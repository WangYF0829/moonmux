// demux.mbt —— MP4（Opus-in-MP4）→ Ogg Opus 解封装
//
// 与 write.mbt 的 `remux_ogg_opus` 互逆：只搬容器，不解码。
// 读侧只支持「单音轨、Opus 编码、mdhd timescale = 48000」的 MP4 ——
// 这是 Opus-in-ISOBMFF 规范要求的形态，也正好覆盖 remux 的产物。
//
// 注释（OpusTags）在 MP4 写侧没有保存，因此输出的 OpusTags 使用最小
// vendor 串（"moonmux"）+ 0 条注释；音频包与 OpusHead 字段逐字节还原。

///|
/// 一个 MP4 样本（= 一个 Opus 包）在文件中的位置与时长。
priv struct Mp4Sample {
  offset : Int32
  size : Int32
  duration : Int32
}

///|
/// stts 的游程：连续 `sample_count` 个样本，每个时长 `delta`。
priv struct SttsRun {
  sample_count : Int32
  delta : Int32
}

///|
/// stsc 的游程：从 `first_chunk`（1 起算）开始，每个 chunk 装 `samples_per_chunk` 个样本。
priv struct StscRun {
  first_chunk : Int32
  samples_per_chunk : Int32
}

///|
/// 从 dOps 还原出的 Opus 配置。
priv struct OpusConfig {
  channels : Int32
  pre_skip : Int32
  input_rate : Int32
  gain : Int32
  family : Int32
  mapping : Array[Int32]
}

// ---------- 小端写出 ----------

///|
fn push_u16_le(buf : Buffer, v : Int32) -> Unit {
  buf.write_uint16_le(v.to_uint16())
}

///|
fn push_u32_le(buf : Buffer, v : Int32) -> Unit {
  buf.write_uint_le(v.reinterpret_as_uint())
}

///|
/// 拷贝字节切片 `[start, end)`。
fn demux_slice(data : Bytes, start : Int32, end : Int32) -> Bytes {
  let out = Buffer(size_hint=end - start)
  let mut i = start
  while i < end {
    out.write_byte(data[i])
    i = i + 1
  }
  out.to_bytes()
}

// ---------- 样本表解析 ----------

///|
/// stts：样本时长游程。
fn read_stts(data : Bytes, b : BoxRef) -> Result[Array[SttsRun], String] {
  if b.body + 8 > b.next {
    return Err("stts 太短")
  }
  let count = rd_u32_be(data, b.body + 4)
  if count < 0 || count > (b.next - b.body - 8) / 8 {
    return Err("stts 条目数越界")
  }
  let runs : Array[SttsRun] = []
  let mut i = 0
  while i < count {
    let p = b.body + 8 + i * 8
    let n = rd_u32_be(data, p)
    let delta = rd_u32_be(data, p + 4)
    if n <= 0 || delta < 0 {
      return Err("stts 游程非法")
    }
    runs.push({ sample_count: n, delta, })
    i = i + 1
  }
  Ok(runs)
}

///|
/// stsz：逐样本大小。
fn read_stsz(data : Bytes, b : BoxRef) -> Result[Array[Int32], String] {
  if b.body + 12 > b.next {
    return Err("stsz 太短")
  }
  let fixed = rd_u32_be(data, b.body + 4)
  let count = rd_u32_be(data, b.body + 8)
  if count < 0 {
    return Err("stsz 样本数非法")
  }
  let sizes : Array[Int32] = []
  if fixed > 0 {
    let mut i = 0
    while i < count {
      sizes.push(fixed)
      i = i + 1
    }
  } else {
    if count > (b.next - b.body - 12) / 4 {
      return Err("stsz 表越界")
    }
    let mut i = 0
    while i < count {
      let size = rd_u32_be(data, b.body + 12 + i * 4)
      if size <= 0 {
        return Err("stsz 中存在空样本")
      }
      sizes.push(size)
      i = i + 1
    }
  }
  Ok(sizes)
}

