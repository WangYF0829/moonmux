# 更新日志

本项目遵循语义化版本；每个版本对应 GitHub Release 与 mooncakes.io 发布。
更早的历史见 `git log` 与 GitHub Releases。

## [0.3.0] — 2026-11-07

2026 年 11 月按「已有项目维护」方向持续开发：补齐 MP4 写入能力与工程化。

### 新增
- `mp4/` 包 —— MP4 / ISOBMFF 写入（Opus-in-MP4）：ISOBMFF box 层、
  `ftyp` / `moov` / `mdat`、`stbl` 五表、`dOps`；最小读侧 `inspect` / `is_mp4`
  供 `info` 与 remux 自检（写—读对称）。
- `remux` 命令 —— Ogg（Opus）→ `.m4a`；不做转码，Opus 数据包原样搬运。
- `info` 识别 MP4 —— 编码、声道、采样率、时长、样本数（文本与 `--json`）。
- `codec`：Opus 包 TOC 帧时长计算（RFC 6716），用于生成 stts / mdhd。

### 变更 / 优化
- CRC-32 改为 8 位查表实现：对外输出与 RFC 3533 逐位结果逐字节一致
  （crc_wbtest 交叉校验 0..511 字节 + 真实 Ogg 文件断言），`verify` 大文件更快。

### 测试
- 237 → 252：box 大小/四码、合成 Ogg→MP4 往返、MP4 布局、CLI 解析、CRC 交叉校验。

### 文档 / 工程
- 新增 CHANGELOG；README 增加「2026-11 更新」与库用法示例；申报书更新为 11 月版。
- 新增 `examples/`（WAV 往返 / Ogg 信息 / Ogg→MP4 三个可运行示例）与
  `docs/architecture.md`（模块边界、关键不变量、测试策略）。
- 新增 `scripts/verify_mp4.sh`（ffprobe / ffmpeg 外部对账）与
  `scripts/install_check.sh`（干净工程 `moon add` 复验，回应 10 月终审反馈）。
- 发布 v0.3.0 到 mooncakes.io 与 GitHub Release。

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
