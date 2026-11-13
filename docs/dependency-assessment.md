# 依赖维护性评估（G1-B2 / B 场景）

> 评估对象：`WangYF0829/moonmux` v0.9.3 的 3 个直接依赖（含传递关系）。
> 评估日期：2026-11-13（Asia/Shanghai）。评估人：供应链审查/整改组。
> 评估依据：`MoonBit语言库通用验收清单` G1-B2「维护可用」与 `编程语言库通用验收清单` G1-B2「维护可用性」：
> 近 12 个月有发布或明确「稳定冻结」声明、有可用的安全披露渠道、bus factor ≥2 或有接管/分叉预案、无 `moon deprecate` 标记。
> 方法：`moon view`（mooncakes 元数据，2026-11-13）＋ 本地注册表索引 `created_at` 逐版本核对 ＋ GitHub REST API
> （repo / contributors / commits / releases / SECURITY.md / security-advisories，2026-11-13，未认证配额 60/60 起抓取）。
> 原始证据：`_review/evidence/r3-supply-*.{json,log}`、`r3-supply-mooncakes.log`、`r3-supply-release-cadence.log`。

## 1. 依赖与角色

| 依赖 | 固定版本 | 在 moonmux 中的角色 | 来源 |
|---|---|---|---|
| `moonbitlang/x` | `0.5.5` | `cmd/main`、`examples/*` 的 `x/fs`/`x/sys`（文件 I/O）；也是另两个依赖的传递依赖 | mooncakes；GitHub `moonbitlang/x` |
| `LL728/moonopus` | `0.2.2` | `pipeline/` 的 Ogg Opus 解码（`to-wav` Opus 路径） | mooncakes；GitHub `Xcsa-ee/moonopus`（注意与发布者不同，见风险 R-DEP-01） |
| `LL728/moonvorbis` | `0.1.4` | `pipeline/` 的 Ogg Vorbis 解码（`to-wav` Vorbis 路径） | mooncakes；GitHub `LL728/moonvorbis` |

依赖声明见 [`moon.mod`](../moon.mod)（全部精确 pin）；依赖树 = 3 直接依赖 + 共享的 `moonbitlang/x`，深度 2、无其他传递依赖
（首轮供应链审查 `moon tree` 记录；`moonbitlang/x` 无依赖）。许可证与再分发信息见 [`THIRD_PARTY.md`](../THIRD_PARTY.md) / [`NOTICE`](../NOTICE)。

## 2. 逐项取证

### 2.1 `moonbitlang/x@0.5.5`

| 维度 | 证据（2026-11-13） |
|---|---|
| mooncakes 最新发布 | 0.5.7，Published `2026-10-30T14:38:10Z`；共 **61** 个版本；`moon view` 无弃用标记、`--versions --json` 全部 `yanked:false` |
| 固定版本发布日期 | 0.5.5 @ `2026-09-11T07:30:15Z`（比最新 0.5.7 落后 2 个 patch） |
| 近 12 个月发布 | **21** 个版本（2025-11-13～2026-11-13，本地注册表 `created_at` 统计）；最近 5 个：0.5.3(09-09)、0.5.4(09-09)、0.5.5(09-11)、0.5.6(10-20)、0.5.7(10-30) |
| 仓库 | `github.com/moonbitlang/x`；`pushed_at 2026-11-12T03:09:57Z`（评估前 1 天）；最近 commit `2026-11-11T03:56Z`（作者 Gappylul）；`archived:false` |
| 维护者 / bus factor | GitHub contributors **35 个自然人 + 1 bot**（官方组织 `moonbitlang`；63 stars / 38 forks）；bus factor 高，组织级维护 |
| open issues | 22（有公开 issue 跟踪） |
| 安全披露渠道 | **仓库内无 `SECURITY.md`**（根目录与 `.github/` 均 404）；GitHub Security Advisories 功能可用但当前 0 条、未声明渠道/SLA |
| GitHub Releases | 10 个，最新 `v0.4.45` @ 2026-06-02（GitHub Release 落后于 mooncakes，发布渠道以 mooncakes 为准） |
| 许可 | `moon.mod license = Apache-2.0`；⚠️ 包内无 LICENSE 文本（上游打包缺口，THIRD_PARTY 已登记） |

