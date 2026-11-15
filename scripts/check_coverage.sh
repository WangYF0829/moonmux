#!/usr/bin/env bash
# check_coverage.sh —— 覆盖率门禁：库层覆盖率 + 总覆盖率（行覆盖率口径）
#
# 做什么：
#   1) （默认）运行 `moon test --enable-coverage --target native --target-dir <dir>`；
#   2) 在测试数据目录内用 `moon coverage report -f summary` 生成逐文件覆盖率；
#   3) 计算两个指标：
#        - 库层覆盖率：排除 cmd/main、examples/*、root 包（moonmux.mbt）后的
#          “库包”行覆盖率（cli/codec/manifest/mp4/ogg/pipeline/wav）；
#        - 总覆盖率：报告 `Total:` 行（行覆盖率）。
#      阈值：库层 ≥ 88%、总覆盖率 ≥ 80%（可用参数覆盖）。
#
# trace 卫生（重要，2026-11-13 第 10 轮修复）：
#   `moon coverage report` 会从**项目根递归**发现名为 `moonbit_coverage_*` 的 trace 文件，
#   因此开发机上其它目录的历史 trace（旧构建/旧副本/上一次 preflight 的 trace）会被合并进
#   本次测量，导致覆盖率虚高（实测同一工作区可虚高 ~6.5pp，且工具只打印
#   "Counts array length mismatch" 警告而不失败）。本脚本在测量前后做隔离：
#     * 运行测试前清空 target-dir 内已有 trace；
#     * 生成报告前把**仓库内其它位置**的 trace 临时移出仓库（trap 恢复），只保留 target-dir 内的；
#     * 报告输出若仍出现 "Counts array length mismatch" / "obsolete coverage" 则按工具错误 exit 2。
#
# 口径说明（重要）：
#   * 本工具链（moon 0.1.20261012）的 cobertura 报告只有行覆盖（无 branch-rate），
#     summary 的百分比口径是行覆盖率；因此"总分支 ≥75%"按验收报告同源的
#     summary `Total` 行覆盖率执行（76.09% ↔ Total: 4784/6287）。
#   * 若 summary 生成失败，脚本再尝试 cobertura（`moon coverage report -f cobertura`）
#     解析（口径为可插桩行，数值会与 summary 不同，会在输出中注明），仍失败则 exit 2。
#
# 退出码：0 = 达标；1 = 不达标；2 = 工具错误（缺 moon/awk、测试失败、报告不可用等）。
#
# 用法：
#   bash scripts/check_coverage.sh
#   bash scripts/check_coverage.sh --lib-threshold 88 --total-threshold 75
#   bash scripts/check_coverage.sh --no-run --target-dir _build        # 复用已生成 coverage 数据
#   bash scripts/check_coverage.sh --summary-file /tmp/summary.txt      # 直接解析已有 summary
set -u
export LC_ALL=C

