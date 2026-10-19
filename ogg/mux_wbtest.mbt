// mux_wbtest.mbt —— 多逻辑流分组与交织的测试

///|
/// `group_by_stream` 按首次出现顺序分组，流内保持原有包序。
///
/// 顺序不能按流号排：这里流号 5 先出现、3 后出现，
/// 若按流号排序，交织出的 BOS 页顺序就与原文件相反。
test "group_by_stream keeps first-appearance order" {
  let packets : Array[Packet] = [
    { data: b"a", granule_position: 0L, serial: 5U },
    { data: b"b", granule_position: 0L, serial: 3U },
    { data: b"c", granule_position: 0L, serial: 5U },
  ]
  let groups = group_by_stream(packets)
  assert_eq(groups.length(), 2)
  assert_eq(groups[0].serial, 5U)
  assert_eq(groups[1].serial, 3U)
  assert_eq(groups[0].packets.length(), 2)
  assert_eq(groups[1].packets.length(), 1)
  assert_true(same_bytes(groups[0].packets[0].data, b"a"))
  assert_true(same_bytes(groups[0].packets[1].data, b"c"))
  assert_true(same_bytes(groups[1].packets[0].data, b"b"))
}

///|
/// 所有 BOS 页必须排在最前面。
///
/// 解码器要先读到每条流的头部包才能决定怎么解，因此 BOS 页不能
/// 混在数据页中间 —— 这里把「前 N 页全是 BOS、之后一页都没有」钉住。
test "all bos pages come first" {
  let streams : Array[LogicalStream] = [
    {
      serial: 1U,
      packets: [
        { data: b"a1", granule_position: 0L, serial: 1U },
        { data: b"a2", granule_position: 1L, serial: 1U },
      ],
    },
    {
      serial: 2U,
      packets: [
        { data: b"b1", granule_position: 0L, serial: 2U },
        { data: b"b2", granule_position: 1L, serial: 2U },
      ],
    },
  ]
  match mux_streams(streams) {
    Err(_) => assert_true(false)
    Ok(pages) => {
      assert_eq(pages.length(), 4)
      assert_true((pages[0].header_type.to_int() & flag_bos().to_int()) != 0)
      assert_true((pages[1].header_type.to_int() & flag_bos().to_int()) != 0)
      assert_true((pages[2].header_type.to_int() & flag_bos().to_int()) == 0)
      assert_true((pages[3].header_type.to_int() & flag_bos().to_int()) == 0)
      // 末页各自带 EOS，两条流都要有结束标志
      let mut eos = 0
      for p in pages {
        if (p.header_type.to_int() & flag_eos().to_int()) != 0 {
          eos = eos + 1
        }
      }
      assert_eq(eos, 2)
    }
  }
}

///|
/// 交织后按粒度位置升序排列。
///
/// 两条流的包交错在时间里（0/100/200 与 50/150），
/// 归并结果应当是 100 → 150 → 200，而不是把某条流一口气写完。
/// 若实现成「流 1 全部写完再写流 2」，这里会是 100 → 200 → 150。
test "pages are interleaved by granule position" {
  let streams : Array[LogicalStream] = [
    {
      serial: 1U,
      packets: [
        { data: b"a1", granule_position: 0L, serial: 1U },
        { data: b"a2", granule_position: 100L, serial: 1U },
        { data: b"a3", granule_position: 200L, serial: 1U },
      ],
    },
    {
      serial: 2U,
      packets: [
        { data: b"b1", granule_position: 50L, serial: 2U },
        { data: b"b2", granule_position: 150L, serial: 2U },
      ],
    },
  ]
  match mux_streams(streams) {
    Err(_) => assert_true(false)
    Ok(pages) => {
      let gran : Array[Int64] = []
      let ser : Array[UInt] = []
      for p in pages {
        if (p.header_type.to_int() & flag_bos().to_int()) == 0 {
          gran.push(p.granule_position)
          ser.push(p.serial)
        }
      }
      assert_eq(gran.length(), 3)
      assert_eq(gran[0], 100L)
      assert_eq(gran[1], 150L)
      assert_eq(gran[2], 200L)
      assert_eq(ser[0], 1U)
      assert_eq(ser[1], 2U)
      assert_eq(ser[2], 1U)
    }
  }
}

