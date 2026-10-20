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
/// 小端读取 32 位无符号整数，以 Int64 返回。
///
/// 必须用 64 位承接：MoonBit 的 `Int` 是 32 位有符号，
/// 长度字段的最高位一旦置 1（如 0x80000000），用 `Int` 读出来就是负数，
/// 会绕过「块声明长度超出实际数据」的边界检查，把损坏文件静默当成空数据放行。
fn rd_u32(data : Bytes, offset : Int) -> Int64 {
  data[offset].to_int().to_int64() |
  (data[offset + 1].to_int().to_int64() << 8) |
  (data[offset + 2].to_int().to_int64() << 16) |
  (data[offset + 3].to_int().to_int64() << 24)
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
  // RIFF 长度字段 = 文件总长 - 8。此前这个字段被完全忽略，
  // 于是「长度字段被改坏」或「文件被截断」的文件照样能解析通过，
  // 交给下游当作合法音频。这里至少挡住截断这一类。
  let riff_size = rd_u32(bytes, 4)
  if riff_size < 4L {
    return None
  }
  if riff_size + 8L > bytes.length().to_int64() {
    return None
  }
  let mut pos = 12
  let mut format : WavFormat? = None
  let mut pcm : Bytes? = None
  while pos + 8 <= bytes.length() {
    let size = rd_u32(bytes, pos + 4)
    let body = pos + 8
    if body.to_int64() + size > bytes.length().to_int64() {
      // 块声明的长度超出实际数据，视为损坏
      return None
    }
    if tag_is(bytes, pos, 0x66, 0x6D, 0x74, 0x20) {
      // "fmt "
      if size < 16L {
        return None
      }
      // 格式标签：1 = PCM，0xFFFE = WAVE_FORMAT_EXTENSIBLE。
      // 扩展格式的**真实**编码在 SubFormat GUID 的前两个字节里，
      // 必须读出来校验 —— 只看 0xFFFE 会把 IEEE float 当成整数 PCM。
      let format_tag = rd_u16(bytes, body + 0)
      if format_tag == 0xFFFE {
        // cbSize(2) + validBits(2) + channelMask(4) + SubFormat(16) ⇒ fmt 至少 40 字节
        if size < 40L {
          return None
        }
        let cb_size = rd_u16(bytes, body + 16)
        if cb_size < 22 {
          return None
        }
        // 与标准 PCM 的 SubFormat GUID 全量比较（16 字节）：
        // 00000001-0000-0010-8000-00AA00389B71，小端字节序。
        // 只比前两字节的话，伪造一个 `01 00 46 41 4B 45 …` 也能过。
        let pcm_guid : Array[Int] = [
          1, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71,
        ]
        let mut gi = 0
        while gi < 16 {
          if bytes[body + 24 + gi].to_int() != pcm_guid[gi] {
            return None
          }
          gi = gi + 1
        }
      } else if format_tag != 1 {
        return None
      }
      let channels = rd_u16(bytes, body + 2)
      let sample_rate = rd_u32(bytes, body + 4).to_int()
      let bits_per_sample = rd_u16(bytes, body + 14)
      // 声道数、采样率、位深为 0 都不是可用的音频格式。
      // 放过去的话，下游按 block_align = 0 去切帧会得到无穷循环或空结果。
      // 用 <= 0 而不是 == 0：u32 高位为 1 的字段读进有符号 Int 是负数，
      // 只挡 0 会让「采样率 -1 Hz」一路走到显示层。
      if channels <= 0 || sample_rate <= 0 || bits_per_sample <= 0 {
        return None
      }
      format = Some({ channels, sample_rate, bits_per_sample })
    } else if tag_is(bytes, pos, 0x64, 0x61, 0x74, 0x61) {
      // "data"。经过上面的边界检查后 size 必然小于等于文件长度，
      // 此时转回 Int 是安全的。
      let n = size.to_int()
      let acc = Buffer()
      let mut i = 0
      while i < n {
        acc.write_byte(bytes[body + i])
        i = i + 1
      }
      pcm = Some(acc.to_bytes())
    }
    // 块对齐到偶数字节
    pos = body + size.to_int()
    if size % 2L == 1L {
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
  // 预分配恰好大小：默认的倍增扩容会在峰值时同时持有旧块与新块，
  // 对几十 MB 的 PCM 意味着多出一份完整副本。
  let buf = Buffer(size_hint=44 + data.length())
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
