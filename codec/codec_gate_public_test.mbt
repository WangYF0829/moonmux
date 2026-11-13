// codec_gate_public_test.mbt —— 黑盒测试：Vorbis setup 预检（gate）的公开 API 拒绝分支。
//
// 只使用 codec 包发布出来的公开 API（validate_vorbis_setup / parse_vorbis_id），
// 用 LSB-first 位打包手工构造 Vorbis 线格式，覆盖：同步码、dimensions/entries
// 上限、ordered/sparse 码长表、lookup type 1/2 的位预算等拒绝分支。

///|
/// 把 `value` 的低 `n` 位按 LSB-first 追加到位序列。
fn gate_push_bits(bits : Array[Int32], value : Int32, n : Int32) -> Unit {
  let mut i = 0
  while i < n {
    bits.push((value >> i) & 1)
    i = i + 1
  }
}

///|
/// 把 LSB-first 位序列打包成字节。
fn gate_pack_bits(bits : Array[Int32]) -> Bytes {
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
/// 拼一个 Vorbis setup 包：0x05 + "vorbis" + 位流。
fn gate_setup_packet(bits : Array[Int32]) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(b"\x05vorbis".exact_view())
  buf.write_bytes(gate_pack_bits(bits).exact_view())
  buf.to_bytes()
}

///|
/// 在 `bits` 后追加单个 codebook 的公共头（sync / dims / entries / ordered / sparse）。
fn gate_book_header(
  bits : Array[Int32],
  dims : Int32,
  entries : Int32,
  ordered : Int32,
  sparse : Int32,
) -> Unit {
  gate_push_bits(bits, 0x564342, 24)
  gate_push_bits(bits, dims, 16)
  gate_push_bits(bits, entries, 24)
  gate_push_bits(bits, ordered, 1)
  if ordered == 0 {
    gate_push_bits(bits, sparse, 1)
  }
}

///|
/// 拼一个 30 字节的 Vorbis 识别头（公开字段布局见 Vorbis I §4.2.2）。
fn gate_vorbis_id(
  channels : Int32,
  sample_rate : Int32,
  block0 : Int32,
  block1 : Int32,
  framing : Int32,
) -> Bytes {
  let buf = Buffer()
  buf.write_byte((0x01 : Byte))
  buf.write_bytes(b"vorbis".exact_view())
  // version = 0
  buf.write_bytes(b"\x00\x00\x00\x00".exact_view())
  buf.write_byte(channels.to_byte())
  // sample_rate = u32 LE
  buf.write_byte((sample_rate % 256).to_byte())
  buf.write_byte((sample_rate / 256 % 256).to_byte())
  buf.write_byte((sample_rate / 65536 % 256).to_byte())
  buf.write_byte((sample_rate / 16777216 % 256).to_byte())
  // 三个 bitrate 字段 = 0（12 字节）
  buf.write_bytes(
    b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".exact_view(),
  )
  buf.write_byte((block0 | (block1 << 4)).to_byte())
  buf.write_byte(framing.to_byte())
  buf.to_bytes()
}

///|
test "public api: parse_vorbis_id rejects illegal identification headers" {
  let ok = gate_vorbis_id(2, 44100, 8, 11, 1)
  assert_eq(ok.length(), 30)
  match @codec.parse_vorbis_id(ok) {
    Some(info) => {
      assert_eq(info.codec, "Vorbis")
      assert_eq(info.channels, 2)
      assert_eq(info.sample_rate, 44100)
    }
    None => assert_true(false)
  }
  // 声道数为 0
  assert_true(
    @codec.parse_vorbis_id(gate_vorbis_id(0, 44100, 8, 11, 1)) is None,
  )
  // 采样率为 0
  assert_true(@codec.parse_vorbis_id(gate_vorbis_id(2, 0, 8, 11, 1)) is None)
  // block size 越界（合法范围 6..13，且 block0 <= block1）
  assert_true(
    @codec.parse_vorbis_id(gate_vorbis_id(2, 44100, 5, 11, 1)) is None,
  )
  assert_true(
    @codec.parse_vorbis_id(gate_vorbis_id(2, 44100, 8, 14, 1)) is None,
  )
  assert_true(
    @codec.parse_vorbis_id(gate_vorbis_id(2, 44100, 11, 8, 1)) is None,
  )
  // framing 标志必须为 1
  assert_true(
    @codec.parse_vorbis_id(gate_vorbis_id(2, 44100, 8, 11, 0)) is None,
  )
}

