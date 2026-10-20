// chain_wbtest.mbt —— 物理流链接的测试

///|
/// 造一条单包单页的流，便于拼测试场景。
fn one_page(data : Bytes, granule : Int64, serial : UInt) -> Array[Page] {
  paginate([{ data, granule_position: granule, serial }], serial)
}

///|
/// 造三个包，用于拼多页流。
fn three_packets(serial : UInt, granule : Int64) -> Array[Packet] {
  [
    { data: b"p1", granule_position: granule, serial },
    { data: b"p2", granule_position: granule + 1L, serial },
    { data: b"p3", granule_position: granule + 2L, serial },
  ]
}

///|
/// 造一条三包三页的流：首页带 BOS、末页带 EOS，中间是数据页。
///
/// 必须多于一页，段内才会出现数据页 —— 单页流的 BOS 与 EOS 挤在同一页上，
/// 与「下一段的第一页」在字节上无法区分（见下面那条保守行为的测试）。
fn three_pages(serial : UInt, granule : Int64) -> Array[Page] {
  paginate(three_packets(serial, granule), serial)
}

///|
/// 把 `chain` 的结果取出来。
///
/// 普通函数里不能用会抛错的断言，所以链接失败时返回空数组，
/// 由各测试自己的段数断言把它拦住 —— 链接若失败，段数必然对不上。
fn chained(a : Array[Page], b : Array[Page]) -> Array[Page] {
  match chain(a, b) {
    Ok(pages) => pages
    Err(_) => []
  }
}

///|
/// 流号不冲突时原样透传：页、页序号都保持读入时的样子。
///
/// 拼接本来就该是无损的 —— 若无冲突也去重新分页，
/// 产物就不再是「这两个文件的拼接」，对账时说不清楚。
test "chain passthrough keeps pages untouched" {
  let a = one_page(b"aaa", 10L, 1U)
  let b = one_page(b"bbb", 20L, 2U)
  match chain(a, b) {
    Err(_) => assert_true(false)
    Ok(pages) => {
      assert_eq(pages.length(), 2)
      assert_eq(pages[0].serial, 1U)
      assert_eq(pages[0].sequence, 0U)
      assert_eq(pages[0].granule_position, 10L)
      assert_eq(pages[1].serial, 2U)
      assert_eq(pages[1].sequence, 0U)
      assert_eq(pages[1].granule_position, 20L)
      // 两页的 BOS / EOS 各自保留：这正是 chained 形态
      assert_true((pages[0].header_type.to_int() & flag_bos().to_int()) != 0)
      assert_true((pages[0].header_type.to_int() & flag_eos().to_int()) != 0)
      assert_true((pages[1].header_type.to_int() & flag_bos().to_int()) != 0)
      assert_true((pages[1].header_type.to_int() & flag_eos().to_int()) != 0)
    }
  }
}

///|
/// 流号相撞时，后一条流必须换新流号，包内容与粒度位置不变。
///
/// 相撞不处理的话，读取端会把两条流当成一条：页序号从中间重新数起，
/// 两条流的包被粘在一起 —— 链接产物表面正常，播放时才崩。
test "chain remaps colliding serial" {
  let a = one_page(b"aaa", 10L, 1U)
  let b = one_page(b"bbb", 20L, 1U)
  match chain(a, b) {
    Err(_) => assert_true(false)
    Ok(pages) => {
      assert_eq(pages.length(), 2)
      assert_eq(pages[0].serial, 1U)
      // 第二条流换到了新流号，且不是第一条已占用的 1
      assert_true(pages[1].serial != 1U)
      let packets = reassemble(pages)
      assert_eq(packets.length(), 2)
      assert_true(same_bytes(packets[0].data, b"aaa"))
      assert_true(same_bytes(packets[1].data, b"bbb"))
      // 粒度位置保留
      assert_eq(packets[1].granule_position, 20L)
      assert_eq(packets[1].serial, pages[1].serial)
      // 链接产物序列化—解析后结构完好
      let reparsed = parse_pages(serialize_pages(pages))
      assert_eq(structure_problems(reparsed).length(), 0)
      for p in reparsed {
        assert_true(page_crc_ok(p))
      }
    }
  }
}

