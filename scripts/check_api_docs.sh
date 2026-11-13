#!/usr/bin/env bash
# check_api_docs.sh —— 公开 API 文档注释（///）覆盖门禁（D6）
#
# 做什么：
#   1) 在当前工作树运行 `moon info --frozen` 生成全部 `pkg.generated.mbti`；
#   2) 从 `.mbti` 解析全部 pub 符号（pub fn / pub const / pub(all) struct|enum /
#      pub type / pub trait，含 `Type::method`）；这是"公开 API"的唯一依据；
#   3) 扫描非测试源码 `.mbt` 中的 pub 声明，检查紧邻声明上方是否有 `///` 文档正文
#      （`///|` 仅作分隔符不算正文；允许 `#attribute` 行夹在文档与声明之间）；
#   4) 按 .mbti 符号集合统计覆盖率（未找到源码声明的记为 NOT-FOUND），
#      输出覆盖率、阈值、未文档符号清单（含文件:行）。
#
# 阈值：默认覆盖率 ≥95%，且未文档符号数 ≤ --max-gap（默认 0 = 全部必须有文档；
#       D6 登记例外时用 --max-gap 1 显式放宽，并在验收报告登记该缺口）。
#
# 退出码：0 = 达标；1 = 不达标；2 = 工具错误（缺 moon/awk、moon info 失败、无符号等）。
#
# 用法：
#   bash scripts/check_api_docs.sh
#   bash scripts/check_api_docs.sh --threshold 95 --max-gap 0
#   bash scripts/check_api_docs.sh --target-dir _build/api-docs --keep
set -u
export LC_ALL=C

usage() {
  cat <<'EOF'
用法: bash scripts/check_api_docs.sh [选项]

对当前工作树运行 `moon info --frozen` 生成 .mbti，统计 pub 符号的 /// 文档覆盖率。

选项:
  --threshold <pct>   覆盖率阈值（百分比，默认 95）
  --max-gap <n>       允许的未文档符号数上限（默认 0；D6 登记例外时可用 1）
  --target-dir <dir>  moon 构建目录（默认 _build/api-docs）
  --keep              保留本次生成的 pkg.generated.mbti（默认只清理本次新建的）
  -h, --help          显示本帮助

退出码: 0=达标; 1=不达标; 2=工具错误
EOF
}

THRESHOLD="95"
MAX_GAP="0"
TARGET_DIR="_build/api-docs"
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --threshold)  [ $# -ge 2 ] || { echo "ERROR: --threshold 缺参数" >&2; exit 2; }; THRESHOLD="$2"; shift 2 ;;
    --max-gap)    [ $# -ge 2 ] || { echo "ERROR: --max-gap 缺参数" >&2; exit 2; };   MAX_GAP="$2"; shift 2 ;;
    --target-dir) [ $# -ge 2 ] || { echo "ERROR: --target-dir 缺参数" >&2; exit 2; }; TARGET_DIR="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: 未知参数: $1（--help 查看用法）" >&2; exit 2 ;;
  esac
done

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
is_num() { case "$1" in ''|*[!0-9.]*) return 1 ;; *) return 0 ;; esac; }
is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_num "$THRESHOLD" || die "--threshold 非法: $THRESHOLD"
is_int "$MAX_GAP"   || die "--max-gap 非法: $MAX_GAP"

ROOT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" || die "无法定位脚本目录"
cd "$ROOT" || die "无法进入仓库根: $ROOT"

command -v moon >/dev/null 2>&1 || die "找不到 moon 命令（先安装 MoonBit 工具链）"
command -v awk  >/dev/null 2>&1 || die "找不到 awk"
command -v find >/dev/null 2>&1 || die "找不到 find"
[ -f "$ROOT/moon.mod" ] || die "不是 moonmux 仓库根（缺少 moon.mod）: $ROOT"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/moonmux-api-docs.XXXXXX" 2>/dev/null)" || die "mktemp 失败"
LIST_BEFORE="$TMP_DIR/before.txt"
LIST_AFTER="$TMP_DIR/after.txt"
CLEAN_LIST="$TMP_DIR/clean.txt"
EXPECTED="$TMP_DIR/expected.tsv"
DECLS="$TMP_DIR/decls.tsv"
STATS="$TMP_DIR/stats.txt"
UNDOC_TXT="$TMP_DIR/undoc.txt"
: > "$UNDOC_TXT"

