// wav.mbt —— WAV（RIFF）的解析与序列化
//
// WAV 是 RIFF 容器的一个特例，结构如下：
//
//   "RIFF" | 文件长度-8 | "WAVE"
//   "fmt " | 块长       | 音频格式 声道数 采样率 字节率 块对齐 位深 [扩展字段]
//   "data" | 块长       | PCM / 浮点采样数据
//
// 支持的编码（语义对齐 Rust hound，Apache-2.0，仅移植语义，不抄代码）：
//   * fmt tag 1：整数 PCM，有效位深 8/16/24/32；
//   * fmt tag 3：IEEE 浮点，32/64 位；
//   * fmt tag 0xFFFE：WAVE_FORMAT_EXTENSIBLE，按 SubFormat GUID 判定真实编码
//     （GUID 全 16 字节比较：PCM 首字节 0x01、FLOAT 首字节 0x03；
//     布局为 base 16B + cbSize(2)@16 + validBits(2)@18 + channelMask(4)@20 +
//     SubFormat(16)@24）。
//
// 容器字节数与有效位深可以不同：每采样字节数 bytes_per_sample = block_align / channels，
// 有效位深只要不超过容器容量即可（例如 24 位采样放在 4 字节容器里的专业 WAV）。
//
// 所有多字节字段均为小端序。RIFF 规定每个块对齐到偶数字节，
// 长度为奇数的块后面会补一个填充字节 —— 遍历时必须跳过它，
// 否则后续所有块的偏移都会错位。

///|
/// WAV 的音频格式参数。
pub(all) struct WavFormat {
  channels : Int32
  sample_rate : Int32
  bits_per_sample : Int32
}

///|
/// 采样数据的类型。
///
/// 与容器位深分开：`bits_per_sample` 是有效位深，实际占用字节数由
/// `WavFile::bytes_per_sample` 给出。
pub(all) enum SampleFormat {
  Int
  Float
}

///|
/// WAV 里的一个非 `fmt `/`data` 块（LIST、fact、junk 等）。
///
/// 保存原始 fourcc 与负载，`after_data` 表示它出现在 `data` 块之后。
/// 重新编码时按原顺序写回，用于块保真（parse → to_bytes 逐字节还原）。
pub(all) struct WavChunk {
  fourcc : String
  data : Bytes
  after_data : Bool
}

///|
/// 一个解析后的 WAV 文件。
pub(all) struct WavFile {
  format : WavFormat
  data : Bytes
  /// 采样数据是整数 PCM 还是 IEEE 浮点。
  sample_format : SampleFormat
  /// 每个采样占用的容器字节数（= block_align / channels）。
  /// 可能与 `bits_per_sample / 8` 不同，例如 24 位采样放在 4 字节容器里。
  bytes_per_sample : Int32
  /// `fmt `/`data` 之外的扩展块（按文件里的顺序）。
  chunks : Array[WavChunk]
  /// WAVE_FORMAT_EXTENSIBLE 的声道掩码（普通格式为 0）；块保真往返时原样写回。
  channel_mask : Int32
  /// 解析到的原始 fmt 块负载（含 cbSize / Extensible 扩展）。
  /// `to_bytes` 原样写回，保留 16 / 18 / 40 字节等原始布局；
  /// 由编码器新建的 WavFile 走空值，按语义重新生成。
  fmt_bytes : Bytes
}

///|
/// 小端读取 16 位无符号整数。
fn rd_u16(data : Bytes, offset : Int32) -> Int32 {
  data[offset].to_int() | (data[offset + 1].to_int() << 8)
}

///|
/// 小端读取 32 位无符号整数，以 Int64 返回。
///
/// 必须用 64 位承接：MoonBit 的 `Int` 是 32 位有符号，
/// 长度字段的最高位一旦置 1（如 0x80000000），用 `Int` 读出来就是负数，
/// 会绕过「块声明长度超出实际数据」的边界检查，把损坏文件静默当成空数据放行。
fn rd_u32(data : Bytes, offset : Int32) -> Int64 {
  data[offset].to_int().to_int64() |
  (data[offset + 1].to_int().to_int64() << 8) |
  (data[offset + 2].to_int().to_int64() << 16) |
  (data[offset + 3].to_int().to_int64() << 24)
}

