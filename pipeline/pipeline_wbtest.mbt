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
/// 能通过最小 setup 预检的 Vorbis setup 头（第 1 个 codebook 为 ordered，
/// 预检对 ordered 码本只做前缀/边界检查，不解析变长游程）。
fn vorbis_setup_ordered() -> Bytes {
  b"\x05vorbis\x00\x42\x43\x56\x00\x00\x00\x00\x00\x01"
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
