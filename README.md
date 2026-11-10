> 作者：WangYF0829（王轶凡）｜创建日期：2026-10-13｜用途：moonmux 项目文档

# moonmux

[![CI](https://github.com/WangYF0829/moonmux/actions/workflows/ci.yml/badge.svg)](https://github.com/WangYF0829/moonmux/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-335%20passing-brightgreen.svg)](#构建与测试)
[![Version](https://img.shields.io/badge/version-0.9.0-blue.svg)](https://github.com/WangYF0829/moonmux/releases)
[![mooncakes](https://img.shields.io/badge/mooncakes-0.9.0-blueviolet)](https://mooncakes.io/docs/WangYF0829/moonmux)

纯 MoonBit 实现的音频容器工具包，补上 MoonBit 生态中「能解码、不能封装」的最后一环。

## 2026-11 更新（v0.8.0）

项目当前版本 **v0.9.0**（2026-11-10，第二轮正确性/契约修复版）。主要能力与发布里程碑：

| 项 | 状态 |
|---|---|
| **MP4 / ISOBMFF 写入**（Opus-in-MP4，新 `mp4/` 包：`ftyp`/`moov`/`mdat`、`stbl` 表、`dOps`） | **已完成** |
| **`remux` 命令**：Ogg Opus → `.m4a` | **已完成** |
| **`info` 识别 MP4** | **已完成** |
| **CRC-32 查表优化**（输出与 RFC 3533 逐字节一致） | **已完成** |
| **WAV 全格式兼容**：IEEE float 32/64、`WAVE_FORMAT_EXTENSIBLE`、24-in-4 容器；新增 `encode_wav_ex` | **已完成（v0.4.0）** |
| **流式页读取**：增量 `PageReader`（分块喂入、按需取页、失步重同步） | **已完成（v0.4.0）** |
| **`to-ogg` 命令**：MP4（Opus-in-MP4）→ Ogg Opus，与 `remux` 互逆 | **已完成（v0.5.0）** |
| **性能基准 `scripts/bench.mjs`**：verify/info/dump/remux/to-ogg/demux 端到端计时，CI 运行并写 job summary | **已完成（v0.6.0）** |
| **确定性变异测试 `scripts/fuzz.mjs`**：真实 Ogg/Vorbis/MP4/WAV × 6 类变异，CI 400 次/固定种子 | **已完成（v0.6.0）** |
| **WAV 块保真**：LIST/fact 等扩展块原样保留，`WavFile::to_bytes` 逐字节还原（含 24-in-4 容器与 channelMask） | **已完成（v0.7.0）** |
| **流式写接口 `WavWriter`**：增量追加 PCM、可选扩展块，`finish` 生成 WAV | **已完成（v0.7.0）** |
| **正确性修复（v0.8.0）**：remux 输入闸门 + 拒绝链式/多流、MP4 读侧防越界 panic、stsz 定长样本与样本偏移上界、多声道 OpusHead `StreamCount/CoupledCount`、MP4→Ogg granule 语义、dOps OutputGain 透传、头包页隔离、跨页包替换、WAV 原始 fmt 布局保真、manifest/mux 自检 | **已完成（v0.8.0）** |
| **第二轮正确性/契约修复（v0.9.0）**：MP4 写侧补 `edts/elst` + `roll` 样本组与 end-trim、WAV 浮点 `fact` 块与重复块拒绝、Ogg 头包预筛重同步 + 页校验序列化、CLI 诊断走 stderr / JSON 错误对象 / `--hex` 宽容 / 提取 `--force` / 选项任意位置 / tags 控制字符转义、2 GiB 聚合闸门、PCM 预算显式校验、POSIX 路径与 8.3 短名、manifest 重复头拒绝 | **已完成（v0.9.0）** |
| 测试 / 示例 / 文档 / CHANGELOG / **v0.9.0 发布（mooncakes + GitHub Release）** | **已完成** |

- **已可用（最新发布 v0.9.0）**：`moon add WangYF0829/moonmux` 安装 **v0.9.0**（2026-11-10 正确性修复版：remux 输入闸门、MP4 读侧防崩溃、stsz/偏移上界、多声道 OpusHead、granule 语义、dOps gain、头包页隔离、跨页包替换、WAV fmt 布局保真等；此前 v0.7.x 提供 WAV 块保真与 `WavWriter`，v0.6.0 性能基准与变异测试，v0.5.0 `to-ogg` 解封装，v0.4.0 WAV 全格式与流式页读取）。
- 变更明细见 [CHANGELOG.md](CHANGELOG.md)。


## 为什么做这个

MoonBit 生态目前已经有一批纯 MoonBit 编写的音频解码器（Opus、Vorbis、MP3、WAV 等），也有播放管线，但**没有一个可独立复用的容器库**：解码器各自在包内附带一份仅供自己使用的 Ogg 代码，外部取不到，而且普遍只读。解出来的 PCM 能存成 WAV，却没法重新封装回 Ogg。

（边界说清楚：本项目补的是「**读写已有压缩包**」这一环 —— 把包重新封装成合规的 Ogg、读写注释、定位与诊断。**不做 PCM → Ogg 的编码器**，那需要 Opus / Vorbis 编码器本体，不在本项目范围；解码产物落盘走 `to-wav`。）

这不是「没人想到」，而是价值链的最后一环空缺：

| 环节 | 生态现状 |
|---|---|
| 读容器（demux） | 有：`isobmff`（MP4 解析）、`moontsinspect`（TS 检查） |
| 解码 | 有：`moonopus`、`moonvorbis`、`mp3.mbt`、`moon-wav` |
| 播放 | 有：`moon_rodio` |
| **写容器（mux）** | **没有** |
| **转码管线** | **没有** |

moonmux 补的就是最后两行。

## 功能范围

| 模块 | 内容 | 状态 |
|---|---|---|
| `ogg/` | 页 / 段 / 包解析与序列化；Ogg 专用 CRC-32；多逻辑流交织；物理流链接与拆分；按大小攒页；granule 二分定位；结构体检（分级 + 坏页重同步）；页级补丁；**增量页读取 `PageReader`**（v0.4.0，流式/失步重同步） | 已完成 |
| `codec/` | 编解码头解析（OpusHead / Vorbis ID）、时长换算、VorbisComment / OpusTags 读写 | 已完成 |
| `manifest/` | `demux`/`mux` 的流目录清单（流号、包数、链序号、逐包粒度）的解析与生成 | 已完成 |
| `wav/` | WAV（RIFF）读写：PCM 8/16/24/32、IEEE float 32/64、`WAVE_FORMAT_EXTENSIBLE`、24-in-4 容器读取；整数 PCM 编码与 `encode_wav_ex`（float/Extensible）；**v0.7.0 块保真（LIST/fact 扩展块、channelMask）+ `WavFile::to_bytes` + `WavWriter`** | 已完成（v0.4.0 全格式 / v0.7.0 块保真） |
| `pipeline/` | Ogg（Opus / Vorbis）→ WAV 转码管线 | 已完成 |
| `mp4/` | MP4/ISOBMFF：写侧 `ftyp`/`moov`/`mdat`/`stbl` 五表/`dOps`（Opus-in-MP4，v0.3.x）；读侧 `inspect` + **`demux_mp4_opus` 解封装回 Ogg**（v0.5.0，读写闭环） | **已完成（v0.3.x 写 / v0.5.0 读）** |
| `cmd/main/` | 命令行工具：`info`、`demux`、`mux`、`cat`、`split`、`extract`、`dump`、`tags`、`tag`、`seek`、`verify`、`to-wav`、`chop`、`remux`、`to-ogg` | 已完成 |

**容器层（`ogg/`、`wav/`）不依赖任何三方包**：容器格式的正确性应当能被独立验证，不该被解码器的缺陷掩盖。解码环节留给生态中已有的纯 MoonBit 解码器（`LL728/moonopus`、`LL728/moonvorbis`），通过 `pipeline/` 对接 —— 三方依赖被隔离在这一层，不在容器层。

## 作为库使用

模块已按 mooncakes.io 规范命名（`WangYF0829/moonmux`）并发布 **0.9.0**（2026-11-10；0.2.0 于 2026-11-06 首发）：

```bash
moon add WangYF0829/moonmux
```

安装后通过 `moon.pkg` 的 `import` 引用各子包，例如：

```text
import {
  "WangYF0829/moonmux/ogg",
  "WangYF0829/moonmux/wav",
}
```

最小示例（`cmd/main/main.mbt`，已验证可在干净工程运行）：

```moonbit
fn main {
  // WAV：编码 → 解析往返
  let bytes = @wav.encode_wav(
    { channels: 1, sample_rate: 8000, bits_per_sample: 16 },
    b"\x00\x00\x01\x00",
  )
  match @wav.WavFile::parse(bytes) {
    Some(f) => println("wav ok: " + f.format.sample_rate.to_string())
    None => println("wav parse failed")
  }
  // Ogg：页起始识别
  println("ogg page: " + @ogg.is_page_start(b"OggS", 0).to_string())
}
```

v0.4.0 新增库 API：`@ogg.PageReader` / `@ogg.for_each_page_chunked`（增量流式读取）、`@wav.SampleFormat` / `@wav.encode_wav_ex`（IEEE float 与 Extensible 编码）；v0.5.0 新增 `@mp4.demux_mp4_opus`（MP4 → Ogg）；v0.7.0 新增 `@wav.WavChunk` / `@wav.WavFile::to_bytes`（块保真）与 `@wav.WavWriter`（增量写）。

容器层（`ogg/`、`wav/`、`codec/`、`manifest/`、`mp4/`）全部是纯函数、零依赖，可以单独复用；
只有 `pipeline/` 会引入解码器。安装可用性已在干净工程实测：`moon add` → `moon check` → `moon run`。

## 退出码约定

| 退出码 | 含义 |
|---|---|
| `0` | 成功 |
| `1` | 数据校验未通过（输入不是合法 Ogg、被截断、清单与目录不符、`verify` 的 error / CRC 失败） |
| `2` | 用法或 I/O 错误（参数错、文件读不到、拒绝覆盖非空目录等） |

脚本与 CI 可直接据此判断，不必 grep 中文输出。

**写命令要求输入完整**：每页 CRC 通过、每条逻辑流以 EOS 收尾、尾部最多 1 MiB 全零填充；
缺 EOS 的直播流会被拒绝（本工具面向静态文件）。`verify` 对缺 EOS 只报 warn（退出 0），
写命令则按数据错误处理（退出 1）。
输入与输出路径相同（含大小写别名、`..`、硬链接）会被拒绝；内容与输入完全相同的已有输出也会被拒绝。
`mux` 还会把已有输出与实际读取的每个包/清单做身份比较，拦截目录外任意文件名的硬链接别名。
写命令面向单写者：不要并发写同一个输出文件。

**错误与用法信息统一走 stderr**（stdout 只留成功结果；`--json` 命令失败时输出 `{"error":...}`）。**只读命令对损坏文件保持宽容**：`info` / `dump` / `tags` 在文件有结构问题时尽量给出能读到的信息（`info` / `dump` 会提示「只解析到偏移 X」），退出码仍为 0；**会写产物的命令**（`demux` / `mux` / `cat` / `split` / `extract` / `tag` / `to-wav` / `chop`）在输入有 error 级结构问题、被截断或清单不符时拒绝执行并返回 1 —— 不产出半截文件。端到端检查见 `scripts/smoke.sh`（POSIX 54 项，覆盖往返、退出码、截断、清单异常、FIFO 与输出别名防护）。

## 能力边界

| 项 | 上限 | 原因 |
|---|---|---|
| 单文件大小 | **2 GiB** | MoonBit `Int` 是 32 位，页偏移与长度都用它；`@fs` 也只有整文件 API；聚合写命令在分配前显式估算并拒绝越界 |
| MP4 写侧 | 仅 **Opus-in-MP4**、单音轨、单 chunk | 只补 Opus；Vorbis-in-MP4 非主流且需解析 Vorbis setup，明确不做；`remux` 只接受 Ogg Opus 输入 |
| MP4 读侧 | 仅解封装 **Opus-in-MP4**（单音轨、`mdhd` timescale=48000） | `to-ogg` 是 `remux` 的逆操作；注释不随 MP4 保存，输出使用最小 OpusTags |
| `demux` 包数 | **999999** | 包文件名固定 6 位，超过后字典序错乱、`mux` 读回顺序不对 |
| `to-wav` PCM 预算 | **256 MiB**（`MOONMUX_MAX_PCM_MB` 可调，1..2048） | 整条链路没有流式写接口，PCM 必须攒齐再落盘；实测峰值约为预算的 3–4 倍。外部解码器一次返回整段 PCM，恶意伪造的 granule 仍可能造成超出预算的瞬时分配 |
| `chop` Opus 时间戳 | 页精度，约 ±1 页 | 不重写 OpusHead 的 pre-skip；裁剪后首个数据页可能多带不到一页的前导样本 |
| `to-wav` 速度 | Opus 约 30× 实时（6.02 s 音频 ≈0.2 s）；**Vorbis 1.0 s 音频约需 60–70 s** | 纯 MoonBit 解码器；Vorbis 路径明显更慢，长文件请先 `split`（release native / Windows x64 实测） |
| chained 拆分 | 整段都由单页流组成时无法拆分 | 与「一段内交织两条单页流」字节相同，规格上不可判定（保守不切） |
| 裁剪流时长 | 上界 | 容器层拿不到首个音频页的样本数，精确值需解码 |
| MP4 编辑列表 | 已写 `edts/elst`（pre-skip 裁剪）与 `roll` 样本组 | 不做章节/多轨编辑；`mdhd` 保留总样本数，`mvhd/tkhd` 用裁剪后时长 |
| `remux` 输入 | 单段、单逻辑流 Ogg | 链式/多流输入显式拒绝（exit 1），不再静默只取第一段 |
| `PageReader` 重同步 | 无候选步进上限 | 大量伪造 `OggS` 的恶意输入可能造成 CPU / `gaps` 放大；普通文件不受影响 |
| 写侧公开 API | `serialize_pages_checked` / `validate_page` 可用 | CLI 写命令已全部走校验入口；库用户直接调用 `serialize_pages` 时仍需自行保证 `Page` 合法 |
| WAV 块保真布局 | fmt 在 data 之前、扩展块在 fmt 之后的标准布局 | 原始 fmt 与扩展块逐字节写回；fmt 之前出现未知块或非零填充字节的极端布局会按语义规范化（扩展块保留、采样数据无损） |
| `extract` 幂等重跑 | 需显式 `--force` | 输出与输入内容相同（单流文件抽自己）时默认按别名保护拒绝；`--force` 跳过内容比较（仍拒绝同一路径），可用于幂等重跑 |

内存量级（实测，19 MB / 300 段输入）：`info` 约 2.5×、`verify` 约 2.6×、`cat`/`mux` 约 3.5×；
`to-wav` 还要叠加解码器的 Double PCM（约 4–5× 输出）。所有命令整文件读入，没有流式写接口。

## 构建与测试

需要 MoonBit 工具链。在 PowerShell 中安装：

```powershell
irm https://cli.moonbitlang.cn/install/powershell.ps1 | iex
```

安装后新开终端，确认可用：

```sh
moon version
```

构建与测试：

```sh
moon build
moon test
```

## 性能基准（bench）

`scripts/bench.mjs`（Node，无第三方依赖）在 release 版 native CLI 上做端到端计时：
自动把 `testdata/opus_sample.opus` 复制成 16 条 serial 递增的链接流（≈1.0 MiB）作为大输入，
每个操作运行 N 次取最小值（含进程启动 1–2 ms）。

```sh
moon build --release --target native
node scripts/bench.mjs --runs 5
```

本机实测（Windows 11 x64，release native，2026-11-09）：

| 操作 | 输入 | 最小耗时 | 吞吐 |
|---|---:|---:|---:|
| `verify`（CRC + 结构体检） | 1.02 MiB | 22.9 ms | 44 MB/s |
| `info --json` | 1.02 MiB | 18.8 ms | 54 MB/s |
| `dump`（页级转储） | 1.02 MiB | 18.2 ms | 56 MB/s |
| `remux`（Ogg → MP4） | 65 KiB | 16.9 ms | — |
| `to-ogg`（MP4 → Ogg） | 66 KiB | 18.7 ms | — |
| `demux`（拆包写目录） | 65 KiB | 87.8 ms | — |

CI 的 `bench` job 会用 ubuntu-latest 跑同一脚本，并把表格写进 job summary（只记录、不设阈值）。

## 变异测试（fuzz）

`scripts/fuzz.mjs` 采用「种子 + 确定性变异」（参考 cargo-fuzz / AFL++ 的 mutation 模式，不依赖其引擎）：

- 种子：真实 Ogg Opus / Vorbis、CLI 生成的 MP4 与 WAV；
- 变异：随机翻位、块覆盖、截断、插入、删除、整段复制；
- 目标命令：`info` / `verify` / `seek` / `dump` / `to-ogg`；
- 断言：退出码只能是 0（成功）/ 1（数据错误）/ 2（用法/I/O），且不超时、不崩溃。

```sh
moon build --target native
node scripts/fuzz.mjs --iterations 400 --seed 20261109
```

本地 200 次实测：成功 121、数据/用法错误 79、**异常 0**。CI 的 `fuzz` job 固定种子跑 400 次，
坏样本出现时可用相同 `--seed` 复现。

## 使用

命令行工具的用法：

```sh
# 查看容器信息（自动识别 Ogg 与 WAV）
#   Ogg：格式、流号、页数、包数、负载字节、各流末粒度；能识别音频流时再给编码/声道/采样率/时长
#   WAV：声道、采样率、位深、PCM 字节数、帧数与时长
moonmux info input.ogg
moonmux info input.wav
moonmux info input.ogg --json    # 单行 JSON，便于脚本处理
#   注：时长为「末粒度 − 首粒度 − pre-skip」，对裁剪过的流是上界

# 结构体检：逐页 CRC + 页序号连续性 + BOS / EOS 完备性 + 段表一致性
#   用于判断文件是容器损坏还是编码问题，并给出损坏的具体位置
moonmux verify input.ogg
moonmux verify input.ogg --json  # 完整 findings（文本只铺前 10 条）

# 解复用：按逻辑流拆出包，每条流一个子目录（s1/、s2/……）
moonmux demux input.ogg ./packets/

# 复用：把包重新封装成 Ogg
#   目录里有子目录 → 每个子目录一条逻辑流，按 Ogg 规则交织（BOS 页置顶、数据页按粒度升序）
#   目录里没有子目录 → 整个目录一条逻辑流
moonmux mux ./packets/ output.ogg

# 链接：把多个 Ogg 文件首尾相接成一个物理流
#   流号不冲突时逐页原样透传（字节级无损）；冲突时把后一个文件相撞的流换新流号
moonmux cat a.ogg b.ogg c.ogg output.ogg

# 拆分：把链接流按链接点切回各自独立的 Ogg 文件（输出 part1.ogg、part2.ogg……）
#   页原样沿用，字节与 CRC 一字节不改 —— 非链接流得到的 part1 与输入完全相同
moonmux split chained.ogg ./parts/

# 抽流：把第 n 条逻辑流单独取出来（页级原样，可与输入逐字节对账）
moonmux extract input.ogg 2 single.ogg

# 页级转储：偏移 / 流号 / 页序 / 粒度 / 标志 / 段数 / 负载
moonmux dump input.ogg
moonmux dump input.ogg --hex     # xxd 兼容，可 `| xxd -r` 还原

# 注释：读取与改写（KEY= 表示删除该键）
moonmux tags input.ogg
moonmux tag input.ogg tagged.ogg TITLE=月光 ARTIST=王轶凡

# 定位：按毫秒找到不晚于该时刻的页（打印页下标、字节偏移与该页起始时间）
#   链接流可用第 3 个参数指定第几段（默认第 1 段）
moonmux seek input.ogg 2500
moonmux seek chained.ogg 500 2

# 转码：Ogg（Opus / Vorbis）→ WAV；默认 16 位，可选 24 位
moonmux to-wav input.ogg output.wav
moonmux to-wav input.ogg output24.wav 24

# 重新封装：Ogg（Opus）→ MP4 / ISOBMFF 音频容器（.m4a，v0.3.x 新增）
#   不做转码：Opus 数据包原样搬运，只重建容器；info 可识别产物
moonmux remux input.ogg output.m4a
moonmux info output.m4a

# 反向解封装：MP4（Opus）→ Ogg（v0.5.0 新增，remux 的逆操作）
#   音频包逐字节还原；注释未随 MP4 保存，输出最小 OpusTags
moonmux to-ogg output.m4a back.ogg
moonmux verify back.ogg

# 裁剪：按毫秒区间裁剪（页精度，头页保留，时间轴归零）
moonmux chop input.ogg clip.ogg 1000 3000
```

构建命令行工具需要 native 后端（MSVC）：

```sh
moon build --target native
```

## 项目结构

```
moonmux/
├── moon.mod / moon.pkg / moonmux.mbt   模块配置与根包
├── ogg/               Ogg 容器（页 / 段 / 包、CRC、交织、链接、结构体检、PageReader）
├── wav/               WAV 容器（全格式读写、块保真、WavWriter）
├── codec/             编解码头解析（OpusHead / Vorbis ID / OpusTags / VorbisComment / TOC）
├── manifest/          demux / mux 的流目录清单
├── pipeline/          转码管线（唯一引入三方解码器的包）
├── mp4/               MP4 / ISOBMFF 写入与解封装
├── cli/               命令行参数解析（纯逻辑）
├── cmd/main/          命令行入口
├── docs/architecture.md   模块边界、关键不变量、测试策略、能力边界
├── examples/          三个可运行示例
├── scripts/           smoke / verify_mp4 / bench / fuzz / install_check
└── testdata/          真实音频样本
```

## 示例（examples/）

| 示例 | 命令 | 说明 |
|---|---|---|
| WAV 往返 | `moon run examples/wav_roundtrip` | 最小库用法：`encode_wav` → `WavFile::parse` |
| Ogg 信息 | `moon run examples/ogg_info` | 用 `ogg/` + `codec/` 公开 API 读取容器信息 |
| Ogg → MP4 | `moon run examples/remux_ogg_to_mp4` | `mp4/` 写—读对称：remux 后 `inspect` 读回 |
| MP4 → Ogg | `smoke.sh` / `verify_mp4.sh` 的 4e/6 段 | `to-ogg` 后 `verify` + 音频包逐字节比对 |

（在仓库根目录运行；`ogg_info` / `remux_ogg_to_mp4` 读取 `testdata/` 下的真实样本，需要 native 后端。）

架构与设计说明见 [docs/architecture.md](docs/architecture.md)。

## Shell 补全

```bash
source scripts/moonmux.bash   # 子命令与文件路径补全
```

## 参考规范

- RFC 3533: The Ogg Encapsulation Format Version 0
- RFC 7845: Ogg Encapsulation for the Opus Audio Codec
- RFC 3534: The application/ogg Media Type
- Microsoft RIFF 规范（WAV）

## 参考实现与取舍

实现全部为 MoonBit 原创，没有复制其他项目的代码；v0.4.0 的 WAV 全格式与流式页读取、v0.7.0 的块保真只移植了**语义与字段布局**，代码独立实现。以下项目作为**行为与取舍**对照：

| 项目 | 参考了什么 | 没有照搬什么 |
|---|---|---|
| Xiph `oggz` / `liboggz` | 子命令的语义（`rip`/`dump`/`validate`/`chop` 的职责划分）、多流合并按呈现时间 | 不做 Skeleton，不解析 Theora/FLAC 等头；`dump` 不可逆 |
| `libogg` | 页大小与 flush 时机（4096 阈值、首页/EOS 强制刷出） | 不把 BOS 顺序交给调用方；写侧自己维护不变量 |
| `mutagen`（Python） | 注释改写时用 padding 保持旧包等长、复用旧页布局 | 不做 high/low 区间公式 |
| `ffmpeg` | 作为行为对照（转码产物用独立工具回读验证） | 不用时间驱动的分页策略 |
| `libopusfile` | seek 在 granule 上插值二分、80 ms pre-roll | 只定位到页，不解码 |
| Rust `hound`（Apache-2.0） | WAV fmt 标签 1/3/0xFFFE、Extensible 字段布局与 SubFormat GUID、24-in-4 容器语义、float 32/64、未知块跳过 | 不复制代码；v0.7.0 额外保留 channelMask 与扩展块以支持逐字节往返（hound 不暴露这些字段） |
| RustAudio `ogg` crate | 增量页读取状态机语义：先同步捕获模式、按段表等数据、CRC 失步后重同步 | 不复制代码；不实现其异步/seek 组合器 |
| `hyperfine` / `cargo bench` | 基准的「多次运行取最小值 + 表格化输出」呈现方式 | 不引入第三方依赖、不设跨机器阈值（CI 只记录） |
| `cargo-fuzz` / AFL++ | 「种子 + 确定性变异 + 退出码/超时断言」的变异测试模式 | 不使用其 fuzz 引擎；无覆盖率引导 |

测试样本说明：`testdata/` 下的 Opus / Vorbis 文件由 ffmpeg（libopus / libvorbis）生成，仅用于测试，
不包含任何第三方受版权保护的音频内容。

## 开发状态

当前最新版本为 **v0.9.0**（2026-11-10，正确性/契约修复）。版本历程：v0.2.0（2026-10-23）→ v0.3.0–v0.3.2（2026-11-07：MP4 写入、`remux`、CRC 查表）→ v0.4.0（2026-11-09：WAV 全格式与流式页读取）→ v0.5.0（2026-11-09：MP4 → Ogg 解封装 `to-ogg`）→ v0.6.0（2026-11-09：性能基准与变异测试）→ v0.7.0（2026-11-09：WAV 块保真与 `WavWriter`）→ v0.7.1（2026-11-09：文档同步）→ v0.8.0（2026-11-10：审阅问题修复）→ v0.9.0（2026-11-10：第二轮修复）。

已可用：Ogg 容器读写（含多逻辑流的分组与交织写出、物理流链接与拆分、结构体检）、WAV 读写、
Ogg → WAV 转码管线（Opus 与 Vorbis 均已实测）、**MP4/ISOBMFF 写入（Opus-in-MP4，`remux`）与解封装（`to-ogg`）**，
`info` / `demux` / `mux` / `cat` / `split` / `extract` / `dump` / `tags` / `tag` / `seek` / `verify` / `to-wav` / `chop` / `remux` / `to-ogg` 十五个子命令，
335 个测试通过（Windows native 实测；CI 在 ubuntu/windows 上运行），并通过真实 Opus / Vorbis 文件的逐页 CRC、拆包—重封装往返验证、
双逻辑流交织—还原往返验证、物理流链接—拆分往返验证（含流号冲突场景）、转码验证、Ogg→MP4 外部工具（ffprobe/ffmpeg）对账与 MP4→Ogg 逐包还原验证。

工程配套：`moon check --deny-warn` 零警告、`moon fmt --check` 通过、`native` / `wasm-gc` 双后端；
335 个测试、POSIX 端到端检查（`scripts/smoke.sh`，含 remux/MP4 项）、
`scripts/verify_mp4.sh`（ffprobe/ffmpeg 外部对账）、`scripts/install_check.sh`（干净工程 `moon add` 复验）、`scripts/bench.mjs`（性能基准）、`scripts/fuzz.mjs`（确定性变异测试）、
GitHub Actions CI（ubuntu + windows 矩阵，外加覆盖率非回归门禁与 native 冒烟）。
变更记录见 [CHANGELOG.md](CHANGELOG.md) 与 GitHub Releases（v0.1.0 / v0.2.0 / v0.3.0 / v0.3.1 / v0.3.2 / v0.4.0 / v0.5.0 / v0.6.0 / v0.7.0 / v0.7.1 / v0.8.0 / v0.9.0）。

主要新增能力（v0.3.0–v0.9.0）：MP4 / ISOBMFF 封装（Opus-in-MP4）与 `remux`、MP4 → Ogg 解封装 `to-ogg`（读写闭环）；CRC-32 查表优化；WAV 全格式兼容（IEEE float / Extensible / 24-in-4）与增量流式页读取；性能基准与确定性变异测试；WAV 块保真与流式写接口 `WavWriter`；以及 v0.8.0 的 Opus TOC / remux 闸门 / MP4 读侧 / stsz / 多声道头 / granule / dOps gain / 头包页隔离 / 跨页替换 / WAV fmt 布局等正确性修复。
仍不做：WAV → Ogg 的反向管线（生态中尚无纯 MoonBit 编码器，边界与原因见上）。

## 许可证

Apache-2.0，见 `LICENSE`。
