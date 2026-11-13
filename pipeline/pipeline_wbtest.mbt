// pipeline_wbtest.mbt —— 转码管线的测试
//
// 这里测的是**管线自己**的职责：识别编码格式、分派、以及失败时如实报错。
// 解码本身是外部解码器的活，不应由这些测试承担 —— 那会把别人的
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
/// 小端写 u32（测试里手工拼包用）。
fn put_u32(buf : Buffer, v : Int32) -> Unit {
  buf.write_byte((v % 256).to_byte())
  buf.write_byte((v / 256 % 256).to_byte())
  buf.write_byte((v / 65536 % 256).to_byte())
  buf.write_byte((v / 16777216 % 256).to_byte())
}

///|
/// 构造一个最小合法 OpusHead（19 字节）；版本 / 声道 / pre-skip 可指定。
fn make_opus_head(version : Int32, channels : Int32, pre_skip : Int32) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(b"OpusHead".exact_view())
  buf.write_byte(version.to_byte())
  buf.write_byte(channels.to_byte())
  buf.write_byte((pre_skip % 256).to_byte())
  buf.write_byte((pre_skip / 256 % 256).to_byte())
  // 输入采样率 48000（只是元数据，Opus 输出恒为 48 kHz）
  buf.write_byte((0x80 : Byte))
  buf.write_byte((0xBB : Byte))
  buf.write_byte((0 : Byte))
  buf.write_byte((0 : Byte))
  buf.write_byte((0 : Byte)) // 输出增益
  buf.write_byte((0 : Byte))
  buf.write_byte((0 : Byte)) // 声道映射族 0
  buf.to_bytes()
}

///|
/// 最小合法 OpusTags：空 vendor、零条目。
fn opus_tags_packet() -> Bytes {
  let buf = Buffer()
  buf.write_bytes(b"OpusTags".exact_view())
  put_u32(buf, 0)
  put_u32(buf, 0)
  buf.to_bytes()
}

///|
/// 合法 Vorbis 识别头（2 声道 / 44100 Hz / block sizes 8、11 / framing=1）。
fn vorbis_ident_packet() -> Bytes {
  b"\x01vorbis\x00\x00\x00\x00\x02\x44\xAC\x00\x00\x00\x00\x00\x00\x00\xF4\x01\x00\x00\x00\x00\x00\xB8\x01"
}

///|
/// 合法 Vorbis 注释包：空 vendor、零条目、framing=1。
fn vorbis_comment_packet() -> Bytes {
  let buf = Buffer()
  buf.write_bytes(b"\x03vorbis".exact_view())
  put_u32(buf, 0)
  put_u32(buf, 0)
  buf.write_byte((0x01 : Byte))
  buf.to_bytes()
}

///|
/// 完整合法的 Vorbis setup 头（1 codebook / floor1 / residue / mapping / mode）。
///
/// pipeline 的 gate v2 会解析到 mode 段，所以必须给完整 setup 而不能只有
/// codebook 前缀；`mode_blockflag` 控制该 mode 使用短块(0)/长块(1)。
fn vorbis_setup_full(mode_blockflag : Int32) -> Bytes {
  let bits : Array[Int32] = []
  // 1 个 codebook：dims=1、entries=1、非 sparse、码长 1、无 lookup。
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 0x564342, 24)
  pv_push_bits(bits, 1, 16)
  pv_push_bits(bits, 1, 24)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 5)
  pv_push_bits(bits, 0, 4)
  // 时间变换：1 个类型 0
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 0, 16)
  // floor：1 个无 partition 的 floor1
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 1, 16)
  pv_push_bits(bits, 0, 5)
  pv_push_bits(bits, 0, 2)
  pv_push_bits(bits, 0, 4)
  // residue：1 个 type 1
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 1, 16)
  pv_push_bits(bits, 0, 24)
  pv_push_bits(bits, 0, 24)
  pv_push_bits(bits, 0, 24)
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 0, 3)
  pv_push_bits(bits, 0, 1)
  // mapping：1 个（单 submap、无 coupling）
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 0, 16)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 2)
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 0, 8)
  // mode：1 个
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, mode_blockflag, 1)
  pv_push_bits(bits, 0, 16)
  pv_push_bits(bits, 0, 16)
  pv_push_bits(bits, 0, 8)
  // framing 位
  pv_push_bits(bits, 1, 1)
  let buf = Buffer()
  buf.write_bytes(b"\x05vorbis".exact_view())
  buf.write_bytes(pv_bits_to_bytes(bits).exact_view())
  buf.to_bytes()
}

///|
fn vorbis_setup_ordered() -> Bytes {
  vorbis_setup_full(0)
}

///|
/// 按参数拼 30 字节 Vorbis 识别头（用于声道数/块大小相关的预算测试）。
fn vorbis_ident_packet_ex(
  channels : Int32,
  block0 : Int32,
  block1 : Int32,
) -> Bytes {
  let buf = Buffer()
  buf.write_byte((0x01 : Byte))
  buf.write_bytes(b"vorbis".exact_view())
  buf.write_bytes(b"\x00\x00\x00\x00".exact_view())
  buf.write_byte(channels.to_byte())
  buf.write_bytes(b"\x44\xAC\x00\x00".exact_view())
  buf.write_bytes(
    b"\x00\x00\x00\x00\x00\xF4\x01\x00\x00\x00\x00\x00".exact_view(),
  )
  buf.write_byte((block0 | (block1 << 4) : Int32).to_byte())
  buf.write_byte((1 : Byte))
  buf.to_bytes()
}

