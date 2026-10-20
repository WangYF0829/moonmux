// pipeline.mbt —— Ogg（Opus / Vorbis）→ WAV 的转码管线
//
// 一条链路上有三个角色，各有各的边界：
//
//   1. 识别编码格式 —— 用本项目的 `ogg/` 拆包，看首个包的头部标记。
//      这是容器层的活，不该由解码器顺手代劳，也不该靠文件扩展名猜。
//   2. 解码成 PCM —— 交给生态里已有的纯 MoonBit 解码器。
//   3. 编码成 WAV —— 用本项目的 `wav/`。
//
// 失败一律返回 Err(说明) 而不是抛异常：解码器本身的能力是有范围的
// （例如 moonopus 目前只支持 CELT-only 全频带单声道），
// 把范围外的流如实退回来，比编造一个安静的输出更有用。
//
// 关于「交给解码器的到底是什么」：这里先把目标逻辑流**抽成一份独立的
// 单流 Ogg**（用容器层的 stream_pages），再递给解码器。
// 直接把整份多流文件丢过去是不行的 —— 解码器看到别的流的包只会报错，
// 或者更糟：把它当成自己流的残包解出噪声。抽流是筛选而不是重写，
// 页级原样，所以这一步不引入任何失真。

///|
/// 识别出的音频编码格式。
pub(all) enum Codec {
  /// Ogg Opus（RFC 7845）
  Opus
  /// Ogg Vorbis
  Vorbis
}

///|
/// 一段解出来的音频：格式 + 16 位小端交错的 PCM。
priv struct Pcm {
  channels : Int
  sample_rate : Int
  data : Bytes
}

///|
/// 小端写入一个 16 位有符号采样。
///
/// 先折到无符号区间再拆两个字节，避开 Int → UInt16 转换的语义细节，
/// 这样负样本写入的补码是确定的。
fn write_i16_le(buf : Buffer, v : Int) -> Unit {
  let u = if v < 0 { v + 65536 } else { v }
  buf.write_byte((u % 256).to_byte())
  buf.write_byte((u / 256).to_byte())
}

///|
/// 把 [-1, 1] 的浮点采样折成 16 位整数并写入，超出范围的一律夹住。
///
/// 夹住而不是回绕：解码器偶尔会给出略微越界的值（浮点误差），
/// 回绕会让一个 1.0001 的样本变成满量程负值，听上去是一声爆音。
fn write_sample(buf : Buffer, s : Double) -> Unit {
  let v = (s * 32767.0).to_int()
  let q = if v > 32767 {
    32767
  } else if v < -32768 {
    -32768
  } else {
    v
  }
  write_i16_le(buf, q)
}

