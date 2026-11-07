# moonmux 架构与设计说明

> 本文回答「项目怎么组织、关键不变量是什么、为什么这样取舍」，供评审与后续维护者阅读。
> 版本：v0.3.1（2026-11-07）。

## 1. 目标与非目标

**目标**：给 MoonBit 生态提供一个**可独立复用、零依赖的音频容器层** —— Ogg / WAV / MP4（Opus-in-MP4）的读写，以及容器级工具（诊断、解复用、重封装、定位）。容器格式的正确性应当能被外部工具独立验证。

**非目标**：
- 不做音频编解码（Opus / Vorbis 解码器由 `LL728/moonopus`、`LL728/moonvorbis` 提供，仅 `pipeline/` 对接）；
- 不做 PCM → Ogg 的编码器（需要编码器本体）；
- 不做流式文件 I/O 的承诺（`moonbitlang/x/fs` 只有整文件 API；2 GiB 为硬边界）；
- MP4 只做 **Opus-in-MP4 写侧**（读侧只做 `info` 所需的最小解析）。

## 2. 模块结构

| 包 | 职责 | 依赖 |
|---|---|---|
| `ogg/` | RFC 3533：页 / 段 / 包、Ogg CRC-32、多逻辑流交织、物理流链接与拆分、结构体检、页级补丁、定位 | 无 |
| `wav/` | RIFF/WAVE：`fmt `/`data` 解析、44 字节头编码、块边界与填充检查 | 无 |
| `codec/` | 编解码头（OpusHead / Vorbis ID）、VorbisComment/OpusTags、时长换算、**Opus TOC 帧时长** | 无 |
| `manifest/` | `demux`/`mux` 的流目录清单（流号、包数、链序号、逐包粒度） | 无 |
| `pipeline/` | Ogg（Opus / Vorbis）→ WAV 转码管线 | ogg + 两个纯 MoonBit 解码器 |
| `mp4/` | ISOBMFF box 层、`moov`/`stbl` 构造（Opus-in-MP4）、最小读侧 `inspect`、`remux_ogg_opus` | ogg + codec |
| `cli/` | 参数解析（纯逻辑，不碰 I/O 与 stdout） | 无 |
| `cmd/main/` | I/O、错误→退出码、输出排版 | cli + 全部容器包 + `moonbitlang/x` |

分层原则：**容器层（`ogg`/`wav`/`codec`/`manifest`/`mp4`）零三方依赖**，三方解码器只出现在 `pipeline/`；`cli/` 纯函数可离线断言，`cmd/main/` 只做 I/O。

## 3. 关键不变量

1. **Ogg CRC**：`crc32` 覆盖整页（含 `OggS` 捕获模式），CRC 字段置零参与计算；参数为多项式 `0x04c11db7`、初值 0、不反射、末异或。查表实现与逐位定义逐字节一致（`ogg/crc_wbtest.mbt` 交叉校验）。
2. **页/包结构**：段表每项 0..255、总和等于负载长度；单页 ≤255 段、负载 ≤65025；跨页包只在结束页写 granule，其余页写 -1；首页 BOS、每段末页 EOS。
3. **写命令先校验后落盘**：`demux`/`mux`/`cat`/`split`/`extract`/`tag`/`to-wav`/`chop`/`remux` 在输入结构错误、截断或清单不符时拒绝写半成品；已有输出先备份，写后回读自检失败则恢复。
4. **退出码**：`0` 成功；`1` 数据/校验错误；`2` 用法或 I/O 错误。
5. **MP4 盒子自洽**：`stts` 样本时长和 = `mdhd` duration；`stsz` 逐样本大小和 = `mdat` 负载长度；`stsc` 单 chunk 装全部样本，`stco` 指向 `mdat` 负载起点；`dOps` 是 **Box**（首字节为 Version），不是 FullBox —— 写成 FullBox 会让 ffmpeg 读到 zero channel count。
6. **发布一致性**：发布包来自 git 跟踪文件，`.moonignore` 排除 `_build`、`*.mbti`、日志等生成物。

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

## 5. 测试策略

| 层 | 手段 |
|---|---|
| 单元/白盒 | 252 个 `moon test`（页/包/CRC/清单/转码/box/Mp4 往返/CLI 解析），含真实 Ogg 文件的逐页 CRC 断言 |
| 合成流闭环 | 合成 OpusHead+OpusTags+音频包 → Ogg → remux → inspect 读回（`mp4/mp4_wbtest.mbt`） |
| 外部对账 | `scripts/verify_mp4.sh`：真实样本 remux 后 ffprobe 断言编码/声道/采样率/时长，ffmpeg 解码无错 |
| 端到端 | `scripts/smoke.sh`：CLI 往返逐字节、退出码、边界输入、MP4/remux 项 |
| 可安装性 | `scripts/install_check.sh`：干净工程 `moon add` → 调用公开 API → 运行 |
| 门禁 | CI：`check --deny-warn`、`fmt --check`、`info`、双平台测试、覆盖率非回归、native smoke、mp4 verify、install |

## 6. 已知边界与下一期候选

- 2 GiB 文件上限（`Int` 32 位 + `@fs` 整文件 API）；无流式写接口。
- MP4 仅 Opus 单音轨；Vorbis-in-MP4 明确不做。
- 无 `examples/` 之外的 benchmark 体系；fuzz 仅确定性用例。
- 下一期候选：流式 `PageReader`/`WavWriter`、CRC/序列化基准、mutation fuzz corpus、WAV float/块保真、MP4 读侧（demux MP4 → Ogg）。
