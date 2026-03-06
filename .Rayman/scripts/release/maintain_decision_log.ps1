param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [string]$LogPath = "",
  [string]$SummaryPath = "",
  [int]$MaxLines = -1,
  [int]$KeepFiles = -1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info([string]$m){ Write-Host ("ℹ️  [decision-maintain] {0}" -f $m) -ForegroundColor Cyan }
function Fail([string]$m){ Write-Host ("❌ [decision-maintain] {0}" -f $m) -ForegroundColor Red; exit 2 }

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
if ([string]::IsNullOrWhiteSpace($LogPath)) {
  $LogPath = Join-Path $WorkspaceRoot '.Rayman\runtime\decision.log'
}
if ([string]::IsNullOrWhiteSpace($SummaryPath)) {
  $SummaryPath = Join-Path $WorkspaceRoot '.Rayman\runtime\decision.summary.tsv'
}

if ($MaxLines -lt 0) {
  $raw = [string]$env:RAYMAN_DECISION_LOG_MAX_LINES
  if ([string]::IsNullOrWhiteSpace($raw)) { $MaxLines = 2000 }
  else {
    $p = 0
    if ([int]::TryParse($raw, [ref]$p) -and $p -ge 0) { $MaxLines = $p }
    else { Fail "invalid RAYMAN_DECISION_LOG_MAX_LINES=$raw" }
  }
}

if ($KeepFiles -lt 0) {
  $raw = [string]$env:RAYMAN_DECISION_LOG_KEEP_FILES
  if ([string]::IsNullOrWhiteSpace($raw)) { $KeepFiles = 10 }
  else {
    $p = 0
    if ([int]::TryParse($raw, [ref]$p) -and $p -ge 0) { $KeepFiles = $p }
    else { Fail "invalid RAYMAN_DECISION_LOG_KEEP_FILES=$raw" }
  }
}

$logDir = Split-Path -Parent $LogPath
$summaryDir = Split-Path -Parent $SummaryPath
if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}
if (-not (Test-Path -LiteralPath $summaryDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $summaryDir | Out-Null
}
if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
  New-Item -ItemType File -Force -Path $LogPath | Out-Null
}

$lines = Get-Content -LiteralPath $LogPath -Encoding UTF8 -ErrorAction SilentlyContinue
if ($null -eq $lines) { $lines = @() }

if ($MaxLines -gt 0 -and $lines.Count -gt $MaxLines) {
  $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
  $backup = "$LogPath.$stamp.bak"
  Copy-Item -LiteralPath $LogPath -Destination $backup -Force
  $tail = @($lines | Select-Object -Last $MaxLines)
  Set-Content -LiteralPath $LogPath -Value $tail -Encoding UTF8
  $lines = $tail
}

if ($KeepFiles -ge 0) {
  $pattern = [System.IO.Path]::GetFileName($LogPath) + '.*.bak'
  $bakDir = Split-Path -Parent $LogPath
  $baks = @(Get-ChildItem -LiteralPath $bakDir -File -Filter $pattern -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
  if ($baks.Count -gt $KeepFiles) {
    foreach ($old in $baks | Select-Object -Skip $KeepFiles) {
      Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
    }
  }
}

$map = @{}
$rx = '^(?<ts>[^ ]+)\s+gate=(?<gate>[^ ]+)\s+action=(?<action>[^ ]+)(?:\s+[A-Za-z0-9_.-]+=[^ ]+)*\s+reason=(?<reason>.*)$'
foreach ($line in $lines) {
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  $m = [regex]::Match($line, $rx)
  if (-not $m.Success) { continue }

  $ts = $m.Groups['ts'].Value
  $date = if ($ts.Length -ge 10) { $ts.Substring(0, 10) } else { $ts }
  $gate = $m.Groups['gate'].Value
  $action = $m.Groups['action'].Value
  $reason = $m.Groups['reason'].Value

  $key = "$date`t$gate`t$action`t$reason"
  if (-not $map.ContainsKey($key)) {
    $map[$key] = [pscustomobject]@{
      date = $date
      gate = $gate
      action = $action
      reason = $reason
      count = 1
      first_ts = $ts
      last_ts = $ts
    }
  } else {
    $item = $map[$key]
    $item.count = [int]$item.count + 1
    $item.last_ts = $ts
  }
}

$rows = @(
  $map.Values |
    Sort-Object date, gate, action, reason |
    ForEach-Object {
      "{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}" -f $_.date, $_.gate, $_.action, $_.reason, $_.count, $_.first_ts, $_.last_ts
    }
)

$output = @('date`tgate`taction`treason`tcount`tfirst_ts`tlast_ts') + $rows
Set-Content -LiteralPath $SummaryPath -Value $output -Encoding UTF8

Info ("log={0} summary={1}" -f $LogPath, $SummaryPath)
