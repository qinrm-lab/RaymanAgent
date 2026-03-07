param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$IncludeResidualCleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
  throw "common.ps1 not found: $commonPath"
}
. $commonPath

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime'

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

if ($IncludeResidualCleanup) {
  $sessionDir = Join-Path $runtimeDir 'vscode_sessions'
  if (Test-Path -LiteralPath $sessionDir -PathType Container) {
    try { Remove-Item -LiteralPath $sessionDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }
}

Write-Info '[watch-stop] all background services stopped.'
