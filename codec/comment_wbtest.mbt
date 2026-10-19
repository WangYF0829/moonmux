// comment_wbtest.mbt —— VorbisComment / OpusTags 解析与编码的测试

///|
/// 小端写 u32（测试里自己拼包用）。
fn put_u32(buf : Buffer, v : Int) -> Unit {
  buf.write_byte((v % 256).to_byte())
  buf.write_byte(((v / 256) % 256).to_byte())
  buf.write_byte(((v / 65536) % 256).to_byte())
  buf.write_byte(((v / 16777216) % 256).to_byte())
}

///|
/// 手工拼一个注释包：前缀 + vendor + 条目 +（可选）framing 字节 + 尾巴。
fn packet_of(
  prefix : Bytes,
  vendor : String,
  entries : Array[String],
  framing : Bool,
  tail : Bytes,
) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(prefix.exact_view())
  let v = @utf8.encode(vendor)
  put_u32(buf, v.length())
  buf.write_bytes(v.exact_view())
  put_u32(buf, entries.length())
  for e in entries {
    let b = @utf8.encode(e)
    put_u32(buf, b.length())
    buf.write_bytes(b.exact_view())
  }
  if framing {
    buf.write_byte((0x01 : Byte))
  }
  buf.write_bytes(tail.exact_view())
  buf.to_bytes()
}

///|
/// OpusTags 包能被解析出 vendor 与全部条目。
test "parse an opus tags packet" {
  let pkt = packet_of(
    b"OpusTags",
    "moonmux test",
    ["TITLE=Hello", "ARTIST=Someone"],
    false,
    b"",
  )
  match parse_comment(pkt) {
    Err(_) => assert_true(false)
    Ok(parsed) => {
      match parsed.0 {
        CommentKind::Opus => assert_true(true)
        _ => assert_true(false)
      }
      assert_eq(parsed.1.vendor, "moonmux test")
      assert_eq(parsed.1.tags.length(), 2)
      assert_eq(parsed.1.tags[0].key, "TITLE")
      assert_eq(parsed.1.tags[0].value, "Hello")
      assert_eq(parsed.1.tags[1].key, "ARTIST")
    }
  }
}

///|
/// Vorbis 注释包同理，且 framing 位必须被校验。
test "parse a vorbis comment packet and check the framing bit" {
  let pkt = packet_of(b"\x03vorbis", "v", ["TITLE=Hi"], true, b"")
  match parse_comment(pkt) {
    Ok(parsed) => {
      match parsed.0 {
        CommentKind::Vorbis => assert_true(true)
        _ => assert_true(false)
      }
      assert_eq(parsed.1.tags.length(), 1)
    }
    Err(_) => assert_true(false)
  }
  // framing 位没置位 → 必须拒绝（规范说这样的流不可解码）
  let bad = packet_of(b"\x03vorbis", "v", ["TITLE=Hi"], false, b"")
  match parse_comment(bad) {
    Err(msg) => assert_true(msg.contains("framing"))
    _ => assert_true(false)
  }
}

///|
/// 尾随填充零应当被忽略 —— 这正是「把新包补到与旧包等长」所依赖的性质。
test "trailing padding is ignored" {
  let padded = packet_of(
    b"OpusTags",
    "v",
    ["TITLE=A"],
    false,
    b"\x00\x00\x00\x00\x00\x00\x00\x00",
  )
  match parse_comment(padded) {
    Ok(parsed) => assert_eq(parsed.1.tags.length(), 1)
    Err(_) => assert_true(false)
  }
}

///|
/// 声称有几十亿条注释的包必须在分配内存前被拒 —— 长度字段的 DoS 防护。
test "absurd entry count is rejected" {
  let buf = Buffer()
  buf.write_bytes(b"OpusTags".exact_view())
  put_u32(buf, 0) // vendor 为空
  put_u32(buf, 0x7FFFFFFF) // 21 亿条
  match parse_comment(buf.to_bytes()) {
    Err(msg) => assert_true(msg.contains("条目计数"))
    _ => assert_true(false)
  }
}

