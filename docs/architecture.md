# moonmux 架构与设计说明

> 本文回答「项目怎么组织、关键不变量是什么、为什么这样取舍」，供后续维护者阅读。
> 版本：v0.9.4（2026-11-13 发布基线；验收整改版）；版本变更见 [`CHANGELOG.md`](../CHANGELOG.md) 与 [`docs/releases/`](releases/)，发布流程与回滚预案见 [`RELEASING.md`](../RELEASING.md)。

## 1. 目标与非目标

**目标**：给 MoonBit 生态提供一个**可独立复用、零依赖的音频容器层** —— Ogg / WAV / MP4（Opus-in-MP4）的读写，以及容器级工具（诊断、解复用、重封装、定位）。容器格式的正确性应当能被外部工具独立验证。

**非目标**：
- 不做音频编解码（Opus / Vorbis 解码器由 `LL728/moonopus`、`LL728/moonvorbis` 提供，仅 `pipeline/` 对接）；
- 不做 PCM → Ogg 的编码器（需要编码器本体）；
- 库提供**增量解析 API**（`ogg.PageReader`，分块喂入），但 CLI 仍以整文件 I/O 为主（`moonbitlang/x/fs` 只有整文件 API；2 GiB 为硬边界）；
- MP4 做 **Opus-in-MP4 写侧 + 解封装回 Ogg**（v0.5.0）；不做 Vorbis-in-MP4，也不支持多音轨 MP4。

## 2. 模块结构

| 包 | 职责 | 依赖 |
|---|---|---|
| `ogg/` | RFC 3533：页 / 段 / 包、Ogg CRC-32、多逻辑流交织、物理流链接与拆分、结构体检、页级补丁、定位；**增量页读取 `PageReader`（v0.4.0）** | 无 |
| `wav/` | RIFF/WAVE：`fmt `/`data` 解析、整数 PCM 编码；**v0.4.0 全格式**：fmt 1/3/0xFFFE、Extensible GUID、IEEE float 32/64、24-in-4 容器、`encode_wav_ex`；**v0.7.0 块保真**（扩展块 / channelMask / `WavFile::to_bytes`）与 `WavWriter` | 无 |
| `codec/` | 编解码头（OpusHead / Vorbis ID）、VorbisComment/OpusTags、时长换算、**Opus TOC 帧时长**；**Vorbis setup 完整有界校验（gate v3）**、codebook 分配 / Huffman·IMDCT **CPU 双预算**成本模型与块大小推导（`parse_vorbis_setup_info` / `VorbisSetupInfo` / `vorbis_block_sizes`） | 无 |
| `manifest/` | `demux`/`mux` 的流目录清单（流号、包数、链序号、逐包粒度） | 无 |
| `pipeline/` | Ogg（Opus / Vorbis）→ WAV 转码管线 | ogg + 两个纯 MoonBit 解码器 |
| `mp4/` | ISOBMFF box 层、`moov`/`stbl` 构造（Opus-in-MP4）、`inspect` 摘要、`remux_ogg_opus`；**v0.5.0 解封装 `demux_mp4_opus`**（stsd/dOps/stts/stsc/stsz/stco → Ogg Opus） | ogg + codec |
| `cli/` | 参数解析（纯逻辑，不碰 I/O 与 stdout） | 无 |
| `cmd/main/` | I/O、错误→退出码、输出排版 | cli + 全部容器包 + `moonbitlang/x` |

分层原则：**容器层（`ogg`/`wav`/`codec`/`manifest`/`mp4`）零三方依赖**，三方解码器只出现在 `pipeline/`；`cli/` 纯函数可离线断言，`cmd/main/` 只做 I/O。

## 3. 关键不变量

