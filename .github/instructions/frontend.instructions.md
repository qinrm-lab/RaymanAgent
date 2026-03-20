---
applyTo: "**/*.{ts,tsx,js,jsx,css,scss,html}"
description: "Use when editing frontend, prompt UI, browser-facing assets, Playwright-visible flows, or web application code in Rayman-managed workspaces."
---

# Rayman Frontend Instructions

- Optimize for accessibility, keyboard safety, and low-friction automation.
- Favor deterministic selectors and stable UI copy for Playwright and agent-driven flows.
- Keep confirmation flows explicit; avoid surprise popups, window spawning, or modal spam.
- When UI text changes affect automation, update related Playwright or manual verification notes.
- Minimize one-off style drift; prefer shared primitives and consistent component states.
