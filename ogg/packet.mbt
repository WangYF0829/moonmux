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
      // 本页最后一个「完整结束」的包在 packets 中的下标；-1 表示本页没有包结束
      let mut last_ended : Int = -1
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
            granule_position: -1L,
            serial: page.serial,
          })
          last_ended = packets.length() - 1
          acc.reset()
        }
      }
      // RFC 3533：页头的粒度位置只属于本页**最后一个完整结束的包**，
      // 同页其余包的粒度都是 -1（未携带）。曾经这里把页的值复制给页内每个包，
      // 后果是重新分页时这些包各自带出同一个粒度，页数与时间轴双双失真 ——
      // 而且它在本文件内部看不出来，只有把包重新封装成页之后才暴露。
      if last_ended >= 0 {
        let ended = packets[last_ended]
        packets[last_ended] = {
          data: ended.data,
          granule_position: page.granule_position,
          serial: ended.serial,
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

///|
/// 一个包会占几个段。
fn seg_count(p : Packet) -> Int {
  segments_for(p.data.length()).length()
}

///|
/// 一组包的负载字节数。
fn group_bytes(group : Array[Packet]) -> Int {
  let mut n = 0
  for p in group {
    n = n + p.data.length()
  }
  n
}

///|
/// 一组包的段数。
fn group_segs(group : Array[Packet]) -> Int {
  let mut n = 0
  for p in group {
    n = n + seg_count(p)
  }
  n
}

///|
/// 默认的目标页大小（字节）。
///
/// 4096 是 libogg 写死的阈值，也是 mutagen `from_packets` 的默认值 ——
/// 生态里的事实标准。需要别的值时把参数传进来，不要改这个常量。
pub const DEFAULT_PAGE_TARGET : Int = 4096

///|
/// 按目标页大小重新分页 —— 「攒够再出页」，而不是一包一页。
///
/// `paginate` 一包一页，页数等于包数。一个 6 秒的 Opus 文件因此会从 9 页涨到
/// 303 页、体积多付约 12%：每页都有 27 字节固定头 + 段表，而标准编码器
/// （libogg、mutagen 的默认值都是 4 KiB）会把多个包攒进一页。
///
/// 合并页有一条硬约束：**页边界只能落在携带真粒度（≥ 0）的包之后**。
/// 粒度属于「本页最后一个结束的包」，换个说法 —— 原文件里的真粒度恰好标出
/// 了它自己的页边界。以这些包为界切组，再把相邻组攒成更大的页，
/// 新页的最后一包必然带着真粒度，时间轴因此一格不差。
/// 反过来，若不管粒度随便攒，中间页的粒度就成了 -1，而页里明明有包结束，
/// 播放器的时钟会在那里断掉。
///
/// 没有真粒度（手工准备的包目录、旧清单）时每个包自成一组，退化为纯粹的
/// 按大小打包 —— 此时本来就没有时间信息可保。
///
/// 两处特殊处理：
/// - **第一组独占 BOS 页**。RFC 7845 §3 要求首页只放标识头，
///   把 OpusTags 甚至音频包塞进 BOS 页会被解码器拒绝。
/// - **单组超过一页容量**（手工目录里的超长包）时交回 `paginate` 逐包分页，
///   续页带 continued 标志，粒度只写在末页。
///
/// `target` ≤ 0 时与 `paginate` 完全一致 —— 默认行为不变，
/// `cat` / `split` 依赖的字节透传特性不受影响。
pub fn paginate_sized(packets : Array[Packet], serial : UInt, target : Int) -> Array[Page] {
  if packets.length() == 0 || target <= 0 {
    return paginate(packets, serial)
  }
  let limit = if target > 65025 { 65025 } else { target }
  // 是否存在真粒度：决定「按原页边界切组」还是「逐包成组」
  let mut timing = false
  for p in packets {
    if p.granule_position >= 0L {
      timing = true
    }
  }
  // 按原页边界切组：携带真粒度的包是它所在原页的最后一个包
  let split_groups : Array[Array[Packet]] = []
  let mut start = 0
  let mut i = 0
  while i < packets.length() {
    let end_here = !timing || packets[i].granule_position >= 0L
    if end_here {
      let g : Array[Packet] = []
      let mut k = start
      while k <= i {
        g.push(packets[k])
        k = k + 1
      }
      split_groups.push(g)
      start = i + 1
    }
    i = i + 1
  }
  if start < packets.length() {
    let g : Array[Packet] = []
    let mut k = start
    while k < packets.length() {
      g.push(packets[k])
      k = k + 1
    }
    split_groups.push(g)
  }
  let raw : Array[Page] = []
  let mut last_known : Int64 = -1L
  let mut gi = 0
  while gi < split_groups.length() {
    let head = split_groups[gi]
    // 单组就超出单页容量（超长包）→ 交回 paginate 逐包分页。
    // **必须清掉它自带的 BOS / EOS**：paginate 把这一组当成一条独立的流，
    // 会在组首页打 BOS、组末页打 EOS；而这一组往往只是整条流中间的一段，
    // 原样收下就会出现「一条流多个 BOS」「EOS 之后还有页」——
    // 产物过不了自己的 verify（真实缺陷，已由回归测试钉住）。
    if group_segs(head) > 255 || group_bytes(head) > 65025 {
      let strip = 255 - flag_bos().to_int() - flag_eos().to_int()
      for q in paginate(head, serial) {
        raw.push({
          header_type: (q.header_type.to_int() & strip).to_byte(),
          granule_position: q.granule_position,
          serial: q.serial,
          sequence: q.sequence,
          crc: q.crc,
          segments: q.segments,
          payload: q.payload,
        })
      }
      gi = gi + 1
      continue
    }
    let mut end = gi + 1
    if gi > 0 {
      let mut size = group_bytes(head)
      let mut segs = group_segs(head)
      while end < split_groups.length() {
        let gs = group_bytes(split_groups[end])
        let gg = group_segs(split_groups[end])
        // 合并的判据是「**加进来**会不会超过目标」，不是「当前是否已超」。
        // 后者会让一页在超过目标后还继续吞下下一个整页（例如把 61 字节的
        // OpusTags 页和一个 9.8 KB 的音频页并成一页），页数虽少一页，
        // 但页布局就与原文件对不上了 —— 往返对账时看不出错，只是字节不同。
        //
        // 单组本身超过目标时仍然独占一页：拆组就等于把原页劈开，
        // 中间那页会「有包结束却没有粒度」，时间轴当场断掉。
        if size + gs > limit || segs + gg > 255 {
          break
        }
        size = size + gs
        segs = segs + gg
        end = end + 1
      }
    }
    let segs : Array[Int] = []
    let buf = Buffer()
    let mut granule : Int64 = -1L
    let mut k = gi
    while k < end {
      for p in split_groups[k] {
        for s in segments_for(p.data.length()) {
          segs.push(s)
        }
        buf.write_bytes(p.data.exact_view())
        granule = p.granule_position
      }
      k = k + 1
    }
    // 页里有包结束就必须给一个真粒度。末组可能没有（被截断的流），
    // 此时沿用上一个已知值：粒度只要求单调不减，往前带一格是安全的近似，
    // 写 -1 反而与「本页有包结束」自相矛盾。
    if granule >= 0L {
      last_known = granule
    } else if segs.length() > 0 && last_known >= 0L {
      granule = last_known
    }
    raw.push({
      header_type: (0x00 : Byte),
      granule_position: granule,
      serial,
      sequence: 0U,
      crc: 0U,
      segments: segs,
      payload: buf.to_bytes(),
    })
    gi = end
  }
  // 统一编号并打 BOS / EOS；超长包组里中间页的 continued 标志已由
  // paginate 带上，这里只做按位或，不覆盖
  let out : Array[Page] = []
  let mut i2 = 0
  while i2 < raw.length() {
    let p = raw[i2]
    let mut header = p.header_type
    if i2 == 0 {
      header = header | flag_bos()
    }
    if i2 == raw.length() - 1 {
      header = header | flag_eos()
    }
    out.push({
      header_type: header,
      granule_position: p.granule_position,
      serial,
      sequence: i2.reinterpret_as_uint(),
      crc: 0U,
      segments: p.segments,
      payload: p.payload,
    })
    i2 = i2 + 1
  }
  out
}
