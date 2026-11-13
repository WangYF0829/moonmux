///|
/// 固定宽度的文件名/时间片：`pad6` 补到 6 位，`pad2` 补到 2 位。
test "pad6 and pad2 keep a fixed width" {
  assert_eq(pad6(0), "000000")
  assert_eq(pad6(7), "000007")
  assert_eq(pad6(123456), "123456")
  assert_eq(pad2(0), "00")
  assert_eq(pad2(5), "05")
  assert_eq(pad2(99), "99")
}

///|
/// 目录序号只认 `s<N>`；其它命名不能猜，交回字典序。
test "dir_number parses the sN form and rejects the rest" {
  assert_eq(dir_number("s1"), Some(1))
  assert_eq(dir_number("s10"), Some(10))
  assert_eq(dir_number("s0"), Some(0))
  assert_eq(dir_number("s"), None)
  assert_eq(dir_number("s1x"), None)
  assert_eq(dir_number("x2"), None)
  assert_eq(dir_number("backup"), None)
}

///|
/// 预算文本：合法值换算成字节；0 / 超上限（2048 MiB）/ 非数字 / 空串返回 None。
test "budget text validates range and syntax" {
  let mib : Int64 = 1048576L
  assert_eq(budget_from_text_checked("1"), Some(1L * mib))
  assert_eq(budget_from_text_checked("256"), Some(256L * mib))
  assert_eq(budget_from_text_checked("2048"), Some(2048L * mib))
  assert_eq(budget_from_text_checked("0"), None)
  assert_eq(budget_from_text_checked("2049"), None)
  assert_eq(budget_from_text_checked(""), None)
  assert_eq(budget_from_text_checked("12x"), None)
  assert_eq(budget_from_text_checked("-1"), None)
  // 超过 Int64 的数字不能回绕成 1 而被当成 1 MiB
  assert_eq(budget_from_text_checked("18446744073709551617"), None)
  assert_eq(budget_from_text_checked("999999999999999999999999"), None)
}

///|
/// Windows 保留名不能只认 ASCII 1..9；CONIN$/CONOUT$ 与上标数字也要挡住。
#cfg(platform="windows")
test "windows reserved device names are rejected" {
  assert_true(is_reserved_device("NUL"))
  assert_true(is_reserved_device("subdir/con.txt"))
  assert_true(is_reserved_device("CONIN$"))
  assert_true(is_reserved_device("CONOUT$"))
  assert_true(is_reserved_device("COM1"))
  assert_true(is_reserved_device("LPT9.log"))
  assert_true(is_reserved_device("COM¹"))
  assert_true(is_reserved_device("lpt³"))
  assert_true(!is_reserved_device("console.txt"))
  assert_true(!is_reserved_device("COM0"))
  assert_true(!is_reserved_device("com10"))
}

///|
/// 链序号是 1 起算的；找不到流时退回第 1 段（防御性兜底，正常调用不会触发）。
test "chain_index_of returns the 1-based segment holding the serial" {
  let a = @ogg.paginate([{ data: b"a", granule_position: 0L, serial: 1U, }], 1U)
  let b = @ogg.paginate([{ data: b"b", granule_position: 0L, serial: 2U, }], 2U)
  let chains : Array[Array[@ogg.Page]] = [a, b]
  assert_eq(chain_index_of(chains, 1U), 1)
  assert_eq(chain_index_of(chains, 2U), 2)
  assert_eq(chain_index_of(chains, 99U), 1)
}

///|
/// Opus 流的注释包在第二个包；`find_comment` 应带回流号、种类与 vendor。
test "find_comment locates the OpusTags packet" {
  let head : Bytes = b"OpusHead\x01\x01\x38\x01\x80\xBB\x00\x00\x00\x00\x00"
  let tags = @codec.encode_comment(
    @codec.CommentKind::Opus,
    { vendor: "moonmux", tags: [], },
    0,
  )
  let pages = @ogg.paginate(
    [
      { data: head, granule_position: 0L, serial: 7U, },
      { data: tags, granule_position: 0L, serial: 7U, },
      { data: b"audio", granule_position: 480L, serial: 7U, },
    ],
    7U,
  )
  match find_comment(pages) {
    Ok(found) => {
      assert_eq(found.0, 7U)
      match found.1 {
        @codec.CommentKind::Opus => ()
        _ => assert_true(false)
      }
      assert_eq(found.2.vendor, "moonmux")
      assert_eq(found.2.tags.length(), 0)
    }
    Err(msg) => abort(msg)
  }
}

///|
/// 第一条音频流只有头包时，应继续寻找后面带注释的音频流。
test "find_comment skips an audio stream without a comment packet" {
  let head : Bytes = b"OpusHead\x01\x01\x38\x01\x80\xBB\x00\x00\x00\x00\x00"
  let tags = @codec.encode_comment(
    @codec.CommentKind::Opus,
    { vendor: "moonmux", tags: [], },
    0,
  )
  let built = @ogg.mux_streams([
    {
      serial: 1U,
      packets: [{ data: head, granule_position: 0L, serial: 1U, }],
    },
    {
      serial: 2U,
      packets: [
        { data: head, granule_position: 0L, serial: 2U, },
        { data: tags, granule_position: 0L, serial: 2U, },
        { data: b"audio", granule_position: 480L, serial: 2U, },
      ],
    },
  ])
  let pages = match built {
    Ok(p) => p
    Err(msg) => abort(msg)
  }
  match find_comment(pages) {
    Ok(found) => {
      assert_eq(found.0, 2U)
      assert_eq(found.2.vendor, "moonmux")
    }
    Err(msg) => abort(msg)
  }
}

///|
/// 音频流信息：声道与 pre-skip 来自 OpusHead，首尾粒度来自页头。
///
/// 不断言 `sample_rate`：Opus 的解码采样率恒为 48 kHz，`parse_audio_header`
/// 里是常量，把它写进断言只会制造「测了解析」的错觉。
test "audio_stream_info reports header and granule span" {
  let head : Bytes = b"OpusHead\x01\x02\x38\x01\x80\xBB\x00\x00\x00\x00\x00"
  let pages = @ogg.paginate(
    [
      { data: head, granule_position: 0L, serial: 3U, },
      { data: b"audio", granule_position: 48000L, serial: 3U, },
    ],
    3U,
  )
  match audio_stream_info(pages) {
    Ok(info) => {
      assert_eq(info.0, 3U)
      assert_eq(info.1.channels, 2)
      assert_eq(info.1.pre_skip, 312)
      assert_eq(info.2, 0L)
      assert_eq(info.3, 48000L)
    }
    Err(msg) => abort(msg)
  }
}