1. **Ogg CRC**：`crc32` 覆盖整页（含 `OggS` 捕获模式），CRC 字段置零参与计算；参数为多项式 `0x04c11db7`、初值 0、不反射、末异或。查表实现与逐位定义逐字节一致（`ogg/crc_wbtest.mbt` 交叉校验）。
2. **页/包结构**：段表每项 0..255、总和等于负载长度；单页 ≤255 段、负载 ≤65025；跨页包只在结束页写 granule，其余页写 -1；首页 BOS、每段末页 EOS。
3. **写命令先校验后落盘**：`demux`/`mux`/`cat`/`split`/`extract`/`tag`/`to-wav`/`chop`/`remux` 在输入结构错误、截断或清单不符时拒绝写半成品；已有输出先备份，写后回读自检失败则恢复。
4. **退出码**：`0` 成功；`1` 数据 / 校验错误（截断、CRC 失败、清单与目录不符、`verify` 报 error 等）；`2` 用法 / 参数引用 / I/O / 能力边界 / 输入形态不支持（参数错、文件读不到、2 GiB 上限、`demux` 包数上限、Windows MAX_PATH、`remux` 拒绝链式 / 多流等）。
5. **MP4 盒子自洽**：`stts` 样本时长和 = `mdhd` duration；`stsz` 逐样本大小和 = `mdat` 负载长度；`stsc` 单 chunk 装全部样本，`stco` 指向 `mdat` 负载起点；`dOps` 是 **Box**（首字节为 Version），不是 FullBox —— 写成 FullBox 会让 ffmpeg 读到 zero channel count。
6. **WAV 格式判定**：fmt 标签 1=PCM、3=IEEE float、0xFFFE=Extensible；Extensible 取 SubFormat GUID（16 字节全量比较）判定真实编码，`validBits` 与容器位深分开：`bytes_per_sample = block_align / channels`，帧大小按容器算，不能用有效位深除 8（24-in-4 就是反例）。
7. **流式解析等价性**：`PageReader` 任意分块喂入的页序列必须与一次性 `parse_pages` 相同；CRC 失败视为失步，跳 1 字节后继续同步；`finish` 把残余字节记为 `Skipped`，保留末尾 3 字节避免切掉半个 `OggS`。
8. **WAV 块保真**：`fmt `/`data` 之外的块（含 `fact`/`LIST`/`junk`）与 `channel_mask` 原样保留在 `WavFile.chunks`/`channel_mask`；`WavFile::to_bytes` 保留原始 fmt 负载（16 / 18 / 40 字节等布局）与 fmt 之后扩展块的相对顺序，对标准布局 parse → to_bytes 逐字节一致（覆盖 24-in-4、奇数填充与 Extensible 小声道数）；fmt 之前出现未知块或非零填充字节的极端布局会按语义规范化（扩展块仍保留、采样数据无损）。
9. **头包页隔离**：粒度全为 0 的头包组（OpusHead/OpusTags、Vorbis 三个头包）各自独占一页、在页边界上开始与结束；`paginate_sized` 不得把它们与音频包合并。
10. **MP4 写侧闸门**：`remux` 只接受单段、单逻辑流的 Ogg；CLI 先过 CRC / 结构 / EOS 检查，库层再自校验页表，链式或多流输入显式拒绝而不是静默截取。
11. **MP4 读侧防崩溃**：读 box 字段前按 `next - body` 校验长度，截断文件返回 `None`/`Err` 而不是越界 panic；`stsz` 定长样本与样本偏移都用文件大小做上界，`pos + size` 用 Int64 计算防止回绕。
12. **发布一致性**：发布包由 `moon package`/`moon publish` 按工作区文件生成，`.moonignore` 排除 `_build`、`_*/`、`out/`、`tmp/`、`*.zip`、`*.bak`、`*.mbti`、日志等；CI 对 `moon package --list` 做白名单门禁（只允许源码/文档/测试数据路径），生成物与本地临时目录不得进包。发布前检查单、`moon publish --dry-run` 判定与回滚预案见 `RELEASING.md`；每次发布的 commit / tag / 工具链 / **zip sha256** / CI run / gate 结果归档在 `docs/releases/`（v0.9.3 见 `docs/releases/v0.9.3.md`）。
13. **Vorbis setup gate v3**：pipeline 解码前必须用 `@codec.parse_vorbis_setup_info(packet, channels)` 做完整有界校验 —— 逐 codebook（sparse 按解码器真实读取量做位预算）、floor / residue / mapping / mode 各段、**跨段交叉引用**（book / floor / residue / mapping / 声道下标）、lookup1/2 表（维度与元素数上限、除零 / 溢出）、ordered 游程与 framing 位；旧 `validate_vorbis_setup` 仅为兼容保留（只验 codebook 段，非完整安全路径）。**预算模型（v3）**：①内存 = `decoder_setup_bytes`（按 moonvorbis 真实分配上界：type0 `entries×8+…`、type1 `entries×(4×dims+8)+…`、type2 `entries×(8×dims+8)+…`，含 Huffman 表与码长数组）+ 逐包 mode/block_size/PCM 上界（不信任 granule）；②**CPU 双预算（单位不同，分别限额、不相加）**：**IMDCT 34,000 cos/字节**（下限 6M，真实样本 184.6M ≤ 263.2M，余量 ×1.43）与 **Huffman 650,000 比较/字节**（下限 32M，真实样本 3.384G ≤ 5.032G，余量 ×1.49）；Huffman 工作量 = `huffman_work_upper`（每包符号数上界，**含 `residue_vq_codewords` 的 VQ 码字数**）× `max_huffman_scan`；③RT3-04 裁决：dimensions 线格式为 **raw 值（无 +1）**，标量书（classbook / floor1 master/subclass）dims=0 合法、VQ 书（floor0/residue book）dims=0 仍 fail-closed 拒绝；④RT4-01：VQ 符号数上界漏乘 ×128 已修正（6,511 B PoC exit 1 / 0.87 s）。

