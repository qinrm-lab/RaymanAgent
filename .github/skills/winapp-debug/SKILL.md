---
name: winapp-debug
description: Debug Windows desktop UI flows with Rayman WinApp-first evidence
---

Use this skill for WinForms, WPF, MAUI(Windows), dialogs, or UIA failures.

- Prefer Rayman WinApp MCP when available.
- Capture the concrete failing interaction before changing application code.
- If MCP is unavailable, fall back to `rayman.ps1 ensure-winapp` then `rayman.ps1 winapp-test`.
- Keep desktop fixes narrowly scoped.
