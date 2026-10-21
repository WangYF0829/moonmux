// packet_edit_wbtest.mbt —— 包替换原语的测试

///|
/// 造一条四包四页的单流文件：标识包、注释包、两个音频包。
fn four_packet_stream(serial : UInt32) -> Array[Page] {
  paginate(
    [
      { data: b"IDHEADER01", granule_position: 0L, serial, },
      { data: b"COMMENT-HEADER-DATA", granule_position: 0L, serial, },
      { data: repeat_byte((0x41 : Byte), 100), granule_position: 960L, serial, },
      {
        data: repeat_byte((0x42 : Byte), 100),
        granule_position: 1920L,
        serial,
      },
    ],
    serial,
  )
}

///|
/// 等长替换：页数、页序号、其余包全不变，只有目标包的字节变了。
test "replacing a packet of equal size touches only that page" {
  let pages = four_packet_stream(7U)
  let before = reassemble(pages)
  let replacement = b"COMMENT-HEADER-DATA" // 与原来等长
  let updated = match replace_packet(pages, 7U, 1, replacement) {
    Ok(p) => p
    Err(_) => []
  }
  assert_eq(updated.length(), pages.length())
  let after = reassemble(updated)
  assert_eq(after.length(), before.length())
  // 除目标包外，逐包内容一致
  let mut i = 0
  while i < after.length() {
    assert_eq(after[i].data.length(), before[i].data.length())
    if i != 1 {
      assert_true(same_bytes(after[i].data, before[i].data))
    }
    i = i + 1
  }
  // 页序号没动（等长替换不需要重编号）
  assert_eq(updated[1].sequence, 1U)
  let reparsed = parse_pages(serialize_pages(updated))
  assert_eq(structure_problems(reparsed).length(), 0)
  for p in reparsed {
    assert_true(page_crc_ok(p))
  }
}

///|
/// 变长替换（新包比一页还大）：页数增加，同流后续页重编号，结构仍自洽。
test "replacing with a larger packet renumbers the following pages" {
  let pages = four_packet_stream(7U)
  let big = repeat_byte((0x5A : Byte), 65025 + 1000)
  let updated = match replace_packet(pages, 7U, 1, big) {
    Ok(p) => p
    Err(_) => []
  }
  // 四个包 → 目标包占两页，总页数 5
  assert_eq(updated.length(), 5)
  // 页序号必须连续，否则播放器会在跳变处认为丢页
  let mut i = 0
  while i < updated.length() {
    assert_eq(updated[i].sequence, i.reinterpret_as_uint())
    i = i + 1
  }
  let after = reassemble(updated)
  assert_eq(after.length(), 4)
  assert_eq(after[1].data.length(), 65025 + 1000)
  let reparsed = parse_pages(serialize_pages(updated))
  assert_eq(structure_problems(reparsed).length(), 0)
  for p in reparsed {
    assert_true(page_crc_ok(p))
  }
}

///|
/// 多流文件里替换一条流的包，另一条流的页必须逐字节不动。
///
/// 这是「只重写受影响的页」的核心承诺：改 A 流的元数据，
/// 不该让 B 流的任何一个字节发生变化。
test "replacing in one stream leaves the others byte identical" {
  let built = mux_streams([
    {
      serial: 1U,
      packets: [
        { data: b"ID-ONE", granule_position: 0L, serial: 1U, },
        { data: b"COMMENT-ONE", granule_position: 0L, serial: 1U, },
        {
          data: repeat_byte((0x41 : Byte), 200),
          granule_position: 960L,
          serial: 1U,
        },
      ],
    },
    {
      serial: 2U,
      packets: [
        { data: b"ID-TWO", granule_position: 0L, serial: 2U, },
        { data: b"COMMENT-TWO", granule_position: 0L, serial: 2U, },
        {
          data: repeat_byte((0x42 : Byte), 200),
          granule_position: 960L,
          serial: 2U,
        },
      ],
    },
  ])
  let pages = match built {
    Ok(p) => p
    Err(_) => []
  }
  let other_before = serialize_pages(stream_pages(pages, 2U))
  let updated = match replace_packet(pages, 1U, 1, b"NEW-COMMENT-ONE") {
    Ok(p) => p
    Err(_) => []
  }
  let other_after = serialize_pages(stream_pages(updated, 2U))
  assert_true(same_bytes(other_before, other_after))
  // 目标流确实被改了
  let mine = reassemble(stream_pages(updated, 1U))
  assert_eq(mine[1].data.length(), 15)
  // 整文件结构仍然自洽
  assert_eq(
    structure_problems(parse_pages(serialize_pages(updated))).length(),
    0,
  )
}

///|
/// 序号越界与流号不存在都要报错，而不是悄悄什么都不做。
test "replace_packet reports bad input" {
  let pages = four_packet_stream(7U)
  match replace_packet(pages, 7U, 99, b"x") {
    Err(msg) => assert_true(msg.contains("越界"))
    Ok(_) => assert_true(false)
  }
  match replace_packet(pages, 123U, 1, b"x") {
    Err(msg) => assert_true(msg.contains("serial"))
    Ok(_) => assert_true(false)
  }
}

///|
/// 一页装两个包时，替换其中一个**必须保持页分组**。
///
/// Vorbis 的真实形态：注释头与 setup 头共享第 1 页。曾经用一包一页重建，
/// 结果页数 3→4、中间页变成「有包结束却 -1」，verify 直接报警 ——
/// 改一个标签却动了整个页布局。
test "replacing a packet on a shared page keeps the layout" {
  // 手工拼一条三页的流：第 0 页 ID，第 1 页 comment + setup，第 2 页音频
  let pages : Array[Page] = [
    {
      header_type: flag_bos(),
      granule_position: 0L,
      serial: 9U,
      sequence: 0U,
      crc: 0U,
      segments: [3],
      payload: b"ID!",
    },
    {
      header_type: (0x00 : Byte),
      granule_position: 0L,
      serial: 9U,
      sequence: 1U,
      crc: 0U,
      // 段表之和必须等于负载长度（7 + 5 = 12）：否则 reassemble 会按
      // 「宁可少给包」的规则丢弃，测试就测不到真正的路径了
      segments: [7, 5],
      payload: b"COMMENTSETUP",
    },
    {
      header_type: flag_eos(),
      granule_position: 4800L,
      serial: 9U,
      sequence: 2U,
      crc: 0U,
      segments: [4],
      payload: b"AUDI",
    },
  ]
  let updated = match replace_packet(pages, 9U, 1, b"NEWCMT") {
    Ok(p) => p
    Err(_) => []
  }
  // 页数不变，且第 1 页仍然装着两个包
  assert_eq(updated.length(), 3)
  assert_eq(updated[1].segments.length(), 2)
  // 第 1 页的粒度仍是真值 0（不是 -1）
  assert_eq(updated[1].granule_position, 0L)
  let after = reassemble(updated)
  assert_eq(after.length(), 4)
  // 被替换的包是 6 字节，紧跟其后的 setup 包仍是 5 字节
  assert_eq(after[1].data.length(), 6)
  assert_eq(after[2].data.length(), 5)
  // 结构体检必须全绿
  assert_eq(structure_findings(updated).length(), 0)
  let reparsed = parse_pages(serialize_pages(updated))
  assert_eq(structure_findings(reparsed).length(), 0)
  for p in reparsed {
    assert_true(page_crc_ok(p))
  }
}
