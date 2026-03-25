# Rayman Agentic Plan

- plan_id: 1245769107cd4cc58946b5ba98cf1175
- generated_at: 2026-03-25T19:03:32.6355851+08:00
- task_kind: maintenance
- prompt_key: 
- pipeline: planner_v1

## Goal

- 消除 `.Rayman/CONTEXT.md` 与 `.Rayman/codex_fix_prompt.txt` 的非幂等污染；让 `generate_context` / `inject_codex_fix_prompt` 在完整回归后不再把 source workspace 写脏

## Constraints

- Follow solution requirements: E:\rayman\software\RaymanAgent\.RaymanAgent\.RaymanAgent.requirements.md
- Follow release discipline: E:\rayman\software\RaymanAgent\.Rayman\RELEASE_REQUIREMENTS.md
- 本文件为 Solution 级强制约束，必须执行。
- 本文件必须包含全部 Project requirements（按路径文本列出）。
- (none detected)
- CI 会校验：此文件必须包含上述每一条路径文本。
- 约定：Solution/Project requirements 均在 .RaymanAgent/ 下，不应在根目录出现 .*.requirements.md。

## Acceptance Criteria

- Task goal remains: 消除 `.Rayman/CONTEXT.md` 与 `.Rayman/codex_fix_prompt.txt` 的非幂等污染；让 `generate_context` / `inject_codex_fix_prompt` 在完整回归后不再把 source workspace 写脏
- `inject_codex_fix_prompt` 不得再注入时间戳；重复执行时内容必须保持稳定。
- `inject_codex_fix_prompt` 在缺失进程级 `RAYMAN_SKILLS_SELECTED` 时，必须能回读 runtime 的 skills state。
- `generate_context` 的 top-level snapshot 必须基于稳定输入，不得吸入未跟踪本地文件。
- `generate_context` 不得把 runtime capability 细节固化进已跟踪的 `.Rayman/CONTEXT.md`。
- 定向 Pester、`assert_dist_sync.ps1`、`full-gate`、strict host `copy_smoke` 必须通过。
- 回归前后 `.Rayman/CONTEXT.md` / `.Rayman/codex_fix_prompt.txt` / `.Rayman/.dist/codex_fix_prompt.txt` hash 必须保持不变。
- Selected tool policy must be written before execution.
- Doc gate must pass for the active pipeline stage.

## Selected Tools

- `local_shell` score=95 reason=Local shell remains the universal fallback and evidence collector.

## Required Docs
