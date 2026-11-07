// opus_toc_wbtest.mbt —— Opus TOC 时长计算测试

///|
fn toc_samples(bytes : Bytes) -> Int? {
  match opus_packet_samples(bytes) {
    Ok(n) => Some(n)
    Err(_) => None
  }
}

///|
test "opus TOC: CELT config 31 code 0 is 20ms" {
  // 0xFC = config 31 (11111) + code 0 → 1 帧 × 960（20 ms @ 48 kHz）
  assert_eq(toc_samples(b"\xFC"), Some(960))
}

///|
test "opus TOC: SILK config 0 code 0 is 10ms" {
  // 0x00 = config 0 + code 0 → 1 帧 × 480（10 ms）
  assert_eq(toc_samples(b"\x00"), Some(480))
  // 0x01 = config 0 + code 1 → 2 帧 × 480 = 960
  assert_eq(toc_samples(b"\x01"), Some(960))
  // 0x02 = config 0 + code 2 → 2 帧 × 480 = 960
  assert_eq(toc_samples(b"\x02"), Some(960))
}

///|
test "opus TOC: code 3 frame count byte" {
  // 0x03 = config 0 + code 3；第二字节低 6 位 = 2 帧 → 2 × 480 = 960
  assert_eq(toc_samples(b"\x03\x02"), Some(960))
  assert_eq(toc_samples(b"\x03\x01"), Some(480))
  // 帧数为 0 / 缺少第二字节都必须拒绝
  assert_eq(toc_samples(b"\x03\x00"), None)
  assert_eq(toc_samples(b"\x03"), None)
}

///|
test "opus TOC: hybrid and CELT frame lengths" {
  // config 12 (Hybrid SWB 10ms) → 480；config 13 → 960
  assert_eq(toc_samples(b"\x60"), Some(480))
  assert_eq(toc_samples(b"\x68"), Some(960))
  // config 16 (CELT 2.5ms) → 120；config 19 (CELT 20ms) → 960
  assert_eq(toc_samples(b"\x80"), Some(120))
  assert_eq(toc_samples(b"\x98"), Some(960))
  // 空包拒绝
  assert_eq(toc_samples(b""), None)
}
