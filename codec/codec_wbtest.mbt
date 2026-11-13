// codec_wbtest.mbt —— 编解码头解析的测试

///|
/// 一个 OpusHead：2 声道、pre-skip 312、输入采样率 48000、增益 0、映射族 0。
///
/// 字节布局（RFC 7845 §5.1）："OpusHead" | ver=1 | ch=2 | pre-skip(312)
/// | input_rate(48000) | gain(0) | mapping(0)
let opus_head_2ch : Bytes = b"OpusHead\x01\x02\x38\x01\x80\xBB\x00\x00\x00\x00\x00"

///|
/// 一个 Vorbis 识别头：2 声道、采样率 44100。
///
/// 0x01 | "vorbis" | 版本 0 | ch=2 | rate=44100 | 三个码率(0) | 块大小 | 帧标志
let vorbis_id_2ch : Bytes = b"\x01vorbis\x00\x00\x00\x00\x02\x44\xAC\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xB8\x01"

///|
/// OpusHead 的各字段应被正确读出。
test "parse opus head" {
  match parse_opus_head(opus_head_2ch) {
    Some(info) => {
      assert_eq(info.codec, "Opus")
      assert_eq(info.channels, 2)
      assert_eq(info.pre_skip, 312)
      // 输出采样率恒为 48 kHz，与头里的输入采样率无关
      assert_eq(info.sample_rate, 48000)
    }
    None => assert_true(false)
  }
}

///|
/// Vorbis 识别头同理。
test "parse vorbis id" {
  match parse_vorbis_id(vorbis_id_2ch) {
    Some(info) => {
      assert_eq(info.codec, "Vorbis")
      assert_eq(info.channels, 2)
      assert_eq(info.sample_rate, 44100)
      // Vorbis 没有 pre-skip 的概念
      assert_eq(info.pre_skip, 0)
    }
    None => assert_true(false)
  }
}

///|
/// 两种头互不误认 —— 它们都以「自己的魔数」开头，判据是包内容而非长度。
test "headers do not cross-match" {
  match parse_opus_head(vorbis_id_2ch) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
  match parse_vorbis_id(opus_head_2ch) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
}

