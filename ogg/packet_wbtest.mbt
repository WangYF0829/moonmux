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

///|
/// 页本身损坏（段表声称的总长 ≠ 实际负载）时，必须丢弃而不是越界读。
///
/// 这是修复前真实存在的崩溃：段表以 255 结尾、负载却不够，
/// `page.payload[offset + i]` 直接抛 RuntimeError。
/// 设计上承诺「宁可少给包，也不交出半截数据」—— 这里把它钉住。
test "corrupt page is dropped, not crashed on" {
  let page : Page = {
    header_type: flag_bos(),
    granule_position: 0L,
    serial: 1U,
    sequence: 0U,
    crc: 0U,
    // 声称 5 + 255 字节，实际负载只有 11 字节
    segments: [5, 255],
    payload: b"aaabbbbbbbbb",
  }
  let packets = reassemble([page])
  assert_eq(packets.length(), 0)
}

///|
/// 末尾未成形的包要丢弃：段表以 255 结尾却没有续页，
/// 前面的完整包照常给出，残缺的那部分不产生包。
test "trailing incomplete packet is dropped" {
  let page : Page = {
    header_type: flag_bos(),
    granule_position: 0L,
    serial: 1U,
    sequence: 0U,
    crc: 0U,
    segments: [2, 255],
    payload: repeat_byte((0x41 : Byte), 257),
  }
  let packets = reassemble([page])
  assert_eq(packets.length(), 1)
  assert_eq(packets[0].data.length(), 2)
}

///|
/// 多条逻辑流交织时，各流的段不能混进同一个累加器。
///
/// 修复前的实现用单个累加器，流 1 的 255 字节会和流 2 的 1 字节粘成一个
/// 被错标为流 2 的包。单流文件掩盖了这个问题。
test "interleaved logical streams stay separate" {
  let p1 : Page = {
    header_type: flag_bos(),
    granule_position: 0L,
    serial: 1U,
    sequence: 0U,
    crc: 0U,
    segments: [255],
    payload: repeat_byte((0x41 : Byte), 255),
  }
  let p2 : Page = {
    header_type: flag_bos(),
    granule_position: 0L,
    serial: 2U,
    sequence: 0U,
    crc: 0U,
    segments: [1],
    payload: b"Z",
  }
  let p3 : Page = {
    header_type: flag_continued(),
    granule_position: 0L,
    serial: 1U,
    sequence: 1U,
    crc: 0U,
    segments: [1],
    payload: b"Q",
  }
  let packets = reassemble([p1, p2, p3])
  assert_eq(packets.length(), 2)
  let mut s1_len = -1
  let mut s2_len = -1
  for p in packets {
    if p.serial == 1U {
      s1_len = p.data.length()
    }
    if p.serial == 2U {
      s2_len = p.data.length()
    }
  }
  // 流 2 只有 1 字节，不能被流 1 的数据污染
  assert_eq(s2_len, 1)
  assert_eq(s1_len, 256)
}

///|
/// `paginate` 是 `reassemble` 的逆运算：小包一包一页，BOS / EOS 到位。
test "paginate lays small packets one page each" {
  let packets : Array[Packet] = [
    { data: b"abc", granule_position: 0L, serial: 4U },
    { data: b"de", granule_position: 5L, serial: 4U },
  ]
  let pages = paginate(packets, 4U)
  assert_eq(pages.length(), 2)
  assert_true((pages[0].header_type.to_int() & flag_bos().to_int()) != 0)
  assert_true((pages[1].header_type.to_int() & flag_eos().to_int()) != 0)
  assert_eq(pages[0].sequence, 0U)
  assert_eq(pages[1].sequence, 1U)
  // 只有包结束所在页携带真实粒度位置
  assert_eq(pages[1].granule_position, 5L)
}

///|
/// 超长包必须跨页承载。
///
/// 单页最多 255 个段，单页负载上限 255×255 = 65025 字节。
/// 修复前的实现把整包塞进一页、段数写进单字节字段 ——
/// 65026 字节的包会把段数写成 0，页结构彻底崩坏且不报错。
test "paginate splits oversized packet and roundtrips" {
  let n = 255 * 255 + 1
  let data = repeat_byte((0x41 : Byte), n)
  let packets : Array[Packet] = [{ data, granule_position: 7L, serial: 9U }]
  let pages = paginate(packets, 9U)
  assert_eq(pages.length(), 2)
  for p in pages {
    // 单页段数与负载都不能越界
    assert_true(p.segments.length() <= 255)
    assert_true(p.payload.length() <= 255 * 255)
  }
  assert_true((pages[0].header_type.to_int() & flag_bos().to_int()) != 0)
  assert_true((pages[1].header_type.to_int() & flag_continued().to_int()) != 0)
  assert_true((pages[1].header_type.to_int() & flag_eos().to_int()) != 0)
  // 未承载包结束的页写 -1
  assert_eq(pages[0].granule_position, -1L)
  assert_eq(pages[1].granule_position, 7L)
  // 序列化 → 解析 → 重组，数据必须一字不差
  let restored = reassemble(parse_pages(serialize_pages(pages)))
  assert_eq(restored.length(), 1)
  assert_true(same_bytes(restored[0].data, data))
}

