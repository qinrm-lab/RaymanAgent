#!/usr/bin/env bash
set -euo pipefail

fail(){ echo "❌ [rayman-regress] $*" >&2; exit 4; }
ok(){ echo "✅ [rayman-regress] $*"; }

must_exist(){ [[ -f "$1" ]] || fail "missing file: $1"; }
must_grep(){ local f="$1"; local pat="$2"; grep -qE "$pat" "$f" || fail "missing marker in $f: $pat"; }

must_exist ".Rayman/init.sh"
must_exist ".Rayman/init.ps1"
must_exist ".Rayman/init.cmd"
must_exist ".Rayman/win-watch.ps1"
must_exist ".Rayman/self-check.sh"
must_exist ".Rayman/codex_fix_prompt.txt"
must_exist ".Rayman/config.json"
must_exist ".Rayman/scripts/backup/backup_solution.ps1"
must_exist ".Rayman/scripts/alerts/attention_watch.ps1"
must_exist ".Rayman/scripts/alerts/ensure_attention_watch.ps1"
must_exist ".Rayman/scripts/watch/start_background_watchers.ps1"
must_exist ".Rayman/scripts/watch/install_vscode_autostart.ps1"
must_exist ".Rayman/scripts/requirements/process_prompts.sh"
must_exist ".Rayman/scripts/requirements/process_prompts.ps1"
must_exist ".Rayman/scripts/requirements/ensure_requirements.sh"
must_exist ".Rayman/scripts/skills/inject_codex_fix_prompt.sh"
must_exist ".Rayman/scripts/skills/inject_codex_fix_prompt.ps1"
must_exist ".Rayman/scripts/agents/ensure_agents.sh"
must_exist ".Rayman/scripts/agents/resolve_agents_file.sh"
must_exist ".Rayman/scripts/release/validate_release_requirements.sh"
must_exist ".Rayman/scripts/release/checklist.sh"
must_exist ".Rayman/scripts/release/issues_gate.sh"
must_exist ".Rayman/scripts/release/regression_guard.sh"
must_exist ".Rayman/scripts/release/spotcheck_release.sh"
must_exist ".Rayman/scripts/release/verify_signature.sh"
must_exist ".Rayman/scripts/release/maintain_decision_log.sh"
must_exist ".Rayman/scripts/release/maintain_decision_log.ps1"
must_exist ".Rayman/scripts/release/assert_workspace_hygiene.sh"
must_exist ".Rayman/scripts/release/assert_dist_sync.sh"
must_exist ".Rayman/scripts/release/assert_dist_sync.ps1"
must_exist ".Rayman/scripts/release/copy_smoke.ps1"
must_exist ".Rayman/scripts/release/config_sanity.sh"
must_exist ".Rayman/scripts/release/contract_update_from_prompt.sh"
must_exist ".Rayman/scripts/release/contract_release_gate.sh"
must_exist ".Rayman/scripts/release/contract_playwright_fallback.sh"
must_exist ".Rayman/scripts/release/contract_git_safe.sh"
must_exist ".Rayman/scripts/release/contract_nested_repair.sh"
must_exist ".Rayman/scripts/pwa/ensure_playwright_wsl.sh"
must_exist ".Rayman/scripts/pwa/ensure_playwright_ready.ps1"
must_exist ".Rayman/scripts/pwa/prepare_windows_sandbox.ps1"
must_exist ".Rayman/scripts/pwa/prepare_windows_sandbox_cache.ps1"
must_exist ".Rayman/scripts/pwa/sandbox/bootstrap.ps1"
must_exist ".Rayman/scripts/proxy/sandbox_proxy_bridge.ps1"
must_exist ".Rayman/scripts/backup/snapshot_workspace.sh"
must_exist ".Rayman/scripts/backup/snapshot_workspace.ps1"
must_exist ".Rayman/scripts/utils/clean_workspace.sh"
must_exist ".Rayman/scripts/utils/clean_workspace.ps1"
must_exist ".Rayman/scripts/utils/ensure_project_test_deps.sh"
must_exist ".Rayman/scripts/utils/ensure_project_test_deps.ps1"
must_exist ".Rayman/scripts/repair/run_tests_and_fix.ps1"
must_exist ".Rayman/scripts/rag/rag_bootstrap.ps1"
must_exist ".Rayman/scripts/telemetry/rules_metrics.sh"
must_exist ".Rayman/scripts/telemetry/daily_trend.sh"
must_exist ".Rayman/scripts/telemetry/validate_json.sh"
must_exist ".Rayman/scripts/telemetry/baseline_guard.sh"
must_exist ".Rayman/scripts/telemetry/export_artifacts.sh"
must_exist ".Rayman/scripts/telemetry/index_artifacts.sh"
must_exist ".Rayman/scripts/telemetry/prune_artifacts.sh"
must_exist ".Rayman/scripts/telemetry/schemas/rules_metrics.v1.schema.json"
must_exist ".Rayman/scripts/telemetry/schemas/daily_trend.v1.schema.json"
must_exist ".Rayman/scripts/telemetry/schemas/baseline_guard.v1.schema.json"
must_exist ".Rayman/scripts/telemetry/schemas/artifact_bundle.v1.schema.json"
must_exist ".Rayman/scripts/telemetry/schemas/artifact_index.v1.schema.json"

# init.ps1 should not contain a stray single backslash line
if grep -nE '^[[:space:]]*\\[[:space:]]*$' ".Rayman/init.ps1" >/dev/null 2>&1; then
  fail "init.ps1 contains stray '\\' line"
fi

# codex_fix_prompt must have skill + user prompt blocks
must_grep ".Rayman/codex_fix_prompt.txt" "RAYMAN:SKILLS:BEGIN"
must_grep ".Rayman/codex_fix_prompt.txt" "RAYMAN:USER_PROMPT:BEGIN"

ok "entrypoints and markers OK"
