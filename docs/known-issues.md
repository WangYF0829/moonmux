# 已知问题与残余风险（Known Issues）

> 本文件汇总 moonmux v0.9.3 当前仍存在的已知问题与**已登记的风险接受**，供使用者、发布负责人与后续维护者查阅。
> 每一项都给出：影响、现有缓解、跟踪状态、负责人建议。相关背景见 [`README.md`](../README.md)（能力边界）、
> [`docs/architecture.md`](architecture.md)（不变量与已知边界）、[`CHANGELOG.md`](../CHANGELOG.md)、
> [`RELEASING.md`](../RELEASING.md)（发布检查单）与 [`docs/releases/v0.9.3.md`](releases/v0.9.3.md)（发布记录）。
> 安全类（历史 PII）另见 [`docs/security/pii-advisory.md`](security/pii-advisory.md)。

## 索引

| ID | 问题 | 严重度 | 状态 | 负责人建议 |
|---|---|---|---|---|
| KI-01 | 依赖 `moonvorbis@0.1.4` 的 `unsafe_get` / 缺 bit-budget（上游无修复版本） | 中高 | 开放（已缓解，待上游修复） | 上游维护者（LL728）；moonmux 维护者负责提 issue/跟踪 |
| KI-02 | Opus 音频 payload 只校验 TOC，不校验码流内容（依赖解码器边界） | 中 | 已登记（信任边界约束） | moonmux 维护者 + 上游 `moonopus` |
| KI-03 | 历史发布包 PII（0.2.0–0.9.1 含作者联系方式，不可撤回） | 中低 | 已接受风险（发布前扫描门禁） | 项目维护者；发布负责人执行 `check_pii.sh` |
| KI-04 | bench 本机噪声 / 跨平台不可比（共享 runner） | 低 | 已缓解（噪声下限/基线/平台守卫） | QA/性能维护者 |
| KI-05 | 真实 Vorbis 解码慢（debug 约 92–97 s）与 CPU 预算密度残余 | 低 | 已登记（依赖性能限制） | 核心/性能维护者；上游解码器 |

> 严重度口径：中高 = 可被恶意输入触发资源/崩溃类问题且上游未修；中 = 有明确信任边界约束；低 = 使用体验/度量噪声。
> 本文件之外，`moonvorbis`/`moonopus` 的许可与再分发信息见 [`THIRD_PARTY.md`](../THIRD_PARTY.md)，
> 依赖维护性评估（G1-B2）见 [`docs/dependency-assessment.md`](dependency-assessment.md)。

---

## KI-01：`moonvorbis@0.1.4` 的 `unsafe_get` / 缺 bit-budget（依赖层，未修复）

**现状**
- `LL728/moonvorbis@0.1.4` 是当前 mooncakes 最新版（2026-10-17 发布，之后无新版本），解码器内部大量使用 `unsafe_get`
  （包内源码 `unsafe_*` 出现约 51 处，集中在 `ogg_page.mbt`/`vorbis_comment.mbt`/`vorbis_info.mbt`/`vorbis_setup.mbt` 等），
  且 setup/码流解析缺少统一的 bit-budget 上限——对不可信 Vorbis 码流不保证内存安全/有界 CPU。
- 该问题在 moonmux 侧已登记为"残余风险"：见 [`CHANGELOG.md`](../CHANGELOG.md) 的「已知残余」与
  [`docs/architecture.md`](architecture.md) 第 6 节、[`README.md`](../README.md)「能力边界 / `to-wav` 不可信输入」。
- 与首轮验收的对应：G1-M06 依赖缺陷（登记降级）、F-PAR-01（旧 gate 只校验第 1 个 codebook）；上游无修复版本。

**影响**
- 若把 `to-wav` 直接暴露给不可信输入，恶意/畸形 Vorbis 码流可能导致解码器越界读、panic/崩溃或 CPU/内存放大（DoS 类），
  而非机密性破坏；影响面限于解码路径（`pipeline/` → `to-wav`），容器读写层不依赖该解码器。
- 生产使用建议：对不可信来源的 Ogg/Vorbis 先做容器级校验/隔离（独立进程、资源限额），不要直接调用 `to-wav`。

**现有缓解（moonmux 侧，gate v3）**
- 解码前统一调用 `@codec.parse_vorbis_setup_info`（gate v3）：逐 codebook（sparse 按真实读取量做位预算）、
  floor/residue/mapping/mode 段与跨段交叉引用、lookup1/2 表（含除零/溢出）、ordered 与 framing 位；
  产出内存分配上界 `decoder_setup_bytes` 与 **CPU 双预算**（IMDCT 34,000 cos/字节、下限 6M；Huffman 650,000 比较/字节、下限 32M）。
- 红队回归：RT4-01 PoC（6,511 B、VQ 码字数上界漏乘）现 `exit 1 / 0.87 s`；RT3 相关 19 组 PoC 全部 `exit 1`、0 崩溃、0 残留；
  真实样本 `to-wav` 产物字节数不变（Vorbis 176,444 / Opus 576,044）。