list_mbti() {
  ( cd "$ROOT" && find . -name pkg.generated.mbti \
      ! -path './.mooncakes/*' ! -path './_build*' ! -path './_review/*' ! -path './.git/*' \
      2>/dev/null | sed 's|^\./||' | sort )
}
cleanup() {
  if [ "$KEEP" -eq 0 ] && [ -s "$CLEAN_LIST" ]; then
    while IFS= read -r f; do
      case "$f" in "$ROOT"/*) rm -f "$f" 2>/dev/null || true ;; esac
    done < "$CLEAN_LIST"
  fi
  rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

printf '== API 文档覆盖门禁（D6）==\n'
printf '   仓库: %s\n' "$ROOT"
printf '   阈值: 覆盖率 >= %s%%，未文档符号 <= %s\n' "$THRESHOLD" "$MAX_GAP"

list_mbti > "$LIST_BEFORE"

# ---------- 1) moon info 生成 .mbti ----------
INFO_LOG="$TMP_DIR/moon-info.log"
moon info --frozen --target-dir "$TARGET_DIR" > "$INFO_LOG" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  sed -n '1,40p' "$INFO_LOG" >&2
  die "moon info --frozen 失败（exit $rc）"
fi
list_mbti > "$LIST_AFTER"
comm -13 "$LIST_BEFORE" "$LIST_AFTER" > "$CLEAN_LIST" 2>/dev/null || true

# ---------- 2) 解析 .mbti 公开符号（pkgdir、kind、name） ----------
: > "$EXPECTED"
while IFS= read -r mbti; do
  [ -n "$mbti" ] || continue
  pkgdir="$(dirname "$mbti")"
  [ "$pkgdir" = "." ] && pkgdir="."
  awk -v pkg="$pkgdir" '
    function name_after(prefix,   s) { s = $0; sub(prefix, "", s); sub(/[ (].*/, "", s); return s }
    /^pub fn /            { print pkg "\tfn\t"     name_after("^pub fn ");     next }
    /^pub const /         { print pkg "\tconst\t"  name_after("^pub const ");  next }
    /^pub\(all\) struct / { print pkg "\tstruct\t" name_after("^pub\\(all\\) struct "); next }
    /^pub\(all\) enum /   { print pkg "\tstruct\t" name_after("^pub\\(all\\) enum ");   next }
    /^pub struct /        { print pkg "\tstruct\t" name_after("^pub struct "); next }
    /^pub enum /          { print pkg "\tstruct\t" name_after("^pub enum ");   next }
    /^pub type /          { print pkg "\ttype\t"   name_after("^pub type ");   next }
    /^pub trait /         { print pkg "\ttrait\t"  name_after("^pub trait ");  next }
  ' "$ROOT/$mbti" >> "$EXPECTED"
done < "$LIST_AFTER"

TOTAL="$(grep -c . "$EXPECTED" 2>/dev/null || true)"
[ -n "$TOTAL" ] || TOTAL=0
[ "$TOTAL" -gt 0 ] || die "未从 .mbti 解析到任何 pub 符号（moon info 输出异常？）"

# ---------- 3) 扫描非测试源码中的 pub 声明与 /// 文档 ----------
# 单次 find + 单次 awk：输出 "pkgdir kind name doc file:line"
SRC_LIST="$TMP_DIR/src.txt"
( cd "$ROOT" && find . -name '*.mbt' -type f \
    ! -path './.mooncakes/*' ! -path './_build*' ! -path './_review/*' ! -path './.git/*' \
    2>/dev/null | sed 's|^\./||' | grep -vE '_(wb)?test\.mbt$' | sort ) > "$SRC_LIST"