///|
/// C-02 的 221 B PoC 中的恶意 setup：第 1 个 codebook 声明
/// dimensions=65536、entries=16777216，且没有任何码长数据。
fn vorbis_setup_malicious() -> Bytes {
  b"\x05vorbis\x00\x42\x43\x56\xFF\xFF\xFF\xFF\xFF\x00"
}

///|
/// 把包序列变成已解析的页（多数测试只需页列表）。
fn pages_of(packets : Array[@ogg.Packet]) -> Array[@ogg.Page] {
  @ogg.paginate(packets, packets[0].serial)
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
/// 估算按解码工作量：Opus 逐包读 TOC 累加样本，完全忽略页 granule。
test "plan estimate uses opus packet toc and ignores granule" {
  let packets : Array[@ogg.Packet] = [
    {
      data: b"OpusHead\x01\x02\x38\x01\x80\xBB\x00\x00\x00\x00\x00",
      granule_position: 0L,
      serial: 1U,
    },
    { data: opus_tags_packet(), granule_position: 0L, serial: 1U, },
    // 0x19 = config 3（SILK 60 ms，2880 样本）+ code 1（2 帧）→ 5760 样本
    { data: b"\x19", granule_position: 0L, serial: 1U, },
    // 即使 granule 是 Int64 上限，估算也只看 TOC（H-03 / M-13）
    { data: b"\x19", granule_position: 9223372036854775807L, serial: 1U, },
  ]
  match plan_segment(pages_of(packets), 16) {
    Ok(plan) => {
      assert_eq(plan.channels, 2)
      assert_eq(plan.sample_rate, 48000)
      // 2 包 × 5760 样本 × 2 声道 ×（16 位输出 2 B + 解码器内部缓冲 8 B）
      assert_eq(plan.estimated_bytes, 2L * 5760L * 2L * 10L)
    }
    Err(_) => assert_true(false)
  }
}

///|
/// 估算超过预算时在解码前就拒绝，并说明是解码内存预算。
test "the pcm budget is enforced before decoding" {
  let packets : Array[@ogg.Packet] = [
    {
      data: b"OpusHead\x01\x02\x38\x01\x80\xBB\x00\x00\x00\x00\x00",
      granule_position: 0L,
      serial: 1U,
    },
    { data: opus_tags_packet(), granule_position: 0L, serial: 1U, },
    { data: b"\x19", granule_position: 48000L, serial: 1U, },
  ]
  let data = @ogg.serialize_pages(@ogg.paginate(packets, 1U))
  match ogg_to_wav_limited(data, 1000L) {
    Err(msg) => {
      assert_true(msg.contains("MiB"))
      assert_true(msg.contains("预算"))
    }
    Ok(_) => assert_true(false)
  }
}

///|
/// M-13 / CP-06 回归：损坏的 granule 不再用 `MAX+1` 哨兵绕过判断，
/// 而是估算直接 Err —— 与用户预算大小无关（调大预算也不能放行）。
test "absurd vorbis granule is rejected regardless of budget" {
  let packets : Array[@ogg.Packet] = [
    { data: vorbis_ident_packet(), granule_position: 0L, serial: 1U, },
    { data: vorbis_comment_packet(), granule_position: 0L, serial: 1U, },
    { data: vorbis_setup_ordered(), granule_position: 0L, serial: 1U, },
    { data: b"\x00", granule_position: 9223372036854775807L, serial: 1U, },
  ]
  match plan_segment(pages_of(packets), 16) {
    Err(msg) => assert_true(msg.contains("无法估算"))
    Ok(_) => assert_true(false)
  }
}

///|
/// H-03 回归：所有页 granule 都为 0 时，预算仍按包数 × TOC 估算并在
/// 解码前拒绝 —— 不再出现「估算 0 → 放行 → 解码器按包数分配」的绕过。
test "granule-zero opus cannot bypass the budget" {
  let packets : Array[@ogg.Packet] = [
    { data: make_opus_head(1, 1, 312), granule_position: 0L, serial: 1U, },
    { data: opus_tags_packet(), granule_position: 0L, serial: 1U, },
  ]
  let mut i = 0
  while i < 20 {
    // 每个 0x19 包 5760 样本；20 包 × 1 声道 × 10 B/样本 ≈ 1.1 MiB
    packets.push({ data: b"\x19", granule_position: 0L, serial: 1U, })
    i = i + 1
  }
  let data = @ogg.serialize_pages(@ogg.paginate(packets, 1U))
  match ogg_to_wav_pages(@ogg.parse_pages(data), 1048576L) {
    Err(msg) => {
      assert_true(msg.contains("预算"))
      assert_true(msg.contains("TOC"))
    }
    Ok(_) => assert_true(false)
  }
}

///|
/// H-04 回归：本项目解析器不接受的头部（OpusHead version=2）必须在解码前
/// 被拒绝，而不是「估算 0 → 解码器照跑 → 事后才报错」。
test "opus head version 2 is rejected before decoding" {
  let packets : Array[@ogg.Packet] = [
    { data: make_opus_head(2, 1, 312), granule_position: 0L, serial: 1U, },
    { data: opus_tags_packet(), granule_position: 0L, serial: 1U, },
    { data: b"\x19", granule_position: 5760L, serial: 1U, },
  ]
  let data = @ogg.serialize_pages(@ogg.paginate(packets, 1U))
  match ogg_to_wav_pages(@ogg.parse_pages(data), 268435456L) {
    Err(msg) => assert_true(msg.contains("不支持的 Opus 头部"))
    Ok(_) => assert_true(false)
  }
}

///|
/// C-02 回归：97 B 的恶意 Vorbis 注释（vendor_len=0x7FFFFFFF）必须在交给
/// moonvorbis 之前被本项目解析器拒绝，返回 Err 而不是崩溃（exit 0xC0000409）。
test "malicious vorbis comment is rejected before decoding" {
  let packets : Array[@ogg.Packet] = [
    { data: vorbis_ident_packet(), granule_position: 0L, serial: 1U, },
    // 0x7FFFFFFF 的 vendor 长度：解码器里 pos + vendor_len 会回绕成负数。
    { data: b"\x03vorbis\xFF\xFF\xFF\x7F", granule_position: 0L, serial: 1U, },
  ]
  let data = @ogg.serialize_pages(@ogg.paginate(packets, 1U))
  match ogg_to_wav_pages(@ogg.parse_pages(data), 1048576L) {
    Err(msg) => assert_true(msg.contains("预检"))
    Ok(_) => assert_true(false)
  }
}

///|
/// C-02 回归：221 B 的恶意 Vorbis setup（codebook entries=16777216 但无
/// 码长数据）必须在交给 moonvorbis 之前被拒绝（exit 0xC0000005 是访问违例）。
test "malicious vorbis setup is rejected before decoding" {
  let packets : Array[@ogg.Packet] = [
    { data: vorbis_ident_packet(), granule_position: 0L, serial: 1U, },
    { data: vorbis_comment_packet(), granule_position: 0L, serial: 1U, },
    { data: vorbis_setup_malicious(), granule_position: 0L, serial: 1U, },
  ]
  let data = @ogg.serialize_pages(@ogg.paginate(packets, 1U))
  match ogg_to_wav_pages(@ogg.parse_pages(data), 1048576L) {
    Err(msg) => assert_true(msg.contains("setup"))
    Ok(_) => assert_true(false)
  }
}

///|
/// Opus 音频包的 TOC 无法解析时必须在解码前拒绝（不能把不确定的包交给解码器）。
test "unparseable opus toc is rejected before decoding" {
  let packets : Array[@ogg.Packet] = [
    { data: make_opus_head(1, 1, 312), granule_position: 0L, serial: 1U, },
    { data: opus_tags_packet(), granule_position: 0L, serial: 1U, },
    { data: b"", granule_position: 5760L, serial: 1U, },
  ]
  let data = @ogg.serialize_pages(@ogg.paginate(packets, 1U))
  match ogg_to_wav_pages(@ogg.parse_pages(data), 268435456L) {
    Err(msg) => assert_true(msg.contains("TOC"))
    Ok(_) => assert_true(false)
  }
}

///|
/// Vorbis 的 granule 全部不可用时（-1）必须拒绝，不能按 0 估算放行。
test "vorbis without usable granule is rejected" {
  let packets : Array[@ogg.Packet] = [
    { data: vorbis_ident_packet(), granule_position: -1L, serial: 1U, },
    { data: vorbis_comment_packet(), granule_position: -1L, serial: 1U, },
    { data: vorbis_setup_ordered(), granule_position: -1L, serial: 1U, },
    { data: b"\x00", granule_position: -1L, serial: 1U, },
  ]
  match plan_segment(pages_of(packets), 16) {
    Err(msg) => assert_true(msg.contains("无法估算"))
    Ok(_) => assert_true(false)
  }
}

///|
/// 预检与解码共用同一次选流结果：多流文件里跳过非音频流，选中的是音频流。
test "gate picks the audio stream and shares it with decode" {
  let built = @ogg.mux_streams([
    {
      serial: 1U,
      packets: [{ data: b"fishead", granule_position: 0L, serial: 1U, }],
    },
    {
      serial: 2U,
      packets: [
        { data: make_opus_head(1, 1, 312), granule_position: 0L, serial: 2U, },
        { data: opus_tags_packet(), granule_position: 0L, serial: 2U, },
        { data: b"\x19", granule_position: 5760L, serial: 2U, },
      ],
    },
  ])
  let pages = match built {
    Ok(p) => p
    Err(_) => []
  }
  match plan_segment(pages, 16) {
    Ok(plan) => {
      assert_eq(plan.serial, 2U)
      assert_eq(plan.channels, 1)
      assert_eq(plan.estimated_bytes, 5760L * 10L)
    }
    Err(_) => assert_true(false)
  }
}

///|
/// 公开入口只接受 16/24 位，且拒绝负预算；否则格式块与实际字节会不一致。
test "pipeline rejects unsupported bits and negative budget" {
  let data = @ogg.serialize_pages(
    @ogg.paginate(
      [{ data: b"RandomJunk", granule_position: 0L, serial: 1U, }],
      1U,
    ),
  )
  let pages = @ogg.parse_pages(data)
  match ogg_to_wav_pages_bits(pages, 1024L, 8) {
    Err(msg) => assert_true(msg.contains("16 或 24"))
    Ok(_) => assert_true(false)
  }
  match ogg_to_wav_pages_bits(pages, -1L, 16) {
    Err(msg) => assert_true(msg.contains("预算"))
    Ok(_) => assert_true(false)
  }
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

///|
test "pipeline rejects bad page lists and budgets" {
  // 空页
  match ogg_to_wav_pages([], 1048576L) {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
  // 负数预算
  match ogg_to_wav_pages([], -1L) {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
  // 位深非法
  match ogg_to_wav_pages_bits([], 1048576L, 20) {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
  // 合法 Ogg 但预算极小：应报「超出预算」而不是写出空文件
  let stream = @ogg.serialize_pages(
    @ogg.paginate(
      [
        {
          data: b"OpusHead\x01\x01\x38\x01\x80\xbb\x00\x00\x00\x00\x00",
          granule_position: 0L,
          serial: 1U,
        },
        {
          data: b"OpusTags\x00\x00\x00\x00\x00\x00\x00\x00",
          granule_position: 0L,
          serial: 1U,
        },
      ],
      1U,
    ),
  )
  match ogg_to_wav_pages(@ogg.parse_pages(stream), 0L) {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
}

// ---------- F-PAR-01 回归：setup gate 覆盖第 2+ 个 codebook ----------

///|
/// 把 `value` 的低 `n` 位按 LSB-first 追加到 `bits`。
fn pv_push_bits(bits : Array[Int32], value : Int32, n : Int32) -> Unit {
  let mut i = 0
  while i < n {
    bits.push((value >> i) & 1)
    i = i + 1
  }
}

///|
fn pv_bits_to_bytes(bits : Array[Int32]) -> Bytes {
  let buf = Buffer()
  let mut cur = 0
  let mut cnt = 0
  for b in bits {
    if b != 0 {
      cur = cur | (1 << cnt)
    }
    cnt = cnt + 1
    if cnt == 8 {
      buf.write_byte(cur.to_byte())
      cur = 0
      cnt = 0
    }
  }
  if cnt > 0 {
    buf.write_byte(cur.to_byte())
  }
  buf.to_bytes()
}

///|
/// 354 B PoC 同构的恶意 setup：第 1 个 codebook 合法，第 2 个声明
/// dimensions=40000 / entries=256 / lookup_type=2（没有任何 lookup 位数据）。
fn vorbis_setup_second_codebook_oom() -> Bytes {
  let bits : Array[Int32] = []
  pv_push_bits(bits, 1, 8) // codebook 计数 - 1 = 1
  pv_push_bits(bits, 0x564342, 24)
  pv_push_bits(bits, 1, 16)
  pv_push_bits(bits, 1, 24)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 5)
  pv_push_bits(bits, 0, 4)
  pv_push_bits(bits, 0x564342, 24)
  pv_push_bits(bits, 40000, 16)
  pv_push_bits(bits, 256, 24)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 1)
  let mut i = 0
  while i < 256 {
    pv_push_bits(bits, 0, 5)
    i = i + 1
  }
  pv_push_bits(bits, 2, 4)
  pv_push_bits(bits, 0, 32)
  pv_push_bits(bits, 0, 32)
  pv_push_bits(bits, 15, 4)
  pv_push_bits(bits, 0, 1)
  let buf = Buffer()
  buf.write_bytes(b"\x05vorbis".exact_view())
  buf.write_bytes(pv_bits_to_bytes(bits).exact_view())
  buf.to_bytes()
}

///|
/// F-PAR-01 回归：第 2 个 codebook 的巨型 lookup 声明必须在解码前被拒绝，
/// 不能交给 moonvorbis（其 BitReader 越界读会造成 0xC0000005 崩溃）。
test "malicious vorbis setup in second codebook is rejected before decoding" {
  let packets : Array[@ogg.Packet] = [
    { data: vorbis_ident_packet(), granule_position: 0L, serial: 1U, },
    { data: vorbis_comment_packet(), granule_position: 0L, serial: 1U, },
    {
      data: vorbis_setup_second_codebook_oom(),
      granule_position: 0L,
      serial: 1U,
    },
    { data: b"\x00", granule_position: 1024L, serial: 1U, },
  ]
  let data = @ogg.serialize_pages(@ogg.paginate(packets, 1U))
  match ogg_to_wav_pages(@ogg.parse_pages(data), 1048576L) {
    Err(msg) => assert_true(msg.contains("setup"))
    Ok(_) => assert_true(false)
  }
}

// ---------- 第 2 轮（RT-A）：Vorbis 内存与 CPU 预算 ----------

///|
/// RT-A-04：granule 估算不是内存上界。构造「granule 很小、但 255 个音频包
/// ×200 声道」的流：旧实现按 granule 估算几百字节而放行（实测峰值 14.17 MiB）；
/// 新实现按逐包 block_size 推导输出样本上界（255×64×200×10 B ≈ 32.6 MiB），
/// 预算 1 MiB 时在解码前拒绝。
test "vorbis memory bound uses packet work, not granule (RT-A-04)" {
  let packets : Array[@ogg.Packet] = [
    {
      data: vorbis_ident_packet_ex(200, 6, 6),
      granule_position: 0L,
      serial: 1U,
    },
    { data: vorbis_comment_packet(), granule_position: 0L, serial: 1U, },
    { data: vorbis_setup_full(0), granule_position: 0L, serial: 1U, },
  ]
  let mut i = 0
  while i < 255 {
    packets.push({
      data: b"\x00",
      granule_position: 64L * (i + 1).to_int64(),
      serial: 1U,
    })
    i = i + 1
  }
  let pages = pages_of(packets)
  match ogg_to_wav_pages(pages, 1048576L) {
    Err(msg) => {
      assert_true(msg.contains("预算"))
      assert_true(msg.contains("MiB"))
    }
    Ok(_) => assert_true(false)
  }
  // 同样的流用默认预算时，plan 给出的估算必须是逐包工作量的上界，
  // 而不是 granule（64 帧）级别的几百字节。
  match plan_segment(pages, 16) {
    Ok(plan) => assert_true(plan.estimated_bytes >= 255L * 64L * 200L * 10L)
    Err(msg) => abort("内存上界在合法 Vorbis 流上误拒: " + msg)
  }
}

///|
/// RT-A-05：Vorbis IMDCT 是 O(block_size²) 的 cos 调用。239 B 级输入声明
/// 2 个 8192 长块，旧实现要跑 ~28.9 s；新实现按
/// 「工作量 ≤ max(输入字节×12 万, 3200 万)」在解码前拒绝。
test "vorbis cpu work budget rejects tiny input with huge imdct (RT-A-05)" {
  let packets : Array[@ogg.Packet] = [
    {
      data: vorbis_ident_packet_ex(1, 6, 13),
      granule_position: 0L,
      serial: 1U,
    },
    { data: vorbis_comment_packet(), granule_position: 0L, serial: 1U, },
    { data: vorbis_setup_full(1), granule_position: 0L, serial: 1U, },
    { data: b"\x00", granule_position: 0L, serial: 1U, },
    { data: b"\x00", granule_position: 8000L, serial: 1U, },
  ]
  let pages = pages_of(packets)
  // 内存上界（16 KiB）远小于 256 MiB：必须在 CPU 预算处失败，而不是内存处。
  match ogg_to_wav_pages(pages, 268435456L) {
    Err(msg) => assert_true(msg.contains("工作量"))
    Ok(_) => assert_true(false)
  }
}

///|
/// 正向对照：真实形态的 45 个长块（2048）立体声包，工作量约 1.89 亿次，
/// 输入约 1.9 KB —— 放大比低于 12 万/字节，预算必须放行（不误伤正常流）。
test "vorbis cpu work budget accepts a realistic long-block stream" {
  let packets : Array[@ogg.Packet] = [
    { data: vorbis_ident_packet(), granule_position: 0L, serial: 1U, },
    { data: vorbis_comment_packet(), granule_position: 0L, serial: 1U, },
    { data: vorbis_setup_full(1), granule_position: 0L, serial: 1U, },
  ]
  let payload_buf = Buffer()
  let mut k = 0
  while k < 128 {
    payload_buf.write_byte((0 : Byte))
    k = k + 1
  }
  let payload = payload_buf.to_bytes()
  let mut i = 0
  while i < 45 {
    packets.push({
      data: payload,
      granule_position: 1024L * (i + 1).to_int64(),
      serial: 1U,
    })
    i = i + 1
  }
  let pages = pages_of(packets)
  match plan_segment(pages, 16) {
    Ok(plan) => {
      assert_eq(plan.channels, 2)
      // 上界 = 45 包 × 2048 样本 × 2 声道 × 10 B，远大于 granule 推算值。
      assert_true(plan.estimated_bytes >= 45L * 2048L * 2L * 10L)
    }
    Err(msg) => abort("真实形态的长块流被 CPU 预算误拒: " + msg)
  }
}

///|
/// 音频包必须是「packet type=0 + 合法 mode 号」；截断或 header 包出现在
/// 音频位置时在解码前拒绝（不能把不确定的包交给 moonvorbis）。
test "vorbis audio packet mode field is validated before decoding" {
  // 音频位置放一个 header 包（bit0 = 1）
  let packets : Array[@ogg.Packet] = [
    { data: vorbis_ident_packet(), granule_position: 0L, serial: 1U, },
    { data: vorbis_comment_packet(), granule_position: 0L, serial: 1U, },
    { data: vorbis_setup_full(0), granule_position: 0L, serial: 1U, },
    { data: b"\x01", granule_position: 8000L, serial: 1U, },
  ]
  match plan_segment(pages_of(packets), 16) {
    Err(msg) => assert_true(msg.contains("mode 字段"))
    Ok(_) => assert_true(false)
  }
  // 空音频包
  let packets2 : Array[@ogg.Packet] = [
    { data: vorbis_ident_packet(), granule_position: 0L, serial: 1U, },
    { data: vorbis_comment_packet(), granule_position: 0L, serial: 1U, },
    { data: vorbis_setup_full(0), granule_position: 0L, serial: 1U, },
    { data: b"", granule_position: 8000L, serial: 1U, },
  ]
  match plan_segment(pages_of(packets2), 16) {
    Err(msg) => assert_true(msg.contains("mode 字段"))
    Ok(_) => assert_true(false)
  }
}

// ---------- 第 3 轮（RT3）：lookup 展开内存与 Huffman CPU 预算 ----------

///|
/// 2 个 `lookup_type=1, dimensions=16, entries=65536` 的 ordered codebook
/// （setup 只有 ~90 字节，但解码器会为每个展开 65536×16 个 Float，两个约 11 MB）。
fn vorbis_setup_big_lookup() -> Bytes {
  let bits : Array[Int32] = []
  pv_push_bits(bits, 1, 8) // 2 个 codebook
  let mut cb = 0
  while cb < 2 {
    pv_push_bits(bits, 0x564342, 24)
    pv_push_bits(bits, 16, 16) // dimensions = 16（raw）
    pv_push_bits(bits, 65536, 24)
    pv_push_bits(bits, 1, 1) // ordered
    pv_push_bits(bits, 0, 5) // 起始码长 1
    pv_push_bits(bits, 65535, 17) // 65535 个 length=1
    pv_push_bits(bits, 1, 1) // 1 个 length=2
    pv_push_bits(bits, 1, 4) // lookup_type = 1
    pv_push_bits(bits, 0, 32)
    pv_push_bits(bits, 0, 32)
    pv_push_bits(bits, 0, 4) // value_bits = 1
    pv_push_bits(bits, 0, 1)
    pv_push_bits(bits, 0, 2) // raw = lookup1_values(65536,16) = 2
    cb = cb + 1
  }
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 0, 16)
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 1, 16)
  pv_push_bits(bits, 0, 5)
  pv_push_bits(bits, 0, 2)
  pv_push_bits(bits, 0, 4)
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 1, 16)
  pv_push_bits(bits, 0, 24)
  pv_push_bits(bits, 0, 24)
  pv_push_bits(bits, 0, 24)
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 0, 3)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 0, 16)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 2)
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 16)
  pv_push_bits(bits, 0, 16)
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 1, 1)
  let buf = Buffer()
  buf.write_bytes(b"\x05vorbis".exact_view())
  buf.write_bytes(pv_bits_to_bytes(bits).exact_view())
  buf.to_bytes()
}

