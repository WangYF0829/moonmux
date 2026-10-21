// dump_wbtest.mbt —— 页级转储排版的测试
//
// 排版也是要测的：一列数值对不齐、偏移算错一位，都是肉眼容易放过、
// 却会让整张表失真的错。而「偏移」这一列是可以拿去和真实文件对照的，
// 所以它必须与 `Page::to_bytes` 写出的布局严格一致。

///|
/// 偏移列必须与序列化后的真实布局一致：按表里的偏移去解析，
/// 解析出来的必须正是那一页。
///
/// 这是把排版与序列化两条路径钉在一起 —— 偏移公式一旦和 `to_bytes`
/// 脱节，这张表就会把用户引到错误的文件位置上去，比不给偏移更糟。
test "page_offsets agree with the serialized layout" {
  let pages = interleaved_pair()
  let blob = serialize_pages(pages)
  let offsets = page_offsets(pages)
  assert_eq(offsets.length(), pages.length())
  assert_eq(offsets[0], 0)
  let mut i = 0
  while i < pages.length() {
    match Page::parse(blob, offsets[i]) {
      Some((page, _)) => {
        assert_eq(page.serial, pages[i].serial)
        assert_eq(page.sequence, pages[i].sequence)
        assert_eq(page.payload.length(), pages[i].payload.length())
      }
      None => assert_true(false)
    }
    i = i + 1
  }
  // 末页偏移 + 末页长度 = 文件总长（说明没有页被算漏或算重）
  let last = pages.length() - 1
  assert_eq(
    offsets[last] +
    27 +
    pages[last].segments.length() +
    pages[last].payload.length(),
    blob.length(),
  )
}

///|
/// 每页一行，且行里带上了该页的身份信息。
test "describe_pages emits one line per page carrying its identity" {
  let pages = interleaved_pair()
  let lines = describe_pages(pages)
  assert_eq(lines.length(), pages.length())
  let mut i = 0
  while i < pages.length() {
    assert_true(lines[i].contains(pages[i].serial.to_string()))
    assert_true(lines[i].contains(pages[i].sequence.to_string()))
    i = i + 1
  }
}

///|
/// 标志列写成文字而不是位掩码：单页流的 BOS 与 EOS 落在同一页上。
test "flags are spelled out" {
  let one = paginate([{ data: b"hi", granule_position: 5L, serial: 1U, }], 1U)
  assert_eq(one.length(), 1)
  let lines = describe_pages(one)
  assert_true(lines[0].contains("BOS+EOS"))

  // 多页流：首页只有 BOS，末页只有 EOS
  let three = paginate(
    [
      { data: b"p1", granule_position: 0L, serial: 2U, },
      { data: b"p2", granule_position: 1L, serial: 2U, },
      { data: b"p3", granule_position: 2L, serial: 2U, },
    ],
    2U,
  )
  assert_eq(three.length(), 3)
  let l = describe_pages(three)
  assert_true(l[0].contains("BOS"))
  assert_true(!l[0].contains("EOS"))
  assert_true(l[2].contains("EOS"))
  assert_true(!l[2].contains("BOS"))
  // 首页与末页之间的数据页没有任何标志
  assert_true(l[1].contains("-"))
}

///|
/// 粒度位置为 -1（本页没有包结束）原样显示为 -1，不伪造成 0。
///
/// 0 与 -1 在粒度语义上完全不同：0 是「时间点 0」，-1 是「这一页不结束任何包」。
/// 把 -1 显示成 0 会让人以为时间倒退了。
test "negative granule is shown as is" {
  let n = 255 * 255 + 1
  let data = repeat_byte((0x41 : Byte), n)
  let pages = paginate([{ data, granule_position: 7L, serial: 9U, }], 9U)
  assert_eq(pages.length(), 2)
  assert_eq(pages[0].granule_position, -1L)
  let lines = describe_pages(pages)
  assert_true(lines[0].contains("-1"))
  assert_true(lines[1].contains("7"))
}

///|
/// 段数与负载两列要反映该页的实际值 —— 超长包跨页时两页的数字不同。
test "segment and payload columns reflect the page" {
  let n = 255 * 255 + 1
  let data = repeat_byte((0x41 : Byte), n)
  let pages = paginate([{ data, granule_position: 0L, serial: 3U, }], 3U)
  let lines = describe_pages(pages)
  // 首页装满了 255 个段
  assert_true(lines[0].contains("255"))
  // 两行不相同（一页满、一页只剩尾段）
  assert_true(!(lines[0] == lines[1]))
}

///|
/// 列标题行不为空，且点出了会让人困惑的那几列的含义。
test "table header names the columns" {
  let h = page_table_header()
  assert_true(h.length() > 0)
  for name in ["偏移", "流号", "页序", "粒度", "标志"] {
    assert_true(h.contains(name))
  }
}

///|
/// 表头与数据行必须占同样的**显示**列宽。
///
/// 汉字一个字占两列，而 `String::length()` 数是它是 1 ——
/// 表头全是中文标签，按 length 补空格会让表头相对数字列整体偏左。
/// 这里用显示宽度比对，并顺带钉住「汉字按两列算」这个前提本身。
test "header and data rows line up in display columns" {
  let pages = interleaved_pair()
  let width = display_width(page_table_header())
  let lines = describe_pages(pages)
  assert_true(lines.length() > 0)
  for line in lines {
    assert_eq(display_width(line), width)
  }
  // 前提本身也要钉住，否则这个测试会退化成按 length 比对
  assert_eq(display_width("偏移"), 4)
  assert_eq(display_width("abc"), 3)
  assert_eq(display_width("BOS+EOS"), 7)
}
