param(
  [string]$StatePath = '',
  [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
  throw "common.ps1 not found: $commonPath"
}
. $commonPath

$watchLifecycleLibPath = Join-Path $PSScriptRoot 'watch_lifecycle.lib.ps1'
if (-not (Test-Path -LiteralPath $watchLifecycleLibPath -PathType Leaf)) {
  throw "watch_lifecycle.lib.ps1 not found: $watchLifecycleLibPath"
}
. $watchLifecycleLibPath

$embeddedLibPath = Join-Path $PSScriptRoot 'embedded_watchers.lib.ps1'
if (-not (Test-Path -LiteralPath $embeddedLibPath -PathType Leaf)) {
  throw "embedded_watchers.lib.ps1 not found: $embeddedLibPath"
}
. $embeddedLibPath

function Get-RaymanCodexDesktopBootstrapDefaultStatePath {
  $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
  if ([string]::IsNullOrWhiteSpace($localAppData)) {
    $userHome = Get-RaymanUserHomePath
    if (-not [string]::IsNullOrWhiteSpace($userHome)) {
      $localAppData = Join-Path $userHome 'AppData\Local'
    }
  }
  if ([string]::IsNullOrWhiteSpace($localAppData)) {
    throw 'codex desktop bootstrap could not resolve LOCALAPPDATA.'
  }
  return (Join-Path $localAppData 'Rayman\state\workspace_source.json')
}

function Get-RaymanCodexDesktopBootstrapRuntimeRoot {
  param([string]$ResolvedStatePath)

  $stateDir = Split-Path -Parent $ResolvedStatePath
  $userRoot = Split-Path -Parent $stateDir
  return (Join-Path $userRoot 'runtime')
}

function Get-RaymanCodexDesktopBootstrapReportPath {
  param([string]$ResolvedStatePath)

  return (Join-Path (Get-RaymanCodexDesktopBootstrapRuntimeRoot -ResolvedStatePath $ResolvedStatePath) 'codex_desktop_bootstrap.last.json')
}

function Get-RaymanCodexDesktopBootstrapActiveIndexPath {
  param([string]$ResolvedStatePath)

  return (Join-Path (Get-RaymanCodexDesktopBootstrapRuntimeRoot -ResolvedStatePath $ResolvedStatePath) 'codex_desktop_bootstrap.active.json')
}

function Get-RaymanCodexDesktopBootstrapStateFilePath {
  param([string]$ResolvedStatePath)

  return (Join-Path (Get-RaymanCodexDesktopBootstrapRuntimeRoot -ResolvedStatePath $ResolvedStatePath) 'codex_desktop_bootstrap.state.json')
}

function Get-RaymanCodexDesktopBootstrapPidFilePath {
  param([string]$ResolvedStatePath)

  return (Join-Path (Get-RaymanCodexDesktopBootstrapRuntimeRoot -ResolvedStatePath $ResolvedStatePath) 'codex_desktop_bootstrap.pid')
}

function Test-RaymanCodexDesktopWatchAutoStartEnabled {
  return (Get-RaymanEnvBool -Name 'RAYMAN_CODEX_DESKTOP_WATCH_AUTO_START_ENABLED' -Default $true)
}

function Get-RaymanCodexDesktopBootstrapPollMs {
  return (Get-RaymanEnvInt -Name 'RAYMAN_CODEX_DESKTOP_BOOTSTRAP_POLL_MS' -Default 5000 -Min 1000 -Max 60000)
}

function Get-RaymanCodexDesktopActiveSessionSeconds {
  return (Get-RaymanEnvInt -Name 'RAYMAN_CODEX_DESKTOP_ACTIVE_SESSION_SECONDS' -Default 120 -Min 30 -Max 3600)
}

function Get-RaymanCodexDesktopStopGraceSeconds {
  return (Get-RaymanEnvInt -Name 'RAYMAN_CODEX_DESKTOP_STOP_GRACE_SECONDS' -Default 900 -Min 60 -Max 86400)
}

function Write-RaymanCodexDesktopBootstrapReport {
  param(
    [string]$ReportPath,
    [hashtable]$Payload
  )

  if ([string]::IsNullOrWhiteSpace([string]$ReportPath) -or $null -eq $Payload) {
    return
  }

  $reportDir = Split-Path -Parent $ReportPath
  if (-not [string]::IsNullOrWhiteSpace([string]$reportDir) -and -not (Test-Path -LiteralPath $reportDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
  }

  Write-RaymanUtf8NoBom -Path $ReportPath -Content ((($Payload | ConvertTo-Json -Depth 8).TrimEnd()) + "`n")
}

function Test-RaymanCodexDesktopBootstrapProcess {
  param(
    [int]$ProcessId,
    [string]$ScriptPath,
    [string]$StatePath
  )

  if ($ProcessId -le 0) {
    return $false
  }

  if (-not (Test-RaymanWindowsPlatform)) {
    return (Test-RaymanTrackedProcessAlive -ProcessId $ProcessId)
  }

  $proc = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $ProcessId) -ErrorAction SilentlyContinue
  if ($null -eq $proc) {
    return $false
  }

  $name = [string]$proc.Name
  if ($name -notin @('powershell.exe', 'pwsh.exe')) {
    return $false
  }

  $cmd = ([string]$proc.CommandLine).ToLowerInvariant().Replace('/', '\')
  $scriptNeedle = Normalize-RaymanWatchPathForMatch -PathValue $ScriptPath
  if (-not [string]::IsNullOrWhiteSpace([string]$scriptNeedle) -and -not $cmd.Contains($scriptNeedle)) {
    return $false
  }

  $stateNeedle = Normalize-RaymanWatchPathForMatch -PathValue $StatePath
  if (-not [string]::IsNullOrWhiteSpace([string]$stateNeedle) -and -not $cmd.Contains($stateNeedle)) {
    return $false
  }

  return $true
}

function Initialize-RaymanCodexDesktopBootstrapPidFile {
  param(
    [object]$State,
    [string]$ScriptPath
  )

  $result = [ordered]@{
    already_running = $false
    existing_pid = 0
    stale_pid = 0
  }

  if ($null -eq $State) {
    return [pscustomobject]$result
  }

  $pidFilePath = [string]$State.PidFilePath
  $existingPid = Get-RaymanPidFromFile -PidFilePath $pidFilePath
  if ($existingPid -gt 0 -and $existingPid -ne $PID) {
    $result.existing_pid = [int]$existingPid
    if (Test-RaymanCodexDesktopBootstrapProcess -ProcessId $existingPid -ScriptPath $ScriptPath -StatePath ([string]$State.ResolvedStatePath)) {
      $result.already_running = $true
      return [pscustomobject]$result
    }

    $result.stale_pid = [int]$existingPid
    try {
      Remove-Item -LiteralPath $pidFilePath -Force -ErrorAction SilentlyContinue
    } catch {}
  }

  Set-Content -LiteralPath $pidFilePath -Value $PID -NoNewline -Encoding ASCII
  return [pscustomobject]$result
}

function Read-RaymanCodexDesktopBootstrapState {
  param([string]$ResolvedStatePath)

  $stateFilePath = Get-RaymanCodexDesktopBootstrapStateFilePath -ResolvedStatePath $ResolvedStatePath
  $doc = Read-RaymanJsonFile -Path $stateFilePath
  $workspaceMap = [ordered]@{}
  if ([bool]$doc.Exists -and -not [bool]$doc.ParseFailed -and $null -ne $doc.Obj) {
    $existingMap = Get-RaymanMapValue -Map $doc.Obj -Key 'workspaces' -Default $null
    $workspaceMap = ConvertTo-RaymanStringKeyMap -InputObject $existingMap
  }

  return [pscustomobject]@{
    ResolvedStatePath = $ResolvedStatePath
    RuntimeRoot = (Get-RaymanCodexDesktopBootstrapRuntimeRoot -ResolvedStatePath $ResolvedStatePath)
    ReportPath = (Get-RaymanCodexDesktopBootstrapReportPath -ResolvedStatePath $ResolvedStatePath)
    ActiveIndexPath = (Get-RaymanCodexDesktopBootstrapActiveIndexPath -ResolvedStatePath $ResolvedStatePath)
    StateFilePath = $stateFilePath
    PidFilePath = (Get-RaymanCodexDesktopBootstrapPidFilePath -ResolvedStatePath $ResolvedStatePath)
    PollMs = (Get-RaymanCodexDesktopBootstrapPollMs)
    ActiveSessionSeconds = (Get-RaymanCodexDesktopActiveSessionSeconds)
    SessionLookbackHours = (Get-RaymanNetworkResumeDesktopSessionLookbackHours)
    StopGraceSeconds = (Get-RaymanCodexDesktopStopGraceSeconds)
    Workspaces = $workspaceMap
    ActiveWorkspaces = [ordered]@{}
  }
}

function Save-RaymanCodexDesktopBootstrapState {
  param([object]$State)

  if ($null -eq $State) { return }
  $runtimeRoot = [string]$State.RuntimeRoot
  if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
  }

  $payload = [ordered]@{
    schema = 'rayman.codex.desktop_bootstrap.state.v1'
    generated_at = (Get-Date).ToString('o')
    workspaces = [ordered]@{}
  }
  foreach ($key in @((ConvertTo-RaymanStringKeyMap -InputObject $State.Workspaces).Keys | Sort-Object)) {
    $entry = Get-RaymanMapValue -Map $State.Workspaces -Key $key -Default $null
    if ($null -eq $entry) { continue }
    $payload.workspaces[$key] = [ordered]@{
      workspace_root = [string](Get-RaymanMapValue -Map $entry -Key 'workspace_root' -Default '')
      last_session_id = [string](Get-RaymanMapValue -Map $entry -Key 'last_session_id' -Default '')
      last_session_path = [string](Get-RaymanMapValue -Map $entry -Key 'last_session_path' -Default '')
      last_session_activity_at = [string](Get-RaymanMapValue -Map $entry -Key 'last_session_activity_at' -Default '')
      last_observed_activity_at = [string](Get-RaymanMapValue -Map $entry -Key 'last_observed_activity_at' -Default '')
      last_start_attempt_at = [string](Get-RaymanMapValue -Map $entry -Key 'last_start_attempt_at' -Default '')
      last_stop_attempt_at = [string](Get-RaymanMapValue -Map $entry -Key 'last_stop_attempt_at' -Default '')
      watch_state = [string](Get-RaymanMapValue -Map $entry -Key 'watch_state' -Default '')
      last_error = [string](Get-RaymanMapValue -Map $entry -Key 'last_error' -Default '')
    }
  }
  Write-RaymanUtf8NoBom -Path ([string]$State.StateFilePath) -Content (($payload | ConvertTo-Json -Depth 8).TrimEnd() + "`n")
}

function Save-RaymanCodexDesktopBootstrapActiveIndex {
  param([object]$State)

  if ($null -eq $State) { return }
  $runtimeRoot = [string]$State.RuntimeRoot
  if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
  }

  $payload = [ordered]@{
    schema = 'rayman.codex.desktop_bootstrap.active_index.v1'
    generated_at = (Get-Date).ToString('o')
    active_session_seconds = [int]$State.ActiveSessionSeconds
    workspaces = @()
  }

  foreach ($key in @((ConvertTo-RaymanStringKeyMap -InputObject $State.ActiveWorkspaces).Keys | Sort-Object)) {
    $entry = Get-RaymanMapValue -Map $State.ActiveWorkspaces -Key $key -Default $null
    if ($null -eq $entry) { continue }
    $payload.workspaces += [ordered]@{
      workspace_key = [string]$key
      workspace_root = [string](Get-RaymanMapValue -Map $entry -Key 'workspace_root' -Default '')
      last_session_id = [string](Get-RaymanMapValue -Map $entry -Key 'last_session_id' -Default '')
      last_session_path = [string](Get-RaymanMapValue -Map $entry -Key 'last_session_path' -Default '')
      activity_at = [string](Get-RaymanMapValue -Map $entry -Key 'activity_at' -Default '')
      activated_at = [string](Get-RaymanMapValue -Map $entry -Key 'activated_at' -Default '')
      activation_source = [string](Get-RaymanMapValue -Map $entry -Key 'activation_source' -Default '')
    }
  }

  Write-RaymanUtf8NoBom -Path ([string]$State.ActiveIndexPath) -Content (($payload | ConvertTo-Json -Depth 8).TrimEnd() + "`n")
}

