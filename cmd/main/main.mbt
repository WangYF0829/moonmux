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
/// `demux`：把包按逻辑流分组写成文件。
///
/// 每条逻辑流写进一个子目录 `s1`、`s2`……（按流在文件中首次出现的顺序），
/// 包在子目录内以 `packet_000000.bin` 命名、序号补零到六位。
/// 分组是必要的：包文件本身不带流号，若把所有流平铺进同一个目录，
/// 重新封装时就无法再把它们分开 —— 多逻辑流文件会因此不可逆地退化成单流。
///
/// 每条流原有的流号会打在输出里（重新封装时不沿用，见 `run_mux`）。
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
      let streams = @ogg.group_by_stream(packets)
      if !@fs.path_exists(dir) {
        @fs.create_dir(dir) catch {
          IOError(msg) => {
            println("错误: 无法创建目录 " + dir + " —— " + msg)
            return
          }
        }
      }
      let mut si = 0
      while si < streams.length() {
        let sub = dir + "/s" + (si + 1).to_string()
        if !@fs.path_exists(sub) {
          @fs.create_dir(sub) catch {
            IOError(msg) => {
              println("错误: 无法创建目录 " + sub + " —— " + msg)
              return
            }
          }
        }
        let group = streams[si].packets
        let mut i = 0
        while i < group.length() {
          let name = sub + "/packet_" + pad6(i) + ".bin"
          @fs.write_bytes_to_file(name, group[i].data) catch {
            IOError(msg) => {
              println("错误: 无法写入 " + name + " —— " + msg)
              return
            }
          }
          i = i + 1
        }
        println(
          "  s" +
          (si + 1).to_string() +
          "  serial=" +
          streams[si].serial.to_string() +
          "  包数=" +
          group.length().to_string(),
        )
        si = si + 1
      }
      println(
        "已写出 " +
        packets.length().to_string() +
        " 个包 / " +
        streams.length().to_string() +
        " 条逻辑流到 " +
        dir,
      )
    }
  }
}

///|
/// 一次封装的结果：写出的页、涉及多少包、多少条逻辑流。
struct MuxPlan {
  pages : Array[@ogg.Page]
  packets : Int
  streams : Int
}

///|
/// 列出目录下的普通文件名，按名字典序。
fn files_in(dir : String) -> Result[Array[String], String] {
  let entries = @fs.read_dir(dir) catch {
    IOError(msg) => return Err("无法读取目录 " + dir + " —— " + msg)
  }
  let names : Array[String] = []
  for e in entries {
    let isf = @fs.is_file(dir + "/" + e) catch {
      _ => false
    }
    if isf {
      names.push(e)
    }
  }
  names.sort()
  Ok(names)
}

///|
/// 列出目录下的子目录名，按名字典序。
fn subdirs_in(dir : String) -> Result[Array[String], String] {
  let entries = @fs.read_dir(dir) catch {
    IOError(msg) => return Err("无法读取目录 " + dir + " —— " + msg)
  }
  let names : Array[String] = []
  for e in entries {
    let isf = @fs.is_file(dir + "/" + e) catch {
      _ => false
    }
    if !isf {
      names.push(e)
    }
  }
  names.sort()
  Ok(names)
}

///|
/// 按目录布局决定封装方式，产出要写出的页。
///
/// 目录里**有子目录**时，每个子目录是一条逻辑流（按名字典序，
/// 也就是 BOS 页的先后）；**没有子目录**时，整个目录是一条逻辑流。
///
/// 两种布局混在一起时直接报错而不是挑一种：无论选哪一种都会漏掉另一半数据，
/// 而这种遗漏在产出的文件里看不出来 —— 文件照样能解析，只是少了一条流。
///
/// 流号在封装时重新编号为 1、2、3……，不沿用原文件的流号：
/// 包文件里不带流号，目录布局只表达了「有几条流、各自有哪些包」。
/// 原流号在 `demux` 的输出里已经给出。
fn plan_mux(dir : String) -> Result[MuxPlan, String] {
  let subs = match subdirs_in(dir) {
    Ok(v) => v
    Err(m) => return Err(m)
  }
  let loose = match files_in(dir) {
    Ok(v) => v
    Err(m) => return Err(m)
  }
  if subs.length() > 0 && loose.length() > 0 {
    return Err(
      "目录里既有子目录又有散落的包文件，无法确定封装方式 —— " +
      dir +
      "\n  多逻辑流：每条流一个子目录，且目录下不再放散落的包文件" +
      "\n  单逻辑流：删掉子目录，把包直接放在 " +
      dir,
    )
  }
  if subs.length() == 0 && loose.length() == 0 {
    return Err("目录中没有包文件 —— " + dir)
  }
  if subs.length() == 0 {
    // 单条逻辑流
    let packets : Array[@ogg.Packet] = []
    for n in loose {
      let data = @fs.read_file_to_bytes(dir + "/" + n) catch {
        IOError(msg) => return Err("无法读取包文件 " + n + " —— " + msg)
      }
      // 包文件里不带粒度位置信息，统一写 0
      packets.push({ data, granule_position: 0L, serial: 1U })
    }
    Ok({
      pages: @ogg.paginate(packets, 1U),
      packets: packets.length(),
      streams: 1,
    })
  } else {
    // 多条逻辑流
    let streams : Array[@ogg.LogicalStream] = []
    let mut total = 0
    let mut si = 0
    while si < subs.length() {
      let sub = dir + "/" + subs[si]
      let names = match files_in(sub) {
        Ok(v) => v
        Err(m) => return Err(m)
      }
      if names.length() == 0 {
        return Err(
          "子目录 " + subs[si] + " 中没有包文件 —— 空逻辑流无法封装",
        )
      }
      let serial = (si + 1).reinterpret_as_uint()
      let packets : Array[@ogg.Packet] = []
      for n in names {
        let data = @fs.read_file_to_bytes(sub + "/" + n) catch {
          IOError(msg) => return Err("无法读取包文件 " + n + " —— " + msg)
        }
        packets.push({ data, granule_position: 0L, serial })
      }
      total = total + packets.length()
      streams.push({ serial, packets })
      si = si + 1
    }
    // 交织规则（BOS 页置顶、按粒度升序）全在容器层，这里不碰
    match @ogg.mux_streams(streams) {
      Err(m) => Err(m)
      Ok(pages) => Ok({ pages, packets: total, streams: streams.length() })
    }
  }
}