///|
/// 判断偏移处 4 个字节是否等于给定的 ASCII 标记。
fn tag_is(
  data : Bytes,
  offset : Int32,
  a : Int32,
  b : Int32,
  c : Int32,
  d : Int32,
) -> Bool {
  offset + 4 <= data.length() &&
  data[offset].to_int() == a &&
  data[offset + 1].to_int() == b &&
  data[offset + 2].to_int() == c &&
  data[offset + 3].to_int() == d
}

///|
/// 判断 16 字节 SubFormat GUID 是否为「Data1 低字节 = first」的标准子格式。
///
/// 标准 GUID（小端字节序）：Data1(4) Data2(2) Data3(2) Data4(8)，
/// PCM   = 00000001-0000-0010-8000-00AA00389B71，
/// FLOAT = 00000003-0000-0010-8000-00AA00389B71。
/// 必须整段比较：只比前两字节的话，伪造一个 `01 00 46 41 4B 45 …` 也能过。
fn subformat_guid_is(data : Bytes, offset : Int32, first : Int32) -> Bool {
  data[offset].to_int() == first &&
  data[offset + 1].to_int() == 0 &&
  data[offset + 2].to_int() == 0 &&
  data[offset + 3].to_int() == 0 &&
  data[offset + 4].to_int() == 0 &&
  data[offset + 5].to_int() == 0 &&
  data[offset + 6].to_int() == 0x10 &&
  data[offset + 7].to_int() == 0 &&
  data[offset + 8].to_int() == 0x80 &&
  data[offset + 9].to_int() == 0 &&
  data[offset + 10].to_int() == 0 &&
  data[offset + 11].to_int() == 0xAA &&
  data[offset + 12].to_int() == 0 &&
  data[offset + 13].to_int() == 0x38 &&
  data[offset + 14].to_int() == 0x9B &&
  data[offset + 15].to_int() == 0x71
}

///|
/// 解析 `fmt ` 块。
///
/// 返回（格式参数、采样类型、每采样容器字节数）；任何字段不一致都返回 `None`，
/// 由调用方统一当作损坏文件处理。
fn parse_fmt_chunk(
  data : Bytes,
  body : Int32,
  size : Int64,
) -> (WavFormat, SampleFormat, Int32, Int32)? {
  if size < 16L {
    return None
  }
  // 格式标签：1 = PCM，3 = IEEE float，0xFFFE = WAVE_FORMAT_EXTENSIBLE。
  // 扩展格式的**真实**编码在 SubFormat GUID 里，必须整段读出来校验 ——
  // 只看 0xFFFE 会把浮点当成整数 PCM。
  let format_tag = rd_u16(data, body + 0)
  let channels = rd_u16(data, body + 2)
  let sample_rate = rd_u32(data, body + 4).to_int()
  let byte_rate = rd_u32(data, body + 8)
  let block_align = rd_u16(data, body + 12)
  let container_bits = rd_u16(data, body + 14)
  let mut sample_format : SampleFormat = Int
  let mut channel_mask = 0
  // 默认有效位深等于容器位深；Extensible 的 validBits 可能更小（24-in-4）。
  let mut bits_per_sample = container_bits
  match format_tag {
    1 => ()
    3 => sample_format = Float
    0xFFFE => {
      // cbSize(2) + validBits(2) + channelMask(4) + SubFormat(16) ⇒ fmt 至少 40 字节
      if size < 40L {
        return None
      }
      let cb_size = rd_u16(data, body + 16)
      if cb_size < 22 {
        return None
      }
      let valid_bits = rd_u16(data, body + 18)
      if valid_bits > container_bits {
        return None
      }
      // channelMask 位于 body+20（4 字节）；保留它，块保真往返时写回原值。
      channel_mask = rd_u32(data, body + 20).to_int()
      // SubFormat GUID 全量比较，只认 PCM(0x01) 与 FLOAT(0x03)。
      if subformat_guid_is(data, body + 24, 1) {
        sample_format = Int
      } else if subformat_guid_is(data, body + 24, 3) {
        sample_format = Float
      } else {
        return None
      }
      // validBits 为 0 是老式写入器的常见情况，此时退回容器位深。
      if valid_bits > 0 {
        bits_per_sample = valid_bits
      }
    }
    _ => return None
  }
  // 声道数、采样率、有效位深为 0 都不是可用的音频格式。
  // 放过去的话，下游按 block_align = 0 去切帧会得到无穷循环或空结果。
  // 用 <= 0 而不是 == 0：u32 高位为 1 的字段读进有符号 Int 是负数，
  // 只挡 0 会让「采样率 -1 Hz」一路走到显示层。
  if channels <= 0 || sample_rate <= 0 || bits_per_sample <= 0 {
    return None
  }
  // 每采样容器字节数由 block_align / channels 决定；不整除说明块对齐被改坏。
  if block_align <= 0 || block_align % channels != 0 {
    return None
  }
  let bytes_per_sample = block_align / channels
  let container_capacity = bytes_per_sample * 8
  // 容器位深与有效位深都不能超过容器容量：
  // 允许 24 位挤进 4 字节容器，但不允许 32 位挤进 2 字节容器。
  if container_bits > container_capacity || bits_per_sample > container_capacity {
    return None
  }
  // 有效位深必须是该采样类型支持的宽度：整数 PCM 8/16/24/32，
  // 浮点只接受 32/64（16 位浮点不是 WAV 的标准形式）。
  match sample_format {
    Int =>
      if bits_per_sample != 8 &&
        bits_per_sample != 16 &&
        bits_per_sample != 24 &&
        bits_per_sample != 32 {
        return None
      }
    Float => if bits_per_sample != 32 && bits_per_sample != 64 { return None }
  }
  // 字节率必须与 block_align 一致（用 Int64 比较，避免 32 位乘法溢出）。
  if byte_rate != sample_rate.to_int64() * block_align.to_int64() {
    return None
  }
  Some(
    (
      { channels, sample_rate, bits_per_sample, },
      sample_format,
      bytes_per_sample,
      channel_mask,
    ),
  )
}

