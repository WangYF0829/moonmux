// main.mbt —— 命令行入口
//
// 这一层只做 I/O 与排版。所有参数解释在 cli/，所有容器逻辑在 ogg/ 与 wav/。
// 这里出现任何「判断」都是不该有的 —— 判断应该已经被下层测过了。
//
// IOError 没有实现 Show，因此错误消息统一用模式匹配取出其中的字符串，
// 而不是直接插值。

///|
/// 读取整个文件；失败时打印原因并返回 None。
fn read_all(path : String) -> Bytes? {
  let data = @fs.read_file_to_bytes(path) catch {
    IOError(msg) => {
      println("错误: 无法读取 " + path + " —— " + msg)
      return None
    }
  }
  Some(data)
}

///|
/// `info`：报告一个 Ogg 文件的容器层信息。
///
/// 只读容器结构，不解码音频 —— 因此任何格式的 Ogg（Opus、Vorbis、
/// 甚至非音频的逻辑流）都能给出页数、包数与流号。
fn run_info(path : String) -> Unit {
  match read_all(path) {
    None => ()
    Some(data) => {
      let pages = @ogg.parse_pages(data)
      if pages.length() == 0 {
        println("错误: 不是合法的 Ogg 文件 —— " + path)
        return
      }
      let packets = @ogg.reassemble(pages)
      println("文件:   " + path)
      println("字节数: " + data.length().to_string())
      println("页数:   " + pages.length().to_string())
      println("包数:   " + packets.length().to_string())
      // 汇总出现过的逻辑流
      let serials : Array[UInt] = []
      for page in pages {
        let mut seen = false
        for s in serials {
          if s == page.serial {
            seen = true
          }
        }
        if !seen {
          serials.push(page.serial)
        }
      }
      println("逻辑流: " + serials.length().to_string())
      for s in serials {
        let mut page_count = 0
        let mut byte_count = 0
        for page in pages {
          if page.serial == s {
            page_count = page_count + 1
            byte_count = byte_count + page.payload.length()
          }
        }
        println(
          "  serial=" +
          s.to_string() +
          " 页=" +
          page_count.to_string() +
          " 负载字节=" +
          byte_count.to_string(),
        )
      }
    }
  }
}

///|
/// `demux`：把每个包按序号写成独立文件。
///
/// 输出目录不存在时会先创建。包以 `packet_000.bin` 的形式命名，
/// 序号补零以保证按文件名排序即为时间顺序。
fn run_demux(src : String, dir : String) -> Unit {
  match read_all(src) {
    None => ()
    Some(data) => {
      let pages = @ogg.parse_pages(data)
      if pages.length() == 0 {
        println("错误: 不是合法的 Ogg 文件 —— " + src)
        return
      }
      let packets = @ogg.reassemble(pages)
      if !@fs.path_exists(dir) {
        @fs.create_dir(dir) catch {
          IOError(msg) => {
            println("错误: 无法创建目录 " + dir + " —— " + msg)
            return
          }
        }
      }
      let mut i = 0
      while i < packets.length() {
        let name = dir + "/packet_" + pad3(i) + ".bin"
        @fs.write_bytes_to_file(name, packets[i].data) catch {
          IOError(msg) => {
            println("错误: 无法写入 " + name + " —— " + msg)
            return
          }
        }
        i = i + 1
      }
      println("已写出 " + packets.length().to_string() + " 个包到 " + dir)
    }
  }
}

///|
/// `mux`：把目录中的包按文件名顺序封装成一个 Ogg 文件。
///
/// 这里不做重排或校验：包按文件名字典序拼接，写进单个逻辑流。
/// 第一个包所在页带 BOS 标志，最后一个包所在页带 EOS 标志 ——
/// 这两条是解码器判断流边界的依据，缺了会被认为文件被截断。
fn run_mux(dir : String, out : String) -> Unit {
  let entries = @fs.read_dir(dir) catch {
    IOError(msg) => {
      println("错误: 无法读取目录 " + dir + " —— " + msg)
      return
    }
  }
  // 只收普通文件，跳过子目录
  let bins : Array[String] = []
  for e in entries {
    let isf = @fs.is_file(dir + "/" + e) catch {
      _ => false
    }
    if isf {
      bins.push(e)
    }
  }
  if bins.length() == 0 {
    println("错误: 目录中没有包文件 —— " + dir)
    return
  }
  // 按文件名排序，保证 packet_000 排在最前
  bins.sort()
  let pages : Array[@ogg.Page] = []
  let mut seq = 0
  let mut i = 0
  while i < bins.length() {
    let pkt = @fs.read_file_to_bytes(dir + "/" + bins[i]) catch {
      IOError(msg) => {
        println("错误: 无法读取包文件 —— " + msg)
        return
      }
    }
    let mut header : Byte = (0x00 : Byte)
    if i == 0 {
      header = @ogg.flag_bos()
    }
    let is_last = i == bins.length() - 1
    if is_last {
      header = header | @ogg.flag_eos()
    }
    pages.push({
      header_type: header,
      granule_position: 0L,
      serial: 1U,
      sequence: seq.reinterpret_as_uint(),
      crc: 0U,
      segments: @ogg.segments_for(pkt.length()),
      payload: pkt,
    })
    seq = seq + 1
    i = i + 1
  }
  @fs.write_bytes_to_file(out, @ogg.serialize_pages(pages)) catch {
    IOError(msg) => {
      println("错误: 无法写入 " + out + " —— " + msg)
      return
    }
  }
  println("已写出 " + pages.length().to_string() + " 页到 " + out)
}

///|
/// 把整数补零成三位，用于包文件名排序。
fn pad3(n : Int) -> String {
  if n < 10 {
    "00" + n.to_string()
  } else if n < 100 {
    "0" + n.to_string()
  } else {
    n.to_string()
  }
}

///|
/// 入口：剥掉 argv[0]，其余交给 cli 解析。
fn main {
  let argv = @env.args()
  let rest : Array[String] = []
  let mut i = 1
  while i < argv.length() {
    rest.push(argv[i])
    i = i + 1
  }
  match @cli.parse(rest) {
    @cli.Command::Info(path) => run_info(path)
    @cli.Command::Demux(src, dir) => run_demux(src, dir)
    @cli.Command::Mux(dir, out) => run_mux(dir, out)
    @cli.Command::Version => println(@moonmux.describe())
    @cli.Command::Help => println(@cli.usage())
    @cli.Command::Bad(msg, usage) => {
      println("错误: " + msg)
      println("")
      println(usage)
    }
  }
}
