// wav.mbt —— WAV（RIFF/PCM）的解析与序列化
//
// WAV 是 RIFF 容器的一个特例，结构如下：
//
//   "RIFF" | 文件长度-8 | "WAVE"
//   "fmt " | 块长(16)   | 音频格式(1=PCM) 声道数 采样率 字节率 块对齐 位深
//   "data" | 块长       | PCM 采样数据
//
// 所有多字节字段均为小端序。RIFF 规定每个块对齐到偶数字节，
// 长度为奇数的块后面会补一个填充字节 —— 遍历时必须跳过它，
// 否则后续所有块的偏移都会错位。

///|
/// WAV 的音频格式参数。
pub(all) struct WavFormat {
  channels : Int
  sample_rate : Int
  bits_per_sample : Int
}

///|
/// 一个解析后的 WAV 文件。
pub(all) struct WavFile {
  format : WavFormat
  data : Bytes
}

///|
/// 小端读取 16 位无符号整数。
fn rd_u16(data : Bytes, offset : Int) -> Int {
  data[offset].to_int() | (data[offset + 1].to_int() << 8)
}

///|
/// 小端读取 32 位无符号整数。
fn rd_u32(data : Bytes, offset : Int) -> Int {
  data[offset].to_int() |
  (data[offset + 1].to_int() << 8) |
  (data[offset + 2].to_int() << 16) |
  (data[offset + 3].to_int() << 24)
}

///|
/// 判断偏移处 4 个字节是否等于给定的 ASCII 标记。
fn tag_is(data : Bytes, offset : Int, a : Int, b : Int, c : Int, d : Int) -> Bool {
  offset + 4 <= data.length() &&
  data[offset].to_int() == a &&
  data[offset + 1].to_int() == b &&
  data[offset + 2].to_int() == c &&
  data[offset + 3].to_int() == d
}

///|
/// 解析 WAV 字节流。
///
/// 返回 `None` 表示不是合法的 WAV，或缺少必需的 `fmt ` / `data` 块。
/// 会跳过 `LIST`、`fact` 等无关块，只挑出需要的两个。
pub fn WavFile::parse(bytes : Bytes) -> WavFile? {
  if bytes.length() < 12 {
    return None
  }
  // "RIFF"
  if !tag_is(bytes, 0, 0x52, 0x49, 0x46, 0x46) {
    return None
  }
  // "WAVE"
  if !tag_is(bytes, 8, 0x57, 0x41, 0x56, 0x45) {
    return None
  }
  let mut pos = 12
  let mut format : WavFormat? = None
  let mut pcm : Bytes? = None
  while pos + 8 <= bytes.length() {
    let size = rd_u32(bytes, pos + 4)
    let body = pos + 8
    if body + size > bytes.length() {
      // 块声明的长度超出实际数据，视为损坏
      return None
    }
    if tag_is(bytes, pos, 0x66, 0x6D, 0x74, 0x20) {
      // "fmt "
      if size < 16 {
        return None
      }
      let channels = rd_u16(bytes, body + 2)
      let sample_rate = rd_u32(bytes, body + 4)
      let bits_per_sample = rd_u16(bytes, body + 14)
      format = Some({ channels, sample_rate, bits_per_sample })
    } else if tag_is(bytes, pos, 0x64, 0x61, 0x74, 0x61) {
      // "data"
      let acc = Buffer()
      let mut i = 0
      while i < size {
        acc.write_byte(bytes[body + i])
        i = i + 1
      }
      pcm = Some(acc.to_bytes())
    }
    // 块对齐到偶数字节
    pos = body + size
    if size % 2 == 1 {
      pos = pos + 1
    }
  }
  match (format, pcm) {
    (Some(f), Some(d)) => Some({ format: f, data: d })
    _ => None
  }
}

///|
/// 把音频数据序列化为 WAV 字节流。
///
/// 只写标准的 44 字节头：`RIFF` + `fmt `（16 字节 PCM）+ `data`。
/// 不做 `fact`、`LIST` 之类的扩展块 —— 转码产物越简单越不容易被拒。
pub fn encode_wav(format : WavFormat, data : Bytes) -> Bytes {
  let buf = Buffer()
  // "RIFF"
  buf.write_byte((0x52 : Byte))
  buf.write_byte((0x49 : Byte))
  buf.write_byte((0x46 : Byte))
  buf.write_byte((0x46 : Byte))
  // 文件总长减 8
  buf.write_uint_le((36 + data.length()).reinterpret_as_uint())
  // "WAVE"
  buf.write_byte((0x57 : Byte))
  buf.write_byte((0x41 : Byte))
  buf.write_byte((0x56 : Byte))
  buf.write_byte((0x45 : Byte))
  // "fmt "
  buf.write_byte((0x66 : Byte))
  buf.write_byte((0x6D : Byte))
  buf.write_byte((0x74 : Byte))
  buf.write_byte((0x20 : Byte))
  buf.write_uint_le(16U)
  // 格式 1 = 线性 PCM
  buf.write_uint16_le((1 : UInt16))
  buf.write_uint16_le(format.channels.to_uint16())
  buf.write_uint_le(format.sample_rate.reinterpret_as_uint())
  let block_align = format.channels * format.bits_per_sample / 8
  buf.write_uint_le((format.sample_rate * block_align).reinterpret_as_uint())
  buf.write_uint16_le(block_align.to_uint16())
  buf.write_uint16_le(format.bits_per_sample.to_uint16())
  // "data"
  buf.write_byte((0x64 : Byte))
  buf.write_byte((0x61 : Byte))
  buf.write_byte((0x74 : Byte))
  buf.write_byte((0x61 : Byte))
  buf.write_uint_le(data.length().reinterpret_as_uint())
  buf.write_bytes(data.exact_view())
  buf.to_bytes()
}
