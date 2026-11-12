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
// **解码前 gate**：第三方解码器（moonvorbis 0.1.4）对恶意头部有内存安全
// 缺陷（已知畸形头：97/221 字节的构造文件即可越界读/panic）。这里在把
// 任何流交给解码器之前，先用本项目的 codec 解析器做结构预检：严格校验
// 标识头、注释包与 Vorbis setup 前缀，校验失败一律 Err —— 绝不把解析器
// 不认识的头部交给解码器「碰运气」。预检同时产出解码内存估算，估算与
// 解码共用同一次选流结果（H-03 / H-04）。
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
  channels : Int32
  sample_rate : Int32
  data : Bytes
}

///|
/// 小端写入一个 16 位有符号采样。
///
/// 先折到无符号区间再拆两个字节，避开 Int → UInt16 转换的语义细节，
/// 这样负样本写入的补码是确定的。
fn write_i16_le(buf : Buffer, v : Int32) -> Unit {
  let u = if v < 0 { v + 65536 } else { v }
  buf.write_byte((u % 256).to_byte())
  buf.write_byte((u / 256).to_byte())
}

///|
/// 把 [-1, 1] 的浮点采样折成 16 位整数并写入，超出范围的一律夹住。
///
/// 夹住而不是回绕：解码器偶尔会给出略微越界的值（浮点误差），
/// 回绕会让一个 1.0001 的样本变成满量程负值，听上去是一声爆音。
fn write_sample(buf : Buffer, s : Double, bits : Int32) -> Unit {
  if bits == 24 {
    let v = (s * 8388607.0).to_int()
    let q = if v > 8388607 {
      8388607
    } else if v < -8388608 {
      -8388608
    } else {
      v
    }
    write_i24_le(buf, q)
  } else {
    let v = (s * 32767.0).to_int()
    let q = if v > 32767 { 32767 } else if v < -32768 { -32768 } else { v }
    write_i16_le(buf, q)
  }
}

///|
/// 24 位小端：先折到 24 位无符号区间再拆三个字节（与 write_i16_le 同思路）。
fn write_i24_le(buf : Buffer, v : Int32) -> Unit {
  let u = if v < 0 { v + 16777216 } else { v }
  buf.write_byte((u % 256).to_byte())
  buf.write_byte((u / 256 % 256).to_byte())
  buf.write_byte((u / 65536).to_byte())
}

