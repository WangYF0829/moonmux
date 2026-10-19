// seek.mbt —— 按 granule 定位页（插值二分）
//
// Ogg 没有索引，也不该有：索引与直播不兼容，还会因文件被编辑而失效
// （RFC 3533 明确把「无索引也能定位」当成设计要点）。
// 正确做法是在页的 granule 上做**插值二分** —— 页按时间递增排列，
// 天然是一个有序数组。
//
// 这里只做容器层的事：给一个目标 granule，返回「不晚于它的最后一个页」。
// 解码侧的 pre-roll（RFC 7845 §4.6：Opus 至少要提前 3840 样本、
// 即 80 ms 开始解码并丢弃输出，pre-roll 与 pre-skip 是两回事）
// 由调用方负责 —— 容器层不知道要不要解码。
//
// 三个必须守住的性质：
// 1. **结果必须终止**。插值在分布不均时可能停在原地，需退化为中点二分，
//    并设迭代上限；损坏文件不能让 seek 挂死。
// 2. **granule = -1 的页不能当路标**。那表示「本页没有包结束」，没有时间。
// 3. **返回的页必须满足 granule <= 目标**，否则调用方会从目标之后开始播。

///|
/// 一次定位的结果。
pub(all) struct SeekPoint {
  /// 该页在整个页序列中的下标
  page_index : Int
  /// 该页的起始字节偏移（可直接用于文件 seek）
  byte_offset : Int
  /// 页序号
  sequence : UInt
  /// 该页携带的粒度位置
  granule : Int64
}

///|
/// 在页序列里定位到「granule 不晚于 `target` 的最后一个页」。
///
/// 只看携带真实粒度的页（granule ≥ 0）：-1 的页没有时间信息，
/// 拿它当路标会把定位带到错误的偏移上。
pub fn seek_granule(
  pages : Array[Page],
  serial : UInt,
  target : Int64,
) -> SeekPoint? {
  // 收集路标：本流的、带真实粒度的页
  let offsets = page_offsets(pages)
  let idx : Array[Int] = []
  let marks : Array[Int64] = []
  let mut i = 0
  while i < pages.length() {
    if pages[i].serial == serial && pages[i].granule_position >= 0L {
      idx.push(i)
      marks.push(pages[i].granule_position)
    }
    i = i + 1
  }
  if idx.length() == 0 {
    return None
  }
  let n = idx.length()
  // 目标在两端之外时直接取端点
  if target <= marks[0] {
    return Some(point_at(pages, offsets, idx[0]))
  }
  if target >= marks[n - 1] {
    return Some(point_at(pages, offsets, idx[n - 1]))
  }
  // 插值二分：lo 始终满足 marks[lo] <= target
  let mut lo = 0
  let mut hi = n - 1
  let mut steps = 0
  while hi - lo > 1 && steps < 64 {
    let span = (marks[hi] - marks[lo]).to_double()
    let mid = if span > 0.0 {
      let ratio = (target - marks[lo]).to_double() / span
      let est = (lo.to_double() + (hi - lo).to_double() * ratio).to_int()
      // 估计值必须严格落在 (lo, hi) 内，否则插值没有推进 ——
      // granule 分布极不均匀时会停在原地，此时退化为中点二分
      if est <= lo {
        (lo + hi) / 2
      } else if est >= hi {
        hi - 1
      } else {
        est
      }
    } else {
      (lo + hi) / 2
    }
    if marks[mid] <= target {
      lo = mid
    } else {
      hi = mid
    }
    steps = steps + 1
  }
  Some(point_at(pages, offsets, idx[lo]))
}

///|
/// 组装一个定位结果。
fn point_at(pages : Array[Page], offsets : Array[Int], page_index : Int) -> SeekPoint {
  let page = pages[page_index]
  {
    page_index,
    byte_offset: offsets[page_index],
    sequence: page.sequence,
    granule: page.granule_position,
  }
}

///|
/// 一条流里第 `header_packets` 个包（0 基）**开始**在哪一页。
///
/// 对 Opus 是 2（OpusHead + OpusTags）、Vorbis 是 3（ID + comment + setup），
/// 也就是首个音频页。`seek 0` 应该落在这里，而不是停在粒度同样是 0 的
/// 头部页上 —— 头部页不能直接解码。
///
/// 注意「开始」而不是「结束」：首个音频包可能跨页，若返回它结束的那页，
/// 调用方会从 continued 包中间开始解码。找不到时返回 None，
/// 由调用方决定退回哪个落点。
pub fn first_audio_page(
  pages : Array[Page],
  serial : UInt,
  header_packets : Int,
) -> Int? {
  let mut completed = 0
  let mut i = 0
  while i < pages.length() {
    let page = pages[i]
    if page.serial == serial {
      // 页首是续包时，本页第一个段不是一个新包的开始
      let mut starts_here = (page.header_type.to_int() & flag_continued().to_int()) == 0
      for seg in page.segments {
        if starts_here && completed == header_packets {
          return Some(i)
        }
        if seg < 255 {
          completed = completed + 1
          starts_here = true
        } else {
          starts_here = false
        }
      }
    }
    i = i + 1
  }
  None
}
