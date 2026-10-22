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
/// 跑一轮：随机 OpusTags 载荷，要么被拒绝，要么解码—编码—解码后 vendor 与标签数不变。
///
/// 单独成函数是为了不让编译器把整个循环体展开 —— 100 轮直接写在 `while` 里
/// 会让 `moonc` 在链接期耗尽内存（实测）。
fn codec_fuzz_round(seed : UInt32) -> UInt32 {
  let mut cur = codec_fuzz_next(seed)
  let len = (cur % 200U).reinterpret_as_int()
  let buf = Buffer()
  buf.write_bytes(b"OpusTags".exact_view())
  let mut i = 0
  while i < len {
    cur = codec_fuzz_next(cur)
    buf.write_byte((cur % 256U).reinterpret_as_int().to_byte())
    i = i + 1
  }
  match parse_comment(buf.to_bytes()) {
    Err(_) => ()
    Ok(parsed) => {
      let encoded = encode_comment(parsed.0, parsed.1, 0)
      match parse_comment(encoded) {
        Ok(again) => {
          // 辅助函数没有错误类型，用 abort 而不是 assert_*
          if again.1.vendor != parsed.1.vendor {
            abort("vendor 在重编码后变化")
          }
          if again.1.tags.length() != parsed.1.tags.length() {
            abort("标签数在重编码后变化")
          }
        }
        Err(msg) => abort("重新编码后解析失败：" + msg)
      }
    }
  }
  cur
}

///|
/// 注释包解析：随机字节加合法前缀，不能崩；成功解析的结果必须能重新编码再解析。
test "random comment payloads are either rejected or round-trip" {
  let mut seed = 0x1234ABCDU
  let mut round = 0
  while round < 100 {
    seed = codec_fuzz_round(seed)
    round = round + 1
  }
}
