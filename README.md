> 作者：WangYF0829（王轶凡）｜创建日期：2026-10-13｜用途：moonmux 项目说明文档

# moonmux

[![CI](https://github.com/WangYF0829/moonmux/actions/workflows/ci.yml/badge.svg)](https://github.com/WangYF0829/moonmux/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-203%20passing-brightgreen.svg)](#构建与测试)
[![Version](https://img.shields.io/badge/version-0.1.0-blue.svg)](CHANGELOG.md)

纯 MoonBit 实现的音频容器工具包，补上 MoonBit 生态中「能解码、不能封装」的最后一环。

## 为什么做这个

截至 2026 年 10 月，MoonBit 生态已经有一批纯 MoonBit 编写的音频解码器（Opus、Vorbis、MP3、WAV 等），也有播放管线，但**没有一个可独立复用的容器库**：解码器各自在包内附带一份仅供自己使用的 Ogg 代码，外部取不到，而且普遍只读。解出来的 PCM 能存成 WAV，却没法重新封装回 Ogg。

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
| `ogg/` | 页 / 段 / 包解析与序列化；Ogg 专用 CRC-32；多逻辑流交织；物理流链接与拆分；按大小攒页；granule 二分定位；结构体检（分级 + 坏页重同步）；页级补丁 | 已完成 |
| `codec/` | 编解码头解析（OpusHead / Vorbis ID）、时长换算、VorbisComment / OpusTags 读写 | 已完成 |
| `manifest/` | `demux`/`mux` 的流目录清单（流号、包数、链序号、逐包粒度）的解析与生成 | 已完成 |
| `wav/` | WAV（RIFF/PCM）读写 | 已完成 |
| `pipeline/` | Ogg（Opus / Vorbis）→ WAV 转码管线 | 已完成 |
| `cmd/main/` | 命令行工具：`info`、`demux`、`mux`、`cat`、`split`、`extract`、`dump`、`tags`、`tag`、`seek`、`verify`、`to-wav` | 已完成 |

**容器层（`ogg/`、`wav/`）不依赖任何三方包**：容器格式的正确性应当能被独立验证，不该被解码器的缺陷掩盖。解码环节留给生态中已有的纯 MoonBit 解码器（`LL728/moonopus`、`LL728/moonvorbis`），通过 `pipeline/` 对接 —— 三方依赖被隔离在这一层，不在容器层。

## 作为库使用

模块已按 mooncakes.io 规范命名（`WangYF0829/moonmux`）。发布后可直接引用：

```bash
moon add WangYF0829/moonmux
```

容器层（`ogg/`、`wav/`、`codec/`、`manifest/`）全部是纯函数、零依赖，可以单独复用；
只有 `pipeline/` 会引入解码器。各包职责见 `AGENTS.md`。

## 退出码约定

| 退出码 | 含义 |
|---|---|
| `0` | 成功 |
| `1` | 数据校验未通过（输入不是合法 Ogg、被截断、清单与目录不符、`verify` 的 error / CRC 失败） |
| `2` | 用法或 I/O 错误（参数错、文件读不到、拒绝覆盖非空目录等） |

脚本与 CI 可直接据此判断，不必 grep 中文输出。

**只读命令对损坏文件保持宽容**：`info` / `dump` / `tags` 在文件有结构问题时尽量给出能读到的信息（`info` / `dump` 会提示「只解析到偏移 X」），退出码仍为 0；**会写产物的命令**（`demux` / `mux` / `cat` / `split` / `extract` / `tag` / `to-wav`）在输入有 error 级结构问题、被截断或清单不符时拒绝执行并返回 1 —— 不产出半截文件。端到端检查见 `scripts/smoke.sh`（33 项，覆盖往返、退出码、截断与清单异常）。

## 能力边界

| 项 | 上限 | 原因 |
|---|---|---|
| 单文件大小 | **2 GiB** | MoonBit `Int` 是 32 位，页偏移与长度都用它；`@fs` 也只有整文件 API |
| `demux` 包数 | **999999** | 包文件名固定 6 位，超过后字典序错乱、`mux` 读回顺序不对 |
| `to-wav` PCM 预算 | **256 MiB**（`MOONMUX_MAX_PCM_MB` 可调大） | 整条链路没有流式写接口，PCM 必须攒齐再落盘；实测峰值约为预算的 3–4 倍 |
| `to-wav` 速度 | Opus 约 1.5× 实时；**Vorbis 约 80× 实时** | 纯 MoonBit 解码器；Vorbis 路径明显更慢，长文件请先 `split` |
| chained 拆分 | 整段都由单页流组成时无法拆分 | 与「一段内交织两条单页流」字节相同，规格上不可判定（保守不切） |
| 裁剪流时长 | 上界 | 容器层拿不到首个音频页的样本数，精确值需解码 |

内存量级：所有命令都整文件读入（约 1–2× 文件大小）；`cat`/`mux` 写出时再加一份输出副本（实测 3.7×）；`to-wav` 还要叠加解码器的 Double PCM（约 4–5× 输出）。

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

## 使用

命令行工具的用法：

```sh
# 查看容器信息（自动识别 Ogg 与 WAV）
#   Ogg：格式、流号、页数、包数、负载字节、各流末粒度；能识别音频流时再给编码/声道/采样率/时长
#   WAV：声道、采样率、位深、PCM 字节数、帧数与时长
moonmux info input.ogg
moonmux info input.wav
#   注：时长为「末粒度 − 首粒度 − pre-skip」，对裁剪过的流是上界（见 docs/design.md）

# 结构体检：逐页 CRC + 页序号连续性 + BOS / EOS 完备性 + 段表一致性
#   用于判断文件是容器损坏还是编码问题，并给出损坏的具体位置
moonmux verify input.ogg

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

# 注释：读取与改写（KEY= 表示删除该键）
moonmux tags input.ogg
moonmux tag input.ogg tagged.ogg TITLE=月光 ARTIST=王轶凡

# 定位：按毫秒找到不晚于该时刻的页（打印页下标、字节偏移与该页起始时间）
#   链接流可用第 3 个参数指定第几段（默认第 1 段）
moonmux seek input.ogg 2500
moonmux seek chained.ogg 500 2

# 转码：Ogg（Opus / Vorbis）→ WAV（16 位 PCM）
moonmux to-wav input.ogg output.wav
```

构建命令行工具需要 native 后端（MSVC）：

```sh
moon build --target native
```

## 项目结构

```
moonmux/
├── moon.mod           模块配置
├── moon.pkg           根包
├── moonmux.mbt        模块级描述
├── ogg/               Ogg 容器
│   ├── crc.mbt        CRC-32（RFC 3533 参数）与页校验
│   ├── page.mbt       页的解析与序列化
│   ├── packet.mbt     包重组与页切分
│   ├── mux.mbt        多逻辑流的分组与交织
│   ├── chain.mbt      物理流链接与拆分（chained bitstream）
│   ├── verify.mbt     结构体检（段表 / 页序号 / BOS·EOS）
│   └── stream.mbt     字节流 ↔ 页序列
├── wav/               WAV 容器
├── pipeline/          转码管线（唯一引入三方解码器的包）
├── cli/               命令行参数解析（纯逻辑）
├── cmd/main/          命令行入口
├── testdata/          真实音频样本
└── docs/design.md     设计说明
```

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

实现全部为 MoonBit 原创，没有移植或复制其他项目的代码。以下项目只在**行为与取舍**上作为对照：

| 项目 | 参考了什么 | 没有照搬什么 |
|---|---|---|
| Xiph `oggz` / `liboggz` | 子命令的语义（`rip`/`dump`/`validate`/`chop` 的职责划分）、多流合并按呈现时间 | 不做 Skeleton，不解析 Theora/FLAC 等头；`dump` 不可逆 |
| `libogg` | 页大小与 flush 时机（4096 阈值、首页/EOS 强制刷出） | 不把 BOS 顺序交给调用方；写侧自己维护不变量 |
| `mutagen`（Python） | 注释改写时用 padding 保持旧包等长、复用旧页布局 | 不做 high/low 区间公式 |
| `ffmpeg` | 作为行为对照（转码产物用独立工具回读验证） | 不用时间驱动的分页策略 |
| `libopusfile` | seek 在 granule 上插值二分、80 ms pre-roll | 只定位到页，不解码 |

测试样本说明：`testdata/` 下的 Opus / Vorbis 文件由 ffmpeg（libopus / libvorbis）生成，仅用于测试，
不包含任何第三方受版权保护的音频内容。

## 开发状态

本项目为 2026 MoonBit 黑客松十月赛参赛作品，当前版本 **0.1.0**（2026-10-22）。

已可用：Ogg 容器读写（含多逻辑流的分组与交织写出、物理流链接与拆分、结构体检）、WAV 读写、
Ogg → WAV 转码管线（Opus 与 Vorbis 均已实测），
`info` / `demux` / `mux` / `cat` / `split` / `extract` / `dump` / `tags` / `tag` / `seek` / `verify` / `to-wav` 十三个子命令，
203 个测试（native；wasm-gc 193，cmd/main 只支持 native）通过，并通过真实 Opus / Vorbis 文件的逐页 CRC、拆包—重封装往返验证、
双逻辑流交织—还原往返验证、物理流链接—拆分往返验证（含流号冲突场景）与转码验证。

工程配套：`moon check --deny-warn` 零警告、`moon fmt --check` 通过、`wasm-gc` 与 `native` 双后端
203 个测试（native；wasm-gc 193，cmd/main 只支持 native）、33 项端到端检查（`scripts/smoke.sh`）、GitHub Actions CI（ubuntu + windows 矩阵，
外加覆盖率非回归门禁与 native 冒烟）。
变更记录见 `CHANGELOG.md`，协作约定见 `AGENTS.md`，开发过程与取舍见 `docs/开发历程.md`。

尚未完成：MP4 / ISOBMFF 的封装；WAV → Ogg 的反向管线（生态中尚无纯 MoonBit 编码器）。
详见 `docs/design.md`。

## 许可证

Apache-2.0，见 `LICENSE`。
