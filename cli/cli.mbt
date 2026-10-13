// cli.mbt —— 命令行参数解析
//
// 把 argv 映射成一个 Command 值。所有分支都在这里判定，
// 不产生任何副作用，便于测试。

///|
/// 一条解析后的命令。
pub(all) enum Command {
  /// 查看 Ogg 文件的容器信息
  Info(String)
  /// 从 Ogg 文件拆出包，写入指定目录
  Demux(String, String)
  /// 把目录中的包封装成 Ogg 文件
  Mux(String, String)
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
  "  moonmux demux <file.ogg> <dir>   把包拆到目录\n" +
  "  moonmux mux <dir> <out.ogg>      把包封装成 Ogg\n" +
  "  moonmux version                  打印版本\n" +
  "  moonmux help                     显示本帮助"
}

///|
/// 针对单个子命令的用法文本。
pub fn usage_for(topic : String) -> String {
  if topic == "info" {
    "用法: moonmux info <file.ogg>"
  } else if topic == "demux" {
    "用法: moonmux demux <file.ogg> <dir>"
  } else if topic == "mux" {
    "用法: moonmux mux <dir> <out.ogg>"
  } else {
    usage()
  }
}

///|
/// 解析命令行参数（不含可执行文件名本身）。
pub fn parse(args : Array[String]) -> Command {
  if args.length() == 0 {
    return Command::Help
  }
  let sub = args[0]
  if sub == "info" {
    if args.length() < 2 {
      Command::Bad("info 需要一个 Ogg 文件路径", usage_for("info"))
    } else {
      Command::Info(args[1])
    }
  } else if sub == "demux" {
    if args.length() < 3 {
      Command::Bad("demux 需要输入文件与输出目录", usage_for("demux"))
    } else {
      Command::Demux(args[1], args[2])
    }
  } else if sub == "mux" {
    if args.length() < 3 {
      Command::Bad("mux 需要输入目录与输出文件", usage_for("mux"))
    } else {
      Command::Mux(args[1], args[2])
    }
  } else if sub == "version" {
    Command::Version
  } else if sub == "help" {
    Command::Help
  } else {
    Command::Bad("未知子命令: " + sub, usage())
  }
}
