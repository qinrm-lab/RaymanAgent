param(
  [string]$Root
)

$ErrorActionPreference = "Stop"
if (-not $Root) {
  $Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

function Fail($msg) { Write-Host "❌ [rayman-repair] $msg" ; exit 3 }
function Info($msg) { Write-Host "ℹ️  [rayman-repair] $msg" }

$dist = Join-Path $Root ".Rayman\.dist"
if (-not (Test-Path $dist)) { Fail "缺少内置修复包：$dist（Rayman 包不完整或解压损坏；请用完整包覆盖 .Rayman）" }

$mustPaths = @(
  ".Rayman\config.json",
  ".Rayman\scripts\release\validate_release_requirements.sh",
  ".Rayman\scripts\release\checklist.sh",
  ".Rayman\scripts\release\issues_gate.sh",
  ".Rayman\scripts\release\regression_guard.sh",
  ".Rayman\scripts\release\spotcheck_release.sh",
  ".Rayman\scripts\release\verify_signature.sh",
  ".Rayman\scripts\release\assert_workspace_hygiene.sh",
  ".Rayman\scripts\release\assert_dist_sync.sh",
  ".Rayman\scripts\release\assert_dist_sync.ps1",
  ".Rayman\scripts\release\copy_smoke.ps1",
  ".Rayman\scripts\release\config_sanity.sh",
  ".Rayman\scripts\release\contract_update_from_prompt.sh",
  ".Rayman\scripts\release\contract_git_safe.sh",
  ".Rayman\scripts\release\contract_nested_repair.sh",
  ".Rayman\scripts\release\maintain_decision_log.sh",
  ".Rayman\scripts\release\maintain_decision_log.ps1",
  ".Rayman\scripts\telemetry\rules_metrics.sh",
  ".Rayman\scripts\telemetry\daily_trend.sh",
  ".Rayman\scripts\telemetry\validate_json.sh",
  ".Rayman\scripts\telemetry\baseline_guard.sh",
  ".Rayman\scripts\telemetry\export_artifacts.sh",
  ".Rayman\scripts\telemetry\index_artifacts.sh",
  ".Rayman\scripts\telemetry\prune_artifacts.sh",
  ".Rayman\scripts\telemetry\schemas\rules_metrics.v1.schema.json",
  ".Rayman\scripts\telemetry\schemas\daily_trend.v1.schema.json",
  ".Rayman\scripts\telemetry\schemas\baseline_guard.v1.schema.json",
  ".Rayman\scripts\telemetry\schemas\artifact_bundle.v1.schema.json",
  ".Rayman\scripts\telemetry\schemas\artifact_index.v1.schema.json",
  ".Rayman\scripts\backup\backup_solution.ps1",
  ".Rayman\scripts\alerts\attention_watch.ps1",
  ".Rayman\scripts\alerts\ensure_attention_watch.ps1",
  ".Rayman\scripts\watch\start_background_watchers.ps1",
  ".Rayman\scripts\watch\install_vscode_autostart.ps1",
  ".Rayman\scripts\proxy\run_tcp_bridge.ps1",
  ".Rayman\scripts\proxy\sandbox_proxy_bridge.ps1",
  ".Rayman\scripts\requirements\ensure_requirements.sh",
  ".Rayman\scripts\requirements\detect_solution.sh",
  ".Rayman\scripts\requirements\detect_projects.sh",
  ".Rayman\scripts\pwa\ensure_playwright_wsl.sh",
  ".Rayman\scripts\pwa\ensure_playwright_ready.ps1",
  ".Rayman\scripts\pwa\prepare_windows_sandbox.ps1",
  ".Rayman\scripts\pwa\prepare_windows_sandbox_cache.ps1",
  ".Rayman\scripts\pwa\sandbox\bootstrap.ps1",
  ".Rayman\scripts\agents\ensure_agents.sh",
  ".Rayman\scripts\agents\resolve_agents_file.sh",
  ".Rayman\scripts\backup\snapshot_workspace.sh",
  ".Rayman\scripts\backup\snapshot_workspace.ps1",
  ".Rayman\scripts\utils\clean_workspace.sh",
  ".Rayman\scripts\utils\clean_workspace.ps1",
  ".Rayman\scripts\utils\ensure_project_test_deps.sh",
  ".Rayman\scripts\utils\ensure_project_test_deps.ps1",
  ".Rayman\scripts\repair\run_tests_and_fix.ps1",
  ".Rayman\RELEASE_REQUIREMENTS.md",
  ".Rayman\VERSION"
)

foreach ($rel in $mustPaths) {
  $abs = Join-Path $Root $rel
  if (-not (Test-Path $abs)) {
    # dist mirrors the .Rayman subtree roots (scripts, templates, etc.)
    $sub = $rel.Substring(".Rayman\".Length)
    $src = Join-Path $dist $sub
    if (Test-Path $src) {
      $parent = Split-Path $abs -Parent
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
      Copy-Item -Recurse -Force $src $abs
      Info "repaired: $rel"
    } else {
      Fail "无法修复缺失项：$rel（dist 中不存在 $src）"
    }
  }
}

Info "Rayman 完整性检查通过"
