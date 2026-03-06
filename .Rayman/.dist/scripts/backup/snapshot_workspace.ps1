param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [string]$Reason = 'manual',
  [int]$Keep = -1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info([string]$m){ Write-Host ("ℹ️  [rayman-snapshot] {0}" -f $m) -ForegroundColor Cyan }
function Fail([string]$m){ Write-Host ("❌ [rayman-snapshot] {0}" -f $m) -ForegroundColor Red; exit 2 }

if ($Keep -lt 0) {
  $raw = [string]$env:RAYMAN_SNAPSHOT_KEEP
  if ([string]::IsNullOrWhiteSpace($raw)) { $Keep = 5 }
  else {
    $v = 0
    if ([int]::TryParse($raw, [ref]$v) -and $v -ge 0) { $Keep = $v }
    else { Fail "invalid RAYMAN_SNAPSHOT_KEEP=$raw" }
  }
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$snapshotDir = Join-Path $WorkspaceRoot '.Rayman\runtime\snapshots'
if (-not (Test-Path -LiteralPath $snapshotDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $snapshotDir | Out-Null
}

$ts = Get-Date -Format 'yyyyMMddTHHmmss'
$reasonSlug = ($Reason -replace '[^A-Za-z0-9._-]+', '_').Trim('_')
if ([string]::IsNullOrWhiteSpace($reasonSlug)) { $reasonSlug = 'manual' }
$base = "snapshot-$ts-$reasonSlug"
$archive = Join-Path $snapshotDir ("$base.tar.gz")
$manifest = Join-Path $snapshotDir ("$base.manifest.json")

$tar = Get-Command tar -ErrorAction SilentlyContinue
if ($null -eq $tar) {
  Fail 'tar is required to create snapshot archives'
}

$excludes = @(
  '.Rayman/runtime/snapshots',
  '.Rayman/runtime/tmp',
  '.Rayman/runtime/artifacts',
  '.Rayman/logs',
  '.Rayman/state/chroma_db',
  '.Rayman/state/rag.db',
  '.venv',
  '.rag',
  '.tmp_sandbox_verify_*',
  '.tmp_sandbox_verify_clean_*',
  '.Rayman_full_for_copy',
  'Rayman_full_bundle'
)

$includes = New-Object 'System.Collections.Generic.List[string]'
$includes.Add('.Rayman') | Out-Null
$includes.Add('AGENTS.md') | Out-Null
$includes.Add('agents.md') | Out-Null
$includes.Add('.SolutionName') | Out-Null

$solutionNamePath = Join-Path $WorkspaceRoot '.SolutionName'
if (Test-Path -LiteralPath $solutionNamePath -PathType Leaf) {
  $sol = (Get-Content -LiteralPath $solutionNamePath -Raw -Encoding UTF8).Trim()
  if (-not [string]::IsNullOrWhiteSpace($sol)) {
    $solDir = Join-Path $WorkspaceRoot ('.' + $sol)
    if (Test-Path -LiteralPath $solDir -PathType Container) {
      $includes.Add('.' + $sol) | Out-Null
    }
  }
}

Push-Location $WorkspaceRoot
try {
  $args = @('-czf', $archive)
  foreach ($ex in $excludes) { $args += "--exclude=$ex" }
  $existingIncludes = @()
  foreach ($rel in $includes) {
    if (Test-Path -LiteralPath (Join-Path $WorkspaceRoot $rel)) {
      $existingIncludes += $rel
    }
  }
  if ($existingIncludes.Count -eq 0) {
    Fail "nothing to snapshot under $WorkspaceRoot"
  }
  $args += $existingIncludes
  & tar @args
  if ($LASTEXITCODE -ne 0) {
    Fail ("tar failed with exit code {0}" -f $LASTEXITCODE)
  }
} finally {
  Pop-Location
}

$payload = [pscustomobject]@{
  schema = 'rayman.snapshot.v1'
  generated_at = (Get-Date).ToString('o')
  reason = $Reason
  workspace_root = $WorkspaceRoot
  archive = $archive
  exclude = $excludes
  include = $existingIncludes
}
$payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifest -Encoding UTF8

if ($Keep -ge 0) {
  $archives = @(Get-ChildItem -LiteralPath $snapshotDir -Filter 'snapshot-*.tar.gz' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
  if ($archives.Count -gt $Keep) {
    foreach ($old in $archives | Select-Object -Skip $Keep) {
      Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
      $oldManifest = [System.IO.Path]::ChangeExtension($old.FullName, '.manifest.json')
      Remove-Item -LiteralPath $oldManifest -Force -ErrorAction SilentlyContinue
    }
  }
}

Info ("archive={0}" -f $archive)
Info ("manifest={0}" -f $manifest)
