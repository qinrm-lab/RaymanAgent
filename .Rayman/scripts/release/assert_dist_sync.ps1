param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
  Write-Host ("❌ [rayman-dist-sync] {0}" -f $Message) -ForegroundColor Red
  exit 6
}

function Warn([string]$Message) {
  Write-Host ("⚠️  [rayman-dist-sync] {0}" -f $Message) -ForegroundColor Yellow
}

function Ok() {
  Write-Output 'OK'
}

function Get-NowTimestamp() {
  (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
}

function Get-FileHashCompat([string]$Path, [string]$Algorithm) {
  $cmd = Get-Command Get-FileHash -ErrorAction SilentlyContinue
  if ($null -ne $cmd) {
    return (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash
  }

  # Compatibility fallback for older PowerShell that lacks Get-FileHash.
  $alg = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
  if ($null -eq $alg) {
    Fail ("hash algorithm not supported: {0}" -f $Algorithm)
  }

  $stream = [System.IO.File]::OpenRead($Path)
  try {
    $bytes = $alg.ComputeHash($stream)
  } finally {
    try { $stream.Dispose() } catch {}
    try { $alg.Dispose() } catch {}
  }

  return ([System.BitConverter]::ToString($bytes)).Replace('-', '')
}

function Get-BypassReasonOrFail([string]$Gate) {
  $reason = [string]$env:RAYMAN_BYPASS_REASON
  if ([string]::IsNullOrWhiteSpace($reason)) {
    Fail ("{0} 需要显式原因：请设置 RAYMAN_BYPASS_REASON。" -f $Gate)
  }
  return $reason.Trim()
}

function Write-BypassDecision([string]$DecisionLogPath, [string]$Gate, [string]$Reason) {
  $line = "{0} gate={1} action=BYPASS reason={2}" -f (Get-NowTimestamp), $Gate, $Reason
  Add-Content -LiteralPath $DecisionLogPath -Value $line -Encoding UTF8
  try {
    $maintainer = Join-Path $WorkspaceRoot '.Rayman\scripts\release\maintain_decision_log.ps1'
    if (Test-Path -LiteralPath $maintainer -PathType Leaf) {
      & $maintainer -WorkspaceRoot $WorkspaceRoot -LogPath $DecisionLogPath -SummaryPath (Join-Path $WorkspaceRoot '.Rayman\runtime\decision.summary.tsv') | Out-Null
    }
  } catch {}
  Warn ("gate bypass: {0}（reason={1}）" -f $Gate, $Reason)
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
Push-Location $WorkspaceRoot
try {
  $runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime'
  if (-not (Test-Path -LiteralPath $runtimeDir)) {
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
  }
  $decisionLog = Join-Path $runtimeDir 'decision.log'

  $mirrorRel = @(
    'scripts/requirements/update_from_prompt.sh'
    'scripts/requirements/process_prompts.sh'
    'scripts/requirements/detect_solution.sh'
    'scripts/requirements/ensure_requirements.sh'
    'scripts/requirements/update_from_prompt.ps1'
    'scripts/requirements/process_prompts.ps1'
    'scripts/requirements/migrate_legacy_requirements.ps1'
    'scripts/requirements/migrate_legacy_requirements.sh'
    'scripts/skills/inject_codex_fix_prompt.ps1'
    'scripts/agents/ensure_agents.sh'
    'scripts/agents/resolve_agents_file.sh'
    'scripts/agents/ensure_agent_assets.ps1'
    'scripts/agents/dispatch.ps1'
    'scripts/agents/review_loop.ps1'
    'scripts/agents/first_pass_report.ps1'
    'scripts/agents/prompts_catalog.ps1'
    'scripts/alerts/attention_watch.ps1'
    'scripts/alerts/ensure_attention_watch.ps1'
    'scripts/watch/install_vscode_autostart.ps1'
    'scripts/watch/start_background_watchers.ps1'
    'scripts/release/checklist.sh'
    'scripts/release/regression_guard.sh'
    'scripts/release/spotcheck_release.sh'
    'scripts/release/release_gate.ps1'
    'scripts/release/package_distributable.ps1'
    'scripts/release/sync_dist_from_src.ps1'
    'scripts/release/copy_smoke.ps1'
    'scripts/release/assert_dist_sync.sh'
    'scripts/release/assert_dist_sync.ps1'
    'scripts/release/config_sanity.sh'
    'scripts/release/assert_workspace_hygiene.sh'
    'scripts/release/contract_update_from_prompt.sh'
    'scripts/release/contract_release_gate.sh'
    'scripts/release/contract_playwright_fallback.sh'
    'scripts/release/contract_git_safe.sh'
    'scripts/release/contract_nested_repair.sh'
    'scripts/release/maintain_decision_log.sh'
    'scripts/release/maintain_decision_log.ps1'
    'scripts/release/validate_release_requirements.sh'
    'scripts/release/verify_signature.sh'
    'scripts/backup/snapshot_workspace.sh'
    'scripts/backup/snapshot_workspace.ps1'
    'scripts/utils/clean_workspace.sh'
    'scripts/utils/clean_workspace.ps1'
    'scripts/utils/ensure_project_test_deps.sh'
    'scripts/utils/ensure_project_test_deps.ps1'
    'scripts/repair/run_tests_and_fix.ps1'
    'scripts/rag/rag_bootstrap.ps1'
    'scripts/rag/migrate_legacy_rag.ps1'
    'scripts/telemetry/rules_metrics.sh'
    'scripts/telemetry/daily_trend.sh'
    'scripts/telemetry/validate_json.sh'
    'scripts/telemetry/baseline_guard.sh'
    'scripts/telemetry/export_artifacts.sh'
    'scripts/telemetry/index_artifacts.sh'
    'scripts/telemetry/prune_artifacts.sh'
    'scripts/telemetry/schemas/rules_metrics.v1.schema.json'
    'scripts/telemetry/schemas/daily_trend.v1.schema.json'
    'scripts/telemetry/schemas/baseline_guard.v1.schema.json'
    'scripts/telemetry/schemas/first_pass_report.v1.schema.json'
    'scripts/telemetry/schemas/artifact_bundle.v1.schema.json'
    'scripts/telemetry/schemas/artifact_index.v1.schema.json'
    'scripts/ci/validate_requirements.sh'
    'scripts/test_in_sandbox_win.ps1'
    'scripts/test_in_sandbox_wsl.sh'
    'scripts/pwa/ensure_playwright_ready.ps1'
    'scripts/pwa/ensure_playwright_wsl.sh'
    'scripts/pwa/sandbox/bootstrap.ps1'
    'scripts/pwa/prepare_windows_sandbox_cache.ps1'
    'scripts/proxy/detect_win_proxy.ps1'
    'scripts/proxy/sandbox_proxy_bridge.ps1'
    'scripts/repair/ensure_complete_rayman.ps1'
    'scripts/repair/ensure_complete_rayman.sh'
    'RELEASE_REQUIREMENTS.md'
    'VERSION'
  )

  $drift = New-Object System.Collections.Generic.List[string]
  foreach ($rel in $mirrorRel) {
    $relWin = $rel.Replace('/', '\')
    $src = Join-Path $WorkspaceRoot (Join-Path '.Rayman' $relWin)
    $dst = Join-Path $WorkspaceRoot (Join-Path '.Rayman\.dist' $relWin)

    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
      Fail ("source missing: .Rayman/{0}" -f $rel)
    }
    if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) {
      Fail ("dist missing: .Rayman/.dist/{0}" -f $rel)
    }

    $hashSrc = Get-FileHashCompat -Path $src -Algorithm 'SHA1'
    $hashDst = Get-FileHashCompat -Path $dst -Algorithm 'SHA1'
    if ($hashSrc -ne $hashDst) {
      [void]$drift.Add($rel)
    }
  }

  if ($drift.Count -gt 0) {
    if ([string]$env:RAYMAN_ALLOW_DIST_DRIFT -eq '1') {
      $reason = Get-BypassReasonOrFail -Gate 'dist-drift'
      Write-BypassDecision -DecisionLogPath $decisionLog -Gate 'dist-drift' -Reason $reason
      Warn (".Rayman/.dist 漂移已按显式决策放行：{0}" -f ($drift -join ' '))
      Ok
      exit 0
    }
    Fail (".Rayman/.dist 漂移：{0}（请先同步，或显式设置 RAYMAN_ALLOW_DIST_DRIFT=1 + RAYMAN_BYPASS_REASON）" -f ($drift -join ' '))
  }

  Ok
} finally {
  Pop-Location
}
