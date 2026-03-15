---
description: "Use when working on Rayman governance files, AGENTS.md, copilot-instructions.md, prompts, config JSON, context generation, release rules, or repository automation docs."
---

# Rayman General Instructions

- Treat Rayman as an agent platform: preserve deterministic flows, auditable decisions, and rollback guidance.
- Keep source and `.Rayman/.dist` mirrors aligned for shared runtime and agent assets whenever copied distributions depend on the same behavior.
- Prefer small, verifiable contracts over broad prose; when adding a rule, also add a report, script check, or validation note when practical.
- If you touch `.github/`, `.Rayman/config/`, `AGENTS.md`, or governance docs, call out which downstream files must stay in sync.
- Agent capabilities are declared in `.Rayman/config/agent_capabilities.json`; `.codex/config.toml` is a generated workspace artifact and must stay consistent with that registry.
- OpenAI/API/model/docs tasks should prefer OpenAI Docs MCP; browser/web/e2e tasks should prefer Playwright MCP; WinForms / MAUI(Windows) / desktop / UIA tasks should prefer Rayman WinApp MCP. Document the Rayman fallback path when MCP is unavailable.
- Do not silently weaken requirements-reading, full-auto, release-gate, or rollback guarantees.
