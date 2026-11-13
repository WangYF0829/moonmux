// codec.mbt —— 编解码头解析
//
// 只读取标识头里的几个字段，用于回答「这是什么音频、多长、多少声道」。
// 不做解码，也不依赖任何三方包。

///|
/// 一段音频流的格式参数。
///
/// `sample_rate` 是**解码输出**的采样率，不是容器里记录的输入采样率 ——
/// 对 Opus 而言两者常常不同（见 `parse_opus_head`）。
pub(all) struct AudioInfo {
  codec : String
  channels : Int32
  sample_rate : Int32
  // Opus 的 pre-skip（解码器需要丢弃的前导样本数）；Vorbis 恒为 0。
  // 算时长时必须减掉它，否则会把编码器补的前导静音算进去。
  pre_skip : Int32
}

///|
/// 小端读取 16 位无符号整数。
fn rd_u16(data : Bytes, offset : Int32) -> Int32 {
  data[offset].to_int() | (data[offset + 1].to_int() << 8)
}

///|
/// 小端读取 32 位无符号整数。
fn rd_u32(data : Bytes, offset : Int32) -> Int32 {
  data[offset].to_int() |
  (data[offset + 1].to_int() << 8) |
  (data[offset + 2].to_int() << 16) |
  (data[offset + 3].to_int() << 24)
}

///|
/// 判断 `data` 从 `offset` 起是否等于给定的 ASCII 标记。
fn tag_at(data : Bytes, offset : Int32, tag : String) -> Bool {
  if offset + tag.length() > data.length() {
    return false
  }
  let mut i = 0
  let mut same = true
  while i < tag.length() {
    match tag.get_char(i) {
      Some(c) => if data[offset + i].to_int() != c.to_int() { same = false }
      None => same = false
    }
    i = i + 1
  }
  same
}

///|
/// 解析 OpusHead（RFC 7845 §5.1）。不是 Opus 标识头时返回 `None`。
///
/// 字段布局：
///
///   0..8   "OpusHead"
///   8      版本（本实现只认 1）
///   9      声道数
///   10..12 pre-skip（u16 LE）
///   12..16 输入采样率（u32 LE）
///   16..18 输出增益（i16 LE，Q7.8 dB）
///   18     声道映射族
///
/// **输出采样率恒为 48000**：Opus 解码后固定输出 48 kHz，标识头里的
/// 「输入采样率」只是给源素材留的记录，拿它算时长会得到错误结果。
pub fn parse_opus_head(data : Bytes) -> AudioInfo? {
  if data.length() < 19 {
    return None
  }
  if !tag_at(data, 0, "OpusHead") {
    return None
  }
  let version = data[8].to_int()
  if version != 1 {
    return None
  }
  let channels = data[9].to_int()
  if channels == 0 {
    return None
  }
  let family = data[18].to_int()
  if family == 0 {
    // 映射族 0 只支持单声道 / 立体声（RFC 7845 §5.1.1）
    if channels > 2 {
      return None
    }
  } else {
    // 映射族非 0：必须带 StreamCount / CoupledCount / ChannelMapping(channels)
    if data.length() < 21 + channels {
      return None
    }
    let stream_count = data[19].to_int()
    let coupled_count = data[20].to_int()
    if stream_count == 0 || coupled_count > stream_count {
      return None
    }
  }
  Some({
    codec: "Opus",
    channels,
    sample_rate: 48000,
    pre_skip: rd_u16(data, 10),
  })
}

///|
/// 解析 Vorbis 识别头（Vorbis I §4.2.2）。不是识别头时返回 `None`。
///
/// 字段布局：
///
///   0      包类型 0x01
///   1..7   "vorbis"
///   7..11  版本（u32 LE）
///   11     声道数
///   12..16 采样率（u32 LE）
///   16..28 三个码率（u32 LE）
///   28     块大小
///   29     帧标志
pub fn parse_vorbis_id(data : Bytes) -> AudioInfo? {
  if data.length() < 30 {
    return None
  }
  if data[0].to_int() != 1 {
    return None
  }
  if !tag_at(data, 1, "vorbis") {
    return None
  }
  if rd_u32(data, 7) != 0 {
    return None
  }
  let channels = data[11].to_int()
  let sample_rate = rd_u32(data, 12)
  // u32 读进 32 位有符号 Int：高位为 1 的值（如 0xFFFFFFFF）会变成负数。
  // 采样率 <= 0 的头没有意义，一律拒掉 —— 否则 info 会打出「采样率 -1 Hz」，
  // 时长还会被算成负数。
  if channels == 0 || sample_rate <= 0 {
    return None
  }
  let block_sizes = data[28].to_int()
  let block_0 = block_sizes & 0x0F
  let block_1 = (block_sizes >> 4) & 0x0F
  if block_0 < 6 ||
    block_0 > 13 ||
    block_1 < 6 ||
    block_1 > 13 ||
    block_0 > block_1 {
    return None
  }
  if (data[29].to_int() & 1) == 0 {
    return None
  }
  Some({ codec: "Vorbis", channels, sample_rate, pre_skip: 0, })
}

///|
/// setup 头校验用的有界位读取器（LSB-first，位置用 Int64 记录）。
///
/// 与解码器不同：**任何一次读越过包尾都返回 None**，绝不 `unsafe_get`。
/// 位置用 Int64 而不是 Int32，避免「单包超过 256 MiB 时 `len * 8` 回绕」
/// 把位预算算错（F-PAR-08）。
priv struct SetupBits {
  data : Bytes
  /// 相对包首的位偏移
  mut pos : Int64
}

///|
fn SetupBits::new(data : Bytes) -> SetupBits {
  { data, pos: 0L, }
}

///|
/// 还剩多少位可读。
fn SetupBits::remaining(self : SetupBits) -> Int64 {
  self.data.length().to_int64() * 8L - self.pos
}

///|
/// 读 `n` 位（0 ≤ n ≤ 24）；越过包尾返回 None。
fn SetupBits::read(self : SetupBits, n : Int32) -> Int32? {
  if n < 0 || n > 24 {
    return None
  }
  if self.remaining() < n.to_int64() {
    return None
  }
  let mut v = 0
  let mut i = 0
  while i < n {
    let bit_pos = self.pos + i.to_int64()
    let byte_index = (bit_pos / 8L).to_int()
    let bit_in_byte = (bit_pos % 8L).to_int()
    let bit = (self.data[byte_index].to_int() >> bit_in_byte) & 1
    v = v | (bit << i)
    i = i + 1
  }
  self.pos = self.pos + n.to_int64()
  Some(v)
}

