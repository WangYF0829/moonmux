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
/// 查找逻辑流序号在 `serials` 中的下标；未出现过返回 -1。
fn serial_index(serials : Array[UInt], s : UInt) -> Int {
  let mut i = 0
  while i < serials.length() {
    if serials[i] == s {
      return i
    }
    i = i + 1
  }
  -1
}

///|
/// 把一列页重组成包。
///
/// 仅做重组，不做校验。两条不变量：
///
/// 1. **按逻辑流分流**。Ogg 允许同一字节流中交织多条逻辑流
///    （Ogg Skeleton、音视频复用等）。每条流各有独立的累加器，
///    否则不同流的段会被粘成同一个包，且包上标的 `serial` 会是错的。
/// 2. **截断即丢弃**。段表声明的总长与该页实际负载不符时，页本身已损坏；
///    这条流上尚未成形的数据一并丢弃，不产生包 ——
///    宁可少一个包，也不交出半截数据，更不越界读。
pub fn reassemble(pages : Array[Page]) -> Array[Packet] {
  let packets : Array[Packet] = []
  let serials : Array[UInt] = []
  let accs : Array[Buffer] = []
  for page in pages {
    let idx = serial_index(serials, page.serial)
    let ai = if idx >= 0 {
      idx
    } else {
      serials.push(page.serial)
      accs.push(Buffer())
      serials.length() - 1
    }
    let acc = accs[ai]
    // 段表各项之和必须恰好等于负载长度 —— Page::parse 产出的页天然满足，
    // 但本函数是公开 API，手工构造或上层拼装的页可能不满足。
    let mut declared = 0
    for seg in page.segments {
      declared = declared + seg
    }
    if declared != page.payload.length() {
      acc.reset()
    } else {
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
  }
  packets
}

///|
/// 把包长切成页内段表。
///
/// 规则是把包长反复减去 255：每满 255 就记一个 255，
/// 余数（含 0）作为最后一段收尾。这决定了包在页边界处如何被切开。
/// 例如长度 255 的包，段表是 [255, 0] —— 末尾那个 0 段是必需的，
/// 否则解码器会认为包还没结束。
///
/// 注意：本函数只负责**单个包**的段表，不保证段数不超过 255。
/// 段数超过 255 时应由 `paginate` 拆到多页承载。
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

///|
/// 把包序列切成合法的页序列 —— `reassemble` 的逆运算。
///
/// RFC 3533 规定单页最多 255 个段，因此单页负载上限为 255×255 = 65025 字节。
/// 超过这个上限的包**必须跨页承载**：续页带 0x01（continued）标志。
/// 页头的段数字段只有一个字节，若不做拆分而直接写超出的段数，
/// 长度会被静默截断、页结构随之崩坏 —— 这是之前版本的真实缺陷。
///
/// 粒度位置只写在包**结束**所在的那一页，其余页写 -1
/// （RFC 3533：表示「本页没有包结束」）。首页打 BOS、末页打 EOS，
/// 解码器据此判断流边界，缺了会被认为文件被截断。
pub fn paginate(packets : Array[Packet], serial : UInt) -> Array[Page] {
  let pages : Array[Page] = []
  let mut sequence = 0
  for pkt in packets {
    let segs = segments_for(pkt.data.length())
    let mut seg_idx = 0
    let mut payload_off = 0
    let mut first_chunk = true
    while seg_idx < segs.length() {
      // 每页最多取 255 个段
      let chunk : Array[Int] = []
      let mut chunk_len = 0
      while seg_idx < segs.length() && chunk.length() < 255 {
        chunk.push(segs[seg_idx])
        chunk_len = chunk_len + segs[seg_idx]
        seg_idx = seg_idx + 1
      }
      let buf = Buffer()
      let mut k = 0
      while k < chunk_len {
        buf.write_byte(pkt.data[payload_off + k])
        k = k + 1
      }
      payload_off = payload_off + chunk_len
      let ends_here = seg_idx >= segs.length()
      let mut header : Byte = (0x00 : Byte)
      if !first_chunk {
        header = header | flag_continued()
      }
      pages.push({
        header_type: header,
        granule_position: if ends_here { pkt.granule_position } else { -1L },
        serial,
        sequence: sequence.reinterpret_as_uint(),
        crc: 0U,
        segments: chunk,
        payload: buf.to_bytes(),
      })
      sequence = sequence + 1
      first_chunk = false
    }
  }
  if pages.length() > 0 {
    let first = pages[0]
    pages[0] = {
      header_type: first.header_type | flag_bos(),
      granule_position: first.granule_position,
      serial: first.serial,
      sequence: first.sequence,
      crc: first.crc,
      segments: first.segments,
      payload: first.payload,
    }
    let last = pages.length() - 1
    let tail = pages[last]
    pages[last] = {
      header_type: tail.header_type | flag_eos(),
      granule_position: tail.granule_position,
      serial: tail.serial,
      sequence: tail.sequence,
      crc: tail.crc,
      segments: tail.segments,
      payload: tail.payload,
    }
  }
  pages
}
