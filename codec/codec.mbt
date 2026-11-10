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
  let family = data[18].to_int()
  if family == 0 {
    // 映射族 0 只支持单声道 / 立体声（RFC 7845 §5.1.1）
    if channels > 2 {
      return None
    }
  } else {
    // 映射族非 0：必须带 StreamCount / CoupledCount / ChannelMapping(channels)
    if data.length() < 21 + channels {
      return None
    }
    let stream_count = data[19].to_int()
    let coupled_count = data[20].to_int()
    if stream_count == 0 || coupled_count > stream_count {
      return None
    }
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
  if rd_u32(data, 7) != 0 {
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
  let block_sizes = data[28].to_int()
  let block_0 = block_sizes & 0x0F
  let block_1 = (block_sizes >> 4) & 0x0F
  if block_0 < 6 ||
    block_0 > 13 ||
    block_1 < 6 ||
    block_1 > 13 ||
    block_0 > block_1 {
    return None
  }
  if (data[29].to_int() & 1) == 0 {
    return None
  }
  Some({ codec: "Vorbis", channels, sample_rate, pre_skip: 0, })
}

///|
/// 从 `packet` 的 `start_byte` 之后、第 `bit_offset` 位起，按 LSB-first
/// 读 `n` 位（Vorbis 头内部一律 LSB-first，`n ≤ 24`）。
///
/// 越界或参数非法返回 `None`：这是「安全预检」用的读取器，**绝不读到
/// 包外**。位读取本身不做任何分配，因此可以放心在解码前的 gate 里使用。
fn read_bits_lsb(
  packet : Bytes,
  start_byte : Int32,
  bit_offset : Int32,
  n : Int32,
) -> Int32? {
  if n < 0 || n > 24 || bit_offset < 0 {
    return None
  }
  let total_bits = (packet.length() - start_byte) * 8
  if total_bits < 0 || bit_offset + n > total_bits {
    return None
  }
  let mut v = 0
  let mut i = 0
  while i < n {
    let bit_pos = bit_offset + i
    let byte_index = start_byte + bit_pos / 8
    let bit_in_byte = bit_pos % 8
    let bit = (packet[byte_index].to_int() >> bit_in_byte) & 1
    v = v | (bit << i)
    i = i + 1
  }
  Some(v)
}

///|
/// Vorbis setup 头的最小安全结构校验（解码前的 gate，C-02 兜底之一）。
///
/// 只解第一个 codebook 的头部声明，判断「声明的条目数」与「包内实际可读
/// 位数」是否自洽。C-02 的 221 B PoC 正是声明 `entries=16777215`、非 sparse
/// 却只给几十字节：第三方解码器逐条读 5 位码长时没有 bit budget 检查，
/// 会越过包尾做 `unsafe_get`（原生访问违例）。这里在做任何解码之前挡掉它。
///
/// **能力边界**：这不是完整的 Vorbis setup 解析器 —— 只校验第一个 codebook
/// 的声明自洽性；ordered codebook 以及后续 codebook/floor/residue/mapping
/// 的恶意构造仍可能让解码器崩溃（见 `pipeline/` 文件头与任务报告的残余风险）。
pub fn validate_vorbis_setup(packet : Bytes) -> Result[Unit, String] {
  if packet.length() < 8 {
    return Err(
      "setup 包过短（" + packet.length().to_string() + " 字节）",
    )
  }
  if packet[0].to_int() != 0x05 || !tag_at(packet, 1, "vorbis") {
    return Err("不是 Vorbis setup 头（缺少 0x05 + \"vorbis\" 标记）")
  }
  // setup 数据从包偏移 7 开始，按 LSB-first 位流解析。
  let start = 7
  let total_bits = (packet.length() - start) * 8
  let mut pos = 0
  let count = match read_bits_lsb(packet, start, pos, 8) {
    Some(v) => {
      pos = pos + 8
      v + 1
    }
    None => return Err("setup 头缺少 codebook 计数")
  }
  if count <= 0 {
    return Err("setup 头的 codebook 计数非法")
  }
  // 只校验第一个 codebook；codebook 数量本身有 8 位上限（≤256），
  // 真正会造成分配/越界放大的是单个 codebook 的 entries × dimensions。
  // 每个 codebook 以 24 位同步码 0x564342 开头（Vorbis I §3.2.1）。
  let sync = match read_bits_lsb(packet, start, pos, 24) {
    Some(v) => {
      pos = pos + 24
      v
    }
    None =>
      return Err("setup 头在第 1 个 codebook 的同步码处被截断")
  }
  if sync != 0x564342 {
    return Err(
      "setup 头第 1 个 codebook 的同步码不是 0x564342（已拒绝）",
    )
  }
  let dimensions = match read_bits_lsb(packet, start, pos, 16) {
    Some(v) => {
      pos = pos + 16
      v + 1
    }
    None =>
      return Err(
        "setup 头在第 1 个 codebook 的 dimensions 字段处被截断",
      )
  }
  let entries = match read_bits_lsb(packet, start, pos, 24) {
    Some(v) => {
      pos = pos + 24
      v + 1
    }
    None =>
      return Err(
        "setup 头在第 1 个 codebook 的 entries 字段处被截断",
      )
  }
  // 合理的 codebook 远小于这两个上限；超过即视为恶意/损坏的构造。
  // （阈值取宽松值，真实 Vorbis 的第一个 codebook 只有几个维度、几千条目。）
  if dimensions > 4096 || entries > 1048576 {
    return Err(
      "setup 头第 1 个 codebook 的 dimensions=" +
      dimensions.to_string() +
      " / entries=" +
      entries.to_string() +
      " 超出合理范围（已拒绝）",
    )
  }
  let ordered = match read_bits_lsb(packet, start, pos, 1) {
    Some(v) => {
      pos = pos + 1
      v
    }
    None =>
      return Err(
        "setup 头在第 1 个 codebook 的 ordered 标志处被截断",
      )
  }
  if ordered == 1 {
    // ordered codebook 的长度用变长游程编码，这里不做位预算判断；
    // 交给解码器（残余风险见函数文档）。
    return Ok(())
  }
  let sparse = match read_bits_lsb(packet, start, pos, 1) {
    Some(v) => {
      pos = pos + 1
      v
    }
    None =>
      return Err("setup 头在第 1 个 codebook 的 sparse 标志处被截断")
  }
  let remaining = total_bits - pos
  // 无序 codebook：每条目至少 1 位（sparse 时的 used 标志），非 sparse
  // 时每条目固定 5 位码长。声明的条目数超过剩余位数，就必然导致越界读。
  let required : Int64 = if sparse == 1 {
    entries.to_int64()
  } else {
    entries.to_int64() * 5L
  }
  if required > remaining.to_int64() {
    return Err(
      "setup 头声明的 codebook 条目数（" +
      entries.to_string() +
      "）与包内剩余位数不符（疑似恶意构造，已拒绝）",
    )
  }
  Ok(())
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
