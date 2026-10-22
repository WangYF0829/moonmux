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
/// 预算文本：合法值换算成字节，0 / 超上限 / 非数字 / 空串都退回默认 256 MiB。
test "budget text falls back to the default on anything unusual" {
  let mib : Int64 = 1048576L
  assert_eq(budget_from_text("1"), 1L * mib)
  assert_eq(budget_from_text("256"), 256L * mib)
  assert_eq(budget_from_text("4096"), 4096L * mib)
  assert_eq(budget_from_text("0"), 256L * mib)
  assert_eq(budget_from_text("4097"), 256L * mib)
  assert_eq(budget_from_text(""), 256L * mib)
  assert_eq(budget_from_text("12x"), 256L * mib)
  assert_eq(budget_from_text("-1"), 256L * mib)
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
    remove_dir_tree(dir)
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
  remove_dir_tree(dir)
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
    Err(msg) => abort(msg)
  }
  remove_dir_tree(dir)
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
    Err(msg) => abort(msg)
  }
  remove_dir_tree(dir)
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
    Err(msg) => assert_true(msg.contains("没有包文件"))
  }
  remove_dir_tree(empty)

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
      assert_true(msg.contains("既有子目录又有散落的包文件"))
  }
  remove_dir_tree(mixed)
}

///|
/// JSON 转义：引号、反斜杠、换行与控制字符。
test "json escaping handles quotes, backslashes and controls" {
  assert_eq(json_escape("a\"b\\c"), "a\\\"b\\\\c")
  assert_eq(json_escape("a\nb"), "a\\nb")
  assert_eq(json_escape("\u0001"), "\\u0001")
  assert_eq(json_string("x"), "\"x\"")
}
