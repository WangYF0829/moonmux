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
/// `info`：报告容器层信息，自动识别 Ogg 与 WAV。
///
/// 只读容器结构，不解码音频 —— 因此任何格式的 Ogg（Opus、Vorbis、
/// 甚至非音频的逻辑流）都能给出页数、包数与流号；
/// WAV 则给出声道、采样率与时长。
/// 识别依据是文件头（`OggS` / `RIFF`），不是扩展名。
fn run_info(path : String) -> Unit {
  match read_all(path) {
    None => ()
    Some(data) => {
      if @ogg.is_page_start(data, 0) {
        show_ogg_info(path, data)
      } else {
        match @wav.WavFile::parse(data) {
          Some(f) => show_wav_info(path, data, f)
          None => println("错误: 既不是 Ogg 也不是 WAV —— " + path)
        }
      }
    }
  }
}

///|
/// 打印 Ogg 的容器信息。
///
/// 每条逻辑流除了页数与负载字节，还给出「末粒度」——
/// 该流最后一次出现的粒度位置。粒度就是时间（对音频流而言即采样点数），
/// 它是容器层能拿到的唯一时长线索；要换算成秒需要知道采样率，
/// 那属于编码层的信息，这里不猜。
///
/// 物理流与逻辑流是两层：一个文件里可以串接多条物理流（链接流），
/// 每条物理流里再交织多条逻辑流。链接流要单独说明 ——
/// 它的页数、包数是所有段的总和，只看总数会以为是一条很长的流。
fn show_ogg_info(path : String, data : Bytes) -> Unit {
  let pages = @ogg.parse_pages(data)
  if pages.length() == 0 {
    println("错误: 不是合法的 Ogg 文件 —— " + path)
    return
  }
  let packets = @ogg.reassemble(pages)
  println("文件:   " + path)
  println("格式:   Ogg")
  println("字节数: " + data.length().to_string())
  println("页数:   " + pages.length().to_string())
  println("包数:   " + packets.length().to_string())
  let chains = @ogg.split_chains(pages)
  println("物理流: " + chains.length().to_string())
  let serials = @ogg.serials_of(pages)
  println("逻辑流: " + serials.length().to_string())
  let mut si = 0
  while si < serials.length() {
    let s = serials[si]
    let mut page_count = 0
    let mut byte_count = 0
    let mut last_granule : Int64 = -1L
    let mut has_granule = false
    for page in pages {
      if page.serial == s {
        page_count = page_count + 1
        byte_count = byte_count + page.payload.length()
        // -1 表示本页没有包结束，不代表时间
        if page.granule_position >= 0L {
          last_granule = page.granule_position
          has_granule = true
        }
      }
    }
    // 序号是给 `extract` 用的选择符，打出来才不用手工数
    let mut line = "  " +
      (si + 1).to_string() +
      ") serial=" +
      s.to_string() +
      " 页=" +
      page_count.to_string() +
      " 负载字节=" +
      byte_count.to_string()
    if has_granule {
      line = line + " 末粒度=" + last_granule.to_string()
    }
    println(line)
    si = si + 1
  }
  // 链接流逐段列出：段与段之间没有共享的流号，
  // 光看总数看不出这份文件其实是好几段拼起来的
  if chains.length() > 1 {
    let mut ci = 0
    while ci < chains.length() {
      let part = chains[ci]
      println(
        "  第 " +
        (ci + 1).to_string() +
        " 段: " +
        part.length().to_string() +
        " 页 / " +
        @ogg.serials_of(part).length().to_string() +
        " 条逻辑流 / " +
        @ogg.reassemble(part).length().to_string() +
        " 包",
      )
      ci = ci + 1
    }
    println("  （链接流：以上各段首尾相接，段间流号互不复用）")
  }
}

