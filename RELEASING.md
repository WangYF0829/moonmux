# 发布流程（RELEASING）

> 面向对象：moonmux 发布负责人 / 复核人。
> 适用范围：mooncakes.io（`WangYF0829/moonmux`）与 GitHub Release。
> 工具链基线：`moon 0.1.20261117` / `moonc 0.10.21`（CI 通过 `.github/actions/setup-moonbit` pin 到该版本；v0.9.4–v0.9.7 使用 moon 0.1.20261012；每次发布以 `moon version --all` 实际输出为准并记入发布记录）。
> 历史发布记录见 [`docs/releases/`](docs/releases/)。

## 0. 先记住三件事

1. **发布不可撤回**：mooncakes 没有「删除 / 撤回单个版本」的能力，同一版本号不能重发（重复发布会返回 HTTP 409 `duplicated`）；唯一的止损手段是 `moon deprecate WangYF0829/moonmux`（**全模块弃用**）并尽快发修复版。
2. **发布包由工作区生成**：`moon package` / `moon publish` 打包的是当前工作区文件（含未跟踪文件），`.moonignore` 只负责排除。发布前工作区必须干净。
3. **可复现性要求：发布工作区必须与标准 checkout 的字节一致（UTF-8 无 BOM + LF）**。历史发布包（v0.9.3 / v0.9.4）保留了作者工作区的 CRLF/BOM 字节：只有该工作区能逐字节复现，标准 `git checkout`（`.gitattributes` 的 `eol=lf`）不能（v0.9.3 实测 371,067 B vs 370,958 B，sha256 不同）。自本流程起：发布前把跟踪的文本文件规范化为 LF、去除 UTF-8 BOM，并用 `bash scripts/check_package.sh --strict-repro` 验证；打包后再在 tag 的**全新 checkout** 上重跑 `moon package`，两次 zip 的 sha256 必须一致。发布记录同时写明作者工作区与标准 checkout 的 sha256。

## 1. 发布前检查单（按序执行，全部留档）

- [ ] **版本号单一事实源**：`moon.mod` 的 `version` 更新后，同步以下版本副本：
      `moonmux.mbt` 的 `MOONMUX_VERSION`、README 的 version / mooncakes 双徽章、
      `scripts/install_check.sh` 默认版本、`.github/workflows/ci.yml` 的 `MOONMUX_INSTALL_VERSION`、
      `docs/architecture.md` 版本行、`CHANGELOG.md` 顶部条目（以及 `scripts/check_version.sh` 期望分支）。
- [ ] **版本一致性脚本**：`bash scripts/check_version.sh` → 退出码 0（Git Bash / Linux）。
      该脚本共 **11 项**：CLI `describe()`、README 双徽章、smoke 断言、install_check、CI install 版本、`MOONMUX_VERSION`、
      `docs/architecture.md` 版本行、CHANGELOG `[Unreleased]` 与顶部版本条目、`git describe --tags`（以脚本实际内容为准）。
- [ ] **工作区干净**：`git status --porcelain` 为空；`git ls-files` 中无 `_build/`、`*.mbti`、`pkg.generated.mbti`、日志。
- [ ] **质量门禁**：`moon check --deny-warn`、`moon fmt --check`、`moon test --deny-warn --target all`
      （v0.9.9 实测：native **484/484**（Windows；Linux CI **481**，净差 3 项（Windows / POSIX 专属用例））、wasm-gc **429/429**、js **429/429**；覆盖率 v0.9.9 实测工具口径总 **82.57%**、库层 **91.82%**（3781/4118）；v0.9.5 发布基线为 480/477/428、82.53%/91.82%；v0.9.4 为 475/473/425、82.87%/91.79%）全部退出 0。
- [ ] **发布前一键预检**：`bash scripts/preflight_release.sh` → 退出码 0（PASS/FAIL 汇总表）；要求 **clean worktree**，
      发布演练/整改期可用 `--allow-dirty`；快速门禁用 `--skip-bench` / `--skip-fuzz` / `--skip-smoke`；
      覆盖：工具链记录 / worktree / 版本一致性 / 格式 / check / test all / api-diff / api-docs / 覆盖率（总 ≥80%）/ PII / 包内容 / SBOM / bench / fuzz / smoke。