///|
/// 判断 `data` 从 `offset` 起是否为给定的字节序列。
fn starts_with(data : Bytes, offset : Int32, tag : Bytes) -> Bool {
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
fn first_audio_stream(
  pages : Array[@ogg.Page],
) -> Result[(UInt32, Codec), String] {
  let serials = @ogg.serials_of(pages)
  if serials.length() == 0 {
    return Err("文件里没有任何逻辑流")
  }
  let firsts = @ogg.first_packets(pages)
  let mut i = 0
  while i < serials.length() {
    let serial = serials[i]
    match firsts.get(serial) {
      Some(head) =>
        match codec_of_packet(head) {
          Some(codec) => return Ok((serial, codec))
          None => ()
        }
      None => ()
    }
    i = i + 1
  }
  Err(
    "文件里没有可识别的音频流（首包既不是 OpusHead 也不是 Vorbis 标识包）",
  )
}

///|
/// 估算时计入的解码器内部缓冲（字节 / 样本 / 声道）。
///
/// 两个第三方解码器都是「先把整段样本攒进浮点数组再返回」：
/// moonopus 用 `Array[Double]`（8 B/样本）、moonvorbis 用
/// `Array[Array[Float]]`（4 B/样本/声道，另有裁剪时的瞬时副本）。
/// 统一按 8 B 计入，宁可高估 —— 这是预算估算里「解码工作量」与
/// 「最终 PCM 字节数」的差额来源。
const DECODER_OVERHEAD_PER_SAMPLE : Int64 = 8L

///|
/// 一段（链接流中的一段）预检通过后的解码计划。
///
/// 估算与解码**共用同一份选择结果**：既避免两套头部校验器给出不同结论
/// （H-04），也保证「估算失败就当 0 放行」的旧路径不存在。
priv struct SegmentPlan {
  serial : UInt32
  codec : Codec
  channels : Int32
  sample_rate : Int32
  /// 解码期内存峰值估算（字节，含解码器内部浮点缓冲）。
  estimated_bytes : Int64
}

///|
/// `samples × channels × per_sample` 的溢出安全乘法；任何一步溢出返回 `None`。
fn checked_decoder_bytes(
  samples : Int64,
  channels : Int64,
  per_sample : Int64,
) -> Int64? {
  if samples < 0L || channels <= 0L || per_sample <= 0L {
    return None
  }
  if channels > 9223372036854775807L / per_sample {
    return None
  }
  let per_frame = channels * per_sample
  if samples > 9223372036854775807L / per_frame {
    return None
  }
  Some(samples * per_frame)
}

///|
/// 解码前的统一预检（H-03 / H-04 / C-02 的兜底闸门）。
///
/// 步骤与理由：
/// 1. 用容器层选出第一条音频流（与后续解码使用同一个 serial/codec）；
/// 2. **严格**校验头部：本项目解析器不认的头部一律 `Err`（fail closed），
///    不再「估算跳过、解码照跑」；
/// 3. 预先用本项目自己的 `@codec.parse_comment` 解析注释包 —— 第三方解码器
///    在 vendor/条目长度字段上出过越界读与 panic，而本项目解析器对同样的
///    数据安全返回 Err（C-02 的 97 B PoC 在此被挡）；
/// 4. Vorbis 额外校验 setup 头的最小结构（221 B 的恶意 setup 在此被挡）；
/// 5. 按**解码工作量**估算内存：Opus 逐包读 TOC 累加样本数，完全不信任
///    页 granule（H-03）；Vorbis 没有逐包时长，只能按 granule 估算并拒绝
///    不可用的 granule。
///
/// 返回的计划同时供估算与解码使用，避免两者选到不同的流。
fn plan_segment(
  part : Array[@ogg.Page],
  bits : Int32,
) -> Result[SegmentPlan, String] {
  let target = match first_audio_stream(part) {
    Ok(t) => t
    Err(msg) => return Err(msg)
  }
  let (serial, codec) = target
  // 抽成单流并重组头包/音频包。重组会复制负载（约 1 份输入大小），
  // 但换来了「按包计算解码工作量」与对注释头的完整边界检查；
  // 与解码器内部按样本数的放大（可达 60×）相比，这份 1× 是廉价且必要的。
  let packets = @ogg.reassemble(@ogg.stream_pages(part, serial))
  if packets.length() == 0 {
    return Err("音频流里没有可重组的包")
  }
  let bytes_per_sample : Int64 = if bits == 24 { 3L } else { 2L }
  let per_sample_unit = bytes_per_sample + DECODER_OVERHEAD_PER_SAMPLE
  match codec {
    Codec::Opus => {
      let info = match @codec.parse_opus_head(packets[0].data) {
        Some(info) => info
        None =>
          return Err(
            "不支持的 Opus 头部（只接受 OpusHead version=1 且声道/映射合法的流，已拒绝交给解码器）",
          )
      }
      if packets.length() < 2 {
        return Err("Opus 流缺少注释头（OpusTags）")
      }
      match @codec.parse_comment(packets[1].data) {
        Ok((@codec.CommentKind::Opus, _)) => ()
        Ok((@codec.CommentKind::Vorbis, _)) =>
          return Err("Opus 流的第二个包头不是 OpusTags")
        Err(msg) =>
          return Err(
            "Opus 注释头预检失败（已拒绝交给解码器）：" + msg,
          )
      }
      // 音频包 = 头两个包之后；逐包读 TOC 累加样本数。
      // 任一包的 TOC 无法解析都在解码前拒绝（与解码器的包解析规则一致）。
      let mut samples : Int64 = 0L
      let mut i = 2
      while i < packets.length() {
        match @codec.opus_packet_samples(packets[i].data) {
          Ok(n) => samples = samples + n.to_int64()
          Err(msg) =>
            return Err(
              "第 " +
              (i + 1).to_string() +
              " 个 Opus 音频包的 TOC 无法解析（已拒绝解码）：" +
              msg,
            )
        }
        i = i + 1
      }
      let estimated = match
        checked_decoder_bytes(
          samples,
          info.channels.to_int64(),
          per_sample_unit,
        ) {
        Some(v) => v
        None =>
          return Err(
            "无法估算 Opus 解码内存：样本数超出可表示范围（文件可能已损坏）",
          )
      }
      Ok({
        serial,
        codec,
        channels: info.channels,
        sample_rate: info.sample_rate,
        estimated_bytes: estimated,
      })
    }
    Codec::Vorbis => {
      let info = match @codec.parse_vorbis_id(packets[0].data) {
        Some(info) => info
        None =>
          return Err(
            "不支持的 Vorbis 识别头（已拒绝交给解码器）",
          )
      }
      if packets.length() < 2 {
        return Err("Vorbis 流缺少注释头")
      }
      match @codec.parse_comment(packets[1].data) {
        Ok((@codec.CommentKind::Vorbis, _)) => ()
        Ok((@codec.CommentKind::Opus, _)) =>
          return Err("Vorbis 流的第二个包头不是 VorbisComment")
        Err(msg) =>
          return Err(
            "Vorbis 注释头预检失败（已拒绝交给解码器）：" +
            msg,
          )
      }
      if packets.length() < 3 {
        return Err("Vorbis 流缺少 setup 头")
      }
      match @codec.validate_vorbis_setup(packets[2].data) {
        Ok(_) => ()
        Err(msg) =>
          return Err(
            "Vorbis setup 头预检失败（已拒绝交给解码器）：" +
            msg,
          )
      }
      // Vorbis 没有逐包时长字段，只能按页 granule 估算（近似：末值减首值）。
      // granule 不可用时必须拒绝，而不是当作 0 放行 —— 否则预算闸门失效。
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
        return Err(
          "Vorbis 输出大小无法估算：音频页 granule 缺失或非正（文件可能已损坏，已拒绝）",
        )
      }
      let samples = last - first
      let estimated = match
        checked_decoder_bytes(
          samples,
          info.channels.to_int64(),
          per_sample_unit,
        ) {
        Some(v) => v
        None =>
          return Err(
            "无法估算 Vorbis 解码内存：granule 超出可表示范围（文件可能已损坏）",
          )
      }
      Ok({
        serial,
        codec,
        channels: info.channels,
        sample_rate: info.sample_rate,
        estimated_bytes: estimated,
      })
    }
  }
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
/// 转码允许的解码期内存峰值预算（字节）。
///
/// 整条链路没有流式写接口（`@fs` 只有整文件写），所以 PCM 必须在内存里
/// 攒齐再一次性写盘。预算按**解码工作量**估算：样本数 × 声道数 ×
/// （输出字节/样本 + 解码器内部缓冲 8 B），样本数对 Opus 逐包读 TOC 得到、
/// 完全不依赖页 granule。
///
/// **能力边界**：外部解码器一次调用返回整段 PCM，无法在解码过程中施加
/// 输出上限；本预算只能保证「估算不通过时绝不进入解码」，无法约束解码器
/// 内部在声明合法时的瞬时分配。残余风险与实测倍率见任务报告（M-11）。
const MAX_PCM_BYTES : Int64 = 256L * 1024L * 1024L

///|
/// Ogg → WAV。
pub fn ogg_to_wav(data : Bytes) -> Result[Bytes, String] {
  ogg_to_wav_limited(data, MAX_PCM_BYTES)
}

///|
/// 同 `ogg_to_wav`，但允许调用方指定解码内存峰值预算（字节）。
///
/// 命令行通过 `MOONMUX_MAX_PCM_MB` 覆盖。预算按「样本数 × 声道数 ×
/// （输出字节 + 解码器内部缓冲 8 B）」估算：对 Opus 由逐包 TOC 累加得到
/// 样本数，对 Vorbis 由页 granule 近似（Vorbis 没有逐包时长字段）。
/// 估算不通过时在解码之前就返回 Err。
pub fn ogg_to_wav_limited(data : Bytes, limit : Int64) -> Result[Bytes, String] {
  let pages = @ogg.parse_pages(data)
  if pages.length() == 0 {
    return Err("不是合法的 Ogg 文件（没有解析出任何页）")
  }
  ogg_to_wav_pages(pages, limit)
}

///|
/// 同 `ogg_to_wav_limited`，但接收**已解析的页**。
///
/// 命令行入口为了打印「多流提示」本来就要解析一次；再调一次带 bytes 的版本
/// 会把整份输入重新解析并复制一遍（大文件上等于多一份峰值）。
pub fn ogg_to_wav_pages(
  pages : Array[@ogg.Page],
  limit : Int64,
) -> Result[Bytes, String] {
  ogg_to_wav_pages_bits(pages, limit, 16)
}

///|
/// 同 `ogg_to_wav_pages`，但从解码到量化都按 `bits`（16 或 24）输出。
pub fn ogg_to_wav_pages_bits(
  pages : Array[@ogg.Page],
  limit : Int64,
  bits : Int32,
) -> Result[Bytes, String] {
  if pages.length() == 0 {
    return Err("不是合法的 Ogg 文件（没有解析出任何页）")
  }
  if bits != 16 && bits != 24 {
    return Err("WAV 位深只支持 16 或 24，实际是 " + bits.to_string())
  }
  if limit < 0L {
    return Err("PCM 内存预算不能为负")
  }
  let chains = @ogg.split_chains(pages)
  // 预检 + 估算：与解码共用同一份选择结果（H-04），并按解码工作量估算
  // （H-03）。任何一段预检失败都直接 Err —— 绝不带着不确定的输入进解码器。
  let plans : Array[SegmentPlan] = []
  let mut estimated : Int64 = 0L
  let mut si = 0
  while si < chains.length() {
    let plan = match plan_segment(chains[si], bits) {
      Ok(p) => p
      Err(msg) => return Err("第 " + (si + 1).to_string() + " 段：" + msg)
    }
    // 累加同样做溢出检查：损坏的 granule/包数不能把估算回绕成一个小值。
    if plan.estimated_bytes > 9223372036854775807L - estimated {
      return Err(
        "无法估算输出大小（估算值超出可表示范围，文件可能已损坏）",
      )
    }
    estimated = estimated + plan.estimated_bytes
    plans.push(plan)
    si = si + 1
  }
  if estimated > limit {
    return Err(
      "预计解码内存峰值 " +
      (estimated / 1048576L).to_string() +
      " MiB（" +
      estimated.to_string() +
      " 字节），超过 " +
      (limit / 1048576L).to_string() +
      " MiB（" +
      limit.to_string() +
      " 字节）的 PCM 预算。\n" +
      "  估算按解码工作量（Opus 逐包 TOC + 解码器内部缓冲）计算，不依赖页 granule。\n" +
      "  链接流可先 split 拆开逐段转码；单链文件需要外部切分或重编码。\n" +
      "  确认内存足够时可用环境变量 MOONMUX_MAX_PCM_MB 调大预算",
    )
  }
  // 预分配：避免 Buffer 反复倍增时同时持有新旧两块内存。
  // 但估算值来自输入（不可全信），预分配封顶 16 MiB，其余按需增长。
  let hint = if estimated > 16777216L { 16777216L } else { estimated }
  let buf = Buffer(size_hint=hint.to_int())
  let mut channels = 0
  let mut sample_rate = 0
  let mut seg = 0
  while seg < chains.length() {
    let part = chains[seg]
    // 用预检阶段的同一份选择结果：估算与解码不会选到不同的流。
    let plan = plans[seg]
    let serial = plan.serial
    let codec = plan.codec
    // 抽成独立的单流 Ogg 再交给解码器（见文件头说明）
    let one = @ogg.serialize_pages(@ogg.stream_pages(part, serial))
    let decoded = match decode_stream(one, codec, bits) {
      Ok(d) => d
      Err(msg) => return Err("第 " + (seg + 1).to_string() + " 段：" + msg)
    }
    // 解码结果必须与预检读到的头部一致：两套解析器对同一个头不能给出
    // 不同结论（H-04 的「单一权威」要求）。
    if decoded.channels != plan.channels ||
      decoded.sample_rate != plan.sample_rate {
      return Err(
        "第 " +
        (seg + 1).to_string() +
        " 段：解码结果（" +
        decoded.channels.to_string() +
        " 声道 / " +
        decoded.sample_rate.to_string() +
        " Hz）与头部声明（" +
        plan.channels.to_string() +
        " 声道 / " +
        plan.sample_rate.to_string() +
        " Hz）不一致",
      )
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
    let used = buf.length().to_int64()
    let actual = decoded.data.length().to_int64()
    if used > limit || actual > limit - used {
      return Err(
        "解码后的 PCM 实际为 " +
        (used + actual).to_string() +
        " 字节，超过 " +
        limit.to_string() +
        " 字节的内存预算 — 容器估算与解码结果不一致，已停止",
      )
    }
    buf.write_bytes(decoded.data.exact_view())
    seg = seg + 1
  }
  if channels == 0 || sample_rate == 0 {
    return Err("没有解出任何音频数据")
  }
  if buf.length() == 0 {
    return Err("解码后的 PCM 为空（流里没有可解码的音频包）")
  }
  let frame_bytes = channels * (bits / 8)
  if frame_bytes > 0 && buf.length() % frame_bytes != 0 {
    return Err(
      "解码后的 PCM 不是完整帧（长度 " +
      buf.length().to_string() +
      "，帧大小 " +
      frame_bytes.to_string() +
      "）",
    )
  }
  let format : @wav.WavFormat = {
    channels,
    sample_rate,
    bits_per_sample: bits,
  }
  let total = buf.length().to_int64() + 60L
  if total > 2147483647L {
    return Err("WAV 输出超过单文件 2 GiB 上限")
  }
  Ok(@wav.encode_wav(format, buf.to_bytes()))
}

///|
/// 按编码格式分派到对应的解码路径。
fn decode_stream(
  data : Bytes,
  codec : Codec,
  bits : Int32,
) -> Result[Pcm, String] {
  match codec {
    Codec::Opus => opus_pcm(data, bits)
    Codec::Vorbis => vorbis_pcm(data, bits)
  }
}

///|
/// Ogg Opus → PCM。
///
/// `moonopus` 输出 48 kHz 单声道 Double PCM —— Opus 的解码采样率固定为
/// 48 kHz，与编码时的原始采样率无关（`input_sample_rate` 只是元数据）。
fn opus_pcm(data : Bytes, bits : Int32) -> Result[Pcm, String] {
  match @moonopus.decode_opus_pcm(data) {
    Err(e) => Err("Opus 解码失败：" + e)
    Ok(samples) => {
      let buf = Buffer()
      for s in samples {
        write_sample(buf, s, bits)
      }
      Ok({ channels: 1, sample_rate: 48000, data: buf.to_bytes(), })
    }
  }
}

///|
/// Ogg Vorbis → PCM。
///
/// `moonvorbis` 输出的 PCM 是**按声道分轨**的（每声道一个 Float 数组），
/// 而 WAV 要求按帧交错，所以要在这里做一次转置。
/// 采样率与声道数取自解码出的流信息，不写死 —— Vorbis 两者都是可变的。
fn vorbis_pcm(data : Bytes, bits : Int32) -> Result[Pcm, String] {
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
            write_sample(buf, pcm[c][f].to_double(), bits)
          } else {
            // 声道数据缺失时补静音，保持帧对齐（24 位必须写 3 字节）
            write_sample(buf, 0.0, bits)
          }
          c = c + 1
        }
        f = f + 1
      }
      Ok({ channels, sample_rate, data: buf.to_bytes(), })
    }
  }
}
