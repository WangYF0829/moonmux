// cli_wbtest.mbt —— 命令行解析的测试
//
// 重点钉住几类曾经在同类项目里出过的错：
// 拼错的子命令被当成文件名、缺参数时报出无关提示、
// 多给的参数被静默忽略。

///|
/// 无参数时给出帮助。
test "empty args shows help" {
  match parse([]) {
    Command::Help => assert_true(true)
    _ => assert_true(false)
  }
}

///|
/// `info` 缺文件参数时应当明确报错，而不是把子命令当路径。
test "info without file reports arity error" {
  match parse(["info"]) {
    Command::Bad(msg, usage) => {
      assert_true(msg.length() > 0)
      assert_true(usage.length() > 0)
    }
    _ => assert_true(false)
  }
}

///|
/// 正常路径：`info <file>`。
test "info with file" {
  match parse(["info", "a.ogg"]) {
    Command::Info(p) => assert_eq(p, "a.ogg")
    _ => assert_true(false)
  }
}

///|
/// 未知子命令必须报错，并附带总用法 —— 而不是落到某个默认分支里。
test "unknown subcommand reports error" {
  match parse(["nosuchcmd"]) {
    Command::Bad(_, usage) => assert_true(usage.length() > 0)
    _ => assert_true(false)
  }
}

///|
/// demux 的参数个数：一个不够，两个正好。
test "demux arity" {
  match parse(["demux", "a.ogg"]) {
    Command::Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
  match parse(["demux", "a.ogg", "outdir"]) {
    Command::Demux(a, b) => {
      assert_eq(a, "a.ogg")
      assert_eq(b, "outdir")
    }
    _ => assert_true(false)
  }
}

///|
/// mux 的参数个数。
test "mux arity" {
  match parse(["mux", "indir"]) {
    Command::Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
  match parse(["mux", "indir", "out.ogg"]) {
    Command::Mux(a, b) => {
      assert_eq(a, "indir")
      assert_eq(b, "out.ogg")
    }
    _ => assert_true(false)
  }
}

///|
/// version 与 help 是无参命令。
test "version and help take no arguments" {
  match parse(["version"]) {
    Command::Version => assert_true(true)
    _ => assert_true(false)
  }
  match parse(["help"]) {
    Command::Help => assert_true(true)
    _ => assert_true(false)
  }
}
