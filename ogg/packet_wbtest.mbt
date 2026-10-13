// packet_wbtest.mbt —— 包重组与段表切分的测试

///|
/// 构造一段重复字节，便于造出指定长度的负载。
fn repeat_byte(b : Byte, n : Int) -> Bytes {
  let buf = Buffer()
  let mut i = 0
  while i < n {
    buf.write_byte(b)
    i = i + 1
  }
  buf.to_bytes()
}

///|
/// 同一页内的两个包应当被正确切开。
///
/// 段表 [1, 1] 表示两个各含 1 字节的包。
test "two packets in one page" {
  let page : Page = {
    header_type: flag_bos(),
    granule_position: 0L,
    serial: 1U,
    sequence: 0U,
    crc: 0U,
    segments: [1, 1],
    payload: b"ab",
  }
  let packets = reassemble([page])
  assert_eq(packets.length(), 2)
  assert_true(same_bytes(packets[0].data, b"a"))
  assert_true(same_bytes(packets[1].data, b"b"))
}

///|
/// 跨页延续的包：第一页以 255 段结尾，第二页以短段收尾。
///
/// 这是 Ogg 区别于「按页独立编码」的关键机制 ——
/// 若实现只按页切分，这里会得到两个 255 和 1 字节的碎片，
/// 而不是一个完整的 256 字节包。
test "packet spanning two pages" {
  let page1 : Page = {
    header_type: flag_bos(),
    granule_position: 0L,
    serial: 1U,
    sequence: 0U,
    crc: 0U,
    segments: [255],
    payload: repeat_byte((0x41 : Byte), 255),
  }
  let page2 : Page = {
    header_type: flag_continued(),
    granule_position: 100L,
    serial: 1U,
    sequence: 1U,
    crc: 0U,
    segments: [1],
    payload: b"Z",
  }
  let packets = reassemble([page1, page2])
  assert_eq(packets.length(), 1)
  assert_eq(packets[0].data.length(), 256)
  // 粒度位置应取自包结束所在的第二页
  assert_eq(packets[0].granule_position, 100L)
}

///|
/// 段表切分：长度 255 的包必须产出 [255, 0]，
/// 末尾的 0 段用于向解码器标明包已结束。
test "segments_for handles exact multiples of 255" {
  let s255 = segments_for(255)
  assert_eq(s255.length(), 2)
  assert_eq(s255[0], 255)
  assert_eq(s255[1], 0)
  let s256 = segments_for(256)
  assert_eq(s256.length(), 2)
  assert_eq(s256[0], 255)
  assert_eq(s256[1], 1)
  let s0 = segments_for(0)
  assert_eq(s0.length(), 1)
  assert_eq(s0[0], 0)
}

///|
/// 端到端：字节流 → 页 → 包，内容不丢。
test "stream to packets roundtrip" {
  let page : Page = {
    header_type: flag_bos(),
    granule_position: 5L,
    serial: 7U,
    sequence: 0U,
    crc: 0U,
    segments: [3, 2],
    payload: b"abcde",
  }
  let bytes = serialize_pages([page])
  let pages = parse_pages(bytes)
  assert_eq(pages.length(), 1)
  let packets = reassemble(pages)
  assert_eq(packets.length(), 2)
  assert_true(same_bytes(packets[0].data, b"abc"))
  assert_true(same_bytes(packets[1].data, b"de"))
}
