// patch_wbtest.mbt —— 页补丁原语的测试

///|
/// 三页样本。
fn patch_stream() -> Array[Page] {
  paginate(
    [
      { data: b"a", granule_position: 0L, serial: 1U, },
      { data: b"bb", granule_position: 10L, serial: 1U, },
      { data: b"ccc", granule_position: 20L, serial: 1U, },
    ],
    1U,
  )
}

///|
/// 改一页的粒度：只有那一页的字节变化，其余页逐字节不动。
test "patching a granule touches only that page" {
  let pages = patch_stream()
  let before = pages.map(fn(p) { p.to_bytes() })
  // 新粒度必须落在前后两页之间：补丁本身不该制造时间倒流
  let updated = match patch_page(pages, 1, granule=15L) {
    Ok(p) => p
    Err(_) => []
  }
  assert_eq(updated.length(), pages.length())
  assert_eq(updated[1].granule_position, 15L)
  let after = updated.map(fn(p) { p.to_bytes() })
  assert_true(!same_bytes(before[1], after[1]))
  assert_true(same_bytes(before[0], after[0]))
  assert_true(same_bytes(before[2], after[2]))
  // 补丁后的页自洽
  assert_true(page_crc_ok(parse_pages(serialize_pages(updated))[1]))
  assert_eq(structure_problems(updated).length(), 0)
}

///|
/// 只给标志时粒度不变；两个都不给时等于原样复制。
test "patch_page keeps omitted fields intact" {
  let pages = patch_stream()
  let marked = match
    patch_page(pages, 2, header=pages[2].header_type | flag_eos()) {
    Ok(p) => p
    Err(_) => []
  }
  assert_eq(marked[2].granule_position, pages[2].granule_position)
  assert_true((marked[2].header_type.to_int() & flag_eos().to_int()) != 0)
  let same = match patch_page(pages, 0) {
    Ok(p) => p
    Err(_) => []
  }
  assert_true(same_bytes(serialize_pages(same), serialize_pages(pages)))
}

///|
/// 下标越界要报错。
test "patch_page reports an out of range index" {
  match patch_page(patch_stream(), 9, granule=1L) {
    Err(msg) => assert_true(msg.contains("越界"))
    Ok(_) => assert_true(false)
  }
}

///|
/// `set_eos` 只给末页补标志，且是幂等的。
test "set_eos marks the last page once" {
  let pages = patch_stream()
  // 先清掉末页 EOS，模拟被裁剪过的文件
  let stripped = match
    patch_page(pages, 2, header=pages[2].header_type & 0xFB) {
    Ok(p) => p
    Err(_) => []
  }
  let fixed = match set_eos(stripped, 1U) {
    Ok(p) => p
    Err(_) => []
  }
  assert_true((fixed[2].header_type.to_int() & flag_eos().to_int()) != 0)
  assert_true(same_bytes(serialize_pages(fixed), serialize_pages(pages)))
  // 再来一次不应再改
  let again = match set_eos(fixed, 1U) {
    Ok(p) => p
    Err(_) => []
  }
  assert_true(same_bytes(serialize_pages(again), serialize_pages(fixed)))
  match set_eos(fixed, 42U) {
    Err(msg) => assert_true(msg.contains("serial"))
    Ok(_) => assert_true(false)
  }
}