- 预算与信任边界详见 [`README.md`](../README.md)「能力边界」表；发布检查单见 [`RELEASING.md`](../RELEASING.md)。

**跟踪状态**
- 上游 issue：**尚未提交**（下方为可直接粘贴的草稿；提交人需为维护者/有 GitHub 账号，目标仓库
  <https://github.com/LL728/moonvorbis/issues>）。
- 修复上游后：升级 `moonvorbis` 版本 → 回归 gate v3/`to-wav`/bench → 更新 [`THIRD_PARTY.md`](../THIRD_PARTY.md)、
  [`docs/dependency-assessment.md`](dependency-assessment.md) 与发布记录。
- 负责人建议：moonmux 维护者（提交/跟踪 issue）+ 上游维护者 `LL728`（修复）；发布负责人每季度复核状态。

**上游 issue 草稿（可直接粘贴，提交前请复核措辞与复现细节）**

```markdown
标题：Hardening request: unchecked `unsafe_get` and missing bit-budget in Vorbis setup/decoder paths

环境
- moonvorbis 0.1.4（mooncakes 最新）；MoonBit moon 0.1.20261012 / moonc 0.10.15。
- 下游：moonmux v0.9.3（delegate 到 pipeline/），用于复现与对照。

问题
1. 解码器内部多处使用 `unsafe_get`（约 51 处，集中于 ogg_page/vorbis_comment/vorbis_info/vorbis_setup 等），
   对截断/畸形码流没有统一的边界/位预算保护。
2. setup 解析（codebook/floor/residue/mapping 等）缺少随输入规模线性受限的 bit-budget；
   恶意构造的 sparse codebook / 超大 VQ 码字数可导致非法读取或长时间 CPU（下游需自行在调用前加 gate 才能挡住）。

影响
- 对不可信 Ogg/Vorbis 输入：可能 panic/越界读/CPU 或内存放大（DoS 类）；
- 下游 moonmux 已用外部 gate v3（完整 setup 校验 + 内存/CPU 双预算）缓解，但库内残余仍在，
  未加 gate 的调用方（直接使用解码器）不受保护。

复现（高层描述；完整 PoC 可私下提供）
- 构造 Vorbis setup 头：把某个 residue VQ 的 dimensions/partition 计数放大（或构造 sparse codebook 使扫描量远超输入长度），
  在未加 gate 的 moonvorbis 解码路径上观察到超长 CPU/异常读取；
- 对照：同一输入经 moonmux gate v3 前置校验后返回数据错误（exit 1），不解码。

期望修复
- 在 setup/码流解析中加入显式 bit-budget（按输入长度/声明字段上限裁剪），并对所有数组访问做边界检查
  （或将 `unsafe_get` 替换为带检查访问）；
- 为 labels/residue/floor/mapping 增加交叉引用与上限校验（可参考 RFC 3533 / Vorbis I 规范）；
- 增加对应回归测试（畸形 setup 样本应返回错误而非崩溃/超长 CPU）。

参考
- moonmux 侧登记：docs/known-issues.md KI-01；gate v3 实现：moonmux `codec/` + `pipeline/`。
- 许可：Apache-2.0。
```

---

## KI-02：Opus 音频 payload 只校验 TOC，不校验码流内容

**现状**：`to-wav` 的 Opus 路径在 gate 阶段只校验 `OpusHead`/`OpusTags` 与逐包 TOC（帧时长/配置），
不校验 Opus 音频 payload 的码流内容；Opus 解码由依赖 `LL728/moonopus@0.2.2` 完成。登记来源：
[`CHANGELOG.md`](../CHANGELOG.md)「已知残余」（"Opus 音频 payload 也只校验 TOC，不校验码流内容"）。

**影响**：畸形 Opus payload 的健壮性依赖解码器实现；moonmux 无法保证对不可信 Opus 码流的有界性，
可能在解码器内部出现异常/崩溃（影响范围与 KI-01 同类，属信任边界约束）。

**现有缓解**：容器级写前校验、Opus 逐包 TOC 时长与包数预算、`to-wav` 内存/CPU 预算、
"不建议直接处理不可信输入"的文档约束（[`README.md`](../README.md)、[`docs/architecture.md`](architecture.md)）。

**跟踪状态**：已知并登记；后续可评估对 Opus payload 做更细粒度校验或依赖上游 `moonopus` 加固。
负责人建议：moonmux 维护者（文档/信任边界）+ 上游 `moonopus` 维护者（解码器健壮性）。

---

## KI-03：历史发布包 PII（0.2.0–0.9.1，不可撤回）