///|
/// 跳过 `n` 位；不够则返回 false 且位置不变。
fn SetupBits::skip(self : SetupBits, n : Int64) -> Bool {
  if n < 0L || self.remaining() < n {
    return false
  }
  self.pos = self.pos + n
  true
}

///|
/// `v > 0` 时返回表示 `v` 所需的位数（floor(log2(v)) + 1）。
fn ilog64(v : Int64) -> Int32 {
  let mut x = v
  let mut n = 0
  while x > 0L {
    n = n + 1
    x = x >> 1
  }
  n
}

///|
/// lookup type 1 的原始值个数：最大的 r 使 r^dimensions <= entries。
///
/// 全程 Int64 计算并在溢出前停止：返回值只用于位预算，不做分配。
fn lookup1_values_checked(entries : Int64, dimensions : Int64) -> Int64? {
  if dimensions <= 0L {
    return None
  }
  // dimensions == 1 时 r 就是 entries 本身；直接返回，避免 O(entries) 循环。
  if dimensions == 1L {
    return Some(entries)
  }
  let mut r : Int64 = 0L
  let mut go = true
  while go {
    let base = r + 1L
    let mut p : Int64 = 1L
    let mut i : Int64 = 0L
    let mut over = false
    while i < dimensions && !over {
      // 先做除法判断，避免 p * base 溢出
      if p > entries / base {
        over = true
      } else {
        p = p * base
        if p > entries {
          over = true
        }
      }
      i = i + 1L
    }
    if over {
      go = false
    } else {
      r = r + 1L
    }
  }
  Some(r)
}

///|
/// 单个 codebook 解析后需要保留的元数据：交叉引用校验、解码内存上界
/// （codebook 构造期的数组分配）与 Huffman 线性查表的 CPU 上界都要用它。
priv struct VorbisCodebook {
  dimensions : Int32
  entries : Int32
  lookup_type : Int32
  /// 有效码字（码长 > 0）数量；moonvorbis 的 Huffman 表只装这些。
  active_entries : Int32
  /// 最长码长（0 表示整本码长全 0）。
  max_code_length : Int32
}

///|
/// codebook 构造期内存上界（字节），对齐 moonvorbis `Codebook::parse` 的实际分配：
///
/// - `lengths`：`entries × 4`；
/// - `compute_codewords` 的临时 `codewords`：`entries × 4`；
/// - Huffman 表的 codewords/lengths/symbols 三个数组：`active × 12`；
/// - lookup 展开 `multiplicands_f`：type1 为 `entries × dims × 4`（RT3-01 的
///   真实放大来源），type2 还把原始 `multiplicands` 也按 `entries × dims × 4`
///   保留，故 type2 合计 `entries × dims × 8`；
/// - 再留 64 B 给零散对象头。
fn VorbisCodebook::alloc_bytes(self : VorbisCodebook) -> Int64 {
  let e = self.entries.to_int64()
  let a = self.active_entries.to_int64()
  let d = self.dimensions.to_int64()
  let table = a * 12L + 64L
  if self.lookup_type == 0 {
    e * 8L + table
  } else if self.lookup_type == 1 {
    e * (4L * d + 8L) + table
  } else {
    e * (8L * d + 8L) + table
  }
}

///|
/// 完整 setup 头的校验结果，供 pipeline 计算解码内存与 CPU 工作量上界。
///
/// 数组字段与 setup 段一一对应（下标即段序号），pipeline 用它们推导
/// 「每包 Huffman 符号数上界」——floor/residue 的每个参数都来自已校验的
/// setup，不会出现「预算按结构猜、解码按另一套参数读」的偏差。
pub(all) struct VorbisSetupInfo {
  channels : Int32
  codebooks : Int32
  floors : Int32
  residues : Int32
  mappings : Int32
  /// 每个 mode 的 blockflag（0 = 短块，1 = 长块）。
  modes : Array[Int32]
  /// 每个 mode 使用的 mapping 下标。
  modes_mapping : Array[Int32]
  /// 每个 floor 每声道解码时读取的 Huffman 符号数上界。
  floor_symbols : Array[Int32]
  /// 每个 residue 的 type / begin / end / partition_size。
  residue_type : Array[Int32]
  residue_begin : Array[Int32]
  residue_end : Array[Int32]
  residue_partition_size : Array[Int32]
  /// 每个 residue 的「每 partition / 每 pass / 每声道最多 VQ 码字数」上界：
  /// `max over 引用的 VQ book of ceil(partition_size / dimensions)`（RT4-01）。
  residue_vq_codewords : Array[Int32]
  /// 每个 mapping 的 submaps 数量、每个 submap 的 floor/residue 下标。
  mappings_submaps : Array[Int32]
  mappings_floor : Array[Array[Int32]]
  mappings_residue : Array[Array[Int32]]
  /// submaps > 1 时每声道的 submap 选择；否则为空数组。
  mappings_mux : Array[Array[Int32]]
  /// 所有 codebook 中最大的「最长码长 × 有效码字数」。
  max_huffman_scan : Int64
  /// setup 解析后解码器为 codebook 分配的内存量上界（字节）。
  decoder_setup_bytes : Int64
}

///|
/// 带错误状态的位扫描器：读失败只记录一次错误、不推进位置。
///
/// setup 头各段的计数字段都很小（≤ 8 位），所有循环都有确定上界，因此
/// 「先继续扫完、最后统一返回 Err」是安全的：既避免每个字段都写一遍
/// `match ... None => return Err`，也不会因为失败位置错乱再读穿内存。
priv struct SetupScan {
  bits : SetupBits
  mut err : String?
}

///|
fn SetupScan::new(data : Bytes) -> SetupScan {
  { bits: SetupBits::new(data), err: None, }
}

///|
fn SetupScan::fail(self : SetupScan, what : String) -> Unit {
  if self.err is None {
    self.err = Some(what)
  }
}

///|
fn SetupScan::failed(self : SetupScan) -> Bool {
  match self.err {
    Some(_) => true
    None => false
  }
}

///|
/// 读 `n` 位；截断时记录错误并返回 0（位置不前进，循环上界保证不会空转）。
fn SetupScan::u(self : SetupScan, n : Int32, what : String) -> Int32 {
  match self.bits.read(n) {
    Some(v) => v
    None => {
      self.fail(what + " 字段处被截断")
      0
    }
  }
}

