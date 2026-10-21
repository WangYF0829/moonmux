// comment.mbt —— VorbisComment / OpusTags 的解析与编码
//
// 两种编码共用同一套载荷结构（Xiph 的 Vorbis comment）：
//
//   vendor_len(u32 LE) + vendor(UTF-8)
//   count(u32 LE)      + count × [ entry_len(u32 LE) + "NAME=value"(UTF-8) ]
//
// 差别只在包前缀与结尾：
//
//   Vorbis: 0x03 + "vorbis" …… 末尾一个 framing 字节（最低位必须为 1）
//   Opus:   "OpusTags"      …… 没有 framing 位
//
// **尾随零字节是允许的**（填充）。Vorbis 的写法是「注释数据 + 填充零」，
// 读端只检查 framing 字节的最低位、忽略其余；Opus 在 RFC 7845 §5.2 里
// 明确允许尾随填充。填充的价值在于：改标签时可以把新包补到与旧包等长，
// 页布局因此一个字节都不用挪。
//
// 长度字段一律在分配内存前校验：一个声称有 40 亿条注释的损坏包
// 不能把进程拖死（各语言的标签库在这上面出过真实的 OOM 缺陷）。

///|
/// 一条注释：键 + 值。
///
/// 键是大小写不敏感的 ASCII（可打印字符，不含 `=`），值可以是任意 UTF-8。
/// 同一个键可以出现多次（多值标签），因此用数组而不是映射保存 ——
/// 顺序与重复都是格式的一部分，用映射会丢掉它们。
pub(all) struct Tag {
  key : String
  value : String
}

///|
/// 一段流的注释内容。
pub(all) struct Comment {
  vendor : String
  tags : Array[Tag]
}

///|
/// 注释包的种类：决定前缀与是否有 framing 位。
pub(all) enum CommentKind {
  /// Ogg Opus（RFC 7845 §5.2）
  Opus
  /// Ogg Vorbis（Vorbis I §5.2）
  Vorbis
}

///|
/// 判断 `data` 从 `offset` 起是否等于给定的 ASCII 标记 ——
/// 与 `codec.mbt` 里的 `tag_at` 是同一个实现，同包共用。

///|
/// 小端读取 32 位无符号整数（越界或高位为 1 时返回 None）。
///
/// 32 位无符号读进有符号 Int 时，0x80000000 以上的值会变成负数。
/// 长度字段出现负数只可能来自损坏数据，直接拒绝。
fn read_len(data : Bytes, offset : Int32) -> Int32? {
  if offset < 0 || offset + 4 > data.length() {
    return None
  }
  let v = data[offset].to_int() |
    (data[offset + 1].to_int() << 8) |
    (data[offset + 2].to_int() << 16) |
    (data[offset + 3].to_int() << 24)
  if v < 0 {
    None
  } else {
    Some(v)
  }
}

///|
/// 取 `data[offset ..< offset+len]` 的副本。
fn slice_bytes(data : Bytes, offset : Int32, len : Int32) -> Bytes {
  let buf = Buffer()
  let mut i = 0
  while i < len {
    buf.write_byte(data[offset + i])
    i = i + 1
  }
  buf.to_bytes()
}

///|
/// 把小端 u32 写入缓冲。
fn write_u32(buf : Buffer, v : Int32) -> Unit {
  buf.write_byte((v % 256).to_byte())
  buf.write_byte((v / 256 % 256).to_byte())
  buf.write_byte((v / 65536 % 256).to_byte())
  buf.write_byte((v / 16777216 % 256).to_byte())
}

///|
/// 识别一个包是哪种注释头；都不是则 None。
pub fn comment_kind(packet : Bytes) -> CommentKind? {
  if tag_at(packet, 0, "OpusTags") {
    Some(CommentKind::Opus)
  } else if packet.length() >= 7 &&
    packet[0].to_int() == 0x03 &&
    tag_at(packet, 1, "vorbis") {
    Some(CommentKind::Vorbis)
  } else {
    None
  }
}

