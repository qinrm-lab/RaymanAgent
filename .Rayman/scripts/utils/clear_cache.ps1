param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$DryRun,
  [switch]$Aggressive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info([string]$Message) { Write-Host ("ℹ️  [clear-cache] {0}" -f $Message) -ForegroundColor Cyan }
function Warn([string]$Message) { Write-Host ("⚠️  [clear-cache] {0}" -f $Message) -ForegroundColor Yellow }

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$patterns = @(
  'bin', 'obj', '.vs', 'node_modules', '.pytest_cache', '.mypy_cache', '.ruff_cache',
  '__pycache__', '.turbo', '.next', 'dist', 'build', 'coverage', ('.' + 'rag')
)

$candidates = New-Object System.Collections.Generic.List[string]
Get-ChildItem -LiteralPath $WorkspaceRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue |
  Where-Object {
    $_.FullName -notmatch '\\.git\\' -and
    $_.FullName -notmatch '\\.venv\\' -and
    $_.FullName -notmatch '\\.Rayman\\.dist\\' -and
    $patterns -contains $_.Name
  } |
  ForEach-Object {
    if (-not $candidates.Contains($_.FullName)) { $candidates.Add($_.FullName) | Out-Null }
  }

foreach ($legacyPath in @(
  (Join-Path $WorkspaceRoot ('.' + 'rag')),
  (Join-Path (Join-Path $WorkspaceRoot '.Rayman\state') ('chroma' + '_db')),
  (Join-Path (Join-Path $WorkspaceRoot '.Rayman\state') ('rag' + '.db'))
)) {
  if (Test-Path -LiteralPath $legacyPath -ErrorAction SilentlyContinue) {
    if (-not $candidates.Contains($legacyPath)) { $candidates.Add($legacyPath) | Out-Null }
  }
}

if ($Aggressive) {
  foreach ($extra in @('.cache', '.parcel-cache')) {
    Get-ChildItem -LiteralPath $WorkspaceRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -eq $extra -and $_.FullName -notmatch '\\.git\\' } |
      ForEach-Object {
        if (-not $candidates.Contains($_.FullName)) { $candidates.Add($_.FullName) | Out-Null }
      }
  }
}

Info ("workspace={0}" -f $WorkspaceRoot)
Info ("matched={0} dry_run={1} aggressive={2}" -f $candidates.Count, [int]$DryRun.IsPresent, [int]$Aggressive.IsPresent)
foreach ($path in $candidates) {
  $rel = if ($path.StartsWith($WorkspaceRoot, [System.StringComparison]::OrdinalIgnoreCase)) { $path.Substring($WorkspaceRoot.Length).TrimStart([char[]]@('\','/')) } else { $path }
  Write-Host ("[clear-cache] candidate: {0}" -f $rel)
}

$raymanClean = Join-Path $WorkspaceRoot '.Rayman\scripts\utils\clean_workspace.ps1'
if ($DryRun) {
  if (Test-Path -LiteralPath $raymanClean -PathType Leaf) {
    & $raymanClean -WorkspaceRoot $WorkspaceRoot -DryRun 1 -Aggressive:$Aggressive.IsPresent | Out-Host
  }
  exit 0
}

$removed = 0
foreach ($path in $candidates) {
  try {
    if (Test-Path -LiteralPath $path) {
      Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
      $removed++
    }
  } catch {
    Warn ("failed to remove {0}: {1}" -f $path, $_.Exception.Message)
  }
}

if (Test-Path -LiteralPath $raymanClean -PathType Leaf) {
  & $raymanClean -WorkspaceRoot $WorkspaceRoot -DryRun 0 -Aggressive:$Aggressive.IsPresent | Out-Host
}

Info ("removed={0}" -f $removed)
exit 0
