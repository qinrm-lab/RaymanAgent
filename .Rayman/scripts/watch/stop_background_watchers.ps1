param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$IncludeResidualCleanup,
  [string]$OwnerPid = ''
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

function Normalize-PathForMatch([string]$PathValue) {
  if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
  try {
    $full = [System.IO.Path]::GetFullPath($PathValue)
    return ($full -replace '/', '\').ToLowerInvariant()
  } catch {
    return ($PathValue -replace '/', '\').ToLowerInvariant()
  }
}

function Stop-ResidualRaymanStartupProcesses {
  $workspaceNeedle = Normalize-PathForMatch -PathValue $WorkspaceRoot
  if ([string]::IsNullOrWhiteSpace($workspaceNeedle)) { return }

  $scriptNeedles = @(
    '.rayman\scripts\watch\start_background_watchers.ps1'
    '.rayman\scripts\watch\vscode_folder_open_bootstrap.ps1'
    '.rayman\scripts\utils\ensure_win_deps.ps1'
    '.rayman\scripts\state\check_pending_task.ps1'
    '.rayman\scripts\watch\daily_health_check.ps1'
  )

  $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine)
  })
  if ($processes.Count -eq 0) { return }

  $processByPid = @{}
  foreach ($proc in $processes) {
    $processByPid[[int]$proc.ProcessId] = $proc
  }

  $matchedStartupPids = New-Object 'System.Collections.Generic.HashSet[int]'
  foreach ($proc in $processes) {
    $name = ([string]$proc.Name).ToLowerInvariant()
    if ($name -ne 'powershell.exe' -and $name -ne 'pwsh.exe') {
      continue
    }

    $cmd = ([string]$proc.CommandLine).ToLowerInvariant().Replace('/', '\')
    if (-not $cmd.Contains($workspaceNeedle)) {
      continue
    }
    if (-not ($scriptNeedles | Where-Object { $cmd.Contains($_) })) {
      continue
    }
    if ([int]$proc.ProcessId -eq [int]$PID) {
      continue
    }

    [void]$matchedStartupPids.Add([int]$proc.ProcessId)
  }

  foreach ($procId in @($matchedStartupPids)) {
    try {
      Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
      Write-Info ("[watch-stop] stopped residual startup process (PID={0})." -f $procId)
    } catch {
      Write-Warn ("[watch-stop] failed to stop residual startup process (PID={0}): {1}" -f $procId, $_.Exception.Message)
    }
  }

  foreach ($proc in $processes) {
    $name = ([string]$proc.Name).ToLowerInvariant()
    if ($name -ne 'wsl.exe') {
      continue
    }

    $currentPid = [int]$proc.ParentProcessId
    $hit = $false
    $hop = 0
    while ($currentPid -gt 0 -and $hop -lt 16) {
      if ($matchedStartupPids.Contains($currentPid)) {
        $hit = $true
        break
      }
      if (-not $processByPid.ContainsKey($currentPid)) {
        break
      }
      $currentPid = [int]$processByPid[$currentPid].ParentProcessId
      $hop++
    }

    if (-not $hit) {
      continue
    }

    try {
      Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction SilentlyContinue
      Write-Info ("[watch-stop] stopped residual WSL helper (PID={0})." -f [int]$proc.ProcessId)
    } catch {
      Write-Warn ("[watch-stop] failed to stop residual WSL helper (PID={0}): {1}" -f [int]$proc.ProcessId, $_.Exception.Message)
    }
  }
}

function Stop-ProcessByPidFile([string]$Name, [string]$PidFile) {
  if (-not (Test-Path -LiteralPath $PidFile -PathType Leaf)) {
    Write-Info ("[watch-stop] {0} is not running (no pid file)." -f $Name)
    return
  }

  $pidVal = Get-RaymanPidFromFile -PidFilePath $PidFile
  if ($pidVal -gt 0) {
    try {
      $proc = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
      if ($proc) {
        Stop-Process -Id $pidVal -Force -ErrorAction SilentlyContinue
        Write-Info ("[watch-stop] stopped {0} (PID={1})." -f $Name, $pidVal)
      }
    } catch {
      Write-Warn ("[watch-stop] stop {0} failed: {1}" -f $Name, $_.Exception.Message)
    }
  }

  try { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Info '[watch-stop] stopping Rayman background services...'

Stop-ProcessByPidFile -Name 'prompt-watch' -PidFile (Join-Path $runtimeDir 'win_watch.pid')
Stop-ProcessByPidFile -Name 'attention-watch' -PidFile (Join-Path $runtimeDir 'attention_watch.pid')
Stop-ProcessByPidFile -Name 'auto-save-watch' -PidFile (Join-Path $runtimeDir 'auto_save_watch.pid')
Stop-ProcessByPidFile -Name 'mcp-sqlite' -PidFile (Join-Path $runtimeDir 'mcp\sqlite.pid')

$ownedProcessOwner = Get-RaymanWorkspaceProcessOwnerContext -WorkspaceRootPath $WorkspaceRoot -ExplicitOwnerPid $OwnerPid
$ownedCleanupResults = @(Stop-RaymanWorkspaceOwnedProcessesForCurrentOwner -WorkspaceRootPath $WorkspaceRoot -OwnerContext $ownedProcessOwner -Kinds @('dotnet') -Reason 'watch-stop')
if ($ownedCleanupResults.Count -eq 0) {
  Write-Info ("[watch-stop] no registered workspace-owned dotnet processes for {0}." -f [string]$ownedProcessOwner.owner_display)
} else {
  foreach ($cleanup in $ownedCleanupResults) {
    $pidText = if ($cleanup.cleanup_pids -and $cleanup.cleanup_pids.Count -gt 0) { ($cleanup.cleanup_pids -join ',') } else { '(none)' }
    if ([string]$cleanup.cleanup_result -eq 'cleaned') {
      Write-Info ("[watch-stop] cleaned owned {0} process root={1} pids={2} owner={3} reason={4}" -f [string]$cleanup.kind, [int]$cleanup.root_pid, $pidText, [string]$cleanup.owner_display, [string]$cleanup.cleanup_reason)
    } else {
      $aliveText = if ($cleanup.alive_pids -and $cleanup.alive_pids.Count -gt 0) { ($cleanup.alive_pids -join ',') } else { '(none)' }
      Write-Warn ("[watch-stop] cleanup failed for owned {0} process root={1} owner={2} alive={3}" -f [string]$cleanup.kind, [int]$cleanup.root_pid, [string]$cleanup.owner_display, $aliveText)
    }
  }
}

if ($IncludeResidualCleanup) {
  Stop-ResidualRaymanStartupProcesses
  $sessionDir = Join-Path $runtimeDir 'vscode_sessions'
  if (Test-Path -LiteralPath $sessionDir -PathType Container) {
    try { Remove-Item -LiteralPath $sessionDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }
}

Write-Info '[watch-stop] all background services stopped.'
