// box.mbt —— ISOBMFF 盒子的底层序列化
//
// ISOBMFF（ISO/IEC 14496-12）把文件组织成嵌套的 box：
//
//   size(4, 大端) | fourcc(4) | payload
//
// size 包含 8 字节头；size == 1 表示 64 位 largesize 跟在 fourcc 后，
// size == 0 表示「到文件末尾」。本实现只写出普通 32 位 box
// （单文件 < 2 GiB，与整个工具的能力边界一致）。
//
// 本文件只提供「写大端整数 / 拼 box」的底层原语，不含容器语义。

///|
/// 把 Int 的低 8 位写成一个字节。
fn push_u8(buf : Buffer, v : Int32) -> Unit {
  buf.write_byte((v & 0xFF).to_byte())
}

///|
/// 大端 16 位。
fn push_u16_be(buf : Buffer, v : Int32) -> Unit {
  push_u8(buf, (v >> 8) & 0xFF)
  push_u8(buf, v & 0xFF)
}

///|
/// 大端 24 位。
fn push_u24_be(buf : Buffer, v : Int32) -> Unit {
  push_u8(buf, (v >> 16) & 0xFF)
  push_u8(buf, (v >> 8) & 0xFF)
  push_u8(buf, v & 0xFF)
}

///|
/// 大端 32 位。
fn push_u32_be(buf : Buffer, v : Int32) -> Unit {
  push_u8(buf, (v >> 24) & 0xFF)
  push_u8(buf, (v >> 16) & 0xFF)
  push_u8(buf, (v >> 8) & 0xFF)
  push_u8(buf, v & 0xFF)
}

///|
/// 写 fourcc（4 个 ASCII 字符；不足补空格）。
fn push_fourcc(buf : Buffer, s : String) -> Unit {
  let mut i = 0
  while i < 4 {
    match s.get_char(i) {
      Some(c) => push_u8(buf, c.to_int())
      None => push_u8(buf, 0x20)
    }
    i = i + 1
  }
}

///|
/// 构造一个普通 box：size + fourcc + payload。
fn box(fourcc : String, payload : Bytes) -> Bytes {
  let out = Buffer(size_hint=8 + payload.length())
  push_u32_be(out, 8 + payload.length())
  push_fourcc(out, fourcc)
  out.write_bytes(payload.exact_view())
  out.to_bytes()
}

///|
/// 构造一个 full box：在 payload 前加 version(1) + flags(3)，再套普通 box。
fn full_box(
  fourcc : String,
  version : Int32,
  flags : Int32,
  payload : Bytes,
) -> Bytes {
  let body = Buffer(size_hint=4 + payload.length())
  push_u8(body, version)
  push_u24_be(body, flags)
  body.write_bytes(payload.exact_view())
  box(fourcc, body.to_bytes())
}

///|
/// 顺序拼接若干字节块。
fn concat(parts : Array[Bytes]) -> Bytes {
  let mut n = 0
  for p in parts {
    n = n + p.length()
  }
  let out = Buffer(size_hint=n)
  for p in parts {
    out.write_bytes(p.exact_view())
  }
  out.to_bytes()
}

///|
/// 把一组 Int 按大端 u32 序列化（用于 entry_count 之后的小数组）。
fn u32_array(values : Array[Int32]) -> Bytes {
  let out = Buffer(size_hint=values.length() * 4)
  for v in values {
    push_u32_be(out, v)
  }
  out.to_bytes()
}
