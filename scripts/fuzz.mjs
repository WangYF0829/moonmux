#!/usr/bin/env node
// fuzz.mjs —— moonmux 的确定性变异测试（mutation fuzz）
//
// 用法：
//   node scripts/fuzz.mjs [--bin <path>] [--iterations 300] [--seed 20261109]
//                         [--seeds 20261109,20261224] [--timeout-ms 10000] [--keep]
//
// 前提：已构建 native CLI（debug 或 release 均可）：
//   moon build --target native
//
// 思路参考 cargo-fuzz / AFL++ 的「种子 + 确定性变异」模式（不引入第三方依赖）：
//   - 种子：真实 Ogg Opus / Vorbis、CLI 生成的 MP4 与 WAV；
//   - 变异：随机翻位、块覆盖、截断、插入、删除、整段复制；
//   - 目标：info / verify / seek / dump / to-ogg / remux 等只读或单文件命令；
//   - 断言：退出码只能是 0/1/2（0 成功、1 数据错误、2 用法/I/O），
//           不能超时、不能被信号杀死、不能崩溃；
//   - 成功退出时必须“言之有物”：产物可被 info 读回、--json 可解析，
//     remux/to-ogg 的产物还能被 verify（以及往返）验证；
//   - panic 检测同时扫 stdout 与 stderr，并识别负退出码 / Windows 崩溃码
//     （0xC0000409 fail-fast、0xC0000005 访问违例等）。
//
// 确定性：默认固定种子 20261109。每一轮迭代的随机流由
// `mulberry32(seed ^ (iter * 0x9E3779B1))` 单独派生，因此同一 `--seed` +
// `--iterations N` 必定重放同样的变异；`--seeds a,b,c` 让多组固定种子按迭代
// 轮换（仍然完全确定），用于扩大覆盖而不引入时间/环境随机性。
//
// 失败时打印复现信息（种子、迭代号、变异文件保留在 --keep 目录）。

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
const BASE_SEED = Number(getArg("--seed", "20261109"));
const SEED_LIST = getArg("--seeds", "")
  .split(",")
  .map((s) => s.trim())
  .filter((s) => s !== "")
  .map(Number)
  .filter((n) => Number.isFinite(n));
const SEEDS = SEED_LIST.length > 0 ? SEED_LIST : [BASE_SEED];
const TIMEOUT_MS = Number(getArg("--timeout-ms", "10000"));
const KEEP = args.includes("--keep");
// 成功样本的产物校验会额外启动 CLI；设上限避免成功率高时把总耗时翻几倍。
const MAX_VALIDATIONS = Number(getArg("--max-validations", "40"));

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
// 每轮迭代独立派生随机流：固定 seed + 迭代号 → 可逐轮复现。
function rngFor(iter) {
  const seed = SEEDS[iter % SEEDS.length];
  return mulberry32((seed ^ Math.imul(iter, 0x9e3779b1)) >>> 0);
}

// ---------- 子进程运行 / 崩溃与 panic 判定 ----------

function runCli(argv) {
  const r = spawnSync(BIN, argv, { encoding: "utf8", timeout: TIMEOUT_MS });
  return {
    error: r.error,
    status: r.status,
    signal: r.signal,
    stdout: r.stdout || "",
    stderr: r.stderr || "",
  };
}

// panic 输出可能出现在 stdout（部分语言运行时把 panic 打到 stdout）或 stderr。
const PANIC_RE = /PanicError|\bpanic\b|Aborted|unreachable|Invalid_argument|Fatal error|assertion failed/i;

// Windows 常见崩溃码（NTSTATUS / fail-fast）；负值同样视为崩溃。
const WINDOWS_CRASH_CODES = new Map([
  [0xc0000005, "访问违例 (0xC0000005)"],
  [0xc0000409, "fail-fast / 栈溢出 (0xC0000409)"],
  [0xc00000fd, "栈溢出 (0xC00000FD)"],
  [0xc0000139, "入口点缺失 (0xC0000139)"],
  [0xc0000374, "堆损坏 (0xC0000374)"],
  [0x80000003, "断点 (0x80000003)"],
]);

function crashLabel(status, signal) {
  if (signal) return `被信号杀死: ${signal}`;
  if (status === null) return "进程未启动（status=null）";
  if (status < 0) return `崩溃退出码 ${status}`;
  if (status > 2) {
    const hex = (status >>> 0).toString(16).toUpperCase();
    const known = WINDOWS_CRASH_CODES.get(status >>> 0);
    return known === undefined
      ? `非法退出码 ${status}（0x${hex}）`
      : `崩溃退出码 ${status}：${known}`;
  }
  return null;
}