function Get-RaymanCodexDesktopBootstrapWorkspaceEntries {
  param([object]$State)

  $sessionsRoot = Get-RaymanCodexDesktopSessionsRoot
  if ([string]::IsNullOrWhiteSpace($sessionsRoot) -or -not (Test-Path -LiteralPath $sessionsRoot -PathType Container)) {
    return @()
  }

  $cutoff = (Get-Date).AddHours(-1 * [int]$State.SessionLookbackHours)
  $activeCutoff = (Get-Date).AddSeconds(-1 * [int]$State.ActiveSessionSeconds)
  $entriesByKey = @{}
  foreach ($sessionFile in @(Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue)) {
    if ($null -eq $sessionFile) { continue }
    if ($sessionFile.LastWriteTime -lt $cutoff) { continue }
    $sessionWriteAt = [datetime]$sessionFile.LastWriteTime
    if ($sessionWriteAt -lt $activeCutoff) { continue }

    $meta = Get-RaymanNetworkResumeDesktopSessionMeta -SessionPath ([string]$sessionFile.FullName)
    if (-not [bool]$meta.valid) { continue }

    $workspaceRoot = [string]$meta.workspace_root
    if ([string]::IsNullOrWhiteSpace($workspaceRoot)) { continue }
    $raymanRoot = Join-Path $workspaceRoot '.Rayman'
    if (-not (Test-Path -LiteralPath $raymanRoot -PathType Container)) { continue }

    $normalizedKey = Get-RaymanPathComparisonValue -PathValue $workspaceRoot
    if ([string]::IsNullOrWhiteSpace($normalizedKey)) { continue }

    # Treat the rollout file write time as the current Desktop heartbeat.
    $activityAt = $sessionWriteAt
    $existing = if ($entriesByKey.ContainsKey($normalizedKey)) { $entriesByKey[$normalizedKey] } else { $null }
    if ($null -eq $existing -or $activityAt -gt [datetime]$existing.activity_at) {
      $entriesByKey[$normalizedKey] = [pscustomobject]@{
        workspace_key = $normalizedKey
        workspace_root = $workspaceRoot
        desktop_session_id = [string]$meta.session_id
        desktop_session_path = [string]$sessionFile.FullName
        activity_at = $activityAt.ToString('o')
      }
    }
  }

  return @($entriesByKey.Values)
}

