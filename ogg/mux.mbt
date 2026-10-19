// mux.mbt —— 多条逻辑流的分组与交织
//
// Ogg 的一个「物理流」（一个文件）可以承载多条「逻辑流」，
// 靠页头里的 serial 区分。典型用途是音视频复用：
// 一条视频流加若干条音频流共用一个文件。
//
// 交织要守 RFC 3533 的两条约束，缺一条标准解码器就读不出来：
//
// 1. **所有 BOS 页排在最前面**。每条逻辑流的首页带 0x02 标志，
//    解码器在解任何数据之前，要先读到所有流的头部包
//    （OpusHead、Vorbis 识别头等）才能决定怎么解。
//    因此既不能「流 1 全部写完再写流 2」，也不能把 BOS 页混进数据页中间。
// 2. **此后按粒度位置升序交织**。粒度位置就是时间：播放器顺序往下读，
//    播到第 N 秒时手上必须已经拿到所有流第 N 秒前后的数据。
//    某条流若一股脑写在前面，播放器要么缓冲区撑爆，要么读到的是过期数据。
//
// 粒度位置为 -1 的页（本页没有包结束）自身没有时间，
// 沿用该流上一条已知的粒度 —— 它本来就是上一页的延续。

///|
/// 一条逻辑流：流号 + 该流的包序列。
pub(all) struct LogicalStream {
  serial : UInt
  packets : Array[Packet]
}

///|
/// 把包按逻辑流分组，保持每条流**首次出现的顺序**。
///
/// 这个顺序就是各流 BOS 页在原文件里的先后 —— 交织时靠它决定
/// 「谁的头包排第一」。不能改用流号排序：流号是随机分配的，
/// 大小与文件里的先后顺序无关（Ogg Skeleton 的骨架流必须先出，
/// 但它的流号未必最小）。
pub fn group_by_stream(packets : Array[Packet]) -> Array[LogicalStream] {
  let serials : Array[UInt] = []
  let groups : Array[Array[Packet]] = []
  for pkt in packets {
    let mut found = -1
    let mut i = 0
    while i < serials.length() {
      if serials[i] == pkt.serial {
        found = i
      }
      i = i + 1
    }
    if found < 0 {
      serials.push(pkt.serial)
      groups.push([pkt])
    } else {
      groups[found].push(pkt)
    }
  }
  let out : Array[LogicalStream] = []
  let mut k = 0
  while k < serials.length() {
    out.push({ serial: serials[k], packets: groups[k] })
    k = k + 1
  }
  out
}

///|
/// 把多条逻辑流交织成一列页（一包一页）。
///
/// 等价于 `mux_streams_sized(streams, 0)` —— 阈值 0 时退回 `paginate`
/// 的原有语义。需要按目标页大小攒页时用 `mux_streams_sized`。
pub fn mux_streams(streams : Array[LogicalStream]) -> Result[Array[Page], String] {
  mux_streams_sized(streams, 0)
}

///|
/// 把多条逻辑流交织成一列页，按 `target` 字节攒页。
///
/// 每条流先各自分页（页序号各自从 0 编号，首末页各自打 BOS / EOS），
/// 再分两阶段输出：先出所有 BOS 页，再按粒度位置做 k 路归并。
///
/// `target` 传给 `paginate_sized`：> 0 时按目标大小攒页（BOS 页仍独占），
/// 0 时与 `mux_streams` 完全一致。
///
/// 唯一的失败情形是两条流用了同一个流号 —— 对 `reassemble` 来说
/// 相同 serial 就是同一条流，拆出来的包会被粘在一起。
/// 静默接受只会把错误推迟到解码阶段爆发，所以在这里就拒绝。
pub fn mux_streams_sized(
  streams : Array[LogicalStream],
  target : Int,
) -> Result[Array[Page], String] {
  let mut i = 0
  while i < streams.length() {
    let mut j = i + 1
    while j < streams.length() {
      if streams[i].serial == streams[j].serial {
        return Err(
          "流号 " + streams[i].serial.to_string() + " 被多条逻辑流重复使用",
        )
      }
      j = j + 1
    }
    i = i + 1
  }
  let per : Array[Array[Page]] = []
  for st in streams {
    per.push(paginate_sized(st.packets, st.serial, target))
  }
  // `cursors` 是每条流下一个待取页的下标，`carries` 是该流上一条已知的粒度
  let cursors : Array[Int] = []
  let carries : Array[Int64] = []
  let mut k = 0
  while k < per.length() {
    cursors.push(0)
    carries.push(0L)
    k = k + 1
  }
  let out : Array[Page] = []
  // 第一阶段：所有首（BOS）页先出
  let mut s = 0
  while s < per.length() {
    if per[s].length() > 0 {
      let first = per[s][0]
      out.push(first)
      cursors[s] = 1
      if first.granule_position >= 0L {
        carries[s] = first.granule_position
      }
    }
    s = s + 1
  }
  // 第二阶段：按有效粒度升序做 k 路归并，粒度相同时序号小的流先出
  let mut go = true
  while go {
    let mut pick = -1
    let mut pick_key : Int64 = 0L
    let mut t = 0
    while t < per.length() {
      if cursors[t] < per[t].length() {
        let page = per[t][cursors[t]]
        let key = if page.granule_position >= 0L {
          page.granule_position
        } else {
          carries[t]
        }
        if pick < 0 || key < pick_key {
          pick = t
          pick_key = key
        }
      }
      t = t + 1
    }
    if pick < 0 {
      go = false
    } else {
      let page = per[pick][cursors[pick]]
      out.push(page)
      if page.granule_position >= 0L {
        carries[pick] = page.granule_position
      }
      cursors[pick] = cursors[pick] + 1
    }
  }
  Ok(out)
}

///|
/// 按**物理流（链）**封装：每一段内部照常交织，段与段首尾相接。
///
/// 这是 chained 文件的写回路径。`mux_streams_sized` 只处理「一个物理流里
/// 交织多条逻辑流」；把 chained 文件的所有流一次性丢给它，多段会被压成
/// 一段同时播放 —— 容器结构仍然合法，语义已经变了。所以链边界必须显式传递。
///
/// **所有段的流号必须全局唯一**（RFC 3533 §4：Each chained logical bitstream
/// MUST have a unique serial number within the scope of the physical bitstream）。
/// 跨段复用会让读取端把两段当成同一條流：页序号从中间重新数起、
/// 包被粘在一起 —— 所以这里拒绝，而不是交给播放器去猜。
pub fn mux_chains_sized(
  chains : Array[Array[LogicalStream]],
  target : Int,
) -> Result[Array[Page], String] {
  // 先做全局流号唯一性检查（跨段也算），再逐段封装
  let all_serials : Array[UInt] = []
  for chain in chains {
    for st in chain {
      if has_serial(all_serials, st.serial) {
        return Err(
          "流号 " +
          st.serial.to_string() +
          " 在多段物理流中重复 —— RFC 3533 §4 要求同一物理流内全局唯一",
        )
      }
      all_serials.push(st.serial)
    }
  }
  let out : Array[Page] = []
  let mut i = 0
  while i < chains.length() {
    match mux_streams_sized(chains[i], target) {
      Err(msg) => return Err("第 " + (i + 1).to_string() + " 段：" + msg)
      Ok(pages) => {
        for p in pages {
          out.push(p)
        }
      }
    }
    i = i + 1
  }
  Ok(out)
}
