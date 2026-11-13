///|
test "validate_page and serialize_pages_checked reject malformed pages" {
  // 段值 > 255：序列化会静默截断，必须在写入前拒绝
  let bad : Page = {
    header_type: (0x00 : Byte),
    granule_position: 0L,
    serial: 1U,
    sequence: 0U,
    crc: 0U,
    segments: [256],
    payload: b"x",
  }
  assert_true(validate_page(bad) is Err(_))
  assert_true(serialize_pages_checked([bad]) is Err(_))
  // 段表总和与负载不一致
  let mismatch : Page = {
    header_type: (0x00 : Byte),
    granule_position: 0L,
    serial: 1U,
    sequence: 0U,
    crc: 0U,
    segments: [2],
    payload: b"x",
  }
  assert_true(validate_page(mismatch) is Err(_))
  // 合法页通过，输出可回读
  let ok : Page = {
    header_type: (0x00 : Byte),
    granule_position: 960L,
    serial: 1U,
    sequence: 0U,
    crc: 0U,
    segments: [1, 2],
    payload: b"abc",
  }
  assert_true(validate_page(ok) is Ok(_))
  match serialize_pages_checked([ok]) {
    Ok(bytes) => assert_eq(parse_pages(bytes).length(), 1)
    Err(_) => assert_true(false)
  }
}

///|
/// F-PAR-05：RFC 3533 §6 规定头类型位 0x08–0x80 为保留位、必须为 0。
/// 解析、写前校验、重同步预筛必须用同一套判据。
test "reserved header-type bits are rejected by parse and validate_page" {
  // 合法页先序列化，再把 header_type 的保留位打开
  let patched : Page = {
    header_type: (0x0A : Byte), // BOS + 保留位 0x08
    granule_position: 0L,
    serial: 1U,
    sequence: 0U,
    crc: 0U,
    segments: [1],
    payload: b"x",
  }
  let bad_bytes = serialize_pages([patched])
  // 解析侧：Page::parse 拒绝
  assert_eq(parse_pages(bad_bytes).length(), 0)
  // 写侧：validate_page 也拒绝，避免写出的字节自己读不回来
  assert_true(validate_page(patched) is Err(_))
  assert_true(serialize_pages_checked([patched]) is Err(_))
}

///|
test "validate_page rejects payload over 65025 bytes" {
  let segs = Array::make(255, 255)
  let buf = Buffer()
  let mut i = 0
  while i < 65026 {
    buf.write_byte((0 : Byte))
    i = i + 1
  }
  let big : Page = {
    header_type: (0x00 : Byte),
    granule_position: 0L,
    serial: 1U,
    sequence: 0U,
    crc: 0U,
    segments: segs,
    payload: buf.to_bytes(),
  }
  assert_true(validate_page(big) is Err(_))
}
