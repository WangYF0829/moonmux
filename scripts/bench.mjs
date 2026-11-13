#!/usr/bin/env node
// bench.mjs —— moonmux 端到端性能基准（支持基线阈值、小操作噪声下限与峰值内存）
//
// 用法：
//   node scripts/bench.mjs [--bin <path>] [--runs 5] [--batches 1]
//   node scripts/bench.mjs --baseline scripts/bench-baseline.json [--fail-over 0.10]
//   node scripts/bench.mjs --baseline scripts/bench-baseline.json --noise-floor 4 --no-mem
//   node scripts/bench.mjs --json-out _review/evidence/bench.json   # 机器可读结果（生成基线用）
//
// 前提：已构建 native CLI（release 优先）：
//   moon build --release --target native
//
// 说明：
//   * 每个操作都是独立子进程，耗时含进程启动（约 1–2 ms）；对小文件这是固定开销，
//     因此同时给出吞吐列（MB/s，按输入大小估算）。
//   * 无 --baseline 时保持"只记录"模式（退出码 0），与旧行为兼容。
//   * 有 --baseline 时按 min_ms 与基线比较，判定阈值 =
//       - 小操作（基线 < 50 ms）：max(--fail-over × 基线, --noise-floor 绝对毫秒数)
//         原因：~20 ms 的操作里进程启动/调度抖动就是 1–2 ms，10% 比例阈值（≈2 ms）
//         会被负载噪声误触（实测 remux 22.0 vs 19.8 = +11% 但无真实回退）；
//         默认绝对噪声下限 4 ms，可用 --noise-floor 调整（0 = 关闭）。
//       - 大操作（基线 ≥ 50 ms）：严格按 --fail-over 比例判定。
//     共享 CI runner 与基线机器不同，跨平台时脚本自动降级为"仅记录+WARN"（见 PLATFORM_MISMATCH）。
//   * 采样策略：每项跑 --runs 次取最小值；--batches N 表示把采样分 N 批重复（总样本
//     runs×batches，仍是 min-of-min），用于空闲机器上生成稳定基线（建议 --batches 3）。
//   * 峰值内存（--no-mem 可关闭）：
//       - Linux：/usr/bin/time -v 的 Maximum resident set size（kB），逐项单独采样一次；
//       - Windows：PowerShell Start-Process 轮询 WorkingSet64 采样一次；
//       - 其他平台或工具缺失：降级为"未测量"，不影响退出码。
//     内存采样在计时结束后单独进行，不污染耗时样本。
//
// 退出码：0 = 通过/只记录；1 = 基线劣化超阈值；2 = 环境/参数错误。

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
function getArg(name, fallback) {
  const i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
}
function hasFlag(name) {
  return args.includes(name);
}

const RUNS = Number(getArg("--runs", "5"));
const BATCHES = Number(getArg("--batches", "1"));
const NOISE_FLOOR_MS_RAW = getArg("--noise-floor", "4");const JSON_OUT = getArg("--json-out", "");
const BASELINE_PATH = getArg("--baseline", "");
const FAIL_OVER_RAW = getArg("--fail-over", "");
const NO_MEM = hasFlag("--no-mem");
const BIN =
  getArg("--bin", "") ||
  [
    "_build/native/release/build/cmd/main/main.exe",
    "_build/native/release/build/cmd/main/main",
    "_build/native/debug/build/cmd/main/main.exe",
    "_build/native/debug/build/cmd/main/main",
  ]
    .map((p) => join(ROOT, p))
    .find((p) => existsSync(p));

