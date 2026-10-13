<!--
作者：WangYF0829（王轶凡）
创建日期：2026-10-13
用途：moonmux 项目说明文档
-->

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
| `ogg/` | Ogg 页、段、包的解析与序列化；Ogg 专用 CRC-32 校验 | 开发中 |
| `wav/` | WAV（RIFF/PCM）读写 | 规划中 |
| `cmd/main/` | 命令行工具：`info`、`demux`、`mux` | 规划中 |

设计上刻意**不依赖任何三方包**：容器格式的正确性应当能被独立验证，不该被解码器的缺陷掩盖。解码环节留给生态中已有的解码器，通过转码管线对接。

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

命令行工具规划中的用法：

```sh
# 查看容器信息（流数、页数、包数、时长）
moonmux info input.ogg

# 解复用：把包拆出来
moonmux demux input.ogg ./packets/

# 复用：把包重新封装成 Ogg
moonmux mux ./packets/ output.ogg
```

## 项目结构

```
moonmux/
├── moon.mod           模块配置
├── moon.pkg           根包
├── moonmux.mbt        模块级描述
├── ogg/               Ogg 容器
│   ├── crc.mbt        CRC-32（RFC 3533 参数）
│   ├── page.mbt       页的解析与序列化
│   └── packet.mbt     包重组
├── wav/               WAV 容器
├── cmd/main/          命令行入口
└── docs/design.md     设计说明
```

## 参考规范

- RFC 3533: The Ogg Encapsulation Format Version 0
- RFC 7845: Ogg Encapsulation for the Opus Audio Codec
- RFC 3534: The application/ogg Media Type
- Microsoft RIFF 规范（WAV）

## 开发状态

本项目为 2026 MoonBit 黑客松十月赛参赛作品，开发中。当前进度与后续计划见 `docs/design.md`。

## 许可证

Apache-2.0，见 `LICENSE`。
