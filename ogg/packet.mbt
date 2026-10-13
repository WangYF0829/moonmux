// packet.mbt —— 把页内的段重组成逻辑包
//
// Ogg 有两级切分：逻辑流被切成「页」（page），页内又被切成「段」
// （segment，长度 0 到 255）。段表里出现 255，表示包在此处尚未结束、
// 要继续读下一段；出现小于 255 的段，则该包在此段结束。
// 因此一个包可以横跨多页 —— 此时后一页的头类型带有 0x01 标志。
//
// 重组规则完全由段表决定，与负载内容无关：
// 这正是 Ogg 能用同一套容器承载任意编解码器数据的原因。

///|
/// 一个重组后的逻辑包。
///
/// `granule_position` 取自**包结束所在页**的粒度位置 ——
/// 对音频流来说，它通常表示该包解出的第一个采样点的时间位置。
pub(all) struct Packet {
  data : Bytes
  granule_position : Int64
  serial : UInt
}

///|
/// 把一列页重组成包。
///
/// 仅做重组，不做校验。若页序列本身是截断的（最后一个包的段表以 255
/// 结尾却没有后续页），末尾的不完整数据会被丢弃，不产生包 ——
/// 宁可少一个包，也不交出半截数据。
pub fn reassemble(pages : Array[Page]) -> Array[Packet] {
  let packets : Array[Packet] = []
  let acc = Buffer()
  for page in pages {
    let mut offset = 0
    for seg in page.segments {
      let mut i = 0
      while i < seg {
        acc.write_byte(page.payload[offset + i])
        i = i + 1
      }
      offset = offset + seg
      // 小于 255 的段标志着包在此结束
      if seg < 255 {
        packets.push({
          data: acc.to_bytes(),
          granule_position: page.granule_position,
          serial: page.serial,
        })
        acc.reset()
      }
    }
  }
  packets
}

///|
/// 把包序列切成页所需的段表。
///
/// 规则是把包长反复减去 255：每满 255 就记一个 255，
/// 余数（含 0）作为最后一段收尾。这决定了包在页边界处如何被切开。
/// 例如长度 255 的包，段表是 [255, 0] —— 末尾那个 0 段是必需的，
/// 否则解码器会认为包还没结束。
pub fn segments_for(len : Int) -> Array[Int] {
  let segs : Array[Int] = []
  let mut rest = len
  while rest >= 255 {
    segs.push(255)
    rest = rest - 255
  }
  segs.push(rest)
  segs
}
