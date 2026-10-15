// pipeline_wbtest.mbt —— 转码管线的测试
//
// 这里测的是**管线自己**的职责：识别编码格式、分派、以及失败时如实报错。
// 解码本身是外部解码器的活，不该由这些测试来验收 —— 那会把别人的
// 改动变成自己测试的红绿灯。真实解码的端到端验证走命令行与 testdata/。

///|
/// 用给定负载构造一个单页 Ogg 文件，供识别函数使用。
fn page_with(payload : Bytes) -> Bytes {
  let page : @ogg.Page = {
    header_type: 0,
    granule_position: 0L,
    serial: 1U,
    sequence: 0U,
    crc: 0U,
    segments: [payload.length()],
    payload,
  }
  @ogg.serialize_pages([page])
}

///|
/// Opus 的标识包以 "OpusHead" 开头（RFC 7845 §5.1）。
test "detect identifies opus by its id packet" {
  match detect(page_with(b"OpusHead")) {
    Ok(Codec::Opus) => assert_true(true)
    _ => assert_true(false)
  }
}

///|
/// Vorbis 的标识包以 0x01 + "vorbis" 开头（Vorbis I 规范 §4.2.1）。
test "detect identifies vorbis by its id packet" {
  match detect(page_with(b"\x01vorbis")) {
    Ok(Codec::Vorbis) => assert_true(true)
    _ => assert_true(false)
  }
}

///|
/// 判据是**包内容**而不是文件扩展名：起手包不是标识包就该报错。
test "detect rejects unrecognised id packet" {
  match detect(page_with(b"RandomJunk")) {
    Err(msg) => assert_true(msg.length() > 0)
    _ => assert_true(false)
  }
}

///|
/// 不是 Ogg 的东西必须报错，而不是解析出垃圾。
test "detect rejects non-ogg input" {
  match detect(b"this is definitely not an ogg file") {
    Err(msg) => assert_true(msg.length() > 0)
    _ => assert_true(false)
  }
}

///|
/// 起不出页的文件（捕获模式都没有）同样要报错。
test "detect rejects input with no pages" {
  match detect(b"OggS") {
    Err(_) => assert_true(true)
    _ => assert_true(false)
  }
}

///|
/// 转码入口把无法识别的流如实退回，而不是写出一个空 WAV。
test "ogg_to_wav returns an error for unknown codec" {
  match ogg_to_wav(page_with(b"RandomJunk")) {
    Err(_) => assert_true(true)
    _ => assert_true(false)
  }
  match ogg_to_wav(b"not an ogg file") {
    Err(_) => assert_true(true)
    _ => assert_true(false)
  }
}
