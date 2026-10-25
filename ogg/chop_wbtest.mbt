///|
/// 造一个只有一页的流片段，便于精确控制粒度与标志。
fn chop_mk_page(
  data : Bytes,
  granule : Int64,
  serial : UInt32,
  seq : UInt32,
  header : Byte,
) -> Page {
  {
    header_type: header,
    granule_position: granule,
    serial,
    sequence: seq,
    crc: 0U,
    segments: [data.length()],
    payload: data,
  }
}

///|
/// 裁剪保留与区间相交的页：头页整段保留、序号重排、末页补 EOS。
test "chop keeps header pages, overlapping data pages and closes the stream" {
  let pages : Array[Page] = [
    chop_mk_page(b"head", 0L, 1U, 0U, flag_bos()),
    chop_mk_page(b"tags", 0L, 1U, 1U, 0),
    chop_mk_page(b"a", 480L, 1U, 2U, 0),
    chop_mk_page(b"b", 960L, 1U, 3U, 0),
    chop_mk_page(b"c", 1440L, 1U, 4U, 0),
    chop_mk_page(b"d", 1920L, 1U, 5U, flag_eos()),
  ]
  let out = match chop_pages(pages, 1U, 500L, 1000L) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  // 头两页 + 与 [500,1000) 相交的两页（(480,960] 与 (960,1440]）
  assert_eq(out.length(), 4)
  assert_eq(out[0].granule_position, 0L)
  assert_eq(out[1].granule_position, 0L)
  // 首张保留页的基准是它之前的 480，而不是请求的 500：
  // 页不拆包，必须让首页粒度等于它实际携带的完整页样本数。
  assert_eq(out[2].granule_position, 480L) // 960 - 480
  assert_eq(out[3].granule_position, 960L) // 1440 - 480
  let mut i = 0
  while i < out.length() {
    assert_eq(out[i].sequence, i.reinterpret_as_uint())
    i = i + 1
  }
  assert_true((out[0].header_type.to_int() & flag_bos().to_int()) != 0)
  assert_true((out[3].header_type.to_int() & flag_eos().to_int()) != 0)
  let mut errors = 0
  for f in structure_findings(out) {
    match f.severity {
      Severity::Error => errors = errors + 1
      _ => ()
    }
  }
  assert_eq(errors, 0)
  // 序列化后 CRC 必须全部通过
  let bytes = serialize_pages(out)
  for p in parse_pages(bytes) {
    assert_true(page_crc_ok(p))
  }
}

///|
/// 区间落在数据之外：明确报错，不产出空文件。
test "chop rejects a range without audio pages" {
  let pages : Array[Page] = [
    chop_mk_page(b"head", 0L, 1U, 0U, flag_bos()),
    chop_mk_page(b"tags", 0L, 1U, 1U, 0),
    chop_mk_page(b"a", 480L, 1U, 2U, flag_eos()),
  ]
  match chop_pages(pages, 1U, 5000L, 6000L) {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.contains("超过流的末粒度"))
  }
  match chop_pages(pages, 1U, 100L, 100L) {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.contains("大于起点"))
  }
}

///|
/// 多逻辑流与链接流都拒绝：先 extract / split 再裁。
test "chop rejects multi-stream and chained inputs" {
  let multi : Array[Page] = [
    chop_mk_page(b"h1", 0L, 1U, 0U, flag_bos()),
    chop_mk_page(b"h2", 0L, 2U, 0U, flag_bos()),
    chop_mk_page(b"a", 480L, 1U, 1U, flag_eos()),
    chop_mk_page(b"b", 480L, 2U, 1U, flag_eos()),
  ]
  match chop_pages(multi, 1U, 0L, 1000L) {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.contains("一次只处理一条逻辑流"))
  }
  let chained : Array[Page] = [
    chop_mk_page(b"h1", 0L, 1U, 0U, flag_bos()),
    chop_mk_page(b"a", 480L, 1U, 1U, flag_eos()),
    chop_mk_page(b"h2", 0L, 2U, 0U, flag_bos()),
    chop_mk_page(b"b", 480L, 2U, 1U, flag_eos()),
  ]
  match chop_pages(chained, 1U, 0L, 1000L) {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.contains("先 split"))
  }
}

