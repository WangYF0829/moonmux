// chain.mbt —— 物理流的链接（chained bitstream）与拆分
//
// Ogg 允许多条物理流首尾相接：前一条流的末页带 EOS，下一条流重新从
// BOS 开始，播放器读到 EOS 后重新初始化解码器继续播。
// 分段录音的合并、电台节目的拼接都是这种形态。
//
// 链接的合法性只取决于一件事：**先后两条流不能共用流号**。
// 流号是页头里的身份标识，两条不同的逻辑流共用同一个流号，
// 读取端会当成一条流处理 —— 页序号对不上，包也会被粘在一起。
//
// 本模块同时提供链接的逆操作 `split_chains`：把一条链接流切回
// 各自独立的物理流。链接与拆分构成一对互逆操作 ——
// `split_chains(chain(a, b))` 应当得到 `[a, b]`。

///|
/// `serials` 里是否已有流号 `s`。
fn has_serial(serials : Array[UInt], s : UInt) -> Bool {
  let mut i = 0
  while i < serials.length() {
    if serials[i] == s {
      return true
    }
    i = i + 1
  }
  false
}

///|
/// 列出一条物理流里出现过的所有流号，按首次出现顺序。
///
/// 这个顺序也是各流 BOS 页的先后顺序。
pub fn serials_of(pages : Array[Page]) -> Array[UInt] {
  let serials : Array[UInt] = []
  for p in pages {
    if !has_serial(serials, p.serial) {
      serials.push(p.serial)
    }
  }
  serials
}

///|
/// 把 `second` 接在 `first` 之后，产出一列页。
///
/// 双方流号不冲突时**原样透传**：页、CRC 与页序号都保持读入时的样子，
/// 链接产物与手工拼接字节一致 —— 拼接本来就该是无损的。
/// 冲突时把 `second` 按流重组，给相撞的流换一个两边都未使用的新流号，
/// 再重新分页交织 —— 这一步会重排 `second` 的页，
/// 但每条流的包内容与粒度位置不变。
pub fn chain(first : Array[Page], second : Array[Page]) -> Result[Array[Page], String] {
  if first.length() == 0 {
    return Ok(second)
  }
  if second.length() == 0 {
    return Ok(first)
  }
  let used = serials_of(first)
  let second_serials = serials_of(second)
  let mut clash = false
  for s in second_serials {
    if has_serial(used, s) {
      clash = true
    }
  }
  if !clash {
    let out : Array[Page] = []
    for p in first {
      out.push(p)
    }
    for p in second {
      out.push(p)
    }
    return Ok(out)
  }
  // 有流号相撞：换新流号后重新分页。
  // 新流号从双方所有流号的最大值往上递增，保证与两边都不冲突。
  let mut max_serial : UInt = 0U
  for s in used {
    if s > max_serial {
      max_serial = s
    }
  }
  for s in second_serials {
    if s > max_serial {
      max_serial = s
    }
  }
  let streams = group_by_stream(reassemble(second))
  let mut next = max_serial + 1U
  let remapped : Array[LogicalStream] = []
  for st in streams {
    let serial = if has_serial(used, st.serial) {
      let fresh = next
      next = next + 1U
      fresh
    } else {
      st.serial
    }
    remapped.push({ serial, packets: st.packets })
  }
  // 用按大小攒页而不是一包一页：重组的包只有「原页最后一个包」带真粒度，
  // 一包一页会让中间那些页的粒度全变成 -1（时间轴断掉）。
  // 按原页边界攒页则每页的最后一包都带真粒度，时间轴一格不差。
  match mux_streams_sized(remapped, DEFAULT_PAGE_TARGET) {
    Err(msg) => Err(msg)
    Ok(pages) => {
      let out : Array[Page] = []
      for p in first {
        out.push(p)
      }
      for p in pages {
        out.push(p)
      }
      Ok(out)
    }
  }
}

///|
/// 页是否带 BOS 标志（逻辑流的开头）。
fn is_bos(page : Page) -> Bool {
  (page.header_type.to_int() & flag_bos().to_int()) != 0
}

///|
/// 把一条物理流按链接点切成若干段，每段是一条独立的物理流。
///
/// 切分依据是 **BOS 页出现在数据页之后**：一条流内部，BOS 页只可能成组
/// 出现在开头（解码器必须先读到头包才能解后面的数据），
/// 所以在若干数据页之后冒出来的 BOS 页，只能是下一条流的开头。
///
/// 这里刻意只切「字节本身能确定」的地方。有一种形态在规格上是歧义的：
/// 两条首尾相接的单页流，与「同一物理流里交织的两条单页流」
/// 是**完全相同的一串字节** —— 单页流的 BOS 与 EOS 落在同一页上，
/// 段内因此根本不出现数据页，无从判断下一个 BOS 页是同段的第二条流
/// 还是新段的第一条流。遇到这种情况一律不切（归为一段）：
/// 少切一段最坏是没帮上忙，错切一段会把一条好流劈成两半。
///
/// 拆分不做任何重写：切出来的每段都沿用原页对象，字节与 CRC 原样保留。
/// 非链接流（绝大多数 Ogg 文件）只切出一段，内容与输入完全一致 ——
/// 拆分因此永远不丢页，也永远不会把一份合法文件切坏。
pub fn split_chains(pages : Array[Page]) -> Array[Array[Page]] {
  let chains : Array[Array[Page]] = []
  if pages.length() == 0 {
    return chains
  }
  let mut current : Array[Page] = []
  // 当前段是否已经出过不带 BOS 的页（即已经越过开头的 BOS 页组）
  let mut saw_plain = false
  for page in pages {
    if is_bos(page) {
      if saw_plain {
        chains.push(current)
        current = []
        saw_plain = false
      }
    } else {
      saw_plain = true
    }
    current.push(page)
  }
  chains.push(current)
  chains
}
