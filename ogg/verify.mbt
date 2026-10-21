// verify.mbt —— 页序列的结构体检
//
// CRC 只能发现「字节坏了」，发现不了「页放错了」：
// 页序号跳号意味着这条流在中间丢过页，读取端无法自行定位；
// 缺 BOS 意味着头部包不在，解码器无法初始化；
// 缺 EOS 意味着文件在末尾被截断。
// 这些文件 CRC 可以照样全绿，播放到相应位置才出问题 ——
// 越晚发现，越难归因。
//
// 检查项对齐 oggz-validate 里能在纯容器层判定、且不依赖编解码知识的部分：
// 段表一致性、页序号、BOS / EOS、granule 单调性、
// 「没有包结束的页粒度必须是 -1」、EOS 之后不应再有页。
//
// 结论分两级：**error** 是明确违规（读端会出错），
// **warn** 是需要人看一眼的可疑形态（可能是截断，也可能是直播流的正常收尾）。
// 退出码只看 error：CI 里不该因为一条「末页缺 EOS」就红掉整个构建，
// 但缺 BOS 这种直接不可解码的必须红。

///|
/// 一条体检结论的严重程度。
pub(all) enum Severity {
  /// 提示（当前检查项不产生这一级，保留给将来的统计类信息）
  Info
  /// 可疑，但不一定影响播放：截断、缺 EOS、粒度异常
  Warning
  /// 明确违规：读端会出错
  Error
}

///|
/// 一条体检结论。
pub(all) struct Finding {
  severity : Severity
  message : String
}

///|
/// 严重程度的文字标记（命令行直接用）。
pub fn severity_label(s : Severity) -> String {
  match s {
    Severity::Info => "info"
    Severity::Warning => "warn"
    Severity::Error => "error"
  }
}

///|
/// 一页有没有包在本页结束（段表里有 < 255 的段）。
fn has_completion(page : Page) -> Bool {
  let mut yes = false
  for seg in page.segments {
    if seg < 255 {
      yes = true
    }
  }
  yes
}

///|
/// 对一列页做结构体检，逐条给出带严重程度的问题；空数组表示全部通过。
///
/// 先按物理流（链）分段再按 serial 分组：chained 文件的两段是彼此独立的
/// 逻辑流集合，**即使两段复用同一个 serial 也不该合并统计** ——
/// 合并会让页序号看起来"从 1 退回 0"、出现两个 EOS，全是假阳性。
pub fn structure_findings(pages : Array[Page]) -> Array[Finding] {
  let findings : Array[Finding] = []
  let chains = split_chains(pages)
  // 跨段流号重复是硬错误（RFC 3533 §4：同一物理流内必须全局唯一）。
  // 读取端会把两段当成同一条流，页序号与包都错乱。
  let seen : Array[UInt32] = []
  for chain in chains {
    for s in serials_of(chain) {
      if has_serial(seen, s) {
        findings.push({
          severity: Severity::Error,
          message: "serial=" +
          s.to_string() +
          " 在多段物理流中重复（RFC 3533 §4 要求全局唯一）",
        })
      } else {
        seen.push(s)
      }
    }
  }
  for chain in chains {
    chain_findings(chain, findings)
  }
  findings
}