///|
/// 一个 1M 码字、最长码长 21 的 ordered codebook（bits 只有几百），
/// 模拟 RT3-02 的「Huffman 线性查表 CPU 放大」setup。
fn vorbis_setup_huffman_scan() -> Bytes {
  let bits : Array[Int32] = []
  pv_push_bits(bits, 0, 8) // 1 个 codebook
  pv_push_bits(bits, 0x564342, 24)
  pv_push_bits(bits, 1, 16) // dimensions = 1
  pv_push_bits(bits, 1048576, 24)
  pv_push_bits(bits, 1, 1) // ordered
  pv_push_bits(bits, 0, 5) // 起始码长 1
  let mut z = 1
  while z < 20 {
    pv_push_bits(bits, 0, 21) // 空游程，码长 +1
    z = z + 1
  }
  pv_push_bits(bits, 1048575, 21) // 1048575 个 length=20
  pv_push_bits(bits, 1, 1) // 1 个 length=21
  pv_push_bits(bits, 0, 4) // lookup_type = 0
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 0, 16)
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 1, 16)
  pv_push_bits(bits, 0, 5)
  pv_push_bits(bits, 0, 2)
  pv_push_bits(bits, 0, 4)
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 0, 16) // residue type 0
  pv_push_bits(bits, 0, 24) // begin 0
  pv_push_bits(bits, 32, 24) // end 32
  pv_push_bits(bits, 0, 24) // partition_size 1
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 0, 8) // classbook 0
  pv_push_bits(bits, 0, 3)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 0, 16)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 2)
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 16)
  pv_push_bits(bits, 0, 16)
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 1, 1)
  let buf = Buffer()
  buf.write_bytes(b"\x05vorbis".exact_view())
  buf.write_bytes(pv_bits_to_bytes(bits).exact_view())
  buf.to_bytes()
}

