// packet_edit.mbt —— 替换单条逻辑流里的某个包
//
// 元数据编辑的底座。这一层刻意不知道「包内容是什么」：
// OpusTags 也好、Vorbis 注释头也好，在容器层都只是「第 1 个包」。
// 载荷语义留给 codec/，容器层只负责一件事 ——
// **只重写受影响的那几页，其余页原样透传**。
//
// 为什么不能简单地把整条流重新分页：音频页重新分页会改变页布局，
// 元数据一改，整个文件的字节全变（虽然内容等价）。成熟实现都避免这一点：
// mutagen 在包长未变时原样复用旧页布局（`_from_packets_try_preserve`），
// 长度变了才重编号（`renumber` 只改页序号与 CRC）。
// 本函数走的是同一条路：替换受影响的页，必要时给同流后续页重编号。
//
// 重编号是**万不得已**才发生：调用方把新包补到与旧包等长时，
// 页数不变、后续页序号不变，产物只有那一页的字节不同。

///|
/// 替换某条逻辑流的第 `index` 个包，返回新的整文件页序列。
///
/// 只重写包含该包的页；同流后续页在页数变化时重编号（只改序号与 CRC，
/// 负载一个字节不动）。其它逻辑流、其它链接段的页完全不碰。
///
/// 失败情形：找不到该流、序号越界。
pub fn replace_packet(
  pages : Array[Page],
  serial : UInt,
  index : Int,
  new_data : Bytes,
) -> Result[Array[Page], String] {
  let stream = stream_pages(pages, serial)
  if stream.length() == 0 {
    return Err("文件里没有 serial=" + serial.to_string() + " 的逻辑流")
  }
  let packets = reassemble(stream)
  if index < 0 || index >= packets.length() {
    return Err(
      "第 " +
      index.to_string() +
      " 个包越界（该流共有 " +
      packets.length().to_string() +
      " 个包）",
    )
  }
  // 每页结束了多少个包，以及累计
  let before : Array[Int] = []
  let on_page : Array[Int] = []
  let mut acc = 0
  for page in stream {
    let mut ends = 0
    for seg in page.segments {
      if seg < 255 {
        ends = ends + 1
      }
    }
    before.push(acc)
    on_page.push(ends)
    acc = acc + ends
  }
  // 找到目标包结束所在页
  let mut end_page = -1
  let mut p = 0
  while p < stream.length() {
    if before[p] + on_page[p] > index {
      end_page = p
      break
    }
    p = p + 1
  }
  if end_page < 0 {
    return Err("第 " + index.to_string() + " 个包在页序列里找不到结束位置")
  }
  // 向前扩展到该页的起点：页首若是续包，说明目标包可能从上一页开始
  let mut start_page = end_page
  while start_page > 0 &&
    (stream[start_page].header_type.to_int() & flag_continued().to_int()) != 0 {
    start_page = start_page - 1
  }
  // 向后扩展到完整包的边界：末段为 255 说明还有包延伸到下一页
  while end_page < stream.length() - 1 && last_segment(stream[end_page]) == 255 {
    end_page = end_page + 1
  }
  // 这一页段里包含的全部包
  let first_pkt = before[start_page]
  let last_pkt = before[end_page] + on_page[end_page] - 1
  let rebuilt_pkts : Array[Packet] = []
  let mut k = first_pkt
  while k <= last_pkt {
    if k == index {
      rebuilt_pkts.push({ data: new_data, granule_position: packets[k].granule_position, serial })
    } else {
      rebuilt_pkts.push(packets[k])
    }
    k = k + 1
  }
  // 重建这一段的页，**保留原来的页分组**：把「在同一页结束的包」放回同一页。
  //
  // 不能一包一页：Vorbis 的注释头与 setup 头本来就共享第 1 页，
  // 一包一页会把它们拆成两页，中间那页变成「有包结束却 -1」，
  // verify 立刻报警，页数也从 3 涨到 4 —— 改个标签却动了整个布局。
  let rebuilt : Array[Page] = []
  let mut last_known : Int64 = -1L
  let mut g = start_page
  while g <= end_page {
    let lo = before[g]
    let hi = before[g] + on_page[g]
    if hi > lo {
      let segs : Array[Int] = []
      let buf = Buffer()
      let mut page_granule : Int64 = -1L
      let mut k = lo
      while k < hi {
        let pkt = rebuilt_pkts[k - first_pkt]
        for seg in segments_for(pkt.data.length()) {
          segs.push(seg)
        }
        buf.write_bytes(pkt.data.exact_view())
        page_granule = pkt.granule_position
        k = k + 1
      }
      if page_granule >= 0L {
        last_known = page_granule
      } else if last_known >= 0L {
        // 页里有包结束就必须给真粒度（RFC 3533：-1 只用于没有包结束的页）
        page_granule = last_known
      }
      if segs.length() <= 255 && buf.length() <= 65025 {
        rebuilt.push({
          header_type: (0x00 : Byte),
          granule_position: page_granule,
          serial,
          sequence: 0U,
          crc: 0U,
          segments: segs,
          payload: buf.to_bytes(),
        })
      } else {
        // 新包太大，这一页装不下：拆页，并清掉 paginate 自带的 BOS / EOS
        let group_packets : Array[Packet] = []
        let mut q = lo
        while q < hi {
          group_packets.push(rebuilt_pkts[q - first_pkt])
          q = q + 1
        }
        let strip = 255 - flag_bos().to_int() - flag_eos().to_int()
        for pg in paginate(group_packets, serial) {
          rebuilt.push({
            header_type: (pg.header_type.to_int() & strip).to_byte(),
            granule_position: pg.granule_position,
            serial,
            sequence: 0U,
            crc: 0U,
            segments: pg.segments,
            payload: pg.payload,
          })
        }
      }
    }
    g = g + 1
  }
  if rebuilt.length() == 0 {
    return Err("重建后的页为空")
  }
  // BOS / EOS 只在真正的流首尾保留：中间段重建出来的页不能带这两个标志
  let is_first = start_page == 0
  let is_last = end_page == stream.length() - 1
  let fixed : Array[Page] = []
  let mut r = 0
  while r < rebuilt.length() {
    let pg = rebuilt[r]
    let mut header = pg.header_type
    if !is_first && r == 0 {
      header = (header.to_int() & (255 - flag_bos().to_int())).to_byte()
    }
    if !is_last && r == rebuilt.length() - 1 {
      header = (header.to_int() & (255 - flag_eos().to_int())).to_byte()
    }
    fixed.push({
      header_type: header,
      granule_position: pg.granule_position,
      serial,
      sequence: 0U,
      crc: 0U,
      segments: pg.segments,
      payload: pg.payload,
    })
    r = r + 1
  }
  // 拼回整条流并重编号
  let new_stream : Array[Page] = []
  let mut i = 0
  while i < start_page {
    new_stream.push(stream[i])
    i = i + 1
  }
  for pg in fixed {
    new_stream.push(pg)
  }
  let mut j = end_page + 1
  while j < stream.length() {
    new_stream.push(stream[j])
    j = j + 1
  }
  let renumbered : Array[Page] = []
  let mut n = 0
  while n < new_stream.length() {
    let pg = new_stream[n]
    renumbered.push({
      header_type: pg.header_type,
      granule_position: pg.granule_position,
      serial,
      sequence: n.reinterpret_as_uint(),
      crc: 0U,
      segments: pg.segments,
      payload: pg.payload,
    })
    n = n + 1
  }
  // 按原顺序把该流的页换掉，其它流的页原位不动。
  //
  // 逐一替换而不是「整条流插到第一个页的位置」：多流文件里各流的页是交织的，
  // 把 A 流的页全搬到前面会让 B 流的 BOS 页落到数据页之后 —— 交织规则被破坏。
  // 页数变多时，多出来的页接在该流最后一页之后（仍是数据页，位置合法）。
  let mut last_pos = -1
  let mut q = 0
  while q < pages.length() {
    if pages[q].serial == serial {
      last_pos = q
    }
    q = q + 1
  }
  let out : Array[Page] = []
  let mut cursor = 0
  let mut idx = 0
  while idx < pages.length() {
    let pg = pages[idx]
    if pg.serial == serial {
      if cursor < renumbered.length() {
        out.push(renumbered[cursor])
        cursor = cursor + 1
      }
    } else {
      out.push(pg)
    }
    if idx == last_pos {
      while cursor < renumbered.length() {
        out.push(renumbered[cursor])
        cursor = cursor + 1
      }
    }
    idx = idx + 1
  }
  Ok(out)
}

///|
/// 一页的段表最后一项（空段表返回 0）。
fn last_segment(page : Page) -> Int {
  if page.segments.length() == 0 {
    0
  } else {
    page.segments[page.segments.length() - 1]
  }
}
