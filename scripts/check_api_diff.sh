#!/usr/bin/env bash
# check_api_diff.sh —— 公开 API 契约门禁：对上一发布 tag 做 `.mbti` 逐包 diff
#
# 背景：`moon info` 生成的 `pkg.generated.mbti` 是 MoonBit 公开 API 的唯一依据。
# 本脚本把 BASE_REF（默认上一发布 tag）导出为基线树，与当前工作区各运行一次
# `moon info --frozen`，逐包比较 `.mbti`：
#   - 新增公开符号 / 新增包                   → 允许（0.x 下 minor 版可扩展 API）
#   - 删除 / 改签名 / 枚举成员或结构字段变化  → 破坏性（0.x 下应升 minor 并附迁移说明）
#   - `MOONMUX_VERSION` 常量值行              → 白名单（每次发版必然变化 1 行）
#
# 用法:
#   bash scripts/check_api_diff.sh [BASE_REF] [--target-all] [--keep]
#   bash scripts/check_api_diff.sh                  # 默认: git describe --tags --abbrev=0 HEAD^
#   bash scripts/check_api_diff.sh v0.9.3
#   MOONMUX_API_BASE_REF=v0.9.3 bash scripts/check_api_diff.sh
#
# 退出码:
#   0  仅新增或仅白名单差异（含完全无差异）
#   1  出现删除/改签名/枚举值或结构字段变化等破坏性差异
#   2  工具错误（缺少 git/moon/tar/diff、基线不可用、moon info 失败等）
#
# 依赖（Git Bash / ubuntu 自带）: git, moon, tar, diff, find, sed, sort, awk,
# comm, mktemp, cp, rm, grep。
# 说明:
#   * 基线树通过 `git archive` 导出；若仓库根存在 legacy `.mooncakes/`（旧工具链本地缓存）
#     会一并复制，否则基线树直接使用 moon 0.1.x 的全局 registry 缓存（`~/.moon/registry`）
#     并配合 `--frozen`（CI 在 `moon update` + `moon check` 之后运行）。
#   * 当前树直接取工作区内容（包含未提交改动）；本次生成的 `pkg.generated.mbti`
#     与临时 target-dir 在结束时清理，不污染工作区。
#   * 若当前与基线依赖版本不同、基线 `moon info --frozen` 失败，会退回一次非 frozen
#     解析（联网），仍失败则按工具错误退出 2。
set -u
export LC_ALL=C

usage() {
  cat <<'EOF'
用法: bash scripts/check_api_diff.sh [BASE_REF] [--target-all] [--keep]

参数:
  BASE_REF       基线 ref（tag / commit）。默认取 git describe --tags --abbrev=0 HEAD^，
                 也可用环境变量 MOONMUX_API_BASE_REF 指定。

选项:
  --target-all   同时运行 `moon info --target all`，并要求各后端公开接口一致
  --keep         失败排查时保留临时基线树（默认结束时删除）
  -h, --help     显示本帮助

退出码: 0=仅新增/白名单; 1=破坏性 API 变化; 2=工具错误
EOF
}

BASE_REF=""
TARGET_ALL=0
KEEP=0
for arg in "$@"; do
  case "$arg" in
    --target-all) TARGET_ALL=1 ;;
    --keep) KEEP=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) printf 'ERROR: 未知参数: %s\n' "$arg" >&2; exit 2 ;;
    *)
      if [ -z "$BASE_REF" ]; then
        BASE_REF="$arg"
      else
        printf 'ERROR: 只能指定一个 base-ref，多余参数: %s\n' "$arg" >&2
        exit 2
      fi
      ;;
  esac
done

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
log() { printf '%s\n' "$*"; }

ROOT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" || { printf 'ERROR: 无法定位仓库根\n' >&2; exit 2; }
cd "$ROOT" || die "无法进入仓库根 $ROOT"

command -v git >/dev/null 2>&1 || die "找不到 git"
command -v moon >/dev/null 2>&1 || die "找不到 moon（mooncakes 工具链）"
command -v tar >/dev/null 2>&1 || die "找不到 tar"
command -v diff >/dev/null 2>&1 || die "找不到 diff"
command -v awk >/dev/null 2>&1 || die "找不到 awk"
[ -f "$ROOT/moon.mod" ] || die "不是 moonmux 仓库根（缺少 moon.mod）: $ROOT"

