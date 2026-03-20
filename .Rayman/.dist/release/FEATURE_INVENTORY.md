# Rayman Feature Inventory

本文件是 RaymanAgent 当前 tracked 仓库的功能账本，用于做整仓审查、增强优先级讨论和发布前回归对照。

- CLI 入口仍以 `.Rayman/config/command_catalog.tsv` 为准。
- 用户面说明仍以 `.Rayman/README.md` 与 `.Rayman/RELEASE_REQUIREMENTS.md` 为准。
- workflow / capability 面仍以 `.github/workflows/*.yml`、`.github/agents/*.agent.md`、`.github/skills/*/SKILL.md`、`.github/prompts/*.prompt.md` 为准。

## Status Labels

- `stable`：默认行为、入口、测试和分发镜像基本一致。
- `drifting`：代码、README、workflow、copy/distribution 或契约面存在已知漂移风险。
- `under-tested`：功能存在，但高风险路径的 host / contract / release 覆盖不足。
- `platform-opportunity`：本地能力可用，但 2026 平台能力可显著增强体验或交付质量。

## 1. Entrypoints And Setup

| Cluster | Public entrypoints | Default behavior | Runtime / host dependencies | Existing coverage | Status |
| --- | --- | --- | --- | --- | --- |
| Setup bootstrap | `rayman init`, `init.sh`, `init.ps1`, `init.cmd`, `setup.ps1` | 初始化工作区、准备 Git、requirements、workflow、context、watch/bootstrap 默认值 | `bash`, `powershell.exe`, `git`, optional `gh`, optional WSL | `copy-self-check`, `host-smoke`, `release-gate`, `common.workspace.Tests` | `stable` |
| CLI surface | `rayman`, `rayman.ps1`, `commands.txt`, README commands block | 命令目录驱动 help、README 命令块和 CLI parity | `bash`, `pwsh`/`powershell.exe` | `command_catalog.Tests`, `verify_cli_parity.ps1`, `host-smoke` | `stable` |
| Workspace hygiene | setup SCM ignore / tracked-noise block / dist parity | source workspace 默认只忽略本地生成物，external workspace 默认忽略整套 Rayman 资产 | `git`, `.git/info/exclude`, `.gitignore` | `contract_scm_tracked_noise.sh`, `assert_dist_sync.*`, `common.workspace.Tests` | `stable` |

## 2. Watch / Alerts / Lifecycle

| Cluster | Public entrypoints | Default behavior | Runtime / host dependencies | Existing coverage | Status |
| --- | --- | --- | --- | --- | --- |
| Shared watcher host | `win-watch.ps1`, `watch-auto`, `watch-stop` | Windows 自动路径收敛到共享 watcher；默认 prompt sync 开启，attention / auto-save 默认关闭 | Windows host, PowerShell, owner PID bookkeeping | `watch_lifecycle.Tests`, `vscode_folder_open_bootstrap.Tests`, host smoke partial | `stable` |
| Quiet alerts | `request_attention.ps1`, `alert-watch`, `alert-stop` | `log-first` 默认；manual/error 写终端、diag、`attention.last.json`，完成提醒默认静默 | Windows terminal, optional toast/TTS | `common.workspace.Tests`, `watch_lifecycle.Tests` | `stable` |
| VS Code folder-open bootstrap | `Rayman: Folder Open Bootstrap` | conservative 默认，仅拉必要 watcher/session/pending-task 路径 | VS Code tasks/settings, owner PID | `vscode_folder_open_bootstrap.Tests`, `watch_lifecycle.Tests` | `stable` |

## 3. Agent / Capability / Prompt Governance

