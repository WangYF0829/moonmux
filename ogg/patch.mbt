// patch.mbt —— 只改一页的两个字段，其余页字节透传
//
// 这是 `oggz-chop` 那类工具的底座：改 8 字节粒度 + 1 字节标志，
// 只重算那一页的 CRC，其它页百分之百原样保留。
// 用它拼出来的工具（EOS 修补、粒度平移、把 -1 规范化）共享同一套逻辑，
// 不必各自重写一遍分页。
//
// 之所以坚持「其余页原样」：改一个字段就让整份文件重新分页，
// 意味着产物与输入无法逐字节对账 —— 出问题时说不清是补丁的锅
// 还是重新分页的锅。

///|
/// 修改第 `index` 页的粒度位置与／或头标志，返回新的页序列。
///
/// 只替换这一页的字段，其余页对象原样复用；页序号一概不动
/// （补丁不改变页数，也就不需要重编号）。CRC 由 `Page::to_bytes`
/// 在序列化时重算，因此补丁后的页天然自洽。
pub fn patch_page(
  pages : Array[Page],
  index : Int32,
  granule? : Int64,
  header? : Byte,
) -> Result[Array[Page], String] {
  if index < 0 || index >= pages.length() {
    return Err(
      "页下标 " +
      index.to_string() +
      " 越界（共 " +
      pages.length().to_string() +
      " 页）",
    )
  }
  let page = pages[index]
  let new_granule = match granule {
    Some(g) => g
    None => page.granule_position
  }
  let new_header = match header {
    Some(h) => h
    None => page.header_type
  }
  let out : Array[Page] = []
  let mut i = 0
  while i < pages.length() {
    if i == index {
      out.push({
        header_type: new_header,
        granule_position: new_granule,
        serial: page.serial,
        sequence: page.sequence,
        crc: 0U,
        segments: page.segments,
        payload: page.payload,
      })
    } else {
      out.push(pages[i])
    }
    i = i + 1
  }
  Ok(out)
}

///|
/// 给某条逻辑流的末页补上 EOS 标志（`oggz-chop` 裁掉尾巴后的常规修补）。
///
/// 找不到该流时返回 Err；该流末页已经有 EOS 时原样返回，不做无谓改动。
pub fn set_eos(
  pages : Array[Page],
  serial : UInt32,
) -> Result[Array[Page], String] {
  let mut last = -1
  let mut i = 0
  while i < pages.length() {
    if pages[i].serial == serial {
      last = i
    }
    i = i + 1
  }
  if last < 0 {
    return Err("文件里没有 serial=" + serial.to_string() + " 的逻辑流")
  }
  if (pages[last].header_type.to_int() & flag_eos().to_int()) != 0 {
    return Ok(pages)
  }
  patch_page(pages, last, header=pages[last].header_type | flag_eos())
}