///|
test "public api: setup gate rejects truncation at every field" {
  // 只有 codebook 计数（8 位），没有同步码
  assert_true(
    @codec.validate_vorbis_setup(gate_setup_packet([0, 0, 0, 0, 0, 0, 0, 0]))
    is Err(_),
  )
  // 同步码错误
  let wrong_sync : Array[Int32] = []
  gate_push_bits(wrong_sync, 0, 8)
  gate_push_bits(wrong_sync, 0x111111, 24)
  assert_true(
    @codec.validate_vorbis_setup(gate_setup_packet(wrong_sync)) is Err(_),
  )
  // dimensions 截断：同步码之后只剩 8 位
  let cut_dims : Array[Int32] = []
  gate_push_bits(cut_dims, 0, 8)
  gate_push_bits(cut_dims, 0x564342, 24)
  gate_push_bits(cut_dims, 1, 8)
  assert_true(
    @codec.validate_vorbis_setup(gate_setup_packet(cut_dims)) is Err(_),
  )
  // entries 截断：dimensions 之后只剩 8 位
  let cut_entries : Array[Int32] = []
  gate_push_bits(cut_entries, 0, 8)
  gate_push_bits(cut_entries, 0x564342, 24)
  gate_push_bits(cut_entries, 1, 16)
  gate_push_bits(cut_entries, 1, 8)
  assert_true(
    @codec.validate_vorbis_setup(gate_setup_packet(cut_entries)) is Err(_),
  )
  // ordered 标志截断
  let cut_ordered : Array[Int32] = []
  gate_push_bits(cut_ordered, 0, 8)
  gate_push_bits(cut_ordered, 0x564342, 24)
  gate_push_bits(cut_ordered, 1, 16)
  gate_push_bits(cut_ordered, 1, 24)
  assert_true(
    @codec.validate_vorbis_setup(gate_setup_packet(cut_ordered)) is Err(_),
  )
  // sparse 标志截断（ordered = 0 之后没有位）
  let cut_sparse : Array[Int32] = []
  gate_push_bits(cut_sparse, 0, 8)
  gate_push_bits(cut_sparse, 0x564342, 24)
  gate_push_bits(cut_sparse, 1, 16)
  gate_push_bits(cut_sparse, 1, 24)
  gate_push_bits(cut_sparse, 0, 1)
  assert_true(
    @codec.validate_vorbis_setup(gate_setup_packet(cut_sparse)) is Err(_),
  )
}

///|
test "public api: setup gate rejects oversized dims / entries and bad ordered runs" {
  // entries 超过 1048576 上限
  let big_entries : Array[Int32] = []
  gate_push_bits(big_entries, 0, 8)
  gate_book_header(big_entries, 1, 1048577, 0, 0)
  assert_true(
    @codec.validate_vorbis_setup(gate_setup_packet(big_entries)) is Err(_),
  )
  // ordered 起始码长截断
  let cut_start : Array[Int32] = []
  gate_push_bits(cut_start, 0, 8)
  gate_book_header(cut_start, 1, 6, 1, 0)
  assert_true(
    @codec.validate_vorbis_setup(gate_setup_packet(cut_start)) is Err(_),
  )
  // ordered 游程截断（起始码长之后没有游程位）
  let cut_run : Array[Int32] = []
  gate_push_bits(cut_run, 0, 8)
  gate_book_header(cut_run, 1, 6, 1, 0)
  gate_push_bits(cut_run, 0, 5)
  assert_true(
    @codec.validate_vorbis_setup(gate_setup_packet(cut_run)) is Err(_),
  )
  // ordered 游程一直为 1，长度超过 32 仍未覆盖 entries
  let long_runs : Array[Int32] = []
  gate_push_bits(long_runs, 0, 8)
  gate_book_header(long_runs, 1, 100, 1, 0)
  gate_push_bits(long_runs, 0, 5)
  let mut left = 100
  let mut round = 0
  while round < 33 {
    gate_push_bits(long_runs, 1, gate_ilog(left))
    left = left - 1
    round = round + 1
  }
  assert_true(
    @codec.validate_vorbis_setup(gate_setup_packet(long_runs)) is Err(_),
  )
}

///|
/// 与 codec 包内部同义的 ilog（位宽），测试里独立实现。
fn gate_ilog(v : Int32) -> Int32 {
  let mut x = v
  let mut n = 0
  while x > 0 {
    n = n + 1
    x = x >> 1
  }
  n
}

///|
test "public api: setup gate rejects bit-starved and malformed codebooks" {
  // 非 sparse：entries=2 需要 10 位码长，但只给 5 位
  let starved : Array[Int32] = []
  gate_push_bits(starved, 0, 8)
  gate_book_header(starved, 1, 2, 0, 0)
  gate_push_bits(starved, 0, 5)
  assert_true(
    @codec.validate_vorbis_setup(gate_setup_packet(starved)) is Err(_),
  )
  // lookup_type = 3（保留值）
  let reserved : Array[Int32] = []
  gate_push_bits(reserved, 0, 8)
  gate_book_header(reserved, 1, 1, 0, 0)
  gate_push_bits(reserved, 0, 5)
  gate_push_bits(reserved, 3, 4)
  assert_true(
    @codec.validate_vorbis_setup(gate_setup_packet(reserved)) is Err(_),
  )
  // sparse：used 标志与码长表的合法路径
  let sparse_ok : Array[Int32] = []
  gate_push_bits(sparse_ok, 0, 8)
  gate_book_header(sparse_ok, 1, 3, 0, 1)
  gate_push_bits(sparse_ok, 0, 1)
  gate_push_bits(sparse_ok, 1, 1)
  gate_push_bits(sparse_ok, 0, 5)
  gate_push_bits(sparse_ok, 0, 1)
  gate_push_bits(sparse_ok, 0, 4)
  assert_true(
    @codec.validate_vorbis_setup(gate_setup_packet(sparse_ok)) is Ok(_),
  )
}