if (!BIN) {
  console.error("找不到 native CLI。先运行: moon build --release --target native");
  process.exit(2);
}
if (!Number.isFinite(RUNS) || RUNS < 1 || RUNS > 100) {
  console.error(`--runs 非法: ${getArg("--runs", "")}`);
  process.exit(2);
}
if (!Number.isFinite(BATCHES) || BATCHES < 1 || BATCHES > 20) {
  console.error(`--batches 非法: ${getArg("--batches", "")}（1..20）`);
  process.exit(2);
}
let NOISE_FLOOR_MS = Number(NOISE_FLOOR_MS_RAW);
if (!Number.isFinite(NOISE_FLOOR_MS) || NOISE_FLOOR_MS < 0 || NOISE_FLOOR_MS > 1000) {
  console.error(`--noise-floor 非法: ${NOISE_FLOOR_MS_RAW}（0..1000 毫秒，0=关闭）`);
  process.exit(2);
}
// 小操作（基线 < 50 ms）的判定：比例阈值 + 绝对噪声下限（取较大者）。
const SMALL_OP_BASELINE_MS = 50;
const NOISE_FLOOR_GIVEN = args.includes("--noise-floor");

// ---------- 基线 ----------
let baseline = null;
if (BASELINE_PATH) {
  const p = resolve(ROOT, BASELINE_PATH);
  if (!existsSync(p)) {
    console.error(`基线文件不存在: ${p}`);
    process.exit(2);
  }
  try {
    baseline = JSON.parse(readFileSync(p, "utf8"));
  } catch (e) {
    console.error(`基线 JSON 解析失败: ${p}: ${e.message}`);
    process.exit(2);
  }
  if (!baseline || typeof baseline.metrics !== "object") {
    console.error(`基线格式错误（缺少 metrics）: ${p}`);
    process.exit(2);
  }
  // 基线可携带 noise_floor_ms 策略值（未显式传 --noise-floor 时采用）。
  const bnf = Number(baseline.noise_floor_ms);
  if (!NOISE_FLOOR_GIVEN && Number.isFinite(bnf) && bnf >= 0 && bnf <= 1000) {
    NOISE_FLOOR_MS = bnf;
  }
}
let FAIL_OVER = baseline ? Number(baseline.fail_over_default ?? 0.1) : 0;
if (FAIL_OVER_RAW !== "") {
  FAIL_OVER = Number(FAIL_OVER_RAW);
}
if (!Number.isFinite(FAIL_OVER) || FAIL_OVER < 0 || FAIL_OVER > 10) {
  console.error(`--fail-over 非法: ${FAIL_OVER_RAW}（应为 0..10 的比例，如 0.10）`);
  process.exit(2);
}
// 基线平台与当前平台不一致时，绝对耗时不可比：只记录、不做阈值判定（避免误红）。
let PLATFORM_MISMATCH = false;
if (baseline) {
  const envOs = String(baseline.environment?.os ?? "").toLowerCase();
  const expected =
    envOs.includes("windows") ? "win32" : envOs.includes("linux") ? "linux" : envOs.includes("mac") ? "darwin" : "";
  if (expected && expected !== process.platform) {
    PLATFORM_MISMATCH = true;
    console.error(
      `WARN: 基线环境为 ${baseline.environment?.os}，当前平台 ${process.platform}；` +
        `绝对耗时不可比，本次仅记录不判定阈值（如需门禁请生成同平台基线）。`,
    );
  }
}
if (baseline) {
  console.log(
    `# 基线：${BASELINE_PATH}（fail-over=${(FAIL_OVER * 100).toFixed(0)}%；` +
      `小操作<${SMALL_OP_BASELINE_MS}ms 绝对噪声下限 ${NOISE_FLOOR_MS}ms；采样 ${RUNS}×${BATCHES}）`,
  );
}

mkdirSync(join(ROOT, "_build"), { recursive: true });
const TMP = mkdtempSync(join(ROOT, "_build", "bench-"));
process.on("exit", () => rmSync(TMP, { recursive: true, force: true }));

// ---------- Ogg 页处理：把同一个文件复制成多条 serial 递增的逻辑流，拼出大文件 ----------
// 只用于基准输入构造；moonmux 自身写侧仍是唯一的正确性来源。

