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

function Test-GitTrackedPath([string]$GitExe, [string]$RepoRoot, [string]$RelativePath) {
  if ([string]::IsNullOrWhiteSpace($GitExe) -or [string]::IsNullOrWhiteSpace($RelativePath)) {
    return $false
  }

  & $GitExe -C $RepoRoot ls-files --error-unmatch -- $RelativePath *> $null
  return ($LASTEXITCODE -eq 0)
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
  $commonPath = Join-Path $WorkspaceRoot '.Rayman\common.ps1'
  if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
    . $commonPath
  }

  $runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime'
  if (-not (Test-Path -LiteralPath $runtimeDir)) {
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
  }
  $decisionLog = Join-Path $runtimeDir 'decision.log'
  $gitCommand = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
  $enforceTrackedness = $false
  $trackedMissing = New-Object System.Collections.Generic.List[string]
  $workspaceKind = 'external'
  if (Get-Command Get-RaymanWorkspaceKind -ErrorAction SilentlyContinue) {
    try {
      $workspaceKind = [string](Get-RaymanWorkspaceKind -WorkspaceRoot $WorkspaceRoot)
    } catch {
      $workspaceKind = 'external'
    }
  }
  if ($null -eq $gitCommand -or [string]::IsNullOrWhiteSpace([string]$gitCommand.Source)) {
    Warn 'git not found; skip trackedness validation.'
  } else {
    & $gitCommand.Source -C $WorkspaceRoot rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -eq 0) {
      if ($workspaceKind -eq 'source') {
        $enforceTrackedness = $true
      } else {
        Warn ("workspace kind is {0}; skip trackedness validation." -f $workspaceKind)
      }
    } else {
      Warn ("workspace is not a git worktree; skip trackedness validation: {0}" -f $WorkspaceRoot)
    }
  }

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
    'scripts/skills/detect_skills.ps1'
    'scripts/agents/ensure_agents.sh'
    'scripts/agents/resolve_agents_file.sh'
    'scripts/agents/agent_asset_manifest.ps1'
    'scripts/agents/ensure_agent_assets.ps1'
    'scripts/agents/check_agent_contract.ps1'
    'scripts/agents/ensure_agent_capabilities.ps1'
    'scripts/agents/dispatch.ps1'
    'scripts/agents/review_loop.ps1'
    'scripts/agents/first_pass_report.ps1'
    'scripts/agents/prompts_catalog.ps1'
    'scripts/codex/codex_common.ps1'
    'scripts/codex/manage_accounts.ps1'
    'scripts/windows/winapp_core.ps1'
    'scripts/windows/ensure_winapp.ps1'
    'scripts/windows/inspect_winapp.ps1'
    'scripts/windows/run_winapp_flow.ps1'
    'scripts/windows/winapp_mcp_server.ps1'
    'scripts/alerts/attention_watch.ps1'
    'scripts/alerts/ensure_attention_watch.ps1'
    'scripts/watch/embedded_watchers.lib.ps1'
    'scripts/watch/install_vscode_autostart.ps1'
    'scripts/watch/watch_lifecycle.lib.ps1'
    'scripts/watch/start_background_watchers.ps1'
    'scripts/watch/vscode_folder_open_bootstrap.ps1'
    'scripts/watch/daily_health_check.ps1'
    'scripts/release/checklist.sh'
    'scripts/release/regression_guard.sh'
    'scripts/release/spotcheck_release.sh'
    'scripts/release/release_gate.ps1'
    'scripts/release/release_gate.lib.ps1'
    'scripts/release/package_distributable.ps1'
    'scripts/release/manage_version.ps1'
    'scripts/release/sync_dist_from_src.ps1'
    'scripts/release/copy_smoke.ps1'
    'scripts/release/assert_dist_sync.sh'
    'scripts/release/assert_dist_sync.ps1'
    'scripts/release/config_sanity.sh'
    'scripts/project/project_gate.lib.ps1'
    'scripts/project/run_project_gate.ps1'
    'scripts/project/generate_project_workflows.ps1'
    'scripts/release/assert_workspace_hygiene.sh'
    'scripts/release/contract_update_from_prompt.sh'
    'scripts/release/contract_release_gate.sh'
    'scripts/release/contract_playwright_fallback.sh'
    'scripts/release/contract_git_safe.sh'
    'scripts/release/contract_scm_tracked_noise.sh'
    'scripts/release/contract_nested_repair.sh'
    'scripts/release/maintain_decision_log.sh'
    'scripts/release/maintain_decision_log.ps1'
    'scripts/release/validate_release_requirements.sh'
    'scripts/release/verify_signature.sh'
    'scripts/backup/snapshot_workspace.sh'
    'scripts/backup/snapshot_workspace.ps1'
    'scripts/utils/clean_workspace.sh'
    'scripts/utils/clean_workspace.ps1'
    'scripts/utils/diagnose_residual_diagnostics.ps1'
    'scripts/utils/command_catalog.ps1'
    'scripts/utils/generate_context.ps1'
    'scripts/utils/request_attention.ps1'
    'scripts/utils/update_command_docs.ps1'
    'scripts/utils/workspace_process_ownership.ps1'
    'scripts/utils/ensure_project_test_deps.sh'
    'scripts/utils/ensure_project_test_deps.ps1'
    'scripts/utils/workspace_state_guard.ps1'
    'scripts/utils/workspace_state_guard.sh'
    'config/command_catalog.tsv'
    'config/agent_capabilities.json'
    'winapp.flow.sample.json'
    'scripts/repair/run_tests_and_fix.ps1'
    'scripts/repair/capture_snapshot.ps1'
    'scripts/repair/inject_probe.ps1'
    'scripts/repair/revert_probe.ps1'
    'agents/diagnostics.prompt.md'
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
    'scripts/pwa/ensure_playwright_ready.ps1'
    'scripts/pwa/playwright_ready.lib.ps1'
    'scripts/pwa/ensure_playwright_wsl.sh'
    'scripts/pwa/sandbox/bootstrap.ps1'
    'scripts/pwa/prepare_windows_sandbox_cache.ps1'
    'scripts/proxy/detect_win_proxy.ps1'
    'scripts/proxy/sandbox_proxy_bridge.ps1'
    'scripts/testing/validate_json_contracts.py'
    'scripts/testing/run_fast_contract.sh'
    'scripts/testing/run_bats_tests.sh'
    'scripts/testing/run_pester_tests.ps1'
    'scripts/testing/host_smoke.lib.ps1'
    'scripts/testing/run_host_smoke.ps1'
    'scripts/testing/pester/common.workspace.Tests.ps1'
    'scripts/testing/pester/codex_accounts.Tests.ps1'
    'scripts/testing/pester/workspace_state_guard.Tests.ps1'
    'scripts/testing/pester/workspace_process_ownership.Tests.ps1'
    'scripts/testing/pester/watch_lifecycle.Tests.ps1'
    'scripts/testing/pester/dotnet_maui.Tests.ps1'
    'scripts/testing/pester/host_smoke.lib.Tests.ps1'
    'scripts/testing/pester/release_gate.lib.Tests.ps1'
    'scripts/testing/pester/playwright_ready.lib.Tests.ps1'
    'scripts/testing/pester/winapp_core.Tests.ps1'
    'scripts/testing/bats/ensure_project_test_deps.bats'
    'scripts/testing/fixtures/reports/release_gate.sample.json'
    'scripts/testing/fixtures/reports/playwright.ready.windows.sample.json'
    'scripts/testing/fixtures/reports/playwright.ready.wsl.sample.json'
    'scripts/testing/fixtures/reports/winapp.ready.windows.sample.json'
    'scripts/testing/fixtures/reports/winapp.last_result.sample.json'
    'scripts/testing/fixtures/reports/agent_capabilities.report.sample.json'
    'scripts/testing/fixtures/reports/codex.auth.status.sample.json'
    'scripts/testing/fixtures/reports/project_gate.fast.sample.json'
    'scripts/testing/schemas/release_gate.v1.schema.json'
    'scripts/testing/schemas/playwright_windows.v2.schema.json'
    'scripts/testing/schemas/playwright_wsl.v1.schema.json'
    'scripts/testing/schemas/winapp_ready.v1.schema.json'
    'scripts/testing/schemas/winapp_flow.v1.schema.json'
    'scripts/testing/schemas/winapp_flow_result.v1.schema.json'
    'scripts/testing/schemas/agent_capabilities_report.v1.schema.json'
    'scripts/testing/schemas/codex_auth_status.v1.schema.json'
    'scripts/testing/schemas/project_gate.v1.schema.json'
    'templates/workflows/rayman-project-fast-gate.yml'
    'templates/workflows/rayman-project-browser-gate.yml'
    'templates/workflows/rayman-project-full-gate.yml'
    'scripts/repair/ensure_complete_rayman.ps1'
    'scripts/repair/ensure_complete_rayman.sh'
    'scripts/testing/pester/governance_docs.Tests.ps1'
    'common.ps1'
    'rayman'
    'rayman.ps1'
    'win-watch.ps1'
    'release/FEATURE_INVENTORY.md'
    'release/ENHANCEMENT_ROADMAP_2026.md'
    'README.md'
    'commands.txt'
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

    if ($enforceTrackedness) {
      $srcTrackedRel = (Join-Path '.Rayman' $relWin).Replace('\', '/')
      $dstTrackedRel = (Join-Path '.Rayman\.dist' $relWin).Replace('\', '/')
      if (-not (Test-GitTrackedPath -GitExe $gitCommand.Source -RepoRoot $WorkspaceRoot -RelativePath $srcTrackedRel)) {
        [void]$trackedMissing.Add($srcTrackedRel)
      }
      if (-not (Test-GitTrackedPath -GitExe $gitCommand.Source -RepoRoot $WorkspaceRoot -RelativePath $dstTrackedRel)) {
        [void]$trackedMissing.Add($dstTrackedRel)
      }
    }

    $hashSrc = Get-FileHashCompat -Path $src -Algorithm 'SHA1'
    $hashDst = Get-FileHashCompat -Path $dst -Algorithm 'SHA1'
    if ($hashSrc -ne $hashDst) {
      [void]$drift.Add($rel)
    }
  }

  if ($enforceTrackedness -and $trackedMissing.Count -gt 0) {
    Fail ("git index missing mirrored assets: {0}（请先 git add 对应 source/dist 资产）" -f ($trackedMissing -join ' '))
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
