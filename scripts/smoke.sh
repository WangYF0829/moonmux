#!/usr/bin/env bash
# smoke.sh —— 端到端冒烟检查
#
# 单元测试（moon test）覆盖的是库逻辑；这份脚本覆盖**命令层**：
# 往返是否逐字节、退出码是否按约定、边界输入是否得体。
# 用法：bash scripts/smoke.sh [path/to/moonmux]
#
# 退出码：0 全部通过；1 有失败项。

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
# Windows 产物是 main.exe，Linux/macOS 是 main —— 自动探测，CI 与本地共用
if [ -n "${1:-}" ]; then
  BIN="$1"
elif [ -x "_build/native/debug/build/cmd/main/main.exe" ]; then
  BIN="_build/native/debug/build/cmd/main/main.exe"
else
  BIN="_build/native/debug/build/cmd/main/main"
fi
# 临时目录放进 _build（已在 .gitignore 里）：即使脚本被中断，
# 残留也只落在构建目录内，不会污染仓库根目录。
mkdir -p _build
# 每个实例只清理自己的目录；不按时间删除其他 smoke.*，避免慢实例被并发清理。
# Windows 原生 CLI 走 @fs，对 Git Bash 的 /tmp 映射目录可能没有创建子目录权限；
# 优先用仓库内相对路径，失败再退回系统临时目录（GNU/BSD mktemp 都接受显式模板）。
TMP="$(mktemp -d _build/smoke.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/moonmux-smoke.XXXXXX" 2>/dev/null || mktemp -d)"
# Windows 上文件句柄释放有延迟，rm -rf 可能第一次删不干净；
# 重试几次，仍失败就明确提示残留路径。
cleanup() {
  # 不清理其他实例的目录；本实例失败时只报告自己的 TMP。
  # 2544 个文件的目录在 Windows 上删除本身要几秒，重试要给足时间
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    rm -rf "$TMP" 2>/dev/null
    [ -d "$TMP" ] || return 0
    sleep 0.5
  done
  echo "注意: 临时目录未能完全删除：$TMP（在 _build 内，已忽略）" >&2
}
trap 'cleanup; exit 130' INT TERM
trap cleanup EXIT
FAIL=0

pass() { printf "  \033[32mPASS\033[0m  %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; FAIL=$((FAIL + 1)); }
check() { if [ "$1" -eq 0 ]; then pass "$2"; else fail "$2"; fi; }

if [ ! -x "$BIN" ]; then
  echo "找不到可执行文件：$BIN（先运行 moon build --target native）"
  exit 1
fi

echo "== 0. 版本与输出类型防护 =="
"$BIN" version | grep -q "moonmux 0.9.2"
check $? "version 与模块版本一致（0.9.2）"
"$BIN" extract testdata/opus_sample.opus 1 "$TMP" >/dev/null 2>&1
[ $? -eq 2 ]; check $? "目录作为输出路径被拒绝（2）"

# Win32 的 @fs 看不见 MSYS FIFO，is_file 也区分不了它；FIFO 断言只在真 POSIX 上跑。
RUN_POSIX_FIFO=0
case "$(uname -s)" in
  Linux|Darwin|FreeBSD) RUN_POSIX_FIFO=1 ;;
esac
if [ "$RUN_POSIX_FIFO" -eq 1 ] && command -v mkfifo >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
  : > "$TMP/fifo-out.ogg"
  mkfifo "$TMP/input.fifo"
  timeout 5 "$BIN" extract "$TMP/input.fifo" 1 "$TMP/fifo-out.ogg" >/dev/null 2>&1
  [ $? -eq 2 ]; check $? "FIFO 输入在预读阶段被拒绝且不阻塞"
  rm -f "$TMP/input.fifo"
  mkfifo "$TMP/output.fifo"
  timeout 5 "$BIN" extract testdata/opus_sample.opus 1 "$TMP/output.fifo" >/dev/null 2>&1
  [ $? -eq 2 ]; check $? "FIFO 输出被拒绝且不阻塞"
  rm -f "$TMP/output.fifo"
else
  echo "  SKIP  FIFO 防护（仅 POSIX 或本机缺少 mkfifo/timeout）"
fi

echo "== 1. 单流往返（逐字节） =="
"$BIN" demux testdata/opus_sample.opus "$TMP/rt1" >/dev/null 2>&1
"$BIN" mux "$TMP/rt1" "$TMP/rt1.ogg" >/dev/null 2>&1
cmp -s "$TMP/rt1.ogg" testdata/opus_sample.opus
check $? "Opus demux→mux 逐字节相同"

