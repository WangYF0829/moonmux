// verify_wbtest.mbt —— 页序列结构体检的测试

///|
/// 复制一页并替换其中若干字段，便于构造「恰好坏一处」的页。
///
/// 结构体检的设计前提：每类问题能被独立触发 ——
/// 所以测试必须能只改序号、只抹 BOS、只抹 EOS，而不牵连别的字段。
fn copy_page(p : Page, sequence : UInt, header_type : Byte) -> Page {
  {
    header_type,
    granule_position: p.granule_position,
    serial: p.serial,
    sequence,
    crc: p.crc,
    segments: p.segments,
    payload: p.payload,
  }
}

///|
/// 清掉 `page` 头类型标志中的某一位。
fn strip_flag(p : Page, bit : Int) -> Byte {
  (p.header_type.to_int() & (255 - bit)).to_byte()
}

///|
/// 分页产出的页本身就是完好的：序号从 0 连续，BOS / EOS 到位。
test "clean pages report no problems" {
  let packets : Array[Packet] = [
    { data: b"a", granule_position: 0L, serial: 1U },
    { data: b"b", granule_position: 9L, serial: 1U },
  ]
  assert_eq(structure_problems(paginate(packets, 1U)).length(), 0)
}

///|
/// 多流交织产出的页同样完好：每条流各自从 0 连续编号。
test "multiplexed pages report no problems" {
  let built = mux_streams([
    {
      serial: 1U,
      packets: [
        { data: b"a1", granule_position: 0L, serial: 1U },
        { data: b"a2", granule_position: 5L, serial: 1U },
      ],
    },
    {
      serial: 2U,
      packets: [{ data: b"b1", granule_position: 3L, serial: 2U }],
    },
  ])
  match built {
    Err(_) => assert_true(false)
    Ok(pages) => assert_eq(structure_problems(pages).length(), 0)
  }
}

///|
/// 页序号跳号必须被指出 —— 这是丢页在容器层唯一留下的痕迹。
///
/// 报告里要带断点两侧的实际序号与丢失页数，否则排查时无从定位。
test "sequence gap is reported" {
  let packets : Array[Packet] = [
    { data: b"a", granule_position: 0L, serial: 1U },
    { data: b"b", granule_position: 9L, serial: 1U },
  ]
  let pages = paginate(packets, 1U)
  pages[1] = copy_page(pages[1], 5U, pages[1].header_type)
  let problems = structure_problems(pages)
  assert_eq(problems.length(), 1)
  assert_eq(problems[0], "serial=1 页序号从 0 跳到 5（中间丢了 4 页）")
}

///|
/// 中间丢一页只报一处，而不是把后面所有页都报一遍。
///
/// 丢一页会让后续页整体前移一位：按位置逐页对账会为每一页都报一次，
/// 真正有用的那个断点被 99 条重复信息埋掉。诊断工具的价值在于指向问题，
/// 不在于把问题数乘以 99。
test "one lost page yields exactly one report" {
  let packets : Array[Packet] = []
  let mut i = 0
  while i < 8 {
    packets.push({ data: b"x", granule_position: i.to_int64(), serial: 1U })
    i = i + 1
  }
  let pages = paginate(packets, 1U)
  // 删掉序号 3 那一页，把后面的整体前移
  let kept : Array[Page] = []
  let mut j = 0
  while j < pages.length() {
    if j != 3 {
      kept.push(pages[j])
    }
    j = j + 1
  }
  let problems = structure_problems(kept)
  assert_eq(problems.length(), 1)
  assert_eq(problems[0], "serial=1 页序号从 2 跳到 4（中间丢了 1 页）")
}

///|
/// 一条流不从第 0 页开始必须被指出 —— 说明前面那段不在这个文件里。
test "stream not starting at page zero is reported" {
  let pages = paginate([{ data: b"a", granule_position: 0L, serial: 1U }], 1U)
  pages[0] = copy_page(pages[0], 3U, pages[0].header_type)
  let problems = structure_problems(pages)
  assert_eq(problems.length(), 1)
  assert_eq(problems[0], "serial=1 首页页序号是 3（应为 0，流的开头可能丢失）")
}