///|
/// 打印 WAV 的容器信息。
///
/// 时长按帧数换算：帧数 = PCM 字节数 ÷（声道 × 位深/8），
/// 秒 = 帧数 ÷ 采样率。全部用整数算，避免浮点把「6 秒」显示成 5.999。
fn show_wav_info(path : String, data : Bytes, f : @wav.WavFile) -> Unit {
  println("文件:   " + path)
  println("格式:   WAV（RIFF/PCM）")
  println("字节数: " + data.length().to_string())
  println("声道:   " + f.format.channels.to_string())
  println("采样率: " + f.format.sample_rate.to_string() + " Hz")
  println("位深:   " + f.format.bits_per_sample.to_string() + " 位")
  println("PCM:    " + f.data.length().to_string() + " 字节")
  let frame_size = f.format.channels * (f.format.bits_per_sample / 8)
  if frame_size > 0 && f.format.sample_rate > 0 {
    let frames = f.data.length() / frame_size
    let whole = frames / f.format.sample_rate
    let frac = (frames % f.format.sample_rate) * 100 / f.format.sample_rate
    println(
      "帧数:   " +
      frames.to_string() +
      "（约 " +
      whole.to_string() +
      "." +
      pad2(frac) +
      " 秒）",
    )
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
/// `cat`：把多个 Ogg 文件首尾链接成一条物理流（chained bitstream）。
///
/// 链接规则在容器层 `chain` 里：流号不冲突时原样透传（字节级无损），
/// 冲突时后一方的相撞流换新流号重新分页。这里只做 I/O 与逐个衔接，
/// 中途有一个文件读不出或不是 Ogg，就整趟不出（半截链没有意义）。
fn run_cat(inputs : Array[String], out : String) -> Unit {
  let mut acc : Array[@ogg.Page] = []
  let mut ok = true
  let mut i = 0
  while ok && i < inputs.length() {
    match read_all(inputs[i]) {
      None => ok = false
      Some(data) => {
        let pages = @ogg.parse_pages(data)
        if pages.length() == 0 {
          println("错误: 不是合法的 Ogg 文件 —— " + inputs[i])
          ok = false
        } else {
          match @ogg.chain(acc, pages) {
            Err(msg) => {
              println("错误: 链接失败 —— " + msg)
              ok = false
            }
            Ok(merged) => acc = merged
          }
        }
      }
    }
    i = i + 1
  }
  if ok {
    @fs.write_bytes_to_file(out, @ogg.serialize_pages(acc)) catch {
      IOError(msg) => {
        println("错误: 无法写入 " + out + " —— " + msg)
        return
      }
    }
    println(
      "已链接 " +
      inputs.length().to_string() +
      " 个文件 / " +
      acc.length().to_string() +
      " 页 / " +
      @ogg.serials_of(acc).length().to_string() +
      " 条逻辑流到 " +
      out,
    )
  }
}

///|
/// `split`：把一条链接流按链接点拆成各自独立的 Ogg 文件。
///
/// 切分依据与重写与否全在容器层 `split_chains` 里，这里只做 I/O：
/// 每段写成 `<dir>/part1.ogg`、`part2.ogg`…… 页对象原样沿用，
/// 字节与 CRC 一个都不动 —— 非链接流因此得到的 part1 与输入逐字节相同。
/// 拆开是有用的：链接流的各段互不共享流号，播放器按段重新初始化解码器，
/// 单独取出其中一段交给下游工具时，其余段是多余的负担。
fn run_split(src : String, dir : String) -> Unit {
  match read_all(src) {
    None => ()
    Some(data) => {
      let pages = @ogg.parse_pages(data)
      if pages.length() == 0 {
        println("错误: 不是合法的 Ogg 文件 —— " + src)
        return
      }
      let parts = @ogg.split_chains(pages)
      if !@fs.path_exists(dir) {
        @fs.create_dir(dir) catch {
          IOError(msg) => {
            println("错误: 无法创建目录 " + dir + " —— " + msg)
            return
          }
        }
      }
      let mut i = 0
      let mut ok = true
      while ok && i < parts.length() {
        let name = dir + "/part" + (i + 1).to_string() + ".ogg"
        @fs.write_bytes_to_file(name, @ogg.serialize_pages(parts[i])) catch {
          IOError(msg) => {
            println("错误: 无法写入 " + name + " —— " + msg)
            ok = false
          }
        }
        if ok {
          println(
            "  part" +
            (i + 1).to_string() +
            ".ogg  " +
            parts[i].length().to_string() +
            " 页 / " +
            @ogg.serials_of(parts[i]).length().to_string() +
            " 条逻辑流",
          )
        }
        i = i + 1
      }
      if ok {
        if parts.length() == 1 {
          println(
            "该文件不是链接流，已原样写出到 " + dir + "/part1.ogg",
          )
        } else {
          println("已拆出 " + parts.length().to_string() + " 条物理流到 " + dir)
        }
      }
    }
  }
}

///|
/// `extract`：抽出一条逻辑流，写成独立的 Ogg 文件。
///
/// 抽流是筛选而不是重写（见容器层的 `stream_pages`）：页级原样透传，
/// 因此产物与输入里属于该流的那几页逐字节相同，可以拿去做对账。
/// 选择符是 1 起算的逻辑流序号，与 `info` 列出的顺序一致。
///
/// 与 `demux` 的分工：`demux` 拆到**包**（丢掉页边界与粒度位置，
/// 适合拿去处理音频数据），`extract` 抽到**流**（保持页级原样，
/// 适合把文件里的某一条轨道单独取出来用）。
fn run_extract(src : String, index : Int, out : String) -> Unit {
  match read_all(src) {
    None => ()
    Some(data) => {
      let pages = @ogg.parse_pages(data)
      if pages.length() == 0 {
        println("错误: 不是合法的 Ogg 文件 —— " + src)
        return
      }
      let serial = match @ogg.serial_at(pages, index) {
        Ok(s) => s
        Err(msg) => {
          println("错误: " + msg)
          return
        }
      }
      let stream = @ogg.stream_pages(pages, serial)
      @fs.write_bytes_to_file(out, @ogg.serialize_pages(stream)) catch {
        IOError(msg) => {
          println("错误: 无法写入 " + out + " —— " + msg)
          return
        }
      }
      println(
        "已抽出第 " +
        index.to_string() +
        " 条逻辑流（serial=" +
        serial.to_string() +
        "）：" +
        stream.length().to_string() +
        " 页 / " +
        @ogg.reassemble(stream).length().to_string() +
        " 包 → " +
        out,
      )
    }
  }
}

///|
/// `dump`：把页级结构摊成一张表。
///
/// `info` 给汇总、`verify` 给结论，这张表给的是**页本身长什么样** ——
/// `verify` 报出「serial=2 页序号从 202 跳到 204」之后，
/// 要接着看的就是 200 号附近那几页。偏移列可以直接和十六进制编辑器对照。
fn run_dump(path : String) -> Unit {
  match read_all(path) {
    None => ()
    Some(data) => {
      let pages = @ogg.parse_pages(data)
      if pages.length() == 0 {
        println("错误: 不是合法的 Ogg 文件 —— " + path)
        return
      }
      println("文件: " + path)
      println("页数: " + pages.length().to_string())
      println(@ogg.page_table_header())
      for line in @ogg.describe_pages(pages) {
        println(line)
      }
    }
  }
}

///|
/// `verify`：对 Ogg 文件做完整体检。
///
/// CRC 逐页重算（独立于序列化路径的再计算），结构层查四件事：
/// 段表与负载是否一致、每条流的页序号是否连续、首末页 BOS / EOS 是否到位。
/// CRC 全绿只说明字节没坏 —— 页序号跳号意味着丢页，缺 BOS / EOS
/// 意味着头尾被截，这些都要到播放时才出症状，这里提前指出来。
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
      let problems = @ogg.structure_problems(pages)
      println("文件:     " + path)
      println("字节数:   " + data.length().to_string())
      println("页数:     " + pages.length().to_string())
      println("物理流:   " + @ogg.split_chains(pages).length().to_string())
      println("逻辑流:   " + @ogg.serials_of(pages).length().to_string())
      println("CRC 通过: " + ok.to_string() + "  失败: " + bad.to_string())
      println("结构问题: " + problems.length().to_string())
      // 只铺前 10 条：坏了大半的文件逐条打出来只会淹没结论，
      // 但省略要明说 —— 闷声少报等于把问题藏起来
      let mut shown = 0
      for p in problems {
        if shown < 10 {
          println("  - " + p)
          shown = shown + 1
        }
      }
      if problems.length() > 10 {
        println(
          "  ……另有 " +
          (problems.length() - 10).to_string() +
          " 处（以上为前 10 处）",
        )
      }
      if bad == 0 && problems.length() == 0 {
        println("结论:     结构完好（CRC、页序号、BOS·EOS 全部自洽）")
      } else {
        println(
          "结论:     共 " +
          (bad + problems.length()).to_string() +
          " 处问题",
        )
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
///
/// 输入可能同时含多条逻辑流与多段链接流，而 WAV 里只装得下一条音轨。
/// 转码取每段的第一条可识别音频流；输入不是单流时先把这件事说清楚，
/// 免得用户以为文件里的其余轨道也进了 WAV。
fn run_towav(src : String, out : String) -> Unit {
  match read_all(src) {
    None => ()
    Some(data) => {
      let pages = @ogg.parse_pages(data)
      let streams = @ogg.serials_of(pages)
      let chains = @ogg.split_chains(pages)
      if streams.length() > 1 || chains.length() > 1 {
        println(
          "提示: 输入含 " +
          chains.length().to_string() +
          " 条物理流 / " +
          streams.length().to_string() +
          " 条逻辑流，只转码每段的第一条可识别音频流",
        )
      }
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
/// 把不足 10 的数补一位零。
fn pad2(n : Int) -> String {
  if n < 10 {
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
    @cli.Command::Cat(inputs, out) => run_cat(inputs, out)
    @cli.Command::Split(src, dir) => run_split(src, dir)
    @cli.Command::Extract(src, index, out) => run_extract(src, index, out)
    @cli.Command::Dump(path) => run_dump(path)
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