///|
/// RT3-01：lookup_type=1 的 entries×dimensions 展开内存必须计入内存预算。
/// 该 setup 的 codebook 展开约 11 MB，而输入只有几十字节。
test "vorbis memory budget includes lookup type1 expansion (RT3-01)" {
  let packets : Array[@ogg.Packet] = [
    {
      data: vorbis_ident_packet_ex(1, 8, 11),
      granule_position: 0L,
      serial: 1U,
    },
    { data: vorbis_comment_packet(), granule_position: 0L, serial: 1U, },
    { data: vorbis_setup_big_lookup(), granule_position: 0L, serial: 1U, },
    { data: b"\x00", granule_position: 8000L, serial: 1U, },
  ]
  let pages = pages_of(packets)
  // 预算 1 MiB：仅 codebook 展开就约 11 MB → 必须在解码前拒绝
  match ogg_to_wav_pages(pages, 1048576L) {
    Err(msg) => assert_true(msg.contains("预算"))
    Ok(_) => assert_true(false)
  }
  // plan 的估算必须包含 setup 分配上界（否则就是 RT3-01 的绕过）
  match plan_segment(pages, 16) {
    Ok(plan) => assert_true(plan.estimated_bytes >= 11010176L)
    Err(msg) => abort("合法的 lookup type1 setup 被误拒: " + msg)
  }
}

