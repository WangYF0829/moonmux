// select_wbtest.mbt —— 单条逻辑流挑选的测试

///|
/// 造一个「两条逻辑流交织」的页序列，供挑选测试使用。
fn interleaved_pair() -> Array[Page] {
  match
    mux_streams([
      {
        serial: 7U,
        packets: [
          { data: b"a1", granule_position: 0L, serial: 7U, },
          { data: b"a2", granule_position: 10L, serial: 7U, },
        ],
      },
      {
        serial: 9U,
        packets: [
          { data: b"b1", granule_position: 0L, serial: 9U, },
          { data: b"b2", granule_position: 20L, serial: 9U, },
        ],
      },
    ]) {
    Ok(pages) => pages
    Err(_) => []
  }
}

///|
/// 按流号挑出的页只属于那一条流，且保持原有先后顺序。
test "stream_pages keeps only the requested serial in order" {
  let pages = interleaved_pair()
  assert_true(pages.length() > 2)
  let mine = stream_pages(pages, 7U)
  assert_true(mine.length() > 0)
  for p in mine {
    assert_eq(p.serial, 7U)
  }
  // 页序号必须是 0、1、2…… 逐页递增，没被抽取过程打乱
  let mut i = 0
  while i < mine.length() {
    assert_eq(mine[i].sequence, i.reinterpret_as_uint())
    i = i + 1
  }
}

///|
/// 抽出来的页序列本身就是一份合法的单流 Ogg：结构完好、逐页 CRC 通过。
///
/// 这条是「抽流是筛选而不是重写」的判据 —— 之所以能不重写，
/// 正是因为 RFC 3533 要求每条逻辑流各自的页序号从 0 起连续递增。
test "an extracted stream stands alone" {
  let pages = interleaved_pair()
  let mine = stream_pages(pages, 9U)
  let reparsed = parse_pages(serialize_pages(mine))
  assert_eq(reparsed.length(), mine.length())
  assert_eq(structure_problems(reparsed).length(), 0)
  for p in reparsed {
    assert_true(page_crc_ok(p))
  }
  assert_eq(serials_of(reparsed).length(), 1)
}

///|
/// 抽流是逐字节透传：产物就是输入里属于该流的那几页，一字节不改。
test "extraction is byte for byte" {
  let pages = interleaved_pair()
  let mine = stream_pages(pages, 7U)
  // 手工按流筛一遍，两条路径应当给出同样的字节
  let manual : Array[Page] = []
  for p in pages {
    if p.serial == 7U {
      manual.push(p)
    }
  }
  assert_true(same_bytes(serialize_pages(mine), serialize_pages(manual)))
}

///|
/// 流号不存在时挑出空数组，不报错也不编造。
test "stream_pages returns nothing for an absent serial" {
  let pages = interleaved_pair()
  assert_eq(stream_pages(pages, 12345U).length(), 0)
  assert_true(!has_stream(pages, 12345U))
  assert_true(has_stream(pages, 7U))
}

///|
/// 1 起算的序号按**首次出现**顺序映射到流号，与 `demux` 的 s1、s2 一致。
test "serial_at maps a 1-based index in first-appearance order" {
  let built = mux_streams([
    {
      serial: 500U,
      packets: [{ data: b"x", granule_position: 0L, serial: 500U, }],
    },
    {
      serial: 3U,
      packets: [{ data: b"y", granule_position: 0L, serial: 3U, }],
    },
  ])
  let pages = match built {
    Ok(p) => p
    Err(_) => []
  }
  // 序号 1 是流号 500 而不是 3 —— 不按流号大小排
  match serial_at(pages, 1) {
    Ok(s) => assert_eq(s, 500U)
    Err(_) => assert_true(false)
  }
  match serial_at(pages, 2) {
    Ok(s) => assert_eq(s, 3U)
    Err(_) => assert_true(false)
  }
}

///|
/// 序号越界时返回 Err，且说明里给出实际条数。
///
/// 越界是用户真会犯的错（比如对单流文件要「第 2 条」），
/// 报错要能自己说清可用范围。
test "serial_at reports the range when out of bounds" {
  let pages = interleaved_pair()
  for bad in [0, -1, 3, 99] {
    match serial_at(pages, bad) {
      Err(msg) => {
        assert_true(msg.contains("超出范围"))
        assert_true(msg.contains("2"))
      }
      Ok(_) => assert_true(false)
    }
  }
}
