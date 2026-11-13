// ogg_public_test.mbt —— 黑盒测试：只用 ogg 包发布出来的公开 API。
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
test "public api: paginate -> serialize -> parse -> reassemble roundtrip" {
  let packets : Array[@ogg.Packet] = [
    { data: b"OpusHead", granule_position: 0L, serial: 7U, },
    { data: b"second packet payload", granule_position: 960L, serial: 7U, },
  ]
  let pages = @ogg.paginate(packets, 7U)
  assert_true(pages.length() > 0)
  assert_eq(@ogg.serials_of(pages).length(), 1)
  assert_eq(@ogg.count_packets(pages), 2)
  assert_eq(@ogg.DEFAULT_PAGE_TARGET, 4096)
  let bytes = @ogg.serialize_pages(pages)
  let reparsed = @ogg.parse_pages(bytes)
  assert_eq(reparsed.length(), pages.length())
  let again = @ogg.serialize_pages(reparsed)
  assert_true(public_bytes_equal(again, bytes))
  let reassembled = @ogg.reassemble(reparsed)
  assert_eq(reassembled.length(), 2)
  assert_eq(reassembled[0].serial, 7U)
  assert_eq(reassembled[1].granule_position, 960L)
  assert_true(public_bytes_equal(reassembled[1].data, b"second packet payload"))
}

///|
test "public api: crc / page validation of a trusted page" {
  let page : @ogg.Page = {
    header_type: @ogg.flag_bos(),
    granule_position: 0L,
    serial: 1U,
    sequence: 0U,
    crc: 0U,
    segments: [3],
    payload: b"ABC",
  }
  let bytes = page.to_bytes()
  assert_eq(bytes.length(), 31)
  match @ogg.Page::parse(bytes, 0) {
    Some((parsed, next)) => {
      assert_eq(next, bytes.length())
      assert_true(@ogg.page_crc_ok(parsed))
      assert_eq(parsed.crc, parsed.expected_crc())
      assert_true(@ogg.verify_page(bytes, parsed.crc))
      assert_true(!@ogg.verify_page(bytes, parsed.crc + 1U))
      assert_eq(parsed.payload.length(), 3)
      assert_eq(@ogg.serialize_pages([parsed]).length(), 31)
    }
    None => assert_true(false)
  }
  assert_eq(@ogg.crc32(b""), 0U)
  assert_true(!@ogg.verify_page(b"", 0U))
  assert_true(!@ogg.verify_page(b"not an ogg page", 0U))
}

///|
test "public api: malformed input is rejected without crashing" {
  assert_eq(@ogg.parse_pages(b"").length(), 0)
  assert_eq(@ogg.parse_pages(b"OggS").length(), 0)
  assert_eq(@ogg.parse_pages(b"completely not an ogg stream").length(), 0)
  let (pages, gaps) = @ogg.parse_pages_lenient(b"junk before any page")
  assert_eq(pages.length(), 0)
  assert_true(gaps.length() > 0)
  match @ogg.parse_pages_lenient_checked(b"junk before any page") {
    Ok((checked_pages, _)) => assert_eq(checked_pages.length(), 0)
    Err(_) => assert_true(false)
  }
  match @ogg.Page::parse(b"", 0) {
    None => assert_true(true)
    Some(_) => assert_true(false)
  }
  let bad : @ogg.Page = {
    header_type: 0,
    granule_position: 0L,
    serial: 1U,
    sequence: 0U,
    crc: 0U,
    segments: [5],
    payload: b"ab",
  }
  match @ogg.validate_page(bad) {
    Err(msg) => assert_true(msg.length() > 0)
    Ok(_) => assert_true(false)
  }
  match @ogg.serialize_pages_checked([bad]) {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
}

///|
test "public api: PageReader streams pages and records a gap on a partial tail" {
  let packets : Array[@ogg.Packet] = [
    { data: b"aaaa", granule_position: 0L, serial: 3U, },
    { data: b"bbbb", granule_position: 480L, serial: 3U, },
  ]
  let pages = @ogg.paginate(packets, 3U)
  let bytes = @ogg.serialize_pages(pages)
  let reader = @ogg.PageReader::new()
  reader.feed(bytes)
  assert_eq(reader.pages_ready(), pages.length())
  let got = reader.take_pages()
  assert_eq(got.length(), pages.length())
  assert_eq(reader.pages_ready(), 0)
  reader.finish()
  assert_true(reader.is_finished())
  let tail_reader = @ogg.PageReader::new()
  tail_reader.feed(b"xxxx")
  tail_reader.finish()
  assert_eq(tail_reader.pages_ready(), 0)
  assert_true(tail_reader.take_skipped().length() > 0)
}
