// wav_wbtest.mbt —— WAV 读写的测试

///|
/// 编码再解析应当还原出同样的格式与数据。
test "wav encode then parse roundtrip" {
  let fmt : WavFormat = {
    channels: 2,
    sample_rate: 44100,
    bits_per_sample: 16,
  }
  let samples : Bytes = b"\x01\x02\x03\x04"
  let bytes = encode_wav(fmt, samples)
  match WavFile::parse(bytes) {
    Some(w) => {
      assert_eq(w.format.channels, 2)
      assert_eq(w.format.sample_rate, 44100)
      assert_eq(w.format.bits_per_sample, 16)
      assert_eq(w.bytes_per_sample, 2)
      match w.sample_format {
        Int => assert_true(true)
        Float => assert_true(false)
      }
      assert_eq(w.data.length(), 4)
      assert_eq(w.data[0].to_int(), 1)
      assert_eq(w.data[3].to_int(), 4)
    }
    None => assert_true(false)
  }
}

///|
/// 标准 44 字节头 + 数据：总长应为 44 + n。
test "header length is 44 bytes" {
  let fmt : WavFormat = { channels: 1, sample_rate: 8000, bits_per_sample: 8, }
  let bytes = encode_wav(fmt, b"abcd")
  assert_eq(bytes.length(), 48)
  // RIFF 长度字段 = 总长 - 8
  let declared = bytes[4].to_int() |
    (bytes[5].to_int() << 8) |
    (bytes[6].to_int() << 16) |
    (bytes[7].to_int() << 24)
  assert_eq(declared, 40)
}

///|
/// 非 WAV 数据必须被拒绝，而不是解析出垃圾。
test "reject non-wav input" {
  match WavFile::parse(b"this is definitely not a wave file") {
    None => assert_true(true)
    Some(_) => assert_true(false)
  }
  match WavFile::parse(b"RIFF") {
    None => assert_true(true)
    Some(_) => assert_true(false)
  }
}

///|
/// 声道数与位深应如实写进头里，供解码方计算块对齐。
test "format fields survive mono 8-bit" {
  let fmt : WavFormat = { channels: 1, sample_rate: 16000, bits_per_sample: 8, }
  let bytes = encode_wav(fmt, b"\x80")
  match WavFile::parse(bytes) {
    Some(w) => {
      assert_eq(w.format.channels, 1)
      assert_eq(w.format.sample_rate, 16000)
      assert_eq(w.format.bits_per_sample, 8)
    }
    None => assert_true(false)
  }
}

///|
/// RIFF 长度字段声称的尺寸超出文件实际长度时必须拒绝。
///
/// 修复前这个字段被完全忽略：把它改成 0xFFFFFFFF 也照样解析通过。
test "reject wav whose riff size exceeds the file" {
  let fmt : WavFormat = { channels: 1, sample_rate: 8000, bits_per_sample: 16, }
  let good = encode_wav(fmt, b"abcdefgh")
  let buf = Buffer()
  let mut i = 0
  while i < good.length() {
    if i >= 4 && i < 8 {
      buf.write_byte((0xFF : Byte))
    } else {
      buf.write_byte(good[i])
    }
    i = i + 1
  }
  match WavFile::parse(buf.to_bytes()) {
    None => assert_true(true)
    Some(_) => assert_true(false)
  }
}

///|
/// 声道数、采样率、位深为 0 不是可用格式，应当拒绝。
test "reject wav with zero format fields" {
  let bad : WavFormat = { channels: 0, sample_rate: 0, bits_per_sample: 0, }
  match WavFile::parse(encode_wav(bad, b"\x00\x00")) {
    None => assert_true(true)
    Some(_) => assert_true(false)
  }
}

///|
/// 块长度字段的高位被置 1 时必须拒绝，而不是当成负数放行。
///
/// 修复前 `rd_u32` 用 32 位有符号 `Int` 读长度：0x80000000 读出来是负数，
/// 「声明长度超出实际数据」的检查被绕过，copy 循环直接跳过，
/// 最后返回一个 data 为空的「合法」文件 —— 静默的错误接受。
test "reject wav whose data chunk size sets the sign bit" {
  let fmt : WavFormat = { channels: 1, sample_rate: 8000, bits_per_sample: 16, }
  let good = encode_wav(fmt, b"abcdefgh")
  // data 块长度字段在偏移 40..44，篡改为 0x80000000（小端）
  let buf = Buffer()
  let mut i = 0
  while i < good.length() {
    if i == 43 {
      buf.write_byte((0x80 : Byte))
    } else {
      buf.write_byte(good[i])
    }
    i = i + 1
  }
  match WavFile::parse(buf.to_bytes()) {
    None => assert_true(true)
    Some(_) => assert_true(false)
  }
}

///|
/// 浮点只支持 32/64 位：tag=3 + 16 位必须拒绝。
test "reject float wav with 16-bit samples" {
  let ok = encode_wav(
    { channels: 1, sample_rate: 8000, bits_per_sample: 16, },
    b"\x00\x00",
  )
  // 把 fmt 块的格式标签从 1 改成 3（IEEE float），位深仍是 16
  let buf = Buffer()
  let mut i = 0
  while i < ok.length() {
    if i == 20 {
      buf.write_byte((0x03 : Byte))
    } else if i == 21 {
      buf.write_byte((0x00 : Byte))
    } else {
      buf.write_byte(ok[i])
    }
    i = i + 1
  }
  match WavFile::parse(buf.to_bytes()) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
}

///|
/// 小端写 16 位（测试里手工拼 WAV 用）。
fn put_u16(buf : Buffer, v : Int32) -> Unit {
  buf.write_byte((v % 256).to_byte())
  buf.write_byte((v / 256 % 256).to_byte())
}

///|
/// 小端写 32 位。
fn put_u32(buf : Buffer, v : Int32) -> Unit {
  buf.write_byte((v % 256).to_byte())
  buf.write_byte((v / 256 % 256).to_byte())
  buf.write_byte((v / 65536 % 256).to_byte())
  buf.write_byte((v / 16777216 % 256).to_byte())
}

