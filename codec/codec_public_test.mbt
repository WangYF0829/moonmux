// codec_public_test.mbt —— 黑盒测试：只用 codec 包发布出来的公开 API。
//
// 与 *_wbtest.mbt 的白盒测试互补：这里不访问任何私有符号。

///|
/// 合法 OpusHead（RFC 7845 §5.1）：
/// magic + version=1 + channels=2 + pre_skip=312 + input_rate=48000 + gain=0 + mapping=0。
fn valid_opus_head() -> Bytes {
  b"OpusHead\x01\x02\x38\x01\x80\xbb\x00\x00\x00\x00\x00"
}

///|
/// TOC 时长查询的 Option 包装（Result 不实现通用的相等比较）。
fn toc_samples(packet : Bytes) -> Int32? {
  match @codec.opus_packet_samples(packet) {
    Ok(n) => Some(n)
    Err(_) => None
  }
}

///|
test "public api: OpusHead parsing and rejection" {
  let head = valid_opus_head()
  assert_eq(head.length(), 19)
  match @codec.parse_opus_head(head) {
    None => assert_true(false)
    Some(info) => {
      assert_eq(info.codec, "Opus")
      assert_eq(info.channels, 2)
      assert_eq(info.sample_rate, 48000)
      assert_eq(info.pre_skip, 312)
    }
  }
  match @codec.parse_audio_header(head) {
    Some(info) => assert_eq(info.codec, "Opus")
    None => assert_true(false)
  }
  assert_true(@codec.parse_opus_head(b"") is None)
  // 魔数不符
  assert_true(@codec.parse_opus_head(b"NotAnOpusHeader!!!!") is None)
  // 版本必须为 1
  assert_true(
    @codec.parse_opus_head(
      b"OpusHead\x02\x02\x38\x01\x80\xbb\x00\x00\x00\x00\x00",
    )
    is None,
  )
  // 声道数不能为 0
  assert_true(
    @codec.parse_opus_head(
      b"OpusHead\x01\x00\x38\x01\x80\xbb\x00\x00\x00\x00\x00",
    )
    is None,
  )
}

