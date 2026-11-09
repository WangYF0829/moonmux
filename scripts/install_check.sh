#!/usr/bin/env bash
# install_check.sh —— 「可安装使用」的独立验证
#
# 在干净临时工程里走真实用户路径：
#   moon new → moon add WangYF0829/moonmux@<version> → 调用公开 API → 运行
# 这是 10 月终审反馈（核心库未发布/不可安装使用）的复验脚本，也用于
# 每次发布后确认 mooncakes 上的版本确实可安装。
#
# 用法: bash scripts/install_check.sh [version]
#   默认版本：$MOONMUX_INSTALL_VERSION，未设置时 0.7.1
# 退出码: 0 通过；1 失败；2 前提不满足（moon 不可用）

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

VERSION="${1:-${MOONMUX_INSTALL_VERSION:-0.7.1}}"

if ! command -v moon >/dev/null 2>&1; then
  echo "找不到 moon（先安装 MoonBit 工具链）"
  exit 2
fi

mkdir -p _build
TMP="$(mktemp -d -p _build install-check.XXXXXX 2>/dev/null || mktemp -d)"
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

FAIL=0
pass() { printf "  PASS  %s\n" "$1"; }
fail() { printf "  FAIL  %s\n" "$1"; FAIL=$((FAIL + 1)); }

echo "== 可安装性验证：WangYF0829/moonmux@$VERSION =="

cd "$TMP" || exit 1
# 1) 干净工程（显式指定 user/name，CI 环境未登录时也能创建）
moon new --user qa --name qa_install qa_install >/dev/null 2>&1
if [ -d qa_install ]; then
  pass "moon new 创建干净工程"
else
  fail "moon new 创建干净工程"
fi
cd qa_install || exit 1

# 2) 从 mooncakes 安装（moon.mod 里会写入 import）
moon add "WangYF0829/moonmux@$VERSION" >/dev/null 2>&1
if [ $? -eq 0 ] && grep -q "WangYF0829/moonmux@$VERSION" moon.mod; then
  pass "moon add WangYF0829/moonmux@$VERSION"
else
  fail "moon add WangYF0829/moonmux@$VERSION"
fi

# 3) 写最小示例：根包 + ogg + wav 三个公开入口
cat > cmd/main/main.mbt <<'EOF'
///|
fn main {
  println("module: " + @moonmux.describe())
  let wav_bytes = @wav.encode_wav(
    { channels: 1, sample_rate: 8000, bits_per_sample: 16 },
    b"\x00\x00\x01\x00",
  )
  match @wav.WavFile::parse(wav_bytes) {
    Some(f) =>
      println(
        "wav ok: ch=" +
        f.format.channels.to_string() +
        " rate=" +
        f.format.sample_rate.to_string(),
      )
    None => println("wav parse failed")
  }
  println("ogg page: " + @ogg.is_page_start(b"OggS", 0).to_string())
}
EOF
python3 - "$PWD/cmd/main/moon.pkg" <<'PY' 2>/dev/null || true
import sys
p = sys.argv[1]
text = open(p, encoding='utf-8').read()
imports = '"WangYF0829/moonmux", "WangYF0829/moonmux/wav", "WangYF0829/moonmux/ogg"'
if 'import {' in text:
    text = text.replace('import {\n}', 'import {\n  ' + imports + ',\n}')
else:
    text = text.rstrip() + '\n\nimport {\n  ' + imports + ',\n}\n'
open(p, 'w', encoding='utf-8').write(text)
PY
# 没有 python3 时退回文本追加（moon new 的 moon.pkg 结构简单）
if ! grep -q "WangYF0829/moonmux/wav" cmd/main/moon.pkg 2>/dev/null; then
  {
    echo
    echo "import {"
    echo '  "WangYF0829/moonmux",'
    echo '  "WangYF0829/moonmux/wav",'
    echo '  "WangYF0829/moonmux/ogg",'
    echo "}"
  } >> cmd/main/moon.pkg
fi

# 4) 类型检查 + 运行
moon check >/dev/null 2>&1
if [ $? -eq 0 ]; then pass "moon check 通过"; else fail "moon check 通过"; fi
OUT="$(moon run --target native cmd/main 2>&1)"
echo "$OUT" | grep -q "wav ok"
if [ $? -eq 0 ]; then pass "最小示例调用 wav API 成功"; else fail "最小示例调用 wav API 成功"; fi
echo "$OUT" | grep -q "ogg page: true"
if [ $? -eq 0 ]; then pass "最小示例调用 ogg API 成功"; else fail "最小示例调用 ogg API 成功"; fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "install_check: 全部通过（$VERSION 可安装、可运行）"
  exit 0
else
  echo "install_check: $FAIL 项失败"
  exit 1
fi