const CRC_TABLE = new Uint32Array(256);
for (let i = 0; i < 256; i++) {
  let r = i << 24;
  for (let j = 0; j < 8; j++) {
    r = r & 0x80000000 ? (r << 1) ^ 0x04c11db7 : r << 1;
  }
  CRC_TABLE[i] = r >>> 0;
}
function oggCrc(bytes) {
  let c = 0;
  for (let i = 0; i < bytes.length; i++) {
    c = ((c << 8) >>> 0) ^ CRC_TABLE[((c >>> 24) ^ bytes[i]) & 0xff];
  }
  return c >>> 0;
}

function rewriteSerial(page, serial) {
  const buf = Buffer.from(page);
  buf.writeUInt32LE(0, 22); // CRC 字段置零
  buf.writeUInt32LE(serial, 14);
  const crc = oggCrc(buf);
  buf.writeUInt32LE(crc, 22);
  return buf;
}

function repeatChainedOgg(srcPath, copies) {
  const src = readFileSync(srcPath);
  const out = [];
  for (let copy = 0; copy < copies; copy++) {
    let off = 0;
    while (off + 27 <= src.length) {
      if (src.toString("latin1", off, off + 4) !== "OggS") {
        throw new Error(`bad page at offset ${off}`);
      }
      const nseg = src[off + 26];
      let payload = 0;
      for (let i = 0; i < nseg; i++) payload += src[off + 27 + i];
      const end = off + 27 + nseg + payload;
      out.push(rewriteSerial(src.subarray(off, end), 0x1000 + copy));
      off = end;
    }
  }
  return Buffer.concat(out);
}

// ---------- 测量 ----------

function runOnce(cmdArgs) {
  const t0 = process.hrtime.bigint();
  let r = spawnSync(BIN, cmdArgs, { encoding: "utf8", timeout: 120000 });
  if (r.error && r.error.code === "EPERM") {
    // 受限沙箱（如本审查环境）禁止管道 stdio：退回 stdio=ignore 只测耗时/退出码。
    r = spawnSync(BIN, cmdArgs, { stdio: ["ignore", "ignore", "inherit"], timeout: 120000 });
  }
  if (r.error) throw new Error(`启动 CLI 失败: ${r.error.message}`);
  const ms = Number(process.hrtime.bigint() - t0) / 1e6;
  if (r.error || r.status !== 0) {
    throw new Error(
      `命令失败 (${r.status ?? r.signal}): ${BIN} ${cmdArgs.join(" ")}\n${r.stderr ?? ""}`,
    );
  }
  return ms;
}

function measure(name, key, sizeBytes, makeArgs) {
  // min-of-min：分 BATCHES 批、每批 RUNS 个样本，取全局最小（批间间隔让突发噪声不落在同一批）。
  const samples = [];
  const total = RUNS * BATCHES;
  for (let i = 0; i < total; i++) samples.push(runOnce(makeArgs(i)));
  samples.sort((a, b) => a - b);
  const min = samples[0];
  const median = samples[Math.floor(samples.length / 2)];
  const mbs = sizeBytes > 0 && min > 0 ? sizeBytes / 1048576 / (min / 1000) : 0;
  return { name, key, sizeBytes, min, median, mbs, memBytes: null, samples: total };
}

// ---------- 峰值内存（单独一次采样，不计入耗时） ----------

const TIME_BIN = "/usr/bin/time";