| Cluster | Public entrypoints | Default behavior | Runtime / host dependencies | Existing coverage | Status |
| --- | --- | --- | --- | --- | --- |
| Capability registry | `rayman agent-capabilities`, `.codex/config.toml` managed slices | OpenAI Docs MCP、Playwright MCP、Rayman WinApp MCP 可选启用；multi-agent 可降级 | Codex runtime, MCP availability, local capability probes | `check_agent_contract.ps1`, capability report, JSON schemas | `stable` |
| Prompt / agent assets | `.github/agents`, `.github/skills`, `.github/prompts`, `dispatch`, `review_loop` | capability 资产由 Rayman 管理，路由与 report 需一致 | repo docs + Codex/Copilot consumption | `agent_asset_manifest.ps1`, `check_agent_contract.ps1` | `drifting` |
| Model routing and policy | `.Rayman/config/model_routing.json`, `.Rayman/config/codex_agents/*.toml` | review prompts 和 Codex roles 已有默认模型，但 hosted model selection 仍主要靠文档治理 | Hosted platform features, human operator choice | route config tests partial, no single human-readable policy before this change | `platform-opportunity` |

## 4. Browser / PWA / WinApp

| Cluster | Public entrypoints | Default behavior | Runtime / host dependencies | Existing coverage | Status |
| --- | --- | --- | --- | --- | --- |
| Playwright readiness | `ensure-playwright`, `pwa-test`, sandbox/bootstrap helpers | 优先准备 Playwright；WSL/host/sandbox 有 fallback 链路 | Node/npm, Playwright browsers, optional Windows Sandbox | `playwright_ready.lib.Tests`, host smoke, copy smoke partial | `stable` |
| Browser debugging | Playwright MCP + `pwa-test` fallback | MCP 优先，失败退回本地脚本 | Codex MCP, Playwright runtime | capability report + readiness report | `platform-opportunity` |
| Windows desktop automation | `ensure-winapp`, `winapp-test`, `winapp-inspect`, WinApp MCP | 保留 WinAppDriver-compatible 本地链路和 MCP 包装 | Windows desktop session, UIA, WinApp backend | `winapp_core.Tests`, host smoke, JSON schemas | `under-tested` |

## 5. Release / CI / Security

| Cluster | Public entrypoints | Default behavior | Runtime / host dependencies | Existing coverage | Status |
| --- | --- | --- | --- | --- | --- |
| Release gate | `release-gate`, `copy-self-check --strict`, release checklist / spotcheck | 强制 requirements、regression guard、dist parity、签名校验、telemetry freshness | Git, signing public key, telemetry index | `release_gate.lib.Tests`, `copy_smoke.ps1`, contract lanes | `stable` |
| CI lanes | fast-contract / logic-unit / host-smoke / release + nightly | hosted matrix + nightly self-hosted deep smoke | GitHub Actions, Pester, bats, jsonschema | workflows + local lane scripts | `stable` |
| Provenance / workflow hardening | workflow permissions, reusable workflows, artifact attestations | 当前已分 lane，但 provenance 与 workflow 去重仍主要靠人工治理 | GitHub Actions hosted features | release gate coverage partial, no attestation verify path yet | `platform-opportunity` |

## 6. State / Transfer / Docs / Telemetry

| Cluster | Public entrypoints | Default behavior | Runtime / host dependencies | Existing coverage | Status |
| --- | --- | --- | --- | --- | --- |
| State / handover | `state-save`, `state-resume`, `transfer-export`, `transfer-import` | 工作区状态、handover 信息和恢复链路已形成标准入口 | Git stash, local filesystem, runtime reports | CLI parity, smoke partial | `stable` |
| Telemetry | rules metrics, daily trend, baseline guard, artifact export/index | release 可消费 telemetry bundles 与 baseline guard | shell tooling, JSON schema validation | telemetry schemas + release gate | `stable` |
| Review / enhancement docs | 本功能账本、2026 路线图、model policy | 作为治理面和增强优先级的 tracked 资产，不改变既有 CLI 默认行为 | repo docs only | `check_agent_contract.ps1`, governance docs tests | `drifting` |

## Review Notes

- 当前功能面已经覆盖 setup、watch、alerts、agent/capability、browser/winapp、release、telemetry、handover 等主要链路。
- 近期最容易继续漂移的面不是 CLI 本体，而是 `.github` capability 资产、hosted platform 说明、以及 `.Rayman/.dist` 与 review docs 的同步。
- 2026 增强优先级见 `.Rayman/release/ENHANCEMENT_ROADMAP_2026.md`；平台能力边界见 `.github/model-policy.md`。
