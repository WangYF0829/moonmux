// codec_wbtest.mbt —— 编解码头解析的测试

///|
/// 一个 OpusHead：2 声道、pre-skip 312、输入采样率 48000、增益 0、映射族 0。
///
/// 字节布局（RFC 7845 §5.1）："OpusHead" | ver=1 | ch=2 | pre-skip(312)
/// | input_rate(48000) | gain(0) | mapping(0)
let opus_head_2ch : Bytes = b"OpusHead\x01\x02\x38\x01\x80\xBB\x00\x00\x00\x00\x00"

///|
/// 一个 Vorbis 识别头：2 声道、采样率 44100。
///
/// 0x01 | "vorbis" | 版本 0 | ch=2 | rate=44100 | 三个码率(0) | 块大小 | 帧标志
let vorbis_id_2ch : Bytes = b"\x01vorbis\x00\x00\x00\x00\x02\x44\xAC\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xB8\x01"

///|
/// OpusHead 的各字段应被正确读出。
test "parse opus head" {
  match parse_opus_head(opus_head_2ch) {
    Some(info) => {
      assert_eq(info.codec, "Opus")
      assert_eq(info.channels, 2)
      assert_eq(info.pre_skip, 312)
      // 输出采样率恒为 48 kHz，与头里的输入采样率无关
      assert_eq(info.sample_rate, 48000)
    }
    None => assert_true(false)
  }
}

///|
/// Vorbis 识别头同理。
test "parse vorbis id" {
  match parse_vorbis_id(vorbis_id_2ch) {
    Some(info) => {
      assert_eq(info.codec, "Vorbis")
      assert_eq(info.channels, 2)
      assert_eq(info.sample_rate, 44100)
      // Vorbis 没有 pre-skip 的概念
      assert_eq(info.pre_skip, 0)
    }
    None => assert_true(false)
  }
}

///|
/// 两种头互不误认 —— 它们都以「自己的魔数」开头，判据是包内容而非长度。
test "headers do not cross-match" {
  match parse_opus_head(vorbis_id_2ch) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
  match parse_vorbis_id(opus_head_2ch) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
}

