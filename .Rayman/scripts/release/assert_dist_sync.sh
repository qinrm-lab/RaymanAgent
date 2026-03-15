#!/usr/bin/env bash
set -euo pipefail

fail(){ echo "❌ [rayman-dist-sync] $*" >&2; exit 6; }
warn(){ echo "⚠️  [rayman-dist-sync] $*" >&2; }
ok(){ echo "OK"; }

RUNTIME_DIR=".Rayman/runtime"
DECISION_LOG="${RUNTIME_DIR}/decision.log"
DECISION_SUMMARY="${RUNTIME_DIR}/decision.summary.tsv"
DECISION_MAINTAINER="./.Rayman/scripts/release/maintain_decision_log.sh"
mkdir -p "${RUNTIME_DIR}"

now_ts(){ date -Iseconds; }

require_bypass_reason(){
  local gate="$1"
  local reason="${RAYMAN_BYPASS_REASON:-}"
  if [[ -z "${reason// }" ]]; then
    fail "${gate} 需要显式原因：请设置 RAYMAN_BYPASS_REASON。"
  fi
  printf '%s' "${reason}"
}

record_bypass(){
  local gate="$1"
  local reason="$2"
  printf '%s gate=%s action=BYPASS reason=%s\n' "$(now_ts)" "${gate}" "${reason}" >> "${DECISION_LOG}"
  if [[ -f "${DECISION_MAINTAINER}" ]]; then
    bash "${DECISION_MAINTAINER}" --log "${DECISION_LOG}" --summary "${DECISION_SUMMARY}" >/dev/null || true
  fi
  warn "gate bypass: ${gate}（reason=${reason}）"
}

hash_file(){
  sha1sum "$1" | awk '{print $1}'
}