function panicOutput(stdout, stderr) {
  const hit = [stderr, stdout].find((s) => s !== "" && PANIC_RE.test(s));
  if (hit === undefined) return null;
  const lines = hit.split(/\r?\n/).filter((l) => PANIC_RE.test(l));
  return (lines[0] || hit.slice(0, 200)).trim().slice(0, 240);
}

// ---------- 种子准备 ----------

function genSavable(argv, out) {
  const r = runCli([...argv, out]);
  if (r.error) throw new Error(`启动 CLI 失败: ${r.error.message}`);
  if (r.status !== 0) throw new Error(`生成种子失败: ${argv.join(" ")}（退出码 ${r.status}）`);
  return readFileSync(out);
}

const seeds = [];
function addSeed(name, bytes, commands) {
  seeds.push({ name, bytes, commands });
}
addSeed("ogg-opus", readFileSync(join(ROOT, "testdata/opus_sample.opus")), ["info", "verify", "seek0", "dump", "remux"]);
addSeed("ogg-vorbis", readFileSync(join(ROOT, "testdata/vorbis_sample.ogg")), ["info", "verify", "seek0", "dump"]);
const m4a = genSavable(["remux", join(ROOT, "testdata/opus_sample.opus")], join(TMP, "seed.m4a"));
addSeed("mp4-opus", m4a, ["info", "to-ogg"]);
const wav = genSavable(["to-wav", join(ROOT, "testdata/opus_sample.opus")], join(TMP, "seed.wav"));
addSeed("wav", wav, ["info"]);

// ---------- 变异 ----------