///|
/// RT3-02：CPU 预算必须包含 Huffman 线性查表成本（符号数 × 最长码长 ×
/// 有效码字数），否则 677 B 输入可跑 26 s。该 setup 单符号成本 ≈ 2200 万。
test "vorbis cpu budget includes huffman linear scan (RT3-02)" {
  let packets : Array[@ogg.Packet] = [
    { data: vorbis_ident_packet_ex(1, 6, 6), granule_position: 0L, serial: 1U, },
    { data: vorbis_comment_packet(), granule_position: 0L, serial: 1U, },
    { data: vorbis_setup_huffman_scan(), granule_position: 0L, serial: 1U, },
    { data: b"\x00", granule_position: 64L, serial: 1U, },
    { data: b"\x00", granule_position: 128L, serial: 1U, },
  ]
  match plan_segment(pages_of(packets), 16) {
    Err(msg) => assert_true(msg.contains("工作量"))
    Ok(_) => assert_true(false)
  }
}

///|
/// RT3-03：426 B / 1×8192 长块（≈8.65 s CPU）必须被收紧后的预算拒绝；
/// 真实样本（约 5.4 万 work/字节）仍放行由 CLI 端到端验证。
test "vorbis cpu budget rejects the single 8192-block boundary (RT3-03)" {
  let packets : Array[@ogg.Packet] = [
    {
      data: vorbis_ident_packet_ex(1, 6, 13),
      granule_position: 0L,
      serial: 1U,
    },
    { data: vorbis_comment_packet(), granule_position: 0L, serial: 1U, },
    { data: vorbis_setup_full(1), granule_position: 0L, serial: 1U, },
    { data: b"\x00", granule_position: 8192L, serial: 1U, },
  ]
  match plan_segment(pages_of(packets), 16) {
    Err(msg) => assert_true(msg.contains("工作量"))
    Ok(_) => assert_true(false)
  }
}

