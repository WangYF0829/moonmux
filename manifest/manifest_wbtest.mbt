// manifest_wbtest.mbt —— 清单解析/生成的测试
//
// 清单决定 demux → mux 能否保真，所以解析必须是**严格**的：
// 任何无法解析的行都报错，而不是猜。宽松解析会让手工编辑过的清单
// 静默错位，而 mux 完全信任这份数据。

///|
/// 解析失败时的空清单，供测试里兜底。
fn empty_manifest() -> Manifest {
  { serial: None, packets: None, chain: None, granules: [] }
}

///|
/// 完整清单：三个头字段 + 逐包粒度都能读出来。
test "parse a full manifest" {
  let text = "# moonmux manifest v1\n# granulepos\n# serial=1647431420\n# packets=3\n# chain=2\n0\n-1\n288312\n"
  let m = match parse(text) {
    Ok(m) => m
    Err(_) => {
      assert_true(false)
      empty_manifest()
    }
  }
  match m.serial {
    Some(s) => assert_eq(s, 1647431420U)
    None => assert_true(false)
  }
  match m.packets {
    Some(n) => assert_eq(n, 3)
    None => assert_true(false)
  }
  match m.chain {
    Some(c) => assert_eq(c, 2)
    None => assert_true(false)
  }
  assert_eq(m.granules.length(), 3)
  assert_eq(m.granules[0], 0L)
  assert_eq(m.granules[1], -1L)
  assert_eq(m.granules[2], 288312L)
}

///|
/// 旧清单没有 serial/packets/chain：三个字段都应是 None，粒度照读。
test "parse a legacy manifest without optional headers" {
  let m = match parse("# moonmux manifest v1\n# granulepos\n10\n20\n") {
    Ok(m) => m
    Err(_) => empty_manifest()
  }
  assert_true(m.serial is None)
  assert_true(m.packets is None)
  assert_true(m.chain is None)
  assert_eq(m.granules.length(), 2)
}

///|
/// CRLF、空行、注释行都不能影响解析。
test "crlf and blank lines are tolerated" {
  let m = match parse("# moonmux manifest v1\r\n# serial=7\r\n\r\n5\r\n-1\r\n") {
    Ok(m) => m
    Err(_) => empty_manifest()
  }
  match m.serial {
    Some(s) => assert_eq(s, 7U)
    None => assert_true(false)
  }
  assert_eq(m.granules.length(), 2)
  assert_eq(m.granules[0], 5L)
  assert_eq(m.granules[1], -1L)
}

///|
/// UTF-8 BOM 必须被剥掉。
///
/// 不剥的话，版本行不再以 '#' 开头，会被当成一条粒度 ——
/// 时间轴整体前移一格，mux 出来的文件结构合法但时间是错的。
test "utf-8 bom is stripped" {
  let text = "\u{FEFF}# moonmux manifest v1\n# serial=9\n# packets=1\n5\n"
  let m = match parse(text) {
    Ok(m) => m
    Err(_) => empty_manifest()
  }
  assert_eq(m.granules.length(), 1)
  assert_eq(m.granules[0], 5L)
  match m.serial {
    Some(s) => assert_eq(s, 9U)
    None => assert_true(false)
  }
}

///|
/// 无法解析的粒度行要报错，不能"跳过非数字继续拼"。
test "non-numeric granule lines are rejected" {
  match parse("# packets=1\nabc\n") {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.contains("无法解析"))
  }
  match parse("# packets=1\n12x\n") {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
}

