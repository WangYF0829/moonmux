// cli_remux_wbtest.mbt —— remux 子命令的参数解析测试

///|
test "cli parse: remux takes input and output" {
  match parse(["remux", "in.ogg", "out.m4a"]) {
    Remux(src, out) => {
      assert_eq(src, "in.ogg")
      assert_eq(out, "out.m4a")
    }
    _ => assert_true(false)
  }
}

///|
test "cli parse: remux arity errors" {
  match parse(["remux"]) {
    Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
  match parse(["remux", "a.ogg"]) {
    Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
  match parse(["remux", "a.ogg", "b.m4a", "extra"]) {
    Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
}

///|
test "cli usage mentions remux and m4a" {
  assert_true(usage().contains("remux"))
  assert_true(usage().contains("m4a"))
  assert_true(usage_for("remux").contains("MP4"))
}

///|
/// 每个子命令的用法文本都覆盖到（usage_for 的分支全部执行）。
test "usage_for covers every subcommand" {
  let topics : Array[String] = [
    "info", "demux", "mux", "cat", "split", "extract", "dump", "tags", "tag", "seek",
    "verify", "to-wav", "chop", "remux", "version", "help", "unknown",
  ]
  for topic in topics {
    assert_true(usage_for(topic).length() > 0)
  }
  assert_true(usage().length() > 0)
}
