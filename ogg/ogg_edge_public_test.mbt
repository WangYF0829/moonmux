// ogg_edge_public_test.mbt —— 黑盒测试：ogg 公开 API 的边界/坏输入路径。
//
// 只用公开 API（Page 结构体是 pub(all)，可以在测试里直接构造页），
// 覆盖容错解析、first_packets 状态机、hex 输出、chop 的拒绝分支。

///|
fn edge_payload(n : Int32, fill : Int32) -> Bytes {
  let buf = Buffer()
  let mut i = 0
  while i < n {
    buf.write_byte(((fill + i) % 251).to_byte())
    i = i + 1
  }
  buf.to_bytes()
}

///|
fn edge_concat(a : Bytes, b : Bytes) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(a.exact_view())
  buf.write_bytes(b.exact_view())
  buf.to_bytes()
}

///|
test "public api: for_each_hex_line matches xxd layout" {
  let lines : Array[String] = []
  @ogg.for_each_hex_line(b"0123456789abcdefXYZ", s => lines.push(s))
  assert_eq(lines.length(), 2)
  assert_true(lines[0].contains("00000000:"))
  assert_true(lines[0].contains("3031"))
  assert_true(lines[1].contains("00000010:"))
  // 最后一行不足 16 字节：必须补空白而不是少打印
  assert_true(lines[1].length() >= lines[0].length())
  let empty_lines : Array[String] = []
  @ogg.for_each_hex_line(b"", s => empty_lines.push(s))
  assert_eq(empty_lines.length(), 0)
}

///|
test "public api: first_packets marks malformed first pages invalid" {
  // 空页带负载：不含包边界，但负载非 0 视为结构不符
  let empty_with_payload : @ogg.Page = {
    header_type: 0,
    granule_position: 0L,
    serial: 1U,
    sequence: 0U,
    crc: 0U,
    segments: [],
    payload: b"\x00",
  }
  // 首页带 continued：包的开头不在文件里
  let continued_first : @ogg.Page = {
    header_type: @ogg.flag_continued(),
    granule_position: 0L,
    serial: 2U,
    sequence: 0U,
    crc: 0U,
    segments: [1],
    payload: b"a",
  }
  // 打开一个跨页包，但下一张页没有 continued（缺页）
  let open_first : @ogg.Page = {
    header_type: 0,
    granule_position: 0L,
    serial: 3U,
    sequence: 0U,
    crc: 0U,
    segments: [255],
    payload: edge_payload(255, 7),
  }
  let broken_second : @ogg.Page = {
    header_type: @ogg.flag_continued(),
    granule_position: 0L,
    serial: 3U,
    sequence: 1U,
    crc: 0U,
    segments: [5],
    payload: b"abc",
  }
  let got = @ogg.first_packets([
    empty_with_payload, continued_first, open_first, broken_second,
  ])
  assert_true(got.get(1U) is None)
  assert_true(got.get(2U) is None)
  assert_true(got.get(3U) is None)
}

///|
test "public api: parse_pages_lenient skips garbage and truncated heads" {
  // 垃圾前缀 + 结构不完整（不足以容纳 27 字节头）的伪页头
  let a = edge_concat(b"xxOggS\x00\x00", edge_payload(20, 3))
  let (pages_a, gaps_a) = @ogg.parse_pages_lenient(a)
  assert_eq(pages_a.length(), 0)
  assert_true(gaps_a.length() > 0)
  // 段表长度超出剩余字节（最后一字节作为 n_segments = 255）
  let mut b = edge_concat(b"xxOggS\x00\x00", edge_payload(21, 5))
  let raw = b
  if raw.length() > 0 {
    let buf = Buffer()
    buf.write_bytes(raw[:raw.length() - 1].exact_view())
    buf.write_byte((255 : Byte))
    b = buf.to_bytes()
  }
  let (pages_b, gaps_b) = @ogg.parse_pages_lenient(b)
  assert_eq(pages_b.length(), 0)
  assert_true(gaps_b.length() > 0)
  // 单页声明了 5 字节负载但只给 2 字节
  let hdr = Buffer()
  hdr.write_bytes(b"OggS".exact_view())
  hdr.write_byte((0 : Byte))
  hdr.write_byte((0 : Byte))
  let mut hz = 0
  while hz < 8 {
    hdr.write_byte((0 : Byte))
    hz = hz + 1
  }
  hdr.write_bytes(b"\x00\x00\x00\x01".exact_view())
  let mut hz2 = 0
  while hz2 < 8 {
    hdr.write_byte((0 : Byte))
    hz2 = hz2 + 1
  }
  hdr.write_byte((1 : Byte))
  hdr.write_byte((5 : Byte))
  let header = hdr.to_bytes()
  assert_eq(header.length(), 28)
  let truncated = edge_concat(header, b"ab")
  let (pages_c, gaps_c) = @ogg.parse_pages_lenient(truncated)
  assert_eq(pages_c.length(), 0)
  assert_true(gaps_c.length() > 0)
}

///|
test "public api: parse_pages_lenient_checked rejects fake-header flood" {
  // 密集伪页头：每个候选的段表扫描都要计入重同步预算
  let many = Buffer()
  let mut i = 0
  while i < 900 {
    many.write_bytes(b"OggS\x00\x00".exact_view())
    i = i + 1
  }
  match @ogg.parse_pages_lenient_checked(many.to_bytes()) {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.length() > 0)
  }
}

///|
test "public api: chop_pages rejects bad range and missing stream" {
  let packets : Array[@ogg.Packet] = [
    { data: b"abc", granule_position: 0L, serial: 7U, },
  ]
  let pages = @ogg.paginate(packets, 7U)
  match @ogg.chop_pages(pages, 7U, -1L, 10L) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  match @ogg.chop_pages(pages, 99U, 0L, 10L) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  match @ogg.chop_pages(pages, 7U, 0L, 10L) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
}
