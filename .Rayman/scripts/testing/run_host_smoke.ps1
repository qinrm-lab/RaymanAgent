param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$IncludeWsl,
  [switch]$IncludeSandbox,
  [switch]$RequireEnvironment
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime\test_lanes'
$logDir = Join-Path $runtimeDir 'logs'
$reportPath = Join-Path $runtimeDir 'host_smoke.report.json'
$schemaReportPath = Join-Path $runtimeDir 'host_smoke.schemas.json'
$playwrightScript = Join-Path $WorkspaceRoot '.Rayman\scripts\pwa\ensure_playwright_ready.ps1'
$winAppScript = Join-Path $WorkspaceRoot '.Rayman\scripts\windows\ensure_winapp.ps1'
$winAppCoreScript = Join-Path $WorkspaceRoot '.Rayman\scripts\windows\winapp_core.ps1'
$schemaValidator = Join-Path $WorkspaceRoot '.Rayman\scripts\testing\validate_json_contracts.py'
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1
$pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $pythonCmd) {
  $pythonCmd = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
}

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

function Invoke-NativeSmokeStep {
  param(
    [string]$Name,
    [string]$FilePath,
    [string[]]$ArgumentList
  )

  $logPath = Join-Path $logDir ("{0}.log" -f $Name)
  $output = ''
  $exitCode = 0
  try {
    $output = & $FilePath @ArgumentList 2>&1 | Out-String
    $exitCode = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }
  } catch {
    $output = $_.Exception.ToString()
    $exitCode = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 1 }
  }
  Set-Content -LiteralPath $logPath -Value $output -Encoding UTF8
  return [pscustomobject]@{
    log_path = $logPath
    output = $output
    exit_code = $exitCode
  }
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

$bashCmd = Get-Command bash -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $bashCmd) {
  Add-Step -Steps $steps -Name 'bash_cli_help' -Status 'FAIL' -Detail 'bash not found'
  $overall = 'FAIL'
} else {
  $result = Invoke-NativeSmokeStep -Name 'bash_cli_help' -FilePath $bashCmd.Source -ArgumentList @('-lc', "cd '$WorkspaceRoot' && bash ./.Rayman/rayman help")
  if ($result.exit_code -eq 0 -and $result.output -match 'Rayman CLI \(v') {
    Add-Step -Steps $steps -Name 'bash_cli_help' -Status 'PASS' -Detail 'bash rayman help succeeded' -LogPath $result.log_path
  } else {
    Add-Step -Steps $steps -Name 'bash_cli_help' -Status 'FAIL' -Detail ("bash rayman help failed (exit={0})" -f $result.exit_code) -LogPath $result.log_path
    $overall = 'FAIL'
  }
}

$psHelpLog = Join-Path $logDir 'pwsh_cli_help.log'
if ($null -eq $pwshCmd) {
  Set-Content -LiteralPath $psHelpLog -Value 'pwsh not found' -Encoding UTF8
  Add-Step -Steps $steps -Name 'pwsh_cli_help' -Status 'FAIL' -Detail 'pwsh not found' -LogPath $psHelpLog
  $overall = 'FAIL'
} else {
  $psHelp = Invoke-NativeSmokeStep -Name 'pwsh_cli_help' -FilePath $pwshCmd.Source -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $WorkspaceRoot '.Rayman\rayman.ps1'), 'help')
  if ($psHelp.exit_code -eq 0 -and $psHelp.output -match 'Rayman CLI \(v') {
    Add-Step -Steps $steps -Name 'pwsh_cli_help' -Status 'PASS' -Detail 'pwsh rayman help succeeded' -LogPath $psHelp.log_path
  } else {
    Add-Step -Steps $steps -Name 'pwsh_cli_help' -Status 'FAIL' -Detail ("pwsh rayman help failed (exit={0})" -f $psHelp.exit_code) -LogPath $psHelp.log_path
    $overall = 'FAIL'
  }
}

if ($null -eq $pwshCmd) {
  $winAppLog = Join-Path $logDir 'winapp_json.log'
  Set-Content -LiteralPath $winAppLog -Value 'pwsh not found' -Encoding UTF8
  Add-Step -Steps $steps -Name 'winapp_json' -Status 'FAIL' -Detail 'pwsh not found' -LogPath $winAppLog
  $overall = 'FAIL'
} else {
  $winApp = Invoke-NativeSmokeStep -Name 'winapp_json' -FilePath $pwshCmd.Source -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $winAppScript, '-WorkspaceRoot', $WorkspaceRoot, '-Json')
  if ($winApp.exit_code -eq 0) {
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
        ("ready={0} reason={1} (not_applicable_on_current_host)" -f [bool]$winAppJson.ready, $winAppReason)
      } else {
        ("ready={0} reason={1}" -f [bool]$winAppJson.ready, $winAppReason)
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

$playwrightScopes = New-Object System.Collections.Generic.List[string]
$playwrightScopes.Add('host') | Out-Null
if ($IncludeWsl) { $playwrightScopes.Add('wsl') | Out-Null }
if ($IncludeSandbox) { $playwrightScopes.Add('sandbox') | Out-Null }

if ($null -eq $pwshCmd) {
  foreach ($scope in $playwrightScopes) {
    $scopeLog = Join-Path $logDir ("playwright_{0}.log" -f $scope)
    Set-Content -LiteralPath $scopeLog -Value 'pwsh not found' -Encoding UTF8
    Add-Step -Steps $steps -Name ("playwright_{0}" -f $scope) -Status 'FAIL' -Detail 'pwsh not found' -LogPath $scopeLog
  }
  $overall = 'FAIL'
} else {
  foreach ($scope in $playwrightScopes) {
    $result = Invoke-NativeSmokeStep -Name ("playwright_{0}" -f $scope) -FilePath $pwshCmd.Source -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $playwrightScript, '-WorkspaceRoot', $WorkspaceRoot, '-Scope', $scope, '-Require:$false', '-Json')
    if ($result.exit_code -eq 0) {
      $json = Convert-JsonFromCommandOutput -OutputText $result.output
      if ($null -ne $json -and $json.schema -eq 'rayman.playwright.windows.v2' -and [string]$json.scope -eq $scope) {
        $stepStatus = if ([bool]$json.success) { 'PASS' } elseif ($RequireEnvironment) { 'FAIL' } else { 'WARN' }
        if ($stepStatus -eq 'FAIL') { $overall = 'FAIL' } elseif ($stepStatus -eq 'WARN' -and $overall -eq 'PASS') { $overall = 'WARN' }
        Add-Step -Steps $steps -Name ("playwright_{0}" -f $scope) -Status $stepStatus -Detail ("success={0}" -f [bool]$json.success) -LogPath $result.log_path
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

$schemaLog = Join-Path $logDir 'json_runtime_contracts.log'
if ($null -eq $pythonCmd) {
  Set-Content -LiteralPath $schemaLog -Value 'python/python3 not found' -Encoding UTF8
  Add-Step -Steps $steps -Name 'json_runtime_contracts' -Status 'FAIL' -Detail 'python/python3 not found' -LogPath $schemaLog
  $overall = 'FAIL'
} else {
  $schemaCheck = Invoke-NativeSmokeStep -Name 'json_runtime_contracts' -FilePath $pythonCmd.Source -ArgumentList @($schemaValidator, '--workspace-root', $WorkspaceRoot, '--mode', 'runtime', '--report-path', $schemaReportPath)
  if ($schemaCheck.exit_code -eq 0) {
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