### 2.2 `LL728/moonopus@0.2.2`

| 维度 | 证据（2026-11-13） |
|---|---|
| mooncakes 最新发布 | 0.2.2，Published `2026-10-16T11:00:07Z`（即固定版本，最新）；共 **4** 个版本；全部 `yanked:false`、无弃用标记 |
| 近 12 个月发布 | **4** 个版本：0.1.0(2026-10-09)、0.2.0(10-11)、0.2.1(10-11)、0.2.2(10-16) |
| 仓库 | `github.com/Xcsa-ee/moonopus`；`pushed_at 2026-10-16T11:01:22Z`（评估前 28 天）；最近 commit `2026-10-16T11:01:14Z`（Xcsa-ee）；`archived:false` |
| 维护者 / bus factor | contributors **1**（`Xcsa-ee`）→ **bus factor = 1**；无接管/分叉预案文档 |
| open issues | 0（无公开 issue 跟踪；亦无 GitHub Releases） |
| 安全披露渠道 | **无 `SECURITY.md`**（根目录/.github 均 404）；Security Advisories 0 条、无渠道/SLA |
| 许可 | Apache-2.0（`LICENSE` 11,358 B + `LICENSE-LIBOPUS` 4,393 B，BSD-3 表数据，见 THIRD_PARTY） |
| 身份链 | mooncakes 发布者 `LL728` ≠ GitHub 仓库 owner `Xcsa-ee`（`LL728/moonopus` 404）。首轮 G1-B1 已登记，仍无书面解释（见 R-DEP-01） |

### 2.3 `LL728/moonvorbis@0.1.4`

| 维度 | 证据（2026-11-13） |
|---|---|
| mooncakes 最新发布 | 0.1.4，Published `2026-10-17T02:34:21Z`（即固定版本，最新）；共 **5** 个版本；全部 `yanked:false`、无弃用标记 |
| 近 12 个月发布 | **5** 个版本：0.1.0(2026-09-20)、0.1.1(09-22)、0.1.2(10-03)、0.1.3(10-03)、0.1.4(10-17) |
| 仓库 | `github.com/LL728/moonvorbis`；`pushed_at 2026-10-17T02:59:27Z`（评估前 27 天）；最近 commit `2026-10-17T02:55:01Z`（LL728）；`archived:false` |
| 维护者 / bus factor | contributors **1**（`LL728`）→ **bus factor = 1**；无接管/分叉预案文档 |
| open issues | 0（无公开 issue 跟踪；无 GitHub Releases） |
| 安全披露渠道 | **无 `SECURITY.md`**（根目录/.github 均 404）；Security Advisories 0 条、无渠道/SLA |
| 已知缺陷 | `unsafe_get` / 缺 bit-budget（上游无修复版本）——详见 [`docs/known-issues.md`](known-issues.md) KI-01 |
| 许可 | Apache-2.0（`LICENSE` 11,358 B；README 声明原创、未移植上游代码） |

## 3. G1-B2 判定

| G1-B2 子项 | moonbitlang/x | LL728/moonopus | LL728/moonvorbis |
|---|---|---|---|
| 近 12 个月有发布（或明确冻结） | ✅ 21 个版本 | ✅ 4 个版本 | ✅ 5 个版本 |
| 无 `moon deprecate` 标记 / 未 yanked | ✅ | ✅ | ✅ |
| 有可用安全披露渠道 | ❌ 无 SECURITY.md（仅 GitHub Advisories 功能） | ❌ 无 SECURITY.md | ❌ 无 SECURITY.md |
| bus factor ≥2 或有接管/分叉预案 | ✅ 35 contributors（组织维护） | ❌ 1 contributor，无预案 | ❌ 1 contributor，无预案 |
| **单项结论** | **PASS（1 项披露渠道缺口）** | **PARTIAL（bus factor / 披露渠道不满足）** | **PARTIAL（bus factor / 披露渠道不满足；另有已知缺陷）** |

