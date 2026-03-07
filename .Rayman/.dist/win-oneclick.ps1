param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\.." | Select-Object -ExpandProperty Path),
  [switch]$SkipInit,
  [switch]$SkipWatchers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path

function Info([string]$Message) { Write-Host ("[win-oneclick] {0}" -f $Message) -ForegroundColor Cyan }

if (-not $SkipInit) {
  Info 'run init.cmd'
  & (Join-Path $WorkspaceRoot '.Rayman\init.cmd')
}

if (-not $SkipWatchers) {
  $watchScript = Join-Path $WorkspaceRoot '.Rayman\scripts\watch\start_background_watchers.ps1'
  if (Test-Path -LiteralPath $watchScript -PathType Leaf) {
    Info 'start background watchers'
    & $watchScript -WorkspaceRoot $WorkspaceRoot
  }
}

Info 'one-click flow complete'