- [ ] **API 兼容性门禁**：`bash scripts/check_api_diff.sh --target-all` → 退出码 0（仅新增 / 白名单差异）；
      1 = 出现删除 / 改签名 / 枚举值变化（0.x 下需升 minor 并附迁移说明）；CI `api-diff` job 同语义（已调用 `--target-all`，校验 native/wasm/wasm-gc/js 各后端接口一致）。
- [ ] **API 文档覆盖门禁（D6）**：`bash scripts/check_api_docs.sh --threshold 95 --max-gap 0` → 退出码 0；
      当前 **133/133 = 100%** pub 符号有 `///`（阈值 ≥95%、未文档符号 0；登记例外时才放宽 `--max-gap 1`）。CI `check` job 已接线。
- [ ] **覆盖率门禁**：`bash scripts/check_coverage.sh --lib-threshold 88 --total-threshold 80` → 退出码 0；
      当前 v0.9.7/v0.9.8 本地实测工具口径总覆盖率 **82.57%**（门限 ≥80%）、库层 **91.82%**（3781/4118，≥88%）；CI Linux v0.9.9 实测总 **80.68%**、未覆盖行 685（余量 0.68pp）；v0.9.5 发布基线为总 82.53%、库层 91.82%、CI Linux 80.49%/687；v0.9.4 为 82.87%（5210/6287）/91.79%/635。CI `coverage` job 已接线（阈值 80）。注意：`check_coverage.sh` 会先隔离仓库内其它位置的历史 trace（否则 `moon coverage report` 从项目根递归合并旧 trace 会虚高），并检测 `Counts array length mismatch` 告警。
- [ ] **包内容门禁**：`bash scripts/check_package.sh --strict-repro` 退出码 0（`moon package --list` 与 `git ls-files` 差集、worktree 干净、
      文件数 / 体积基线、禁止路径、密钥模式、UTF-8 BOM / CRLF 可复现性检查）；同时人工确认无 `_build/`、`*.mbti`、`pkg.generated.mbti`、`*.log`、`*.zip`、`out/`、`tmp/`、`*.bak`。
- [ ] **敏感信息 / PII 扫描**：`bash scripts/check_pii.sh`（手机号 / 邮箱 / 凭据正则）无命中；`git grep` 扫 `ghp_` / `sk-` / `AKIA` 无命中。
- [ ] **bench 基线**：`node scripts/bench.mjs --runs 5 --batches 2 --baseline scripts/bench-baseline.json --fail-over 0.10` 退出码 0；
      规则：①小操作（基线 < 50 ms）允许波动 = `max(fail_over × 基线, 4 ms 噪声下限)`，大操作按比例；②基线取「多轮 min 的上界」（每项 30 样本）而非绝对最小值；③`demux` 为 I/O 密集，基线取 6 次测量上界 **80.0 ms**（同机 66.2–84.6 ms 抖动），阈值仍可捕获 ≥20% 真实回退；④更新基线须在提交说明中给出实测环境（OS / CPU / `moon version --all`）、采样轮数/runs/batches 与数值，并同步更新 `scripts/bench-baseline.json` 的 `threshold_policy` / `notes`；⑤**跨平台只 WARN（平台守卫）**，严格门禁需在 ubuntu 生成同平台基线。
- [ ] **SBOM / 发布材料归档**：`bash scripts/gen_sbom.sh --out docs/releases/<version>`（或 `_review/fix/sbom-<round>`），
      归档 `moon tree --json`、`moon.mod` 快照、`moon version --all`、发布 zip sha256 与各文件校验和。
- [ ] **`moon publish --dry-run`**：必须在**未发布版本号**上演练并留档，判定标准见 §2；CI `publish-dry-run` job 已按 409/202 语义接线。
- [ ] **发布记录**：新建 `docs/releases/v<version>.md`（模板见 §4），填好 commit / tag / 工具链 / zip sha256 / 各 gate（含 api-diff / coverage / bench）结果 / CI run。
- [ ] **CI 全绿**：11 个 job（check / api-diff / coverage / native / examples / mp4 / install / publish-dry-run / bench / fuzz / smoke-windows）全部 success。
- [ ] **双人复核**：本仓库为单维护者项目，无法满足双人复核 → 按 §5 登记例外并用 CI 门禁 + 本检查单 + 发布后复测补偿。
- [ ] **发布身份**：`moon whoami` 确认发布身份为 `WangYF0829`；发布机器为可信本地机器；发布后检查 `moon view --my`。
- [ ] **GitHub Release 附件**：把 `moon package` 生成的 zip 与 `*.sha256` 作为 Release 附件上传（或至少把 sha256 写进 Release body）——**目前需要人工上传**（见 §9）。

