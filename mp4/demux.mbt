// demux.mbt —— MP4（Opus-in-MP4）→ Ogg Opus 解封装
//
// 与 write.mbt 的 `remux_ogg_opus` 互逆：只搬容器，不解码。
// 读侧只支持「单音轨、Opus 编码、mdhd timescale = 48000」的 MP4 ——
// 这是 Opus-in-ISOBMFF 规范要求的形态，也正好覆盖 remux 的产物。
//
// 注释（OpusTags）在 MP4 写侧没有保存，因此输出的 OpusTags 使用最小
// vendor 串（"moonmux"）+ 0 条注释；音频包与 OpusHead 字段逐字节还原。

///|
/// 单次解封装的样本数上限。
///
/// 每个样本至少要一个 stsz 表项 + 一个 `@ogg.Packet` + 一个 Ogg 页对象，
/// 内存开销与样本数成正比。只靠输出 2 GiB 闸门管不住这些中间对象：
/// 2,000,000 个 1 字节样本只有 58 MB 输出，按声明值展开的中间数组却要
/// ~587 MB（H-02）。因此显式设上限，超限在分配前报错。
/// 1,048,576 个样本在 20 ms/包下约 5.8 小时音频，足够容器层场景。
const MAX_DEMUX_SAMPLES : Int64 = 1048576L

///|
/// 解封装输出的字节上限（与 CLI 的单文件 2 GiB 能力边界一致）。
const MAX_DEMUX_OUTPUT_BYTES : Int64 = 2147483647L

