#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${REPO_ROOT}"

RAYMAN_DIR="${REPO_ROOT}/.Rayman"
DIST="${RAYMAN_DIR}/.dist"

info(){ echo "ℹ️  [rayman-repair] $*"; }
warn(){ echo "⚠️  [rayman-repair] $*" >&2; }
fail(){ echo "❌ [rayman-repair] $*" >&2; exit 3; }

write_regression_guard(){
  local target="$1"
  mkdir -p "$(dirname "$target")"
  cat >"$target" <<'RAYMAN_EOF'
#!/usr/bin/env bash
set -euo pipefail

fail(){ echo "❌ [rayman-regress] $*" >&2; exit 4; }
ok(){ echo "✅ [rayman-regress] $*"; }

must_exist(){ [[ -f "$1" ]] || fail "missing file: $1"; }

# Minimal guard: ensure key Rayman entrypoints exist.
must_exist ".Rayman/init.sh"
must_exist ".Rayman/init.ps1"
must_exist ".Rayman/init.cmd"
must_exist ".Rayman/win-watch.ps1"
must_exist ".Rayman/self-check.sh"

ok "regression guard passed (minimal)"
RAYMAN_EOF
  chmod +x "$target" 2>/dev/null || true
}

repair_one(){
  local rel="$1"

  # Already present
  if [[ -e "$rel" ]]; then
    return 0
  fi

  # Prefer restoring from .dist mirror
  if [[ -d "$DIST" ]] && [[ -e "$DIST/${rel#./.Rayman/}" ]]; then
    mkdir -p "$(dirname "$rel")"
    if [[ -d "$DIST/${rel#./.Rayman/}" ]]; then
      rm -rf "$rel"
      cp -a "$DIST/${rel#./.Rayman/}" "$rel"
    else
      cp -a "$DIST/${rel#./.Rayman/}" "$rel"
    fi
    info "repaired from .dist: $rel"
    return 0
  fi

  # Last resort: regenerate a minimal regression_guard.sh
  if [[ "$rel" == "./.Rayman/scripts/release/regression_guard.sh" ]]; then
    warn ".dist 不存在，使用内置模板重建: $rel"
    write_regression_guard "$rel"
    return 0
  fi

  fail "缺失且无法自愈：$rel（建议删除整个 .Rayman 后重新完整解压 Rayman 包，确保包含 .Rayman/.dist）"
}

# Ensure base dirs exist
mkdir -p ".Rayman/scripts" ".Rayman/runtime" 2>/dev/null || true