///|
/// 读取偏移处的 4 字节 fourcc 文本（RIFF 块名均为 ASCII）。
fn fourcc_text(data : Bytes, offset : Int32) -> String {
  let buf = StringBuilder()
  let mut i = 0
  while i < 4 {
    buf.write_char(data[offset + i].to_char())
    i = i + 1
  }
  buf.to_string()
}

///|
/// 拷贝字节切片 `[start, end)`。
fn wav_slice(data : Bytes, start : Int32, end : Int32) -> Bytes {
  let out = Buffer(size_hint=end - start)
  let mut i = start
  while i < end {
    out.write_byte(data[i])
    i = i + 1
  }
  out.to_bytes()
}

///|
/// 解析 WAV 字节流。
///
/// 返回 `None` 表示不是合法的 WAV，或缺少必需的 `fmt ` / `data` 块。
/// 会跳过 `LIST`、`fact` 等无关块（含奇数块后的填充字节），只挑出需要的两个。
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
  let riff_end = (riff_size + 8L).to_int()
  let mut pos = 12
  let mut format : (WavFormat, SampleFormat, Int32, Int32)? = None
  let mut pcm : Bytes? = None
  let mut fmt_raw : Bytes? = None
  let chunks : Array[WavChunk] = []
  while pos <= riff_end - 8 {
    let size = rd_u32(bytes, pos + 4)
    let body = pos + 8
    if body.to_int64() + size > riff_end.to_int64() {
      // 块声明的长度超出 RIFF 逻辑边界，视为损坏；物理尾部不能当块读取。
      return None
    }
    if tag_is(bytes, pos, 0x66, 0x6D, 0x74, 0x20) {
      // "fmt "
      match parse_fmt_chunk(bytes, body, size) {
        Some(parsed) => {
          format = Some(parsed)
          // 记住 fmt 的原始字节：24-bit tag1、18 字节 fmt、Extensible
          // 等布局在 to_bytes 时必须原样写回，否则「逐字节往返」不成立。
          fmt_raw = Some(wav_slice(bytes, body, body + size.to_int()))
        }
        None => return None
      }
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
    } else {
      // 其它块（LIST / fact / junk …）原样保留：块保真要求的正是"不认识的别丢"。
      let n = size.to_int()
      chunks.push({
        fourcc: fourcc_text(bytes, pos),
        data: wav_slice(bytes, body, body + n),
        after_data: match pcm {
          Some(_) => true
          None => false
        },
      })
    }
    // 奇数块必须在 RIFF 边界内带一个填充字节。
    pos = body + size.to_int()
    if size % 2L == 1L {
      if pos >= riff_end {
        return None
      }
      pos = pos + 1
    }
  }
  if pos != riff_end {
    return None
  }
  match (format, pcm) {
    (Some((f, sf, bps, mask)), Some(d)) => {
      let align = f.channels * bps
      if align <= 0 || d.length() % align != 0 {
        None
      } else {
        Some({
          format: f,
          data: d,
          sample_format: sf,
          bytes_per_sample: bps,
          chunks,
          channel_mask: mask,
          fmt_bytes: match fmt_raw {
            Some(raw) => raw
            None => b""
          },
        })
      }
    }
    _ => None
  }
}

