# Rayman Model Policy

本文件描述 Rayman 对 hosted model selection 的治理边界。它是文档和检测依据，不会把平台能力伪装成仓库内强制托管能力。

## Boundary

- repository-managed：
  - `.Rayman/config/model_routing.json`
  - `.Rayman/config/codex_agents/*.toml`
  - `.github/instructions/*.instructions.md`
  - `.github/agents/*.agent.md`
  - `.github/prompts/*.prompt.md`
- hosted / policy-dependent：
  - Copilot Memory
  - GitHub.com custom agents UI
  - Auto model selection / model picker
  - hosted remote MCP policy

## Recommended Selection

### Use Auto model selection when

- 任务是常规实现、文档更新、低风险脚本整理或泛型仓库探索。
- 你更看重交互速度，而不是跨系统、跨语言、跨 workflow 的深推理。

### Prefer a stronger manually selected model when

- 任务涉及 release gate、security、signing、跨平台 setup/watch/repair、复杂 regression review。
- 需要同时理解 `.github` capability 资产、`.Rayman` runtime、workflow、release 契约。
- 需要做 architecture / rollout / rollback 设计，或要写 findings-first 的 review。

### Prefer a smaller / faster model when

- 任务是 inventory、上下文刷新、说明文档补链、命令目录整理、结构化搜索或单一文件的小修。
- 可以把工作拆成 bounded sidecar task，而不是一个大 patch。

## Current Rayman Defaults

- review prompt 路由由 `.Rayman/config/model_routing.json` 管理。
- Codex subagent / role 默认值由 `.Rayman/config/codex_agents/*.toml` 管理。
- OpenAI / model / SDK / docs 相关任务应优先走 OpenAI Docs MCP，而不是依赖过期记忆。
- browser / web / e2e 相关任务优先走 Playwright MCP；desktop / UIA / WinForms / WPF / MAUI(Windows) 相关任务优先走 Rayman WinApp MCP。

## Enforcement Rule

- 允许在 README、review docs、capability report 中记录 hosted 平台能力。
- 不允许把 hosted-only 能力写成仓库默认保证，也不允许在 repo 中伪造已托管配置已经存在。
- 任何 platform-opportunity 增强都应同时给出本地 fallback。
