// manifest.mbt —— 流目录清单的解析与生成
//
// `demux` 会把每条逻辑流的原始流号、链序号、包数与逐包粒度写进
// `manifest.txt`，`mux` 再据此还原。这些字段决定往返是否保真，
// 所以解析逻辑必须能被单独测试 —— 它原先长在命令行入口里，
// 只能靠手工验证，是覆盖上的一个盲区。
//
// 清单是纯文本，人也可以读写：
//
//   # moonmux manifest v1
//   # granulepos
//   # serial=1647431420
//   # packets=303
//   # chain=1
//   0
//   -1
//   ...
//
// `#` 开头的是头信息，其余每行一个粒度，顺序与 `packet_NNNNNN.bin` 一一对应。
// 旧清单没有 `# packets=` / `# chain=`，按「未记录」处理，调用方退回旧行为。

///|
/// 一份流目录清单的内容。
pub(all) struct Manifest {
  /// 原文件的流号；旧清单没有则 None
  serial : UInt?
  /// 包数（用于校验目录是否被改动或复用）
  packets : Int?
  /// 该流所属的物理流（链）序号，1 起算；旧清单没有则 None
  chain : Int?
  /// 逐包粒度；-1 表示该包在原文件里不携带粒度
  granules : Array[Int64]
}

///|
/// 字符串是否以给定前缀开头（逐字符比对）。
pub fn starts_with(s : String, prefix : String) -> Bool {
  if s.length() < prefix.length() {
    return false
  }
  let mut i = 0
  let mut same = true
  while i < prefix.length() {
    match (s.get_char(i), prefix.get_char(i)) {
      (Some(a), Some(b)) =>
        if a.to_int() != b.to_int() {
          same = false
        }
      _ => same = false
    }
    i = i + 1
  }
  same
}

///|
/// 字符串是否以给定后缀结尾。
pub fn ends_with(s : String, suffix : String) -> Bool {
  if s.length() < suffix.length() {
    return false
  }
  let offset = s.length() - suffix.length()
  let mut i = 0
  let mut same = true
  while i < suffix.length() {
    match (s.get_char(offset + i), suffix.get_char(i)) {
      (Some(a), Some(b)) =>
        if a.to_int() != b.to_int() {
          same = false
        }
      _ => same = false
    }
    i = i + 1
  }
  same
}

///|
/// 把字符串按换行切成行（去掉空行由调用方决定）。
///
/// 用 StringBuilder 而不是 Buffer::write_char：后者写的是 UTF-16LE 字节，
/// 现在靠读写对称碰巧不出错，官方已把它标记为弃用并计划改成 UTF-8 语义。
fn split_lines(s : String) -> Array[String] {
  let out : Array[String] = []
  let buf = StringBuilder()
  let mut i = 0
  while i < s.length() {
    match s.get_char(i) {
      Some(ch) =>
        if ch.to_int() == 10 {
          out.push(buf.to_string())
          buf.reset()
        } else if ch.to_int() != 13 {
          // 手工编辑过的清单可能是 CRLF，CR 直接丢掉
          buf.write_char(ch)
        }
      None => ()
    }
    i = i + 1
  }
  if !buf.is_empty() {
    out.push(buf.to_string())
  }
  out
}

///|
/// 严格解析十进制整数：只允许一个可选负号加若干数字，且必须有数字。
///
/// 旧实现「跳过非数字继续拼」会把注释里的数字吃进来
/// （`# serial=123 # v2` → 1232），清单一旦被手工编辑就会静默错位。
/// 这里宁可报错也不猜。
fn parse_int_strict(s : String) -> Int64? {
  if s.length() == 0 {
    return None
  }
  let mut i = 0
  let mut neg = false
  match s.get_char(0) {
    Some(c) =>
      if c.to_int() == 45 {
        neg = true
        i = 1
      }
    None => return None
  }
  if i >= s.length() {
    return None
  }
  let mut v : Int64 = 0L
  while i < s.length() {
    match s.get_char(i) {
      Some(c) => {
        let d = c.to_int() - 48
        if d < 0 || d > 9 {
          return None
        }
        // 溢出检查：清单是外部输入，一个超大数字会让 v 回绕成负数，
        // 后面再被当成合法粒度写进页头。
        if v > (9223372036854775807L - d.to_int64()) / 10L {
          return None
        }
        v = v * 10L + d.to_int64()
      }
      None => return None
    }
    i = i + 1
  }
  Some(if neg { -v } else { v })
}