///|
/// 把音频数据序列化为 WAV 字节流。
///
/// 只写标准的 44 字节头：`RIFF` + `fmt `（16 字节 PCM）+ `data`。
/// 不做 `fact`、`LIST` 之类的扩展块 —— 转码产物越简单越不容易被拒。
///
/// **前置条件**：`format` 必须是 8/16/24/32 位整数 PCM，`data` 长度必须是
/// 完整帧（声道数 × 位深/8 的整数倍）。本函数签名为 `Bytes` 而非 `Result`，
/// 不做拒绝；不满足前置条件的输入会生成无法被 `WavFile::parse` 接受的字节。
/// 需要浮点、多声道、高位深或参数校验时用 `encode_wav_ex`。
pub fn encode_wav(format : WavFormat, data : Bytes) -> Bytes {
  // 预分配恰好大小：默认的倍增扩容会在峰值时同时持有旧块与新块，
  // 对几十 MB 的 PCM 意味着多出一份完整副本。
  let pad = data.length() % 2
  let buf = Buffer(size_hint=44 + data.length() + pad)
  // "RIFF"
  buf.write_byte((0x52 : Byte))
  buf.write_byte((0x49 : Byte))
  buf.write_byte((0x46 : Byte))
  buf.write_byte((0x46 : Byte))
  // 文件总长减 8
  buf.write_uint_le((36 + data.length() + pad).reinterpret_as_uint())
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
  if pad == 1 {
    buf.write_byte((0x00 : Byte))
  }
  buf.to_bytes()
}

