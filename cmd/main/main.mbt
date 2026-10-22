// main.mbt —— 命令行入口
//
// 这一层只做 I/O 与排版。所有参数解释在 cli/，所有容器逻辑在 ogg/ 与 wav/。
// 这里出现任何「判断」都是不该有的 —— 判断应该已经被下层测过了。
//
// IOError 没有实现 Show，因此错误消息统一用模式匹配取出其中的字符串，
// 而不是直接插值。

///|
/// 删除一个由我们刚创建的目录及其中的文件（写盘失败时清理半成品）。
fn remove_dir_tree(dir : String) -> Unit {
  if !@fs.path_exists(dir) {
    return
  }
  let entries = @fs.read_dir(dir) catch { IOError(_) => return }
  for e in entries {
    let p = dir + "/" + e
    let nested = @fs.is_dir(p) catch { _ => false }
    if nested {
      // demux 的输出是「目录 + 平铺文件」，但回滚也可能遇到更深一层；
      // 不递归的话 remove_file 对子目录必然失败，整个回滚等于空操作。
      remove_dir_tree(p)
    } else {
      @fs.remove_file(p) catch {
        _ => ()
      }
    }
  }
  @fs.remove_dir(dir) catch {
    _ => ()
  }
}

///|
/// 统一的失败出口：打印一行错误，并以 **2** 退出。
///
/// 退出码约定：`0` 成功、`1` 校验未通过（verify 的 error / CRC 失败）、
/// `2` 用法或 I/O 错误。脚本据此就能区分「文件坏了」与「命令用错了」，
/// 不必去 grep 中文输出。
fn fail(msg : String) -> Unit {
  println(msg)
  @sys.exit(2)
}

///|
/// 数据错误（输入不是合法 Ogg、被截断、清单对不上…）：打印并以 **1** 退出。
///
/// 与 `fail`（用法 / I/O，退出 2）分开，脚本才能区分
/// 「文件坏了」和「命令用错了」。
fn fail_data(msg : String) -> Unit {
  println(msg)
  @sys.exit(1)
}

///|
/// 严格解析后若还有未消费的字节，说明文件被截断或中间有垃圾。
///
/// 对**会写产物**的命令这必须拒绝：产出的会是半截文件，而退出码和
/// 正常情况一样是 0 —— 用户以为拆完了，实际只拿到前一段。
fn require_fully_parsed(
  path : String,
  pages : Array[@ogg.Page],
  data : Bytes,
) -> Unit {
  let mut consumed = 0
  for p in pages {
    consumed = consumed + 27 + p.segments.length() + p.payload.length()
  }
  if consumed < data.length() {
    let extra = data.length() - consumed
    // 所有流都以 EOS 收尾时，尾部多出来的字节是填充/垃圾，不影响已解析内容；
    // 没有 EOS 才说明是截断 —— 那才是"半截产物"。
    let mut all_closed = true
    for s in @ogg.serials_of(pages) {
      let sp = @ogg.stream_pages(pages, s)
      let last = sp[sp.length() - 1]
      if (last.header_type.to_int() & @ogg.flag_eos().to_int()) == 0 {
        all_closed = false
      }
    }
    if all_closed {
      println(
        "注意: 文件末尾有 " +
        extra.to_string() +
        " 字节无法解析（所有流都已 EOS，按尾部填充忽略）",
      )
    } else {
      fail_data(
        "错误: " +
        path +
        " 在偏移 " +
        consumed.to_string() +
        " 之后还有 " +
        extra.to_string() +
        " 字节无法解析（文件可能被截断或中间损坏）——\n" +
        "  拒绝写出半截产物；请先用 verify 查看损坏位置",
      )
    }
  }
}