///|
/// 逐字节比较两个 Bytes。
fn bytes_eq(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut i = 0
  while i < a.length() {
    if a[i] != b[i] {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// 把 `src` 里偏移 `offset` 的 4 个字节替换成小端 `value`，用于篡改测试。
fn patch_u32(src : Bytes, offset : Int32, value : Int32) -> Bytes {
  let buf = Buffer()
  let mut i = 0
  while i < src.length() {
    if i == offset {
      put_u32(buf, value)
      i = i + 4
    } else {
      buf.write_byte(src[i])
      i = i + 1
    }
  }
  buf.to_bytes()
}

///|
/// 手工拼一个简单（非 Extensible、fmt 块 16 字节）的 WAV。
/// `block_align` 单独传入，便于构造「24 位采样放 4 字节容器」这类专业 WAV。
fn build_wav_simple(
  tag : Int32,
  channels : Int32,
  sample_rate : Int32,
  block_align : Int32,
  bits : Int32,
  data : Bytes,
) -> Bytes {
  let data_len = data.length()
  let pad = data_len % 2
  let total = 12 + 8 + 16 + 8 + data_len + pad
  let buf = Buffer()
  buf.write_bytes(b"RIFF".exact_view())
  put_u32(buf, total - 8)
  buf.write_bytes(b"WAVE".exact_view())
  buf.write_bytes(b"fmt ".exact_view())
  put_u32(buf, 16)
  put_u16(buf, tag)
  put_u16(buf, channels)
  put_u32(buf, sample_rate)
  put_u32(buf, sample_rate * block_align)
  put_u16(buf, block_align)
  put_u16(buf, bits)
  buf.write_bytes(b"data".exact_view())
  put_u32(buf, data_len)
  buf.write_bytes(data.exact_view())
  if pad == 1 {
    buf.write_byte((0 : Byte))
  }
  buf.to_bytes()
}

///|
/// 手工拼一个 WAVE_FORMAT_EXTENSIBLE 的 WAV。
///
/// `sub` 是 SubFormat GUID 的 Data1 低字节（1 = PCM，3 = IEEE float，其它为未知格式）；
/// `container_bits` 是 fmt 里的容器位深，`valid_bits` 是 validBitsPerSample
/// （24-in-4 这类专业 WAV 里二者不同）。
fn build_wav_ext(
  sub : Int32,
  channels : Int32,
  sample_rate : Int32,
  container_bits : Int32,
  valid_bits : Int32,
  block_align : Int32,
  data : Bytes,
) -> Bytes {
  let data_len = data.length()
  let pad = data_len % 2
  let fmt_size = 40
  let total = 12 + 8 + fmt_size + 8 + data_len + pad
  let buf = Buffer()
  buf.write_bytes(b"RIFF".exact_view())
  put_u32(buf, total - 8)
  buf.write_bytes(b"WAVE".exact_view())
  buf.write_bytes(b"fmt ".exact_view())
  put_u32(buf, fmt_size)
  put_u16(buf, 0xFFFE) // wFormatTag = EXTENSIBLE
  put_u16(buf, channels)
  put_u32(buf, sample_rate)
  put_u32(buf, sample_rate * block_align)
  put_u16(buf, block_align)
  put_u16(buf, container_bits) // 容器位深
  put_u16(buf, 22) // cbSize
  put_u16(buf, valid_bits) // validBitsPerSample
  put_u32(buf, 4) // channelMask
  // SubFormat GUID（16 字节）：Data1 = sub（4 字节）、Data2 = 0（2）、
  // Data3 = 0x0010（2）、Data4 = 80 00 00 AA 00 38 9B 71（8）
  put_u16(buf, sub)
  put_u16(buf, 0)
  put_u16(buf, 0)
  put_u16(buf, 0x0010)
  buf.write_byte((0x80 : Byte))
  buf.write_byte((0x00 : Byte))
  buf.write_byte((0x00 : Byte))
  buf.write_byte((0xAA : Byte))
  buf.write_byte((0x00 : Byte))
  buf.write_byte((0x38 : Byte))
  buf.write_byte((0x9B : Byte))
  buf.write_byte((0x71 : Byte))
  buf.write_bytes(b"data".exact_view())
  put_u32(buf, data_len)
  buf.write_bytes(data.exact_view())
  if pad == 1 {
    buf.write_byte((0 : Byte))
  }
  buf.to_bytes()
}

///|
/// 奇数长度 data 块必须补 RIFF 对齐字节，RIFF size 也要把它算进去。
test "odd data chunks are padded and roundtrip" {
  for bits in [8, 24] {
    let fmt : WavFormat = {
      channels: 1,
      sample_rate: 8000,
      bits_per_sample: bits,
    }
    let data : Bytes = b"\x01\x02\x03"
    let encoded = encode_wav(fmt, data)
    assert_eq(encoded.length(), 44 + 4)
    // RIFF size = 36 + 3 字节数据 + 1 字节 padding
    let declared = encoded[4].to_int() |
      (encoded[5].to_int() << 8) |
      (encoded[6].to_int() << 16) |
      (encoded[7].to_int() << 24)
    assert_eq(declared, 40)
    assert_eq(encoded[encoded.length() - 1].to_int(), 0)
    match WavFile::parse(encoded) {
      Some(w) => {
        assert_eq(w.data.length(), 3)
        assert_eq(w.format.bits_per_sample, bits)
      }
      None => assert_true(false)
    }
  }
}

///|
/// 奇数 data 块缺少 padding、RIFF 声明过小、数据不是完整帧都必须拒绝。
test "reject malformed riff boundaries and pcm alignment" {
  let fmt : WavFormat = { channels: 1, sample_rate: 8000, bits_per_sample: 24, }
  let good = encode_wav(fmt, b"\x01\x02\x03")
  // 去掉 padding 并把 RIFF size 改为与实际物理长度一致
  let sliced = good[0:good.length() - 1]
  let no_pad = Buffer()
  let mut i = 0
  while i < sliced.length() {
    if i == 4 {
      no_pad.write_byte((39 : Byte))
      no_pad.write_byte((0 : Byte))
      no_pad.write_byte((0 : Byte))
      no_pad.write_byte((0 : Byte))
      i = i + 4
    } else {
      no_pad.write_byte(sliced[i])
      i = i + 1
    }
  }
  match WavFile::parse(no_pad.to_bytes()) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }

  // RIFF 逻辑上只含 "WAVE"，物理文件后的块不能被当成容器内容
  let too_small = Buffer()
  let mut j = 0
  while j < good.length() {
    if j == 4 {
      too_small.write_byte((4 : Byte))
      too_small.write_byte((0 : Byte))
      too_small.write_byte((0 : Byte))
      too_small.write_byte((0 : Byte))
      j = j + 4
    } else {
      too_small.write_byte(good[j])
      j = j + 1
    }
  }
  match WavFile::parse(too_small.to_bytes()) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }

  // 16 位单声道 data 不是 2 字节的整数倍 → 缺半帧
  let misaligned = encode_wav(
    { channels: 1, sample_rate: 8000, bits_per_sample: 16, },
    b"\x01\x02\x03\x04\x05",
  )
  match WavFile::parse(misaligned) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
}

///|
/// EXTENSIBLE + PCM 子格式应当接受。
test "accept extensible wav whose subformat is pcm" {
  match
    WavFile::parse(build_wav_ext(1, 1, 8000, 16, 16, 2, b"\x00\x00\x00\x00")) {
    Some(f) => {
      assert_eq(f.format.channels, 1)
      assert_eq(f.format.sample_rate, 8000)
      assert_eq(f.format.bits_per_sample, 16)
      assert_eq(f.bytes_per_sample, 2)
      match f.sample_format {
        Int => assert_true(true)
        Float => assert_true(false)
      }
    }
    None => assert_true(false)
  }
}

///|
/// EXTENSIBLE + IEEE float（SubFormat GUID 首字节 0x03）应当接受。
test "accept extensible wav whose subformat is float" {
  match
    WavFile::parse(build_wav_ext(3, 1, 8000, 32, 32, 4, b"\x00\x00\x80\x3f")) {
    Some(f) => {
      assert_eq(f.format.channels, 1)
      assert_eq(f.format.sample_rate, 8000)
      assert_eq(f.format.bits_per_sample, 32)
      assert_eq(f.bytes_per_sample, 4)
      match f.sample_format {
        Float => assert_true(true)
        Int => assert_true(false)
      }
    }
    None => assert_true(false)
  }
}

///|
/// EXTENSIBLE 但 fmt 块只有 16 字节（没有 cbSize 与 GUID）必须拒绝。
test "reject truncated extensible fmt block" {
  let data_len = 4
  let fmt_size = 16
  let total = 12 + 8 + fmt_size + 8 + data_len
  let buf = Buffer()
  buf.write_bytes(b"RIFF".exact_view())
  put_u32(buf, total - 8)
  buf.write_bytes(b"WAVE".exact_view())
  buf.write_bytes(b"fmt ".exact_view())
  put_u32(buf, fmt_size)
  put_u16(buf, 0xFFFE)
  put_u16(buf, 1)
  put_u32(buf, 8000)
  put_u32(buf, 16000)
  put_u16(buf, 2)
  put_u16(buf, 16)
  buf.write_bytes(b"data".exact_view())
  put_u32(buf, data_len)
  put_u16(buf, 0)
  put_u16(buf, 0)
  match WavFile::parse(buf.to_bytes()) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
}

///|
/// SubFormat GUID 前两字节对、尾部被伪造 → 必须拒绝。
///
/// 只比较 `wFormatTag` 两个字节的话，`01 00 46 41 4B 45 ...` 这种
/// 伪造 GUID 会被当成 PCM。
test "reject extensible wav with a forged subformat guid" {
  let full = build_wav_ext(1, 1, 8000, 16, 16, 2, b"\x00\x00\x00\x00")
  // fmt 体起点 20，GUID 在 +24 → 44；Data4 首字节在 44 + 8 = 52
  let buf = Buffer()
  let mut i = 0
  while i < full.length() {
    if i == 52 {
      buf.write_byte((0x46 : Byte))
    } else {
      buf.write_byte(full[i])
    }
    i = i + 1
  }
  match WavFile::parse(buf.to_bytes()) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
}

///|
/// Extensible 未知 SubFormat GUID（如 0x02）必须拒绝。
test "reject extensible wav with unknown subformat guid" {
  match
    WavFile::parse(build_wav_ext(2, 1, 8000, 32, 32, 4, b"\x00\x00\x00\x00")) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
}

///|
/// 24 位采样放在 4 字节容器里：Extensible（容器 32 位 + validBits 24）应接受。
test "accept 24-in-4 pcm extensible wav" {
  let data : Bytes = b"\x01\x02\x03\x04\x05\x06\x07\x08"
  match WavFile::parse(build_wav_ext(1, 1, 8000, 32, 24, 4, data)) {
    Some(f) => {
      assert_eq(f.format.channels, 1)
      assert_eq(f.format.sample_rate, 8000)
      // bits_per_sample 报告有效位深，bytes_per_sample 报告容器大小
      assert_eq(f.format.bits_per_sample, 24)
      assert_eq(f.bytes_per_sample, 4)
      match f.sample_format {
        Int => assert_true(true)
        Float => assert_true(false)
      }
      assert_eq(f.data.length(), 8)
    }
    None => assert_true(false)
  }
}

///|
/// 24 位采样放在 4 字节容器里：老式 tag=1 且 block_align = 4 × 声道数也应接受。
test "accept 24-in-4 pcm tag 1 wav" {
  let data : Bytes = b"\x01\x02\x03\x04"
  match WavFile::parse(build_wav_simple(1, 1, 8000, 4, 24, data)) {
    Some(f) => {
      assert_eq(f.format.bits_per_sample, 24)
      assert_eq(f.bytes_per_sample, 4)
      assert_eq(f.data.length(), 4)
    }
    None => assert_true(false)
  }
}

///|
/// 无效组合必须拒绝：bits=20、块对齐不是整数倍、字节率不一致、数据缺帧。
test "reject invalid format combinations" {
  // bits = 20 不是 PCM 支持的有效位深
  match WavFile::parse(build_wav_simple(1, 1, 8000, 3, 20, b"\x01\x02\x03")) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
  // block_align 3 不是声道数 2 的整数倍
  match WavFile::parse(build_wav_simple(1, 2, 8000, 3, 16, b"\x01\x02\x03")) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
  // 字节率与 sample_rate × block_align 不一致
  let ok = build_wav_simple(1, 1, 8000, 2, 16, b"\x00\x00")
  match WavFile::parse(patch_u32(ok, 28, 9999)) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
  // data 长度不是完整帧
  match WavFile::parse(build_wav_simple(1, 1, 8000, 2, 16, b"\x01\x02\x03")) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
  // validBits 大于容器位深
  match WavFile::parse(build_wav_ext(1, 1, 8000, 16, 20, 2, b"\x00\x00")) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
}

///|
/// 未知块（LIST/junk/fact 等）必须跳过，奇数长度的未知块还要跳过填充字节。
test "skip unknown chunks with odd size and padding" {
  // 布局：RIFF + WAVE + fmt(16) + junk(3+1 pad) + data(4)
  // 总长 = 12 + 24 + 12 + 12 = 60，RIFF size = 52
  let buf = Buffer()
  buf.write_bytes(b"RIFF".exact_view())
  put_u32(buf, 52)
  buf.write_bytes(b"WAVE".exact_view())
  buf.write_bytes(b"fmt ".exact_view())
  put_u32(buf, 16)
  put_u16(buf, 1)
  put_u16(buf, 1)
  put_u32(buf, 8000)
  put_u32(buf, 16000)
  put_u16(buf, 2)
  put_u16(buf, 16)
  buf.write_bytes(b"junk".exact_view())
  put_u32(buf, 3)
  buf.write_byte((0xAA : Byte))
  buf.write_byte((0xBB : Byte))
  buf.write_byte((0xCC : Byte))
  buf.write_byte((0 : Byte)) // 奇数块填充
  buf.write_bytes(b"data".exact_view())
  put_u32(buf, 4)
  put_u16(buf, 0x0102)
  put_u16(buf, 0x0304)
  match WavFile::parse(buf.to_bytes()) {
    Some(w) => {
      assert_eq(w.format.channels, 1)
      assert_eq(w.format.sample_rate, 8000)
      assert_eq(w.format.bits_per_sample, 16)
      assert_eq(w.data.length(), 4)
      // put_u16(0x0102) / put_u16(0x0304) 写出的小端字节：02 01 04 03
      assert_eq(w.data[0].to_int(), 2)
      assert_eq(w.data[3].to_int(), 3)
    }
    None => assert_true(false)
  }
}

///|
/// 手写简单 fmt tag=3 的 float32 WAV（非 Extensible）必须能解析。
test "accept hand-written tag 3 float32 wav" {
  // 1.0f 的 4 字节小端表示
  let data : Bytes = b"\x00\x00\x80\x3f"
  match WavFile::parse(build_wav_simple(3, 1, 8000, 4, 32, data)) {
    Some(f) => {
      assert_eq(f.format.channels, 1)
      assert_eq(f.format.sample_rate, 8000)
      assert_eq(f.format.bits_per_sample, 32)
      assert_eq(f.bytes_per_sample, 4)
      match f.sample_format {
        Float => assert_true(true)
        Int => assert_true(false)
      }
      assert_eq(f.data.length(), 4)
      assert_eq(f.data[0].to_int(), 0)
      assert_eq(f.data[3].to_int(), 0x3F)
    }
    None => assert_true(false)
  }
}

///|
/// Int 且 <=2 声道且 <=16 位时，encode_wav_ex 的输出必须与 encode_wav 逐字节相同。
test "encode_wav_ex simple layout is byte-identical to encode_wav" {
  let cases : Array[WavFormat] = [
    { channels: 1, sample_rate: 8000, bits_per_sample: 8, },
    { channels: 2, sample_rate: 44100, bits_per_sample: 16, },
  ]
  let data : Bytes = b"\x01\x02\x03\x04\x05\x06\x07\x08"
  for fmt in cases {
    match encode_wav_ex(fmt, data, Int) {
      Ok(encoded) => {
        assert_true(bytes_eq(encoded, encode_wav(fmt, data)))
        assert_eq(encoded.length(), 44 + 8)
        // tag = 1、fmt 块长 = 16
        assert_eq(encoded[20].to_int(), 1)
        assert_eq(encoded[21].to_int(), 0)
        assert_eq(encoded[16].to_int(), 16)
      }
      Err(_) => assert_true(false)
    }
  }
}

///|
/// Int 高位深（>16 位）走 Extensible 布局，并能解析往返。
test "encode_wav_ex int 24 bit uses extensible and roundtrips" {
  let fmt : WavFormat = { channels: 1, sample_rate: 8000, bits_per_sample: 24, }
  let data : Bytes = b"\x01\x02\x03\x04\x05\x06"
  match encode_wav_ex(fmt, data, Int) {
    Ok(encoded) => {
      assert_eq(encoded.length(), 68 + 6)
      // fmt 块长 40、tag 0xFFFE
      assert_eq(encoded[16].to_int(), 40)
      assert_eq(encoded[20].to_int(), 0xFE)
      assert_eq(encoded[21].to_int(), 0xFF)
      // block_align = 3（24 位容器 3 字节）
      assert_eq(encoded[32].to_int(), 3)
      // 容器位深 = 24、validBits = 24
      assert_eq(encoded[34].to_int(), 24)
      assert_eq(encoded[38].to_int(), 24)
      // SubFormat GUID 首字节 = 0x01（PCM）
      assert_eq(encoded[44].to_int(), 1)
      match WavFile::parse(encoded) {
        Some(w) => {
          assert_eq(w.format.bits_per_sample, 24)
          assert_eq(w.bytes_per_sample, 3)
          match w.sample_format {
            Int => assert_true(true)
            Float => assert_true(false)
          }
          assert_eq(w.data.length(), 6)
          assert_eq(w.data[5].to_int(), 6)
        }
        None => assert_true(false)
      }
    }
    Err(_) => assert_true(false)
  }
}

///|
/// float32 走 Extensible（tag 0xFFFE、GUID 首字节 0x03），并能解析往返。
test "encode_wav_ex float32 roundtrips with extensible header" {
  let fmt : WavFormat = { channels: 1, sample_rate: 8000, bits_per_sample: 32, }
  // 1.0f
  let data : Bytes = b"\x00\x00\x80\x3f"
  match encode_wav_ex(fmt, data, Float) {
    Ok(encoded) => {
      assert_eq(encoded.length(), 68 + 12 + 4)
      assert_eq(encoded[16].to_int(), 40) // fmt 块长
      assert_eq(encoded[20].to_int(), 0xFE) // tag 低字节
      assert_eq(encoded[21].to_int(), 0xFF) // tag 高字节
      assert_eq(encoded[32].to_int(), 4) // block_align
      assert_eq(encoded[34].to_int(), 32) // 容器位深
      assert_eq(encoded[36].to_int(), 22) // cbSize
      assert_eq(encoded[38].to_int(), 32) // validBits
      // channelMask = 0
      assert_eq(encoded[40].to_int(), 0)
      assert_eq(encoded[41].to_int(), 0)
      assert_eq(encoded[42].to_int(), 0)
      assert_eq(encoded[43].to_int(), 0)
      // SubFormat GUID：FLOAT = 00000003-0000-0010-8000-00AA00389B71
      let float_guid : Array[Int32] = [
        0x03, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71,
      ]
      let mut gi = 0
      while gi < 16 {
        assert_eq(encoded[44 + gi].to_int(), float_guid[gi])
        gi = gi + 1
      }
      // fact 块（紧接 fmt 之后，偏移 60）：浮点 WAV 声明样本帧数（1 帧）
      assert_eq(encoded[60].to_int(), 0x66) // 'f'
      assert_eq(encoded[61].to_int(), 0x61) // 'a'
      assert_eq(encoded[62].to_int(), 0x63) // 'c'
      assert_eq(encoded[63].to_int(), 0x74) // 't'
      assert_eq(encoded[64].to_int(), 4) // fact 负载长度（小端）
      assert_eq(encoded[68].to_int(), 1) // 样本帧数（小端）
      match WavFile::parse(encoded) {
        Some(w) => {
          assert_eq(w.format.channels, 1)
          assert_eq(w.format.sample_rate, 8000)
          assert_eq(w.format.bits_per_sample, 32)
          assert_eq(w.bytes_per_sample, 4)
          match w.sample_format {
            Float => assert_true(true)
            Int => assert_true(false)
          }
          assert_eq(w.data.length(), 4)
          assert_eq(w.data[3].to_int(), 0x3F)
        }
        None => assert_true(false)
      }
    }
    Err(_) => assert_true(false)
  }
}

///|
/// float64 走 Extensible（GUID 首字节 0x03、容器 8 字节），并能解析往返。
test "encode_wav_ex float64 roundtrips with extensible header" {
  let fmt : WavFormat = { channels: 1, sample_rate: 8000, bits_per_sample: 64, }
  // 1.0 的双精度小端表示
  let data : Bytes = b"\x00\x00\x00\x00\x00\x00\xf0\x3f"
  match encode_wav_ex(fmt, data, Float) {
    Ok(encoded) => {
      assert_eq(encoded.length(), 68 + 12 + 8)
      assert_eq(encoded[20].to_int(), 0xFE)
      assert_eq(encoded[32].to_int(), 8) // block_align
      assert_eq(encoded[34].to_int(), 64) // 容器位深
      assert_eq(encoded[38].to_int(), 64) // validBits
      assert_eq(encoded[44].to_int(), 3) // GUID: FLOAT
      assert_eq(encoded[58].to_int(), 0x9B)
      assert_eq(encoded[59].to_int(), 0x71)
      // fact：紧接 fmt 之后，1 帧
      assert_eq(encoded[60].to_int(), 0x66)
      assert_eq(encoded[68].to_int(), 1)
      match WavFile::parse(encoded) {
        Some(w) => {
          assert_eq(w.format.bits_per_sample, 64)
          assert_eq(w.bytes_per_sample, 8)
          match w.sample_format {
            Float => assert_true(true)
            Int => assert_true(false)
          }
          assert_eq(w.data.length(), 8)
          assert_eq(w.data[7].to_int(), 0x3F)
        }
        None => assert_true(false)
      }
    }
    Err(_) => assert_true(false)
  }
}

///|
/// encode_wav_ex 对非法参数与不完整帧必须返回 Err。
test "encode_wav_ex rejects invalid parameters" {
  // float + 16 位
  match
    encode_wav_ex(
      { channels: 1, sample_rate: 8000, bits_per_sample: 16, },
      b"\x00\x00",
      Float,
    ) {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
  // bits = 20
  match
    encode_wav_ex(
      { channels: 1, sample_rate: 8000, bits_per_sample: 20, },
      b"\x00\x00\x00",
      Int,
    ) {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
  // data 不是完整帧（2 声道 × 2 字节 = 4 字节一帧，给 3 字节）
  match
    encode_wav_ex(
      { channels: 2, sample_rate: 8000, bits_per_sample: 16, },
      b"\x00\x00\x00",
      Int,
    ) {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
  // 声道数为 0
  match
    encode_wav_ex(
      { channels: 0, sample_rate: 8000, bits_per_sample: 16, },
      b"\x00\x00",
      Int,
    ) {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
}

// ---------- v0.7.0：块保真 + 流式写接口 ----------

///|
/// 手工拼一个带 LIST（data 前、奇数长度）与 fact（data 后）的 WAV。
fn build_wav_with_chunks() -> Bytes {
  let pcm : Bytes = b"\x01\x02\x03\x04"
  let buf = Buffer()
  buf.write_bytes(b"RIFF".exact_view())
  put_u32(buf, 64) // 12 + 24(fmt) + 12(LIST+pad) + 12(data) + 12(fact) - 8
  buf.write_bytes(b"WAVE".exact_view())
  buf.write_bytes(b"fmt ".exact_view())
  put_u32(buf, 16)
  put_u16(buf, 1)
  put_u16(buf, 1)
  put_u32(buf, 8000)
  put_u32(buf, 16000)
  put_u16(buf, 2)
  put_u16(buf, 16)
  buf.write_bytes(b"LIST".exact_view())
  put_u32(buf, 3)
  buf.write_byte((0xAA : Byte))
  buf.write_byte((0xBB : Byte))
  buf.write_byte((0xCC : Byte))
  buf.write_byte((0 : Byte)) // 奇数块填充
  buf.write_bytes(b"data".exact_view())
  put_u32(buf, 4)
  buf.write_bytes(pcm.exact_view())
  buf.write_bytes(b"fact".exact_view())
  put_u32(buf, 4)
  put_u32(buf, 2) // 采样帧数
  buf.to_bytes()
}

///|
test "unknown chunks are collected and preserved byte-for-byte" {
  let original = build_wav_with_chunks()
  match WavFile::parse(original) {
    Some(w) => {
      assert_eq(w.chunks.length(), 2)
      assert_eq(w.chunks[0].fourcc, "LIST")
      assert_eq(w.chunks[0].after_data, false)
      assert_eq(w.chunks[0].data.length(), 3)
      assert_eq(w.chunks[1].fourcc, "fact")
      assert_eq(w.chunks[1].after_data, true)
      match w.to_bytes() {
        Ok(out) => assert_true(bytes_eq(original, out))
        Err(msg) => {
          println("to_bytes error: " + msg)
          assert_true(false)
        }
      }
    }
    None => assert_true(false)
  }
}

///|
test "24-in-4 extensible wav roundtrips byte-for-byte (incl channel mask)" {
  let original = build_wav_ext(1, 1, 48000, 32, 24, 4, b"\x01\x02\x03\x04")
  match WavFile::parse(original) {
    Some(w) => {
      assert_eq(w.bytes_per_sample, 4)
      assert_eq(w.format.bits_per_sample, 24)
      assert_eq(w.channel_mask, 4)
      match w.to_bytes() {
        Ok(out) => assert_true(bytes_eq(original, out))
        Err(_) => assert_true(false)
      }
    }
    None => assert_true(false)
  }
}

///|
test "float32 encode->parse->to_bytes is byte-identical" {
  match
    encode_wav_ex(
      { channels: 1, sample_rate: 8000, bits_per_sample: 32, },
      b"\x00\x00\x80\x3f",
      Float,
    ) {
    Err(_) => assert_true(false)
    Ok(original) =>
      match WavFile::parse(original) {
        Some(w) =>
          match w.to_bytes() {
            Ok(out) => assert_true(bytes_eq(original, out))
            Err(_) => assert_true(false)
          }
        None => assert_true(false)
      }
  }
}

///|
test "wav writer output equals encode_wav_ex for int and float" {
  let cases : Array[(WavFormat, SampleFormat, Bytes)] = [
    (
      { channels: 1, sample_rate: 8000, bits_per_sample: 16, },
      Int,
      b"\x01\x02\x03\x04",
    ),
    (
      { channels: 2, sample_rate: 44100, bits_per_sample: 24, },
      Int,
      b"\x01\x02\x03\x04\x05\x06",
    ),
    (
      { channels: 1, sample_rate: 48000, bits_per_sample: 32, },
      Float,
      b"\x00\x00\x80\x3f\x00\x00\x00\x40",
    ),
  ]
  for c in cases {
    let (format, sf, data) = c
    match encode_wav_ex(format, data, sf) {
      Err(_) => assert_true(false)
      Ok(expected) => {
        let writer = WavWriter::new(format, sf)
        // 分两段追加，验证增量写入
        let half = data.length() / 2
        let first : Bytes = wav_slice(data, 0, half)
        let second : Bytes = wav_slice(data, half, data.length())
        writer.write(first)
        writer.write(second)
        assert_eq(writer.data_len(), data.length())
        match writer.finish() {
          Ok(out) => assert_true(bytes_eq(expected, out))
          Err(_) => assert_true(false)
        }
      }
    }
  }
}

///|
test "wav writer keeps chunks before and after data" {
  let writer = WavWriter::new(
    { channels: 1, sample_rate: 8000, bits_per_sample: 16, },
    Int,
  )
  writer.write(b"\x01\x02\x03\x04")
  writer.add_chunk("LIST", b"\xAA\xBB")
  writer.add_trailing_chunk("fact", b"\x02\x00\x00\x00")
  match writer.finish() {
    Err(_) => assert_true(false)
    Ok(bytes) =>
      match WavFile::parse(bytes) {
        Some(w) => {
          assert_eq(w.chunks.length(), 2)
          assert_eq(w.chunks[0].fourcc, "LIST")
          assert_eq(w.chunks[0].after_data, false)
          assert_eq(w.chunks[1].fourcc, "fact")
          assert_eq(w.chunks[1].after_data, true)
          assert_eq(w.data.length(), 4)
        }
        None => assert_true(false)
      }
  }
}

///|
test "wav writer rejects misaligned pcm" {
  let writer = WavWriter::new(
    { channels: 1, sample_rate: 8000, bits_per_sample: 16, },
    Int,
  )
  writer.write(b"\x01") // 不是完整帧
  match writer.finish() {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
}

// ---------- v0.7.0：块保真编码器的错误分支 ----------

///|
/// 直接调用 `validate_format` 覆盖各条拒绝分支（私有函数，whitebox 测试可见）。
test "validate_format rejects each invalid combination" {
  // 位深 12 不是 8 的倍数
  assert_true(
    match
      validate_format(
        { channels: 1, sample_rate: 8000, bits_per_sample: 12, },
        Int,
        2,
      ) {
      Err(_) => true
      Ok(_) => false
    },
  )
  // 浮点 16 位不支持
  assert_true(
    match
      validate_format(
        { channels: 1, sample_rate: 8000, bits_per_sample: 16, },
        Float,
        2,
      ) {
      Err(_) => true
      Ok(_) => false
    },
  )
  // 每采样字节数为 0
  assert_true(
    match
      validate_format(
        { channels: 1, sample_rate: 8000, bits_per_sample: 16, },
        Int,
        0,
      ) {
      Err(_) => true
      Ok(_) => false
    },
  )
  // 有效位深超过容器容量（16 位塞进 1 字节）
  assert_true(
    match
      validate_format(
        { channels: 1, sample_rate: 8000, bits_per_sample: 16, },
        Int,
        1,
      ) {
      Err(_) => true
      Ok(_) => false
    },
  )
  // 声道数超出 16 位字段
  assert_true(
    match
      validate_format(
        { channels: 70000, sample_rate: 8000, bits_per_sample: 8, },
        Int,
        1,
      ) {
      Err(_) => true
      Ok(_) => false
    },
  )
  // 块对齐超出 16 位字段（30000 声道 × 3 字节）
  assert_true(
    match
      validate_format(
        { channels: 30000, sample_rate: 8000, bits_per_sample: 24, },
        Int,
        3,
      ) {
      Err(_) => true
      Ok(_) => false
    },
  )
  // 字节率超出 32 位字段
  assert_true(
    match
      validate_format(
        { channels: 1, sample_rate: 2147483647, bits_per_sample: 16, },
        Int,
        2,
      ) {
      Err(_) => true
      Ok(_) => false
    },
  )
}

///|
/// 扩展块 fourcc 不是 4 个字符时必须拒绝；write_riff_chunk 对短 fourcc 补 0。
test "encode_wav_layout rejects bad chunk fourcc" {
  let format : WavFormat = {
    channels: 1,
    sample_rate: 8000,
    bits_per_sample: 16,
  }
  let bad : Array[WavChunk] = [
    { fourcc: "LIS", data: b"\x01", after_data: false, },
  ]
  assert_true(
    match encode_wav_layout(format, b"\x00\x00", Int, 2, 0, bad, None) {
      Err(_) => true
      Ok(_) => false
    },
  )
  // write_riff_chunk 对不足 4 字符的 fourcc 用 0 补齐（仅用于防御性分支覆盖）
  let buf = Buffer()
  write_riff_chunk(buf, "AB", b"\x01")
  assert_true(buf.length() > 0)
}

///|
/// 编码器对非法参数直接返回 Err（覆盖 encode_wav_layout 的入口校验分支）。
test "encode_wav_layout rejects invalid format and misaligned data" {
  let bad_format : WavFormat = {
    channels: 0,
    sample_rate: 8000,
    bits_per_sample: 16,
  }
  assert_true(
    match encode_wav_layout(bad_format, b"", Int, 2, 0, [], None) {
      Err(_) => true
      Ok(_) => false
    },
  )
  let format : WavFormat = {
    channels: 1,
    sample_rate: 8000,
    bits_per_sample: 16,
  }
  assert_true(
    match encode_wav_layout(format, b"\x00", Int, 2, 0, [], None) {
      Err(_) => true
      Ok(_) => false
    },
  )
}

///|
/// 解析侧：fmt 太短、cbSize 太小、validBits 超过容器位深都必须拒绝。
test "parse rejects short fmt, small cbsize and oversized valid bits" {
  // fmt 块声明长度为 8（<16）
  let short_fmt = patch_u32(
    build_wav_simple(1, 1, 8000, 2, 16, b"\x00\x00"),
    16,
    8,
  )
  assert_true(
    match WavFile::parse(short_fmt) {
      None => true
      Some(_) => false
    },
  )
  // cbSize 改成 0（Extensible 至少 22）
  let ext = build_wav_ext(1, 1, 8000, 16, 16, 2, b"\x00\x00")
  let zero_cb = patch_u32(ext, 36, 0) // fmt body 起点 20，cbSize 在 +16
  assert_true(
    match WavFile::parse(zero_cb) {
      None => true
      Some(_) => false
    },
  )
  // validBits 超过容器位深
  let bad_valid = build_wav_ext(1, 1, 8000, 16, 32, 2, b"\x00\x00")
  assert_true(
    match WavFile::parse(bad_valid) {
      None => true
      Some(_) => false
    },
  )
}

///|
/// 手工拼一个 fmt 块 18 字节（PCM + cbSize=0）的 WAV：旧实现会把它重写成 16 字节。
fn build_wav_fmt18() -> Bytes {
  let data : Bytes = b"\x01\x02\x03\x04"
  let total = 12 + 8 + 18 + 8 + data.length()
  let buf = Buffer()
  buf.write_bytes(b"RIFF".exact_view())
  put_u32(buf, total - 8)
  buf.write_bytes(b"WAVE".exact_view())
  buf.write_bytes(b"fmt ".exact_view())
  put_u32(buf, 18)
  put_u16(buf, 1) // PCM
  put_u16(buf, 1)
  put_u32(buf, 8000)
  put_u32(buf, 16000)
  put_u16(buf, 2)
  put_u16(buf, 16)
  put_u16(buf, 0) // cbSize = 0
  buf.write_bytes(b"data".exact_view())
  put_u32(buf, data.length())
  buf.write_bytes(data.exact_view())
  buf.to_bytes()
}

///|
test "to_bytes preserves tag-1 24-bit fmt layout" {
  // encode_wav 对 24 位整数写 tag1 + 16 字节 fmt（block_align=3）。
  // 旧 to_bytes 会改写成 40 字节 Extensible，破坏逐字节往返。
  let fmt : WavFormat = { channels: 1, sample_rate: 8000, bits_per_sample: 24, }
  let original = encode_wav(fmt, b"\x01\x02\x03\x04\x05\x06")
  match WavFile::parse(original) {
    Some(w) =>
      match w.to_bytes() {
        Ok(back) =>
          assert_true(
            back.length() == original.length() &&
            ({
              let mut same = true
              let mut i = 0
              while i < back.length() {
                if back[i].to_int() != original[i].to_int() {
                  same = false
                }
                i = i + 1
              }
              same
            }),
          )
        Err(msg) => {
          println("to_bytes error: " + msg)
          assert_true(false)
        }
      }
    None => assert_true(false)
  }
}

///|
test "to_bytes preserves 18-byte fmt chunk" {
  let original = build_wav_fmt18()
  match WavFile::parse(original) {
    Some(w) =>
      match w.to_bytes() {
        Ok(back) =>
          assert_true(
            back.length() == original.length() &&
            ({
              let mut same = true
              let mut i = 0
              while i < back.length() {
                if back[i].to_int() != original[i].to_int() {
                  same = false
                }
                i = i + 1
              }
              same
            }),
          )
        Err(_) => assert_true(false)
      }
    None => assert_true(false)
  }
}

///|
test "to_bytes preserves extensible fmt for stereo 16-bit" {
  // 2 声道 / 16 位本可以用简单 16 字节 fmt；原始文件是 Extensible 时必须保留
  // （否则 channelMask 丢失，且 72 字节文件会缩成 48 字节）。
  let original = build_wav_ext(1, 2, 8000, 16, 16, 4, b"\x01\x02\x03\x04")
  match WavFile::parse(original) {
    Some(w) =>
      match w.to_bytes() {
        Ok(back) =>
          assert_true(
            back.length() == original.length() &&
            ({
              let mut same = true
              let mut i = 0
              while i < back.length() {
                if back[i].to_int() != original[i].to_int() {
                  same = false
                }
                i = i + 1
              }
              same
            }),
          )
        Err(_) => assert_true(false)
      }
    None => assert_true(false)
  }
}

///|
/// 按给定字段拼 16 字节 fmt 负载（测试 to_bytes 的原始布局校验用）。
fn raw_fmt16(
  tag : Int32,
  channels : Int32,
  sample_rate : Int32,
  block_align : Int32,
  bits : Int32,
) -> Bytes {
  let buf = Buffer()
  put_u16(buf, tag)
  put_u16(buf, channels)
  put_u32(buf, sample_rate)
  put_u32(buf, sample_rate * block_align)
  put_u16(buf, block_align)
  put_u16(buf, bits)
  buf.to_bytes()
}

///|
fn slice_bytes(src : Bytes, start : Int32, end : Int32) -> Bytes {
  let buf = Buffer()
  let mut i = start
  while i < end {
    buf.write_byte(src[i])
    i = i + 1
  }
  buf.to_bytes()
}

///|
test "silent fallback when raw fmt payload is inconsistent" {
  let fmt : WavFormat = { channels: 1, sample_rate: 8000, bits_per_sample: 16, }
  let data : Bytes = b"\x00\x00"
  let good = raw_fmt16(1, 1, 8000, 2, 16)
  let cases : Array[Bytes] = [
    b"", // 长度 < 16
    slice_bytes(build_wav_simple(1, 1, 8000, 2, 16, b"\x00\x00"), 20, 37), // 17 字节奇数长度
    raw_fmt16(0x55, 1, 8000, 2, 16), // 未知 tag
    raw_fmt16(1, 2, 8000, 2, 16), // 声道不符
    raw_fmt16(1, 1, 44100, 2, 16), // 采样率不符
    raw_fmt16(1, 1, 8000, 4, 16), // 块对齐不符
    raw_fmt16(1, 1, 8000, 2, 24), // 容器位深不符
    raw_fmt16(0xFFFE, 1, 8000, 2, 16), // Extensible 却只有 16 字节
    raw_fmt16(1, 1, 8000, 2, 16) + b"\x00\x00\x00\x00", // tag1 不是 16/18 字节
  ]
  for raw in cases {
    match encode_wav_layout(fmt, data, Int, 2, 0, [], Some(raw)) {
      Ok(out) => assert_true(out.length() > 0)
      Err(msg) => {
        println("unexpected err: " + msg)
        assert_true(false)
      }
    }
  }
  // 合法原始布局原样写回
  match encode_wav_layout(fmt, data, Int, 2, 0, [], Some(good)) {
    Ok(out) => assert_true(slice_bytes(out, 20, 36).length() == 16)
    Err(_) => assert_true(false)
  }
  // Extensible 原始 40 字节 + 匹配的 channelMask：保留原布局
  let ext = build_wav_ext(1, 1, 8000, 16, 16, 2, b"\x00\x00")
  let ext_raw = slice_bytes(ext, 20, 60)
  match encode_wav_layout(fmt, data, Int, 2, 4, [], Some(ext_raw)) {
    Ok(out) => assert_eq(out.length(), ext.length())
    Err(_) => assert_true(false)
  }
}

///|
/// 手工拼带重复 fmt / data 块的 WAV：解析器必须拒绝，不能静默取最后一个。
fn build_wav_duplicate_block(kind : Int32) -> Bytes {
  let data : Bytes = b"\x00\x00"
  let total = 12 + 8 + 16 + 8 + 2 + 8 + 2
  let buf = Buffer()
  buf.write_bytes(b"RIFF".exact_view())
  put_u32(buf, total - 8)
  buf.write_bytes(b"WAVE".exact_view())
  buf.write_bytes(b"fmt ".exact_view())
  put_u32(buf, 16)
  put_u16(buf, 1)
  put_u16(buf, 1)
  put_u32(buf, 8000)
  put_u32(buf, 16000)
  put_u16(buf, 2)
  put_u16(buf, 16)
  if kind == 0 {
    // 第二个 fmt
    buf.write_bytes(b"fmt ".exact_view())
    put_u32(buf, 16)
    put_u16(buf, 1)
    put_u16(buf, 1)
    put_u32(buf, 8000)
    put_u32(buf, 16000)
    put_u16(buf, 2)
    put_u16(buf, 16)
  }
  buf.write_bytes(b"data".exact_view())
  put_u32(buf, data.length())
  buf.write_bytes(data.exact_view())
  if kind == 1 {
    // 第二个 data
    buf.write_bytes(b"data".exact_view())
    put_u32(buf, data.length())
    buf.write_bytes(data.exact_view())
  }
  buf.to_bytes()
}

///|
test "parse rejects duplicate fmt/data chunks" {
  assert_true(WavFile::parse(build_wav_duplicate_block(0)) is None)
  assert_true(WavFile::parse(build_wav_duplicate_block(1)) is None)
}

///|
test "float encode writes fact chunk with frame count" {
  let fmt : WavFormat = { channels: 2, sample_rate: 8000, bits_per_sample: 32, }
  let data : Bytes = b"\x00\x00\x80\x3f\x00\x00\x00\x00"
  match encode_wav_ex(fmt, data, Float) {
    Err(_) => assert_true(false)
    Ok(encoded) =>
      match WavFile::parse(encoded) {
        Some(w) => {
          let mut has_fact = false
          for c in w.chunks {
            if c.fourcc == "fact" {
              has_fact = true
              assert_eq(c.data.length(), 4)
              // 1 帧（8 字节 / 每帧 2 声道 × 4 字节）
              assert_eq(c.data[0].to_int() | (c.data[1].to_int() << 8), 1)
            }
          }
          assert_true(has_fact)
          match w.to_bytes() {
            Ok(back) => assert_eq(back.length(), encoded.length())
            Err(_) => assert_true(false)
          }
        }
        None => assert_true(false)
      }
  }
}
