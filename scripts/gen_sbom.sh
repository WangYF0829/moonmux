#!/usr/bin/env bash
# gen_sbom.sh —— 发布材料 / SBOM 归档（供应链可追溯性）
#
# 归档内容（写入输出目录，不修改源码）：
#   moon-tree.json           `moon tree --json` 依赖图（机器可读，SBOM 替代材料）
#   moon-tree.txt            `moon tree` 人类可读依赖树
#   moon.mod                 moon.mod 快照（版本/依赖/许可单一事实源）
#   moon-version-all.txt     `moon version --all` 工具链版本
#   artifact-sha256.txt      发布 zip 路径/体积/sha256（--zip 指定或自动探测 _build/publish/*.zip）
#   dependency-checksums.txt 各依赖在本地注册表缓存中的 zip sha256（与 mooncakes checksum 对照用）
#   package-list.txt         可选（--with-package-list）：`moon package --list` 清单
#   manifest.txt             本次归档的元信息（时间/commit/tag/worktree 状态）+ 各文件 sha256
#
# 用法：
#   bash scripts/gen_sbom.sh                                  # 默认输出 _review/fix/sbom/
#   bash scripts/gen_sbom.sh --out docs/releases/v0.9.3      # CI 接线：交给发布文档组复核
#   bash scripts/gen_sbom.sh --zip _build/publish/WangYF0829-moonmux-0.9.3.zip
#   bash scripts/gen_sbom.sh --with-package-list              # 额外固化发布清单（会触发一次 package）
#   bash scripts/gen_sbom.sh --force                          # 允许覆盖同一输出目录（默认不覆盖）
#
# 说明：默认输出路径只落在 _review/fix/sbom/（修复组自留证据）；不需要发布文档组目录。
#       发布流水线可通过 --out docs/releases/<version>/ 归档为正式材料。
#       输出目录已存在 manifest.txt 时默认不会覆盖：自动改用 <out>/run-<UTC时间戳>/。
#
# 退出码：0 = 归档完成；1 = 归档命令失败；2 = 用法/环境错误。
set -u
if [ -n "${BASH_VERSION:-}" ]; then
  set -o pipefail
fi

ROOT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" || { echo "gen_sbom: 无法定位脚本目录" >&2; exit 2; }
if [ -n "${MOONMUX_ROOT:-}" ]; then
  ROOT="$(cd "$MOONMUX_ROOT" 2>/dev/null && pwd)" || { echo "gen_sbom: MOONMUX_ROOT 无效：$MOONMUX_ROOT" >&2; exit 2; }
fi
cd "$ROOT" || { echo "gen_sbom: 无法进入仓库根 $ROOT" >&2; exit 2; }

OUT_ARG="_review/fix/sbom"
ZIP_ARG=""
FORCE=0
WITH_PKG_LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT_ARG="${2:-}"; shift 2 ;;
    --out=*) OUT_ARG="${1#--out=}"; shift ;;
    --zip) ZIP_ARG="${2:-}"; shift 2 ;;
    --zip=*) ZIP_ARG="${1#--zip=}"; shift ;;
    --force) FORCE=1; shift ;;
    --with-package-list) WITH_PKG_LIST=1; shift ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "gen_sbom: 未知参数：$1（用 --help 查看用法）" >&2; exit 2 ;;
  esac
done
[ -n "$OUT_ARG" ] || { echo "gen_sbom: --out 不能为空" >&2; exit 2; }

command -v moon >/dev/null 2>&1 || { echo "gen_sbom: 找不到 moon 命令" >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo "gen_sbom: 需要 sha256sum（Git Bash/Linux 自带）" >&2; exit 2; }