///|
/// 截断的、或魔数不符的数据一律拒绝，而不是读出垃圾字段。
test "reject truncated and foreign headers" {
  match parse_opus_head(b"OpusHead\x01\x02\x38") {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
  match parse_vorbis_id(b"\x01vorbi") {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
  match parse_audio_header(b"not an audio header at all........") {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
}

///|
/// 采样率字段高位被置 1（如 0xFFFFFFFF）时读成有符号 Int 是负数，
/// 这种头必须拒绝 —— 否则 info 会打出「采样率 -1 Hz」、时长被算成负值。
test "reject vorbis id with absurd sample rate" {
  let absurd : Bytes = b"\x01vorbis\x00\x00\x00\x00\x02\xFF\xFF\xFF\xFF\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xB8\x01"
  match parse_vorbis_id(absurd) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
}

///|
/// 复制 Vorbis 识别头并替换一个字节。
fn vorbis_with(index : Int32, value : Int32) -> Bytes {
  let buf = Buffer()
  let mut i = 0
  while i < vorbis_id_2ch.length() {
    if i == index {
      buf.write_byte(value.to_byte())
    } else {
      buf.write_byte(vorbis_id_2ch[i])
    }
    i = i + 1
  }
  buf.to_bytes()
}

///|
/// Vorbis 识别头的版本、块大小与 framing 标志都是可判定的硬约束。
test "reject vorbis id with invalid required fields" {
  // version 必须为 0（偏移 7..10）
  match parse_vorbis_id(vorbis_with(7, 1)) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
  // blocksize_0 必须 >= 6：这里把低四位改成 0
  match parse_vorbis_id(vorbis_with(28, 0)) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
  // 两个块大小颠倒（8 > 6）同样不合法
  match parse_vorbis_id(vorbis_with(28, 0x68)) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
  // framing 标志必须置位
  match parse_vorbis_id(vorbis_with(29, 0)) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
}

///|
/// 版本号不为 1 的 OpusHead 应当拒绝：字段布局只对版本 1 有保证，
/// 硬着头皮读下去只会得到错误参数。
test "reject opus head with unknown version" {
  let v2 : Bytes = b"OpusHead\x02\x02\x38\x01\x80\xBB\x00\x00\x00\x00\x00"
  match parse_opus_head(v2) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
}

///|
/// 时长公式必须同时减掉首粒度与 pre-skip。
///
/// 用真实样本的数字：末粒度 288312、首粒度 0、pre-skip 312、48 kHz
/// → (288312 - 0 - 312) / 48000 = 6.000 秒。
test "duration subtracts pre-skip" {
  let info : AudioInfo = {
    codec: "Opus",
    channels: 2,
    sample_rate: 48000,
    pre_skip: 312,
  }
  let d = duration_seconds(info, 0L, 288312L)
  assert_true(d > 5.99 && d < 6.01)
}

///|
/// 首粒度不为 0 时必须减掉它 —— 被裁剪或中途接入的流会这样，
/// 不减就把开头偏移算进时长。
test "duration subtracts the first granule" {
  let info : AudioInfo = {
    codec: "Opus",
    channels: 2,
    sample_rate: 48000,
    pre_skip: 312,
  }
  // 首粒度 48000 = 已跳过 1 秒；末 144312 → 再走 2 秒
  let d = duration_seconds(info, 48000L, 144312L)
  assert_true(d > 1.99 && d < 2.01)
}

///|
/// 末粒度不大于首粒度时返回 0，不返回负数 —— 损坏文件里会出现这种情形。
test "duration never goes negative" {
  let info : AudioInfo = {
    codec: "Opus",
    channels: 2,
    sample_rate: 48000,
    pre_skip: 312,
  }
  assert_true(duration_seconds(info, 100L, 50L) == 0.0)
  assert_true(duration_seconds(info, 0L, 100L) == 0.0)
}

///|

///|
/// 按 RFC 7845 §5.1.1 拼 OpusHead（family=0 为 19 字节，否则 21+C）。
fn mk_opus_head(
  ch : Int32,
  family : Int32,
  stream : Int32,
  coupled : Int32,
  mapping : Array[Int32],
) -> Bytes {
  let b = Buffer()
  b.write_bytes(b"OpusHead".exact_view())
  b.write_byte((1 : Byte))
  b.write_byte(ch.to_byte())
  b.write_byte((0x38 : Byte))
  b.write_byte((0x01 : Byte))
  b.write_byte((0x80 : Byte))
  b.write_byte((0xBB : Byte))
  b.write_byte((0 : Byte))
  b.write_byte((0 : Byte))
  b.write_byte((0 : Byte))
  b.write_byte((0 : Byte))
  b.write_byte(family.to_byte())
  if family != 0 {
    b.write_byte(stream.to_byte())
    b.write_byte(coupled.to_byte())
    for m in mapping {
      b.write_byte(m.to_byte())
    }
  }
  b.to_bytes()
}

///|
test "parse_opus_head validates mapping family" {
  // 合法：family=0 单声道 / 立体声
  match parse_opus_head(mk_opus_head(1, 0, 0, 0, [])) {
    Some(info) => assert_eq(info.channels, 1)
    None => assert_true(false)
  }
  match parse_opus_head(mk_opus_head(2, 0, 0, 0, [])) {
    Some(info) => assert_eq(info.channels, 2)
    None => assert_true(false)
  }
  // family=0 且 3 声道：非法
  assert_true(parse_opus_head(mk_opus_head(3, 0, 0, 0, [])) is None)
  // family=1 但缺少映射表
  assert_true(parse_opus_head(mk_opus_head(1, 1, 1, 0, [])) is None)
  // family=1、stream_count=0：非法
  assert_true(parse_opus_head(mk_opus_head(1, 1, 0, 0, [0])) is None)
  // family=1 合法：21+C = 22 字节
  match parse_opus_head(mk_opus_head(1, 1, 1, 0, [0])) {
    Some(info) => assert_eq(info.channels, 1)
    None => assert_true(false)
  }
}

///|
/// OpusHead 版本不是 1 时必须拒绝 —— 解码器（moonopus）却接受 version ≤15，
/// 这正是 H-04「估算与解码校验器不一致」的根源；pipeline 的 gate 依赖这里的
/// 严格性做 fail-closed。
test "parse_opus_head rejects versions other than 1" {
  let b = Buffer()
  b.write_bytes(mk_opus_head(1, 0, 0, 0, []).exact_view())
  let head = b.to_bytes()
  let v2 = Buffer()
  let mut i = 0
  while i < head.length() {
    if i == 8 {
      v2.write_byte((2 : Byte))
    } else {
      v2.write_byte(head[i])
    }
    i = i + 1
  }
  assert_true(parse_opus_head(v2.to_bytes()) is None)
  assert_true(parse_audio_header(v2.to_bytes()) is None)
  // 合法版本仍然通过
  assert_true(parse_opus_head(head) is Some(_))
}

///|
/// Vorbis setup 最小预检：接受合法前缀，拒绝 C-02 的 221 B PoC。
test "validate_vorbis_setup catches the malicious setup" {
  // 合法前缀：1 个 ordered、entries=0 的 codebook；末尾补 1 字节提供
  // ordered 起始码长（5 位）与 lookup_type（4 位）所需的位。
  let ok = b"\x05vorbis\x00\x42\x43\x56\x00\x00\x00\x00\x00\x01\x00"
  assert_true(validate_vorbis_setup(ok) is Ok(_))
  // PoC：dimensions=65536、entries=16777216，非 ordered、非 sparse
  let bad = b"\x05vorbis\x00\x42\x43\x56\xFF\xFF\xFF\xFF\xFF\x00"
  match validate_vorbis_setup(bad) {
    Err(msg) => assert_true(msg.contains("codebook"))
    Ok(_) => assert_true(false)
  }
  // 不是 setup 头
  match validate_vorbis_setup(b"\x03vorbis\x00\x00\x00\x00") {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
  // 截断
  match validate_vorbis_setup(b"\x05vorbis") {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
}

///|
/// 声明的条目数超过包内可读位数（非 sparse 每条约 5 位）必须被拒绝。
test "validate_vorbis_setup rejects a bit-starved codebook" {
  // 1 个非 ordered、非 sparse 的 codebook：entries=1，但码长表之后已无位可读
  let starved = b"\x05vorbis\x00\x42\x43\x56\x00\x00\x01\x00\x00\x00"
  match validate_vorbis_setup(starved) {
    Err(msg) => assert_true(msg.contains("codebook"))
    Ok(_) => assert_true(false)
  }
}

// ---------- F-PAR-01 / F-PAR-02 回归：全 codebook 有界校验 ----------

///|
/// 把 `value` 的低 `n` 位按 LSB-first 追加到 `bits`。
fn vs_push_bits(bits : Array[Int32], value : Int32, n : Int32) -> Unit {
  let mut i = 0
  while i < n {
    bits.push((value >> i) & 1)
    i = i + 1
  }
}

///|
/// 把 LSB-first 位序列打包成字节。
fn vs_bits_to_bytes(bits : Array[Int32]) -> Bytes {
  let buf = Buffer()
  let mut cur = 0
  let mut cnt = 0
  for b in bits {
    if b != 0 {
      cur = cur | (1 << cnt)
    }
    cnt = cnt + 1
    if cnt == 8 {
      buf.write_byte(cur.to_byte())
      cur = 0
      cnt = 0
    }
  }
  if cnt > 0 {
    buf.write_byte(cur.to_byte())
  }
  buf.to_bytes()
}

///|
/// 拼一个 setup 包：0x05 + "vorbis" + 位流（位流第一项是 codebook 计数 - 1）。
fn vs_packet(bits : Array[Int32]) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(b"\x05vorbis".exact_view())
  buf.write_bytes(vs_bits_to_bytes(bits).exact_view())
  buf.to_bytes()
}

///|
/// 拼一个单 codebook 的 setup 位流公共头（sync / dims / entries / ordered / sparse）。
fn vs_single_codebook_header(
  bits : Array[Int32],
  dims : Int32,
  entries : Int32,
  ordered : Int32,
  sparse : Int32,
) -> Unit {
  vs_push_bits(bits, 0, 8) // codebook 计数 - 1 = 0
  vs_push_bits(bits, 0x564342, 24)
  vs_push_bits(bits, dims, 16)
  vs_push_bits(bits, entries, 24)
  vs_push_bits(bits, ordered, 1)
  if ordered == 0 {
    vs_push_bits(bits, sparse, 1)
  }
}

///|
/// F-PAR-02：dimensions / entries 必须按线格式的原值解释（不再 +1）。
///
/// 用 dimensions=4096（恰好等于 gate 上限）而 entries=0 的 codebook：
/// 旧实现读成 4097 会误拒；新实现按 4096 接受。同一组字节在 moonvorbis
/// 的 Codebook 解析里也是 4096（其 codebook_wbtest 的向量 0x0002 -> dims=2）。
test "vorbis setup gate uses wire values for dims/entries (F-PAR-02)" {
  // 对照：moonvorbis codebook_wbtest 的向量（wire dims=2 / entries=4）
  let cross = b"\x05vorbis\x00\x42\x43\x56\x02\x00\x04\x00\x00\x04\x11\x04\x00"
  assert_true(validate_vorbis_setup(cross) is Ok(_))
  // dimensions = 4096（旧实现 +1 后是 4097，会被上限误拒）
  let bits : Array[Int32] = []
  vs_single_codebook_header(bits, 4096, 0, 0, 0)
  vs_push_bits(bits, 0, 4) // lookup_type = 0
  assert_true(validate_vorbis_setup(vs_packet(bits)) is Ok(_))
  // dimensions = 4097 仍应被上限拒绝
  let bits2 : Array[Int32] = []
  vs_single_codebook_header(bits2, 4097, 0, 0, 0)
  vs_push_bits(bits2, 0, 4)
  match validate_vorbis_setup(vs_packet(bits2)) {
    Err(msg) => assert_true(msg.contains("dimensions"))
    Ok(_) => assert_true(false)
  }
}

///|
/// F-PAR-01 回归：第 2 个 codebook 声明巨型 lookup 表（无对应位数据）时，
/// gate 必须在**解码前**返回 Err，而不是把它交给解码器越界读。
///
/// 这正是 354 B PoC 的 setup 构造：第 1 个 codebook 合法，第 2 个声明
/// dimensions=40000 / entries=256 / lookup_type=2（40000 > 4096 即拒绝；
/// 即使绕过上限，lookup 的位预算也会拒绝）。
test "vorbis setup gate validates every codebook (F-PAR-01)" {
  let bits : Array[Int32] = []
  vs_push_bits(bits, 1, 8) // codebook 计数 - 1 = 1 -> 2 个 codebook
  // book 1：完全合法
  vs_push_bits(bits, 0x564342, 24)
  vs_push_bits(bits, 1, 16)
  vs_push_bits(bits, 1, 24)
  vs_push_bits(bits, 0, 1)
  vs_push_bits(bits, 0, 1)
  vs_push_bits(bits, 0, 5)
  vs_push_bits(bits, 0, 4) // lookup_type = 0
  // book 2：恶意声明（PoC 同构）
  vs_push_bits(bits, 0x564342, 24)
  vs_push_bits(bits, 40000, 16)
  vs_push_bits(bits, 256, 24)
  vs_push_bits(bits, 0, 1)
  vs_push_bits(bits, 0, 1)
  let mut i = 0
  while i < 256 {
    vs_push_bits(bits, 0, 5)
    i = i + 1
  }
  vs_push_bits(bits, 2, 4) // lookup_type = 2
  vs_push_bits(bits, 0, 32)
  vs_push_bits(bits, 0, 32)
  vs_push_bits(bits, 15, 4)
  vs_push_bits(bits, 0, 1)
  match validate_vorbis_setup(vs_packet(bits)) {
    Err(msg) => assert_true(msg.contains("dimensions"))
    Ok(_) => assert_true(false)
  }
}

///|
/// F-PAR-01（位预算分支）：codebook 的 lookup 表声明超过包内剩余位数时，
/// 即使 dimensions 在允许范围内也必须拒绝 —— 解码器会按声明值逐个读位。
test "vorbis setup gate rejects a codebook whose lookup table exceeds packet" {
  let bits : Array[Int32] = []
  vs_push_bits(bits, 1, 8) // 2 个 codebook
  // book 1：合法
  vs_push_bits(bits, 0x564342, 24)
  vs_push_bits(bits, 1, 16)
  vs_push_bits(bits, 1, 24)
  vs_push_bits(bits, 0, 1)
  vs_push_bits(bits, 0, 1)
  vs_push_bits(bits, 0, 5)
  vs_push_bits(bits, 0, 4)
  // book 2：dims=4096、entries=1000、lookup type 2 → 需要 4096*1000*16 位
  vs_push_bits(bits, 0x564342, 24)
  vs_push_bits(bits, 4096, 16)
  vs_push_bits(bits, 1000, 24)
  vs_push_bits(bits, 0, 1)
  vs_push_bits(bits, 0, 1)
  let mut i = 0
  while i < 1000 {
    vs_push_bits(bits, 0, 5)
    i = i + 1
  }
  vs_push_bits(bits, 2, 4)
  vs_push_bits(bits, 0, 32)
  vs_push_bits(bits, 0, 32)
  vs_push_bits(bits, 15, 4)
  vs_push_bits(bits, 0, 1)
  match validate_vorbis_setup(vs_packet(bits)) {
    Err(msg) => assert_true(msg.contains("lookup"))
    Ok(_) => assert_true(false)
  }
}

///|
/// 合法的 ordered codebook（游程恰好覆盖 entries）必须被接受。
test "vorbis setup gate accepts a valid ordered codebook" {
  let bits : Array[Int32] = []
  vs_single_codebook_header(bits, 1, 6, 1, 0)
  vs_push_bits(bits, 2, 5) // 起始码长 = 3
  // entries=6：第一段 2 项（ilog(6)=3 位），第二段 4 项（ilog(4)=3 位）
  vs_push_bits(bits, 2, 3)
  vs_push_bits(bits, 4, 3)
  vs_push_bits(bits, 0, 4) // lookup_type = 0
  assert_true(validate_vorbis_setup(vs_packet(bits)) is Ok(_))
}

///|
/// ordered codebook 的游程超过剩余条目数必须被拒绝。
test "vorbis setup gate rejects an ordered run overflow" {
  let bits : Array[Int32] = []
  vs_single_codebook_header(bits, 1, 6, 1, 0)
  vs_push_bits(bits, 2, 5)
  vs_push_bits(bits, 7, 3) // 7 > 6
  match validate_vorbis_setup(vs_packet(bits)) {
    Err(msg) => assert_true(msg.contains("游程"))
    Ok(_) => assert_true(false)
  }
}

///|
/// lookup_type 只能是 0/1/2；保留值必须被拒绝（解码器会误解释）。
test "vorbis setup gate rejects a reserved lookup type" {
  let bits : Array[Int32] = []
  vs_single_codebook_header(bits, 1, 0, 0, 0)
  vs_push_bits(bits, 3, 4) // lookup_type = 3（保留）
  match validate_vorbis_setup(vs_packet(bits)) {
    Err(msg) => assert_true(msg.contains("lookup_type"))
    Ok(_) => assert_true(false)
  }
}

///|
/// sparse codebook 的 used 标志/码长表必须按解码器实际读取量核算位预算；
/// 位不够时读到不足即拒绝（RT-A-01）。
test "vorbis setup gate rejects a bit-starved sparse codebook" {
  let bits : Array[Int32] = []
  vs_single_codebook_header(bits, 1, 7, 0, 1)
  match validate_vorbis_setup(vs_packet(bits)) {
    Err(msg) => assert_true(msg.contains("sparse"))
    Ok(_) => assert_true(false)
  }
}

// ---------- 第 2 轮（RT-A）：完整 setup 段与交叉引用校验 ----------

///|
/// 一个最小 codebook（dims=1、entries=1、非 sparse、无 lookup）的位流。
fn vs_bits_cb(bits : Array[Int32]) -> Unit {
  vs_push_bits(bits, 0, 8)
  vs_push_bits(bits, 0x564342, 24)
  vs_push_bits(bits, 1, 16)
  vs_push_bits(bits, 1, 24)
  vs_push_bits(bits, 0, 1)
  vs_push_bits(bits, 0, 1)
  vs_push_bits(bits, 0, 5)
  vs_push_bits(bits, 0, 4)
}

///|
/// 带 lookup type 1 的 codebook（dims=1、entries=1、1 个 lookup 值）。
fn vs_bits_cb_lookup(bits : Array[Int32]) -> Unit {
  vs_push_bits(bits, 0, 8)
  vs_push_bits(bits, 0x564342, 24)
  vs_push_bits(bits, 1, 16)
  vs_push_bits(bits, 1, 24)
  vs_push_bits(bits, 0, 1)
  vs_push_bits(bits, 0, 1)
  vs_push_bits(bits, 0, 5)
  vs_push_bits(bits, 1, 4) // lookup_type = 1
  vs_push_bits(bits, 0, 32)
  vs_push_bits(bits, 0, 32)
  vs_push_bits(bits, 0, 4) // value_bits = 1
  vs_push_bits(bits, 0, 1) // sequence
  vs_push_bits(bits, 0, 1) // 1 个 lookup 值
}

///|
/// 时间变换段：1 个类型 0。
fn vs_bits_time(bits : Array[Int32], kind : Int32) -> Unit {
  vs_push_bits(bits, 0, 6)
  vs_push_bits(bits, kind, 16)
}

///|
/// 无 partition 的 floor1 段。
fn vs_bits_floor1_simple(bits : Array[Int32]) -> Unit {
  vs_push_bits(bits, 0, 6)
  vs_push_bits(bits, 1, 16)
  vs_push_bits(bits, 0, 5)
  vs_push_bits(bits, 0, 2)
  vs_push_bits(bits, 0, 4)
}

///|
/// 带 1 个 partition class（subclasses=1）的 floor1：masterbook 与两个
/// subclass book 都可以注入越界索引（-1 表示 subclass book 不使用）。
fn vs_bits_floor1_books(
  bits : Array[Int32],
  masterbook : Int32,
  subclass0 : Int32,
  subclass1 : Int32,
) -> Unit {
  vs_push_bits(bits, 0, 6)
  vs_push_bits(bits, 1, 16)
  vs_push_bits(bits, 1, 5) // partitions = 1
  vs_push_bits(bits, 0, 4) // partition class 0
  vs_push_bits(bits, 0, 3) // class dimensions - 1 = 0 -> 1
  vs_push_bits(bits, 1, 2) // subclasses = 1
  vs_push_bits(bits, masterbook, 8)
  vs_push_bits(bits, subclass0 + 1, 8)
  vs_push_bits(bits, subclass1 + 1, 8)
  vs_push_bits(bits, 0, 2) // multiplier
  vs_push_bits(bits, 0, 4) // rangebits
}

///|
/// floor0 段（2 个 book 引用）。
fn vs_bits_floor0(bits : Array[Int32], book0 : Int32, book1 : Int32) -> Unit {
  vs_push_bits(bits, 0, 6)
  vs_push_bits(bits, 0, 16)
  vs_push_bits(bits, 1, 8) // order
  vs_push_bits(bits, 1, 16) // rate
  vs_push_bits(bits, 1, 16) // bark_map_size
  vs_push_bits(bits, 0, 6)
  vs_push_bits(bits, 0, 8)
  vs_push_bits(bits, 1, 4) // book_count - 1 = 1 -> 2
  vs_push_bits(bits, book0, 8)
  vs_push_bits(bits, book1, 8)
}

///|
/// residue 段：type=1、classifications=1、pair 可选（cascade 第 0 位置位）。
fn vs_bits_residue(
  bits : Array[Int32],
  residue_type : Int32,
  classbook : Int32,
  cascade_low : Int32,
  residue_book : Int32,
) -> Unit {
  vs_push_bits(bits, 0, 6)
  vs_push_bits(bits, residue_type, 16)
  vs_push_bits(bits, 0, 24)
  vs_push_bits(bits, 0, 24)
  vs_push_bits(bits, 0, 24)
  vs_push_bits(bits, 0, 6)
  vs_push_bits(bits, classbook, 8)
  vs_push_bits(bits, cascade_low, 3)
  vs_push_bits(bits, 0, 1)
  if cascade_low != 0 {
    vs_push_bits(bits, residue_book, 8)
  }
}

///|
/// 单 submap、无 coupling 的 mapping 段（可注入越界的 floor/residue/time 下标）。
fn vs_bits_mapping(
  bits : Array[Int32],
  mapping_type : Int32,
  floor : Int32,
  residue : Int32,
  time_config : Int32,
) -> Unit {
  vs_push_bits(bits, 0, 6)
  vs_push_bits(bits, mapping_type, 16)
  vs_push_bits(bits, 0, 1) // submaps flag
  vs_push_bits(bits, 0, 1) // coupling flag
  vs_push_bits(bits, 0, 2) // reserved
  vs_push_bits(bits, time_config, 8)
  vs_push_bits(bits, floor, 8)
  vs_push_bits(bits, residue, 8)
}

///|
/// 带 coupling 的 mapping（单声道对，channels 决定声道号位数）。
fn vs_bits_mapping_coupling(
  bits : Array[Int32],
  channels : Int32,
  magnitude : Int32,
  angle : Int32,
) -> Unit {
  vs_push_bits(bits, 0, 6)
  vs_push_bits(bits, 0, 16)
  vs_push_bits(bits, 0, 1) // submaps flag
  vs_push_bits(bits, 1, 1) // coupling flag
  vs_push_bits(bits, 0, 8) // coupling steps - 1 = 0
  let step_bits = gate_step_bits(channels)
  vs_push_bits(bits, magnitude, step_bits)
  vs_push_bits(bits, angle, step_bits)
  vs_push_bits(bits, 0, 2) // reserved
  vs_push_bits(bits, 0, 8)
  vs_push_bits(bits, 0, 8)
  vs_push_bits(bits, 0, 8)
}

///|
/// 与解码器 `ilog(channels - 1)` 等价的声道号位宽。
fn gate_step_bits(channels : Int32) -> Int32 {
  let mut x = channels - 1
  let mut n = 0
  while x > 0 {
    n = n + 1
    x = x >> 1
  }
  n
}

///|
/// 带 submaps>1 的 mapping：mux 可注入越界值。
fn vs_bits_mapping_submaps(
  bits : Array[Int32],
  channels : Int32,
  submaps : Int32,
  mux : Int32,
) -> Unit {
  vs_push_bits(bits, 0, 6)
  vs_push_bits(bits, 0, 16)
  vs_push_bits(bits, 1, 1)
  vs_push_bits(bits, submaps - 1, 4)
  vs_push_bits(bits, 0, 1) // coupling flag
  vs_push_bits(bits, 0, 2) // reserved
  let mut i = 0
  while i < channels {
    vs_push_bits(bits, mux, 4)
    i = i + 1
  }
  let mut s = 0
  while s < submaps {
    vs_push_bits(bits, 0, 8)
    vs_push_bits(bits, 0, 8)
    vs_push_bits(bits, 0, 8)
    s = s + 1
  }
}

///|
/// mode 段（可注入越界 mapping 下标与非法 window/transform 类型）。
fn vs_bits_modes(
  bits : Array[Int32],
  blockflag : Int32,
  windowtype : Int32,
  transformtype : Int32,
  mapping : Int32,
) -> Unit {
  vs_push_bits(bits, 0, 6)
  vs_push_bits(bits, blockflag, 1)
  vs_push_bits(bits, windowtype, 16)
  vs_push_bits(bits, transformtype, 16)
  vs_push_bits(bits, mapping, 8)
}

///|
/// 收尾 framing 位。
fn vs_bits_finish(bits : Array[Int32]) -> Unit {
  vs_push_bits(bits, 1, 1)
}

///|
/// 默认的完整合法 setup（1 codebook / floor1 / residue / mapping / mode）。
fn vs_full_setup_packet() -> Bytes {
  let bits : Array[Int32] = []
  vs_bits_cb(bits)
  vs_bits_time(bits, 0)
  vs_bits_floor1_simple(bits)
  vs_bits_residue(bits, 1, 0, 0, 0)
  vs_bits_mapping(bits, 0, 0, 0, 0)
  vs_bits_modes(bits, 0, 0, 0, 0)
  vs_bits_finish(bits)
  vs_packet(bits)
}

///|
/// RT-A-02 / gate v2：完整合法 setup 必须被接受，并返回各段计数与 mode。
test "vorbis setup v2 accepts a complete setup" {
  let packet = vs_full_setup_packet()
  match parse_vorbis_setup_info(packet, 2) {
    Ok(info) => {
      assert_eq(info.codebooks, 1)
      assert_eq(info.floors, 1)
      assert_eq(info.residues, 1)
      assert_eq(info.mappings, 1)
      assert_eq(info.modes.length(), 1)
      assert_eq(info.modes[0], 0)
    }
    Err(msg) => abort("合法 setup 被拒绝: " + msg)
  }
  // 声道数非法必须在入口拒绝（mapping 校验依赖它）
  assert_true(parse_vorbis_setup_info(packet, 0) is Err(_))
  assert_true(parse_vorbis_setup_info(packet, 256) is Err(_))
  // 非 setup 包
  assert_true(parse_vorbis_setup_info(b"\x05vorbis", 2) is Err(_))
  assert_true(parse_vorbis_setup_info(b"\x03vorbis\x00\x00", 2) is Err(_))
}

///|
/// RT-A-02：residue 的 classbook / residue book 必须是合法 codebook 下标。
test "vorbis setup v2 rejects out-of-range residue book references" {
  // classbook = 200（只有一个 codebook）
  let bits : Array[Int32] = []
  vs_bits_cb(bits)
  vs_bits_time(bits, 0)
  vs_bits_floor1_simple(bits)
  vs_bits_residue(bits, 1, 200, 0, 0)
  vs_bits_mapping(bits, 0, 0, 0, 0)
  vs_bits_modes(bits, 0, 0, 0, 0)
  vs_bits_finish(bits)
  match parse_vorbis_setup_info(vs_packet(bits), 2) {
    Err(msg) => assert_true(msg.contains("classbook"))
    Ok(_) => assert_true(false)
  }
  // residue book = 200（cascade 第 0 位置位）
  let bits2 : Array[Int32] = []
  vs_bits_cb(bits2)
  vs_bits_time(bits2, 0)
  vs_bits_floor1_simple(bits2)
  vs_bits_residue(bits2, 1, 0, 1, 200)
  vs_bits_mapping(bits2, 0, 0, 0, 0)
  vs_bits_modes(bits2, 0, 0, 0, 0)
  vs_bits_finish(bits2)
  match parse_vorbis_setup_info(vs_packet(bits2), 2) {
    Err(msg) => assert_true(msg.contains("residue book"))
    Ok(_) => assert_true(false)
  }
  // RT3-04：classbook 只用 Huffman 标量解码，dimensions=0 合法
  // （dimensions 线格式是 raw 值、无 +1；libvorbis codebook.c 同）。
  let bits3 : Array[Int32] = []
  vs_push_bits(bits3, 0, 8)
  vs_push_bits(bits3, 0x564342, 24)
  vs_push_bits(bits3, 0, 16)
  vs_push_bits(bits3, 1, 24)
  vs_push_bits(bits3, 0, 1)
  vs_push_bits(bits3, 0, 1)
  vs_push_bits(bits3, 0, 5)
  vs_push_bits(bits3, 0, 4)
  vs_bits_time(bits3, 0)
  vs_bits_floor1_simple(bits3)
  vs_bits_residue(bits3, 1, 0, 0, 0)
  vs_bits_mapping(bits3, 0, 0, 0, 0)
  vs_bits_modes(bits3, 0, 0, 0, 0)
  vs_bits_finish(bits3)
  match parse_vorbis_setup_info(vs_packet(bits3), 2) {
    Ok(info) => {
      assert_eq(info.codebooks, 1)
      assert_eq(info.decoder_setup_bytes > 0L, true)
    }
    Err(msg) => abort("classbook dimensions=0 应被接受（RT3-04）: " + msg)
  }
  // residue book 走 VQ 解码，dimensions=0 会让解码循环不前进 → 拒绝
  let bits4 : Array[Int32] = []
  vs_push_bits(bits4, 0, 8)
  vs_push_bits(bits4, 0x564342, 24)
  vs_push_bits(bits4, 0, 16)
  vs_push_bits(bits4, 1, 24)
  vs_push_bits(bits4, 0, 1)
  vs_push_bits(bits4, 0, 1)
  vs_push_bits(bits4, 0, 5)
  vs_push_bits(bits4, 0, 4)
  vs_bits_time(bits4, 0)
  vs_bits_floor1_simple(bits4)
  vs_bits_residue(bits4, 1, 0, 1, 0)
  vs_bits_mapping(bits4, 0, 0, 0, 0)
  vs_bits_modes(bits4, 0, 0, 0, 0)
  vs_bits_finish(bits4)
  match parse_vorbis_setup_info(vs_packet(bits4), 2) {
    Err(msg) => assert_true(msg.contains("dimensions"))
    Ok(_) => assert_true(false)
  }
}

///|
/// RT-A-02：floor1 的 masterbook / subclass book 必须是合法 codebook 下标。
test "vorbis setup v2 rejects out-of-range floor1 book references" {
  // subclass book = 200
  let bits : Array[Int32] = []
  vs_bits_cb(bits)
  vs_bits_time(bits, 0)
  vs_bits_floor1_books(bits, 0, 200, -1)
  vs_bits_residue(bits, 1, 0, 0, 0)
  vs_bits_mapping(bits, 0, 0, 0, 0)
  vs_bits_modes(bits, 0, 0, 0, 0)
  vs_bits_finish(bits)
  match parse_vorbis_setup_info(vs_packet(bits), 2) {
    Err(msg) => assert_true(msg.contains("subclass book"))
    Ok(_) => assert_true(false)
  }
  // masterbook = 200（subclasses=1 才会读它）
  let bits2 : Array[Int32] = []
  vs_bits_cb(bits2)
  vs_bits_time(bits2, 0)
  vs_bits_floor1_books(bits2, 200, -1, -1)
  vs_bits_residue(bits2, 1, 0, 0, 0)
  vs_bits_mapping(bits2, 0, 0, 0, 0)
  vs_bits_modes(bits2, 0, 0, 0, 0)
  vs_bits_finish(bits2)
  match parse_vorbis_setup_info(vs_packet(bits2), 2) {
    Err(msg) => assert_true(msg.contains("masterbook"))
    Ok(_) => assert_true(false)
  }
}

///|
/// RT-A-02：floor0 的 book 引用越界 / 无 lookup / order 为 0 都要拒绝。
test "vorbis setup v2 validates floor0 book references" {
  let bits : Array[Int32] = []
  vs_bits_cb_lookup(bits)
  vs_bits_time(bits, 0)
  vs_bits_floor0(bits, 0, 0)
  vs_bits_residue(bits, 1, 0, 0, 0)
  vs_bits_mapping(bits, 0, 0, 0, 0)
  vs_bits_modes(bits, 0, 0, 0, 0)
  vs_bits_finish(bits)
  match parse_vorbis_setup_info(vs_packet(bits), 2) {
    Ok(_) => assert_true(true)
    Err(msg) => abort("合法 floor0 被拒绝: " + msg)
  }
  // book 索引越界
  let bits2 : Array[Int32] = []
  vs_bits_cb_lookup(bits2)
  vs_bits_time(bits2, 0)
  vs_bits_floor0(bits2, 200, 0)
  vs_bits_residue(bits2, 1, 0, 0, 0)
  vs_bits_mapping(bits2, 0, 0, 0, 0)
  vs_bits_modes(bits2, 0, 0, 0, 0)
  vs_bits_finish(bits2)
  match parse_vorbis_setup_info(vs_packet(bits2), 2) {
    Err(msg) => assert_true(msg.contains("book 索引"))
    Ok(_) => assert_true(false)
  }
  // 引用的 book 没有 lookup 表（dims/entries=1、lookup_type=0）
  let bits3 : Array[Int32] = []
  vs_bits_cb(bits3)
  vs_bits_time(bits3, 0)
  vs_bits_floor0(bits3, 0, 0)
  vs_bits_residue(bits3, 1, 0, 0, 0)
  vs_bits_mapping(bits3, 0, 0, 0, 0)
  vs_bits_modes(bits3, 0, 0, 0, 0)
  vs_bits_finish(bits3)
  match parse_vorbis_setup_info(vs_packet(bits3), 2) {
    Err(msg) => assert_true(msg.contains("lookup"))
    Ok(_) => assert_true(false)
  }
}

///|
/// RT-A-02：mapping 的 floor/residue/time 下标必须是合法跨段下标。
test "vorbis setup v2 rejects out-of-range mapping references" {
  // floor = 200
  let bits : Array[Int32] = []
  vs_bits_cb(bits)
  vs_bits_time(bits, 0)
  vs_bits_floor1_simple(bits)
  vs_bits_residue(bits, 1, 0, 0, 0)
  vs_bits_mapping(bits, 0, 200, 0, 0)
  vs_bits_modes(bits, 0, 0, 0, 0)
  vs_bits_finish(bits)
  match parse_vorbis_setup_info(vs_packet(bits), 2) {
    Err(msg) => assert_true(msg.contains("floor 索引"))
    Ok(_) => assert_true(false)
  }
  // residue = 200
  let bits2 : Array[Int32] = []
  vs_bits_cb(bits2)
  vs_bits_time(bits2, 0)
  vs_bits_floor1_simple(bits2)
  vs_bits_residue(bits2, 1, 0, 0, 0)
  vs_bits_mapping(bits2, 0, 0, 200, 0)
  vs_bits_modes(bits2, 0, 0, 0, 0)
  vs_bits_finish(bits2)
  match parse_vorbis_setup_info(vs_packet(bits2), 2) {
    Err(msg) => assert_true(msg.contains("residue 索引"))
    Ok(_) => assert_true(false)
  }
  // time_config = 200
  let bits3 : Array[Int32] = []
  vs_bits_cb(bits3)
  vs_bits_time(bits3, 0)
  vs_bits_floor1_simple(bits3)
  vs_bits_residue(bits3, 1, 0, 0, 0)
  vs_bits_mapping(bits3, 0, 0, 0, 200)
  vs_bits_modes(bits3, 0, 0, 0, 0)
  vs_bits_finish(bits3)
  match parse_vorbis_setup_info(vs_packet(bits3), 2) {
    Err(msg) => assert_true(msg.contains("time_config"))
    Ok(_) => assert_true(false)
  }
  // mapping 类型不是 0
  let bits4 : Array[Int32] = []
  vs_bits_cb(bits4)
  vs_bits_time(bits4, 0)
  vs_bits_floor1_simple(bits4)
  vs_bits_residue(bits4, 1, 0, 0, 0)
  vs_bits_mapping(bits4, 1, 0, 0, 0)
  vs_bits_modes(bits4, 0, 0, 0, 0)
  vs_bits_finish(bits4)
  match parse_vorbis_setup_info(vs_packet(bits4), 2) {
    Err(msg) => assert_true(msg.contains("类型不是 0"))
    Ok(_) => assert_true(false)
  }
}

///|
/// RT-A-02：mode 的 mapping 下标越界 / window·transform 非 0 必须拒绝。
test "vorbis setup v2 rejects invalid modes" {
  let bits : Array[Int32] = []
  vs_bits_cb(bits)
  vs_bits_time(bits, 0)
  vs_bits_floor1_simple(bits)
  vs_bits_residue(bits, 1, 0, 0, 0)
  vs_bits_mapping(bits, 0, 0, 0, 0)
  vs_bits_modes(bits, 0, 0, 0, 200)
  vs_bits_finish(bits)
  match parse_vorbis_setup_info(vs_packet(bits), 2) {
    Err(msg) => assert_true(msg.contains("mapping 索引"))
    Ok(_) => assert_true(false)
  }
  let bits2 : Array[Int32] = []
  vs_bits_cb(bits2)
  vs_bits_time(bits2, 0)
  vs_bits_floor1_simple(bits2)
  vs_bits_residue(bits2, 1, 0, 0, 0)
  vs_bits_mapping(bits2, 0, 0, 0, 0)
  vs_bits_modes(bits2, 0, 1, 0, 0)
  vs_bits_finish(bits2)
  match parse_vorbis_setup_info(vs_packet(bits2), 2) {
    Err(msg) => assert_true(msg.contains("windowtype"))
    Ok(_) => assert_true(false)
  }
}

///|
/// RT-A-02：coupling 声道号必须小于声道数，且 magnitude != angle。
test "vorbis setup v2 validates coupling channels" {
  let bits : Array[Int32] = []
  vs_bits_cb(bits)
  vs_bits_time(bits, 0)
  vs_bits_floor1_simple(bits)
  vs_bits_residue(bits, 1, 0, 0, 0)
  vs_bits_mapping_coupling(bits, 3, 3, 0)
  vs_bits_modes(bits, 0, 0, 0, 0)
  vs_bits_finish(bits)
  match parse_vorbis_setup_info(vs_packet(bits), 3) {
    Err(msg) => assert_true(msg.contains("coupling 声道号"))
    Ok(_) => assert_true(false)
  }
  // magnitude == angle
  let bits2 : Array[Int32] = []
  vs_bits_cb(bits2)
  vs_bits_time(bits2, 0)
  vs_bits_floor1_simple(bits2)
  vs_bits_residue(bits2, 1, 0, 0, 0)
  vs_bits_mapping_coupling(bits2, 2, 1, 1)
  vs_bits_modes(bits2, 0, 0, 0, 0)
  vs_bits_finish(bits2)
  match parse_vorbis_setup_info(vs_packet(bits2), 2) {
    Err(msg) => assert_true(msg.contains("等于 angle"))
    Ok(_) => assert_true(false)
  }
  // 单声道声明 coupling：无法校验声道下标，fail-closed
  let bits3 : Array[Int32] = []
  vs_bits_cb(bits3)
  vs_bits_time(bits3, 0)
  vs_bits_floor1_simple(bits3)
  vs_bits_residue(bits3, 1, 0, 0, 0)
  vs_bits_mapping_coupling(bits3, 1, 0, 0)
  vs_bits_modes(bits3, 0, 0, 0, 0)
  vs_bits_finish(bits3)
  match parse_vorbis_setup_info(vs_packet(bits3), 1) {
    Err(msg) => assert_true(msg.contains("声道"))
    Ok(_) => assert_true(false)
  }
}

///|
/// RT-A-02：submaps>1 时 mux 必须小于 submaps。
test "vorbis setup v2 validates mapping mux" {
  let bits : Array[Int32] = []
  vs_bits_cb(bits)
  vs_bits_time(bits, 0)
  vs_bits_floor1_simple(bits)
  vs_bits_residue(bits, 1, 0, 0, 0)
  vs_bits_mapping_submaps(bits, 2, 2, 2)
  vs_bits_modes(bits, 0, 0, 0, 0)
  vs_bits_finish(bits)
  match parse_vorbis_setup_info(vs_packet(bits), 2) {
    Err(msg) => assert_true(msg.contains("mux"))
    Ok(_) => assert_true(false)
  }
}

///|
/// RT-A-07 / RT-A-01：ordered=1 不得提前 Ok；sparse 位预算必须按解码器
/// 实际读取量（1+5 位）核算。
test "vorbis setup v2 does not early-return on ordered codebooks (RT-A-07)" {
  // ordered、entries=0、lookup_type=1 但后续字段完全缺失：必须继续解析并 Err
  let bits : Array[Int32] = []
  vs_push_bits(bits, 0, 8)
  vs_push_bits(bits, 0x564342, 24)
  vs_push_bits(bits, 1, 16)
  vs_push_bits(bits, 0, 24)
  vs_push_bits(bits, 1, 1) // ordered
  vs_push_bits(bits, 0, 5) // 起始码长
  vs_push_bits(bits, 1, 4) // lookup_type=1，但 min/delta 缺失
  match validate_vorbis_setup(vs_packet(bits)) {
    Err(msg) => assert_true(msg.contains("min_value"))
    Ok(_) => assert_true(false)
  }
}

///|
/// RT-A-01：sparse 码长表按「1 位 only」估计会放行、按解码器实际读取量
/// （used=1 时再读 5 位）必须拒绝。
test "vorbis setup v2 uses decoder sparse budget (RT-A-01)" {
  // entries=3，头部之后只给 3 位 used 标志（全 1）→ 解码器还要读 15 位码长
  let bits : Array[Int32] = []
  vs_push_bits(bits, 0, 8)
  vs_push_bits(bits, 0x564342, 24)
  vs_push_bits(bits, 1, 16)
  vs_push_bits(bits, 3, 24)
  vs_push_bits(bits, 0, 1)
  vs_push_bits(bits, 1, 1) // sparse
  vs_push_bits(bits, 7, 3) // 3 个 used 位全 1
  match validate_vorbis_setup(vs_packet(bits)) {
    Err(msg) => assert_true(msg.contains("sparse"))
    Ok(_) => assert_true(false)
  }
  // 同样的 3 个条目，给足 3×(1+5)=18 位：码长表合法，旧 API 应接受
  let bits2 : Array[Int32] = []
  vs_push_bits(bits2, 0, 8)
  vs_push_bits(bits2, 0x564342, 24)
  vs_push_bits(bits2, 1, 16)
  vs_push_bits(bits2, 3, 24)
  vs_push_bits(bits2, 0, 1)
  vs_push_bits(bits2, 1, 1)
  vs_push_bits(bits2, 7, 3)
  vs_push_bits(bits2, 0, 5)
  vs_push_bits(bits2, 0, 5)
  vs_push_bits(bits2, 0, 5)
  assert_true(validate_vorbis_setup(vs_packet(bits2)) is Ok(_))
}

///|
/// RT-A-03：lookup type 1 的 dimensions 越界、lookup type 2 元素数溢出。
test "vorbis setup v2 bounds lookup tables (RT-A-03)" {
  // type 1、dimensions=17（解码器幂算会溢出/空转）→ 拒绝
  let bits : Array[Int32] = []
  vs_push_bits(bits, 0, 8)
  vs_push_bits(bits, 0x564342, 24)
  vs_push_bits(bits, 17, 16)
  vs_push_bits(bits, 2, 24)
  vs_push_bits(bits, 0, 1)
  vs_push_bits(bits, 0, 1)
  vs_push_bits(bits, 0, 5)
  vs_push_bits(bits, 0, 5)
  vs_push_bits(bits, 1, 4)
  vs_push_bits(bits, 0, 32)
  vs_push_bits(bits, 0, 32)
  vs_push_bits(bits, 0, 4)
  vs_push_bits(bits, 0, 1)
  match validate_vorbis_setup(vs_packet(bits)) {
    Err(msg) => assert_true(msg.contains("dimensions"))
    Ok(_) => assert_true(false)
  }
  // type 2：entries=4097、dimensions=4096 → 元素数 16,781,312 超上限
  let bits2 : Array[Int32] = []
  vs_push_bits(bits2, 0, 8)
  vs_push_bits(bits2, 0x564342, 24)
  vs_push_bits(bits2, 4096, 16)
  vs_push_bits(bits2, 4097, 24)
  vs_push_bits(bits2, 0, 1)
  vs_push_bits(bits2, 0, 1)
  let mut i = 0
  while i < 4097 {
    vs_push_bits(bits2, 0, 5)
    i = i + 1
  }
  vs_push_bits(bits2, 2, 4)
  vs_push_bits(bits2, 0, 32)
  vs_push_bits(bits2, 0, 32)
  vs_push_bits(bits2, 0, 4)
  vs_push_bits(bits2, 0, 1)
  match validate_vorbis_setup(vs_packet(bits2)) {
    Err(msg) => assert_true(msg.contains("元素数"))
    Ok(_) => assert_true(false)
  }
}

///|
/// 其余结构错误：时间变换类型、floor 类型、residue 类型、reserved、
/// framing 位、尾部多余位。
test "vorbis setup v2 rejects malformed section headers" {
  // 时间变换类型非 0
  let a : Array[Int32] = []
  vs_bits_cb(a)
  vs_bits_time(a, 1)
  vs_bits_floor1_simple(a)
  vs_bits_residue(a, 1, 0, 0, 0)
  vs_bits_mapping(a, 0, 0, 0, 0)
  vs_bits_modes(a, 0, 0, 0, 0)
  vs_bits_finish(a)
  match parse_vorbis_setup_info(vs_packet(a), 2) {
    Err(msg) => assert_true(msg.contains("时间变换"))
    Ok(_) => assert_true(false)
  }
  // floor 类型 2（不存在）
  let b : Array[Int32] = []
  vs_bits_cb(b)
  vs_bits_time(b, 0)
  vs_push_bits(b, 0, 6)
  vs_push_bits(b, 2, 16)
  vs_bits_residue(b, 1, 0, 0, 0)
  vs_bits_mapping(b, 0, 0, 0, 0)
  vs_bits_modes(b, 0, 0, 0, 0)
  vs_bits_finish(b)
  match parse_vorbis_setup_info(vs_packet(b), 2) {
    Err(msg) => assert_true(msg.contains("不支持"))
    Ok(_) => assert_true(false)
  }
  // residue 类型 3
  let c : Array[Int32] = []
  vs_bits_cb(c)
  vs_bits_time(c, 0)
  vs_bits_floor1_simple(c)
  vs_bits_residue(c, 3, 0, 0, 0)
  vs_bits_mapping(c, 0, 0, 0, 0)
  vs_bits_modes(c, 0, 0, 0, 0)
  vs_bits_finish(c)
  match parse_vorbis_setup_info(vs_packet(c), 2) {
    Err(msg) => assert_true(msg.contains("类型不支持"))
    Ok(_) => assert_true(false)
  }
  // reserved != 0
  let d : Array[Int32] = []
  vs_bits_cb(d)
  vs_bits_time(d, 0)
  vs_bits_floor1_simple(d)
  vs_bits_residue(d, 1, 0, 0, 0)
  vs_push_bits(d, 0, 6)
  vs_push_bits(d, 0, 16)
  vs_push_bits(d, 0, 1)
  vs_push_bits(d, 0, 1)
  vs_push_bits(d, 1, 2)
  vs_push_bits(d, 0, 8)
  vs_push_bits(d, 0, 8)
  vs_push_bits(d, 0, 8)
  vs_bits_modes(d, 0, 0, 0, 0)
  vs_bits_finish(d)
  match parse_vorbis_setup_info(vs_packet(d), 2) {
    Err(msg) => assert_true(msg.contains("reserved"))
    Ok(_) => assert_true(false)
  }
  // framing 位为 0
  let e : Array[Int32] = []
  vs_bits_cb(e)
  vs_bits_time(e, 0)
  vs_bits_floor1_simple(e)
  vs_bits_residue(e, 1, 0, 0, 0)
  vs_bits_mapping(e, 0, 0, 0, 0)
  vs_bits_modes(e, 0, 0, 0, 0)
  vs_push_bits(e, 0, 1)
  match parse_vorbis_setup_info(vs_packet(e), 2) {
    Err(msg) => assert_true(msg.contains("framing"))
    Ok(_) => assert_true(false)
  }
  // framing 之后还有 ≥8 位多余数据
  let f : Array[Int32] = []
  vs_bits_cb(f)
  vs_bits_time(f, 0)
  vs_bits_floor1_simple(f)
  vs_bits_residue(f, 1, 0, 0, 0)
  vs_bits_mapping(f, 0, 0, 0, 0)
  vs_bits_modes(f, 0, 0, 0, 0)
  vs_bits_finish(f)
  vs_push_bits(f, 0, 8)
  match parse_vorbis_setup_info(vs_packet(f), 2) {
    Err(msg) => assert_true(msg.contains("多余数据"))
    Ok(_) => assert_true(false)
  }
}

///|
/// 拼一个 30 字节的 Vorbis 识别头（公开字段布局见 Vorbis I §4.2.2）。
fn vs_id_packet(block0 : Int32, block1 : Int32) -> Bytes {
  let buf = Buffer()
  buf.write_byte((0x01 : Byte))
  buf.write_bytes(b"vorbis".exact_view())
  buf.write_bytes(b"\x00\x00\x00\x00".exact_view())
  buf.write_byte((1 : Byte))
  buf.write_bytes(b"\x44\xac\x00\x00".exact_view())
  buf.write_bytes(
    b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".exact_view(),
  )
  buf.write_byte((block0 | (block1 << 4) : Int32).to_byte())
  buf.write_byte((1 : Byte))
  buf.to_bytes()
}

///|
/// `vorbis_block_sizes` 与 `parse_vorbis_id` 使用同一套块大小校验。
test "vorbis block sizes helper mirrors identification header validation" {
  let id = vs_id_packet(8, 11)
  assert_eq(id.length(), 30)
  match vorbis_block_sizes(id) {
    Some((b0, b1)) => {
      assert_eq(b0, 256)
      assert_eq(b1, 2048)
    }
    None => assert_true(false)
  }
  assert_true(vorbis_block_sizes(b"\x01vorbis") is None)
  // block0 > block1：非法
  assert_true(vorbis_block_sizes(vs_id_packet(11, 8)) is None)
  // block 指数越界（5 / 14）
  assert_true(vorbis_block_sizes(vs_id_packet(5, 11)) is None)
  assert_true(vorbis_block_sizes(vs_id_packet(8, 14)) is None)
}

// ---------- 第 3 轮（RT3）：codebook 分配上界与 Huffman 符号上界 ----------

///|
/// 2 个 `lookup_type=1, dimensions=16, entries=65536` 的 ordered codebook
/// （bits 很少，但解码器会为每个展开 65536×16 个 Float）。
fn vs_bits_big_lookup(bits : Array[Int32]) -> Unit {
  vs_push_bits(bits, 1, 8) // codebook 计数 - 1 = 1
  let mut cb = 0
  while cb < 2 {
    vs_push_bits(bits, 0x564342, 24)
    vs_push_bits(bits, 16, 16)
    vs_push_bits(bits, 65536, 24)
    vs_push_bits(bits, 1, 1) // ordered
    vs_push_bits(bits, 0, 5) // 起始码长 1
    vs_push_bits(bits, 65535, 17) // 65535 个 length=1
    vs_push_bits(bits, 1, 1) // 1 个 length=2
    vs_push_bits(bits, 1, 4) // lookup_type = 1
    vs_push_bits(bits, 0, 32)
    vs_push_bits(bits, 0, 32)
    vs_push_bits(bits, 0, 4) // value_bits = 1
    vs_push_bits(bits, 0, 1)
    vs_push_bits(bits, 0, 2) // raw = lookup1_values(65536,16) = 2
    cb = cb + 1
  }
}

///|
/// RT3-01：`lookup_type=1` 的 entries×dimensions 展开与 Huffman 表必须计入
/// `decoder_setup_bytes`；同时给出 `max_huffman_scan`（RT3-02 的 CPU 上界）。
test "vorbis setup v3 exposes codebook allocation and huffman bounds" {
  let bits : Array[Int32] = []
  vs_bits_big_lookup(bits)
  vs_bits_time(bits, 0)
  vs_bits_floor1_simple(bits)
  vs_bits_residue(bits, 1, 0, 0, 0)
  vs_bits_mapping(bits, 0, 0, 0, 0)
  vs_bits_modes(bits, 0, 0, 0, 0)
  vs_bits_finish(bits)
  match parse_vorbis_setup_info(vs_packet(bits), 2) {
    Ok(info) => {
      // 每个 codebook：entries*(4*dims+8) + active*12 + 64
      // = 65536*72 + 65536*12 + 64 = 5,505,088；两个 = 11,010,176
      assert_eq(info.decoder_setup_bytes, 11010176L)
      // 最长码长 2、有效码字 65536 → scan = 131072
      assert_eq(info.max_huffman_scan, 131072L)
      assert_eq(info.floor_symbols.length(), 1)
      assert_eq(info.floor_symbols[0], 2)
      // 每包符号上界：2 声道 × floor(2) + 2 声道 × 8 × (0/1 + 1) = 20；× maxScan 131072
      // （该 fixture 的 residue begin=end=0，part_read=0）
      assert_eq(info.huffman_work_upper(128, 0), 524288L)
      assert_eq(info.huffman_work_upper(128, 99), 0L)
    }
    Err(msg) => abort("合法的 big-lookup setup 被拒绝: " + msg)
  }
}

///|
/// RT3-02：Huffman 线性查表单符号成本 = 最长码长 × 有效码字数。
test "vorbis setup v3 reports linear huffman scan cost (RT3-02)" {
  // 1M 个码字、最长码长 21 的 ordered codebook（bits 仍只有几百）
  let bits : Array[Int32] = []
  vs_push_bits(bits, 0, 8)
  vs_push_bits(bits, 0x564342, 24)
  vs_push_bits(bits, 1, 16)
  vs_push_bits(bits, 1048576, 24)
  vs_push_bits(bits, 1, 1) // ordered
  vs_push_bits(bits, 0, 5) // 起始码长 1
  let mut z = 1
  while z < 20 {
    vs_push_bits(bits, 0, 21) // 空游程，码长 +1
    z = z + 1
  }
  vs_push_bits(bits, 1048575, 21) // 1048575 个 length=20
  vs_push_bits(bits, 1, 1) // 1 个 length=21
  vs_push_bits(bits, 0, 4) // lookup_type = 0
  vs_bits_time(bits, 0)
  vs_bits_floor1_simple(bits)
  vs_bits_residue(bits, 0, 0, 0, 0)
  vs_bits_mapping(bits, 0, 0, 0, 0)
  vs_bits_modes(bits, 0, 0, 0, 0)
  vs_bits_finish(bits)
  match parse_vorbis_setup_info(vs_packet(bits), 1) {
    Ok(info) => {
      assert_eq(info.max_huffman_scan, 21L * 1048576L)
      // 每包符号上界：1 声道 × floor(2) + 1 × 8 × (0/1 + 1) = 10；× 21×1048576
      assert_eq(info.huffman_work_upper(32, 0), 44040192L)
    }
    Err(msg) => abort("Huffman 扫描上界 setup 被拒绝: " + msg)
  }
}

///|
/// RT4-01：residue 每个 partition 的 VQ 码字数必须是 ceil(ps / VQ dims)，
/// 不是「每 partition 1 个符号」——6.5 KB 构造曾因此低估约 128 倍。
test "vorbis setup v4 counts residue VQ codewords per partition (RT4-01)" {
  let bits : Array[Int32] = []
  vs_push_bits(bits, 1, 8) // 2 个 codebook
  // codebook 0：标量 classbook（d1/e1）
  vs_push_bits(bits, 0x564342, 24)
  vs_push_bits(bits, 1, 16)
  vs_push_bits(bits, 1, 24)
  vs_push_bits(bits, 0, 1)
  vs_push_bits(bits, 0, 1)
  vs_push_bits(bits, 0, 5)
  vs_push_bits(bits, 0, 4)
  // codebook 1：VQ 书 d4/e16、码长全 1（active=16、maxlen=1 → maxScan=16）
  vs_push_bits(bits, 0x564342, 24)
  vs_push_bits(bits, 4, 16)
  vs_push_bits(bits, 16, 24)
  vs_push_bits(bits, 0, 1)
  vs_push_bits(bits, 0, 1)
  let mut e = 0
  while e < 16 {
    vs_push_bits(bits, 0, 5)
    e = e + 1
  }
  vs_push_bits(bits, 0, 4) // lookup_type 0
  vs_bits_time(bits, 0)
  vs_bits_floor1_simple(bits)
  // residue type0, begin=0, end=64, partition_size=64, cascade 8 pass 全引用 book1
  vs_push_bits(bits, 0, 6)
  vs_push_bits(bits, 0, 16)
  vs_push_bits(bits, 0, 24)
  vs_push_bits(bits, 64, 24)
  vs_push_bits(bits, 63, 24)
  vs_push_bits(bits, 0, 6)
  vs_push_bits(bits, 0, 8)
  vs_push_bits(bits, 7, 3)
  vs_push_bits(bits, 1, 1)
  vs_push_bits(bits, 31, 5)
  let mut k = 0
  while k < 8 {
    vs_push_bits(bits, 1, 8)
    k = k + 1
  }
  vs_bits_mapping(bits, 0, 0, 0, 0)
  vs_bits_modes(bits, 0, 0, 0, 0)
  vs_bits_finish(bits)
  match parse_vorbis_setup_info(vs_packet(bits), 1) {
    Ok(info) => {
      // ceil(64 / 4) = 16 个 VQ 码字 / partition / pass / 声道
      assert_eq(info.residue_vq_codewords.length(), 1)
      assert_eq(info.residue_vq_codewords[0], 16)
      // 符号上界：1 声道 × floor(2) + 1 × 1 partition × (1 + 8×16) = 131；
      // 单符号成本 = maxScan = 16 → 131×16 = 2096
      assert_eq(info.huffman_work_upper(64, 0), 2096L)
    }
    Err(msg) => abort("合法 VQ residue setup 被拒绝: " + msg)
  }
}