function Test-RaymanCodexDesktopBootstrapHasActiveVsCodeSession {
  param([string]$WorkspaceRoot)

  $sessionDir = Join-Path $WorkspaceRoot '.Rayman\runtime\vscode_sessions'
  return (@(Get-RaymanOtherActiveVsCodeSessions -SessionDirectory $sessionDir -CurrentOwnerPid 0)).Count -gt 0
}

function Invoke-RaymanCodexDesktopBootstrapWatchCommand {
  param(
    [string]$WorkspaceRoot,
    [ValidateSet('start', 'stop')][string]$Action
  )

  $scriptPath = if ($Action -eq 'start') {
    Join-Path $WorkspaceRoot '.Rayman\scripts\watch\start_background_watchers.ps1'
  } else {
    Join-Path $WorkspaceRoot '.Rayman\scripts\watch\stop_background_watchers.ps1'
  }
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    return [pscustomobject]@{
      success = $false
      exit_code = 1
      output = ("missing script: {0}" -f $scriptPath)
      error = ("missing script: {0}" -f $scriptPath)
      command = ''
    }
  }

  $psHost = Resolve-RaymanPowerShellHost
  if ([string]::IsNullOrWhiteSpace($psHost)) {
    return [pscustomobject]@{
      success = $false
      exit_code = 1
      output = 'powershell host not found'
      error = 'powershell host not found'
      command = ''
    }
  }

  $args = if ($Action -eq 'start') {
    @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-WorkspaceRoot', $WorkspaceRoot, '-FromCodexDesktopAuto')
  } else {
    @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-WorkspaceRoot', $WorkspaceRoot, '-OnOwnerExit', '-SharedOnly')
  }
  return (Invoke-RaymanNativeCommandCapture -FilePath $psHost -ArgumentList $args -WorkingDirectory $WorkspaceRoot)
}

