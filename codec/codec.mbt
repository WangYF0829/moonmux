// codec.mbt —— 编解码头解析
//
// 只读取标识头里的几个字段，用于回答「这是什么音频、多长、多少声道」。
// 不做解码，也不依赖任何三方包。

///|
/// 一段音频流的格式参数。
///
/// `sample_rate` 是**解码输出**的采样率，不是容器里记录的输入采样率 ——
/// 对 Opus 而言两者常常不同（见 `parse_opus_head`）。
pub(all) struct AudioInfo {
  codec : String
  channels : Int32
  sample_rate : Int32
  // Opus 的 pre-skip（解码器需要丢弃的前导样本数）；Vorbis 恒为 0。
  // 算时长时必须减掉它，否则会把编码器补的前导静音算进去。
  pre_skip : Int32
}

///|
/// 小端读取 16 位无符号整数。
fn rd_u16(data : Bytes, offset : Int32) -> Int32 {
  data[offset].to_int() | (data[offset + 1].to_int() << 8)
}

///|
/// 小端读取 32 位无符号整数。
fn rd_u32(data : Bytes, offset : Int32) -> Int32 {
  data[offset].to_int() |
  (data[offset + 1].to_int() << 8) |
  (data[offset + 2].to_int() << 16) |
  (data[offset + 3].to_int() << 24)
}

///|
/// 判断 `data` 从 `offset` 起是否等于给定的 ASCII 标记。
fn tag_at(data : Bytes, offset : Int32, tag : String) -> Bool {
  if offset + tag.length() > data.length() {
    return false
  }
  let mut i = 0
  let mut same = true
  while i < tag.length() {
    match tag.get_char(i) {
      Some(c) => if data[offset + i].to_int() != c.to_int() { same = false }
      None => same = false
    }
    i = i + 1
  }
  same
}

///|
/// 解析 OpusHead（RFC 7845 §5.1）。不是 Opus 标识头时返回 `None`。
///
/// 字段布局：
///
///   0..8   "OpusHead"
///   8      版本（本实现只认 1）
///   9      声道数
///   10..12 pre-skip（u16 LE）
///   12..16 输入采样率（u32 LE）
///   16..18 输出增益（i16 LE，Q7.8 dB）
///   18     声道映射族
///
/// **输出采样率恒为 48000**：Opus 解码后固定输出 48 kHz，标识头里的
/// 「输入采样率」只是给源素材留的记录，拿它算时长会得到错误结果。
pub fn parse_opus_head(data : Bytes) -> AudioInfo? {
  if data.length() < 19 {
    return None
  }
  if !tag_at(data, 0, "OpusHead") {
    return None
  }
  let version = data[8].to_int()
  if version != 1 {
    return None
  }
  let channels = data[9].to_int()
  if channels == 0 {
    return None
  }
  Some({
    codec: "Opus",
    channels,
    sample_rate: 48000,
    pre_skip: rd_u16(data, 10),
  })
}

///|
/// 解析 Vorbis 识别头（Vorbis I §4.2.2）。不是识别头时返回 `None`。
///
/// 字段布局：
///
///   0      包类型 0x01
///   1..7   "vorbis"
///   7..11  版本（u32 LE）
///   11     声道数
///   12..16 采样率（u32 LE）
///   16..28 三个码率（u32 LE）
///   28     块大小
///   29     帧标志
pub fn parse_vorbis_id(data : Bytes) -> AudioInfo? {
  if data.length() < 30 {
    return None
  }
  if data[0].to_int() != 1 {
    return None
  }
  if !tag_at(data, 1, "vorbis") {
    return None
  }
  let channels = data[11].to_int()
  let sample_rate = rd_u32(data, 12)
  // u32 读进 32 位有符号 Int：高位为 1 的值（如 0xFFFFFFFF）会变成负数。
  // 采样率 <= 0 的头没有意义，一律拒掉 —— 否则 info 会打出「采样率 -1 Hz」，
  // 时长还会被算成负数。
  if channels == 0 || sample_rate <= 0 {
    return None
  }
  Some({ codec: "Vorbis", channels, sample_rate, pre_skip: 0, })
}

///|
/// 依次尝试各编解码的标识头。
pub fn parse_audio_header(data : Bytes) -> AudioInfo? {
  match parse_opus_head(data) {
    Some(info) => Some(info)
    None => parse_vorbis_id(data)
  }
}

///|
/// 由首末粒度位置算时长（秒）。
///
/// 公式里三个减项缺一不可：
///
/// - **减首粒度**：被裁剪过、或从直播中途接入的流，首个音频页的粒度不为 0
///   （RFC 7845 §4.5 明确允许），不减就把开头偏移算进了时长。
/// - **减 pre-skip**：编码器补的前导样本不属于内容。
/// - `last < first` 时返回 0 而不是负数：损坏文件里该情形会出现，
///   报负数时长只会让调用方更困惑。
///
/// 注意这里用的是**最后一个携带真粒度的页**的值。末页可能是 End-trim
/// （编码器把结尾的补零裁掉，granule 小于实际解出的样本数），那个值才是
/// 权威时长；`-1` 的页表示该页没有包结束，不携带时间信息，必须跳过。
///
/// **能力边界**：容器层只有「首末粒度」，拿不到「首个音频页里究竟有多少样本」。
/// 对从头开始的普通流，首粒度是 0，公式精确；对裁剪过、或从直播中途接入的流
/// （首个音频页 granule 远大于本页样本数），这里算出的值**包含起始偏移**，
/// 是一个上界。要得到精确内容时长必须解码后按样本数回推（RFC 7845 §4.5），
/// 那属于解码层的事 —— 本项目不承诺这一项。
pub fn duration_seconds(
  info : AudioInfo,
  first_granule : Int64,
  last_granule : Int64,
) -> Double {
  if last_granule <= first_granule {
    return 0.0
  }
  let span = last_granule - first_granule - info.pre_skip.to_int64()
  if span <= 0L {
    return 0.0
  }
  span.to_double() / info.sample_rate.to_double()
}
