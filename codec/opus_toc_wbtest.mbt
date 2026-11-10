// opus_toc_wbtest.mbt —— Opus TOC 时长计算测试
//
// 期望值依据 RFC 6716 §3.1（每帧样本数）与 §3.2.5（code 3 帧数）；
// 每个配置都至少覆盖一次，特别是 SILK 60 ms（config 3/7/11）。

///|
fn toc_samples(bytes : Bytes) -> Int32? {
  match opus_packet_samples(bytes) {
    Ok(n) => Some(n)
    Err(_) => None
  }
}

///|
test "opus TOC: SILK frame lengths incl 60 ms" {
  // config 0/1/2/3 → 10/20/40/60 ms（480/960/1920/2880）
  assert_eq(toc_samples(b"\x00"), Some(480))
  assert_eq(toc_samples(b"\x08"), Some(960))
  assert_eq(toc_samples(b"\x10"), Some(1920))
  assert_eq(toc_samples(b"\x18"), Some(2880))
  // config 7 / 11 同样是 60 ms（MB / WB）
  assert_eq(toc_samples(b"\x38"), Some(2880))
  assert_eq(toc_samples(b"\x58"), Some(2880))
}

///|
test "opus TOC: code 1 and 2 are two frames" {
  assert_eq(toc_samples(b"\x01"), Some(960)) // config 0: 2 × 480
  assert_eq(toc_samples(b"\x02"), Some(960))
  assert_eq(toc_samples(b"\x0A"), Some(1920)) // config 1: 2 × 960
}

///|
test "opus TOC: code 3 frame count uses bits 2..7" {
  // 0x03 = config 0 code 3；0x08 >> 2 = 2 帧 → 2 × 480 = 960
  assert_eq(toc_samples(b"\x03\x08"), Some(960))
  // 0x04 >> 2 = 1 帧
  assert_eq(toc_samples(b"\x03\x04"), Some(480))
  // 0x40 >> 2 = 16 帧：CELT 2.5 ms 配置下 16 × 120 = 1920（合法）
  assert_eq(toc_samples(b"\x83\x40"), Some(1920))
  // 帧数为 0 / 缺少第二字节 / 超过 48 帧都必须拒绝
  assert_eq(toc_samples(b"\x03\x00"), None)
  assert_eq(toc_samples(b"\x03"), None)
  assert_eq(toc_samples(b"\x03\xFC"), None) // 63 帧 > 48
}

///|
test "opus TOC: rejects packets longer than 120 ms" {
  // config 3（60 ms）code 2 → 120 ms = 5760，合法
  assert_eq(toc_samples(b"\x1A"), Some(5760))
  // config 3 code 3 + 第二字节 M=3 → 180 ms > 120 ms，拒绝
  assert_eq(toc_samples(b"\x1B\x0C"), None)
  // CELT 20 ms（config 31）code 3 M=7 → 140 ms > 120 ms，拒绝
  assert_eq(toc_samples(b"\xFF\x1C"), None)
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
