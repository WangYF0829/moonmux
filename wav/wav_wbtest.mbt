// wav_wbtest.mbt —— WAV 读写的测试

///|
/// 编码再解析应当还原出同样的格式与数据。
test "wav encode then parse roundtrip" {
  let fmt : WavFormat = { channels: 2, sample_rate: 44100, bits_per_sample: 16 }
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
  let fmt : WavFormat = { channels: 1, sample_rate: 8000, bits_per_sample: 8 }
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
  let fmt : WavFormat = { channels: 1, sample_rate: 16000, bits_per_sample: 8 }
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
  let fmt : WavFormat = { channels: 1, sample_rate: 8000, bits_per_sample: 16 }
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
  let bad : WavFormat = { channels: 0, sample_rate: 0, bits_per_sample: 0 }
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
  let fmt : WavFormat = { channels: 1, sample_rate: 8000, bits_per_sample: 16 }
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