function windowsQuote(s) {
  // Windows CommandLineToArgvW 兼容的双引号转义
  return '"' + String(s).replace(/(\\*)"/g, "$1$1\\").replace(/(\\+)$/, "$1$1") + '"';
}

function measurePeakRss(cmdArgs) {
  if (process.platform === "linux" && existsSync(TIME_BIN)) {
    const r = spawnSync(TIME_BIN, ["-v", BIN, ...cmdArgs], { encoding: "utf8", timeout: 120000 });
    if (r.error || r.status !== 0) return { bytes: null, note: `time -v 失败: ${r.error?.message ?? r.status}` };
    const m = /Maximum resident set size \(kbytes\):\s*(\d+)/.exec(r.stderr ?? "");
    return m ? { bytes: Number(m[1]) * 1024, note: "linux /usr/bin/time -v" } : { bytes: null, note: "未解析到 Maximum resident set size" };
  }
  if (process.platform === "win32") {
    // 用 PowerShell 轮询 WorkingSet64；-EncodedCommand 避免多层引号转义问题。
    const quotedArgs = cmdArgs.map(windowsQuote).join(" ");
    const ps = [
      "$ErrorActionPreference='Stop'",
      "$psi = New-Object System.Diagnostics.ProcessStartInfo",
      `$psi.FileName = '${BIN.replace(/'/g, "''")}'`,
      `$psi.Arguments = '${quotedArgs.replace(/'/g, "''")}'`,
      "$psi.UseShellExecute = $false",
      "$psi.CreateNoWindow = $true",
      "$p = [System.Diagnostics.Process]::Start($psi)",
      "$peak = 0",
      "while (-not $p.HasExited) {",
      "  try { $p.Refresh(); if ($p.WorkingSet64 -gt $peak) { $peak = $p.WorkingSet64 } } catch { break }",
      "  Start-Sleep -Milliseconds 5",
      "}",
      "$p.WaitForExit()",
      "Write-Output ('PEAK_RSS_BYTES=' + $peak)",
      "Write-Output ('EXIT_CODE=' + $p.ExitCode)",
    ].join("\n");
    const encoded = Buffer.from(ps, "utf16le").toString("base64");
    const r = spawnSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-EncodedCommand", encoded], {
      encoding: "utf8",
      timeout: 120000,
    });
    if (r.error && r.error.code === "EPERM") return { bytes: null, note: "沙箱禁止管道 stdio，跳过内存采样" };
    if (r.error) return { bytes: null, note: `PowerShell 采样失败: ${r.error.message}` };
    const pm = /PEAK_RSS_BYTES=(\d+)/.exec(r.stdout ?? "");
    const em = /EXIT_CODE=(-?\d+)/.exec(r.stdout ?? "");
    if (!pm || (em && Number(em[1]) !== 0)) return { bytes: null, note: "PowerShell 采样未得到有效结果" };
    return { bytes: Number(pm[1]), note: "windows PowerShell WorkingSet64 采样" };
  }
  return { bytes: null, note: "平台不支持内存采样（已降级）" };
}

// ---------- 准备输入 ----------

const opus = join(ROOT, "testdata/opus_sample.opus");
const vorbis = join(ROOT, "testdata/vorbis_sample.ogg");
if (!existsSync(opus) || !existsSync(vorbis)) {
  console.error("缺少 testdata/opus_sample.opus 或 testdata/vorbis_sample.ogg");
  process.exit(2);
}

const bigOgg = join(TMP, "big.ogg");
writeFileSync(bigOgg, repeatChainedOgg(opus, 16)); // ≈1.0 MiB，16 条链接流
const bigSize = statSync(bigOgg).size;
const opusSize = statSync(opus).size;

// remux 只支持单段单流：用原始小文件生成 MP4，再做 to-ogg
const smallM4a = join(TMP, "small.m4a");
runOnce(["remux", opus, smallM4a]);
const m4aSize = statSync(smallM4a).size;

// ---------- 基准项 ----------

const rows = [];
let seq = 0;
const unique = (ext) => join(TMP, `f${seq++}${ext}`);
rows.push(measure("verify（CRC + 结构体检）", "verify", bigSize, () => ["verify", bigOgg]));
rows.push(measure("info --json（页/包统计）", "info", bigSize, () => ["info", bigOgg, "--json"]));
rows.push(measure("dump（页级转储）", "dump", bigSize, () => ["dump", bigOgg]));
rows.push(measure("remux（Ogg Opus → MP4）", "remux", opusSize, () => ["remux", opus, unique(".m4a")]));
rows.push(measure("to-ogg（MP4 → Ogg Opus）", "to-ogg", m4aSize, () => ["to-ogg", smallM4a, unique(".ogg")]));
rows.push(
  measure("demux（拆包写目录）", "demux", opusSize, () => {
    const dir = join(TMP, `d${seq++}`);
    mkdirSync(dir, { recursive: true });
    return ["demux", opus, dir];
  }),
);

// ---------- 峰值内存（单独采样一次；失败降级） ----------

