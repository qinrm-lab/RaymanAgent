param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [string]$ProjectName = '',
  [switch]$SkipReleaseGate,
  [switch]$SkipPackage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info([string]$Message) { Write-Host ("ℹ️  [deploy] {0}" -f $Message) -ForegroundColor Cyan }
function Ok([string]$Message) { Write-Host ("✅ [deploy] {0}" -f $Message) -ForegroundColor Green }
function Fail([string]$Message) { Write-Host ("❌ [deploy] {0}" -f $Message) -ForegroundColor Red; exit 2 }

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$releaseGateScript = Join-Path $WorkspaceRoot '.Rayman\scripts\release\release_gate.ps1'
$packageScript = Join-Path $WorkspaceRoot '.Rayman\scripts\release\package_distributable.ps1'
$runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime'
$reportPath = Join-Path $runtimeDir 'deploy.last.json'

if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
}

if (-not [string]::IsNullOrWhiteSpace($ProjectName)) {
  Info ("project filter requested: {0}" -f $ProjectName)
}

if (-not $SkipReleaseGate) {
  if (-not (Test-Path -LiteralPath $releaseGateScript -PathType Leaf)) {
    Fail ("release gate script not found: {0}" -f $releaseGateScript)
  }
  Info 'running release gate (project mode)...'
  & $releaseGateScript -WorkspaceRoot $WorkspaceRoot -Mode project
  if ($LASTEXITCODE -ne 0) {
    Fail ("release gate failed with exit code {0}" -f $LASTEXITCODE)
  }
}

$packagePath = ''
if (-not $SkipPackage) {
  if (-not (Test-Path -LiteralPath $packageScript -PathType Leaf)) {
    Fail ("package script not found: {0}" -f $packageScript)
  }
  Info 'building distributable package...'
  & $packageScript -WorkspaceRoot $WorkspaceRoot
  if ($LASTEXITCODE -ne 0) {
    Fail ("package step failed with exit code {0}" -f $LASTEXITCODE)
  }

  $releaseDir = Join-Path $WorkspaceRoot '.Rayman\release'
  $latestPackage = Get-ChildItem -LiteralPath $releaseDir -Filter '*.zip' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($null -ne $latestPackage) {
    $packagePath = $latestPackage.FullName
    Ok ("package ready: {0}" -f $packagePath)
  }
}

$result = [pscustomobject]@{
  generatedAt = (Get-Date).ToString('o')
  workspaceRoot = $WorkspaceRoot
  projectName = $ProjectName
  skipReleaseGate = [bool]$SkipReleaseGate
  skipPackage = [bool]$SkipPackage
  packagePath = $packagePath
}
$result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $reportPath -Encoding UTF8
Ok ("deploy summary: {0}" -f $reportPath)
exit 0