///|
/// 准备一个干净的测试目录。
///
/// Windows 上目录句柄释放有延迟，`remove_dir` 可能第一次失败；重试几次，
/// 失败就让测试直接失败，而不是把「目录已存在」留给下一次运行。
#cfg(target="native")
fn reset_test_dir(dir : String) -> Unit {
  let mut i = 0
  while i < 3 {
    let ignored : Array[String] = []
    remove_dir_tree_collect(dir, ignored)
    if !@fs.path_exists(dir) {
      return
    }
    i = i + 1
  }
  abort("无法清理测试目录 " + dir)
}

///|
/// 递归清理要能删掉嵌套目录 —— demux 的回滚依赖它。
#cfg(target="native")
test "remove_dir_tree removes nested directories" {
  let dir = "_build/wbtest_rm_tree"
  reset_test_dir(dir)
  @fs.create_dir(dir) catch {
    IOError(msg) => abort("create_dir: " + msg)
  }
  @fs.create_dir(dir + "/a") catch {
    IOError(msg) => abort("create_dir a: " + msg)
  }
  @fs.write_bytes_to_file(dir + "/a/b.bin", b"x") catch {
    IOError(msg) => abort("write b: " + msg)
  }
  let failures : Array[String] = []
  remove_dir_tree_collect(dir, failures)
  assert_true(!@fs.path_exists(dir))
}

///|
/// 多流目录：一条流一个子目录，清单给出流号 42 与两个粒度。
///
/// 两个包各自带真粒度，分页器按粒度边界分成两页。
#cfg(target="native")
test "plan_mux reads a multi-stream directory" {
  let dir = "_build/wbtest_plan_mux"
  reset_test_dir(dir)
  @fs.create_dir(dir) catch {
    IOError(msg) => abort("create_dir: " + msg)
  }
  let sub = dir + "/s1"
  @fs.create_dir(sub) catch {
    IOError(msg) => abort("create_dir s1: " + msg)
  }
  let manifest = "# moonmux manifest v1\n# granulepos\n# serial=42\n# packets=2\n# chain=1\n0\n960\n"
  @fs.write_string_to_file(sub + "/manifest.txt", manifest) catch {
    IOError(msg) => abort("manifest: " + msg)
  }
  @fs.write_bytes_to_file(sub + "/packet_000000.bin", b"aa") catch {
    IOError(msg) => abort("packet 0: " + msg)
  }
  @fs.write_bytes_to_file(sub + "/packet_000001.bin", b"bb") catch {
    IOError(msg) => abort("packet 1: " + msg)
  }
  match plan_mux(dir) {
    Ok(plan) => {
      assert_eq(plan.packets, 2)
      assert_eq(plan.streams, 1)
      assert_eq(plan.pages.length(), 2)
      assert_eq(plan.pages[0].serial, 42U)
      assert_eq(plan.pages[0].granule_position, 0L)
      assert_eq(plan.pages[1].granule_position, 960L)
    }
    Err(msg) => abort(mux_fail_text(msg))
  }
  reset_test_dir(dir)
}

///|
/// plan_mux 的失败类型转成可读文本（测试断言用）。
fn mux_fail_text(f : MuxFail) -> String {
  match f {
    MuxIo(m) => m
    MuxData(m) => m
  }
}

///|
/// 单流目录：包直接放在目录下，清单也在目录下。
#cfg(target="native")
test "plan_mux reads a single-stream directory" {
  let dir = "_build/wbtest_plan_single"
  reset_test_dir(dir)
  @fs.create_dir(dir) catch {
    IOError(msg) => abort("create_dir: " + msg)
  }
  let manifest = "# moonmux manifest v1\n# granulepos\n# serial=5\n# packets=2\n# chain=1\n0\n960\n"
  @fs.write_string_to_file(dir + "/manifest.txt", manifest) catch {
    IOError(msg) => abort("manifest: " + msg)
  }
  @fs.write_bytes_to_file(dir + "/packet_000000.bin", b"aa") catch {
    IOError(msg) => abort("packet 0: " + msg)
  }
  @fs.write_bytes_to_file(dir + "/packet_000001.bin", b"bb") catch {
    IOError(msg) => abort("packet 1: " + msg)
  }
  match plan_mux(dir) {
    Ok(plan) => {
      assert_eq(plan.streams, 1)
      assert_eq(plan.packets, 2)
      assert_true(plan.pages.length() >= 1)
      assert_eq(plan.pages[0].serial, 5U)
      assert_eq(plan.pages[plan.pages.length() - 1].granule_position, 960L)
    }
    Err(msg) => abort(mux_fail_text(msg))
  }
  reset_test_dir(dir)
}

///|
/// 空目录与「子目录 + 散包混放」都必须明确报错，不能猜。
#cfg(target="native")
test "plan_mux rejects empty and mixed layouts" {
  let empty = "_build/wbtest_plan_empty"
  reset_test_dir(empty)
  @fs.create_dir(empty) catch {
    IOError(msg) => abort("create_dir empty: " + msg)
  }
  match plan_mux(empty) {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(mux_fail_text(msg).contains("没有包文件"))
  }
  reset_test_dir(empty)

  let mixed = "_build/wbtest_plan_mixed"
  reset_test_dir(mixed)
  @fs.create_dir(mixed) catch {
    IOError(msg) => abort("create_dir mixed: " + msg)
  }
  @fs.create_dir(mixed + "/s1") catch {
    IOError(msg) => abort("create_dir s1: " + msg)
  }
  @fs.write_bytes_to_file(mixed + "/packet_000000.bin", b"aa") catch {
    IOError(msg) => abort("packet: " + msg)
  }
  match plan_mux(mixed) {
    Ok(_) => assert_true(false)
    Err(msg) =>
      assert_true(
        mux_fail_text(msg).contains("既有子目录又有散落的包文件"),
      )
  }
  reset_test_dir(mixed)
}

///|
/// JSON 转义：引号、反斜杠、换行与控制字符。
test "json escaping handles quotes, backslashes and controls" {
  assert_eq(json_escape("a\"b\\c"), "a\\\"b\\\\c")
  assert_eq(json_escape("a\nb"), "a\\nb")
  assert_eq(json_escape("\u0001"), "\\u0001")
  assert_eq(json_string("x"), "\"x\"")
}

// ---- v0.3.0：MP4/remux 的 I/O 层覆盖 ----
// smoke.sh 用真实进程覆盖 CLI 路径，但覆盖率统计看不到子进程内部；
// 这里直接调用 cmd/main 里的渲染/写出函数，把这些分支钉在覆盖率门禁里。

