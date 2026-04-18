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

$hostSmokeMutex = $null
$hostSmokeLockTaken = $false
$hostSmokeExitCode = 0
$hostSmokeMutexWaitSeconds = Get-RaymanHostSmokeMutexWaitSeconds

try {
  # Prevent concurrent host smoke runs from clobbering shared worker/runtime state.
  $hostSmokeMutex = New-RaymanHostSmokeRunMutex -WorkspaceRootPath $WorkspaceRoot
  if ($null -ne $hostSmokeMutex) {
    try {
      $hostSmokeLockTaken = $hostSmokeMutex.WaitOne(([int]$hostSmokeMutexWaitSeconds * 1000))
    } catch [System.Threading.AbandonedMutexException] {
      $hostSmokeLockTaken = $true
    }
    if (-not $hostSmokeLockTaken) {
      throw ("host smoke is already running for this workspace; waited {0} seconds for the workspace mutex." -f $hostSmokeMutexWaitSeconds)
    }
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

function Get-RaymanHostSmokeFreeTcpPort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  try {
    return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
  } finally {
    $listener.Stop()
  }
}

function Get-RaymanHostSmokeFreeUdpPort {
  $udp = New-Object System.Net.Sockets.UdpClient([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Loopback, 0))
  try {
    return ([System.Net.IPEndPoint]$udp.Client.LocalEndPoint).Port
  } finally {
    $udp.Dispose()
  }
}

function Save-RaymanHostSmokeFileSnapshot {
  param(
    [System.Collections.Generic.List[object]]$Snapshots,
    [string]$Path
  )

  $exists = Test-Path -LiteralPath $Path -PathType Leaf
  $bytes = @()
  if ($exists) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
  }
  $Snapshots.Add([pscustomobject]@{
      path = $Path
      exists = $exists
      bytes = $bytes
    }) | Out-Null
}