# The minimal set required for init to run
must_paths=(
  "./.Rayman/config.json"
  "./.Rayman/VERSION"
  "./.Rayman/RELEASE_REQUIREMENTS.md"
  "./.Rayman/init.sh"
  "./.Rayman/init.ps1"
  "./.Rayman/init.cmd"
  "./.Rayman/win-watch.ps1"
  "./.Rayman/self-check.sh"
  "./.Rayman/codex_fix_prompt.txt"
  "./.Rayman/scripts/release/validate_release_requirements.sh"
  "./.Rayman/scripts/release/regression_guard.sh"
  "./.Rayman/scripts/release/assert_workspace_hygiene.sh"
  "./.Rayman/scripts/release/assert_dist_sync.sh"
  "./.Rayman/scripts/release/assert_dist_sync.ps1"
  "./.Rayman/scripts/release/copy_smoke.ps1"
  "./.Rayman/scripts/release/config_sanity.sh"
  "./.Rayman/scripts/project/project_gate.lib.ps1"
  "./.Rayman/scripts/project/run_project_gate.ps1"
  "./.Rayman/scripts/project/generate_project_workflows.ps1"
  "./.Rayman/scripts/release/contract_update_from_prompt.sh"
  "./.Rayman/scripts/release/contract_git_safe.sh"
  "./.Rayman/scripts/release/contract_nested_repair.sh"
  "./.Rayman/scripts/release/maintain_decision_log.sh"
  "./.Rayman/scripts/release/maintain_decision_log.ps1"
  "./.Rayman/scripts/telemetry/rules_metrics.sh"
  "./.Rayman/scripts/telemetry/daily_trend.sh"
  "./.Rayman/scripts/telemetry/validate_json.sh"
  "./.Rayman/scripts/telemetry/baseline_guard.sh"
  "./.Rayman/scripts/telemetry/export_artifacts.sh"
  "./.Rayman/scripts/telemetry/index_artifacts.sh"
  "./.Rayman/scripts/telemetry/prune_artifacts.sh"
  "./.Rayman/scripts/telemetry/schemas/rules_metrics.v1.schema.json"
  "./.Rayman/scripts/telemetry/schemas/daily_trend.v1.schema.json"
  "./.Rayman/scripts/telemetry/schemas/baseline_guard.v1.schema.json"
  "./.Rayman/scripts/telemetry/schemas/artifact_bundle.v1.schema.json"
  "./.Rayman/scripts/telemetry/schemas/artifact_index.v1.schema.json"
  "./.Rayman/scripts/backup/backup_solution.ps1"
  "./.Rayman/scripts/alerts/attention_watch.ps1"
  "./.Rayman/scripts/alerts/ensure_attention_watch.ps1"
  "./.Rayman/scripts/watch/embedded_watchers.lib.ps1"
  "./.Rayman/scripts/watch/watch_lifecycle.lib.ps1"
  "./.Rayman/scripts/watch/start_background_watchers.ps1"
  "./.Rayman/scripts/watch/stop_background_watchers.ps1"
  "./.Rayman/scripts/watch/codex_desktop_bootstrap.ps1"
  "./.Rayman/scripts/watch/worker_auto_sync.ps1"
  "./.Rayman/scripts/watch/vscode_folder_open_bootstrap.ps1"
  "./.Rayman/scripts/watch/daily_health_check.ps1"
  "./.Rayman/scripts/watch/install_vscode_autostart.ps1"
  "./.Rayman/scripts/proxy/run_tcp_bridge.ps1"
  "./.Rayman/scripts/proxy/sandbox_proxy_bridge.ps1"
  "./.Rayman/scripts/requirements/ensure_requirements.sh"
  "./.Rayman/scripts/requirements/process_prompts.sh"
  "./.Rayman/scripts/requirements/process_prompts.ps1"
  "./.Rayman/scripts/pwa/ensure_playwright_wsl.sh"
  "./.Rayman/scripts/pwa/ensure_playwright_ready.ps1"
  "./.Rayman/scripts/pwa/prepare_windows_sandbox.ps1"
  "./.Rayman/scripts/pwa/prepare_windows_sandbox_cache.ps1"
  "./.Rayman/scripts/pwa/sandbox/bootstrap.ps1"
  "./.Rayman/scripts/agents/resolve_agents_file.sh"
  "./.Rayman/scripts/backup/snapshot_workspace.sh"
  "./.Rayman/scripts/backup/snapshot_workspace.ps1"
  "./.Rayman/scripts/utils/clean_workspace.sh"
  "./.Rayman/scripts/utils/clean_workspace.ps1"
  "./.Rayman/scripts/workspace/registered_workspace_bootstrap.ps1"
  "./.Rayman/scripts/utils/request_attention.ps1"
  "./.Rayman/scripts/utils/sound_check.ps1"
  "./.Rayman/scripts/utils/ensure_project_test_deps.sh"
  "./.Rayman/scripts/utils/ensure_project_test_deps.ps1"
  "./.Rayman/scripts/repair/run_tests_and_fix.ps1"
  "./.Rayman/templates/workflows/rayman-project-fast-gate.yml"
  "./.Rayman/templates/workflows/rayman-project-browser-gate.yml"
  "./.Rayman/templates/workflows/rayman-project-full-gate.yml"
  "./.Rayman/scripts/testing/schemas/project_gate.v1.schema.json"
  "./.Rayman/scripts/testing/fixtures/reports/project_gate.fast.sample.json"
  "./.Rayman/release/FEATURE_INVENTORY.md"
  "./.Rayman/release/ENHANCEMENT_ROADMAP_2026.md"
  "./.Rayman/scripts/skills/detect_skills.sh"
  "./.Rayman/scripts/skills/inject_codex_fix_prompt.sh"
  "./.Rayman/scripts/skills/inject_codex_fix_prompt.ps1"
  "./.Rayman/scripts/agents/ensure_agents.sh"
)

for p in "${must_paths[@]}"; do
  repair_one "$p"
done

# Best-effort chmod (may be ignored on NTFS)
chmod +x .Rayman/init.sh 2>/dev/null || true
find .Rayman/scripts -type f -name "*.sh" -exec chmod +x {} + 2>/dev/null || true

# Quick syntax checks (fail fast before running anything else)
for shf in ".Rayman/init.sh" ".Rayman/scripts/release/validate_release_requirements.sh" ".Rayman/scripts/release/regression_guard.sh" ".Rayman/scripts/repair/ensure_complete_rayman.sh"; do
  bash -n "$shf" >/dev/null 2>&1 || fail "bash 语法检查失败：$shf"
done

info "Rayman 完整性检查通过"
