// stream.mbt —— 字节流与页序列之间的转换

///|
/// 从字节流中依次解析出所有页。
///
/// 遇到无法解析的位置即停止，不做重同步扫描 ——
/// 调用方拿到的通常是完整文件的全部内容，损坏的流应当在更上层处理。
pub fn parse_pages(data : Bytes) -> Array[Page] {
  let pages : Array[Page] = []
  let mut offset = 0
  let mut go = true
  while go && offset < data.length() {
    match Page::parse(data, offset) {
      Some((page, next)) => {
        pages.push(page)
        offset = next
      }
      None => go = false
    }
  }
  pages
}

///|
/// 把页序列拼接为字节流。
///
/// 每页在序列化时都会重新计算并写入自己的 CRC，
/// 因此这个函数产出的字节流总是自洽的。
pub fn serialize_pages(pages : Array[Page]) -> Bytes {
  let buf = Buffer()
  for page in pages {
    buf.write_bytes(page.to_bytes().exact_view())
  }
  buf.to_bytes()
}