if [ -z "$BASE_REF" ]; then
  BASE_REF="${MOONMUX_API_BASE_REF:-}"
fi
if [ -z "$BASE_REF" ]; then
  BASE_REF="$(git -C "$ROOT" describe --tags --abbrev=0 HEAD^ 2>/dev/null || true)"
  [ -n "$BASE_REF" ] || die "无法推断上一发布 tag（HEAD^ 不可 describe）；请显式传入 BASE_REF"
fi
git -C "$ROOT" rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null 2>&1 \
  || die "base-ref 不存在: $BASE_REF"
BASE_COMMIT="$(git -C "$ROOT" rev-parse --short "${BASE_REF}^{commit}")"
CUR_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || printf '?')"
MOON_VER="$(moon version --all 2>/dev/null | sed -n '1p' || true)"
DIRTY="$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"

BASE_PARENT="${TMPDIR:-/tmp}"
BASE_DIR="$(mktemp -d "$BASE_PARENT/moonmux-api-base.XXXXXX" 2>/dev/null)" \
  || die "mktemp 失败（TMPDIR=$BASE_PARENT）"
BASE_GEN_LIST="$(mktemp "$BASE_PARENT/moonmux-api-basegen.XXXXXX" 2>/dev/null)" || die "mktemp 失败"
CUR_PRE_LIST="$(mktemp "$BASE_PARENT/moonmux-api-pre.XXXXXX" 2>/dev/null)" || die "mktemp 失败"
CUR_POST_LIST="$(mktemp "$BASE_PARENT/moonmux-api-post.XXXXXX" 2>/dev/null)" || die "mktemp 失败"
CLEAN_LIST="$(mktemp "$BASE_PARENT/moonmux-api-clean.XXXXXX" 2>/dev/null)" || die "mktemp 失败"
BASE_LIST="$(mktemp "$BASE_PARENT/moonmux-api-baselist.XXXXXX" 2>/dev/null)" || die "mktemp 失败"
CUR_LIST="$(mktemp "$BASE_PARENT/moonmux-api-curlist.XXXXXX" 2>/dev/null)" || die "mktemp 失败"
UNION_LIST="$(mktemp "$BASE_PARENT/moonmux-api-union.XXXXXX" 2>/dev/null)" || die "mktemp 失败"
DIFF_FILE="$(mktemp "$BASE_PARENT/moonmux-api-diff.XXXXXX" 2>/dev/null)" || die "mktemp 失败"
BASE_LOG="$(mktemp "$BASE_PARENT/moonmux-api-baselog.XXXXXX" 2>/dev/null)" || die "mktemp 失败"
CUR_LOG="$(mktemp "$BASE_PARENT/moonmux-api-curlog.XXXXXX" 2>/dev/null)" || die "mktemp 失败"
WARM_LOG="$(mktemp "$BASE_PARENT/moonmux-api-warm.XXXXXX" 2>/dev/null)" || die "mktemp 失败"

CUR_TARGET_NAME="_build_api_diff_tmp"
CUR_TARGET_DIR="$ROOT/$CUR_TARGET_NAME"

cleanup() {
  # 删除当前树本次新生成的 pkg.generated.mbti（保留运行前已存在的）
  if [ -s "$CLEAN_LIST" ]; then
    while IFS= read -r f; do
      rm -f "$f" 2>/dev/null || true
    done < "$CLEAN_LIST"
  fi
  rm -rf "$CUR_TARGET_DIR" 2>/dev/null || true
  if [ "$KEEP" -eq 0 ]; then
    rm -rf "$BASE_DIR" 2>/dev/null || true
    rm -f "$BASE_GEN_LIST" "$CUR_PRE_LIST" "$CUR_POST_LIST" "$CLEAN_LIST" \
      "$BASE_LIST" "$CUR_LIST" "$UNION_LIST" "$DIFF_FILE" "$DIFF_FILE.stat" \
      "$BASE_LOG" "$CUR_LOG" "$WARM_LOG" 2>/dev/null || true
  else
    printf 'INFO: --keep 保留基线树与日志: %s（moon info 日志: %s / %s）\n' \
      "$BASE_DIR" "$BASE_LOG" "$CUR_LOG"
  fi
}
trap cleanup EXIT INT TERM

