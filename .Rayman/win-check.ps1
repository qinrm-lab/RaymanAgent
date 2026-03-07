param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\.." | Select-Object -ExpandProperty Path)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path

function Info([string]$Message) { Write-Host ("[win-check] {0}" -f $Message) -ForegroundColor Cyan }
function Warn([string]$Message) { Write-Host ("[win-check] {0}" -f $Message) -ForegroundColor Yellow }

& (Join-Path $WorkspaceRoot '.Rayman\win-preflight.ps1') -WorkspaceRoot $WorkspaceRoot

$releaseGate = Join-Path $WorkspaceRoot '.Rayman\scripts\release\release_gate.ps1'
if (Test-Path -LiteralPath $releaseGate -PathType Leaf) {
  Info 'run standard release gate'
  & $releaseGate -WorkspaceRoot $WorkspaceRoot -Mode standard -AllowNoGit
} else {
  Warn ("release gate script not found: {0}" -f $releaseGate)
}

$bash = Get-Command bash -ErrorAction SilentlyContinue
if ($null -ne $bash) {
  Info 'run full release requirements validation'
  Push-Location $WorkspaceRoot
  try {
    & bash './.Rayman/scripts/release/validate_release_requirements.sh'
  } finally {
    Pop-Location
  }
} else {
  Warn 'bash not found; skip validate_release_requirements.sh'
}

Info 'check complete'
