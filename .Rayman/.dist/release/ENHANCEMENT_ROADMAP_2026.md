# Rayman Enhancement Roadmap 2026

本路线图基于当前 tracked 功能面，目标是在不收缩既有 CLI 的前提下，为 Rayman 增加更清晰的 capability 治理、更强的 CI/provenance、更现代的 browser/winapp 调试路径，以及可选的 hosted agent 增强。

原则：

- 既有 CLI 和默认本地链路保持兼容。
- 新平台能力默认标记为 `optional / hosted / policy-dependent`。
- 文档、workflow、contract、`.dist` 镜像和 repair 清单必须一起更新。

## P0: Immediate Documentation And Contract Hardening

| Area | Change | Why now | Regression surfaces |
| --- | --- | --- | --- |
| Review baseline | 维护 `.Rayman/release/FEATURE_INVENTORY.md` 与本路线图 | 把“功能盘点”和“增强建议”变成 tracked 资产，而不是聊天记录 | `check_agent_contract.ps1`, governance docs tests, dist parity |
| Agentic pipeline contract | 把 `planner_v1` 默认链路、`.RaymanAgent/agentic/*`、requirements gate、first-pass telemetry 作为同一组受管资产维护 | 默认路径已经切到 `plan -> tool/subagent select -> execute -> reflect -> verify -> doc close`，必须防止 runtime/文档/契约再次漂移 | `dispatch`, `review_loop`, `validate_requirements.sh`, `first_pass_report.ps1`, dist parity |
| Instruction layering | 收紧 `.github/copilot-instructions.md`，把 repository-wide、path-specific、model policy、review docs 的职责分开 | 减少 `.github` 规则重复、冲突和 typo 漂移 | agent contract, human review |
| Hosted platform boundary | 维护 `.github/model-policy.md`，明确 Auto model selection / custom agents / hosted MCP 只做文档与检测 | 避免把平台能力误写成 repo 保证 | agent contract, README links |
| README parity | 修正 watcher / alert 默认值、补 review docs 和 platform-opportunity 链接 | 当前 README 容易成为运维与功能认知入口，漂移成本高 | README review, host smoke indirect |
| Dist / repair parity | 新增治理文档纳入 `.dist` 与 repair 包 | 保证 fresh copy 与 source workspace 看到同一份审查基线 | `assert_dist_sync.*`, `ensure_complete_rayman.*` |

## P1: Optional Capability Upgrades

| Area | Change | External signal | Acceptance shape |
| --- | --- | --- | --- |
| OpenAI / Codex | 在默认 `planner_v1` 之上，通过 delegated Codex 为长任务与 prompt 治理增加可选 background mode / compaction / prompt optimizer / `codex exec` 适配层 | OpenAI 已公开 Codex SDK / background mode / prompt optimizer，并强调本地 CLI / editor / cloud 连通 | default path stays local-first; optional features must auto-detect, flow through delegated Codex, and degrade to local fallback |
| Long-running work | 为长耗时分析/修复增加 background mode submit / poll / cancel / timeout 语义 | OpenAI Responses API 官方支持 background mode | new opt-in command or helper, explicit timeout diagnostics |
| Prompt governance | 对高价值 prompts 引入 prompt objects、prompt optimizer、eval dataset 闭环 | OpenAI 官方把 prompt objects / optimizer 作为提示资产治理路径 | report + eval dataset + no runtime breakage |
| Browser debugging | 把 trace 变成一等 artifact；Playwright setup/auth 收敛到 projects + dependencies | Playwright 官方强调 trace viewer、projects、dependencies、UI mode | failing browser jobs always publish trace |
| Desktop automation | 新增 Appium Windows Driver / Appium 3 backend，保留 WinAppDriver fallback | Appium Windows Driver 官方已明确 Appium 3 路线；其 README 也提醒 WinAppDriver 长期未维护 | backend probe + fallback + failure diagnosis |
| Provenance | 为关键制品增加 artifact attestations，并补 verify 链路 | GitHub Actions 官方已提供 artifact attestations | generate + verify both required before claiming support |

## P2: Platform-Dependent Expansion

| Area | Change | Risk | Rollout rule |
| --- | --- | --- | --- |
| Cloud orchestration | Slack / Codex 云端任务委派 | 依赖组织权限、计费和 hosted environment policy | feature flag + whitelist only |
| Remote MCP | trusted read-only remote MCP 治理规范 | 容易扩大权限边界和数据暴露面 | docs/search/research only first |
| Organization policy | GitHub Copilot Auto model selection / custom agents 的组织级策略说明与检测 | repo 无法强制平台租户配置 | doc + detection only |
| Workflow dedupe | 把现有 workflows 进一步拆成 reusable workflows / composite actions | CI 结构重排风险高于单纯文档治理 | do after current lanes have stable baselines |

## Official Sources Used For 2026 Opportunities

- OpenAI Codex GA / SDK / GitHub Action: https://openai.com/index/codex-now-generally-available/
- OpenAI background mode: https://developers.openai.com/api/docs/guides/background
- OpenAI prompting / prompt objects: https://developers.openai.com/api/docs/guides/prompting
- OpenAI prompt optimizer: https://developers.openai.com/api/docs/guides/prompt-optimizer
- OpenAI MCP / remote MCP guidance: https://developers.openai.com/api/docs/mcp
- GitHub custom instructions precedence: https://docs.github.com/en/copilot/concepts/prompting/response-customization
- GitHub custom agents: https://docs.github.com/en/copilot/tutorials/customization-library/custom-agents/your-first-custom-agent
- GitHub Auto model selection: https://docs.github.com/en/copilot/concepts/auto-model-selection
- GitHub artifact attestations: https://docs.github.com/en/actions/concepts/security/artifact-attestations
- GitHub reusable workflows: https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations
- Playwright trace viewer: https://playwright.dev/docs/trace-viewer
- Playwright authentication / UI mode context: https://playwright.dev/docs/auth
- Appium Windows Driver / Appium 3 notes: https://github.com/appium/appium-windows-driver

## Rollout Defaults

- 默认先做 P0 文档、契约和 parity 收口。
- P1 只做 opt-in，不直接改变现有默认执行路径。
- P2 需要单独的组织/平台决策，不在仓库里伪装成默认可用。