///|
/// 把音频数据序列化为 WAV 字节流，可指定整数或浮点采样，并做完整参数校验。
///
/// 布局选择与 hound 的编码器一致：
/// * `Int` 且声道数 <= 2 且位深 <= 16 → 16 字节 `fmt `（tag 1），
///   与 `encode_wav` 的输出**逐字节相同**；
/// * 其余（Int 高位深 / 多声道、Float 32/64）→ WAVE_FORMAT_EXTENSIBLE
///   （tag 0xFFFE、40 字节 `fmt `、validBits = 位深、channelMask = 0、
///   SubFormat GUID 区分 PCM/浮点），与 hound 一致不写 `fact` 块。
///
/// 参数不合法、或 `data` 长度不是完整帧（声道数 × 每采样字节数的整数倍）时
/// 返回 `Err`；`data` 为奇数长度时按 RIFF 规范补 0 填充。
pub fn encode_wav_ex(
  format : WavFormat,
  data : Bytes,
  sample_format : SampleFormat,
) -> Result[Bytes, String] {
  let channels = format.channels
  let sample_rate = format.sample_rate
  let bits = format.bits_per_sample
  if channels <= 0 || sample_rate <= 0 || bits <= 0 {
    return Err(
      "编码参数不合法：声道数、采样率、位深必须为正",
    )
  }
  if bits % 8 != 0 {
    return Err("编码参数不合法：位深必须是 8 的整数倍")
  }
  match sample_format {
    Int =>
      if bits != 8 && bits != 16 && bits != 24 && bits != 32 {
        return Err(
          "编码参数不合法：整数 PCM 只支持 8/16/24/32 位",
        )
      }
    Float =>
      if bits != 32 && bits != 64 {
        return Err("编码参数不合法：浮点 WAV 只支持 32/64 位")
      }
  }
  // 编码时容器恰好容纳有效位深（24 位写 3 字节）；24-in-4 只出现在解析侧。
  let bytes_per_sample = bits / 8
  if channels > 65535 {
    return Err("编码参数不合法：声道数超出 16 位字段上限")
  }
  let block_align = channels * bytes_per_sample
  if block_align > 65535 {
    return Err("编码参数不合法：块对齐超出 16 位字段上限")
  }
  // 字节率字段是 32 位无符号；先挡掉会溢出的组合，避免写出错值。
  if sample_rate > 2147483647 / block_align {
    return Err("编码参数不合法：字节率超出 32 位字段上限")
  }
  if data.length() % block_align != 0 {
    return Err(
      "data 长度不是完整帧（必须为声道数 × 每采样字节数的整数倍）",
    )
  }
  // 最简单的情形沿用原有 44 字节头，保证 `encode_wav_ex` 与 `encode_wav`
  // 在 Int/<=2 声道/<=16 位时输出逐字节一致。
  let simple_layout = match sample_format {
    Int => channels <= 2 && bits <= 16
    Float => false
  }
  if simple_layout {
    return Ok(encode_wav(format, data))
  }
  // 其余走 WAVE_FORMAT_EXTENSIBLE：40 字节 fmt、tag 0xFFFE、validBits = 位深、
  // channelMask = 0、SubFormat GUID 区分 PCM/浮点；不写 fact 块。
  let pad = data.length() % 2
  let buf = Buffer(size_hint=68 + data.length() + pad)
  // "RIFF"
  buf.write_byte((0x52 : Byte))
  buf.write_byte((0x49 : Byte))
  buf.write_byte((0x46 : Byte))
  buf.write_byte((0x46 : Byte))
  // 文件总长减 8：4("WAVE") + 8+40(fmt) + 8(data 头) + data + pad
  buf.write_uint_le((60 + data.length() + pad).reinterpret_as_uint())
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
  buf.write_uint_le(40U)
  // WAVE_FORMAT_EXTENSIBLE
  buf.write_uint16_le((0xFFFE : UInt16))
  buf.write_uint16_le(channels.to_uint16())
  buf.write_uint_le(sample_rate.reinterpret_as_uint())
  buf.write_uint_le((sample_rate * block_align).reinterpret_as_uint())
  buf.write_uint16_le(block_align.to_uint16())
  // 容器位深（= 8 × 每采样字节数）
  buf.write_uint16_le((bytes_per_sample * 8).to_uint16())
  // cbSize = 22
  buf.write_uint16_le((22 : UInt16))
  // validBits = 有效位深
  buf.write_uint16_le(bits.to_uint16())
  // channelMask = 0（未指定声道布局）
  buf.write_uint_le(0U)
  // SubFormat GUID：Data1 低字节区分 PCM(0x01)/FLOAT(0x03)，
  // 其余与标准 GUID {0000000X-0000-0010-8000-00AA00389B71} 一致。
  let sub = match sample_format {
    Int => 1
    Float => 3
  }
  buf.write_byte(sub.to_byte())
  buf.write_byte((0 : Byte))
  buf.write_byte((0 : Byte))
  buf.write_byte((0 : Byte))
  buf.write_byte((0 : Byte))
  buf.write_byte((0 : Byte))
  buf.write_byte((0x10 : Byte))
  buf.write_byte((0 : Byte))
  buf.write_byte((0x80 : Byte))
  buf.write_byte((0 : Byte))
  buf.write_byte((0 : Byte))
  buf.write_byte((0xAA : Byte))
  buf.write_byte((0 : Byte))
  buf.write_byte((0x38 : Byte))
  buf.write_byte((0x9B : Byte))
  buf.write_byte((0x71 : Byte))
  // "data"
  buf.write_byte((0x64 : Byte))
  buf.write_byte((0x61 : Byte))
  buf.write_byte((0x74 : Byte))
  buf.write_byte((0x61 : Byte))
  buf.write_uint_le(data.length().reinterpret_as_uint())
  buf.write_bytes(data.exact_view())
  if pad == 1 {
    buf.write_byte((0x00 : Byte))
  }
  Ok(buf.to_bytes())
}

// ---------- 块保真编码与流式写接口（v0.7.0） ----------

