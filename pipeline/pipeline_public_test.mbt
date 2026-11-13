// pipeline_public_test.mbt —— 黑盒测试：只用 pipeline 及其依赖包发布出来的公开 API。
//
// 与 *_wbtest.mbt 的白盒测试互补：这里不访问 pipeline 的任何私有符号。

///|
/// 从 testdata/opus_sample.opus 抽取的真实 Opus 逻辑流三个包：
/// OpusHead（19 B）、OpusTags（61 B）、一个真实音频包（143 B）。
/// 直接嵌入测试源而不是读文件：可信输入路径在 wasm / js 后端也能跑，
/// 且不依赖测试进程的工作目录。
fn trusted_opus_packets() -> Array[@ogg.Packet] {
  let head = b"\x4f\x70\x75\x73\x48\x65\x61\x64\x01\x01\x38\x01\x80\xbb\x00\x00\x00\x00\x00"
  let tags = b"\x4f\x70\x75\x73\x54\x61\x67\x73\x0c\x00\x00\x00\x4c\x61\x76\x66\x36\x31\x2e\x37\x2e\x31\x30\x30\x01\x00\x00\x00\x1d\x00\x00\x00\x65\x6e\x63\x6f\x64\x65\x72\x3d\x4c\x61\x76\x63\x36\x31\x2e\x31\x39\x2e\x31\x30\x30\x20\x6c\x69\x62\x6f\x70\x75\x73"
  let audio = b"\xf8\xab\xe6\x60\xba\x1d\x64\x5d\xf4\xe9\x4d\xb7\x4c\x9c\x8e\x8d\x80\x80\x41\x44\xf6\x91\xe9\x9d\x7d\x46\x58\x13\x57\x77\xcf\xc2\xb9\xe6\xc0\x2a\x03\x1e\xe3\x82\x98\x13\x80\x72\x5d\xc5\x89\xa0\xb7\x6d\x06\xb1\xd3\xe6\x9d\xb7\xb4\x9f\xc8\x69\x8e\x4f\x5e\xc9\x89\x59\xc6\x6e\xf5\x5e\x94\x45\x5d\x12\xe4\x1d\x84\x51\x33\xda\xc6\xe0\x1f\xa9\x8c\x10\xf7\x08\x39\x27\x6f\xe0\x4f\x65\xf5\x42\x9f\xc8\x7b\x83\x42\xab\xd7\xfa\xa3\x8a\x77\x9c\x50\x46\x56\x85\x21\x04\x76\x70\x2b\xdd\x43\x39\x23\x70\xff\x9c\xd6\xf0\x0e\xf9\x58\xf9\x91\xd1\xd9\x7b\x77\x4a\xcd\x1b\xf5\xa2\xdf\x78\xb0"
  [
    { data: head, granule_position: 0L, serial: 20261112U, },
    { data: tags, granule_position: 0L, serial: 20261112U, },
    { data: audio, granule_position: 960L, serial: 20261112U, },
  ]
}