///|
/// stsc：chunk → 样本数的映射。
fn read_stsc(data : Bytes, b : BoxRef) -> Result[Array[StscRun], String] {
  if b.body + 8 > b.next {
    return Err("stsc 太短")
  }
  let count = rd_u32_be(data, b.body + 4)
  if count <= 0 || count > (b.next - b.body - 8) / 12 {
    return Err("stsc 条目数非法")
  }
  let runs : Array[StscRun] = []
  let mut i = 0
  while i < count {
    let p = b.body + 8 + i * 12
    let first_chunk = rd_u32_be(data, p)
    let spc = rd_u32_be(data, p + 4)
    if first_chunk <= 0 || spc <= 0 {
      return Err("stsc 游程非法")
    }
    if i == 0 && first_chunk != 1 {
      return Err("stsc 首个游程的 first_chunk 必须是 1")
    }
    if i > 0 && first_chunk <= runs[i - 1].first_chunk {
      return Err("stsc 游程未递增")
    }
    runs.push({ first_chunk, samples_per_chunk: spc, })
    i = i + 1
  }
  Ok(runs)
}

///|
/// stco：chunk 偏移（32 位）。
fn read_stco(data : Bytes, b : BoxRef) -> Result[Array[Int32], String] {
  if b.body + 8 > b.next {
    return Err("stco 太短")
  }
  let count = rd_u32_be(data, b.body + 4)
  if count <= 0 || count > (b.next - b.body - 8) / 4 {
    return Err("stco 条目数非法")
  }
  let offsets : Array[Int32] = []
  let mut i = 0
  while i < count {
    offsets.push(rd_u32_be(data, b.body + 8 + i * 4))
    i = i + 1
  }
  Ok(offsets)
}

///|
/// 在 stsd 里定位第一个 Opus 样本条目，返回 [entry, entry_end)。
fn find_opus_entry(
  data : Bytes,
  stsd : BoxRef,
) -> Result[(Int32, Int32), String] {
  if stsd.body + 8 > stsd.next {
    return Err("stsd 太短")
  }
  let count = rd_u32_be(data, stsd.body + 4)
  if count <= 0 {
    return Err("stsd 没有样本描述")
  }
  let entry = stsd.body + 8
  if entry + 8 > stsd.next {
    return Err("stsd 样本条目越界")
  }
  let size = rd_u32_be(data, entry)
  let codec = rd_fourcc(data, entry + 4)
  if codec != "Opus" {
    return Err("不是 Opus-in-MP4（样本条目为 " + codec + "）")
  }
  if size < 36 || entry + size > stsd.next {
    return Err("Opus 样本条目长度非法")
  }
  Ok((entry, entry + size))
}

///|
/// 从 `dOps` box 还原 Opus 配置。
///
/// 布局（Opus-in-ISOBMFF）：Version(1) | OutputChannelCount(1) |
/// PreSkip(2 BE) | InputSampleRate(4 BE) | OutputGain(2 BE) |
/// ChannelMappingFamily(1) [| StreamCount(1) | CoupledCount(1) | Mapping(channels)]
fn parse_dops(data : Bytes, dops : BoxRef) -> Result[OpusConfig, String] {
  let b = dops.body
  if b + 11 > dops.next {
    return Err("dOps 太短")
  }
  let version = rd_u8(data, b)
  if version != 0 {
    return Err("dOps 版本不支持: " + version.to_string())
  }
  let channels = rd_u8(data, b + 1)
  if channels <= 0 {
    return Err("dOps 声道数为 0")
  }
  let pre_skip = rd_u16_be(data, b + 2)
  let input_rate = rd_u32_be(data, b + 4)
  let gain_u = rd_u16_be(data, b + 8)
  let gain = if gain_u >= 0x8000 { gain_u - 0x10000 } else { gain_u }
  let family = rd_u8(data, b + 10)
  let mapping : Array[Int32] = []
  if family != 0 {
    if b + 13 + channels > dops.next {
      return Err("dOps 声道映射表越界")
    }
    let mut i = 0
    while i < channels {
      mapping.push(rd_u8(data, b + 13 + i))
      i = i + 1
    }
  }
  Ok({ channels, pre_skip, input_rate, gain, family, mapping, })
}