///|
/// 写一个 RIFF 块（fourcc + 长度 + 负载 + 奇数填充）。
fn write_riff_chunk(buf : Buffer, fourcc : String, payload : Bytes) -> Unit {
  let mut i = 0
  while i < 4 {
    match fourcc.get_char(i) {
      Some(c) => buf.write_byte((c.to_int() & 0xFF).to_byte())
      None => buf.write_byte((0 : Byte))
    }
    i = i + 1
  }
  buf.write_uint_le(payload.length().reinterpret_as_uint())
  buf.write_bytes(payload.exact_view())
  if payload.length() % 2 == 1 {
    buf.write_byte((0 : Byte))
  }
}

///|
/// 校验编码参数（`encode_wav_ex` / `WavFile::to_bytes` / `WavWriter` 共用）。
fn validate_format(
  format : WavFormat,
  sample_format : SampleFormat,
  bytes_per_sample : Int32,
) -> Result[Unit, String] {
  let channels = format.channels
  let sample_rate = format.sample_rate
  let bits = format.bits_per_sample
  if channels <= 0 || sample_rate <= 0 || bits <= 0 {
    return Err(
      "编码参数不合法：声道数、采样率、位深必须为正",
    )
  }
  if bits % 8 != 0 {
    return Err("编码参数不合法：位深必须是 8 的整数倍")
  }
  match sample_format {
    Int =>
      if bits != 8 && bits != 16 && bits != 24 && bits != 32 {
        return Err(
          "编码参数不合法：整数 PCM 只支持 8/16/24/32 位",
        )
      }
    Float =>
      if bits != 32 && bits != 64 {
        return Err("编码参数不合法：浮点 WAV 只支持 32/64 位")
      }
  }
  if bytes_per_sample <= 0 {
    return Err("编码参数不合法：每采样字节数必须为正")
  }
  if bits > bytes_per_sample * 8 {
    return Err("编码参数不合法：有效位深超过容器容量")
  }
  if channels > 65535 {
    return Err("编码参数不合法：声道数超出 16 位字段上限")
  }
  let block_align = channels * bytes_per_sample
  if block_align > 65535 {
    return Err("编码参数不合法：块对齐超出 16 位字段上限")
  }
  if sample_rate > 2147483647 / block_align {
    return Err("编码参数不合法：字节率超出 32 位字段上限")
  }
  Ok(())
}

///|
/// 判断 `to_bytes` 带回来的原始 fmt 负载能否原样写回。
///
/// 只信任与语义字段一致的原始布局：fmt 头里的声道 / 采样率 / 块对齐 /
/// 容器位深必须和解析结果一致，Extensible 的掩码也必须一致；
/// 任何不一致都回退到按语义重新生成，避免公开结构体被手工填坏时写出坏文件。
fn fmt_payload_matches(
  raw : Bytes,
  format : WavFormat,
  bytes_per_sample : Int32,
  channel_mask : Int32,
) -> Bool {
  let len = raw.length()
  if len < 16 || len % 2 != 0 {
    return false
  }
  let tag = rd_u16(raw, 0)
  if tag != 1 && tag != 3 && tag != 0xFFFE {
    return false
  }
  if rd_u16(raw, 2) != format.channels {
    return false
  }
  if rd_u32(raw, 4) != format.sample_rate.to_int64() {
    return false
  }
  let channels = format.channels
  let block_align = channels * bytes_per_sample
  if rd_u16(raw, 12) != block_align {
    return false
  }
  if rd_u16(raw, 14) != bytes_per_sample * 8 {
    return false
  }
  if tag == 0xFFFE {
    if len < 40 || rd_u16(raw, 16) != 22 {
      return false
    }
    if rd_u32(raw, 20).to_int() != channel_mask {
      return false
    }
  } else if len != 16 && len != 18 {
    return false
  }
  true
}