///|
/// 起点落在跨页包中间时，丢掉带 continued 标志的第一页，
/// 否则输出会以一个「缺了开头」的包起手。
test "chop drops a leading continued page" {
  let pages : Array[Page] = [
    chop_mk_page(b"head", 0L, 1U, 0U, flag_bos()),
    chop_mk_page(b"tags", 0L, 1U, 1U, 0),
    chop_mk_page(b"a", 480L, 1U, 2U, 0),
    // 这一页延续上一页的包：不能作为输出的第一张数据页
    chop_mk_page(b"b", 960L, 1U, 3U, flag_continued()),
    chop_mk_page(b"c", 1440L, 1U, 4U, flag_eos()),
  ]
  let out = match chop_pages(pages, 1U, 500L, 1440L) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  // 头两页 + (480,960] 被丢弃 + (960,1440]
  assert_eq(out.length(), 3)
  // 丢弃的续页结束于 960，首张实际保留页从 960 重基
  assert_eq(out[2].granule_position, 480L) // 1440 - 960
  assert_true((out[2].header_type.to_int() & flag_eos().to_int()) != 0)
}

///|
/// start 恰好等于页尾时，该页与 [start,end) 没有交集，不能多保留一整页。
test "chop excludes a page ending exactly at start" {
  let pages : Array[Page] = [
    chop_mk_page(b"head", 0L, 1U, 0U, flag_bos()),
    chop_mk_page(b"tags", 0L, 1U, 1U, 0),
    chop_mk_page(b"a", 480L, 1U, 2U, 0),
    chop_mk_page(b"b", 960L, 1U, 3U, 0),
    chop_mk_page(b"c", 1440L, 1U, 4U, flag_eos()),
  ]
  let out = match chop_pages(pages, 1U, 480L, 960L) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  // 只保留 (480,960] 这一页；头两页仍在
  assert_eq(out.length(), 3)
  assert_eq(out[2].granule_position, 480L)
}

///|
/// 首个音频页前有 0 段页（粒度 -1）时，重基不能取 -1，否则全部粒度 +1。
test "chop ignores empty header page when rebasing" {
  let pages : Array[Page] = [
    chop_mk_page(b"head", 0L, 1U, 0U, flag_bos()),
    chop_mk_page(b"tags", 0L, 1U, 1U, 0),
    chop_mk_page(b"", -1L, 1U, 2U, 0),
    chop_mk_page(b"a", 960L, 1U, 3U, flag_eos()),
  ]
  // 空页的段表必须是 []，而不是 [0]
  pages[2] = {
    header_type: 0,
    granule_position: -1L,
    serial: 1U,
    sequence: 2U,
    crc: 0U,
    segments: [],
    payload: b"",
  }
  let out = match chop_pages(pages, 1U, 0L, 960L) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  assert_eq(out[out.length() - 1].granule_position, 960L)
}

///|
/// 首个音频包跨页时，头页里已有它的开头，不能丢掉续页留下半包。
test "chop keeps a first audio packet spanning from header prefix" {
  let pages : Array[Page] = [
    chop_mk_page(b"head", 0L, 1U, 0U, flag_bos()),
    chop_mk_page(b"tags", 0L, 1U, 1U, 0),
    chop_mk_page(repeat_byte((0x41 : Byte), 255), -1L, 1U, 2U, 0),
    chop_mk_page(b"ZZZZZ", 960L, 1U, 3U, flag_continued()),
    chop_mk_page(b"B", 1440L, 1U, 4U, flag_eos()),
  ]
  let out = match chop_pages(pages, 1U, 0L, 1440L) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  assert_eq(out.length(), 5)
  assert_eq(structure_findings(out).length(), 0)
  // 半包与续页都在，且首页完整包的粒度没有被 -1 偏移
  assert_eq(out[3].granule_position, 960L)
  assert_eq(out[4].granule_position, 1440L)
  let packets = reassemble(out)
  assert_eq(packets.length(), 4)
  assert_eq(packets[2].data.length(), 260)
}