///|
/// 单段（一条物理流）内的检查；结果追加到 `findings`。
fn chain_findings(pages : Array[Page], findings : Array[Finding]) -> Unit {
  // 按流分组（保持首次出现顺序），记录各流页下标
  let serials : Array[UInt32] = []
  let members : Array[Array[Int32]] = []
  let mut i = 0
  while i < pages.length() {
    let page = pages[i]
    // 段表一致性
    let mut declared = 0
    for seg in page.segments {
      declared = declared + seg
    }
    if declared != page.payload.length() {
      findings.push({
        severity: Severity::Error,
        message: "serial=" +
        page.serial.to_string() +
        " sequence=" +
        page.sequence.to_string() +
        " 段表声明 " +
        declared.to_string() +
        " 字节，实际负载 " +
        page.payload.length().to_string() +
        " 字节",
      })
    }
    // 粒度与「本页有没有包结束」必须一致（RFC 3533：-1 表示本页没有包结束）
    let completes = has_completion(page)
    if completes && page.granule_position < 0L {
      findings.push({
        severity: Severity::Warning,
        message: "serial=" +
        page.serial.to_string() +
        " sequence=" +
        page.sequence.to_string() +
        " 本页有包结束，粒度却是 -1（应为完成样本数）",
      })
    }
    // nil EOS 页是合法的（RFC 3533 §4）：没有内容、只有页头，
    // 却可以带 position 信息。别把它当成「粒度写错了」。
    let nil_eos = !completes &&
      page.segments.length() == 0 &&
      (page.header_type.to_int() & flag_eos().to_int()) != 0
    if !completes && page.granule_position >= 0L && !nil_eos {
      findings.push({
        severity: Severity::Warning,
        message: "serial=" +
        page.serial.to_string() +
        " sequence=" +
        page.sequence.to_string() +
        " 本页没有包结束，粒度却是 " +
        page.granule_position.to_string() +
        "（应为 -1）",
      })
    }
    let mut idx = -1
    let mut j = 0
    while j < serials.length() {
      if serials[j] == page.serial {
        idx = j
      }
      j = j + 1
    }
    if idx < 0 {
      serials.push(page.serial)
      members.push([i])
    } else {
      members[idx].push(i)
    }
    i = i + 1
  }
  // BOS 页必须全部排在本段的非 BOS 页之前（RFC 3533 §4）。
  // 第二个流的头包如果落在数据页之后，标准解码器在解第一条数据时
  // 还没看到它的头 —— 这类文件结构自洽但播不了。
  let mut first_data = -1
  let mut bi = 0
  while bi < pages.length() {
    if !is_bos(pages[bi]) {
      first_data = bi
      break
    }
    bi = bi + 1
  }
  if first_data >= 0 {
    let mut li = first_data + 1
    while li < pages.length() {
      if is_bos(pages[li]) {
        findings.push({
          severity: Severity::Error,
          message: "serial=" +
          pages[li].serial.to_string() +
          " 的 BOS 页出现在数据页之后（所有 BOS 必须排在最前）",
        })
      }
      li = li + 1
    }
  }
  // 逐条流检查
  let mut t = 0
  while t < serials.length() {
    let sid = serials[t].to_string()
    let group = members[t]
    let first = pages[group[0]]
    // 首页必须是该流自己的第 0 页
    if first.sequence != 0U {
      findings.push({
        severity: Severity::Warning,
        message: "serial=" +
        sid +
        " 首页页序号是 " +
        first.sequence.to_string() +
        "（应为 0，流的开头可能丢失）",
      })
    }
    // 逐页比对：页序号每次只能前进 1，多出来的是丢页、退回去的是重复
    //
    // 按**跳变**判定而不是按位置对账：中间丢一页会让后面所有页整体前移一位，
    // 按位置对账会为每一页都报一次 —— 丢 1 页报出 99 条近乎重复的信息，
    // 真正有用的那一处（断点在哪）反而被埋掉。
    let mut k = 1
    while k < group.length() {
      let prev = pages[group[k - 1]].sequence
      let cur = pages[group[k]].sequence
      if cur > prev + 1U {
        findings.push({
          severity: Severity::Error,
          message: "serial=" +
          sid +
          " 页序号从 " +
          prev.to_string() +
          " 跳到 " +
          cur.to_string() +
          "（中间丢了 " +
          (cur - prev - 1U).to_string() +
          " 页）",
        })
      } else if cur < prev + 1U {
        findings.push({
          severity: Severity::Error,
          message: "serial=" +
          sid +
          " 页序号从 " +
          prev.to_string() +
          " 回退到 " +
          cur.to_string() +
          "（可能重复或乱序）",
        })
      }
      k = k + 1
    }
    // BOS / EOS 计数与位置
    let mut bos_count = 0
    let mut eos_count = 0
    let mut eos_at = -1
    let mut m = 0
    while m < group.length() {
      let pg = pages[group[m]]
      if (pg.header_type.to_int() & flag_bos().to_int()) != 0 {
        bos_count = bos_count + 1
      }
      if (pg.header_type.to_int() & flag_eos().to_int()) != 0 {
        eos_count = eos_count + 1
        if eos_at < 0 {
          eos_at = m
        }
      }
      m = m + 1
    }
    if (first.header_type.to_int() & flag_bos().to_int()) == 0 {
      findings.push({
        severity: Severity::Error,
        message: "serial=" +
        sid +
        " 首页缺 BOS 标志（头部包可能丢失）",
      })
    }
    if bos_count > 1 {
      findings.push({
        severity: Severity::Error,
        message: "serial=" +
        sid +
        " 出现 " +
        bos_count.to_string() +
        " 个 BOS 页（一条流只应有一个开头）",
      })
    }
    if eos_count > 1 {
      findings.push({
        severity: Severity::Error,
        message: "serial=" +
        sid +
        " 出现 " +
        eos_count.to_string() +
        " 个 EOS 页（一条流只应有一个结尾）",
      })
    }
    let last = pages[group[group.length() - 1]]
    if (last.header_type.to_int() & flag_eos().to_int()) == 0 {
      findings.push({
        severity: Severity::Warning,
        message: "serial=" +
        sid +
        " 末页缺 EOS 标志（文件可能被截断）",
      })
    }
    // EOS 之后不该再有这一流的页
    if eos_at >= 0 && eos_at < group.length() - 1 {
      findings.push({
        severity: Severity::Error,
        message: "serial=" +
        sid +
        " EOS 之后还有 " +
        (group.length() - 1 - eos_at).to_string() +
        " 页（流已经结束）",
      })
      let eos_page = pages[group[eos_at]]
      if !has_completion(eos_page) {
        findings.push({
          severity: Severity::Warning,
          message: "serial=" + sid + " EOS 页上没有包结束",
        })
      }
    }
    // granule 单调性：非 -1 的粒度只应不减
    let mut prev_granule : Int64 = -1L
    let mut has_prev = false
    let mut g = 0
    while g < group.length() {
      let granule = pages[group[g]].granule_position
      if granule >= 0L {
        if has_prev && granule < prev_granule {
          findings.push({
            severity: Severity::Error,
            message: "serial=" +
            sid +
            " 粒度回退：" +
            prev_granule.to_string() +
            " → " +
            granule.to_string() +
            "（时间倒流）",
          })
        }
        prev_granule = granule
        has_prev = true
      }
      g = g + 1
    }
    t = t + 1
  }
}

///|
/// 兼容入口：只返回需要人处理（warn / error）的结论文本。
///
/// 保持这个签名是因为它已经被大量测试与调用方使用；
/// 需要严重程度时用 `structure_findings`。
pub fn structure_problems(pages : Array[Page]) -> Array[String] {
  let out : Array[String] = []
  for f in structure_findings(pages) {
    match f.severity {
      Severity::Info => ()
      _ => out.push(f.message)
    }
  }
  out
}
