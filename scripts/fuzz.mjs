#!/usr/bin/env node
// fuzz.mjs —— moonmux 的确定性变异测试（mutation fuzz）
//
// 用法：
//   node scripts/fuzz.mjs [--bin <path>] [--iterations 300] [--seed 20261109]
//
// 前提：已构建 native CLI（debug 或 release 均可）：
//   moon build --target native
//
// 思路参考 cargo-fuzz / AFL++ 的「种子 + 确定性变异」模式（不引入第三方依赖）：
//   - 种子：真实 Ogg Opus / Vorbis、CLI 生成的 MP4 与 WAV；
//   - 变异：随机翻位、块覆盖、截断、插入、删除、整段复制；
//   - 目标：info / verify / seek / dump / to-ogg 等只读或单文件命令；
//   - 断言：退出码只能是 0/1/2（0 成功、1 数据错误、2 用法/I/O），
//           不能超时、不能被信号杀死、不能崩溃。
//
// 失败时打印复现信息（种子、迭代号、变异文件保留在 --keep 目录）。

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
function getArg(name, fallback) {
  const i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
}
const BIN =
  getArg("--bin", "") ||
  [
    "_build/native/debug/build/cmd/main/main.exe",
    "_build/native/debug/build/cmd/main/main",
    "_build/native/release/build/cmd/main/main.exe",
    "_build/native/release/build/cmd/main/main",
  ]
    .map((p) => join(ROOT, p))
    .find((p) => existsSync(p));
const ITERATIONS = Number(getArg("--iterations", "300"));
const SEED = Number(getArg("--seed", "20261109"));
const TIMEOUT_MS = Number(getArg("--timeout-ms", "10000"));
const KEEP = args.includes("--keep");

if (!BIN) {
  console.error("找不到 native CLI。先运行: moon build --target native");
  process.exit(2);
}

mkdirSync(join(ROOT, "_build"), { recursive: true });
const TMP = mkdtempSync(join(ROOT, "_build", "fuzz-"));
process.on("exit", () => {
  if (!KEEP) rmSync(TMP, { recursive: true, force: true });
  else console.error(`保留变异样本目录: ${TMP}`);
});

// ---------- 确定性 PRNG（mulberry32） ----------

function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const rng = mulberry32(SEED);
const randInt = (n) => Math.floor(rng() * n);
const randRange = (a, b) => a + randInt(Math.max(1, b - a));

// ---------- 种子准备 ----------

function gen(args2, out) {
  const r = spawnSync(BIN, [...args2, out], { encoding: "utf8", timeout: TIMEOUT_MS });
  if (r.error) throw new Error(`启动 CLI 失败: ${r.error.message}`);
  if (r.status !== 0) throw new Error(`生成种子失败: ${args2.join(" ")}`);
  return readFileSync(out);
}

const seeds = [];
function addSeed(name, bytes, commands) {
  seeds.push({ name, bytes, commands });
}
addSeed("ogg-opus", readFileSync(join(ROOT, "testdata/opus_sample.opus")), ["info", "verify", "seek0", "dump", "remux"]);
addSeed("ogg-vorbis", readFileSync(join(ROOT, "testdata/vorbis_sample.ogg")), ["info", "verify", "seek0", "dump"]);
const m4a = gen(["remux", join(ROOT, "testdata/opus_sample.opus")], join(TMP, "seed.m4a"));
addSeed("mp4-opus", m4a, ["info", "to-ogg"]);
const wav = gen(["to-wav", join(ROOT, "testdata/opus_sample.opus")], join(TMP, "seed.wav"));
addSeed("wav", wav, ["info"]);

// ---------- 变异 ----------