function mutate(src, rng) {
  const randInt = (n) => Math.floor(rng() * n);
  const randRange = (a, b) => a + randInt(Math.max(1, b - a));
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

// ---------- 成功样本的产物校验 ----------

let validations = 0;

function readbackJson(file) {
  const r = runCli(["info", file, "--json"]);
  const crash = crashLabel(r.status, r.signal);
  if (crash !== null) return { reason: `产物回读命令崩溃：${crash}` };
  if (r.error) return { reason: `产物回读启动失败：${r.error.message}` };
  if (r.status !== 0) return { reason: `产物回读 info 退出码 ${r.status}` };
  const panic = panicOutput(r.stdout, r.stderr);
  if (panic !== null) return { reason: `产物回读疑似 panic：${panic}` };
  const text = r.stdout.trim();
  if (text === "") return { reason: "产物回读 info --json 输出为空" };
  let parsed;
  try {
    parsed = JSON.parse(text.split(/\r?\n/).filter((l) => l.trim() !== "").pop());
  } catch {
    return { reason: "产物回读 info --json 不是合法 JSON" };
  }
  if (parsed === null || typeof parsed !== "object") {
    return { reason: "产物回读 info --json 不是 JSON 对象" };
  }
  return { reason: null, info: parsed };
}

function verifyFile(file) {
  const r = runCli(["verify", file]);
  const crash = crashLabel(r.status, r.signal);
  if (crash !== null) return `verify 崩溃：${crash}`;
  if (r.error) return `verify 启动失败：${r.error.message}`;
  if (r.status !== 0) return `verify 退出码 ${r.status}（成功产物应当是合法容器）`;
  const panic = panicOutput(r.stdout, r.stderr);
  if (panic !== null) return `verify 疑似 panic：${panic}`;
  return null;
}

// 返回失败原因（string）或 null。只在命令成功时调用。
function validateSuccess(cmd, input, out, iter) {
  if (validations >= MAX_VALIDATIONS) return null;
  validations++;
  if (cmd === "remux" || cmd === "to-ogg") {
    if (!existsSync(out)) return `退出码 0 但产物不存在: ${out}`;
    if (statSync(out).size === 0) return "退出码 0 但产物为空文件";
    const back = readbackJson(out);
    if (back.reason !== null) return back.reason;
    const wantFormat = cmd === "remux" ? "mp4" : "ogg";
    if (back.info.format !== wantFormat) {
      return `产物格式是 ${String(back.info.format)}，期望 ${wantFormat}`;
    }
    if (cmd === "to-ogg") {
      const bad = verifyFile(out);
      if (bad !== null) return bad;
    } else {
      // 往返：Ogg Opus → MP4 → Ogg → verify
      const roundtrip = join(TMP, `rt${iter}.ogg`);
      const r = runCli(["to-ogg", out, roundtrip]);
      const crash = crashLabel(r.status, r.signal);
      if (crash !== null) return `remux 产物往返 to-ogg 崩溃：${crash}`;
      const panic = panicOutput(r.stdout, r.stderr);
      if (panic !== null) return `remux 产物往返 to-ogg 疑似 panic：${panic}`;
      if (r.status !== 0) return `remux 产物无法 to-ogg（退出码 ${r.status}）`;
      const bad = verifyFile(roundtrip);
      if (bad !== null) return `remux→to-ogg 往返产物 ${bad}`;
    }
    return null;
  }
  // 只读命令：成功意味着输入被理解，回读 --json 必须可解析。
  const back = readbackJson(input);
  if (back.reason !== null) return back.reason;
  return null;
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
  const rng = rngFor(iter);
  const randInt = (n) => Math.floor(rng() * n);
  const seed = seeds[randInt(seeds.length)];
  const mutated = mutate(seed.bytes, rng);
  const file = join(TMP, `m${iter}.bin`);
  writeFileSync(file, mutated);
  // 每个变异样本随机跑一条命令（保证样本覆盖）
  const cmd = seed.commands[randInt(seed.commands.length)];
  const out = join(TMP, `o${iter}.bin`);
  const r = runCli(commandArgs(cmd, file, out));
  runs++;
  const crash = crashLabel(r.status, r.signal);
  if (r.error && r.error.code !== "ETIMEDOUT") {
    // 二进制不存在/不可执行等启动失败，不能伪装成「超时」
    failures.push({ iter, seed: seed.name, cmd, reason: "启动失败: " + r.error.message });
    continue;
  }
  // panic 检测必须同时扫 stderr 和 stdout（部分运行时把 panic 打到 stdout）。
  const panic = panicOutput(r.stdout, r.stderr);
  if (panic !== null) {
    failures.push({
      iter,
      seed: seed.name,
      cmd,
      reason: "疑似 panic: " + panic,
      stderr: r.stderr.slice(0, 400),
      stdout: r.stdout.slice(0, 400),
    });
    continue;
  }
  if (r.error?.code === "ETIMEDOUT" || (r.status === null && r.signal)) {
    failures.push({ iter, seed: seed.name, cmd, reason: "超时/被信号杀死", signal: r.signal });
    continue;
  }
  if (crash !== null) {
    failures.push({
      iter,
      seed: seed.name,
      cmd,
      reason: crash,
      stderr: (r.stderr || "").slice(0, 400),
      stdout: (r.stdout || "").slice(0, 400),
    });
    continue;
  }
  if (r.status === 0) {
    ok++;
    // 成功退出必须证明产物/输入确实可读、可解析、可往返验证。
    const bad = validateSuccess(cmd, file, out, iter);
    if (bad !== null) {
      failures.push({ iter, seed: seed.name, cmd, reason: "成功路径断言失败: " + bad, stderr: r.stderr.slice(0, 400) });
    }
  } else if (r.status === 1 || r.status === 2) {
    dataErrors++;
  } else {
    failures.push({
      iter,
      seed: seed.name,
      cmd,
      reason: `非法退出码 ${r.status}`,
      stderr: (r.stderr || "").slice(0, 400),
    });
  }
}

console.log(`# moonmux mutation fuzz`);
console.log("");
console.log(`- CLI：${BIN}`);
console.log(`- 种子：${seeds.map((s) => s.name).join(", ")}`);
console.log(`- 迭代：${ITERATIONS}，随机种子：${SEEDS.join(",")}${SEEDS.length > 1 ? "（按迭代轮换）" : "（固定）"}`);
console.log(`- 成功样本额外校验：${validations} 次（上限 ${MAX_VALIDATIONS}）`);
console.log(`- 结果：运行 ${runs} 次 · 成功 ${ok} · 数据/用法错误 ${dataErrors} · 异常 ${failures.length}`);
if (failures.length > 0) {
  console.log("");
  console.log("异常样本（可复现：同一 --seed/--seeds 与 --iterations 重跑即可重放）：");
  for (const f of failures.slice(0, 10)) {
    console.log(`- iter=${f.iter} seed=${f.seed} cmd=${f.cmd} ${f.reason}${f.stderr ? ` stderr=${f.stderr.replace(/\s+/g, " ")}` : ""}`);
  }
  process.exit(1);
}
console.log("");
console.log("全部变异均落在 0/1/2 退出码内，无崩溃、无超时；成功样本的产物回读/往返校验通过。");
