// verify.mbt —— 页序列的结构体检
//
// CRC 只能发现「字节坏了」，发现不了「页放错了」：
// 页序号跳号意味着这条流在中间丢过页，读取端无法自行定位；
// 缺 BOS 意味着头部包不在，解码器无法初始化；
// 缺 EOS 意味着文件在末尾被截断。
// 这些文件 CRC 可以照样全绿，播放到相应位置才出问题 ——
// 越晚发现，越难归因。
//
// CRC 本身由 `page_crc_ok` 单独承担（见 crc.mbt）；
// 本模块只管结构：段表一致性、页序号连续性、BOS / EOS。

///|
/// 对一列页做结构体检，逐条给出问题描述；空数组表示结构完好。
///
/// 检查项：
/// - **段表一致性**：段表各项之和必须等于负载长度
///   （`Page::parse` 产出的页天然满足，此项防的是手工构造的页）
/// - **页序号**：每条逻辑流的页序号从 0 开始、逐页只前进 1
///   —— 跳号说明这条流中间丢过页；页序号是容器层唯一能暴露丢页的字段。
///   按相邻页的**跳变**判定，一次丢失只报一处断点
/// - **BOS / EOS**：每条逻辑流的第一页带 BOS、最后一页带 EOS
pub fn structure_problems(pages : Array[Page]) -> Array[String] {
  let problems : Array[String] = []
  // 按流分组（保持首次出现顺序），记录各流页下标
  let serials : Array[UInt] = []
  let members : Array[Array[Int]] = []
  let mut i = 0
  while i < pages.length() {
    let page = pages[i]
    // 段表一致性
    let mut declared = 0
    for seg in page.segments {
      declared = declared + seg
    }
    if declared != page.payload.length() {
      problems.push(
        "serial=" +
        page.serial.to_string() +
        " sequence=" +
        page.sequence.to_string() +
        " 段表声明 " +
        declared.to_string() +
        " 字节，实际负载 " +
        page.payload.length().to_string() +
        " 字节",
      )
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
  // 每条流：页序号连续性 + BOS / EOS
  let mut t = 0
  while t < serials.length() {
    let group = members[t]
    // 首页必须是该流自己的第 0 页
    let first = pages[group[0]]
    if first.sequence != 0U {
      problems.push(
        "serial=" +
        serials[t].to_string() +
        " 首页页序号是 " +
        first.sequence.to_string() +
        "（应为 0，流的开头可能丢失）",
      )
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
        problems.push(
          "serial=" +
          serials[t].to_string() +
          " 页序号从 " +
          prev.to_string() +
          " 跳到 " +
          cur.to_string() +
          "（中间丢了 " +
          (cur - prev - 1U).to_string() +
          " 页）",
        )
      } else if cur < prev + 1U {
        problems.push(
          "serial=" +
          serials[t].to_string() +
          " 页序号从 " +
          prev.to_string() +
          " 回退到 " +
          cur.to_string() +
          "（可能重复或乱序）",
        )
      }
      k = k + 1
    }
    if (first.header_type.to_int() & flag_bos().to_int()) == 0 {
      problems.push(
        "serial=" +
        serials[t].to_string() +
        " 首页缺 BOS 标志（头部包可能丢失）",
      )
    }
    let last = pages[group[group.length() - 1]]
    if (last.header_type.to_int() & flag_eos().to_int()) == 0 {
      problems.push(
        "serial=" +
        serials[t].to_string() +
        " 末页缺 EOS 标志（文件可能被截断）",
      )
    }
    t = t + 1
  }
  problems
}