///|
/// 序列化后的页 CRC 必须自洽（用独立的校验路径复查一遍）。
test "serialized pages pass independent crc check" {
  let packets : Array[Packet] = [
    { data: b"hello world", granule_position: 0L, serial: 1U },
    { data: repeat_byte((0x5A : Byte), 600), granule_position: 3L, serial: 1U },
  ]
  let pages = paginate(packets, 1U)
  let reparsed = parse_pages(serialize_pages(pages))
  assert_eq(reparsed.length(), pages.length())
  for p in reparsed {
    assert_true(page_crc_ok(p))
  }
}

///|
/// 目标为 0 时 `paginate_sized` 必须与 `paginate` 完全一致。
///
/// 这条是向后兼容的闸门：`cat` / `split` 的字节透传依赖 `paginate`
/// 的原语义，任何「顺手改默认行为」的改动都会在这里变红。
test "paginate_sized with zero target matches paginate" {
  let packets : Array[Packet] = [
    { data: b"abc", granule_position: 0L, serial: 4U },
    { data: repeat_byte((0x41 : Byte), 700), granule_position: 5L, serial: 4U },
    { data: b"de", granule_position: 6L, serial: 4U },
  ]
  let legacy = paginate(packets, 4U)
  let sized = paginate_sized(packets, 4U, 0)
  assert_eq(sized.length(), legacy.length())
  let mut i = 0
  while i < legacy.length() {
    assert_eq(sized[i].sequence, legacy[i].sequence)
    assert_eq(sized[i].granule_position, legacy[i].granule_position)
    assert_eq(sized[i].header_type, legacy[i].header_type)
    assert_eq(sized[i].segments.length(), legacy[i].segments.length())
    i = i + 1
  }
}

///|
/// 小包按目标大小攒页，首页只放第一个包。
test "paginate_sized packs small packets up to the target" {
  let packets : Array[Packet] = []
  let mut i = 0
  while i < 10 {
    packets.push({
      data: repeat_byte((0x41 : Byte), 1000),
      granule_position: i.to_int64(),
      serial: 1U,
    })
    i = i + 1
  }
  let pages = paginate_sized(packets, 1U, 4096)
  // 一包一页要 10 页；按 4 KiB 攒应显著更少
  assert_true(pages.length() < 10)
  assert_true(pages.length() >= 3)
  // 首页只有第一个包（4 个段：255+255+255+235）
  assert_eq(pages[0].segments.length(), 4)
  // 段总数必须与包数据总量对得上（没丢也没重复）
  let mut total = 0
  for p in pages {
    for seg in p.segments {
      total = total + seg
    }
  }
  assert_eq(total, 10 * 1000)
  // 结构自洽
  let reparsed = parse_pages(serialize_pages(pages))
  assert_eq(structure_problems(reparsed).length(), 0)
  assert_eq(reassemble(reparsed).length(), 10)
}

///|
/// 页边界只能落在携带真粒度的包之后 —— 不能把一个原页劈开。
///
/// 反例：若把 a、b 单独攒成页、c 另起一页，那张页就有包结束却没有粒度
/// （-1），播放器的时钟会在那里断掉。
test "paginate_sized never splits an original page" {
  let packets : Array[Packet] = [
    { data: b"hdr", granule_position: 0L, serial: 1U },
    { data: b"a", granule_position: -1L, serial: 1U },
    { data: b"b", granule_position: -1L, serial: 1U },
    { data: b"c", granule_position: 48000L, serial: 1U },
  ]
  let pages = paginate_sized(packets, 1U, 4096)
  assert_eq(pages.length(), 2)
  // 第一页是标识包独占的 BOS 页
  assert_eq(pages[0].granule_position, 0L)
  assert_eq(pages[0].segments.length(), 1)
  // 第二页把 a、b、c 一起装下，粒度取最后一个包的 48000
  assert_eq(pages[1].segments.length(), 3)
  assert_eq(pages[1].granule_position, 48000L)
  assert_true((pages[1].header_type.to_int() & flag_eos().to_int()) != 0)
}

///|
/// 单页装不下的超长包仍要跨页，续页带 continued、粒度只写在末页。
test "paginate_sized keeps oversized packets spanning pages" {
  let n = 255 * 255 + 1
  let packets : Array[Packet] = [
    { data: repeat_byte((0x41 : Byte), n), granule_position: 7L, serial: 9U },
  ]
  let pages = paginate_sized(packets, 9U, 4096)
  assert_eq(pages.length(), 2)
  assert_true((pages[1].header_type.to_int() & flag_continued().to_int()) != 0)
  assert_eq(pages[0].granule_position, -1L)
  assert_eq(pages[1].granule_position, 7L)
  // 重组回来一字不差
  let restored = reassemble(parse_pages(serialize_pages(pages)))
  assert_eq(restored.length(), 1)
  assert_eq(restored[0].data.length(), n)
}

