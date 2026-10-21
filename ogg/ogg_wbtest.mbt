// ogg_wbtest.mbt —— Ogg 容器层的白盒测试
//
// 覆盖三类不变量：
// 1. CRC 算法与 RFC 3533 的参数一致（用权威校验值钉住）；
// 2. 页的序列化与解析互为逆运算；
// 3. 重新序列化是幂等的，字段在往返中不漂移。

///|
/// 逐字节比较两个字节序列。
fn same_bytes(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut i = 0
  while i < a.length() {
    if a[i] != b[i] {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// ASCII "123456789" 在 Ogg CRC 参数下应得 0x89A1897F。
///
/// 该值可由 Rocksoft 模型的 CRC-32/POSIX（cksum）反推：
/// cksum 使用同一多项式与初值，仅末尾异或 0xFFFFFFFF，
/// 0x765E7680 ^ 0xFFFFFFFF = 0x89A1897F。
/// 若这里失败，说明参数取错（例如误用了 zlib 的反射版本），
/// 生成的 Ogg 文件会被所有解码器拒绝。
test "crc32 matches RFC 3533 parameters" {
  let data : Bytes = b"123456789"
  assert_eq(crc32(data), (0x89A1897FU : UInt32))
}

///|
/// 空输入的 CRC 应为 0（初值为 0 且无字节可异或）。
test "crc32 of empty input is zero" {
  assert_eq(crc32(b""), 0U)
}

///|
/// 单个页的往返：序列化后解析回来，关键字段应当不变。
test "page roundtrip preserves fields" {
  let page : Page = {
    header_type: flag_bos(),
    granule_position: 0L,
    serial: 42U,
    sequence: 7U,
    crc: 0U,
    segments: [3],
    payload: b"abc",
  }
  let bytes = page.to_bytes()
  match Page::parse(bytes, 0) {
    Some((parsed, next)) => {
      assert_eq(next, bytes.length())
      assert_eq(parsed.serial, 42U)
      assert_eq(parsed.sequence, 7U)
      assert_eq(parsed.granule_position, 0L)
      assert_eq(parsed.segments.length(), 1)
      assert_eq(parsed.segments[0], 3)
      assert_true(same_bytes(parsed.payload, b"abc"))
    }
    None => assert_true(false)
  }
}

///|
/// 序列化后的页必须携带非零 CRC，且再次序列化结果逐字节相同。
test "serialization is idempotent" {
  let page : Page = {
    header_type: flag_eos(),
    granule_position: 12345L,
    serial: 99U,
    sequence: 1U,
    crc: 0U,
    segments: [1, 1],
    payload: b"xy",
  }
  let first = page.to_bytes()
  match Page::parse(first, 0) {
    Some((parsed, _)) => {
      assert_true(parsed.crc != 0U)
      let second = parsed.to_bytes()
      assert_true(same_bytes(first, second))
    }
    None => assert_true(false)
  }
}

///|
/// 捕获模式识别：只有 "OggS" 才是合法页起点。
test "capture pattern detection" {
  assert_true(is_page_start(b"OggS", 0))
  assert_true(!is_page_start(b"OggX", 0))
  assert_true(!is_page_start(b"Og", 0))
}

///|
/// CRC 的计算范围必须覆盖整页，**包含开头的捕获模式 "OggS"**。
///
/// 这个测试是被真实文件逼出来的：最初的实现把捕获模式排除在计算范围之外，
/// 页的往返测试、序列化幂等测试全都照常通过 —— 但生成的文件与所有标准
/// 解码器都不兼容。直到拿真实 Ogg 文件逐页重算 CRC（9/9 与 325/325 全不匹配，
/// 改成含捕获模式后立刻全对）才暴露出来。
///
/// 向量：OggS | ver=0 | type=BOS | granule=0 | serial=1 | seq=0 | crc=0
///       | nseg=1 | seg=[3] | "ABC"，共 31 字节，正确 CRC = 0x9663CDB4。
/// 若实现退回到排除捕获模式，这里会得到 0x55CD9637。
test "crc covers the capture pattern" {
  let page : Page = {
    header_type: flag_bos(),
    granule_position: 0L,
    serial: 1U,
    sequence: 0U,
    crc: 0U,
    segments: [3],
    payload: b"ABC",
  }
  let bytes = page.to_bytes()
  assert_eq(bytes.length(), 31)
  // CRC 字段位于页内偏移 22，小端序
  let crc_field = bytes[22].to_int().reinterpret_as_uint() |
    (bytes[23].to_int().reinterpret_as_uint() << 8) |
    (bytes[24].to_int().reinterpret_as_uint() << 16) |
    (bytes[25].to_int().reinterpret_as_uint() << 24)
  assert_eq(crc_field, (0x9663CDB4U : UInt32))
}

///|
/// 独立的 CRC 校验路径：`expected_crc` 算出的值必须与序列化时写入的一致。
test "expected_crc matches the stored crc" {
  let page : Page = {
    header_type: 0,
    granule_position: 999L,
    serial: 12345U,
    sequence: 8U,
    crc: 0U,
    segments: [4],
    payload: b"data",
  }
  let bytes = page.to_bytes()
  match Page::parse(bytes, 0) {
    Some((parsed, _)) => {
      assert_eq(parsed.expected_crc(), parsed.crc)
      assert_true(page_crc_ok(parsed))
    }
    None => assert_true(false)
  }
}

///|
/// 负载被改动一个字节后，`page_crc_ok` 必须报否 ——
/// 这正是 `verify` 命令据以定位损坏页的判据。
test "page_crc_ok rejects tampered payload" {
  let page : Page = {
    header_type: 0,
    granule_position: 0L,
    serial: 1U,
    sequence: 0U,
    crc: 0U,
    segments: [3],
    payload: b"abc",
  }
  let parsed = match Page::parse(page.to_bytes(), 0) {
    Some((p, _)) => p
    None => page
  }
  assert_true(page_crc_ok(parsed))
  // 沿用原有 crc 字段，但负载换了一个字节
  let tampered : Page = {
    header_type: 0,
    granule_position: 0L,
    serial: 1U,
    sequence: 0U,
    crc: parsed.crc,
    segments: [3],
    payload: b"abd",
  }
  assert_true(!page_crc_ok(tampered))
}

///|
/// 调用方传入负偏移时必须安全拒绝，而不是索引到负数位置直接崩掉。
test "negative offset is rejected safely" {
  assert_true(!is_page_start(b"OggS", -1))
  assert_true(!is_page_start(b"", -100))
  match Page::parse(b"OggS", -1) {
    None => assert_true(true)
    Some(_) => assert_true(false)
  }
  let page : Page = {
    header_type: 0,
    granule_position: 0L,
    serial: 1U,
    sequence: 0U,
    crc: 0U,
    segments: [3],
    payload: b"abc",
  }
  match Page::parse(page.to_bytes(), -7) {
    None => assert_true(true)
    Some(_) => assert_true(false)
  }
}