usage() {
  cat <<'EOF'
用法: bash scripts/check_coverage.sh [选项]

生成/解析代码覆盖率报告并执行门禁：
  - 库层覆盖率（排除 cmd/main、examples/*、root 的 moonmux.mbt）>= 88%
  - 总覆盖率（summary Total 行覆盖率）>= 80%
口径：行覆盖率；本工具链 cobertura 无 branch-rate，分支阈值按 summary Total 执行。

选项:
  --target-dir <dir>      coverage 构建目录（默认 _build；--no-run 时解析该目录已有数据）
  --lib-threshold <pct>   库层覆盖率阈值（默认 88）
  --total-threshold <pct> 总覆盖率阈值（默认 80）
  --no-run                跳过 `moon test --enable-coverage`，直接解析已有 trace 数据
  --summary-file <file>   直接解析已有的 summary 文本（不再生成）
  --keep                  保留临时文件（排查用）
  -h, --help              显示本帮助

退出码: 0=达标; 1=不达标; 2=工具错误
EOF
}

TARGET_DIR="_build"
LIB_THRESHOLD="88"
TOTAL_THRESHOLD="80"
NO_RUN=0
SUMMARY_FILE=""
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --target-dir)     [ $# -ge 2 ] || { echo "ERROR: --target-dir 缺参数" >&2; exit 2; }; TARGET_DIR="$2"; shift 2 ;;
    --lib-threshold)  [ $# -ge 2 ] || { echo "ERROR: --lib-threshold 缺参数" >&2; exit 2; }; LIB_THRESHOLD="$2"; shift 2 ;;
    --total-threshold)[ $# -ge 2 ] || { echo "ERROR: --total-threshold 缺参数" >&2; exit 2; }; TOTAL_THRESHOLD="$2"; shift 2 ;;
    --no-run) NO_RUN=1; shift ;;
    --summary-file)   [ $# -ge 2 ] || { echo "ERROR: --summary-file 缺参数" >&2; exit 2; }; SUMMARY_FILE="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: 未知参数: $1（--help 查看用法）" >&2; exit 2 ;;
  esac
done

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
is_num() { case "$1" in ''|*[!0-9.]*) return 1 ;; *) return 0 ;; esac; }
is_num "$LIB_THRESHOLD"   || die "--lib-threshold 非法: $LIB_THRESHOLD"
is_num "$TOTAL_THRESHOLD" || die "--total-threshold 非法: $TOTAL_THRESHOLD"

ROOT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" || die "无法定位脚本目录"
cd "$ROOT" || die "无法进入仓库根: $ROOT"
command -v moon >/dev/null 2>&1 || die "找不到 moon 命令（先安装 MoonBit 工具链）"
command -v awk  >/dev/null 2>&1 || die "找不到 awk"
[ -f "$ROOT/moon.mod" ] || die "不是 moonmux 仓库根（缺少 moon.mod）: $ROOT"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/moonmux-coverage.XXXXXX" 2>/dev/null)" || die "mktemp 失败"
SUMMARY="$TMP_DIR/summary.txt"
COBERTURA="$TMP_DIR/cobertura.xml"
METRICS="$TMP_DIR/metrics.txt"
WORST="$TMP_DIR/worst.txt"
REPORT_ERR="$TMP_DIR/report.err"
TRACE_BACKUP=""          # 仓库内其它位置 trace 的临时存放目录（隔离用）
TRACE_MANIFEST=""        # "原路径<TAB>备份路径" 列表，退出时按序恢复
isolated_restore() {
  if [ -n "${TRACE_MANIFEST:-}" ] && [ -f "$TRACE_MANIFEST" ]; then
    while IFS="$(printf '\t')" read -r orig bak; do
      [ -n "$orig" ] || continue
      [ -f "$bak" ] || continue
      mkdir -p "$(dirname "$orig")" 2>/dev/null || true
      mv -f "$bak" "$orig" 2>/dev/null || true
    done < "$TRACE_MANIFEST"
  fi
  if [ -n "${TRACE_BACKUP:-}" ]; then rm -rf "$TRACE_BACKUP" 2>/dev/null || true; fi
}
cleanup() { isolated_restore; [ "$KEEP" -eq 1 ] || rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

printf '== 覆盖率门禁 ==\n'
printf '   仓库: %s\n' "$ROOT"
printf '   阈值: 库层 >= %s%%，总覆盖率 >= %s%%（行覆盖率口径）\n' "$LIB_THRESHOLD" "$TOTAL_THRESHOLD"

MODE=""
if [ -n "$SUMMARY_FILE" ]; then
  [ -f "$SUMMARY_FILE" ] || die "summary 文件不存在: $SUMMARY_FILE"
  cp "$SUMMARY_FILE" "$SUMMARY" || die "读取 summary 失败"
  MODE="summary-file"
else
  TD_ABS="$ROOT/$TARGET_DIR"
  case "$TARGET_DIR" in
    /*|[A-Za-z]:[/\\]*) TD_ABS="$TARGET_DIR" ;;
  esac
  if [ "$NO_RUN" -eq 0 ]; then
    mkdir -p "$TD_ABS" || die "无法创建 target-dir: $TD_ABS"
    # 清理 target-dir 内上一次运行残留的 trace，避免同目录旧 trace 与本次合并。
    find "$TD_ABS" -name 'moonbit_coverage_*' -type f -delete 2>/dev/null || true
    TEST_LOG="$TMP_DIR/moon-test.log"
    printf '   运行: moon test --enable-coverage --target native --target-dir %s\n' "$TARGET_DIR"
    ( cd "$ROOT" && moon test --enable-coverage --target native --target-dir "$TARGET_DIR" ) > "$TEST_LOG" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
      sed -n '1,40p' "$TEST_LOG" >&2
      die "moon test --enable-coverage 失败（exit $rc）"
    fi
    grep -E 'Total tests:' "$TEST_LOG" | tail -1 || true
  else
    [ -d "$TD_ABS" ] || die "--no-run 但 target-dir 不存在: $TD_ABS"
  fi

  # ---- trace 卫生：把仓库内其它位置的 moonbit_coverage_* 临时移出（报告后恢复）----
  # `moon coverage report` 会从项目根递归发现 trace；开发机上其它目录的历史 trace
  # （旧构建/旧副本/上一次 preflight）会被合并，导致覆盖率虚高（实测 ~+6.5pp）。
  isolate_traces_elsewhere() {
    if [ -n "${TRACE_BACKUP:-}" ] && [ -d "$TRACE_BACKUP" ]; then return 0; fi
    TRACE_BACKUP="$(mktemp -d "${TMPDIR:-/tmp}/moonmux-covtraces.XXXXXX" 2>/dev/null)" \
      || die "mktemp 失败（trace 隔离）"
    TRACE_MANIFEST="$TRACE_BACKUP/manifest.tsv"
    : > "$TRACE_MANIFEST"
    moved=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in
        "$TD_ABS"/*) continue ;;
      esac
      moved=$((moved + 1))
      dst="$TRACE_BACKUP/$moved.$(basename "$f")"
      if mv -f "$f" "$dst" 2>/dev/null; then
        printf '%s\t%s\n' "$f" "$dst" >> "$TRACE_MANIFEST"
      fi
    done <<EOF
$(find "$ROOT" -name 'moonbit_coverage_*' -type f 2>/dev/null)
EOF
    if [ "$moved" -gt 0 ]; then
      printf '   trace 隔离: 临时移开仓库内其它位置的 %s 个历史 trace（报告后恢复）\n' "$moved"
    fi
  }
  isolate_traces_elsewhere

  # 主路径：summary 报告（cwd 必须是 trace 所在目录；source-paths 指回仓库根）
  if ( cd "$TD_ABS" && moon coverage report -f summary --source-paths "$ROOT" ) > "$SUMMARY" 2> "$REPORT_ERR"; then
    MODE="summary"
  else
    MODE=""
  fi
  if ! grep -q '^Total:' "$SUMMARY" 2>/dev/null; then
    # 回退路径：cobertura（口径不同，会在输出中注明）
    if ( cd "$TD_ABS" && moon coverage report -f cobertura -o "$COBERTURA" --source-paths "$ROOT" ) > "$TMP_DIR/cob.log" 2>&1 \
       && [ -s "$COBERTURA" ]; then
      MODE="cobertura-fallback"
    else
      sed -n '1,30p' "$REPORT_ERR" >&2
      die "无法生成 coverage 报告（summary/cobertura 均不可用）；请确认先跑过 moon test --enable-coverage"
    fi
  fi
  # 隔离后仍出现 trace 混用告警 → 视为工具错误（否则会静默给出错误覆盖率）。
  if grep -qE 'Counts array length mismatch|obsolete coverage' "$SUMMARY" "$REPORT_ERR" 2>/dev/null; then
    grep -E 'Counts array length mismatch|obsolete coverage' "$REPORT_ERR" "$SUMMARY" 2>/dev/null | head -5 >&2 || true
    die "coverage 报告检测到 trace 混用（Counts array length mismatch / obsolete coverage）；请先 moon coverage clean 并清理残留 trace 后重跑"
  fi
fi

# ---------- 解析 ----------
if [ "$MODE" = "cobertura-fallback" ]; then
  awk -v metricsf="$METRICS" '
    { xml = xml $0 "\n" }
    END {
      # 总覆盖率：<coverage lines-valid=".." lines-covered=".." line-rate="..">
      if (!match(xml, /<coverage[^>]*line-rate="[0-9.]+"/)) { print "COBERTURA-PARSE-FAIL"; exit 2 }
      s = substr(xml, RSTART, RLENGTH); sub(/.*line-rate="/, "", s); sub(/".*/, "", s)
      total_rate = s + 0
      lib_c = 0; lib_t = 0
      n = split(xml, lines, "\n")
      for (i = 1; i <= n; i++) {
        l = lines[i]
        if (l !~ /<class /) continue
        if (!match(l, /name="[^"]+"/)) continue
        name = substr(l, RSTART + 6, RLENGTH - 7); gsub(/\\/, "/", name)
        covered = ""; valid = ""
        if (match(l, /lines-covered="[0-9]+"/)) { c = substr(l, RSTART, RLENGTH); sub(/.*="/, "", c); sub(/"/, "", c); covered = c + 0 }
        if (match(l, /lines-valid="[0-9]+"/))   { v = substr(l, RSTART, RLENGTH); sub(/.*="/, "", v); sub(/"/, "", v); valid = v + 0 }
        if (covered == "" || valid == "") continue
        if (name ~ /^(cmd\/|examples\/)/ || name == "moonmux.mbt") continue
        lib_c += covered; lib_t += valid
      }
      if (lib_t == 0) { print "COBERTURA-LIB-EMPTY"; exit 2 }
      printf "total %.2f\n", total_rate * 100 > metricsf
      printf "lib %.2f %d %d\n", 100.0 * lib_c / lib_t, lib_c, lib_t >> metricsf
      close(metricsf)
    }
  ' "$COBERTURA" || die "cobertura 回退解析失败（口径: cobertura）"
