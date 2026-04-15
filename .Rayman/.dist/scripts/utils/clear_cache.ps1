param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$DryRun,
  [switch]$Aggressive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info([string]$Message) { Write-Host ("ℹ️  [clear-cache] {0}" -f $Message) -ForegroundColor Cyan }
function Warn([string]$Message) { Write-Host ("⚠️  [clear-cache] {0}" -f $Message) -ForegroundColor Yellow }

$runtimeCleanupScript = Join-Path $PSScriptRoot 'runtime_cleanup.ps1'
if (Test-Path -LiteralPath $runtimeCleanupScript -PathType Leaf) {
  . $runtimeCleanupScript -NoMain
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$report = Invoke-RaymanRuntimeCleanup -WorkspaceRoot $WorkspaceRoot -Mode 'cache-clear' -KeepDays 14 -DryRun:$DryRun -WriteSummary:(!$DryRun.IsPresent) -Aggressive ([int]$Aggressive.IsPresent)

Info ("workspace={0}" -f $WorkspaceRoot)
Info ("matched={0} dry_run={1} aggressive={2}" -f [int]$report.planned_removal_count, [int]$DryRun.IsPresent, [int]$Aggressive.IsPresent)
foreach ($entry in @($report.planned_removals)) {
  Write-Host ("[clear-cache] candidate: {0}" -f [string]$entry.path)
}
foreach ($entry in @($report.preserved)) {
  Write-Host ("[clear-cache] preserve: {0} ({1})" -f [string]$entry.path, [string]$entry.reason)
}

if ($report.failed_count -gt 0) {
  foreach ($entry in @($report.failed)) {
    Warn ("failed to remove {0}: {1}" -f [string]$entry.relative_path, [string]$entry.error)
  }
}

Info ("removed={0}" -f [int]$report.removed_count)
exit 0
