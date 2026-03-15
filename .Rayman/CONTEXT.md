# Rayman Context

> Artifact: local-generated
> Workspace: RaymanAgent
> Skills status: generated

## Workspace Snapshot

- Root: `.`
- Top-level entries: .clinerules, .codex, .cursorrules, .env, .github, .gitignore, .rag, .Rayman, .rayman.env.ps1, .RaymanAgent, .SolutionName, .venv, .vscode, AGENTS.md

## Governance & Agent Assets

- AGENTS.md
- .github\copilot-instructions.md
- .RaymanAgent\.RaymanAgent.requirements.md
- .Rayman\config\agent_capabilities.json
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
- deploy
- dynproxy
- fast-init
- mcp
- project
- proxy
- pwa
- rag
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

## Agent Config

- agent_capabilities.json
- agent_policy.json
- agent_router.json
- command_catalog.tsv
- model_routing.json
- review_loop.json
- system_slim_policy.json

## Auto Skills

- File: `.Rayman\context\skills.auto.md`
- Summary: # Skills（自动）

## Agent Capabilities

- Report: `.Rayman\runtime\agent_capabilities.report.md`
- Active: openai_docs, web_auto_test
- Codex config: `.codex\config.toml`
- Workspace trust: `unknown` (workspace_not_found)
- Managed block present: `true`
- Playwright ready: `true` (summary_success)
- WinApp ready: `false` (host_not_windows)

## Recommended Entry Points

<!-- RAYMAN:RECOMMENDED:BEGIN -->
- `[ windows-only ]` `rayman.ps1 watch-auto`：Start background watchers (prompt-watch + attention-watch).
- `[ windows-only ]` `rayman.ps1 watch-stop`：Stop background watchers and helper processes.
- `[ all ]` `rayman dispatch`：Route a task to codex, copilot, or local backends.
- `[ pwsh-only ]` `rayman.ps1 agent-capabilities`：Sync or inspect Rayman-managed Codex capabilities.
- `[ pwsh-only ]` `rayman.ps1 review-loop`：Run the dispatch plus test-fix review loop.
- `[ pwsh-only ]` `rayman.ps1 release-gate`：Run release readiness checks and reports.
- `[ pwsh-only ]` `rayman.ps1 context-update`：Regenerate local context and auto-skill artifacts.
<!-- RAYMAN:RECOMMENDED:END -->