"$BIN" demux testdata/vorbis_sample.ogg "$TMP/rt2" >/dev/null 2>&1
"$BIN" mux "$TMP/rt2" "$TMP/rt2.ogg" >/dev/null 2>&1
cmp -s "$TMP/rt2.ogg" testdata/vorbis_sample.ogg
check $? "Vorbis demux→mux 逐字节相同"

echo "== 2. 多流往返与抽流 =="
mkdir -p "$TMP/mix"
cp -r "$TMP/rt1/s1" "$TMP/mix/s1"
cp -r "$TMP/rt2/s1" "$TMP/mix/s2"
"$BIN" mux "$TMP/mix" "$TMP/mix.ogg" >/dev/null 2>&1
PAGES=$("$BIN" info "$TMP/mix.ogg" | grep -o '页数:   [0-9]*' | grep -o '[0-9]*')
[ "$PAGES" = "12" ]; check $? "双流封装为 12 页（实测 $PAGES）"

"$BIN" extract "$TMP/mix.ogg" 1 "$TMP/x1.ogg" >/dev/null 2>&1
cmp -s "$TMP/x1.ogg" testdata/opus_sample.opus
check $? "extract 抽出的第 1 条流与原件逐字节相同"

echo "== 3. chained 往返（逐字节） =="
"$BIN" cat testdata/opus_sample.opus testdata/opus_sample.opus "$TMP/ch.ogg" >/dev/null 2>&1
"$BIN" demux "$TMP/ch.ogg" "$TMP/chd" >/dev/null 2>&1
"$BIN" mux "$TMP/chd" "$TMP/chr.ogg" >/dev/null 2>&1
cmp -s "$TMP/chr.ogg" "$TMP/ch.ogg"
check $? "chained demux→mux 逐字节相同"
[ "$("$BIN" info "$TMP/chr.ogg" | grep -c '^物理流: 2')" = "1" ]
check $? "chained 往返后仍是 2 段物理流"

echo "== 4. 注释读写 =="
"$BIN" tag testdata/vorbis_sample.ogg "$TMP/t.ogg" TITLE=Smoke >/dev/null 2>&1
"$BIN" tags "$TMP/t.ogg" | grep -q "TITLE=Smoke"
check $? "写入的标签能读回"
"$BIN" verify "$TMP/t.ogg" >/dev/null 2>&1
check $? "改过标签的文件结构体检通过"
ORIG=$(wc -c < testdata/vorbis_sample.ogg)
NEW=$(wc -c < "$TMP/t.ogg")
[ "$NEW" -ge "$ORIG" ]; check $? "改标签后文件大小合理（$ORIG → $NEW）"

echo "== 4b. 转码（解码路径）=="
# 单测只覆盖容器层；解码器升级后 to-wav 的输出没有任何自动化校验。
# 这里固定 PCM 字节数（6.00 s @48k 单声道 / 1.00 s @44.1k 双声道），
# 解码器若改变输出，这一项会先失败，提醒人工复核。
"$BIN" to-wav testdata/opus_sample.opus "$TMP/o.wav" >/dev/null 2>&1
[ $? -eq 0 ] && [ "$(wc -c < "$TMP/o.wav")" -eq 576044 ]
check $? "Opus → WAV（576044 字节）"
"$BIN" to-wav testdata/vorbis_sample.ogg "$TMP/v.wav" >/dev/null 2>&1
[ $? -eq 0 ] && [ "$(wc -c < "$TMP/v.wav")" -eq 176444 ]
check $? "Vorbis → WAV（176444 字节）"
"$BIN" to-wav testdata/opus_sample.opus "$TMP/o24.wav" 24 >/dev/null 2>&1
[ $? -eq 0 ] && [ "$(wc -c < "$TMP/o24.wav")" -eq 864044 ]
check $? "Opus → WAV 24 位（864044 字节）"

echo "== 4c. 裁剪 =="
"$BIN" chop testdata/opus_sample.opus "$TMP/chop.ogg" 1000 3000 >/dev/null 2>&1
[ $? -eq 0 ] && [ -s "$TMP/chop.ogg" ]
check $? "chop 输出非空"
"$BIN" info "$TMP/chop.ogg" | grep -q "时长=1.99 秒"
check $? "chop 1000→3000 ms 输出约 2.00 秒（扣 pre-skip 后 1.99）"
"$BIN" verify "$TMP/chop.ogg" 2>/dev/null | grep -q "结构完好"
check $? "chop 结果通过 verify"
"$BIN" chop testdata/opus_sample.opus "$TMP/chop2.ogg" 7000 8000 >/dev/null 2>&1
[ $? -eq 1 ]
check $? "chop 越界区间报数据错误（1）"

