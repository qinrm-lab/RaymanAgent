param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$IncludeResidualCleanup,
  [string]$OwnerPid = '',
  [switch]$OnOwnerExit,
  [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
  throw "common.ps1 not found: $commonPath"
}
. $commonPath

$ownedProcessPath = Join-Path $PSScriptRoot '..\utils\workspace_process_ownership.ps1'
if (-not (Test-Path -LiteralPath $ownedProcessPath -PathType Leaf)) {
  throw "workspace_process_ownership.ps1 not found: $ownedProcessPath"
}
. $ownedProcessPath -NoMain

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime'
$sessionDir = Join-Path $runtimeDir 'vscode_sessions'
$script:RaymanStopWorkspaceRoot = $WorkspaceRoot
$script:RaymanStopRuntimeDir = $runtimeDir
$script:RaymanStopSessionDir = $sessionDir

function Normalize-PathForMatch([string]$PathValue) {
  if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
  try {
    $full = [System.IO.Path]::GetFullPath($PathValue)
    return ($full -replace '/', '\').ToLowerInvariant()
  } catch {
    return ($PathValue -replace '/', '\').ToLowerInvariant()
  }
}

function Resolve-RaymanVsCodeSessionPid([string]$Value) {
  $parsed = 0
  if (-not [string]::IsNullOrWhiteSpace($Value) -and [int]::TryParse($Value.Trim(), [ref]$parsed) -and $parsed -gt 0) {
    return $parsed
  }
  return 0
}

function Read-RaymanVsCodeSessionState([string]$SessionPath) {
  if ([string]::IsNullOrWhiteSpace($SessionPath) -or -not (Test-Path -LiteralPath $SessionPath -PathType Leaf)) {
    return $null
  }

  try {
    $raw = Get-Content -LiteralPath $SessionPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Test-RaymanVsCodeSessionProcessAlive([int]$ProcessId, [string]$ExpectedStartUtc = '') {
  if ($ProcessId -le 0) { return $false }

  try {
    $proc = Get-Process -Id $ProcessId -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace($ExpectedStartUtc)) {
      $actual = $proc.StartTime.ToUniversalTime().ToString('o')
      if ($actual -ne $ExpectedStartUtc) {
        return $false
      }
    }
    return $true
  } catch {
    return $false
  }
}

function Get-RaymanVsCodeSessionEntries {
  if (-not (Test-Path -LiteralPath $script:RaymanStopSessionDir -PathType Container)) {
    return @()
  }

  $entries = New-Object System.Collections.Generic.List[object]
  foreach ($sessionFile in @(Get-ChildItem -LiteralPath $script:RaymanStopSessionDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    $session = Read-RaymanVsCodeSessionState -SessionPath $sessionFile.FullName
    if ($null -eq $session) {
      continue
    }

    $parentPid = Resolve-RaymanVsCodeSessionPid -Value ([string]$session.parentPid)
    $parentStartUtc = [string]$session.parentStartUtc
    $state = ([string]$session.state).Trim().ToLowerInvariant()
    $alive = Test-RaymanVsCodeSessionProcessAlive -ProcessId $parentPid -ExpectedStartUtc $parentStartUtc
    $active = ($alive -and $state -ne 'parent-exited' -and $state -ne 'stop-failed')

    $entries.Add([pscustomobject]@{
      path = [string]$sessionFile.FullName
      parent_pid = $parentPid
      parent_start_utc = $parentStartUtc
      state = $state
      alive = $alive
      active = $active
    }) | Out-Null
  }

  return @($entries.ToArray())
}

function Get-OtherActiveVsCodeSessions([int]$CurrentOwnerPid) {
  return @(
    Get-RaymanVsCodeSessionEntries | Where-Object {
      [bool]$_.active -and ([int]$_.parent_pid -ne $CurrentOwnerPid)
    }
  )
}

function Get-RaymanOwnedRecordsForOwner {
  param(
    [object]$OwnerContext,
    [string[]]$Kinds = @()
  )

  if ($null -eq $OwnerContext) { return @() }

  $kindSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($kind in @($Kinds)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$kind)) {
      [void]$kindSet.Add(([string]$kind).Trim())
    }
  }

  return @(
    Get-RaymanWorkspaceOwnedProcessRecords -WorkspaceRootPath $script:RaymanStopWorkspaceRoot | Where-Object {
      $ownerKey = if ($_.PSObject.Properties['owner_key']) { [string]$_.owner_key } else { '' }
      $kindValue = if ($_.PSObject.Properties['kind']) { [string]$_.kind } else { '' }
      if ($ownerKey -ne [string]$OwnerContext.owner_key) { return $false }
      if ($kindSet.Count -eq 0) { return $true }
      return $kindSet.Contains($kindValue)
    }
  )
}

function Write-OwnedCleanupResults([object[]]$CleanupResults) {
  foreach ($cleanup in @($CleanupResults)) {
    $pidText = if ($cleanup.cleanup_pids -and $cleanup.cleanup_pids.Count -gt 0) { ($cleanup.cleanup_pids -join ',') } else { '(none)' }
    if ([string]$cleanup.cleanup_result -eq 'cleaned') {
      Write-Info ("[watch-stop] cleaned owned {0} process root={1} pids={2} owner={3} reason={4}" -f [string]$cleanup.kind, [int]$cleanup.root_pid, $pidText, [string]$cleanup.owner_display, [string]$cleanup.cleanup_reason)
    } else {
      $aliveText = if ($cleanup.alive_pids -and $cleanup.alive_pids.Count -gt 0) { ($cleanup.alive_pids -join ',') } else { '(none)' }
      Write-Warn ("[watch-stop] cleanup failed for owned {0} process root={1} owner={2} alive={3}" -f [string]$cleanup.kind, [int]$cleanup.root_pid, [string]$cleanup.owner_display, $aliveText)
    }
  }
}

function Invoke-OwnedProcessCleanup {
  param(
    [object[]]$Records,
    [string]$Reason,
    [switch]$SkipCurrentProcessRoot
  )

  $results = New-Object System.Collections.Generic.List[object]
  foreach ($record in @($Records)) {
    if ($null -eq $record) { continue }

    $rootPid = 0
    try { $rootPid = [int]$record.root_pid } catch { $rootPid = 0 }
    if ($SkipCurrentProcessRoot -and $rootPid -eq [int]$PID) {
      Remove-RaymanWorkspaceOwnedProcess -WorkspaceRootPath $script:RaymanStopWorkspaceRoot -RootPid $rootPid
      Write-Info ("[watch-stop] detached current process record (PID={0}, owner={1})." -f $rootPid, [string]$record.owner_display)
      continue
    }

    $result = Stop-RaymanWorkspaceOwnedProcess -WorkspaceRootPath $script:RaymanStopWorkspaceRoot -Record $record -Reason $Reason
    if ($null -ne $result) {
      $results.Add($result) | Out-Null
    }
  }

  return @($results.ToArray())
}

function Stop-ProcessByPidFile {
  param(
    [string]$Name,
    [string]$PidFile,
    [string]$Reason
  )

  if (-not (Test-Path -LiteralPath $PidFile -PathType Leaf)) {
    Write-Info ("[watch-stop] {0} is not running (no pid file)." -f $Name)
    return
  }

  $pidVal = Get-RaymanPidFromFile -PidFilePath $PidFile
  if ($pidVal -le 0) {
    try { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue } catch {}
    Write-Info ("[watch-stop] {0} pid file was stale and has been removed." -f $Name)
    return
  }

  $record = [pscustomobject]@{
    owner_key = 'pid-file'
    owner_display = 'pid-file'
    kind = $Name
    launcher = 'pid-file'
    root_pid = $pidVal
    started_at = ''
    command = $Name
  }

  $result = Stop-RaymanWorkspaceOwnedProcess -WorkspaceRootPath $script:RaymanStopWorkspaceRoot -Record $record -Reason $Reason
  if ($null -ne $result) {
    Write-OwnedCleanupResults -CleanupResults @($result)
  }

  try { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue } catch {}
}

function Stop-ResidualRaymanStartupProcesses {
  param(
    [bool]$StopSharedServices,
    [int]$CurrentOwnerPid = 0
  )

  $workspaceNeedle = Normalize-PathForMatch -PathValue $script:RaymanStopWorkspaceRoot
  if ([string]::IsNullOrWhiteSpace($workspaceNeedle)) { return }

  $scriptNeedles = if ($StopSharedServices) {
    @(
      '.rayman\win-exitwatch.ps1'
      '.rayman\win-watch.ps1'
      '.rayman\scripts\alerts\attention_watch.ps1'
      '.rayman\scripts\state\auto_save_watch.ps1'
      '.rayman\scripts\mcp\manage_mcp.ps1'
      '.rayman\scripts\watch\start_background_watchers.ps1'
      '.rayman\scripts\watch\vscode_folder_open_bootstrap.ps1'
      '.rayman\scripts\utils\ensure_win_deps.ps1'
      '.rayman\scripts\state\check_pending_task.ps1'
      '.rayman\scripts\watch\daily_health_check.ps1'
    )
  } else {
    @('.rayman\win-exitwatch.ps1')
  }

  $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine)
  })
  if ($processes.Count -eq 0) { return }

  $processByPid = @{}
  $childrenByParent = @{}
  foreach ($proc in $processes) {
    $procPid = [int]$proc.ProcessId
    $parentPid = [int]$proc.ParentProcessId
    $processByPid[$procPid] = $proc
    if (-not $childrenByParent.ContainsKey($parentPid)) {
      $childrenByParent[$parentPid] = New-Object System.Collections.Generic.List[int]
    }
    $childrenByParent[$parentPid].Add($procPid) | Out-Null
  }

  $matchedStartupPids = New-Object 'System.Collections.Generic.HashSet[int]'
  foreach ($proc in $processes) {
    $name = ([string]$proc.Name).ToLowerInvariant()
    if ($name -ne 'powershell.exe' -and $name -ne 'pwsh.exe') {
      continue
    }

    $procPid = [int]$proc.ProcessId
    if ($procPid -eq [int]$PID) {
      continue
    }

    $cmd = ([string]$proc.CommandLine).ToLowerInvariant().Replace('/', '\')
    if (-not $cmd.Contains($workspaceNeedle)) {
      continue
    }
    if (-not ($scriptNeedles | Where-Object { $cmd.Contains($_) })) {
      continue
    }
    if (-not $StopSharedServices -and $CurrentOwnerPid -gt 0) {
      $ownerToken = ("-parentpid {0}" -f $CurrentOwnerPid)
      if (-not $cmd.Contains($ownerToken)) {
        continue
      }
    }

    [void]$matchedStartupPids.Add($procPid)
  }

  $allMatchedPids = New-Object 'System.Collections.Generic.HashSet[int]'
  foreach ($rootPid in @($matchedStartupPids)) {
    $queue = New-Object 'System.Collections.Generic.Queue[int]'
    $queue.Enqueue([int]$rootPid)
    while ($queue.Count -gt 0) {
      $currentPid = [int]$queue.Dequeue()
      if ($currentPid -eq [int]$PID -or $allMatchedPids.Contains($currentPid)) {
        continue
      }
      [void]$allMatchedPids.Add($currentPid)
      if ($childrenByParent.ContainsKey($currentPid)) {
        foreach ($childPid in $childrenByParent[$currentPid]) {
          if (-not $allMatchedPids.Contains([int]$childPid)) {
            $queue.Enqueue([int]$childPid)
          }
        }
      }
    }
  }

  foreach ($procId in @($allMatchedPids | Sort-Object -Descending)) {
    try {
      Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
      Write-Info ("[watch-stop] stopped residual startup process (PID={0})." -f $procId)
    } catch {
      Write-Warn ("[watch-stop] failed to stop residual startup process (PID={0}): {1}" -f $procId, $_.Exception.Message)
    }
  }
}