///|
/// 解析注释包（只解析第一个，不含尾随填充）。
///
/// 失败情形都写在返回的字符串里，便于命令行原样转述：
/// 前缀不符、长度字段越界、framing 位缺失。
pub fn parse_comment(packet : Bytes) -> Result[(CommentKind, Comment), String] {
  let kind = match comment_kind(packet) {
    Some(k) => k
    None => return Err("不是 VorbisComment / OpusTags 注释包")
  }
  let mut offset = match kind {
    CommentKind::Opus => 8
    CommentKind::Vorbis => 7
  }
  let vendor_len = match read_len(packet, offset) {
    Some(n) => n
    None => return Err("注释包的 vendor 长度字段越界")
  }
  offset = offset + 4
  if vendor_len > packet.length() - offset {
    return Err(
      "vendor 长度 " + vendor_len.to_string() + " 超出包内剩余字节",
    )
  }
  let vendor = @utf8.decode_lossy(slice_bytes(packet, offset, vendor_len))
  offset = offset + vendor_len
  let count = match read_len(packet, offset) {
    Some(n) => n
    None => return Err("注释包的条目计数字段越界")
  }
  offset = offset + 4
  // 每条至少 4 字节（长度字段）。先按这个下界挡掉「声称有几十亿条」的包，
  // 免得循环把内存吃光 —— 各语言标签库都在这上面出过真实的 OOM 缺陷。
  if count > (packet.length() - offset) / 4 {
    return Err(
      "条目计数 " +
      count.to_string() +
      " 与包内剩余字节不符（已拒绝）",
    )
  }
  let tags : Array[Tag] = []
  let mut i = 0
  while i < count {
    let len = match read_len(packet, offset) {
      Some(n) => n
      None =>
        return Err(
          "第 " + (i + 1).to_string() + " 条注释的长度字段越界",
        )
    }
    offset = offset + 4
    if len > packet.length() - offset {
      return Err(
        "第 " + (i + 1).to_string() + " 条注释超出包内剩余字节",
      )
    }
    let text = @utf8.decode_lossy(slice_bytes(packet, offset, len))
    offset = offset + len
    // "NAME=value"：按第一个 '=' 切分，值里可以有 '='
    match text.find("=") {
      Some(at) => {
        let key = text[0:at].to_owned()
        let value = text[at + 1:].to_owned()
        if key.length() > 0 {
          tags.push({ key, value, })
        }
      }
      None => () // 没有 '=' 的条目按规范无效，跳过而不是整包失败
    }
    i = i + 1
  }
  // Vorbis 的 framing 位：读一个字节，最低位必须为 1
  match kind {
    CommentKind::Vorbis => {
      if offset >= packet.length() {
        return Err("Vorbis 注释包缺少 framing 字节")
      }
      if (packet[offset].to_int() & 0x01) == 0 {
        return Err("Vorbis 注释包的 framing 位未置位")
      }
    }
    CommentKind::Opus => ()
  }
  Ok((kind, { vendor, tags, }))
}

///|
/// 编码注释包。
///
/// `padding` 是追加在包尾的零字节数 —— 用来把新包补到与旧包等长，
/// 使页布局无需移动（见 `replace_packet`）。
pub fn encode_comment(
  kind : CommentKind,
  comment : Comment,
  padding : Int32,
) -> Bytes {
  let buf = Buffer()
  match kind {
    CommentKind::Opus => buf.write_bytes(b"OpusTags".exact_view())
    CommentKind::Vorbis => {
      buf.write_byte((0x03 : Byte))
      buf.write_bytes(b"vorbis".exact_view())
    }
  }
  let vendor = @utf8.encode(comment.vendor)
  write_u32(buf, vendor.length())
  buf.write_bytes(vendor.exact_view())
  write_u32(buf, comment.tags.length())
  for t in comment.tags {
    let line = @utf8.encode(t.key + "=" + t.value)
    write_u32(buf, line.length())
    buf.write_bytes(line.exact_view())
  }
  match kind {
    // framing 字节：最低位置 1，其余位按规范清零
    CommentKind::Vorbis => buf.write_byte((0x01 : Byte))
    CommentKind::Opus => ()
  }
  let mut i = 0
  while i < padding {
    buf.write_byte((0x00 : Byte))
    i = i + 1
  }
  buf.to_bytes()
}

///|
/// ASCII 大小写不敏感的键比较。
fn key_eq(a : String, b : String) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut i = 0
  let mut same = true
  while i < a.length() {
    let x = match a.get_char(i) {
      Some(c) => c.to_int()
      None => -1
    }
    let y = match b.get_char(i) {
      Some(c) => c.to_int()
      None => -1
    }
    // 'A'..'Z' → 加 32 折成小写；其余原样比较
    let nx = if x >= 65 && x <= 90 { x + 32 } else { x }
    let ny = if y >= 65 && y <= 90 { y + 32 } else { y }
    if nx != ny {
      same = false
    }
    i = i + 1
  }
  same
}

///|
/// 键是否合法：可打印 ASCII（0x20–0x7D），不含 `=`，且非空。
pub fn valid_key(key : String) -> Bool {
  if key.length() == 0 {
    return false
  }
  let mut i = 0
  let mut ok = true
  while i < key.length() {
    match key.get_char(i) {
      Some(c) => {
        let v = c.to_int()
        if v < 0x20 || v > 0x7D || v == 0x3D {
          ok = false
        }
      }
      None => ok = false
    }
    i = i + 1
  }
  ok
}

///|
/// 取某个键的第一个值（大小写不敏感）。
pub fn get_tag(comment : Comment, key : String) -> String? {
  for t in comment.tags {
    if key_eq(t.key, key) {
      return Some(t.value)
    }
  }
  None
}

///|
/// 设置一个键：已有同名键则替换**第一个**的值并删掉其余重复项，
/// 没有则追加到末尾。
///
/// 替换第一个、删除其余，是标签编辑器的通行做法 ——
/// 多值标签（例如两个 ARTIST）在「设置单一值」的语义下应当收敛成一个。
pub fn set_tag(comment : Comment, key : String, value : String) -> Comment {
  let out : Array[Tag] = []
  let mut replaced = false
  for t in comment.tags {
    if key_eq(t.key, key) {
      if !replaced {
        out.push({ key: t.key, value, })
        replaced = true
      }
      // 其余同名项丢弃
    } else {
      out.push(t)
    }
  }
  if !replaced {
    out.push({ key, value, })
  }
  { vendor: comment.vendor, tags: out, }
}

///|
/// 删除某个键的全部条目（大小写不敏感）。
pub fn remove_tag(comment : Comment, key : String) -> Comment {
  let out : Array[Tag] = []
  for t in comment.tags {
    if !key_eq(t.key, key) {
      out.push(t)
    }
  }
  { vendor: comment.vendor, tags: out, }
}