mirror_rel=(
  "scripts/requirements/update_from_prompt.sh"
  "scripts/requirements/process_prompts.sh"
  "scripts/requirements/detect_solution.sh"
  "scripts/requirements/ensure_requirements.sh"
  "scripts/requirements/update_from_prompt.ps1"
  "scripts/requirements/process_prompts.ps1"
  "scripts/requirements/migrate_legacy_requirements.ps1"
  "scripts/requirements/migrate_legacy_requirements.sh"
  "scripts/skills/inject_codex_fix_prompt.ps1"
  "scripts/skills/detect_skills.ps1"
  "scripts/agents/ensure_agents.sh"
  "scripts/agents/resolve_agents_file.sh"
  "scripts/agents/ensure_agent_assets.ps1"
  "scripts/agents/check_agent_contract.ps1"
  "scripts/agents/ensure_agent_capabilities.ps1"
  "scripts/agents/dispatch.ps1"
  "scripts/agents/review_loop.ps1"
  "scripts/agents/first_pass_report.ps1"
  "scripts/agents/prompts_catalog.ps1"
  "scripts/windows/winapp_core.ps1"
  "scripts/windows/ensure_winapp.ps1"
  "scripts/windows/inspect_winapp.ps1"
  "scripts/windows/run_winapp_flow.ps1"
  "scripts/windows/winapp_mcp_server.ps1"
  "scripts/alerts/attention_watch.ps1"
  "scripts/alerts/ensure_attention_watch.ps1"
  "scripts/watch/install_vscode_autostart.ps1"
  "scripts/watch/start_background_watchers.ps1"
  "scripts/watch/vscode_folder_open_bootstrap.ps1"
  "scripts/watch/daily_health_check.ps1"
  "scripts/release/checklist.sh"
  "scripts/release/regression_guard.sh"
  "scripts/release/spotcheck_release.sh"
  "scripts/release/release_gate.ps1"
  "scripts/release/release_gate.lib.ps1"
  "scripts/release/package_distributable.ps1"
  "scripts/release/sync_dist_from_src.ps1"
  "scripts/release/copy_smoke.ps1"
  "scripts/release/assert_dist_sync.sh"
  "scripts/release/assert_dist_sync.ps1"
  "scripts/release/config_sanity.sh"
  "scripts/project/project_gate.lib.ps1"
  "scripts/project/run_project_gate.ps1"
  "scripts/project/generate_project_workflows.ps1"
  "scripts/release/assert_workspace_hygiene.sh"
  "scripts/release/contract_update_from_prompt.sh"
  "scripts/release/contract_release_gate.sh"
  "scripts/release/contract_playwright_fallback.sh"
  "scripts/release/contract_git_safe.sh"
  "scripts/release/contract_scm_tracked_noise.sh"
  "scripts/release/contract_nested_repair.sh"
  "scripts/release/maintain_decision_log.sh"
  "scripts/release/maintain_decision_log.ps1"
  "scripts/release/validate_release_requirements.sh"
  "scripts/release/verify_signature.sh"
  "scripts/backup/snapshot_workspace.sh"
  "scripts/backup/snapshot_workspace.ps1"
  "scripts/utils/clean_workspace.sh"
  "scripts/utils/clean_workspace.ps1"
  "scripts/utils/diagnose_residual_diagnostics.ps1"
  "scripts/utils/generate_context.ps1"
  "scripts/utils/request_attention.ps1"
  "scripts/utils/workspace_process_ownership.ps1"
  "scripts/utils/ensure_project_test_deps.sh"
  "scripts/utils/ensure_project_test_deps.ps1"
  "scripts/utils/workspace_state_guard.ps1"
  "scripts/utils/workspace_state_guard.sh"
  "config/agent_capabilities.json"
  "winapp.flow.sample.json"
  "scripts/repair/run_tests_and_fix.ps1"
  "scripts/repair/capture_snapshot.ps1"
    "scripts/repair/inject_probe.ps1"
    "scripts/repair/revert_probe.ps1"
    "agents/diagnostics.prompt.md"
    "scripts/rag/rag_bootstrap.ps1"
  "scripts/rag/migrate_legacy_rag.ps1"
  "scripts/telemetry/rules_metrics.sh"
  "scripts/telemetry/daily_trend.sh"
  "scripts/telemetry/validate_json.sh"
  "scripts/telemetry/baseline_guard.sh"
  "scripts/telemetry/export_artifacts.sh"
  "scripts/telemetry/index_artifacts.sh"
  "scripts/telemetry/prune_artifacts.sh"
  "scripts/telemetry/schemas/rules_metrics.v1.schema.json"
  "scripts/telemetry/schemas/daily_trend.v1.schema.json"
  "scripts/telemetry/schemas/baseline_guard.v1.schema.json"
  "scripts/telemetry/schemas/first_pass_report.v1.schema.json"
  "scripts/telemetry/schemas/artifact_bundle.v1.schema.json"
  "scripts/telemetry/schemas/artifact_index.v1.schema.json"
  "scripts/ci/validate_requirements.sh"
  "scripts/test_in_sandbox_win.ps1"
  "scripts/test_in_sandbox_wsl.sh"
  "scripts/pwa/ensure_playwright_ready.ps1"
  "scripts/pwa/playwright_ready.lib.ps1"
  "scripts/pwa/ensure_playwright_wsl.sh"
  "scripts/pwa/sandbox/bootstrap.ps1"
  "scripts/pwa/prepare_windows_sandbox_cache.ps1"
  "scripts/proxy/detect_win_proxy.ps1"
  "scripts/proxy/sandbox_proxy_bridge.ps1"
  "scripts/testing/validate_json_contracts.py"
  "scripts/testing/run_fast_contract.sh"
  "scripts/testing/run_bats_tests.sh"
  "scripts/testing/run_pester_tests.ps1"
  "scripts/testing/run_host_smoke.ps1"
  "scripts/testing/pester/common.workspace.Tests.ps1"
  "scripts/testing/pester/workspace_state_guard.Tests.ps1"
  "scripts/testing/pester/workspace_process_ownership.Tests.ps1"
  "scripts/testing/pester/dotnet_maui.Tests.ps1"
  "scripts/testing/pester/release_gate.lib.Tests.ps1"
  "scripts/testing/pester/playwright_ready.lib.Tests.ps1"
  "scripts/testing/pester/winapp_core.Tests.ps1"
  "scripts/testing/bats/test_in_sandbox_wsl.bats"
  "scripts/testing/bats/ensure_project_test_deps.bats"
  "scripts/testing/fixtures/bash/sandbox_success/.Rayman/scripts/utils/ensure_project_test_deps.sh"
  "scripts/testing/fixtures/bash/sandbox_deps_fail/.Rayman/scripts/utils/ensure_project_test_deps.sh"
  "scripts/testing/fixtures/reports/release_gate.sample.json"
  "scripts/testing/fixtures/reports/playwright.ready.windows.sample.json"
  "scripts/testing/fixtures/reports/playwright.ready.wsl.sample.json"
  "scripts/testing/fixtures/reports/winapp.ready.windows.sample.json"
  "scripts/testing/fixtures/reports/winapp.last_result.sample.json"
  "scripts/testing/fixtures/reports/agent_capabilities.report.sample.json"
  "scripts/testing/fixtures/reports/project_gate.fast.sample.json"
  "scripts/testing/schemas/release_gate.v1.schema.json"
  "scripts/testing/schemas/playwright_windows.v2.schema.json"
  "scripts/testing/schemas/playwright_wsl.v1.schema.json"
  "scripts/testing/schemas/winapp_ready.v1.schema.json"
  "scripts/testing/schemas/winapp_flow.v1.schema.json"
  "scripts/testing/schemas/winapp_flow_result.v1.schema.json"
  "scripts/testing/schemas/agent_capabilities_report.v1.schema.json"
  "scripts/testing/schemas/project_gate.v1.schema.json"
  "templates/workflows/rayman-project-fast-gate.yml"
  "templates/workflows/rayman-project-browser-gate.yml"
  "templates/workflows/rayman-project-full-gate.yml"
  "scripts/repair/ensure_complete_rayman.ps1"
  "scripts/repair/ensure_complete_rayman.sh"
  "RELEASE_REQUIREMENTS.md"
  "VERSION"
)

drift=()
for rel in "${mirror_rel[@]}"; do
  src=".Rayman/${rel}"
  dst=".Rayman/.dist/${rel}"

  [[ -f "${src}" ]] || fail "source missing: ${src}"
  [[ -f "${dst}" ]] || fail "dist missing: ${dst}"

  hs="$(hash_file "${src}")"
  hd="$(hash_file "${dst}")"
  if [[ "${hs}" != "${hd}" ]]; then
    drift+=("${rel}")
  fi
done

if [[ "${#drift[@]}" -gt 0 ]]; then
  if [[ "${RAYMAN_ALLOW_DIST_DRIFT:-0}" == "1" ]]; then
    reason="$(require_bypass_reason "dist-drift")"
    record_bypass "dist-drift" "${reason}"
    warn ".Rayman/.dist 漂移已按显式决策放行：${drift[*]}"
    ok
    exit 0
  fi
  fail ".Rayman/.dist 漂移：${drift[*]}（请先同步，或显式设置 RAYMAN_ALLOW_DIST_DRIFT=1 + RAYMAN_BYPASS_REASON）"
fi

ok
