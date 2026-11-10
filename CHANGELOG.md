# 更新日志

本项目遵循语义化版本；每个版本对应 GitHub Release 与 mooncakes.io 发布。
更早的历史见 `git log` 与 GitHub Releases。

## [0.9.2] — 2026-11-11

### 安全 / 资源边界修复
- **MP4 解封装**：`stts` 样本数改用 Int64 累加、逐游程与 `stsz` 比较，先校验后展开；
  `stsz` 定长分支以 mdat 实际负载为界、逐样本分支先做 Σsizes 与输出大小预估再物化；
  `co64` 偏移按 Int64 校验（≥2³¹ 或不在 mdat 内即拒绝）；新增 1,048,576 样本上限；
  `inspect` 拒绝缺 `mvhd` 与 `stsz` 计数高位为 1 的输入；remux 的 `total_samples`
  用 Int64 累加并在超过 32 位时长时返回错误。
- **Ogg 重同步**：新增零拷贝页 CRC（`crc32_page_range`）与页长计算，候选命中 CRC 后才
  物化 `Page`；`parse_pages_lenient`/`PageReader` 加确定性候选预算（超限报“疑似伪页头
  洪水”），并把保留位页的接受判据对齐严格解析；候选边界全部改为减法/Int64，修掉
  接近 2³¹ 时的回绕窗口。
- **to-wav 解码边界**：解码前统一 gate（OpusHead/OpusTags、Vorbis ID/comment 用本项目
  解析器校验，Vorbis setup 首 codebook 做有界位预算检查）；PCM 预算改为按解码工作量
  估算（Opus 逐包 TOC 时长，不信任页 granule），估算与解码共用同一选流结果；OpusHead
  version≠1、TOC 不可解析、Vorbis granule 异常时在解码前返回错误。两个已知恶意头
  PoC 现在返回数据错误而不是崩溃。
- **写路径安全**：`extract --force` 收紧为只允许幂等覆盖（已有输出与待写内容相同，或
  待写内容等于整个输入文件），拒绝覆盖不同内容/硬链接别名；`demux` 先写 manifest 再写
  包文件，中断残留目录会被 `mux` 的包数校验拒绝。
- **CLI/契约**：`verify --json` 的“不是合法 Ogg”输出 JSON 错误对象；`info` 文本输出的
  MP4 brand/codec 与 WAV chunk id 做控制字符转义；非选项类子命令遇到 `--xxx` 按未知
  选项退出 2；manifest 未知头部字段报错；手工包目录按数字序排序（packet_2 在 packet_10 前）。
- **发布/CI**：`.moonignore` 排除 `review/`、`out/`、`tmp/`、`*.zip`、`*.bak`；CI 增加
  `moon package --list` 内容门禁（禁止评审/构建/临时目录进包），覆盖率阈值 730→780
  （容差 20，上限 800）；fuzz 增加 stderr panic 检测；修复 smoke 在 Windows Git Bash
  下使用 `/tmp` 导致原生 `@fs` 无法建目录的回归（优先进 `_build/smoke.*`）。
- **隐私**：项目申报书移除个人手机号/邮箱，改为仓库 Issue 联系方式。

### 测试
- Windows native **369/369**、wasm-gc **344/344**、`moon check --deny-warn` 零警告；
  覆盖率未覆盖行 **757**（Linux 侧约 784，CI 上限 800）。

### 已知残余
- `moonvorbis@0.1.4` 的 `unsafe_get` / 缺 bit-budget 是依赖层问题，gate 仅覆盖已识别的
  畸形头；任意恶意 Vorbis 码流仍可能让 `to-wav` 崩溃，不可把 `to-wav` 直接暴露给
  不可信输入。Opus 音频 payload 也只校验 TOC，不校验码流内容。
- MP4 解封装样本数上限 1,048,576（约 5.8 小时 @20 ms 包）为新增能力边界。
- `@fs` 无 stat/inode/rename：备份/别名检查的整体读入内存与中断窗口仍无法彻底消除。

## [0.9.1] — 2026-11-10

### 修复
- `mux` 的 `manifest.txt` 是目录/管道/设备时按 I/O 错误退出 **2**（与文档和 smoke 的
  约定一致；0.9.0 误归为数据错误 1）。
- `looks_like_packet_member` 的平台测试修正：POSIX 文件名大小写敏感，大写 8.3 短名
  只在 Windows 上应被识别（单独 `cfg(platform="windows")` 测试覆盖）。

### 测试
- Windows native **336** 个测试通过（Linux 335，差异来自 Windows 专属测试）。

## [0.9.0] — 2026-11-10

