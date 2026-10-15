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

///|
/// 多余的参数必须被报错，而不是静默忽略。
///
/// 这是同类入口最常见的 bug，也是本项目设计文档点名要钉住的一类：
/// 用户以为自己改了参数，程序却按默认行为跑完，结果与预期不符却无任何提示。
test "extra arguments are rejected, not ignored" {
  match parse(["info", "a.ogg", "extra"]) {
    Command::Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
  match parse(["demux", "a.ogg", "dir", "extra"]) {
    Command::Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
  match parse(["mux", "dir", "out.ogg", "extra"]) {
    Command::Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
  match parse(["version", "junk"]) {
    Command::Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
  match parse(["help", "junk"]) {
    Command::Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
}

///|
/// `to-wav` 子命令的参数个数。
test "to-wav arity" {
  match parse(["to-wav"]) {
    Command::Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
  match parse(["to-wav", "a.ogg"]) {
    Command::Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
  match parse(["to-wav", "a.ogg", "b.wav"]) {
    Command::ToWav(a, b) => {
      assert_eq(a, "a.ogg")
      assert_eq(b, "b.wav")
    }
    _ => assert_true(false)
  }
  match parse(["to-wav", "a.ogg", "b.wav", "c"]) {
    Command::Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
}

///|
/// `verify` 子命令的参数个数。
test "verify arity" {
  match parse(["verify"]) {
    Command::Bad(msg, usage) => {
      assert_true(msg.length() > 0)
      assert_true(usage.length() > 0)
    }
    _ => assert_true(false)
  }
  match parse(["verify", "a.ogg"]) {
    Command::Verify(p) => assert_eq(p, "a.ogg")
    _ => assert_true(false)
  }
  match parse(["verify", "a.ogg", "b.ogg"]) {
    Command::Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
}

///|
/// `cat` 的输入个数不限，但「至少两个输入 + 一个输出」要卡住：
/// 少于这个数就没有「链接」可言，静默按单文件处理只会让用户误以为拼上了。
///
/// 末位参数是输出文件 —— 这与 `demux` / `mux` / `to-wav` 的
/// 「输入在前、输出在后」约定一致。
test "cat arity" {
  match parse(["cat"]) {
    Command::Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
  match parse(["cat", "a.ogg"]) {
    Command::Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
  match parse(["cat", "a.ogg", "out.ogg"]) {
    Command::Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
  match parse(["cat", "a.ogg", "b.ogg", "out.ogg"]) {
    Command::Cat(inputs, out) => {
      assert_eq(inputs.length(), 2)
      assert_eq(inputs[0], "a.ogg")
      assert_eq(inputs[1], "b.ogg")
      assert_eq(out, "out.ogg")
    }
    _ => assert_true(false)
  }
  // 三个输入也要能收下
  match parse(["cat", "a.ogg", "b.ogg", "c.ogg", "out.ogg"]) {
    Command::Cat(inputs, out) => {
      assert_eq(inputs.length(), 3)
      assert_eq(inputs[2], "c.ogg")
      assert_eq(out, "out.ogg")
    }
    _ => assert_true(false)
  }
}

///|
/// `split` 是 `cat` 的逆操作，参数形态与 `demux` 一致（输入 + 输出目录）。
test "split arity" {
  match parse(["split"]) {
    Command::Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
  match parse(["split", "a.ogg"]) {
    Command::Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
  match parse(["split", "a.ogg", "outdir"]) {
    Command::Split(a, b) => {
      assert_eq(a, "a.ogg")
      assert_eq(b, "outdir")
    }
    _ => assert_true(false)
  }
  // 多给参数照旧要报错
  match parse(["split", "a.ogg", "outdir", "extra"]) {
    Command::Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
}