///|
/// 按 dOps 还原 OpusHead（RFC 7845 §5.1）。
fn encode_opus_head(config : OpusConfig) -> Bytes {
  let buf = Buffer(size_hint=19 + config.mapping.length())
  buf.write_bytes(b"OpusHead".exact_view())
  push_u8(buf, 1) // 版本
  push_u8(buf, config.channels)
  push_u16_le(buf, config.pre_skip)
  push_u32_le(buf, config.input_rate)
  push_u16_le(buf, config.gain)
  push_u8(buf, config.family)
  for m in config.mapping {
    push_u8(buf, m)
  }
  buf.to_bytes()
}

///|
/// 输出用的最小 OpusTags：magic + vendor("moonmux") + 0 条注释。
fn encode_min_opus_tags() -> Bytes {
  let vendor = b"moonmux"
  let buf = Buffer(size_hint=8 + 4 + vendor.length() + 4)
  buf.write_bytes(b"OpusTags".exact_view())
  push_u32_le(buf, vendor.length())
  buf.write_bytes(vendor.exact_view())
  push_u32_le(buf, 0)
  buf.to_bytes()
}

///|
/// 从 MP4（Opus-in-MP4）解封装回 Ogg Opus 字节流。
///
/// 只支持单音轨、Opus 编码、`mdhd` timescale = 48000 的文件；
/// 不做转码，Opus 包逐字节搬运。输出为单逻辑流、确定性 serial（无需随机数），
/// 便于测试与逐字节比对。
pub fn demux_mp4_opus(data : Bytes) -> Result[Bytes, String] {
  if data.length() < 16 || !is_mp4(data) {
    return Err("不是 MP4 文件（缺少 ftyp）")
  }
  let top = boxes_in(data, 0, data.length())
  let moov = match find_box(top, "moov") {
    Some(b) => b
    None => return Err("MP4 缺少 moov")
  }
  let mdat = match find_box(top, "mdat") {
    Some(b) => b
    None => return Err("MP4 缺少 mdat")
  }
  // 找第一条音频轨
  let mut trak : BoxRef? = None
  for b in boxes_in(data, moov.body, moov.next) {
    if b.fourcc == "trak" {
      match child(data, b, "mdia") {
        Some(mdia) =>
          match child(data, mdia, "hdlr") {
            Some(h) =>
              if h.body + 12 <= h.next && rd_fourcc(data, h.body + 8) == "soun" {
                trak = Some(b)
              }
            None => ()
          }
        None => ()
      }
    }
  }
  let trak_box = match trak {
    Some(t) => t
    None => return Err("MP4 中没有音频轨")
  }
  let mdia = match child(data, trak_box, "mdia") {
    Some(m) => m
    None => return Err("音频轨缺少 mdia")
  }
  let mdia_children = boxes_in(data, mdia.body, mdia.next)
  let mdhd = match find_box(mdia_children, "mdhd") {
    Some(m) => m
    None => return Err("音频轨缺少 mdhd")
  }
  let (timescale, _) = read_time_header(data, mdhd)
  if timescale != 48000 {
    return Err(
      "不是 Opus-in-MP4（mdhd timescale = " +
      timescale.to_string() +
      "，Opus 要求 48000）",
    )
  }
  let minf = match child(data, mdia, "minf") {
    Some(m) => m
    None => return Err("音频轨缺少 minf")
  }
  let stbl = match child(data, minf, "stbl") {
    Some(s) => s
    None => return Err("音频轨缺少 stbl")
  }
  let stbl_children = boxes_in(data, stbl.body, stbl.next)
  let stsd = match find_box(stbl_children, "stsd") {
    Some(b) => b
    None => return Err("stbl 缺少 stsd")
  }
  let stts = match find_box(stbl_children, "stts") {
    Some(b) => b
    None => return Err("stbl 缺少 stts")
  }
  let stsz = match find_box(stbl_children, "stsz") {
    Some(b) => b
    None => return Err("stbl 缺少 stsz")
  }
  let stsc = match find_box(stbl_children, "stsc") {
    Some(b) => b
    None => return Err("stbl 缺少 stsc")
  }
  let (entry_start, entry_end) = match find_opus_entry(data, stsd) {
    Ok(v) => v
    Err(msg) => return Err(msg)
  }
  let dops = match
    find_box(boxes_in(data, entry_start + 36, entry_end), "dOps") {
    Some(b) => b
    None => return Err("Opus 样本条目缺少 dOps")
  }
  let config = match parse_dops(data, dops) {
    Ok(c) => c
    Err(msg) => return Err(msg)
  }
  let stts_runs = match read_stts(data, stts) {
    Ok(v) => v
    Err(msg) => return Err(msg)
  }
  let sizes = match read_stsz(data, stsz) {
    Ok(v) => v
    Err(msg) => return Err(msg)
  }
  let stsc_runs = match read_stsc(data, stsc) {
    Ok(v) => v
    Err(msg) => return Err(msg)
  }
  // chunk 偏移：stco，缺省时尝试 co64
  let mut chunk_offsets : Array[Int32] = []
  match find_box(stbl_children, "stco") {
    Some(b) =>
      match read_stco(data, b) {
        Ok(v) => chunk_offsets = v
        Err(msg) => return Err(msg)
      }
    None => {
      let co64 = match find_box(stbl_children, "co64") {
        Some(b) => b
        None => return Err("stbl 缺少 stco/co64")
      }
      if co64.body + 8 > co64.next {
        return Err("co64 太短")
      }
      let count = rd_u32_be(data, co64.body + 4)
      if count <= 0 || count > (co64.next - co64.body - 8) / 8 {
        return Err("co64 条目数非法")
      }
      let mut i = 0
      while i < count {
        chunk_offsets.push(rd_u64_be(data, co64.body + 8 + i * 8).to_int())
        i = i + 1
      }
    }
  }
  let sample_count = sizes.length()
  if sample_count == 0 {
    return Err("MP4 中没有音频样本")
  }
  // 时长表必须覆盖全部样本
  let mut duration_total = 0
  for run in stts_runs {
    duration_total = duration_total + run.sample_count
  }
  if duration_total != sample_count {
    return Err(
      "stts 覆盖的样本数（" +
      duration_total.to_string() +
      "）与 stsz（" +
      sample_count.to_string() +
      "）不一致",
    )
  }
  let durations : Array[Int32] = []
  for run in stts_runs {
    let mut i = 0
    while i < run.sample_count {
      durations.push(run.delta)
      i = i + 1
    }
  }
  // 按 chunk → 样本表切出样本并计算 granule
  let samples : Array[Mp4Sample] = []
  let mut sample_i = 0
  let mut sc_i = 0
  let mut chunk_i = 0
  while chunk_i < chunk_offsets.length() && sample_i < sample_count {
    let chunk_no = chunk_i + 1
    while sc_i + 1 < stsc_runs.length() &&
          stsc_runs[sc_i + 1].first_chunk <= chunk_no {
      sc_i = sc_i + 1
    }
    let spc = stsc_runs[sc_i].samples_per_chunk
    let mut pos = chunk_offsets[chunk_i]
    let mut k = 0
    while k < spc && sample_i < sample_count {
      let size = sizes[sample_i]
      let end = pos + size
      if pos < mdat.body || end > mdat.next {
        return Err("样本偏移越界（chunk " + chunk_no.to_string() + "）")
      }
      samples.push({ offset: pos, size, duration: durations[sample_i], })
      pos = end
      sample_i = sample_i + 1
      k = k + 1
    }
    chunk_i = chunk_i + 1
  }
  if sample_i != sample_count {
    return Err(
      "stsc/stco 只覆盖了 " +
      sample_i.to_string() +
      " / " +
      sample_count.to_string() +
      " 个样本",
    )
  }
  // 组装 Ogg：OpusHead + OpusTags + 音频包
  let serial = (0x4D4D5558 : UInt32) // 'MMUX'
  let packets : Array[@ogg.Packet] = []
  packets.push({ data: encode_opus_head(config), granule_position: 0L, serial, })
  packets.push({ data: encode_min_opus_tags(), granule_position: 0L, serial, })
  let mut cumulative : Int64 = 0L
  for sample in samples {
    cumulative = cumulative + sample.duration.to_int64()
    packets.push({
      data: demux_slice(data, sample.offset, sample.offset + sample.size),
      granule_position: config.pre_skip.to_int64() + cumulative,
      serial,
    })
  }
  Ok(@ogg.serialize_pages(@ogg.paginate(packets, serial)))
}
