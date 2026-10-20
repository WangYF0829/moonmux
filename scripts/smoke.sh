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
BIN="${1:-_build/native/debug/build/cmd/main/main.exe}"
# 临时目录放进 _build（已在 .gitignore 里）：即使脚本被中断，
# 残留也只落在构建目录内，不会污染仓库根目录。
mkdir -p _build
# 被强制中断（SIGKILL / 终端关闭）时 trap 不会执行；把一小时前的遗留清掉，
# 避免残留无限累积。只碰自己命名的目录。
find _build -maxdepth 1 -type d -name 'smoke.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
TMP="$(mktemp -d -p _build smoke.XXXXXX)"
# Windows 上文件句柄释放有延迟，rm -rf 可能第一次删不干净；
# 重试几次，失败也不影响检查结果（下次运行前的陈旧目录清理会兜底）。
cleanup() {
  # Windows 上文件句柄释放有延迟：多试几次，仍失败就留一句提示
  # （目录在 _build/ 内，下一次运行前的陈旧清理会兜底）。
  for _ in 1 2 3 4 5; do
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

"$BIN" demux testdata/opus_sample.opus "$TMP/bom" >/dev/null 2>&1
printf '\xef\xbb\xbf' | cat - "$TMP/bom/s1/manifest.txt" > "$TMP/bom/s1/m2"
mv "$TMP/bom/s1/m2" "$TMP/bom/s1/manifest.txt"
"$BIN" mux "$TMP/bom" "$TMP/bom.ogg" >/dev/null 2>&1
cmp -s "$TMP/bom.ogg" testdata/opus_sample.opus
check $? "带 BOM 的清单被正确剥离（仍逐字节还原）"

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
