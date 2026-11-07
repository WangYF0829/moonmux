// write.mbt —— Opus-in-MP4 的 moov 构造
//
// 只实现 version 0 的时间字段（32 位）：月赛/工具场景下单文件时长远小于
// 2^32 个时间单位。文件布局固定为 ftyp + mdat + moov，单 chunk 装全部样本：
//
//   · mdat 在前 → moov 里的 stco 偏移在写 moov 前就确定（ftyp 长度 + 8），
//     不需要回填（Bytes 不可变，回填要么预留占位要么重写，容易出不一致）；
//   · 单 chunk 意味着 stsc 只有一项、stco 只有一项，表小且自洽。
//
// 所有字段的大端序、盒子的嵌套关系均有单测覆盖；对外一致性由
// ffprobe / isobmff 读回与 mp4/inspect 自检共同保证。

// ---------- 小端读取（解析 OpusHead 用；Ogg 侧字段是小端） ----------

///|
fn le16_at(data : Bytes, offset : Int32) -> Int32 {
  data[offset].to_int() | (data[offset + 1].to_int() << 8)
}

///|
fn le32_at(data : Bytes, offset : Int32) -> Int32 {
  data[offset].to_int() |
  (data[offset + 1].to_int() << 8) |
  (data[offset + 2].to_int() << 16) |
  (data[offset + 3].to_int() << 24)
}

// ---------- 通用结构 ----------

///|
/// ftyp：主品牌、次版本、兼容品牌列表。
fn ftyp_box(major : String, minor : Int32, brands : Array[String]) -> Bytes {
  let body = Buffer(size_hint=8 + brands.length() * 4)
  push_fourcc(body, major)
  push_u32_be(body, minor)
  for b in brands {
    push_fourcc(body, b)
  }
  box("ftyp", body.to_bytes())
}

///|
/// 单位矩阵（mvhd / tkhd 共用，16.16 定点）。
fn identity_matrix(buf : Buffer) -> Unit {
  let values : Array[Int32] = [
    0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000,
  ]
  for v in values {
    push_u32_be(buf, v)
  }
}

// ---------- moov 子结构 ----------

///|
/// mvhd：媒体时间轴（movie timescale）与总时长。
fn mvhd_box(timescale : Int32, duration : Int32) -> Bytes {
  let body = Buffer(size_hint=100)
  push_u32_be(body, 0) // creation_time
  push_u32_be(body, 0) // modification_time
  push_u32_be(body, timescale)
  push_u32_be(body, duration)
  push_u32_be(body, 0x00010000) // rate 1.0（16.16）
  push_u16_be(body, 0x0100) // volume 1.0（8.8）
  push_u16_be(body, 0) // reserved
  push_u32_be(body, 0) // reserved
  push_u32_be(body, 0) // reserved
  identity_matrix(body)
  let mut i = 0
  while i < 6 {
    push_u32_be(body, 0) // pre_defined[6]
    i = i + 1
  }
  push_u32_be(body, 2) // next_track_ID
  full_box("mvhd", 0, 0, body.to_bytes())
}

///|
/// tkhd：轨道头（时长用 movie timescale；音频轨 volume 1.0）。
fn tkhd_box(track_id : Int32, duration : Int32) -> Bytes {
  let body = Buffer(size_hint=90)
  push_u32_be(body, 0) // creation_time
  push_u32_be(body, 0) // modification_time
  push_u32_be(body, track_id)
  push_u32_be(body, 0) // reserved
  push_u32_be(body, duration)
  push_u32_be(body, 0) // reserved
  push_u32_be(body, 0) // reserved
  push_u16_be(body, 0) // layer
  push_u16_be(body, 0) // alternate_group
  push_u16_be(body, 0x0100) // volume 1.0（8.8）
  push_u16_be(body, 0) // reserved
  identity_matrix(body)
  push_u32_be(body, 0) // width（音频轨为 0）
  push_u32_be(body, 0) // height
  full_box("tkhd", 0, 0x000007, body.to_bytes())
}

///|
/// mdhd：媒体头（媒体时间轴与媒体时长）。
fn mdhd_box(timescale : Int32, duration : Int32) -> Bytes {
  let body = Buffer(size_hint=24)
  push_u32_be(body, 0) // creation_time
  push_u32_be(body, 0) // modification_time
  push_u32_be(body, timescale)
  push_u32_be(body, duration)
  push_u16_be(body, 0x55C4) // language: "und"（ISO-639-2/T 打包）
  push_u16_be(body, 0) // pre_defined
  full_box("mdhd", 0, 0, body.to_bytes())
}

