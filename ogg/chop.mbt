///|
/// 清掉 EOS 标志（MoonBit 没有位取反，用 0xFF 异或出掩码）。
fn without_eos(h : Byte) -> Byte {
  (h.to_int() & (0xFF ^ flag_eos().to_int())).to_byte()
}

///|
/// `before` 之前（不含）最近一个带段表的页；0 段页对包边界透明。
fn previous_with_segments(pages : Array[Page], before : Int32) -> Int32 {
  let mut i = before - 1
  while i >= 0 {
    if pages[i].segments.length() > 0 {
      return i
    }
    i = i - 1
  }
  -1
}

///|
/// `upto`（含）之前最近一个带段表的页。
fn last_with_segments(pages : Array[Page], upto : Int32) -> Int32 {
  let mut i = upto
  while i >= 0 {
    if pages[i].segments.length() > 0 {
      return i
    }
    i = i - 1
  }
  -1
}

///|
/// 每页的有效结束时间：没有包结束的页沿用其后第一条真粒度。
/// 选页时用它判断时间交集，写回时仍保留原来的 -1。
fn effective_page_ends(
  pages : Array[Page],
  stream_last : Int64,
) -> Array[Int64] {
  let ends = Array::make(pages.length(), -1L)
  let mut next = stream_last
  let mut i = pages.length() - 1
  while i >= 0 {
    if pages[i].granule_position >= 0L {
      next = pages[i].granule_position
    }
    ends[i] = next
    i = i - 1
  }
  ends
}