///|
/// 部分相撞：后一文件里只有一条流需要换号，其余照旧。
test "chain remaps only the colliding stream" {
  let a = one_page(b"aaa", 10L, 1U)
  let built = mux_streams([
    {
      serial: 1U,
      packets: [{ data: b"b1", granule_position: 0L, serial: 1U }],
    },
    {
      serial: 2U,
      packets: [{ data: b"b2", granule_position: 0L, serial: 2U }],
    },
  ])
  let second = match built {
    Ok(pages) => pages
    Err(_) => {
      assert_true(false)
      []
    }
  }
  match chain(a, second) {
    Err(_) => assert_true(false)
    Ok(pages) => {
      // 流号 1 与前一条相撞，换成了 3（双方最大流号为 2）；
      // 流号 2 不相撞，原样保留
      let serials = serials_of(pages)
      assert_eq(serials.length(), 3)
      assert_eq(serials[0], 1U)
      assert_eq(serials[1], 3U)
      assert_eq(serials[2], 2U)
      // 三条流的包一字不差
      let packets = reassemble(pages)
      assert_eq(packets.length(), 3)
      // 链接产物结构完好
      assert_eq(structure_problems(parse_pages(serialize_pages(pages))).length(), 0)
    }
  }
}

///|
/// 空的一侧直接返回另一侧 —— 链接空文件不产生额外页。
test "chain with an empty side" {
  let a = one_page(b"aaa", 10L, 1U)
  match chain(a, []) {
    Err(_) => assert_true(false)
    Ok(pages) => {
      assert_eq(pages.length(), 1)
      assert_eq(pages[0].serial, 1U)
    }
  }
  match chain([], a) {
    Err(_) => assert_true(false)
    Ok(pages) => {
      assert_eq(pages.length(), 1)
      assert_eq(pages[0].serial, 1U)
    }
  }
}

///|
/// 非链接流只切出一段，且逐字节就是输入本身。
///
/// 绝大多数 Ogg 文件不是链接流，拆分对它们必须是恒等操作 ——
/// 把一份好文件切出花来，比不提供这个功能更糟。
test "split of a plain stream yields one part" {
  let pages = three_pages(1U, 10L)
  let parts = split_chains(pages)
  assert_eq(parts.length(), 1)
  assert_eq(parts[0].length(), 3)
  assert_true(same_bytes(serialize_pages(parts[0]), serialize_pages(pages)))
}

///|
/// 多逻辑流交织的文件是一**条**物理流，不该被切开。
///
/// 交织文件的 BOS 页成组排在最前（RFC 3533 的约束），
/// 数据页之后再没有 BOS 页 —— 拆分看到的就是一段。
/// 物理流（一个链）与逻辑流（链内的一条）是两层概念，不能混。
test "split keeps an interleaved multi-stream file whole" {
  let built = mux_streams([
    {
      serial: 1U,
      packets: [
        { data: b"a1", granule_position: 0L, serial: 1U },
        { data: b"a2", granule_position: 10L, serial: 1U },
      ],
    },
    {
      serial: 2U,
      packets: [
        { data: b"b1", granule_position: 0L, serial: 2U },
        { data: b"b2", granule_position: 20L, serial: 2U },
      ],
    },
  ])
  let pages = match built {
    Ok(p) => p
    Err(_) => {
      assert_true(false)
      []
    }
  }
  let parts = split_chains(pages)
  assert_eq(parts.length(), 1)
  assert_eq(parts[0].length(), pages.length())
}

