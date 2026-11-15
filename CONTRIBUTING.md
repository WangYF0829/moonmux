# 贡献指南（Contributing）

感谢关注 moonmux。项目以“容器层可验证、失败不产出半成品”为第一原则；提交前请先跑通本地门禁。

## 开发环境

- MoonBit 工具链：`moon 0.1.20261012` / `moonc 0.10.15`（以 `moon version --all` 为准）；
- Windows 需要 MSVC（native 构建），Linux 需要 C 工具链；
- 可选：Node.js（`scripts/bench.mjs` / `scripts/fuzz.mjs`）、ffmpeg/ffprobe（`scripts/verify_mp4.sh`）、
  Git Bash（Windows 上的 `scripts/*.sh`）。

## 提交前检查

```bash
moon check --deny-warn
moon fmt --check
moon test --deny-warn --target all      # native / wasm-gc / js
bash scripts/smoke.sh                   # 端到端
node scripts/fuzz.mjs --iterations 400 --seed 20261109
bash scripts/preflight_release.sh --allow-dirty --skip-bench --skip-coverage
```

完整发布门禁见 [`RELEASING.md`](RELEASING.md)；覆盖率与 API 文档门禁分别由
`scripts/check_coverage.sh`、`scripts/check_api_docs.sh` 执行。

## 代码与测试约定

- **纯函数优先**：`cli/` 只做解析，`cmd/main/` 只做 I/O 与退出码映射；容器层
  （`ogg` / `wav` / `codec` / `manifest` / `mp4`）零三方依赖。
- **公开 API 变更**：新增/修改 `pub` 前先跑 `bash scripts/check_api_diff.sh`；删除或改签名必须升 minor
  并在 `CHANGELOG.md` 给出迁移说明。
- **测试分层**：白盒 `*_wbtest.mbt` 可访问私有；黑盒 `*_test.mbt` 只用公开 API（`for "test"` 导入）。
  容器格式改动至少补一条边界用例（空/截断/超长/数值溢出）。
- **错误模型**：数据错误用 `Result`/`Option` 或 `fail_data`（exit 1）；用法、I/O、能力边界用
  `fail`（exit 2）；写命令失败不得留下半成品。
- **不要提交**：`_build/`、`*.mbti`、`pkg.generated.mbti`、日志、临时样本、凭据。
- 提交信息建议采用 `fix:` / `feat:` / `test:` / `docs:` / `ci:` 前缀；一个提交只做一类变更。

## 安全与行为

- 安全问题**不要**开公开 Issue，按 [`SECURITY.md`](SECURITY.md) 私密报告。
- 讨论保持技术化；不提交针对个人的攻击性内容。
- 贡献代码默认按 Apache-2.0 授权（与 [`LICENSE`](LICENSE) 一致）。

## 发布

发布由维护者按 [`RELEASING.md`](RELEASING.md) 执行：版本一致性 → 全量预检 → 干净 worktree →
`moon publish --dry-run` → 发布 → 干净工程 install gate → GitHub Release 附件（zip / SHA256SUMS / SBOM）。
