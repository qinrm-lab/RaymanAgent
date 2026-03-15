param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$Force,
  [switch]$SkipPendingTask,
  [switch]$SkipContextRefresh
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info([string]$Message) { Write-Host ("[daily-health] {0}" -f $Message) -ForegroundColor Cyan }
function Warn([string]$Message) { Write-Host ("[daily-health] {0}" -f $Message) -ForegroundColor Yellow }

function Read-JsonOrNull([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Write-Json([string]$Path, [object]$Value) {
  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  ($Value | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-FileFingerprint([string[]]$Paths) {
  $tokens = New-Object System.Collections.Generic.List[string]
  foreach ($path in @($Paths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      continue
    }
    try {
      $item = Get-Item -LiteralPath $path -ErrorAction Stop
      $tokens.Add(("{0}|{1}|{2}" -f $item.FullName.Replace('\', '/'), [int64]$item.Length, [int64]$item.LastWriteTimeUtc.Ticks)) | Out-Null
    } catch {}
  }
  return (($tokens.ToArray() | Sort-Object) -join ';')
}

function Get-DailyHealthFingerprint {
  param([string]$Root)

  $fingerprintPaths = New-Object System.Collections.Generic.List[string]
  foreach ($candidate in @(
    (Join-Path $Root 'AGENTS.md'),
    (Join-Path $Root '.Rayman\scripts\watch\daily_health_check.ps1'),
    (Join-Path $Root '.Rayman\scripts\utils\generate_context.ps1'),
    (Join-Path $Root '.Rayman\state\pending_task.md')
  )) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $fingerprintPaths.Add($candidate) | Out-Null
    }
  }

  try {
    foreach ($req in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.requirements.md' -Force -ErrorAction SilentlyContinue)) {
      $fingerprintPaths.Add([string]$req.FullName) | Out-Null
    }
  } catch {}

  return (Get-FileFingerprint -Paths @($fingerprintPaths.ToArray()))
}

function Test-ShouldSkipDailyHealthPath {
  param(
    [string]$WorkspaceRoot,
    [string]$FullPath
  )

  if ([string]::IsNullOrWhiteSpace($FullPath)) { return $true }
  $rootNorm = $WorkspaceRoot.Replace('\', '/').TrimEnd('/')
  $pathNorm = $FullPath.Replace('\', '/')
  $relative = if ($pathNorm.StartsWith($rootNorm + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
    $pathNorm.Substring($rootNorm.Length + 1)
  } else {
    $pathNorm
  }
  $relLower = $relative.ToLowerInvariant()

  foreach ($prefix in @(
    '.git/',
    '.rayman/.dist/',
    '.rayman/runtime/',
    '.rayman/state/',
    '.rayman/logs/',
    '.artifacts/',
    'node_modules/',
    'test-results/',
    '.venv/',
    'dist/',
    'build/',
    'coverage/'
  )) {
    if ($relLower.StartsWith($prefix)) { return $true }
  }

  foreach ($segment in @('/bin/', '/obj/')) {
    if ($relLower.Contains($segment)) { return $true }
  }

  return $false
}

function Get-DailyHealthModeKey {
  param(
    [bool]$PendingSkipped,
    [bool]$ContextSkipped
  )

  return ("pending={0};context={1}" -f [string]$PendingSkipped, [string]$ContextSkipped).ToLowerInvariant()
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$stateDir = Join-Path $WorkspaceRoot '.Rayman\state'
$runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime'
$lastRunFile = Join-Path $stateDir 'daily_health_check.last.txt'
$statePath = Join-Path $stateDir 'daily_health_check.state.json'
$summaryPath = Join-Path $runtimeDir 'daily_health_check.summary.md'

if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
}
if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
}

$today = (Get-Date).ToString('yyyy-MM-dd')
$fingerprint = Get-DailyHealthFingerprint -Root $WorkspaceRoot
$modeKey = Get-DailyHealthModeKey -PendingSkipped $SkipPendingTask.IsPresent -ContextSkipped $SkipContextRefresh.IsPresent
$priorState = Read-JsonOrNull -Path $statePath

if (-not $Force -and $null -ne $priorState) {
  $priorFingerprint = ''
  $priorModeKey = ''
  $lastSuccessAt = $null
  if ($priorState.PSObject.Properties['fingerprint']) { $priorFingerprint = [string]$priorState.fingerprint }
  if ($priorState.PSObject.Properties['mode_key']) { $priorModeKey = [string]$priorState.mode_key }
  if ($priorState.PSObject.Properties['last_success_at']) {
    try { $lastSuccessAt = [datetimeoffset]::Parse([string]$priorState.last_success_at) } catch { $lastSuccessAt = $null }
  }

  $sameFingerprint = ($priorFingerprint -eq $fingerprint)
  $sameMode = ($priorModeKey -eq $modeKey)
  $freshEnough = $false
  if ($null -ne $lastSuccessAt) {
    $freshEnough = (((Get-Date).ToUniversalTime() - $lastSuccessAt.UtcDateTime).TotalHours -lt 24)
  }

  if ($sameFingerprint -and $sameMode -and $freshEnough) {
    Info ('skip: fresh cache hit (mode={0})' -f $modeKey)
    exit 0
  }
}

Info ('start ({0}; mode={1})' -f $today, $modeKey)

if (-not $SkipPendingTask) {
  $pendingScript = Join-Path $WorkspaceRoot '.Rayman\scripts\state\check_pending_task.ps1'
  if (Test-Path -LiteralPath $pendingScript -PathType Leaf) {
    try {
      & $pendingScript -WorkspaceRoot $WorkspaceRoot | Out-Host
    } catch {
      Warn ("pending task check failed: {0}" -f $_.Exception.Message)
    }
  }
}

if (-not $SkipContextRefresh) {
  $contextScript = Join-Path $WorkspaceRoot '.Rayman\scripts\utils\generate_context.ps1'
  if (Test-Path -LiteralPath $contextScript -PathType Leaf) {
    try {
      & $contextScript -WorkspaceRoot $WorkspaceRoot | Out-Host
    } catch {
      Warn ("context refresh failed: {0}" -f $_.Exception.Message)
    }
  }
}

$gitSummary = 'not-a-git-worktree'
$git = Get-Command 'git' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -ne $git -and -not [string]::IsNullOrWhiteSpace([string]$git.Source)) {
  try {
    Push-Location $WorkspaceRoot
    & $git.Source rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -eq 0) {
      $statusLines = @(& $git.Source status --short 2>$null)
      $gitSummary = ('changes={0}' -f $statusLines.Count)
    }
  } catch {
    $gitSummary = ('git-status-error: {0}' -f $_.Exception.Message)
  } finally {
    Pop-Location
  }
}

$todoMatches = @()
try {
  $scanFiles = @(Get-ChildItem -LiteralPath $WorkspaceRoot -File -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
    -not (Test-ShouldSkipDailyHealthPath -WorkspaceRoot $WorkspaceRoot -FullPath $_.FullName)
  })
  if ($scanFiles.Count -gt 0) {
    $todoMatches = @(Select-String -Path ($scanFiles | Select-Object -ExpandProperty FullName) -Pattern 'TODO|FIXME' -SimpleMatch:$false -ErrorAction SilentlyContinue | Select-Object -First 10)
  }
} catch {
  Warn ("todo scan failed: {0}" -f $_.Exception.Message)
}

$summary = New-Object System.Collections.Generic.List[string]
$summary.Add('# Rayman Daily Health Check') | Out-Null
$summary.Add('') | Out-Null
$summary.Add(('- generated_at: {0}' -f (Get-Date).ToString('o'))) | Out-Null
$summary.Add(('- mode: {0}' -f $modeKey)) | Out-Null
$summary.Add(('- git: {0}' -f $gitSummary)) | Out-Null
$summary.Add(('- todo_fixme_hits: {0}' -f $todoMatches.Count)) | Out-Null
if ($todoMatches.Count -gt 0) {
  $summary.Add('') | Out-Null
  $summary.Add('## sample hits') | Out-Null
  foreach ($hit in $todoMatches) {
    $rel = $hit.Path
    if ($hit.Path.StartsWith($WorkspaceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      $rel = $hit.Path.Substring($WorkspaceRoot.Length).TrimStart([char[]]@('\','/'))
    }
    $summary.Add(('- `{0}:{1}` {2}' -f $rel, $hit.LineNumber, $hit.Line.Trim())) | Out-Null
  }
}

$summary | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Set-Content -LiteralPath $lastRunFile -Value $today -Encoding UTF8
Write-Json -Path $statePath -Value ([ordered]@{
  last_success_at = (Get-Date).ToString('o')
  fingerprint = $fingerprint
  mode_key = $modeKey
  skip_pending_task = [bool]$SkipPendingTask
  skip_context_refresh = [bool]$SkipContextRefresh
  todo_hit_count = $todoMatches.Count
  git_summary = $gitSummary
  summary_path = $summaryPath
})

Info ("summary: {0}" -f $summaryPath)
exit 0
