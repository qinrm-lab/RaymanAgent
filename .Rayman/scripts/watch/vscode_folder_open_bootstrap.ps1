param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [string]$VscodeOwnerPid = '',
  [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
  throw "common.ps1 not found: $commonPath"
}
. $commonPath

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

function Import-BootstrapState([string]$Path) {
  $state = [ordered]@{
    steps = [ordered]@{}
  }
  $raw = Read-JsonOrNull -Path $Path
  if ($null -eq $raw -or $null -eq $raw.PSObject.Properties['steps']) {
    return $state
  }

  foreach ($prop in $raw.steps.PSObject.Properties) {
    $entry = [ordered]@{}
    foreach ($field in $prop.Value.PSObject.Properties) {
      $entry[[string]$field.Name] = $field.Value
    }
    $state.steps[[string]$prop.Name] = $entry
  }

  return $state
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

function Test-ContextRefreshFingerprintPath {
  param(
    [string]$Root,
    [string]$CandidatePath
  )

  if ([string]::IsNullOrWhiteSpace($CandidatePath)) { return $false }

  $resolvedRoot = ''
  $resolvedPath = ''
  try {
    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
  } catch {
    $resolvedRoot = $Root
  }
  try {
    $resolvedPath = (Resolve-Path -LiteralPath $CandidatePath).Path
  } catch {
    $resolvedPath = $CandidatePath
  }

  $rootNorm = (Get-RaymanPathComparisonValue -PathValue $resolvedRoot)
  $pathNorm = (Get-RaymanPathComparisonValue -PathValue $resolvedPath)
  if ([string]::IsNullOrWhiteSpace($rootNorm) -or [string]::IsNullOrWhiteSpace($pathNorm)) { return $false }
  if (-not ($pathNorm -eq $rootNorm -or $pathNorm.StartsWith($rootNorm + '/'))) { return $false }

  $relative = $pathNorm.Substring($rootNorm.Length).TrimStart('/')
  $relativeLower = $relative.ToLowerInvariant()
  $segments = @($relativeLower -split '/' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })

  foreach ($segment in $segments) {
    if ($segment -in @('.tmp', '.temp')) { return $false }
    if ($segment -like '.rayman.bak*') { return $false }
    if ($segment -like 'rayman_copy_smoke_*') { return $false }
  }

  foreach ($prefix in @(
    '.rayman/runtime/',
    '.rayman/state/',
    '.rayman/logs/',
    '.artifacts/',
    'artifacts/'
  )) {
    if ($relativeLower.StartsWith($prefix)) {
      return $false
    }
  }

  return $true
}

function Get-ContextRefreshFingerprint([string]$Root) {
  $paths = New-Object System.Collections.Generic.List[string]
  foreach ($candidate in @(
    (Join-Path $Root 'AGENTS.md'),
    (Join-Path $Root '.github\copilot-instructions.md'),
    (Join-Path $Root '.Rayman\scripts\utils\generate_context.ps1'),
    (Join-Path $Root '.Rayman\scripts\skills\detect_skills.ps1'),
    (Join-Path $Root '.Rayman\config\agent_capabilities.json'),
    (Join-Path $Root '.Rayman\config\agent_policy.json'),
    (Join-Path $Root '.Rayman\config\model_routing.json')
  )) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $paths.Add($candidate) | Out-Null
    }
  }

  try {
    foreach ($req in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.requirements.md' -Force -ErrorAction SilentlyContinue)) {
      if (-not (Test-ContextRefreshFingerprintPath -Root $Root -CandidatePath $req.FullName)) {
        continue
      }
      $paths.Add([string]$req.FullName) | Out-Null
    }
  } catch {}

  return (Get-FileFingerprint -Paths @($paths.ToArray()))
}

