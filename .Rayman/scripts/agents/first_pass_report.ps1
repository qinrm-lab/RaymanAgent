param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [int]$Window = 0,
  [int]$RecentDays = 3,
  [int]$BaselineDays = 14,
  [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-EnvIntCompat([string]$Name, [int]$Default, [int]$Min = 1, [int]$Max = 1000) {
  $raw = [Environment]::GetEnvironmentVariable($Name)
  $parsed = 0
  if (-not [string]::IsNullOrWhiteSpace($raw) -and [int]::TryParse($raw, [ref]$parsed)) {
    if ($parsed -lt $Min) { return $Min }
    if ($parsed -gt $Max) { return $Max }
    return $parsed
  }
  return $Default
}

function Ensure-Dir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Parse-FirstPassRows([string]$Path) {
  $rows = New-Object System.Collections.Generic.List[object]
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @($rows.ToArray()) }
  $lines = Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue
  foreach ($line in $lines) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line.StartsWith('ts_iso')) { continue }
    $parts = $line -split "`t"
    if ($parts.Count -lt 9) { continue }
    $tsRaw = [string]$parts[0]
    $ts = $null
    try { $ts = [datetime]::Parse($tsRaw) } catch { continue }
    $dur = 0
    [void][int]::TryParse([string]$parts[7], [ref]$dur)
    $round1Touched = $null
    $round1NetLineDelta = $null
    $round1Modified = $null
    $round1Added = $null
    $round1Deleted = $null
    $round1NetSizeDeltaBytes = $null
    if ($parts.Count -gt 9) {
      $tmp = 0
      if ([int]::TryParse([string]$parts[9], [ref]$tmp)) { $round1Touched = [int]$tmp }
    }
    if ($parts.Count -gt 10) {
      $tmp = 0
      if ([int]::TryParse([string]$parts[10], [ref]$tmp)) { $round1NetLineDelta = [int]$tmp }
    }
    if ($parts.Count -gt 11) {
      $tmp = 0
      if ([int]::TryParse([string]$parts[11], [ref]$tmp)) { $round1Modified = [int]$tmp }
    }
    if ($parts.Count -gt 12) {
      $tmp = 0
      if ([int]::TryParse([string]$parts[12], [ref]$tmp)) { $round1Added = [int]$tmp }
    }
    if ($parts.Count -gt 13) {
      $tmp = 0
      if ([int]::TryParse([string]$parts[13], [ref]$tmp)) { $round1Deleted = [int]$tmp }
    }
    if ($parts.Count -gt 14) {
      $tmp64 = [int64]0
      if ([int64]::TryParse([string]$parts[14], [ref]$tmp64)) { $round1NetSizeDeltaBytes = [int64]$tmp64 }
    }
    $rows.Add([pscustomobject]@{
      ts_iso = $tsRaw
      ts = $ts
      run_id = [string]$parts[1]
      profile = [string]$parts[2]
      stage = [string]$parts[3]
      scope = [string]$parts[4]
      status = [string]$parts[5]
      error_kind = [string]$parts[6]
      duration_ms = $dur
      command = [string]$parts[8]
      round1_touched_files = $round1Touched
      round1_net_line_delta = $round1NetLineDelta
      round1_modified_files = $round1Modified
      round1_added_files = $round1Added
      round1_deleted_files = $round1Deleted
      round1_net_size_delta_bytes = $round1NetSizeDeltaBytes
    }) | Out-Null
  }
  return @($rows | Sort-Object ts)
}

function Get-Rate([int]$Pass, [int]$Total) {
  if ($Total -le 0) { return 0.0 }
  return [Math]::Round(($Pass * 100.0) / $Total, 1)
}

function Get-AverageOrNull([double[]]$Values) {
  if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
  return [Math]::Round((@($Values | Measure-Object -Average).Average), 2)
}

function Get-PearsonCorrelation([double[]]$X, [double[]]$Y) {
  if ($null -eq $X -or $null -eq $Y) { return $null }
  if ($X.Count -ne $Y.Count) { return $null }
  if ($X.Count -lt 2) { return $null }

  $mx = Get-AverageOrNull -Values $X
  $my = Get-AverageOrNull -Values $Y
  if ($null -eq $mx -or $null -eq $my) { return $null }

  $sumXY = 0.0
  $sumX2 = 0.0
  $sumY2 = 0.0
  for ($i = 0; $i -lt $X.Count; $i++) {
    $dx = [double]$X[$i] - [double]$mx
    $dy = [double]$Y[$i] - [double]$my
    $sumXY += ($dx * $dy)
    $sumX2 += ($dx * $dx)
    $sumY2 += ($dy * $dy)
  }
  if ($sumX2 -le 0.0 -or $sumY2 -le 0.0) { return $null }
  return [Math]::Round(($sumXY / [Math]::Sqrt($sumX2 * $sumY2)), 4)
}

