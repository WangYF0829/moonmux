#!/usr/bin/env bash
# preflight_release.sh —— 发布前全量预检（A1 发布演练 / 本地发布门禁）
#
# 做什么：把 RELEASING.md 中“发布前检查单”的自动化部分串成一条命令，
#         按依赖顺序执行全部本地门禁并输出 PASS/FAIL 汇总表。
#
# 覆盖：工具链记录 / worktree 状态 / 版本一致性 / 格式 / 编译 / 测试（target all）/
#       公开 API diff / API 文档覆盖 / 覆盖率门禁 / PII 扫描 / 发布包内容 / SBOM /
#       性能基线（可跳过）/ 变异 fuzz（可跳过）/ 端到端 smoke（可跳过）。
#
# 用法：
#   bash scripts/preflight_release.sh                  # 完整预检（干净 worktree 必须）
#   bash scripts/preflight_release.sh --allow-dirty    # 开发/整改期允许脏 worktree
#   bash scripts/preflight_release.sh --skip-bench --skip-fuzz --skip-smoke   # 快速门禁
#   bash scripts/preflight_release.sh --total-threshold 80 --lib-threshold 88
#
# 退出码：0 = 全部通过；1 = 有门禁失败；2 = 用法/环境错误。
#
# 说明：
#   * 本脚本不提交、不改版本号、不发布，仅为发布前本地演练。
#   * coverage 使用 `_review/build/preflight-cov`（被 .gitignore 的 `_*/` 覆盖，
#     不污染发布包）；check_package/gen_sbom 使用 `_build/` 与临时目录。
set -u
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" || { echo "ERROR: 无法定位仓库根" >&2; exit 2; }
cd "$ROOT" || { echo "ERROR: 无法进入仓库根: $ROOT" >&2; exit 2; }
[ -f moon.mod ] || { echo "ERROR: 不在 moonmux 仓库根（缺少 moon.mod）: $ROOT" >&2; exit 2; }

