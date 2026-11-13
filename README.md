> 作者：WangYF0829（王轶凡）｜创建日期：2026-10-13｜用途：moonmux 项目文档

# moonmux

[![CI](https://github.com/WangYF0829/moonmux/actions/workflows/ci.yml/badge.svg)](https://github.com/WangYF0829/moonmux/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-475%20passing-brightgreen.svg)](#构建与测试)
[![Version](https://img.shields.io/badge/version-0.9.4-blue.svg)](https://github.com/WangYF0829/moonmux/releases)
[![mooncakes](https://img.shields.io/badge/mooncakes-0.9.4-blueviolet)](https://mooncakes.io/docs/WangYF0829/moonmux)

纯 MoonBit 实现的音频容器工具包，补上 MoonBit 生态中「能解码、不能封装」的最后一环。

## 2026-11 更新（v0.9.4）

项目当前版本 **v0.9.4**（2026-11-13，验收整改版：Vorbis gate v3、CI 11 门禁、D2 覆盖率 82.87%、发布治理与安装证据）。主要能力与发布里程碑：

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
| **正确性/契约修复（v0.9.0）**：MP4 写侧补 `edts/elst` + `roll` 样本组与 end-trim、WAV 浮点 `fact` 块与重复块拒绝、Ogg 头包预筛重同步 + 页校验序列化、CLI 诊断走 stderr / JSON 错误对象 / `--hex` 宽容 / 提取 `--force` / 选项任意位置 / tags 控制字符转义、2 GiB 聚合闸门、PCM 预算显式校验、POSIX 路径与 8.3 短名、manifest 重复头拒绝 | **已完成（v0.9.0）** |
| **补丁（v0.9.1）**：`mux` 的 `manifest.txt` 为目录/管道/设备时按 I/O 错误退出 2；平台专属 8.3 短名测试 | **已完成（v0.9.1）** |
| **安全/资源边界修复（v0.9.2）**：MP4 stts/stsz 先校验后分配（C-01/H-02）、co64 64 位偏移校验、inspect 缺 mvhd/stsz 高位拒绝；Ogg 重同步零拷贝 CRC + 确定性预算（H-01）；解码前统一 gate + 按解码工作量估算 PCM 预算（H-03/H-04）；extract --force 收紧（H-05）；demux 清单先行（H-06）；发布包内容门禁（H-07） | **已完成（v0.9.2）** |
| **仓库整理（v0.9.3）**：源码注释与文档中的内部语料路径改为中性描述；发布包门禁改白名单；无行为变更 | **已完成（v0.9.3）** |
| **验收整改（v0.9.4）**：Vorbis gate v3（内存 + CPU 双预算）、CLI/解析边界修复、CI 11 门禁、D2 覆盖率 82.87%、发布治理（RELEASING/发布记录/NOTICE/SBOM/PII） | **已完成（v0.9.4）** |
| 测试 / 示例 / 文档 / CHANGELOG / **v0.9.4 发布（mooncakes + GitHub Release）** | **已完成** |

- **已可用（最新发布 v0.9.4）**：`moon add WangYF0829/moonmux` 安装 **v0.9.4**（2026-11-13 验收整改版：安全 gate v3、CI 门禁、覆盖率 82.87%；v0.9.2 为安全/资源边界修复：MP4 表校验先于分配、Ogg 重同步预算、解码前 gate 与工作量预算、`extract --force` 收紧、demux 清单提交点、发布包门禁等；此前 v0.9.0 补 MP4 编辑列表与 `roll`、WAV `fact`、页校验、CLI 契约、2 GiB 闸门；v0.8.0 修复 TOC/remux 闸门/MP4 读侧，v0.7.x 提供 WAV 块保真与 `WavWriter`，v0.6.0 性能基准与变异测试，v0.5.0 `to-ogg` 解封装，v0.4.0 WAV 全格式与流式页读取）。
- 变更明细见 [CHANGELOG.md](CHANGELOG.md)。

## 5 分钟上手

在干净 MoonBit 工程里跑通第一个调用（Windows / Linux 均验证过；native 后端需要 C 工具链）：

```sh
moon new --user <your-user> --name <your-name> myproj   # 已有工程可跳过
cd myproj
moon add WangYF0829/moonmux@0.9.4
```

在 `cmd/main/moon.pkg` 中加入 import（下面的示例只用容器层，不引入解码器）：

```text
import {
  "WangYF0829/moonmux/ogg",
  "WangYF0829/moonmux/wav",
}
```

把 `cmd/main/main.mbt` 换成下文「作为库使用」里的最小示例，然后运行：

```sh
moon check
moon run --target native cmd/main
# 输出：
# wav ok: 8000
# ogg page: true
```

> **关于 `moonmux` 命令**：从库安装**不会**安装 `moonmux` 可执行文件。CLI 需要在本仓库构建：
> `moon build --target native`，产物位于 `_build\native\debug\build\cmd\main\main.exe`
> （Linux / macOS：`_build/native/debug/build/cmd/main/main`）。README 下文用 `moonmux` 代指该可执行文件；
> 需要 PATH 上的 `moonmux` 时自行复制 / 重命名（`scripts/moonmux.bash` 的补全同时注册了 `moonmux` / `main` / `main.exe`）。

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
| `codec/` | 编解码头解析（OpusHead / Vorbis ID）、时长换算、VorbisComment / OpusTags 读写；**Vorbis setup 完整有界校验（gate v3：codebook/floor/residue/mapping/mode + 交叉引用 + lookup + 内存/Huffman·IMDCT 双预算成本模型）**与块大小推导（`parse_vorbis_setup_info` / `VorbisSetupInfo` / `vorbis_block_sizes`） | 已完成 |
| `manifest/` | `demux`/`mux` 的流目录清单（流号、包数、链序号、逐包粒度）的解析与生成 | 已完成 |
| `wav/` | WAV（RIFF）读写：PCM 8/16/24/32、IEEE float 32/64、`WAVE_FORMAT_EXTENSIBLE`、24-in-4 容器读取；整数 PCM 编码与 `encode_wav_ex`（float/Extensible）；**v0.7.0 块保真（LIST/fact 扩展块、channelMask）+ `WavFile::to_bytes` + `WavWriter`** | 已完成（v0.4.0 全格式 / v0.7.0 块保真） |
| `pipeline/` | Ogg（Opus / Vorbis）→ WAV 转码管线 | 已完成 |
| `mp4/` | MP4/ISOBMFF：写侧 `ftyp`/`moov`/`mdat`/`stbl` 五表/`dOps`（Opus-in-MP4，v0.3.x）；读侧 `inspect` + **`demux_mp4_opus` 解封装回 Ogg**（v0.5.0，读写闭环） | **已完成（v0.3.x 写 / v0.5.0 读）** |
| `cmd/main/` | 命令行工具：`info`、`demux`、`mux`、`cat`、`split`、`extract`、`dump`、`tags`、`tag`、`seek`、`verify`、`to-wav`、`chop`、`remux`、`to-ogg` | 已完成 |

**容器层（`ogg/`、`wav/`）不依赖任何三方包**：容器格式的正确性应当能被独立验证，不该被解码器的缺陷掩盖。解码环节留给生态中已有的纯 MoonBit 解码器（`LL728/moonopus`、`LL728/moonvorbis`），通过 `pipeline/` 对接 —— 三方依赖被隔离在这一层，不在容器层。

## 作为库使用

模块已按 mooncakes.io 规范命名（`WangYF0829/moonmux`）并发布 **0.9.4**（2026-11-13；0.2.0 于 2026-11-06 首发）：

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

v0.4.0 新增库 API：`@ogg.PageReader` / `@ogg.for_each_page_chunked`（增量流式读取）、`@wav.SampleFormat` / `@wav.encode_wav_ex`（IEEE float 与 Extensible 编码）；v0.5.0 新增 `@mp4.demux_mp4_opus`（MP4 → Ogg）；v0.7.0 新增 `@wav.WavChunk` / `@wav.WavFile::to_bytes`（块保真）与 `@wav.WavWriter`（增量写）。安全整改轮新增 setup 完整校验 API：`@codec.parse_vorbis_setup_info`（完整有界校验，返回 `@codec.VorbisSetupInfo`）与 `@codec.vorbis_block_sizes`（从识别头取短/长块大小，供工作量推导）；旧的 `@codec.validate_vorbis_setup` 仍保留（仅 codebook 段，非完整安全路径）。

容器层（`ogg/`、`wav/`、`codec/`、`manifest/`、`mp4/`）全部是纯函数、零依赖，可以单独复用；
只有 `pipeline/` 会引入解码器。安装可用性已在干净工程实测：`moon add` → `moon check` → `moon run`。

## 退出码约定

| 退出码 | 含义 |
|---|---|
| `0` | 成功 |
| `1` | **数据 / 校验错误**：输入不是合法 Ogg / WAV / MP4、被截断、CRC 或结构体检失败、清单与目录不符、`verify` 报 error 等 |
| `2` | **用法 / 参数引用 / I/O / 能力边界 / 输入形态不支持**：参数错、缺参数、多余参数、未知选项、文件读不到、拒绝覆盖、单文件 2 GiB 上限、`demux` 包数上限、`MOONMUX_MAX_PCM_MB` 非法值、Windows 路径超过 `MAX_PATH`、`remux` 拒绝链式/多流输入等 |

脚本与 CI 可直接据此判断，不必 grep 中文输出。

**判定标准**：数据本身不合法（截断、CRC 失败、清单与目录不符）退出 1；命令用错、I/O 失败或输入形态/规模超出本工具声明的能力边界退出 2。具体到单个命令的判定，以 `moonmux <cmd> --help` 与实际端到端断言（`scripts/smoke.sh`）为准。

**写命令要求输入完整**：每页 CRC 通过、每条逻辑流以 EOS 收尾、尾部最多 1 MiB 全零填充；
缺 EOS 的直播流会被拒绝（本工具面向静态文件）。`verify` 对缺 EOS 只报 warn（退出 0），
写命令则按数据错误处理（退出 1）。
输入与输出路径相同（含大小写别名、`..`、硬链接）会被拒绝；内容与输入完全相同的已有输出也会被拒绝。
`mux` 还会把已有输出与实际读取的每个包/清单做身份比较，拦截目录外任意文件名的硬链接别名。
写命令面向单写者：不要并发写同一个输出文件。

**错误与用法信息统一走 stderr**（stdout 只留成功结果；`--json` 命令失败时输出 `{"error":...}`）。**只读命令对损坏文件保持宽容**：`info` / `dump` / `tags` 在文件有结构问题时尽量给出能读到的信息（`info` / `dump` 会提示「只解析到偏移 X」），退出码仍为 0；**会写产物的命令**（`demux` / `mux` / `cat` / `split` / `extract` / `tag` / `to-wav` / `chop`）在输入有 error 级结构问题、被截断或清单不符时拒绝执行并返回 1 —— 不产出半截文件。端到端检查见 `scripts/smoke.sh`（POSIX 66 项断言，Linux 与 Windows Git Bash 都跑；v0.9.3 基线 54 项，整改轮补充 CLI 契约 / stdout-stderr 归属 / `--help`·`--version` 别名等断言，覆盖往返、退出码、截断、清单异常、FIFO 与输出别名防护）。`verify --json` 的“不是合法 Ogg”也输出 `{"error":...}`；非选项类子命令遇到 `--xxx` 按未知选项退出 2，不会被当成路径。

## 能力边界

| 项 | 上限 | 原因 |
|---|---|---|
| 单文件大小 | **2 GiB** | MoonBit `Int` 是 32 位，页偏移与长度都用它；`@fs` 也只有整文件 API；聚合写命令在分配前显式估算并拒绝越界 |
| MP4 写侧 | 仅 **Opus-in-MP4**、单音轨、单 chunk | 只补 Opus；Vorbis-in-MP4 非主流且需解析 Vorbis setup，明确不做；`remux` 只接受 Ogg Opus 输入 |
| MP4 读侧 | 仅解封装 **Opus-in-MP4**（单音轨、`mdhd` timescale=48000） | `to-ogg` 是 `remux` 的逆操作；注释不随 MP4 保存，输出使用最小 OpusTags |
| `demux` 输出文件对象 | **999999**（`MAX_DEMUX_PACKETS`，口径 = 包数 + 2 × 逻辑流数） | 包文件名固定 6 位且每个流/清单都占文件对象，超过后字典序错乱、`mux` 读回顺序不对。实现：写盘前先按 `页数 × 255` 粗估包数，超过上限立即拒绝（exit 2，且不创建输出目录），避免小输入放大成海量文件；未超限再按段表精算，写入前复核 |
| `split` 段数 | **999999**（`MAX_SPLIT_PARTS`） | 输出是 `partN.ogg` 固定命名，段数超限即拒绝（exit 2，且不建输出目录），避免链式流输入放大成海量文件 |
| `to-wav` 预算 | **256 MiB**（`MOONMUX_MAX_PCM_MB` 可调，1..2048） | 内存预算 = **gate v3 解析出的 `decoder_setup_bytes`（按 moonvorbis 真实分配上界：type0 `entries×8+…`、type1 `entries×(4×dims+8)+…`、type2 `entries×(8×dims+8)+…`，含 Huffman 表与码长数组）+ 逐包 mode/block_size 推导的 PCM/临时缓冲上界**（不信任页 granule）；Opus 按逐包 TOC 时长 × 声道 ×（输出字节 + 8 B/样本缓冲）。CPU 为**双预算（两套单位不同、分别限额、不相加）**：**IMDCT 34,000 cos/字节**（下限 6M）与 **Huffman 650,000 比较/字节**（下限 32M）；Huffman 工作量 = 每包符号数上界（`huffman_work_upper`，含 `residue_vq_codewords` 的 VQ 码字数）× `max_huffman_scan`，IMDCT 工作量 = Σ 声道 × block_size² / 2。默认 256 MiB ≈ 9 分钟 16 位单声道 Opus；进程实际峰值约预算的 1.5–2 倍 |
| `chop` Opus 时间戳 | 页精度，约 ±1 页 | 不重写 OpusHead 的 pre-skip；裁剪后首个数据页可能多带不到一页的前导样本 |
| `to-wav` 速度 | Opus 约 30× 实时（6.02 s 音频 ≈0.2 s）；**Vorbis 1.0 s 音频约需 60–70 s，真实 `testdata` 样本 debug 下 92.6 s** | 纯 MoonBit 解码器的真实性能（O(n²) IMDCT + Huffman 逐 bit 线性扫表）；长文件请先 `split`；release 构建未实测 |
| `to-wav` 不可信输入 | gate v3 已校验 setup 全 codebook / 交叉引用 / lookup / 内存与 **CPU 双预算**，仍建议不直接处理不可信输入 | 解码前 gate（`@codec.parse_vorbis_setup_info`，gate v3）：逐 codebook（sparse 按解码器真实读取量做位预算）、floor/residue/mapping/mode 段与**跨段交叉引用**、lookup1/2 表（含除零/溢出）、ordered 与 framing 位，并产出内存分配上界、Huffman 比较成本上界（含 **residue VQ 码字数** `residue_vq_codewords`）与 IMDCT 成本上界；**RT4-01 PoC（6,511 B、VQ 符号数上界漏乘）现在 exit 1 / 0.87 s**（修复前放行后 15–25 s 超时、外推 7–8 min CPU），RT3 相关 19 组 PoC 回归仍全部 exit=1、0 崩溃、0 残留，真实样本 to-wav 产物字节数不变（Vorbis 176444 / Opus 576044）。**残余风险**：① Huffman 码长表的**有效性**（全 0/超长码语义）仍由解码器判定，gate 只用长度分布做成本预算；② floor1 `x` 序等语义细节不在 gate 覆盖；③ 内存模型是**上界估算**而非精确峰值；④ **CPU 双预算 debug 上限约 18 ms/字节**（真实样本 92.6 s 已接近硬约束；余量：IMDCT 限额 ×1.43、Huffman ×1.49），高码长 + 多符号的合法流仍可能被误拒；⑤ release/Linux 未实测；⑥ 依赖 `LL728/moonvorbis@0.1.4` 内部的 `unsafe_get` 仍是残余风险 —— 因此 `to-wav` 仍不建议直接处理不可信输入。旧 `validate_vorbis_setup` 仅为兼容保留（只验 codebook 段，非完整安全路径），安全路径请用 `parse_vorbis_setup_info` |
| chained 拆分 | 整段都由单页流组成时无法拆分 | 与「一段内交织两条单页流」字节相同，规格上不可判定（保守不切） |
| 裁剪流时长 | 上界 | 容器层拿不到首个音频页的样本数，精确值需解码 |
| MP4 编辑列表 | 已写 `edts/elst`（pre-skip 裁剪）与 `roll` 样本组 | 不做章节/多轨编辑；`mdhd` 保留总样本数，`mvhd/tkhd` 用裁剪后时长 |
| `remux` 输入 | 单段、单逻辑流 Ogg | 链式 / 多流输入按「输入形态不支持」显式拒绝（**exit 2**，统一后的能力边界类退出码），不再静默只取第一段 |
| Windows 路径 | 传统 Win32 API 上限 **260 字符（MAX_PATH）** | 超过时给出可操作错误（缩短路径 / 把工作目录移到更靠近盘根的位置）；`\\?\` 前缀与 ADS（备用数据流）按普通路径语义处理，不会被误判成设备名 |
| `PageReader` 重同步预算 | 每次调用 `8 × 缓冲长度 + 64 KiB` 的 CRC 工作预算 | v0.9.2 起有确定性候选预算：超限即放弃重同步并把剩余缓冲记为跳过区间（报「疑似伪页头洪水」），恶意伪造 `OggS` 不会无限放大 CPU / `gaps`；普通文件不受影响 |
| 写侧公开 API | `serialize_pages_checked` / `validate_page` 可用 | CLI 写命令已全部走校验入口；库用户直接调用 `serialize_pages` 时仍需自行保证 `Page` 合法 |
| WAV 块保真布局 | fmt 在 data 之前、扩展块在 fmt 之后的标准布局 | 原始 fmt 与扩展块逐字节写回；fmt 之前出现未知块或非零填充字节的极端布局会按语义规范化（扩展块保留、采样数据无损） |
| `extract` 幂等重跑 | 需显式 `--force`，且只允许幂等覆盖 | 默认拒绝“输出与输入内容相同”的别名；`--force` 仍要求已有输出与待写内容相同（或待写内容就是整个输入文件），不再允许覆盖不同内容——硬链接/别名截断多流源文件会被拒绝 |
| 覆盖/别名检查的内存 | 无 `stat`/inode API | 覆盖已有输出时把旧文件整体读入内存做内容比较（峰值约旧文件 + 新输出）；不能流式比较或原子替换 |

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

## 支持矩阵

`moon.mod` 声明 `preferred_target = "native"`、`supported_targets = [ "native", "wasm-gc", "js" ]`（以此字段为唯一事实源）。当前实测与 CI 覆盖如下（测试数为 Windows x64 实测，整改后本地完整 `--target all`）：

| target | 本地实测 | CI 覆盖 | 说明 |
|---|---|---|---|
| `native`（preferred） | ✅ 475/475 | ✅ ubuntu `moon test --target all` / `moon test --target native`；windows native CLI 测试；双平台 smoke；bench / mp4 / install 均 native | CLI 与 examples 的主目标；需要 MSVC（Windows）或 C 工具链（Linux / macOS） |
| `wasm-gc` | ✅ 425/425 | ✅ ubuntu `moon test --target all`（declared backends）+ windows `--target wasm-gc` | 纯库路径；两个读取文件示例声明 `supported_targets = "native"`，不参与 |
| `js` | ✅ 425/425（`moon test` / `moon run --target js`） | ✅ ubuntu `moon test --target all`（declared backends） | 纯库路径可用；native-only 的 CLI / 示例项不适用 |

- **`supported_targets`**：`moon.mod` 声明 `native` / `wasm-gc` / `js`（以此字段为唯一事实源；上表与之对齐）。
- `wasm`（legacy）：本地 `--target all` 下 **0 个测试用例（未验证）**，不在 `supported_targets` 中，不应视为已支持。
- **OS**：CI 常规矩阵为 `ubuntu-latest` + `windows-latest`；macOS 未验证。
- **工具链**：CI 跟随 mooncakes 官方 latest（每个 job 记录 `moon version --all`）；v0.9.4 发布验证使用 moon `0.1.20261012` / moonc `0.10.15`（见 [docs/releases/v0.9.4.md](docs/releases/v0.9.4.md)）。工具链固定版本的可行性已评估：installer 支持版本参数，但**固定版本下载 URL 全线 403、latest 200**，故维持「latest + 版本记录」（详见 [docs/dependency-assessment.md](docs/dependency-assessment.md)）。
- `supported_targets` 字段与上表不一致时视为缺陷。

## 质量门禁

CI 的 11 个 job 在每次 push / PR（ubuntu + windows 矩阵）执行下列门禁，详细接线见 [`.github/workflows/ci.yml`](.github/workflows/ci.yml)：

| 门禁 | 命令 / 阈值 | 当前实测 |
|---|---|---|
| 编译 / 格式 / 包信息 | `moon check --deny-warn`（含 `--target all --frozen`）、`moon fmt --check`、`moon info --frozen` | 0 error / 0 warning |
| 测试矩阵 | `moon test --deny-warn --target all` | native **475/475**、wasm-gc **425/425**、js **425/425**（wasm 0 测试） |
| 公开 API 文档覆盖（D6） | `bash scripts/check_api_docs.sh --threshold 95 --max-gap 0`（`check` job，Linux） | **132/132 = 100%**（阈值 ≥95%、未文档符号 0） |
| 覆盖率（D2 已达标） | `moon coverage analyze`（未覆盖行 ≤ 780 + 20）+ `bash scripts/check_coverage.sh --lib-threshold 88 --total-threshold 80`（`coverage` job） | **工具口径总 82.87%**（5210/6287，门禁 ≥80%）、库层行覆盖率 **91.79%**（3779/4117，≥88%）、未覆盖行 **635**（Linux 估算 ~662 < 800） |
| API 兼容性 | `bash scripts/check_api_diff.sh --target-all`（对上一发布 tag 的逐包 `.mbti` diff，并校验 native/wasm/wasm-gc/js 接口一致；0 = 仅新增/白名单，1 = 破坏性） | exit 0（本轮无破坏性变更） |
| 包内容 / 供应链 | `check_package.sh`（清单/体积/worktree/密钥）、`check_pii.sh`（PII）、`gen_sbom.sh`（SBOM 归档） | exit 0 |
| 性能 / 变异 / 端到端 | `bench.mjs --baseline`（阈值 + 4 ms 噪声下限 + 平台守卫）、`fuzz.mjs`（固定种子 400 次）、`smoke.sh`（66 项断言）、Windows smoke、mp4 ffprobe 对账 | 全部通过 |
| 发布前预检（一键） | `bash scripts/preflight_release.sh`（干净 worktree；开发期可 `--allow-dirty`，快速门禁可 `--skip-bench/--skip-fuzz/--skip-smoke`） | 发布演练用；输出 PASS/FAIL 汇总，exit 0 才可发布 |

逐版本 gate 结果见 [`docs/releases/v0.9.4.md`](docs/releases/v0.9.4.md)（历史版本见 [`docs/releases/v0.9.3.md`](docs/releases/v0.9.3.md)）；安装抽样证据见 [`docs/releases/v0.9.3-install-sampling.md`](docs/releases/v0.9.3-install-sampling.md)（30/30 冷装，中位 1980 ms）。

## 性能基准（bench）

`scripts/bench.mjs`（Node，无第三方依赖）在 release 版 native CLI 上做端到端计时：
自动把 `testdata/opus_sample.opus` 复制成 16 条 serial 递增的链接流（≈1.0 MiB）作为大输入，
每个操作运行 N 次取最小值（含进程启动 1–2 ms）。

```sh
moon build --release --target native
node scripts/bench.mjs --runs 5                                                          # 只记录（旧行为）
node scripts/bench.mjs --runs 5 --batches 2                                               # 多批次采样（降低进程启动抖动）
node scripts/bench.mjs --runs 5 --batches 2 --baseline scripts/bench-baseline.json --fail-over 0.10  # 基线对比
```

基线（`scripts/bench-baseline.json`：Windows 11 x64 / release native / 2026-11-13；
3 轮独立运行 × 每轮 5 runs × 2 batches = 每项 30 样本取 min，再取各轮 min 的上界）：

| 操作 | 输入 | 基线 min_ms | 说明 |
|---|---:|---:|---|
| `verify`（CRC + 结构体检） | 1.02 MiB | 21.7 ms | |
| `info --json` | 1.02 MiB | 16.5 ms | |
| `dump`（页级转储） | 1.02 MiB | 19.7 ms | |
| `remux`（Ogg → MP4） | 65 KiB | 18.4 ms | |
| `to-ogg`（MP4 → Ogg） | 66 KiB | 18.2 ms | |
| `demux`（拆包写目录） | 65 KiB | 80.0 ms | **I/O 密集**：同机 6 次测量 min 在 66.2–84.6 ms 间波动（±10 ms），基线取混合负载下 6 次测量的上界 80.0 ms |

**门禁语义**：有 `--baseline` 时按 `min_ms` 比较，超阈值退出码 1。抖动处理：
- **小操作噪声下限 4 ms**：基线 < 50 ms 的操作，允许波动 = `max(fail_over × 基线, 4 ms)`（`--noise-floor` 可调，0 关闭）——否则 ~15–22 ms 的操作只要进程启动慢 1–2 ms 就会误报；
- 大操作严格按 `--fail-over` 比例；基线取「多轮 min 的上界」而非绝对最小值，配合噪声下限仍能捕获小操作 >~20% / 大操作 >10% 的真实回退；
- 基线文件带环境信息（OS / 工具链 / Node），**平台不一致时只打 `WARN` 不判失败（平台守卫）**；
- CI 的 `bench · native` job 用 ubuntu-latest + `--fail-over 0.50`（共享 runner 抖动大）作粗粒度告警，严格门禁需在 ubuntu 生成同平台基线；本地 / 专用 runner 用默认 `0.10`。

更新基线须在提交说明中给出实测环境（OS / CPU / `moon version --all`）、采样轮数与数值，并保留 `threshold_policy` / `notes` 记录。

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

常用别名等价可用（均 exit 0）：`moonmux --help` / `moonmux -h` 等同 `moonmux help`，`moonmux --version` 等同 `moonmux version`；未知选项会给出对应子命令用法并 exit 2。

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
├── docs/dependency-assessment.md  依赖维护性评估（G1-B2 = DEGRADED）与工具链 pin 结论
├── docs/known-issues.md   已知问题与残余风险（KI-01..05）
├── docs/security/pii-advisory.md  历史发布包 PII 风险接受公告
├── docs/releases/     逐版本发布记录（commit / tag / 工具链 / zip sha256 / gate 结果）与安装抽样（v0.9.3-install-sampling）
├── examples/          三个可运行示例
├── scripts/           smoke / verify_mp4 / bench / fuzz / install_check / preflight_release / check_package / check_pii / gen_sbom / check_api_diff / check_api_docs / check_coverage / bench-baseline
├── testdata/          真实音频样本
├── RELEASING.md       发布流程、发布前检查单、回滚预案
└── NOTICE / THIRD_PARTY.md   许可声明与第三方依赖清单
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
| `hyperfine` / `cargo bench` | 基准的「多次运行取最小值 + 表格化输出」呈现方式 | 不引入第三方依赖；提供本地基线 + 阈值 + 平台守卫（跨平台仅 WARN），不做跨机器绝对阈值 |
| `cargo-fuzz` / AFL++ | 「种子 + 确定性变异 + 退出码/超时断言」的变异测试模式 | 不使用其 fuzz 引擎；无覆盖率引导 |

测试样本说明：`testdata/` 下的 Opus / Vorbis 文件由 ffmpeg（libopus / libvorbis）生成，仅用于测试，
不包含任何第三方受版权保护的音频内容。

## 开发状态

当前最新版本为 **v0.9.4**（2026-11-13，验收整改版）。版本历程：v0.2.0（2026-10-23）→ v0.3.0–v0.3.2（2026-11-07：MP4 写入、`remux`、CRC 查表）→ v0.4.0（2026-11-09：WAV 全格式与流式页读取）→ v0.5.0（2026-11-09：MP4 → Ogg 解封装 `to-ogg`）→ v0.6.0（2026-11-09：性能基准与变异测试）→ v0.7.0（2026-11-09：WAV 块保真与 `WavWriter`）→ v0.7.1（2026-11-09：文档同步）→ v0.8.0（2026-11-10：正确性修复）→ v0.9.0（2026-11-10：正确性/契约修复）→ v0.9.1（2026-11-10：清单 I/O 退出码修复）→ v0.9.2（2026-11-11：安全/资源边界修复）→ v0.9.3（2026-11-12：仓库整理）→ v0.9.4（2026-11-13：验收整改：安全 gate v3、CI 门禁、覆盖率 82.87%）。

已可用：Ogg 容器读写（含多逻辑流的分组与交织写出、物理流链接与拆分、结构体检）、WAV 读写、
Ogg → WAV 转码管线（Opus 与 Vorbis 均已实测）、**MP4/ISOBMFF 写入（Opus-in-MP4，`remux`）与解封装（`to-ogg`）**，
`info` / `demux` / `mux` / `cat` / `split` / `extract` / `dump` / `tags` / `tag` / `seek` / `verify` / `to-wav` / `chop` / `remux` / `to-ogg` 十五个子命令，
**475 个测试通过**（Windows x64 本地实测：native 475/475、wasm-gc 425/425、js 425/425；`wasm` 后端 0 个测试、不在 `supported_targets`），覆盖率 **工具口径总 82.87%（5210/6287，CI 门禁 ≥80%，D2 已达标）、库层行覆盖率 91.79%（3779/4117，≥88%）**；未覆盖行 **635**、Linux 估算 ~662（CI 阈值 780+20 = 800），**公开 API 文档覆盖 132/132 = 100%**（D6 门禁 ≥95%），并通过真实 Opus / Vorbis 文件的逐页 CRC、拆包—重封装往返验证、
双逻辑流交织—还原往返验证、物理流链接—拆分往返验证（含流号冲突场景）、转码验证、Ogg→MP4 外部工具（ffprobe/ffmpeg）对账与 MP4→Ogg 逐包还原验证。

工程配套：`moon check --deny-warn` 零警告、`moon fmt --check` 通过、`native` / `wasm-gc` / `js` 后端（覆盖矩阵见上文「支持矩阵」）；
475 个测试（native；wasm-gc / js 各 425）、端到端检查（`scripts/smoke.sh`，含 remux/MP4 项）、
`scripts/verify_mp4.sh`（ffprobe/ffmpeg 外部对账）、`scripts/install_check.sh`（干净工程 `moon add` 验证）、`scripts/bench.mjs`（性能基准，含基线 / 阈值 / 平台守卫）、`scripts/fuzz.mjs`（确定性变异测试）、发布/供应链脚本（`preflight_release.sh` / `check_package.sh` / `check_pii.sh` / `gen_sbom.sh` / `check_api_diff.sh` / `check_api_docs.sh` / `check_coverage.sh` / `bench-baseline.json`）、
GitHub Actions CI（11 个 job：check/fmt/info/test × 2 OS + target-all + **API 文档覆盖 + 库层/总覆盖率门限（总 ≥80%）** + native/Windows smoke + mp4 + install + **api-diff（已对 `--target-all` 各后端接口做 diff）** + **examples** + **publish-dry-run** + bench 阈值 + fuzz）。
变更记录见 [CHANGELOG.md](CHANGELOG.md) 与 GitHub Releases（v0.1.0 / v0.2.0 / v0.3.0 / v0.3.1 / v0.3.2 / v0.4.0 / v0.5.0 / v0.6.0 / v0.7.0 / v0.7.1 / v0.8.0 / v0.9.0 / v0.9.1 / v0.9.2 / v0.9.3 / v0.9.4）。
发布流程与回滚预案见 [RELEASING.md](RELEASING.md)；v0.9.4 的 commit / tag / 工具链 / **zip sha256** / gate 结果见 [docs/releases/v0.9.4.md](docs/releases/v0.9.4.md)（历史 v0.9.3 见 [docs/releases/v0.9.3.md](docs/releases/v0.9.3.md)），**G1-01 冷装抽样证据**（30/30 = 100%，中位 1980 ms）见 [docs/releases/v0.9.3-install-sampling.md](docs/releases/v0.9.3-install-sampling.md)；**依赖维护性评估**（G1-B2 = DEGRADED，含退出预案与工具链 pin 结论）见 [docs/dependency-assessment.md](docs/dependency-assessment.md)；**已知问题与残余风险**（KI-01..05，含 moonvorbis 上游 issue 草稿）见 [docs/known-issues.md](docs/known-issues.md)；**历史 PII 风险接受**见 [docs/security/pii-advisory.md](docs/security/pii-advisory.md)；第三方依赖许可见 [THIRD_PARTY.md](THIRD_PARTY.md) 与 [NOTICE](NOTICE)。

主要新增能力（v0.3.0–v0.9.4）：MP4 / ISOBMFF 封装（Opus-in-MP4）与 `remux`、MP4 → Ogg 解封装 `to-ogg`（读写闭环）；CRC-32 查表优化；WAV 全格式兼容（IEEE float / Extensible / 24-in-4）与增量流式页读取；性能基准与确定性变异测试；WAV 块保真与流式写接口 `WavWriter`；v0.8.0 的 Opus TOC / remux 闸门 / MP4 读侧 / stsz / 多声道头 / granule / dOps gain / 头包页隔离 / 跨页替换 / WAV fmt 布局等正确性修复，v0.9.0/v0.9.1 的 MP4 编辑列表 / WAV fact / 页校验 / CLI 契约 / 2 GiB 闸门 / 清单 I/O 退出码等，v0.9.2 的分配前 Int64 上界 / 重同步预算 / 解码前 gate 与工作量预算 / 写路径安全收紧，以及 v0.9.3 的仓库整理、v0.9.4 的验收整改（Vorbis gate v3 双预算、CLI/解析边界修复、CI 11 门禁、覆盖率 82.87%）。
仍不做：WAV → Ogg 的反向管线（生态中尚无纯 MoonBit 编码器，边界与原因见上）。

## 许可证

Apache-2.0，见 [`LICENSE`](LICENSE)；版权声明见 [`NOTICE`](NOTICE)；第三方依赖许可证、仓库与用途见 [`THIRD_PARTY.md`](THIRD_PARTY.md)（含 `LL728/moonopus` 的 BSD-3-Clause 表数据组件与 `moonbitlang/x` 无 LICENSE 文本的上游缺口）。
依赖维护性评估（G1-B2 = DEGRADED，含退出预案与工具链 pin 结论）见 [`docs/dependency-assessment.md`](docs/dependency-assessment.md)；已知问题与残余风险（KI-01..05）见 [`docs/known-issues.md`](docs/known-issues.md)；历史发布包 PII 风险接受见 [`docs/security/pii-advisory.md`](docs/security/pii-advisory.md)。








