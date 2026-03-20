param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [string]$PidFile = '',
  [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot "..\..\common.ps1"
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
  . $commonPath
} else {
  throw "common.ps1 not found: $commonPath"
}

$embeddedLibPath = Join-Path $PSScriptRoot '..\watch\embedded_watchers.lib.ps1'
if (-not (Test-Path -LiteralPath $embeddedLibPath -PathType Leaf)) {
  throw "embedded_watchers.lib.ps1 not found: $embeddedLibPath"
}
. $embeddedLibPath

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime'
if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
}

if ([string]::IsNullOrWhiteSpace($PidFile)) {
  $PidFile = Join-Path $runtimeDir 'attention_watch.pid'
}

$state = New-RaymanAttentionWatchState -WorkspaceRoot $WorkspaceRoot -ExitWhenIdle $true
$delayMs = Get-RaymanAttentionWatchDelayMs -State $state

try {
  Set-RaymanWatcherPidFile -PidFile $PidFile -ProcessId $PID
} catch {
  Write-Warn ("[alert-watch] write pid file failed: {0}" -f $_.Exception.Message)
  Write-RaymanDiag -Scope 'alert-watch' -Message ("write pid file failed: {0}" -f $_.Exception.ToString())
}

Write-Info (Get-RaymanAttentionWatchStartupMessage -State $state)

try {
  do {
    $result = Invoke-RaymanAttentionWatchCycle -State $state
    if ($Once -or [bool]$result.should_exit) {
      if ([bool]$result.should_exit) {
        Write-Info ("[alert-watch] no target process for {0}s, exiting." -f [int]$state.IdleExitSeconds)
      }
      break
    }

    Start-Sleep -Milliseconds $delayMs
  } while ($true)
} catch {
  Write-Warn ("[alert-watch] failed: {0}" -f $_.Exception.Message)
  Write-RaymanDiag -Scope 'alert-watch' -Message ("main loop failed: {0}" -f $_.Exception.ToString())
  try {
    Invoke-RaymanAttentionAlert -Kind 'error' -Reason 'alert-watch 运行异常，需要人工查看。' -MaxSeconds 30 -WorkspaceRoot $WorkspaceRoot | Out-Null
  } catch {
    Write-RaymanDiag -Scope 'alert-watch' -Message ("error alert invoke failed: {0}" -f $_.Exception.ToString())
  }
} finally {
  try {
    Clear-RaymanWatcherPidFile -PidFile $PidFile -ExpectedPid $PID
  } catch {
    Write-RaymanDiag -Scope 'alert-watch' -Message ("cleanup pid file failed: {0}" -f $_.Exception.ToString())
  }
  Write-Info "[alert-watch] stopped"
}