///|
/// 去掉首尾的 ASCII 空白（空格 / 制表符）。
fn trim_ascii(s : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end {
    match s.get_char(start) {
      Some(c) =>
        if c.to_int() == 32 || c.to_int() == 9 {
          start = start + 1
        } else {
          break
        }
      None => break
    }
  }
  while end > start {
    match s.get_char(end - 1) {
      Some(c) =>
        if c.to_int() == 32 || c.to_int() == 9 {
          end = end - 1
        } else {
          break
        }
      None => break
    }
  }
  s[start:end].to_owned()
}

///|
/// 解析一行头部：`# key=value`，允许键与等号两侧有空白。
///
/// 返回 `Ok(None)` 表示这行不是 `key=value` 形式（版本行、`# granulepos` 等注释）；
/// 返回 `Err` 表示它看起来是已知字段但格式不对 —— 这种情况必须报错：
/// 把 `# chain = 2` 当注释忽略，会把 chained 文件静默压成一条物理流。
fn parse_header(line : String) -> Result[(String, String)?, String] {
  let rest = trim_ascii(line[1:].to_owned())
  match rest.find("=") {
    None => {
      // 已知字段却没有等号（例如 "# chain 2"）→ 报错；其余当注释。
      // 只按「已知字段名 + 空白」判断，避免把 "# chainnote" 这类扩展字段误伤。
      let key = trim_ascii(rest)
      let mut known = false
      for name in ["serial", "packets", "chain"] {
        if key == name {
          known = true
        } else if starts_with(key, name) {
          match key.get_char(name.length()) {
            Some(c) =>
              if c.to_int() == 32 || c.to_int() == 9 {
                known = true
              }
            None => ()
          }
        }
      }
      if known {
        Err("清单头部缺少等号：" + line)
      } else {
        Ok(None)
      }
    }
    Some(at) => {
      let key = trim_ascii(rest[0:at].to_owned())
      let value = trim_ascii(rest[at + 1:].to_owned())
      if key == "serial" || key == "packets" || key == "chain" {
        Ok(Some((key, value)))
      } else {
        // 将来的扩展字段：当作注释忽略，不猜测语义
        Ok(None)
      }
    }
  }
}

///|
/// 解析清单文本。
///
/// 严格模式：头部字段与粒度行都必须是纯十进制整数，任何无法解析的行都报错。
/// 清单一旦被手工编辑过（加 BOM、改错一个字段），宽松解析会静默错位 ——
/// 而 mux 完全信任这份数据，错位的结果是「结构合法但时间轴错了」。
pub fn parse(text : String) -> Result[Manifest, String] {
  let granules : Array[Int64] = []
  let mut serial : UInt? = None
  let mut packets : Int? = None
  let mut chain : Int? = None
  // 去掉 UTF-8 BOM：Notepad 保存的清单第一行会带它，
  // 不去掉的话版本行不再以 '#' 开头，会被当成一条粒度。
  let body = if text.length() > 0 {
    match text.get_char(0) {
      Some(c) =>
        if c.to_int() == 0xFEFF {
          text[1:].to_owned()
        } else {
          text
        }
      None => text
    }
  } else {
    text
  }
  let mut has_version = false
  for line in split_lines(body) {
    if line.length() > 0 {
      match line.get_char(0) {
        Some(c) =>
          if c.to_int() == 35 {
            // 注释行：可能是头部字段，也可能是版本行
            if line.contains("moonmux manifest") {
              has_version = true
            }
            match parse_header(line) {
              Err(msg) => return Err(msg)
              Ok(Some(kv)) => {
                let key = kv.0
                let value = kv.1
                match parse_int_strict(value) {
                  None => return Err("清单的 " + key + " 不是十进制整数：" + line)
                  Some(v) => {
                    if key == "serial" {
                      if v < 0L {
                        return Err("清单的 serial 不能为负：" + line)
                      }
                      // 流号是 32 位字段：超出范围时 to_uint() 会静默截断，
                      // 用户只会看到「流号 1001 重复」这种莫名其妙的错误。
                      if v > 4294967295L {
                        return Err("清单的 serial 超出 32 位范围：" + line)
                      }
                      serial = Some(v.reinterpret_as_uint64().to_uint())
                    } else if key == "packets" {
                      if v < 0L {
                        return Err("清单的 packets 不能为负：" + line)
                      }
                      packets = Some(v.to_int())
                    } else if key == "chain" {
                      if v < 1L {
                        return Err("清单的 chain 必须是 ≥ 1 的整数：" + line)
                      }
                      chain = Some(v.to_int())
                    }
                  }
                }
              }
              Ok(None) => ()
            }
          } else {
            match parse_int_strict(line) {
              Some(v) => granules.push(v)
              None => return Err("清单里有无法解析的粒度行：" + line)
            }
          }
        None => ()
      }
    }
  }
  // 有版本行却没有任何粒度行：清单被截断（或只复制了头部）。
  // 静默当成「没有时间信息」会让 mux 写出所有粒度都是 0 的文件。
  if has_version && granules.length() == 0 {
    return Err("清单没有任何粒度行（文件可能被截断）")
  }
  Ok({ serial, packets, chain, granules })
}