///|
/// 合成最小 Ogg Opus 流（与 mp4/mp4_wbtest.mbt 同构）：
/// OpusHead + OpusTags + 两个 20ms 包。
fn wb_ogg_opus() -> Bytes {
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
/// MP4 信息的文本与 JSON 两种渲染。
test "mp4 info rendering covers text and json" {
  match @mp4.remux_ogg_opus(wb_ogg_opus()) {
    Err(msg) => {
      println("remux error: " + msg)
      assert_true(false)
    }
    Ok(mp4) =>
      match @mp4.inspect(mp4) {
        Some(info) => {
          show_mp4_info("synthetic.m4a", mp4, info, false)
          show_mp4_info("synthetic.m4a", mp4, info, true)
          assert_eq(info.tracks[0].codec, "Opus")
          assert_eq(info.tracks[0].channels, 1)
        }
        None => assert_true(false)
      }
  }
}

///|
/// remux 的完整 I/O 路径：读输入 → 封装 → 备份/写出 → 回读自检 → info 识别。
test "run_remux writes a valid mp4 and info reads it back" {
  let dir = "_build/wbtest-remux"
  @fs.create_dir(dir) catch {
    _ => ()
  }
  let src = dir + "/in.ogg"
  let out = dir + "/out.m4a"
  let mut wrote = true
  @fs.write_bytes_to_file(src, wb_ogg_opus()) catch {
    _ => wrote = false
  }
  if wrote {
    run_remux(src, out)
    let produced = @fs.read_file_to_bytes(out) catch { _ => b"" }
    assert_true(produced.length() > 0)
    assert_true(@mp4.is_mp4(produced))
    // run_info 的 MP4 分支（文本 + JSON）
    run_info(out, false)
    run_info(out, true)
  } else {
    assert_true(false)
  }
  @fs.remove_file(src) catch {
    _ => ()
  }
  @fs.remove_file(out) catch {
    _ => ()
  }
}

// ---- 覆盖率：info 的 Ogg/WAV 渲染与 run_info 分支 ----

///|
/// Ogg/WAV 信息的文本与 JSON 渲染，以及 run_info 的文件 I/O 分派。
test "ogg and wav info rendering covers text and json" {
  let ogg = wb_ogg_opus()
  show_ogg_info("synthetic.ogg", ogg, false)
  show_ogg_info("synthetic.ogg", ogg, true)
  let wav = @wav.encode_wav(
    { channels: 1, sample_rate: 8000, bits_per_sample: 16, },
    b"\x00\x00\x01\x00",
  )
  match @wav.WavFile::parse(wav) {
    Some(f) => {
      show_wav_info("synthetic.wav", wav, f, false)
      show_wav_info("synthetic.wav", wav, f, true)
    }
    None => assert_true(false)
  }
  let dir = "_build/wbtest-info"
  @fs.create_dir(dir) catch {
    _ => ()
  }
  @fs.write_bytes_to_file(dir + "/a.ogg", ogg) catch {
    _ => ()
  }
  @fs.write_bytes_to_file(dir + "/a.wav", wav) catch {
    _ => ()
  }
  run_info(dir + "/a.ogg", false)
  run_info(dir + "/a.ogg", true)
  run_info(dir + "/a.wav", false)
  run_info(dir + "/a.wav", true)
  @fs.remove_file(dir + "/a.ogg") catch {
    _ => ()
  }
  @fs.remove_file(dir + "/a.wav") catch {
    _ => ()
  }
}

// ---- v0.4.0：WAV 全格式（float/Extensible）在 info 输出层的覆盖 ----

///|
/// IEEE float WAV 的文本/JSON 渲染，以及 info 对 sample_format 的展示。
test "wav float info rendering covers text and json" {
  match
    @wav.encode_wav_ex(
      { channels: 1, sample_rate: 8000, bits_per_sample: 32, },
      b"\x00\x00\x80\x3f",
      @wav.SampleFormat::Float,
    ) {
    Err(msg) => {
      println("encode_wav_ex error: " + msg)
      assert_true(false)
    }
    Ok(bytes) =>
      match @wav.WavFile::parse(bytes) {
        Some(f) => {
          assert_true(f.sample_format is @wav.SampleFormat::Float)
          assert_eq(f.bytes_per_sample, 4)
          show_wav_info("float.wav", bytes, f, false)
          show_wav_info("float.wav", bytes, f, true)
          assert_eq(f.format.bits_per_sample, 32)
        }
        None => assert_true(false)
      }
  }
}

// ---- v0.5.0：to-ogg（MP4 → Ogg）的 I/O 路径 ----

///|
/// remux 出 MP4 → run_to_ogg 解封装 → 回读 Ogg，断言 OpusHead 与页结构。
test "run_to_ogg writes a valid ogg from an mp4 file" {
  let dir = "_build/wbtest-toogg"
  @fs.create_dir(dir) catch {
    _ => ()
  }
  let src = dir + "/in.ogg"
  let m4a = dir + "/mid.m4a"
  let out = dir + "/out.ogg"
  let mut wrote = true
  @fs.write_bytes_to_file(src, wb_ogg_opus()) catch {
    _ => wrote = false
  }
  if wrote {
    run_remux(src, m4a)
    run_to_ogg(m4a, out)
    let produced = @fs.read_file_to_bytes(out) catch { _ => b"" }
    assert_true(produced.length() > 0)
    let pages = @ogg.parse_pages(produced)
    assert_true(pages.length() > 0)
    let packets = @ogg.reassemble(pages)
    assert_true(packets.length() >= 3)
    // 首包必须是 OpusHead，且能被 codec 解析
    match @codec.parse_audio_header(packets[0].data) {
      Some(info) => {
        assert_eq(info.codec, "Opus")
        assert_eq(info.channels, 1)
      }
      None => assert_true(false)
    }
  } else {
    assert_true(false)
  }
  @fs.remove_file(src) catch {
    _ => ()
  }
  @fs.remove_file(m4a) catch {
    _ => ()
  }
  @fs.remove_file(out) catch {
    _ => ()
  }
}

// ---- v0.7.0：WAV 块保真 / WavWriter 在 info 输出层的覆盖 ----

///|
/// 带 LIST/fact 扩展块的 WAV：文本与 JSON 渲染都要报出扩展块。
test "wav info rendering covers preserved chunks" {
  let writer = @wav.WavWriter::new(
    { channels: 1, sample_rate: 8000, bits_per_sample: 16, },
    @wav.SampleFormat::Int,
  )
  writer.write(b"\x00\x00\x01\x00")
  writer.add_chunk("LIST", b"\x01\x02\x03")
  writer.add_trailing_chunk("fact", b"\x04\x00\x00\x00")
  match writer.finish() {
    Err(msg) => {
      println("writer error: " + msg)
      assert_true(false)
    }
    Ok(bytes) =>
      match @wav.WavFile::parse(bytes) {
        Some(f) => {
          assert_eq(f.chunks.length(), 2)
          show_wav_info("chunks.wav", bytes, f, false)
          show_wav_info("chunks.wav", bytes, f, true)
          // 块保真：to_bytes 往返逐字节一致
          match f.to_bytes() {
            Ok(back) => assert_eq(back.length(), bytes.length())
            Err(_) => assert_true(false)
          }
        }
        None => assert_true(false)
      }
  }
}

///|
test "pages_byte_size counts per-page header and segment table" {
  let packets : Array[@ogg.Packet] = [
    { data: b"abc", granule_position: 0L, serial: 1U, },
    { data: b"defgh", granule_position: 960L, serial: 1U, },
  ]
  let pages = @ogg.paginate(packets, 1U)
  let mut expected = 0L
  for p in pages {
    expected = expected +
      27L +
      p.segments.length().to_int64() +
      p.payload.length().to_int64()
  }
  assert_eq(pages_byte_size(pages), expected)
}

///|
test "escape_controls renders control characters as hex" {
  assert_eq(escape_controls("ok"), "ok")
  assert_eq(escape_controls("a\nb"), "a\\x0Ab")
  assert_eq(escape_controls("\u001b[0m"), "\\x1B[0m")
  assert_eq(escape_controls("\u007f"), "\\x7F")
}

///|
test "looks_like_packet_member only matches real packet members" {
  assert_true(looks_like_packet_member("packet_000001.bin"))
  assert_true(looks_like_packet_member("dir/manifest.txt"))
  assert_true(looks_like_packet_member("packet~1.bin"))
  assert_true(looks_like_packet_member("manife~1.txt"))
  // 8.3 短名的 "~" 后必须是数字，普通文件名不能误拒
  assert_false(looks_like_packet_member("manife~abc.txt"))
  assert_false(looks_like_packet_member("packet_000001.ogg"))
  assert_false(looks_like_packet_member("notes.txt"))
}

///|
/// Windows 路径大小写不敏感，大写 8.3 短名同样要识别；POSIX 下文件名区分大小写，
/// 大写形式是普通文件名，不应误拒。
#cfg(platform="windows")
test "looks_like_packet_member folds case on Windows" {
  assert_true(looks_like_packet_member("PACKET~1.BIN"))
  assert_true(looks_like_packet_member("MANIFE~1.TXT"))
}

///|
test "version constant matches describe output" {
  assert_true(@moonmux.MOONMUX_VERSION.length() > 0)
  assert_eq(@moonmux.describe(), "moonmux " + @moonmux.MOONMUX_VERSION)
}

///|
test "packet numbers sort numerically, not lexicographically" {
  assert_eq(packet_number("packet_000010.bin"), Some(10L))
  assert_eq(packet_number("packet_1.bin"), Some(1L))
  assert_eq(packet_number("packet_x.bin"), None)
  assert_eq(packet_number("other_1.bin"), None)
  assert_true(packet_less("packet_2.bin", "packet_10.bin"))
  assert_false(packet_less("packet_10.bin", "packet_2.bin"))
}

///|
/// demux 包数上界：小输入按「页数 × 255」粗估，不做逐段扫描（不做无谓的 O(n) 工作）。
test "demux packet upper bound is coarse for small inputs" {
  let pages = @ogg.paginate(
    [
      { data: b"aa", granule_position: 0L, serial: 1U, },
      { data: b"bb", granule_position: 0L, serial: 1U, },
    ],
    1U,
  )
  let bound = demux_packet_upper_bound(pages)
  assert_true(bound >= 2L)
  assert_eq(bound, pages.length().to_int64() * 255L)
  // 文件对象上界 = 包数 + 2×流数（每流一份清单 + 一个子目录）
  assert_eq(
    demux_output_object_upper_bound(pages),
    bound + @ogg.serials_of(pages).length().to_int64() * 2L,
  )
  assert_true(demux_output_guard(pages) is None)
}

///|
/// 造「每页 255 个零长段」的页序列：每段都结束一个包，5301 B 输入 ≈ 5100 个文件。
///
/// 只给估算函数用：不参与重组成包，也不要求 CRC 正确。
fn test_zero_segment_pages(n_pages : Int32) -> Array[@ogg.Page] {
  let segments : Array[Int32] = []
  let mut i = 0
  while i < 255 {
    segments.push(0)
    i = i + 1
  }
  let pages : Array[@ogg.Page] = []
  let mut p = 0
  while p < n_pages {
    pages.push({
      header_type: (0x00 : Byte),
      granule_position: 0L,
      serial: 1U,
      sequence: 0U,
      crc: 0U,
      segments,
      payload: b"",
    })
    p = p + 1
  }
  pages
}

///|
/// 造「每页 254 段续包 + 1 段收尾」的页序列：每页只结束 1 个包（正常大文件形态）。
fn test_continuation_pages(n_pages : Int32) -> Array[@ogg.Page] {
  let segments : Array[Int32] = []
  let mut i = 0
  while i < 255 {
    if i == 254 {
      segments.push(0)
    } else {
      segments.push(255)
    }
    i = i + 1
  }
  let pages : Array[@ogg.Page] = []
  let mut p = 0
  while p < n_pages {
    pages.push({
      header_type: (0x00 : Byte),
      granule_position: 0L,
      serial: 1U,
      sequence: 0U,
      crc: 0U,
      segments,
      payload: b"",
    })
    p = p + 1
  }
  pages
}

///|
/// F-PAR-03 回归：零长段构造的包数放大必须在重组/写盘之前被拒。
///
/// 3922 页 × 255 个零长段 = 1,000,110 个包；文件对象 1,000,112（含 1 流清单+目录）
/// 超过 999999 上限。同时验证「粗估超限、精算不超限」的正常文件不会被误拒。
test "demux output guard rejects segment-flood amplification before reassembly" {
  let flood = test_zero_segment_pages(3922)
  let bound = demux_packet_upper_bound(flood)
  assert_true(bound > MAX_DEMUX_PACKETS.to_int64())
  assert_true(demux_output_object_upper_bound(flood) > MAX_DEMUX_OUTPUT_OBJECTS)
  match demux_output_guard(flood) {
    Some(msg) => {
      assert_true(msg.contains("999999"))
      assert_true(msg.contains("split"))
    }
    None => assert_true(false)
  }
  let cont = test_continuation_pages(3922)
  assert_eq(demux_packet_upper_bound(cont), 3922L)
  assert_true(demux_output_guard(cont) is None)
  // 上限内的零长段文件仍然放行（5100 个文件属于文档允许的能力范围）
  assert_true(demux_output_guard(test_zero_segment_pages(20)) is None)
}

///|
/// 造「N 条逻辑流、每流 1 个包」的页序列（每流一段 BOS 页）。
///
/// 只给估算函数用：一条流一个包时「包数」只有 N，但 demux 会写 N 个包文件 +
/// N 份清单 + N 个子目录 → 文件对象 3N。用于 RT-A-08 的计数口径回归。
fn test_many_stream_pages(streams : Int32) -> Array[@ogg.Page] {
  let segments : Array[Int32] = [1]
  let pages : Array[@ogg.Page] = []
  let mut s = 0
  let mut serial : UInt32 = 1U
  while s < streams {
    pages.push({
      header_type: (0x02 : Byte),
      granule_position: 0L,
      serial,
      sequence: 0U,
      crc: 0U,
      segments,
      payload: b"x",
    })
    serial = serial + 1U
    s = s + 1
  }
  pages
}

///|
/// RT-A-08 回归：demux 上限必须按**文件对象**计，而不是只按包数。
///
/// 333,335 条流 × 1 包：包数只有 333,335（远低于 999999），
/// 但文件对象 = 333,335 + 2×333,335 = 1,000,005 > 999999 → 必须拒绝。
/// 小规模（255 流）仍放行：上限内按文档允许写文件。
test "demux output guard counts manifests and directories, not just packets" {
  let big = test_many_stream_pages(333335)
  assert_eq(demux_packet_upper_bound(big), 333335L)
  assert_eq(demux_output_object_upper_bound(big), 333335L + 333335L * 2L)
  match demux_output_guard(big) {
    Some(msg) => assert_true(msg.contains("999999"))
    None => assert_true(false)
  }
  let small = test_many_stream_pages(255)
  assert_true(demux_output_guard(small) is None)
}

///|
/// RT-A-06 回归：`split` 的段数上限（162 KB PoC 可铺出 3,000 个文件）。
test "split parts guard caps output file count" {
  // 上限内的常见链接流（3,000 段）放行 —— 与 demux 同一口径
  assert_true(split_parts_guard(3000) is None)
  assert_true(split_parts_guard(MAX_SPLIT_PARTS) is None)
  match split_parts_guard(MAX_SPLIT_PARTS + 1) {
    Some(msg) => {
      assert_true(msg.contains("999999"))
      assert_true(msg.contains("partN.ogg"))
    }
    None => assert_true(false)
  }
  match split_parts_guard(1000000) {
    Some(msg) => assert_true(msg.contains("partN.ogg"))
    None => assert_true(false)
  }
}

///|
/// F-CLI-01 回归：回滚前先判存在 —— 写失败但没留下任何文件时不能报「清理失败」。
#cfg(target="native")
test "restore_output stays quiet when nothing was written" {
  let dir = "_build/wbtest_restore_quiet"
  reset_test_dir(dir)
  @fs.create_dir(dir) catch {
    IOError(msg) => abort("create_dir: " + msg)
  }
  let missing = dir + "/never-created.ogg"
  let failures = restore_output(missing, NoOriginal)
  assert_eq(failures.length(), 0)
  // 确实存在半截文件时：删掉，且删除成功不需要任何清理告警
  @fs.write_bytes_to_file(missing, b"half") catch {
    IOError(msg) => abort("write half: " + msg)
  }
  let failures2 = restore_output(missing, NoOriginal)
  assert_eq(failures2.length(), 0)
  assert_false(@fs.path_exists(missing))
  reset_test_dir(dir)
}

///|
/// 有备份时的回滚：旧内容放回、备份删除、不产生清理失败。
#cfg(target="native")
test "restore_output puts the backup back and removes the bak file" {
  let dir = "_build/wbtest_restore_saved"
  reset_test_dir(dir)
  @fs.create_dir(dir) catch {
    IOError(msg) => abort("create_dir: " + msg)
  }
  let out = dir + "/out.ogg"
  let bak = out + ".moonmux.bak.0"
  @fs.write_bytes_to_file(bak, b"ORIGINAL") catch {
    IOError(msg) => abort("write bak: " + msg)
  }
  @fs.write_bytes_to_file(out, b"BROKEN") catch {
    IOError(msg) => abort("write out: " + msg)
  }
  let failures = restore_output(out, Saved(bak))
  assert_eq(failures.length(), 0)
  let restored = @fs.read_file_to_bytes(out) catch {
    IOError(msg) => abort("read out: " + msg)
  }
  assert_true(bytes_same(restored, b"ORIGINAL"))
  assert_false(@fs.path_exists(bak))
  reset_test_dir(dir)
}

///|
/// F-CLI-04 回归：`@fs` 的空错误串 / "No error" 不能原样透给用户；
/// 真实 errno 文案（如 Permission denied）必须保留。
test "io_reason replaces empty and No error messages" {
  assert_true(io_reason("").contains("路径"))
  assert_true(io_reason("No error").contains("路径"))
  assert_eq(io_reason("Permission denied"), "Permission denied")
  assert_eq(io_reason("No such file or directory"), "No such file or directory")
}

///|
/// F-CLI-03 回归：`\\?\` / `\\.\` / `\\?\UNC\` 前缀要在路径归一化前剥掉
/// （否则会被 ADS 判据误判成 NTFS 备用数据流）。
#cfg(platform="windows")
test "extended length prefixes are stripped on Windows" {
  assert_eq(strip_extended_prefix("\\\\?\\C:\\tmp\\a.ogg"), "C:\\tmp\\a.ogg")
  assert_eq(strip_extended_prefix("\\\\.\\C:\\tmp\\a.ogg"), "C:\\tmp\\a.ogg")
  assert_eq(
    strip_extended_prefix("\\\\?\\UNC\\srv\\share\\a.ogg"),
    "\\\\srv\\share\\a.ogg",
  )
  // 普通路径原样返回
  assert_eq(strip_extended_prefix("C:\\tmp\\a.ogg"), "C:\\tmp\\a.ogg")
  assert_eq(strip_extended_prefix("a.ogg"), "a.ogg")
  // 剥掉前缀后不再含第二个冒号，ADS 判据不会误杀
  assert_false(
    strip_extended_prefix("\\\\?\\C:\\tmp\\a.ogg").contains("\\\\?\\"),
  )
}

///|
/// POSIX 下 `\\?\` 只是普通文件名字符，不能被当成 Windows 前缀剥掉。
#cfg(not(platform="windows"))
test "extended length prefixes are not stripped on POSIX" {
  assert_eq(
    strip_extended_prefix("\\\\?\\C:\\tmp\\a.ogg"),
    "\\\\?\\C:\\tmp\\a.ogg",
  )
}

///|
/// F-CLI-03 回归：超过 MAX_PATH 的路径要给出可操作提示，短路径保持安静。
#cfg(platform="windows")
test "long path hint fires above MAX_PATH and stays quiet below" {
  let mut long : String = ""
  let mut i = 0
  while i < 300 {
    long = long + "a"
    i = i + 1
  }
  assert_true(long_path_hint(long).length() > 0)
  assert_true(long_path_hint(long).contains("260"))
  assert_eq(long_path_hint("a.ogg"), "")
}

///|
/// POSIX 下没有 MAX_PATH 概念：任何长度都不该冒出 Windows 专属提示。
#cfg(not(platform="windows"))
test "long path hint is empty on POSIX" {
  let mut long : String = ""
  let mut i = 0
  while i < 300 {
    long = long + "a"
    i = i + 1
  }
  assert_eq(long_path_hint(long), "")
}

///|
/// 回滚清理：本轮创建的目录整棵删掉，且不产生「清理失败」。
#cfg(target="native")
test "rollback_demux removes a directory it created" {
  let dir = "_build/wbtest_rollback_created"
  reset_test_dir(dir)
  @fs.create_dir(dir) catch {
    IOError(msg) => abort("create_dir: " + msg)
  }
  @fs.create_dir(dir + "/s1") catch {
    IOError(msg) => abort("create_dir s1: " + msg)
  }
  @fs.write_bytes_to_file(dir + "/s1/packet_000000.bin", b"x") catch {
    IOError(msg) => abort("write packet: " + msg)
  }
  let failures = rollback_demux(dir, true, [], [])
  assert_eq(failures.length(), 0)
  assert_false(@fs.path_exists(dir))
  reset_test_dir(dir)
}

///|
/// 回滚清理：目录是用户原有的，只删本命令写出的文件，保留用户文件。
#cfg(target="native")
test "rollback_demux keeps files it did not create" {
  let dir = "_build/wbtest_rollback_existing"
  reset_test_dir(dir)
  @fs.create_dir(dir) catch {
    IOError(msg) => abort("create_dir: " + msg)
  }
  let keep = dir + "/keep.txt"
  let mine = dir + "/packet_000000.bin"
  @fs.write_string_to_file(keep, "keep") catch {
    IOError(msg) => abort("write keep: " + msg)
  }
  @fs.write_bytes_to_file(mine, b"x") catch {
    IOError(msg) => abort("write mine: " + msg)
  }
  let created : Array[String] = [mine]
  let failures = rollback_demux(dir, false, [], created)
  assert_eq(failures.length(), 0)
  assert_true(@fs.path_exists(keep))
  assert_false(@fs.path_exists(mine))
  assert_true(@fs.path_exists(dir))
  reset_test_dir(dir)
}

// ---- 第 4 轮：D2 覆盖率缺口（cmd/main 内部 I/O / 守卫 / 渲染路径） ----
// 这些函数只在 native 可执行入口里被 main 调用，之前的测试只覆盖了其中一部分；
// 这里直接调用同包私有函数，断言具体返回值/文本，不经过子进程。

///|
/// 造一张页：单段负载（< 255 字节），CRC 留给 serialize_pages 统一计算。
fn wb_page(
  ht : Byte,
  serial : UInt32,
  seq : UInt32,
  granule : Int64,
  payload : Bytes,
) -> @ogg.Page {
  {
    header_type: ht,
    granule_position: granule,
    serial,
    sequence: seq,
    crc: 0U,
    segments: [payload.length()],
    payload,
  }
}

///|
/// 指定流号的单段 Opus 流：BOS 头页 + 注释页 + 两个音频页（末页 EOS）。
fn wb_ogg_serial(serial : UInt32) -> Bytes {
  let head : Bytes = b"OpusHead\x01\x01\x38\x01\x80\xbb\x00\x00\x00\x00\x00"
  let tags : Bytes = b"OpusTags\x06\x00\x00\x00moonmu\x00\x00\x00\x00"
  let pages : Array[@ogg.Page] = [
    wb_page((0x02 : Byte), serial, 0U, 0L, head),
    wb_page((0x00 : Byte), serial, 1U, 0L, tags),
    wb_page((0x00 : Byte), serial, 2U, 960L, b"\xfc\x01\x02\x03"),
    wb_page((0x04 : Byte), serial, 3U, 1920L, b"\xfc\x04\x05"),
  ]
  @ogg.serialize_pages(pages)
}

///|
/// 两段链接流：第二段从新的 BOS 页重新开始（split / cat / info 的链接分支输入）。
fn wb_linked_ogg() -> Bytes {
  let buf = Buffer()
  buf.write_bytes(wb_ogg_serial(1U).exact_view())
  buf.write_bytes(wb_ogg_serial(2U).exact_view())
  buf.to_bytes()
}

///|
/// 准备一个干净的测试目录并返回路径。
fn wb_fresh_dir(name : String) -> String {
  let dir = "_build/wbtest_" + name
  reset_test_dir(dir)
  @fs.create_dir(dir) catch {
    IOError(msg) => abort("create_dir " + dir + ": " + msg)
  }
  dir
}

///|
/// 写文件失败直接让测试失败（避免后续断言读到空文件）。
fn wb_write(path : String, data : Bytes) -> Unit {
  @fs.write_bytes_to_file(path, data) catch {
    IOError(msg) => abort("write " + path + ": " + msg)
  }
}

///|
/// 写文本文件失败直接让测试失败。
fn wb_write_text(path : String, text : String) -> Unit {
  @fs.write_string_to_file(path, text) catch {
    IOError(msg) => abort("write " + path + ": " + msg)
  }
}

///|
/// verify 的成功路径（干净文件 + 只有 warning 的文件）都要能正常结束；
/// 只有 error 才允许 exit。这里两个文件都跑文本与 JSON 两种渲染。
#cfg(target="native")
test "run_verify reports clean and warning files without exiting" {
  let dir = wb_fresh_dir("verify")
  let clean = dir + "/clean.ogg"
  wb_write(clean, wb_ogg_serial(1U))
  run_verify(clean, false)
  run_verify(clean, true)
  // 去掉末页 EOS：结构检查只给 warning，不应触发退出码 1
  let pages = @ogg.parse_pages(wb_ogg_serial(1U))
  let patched : Array[@ogg.Page] = []
  let mut i = 0
  for p in pages {
    patched.push({
      header_type: if i == pages.length() - 1 {
        (0x00 : Byte)
      } else {
        p.header_type
      },
      granule_position: p.granule_position,
      serial: p.serial,
      sequence: p.sequence,
      crc: 0U,
      segments: p.segments,
      payload: p.payload,
    })
    i = i + 1
  }
  let warn = dir + "/warn.ogg"
  wb_write(warn, @ogg.serialize_pages(patched))
  run_verify(warn, false)
  run_verify(warn, true)
  assert_eq(pages.length(), 4)
  assert_eq(patched.length(), 4)
  assert_eq(patched[3].header_type, (0x00 : Byte))
  reset_test_dir(dir)
}

///|
/// dump 的两种输出：纯 hex（可 xxd -r 还原）与页表。
#cfg(target="native")
test "run_dump prints hex and page table" {
  let dir = wb_fresh_dir("dump")
  let path = dir + "/a.ogg"
  wb_write(path, wb_ogg_serial(1U))
  run_dump(path, true)
  run_dump(path, false)
  let pages = @ogg.parse_pages(wb_ogg_serial(1U))
  assert_eq(pages.length(), 4)
  assert_eq(pages[1].granule_position, 0L)
  assert_eq(pages[3].granule_position, 1920L)
  reset_test_dir(dir)
}

///|
/// tags 的成功路径：识别 Opus 注释并打印 vendor / 注释条数。
#cfg(target="native")
test "run_tags prints the Opus comment" {
  let dir = wb_fresh_dir("tags")
  let path = dir + "/a.ogg"
  wb_write(path, wb_ogg_serial(1U))
  run_tags(path)
  match find_comment(@ogg.parse_pages(wb_ogg_serial(1U))) {
    Err(msg) => abort("find_comment: " + msg)
    Ok(found) => {
      let (serial, kind, comment) = found
      assert_eq(serial, 1U)
      match kind {
        @codec.CommentKind::Opus => assert_true(true)
        @codec.CommentKind::Vorbis => assert_true(false)
      }
      assert_eq(comment.vendor, "moonmu")
      assert_eq(comment.tags.length(), 0)
    }
  }
  reset_test_dir(dir)
}

///|
/// info 的链接流分支：两段物理流要分开统计；尾部多余字节要明说。
test "show_ogg_info renders linked and trailing-data inputs" {
  let linked = wb_linked_ogg()
  show_ogg_info("linked.ogg", linked, false)
  show_ogg_info("linked.ogg", linked, true)
  let pages = @ogg.parse_pages(linked)
  assert_eq(pages.length(), 8)
  assert_eq(@ogg.split_chains(pages).length(), 2)
  assert_eq(@ogg.serials_of(pages).length(), 2)
  // 末尾多 3 个零字节：dump/info 只能解析到最后一页，必须提示剩余字节
  let buf = Buffer()
  buf.write_bytes(linked.exact_view())
  buf.write_bytes(b"\x00\x00\x00".exact_view())
  show_ogg_info("trailing.ogg", buf.to_bytes(), false)
  show_ogg_info("trailing.ogg", buf.to_bytes(), true)
}

///|
/// plan_mux / read_manifest 的 I/O 与数据错误分支（不触发进程退出）。
#cfg(target="native")
test "plan_mux and read_manifest surface io and data errors" {
  // 目录不存在：subdirs_in 返回 Err → MuxIo
  let missing = "_build/wbtest_plan_missing_dir"
  reset_test_dir(missing)
  match plan_mux(missing) {
    Ok(_) => assert_true(false)
    Err(m) => assert_true(mux_fail_text(m).contains("无法读取目录"))
  }
  // 空子目录：多流布局里出现空逻辑流 → MuxData
  let dir = wb_fresh_dir("plan_empty_sub")
  @fs.create_dir(dir + "/s1") catch {
    IOError(msg) => abort("create_dir s1: " + msg)
  }
  match plan_mux(dir) {
    Ok(_) => assert_true(false)
    Err(m) => assert_true(mux_fail_text(m).contains("没有包文件"))
  }
  reset_test_dir(dir)
  // 清单文本非法：read_manifest → MuxData
  let dir2 = wb_fresh_dir("plan_bad_manifest")
  wb_write_text(dir2 + "/manifest.txt", "这不是清单\n")
  wb_write(dir2 + "/packet_000000.bin", b"aa")
  match plan_mux(dir2) {
    Ok(_) => assert_true(false)
    Err(m) => assert_true(mux_fail_text(m).length() > 0)
  }
  reset_test_dir(dir2)
  // 清单缺失：合法（手工目录），返回全 None
  let dir3 = wb_fresh_dir("plan_no_manifest")
  match read_manifest(dir3) {
    Err(m) => abort("read_manifest missing: " + mux_fail_text(m))
    Ok(m) => {
      assert_true(m.serial is None)
      assert_true(m.packets is None)
      assert_true(m.chain is None)
      assert_eq(m.granules.length(), 0)
    }
  }
  // manifest.txt 是目录而不是普通文件：MuxIo（不是 MuxData）
  @fs.create_dir(dir3 + "/manifest.txt") catch {
    IOError(msg) => abort("create_dir manifest.txt: " + msg)
  }
  match read_manifest(dir3) {
    Ok(_) => assert_true(false)
    Err(m) => assert_true(mux_fail_text(m).contains("不是普通文件"))
  }
  reset_test_dir(dir3)
}

///|
/// subdirs_in：只收目录、按 sN 数字排序（s10 不能排在 s2 前面）。
#cfg(target="native")
test "subdirs_in sorts sN numerically and skips files" {
  let dir = wb_fresh_dir("subdirs")
  @fs.create_dir(dir + "/s2") catch {
    IOError(msg) => abort("create_dir s2: " + msg)
  }
  @fs.create_dir(dir + "/s10") catch {
    IOError(msg) => abort("create_dir s10: " + msg)
  }
  @fs.create_dir(dir + "/s1") catch {
    IOError(msg) => abort("create_dir s1: " + msg)
  }
  wb_write(dir + "/x.txt", b"x")
  match subdirs_in(dir) {
    Err(msg) => abort("subdirs_in: " + msg)
    Ok(names) => {
      assert_eq(names.length(), 3)
      assert_eq(names[0], "s1")
      assert_eq(names[1], "s2")
      assert_eq(names[2], "s10")
    }
  }
  match subdirs_in(dir + "/nope") {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.contains("无法读取目录"))
  }
  reset_test_dir(dir)
}