///|
/// 一页内的多个包，只有**最后一个**携带该页的粒度位置。
///
/// RFC 3533 规定页头的 granule 属于本页最后一个完整结束的包，同页其余包的
/// 粒度是 -1。曾经把页的值复制给每一个包 —— 那样在重新分页时，这些包会
/// 各自带出同一个粒度，页数与时间轴双双失真，而错误在本文件内部看不出来，
/// 只有把它们重新封装成页之后才暴露。
test "only the last packet on a page carries the granule" {
  let page : Page = {
    header_type: flag_bos(),
    granule_position: 100L,
    serial: 1U,
    sequence: 0U,
    crc: 0U,
    segments: [1, 1, 1],
    payload: b"abc",
  }
  let packets = reassemble([page])
  assert_eq(packets.length(), 3)
  assert_eq(packets[0].granule_position, -1L)
  assert_eq(packets[1].granule_position, -1L)
  assert_eq(packets[2].granule_position, 100L)
}

///|
/// 多页之间粒度不串台：每页的粒度只落在该页最后一个结束的包上，
/// 既不下放到同页靠前的包，也不越过页边界。
test "granules do not leak across pages" {
  let p1 : Page = {
    header_type: flag_bos(),
    granule_position: 10L,
    serial: 1U,
    sequence: 0U,
    crc: 0U,
    segments: [1, 1],
    payload: b"ab",
  }
  let p2 : Page = {
    header_type: (0x00 : Byte),
    granule_position: 20L,
    serial: 1U,
    sequence: 1U,
    crc: 0U,
    segments: [1],
    payload: b"c",
  }
  let packets = reassemble([p1, p2])
  assert_eq(packets.length(), 3)
  assert_eq(packets[0].granule_position, -1L)
  assert_eq(packets[1].granule_position, 10L)
  assert_eq(packets[2].granule_position, 20L)
}

///|
/// 超长包夹在其它包中间时，不能把 paginate 自带的 BOS / EOS 带进来。
///
/// 回归：曾经把 `paginate(head)` 的页原样收下，结果一条流出现多个 BOS、
/// EOS 之后还有页 —— 自己 mux 出来的文件被自己的 verify 判三个 error。
test "an oversized packet in the middle keeps a single BOS and EOS" {
  let big = repeat_byte((0x42 : Byte), 65025 + 500)
  let packets : Array[Packet] = [
    { data: b"id", granule_position: 0L, serial: 4U },
    { data: big, granule_position: 1000L, serial: 4U },
    { data: b"tail", granule_position: 2000L, serial: 4U },
  ]
  let pages = paginate_sized(packets, 4U, 4096)
  let mut bos = 0
  let mut eos = 0
  for p in pages {
    if (p.header_type.to_int() & flag_bos().to_int()) != 0 {
      bos = bos + 1
    }
    if (p.header_type.to_int() & flag_eos().to_int()) != 0 {
      eos = eos + 1
    }
  }
  assert_eq(bos, 1)
  assert_eq(eos, 1)
  // 首尾必须真的是第一条与最后一条
  assert_true((pages[0].header_type.to_int() & flag_bos().to_int()) != 0)
  assert_true((pages[pages.length() - 1].header_type.to_int() & flag_eos().to_int()) != 0)
  // 结构体检必须全绿，且能重组回三个包
  let reparsed = parse_pages(serialize_pages(pages))
  assert_eq(structure_findings(reparsed).length(), 0)
  assert_eq(reassemble(reparsed).length(), 3)
}

///|
/// 超长包在首位／末位时同样只能有一个 BOS 与一个 EOS。
test "oversized packet at either end keeps flags unique" {
  let big = repeat_byte((0x43 : Byte), 65025 + 100)
  let first_case : Array[Packet] = [
    { data: big, granule_position: 0L, serial: 6U },
    { data: b"x", granule_position: 500L, serial: 6U },
  ]
  let last_case : Array[Packet] = [
    { data: b"y", granule_position: 0L, serial: 7U },
    { data: big, granule_position: 900L, serial: 7U },
  ]
  for packets in [first_case, last_case] {
    let serial = packets[0].serial
    let pages = paginate_sized(packets, serial, 4096)
    let reparsed = parse_pages(serialize_pages(pages))
    assert_eq(structure_findings(reparsed).length(), 0)
    let mut bos = 0
    let mut eos = 0
    for p in reparsed {
      if (p.header_type.to_int() & flag_bos().to_int()) != 0 {
        bos = bos + 1
      }
      if (p.header_type.to_int() & flag_eos().to_int()) != 0 {
        eos = eos + 1
      }
    }
    assert_eq(bos, 1)
    assert_eq(eos, 1)
  }
}