///|
test "public api: setup gate rejects truncated lookup tables" {
  // 公共前缀：单个 codebook（entries=1，非 sparse）的合法码长 + lookup_type=1
  let base : Array[Int32] = []
  gate_push_bits(base, 0, 8)
  gate_book_header(base, 1, 1, 0, 0)
  gate_push_bits(base, 0, 5)
  gate_push_bits(base, 1, 4)
  // min_value 截断
  assert_true(@codec.validate_vorbis_setup(gate_setup_packet(base)) is Err(_))
  // delta_value 截断
  let after_min = base.copy()
  gate_push_bits(after_min, 0, 32)
  assert_true(
    @codec.validate_vorbis_setup(gate_setup_packet(after_min)) is Err(_),
  )
  // value_bits 截断
  let after_delta = base.copy()
  gate_push_bits(after_delta, 0, 32)
  gate_push_bits(after_delta, 0, 32)
  assert_true(
    @codec.validate_vorbis_setup(gate_setup_packet(after_delta)) is Err(_),
  )
  // sequence 标志截断
  let after_value_bits = base.copy()
  gate_push_bits(after_value_bits, 0, 32)
  gate_push_bits(after_value_bits, 0, 32)
  gate_push_bits(after_value_bits, 0, 4)
  assert_true(
    @codec.validate_vorbis_setup(gate_setup_packet(after_value_bits)) is Err(_),
  )
}

///|
test "public api: setup gate budget checks for lookup type 1" {
  // dimensions = 1：raw = entries，直接走快速路径
  let dims1 : Array[Int32] = []
  gate_push_bits(dims1, 0, 8)
  gate_book_header(dims1, 1, 4, 0, 0)
  gate_push_bits(dims1, 0, 5)
  gate_push_bits(dims1, 0, 5)
  gate_push_bits(dims1, 0, 5)
  gate_push_bits(dims1, 0, 5)
  gate_push_bits(dims1, 1, 4)
  gate_push_bits(dims1, 0, 32)
  gate_push_bits(dims1, 0, 32)
  gate_push_bits(dims1, 0, 4)
  gate_push_bits(dims1, 0, 1)
  gate_push_bits(dims1, 0, 4)
  assert_true(@codec.validate_vorbis_setup(gate_setup_packet(dims1)) is Ok(_))
  // dimensions = 2：走 r^dims <= entries 的循环（10 -> r=3），预算 3 位
  let dims2 : Array[Int32] = []
  gate_push_bits(dims2, 0, 8)
  gate_book_header(dims2, 2, 10, 0, 0)
  let mut i = 0
  while i < 10 {
    gate_push_bits(dims2, 0, 5)
    i = i + 1
  }
  gate_push_bits(dims2, 1, 4)
  gate_push_bits(dims2, 0, 32)
  gate_push_bits(dims2, 0, 32)
  gate_push_bits(dims2, 0, 4)
  gate_push_bits(dims2, 0, 1)
  gate_push_bits(dims2, 0, 3)
  assert_true(@codec.validate_vorbis_setup(gate_setup_packet(dims2)) is Ok(_))
  // dimensions = 17：lookup type 1 只放行 dims <= 16
  let dims17 : Array[Int32] = []
  gate_push_bits(dims17, 0, 8)
  gate_book_header(dims17, 17, 2, 0, 0)
  gate_push_bits(dims17, 0, 5)
  gate_push_bits(dims17, 0, 5)
  gate_push_bits(dims17, 1, 4)
  gate_push_bits(dims17, 0, 32)
  gate_push_bits(dims17, 0, 32)
  gate_push_bits(dims17, 0, 4)
  gate_push_bits(dims17, 0, 1)
  assert_true(@codec.validate_vorbis_setup(gate_setup_packet(dims17)) is Err(_))
}

///|
test "public api: setup gate rejects a lookup table that exceeds the packet" {
  // lookup type 2：raw = entries * dims = 1000 * 4096，预算远超包内位数
  let bits : Array[Int32] = []
  gate_push_bits(bits, 0, 8)
  gate_book_header(bits, 4096, 1000, 0, 0)
  let mut i = 0
  while i < 1000 {
    gate_push_bits(bits, 0, 5)
    i = i + 1
  }
  gate_push_bits(bits, 2, 4)
  gate_push_bits(bits, 0, 32)
  gate_push_bits(bits, 0, 32)
  gate_push_bits(bits, 15, 4)
  gate_push_bits(bits, 0, 1)
  assert_true(@codec.validate_vorbis_setup(gate_setup_packet(bits)) is Err(_))
}