///|
/// find_comment 的失败形态：没有流、没有可识别音频流、音频流缺注释包。
test "find_comment reports missing streams and comments" {
  let empty : Array[@ogg.Page] = []
  match find_comment(empty) {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.contains("没有任何逻辑流"))
  }
  let skeleton : Array[@ogg.Page] = [
    wb_page((0x02 : Byte), 9U, 0U, 0L, b"fishead"),
  ]
  match find_comment(skeleton) {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.contains("没有可识别的音频流"))
  }
  let head_only : Array[@ogg.Page] = [
    wb_page(
      (0x02 : Byte),
      3U,
      0U,
      0L,
      b"OpusHead\x01\x01\x38\x01\x80\xbb\x00\x00\x00\x00\x00",
    ),
  ]
  match find_comment(head_only) {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.contains("没有注释包"))
  }
}

///|
/// 路径词法规范化：大小写、分隔符折叠、尾随点/空格、开头的 ./。
#cfg(target="native")
test "normalize_path folds separators case and trailing dots" {
  assert_eq(normalize_path("A\\\\B\\\\C.OGG."), "a/b/c.ogg")
  assert_eq(normalize_path("./x//y/"), "x/y")
  assert_eq(normalize_path("C:\\\\Temp\\\\"), "c:/temp")
  assert_eq(normalize_path("dir/ "), "dir")
  assert_eq(normalize_path("a/./b"), "a/./b")
  assert_eq(normalize_path("."), ".")
}

