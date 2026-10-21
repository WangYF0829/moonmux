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
/// 非 PCM 的格式标签要拒绝（浮点 WAV 的 data 不能按整数 PCM 解释）。
test "reject wav with a non-pcm format tag" {
  let ok = encode_wav(
    { channels: 1, sample_rate: 8000, bits_per_sample: 16, },
    b"\x00\x00",
  )
  // 把 fmt 块的格式标签从 1 改成 3（IEEE float）
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
/// 手工拼一个 WAVE_FORMAT_EXTENSIBLE 的 WAV：`sub` 是 SubFormat GUID 的前两字节
/// （1 = PCM，3 = IEEE float）。
fn build_wav_ext(sub : Int32, bits : Int32) -> Bytes {
  let data_len = 4
  let fmt_size = 40
  let total = 12 + 8 + fmt_size + 8 + data_len
  let buf = Buffer()
  buf.write_bytes(b"RIFF".exact_view())
  put_u32(buf, total - 8)
  buf.write_bytes(b"WAVE".exact_view())
  buf.write_bytes(b"fmt ".exact_view())
  put_u32(buf, fmt_size)
  put_u16(buf, 0xFFFE) // wFormatTag = EXTENSIBLE
  put_u16(buf, 1) // channels
  put_u32(buf, 8000) // sample rate
  put_u32(buf, 16000) // byte rate
  put_u16(buf, 2) // block align
  put_u16(buf, bits) // bits per sample
  put_u16(buf, 22) // cbSize
  put_u16(buf, bits) // valid bits
  put_u32(buf, 4) // channel mask
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
  put_u16(buf, 0)
  put_u16(buf, 0)
  buf.to_bytes()
}

///|
/// EXTENSIBLE + PCM 子格式应当接受。
test "accept extensible wav whose subformat is pcm" {
  match WavFile::parse(build_wav_ext(1, 16)) {
    Some(f) => {
      assert_eq(f.format.channels, 1)
      assert_eq(f.format.sample_rate, 8000)
      assert_eq(f.format.bits_per_sample, 16)
    }
    None => assert_true(false)
  }
}

///|
/// EXTENSIBLE + IEEE float 子格式必须拒绝（data 不能按整数 PCM 解释）。
test "reject extensible wav whose subformat is float" {
  match WavFile::parse(build_wav_ext(3, 32)) {
    Some(_) => assert_true(false)
    None => assert_true(true)
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
  let full = build_wav_ext(1, 16)
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