///|
/// 生成清单文本。
///
/// `chain` 是 1 起算的物理流序号：chained 文件重封装时必须知道
/// 哪些流属于同一段，否则多段会被压成一条交织流（语义变了但结构仍合法）。
pub fn render(
  serial : UInt,
  chain : Int,
  granules : Array[Int64],
) -> String {
  // 逐行字符串拼接是 O(n²)：10 万个包会产生约 10 万次整串复制。
  // 用 StringBuilder 预分配（每行最多 21 字节："-" + 19 位数字 + 换行）。
  let sb = StringBuilder(size_hint=64 + granules.length() * 21)
  push_str(sb, "# moonmux manifest v1\n# granulepos\n# serial=")
  push_str(sb, serial.to_string())
  push_str(sb, "\n# packets=")
  push_str(sb, granules.length().to_string())
  push_str(sb, "\n# chain=")
  push_str(sb, chain.to_string())
  push_str(sb, "\n")
  for g in granules {
    push_str(sb, g.to_string())
    push_str(sb, "\n")
  }
  sb.to_string()
}

///|
/// 把字符串追加到 StringBuilder。
fn push_str(sb : StringBuilder, s : String) -> Unit {
  sb.write_stringview(s[:])
}

///|
/// 取第 `i` 个粒度；清单比包数短时返回 0（与新增清单之前的行为一致）。
pub fn granule_at(granules : Array[Int64], i : Int) -> Int64 {
  if i >= 0 && i < granules.length() {
    granules[i]
  } else {
    0L
  }
}

///|
/// 校验清单声明的包数与目录里实际的包数是否一致。
///
/// 不一致通常意味着目录被改动过、或复用给了另一个文件 ——
/// 后者会静默产出内容错误但结构合法的文件，容器层查不出来，
/// 所以必须在封装前挡住。
pub fn check_count(
  manifest : Manifest,
  actual : Int,
  label : String,
) -> Result[Unit, String] {
  let rows = manifest.granules.length()
  // 粒度行比包还多，只可能是清单与目录对不上（或曾被别的文件覆盖过）
  if rows > actual {
    return Err(
      label +
      " 的清单有 " +
      rows.to_string() +
      " 行粒度，目录里只有 " +
      actual.to_string() +
      " 个包",
    )
  }
  match manifest.packets {
    Some(n) =>
      if n != actual {
        Err(
          label +
          " 的清单声明 " +
          n.to_string() +
          " 个包，实际有 " +
          actual.to_string() +
          " 个 —— 目录可能被改动过或复用了",
        )
      } else if rows != n {
        Err(
          label +
          " 的清单声明 " +
          n.to_string() +
          " 个包，但只写了 " +
          rows.to_string() +
          " 行粒度",
        )
      } else {
        Ok(())
      }
    None => Ok(())
  }
}