"$BIN" dump testdata/opus_sample.opus --hex | head -1 | grep -q '^00000000: 4f67 6753'
check $? "dump --hex 首行与 xxd 兼容"
"$BIN" info testdata/opus_sample.opus --json | grep -q '"format":"ogg"'
check $? "info --json 输出 Ogg 结构"
"$BIN" verify testdata/opus_sample.opus --json | grep -q '"crc_ok":9'
check $? "verify --json 输出 CRC 统计"

echo "== 4d. remux（Ogg → MP4）=="
"$BIN" remux testdata/opus_sample.opus "$TMP/out.m4a" >/dev/null 2>&1
[ $? -eq 0 ] && [ -s "$TMP/out.m4a" ]
check $? "Ogg Opus → MP4 输出非空"
"$BIN" info "$TMP/out.m4a" | grep -q "格式:   MP4"
check $? "info 识别 MP4"
"$BIN" info "$TMP/out.m4a" | grep -q "Opus"
check $? "MP4 信息含 Opus 音轨"
# 前 8 字节应为 size + "ftyp"（不硬编码 size，只断言 fourcc）
head -c 8 "$TMP/out.m4a" | od -An -tx1 | tr -d ' \n' | grep -q "66747970"
check $? "MP4 文件以 ftyp 开头"
"$BIN" remux testdata/vorbis_sample.ogg "$TMP/v.m4a" >/dev/null 2>&1
[ $? -eq 1 ]
check $? "Vorbis 输入被拒绝（仅支持 Ogg Opus，退出 1）"
# 输出扩展名不做限制：容器识别只按内容
"$BIN" remux testdata/opus_sample.opus "$TMP/out-noext" >/dev/null 2>&1
check $? "remux 不依赖输出扩展名"
# 外部对账：ffprobe 能识别出 opus 编码（CI ubuntu 自带；本机可选）
if command -v ffprobe >/dev/null 2>&1; then
  ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1 "$TMP/out.m4a" | grep -q "codec_name=opus"
  check $? "ffprobe 识别 MP4 内 Opus 编码"
else
  echo "  SKIP  ffprobe 外部对账（未安装）"
fi

echo "== 4e. to-ogg（MP4 → Ogg 回读）=="
"$BIN" to-ogg "$TMP/out.m4a" "$TMP/back.ogg" >/dev/null 2>&1
[[ $? -eq 0 ]] && [ -s "$TMP/back.ogg" ]
check $? "MP4 → Ogg 输出非空"
"$BIN" info "$TMP/back.ogg" | grep -q "Opus  声道=1  采样率=48000"
check $? "回读 Ogg 信息含 Opus 1 声道 / 48000 Hz"
"$BIN" verify "$TMP/back.ogg" >/dev/null 2>&1
check $? "回读 Ogg 结构完好（verify → 0）"
# 音频包逐字节还原：与原 Ogg 的 demux 结果对比（跳过 OpusHead/OpusTags）
"$BIN" demux testdata/opus_sample.opus "$TMP/rt-orig" >/dev/null 2>&1
"$BIN" demux "$TMP/back.ogg" "$TMP/rt-back" >/dev/null 2>&1
cmp -s "$TMP/rt-orig/s1/packet_000002.bin" "$TMP/rt-back/s1/packet_000002.bin"
check $? "音频包逐字节还原（首个音频包对比）"
# 非 MP4 输入被拒绝
"$BIN" to-ogg testdata/opus_sample.opus "$TMP/x.ogg" >/dev/null 2>&1
[[ $? -eq 1 ]]
check $? "非 MP4 输入被拒绝（退出 1）"

echo "== 5. 定位 =="
"$BIN" seek testdata/opus_sample.opus 2500 >/dev/null 2>&1
check $? "seek 正常工作"
"$BIN" seek testdata/opus_sample.opus 0 | grep -q "起始时间: 0.00 秒"
check $? "seek 0 落在首个音频页（起始 0.00 秒）"
"$BIN" seek "$TMP/ch.ogg" 500 2 | grep -q "第 2 / 2 段"
check $? "seek 支持按链定位"

echo "== 6. 退出码约定 =="
"$BIN" verify testdata/opus_sample.opus >/dev/null 2>&1
[ $? -eq 0 ]; check $? "verify 完好文件 → 0"
printf 'not an ogg' > "$TMP/junk.bin"
"$BIN" verify "$TMP/junk.bin" >/dev/null 2>&1
[ $? -eq 1 ]; check $? "verify 非 Ogg → 1（校验失败）"
"$BIN" info "$TMP/junk.bin" >/dev/null 2>&1
[ $? -eq 1 ]; check $? "info 非 Ogg → 1（数据校验失败）"
"$BIN" seek "$TMP/missing.ogg" 1 >/dev/null 2>&1
[ $? -eq 2 ]; check $? "seek 文件不存在 → 2"
"$BIN" extract testdata/opus_sample.opus 0 "$TMP/z.ogg" >/dev/null 2>&1
[ $? -eq 2 ]; check $? "extract 序号 0 → 2"

