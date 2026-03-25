# Rayman Agentic Plan

- plan_id: 9a77d3152dc34ec5bcf4f8ea9db85a89
- generated_at: 2026-03-25T17:59:07.1082387+08:00
- task_kind: maintenance
- prompt_key: 
- pipeline: planner_v1

## Goal

- 修复 3 个 worker review finding：命令转义、staged sync 过滤、本地默认 loopback + 显式 LAN 鉴权；并通过定向回归与发布 gate

## Constraints

- Follow solution requirements: E:\rayman\software\RaymanAgent\.RaymanAgent\.RaymanAgent.requirements.md
- Follow release discipline: E:\rayman\software\RaymanAgent\.Rayman\RELEASE_REQUIREMENTS.md
- 本文件为 Solution 级强制约束，必须执行。
- 本文件必须包含全部 Project requirements（按路径文本列出）。
- (none detected)
- CI 会校验：此文件必须包含上述每一条路径文本。
- 约定：Solution/Project requirements 均在 .RaymanAgent/ 下，不应在根目录出现 .*.requirements.md。

## Acceptance Criteria

- Task goal remains: 修复 3 个 worker review finding：命令转义、staged sync 过滤、本地默认 loopback + 显式 LAN 鉴权；并通过定向回归与发布 gate
- `manage_workers` 必须保留带空格路径/参数的 PowerShell 语义。
- `worker_sync` staged bundle 不得包含 `.env`、`.codex/config.toml`、release zip、`.vscode/*` 与 gitignored 文件。
- `worker_host` 默认仅允许 loopback 控制面；LAN 模式必须显式开启并要求 token。
- 定向 Pester、`run_host_smoke.ps1`、`full-gate`、strict host `copy_smoke` 必须通过。
- Selected tool policy must be written before execution.
- Doc gate must pass for the active pipeline stage.

## Selected Tools

- `local_shell` score=95 reason=Local shell remains the universal fallback and evidence collector.

## Required Docs