///|
/// 读取整个文件；失败时打印原因并返回 None。
fn read_all(path : String) -> Bytes? {
  let data = @fs.read_file_to_bytes(path) catch {
    IOError(msg) => {
      fail("错误: 无法读取 " + path + " —— " + msg)
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
fn run_info(path : String, json : Bool) -> Unit {
  match read_all(path) {
    None => ()
    Some(data) =>
      if @ogg.is_page_start(data, 0) {
        show_ogg_info(path, data, json)
      } else {
        match @wav.WavFile::parse(data) {
          Some(f) => show_wav_info(path, data, f, json)
          None =>
            fail_data("错误: 既不是 Ogg 也不是 WAV —— " + path)
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
fn show_ogg_info(path : String, data : Bytes, json : Bool) -> Unit {
  let pages = @ogg.parse_pages(data)
  if pages.length() == 0 {
    fail_data("错误: 不是合法的 Ogg 文件 —— " + path)
    return
  }
  if json {
    print_ogg_json(path, data, pages)
    return
  }
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
  println("包数:   " + @ogg.count_packets(pages).to_string())
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
  // 一趟扫描统计每条流：原来对每条流都遍历全部页与全部包，
  // 是 O(流数 × 页数)。1–2 条流无所谓，300 段文件会放大成几十万次比较。
  let index_of : Map[UInt32, Int32] = Map([])
  let mut k = 0
  while k < serials.length() {
    index_of.set(serials[k], k)
    k = k + 1
  }
  let page_counts = Array::make(serials.length(), 0)
  let byte_counts = Array::make(serials.length(), 0)
  let first_granules = Array::make(serials.length(), -1L)
  let last_granules = Array::make(serials.length(), -1L)
  let has_granules = Array::make(serials.length(), false)
  for page in pages {
    match index_of.get(page.serial) {
      Some(idx) => {
        page_counts[idx] = page_counts[idx] + 1
        byte_counts[idx] = byte_counts[idx] + page.payload.length()
        // -1 表示本页没有包结束，不代表时间
        if page.granule_position >= 0L {
          if !has_granules[idx] {
            first_granules[idx] = page.granule_position
          }
          last_granules[idx] = page.granule_position
          has_granules[idx] = true
        }
      }
      None => ()
    }
  }
  // 每条流的首个包（标识头）：同样一趟扫描，取首次出现
  // 每条流只取首个包（标识头），不重组整条流
  let heads : Array[Bytes?] = Array::make(serials.length(), None)
  let mut hi = 0
  while hi < serials.length() {
    heads[hi] = @ogg.first_packet(pages, serials[hi])
    hi = hi + 1
  }
  let mut si = 0
  while si < serials.length() {
    let s = serials[si]
    let page_count = page_counts[si]
    let byte_count = byte_counts[si]
    let first_granule = first_granules[si]
    let last_granule = last_granules[si]
    let has_granule = has_granules[si]
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
    match heads[si] {
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
              let secs = @codec.duration_seconds(
                info, first_granule, last_granule,
              )
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
    println(
      "  （链接流：以上各段首尾相接，段间流号互不复用）",
    )
  }
}

///|
/// 打印 WAV 的容器信息。
///
/// 时长按帧数换算：帧数 = PCM 字节数 ÷（声道 × 位深/8），
/// 秒 = 帧数 ÷ 采样率。全部用整数算，避免浮点把「6 秒」显示成 5.999。
fn show_wav_info(
  path : String,
  data : Bytes,
  f : @wav.WavFile,
  json : Bool,
) -> Unit {
  if json {
    print_wav_json(path, data, f)
    return
  }
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
    let frac = frames % f.format.sample_rate * 100 / f.format.sample_rate
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
        fail_data("错误: 不是合法的 Ogg 文件 —— " + src)
        return
      }
      let packets = @ogg.reassemble(pages)
      // 包文件名是 packet_%06d.bin，超过 6 位后字典序会乱，mux 读回的顺序就错了。
      if packets.length() > 999999 {
        fail_data(
          "错误: 该文件有 " +
          packets.length().to_string() +
          " 个包，超过当前命名方案的上限 999999",
        )
      }
      let streams = @ogg.group_by_stream(packets)
      let chains = @ogg.split_chains(pages)
      // 输入必须整份解析成功，否则写出的是半截包集
      require_fully_parsed(src, pages, data)
      // 有 error 级结构问题的输入不拆：拆出来的包目录会把损坏"洗白"，
      // 再 mux 回去结构合法、内容却不对（例如跨段复用 serial 被粘成一条流）。
      let mut input_errors = 0
      for f in @ogg.structure_findings(pages) {
        match f.severity {
          @ogg.Severity::Error => input_errors = input_errors + 1
          _ => ()
        }
      }
      if input_errors > 0 {
        fail_data(
          "错误: 输入有 " +
          input_errors.to_string() +
          " 处结构错误，拒绝拆分 —— 先用 verify 查看",
        )
      }
      // 复用非空目录会静默混入上一次的包：mux 会照单全收，
      // 而清单只覆盖新文件 —— 产物内容错乱、verify 却全绿。
      // 这类错误只能靠入口挡住，容器层看不出来。
      if @fs.path_exists(dir) {
        let existing = @fs.read_dir(dir) catch {
          IOError(msg) =>
            return fail(
              "错误: 无法读取输出目录 " + dir + " —— " + msg,
            )
        }
        if existing.length() > 0 {
          fail(
            "错误: 输出目录已存在且非空 —— " +
            dir +
            "\n  请换一个新目录，或先清空它（复用目录会混入上一次的包，且无法自动分辨）",
          )
          return
        }
      }
      // 目录是本轮创建的：中途失败就把整个目录回滚，不留半套 sN。
      // （复用已存在目录的情况在入口已被拒绝，所以这里的目录只可能是我们的。）
      let created_dir = !@fs.path_exists(dir)
      if created_dir {
        @fs.create_dir(dir) catch {
          IOError(msg) => {
            fail("错误: 无法创建目录 " + dir + " —— " + msg)
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
              if created_dir {
                remove_dir_tree(dir)
              }
              fail("错误: 无法创建目录 " + sub + " —— " + msg)
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
              // 已经写出的前 i 个文件不能留在磁盘上，否则是一个
              // 「看起来成功、实际缺包」的包目录；若整个目录是本轮建的，
              // 连父目录一起删，避免后续 mux 把残留的 sN 当完整输入。
              if created_dir {
                remove_dir_tree(dir)
              } else {
                remove_dir_tree(sub)
              }
              fail("错误: 无法写入 " + name + " —— " + msg)
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
        // 清单头部记 `# serial=`（原流号）、`# packets=`（包数，防止目录
        // 被复用或改动）与 `# chain=`（属于第几段物理流）。没有链序号，
        // chained 文件重封装时多段会被压成一条交织流：结构仍合法，
        // 但播放语义从「顺序播」变成「同时播」。
        // 文本的生成与解析都在 `manifest/` 包里（纯函数、有单元测试）。
        let granule_list : Array[Int64] = []
        let mut gi = 0
        while gi < group.length() {
          granule_list.push(group[gi].granule_position)
          gi = gi + 1
        }
        let manifest = @manifest.render(
          streams[si].serial,
          chain_index_of(chains, streams[si].serial),
          granule_list,
        )
        @fs.write_string_to_file(sub + "/manifest.txt", manifest) catch {
          IOError(msg) => {
            if created_dir {
              remove_dir_tree(dir)
            } else {
              remove_dir_tree(sub)
            }
            fail(
              "错误: 无法写入清单 " +
              sub +
              "/manifest.txt —— " +
              msg,
            )
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
  packets : Int32
  streams : Int32
}

///|
/// 列出目录下的普通文件名，按名字典序。
fn files_in(dir : String) -> Result[Array[String], String] {
  let entries = @fs.read_dir(dir) catch {
    IOError(msg) => return Err("无法读取目录 " + dir + " —— " + msg)
  }
  let names : Array[String] = []
  for e in entries {
    let isf = @fs.is_file(dir + "/" + e) catch { _ => false }
    // manifest.txt 描述包，本身不是包。漏掉这一句会让它被当成最后一个包
    // 读进来：封装出的文件多一个包、末页粒度取到清单之外的默认值 0 ——
    // 症状与「粒度根本没修」一模一样，极易误判。
    // 只收自己写出的包文件：目录里的 .DS_Store、Thumbs.db、
    // 手工笔记之类不能被当成包读进容器（读进去就是一个垃圾包）
    if isf &&
      @manifest.starts_with(e, "packet_") &&
      @manifest.ends_with(e, ".bin") {
      names.push(e)
    }
  }
  names.sort()
  Ok(names)
}

///|
/// 列出目录下的子目录名，按 s<N> 的数字序（s2 在 s10 之前）。
fn subdirs_in(dir : String) -> Result[Array[String], String] {
  let entries = @fs.read_dir(dir) catch {
    IOError(msg) => return Err("无法读取目录 " + dir + " —— " + msg)
  }
  let names : Array[String] = []
  for e in entries {
    let isf = @fs.is_file(dir + "/" + e) catch { _ => false }
    if !isf {
      names.push(e)
    }
  }
  // 按 s<N> 的数字排序。字典序会把 s10 排在 s2 前面，
  // 超过 9 条逻辑流时 BOS 顺序与 demux 时不一致，往返就对不上了。
  let mut i = 1
  while i < names.length() {
    let mut j = i
    while j > 0 {
      let a = dir_number(names[j - 1])
      let b = dir_number(names[j])
      let swap = match (a, b) {
        (Some(x), Some(y)) => y < x
        (Some(_), None) => false
        (None, Some(_)) => true
        (None, None) => names[j] < names[j - 1]
      }
      if swap {
        let tmp = names[j - 1]
        names[j - 1] = names[j]
        names[j] = tmp
        j = j - 1
      } else {
        break
      }
    }
    i = i + 1
  }
  Ok(names)
}

///|
/// 解析 `s<N>` 形式的目录序号；不是这种形式时返回 None。
fn dir_number(name : String) -> Int32? {
  if name.length() < 2 {
    return None
  }
  match name.get_char(0) {
    Some(c) => if c.to_int() != 115 { return None }
    None => return None
  }
  let mut n = 0
  let mut i = 1
  while i < name.length() {
    match name.get_char(i) {
      Some(c) => {
        let d = c.to_int() - 48
        if d < 0 || d > 9 {
          return None
        }
        if n > (2147483647 - d) / 10 {
          return None
        }
        n = n * 10 + d
      }
      None => return None
    }
    i = i + 1
  }
  Some(n)
}

///|
/// 流号属于第几段物理流（1 起算）；找不到时按第 1 段处理。
fn chain_index_of(chains : Array[Array[@ogg.Page]], serial : UInt32) -> Int32 {
  let mut i = 0
  while i < chains.length() {
    if @ogg.has_stream(chains[i], serial) {
      return i + 1
    }
    i = i + 1
  }
  1
}

///|
/// 读取某个流目录下的清单。
///
/// I/O 在这一层，解析与校验在 `manifest/` 包里 —— 那边是纯函数，有单元测试。
/// 清单缺失时返回三个 None 加空粒度表，调用方据此退回旧行为
/// （流号按 1、2、3 编号、粒度全 0、单链）。
fn read_manifest(sub : String) -> Result[@manifest.Manifest, String] {
  let empty : @manifest.Manifest = {
    serial: None,
    packets: None,
    chain: None,
    granules: [],
  }
  let path = sub + "/manifest.txt"
  if !@fs.path_exists(path) {
    // 没有清单是合法的（手工准备的包目录），退回旧行为
    return Ok(empty)
  }
  // 文件存在却读不出来是 I/O 错误：不能假装「没有清单」继续封装，
  // 否则 serial 与粒度会静默退化成 1 和 0。
  let text = @fs.read_file_to_string(path) catch {
    IOError(msg) => return Err("无法读取清单 " + path + " —— " + msg)
  }
  @manifest.parse(text)
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
    let manifest = match read_manifest(dir) {
      Ok(m) => m
      Err(msg) => return Err(msg)
    }
    match @manifest.check_count(manifest, loose.length(), dir) {
      Err(msg) => return Err(msg)
      Ok(_) => ()
    }
    let serial = match manifest.serial {
      Some(s) => s
      None => 1U
    }
    let packets : Array[@ogg.Packet] = []
    let mut gi = 0
    for n in loose {
      let data = @fs.read_file_to_bytes(dir + "/" + n) catch {
        IOError(msg) =>
          return Err("无法读取包文件 " + n + " —— " + msg)
      }
      packets.push({
        data,
        granule_position: @manifest.granule_at(manifest.granules, gi),
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
    // 多条逻辑流：按清单里的 `# chain=` 分组，段内交织、段间首尾相接
    let chain_ids : Array[Int32] = []
    let groups : Array[Array[@ogg.LogicalStream]] = []
    let mut total = 0
    let mut saw_chain = false
    let mut si = 0
    while si < subs.length() {
      let sub = dir + "/" + subs[si]
      let names = match files_in(sub) {
        Ok(v) => v
        Err(m) => return Err(m)
      }
      if names.length() == 0 {
        return Err(
          "子目录 " +
          subs[si] +
          " 中没有包文件 —— 空逻辑流无法封装",
        )
      }
      let manifest = match read_manifest(sub) {
        Ok(m) => m
        Err(msg) => return Err(msg)
      }
      match
        @manifest.check_count(manifest, names.length(), "子目录 " + subs[si]) {
        Err(msg) => return Err(msg)
        Ok(_) => ()
      }
      let serial = match manifest.serial {
        Some(s) => s
        None => (si + 1).reinterpret_as_uint()
      }
      let packets : Array[@ogg.Packet] = []
      let mut gi = 0
      for n in names {
        let data = @fs.read_file_to_bytes(sub + "/" + n) catch {
          IOError(msg) =>
            return Err("无法读取包文件 " + n + " —— " + msg)
        }
        packets.push({
          data,
          granule_position: @manifest.granule_at(manifest.granules, gi),
          serial,
        })
        gi = gi + 1
      }
      total = total + packets.length()
      if manifest.chain is Some(_) {
        saw_chain = true
      }
      let chain_no = match manifest.chain {
        Some(c) => if c < 1 { 1 } else { c }
        None => 1
      }
      let mut slot = -1
      let mut j = 0
      while j < chain_ids.length() {
        if chain_ids[j] == chain_no {
          slot = j
        }
        j = j + 1
      }
      if slot < 0 {
        chain_ids.push(chain_no)
        groups.push([{ serial, packets, }])
      } else {
        groups[slot].push({ serial, packets, })
      }
      si = si + 1
    }
    // 链号升序，避免目录顺序与链顺序不一致时把段顺序写反
    let mut a = 0
    while a < chain_ids.length() {
      let mut b = a + 1
      while b < chain_ids.length() {
        if chain_ids[b] < chain_ids[a] {
          let tmp = chain_ids[a]
          chain_ids[a] = chain_ids[b]
          chain_ids[b] = tmp
          let g = groups[a]
          groups[a] = groups[b]
          groups[b] = g
        }
        b = b + 1
      }
      a = a + 1
    }
    let stream_count = {
      let mut n = 0
      for g in groups {
        n = n + g.length()
      }
      n
    }
    if !saw_chain && subs.length() > 1 {
      // 多个流目录却没有任何链序号：可能是老清单（会丢链接边界），
      // 也可能本来就是一段里的多条流。后者正常，所以只提示不报错。
      println(
        "注意: 清单里没有 # chain= 记录，按单段物理流封装；" +
        "若原文件是链接流，段边界会丢失（重新 demux 可补上链序号）",
      )
    }
    // 交织规则（BOS 页置顶、按粒度升序）全在容器层，这里不碰
    match @ogg.mux_chains_sized(groups, @ogg.DEFAULT_PAGE_TARGET) {
      Err(m) => Err(m)
      Ok(pages) => Ok({ pages, packets: total, streams: stream_count, })
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
    Err(msg) =>
      // plan_mux 的失败分两类：读不到目录/清单/包文件是 I/O（2），
      // 布局与清单不符是数据（1）。按消息前缀区分，避免把 I/O 也报成数据错误。
      if msg.contains("无法读取") || msg.contains("无法打开") {
        fail("错误: " + msg)
      } else {
        fail_data("错误: " + msg)
      }
    Ok(plan) => {
      @fs.write_bytes_to_file(out, @ogg.serialize_pages(plan.pages)) catch {
        IOError(msg) => {
          fail("错误: 无法写入 " + out + " —— " + msg)
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
          fail_data("错误: 不是合法的 Ogg 文件 —— " + inputs[i])
          ok = false
        } else {
          require_fully_parsed(inputs[i], pages, data)
          match @ogg.chain(acc, pages) {
            Err(msg) => {
              fail_data("错误: 链接失败 —— " + msg)
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
        fail("错误: 无法写入 " + out + " —— " + msg)
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
        fail_data("错误: 不是合法的 Ogg 文件 —— " + src)
        return
      }
      require_fully_parsed(src, pages, data)
      let parts = @ogg.split_chains(pages)
      // 与 demux 一致：复用非空目录会留下上一次的 partN.ogg，
      // 用户可能把它当成这次拆分的产物。
      if @fs.path_exists(dir) {
        let existing = @fs.read_dir(dir) catch {
          IOError(msg) =>
            return fail(
              "错误: 无法读取输出目录 " + dir + " —— " + msg,
            )
        }
        if existing.length() > 0 {
          fail(
            "错误: 输出目录已存在且非空 —— " +
            dir +
            "\n  请换一个新目录，或先清空它（残留的 partN.ogg 会被误认为本次产物）",
          )
        }
      }
      // 目录是本轮创建的：中途失败就把整个目录回滚，不留半套 sN。
      // （复用已存在目录的情况在入口已被拒绝，所以这里的目录只可能是我们的。）
      let created_dir = !@fs.path_exists(dir)
      if created_dir {
        @fs.create_dir(dir) catch {
          IOError(msg) => {
            fail("错误: 无法创建目录 " + dir + " —— " + msg)
            return
          }
        }
      }
      let mut i = 0
      let mut ok = true
      let written : Array[String] = []
      while ok && i < parts.length() {
        let name = dir + "/part" + (i + 1).to_string() + ".ogg"
        @fs.write_bytes_to_file(name, @ogg.serialize_pages(parts[i])) catch {
          IOError(msg) => {
            // 删掉本次已写出的 part 与**正在写的那一个**（可能已被创建/截断），
            // 避免留下「缺了几段」的拆分结果
            for p in written {
              @fs.remove_file(p) catch {
                _ => ()
              }
            }
            @fs.remove_file(name) catch {
              _ => ()
            }
            fail("错误: 无法写入 " + name + " —— " + msg)
            ok = false
          }
        }
        if ok {
          written.push(name)
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
            "该文件不是链接流，已原样写出到 " +
            dir +
            "/part1.ogg",
          )
        } else {
          println(
            "已拆出 " +
            parts.length().to_string() +
            " 条物理流到 " +
            dir,
          )
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
fn run_extract(src : String, index : Int32, out : String) -> Unit {
  match read_all(src) {
    None => ()
    Some(data) => {
      let pages = @ogg.parse_pages(data)
      if pages.length() == 0 {
        fail_data("错误: 不是合法的 Ogg 文件 —— " + src)
        return
      }
      require_fully_parsed(src, pages, data)
      let mut input_errors = 0
      for f in @ogg.structure_findings(pages) {
        match f.severity {
          @ogg.Severity::Error => input_errors = input_errors + 1
          _ => ()
        }
      }
      if input_errors > 0 {
        fail_data(
          "错误: 输入有 " +
          input_errors.to_string() +
          " 处结构错误，拒绝抽流 —— 先用 verify 查看",
        )
      }
      let serial = match @ogg.serial_at(pages, index) {
        Ok(s) => s
        Err(msg) => {
          fail("错误: " + msg)
          return
        }
      }
      let stream = @ogg.stream_pages(pages, serial)
      @fs.write_bytes_to_file(out, @ogg.serialize_pages(stream)) catch {
        IOError(msg) => {
          fail("错误: 无法写入 " + out + " —— " + msg)
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
fn run_dump(path : String, hex : Bool) -> Unit {
  match read_all(path) {
    None => ()
    Some(data) => {
      let pages = @ogg.parse_pages(data)
      if pages.length() == 0 {
        fail_data("错误: 不是合法的 Ogg 文件 —— " + path)
        return
      }
      if hex {
        // 纯十六进制、不带任何前缀：`dump --hex | xxd -r` 可直接还原
        @ogg.for_each_hex_line(data, fn(line) { println(line) })
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
      // 边生成边打印：百万页的文件不会先攒一个百万字符串的数组
      @ogg.for_each_page_line(pages, fn(line) { println(line) })
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
) -> Result[(UInt32, @codec.CommentKind, @codec.Comment), String] {
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
        fail_data("错误: 不是合法的 Ogg 文件 —— " + path)
        return
      }
      match find_comment(pages) {
        Err(msg) =>
          // plan_mux 的失败分两类：读不到目录/清单/包文件是 I/O（2），
          // 布局与清单不符是数据（1）。按消息前缀区分，避免把 I/O 也报成数据错误。
          if msg.contains("无法读取") || msg.contains("无法打开") {
            fail("错误: " + msg)
          } else {
            fail_data("错误: " + msg)
          }
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
        fail_data("错误: 不是合法的 Ogg 文件 —— " + src)
        return
      }
      require_fully_parsed(src, pages, data)
      let found = match find_comment(pages) {
        Ok(f) => f
        Err(msg) => {
          fail_data("错误: " + msg)
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
              fail(
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
          fail_data("错误: " + msg)
          return
        }
      }
      let blob = @ogg.serialize_pages(updated)
      @fs.write_bytes_to_file(out, blob) catch {
        IOError(msg) => {
          fail("错误: 无法写入 " + out + " —— " + msg)
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
      let mut written_errors = 0
      for f in @ogg.structure_findings(written) {
        match f.severity {
          @ogg.Severity::Error => written_errors = written_errors + 1
          _ => ()
        }
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
      // 自己写出的文件自己都通不过校验，必须让退出码体现出来
      if written_errors > 0 || crc_bad > 0 {
        // 先写盘后自检：失败时不能把坏文件留在原地
        @fs.remove_file(out) catch {
          _ => ()
        }
        fail_data(
          "错误: 写出的文件未通过自检，已删除 —— " + out,
        )
      }
    }
  }
}

///|
/// 找出第一条音频流：返回（流号、头参数、首个真粒度、末个真粒度）。
fn audio_stream_info(
  pages : Array[@ogg.Page],
) -> Result[(UInt32, @codec.AudioInfo, Int64, Int64), String] {
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
/// 容器层返回「不晚于目标时间的最后一个页」；这里负责三件事：
/// 把毫秒换算成 granule（需要采样率与 pre-skip）、按链序号选段
/// （chained 各段时间轴独立，不能混算）、把落点夹到首个音频页之后。
///
/// 我们不解码，所以不做 pre-roll，只把落点与「解码时要提前多少」一起打出来。
fn run_seek(path : String, ms : Int32, chain_no : Int32) -> Unit {
  match read_all(path) {
    None => ()
    Some(data) => {
      let pages = @ogg.parse_pages(data)
      if pages.length() == 0 {
        fail_data("错误: 不是合法的 Ogg 文件 —— " + path)
        return
      }
      let chains = @ogg.split_chains(pages)
      if chain_no < 1 || chain_no > chains.length() {
        fail(
          "错误: 链序号 " +
          chain_no.to_string() +
          " 超出范围（本文件有 " +
          chains.length().to_string() +
          " 段物理流）",
        )
        return
      }
      let chain = chains[chain_no - 1]
      // 该段在整份页序列里的起点（用于把局部下标/偏移换算成全局）
      let mut chain_start = 0
      let mut ci = 0
      while ci < chain_no - 1 {
        chain_start = chain_start + chains[ci].length()
        ci = ci + 1
      }
      // 该段的第一条音频流
      let found = match audio_stream_info(chain) {
        Ok(f) => f
        Err(msg) => {
          fail_data("错误: 第 " + chain_no.to_string() + " 段：" + msg)
          return
        }
      }
      let serial = found.0
      let head = found.1
      let first = found.2
      let target = first +
        head.pre_skip.to_int64() +
        ms.to_int64() * head.sample_rate.to_int64() / 1000L
      let landing = match @ogg.seek_granule(chain, serial, target) {
        None => {
          fail_data(
            "错误: 该流没有可用的粒度路标（所有页的 granule 都是 -1）",
          )
          return
        }
        Some(p) => p
      }
      // 夹到首个音频页：`seek 0` 不该停在头部页上
      let header_packets = if head.codec == "Opus" { 2 } else { 3 }
      let audio_page = match
        @ogg.first_audio_page(chain, serial, header_packets) {
        Some(p) => p
        None => landing.page_index
      }
      let local_index = if landing.page_index < audio_page {
        audio_page
      } else {
        landing.page_index
      }
      let global_index = chain_start + local_index
      let offsets = @ogg.page_offsets(pages)
      let page = pages[global_index]
      // 落点时间取这一页的**起始**（上一个带粒度页的 granule）：
      // 页头的 granule 是「本页最后一个包结束时的累计样本数」，也就是页的结束时间。
      // 对调用方更有意义的是「从这一页开始解码，音频从几秒开始」。
      let mut start_granule = first
      let mut k = local_index
      while k > 0 {
        k = k - 1
        let prev = chain[k]
        if prev.serial == serial && prev.granule_position >= 0L {
          start_granule = prev.granule_position
          break
        }
      }
      let rel = start_granule - first - head.pre_skip.to_int64()
      let landed = if rel > 0L {
        rel.to_double() / head.sample_rate.to_double()
      } else {
        0.0
      }
      let hundredths = (landed * 100.0 + 0.5).to_int64()
      println("文件:     " + path)
      println("目标:     " + ms.to_string() + " ms")
      println(
        "物理流:   第 " +
        chain_no.to_string() +
        " / " +
        chains.length().to_string() +
        " 段",
      )
      println("流号:     " + serial.to_string())
      println("页下标:   " + global_index.to_string())
      println("字节偏移: " + offsets[global_index].to_string())
      println("页序号:   " + page.sequence.to_string())
      println("granule:  " + page.granule_position.to_string())
      println(
        "起始时间: " +
        (hundredths / 100L).to_string() +
        "." +
        pad2((hundredths % 100L).to_int()) +
        " 秒",
      )
      if head.codec == "Opus" {
        println(
          "提示:     解码需从该页再提前 80 ms 开始并丢弃输出（RFC 7845 §4.6 pre-roll）",
        )
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
fn run_verify(path : String, json : Bool) -> Unit {
  match read_all(path) {
    None => ()
    Some(data) => {
      // 容错解析：坏页跳过并记录下来，而不是撞到第一个坏点就停 ——
      // verify 的价值在于说清「坏在哪、坏掉多少、后面还剩多少」。
      let (pages, gaps) = @ogg.parse_pages_lenient(data)
      if pages.length() == 0 {
        // 校验类失败用 1（与「文件有问题」一致），不用用法错误的 2
        println("错误: 不是合法的 Ogg 文件 —— " + path)
        @sys.exit(1)
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
      // CRC 失败同样是 error：字节坏了，不是「可疑形态」。
      // 每页只算一次 CRC（`page_crc_ok` 会复制整页），计数与问题条目共用结果。
      let mut ok = 0
      let mut bad = 0
      for page in pages {
        if @ogg.page_crc_ok(page) {
          ok = ok + 1
        } else {
          bad = bad + 1
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
      if json {
        let sb = StringBuilder()
        sb.write_stringview("{\"file\":")
        sb.write_stringview(json_string(path))
        sb.write_stringview(",\"bytes\":")
        sb.write_stringview(data.length().to_string())
        sb.write_stringview(",\"pages\":")
        sb.write_stringview(pages.length().to_string())
        sb.write_stringview(",\"chains\":")
        sb.write_stringview(@ogg.split_chains(pages).length().to_string())
        sb.write_stringview(",\"streams\":")
        sb.write_stringview(@ogg.serials_of(pages).length().to_string())
        sb.write_stringview(",\"crc_ok\":")
        sb.write_stringview(ok.to_string())
        sb.write_stringview(",\"crc_bad\":")
        sb.write_stringview(bad.to_string())
        sb.write_stringview(",\"errors\":")
        sb.write_stringview(errors.to_string())
        sb.write_stringview(",\"warnings\":")
        sb.write_stringview(warnings.to_string())
        sb.write_stringview(",\"findings\":[")
        let mut fi = 0
        for f in findings {
          if fi > 0 {
            sb.write_stringview(",")
          }
          sb.write_stringview("{\"severity\":")
          sb.write_stringview(json_string(@ogg.severity_label(f.severity)))
          sb.write_stringview(",\"message\":")
          sb.write_stringview(json_string(f.message))
          sb.write_stringview("}")
          fi = fi + 1
        }
        sb.write_stringview("]}")
        println(sb.to_string())
      } else {
        println("文件:     " + path)
        println("字节数:   " + data.length().to_string())
        println("页数:     " + pages.length().to_string())
        println("物理流:   " + @ogg.split_chains(pages).length().to_string())
        println("逻辑流:   " + @ogg.serials_of(pages).length().to_string())
        println(
          "CRC 通过: " + ok.to_string() + "  失败: " + bad.to_string(),
        )
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
          println(
            "结论:     结构完好（CRC、页序号、BOS·EOS、粒度全部自洽）",
          )
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
/// 读 `MOONMUX_MAX_PCM_MB` 作为转码的 PCM 预算；非法值退回默认 256 MiB。
///
/// 默认值对单链长文件是一个能力上限（约 46 分钟单声道 Opus）。
/// 给一个显式覆盖入口，比让用户去改代码或忍受 OOM 更合理。
fn pcm_budget_bytes() -> Int64 {
  let default : Int64 = 256L * 1048576L
  match @env.get_env_var("MOONMUX_MAX_PCM_MB") {
    None => default
    Some(v) => budget_from_text(v)
  }
}

///|
/// 解析预算文本（单位 MiB）：只接受 1..4096 的纯十进制整数，其余退回默认 256 MiB。
/// 拆成纯函数是为了能单测 —— 环境变量在本进程里不好设置。
fn budget_from_text(v : String) -> Int64 {
  let default : Int64 = 256L * 1048576L
  let mut n : Int64 = 0L
  let mut ok = v.length() > 0
  let mut i = 0
  while i < v.length() {
    match v.get_char(i) {
      Some(c) => {
        let d = c.to_int() - 48
        if d < 0 || d > 9 {
          ok = false
        } else {
          n = n * 10L + d.to_int64()
        }
      }
      None => ok = false
    }
    i = i + 1
  }
  if ok && n > 0L && n <= 4096L {
    n * 1048576L
  } else {
    default
  }
}

///|
/// 调容器层的 chop；失败时按「用法/数据」分流退出。
/// 末尾的空数组不可达（fail 直接退出），只为满足类型。
fn chop_or_exit(
  pages : Array[@ogg.Page],
  serial : UInt32,
  start : Int64,
  end : Int64,
) -> Array[@ogg.Page] {
  match @ogg.chop_pages(pages, serial, start, end) {
    Ok(v) => v
    Err(msg) => {
      if msg.contains("只处理") || msg.contains("一次只处理") {
        fail("错误: " + msg)
      } else {
        fail_data("错误: " + msg)
      }
      []
    }
  }
}

///|
/// `chop`：按毫秒区间裁剪，页精度。
///
/// 容器层只认粒度，所以这里先用 `audio_stream_info` 取得采样率，
/// 把毫秒换算成 granule。输出保留原粒度（时间轴不变），
/// 并补 EOS；写盘后回读自检，坏文件不留在磁盘上。
fn run_chop(
  src : String,
  out : String,
  start_ms : Int32,
  end_ms : Int32,
) -> Unit {
  match read_all(src) {
    None => ()
    Some(data) => {
      let pages = @ogg.parse_pages(data)
      if pages.length() == 0 {
        fail_data("错误: 不是合法的 Ogg 文件 —— " + src)
        return
      }
      require_fully_parsed(src, pages, data)
      let info = match audio_stream_info(pages) {
        Ok(v) => v
        Err(msg) => {
          fail_data("错误: " + msg)
          return
        }
      }
      let (serial, audio, _, _) = info
      let rate = audio.sample_rate.to_int64()
      if rate <= 0L {
        fail_data("错误: 采样率无效，无法把毫秒换算成粒度")
        return
      }
      let start_g = start_ms.to_int64() * rate / 1000L
      let end_g = end_ms.to_int64() * rate / 1000L
      let chopped = chop_or_exit(pages, serial, start_g, end_g)
      let bytes = @ogg.serialize_pages(chopped)
      @fs.write_bytes_to_file(out, bytes) catch {
        IOError(msg) => {
          fail("错误: 无法写入 " + out + " —— " + msg)
          return
        }
      }
      // 自检：读回、逐页 CRC、结构问题都必须干净
      let back = @ogg.parse_pages(bytes)
      let mut bad = 0
      for p in back {
        if !@ogg.page_crc_ok(p) {
          bad = bad + 1
        }
      }
      let mut errors = 0
      for f in @ogg.structure_findings(back) {
        match f.severity {
          @ogg.Severity::Error => errors = errors + 1
          _ => ()
        }
      }
      if back.length() != chopped.length() || bad > 0 || errors > 0 {
        @fs.remove_file(out) catch {
          _ => ()
        }
        fail_data("错误: 写出后自检失败，已删除 —— " + out)
        return
      }
      // 容器层已把粒度减去起点，这里直接用它当片段时长
      let last_g = back[back.length() - 1].granule_position
      let span = last_g
      let hundredths = if span > 0L { span * 100L / rate } else { 0L }
      println(
        "已写出 " +
        out +
        "  " +
        chopped.length().to_string() +
        " 页  约 " +
        (hundredths / 100L).to_string() +
        "." +
        pad2((hundredths % 100L).to_int()) +
        " 秒",
      )
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
fn run_towav(src : String, out : String, bits : Int32) -> Unit {
  match read_all(src) {
    None => ()
    Some(data) => {
      let pages = @ogg.parse_pages(data)
      if pages.length() == 0 {
        fail_data("错误: 不是合法的 Ogg 文件 —— " + src)
        return
      }
      require_fully_parsed(src, pages, data)
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
      match @pipeline.ogg_to_wav_pages_bits(pages, pcm_budget_bytes(), bits) {
        Err(msg) => fail_data("错误: 转码失败 —— " + msg)
        Ok(wav) => {
          @fs.write_bytes_to_file(out, wav) catch {
            IOError(msg) => {
              fail("错误: 无法写入 " + out + " —— " + msg)
              return
            }
          }
          // 回读一遍，确认产出的 WAV 能被子模块自己解析回来
          match @wav.WavFile::parse(wav) {
            None => {
              @fs.remove_file(out) catch {
                _ => ()
              }
              fail_data(
                "错误: 已写出 " +
                out +
                "，但回读校验未通过，已删除",
              )
            }
            Some(f) =>
              println(
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
fn pad6(n : Int32) -> String {
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
fn pad2(n : Int32) -> String {
  if n < 10 {
    "0" + n.to_string()
  } else {
    n.to_string()
  }
}

///|
/// 入口：剥掉 argv[0]，其余交给 cli 解析。

///|
/// JSON 字符串转义：引号、反斜杠、控制字符。
fn json_escape(s : String) -> String {
  let sb = StringBuilder()
  let mut i = 0
  while i < s.length() {
    match s.get_char(i) {
      Some(c) =>
        match c {
          '"' => sb.write_stringview("\\\"")
          '\\' => sb.write_stringview("\\\\")
          '\n' => sb.write_stringview("\\n")
          '\r' => sb.write_stringview("\\r")
          '\t' => sb.write_stringview("\\t")
          _ =>
            if c.to_int() < 0x20 {
              sb.write_stringview("\\u00")
              sb.write_char(hex_digit((c.to_int() >> 4) & 0xF))
              sb.write_char(hex_digit(c.to_int() & 0xF))
            } else {
              sb.write_char(c)
            }
        }
      None => ()
    }
    i = i + 1
  }
  sb.to_string()
}

///|
/// 一位十六进制字符（大写）。
fn hex_digit(n : Int32) -> Char {
  let digits = "0123456789ABCDEF"
  match digits.get_char(n) {
    Some(c) => c
    None => '0'
  }
}

///|
/// 加引号的 JSON 字符串。
fn json_string(s : String) -> String {
  "\"" + json_escape(s) + "\""
}

///|
/// Ogg 信息的 JSON 版本（单行）。统计逻辑与文本版一致，只是渲染不同。
fn print_ogg_json(
  path : String,
  data : Bytes,
  pages : Array[@ogg.Page],
) -> Unit {
  let chains = @ogg.split_chains(pages)
  let serials = @ogg.serials_of(pages)
  let index_of : Map[UInt32, Int32] = Map([])
  let mut k = 0
  while k < serials.length() {
    index_of.set(serials[k], k)
    k = k + 1
  }
  let page_counts = Array::make(serials.length(), 0)
  let byte_counts = Array::make(serials.length(), 0)
  let first_granules = Array::make(serials.length(), -1L)
  let last_granules = Array::make(serials.length(), -1L)
  let has_granules = Array::make(serials.length(), false)
  for page in pages {
    match index_of.get(page.serial) {
      Some(idx) => {
        page_counts[idx] = page_counts[idx] + 1
        byte_counts[idx] = byte_counts[idx] + page.payload.length()
        if page.granule_position >= 0L {
          if !has_granules[idx] {
            first_granules[idx] = page.granule_position
          }
          last_granules[idx] = page.granule_position
          has_granules[idx] = true
        }
      }
      None => ()
    }
  }
  // 每条流只取首个包（标识头），不重组整条流
  let heads : Array[Bytes?] = Array::make(serials.length(), None)
  let mut hi = 0
  while hi < serials.length() {
    heads[hi] = @ogg.first_packet(pages, serials[hi])
    hi = hi + 1
  }
  let sb = StringBuilder()
  sb.write_stringview("{\"file\":")
  sb.write_stringview(json_string(path))
  sb.write_stringview(",\"format\":\"ogg\",\"bytes\":")
  sb.write_stringview(data.length().to_string())
  sb.write_stringview(",\"pages\":")
  sb.write_stringview(pages.length().to_string())
  sb.write_stringview(",\"packets\":")
  sb.write_stringview(@ogg.count_packets(pages).to_string())
  sb.write_stringview(",\"chains\":")
  sb.write_stringview(chains.length().to_string())
  sb.write_stringview(",\"streams\":[")
  let mut i = 0
  while i < serials.length() {
    if i > 0 {
      sb.write_stringview(",")
    }
    sb.write_stringview("{\"index\":")
    sb.write_stringview((i + 1).to_string())
    sb.write_stringview(",\"serial\":")
    sb.write_stringview(serials[i].to_string())
    sb.write_stringview(",\"pages\":")
    sb.write_stringview(page_counts[i].to_string())
    sb.write_stringview(",\"payload_bytes\":")
    sb.write_stringview(byte_counts[i].to_string())
    if has_granules[i] {
      sb.write_stringview(",\"last_granule\":")
      sb.write_stringview(last_granules[i].to_string())
    }
    match heads[i] {
      Some(head) =>
        match @codec.parse_audio_header(head) {
          Some(info) => {
            sb.write_stringview(",\"codec\":")
            sb.write_stringview(json_string(info.codec))
            sb.write_stringview(",\"channels\":")
            sb.write_stringview(info.channels.to_string())
            sb.write_stringview(",\"sample_rate\":")
            sb.write_stringview(info.sample_rate.to_string())
            if has_granules[i] {
              let secs = @codec.duration_seconds(
                info,
                first_granules[i],
                last_granules[i],
              )
              let ms = (secs * 1000.0 + 0.5).to_int64()
              sb.write_stringview(",\"duration_ms\":")
              sb.write_stringview(ms.to_string())
            }
          }
          None => ()
        }
      None => ()
    }
    sb.write_stringview("}")
    i = i + 1
  }
  sb.write_stringview("]}")
  println(sb.to_string())
}

///|
/// WAV 信息的 JSON 版本（单行）。
fn print_wav_json(path : String, data : Bytes, f : @wav.WavFile) -> Unit {
  let frame_size = f.format.channels * (f.format.bits_per_sample / 8)
  let sb = StringBuilder()
  sb.write_stringview("{\"file\":")
  sb.write_stringview(json_string(path))
  sb.write_stringview(",\"format\":\"wav\",\"bytes\":")
  sb.write_stringview(data.length().to_string())
  sb.write_stringview(",\"channels\":")
  sb.write_stringview(f.format.channels.to_string())
  sb.write_stringview(",\"sample_rate\":")
  sb.write_stringview(f.format.sample_rate.to_string())
  sb.write_stringview(",\"bits\":")
  sb.write_stringview(f.format.bits_per_sample.to_string())
  sb.write_stringview(",\"pcm_bytes\":")
  sb.write_stringview(f.data.length().to_string())
  if frame_size > 0 && f.format.sample_rate > 0 {
    sb.write_stringview(",\"frames\":")
    sb.write_stringview((f.data.length() / frame_size).to_string())
  }
  sb.write_stringview("}")
  println(sb.to_string())
}

///|
fn main {
  let argv = @env.args()
  let rest : Array[String] = []
  let mut i = 1
  while i < argv.length() {
    rest.push(argv[i])
    i = i + 1
  }
  match @cli.parse(rest) {
    @cli.Command::Info(path, json) => run_info(path, json)
    @cli.Command::Demux(src, dir) => run_demux(src, dir)
    @cli.Command::Mux(dir, out) => run_mux(dir, out)
    @cli.Command::Cat(inputs, out) => run_cat(inputs, out)
    @cli.Command::Split(src, dir) => run_split(src, dir)
    @cli.Command::Extract(src, index, out) => run_extract(src, index, out)
    @cli.Command::Dump(path, hex) => run_dump(path, hex)
    @cli.Command::Tags(path) => run_tags(path)
    @cli.Command::TagWrite(src, out, assigns) => run_tag(src, out, assigns)
    @cli.Command::Seek(path, ms, chain) => run_seek(path, ms, chain)
    @cli.Command::Verify(path, json) => run_verify(path, json)
    @cli.Command::ToWav(src, out, bits) => run_towav(src, out, bits)
    @cli.Command::Chop(src, out, start_ms, end_ms) =>
      run_chop(src, out, start_ms, end_ms)
    @cli.Command::Version => println(@moonmux.describe())
    @cli.Command::Help => println(@cli.usage())
    @cli.Command::Bad(msg, usage) => {
      // 不能调 fail：它内部立刻 exit，后面的用法文本就永远打不出来
      println("错误: " + msg)
      println("")
      println(usage)
      @sys.exit(2)
    }
  }
}
