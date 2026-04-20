# RaymanAgent

[![CI](https://github.com/qinrm-lab/RaymanAgent/actions/workflows/rayman-test-lanes.yml/badge.svg)](https://github.com/qinrm-lab/RaymanAgent/actions/workflows/rayman-test-lanes.yml)
[![Nightly Smoke](https://github.com/qinrm-lab/RaymanAgent/actions/workflows/rayman-nightly-smoke.yml/badge.svg)](https://github.com/qinrm-lab/RaymanAgent/actions/workflows/rayman-nightly-smoke.yml)

RaymanAgent is the source workspace for Rayman: a Windows-first workspace automation toolkit for setup/bootstrap, release gates, Codex and Copilot collaboration, shared LAN workers, and repeatable host/browser debugging flows.

## What It Covers

- Rayman CLI and workspace bootstrap assets under `.Rayman/`
- Release discipline, contract validation, and CI lanes
- Codex/Copilot instructions, capability assets, and agentic docs
- Shared Windows worker discovery, staged sync, exec, and debug flows
- VS Code bootstrap, watcher lifecycle, and project gate automation

## Quick Start

```bash
bash ./.Rayman/init.sh
```

On Windows, the minimal setup path is:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\.Rayman\setup.ps1
```

## Docs

- Main docs: [`.Rayman/README.md`](./.Rayman/README.md)
- Release requirements: [`.Rayman/RELEASE_REQUIREMENTS.md`](./.Rayman/RELEASE_REQUIREMENTS.md)
- Feature inventory: [`.Rayman/release/FEATURE_INVENTORY.md`](./.Rayman/release/FEATURE_INVENTORY.md)
- 2026 roadmap: [`.Rayman/release/ENHANCEMENT_ROADMAP_2026.md`](./.Rayman/release/ENHANCEMENT_ROADMAP_2026.md)

## Notes

- This repository is the authored source workspace. External consumer workspaces usually receive the distributable `.Rayman/` snapshot instead of the whole repo.
- The repository may contain local/runtime noise that is intentionally excluded from Git; authoritative product docs live under `.Rayman/`.