function Invoke-RaymanCodexDesktopBootstrapCycle {
  param([object]$State)

  if ($null -eq $State) {
    return [pscustomobject]@{
      success = $false
      status = 'state_missing'
      active_workspaces = @()
    }
  }

  $observedEntries = @(Get-RaymanCodexDesktopBootstrapWorkspaceEntries -State $State)
  $observedByKey = @{}
  foreach ($entry in $observedEntries) {
    $observedByKey[[string]$entry.workspace_key] = $entry
  }

  $results = New-Object System.Collections.Generic.List[object]
  $now = Get-Date
  $confirmedEntries = New-Object System.Collections.Generic.List[object]
  foreach ($entry in $observedEntries) {
    $key = [string]$entry.workspace_key
    $existing = Get-RaymanMapValue -Map $State.Workspaces -Key $key -Default $null
    $lastActivityAt = ConvertTo-RaymanNullableDateTime -Value ([string](Get-RaymanMapValue -Map $existing -Key 'last_session_activity_at' -Default ''))
    $lastObservedAt = ConvertTo-RaymanNullableDateTime -Value ([string](Get-RaymanMapValue -Map $existing -Key 'last_observed_activity_at' -Default ''))
    $lastStartAttemptAt = ConvertTo-RaymanNullableDateTime -Value ([string](Get-RaymanMapValue -Map $existing -Key 'last_start_attempt_at' -Default ''))
    $existingSessionId = [string](Get-RaymanMapValue -Map $existing -Key 'last_session_id' -Default '')
    $sessionChanged = (-not [string]::IsNullOrWhiteSpace($existingSessionId) -and $existingSessionId -ne [string]$entry.desktop_session_id)
    $activityAt = ConvertTo-RaymanNullableDateTime -Value ([string]$entry.activity_at)
    $activityAdvanced = ($null -ne $lastObservedAt -and $null -ne $activityAt -and [datetime]$activityAt -gt [datetime]$lastObservedAt)
    $isConfirmedActive = ($State.ActiveWorkspaces.Contains($key) -or $sessionChanged -or $activityAdvanced)

    $newEntry = [ordered]@{
      workspace_root = [string]$entry.workspace_root
      last_session_id = [string]$entry.desktop_session_id
      last_session_path = [string]$entry.desktop_session_path
      last_session_activity_at = $(if ($isConfirmedActive) { [string]$entry.activity_at } else { [string](Get-RaymanMapValue -Map $existing -Key 'last_session_activity_at' -Default '') })
      last_observed_activity_at = [string]$entry.activity_at
      last_start_attempt_at = [string](Get-RaymanMapValue -Map $existing -Key 'last_start_attempt_at' -Default '')
      last_stop_attempt_at = [string](Get-RaymanMapValue -Map $existing -Key 'last_stop_attempt_at' -Default '')
      watch_state = $(if ($isConfirmedActive) { [string](Get-RaymanMapValue -Map $existing -Key 'watch_state' -Default 'desktop_active_index') } else { 'desktop_observed' })
      last_error = [string](Get-RaymanMapValue -Map $existing -Key 'last_error' -Default '')
    }

    if ($isConfirmedActive) {
      $existingActive = Get-RaymanMapValue -Map $State.ActiveWorkspaces -Key $key -Default $null
      $State.ActiveWorkspaces[$key] = [ordered]@{
        workspace_root = [string]$entry.workspace_root
        last_session_id = [string]$entry.desktop_session_id
        last_session_path = [string]$entry.desktop_session_path
        activity_at = [string]$entry.activity_at
        activated_at = if ($null -ne $existingActive) { [string](Get-RaymanMapValue -Map $existingActive -Key 'activated_at' -Default $now.ToString('o')) } else { $now.ToString('o') }
        activation_source = if ($sessionChanged) { 'session_changed' } elseif ($activityAdvanced) { 'activity_advanced' } else { 'already_active' }
      }
      $confirmedEntries.Add($entry) | Out-Null
    } else {
      $null = $State.ActiveWorkspaces.Remove($key)
    }

    $shouldStart = ($isConfirmedActive -and ($sessionChanged -or $null -eq $lastStartAttemptAt -or (((Get-Date) - [datetime]$lastStartAttemptAt).TotalSeconds -ge 300)))
    if ($shouldStart) {
      $capture = Invoke-RaymanCodexDesktopBootstrapWatchCommand -WorkspaceRoot ([string]$entry.workspace_root) -Action 'start'
      $newEntry.last_start_attempt_at = $now.ToString('o')
      $newEntry.watch_state = if ([bool]$capture.success) { 'desktop_started' } else { 'desktop_start_failed' }
      $newEntry.last_error = if ([bool]$capture.success) { '' } else { [string]$capture.output }
      $results.Add([pscustomobject]@{
          workspace_root = [string]$entry.workspace_root
          action = 'start'
          success = [bool]$capture.success
          exit_code = [int]$capture.exit_code
          state = [string]$newEntry.watch_state
        }) | Out-Null
    } elseif ($isConfirmedActive -and $null -ne $lastActivityAt -and $lastActivityAt -ne $activityAt) {
      $newEntry.watch_state = 'desktop_active'
      $newEntry.last_error = ''
    }

    $State.Workspaces[$key] = $newEntry
  }

  foreach ($key in @((ConvertTo-RaymanStringKeyMap -InputObject $State.Workspaces).Keys)) {
    if ($observedByKey.ContainsKey([string]$key)) {
      continue
    }

    $null = $State.ActiveWorkspaces.Remove([string]$key)
    $existingRaw = Get-RaymanMapValue -Map $State.Workspaces -Key $key -Default $null
    if ($null -eq $existingRaw) { continue }
    $existing = [ordered]@{
      workspace_root = [string](Get-RaymanMapValue -Map $existingRaw -Key 'workspace_root' -Default '')
      last_session_id = [string](Get-RaymanMapValue -Map $existingRaw -Key 'last_session_id' -Default '')
      last_session_path = [string](Get-RaymanMapValue -Map $existingRaw -Key 'last_session_path' -Default '')
      last_session_activity_at = [string](Get-RaymanMapValue -Map $existingRaw -Key 'last_session_activity_at' -Default '')
      last_observed_activity_at = [string](Get-RaymanMapValue -Map $existingRaw -Key 'last_observed_activity_at' -Default '')
      last_start_attempt_at = [string](Get-RaymanMapValue -Map $existingRaw -Key 'last_start_attempt_at' -Default '')
      last_stop_attempt_at = [string](Get-RaymanMapValue -Map $existingRaw -Key 'last_stop_attempt_at' -Default '')
      watch_state = [string](Get-RaymanMapValue -Map $existingRaw -Key 'watch_state' -Default '')
      last_error = [string](Get-RaymanMapValue -Map $existingRaw -Key 'last_error' -Default '')
    }
    $workspaceRoot = [string]$existing.workspace_root
    $lastActivityAt = ConvertTo-RaymanNullableDateTime -Value ([string]$existing.last_session_activity_at)
    if ([string]::IsNullOrWhiteSpace($workspaceRoot) -or $null -eq $lastActivityAt) {
      continue
    }

    $elapsedSinceActivity = [int][Math]::Max(0, [Math]::Floor(((Get-Date) - [datetime]$lastActivityAt).TotalSeconds))
    if ($elapsedSinceActivity -lt [int]$State.StopGraceSeconds) {
      $existing.watch_state = 'desktop_waiting_grace'
      $State.Workspaces[[string]$key] = $existing
      continue
    }
    if (Test-RaymanCodexDesktopBootstrapHasActiveVsCodeSession -WorkspaceRoot $workspaceRoot) {
      $existing.watch_state = 'desktop_kept_for_vscode'
      $State.Workspaces[[string]$key] = $existing
      continue
    }

    $lastStopAttemptAt = ConvertTo-RaymanNullableDateTime -Value ([string](Get-RaymanMapValue -Map $existing -Key 'last_stop_attempt_at' -Default ''))
    if ($null -ne $lastStopAttemptAt -and (((Get-Date) - [datetime]$lastStopAttemptAt).TotalSeconds -lt [int]$State.StopGraceSeconds)) {
      $existing.watch_state = 'desktop_stopped'
      $State.Workspaces[[string]$key] = $existing
      continue
    }

    $capture = Invoke-RaymanCodexDesktopBootstrapWatchCommand -WorkspaceRoot $workspaceRoot -Action 'stop'
    $existing.last_stop_attempt_at = $now.ToString('o')
    $existing.watch_state = if ([bool]$capture.success) { 'desktop_stopped' } else { 'desktop_stop_failed' }
    $existing.last_error = if ([bool]$capture.success) { '' } else { [string]$capture.output }
    $State.Workspaces[[string]$key] = $existing
    $results.Add([pscustomobject]@{
        workspace_root = $workspaceRoot
        action = 'stop'
        success = [bool]$capture.success
        exit_code = [int]$capture.exit_code
        state = [string]$existing.watch_state
      }) | Out-Null
  }

  Save-RaymanCodexDesktopBootstrapState -State $State
  Save-RaymanCodexDesktopBootstrapActiveIndex -State $State
  Write-RaymanUtf8NoBom -Path ([string]$State.ReportPath) -Content (([ordered]@{
        schema = 'rayman.codex.desktop_bootstrap.report.v1'
        generated_at = (Get-Date).ToString('o')
        state_path = [string]$State.ResolvedStatePath
        active_index_path = [string]$State.ActiveIndexPath
        poll_ms = [int]$State.PollMs
        active_session_seconds = [int]$State.ActiveSessionSeconds
        session_lookback_hours = [int]$State.SessionLookbackHours
        stop_grace_seconds = [int]$State.StopGraceSeconds
        observed_workspaces = @($observedEntries)
        active_workspaces = @($confirmedEntries.ToArray())
        actions = @($results.ToArray())
      } | ConvertTo-Json -Depth 8).TrimEnd() + "`n")

  return [pscustomobject]@{
    success = $true
    status = 'ok'
    observed_workspaces = @($observedEntries)
    active_session_seconds = [int]$State.ActiveSessionSeconds
    active_workspaces = @($confirmedEntries.ToArray())
    actions = @($results.ToArray())
  }
}

