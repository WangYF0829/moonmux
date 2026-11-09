# moonmux 架构与设计说明

> 本文回答「项目怎么组织、关键不变量是什么、为什么这样取舍」，供评审与后续维护者阅读。
> 版本：v0.7.0（2026-11-09）。

## 1. 目标与非目标

**目标**：给 MoonBit 生态提供一个**可独立复用、零依赖的音频容器层** —— Ogg / WAV / MP4（Opus-in-MP4）的读写，以及容器级工具（诊断、解复用、重封装、定位）。容器格式的正确性应当能被外部工具独立验证。

**非目标**：
- 不做音频编解码（Opus / Vorbis 解码器由 `LL728/moonopus`、`LL728/moonvorbis` 提供，仅 `pipeline/` 对接）；
- 不做 PCM → Ogg 的编码器（需要编码器本体）；
- 库提供**增量解析 API**（`ogg.PageReader`，分块喂入），但 CLI 仍以整文件 I/O 为主（`moonbitlang/x/fs` 只有整文件 API；2 GiB 为硬边界）；
- MP4 做 **Opus-in-MP4 写侧 + 解封装回 Ogg**（v0.7.0）；不做 Vorbis-in-MP4，也不支持多音轨 MP4。

## 2. 模块结构

| 包 | 职责 | 依赖 |
|---|---|---|
| `ogg/` | RFC 3533：页 / 段 / 包、Ogg CRC-32、多逻辑流交织、物理流链接与拆分、结构体检、页级补丁、定位；**增量页读取 `PageReader`（v0.7.0）** | 无 |
| `wav/` | RIFF/WAVE：`fmt `/`data` 解析、整数 PCM 编码；**v0.4.0 全格式**：fmt 1/3/0xFFFE、Extensible GUID、IEEE float 32/64、24-in-4 容器、`encode_wav_ex`；**v0.7.0 块保真**（扩展块 / channelMask / `WavFile::to_bytes`）与 `WavWriter` | 无 |
| `codec/` | 编解码头（OpusHead / Vorbis ID）、VorbisComment/OpusTags、时长换算、**Opus TOC 帧时长** | 无 |
| `manifest/` | `demux`/`mux` 的流目录清单（流号、包数、链序号、逐包粒度） | 无 |
| `pipeline/` | Ogg（Opus / Vorbis）→ WAV 转码管线 | ogg + 两个纯 MoonBit 解码器 |
| `mp4/` | ISOBMFF box 层、`moov`/`stbl` 构造（Opus-in-MP4）、`inspect` 摘要、`remux_ogg_opus`；**v0.7.0 解封装 `demux_mp4_opus`**（stsd/dOps/stts/stsc/stsz/stco → Ogg Opus） | ogg + codec |
| `cli/` | 参数解析（纯逻辑，不碰 I/O 与 stdout） | 无 |
| `cmd/main/` | I/O、错误→退出码、输出排版 | cli + 全部容器包 + `moonbitlang/x` |

分层原则：**容器层（`ogg`/`wav`/`codec`/`manifest`/`mp4`）零三方依赖**，三方解码器只出现在 `pipeline/`；`cli/` 纯函数可离线断言，`cmd/main/` 只做 I/O。

## 3. 关键不变量