///|
/// 校验单个 codebook 的声明与它在包内的位预算（F-PAR-01 / F-PAR-02 / RT3-01）。
///
/// 字段语义与 Vorbis 线格式一致：`dimensions` / `entries` 就是 16/24 位
/// 字段的原始值，**不再 +1**。这一点与参考实现 libvorbis 完全一致：
/// `vorbis_staticbook_unpack` 里是 `s->dim=oggpack_read(opb,16)`（无 +1），
/// moonvorbis 的 `Codebook::parse` 同样按 raw 值解析（F-PAR-02 已用其测试
/// 向量与 Python 生成器交叉验证）。
///
/// sparse 码长表**不能**按「1 位/条目」估计位预算（RT-A-01）：解码器实际读
/// 「1 位 used + used 时 5 位码长」，最坏 6 倍。这里逐个条目按解码器的真实
/// 读取量核算（读到包尾即 Err），既不留下 6 倍越界窗口，也不会因为「最坏
/// 情况估计」误伤真实文件里大量 used=0 的稀疏码本。
///
/// 同时统计有效码字数与最长码长，供 `alloc_bytes`（RT3-01 内存）与
/// `max_huffman_scan`（RT3-02 CPU，moonvorbis 的 Huffman 解码是逐 bit
/// 线性扫全表的 O(码长 × 有效码字数)）使用。
fn validate_vorbis_codebook(
  scan : SetupBits,
  index : Int32,
) -> Result[VorbisCodebook, String] {
  let tag = "setup 头第 " + (index + 1).to_string() + " 个 codebook："
  // 每个 codebook 以 24 位同步码 0x564342 开头（Vorbis I §3.2.1）。
  let sync = match scan.read(24) {
    Some(v) => v
    None => return Err(tag + "同步码处被截断")
  }
  if sync != 0x564342 {
    return Err(tag + "同步码不是 0x564342（已拒绝）")
  }
  let dimensions = match scan.read(16) {
    Some(v) => v
    None => return Err(tag + "dimensions 字段处被截断")
  }
  let entries = match scan.read(24) {
    Some(v) => v
    None => return Err(tag + "entries 字段处被截断")
  }
  // 合理 codebook 远小于这两个上限；超过即视为恶意/损坏的构造。
  if dimensions > 4096 {
    return Err(
      tag +
      "dimensions=" +
      dimensions.to_string() +
      " 超出合理范围（已拒绝）",
    )
  }
  if entries > 1048576 {
    return Err(
      tag +
      "entries=" +
      entries.to_string() +
      " 超出合理范围（已拒绝）",
    )
  }
  let entries64 = entries.to_int64()
  let dims64 = dimensions.to_int64()
  let ordered = match scan.read(1) {
    Some(v) => v
    None => return Err(tag + "ordered 标志处被截断")
  }
  let mut active_entries : Int64 = 0L
  let mut max_code_length = 0
  if ordered == 1 {
    // ordered：码长用变长游程编码。每轮至少消耗 1 位，因此位读尽即终止；
    // 码长上限是 32（超长码长在解码器里也无法建表），超过仍在续写即拒绝。
    let mut current_entry : Int64 = 0L
    let mut current_length = match scan.read(5) {
      Some(v) => v + 1
      None => return Err(tag + "ordered 起始码长被截断")
    }
    while current_entry < entries64 {
      let span = entries64 - current_entry
      let n_bits = ilog64(span)
      let n = match scan.read(n_bits) {
        Some(v) => v.to_int64()
        None => return Err(tag + "ordered 码长游程处被截断")
      }
      if n > span {
        return Err(tag + "ordered 码长游程越界（已拒绝）")
      }
      current_entry = current_entry + n
      active_entries = active_entries + n
      if n > 0L && current_length > max_code_length {
        max_code_length = current_length
      }
      current_length = current_length + 1
      if current_length > 32 && current_entry < entries64 {
        return Err(tag + "ordered 码长超过 32 仍未结束（已拒绝）")
      }
    }
  } else {
    let sparse = match scan.read(1) {
      Some(v) => v
      None => return Err(tag + "sparse 标志处被截断")
    }
    if sparse == 1 {
      // sparse：每条目 1 位 used 标志，used=1 时再 5 位码长。位预算必须按
      // 解码器的实际读取量逐条核算（RT-A-01：按 1 位/条估计会漏掉 5 倍）。
      // 读越包尾立即 Err；不做事前「最坏 6 倍」估计，避免误伤真实文件里
      // 大量 used=0 的稀疏码本（最坏情况估计会把它们全部拒绝）。
      let mut i : Int64 = 0L
      while i < entries64 {
        let used = match scan.read(1) {
          Some(v) => v
          None => return Err(tag + "sparse used 标志处被截断")
        }
        if used == 1 {
          let l = match scan.read(5) {
            Some(v) => v + 1
            None => return Err(tag + "sparse 码长处被截断")
          }
          active_entries = active_entries + 1L
          if l > max_code_length {
            max_code_length = l
          }
        }
        i = i + 1L
      }
    } else {
      // 非 sparse：每条目固定 5 位码长。先做整表位预算，再读取并统计。
      let required = entries64 * 5L
      if required > scan.remaining() {
        return Err(
          tag +
          "声明的条目数（" +
          entries.to_string() +
          "）与包内剩余位数不符（已拒绝）",
        )
      }
      let mut i : Int64 = 0L
      while i < entries64 {
        let l = match scan.read(5) {
          Some(v) => v + 1
          None => return Err(tag + "码长表越过包尾（已拒绝）")
        }
        active_entries = active_entries + 1L
        if l > max_code_length {
          max_code_length = l
        }
        i = i + 1L
      }
    }
  }
  let lookup_type = match scan.read(4) {
    Some(v) => v
    None => return Err(tag + "lookup_type 字段处被截断")
  }
  if lookup_type != 0 {
    if lookup_type != 1 && lookup_type != 2 {
      return Err(
        tag +
        "lookup_type=" +
        lookup_type.to_string() +
        " 非法（已拒绝）",
      )
    }
    // min_value / delta_value 各 32 位，只做位预算、不解释内容。
    if !scan.skip(32L) {
      return Err(tag + "lookup 的 min_value 字段被截断")
    }
    if !scan.skip(32L) {
      return Err(tag + "lookup 的 delta_value 字段被截断")
    }
    let value_bits = match scan.read(4) {
      Some(v) => v + 1
      None => return Err(tag + "lookup 的 value_bits 字段被截断")
    }
    let _sequence = match scan.read(1) {
      Some(v) => v
      None => return Err(tag + "lookup 的 sequence 标志被截断")
    }
    // 原始 lookup 值数量：type 1 是 r（r^dims <= entries），type 2 是 entries*dims。
    // 解码器按这个数量读位；这里算清位预算与元素数上限，不够/过大就拒绝（RT-A-03）。
    let raw = if lookup_type == 1 {
      // 解码器用 Int32 幂算 r：维度大时自身会溢出/空转；只放行小维度。
      if dims64 <= 0L || dims64 > 16L {
        return Err(
          tag +
          "lookup type 1 的 dimensions=" +
          dimensions.to_string() +
          " 超出合理范围（已拒绝）",
        )
      }
      match lookup1_values_checked(entries64, dims64) {
        Some(v) => v
        None => return Err(tag + "lookup type 1 参数非法（已拒绝）")
      }
    } else {
      // type 2：解码器按 Int32 计算 entries*dimensions；乘积溢出会变成负数，
      // 随后按负长度分配/读取。先限制元素数，再限制其必须装进 Int32。
      let raw = entries64 * dims64
      if raw > 16777216L || raw > 2147483647L {
        return Err(
          tag +
          "lookup type 2 的元素数 " +
          raw.to_string() +
          " 超出合理范围（已拒绝）",
        )
      }
      raw
    }
    let budget = raw * value_bits.to_int64()
    if budget > scan.remaining() {
      return Err(
        tag +
        "lookup 表需要 " +
        budget.to_string() +
        " 位，超过包内剩余 " +
        scan.remaining().to_string() +
        " 位（疑似恶意构造，已拒绝）",
      )
    }
    if !scan.skip(budget) {
      return Err(tag + "lookup 表越过包尾（已拒绝）")
    }
  }
  if active_entries > 2147483647L {
    return Err(tag + "有效码字数超出可表示范围（已拒绝）")
  }
  Ok({
    dimensions,
    entries,
    lookup_type,
    active_entries: active_entries.to_int(),
    max_code_length,
  })
}