**现状**：`项目申报书.md` 在 v0.9.2 之前包含作者手机号与 QQ 邮箱；该文件随 mooncakes 发布包 0.2.0–0.9.1 永久发布，
git 历史亦保留（73/85 个 commit 的文件内容含该 PII；v0.9.2 的 `af8033e` 起移除；v0.9.3 当前树与发布包已干净）。
mooncakes 不支持删除/撤回单个版本，`moon deprecate` 为全模块弃用（代价过大），因此**作为已接受风险登记**。

**影响**：作者个人联系方式在旧版本包与 git 历史中公开可检索；不涉及凭据/第三方数据；不代表当前版本存在问题。

**现有缓解**：v0.9.2 起已清除；发布检查单强制 `bash scripts/check_pii.sh`（当前树 0 命中才允许发布）；
历史模式仅作审计留档（预期非 0）；发布记录 `docs/releases/v0.9.3.md` 已登记风险接受。

**跟踪状态**：风险接受（不重写历史、不 deprecate 全模块）。完整事实、影响面、不可撤回约束与门禁见
[`docs/security/pii-advisory.md`](security/pii-advisory.md)。负责人建议：项目维护者（风险接受决策）+ 发布负责人（执行门禁）。

---

## KI-04：bench 本机噪声 / 跨平台不可比

**现状**
- `scripts/bench.mjs` 端到端计时（含 1–2 ms 进程启动），本机小操作（约 15–22 ms）易受启动抖动影响；
  一次本机测量曾出现 `info +26.7%` 的噪声误报（重测 `--runs 8 --batches 2` 6/6 PASS）。
- 已接入：本地基线 [`scripts/bench-baseline.json`](../scripts/bench-baseline.json)（3 轮 × 5 runs × 2 batches，每项 30 样本取 min 的上界）、
  小操作噪声下限 **4 ms**、`demux` I/O 密集取 6 次测量上界 **80.0 ms**、跨平台仅 `WARN`（平台守卫）。
- CI `bench · native` 用共享 runner，仅作粗粒度告警（`--fail-over 0.50`）；**Linux/release 平台基线未实测**（[`docs/architecture.md`](architecture.md) §6）。

**影响**：阈值门禁可能因环境噪声误报（假阳性），或因阈值放宽而漏掉小幅真实回退（假阴性）；跨平台绝对值不可比。

**现有缓解**：噪声下限 + 多批次/多样本基线 + 平台守卫 + 发布前本机复测；详见 [`RELEASING.md`](../RELEASING.md) §9 已知偏差表。

**跟踪状态**：已缓解/登记；建议在专用 runner 或 Linux 上补一次基线，再收紧 CI 阈值。
负责人建议：QA/性能维护者。

---

## KI-05：真实 Vorbis 解码慢（debug 约 92–97 s）与 CPU 预算密度残余

**现状**
- `testdata/vorbis_sample.ogg` 在 **debug native** 下 `to-wav` 约 **92.6 s**（红队/复验记录 92.3–97.2 s）；
  约 1.0 s 的 Vorbis 音频需 60–70 s（纯 MoonBit 解码器：O(n²) IMDCT + Huffman 逐 bit 线性扫表），Opus 约 30× 实时。
- CPU 双预算（debug）上限约 **18 ms/字节**（真实样本已接近硬约束：IMDCT 余量 ×1.43、Huffman ×1.49），
  且预算密度与真实样本同量级：debug 下 1.4–1.5 KB 的构造输入可在预算内消耗 10.2–10.4 s（属"依赖解码器真实慢"，非公式低估）。
- 解码器 setup 构造 CPU 未单独预算（实测 9–13.5 s，主要仍是 IMDCT）；release/Linux 未实测。

**影响**：长 Vorbis 文件解码耗时长（分钟级），接近预算上限的合法流可能被误拒；调试构建不适合处理长音频。

**现有缓解**：内存/CPU 双预算 + 上限抖动余量；文档明确"长文件先 `split`"、release 构建建议；
真实样本产物字节数不变（未被误拒）；bench 仅测容器层命令（不把 to-wav 纳入阈值）。

**跟踪状态**：已登记（依赖性能限制，非本项目可加速）；如上游解码器优化或 release 实测差异明显，再评估调整预算系数。
负责人建议：核心/性能维护者跟踪；上游 `moonvorbis` 性能改进。

---

## 维护与更新方式

- 新增已知问题：在本文件「索引」表加一行 + 新增小节（影响/缓解/跟踪/负责人），并同步到 [`RELEASING.md`](../RELEASING.md) §9 已知偏差登记。
- 修复/关闭：把状态改为「已关闭」并注明版本/commit；涉及依赖的同步更新 [`THIRD_PARTY.md`](../THIRD_PARTY.md)、
  [`docs/dependency-assessment.md`](dependency-assessment.md)。
- 安全披露：当前项目无独立 SECURITY.md，安全问题可通过仓库 Issue 联系维护者；历史 PII 见
  [`docs/security/pii-advisory.md`](security/pii-advisory.md)。
