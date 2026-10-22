///|
/// 清掉 EOS 标志（MoonBit 没有位取反，用 0xFF 异或出掩码）。
fn without_eos(h : Byte) -> Byte {
  (h.to_int() & (0xFF ^ flag_eos().to_int())).to_byte()
}

///|
/// 按粒度区间裁剪一条逻辑流（`chop` 的容器层）。
///
/// 语义是**页精度**：保留与 `[start, end)` 有交集的页，页内不拆分。
/// 因此两端各可能多出不到一页的音频 —— 这比「精确到样本」诚实，也不需要解码。
/// 头页（粒度不大于 0 的前缀）整段保留，否则输出无法解码。
///
/// 数据页的粒度减去起点，让输出从 0 开始计时（与 oggz-chop 一致）；
/// 头页保持 0。页内可能包含起点之前不到一页的音频，因此首包时间可能略小于 0，
/// 这里把它夹到 0。
pub fn chop_pages(
  pages : Array[Page],
  serial : UInt32,
  start : Int64,
  end : Int64,
) -> Result[Array[Page], String] {
  if start < 0L {
    return Err("裁剪起点不能为负")
  }
  if end <= start {
    return Err("裁剪终点必须大于起点")
  }
  // 先判链接流：每段有自己的 serial，否则会被误报成「多逻辑流」。
  if split_chains(pages).length() > 1 {
    return Err(
      "chop 只处理单段文件；链接流请先 split 再逐段裁剪",
    )
  }
  let serials = serials_of(pages)
  if serials.length() != 1 {
    return Err(
      "chop 一次只处理一条逻辑流（当前 " +
      serials.length().to_string() +
      " 条）；多流请先 extract 再用",
    )
  }
  if serials[0] != serial {
    return Err("文件里没有 serial=" + serial.to_string() + " 的逻辑流")
  }
  // 头页：第一条粒度大于 0 的页之前的所有页（OpusHead / OpusTags、Vorbis 三头）
  let mut first_audio = -1
  let mut i = 0
  while i < pages.length() {
    if pages[i].granule_position > 0L {
      first_audio = i
      break
    }
    i = i + 1
  }
  if first_audio < 0 {
    return Err("文件里没有带粒度的音频页，无法按时间裁剪")
  }
  let out : Array[Page] = []
  let mut seq : UInt32 = 0
  let mut j = 0
  while j < first_audio {
    out.push({
      header_type: without_eos(pages[j].header_type),
      granule_position: pages[j].granule_position,
      serial: pages[j].serial,
      sequence: seq,
      crc: 0U,
      segments: pages[j].segments,
      payload: pages[j].payload,
    })
    seq = seq + 1
    j = j + 1
  }
  // 数据页：页的时间范围是 (上一页粒度, 本页粒度]
  // first_audio 可能为 0（第一页就带粒度），此时没有「上一页」，起点按 0 算。
  let mut prev = if first_audio > 0 {
    pages[first_audio - 1].granule_position
  } else {
    0L
  }
  // 终点超过末粒度说明请求区间越界：截短后返回成功会让调用方以为拿到了完整区间
  let mut stream_last = 0L
  for p in pages {
    if p.granule_position > stream_last {
      stream_last = p.granule_position
    }
  }
  if end > stream_last {
    return Err(
      "裁剪终点 " +
      end.to_string() +
      " 超过流的末粒度 " +
      stream_last.to_string() +
      "（按采样数计）",
    )
  }
  let mut kept = 0
  let mut skipping_partial = true
  let mut k = first_audio
  while k < pages.length() {
    let page = pages[k]
    let page_end = page.granule_position
    // 区间重叠：本页结束不早于起点，且上一页结束早于终点
    if page_end >= start && prev < end {
      // 丢掉与上一页共享包的第一页：那个包的开头已经不在输出里了
      if skipping_partial &&
        (page.header_type.to_int() & flag_continued().to_int()) != 0 {
        prev = page_end
        k = k + 1
        continue
      }
      skipping_partial = false
      out.push({
        header_type: without_eos(page.header_type),
        // 减去起点，夹到 0：页精度下首页可能包含起点之前的音频
        granule_position: if page_end > start {
          page_end - start
        } else {
          0L
        },
        serial: page.serial,
        sequence: seq,
        crc: 0U,
        segments: page.segments,
        payload: page.payload,
      })
      seq = seq + 1
      kept = kept + 1
    }
    if page_end >= 0L {
      prev = page_end
    }
    k = k + 1
  }
  if kept == 0 {
    return Err("该时间区间内没有音频页")
  }
  // 末页补 EOS：不补的话 verify 会报「缺 EOS」
  let last = out.length() - 1
  out[last] = {
    header_type: out[last].header_type | flag_eos(),
    granule_position: out[last].granule_position,
    serial: out[last].serial,
    sequence: out[last].sequence,
    crc: 0U,
    segments: out[last].segments,
    payload: out[last].payload,
  }
  Ok(out)
}