///|
/// 校验 setup 头的 floor 段：floor0 的 book 引用、floor1 的 master/subclass
/// book 引用都必须落在已有 codebook 范围内；同时把「每声道解码该 floor
/// 所需的 Huffman 符号数上界」写入 `out_symbols`（供 CPU 预算使用）。
///
/// floor1 的 master/subclass book 只用于 `decode_scalar`（Huffman 标量），
/// 因此 `dimensions=0` 在这里是合法的（对应 RT3-04：dimensions 线格式是
/// raw 值、没有 +1，classbook/masterbook 这类标量书不要求维度 > 0）。
fn validate_vorbis_floor(
  scan : SetupScan,
  codebooks : Array[VorbisCodebook],
  index : Int32,
  out_symbols : Array[Int32],
) -> Unit {
  let tag = "setup 头第 " + (index + 1).to_string() + " 个 floor："
  let floor_type = scan.u(16, tag + "类型字段")
  let codebook_count = codebooks.length()
  if floor_type == 0 {
    // floor0：order/rate/bark 不能为 0；引用的 book 必须有 lookup 表且维度 > 0
    // （floor0 用 decode_vq_set 取 LSP 系数，dimensions=0 会让内层循环不前进）。
    let order = scan.u(8, tag + "order")
    let rate = scan.u(16, tag + "rate")
    let bark_map_size = scan.u(16, tag + "bark_map_size")
    let _amplitude_bits = scan.u(6, tag + "amplitude_bits")
    let _amplitude_offset = scan.u(8, tag + "amplitude_offset")
    let book_count = scan.u(4, tag + "book 计数") + 1
    if order < 1 {
      scan.fail(tag + "order 为 0（已拒绝）")
    }
    if rate < 1 {
      scan.fail(tag + "rate 为 0（已拒绝）")
    }
    if bark_map_size < 1 {
      scan.fail(tag + "bark_map_size 为 0（已拒绝）")
    }
    let mut b = 0
    while b < book_count && !scan.failed() {
      let book = scan.u(8, tag + "book 索引")
      if book >= codebook_count {
        scan.fail(
          tag +
          "book 索引 " +
          book.to_string() +
          " 超出 codebook 数量 " +
          codebook_count.to_string() +
          "（已拒绝）",
        )
      } else if codebooks[book].lookup_type == 0 {
        scan.fail(tag + "引用的 book 没有 lookup 表（已拒绝）")
      } else if codebooks[book].dimensions < 1 {
        scan.fail(
          tag +
          "引用的 book dimensions 为 0（VQ 解码需要维度 > 0，已拒绝）",
        )
      }
      b = b + 1
    }
    // 幅度/标志 2 次 + 每个 entry 至少 1 个 Huffman 符号（order 个系数按维度分组）
    out_symbols.push(order + 2)
  } else if floor_type == 1 {
    // floor1：partition class → masterbook / subclass books 都是标量 Huffman 书。
    let partitions = scan.u(5, tag + "partitions")
    let class_list : Array[Int32] = []
    let mut max_class = -1
    let mut p = 0
    while p < partitions && !scan.failed() {
      let c = scan.u(4, tag + "partition class")
      class_list.push(c)
      if c > max_class {
        max_class = c
      }
      p = p + 1
    }
    let class_dimensions : Array[Int32] = []
    let mut c = 0
    while c <= max_class && !scan.failed() {
      class_dimensions.push(scan.u(3, tag + "class dimensions") + 1)
      let subclasses = scan.u(2, tag + "class subclasses")
      if subclasses != 0 {
        let masterbook = scan.u(8, tag + "class masterbook")
        if masterbook >= codebook_count {
          scan.fail(
            tag +
            "class masterbook 索引 " +
            masterbook.to_string() +
            " 超出 codebook 数量 " +
            codebook_count.to_string() +
            "（已拒绝）",
          )
        }
      }
      let book_slots = 1 << subclasses
      let mut k = 0
      while k < book_slots && !scan.failed() {
        // 线格式里存的是「book + 1」，0 表示该位置不使用 codebook。
        let book = scan.u(8, tag + "subclass book") - 1
        if book >= 0 && book >= codebook_count {
          scan.fail(
            tag +
            "subclass book 索引 " +
            book.to_string() +
            " 超出 codebook 数量 " +
            codebook_count.to_string() +
            "（已拒绝）",
          )
        }
        k = k + 1
      }
      c = c + 1
    }
    let _multiplier = scan.u(2, tag + "multiplier") + 1
    let rangebits = scan.u(4, tag + "rangebits")
    // x 值只用于解码期插值，数量由 partitions × class dimensions 决定；
    // gate 只按位预算跳过，不解释取值。
    let mut x_total = 0
    for cls in class_list {
      if cls >= 0 && cls < class_dimensions.length() {
        x_total = x_total + class_dimensions[cls]
      }
    }
    let mut x = 0
    while x < x_total && !scan.failed() {
      let _ = scan.u(rangebits, tag + "x 值")
      x = x + 1
    }
    // 2 个幅度符号 + 每个 partition 的 masterbook 符号 + 每个分量的 VQ/标量符号。
    out_symbols.push(2 + partitions + x_total)
  } else {
    scan.fail(
      tag +
      "类型 " +
      floor_type.to_string() +
      " 不支持（只接受 floor0 / floor1，已拒绝）",
    )
    out_symbols.push(0)
  }
}

