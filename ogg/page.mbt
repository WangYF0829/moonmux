// page.mbt —— Ogg 页的解析与序列化
//
// 页是 Ogg 容器的最小同步单位，结构遵循 RFC 3533：
//
//   偏移  长度  字段
//   0     4     捕获模式 "OggS"
//   4     1     流结构版本（固定为 0）
//   5     1     头类型标志
//   6     8     粒度位置（granule position）
//   14    4     逻辑流序号
//   18    4     页序号
//   22    4     CRC 校验
//   26    1     段数
//   27    N     段表（每项 0..255）
//   27+N  M     负载
//
// 除捕获模式外所有多字节字段均为小端序。
// CRC 字段在计算校验值时必须先置零；校验范围覆盖整页，**包含**开头的捕获模式。
// 把捕获模式排除在外是最容易犯、后果最严重的错误：算出的页与所有标准解码器都不兼容，
// 而自产自销的往返测试发现不了（详见 expected_crc 的说明与 ogg_wbtest.mbt 的回归用例）。

///|
/// 一个 Ogg 页。
///
/// `segments` 保存原始段表（每项 0 到 255），它决定包在页边界处的切分方式；
/// `payload` 是所有段负载的拼接。两者都保留，是因为「重组包」既需要负载本身，
/// 也需要段表来判断包在哪里结束。
pub(all) struct Page {
  header_type : Byte
  granule_position : Int64
  serial : UInt
  sequence : UInt
  crc : UInt
  segments : Array[Int]
  payload : Bytes
}

///|
/// 头类型标志：本页以一个「延续自上一页的包」开头。
pub fn flag_continued() -> Byte {
  (0x01 : Byte)
}

///|
/// 头类型标志：本页是逻辑流的第一个页（beginning of stream）。
pub fn flag_bos() -> Byte {
  (0x02 : Byte)
}

///|
/// 头类型标志：本页是逻辑流的最后一个页（end of stream）。
pub fn flag_eos() -> Byte {
  (0x04 : Byte)
}

///|
/// 小端读取 32 位无符号整数。
fn read_u32_le(data : Bytes, offset : Int) -> UInt {
  let b0 = data[offset].to_int().reinterpret_as_uint()
  let b1 = data[offset + 1].to_int().reinterpret_as_uint()
  let b2 = data[offset + 2].to_int().reinterpret_as_uint()
  let b3 = data[offset + 3].to_int().reinterpret_as_uint()
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

///|
/// 小端读取 64 位无符号整数。
fn read_u64_le(data : Bytes, offset : Int) -> UInt64 {
  let lo = read_u32_le(data, offset).to_uint64()
  let hi = read_u32_le(data, offset + 4).to_uint64()
  lo | (hi << 32)
}

///|
/// 判断 `offset` 处是否为 Ogg 页的捕获模式 "OggS"。
///
/// `offset` 来自调用方，必须先挡掉负值 —— 否则 `offset + 4 <= 长度`
/// 这类上界检查拦不住它，索引到负数会在运行时直接崩掉。
pub fn is_page_start(data : Bytes, offset : Int) -> Bool {
  offset >= 0 &&
  offset + 4 <= data.length() &&
  data[offset].to_int() == 0x4F &&
  data[offset + 1].to_int() == 0x67 &&
  data[offset + 2].to_int() == 0x67 &&
  data[offset + 3].to_int() == 0x53
}

///|
/// 从 `data` 的 `offset` 处解析一个 Ogg 页，同时给出下一页的起始偏移。
///
/// 返回 `None` 表示此处不是合法页起点（捕获模式不匹配或数据不足），
/// 调用方可以据此在字节流中重新同步。
pub fn Page::parse(data : Bytes, offset : Int) -> (Page, Int)? {
  // 固定头 27 字节
  if offset + 27 > data.length() {
    return None
  }
  if !is_page_start(data, offset) {
    return None
  }
  let header_type = data[offset + 5]
  let granule_position = read_u64_le(data, offset + 6).reinterpret_as_int64()
  let serial = read_u32_le(data, offset + 14)
  let sequence = read_u32_le(data, offset + 18)
  let crc = read_u32_le(data, offset + 22)
  let n_segments = data[offset + 26].to_int()
  // 段表
  let table_start = offset + 27
  if table_start + n_segments > data.length() {
    return None
  }
  let segments : Array[Int] = []
  let mut payload_len = 0
  let mut k = 0
  while k < n_segments {
    let v = data[table_start + k].to_int()
    segments.push(v)
    payload_len = payload_len + v
    k = k + 1
  }
  // 负载
  let payload_start = table_start + n_segments
  let payload_end = payload_start + payload_len
  if payload_end > data.length() {
    return None
  }
  let payload_buf = Buffer()
  let mut p = payload_start
  while p < payload_end {
    payload_buf.write_byte(data[p])
    p = p + 1
  }
  let page : Page = {
    header_type,
    granule_position,
    serial,
    sequence,
    crc,
    segments,
    payload: payload_buf.to_bytes(),
  }
  Some((page, payload_end))
}

///|
/// 写入捕获模式 "OggS"。
fn write_capture(buf : Buffer) -> Unit {
  buf.write_byte((0x4F : Byte))
  buf.write_byte((0x67 : Byte))
  buf.write_byte((0x67 : Byte))
  buf.write_byte((0x53 : Byte))
}

///|
/// 写入捕获模式之后的页体。
///
/// 构造第一次时 `crc` 传 0 用于计算校验值，构造第二次时传入真实值 ——
/// 这样就不需要「先写占位再回填」，因为 `Bytes` 本身不可变。
fn write_body(buf : Buffer, page : Page, crc : UInt) -> Unit {
  buf.write_byte((0x00 : Byte))
  buf.write_byte(page.header_type)
  buf.write_uint64_le(page.granule_position.reinterpret_as_uint64())
  buf.write_uint_le(page.serial)
  buf.write_uint_le(page.sequence)
  buf.write_uint_le(crc)
  buf.write_byte(page.segments.length().to_byte())
  for s in page.segments {
    buf.write_byte(s.to_byte())
  }
  buf.write_bytes(page.payload.exact_view())
}

///|
/// 重算一页应有的 CRC 校验值：范围覆盖**整个页，包含开头的捕获模式 "OggS"**，
/// 计算时 CRC 字段自身置零。
///
/// 这一点极易搞错，且代价很大：若把捕获模式排除在计算范围之外，
/// 算出的校验值与所有标准解码器都不一致，生成的文件会被拒绝，
/// 而自产自销的往返测试却完全发现不了 —— 此处已用真实文件逐页校验过。
///
/// 只算不写，因此可以用来**校验**从外部拿到的文件：
/// 把结果与该页里存着的 `crc` 字段比较即可（见 `page_crc_ok`）。
pub fn Page::expected_crc(self : Page) -> UInt {
  let probe = Buffer()
  write_capture(probe)
  write_body(probe, self, 0U)
  crc32(probe.to_bytes())
}

///|
/// 把页序列化为字节，并写入正确的 CRC 校验值。
pub fn Page::to_bytes(self : Page) -> Bytes {
  let out = Buffer()
  write_capture(out)
  write_body(out, self, self.expected_crc())
  out.to_bytes()
}
