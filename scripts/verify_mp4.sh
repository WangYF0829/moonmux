#!/usr/bin/env bash
# verify_mp4.sh —— MP4 写侧的独立验证：结构断言 + ffprobe 外部对账
#
# 单元测试（moon test）已经覆盖 box 级结构与合成流往返；这份脚本验证
# **真实音频 + 外部工具**：用 testdata 里的真实 Ogg Opus 做 remux，
# 再用 ffprobe / ffmpeg 证明产物是标准工具认可的 MP4。
#
# 用法: bash scripts/verify_mp4.sh [path/to/moonmux]
# 退出码: 0 通过；1 有失败项；2 前提不满足（未构建 / 样例缺失）

set -u
# ffprobe 未安装时 M4_MS 保持空串；set -u 下引用必须给出默认值。
M4_MS=""
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

BIN="${1:-}"
if [ -z "$BIN" ]; then
  if [ -x "_build/native/debug/build/cmd/main/main.exe" ]; then
    BIN="_build/native/debug/build/cmd/main/main.exe"
  elif [ -x "_build/native/debug/build/cmd/main/main" ]; then
    BIN="_build/native/debug/build/cmd/main/main"
  fi
fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "找不到 native CLI（先运行: moon build --target native），或显式传入路径"
  exit 2
fi
if [ ! -f testdata/opus_sample.opus ]; then
  echo "缺少 testdata/opus_sample.opus"
  exit 2
fi

mkdir -p _build
TMP="$(mktemp -d -p _build verify-mp4.XXXXXX 2>/dev/null || mktemp -d)"
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

FAIL=0
pass() { printf "  PASS  %s\n" "$1"; }
fail() { printf "  FAIL  %s\n" "$1"; FAIL=$((FAIL + 1)); }

echo "== MP4 写侧验证（$BIN）=="

# 1) remux 真实 Opus 文件
"$BIN" remux testdata/opus_sample.opus "$TMP/out.m4a" >/dev/null 2>&1
if [ $? -eq 0 ] && [ -s "$TMP/out.m4a" ]; then
  pass "remux 真实 Ogg Opus → MP4"
else
  fail "remux 真实 Ogg Opus → MP4"
fi

# 2) MP4 结构：偏移 4 处必须是 fourcc "ftyp"
if [ -s "$TMP/out.m4a" ] &&
  head -c 8 "$TMP/out.m4a" | od -An -tx1 | tr -d ' \n' | grep -q "66747970"; then
  pass "MP4 以 ftyp box 开头"
else
  fail "MP4 以 ftyp box 开头"
fi

# 3) 自有读侧识别
"$BIN" info "$TMP/out.m4a" | grep -q "格式:   MP4"
if [ $? -eq 0 ]; then pass "info 识别 MP4"; else fail "info 识别 MP4"; fi
"$BIN" info "$TMP/out.m4a" | grep -q "Opus"
if [ $? -eq 0 ]; then pass "info 报告 Opus 音轨"; else fail "info 报告 Opus 音轨"; fi
"$BIN" info "$TMP/out.m4a" --json | grep -q '"format":"mp4"'
if [ $? -eq 0 ]; then pass "info --json 输出 mp4"; else fail "info --json 输出 mp4"; fi

# 4) 拒绝非 Opus 输入（退出码 1：数据错误，不是用法错误）
"$BIN" remux testdata/vorbis_sample.ogg "$TMP/v.m4a" >/dev/null 2>&1
if [ $? -eq 1 ]; then pass "Vorbis 输入被拒绝（退出 1）"; else fail "Vorbis 输入被拒绝（退出 1）"; fi

