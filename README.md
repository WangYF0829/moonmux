> 作者：WangYF0829（王轶凡）｜创建日期：2026-10-13｜用途：moonmux 项目说明文档

# moonmux

纯 MoonBit 实现的音频容器工具包，补上 MoonBit 生态中「能解码、不能封装」的最后一环。

## 为什么做这个

截至 2026 年 10 月，MoonBit 生态已经有一批纯 MoonBit 编写的音频解码器（Opus、Vorbis、MP3、WAV 等），也有播放管线，但**没有任何一个包能把解码结果写回容器文件**。解出来的数据只能进内存、进扬声器，出不了文件。

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
| `ogg/` | Ogg 页、段、包的解析与序列化；Ogg 专用 CRC-32 校验；多逻辑流的分组与交织 | 已完成 |
| `wav/` | WAV（RIFF/PCM）读写 | 已完成 |
| `pipeline/` | Ogg（Opus / Vorbis）→ WAV 转码管线 | 已完成 |
| `cmd/main/` | 命令行工具：`info`、`demux`、`mux`、`verify`、`to-wav` | 已完成 |

**容器层（`ogg/`、`wav/`）不依赖任何三方包**：容器格式的正确性应当能被独立验证，不该被解码器的缺陷掩盖。解码环节留给生态中已有的纯 MoonBit 解码器（`LL728/moonopus`、`LL728/moonvorbis`），通过 `pipeline/` 对接 —— 三方依赖被隔离在这一层，不在容器层。

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
# 查看容器信息（流数、页数、包数、负载字节）
moonmux info input.ogg

# 逐页校验 CRC，报告通过率（判断是容器损坏还是编码问题）
moonmux verify input.ogg

# 解复用：按逻辑流拆出包，每条流一个子目录（s1/、s2/……）
moonmux demux input.ogg ./packets/

# 复用：把包重新封装成 Ogg
#   目录里有子目录 → 每个子目录一条逻辑流，按 Ogg 规则交织（BOS 页置顶、数据页按粒度升序）
#   目录里没有子目录 → 整个目录一条逻辑流
moonmux mux ./packets/ output.ogg

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
│   └── stream.mbt     字节流 ↔ 页序列
├── wav/               WAV 容器
├── pipeline/          转码管线（唯一引入三方解码器的包）
├── cli/               命令行参数解析（纯逻辑）
├── cmd/main/          命令行入口
├── testdata/          真实音频样本
└── docs/design.md     设计说明
```

## 参考规范

- RFC 3533: The Ogg Encapsulation Format Version 0
- RFC 7845: Ogg Encapsulation for the Opus Audio Codec
- RFC 3534: The application/ogg Media Type
- Microsoft RIFF 规范（WAV）

## 开发状态

本项目为 2026 MoonBit 黑客松十月赛参赛作品，开发中。

已可用：Ogg 容器读写（含多逻辑流的分组与交织写出）、WAV 读写、
Ogg → WAV 转码管线（Opus 与 Vorbis 均已实测），
`info` / `demux` / `mux` / `verify` / `to-wav` 五个子命令，
49 个测试通过，并通过真实 Opus / Vorbis 文件的逐页 CRC、拆包—重封装往返验证、
双逻辑流交织—还原往返验证与转码验证。

尚未完成：MP4 / ISOBMFF 的封装；WAV → Ogg 的反向管线（生态中尚无纯 MoonBit 编码器）。
详见 `docs/design.md`。

## 许可证

Apache-2.0，见 `LICENSE`。
