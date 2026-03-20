param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$Refresh,
  [Alias('Json')][switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$detectScript = Join-Path $WorkspaceRoot '.Rayman\scripts\proxy\detect_win_proxy.ps1'
$summaryScript = Join-Path $WorkspaceRoot '.Rayman\win-proxy-check.ps1'
$snapshotPath = Join-Path $WorkspaceRoot '.Rayman\runtime\proxy.resolved.json'

function Invoke-ProxyRefresh {
  param([switch]$Quiet)

  if (-not (Test-Path -LiteralPath $detectScript -PathType Leaf)) {
    throw ("detect script not found: {0}" -f $detectScript)
  }

  if ($Quiet) {
    & $detectScript -WorkspaceRoot $WorkspaceRoot 6>$null | Out-Null
    return
  }

  & $detectScript -WorkspaceRoot $WorkspaceRoot | Out-Host
}

if ($Refresh -or -not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) {
  Invoke-ProxyRefresh -Quiet:$AsJson
}

if ($AsJson) {
  $report = [ordered]@{
    schema = 'rayman.proxy_health.v1'
    workspace_root = $WorkspaceRoot
    refreshed = [bool]$Refresh
    snapshot_path = $snapshotPath
    snapshot_exists = (Test-Path -LiteralPath $snapshotPath -PathType Leaf)
    resolved_proxy = $null
  }

  if ($report.snapshot_exists) {
    try {
      $report.resolved_proxy = Get-Content -LiteralPath $snapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
      $report['snapshot_parse_error'] = $_.Exception.Message
    }
  }

  $report | ConvertTo-Json -Depth 8
  exit 0
}

if (-not (Test-Path -LiteralPath $summaryScript -PathType Leaf)) {
  throw ("summary script not found: {0}" -f $summaryScript)
}

& $summaryScript -WorkspaceRoot $WorkspaceRoot