### v0.9.0 修复 / 补齐
- **MP4 写侧**：补 `edts/elst`（按 pre-skip 裁剪播放时间轴）与 `roll` 样本组；
  末包粒度不推进时按 Ogg end-trim 裁掉多余样本；`mvhd/tkhd` 用裁剪后时长，
  `mdhd` 保留媒体总样本数。
- **MP4 读侧**：支持 64 位 `largesize` 并做边界检查；v1 时长字段钳到 Int32 上限；
  多条音频轨显式拒绝（不再静默取第一条）。
- **WAV**：浮点 WAV 写 `fact` 块（样本帧数）；解析拒绝重复 `fmt `/`data` 块。
- **Ogg**：重同步候选加 version/头类型预筛、跳过伪页头并合并相邻 gap；
  新增 `validate_page` / `serialize_pages_checked`，CLI 所有写命令改用校验入口；
  `verify_page` 修正为「CRC 字段清零后再算」。
- **CLI 契约**：错误/用法信息走 stderr（stdout 只留成功结果，`--json` 失败输出
  `{"error":...}`）；`info` 增加 `parsed_bytes`/`truncated`；`dump --hex` 对损坏文件
  仍输出整文件 hex；`extract --force` 允许幂等覆盖内容相同的输出；`--json`/`--hex`
  可出现在路径前后；无参调用与用法错误统一退出 2；`tags` 对控制字符做 `\xNN` 转义；
  `plan_mux` 用类型化错误分流（不再按中文文案猜退出码）；`chop` 的结构性限制预检。
- **资源/边界**：聚合写命令（cat/mux/split/extract/tag/chop/remux/demux/to-wav）
  在分配前做 2 GiB Int64 估算；`MOONMUX_MAX_PCM_MB` 非法值显式报错、上限改为 2048；
  restore/commit/备份删除失败不再静默；`looks_like_packet_member` 收紧 8.3 短名。
- **POSIX**：反斜杠不再当分隔符、`C:foo` 不再被误当作绝对路径。
- **manifest**：拒绝重复 `serial/packets/chain` 头字段。
- **CI/工程**：checkout 固定到 v4.2.2 SHA、每个 job 记录工具链版本（官方安装脚本对旧版本 URL 返回 403，暂无法 pin）；文档-only 推送跳过 CI；
  `install` job 轮询等待 mooncakes 发布；新增 Windows smoke job 与版本一致性断言脚本；
  install_check 去掉 Python 依赖、smoke/安装脚本 `mktemp` 可移植；bench/fuzz 使用
  唯一临时目录、区分启动失败与超时、fuzz 覆盖 remux。

### 测试
- 测试 **315 → 335**（Windows；0.9.1 增加平台专属测试后为 336）；覆盖率未覆盖行 **710**（Windows 实测；Linux ≈737，CI 门禁上限
  730+20=750）。
- 新增：MP4 edit list/roll/end-trim、largesize/duration、多音轨拒绝、WAV fact/重复块、
  manifest 重复头、页校验、伪 `OggS` 洪泛、CLI 标志位置/版本一致性等回归。

## [0.8.0] — 2026-11-10

### 修复（正确性问题）
- **Opus TOC**：SILK 60 ms 帧长 3840 → 2880；code-3 帧数改读 `data[1] >> 2`；
  补 M ≤ 48 与包总时长 ≤ 120 ms 校验。
- **`remux` 输入闸门**：CLI 先做 CRC / 结构 / EOS 检查；库层拒绝链式与多逻辑流输入
  （不再静默只取第一段）；stts 时长不再因 TOC 错误偏大。
- **MP4 读侧防崩溃**：box 字段读取先按 `next - body` 校验长度，截断文件返回
  `None`/`Err` 而不是越界 panic；mvhd/mdhd version 1 按 64 位字段解析。
- **`stsz` 与样本偏移**：定长样本数与样本偏移用文件大小做上界；`pos + size` 改用
  Int64 计算，修复溢出后 0 字节音频包「假成功」。
- **多声道 OpusHead**：dOps / OpusHead 保留 `StreamCount` / `CoupledCount`，
  family≠0 输出 21+C 字节，5.1/7.1 流往返后头部合法。
- **granule 语义**：MP4 → Ogg 写累计样本数（RFC 7845 §4，PCM = granule − pre-skip）。
- **dOps OutputGain**：从 OpusHead 透传 Q7.8 增益，带 gain 的流往返不再归零。
- **头包页隔离**：`paginate_sized` 不再把 OpusTags / Vorbis 头包与音频包合并
  （RFC 7845 §3 / Vorbis I A.2）。
- **`replace_packet` 跨页**：修正向前回溯条件，带大封面/超长 OpusTags 的跨页包可正确替换。
- **WAV fmt 布局保真**：`WavFile::to_bytes` 保存并原样写回原始 fmt 负载（16 / 18 / 40 字节），
  tag1+24bit、tag3+16 字节、Extensible 小声道数不再被改写，channelMask 不再丢失。