///|
/// 校验 setup 头的 residue 段：classbook 与 residue_books 都是解码器的直接
/// 数组下标；residue book 还会走 VQ 解码（decode_vq/decode_vq_step），
/// dimensions=0 会让 rtype0 的 `part_size / dimensions` 除零、rtype2 的
/// `k += dimensions` 死循环，因此 VQ book 必须 dimensions > 0。
///
/// classbook 只用 `decode_scalar`（Huffman 标量），不读 dimensions，因此
/// classbook 的 dimensions=0 是合法的（RT3-04：dimensions 线格式为 raw 值，
/// 无 +1；参考 libvorbis `codebook.c` 的 `s->dim=oggpack_read(opb,16)`）。
fn validate_vorbis_residue(
  scan : SetupScan,
  codebooks : Array[VorbisCodebook],
  index : Int32,
  out_type : Array[Int32],
  out_begin : Array[Int32],
  out_end : Array[Int32],
  out_partition_size : Array[Int32],
  out_vq_codewords : Array[Int32],
) -> Unit {
  let tag = "setup 头第 " + (index + 1).to_string() + " 个 residue："
  let codebook_count = codebooks.length()
  let residue_type = scan.u(16, tag + "类型字段")
  if residue_type > 2 {
    scan.fail(tag + "类型不支持（只接受 0/1/2，已拒绝）")
  }
  let begin = scan.u(24, tag + "begin")
  let end = scan.u(24, tag + "end")
  let partition_size = scan.u(24, tag + "partition_size") + 1
  let classifications = scan.u(6, tag + "classifications") + 1
  let classbook = scan.u(8, tag + "classbook")
  if classbook >= codebook_count {
    scan.fail(
      tag +
      "classbook 索引 " +
      classbook.to_string() +
      " 超出 codebook 数量 " +
      codebook_count.to_string() +
      "（已拒绝）",
    )
  } else if codebooks[classbook].entries <= 0 {
    scan.fail(
      tag + "classbook 的 entries 为 0（无法解码分类，已拒绝）",
    )
  }
  // cascade：每个 classification 先 3 位低段 + 1 位标志（+5 位高段），
  // 后续对每个置位的 pass 读一个 8 位 residue book 索引。
  let cascades : Array[Int32] = []
  let mut j = 0
  while j < classifications && !scan.failed() {
    let low = scan.u(3, tag + "cascade 低段")
    let flag = scan.u(1, tag + "cascade 标志")
    let high = if flag == 1 { scan.u(5, tag + "cascade 高段") } else { 0 }
    cascades.push(high * 8 + low)
    j = j + 1
  }
  let mut vq_codewords = 0
  let mut j2 = 0
  while j2 < cascades.length() && !scan.failed() {
    let mut k = 0
    while k < 8 && !scan.failed() {
      if (cascades[j2] & (1 << k)) != 0 {
        let book = scan.u(8, tag + "residue book 索引")
        if book >= codebook_count {
          scan.fail(
            tag +
            "residue book 索引 " +
            book.to_string() +
            " 超出 codebook 数量 " +
            codebook_count.to_string() +
            "（已拒绝）",
          )
        } else if codebooks[book].dimensions <= 0 {
          scan.fail(
            tag +
            "residue book 的 dimensions 为 0（VQ 解码需要维度 > 0，已拒绝）",
          )
        } else {
          // RT4-01：解码器每个 partition 的 VQ 码字数 = ceil(ps / dims)，
          // 取该 residue 所有引用书的组合上界（每个符号落在哪本书取决于码流，
          // 用最大值才是严格上界）。
          let dims = codebooks[book].dimensions
          let cw = (partition_size + dims - 1) / dims
          if cw > vq_codewords {
            vq_codewords = cw
          }
        }
      }
      k = k + 1
    }
    j2 = j2 + 1
  }
  out_type.push(residue_type)
  out_begin.push(begin)
  out_end.push(end)
  out_partition_size.push(partition_size)
  out_vq_codewords.push(vq_codewords)
}