# 解析输出目录：相对路径按仓库根解析；绝对路径（/ 或盘符）直接使用。
case "$OUT_ARG" in
  /*|[A-Za-z]:[\\/]*) OUT="$OUT_ARG" ;;
  *) OUT="$ROOT/$OUT_ARG" ;;
esac

if [ -e "$OUT/manifest.txt" ] && [ "$FORCE" -ne 1 ]; then
  STAMP="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo run-$$)"
  echo "gen_sbom: $OUT 已有归档（存在 manifest.txt），不覆盖；改写 $OUT/run-$STAMP/"
  OUT="$OUT/run-$STAMP"
fi
mkdir -p "$OUT" || { echo "gen_sbom: 无法创建输出目录：$OUT" >&2; exit 2; }

echo "== SBOM / 发布材料归档 =="
echo "仓库根：$ROOT"
echo "输出目录：$OUT"

STATUS=0
run_to_file() {
  desc="$1"; shift; dest="$1"; shift
  if "$@" >"$dest" 2>&1; then
    echo "  OK    $desc -> ${dest#$ROOT/}"
  else
    rc=$?
    echo "  FAIL  $desc（exit $rc）-> ${dest#$ROOT/}" >&2
    STATUS=1
  fi
}

# 1) 依赖图 + 模块清单 + 工具链
run_to_file "moon tree --json" "$OUT/moon-tree.json" moon tree --json
run_to_file "moon tree" "$OUT/moon-tree.txt" moon tree
cat moon.mod >"$OUT/moon.mod"
run_to_file "moon version --all" "$OUT/moon-version-all.txt" moon version --all

# 2) 发布 zip sha256（显式 --zip 优先；否则自动探测 _build/publish/*.zip 最新文件）
ZIP="$ZIP_ARG"
if [ -z "$ZIP" ]; then
  ZIP="$(ls -t _build/publish/*.zip 2>/dev/null | head -n 1)"
fi
{
  echo "# 发布制品校验（artifact sha256）"
  echo "generated_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  echo "commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  if [ -n "$ZIP" ] && [ -f "$ZIP" ]; then
    ZIP_BYTES="$(wc -c <"$ZIP" | tr -d ' ')"
    ZIP_SHA="$(sha256sum "$ZIP" | awk '{print $1}')"
    echo "zip_path=$ZIP"
    echo "zip_bytes=$ZIP_BYTES"
    echo "zip_sha256=$ZIP_SHA"
  else
    echo "zip_path=(not found)"
    echo "zip_bytes=0"
    echo "zip_sha256=(not found: 先运行 moon package，或用 --zip 指定)"
  fi
} >"$OUT/artifact-sha256.txt"
if grep -q '^zip_sha256=(not found' "$OUT/artifact-sha256.txt"; then
  echo "  WARN  未找到发布 zip；artifact-sha256.txt 记录 not found（发布前先 moon package）"
else
  echo "  OK    发布 zip sha256 -> ${OUT#$ROOT/}/artifact-sha256.txt"
fi

# 3) 依赖缓存 zip 的 sha256（与 mooncakes 注册表 checksum 对照；找不到则标注 missing）
CACHE_ROOT=""
if [ -n "${HOME:-}" ] && [ -d "$HOME/.moon/registry/cache" ]; then
  CACHE_ROOT="$HOME/.moon/registry/cache"
elif [ -n "${USERPROFILE:-}" ] && [ -d "$USERPROFILE/.moon/registry/cache" ]; then
  CACHE_ROOT="$USERPROFILE/.moon/registry/cache"
fi
{
  echo "# 依赖制品校验（本地 .moon/registry/cache 中的 zip sha256；应与 mooncakes metadata.checksum 一致）"
  echo "cache_root=${CACHE_ROOT:-（未找到）}"
  # moon.mod import 形如 "user/module@version"
  grep -E '"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9][^"]*"' moon.mod 2>/dev/null \
    | sed -E 's/.*"([^"]+)".*/\1/' | sort -u \
    | while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        mod="${dep%@*}"
        ver="${dep##*@}"
        owner="${mod%%/*}"
        name="${mod#*/}"
        if [ -n "$CACHE_ROOT" ] && [ -f "$CACHE_ROOT/$owner/$name/$ver.zip" ]; then
          printf '%s@%s %s\n' "$mod" "$ver" "$(sha256sum "$CACHE_ROOT/$owner/$name/$ver.zip" | awk '{print $1}')"
        else
          printf '%s@%s MISSING\n' "$mod" "$ver"
        fi
      done
} >"$OUT/dependency-checksums.txt"
echo "  OK    依赖缓存 sha256 -> ${OUT#$ROOT/}/dependency-checksums.txt"

# 4) 可选：发布清单（会触发一次 moon package；默认关闭以免改动 _build/publish 中的 zip）
if [ "$WITH_PKG_LIST" -eq 1 ]; then
  run_to_file "moon package --list" "$OUT/package-list.txt" moon package --list
fi

# 5) manifest：元信息 + 各归档文件 sha256
{
  echo "# moonmux SBOM / 发布材料归档清单"
  echo "generated_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  echo "module=$(sed -n 's/^name = \"\(.*\)\"/\1/p' moon.mod | head -1)"
  echo "module_version=$(sed -n 's/^version = \"\(.*\)\"/\1/p' moon.mod | head -1)"
  echo "license=$(sed -n 's/^license = \"\(.*\)\"/\1/p' moon.mod | head -1)"
  echo "commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "git_describe=$(git describe --tags --always --dirty 2>/dev/null || echo unknown)"
  echo "tag_points_at_head=$(git tag --points-at HEAD 2>/dev/null | tr '\n' ' ' || echo '')"
  DIRTY_LINES="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  echo "worktree_dirty_lines=$DIRTY_LINES"
  echo "moon_version=$(moon version --all 2>/dev/null | head -1 | tr -d '\r')"
  echo
  echo "## 归档文件 sha256"
  for f in moon-tree.json moon-tree.txt moon.mod moon-version-all.txt artifact-sha256.txt dependency-checksums.txt package-list.txt; do
    [ -f "$OUT/$f" ] || continue
    printf '%s  %s\n' "$(sha256sum "$OUT/$f" | awk '{print $1}')" "$f"
  done
} >"$OUT/manifest.txt"
echo "  OK    manifest -> ${OUT#$ROOT/}/manifest.txt"

echo
echo "归档完成：$(ls "$OUT" | wc -l | tr -d ' ') 个文件 -> $OUT"
if [ "$STATUS" -ne 0 ]; then
  echo "gen_sbom: 有归档命令失败（见上方 FAIL）"
  exit 1
fi
exit 0