**G1-B2 判定：DEGRADED（严格 MUST 口径 = FAIL）。**
- 3 个依赖都在近 12 个月内持续发布、均未弃用/yanked，**活跃度维度通过**；
- 但 **3/3 无安全披露渠道文档**，**2/3 为单人维护（bus factor=1）且无接管/分叉预案**，不满足 G1-B2 的全部子项；
- moonvorbis 另有未修复的 `unsafe_get`/缺 bit-budget 依赖缺陷（G1-M06 已登记降级）。
- 缓解与风险接受见 §5；不因 B2 降级而阻塞发布（属依赖侧外部条件，已用隔离/固定版本/gate 缓解并登记）。

## 4. 工具链 pin 可行性（结论：机制存在，但上游拒绝固定版本 → 当前不可可靠 pin）

目的：判断 CI 能否把 MoonBit 工具链固定到发布基线 `moon 0.1.20261012`，从而消除"latest 漂移"。

### 4.1 安装脚本取证（源码已抓取：`_review/evidence/r3-supply-install-unix.sh`、`r3-supply-install-powershell.ps1`）

| 安装器 | 固定版本机制 | 下载 URL 规则 |
|---|---|---|
| Linux/macOS `install/unix.sh` | ✅ 支持：`version=${ARGUMENTS[0]:-${MOONBIT_INSTALL_VERSION:-latest}}`（第 105 行；位置参数或 `MOONBIT_INSTALL_VERSION` 环境变量） | `https://cli.moonbitlang.com/binaries/<version>/moonbit-<target>.tar.gz`（第 110 行）；`.../cores/core-<version>.tar.gz`（第 111 行）；target = `darwin-aarch64` / `linux-x86_64` / `linux-aarch64`（第 86-94 行） |
| Windows `install/powershell.ps1` | ✅ 支持但**仅环境变量**：`if ($env:MOONBIT_INSTALL_VERSION) { $Version = $env:MOONBIT_INSTALL_VERSION }`（第 2-6 行；**无位置参数**） | `https://cli.moonbitlang.com/binaries/<version>/moonbit-windows-x86_64.zip`（第 35 行）；`.../cores/core-<version>.zip`（第 38 行） |

### 4.2 固定版本 URL 实测（HEAD，2026-11-13；未安装/未改本机环境）

| URL（`<version>` 占位） | HTTP | 说明 |
|---|---|---|
| `binaries/0.1.20261012/moonbit-linux-x86_64.tar.gz` | **403** | 目标固定版本，CDN 返回 `application/xml` 拒绝 |
| `binaries/0.1.20261012/moonbit-linux-aarch64.tar.gz` | **403** | 同上 |
| `binaries/0.1.20261012/moonbit-darwin-aarch64.tar.gz` | **403** | 同上 |
| `cores/core-0.1.20261012.tar.gz` | **403** | 同上 |
| `binaries/0.1.20261012/moonbit-windows-x86_64.zip` | **403** | Windows 固定版本同样被拒 |
| `cores/core-0.1.20261012.zip` | **403** | 同上 |
| `binaries/latest/moonbit-linux-x86_64.tar.gz` | **200**（101,202,397 B） | latest 可用 |
| `cores/core-latest.tar.gz` | **200**（2,811,618 B） | latest 可用 |
| `binaries/latest/moonbit-windows-x86_64.zip` | **200**（92,766,314 B） | latest 可用 |
| `cores/core-latest.zip` | **200**（3,922,073 B） | latest 可用 |

原始输出：`_review/evidence/r3-supply-toolchain-head.log` / `.json`（6 个固定版本 URL 全部 403，4 个 latest URL 全部 200）。

