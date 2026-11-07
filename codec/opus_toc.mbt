// opus_toc.mbt —— Opus 数据包 TOC 解析（时长计算）
//
// Opus 的每个数据包都以一个 TOC（table of contents）字节开头，
// 其中高 5 位是「配置」（决定每帧样本数），低 2 位是「帧数编码」。
// 容器层把 Ogg Opus 重新封装成 MP4 时，必须知道每个包对应多少样本，
// 才能正确填写 stts（每个样本的时长）与 mdhd（媒体时长）。
//
// 依据：RFC 6716 §3.1（TOC 字节与帧长表）、RFC 7845 §4（Ogg 中的 Opus）。
// 本函数只算时长，不校验包体完整性 —— 包体 CRC/长度由容器层负责。

///|
/// 解析 Opus 包的 TOC，返回该包解码后的样本数（48 kHz 时钟）。
///
/// 每帧样本数（48 kHz）：
///   config 0–11   SILK NB/MB/WB：10/20/40/60 ms → 480/960/1920/2880
///   config 12–15  Hybrid SWB/FB：10/20 ms → 480/960
///   config 16–31  CELT NB/WB/SWB/FB：2.5/5/10/20 ms → 120/240/480/960
///
/// 帧数：code 0 → 1；code 1、2 → 2；code 3 → 读 TOC 后一字节低 6 位（1..63）。
pub fn opus_packet_samples(data : Bytes) -> Result[Int32, String] {
  if data.length() == 0 {
    return Err("Opus 数据包为空")
  }
  let toc = data[0].to_int()
  let config = (toc >> 3) & 0x1F
  let code = toc & 0x03
  let frame = if config <= 11 {
    480 << (config & 3)
  } else if config <= 15 {
    480 << ((config - 12) & 1)
  } else {
    120 << (config & 3)
  }
  let frames = if code == 0 {
    1
  } else if code == 1 || code == 2 {
    2
  } else {
    if data.length() < 2 {
      return Err("Opus 包 code=3 但缺少帧数字节")
    }
    let n = data[1].to_int() & 0x3F
    if n == 0 {
      return Err("Opus 包 code=3 但帧数为 0")
    }
    n
  }
  Ok(frame * frames)
}