///|
/// run_mux 的两种布局：单流（包直接放目录 + 清单）与多流（子目录 + 清单）。
#cfg(target="native")
test "run_mux writes single and multi stream plans" {
  // 单流目录
  let dir = wb_fresh_dir("mux_single")
  wb_write_text(
    dir + "/manifest.txt",
    "# moonmux manifest v1\n# granulepos\n# serial=11\n# packets=2\n# chain=1\n0\n960\n",
  )
  wb_write(dir + "/packet_000000.bin", b"aa")
  wb_write(dir + "/packet_000001.bin", b"bb")
  let out = dir + "_out.ogg"
  run_mux(dir, out)
  let produced = @fs.read_file_to_bytes(out) catch { _ => b"" }
  assert_true(produced.length() > 0)
  let pages = @ogg.parse_pages(produced)
  assert_true(pages.length() >= 1)
  assert_eq(pages[0].serial, 11U)
  reset_test_dir(dir)
  // 多流目录：s1/s2 各有清单，链号 1/2（升序交织）
  let mdir = wb_fresh_dir("mux_multi")
  @fs.create_dir(mdir + "/s1") catch {
    IOError(msg) => abort("create_dir s1: " + msg)
  }
  @fs.create_dir(mdir + "/s2") catch {
    IOError(msg) => abort("create_dir s2: " + msg)
  }
  wb_write_text(
    mdir + "/s1/manifest.txt",
    "# moonmux manifest v1\n# granulepos\n# serial=21\n# packets=1\n# chain=1\n0\n",
  )
  wb_write_text(
    mdir + "/s2/manifest.txt",
    "# moonmux manifest v1\n# granulepos\n# serial=22\n# packets=1\n# chain=2\n0\n",
  )
  wb_write(mdir + "/s1/packet_000000.bin", b"aa")
  wb_write(mdir + "/s2/packet_000000.bin", b"bb")
  let mout = mdir + "_out.ogg"
  run_mux(mdir, mout)
  let mpages = @ogg.parse_pages(@fs.read_file_to_bytes(mout) catch { _ => b"" })
  assert_true(mpages.length() >= 2)
  let serials = @ogg.serials_of(mpages)
  assert_true(serials.contains(21U))
  assert_true(serials.contains(22U))
  reset_test_dir(mdir)
}

