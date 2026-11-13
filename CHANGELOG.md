# 更新日志

本项目遵循语义化版本；每个版本对应 GitHub Release 与 mooncakes.io 发布。
格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)（`Unreleased` + Added / Changed / Fixed / Deprecated / Removed / Security）。
更早的历史见 `git log` 与 GitHub Releases。
发布流程与回滚预案见 [`RELEASING.md`](RELEASING.md)；逐版本发布记录（含 zip sha256）见 [`docs/releases/`](docs/releases/)。

## [Unreleased]

（暂无）

## [0.9.4] — 2026-11-13

> 验收整改版：Vorbis gate v3（内存 + CPU 双预算）、CLI / 解析边界修复、发布治理与发布记录、CI 11 门禁、D2 覆盖率达标（82.87%）。发布记录见 [docs/releases/v0.9.4.md](docs/releases/v0.9.4.md)。

### Added

- 新增 [`RELEASING.md`](RELEASING.md)：发布前检查单、`moon publish --dry-run` 判定标准（以服务器返回文本为准；已发布版本 409、合成版本 202 但 CLI 非零退出为已知工具链行为）、双人复核的单人项目例外登记与补偿、回滚预案（修复版 + `moon deprecate WangYF0829/moonmux` 预览/演练）与发布后 24h / 7 天监控。
- 新增 [`docs/releases/v0.9.3.md`](docs/releases/v0.9.3.md)：v0.9.3 发布记录（commit / tag / 工具链 / **zip sha256** / CI run / 各 gate 结果 / 可复现性裁决 / deprecate 预览演练）。
- 新增 [`NOTICE`](NOTICE) / [`THIRD_PARTY.md`](THIRD_PARTY.md)：许可声明与第三方依赖清单（`LL728/moonopus` Apache-2.0 + BSD-3-Clause 表数据组件、`LL728/moonvorbis`、`moonbitlang/x`），并登记 `moonbitlang/x` 包内无 LICENSE 文本的上游缺口。
- 新增发布前制品 / 依赖校验与归档脚本：`scripts/check_package.sh`（包清单 / 体积 / worktree / 密钥门禁）、`scripts/check_pii.sh`（PII 扫描）、`scripts/gen_sbom.sh`（SBOM 归档）、`scripts/check_api_diff.sh`（`.mbti` diff 门禁，CI 已调用 `--target-all`）、**`scripts/check_api_docs.sh`**（公开 API 文档注释覆盖门禁，阈值 ≥95% / 未文档 0）、**`scripts/check_coverage.sh`**（库层 / 总覆盖率门限，≥88% / **≥80%**）、**`scripts/preflight_release.sh`**（发布前一键预检：worktree/版本/格式/check/test all/api-diff/api-docs/覆盖率/PII/包内容/SBOM/bench/fuzz/smoke 串跑，支持 `--allow-dirty` / `--skip-*`）、`scripts/bench-baseline.json`（bench 基线）。
- 新增评估 / 证据 / 风险文档：[`docs/releases/v0.9.3-install-sampling.md`](docs/releases/v0.9.3-install-sampling.md)（G1-01 冷装抽样：30/30 = 100%、合计 33/33、中位 1980 ms）、[`docs/dependency-assessment.md`](docs/dependency-assessment.md)（G1-B2 依赖维护性 = DEGRADED、退出预案、工具链 pin 结论）、[`docs/known-issues.md`](docs/known-issues.md)（KI-01..05，含 moonvorbis 上游 issue 草稿）、[`docs/security/pii-advisory.md`](docs/security/pii-advisory.md)（历史 PII 风险接受）。
- **新增 3 个公开 API（`codec` 包）**：`parse_vorbis_setup_info(packet, channels) -> Result[VorbisSetupInfo, String]`（Vorbis setup 完整有界校验，安全路径入口）、`VorbisSetupInfo`（第 2 轮引入、**尚未发布**；第 3/4 轮扩展为 codebooks / floors / residues / mappings / modes / channels / modes_mapping / floor_symbols / residue_type·begin·end·partition_size / **`residue_vq_codewords`** / mappings_submaps·floor·residue·mux / `max_huffman_scan` / `decoder_setup_bytes`，并提供 **`huffman_work_upper`**（第 4 轮由 `huffman_symbols_upper` 重命名，含 VQ 码字数））、`vorbis_block_sizes(id_packet) -> (Int32, Int32)?`（短 / 长块大小，供解码工作量推导）；旧 `validate_vorbis_setup` 签名与语义保留（仅 codebook 段，文档注明非完整安全路径）。
- 新增黑盒测试：`codec` / `manifest` / `mp4` / `ogg` / `pipeline` / `wav` 各新增 `*_public_test.mbt`（`for "test"` 导入，只使用公开 API）。
- CLI 支持 `--help` / `-h` / `--version` 别名（等价 `help` / `version`，均 exit 0），未知选项给出对应子命令用法提示。
- 新增回归测试与契约断言：CLI 契约（无参 / 未知子命令 / 未知选项 / 多余参数 / 别名）、Vorbis gate v3（sparse 位预算 / 交叉引用 / lookup / ordered / 内存分配上界 / Huffman 成本）、Ogg 保留位、MP4 `stsz` 高位、WAV 时长溢出等边界用例；`scripts/smoke.sh` 断言从 54 项扩到 66 项（stdout/stderr 归属、别名、`PIPESTATUS`）。
- CI 门禁增强至 **11 个 job**：新增 `api-diff`（对上一发布 tag 做 `.mbti` diff，破坏性变更 fail）、`examples`（native 实跑三个示例）、`publish-dry-run`（不真实发布，按 409/202 语义判定）；`check` job 增加 `moon check/test --target all --frozen` 与包清单 / worktree 校验；`bench` 接入基线阈值。