else
  awk -v metricsf="$METRICS" -v worstf="$WORST" '
    /^Total: [0-9]+\/[0-9]+$/ {
      split($0, a, ": "); split(a[2], b, "/");
      tot_c = b[1] + 0; tot_t = b[2] + 0; next
    }
    /: [0-9]+\/[0-9]+$/ {
      i = index($0, ": "); path = substr($0, 1, i - 1); rest = substr($0, i + 2)
      split(rest, b, "/"); c = b[1] + 0; t = b[2] + 0
      gsub(/\\/, "/", path)
      if (t <= 0) next
      if (path ~ /^(cmd\/|examples\/)/ || path == "moonmux.mbt") { excl_c += c; excl_t += t; next }
      lib_c += c; lib_t += t
      rate = 100.0 * c / t
      print rate "\t" path "\t" c "/" t > worstf
      next
    }
    END {
      if (tot_t <= 0) { print "NO-TOTAL"; exit 2 }
      printf "total %.2f\n", 100.0 * tot_c / tot_t > metricsf
      printf "lib %.2f %d %d\n", (lib_t > 0 ? 100.0 * lib_c / lib_t : 0), lib_c, lib_t >> metricsf
      printf "excluded %d %d\n", excl_c, excl_t >> metricsf
      close(metricsf); close(worstf)
    }
  ' "$SUMMARY"
