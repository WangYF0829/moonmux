// page_reader_wbtest.mbt —— 增量页读取器的测试
//
// 核心断言：任意分块方式喂入，解析结果与一次性 `parse_pages` 相同；
// 前缀垃圾/截断/坏 CRC 的跳过区间符合预期。

///|
fn pr_same_bytes(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut i = 0
  while i < a.length() {
    if a[i].to_int() != b[i].to_int() {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// 合成一段普通的单逻辑流 Ogg（3 个包，两个音频包）。
fn pr_stream() -> Bytes {
  let packets : Array[Packet] = [
    { data: b"head", granule_position: 0L, serial: 1U, },
    { data: b"tags", granule_position: 0L, serial: 1U, },
    { data: b"\xfc\x01\x02\x03\x04", granule_position: 960L, serial: 1U, },
    { data: b"\xfc\x05\x06", granule_position: 1920L, serial: 1U, },
    { data: b"\xfc\x07", granule_position: 2880L, serial: 1U, },
  ]
  serialize_pages(paginate(packets, 1U))
}

///|
/// 收集「分块喂入 + finish」后的页与跳过区间。
fn pr_collect_chunked(
  data : Bytes,
  chunk : Int32,
) -> (Array[Page], Array[Skipped]) {
  let reader = PageReader::new()
  let mut off = 0
  while off < data.length() {
    let end = if off + chunk > data.length() {
      data.length()
    } else {
      off + chunk
    }
    reader.feed(slice_bytes(data, off, end))
    off = end
  }
  reader.finish()
  (reader.take_pages(), reader.take_skipped())
}

///|
test "page reader: whole chunk equals parse_pages" {
  let stream = pr_stream()
  let expected = parse_pages(stream)
  let reader = PageReader::new()
  reader.feed(stream)
  assert_eq(reader.pages_ready(), expected.length())
  let pages = reader.take_pages()
  assert_true(pr_same_bytes(serialize_pages(pages), serialize_pages(expected)))
  reader.finish()
  assert_eq(reader.take_skipped().length(), 0)
}

///|
test "page reader: any chunk size yields identical pages" {
  let stream = pr_stream()
  let expected = serialize_pages(parse_pages(stream))
  let sizes : Array[Int32] = [1, 2, 3, 5, 7, 13, 64, 255, 1024]
  for size in sizes {
    let (pages, gaps) = pr_collect_chunked(stream, size)
    assert_true(pr_same_bytes(serialize_pages(pages), expected))
    assert_eq(gaps.length(), 0)
  }
}

///|
test "page reader: take_pages clears the ready queue" {
  let reader = PageReader::new()
  reader.feed(pr_stream())
  assert_true(reader.pages_ready() > 0)
  let _ = reader.take_pages()
  assert_eq(reader.pages_ready(), 0)
}

///|
test "page reader: leading garbage and truncated tail are skipped" {
  let stream = pr_stream()
  let all = parse_pages(stream)
  // 前缀垃圾 + 被砍掉最后 10 字节的流（截断在末页中间）
  let garbage : Bytes = b"garbage!"
  let cut = stream.length() - 10
  let truncated = slice_bytes(stream, 0, cut)
  let data = append_bytes(garbage, truncated)
  let (pages, gaps) = pr_collect_chunked(data, 7)
  // 末页不完整，只应解析出前面的页
  assert_eq(pages.length(), all.length() - 1)
  // 末页在完整流里的起点 = 前面所有完整页长度之和
  let mut last_page_start = 0
  let mut i = 0
  while i < all.length() - 1 {
    last_page_start = last_page_start +
      27 +
      all[i].segments.length() +
      all[i].payload.length()
    i = i + 1
  }
  // 前缀垃圾可能被切成多段 gap（分块喂入 + 末尾 3 字节保留策略）
  assert_eq(gaps[0].offset, 0)
  let mut head_skipped = 0
  for g in gaps {
    if g.offset < garbage.length() {
      head_skipped = head_skipped + g.bytes
    }
  }
  assert_eq(head_skipped, garbage.length())
  // 其余 gap 是截断尾巴：截断页在缓冲区里剩下的字节都被记为 skipped，
  // 且结束位置恰好落在被砍掉的末尾（garbage.length + cut）
  let mut tail_skipped = 0
  let mut tail_end = 0
  for g in gaps {
    if g.offset >= garbage.length() {
      tail_skipped = tail_skipped + g.bytes
      tail_end = g.offset + g.bytes
    }
  }
  assert_eq(tail_skipped, cut - last_page_start)
  assert_eq(tail_end, garbage.length() + cut)
}

///|
test "page reader: corrupted CRC page is resynced" {
  let stream = pr_stream()
  let pages = parse_pages(stream)
  let first_len = 27 + pages[0].segments.length() + pages[0].payload.length()
  // 复制并翻转第一页最后一个负载字节（不更新 CRC）
  let buf = Buffer()
  let mut i = 0
  while i < stream.length() {
    let v = if i == first_len - 1 {
      (stream[i].to_int() ^ 0xFF).to_byte()
    } else {
      stream[i]
    }
    buf.write_byte(v)
    i = i + 1
  }
  let corrupt = buf.to_bytes()
  let reader = PageReader::new()
  reader.feed(corrupt)
  reader.finish()
  let parsed = reader.take_pages()
  // 坏页被跳过，其余页仍然解析出来
  assert_eq(parsed.length(), pages.length() - 1)
  let gaps = reader.take_skipped()
  let mut skipped = 0
  for g in gaps {
    skipped = skipped + g.bytes
  }
  assert_eq(skipped, first_len)
}

///|
test "page reader: verify_crc=false accepts a bad CRC page" {
  let stream = pr_stream()
  let pages = parse_pages(stream)
  let first_len = 27 + pages[0].segments.length() + pages[0].payload.length()
  let buf = Buffer()
  let mut i = 0
  while i < stream.length() {
    let v = if i == first_len - 1 {
      (stream[i].to_int() ^ 0xFF).to_byte()
    } else {
      stream[i]
    }
    buf.write_byte(v)
    i = i + 1
  }
  let reader = PageReader::with_options(false, true)
  reader.feed(buf.to_bytes())
  assert_eq(reader.take_pages().length(), pages.length())
}

///|
test "page reader: strict mode refuses to resync" {
  let stream = pr_stream()
  let reader = PageReader::with_options(true, false)
  reader.feed(append_bytes(b"junk-before-stream", stream))
  assert_eq(reader.take_pages().length(), 0)
  reader.finish()
  let gaps = reader.take_skipped()
  assert_eq(gaps.length(), 1)
  assert_eq(gaps[0].bytes, 18 + stream.length())
}

///|
test "page reader: for_each_page_chunked convenience matches parse_pages" {
  let stream = pr_stream()
  let collected : Array[Page] = []
  let gaps = for_each_page_chunked(stream, 11, fn(page) { collected.push(page) })
  assert_eq(gaps.length(), 0)
  assert_true(
    pr_same_bytes(
      serialize_pages(collected),
      serialize_pages(parse_pages(stream)),
    ),
  )
}
