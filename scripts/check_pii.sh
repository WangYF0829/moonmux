#!/usr/bin/env bash
# check_pii.sh —— 发布前 PII（个人信息）扫描
#
# 背景：v0.9.2 之前 `项目申报书.md` 曾把作者手机号/QQ 邮箱写进仓库并随
#       0.2.0–0.9.1 发布包永久发布（mooncakes 不能单版本撤回）；本脚本把
#       “发布前 PII 零命中”固化为可执行检查，供发布检查单/CI 引用。
#
# 扫描规则（grep -E，均带数字边界以减少误报）：
#   1) 中国大陆手机号： (^|[^0-9])1[3-9][0-9]{9}([^0-9]|$)
#   2) 邮箱地址：        [A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}
#   3) QQ 号/QQ 邮箱：   [1-9][0-9]{4,11}@qq\.com
#   4) 居民身份证号：    (^|[^0-9])[1-9][0-9]{16}[0-9Xx]([^0-9]|$)
#   输出只给 文件:行 与脱敏后的片段（数字/邮箱被 <...> 替换），不回显完整 PII。
#
# 用法：
#   bash scripts/check_pii.sh                 # 当前工作树（git 跟踪文件）——发布门禁默认模式
#   bash scripts/check_pii.sh --history       # 追加 git 全历史扫描（审计用；历史模式失败不代表当前树有问题）
#   bash scripts/check_pii.sh --history --max-commits 20   # 历史模式只扫最近 N 个 commit（调试/提速）
#   bash scripts/check_pii.sh --paths "docs README.md"      # 只扫指定路径
#   bash scripts/check_pii.sh --help
#
# 环境变量：MOONMUX_ROOT 指定仓库根（默认脚本上一级目录；用于在副本中测试）
#
# 退出码：
#   0  未命中 PII
#   1  命中 PII（发布门禁必须失败；历史模式命中属已知历史遗留，见 _review/fix/supply.md）
#   2  环境/用法错误（不是 git 仓库、参数非法等）
set -u
if [ -n "${BASH_VERSION:-}" ]; then
  set -o pipefail
fi

ROOT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" || { echo "check_pii: 无法定位脚本目录" >&2; exit 2; }
if [ -n "${MOONMUX_ROOT:-}" ]; then
  ROOT="$(cd "$MOONMUX_ROOT" 2>/dev/null && pwd)" || { echo "check_pii: MOONMUX_ROOT 无效：$MOONMUX_ROOT" >&2; exit 2; }
fi
cd "$ROOT" || { echo "check_pii: 无法进入仓库根 $ROOT" >&2; exit 2; }

HISTORY=0
MAX_COMMITS=0
PATHS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --history) HISTORY=1; shift ;;
    --max-commits) MAX_COMMITS="${2:-0}"; shift 2 ;;
    --max-commits=*) MAX_COMMITS="${1#--max-commits=}"; shift ;;
    --paths) PATHS="${2:-}"; shift 2 ;;
    --paths=*) PATHS="${1#--paths=}"; shift ;;
    -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "check_pii: 未知参数：$1（用 --help 查看用法）" >&2; exit 2 ;;
  esac
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "check_pii: 当前目录不是 git 仓库：$ROOT" >&2
  exit 2
fi

# 临时目录：优先 TMPDIR，其次仓库内 _build/（Windows/busybox 下 /tmp 不可用时可用）。
TMP_DIR=""
for base in "${TMPDIR:-}" "${TEMP:-}" "$ROOT/_build" "."; do
  [ -n "$base" ] || continue
  mkdir -p "$base" 2>/dev/null || continue
  TMP_DIR="$(mktemp -d "$base/moonmux-pii.XXXXXX" 2>/dev/null)" || TMP_DIR=""
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then break; fi
  TMP_DIR=""
done
if [ -z "$TMP_DIR" ]; then
  TMP_DIR="$ROOT/_build/.check-pii.$$"
  mkdir -p "$TMP_DIR" 2>/dev/null || { echo "check_pii: 无法创建临时目录（设置 TMPDIR 后重试）" >&2; exit 2; }
