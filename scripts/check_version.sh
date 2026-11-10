#!/usr/bin/env bash
# check_version.sh —— 版本号单一事实源校验
#
# 版本号仍以 moon.mod 为唯一事实源（MoonBit 没有编译期读 moon.mod 的机制），
# 这里把散落在构建产物/文档/CI 里的副本全部对齐检查；任何一处不同步都失败。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

FAIL=0
pass() { printf "  PASS  %s\n" "$1"; }
fail() { printf "  FAIL  %s\n" "$1"; FAIL=$((FAIL + 1)); }

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

echo
if [ "$FAIL" -eq 0 ]; then
  echo "check_version: 全部一致（$MOD_VERSION）"
  exit 0
else
  echo "check_version: $FAIL 项不一致"
  exit 1
fi