let memNote = "";
if (!NO_MEM) {
  const notes = [];
  for (const row of rows) {
    const argsFor = (() => {
      switch (row.key) {
        case "verify":
          return ["verify", bigOgg];
        case "info":
          return ["info", bigOgg, "--json"];
        case "dump":
          return ["dump", bigOgg];
        case "remux":
          return ["remux", opus, unique(".m4a")];
        case "to-ogg":
          return ["to-ogg", smallM4a, unique(".ogg")];
        case "demux": {
          const dir = join(TMP, `dm${seq++}`);
          mkdirSync(dir, { recursive: true });
          return ["demux", opus, dir];
        }
        default:
          return null;
      }
    })();
    if (!argsFor) continue;
    const { bytes, note } = measurePeakRss(argsFor);
    if (bytes !== null) row.memBytes = bytes;
    if (note && !notes.includes(note)) notes.push(note);
  }
  memNote = notes.join("；");
}

// ---------- 基线比较 ----------

let regressions = 0;
const metricOf = (key) => {
  const m = baseline?.metrics?.[key];
  if (m === undefined || m === null) return null;
  const v = typeof m === "number" ? m : Number(m.value);
  return Number.isFinite(v) ? v : null;
};

for (const row of rows) {
  const base = metricOf(row.key);
  row.baseline = base;
  row.delta = base && base > 0 ? (row.min - base) / base : null;
  row.deltaMs = base && base > 0 ? row.min - base : null;
  row.toleranceMs = null;
  row.tolKind = "";
  row.status = "";
  if (base === null) {
    row.status = baseline ? "无基线项" : "";
    continue;
  }
  // 小操作：允许波动 = max(fail_over×基线, 绝对噪声下限)；大操作：严格比例。
  const ratioTol = FAIL_OVER * base;
  const absNoise = base < SMALL_OP_BASELINE_MS ? NOISE_FLOOR_MS : 0;
  const allowed = Math.max(ratioTol, absNoise);
  row.toleranceMs = allowed;
  row.tolKind = absNoise > ratioTol ? "噪声下限" : "";
  const exceeded = row.min - base > allowed;
  if (exceeded && !PLATFORM_MISMATCH) {
    row.status = "FAIL(劣化)";
    regressions++;
  } else if (exceeded) {
    row.status = "PASS(跨平台仅记录)";
  } else if (row.delta !== null && row.delta >= -0.05) {
    row.status = "PASS";
  } else if (row.delta !== null) {
    row.status = "PASS(更快)";
  }
}

// ---------- 输出 ----------

const memFmt = (b) => (b === null || b === undefined ? "—" : `${(b / 1048576).toFixed(1)} MiB`);
const baseFmt = (b) => (b === null || b === undefined ? "—" : b.toFixed(1));
const deltaFmt = (d) => (d === null || d === undefined ? "—" : `${d >= 0 ? "+" : ""}${(d * 100).toFixed(1)}%`);
const tolFmt = (r) => {
  if (r.toleranceMs === null || r.toleranceMs === undefined) return "—";
  return `+${r.toleranceMs.toFixed(1)}${r.tolKind ? "(" + r.tolKind + ")" : ""}`;
};

