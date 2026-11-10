// stream.mbt —— 字节流与页序列之间的转换

///|
/// 一段无法同步到页的字节区间（坏了、被插了东西、或被截断）。
pub(all) struct Skipped {
  /// 区间在文件里的起始偏移
  offset : Int32
  /// 跳过的字节数
  bytes : Int32
}

///|
/// 从字节流中依次解析出所有页。
///
/// 遇到无法解析的位置即停止，不做重同步扫描 ——
/// 调用方拿到的通常是完整文件的全部内容，损坏的流应当在更上层处理。
///
/// 需要「跳过坏页继续读」时用 `parse_pages_lenient`。
pub fn parse_pages(data : Bytes) -> Array[Page] {
  let pages : Array[Page] = []
  let mut offset = 0
  let mut go = true
  while go && offset < data.length() {
    match Page::parse(data, offset) {
      Some((page, next)) => {
        pages.push(page)
        offset = next
      }
      None => go = false
    }
  }
  pages
}

///|
/// 重同步 CRC 工作预算的放大系数（相对输入大小）。
///
/// 合法文件的重同步只发生在少量损坏区域：候选要么被 `plausible_page_start`
/// 廉价挡掉，要么很快命中真页，累计 CRC 字节数与输入同阶。而「稠密伪页头」
/// （例如每 6 字节一个 `OggS\0\0`，每个候选都能通过预筛、凑出一页的段表）
/// 会让每个候选付出整页长度的 CRC 代价，实测约 4 s/MiB（~1000× 放大）。
/// 预算把这个上界钉死为 `factor × 输入长度 + base` 字节（Int64 计算，避免
/// Int32 回绕），超限即判定为伪页头洪水，不再继续扫描。
const RESYNC_BUDGET_FACTOR : Int64 = 8L

///|
/// 重同步 CRC 工作预算的常数项，让很小的文件也有基本预算。
const RESYNC_BUDGET_BASE : Int64 = 65536L

///|
/// 一次容错解析允许的重同步 CRC 工作字节数：`factor × 输入长度 + base`。
fn resync_budget(input_len : Int32) -> Int64 {
  input_len.to_int64() * RESYNC_BUDGET_FACTOR + RESYNC_BUDGET_BASE
}

///|
/// 从 `from` 起寻找下一个「结构完整且 CRC 复核通过」的页起点。
///
/// 返回 `(页起点, 本次消耗的 CRC 字节数, 是否因超出预算而中止)`。
///
/// 三个阶段都不物化 `Page`，单候选成本被压到一次遍历：
/// 1. `plausible_page_start` 预筛只读 6 字节（魔数 + version + 保留位）；
/// 2. `page_length_at` 只按段表算页长，确认页在剩余字节内结构完整；
/// 3. `crc32_page_range` 直接在原始字节上按页范围算 CRC，与页内 CRC 字段比较。
/// 只有本函数命中的位置才会被 `Page::parse` 真正接管（每个命中位置一次，
/// 线性成本）。
///
/// 预算检查放在每次 CRC **之前**：`spent + page_len > budget_left` 时立即
/// 中止，绝不先算再查 —— 单次调用的 CPU 上界因此与输入大小严格成比例。
/// 所有边界都用减法表达，`Int32` 在接近 2³¹ 时不会回绕（M-29）。
fn find_resync_page(
  data : Bytes,
  from : Int32,
  budget_left : Int64,
) -> (Int32?, Int64, Bool) {
  let mut spent : Int64 = 0L
  if data.length() < 27 {
    return (None, spent, false)
  }
  let max_start = data.length() - 27
  let mut probe = from
  while probe <= max_start {
    if plausible_page_start(data, probe) {
      // 候选的结构扫描成本（页头 27 字节 + 段表指针）也计入预算：
      // 否则「每字节一个 255 段伪页头」可以用段表扫描放大 CPU，
      // 而 CRC 预算永远等不到。probe <= max_start 保证 +26 不越界。
      let structural = 27 + data[probe + 26].to_int()
      if spent + structural.to_int64() > budget_left {
        return (None, spent, true)
      }
      spent = spent + structural.to_int64()
      match page_length_at(data, probe) {
        Some(page_len) => {
          if spent + page_len.to_int64() > budget_left {
            return (None, spent, true)
          }
          let page_end = probe + page_len
          if crc32_page_range(data, probe, page_end) ==
            read_u32_le(data, probe + 22) {
            return (Some(probe), spent, false)
          }
          // 结构像页但 CRC 不符：这个候选的整页 CRC 代价已经付出，记入预算
          spent = spent + page_len.to_int64()
        }
        None => ()
      }
    }
    probe = probe + 1
  }
  (None, spent, false)
}

