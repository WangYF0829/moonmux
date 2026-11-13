#!/usr/bin/env bash
# check_package.sh —— 发布包内容门禁（供应链 / 制品审计）
#
# 校验项（全部只读，除 moon 自身把产物写入 _build/ 外）：
#   1) worktree 必须干净（git status --porcelain 为空）——moon package 会打包未跟踪文件，
#      发布前必须确认没有本地临时产物会混入发布包（mooncakes 发布不可撤回）。
#   2) moon package --list 的发布清单必须与 git 跟踪文件一致：
#        - 清单里的文件必须全部被 git 跟踪（否则说明未跟踪文件入包）；
#        - 被跟踪但不在清单里的文件，只允许是 .moonignore / git 默认排除的文件
#          （点开头路径、*.mbti、_build/、临时目录、测试临时文件等）。
#   3) 发布清单不得包含禁止路径（_build/、_review/、tmp/、out/、*.mbti、*.log、
#      *.zip、*.bak、*.pem、*.key、.env、*.wasm、*.exe、*.dll）。
#   4) 发布文件内容不得命中密钥模式（ghp_/gho_/ghu_/ghs_/github_pat_/sk-/AKIA/PRIVATE KEY）。
#   5) 文件数与 zip 体积在基线范围内（v0.9.3 已发布：86 文件 / 371,067 B；
#      本修复新增 3 个 scripts/ 脚本后预期约 89 文件；单文件不超过 1 MiB）。
#
# 用法：
#   bash scripts/check_package.sh                    # 标准门禁（要求 worktree 干净）
#   bash scripts/check_package.sh --allow-dirty      # 本地调试：跳过第 1 项 worktree 断言
#   bash scripts/check_package.sh --help
#
# 环境变量（可选）：
#   MOONMUX_ROOT          指定仓库根（默认脚本所在目录的上一级；用于在副本中测试）
#   PACKAGE_MIN_FILES     期望发布文件数下限（默认 80）
#   PACKAGE_MAX_FILES     期望发布文件数上限（默认 120）
#   PACKAGE_MIN_ZIP_BYTES zip 体积下限（默认 300000）
#   PACKAGE_MAX_ZIP_BYTES zip 体积上限（默认 800000）
#   PACKAGE_MAX_FILE_BYTES 单文件体积上限（默认 1048576）
#   SECRET_SCAN_PATTERN   覆盖内置密钥正则（grep -E）
#
# 退出码：
#   0  全部门禁通过
#   1  门禁失败（逐项 FAIL 输出原因）
#   2  环境/用法错误（不是 git 仓库、缺 moon、moon package --list 执行失败等）
#
# 说明：本脚本不修改源码；`moon package --list` 会触发一次 check 并生成
#       _build/publish/*.zip（_build/ 已被 .gitignore/.moonignore 排除）。
#       供 CI 接线：直接 `bash scripts/check_package.sh` 即可。
set -u
# pipefail 仅 bash 有；在 POSIX sh（如 busybox ash）下自动跳过，保证可移植。
if [ -n "${BASH_VERSION:-}" ]; then
  set -o pipefail
fi

ROOT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" || { echo "check_package: 无法定位脚本目录" >&2; exit 2; }
if [ -n "${MOONMUX_ROOT:-}" ]; then
  ROOT="$(cd "$MOONMUX_ROOT" 2>/dev/null && pwd)" || { echo "check_package: MOONMUX_ROOT 无效：$MOONMUX_ROOT" >&2; exit 2; }
fi
cd "$ROOT" || { echo "check_package: 无法进入仓库根 $ROOT" >&2; exit 2; }

ALLOW_DIRTY=0
for arg in "$@"; do
  case "$arg" in
    --allow-dirty) ALLOW_DIRTY=1 ;;
    -h|--help)
      sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "check_package: 未知参数：$arg（用 --help 查看用法）" >&2
      exit 2
      ;;
  esac
done

FAIL=0
WARN=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  WARN  %s\n' "$1"; WARN=$((WARN + 1)); }

# ---- 0) 环境检查 ----------------------------------------------------------
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "check_package: 当前目录不是 git 仓库：$ROOT" >&2
  exit 2