## 2. `moon publish --dry-run` 的判定标准（工具链行为记录）

`moon 0.1.20261012` 实测（2026-11-12）：

| 场景 | 服务器返回 | CLI 行为 | 判定 |
|---|---|---|---|
| 版本已发布（例如对 `0.9.3` 复跑） | HTTP 409 `Version Error: ... duplicated with an existing version` | 非零退出 | **失败**（版本号已被占用，不能充当发布前演练） |
| 版本未发布（在合成 `0.9.4` 副本上演练） | HTTP 202 `Dry run completed successfully. No changes were made.` | 仍打印 ``Error: `moon publish` failed`` 并以非零退出（PowerShell 观测 `-1`） | **通过**（以服务器文本为准，不看退出码） |

**判定规则**：dry-run 的“通过”以服务器返回文本是否包含 `Dry run completed successfully` 为准；出现 4xx/5xx（401/403/409 等）判失败。当前工具链下 CLI 的非零退出是已知行为，不单独作为失败依据，但必须把完整 stdout / stderr 留档。

**操作步骤**：
1. 在隔离副本（不要动主工作区）把 `moon.mod` 版本临时改成下一个未发布号（示例：`0.9.4`）。
2. `moon publish --dry-run`，把 stdout / stderr 保存到 `_review/evidence/release-<version>/publish-dry-run.log`。
3. 核对：本地 check / 打包 / 解包复验通过 + 服务器 202 文本；同时确认**没有真正上传**
   （`moon view WangYF0829/moonmux --versions --json` 中不出现该版本）。
4. 若因故无法在未发布版本上演练（例如补记历史版本），用 `moon view WangYF0829/moonmux --json` 的
   `metadata.checksum` 与 `docs/releases/` 中的 sha256 互证，并在发布记录中注明“dry-run 未能事前留档”的原因。

**CI 接线**：`publish-dry-run` job 已按上述语义实现 —— 退出 0 = 通过；日志含 `409 Conflict` / `duplicated with an existing version` = 版本已发布，**warning 放行**（本地打包/解包校验已通过）；日志含 `Server status: 202` = 放行并记录；其余 = 失败。

## 3. 发布步骤

1. 完成 §1 全部检查（含 `preflight_release.sh` 一键预检、`check_api_diff.sh`、`bench.mjs --baseline`、`gen_sbom.sh` 与 `publish-dry-run`）。
2. `git tag -a vX.Y.Z -m "..."`（annotated tag，与发布 commit 对应）。
3. `moon package` → 记录 zip 路径 / 大小 / `Get-FileHash -Algorithm SHA256`（Linux：`sha256sum`）。
4. `bash scripts/gen_sbom.sh --out docs/releases/vX.Y.Z` 归档 SBOM / 工具链 / 制品 sha256（输出目录已存在时脚本不覆盖，会改用 `run-<时间戳>/`）。
5. 写 `docs/releases/vX.Y.Z.md` 与 GitHub Release（tag、sha256、工具链、CI run、各 gate 结果）。
6. `moon publish`（真实发布，不可撤回；确保版本号未发布）。
7. 发布后立即用干净工程复测：`moon new` → `moon add WangYF0829/moonmux@X.Y.Z` → `moon check` → 运行最小示例
   （可复用 `scripts/install_check.sh`）；CI `install` job 也会等待 mooncakes 并复测。
8. 24h 内复查：`moon view WangYF0829/moonmux --json` 的 `metadata.checksum` 与发布记录一致；关注 issue / 安装失败反馈；必要时执行 §6 回滚。
9. 把实际结果补进 `docs/releases/vX.Y.Z.md`，发布记录与 Release 附件互链。

## 4. 发布记录模板（`docs/releases/v<version>.md`）

