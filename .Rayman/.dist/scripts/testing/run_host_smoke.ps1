param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$IncludeWsl,
  [switch]$IncludeSandbox,
  [switch]$RequireEnvironment
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\..\common.ps1')
. (Join-Path $PSScriptRoot 'host_smoke.lib.ps1')

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime\test_lanes'
$logDir = Join-Path $runtimeDir 'logs'
$reportPath = Join-Path $runtimeDir 'host_smoke.report.json'
$schemaReportPath = Join-Path $runtimeDir 'host_smoke.schemas.json'
$isolatedCodexHome = Join-Path $WorkspaceRoot '.Rayman\runtime\tmp\host_smoke_codex_home'
$playwrightScript = Join-Path $WorkspaceRoot '.Rayman\scripts\pwa\ensure_playwright_ready.ps1'
$winAppScript = Join-Path $WorkspaceRoot '.Rayman\scripts\windows\ensure_winapp.ps1'
$winAppCoreScript = Join-Path $WorkspaceRoot '.Rayman\scripts\windows\winapp_core.ps1'
$agentCapabilitiesScript = Join-Path $WorkspaceRoot '.Rayman\scripts\agents\ensure_agent_capabilities.ps1'
$memoryManageScript = Join-Path $WorkspaceRoot '.Rayman\scripts\memory\manage_memory.ps1'
$schemaValidator = Join-Path $WorkspaceRoot '.Rayman\scripts\testing\validate_json_contracts.py'
$codexCmd = Resolve-RaymanHostSmokeCommandPath -Names @('codex')
$pwshCmd = Resolve-RaymanHostSmokeCommandPath -Names @('pwsh.exe', 'pwsh')

if (Test-Path -LiteralPath $winAppCoreScript -PathType Leaf) {
  . $winAppCoreScript
}

if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
}
if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}

function Add-Step {
  param(
    [System.Collections.Generic.List[object]]$Steps,
    [string]$Name,
    [ValidateSet('PASS','WARN','FAIL')][string]$Status,
    [string]$Detail,
    [string]$LogPath = ''
  )

  $Steps.Add([pscustomobject]@{
      name = $Name
      status = $Status
      detail = $Detail
      log_path = $LogPath
    }) | Out-Null
}

function Get-LaunchFailureDetail {
  param(
    [string]$Label,
    [object]$Result
  )

  $reason = if ($null -eq $Result -or [string]::IsNullOrWhiteSpace([string]$Result.launch_error)) {
    'failed to start'
  } else {
    [string]$Result.launch_error
  }

  return ("{0} failed to launch ({1})" -f $Label, $reason)
}

function Convert-JsonFromCommandOutput {
  param(
    [string]$OutputText
  )

  if ([string]::IsNullOrWhiteSpace($OutputText)) { return $null }
  try {
    return ($OutputText | ConvertFrom-Json -ErrorAction Stop)
  } catch {}

  $lines = $OutputText -split "`r?`n"
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    if ($lines[$i].TrimStart().StartsWith('{')) {
      $candidate = ($lines[$i..($lines.Count - 1)] -join "`n")
      try {
        return ($candidate | ConvertFrom-Json -ErrorAction Stop)
      } catch {}
    }
  }

  return $null
}

$steps = New-Object 'System.Collections.Generic.List[object]'
$overall = 'PASS'

$bashInvocation = New-RaymanHostSmokeBashInvocation -WorkspaceRoot $WorkspaceRoot -CommandText './.Rayman/rayman help'
if ($null -eq $bashInvocation) {
  Add-Step -Steps $steps -Name 'bash_cli_help' -Status 'FAIL' -Detail 'bash not found'
  $overall = 'FAIL'
} else {
  $result = Invoke-RaymanHostSmokeStep -Name 'bash_cli_help' -LogDir $logDir -FilePath $bashInvocation.path -ArgumentList $bashInvocation.argument_list -WorkingDirectory $WorkspaceRoot
  if (-not [bool]$result.started) {
    Add-Step -Steps $steps -Name 'bash_cli_help' -Status 'FAIL' -Detail (Get-LaunchFailureDetail -Label 'bash rayman help' -Result $result) -LogPath $result.log_path
    $overall = 'FAIL'
  } elseif ($result.exit_code -eq 0 -and $result.output -match 'Rayman CLI \(v') {
    Add-Step -Steps $steps -Name 'bash_cli_help' -Status 'PASS' -Detail 'bash rayman help succeeded' -LogPath $result.log_path
  } else {
    Add-Step -Steps $steps -Name 'bash_cli_help' -Status 'FAIL' -Detail ("bash rayman help failed (exit={0})" -f $result.exit_code) -LogPath $result.log_path
    $overall = 'FAIL'
  }
}