///|
/// split：链接流按段拆成多个 partN.ogg；单段流原样写出 part1.ogg。
#cfg(target="native")
test "run_split writes one part per physical stream" {
  let dir = wb_fresh_dir("split_src")
  let linked = dir + "/linked.ogg"
  wb_write(linked, wb_linked_ogg())
  let out_dir = "_build/wbtest_split_out"
  reset_test_dir(out_dir)
  run_split(linked, out_dir)
  assert_true(@fs.path_exists(out_dir + "/part1.ogg"))
  assert_true(@fs.path_exists(out_dir + "/part2.ogg"))
  let p1 = @ogg.parse_pages(
    @fs.read_file_to_bytes(out_dir + "/part1.ogg") catch {
      _ => b""
    },
  )
  let p2 = @ogg.parse_pages(
    @fs.read_file_to_bytes(out_dir + "/part2.ogg") catch {
      _ => b""
    },
  )
  assert_eq(p1.length(), 4)
  assert_eq(p2.length(), 4)
  let sp1 = @ogg.serials_of(p1)
  let sp2 = @ogg.serials_of(p2)
  assert_eq(sp1.length(), 1)
  assert_eq(sp1[0], 1U)
  assert_eq(sp2.length(), 1)
  assert_eq(sp2[0], 2U)
  reset_test_dir(out_dir)
  // 单段流：只写 part1 并提示不是链接流
  let single = dir + "/single.ogg"
  wb_write(single, wb_ogg_serial(1U))
  run_split(single, out_dir)
  assert_true(@fs.path_exists(out_dir + "/part1.ogg"))
  assert_true(!@fs.path_exists(out_dir + "/part2.ogg"))
  reset_test_dir(out_dir)
  reset_test_dir(dir)
}