| 字段 | 内容 |
|---|---|
| 版本 / 日期 | `X.Y.Z` / `YYYY-MM-DD HH:MM +08:00` |
| 发布 commit / tag | commit 全哈希 + annotated tag 名 |
| 工具链 | `moon version --all` 原文（moon / moonc / moonrun） |
| 发布平台 | 构建验证平台 + CI runner |
| 发布 zip | 大小 / 文件数 / 解压体积 |
| **zip sha256** | 完整哈希（同时写入 GitHub Release 附件 / body） |
| 注册表校验 | `moon view WangYF0829/moonmux --json` 的 `metadata.checksum` 与本地复算值 |
| CI run | run id / head_sha / job 数（当前 11）/ 结论 / 链接 |
| 各 gate 结果 | check / fmt / test（target 数）/ **API 文档覆盖 133/133** / coverage（分支% / 行口径总% / 库层% / 未覆盖行）/ smoke / mp4 / install / **api-diff（--target-all）** / **bench（基线对比）** / fuzz / package-list |
| 可复现性 | 保留工作区字节是否可复现；标准 checkout 的 sha256 与差异文件清单 |
| API 基线 | `.mbti` 基线归档位置（见 §8） |
| SBOM / 归档 | `gen_sbom.sh` 输出目录（moon tree / moon.mod / 工具链 / artifact sha256） |
| 安装复测 | 干净工程 add/check/run 结果与时间 |
| 已知问题 / 回滚 | 残余风险、是否需要 deprecate |

## 5. 双人复核例外登记（单维护者项目）

| 项 | 说明 |
|---|---|
| 事实 | 仓库仅 `WangYF0829` 一名发布者（无 PR / 评审记录），「双人复核」不满足 |
| 补偿 | ① CI 必需检查（**11 个 job**：check / api-diff / coverage / native / examples / mp4 / install / publish-dry-run / bench / fuzz / smoke-windows）② 本检查单逐项留档 ③ 发布后干净工程 install gate 24h 内复测 ④ 发布记录与 Release 附件可独立审计 ⑤ 重大版本可请第三方复核 API diff 报告 |
| 复核触发 | 每次发布由发布负责人按本文件自查并留档；每季度由 QA 抽查一次发布记录 |
| 到期复评 | 每 6 个月或在引入第二名维护者时，重新评估是否可以恢复真实双人复核 |

## 6. 回滚预案（发布不可撤回）

**关键事实**：MoonBit 注册表不支持删除 / 撤回单个版本，也不支持同版本重发（409）；`moon deprecate WangYF0829/moonmux --reason "..."` 只能**全模块弃用**（所有已发布版本），`--undo` 恢复；弃用不影响版本解析，但依赖解析选中被弃用模块时会告警。发布修复版是首选止损方式。

| 情形 | 处置 | 时限 |
|---|---|---|
| 发布包内容错误（文档 / 元数据）但不影响使用 | 发布 `X.Y.(Z+1)` 修复版，在 Release 说明前一版问题；不 deprecate（避免影响全部版本） | ≤24h |
| 发布包缺文件 / 构建失败 / 安全边界问题 | 发布修复版；评估是否 `moon deprecate`（全模块） | ≤24h |
| 严重安全 / 供应链事件（无法短期修复） | 发布修复版 + `moon deprecate WangYF0829/moonmux --reason "..."`（先 `--dry-run` 预览） | 立即，≤24h 内公告 |
| 需要恢复弃用 | `moon deprecate WangYF0829/moonmux --undo` | 按需 |

**deprecate 演练（每 6 个月或每次 major / minor 发布前）**：

```bash
# 1) 只预览，不改注册表（必须做 dry-run 留档）
moon deprecate WangYF0829/moonmux --reason "演练：验证弃用预览流程，不实际执行" --dry-run

# 2) 真实弃用（仅在回滚时执行，需发布负责人确认）
moon deprecate WangYF0829/moonmux --reason "<原因>"

# 3) 恢复
moon deprecate WangYF0829/moonmux --undo
```

演练输出保存到 `_review/evidence/release/<date>-deprecate-dryrun.log`，并在 `docs/releases/` 记一行「回滚演练：<date> 通过 / 失败」。

> 首次演练记录（2026-11-12，只预览未修改注册表）见 [`docs/releases/v0.9.3.md`](docs/releases/v0.9.3.md) §7：
> `moon deprecate WangYF0829/moonmux --reason "…" --dry-run` → exit 0，逐版本打印 "Would deprecate …"，演练后全部版本仍 `yanked=false`。