function mutate(src) {
  let b = Buffer.from(src);
  const kind = randInt(6);
  switch (kind) {
    case 0: {
      // 随机翻位
      const n = randRange(1, 9);
      for (let i = 0; i < n; i++) {
        const at = randInt(b.length);
        b[at] ^= 1 << randInt(8);
      }
      break;
    }
    case 1: {
      // 随机块覆盖（随机字节）
      const at = randInt(b.length);
      const len = randRange(1, Math.min(64, b.length - at));
      for (let i = 0; i < len; i++) b[at + i] = randInt(256);
      break;
    }
    case 2:
      // 截断
      b = b.subarray(0, randInt(b.length));
      break;
    case 3: {
      // 中间插入随机字节
      const at = randInt(b.length);
      const ins = Buffer.alloc(randRange(1, 32), 0);
      for (let i = 0; i < ins.length; i++) ins[i] = randInt(256);
      b = Buffer.concat([b.subarray(0, at), ins, b.subarray(at)]);
      break;
    }
    case 4: {
      // 删除一段
      const at = randInt(b.length);
      const len = randRange(1, Math.min(64, b.length - at));
      b = Buffer.concat([b.subarray(0, at), b.subarray(at + len)]);
      break;
    }
    default: {
      // 复制一段拼到随机位置（制造重复页/重复包）
      const at = randInt(b.length);
      const len = randRange(1, Math.min(256, b.length - at));
      const slice = b.subarray(at, at + len);
      const insertAt = randInt(b.length);
      b = Buffer.concat([b.subarray(0, insertAt), slice, b.subarray(insertAt)]);
      break;
    }
  }
  return b;
}

// ---------- 执行与断言 ----------

function commandArgs(name, file, outPath) {
  switch (name) {
    case "info":
      return ["info", file];
    case "verify":
      return ["verify", file];
    case "seek0":
      return ["seek", file, "0"];
    case "dump":
      return ["dump", file];
    case "to-ogg":
      return ["to-ogg", file, outPath];
    case "remux":
      return ["remux", file, outPath];
    default:
      throw new Error(`未知命令 ${name}`);
  }
}

let runs = 0;
let ok = 0;
let dataErrors = 0;
const failures = [];

for (let iter = 0; iter < ITERATIONS; iter++) {
  const seed = seeds[randInt(seeds.length)];
  const mutated = mutate(seed.bytes);
  const file = join(TMP, `m${iter}.bin`);
  writeFileSync(file, mutated);
  // 每个变异样本随机跑一条命令（保证样本覆盖）
  const cmd = seed.commands[randInt(seed.commands.length)];
  const out = join(TMP, `o${iter}.bin`);
  const r = spawnSync(BIN, commandArgs(cmd, file, out), { encoding: "utf8", timeout: TIMEOUT_MS });
  runs++;
  const status = r.status;
  if (r.error && r.error.code !== "ETIMEDOUT") {
    // 二进制不存在/不可执行等启动失败，不能伪装成「超时」
    failures.push({ iter, seed: seed.name, cmd, reason: "启动失败: " + r.error.message });
    continue;
  }
  // 平台差异：Windows 上 panic 可能以崩溃码结束，Linux 上可能只是 exit(1)；
  // 只看退出码会把 Linux 的 panic 误判成普通数据错误，所以额外检查 stderr。
  const fuzzStderr = r.stderr || "";
  if (fuzzStderr.includes("PanicError") || /panic/i.test(fuzzStderr)) {
    failures.push({
      iter,
      seed: seed.name,
      cmd,
      reason: "疑似 panic",
      stderr: fuzzStderr.slice(0, 400),
    });
    continue;
  }
  if (r.error?.code === "ETIMEDOUT" || (status === null && r.signal)) {
    failures.push({ iter, seed: seed.name, cmd, reason: "超时/被信号杀死", signal: r.signal });
    continue;
  }
  if (status === null) {
    failures.push({ iter, seed: seed.name, cmd, reason: "进程未启动（status=null）" });
    continue;
  }
  if (status === 0) {
    ok++;
  } else if (status === 1 || status === 2) {
    dataErrors++;
  } else {
    failures.push({ iter, seed: seed.name, cmd, reason: `非法退出码 ${status}`, stderr: (r.stderr || "").slice(0, 400) });
  }
}

console.log(`# moonmux mutation fuzz`);
console.log("");
console.log(`- CLI：${BIN}`);
console.log(`- 种子：${seeds.map((s) => s.name).join(", ")}`);
console.log(`- 迭代：${ITERATIONS}，随机种子：${SEED}`);
console.log(`- 结果：运行 ${runs} 次 · 成功 ${ok} · 数据/用法错误 ${dataErrors} · 异常 ${failures.length}`);
if (failures.length > 0) {
  console.log("");
  console.log("异常样本（可复现）：");
  for (const f of failures.slice(0, 10)) {
    console.log(`- iter=${f.iter} seed=${f.seed} cmd=${f.cmd} ${f.reason}${f.stderr ? ` stderr=${f.stderr.replace(/\s+/g, " ")}` : ""}`);
  }
  process.exit(1);
}
console.log("");
console.log("全部变异均落在 0/1/2 退出码内，无崩溃、无超时。");