log "== moonmux 公开 API 契约门禁 =="
log "   基线: $BASE_REF ($BASE_COMMIT)"
log "   当前: HEAD $CUR_COMMIT（工作区未提交改动 $DIRTY 项）"
log "   工具链: ${MOON_VER:-moon 版本未知}"
log ""

# 当前树已有的 pkg.generated.mbti（用于结束后清理本次新生成的文件）
list_gen() {
  ( cd "$1" && find . -name pkg.generated.mbti \
      ! -path './.mooncakes/*' ! -path './_build*' ! -path './_review/*' \
      ! -path './.git/*' 2>/dev/null | sed 's|^\./||' | sort )
}
list_gen "$ROOT" > "$CUR_PRE_LIST" || die "枚举当前树 pkg.generated.mbti 失败"

# ---------- 1) 导出基线树 ----------
log "== 1/4 导出基线树 =="
TAR_LOG="$(mktemp "$BASE_PARENT/moonmux-api-tar.XXXXXX" 2>/dev/null)" || die "mktemp 失败"
if ! git -C "$ROOT" archive --format=tar "$BASE_REF" | tar -xf - -C "$BASE_DIR" 2>"$TAR_LOG"; then
  if [ -f "$BASE_DIR/moon.mod" ] && [ -f "$BASE_DIR/moon.pkg" ] \
     && [ -n "$(find "$BASE_DIR" -type f -name '*.mbt' 2>/dev/null | sed -n '1p')" ]; then
    # 已知问题：Windows 上 tar（busybox/Git Bash）对非 ASCII 文件名（如 项目申报书.md）可能报错，
    # 但该文件不参与 API diff；只要 moon.mod/moon.pkg/*.mbt 完整即可继续。
    log "WARN: tar 解包存在非致命错误（常见于 Windows 非 ASCII 文件名），已忽略："
    sed -n '1,5p' "$TAR_LOG" | while IFS= read -r l; do log "      $l"; done
  else
    sed -n '1,20p' "$TAR_LOG" >&2
    die "git archive $BASE_REF 失败或解包不完整（缺少 moon.mod/moon.pkg/*.mbt）"
  fi
fi
if [ -d "$ROOT/.mooncakes" ]; then
  # legacy 本地依赖缓存（旧工具链 / 离线环境）：复制进基线树，基线树沿用 --frozen。
  cp -R "$ROOT/.mooncakes" "$BASE_DIR/.mooncakes" \
    || die "复制 .mooncakes 到基线树失败"
  log "   legacy .mooncakes 已复制到基线树"
else
  # moon 0.1.x 默认使用全局 registry 缓存（~/.moon/registry）；无需本地 .mooncakes。
  log "   未发现 legacy .mooncakes（使用全局 registry 缓存 + --frozen；CI 需先 moon update）"
fi
list_gen "$BASE_DIR" > "$BASE_GEN_LIST" || die "枚举基线树 pkg.generated.mbti 失败"

# ---------- 2) 两棵树各生成 .mbti ----------
log "== 2/4 生成 .mbti（moon info --frozen）=="
if [ "$TARGET_ALL" -eq 1 ]; then
  TARGET_ARG="all"
else
  TARGET_ARG=""
fi

# 依赖同步：moon 0.1.x 默认使用全局 registry 缓存（~/.moon/registry）；若树内没有
# legacy `.mooncakes/`，先做一次非 frozen 的 `moon check --deny-warn` 让工具链把依赖装好，
# 之后的 `moon info --frozen` 不再改动依赖图。check 失败不致命（后续 info 的 frozen
# 失败还会退回一次非 frozen 解析）。
warm_tree() {
  tree_dir="$1"
  tree_name="$2"
  log "   同步 $tree_name 依赖（非 frozen check，仅首次）"
  if ! ( cd "$tree_dir" && moon check --deny-warn --target-dir "$CUR_TARGET_NAME" ) >"$WARM_LOG" 2>&1; then
    log "   WARN: $tree_name 依赖同步失败（继续尝试 --frozen 生成；失败会再退回一次非 frozen）"
  fi
}
if [ ! -d "$ROOT/.mooncakes" ]; then
  warm_tree "$ROOT" "当前树"