## 7. 发布后监控（24h / 7 天）

- **24h**：`moon view WangYF0829/moonmux --json` 的 checksum 与发布记录一致；干净工程重新安装；issue / 讨论区无安装失败。
- **7 天**：安装失败率（以反馈 / issue 计）、兼容性回归、下载量（`moon view` 的 Downloads）；有回归时按 §6 处置并写进发布记录。
- **触发复验**：新版本发布、安全公告、工具链升级、`supported_targets` 变更。

## 8. 相关文件与内部归档

- [`CHANGELOG.md`](CHANGELOG.md)：Keep a Changelog 结构（`Unreleased` + Added / Changed / Fixed / Deprecated / Removed / Security）。
- [`docs/releases/`](docs/releases/)：逐版本发布记录（含 zip sha256）。
- [`NOTICE`](NOTICE) / [`THIRD_PARTY.md`](THIRD_PARTY.md)：许可声明与第三方依赖清单（`LL728/moonopus` 含 BSD-3-Clause 表数据组件；`moonbitlang/x` 无 LICENSE 文本为上游缺口）。
- 发布前脚本：`scripts/preflight_release.sh`（一键预检：worktree/版本/格式/check/test all/api-diff/api-docs/覆盖率≥80/PII/包内容/SBOM/bench/fuzz/smoke；支持 `--allow-dirty` / `--skip-*`）、`scripts/check_version.sh`（11 项版本一致性）、`scripts/check_api_diff.sh`（`.mbti` diff，0/1/2 退出码，CI 已 `--target-all`）、`scripts/check_api_docs.sh`（公开 API `///` 覆盖门禁，≥95%、未文档 0）、`scripts/check_coverage.sh`（库层 ≥88% / 总 ≥80% 覆盖率门限）、`scripts/check_package.sh`（包清单/体积/worktree/密钥）、`scripts/check_pii.sh`（PII）、`scripts/gen_sbom.sh`（SBOM/发布材料归档）、`scripts/bench-baseline.json` + `scripts/bench.mjs`（基线阈值与平台守卫）。
- 评估 / 证据 / 风险文档：[`docs/releases/v0.9.3-install-sampling.md`](docs/releases/v0.9.3-install-sampling.md)（G1-01 冷装抽样 30/30，中位 1980 ms）、[`docs/dependency-assessment.md`](docs/dependency-assessment.md)（G1-B2 = DEGRADED、退出预案、工具链 pin 结论）、[`docs/known-issues.md`](docs/known-issues.md)（KI-01..05，含 `moonvorbis` 上游 issue 草稿）、[`docs/security/pii-advisory.md`](docs/security/pii-advisory.md)（历史 PII 风险接受）。
- API 基线归档：每次发布归档上一版 `moon info` 生成的逐包 `.mbti` + manifest sha256（v0.9.3 基线已归档于 `_review/fix/api-baseline/`（`manifest.json` + `SHA256SUMS`）；
  对外发布时建议把该归档与发布 zip 一起作为 Release 附件）。
- 可复现性裁决记录：内部验收报告 §2.3（保留工作区字节 vs 标准 checkout 的结论来源）。

## 9. 已知偏差登记（短期不可消除，随发布记录接受）

