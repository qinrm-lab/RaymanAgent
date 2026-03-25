# Rayman Agentic Plan

- plan_id: cb3d64d9ca35483489115aae75ec10e7
- generated_at: 2026-03-25T15:32:20.5921968+08:00
- task_kind: maintenance
- prompt_key: 
- pipeline: planner_v1

## Goal

- 清理脏工作区并完成全仓库完整回归：修复 worker smoke 夹具、收敛 diff、通过 full-gate 与 strict host copy-smoke

## Constraints

- Follow solution requirements: E:\rayman\software\RaymanAgent\.RaymanAgent\.RaymanAgent.requirements.md
- Follow release discipline: E:\rayman\software\RaymanAgent\.Rayman\RELEASE_REQUIREMENTS.md
- 本文件为 Solution 级强制约束，必须执行。
- 本文件必须包含全部 Project requirements（按路径文本列出）。
- (none detected)
- CI 会校验：此文件必须包含上述每一条路径文本。
- 约定：Solution/Project requirements 均在 .RaymanAgent/ 下，不应在根目录出现 .*.requirements.md。

## Acceptance Criteria

- Task goal remains: 清理脏工作区并完成全仓库完整回归：修复 worker smoke 夹具、收敛 diff、通过 full-gate 与 strict host copy-smoke
- Selected tool policy must be written before execution.
- Doc gate must pass for the active pipeline stage.

## Selected Tools

- `local_shell` score=95 reason=Local shell remains the universal fallback and evidence collector.

## Required Docs
