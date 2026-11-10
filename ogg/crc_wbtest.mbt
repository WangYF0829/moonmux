// crc_wbtest.mbt —— CRC-32 查表实现的交叉校验
//
// 查表实现必须与 RFC 3533 的逐位定义逐字节一致；这里用逐位参考实现
// 对 0..511 字节的各种数据做全量对比。真实 Ogg 文件的逐页 CRC 断言
// 在 ogg_wbtest.mbt / resync_wbtest.mbt 里（更接近外部证据）。

///|
/// 参考实现：直接按 RFC 3533 附录 A 的逐位算法计算（不查表）。
fn crc32_bitwise_ref(data : Bytes) -> UInt32 {
  let mut crc : UInt32 = 0U
  let mut i = 0
  while i < data.length() {
    crc = crc ^ (data[i].to_int().reinterpret_as_uint() << 24)
    let mut bit = 0
    while bit < 8 {
      if (crc & 0x80000000U) != 0U {
        crc = (crc << 1) ^ 0x04c11db7U
      } else {
        crc = crc << 1
      }
      bit = bit + 1
    }
    i = i + 1
  }
  crc
}

///|
test "crc32: empty input is zero" {
  assert_eq(crc32(b""), 0U)
}

///|
test "crc32: table matches bitwise reference for 0..511 bytes" {
  let mut n = 0
  while n < 512 {
    let buf = Buffer()
    let mut i = 0
    while i < n {
      // 有重复也有变化，避免只测到全零/单字节模式
      buf.write_byte(((i * 37 + n * 11 + 5) & 0xFF).to_byte())
      i = i + 1
    }
    let data = buf.to_bytes()
    assert_eq(crc32(data), crc32_bitwise_ref(data))
    n = n + 1
  }
}

///|
test "crc32: known bit patterns" {
  // 单字节 0x00 / 0xFF / 0x80、以及 "OggS" 捕获模式
  let cases : Array[Bytes] = [b"\x00", b"\xFF", b"\x80", b"OggS", b"OggS\x00"]
  for data in cases {
    assert_eq(crc32(data), crc32_bitwise_ref(data))
  }
}

///|
/// `verify_page` 必须先把页内 CRC 字段清零再计算；否则真实页永远校验失败。
test "verify_page zeroes the stored crc field" {
  let page : Page = {
    header_type: (0x02 : Byte),
    granule_position: 0L,
    serial: 1U,
    sequence: 0U,
    crc: 0U,
    segments: [3],
    payload: b"abc",
  }
  let bytes = page.to_bytes()
  let expected = page.expected_crc()
  // 磁盘上的页 CRC 字段非 0，但 verify_page 应能复算通过
  assert_true(verify_page(bytes, expected))
  assert_false(verify_page(bytes, expected ^ 1U))
  // 太短的输入必须拒绝而不是越界
  assert_false(verify_page(b"OggS", expected))
}