// ---------- 第 5 轮（RT4）：residue VQ 符号数与双预算标定 ----------

///|
/// RT4-01 g9 同构构造：residue type0、ps=4096、VQ 书 dims=16、cascade 8 pass。
/// 每包实际 VQ 符号数 = 8 × (4096/16) = 2048；旧公式只算 8 个。
fn vorbis_setup_rt4_vq() -> Bytes {
  let bits : Array[Int32] = []
  pv_push_bits(bits, 1, 8) // 2 个 codebook
  // cb0：标量 classbook d1/e1
  pv_push_bits(bits, 0x564342, 24)
  pv_push_bits(bits, 1, 16)
  pv_push_bits(bits, 1, 24)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 5)
  pv_push_bits(bits, 0, 4)
  // cb1：ordered d16/e1048576，前 1048575 条码长 20、最后 1 条 21
  pv_push_bits(bits, 0x564342, 24)
  pv_push_bits(bits, 16, 16)
  pv_push_bits(bits, 1048576, 24)
  pv_push_bits(bits, 1, 1) // ordered
  pv_push_bits(bits, 0, 5) // 起始码长 1
  let mut z = 1
  while z < 20 {
    pv_push_bits(bits, 0, 21)
    z = z + 1
  }
  pv_push_bits(bits, 1048575, 21)
  pv_push_bits(bits, 1, 1) // 第 1048576 条（码长 21）
  pv_push_bits(bits, 1, 4) // lookup_type 1
  pv_push_bits(bits, 0, 32)
  pv_push_bits(bits, 0, 32)
  pv_push_bits(bits, 0, 4) // value_bits 1
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 2) // raw = lookup1_values(1048576,16) = 2
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 0, 16)
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 1, 16)
  pv_push_bits(bits, 0, 5)
  pv_push_bits(bits, 0, 2)
  pv_push_bits(bits, 0, 4)
  // residue type0：begin 0、end 4096、ps 4096、cascade 8 pass 全引用 book1
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 0, 16)
  pv_push_bits(bits, 0, 24)
  pv_push_bits(bits, 4096, 24)
  pv_push_bits(bits, 4095, 24)
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 7, 3)
  pv_push_bits(bits, 1, 1)
  pv_push_bits(bits, 31, 5)
  let mut k = 0
  while k < 8 {
    pv_push_bits(bits, 1, 8)
    k = k + 1
  }
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 0, 16)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 2)
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 1, 1) // blockflag = 1 → 8192
  pv_push_bits(bits, 0, 16)
  pv_push_bits(bits, 0, 16)
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 1, 1)
  let buf = Buffer()
  buf.write_bytes(b"\x05vorbis".exact_view())
  buf.write_bytes(pv_bits_to_bytes(bits).exact_view())
  buf.to_bytes()
}