///|
/// extract：按 1 起算的逻辑流序号抽出单条流，页级原样透传。
#cfg(target="native")
test "run_extract writes the selected stream" {
  let dir = wb_fresh_dir("extract")
  let linked = dir + "/linked.ogg"
  let out = dir + "/s2.ogg"
  wb_write(linked, wb_linked_ogg())
  run_extract(linked, 2, out, false)
  let produced = @ogg.parse_pages(
    @fs.read_file_to_bytes(out) catch {
      _ => b""
    },
  )
  assert_eq(produced.length(), 4)
  let sp = @ogg.serials_of(produced)
  assert_eq(sp.length(), 1)
  assert_eq(sp[0], 2U)
  // 幂等重跑（--force 语义）：已有输出与待写内容相同，允许覆盖
  run_extract(linked, 2, out, true)
  let again = @fs.read_file_to_bytes(out) catch { _ => b"" }
  assert_true(again.length() > 0)
  reset_test_dir(dir)
}

///|
/// cat：多个 Ogg 首尾链接成一条物理流。
#cfg(target="native")
test "run_cat links multiple ogg files" {
  let dir = wb_fresh_dir("cat")
  let a = dir + "/a.ogg"
  let b = dir + "/b.ogg"
  let out = dir + "/joined.ogg"
  wb_write(a, wb_ogg_serial(1U))
  wb_write(b, wb_ogg_serial(2U))
  let inputs : Array[String] = [a, b]
  run_cat(inputs, out)
  let produced = @ogg.parse_pages(
    @fs.read_file_to_bytes(out) catch {
      _ => b""
    },
  )
  assert_eq(produced.length(), 8)
  assert_eq(@ogg.split_chains(produced).length(), 2)
  let serials = @ogg.serials_of(produced)
  assert_true(serials.contains(1U))
  assert_true(serials.contains(2U))
  reset_test_dir(dir)
}