### 4.3 结论与补偿

**结论：安装器支持版本选择，但上游只保留 `latest` 产物（固定版本 403），CI 无法可靠 pin 到 `0.1.20261012`。**
维持现状（latest + 版本记录 + 可复现/校验和补偿），并保留本结论作为"已知偏差"登记：
- 每个 job 打印 `moon version --all`（CI 已有），发布记录/`docs/releases/*.md` 记录实际工具链；
- 发布制品用 `sha256` + mooncakes `metadata.checksum` 互证（[`scripts/gen_sbom.sh`](../scripts/gen_sbom.sh) 归档）；
- 同 commit + 同工具链重建可比对（首轮供应链审查已验证 v0.9.3 发布包可复现，注意 CRLF 口径见 [`RELEASING.md`](../RELEASING.md)）；
- 若未来上游开放固定版本，CI 只需：

```yaml
# .github/workflows/ci.yml（未来上游放开固定版本后）
env:
  MOONBIT_INSTALL_VERSION: "0.1.20261012"   # unix.sh 也可用位置参数传版本
steps:
  - name: Install MoonBit (Unix)
    run: curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
  - name: Install MoonBit (Windows)
    shell: pwsh
    run: irm https://cli.moonbitlang.com/install/powershell.ps1 | iex   # 仅读 MOONBIT_INSTALL_VERSION
  - name: Verify pinned toolchain
    run: moon version --all   # 并断言包含 0.1.20261012；不匹配则失败
```

> 备注：上游未公开固定版本保留策略/校验方式；本次 403 与 `RELEASING.md`/`ci.yml` 注释中"旧版本 URL 403"的历史一致。

## 5. 风险登记

| ID | 风险 | 严重度 | 影响 | 现有缓解 | 建议跟踪/负责人 |
|---|---|---|---|---|---|
| R-DEP-01 | `moonopus` 身份链：mooncakes 发布者 `LL728` ≠ 仓库 owner `Xcsa-ee`，且 bus factor=1 | 中 | 来源可追溯性/维护连续性风险；不能排除账号转移或 fork 关系不明 | 固定版本 0.2.2 + `metadata.checksum` 校验 + SPDX/许可核对；依赖隔离在 `pipeline/` | 引入方（moonmux 维护者）书面说明或 ADR；每季度复核仓库/账号变化 |
| R-DEP-02 | `moonvorbis` bus factor=1 + 已知 `unsafe_get`/缺 bit-budget 无上游修复 | 中高 | 恶意码流健壮性风险；上游若停更无修复来源 | gate v3（内存/CPU 双预算）+ 固定版本 + `to-wav` 不承诺不可信输入；见 [known-issues](known-issues.md) KI-01 | 上游提 issue 并跟踪（草稿见 KI-01）；moonmux 维护者负责升级评估 |
| R-DEP-03 | 3/3 依赖无 `SECURITY.md`/披露渠道/SLA | 中 | 漏洞无处报告、无响应预期；供应链事件响应不可控 | 以 GitHub Security Advisories（当前均 0 条）作为事实渠道；moonmux 侧 PII/凭据扫描与固定版本 | moonmux 维护者在其 `SECURITY.md`（如有）或 RELEASING 记录第三方上报路径；向上游建议补 SECURITY.md |
| R-DEP-04 | `moonbitlang/x` 固定 0.5.5，落后最新 0.5.7 两个 patch | 低 | 可能缺非安全修复（0.5.6/0.5.7 changelog 未见安全修复条目） | 精确 pin + 变更评估流程；不自动升级 | 每次升级评估（CI 回归 + CHANGELOG 对比）；登记升级决策 |
| R-DEP-05 | MoonBit 生态无公共 CVE/OSV 数据库 | 低 | 无法做自动化漏洞匹配，只能人工/GitHub advisories 取证 | 依赖少（3 个）、纯 MoonBit、C stub 已审；固定版本 + checksum | 持续关注上游 release/advisory；发布前跑 `check_package`/`check_pii` |