$psHelpLog = Join-Path $logDir 'pwsh_cli_help.log'
if ([string]::IsNullOrWhiteSpace($pwshCmd)) {
  Set-Content -LiteralPath $psHelpLog -Value 'pwsh not found' -Encoding UTF8
  Add-Step -Steps $steps -Name 'pwsh_cli_help' -Status 'FAIL' -Detail 'pwsh not found' -LogPath $psHelpLog
  $overall = 'FAIL'
} else {
  $psHelp = Invoke-RaymanHostSmokeStep -Name 'pwsh_cli_help' -LogDir $logDir -FilePath $pwshCmd -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $WorkspaceRoot '.Rayman\rayman.ps1'), 'help') -WorkingDirectory $WorkspaceRoot
  if (-not [bool]$psHelp.started) {
    Add-Step -Steps $steps -Name 'pwsh_cli_help' -Status 'FAIL' -Detail (Get-LaunchFailureDetail -Label 'pwsh rayman help' -Result $psHelp) -LogPath $psHelp.log_path
    $overall = 'FAIL'
  } elseif ($psHelp.exit_code -eq 0 -and $psHelp.output -match 'Rayman CLI \(v') {
    Add-Step -Steps $steps -Name 'pwsh_cli_help' -Status 'PASS' -Detail 'pwsh rayman help succeeded' -LogPath $psHelp.log_path
  } else {
    Add-Step -Steps $steps -Name 'pwsh_cli_help' -Status 'FAIL' -Detail ("pwsh rayman help failed (exit={0})" -f $psHelp.exit_code) -LogPath $psHelp.log_path
    $overall = 'FAIL'
  }
}

if ([string]::IsNullOrWhiteSpace($pwshCmd)) {
  $winAppLog = Join-Path $logDir 'winapp_json.log'
  Set-Content -LiteralPath $winAppLog -Value 'pwsh not found' -Encoding UTF8
  Add-Step -Steps $steps -Name 'winapp_json' -Status 'FAIL' -Detail 'pwsh not found' -LogPath $winAppLog
  $overall = 'FAIL'
} else {
  $winApp = Invoke-RaymanHostSmokeStep -Name 'winapp_json' -LogDir $logDir -FilePath $pwshCmd -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $winAppScript, '-WorkspaceRoot', $WorkspaceRoot, '-Json') -WorkingDirectory $WorkspaceRoot
  if (-not [bool]$winApp.started) {
    Add-Step -Steps $steps -Name 'winapp_json' -Status 'FAIL' -Detail (Get-LaunchFailureDetail -Label 'ensure-winapp' -Result $winApp) -LogPath $winApp.log_path
    $overall = 'FAIL'
  } elseif ($winApp.exit_code -eq 0) {
    $winAppJson = Convert-JsonFromCommandOutput -OutputText $winApp.output
    if ($null -ne $winAppJson -and $winAppJson.schema -eq 'rayman.winapp.ready.v1') {
      $winAppReason = [string]$winAppJson.reason
      $notApplicable = $false
      if (Get-Command Test-WinAppReadinessReasonNotApplicable -ErrorAction SilentlyContinue) {
        $notApplicable = Test-WinAppReadinessReasonNotApplicable -Reason $winAppReason
      }
      $status = if ([bool]$winAppJson.ready) { 'PASS' } elseif ($RequireEnvironment) { 'FAIL' } elseif ($notApplicable) { 'PASS' } else { 'WARN' }
      if ($status -eq 'FAIL') { $overall = 'FAIL' } elseif ($status -eq 'WARN' -and $overall -eq 'PASS') { $overall = 'WARN' }
      $detail = if ($notApplicable -and -not [bool]$winAppJson.ready) {
        ("ready={0} reason={1} selected_backend={2} preferred_backend={3} fallback={4} (not_applicable_on_current_host)" -f [bool]$winAppJson.ready, $winAppReason, [string]$winAppJson.selected_backend, [string]$winAppJson.preferred_backend, [string]$winAppJson.fallback_decision)
      } else {
        ("ready={0} reason={1} selected_backend={2} preferred_backend={3} fallback={4}" -f [bool]$winAppJson.ready, $winAppReason, [string]$winAppJson.selected_backend, [string]$winAppJson.preferred_backend, [string]$winAppJson.fallback_decision)
      }
      Add-Step -Steps $steps -Name 'winapp_json' -Status $status -Detail $detail -LogPath $winApp.log_path
    } else {
      Add-Step -Steps $steps -Name 'winapp_json' -Status 'FAIL' -Detail 'ensure-winapp did not emit valid JSON' -LogPath $winApp.log_path
      $overall = 'FAIL'
    }
  } else {
    Add-Step -Steps $steps -Name 'winapp_json' -Status 'FAIL' -Detail ("ensure-winapp failed (exit={0})" -f $winApp.exit_code) -LogPath $winApp.log_path
    $overall = 'FAIL'
  }
}