function Restore-RaymanHostSmokeFileSnapshots {
  param([System.Collections.Generic.List[object]]$Snapshots)

  foreach ($entry in @($Snapshots.ToArray())) {
    $path = [string]$entry.path
    if ([bool]$entry.exists) {
      $parent = Split-Path -Parent $path
      if (-not [string]::IsNullOrWhiteSpace([string]$parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
      }
      [System.IO.File]::WriteAllBytes($path, [byte[]]$entry.bytes)
    } elseif (Test-Path -LiteralPath $path -PathType Leaf) {
      Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
  }
}

function Resolve-RaymanHostSmokeWorkerFixture {
  param(
    [string]$WorkspaceRoot,
    [string]$LogDir
  )

  $projectRelative = '.Rayman\scripts\testing\fixtures\worker_smoke_app\WorkerSmokeApp.csproj'
  $projectPath = Join-Path $WorkspaceRoot $projectRelative
  $fixtureBuildRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_host_smoke_fixture_' + [Guid]::NewGuid().ToString('N'))
  $stageArtifactRelativeDir = '.Rayman/runtime/test_fixtures/worker_smoke_app/build'
  $stageSourceRoot = Join-Path $fixtureBuildRoot 'source'
  $outputDir = Join-Path $fixtureBuildRoot 'build'
  $intermediateDir = Join-Path $fixtureBuildRoot 'obj'
  $programPath = Join-Path $outputDir 'WorkerSmokeApp.dll'
  $programRelative = ($stageArtifactRelativeDir.TrimEnd('/') + '/WorkerSmokeApp.dll')

  $result = [ordered]@{
    ready = $false
    detail = ''
    project_path = $projectPath
    project_relative = $projectRelative
    staged_project_path = ''
    stage_root = $stageSourceRoot
    temp_root = $fixtureBuildRoot
    output_dir = $outputDir
    program_path = $programPath
    program_relative = $programRelative
    log_path = ''
  }

  if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
    $result.detail = ("worker smoke fixture project missing: {0}" -f $projectRelative)
    return [pscustomobject]$result
  }

  $dotnetCmd = Resolve-RaymanHostSmokeCommandPath -Names @('dotnet.exe', 'dotnet')
  if ([string]::IsNullOrWhiteSpace($dotnetCmd)) {
    $result.detail = 'dotnet not found; cannot build worker smoke fixture'
    return [pscustomobject]$result
  }

  if (Test-Path -LiteralPath $outputDir) {
    Remove-Item -LiteralPath $outputDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $intermediateDir) {
    Remove-Item -LiteralPath $intermediateDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (-not (Test-Path -LiteralPath $fixtureBuildRoot -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $fixtureBuildRoot | Out-Null
  }

  $buildProjectPath = $projectPath
  if (Get-Command Initialize-RaymanHostSmokeStagedProject -ErrorAction SilentlyContinue) {
    try {
      $stagedProject = Initialize-RaymanHostSmokeStagedProject -SourceProjectPath $projectPath -StageRoot $stageSourceRoot
      if ($null -ne $stagedProject -and -not [string]::IsNullOrWhiteSpace([string]$stagedProject.staged_project_path)) {
        $buildProjectPath = [string]$stagedProject.staged_project_path
        $result.staged_project_path = $buildProjectPath
      }
    } catch {
      $result.detail = ("worker fixture staging failed: {0}" -f $_.Exception.Message)
      return [pscustomobject]$result
    }
  }

  $intermediateDirArg = $intermediateDir
  if (-not $intermediateDirArg.EndsWith('\')) {
    $intermediateDirArg += '\'
  }

  $buildStep = Invoke-RaymanHostSmokeStep -Name 'worker_loopback_fixture_build' -LogDir $LogDir -FilePath $dotnetCmd -ArgumentList @(
    'build',
    $buildProjectPath,
    '-c',
    'Debug',
    '-nologo',
    '-o',
    $outputDir,
    ("-p:MSBuildProjectExtensionsPath={0}" -f $intermediateDirArg),
    ("-p:BaseIntermediateOutputPath={0}" -f $intermediateDirArg)
  ) -WorkingDirectory $WorkspaceRoot -TimeoutSeconds 180
  $result.log_path = [string]$buildStep.log_path

  if (-not [bool]$buildStep.started) {
    $result.detail = Get-LaunchFailureDetail -Label 'worker fixture build' -Result $buildStep
    return [pscustomobject]$result
  }
  if ([int]$buildStep.exit_code -ne 0) {
    $result.detail = ("worker fixture build failed (exit={0})" -f [int]$buildStep.exit_code)
    return [pscustomobject]$result
  }
  if (-not (Test-Path -LiteralPath $programPath -PathType Leaf)) {
    $result.detail = ("worker fixture build missing output: {0}" -f $programRelative)
    return [pscustomobject]$result
  }

  $result.ready = $true
  $result.detail = ("worker fixture built: {0}" -f $programRelative)
  return [pscustomobject]$result
}

function Invoke-RaymanHostSmokeWorkerCli {
  param(
    [string]$Name,
    [string]$PowerShellPath,
    [string]$WorkspaceRoot,
    [string]$LogDir,
    [string[]]$WorkerArgs
  )

  $argumentList = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    (Join-Path $WorkspaceRoot '.Rayman\rayman.ps1'),
    'worker'
  )
  if ($null -ne $WorkerArgs) {
    $argumentList += @($WorkerArgs)
  }

  return (Invoke-RaymanHostSmokeStep -Name $Name -LogDir $LogDir -FilePath $PowerShellPath -ArgumentList $argumentList -WorkingDirectory $WorkspaceRoot)
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

$workerHostScript = Join-Path $WorkspaceRoot '.Rayman\scripts\worker\worker_host.ps1'
if (-not (Test-RaymanWindowsPlatform)) {
  Add-Step -Steps $steps -Name 'worker_loopback' -Status 'WARN' -Detail 'worker smoke skipped on non-Windows host'
  if ($overall -eq 'PASS') { $overall = 'WARN' }
} elseif ([string]::IsNullOrWhiteSpace($pwshCmd)) {
  Add-Step -Steps $steps -Name 'worker_loopback' -Status 'FAIL' -Detail 'pwsh not found'
  $overall = 'FAIL'
} elseif (-not (Test-Path -LiteralPath $workerHostScript -PathType Leaf)) {
  Add-Step -Steps $steps -Name 'worker_loopback' -Status 'FAIL' -Detail ("worker host script missing: {0}" -f $workerHostScript)
  $overall = 'FAIL'
} else {
  $workerFixture = Resolve-RaymanHostSmokeWorkerFixture -WorkspaceRoot $WorkspaceRoot -LogDir $logDir
  if (-not [bool]$workerFixture.ready) {
    Add-Step -Steps $steps -Name 'worker_loopback_fixture_build' -Status 'FAIL' -Detail ([string]$workerFixture.detail) -LogPath ([string]$workerFixture.log_path)
    $overall = 'FAIL'
  } else {
    $workerFixtureProgramRelative = [string]$workerFixture.program_relative
    Add-Step -Steps $steps -Name 'worker_loopback_fixture_build' -Status 'PASS' -Detail ([string]$workerFixture.detail) -LogPath ([string]$workerFixture.log_path)

  $workerSnapshots = New-Object 'System.Collections.Generic.List[object]'
  foreach ($path in @(
      (Join-Path $WorkspaceRoot '.Rayman\state\workers\registry.json'),
      (Join-Path $WorkspaceRoot '.Rayman\state\workers\active.json'),
      (Join-Path $WorkspaceRoot '.Rayman\runtime\workers\discovery.last.json'),
      (Join-Path $WorkspaceRoot '.Rayman\runtime\workers\debug.last.json'),
      (Join-Path $WorkspaceRoot '.Rayman\runtime\worker\host.status.json'),
      (Join-Path $WorkspaceRoot '.Rayman\runtime\worker\beacon.last.json'),
      (Join-Path $WorkspaceRoot '.Rayman\runtime\worker\sync.last.json'),
      (Join-Path $WorkspaceRoot '.Rayman\runtime\worker\upgrade.last.json'),
      (Join-Path $WorkspaceRoot '.Rayman\runtime\worker\debug.session.last.json'),
      (Join-Path $WorkspaceRoot '.Rayman\runtime\worker\vsdbg.last.json')
    )) {
    Save-RaymanHostSmokeFileSnapshot -Snapshots $workerSnapshots -Path $path
  }

  $workerRuntimeDirs = @(
    (Join-Path $WorkspaceRoot '.Rayman\runtime\worker\uploads'),
    (Join-Path $WorkspaceRoot '.Rayman\runtime\worker\staging'),
    (Join-Path $WorkspaceRoot '.Rayman\runtime\worker\sync-temp'),
    (Join-Path $WorkspaceRoot '.Rayman\runtime\worker\upgrade-temp')
  )
  $workerRuntimeDirExists = @{}
  foreach ($dir in $workerRuntimeDirs) {
    $workerRuntimeDirExists[$dir] = (Test-Path -LiteralPath $dir -PathType Container)
  }

  $workerEnvNames = @(
    'RAYMAN_WORKER_DISCOVERY_PORT',
    'RAYMAN_WORKER_CONTROL_PORT',
    'RAYMAN_WORKER_DISCOVERY_LISTEN_SECONDS',
    'RAYMAN_WORKER_VSDBG_PATH',
    'RAYMAN_WORKER_LAN_ENABLED',
    'RAYMAN_WORKER_AUTH_TOKEN',
    'RAYMAN_WORKER_ALLOW_PROTECTED_LOCAL'
  )
  $workerEnvBackup = @{}
  foreach ($name in $workerEnvNames) {
    $workerEnvBackup[$name] = [Environment]::GetEnvironmentVariable($name)
  }

  $workerHostProcess = $null
  $workerHostStdoutLog = Join-Path $logDir 'worker_loopback_host.stdout.log'
  $workerHostStderrLog = Join-Path $logDir 'worker_loopback_host.stderr.log'
  $workerHostStatusPath = Join-Path $WorkspaceRoot '.Rayman\runtime\worker\host.status.json'
  $workerHostBeaconPath = Join-Path $WorkspaceRoot '.Rayman\runtime\worker\beacon.last.json'
  $workerHostReadyTimeoutSeconds = Get-EnvIntCompat -Name 'RAYMAN_HOST_SMOKE_WORKER_READY_TIMEOUT_SECONDS' -Default 45 -Min 20 -Max 180
  $workerOk = $true
  try {
    $workerHostStatusBaselineUtc = if (Test-Path -LiteralPath $workerHostStatusPath -PathType Leaf) { (Get-Item -LiteralPath $workerHostStatusPath).LastWriteTimeUtc } else { [datetime]::MinValue }
    $workerHostBeaconBaselineUtc = if (Test-Path -LiteralPath $workerHostBeaconPath -PathType Leaf) { (Get-Item -LiteralPath $workerHostBeaconPath).LastWriteTimeUtc } else { [datetime]::MinValue }

    [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_DISCOVERY_PORT', [string](Get-RaymanHostSmokeFreeUdpPort))
    [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_CONTROL_PORT', [string](Get-RaymanHostSmokeFreeTcpPort))
    [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_DISCOVERY_LISTEN_SECONDS', '8')
    [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_VSDBG_PATH', $pwshCmd)
    [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_LAN_ENABLED', '0')
    [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', $null)
    [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_ALLOW_PROTECTED_LOCAL', '1')

    $workerHostProcess = Start-Process -FilePath $pwshCmd -ArgumentList @(
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      $workerHostScript,
      '-WorkspaceRoot',
      $WorkspaceRoot
    ) -WorkingDirectory $WorkspaceRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $workerHostStdoutLog -RedirectStandardError $workerHostStderrLog

    $workerHostReady = $false
    $workerHostReadyDetail = ''
    $workerHostReadyDeadline = (Get-Date).AddSeconds($workerHostReadyTimeoutSeconds)
    while ((Get-Date) -lt $workerHostReadyDeadline) {
      if ($workerHostProcess.HasExited) {
        $workerHostReadyDetail = ("worker host exited early (exit={0})" -f $workerHostProcess.ExitCode)
        break
      }

      $statusFresh = (Test-Path -LiteralPath $workerHostStatusPath -PathType Leaf) -and ((Get-Item -LiteralPath $workerHostStatusPath).LastWriteTimeUtc -gt $workerHostStatusBaselineUtc)
      $beaconFresh = (Test-Path -LiteralPath $workerHostBeaconPath -PathType Leaf) -and ((Get-Item -LiteralPath $workerHostBeaconPath).LastWriteTimeUtc -gt $workerHostBeaconBaselineUtc)
      if ($statusFresh -and $beaconFresh) {
        $workerHostReady = $true
        break
      }

      Start-Sleep -Milliseconds 250
    }

    if (-not $workerHostReady) {
      if ([string]::IsNullOrWhiteSpace($workerHostReadyDetail)) {
        $workerHostReadyDetail = ("worker host did not refresh host.status/beacon within {0} seconds" -f $workerHostReadyTimeoutSeconds)
      }
      Add-Step -Steps $steps -Name 'worker_loopback_discover' -Status 'FAIL' -Detail $workerHostReadyDetail -LogPath $workerHostStderrLog
      $overall = 'FAIL'
      $workerOk = $false
    } else {
      $discoverStep = Invoke-RaymanHostSmokeWorkerCli -Name 'worker_loopback_discover' -PowerShellPath $pwshCmd -WorkspaceRoot $WorkspaceRoot -LogDir $logDir -WorkerArgs @('discover', '--json')
      $discoverJson = if ($discoverStep.exit_code -eq 0) { Convert-JsonFromCommandOutput -OutputText $discoverStep.output } else { $null }
      if ($discoverStep.exit_code -ne 0 -or $null -eq $discoverJson -or @($discoverJson.workers).Count -lt 1) {
        Add-Step -Steps $steps -Name 'worker_loopback_discover' -Status 'FAIL' -Detail ("discover failed (exit={0})" -f $discoverStep.exit_code) -LogPath $discoverStep.log_path
        $overall = 'FAIL'
        $workerOk = $false
      } else {
        Add-Step -Steps $steps -Name 'worker_loopback_discover' -Status 'PASS' -Detail ("workers={0}" -f @($discoverJson.workers).Count) -LogPath $discoverStep.log_path
      }
    }

    $selectedWorker = $null
    if ($workerOk) {
      $expectedControlPort = 0
      $expectedControlPortRaw = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_CONTROL_PORT')
      if (-not [int]::TryParse([string]$expectedControlPortRaw, [ref]$expectedControlPort)) {
        $expectedControlPort = 0
      }
      $selectedWorker = Select-RaymanHostSmokeLoopbackWorker -Workers @($discoverJson.workers) -ExpectedControlPort $expectedControlPort
      if ($null -eq $selectedWorker) {
        Add-Step -Steps $steps -Name 'worker_loopback_select' -Status 'FAIL' -Detail ("discover did not surface the loopback worker (expected_control_port={0})" -f $expectedControlPort) -LogPath $discoverStep.log_path
        $overall = 'FAIL'
        $workerOk = $false
      }
    }

    $workerId = if ($workerOk -and $null -ne $selectedWorker -and $selectedWorker.PSObject.Properties['worker_id']) { [string]$selectedWorker.worker_id } else { '' }
    if ($workerOk) {
      $useStep = Invoke-RaymanHostSmokeWorkerCli -Name 'worker_loopback_use' -PowerShellPath $pwshCmd -WorkspaceRoot $WorkspaceRoot -LogDir $logDir -WorkerArgs @('use', '--id', $workerId, '--json')
      $useJson = if ($useStep.exit_code -eq 0) { Convert-JsonFromCommandOutput -OutputText $useStep.output } else { $null }
      if ($useStep.exit_code -ne 0 -or $null -eq $useJson -or [string]$useJson.worker_id -ne $workerId) {
        Add-Step -Steps $steps -Name 'worker_loopback_use' -Status 'FAIL' -Detail ("use failed (exit={0})" -f $useStep.exit_code) -LogPath $useStep.log_path
        $overall = 'FAIL'
        $workerOk = $false
      } else {
        Add-Step -Steps $steps -Name 'worker_loopback_use' -Status 'PASS' -Detail ("worker_id={0}" -f $workerId) -LogPath $useStep.log_path
      }
    }

    if ($workerOk) {
      $statusStep = Invoke-RaymanHostSmokeWorkerCli -Name 'worker_loopback_status' -PowerShellPath $pwshCmd -WorkspaceRoot $WorkspaceRoot -LogDir $logDir -WorkerArgs @('status', '--json')
      $statusJson = if ($statusStep.exit_code -eq 0) { Convert-JsonFromCommandOutput -OutputText $statusStep.output } else { $null }
      if ($statusStep.exit_code -ne 0 -or
          $null -eq $statusJson -or
          [string]$statusJson.schema -ne 'rayman.worker.status.v1' -or
          -not [bool]$statusJson.debugger_ready -or
          [string]$statusJson.address -ne '127.0.0.1' -or
          [string]$statusJson.control.base_url -notmatch '^http://127\.0\.0\.1:' -or
          -not [bool]$statusJson.shared_worker -or
          [string]$statusJson.session_isolation -ne 'multi_client_staged_only' -or
          (@($statusJson.supported_sync_modes) -notcontains 'staged')) {
        Add-Step -Steps $steps -Name 'worker_loopback_status' -Status 'FAIL' -Detail ("status failed (exit={0})" -f $statusStep.exit_code) -LogPath $statusStep.log_path
        $overall = 'FAIL'
        $workerOk = $false
      } else {
        Add-Step -Steps $steps -Name 'worker_loopback_status' -Status 'PASS' -Detail ("debugger_ready={0} control={1}" -f [bool]$statusJson.debugger_ready, [string]$statusJson.control.base_url) -LogPath $statusStep.log_path
      }
    }

    if ($workerOk) {
      $syncAttachedStep = Invoke-RaymanHostSmokeWorkerCli -Name 'worker_loopback_sync_attached' -PowerShellPath $pwshCmd -WorkspaceRoot $WorkspaceRoot -LogDir $logDir -WorkerArgs @('sync', '--mode', 'attached', '--json')
      $syncAttachedJson = Convert-JsonFromCommandOutput -OutputText $syncAttachedStep.output
      $attachedRejected = ($syncAttachedStep.exit_code -ne 0) -and
        $null -ne $syncAttachedJson -and
        [string]$syncAttachedJson.schema -eq 'rayman.worker.cli_error.v1' -and
        [string]$syncAttachedJson.error -match 'staged sync only|shared worker only supports staged mode'
      if (-not $attachedRejected) {
        Add-Step -Steps $steps -Name 'worker_loopback_sync_attached' -Status 'FAIL' -Detail ("attached sync should fail-fast on shared workers (exit={0})" -f $syncAttachedStep.exit_code) -LogPath $syncAttachedStep.log_path
        $overall = 'FAIL'
      } else {
        Add-Step -Steps $steps -Name 'worker_loopback_sync_attached' -Status 'PASS' -Detail 'attached sync correctly rejected for shared staged-only worker' -LogPath $syncAttachedStep.log_path
      }
    }

    if ($workerOk) {
      $syncStagedStep = Invoke-RaymanHostSmokeWorkerCli -Name 'worker_loopback_sync_staged' -PowerShellPath $pwshCmd -WorkspaceRoot $WorkspaceRoot -LogDir $logDir -WorkerArgs @('sync', '--mode', 'staged', '--json')
      $syncStagedJson = if ($syncStagedStep.exit_code -eq 0) { Convert-JsonFromCommandOutput -OutputText $syncStagedStep.output } else { $null }
      if ($syncStagedStep.exit_code -ne 0 -or $null -eq $syncStagedJson -or [string]$syncStagedJson.mode -ne 'staged') {
        Add-Step -Steps $steps -Name 'worker_loopback_sync_staged' -Status 'FAIL' -Detail ("staged sync failed (exit={0})" -f $syncStagedStep.exit_code) -LogPath $syncStagedStep.log_path
        $overall = 'FAIL'
        $workerOk = $false
      } else {
        Add-Step -Steps $steps -Name 'worker_loopback_sync_staged' -Status 'PASS' -Detail 'staged sync succeeded' -LogPath $syncStagedStep.log_path
      }
    }

    if ($workerOk) {
      $execStep = Invoke-RaymanHostSmokeWorkerCli -Name 'worker_loopback_exec' -PowerShellPath $pwshCmd -WorkspaceRoot $WorkspaceRoot -LogDir $logDir -WorkerArgs @('exec', '--json', 'Write-Output', 'worker-smoke-ok')
      $execJson = if ($execStep.exit_code -eq 0) { Convert-JsonFromCommandOutput -OutputText $execStep.output } else { $null }
      if ($execStep.exit_code -ne 0 -or
          $null -eq $execJson -or
          -not [bool]$execJson.success -or
          [string]$execJson.workspace_mode -ne 'staged' -or
          ($execJson.output_lines -notcontains 'worker-smoke-ok')) {
        Add-Step -Steps $steps -Name 'worker_loopback_exec' -Status 'FAIL' -Detail ("exec failed (exit={0})" -f $execStep.exit_code) -LogPath $execStep.log_path
        $overall = 'FAIL'
        $workerOk = $false
      } else {
        Add-Step -Steps $steps -Name 'worker_loopback_exec' -Status 'PASS' -Detail 'remote exec succeeded from staged client session' -LogPath $execStep.log_path
      }
    }

    if ($workerOk) {
      $stagingRoot = ''
      if ($null -ne $syncStagedJson -and $syncStagedJson.PSObject.Properties['sync_manifest']) {
        $syncManifest = $syncStagedJson.sync_manifest
        if ($null -ne $syncManifest -and $syncManifest.PSObject.Properties['staging_root']) {
          $stagingRoot = [string]$syncManifest.staging_root
        }
      }
      if ([string]::IsNullOrWhiteSpace($stagingRoot) -or -not (Test-Path -LiteralPath $stagingRoot -PathType Container)) {
        Add-Step -Steps $steps -Name 'worker_loopback_fixture_stage' -Status 'FAIL' -Detail 'staged sync manifest missing staging_root'
        $overall = 'FAIL'
        $workerOk = $false
      } else {
        $stageRelativeDir = Split-Path -Parent (($workerFixtureProgramRelative -replace '/', '\'))
        $stageTargetDir = if ([string]::IsNullOrWhiteSpace($stageRelativeDir)) { $stagingRoot } else { Join-Path $stagingRoot $stageRelativeDir }
        New-Item -ItemType Directory -Force -Path $stageTargetDir | Out-Null
        foreach ($artifact in @(Get-ChildItem -LiteralPath ([string]$workerFixture.output_dir) -File -Force -ErrorAction SilentlyContinue)) {
          Copy-Item -LiteralPath $artifact.FullName -Destination (Join-Path $stageTargetDir $artifact.Name) -Force
        }
        if (-not (Test-Path -LiteralPath (Join-Path $stageTargetDir 'WorkerSmokeApp.dll') -PathType Leaf)) {
          Add-Step -Steps $steps -Name 'worker_loopback_fixture_stage' -Status 'FAIL' -Detail ("staged fixture missing output: {0}" -f $workerFixtureProgramRelative)
          $overall = 'FAIL'
          $workerOk = $false
        } else {
          Add-Step -Steps $steps -Name 'worker_loopback_fixture_stage' -Status 'PASS' -Detail ("staged fixture path={0}" -f $workerFixtureProgramRelative)
        }
      }
    }

    if ($workerOk) {
      $debugStep = Invoke-RaymanHostSmokeWorkerCli -Name 'worker_loopback_debug_prepare' -PowerShellPath $pwshCmd -WorkspaceRoot $WorkspaceRoot -LogDir $logDir -WorkerArgs @('debug', '--mode', 'launch', '--program', ($workerFixtureProgramRelative -replace '\\', '/'), '--json')
      $debugJson = if ($debugStep.exit_code -eq 0) { Convert-JsonFromCommandOutput -OutputText $debugStep.output } else { $null }
      $hasSourceMap = $false
      if ($null -ne $debugJson -and $debugJson.PSObject.Properties['source_file_map']) {
        $sourceFileMap = $debugJson.source_file_map
        if ($sourceFileMap -is [System.Collections.IDictionary]) {
          $hasSourceMap = ($sourceFileMap.Count -gt 0)
        } elseif ($null -ne $sourceFileMap) {
          $hasSourceMap = (@($sourceFileMap.PSObject.Properties).Count -gt 0)
        }
      }
      if ($debugStep.exit_code -ne 0 -or $null -eq $debugJson -or [string]$debugJson.schema -ne 'rayman.worker.debug_session.v1' -or -not [bool]$debugJson.debugger_ready -or -not $hasSourceMap) {
        Add-Step -Steps $steps -Name 'worker_loopback_debug_prepare' -Status 'FAIL' -Detail ("debug prepare failed (exit={0})" -f $debugStep.exit_code) -LogPath $debugStep.log_path
        $overall = 'FAIL'
        $workerOk = $false
      } else {
        Add-Step -Steps $steps -Name 'worker_loopback_debug_prepare' -Status 'PASS' -Detail ("workspace_mode={0}" -f [string]$debugJson.workspace_mode) -LogPath $debugStep.log_path
      }
    }

      $clearStep = Invoke-RaymanHostSmokeWorkerCli -Name 'worker_loopback_clear' -PowerShellPath $pwshCmd -WorkspaceRoot $WorkspaceRoot -LogDir $logDir -WorkerArgs @('clear', '--json')
      $clearJson = if ($clearStep.exit_code -eq 0) { Convert-JsonFromCommandOutput -OutputText $clearStep.output } else { $null }
      if ($clearStep.exit_code -ne 0 -or $null -eq $clearJson -or [string]$clearJson.schema -ne 'rayman.worker.clear.result.v1') {
      Add-Step -Steps $steps -Name 'worker_loopback_clear' -Status 'FAIL' -Detail ("clear failed (exit={0})" -f $clearStep.exit_code) -LogPath $clearStep.log_path
      $overall = 'FAIL'
    } else {
      Add-Step -Steps $steps -Name 'worker_loopback_clear' -Status 'PASS' -Detail 'active worker cleared' -LogPath $clearStep.log_path
    }
  } finally {
    if ($null -ne $workerHostProcess) {
      try {
        if (-not $workerHostProcess.HasExited) {
          Stop-Process -Id $workerHostProcess.Id -Force -ErrorAction SilentlyContinue
          Start-Sleep -Milliseconds 400
        }
      } catch {}
    }

    foreach ($name in $workerEnvNames) {
      [Environment]::SetEnvironmentVariable($name, $workerEnvBackup[$name])
    }
    Restore-RaymanHostSmokeFileSnapshots -Snapshots $workerSnapshots
    foreach ($dir in $workerRuntimeDirs) {
      if (-not [bool]$workerRuntimeDirExists[$dir] -and (Test-Path -LiteralPath $dir -PathType Container)) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
    if ($null -ne $workerFixture -and $workerFixture.PSObject.Properties['temp_root'] -and -not [string]::IsNullOrWhiteSpace([string]$workerFixture.temp_root)) {
      Remove-Item -LiteralPath ([string]$workerFixture.temp_root) -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
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
  generated_at = (Get-Date).ToString('o')
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
  $hostSmokeExitCode = 1
}
} finally {
  if ($hostSmokeLockTaken -and $null -ne $hostSmokeMutex) {
    try { $hostSmokeMutex.ReleaseMutex() } catch {}
  }
  if ($null -ne $hostSmokeMutex) {
    try { $hostSmokeMutex.Dispose() } catch {}
  }
}

exit $hostSmokeExitCode
