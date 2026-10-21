// crc.mbt —— Ogg 页校验所用的 CRC-32
//
// 参数与 RFC 3533 附录 A 的规定一致：
// 生成多项式 0x04c11db7，初值 0，输入与输出均不反射，末尾不做异或。
//
// 注意：这与 zlib / PKZIP 常见的 CRC-32 是两套不同参数
// （后者反射输入输出、初值 0xFFFFFFFF、末尾取反），
// 两者结果不可互换。用错参数会导致生成的 Ogg 文件被所有解码器拒绝。

///|
/// 计算一段字节的 Ogg CRC-32。
///
/// 采用逐位实现，优先保证与规范一致。Ogg 页的负载通常在数 KB 量级，
/// 该实现足够；若日后需要处理超大负载，可在不改变对外行为的前提下
/// 改为查表实现。
pub fn crc32(data : Bytes) -> UInt32 {
  let mut crc : UInt32 = 0U
  let mut i = 0
  while i < data.length() {
    // 当前字节移到最高位后与寄存器异或
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
/// 校验一整页（含 CRC 字段本身，计算时该字段视为 0）是否自洽。
///
/// 传入的是**页的完整字节**，其中 CRC 字段必须已经置零，
/// 与 RFC 3533 要求的计算方式一致。
pub fn verify_page(page_bytes : Bytes, expected : UInt32) -> Bool {
  crc32(page_bytes) == expected
}

///|
/// 校验一个已解析的页：页里存着的 `crc` 字段是否与重算结果一致。
///
/// 这是独立于序列化路径的再次计算。用自产自销的往返测试，
/// 「写出去的页其实不合规」是发现不了的 —— 只有拿外部文件、
/// 或对已有字节重算一遍，才能证伪。
pub fn page_crc_ok(page : Page) -> Bool {
  page.expected_crc() == page.crc
}
