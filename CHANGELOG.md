# 更新日志

本项目遵循语义化版本；每个版本对应 GitHub Release 与 mooncakes.io 发布。
更早的历史见 `git log` 与 GitHub Releases。

## [Unreleased] — v0.3.0（2026-11，开发中）

2026 年 11 月按「已有项目维护」方向持续开发，本期目标：补齐 MP4 写入能力与工程化。

### 新增
- 计划：`mp4/` 包 —— MP4 / ISOBMFF 写入（Opus-in-MP4：`ftyp` / `moov` / `mdat`、`stbl` 五表、`dOps`）。
- 计划：`remux` 命令 —— Ogg（Opus）→ `.m4a`。
- 计划：`info` 识别 MP4（编码、声道、采样率、时长）。

### 变更 / 优化
- 计划：CRC-32 改为查表实现（对外输出与 RFC 3533 逐字节一致，`verify` 更快）。

### 文档 / 工程
- 新增本 CHANGELOG；README 增加「2026-11 更新」与库用法示例。
- 计划：补充测试、示例与 CI 门禁；发布 v0.3.0 到 mooncakes.io 与 GitHub Release。

## [0.2.0] — 2026-10-23

10 月参赛版本（GitHub Release + mooncakes.io 0.2.0，后者于 2026-11-06 发布）。

### 新增
- 页级补丁（`patch`）、时间区间裁剪（`chop`）、多逻辑流与链接流的 CLI 工具。
- `info` / `verify` 的 `--json` 输出；`to-wav` 16/24 位；`dump --hex` 可逆十六进制转储。
- 容器边界加固（截断/损坏/输出别名防护）、manifest 严格校验、退出码 0/1/2 约定。
- 覆盖率非回归门禁、双平台 CI、确定性 fuzz、smoke 端到端（POSIX 42 项 / Windows 40 项）。

### 发布
- GitHub Release `v0.2.0`；mooncakes.io `WangYF0829/moonmux@0.2.0`（build success，可 `moon add` 安装）。

## [0.1.0] — 2026-10-22

首个可用版本：Ogg 容器读写（页/段/包、CRC-32、多逻辑流交织、链接/拆分、结构体检）、
WAV 读写、Ogg（Opus/Vorbis）→ WAV 转码管线、CLI 基础命令与测试基线。
