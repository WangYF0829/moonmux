// stream.mbt —— 字节流与页序列之间的转换

///|
/// 一段无法同步到页的字节区间（坏了、被插了东西、或被截断）。
pub(all) struct Skipped {
  /// 区间在文件里的起始偏移
  offset : Int
  /// 跳过的字节数
  bytes : Int
}

///|
/// 从字节流中依次解析出所有页。
///
/// 遇到无法解析的位置即停止，不做重同步扫描 ——
/// 调用方拿到的通常是完整文件的全部内容，损坏的流应当在更上层处理。
///
/// 需要「跳过坏页继续读」时用 `parse_pages_lenient`。
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
/// 容错解析：撞到坏页时向前搜下一个能通过 CRC 复核的页，跳过中间的字节。
///
/// `parse_pages` 撞到第一个坏点就停 —— 一个坏字节等于丢掉它后面的整个文件。
/// 这在这里是有意的（`split` / `cat` 不该悄悄产出半截东西），但对诊断不够用：
/// 用户想知道「坏在哪、坏掉多少、后面还剩多少能救」。
///
/// 重同步的关键是**必须用 CRC 复核候选位置**：负载里出现字面量 "OggS" 完全正常，
/// 只搜魔数会把音频数据当成页首，越搜越歪（libogg 的 `ogg_sync_pageseek`
/// 也是这么做的）。代价是要给每个候选算一次 CRC，换来的是不会误判。
///
/// 返回（能解析出的页，被跳过的区间列表）。页按文件顺序排列，
/// 跳过的区间按偏移升序 —— 调用方可以据此判断「这只是结尾截断」还是
/// 「中间烂了一大段」。
pub fn parse_pages_lenient(data : Bytes) -> (Array[Page], Array[Skipped]) {
  let pages : Array[Page] = []
  let gaps : Array[Skipped] = []
  let mut offset = 0
  while offset < data.length() {
    // 已知可信位置：结构能解析就收下（CRC 是否相符由 verify 单独报）
    let mut accepted = false
    if is_page_start(data, offset) {
      match Page::parse(data, offset) {
        Some((page, next)) => {
          if next > offset {
            pages.push(page)
            offset = next
            accepted = true
          }
        }
        None => ()
      }
    }
    if accepted {
      continue
    }
    // 从这里开始找下一个「能解析且 CRC 相符」的页
    let mut probe = offset + 1
    let mut found = -1
    while found < 0 && probe + 27 <= data.length() {
      if is_page_start(data, probe) {
        match Page::parse(data, probe) {
          Some((page, next)) => {
            if next > probe && page_crc_ok(page) {
              found = probe
            }
          }
          None => ()
        }
      }
      probe = probe + 1
    }
    if found >= 0 {
      gaps.push({ offset, bytes: found - offset })
      offset = found
    } else {
      gaps.push({ offset, bytes: data.length() - offset })
      offset = data.length()
    }
  }
  (pages, gaps)
}

///|
/// 把页序列拼接为字节流。
///
/// 每页在序列化时都会重新计算并写入自己的 CRC，
/// 因此这个函数产出的字节流总是自洽的。
pub fn serialize_pages(pages : Array[Page]) -> Bytes {
  // 预分配总长，并直接把每页写进同一个缓冲：
  // 旧写法每页先 to_bytes() 生成一份 Bytes 再整体复制，
  // 输出阶段因此多出一倍的分配与拷贝（156 MB 的文件实测峰值 593 MB）。
  let mut total = 0
  for page in pages {
    total = total + 27 + page.segments.length() + page.payload.length()
  }
  let buf = Buffer(size_hint=total)
  for page in pages {
    write_capture(buf)
    write_body(buf, page, page.expected_crc())
  }
  buf.to_bytes()
}
