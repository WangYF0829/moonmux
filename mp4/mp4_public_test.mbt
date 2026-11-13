// mp4_public_test.mbt —— 黑盒测试：只用 mp4 包发布出来的公开 API。
//
// 与 *_wbtest.mbt 的白盒测试互补：这里不访问任何私有符号。

///|
/// 最小 ftyp box：size=16、fourcc="ftyp"、major brand="M4A "、minor version=0。
fn minimal_ftyp() -> Bytes {
  b"\x00\x00\x00\x10ftypM4A \x00\x00\x00\x00"
}

///|
test "public api: is_mp4 only accepts an ftyp box" {
  let ftyp = minimal_ftyp()
  assert_eq(ftyp.length(), 16)
  assert_true(@mp4.is_mp4(ftyp))
  assert_true(!@mp4.is_mp4(b""))
  assert_true(!@mp4.is_mp4(b"not an mp4 file"))
  assert_true(
    !@mp4.is_mp4(b"\x00\x00\x00\x10ftyX\x00\x00\x00\x00\x00\x00\x00\x00"),
  )
}

///|
test "public api: inspect rejects empty / truncated / moov-less input" {
  let ftyp = minimal_ftyp()
  assert_true(@mp4.inspect(b"") is None)
  assert_true(@mp4.inspect(b"short") is None)
  assert_true(@mp4.inspect(b"\x00\x00\x00\x10ftyp") is None)
  // 只有 ftyp、没有 moov：必须返回 None，而不是把它洗白成合法 MP4
  assert_true(@mp4.inspect(ftyp) is None)
}

///|
test "public api: demux and remux reject non-mp4 / non-ogg input" {
  let ftyp = minimal_ftyp()
  match @mp4.demux_mp4_opus(b"") {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  match @mp4.demux_mp4_opus(b"not an mp4") {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  // 有 ftyp 但缺 moov/mdat：必须报错而不是返回半截输出
  match @mp4.demux_mp4_opus(ftyp) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  match @mp4.remux_ogg_opus(b"") {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  match @mp4.remux_ogg_opus(b"OggS but not a real page") {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
}
