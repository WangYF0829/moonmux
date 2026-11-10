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