fi
if [ ! -d "$BASE_DIR/.mooncakes" ]; then
  warm_tree "$BASE_DIR" "基线树"
fi

info_base() {
  if [ -n "$TARGET_ARG" ]; then
    ( cd "$BASE_DIR" && moon info --frozen --target all --target-dir "$CUR_TARGET_NAME" )
  else
    ( cd "$BASE_DIR" && moon info --frozen --target-dir "$CUR_TARGET_NAME" )
  fi
}
info_cur() {
  if [ -n "$TARGET_ARG" ]; then
    ( cd "$ROOT" && moon info --frozen --target all --target-dir "$CUR_TARGET_NAME" )
  else
    ( cd "$ROOT" && moon info --frozen --target-dir "$CUR_TARGET_NAME" )
  fi
}

info_base > "$BASE_LOG" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  # 基线 tag 的依赖版本可能与当前不同：--frozen 失败时退回一次非 frozen 解析（联网/本地缓存）。
  log "WARN: 基线树 moon info --frozen 失败（exit $rc），退回非 frozen 解析重试一次"
  if [ -n "$TARGET_ARG" ]; then
    ( cd "$BASE_DIR" && moon info --target all --target-dir "$CUR_TARGET_NAME" ) > "$BASE_LOG" 2>&1
  else
    ( cd "$BASE_DIR" && moon info --target-dir "$CUR_TARGET_NAME" ) > "$BASE_LOG" 2>&1
  fi
  rc=$?
fi
if [ "$rc" -ne 0 ]; then
  sed -n '1,40p' "$BASE_LOG" >&2
  die "基线树 moon info 失败（exit $rc）；常见原因：基线 moon.mod 依赖不可解析 / 无网络且缓存缺失"
fi

info_cur > "$CUR_LOG" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  sed -n '1,40p' "$CUR_LOG" >&2
  die "当前树 moon info 失败（exit $rc）；先修复 moon check --deny-warn"
fi

# 记录本次在真实工作区新生成的 .mbti，退出时删除
list_gen "$ROOT" > "$CUR_POST_LIST" || true
comm -13 "$CUR_PRE_LIST" "$CUR_POST_LIST" > "$CLEAN_LIST" 2>/dev/null || true

# ---------- 3) 后端接口一致性（--target-all，可选） ----------
TARGET_BREAK=0
if [ "$TARGET_ALL" -eq 1 ]; then
  log "== 3/4 后端接口一致性（moon info --target all）=="
  if grep -q 'diverging interfaces' "$CUR_LOG" 2>/dev/null; then
    TARGET_BREAK=1
    log "BREAKING: 当前树存在后端间公开接口不一致："
    sed -n '/diverging interfaces/,$p' "$CUR_LOG" | sed -n '1,80p'
  else
    log "PASS: native / wasm / wasm-gc / js 各后端公开接口一致（无 diverging interfaces 报告）"
  fi
else
  log "== 3/4 后端接口一致性 =="
  log "SKIP: 未指定 --target-all（CI api-diff job 建议开启）"
fi
log ""

# ---------- 4) 逐包 diff ----------
log "== 4/4 逐包 diff .mbti =="
list_gen "$BASE_DIR" > "$BASE_LIST" || die "枚举基线 .mbti 失败"
list_gen "$ROOT" > "$CUR_LIST" || die "枚举当前 .mbti 失败"
cat "$BASE_LIST" "$CUR_LIST" | sort -u > "$UNION_LIST" || die "合并包清单失败"

TOTAL_ADDED=0
TOTAL_REMOVED=0
TOTAL_BREAKING=0
TOTAL_WHITELIST=0
CHANGED_PKGS=0
BREAKING_PKGS=0

