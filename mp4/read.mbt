// read.mbt —— 最小 MP4 读侧（供 `info` 识别与 remux 自检）
//
// 不追求完整 ISOBMFF 解析：只沿 ftyp → moov → mvhd / trak → mdia →
// mdhd / hdlr / minf → stbl → stsd / stsz 读出用户关心的字段
// （编码、声道、采样率、时长、样本数）。所有读取都做边界检查，
// 坏文件返回 None 而不是崩溃。
//
// 这也是本期「写—读对称」的最小验证：remux 写出的文件必须能被这里读回。

///|
/// 一条 MP4 音轨的摘要信息。
pub(all) struct Mp4Track {
  handler : String
  codec : String
  channels : Int32
  sample_rate : Int32
  duration_seconds : Double
  sample_count : Int32
}

///|
/// 一个 MP4 文件的摘要信息。
pub(all) struct Mp4Info {
  major_brand : String
  timescale : Int32
  duration_seconds : Double
  tracks : Array[Mp4Track]
}

///|
/// 扫描得到的一个 box 引用：fourcc、payload 起止偏移。
priv struct BoxRef {
  fourcc : String
  body : Int32
  next : Int32
}

// ---------- 大端读取 ----------

///|
fn rd_u8(data : Bytes, offset : Int32) -> Int32 {
  data[offset].to_int()
}

///|
fn rd_u16_be(data : Bytes, offset : Int32) -> Int32 {
  (data[offset].to_int() << 8) | data[offset + 1].to_int()
}

///|
fn rd_u32_be(data : Bytes, offset : Int32) -> Int32 {
  (data[offset].to_int() << 24) |
  (data[offset + 1].to_int() << 16) |
  (data[offset + 2].to_int() << 8) |
  data[offset + 3].to_int()
}

///|
fn rd_u64_be(data : Bytes, offset : Int32) -> Int64 {
  let hi = rd_u32_be(data, offset)
  let lo = rd_u32_be(data, offset + 4)
  ((hi.to_int64() & 0xFFFFFFFFL) << 32) | (lo.to_int64() & 0xFFFFFFFFL)
}

///|
fn rd_fourcc(data : Bytes, offset : Int32) -> String {
  let mut s = ""
  let mut i = 0
  while i < 4 {
    s = s + data[offset + i].to_char().to_string()
    i = i + 1
  }
  s
}

// ---------- box 遍历 ----------

///|
/// 扫描 [start, end) 内的同级 box，返回有效 box 列表；遇到坏长度即停止。
fn boxes_in(data : Bytes, start : Int32, end : Int32) -> Array[BoxRef] {
  let out : Array[BoxRef] = []
  let mut p = start
  let mut ok = true
  // 用「剩余字节数」比较而不是 `p + 8 <= end`：p 接近 2 GiB 时后者会回绕成
  // 负数，让循环以为还有空间，随后 body = p + 8 变成负偏移。
  while ok && p >= 0 && p <= end && end - p >= 8 {
    let size = rd_u32_be(data, p)
    let name = rd_fourcc(data, p + 4)
    let mut body = p + 8
    let mut next = 0
    if size == 1 {
      // 64 位 largesize：必须能装下 16 字节头且不越过父 box
      if end - p < 16 {
        ok = false
      } else {
        let large = rd_u64_be(data, p + 8)
        if large < 16L || large > (end - p).to_int64() {
          ok = false
        } else {
          body = p + 16
          next = p + large.to_int()
        }
      }
    } else if size == 0 {
      next = end
    } else if size < 8 {
      // 2..7 的 size 会让 box 重叠自己的头，属于损坏
      ok = false
    } else if size > end - p {
      ok = false
    } else {
      next = p + size
    }
    if ok && (next <= p || next > end) {
      ok = false
    }
    if ok {
      out.push({ fourcc: name, body, next, })
      p = next
    }
  }
  out
}

///|
/// 在同级 box 列表里按 fourcc 找第一个。
fn find_box(boxes : Array[BoxRef], name : String) -> BoxRef? {
  for b in boxes {
    if b.fourcc == name {
      return Some(b)
    }
  }
  None
}

///|
/// 取某个 box 的直接子 box。
fn child(data : Bytes, parent : BoxRef, name : String) -> BoxRef? {
  find_box(boxes_in(data, parent.body, parent.next), name)
}

// ---------- 具体字段 ----------

///|
/// mvhd / mdhd 的时间字段（version 0 用 32 位，version 1 用 64 位）。
///
/// 必须先用 `next - body` 校验字段长度：box 头长度合法但不带完整 payload
/// （例如 size=8 的空 mvhd 位于文件末尾）时，直接 `rd_u8` 会越界 panic。
/// 读侧承诺「坏文件返回 None 而不是崩溃」，这里同样返回 None。
fn read_time_header(data : Bytes, b : BoxRef) -> (Int32, Int32)? {
  let avail = b.next - b.body
  if avail < 4 {
    return None
  }
  let version = rd_u8(data, b.body)
  if version == 1 {
    if avail < 32 {
      return None
    }
    let duration = rd_u64_be(data, b.body + 24)
    Some(
      (
        rd_u32_be(data, b.body + 20),
        if duration > 2147483647L {
          2147483647
        } else {
          duration.to_int()
        },
      ),
    )
  } else {
    if avail < 20 {
      return None
    }
    let duration = rd_u32_be(data, b.body + 16).to_int64() & 0xFFFFFFFFL
    Some(
      (
        rd_u32_be(data, b.body + 12),
        if duration > 2147483647L {
          2147483647
        } else {
          duration.to_int()
        },
      ),
    )
  }
}

