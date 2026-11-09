// page_reader.mbt —— 增量（流式）Ogg 页读取器
//
// 现有的 `parse_pages(Bytes)` 要求调用方一次性拿到完整文件；对网络流、
// 管道、超大文件都不适用。这里补一个增量状态机：分块喂入字节，按需取出
// 已经完整的页，并记录无法同步的区间（坏字节/前缀垃圾/结尾截断）。
//
// 设计参照 libogg 的 `ogg_sync_state` / RustAudio `ogg` crate 的
// `PageReader`（仅移植状态机语义，不复制代码）：
//   · 先同步到捕获模式 "OggS"，再按段表算出一整页长度；数据不够就等下一块；
//   · CRC 复核失败视为失步，跳 1 字节后继续找下一个能通过 CRC 的页；
//   · 无法再同步时，保留末尾最多 3 字节（可能是半个 "OggS"），其余记为跳过的区间。

///|
/// 增量 Ogg 页读取器。
pub(all) struct PageReader {
  /// 尚未消费的字节（可能包含不完整页、前缀垃圾或半个捕获模式）
  mut buf : Bytes
  /// 已解析但尚未取走的完整页
  mut pages : Array[Page]
  /// 无法同步而跳过的区间（绝对偏移）
  mut gaps : Array[Skipped]
  /// `buf[0]` 对应的绝对偏移（用于 skipped 的绝对定位）
  mut base : Int64
  /// 是否逐页复核 CRC（默认 true；关掉可容忍坏 CRC 的页）
  mut verify_crc : Bool
  /// 失步后是否尝试重新同步（默认 true；关掉则严格按顺序解析）
  mut resync : Bool
  /// 是否已经调用过 finish
  mut finished : Bool
}

///|
/// 创建一个默认配置的读取器：校验 CRC、允许重新同步。
pub fn PageReader::new() -> PageReader {
  let reader : PageReader = {
    buf: b"",
    pages: [],
    gaps: [],
    base: 0L,
    verify_crc: true,
    resync: true,
    finished: false,
  }
  reader
}

///|
/// 自定义配置：`verify_crc` 关闭时接受 CRC 不符的页；`resync` 关闭时不做失步重同步。
pub fn PageReader::with_options(verify_crc : Bool, resync : Bool) -> PageReader {
  let reader : PageReader = {
    buf: b"",
    pages: [],
    gaps: [],
    base: 0L,
    verify_crc,
    resync,
    finished: false,
  }
  reader
}

///|
/// 顺序拼接两块字节。
fn append_bytes(a : Bytes, b : Bytes) -> Bytes {
  if a.length() == 0 {
    return b
  }
  if b.length() == 0 {
    return a
  }
  let out = Buffer(size_hint=a.length() + b.length())
  out.write_bytes(a.exact_view())
  out.write_bytes(b.exact_view())
  out.to_bytes()
}

///|
/// 拷贝字节切片 `[start, end)`。
fn slice_bytes(data : Bytes, start : Int32, end : Int32) -> Bytes {
  if start == 0 && end == data.length() {
    return data
  }
  let out = Buffer(size_hint=end - start)
  let mut i = start
  while i < end {
    out.write_byte(data[i])
    i = i + 1
  }
  out.to_bytes()
}

///|
/// 记录一段被跳过的字节（入参是当前 `buf` 内的相对区间）。
fn PageReader::record_gap(
  self : PageReader,
  start : Int32,
  end : Int32,
) -> Unit {
  if end > start {
    self.gaps.push({
      offset: (self.base + start.to_int64()).to_int(),
      bytes: end - start,
    })
  }
}

///|
/// 在 `from` 之后找下一个捕获模式 "OggS"。
fn PageReader::find_capture_from(self : PageReader, from : Int32) -> Int32? {
  let data = self.buf
  let mut p = from
  while p + 4 <= data.length() {
    if is_page_start(data, p) {
      return Some(p)
    }
    p = p + 1
  }
  None
}

