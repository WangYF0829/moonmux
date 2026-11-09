# 更新日志

本项目遵循语义化版本；每个版本对应 GitHub Release 与 mooncakes.io 发布。
更早的历史见 `git log` 与 GitHub Releases。

## [0.6.0] — 2026-11-09

### 新增
- **性能基准 `scripts/bench.mjs`**（Node，无第三方依赖）：在 release native CLI 上测
  `verify` / `info` / `dump` / `remux` / `to-ogg` / `demux` 的端到端耗时；自动把真实
  Opus 样本复制成 16 条 serial 递增的链接流（≈1.0 MiB）作为大输入，多次运行取最小值。
  CI 新增 `bench · native` job，表格写入 job summary（只记录、不设阈值）。
- **确定性变异测试 `scripts/fuzz.mjs`**：真实 Ogg Opus / Vorbis / MP4 / WAV 种子 ×
  6 类变异（翻位、块覆盖、截断、插入、删除、整段复制），只读/单文件命令为靶；
  断言退出码只能是 0/1/2、无超时/崩溃；固定随机种子可复现。CI 新增 `fuzz · mutation`
  job 跑 400 次迭代。

### 说明
- 仅脚本与 CI 增量，**无库 API / 文件格式变更**；测试仍 288 项。
- README 增加「性能基准」「变异测试」章节与本机实测数据；架构文档补充测试策略。

## [0.5.0] — 2026-11-09

### 新增
- **MP4 → Ogg 解封装**（`mp4.demux_mp4_opus`，`remux` 的逆操作）：
  - 解析 `stsd` 样本条目与 `dOps` 配置（版本/声道/pre-skip/输入采样率/增益/映射族）、
    `stts` 样本时长、`stsc` chunk 映射、`stsz` 样本大小、`stco`（含 `co64`）chunk 偏移；
  - 按 chunk 切出 Opus 包，重建 OpusHead（字段来自 dOps），OpusTags 输出最小
    vendor（"moonmux"）+ 0 条注释；granule = pre-skip + 累计样本时长；
  - 只支持单音轨、Opus、`mdhd` timescale = 48000 的 MP4；坏表/越界/缺 box 全部返回错误。
- **`to-ogg` 子命令**：MP4（Opus-in-MP4）→ Ogg Opus；用法/退出码与其它写命令一致，
  写后回读自检（页可解析、首包为 OpusHead、至少 3 个包）。

### 测试与验证
- 测试 279 → **288**：demux 闭环（音频包/OpusHead 逐字节还原、二次 remux）、
  坏表防御（缺 moov/mdat/track、stts/stsc/stsz/stco/dOps 各分支）、CLI 解析、
  `run_to_ogg` 文件 I/O。
- `scripts/smoke.sh` 新增 4e 段：真实样本 Ogg→MP4→Ogg，回读 Ogg verify 通过、
  首个音频包逐字节比对、非 MP4 输入拒绝。
- `scripts/verify_mp4.sh` 新增第 6 段反向闭环：verify、时长一致性、ffmpeg 解码。

## [0.4.0] — 2026-11-09

### 新增
- **WAV 全格式兼容**（参照 Rust `hound` 的语义独立实现）：
  - 解析 `fmt ` 标签 1（PCM）/ 3（IEEE float）/ 0xFFFE（WAVE_FORMAT_EXTENSIBLE），
    Extensible 的 SubFormat GUID 按 16 字节全量比较；支持 float 32/64、
    `validBits` 与容器位深分离（24-in-4 容器）、未知块（LIST/fact 等）跳过与奇数填充。
  - `WavFile` 新增 `sample_format : SampleFormat` 与 `bytes_per_sample` 字段；
    新增 `encode_wav_ex`（IEEE float / Extensible 编码）。`encode_wav` 输出逐字节不变。
- **增量流式页读取**（参照 libogg / RustAudio `ogg` 的语义独立实现）：
  - `ogg.PageReader`：分块喂入、按需取页、CRC 失步重同步、前缀垃圾与截断区间定位；
  - `ogg.for_each_page_chunked` 便捷函数；任意分块结果与一次性 `parse_pages` 逐字节等价。
- `info` 输出 WAV 的采样格式与容器位深（文本 + `--json` 的 `sample_format` / `container_bits`）。

### 测试与质量
- 测试 259 → **279**（WAV 25 项、流式读取 8 项、info 渲染补充）；覆盖率未覆盖行 644（CI 门禁 675）。
- 参考实现与取舍写入 README「参考实现与取舍」与 `docs/architecture.md`。

## [0.3.2] — 2026-11-07

### 测试
- 测试 252 → 259：为覆盖率门禁补充 MP4/remux 的 I/O 层测试
  （mp4 错误分支、`run_remux` 完整路径、info 的 Ogg/WAV/MP4 渲染与 JSON）。
- 版本号（`moon.mod` / `describe()`）同步到 0.3.2。

## [0.3.1] — 2026-11-07

### 修复
- `moonmux version` / 根包 `describe()` 的版本号从 0.2.0 修正为与 `moon.mod` 一致
  （0.3.0 发布包中该字符串漏更新）。无 API / 格式变更。

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
