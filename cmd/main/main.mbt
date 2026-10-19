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
/// 该流最后一次出现的粒度位置。粒度就是时间（对音频流而言即采样点数）。
///
/// 是音频流（首包是 OpusHead 或 Vorbis 识别头）时，再读标识头给出
/// 编码、声道、采样率，并按首末粒度换算成时长（秒）——
/// 头部字段的解析在 codec/，换算公式（减首粒度、减 pre-skip）也在那一层，
/// 这里只做显示。链接流各段的时间轴相互独立，但流号各段不复用，
/// 所以逐流统计天然就是逐段的。
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
  let consumed = {
    let mut n = 0
    for p in pages {
      n = n + 27 + p.segments.length() + p.payload.length()
    }
    n
  }
  println("文件:   " + path)
  println("格式:   Ogg")
  println("字节数: " + data.length().to_string())
  println("页数:   " + pages.length().to_string())
  println("包数:   " + packets.length().to_string())
  if consumed < data.length() {
    println(
      "注意:   只解析到偏移 " +
      consumed.to_string() +
      "（文件共 " +
      data.length().to_string() +
      " 字节），后面可能还有损坏数据 —— 用 verify 查看跳过区间",
    )
  }
  let chains = @ogg.split_chains(pages)
  println("物理流: " + chains.length().to_string())
  let serials = @ogg.serials_of(pages)
  println("逻辑流: " + serials.length().to_string())
  let mut si = 0
  while si < serials.length() {
    let s = serials[si]
    let mut page_count = 0
    let mut byte_count = 0
    let mut first_granule : Int64 = -1L
    let mut last_granule : Int64 = -1L
    let mut has_granule = false
    for page in pages {
      if page.serial == s {
        page_count = page_count + 1
        byte_count = byte_count + page.payload.length()
        // -1 表示本页没有包结束，不代表时间
        if page.granule_position >= 0L {
          if !has_granule {
            first_granule = page.granule_position
          }
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
    // 音频流：读标识头给出编码、声道、采样率与时长。
    // 不是音频流（Skeleton、视频轨等）就不打这一行。
    match first_packet_of(packets, s) {
      Some(head) =>
        match @codec.parse_audio_header(head) {
          Some(info) => {
            let mut detail = "      " +
              info.codec +
              "  声道=" +
              info.channels.to_string() +
              "  采样率=" +
              info.sample_rate.to_string() +
              " Hz"
            if has_granule {
              // 时长按整数百分之一秒舍入显示，不走浮点打印，
              // 避免把 6 秒显示成 5.9999999
              let secs = @codec.duration_seconds(info, first_granule, last_granule)
              let hundredths = (secs * 100.0 + 0.5).to_int64()
              detail = detail +
                "  时长=" +
                (hundredths / 100L).to_string() +
                "." +
                pad2((hundredths % 100L).to_int()) +
                " 秒"
            }
            println(detail)
          }
          None => ()
        }
      None => ()
    }
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
/// 取一条逻辑流的第一个包（标识头所在）；没有包则 None。
fn first_packet_of(packets : Array[@ogg.Packet], serial : UInt) -> Bytes? {
  for p in packets {
    if p.serial == serial {
      return Some(p.data)
    }
  }
  None
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
/// 每条流原有的流号与逐包粒度写进 `manifest.txt`（重新封装时据此还原，
/// 见 `read_manifest`）。
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
      // 严格解析只到坏点为止：少给了多少要说清楚，不能让人以为拆完了
      let consumed = {
        let mut n = 0
        for p in pages {
          n = n + 27 + p.segments.length() + p.payload.length()
        }
        n
      }
      if consumed < data.length() {
        println(
          "注意: 只解析到偏移 " +
          consumed.to_string() +
          "（文件共 " +
          data.length().to_string() +
          " 字节），后面的数据未能解析，可能被截断或损坏 —— 用 verify 查看",
        )
      }
      // 复用非空目录会静默混入上一次的包：mux 会照单全收，
      // 而清单只覆盖新文件 —— 产物内容错乱、verify 却全绿。
      // 这类错误只能靠入口挡住，容器层看不出来。
      if @fs.path_exists(dir) {
        let existing = @fs.read_dir(dir) catch {
          IOError(_) => []
        }
        if existing.length() > 0 {
          println(
            "错误: 输出目录已存在且非空 —— " +
            dir +
            "\n  请换一个新目录，或先清空它（复用目录会混入上一次的包，且无法自动分辨）",
          )
          return
        }
      }
      if @ogg.split_chains(pages).length() > 1 {
        println(
          "注意: 输入是链接流（" +
          @ogg.split_chains(pages).length().to_string() +
          " 段）。demux 的目录布局不表达链接边界，再 mux 会把多段压成一条物理流；" +
          "要保真请先用 split 拆开。",
        )
      }
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
        // 粒度清单。包文件里没有时间信息，而时间信息正是 Ogg 区别于
        // 「一堆裸包」的地方：不写这份清单，重新封装出来的每一页粒度都是 0，
        // 时长归零、无法 seek、时间戳全错。
        //
        // 每行一个值，顺序与 packet_%06d.bin 一一对应。-1 表示该包在原文件里
        // 不携带粒度（RFC 3533：只有页内最后一个完整结束的包才携带），
        // 它必须与「粒度真的是 0」区分开。
        //
        // 清单头部另记一条 `# serial=` —— 流的原始流号。没有它，往返后的
        // 文件流号会被重新编号成 1，与原文件对不上（拆包工具按 serial 索引时
        // 找不到东西）。放在注释行里是为了双向兼容：旧版读者跳过 # 行，
        // 旧版清单在新版里按「未记录」处理。
        // 用字符串拼接，不用 Buffer::write_utf8 —— 后者把 String 当作
        // UTF-16 码元序列处理，ASCII 会被两两重组（"# m" 变成 "‣潭"），
        // 写出来的清单全是乱码。同一个坑 cli/cli.mbt 已经用注释标记过。
        let manifest_header = "# moonmux manifest v1\n# granulepos\n# serial=" +
          streams[si].serial.to_string() +
          "\n# packets=" +
          group.length().to_string() +
          "\n"
        let mut manifest = manifest_header
        let mut gi = 0
        while gi < group.length() {
          manifest = manifest + group[gi].granule_position.to_string() + "\n"
          gi = gi + 1
        }
        @fs.write_string_to_file(sub + "/manifest.txt", manifest) catch {
          IOError(msg) => {
            println("错误: 无法写入清单 " + sub + "/manifest.txt —— " + msg)
            return
          }
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
    // manifest.txt 描述包，本身不是包。漏掉这一句会让它被当成最后一个包
    // 读进来：封装出的文件多一个包、末页粒度取到清单之外的默认值 0 ——
    // 症状与「粒度根本没修」一模一样，极易误判。
    // 只收自己写出的包文件：目录里的 .DS_Store、Thumbs.db、
    // 手工笔记之类不能被当成包读进容器（读进去就是一个垃圾包）
    if isf && starts_with_str(e, "packet_") && ends_with_str(e, ".bin") {
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
/// 把字符串按换行切成行。
///
/// 用 StringBuilder 而不是 Buffer::write_char —— 后者已标记弃用，
/// 且语义是 UTF-16LE 写字节：现在靠「写与读都是 UTF-16LE」的对称性
/// 恰好不出错，但官方明确说未来的破坏性发布会改成 UTF-8 语义，
/// 到那一天清单会被静默写坏。这份文件里的注释已经因为同一个坑
/// 放弃过 Buffer::write_utf8，不该在切行时再踩一次。
fn split_lines(s : String) -> Array[String] {
  let out : Array[String] = []
  let buf = StringBuilder()
  let mut i = 0
  while i < s.length() {
    match s.get_char(i) {
      Some(ch) =>
        if ch.to_int() == 10 {
          out.push(buf.to_string())
          buf.reset()
        } else {
          buf.write_char(ch)
        }
      None => ()
    }
    i = i + 1
  }
  if !buf.is_empty() {
    out.push(buf.to_string())
  }
  out
}

///|
/// 解析十进制整数，允许一个前导负号。
///
/// 非数字字符一律跳过而不是报错：清单是本工具自己写的，出现杂字符只可能是
/// 被人手工编辑过，此时按「这里没有数字」处理比让整个封装失败更合理。
fn parse_i64(s : String) -> Int64 {
  let mut i = 0
  let mut neg = false
  if s.length() > 0 {
    match s.get_char(0) {
      Some(c) =>
        if c.to_int() == 45 {
          neg = true
          i = 1
        }
      None => ()
    }
  }
  let mut v : Int64 = 0L
  while i < s.length() {
    match s.get_char(i) {
      Some(c) => {
        let d = c.to_int() - 48
        if d >= 0 && d <= 9 {
          v = v * 10L + d.to_int64()
        }
      }
      None => ()
    }
    i = i + 1
  }
  if neg {
    -v
  } else {
    v
  }
}

///|
/// 一份流目录清单的内容：原有流号（若记录）+ 逐包粒度。
struct Manifest {
  serial : UInt?
  packets : Int?
  granules : Array[Int64]
}

///|
/// 字符串是否以给定前缀开头（逐字符比对）。
fn starts_with_str(s : String, prefix : String) -> Bool {
  if s.length() < prefix.length() {
    return false
  }
  let mut i = 0
  let mut same = true
  while i < prefix.length() {
    match (s.get_char(i), prefix.get_char(i)) {
      (Some(a), Some(b)) =>
        if a.to_int() != b.to_int() {
          same = false
        }
      _ => same = false
    }
    i = i + 1
  }
  same
}

///|
/// 字符串是否以给定后缀结尾。
fn ends_with_str(s : String, suffix : String) -> Bool {
  if s.length() < suffix.length() {
    return false
  }
  let offset = s.length() - suffix.length()
  let mut i = 0
  let mut same = true
  while i < suffix.length() {
    match (s.get_char(offset + i), suffix.get_char(i)) {
      (Some(a), Some(b)) =>
        if a.to_int() != b.to_int() {
          same = false
        }
      _ => same = false
    }
    i = i + 1
  }
  same
}

///|
/// 读取某个流目录下的清单，返回原有流号与逐包粒度。
///
/// 没有清单（旧目录、或手工准备的包目录）时返回空记录，调用方据此退回
/// 「流号按 1、2、3 重新编号、粒度全部为 0」的旧行为 —— 这是刻意的向后
/// 兼容：清单是新增的，不能让以前的目录布局失效。
///
/// 清单里 `# serial=` 一行是可选的：老清单没有它，新清单必有。
/// 流号字段是 32 位，读回时按 32 位截断（`to_uint64().to_uint()`），
/// 与页头里的字段宽度一致。
fn read_manifest(sub : String) -> Manifest {
  let path = sub + "/manifest.txt"
  let granules : Array[Int64] = []
  let mut serial : UInt? = None
  let mut packets : Int? = None
  if !@fs.path_exists(path) {
    return { serial, packets, granules }
  }
  let text = @fs.read_file_to_string(path) catch {
    IOError(_) => return { serial, packets, granules }
  }
  for line in split_lines(text) {
    if starts_with_str(line, "# serial=") {
      serial = Some(parse_i64(line[9:].to_owned()).reinterpret_as_uint64().to_uint())
    } else if starts_with_str(line, "# packets=") {
      packets = Some(parse_i64(line[10:].to_owned()).to_int())
    } else if line.length() > 0 {
      match line.get_char(0) {
        Some(c) =>
          if c.to_int() != 35 {
            granules.push(parse_i64(line))
          }
        None => ()
      }
    }
  }
  { serial, packets, granules }
}

///|
/// 取清单中第 `i` 个粒度值。
///
/// 清单缺失、或比包数短时返回 0 —— 与新增清单之前的行为一致，
/// 这样旧目录仍能封装，只是时间信息无从恢复。
fn granule_at(granules : Array[Int64], i : Int) -> Int64 {
  if i < granules.length() {
    granules[i]
  } else {
    0L
  }
}

///|
/// 封装时使用容器层的默认目标页大小（4096，见 `ogg.DEFAULT_PAGE_TARGET`）。
///
///|
/// 按目录布局决定封装方式，产出要写出的页。
///
/// 目录里**有子目录**时，每个子目录是一条逻辑流（按名字典序，
/// 也就是 BOS 页的先后）；**没有子目录**时，整个目录是一条逻辑流。
///
/// 两种布局混在一起时直接报错而不是挑一种：无论选哪一种都会漏掉另一半数据，
/// 而这种遗漏在产出的文件里看不出来 —— 文件照样能解析，只是少了一条流。
///
/// 流号与粒度由清单还原：清单是 `demux` 写出的，记录了原文件的流号与
/// 逐包粒度；没有清单的手工目录退回旧行为（流号按 1、2、3 编号、粒度为 0）。
/// 清单有 serial 时沿用原流号，两条流若因此撞号，`mux_streams` 会如实报错。
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
    let manifest = read_manifest(dir)
    let serial = match manifest.serial {
      Some(s) => s
      None => 1U
    }
    let packets : Array[@ogg.Packet] = []
    let mut gi = 0
    for n in loose {
      let data = @fs.read_file_to_bytes(dir + "/" + n) catch {
        IOError(msg) => return Err("无法读取包文件 " + n + " —— " + msg)
      }
      packets.push({
        data,
        granule_position: granule_at(manifest.granules, gi),
        serial,
      })
      gi = gi + 1
    }
    Ok({
      pages: @ogg.paginate_sized(packets, serial, @ogg.DEFAULT_PAGE_TARGET),
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
      let manifest = read_manifest(sub)
      match manifest.packets {
        Some(n) =>
          if n != names.length() {
            return Err(
              "子目录 " +
              subs[si] +
              " 的清单声明 " +
              n.to_string() +
              " 个包，实际有 " +
              names.length().to_string() +
              " 个 —— 目录可能被改动过或复用了",
            )
          }
        None => ()
      }
      let serial = match manifest.serial {
        Some(s) => s
        None => (si + 1).reinterpret_as_uint()
      }
      let packets : Array[@ogg.Packet] = []
      let mut gi = 0
      for n in names {
        let data = @fs.read_file_to_bytes(sub + "/" + n) catch {
          IOError(msg) => return Err("无法读取包文件 " + n + " —— " + msg)
        }
        packets.push({
          data,
          granule_position: granule_at(manifest.granules, gi),
          serial,
        })
        gi = gi + 1
      }
      total = total + packets.length()
      streams.push({ serial, packets })
      si = si + 1
    }
    // 交织规则（BOS 页置顶、按粒度升序）全在容器层，这里不碰
    match @ogg.mux_streams_sized(streams, @ogg.DEFAULT_PAGE_TARGET) {
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
      // dump 用严格解析（遇到坏页即停）：这里不静默少给，明说到底读了多少
      let consumed = {
        let mut n = 0
        for p in pages {
          n = n + 27 + p.segments.length() + p.payload.length()
        }
        n
      }
      if consumed < data.length() {
        println(
          "注意:   只解析到偏移 " +
          consumed.to_string() +
          "（文件共 " +
          data.length().to_string() +
          " 字节），后面可能还有损坏数据 —— 用 verify 查看跳过区间",
        )
      }
      println(@ogg.page_table_header())
      for line in @ogg.describe_pages(pages) {
        println(line)
      }
    }
  }
}

///|
/// 找出一条音频流的注释包：返回（流号、种类、注释）。
///
/// 判据是「首个包能解析成 OpusHead / Vorbis 识别头」——
/// 多流文件里第一条流未必是音频（Skeleton、视频轨），所以要逐流试。
/// 找不到就如实说清楚，而不是打印一份空注释列表。
fn find_comment(
  pages : Array[@ogg.Page],
) -> Result[(UInt, @codec.CommentKind, @codec.Comment), String] {
  let serials = @ogg.serials_of(pages)
  if serials.length() == 0 {
    return Err("文件里没有任何逻辑流")
  }
  let mut i = 0
  while i < serials.length() {
    let serial = serials[i]
    let packets = @ogg.reassemble(@ogg.stream_pages(pages, serial))
    if packets.length() >= 2 {
      match @codec.parse_audio_header(packets[0].data) {
        Some(_) =>
          match @codec.parse_comment(packets[1].data) {
            Ok(parsed) => return Ok((serial, parsed.0, parsed.1))
            Err(msg) =>
              return Err(
                "第 " +
                (i + 1).to_string() +
                " 条逻辑流的注释包解析失败：" +
                msg,
              )
          }
        None => ()
      }
    }
    i = i + 1
  }
  Err("文件里没有可识别的音频流，或该流没有注释包")
}

///|
/// `tags`：列出注释。
fn run_tags(path : String) -> Unit {
  match read_all(path) {
    None => ()
    Some(data) => {
      let pages = @ogg.parse_pages(data)
      if pages.length() == 0 {
        println("错误: 不是合法的 Ogg 文件 —— " + path)
        return
      }
      match find_comment(pages) {
        Err(msg) => println("错误: " + msg)
        Ok(found) => {
          let (serial, kind, comment) = found
          let codec_name = match kind {
            @codec.CommentKind::Opus => "Opus"
            @codec.CommentKind::Vorbis => "Vorbis"
          }
          println("文件:   " + path)
          println("编码:   " + codec_name)
          println("流号:   " + serial.to_string())
          println("vendor: " + comment.vendor)
          println("注释:   " + comment.tags.length().to_string() + " 条")
          for t in comment.tags {
            println("  " + t.key + "=" + t.value)
          }
        }
      }
    }
  }
}

///|
/// `tag`：改写注释并写入新文件。
///
/// 只替换注释包，音频页原样保留。为了让页布局也尽量不动，
/// 新包会被填充到与旧包等长（填充是尾随零字节，两种编码都允许）——
/// 这样连页序号都不用重编号，产物只有那一页的字节不同。
/// 注释变长时补不下，则重写该包所在的页并给同流后续页重编号。
fn run_tag(src : String, out : String, assignments : Array[String]) -> Unit {
  match read_all(src) {
    None => ()
    Some(data) => {
      let pages = @ogg.parse_pages(data)
      if pages.length() == 0 {
        println("错误: 不是合法的 Ogg 文件 —— " + src)
        return
      }
      let found = match find_comment(pages) {
        Ok(f) => f
        Err(msg) => {
          println("错误: " + msg)
          return
        }
      }
      let serial = found.0
      let kind = found.1
      let mut comment = found.2
      for a in assignments {
        match a.find("=") {
          Some(at) => {
            let key = a[0:at].to_owned()
            let value = a[at + 1:].to_owned()
            if !@codec.valid_key(key) {
              println(
                "错误: 非法的键「" +
                key +
                "」（只能是可打印 ASCII，且不含 '='）",
              )
              return
            }
            if value.length() == 0 {
              comment = @codec.remove_tag(comment, key)
            } else {
              comment = @codec.set_tag(comment, key, value)
            }
          }
          None => ()
        }
      }
      let old_packets = @ogg.reassemble(@ogg.stream_pages(pages, serial))
      let old_len = old_packets[1].data.length()
      let plain = @codec.encode_comment(kind, comment, 0)
      // 填充只在 Vorbis 上做。RFC 7845 §5.2 允许 OpusTags 后跟零填充
      // （首字节最低位为 0 时可当填充丢弃），但本项目转码链路用的
      // moonopus 会把尾随字节判成「trailing bytes after comments」而拒收 ——
      // 于是打上标签的文件反而转不了码。这里选择让自家链路能读回：
      // Opus 不填充、宁可让页序号重编号；Vorbis 的注释在单独一页、
      // moonvorbis 也接受尾随零，填充照用，删键后文件大小可以一个字节不变。
      let pad_ok = match kind {
        @codec.CommentKind::Vorbis => true
        @codec.CommentKind::Opus => false
      }
      let padding = if pad_ok && plain.length() < old_len {
        old_len - plain.length()
      } else {
        0
      }
      let packet = @codec.encode_comment(kind, comment, padding)
      let updated = match @ogg.replace_packet(pages, serial, 1, packet) {
        Ok(p) => p
        Err(msg) => {
          println("错误: " + msg)
          return
        }
      }
      let blob = @ogg.serialize_pages(updated)
      @fs.write_bytes_to_file(out, blob) catch {
        IOError(msg) => {
          println("错误: 无法写入 " + out + " —— " + msg)
          return
        }
      }
      // 回读自检：写出去的东西必须自己还能解析、结构还得自洽
      let written = @ogg.parse_pages(blob)
      let problems = @ogg.structure_problems(written)
      let crc_bad = {
        let mut n = 0
        for p in written {
          if !@ogg.page_crc_ok(p) {
            n = n + 1
          }
        }
        n
      }
      println(
        "已写出 " +
        out +
        "：注释 " +
        comment.tags.length().to_string() +
        " 条，填充 " +
        padding.to_string() +
        " 字节，" +
        pages.length().to_string() +
        " 页 → " +
        written.length().to_string() +
        " 页，CRC 失败 " +
        crc_bad.to_string() +
        "，结构问题 " +
        problems.length().to_string(),
      )
    }
  }
}

///|
/// 找出第一条音频流：返回（流号、头参数、首个真粒度、末个真粒度）。
fn audio_stream_info(
  pages : Array[@ogg.Page],
) -> Result[(UInt, @codec.AudioInfo, Int64, Int64), String] {
  let serials = @ogg.serials_of(pages)
  let mut i = 0
  while i < serials.length() {
    let serial = serials[i]
    let stream = @ogg.stream_pages(pages, serial)
    let packets = @ogg.reassemble(stream)
    if packets.length() > 0 {
      match @codec.parse_audio_header(packets[0].data) {
        Some(info) => {
          let mut first : Int64 = 0L
          let mut last : Int64 = 0L
          let mut seen = false
          for p in stream {
            if p.granule_position >= 0L {
              if !seen {
                first = p.granule_position
                seen = true
              }
              last = p.granule_position
            }
          }
          return Ok((serial, info, first, last))
        }
        None => ()
      }
    }
    i = i + 1
  }
  Err("文件里没有可识别的音频流")
}

///|
/// `seek`：按时间（毫秒）定位到页。
///
/// 容器层返回「不晚于目标时间的最后一个页」，这里负责把毫秒换算成 granule
/// （需要采样率与 pre-skip）。我们不解码，所以不做 pre-roll，
/// 只把落点与「解码时要提前多少」一起打出来 —— 那是调用方的事。
fn run_seek(path : String, ms : Int) -> Unit {
  match read_all(path) {
    None => ()
    Some(data) => {
      let pages = @ogg.parse_pages(data)
      if pages.length() == 0 {
        println("错误: 不是合法的 Ogg 文件 —— " + path)
        return
      }
      let found = match audio_stream_info(pages) {
        Ok(f) => f
        Err(msg) => {
          println("错误: " + msg)
          return
        }
      }
      let serial = found.0
      let head = found.1
      let first = found.2
      let target = first +
        head.pre_skip.to_int64() +
        (ms.to_int64() * head.sample_rate.to_int64()) / 1000L
      match @ogg.seek_granule(pages, serial, target) {
        None => println("错误: 该流没有可用的粒度路标（所有页的 granule 都是 -1）")
        Some(p) => {
          let rel = p.granule - first - head.pre_skip.to_int64()
          let landed = if rel > 0L {
            rel.to_double() / head.sample_rate.to_double()
          } else {
            0.0
          }
          let hundredths = (landed * 100.0 + 0.5).to_int64()
          println("文件:     " + path)
          println("目标:     " + ms.to_string() + " ms")
          println("流号:     " + serial.to_string())
          println("页下标:   " + p.page_index.to_string())
          println("字节偏移: " + p.byte_offset.to_string())
          println("页序号:   " + p.sequence.to_string())
          println("granule:  " + p.granule.to_string())
          println(
            "落点时间: " +
            (hundredths / 100L).to_string() +
            "." +
            pad2((hundredths % 100L).to_int()) +
            " 秒",
          )
          if head.codec == "Opus" {
            println("提示:     解码需从该页再提前 80 ms 开始并丢弃输出（RFC 7845 §4.6 pre-roll）")
          }
        }
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
      // 容错解析：坏页跳过并记录下来，而不是撞到第一个坏点就停 ——
      // verify 的价值在于说清「坏在哪、坏掉多少、后面还剩多少」。
      let (pages, gaps) = @ogg.parse_pages_lenient(data)
      if pages.length() == 0 {
        println("错误: 不是合法的 Ogg 文件 —— " + path)
        // 输入根本读不出页也是失败：CI 不能把它当成「通过」
        @sys.exit(1)
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
      // 无法同步的区间是硬错误：那一段数据连页边界都没有
      let findings : Array[@ogg.Finding] = []
      for gap in gaps {
        findings.push({
          severity: @ogg.Severity::Error,
          message: "偏移 " +
            gap.offset.to_string() +
            " 处跳过 " +
            gap.bytes.to_string() +
            " 字节（无法同步到有效页：坏页、插入的垃圾或被截断）",
        })
      }
      // CRC 失败同样是 error：字节坏了，不是「可疑形态」
      for page in pages {
        if !@ogg.page_crc_ok(page) {
          findings.push({
            severity: @ogg.Severity::Error,
            message: "serial=" +
              page.serial.to_string() +
              " sequence=" +
              page.sequence.to_string() +
              " CRC 校验失败（页内容已损坏）",
          })
        }
      }
      for f in @ogg.structure_findings(pages) {
        findings.push(f)
      }
      let mut errors = 0
      let mut warnings = 0
      for f in findings {
        match f.severity {
          @ogg.Severity::Error => errors = errors + 1
          @ogg.Severity::Warning => warnings = warnings + 1
          @ogg.Severity::Info => ()
        }
      }
      println("文件:     " + path)
      println("字节数:   " + data.length().to_string())
      println("页数:     " + pages.length().to_string())
      println("物理流:   " + @ogg.split_chains(pages).length().to_string())
      println("逻辑流:   " + @ogg.serials_of(pages).length().to_string())
      println("CRC 通过: " + ok.to_string() + "  失败: " + bad.to_string())
      println(
        "结构问题: " +
        findings.length().to_string() +
        "（error " +
        errors.to_string() +
        " / warn " +
        warnings.to_string() +
        "）",
      )
      // 只铺前 10 条：坏了大半的文件逐条打出来只会淹没结论，
      // 但省略要明说 —— 闷声少报等于把问题藏起来
      let mut shown = 0
      for f in findings {
        if shown < 10 {
          println("  [" + @ogg.severity_label(f.severity) + "] " + f.message)
          shown = shown + 1
        }
      }
      if findings.length() > 10 {
        println(
          "  ……另有 " +
          (findings.length() - 10).to_string() +
          " 处（以上为前 10 处）",
        )
      }
      if bad == 0 && findings.length() == 0 {
        println("结论:     结构完好（CRC、页序号、BOS·EOS、粒度全部自洽）")
      } else {
        println(
          "结论:     " +
          errors.to_string() +
          " 个 error / " +
          warnings.to_string() +
          " 个 warn / " +
          bad.to_string() +
          " 页 CRC 失败",
        )
      }
      // 退出码只反映 error：CI 不该因为「末页缺 EOS」这种可疑形态红掉，
      // 但缺 BOS、页序号断裂这类直接不可解码的问题必须让流水线失败。
      if errors > 0 || bad > 0 {
        @sys.exit(1)
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
    @cli.Command::Tags(path) => run_tags(path)
    @cli.Command::TagWrite(src, out, assigns) => run_tag(src, out, assigns)
    @cli.Command::Seek(path, ms) => run_seek(path, ms)
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