///|
/// 从当前位置尽量多解析出完整页；数据不足时保留残片等待下一次 feed。
fn PageReader::parse_available(self : PageReader) -> Unit {
  let mut pos = 0
  let mut stop = false
  while !stop {
    let data = self.buf
    let avail = data.length() - pos
    if avail < 4 {
      stop = true
    } else if !is_page_start(data, pos) {
      if self.resync {
        match self.find_capture_from(pos + 1) {
          Some(p) => {
            self.record_gap(pos, p)
            pos = p
          }
          None => {
            // 找不到下一个候选：保留末尾最多 3 字节（可能是半个 "OggS"）
            let keep = if avail > 3 { data.length() - 3 } else { pos }
            self.record_gap(pos, keep)
            pos = keep
            stop = true
          }
        }
      } else {
        // 严格模式：不重同步，把剩余字节留到 finish 时记为 skipped
        stop = true
      }
    } else if avail < 27 {
      stop = true // 页头不完整
    } else {
      let nseg = data[pos + 26].to_int()
      if avail < 27 + nseg {
        stop = true // 段表不完整
      } else {
        let mut payload_len = 0
        let mut i = 0
        while i < nseg {
          payload_len = payload_len + data[pos + 27 + i].to_int()
          i = i + 1
        }
        if avail < 27 + nseg + payload_len {
          stop = true // 负载不完整
        } else {
          match Page::parse(data, pos) {
            Some((page, next)) =>
              if self.verify_crc && !page_crc_ok(page) {
                // CRC 不符：失步（或坏页），跳 1 字节继续找
                self.record_gap(pos, pos + 1)
                if self.resync {
                  pos = pos + 1
                } else {
                  stop = true
                }
              } else {
                self.pages.push(page)
                pos = next
              }
            None => {
              self.record_gap(pos, pos + 1)
              if self.resync {
                pos = pos + 1
              } else {
                stop = true
              }
            }
          }
        }
      }
    }
  }
  // 统一推进：把已消费的前缀从 buf 中移除，并更新绝对偏移
  if pos > 0 {
    self.buf = slice_bytes(self.buf, pos, self.buf.length())
    self.base = self.base + pos.to_int64()
  }
}

///|
/// 喂入一块新字节，尽量解析出完整页（放入待取队列）。
pub fn PageReader::feed(self : PageReader, chunk : Bytes) -> Unit {
  self.finished = false
  self.buf = append_bytes(self.buf, chunk)
  self.parse_available()
}

///|
/// 流结束：把仍未消费的字节记为跳过的区间（截断页/非法尾巴）。
pub fn PageReader::finish(self : PageReader) -> Unit {
  let remaining = self.buf.length()
  if remaining > 0 {
    self.record_gap(0, remaining)
    self.base = self.base + remaining.to_int64()
    self.buf = b""
  }
  self.finished = true
}

///|
/// 待取页数量。
pub fn PageReader::pages_ready(self : PageReader) -> Int32 {
  self.pages.length()
}

///|
/// 取出已解析的页，并清空待取队列。
pub fn PageReader::take_pages(self : PageReader) -> Array[Page] {
  let out = self.pages
  self.pages = []
  out
}

///|
/// 累计跳过的区间（绝对偏移，按发现顺序）。
pub fn PageReader::skipped(self : PageReader) -> Array[Skipped] {
  self.gaps
}

///|
/// 取出并清空跳过区间列表。
pub fn PageReader::take_skipped(self : PageReader) -> Array[Skipped] {
  let out = self.gaps
  self.gaps = []
  out
}

///|
/// 尚未消费的字节数（不完整页/残片）。
pub fn PageReader::buffered(self : PageReader) -> Int32 {
  self.buf.length()
}

///|
/// 是否已经 finish。
pub fn PageReader::is_finished(self : PageReader) -> Bool {
  self.finished
}

///|
/// 尚未消费的字节副本（调试/统计用）。
pub fn PageReader::pending(self : PageReader) -> Bytes {
  self.buf
}

///|
/// 便捷函数：按固定块大小模拟流式读取整段数据，对每个完整页调用 `visit`。
pub fn for_each_page_chunked(
  data : Bytes,
  chunk_size : Int32,
  visit : (Page) -> Unit,
) -> Array[Skipped] {
  let reader = PageReader::new()
  let size = if chunk_size <= 0 { 4096 } else { chunk_size }
  let mut off = 0
  while off < data.length() {
    let end = if off + size > data.length() {
      data.length()
    } else {
      off + size
    }
    reader.feed(slice_bytes(data, off, end))
    for page in reader.take_pages() {
      visit(page)
    }
    off = end
  }
  reader.finish()
  reader.take_skipped()
}
