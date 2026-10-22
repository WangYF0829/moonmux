///|
/// 确定性伪随机（xorshift），避免给测试引入额外依赖。
fn fuzz_next(state : UInt32) -> UInt32 {
  let mut x = state
  x = x ^ (x << 13)
  x = x ^ (x >> 17)
  x = x ^ (x << 5)
  x
}

///|
/// 随机字节 + 偶发 `OggS` 标记：解析器不能崩，且解析出的页必须能序列化再读回。
test "random bytes never crash the page parser" {
  let mut seed = 0x9E3779B9U
  let mut round = 0
  while round < 200 {
    seed = fuzz_next(seed)
    let len = (seed % 400U).reinterpret_as_int()
    let buf = Buffer()
    let mut i = 0
    while i < len {
      seed = fuzz_next(seed)
      let b = (seed % 256U).reinterpret_as_int().to_byte()
      // 四分之一的情况以捕获模式开头，让解析器进入真正的页分支
      if round % 4 == 0 && i < 4 {
        buf.write_byte(
          match i {
            0 => b'O'
            1 => b'g'
            2 => b'g'
            _ => b'S'
          },
        )
      } else {
        buf.write_byte(b)
      }
      i = i + 1
    }
    let (pages, _gaps) = parse_pages_lenient(buf.to_bytes())
    // 不变量：解析结果序列化后必须能被同一解析器读回，且页数与关键字段不变
    let bytes = serialize_pages(pages)
    let again = parse_pages(bytes)
    assert_eq(again.length(), pages.length())
    let mut j = 0
    while j < pages.length() {
      assert_eq(again[j].serial, pages[j].serial)
      assert_eq(again[j].granule_position, pages[j].granule_position)
      j = j + 1
    }
    round = round + 1
  }
}