1. **Ogg CRC**：`crc32` 覆盖整页（含 `OggS` 捕获模式），CRC 字段置零参与计算；参数为多项式 `0x04c11db7`、初值 0、不反射、末异或。查表实现与逐位定义逐字节一致（`ogg/crc_wbtest.mbt` 交叉校验）。
2. **页/包结构**：段表每项 0..255、总和等于负载长度；单页 ≤255 段、负载 ≤65025；跨页包只在结束页写 granule，其余页写 -1；首页 BOS、每段末页 EOS。
3. **写命令先校验后落盘**：`demux`/`mux`/`cat`/`split`/`extract`/`tag`/`to-wav`/`chop`/`remux` 在输入结构错误、截断或清单不符时拒绝写半成品；已有输出先备份，写后回读自检失败则恢复。
4. **退出码**：`0` 成功；`1` 数据/校验错误；`2` 用法或 I/O 错误。
5. **MP4 盒子自洽**：`stts` 样本时长和 = `mdhd` duration；`stsz` 逐样本大小和 = `mdat` 负载长度；`stsc` 单 chunk 装全部样本，`stco` 指向 `mdat` 负载起点；`dOps` 是 **Box**（首字节为 Version），不是 FullBox —— 写成 FullBox 会让 ffmpeg 读到 zero channel count。
6. **WAV 格式判定**：fmt 标签 1=PCM、3=IEEE float、0xFFFE=Extensible；Extensible 取 SubFormat GUID（16 字节全量比较）判定真实编码，`validBits` 与容器位深分开：`bytes_per_sample = block_align / channels`，帧大小按容器算，不能用有效位深除 8（24-in-4 就是反例）。\n7. **流式解析等价性**：`PageReader` 任意分块喂入的页序列必须与一次性 `parse_pages` 相同；CRC 失败视为失步，跳 1 字节后继续同步；`finish` 把残余字节记为 `Skipped`，保留末尾 3 字节避免切掉半个 `OggS`。\n8. **WAV 块保真**：`fmt `/`data` 之外的块（含 `fact`/`LIST`/`junk`）与 `channel_mask` 原样保留在 `WavFile.chunks`/`channel_mask`；`WavFile::to_bytes` 按原顺序与容器宽度写回，parse → to_bytes 逐字节一致（覆盖 24-in-4 与奇数填充）。\n9. **发布一致性**：发布包来自 git 跟踪文件，`.moonignore` 排除 `_build`、`*.mbti`、日志等生成物。

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
- `dOps` 字段来自 `OpusHead`（pre-skip、输入采样率、声道数、声道映射）。
- 自检：`remux` 产出后立即用 `mp4::inspect` 读回，失败即报错；外部再用 ffprobe / ffmpeg 对账（`scripts/verify_mp4.sh`）。

## 4.1 MP4 解封装（v0.7.0）

```
moov → trak → mdia → minf → stbl
   stsd → Opus 样本条目 → dOps（版本/声道/pre-skip/输入采样率/增益/映射族）
   stts（逐样本时长）   stsc（chunk→样本数）   stsz（样本大小）   stco / co64（chunk 偏移）
mdat → 按 chunk 切出样本（= Opus 包）
```

- 输出 OpusHead 由 dOps 重建；OpusTags 为最小合成标签（MP4 写侧没有保存注释）；
- granule = pre-skip + 累计样本时长（stts 的 mdhd timescale 必须为 48000）；
- 坏表防御：所有 `st*` 表读取做长度/计数/递增/越界检查，错误返回中文原因而不是崩溃。

## 5. 测试策略

| 层 | 手段 |
|---|---|
| 单元/白盒 | 299 个 `moon test`（页/包/CRC/清单/转码/box/Mp4 往返与解封装/CLI 解析/WAV 全格式/流式页读取），含真实 Ogg 文件的逐页 CRC 断言 |
| 合成流闭环 | 合成 OpusHead+OpusTags+音频包 → Ogg → remux → inspect 读回（`mp4/mp4_wbtest.mbt`） |
| 外部对账 | `scripts/verify_mp4.sh`：真实样本 remux 后 ffprobe 断言编码/声道/采样率/时长，ffmpeg 解码无错 |
| 端到端 | `scripts/smoke.sh`：CLI 往返逐字节、退出码、边界输入、MP4/remux 项 |
| 可安装性 | `scripts/install_check.sh`：干净工程 `moon add` → 调用公开 API → 运行 |
| 性能基准 | `scripts/bench.mjs`（release native，端到端计时，含进程启动；CI `bench` job 记录到 job summary，不设阈值） |
| 变异测试 | `scripts/fuzz.mjs`（真实样本 × 6 类变异，断言退出码 0/1/2、无超时/崩溃；CI `fuzz` job 固定种子 400 次）+ 各包 `*_fuzz_wbtest.mbt` 确定性用例 |
| 门禁 | CI：`check --deny-warn`、`fmt --check`、`info`、双平台测试、覆盖率非回归、native smoke、mp4 verify、install、bench、fuzz |

## 6. 已知边界与下一期候选

- 2 GiB 文件上限（`Int` 32 位 + `@fs` 整文件 API）；v0.7.0 提供流式**解析**，尚无流式**写**接口。
- MP4 仅 Opus 单音轨；Vorbis-in-MP4 明确不做。
- 基准与变异测试走 Node 脚本（可复现、无第三方依赖），尚未接入性能回归阈值与 libFuzzer/AFL 覆盖率引导。
- 下一期候选：无。容器层读写、MP4 写/解封装、WAV 全格式/块保真/流式写、基准与变异测试均已落地；明确不做 Vorbis-in-MP4 与多音轨 MP4。