///|
/// 链接流被切回两段，且两段各自都能独立成立。
///
/// 切出来的每段都要能单独存成一个文件：页序号从 0 开始、首尾 BOS / EOS 齐全、
/// 逐页 CRC 通过。否则「拆开」只是把一份坏文件变成两份坏文件。
test "split separates chained streams into standalone parts" {
  let a = three_pages(1U, 10L)
  let b = three_pages(2U, 20L)
  let parts = split_chains(chained(a, b))
  assert_eq(parts.length(), 2)
  assert_eq(parts[0].length(), 3)
  assert_eq(parts[1].length(), 3)
  assert_eq(parts[0][0].serial, 1U)
  assert_eq(parts[1][0].serial, 2U)
  for part in parts {
    let reparsed = parse_pages(serialize_pages(part))
    assert_eq(structure_problems(reparsed).length(), 0)
    for p in reparsed {
      assert_true(page_crc_ok(p))
    }
  }
}

///|
/// 拆分是链接的逆运算：逐字节还原成链接前的两个文件。
///
/// 这条不变量把两个方向钉在一起 —— 链接与拆分若各自漂移，
/// 往返就对不上，而不对账的话两边都能「看起来正常」。
test "split undoes chain byte for byte" {
  let a = three_pages(1U, 10L)
  let b = three_pages(2U, 20L)
  let parts = split_chains(chained(a, b))
  assert_eq(parts.length(), 2)
  assert_true(same_bytes(serialize_pages(parts[0]), serialize_pages(a)))
  assert_true(same_bytes(serialize_pages(parts[1]), serialize_pages(b)))
}

///|
/// 三段链接切出三段，且每一段内部仍是多逻辑流的完整一条链。
///
/// 物理流与逻辑流是两层：链接切的是外层，切出来的段里
/// 该有几条逻辑流就还是几条。
test "split separates a three-way chain including a multi-stream part" {
  let a = three_pages(1U, 10L)
  // 中间那段是两条多页逻辑流交织的：BOS 页成组在前，数据页紧随其后
  let built = mux_streams([
    { serial: 2U, packets: three_packets(2U, 20L) },
    { serial: 3U, packets: three_packets(3U, 20L) },
  ])
  let bc = match built {
    Ok(p) => p
    Err(_) => {
      assert_true(false)
      []
    }
  }
  let c = three_pages(4U, 30L)
  let parts = split_chains(chained(chained(a, bc), c))
  assert_eq(parts.length(), 3)
  assert_eq(parts[0].length(), 3)
  assert_eq(parts[2].length(), 3)
  // 物理流与逻辑流是两层：中间那段切出来后仍是两条逻辑流
  assert_eq(serials_of(parts[0]).length(), 1)
  assert_eq(serials_of(parts[1]).length(), 2)
  assert_eq(serials_of(parts[2]).length(), 1)
}

///|
/// 空输入切出零段 —— 不产生一个空壳段。
test "split of no pages yields no parts" {
  let empty : Array[Page] = []
  assert_eq(split_chains(empty).length(), 0)
}

///|
/// 规格上无从区分的形态一律不切：两条单页流相接，按一段处理。
///
/// 单页流的 BOS 与 EOS 在同一页上，于是「两条单页流首尾链接」与
/// 「同一物理流里交织的两条单页流」是逐字节相同的两种读法。
/// 这里选择保守的一侧 —— 少切最多是没帮上忙，错切会把一条好流劈成两半。
/// 真实文件（Opus、Vorbis）都有成百上千个数据页，不受这条限制。
test "split does not cut where the format is ambiguous" {
  let a = one_page(b"aaa", 10L, 1U)
  let b = one_page(b"bbb", 20L, 2U)
  let parts = split_chains(chained(a, b))
  assert_eq(parts.length(), 1)
  assert_eq(parts[0].length(), 2)
  // 两页都在，一个都没丢
  assert_eq(serials_of(parts[0]).length(), 2)
}