///|
/// 真实样本量级的合法构建：45 个 2048 长块、residue type2/ps32/VQ dims2，
/// 字符数上界 ≈ 639K、输入 ≈ 8 KB —— 用来断言 CPU 双预算放行（避免 97 s 解码）。
fn vorbis_setup_real_shaped() -> Bytes {
  let bits : Array[Int32] = []
  pv_push_bits(bits, 1, 8)
  // cb0：标量 classbook d1/e1
  pv_push_bits(bits, 0x564342, 24)
  pv_push_bits(bits, 1, 16)
  pv_push_bits(bits, 1, 24)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 5)
  pv_push_bits(bits, 0, 4)
  // cb1：ordered d2/e255、码长全 21（active=255、maxlen=21 → scan 5355）
  pv_push_bits(bits, 0x564342, 24)
  pv_push_bits(bits, 2, 16)
  pv_push_bits(bits, 255, 24)
  pv_push_bits(bits, 1, 1)
  pv_push_bits(bits, 0, 5)
  let mut z = 1
  while z < 21 {
    pv_push_bits(bits, 0, 8)
    z = z + 1
  }
  pv_push_bits(bits, 255, 8)
  pv_push_bits(bits, 0, 4)
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 0, 16)
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 1, 16)
  pv_push_bits(bits, 0, 5)
  pv_push_bits(bits, 0, 2)
  pv_push_bits(bits, 0, 4)
  // residue type2：begin 0、end 1760、ps 32、cascade 8 pass 全引用 book1
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 2, 16)
  pv_push_bits(bits, 0, 24)
  pv_push_bits(bits, 1760, 24)
  pv_push_bits(bits, 31, 24)
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 7, 3)
  pv_push_bits(bits, 1, 1)
  pv_push_bits(bits, 31, 5)
  let mut k = 0
  while k < 8 {
    pv_push_bits(bits, 1, 8)
    k = k + 1
  }
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 0, 16)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 1)
  pv_push_bits(bits, 0, 2)
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 0, 6)
  pv_push_bits(bits, 1, 1) // blockflag = 1 → 2048
  pv_push_bits(bits, 0, 16)
  pv_push_bits(bits, 0, 16)
  pv_push_bits(bits, 0, 8)
  pv_push_bits(bits, 1, 1)
  let buf = Buffer()
  buf.write_bytes(b"\x05vorbis".exact_view())
  buf.write_bytes(pv_bits_to_bytes(bits).exact_view())
  buf.to_bytes()
}