while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  b="$BASE_DIR/$rel"
  c="$ROOT/$rel"
  if [ ! -f "$b" ]; then
    log "ADDED  包/接口文件: $rel（新增包或该包首次进入公开面）"
    continue
  fi
  if [ ! -f "$c" ]; then
    log "BREAKING 移除包/接口文件: $rel"
    TOTAL_BREAKING=$((TOTAL_BREAKING + 1))
    BREAKING_PKGS=$((BREAKING_PKGS + 1))
    continue
  fi
  diff -u "$b" "$c" > "$DIFF_FILE" 2>&1
  drc=$?
  if [ "$drc" -eq 0 ]; then
    continue
  fi
  if [ "$drc" -ne 1 ]; then
    die "diff 失败（exit $drc）: $rel"
  fi
  CHANGED_PKGS=$((CHANGED_PKGS + 1))
  log ""
  log "== 接口变化: $rel =="
  cat "$DIFF_FILE"
  awk -v statfile="$DIFF_FILE.stat" '
    function is_new_symbol(l) {
      return (l ~ /^pub (fn|const) /) || (l ~ /^pub\(all\) (struct|enum) /) ||
             (l ~ /^pub (struct|enum|type|trait) /)
    }
    /^--- / || /^\+\+\+ / { next }
    /^@@/ { next }
    /^-/ {
      l = substr($0, 2)
      if (l == "" || l ~ /^\/\//) { next }
      if (l ~ /^pub const MOONMUX_VERSION : String = ".*"$/) { whitelisted++; next }
      removed++
      if (removed <= 20) print "  REMOVED: " l
      next
    }
    /^\+/ {
      l = substr($0, 2)
      if (l == "" || l ~ /^\/\//) { next }
      if (l ~ /^pub const MOONMUX_VERSION : String = ".*"$/) { whitelisted++; next }
      if (is_new_symbol(l)) {
        added++
        print "  ADDED: " l
        if (l ~ /^(pub\(all\) )?(struct|enum) /) block = "type"
        next
      }
      if (l == "import {") { added++; block = "import"; next }
      # 新增块的闭合行：新增 struct/enum 尾随在既有类型之后时，diff 里会出现单独的 "+}"，
      # 其块头在同 hunk 稍后出现；闭合行本身不构成破坏性变化。
      if (l == "}") { added++; block = ""; next }
      if (l ~ /^ +"[^"]*",?$/) { added++; next }
      if (block == "type") { added++; if (l == "}") block = ""; next }
      if (block == "import") { added++; if (l == "}") block = ""; next }
      breaking++
      if (breaking <= 20) print "  BREAKING-ADDED: " l
      next
    }
    END {
      printf "  summary: added=%d removed=%d breaking=%d whitelisted=%d\n", added, removed, breaking, whitelisted
      printf "%d %d %d %d %d\n", added, removed, breaking, whitelisted, (breaking + removed > 0 ? 1 : 0) > statfile
      close(statfile)
      exit (breaking + removed > 0 ? 1 : 0)
    }
  ' "$DIFF_FILE"
  read -r a r brk wh fbrk < "$DIFF_FILE.stat" || true
  TOTAL_ADDED=$((TOTAL_ADDED + ${a:-0}))
  TOTAL_REMOVED=$((TOTAL_REMOVED + ${r:-0}))
  TOTAL_BREAKING=$((TOTAL_BREAKING + ${brk:-0}))
  TOTAL_WHITELIST=$((TOTAL_WHITELIST + ${wh:-0}))
  if [ "${fbrk:-0}" -ne 0 ]; then
    BREAKING_PKGS=$((BREAKING_PKGS + 1))
  fi
done < "$UNION_LIST"

log ""
log "== 汇总 =="
log "   基线: $BASE_REF ($BASE_COMMIT)  当前: HEAD $CUR_COMMIT"
log "   变化包: $CHANGED_PKGS  新增行: $TOTAL_ADDED  删除行: $TOTAL_REMOVED  白名单行: $TOTAL_WHITELIST"
if [ "$TOTAL_BREAKING" -gt 0 ] || [ "$TOTAL_REMOVED" -gt 0 ] || [ "$TARGET_BREAK" -ne 0 ]; then
  log "   破坏性包: $BREAKING_PKGS  破坏性行: $((TOTAL_BREAKING + TOTAL_REMOVED))（删除 $TOTAL_REMOVED / 既有类型成员变化 $TOTAL_BREAKING）"
  log "   FAIL: 检测到破坏性公开 API 变化；0.x 下应升 minor 版本，并在 CHANGELOG/发布说明给出迁移指引。"
  exit 1
fi
log "   PASS: 仅新增/白名单差异（或无差异）；公开 API 契约向后兼容。"
exit 0
