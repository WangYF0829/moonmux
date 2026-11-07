// mp4_wbtest.mbt —— MP4 写侧 / 读侧的端到端测试
//
// 这里用「合成的 Ogg Opus 流」做完整闭环：
//   OpusHead + OpusTags + 两个音频包 → ogg 序列化 → remux → inspect 读回。
// 真实音频文件的验证在 scripts/smoke.sh 与 scripts/verify_mp4.sh（ffprobe）。

///|
/// 合成一个最小、合法的 Ogg Opus 流（1 声道，pre-skip 312，2 个 20ms 包）。
fn synthetic_ogg_opus() -> Bytes {
  // OpusHead：magic(8) version=1 channels=1 pre_skip=312 input_rate=48000 gain=0 family=0
  let head : Bytes = b"OpusHead\x01\x01\x38\x01\x80\xbb\x00\x00\x00\x00\x00"
  // OpusTags：magic(8) vendor_len=6 "moonmu" comment_count=0
  let tags : Bytes = b"OpusTags\x06\x00\x00\x00moonmu\x00\x00\x00\x00"
  // 两个 20ms 的 Opus 包：TOC 0xFC → config 31 / code 0 → 960 样本 @48kHz
  let p1 : Bytes = b"\xfc\x01\x02\x03"
  let p2 : Bytes = b"\xfc\x04\x05"
  let packets : Array[@ogg.Packet] = [
    { data: head, granule_position: 0L, serial: 1U, },
    { data: tags, granule_position: 0L, serial: 1U, },
    { data: p1, granule_position: 960L, serial: 1U, },
    { data: p2, granule_position: 1920L, serial: 1U, },
  ]
  @ogg.serialize_pages(@ogg.paginate(packets, 1U))
}

///|
test "mp4 box: size and fourcc are big-endian" {
  let b = box("ftyp", b"abcd")
  assert_eq(b.length(), 12)
  assert_eq(b[0].to_int(), 0)
  assert_eq(b[3].to_int(), 12)
  assert_eq(b[4].to_int(), 0x66) // 'f'
  assert_eq(b[5].to_int(), 0x74) // 't'
  assert_eq(b[6].to_int(), 0x79) // 'y'
  assert_eq(b[7].to_int(), 0x70) // 'p'
}

///|
test "mp4 full box: version and flags" {
  let b = full_box("test", 1, 0x000007, b"xy")
  assert_eq(b.length(), 14)
  assert_eq(b[8].to_int(), 1) // version
  assert_eq(b[9].to_int(), 0)
  assert_eq(b[10].to_int(), 0)
  assert_eq(b[11].to_int(), 7) // flags
}

///|
test "mp4 remux: synthetic ogg opus roundtrip" {
  let ogg = synthetic_ogg_opus()
  match remux_ogg_opus(ogg) {
    Err(msg) => {
      println("remux error: " + msg)
      assert_true(false)
    }
    Ok(mp4) =>
      match inspect(mp4) {
        None => assert_true(false)
        Some(info) => {
          assert_eq(info.major_brand, "M4A ")
          assert_eq(info.tracks.length(), 1)
          let t = info.tracks[0]
          assert_eq(t.handler, "soun")
          assert_eq(t.codec, "Opus")
          assert_eq(t.channels, 1)
          assert_eq(t.sample_rate, 48000)
          assert_eq(t.sample_count, 2)
          // 2 × 960 / 48000 = 0.04 秒
          assert_true(t.duration_seconds > 0.039)
          assert_true(t.duration_seconds < 0.041)
        }
      }
  }
}

///|
test "mp4 remux: output layout is ftyp + mdat + moov" {
  let ogg = synthetic_ogg_opus()
  match remux_ogg_opus(ogg) {
    Err(_) => assert_true(false)
    Ok(mp4) => {
      // ftyp 在文件开头
      assert_true(is_mp4(mp4))
      // moov 在最后、mdat 在中间：按 box 顺序断言
      let top = boxes_in(mp4, 0, mp4.length())
      assert_eq(top.length(), 3)
      assert_eq(top[0].fourcc, "ftyp")
      assert_eq(top[1].fourcc, "mdat")
      assert_eq(top[2].fourcc, "moov")
    }
  }
}

///|
test "mp4 rejects non-mp4 and non-opus" {
  match inspect(b"RIFF\x00\x00\x00\x00WAVEfmt ") {
    None => assert_true(true)
    Some(_) => assert_true(false)
  }
  match remux_ogg_opus(b"definitely not an ogg stream") {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
}
