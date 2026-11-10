// resync_wbtest.mbt —— 容错解析（坏页重同步）的测试

///|
/// 造三页：每包一页，带 BOS / EOS 与递增粒度。
fn three_page_blob() -> Bytes {
  let packets : Array[Packet] = [
    { data: b"AAAA", granule_position: 0L, serial: 1U, },
    { data: b"BBBB", granule_position: 10L, serial: 1U, },
    { data: b"CCCC", granule_position: 20L, serial: 1U, },
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
      { data: b"AAAA", granule_position: 0L, serial: 1U, },
      { data: b"BBBB", granule_position: 10L, serial: 1U, },
      { data: b"CCCC", granule_position: 20L, serial: 1U, },
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
    paginate([{ data: b"R", granule_position: 0L, serial: 1U, }], 1U),
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
    [{ data: b"xxOggSyy", granule_position: 0L, serial: 2U, }],
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
      { data: b"AAAA", granule_position: 0L, serial: 1U, },
      { data: b"BBBB", granule_position: 10L, serial: 1U, },
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

///|
/// 带页头保留位（RFC 3533 要求为 0，但 `Page::parse` 只校验 version）的页：
/// 严格解析接受它，容错解析也必须接受 —— `plausible_page_start` 只用于
/// 筛选候选，不能当合法性判据，否则 info 接受的文件会被 verify 判成
/// 「不是合法 Ogg」并触发全文件重同步（M-26 回归）。
fn reserved_bit_blob() -> Bytes {
  let pages : Array[Page] = [
    {
      header_type: (0x0A : Byte), // BOS + 保留位 0x08
      granule_position: 0L,
      serial: 1U,
      sequence: 0U,
      crc: 0U,
      segments: [4],
      payload: b"HEAD",
    },
    {
      header_type: (0x0C : Byte), // EOS + 保留位 0x08
      granule_position: 960L,
      serial: 1U,
      sequence: 1U,
      crc: 0U,
      segments: [4],
      payload: b"DATA",
    },
  ]
  serialize_pages(pages)
}

///|
test "lenient parsing accepts every page strict parsing accepts (reserved bits)" {
  let blob = reserved_bit_blob()
  let strict = parse_pages(blob)
  assert_eq(strict.length(), 2)
  let (lenient, gaps) = parse_pages_lenient(blob)
  assert_eq(lenient.length(), strict.length())
  assert_eq(gaps.length(), 0)
  // 保留位随页头原样保留，没有被改写
  assert_eq(lenient[0].header_type.to_int(), 0x0A)
}

///|
/// 稠密伪页头洪水：1 个垃圾字节 + 每 6 字节一个 `OggS\0\0`，每个候选都能
/// 通过预筛并凑出一页的段表（约 6.4 KB），但 CRC 必然不符。
///
/// 旧实现会为每个候选做「整页物化 + 整页重算 CRC」，实测 1 MiB ≈ 4 s；
/// 新实现（零拷贝 CRC + 确定性预算）必须在扫描少量字节后即判定伪页头洪水。
fn fake_header_flood(reps : Int32) -> Bytes {
  let buf = Buffer()
  buf.write_byte((0x4A : Byte)) // 让 offset 0 不是页头，强制走重同步
  let mut i = 0
  while i < reps {
    buf.write_bytes(b"OggS".exact_view())
    buf.write_byte((0 : Byte))
    buf.write_byte((0 : Byte))
    i = i + 1
  }
  buf.to_bytes()
}

///|
test "checked lenient parsing reports a fake-header flood instead of scanning" {
  let flood = fake_header_flood(11000) // 66,001 字节
  match parse_pages_lenient_checked(flood) {
    Ok(_) => assert_true(false) // 必须拒绝：这是伪页头洪水
    Err(msg) => assert_true(msg.contains("伪页头洪水"))
  }
}

///|
/// 兼容旧签名的 `parse_pages_lenient` 不能返回 Err，但同样必须有限终止：
/// 超预算后把剩余字节整体记为跳过区间（确定性结果，不依赖计时）。
test "legacy lenient parsing stays bounded on a fake-header flood" {
  let flood = fake_header_flood(11000)
  let (pages, gaps) = parse_pages_lenient(flood)
  assert_eq(pages.length(), 0)
  let mut skipped = 0
  for gap in gaps {
    assert_true(gap.bytes > 0)
    skipped = skipped + gap.bytes
  }
  assert_eq(skipped, flood.length())
}

///|
/// 控制组：正常文件不得被误判为伪页头洪水。
test "checked lenient parsing accepts normal files" {
  let blob = three_page_blob()
  match parse_pages_lenient_checked(blob) {
    Ok((pages, gaps)) => {
      assert_eq(pages.length(), 3)
      assert_eq(gaps.length(), 0)
    }
    Err(_) => assert_true(false)
  }
}