///|
/// 跨页首包落在起点之前时，其头半页必须一起丢掉，不能留下无续页的半包。
test "chop trims a leading half packet when its continuation is excluded" {
  let pages : Array[Page] = [
    chop_mk_page(b"head", 0L, 1U, 0U, flag_bos()),
    chop_mk_page(b"tags", 0L, 1U, 1U, 0),
    chop_mk_page(repeat_byte((0x41 : Byte), 255), -1L, 1U, 2U, 0),
    chop_mk_page(b"ZZZZZ", 960L, 1U, 3U, flag_continued()),
    chop_mk_page(b"B", 1440L, 1U, 4U, flag_eos()),
  ]
  // 起点 1000 已越过首个音频包的结束页（960），续页 P3 不入选
  let out = match chop_pages(pages, 1U, 1000L, 1440L) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  // 头两页 + 后续完整页；P2 的半包被一并删掉
  assert_eq(out.length(), 3)
  assert_eq(out[2].granule_position, 480L) // 1440 - 960
  assert_eq(structure_findings(out).length(), 0)
  let mut i = 0
  while i < out.length() {
    assert_eq(out[i].sequence, i.reinterpret_as_uint())
    i = i + 1
  }
}

///|
/// 用多段负载构造一页，便于模拟一页结束一个包并开始下一个跨页包。
fn chop_mk_parts_page(
  parts : Array[Bytes],
  granule : Int64,
  serial : UInt32,
  seq : UInt32,
  header : Byte,
) -> Page {
  let segs : Array[Int32] = []
  let buf = Buffer()
  for part in parts {
    segs.push(part.length())
    buf.write_bytes(part.exact_view())
  }
  {
    header_type: header,
    granule_position: granule,
    serial,
    sequence: seq,
    crc: 0U,
    segments: segs,
    payload: buf.to_bytes(),
  }
}

///|
/// 跨页包中间没有完成页（granule=-1）时，不能整页丢掉。
test "chop keeps payload pages without packet completion" {
  let middle = repeat_byte((0x42 : Byte), 255)
  let tail = b"ZZZZZ"
  let pages : Array[Page] = [
    chop_mk_page(b"head", 0L, 1U, 0U, flag_bos()),
    chop_mk_page(b"tags", 0L, 1U, 1U, 0),
    chop_mk_parts_page([b"x", middle], 48000L, 1U, 2U, 0),
    chop_mk_page(middle, -1L, 1U, 3U, flag_continued()),
    chop_mk_page(tail, 96000L, 1U, 4U, flag_continued() | flag_eos()),
  ]
  let before = reassemble(pages)
  let out = match chop_pages(pages, 1U, 0L, 96000L) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  let after = reassemble(out)
  assert_eq(after.length(), before.length())
  assert_eq(after[3].data.length(), before[3].data.length())
  assert_eq(structure_findings(out).length(), 0)
}

///|
/// 终点落在带续包的页尾时，向后补齐整个包，输出仍结构完好。
test "chop completes a trailing partial packet" {
  let pages : Array[Page] = [
    chop_mk_page(b"head", 0L, 1U, 0U, flag_bos()),
    chop_mk_page(b"tags", 0L, 1U, 1U, 0),
    chop_mk_parts_page(
      [b"x", repeat_byte((0x42 : Byte), 255)],
      48000L,
      1U,
      2U,
      0,
    ),
    chop_mk_page(b"Z", 96000L, 1U, 3U, flag_continued() | flag_eos()),
  ]
  let out = match chop_pages(pages, 1U, 0L, 48000L) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  assert_eq(out.length(), 4)
  assert_eq(structure_findings(out).length(), 0)
}

///|
/// 起点恰好等于页尾，而下一张是续页：把起点页作为预卷补回，不能报空区间。
test "chop prepends the start page of an intersecting continuation" {
  let built : Array[Page] = [
    chop_mk_page(b"head", 0L, 1U, 0U, flag_bos()),
    chop_mk_page(b"tags", 0L, 1U, 1U, 0),
    chop_mk_parts_page(
      [b"x", repeat_byte((0x42 : Byte), 255)],
      48000L,
      1U,
      2U,
      0,
    ),
    chop_mk_page(b"Z", 96000L, 1U, 3U, flag_continued() | flag_eos()),
  ]
  let out = match chop_pages(built, 1U, 48000L, 96000L) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  // 头两页 + 预卷起点页 + 续页
  assert_eq(out.length(), 4)
  assert_eq(structure_findings(out).length(), 0)
}

