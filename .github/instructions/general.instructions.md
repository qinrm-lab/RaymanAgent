---
description: "Use when working on Rayman governance files, AGENTS.md, copilot-instructions.md, prompts, config JSON, context generation, release rules, or repository automation docs."
---

# Rayman General Instructions

- Treat Rayman as an agent platform: preserve deterministic flows, auditable decisions, and rollback guidance.
- Keep source and `.Rayman/.dist` mirrors aligned for shared runtime and agent assets whenever copied distributions depend on the same behavior.
- Prefer small, verifiable contracts over broad prose; when adding a rule, also add a report, script check, or validation note when practical.
- If you touch `.github/`, `.Rayman/config/`, `AGENTS.md`, or governance docs, call out which downstream files must stay in sync.
- `.github/model-policy.md` is the human-readable hosted model policy; keep it aligned with `.Rayman/config/model_routing.json`, `.Rayman/config/codex_agents/*.toml`, and Copilot/Codex-facing docs.
- `.Rayman/release/FEATURE_INVENTORY.md` and `.Rayman/release/ENHANCEMENT_ROADMAP_2026.md` are tracked review assets; update them when command catalog, workflows, release lanes, or capability boundaries materially change.
- Agent capabilities are declared in `.Rayman/config/agent_capabilities.json`; `.codex/config.toml` is a generated workspace artifact and now carries Rayman-managed capability, project-doc, profile, and subagent blocks.
- Rayman-managed subagent roles are fixed to `rayman_explorer`, `rayman_reviewer`, `rayman_docs_researcher`, `rayman_browser_debugger`, `rayman_winapp_debugger`, and `rayman_worker`.
- Read the current workspace interaction mode from `.Rayman/CONTEXT.md` or `RAYMAN_INTERACTION_MODE` before deciding whether to ask clarifying questions or present a plan.
- `detailed` means plan first for most meaningful ambiguity; `general` means plan first when outcome/scope/path/risk/test expectations change materially; `simple` means only high-risk ambiguity must stop the run.
- When you stop because the prompt is not clear enough, always provide concrete options plus explicit acceptance criteria before proceeding. This is a Rayman rule even outside Codex Plan Mode.
- `full-auto` approves code changes, but it does not authorize guessing user intent when multiple meaningful implementation paths exist.
- OpenAI/API/model/docs tasks should prefer OpenAI Docs MCP; browser/web/e2e tasks should prefer Playwright MCP; WinForms / MAUI(Windows) / desktop / UIA tasks should prefer Rayman WinApp MCP. Document the Rayman fallback path when MCP is unavailable.
- `.github/agents/*.agent.md`, `.github/skills/*/SKILL.md`, and `.github/prompts/*.prompt.md` are Rayman-managed capability assets; keep them aligned with `dispatch`, `review_loop`, and the capability report.
- GitHub-only features such as Copilot Memory, Auto model selection, and GitHub.com custom agents may be documented or detected, but are not treated as repo-enforced runtime guarantees.
- Do not silently weaken requirements-reading, full-auto, release-gate, or rollback guarantees.
- On Windows, keep approval-sensitive PowerShell automation converged on `powershell.exe -Command` / `-File`; only fall back to `pwsh` when PowerShell 7 compatibility or a non-Windows host is required.