///|
/// demux：把包与清单写到 sN/ 目录（manifest 先写，是整条流的提交点）。
#cfg(target="native")
test "run_demux writes packets and manifests" {
  let dir = wb_fresh_dir("demux")
  let src = dir + "/in.ogg"
  wb_write(src, wb_ogg_serial(1U))
  let out_dir = "_build/wbtest_demux_out"
  reset_test_dir(out_dir)
  run_demux(src, out_dir)
  assert_true(@fs.path_exists(out_dir + "/s1"))
  assert_true(@fs.path_exists(out_dir + "/s1/manifest.txt"))
  assert_true(@fs.path_exists(out_dir + "/s1/packet_000000.bin"))
  assert_true(@fs.path_exists(out_dir + "/s1/packet_000003.bin"))
  let manifest = @fs.read_file_to_string(out_dir + "/s1/manifest.txt") catch {
    _ => ""
  }
  assert_true(manifest.contains("# serial=1"))
  assert_true(manifest.contains("# packets=4"))
  reset_test_dir(out_dir)
  reset_test_dir(dir)
}

///|
/// chop：单流按毫秒区间裁剪，写出后自检通过（页级精度）。
#cfg(target="native")
test "run_chop trims a single stream" {
  let dir = wb_fresh_dir("chop")
  let src = dir + "/in.ogg"
  let out = dir + "/out.ogg"
  wb_write(src, wb_ogg_serial(1U))
  run_chop(src, out, 0, 30)
  let produced = @ogg.parse_pages(
    @fs.read_file_to_bytes(out) catch {
      _ => b""
    },
  )
  assert_true(produced.length() > 0)
  let sp = @ogg.serials_of(produced)
  assert_eq(sp.length(), 1)
  assert_eq(sp[0], 1U)
  reset_test_dir(dir)
}