///|
/// 按「指定容器宽度 + 扩展块」编码 WAV。
///
/// 25 位这类参数不合法组合会返回 Err；`chunks` 按 `after_data` 分两段插入，
/// 顺序与文件里一致。`WavFile::to_bytes` 与 `WavWriter::finish` 都走这里。
fn encode_wav_layout(
  format : WavFormat,
  data : Bytes,
  sample_format : SampleFormat,
  bytes_per_sample : Int32,
  channel_mask : Int32,
  chunks : Array[WavChunk],
  fmt_payload : Bytes?,
) -> Result[Bytes, String] {
  match validate_format(format, sample_format, bytes_per_sample) {
    Err(msg) => return Err(msg)
    Ok(_) => ()
  }
  let channels = format.channels
  let sample_rate = format.sample_rate
  let bits = format.bits_per_sample
  let block_align = channels * bytes_per_sample
  if data.length() % block_align != 0 {
    return Err(
      "data 长度不是完整帧（必须为声道数 × 每采样字节数的整数倍）",
    )
  }
  let mut chunks_size = 0
  for c in chunks {
    if c.fourcc.length() != 4 {
      return Err("扩展块 fourcc 必须是 4 个字符: " + c.fourcc)
    }
    chunks_size = chunks_size + 8 + c.data.length() + c.data.length() % 2
  }
  // 简单布局只在「整数 + <=2 声道 + <=16 位 + 容器=有效位深」时使用，
  // 保证与 `encode_wav` 逐字节一致；扩展块不影响 fmt 布局。
  let simple = match sample_format {
    Int => channels <= 2 && bits <= 16 && bytes_per_sample * 8 == bits
    Float => false
  }
  // 解析回来的原始 fmt 布局优先（tag1+24bit、18 字节 fmt、Extensible 等）；
  // 与语义字段不一致时回退到按语义生成的布局。
  let raw_fmt : Bytes? = match fmt_payload {
    Some(raw) =>
      if fmt_payload_matches(raw, format, bytes_per_sample, channel_mask) {
        Some(raw)
      } else {
        None
      }
    None => None
  }
  let fmt_size = match raw_fmt {
    Some(raw) => raw.length()
    None => if simple { 16 } else { 40 }
  }
  let pad = data.length() % 2
  // 文件总长 = RIFF 头(8) + "WAVE"(4) + fmt 块 + 扩展块 + data 块 + padding
  let total = 12 + (8 + fmt_size) + chunks_size + 8 + data.length() + pad
  let buf = Buffer(size_hint=total)
  // "RIFF" + 文件长度-8（"WAVE" 起算）
  buf.write_byte((0x52 : Byte))
  buf.write_byte((0x49 : Byte))
  buf.write_byte((0x46 : Byte))
  buf.write_byte((0x46 : Byte))
  buf.write_uint_le((total - 8).reinterpret_as_uint())
  buf.write_byte((0x57 : Byte))
  buf.write_byte((0x41 : Byte))
  buf.write_byte((0x56 : Byte))
  buf.write_byte((0x45 : Byte))
  // fmt 块
  buf.write_byte((0x66 : Byte))
  buf.write_byte((0x6D : Byte))
  buf.write_byte((0x74 : Byte))
  buf.write_byte((0x20 : Byte))
  buf.write_uint_le(fmt_size.reinterpret_as_uint())
  match raw_fmt {
    Some(raw) => buf.write_bytes(raw.exact_view())
    None =>
      if simple {
        buf.write_uint16_le((1 : UInt16))
        buf.write_uint16_le(channels.to_uint16())
        buf.write_uint_le(sample_rate.reinterpret_as_uint())
        buf.write_uint_le((sample_rate * block_align).reinterpret_as_uint())
        buf.write_uint16_le(block_align.to_uint16())
        buf.write_uint16_le(bits.to_uint16())
      } else {
        buf.write_uint16_le((0xFFFE : UInt16))
        buf.write_uint16_le(channels.to_uint16())
        buf.write_uint_le(sample_rate.reinterpret_as_uint())
        buf.write_uint_le((sample_rate * block_align).reinterpret_as_uint())
        buf.write_uint16_le(block_align.to_uint16())
        buf.write_uint16_le((bytes_per_sample * 8).to_uint16())
        buf.write_uint16_le((22 : UInt16))
        buf.write_uint16_le(bits.to_uint16())
        buf.write_uint_le(channel_mask.reinterpret_as_uint())
        let sub = match sample_format {
          Int => 1
          Float => 3
        }
        buf.write_byte(sub.to_byte())
        buf.write_byte((0 : Byte))
        buf.write_byte((0 : Byte))
        buf.write_byte((0 : Byte))
        buf.write_byte((0 : Byte))
        buf.write_byte((0 : Byte))
        buf.write_byte((0x10 : Byte))
        buf.write_byte((0 : Byte))
        buf.write_byte((0x80 : Byte))
        buf.write_byte((0 : Byte))
        buf.write_byte((0 : Byte))
        buf.write_byte((0xAA : Byte))
        buf.write_byte((0 : Byte))
        buf.write_byte((0x38 : Byte))
        buf.write_byte((0x9B : Byte))
        buf.write_byte((0x71 : Byte))
      }
  }
  // data 之前的扩展块
  for c in chunks {
    if !c.after_data {
      write_riff_chunk(buf, c.fourcc, c.data)
    }
  }
  // data
  write_riff_chunk(buf, "data", data)
  // data 之后的扩展块
  for c in chunks {
    if c.after_data {
      write_riff_chunk(buf, c.fourcc, c.data)
    }
  }
  Ok(buf.to_bytes())
}

