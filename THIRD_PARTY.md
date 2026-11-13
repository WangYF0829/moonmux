# 第三方依赖与许可清单（THIRD_PARTY）

> 本文件登记 moonmux 的第三方依赖与许可，供再分发 / 合规审查使用。
> 版本以 [`moon.mod`](moon.mod) 的 `import` 为准；依赖树用 `moon tree` 复核。
> 自身许可：Apache-2.0（见 [`LICENSE`](LICENSE)）；版权声明见 [`NOTICE`](NOTICE)。

## 1. 运行时依赖（会进入构建，消费方 `moon add` 即引入）

| 组件 | 版本 | 许可证（SPDX） | 仓库 | 用途 | 备注 |
|---|---|---|---|---|---|
| **moonmux（本项目）** | 0.9.3 | Apache-2.0 | https://github.com/WangYF0829/moonmux | 容器层 / CLI / 转码管线 | 版权归 WangYF0829（王轶凡） |
| `moonbitlang/x` | 0.5.5 | Apache-2.0 | https://github.com/moonbitlang/x | `cmd/main` 用 `x/fs`、`x/sys`；`examples/ogg_info`、`examples/remux_ogg_to_mp4` 用 `x/fs`；亦为 `moonopus` / `moonvorbis` 的依赖 | **上游缺口**：包内无 `LICENSE` 文本文件，只有 `licenserc.toml`（Apache-2.0 头部声明）；许可信息以 `moon.mod` 的 `license = "Apache-2.0"` 与 `licenserc.toml` 为准，再分发时建议随包携带 Apache-2.0 全文 |
| `LL728/moonopus` | 0.2.2 | Apache-2.0（+ BSD-3-Clause 表数据） | https://github.com/Xcsa-ee/moonopus | `pipeline/` 的 Ogg Opus 解码（`to-wav` 的 Opus 路径） | ① 含 `LICENSE`（Apache-2.0）与 `LICENSE-LIBOPUS`；② `celt_tables.mbt` / `celt_mode.mbt` 含提取自 [xiph/opus](https://github.com/xiph/opus) 参考实现的表数据，按 **BSD-3-Clause** 使用（RFC 6716 §4.3.3 要求 bit-exact，规范未列出数值）；上游 `COPYING` 全文保留在依赖包内，再分发时须完整携带并保留版权声明；③ **身份链提示**：mooncakes 模块 owner 为 `LL728`，而仓库指向 `Xcsa-ee/moonopus`（`LL728/moonopus` 在 GitHub 为 404），引入/再分发时需注意该 fork/转移关系 |
| `LL728/moonvorbis` | 0.1.4 | Apache-2.0 | https://github.com/LL728/moonvorbis | `pipeline/` 的 Ogg Vorbis 解码（`to-wav` 的 Vorbis 路径） | 含 `LICENSE`（Apache-2.0）；**已知安全残余**：恶意码流可能触发解码器内存安全问题，`to-wav` 不应直接暴露给不可信输入（见 CHANGELOG `[0.9.2]` 已知残余与 `docs/releases/v0.9.3.md` §6） |

依赖树（`moon tree`，v0.9.3）：

```text
WangYF0829/moonmux@0.9.3
├─ LL728/moonopus    0.2.2 ─┬─ moonbitlang/x 0.5.5
├─ LL728/moonvorbis  0.1.4 ─┘
└─ moonbitlang/x     0.5.5
```

依赖全部为 Apache-2.0（兼容本项目 Apache-2.0），无 copyleft / 未知协议。

## 2. 构建 / 测试期外部工具（不随发布包分发）