///|
/// hdlr：处理器类型（音频为 "soun"）。
fn hdlr_box(handler : String, name : String) -> Bytes {
  let body = Buffer(size_hint=24 + name.length())
  push_u32_be(body, 0) // pre_defined
  push_fourcc(body, handler)
  push_u32_be(body, 0) // reserved
  push_u32_be(body, 0) // reserved
  push_u32_be(body, 0) // reserved
  let mut i = 0
  while i < name.length() {
    match name.get_char(i) {
      Some(c) => push_u8(body, c.to_int())
      None => ()
    }
    i = i + 1
  }
  push_u8(body, 0) // null-terminated name
  full_box("hdlr", 0, 0, body.to_bytes())
}

///|
/// smhd：声音媒体头（balance 0）。
fn smhd_box() -> Bytes {
  let body = Buffer(size_hint=4)
  push_u16_be(body, 0) // balance
  push_u16_be(body, 0) // reserved
  full_box("smhd", 0, 0, body.to_bytes())
}

///|
/// dref / url：数据引用（自包含，flags=1）。
fn dinf_box() -> Bytes {
  let url = full_box("url ", 0, 1, b"")
  let dref_payload = concat([u32_array([1]), url])
  let dref = full_box("dref", 0, 0, dref_payload)
  box("dinf", dref)
}

///|
/// dOps：Opus 专用配置盒（Opus in ISOBMFF 的 OpusSpecificBox）。
///
/// 注意：它不是 FullBox —— 没有 version/flags 头，第一个字节就是自己的
/// Version 字段（读侧 ffmpeg 的 mov_read_dops 也是按 `version = r8` 直接读的）。
/// 写成 FullBox 会让整个字段序列左移 3 个字节，解码器读到的是
/// 「zero channel count」。
fn dops_box(opus_head : Bytes) -> Bytes {
  let channels = opus_head[9].to_int()
  let pre_skip = le16_at(opus_head, 10)
  let input_rate = le32_at(opus_head, 12)
  let family = opus_head[18].to_int()
  let body = Buffer(size_hint=16 + channels)
  push_u8(body, 0) // version
  push_u8(body, channels)
  push_u16_be(body, pre_skip)
  push_u32_be(body, input_rate)
  push_u16_be(body, 0) // output gain（Q7.8 dB）
  push_u8(body, family) // channel mapping family
  if family != 0 && opus_head.length() >= 21 + channels {
    push_u8(body, opus_head[19].to_int()) // stream count
    push_u8(body, opus_head[20].to_int()) // coupled count
    let mut i = 0
    while i < channels {
      push_u8(body, opus_head[21 + i].to_int())
      i = i + 1
    }
  }
  box("dOps", body.to_bytes())
}

///|
/// Opus 音频样本条目（AudioSampleEntry + dOps）。
fn opus_sample_entry(opus_head : Bytes) -> Bytes {
  let channels = opus_head[9].to_int()
  let body = Buffer(size_hint=64)
  // reserved(6) + data_reference_index(2)
  push_u16_be(body, 0)
  push_u16_be(body, 0)
  push_u16_be(body, 0)
  push_u16_be(body, 1)
  // AudioSampleEntry
  push_u16_be(body, 0) // version
  push_u16_be(body, 0) // revision
  push_u32_be(body, 0) // vendor
  push_u16_be(body, channels)
  push_u16_be(body, 16) // sample_size
  push_u16_be(body, 0) // compression_id
  push_u16_be(body, 0) // packet_size
  push_u32_be(body, 48000 << 16) // sample_rate（16.16）
  // dOps 是 sample entry 的子 box
  let dops = dops_box(opus_head)
  body.write_bytes(dops.exact_view())
  box("Opus", body.to_bytes())
}

///|
/// stsd：样本描述（Opus 条目）。
fn stsd_box(opus_head : Bytes) -> Bytes {
  let payload = concat([u32_array([1]), opus_sample_entry(opus_head)])
  full_box("stsd", 0, 0, payload)
}

///|
/// stts：解码时间表（run-length 压缩后的 (样本数, 每样本时长)）。
fn stts_box(runs : Array[(Int32, Int32)]) -> Bytes {
  let body = Buffer(size_hint=8 + runs.length() * 8)
  push_u32_be(body, runs.length())
  for r in runs {
    let (count, delta) = r
    push_u32_be(body, count)
    push_u32_be(body, delta)
  }
  full_box("stts", 0, 0, body.to_bytes())
}

///|
/// stsc：样本到 chunk 的映射（单 chunk 装全部样本）。
fn stsc_box(sample_count : Int32) -> Bytes {
  let body = Buffer(size_hint=20)
  push_u32_be(body, 1) // entry_count
  push_u32_be(body, 1) // first_chunk
  push_u32_be(body, sample_count) // samples_per_chunk
  push_u32_be(body, 1) // sample_description_index
  full_box("stsc", 0, 0, body.to_bytes())
}

///|
/// stsz：逐样本大小（sample_size 为 0 时逐个列出）。
fn stsz_box(sizes : Array[Int32]) -> Bytes {
  let body = Buffer(size_hint=12 + sizes.length() * 4)
  push_u32_be(body, 0) // sample_size（0 = 逐样本给出）
  push_u32_be(body, sizes.length())
  for s in sizes {
    push_u32_be(body, s)
  }
  full_box("stsz", 0, 0, body.to_bytes())
}

