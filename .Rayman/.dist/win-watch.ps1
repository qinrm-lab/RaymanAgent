param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\.." | Select-Object -ExpandProperty Path),
  [string]$PidFile = '',
  [int]$IntervalSeconds = 15,
  [switch]$EnableEmbeddedAttentionWatch,
  [switch]$EnableEmbeddedAutoSave,
  [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot 'common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
  throw "common.ps1 not found: $commonPath"
}
. $commonPath

$embeddedLibPath = Join-Path $PSScriptRoot 'scripts\watch\embedded_watchers.lib.ps1'
if (-not (Test-Path -LiteralPath $embeddedLibPath -PathType Leaf)) {
  throw "embedded_watchers.lib.ps1 not found: $embeddedLibPath"
}
. $embeddedLibPath

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
if ([string]::IsNullOrWhiteSpace($PidFile)) {
  $PidFile = Join-Path $WorkspaceRoot '.Rayman\runtime\win_watch.pid'
}

$pidDir = Split-Path -Parent $PidFile
if (-not (Test-Path -LiteralPath $pidDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $pidDir | Out-Null
}
Set-RaymanWatcherPidFile -PidFile $PidFile -ProcessId $PID

function Invoke-PromptWatchCycle {
  $processPrompts = Join-Path $WorkspaceRoot '.Rayman\scripts\requirements\process_prompts.ps1'
  if (Test-Path -LiteralPath $processPrompts -PathType Leaf) {
    & $processPrompts | Out-Host
  }
}

function Get-WatchSchedulerSleepMs {
  param([datetime[]]$NextTimes)

  $validTimes = @($NextTimes | Where-Object { $null -ne $_ })
  if ($validTimes.Count -eq 0) {
    return 1000
  }

  $now = Get-Date
  $nextDue = $validTimes | Sort-Object | Select-Object -First 1
  $remainingMs = [int][Math]::Round(($nextDue - $now).TotalMilliseconds)
  if ($remainingMs -lt 200) { return 200 }
  if ($remainingMs -gt 5000) { return 5000 }
  return $remainingMs
}

$embeddedAttentionEnabled = [bool]$EnableEmbeddedAttentionWatch.IsPresent
if (-not $embeddedAttentionEnabled) {
  $embeddedAttentionEnabled = Get-RaymanEnvBool -Name 'RAYMAN_AUTO_START_ATTENTION_WATCH_ENABLED' -Default $false
}

$embeddedAutoSaveEnabled = [bool]$EnableEmbeddedAutoSave.IsPresent
if (-not $embeddedAutoSaveEnabled) {
  $embeddedAutoSaveEnabled = Get-RaymanEnvBool -Name 'RAYMAN_AUTO_SAVE_WATCH_ENABLED' -Default $false
}

$attentionState = $null
if ($embeddedAttentionEnabled) {
  $attentionState = New-RaymanAttentionWatchState -WorkspaceRoot $WorkspaceRoot -ExitWhenIdle $false
}

$autoSaveState = $null
if ($embeddedAutoSaveEnabled) {
  $autoSaveState = New-RaymanAutoSaveWatchState -WorkspaceRoot $WorkspaceRoot
}

$attentionDelayMs = if ($null -ne $attentionState) { Get-RaymanAttentionWatchDelayMs -State $attentionState } else { 0 }
$autoSaveIntervalSeconds = Get-RaymanEnvInt -Name 'RAYMAN_AUTO_SAVE_INTERVAL_SECONDS' -Default 300 -Min 30 -Max 86400

$enabledFeatures = New-Object System.Collections.Generic.List[string]
$enabledFeatures.Add('prompt-sync') | Out-Null
if ($null -ne $attentionState) { $enabledFeatures.Add('attention-scan') | Out-Null }
if ($null -ne $autoSaveState) { $enabledFeatures.Add('auto-save') | Out-Null }

if ($null -ne $attentionState) {
  Write-Info (Get-RaymanAttentionWatchStartupMessage -State $attentionState)
}
if ($null -ne $autoSaveState) {
  Write-Info ("[auto-save] embedded scheduler enabled (interval={0}s)" -f $autoSaveIntervalSeconds)
}
Write-Info ("[win-watch] started (interval={0}s, once={1}, features={2})" -f $IntervalSeconds, $Once.IsPresent, (($enabledFeatures | Select-Object -Unique) -join ','))

$nextPromptAt = Get-Date
$nextAttentionAt = if ($null -ne $attentionState) { Get-Date } else { $null }
$nextAutoSaveAt = if ($null -ne $autoSaveState) { Get-Date } else { $null }

try {
  do {
    $now = Get-Date

    if ($now -ge $nextPromptAt) {
      Invoke-PromptWatchCycle
      $nextPromptAt = (Get-Date).AddSeconds([Math]::Max(1, $IntervalSeconds))
    }

    if ($null -ne $attentionState -and $now -ge $nextAttentionAt) {
      $attentionResult = Invoke-RaymanAttentionWatchCycle -State $attentionState
      if ([bool]$attentionResult.should_exit) {
        Write-Info ("[win-watch] embedded attention scan requested stop ({0}); continue prompt sync only." -f [string]$attentionResult.reason)
        $attentionState = $null
        $nextAttentionAt = $null
      } else {
        $nextAttentionAt = (Get-Date).AddMilliseconds([Math]::Max(300, $attentionDelayMs))
      }
    }

    if ($null -ne $autoSaveState -and $now -ge $nextAutoSaveAt) {
      Invoke-RaymanAutoSaveCycle -State $autoSaveState | Out-Null
      $nextAutoSaveAt = (Get-Date).AddSeconds([Math]::Max(30, $autoSaveIntervalSeconds))
    }

    if ($Once) { break }

    Start-Sleep -Milliseconds (Get-WatchSchedulerSleepMs -NextTimes @($nextPromptAt, $nextAttentionAt, $nextAutoSaveAt))
  } while ($true)
} finally {
  try {
    Clear-RaymanWatcherPidFile -PidFile $PidFile -ExpectedPid $PID
  } catch {}
}