///|
/// 校验 setup 头的 mapping 段：coupling 声道号、mux、以及 floor/residue/
/// time_config 三个跨段下标都必须是解码器的合法数组下标（RT-A-02）。
/// 同时把 submaps、每个 submap 的 floor/residue 下标与每声道 mux 写入输出数组，
/// 供 pipeline 推导每包 Huffman 符号数上界。
fn validate_vorbis_mapping(
  scan : SetupScan,
  channels : Int32,
  floor_count : Int32,
  residue_count : Int32,
  time_count : Int32,
  index : Int32,
  out_submaps : Array[Int32],
  out_floor : Array[Array[Int32]],
  out_residue : Array[Array[Int32]],
  out_mux : Array[Array[Int32]],
) -> Unit {
  let tag = "setup 头第 " + (index + 1).to_string() + " 个 mapping："
  let mapping_type = scan.u(16, tag + "类型字段")
  if mapping_type != 0 {
    scan.fail(tag + "类型不是 0（Vorbis I 只定义 0，已拒绝）")
  }
  let submaps = if scan.u(1, tag + "submaps 标志") == 1 {
    scan.u(4, tag + "submaps 计数") + 1
  } else {
    1
  }
  let coupling_flag = scan.u(1, tag + "coupling 标志")
  if coupling_flag == 1 {
    if channels < 2 {
      scan.fail(
        tag +
        "有 coupling 但声道数 " +
        channels.to_string() +
        " < 2（无法校验声道下标，已拒绝）",
      )
    } else {
      let coupling_steps = scan.u(8, tag + "coupling steps") + 1
      let step_bits = ilog64((channels - 1).to_int64())
      let mut s = 0
      while s < coupling_steps && !scan.failed() {
        let magnitude = scan.u(step_bits, tag + "coupling magnitude")
        let angle = scan.u(step_bits, tag + "coupling angle")
        if magnitude == angle {
          scan.fail(tag + "coupling magnitude 等于 angle（已拒绝）")
        } else if magnitude >= channels || angle >= channels {
          scan.fail(
            tag +
            "coupling 声道号超出声道数 " +
            channels.to_string() +
            "（已拒绝）",
          )
        }
        s = s + 1
      }
    }
  }
  let reserved = scan.u(2, tag + "reserved")
  if reserved != 0 {
    scan.fail(tag + "reserved 字段不为 0（已拒绝）")
  }
  let mux : Array[Int32] = []
  if submaps > 1 {
    let mut ch = 0
    while ch < channels && !scan.failed() {
      let m = scan.u(4, tag + "mux")
      if m >= submaps {
        scan.fail(
          tag +
          "mux=" +
          m.to_string() +
          " 超过 submaps=" +
          submaps.to_string() +
          "（已拒绝）",
        )
      }
      mux.push(m)
      ch = ch + 1
    }
  }
  let floors : Array[Int32] = []
  let residues : Array[Int32] = []
  let mut s2 = 0
  while s2 < submaps && !scan.failed() {
    let time_config = scan.u(8, tag + "time_config 索引")
    let floor = scan.u(8, tag + "floor 索引")
    let residue = scan.u(8, tag + "residue 索引")
    if time_config >= time_count {
      scan.fail(
        tag +
        "time_config 索引 " +
        time_config.to_string() +
        " 超出时间变换数量 " +
        time_count.to_string() +
        "（已拒绝）",
      )
    }
    if floor >= floor_count {
      scan.fail(
        tag +
        "floor 索引 " +
        floor.to_string() +
        " 超出 floor 数量 " +
        floor_count.to_string() +
        "（已拒绝）",
      )
    }
    if residue >= residue_count {
      scan.fail(
        tag +
        "residue 索引 " +
        residue.to_string() +
        " 超出 residue 数量 " +
        residue_count.to_string() +
        "（已拒绝）",
      )
    }
    floors.push(floor)
    residues.push(residue)
    s2 = s2 + 1
  }
  out_submaps.push(submaps)
  out_floor.push(floors)
  out_residue.push(residues)
  out_mux.push(mux)
}

///|
/// 校验 setup 头的 mode 段：window/transform 必须为 0，mapping 下标必须
/// 落在已有 mapping 范围内（解码器 `mappings[mode.mapping]` 会越界）。
fn validate_vorbis_modes(
  scan : SetupScan,
  mapping_count : Int32,
  tag_prefix : String,
  out_blockflags : Array[Int32],
  out_mapping : Array[Int32],
) -> Unit {
  let mode_count = scan.u(6, "setup 头 mode 计数") + 1
  let mut m = 0
  while m < mode_count && !scan.failed() {
    let tag = tag_prefix + (m + 1).to_string() + " 个 mode："
    let blockflag = scan.u(1, tag + "blockflag")
    let windowtype = scan.u(16, tag + "windowtype")
    let transformtype = scan.u(16, tag + "transformtype")
    let mapping = scan.u(8, tag + "mapping 索引")
    if windowtype != 0 || transformtype != 0 {
      scan.fail(
        tag + "windowtype/transformtype 不是 0（Vorbis I 只支持 0）",
      )
    }
    if mapping >= mapping_count {
      scan.fail(
        tag +
        "mapping 索引 " +
        mapping.to_string() +
        " 超出 mapping 数量 " +
        mapping_count.to_string() +
        "（已拒绝）",
      )
    }
    out_blockflags.push(blockflag)
    out_mapping.push(mapping)
    m = m + 1
  }
}