///|
/// 把解析后的 WAV 重新编码为字节流：保留采样格式、容器宽度与扩展块。
///
/// 用于无损往返（parse → to_bytes 逐字节还原），例如给带 LIST/fact 块
/// 或 24-in-4 容器的专业 WAV 做原地处理。参数不合法时返回 Err。
pub fn WavFile::to_bytes(self : WavFile) -> Result[Bytes, String] {
  encode_wav_layout(
    self.format,
    self.data,
    self.sample_format,
    self.bytes_per_sample,
    self.channel_mask,
    self.chunks,
    if self.fmt_bytes.length() == 0 {
      None
    } else {
      Some(self.fmt_bytes)
    },
  )
}

///|
/// 流式 WAV 写入器：调用方可以按解码块增量追加 PCM，最后一次性 finish。
///
/// 与一次性 `encode_wav_ex` 的区别只是接口形态：内部仍持有完整 PCM 缓冲
/// （MoonBit 的 `@fs` 没有 seek，真要流式落盘需要调用方自己分块写文件）。
pub(all) struct WavWriter {
  format : WavFormat
  sample_format : SampleFormat
  mut data : Buffer
  mut chunks_before : Array[WavChunk]
  mut chunks_after : Array[WavChunk]
}

///|
/// 新建写入器（参数在 finish 时统一校验）。
pub fn WavWriter::new(
  format : WavFormat,
  sample_format : SampleFormat,
) -> WavWriter {
  let writer : WavWriter = {
    format,
    sample_format,
    data: Buffer(),
    chunks_before: [],
    chunks_after: [],
  }
  writer
}

///|
/// 追加一段 PCM / 浮点采样字节（按字节追加，不对齐做逐次检查）。
pub fn WavWriter::write(self : WavWriter, pcm : Bytes) -> Unit {
  self.data.write_bytes(pcm.exact_view())
}

///|
/// 在 `data` 块之前追加一个扩展块（LIST / fact / junk …）。
pub fn WavWriter::add_chunk(
  self : WavWriter,
  fourcc : String,
  payload : Bytes,
) -> Unit {
  self.chunks_before.push({ fourcc, data: payload, after_data: false, })
}

///|
/// 在 `data` 块之后追加一个扩展块。
pub fn WavWriter::add_trailing_chunk(
  self : WavWriter,
  fourcc : String,
  payload : Bytes,
) -> Unit {
  self.chunks_after.push({ fourcc, data: payload, after_data: true, })
}

///|
/// 已写入的 PCM 字节数。
pub fn WavWriter::data_len(self : WavWriter) -> Int32 {
  self.data.length()
}

///|
/// 结束写入并生成 WAV 字节流；参数或帧对齐不合法时返回 Err。
pub fn WavWriter::finish(self : WavWriter) -> Result[Bytes, String] {
  let chunks : Array[WavChunk] = []
  for c in self.chunks_before {
    chunks.push(c)
  }
  for c in self.chunks_after {
    chunks.push(c)
  }
  encode_wav_layout(
    self.format,
    self.data.to_bytes(),
    self.sample_format,
    self.format.bits_per_sample / 8,
    0,
    chunks,
    None,
  )
}
