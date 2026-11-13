// wav_public_test.mbt —— 黑盒测试：只用 wav 包发布出来的公开 API。
//
// 与 *_wbtest.mbt 的白盒测试互补：这里不访问任何私有符号。

///|
/// 字节序列比较（Bytes 没有公开的相等运算，测试内部自己实现）。
fn public_bytes_equal(a : Bytes, b : Bytes) -> Bool {
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
test "public api: encode -> parse -> to_bytes roundtrip" {
  let fmt : @wav.WavFormat = {
    channels: 2,
    sample_rate: 44100,
    bits_per_sample: 16,
  }
  let pcm = b"\x01\x02\x03\x04"
  let encoded = @wav.encode_wav(fmt, pcm)
  assert_eq(encoded.length(), 48)
  match @wav.WavFile::parse(encoded) {
    None => assert_true(false)
    Some(file) => {
      assert_eq(file.format.channels, 2)
      assert_eq(file.format.sample_rate, 44100)
      assert_eq(file.format.bits_per_sample, 16)
      assert_eq(file.bytes_per_sample, 2)
      assert_eq(file.data.length(), 4)
      match file.sample_format {
        @wav.SampleFormat::Int => assert_true(true)
        @wav.SampleFormat::Float => assert_true(false)
      }
      match file.to_bytes() {
        Ok(again) => assert_true(public_bytes_equal(again, encoded))
        Err(msg) => abort("to_bytes 失败: " + msg)
      }
    }
  }
}

///|
test "public api: float wav via encode_wav_ex" {
  let fmt : @wav.WavFormat = {
    channels: 1,
    sample_rate: 8000,
    bits_per_sample: 32,
  }
  match @wav.encode_wav_ex(fmt, b"\x00\x00\x00\x00", @wav.SampleFormat::Float) {
    Err(msg) => abort("encode_wav_ex(float) 失败: " + msg)
    Ok(bytes) => {
      assert_true(bytes.length() > 44)
      match @wav.WavFile::parse(bytes) {
        None => assert_true(false)
        Some(file) => {
          assert_eq(file.format.bits_per_sample, 32)
          assert_eq(file.bytes_per_sample, 4)
          match file.sample_format {
            @wav.SampleFormat::Float => assert_true(true)
            @wav.SampleFormat::Int => assert_true(false)
          }
        }
      }
    }
  }
}

///|
test "public api: malformed wav and invalid parameters are rejected" {
  assert_true(@wav.WavFile::parse(b"") is None)
  assert_true(@wav.WavFile::parse(b"RIFF") is None)
  assert_true(
    @wav.WavFile::parse(b"this is definitely not a wave file") is None,
  )
  // RIFF/WAVE 头声明存在，但 fmt 块体不足
  assert_true(
    @wav.WavFile::parse(b"RIFF\x24\x00\x00\x00WAVEfmt \x10\x00\x00\x00") is None,
  )
  let zero_channels : @wav.WavFormat = {
    channels: 0,
    sample_rate: 8000,
    bits_per_sample: 16,
  }
  match @wav.encode_wav_ex(zero_channels, b"\x00\x00", @wav.SampleFormat::Int) {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
  let misaligned : @wav.WavFormat = {
    channels: 1,
    sample_rate: 8000,
    bits_per_sample: 16,
  }
  match
    @wav.encode_wav_ex(misaligned, b"\x00\x00\x00", @wav.SampleFormat::Int) {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
}

///|
fn wav_push_u16(buf : Buffer, v : Int32) -> Unit {
  buf.write_byte((v % 256).to_byte())
  buf.write_byte((v / 256 % 256).to_byte())
}

///|
fn wav_push_u32(buf : Buffer, v : Int32) -> Unit {
  buf.write_byte((v % 256).to_byte())
  buf.write_byte((v / 256 % 256).to_byte())
  buf.write_byte((v / 65536 % 256).to_byte())
  buf.write_byte((v / 16777216 % 256).to_byte())
}

///|
/// 组装一个最小 WAV：fmt 块 + data 块。fmt_tag/声道/采样率/块对齐/位深可调。
fn wav_build(
  fmt_tag : Int32,
  channels : Int32,
  sample_rate : Int32,
  block_align : Int32,
  bits : Int32,
  pcm : Bytes,
) -> Bytes {
  let inner = Buffer()
  // fmt 块
  let body = Buffer()
  wav_push_u16(body, fmt_tag)
  wav_push_u16(body, channels)
  wav_push_u32(body, sample_rate)
  wav_push_u32(body, sample_rate * block_align)
  wav_push_u16(body, block_align)
  wav_push_u16(body, bits)
  inner.write_bytes(b"fmt ".exact_view())
  wav_push_u32(inner, 16)
  inner.write_bytes(body.to_bytes().exact_view())
  // data 块
  inner.write_bytes(b"data".exact_view())
  wav_push_u32(inner, pcm.length())
  inner.write_bytes(pcm.exact_view())
  let out = Buffer()
  out.write_bytes(b"RIFF".exact_view())
  wav_push_u32(out, inner.length() + 4)
  out.write_bytes(b"WAVE".exact_view())
  out.write_bytes(inner.to_bytes().exact_view())
  out.to_bytes()
}

///|
test "public api: parse rejects malformed RIFF/chunk layouts" {
  let ok = wav_build(1, 1, 8000, 2, 16, b"\x00\x00\x01\x00")
  assert_true(@wav.WavFile::parse(ok) is Some(_))
  // WAVE 标记被改坏
  let raw = ok
  let bad_wave = Buffer()
  bad_wave.write_bytes(raw[:12].exact_view())
  bad_wave.write_bytes(b"WAVX".exact_view())
  bad_wave.write_bytes(raw[16:].exact_view())
  assert_true(@wav.WavFile::parse(bad_wave.to_bytes()) is None)
  // RIFF 长度字段为 0
  let zero_size = Buffer()
  zero_size.write_bytes(b"RIFF".exact_view())
  wav_push_u32(zero_size, 0)
  zero_size.write_bytes(b"WAVEfmt ".exact_view())
  assert_true(@wav.WavFile::parse(zero_size.to_bytes()) is None)
  // 重复 fmt 块
  let dup_fmt = Buffer()
  dup_fmt.write_bytes(ok[:12].exact_view())
  dup_fmt.write_bytes(ok[12:36].exact_view())
  dup_fmt.write_bytes(ok[12:36].exact_view())
  dup_fmt.write_bytes(ok[36:].exact_view())
  assert_true(@wav.WavFile::parse(dup_fmt.to_bytes()) is None)
  // 不支持的格式 tag（2 = MS ADPCM）
  assert_true(
    @wav.WavFile::parse(wav_build(2, 1, 8000, 2, 16, b"\x00\x00")) is None,
  )
  // 块对齐不是声道数整数倍
  assert_true(@wav.WavFile::parse(wav_build(1, 2, 8000, 3, 16, b"")) is None)
  // 容器容量不够：32 位采样塞进 2 字节容器
  assert_true(
    @wav.WavFile::parse(wav_build(1, 1, 8000, 2, 32, b"\x00\x00")) is None,
  )
  // RIFF 声明长度包含额外的尾巴，但块只填到 44 字节 → pos != riff_end
  let trailing = Buffer()
  trailing.write_bytes(ok.exact_view())
  trailing.write_bytes(b"\x00".exact_view())
  let tail_bytes = Buffer()
  tail_bytes.write_bytes(b"RIFF".exact_view())
  wav_push_u32(tail_bytes, ok.length() - 8 + 1)
  tail_bytes.write_bytes(trailing.to_bytes()[8:].exact_view())
  assert_true(@wav.WavFile::parse(tail_bytes.to_bytes()) is None)
}

///|
test "public api: encode_wav_ex rejects parameter overflows" {
  let bad_bits : @wav.WavFormat = {
    channels: 1,
    sample_rate: 8000,
    bits_per_sample: 40,
  }
  assert_true(
    @wav.encode_wav_ex(
      bad_bits,
      b"\x00\x00\x00\x00\x00",
      @wav.SampleFormat::Int,
    )
    is Err(_),
  )
  let huge_channels : @wav.WavFormat = {
    channels: 65536,
    sample_rate: 8000,
    bits_per_sample: 16,
  }
  assert_true(
    @wav.encode_wav_ex(huge_channels, b"\x00\x00", @wav.SampleFormat::Int)
    is Err(_),
  )
  let wide_align : @wav.WavFormat = {
    channels: 65535,
    sample_rate: 8000,
    bits_per_sample: 16,
  }
  assert_true(
    @wav.encode_wav_ex(wide_align, b"\x00\x00", @wav.SampleFormat::Int)
    is Err(_),
  )
  let fast_rate : @wav.WavFormat = {
    channels: 1,
    sample_rate: 2147483647,
    bits_per_sample: 16,
  }
  assert_true(
    @wav.encode_wav_ex(fast_rate, b"\x00\x00", @wav.SampleFormat::Int) is Err(_),
  )
}