///|
/// 每条流的页序号各自从 0 编号 —— 序号是「在本流内的第几页」，
/// 不是「在整个文件里的第几页」。
test "each stream numbers its own pages from zero" {
  let streams : Array[LogicalStream] = [
    {
      serial: 1U,
      packets: [
        { data: b"a1", granule_position: 0L, serial: 1U },
        { data: b"a2", granule_position: 1L, serial: 1U },
      ],
    },
    { serial: 2U, packets: [{ data: b"b1", granule_position: 0L, serial: 2U }] },
  ]
  match mux_streams(streams) {
    Err(_) => assert_true(false)
    Ok(pages) => {
      let seq1 : Array[UInt] = []
      let seq2 : Array[UInt] = []
      for p in pages {
        if p.serial == 1U {
          seq1.push(p.sequence)
        }
        if p.serial == 2U {
          seq2.push(p.sequence)
        }
      }
      assert_eq(seq1.length(), 2)
      assert_eq(seq1[0], 0U)
      assert_eq(seq1[1], 1U)
      assert_eq(seq2.length(), 1)
      assert_eq(seq2[0], 0U)
    }
  }
}

///|
/// 端到端：两条流交织写出后，序列化 → 解析 → 重组 → 按流分组，
/// 每条流的包内容与条数都不变。
///
/// 这是「多流封装」真正要保证的东西：字节级可还原，
/// 而不是「写出来能解析就完了」。
test "multiplexed output roundtrips byte for byte" {
  let streams : Array[LogicalStream] = [
    {
      serial: 11U,
      packets: [
        { data: b"head-a", granule_position: 0L, serial: 11U },
        { data: b"body-a", granule_position: 10L, serial: 11U },
      ],
    },
    {
      serial: 22U,
      packets: [
        { data: b"head-b", granule_position: 0L, serial: 22U },
        { data: repeat_byte((0x41 : Byte), 70000), granule_position: 10L, serial: 22U },
      ],
    },
  ]
  match mux_streams(streams) {
    Err(_) => assert_true(false)
    Ok(pages) => {
      let reparsed = parse_pages(serialize_pages(pages))
      assert_eq(reparsed.length(), pages.length())
      for p in reparsed {
        assert_true(page_crc_ok(p))
      }
      let groups = group_by_stream(reassemble(reparsed))
      assert_eq(groups.length(), 2)
      assert_eq(groups[0].serial, 11U)
      assert_eq(groups[1].serial, 22U)
      assert_eq(groups[0].packets.length(), 2)
      assert_eq(groups[1].packets.length(), 2)
      assert_true(same_bytes(groups[0].packets[0].data, b"head-a"))
      assert_true(same_bytes(groups[0].packets[1].data, b"body-a"))
      assert_true(same_bytes(groups[1].packets[0].data, b"head-b"))
      assert_eq(groups[1].packets[1].data.length(), 70000)
    }
  }
}

///|
/// 两条流用了同一个流号必须被拒绝。
///
/// 相同 serial 对 `reassemble` 就是同一条流，拆出来的包会被粘在一起；
/// 静默接受等于把错误推迟到解码阶段，所以宁可在这里报错。
test "duplicate serial is rejected" {
  let streams : Array[LogicalStream] = [
    { serial: 7U, packets: [{ data: b"a", granule_position: 0L, serial: 7U }] },
    { serial: 7U, packets: [{ data: b"b", granule_position: 0L, serial: 7U }] },
  ]
  match mux_streams(streams) {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.length() > 0)
  }
}

///|
/// 没有流就没有页 —— 与 `paginate` 对空输入的处理保持一致。
test "no streams yields no pages" {
  let empty : Array[LogicalStream] = []
  match mux_streams(empty) {
    Ok(pages) => assert_eq(pages.length(), 0)
    Err(_) => assert_true(false)
  }
}

///|
/// 按目标大小攒页时，所有 BOS 页仍必须排在最前面。
///
/// 攒页只改变「每页装几个包」，不改变交织规则：解码器在解任何数据之前
/// 仍要先读到每条流的头包。这条把两件事钉在一起。
test "mux_streams_sized keeps every BOS page first" {
  let pa : Array[Packet] = []
  let pb : Array[Packet] = []
  let mut i = 0
  while i < 5 {
    let g = i.to_int64() * 960L
    pa.push({ data: repeat_byte((0x41 : Byte), 1200), granule_position: g, serial: 1U })
    pb.push({ data: repeat_byte((0x42 : Byte), 1200), granule_position: g, serial: 2U })
    i = i + 1
  }
  let built = mux_streams_sized([
    { serial: 1U, packets: pa },
    { serial: 2U, packets: pb },
  ], 4096)
  let pages = match built {
    Ok(p) => p
    Err(_) => []
  }
  assert_true(pages.length() > 2)
  assert_true((pages[0].header_type.to_int() & flag_bos().to_int()) != 0)
  assert_true((pages[1].header_type.to_int() & flag_bos().to_int()) != 0)
  assert_eq(serials_of(pages).length(), 2)
  let reparsed = parse_pages(serialize_pages(pages))
  assert_eq(structure_problems(reparsed).length(), 0)
  assert_eq(reassemble(reparsed).length(), 10)
}