///|
/// 截断的、或魔数不符的数据一律拒绝，而不是读出垃圾字段。
test "reject truncated and foreign headers" {
  match parse_opus_head(b"OpusHead\x01\x02\x38") {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
  match parse_vorbis_id(b"\x01vorbi") {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
  match parse_audio_header(b"not an audio header at all........") {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
}

///|
/// 采样率字段高位被置 1（如 0xFFFFFFFF）时读成有符号 Int 是负数，
/// 这种头必须拒绝 —— 否则 info 会打出「采样率 -1 Hz」、时长被算成负值。
test "reject vorbis id with absurd sample rate" {
  let absurd : Bytes = b"\x01vorbis\x00\x00\x00\x00\x02\xFF\xFF\xFF\xFF\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xB8\x01"
  match parse_vorbis_id(absurd) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
}

///|
/// 复制 Vorbis 识别头并替换一个字节。
fn vorbis_with(index : Int32, value : Int32) -> Bytes {
  let buf = Buffer()
  let mut i = 0
  while i < vorbis_id_2ch.length() {
    if i == index {
      buf.write_byte(value.to_byte())
    } else {
      buf.write_byte(vorbis_id_2ch[i])
    }
    i = i + 1
  }
  buf.to_bytes()
}

///|
/// Vorbis 识别头的版本、块大小与 framing 标志都是可判定的硬约束。
test "reject vorbis id with invalid required fields" {
  // version 必须为 0（偏移 7..10）
  match parse_vorbis_id(vorbis_with(7, 1)) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
  // blocksize_0 必须 >= 6：这里把低四位改成 0
  match parse_vorbis_id(vorbis_with(28, 0)) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
  // 两个块大小颠倒（8 > 6）同样不合法
  match parse_vorbis_id(vorbis_with(28, 0x68)) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
  // framing 标志必须置位
  match parse_vorbis_id(vorbis_with(29, 0)) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
}

///|
/// 版本号不为 1 的 OpusHead 应当拒绝：字段布局只对版本 1 有保证，
/// 硬着头皮读下去只会得到错误参数。
test "reject opus head with unknown version" {
  let v2 : Bytes = b"OpusHead\x02\x02\x38\x01\x80\xBB\x00\x00\x00\x00\x00"
  match parse_opus_head(v2) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
}

///|
/// 时长公式必须同时减掉首粒度与 pre-skip。
///
/// 用真实样本的数字：末粒度 288312、首粒度 0、pre-skip 312、48 kHz
/// → (288312 - 0 - 312) / 48000 = 6.000 秒。
test "duration subtracts pre-skip" {
  let info : AudioInfo = {
    codec: "Opus",
    channels: 2,
    sample_rate: 48000,
    pre_skip: 312,
  }
  let d = duration_seconds(info, 0L, 288312L)
  assert_true(d > 5.99 && d < 6.01)
}

///|
/// 首粒度不为 0 时必须减掉它 —— 被裁剪或中途接入的流会这样，
/// 不减就把开头偏移算进时长。
test "duration subtracts the first granule" {
  let info : AudioInfo = {
    codec: "Opus",
    channels: 2,
    sample_rate: 48000,
    pre_skip: 312,
  }
  // 首粒度 48000 = 已跳过 1 秒；末 144312 → 再走 2 秒
  let d = duration_seconds(info, 48000L, 144312L)
  assert_true(d > 1.99 && d < 2.01)
}

///|
/// 末粒度不大于首粒度时返回 0，不返回负数 —— 损坏文件里会出现这种情形。
test "duration never goes negative" {
  let info : AudioInfo = {
    codec: "Opus",
    channels: 2,
    sample_rate: 48000,
    pre_skip: 312,
  }
  assert_true(duration_seconds(info, 100L, 50L) == 0.0)
  assert_true(duration_seconds(info, 0L, 100L) == 0.0)
}

///|

///|
/// 按 RFC 7845 §5.1.1 拼 OpusHead（family=0 为 19 字节，否则 21+C）。
fn mk_opus_head(
  ch : Int32,
  family : Int32,
  stream : Int32,
  coupled : Int32,
  mapping : Array[Int32],
) -> Bytes {
  let b = Buffer()
  b.write_bytes(b"OpusHead".exact_view())
  b.write_byte((1 : Byte))
  b.write_byte(ch.to_byte())
  b.write_byte((0x38 : Byte))
  b.write_byte((0x01 : Byte))
  b.write_byte((0x80 : Byte))
  b.write_byte((0xBB : Byte))
  b.write_byte((0 : Byte))
  b.write_byte((0 : Byte))
  b.write_byte((0 : Byte))
  b.write_byte((0 : Byte))
  b.write_byte(family.to_byte())
  if family != 0 {
    b.write_byte(stream.to_byte())
    b.write_byte(coupled.to_byte())
    for m in mapping {
      b.write_byte(m.to_byte())
    }
  }
  b.to_bytes()
}

///|
test "parse_opus_head validates mapping family" {
  // 合法：family=0 单声道 / 立体声
  match parse_opus_head(mk_opus_head(1, 0, 0, 0, [])) {
    Some(info) => assert_eq(info.channels, 1)
    None => assert_true(false)
  }
  match parse_opus_head(mk_opus_head(2, 0, 0, 0, [])) {
    Some(info) => assert_eq(info.channels, 2)
    None => assert_true(false)
  }
  // family=0 且 3 声道：非法
  assert_true(parse_opus_head(mk_opus_head(3, 0, 0, 0, [])) is None)
  // family=1 但缺少映射表
  assert_true(parse_opus_head(mk_opus_head(1, 1, 1, 0, [])) is None)
  // family=1、stream_count=0：非法
  assert_true(parse_opus_head(mk_opus_head(1, 1, 0, 0, [0])) is None)
  // family=1 合法：21+C = 22 字节
  match parse_opus_head(mk_opus_head(1, 1, 1, 0, [0])) {
    Some(info) => assert_eq(info.channels, 1)
    None => assert_true(false)
  }
}