///|
test "public api: OpusTags / VorbisComment roundtrip and tag editing" {
  let comment : @codec.Comment = {
    vendor: "moonmux",
    tags: [{ key: "TITLE", value: "标题", }],
  }
  let packet = @codec.encode_comment(@codec.CommentKind::Opus, comment, 0)
  match @codec.parse_comment(packet) {
    Err(msg) => abort("OpusTags 往返失败: " + msg)
    Ok((kind, parsed)) => {
      match kind {
        @codec.CommentKind::Opus => assert_true(true)
        @codec.CommentKind::Vorbis => assert_true(false)
      }
      assert_eq(parsed.vendor, "moonmux")
      assert_eq(parsed.tags.length(), 1)
      assert_eq(parsed.tags[0].key, "TITLE")
      assert_eq(parsed.tags[0].value, "标题")
      match @codec.get_tag(parsed, "TITLE") {
        Some(v) => assert_eq(v, "标题")
        None => assert_true(false)
      }
    }
  }
  // VorbisComment 走同一条公开编码/解析路径
  let vorbis = @codec.encode_comment(@codec.CommentKind::Vorbis, comment, 0)
  match @codec.parse_comment(vorbis) {
    Err(msg) => abort("VorbisComment 往返失败: " + msg)
    Ok((kind, _)) =>
      match kind {
        @codec.CommentKind::Vorbis => assert_true(true)
        @codec.CommentKind::Opus => assert_true(false)
      }
  }
  assert_true(@codec.valid_key("TITLE"))
  assert_true(!@codec.valid_key("A=B"))
  assert_true(!@codec.valid_key(""))
  let updated = @codec.set_tag(comment, "ARTIST", "someone")
  assert_eq(updated.tags.length(), 2)
  let removed = @codec.remove_tag(updated, "TITLE")
  assert_eq(removed.tags.length(), 1)
  assert_true(@codec.get_tag(removed, "TITLE") is None)
  match @codec.parse_comment(b"") {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
  match @codec.parse_comment(b"NotACommentAtAll") {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
}

///|
test "public api: opus TOC durations and rejects" {
  // config 0/1/2/3 → 10/20/40/60 ms（480/960/1920/2880 样本）
  assert_eq(toc_samples(b"\x00"), Some(480))
  assert_eq(toc_samples(b"\x08"), Some(960))
  assert_eq(toc_samples(b"\x10"), Some(1920))
  assert_eq(toc_samples(b"\x18"), Some(2880))
  // code 1/2 为两帧；code 3 的帧数取第二字节
  assert_eq(toc_samples(b"\x01"), Some(960))
  assert_eq(toc_samples(b"\x03\x08"), Some(960))
  // 非法：空包、缺第二字节、帧数超限
  assert_eq(toc_samples(b""), None)
  assert_eq(toc_samples(b"\x03"), None)
  assert_eq(toc_samples(b"\x03\xfc"), None)
}

///|
test "public api: comment parser rejects malformed fields and framing" {
  // 只有 vendor 长度与 vendor，没有条目计数字段
  assert_true(@codec.parse_comment(b"OpusTags\x00\x00\x00\x00") is Err(_))
  // 声明 1 条注释，但条目长度字段缺失
  assert_true(
    @codec.parse_comment(b"OpusTags\x00\x00\x00\x00\x01\x00\x00\x00") is Err(_),
  )
  // 条目长度 100 超出包内剩余字节
  assert_true(
    @codec.parse_comment(
      b"OpusTags\x00\x00\x00\x00\x01\x00\x00\x00\x64\x00\x00\x00",
    )
    is Err(_),
  )
  // 没有 '=' 的条目按规范无效：跳过而不是整包失败
  match
    @codec.parse_comment(
      b"OpusTags\x00\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00ab",
    ) {
    Err(msg) => abort("无等号条目不应导致整包失败: " + msg)
    Ok((_, parsed)) => assert_eq(parsed.tags.length(), 0)
  }
  // Vorbis 注释包的 framing 位未置位
  match
    @codec.parse_comment(b"\x03vorbis\x00\x00\x00\x00\x00\x00\x00\x00\x00") {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
}

///|
test "public api: encode_comment_preserving validates kinds and suffix" {
  let comment : @codec.Comment = { vendor: "moonmux", tags: [], }
  // 原包非法
  match
    @codec.encode_comment_preserving(@codec.CommentKind::Opus, comment, 0, b"") {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  // 写出类型与原包类型不一致
  let opus_packet = @codec.encode_comment(@codec.CommentKind::Opus, comment, 0)
  match
    @codec.encode_comment_preserving(
      @codec.CommentKind::Vorbis,
      comment,
      0,
      opus_packet,
    ) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  // Vorbis 注释不保留二进制后缀
  let vorbis_packet = @codec.encode_comment(
    @codec.CommentKind::Vorbis,
    comment,
    0,
  )
  match
    @codec.encode_comment_preserving(
      @codec.CommentKind::Vorbis,
      comment,
      0,
      vorbis_packet,
    ) {
    Ok(_) => assert_true(true)
    Err(_) => assert_true(false)
  }
  // Opus 的二进制后缀（首字节最低位为 1）必须原样保留
  let with_suffix = Buffer()
  with_suffix.write_bytes(opus_packet.exact_view())
  with_suffix.write_byte((0x01 : Byte))
  match
    @codec.encode_comment_preserving(
      @codec.CommentKind::Opus,
      comment,
      0,
      with_suffix.to_bytes(),
    ) {
    Err(_) => assert_true(false)
    Ok(out) => assert_eq(out.length(), opus_packet.length() + 1)
  }
}

///|
test "public api: vorbis_block_sizes rejects non-vorbis headers" {
  assert_true(@codec.vorbis_block_sizes(b"") is None)
  let wrong = Buffer()
  wrong.write_byte((0x02 : Byte))
  wrong.write_bytes(b"vorbis".exact_view())
  let mut i = 0
  while i < 23 {
    wrong.write_byte((0 : Byte))
    i = i + 1
  }
  assert_eq(wrong.to_bytes().length(), 30)
  assert_true(@codec.vorbis_block_sizes(wrong.to_bytes()) is None)
  // 合法识别头：block0=8、block1=11 → (256, 2048)
  let ok = Buffer()
  ok.write_byte((0x01 : Byte))
  ok.write_bytes(b"vorbis".exact_view())
  ok.write_bytes(b"\x00\x00\x00\x00".exact_view())
  ok.write_byte((1 : Byte))
  ok.write_bytes(b"\x44\xac\x00\x00".exact_view())
  ok.write_bytes(
    b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".exact_view(),
  )
  ok.write_byte((0xB8 : Byte))
  ok.write_byte((0x01 : Byte))
  match @codec.vorbis_block_sizes(ok.to_bytes()) {
    Some(pair) => {
      assert_eq(pair.0, 256)
      assert_eq(pair.1, 2048)
    }
    None => assert_true(false)
  }
}