///|
/// 容错解析核心：返回（页, 跳过区间, 是否因重同步超预算而提前中止）。
///
/// 提前中止时已把「无法再同步的剩余字节」记为一个跳过区间，调用方据此
/// 决定返回 Err（`parse_pages_lenient_checked`）还是照常返回（兼容包装）。
fn parse_pages_lenient_core(
  data : Bytes,
) -> (Array[Page], Array[Skipped], Bool) {
  let pages : Array[Page] = []
  let gaps : Array[Skipped] = []
  let budget = resync_budget(data.length())
  let mut spent : Int64 = 0L
  let mut offset = 0
  while offset < data.length() {
    // 已知可信位置：接受判据与严格解析完全一致（`Page::parse` 成功即收下），
    // CRC 是否相符由 verify 单独复核。预筛只用于候选筛选，绝不能当合法性
    // 判据 —— 否则 info（严格解析）接受的文件会在 verify（容错解析）里被
    // 当成垃圾拒绝，并连带触发全文件重同步（M-26）。
    let mut parsed = false
    match Page::parse(data, offset) {
      Some((page, next)) =>
        if next > offset {
          pages.push(page)
          offset = next
          parsed = true
        }
      None => ()
    }
    if parsed {
      continue
    }
    let (found, cost, over_budget) = find_resync_page(
      data,
      offset + 1,
      budget - spent,
    )
    spent = spent + cost
    match found {
      Some(start) =>
        if start > offset {
          gaps.push({ offset, bytes: start - offset, })
          offset = start
        } else {
          // 防御：候选必须严格前进，否则把剩余字节整体记为跳过并结束
          gaps.push({ offset, bytes: data.length() - offset, })
          offset = data.length()
        }
      None => {
        // 要么是真正的尾部残片，要么是伪页头洪水超出预算：都无法再同步，
        // 剩余字节整体记为一个跳过区间
        gaps.push({ offset, bytes: data.length() - offset, })
        offset = data.length()
      }
    }
    if over_budget {
      return (pages, gaps, true)
    }
  }
  (pages, gaps, false)
}

///|
/// 容错解析：撞到坏页时向前搜下一个能通过 CRC 复核的页，跳过中间的字节。
///
/// `parse_pages` 撞到第一个坏点就停 —— 一个坏字节等于丢掉它后面的整个文件。
/// 这在这里是有意的（`split` / `cat` 不该悄悄产出半截东西），但对诊断不够用：
/// 用户想知道「坏在哪、坏掉多少、后面还剩多少能救」。
///
/// 重同步的关键是**必须用 CRC 复核候选位置**：负载里出现字面量 "OggS" 完全正常，
/// 只搜魔数会把音频数据当成页首，越搜越歪（libogg 的 `ogg_sync_pageseek`
/// 也是这么做的）。代价是要给每个候选算一次 CRC，换来的是不会误判。
///
/// 候选 CRC 直接在原始字节上按页范围计算（零拷贝），并受确定性预算约束：
/// 累计 CRC 字节数超过 `8 × 输入长度 + 64 KiB` 时停止扫描，剩余字节记为
/// 跳过区间。因此本函数面对「稠密伪页头」输入也不会把 CPU 放大 ~1000×，
/// 但不会报错（旧签名无法返回 Err）。需要显式拒绝的调用方用
/// `parse_pages_lenient_checked`。
///
/// 返回（能解析出的页，被跳过的区间列表）。页按文件顺序排列，
/// 跳过的区间按偏移升序 —— 调用方可以据此判断「这只是结尾截断」还是
/// 「中间烂了一大段」。
pub fn parse_pages_lenient(data : Bytes) -> (Array[Page], Array[Skipped]) {
  let (pages, gaps, _over_budget) = parse_pages_lenient_core(data)
  (pages, gaps)
}

///|
/// 与 `parse_pages_lenient` 相同，但重同步的累计 CRC 计算量超过确定性预算
/// （`8 × 输入长度 + 64 KiB` 字节）时返回 `Err`，而不是继续扫描。
///
/// 适用场景：对不可信输入（CI 产物校验、上传扫描、批量巡检）做容错解析，
/// 需要把 CPU 上界写进契约。恶意构造的稠密伪页头（每 6 字节一个
/// `OggS\0\0`，实测 1 MiB ≈ 4 s、放大 ~1000×）会在这里被快速拒绝。
pub fn parse_pages_lenient_checked(
  data : Bytes,
) -> Result[(Array[Page], Array[Skipped]), String] {
  let (pages, gaps, over_budget) = parse_pages_lenient_core(data)
  if over_budget {
    return Err(
      "疑似伪页头洪水：重同步候选的 CRC 计算量超过预算（" +
      resync_budget(data.length()).to_string() +
      " 字节），已停止扫描",
    )
  }
  Ok((pages, gaps))
}

///|
/// 校验并序列化页序列；任一项不合法都返回 Err。
///
/// 写命令应优先用这个入口：合法的 `Page` 数组经 `serialize_pages` 会重新算 CRC，
/// 而非法段值会被静默截断。这里先逐页校验，再序列化。
pub fn serialize_pages_checked(pages : Array[Page]) -> Result[Bytes, String] {
  let mut i = 0
  while i < pages.length() {
    match validate_page(pages[i]) {
      Err(msg) => return Err("第 " + i.to_string() + " 页不合法：" + msg)
      Ok(_) => ()
    }
    i = i + 1
  }
  Ok(serialize_pages(pages))
}

///|
/// 把页序列拼接为字节流。
///
/// 每页在序列化时都会重新计算并写入自己的 CRC，
/// 因此这个函数产出的字节流总是自洽的。
pub fn serialize_pages(pages : Array[Page]) -> Bytes {
  // 预分配总长，并直接把每页写进同一个缓冲：
  // 旧写法每页先 to_bytes() 生成一份 Bytes 再整体复制，
  // 输出阶段因此多出一倍的分配与拷贝（156 MB 的文件实测峰值 593 MB）。
  let mut total = 0
  for page in pages {
    total = total + 27 + page.segments.length() + page.payload.length()
  }
  let buf = Buffer(size_hint=total)
  for page in pages {
    write_capture(buf)
    write_body(buf, page, page.expected_crc())
  }
  buf.to_bytes()
}
