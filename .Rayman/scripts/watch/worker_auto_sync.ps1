param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [string]$PidFile = '',
  [switch]$Once,
  [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
  throw "common.ps1 not found: $commonPath"
}
. $commonPath

$embeddedLibPath = Join-Path $PSScriptRoot 'embedded_watchers.lib.ps1'
if (-not (Test-Path -LiteralPath $embeddedLibPath -PathType Leaf)) {
  throw "embedded_watchers.lib.ps1 not found: $embeddedLibPath"
}
. $embeddedLibPath

$manageWorkersPath = Join-Path $PSScriptRoot '..\worker\manage_workers.ps1'
if (-not (Test-Path -LiteralPath $manageWorkersPath -PathType Leaf)) {
  throw "manage_workers.ps1 not found: $manageWorkersPath"
}
. $manageWorkersPath -WorkspaceRoot $WorkspaceRoot -NoMain

function Get-RaymanWorkerAutoSyncEnabled {
  param([string]$WorkspaceRoot)

  return (Get-RaymanWorkspaceEnvBool -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_WORKER_AUTO_SYNC_ENABLED' -Default $false)
}

function Get-RaymanWorkerAutoSyncEnvInt {
  param(
    [string]$WorkspaceRoot,
    [string]$Name,
    [int]$Default,
    [int]$Min,
    [int]$Max
  )

  $raw = Get-RaymanWorkspaceEnvString -WorkspaceRoot $WorkspaceRoot -Name $Name -Default ''
  $parsed = 0
  if (-not [string]::IsNullOrWhiteSpace([string]$raw) -and [int]::TryParse([string]$raw, [ref]$parsed)) {
    if ($parsed -lt $Min) { return $Min }
    if ($parsed -gt $Max) { return $Max }
    return $parsed
  }
  return $Default
}

function Get-RaymanWorkerAutoSyncBaseline {
  param(
    [string]$WorkspaceRoot,
    [object]$Active
  )

  $statusPath = Get-RaymanWorkerAutoSyncStatusPath -WorkspaceRoot $WorkspaceRoot
  $previous = Read-RaymanWorkerJsonFile -Path $statusPath
  $baselineFingerprint = ''
  $baselineTime = ''

  if ($null -ne $Active -and $Active.PSObject.Properties['sync_manifest'] -and $null -ne $Active.sync_manifest) {
    $syncManifest = $Active.sync_manifest
    if ($syncManifest.PSObject.Properties['source_fingerprint'] -and -not [string]::IsNullOrWhiteSpace([string]$syncManifest.source_fingerprint)) {
      $baselineFingerprint = [string]$syncManifest.source_fingerprint
      if ($syncManifest.PSObject.Properties['generated_at']) {
        $baselineTime = [string]$syncManifest.generated_at
      }
    }
  }

  if ([string]::IsNullOrWhiteSpace([string]$baselineFingerprint) -and $null -ne $previous) {
    $sameWorker = ($previous.PSObject.Properties['worker_id'] -and [string]$previous.worker_id -eq [string]$Active.worker_id)
    $sameMode = ($previous.PSObject.Properties['mode'] -and [string]$previous.mode -eq 'staged')
    if ($sameWorker -and $sameMode -and $previous.PSObject.Properties['last_success_fingerprint'] -and -not [string]::IsNullOrWhiteSpace([string]$previous.last_success_fingerprint)) {
      $baselineFingerprint = [string]$previous.last_success_fingerprint
      if ($previous.PSObject.Properties['last_success_at']) {
        $baselineTime = [string]$previous.last_success_at
      }
    }
  }

  return [pscustomobject]@{
    fingerprint = $baselineFingerprint
    last_success_at = $baselineTime
  }
}

function Reset-RaymanWorkerAutoSyncContext {
  param(
    [object]$State,
    [object]$Context
  )

  $active = if ($null -ne $Context) { $Context.active } else { $null }
  $baseline = if ($null -ne $active -and [string]$active.workspace_mode -eq 'staged') {
    Get-RaymanWorkerAutoSyncBaseline -WorkspaceRoot ([string]$State.WorkspaceRoot) -Active $active
  } else {
    [pscustomobject]@{
      fingerprint = ''
      last_success_at = ''
    }
  }

  $State.ContextWorkerId = if ($null -ne $active -and $active.PSObject.Properties['worker_id']) { [string]$active.worker_id } else { '' }
  $State.ContextMode = if ($null -ne $active -and $active.PSObject.Properties['workspace_mode']) { [string]$active.workspace_mode } else { '' }
  $State.Initialized = $false
  $State.ObservedFingerprint = ''
  $State.PendingFingerprint = ''
  $State.PendingSince = $null
  $State.CooldownUntil = $null
  $State.CooldownStatus = ''
  $State.CooldownError = ''
  $State.LastSuccessfulFingerprint = [string]$baseline.fingerprint
  $State.LastSuccessAt = [string]$baseline.last_success_at
}

function Set-RaymanWorkerAutoSyncPending {
  param(
    [object]$State,
    [string]$Fingerprint,
    [datetime]$Now
  )

  $State.PendingFingerprint = [string]$Fingerprint
  $State.PendingSince = $Now
  $State.CooldownUntil = $null
  $State.CooldownStatus = ''
  $State.CooldownError = ''
}

function Clear-RaymanWorkerAutoSyncPending {
  param([object]$State)

  $State.PendingFingerprint = ''
  $State.PendingSince = $null
  $State.CooldownUntil = $null
  $State.CooldownStatus = ''
  $State.CooldownError = ''
}

function Set-RaymanWorkerAutoSyncCooldown {
  param(
    [object]$State,
    [datetime]$Until,
    [string]$Status,
    [string]$Error = ''
  )

  $State.CooldownUntil = $Until
  $State.CooldownStatus = [string]$Status
  $State.CooldownError = [string]$Error
}

function Get-RaymanWorkerAutoSyncPreconditionStatus {
  param([string]$Message)

  $normalized = [string]$Message
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    return 'worker_status_unavailable'
  }

  $normalized = $normalized.ToLowerInvariant()
  if ($normalized.Contains('token') -or $normalized.Contains('unauthorized') -or $normalized.Contains('401')) {
    return 'worker_auth_failed'
  }
  if ($normalized.Contains('timed out') -or $normalized.Contains('timeout') -or $normalized.Contains('refused') -or $normalized.Contains('unreachable') -or $normalized.Contains('offline') -or $normalized.Contains('actively refused') -or $normalized.Contains('no connection')) {
    return 'worker_unreachable'
  }

  return 'worker_status_unavailable'
}