///|
/// 秒数换算；timescale 非法时返回 0。
fn to_seconds(duration : Int32, timescale : Int32) -> Double {
  if timescale <= 0 || duration < 0 {
    0.0
  } else {
    duration.to_double() / timescale.to_double()
  }
}

///|
/// stsd 第一条样本描述：(fourcc, 声道数, 采样率)。
fn read_stsd(data : Bytes, b : BoxRef) -> (String, Int32, Int32) {
  if b.next - b.body < 8 {
    return ("", 0, 0)
  }
  let count = rd_u32_be(data, b.body + 4)
  if count <= 0 {
    return ("", 0, 0)
  }
  let entry = b.body + 8
  if b.next - entry < 8 {
    return ("", 0, 0)
  }
  let size = rd_u32_be(data, entry)
  let codec = rd_fourcc(data, entry + 4)
  // AudioSampleEntry 固定字段到 entry + 36 结束。
  // 用「剩余字节数」比较：entry + size 在 Int32 上可回绕成负数，
  // 从而绕过父 box 边界检查（M-13）。
  if size < 36 || size.to_int64() > (b.next - entry).to_int64() {
    return (codec, 0, 0)
  }
  let channels = rd_u16_be(data, entry + 24)
  // sample_rate 是 16.16 定点；右移后必须再 & 0xFFFF，否则高位为 1 时
  // 算术右移会把负数带进来（48000 会读成 -17536）。
  let rate = (rd_u32_be(data, entry + 32) >> 16) & 0xFFFF
  (codec, channels, rate)
}

///|
/// stsz 的样本数（sample_size 非 0 时表中只给一个值，count 仍在 +8）。
///
/// 字段本身是 u32，但 `Mp4Track.sample_count` 是 Int32：0x80000000 以上
/// 直接按有符号读会显示成负数（M-17）。2 GiB 读取边界内不可能有 >= 2³¹
/// 个样本（stsz 表或定长样本都装不进文件），所以按「不可解析」返回 None，
/// 与缺 mvhd 的处理一致。
fn read_stsz_count(data : Bytes, b : BoxRef) -> Int32? {
  if b.next - b.body < 12 {
    None
  } else {
    let count = rd_u32_be(data, b.body + 8)
    if count < 0 {
      None
    } else {
      Some(count)
    }
  }
}

///|
/// 判断文件头是否像 MP4（偏移 4 处为 "ftyp"）。
pub fn is_mp4(data : Bytes) -> Bool {
  data.length() >= 12 && rd_fourcc(data, 4) == "ftyp"
}

///|
/// 解析 MP4 的摘要信息；不是可识别的 MP4（无 ftyp/moov）时返回 None。
pub fn inspect(data : Bytes) -> Mp4Info? {
  if data.length() < 16 {
    return None
  }
  let top = boxes_in(data, 0, data.length())
  let ftyp = match find_box(top, "ftyp") {
    Some(b) => b
    None => return None
  }
  let moov = match find_box(top, "moov") {
    Some(b) => b
    None => return None
  }
  if ftyp.next - ftyp.body < 4 {
    return None
  }
  let major = rd_fourcc(data, ftyp.body)
  let moov_children = boxes_in(data, moov.body, moov.next)
  // ISO/IEC 14496-12 要求 moov 必含 mvhd。缺失（或截断）时整个文件视为不可
  // 识别：否则 info 会把坏文件"洗白"成时长 0 秒的合法 MP4（M-19）。
  let mvhd = match find_box(moov_children, "mvhd") {
    Some(b) => b
    None => return None
  }
  let (timescale, duration) = match read_time_header(data, mvhd) {
    Some(pair) => pair
    // mvhd 截断：整个文件视为不可识别，而不是崩溃或给出错误时长
    None => return None
  }
  let tracks : Array[Mp4Track] = []
  for b in moov_children {
    if b.fourcc == "trak" {
      match child(data, b, "mdia") {
        Some(mdia) => {
          let mdia_children = boxes_in(data, mdia.body, mdia.next)
          let mut handler = ""
          match find_box(mdia_children, "hdlr") {
            Some(h) =>
              if h.next - h.body >= 12 {
                handler = rd_fourcc(data, h.body + 8)
              }
            None => ()
          }
          let mut ts = 0
          let mut dur = 0
          match find_box(mdia_children, "mdhd") {
            Some(m) =>
              match read_time_header(data, m) {
                Some(pair) => {
                  ts = pair.0
                  dur = pair.1
                }
                None => return None
              }
            None => ()
          }
          let mut codec = ""
          let mut channels = 0
          let mut rate = 0
          let mut samples = 0
          match child(data, mdia, "minf") {
            Some(minf) =>
              match child(data, minf, "stbl") {
                Some(stbl) => {
                  match child(data, stbl, "stsd") {
                    Some(stsd) => {
                      let t = read_stsd(data, stsd)
                      codec = t.0
                      channels = t.1
                      rate = t.2
                    }
                    None => ()
                  }
                  match child(data, stbl, "stsz") {
                    Some(stsz) =>
                      match read_stsz_count(data, stsz) {
                        Some(n) => samples = n
                        // u32 计数字段高位为 1：按不可解析处理（M-17）
                        None => return None
                      }
                    None => ()
                  }
                }
                None => ()
              }
            None => ()
          }
          tracks.push({
            handler,
            codec,
            channels,
            sample_rate: rate,
            duration_seconds: to_seconds(dur, ts),
            sample_count: samples,
          })
        }
        None => ()
      }
    }
  }
  Some({
    major_brand: major,
    timescale,
    duration_seconds: to_seconds(duration, timescale),
    tracks,
  })
}