if (-not (Test-Path -LiteralPath $isolatedCodexHome -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $isolatedCodexHome | Out-Null
}

if ([string]::IsNullOrWhiteSpace($pwshCmd) -or [string]::IsNullOrWhiteSpace($codexCmd)) {
  $detail = if ([string]::IsNullOrWhiteSpace($codexCmd)) { 'codex not found' } else { 'pwsh not found' }
  $status = if ($RequireEnvironment) { 'FAIL' } else { 'WARN' }
  if ($status -eq 'FAIL') { $overall = 'FAIL' } elseif ($overall -eq 'PASS') { $overall = 'WARN' }
  Add-Step -Steps $steps -Name 'codex_login_status_isolated' -Status $status -Detail $detail
  Add-Step -Steps $steps -Name 'codex_features_list_isolated' -Status $status -Detail $detail
  Add-Step -Steps $steps -Name 'agent_capabilities_isolated_codex_home' -Status $status -Detail $detail
} else {
  $quotedHome = $isolatedCodexHome.Replace("'", "''")

  $codexLogin = Invoke-RaymanHostSmokeStep -Name 'codex_login_status_isolated' -LogDir $logDir -FilePath $pwshCmd -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "& { `$env:CODEX_HOME = '$quotedHome'; codex login status }") -WorkingDirectory $WorkspaceRoot
  if (-not [bool]$codexLogin.started) {
    Add-Step -Steps $steps -Name 'codex_login_status_isolated' -Status 'FAIL' -Detail (Get-LaunchFailureDetail -Label 'codex login status' -Result $codexLogin) -LogPath $codexLogin.log_path
    $overall = 'FAIL'
  } elseif ($codexLogin.output -match 'access.*denied|permission denied') {
    Add-Step -Steps $steps -Name 'codex_login_status_isolated' -Status 'FAIL' -Detail ("codex login status failed (exit={0})" -f $codexLogin.exit_code) -LogPath $codexLogin.log_path
    $overall = 'FAIL'
  } elseif ($codexLogin.exit_code -in @(0, 1)) {
    Add-Step -Steps $steps -Name 'codex_login_status_isolated' -Status 'PASS' -Detail ("codex login status executed (exit={0})" -f $codexLogin.exit_code) -LogPath $codexLogin.log_path
  } else {
    Add-Step -Steps $steps -Name 'codex_login_status_isolated' -Status 'FAIL' -Detail ("codex login status failed (exit={0})" -f $codexLogin.exit_code) -LogPath $codexLogin.log_path
    $overall = 'FAIL'
  }

  $codexFeatures = Invoke-RaymanHostSmokeStep -Name 'codex_features_list_isolated' -LogDir $logDir -FilePath $pwshCmd -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "& { `$env:CODEX_HOME = '$quotedHome'; codex features list }") -WorkingDirectory $WorkspaceRoot
  if (-not [bool]$codexFeatures.started) {
    Add-Step -Steps $steps -Name 'codex_features_list_isolated' -Status 'FAIL' -Detail (Get-LaunchFailureDetail -Label 'codex features list' -Result $codexFeatures) -LogPath $codexFeatures.log_path
    $overall = 'FAIL'
  } elseif ($codexFeatures.exit_code -eq 0) {
    Add-Step -Steps $steps -Name 'codex_features_list_isolated' -Status 'PASS' -Detail 'codex features list succeeded under isolated CODEX_HOME' -LogPath $codexFeatures.log_path
  } else {
    Add-Step -Steps $steps -Name 'codex_features_list_isolated' -Status 'FAIL' -Detail ("codex features list failed (exit={0})" -f $codexFeatures.exit_code) -LogPath $codexFeatures.log_path
    $overall = 'FAIL'
  }

  $agentCaps = Invoke-RaymanHostSmokeStep -Name 'agent_capabilities_isolated_codex_home' -LogDir $logDir -FilePath $pwshCmd -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "& { `$env:CODEX_HOME = '$quotedHome'; & '$agentCapabilitiesScript' -WorkspaceRoot '$WorkspaceRoot' -Action status -Json }") -WorkingDirectory $WorkspaceRoot
  if (-not [bool]$agentCaps.started) {
    Add-Step -Steps $steps -Name 'agent_capabilities_isolated_codex_home' -Status 'FAIL' -Detail (Get-LaunchFailureDetail -Label 'agent-capabilities' -Result $agentCaps) -LogPath $agentCaps.log_path
    $overall = 'FAIL'
  } elseif ($agentCaps.exit_code -eq 0) {
    $agentCapsJson = Convert-JsonFromCommandOutput -OutputText $agentCaps.output
    if ($null -ne $agentCapsJson -and $agentCapsJson.schema -eq 'rayman.agent_capabilities.report.v1') {
      Add-Step -Steps $steps -Name 'agent_capabilities_isolated_codex_home' -Status 'PASS' -Detail ("codex_available={0}" -f [bool]$agentCapsJson.codex_available) -LogPath $agentCaps.log_path
    } else {
      Add-Step -Steps $steps -Name 'agent_capabilities_isolated_codex_home' -Status 'FAIL' -Detail 'agent-capabilities did not emit valid JSON under isolated CODEX_HOME' -LogPath $agentCaps.log_path
      $overall = 'FAIL'
    }
  } else {
    Add-Step -Steps $steps -Name 'agent_capabilities_isolated_codex_home' -Status 'FAIL' -Detail ("agent-capabilities failed (exit={0})" -f $agentCaps.exit_code) -LogPath $agentCaps.log_path
    $overall = 'FAIL'
  }
}

