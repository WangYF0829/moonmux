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
  assert_eq(out[2].granule_position, 460L) // 960 - 500
  assert_eq(out[3].granule_position, 940L) // 1440 - 500
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
    Err(msg) => assert_true(msg.contains("没有音频页"))
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
  let out = match chop_pages(pages, 1U, 500L, 2000L) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  // 头两页 + (480,960] 被丢弃 + (960,1440]
  assert_eq(out.length(), 3)
  assert_eq(out[2].granule_position, 940L) // 1440 - 500
  assert_true((out[2].header_type.to_int() & flag_eos().to_int()) != 0)
}
