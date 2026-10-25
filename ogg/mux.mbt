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
  serial : UInt32
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
  let serials : Array[UInt32] = []
  let groups : Array[Array[Packet]] = []
  // 流号 → 下标；逐包线性查在「很多流」的目录上会退化成 O(包数 × 流数)
  let index_of : Map[UInt32, Int32] = Map([])
  for pkt in packets {
    match index_of.get(pkt.serial) {
      Some(i) => groups[i].push(pkt)
      None => {
        let i = serials.length()
        serials.push(pkt.serial)
        groups.push([pkt])
        index_of.set(pkt.serial, i)
      }
    }
  }
  let out : Array[LogicalStream] = []
  let mut k = 0
  while k < serials.length() {
    out.push({ serial: serials[k], packets: groups[k], })
    k = k + 1
  }
  out
}

///|
/// 把多条逻辑流交织成一列页（一包一页）。
///
/// 等价于 `mux_streams_sized(streams, 0)` —— 阈值 0 时退回 `paginate`
/// 的原有语义。需要按目标页大小攒页时用 `mux_streams_sized`。
pub fn mux_streams(
  streams : Array[LogicalStream],
) -> Result[Array[Page], String] {
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
  target : Int32,
) -> Result[Array[Page], String] {
  let seen : Map[UInt32, Bool] = Map([])
  for st in streams {
    match seen.get(st.serial) {
      Some(_) =>
        return Err(
          "流号 " + st.serial.to_string() + " 被多条逻辑流重复使用",
        )
      None => seen.set(st.serial, true)
    }
  }
  let per : Array[Array[Page]] = []
  for st in streams {
    per.push(paginate_sized(st.packets, st.serial, target))
  }
  // `cursors` 是每条流下一个待取页的下标，`carries` 是该流上一条已知的粒度
  let cursors : Array[Int32] = []
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
  // 第二阶段：按有效粒度升序做 k 路归并。用最小堆而不是每页扫描全部流，
  // 把 O(页数 × 流数) 降为 O(页数 × log 流数)；键相同时流下标小的先出。
  let heap : Array[MergeItem] = []
  let mut t = 0
  while t < per.length() {
    if cursors[t] < per[t].length() {
      heap_push(heap, {
        stream: t,
        key: page_merge_key(per[t][cursors[t]], carries[t]),
      })
    }
    t = t + 1
  }
  while heap_pop(heap) is Some(item) {
    let page = per[item.stream][cursors[item.stream]]
    out.push(page)
    if page.granule_position >= 0L {
      carries[item.stream] = page.granule_position
    }
    cursors[item.stream] = cursors[item.stream] + 1
    if cursors[item.stream] < per[item.stream].length() {
      heap_push(heap, {
        stream: item.stream,
        key: page_merge_key(
          per[item.stream][cursors[item.stream]],
          carries[item.stream],
        ),
      })
    }
  }
  Ok(out)
}

///|
/// 归并堆的元素：流下标 + 该流当前页的有效粒度。
priv struct MergeItem {
  stream : Int32
  key : Int64
}

///|
/// 页在归并时的有效粒度：无包结束的页沿用该流上一条已知粒度。
fn page_merge_key(page : Page, carry : Int64) -> Int64 {
  if page.granule_position >= 0L {
    page.granule_position
  } else {
    carry
  }
}

///|
/// 归并顺序：粒度升序，粒度相同时流下标升序。
fn merge_item_before(a : MergeItem, b : MergeItem) -> Bool {
  a.key < b.key || (a.key == b.key && a.stream < b.stream)
}

///|
fn heap_push(heap : Array[MergeItem], item : MergeItem) -> Unit {
  heap.push(item)
  let mut i = heap.length() - 1
  while i > 0 {
    let parent = (i - 1) / 2
    if !merge_item_before(heap[i], heap[parent]) {
      break
    }
    let tmp = heap[i]
    heap[i] = heap[parent]
    heap[parent] = tmp
    i = parent
  }
}

///|
fn heap_pop(heap : Array[MergeItem]) -> MergeItem? {
  if heap.length() == 0 {
    return None
  }
  let root = heap[0]
  let n = heap.length()
  let last = heap[n - 1]
  let _ = heap.pop()
  if n > 1 {
    heap[0] = last
    let mut i = 0
    let mut go = true
    while go {
      let left = i * 2 + 1
      if left >= n - 1 {
        go = false
      } else {
        let mut child = left
        if left + 1 < n - 1 && merge_item_before(heap[left + 1], heap[left]) {
          child = left + 1
        }
        if !merge_item_before(heap[child], heap[i]) {
          go = false
        } else {
          let tmp = heap[i]
          heap[i] = heap[child]
          heap[child] = tmp
          i = child
        }
      }
    }
  }
  Some(root)
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
  target : Int32,
) -> Result[Array[Page], String] {
  // 先做全局流号唯一性检查（跨段也算），再逐段封装
  let all_serials : Map[UInt32, Bool] = Map([])
  for chain in chains {
    for st in chain {
      match all_serials.get(st.serial) {
        Some(_) =>
          return Err(
            "流号 " +
            st.serial.to_string() +
            " 在多段物理流中重复 —— RFC 3533 §4 要求同一物理流内全局唯一",
          )
        None => all_serials.set(st.serial, true)
      }
    }
  }
  let out : Array[Page] = []
  let mut i = 0
  while i < chains.length() {
    match mux_streams_sized(chains[i], target) {
      Err(msg) => return Err("第 " + (i + 1).to_string() + " 段：" + msg)
      Ok(pages) =>
        for p in pages {
          out.push(p)
        }
    }
    i = i + 1
  }
  Ok(out)
}