function Get-StepDueDecision {
  param(
    [hashtable]$State,
    [string]$Name,
    [int]$TtlHours = 24,
    [string]$Fingerprint = ''
  )

  if ($script:BootstrapProfile -eq 'active' -or $script:BootstrapProfile -eq 'strict') {
    return [pscustomobject]@{ due = $true; reason = 'profile-forces-run' }
  }

  if ($null -eq $State -or -not $State.steps.Contains($Name)) {
    return [pscustomobject]@{ due = $true; reason = 'never-ran' }
  }

  $entry = $State.steps[$Name]
  $lastSuccessAt = $null
  if ($entry.Contains('last_success_at')) {
    try { $lastSuccessAt = [datetimeoffset]::Parse([string]$entry['last_success_at']) } catch { $lastSuccessAt = $null }
  }
  if ($null -eq $lastSuccessAt) {
    return [pscustomobject]@{ due = $true; reason = 'missing-success-timestamp' }
  }

  $previousFingerprint = ''
  if ($entry.Contains('fingerprint')) {
    $previousFingerprint = [string]$entry['fingerprint']
  }
  if (-not [string]::IsNullOrWhiteSpace($Fingerprint) -and $Fingerprint -ne $previousFingerprint) {
    return [pscustomobject]@{ due = $true; reason = 'fingerprint-changed' }
  }

  $ageHours = ((Get-Date).ToUniversalTime() - $lastSuccessAt.UtcDateTime).TotalHours
  if ($ageHours -ge $TtlHours) {
    return [pscustomobject]@{ due = $true; reason = 'stale' }
  }

  return [pscustomobject]@{ due = $false; reason = 'fresh-cache' }
}

function Save-StepState {
  param(
    [hashtable]$State,
    [string]$Name,
    [string]$Fingerprint,
    [string]$Reason
  )

  if ($null -eq $State) { return }
  if (-not $State.Contains('steps')) {
    $State['steps'] = [ordered]@{}
  }
  $State.steps[$Name] = [ordered]@{
    last_success_at = (Get-Date).ToString('o')
    fingerprint = $Fingerprint
    reason = $Reason
  }
}

function Add-StepResult {
  param(
    [string]$Name,
    [string]$Status,
    [string]$Reason,
    [int]$DurationMs,
    [bool]$CacheHit = $false,
    [bool]$Mandatory = $false
  )

  $script:StepResults.Add([pscustomobject]@{
    name = $Name
    status = $Status
    reason = $Reason
    duration_ms = $DurationMs
    cache_hit = $CacheHit
    mandatory = $Mandatory
  }) | Out-Null
}

function Invoke-BootstrapStep {
  param(
    [string]$Name,
    [scriptblock]$Action,
    [bool]$Mandatory = $false,
    [object]$DueDecision = $null,
    [string]$Fingerprint = ''
  )

  if ($null -ne $DueDecision -and -not [bool]$DueDecision.due) {
    Write-Info ("[vscode-bootstrap] step={0} skip ({1})" -f $Name, [string]$DueDecision.reason)
    Add-StepResult -Name $Name -Status 'skipped' -Reason ([string]$DueDecision.reason) -DurationMs 0 -CacheHit $true -Mandatory $Mandatory
    return
  }

  $started = Get-Date
  try {
    Write-Info ("[vscode-bootstrap] step={0}" -f $Name)
    & $Action
    $durationMs = [int][Math]::Max(0, [Math]::Round(((Get-Date) - $started).TotalMilliseconds))
    Add-StepResult -Name $Name -Status 'ok' -Reason $(if ($null -eq $DueDecision) { 'mandatory' } else { [string]$DueDecision.reason }) -DurationMs $durationMs -Mandatory $Mandatory
    Save-StepState -State $script:BootstrapState -Name $Name -Fingerprint $Fingerprint -Reason $(if ($null -eq $DueDecision) { 'mandatory' } else { [string]$DueDecision.reason })
  } catch {
    $durationMs = [int][Math]::Max(0, [Math]::Round(((Get-Date) - $started).TotalMilliseconds))
    $message = [string]$_.Exception.Message
    Add-StepResult -Name $Name -Status 'failed' -Reason $message -DurationMs $durationMs -Mandatory $Mandatory
    Write-Warn ("[vscode-bootstrap] step failed ({0}): {1}" -f $Name, $message)
    Write-RaymanDiag -Scope 'vscode-bootstrap' -Message ("step failed; workspace={0}; step={1}; error={2}" -f $WorkspaceRoot, $Name, $_.Exception.ToString())
    $script:HasStepFailures = $true
  }
}

if ($NoMain) {
  return
}