function Write-RaymanWorkerAutoSyncStatus {
  param(
    [object]$State,
    [string]$Status,
    [string]$WorkerId = '',
    [string]$Mode = '',
    [string]$Fingerprint = '',
    [int]$FileCount = 0,
    [string]$Error = '',
    [hashtable]$Extra = @{}
  )

  $payload = [ordered]@{
    schema = 'rayman.worker.auto_sync_status.v1'
    generated_at = (Get-Date).ToString('o')
    status = [string]$Status
    worker_id = [string]$WorkerId
    mode = [string]$Mode
    fingerprint = [string]$Fingerprint
    file_count = [int]$FileCount
    last_attempt_at = [string]$State.LastAttemptAt
    last_success_at = [string]$State.LastSuccessAt
    last_success_fingerprint = [string]$State.LastSuccessfulFingerprint
    error = [string]$Error
  }
  if ($null -ne $State.PendingSince) {
    $payload['pending_since'] = ([datetime]$State.PendingSince).ToString('o')
  }
  if ($null -ne $State.CooldownUntil) {
    $payload['retry_at'] = ([datetime]$State.CooldownUntil).ToString('o')
  }
  foreach ($key in @($Extra.Keys)) {
    $payload[[string]$key] = $Extra[$key]
  }
  Write-RaymanWorkerJsonFile -Path ([string]$State.StatusPath) -Value ([pscustomobject]$payload)
  return [pscustomobject]$payload
}

function New-RaymanWorkerAutoSyncState {
  param([string]$WorkspaceRoot)

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $runtimeRoot = Get-RaymanWorkerRuntimeRoot -WorkspaceRoot $resolvedRoot
  Ensure-RaymanWorkerDirectory -Path $runtimeRoot

  return [pscustomobject]@{
    WorkspaceRoot = $resolvedRoot
    StatusPath = (Get-RaymanWorkerAutoSyncStatusPath -WorkspaceRoot $resolvedRoot)
    PollMs = (Get-RaymanWorkerAutoSyncEnvInt -WorkspaceRoot $resolvedRoot -Name 'RAYMAN_WORKER_AUTO_SYNC_POLL_MS' -Default 2000 -Min 250 -Max 60000)
    DebounceSeconds = (Get-RaymanWorkerAutoSyncEnvInt -WorkspaceRoot $resolvedRoot -Name 'RAYMAN_WORKER_AUTO_SYNC_DEBOUNCE_SECONDS' -Default 5 -Min 0 -Max 600)
    RetrySeconds = (Get-RaymanWorkerAutoSyncEnvInt -WorkspaceRoot $resolvedRoot -Name 'RAYMAN_WORKER_AUTO_SYNC_RETRY_SECONDS' -Default 30 -Min 1 -Max 3600)
    ContextWorkerId = ''
    ContextMode = ''
    Initialized = $false
    ObservedFingerprint = ''
    PendingFingerprint = ''
    PendingSince = $null
    CooldownUntil = $null
    CooldownStatus = ''
    CooldownError = ''
    LastAttemptAt = ''
    LastSuccessAt = ''
    LastSuccessfulFingerprint = ''
  }
}

