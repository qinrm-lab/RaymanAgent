---
name: browser-e2e-debug
description: Reproduce browser issues with Playwright-first evidence and bounded fixes
---

Use this skill for browser, UI, recording, or E2E failures.

- Reproduce before fixing.
- Capture concrete evidence: steps, selectors, console, network, screenshots.
- Prefer Playwright MCP when available.
- If MCP is unavailable, fall back to `rayman ensure-playwright` then `rayman pwa-test`.