if (-not (Get-RaymanEnvBool -Name 'RAYMAN_VSCODE_FOLDER_OPEN_BOOTSTRAP_ENABLED' -Default $true)) {
  Write-Info '[vscode-bootstrap] disabled by RAYMAN_VSCODE_FOLDER_OPEN_BOOTSTRAP_ENABLED=0.'
  exit 0
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$stateDir = Join-Path $WorkspaceRoot '.Rayman\state'
$runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime'
if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
}
if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
}

$reportPath = Join-Path $runtimeDir 'vscode_bootstrap.last.json'
$sessionPath = Join-Path $stateDir 'vscode_bootstrap.session.json'
$bootstrapStatePath = Join-Path $stateDir 'vscode_bootstrap.state.json'
$script:BootstrapProfile = Get-RaymanVscodeBootstrapProfile -WorkspaceRoot $WorkspaceRoot
$script:BootstrapState = Import-BootstrapState -Path $bootstrapStatePath
$script:StepResults = New-Object System.Collections.Generic.List[object]
$script:HasStepFailures = $false
$runId = [Guid]::NewGuid().ToString('n')
$startedAt = Get-Date
$effectiveOwnerPid = if ([string]::IsNullOrWhiteSpace($VscodeOwnerPid)) { [string]$PID } else { [string]$VscodeOwnerPid }

$existingSession = Read-JsonOrNull -Path $sessionPath
if ($null -ne $existingSession) {
  $sameOwner = $false
  $recentEnough = $false
  if ($existingSession.PSObject.Properties['owner_pid']) {
    $sameOwner = ([string]$existingSession.owner_pid -eq $effectiveOwnerPid)
  }
  if ($existingSession.PSObject.Properties['started_at']) {
    try {
      $existingStartedAt = [datetimeoffset]::Parse([string]$existingSession.started_at)
      $recentEnough = (((Get-Date).ToUniversalTime() - $existingStartedAt.UtcDateTime).TotalSeconds -lt 120)
    } catch {
      $recentEnough = $false
    }
  }
  if ($sameOwner -and $recentEnough) {
    Add-StepResult -Name 'session-dedupe' -Status 'skipped' -Reason 'duplicate-session' -DurationMs 0 -CacheHit $true -Mandatory $true
    Write-Json -Path $reportPath -Value ([ordered]@{
      schema = 'rayman.vscode_bootstrap.v1'
      run_id = $runId
      workspace_root = $WorkspaceRoot
      profile = $script:BootstrapProfile
      owner_pid = $effectiveOwnerPid
      started_at = $startedAt.ToString('o')
      finished_at = (Get-Date).ToString('o')
      duplicate_session = $true
      steps = @($script:StepResults.ToArray())
    })
    Write-Info '[vscode-bootstrap] skipped duplicate session.'
    exit 0
  }
}

Write-Json -Path $sessionPath -Value ([ordered]@{
  run_id = $runId
  owner_pid = $effectiveOwnerPid
  profile = $script:BootstrapProfile
  started_at = $startedAt.ToString('o')
})

$watchScript = Join-Path $WorkspaceRoot '.Rayman\scripts\watch\start_background_watchers.ps1'
$pendingScript = Join-Path $WorkspaceRoot '.Rayman\scripts\state\check_pending_task.ps1'
$dailyScript = Join-Path $WorkspaceRoot '.Rayman\scripts\watch\daily_health_check.ps1'
$contextScript = Join-Path $WorkspaceRoot '.Rayman\scripts\utils\generate_context.ps1'
$winDepsScript = Join-Path $WorkspaceRoot '.Rayman\scripts\utils\ensure_win_deps.ps1'
$checkWslScript = Join-Path $WorkspaceRoot '.Rayman\scripts\utils\check_wsl_deps.sh'
$contextFingerprint = Get-ContextRefreshFingerprint -Root $WorkspaceRoot

