# Rayman Agentic Evals

- prompt_suites: tracked by `.Rayman/config/prompt_eval_suites.json`
- prompt_assets: tracked by `.github/prompts/*.prompt.md`
- planner_artifacts: tracked by `plan.current.*`, `tool-policy.*`, `reflection.current.*`
- runtime_reports:
  - `.Rayman/runtime/prompt_evals/last.json`
  - `.Rayman/runtime/prompt_evals/last.md`
  - `.Rayman/runtime/first_pass.report.json`
- acceptance_targets:
  - doc gate pass
  - acceptance closed
  - reflection outcome distribution
  - prompt eval pass/fail and render drift visibility
  - first-pass stability after planner_v1 rollout
- latest_result: 2026-04-16 Hermes-inspired prompt-eval/report path landed (`context_audit=tracked`, `skills_registry=tracked`, `rollback=tracked`, `prompt_eval=tracked`, `release_visibility=required`)
- baseline: prompt suites are repo-tracked first, hosted optimizer remains optional, and release review should treat `.Rayman/runtime/prompt_evals/` as the machine-readable source of truth.
