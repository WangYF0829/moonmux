// cli.mbt —— 命令行参数解析
//
// 把 argv 映射成一个 Command 值。所有分支都在这里判定，
// 不产生任何副作用，便于测试。
//
// 参数个数是**严格**的：多给的参数会被报错，而不是静默忽略。
// 「多给的参数被静默忽略」是同类入口最常见的 bug 之一 ——
// 用户以为自己改了输出路径，程序却按默认行为跑完了。

///|
/// 一条解析后的命令。
pub(all) enum Command {
  /// 查看 Ogg 文件的容器信息
  Info(String)
  /// 从 Ogg 文件拆出包，写入指定目录
  Demux(String, String)
  /// 把目录中的包封装成 Ogg 文件
  Mux(String, String)
  /// 把多个 Ogg 文件首尾链接（chained）
  Cat(Array[String], String)
  /// 把一条链接流按链接点拆成多个 Ogg 文件
  Split(String, String)
  /// 抽出第 n 条逻辑流，写成独立的 Ogg 文件
  Extract(String, Int, String)
  /// 转储页级结构
  Dump(String)
  /// 逐页重算 CRC，报告通过率
  Verify(String)
  /// 把 Ogg（Opus / Vorbis）转码为 WAV
  ToWav(String, String)
  /// 打印版本
  Version
  /// 打印总用法
  Help
  /// 参数错误：错误说明 + 相关用法
  Bad(String, String)
}

///|
/// 总用法文本。
pub fn usage() -> String {
  "moonmux —— MoonBit 音频容器工具\n" +
  "\n" +
  "用法:\n" +
  "  moonmux info <file>              查看容器信息（Ogg 或 WAV）\n" +
  "  moonmux demux <file.ogg> <dir>   按逻辑流拆到目录（每流一个子目录）\n" +
  "  moonmux mux <dir> <out.ogg>      把包封装成 Ogg（子目录即逻辑流）\n" +
  "  moonmux cat <in1.ogg> <in2.ogg> ... <out.ogg>\n" +
  "                                  把多个 Ogg 首尾链接（chained）\n" +
  "  moonmux split <file.ogg> <dir>   把链接流按链接点拆开（输出 part1/2…）\n" +
  "  moonmux extract <file.ogg> <n> <out.ogg>\n" +
  "                                  抽出第 n 条逻辑流（序号见 info）\n" +
  "  moonmux dump <file.ogg>          转储页级结构（偏移/流号/页序/粒度/标志）\n" +
  "  moonmux verify <file.ogg>        结构体检（CRC / 页序号 / BOS·EOS）\n" +
  "  moonmux to-wav <in.ogg> <out.wav> 转码为 WAV\n" +
  "  moonmux version                  打印版本\n" +
  "  moonmux help                     显示本帮助"
}

///|
/// 针对单个子命令的用法文本。
pub fn usage_for(topic : String) -> String {
  if topic == "info" {
    "用法: moonmux info <file.ogg>"
  } else if topic == "demux" {
    "用法: moonmux demux <file.ogg> <dir>\n" +
    "  <dir> 下每条逻辑流一个子目录：s1/、s2/……"
  } else if topic == "mux" {
    "用法: moonmux mux <dir> <out.ogg>\n" +
    "  <dir> 下有子目录时，每个子目录是一条逻辑流；否则整目录是一条"
  } else if topic == "cat" {
    "用法: moonmux cat <in1.ogg> <in2.ogg> ... <out.ogg>\n" +
    "  末位参数是输出文件，其余均为输入；至少两个输入"
  } else if topic == "split" {
    "用法: moonmux split <file.ogg> <dir>\n" +
    "  每条物理流写成 <dir>/part1.ogg、part2.ogg……\n" +
    "  非链接流只写出 part1.ogg，与输入逐字节相同"
  } else if topic == "extract" {
    "用法: moonmux extract <file.ogg> <n> <out.ogg>\n" +
    "  <n> 是 1 起算的逻辑流序号，与 info 列出的顺序一致\n" +
    "  抽出的文件与该流在输入里的那几页逐字节相同"
  } else if topic == "dump" {
    "用法: moonmux dump <file.ogg>\n" +
    "  逐页列出偏移、流号、页序、粒度位置、头标志、段数与负载字节"
  } else if topic == "verify" {
    "用法: moonmux verify <file.ogg>"
  } else if topic == "to-wav" {
    "用法: moonmux to-wav <in.ogg> <out.wav>"
  } else if topic == "version" {
    "用法: moonmux version"
  } else if topic == "help" {
    "用法: moonmux help"
  } else {
    usage()
  }
}

///|
/// 参数个数不符时的统一报错文本。`got` / `want` 均不含子命令本身。
fn arity_msg(sub : String, got : Int, want : Int) -> String {
  sub + " 需要 " + want.to_string() + " 个参数，实际给了 " + got.to_string() + " 个"
}