# 5) 外部工具对账：ffprobe / ffmpeg
if command -v ffprobe >/dev/null 2>&1; then
  PROBE="$(ffprobe -v error -select_streams a:0 \
    -show_entries stream=codec_name,channels,sample_rate -of default=noprint_wrappers=1 \
    "$TMP/out.m4a" 2>/dev/null)"
  echo "$PROBE" | grep -q "codec_name=opus"
  if [ $? -eq 0 ]; then pass "ffprobe: codec_name=opus"; else fail "ffprobe: codec_name=opus"; fi
  echo "$PROBE" | grep -q "sample_rate=48000"
  if [ $? -eq 0 ]; then pass "ffprobe: sample_rate=48000"; else fail "ffprobe: sample_rate=48000"; fi
  echo "$PROBE" | grep -q "channels=1"
  if [ $? -eq 0 ]; then pass "ffprobe: channels=1"; else fail "ffprobe: channels=1"; fi

  # 时长一致性：MP4（ffprobe）与 Ogg（本项目 info）相差 < 0.2 秒
  M4_MS="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$TMP/out.m4a" 2>/dev/null | awk '{printf "%d", $1*1000}')"
  OGG_MS="$("$BIN" info testdata/opus_sample.opus --json 2>/dev/null | sed -n 's/.*"duration_ms":\([0-9]*\).*/\1/p' | head -1)"
  if [ -n "$M4_MS" ] && [ -n "$OGG_MS" ]; then
    awk -v a="$M4_MS" -v b="$OGG_MS" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 200) }'
    if [ $? -eq 0 ]; then
      pass "时长一致（MP4 ${M4_MS}ms vs Ogg ${OGG_MS}ms，容差 200ms）"
    else
      fail "时长一致（MP4 ${M4_MS}ms vs Ogg ${OGG_MS}ms）"
    fi
  else
    echo "  SKIP  时长一致性（缺少工具输出）"
  fi
else
  echo "  SKIP  ffprobe 对账（未安装 ffmpeg）"
fi

if command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg -v error -i "$TMP/out.m4a" -f null - >/dev/null 2>&1
  if [ $? -eq 0 ]; then pass "ffmpeg 解码 MP4 无错误"; else fail "ffmpeg 解码 MP4 无错误"; fi
else
  echo "  SKIP  ffmpeg 解码（未安装 ffmpeg）"
fi

# 6) 反向闭环：MP4 → Ogg，音频包应逐字节还原
echo
echo "== 6. 反向解封装（MP4 → Ogg）=="
"$BIN" to-ogg "$TMP/out.m4a" "$TMP/back.ogg" >/dev/null 2>&1
if [ $? -eq 0 ] && [ -s "$TMP/back.ogg" ]; then
  pass "to-ogg 输出非空"
else
  fail "to-ogg 输出非空"
fi
"$BIN" verify "$TMP/back.ogg" >/dev/null 2>&1
if [ $? -eq 0 ]; then pass "回读 Ogg verify 通过"; else fail "回读 Ogg verify 通过"; fi
"$BIN" demux testdata/opus_sample.opus "$TMP/rd_orig" >/dev/null 2>&1
"$BIN" demux "$TMP/back.ogg" "$TMP/rd_back" >/dev/null 2>&1
if cmp -s "$TMP/rd_orig/s1/packet_000002.bin" "$TMP/rd_back/s1/packet_000002.bin"; then
  pass "音频包逐字节还原（首个音频包）"
else
  fail "音频包逐字节还原（首个音频包）"
fi
BACK_MS="$("$BIN" info "$TMP/back.ogg" --json 2>/dev/null | sed -n 's/.*"duration_ms":\([0-9]*\).*/\1/p' | head -1)"
if [ -n "${M4_MS:-}" ] && [ -n "$BACK_MS" ]; then
  awk -v a="$M4_MS" -v b="$BACK_MS" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 200) }'
  if [ $? -eq 0 ]; then
    pass "反向时长一致（MP4 ${M4_MS}ms vs Ogg ${BACK_MS}ms）"
  else
    fail "反向时长一致（MP4 ${M4_MS}ms vs Ogg ${BACK_MS}ms）"
  fi
else
  echo "  SKIP  反向时长一致性（缺少工具输出）"
fi
if command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg -v error -i "$TMP/back.ogg" -f null - >/dev/null 2>&1
  if [ $? -eq 0 ]; then pass "ffmpeg 解码回读 Ogg 无错误"; else fail "ffmpeg 解码回读 Ogg 无错误"; fi
else
  echo "  SKIP  ffmpeg 解码回读（未安装 ffmpeg）"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "verify_mp4: 全部通过"
  exit 0
else
  echo "verify_mp4: $FAIL 项失败"
  exit 1
fi
