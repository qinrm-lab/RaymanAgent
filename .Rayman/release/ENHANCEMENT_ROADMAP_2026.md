# Rayman Enhancement Roadmap 2026

本路线图基于当前 tracked 功能面，目标是在不收缩既有 CLI 的前提下，为 Rayman 增加更清晰的 capability 治理、更强的 CI/provenance、更现代的 browser/winapp 调试路径，以及可选的 hosted agent 增强。

原则：

- 既有 CLI 和默认本地链路保持兼容。
- 新平台能力默认标记为 `optional / hosted / policy-dependent`。
- 文档、workflow、contract、`.dist` 镜像和 repair 清单必须一起更新。
- Hermes-inspired upgrade program 固定按 `P0 -> P1 -> P2` 推进：先收口 context safety / recall / skills trust，再补 event hooks / rollback UX / prompt batch eval，最后再看更高阶的平台增强。

## P0: Immediate Documentation And Contract Hardening

| Area | Change | Why now | Regression surfaces |
| --- | --- | --- | --- |
| Context safety and recall | 在 `planner_v1` 默认链路前增加 `context-audit`，并把 session-backed recall 收进 `memory-search` | prompt/context 资产越来越多，必须先拦截 prompt override、secret exfiltration cue 和 oversized context；同时把历史 session 变成可搜索工程记忆 | `context_audit.ps1`, `dispatch`, `review_loop`, `memory-search`, SQLite FTS5 fallback, `.RaymanAgent/agentic/*` |
| Skills trust and distribution | 用 `.Rayman/config/skills_registry.json` 统一 bundled/external skill root 的 trust、allowlist、duplicate policy | `skills.auto.md` 需要明确区分 managed bundled skills 和不受信任 external skills，避免 prompt 污染 | `manage_skills.ps1`, `detect_skills.ps1`, `generate_context.ps1`, agent contract, `.dist` parity |
| Review baseline | 维护 `.Rayman/release/FEATURE_INVENTORY.md` 与本路线图 | 把“功能盘点”和“增强建议”变成 tracked 资产，而不是聊天记录 | `check_agent_contract.ps1`, governance docs tests, dist parity |
| Agentic pipeline contract | 把 `planner_v1` 默认链路、`.RaymanAgent/agentic/*`、requirements gate、first-pass telemetry 作为同一组受管资产维护 | 默认路径已经切到 `plan -> tool/subagent select -> execute -> reflect -> verify -> doc close`，必须防止 runtime/文档/契约再次漂移 | `dispatch`, `review_loop`, `validate_requirements.sh`, `first_pass_report.ps1`, dist parity |
| Interaction mode governance | 把工作区级 `RAYMAN_INTERACTION_MODE`、菜单入口、context/prompt 注入和 delegated preamble 作为同一组受管资产维护 | “full-auto” 容易被误解成“可以替用户决定需求”；需要明确多路径/歧义时何时先给 plan | `rayman.ps1`, `.rayman.env.ps1`, `generate_context.ps1`, `inject_codex_fix_prompt.ps1`, `dispatch`, docs parity |
| Instruction layering | 收紧 `.github/copilot-instructions.md`，把 repository-wide、path-specific、model policy、review docs 的职责分开 | 减少 `.github` 规则重复、冲突和 typo 漂移 | agent contract, human review |
| Hosted platform boundary | 维护 `.github/model-policy.md`，明确 Auto model selection / custom agents / hosted MCP 只做文档与检测 | 避免把平台能力误写成 repo 保证 | agent contract, README links |
| README parity | 修正 watcher / alert 默认值、补 review docs 和 platform-opportunity 链接 | 当前 README 容易成为运维与功能认知入口，漂移成本高 | README review, host smoke indirect |
| Dist / repair parity | 新增治理文档纳入 `.dist` 与 repair 包 | 保证 fresh copy 与 source workspace 看到同一份审查基线 | `assert_dist_sync.*`, `ensure_complete_rayman.*` |

## P1: Optional Capability Upgrades

| Area | Change | External signal | Acceptance shape |
| --- | --- | --- | --- |
| Event hooks and rollback UX | 增加 `.Rayman/config/event_hooks.json` 与 `rayman.ps1 rollback`，把 context/skills/dispatch/review/memory/session/rollback 统一写入 JSONL 事件流，并给 session-backed checkpoints 提供 list/diff/restore UX | Hermes-style observability/value chain 更依赖 first-class events 和可恢复 checkpoint UX | default sink stays local JSONL; rollback only covers session-backed checkpoints; `snapshot` archive semantics stay unchanged |
| Prompt batch eval | 给 `rayman.ps1 prompts` 增加 `-Action eval`，由 `.Rayman/config/prompt_eval_suites.json` 和 `.RaymanAgent/agentic/evals.md` 承载 suite/index/acceptance | prompt assets 已经进入 repo 治理面，缺少 release-visible regression report | eval stays render/report-only by default; runtime reports must be reproducible and visible to release review |
| OpenAI / Codex | 在默认 `planner_v1` 之上，通过 delegated Codex 为长任务与 prompt 治理增加可选 background mode / compaction / prompt optimizer / `codex exec` 适配层 | OpenAI 已公开 Codex SDK / background mode / prompt optimizer，并强调本地 CLI / editor / cloud 连通 | default path stays local-first; optional features must auto-detect, flow through delegated Codex, and degrade to local fallback |
| Long-running work | 为长耗时分析/修复增加 background mode submit / poll / cancel / timeout 语义 | OpenAI Responses API 官方支持 background mode | new opt-in command or helper, explicit timeout diagnostics |
| Prompt governance | 对高价值 prompts 引入 prompt objects、prompt optimizer、eval dataset 闭环 | OpenAI 官方把 prompt objects / optimizer 作为提示资产治理路径 | report + eval dataset + no runtime breakage |
| LAN worker fleet | 在当前共享 worker staged-only 模型之上继续补 worker pairing / auth、多 worker 调度和更稳的 remote debug bootstrap | 当前 v1 已支持 multi-client staged-only；普通办公网/跨网段风险更高，且 `attached` 不提供共享并发保证 | keep single-active source binding + shared staged worker default; add auth before claiming wider network support |
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

- P0 默认落地内容是 context safety、session recall、skills trust/distribution。
- P1 默认落地内容是 event hooks、rollback UX、prompt batch eval。
- 默认先做 P0 文档、契约和 parity 收口。
- P1 只做 opt-in，不直接改变现有默认执行路径。
- P2 需要单独的组织/平台决策，不在仓库里伪装成默认可用。
