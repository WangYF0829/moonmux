///|
/// 确定性伪随机（xorshift），避免给测试引入额外依赖。
fn codec_fuzz_next(state : UInt32) -> UInt32 {
  let mut x = state
  x = x ^ (x << 13)
  x = x ^ (x >> 17)
  x = x ^ (x << 5)
  x
}

///|
/// 注释包解析：随机字节加合法前缀，不能崩；成功解析的结果必须能重新编码再解析。
test "random comment payloads are either rejected or round-trip" {
  let mut seed = 0x1234ABCDU
  let mut round = 0
  while round < 100 {
    seed = codec_fuzz_next(seed)
    let len = (seed % 200U).reinterpret_as_int()
    let buf = Buffer()
    buf.write_bytes(b"OpusTags".exact_view())
    let mut i = 0
    while i < len {
      seed = codec_fuzz_next(seed)
      buf.write_byte((seed % 256U).reinterpret_as_int().to_byte())
      i = i + 1
    }
    match parse_comment(buf.to_bytes()) {
      Err(_) => ()
      Ok(parsed) => {
        let encoded = encode_comment(parsed.0, parsed.1, 0)
        match parse_comment(encoded) {
          Ok(again) => {
            assert_eq(again.1.vendor, parsed.1.vendor)
            assert_eq(again.1.tags.length(), parsed.1.tags.length())
          }
          Err(msg) => abort("重新编码后解析失败：" + msg)
        }
      }
    }
    round = round + 1
  }
}