///|
/// 首页缺 BOS 必须被指出 —— 头部包不在，解码器无法初始化。
test "missing bos is reported" {
  let packets : Array[Packet] = [
    { data: b"a", granule_position: 0L, serial: 1U },
    { data: b"b", granule_position: 9L, serial: 1U },
  ]
  let pages = paginate(packets, 1U)
  pages[0] = copy_page(pages[0], pages[0].sequence, strip_flag(pages[0], 2))
  let problems = structure_problems(pages)
  // 只抹了 BOS，序号与 EOS 都还正常 —— 应当只有这一条问题
  assert_eq(problems.length(), 1)
  assert_eq(problems[0], "serial=1 首页缺 BOS 标志（头部包可能丢失）")
}

///|
/// 末页缺 EOS 必须被指出 —— 文件末尾被截断时就是这个形态。
test "missing eos is reported" {
  let packets : Array[Packet] = [
    { data: b"a", granule_position: 0L, serial: 1U },
    { data: b"b", granule_position: 9L, serial: 1U },
  ]
  let pages = paginate(packets, 1U)
  let last = pages.length() - 1
  pages[last] = copy_page(pages[last], pages[last].sequence, strip_flag(pages[last], 4))
  let problems = structure_problems(pages)
  assert_eq(problems.length(), 1)
  assert_eq(problems[0], "serial=1 末页缺 EOS 标志（文件可能被截断）")
}

///|
/// 段表声明的总长与实际负载不符必须被指出。
///
/// `Page::parse` 产出的页天然满足段表一致性，这项检查防的是
/// 上层手工拼页 —— 段表与负载错位时读端会越界或悄悄丢数据。
test "segment table mismatch is reported" {
  let pages = paginate([{ data: b"abc", granule_position: 0L, serial: 1U }], 1U)
  // 声明 4 字节，实际负载 3 字节
  pages[0] = {
    header_type: pages[0].header_type,
    granule_position: pages[0].granule_position,
    serial: pages[0].serial,
    sequence: pages[0].sequence,
    crc: pages[0].crc,
    segments: [4],
    payload: b"abc",
  }
  let problems = structure_problems(pages)
  assert_eq(problems.length(), 1)
  assert_eq(problems[0], "serial=1 sequence=0 段表声明 4 字节，实际负载 3 字节")
}

///|
/// 造一页：段表按负载长度生成（负载 < 255 时本页有包结束）。
fn mk_page(
  serial : UInt,
  seq : UInt,
  granule : Int64,
  header : Byte,
  payload : Bytes,
) -> Page {
  {
    header_type: header,
    granule_position: granule,
    serial,
    sequence: seq,
    crc: 0U,
    segments: [payload.length()],
    payload,
  }
}

///|
/// 粒度倒流必须报 error：时间轴断了，播放器会跳回过去。
test "granule going backwards is an error" {
  let pages : Array[Page] = [
    mk_page(1U, 0U, 100L, flag_bos(), b"a"),
    mk_page(1U, 1U, 50L, (0x00 : Byte), b"b"),
    mk_page(1U, 2U, 200L, flag_eos(), b"c"),
  ]
  let findings = structure_findings(pages)
  assert_eq(findings.length(), 1)
  match findings[0].severity {
    Severity::Error => assert_true(findings[0].message.contains("粒度回退"))
    _ => assert_true(false)
  }
}

///|
/// 没有包结束的页带着粒度 → warn（-1 才表示「本页没有包结束」）。
test "granule on a page without packet completion is a warning" {
  let pages : Array[Page] = [
    mk_page(1U, 0U, 5L, flag_bos() | flag_eos(), repeat_byte((0x41 : Byte), 255)),
  ]
  let findings = structure_findings(pages)
  assert_eq(findings.length(), 1)
  match findings[0].severity {
    Severity::Warning => assert_true(findings[0].message.contains("应为 -1"))
    _ => assert_true(false)
  }
}

///|
/// 有包结束却写 -1 → warn。
test "missing granule where packets complete is a warning" {
  let pages : Array[Page] = [
    mk_page(1U, 0U, -1L, flag_bos() | flag_eos(), b"x"),
  ]
  let findings = structure_findings(pages)
  assert_eq(findings.length(), 1)
  match findings[0].severity {
    Severity::Warning => assert_true(findings[0].message.contains("粒度却是 -1"))
    _ => assert_true(false)
  }
}