## 6. 维护性监控与退出预案

1. **监控**：每次发布前复核 3 个依赖的 mooncakes 最新版本/日期、仓库 `pushed_at`、open issues、SECURITY.md 状态（本文件所列命令可复跑，见 §7）；记录到发布记录。
2. **升级流程**：版本对比 → 上游 CHANGELOG/issue 评估 → 固定新版本 → `moon check/test/bench` 回归 → 输出 API diff（`scripts/check_api_diff.sh`）→ 更新 [`THIRD_PARTY.md`](../THIRD_PARTY.md) 与 checksum。
3. **退出预案（依赖停更/安全事件）**：3 个依赖均 Apache-2.0、纯 MoonBit、体积小，可本地 fork/vendor：优先临时 fork + 修复补丁（保留原许可/版权），或在下游用 `pipeline/` 适配层替换解码器；`moonmux` 已把解码依赖隔离在 `pipeline/`（容器层零三方依赖），替换成本可控。**目前无正式书面预案**，本文件即登记载体，建议发布负责人确认后同步到 [`RELEASING.md`](../RELEASING.md)。
4. **披露渠道**：当前依赖无 SECURITY.md，建议向上游 repo 提 issue 请求补充；紧急安全问题通过 moonmux 维护者转发。

## 7. 复跑命令（可复现取证）

```bash
# mooncakes 元数据 / 版本列表 / 单版本日期
moon view moonbitlang/x
moon view LL728/moonopus
moon view LL728/moonvorbis
moon view moonbitlang/x@0.5.5 --json
# 本地注册表索引（含逐版本 created_at；路径按平台）
cat ~/.moon/registry/index/user/moonbitlang/x.index
# GitHub 侧（未认证 API，注意 60 req/h 配额）
curl -s https://api.github.com/repos/moonbitlang/x
curl -s https://api.github.com/repos/moonbitlang/x/contributors?per_page=100
curl -s https://api.github.com/repos/moonbitlang/x/contents/SECURITY.md
# 工具链 pin（HEAD 探测，不安装）
curl -sI https://cli.moonbitlang.com/binaries/0.1.20261012/moonbit-linux-x86_64.tar.gz   # 403
curl -sI https://cli.moonbitlang.com/binaries/latest/moonbit-linux-x86_64.tar.gz        # 200
```

## 8. 证据索引与未验证项

**证据**（`_review/evidence/`）：
- `r3-supply-gh-repo-{x,opus,vorbis}.json`、`r3-supply-gh-contributors-{x,opus,vorbis}.json`、
  `r3-supply-gh-commits-{x,opus,vorbis}.json`、`r3-supply-gh-releases-{x,opus,vorbis}.json`、
  `r3-supply-gh-securityroot-{x,opus,vorbis}.json`、`r3-supply-gh-securitygh-{x,opus,vorbis}.json`、
  `r3-supply-gh-advisories-{x,opus,vorbis}.json`、`r3-supply-gh-summary.json`；
- `r3-supply-mooncakes.log`、`r3-supply-release-cadence.log`、`r3-supply-toolchain-head.log/.json`、
  `r3-supply-install-unix.sh`、`r3-supply-install-powershell.ps1`。

**未验证项**：
- GitHub 未认证 API 为快照（2026-11-13），`contributors` 仅统计 GitHub 可见提交者，不能反映全部维护者；mooncakes 页面无 deprecated 字段，弃用状态以 `yanked:false` + 无弃用标记推断。
- GitHub Security Advisories 空仅代表未公开披露，不代表无已知漏洞；MoonBit 无 CVE/OSV 数据源可对照。
- 工具链固定版本 URL 只探测了 `0.1.20261012`（发布基线）与 `latest`；未穷举其他历史版本（上游注释/实测一致表明旧版本不可用）。
- 上游仓库贡献者/维护者响应时限、SLA 无法从公开 API 获取；SECURITY.md 未来是否补充未验证。