function Format-Nullable([object]$Value, [int]$Digits = 2) {
  if ($null -eq $Value) { return 'n/a' }
  try {
    return ([Math]::Round([double]$Value, $Digits)).ToString()
  } catch {
    return [string]$Value
  }
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$telemetryDir = Join-Path $WorkspaceRoot '.Rayman\runtime\telemetry'
Ensure-Dir -Path $telemetryDir

$sourcePath = Join-Path $telemetryDir 'first_pass_runs.tsv'
$reportPath = Join-Path $telemetryDir 'first_pass_report.md'
$jsonPath = Join-Path $telemetryDir 'first_pass_report.json'

if ($Window -le 0) {
  $Window = Get-EnvIntCompat -Name 'RAYMAN_FIRST_PASS_WINDOW' -Default 20 -Min 1 -Max 2000
}
if ($RecentDays -lt 1) { $RecentDays = 1 }
if ($BaselineDays -lt 1) { $BaselineDays = 1 }

$rows = @(Parse-FirstPassRows -Path $sourcePath)
$generatedAt = Get-Date

if ($rows.Count -eq 0) {
  $md = @(
    '# Rayman First-Pass Report',
    '',
    ("- generated_at: {0}" -f $generatedAt.ToString('o')),
    ("- source: {0}" -f $sourcePath),
    ("- window: {0}" -f $Window),
    '',
    'No first-pass records found.'
  ) -join "`r`n"
  Set-Content -LiteralPath $reportPath -Encoding UTF8 -Value $md

  $obj = [ordered]@{
    schema = 'rayman.telemetry.first_pass.v1'
    generated_at = $generatedAt.ToString('o')
    source = $sourcePath
    report = $reportPath
    has_data = $false
    window = $Window
    change_scale_correlation = [ordered]@{
      sample_with_scale = 0
      sample_total = 0
      round1_touched_files = [ordered]@{
        pass_avg = $null
        fail_avg = $null
        delta_pass_minus_fail = $null
        corr_status = $null
      }
      round1_abs_net_size_delta_bytes = [ordered]@{
        pass_avg = $null
        fail_avg = $null
        delta_pass_minus_fail = $null
        corr_status = $null
      }
    }
    summary = [ordered]@{
      total = 0
      pass = 0
      fail = 0
      first_pass_rate = 0.0
      avg_duration_ms = 0
      current_pass_streak = 0
    }
  }
  ($obj | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $jsonPath -Encoding UTF8
  Write-Host ("[first-pass] report={0}" -f $reportPath)
  Write-Host ("[first-pass] json={0}" -f $jsonPath)
  if ($Json) {
    Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | Write-Output
  }
  exit 0
}

$sample = @($rows | Select-Object -Last $Window)
$total = $sample.Count
$passCount = @($sample | Where-Object { [string]$_.status -eq 'OK' }).Count
$failCount = $total - $passCount
$rate = Get-Rate -Pass $passCount -Total $total
$avgDuration = [int][Math]::Round((@($sample | Measure-Object -Property duration_ms -Average).Average), 0)

$streak = 0
for ($i = $sample.Count - 1; $i -ge 0; $i--) {
  if ([string]$sample[$i].status -eq 'OK') {
    $streak++
    continue
  }
  break
}

$backendStats = $sample | Group-Object scope | Sort-Object Count -Descending | ForEach-Object {
  [pscustomobject]@{
    backend = [string]$_.Name
    count = [int]$_.Count
  }
}

$allDays = @($rows | ForEach-Object { $_.ts.ToString('yyyy-MM-dd') } | Select-Object -Unique | Sort-Object)
$recentDates = @()
$baselineDates = @()
if ($allDays.Count -gt 0) {
  $recentDates = @($allDays | Select-Object -Last $RecentDays)
  if ($allDays.Count -gt $recentDates.Count) {
    $remaining = @($allDays | Select-Object -First ($allDays.Count - $recentDates.Count))
    $baselineDates = @($remaining | Select-Object -Last $BaselineDays)
  }
}

$recentRows = @($rows | Where-Object { $recentDates -contains $_.ts.ToString('yyyy-MM-dd') })
$baselineRows = @($rows | Where-Object { $baselineDates -contains $_.ts.ToString('yyyy-MM-dd') })

$recentRate = Get-Rate -Pass (@($recentRows | Where-Object { [string]$_.status -eq 'OK' }).Count) -Total $recentRows.Count
$baselineRate = Get-Rate -Pass (@($baselineRows | Where-Object { [string]$_.status -eq 'OK' }).Count) -Total $baselineRows.Count
$deltaRate = [Math]::Round($recentRate - $baselineRate, 1)

$warnDrop = Get-EnvIntCompat -Name 'RAYMAN_FIRST_PASS_WARN_DROP' -Default 5 -Min 1 -Max 50
$blockDrop = Get-EnvIntCompat -Name 'RAYMAN_FIRST_PASS_BLOCK_DROP' -Default 10 -Min 1 -Max 80
$status = 'PASS'
if (($baselineRows.Count -gt 0) -and ($deltaRate -le (-1 * $blockDrop))) {
  $status = 'BLOCK'
} elseif (($baselineRows.Count -gt 0) -and ($deltaRate -le (-1 * $warnDrop))) {
  $status = 'WARN'
}

$scaleRows = @($sample | Where-Object {
  $null -ne $_.round1_touched_files -and ($null -ne $_.round1_net_size_delta_bytes -or $null -ne $_.round1_net_line_delta)
})
$passScaleRows = @($scaleRows | Where-Object { [string]$_.status -eq 'OK' })
$failScaleRows = @($scaleRows | Where-Object { [string]$_.status -ne 'OK' })

$statusBinary = New-Object System.Collections.Generic.List[double]
$touchValues = New-Object System.Collections.Generic.List[double]
$absScaleValues = New-Object System.Collections.Generic.List[double]
$passAbsScale = New-Object System.Collections.Generic.List[double]
$failAbsScale = New-Object System.Collections.Generic.List[double]
foreach ($r in $scaleRows) {
  $ok = ([string]$r.status -eq 'OK')
  $statusVal = 0.0
  if ($ok) { $statusVal = 1.0 }
  $statusBinary.Add($statusVal) | Out-Null
  $touchValues.Add([double]$r.round1_touched_files) | Out-Null

  $absScale = $null
  if ($null -ne $r.round1_net_size_delta_bytes) {
    $absScale = [Math]::Abs([double]$r.round1_net_size_delta_bytes)
  } elseif ($null -ne $r.round1_net_line_delta) {
    $absScale = [Math]::Abs([double]$r.round1_net_line_delta)
  }
  if ($null -ne $absScale) {
    $absScaleValues.Add([double]$absScale) | Out-Null
    if ($ok) { $passAbsScale.Add([double]$absScale) | Out-Null } else { $failAbsScale.Add([double]$absScale) | Out-Null }
  }
}

$passTouchAvg = Get-AverageOrNull -Values @($passScaleRows | ForEach-Object { [double]$_.round1_touched_files })
$failTouchAvg = Get-AverageOrNull -Values @($failScaleRows | ForEach-Object { [double]$_.round1_touched_files })
$passAbsScaleAvg = Get-AverageOrNull -Values @($passAbsScale.ToArray())
$failAbsScaleAvg = Get-AverageOrNull -Values @($failAbsScale.ToArray())

$touchCorr = Get-PearsonCorrelation -X @($statusBinary.ToArray()) -Y @($touchValues.ToArray())
$absScaleCorr = Get-PearsonCorrelation -X @($statusBinary.ToArray()) -Y @($absScaleValues.ToArray())

$touchDelta = $null
if ($null -ne $passTouchAvg -and $null -ne $failTouchAvg) { $touchDelta = [Math]::Round(([double]$passTouchAvg - [double]$failTouchAvg), 2) }
$absScaleDelta = $null
if ($null -ne $passAbsScaleAvg -and $null -ne $failAbsScaleAvg) { $absScaleDelta = [Math]::Round(([double]$passAbsScaleAvg - [double]$failAbsScaleAvg), 2) }

$mdLines = New-Object System.Collections.Generic.List[string]
$mdLines.Add('# Rayman First-Pass Report') | Out-Null
$mdLines.Add('') | Out-Null
$mdLines.Add(("- generated_at: {0}" -f $generatedAt.ToString('o'))) | Out-Null
$mdLines.Add(("- source: {0}" -f $sourcePath)) | Out-Null
$mdLines.Add(("- window: {0}" -f $Window)) | Out-Null
$mdLines.Add(("- status: {0}" -f $status)) | Out-Null
$mdLines.Add('') | Out-Null
$mdLines.Add('| metric | value |') | Out-Null
$mdLines.Add('| --- | ---: |') | Out-Null
$mdLines.Add(('| total | {0} |' -f $total)) | Out-Null
$mdLines.Add(('| pass | {0} |' -f $passCount)) | Out-Null
$mdLines.Add(('| fail | {0} |' -f $failCount)) | Out-Null
$mdLines.Add(('| first_pass_rate | {0}% |' -f $rate)) | Out-Null
$mdLines.Add(('| avg_duration_ms | {0} |' -f $avgDuration)) | Out-Null
$mdLines.Add(('| current_pass_streak | {0} |' -f $streak)) | Out-Null
$mdLines.Add('') | Out-Null
$mdLines.Add('## Backend Distribution') | Out-Null
$mdLines.Add('') | Out-Null
if ($backendStats.Count -eq 0) {
  $mdLines.Add('- (none)') | Out-Null
} else {
  $mdLines.Add('| backend | count |') | Out-Null
  $mdLines.Add('| --- | ---: |') | Out-Null
  foreach ($it in $backendStats) {
    $mdLines.Add(('| {0} | {1} |' -f $it.backend, $it.count)) | Out-Null
  }
}
$mdLines.Add('') | Out-Null
$mdLines.Add('## Baseline') | Out-Null
$mdLines.Add('') | Out-Null
$mdLines.Add(("- recent_days: {0}" -f $RecentDays)) | Out-Null
$mdLines.Add(("- baseline_days: {0}" -f $BaselineDays)) | Out-Null
$mdLines.Add(("- recent_rate: {0}%" -f $recentRate)) | Out-Null
$mdLines.Add(("- baseline_rate: {0}%" -f $baselineRate)) | Out-Null
$mdLines.Add(("- delta_rate: {0}%" -f $deltaRate)) | Out-Null
$mdLines.Add('') | Out-Null
$mdLines.Add('## Change-Scale Correlation (Round 1)') | Out-Null
$mdLines.Add('') | Out-Null
$mdLines.Add(("- sample_with_scale: {0}/{1}" -f $scaleRows.Count, $sample.Count)) | Out-Null
$mdLines.Add('- correlation uses `status(OK=1,FAIL=0)` vs change scale; near `-1` means larger changes correlate with lower first-pass probability.') | Out-Null
$mdLines.Add('') | Out-Null
$mdLines.Add('| metric | pass_avg | fail_avg | delta(pass-fail) | corr(status,metric) |') | Out-Null
$mdLines.Add('| --- | ---: | ---: | ---: | ---: |') | Out-Null
$mdLines.Add(('| round1_touched_files | {0} | {1} | {2} | {3} |' -f (Format-Nullable -Value $passTouchAvg), (Format-Nullable -Value $failTouchAvg), (Format-Nullable -Value $touchDelta), (Format-Nullable -Value $touchCorr -Digits 4))) | Out-Null
$mdLines.Add(('| round1_abs_net_size_delta_bytes | {0} | {1} | {2} | {3} |' -f (Format-Nullable -Value $passAbsScaleAvg), (Format-Nullable -Value $failAbsScaleAvg), (Format-Nullable -Value $absScaleDelta), (Format-Nullable -Value $absScaleCorr -Digits 4))) | Out-Null
$mdLines.Add('') | Out-Null
$mdLines.Add('Tips:') | Out-Null
$mdLines.Add('- `rayman trend --source .Rayman/runtime/telemetry/first_pass_runs.tsv --days 14`') | Out-Null
$mdLines.Add('- `rayman baseline-guard --source .Rayman/runtime/telemetry/first_pass_runs.tsv --report-only`') | Out-Null

Set-Content -LiteralPath $reportPath -Encoding UTF8 -Value ($mdLines -join "`r`n")

$jsonObj = [ordered]@{
  schema = 'rayman.telemetry.first_pass.v1'
  generated_at = $generatedAt.ToString('o')
  source = $sourcePath
  report = $reportPath
  has_data = $true
  window = $Window
  status = $status
  thresholds = [ordered]@{
    warn_drop = $warnDrop
    block_drop = $blockDrop
  }
  summary = [ordered]@{
    total = $total
    pass = $passCount
    fail = $failCount
    first_pass_rate = $rate
    avg_duration_ms = $avgDuration
    current_pass_streak = $streak
  }
  baseline = [ordered]@{
    recent_days = $RecentDays
    baseline_days = $BaselineDays
    recent_rate = $recentRate
    baseline_rate = $baselineRate
    delta_rate = $deltaRate
  }
  change_scale_correlation = [ordered]@{
    sample_with_scale = [int]$scaleRows.Count
    sample_total = [int]$sample.Count
    round1_touched_files = [ordered]@{
      pass_avg = $passTouchAvg
      fail_avg = $failTouchAvg
      delta_pass_minus_fail = $touchDelta
      corr_status = $touchCorr
    }
    round1_abs_net_size_delta_bytes = [ordered]@{
      pass_avg = $passAbsScaleAvg
      fail_avg = $failAbsScaleAvg
      delta_pass_minus_fail = $absScaleDelta
      corr_status = $absScaleCorr
    }
  }
  backend_distribution = @($backendStats)
}

($jsonObj | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $jsonPath -Encoding UTF8

Write-Host ("[first-pass] report={0}" -f $reportPath)
Write-Host ("[first-pass] json={0}" -f $jsonPath)
if ($Json) {
  Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | Write-Output
}
