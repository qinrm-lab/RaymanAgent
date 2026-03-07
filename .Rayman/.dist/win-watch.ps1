param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\.." | Select-Object -ExpandProperty Path),
  [string]$PidFile = '',
  [int]$IntervalSeconds = 15,
  [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot 'common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
  throw "common.ps1 not found: $commonPath"
}
. $commonPath

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
if ([string]::IsNullOrWhiteSpace($PidFile)) {
  $PidFile = Join-Path $WorkspaceRoot '.Rayman\runtime\win_watch.pid'
}

$pidDir = Split-Path -Parent $PidFile
if (-not (Test-Path -LiteralPath $pidDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $pidDir | Out-Null
}
Set-Content -LiteralPath $PidFile -Value $PID -NoNewline -Encoding ASCII

function Invoke-WatchCycle {
  $processPrompts = Join-Path $WorkspaceRoot '.Rayman\scripts\requirements\process_prompts.ps1'
  if (Test-Path -LiteralPath $processPrompts -PathType Leaf) {
    & $processPrompts | Out-Host
  }

  $ensureAttention = Join-Path $WorkspaceRoot '.Rayman\scripts\alerts\ensure_attention_watch.ps1'
  if (Test-Path -LiteralPath $ensureAttention -PathType Leaf) {
    & $ensureAttention -WorkspaceRoot $WorkspaceRoot -Quiet | Out-Null
  }
}

try {
  Write-Info ("[win-watch] started (interval={0}s, once={1})" -f $IntervalSeconds, $Once.IsPresent)
  do {
    Invoke-WatchCycle
    if ($Once) { break }
    Start-Sleep -Seconds ([Math]::Max(1, $IntervalSeconds))
  } while ($true)
} finally {
  try {
    if ((Get-RaymanPidFromFile -PidFilePath $PidFile) -eq $PID) {
      Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    }
  } catch {}
}