| 偏差 | 影响 | 补偿 / 接受方式 |
|---|---|---|
| 单人维护者、无双人复核 | 无法满足「双人复核」 | §5 例外登记 + CI 门禁 + 检查单留档 + 发布后 24h 复测 |
| 无 PR 流程 / 分支保护 | 仓库为单人直推（0 个 PR），无法提供「PR 必需检查不可跳过」的 PR 侧证据；当前权限下未启用分支保护 | 每次 push 都跑全量 CI（`paths-ignore` 已移除，文档也触发）；发布前 `preflight_release.sh` + 手工检查单补偿；作为单人项目例外登记 |
| v0.9.6 CI workflow 无效（已修复） | v0.9.6 tag 的 `ci.yml` `on:` 段重复键，两次 run 在创建 job 前失败（run 83/84，0 jobs）；失败保留未删除 | v0.9.7 删除重复键并通过 12-job CI；发布记录加勘误；建议使用 0.9.7 |
| GitHub Release 附件需人工上传 | 自动化流水线无法附带 zip / sha256 | 本检查单强制项；发布后立即核对附件与 body sha256 |
| bench 跨平台不可直接比较 | Linux CI 与 Windows 基线的绝对耗时不同 | 平台守卫：平台不匹配只 WARN；CI 共享 runner 放宽到 50%，本地/专用 runner 用 10% |
| bench 噪声（小操作 / I/O） | ~15–22 ms 操作受进程启动抖动影响；`demux` I/O 抖动 ±10 ms | 小操作绝对值下限 4 ms；基线取多轮 min 上界；`demux` 取 6 次测量上界 80.0 ms（见 `threshold_policy`） |
| `moon publish --dry-run` 退出码语义（moon 0.1.20261012） | 409（已发布）/ 202（未发布）均可能非零退出 | 以服务器返回文本判定（§2）；CI `publish-dry-run` job 已按此接线 |
| 覆盖率 CI 阈值余量 | 本地总 **82.57%** / 库层 91.82%；CI Linux 实测总 **80.11%**、未覆盖行 **697**（阈值 800）——**仅余 0.11pp** | qa 持续补测降低未覆盖行；新增防御分支须同步补测试；本版将该余量登记为最紧 SHOULD 风险 |
| G1-B2 依赖维护性 = **DEGRADED** | 3/3 依赖近 12 个月有发布且未弃用、但 3/3 无 SECURITY.md、2/3 bus factor=1 且无接管预案；`moonvorbis` 有 `unsafe_get` 上游缺陷 | 已登记并给出退出预案（fork/替换/降级）与安全披露渠道评估，见 [`docs/dependency-assessment.md`](docs/dependency-assessment.md)；KI-01 跟踪上游 issue；发布记录注明该状态 |
| 上游依赖导致的风险（总表） | `moonvorbis` / `moonopus` / MoonBit 工具链 / `moonbitlang/x` 的根因风险，moonmux 无法在自身代码内完全修复 | **完整表 R-UP-01..05、边界声明、关闭条件与“上游 issue 尚未提交”状态**见 [`docs/known-issues.md`](docs/known-issues.md)「上游依赖导致的风险」；发布记录必须引用该节，不得宣称 G1-M06 已通过 |
| 工具链 pin 依赖第三方归档 | 官方固定版本 URL 全线 403；CI 改用 `chawyehsu/moonbit-binaries` 归档的官方构建，并以仓库内 SHA-256 校验 | **已 pin `0.1.20261117`**（`.github/actions/setup-moonbit`，fail-closed，不回落 latest）；残留归档来源/可用性风险；结论与复验命令见 [`docs/dependency-assessment.md`](docs/dependency-assessment.md) §4 |
| 历史发布包 PII（0.2.0–0.9.1） | 作者联系方式存在于不可撤回的历史版本与 git 历史 | 已接受风险并发布公告：[`docs/security/pii-advisory.md`](docs/security/pii-advisory.md) + [`docs/known-issues.md`](docs/known-issues.md) KI-03；当前版本已干净，`check_pii.sh` 纳入发布检查单 |
| 真实 Vorbis 解码慢（依赖缺陷） | debug native 下 `testdata/vorbis_sample.ogg` to-wav 约 92.6 s（O(n²) IMDCT + Huffman 逐 bit 线性扫表）；release/Linux 未实测 | 属依赖解码器真实慢，非预算误拒；长文件建议 `split`；预算只做放大比拒绝 |
| `to-wav` 残余风险 | ① Huffman 码长表有效性由解码器判定；② floor1 `x` 序等语义不在 gate 覆盖；③ 内存模型为上界估算；④ **CPU 双预算 debug 上限约 18 ms/字节**（真实样本 92.6 s 接近硬约束；余量 IMDCT ×1.43 / Huffman ×1.49），高码长 + 多符号合法流可能被误拒；⑤ 依赖 `moonvorbis` 的 `unsafe_get` | README 能力边界声明「不建议直接处理不可信输入」；gate v3 已修复 RT4-01（6,511 B PoC exit 1 / 0.87 s）并回归 RT3 19 组、此前 75 组红队 PoC；后续可细化 Huffman 成本或推动依赖 O(1) 查表 |