///|
/// 坏输入：detect / ogg_to_wav 各入口必须返回 Err，而不是 panic 或返回半成品。
test "public api: non-ogg input is rejected by every entry point" {
  match @pipeline.detect(b"") {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  match @pipeline.detect(b"this is definitely not an ogg stream") {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  match @pipeline.ogg_to_wav(b"") {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  match @pipeline.ogg_to_wav_limited(b"", 1024L) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  match @pipeline.ogg_to_wav_limited(b"junk", -1L) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  let no_pages : Array[@ogg.Page] = []
  match @pipeline.ogg_to_wav_pages(no_pages, 1024L) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
}

///|
/// 可信输入结构：真实 Opus 包按公开 API 组页后，detect 必须认出 Opus；
/// 预算闸门必须在解码之前拒绝过小的预算，位深校验必须先失败。
test "public api: opus stream is detected and gates fire before decoding" {
  let packets = trusted_opus_packets()
  assert_eq(packets.length(), 3)
  let pages = @ogg.paginate(packets, 20261112U)
  assert_eq(pages.length(), 3)
  let bytes = @ogg.serialize_pages(pages)
  match @pipeline.detect(bytes) {
    Err(msg) => abort("detect 拒绝了一条合法的 Opus 流: " + msg)
    Ok(codec) =>
      match codec {
        @pipeline.Codec::Opus => assert_true(true)
        @pipeline.Codec::Vorbis => assert_true(false)
      }
  }
  // 0 字节预算必须在真正解码之前失败
  match @pipeline.ogg_to_wav_limited(bytes, 0L) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  // 不支持的输出位深必须在校验阶段失败
  match @pipeline.ogg_to_wav_pages_bits(pages, 1048576L, 32) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
}

///|
/// 可信输入的成功路径：真实 Opus 包 → Ogg → WAV，产物必须能被 wav 包解析。
test "public api: trusted opus stream transcodes to a parseable wav" {
  let pages = @ogg.paginate(trusted_opus_packets(), 20261112U)
  let bytes = @ogg.serialize_pages(pages)
  match @pipeline.ogg_to_wav(bytes) {
    Err(msg) => abort("ogg_to_wav 在可信 Opus 流上失败: " + msg)
    Ok(wav) => {
      assert_true(wav.length() > 44)
      match @wav.WavFile::parse(wav) {
        None => assert_true(false)
        Some(file) => {
          assert_eq(file.format.channels, 1)
          assert_eq(file.format.sample_rate, 48000)
          assert_eq(file.format.bits_per_sample, 16)
          assert_true(file.data.length() > 0)
          assert_eq(file.data.length() % 2, 0)
        }
      }
    }
  }
}

///|
/// 用一列包 + 对应 granule 组装单逻辑流 Ogg 字节流（每个包一页）。
fn stream_from_packets(
  packets : Array[Bytes],
  granules : Array[Int64],
  serial : UInt32,
) -> Bytes {
  let ps : Array[@ogg.Packet] = []
  let mut i = 0
  while i < packets.length() {
    ps.push({ data: packets[i], granule_position: granules[i], serial, })
    i = i + 1
  }
  @ogg.serialize_pages(@ogg.paginate(ps, serial))
}

///|
/// 最小的 VorbisComment 包：0x03 + "vorbis" + vendor_len(0) + count(0) + framing(1)。
fn vorbis_comment_packet() -> Bytes {
  b"\x03vorbis\x00\x00\x00\x00\x00\x00\x00\x00\x01"
}

///|
/// 最小的合法 Vorbis 识别头（30 字节）。
fn vorbis_id_packet() -> Bytes {
  let buf = Buffer()
  buf.write_byte((0x01 : Byte))
  buf.write_bytes(b"vorbis".exact_view())
  buf.write_bytes(b"\x00\x00\x00\x00".exact_view())
  buf.write_byte((1 : Byte))
  buf.write_bytes(b"\x44\xac\x00\x00".exact_view())
  buf.write_bytes(
    b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".exact_view(),
  )
  buf.write_byte((0x88 : Byte))
  buf.write_byte((0x01 : Byte))
  buf.to_bytes()
}

///|
/// 能通过 @codec.validate_vorbis_setup 的最小 setup 包。
fn valid_vorbis_setup_packet() -> Bytes {
  b"\x05vorbis\x00\x42\x43\x56\x00\x00\x00\x00\x00\x01\x00"
}

///|
test "public api: opus stream gate rejects missing or mismatched tags" {
  let trusted = trusted_opus_packets()
  let head = trusted[0].data
  let audio = trusted[2].data
  // 只有 OpusHead：缺少 OpusTags
  let only_head = stream_from_packets([head], [0L], 31U)
  match @pipeline.ogg_to_wav(only_head) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  // 第二个包不是注释包
  let not_tags = stream_from_packets(
    [head, b"not a comment packet", audio],
    [0L, 0L, 960L],
    31U,
  )
  match @pipeline.ogg_to_wav(not_tags) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  // 第二个包是 VorbisComment：种类与 Opus 流不匹配
  let wrong_kind = stream_from_packets(
    [head, vorbis_comment_packet(), audio],
    [0L, 0L, 960L],
    31U,
  )
  match @pipeline.ogg_to_wav(wrong_kind) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
}

///|
test "public api: vorbis stream gate rejects incomplete headers" {
  // 能被 codec_of_packet 认出、但不是合法识别头（只有 7 字节标记）
  let stub = stream_from_packets([b"\x01vorbis"], [0L], 41U)
  match @pipeline.ogg_to_wav(stub) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  let id = vorbis_id_packet()
  let comment = vorbis_comment_packet()
  // 缺少注释头
  let only_id = stream_from_packets([id], [0L], 41U)
  match @pipeline.ogg_to_wav(only_id) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  // 第二个包是 OpusTags：种类不匹配
  let tags = trusted_opus_packets()[1].data
  let wrong_kind = stream_from_packets([id, tags], [0L, 0L], 41U)
  match @pipeline.ogg_to_wav(wrong_kind) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  // 缺少 setup 头
  let no_setup = stream_from_packets([id, comment], [0L, 0L], 41U)
  match @pipeline.ogg_to_wav(no_setup) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  // setup 头无法通过预检
  let bad_setup = stream_from_packets(
    [id, comment, b"not a setup header"],
    [0L, 0L, 0L],
    41U,
  )
  match @pipeline.ogg_to_wav(bad_setup) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
}

///|
test "public api: vorbis stream granule checks reject unusable timelines" {
  let id = vorbis_id_packet()
  let comment = vorbis_comment_packet()
  let setup = valid_vorbis_setup_packet()
  // granule 全为 0：估算阶段拒绝
  let flat = stream_from_packets(
    [id, comment, setup, b"\x00"],
    [0L, 0L, 0L, 0L],
    43U,
  )
  match @pipeline.ogg_to_wav(flat) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  // granule 巨大：解码内存估算溢出，必须在进入 Vorbis 解码器之前拒绝
  let huge = stream_from_packets(
    [id, comment, setup, b"\x00"],
    [0L, 0L, 0L, 4611686018427387904L],
    43U,
  )
  match @pipeline.ogg_to_wav(huge) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
}

///|
test "public api: opus stream without audio packets reports empty pcm" {
  let trusted = trusted_opus_packets()
  let head = trusted[0].data
  let tags = trusted[1].data
  let no_audio = stream_from_packets([head, tags], [0L, 0L], 47U)
  match @pipeline.ogg_to_wav(no_audio) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
}

///|
test "public api: opus head channel mismatch with decoded result is rejected" {
  let trusted = trusted_opus_packets()
  // 头声明立体声，但音频包是单声道样本
  let stereo_head = b"OpusHead\x01\x02\x38\x01\x80\xbb\x00\x00\x00\x00\x00"
  let tags = trusted[1].data
  let audio = trusted[2].data
  let mismatched = stream_from_packets(
    [stereo_head, tags, audio],
    [0L, 0L, 960L],
    53U,
  )
  match @pipeline.ogg_to_wav(mismatched) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
}

///|
test "public api: 24-bit output produces a parseable 24-bit wav" {
  let pages = @ogg.paginate(trusted_opus_packets(), 59U)
  match @pipeline.ogg_to_wav_pages_bits(pages, 1048576L, 24) {
    Err(msg) => abort("24 位转码失败: " + msg)
    Ok(wav) => {
      assert_true(wav.length() > 44)
      match @wav.WavFile::parse(wav) {
        None => assert_true(false)
        Some(file) => {
          assert_eq(file.format.bits_per_sample, 24)
          assert_eq(file.bytes_per_sample, 3)
          assert_true(file.data.length() > 0)
          assert_eq(file.data.length() % 3, 0)
        }
      }
    }
  }
}

///|
test "public api: stream whose first packet never completes is rejected" {
  let payload = Buffer()
  let mut i = 0
  while i < 255 {
    payload.write_byte((i % 251).to_byte())
    i = i + 1
  }
  let page : @ogg.Page = {
    header_type: 0,
    granule_position: 0L,
    serial: 61U,
    sequence: 0U,
    crc: 0U,
    segments: [255],
    payload: payload.to_bytes(),
  }
  let bytes = @ogg.serialize_pages([page])
  match @pipeline.detect(bytes) {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
}