function Invoke-RaymanWorkerAutoSyncCycle {
  param([object]$State)

  if ($null -eq $State) {
    return [pscustomobject]@{
      should_exit = $false
      status = 'state_missing'
    }
  }

  $workspaceRoot = [string]$State.WorkspaceRoot
  if (-not (Get-RaymanWorkerAutoSyncEnabled -WorkspaceRoot $workspaceRoot)) {
    Write-RaymanWorkerAutoSyncStatus -State $State -Status 'disabled' | Out-Null
    return [pscustomobject]@{
      should_exit = $true
      status = 'disabled'
    }
  }

  $context = Get-RaymanWorkerActiveExecutionContext -WorkspaceRoot $workspaceRoot
  $active = if ($null -ne $context) { $context.active } else { $null }
  $worker = if ($null -ne $context) { $context.worker } else { $null }
  $workerId = if ($null -ne $active -and $active.PSObject.Properties['worker_id']) { [string]$active.worker_id } else { '' }
  $mode = if ($null -ne $active -and $active.PSObject.Properties['workspace_mode']) { [string]$active.workspace_mode } else { '' }

  if ($workerId -ne [string]$State.ContextWorkerId -or $mode -ne [string]$State.ContextMode) {
    Reset-RaymanWorkerAutoSyncContext -State $State -Context $context
  }

  if ($null -eq $context -or [string]::IsNullOrWhiteSpace([string]$workerId)) {
    Write-RaymanWorkerAutoSyncStatus -State $State -Status 'no_active_worker' | Out-Null
    return [pscustomobject]@{
      should_exit = $false
      status = 'no_active_worker'
    }
  }

  if ($mode -ne 'staged') {
    Write-RaymanWorkerAutoSyncStatus -State $State -Status 'waiting_for_staged' -WorkerId $workerId -Mode $mode | Out-Null
    return [pscustomobject]@{
      should_exit = $false
      status = 'waiting_for_staged'
    }
  }

  $fingerprintInfo = Get-RaymanWorkerSyncFingerprintInfo -WorkspaceRoot $workspaceRoot
  $fingerprint = [string]$fingerprintInfo.fingerprint
  $fileCount = [int]$fingerprintInfo.file_count
  $now = Get-Date
  $syncManifest = if ($active.PSObject.Properties['sync_manifest']) { $active.sync_manifest } else { $null }

  if (-not [bool]$State.Initialized) {
    $State.ObservedFingerprint = $fingerprint
    $State.Initialized = $true
    $hasBaseline = -not [string]::IsNullOrWhiteSpace([string]$State.LastSuccessfulFingerprint)
    if ($hasBaseline -and [string]$State.LastSuccessfulFingerprint -eq $fingerprint) {
      Clear-RaymanWorkerAutoSyncPending -State $State
    } elseif ($hasBaseline) {
      Set-RaymanWorkerAutoSyncPending -State $State -Fingerprint $fingerprint -Now $now
    } else {
      Clear-RaymanWorkerAutoSyncPending -State $State
    }
  } elseif ([string]$State.ObservedFingerprint -ne $fingerprint) {
    $State.ObservedFingerprint = $fingerprint
    Set-RaymanWorkerAutoSyncPending -State $State -Fingerprint $fingerprint -Now $now
  }

  if ([string]$State.PendingFingerprint -ne $fingerprint) {
    Clear-RaymanWorkerAutoSyncPending -State $State
  }

  if ([string]::IsNullOrWhiteSpace([string]$State.PendingFingerprint)) {
    Write-RaymanWorkerAutoSyncStatus -State $State -Status 'idle' -WorkerId $workerId -Mode $mode -Fingerprint $fingerprint -FileCount $fileCount | Out-Null
    return [pscustomobject]@{
      should_exit = $false
      status = 'idle'
    }
  }

  $debounceReadyAt = ([datetime]$State.PendingSince).AddSeconds([int]$State.DebounceSeconds)
  if ($now -lt $debounceReadyAt) {
    Write-RaymanWorkerAutoSyncStatus -State $State -Status 'debouncing' -WorkerId $workerId -Mode $mode -Fingerprint $fingerprint -FileCount $fileCount -Extra @{
      debounce_ready_at = $debounceReadyAt.ToString('o')
    } | Out-Null
    return [pscustomobject]@{
      should_exit = $false
      status = 'debouncing'
    }
  }

  if ($null -ne $State.CooldownUntil -and $now -lt [datetime]$State.CooldownUntil) {
    $cooldownStatus = if ([string]::IsNullOrWhiteSpace([string]$State.CooldownStatus)) { 'retry_wait' } else { [string]$State.CooldownStatus }
    Write-RaymanWorkerAutoSyncStatus -State $State -Status $cooldownStatus -WorkerId $workerId -Mode $mode -Fingerprint $fingerprint -FileCount $fileCount -Error ([string]$State.CooldownError) | Out-Null
    return [pscustomobject]@{
      should_exit = $false
      status = $cooldownStatus
    }
  }

  $State.LastAttemptAt = $now.ToString('o')
  $liveStatusReady = $false
  $result = $null
  try {
    $null = Get-RaymanWorkerLiveStatus -WorkspaceRoot $workspaceRoot -Worker $worker
    $liveStatusReady = $true
    $State.CooldownUntil = $null
    $State.CooldownStatus = ''
    $State.CooldownError = ''
    Write-RaymanWorkerAutoSyncStatus -State $State -Status 'syncing' -WorkerId $workerId -Mode $mode -Fingerprint $fingerprint -FileCount $fileCount | Out-Null
    $result = Invoke-RaymanWorkerSyncAction -WorkspaceRoot $workspaceRoot -Worker $worker -Mode 'staged'
    $State.LastSuccessfulFingerprint = $fingerprint
    $State.LastSuccessAt = (Get-Date).ToString('o')
    Clear-RaymanWorkerAutoSyncPending -State $State
    Write-RaymanWorkerAutoSyncStatus -State $State -Status 'success' -WorkerId $workerId -Mode $mode -Fingerprint $fingerprint -FileCount $fileCount -Extra @{
      bundle_id = if ($result.PSObject.Properties['bundle'] -and $null -ne $result.bundle -and $result.bundle.PSObject.Properties['bundle_id']) { [string]$result.bundle.bundle_id } else { '' }
      staging_root = if ($result.PSObject.Properties['sync_manifest'] -and $null -ne $result.sync_manifest -and $result.sync_manifest.PSObject.Properties['staging_root']) { [string]$result.sync_manifest.staging_root } else { '' }
    } | Out-Null
    return [pscustomobject]@{
      should_exit = $false
      status = 'success'
    }
  } catch {
    $message = [string]$_.Exception.Message
    $status = if (-not $liveStatusReady) {
      Get-RaymanWorkerAutoSyncPreconditionStatus -Message $message
    } else {
      'retry_wait'
    }
    Set-RaymanWorkerAutoSyncCooldown -State $State -Until ((Get-Date).AddSeconds([int]$State.RetrySeconds)) -Status $status -Error $message
    Write-RaymanWorkerAutoSyncStatus -State $State -Status $status -WorkerId $workerId -Mode $mode -Fingerprint $fingerprint -FileCount $fileCount -Error $message | Out-Null
    return [pscustomobject]@{
      should_exit = $false
      status = $status
    }
  }
}

if ($NoMain) {
  return
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
if ([string]::IsNullOrWhiteSpace([string]$PidFile)) {
  $PidFile = Join-Path $WorkspaceRoot '.Rayman\runtime\worker_auto_sync.pid'
}

$state = New-RaymanWorkerAutoSyncState -WorkspaceRoot $WorkspaceRoot
Set-RaymanWatcherPidFile -PidFile $PidFile -ProcessId $PID
Write-Info ("[worker-auto-sync] started (poll={0}ms, debounce={1}s, retry={2}s, once={3})" -f [int]$state.PollMs, [int]$state.DebounceSeconds, [int]$state.RetrySeconds, $Once.IsPresent)

try {
  do {
    $cycle = Invoke-RaymanWorkerAutoSyncCycle -State $state
    if ($Once -or [bool]$cycle.should_exit) {
      break
    }
    Start-Sleep -Milliseconds ([int]$state.PollMs)
  } while ($true)
} finally {
  try {
    Clear-RaymanWatcherPidFile -PidFile $PidFile -ExpectedPid $PID
  } catch {}
}
