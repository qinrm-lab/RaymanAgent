# Rayman Context

> Artifact: local-generated
> Workspace: RaymanAgent
> Skills status: generated

## Workspace Snapshot

- Root: `.`
- Top-level entries: .gitattributes, .github, .gitignore, .Rayman, .RaymanAgent, .SolutionName, AGENTS.md

## Governance & Agent Assets

- AGENTS.md
- .github\copilot-instructions.md
- .RaymanAgent\.RaymanAgent.requirements.md
- .Rayman\config\agent_capabilities.json
- .Rayman\config\codex_multi_agent.json
- .Rayman\config\codex_agents\rayman_explorer.toml
- .Rayman\config\codex_agents\rayman_reviewer.toml
- .Rayman\config\codex_agents\rayman_docs_researcher.toml
- .Rayman\config\codex_agents\rayman_browser_debugger.toml
- .Rayman\config\codex_agents\rayman_winapp_debugger.toml
- .Rayman\config\codex_agents\rayman_worker.toml
- .Rayman\config\agent_router.json
- .Rayman\config\agent_policy.json
- .Rayman\config\model_routing.json
- .Rayman\scripts\agents\ensure_agent_capabilities.ps1
- .Rayman\scripts\agents\dispatch.ps1
- .codex\config.toml

## File Instructions

- backend.instructions.md
- frontend.instructions.md
- general.instructions.md

## Script Domains

- agents
- alerts
- backup
- ci
- codex
- deploy
- dynproxy
- fast-init
- mcp
- memory
- project
- proxy
- pwa
- release
- repair
- requirements
- skills
- state
- telemetry
- testing
- utils
- watch
- windows
- worker

## Agent Config

- agent_capabilities.json
- agent_policy.json
- agent_router.json
- agentic_pipeline.json
- codex_multi_agent.json
- command_catalog.tsv
- model_routing.json
- review_loop.json
- system_slim_policy.json

## Auto Skills

- File: `.Rayman\context\skills.auto.md`
- Summary: # Skills（自动）

## Agent Capabilities

- Report: `.Rayman\runtime\agent_capabilities.report.md`
- Codex config: `.codex\config.toml`
- Summary: active capabilities, workspace trust, and readiness are environment-specific; inspect the runtime report instead of committing those values into `.Rayman\CONTEXT.md`.

## Recommended Entry Points

<!-- RAYMAN:RECOMMENDED:BEGIN -->
- `[ windows-only ]` `rayman.ps1 watch-auto`：Start background watchers (prompt-watch + attention-watch).
- `[ windows-only ]` `rayman.ps1 watch-stop`：Stop background watchers and helper processes.
- `[ all ]` `rayman dispatch`：Route a task to codex, copilot, or local backends.
- `[ all ]` `rayman codex`：Manage Rayman-scoped Codex accounts, switching, and CLI execution.
- `[ windows-only ]` `rayman.ps1 worker`：Manage LAN Rayman Workers, remote sync, exec, debug, and upgrade.
- `[ pwsh-only ]` `rayman.ps1 agent-capabilities`：Sync or inspect Rayman-managed Codex capabilities.
- `[ pwsh-only ]` `rayman.ps1 review-loop`：Run the dispatch plus test-fix review loop.
- `[ pwsh-only ]` `rayman.ps1 release-gate`：Run release readiness checks and reports.
- `[ pwsh-only ]` `rayman.ps1 context-update`：Regenerate local context and auto-skill artifacts.
- `[ pwsh-only ]` `rayman.ps1 one-click-health`：Force daily health check and refresh proxy health snapshot.
<!-- RAYMAN:RECOMMENDED:END -->
