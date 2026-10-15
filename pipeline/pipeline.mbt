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

///|
/// 识别出的音频编码格式。
pub(all) enum Codec {
  /// Ogg Opus（RFC 7845）
  Opus
  /// Ogg Vorbis
  Vorbis
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
/// 识别一个 Ogg 文件里装的是什么编码。
///
/// 判据是首个逻辑包的头部标记，而不是文件扩展名 —— 扩展名可以被随便改，
/// 而 Ogg 的规范（RFC 7845 / Vorbis I）要求标识包必须是流的第一个包：
/// Opus 的标识包以 "OpusHead" 开头，Vorbis 的以 0x01 + "vorbis" 开头。
pub fn detect(data : Bytes) -> Result[Codec, String] {
  let pages = @ogg.parse_pages(data)
  if pages.length() == 0 {
    return Err("不是合法的 Ogg 文件（没有解析出任何页）")
  }
  let packets = @ogg.reassemble(pages)
  if packets.length() == 0 {
    return Err("文件里没有重组出任何完整的包")
  }
  let head = packets[0].data
  if starts_with(head, 0, b"OpusHead") {
    Ok(Codec::Opus)
  } else if head.length() >= 7 &&
    head[0].to_int() == 0x01 &&
    starts_with(head, 1, b"vorbis") {
    Ok(Codec::Vorbis)
  } else {
    Err(
      "无法识别的编码格式：首个包既不是 OpusHead 也不是 Vorbis 标识包",
    )
  }
}

///|
/// 把 Ogg 音频流转码为 WAV（16 位 PCM）字节流。
///
/// 先识别编码，再分派到对应的解码路径，最后统一用本项目的 `wav/` 编码。
pub fn ogg_to_wav(data : Bytes) -> Result[Bytes, String] {
  match detect(data) {
    Err(e) => Err(e)
    Ok(Codec::Opus) => opus_to_wav(data)
    Ok(Codec::Vorbis) => vorbis_to_wav(data)
  }
}

///|
/// Ogg Opus → WAV。
///
/// `moonopus` 输出 48 kHz 单声道 Double PCM —— Opus 的解码采样率固定为
/// 48 kHz，与编码时的原始采样率无关（`input_sample_rate` 只是元数据）。
fn opus_to_wav(data : Bytes) -> Result[Bytes, String] {
  match @moonopus.decode_opus_pcm(data) {
    Err(e) => Err("Opus 解码失败：" + e)
    Ok(samples) => {
      let buf = Buffer()
      for s in samples {
        let v = (s * 32767.0).to_int()
        let c = if v > 32767 {
          32767
        } else if v < -32768 {
          -32768
        } else {
          v
        }
        write_i16_le(buf, c)
      }
      let format : @wav.WavFormat = {
        channels: 1,
        sample_rate: 48000,
        bits_per_sample: 16,
      }
      Ok(@wav.encode_wav(format, buf.to_bytes()))
    }
  }
}

///|
/// Ogg Vorbis → WAV。
///
/// `moonvorbis` 输出的 PCM 是**按声道分轨**的（每声道一个 Float 数组），
/// 而 WAV 要求按帧交错，所以要在这里做一次转置。
/// 采样率与声道数取自解码出的流信息，不写死 —— Vorbis 两者都是可变的。
fn vorbis_to_wav(data : Bytes) -> Result[Bytes, String] {
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
            let v = (pcm[c][f].to_double() * 32767.0).to_int()
            let q = if v > 32767 {
              32767
            } else if v < -32768 {
              -32768
            } else {
              v
            }
            write_i16_le(buf, q)
          } else {
            // 声道数据缺失时补静音，保持帧对齐
            write_i16_le(buf, 0)
          }
          c = c + 1
        }
        f = f + 1
      }
      let format : @wav.WavFormat = { channels, sample_rate, bits_per_sample: 16 }
      Ok(@wav.encode_wav(format, buf.to_bytes()))
    }
  }
}