- **manifest / mux**：拒绝空清单、granule < -1 与非单调清单；`mux` 落盘前在内存里
  回读校验页数 / CRC / 结构，通过才写。
- **工程加固**：LICENSE 去掉 Apache HTTP Server 子组件声明；`.moonignore` 排除 `_*/`
  与开发脚本；CI bench 步骤启用 `pipefail`；`verify_mp4.sh` 在 CI 强制要求
  ffmpeg/ffprobe；smoke 断言数文案修正；补全 bash 补全与 `moon.mod` 描述。

### 测试
- 测试 **299 → 315**；覆盖率未覆盖行 **683**（CI 门禁 715）。
- 新增回归：Opus TOC 全配置（含 SILK 60 ms / code-3 上限）、32 字节截断 MP4、
  stsz 定长样本上界、样本偏移溢出、family=1 六声道 OpusHead、跨页包替换、
  头包页隔离、WAV 原始 fmt 布局回退、manifest 空/坏清单等。

## [0.7.1] — 2026-11-09

### 文档
- `项目申报书.md` 重写为工程说明：项目定位、工作内容（按模块）、技术方案与关键设计、
  工程质量与验证、能力边界、开源合规与参考来源、使用方式、发布与开发记录。
- README 与 CHANGELOG 去除历史项目背景相关表述，改为中性的版本历程与能力清单；
  测试数与版本引用同步更新（299 项测试、v0.7.1）。
- 本版为文档同步发布：**无代码、API 或文件格式变更**；测试仍 299 项，覆盖率 682。

## [0.7.0] — 2026-11-09

### 新增
- **WAV 块保真**：`WavFile` 新增 `chunks : Array[WavChunk]`（fourcc / data / after_data）
  与 `channel_mask`；解析时保留 `fmt `/`data` 之外的全部块（LIST / fact / junk …，
  含奇数长度块的填充），`WavFile::to_bytes()` 按原顺序、原容器宽度（24-in-4）与
  原 channelMask **逐字节还原**。
- **流式写接口 `WavWriter`**：`write` 增量追加 PCM，`add_chunk` / `add_trailing_chunk`
  插入扩展块，`finish` 生成 WAV；简单布局（Int/≤2 声道/≤16 位）与 Extensible 布局的
  输出都与 `encode_wav_ex` 逐字节一致。
- `info` 输出扩展块列表（文本 + `--json` 的 `chunks` 数组：fourcc / bytes / after_data）。

### 测试与质量
- 测试 288 → **299**：块保真逐字节往返、24-in-4 + channelMask 往返、WavWriter 与
  encode_wav_ex 等价、扩展块前后位置、以及 fmt 太短 / cbSize / validBits / 参数校验等
  错误分支；覆盖率未覆盖行 682（CI 门禁 715）。
- README 增加块保真与流式写说明；架构文档补充 WAV 不变量；文档同步。

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

v0.3.0 起补齐 MP4 写入能力与工程化。

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
- 新增 CHANGELOG；README 增加版本更新与库用法示例；相关文档同步更新。
- 新增 `examples/`（WAV 往返 / Ogg 信息 / Ogg→MP4 三个可运行示例）与
  `docs/architecture.md`（模块边界、关键不变量、测试策略）。
- 新增 `scripts/verify_mp4.sh`（ffprobe / ffmpeg 外部对账）与
  `scripts/install_check.sh`（干净工程 `moon add` 验证）。
- 发布 v0.3.0 到 mooncakes.io 与 GitHub Release。

## [0.2.0] — 2026-10-23

v0.2.0（GitHub Release；mooncakes.io 0.2.0 于 2026-11-06 发布）。

### 新增
- 页级补丁（`patch`）、时间区间裁剪（`chop`）、多逻辑流与链接流的 CLI 工具。
- `info` / `verify` 的 `--json` 输出；`to-wav` 16/24 位；`dump --hex` 可逆十六进制转储。
- 容器边界加固（截断/损坏/输出别名防护）、manifest 严格校验、退出码 0/1/2 约定。
- 覆盖率非回归门禁、双平台 CI、确定性 fuzz、smoke 端到端（POSIX 54 项）。

### 发布
- GitHub Release `v0.2.0`；mooncakes.io `WangYF0829/moonmux@0.2.0`（build success，可 `moon add` 安装）。

## [0.1.0] — 2026-10-22

首个可用版本：Ogg 容器读写（页/段/包、CRC-32、多逻辑流交织、链接/拆分、结构体检）、
WAV 读写、Ogg（Opus/Vorbis）→ WAV 转码管线、CLI 基础命令与测试基础。