# 依赖检查：缺工具时立即以清晰信息退出（避免 run 步骤出现误导性的 127）
for tool in moon node bash; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: 找不到 \`$tool\`（请把 MoonBit 工具链/Node/Git Bash 加入 PATH 后重试）" >&2
    exit 2
  }
done
command -v awk >/dev/null 2>&1 || { echo "ERROR: 找不到 awk" >&2; exit 2; }

ALLOW_DIRTY=0
SKIP_BENCH=0
SKIP_FUZZ=0
SKIP_SMOKE=0
SKIP_COVERAGE=0
TOTAL_THRESHOLD=80
LIB_THRESHOLD=88
COV_TD="$ROOT/_review/build/preflight-cov"

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --allow-dirty)     ALLOW_DIRTY=1; shift ;;
    --skip-bench)      SKIP_BENCH=1; shift ;;
    --skip-fuzz)       SKIP_FUZZ=1; shift ;;
    --skip-smoke)      SKIP_SMOKE=1; shift ;;
    --skip-coverage)   SKIP_COVERAGE=1; shift ;;
    --total-threshold) [ $# -ge 2 ] || { echo "ERROR: --total-threshold 缺参数" >&2; exit 2; }; TOTAL_THRESHOLD="$2"; shift 2 ;;
    --lib-threshold)   [ $# -ge 2 ] || { echo "ERROR: --lib-threshold 缺参数" >&2; exit 2; }; LIB_THRESHOLD="$2"; shift 2 ;;
    --target-dir)      [ $# -ge 2 ] || { echo "ERROR: --target-dir 缺参数" >&2; exit 2; }; COV_TD="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: 未知参数: $1（--help 查看用法）" >&2; exit 2 ;;
  esac
done

rm -rf "$COV_TD" 2>/dev/null || true
mkdir -p "$(dirname "$COV_TD")" 2>/dev/null || true

PASS=0
FAIL=0
SKIP=0
declare -a RESULTS=()

record() { # $1=status $2=name $3=detail
  RESULTS+=("$1|$2|$3")
  case "$1" in
    PASS) PASS=$((PASS + 1)) ;;
    FAIL) FAIL=$((FAIL + 1)) ;;
    SKIP) SKIP=$((SKIP + 1)) ;;
  esac
}

run_step() { # $1=name $2=log $3...=command
  local name="$1" log="$2"; shift 2
  printf '\n==> %s\n' "$name"
  if "$@" >"$log" 2>&1; then
    record PASS "$name" "exit 0"
    printf '    PASS\n'
    return 0
  else
    local rc=$?
    record FAIL "$name" "exit $rc；日志: ${log##*/}"
    printf '    FAIL (exit %s)\n' "$rc"
    tail -n 8 "$log" | sed 's/^/    /'
    return 1
  fi
}

LOG_DIR="$ROOT/_review/build/preflight-logs"
rm -rf "$LOG_DIR" 2>/dev/null || true
mkdir -p "$LOG_DIR" || { echo "ERROR: 无法创建日志目录: $LOG_DIR" >&2; exit 2; }

printf '== moonmux 发布前预检 ==\n'
printf '   仓库: %s\n' "$ROOT"
printf '   时间: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
printf '   选项: allow_dirty=%s skip_bench=%s skip_fuzz=%s skip_smoke=%s skip_coverage=%s\n' \
  "$ALLOW_DIRTY" "$SKIP_BENCH" "$SKIP_FUZZ" "$SKIP_SMOKE" "$SKIP_COVERAGE"

# 0) 工具链记录
echo
echo "== 工具链 =="
moon version --all 2>&1 | tee "$LOG_DIR/toolchain.log" || true

# 1) worktree 状态
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
if [ "$DIRTY" = "0" ]; then
  record PASS "worktree 干净" "0 项变更"
  printf '\n==> worktree 干净: PASS\n'
elif [ "$ALLOW_DIRTY" -eq 1 ]; then
  record PASS "worktree 干净" "allow-dirty：$DIRTY 项未提交变更（发布前必须清理）"
  printf '\n==> worktree 不干净（%s 项），--allow-dirty 放行：WARN\n' "$DIRTY"
else
  record FAIL "worktree 干净" "$DIRTY 项未提交变更；发布前必须提交/清理（开发期可用 --allow-dirty）"
  printf '\n==> worktree 不干净（%s 项）：FAIL（可用 --allow-dirty 开发期放行）\n' "$DIRTY"
fi

# 2) 构建 native CLI（check_version.sh 需要可执行文件；干净环境必须先构建）
run_step "构建 native CLI（build --target native）" "$LOG_DIR/build.log" moon build --target native

# 3) 版本一致性
run_step "版本一致性 check_version.sh" "$LOG_DIR/version.log" bash scripts/check_version.sh

# 3) 格式
run_step "格式 fmt --check" "$LOG_DIR/fmt.log" moon fmt --check

# 4) 编译（全 target）
run_step "编译 check --deny-warn --target all" "$LOG_DIR/check.log" moon check --deny-warn --target all

# 5) 测试（全 target）
run_step "测试 test --deny-warn --target all" "$LOG_DIR/test.log" moon test --deny-warn --target all
grep -E '^Total tests' "$LOG_DIR/test.log" | tail -5 | sed 's/^/    /' || true

# 6) 公开 API diff（对上一 tag）
if [ -f scripts/check_api_diff.sh ]; then
  run_step "公开 API diff（--target-all）" "$LOG_DIR/api-diff.log" bash scripts/check_api_diff.sh --target-all
fi

# 7) API 文档覆盖
if [ -f scripts/check_api_docs.sh ]; then
  run_step "API 文档覆盖（D6）" "$LOG_DIR/api-docs.log" bash scripts/check_api_docs.sh --threshold 95 --max-gap 0
fi

# 8) 覆盖率门禁
if [ "$SKIP_COVERAGE" -eq 1 ]; then
  record SKIP "覆盖率门禁" "--skip-coverage"
  printf '\n==> 覆盖率门禁: SKIP\n'
else
  run_step "覆盖率门禁（库层 ≥${LIB_THRESHOLD}% / 总 ≥${TOTAL_THRESHOLD}%）" "$LOG_DIR/coverage.log" \
    bash scripts/check_coverage.sh --target-dir "$COV_TD" --lib-threshold "$LIB_THRESHOLD" --total-threshold "$TOTAL_THRESHOLD"
fi

# 9) PII / 凭据扫描
run_step "PII/凭据扫描 check_pii.sh" "$LOG_DIR/pii.log" bash scripts/check_pii.sh

# 10) 发布包内容
if [ "$ALLOW_DIRTY" -eq 1 ]; then
  run_step "发布包内容 check_package.sh（--allow-dirty）" "$LOG_DIR/package.log" bash scripts/check_package.sh --allow-dirty
else
  run_step "发布包内容 check_package.sh" "$LOG_DIR/package.log" bash scripts/check_package.sh
fi

# 11) SBOM（信息性）
if [ -f scripts/gen_sbom.sh ]; then
  SBOM_DIR="$LOG_DIR/sbom"
  if bash scripts/gen_sbom.sh --out "$SBOM_DIR" >"$LOG_DIR/sbom.log" 2>&1; then
    SBOM_FILES="$(find "$SBOM_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
    SBOM_SUM="$(sha256sum "$SBOM_DIR/SHA256SUMS" 2>/dev/null | cut -d' ' -f1 || true)"
    record PASS "SBOM 生成" "$SBOM_FILES 文件"
    printf '\n==> SBOM: PASS（%s 文件）\n' "$SBOM_FILES"
  else
    record FAIL "SBOM 生成" "见 $LOG_DIR/sbom.log"
    printf '\n==> SBOM: FAIL\n'
  fi
fi

# 12) 性能基线
if [ "$SKIP_BENCH" -eq 1 ]; then
  record SKIP "性能基线 bench" "--skip-bench"
  printf '\n==> 性能基线: SKIP\n'
else
  run_step "性能基线 bench（基线+阈值 10%）" "$LOG_DIR/bench.log" \
    node scripts/bench.mjs --runs 5 --batches 2 --baseline scripts/bench-baseline.json --fail-over 0.10
fi

# 13) 变异 fuzz
if [ "$SKIP_FUZZ" -eq 1 ]; then
  record SKIP "变异 fuzz" "--skip-fuzz"
  printf '\n==> 变异 fuzz: SKIP\n'
else
  run_step "变异 fuzz（400 次，固定种子）" "$LOG_DIR/fuzz.log" \
    node scripts/fuzz.mjs --iterations 400 --seed 20261109
fi

# 14) 端到端 smoke
if [ "$SKIP_SMOKE" -eq 1 ]; then
  record SKIP "端到端 smoke" "--skip-smoke"
  printf '\n==> 端到端 smoke: SKIP\n'
else
  run_step "端到端 smoke（66 项）" "$LOG_DIR/smoke.log" bash scripts/smoke.sh
fi

# ---------- 汇总 ----------
printf '\n== 预检汇总 ==\n'
for row in "${RESULTS[@]}"; do
  IFS='|' read -r st name detail <<EOF
$row
EOF
  printf '%-4s %-46s %s\n' "$st" "$name" "$detail"
done
printf '\nPASS=%s FAIL=%s SKIP=%s（日志: %s）\n' "$PASS" "$FAIL" "$SKIP" "$LOG_DIR"

if [ "$FAIL" -ne 0 ]; then
  echo "FAIL: 有 $FAIL 项未通过，禁止发布。" >&2
  exit 1
fi
echo "PASS: 本地发布前预检全部通过（真实 CI/GitHub Release 仍需发布后复核）。"
exit 0
