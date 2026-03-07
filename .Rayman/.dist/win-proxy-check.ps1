param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\.." | Select-Object -ExpandProperty Path)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$detectScript = Join-Path $WorkspaceRoot '.Rayman\scripts\proxy\detect_win_proxy.ps1'
$snapshotPath = Join-Path $WorkspaceRoot '.Rayman\runtime\proxy.resolved.json'

function Info([string]$Message) { Write-Host ("[win-proxy-check] {0}" -f $Message) -ForegroundColor Cyan }
function Warn([string]$Message) { Write-Host ("[win-proxy-check] {0}" -f $Message) -ForegroundColor Yellow }

if (-not (Test-Path -LiteralPath $detectScript -PathType Leaf)) {
  Warn ("detect script not found: {0}" -f $detectScript)
  exit 0
}

& $detectScript -WorkspaceRoot $WorkspaceRoot | Out-Host

if (Test-Path -LiteralPath $snapshotPath -PathType Leaf) {
  try {
    $snapshot = Get-Content -LiteralPath $snapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $source = if ($snapshot.PSObject.Properties['source']) { [string]$snapshot.source } else { 'unknown' }
    $proxy = if ($snapshot.PSObject.Properties['proxy']) { [string]$snapshot.proxy } else { '' }
    if ([string]::IsNullOrWhiteSpace($proxy)) {
      Info ("proxy source={0}; no proxy selected" -f $source)
    } else {
      Info ("proxy source={0}; proxy={1}" -f $source, $proxy)
    }
  } catch {
    Warn ("proxy snapshot parse failed: {0}" -f $_.Exception.Message)
  }
} else {
  Warn 'proxy snapshot not generated.'
}