fi

TOTAL_RATE="$(awk '$1=="total"{print $2}' "$METRICS")"
LIB_RATE="$(awk '$1=="lib"{print $2}' "$METRICS")"
LIB_C="$(awk '$1=="lib"{print $3}' "$METRICS")"
LIB_T="$(awk '$1=="lib"{print $4}' "$METRICS")"
EXCL="$(awk '$1=="excluded"{print $2"/"$3}' "$METRICS" 2>/dev/null || true)"
[ -n "$TOTAL_RATE" ] || die "无法从 coverage 报告解析总覆盖率（口径: $MODE）"
[ -n "$LIB_RATE" ] || die "无法从 coverage 报告解析库层覆盖率（口径: $MODE）"

printf '\n== 结果 ==\n'
case "$MODE" in
  summary|summary-file) printf '   口径: moon coverage report -f summary（行覆盖率）\n' ;;
  cobertura-fallback)   printf '   WARN: summary 不可用，回退 cobertura（可插桩行口径，数值与 summary 不同）\n' ;;
esac
printf '   总覆盖率: %s%%（阈值 %s%%）\n' "$TOTAL_RATE" "$TOTAL_THRESHOLD"
printf '   库层覆盖率: %s%%（%s/%s，阈值 %s%%；排除 cmd/main、examples/*、root）\n' "$LIB_RATE" "$LIB_C" "$LIB_T" "$LIB_THRESHOLD"
[ -n "${EXCL:-}" ] && [ "$EXCL" != "/" ] && printf '   排除代码: %s 行（cmd/main + examples + root）\n' "$EXCL"
if [ -s "$WORST" ]; then
  printf '   库层覆盖率最低的 5 个文件:\n'
  sort -n "$WORST" 2>/dev/null | head -5 | while IFS="$(printf '\t')" read -r rate path ct; do
    printf '     - %-7s %s (%s)\n' "${rate}%" "$path" "$ct"
  done
fi

PASS_TOTAL="$(awk -v v="$TOTAL_RATE" -v th="$TOTAL_THRESHOLD" 'BEGIN { print (v + 0 >= th + 0) ? 1 : 0 }')"
PASS_LIB="$(awk -v v="$LIB_RATE" -v th="$LIB_THRESHOLD" 'BEGIN { print (v + 0 >= th + 0) ? 1 : 0 }')"
if [ "$PASS_TOTAL" = "1" ] && [ "$PASS_LIB" = "1" ]; then
  printf '   PASS: 库层 %s%% >= %s%%，总覆盖率 %s%% >= %s%%\n' "$LIB_RATE" "$LIB_THRESHOLD" "$TOTAL_RATE" "$TOTAL_THRESHOLD"
  exit 0
fi
printf '   FAIL: 库层 %s%%（阈值 %s%%）/ 总覆盖率 %s%%（阈值 %s%%）存在不达标项\n' \
  "$LIB_RATE" "$LIB_THRESHOLD" "$TOTAL_RATE" "$TOTAL_THRESHOLD"
printf '   建议：优先补库包（ogg/codec/mp4/pipeline/wav/cli/manifest）的未覆盖分支。\n'
exit 1