///|
/// 头部字段必须是纯整数；注释里混数字不能被拼进值里。
test "header values must be plain integers" {
  match parse("# serial=123 # v2\n0\n") {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.contains("serial"))
  }
  match parse("# chain=abc\n0\n") {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.contains("chain"))
  }
  // chain 必须 ≥ 1
  match parse("# chain=0\n0\n") {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  // packets 不能为负
  match parse("# packets=-1\n0\n") {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
}

///|
/// 生成 → 解析必须还原同样的内容。
test "render then parse roundtrips" {
  let granules : Array[Int64] = [0L, -1L, 960L, 288312L]
  let text = render(1647431420U, 3, granules)
  let m = match parse(text) {
    Ok(m) => m
    Err(_) => {
      assert_true(false)
      empty_manifest()
    }
  }
  match m.serial {
    Some(s) => assert_eq(s, 1647431420U)
    None => assert_true(false)
  }
  match m.packets {
    Some(n) => assert_eq(n, 4)
    None => assert_true(false)
  }
  match m.chain {
    Some(c) => assert_eq(c, 3)
    None => assert_true(false)
  }
  assert_eq(m.granules.length(), 4)
  let mut i = 0
  while i < 4 {
    assert_eq(m.granules[i], granules[i])
    i = i + 1
  }
}

///|
/// 包数校验：一致通过；不一致、或粒度行数与包数不符都要报错。
test "check_count validates both packets and granule rows" {
  let ok = match parse("# packets=2\n0\n5\n") {
    Ok(m) => m
    Err(_) => empty_manifest()
  }
  match check_count(ok, 2, "s1") {
    Ok(_) => assert_true(true)
    Err(_) => assert_true(false)
  }
  match check_count(ok, 3, "s1") {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.contains("2") && msg.contains("3"))
  }
  // 清单说 2 个包，却写了 1 行粒度
  let short = match parse("# packets=2\n0\n") {
    Ok(m) => m
    Err(_) => empty_manifest()
  }
  match check_count(short, 2, "s1") {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.contains("粒度"))
  }
  // 粒度行比包还多
  match check_count(ok, 1, "s1") {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  // 旧清单（无 packets）只要行数不超过包数就放行
  let legacy = match parse("# serial=1\n0\n") {
    Ok(m) => m
    Err(_) => empty_manifest()
  }
  match check_count(legacy, 5, "s1") {
    Ok(_) => assert_true(true)
    Err(_) => assert_true(false)
  }
}

///|
/// 缺项与越界取粒度都返回 0，不崩。
test "granule_at falls back to zero" {
  let g : Array[Int64] = [5L, 6L]
  assert_eq(granule_at(g, 0), 5L)
  assert_eq(granule_at(g, 1), 6L)
  assert_eq(granule_at(g, 2), 0L)
  assert_eq(granule_at(g, -1), 0L)
  assert_eq(granule_at([], 0), 0L)
}

///|
/// 前缀/后缀判断（目录里的 `packet_*.bin` 过滤依赖它）。
test "prefix and suffix helpers" {
  assert_true(starts_with("packet_000001.bin", "packet_"))
  assert_true(!starts_with("manifest.txt", "packet_"))
  assert_true(ends_with("packet_000001.bin", ".bin"))
  assert_true(!ends_with("packet_000001.bin", ".ogg"))
  assert_true(!ends_with("a", "abc"))
  assert_true(starts_with("abc", ""))
}

///|
/// 头部允许键与等号两侧有空白，也允许 `#` 后没有空格。
///
/// 把 `# chain = 2` 当注释忽略，会把 chained 文件静默压成一条物理流 ——
/// 结构仍合法，播放语义从「顺序播」变成「同时播」。
test "header key and value tolerate whitespace" {
  let m = match parse("# serial = 7\n# packets = 2\n# chain = 3\n0\n5\n") {
    Ok(m) => m
    Err(_) => empty_manifest()
  }
  match m.serial {
    Some(s) => assert_eq(s, 7U)
    None => assert_true(false)
  }
  match m.chain {
    Some(c) => assert_eq(c, 3)
    None => assert_true(false)
  }
  assert_eq(m.granules.length(), 2)
  // "#packets=1"（井号后没有空格）也要认
  let m2 = match parse("#packets=1\n0\n") {
    Ok(m) => m
    Err(_) => empty_manifest()
  }
  match m2.packets {
    Some(n) => assert_eq(n, 1)
    None => assert_true(false)
  }
}

///|
/// 只有头部、没有粒度行的清单必须拒绝（文件被截断，或只复制了头部）。
test "a header-only manifest is rejected" {
  match parse("# moonmux manifest v1\n# serial=7\n") {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.contains("粒度"))
  }
}

///|
/// 已知字段缺等号（`# chain 2`）要报错，不能当注释。
test "a known header without equals is rejected" {
  match parse("# chain 2\n0\n") {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.contains("等号"))
  }
}