///|
/// 已知头包数量时，首音频页上的多个完整包可以安全判定为音频并排除。
test "chop uses expected header count to disambiguate a multi-packet page" {
  let pages : Array[Page] = [
    chop_mk_page(b"head", 0L, 1U, 0U, flag_bos()),
    chop_mk_page(b"tags", 0L, 1U, 1U, 0),
    {
      header_type: 0,
      granule_position: 480L,
      serial: 1U,
      sequence: 2U,
      crc: 0U,
      segments: [1, 1],
      payload: b"ab",
    },
    chop_mk_page(b"Z", 960L, 1U, 3U, flag_eos()),
  ]
  let out = match chop_pages(pages, 1U, 500L, 960L, header_packets=2) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  assert_eq(out.length(), 3)
  assert_eq(structure_findings(out).length(), 0)
  // 未提供头包数量时保持保守，宁拒绝不丢头
  match chop_pages(pages, 1U, 500L, 960L) {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.contains("共用页面"))
  }
}

///|
/// 首音频页“完成旧包 + 开启新跨页包”时，回溯必须停在该页，不能把两个包拼接。
test "chop stops packet backtrace at a page that completes a packet" {
  let tags = repeat_byte((0x54 : Byte), 10)
  let a1_parts = [
    repeat_byte((0x41 : Byte), 5),
    repeat_byte((0x58 : Byte), 255),
  ]
  let pages : Array[Page] = [
    chop_mk_page(b"head", 0L, 1U, 0U, flag_bos()),
    chop_mk_parts_page([tags, repeat_byte((0x57 : Byte), 255)], 0L, 1U, 1U, 0),
    chop_mk_parts_page(a1_parts, 960L, 1U, 2U, flag_continued()),
    chop_mk_page(repeat_byte((0x58 : Byte), 255), -1L, 1U, 3U, flag_continued()),
    chop_mk_page(
      repeat_byte((0x58 : Byte), 5),
      1920L,
      1U,
      4U,
      flag_continued() | flag_eos(),
    ),
  ]
  let before = reassemble(pages)
  let out = match chop_pages(pages, 1U, 1000L, 1920L, header_packets=2) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  let after = reassemble(out)
  assert_eq(after.length(), before.length())
  assert_eq(after[2].data.length(), before[2].data.length())
  assert_eq(after[3].data.length(), before[3].data.length())
  assert_eq(structure_findings(out).length(), 0)
}

///|
/// 首个音频页与完整头包共用、且该页被排除时，必须报错而不是丢掉头包。
test "chop rejects dropping a shared header page" {
  let tags = repeat_byte((0x54 : Byte), 20)
  let pages : Array[Page] = [
    chop_mk_page(b"head", 0L, 1U, 0U, flag_bos()),
    chop_mk_parts_page(
      [tags, repeat_byte((0x42 : Byte), 255)],
      48000L,
      1U,
      1U,
      0,
    ),
    chop_mk_page(b"Z", 96000L, 1U, 2U, flag_continued()),
    chop_mk_page(b"B", 144000L, 1U, 3U, flag_eos()),
  ]
  match chop_pages(pages, 1U, 100000L, 144000L) {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.contains("共用页面"))
  }
}

///|
/// 0 段页夹在跨页包中间时，向前回溯包开头必须跳过它。
test "chop continuation lookup skips zero-segment pages" {
  let head = chop_mk_page(b"head", 0L, 1U, 0U, flag_bos())
  let tags = chop_mk_page(b"tags", 0L, 1U, 1U, 0)
  let first = chop_mk_page(repeat_byte((0x41 : Byte), 255), -1L, 1U, 2U, 0)
  let empty : Page = {
    header_type: 0,
    granule_position: -1L,
    serial: 1U,
    sequence: 3U,
    crc: 0U,
    segments: [],
    payload: b"",
  }
  let last = chop_mk_page(b"Z", 960L, 1U, 4U, flag_continued() | flag_eos())
  let pages = [head, tags, first, empty, last]
  let out = match chop_pages(pages, 1U, 0L, 960L) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  assert_eq(structure_findings(out).length(), 0)
  let packets = reassemble(out)
  assert_eq(packets.length(), 3)
  assert_eq(packets[2].data.length(), 256)
}

///|
/// 终点超过末粒度：明确报错，避免「请求 2 秒、实际给 1 秒」的静默截短。
test "chop rejects an end beyond the last granule" {
  let pages : Array[Page] = [
    chop_mk_page(b"head", 0L, 1U, 0U, flag_bos()),
    chop_mk_page(b"tags", 0L, 1U, 1U, 0),
    chop_mk_page(b"a", 960L, 1U, 2U, flag_eos()),
  ]
  match chop_pages(pages, 1U, 0L, 2000L) {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.contains("超过流的末粒度"))
  }
}
