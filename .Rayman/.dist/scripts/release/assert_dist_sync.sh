#!/usr/bin/env bash
set -euo pipefail

fail(){ echo "❌ [rayman-dist-sync] $*" >&2; exit 6; }
warn(){ echo "⚠️  [rayman-dist-sync] $*" >&2; }
ok(){ echo "OK"; }

RUNTIME_DIR=".Rayman/runtime"
DECISION_LOG="${RUNTIME_DIR}/decision.log"
DECISION_SUMMARY="${RUNTIME_DIR}/decision.summary.tsv"
DECISION_MAINTAINER="./.Rayman/scripts/release/maintain_decision_log.sh"
WORKSPACE_ROOT="$(pwd)"
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

git_path_tracked(){
  git -C "${WORKSPACE_ROOT}" ls-files --cached -- "$1" | grep -Fxq "$1"
}

git_path_state(){
  local relative_path="$1"
  if [[ ! -f "${WORKSPACE_ROOT}/${relative_path}" ]]; then
    printf 'missing'
    return 0
  fi

  if git_path_tracked "${relative_path}"; then
    printf 'tracked'
    return 0
  fi

  printf 'present'
}

detect_workspace_kind(){
  local root="$1"
  local testing_marker="${root}/.Rayman/scripts/testing/run_fast_contract.sh"
  local has_testing_marker=0
  local has_source_workflow_marker=0
  local has_solution_requirement_marker=0

  [[ -f "${testing_marker}" ]] && has_testing_marker=1
  [[ -f "${root}/.github/workflows/rayman-test-lanes.yml" || -f "${root}/.github/workflows/rayman-nightly-smoke.yml" ]] && has_source_workflow_marker=1

  local dir name
  shopt -s nullglob dotglob
  for dir in "${root}"/.*; do
    [[ -d "${dir}" ]] || continue
    name="$(basename "${dir}")"
    if [[ -f "${dir}/${name}.requirements.md" ]]; then
      has_solution_requirement_marker=1
      break
    fi
  done
  shopt -u nullglob dotglob

  if [[ "${has_source_workflow_marker}" == "1" && ( "${has_testing_marker}" == "1" || "${has_solution_requirement_marker}" == "1" ) ]]; then
    printf 'source'
    return 0
  fi

  printf 'external'
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
  "scripts/agents/agent_asset_manifest.ps1"
  "scripts/agents/ensure_agent_assets.ps1"
  "scripts/agents/check_agent_contract.ps1"
  "scripts/agents/ensure_agent_capabilities.ps1"
  "scripts/agents/agentic_pipeline.ps1"
  "scripts/agents/dispatch.ps1"
  "scripts/agents/review_loop.ps1"
  "scripts/agents/first_pass_report.ps1"
  "scripts/agents/prompts_catalog.ps1"
  "scripts/worker/worker_common.ps1"
  "scripts/worker/worker_host.ps1"
  "scripts/worker/manage_workers.ps1"
  "scripts/worker/worker_sync.ps1"
  "scripts/worker/worker_upgrade.ps1"
  "scripts/worker/worker_pipe_transport.ps1"
  "scripts/codex/codex_common.ps1"
  "scripts/codex/manage_accounts.ps1"
  "scripts/windows/winapp_core.ps1"
  "scripts/windows/ensure_winapp.ps1"
  "scripts/windows/inspect_winapp.ps1"
  "scripts/windows/run_winapp_flow.ps1"
  "scripts/windows/winapp_mcp_server.ps1"
  "scripts/alerts/attention_watch.ps1"
  "scripts/alerts/ensure_attention_watch.ps1"
  "scripts/watch/embedded_watchers.lib.ps1"
  "scripts/watch/install_vscode_autostart.ps1"
  "scripts/watch/watch_lifecycle.lib.ps1"
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
  "scripts/utils/command_catalog.ps1"
  "scripts/utils/generate_context.ps1"
  "scripts/utils/request_attention.ps1"
  "scripts/utils/update_command_docs.ps1"
  "scripts/utils/workspace_process_ownership.ps1"
  "scripts/utils/ensure_project_test_deps.sh"
  "scripts/utils/ensure_project_test_deps.ps1"
  "scripts/utils/workspace_state_guard.ps1"
  "scripts/utils/workspace_state_guard.sh"
  "config/command_catalog.tsv"
  "config/agent_capabilities.json"
  "config/agentic_pipeline.json"
  "winapp.flow.sample.json"
  "scripts/repair/run_tests_and_fix.ps1"
  "scripts/repair/capture_snapshot.ps1"
    "scripts/repair/inject_probe.ps1"
    "scripts/repair/revert_probe.ps1"
    "agents/diagnostics.prompt.md"
    "scripts/memory/memory_bootstrap.ps1"
  "scripts/memory/manage_memory.ps1"
  "scripts/memory/memory_common.ps1"
  "scripts/memory/manage_memory.py"
  "scripts/memory/requirements.txt"
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
  "scripts/testing/host_smoke.lib.ps1"
  "scripts/testing/run_host_smoke.ps1"
  "scripts/testing/pester/common.workspace.Tests.ps1"
  "scripts/testing/pester/codex_accounts.Tests.ps1"
  "scripts/testing/pester/worker_common.Tests.ps1"
  "scripts/testing/pester/workspace_state_guard.Tests.ps1"
  "scripts/testing/pester/workspace_process_ownership.Tests.ps1"
  "scripts/testing/pester/watch_lifecycle.Tests.ps1"
  "scripts/testing/pester/dotnet_maui.Tests.ps1"
  "scripts/testing/pester/host_smoke.lib.Tests.ps1"
  "scripts/testing/pester/release_gate.lib.Tests.ps1"
  "scripts/testing/pester/playwright_ready.lib.Tests.ps1"
  "scripts/testing/pester/winapp_core.Tests.ps1"
  "scripts/testing/pester/agentic_pipeline.Tests.ps1"
  "scripts/testing/pester/agent_memory.Tests.ps1"
  "scripts/testing/bats/ensure_project_test_deps.bats"
  "scripts/testing/bats/validate_requirements_agentic.bats"
  "scripts/testing/fixtures/reports/release_gate.sample.json"
  "scripts/testing/fixtures/reports/playwright.ready.windows.sample.json"
  "scripts/testing/fixtures/reports/playwright.ready.wsl.sample.json"
  "scripts/testing/fixtures/reports/winapp.ready.windows.sample.json"
  "scripts/testing/fixtures/reports/winapp.last_result.sample.json"
  "scripts/testing/fixtures/reports/agent_capabilities.report.sample.json"
  "scripts/testing/fixtures/reports/codex.auth.status.sample.json"
  "scripts/testing/fixtures/reports/agent_memory.status.sample.json"
  "scripts/testing/fixtures/reports/agent_memory.search.sample.json"
  "scripts/testing/fixtures/reports/agent_memory.summarize.sample.json"
  "scripts/testing/fixtures/reports/project_gate.fast.sample.json"
  "scripts/testing/fixtures/worker_smoke_app/WorkerSmokeApp.csproj"
  "scripts/testing/fixtures/worker_smoke_app/Program.cs"
  "scripts/testing/schemas/release_gate.v1.schema.json"
  "scripts/testing/schemas/playwright_windows.v2.schema.json"
  "scripts/testing/schemas/playwright_wsl.v1.schema.json"
  "scripts/testing/schemas/winapp_ready.v1.schema.json"
  "scripts/testing/schemas/winapp_flow.v1.schema.json"
  "scripts/testing/schemas/winapp_flow_result.v1.schema.json"
  "scripts/testing/schemas/agent_capabilities_report.v1.schema.json"
  "scripts/testing/schemas/codex_auth_status.v1.schema.json"
  "scripts/testing/schemas/agent_memory_status.v1.schema.json"
  "scripts/testing/schemas/agent_memory_search_result.v1.schema.json"
  "scripts/testing/schemas/agent_memory_summarize_result.v1.schema.json"
  "scripts/testing/schemas/project_gate.v1.schema.json"
  "templates/workflows/rayman-project-fast-gate.yml"
  "templates/workflows/rayman-project-browser-gate.yml"
  "templates/workflows/rayman-project-full-gate.yml"
  "scripts/repair/ensure_complete_rayman.ps1"
  "scripts/repair/ensure_complete_rayman.sh"
  "scripts/testing/pester/governance_docs.Tests.ps1"
  "common.ps1"
  "rayman"
  "rayman.ps1"
  "win-watch.ps1"
  "release/FEATURE_INVENTORY.md"
  "release/ENHANCEMENT_ROADMAP_2026.md"
  "README.md"
  "commands.txt"
  "RELEASE_REQUIREMENTS.md"
  "VERSION"
)