///|
/// 判断 `data` 从 `offset` 起是否为给定的字节序列。
fn starts_with(data : Bytes, offset : Int, tag : Bytes) -> Bool {
  if offset < 0 || offset + tag.length() > data.length() {
    return false
  }
  let mut i = 0
  while i < tag.length() {
    if data[offset + i] != tag[i] {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// 从一个包的头部标记判断它属于哪种编码；都不是则 None。
///
/// 判据是包内容而不是文件扩展名 —— 扩展名可以被随便改，
/// 而 Ogg 的规范（RFC 7845 / Vorbis I）要求标识包必须是流的第一个包：
/// Opus 的标识包以 "OpusHead" 开头，Vorbis 的以 0x01 + "vorbis" 开头。
fn codec_of_packet(head : Bytes) -> Codec? {
  if starts_with(head, 0, b"OpusHead") {
    Some(Codec::Opus)
  } else if head.length() >= 7 &&
    head[0].to_int() == 0x01 &&
    starts_with(head, 1, b"vorbis") {
    Some(Codec::Vorbis)
  } else {
    None
  }
}

///|
/// 在一段物理流里找出**第一条可识别的音频逻辑流**。
///
/// 按流号的首次出现顺序找，返回 `(流号, 编码)`。
/// 一个文件里可能交织着视频流、字幕流或第二条音轨，
/// 它们的首个包不是音频标识包，会被跳过。
///
/// 找不到可识别的音频流时返回 Err，说明里点明「首包既不是 OpusHead
/// 也不是 Vorbis 标识包」—— 这句话直接告诉用户问题出在哪一层。
fn first_audio_stream(pages : Array[@ogg.Page]) -> Result[(UInt, Codec), String] {
  let serials = @ogg.serials_of(pages)
  if serials.length() == 0 {
    return Err("文件里没有任何逻辑流")
  }
  let mut i = 0
  while i < serials.length() {
    let serial = serials[i]
    let packets = @ogg.reassemble(@ogg.stream_pages(pages, serial))
    if packets.length() > 0 {
      match codec_of_packet(packets[0].data) {
        Some(codec) => return Ok((serial, codec))
        None => ()
      }
    }
    i = i + 1
  }
  Err("文件里没有可识别的音频流（首包既不是 OpusHead 也不是 Vorbis 标识包）")
}

///|
/// 识别一个 Ogg 文件里第一条音频逻辑流用的是什么编码。
///
/// 看的是逻辑流，不是「文件的第一个包」：多流文件里第一条逻辑流
/// 未必是音频（可能是 Skeleton 骨架流），逐流检查才不会认错。
pub fn detect(data : Bytes) -> Result[Codec, String] {
  let pages = @ogg.parse_pages(data)
  if pages.length() == 0 {
    return Err("不是合法的 Ogg 文件（没有解析出任何页）")
  }
  match first_audio_stream(pages) {
    Ok(target) => Ok(target.1)
    Err(msg) => Err(msg)
  }
}

///|
/// 把 Ogg 音频流转码为 WAV（16 位 PCM）字节流。
///
/// 支持三种输入形态，处理方式一致：**逐段取该段的第一条音频流**。
/// - 单流文件：一段、一条流。
/// - 多流交织文件：一段、多条流，取第一条音频流，其余（视频、第二音轨）不进 WAV。
/// - 链接流（chained）：多段，每段各取自己的音频流，解出的 PCM 依次拼接 ——
///   RFC 7845 规定播放器读到 EOS 后重新初始化解码器继续播，拼接的正是这个语义。
///
/// 链接要求各段的声道数与采样率一致：WAV 的格式块只有一份，
/// 拼不进两种格式。不一致时如实报错并指出是哪两段不符，
/// 而不是按第一段的格式硬写 —— 那会让第二段变成音调错误的噪声。
///|
/// 转码输出的内存上限（16 位 PCM 字节数）。
///
/// 整条链路没有流式写接口（`@fs` 只有整文件写），所以 PCM 必须在内存里
/// 攒齐再一次性写盘；实测峰值约为输出的 3–4 倍（解码器的 Double PCM
/// 与最终 WAV 各占一份）。超过这个上限就明确拒绝，而不是让进程 OOM。
const MAX_PCM_BYTES : Int64 = 256L * 1024L * 1024L

///|
/// 取某条流的**第一个包**（头部包）。只扫该流的页，碰到第一个包结束就停。
///
/// 估算阶段只需要头部参数，不需要把整条流重组一遍 ——
/// `reassemble` 会复制全部负载，对百万包的文件等于把内存翻倍。
fn first_packet_bytes(pages : Array[@ogg.Page], serial : UInt) -> Bytes? {
  let buf = Buffer(size_hint=256)
  for page in pages {
    if page.serial == serial {
      let mut completes = false
      for seg in page.segments {
        if seg < 255 {
          completes = true
        }
      }
      buf.write_bytes(page.payload.exact_view())
      if completes {
        return Some(buf.to_bytes())
      }
    }
  }
  None
}

///|
/// 估算整份输出需要多少 16 位 PCM 字节：逐段按「末粒度 − 首粒度 − pre-skip」
/// 乘声道数。复杂度 O(页数)，不解码、不重组。
fn estimate_pcm_bytes(chains : Array[Array[@ogg.Page]]) -> Int64 {
  let mut total : Int64 = 0L
  for part in chains {
    // 找该段的第一条音频流：逐流取头部包解析
    let mut chosen : UInt? = None
    let mut channels = 0
    let mut pre_skip : Int64 = 0L
    for serial in @ogg.serials_of(part) {
      match first_packet_bytes(part, serial) {
        Some(pkt) =>
          match @codec.parse_audio_header(pkt) {
            Some(info) => {
              chosen = Some(serial)
              channels = info.channels
              pre_skip = info.pre_skip.to_int64()
            }
            None => ()
          }
        None => ()
      }
      if chosen is Some(_) {
        break
      }
    }
    let serial = match chosen {
      Some(s) => s
      None => continue
    }
    if channels <= 0 {
      continue
    }
    let mut first : Int64 = -1L
    let mut last : Int64 = -1L
    for p in part {
      if p.serial == serial && p.granule_position >= 0L {
        if first < 0L {
          first = p.granule_position
        }
        last = p.granule_position
      }
    }
    if first < 0L || last <= first {
      continue
    }
    let samples = last - first - pre_skip
    if samples <= 0L {
      continue
    }
    let per_sample = channels.to_int64() * 2L
    // 乘法前检查：损坏的 granule（例如 INT64_MAX）会让乘法回绕成负数，
    // 上限就永远不触发 —— 直接当成「超限」处理。
    if per_sample <= 0L || samples > (9223372036854775807L - total) / per_sample {
      return MAX_PCM_BYTES + 1L
    }
    total = total + samples * per_sample
  }
  total
}

///|
/// Ogg → WAV。
pub fn ogg_to_wav(data : Bytes) -> Result[Bytes, String] {
  ogg_to_wav_limited(data, MAX_PCM_BYTES)
}

///|
/// 同 `ogg_to_wav`，但允许调用方指定 PCM 预算（字节）。
///
/// 命令行通过 `MOONMUX_MAX_PCM_MB` 覆盖：默认 256 MiB 对单链长文件是一个
/// 能力上限（约 46 分钟单声道 Opus），知道自己在做什么的用户可以调大。
pub fn ogg_to_wav_limited(data : Bytes, limit : Int64) -> Result[Bytes, String] {
  let pages = @ogg.parse_pages(data)
  if pages.length() == 0 {
    return Err("不是合法的 Ogg 文件（没有解析出任何页）")
  }
  let chains = @ogg.split_chains(pages)
  let estimated = estimate_pcm_bytes(chains)
  if estimated > limit {
    // 估算函数在数值异常（粒度溢出）时返回 MAX+1 的哨兵值，
    // 直接打印会变成「预计 256 MiB 超过 256 MiB」这种自相矛盾的话。
    if estimated > MAX_PCM_BYTES {
      return Err("无法估算输出大小（页粒度超出可表示范围，文件可能已损坏）")
    }
    return Err(
      "预计输出 " +
      (estimated / 1048576L).to_string() +
      " MiB 的 PCM，超过 " +
      (limit / 1048576L).to_string() +
      " MiB 的内存预算（解码峰值约为它的 3–4 倍）。\n" +
      "  链接流可先 split 拆开逐段转码；单链文件需要外部切分或重编码。\n" +
      "  确认内存足够时可用环境变量 MOONMUX_MAX_PCM_MB 调大预算",
    )
  }
  // 预分配：避免 Buffer 反复倍增时同时持有新旧两块内存。
  // 但估算值来自输入（不可全信），预分配封顶 16 MiB，其余按需增长 ——
  // 否则一个伪造的 granule 就能让进程立刻申请 256 MiB。
  let hint = if estimated > 16777216L {
    16777216L
  } else {
    estimated
  }
  let buf = Buffer(size_hint=hint.to_int())
  let mut channels = 0
  let mut sample_rate = 0
  let mut seg = 0
  while seg < chains.length() {
    let part = chains[seg]
    let target = match first_audio_stream(part) {
      Ok(t) => t
      Err(msg) => {
        return Err("第 " + (seg + 1).to_string() + " 段：" + msg)
      }
    }
    let serial = target.0
    let codec = target.1
    // 抽成独立的单流 Ogg 再交给解码器（见文件头说明）
    let one = @ogg.serialize_pages(@ogg.stream_pages(part, serial))
    let decoded = match decode_stream(one, codec) {
      Ok(d) => d
      Err(msg) => {
        return Err("第 " + (seg + 1).to_string() + " 段：" + msg)
      }
    }
    if channels == 0 {
      channels = decoded.channels
      sample_rate = decoded.sample_rate
    } else if decoded.channels != channels || decoded.sample_rate != sample_rate {
      return Err(
        "链接流各段的格式不一致：第 1 段 " +
        channels.to_string() +
        " 声道 / " +
        sample_rate.to_string() +
        " Hz，第 " +
        (seg + 1).to_string() +
        " 段 " +
        decoded.channels.to_string() +
        " 声道 / " +
        decoded.sample_rate.to_string() +
        " Hz —— 一份 WAV 只能有一个格式块，请先用 split 拆开分别转码",
      )
    }
    buf.write_bytes(decoded.data.exact_view())
    seg = seg + 1
  }
  if channels == 0 || sample_rate == 0 {
    return Err("没有解出任何音频数据")
  }
  let format : @wav.WavFormat = { channels, sample_rate, bits_per_sample: 16 }
  Ok(@wav.encode_wav(format, buf.to_bytes()))
}

///|
/// 按编码格式分派到对应的解码路径。
fn decode_stream(data : Bytes, codec : Codec) -> Result[Pcm, String] {
  match codec {
    Codec::Opus => opus_pcm(data)
    Codec::Vorbis => vorbis_pcm(data)
  }
}

///|
/// Ogg Opus → PCM。
///
/// `moonopus` 输出 48 kHz 单声道 Double PCM —— Opus 的解码采样率固定为
/// 48 kHz，与编码时的原始采样率无关（`input_sample_rate` 只是元数据）。
fn opus_pcm(data : Bytes) -> Result[Pcm, String] {
  match @moonopus.decode_opus_pcm(data) {
    Err(e) => Err("Opus 解码失败：" + e)
    Ok(samples) => {
      let buf = Buffer()
      for s in samples {
        write_sample(buf, s)
      }
      Ok({ channels: 1, sample_rate: 48000, data: buf.to_bytes() })
    }
  }
}

///|
/// Ogg Vorbis → PCM。
///
/// `moonvorbis` 输出的 PCM 是**按声道分轨**的（每声道一个 Float 数组），
/// 而 WAV 要求按帧交错，所以要在这里做一次转置。
/// 采样率与声道数取自解码出的流信息，不写死 —— Vorbis 两者都是可变的。
fn vorbis_pcm(data : Bytes) -> Result[Pcm, String] {
  match @moonvorbis.decode_ogg(data) {
    Err(e) => Err("Vorbis 解码失败：" + e)
    Ok(stream) => {
      let channels = stream.channels()
      let sample_rate = stream.sample_rate()
      if channels <= 0 {
        return Err("Vorbis 流的声道数为 0")
      }
      if sample_rate <= 0 {
        return Err("Vorbis 流的采样率为 0")
      }
      let pcm = stream.pcm()
      let frames = if pcm.length() == 0 { 0 } else { pcm[0].length() }
      let buf = Buffer()
      // 转置：pcm[声道][帧] → 帧内按声道交错
      let mut f = 0
      while f < frames {
        let mut c = 0
        while c < channels {
          if c < pcm.length() && f < pcm[c].length() {
            write_sample(buf, pcm[c][f].to_double())
          } else {
            // 声道数据缺失时补静音，保持帧对齐
            write_i16_le(buf, 0)
          }
          c = c + 1
        }
        f = f + 1
      }
      Ok({ channels, sample_rate, data: buf.to_bytes() })
    }
  }
}