///|
/// 多出来的 BOS 页 → error（一条流只应有一个开头）。
test "duplicate BOS pages are an error" {
  let pages : Array[Page] = [
    mk_page(1U, 0U, 0L, flag_bos(), b"a"),
    mk_page(1U, 1U, 10L, flag_bos(), b"b"),
    mk_page(1U, 2U, 20L, flag_eos(), b"c"),
  ]
  let findings = structure_findings(pages)
  assert_eq(findings.length(), 1)
  match findings[0].severity {
    Severity::Error => assert_true(findings[0].message.contains("2 个 BOS"))
    _ => assert_true(false)
  }
}

///|
/// EOS 之后还有页 → error；重复 EOS 也算 error。
test "pages after EOS and duplicate EOS are errors" {
  let pages : Array[Page] = [
    mk_page(1U, 0U, 0L, flag_bos(), b"a"),
    mk_page(1U, 1U, 10L, flag_eos(), b"b"),
    mk_page(1U, 2U, 20L, flag_eos(), b"c"),
  ]
  let findings = structure_findings(pages)
  assert_true(findings.length() >= 2)
  let mut saw_dup = false
  let mut saw_after = false
  for f in findings {
    match f.severity {
      Severity::Error => {
        if f.message.contains("2 个 EOS") {
          saw_dup = true
        }
        if f.message.contains("EOS 之后") {
          saw_after = true
        }
      }
      _ => ()
    }
  }
  assert_true(saw_dup)
  assert_true(saw_after)
}

///|
/// 严重程度的文字标记就是命令行要打的那三个词。
test "severity labels" {
  assert_eq(severity_label(Severity::Info), "info")
  assert_eq(severity_label(Severity::Warning), "warn")
  assert_eq(severity_label(Severity::Error), "error")
}

///|
/// 一份完好的文件不该产生任何 findings（包括 info 级）。
test "clean stream has no findings at all" {
  let packets : Array[Packet] = [
    { data: b"a", granule_position: 0L, serial: 1U },
    { data: b"b", granule_position: 9L, serial: 1U },
  ]
  let findings = structure_findings(paginate(packets, 1U))
  assert_eq(findings.length(), 0)
}

///|
/// chained 的两段复用同一个 serial 是**硬错误**（RFC 3533 §4）。
///
/// 同时要验证「按链统计」这件事本身：两段各自的结构是自洽的，
/// 不该再报出「页序号回退 / 两个 EOS」这类由合并统计导致的假阳性。
test "chained segments reusing a serial are reported once" {
  let seg_a = paginate(
    [
      { data: b"a", granule_position: 0L, serial: 1U },
      { data: b"b", granule_position: 10L, serial: 1U },
    ],
    1U,
  )
  let seg_b = paginate(
    [
      { data: b"c", granule_position: 0L, serial: 1U },
      { data: b"d", granule_position: 10L, serial: 1U },
    ],
    1U,
  )
  let pages : Array[Page] = []
  for p in seg_a {
    pages.push(p)
  }
  for p in seg_b {
    pages.push(p)
  }
  let findings = structure_findings(pages)
  assert_eq(findings.length(), 1)
  match findings[0].severity {
    Severity::Error => assert_true(findings[0].message.contains("重复"))
    _ => assert_true(false)
  }
}

///|
/// BOS 页出现在数据页之后必须是 error（RFC 3533 §4：所有 BOS 前置）。
///
/// 直观后果：第二条流的头包排在第一条流的数据之后，解码器解第一条数据时
/// 还没看到它的头 —— 结构自洽但播不了。
test "a bos page after data pages is an error" {
  let pages : Array[Page] = [
    mk_page(1U, 0U, 0L, flag_bos(), b"a"),
    mk_page(1U, 1U, 10L, (0x00 : Byte), b"b"),
    mk_page(2U, 0U, 0L, flag_bos(), b"c"),
    mk_page(2U, 1U, 10L, flag_eos(), b"d"),
  ]
  let findings = structure_findings(pages)
  let mut saw = false
  for f in findings {
    match f.severity {
      Severity::Error =>
        if f.message.contains("BOS 页出现在数据页之后") {
          saw = true
        }
      _ => ()
    }
  }
  assert_true(saw)
}