| 工具 | 用途 | 是否随包分发 | 许可提示 |
|---|---|---|---|
| Node.js（`scripts/bench.mjs` / `scripts/fuzz.mjs`） | 性能基准、确定性变异测试 | 否（脚本随包，Node 由使用者自备） | Node.js 为 MIT；脚本本身无第三方 npm 依赖 |
| `ffmpeg` / `ffprobe`（`scripts/verify_mp4.sh`、CI mp4 job） | MP4 产物外部对账 | 否 | 由使用者/CI 自行安装，遵循其各自许可（LGPL/GPL 依构建而定） |
| Python 3（`scripts/measure.py`） | 本机内存测量辅助 | 否（`.moonignore` 已排除该脚本，不进发布包） | Python PSF License |
| `testdata/` 真实样本 | Ogg Opus / Vorbis 测试输入 | 是（`testdata/` 进包） | 由 ffmpeg（libopus / libvorbis）生成，仅用于测试，不含第三方受版权保护的音频内容 |

## 3. 许可文本位置与再分发注意事项

- 本项目自身：`LICENSE`（Apache-2.0 全文）+ `NOTICE`。
- 依赖许可文本位于各自 `.mooncakes/<user>/<module>/` 包内（`moonopus`：`LICENSE` + `LICENSE-LIBOPUS`；`moonvorbis`：`LICENSE`；`moonbitlang/x`：无 LICENSE 文本文件，见上）。
- 再分发本项目或基于它的二进制时，请同时保留：本项目 `LICENSE` / `NOTICE` / `THIRD_PARTY.md`，以及 `LL728/moonopus` 的 `LICENSE` 与 `LICENSE-LIBOPUS`（BSD-3 表数据条款要求保留版权声明与免责声明）。
- 本清单随发布流程核对：每次新增 / 升级依赖时更新本文件，并在 `RELEASING.md` 的发布前检查单中确认（当前 CI 尚未自动校验本文件与 `moon.mod` 的一致性——已知缺口）。
- 相关文档：依赖维护性评估（G1-B2 = DEGRADED、退出预案、工具链 pin 结论）见 [`docs/dependency-assessment.md`](docs/dependency-assessment.md)；已知问题与残余风险（KI-01..05，含 `LL728/moonvorbis` 的 `unsafe_get` 上游 issue 草稿）见 [`docs/known-issues.md`](docs/known-issues.md)；历史发布包 PII 风险接受见 [`docs/security/pii-advisory.md`](docs/security/pii-advisory.md)。

## 4. 复核记录

| 日期 | 复核人 | 结论 |
|---|---|---|
| 2026-11-13 | docs-release（发布文档整改） | 依赖未变（`moonbitlang/x@0.5.5` / `LL728/moonopus@0.2.2` / `LL728/moonvorbis@0.1.4`）；`moonopus` 包内 `LICENSE` + `LICENSE-LIBOPUS` 仍在，BSD-3-Clause 表数据表述准确；`moonbitlang/x` 仍无 LICENSE 文本（上游缺口未修复）；第 3 轮 Vorbis gate v3 只扩展本项目 codec 解析与预算模型，不引入依赖变更 |
| 2026-11-13（第 4 轮收尾） | docs-release | 再次核对 `moon.mod` 依赖无变化；gate v3 未新增第三方组件；`moonopus` BSD-3 表数据条款仍以 `LICENSE-LIBOPUS`（依赖包内）为准；NOTICE 无需变更 |
| 2026-11-13（第 5 轮最终） | docs-release | RT4-01（CPU 双预算）修复仅在本项目 `codec`/`pipeline` 内，依赖未变（`moonbitlang/x@0.5.5` / `LL728/moonopus@0.2.2` / `LL728/moonvorbis@0.1.4`）；`VorbisSetupInfo` 新增 `residue_vq_codewords` 为未发布 API，不引入依赖；moonopus BSD-3 表述与 x 上游缺口仍准确 |
| 2026-11-13（第 6 轮文档收尾） | docs-release | 依赖未变（3 个精确 pin）；本轮仅新增文档与门禁脚本（`check_api_docs.sh`/`check_coverage.sh`），不涉及第三方组件；已补 `docs/dependency-assessment.md`（G1-B2 DEGRADED）与 `docs/known-issues.md`（KI-01..05）链接；moonopus BSD-3 表数据条款仍准确 |
