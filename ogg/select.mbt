// select.mbt —— 从一条物理流里挑出单条逻辑流
//
// 一个 Ogg 文件里可以交织多条逻辑流（音视频复用、多语言音轨等），
// 用 serial 区分。要把其中一条单独取出来，需要的是**筛选**而不是重写：
//
// RFC 3533 规定每条逻辑流各自的页序号从 0 起逐页递增，
// 所以按流号筛出来的页序列本身就是一份合法的单流 Ogg ——
// 页在文件里的相对顺序不变，页序号本来就连续，CRC 也还是对的。
//
// 抽流因此不重排、不改页序号、不重算 CRC，产物与输入里那一段逐字节相同。
// 这一点和 `demux`（拆到包）有本质区别：`demux` 丢掉页边界与粒度位置，
// 再封回去只能得到「结构合法但布局不同」的文件；`select` 保持页级原样，
// 取出来的文件可以拿去做逐字节对账。

///|
/// 文件里是否出现过流号 `serial`。
pub fn has_stream(pages : Array[Page], serial : UInt32) -> Bool {
  for page in pages {
    if page.serial == serial {
      return true
    }
  }
  false
}

///|
/// 取出一条逻辑流的全部页，保持它们在文件中的原有顺序。
///
/// 流号不存在时返回空数组 —— 调用方若要区分「没有这条流」与「这条流没有页」，
/// 先用 `has_stream` 判断（后者在合法文件里不可能出现）。
pub fn stream_pages(pages : Array[Page], serial : UInt32) -> Array[Page] {
  let out : Array[Page] = []
  for page in pages {
    if page.serial == serial {
      out.push(page)
    }
  }
  out
}

///|
/// 把 1 起算的**逻辑流序号**换算成流号。
///
/// 序号按流在文件中首次出现的顺序编号，与 `demux` 输出的 `s1`、`s2` 一致。
/// 刻意不按流号大小排序：流号是随机分配的，大小与文件里的先后顺序无关
/// （Ogg Skeleton 的骨架流必须先出，但它的流号未必最小）。
///
/// 序号越界时返回 Err 并给出实际条数 —— 让 `extract` 报「超出范围（本文件有 2 条）」
/// 比报「找不到」有用得多。
pub fn serial_at(pages : Array[Page], index : Int32) -> Result[UInt32, String] {
  let serials = serials_of(pages)
  if index < 1 || index > serials.length() {
    return Err(
      "逻辑流序号 " +
      index.to_string() +
      " 超出范围（本文件有 " +
      serials.length().to_string() +
      " 条逻辑流）",
    )
  }
  Ok(serials[index - 1])
}