///|
/// 按粒度区间裁剪一条逻辑流（`chop` 的容器层）。
///
/// 语义是**页精度**：保留与 `[start, end)` 有交集的页，页内不拆分。
/// 因此两端各可能多出不到一页的音频 —— 这比「精确到样本」诚实，也不需要解码。
/// 头页（粒度不大于 0 的前缀）整段保留，否则输出无法解码。
///
/// 数据页按第一张实际保留页之前的粒度重基，让输出从 0 开始计时；
/// 头页保持 0。不能直接用请求的 start 减：页内不拆包，那样会让 Opus
/// 首页粒度小于该页实际携带的样本数。
///
/// `header_packets` 是编码层已知的头部包数（Opus 2、Vorbis 3）。
/// 提供时，若首音频页之前已结束全部头包，则该页上的多个完成包都是音频，
/// 可安全排除；不提供时只能保守判断，宁拒绝也不静默丢头包。
pub fn chop_pages(
  pages : Array[Page],
  serial : UInt32,
  start : Int64,
  end : Int64,
  header_packets? : Int32,
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
  // 头部可能以 0 段页结尾（粒度 -1），取它之前最后一个真实粒度作为基准；
  // 直接把 -1 当基准会让首页粒度和全部后续页多 1 个采样。
  let mut prev : Int64 = 0L
  let mut hp = 0
  while hp < first_audio {
    if pages[hp].granule_position >= 0L {
      prev = pages[hp].granule_position
    }
    hp = hp + 1
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
  let effective_end = effective_page_ends(pages, stream_last)
  let leading_idx = previous_with_segments(pages, first_audio)
  let leading_part_kept = leading_idx >= 0 &&
    last_segment(pages[leading_idx]) == 255
  let mut kept = 0
  let mut first_audio_kept = false
  let mut prepended = false
  let mut header_chain_used = false
  let mut skipping_partial = true
  let mut rebase : Int64? = None
  let mut last_data_k = -1
  let mut k = first_audio
  while k < pages.length() {
    let page = pages[k]
    let page_end = page.granule_position
    // 选页用有效结束时间：没有包结束的页自身是 -1，但它属于下一个
    // 真实粒度结束的包，不能因为 -1 就整页丢掉。
    if effective_end[k] > start && prev < end {
      let continued = (page.header_type.to_int() & flag_continued().to_int()) !=
        0
      let mut skip = false
      if skipping_partial && continued {
        let prev_idx = previous_with_segments(pages, k)
        let starts_earlier = prev_idx >= 0 &&
          last_segment(pages[prev_idx]) == 255
        if !starts_earlier {
          // 没有开头的孤儿续页
          skip = true
        } else {
          // 找到这个跨页包最早的一页，确保输出从包开头开始。
          let mut packet_start = prev_idx
          let mut walking = true
          while walking &&
                packet_start > 0 &&
                !has_completion(pages[packet_start]) &&
                (
                  pages[packet_start].header_type.to_int() &
                  flag_continued().to_int()
                ) !=
                0 {
            let before = previous_with_segments(pages, packet_start)
            if before >= 0 && last_segment(pages[before]) == 255 {
              packet_start = before
            } else {
              walking = false
            }
          }
          if packet_start < first_audio {
            // 包开头已经在保留的头页里
            header_chain_used = true
          } else {
            // 起点页因边界被排除，但其后续仍与区间相交：把整包作为预卷保留。
            let mut q = packet_start
            while q < k {
              let src = pages[q]
              out.push({
                header_type: without_eos(src.header_type),
                granule_position: if src.granule_position >= 0L {
                  0L
                } else {
                  -1L
                },
                serial: src.serial,
                sequence: seq,
                crc: 0U,
                segments: src.segments,
                payload: src.payload,
              })
              seq = seq + 1
              q = q + 1
            }
            if k > packet_start {
              prepended = true
            }
          }
        }
      }
      if skip {
        if page_end >= 0L {
          prev = page_end
        }
        k = k + 1
        continue
      }
      skipping_partial = false
      let base = match rebase {
        Some(b) => b
        None => {
          rebase = Some(prev)
          prev
        }
      }
      out.push({
        header_type: without_eos(page.header_type),
        // 有真粒度的页按首张保留页之前的粒度重基；无完成页保持 -1。
        granule_position: if page_end < 0L {
          -1L
        } else if page_end > base {
          page_end - base
        } else {
          0L
        },
        serial: page.serial,
        sequence: seq,
        crc: 0U,
        segments: page.segments,
        payload: page.payload,
      })
      if k == first_audio {
        first_audio_kept = true
      }
      last_data_k = k
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
  // 末页若停在跨页包中间，向后补齐到包结束，最多多出一页。
  let mut extending = true
  while extending && last_data_k >= 0 {
    let terminal = last_with_segments(pages, last_data_k)
    if terminal < 0 || last_segment(pages[terminal]) != 255 {
      extending = false
    } else {
      let mut next = last_data_k + 1
      while next < pages.length() && pages[next].segments.length() == 0 {
        next = next + 1
      }
      if next >= pages.length() {
        return Err(
          "跨页音频包在文件末尾仍未结束，无法安全裁剪",
        )
      }
      let src = pages[next]
      let base = match rebase {
        Some(b) => b
        None => 0L
      }
      out.push({
        header_type: without_eos(src.header_type),
        granule_position: if src.granule_position < 0L {
          -1L
        } else if src.granule_position > base {
          src.granule_position - base
        } else {
          0L
        },
        serial: src.serial,
        sequence: seq,
        crc: 0U,
        segments: src.segments,
        payload: src.payload,
      })
      last_data_k = next
      seq = seq + 1
      kept = kept + 1
    }
  }
  // 首张音频页没有保留、也没有作为预卷补回时，若它同时含有完整头包，
  // 按页裁剪无法既保头又丢音频，明确报错而不是静默丢掉 OpusTags。
  if !first_audio_kept && !prepended && !header_chain_used {
    let fa = pages[first_audio]
    let mut completions = 0
    for seg in fa.segments {
      if seg < 255 {
        completions = completions + 1
      }
    }
    let trailing_incomplete = fa.segments.length() > 0 &&
      last_segment(fa) == 255
    let headers_on_page = match header_packets {
      Some(expected) => {
        // 头包都已在前面页结束，则首音频页上的多个完整包都是音频，剔除安全。
        let mut before = 0
        let mut bi = 0
        while bi < first_audio {
          for seg in pages[bi].segments {
            if seg < 255 {
              before = before + 1
            }
          }
          bi = bi + 1
        }
        before < expected
      }
      // 容器层不知道编码格式时，只能保守判断：多个完整包或尾部半包
      // 都可能意味着头包与音频共用该页。
      None => completions > 1 || (completions > 0 && trailing_incomplete)
    }
    if headers_on_page {
      return Err(
        "首个音频页与头包/跨页音频共用页面，当前起点无法按页安全裁剪",
      )
    }
  }
  // 头页里若有跨页包、而其续页没有被选中，只允许删除不含完整包的纯半包页。
  if leading_part_kept && !first_audio_kept && !prepended && !header_chain_used {
    let mut header_end = first_audio
    let mut q = header_end - 1
    while q >= 0 {
      if pages[q].segments.length() == 0 {
        q = q - 1
        continue
      }
      if last_segment(pages[q]) != 255 {
        break
      }
      if has_completion(pages[q]) {
        return Err(
          "头页同时含有完整头包和跨页音频片段，无法按页安全裁剪",
        )
      }
      header_end = q
      q = q - 1
    }
    let trimmed : Array[Page] = []
    let mut ti = 0
    while ti < header_end {
      trimmed.push(out[ti])
      ti = ti + 1
    }
    // 跳过被裁掉的半包头页；数据页从 first_audio 开始。
    ti = first_audio
    while ti < out.length() {
      trimmed.push(out[ti])
      ti = ti + 1
    }
    out.clear()
    for p in trimmed {
      out.push(p)
    }
  }
  // 头部可能被裁掉若干半包页，统一重编号，避免页序号出现空缺。
  let mut rn = 0
  while rn < out.length() {
    let pg = out[rn]
    out[rn] = {
      header_type: pg.header_type,
      granule_position: pg.granule_position,
      serial: pg.serial,
      sequence: rn.reinterpret_as_uint(),
      crc: 0U,
      segments: pg.segments,
      payload: pg.payload,
    }
    rn = rn + 1
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
