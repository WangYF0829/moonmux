// dump.mbt —— 页级结构的文本转储
//
// `info` 给的是汇总（有几条流、多少页、多少包），`verify` 给的是结论
// （哪一页坏了、哪条流丢了页）。两者之间缺一层：**页本身长什么样**。
// `verify` 报「serial=2 页序号从 202 跳到 204」时，用户接下来要做的就是
// 把 200 号附近的页摊开看 —— 这个模块产出的就是那张表。
//
// 这里只做排版，不碰 I/O：输入页序列，输出若干行文本。
// 排版放在容器层而不是命令行入口，是为了让它能被断言钉住 ——
// 一列数值对不上齐、偏移算错一位，都是肉眼容易放过、却会让整张表失真的错。

///|
/// 估算字符串在等宽终端里占几列：CJK 字符占两列，其余占一列。
///
/// 不能直接用 `String::length()` 当宽度 —— 那是 UTF-16 码元数，
/// 一个汉字算 1，但显示出来占 2 列。表头全是中文标签，
/// 按 1 列算会让整行表头相对数字列整体偏左，一眼就看得出错位。
fn display_width(s : String) -> Int {
  let mut width = 0
  let mut i = 0
  while i < s.length() {
    match s.get_char(i) {
      Some(c) => {
        let code = c.to_int()
        let wide = (code >= 0x1100 && code <= 0x115F) ||
          (code >= 0x2E80 && code <= 0xA4CF) ||
          (code >= 0xAC00 && code <= 0xD7A3) ||
          (code >= 0xF900 && code <= 0xFAFF) ||
          (code >= 0xFE30 && code <= 0xFE6F) ||
          (code >= 0xFF00 && code <= 0xFF60) ||
          (code >= 0xFFE0 && code <= 0xFFE6)
        if wide {
          width = width + 2
        } else {
          width = width + 1
        }
      }
      None => ()
    }
    i = i + 1
  }
  width
}

///|
/// 字符串右侧补空格到占满 `width` 列（已够宽则原样返回，不截断）。
fn pad_right(s : String, width : Int) -> String {
  let mut out = s
  let mut i = display_width(s)
  while i < width {
    out = out + " "
    i = i + 1
  }
  out
}

///|
/// 字符串左侧补空格到占满 `width` 列。
///
/// 数字列左补、文本列右补，这样按列扫读时数位能对齐。
fn pad_left(s : String, width : Int) -> String {
  let mut out = ""
  let mut i = display_width(s)
  while i < width {
    out = out + " "
    i = i + 1
  }
  out + s
}

///|
/// 一个页头标志的简短写法：`cont` / `BOS` / `EOS` 用 `+` 连接，都没有则 `-`。
///
/// 写成文字而不是 0x02 这样的位掩码：看表的人不该为了读一行输出去查 RFC。
fn flags_text(header_type : Byte) -> String {
  let parts : Array[String] = []
  if (header_type.to_int() & flag_continued().to_int()) != 0 {
    parts.push("cont")
  }
  if (header_type.to_int() & flag_bos().to_int()) != 0 {
    parts.push("BOS")
  }
  if (header_type.to_int() & flag_eos().to_int()) != 0 {
    parts.push("EOS")
  }
  if parts.length() == 0 {
    "-"
  } else {
    parts.join("+")
  }
}

///|
/// 每一页在文件中的起始字节偏移。
///
/// 页长 = 27（固定头）+ 段表长度 + 负载长度，与 `Page::to_bytes` 写出的
/// 长度一致。偏移单独成一个函数而不是埋在排版里：它是可以直接拿去和
/// 真实文件对照的数值（用十六进制编辑器核对损坏位置时正需要），
/// 而排版里的数字没法被断言。
pub fn page_offsets(pages : Array[Page]) -> Array[Int] {
  let offsets : Array[Int] = []
  let mut offset = 0
  for page in pages {
    offsets.push(offset)
    offset = offset + 27 + page.segments.length() + page.payload.length()
  }
  offsets
}

///|
/// 页级表的列标题行。
///
/// 每一列的宽度常量与 `describe_pages` 里的一一对应 —— 表头与数据必须
/// 用同一套宽度，否则改一处就错位；表头错位的表格比没有表头更难看。
pub fn page_table_header() -> String {
  pad_left("#", 5) +
  pad_left("偏移", 11) +
  pad_left("流号", 12) +
  pad_left("页序", 6) +
  pad_left("粒度", 14) +
  "  " +
  pad_left("标志", 14) +
  pad_left("段数", 5) +
  pad_left("负载", 8)
}

///|
/// 把一列页转成表格的各数据行。
///
/// 每行给出：页在页序列中的下标、该页在文件中的字节偏移、流号、页序号、
/// 粒度位置、头标志、段数与负载字节数。
///
/// 一份汇总（`info`）看不出页与页的差异，一份结论（`verify`）只说哪一页坏了 ——
/// 这张表补的是两者中间的那层：坏点周围到底摆了哪些页。
pub fn describe_pages(pages : Array[Page]) -> Array[String] {
  let lines : Array[String] = []
  let offsets = page_offsets(pages)
  let mut i = 0
  while i < pages.length() {
    let page = pages[i]
    lines.push(
      pad_left(i.to_string(), 5) +
      pad_left(offsets[i].to_string(), 11) +
      pad_left(page.serial.to_string(), 12) +
      pad_left(page.sequence.to_string(), 6) +
      pad_left(page.granule_position.to_string(), 14) +
      "  " +
      pad_right(flags_text(page.header_type), 14) +
      pad_left(page.segments.length().to_string(), 5) +
      pad_left(page.payload.length().to_string(), 8),
    )
    i = i + 1
  }
  lines
}