///|
/// `mux`：把目录中的包封装成一个 Ogg 文件。
///
/// 单流与多流由目录布局决定（见 `plan_mux`），页的切分与交织交给容器层：
/// 由它保证单页段数不超过 255、超长包跨页承载、首页 BOS / 末页 EOS，
/// 以及多流时 BOS 页置顶、数据页按粒度升序交织。
/// 这些规则手工拼页时极易写错（尤其是超长包），放在容器层才能被测试钉住。
fn run_mux(dir : String, out : String) -> Unit {
  match plan_mux(dir) {
    Err(msg) => println("错误: " + msg)
    Ok(plan) => {
      @fs.write_bytes_to_file(out, @ogg.serialize_pages(plan.pages)) catch {
        IOError(msg) => {
          println("错误: 无法写入 " + out + " —— " + msg)
          return
        }
      }
      println(
        "已写出 " +
        plan.packets.to_string() +
        " 个包 / " +
        plan.streams.to_string() +
        " 条逻辑流 / " +
        plan.pages.length().to_string() +
        " 页到 " +
        out,
      )
    }
  }
}

///|
/// `verify`：逐页重算 CRC，报告通过率。
///
/// 这是独立于序列化路径的再次计算：对文件里每一页的字节重算校验值，
/// 与页头存着的 `crc` 字段比对。它是判断「文件是容器损坏还是编码问题」
/// 的第一道分诊 —— 损坏的页会被精确指出来，而不是留到解码阶段才爆发。
fn run_verify(path : String) -> Unit {
  match read_all(path) {
    None => ()
    Some(data) => {
      let pages = @ogg.parse_pages(data)
      if pages.length() == 0 {
        println("错误: 不是合法的 Ogg 文件 —— " + path)
        return
      }
      let mut ok = 0
      let mut bad = 0
      for page in pages {
        if @ogg.page_crc_ok(page) {
          ok = ok + 1
        } else {
          bad = bad + 1
        }
      }
      println("文件:     " + path)
      println("字节数:   " + data.length().to_string())
      println("页数:     " + pages.length().to_string())
      println("CRC 通过: " + ok.to_string() + "  失败: " + bad.to_string())
      if bad == 0 {
        println("结论:     全部页 CRC 自洽")
      } else {
        println("结论:     有 " + bad.to_string() + " 页 CRC 不匹配，文件已损坏")
      }
    }
  }
}

///|
/// `to-wav`：把 Ogg（Opus / Vorbis）转码成 WAV（16 位 PCM）。
///
/// 这一层只做 I/O：识别与解码都在 `pipeline/` 里，WAV 编码在 `wav/` 里。
/// 解码失败时如实把原因打出来 —— 解码器的能力是有范围的，
/// 把一个「超出范围」的流说清楚，好过写出一个安静的空文件。
fn run_towav(src : String, out : String) -> Unit {
  match read_all(src) {
    None => ()
    Some(data) => {
      match @pipeline.ogg_to_wav(data) {
        Err(msg) => println("错误: 转码失败 —— " + msg)
        Ok(wav) => {
          @fs.write_bytes_to_file(out, wav) catch {
            IOError(msg) => {
              println("错误: 无法写入 " + out + " —— " + msg)
              return
            }
          }
          // 回读一遍，确认产出的 WAV 能被子模块自己解析回来
          match @wav.WavFile::parse(wav) {
            None => println("已写出 " + out + "，但回读校验未通过")
            Some(f) => println(
              "已写出 " +
              out +
              "  " +
              f.format.channels.to_string() +
              " 声道 / " +
              f.format.sample_rate.to_string() +
              " Hz / " +
              f.format.bits_per_sample.to_string() +
              " 位 / " +
              f.data.length().to_string() +
              " 字节 PCM",
            )
          }
        }
      }
    }
  }
}

///|
/// 把包序号补零到**固定六位**，用于包文件名排序。
///
/// 位数必须固定，不能按实际包数收缩：文件名是按字符串排序的，
/// 位数不一致时 "1000" 会插在 "100" 与 "101" 之间（第三位 '0' < '1'），
/// 包数超过 999 就会静默乱序。三分钟的音频轻轻松松就有九千个包，
/// 所以这里直接留够六位。
fn pad6(n : Int) -> String {
  let s = n.to_string()
  let mut zeros = ""
  let mut i = s.length()
  while i < 6 {
    zeros = zeros + "0"
    i = i + 1
  }
  zeros + s
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
    @cli.Command::Verify(path) => run_verify(path)
    @cli.Command::ToWav(src, out) => run_towav(src, out)
    @cli.Command::Version => println(@moonmux.describe())
    @cli.Command::Help => println(@cli.usage())
    @cli.Command::Bad(msg, usage) => {
      println("错误: " + msg)
      println("")
      println(usage)
    }
  }
}