echo "== 7. 边界输入不崩 =="
: > "$TMP/empty.bin"
"$BIN" info "$TMP/empty.bin" >/dev/null 2>&1
[ $? -eq 1 ]; check $? "空文件给数据错误（1）而不是崩溃"
head -c 300 testdata/opus_sample.opus > "$TMP/trunc.ogg"
"$BIN" verify "$TMP/trunc.ogg" | grep -q "处跳过"
check $? "截断文件能报出跳过区间"
"$BIN" verify "$TMP/trunc.ogg" >/dev/null 2>&1
[ $? -eq 1 ]; check $? "截断文件 verify 退出 1"
"$BIN" demux "$TMP/trunc.ogg" "$TMP/td" >/dev/null 2>&1
[ $? -eq 1 ] && [ ! -d "$TMP/td/s1" ]; check $? "截断输入拒绝写半截产物（demux）"
"$BIN" split "$TMP/trunc.ogg" "$TMP/ts" >/dev/null 2>&1
[ $? -eq 1 ]; check $? "截断输入拒绝写半截产物（split）"

echo "== 8. 目录与清单防护 =="
"$BIN" demux testdata/opus_sample.opus "$TMP/rt1" >/dev/null 2>&1
[ $? -eq 2 ]; check $? "向非空目录 demux 被拒绝"

"$BIN" demux testdata/opus_sample.opus "$TMP/single" >/dev/null 2>&1
rm -f "$TMP/single/s1/packet_000100.bin"
"$BIN" mux "$TMP/single" "$TMP/single.ogg" >/dev/null 2>&1
[ $? -eq 1 ]; check $? "单流目录缺包被拒绝"

# 目录外任意文件名硬链接到包成员时，mux 不能借输出覆盖输入。
cp "$TMP/rt1/s1/packet_000000.bin" "$TMP/packet.before"
if ln "$TMP/rt1/s1/packet_000000.bin" "$TMP/packet-alias.ogg" 2>/dev/null; then
  "$BIN" mux "$TMP/rt1" "$TMP/packet-alias.ogg" >/dev/null 2>&1
  [ $? -eq 2 ] && cmp -s "$TMP/rt1/s1/packet_000000.bin" "$TMP/packet.before"
  check $? "mux 拒绝包成员的硬链接别名且不修改输入"
else
  echo "  SKIP  mux 硬链接别名（本机 ln 不支持硬链接）"
fi

"$BIN" demux testdata/opus_sample.opus "$TMP/bom" >/dev/null 2>&1
printf '\xef\xbb\xbf' | cat - "$TMP/bom/s1/manifest.txt" > "$TMP/bom/s1/m2"
mv "$TMP/bom/s1/m2" "$TMP/bom/s1/manifest.txt"
"$BIN" mux "$TMP/bom" "$TMP/bom.ogg" >/dev/null 2>&1
cmp -s "$TMP/bom.ogg" testdata/opus_sample.opus
check $? "带 BOM 的清单被正确剥离（仍逐字节还原）"

# manifest 是目录/管道等非普通文件时属于 I/O 错误（2），不是数据错误（1）
cp -r "$TMP/rt1" "$TMP/mdir"
rm -f "$TMP/mdir/s1/manifest.txt"
mkdir "$TMP/mdir/s1/manifest.txt"
"$BIN" mux "$TMP/mdir" "$TMP/mdir.ogg" >/dev/null 2>&1
[ $? -eq 2 ]; check $? "清单不是普通文件时按 I/O 错误退出（2）"

# 跨段复用 serial 必须被拒绝（RFC 3533 §4）
mkdir -p "$TMP/dup"
cp -r "$TMP/rt1/s1" "$TMP/dup/s1"
sed -i 's/^# serial=.*/# serial=1647431420/' "$TMP/dup/s1/manifest.txt" 2>/dev/null || true
cp -r "$TMP/dup/s1" "$TMP/dup/s2"
"$BIN" mux "$TMP/dup" "$TMP/dup.ogg" >/dev/null 2>&1
[ $? -eq 1 ]; check $? "两段复用同一 serial 被拒绝"


rm -rf "$TMP"
echo
if [ "$FAIL" -eq 0 ]; then
  echo "全部通过"
  exit 0
else
  echo "$FAIL 项失败"
  exit 1
fi