$playwrightScopes = New-Object System.Collections.Generic.List[string]
$playwrightScopes.Add('host') | Out-Null
if ($IncludeWsl) { $playwrightScopes.Add('wsl') | Out-Null }
if ($IncludeSandbox) { $playwrightScopes.Add('sandbox') | Out-Null }

if ([string]::IsNullOrWhiteSpace($pwshCmd)) {
  foreach ($scope in $playwrightScopes) {
    $scopeLog = Join-Path $logDir ("playwright_{0}.log" -f $scope)
    Set-Content -LiteralPath $scopeLog -Value 'pwsh not found' -Encoding UTF8
    Add-Step -Steps $steps -Name ("playwright_{0}" -f $scope) -Status 'FAIL' -Detail 'pwsh not found' -LogPath $scopeLog
  }
  $overall = 'FAIL'
} else {
  foreach ($scope in $playwrightScopes) {
    $result = Invoke-RaymanHostSmokeStep -Name ("playwright_{0}" -f $scope) -LogDir $logDir -FilePath $pwshCmd -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $playwrightScript, '-WorkspaceRoot', $WorkspaceRoot, '-Scope', $scope, '-Require:$false', '-Json') -WorkingDirectory $WorkspaceRoot
    if (-not [bool]$result.started) {
      Add-Step -Steps $steps -Name ("playwright_{0}" -f $scope) -Status 'FAIL' -Detail (Get-LaunchFailureDetail -Label 'ensure-playwright' -Result $result) -LogPath $result.log_path
      $overall = 'FAIL'
    } elseif ($result.exit_code -eq 0) {
      $json = Convert-JsonFromCommandOutput -OutputText $result.output
      if ($null -ne $json -and $json.schema -eq 'rayman.playwright.windows.v2' -and [string]$json.scope -eq $scope) {
        $stepStatus = if ([bool]$json.success) { 'PASS' } elseif ($RequireEnvironment) { 'FAIL' } else { 'WARN' }
        if ($stepStatus -eq 'FAIL') { $overall = 'FAIL' } elseif ($stepStatus -eq 'WARN' -and $overall -eq 'PASS') { $overall = 'WARN' }
        $target = if ($scope -eq 'sandbox') { $json.sandbox } elseif ($scope -eq 'host') { $json.host } else { $json.wsl }
        $detailParts = New-Object System.Collections.Generic.List[string]
        $detailParts.Add(("success={0}" -f [bool]$json.success)) | Out-Null
        if ($null -ne $target) {
          $failureKind = [string]$target.failure_kind
          if (-not [string]::IsNullOrWhiteSpace($failureKind)) {
            $detailParts.Add(("failure_kind={0}" -f $failureKind)) | Out-Null
          }
        }
        if ($scope -eq 'sandbox' -and $null -ne $json.offline_cache) {
          $missing = @($json.offline_cache.missing_components | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
          if ($missing.Count -gt 0) {
            $detailParts.Add(("missing={0}" -f ($missing -join ','))) | Out-Null
          }
        }
        Add-Step -Steps $steps -Name ("playwright_{0}" -f $scope) -Status $stepStatus -Detail ($detailParts -join '; ') -LogPath $result.log_path
      } else {
        Add-Step -Steps $steps -Name ("playwright_{0}" -f $scope) -Status 'FAIL' -Detail 'ensure-playwright did not emit valid JSON' -LogPath $result.log_path
        $overall = 'FAIL'
      }
    } else {
      Add-Step -Steps $steps -Name ("playwright_{0}" -f $scope) -Status 'FAIL' -Detail ("ensure-playwright failed (exit={0})" -f $result.exit_code) -LogPath $result.log_path
      $overall = 'FAIL'
    }
  }
}

