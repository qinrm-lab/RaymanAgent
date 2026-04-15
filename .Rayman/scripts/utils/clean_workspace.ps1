param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [int]$KeepDays = -1,
  [int]$DryRun = -1,
  [int]$Aggressive = -1,
  [int]$CopySmokeArtifacts = -1,
  [int]$AllowExternalTemp = -1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info([string]$m){ Write-Host ("ℹ️  [rayman-clean] {0}" -f $m) -ForegroundColor Cyan }
function Fail([string]$m){ Write-Host ("❌ [rayman-clean] {0}" -f $m) -ForegroundColor Red; exit 2 }

$runtimeCleanupScript = Join-Path $PSScriptRoot 'runtime_cleanup.ps1'
if (Test-Path -LiteralPath $runtimeCleanupScript -PathType Leaf) {
  . $runtimeCleanupScript -NoMain
}

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
if ($AllowExternalTemp -lt 0) { $AllowExternalTemp = Get-EnvInt -Name 'RAYMAN_CLEAN_ALLOW_EXTERNAL_TEMP' -Default 0 -Min 0 }

if ($DryRun -ne 0 -and $DryRun -ne 1) { Fail 'DryRun must be 0 or 1' }
if ($Aggressive -ne 0 -and $Aggressive -ne 1) { Fail 'Aggressive must be 0 or 1' }
if ($CopySmokeArtifacts -ne 0 -and $CopySmokeArtifacts -ne 1) { Fail 'CopySmokeArtifacts must be 0 or 1' }
if ($AllowExternalTemp -ne 0 -and $AllowExternalTemp -ne 1) { Fail 'AllowExternalTemp must be 0 or 1' }
if ($KeepDays -lt 0) { Fail 'KeepDays must be >= 0' }

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$report = Invoke-RaymanRuntimeCleanup -WorkspaceRoot $WorkspaceRoot -Mode 'workspace-clean' -KeepDays $KeepDays -DryRun:($DryRun -eq 1) -WriteSummary:($DryRun -eq 0) -Aggressive $Aggressive -CopySmokeArtifacts $CopySmokeArtifacts -AllowExternalTemp $AllowExternalTemp

if ([int]$report.planned_removal_count -le 0 -and [int]$report.preserved_count -le 0) {
  Info ("no entries matched (keep_days={0}, aggressive={1}, copy_smoke_artifacts={2}, allow_external_temp={3})" -f $KeepDays, $Aggressive, $CopySmokeArtifacts, $AllowExternalTemp)
  exit 0
}

Info ("workspace={0}" -f $WorkspaceRoot)
Info ("keep_days={0} dry_run={1} aggressive={2} copy_smoke_artifacts={3} allow_external_temp={4}" -f $KeepDays, $DryRun, $Aggressive, $CopySmokeArtifacts, $AllowExternalTemp)
foreach ($entry in @($report.planned_removals)) {
  Write-Host ("[rayman-clean] candidate: {0}" -f [string]$entry.path)
}
foreach ($entry in @($report.preserved)) {
  Write-Host ("[rayman-clean] preserve: {0} ({1})" -f [string]$entry.path, [string]$entry.reason)
}

if ($DryRun -eq 1) {
  Info 'dry-run only; no deletion executed'
  exit 0
}

Info ("removed={0}" -f [int]$report.removed_count)
if ($report.failed_count -gt 0) {
  foreach ($entry in @($report.failed)) {
    Write-Host ("⚠️  [rayman-clean] failed to remove {0}: {1}" -f [string]$entry.relative_path, [string]$entry.error) -ForegroundColor Yellow
  }
}
