# Rayman Agentic Plan

- plan_id: 69ebdcf6141e4e4fb9b419386504fbb8
- generated_at: 2026-03-24T08:26:43.9120879+08:00
- task_kind: review
- prompt_key: review.initial.prompt.md
- pipeline: planner_v1

## Goal

- OpenAI docs prompt review

## Constraints

- Follow solution requirements: E:\rayman\software\RaymanAgent\.RaymanAgent\.RaymanAgent.requirements.md
- Follow release discipline: E:\rayman\software\RaymanAgent\.Rayman\RELEASE_REQUIREMENTS.md
- 本文件为 Solution 级强制约束，必须执行。
- 本文件必须包含全部 Project requirements（按路径文本列出）。
- (none detected)
- CI 会校验：此文件必须包含上述每一条路径文本。
- 约定：Solution/Project requirements 均在 .RaymanAgent/ 下，不应在根目录出现 .*.requirements.md。

## Acceptance Criteria

- Task goal remains: OpenAI docs prompt review
- Reflection outcome must be `done` before the run is treated as successful.
- Doc gate must pass with current plan/tool-policy/reflection artifacts.
- Review-loop success still requires `test-fix` to pass.

## Selected Tools

- `openai_docs_mcp` score=95 reason=Official OpenAI docs are the primary source for platform-specific guidance.
- `rayman_docs_researcher` score=55 reason=Multi-agent registry marks this role as relevant for the task shape.
- `rayman_reviewer` score=55 reason=Multi-agent registry marks this role as relevant for the task shape.
- `local_shell` score=25 reason=Local shell remains the universal fallback and evidence collector.

## Required Docs

- `plan.current.md`
- `plan.current.json`
- `tool-policy.md`
- `tool-policy.json`
- `evals.md`