### Changed

- README：新增「5 分钟上手」（含 CLI 二进制实际路径 `_build\native\debug\build\cmd\main\main.exe`，与 `moonmux` 命令名的关系）与「支持矩阵」（native / wasm-gc / js；`supported_targets` 为唯一事实源）；「能力边界」补 `to-wav` 不可信输入信任边界（gate v3 + 残余风险）、`to-wav` 内存 / CPU 预算模型、`demux` 输出文件对象 / `split` 段数上限、Windows MAX_PATH / `\\?\` 说明；`PageReader` 重同步描述修正为 `8 × 缓冲长度 + 64 KiB` 确定性预算；退出码表补充判定标准（1 = 数据 / 校验错误；2 = 用法 / 参数引用 / I/O / 能力边界 / 输入形态不支持）；bench 小节改为基线 / 阈值 / 平台守卫 / 小操作噪声下限 / `--batches` 用法；项目结构、脚本清单、链接与许可证小节同步。
- 测试与覆盖率（Windows x64 本地 `moon test --deny-warn --target all`）：native **475/475**、wasm-gc **425/425**、js **425/425**；`wasm` 后端 **0 个测试（未验证）**。**D2 覆盖率缺口已关闭**：工具口径总 **82.87%**（5210/6287，CI 门禁 ≥80%、达标）、库层行覆盖率 **91.79%**（3779/4117，门限 ≥88%）、`coverage analyze` 未覆盖行 **635**（Linux 估算 ~662 < 800）；新增覆盖来自 `cmd/main/main_wbtest.mbt`（+810 行 / +14 用例，**库源码零改动**）。公开 API 文档覆盖 **132/132 = 100%**（门限 ≥95%、未文档 0）。G1-01 冷装抽样 **30/30 = 100%**（合计 33/33，中位 1980 ms，见 `docs/releases/v0.9.3-install-sampling.md`）。
- CHANGELOG 改为 Keep a Changelog 结构（`Unreleased` + 六类）；**已发布条目保持原样**。
- `docs/architecture.md`：版本行、gate v3 不变量（内存分配上界 / CPU 双预算：IMDCT + Huffman / dims 语义裁决）、能力上限、公开 API、测试 / 覆盖率数字、退出码、发布记录 / 流程同步。
- `.moonignore` / `.gitignore` 对齐：补充 `_*.ogg` / `_*.wav` / `_*.bin`、`target/`、`*.wasm` / `*.exe` / `*.dll` 等制品排除。
- CI：依赖冻结（`--frozen`）、工具链版本记录、`check_version.sh` 扩至 11 项、bench 基线与阈值（含平台守卫 / 噪声下限）接入；`check` job 新增 **API 文档覆盖门禁** `check_api_docs.sh`（132/132 = 100%，≥95%、未文档 0），`coverage` job 新增 **库层/总覆盖率门限** `check_coverage.sh`（91.79% ≥88% / **82.87% ≥80%**，总覆盖阈值由 75 提升到 **80**，actionlint 0 error/0 warning）；`api-diff` job 调用 `check_api_diff.sh --target-all`（校验 native/wasm/wasm-gc/js 各后端接口一致）。
- **bench 门禁稳健化**：`bench.mjs` 增加 `--batches` 多批次采样与**小操作噪声下限 4 ms**（基线 < 50 ms 时允许 `max(比例阈值, 4 ms)`）；基线改为多轮 min 的上界（每项 30 样本）；`demux` 因 I/O 抖动（同机 6 次 66.2–84.6 ms）取上界 **80.0 ms** 并写入 `threshold_policy` / `notes`；`--runs 5 --batches 2` 复测 6/6 PASS。
- `moon.mod` 增加 `supported_targets = [ "native", "wasm-gc", "js" ]`（与本地 `--target all` 实测一致）。

### Fixed

- **第 1 轮（CLI / 解析边界）**：F-PAR-01 Vorbis setup gate 升级为全 codebook 有界校验（详见 Security）；F-PAR-02 `dims` / `entries` 的 `+1` 语义修正并交叉断言；F-PAR-03 `demux` 写盘前按 `页数 × 255` 粗估包数，超 `MAX_DEMUX_PACKETS`（999999）立即拒绝（exit 2）；F-PAR-04 WAV `info` 百分秒 / 时长 Int64 化；F-PAR-05 Ogg 保留头类型位（0xF8）在 `parse` / `verify` / 重同步统一校验；F-PAR-06 MP4 `inspect` 拒绝 `stsz` sample_count 高位（0x7FFFFFFF）；F-PAR-08 `total_bits` 位预算改 Int64。
- **第 2 轮（红队 RT-A 8 项）**：**RT-A-01** sparse 码长表位预算按解码器真实读取量逐条核算（消除最坏 6 倍越界窗口）；**RT-A-02** floor / residue / mapping / mode 段的跨段交叉引用与声道 / 时间下标全部上界校验；**RT-A-03** lookup type 1 维度 1..16 与 type 2 元素数上限（消除除零 / 溢出）；**RT-A-04** 内存上界改为按逐包 mode / block_size 推导，不信任页 granule；**RT-A-05** 新增 CPU 工作量预算（IMDCT O(n²) 放大拒绝）；**RT-A-06** `split` 输出段数上限 `MAX_SPLIT_PARTS=999999`（超限 exit 2、不建输出目录）；**RT-A-07** ordered codebook 游程扫完后继续校验后续字段（不再提前 Ok）；**RT-A-08** `demux` 上限统计口径改为文件对象数（包数 + 2 × 流数 ≤ 999999）。
- **第 3 轮（红队 RT3 预算模型）**：**RT3-01** `lookup_type=1` 展开内存未计入内存预算 —— codec 增加 `VorbisCodebook::alloc_bytes` 按 moonvorbis 真实分配上界（type0/1/2 + Huffman 表 + 码长数组）统计 `decoder_setup_bytes`，pipeline 内存预算使用（4cb/8cb PoC 由 exit 0 + 峰值 331.6/674.1 MiB 变为 exit 1）；**RT3-02** CPU 预算只算 IMDCT 漏掉 Huffman 线性查表 —— 新增 `max_huffman_scan`（最长码长 × 有效码字数）与 `VorbisSetupInfo::huffman_symbols_upper`（**第 4 轮已重命名为 `huffman_work_upper` 并改双预算，见下条**），CPU 工作量 = IMDCT + Huffman 扫描（1p/2p/4p PoC 由 4.9/7.5/26.8 s 变为 exit 1、≤52 ms）；**RT3-03** 系数收紧：`MAX_VORBIS_WORK_PER_INPUT_BYTE` 120,000 → **65,000**、`VORBIS_WORK_FLOOR` 32M → **8M**（**第 4 轮重标定为双预算 34,000 / 650,000**；426 B PoC 由 7.3 s 变为 exit 1、47 ms，真实样本仍放行）；**RT3-04** `dimensions` 语义裁决：线格式为 raw 值（无 +1，与 libvorbis / moonvorbis 一致），标量书（classbook / floor1 master/subclass）dims=0 合法、VQ 书（floor0 / residue book）dims=0 仍 fail-closed 拒绝。
- **第 4 轮（红队 RT4-01 / CPU 双预算重标定）**：**RT4-01** Huffman 符号数上界漏乘 residue VQ 码字数（每 partition `ceil(partition_size / dimensions)`，旧实现漏 ×128）—— codec 新增 `VorbisSetupInfo.residue_vq_codewords`，`huffman_symbols_upper` 重写并重命名为 **`huffman_work_upper`**（每包符号数上界 × `max_huffman_scan`）；pipeline CPU 预算拆为**双预算（单位不同、分别限额、不相加）**：**IMDCT 34,000 cos/字节**（下限 6M）与 **Huffman 650,000 比较/字节**（下限 32M）。6,511 B PoC 由「放行后 15–25 s 超时（外推 7–8 min CPU）」变为 **exit 1 / 0.87 s**（`Huffman 43,012,587,520 > 4,232,150,000`）；真实样本限额为 IMDCT 263.2M（×1.43）、Huffman 5.032G（×1.49），真实样本仍放行。
- CLI：写失败「回滚」告警仅在确有半成品时输出并调整输出顺序；输入形态不支持 / 能力边界类判定统一归入退出码 2（与数据损坏的 1 区分）；`\\?\` 前缀与 ADS 误判、Windows 长路径（MAX_PATH）错误提示；文件不存在等错误补 errno 语义（不再出现「No error」）；`cat` 的输出尺寸预检前移到备份之前。

### Deprecated

- 无。

### Removed

- 无。

### Security

- **Vorbis gate v3**：pipeline 解码前改用 `@codec.parse_vorbis_setup_info` 做完整有界校验（codebook 段 + floor / residue / mapping / mode 段 + 跨段交叉引用 + lookup 表 + ordered / framing 位，逐段位预算），并按 moonvorbis **真实分配上界**计算内存、按 **IMDCT + Huffman 线性扫表（含 residue VQ 码字数）双预算**计算 CPU。RT3 相关 19 组 PoC 回归仍全部 exit=1、0 崩溃、0 残留；**RT4-01 已修复**：6,511 B PoC 由「放行后 15–25 s 超时（外推 7–8 min CPU）」变为 **exit 1 / 0.87 s**（`Huffman 43,012,587,520 > 4,232,150,000`）。真实 `testdata` to-wav 产物字节数不变（Vorbis 176444 / Opus 576044，Vorbis debug 92.6 s）。
- `to-wav` 残余风险已登记（README 能力边界）：① Huffman 码长表有效性仍由解码器判定；② floor1 `x` 序等语义细节不在 gate 覆盖；③ 内存模型是上界估算；④ **CPU 双预算 debug 上限约 18 ms/字节**（真实样本 92.6 s 已接近硬约束；余量 IMDCT ×1.43 / Huffman ×1.49），高码长 + 多符号的合法流仍可能被误拒；⑤ release/Linux 未实测；⑥ 依赖 `moonvorbis` 的 `unsafe_get` 仍是残余风险 —— `to-wav` 仍不建议直接处理不可信输入。
- CLI 对能力边界输入（`demux` 文件对象 / `split` 段数上限等）在资源分配 / 写盘前拒绝，避免资源放大。
- 发布前 PII / 凭据扫描纳入发布检查单（历史发布包 0.2.0–0.9.1 的 PII 风险按 [`docs/security/pii-advisory.md`](docs/security/pii-advisory.md) 与 [`docs/known-issues.md`](docs/known-issues.md) KI-03 记录为已接受风险）。

## [0.9.3] — 2026-11-12

### 仓库整理（无行为变更）
- 源码注释与文档中仅供内部使用的语料目录/编号引用改为中性描述（测试断言与行为不变）。
- `.moonignore` / `.gitignore` 去掉内部目录名，保留通用临时产物规则；
  `moon package --list` 发布门禁由黑名单改为**白名单**（只允许源码/文档/测试数据路径进包），
  比黑名单更严格且不依赖本地目录命名。
- 重新生成发布包；与 0.9.2 行为一致。

### 验证
- Windows native **369/369**、wasm-gc **344/344**、覆盖率未覆盖行 **757**（CI 上限 800）；
  smoke、MP4 ffprobe 对账、干净工程安装检查与 CI 全部复跑通过。

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
- **发布/CI**：`.moonignore` 排除 `out/`、`tmp/`、`*.zip`、`*.bak`；CI 增加
  `moon package --list` 白名单门禁（只允许仓库内的源码/文档/测试数据进包），覆盖率阈值 730→780
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