///|
/// Vorbis setup 头的**完整有界校验**（gate v3）：codebook 段 + floor /
/// residue / mapping / mode 段 + 跨段交叉引用 + framing 位，并把解码器的
/// **内存分配上界**与 **Huffman CPU 上界**所需参数一并返回。
///
/// 从第 2 轮（gate v2）到 v3 的变化：
/// - RT3-01：codebook 内存不再只记 lookup 原始值，而是按 moonvorbis
///   `Codebook::parse` 的真实分配计上界（type1 的 `entries×dimensions` Float
///   展开、type2 的双份展开、lengths/codewords/Huffman 表）；
/// - RT3-02：返回 `max_huffman_scan`（最长码长 × 有效码字数）与 floor/residue
///   结构参数，供 pipeline 计算「每包符号数上界 × 单符号线性扫描成本」；
/// - RT3-04：裁决 dimensions 的线格式——raw 值、无 +1（libvorbis 与
///   moonvorbis 一致）；classbook/masterbook 这类标量书允许 dimensions=0，
///   仅 VQ 书（floor0 / residue book）要求 dimensions>0。
pub fn parse_vorbis_setup_info(
  packet : Bytes,
  channels : Int32,
) -> Result[VorbisSetupInfo, String] {
  if channels < 1 || channels > 255 {
    return Err(
      "声道数 " + channels.to_string() + " 超出 Vorbis 允许范围 1..255",
    )
  }
  if packet.length() < 8 {
    return Err(
      "setup 包过短（" + packet.length().to_string() + " 字节）",
    )
  }
  if packet[0].to_int() != 0x05 || !tag_at(packet, 1, "vorbis") {
    return Err("不是 Vorbis setup 头（缺少 0x05 + \"vorbis\" 标记）")
  }
  let scan = SetupScan::new(packet)
  // setup 数据从包偏移 7 开始，按 LSB-first 位流解析。
  if !scan.bits.skip(56L) {
    return Err("setup 头缺少 0x05 + \"vorbis\" 前缀")
  }
  let codebook_count = scan.u(8, "setup 头 codebook 计数") + 1
  let codebooks : Array[VorbisCodebook] = []
  let mut i = 0
  while i < codebook_count {
    match validate_vorbis_codebook(scan.bits, i) {
      Err(msg) => return Err(msg)
      Ok(v) => codebooks.push(v)
    }
    i = i + 1
  }
  // 时间域变换（Vorbis I 只定义类型 0）。
  let time_count = scan.u(6, "setup 头时间变换计数") + 1
  let mut t = 0
  while t < time_count && !scan.failed() {
    let kind = scan.u(16, "时间变换类型")
    if kind != 0 {
      scan.fail(
        "时间变换类型不是 0（Vorbis I 只定义 0，已拒绝）",
      )
    }
    t = t + 1
  }
  let floor_count = scan.u(6, "setup 头 floor 计数") + 1
  let floor_symbols : Array[Int32] = []
  let mut fi = 0
  while fi < floor_count && !scan.failed() {
    validate_vorbis_floor(scan, codebooks, fi, floor_symbols)
    fi = fi + 1
  }
  let residue_count = scan.u(6, "setup 头 residue 计数") + 1
  let residue_type : Array[Int32] = []
  let residue_begin : Array[Int32] = []
  let residue_end : Array[Int32] = []
  let residue_partition_size : Array[Int32] = []
  let residue_vq_codewords : Array[Int32] = []
  let mut ri = 0
  while ri < residue_count && !scan.failed() {
    validate_vorbis_residue(
      scan, codebooks, ri, residue_type, residue_begin, residue_end, residue_partition_size,
      residue_vq_codewords,
    )
    ri = ri + 1
  }
  let mapping_count = scan.u(6, "setup 头 mapping 计数") + 1
  let mappings_submaps : Array[Int32] = []
  let mappings_floor : Array[Array[Int32]] = []
  let mappings_residue : Array[Array[Int32]] = []
  let mappings_mux : Array[Array[Int32]] = []
  let mut mi = 0
  while mi < mapping_count && !scan.failed() {
    validate_vorbis_mapping(
      scan, channels, floor_count, residue_count, time_count, mi, mappings_submaps,
      mappings_floor, mappings_residue, mappings_mux,
    )
    mi = mi + 1
  }
  let modes : Array[Int32] = []
  let modes_mapping : Array[Int32] = []
  validate_vorbis_modes(
    scan, mapping_count, "setup 头第 ", modes, modes_mapping,
  )
  // framing 位必须是 1；其后最多 7 位（字节对齐补位），再多说明有多余数据。
  let framing = scan.u(1, "setup 头 framing 位")
  if framing != 1 {
    scan.fail("setup 头缺少 framing 位（Vorbis I §4.2.4，已拒绝）")
  }
  if !scan.failed() {
    let rest = scan.bits.remaining()
    if rest < 0L || rest > 7L {
      scan.fail(
        "setup 头 framing 位之后还有 " +
        rest.to_string() +
        " 位多余数据（已拒绝）",
      )
    }
  }
  let mut max_huffman_scan : Int64 = 0L
  let mut decoder_setup_bytes : Int64 = 0L
  for cb in codebooks {
    let scan_cost = cb.max_code_length.to_int64() * cb.active_entries.to_int64()
    if scan_cost > max_huffman_scan {
      max_huffman_scan = scan_cost
    }
    decoder_setup_bytes = decoder_setup_bytes + cb.alloc_bytes()
  }
  match scan.err {
    Some(msg) => Err(msg)
    None =>
      Ok({
        channels,
        codebooks: codebook_count,
        floors: floor_count,
        residues: residue_count,
        mappings: mapping_count,
        modes,
        modes_mapping,
        floor_symbols,
        residue_type,
        residue_begin,
        residue_end,
        residue_partition_size,
        residue_vq_codewords,
        mappings_submaps,
        mappings_floor,
        mappings_residue,
        mappings_mux,
        max_huffman_scan,
        decoder_setup_bytes,
      })
  }
}

///|
/// 一个音频包（block_size = `n`，半块 `n2 = n/2`）最多要做的 Huffman
/// 线性查表比较次数上界（RT3-02 / RT4-01）。
///
/// 单符号成本上界 = `max_huffman_scan`（最长码长 × 有效码字数：
/// `HuffmanTable::decode` 逐 bit 扫描全表）。符号数上界来自已校验的 setup
/// 段与 moonvorbis 解码路径：
/// - floor：每声道每包解一次，floor0 约 `order + 2` 个符号、floor1 约
///   `2 + partitions + Σ class_dimensions` 个；
/// - residue：每个 submap 有 `part_read` 个 partition；每声道每 pass 每
///   partition 的符号数上界是 `1 + 8 × vq_codewords`：1 个 classbook 标量
///   符号 + 8 个 pass 各 `ceil(partition_size / VQ dimensions)` 个 VQ 码字。
///   **RT4-01**：旧实现漏乘了 VQ 码字数（g9 PoC 的 8 pass × 4096/16 被当成
///   8×1），6.5 KB 输入即可在预算内跑数分钟；这里按 VQ 书 dimensions 严格
///   取上限（`residue_vq_codewords` 已由 gate 按引用书计算）。
/// - type2 多声道时 actual = 2×n2（解码器按交错双倍长度读取）。
///
/// 返回值是「查表比较次数」上界；pipeline 把 IMDCT 的 cos 成本与它分别
/// 设预算（两者单位不同，不能简单相加成一个系数）。
pub fn VorbisSetupInfo::huffman_work_upper(
  self : VorbisSetupInfo,
  n2 : Int32,
  mode_index : Int32,
) -> Int64 {
  if n2 < 0 || mode_index < 0 || mode_index >= self.modes_mapping.length() {
    return 0L
  }
  let map_index = self.modes_mapping[mode_index]
  if map_index < 0 || map_index >= self.mappings_submaps.length() {
    return 0L
  }
  let submaps = self.mappings_submaps[map_index]
  let floors = self.mappings_floor[map_index]
  let residues = self.mappings_residue[map_index]
  let mux = if map_index < self.mappings_mux.length() {
    self.mappings_mux[map_index]
  } else {
    []
  }
  let mut symbols : Int64 = 0L
  let mut s = 0
  while s < submaps {
    // 该 submap 覆盖多少声道（submaps==1 时就是全部声道）。
    let mut ch_s = 0
    let mut c = 0
    while c < self.channels {
      let use_s = if submaps > 1 && c < mux.length() {
        mux[c] == s
      } else {
        true
      }
      if use_s {
        ch_s = ch_s + 1
      }
      c = c + 1
    }
    let floor_idx = if s < floors.length() { floors[s] } else { 0 }
    let floor_sym = if floor_idx >= 0 && floor_idx < self.floor_symbols.length() {
      self.floor_symbols[floor_idx]
    } else {
      0
    }
    symbols = symbols + ch_s.to_int64() * floor_sym.to_int64()
    let ridx = if s < residues.length() { residues[s] } else { 0 }
    let rtype = if ridx >= 0 && ridx < self.residue_type.length() {
      self.residue_type[ridx]
    } else {
      0
    }
    let begin = if ridx >= 0 && ridx < self.residue_begin.length() {
      self.residue_begin[ridx]
    } else {
      0
    }
    let end = if ridx >= 0 && ridx < self.residue_end.length() {
      self.residue_end[ridx]
    } else {
      0
    }
    let ps = if ridx >= 0 && ridx < self.residue_partition_size.length() {
      self.residue_partition_size[ridx]
    } else {
      1
    }
    let vq_cw = if ridx >= 0 && ridx < self.residue_vq_codewords.length() {
      self.residue_vq_codewords[ridx]
    } else {
      0
    }
    let factor = if rtype == 2 && ch_s > 1 { 2 } else { 1 }
    let actual = n2 * factor
    let lb = if begin < actual { begin } else { actual }
    let le = if end < actual { end } else { actual }
    let mut nr = le - lb
    if nr < 0 {
      nr = 0
    }
    let part = if ps > 0 { nr / ps } else { 0 }
    symbols = symbols +
      ch_s.to_int64() * part.to_int64() * (1L + 8L * vq_cw.to_int64())
    s = s + 1
  }
  // 单符号成本 × 符号数；溢出饱和到 Int64 上限，让 CPU 预算必然拒绝。
  if self.max_huffman_scan > 0L &&
    symbols > 9223372036854775807L / self.max_huffman_scan {
    return 9223372036854775807L
  }
  symbols * self.max_huffman_scan
}