console.log(`# moonmux 性能基准`);
console.log("");
console.log(`- 运行环境：${process.platform} ${process.arch}，Node ${process.version}`);
console.log(`- CLI：${BIN}`);
console.log(`- 输入：big.ogg = ${(bigSize / 1024).toFixed(1)} KiB（16 条链接流），opus_sample.opus = ${(opusSize / 1024).toFixed(1)} KiB`);
console.log(`- 采样：每项 ${RUNS} 次 × ${BATCHES} 批取最小值（共 ${RUNS * BATCHES} 样本，含进程启动开销）`);
if (baseline) {
  console.log(
    `- 基线：${BASELINE_PATH}（metric=${baseline.metric ?? "min_ms"}，fail-over=${(FAIL_OVER * 100).toFixed(0)}%，` +
      `小操作<${SMALL_OP_BASELINE_MS}ms 绝对噪声下限=${NOISE_FLOOR_MS}ms）`,
  );
}
if (!NO_MEM) {
  console.log(`- 峰值内存：${memNote || "未测量（已降级）"}`);
}
console.log("");
console.log("| 操作 | 输入 | 最小耗时 (ms) | 中位 (ms) | 吞吐 (MB/s) | 峰值内存 | 基线 (ms) | Δ | 允许波动 (ms) | 状态 |");
console.log("|---|---:|---:|---:|---:|---:|---:|---:|---:|---|");
for (const r of rows) {
  const size = r.sizeBytes >= 1048576 ? `${(r.sizeBytes / 1048576).toFixed(2)} MiB` : `${(r.sizeBytes / 1024).toFixed(1)} KiB`;
  console.log(
    `| ${r.name} | ${size} | ${r.min.toFixed(1)} | ${r.median.toFixed(1)} | ${r.mbs > 0 ? r.mbs.toFixed(0) : "—"} | ${memFmt(r.memBytes)} | ${baseFmt(r.baseline)} | ${deltaFmt(r.delta)} | ${tolFmt(r)} | ${r.status} |`,
  );
}
console.log("");
console.log("说明：数值为端到端进程耗时，含 1–2 ms 启动开销；小文件项以绝对耗时为准，阈值带绝对噪声下限。");

// 机器可读结果（用于在空闲机器上生成/更新 scripts/bench-baseline.json）。
if (JSON_OUT) {
  const outPath = resolve(ROOT, JSON_OUT);
  const payload = {
    schema: "moonmux-bench-result/1",
    generated_at: new Date().toISOString(),
    platform: process.platform,
    arch: process.arch,
    node: process.version,
    runs: RUNS,
    batches: BATCHES,
    samples_per_op: RUNS * BATCHES,
    noise_floor_ms: NOISE_FLOOR_MS,
    fail_over: FAIL_OVER,
    baseline: BASELINE_PATH || null,
    platform_mismatch: PLATFORM_MISMATCH,
    rows: rows.map((r) => ({
      key: r.key,
      name: r.name,
      min_ms: Number(r.min.toFixed(3)),
      median_ms: Number(r.median.toFixed(3)),
      mbs: Number(r.mbs.toFixed(1)),
      peak_rss_bytes: r.memBytes,
      baseline_ms: r.baseline,
      delta: r.delta,
      delta_ms: r.deltaMs,
      tolerance_ms: r.toleranceMs,
      status: r.status,
    })),
  };
  try {
    writeFileSync(outPath, JSON.stringify(payload, null, 2) + "\n", "utf8");
    console.log(`JSON 结果已写入: ${outPath}`);
  } catch (e) {
    console.error(`WARN: --json-out 写入失败: ${outPath}: ${e.message}`);
  }
}

if (baseline) {
  if (regressions > 0) {
    console.error("");
    console.error(
      `FAIL: ${regressions} 项超过基线阈值（fail-over=${(FAIL_OVER * 100).toFixed(0)}%，` +
        `小操作<${SMALL_OP_BASELINE_MS}ms 绝对噪声下限=${NOISE_FLOOR_MS}ms）：`,
    );
    for (const r of rows) {
      if (r.status.startsWith("FAIL"))
        console.error(
          `  - ${r.key}: ${r.min.toFixed(1)} ms vs 基线 ${r.baseline.toFixed(1)} ms（${deltaFmt(r.delta)}，允许 +${r.toleranceMs.toFixed(1)} ms）`,
        );
    }
    console.error("若确认为预期变更，请在同一 commit 更新 scripts/bench-baseline.json 并在提交说明中给出新实测值。");
    process.exit(1);
  }
  console.log(
    `PASS: 全部 ${rows.length} 项在基线阈值内（fail-over=${(FAIL_OVER * 100).toFixed(0)}%，` +
      `小操作<${SMALL_OP_BASELINE_MS}ms 绝对噪声下限=${NOISE_FLOOR_MS}ms）。`,
  );
}
process.exit(0);
