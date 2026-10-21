// seek_wbtest.mbt —— 按 granule 定位的测试

///|
/// 造一条每 100 个 granule 一页、共 11 页的流（0, 100, …, 1000）。
fn marks_stream() -> Array[Page] {
  let packets : Array[Packet] = []
  let mut i = 0
  while i <= 10 {
    packets.push({
      data: b"xx",
      granule_position: i.to_int64() * 100L,
      serial: 3U,
    })
    i = i + 1
  }
  paginate(packets, 3U)
}

///|
/// 目标落在两个路标之间时，返回不晚于目标的最后一个页。
test "seek lands on the page at or before the target" {
  let pages = marks_stream()
  match seek_granule(pages, 3U, 250L) {
    Some(p) => {
      assert_eq(p.granule, 200L)
      assert_eq(p.page_index, 2)
      assert_eq(p.sequence, 2U)
    }
    None => assert_true(false)
  }
  // 正好落在路标上
  match seek_granule(pages, 3U, 300L) {
    Some(p) => assert_eq(p.granule, 300L)
    None => assert_true(false)
  }
}

///|
/// 目标在两端之外时取端点，且不越界。
test "seek clamps to the ends" {
  let pages = marks_stream()
  match seek_granule(pages, 3U, -50L) {
    Some(p) => assert_eq(p.page_index, 0)
    None => assert_true(false)
  }
  match seek_granule(pages, 3U, 99999L) {
    Some(p) => {
      assert_eq(p.page_index, 10)
      assert_eq(p.granule, 1000L)
    }
    None => assert_true(false)
  }
}

///|
/// granule = -1 的页不能当路标：它没有时间信息，落上去会把定位带偏。
test "seek never returns a page without a granule" {
  let big = repeat_byte((0x41 : Byte), 255 * 255 + 1000)
  let packets : Array[Packet] = [
    { data: b"a", granule_position: 0L, serial: 5U, },
    { data: big, granule_position: 500L, serial: 5U, },
    { data: b"b", granule_position: 900L, serial: 5U, },
  ]
  let pages = paginate(packets, 5U)
  // 超长包的第一页 granule 是 -1
  assert_eq(pages[1].granule_position, -1L)
  match seek_granule(pages, 5U, 400L) {
    Some(p) => {
      assert_eq(p.page_index, 0)
      assert_eq(p.granule, 0L)
    }
    None => assert_true(false)
  }
  match seek_granule(pages, 5U, 600L) {
    Some(p) => {
      // 落在承载超长包**结束**的那一页上，不是它的续页
      assert_eq(p.granule, 500L)
      assert_eq(p.page_index, 2)
    }
    None => assert_true(false)
  }
}

///|
/// 字节偏移必须与该页在文件里的真实起点一致。
test "seek reports the byte offset of the page" {
  let pages = marks_stream()
  let offsets = page_offsets(pages)
  match seek_granule(pages, 3U, 450L) {
    Some(p) => {
      assert_eq(p.byte_offset, offsets[p.page_index])
      // 用它去解析序列化后的字节流，应当正好解析出那一页
      let blob = serialize_pages(pages)
      match Page::parse(blob, p.byte_offset) {
        Some((parsed, _)) => {
          assert_eq(parsed.sequence, p.sequence)
          assert_eq(parsed.granule_position, p.granule)
        }
        None => assert_true(false)
      }
    }
    None => assert_true(false)
  }
}

///|
/// 流号不存在、或该流没有任何带粒度的页时返回 None。
test "seek returns none for an absent stream" {
  let pages = marks_stream()
  match seek_granule(pages, 999U, 100L) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
  let empty : Array[Page] = []
  match seek_granule(empty, 3U, 0L) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
}

///|
/// 分布极不均匀时也必须终止并给出正确结果（插值退化保护）。
///
/// 路标为 0、1、2、3、1000000：目标 999999 若只按中点二分也能收敛，
/// 但插值若“原地踏步”就会死循环 —— 这里钉住迭代上限那条兜底。
test "seek terminates on skewed distributions" {
  let packets : Array[Packet] = []
  let marks : Array[Int64] = [0L, 1L, 2L, 3L, 1000000L]
  for g in marks {
    packets.push({ data: b"x", granule_position: g, serial: 8U, })
  }
  let pages = paginate(packets, 8U)
  match seek_granule(pages, 8U, 999999L) {
    Some(p) => assert_eq(p.granule, 3L)
    None => assert_true(false)
  }
}

///|
/// 首个音频页：跳过头部页（Opus 两个、Vorbis 三个）。
test "first audio page skips the header pages" {
  let pages = paginate(
    [
      { data: b"OpusHead", granule_position: 0L, serial: 1U, },
      { data: b"OpusTags", granule_position: 0L, serial: 1U, },
      { data: b"audio-1", granule_position: 960L, serial: 1U, },
      { data: b"audio-2", granule_position: 1920L, serial: 1U, },
    ],
    1U,
  )
  match first_audio_page(pages, 1U, 2) {
    Some(i) => assert_eq(i, 2)
    None => assert_true(false)
  }
  // Vorbis 有三个头包
  match first_audio_page(pages, 1U, 3) {
    Some(i) => assert_eq(i, 3)
    None => assert_true(false)
  }
}

///|
/// 首个音频包跨页时，必须返回它**开始**的那一页。
///
/// 返回结束页会让调用方从 continued 包中间开始解码 —— 那一页的第一个段
/// 并不是包的开头。
test "first audio page is where the packet starts, not ends" {
  let big = repeat_byte((0x41 : Byte), 255 * 255 + 100)
  let pages = paginate(
    [
      { data: b"header-1", granule_position: 0L, serial: 2U, },
      { data: b"header-2", granule_position: 0L, serial: 2U, },
      { data: big, granule_position: 4800L, serial: 2U, },
    ],
    2U,
  )
  // 第 2 页装不下整包（段全为 255），第 3 页才是结束页
  assert_true((pages[3].header_type.to_int() & flag_continued().to_int()) != 0)
  match first_audio_page(pages, 2U, 2) {
    Some(i) => assert_eq(i, 2)
    None => assert_true(false)
  }
}

///|
/// 没有头部包时返回第 0 页；流号不存在时返回 None。
test "first audio page handles edges" {
  let pages = marks_stream()
  match first_audio_page(pages, 3U, 0) {
    Some(i) => assert_eq(i, 0)
    None => assert_true(false)
  }
  match first_audio_page(pages, 999U, 0) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
}