///|
/// 兼容用的旧入口：只校验 setup 头的 codebook 段（第 1 轮 gate 语义）。
///
/// 保留它是为了不破坏已发布的公开 API 与既有调用方（含黑盒测试）；它仍然
/// 逐位有界读取、不会越界，但**不覆盖** floor/residue/mapping/mode 段和
/// codebook 之间的交叉引用。安全路径（pipeline 解码前 gate）必须使用
/// `parse_vorbis_setup_info`。
pub fn validate_vorbis_setup(packet : Bytes) -> Result[Unit, String] {
  if packet.length() < 8 {
    return Err(
      "setup 包过短（" + packet.length().to_string() + " 字节）",
    )
  }
  if packet[0].to_int() != 0x05 || !tag_at(packet, 1, "vorbis") {
    return Err("不是 Vorbis setup 头（缺少 0x05 + \"vorbis\" 标记）")
  }
  let scan = SetupBits::new(packet)
  if !scan.skip(56L) {
    return Err("setup 头缺少 0x05 + \"vorbis\" 前缀")
  }
  let count = match scan.read(8) {
    Some(v) => v + 1
    None => return Err("setup 头缺少 codebook 计数")
  }
  // count ∈ 1..256，循环有界。
  let mut i = 0
  while i < count {
    match validate_vorbis_codebook(scan, i) {
      Err(msg) => return Err(msg)
      Ok(_) => ()
    }
    i = i + 1
  }
  Ok(())
}

///|
/// 从 Vorbis 识别头取两个 block size（短块 / 长块，单位为样本）。
///
/// pipeline 用它和 setup 的 mode blockflag 相乘，推导每个音频包的解码
/// 工作量（IMDCT 是 O(n²)）与输出样本上界。字段布局与 `parse_vorbis_id`
/// 完全一致，非法头返回 `None`。
pub fn vorbis_block_sizes(id_packet : Bytes) -> (Int32, Int32)? {
  if id_packet.length() < 30 {
    return None
  }
  if id_packet[0].to_int() != 1 || !tag_at(id_packet, 1, "vorbis") {
    return None
  }
  let block_sizes = id_packet[28].to_int()
  let block_0 = block_sizes & 0x0F
  let block_1 = (block_sizes >> 4) & 0x0F
  if block_0 < 6 ||
    block_0 > 13 ||
    block_1 < 6 ||
    block_1 > 13 ||
    block_0 > block_1 {
    return None
  }
  Some((1 << block_0, 1 << block_1))
}

///|
/// 依次尝试各编解码的标识头。
pub fn parse_audio_header(data : Bytes) -> AudioInfo? {
  match parse_opus_head(data) {
    Some(info) => Some(info)
    None => parse_vorbis_id(data)
  }
}

///|
/// 由首末粒度位置算时长（秒）。
///
/// 公式里三个减项缺一不可：
///
/// - **减首粒度**：被裁剪过、或从直播中途接入的流，首个音频页的粒度不为 0
///   （RFC 7845 §4.5 明确允许），不减就把开头偏移算进了时长。
/// - **减 pre-skip**：编码器补的前导样本不属于内容。
/// - `last < first` 时返回 0 而不是负数：损坏文件里该情形会出现，
///   报负数时长只会让调用方更困惑。
///
/// 注意这里用的是**最后一个携带真粒度的页**的值。末页可能是 End-trim
/// （编码器把结尾的补零裁掉，granule 小于实际解出的样本数），那个值才是
/// 权威时长；`-1` 的页表示该页没有包结束，不携带时间信息，必须跳过。
///
/// **能力边界**：容器层只有「首末粒度」，拿不到「首个音频页里究竟有多少样本」。
/// 对从头开始的普通流，首粒度是 0，公式精确；对裁剪过、或从直播中途接入的流
/// （首个音频页 granule 远大于本页样本数），这里算出的值**包含起始偏移**，
/// 是一个上界。要得到精确内容时长必须解码后按样本数回推（RFC 7845 §4.5），
/// 那属于解码层的事 —— 本项目不承诺这一项。
pub fn duration_seconds(
  info : AudioInfo,
  first_granule : Int64,
  last_granule : Int64,
) -> Double {
  if last_granule <= first_granule {
    return 0.0
  }
  let span = last_granule - first_granule - info.pre_skip.to_int64()
  if span <= 0L {
    return 0.0
  }
  span.to_double() / info.sample_rate.to_double()
}