///|
/// vendor 长度越界、条目长度越界都要报错，而不是读出垃圾。
test "out of bounds length fields are rejected" {
  let buf = Buffer()
  buf.write_bytes(b"OpusTags".exact_view())
  put_u32(buf, 9999) // vendor 声称 9999 字节，包里没有
  match parse_comment(buf.to_bytes()) {
    Err(_) => assert_true(true)
    _ => assert_true(false)
  }
  let buf2 = Buffer()
  buf2.write_bytes(b"OpusTags".exact_view())
  put_u32(buf2, 0)
  put_u32(buf2, 1)
  put_u32(buf2, 9999) // 条目声称 9999 字节
  match parse_comment(buf2.to_bytes()) {
    Err(_) => assert_true(true)
    _ => assert_true(false)
  }
}

///|
/// 编码 → 解析应当还原出同样的内容（含非 ASCII 值）。
test "encode then parse roundtrips" {
  let c : Comment = {
    vendor: "moonmux",
    tags: [
      { key: "TITLE", value: "标题" },
      { key: "ARTIST", value: "A=B" }, // 值里带 '='
    ],
  }
  for kind in [CommentKind::Opus, CommentKind::Vorbis] {
    let pkt = encode_comment(kind, c, 0)
    match parse_comment(pkt) {
      Err(_) => assert_true(false)
      Ok(parsed) => {
        assert_eq(parsed.1.vendor, "moonmux")
        assert_eq(parsed.1.tags.length(), 2)
        assert_eq(parsed.1.tags[0].value, "标题")
        // 值里的 '=' 不能被当作分隔符
        assert_eq(parsed.1.tags[1].value, "A=B")
      }
    }
  }
}

///|
/// 填充只是在包尾加零，解析结果与无填充时一致。
test "padding does not change parsed content" {
  let c : Comment = { vendor: "v", tags: [{ key: "A", value: "1" }] }
  let plain = encode_comment(CommentKind::Opus, c, 0)
  let padded = encode_comment(CommentKind::Opus, c, 64)
  assert_eq(padded.length(), plain.length() + 64)
  match (parse_comment(plain), parse_comment(padded)) {
    (Ok((_, a)), Ok((_, b))) => {
      assert_eq(a.tags.length(), b.tags.length())
      assert_eq(a.tags[0].value, b.tags[0].value)
    }
    _ => assert_true(false)
  }
}

///|
/// 设置键：大小写不敏感地替换第一个、丢弃其余重复项。
test "set_tag replaces case-insensitively and collapses duplicates" {
  let c : Comment = {
    vendor: "v",
    tags: [
      { key: "ARTIST", value: "first" },
      { key: "TITLE", value: "t" },
      { key: "artist", value: "second" },
    ],
  }
  let updated = set_tag(c, "Artist", "new")
  assert_eq(updated.tags.length(), 2)
  assert_eq(updated.tags[0].key, "ARTIST")
  assert_eq(updated.tags[0].value, "new")
  assert_eq(updated.tags[1].key, "TITLE")
  // 原注释不被修改
  assert_eq(c.tags.length(), 3)
}

///|
/// 设置不存在的键 → 追加到末尾。
test "set_tag appends a new key" {
  let c : Comment = { vendor: "v", tags: [{ key: "A", value: "1" }] }
  let updated = set_tag(c, "B", "2")
  assert_eq(updated.tags.length(), 2)
  assert_eq(updated.tags[1].key, "B")
  assert_eq(updated.tags[1].value, "2")
}

///|
/// 删除键：大小写不敏感，删掉全部同名项。
test "remove_tag drops every matching key" {
  let c : Comment = {
    vendor: "v",
    tags: [
      { key: "ARTIST", value: "a" },
      { key: "TITLE", value: "t" },
      { key: "artist", value: "b" },
    ],
  }
  let updated = remove_tag(c, "Artist")
  assert_eq(updated.tags.length(), 1)
  assert_eq(updated.tags[0].key, "TITLE")
}

///|
/// 键的合法性：可打印 ASCII、不含 '='、非空。
test "key validation" {
  assert_true(valid_key("ARTIST"))
  assert_true(valid_key("MUSICBRAINZ_TRACKID"))
  assert_true(!valid_key(""))
  assert_true(!valid_key("A B=C"))
  assert_true(!valid_key("A=B"))
  assert_true(!valid_key("键"))
}

///|
/// `get_tag` 大小写不敏感。
test "get_tag ignores case" {
  let c : Comment = { vendor: "v", tags: [{ key: "TITLE", value: "x" }] }
  match get_tag(c, "title") {
    Some(v) => assert_eq(v, "x")
    None => assert_true(false)
  }
  match get_tag(c, "MISSING") {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
}
