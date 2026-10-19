// resync_wbtest.mbt —— 容错解析（坏页重同步）的测试

///|
/// 造三页：每包一页，带 BOS / EOS 与递增粒度。
fn three_page_blob() -> Bytes {
  let packets : Array[Packet] = [
    { data: b"AAAA", granule_position: 0L, serial: 1U },
    { data: b"BBBB", granule_position: 10L, serial: 1U },
    { data: b"CCCC", granule_position: 20L, serial: 1U },
  ]
  serialize_pages(paginate(packets, 1U))
}

///|
/// 完好数据：与严格解析结果一致，且没有任何跳过区间。
test "lenient parsing matches strict on clean input" {
  let blob = three_page_blob()
  let (pages, gaps) = parse_pages_lenient(blob)
  assert_eq(pages.length(), parse_pages(blob).length())
  assert_eq(pages.length(), 3)
  assert_eq(gaps.length(), 0)
}

///|
/// 文件头前面有垃圾：跳过它，从第一个有效页开始。
test "garbage prefix is skipped" {
  let prefix = b"JUNKJUNK"
  let buf = Buffer()
  buf.write_bytes(prefix.exact_view())
  buf.write_bytes(three_page_blob().exact_view())
  let (pages, gaps) = parse_pages_lenient(buf.to_bytes())
  assert_eq(pages.length(), 3)
  assert_eq(gaps.length(), 1)
  assert_eq(gaps[0].offset, 0)
  assert_eq(gaps[0].bytes, 8)
}

///|
/// 中间一页被破坏：前后两页仍能救回来，跳过的字节数正好是被破坏页的长度。
test "a corrupted middle page is skipped and the rest recovered" {
  let original = three_page_blob()
  let pages = paginate(
    [
      { data: b"AAAA", granule_position: 0L, serial: 1U },
      { data: b"BBBB", granule_position: 10L, serial: 1U },
      { data: b"CCCC", granule_position: 20L, serial: 1U },
    ],
    1U,
  )
  let mid = pages[1]
  let mid_size = 27 + mid.segments.length() + mid.payload.length()
  // 把第二页的捕获模式打成垃圾
  let buf = Buffer()
  buf.write_bytes(b"XXXX".exact_view())
  let mut i = 4
  let blob = original
  let start = 27 + pages[0].segments.length() + pages[0].payload.length()
  while i < mid_size {
    buf.write_byte(blob[start + i])
    i = i + 1
  }
  let patched_buf = Buffer()
  let mut k = 0
  while k < start {
    patched_buf.write_byte(blob[k])
    k = k + 1
  }
  patched_buf.write_bytes(buf.to_bytes().exact_view())
  let mut tail = start + mid_size
  while tail < blob.length() {
    patched_buf.write_byte(blob[tail])
    tail = tail + 1
  }
  let (recovered, gaps) = parse_pages_lenient(patched_buf.to_bytes())
  assert_eq(recovered.length(), 2)
  assert_eq(gaps.length(), 1)
  assert_eq(gaps[0].offset, start)
  assert_eq(gaps[0].bytes, mid_size)
  // 救回来的两页仍是第 0 页与第 2 页
  assert_eq(recovered[0].sequence, 0U)
  assert_eq(recovered[1].sequence, 2U)
}

///|
/// 重同步扫描必须用 CRC 复核候选位置 —— 只搜魔数会把数据当成页首。
///
/// 这里在前导垃圾之后放一个「结构上像页、CRC 对不上」的假页头，
/// 再放一个真页：扫描应当越过假页头、落在真页上。
test "a fake page start is rejected while resyncing" {
  let fake = Buffer()
  fake.write_bytes(b"OggS".exact_view())
  // 27 字节假页头：版本 0、标志 0、粒度 0、流号 0、页序 0、CRC 0、段数 0
  let mut i = 4
  while i < 27 {
    fake.write_byte((0x00 : Byte))
    i = i + 1
  }
  let real = serialize_pages(
    paginate([{ data: b"R", granule_position: 0L, serial: 1U }], 1U),
  )
  let data = Buffer()
  data.write_bytes(b"GARBAGE!".exact_view())
  data.write_bytes(fake.to_bytes().exact_view())
  data.write_bytes(real.exact_view())
  let (pages, gaps) = parse_pages_lenient(data.to_bytes())
  // 只收到那个真页
  assert_eq(pages.length(), 1)
  assert_eq(pages[0].payload.length(), 1)
  // 垃圾 8 字节 + 假页头 27 字节，一并记为跳过
  assert_eq(gaps.length(), 1)
  assert_eq(gaps[0].bytes, 8 + 27)
}

///|
/// 文件开头就是假页头时，结构解析会收下它（无从仅凭结构分辨），
/// 但 CRC 校验必须判它无效 —— 「能解析」与「没坏」是两件事。
test "a fake page at offset zero parses structurally but fails crc" {
  let buf = Buffer()
  buf.write_bytes(b"OggS".exact_view())
  let mut i = 4
  while i < 27 {
    buf.write_byte((0x00 : Byte))
    i = i + 1
  }
  let (pages, _gaps) = parse_pages_lenient(buf.to_bytes())
  assert_eq(pages.length(), 1)
  assert_true(!page_crc_ok(pages[0]))
}

///|
/// 正常页的负载里带 "OggS" 不影响解析（可信位置上不需要重同步）。
test "ogg magic inside a payload does not disturb parsing" {
  let pages = paginate(
    [{ data: b"xxOggSyy", granule_position: 0L, serial: 2U }],
    2U,
  )
  let blob = serialize_pages(pages)
  let (parsed, gaps) = parse_pages_lenient(blob)
  assert_eq(parsed.length(), 1)
  assert_eq(gaps.length(), 0)
  assert_eq(parsed[0].payload.length(), 8)
}

///|
/// 末尾被截断：前面的页照常给出，截断部分记为一个跳过区间。
test "a truncated tail becomes a skipped range" {
  let pages = paginate(
    [
      { data: b"AAAA", granule_position: 0L, serial: 1U },
      { data: b"BBBB", granule_position: 10L, serial: 1U },
    ],
    1U,
  )
  let blob = serialize_pages(pages)
  let cut = Buffer()
  let mut i = 0
  while i < blob.length() - 5 {
    cut.write_byte(blob[i])
    i = i + 1
  }
  let (parsed, gaps) = parse_pages_lenient(cut.to_bytes())
  assert_eq(parsed.length(), 1)
  assert_eq(gaps.length(), 1)
  // 跳过区间从第二页起点一直到文件末尾：整页长度减去被切掉的 5 字节
  assert_eq(gaps[0].offset, 27 + pages[0].segments.length() + 4)
  assert_eq(gaps[0].bytes, 27 + pages[1].segments.length() + 4 - 5)
}