## 4. MP4 写侧布局（v0.3.x）

```
ftyp (M4A / isom / iso2 / mp41)
mdat (全部 Opus 包按序拼接)
moov
 ├─ mvhd  (movie timescale=1000, duration)
 └─ trak
     ├─ tkhd (track_id=1, volume=1.0)
     └─ mdia
         ├─ mdhd (media timescale=48000, duration=总样本数)
         ├─ hdlr ("soun")
         └─ minf
             ├─ smhd
             ├─ dinf → dref → url (self-contained)
             └─ stbl
                 ├─ stsd → Opus sample entry + dOps
                 ├─ stts (run-length 压缩的样本时长)
                 ├─ stsc (单 chunk)
                 ├─ stsz (逐样本大小)
                 └─ stco (mdat 负载偏移)
```

- `ftyp + mdat + moov` 布局使 `stco` 偏移在写 `moov` 前确定（`ftyp` 长度 + 8），无需回填。
- 每个 Opus 包 = 一个 MP4 样本；样本时长由 TOC（RFC 6716）计算：SILK 10/20/40/60 ms、Hybrid 10/20 ms、CELT 2.5/5/10/20 ms。
- `dOps` 字段来自 `OpusHead`（pre-skip、输入采样率、声道数、声道映射、OutputGain）。
- 末包粒度不推进时按 Ogg end-trim 裁掉多余样本；`edts/elst` 负责把 pre-skip 从播放时间轴裁掉，`roll` 组声明随机访问的 pre-roll 样本数。
- 自检：`remux` 产出后立即用 `mp4::inspect` 读回，失败即报错；外部再用 ffprobe / ffmpeg 对账（`scripts/verify_mp4.sh`）。

## 4.1 MP4 解封装（v0.5.0）

```
moov → trak → mdia → minf → stbl
   stsd → Opus 样本条目 → dOps（版本/声道/pre-skip/输入采样率/增益/映射族）
   stts（逐样本时长）   stsc（chunk→样本数）   stsz（样本大小）   stco / co64（chunk 偏移）
mdat → 按 chunk 切出样本（= Opus 包）
```

- 输出 OpusHead 由 dOps 重建；OpusTags 为最小合成标签（MP4 写侧没有保存注释）；
- granule = 累计解码样本数（PCM position = granule − pre-skip；stts 的 mdhd timescale 必须为 48000）；
- 坏表防御：所有 `st*` 表读取做长度/计数/递增/越界检查，错误返回中文原因而不是崩溃。

## 5. 测试策略