enforce_trackedness=0
tracked_mismatch=()
tracked_pending=()
workspace_kind="$(detect_workspace_kind "${WORKSPACE_ROOT}")"
if command -v git >/dev/null 2>&1; then
  if git -C "${WORKSPACE_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [[ "${workspace_kind}" == "source" ]]; then
      enforce_trackedness=1
    else
      warn "workspace kind is ${workspace_kind}; skip trackedness validation."
    fi
  else
    warn "workspace is not a git worktree; skip trackedness validation: ${WORKSPACE_ROOT}"
  fi
else
  warn "git not found; skip trackedness validation."
fi

drift=()
for rel in "${mirror_rel[@]}"; do
  src=".Rayman/${rel}"
  dst=".Rayman/.dist/${rel}"

  [[ -f "${src}" ]] || fail "source missing: ${src}"
  [[ -f "${dst}" ]] || fail "dist missing: ${dst}"

  if [[ "${enforce_trackedness}" == "1" ]]; then
    src_state="$(git_path_state "${src}")"
    dst_state="$(git_path_state "${dst}")"
    if [[ "${src_state}" == "tracked" && "${dst_state}" != "tracked" ]] || [[ "${dst_state}" == "tracked" && "${src_state}" != "tracked" ]]; then
      tracked_mismatch+=("${src}<->${dst}")
    elif [[ "${src_state}" == "present" && "${dst_state}" == "present" ]]; then
      tracked_pending+=("${src}<->${dst}")
    fi
  fi

  hs="$(hash_file "${src}")"
  hd="$(hash_file "${dst}")"
  if [[ "${hs}" != "${hd}" ]]; then
    drift+=("${rel}")
  fi
done

if [[ "${#tracked_mismatch[@]}" -gt 0 ]]; then
  fail "git index mirrored assets mismatch: ${tracked_mismatch[*]}（请先 git add 对应 source/dist 资产）"
fi

if [[ "${#tracked_pending[@]}" -gt 0 ]]; then
  warn "git index pending mirrored assets: ${tracked_pending[*]}"
fi

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