///|
/// 解析一个正整数参数：只认十进制数字，且必须大于 0。
///
/// 刻意不接受 `+1`、`01`、`1.0`、`0`、`-1` 这些写法 —— 逻辑流序号没有
/// 「+1」或「第 0 条」这种说法，收下它们只会让错误延后到取流时才暴露，
/// 而且报出来的会是别的错（找不到流），不是「参数写错了」。
///
/// 手写而不引 `strconv`：这一层至今不引任何包，而这里要的语义比
/// 通用解析窄得多，窄语义自己写反而更清楚。
fn parse_positive(s : String) -> Int? {
  if s.length() == 0 {
    return None
  }
  let mut n = 0
  let mut i = 0
  while i < s.length() {
    // 逐**字符**取，不用 `to_bytes()` —— 后者给出的是 UTF-16 码元
    // （每字符两字节，ASCII 的高位字节是 0），按它逐字节判数字会全判错。
    match s.get_char(i) {
      Some(c) => {
        let d = c.to_int()
        if d < 48 || d > 57 {
          return None
        }
        n = n * 10 + (d - 48)
      }
      None => return None
    }
    i = i + 1
  }
  if n <= 0 {
    None
  } else {
    Some(n)
  }
}

///|
/// 解析命令行参数（不含可执行文件名本身）。
pub fn parse(args : Array[String]) -> Command {
  if args.length() == 0 {
    return Command::Help
  }
  let sub = args[0]
  // 子命令之后的参数个数
  let n = args.length() - 1
  if sub == "info" {
    if n < 1 {
      Command::Bad("info 需要一个 Ogg 文件路径", usage_for("info"))
    } else if n > 1 {
      Command::Bad(arity_msg("info", n, 1), usage_for("info"))
    } else {
      Command::Info(args[1])
    }
  } else if sub == "demux" {
    if n < 2 {
      Command::Bad("demux 需要输入文件与输出目录", usage_for("demux"))
    } else if n > 2 {
      Command::Bad(arity_msg("demux", n, 2), usage_for("demux"))
    } else {
      Command::Demux(args[1], args[2])
    }
  } else if sub == "mux" {
    if n < 2 {
      Command::Bad("mux 需要输入目录与输出文件", usage_for("mux"))
    } else if n > 2 {
      Command::Bad(arity_msg("mux", n, 2), usage_for("mux"))
    } else {
      Command::Mux(args[1], args[2])
    }
  } else if sub == "cat" {
    // cat 的输入个数不限，但至少要两个输入加一个输出
    if n < 3 {
      Command::Bad("cat 需要至少两个输入文件与一个输出文件", usage_for("cat"))
    } else {
      let inputs : Array[String] = []
      let mut i = 1
      while i < n {
        inputs.push(args[i])
        i = i + 1
      }
      Command::Cat(inputs, args[n])
    }
  } else if sub == "split" {
    if n < 2 {
      Command::Bad("split 需要输入文件与输出目录", usage_for("split"))
    } else if n > 2 {
      Command::Bad(arity_msg("split", n, 2), usage_for("split"))
    } else {
      Command::Split(args[1], args[2])
    }
  } else if sub == "extract" {
    if n < 3 {
      Command::Bad(
        "extract 需要输入文件、逻辑流序号与输出文件",
        usage_for("extract"),
      )
    } else if n > 3 {
      Command::Bad(arity_msg("extract", n, 3), usage_for("extract"))
    } else {
      match parse_positive(args[2]) {
        None =>
          Command::Bad(
            "extract 的逻辑流序号必须是正整数，实际是「" + args[2] + "」",
            usage_for("extract"),
          )
        Some(k) => Command::Extract(args[1], k, args[3])
      }
    }
  } else if sub == "dump" {
    if n < 1 {
      Command::Bad("dump 需要一个 Ogg 文件路径", usage_for("dump"))
    } else if n > 1 {
      Command::Bad(arity_msg("dump", n, 1), usage_for("dump"))
    } else {
      Command::Dump(args[1])
    }
  } else if sub == "verify" {
    if n < 1 {
      Command::Bad("verify 需要一个 Ogg 文件路径", usage_for("verify"))
    } else if n > 1 {
      Command::Bad(arity_msg("verify", n, 1), usage_for("verify"))
    } else {
      Command::Verify(args[1])
    }
  } else if sub == "to-wav" {
    if n < 2 {
      Command::Bad("to-wav 需要输入文件与输出文件", usage_for("to-wav"))
    } else if n > 2 {
      Command::Bad(arity_msg("to-wav", n, 2), usage_for("to-wav"))
    } else {
      Command::ToWav(args[1], args[2])
    }
  } else if sub == "version" {
    if n > 0 {
      Command::Bad(arity_msg("version", n, 0), usage_for("version"))
    } else {
      Command::Version
    }
  } else if sub == "help" {
    if n > 0 {
      Command::Bad(arity_msg("help", n, 0), usage_for("help"))
    } else {
      Command::Help
    }
  } else {
    Command::Bad("未知子命令: " + sub, usage())
  }
}