if ([string]::IsNullOrWhiteSpace($pwshCmd) -or -not (Test-Path -LiteralPath $memoryManageScript -PathType Leaf)) {
  $memoryLog = Join-Path $logDir 'agent_memory_json.log'
  $detail = if ([string]::IsNullOrWhiteSpace($pwshCmd)) { 'pwsh not found' } else { 'manage_memory.ps1 not found' }
  Set-Content -LiteralPath $memoryLog -Value $detail -Encoding UTF8
  Add-Step -Steps $steps -Name 'agent_memory_json' -Status 'FAIL' -Detail $detail -LogPath $memoryLog
  $overall = 'FAIL'
} else {
  $statusStep = Invoke-RaymanHostSmokeStep -Name 'agent_memory_status' -LogDir $logDir -FilePath $pwshCmd -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $memoryManageScript, '-WorkspaceRoot', $WorkspaceRoot, '-Action', 'status', '-Json') -WorkingDirectory $WorkspaceRoot
  $searchStep = Invoke-RaymanHostSmokeStep -Name 'agent_memory_search' -LogDir $logDir -FilePath $pwshCmd -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $memoryManageScript, '-WorkspaceRoot', $WorkspaceRoot, '-Action', 'search', '-Query', 'release requirements', '-Json') -WorkingDirectory $WorkspaceRoot
  $summarizeStep = Invoke-RaymanHostSmokeStep -Name 'agent_memory_summarize' -LogDir $logDir -FilePath $pwshCmd -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $memoryManageScript, '-WorkspaceRoot', $WorkspaceRoot, '-Action', 'summarize', '-DrainPending', '-Json') -WorkingDirectory $WorkspaceRoot

  $memoryOk = $true
  foreach ($stepInfo in @(
      @{ result = $statusStep; schema = 'rayman.agent_memory.status.v1' },
      @{ result = $searchStep; schema = 'rayman.agent_memory.search_result.v1' },
      @{ result = $summarizeStep; schema = 'rayman.agent_memory.summarize_result.v1' }
    )) {
    $result = $stepInfo.result
    if (-not [bool]$result.started -or $result.exit_code -ne 0) {
      $memoryOk = $false
      break
    }
    $json = Convert-JsonFromCommandOutput -OutputText $result.output
    if ($null -eq $json -or [string]$json.schema -ne [string]$stepInfo.schema) {
      $memoryOk = $false
      break
    }
  }

  if ($memoryOk) {
    Add-Step -Steps $steps -Name 'agent_memory_json' -Status 'PASS' -Detail 'manage_memory status/search/summarize emitted valid JSON' -LogPath $searchStep.log_path
  } else {
    Add-Step -Steps $steps -Name 'agent_memory_json' -Status 'FAIL' -Detail 'manage_memory status/search/summarize failed or emitted invalid JSON' -LogPath $searchStep.log_path
    $overall = 'FAIL'
  }
}

