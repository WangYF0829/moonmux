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
  "  moonmux info <file.ogg>          查看容器信息\n" +
  "  moonmux demux <file.ogg> <dir>   按逻辑流拆到目录（每流一个子目录）\n" +
  "  moonmux mux <dir> <out.ogg>      把包封装成 Ogg（子目录即逻辑流）\n" +
  "  moonmux verify <file.ogg>        逐页校验 CRC\n" +
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