fi
cleanup() { rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM

PHONE='(^|[^0-9])1[3-9][0-9]{9}([^0-9]|$)'
EMAIL='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
QQ='[1-9][0-9]{4,11}@qq\.com'
IDCARD='(^|[^0-9])[1-9][0-9]{16}[0-9Xx]([^0-9]|$)'
ALL="($PHONE)|($EMAIL)|($QQ)|($IDCARD)"

# 脱敏：先替换邮箱，再把 7 位以上连续数字替换掉（避免在日志/CI 里二次扩散 PII）。
mask() {
  sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g' \
    | sed -E 's/[0-9Xx]{7,}/<digits>/g'
}

echo "== PII 扫描（手机号/邮箱/QQ/身份证）=="
echo "仓库根：$ROOT"
echo "HEAD：$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
HITS=0

# ---- 1) 当前工作树（git 跟踪文件；git grep 读工作区内容，含未提交修改） ----
echo
echo "[1/2] 当前工作树"
if [ -n "$PATHS" ]; then
  # shellcheck disable=SC2086  # 允许按空格拆分多个路径
  TREE_OUT="$(git -c core.quotepath=false grep -nEI -e "$ALL" -- $PATHS 2>/dev/null)"
else
  TREE_OUT="$(git -c core.quotepath=false grep -nEI -e "$ALL" -- . 2>/dev/null)"
fi
if [ -n "$TREE_OUT" ]; then
  echo "  当前工作树命中 PII："
  printf '%s\n' "$TREE_OUT" | mask | sed -n '1,50p' | sed 's/^/        /'
  COUNT_TREE="$(printf '%s\n' "$TREE_OUT" | grep -c .)"
  echo "  命中行数：$COUNT_TREE"
  HITS=$((HITS + COUNT_TREE))
else
  echo "  PASS  当前工作树 0 命中"
fi

# ---- 2) 可选：git 全历史 ----
if [ "$HISTORY" -eq 1 ]; then
  echo
  echo "[2/2] git 历史（git log -p --all 审计；已知 0.2.0–0.9.1 申报书含手机号/QQ 邮箱）"
  REV_LIST="$(git rev-list --all 2>/dev/null)"
  if [ "$MAX_COMMITS" -gt 0 ]; then
    REV_LIST="$(printf '%s\n' "$REV_LIST" | head -n "$MAX_COMMITS")"
  fi
  TOTAL_COMMITS="$(printf '%s\n' "$REV_LIST" | grep -c .)"
  echo "  扫描 commit 数：$TOTAL_COMMITS"
  HIST_HITS=0
  TMP_HIST="$TMP_DIR/history-hits.txt"
  : >"$TMP_HIST"
  for c in $REV_LIST; do
    out="$(git -c core.quotepath=false grep -nEI -e "$ALL" "$c" -- . 2>/dev/null)"
    # 指定 revision 时 git grep 输出已带 commit 前缀（<commit>:<path>:<line>:<content>）；
    # 先脱敏命中行再收集（否则 16 进制 hash 里的长数字串也会被 <digits> 吞掉）。
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | mask >>"$TMP_HIST"
    fi
  done
  if [ -s "$TMP_HIST" ]; then
    echo "  历史命中 PII（commit:path:line；已脱敏）："
    sed -n '1,30p' "$TMP_HIST" | sed 's/^/        /'
    HIST_HITS="$(grep -c . "$TMP_HIST")"
    echo "  历史命中行数：$HIST_HITS（commit × 文件 × 行 口径）"
    HITS=$((HITS + HIST_HITS))
  else
    echo "  PASS  历史 0 命中"
  fi
  rm -f "$TMP_HIST"
else
  echo
  echo "[2/2] git 历史扫描：未启用（加 --history 开启；发布审计建议在 tag 冻结后跑一次并留档）"
fi

echo
if [ "$HITS" -eq 0 ]; then
  echo "check_pii: 通过（0 命中）"
  exit 0
fi
echo "check_pii: 命中 $HITS 处 PII（脱敏展示）"
if [ "$HISTORY" -eq 1 ] && [ "$HITS" -gt 0 ]; then
  echo "check_pii: 注意——历史命中不影响当前树门禁结论，但会随 git 历史保留；"
  echo "           发布旧版本/重写历史前请人工确认（详见 _review/fix/supply.md 的 PII 处置建议）。"
fi
exit 1