awk -v root="$ROOT" '
  FNR == 1 { delete L; delete buf }
  {
    L[FNR] = $0
    if ($0 !~ /^[ \t]*pub[ (]/) next
    kind = ""; name = ""
    if ($0 ~ /^[ \t]*pub[ \t]+fn[ \t]+/)    { kind = "fn";    name = $0; sub(/^[ \t]*pub[ \t]+fn[ \t]+/, "", name); sub(/[ (].*/, "", name) }
    else if ($0 ~ /^[ \t]*pub[ \t]+const[ \t]+/) { kind = "const"; name = $0; sub(/^[ \t]*pub[ \t]+const[ \t]+/, "", name); sub(/[ =].*/, "", name) }
    else if ($0 ~ /^[ \t]*pub(\(all\))?[ \t]+struct[ \t]+/) { kind = "struct"; name = $0; sub(/^[ \t]*pub(\(all\))?[ \t]+struct[ \t]+/, "", name); sub(/[ ({].*/, "", name) }
    else if ($0 ~ /^[ \t]*pub(\(all\))?[ \t]+enum[ \t]+/)   { kind = "struct"; name = $0; sub(/^[ \t]*pub(\(all\))?[ \t]+enum[ \t]+/, "", name); sub(/[ ({].*/, "", name) }
    else if ($0 ~ /^[ \t]*pub[ \t]+type[ \t]+/)  { kind = "type";  name = $0; sub(/^[ \t]*pub[ \t]+type[ \t]+/, "", name); sub(/[ =].*/, "", name) }
    else if ($0 ~ /^[ \t]*pub[ \t]+trait[ \t]+/) { kind = "trait"; name = $0; sub(/^[ \t]*pub[ \t]+trait[ \t]+/, "", name); sub(/[ {].*/, "", name) }
    if (kind == "" || name == "") next
    # 文档检查：向上找连续的 /// 与 #attribute 行；///| 分隔符不算正文
    doc = 0
    i = FNR - 1
    while (i >= 1) {
      l = L[i]
      if (l ~ /^#[A-Za-z]/) { i--; continue }
      if (l ~ /^\/\/\//) {
        if (l ~ /^\/\/\/[ \t]*[^| \t]/) doc = 1
        i--; continue
      }
      break
    }
    # 包目录：FILENAME - root 前缀，再取 dirname
    f = FILENAME
    gsub(/\\/, "/", f)
    r = root; gsub(/\\/, "/", r)
    if (index(f, r "/") == 1) f = substr(f, length(r) + 2)
    if (index(f, "/") > 0) { p = f; sub(/\/[^\/]*$/, "", p) } else { p = "." }
    print p "\t" kind "\t" name "\t" doc "\t" f ":" FNR
  }
' $(cat "$SRC_LIST") > "$DECLS" 2> "$TMP_DIR/awk.err"
[ -s "$DECLS" ] || { sed -n '1,20p' "$TMP_DIR/awk.err" >&2; die "源码 pub 声明扫描结果为空（awk 失败？）"; }

# ---------- 4) 按 .mbti 期望集合做 join，统计文档覆盖 ----------
awk -F '\t' -v statsf="$STATS" -v undocf="$UNDOC_TXT" '
  FNR == NR {  # DECLS: pkg kind name doc loc
    if ($4 == "1") doc[$1 "|" $2 "|" $3] = 1
    else doc[$1 "|" $2 "|" $3] = 0
    loc[$1 "|" $2 "|" $3] = $5
    next
  }
  { # EXPECTED: pkg kind name
    key = $1 "|" $2 "|" $3
    total++
    if (key in doc) {
      if (doc[key] == 1) documented++
      else { undocumented++; print "NO-DOC\t" $1 "\t" $2 "\t" $3 "\t" loc[key] > undocf }
    } else {
      undocumented++; print "NOT-FOUND\t" $1 "\t" $2 "\t" $3 "\t-" > undocf
    }
  }
  END { printf "%d %d %d\n", total, documented, undocumented > statsf }
' "$DECLS" "$EXPECTED"

read -r TOTAL DOCUMENTED UNDOC_COUNT < "$STATS" || die "统计结果读取失败"
[ -n "${TOTAL:-}" ] || TOTAL=0
[ -n "${DOCUMENTED:-}" ] || DOCUMENTED=0
[ -n "${UNDOC_COUNT:-}" ] || UNDOC_COUNT=0
COVERAGE="$(awk -v d="$DOCUMENTED" -v t="$TOTAL" 'BEGIN { if (t > 0) printf "%.2f", 100.0*d/t; else print "0.00" }')"

# ---------- 5) 汇总 ----------
printf '\n== 结果 ==\n'
printf '   pub 符号: %s；有 /// 文档: %s；未文档: %s；覆盖率: %s%%\n' "$TOTAL" "$DOCUMENTED" "$UNDOC_COUNT" "$COVERAGE"
if [ "$UNDOC_COUNT" -gt 0 ]; then
  printf '   未文档符号（最多列 50 条）:\n'
  head -50 "$UNDOC_TXT" | while IFS="$(printf '\t')" read -r why pkg kind name loc; do
    printf '     - [%s] 包=%s %s %s %s\n' "$why" "${pkg:-<root>}" "$kind" "${name:-}" "${loc:-}"
  done
fi

PASS="$(awk -v c="$COVERAGE" -v th="$THRESHOLD" 'BEGIN { print (c + 0 >= th + 0) ? 1 : 0 }')"
if [ "$PASS" = "1" ] && [ "$UNDOC_COUNT" -le "$MAX_GAP" ]; then
  printf '   PASS: 覆盖率 %s%% >= %s%%，未文档 %s <= %s\n' "$COVERAGE" "$THRESHOLD" "$UNDOC_COUNT" "$MAX_GAP"
  exit 0
fi
printf '   FAIL: 覆盖率 %s%%（阈值 %s%%）或未文档数 %s（上限 %s）不达标\n' "$COVERAGE" "$THRESHOLD" "$UNDOC_COUNT" "$MAX_GAP"
printf '   修复方式：为缺失的 pub 符号补充 `///` 文档注释（见上方清单）。\n'
exit 1