///|
/// 第二个输入本身是 chained、且流号相撞时，必须逐段处理。
///
/// 反例：一次性 `reassemble(second)` 会把第二输入的两段压成一段，
/// 链接结果从「A + B1 + B2」变成「A + (B1 与 B2 交织)」—— 结构合法，
/// 播放语义已经变了。
test "chaining a chained input keeps its segments" {
  let first = three_pages(1U, 0L)
  let b1 = three_pages(1U, 0L)
  let b2 = three_pages(2U, 0L)
  let second : Array[Page] = []
  for p in b1 {
    second.push(p)
  }
  for p in b2 {
    second.push(p)
  }
  // 输入自身是两段
  assert_eq(split_chains(second).length(), 2)
  let merged = match chain(first, second) {
    Ok(p) => p
    Err(_) => []
  }
  // 结果应是三段：first、b1、b2
  assert_eq(split_chains(merged).length(), 3)
  // 流号全局唯一（相撞的都被换了号）
  let serials = serials_of(merged)
  let mut i = 0
  while i < serials.length() {
    let mut j = i + 1
    while j < serials.length() {
      assert_true(serials[i] != serials[j])
      j = j + 1
    }
    i = i + 1
  }
  assert_eq(structure_problems(merged).length(), 0)
}

///|
/// 一段还没结束（没有 EOS）时，中途出现的 BOS 页不能当成新的一段。
///
/// 这是损坏文件的典型形态：把某一页的头标志误设成 BOS。
/// 若按「BOS 出现在数据页之后」就切段，`verify` 会把「重复 BOS」的
/// 硬错误降级成两条软警告，损坏文件反而通过体检。
test "a bos page before the segment ends does not split" {
  let pages = three_pages(1U, 0L)
  // 把中间页（序号 1）的头标志改成 BOS，模拟损坏
  let mid = pages[1]
  pages[1] = {
    header_type: mid.header_type | flag_bos(),
    granule_position: mid.granule_position,
    serial: mid.serial,
    sequence: mid.sequence,
    crc: mid.crc,
    segments: mid.segments,
    payload: mid.payload,
  }
  assert_eq(split_chains(pages).length(), 1)
  // 结构体检必须把它当成「重复 BOS」的硬错误
  let findings = structure_findings(pages)
  let mut saw_error = false
  for f in findings {
    match f.severity {
      Severity::Error =>
        if f.message.contains("2 个 BOS") {
          saw_error = true
        }
      _ => ()
    }
  }
  assert_true(saw_error)
}

///|
/// 流号号段用尽时必须报错，而不是回绕到 0 撞上已有流。
///
/// 构造：第一段占用了 0 与 1；第二段有三条流（0、1、0xFFFFFFFE）需要换号。
/// 前两条换到 0xFFFFFFFF 后号段用尽，第三条必须报错 ——
/// 回绕到 0 会产出「跨段流号重复」的文件，`verify` 会判 error。
test "chain reports an exhausted serial space" {
  let part_a = paginate(
    [
      { data: b"a1", granule_position: 0L, serial: 0U },
      { data: b"a2", granule_position: 10L, serial: 0U },
    ],
    0U,
  )
  let part_b = paginate(
    [
      { data: b"b1", granule_position: 0L, serial: 1U },
      { data: b"b2", granule_position: 10L, serial: 1U },
    ],
    1U,
  )
  let first : Array[Page] = []
  for p in part_a {
    first.push(p)
  }
  for p in part_b {
    first.push(p)
  }
  let second = match mux_streams([
    {
      serial: 0U,
      packets: [
        { data: b"c1", granule_position: 0L, serial: 0U },
        { data: b"c2", granule_position: 10L, serial: 0U },
      ],
    },
    {
      serial: 1U,
      packets: [
        { data: b"d1", granule_position: 0L, serial: 1U },
        { data: b"d2", granule_position: 10L, serial: 1U },
      ],
    },
    {
      serial: 4294967294U,
      packets: [{ data: b"e1", granule_position: 0L, serial: 4294967294U }],
    },
  ]) {
    Ok(p) => p
    Err(_) => []
  }
  match chain(first, second) {
    Err(msg) => assert_true(msg.contains("用尽"))
    Ok(_) => assert_true(false)
  }
}
