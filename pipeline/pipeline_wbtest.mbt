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

///|
/// 识别看的是**逻辑流**而不是「文件里的第一个包」。
///
/// 多流文件的第一条流未必是音频（Ogg Skeleton 的骨架流就排在前面），
/// 只看第一个包会把它认成音频格式然后解码失败。
test "detect skips non-audio streams and finds the audio one" {
  let built = @ogg.mux_streams([
    {
      serial: 1U,
      packets: [{ data: b"fishead", granule_position: 0L, serial: 1U, }],
    },
    {
      serial: 2U,
      packets: [{ data: b"OpusHead", granule_position: 0L, serial: 2U, }],
    },
  ])
  let pages = match built {
    Ok(p) => p
    Err(_) => []
  }
  match detect(@ogg.serialize_pages(pages)) {
    Ok(Codec::Opus) => assert_true(true)
    _ => assert_true(false)
  }
}

///|
/// 一条流的首包不是音频标识包时，转码要在报错里点明是**哪一段**。
///
/// 链接流的失败必须能定位到段 —— 「第 3 段没有音频流」和
/// 「这个文件没有音频流」对使用者来说是两个完全不同的问题。
test "ogg_to_wav names the segment without an audio stream" {
  let blob = page_with(b"RandomJunk")
  match ogg_to_wav(blob) {
    Err(msg) => {
      assert_true(msg.contains("第 1 段"))
      assert_true(msg.contains("OpusHead"))
    }
    Ok(_) => assert_true(false)
  }
}

///|
/// 抽流交给解码器之前，页是一条不多一条不少的 —— 用容器层复核一遍。
///
/// 这条钉住的是「转码前先抽成单流」这一步：若抽流时把别的流的页
/// 也带了进去，解码器就会看到不属于自己的包。
test "the stream handed to the decoder holds only that stream" {
  let built = @ogg.mux_streams([
    {
      serial: 4U,
      packets: [{ data: b"OpusHead", granule_position: 0L, serial: 4U, }],
    },
    {
      serial: 5U,
      packets: [{ data: b"\x01vorbis", granule_position: 0L, serial: 5U, }],
    },
  ])
  let pages = match built {
    Ok(p) => p
    Err(_) => []
  }
  let taken = @ogg.stream_pages(pages, 4U)
  assert_eq(@ogg.serials_of(taken).length(), 1)
  assert_eq(taken[0].serial, 4U)
  let reparsed = @ogg.parse_pages(@ogg.serialize_pages(taken))
  assert_eq(@ogg.structure_problems(reparsed).length(), 0)
  assert_eq(@ogg.reassemble(reparsed)[0].data.length(), 8)
}

///|
/// 估算只按头部与粒度算 PCM 字节数（2 声道、pre-skip 312、末粒度 48000）。
test "estimate pcm bytes from headers" {
  let packets : Array[@ogg.Packet] = [
    {
      data: b"OpusHead\x01\x02\x38\x01\x80\xBB\x00\x00\x00\x00\x00",
      granule_position: 0L,
      serial: 1U,
    },
    { data: b"audio", granule_position: 48000L, serial: 1U, },
  ]
  let pages = @ogg.paginate(packets, 1U)
  // (48000 - 0 - 312) × 2 声道 × 2 字节
  assert_eq(estimate_pcm_bytes([pages], 16), (48000L - 312L) * 4L)
}

///|
/// 估算超过预算时在解码前就拒绝，并说明是 PCM 预算。
test "the pcm budget is enforced before decoding" {
  let packets : Array[@ogg.Packet] = [
    {
      data: b"OpusHead\x01\x02\x38\x01\x80\xBB\x00\x00\x00\x00\x00",
      granule_position: 0L,
      serial: 1U,
    },
    { data: b"audio", granule_position: 48000L, serial: 1U, },
  ]
  let data = @ogg.serialize_pages(@ogg.paginate(packets, 1U))
  match ogg_to_wav_limited(data, 1000L) {
    Err(msg) => assert_true(msg.contains("MiB"))
    Ok(_) => assert_true(false)
  }
}

///|
/// 损坏的粒度（Int64 上限）不能让估算溢出成负数而绕过预算。
test "an absurd granule cannot bypass the budget" {
  let packets : Array[@ogg.Packet] = [
    {
      data: b"OpusHead\x01\x02\x38\x01\x80\xBB\x00\x00\x00\x00\x00",
      granule_position: 0L,
      serial: 1U,
    },
    { data: b"audio", granule_position: 9223372036854775807L, serial: 1U, },
  ]
  let pages = @ogg.paginate(packets, 1U)
  // 估算应当直接判为超限，而不是回绕成负数
  assert_true(estimate_pcm_bytes([pages], 16) > 268435456L)
}

///|
/// 24 位量化：满量程夹住、负值写补码、三个字节小端。
test "24-bit sample writer clamps and packs three bytes" {
  let buf = Buffer()
  write_sample(buf, 1.0, 24) // 0x7FFFFF
  write_sample(buf, -1.0, 24) // -8388607 -> 0x800001
  write_sample(buf, 0.0, 24) // 0
  write_sample(buf, 2.0, 24) // 夹到 0x7FFFFF
  let b = buf.to_bytes()
  assert_eq(b.length(), 12)
  assert_eq([b[0], b[1], b[2]], [0xFF, 0xFF, 0x7F].map(fn(x) { x.to_byte() }))
  assert_eq([b[3], b[4], b[5]], [0x01, 0x00, 0x80].map(fn(x) { x.to_byte() }))
  assert_eq([b[6], b[7], b[8]], [0x00, 0x00, 0x00].map(fn(x) { x.to_byte() }))
  assert_eq([b[9], b[10], b[11]], [0xFF, 0xFF, 0x7F].map(fn(x) { x.to_byte() }))
}
