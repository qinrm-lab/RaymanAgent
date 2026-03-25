# Rayman Agentic Plan

- plan_id: f14ff55943ed4dcf818afe426edc11ff
- generated_at: 2026-03-25T12:37:24.3396868+08:00
- task_kind: maintenance
- prompt_key: 
- pipeline: planner_v1

## Goal

- 安全完成 2026-03-24 未闭环任务：重跑 host smoke 并收尾 agentic docs

## Constraints

- Follow solution requirements: E:\rayman\software\RaymanAgent\.RaymanAgent\.RaymanAgent.requirements.md
- Follow release discipline: E:\rayman\software\RaymanAgent\.Rayman\RELEASE_REQUIREMENTS.md
- 本文件为 Solution 级强制约束，必须执行。
- 本文件必须包含全部 Project requirements（按路径文本列出）。
- (none detected)
- CI 会校验：此文件必须包含上述每一条路径文本。
- 约定：Solution/Project requirements 均在 .RaymanAgent/ 下，不应在根目录出现 .*.requirements.md。

## Acceptance Criteria

- Task goal remains: 安全完成 2026-03-24 未闭环任务：重跑 host smoke 并收尾 agentic docs
- Selected tool policy must be written before execution.
- Doc gate must pass for the active pipeline stage.

## Selected Tools

- `local_shell` score=95 reason=Local shell remains the universal fallback and evidence collector.

## Required Docs

- `plan.current.md`
- `plan.current.json`
- `tool-policy.md`
- `tool-policy.json`
- `evals.md`