try {
  Invoke-BootstrapStep -Name 'start-background-watchers' -Mandatory $true -Action {
    if (-not (Test-Path -LiteralPath $watchScript -PathType Leaf)) {
      throw ("missing script: {0}" -f $watchScript)
    }
    & $watchScript -WorkspaceRoot $WorkspaceRoot -VscodeOwnerPid $VscodeOwnerPid -FromVscodeAuto | Out-Host
  }

  Invoke-BootstrapStep -Name 'check-pending-task' -Mandatory $true -Action {
    if (Test-Path -LiteralPath $pendingScript -PathType Leaf) {
      & $pendingScript -WorkspaceRoot $WorkspaceRoot | Out-Host
    }
  }

  $dailyDue = Get-StepDueDecision -State $script:BootstrapState -Name 'daily-health-check' -TtlHours 24 -Fingerprint $contextFingerprint
  Invoke-BootstrapStep -Name 'daily-health-check' -DueDecision $dailyDue -Fingerprint $contextFingerprint -Action {
    if (-not (Test-Path -LiteralPath $dailyScript -PathType Leaf)) {
      throw ("missing script: {0}" -f $dailyScript)
    }
    & $dailyScript -WorkspaceRoot $WorkspaceRoot -SkipPendingTask -SkipContextRefresh | Out-Host
  }

  $contextDue = Get-StepDueDecision -State $script:BootstrapState -Name 'context-refresh' -TtlHours 24 -Fingerprint $contextFingerprint
  Invoke-BootstrapStep -Name 'context-refresh' -DueDecision $contextDue -Fingerprint $contextFingerprint -Action {
    if (-not (Test-Path -LiteralPath $contextScript -PathType Leaf)) {
      throw ("missing script: {0}" -f $contextScript)
    }
    & $contextScript -WorkspaceRoot $WorkspaceRoot | Out-Host
  }

  $winDepsDue = Get-StepDueDecision -State $script:BootstrapState -Name 'check-win-deps-lightweight' -TtlHours 12
  Invoke-BootstrapStep -Name 'check-win-deps-lightweight' -DueDecision $winDepsDue -Action {
    if (Test-Path -LiteralPath $winDepsScript -PathType Leaf) {
      & $winDepsScript -WorkspaceRoot $WorkspaceRoot -Lightweight | Out-Host
    }
  }

  $wslDepsDue = Get-StepDueDecision -State $script:BootstrapState -Name 'check-wsl-deps' -TtlHours 12
  Invoke-BootstrapStep -Name 'check-wsl-deps' -DueDecision $wslDepsDue -Action {
    if (Test-RaymanWindowsPlatform) {
      return
    }
    if (-not (Test-Path -LiteralPath $checkWslScript -PathType Leaf)) {
      return
    }
    $bash = Get-Command 'bash' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $bash -or [string]::IsNullOrWhiteSpace([string]$bash.Source)) {
      throw 'bash not found'
    }

    $workspaceEscaped = $WorkspaceRoot.Replace("'", "'\''")
    $scriptEscaped = './.Rayman/scripts/utils/check_wsl_deps.sh'
    & $bash.Source -lc ("cd '{0}' && bash {1}" -f $workspaceEscaped, $scriptEscaped) | Out-Host
  }
} finally {
  Write-Json -Path $sessionPath -Value ([ordered]@{
    run_id = $runId
    owner_pid = $effectiveOwnerPid
    profile = $script:BootstrapProfile
    started_at = $startedAt.ToString('o')
    completed_at = (Get-Date).ToString('o')
  })
  Write-Json -Path $bootstrapStatePath -Value $script:BootstrapState
}

$finishedAt = Get-Date
Write-Json -Path $reportPath -Value ([ordered]@{
  schema = 'rayman.vscode_bootstrap.v1'
  run_id = $runId
  workspace_root = $WorkspaceRoot
  profile = $script:BootstrapProfile
  owner_pid = $effectiveOwnerPid
  started_at = $startedAt.ToString('o')
  finished_at = $finishedAt.ToString('o')
  duration_ms = [int][Math]::Max(0, [Math]::Round(($finishedAt - $startedAt).TotalMilliseconds))
  steps = @($script:StepResults.ToArray())
})

if ($script:HasStepFailures -and $script:BootstrapProfile -eq 'strict') {
  Write-Warn '[vscode-bootstrap] completed with failures (strict profile).'
  exit 1
}

Write-Info ('[vscode-bootstrap] completed (profile={0}).' -f $script:BootstrapProfile)
exit 0
