param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [int]$KeepDays = -1,
  [int]$DryRun = -1,
  [int]$Aggressive = -1,
  [int]$CopySmokeArtifacts = -1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info([string]$m){ Write-Host ("ℹ️  [rayman-clean] {0}" -f $m) -ForegroundColor Cyan }
function Fail([string]$m){ Write-Host ("❌ [rayman-clean] {0}" -f $m) -ForegroundColor Red; exit 2 }

function Get-EnvInt([string]$Name, [int]$Default, [int]$Min = 0) {
  $raw = [string][System.Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
  $val = 0
  if ([int]::TryParse($raw, [ref]$val) -and $val -ge $Min) { return $val }
  return $Default
}

if ($KeepDays -lt 0) { $KeepDays = Get-EnvInt -Name 'RAYMAN_CLEAN_KEEP_DAYS' -Default 14 -Min 0 }
if ($DryRun -lt 0) { $DryRun = Get-EnvInt -Name 'RAYMAN_CLEAN_DRY_RUN' -Default 1 -Min 0 }
if ($Aggressive -lt 0) { $Aggressive = Get-EnvInt -Name 'RAYMAN_CLEAN_AGGRESSIVE' -Default 0 -Min 0 }
if ($CopySmokeArtifacts -lt 0) { $CopySmokeArtifacts = Get-EnvInt -Name 'RAYMAN_CLEAN_COPY_SMOKE_ARTIFACTS' -Default 0 -Min 0 }

if ($DryRun -ne 0 -and $DryRun -ne 1) { Fail 'DryRun must be 0 or 1' }
if ($Aggressive -ne 0 -and $Aggressive -ne 1) { Fail 'Aggressive must be 0 or 1' }
if ($CopySmokeArtifacts -ne 0 -and $CopySmokeArtifacts -ne 1) { Fail 'CopySmokeArtifacts must be 0 or 1' }
if ($KeepDays -lt 0) { Fail 'KeepDays must be >= 0' }

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$now = Get-Date

function Should-Delete([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  if ($KeepDays -eq 0) { return $true }

  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if ($null -eq $item) { return $false }
  $ageDays = [int][Math]::Floor(($now - $item.LastWriteTime).TotalDays)
  return ($ageDays -ge $KeepDays)
}

$candidates = New-Object 'System.Collections.Generic.List[string]'
function Add-Candidate([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  if (-not (Test-Path -LiteralPath $Path)) { return }
  if (Should-Delete -Path $Path) {
    if (-not $candidates.Contains($Path)) {
      $candidates.Add($Path) | Out-Null
    }
  }
}

Get-ChildItem -LiteralPath $WorkspaceRoot -Directory -Force -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -like '.tmp_sandbox_verify_*' -or $_.Name -like '.tmp_sandbox_verify_clean_*' } |
  ForEach-Object { Add-Candidate -Path $_.FullName }

$runtimeTmp = Join-Path $WorkspaceRoot '.Rayman\runtime\tmp'
if (Test-Path -LiteralPath $runtimeTmp -PathType Container) {
  Get-ChildItem -LiteralPath $runtimeTmp -Force -ErrorAction SilentlyContinue |
    ForEach-Object { Add-Candidate -Path $_.FullName }
}

$telemetryRoot = Join-Path $WorkspaceRoot '.Rayman\runtime\artifacts\telemetry'
if (Test-Path -LiteralPath $telemetryRoot -PathType Container) {
  Get-ChildItem -LiteralPath $telemetryRoot -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'test-bundle*' } |
    ForEach-Object { Add-Candidate -Path $_.FullName }
}

if ($Aggressive -eq 1) {
  Add-Candidate -Path (Join-Path $WorkspaceRoot '.Rayman_full_for_copy')
  Add-Candidate -Path (Join-Path $WorkspaceRoot 'Rayman_full_bundle')
}

if ($CopySmokeArtifacts -eq 1) {
  $tempRoot = [System.IO.Path]::GetTempPath()
  if (Test-Path -LiteralPath $tempRoot -PathType Container) {
    Get-ChildItem -LiteralPath $tempRoot -Directory -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like 'rayman_copy_smoke_*' } |
      ForEach-Object { Add-Candidate -Path $_.FullName }
  }
}

if ($candidates.Count -eq 0) {
  Info ("no entries matched (keep_days={0}, aggressive={1}, copy_smoke_artifacts={2})" -f $KeepDays, $Aggressive, $CopySmokeArtifacts)
  exit 0
}

Info ("workspace={0}" -f $WorkspaceRoot)
Info ("keep_days={0} dry_run={1} aggressive={2} copy_smoke_artifacts={3}" -f $KeepDays, $DryRun, $Aggressive, $CopySmokeArtifacts)
foreach ($p in $candidates) {
  $rel = $p
  if ($p.StartsWith($WorkspaceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    $rel = $p.Substring($WorkspaceRoot.Length).TrimStart('\','/')
  }
  Write-Host ("[rayman-clean] candidate: {0}" -f $rel)
}

if ($DryRun -eq 1) {
  Info 'dry-run only; no deletion executed'
  exit 0
}

$removed = 0
foreach ($p in $candidates) {
  if (Test-Path -LiteralPath $p) {
    Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
    $removed++
  }
}

Info ("removed={0}" -f $removed)