fi
if ! command -v moon >/dev/null 2>&1; then
  echo "check_package: 找不到 moon 命令（先安装 MoonBit 工具链）" >&2
  exit 2
fi

# 临时目录：优先系统 TMPDIR，其次仓库内 _build/（Windows/busybox 下 /tmp 不可用时也可用）。
TMP_DIR=""
for base in "${TMPDIR:-}" "${TEMP:-}" "$ROOT/_build" "."; do
  [ -n "$base" ] || continue
  mkdir -p "$base" 2>/dev/null || continue
  TMP_DIR="$(mktemp -d "$base/moonmux-pkg.XXXXXX" 2>/dev/null)" || TMP_DIR=""
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then break; fi
  TMP_DIR=""
done
if [ -z "$TMP_DIR" ]; then
  TMP_DIR="$ROOT/_build/.check-package.$$"
  mkdir -p "$TMP_DIR" 2>/dev/null || { echo "check_package: 无法创建临时目录（设置 TMPDIR 后重试）" >&2; exit 2; }
fi
cleanup() { rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM

echo "== 发布包内容门禁 =="
echo "仓库根：$ROOT"
echo "HEAD：$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo

# ---- 1) worktree 必须干净 -------------------------------------------------
echo "[1/5] worktree 干净检查"
DIRTY="$(git status --porcelain 2>/dev/null | tr -d '\r')"
if [ -z "$DIRTY" ]; then
  pass "git status --porcelain 为空"
else
  printf '%s\n' "$DIRTY" | sed -n '1,20p' | sed 's/^/        /'
  if [ "$ALLOW_DIRTY" -eq 1 ]; then
    warn "worktree 不干净（--allow-dirty 跳过断言；发布前必须清理）"
  else
    fail "worktree 不干净：moon package 会把未跟踪文件一起打包（发布前先提交/清理）"
  fi
fi
echo

# ---- 2) moon package --list ----------------------------------------------
echo "[2/5] 采集 moon package --list"
RAW="$TMP_DIR/pkg-raw.txt"
# 关闭 -e 语义：显式捕获退出码，避免管道/工具差异吞掉 moon 的失败。
moon package --list >"$RAW" 2>&1
PKG_STATUS=$?
if [ "$PKG_STATUS" -ne 0 ]; then
  echo "check_package: moon package --list 失败（exit $PKG_STATUS），输出末尾：" >&2
  tail -30 "$RAW" >&2
  exit 2
fi
# 过滤 moon 的日志行（与 .github/workflows/ci.yml 的 package gate 保持一致），
# 并把 Windows 反斜杠路径统一成 /，去掉 CR。
sed 's/^Package to .*//' "$RAW" \
  | grep -Ev '^(Package to|Check passed|Finished|Running|Building|$)' \
  | tr -d '\r' \
  | sed 's#\\#/#g' \
  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
  | grep -v '^$' \
  | sort -u >"$TMP_DIR/pkg.txt"
# 注意：Windows 下 git 默认会把非 ASCII 文件名转义成 "\351\241..." 形式，
# 必须关掉 core.quotepath 才能与 moon package --list 的 UTF-8 文件名逐字节比较。
git -c core.quotepath=false ls-files 2>/dev/null | tr -d '\r' | sed 's#\\#/#g' | sort -u >"$TMP_DIR/tracked.txt"

PKG_COUNT="$(wc -l <"$TMP_DIR/pkg.txt" | tr -d ' ')"
TRACKED_COUNT="$(wc -l <"$TMP_DIR/tracked.txt" | tr -d ' ')"
echo "  发布清单：$PKG_COUNT 个文件；git 跟踪：$TRACKED_COUNT 个文件"

# 2a) 发布清单里的文件必须被 git 跟踪
comm -13 "$TMP_DIR/tracked.txt" "$TMP_DIR/pkg.txt" >"$TMP_DIR/pkg-not-tracked.txt"
if [ -s "$TMP_DIR/pkg-not-tracked.txt" ]; then
  fail "发布清单含未跟踪文件（未跟踪文件会随发布永久发布）："
  sed -n '1,20p' "$TMP_DIR/pkg-not-tracked.txt" | sed 's/^/        /'
else
  pass "发布清单全部被 git 跟踪"
fi

# 2b) 被跟踪但未入包的文件，必须是 .moonignore/git 默认排除项
is_packaging_excluded() {
  p="$1"
  case "$p" in
    .*|*/.*) return 0 ;;                                   # 点开头路径默认排除
    *.mbti) return 0 ;;                                    # pkg.generated.mbti / *.mbti
    scripts/measure.py) return 0 ;;                        # 本地开发脚本（.moonignore 显式排除）
    _build/*|*/_build/*|_*/*|*/_*/*) return 0 ;;           # _build/、_build/、_mbuild/ 等
    smoke.*/*|*/smoke.*/*) return 0 ;;
    .workbuddy/*|*/.workbuddy/*) return 0 ;;
    out/*|*/out/*|tmp/*|*/tmp/*|target/*|*/target/*) return 0 ;;
    *.log|*.zip|*.bak|*.pem|*.key|*.wasm|*.exe|*.dll) return 0 ;;
    _*.ogg|_*.wav|_*.bin) return 0 ;;
  esac
  return 1
}
comm -23 "$TMP_DIR/tracked.txt" "$TMP_DIR/pkg.txt" >"$TMP_DIR/tracked-not-pkg.txt"
UNEXPECTED="$TMP_DIR/unexpected-missing.txt"
: >"$UNEXPECTED"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if ! is_packaging_excluded "$f"; then
    printf '%s\n' "$f" >>"$UNEXPECTED"
  fi
done <"$TMP_DIR/tracked-not-pkg.txt"
if [ -s "$UNEXPECTED" ]; then
  fail "以下跟踪文件未入包，且不属于 .moonignore/默认排除项（发布清单可能漏文件）："
  sed -n '1,20p' "$UNEXPECTED" | sed 's/^/        /'
else
  pass "被跟踪但未入包的文件均可由 .moonignore/默认规则解释"
fi
echo

# ---- 3) 禁止路径 ----------------------------------------------------------
echo "[3/5] 禁止路径检查"
FORBIDDEN_RE='(^|/)(_build|_review|_mbuild|_reports|target|out|tmp)/|\.mbti$|\.log$|\.zip$|\.bak$|\.pem$|\.key$|\.p12$|\.env($|\.)|(^|/)\.env$|\.wasm$|\.exe$|\.dll$'
if grep -nE "$FORBIDDEN_RE" "$TMP_DIR/pkg.txt" >"$TMP_DIR/forbidden.txt" 2>/dev/null; then
  fail "发布清单包含禁止路径："
  sed 's/^/        /' "$TMP_DIR/forbidden.txt"
else
  pass "未发现禁止路径（_build/_review/tmp/out/*.mbti/*.log/*.zip/*.bak/*.pem/*.key/.env/*.wasm/*.exe/*.dll）"
fi
echo

# ---- 4) 密钥模式扫描 ------------------------------------------------------
echo "[4/5] 密钥模式扫描（对发布清单内文件内容）"
SECRET_RE='(ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|ghu_[A-Za-z0-9]{20,}|ghs_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY)'
SECRET_HITS="$TMP_DIR/secret-hits.txt"
: >"$SECRET_HITS"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  if grep -IlE "$SECRET_RE" "$f" >>"$SECRET_HITS" 2>/dev/null; then :; fi
done <"$TMP_DIR/pkg.txt"
if [ -s "$SECRET_HITS" ]; then
  fail "发布文件命中密钥模式（只打印文件名，不回显内容）："
  sed 's/^/        /' "$SECRET_HITS"
else
  pass "发布文件未命中密钥模式"
fi
echo

# ---- 5) 基线（文件数 / zip 体积 / 单文件体积） ----------------------------
echo "[5/5] 基线检查"
BASELINE_FILES_REFERENCE=86      # v0.9.3 已发布包文件数
BASELINE_ZIP_BYTES_REFERENCE=371067  # v0.9.3 已发布 zip 体积（sha256 d374f9cf…5631）
BASELINE_FILES_HINT_AFTER_FIX=89 # 增加 scripts/check_package.sh + gen_sbom.sh + check_pii.sh 后预期
PACKAGE_MIN_FILES="${PACKAGE_MIN_FILES:-80}"
PACKAGE_MAX_FILES="${PACKAGE_MAX_FILES:-120}"
PACKAGE_MIN_ZIP_BYTES="${PACKAGE_MIN_ZIP_BYTES:-300000}"
PACKAGE_MAX_ZIP_BYTES="${PACKAGE_MAX_ZIP_BYTES:-800000}"
PACKAGE_MAX_FILE_BYTES="${PACKAGE_MAX_FILE_BYTES:-1048576}"
echo "  参考基线：v0.9.3 发布 $BASELINE_FILES_REFERENCE 文件 / $BASELINE_ZIP_BYTES_REFERENCE B zip；本修复后预期 $BASELINE_FILES_HINT_AFTER_FIX 文件"
echo "  允许范围：文件 $PACKAGE_MIN_FILES..$PACKAGE_MAX_FILES；zip $PACKAGE_MIN_ZIP_BYTES..$PACKAGE_MAX_ZIP_BYTES B；单文件 <= $PACKAGE_MAX_FILE_BYTES B"
echo "  当前：$PKG_COUNT 文件"

if [ "$PKG_COUNT" -lt "$PACKAGE_MIN_FILES" ] || [ "$PKG_COUNT" -gt "$PACKAGE_MAX_FILES" ]; then
  fail "发布文件数 $PKG_COUNT 不在基线范围 $PACKAGE_MIN_FILES..$PACKAGE_MAX_FILES 内"
else
  pass "发布文件数在基线范围内（$PKG_COUNT）"
fi

# 单文件体积
BIG="$TMP_DIR/big-files.txt"
: >"$BIG"
MAX_FILE_BYTES=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  sz="$(wc -c <"$f" 2>/dev/null | tr -d ' ')"
  case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
  if [ "$sz" -gt "$MAX_FILE_BYTES" ]; then MAX_FILE_BYTES="$sz"; fi
  if [ "$sz" -gt "$PACKAGE_MAX_FILE_BYTES" ]; then
    printf '%s (%s B)\n' "$f" "$sz" >>"$BIG"
  fi
done <"$TMP_DIR/pkg.txt"
if [ -s "$BIG" ]; then
  fail "以下发布文件超过单文件体积上限 ${PACKAGE_MAX_FILE_BYTES} B："
  sed 's/^/        /' "$BIG"
else
  pass "单文件最大 $MAX_FILE_BYTES B（<= $PACKAGE_MAX_FILE_BYTES B）"
fi

# zip 体积与 sha256（moon package --list 会生成 _build/publish/*.zip）
LATEST_ZIP="$(ls -t _build/publish/*.zip 2>/dev/null | head -n 1)"
if [ -n "$LATEST_ZIP" ] && [ -f "$LATEST_ZIP" ]; then
  ZIP_BYTES="$(wc -c <"$LATEST_ZIP" | tr -d ' ')"
  echo "  发布 zip：$LATEST_ZIP（$ZIP_BYTES B）"
  if command -v sha256sum >/dev/null 2>&1; then
    echo "  zip sha256：$(sha256sum "$LATEST_ZIP" | awk '{print $1}')"
  fi
  if [ "$ZIP_BYTES" -lt "$PACKAGE_MIN_ZIP_BYTES" ] || [ "$ZIP_BYTES" -gt "$PACKAGE_MAX_ZIP_BYTES" ]; then
    fail "发布 zip 体积 $ZIP_BYTES B 不在基线范围 $PACKAGE_MIN_ZIP_BYTES..$PACKAGE_MAX_ZIP_BYTES 内"
  else
    pass "发布 zip 体积在基线范围内（$ZIP_BYTES B）"
  fi
else
  warn "未找到 _build/publish/*.zip，跳过 zip 体积基线（先运行 moon package）"
fi
echo

if [ "$FAIL" -eq 0 ]; then
  echo "check_package: 全部通过（$PKG_COUNT 文件，WARN=$WARN）"
  exit 0
fi
echo "check_package: $FAIL 项失败（WARN=$WARN）"
exit 1