///|
/// stco：chunk 偏移（单 chunk）。
fn stco_box(offset : Int32) -> Bytes {
  let body = Buffer(size_hint=8)
  push_u32_be(body, 1) // entry_count
  push_u32_be(body, offset)
  full_box("stco", 0, 0, body.to_bytes())
}

///|
/// 组装完整 moov。
fn moov_box(
  opus_head : Bytes,
  total_samples : Int32,
  movie_duration : Int32,
  runs : Array[(Int32, Int32)],
  sizes : Array[Int32],
  chunk_offset : Int32,
) -> Bytes {
  let mvhd = mvhd_box(1000, movie_duration)
  let tkhd = tkhd_box(1, movie_duration)
  let mdhd = mdhd_box(48000, total_samples)
  let hdlr = hdlr_box("soun", "SoundHandler")
  let stbl = box(
    "stbl",
    concat([
      stsd_box(opus_head),
      stts_box(runs),
      stsc_box(sizes.length()),
      stsz_box(sizes),
      stco_box(chunk_offset),
    ]),
  )
  let minf = box("minf", concat([smhd_box(), dinf_box(), stbl]))
  let mdia = box("mdia", concat([mdhd, hdlr, minf]))
  let trak = box("trak", concat([tkhd, mdia]))
  box("moov", concat([mvhd, trak]))
}

// ---------- 对外入口 ----------

///|
/// 把 Ogg（Opus）字节流重新封装成 MP4（Opus-in-MP4）字节流。
///
/// 只支持单条 Opus 逻辑流、非链接流；取 `OpusHead` 与 `OpusTags` 之后的
/// 全部数据包作为样本。每个包按 TOC 计算样本数，单 chunk 装进 mdat。
/// 返回的 MP4 会先用 `inspect` 自检一遍，失败即报错，不产出半成品。
pub fn remux_ogg_opus(ogg_data : Bytes) -> Result[Bytes, String] {
  let pages = @ogg.parse_pages(ogg_data)
  if pages.length() == 0 {
    return Err("不是合法的 Ogg 文件")
  }
  let packets = @ogg.reassemble(pages)
  let streams = @ogg.group_by_stream(packets)
  let mut chosen : @ogg.LogicalStream? = None
  for st in streams {
    if st.packets.length() >= 3 {
      match @codec.parse_opus_head(st.packets[0].data) {
        Some(_) => if chosen is None { chosen = Some(st) }
        None => ()
      }
    }
  }
  let stream = match chosen {
    Some(s) => s
    None =>
      return Err(
        "没有找到 Opus 音频流（首包不是 OpusHead，或包数不足）",
      )
  }
  let opus_head = stream.packets[0].data
  match @codec.parse_opus_head(opus_head) {
    None => return Err("OpusHead 解析失败")
    Some(_) => ()
  }
  let sizes : Array[Int32] = []
  let deltas : Array[Int32] = []
  let mut total_samples = 0
  let mdat = Buffer()
  let mut i = 2
  while i < stream.packets.length() {
    let pkt = stream.packets[i]
    match @codec.opus_packet_samples(pkt.data) {
      Ok(samples) => {
        sizes.push(pkt.data.length())
        deltas.push(samples)
        total_samples = total_samples + samples
        mdat.write_bytes(pkt.data.exact_view())
      }
      Err(msg) =>
        return Err(
          "第 " + (i - 1).to_string() + " 个音频包非法：" + msg,
        )
    }
    i = i + 1
  }
  if sizes.length() == 0 || total_samples == 0 {
    return Err("Opus 流没有可封装的音频包")
  }
  // 把连续相同的样本时长合并成 stts 的 run
  let runs : Array[(Int32, Int32)] = []
  let mut j = 0
  while j < deltas.length() {
    let mut k = j + 1
    while k < deltas.length() && deltas[k] == deltas[j] {
      k = k + 1
    }
    runs.push((k - j, deltas[j]))
    j = k
  }
  let ftyp = ftyp_box("M4A ", 0, ["M4A ", "isom", "iso2", "mp41"])
  let mdat_bytes = box("mdat", mdat.to_bytes())
  let chunk_offset = ftyp.length() + 8
  let movie_duration = ((total_samples.to_int64() * 1000L + 47999L) / 48000L).to_int()
  let moov = moov_box(
    opus_head, total_samples, movie_duration, runs, sizes, chunk_offset,
  )
  let file = concat([ftyp, mdat_bytes, moov])
  // 自检：自己写得对不对，先用自己的读侧过一遍
  match inspect(file) {
    None => Err("生成的 MP4 自检失败（inspect 无法解析）")
    Some(info) =>
      if info.tracks.length() == 0 {
        Err("生成的 MP4 自检失败（没有音轨）")
      } else {
        Ok(file)
      }
  }
}
