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

///|
/// MP4 读侧的错误分支：空数据、只有 ftyp 没有 moov、moov 截断。
test "mp4 inspect rejects empty, moov-less and truncated files" {
  match inspect(b"") {
    None => assert_true(true)
    Some(_) => assert_true(false)
  }
  // 只有 ftyp
  let only_ftyp = Buffer()
  only_ftyp.write_bytes(b"\x00\x00\x00\x10ftypM4A \x00\x00\x00\x00")
  match inspect(only_ftyp.to_bytes()) {
    None => assert_true(true)
    Some(_) => assert_true(false)
  }
  // 合法 MP4 截断到 moov 前
  match remux_ogg_opus(synthetic_ogg_opus()) {
    Err(_) => assert_true(false)
    Ok(mp4) => {
      let cut = mp4.length() - 10
      let buf = Buffer()
      let mut i = 0
      while i < cut {
        buf.write_byte(mp4[i])
        i = i + 1
      }
      match inspect(buf.to_bytes()) {
        None => assert_true(true)
        Some(_) => assert_true(false)
      }
    }
  }
}

///|
/// MP4 写入的错误分支：没有 Opus 流、只有头包没有音频包。
test "mp4 remux rejects non-opus and header-only streams" {
  // 首包不是 OpusHead
  let p1 : Bytes = b"\xfc\x01\x02"
  let p2 : Bytes = b"\xfc\x03\x04"
  let packets : Array[@ogg.Packet] = [
    { data: p1, granule_position: 0L, serial: 1U, },
    { data: p2, granule_position: 960L, serial: 1U, },
    { data: p1, granule_position: 1920L, serial: 1U, },
  ]
  match remux_ogg_opus(@ogg.serialize_pages(@ogg.paginate(packets, 1U))) {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
  // 只有 OpusHead + OpusTags，没有音频包
  let head : Bytes = b"OpusHead\x01\x01\x38\x01\x80\xbb\x00\x00\x00\x00\x00"
  let tags : Bytes = b"OpusTags\x06\x00\x00\x00moonmu\x00\x00\x00\x00"
  let only_headers : Array[@ogg.Packet] = [
    { data: head, granule_position: 0L, serial: 1U, },
    { data: tags, granule_position: 0L, serial: 1U, },
  ]
  match remux_ogg_opus(@ogg.serialize_pages(@ogg.paginate(only_headers, 1U))) {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
}

///|
/// mvhd version 1（64 位时间字段）必须按 version 1 布局解析，而不是崩溃。
fn mp4_with_mvhd_v1(mvhd_payload_len : Int32, duration : Int64) -> Bytes {
  let ftyp : Bytes = b"\x00\x00\x00\x10ftypM4A \x00\x00\x00\x00"
  let body = Buffer()
  body.write_byte((1 : Byte)) // version
  body.write_byte((0 : Byte))
  body.write_byte((0 : Byte))
  body.write_byte((0 : Byte))
  // creation/modification time（16 字节）
  let mut i = 0
  while i < 16 {
    body.write_byte((0 : Byte))
    i = i + 1
  }
  // timescale = 1000
  body.write_byte((0 : Byte))
  body.write_byte((0 : Byte))
  body.write_byte((0x03 : Byte))
  body.write_byte((0xE8 : Byte))
  // duration（8 字节大端）
  let mut shift = 56
  while shift >= 0 {
    let v = ((duration >> shift) & 0xFFL).to_int()
    body.write_byte(v.to_byte())
    shift = shift - 8
  }
  let body_bytes = body.to_bytes()
  // 按 mvhd_payload_len 截断或补零，构造「字段不足」的版本 1 头部
  let payload = Buffer()
  let wanted = if mvhd_payload_len <= body_bytes.length() {
    mvhd_payload_len
  } else {
    body_bytes.length()
  }
  let mut k = 0
  while k < wanted {
    payload.write_byte(body_bytes[k])
    k = k + 1
  }
  let mvhd_size = 8 + payload.length()
  let mvhd = Buffer()
  mvhd.write_byte((mvhd_size / 16777216 % 256).to_byte())
  mvhd.write_byte((mvhd_size / 65536 % 256).to_byte())
  mvhd.write_byte((mvhd_size / 256 % 256).to_byte())
  mvhd.write_byte((mvhd_size % 256).to_byte())
  mvhd.write_bytes(b"mvhd".exact_view())
  mvhd.write_bytes(payload.to_bytes().exact_view())
  let moov_body = mvhd.to_bytes()
  let moov_size = 8 + moov_body.length()
  let moov = Buffer()
  moov.write_byte((moov_size / 16777216 % 256).to_byte())
  moov.write_byte((moov_size / 65536 % 256).to_byte())
  moov.write_byte((moov_size / 256 % 256).to_byte())
  moov.write_byte((moov_size % 256).to_byte())
  moov.write_bytes(b"moov".exact_view())
  moov.write_bytes(moov_body.exact_view())
  let out = Buffer()
  out.write_bytes(ftyp.exact_view())
  out.write_bytes(moov.to_bytes().exact_view())
  out.to_bytes()
}

///|
test "mp4 inspect reads version-1 mvhd and rejects short payloads" {
  match inspect(mp4_with_mvhd_v1(32, 48000L)) {
    Some(info) =>
      assert_true(
        info.tracks.length() == 0 &&
        info.duration_seconds > 47.9 &&
        info.duration_seconds < 48.1,
      )
    None => assert_true(false)
  }
  // version=1 但只有 20 字节时间字段：必须拒绝而不是越界读
  match inspect(mp4_with_mvhd_v1(20, 48000L)) {
    None => assert_true(true)
    Some(_) => assert_true(false)
  }
}