| 层 | 手段 |
|---|---|
| 单元/白盒 | 本地 `moon test --deny-warn --target all` 实测：native **475**、wasm-gc **425**、js **425**（`wasm` 后端 0 个测试、不在 `supported_targets`）；v0.9.3 基线为 369（native）。覆盖页/包/CRC/清单/转码/box/Mp4 往返与解封装/CLI 解析/WAV 全格式/流式页读取/gate v3，含真实 Ogg 文件的逐页 CRC 断言 |
| 黑盒 | 各包 `*_public_test.mbt`（`for "test"` 导入，只使用公开 API），覆盖 ogg/wav/mp4/codec/manifest/pipeline 的主路径与错误路径 smoke 用例 |
| 覆盖率（D2 已达标） | **工具口径（`check_coverage.sh`）总 82.87%（5210/6287，门禁 ≥80%、达标）**；库层行覆盖率 **91.79%（3779/4117，门限 ≥88%）**；`coverage analyze` 未覆盖行 **635**（Linux 估算 ~662，CI 阈值 780 + 20 = 800，余量 ~138）；门禁脚本 `scripts/check_coverage.sh`（CI `coverage` job，`--total-threshold 80`） |
| 公开 API 文档覆盖 | `scripts/check_api_docs.sh --threshold 95 --max-gap 0`（CI `check` job）：从 `.mbti` 解析 pub 符号并核对源码 `///` 覆盖；当前 **132/132 = 100%**（阈值 ≥95%、未文档符号 0） |
| 合成流闭环 | 合成 OpusHead+OpusTags+音频包 → Ogg → remux → inspect 读回（`mp4/mp4_wbtest.mbt`） |
| 外部对账 | `scripts/verify_mp4.sh`：真实样本 remux 后 ffprobe 断言编码/声道/采样率/时长，ffmpeg 解码无错 |
| 端到端 | `scripts/smoke.sh`：CLI 往返逐字节、退出码、边界输入、MP4/remux 项 |
| 可安装性 | `scripts/install_check.sh`：干净工程 `moon add` → 调用公开 API → 运行 |
| 性能基准 | `scripts/bench.mjs`（release native，端到端计时，含进程启动；`--runs 5 --batches 2` 多批次采样）；本地基线 `scripts/bench-baseline.json` + `--baseline` / `--fail-over` 阈值（默认 10%；**小操作 <50 ms 用 4 ms 绝对噪声下限**；`demux` 为 I/O 密集取 6 次测量上界 80 ms；平台不匹配只 WARN 的平台守卫）；CI `bench` job 用共享 runner 放宽到 50% 作粗粒度回归告警 |
| 变异测试 | `scripts/fuzz.mjs`（真实样本 × 6 类变异，断言退出码 0/1/2、无超时/崩溃；CI `fuzz` job 固定种子 400 次）+ 各包 `*_fuzz_wbtest.mbt` 确定性用例 |
| 门禁 | CI **11 个 job**：`check`（check/fmt/info/test × 2 OS + `--target all` + **API 文档覆盖 100%** + 版本一致性 + 包清单 / worktree / 生成物 / 密钥）、`api-diff`（上一发布 tag 的 `.mbti` diff，**已对 `--target-all` 各后端接口**）、`coverage`（未覆盖行 ≤ 780+20 + **库层 ≥88% / 总 ≥80%** 门限）、`native`（smoke）、`examples`（三示例实跑）、`mp4`（ffprobe）、`install`（等待发布并复测）、`publish-dry-run`（不真实发布）、`bench`（基线阈值）、`fuzz`、`smoke-windows` |
| 发布前预检 | `scripts/preflight_release.sh`：一键串跑 worktree / 版本 / 格式 / check / test all / api-diff / api-docs / 覆盖率（总 ≥80%）/ PII / 包内容 / SBOM / bench / fuzz / smoke，输出 PASS/FAIL 汇总；支持 `--allow-dirty`、`--skip-bench` / `--skip-fuzz` / `--skip-smoke`、`--total-threshold` / `--lib-threshold` |
| 安装抽样 | [`docs/releases/v0.9.3-install-sampling.md`](releases/v0.9.3-install-sampling.md)：G1-01 冷装抽样 **30/30 = 100%**（≥99%），附加 3 次删除 `.mooncakes` 重解析后合计 **33/33**，中位 **1980 ms**；局限：工程级冷装、Windows x64 |

## 6. 已知边界与下一期候选