///|
/// RT4-01：6.5 KB 构造（8 pass × ps4096/dims16）必须被 Huffman 预算拒绝，
/// 不能像 gate v3 那样放行后跑数分钟。
test "vorbis cpu budget rejects residue VQ symbol undercount (RT4-01)" {
  // 给音频包足够体积（2 KB），让 IMDCT 预算（按输入字节）先放行，
  // 从而真正命中 Huffman/VQ 符号数分支；真实 g9 PoC 亦为此量级。
  let audio_buf = Buffer()
  let mut ai = 0
  while ai < 2048 {
    audio_buf.write_byte((0 : Byte))
    ai = ai + 1
  }
  let audio = audio_buf.to_bytes()
  let packets : Array[@ogg.Packet] = [
    {
      data: vorbis_ident_packet_ex(1, 13, 13),
      granule_position: 0L,
      serial: 1U,
    },
    { data: vorbis_comment_packet(), granule_position: 0L, serial: 1U, },
    { data: vorbis_setup_rt4_vq(), granule_position: 0L, serial: 1U, },
    { data: audio, granule_position: 8192L, serial: 1U, },
  ]
  match plan_segment(pages_of(packets), 16) {
    Err(msg) => {
      assert_true(msg.contains("Huffman"))
      assert_true(msg.contains("工作量"))
    }
    Ok(_) => assert_true(false)
  }
}

///|
/// 与真实样本同量级的合法构建：双预算（IMDCT 1.43×、Huffman 1.49×）必须放行，
/// 避免把 97 s 的真实 benchmark 用例塞进单测。
test "vorbis cpu budgets accept a realistic-magnitude stream" {
  let packets : Array[@ogg.Packet] = [
    {
      data: vorbis_ident_packet_ex(2, 8, 11),
      granule_position: 0L,
      serial: 1U,
    },
    { data: vorbis_comment_packet(), granule_position: 0L, serial: 1U, },
    { data: vorbis_setup_real_shaped(), granule_position: 0L, serial: 1U, },
  ]
  let payload_buf = Buffer()
  let mut k = 0
  while k < 150 {
    payload_buf.write_byte((0 : Byte))
    k = k + 1
  }
  let payload = payload_buf.to_bytes()
  let mut i = 0
  while i < 45 {
    packets.push({
      data: payload,
      granule_position: 1024L * (i + 1).to_int64(),
      serial: 1U,
    })
    i = i + 1
  }
  match plan_segment(pages_of(packets), 16) {
    Ok(plan) => {
      assert_eq(plan.channels, 2)
      assert_true(plan.estimated_bytes > 0L)
    }
    Err(msg) =>
      abort("真实量级的合法 Vorbis 流被 CPU 预算误拒: " + msg)
  }
}