if ($NoMain) {
  return
}

if ([string]::IsNullOrWhiteSpace($StatePath)) {
  $StatePath = Get-RaymanCodexDesktopBootstrapDefaultStatePath
}
$StatePath = [System.IO.Path]::GetFullPath($StatePath)

if (-not (Test-RaymanCodexDesktopWatchAutoStartEnabled)) {
  $runtimeRoot = Get-RaymanCodexDesktopBootstrapRuntimeRoot -ResolvedStatePath $StatePath
  if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
  }
  Write-RaymanCodexDesktopBootstrapReport -ReportPath (Get-RaymanCodexDesktopBootstrapReportPath -ResolvedStatePath $StatePath) -Payload ([ordered]@{
      schema = 'rayman.codex.desktop_bootstrap.report.v1'
      generated_at = (Get-Date).ToString('o')
      state_path = $StatePath
      status = 'disabled'
    })
  exit 0
}

$state = Read-RaymanCodexDesktopBootstrapState -ResolvedStatePath $StatePath
$runtimeRoot = [string]$state.RuntimeRoot
if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
}
$pidState = Initialize-RaymanCodexDesktopBootstrapPidFile -State $state -ScriptPath $PSCommandPath
if ([bool]$pidState.already_running) {
  Write-RaymanCodexDesktopBootstrapReport -ReportPath ([string]$state.ReportPath) -Payload ([ordered]@{
      schema = 'rayman.codex.desktop_bootstrap.report.v1'
      generated_at = (Get-Date).ToString('o')
      state_path = [string]$state.ResolvedStatePath
      active_index_path = [string]$state.ActiveIndexPath
      poll_ms = [int]$state.PollMs
      active_session_seconds = [int]$state.ActiveSessionSeconds
      session_lookback_hours = [int]$state.SessionLookbackHours
      stop_grace_seconds = [int]$state.StopGraceSeconds
      status = 'already_running'
      existing_pid = [int]$pidState.existing_pid
    })
  exit 0
}