- **`to-wav` 信任边界**：解码前统一 gate v3（`@codec.parse_vorbis_setup_info`：OpusHead / OpusTags、Vorbis ID / comment、**Vorbis setup 完整有界校验** —— codebook（sparse 真实位预算）/ floor / residue / mapping / mode 段、跨段交叉引用、lookup1/2 表、ordered 与 framing，并产出内存分配上界、Huffman 比较成本上界（含 residue VQ 码字数）与 IMDCT 成本上界）；**RT4-01 PoC（6,511 B）现在 exit 1 / 0.87 s**，RT3 相关 19 组 PoC 回归仍全部 exit=1、0 崩溃、0 残留，真实 `to-wav` 产物字节数不变（Vorbis 176444 / Opus 576044，Vorbis debug 92.6 s）。仍**不建议直接处理不可信输入** —— 残余风险：① Huffman 码长表有效性（全 0 / 超长码语义）仍由解码器判定；② floor1 `x` 序等语义细节不在 gate 覆盖；③ 内存模型是上界估算而非精确峰值；④ **CPU 双预算 debug 上限约 18 ms/字节**（真实样本 92.6 s 已接近硬约束；余量 IMDCT ×1.43 / Huffman ×1.49），高码长+多符号的合法流仍可能被误拒；⑤ release/Linux 未实测；⑥ 依赖 `LL728/moonvorbis@0.1.4` 内部的 `unsafe_get` 仍是残余风险。详见 README「能力边界」与 `docs/releases/v0.9.3.md` §6。
- **target 支持**：`moon.mod` 声明 `supported_targets = ["native","wasm-gc","js"]`；本地 `--target all` 实测 native 475 / wasm-gc 425 / js 425，`wasm` 后端 0 个测试（未验证、不承诺）。CI 用 `moon test --target all` 覆盖声明后端（见 `.github/workflows/ci.yml`）。
- **CLI 输出上限**：`demux` 输出文件对象 ≤ **999999**（`MAX_DEMUX_PACKETS`，口径 = 包数 + 2 × 逻辑流数；写盘前按页数 × 255 粗估、超限 exit 2 且不建输出目录，未超限再按段表精算）；`split` 段数 ≤ **999999**（`MAX_SPLIT_PARTS`，超限 exit 2 且不建输出目录）。
- 2 GiB 文件上限（`Int` 32 位 + `@fs` 整文件 API）；聚合写命令在分配前做 Int64 估算。v0.4.0 起提供流式**解析**；`WavWriter` 是内存内增量接口。
- MP4 仅 Opus 单音轨；Vorbis-in-MP4 明确不做；不做章节/多轨编辑。
- `extract` 默认拒绝「输出与输入内容相同」的别名；`--force` 只允许幂等覆盖（已有输出与待写内容相同），不允许覆盖不同内容——`@fs` 无 stat/inode，无法安全区分硬链接别名与普通文件。
- 基准与变异测试走 Node 脚本（可复现、无第三方依赖）；bench 已接入**本地基线 + 阈值 + 平台守卫 + 小操作噪声下限（4 ms）**（`scripts/bench-baseline.json`，默认 10% / CI 共享 runner 50%，`demux` I/O 密集取 6 次测量上界 80 ms，跨平台仅 WARN），变异测试仍无 libFuzzer/AFL 覆盖率引导。
- **真实 Vorbis 解码慢是已知限制**：`testdata/vorbis_sample.ogg` 在 debug native 下 to-wav 约 **92.6 s**（依赖解码器 O(n²) IMDCT + Huffman 逐 bit 线性扫表；release/Linux 未实测）；CPU 双预算 debug 上限约 **18 ms/字节**，真实样本已接近硬约束；本项目只能做放大比预算、不能加速，长文件建议先 `split`；内存预算上界模型与真实峰值可能因 allocator / 环境浮动（已留 2 倍余量）。
- 备份/别名检查的内存：`@fs` 没有 stat/inode/rename API，覆盖已有输出时需把旧文件整体读入内存做内容比较，峰值约为旧文件大小 + 新输出；无法流式比较或原子替换。
- **依赖维护性与已知问题**：依赖维护性评估（G1-B2 = **DEGRADED**：3/3 依赖近 12 个月有发布且未弃用、3/3 无 SECURITY.md、2/3 bus factor=1）与退出预案、工具链 pin 结论见 [`docs/dependency-assessment.md`](dependency-assessment.md)；KI-01..05（含 `moonvorbis` 上游 issue 草稿）见 [`docs/known-issues.md`](known-issues.md)；历史发布包 PII 风险接受见 [`docs/security/pii-advisory.md`](security/pii-advisory.md)。
- **发布可复现性受工作区换行影响**：v0.9.3 实测「保留作者工作区字节」可逐字节复现发布 zip（sha256 `d374f9cf…5631`），但标准 `git checkout` 会按 `.gitattributes` 把 4 个文本文件转为 LF，重建为 370,958 B（sha256 `55c6fe7a…2019`），不可逐字节复现；发布前须按 `RELEASING.md` 规范化并记录。
- 下一期候选：无。容器层读写、MP4 写/解封装、WAV 全格式/块保真/流式写、基准与变异测试均已落地；明确不做 Vorbis-in-MP4 与多音轨 MP4。