$pythonResolution = Resolve-RaymanHostSmokePythonCommand -WorkingDirectory $WorkspaceRoot
$schemaLog = Join-Path $logDir 'json_runtime_contracts.log'
if ([string]::IsNullOrWhiteSpace([string]$pythonResolution.path)) {
  $attemptLines = @($pythonResolution.attempts | ForEach-Object {
      "{0}: {1} ({2})" -f [string]$_.name, [string]$_.status, [string]$_.detail
    })
  $missingDetail = if ($attemptLines.Count -gt 0) {
    ($attemptLines -join [Environment]::NewLine)
  } else {
    'python/python3 not found'
  }
  Set-Content -LiteralPath $schemaLog -Value $missingDetail -Encoding UTF8
  Add-Step -Steps $steps -Name 'json_runtime_contracts' -Status 'FAIL' -Detail 'python/python3 not found' -LogPath $schemaLog
  $overall = 'FAIL'
} else {
  $schemaCheck = Invoke-RaymanHostSmokeStep -Name 'json_runtime_contracts' -LogDir $logDir -FilePath $pythonResolution.path -ArgumentList @($schemaValidator, '--workspace-root', $WorkspaceRoot, '--mode', 'runtime', '--report-path', $schemaReportPath) -WorkingDirectory $WorkspaceRoot
  if (-not [bool]$schemaCheck.started) {
    Add-Step -Steps $steps -Name 'json_runtime_contracts' -Status 'FAIL' -Detail (Get-LaunchFailureDetail -Label 'runtime JSON contract validation' -Result $schemaCheck) -LogPath $schemaCheck.log_path
    $overall = 'FAIL'
  } elseif ($schemaCheck.exit_code -eq 0) {
    Add-Step -Steps $steps -Name 'json_runtime_contracts' -Status 'PASS' -Detail 'runtime JSON contracts validated' -LogPath $schemaCheck.log_path
  } else {
    Add-Step -Steps $steps -Name 'json_runtime_contracts' -Status 'FAIL' -Detail ("runtime JSON contract validation failed (exit={0})" -f $schemaCheck.exit_code) -LogPath $schemaCheck.log_path
    $overall = 'FAIL'
  }
}

$report = [pscustomobject]@{
  schema = 'rayman.testing.host_smoke.v1'
  workspace_root = $WorkspaceRoot
  require_environment = [bool]$RequireEnvironment
  include_wsl = [bool]$IncludeWsl
  include_sandbox = [bool]$IncludeSandbox
  overall = $overall
  steps = @($steps.ToArray())
}

$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
$report | ConvertTo-Json -Depth 8

if ($overall -eq 'FAIL') {
  exit 1
}
