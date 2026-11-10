#!/usr/bin/env node
// bench.mjs —— moonmux 端到端性能基准
//
// 用法：
//   node scripts/bench.mjs [--bin <path>] [--runs 5]
//
// 前提：已构建 native CLI（release 优先）：
//   moon build --release --target native
//
// 说明：每个操作都是独立子进程，耗时含进程启动（约 1–2 ms）；
// 对小文件这是固定开销，因此同时给出吞吐列（MB/s，按输入大小估算）。
// 参考对象：cargo bench / hyperfine 的「多次运行取最小值」思路，不引入第三方依赖。

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
const RUNS = Number(getArg("--runs", "5"));
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
  const r = spawnSync(BIN, cmdArgs, { encoding: "utf8", timeout: 120000 });
  if (r.error) throw new Error(`启动 CLI 失败: ${r.error.message}`);
  const ms = Number(process.hrtime.bigint() - t0) / 1e6;
  if (r.error || r.status !== 0) {
    throw new Error(
      `命令失败 (${r.status ?? r.signal}): ${BIN} ${cmdArgs.join(" ")}\n${r.stderr ?? ""}`,
    );
  }
  return ms;
}

function measure(name, sizeBytes, makeArgs) {
  const samples = [];
  for (let i = 0; i < RUNS; i++) samples.push(runOnce(makeArgs(i)));
  samples.sort((a, b) => a - b);
  const min = samples[0];
  const median = samples[Math.floor(samples.length / 2)];
  const mbs = sizeBytes > 0 && min > 0 ? sizeBytes / 1048576 / (min / 1000) : 0;
  return { name, sizeBytes, min, median, mbs };
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
rows.push(measure("verify（CRC + 结构体检）", bigSize, () => ["verify", bigOgg]));
rows.push(measure("info --json（页/包统计）", bigSize, () => ["info", bigOgg, "--json"]));
rows.push(measure("dump（页级转储）", bigSize, () => ["dump", bigOgg]));
rows.push(measure("remux（Ogg Opus → MP4）", opusSize, () => ["remux", opus, unique(".m4a")]));
rows.push(measure("to-ogg（MP4 → Ogg Opus）", m4aSize, () => ["to-ogg", smallM4a, unique(".ogg")]));
rows.push(
  measure("demux（拆包写目录）", opusSize, () => {
    const dir = join(TMP, `d${seq++}`);
    mkdirSync(dir, { recursive: true });
    return ["demux", opus, dir];
  }),
);

// ---------- 输出 ----------

console.log(`# moonmux 性能基准`);
console.log("");
console.log(`- 运行环境：${process.platform} ${process.arch}，Node ${process.version}`);
console.log(`- CLI：${BIN}`);
console.log(`- 输入：big.ogg = ${(bigSize / 1024).toFixed(1)} KiB（16 条链接流），opus_sample.opus = ${(opusSize / 1024).toFixed(1)} KiB`);
console.log(`- 每项运行 ${RUNS} 次取最小值（含进程启动开销）`);
console.log("");
console.log("| 操作 | 输入 | 最小耗时 (ms) | 中位 (ms) | 吞吐 (MB/s) |");
console.log("|---|---:|---:|---:|---:|");
for (const r of rows) {
  const size = r.sizeBytes >= 1048576 ? `${(r.sizeBytes / 1048576).toFixed(2)} MiB` : `${(r.sizeBytes / 1024).toFixed(1)} KiB`;
  console.log(`| ${r.name} | ${size} | ${r.min.toFixed(1)} | ${r.median.toFixed(1)} | ${r.mbs > 0 ? r.mbs.toFixed(0) : "—"} |`);
}
console.log("");
console.log("说明：数值为端到端进程耗时，含 1–2 ms 启动开销；小文件项以绝对耗时为准。");
