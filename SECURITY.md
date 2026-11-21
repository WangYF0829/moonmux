# 安全策略（Security Policy）

> 适用范围：`WangYF0829/moonmux` 仓库、mooncakes.io 发布包与 GitHub Release 制品。
> 相关文档：[`docs/known-issues.md`](docs/known-issues.md)（已知残余风险）、
> [`docs/security/pii-advisory.md`](docs/security/pii-advisory.md)（历史 PII 风险接受）、
> [`THIRD_PARTY.md`](THIRD_PARTY.md)（依赖许可与安全边界）。

## 支持版本

| 版本 | 安全修复 |
|---|---|
| 最新发布版本（当前 `0.9.x`） | ✅ 接收报告并修复 |
| 更早的 0.x 版本 | ⚠ 仅评估是否影响最新版；不承诺回补 |

MoonBit 生态在 1.0 前不承诺公开 API 稳定；安全修复按 `RELEASING.md` 发布新 patch/minor 版本，
不修改已发布制品（mooncakes 不支持单版本撤回）。

## 报告渠道

**请优先使用 GitHub Security Advisories 私密报告：**

<https://github.com/WangYF0829/moonmux/security/advisories/new>

如果该入口不可用，请在仓库 Issue 中**只说明“需要安全联系方式”**，不要公开漏洞细节、PoC 或
受影响文件；维护者会通过私密渠道跟进。

报告请尽量包含：

- 受影响版本 / commit / 平台（Windows / Linux / wasm-gc / js）；
- 最小复现（输入文件可脱敏；优先给出构造脚本）；
- 影响判断（崩溃 / 越界读 / 资源放大 / 数据损坏 / 仅文档问题）；
- 是否已在公开渠道披露。

## 处理时限（尽力而为）

| 阶段 | 目标 |
|---|---|
| 确认收到 | 7 天内 |
| 初步分级与影响面 | 14 天内 |
| 高危/阻断问题修复或缓解方案 | 30 天内（复杂问题在 Issue/Advisory 中同步进展） |
| 公开披露 | 修复版本发布后，与报告人协商；默认给升级窗口 |

本项目为个人维护的开源项目，无漏洞赏金；会在发布记录与 `CHANGELOG.md` 的 Security 区段致谢
（报告人要求匿名时除外）。

## 范围与已知边界

**在范围内**：Ogg / WAV / MP4 容器解析与写出、CLI 参数与文件路径处理、资源预算、
发布包内容与供应链脚本。

**已知且已登记的残余风险**（不属于新漏洞，但仍欢迎改进建议）：

- `LL728/moonvorbis@0.1.4` 内部 `unsafe_get` 与缺少统一 bit-budget；`to-wav` 的 Vorbis 路径
  已用 gate v3 + 内存/CPU 双预算缓解，但仍不建议直接处理不可信输入（KI-01）。
- Opus 音频 payload 只校验 TOC，不校验码流内容；健壮性依赖 `LL728/moonopus`（KI-02）。
- 历史发布包（0.2.0–0.9.1）含作者旧联系方式，不可撤回，已按风险接受登记（KI-03）。

### 上游依赖导致的风险（非 moonmux 代码缺陷）

以下风险的根因在第三方包或 MoonBit 工具链，**不能通过修改 moonmux 自身代码完全消除**；
完整清单、边界声明与关闭条件见 [`docs/known-issues.md`](docs/known-issues.md) 的「上游依赖导致的风险」一节。

| 上游 | 风险 | 状态 |
|---|---|---|
| `LL728/moonvorbis@0.1.4` | `unsafe_get` / 缺 bit-budget；不可信 Vorbis 可能越界读或资源放大 | 开放；无上游修复；gate v3 缓解；**G1-M06 严格口径 FAIL（风险接受）** |
| `LL728/moonopus@0.2.2` | Opus payload 只校验 TOC，不校验码流内容 | 信任边界约束；KI-02 |
| MoonBit 工具链 latest | 滚动更新可能引入破坏性变更（2026-11-17 `size_hint` 弃用使 0.9.7 编译失败） | 0.9.8 已适配；**已通过第三方归档 + SHA-256 pin 到 `0.1.20261117`**；残留归档信任/可用性 |
| `moonbitlang/x@0.5.5` | 上游 API/ABI 变化 | 精确 pin + CI 回归；低风险 |

**明确声明**：上述风险不是 moonmux 源码中的漏洞；本项目不宣称已通过 G1-M06。上游 issue **尚未提交**
（草稿见 `docs/known-issues.md` KI-01），因此 R-UP-01 的状态是「已缓解、未上游修复、未正式上报」。
在不可信输入场景，仍应使用独立进程和资源限额隔离 `to-wav`。

## 安全默认值

- CLI 写命令在写盘前做完整性与预算校验，失败不产出半成品；
- 解码路径默认有内存/CPU 上限（`MOONMUX_MAX_PCM_MB`），超限以数据错误退出；
- 发布前运行 `scripts/check_pii.sh`、`scripts/check_package.sh` 与 `scripts/preflight_release.sh`；
- 不在仓库/发布包中保存凭据；CI 使用最小权限（`contents: read`）。