function Invoke-RaymanStopBackgroundWatchers {
  param(
    [string]$WorkspaceRootPath,
    [switch]$DoResidualCleanup,
    [string]$ExplicitOwnerPid = '',
    [switch]$OwnerExit
  )

  Write-Info '[watch-stop] stopping Rayman background services...'

  $currentOwnerPid = Resolve-RaymanVsCodeSessionPid -Value $ExplicitOwnerPid
  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRootPath).Path
  $script:RaymanStopWorkspaceRoot = $resolvedRoot
  $script:RaymanStopRuntimeDir = Join-Path $resolvedRoot '.Rayman\runtime'
  $script:RaymanStopSessionDir = Join-Path $script:RaymanStopRuntimeDir 'vscode_sessions'

  $ownerContext = Get-RaymanWorkspaceProcessOwnerContext -WorkspaceRootPath $resolvedRoot -ExplicitOwnerPid $ExplicitOwnerPid
  $sharedOwnerContext = Get-RaymanWorkspaceSharedProcessOwnerContext -WorkspaceRootPath $resolvedRoot

  $sharedServicesStillNeeded = $false
  if ($OwnerExit) {
    $otherActiveSessions = @(Get-OtherActiveVsCodeSessions -CurrentOwnerPid $currentOwnerPid)
    $sharedServicesStillNeeded = ($otherActiveSessions.Count -gt 0)
    if ($sharedServicesStillNeeded) {
      $otherOwnerText = @($otherActiveSessions | ForEach-Object { [int]$_.parent_pid } | Sort-Object -Unique) -join ','
      Write-Info ("[watch-stop] keep shared background services alive; other active session(s)={0}." -f $otherOwnerText)
    }
  }

  $ownerCleanupRecords = @(Get-RaymanOwnedRecordsForOwner -OwnerContext $ownerContext -Kinds @('watcher', 'dotnet'))
  $ownerCleanupResults = @(Invoke-OwnedProcessCleanup -Records $ownerCleanupRecords -Reason $(if ($OwnerExit) { 'watch-stop-owner-exit' } else { 'watch-stop' }) -SkipCurrentProcessRoot:$OwnerExit)
  if ($ownerCleanupResults.Count -eq 0) {
    Write-Info ("[watch-stop] no owner-scoped watcher/dotnet processes for {0}." -f [string]$ownerContext.owner_display)
  } else {
    Write-OwnedCleanupResults -CleanupResults $ownerCleanupResults
  }

  if (-not $OwnerExit -or -not $sharedServicesStillNeeded) {
    $sharedCleanupRecords = @(Get-RaymanOwnedRecordsForOwner -OwnerContext $sharedOwnerContext -Kinds @('watcher', 'mcp'))
    $sharedCleanupResults = @(Invoke-OwnedProcessCleanup -Records $sharedCleanupRecords -Reason $(if ($OwnerExit) { 'watch-stop-owner-exit-shared' } else { 'watch-stop-shared' }))
    if ($sharedCleanupResults.Count -gt 0) {
      Write-OwnedCleanupResults -CleanupResults $sharedCleanupResults
    }

    Stop-ProcessByPidFile -Name 'prompt-watch' -PidFile (Join-Path $script:RaymanStopRuntimeDir 'win_watch.pid') -Reason $(if ($OwnerExit) { 'watch-stop-owner-exit-shared' } else { 'watch-stop-shared' })
    Stop-ProcessByPidFile -Name 'attention-watch' -PidFile (Join-Path $script:RaymanStopRuntimeDir 'attention_watch.pid') -Reason $(if ($OwnerExit) { 'watch-stop-owner-exit-shared' } else { 'watch-stop-shared' })
    Stop-ProcessByPidFile -Name 'auto-save-watch' -PidFile (Join-Path $script:RaymanStopRuntimeDir 'auto_save_watch.pid') -Reason $(if ($OwnerExit) { 'watch-stop-owner-exit-shared' } else { 'watch-stop-shared' })
    Stop-ProcessByPidFile -Name 'mcp-sqlite' -PidFile (Join-Path $script:RaymanStopRuntimeDir 'mcp\sqlite.pid') -Reason $(if ($OwnerExit) { 'watch-stop-owner-exit-shared' } else { 'watch-stop-shared' })
  } else {
    Write-Info '[watch-stop] shared watcher/mcp services remain running for other VS Code sessions.'
  }

  if ($DoResidualCleanup -or $OwnerExit) {
    Stop-ResidualRaymanStartupProcesses -StopSharedServices:(-not $OwnerExit -or -not $sharedServicesStillNeeded) -CurrentOwnerPid $currentOwnerPid
  }

  if ($DoResidualCleanup -and -not $OwnerExit) {
    if (Test-Path -LiteralPath $script:RaymanStopSessionDir -PathType Container) {
      try { Remove-Item -LiteralPath $script:RaymanStopSessionDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
  }

  Write-Info '[watch-stop] all background services stopped.'
}

if (-not $NoMain) {
  Invoke-RaymanStopBackgroundWatchers `
    -WorkspaceRootPath $WorkspaceRoot `
    -DoResidualCleanup:$IncludeResidualCleanup `
    -ExplicitOwnerPid $OwnerPid `
    -OwnerExit:$OnOwnerExit
}
