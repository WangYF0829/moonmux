#!/usr/bin/env bash
# check_version.sh —— 版本号单一事实源校验
#
# 版本号仍以 moon.mod 为唯一事实源（MoonBit 没有编译期读 moon.mod 的机制），
# 这里把散落在构建产物/文档/CI/代码/tag 里的副本全部对齐检查；任何一处不同步都失败。
#
# 检查项：
#   1) native CLI 的 describe()/version 输出 == moon.mod version
#   2) README 双徽章、smoke.sh、install_check.sh、ci.yml 的版本副本
#   3) 代码内副本：moonmux.mbt 的 MOONMUX_VERSION
#   4) 文档副本：docs/architecture.md 的“版本：vX.Y.Z”行
#   5) CHANGELOG：顶部（可选 [Unreleased] 之后）第一条版本条目标题 == moon.mod version
#   6) git tag：git describe --tags --abbrev=0 == vX.Y.Z
#      （发布门禁语义：版本 bump 提交必须先打 tag 再合入/发布；本地可用 VERSION_SKIP_TAG=1 跳过）
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

FAIL=0
pass() { printf "  PASS  %s\n" "$1"; }
fail() { printf "  FAIL  %s\n" "$1"; FAIL=$((FAIL + 1)); }
warn() { printf "  WARN  %s\n" "$1"; }

MOD_VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' moon.mod | head -1)"
if [ -z "$MOD_VERSION" ]; then
  echo "无法从 moon.mod 读出 version"
  exit 2
fi
echo "== 版本一致性（moon.mod: $MOD_VERSION）=="

# 1) CLI 二进制
BIN=""
for cand in \
  "_build/native/debug/build/cmd/main/main.exe" \
  "_build/native/debug/build/cmd/main/main" \
  "_build/native/release/build/cmd/main/main.exe" \
  "_build/native/release/build/cmd/main/main"; do
  if [ -x "$cand" ]; then BIN="$cand"; break; fi
done
if [ -z "$BIN" ]; then
  fail "找不到 native CLI（先 moon build --target native）"
else
  CLI_VERSION="$("$BIN" version | awk '{print $2}')"
  if [ "$CLI_VERSION" = "$MOD_VERSION" ]; then
    pass "CLI describe() = moon.mod（$MOD_VERSION）"
  else
    fail "CLI describe() = $CLI_VERSION，moon.mod = $MOD_VERSION"
  fi
fi

# 2) 脚本/文档/CI 里的版本副本
check_contains() {
  local file="$1" pattern="$2" what="$3"
  if [ ! -f "$file" ]; then
    fail "$what：缺文件 $file"
  elif grep -qF "$pattern" "$file"; then
    pass "$what"
  else
    fail "$what（期望包含「$pattern」）"
  fi
}
check_contains README.md "version-$MOD_VERSION-blue" "README 版本徽章"
check_contains README.md "mooncakes-$MOD_VERSION-blueviolet" "README mooncakes 徽章"
check_contains scripts/smoke.sh "moonmux $MOD_VERSION" "smoke 版本断言"
check_contains scripts/install_check.sh "MOONMUX_INSTALL_VERSION:-$MOD_VERSION" "install_check 默认版本"
check_contains .github/workflows/ci.yml "MOONMUX_INSTALL_VERSION: \"$MOD_VERSION\"" "CI install 版本"

# 3) 代码内副本（moonmux.mbt 的 pub const MOONMUX_VERSION）
check_contains moonmux.mbt "pub const MOONMUX_VERSION : String = \"$MOD_VERSION\"" "代码内 MOONMUX_VERSION"

# 4) 文档副本（docs/architecture.md 的版本行）
if [ -f docs/architecture.md ]; then
  if grep -qF "版本：v$MOD_VERSION" docs/architecture.md; then
    pass "docs/architecture.md 版本行（v$MOD_VERSION）"
  else
    fail "docs/architecture.md 版本行未对齐（期望「版本：v$MOD_VERSION」）"
  fi
else
  fail "docs/architecture.md：缺文件"
fi

# 5) CHANGELOG：顶部条目（允许 "## [Unreleased]" 在最上面）
if [ -f CHANGELOG.md ]; then
  if grep -q '^## \[Unreleased\]' CHANGELOG.md; then
    pass "CHANGELOG 含 [Unreleased] 区段"
  fi
  TOP_VERSION="$(grep -m1 -E '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md \
    | sed -E 's/^## \[([0-9]+\.[0-9]+\.[0-9]+)\].*/\1/')"
  if [ -z "$TOP_VERSION" ]; then
    fail "CHANGELOG 未找到版本条目标题（期望「## [X.Y.Z]」）"
  elif [ "$TOP_VERSION" = "$MOD_VERSION" ]; then
    pass "CHANGELOG 顶部版本条目 = moon.mod（$MOD_VERSION）"
  else
    fail "CHANGELOG 顶部版本条目 = $TOP_VERSION，moon.mod = $MOD_VERSION"
  fi
else
  fail "CHANGELOG.md：缺文件"
fi

# 6) git tag：最近 tag 必须是 vX.Y.Z
if [ "${VERSION_SKIP_TAG:-0}" = "1" ]; then
  warn "跳过 git tag 检查（VERSION_SKIP_TAG=1）"
elif ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "git tag 检查：当前目录不是 git 仓库"
else
  NEAREST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  if [ "$NEAREST_TAG" = "v$MOD_VERSION" ]; then
    pass "git describe --tags --abbrev=0 = v$MOD_VERSION"
  else
    fail "最近 tag = ${NEAREST_TAG:-<无>}，期望 v$MOD_VERSION（发布前请先打 tag；本地可用 VERSION_SKIP_TAG=1）"
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "check_version: 全部一致（$MOD_VERSION）"
  exit 0
else
  echo "check_version: $FAIL 项不一致"
  exit 1
fi
