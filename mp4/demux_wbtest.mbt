// demux_wbtest.mbt —— MP4 → Ogg 解封装的闭环测试
//
// 与 mp4_wbtest.mbt 的「Ogg → MP4」互补：合成 Ogg → remux → demux，
// 断言音频包逐字节还原、OpusHead 逐字节还原、OpusTags 为最小合成标签。

///|
/// 合成最小合法 Ogg Opus 流（1 声道、pre-skip 312、两个 20ms 包）。
fn dwb_ogg_opus() -> Bytes {
  let head : Bytes = b"OpusHead\x01\x01\x38\x01\x80\xbb\x00\x00\x00\x00\x00"
  let tags : Bytes = b"OpusTags\x06\x00\x00\x00moonmu\x00\x00\x00\x00"
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
fn dwb_same(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut i = 0
  while i < a.length() {
    if a[i].to_int() != b[i].to_int() {
      return false
    }
    i = i + 1
  }
  true
}

///|
fn dwb_starts_with(data : Bytes, prefix : Bytes) -> Bool {
  if data.length() < prefix.length() {
    return false
  }
  let mut i = 0
  while i < prefix.length() {
    if data[i].to_int() != prefix[i].to_int() {
      return false
    }
    i = i + 1
  }
  true
}

///|
fn dwb_find(data : Bytes, needle : Bytes) -> Int32? {
  let mut i = 0
  while i + needle.length() <= data.length() {
    let mut same = true
    let mut j = 0
    while j < needle.length() {
      if data[i + j].to_int() != needle[j].to_int() {
        same = false
      }
      j = j + 1
    }
    if same {
      return Some(i)
    }
    i = i + 1
  }
  None
}

///|
/// 把 `at` 起的四个字节替换成给定的 fourcc（用于构造坏样本条目）。
fn dwb_patch_fourcc(data : Bytes, at : Int32, s : String) -> Bytes {
  let out = Buffer()
  let mut i = 0
  while i < data.length() {
    let v = if i >= at && i < at + 4 {
      match s.get_char(i - at) {
        Some(c) => (c.to_int() & 0xFF).to_byte()
        None => data[i]
      }
    } else if i == at + 4 - 1 {
      data[i]
    } else {
      data[i]
    }
    out.write_byte(v)
    i = i + 1
  }
  out.to_bytes()
}

///|
test "demux mp4: audio packets and OpusHead roundtrip" {
  let original = dwb_ogg_opus()
  match remux_ogg_opus(original) {
    Err(msg) => {
      println("remux error: " + msg)
      assert_true(false)
    }
    Ok(mp4) =>
      match demux_mp4_opus(mp4) {
        Err(msg) => {
          println("demux error: " + msg)
          assert_true(false)
        }
        Ok(ogg) => {
          let before = @ogg.reassemble(@ogg.parse_pages(original))
          let after = @ogg.reassemble(@ogg.parse_pages(ogg))
          assert_eq(after.length(), before.length())
          // OpusHead 逐字节还原
          assert_true(dwb_same(before[0].data, after[0].data))
          // OpusTags 是最小合成标签：vendor "moonmux"、0 条注释
          assert_eq(after[1].data.length(), 8 + 4 + 7 + 4)
          assert_true(dwb_starts_with(after[1].data, b"OpusTags"))
          // 音频包逐字节还原
          let mut i = 2
          while i < before.length() {
            assert_true(dwb_same(before[i].data, after[i].data))
            i = i + 1
          }
          // granule = pre-skip + 累计时长
          let last = after.length() - 1
          assert_eq(after[last].granule_position, 312L + 1920L)
          // 所有页 CRC 自洽
          for page in @ogg.parse_pages(ogg) {
            assert_true(@ogg.page_crc_ok(page))
          }
        }
      }
  }
}

///|
test "demux mp4: output can be remuxed again" {
  match remux_ogg_opus(dwb_ogg_opus()) {
    Err(_) => assert_true(false)
    Ok(mp4) =>
      match demux_mp4_opus(mp4) {
        Err(_) => assert_true(false)
        Ok(ogg) =>
          match remux_ogg_opus(ogg) {
            Err(_) => assert_true(false)
            Ok(mp4b) =>
              match inspect(mp4b) {
                Some(info) => {
                  assert_eq(info.tracks[0].codec, "Opus")
                  assert_eq(info.tracks[0].channels, 1)
                  assert_eq(info.tracks[0].sample_count, 2)
                }
                None => assert_true(false)
              }
          }
      }
  }
}

///|
test "demux mp4: rejects non-mp4 and non-opus input" {
  assert_true(
    match demux_mp4_opus(b"not an mp4") {
      Err(_) => true
      Ok(_) => false
    },
  )
  match remux_ogg_opus(dwb_ogg_opus()) {
    Err(_) => assert_true(false)
    Ok(mp4) => {
      // 把样本条目的 fourcc "Opus" 改成 "MP4A"
      let at = match dwb_find(mp4, b"Opus") {
        Some(p) => p
        None => -1
      }
      assert_true(at >= 0)
      if at >= 0 {
        let bad = dwb_patch_fourcc(mp4, at, "MP4A")
        assert_true(
          match demux_mp4_opus(bad) {
            Err(_) => true
            Ok(_) => false
          },
        )
      }
      // 把 dOps 的 Version 改成 1（不支持）
      match dwb_find(mp4, b"dOps") {
        Some(p) => {
          let buf = Buffer()
          let mut i = 0
          while i < mp4.length() {
            let v = if i == p + 4 { (1 : Byte) } else { mp4[i] }
            buf.write_byte(v)
            i = i + 1
          }
          assert_true(
            match demux_mp4_opus(buf.to_bytes()) {
              Err(_) => true
              Ok(_) => false
            },
          )
        }
        None => assert_true(false)
      }
    }
  }
}

// ---------- 坏表防御：每条分支都要有测试触达 ----------

///|
fn dwb_body(mp4 : Bytes, fourcc : Bytes) -> Int32? {
  match dwb_find(mp4, fourcc) {
    Some(p) => Some(p + 4)
    None => None
  }
}

///|
fn dwb_patch_u8(data : Bytes, at : Int32, v : Int32) -> Bytes {
  let out = Buffer()
  let mut i = 0
  while i < data.length() {
    out.write_byte(if i == at { (v & 0xFF).to_byte() } else { data[i] })
    i = i + 1
  }
  out.to_bytes()
}

///|
fn dwb_patch_u32_be(data : Bytes, at : Int32, v : Int32) -> Bytes {
  let out = Buffer()
  let mut i = 0
  while i < data.length() {
    let b = if i == at {
      ((v >> 24) & 0xFF).to_byte()
    } else if i == at + 1 {
      ((v >> 16) & 0xFF).to_byte()
    } else if i == at + 2 {
      ((v >> 8) & 0xFF).to_byte()
    } else if i == at + 3 {
      (v & 0xFF).to_byte()
    } else {
      data[i]
    }
    out.write_byte(b)
    i = i + 1
  }
  out.to_bytes()
}

///|
fn dwb_rejects(mp4 : Bytes) -> Bool {
  match demux_mp4_opus(mp4) {
    Err(_) => true
    Ok(_) => false
  }
}

///|
test "demux mp4: rejects missing moov/mdat/track" {
  // 只有 ftyp
  let only_ftyp : Bytes = b"\x00\x00\x00\x10ftypM4A \x00\x00\x00\x00"
  assert_true(dwb_rejects(only_ftyp))
  match remux_ogg_opus(dwb_ogg_opus()) {
    Err(_) => assert_true(false)
    Ok(mp4) => {
      // mdat 改名 → 缺少 mdat
      match dwb_find(mp4, b"mdat") {
        Some(p) => assert_true(dwb_rejects(dwb_patch_fourcc(mp4, p, "free")))
        None => assert_true(false)
      }
      // hdlr 的 "soun" 改名 → 没有音频轨
      match dwb_find(mp4, b"soun") {
        Some(p) => assert_true(dwb_rejects(dwb_patch_fourcc(mp4, p, "vide")))
        None => assert_true(false)
      }
      // mdhd timescale 改成 44100 → 拒绝
      match dwb_body(mp4, b"mdhd") {
        Some(b) =>
          assert_true(dwb_rejects(dwb_patch_u32_be(mp4, b + 12, 44100)))
        None => assert_true(false)
      }
      // 缺 stsd / stts / stsz / stsc
      let names : Array[Bytes] = [b"stsd", b"stts", b"stsz", b"stsc"]
      for name in names {
        match dwb_find(mp4, name) {
          Some(p) => assert_true(dwb_rejects(dwb_patch_fourcc(mp4, p, "free")))
          None => assert_true(false)
        }
      }
    }
  }
}

///|
test "demux mp4: rejects corrupt sample tables" {
  match remux_ogg_opus(dwb_ogg_opus()) {
    Err(_) => assert_true(false)
    Ok(mp4) => {
      // stts 太短（把 box size 改成 8，只有头部）
      match dwb_find(mp4, b"stts") {
        Some(p) => assert_true(dwb_rejects(dwb_patch_u32_be(mp4, p - 4, 8)))
        None => assert_true(false)
      }
      // stts 条目数越界
      match dwb_body(mp4, b"stts") {
        Some(b) =>
          assert_true(dwb_rejects(dwb_patch_u32_be(mp4, b + 4, 0x7FFFFFFF)))
        None => assert_true(false)
      }
      // stts 游程 sample_count = 0
      match dwb_body(mp4, b"stts") {
        Some(b) => assert_true(dwb_rejects(dwb_patch_u32_be(mp4, b + 8, 0)))
        None => assert_true(false)
      }
      // stsz 太短
      match dwb_find(mp4, b"stsz") {
        Some(p) => assert_true(dwb_rejects(dwb_patch_u32_be(mp4, p - 4, 8)))
        None => assert_true(false)
      }
      // stsz 样本数越界
      match dwb_body(mp4, b"stsz") {
        Some(b) =>
          assert_true(dwb_rejects(dwb_patch_u32_be(mp4, b + 8, 0x7FFFFFFF)))
        None => assert_true(false)
      }
      // stsz 中存在空样本
      match dwb_body(mp4, b"stsz") {
        Some(b) => assert_true(dwb_rejects(dwb_patch_u32_be(mp4, b + 12, 0)))
        None => assert_true(false)
      }
      // stsz 样本数与 stts 不一致
      match dwb_body(mp4, b"stsz") {
        Some(b) => assert_true(dwb_rejects(dwb_patch_u32_be(mp4, b + 8, 1)))
        None => assert_true(false)
      }
      // stsc 太短 / 条目数为 0 / first_chunk 不为 1
      match dwb_find(mp4, b"stsc") {
        Some(p) => assert_true(dwb_rejects(dwb_patch_u32_be(mp4, p - 4, 8)))
        None => assert_true(false)
      }
      match dwb_body(mp4, b"stsc") {
        Some(b) => {
          assert_true(dwb_rejects(dwb_patch_u32_be(mp4, b + 4, 0)))
          assert_true(dwb_rejects(dwb_patch_u32_be(mp4, b + 8, 2)))
        }
        None => assert_true(false)
      }
      // stco 偏移越界
      match dwb_body(mp4, b"stco") {
        Some(b) =>
          assert_true(dwb_rejects(dwb_patch_u32_be(mp4, b + 8, 0x0FFFFFFF)))
        None => assert_true(false)
      }
      // dOps：声道数为 0 / 映射族非 0 但映射表缺失
      match dwb_body(mp4, b"dOps") {
        Some(b) => {
          assert_true(dwb_rejects(dwb_patch_u8(mp4, b + 1, 0)))
          assert_true(dwb_rejects(dwb_patch_u8(mp4, b + 10, 1)))
        }
        None => assert_true(false)
      }
    }
  }
}
