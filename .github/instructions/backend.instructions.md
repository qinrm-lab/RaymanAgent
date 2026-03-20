---
applyTo: "**/*.ps1"
description: "Use when editing Rayman PowerShell automation, setup/init scripts, watchers, dispatch, repair, release, or other backend orchestration scripts."
---

# Rayman Backend Instructions

- Keep scripts idempotent and safe to re-run; prefer guards over duplicate side effects.
- Use strict mode, explicit error handling, and user-visible diagnostics for degraded behavior.
- Preserve non-interactive defaults; when manual action is required, route through `request_attention.ps1` instead of spawning intrusive UI.
- When changing watcher, dispatch, setup, repair, or runtime behavior, update both source and `.Rayman/.dist` copies in the same change.
- After non-trivial backend changes, validate the affected command path and summarize what was exercised.