///|
/// 一个包在 Ogg 中占用的字节数：页头 27 B + 段表 + 负载。
///
/// 单页最多 255 个段、每段最多 255 字节；超长包会拆成多页，每页各带 27 B
/// 页头。输出 2 GiB 闸门必须按这个精确口径预估，否则会低估实际输出。
fn ogg_packet_bytes(size : Int64) -> Int64 {
  let segments = size / 255L + 1L
  let pages = (segments + 254L) / 255L
  pages * 27L + segments + size
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
  stream_count : Int32
  coupled_count : Int32
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
///
/// `expected_samples` 是 stsz 决定的样本总数：游程样本数之和必须恰好相等。
/// 累加全程用 Int64 并即时与上界比较 —— 声明值再大也不会被展开/分配，
/// 更不会因为 32 位回绕而"绕过"一致性检查（C-01：0x7FFFFFFF + 0x7FFFFFFF + 3
/// 在 Int32 下等于 1，旧实现据此展开 ~4.29×10⁹ 个时长）。
fn read_stts(
  data : Bytes,
  b : BoxRef,
  expected_samples : Int64,
) -> Result[Array[SttsRun], String] {
  let avail = b.next - b.body
  if avail < 8 {
    return Err("stts 太短")
  }
  let count = rd_u32_be(data, b.body + 4)
  if count < 0 || count > (avail - 8) / 8 {
    return Err("stts 条目数越界")
  }
  let runs : Array[SttsRun] = []
  let mut total = 0L
  let mut i = 0
  while i < count {
    let p = b.body + 8 + i * 8
    let n = rd_u32_be(data, p)
    let delta = rd_u32_be(data, p + 4)
    if n <= 0 || delta < 0 {
      return Err("stts 游程非法")
    }
    total = total + n.to_int64()
    if total > expected_samples {
      return Err(
        "stts 覆盖的样本数超过 stsz（" +
        expected_samples.to_string() +
        "）",
      )
    }
    runs.push({ sample_count: n, delta, })
    i = i + 1
  }
  if total != expected_samples {
    return Err(
      "stts 覆盖的样本数（" +
      total.to_string() +
      "）与 stsz（" +
      expected_samples.to_string() +
      "）不一致",
    )
  }
  Ok(runs)
}

///|
/// stsz：逐样本大小。
///
/// 上界用的是 **mdat 实际负载字节数**，不是整个文件长度：`fixed = 1` 时
/// 按文件长度能声明到文件字节数那么多样本，但真正能装进 mdat 的样本总量
/// 必须 <= mdat 负载，否则按声明值展开就是内存放大（H-02）。
///
/// 输出大小预估（页头 + 段表 + 负载，见 `ogg_packet_bytes`）也在**物化
/// 样本表之前**校验并拦 2 GiB；样本数另有显式上限。三条上界都在分配前：
/// 自洽的大声明直接 Err，不会先吃掉数 GiB 内存再报错。
fn read_stsz(
  data : Bytes,
  b : BoxRef,
  mdat_bytes : Int64,
  packet_overhead : Int64,
) -> Result[Array[Int32], String] {
  let avail = b.next - b.body
  if avail < 12 {
    return Err("stsz 太短")
  }
  let fixed = rd_u32_be(data, b.body + 4)
  let count = rd_u32_be(data, b.body + 8)
  if fixed < 0 || count < 0 {
    return Err("stsz 样本大小或样本数非法")
  }
  let count64 = count.to_int64()
  if count64 > MAX_DEMUX_SAMPLES {
    return Err(
      "stsz 样本数（" +
      count64.to_string() +
      "）超过解封装上限（" +
      MAX_DEMUX_SAMPLES.to_string() +
      "）",
    )
  }
  let sizes : Array[Int32] = []
  if fixed > 0 {
    let total = count64 * fixed.to_int64()
    if total > mdat_bytes {
      return Err("stsz 定长样本总大小超出 mdat 大小")
    }
    let estimate = ogg_packet_bytes(fixed.to_int64()) * count64 +
      packet_overhead
    if estimate > MAX_DEMUX_OUTPUT_BYTES {
      return Err(
        "解封装输出预估（" +
        estimate.to_string() +
        " B）超过单文件 2 GiB 上限",
      )
    }
    let mut i = 0
    while i < count {
      sizes.push(fixed)
      i = i + 1
    }
  } else {
    if count > (avail - 12) / 4 {
      return Err("stsz 表越界")
    }
    // 第一遍只读表校验并预估输出（不分配）；声明值必须先和 mdat 实际负载
    // 对齐，自洽的大声明在这里被拒，而不是先物化数 GiB 数组。
    let mut total = 0L
    let mut estimate = packet_overhead
    let mut i = 0
    while i < count {
      let size = rd_u32_be(data, b.body + 12 + i * 4)
      if size <= 0 {
        return Err("stsz 中存在空样本")
      }
      total = total + size.to_int64()
      if total > mdat_bytes {
        return Err("stsz 样本总大小超出 mdat 大小")
      }
      estimate = estimate + ogg_packet_bytes(size.to_int64())
      if estimate > MAX_DEMUX_OUTPUT_BYTES {
        return Err(
          "解封装输出预估（" +
          estimate.to_string() +
          " B）超过单文件 2 GiB 上限",
        )
      }
      i = i + 1
    }
    // 第二遍才物化（count 已被样本数上限与 box 长度双重约束）
    i = 0
    while i < count {
      sizes.push(rd_u32_be(data, b.body + 12 + i * 4))
      i = i + 1
    }
  }
  Ok(sizes)
}

///|
/// stsc：chunk → 样本数的映射。
///
/// `max_entries` 用样本总数做上界：每个游程覆盖至少一个 chunk、每个 chunk
/// 至少一个样本，所以游程数不可能超过样本数。没有这个上界时，一个只声明
/// 条目数的 stsc box 也能让解析器先分配几 GiB 数组（同类"先分配后校验"）。
fn read_stsc(
  data : Bytes,
  b : BoxRef,
  max_entries : Int64,
) -> Result[Array[StscRun], String] {
  let avail = b.next - b.body
  if avail < 8 {
    return Err("stsc 太短")
  }
  let count = rd_u32_be(data, b.body + 4)
  if count <= 0 || count.to_int64() > max_entries || count > (avail - 8) / 12 {
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
/// chunk 偏移的公共校验：必须落在 mdat 负载内，且不超出 2 GiB 能力边界。
///
/// 文件是一次读进 `Bytes` 的（长度 < 2³¹），所以 64 位偏移 >= 2³¹ 必然非法；
/// 提前拒绝比在样本循环里读到错误位置更安全（M-01）。
fn check_chunk_offset(
  offset : Int64,
  mdat_body : Int64,
  mdat_end : Int64,
) -> Result[Unit, String] {
  if offset < 0L || offset > 2147483647L {
    return Err("偏移超出单文件 2 GiB 上限")
  }
  if offset < mdat_body || offset >= mdat_end {
    return Err("偏移不在 mdat 内")
  }
  Ok(())
}

///|
fn read_stco(
  data : Bytes,
  b : BoxRef,
  mdat_body : Int64,
  mdat_end : Int64,
  max_entries : Int64,
) -> Result[Array[Int64], String] {
  let avail = b.next - b.body
  if avail < 8 {
    return Err("stco 太短")
  }
  let count = rd_u32_be(data, b.body + 4)
  if count <= 0 || count.to_int64() > max_entries || count > (avail - 8) / 4 {
    return Err("stco 条目数非法")
  }
  let offsets : Array[Int64] = []
  let mut i = 0
  while i < count {
    let offset = rd_u32_be(data, b.body + 8 + i * 4).to_int64() & 0xFFFFFFFFL
    match check_chunk_offset(offset, mdat_body, mdat_end) {
      Ok(_) => offsets.push(offset)
      Err(msg) => return Err("stco " + msg)
    }
    i = i + 1
  }
  Ok(offsets)
}

///|
/// co64：64 位 chunk 偏移。
///
/// 关键点：先按 Int64 校验，再决定是否收窄；`Int64::to_int` 是截断而不是
/// 报错，直接截断会把 `2³² + 合法偏移` 静默当成合法偏移使用（M-01）。
fn read_co64(
  data : Bytes,
  b : BoxRef,
  mdat_body : Int64,
  mdat_end : Int64,
  max_entries : Int64,
) -> Result[Array[Int64], String] {
  let avail = b.next - b.body
  if avail < 8 {
    return Err("co64 太短")
  }
  let count = rd_u32_be(data, b.body + 4)
  if count <= 0 || count.to_int64() > max_entries || count > (avail - 8) / 8 {
    return Err("co64 条目数非法")
  }
  let offsets : Array[Int64] = []
  let mut i = 0
  while i < count {
    let offset = rd_u64_be(data, b.body + 8 + i * 8)
    // 2³¹ 以上的偏移在 2 GiB 读取边界内不可能指向真实负载
    if offset < 0L || offset > 2147483647L {
      return Err("co64 偏移超出单文件 2 GiB 上限")
    }
    match check_chunk_offset(offset, mdat_body, mdat_end) {
      Ok(_) => offsets.push(offset)
      Err(msg) => return Err("co64 " + msg)
    }
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
  let avail = stsd.next - stsd.body
  if avail < 8 {
    return Err("stsd 太短")
  }
  let count = rd_u32_be(data, stsd.body + 4)
  if count <= 0 {
    return Err("stsd 没有样本描述")
  }
  let entry = stsd.body + 8
  if stsd.next - entry < 8 {
    return Err("stsd 样本条目越界")
  }
  let size = rd_u32_be(data, entry)
  let codec = rd_fourcc(data, entry + 4)
  if codec != "Opus" {
    return Err("不是 Opus-in-MP4（样本条目为 " + codec + "）")
  }
  // entry + size 在 Int32 上可回绕成负数从而绕过父 box 边界检查；
  // 用「剩余字节数」比较（entry <= stsd.next 由上面的检查保证）。
  if size < 36 || size.to_int64() > (stsd.next - entry).to_int64() {
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
  let avail = dops.next - b
  if avail < 11 {
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
  let mut stream_count = 0
  let mut coupled_count = 0
  if family != 0 {
    if avail < 13 + channels {
      return Err("dOps 声道映射表越界")
    }
    stream_count = rd_u8(data, b + 11)
    coupled_count = rd_u8(data, b + 12)
    let mut i = 0
    while i < channels {
      mapping.push(rd_u8(data, b + 13 + i))
      i = i + 1
    }
  }
  Ok({
    channels,
    pre_skip,
    input_rate,
    gain,
    family,
    stream_count,
    coupled_count,
    mapping,
  })
}

///|
/// 按 dOps 还原 OpusHead（RFC 7845 §5.1）。
fn encode_opus_head(config : OpusConfig) -> Bytes {
  // family=0：19 字节固定头；family≠0：再加 StreamCount/CoupledCount/Mapping(C)，
  // 即 21+C 字节（RFC 7845 §5.1.1）。少写这两个字节会让映射表整体前移。
  let buf = Buffer(size_hint=21 + config.mapping.length())
  buf.write_bytes(b"OpusHead".exact_view())
  push_u8(buf, 1) // 版本
  push_u8(buf, config.channels)
  push_u16_le(buf, config.pre_skip)
  push_u32_le(buf, config.input_rate)
  push_u16_le(buf, config.gain)
  push_u8(buf, config.family)
  if config.family != 0 {
    push_u8(buf, config.stream_count)
    push_u8(buf, config.coupled_count)
    for m in config.mapping {
      push_u8(buf, m)
    }
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
  // 找音频轨；多音轨必须拒绝，不能静默只解第一条
  let mut trak : BoxRef? = None
  let mut audio_tracks = 0
  for b in boxes_in(data, moov.body, moov.next) {
    if b.fourcc == "trak" {
      match child(data, b, "mdia") {
        Some(mdia) =>
          match child(data, mdia, "hdlr") {
            Some(h) =>
              if h.next - h.body >= 12 && rd_fourcc(data, h.body + 8) == "soun" {
                audio_tracks = audio_tracks + 1
                if audio_tracks > 1 {
                  return Err("MP4 含多条音频轨，只支持单音轨")
                }
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
  let (timescale, _) = match read_time_header(data, mdhd) {
    Some(pair) => pair
    None => return Err("mdhd 被截断，无法解析时长字段")
  }
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
  let head_bytes = encode_opus_head(config)
  let tags_bytes = encode_min_opus_tags()
  let packet_overhead = ogg_packet_bytes(head_bytes.length().to_int64()) +
    ogg_packet_bytes(tags_bytes.length().to_int64())
  let mdat_body = mdat.body.to_int64()
  let mdat_end = mdat.next.to_int64()
  // stsz 决定样本总数：先按 mdat 实际负载（H-02）+ 样本数上限 + 输出预估
  // 在分配前卡住，再让 stts 在 Int64 下证明覆盖数量恰好相等（C-01）。
  let sizes = match
    read_stsz(data, stsz, mdat_end - mdat_body, packet_overhead) {
    Ok(v) => v
    Err(msg) => return Err(msg)
  }
  let sample_count = sizes.length()
  if sample_count == 0 {
    return Err("MP4 中没有音频样本")
  }
  let stts_runs = match read_stts(data, stts, sample_count.to_int64()) {
    Ok(v) => v
    Err(msg) => return Err(msg)
  }
  let stsc_runs = match read_stsc(data, stsc, sample_count.to_int64()) {
    Ok(v) => v
    Err(msg) => return Err(msg)
  }
  // chunk 偏移：stco，缺省时尝试 co64
  let chunk_offsets = match find_box(stbl_children, "stco") {
    Some(b) =>
      match read_stco(data, b, mdat_body, mdat_end, sample_count.to_int64()) {
        Ok(v) => v
        Err(msg) => return Err(msg)
      }
    None => {
      let co64 = match find_box(stbl_children, "co64") {
        Some(b) => b
        None => return Err("stbl 缺少 stco/co64")
      }
      match
        read_co64(data, co64, mdat_body, mdat_end, sample_count.to_int64()) {
        Ok(v) => v
        Err(msg) => return Err(msg)
      }
    }
  }
  // 组装 Ogg：OpusHead + OpusTags + 音频包。
  // 按 chunk → 样本表流式生成：时长从 stts 游程按需取（不展开 durations），
  // 样本位置/大小直接转成包（不物化 samples 数组）。
  let serial = (0x4D4D5558 : UInt32) // 'MMUX'
  let packets : Array[@ogg.Packet] = []
  packets.push({ data: head_bytes, granule_position: 0L, serial, })
  packets.push({ data: tags_bytes, granule_position: 0L, serial, })
  let mut cumulative : Int64 = 0L
  let mut sample_i = 0
  let mut sc_i = 0
  let mut chunk_i = 0
  let mut run_i = 0
  let mut run_used = 0
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
      // Int64 计算 pos + size：size 是 u32 读出的 32 位字段，直接相加会溢出成
      // 负数，从而绕过 mdat 边界检查，产出 0 字节音频包却不报错。
      let end64 = pos + size.to_int64()
      if size <= 0 || pos < mdat_body || end64 > mdat_end {
        return Err("样本偏移越界（chunk " + chunk_no.to_string() + "）")
      }
      // 从 stts 游程取本样本时长；游程总覆盖在 read_stts 里已证明恰好相等。
      while run_i < stts_runs.length() &&
            run_used >= stts_runs[run_i].sample_count {
        run_i = run_i + 1
        run_used = 0
      }
      if run_i >= stts_runs.length() {
        return Err("stts 覆盖的样本数不足")
      }
      cumulative = cumulative + stts_runs[run_i].delta.to_int64()
      packets.push({
        data: demux_slice(data, pos.to_int(), end64.to_int()),
        // RFC 7845 §4：granule = 已解码样本总数（PCM position = granule − pre-skip），
        // 不能在这里再加一次 pre-skip，否则 ogg 端会多算一个 pre-skip 的时长。
        granule_position: cumulative,
        serial,
      })
      pos = end64
      sample_i = sample_i + 1
      run_used = run_used + 1
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
  // 输出聚合大小闸门：与 read_stsz 的预估同口径（页头 + 段表 + 负载）。
  // read_stsz 已在分配前拦过；这里按实际包再核一次，防止口径漂移。
  let mut out_size = 0L
  for p in packets {
    out_size = out_size + ogg_packet_bytes(p.data.length().to_int64())
  }
  if out_size > MAX_DEMUX_OUTPUT_BYTES {
    return Err("解封装输出超过单文件 2 GiB 上限")
  }
  Ok(@ogg.serialize_pages(@ogg.paginate(packets, serial)))
}