$mutex = $null
$lockTaken = $false
try {
  $mutex = New-Object System.Threading.Mutex($false, 'Global\RaymanCodexDesktopBootstrap')
  $lockTaken = $mutex.WaitOne(0)
  if (-not $lockTaken) {
    exit 0
  }

  while ($true) {
    $null = Invoke-RaymanCodexDesktopBootstrapCycle -State $state
    Start-Sleep -Milliseconds ([int]$state.PollMs)
  }
} catch {
  Write-Warn ("[codex-desktop-bootstrap] failed: {0}" -f $_.Exception.Message)
  try {
    Write-RaymanCodexDesktopBootstrapReport -ReportPath ([string]$state.ReportPath) -Payload ([ordered]@{
        schema = 'rayman.codex.desktop_bootstrap.report.v1'
        generated_at = (Get-Date).ToString('o')
        state_path = [string]$state.ResolvedStatePath
        active_index_path = [string]$state.ActiveIndexPath
        poll_ms = [int]$state.PollMs
        active_session_seconds = [int]$state.ActiveSessionSeconds
        session_lookback_hours = [int]$state.SessionLookbackHours
        stop_grace_seconds = [int]$state.StopGraceSeconds
        status = 'failed'
        error = $_.Exception.ToString()
      })
  } catch {}
} finally {
  try { Remove-Item -LiteralPath ([string]$state.PidFilePath) -Force -ErrorAction SilentlyContinue } catch {}
  if ($lockTaken -and $null -ne $mutex) {
    try { $mutex.ReleaseMutex() } catch {}
  }
  if ($null -ne $mutex) {
    try { $mutex.Dispose() } catch {}
  }
}
