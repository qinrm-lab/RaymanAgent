param(
  [string]$WorkspaceRoot = $(if (-not [string]::IsNullOrWhiteSpace([string]$PSScriptRoot)) { (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path } else { (Get-Location).Path }),
  [Parameter(Position = 0)][ValidateSet('install')][string]$Action = 'install',
  [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$CliArgs,
  [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$savedWorkspaceInstallCliState = @{
  WorkspaceRoot = $WorkspaceRoot
  Action = $Action
  CliArgs = @($CliArgs)
  NoMain = [bool]$NoMain
}

. (Join-Path $PSScriptRoot '..\..\common.ps1')
. (Join-Path $PSScriptRoot '..\release\package_distributable.ps1') -NoMain
$legacyCleanupScript = Join-Path $PSScriptRoot '..\utils\legacy_rayman_cleanup.ps1'
if (Test-Path -LiteralPath $legacyCleanupScript -PathType Leaf) {
  . $legacyCleanupScript -NoMain
}

$WorkspaceRoot = [string]$savedWorkspaceInstallCliState.WorkspaceRoot
$Action = [string]$savedWorkspaceInstallCliState.Action
$CliArgs = @($savedWorkspaceInstallCliState.CliArgs)
$NoMain = [bool]$savedWorkspaceInstallCliState.NoMain

function Ensure-RaymanWorkspaceInstallDirectory {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace([string]$Path)) { return }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Write-RaymanWorkspaceInstallUtf8NoBom {
  param(
    [string]$Path,
    [string]$Content
  )

  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace([string]$parent)) {
    Ensure-RaymanWorkspaceInstallDirectory -Path $parent
  }

  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Write-RaymanWorkspaceInstallJsonFile {
  param(
    [string]$Path,
    [object]$Value,
    [int]$Depth = 12
  )

  $json = ($Value | ConvertTo-Json -Depth $Depth)
  Write-RaymanWorkspaceInstallUtf8NoBom -Path $Path -Content (($json.TrimEnd()) + "`n")
}

function Read-RaymanWorkspaceInstallJsonFile {
  param([string]$Path)

  if (-not (Get-Command Read-RaymanJsonFile -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
  }

  $doc = Read-RaymanJsonFile -Path $Path
  if ($null -eq $doc -or -not [bool]$doc.Exists -or [bool]$doc.ParseFailed) {
    return $null
  }
  return $doc.Obj
}

function Get-RaymanWorkspaceInstallStateRoot {
  param([string]$WorkspaceRoot)

  $path = Join-Path $WorkspaceRoot '.Rayman\state\workspace_install'
  Ensure-RaymanWorkspaceInstallDirectory -Path $path
  return $path
}

function Get-RaymanWorkspaceInstallRuntimeRoot {
  param([string]$WorkspaceRoot)

  $path = Join-Path $WorkspaceRoot '.Rayman\runtime\workspace_install'
  Ensure-RaymanWorkspaceInstallDirectory -Path $path
  return $path
}

function Get-RaymanWorkspaceInstallDefaultsPath {
  param([string]$WorkspaceRoot)

  return (Join-Path (Get-RaymanWorkspaceInstallStateRoot -WorkspaceRoot $WorkspaceRoot) 'defaults.json')
}

function Get-RaymanWorkspaceInstallLastPath {
  param([string]$WorkspaceRoot)

  return (Join-Path (Get-RaymanWorkspaceInstallRuntimeRoot -WorkspaceRoot $WorkspaceRoot) 'last.json')
}

function Get-RaymanWorkspaceInstallAutoUpgradeLockPath {
  param([string]$WorkspaceRoot)

  return (Join-Path (Get-RaymanWorkspaceInstallStateRoot -WorkspaceRoot $WorkspaceRoot) 'auto_upgrade.lock.json')
}

function Get-RaymanWorkspaceInstallAutoUpgradeLastPath {
  param([string]$WorkspaceRoot)

  return (Join-Path (Get-RaymanWorkspaceInstallRuntimeRoot -WorkspaceRoot $WorkspaceRoot) 'auto_upgrade.last.json')
}

function Get-RaymanWorkspaceInstallAutoUpgradeLockTtlMinutes {
  return 30
}

function Get-RaymanWorkspaceInstallVersion {
  param([string]$WorkspaceRoot)

  $versionPath = Join-Path $WorkspaceRoot '.Rayman\VERSION'
  if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
    return 'unknown'
  }

  try {
    return (Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8).Trim()
  } catch {
    return 'unknown'
  }
}

function Get-RaymanWorkspaceInstallAppliedState {
  param([string]$WorkspaceRoot)

  $resolvedRoot = Resolve-RaymanWorkspaceInstallPath -Path $WorkspaceRoot
  $raymanRoot = Join-Path $resolvedRoot '.Rayman'
  $hasRayman = Test-Path -LiteralPath $raymanRoot -PathType Container
  $lastPath = Join-Path $resolvedRoot '.Rayman\runtime\workspace_install\last.json'
  $installRecord = if ($hasRayman -and (Test-Path -LiteralPath $lastPath -PathType Leaf)) {
    Read-RaymanWorkspaceInstallJsonFile -Path $lastPath
  } else {
    $null
  }

  return [pscustomobject]@{
    workspace_root = $resolvedRoot
    has_rayman = $hasRayman
    rayman_version = if ($hasRayman) { Get-RaymanWorkspaceInstallVersion -WorkspaceRoot $resolvedRoot } else { '' }
    last_path = $lastPath
    install_record = $installRecord
    install_record_exists = ($null -ne $installRecord)
    applied_published_version = if ($null -ne $installRecord -and $installRecord.PSObject.Properties['applied_published_version']) { [string]$installRecord.applied_published_version } else { '' }
    applied_published_fingerprint = if ($null -ne $installRecord -and $installRecord.PSObject.Properties['applied_published_fingerprint']) { [string]$installRecord.applied_published_fingerprint } else { '' }
  }
}

function Test-RaymanWorkspaceInstallProcessRunning {
  param([int]$Id)

  if ($Id -le 0) {
    return $false
  }

  try {
    $null = Get-Process -Id $Id -ErrorAction Stop | Select-Object -First 1
    return $true
  } catch {
    return $false
  }
}

function Read-RaymanWorkspaceInstallAutoUpgradeLock {
  param([string]$WorkspaceRoot)

  $lockPath = Join-Path (Resolve-RaymanWorkspaceInstallPath -Path $WorkspaceRoot) '.Rayman\state\workspace_install\auto_upgrade.lock.json'
  if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
    return $null
  }

  return (Read-RaymanWorkspaceInstallJsonFile -Path $lockPath)
}

function Write-RaymanWorkspaceInstallAutoUpgradeLock {
  param(
    [string]$WorkspaceRoot,
    [string]$Mode = 'auto_on_open',
    [string]$SourceWorkspaceRoot = '',
    [string]$PublishedVersion = '',
    [string]$PublishedFingerprint = ''
  )

  $resolvedRoot = Resolve-RaymanWorkspaceInstallPath -Path $WorkspaceRoot
  $payload = [pscustomobject]@{
    schema = 'rayman.workspace_install.auto_upgrade_lock.v1'
    workspace_root = $resolvedRoot
    source_workspace_root = [string]$SourceWorkspaceRoot
    published_version = [string]$PublishedVersion
    published_fingerprint = [string]$PublishedFingerprint
    mode = [string]$Mode
    pid = [int]$PID
    started_at = (Get-Date).ToString('o')
  }
  Write-RaymanWorkspaceInstallJsonFile -Path (Get-RaymanWorkspaceInstallAutoUpgradeLockPath -WorkspaceRoot $resolvedRoot) -Value $payload
  return $payload
}

function Clear-RaymanWorkspaceInstallAutoUpgradeLock {
  param([string]$WorkspaceRoot)

  $lockPath = Join-Path (Resolve-RaymanWorkspaceInstallPath -Path $WorkspaceRoot) '.Rayman\state\workspace_install\auto_upgrade.lock.json'
  if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
  }
}

function Get-RaymanWorkspaceInstallActiveAutoUpgradeLock {
  param([string]$WorkspaceRoot)

  $resolvedRoot = Resolve-RaymanWorkspaceInstallPath -Path $WorkspaceRoot
  $lockPath = Join-Path $resolvedRoot '.Rayman\state\workspace_install\auto_upgrade.lock.json'
  $lock = Read-RaymanWorkspaceInstallAutoUpgradeLock -WorkspaceRoot $resolvedRoot
  if ($null -eq $lock) {
    return $null
  }

  $lockPid = 0
  if ($lock.PSObject.Properties['pid']) {
    try { $lockPid = [int]$lock.pid } catch { $lockPid = 0 }
  }
  if ($lockPid -gt 0 -and (Test-RaymanWorkspaceInstallProcessRunning -Id $lockPid)) {
    return $lock
  }

  $startedAt = $null
  if ($lock.PSObject.Properties['started_at']) {
    try { $startedAt = [datetimeoffset]::Parse([string]$lock.started_at) } catch { $startedAt = $null }
  }
  if ($lockPid -le 0 -and $null -ne $startedAt) {
    $ageMinutes = ((Get-Date).ToUniversalTime() - $startedAt.UtcDateTime).TotalMinutes
    if ($ageMinutes -lt (Get-RaymanWorkspaceInstallAutoUpgradeLockTtlMinutes)) {
      return $lock
    }
  }

  if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
  }
  return $null
}

function Test-RaymanWorkspaceInstallInteractiveConsoleAvailable {
  try {
    return (-not [Console]::IsInputRedirected)
  } catch {
    return $true
  }
}

function Resolve-RaymanWorkspaceInstallPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace([string]$Path)) {
    return ''
  }

  try {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath([string]$Path)
  } catch {
    return [System.IO.Path]::GetFullPath([string]$Path)
  }
}

function Get-RaymanWorkspaceInstallDefaultsDocument {
  param([string]$WorkspaceRoot)

  $path = Get-RaymanWorkspaceInstallDefaultsPath -WorkspaceRoot $WorkspaceRoot
  $existing = Read-RaymanWorkspaceInstallJsonFile -Path $path
  if ($null -ne $existing) {
    return $existing
  }

  return [pscustomobject]@{
    schema = 'rayman.workspace_install.defaults.v1'
    target_path = ''
    last_install_at = ''
  }
}

function Save-RaymanWorkspaceInstallDefaultsDocument {
  param(
    [string]$WorkspaceRoot,
    [string]$TargetPath
  )

  $payload = [pscustomobject]@{
    schema = 'rayman.workspace_install.defaults.v1'
    target_path = [string]$TargetPath
    last_install_at = (Get-Date).ToString('o')
  }
  Write-RaymanWorkspaceInstallJsonFile -Path (Get-RaymanWorkspaceInstallDefaultsPath -WorkspaceRoot $WorkspaceRoot) -Value $payload
  return $payload
}

function Resolve-RaymanWorkspaceInstallTargetPath {
  param(
    [string]$WorkspaceRoot,
    [string]$RequestedTarget = ''
  )

  if (-not [string]::IsNullOrWhiteSpace([string]$RequestedTarget)) {
    return (Resolve-RaymanWorkspaceInstallPath -Path $RequestedTarget)
  }

  $defaults = Get-RaymanWorkspaceInstallDefaultsDocument -WorkspaceRoot $WorkspaceRoot
  $rememberedTarget = if ($defaults.PSObject.Properties['target_path']) { [string]$defaults.target_path } else { '' }

  if (-not (Test-RaymanWorkspaceInstallInteractiveConsoleAvailable)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rememberedTarget)) {
      return (Resolve-RaymanWorkspaceInstallPath -Path $rememberedTarget)
    }
    throw 'workspace-install requires --target when stdin is redirected.'
  }

  if (-not [string]::IsNullOrWhiteSpace([string]$rememberedTarget)) {
    $prompt = ("目标工作区根目录（回车复用：{0}）" -f $rememberedTarget)
    $input = [string](Read-Host $prompt)
    if ([string]::IsNullOrWhiteSpace([string]$input)) {
      return (Resolve-RaymanWorkspaceInstallPath -Path $rememberedTarget)
    }
    return (Resolve-RaymanWorkspaceInstallPath -Path $input)
  }

  $input = [string](Read-Host '请输入要安装 Rayman 的本地工作区根目录')
  if ([string]::IsNullOrWhiteSpace([string]$input)) {
    throw 'workspace-install requires a target path.'
  }
  return (Resolve-RaymanWorkspaceInstallPath -Path $input)
}

function Remove-RaymanWorkspaceInstallManagedPath {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }
  Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
}

function Move-RaymanWorkspaceInstallManagedPath {
  param(
    [string]$SourcePath,
    [string]$DestinationPath
  )

  if (-not (Test-Path -LiteralPath $SourcePath)) {
    return
  }
  Move-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
}

function Restore-RaymanWorkspaceInstallManagedPath {
  param(
    [string]$TargetPath,
    [string]$BackupPath
  )

  if (-not (Test-Path -LiteralPath $BackupPath)) {
    return
  }

  if (Test-Path -LiteralPath $TargetPath) {
    Remove-RaymanWorkspaceInstallManagedPath -Path $TargetPath
  }
  Move-Item -LiteralPath $BackupPath -Destination $TargetPath -Force
}

function Prune-RaymanWorkspaceInstallVolatileTargetPaths {
  param([string]$TargetRaymanPath)

  if ([string]::IsNullOrWhiteSpace([string]$TargetRaymanPath) -or -not (Test-Path -LiteralPath $TargetRaymanPath -PathType Container)) {
    return
  }

  foreach ($childName in @('runtime', 'logs', 'temp', 'tmp')) {
    $childPath = Join-Path $TargetRaymanPath $childName
    if (-not (Test-Path -LiteralPath $childPath)) {
      continue
    }
    Remove-RaymanWorkspaceInstallManagedPath -Path $childPath
  }
}

function Copy-RaymanWorkspaceInstallTree {
  param(
    [string]$SourceRoot,
    [string]$DestinationRoot
  )

  Ensure-RaymanWorkspaceInstallDirectory -Path $DestinationRoot
  foreach ($child in @(Get-ChildItem -LiteralPath $SourceRoot -Force -ErrorAction Stop)) {
    Copy-Item -LiteralPath $child.FullName -Destination (Join-Path $DestinationRoot $child.Name) -Recurse -Force
  }
}

function Get-RaymanWorkspaceInstallNormalizedPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace([string]$Path)) { return '' }
  return ([System.IO.Path]::GetFullPath([string]$Path)).TrimEnd('\', '/').ToLowerInvariant()
}

function New-RaymanWorkspaceInstallBackupRoot {
  param([string]$OperationId)

  $token = if ([string]::IsNullOrWhiteSpace([string]$OperationId)) {
    [Guid]::NewGuid().ToString('n')
  } else {
    [string]$OperationId
  }

  $baseRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'Rayman\workspace_install_backups'
  Ensure-RaymanWorkspaceInstallDirectory -Path $baseRoot

  $backupRoot = Join-Path $baseRoot $token
  Ensure-RaymanWorkspaceInstallDirectory -Path $backupRoot
  return $backupRoot
}

function Get-RaymanWorkspaceInstallLatestSetupLog {
  param([string]$TargetRoot)

  $logsRoot = Join-Path $TargetRoot '.Rayman\logs'
  if (-not (Test-Path -LiteralPath $logsRoot -PathType Container)) {
    return ''
  }

  try {
    $latest = Get-ChildItem -LiteralPath $logsRoot -Filter 'setup*.log' -File -ErrorAction Stop |
      Sort-Object LastWriteTimeUtc -Descending |
      Select-Object -First 1
    if ($null -ne $latest) {
      return [string]$latest.FullName
    }
  } catch {}

  return ''
}

function Add-RaymanWorkspaceInstallWarning {
  param(
    [System.Collections.IDictionary]$Result,
    [string]$Message
  )

  if ($null -eq $Result -or [string]::IsNullOrWhiteSpace([string]$Message)) {
    return
  }

  $existing = if ($Result.Contains('warning')) { [string]$Result.warning } else { '' }
  if ([string]::IsNullOrWhiteSpace([string]$existing)) {
    $Result.warning = [string]$Message
    return
  }

  $Result.warning = ("{0}; {1}" -f $existing, [string]$Message)
}

function Invoke-RaymanWorkspaceInstallSetup {
  param([string]$TargetRoot)

  $resolvedTarget = (Resolve-Path -LiteralPath $TargetRoot).Path
  $setupScript = Join-Path $resolvedTarget '.Rayman\setup.ps1'
  if (-not (Test-Path -LiteralPath $setupScript -PathType Leaf)) {
    throw ("workspace-install copied .Rayman but setup.ps1 is missing: {0}" -f $setupScript)
  }

  $psHost = Resolve-RaymanPowerShellHost
  if ([string]::IsNullOrWhiteSpace([string]$psHost)) {
    throw 'no PowerShell host found for workspace-install setup.'
  }

  $previousPostCheckMode = [Environment]::GetEnvironmentVariable('RAYMAN_SETUP_POST_CHECK_MODE')
  $previousSkipScmChecks = [Environment]::GetEnvironmentVariable('RAYMAN_SETUP_SKIP_SCM_CHECKS')
  $previousGithubLogin = [Environment]::GetEnvironmentVariable('RAYMAN_SETUP_GITHUB_LOGIN')
  try {
    [Environment]::SetEnvironmentVariable('RAYMAN_SETUP_POST_CHECK_MODE', 'skip')
    [Environment]::SetEnvironmentVariable('RAYMAN_SETUP_SKIP_SCM_CHECKS', '1')
    [Environment]::SetEnvironmentVariable('RAYMAN_SETUP_GITHUB_LOGIN', '0')
    $capture = Invoke-RaymanNativeCommandCapture -FilePath $psHost -ArgumentList @(
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      $setupScript,
      '-WorkspaceRoot',
      $resolvedTarget,
      '-SkipReleaseGate'
    ) -WorkingDirectory $resolvedTarget
  } finally {
    [Environment]::SetEnvironmentVariable('RAYMAN_SETUP_POST_CHECK_MODE', $previousPostCheckMode)
    [Environment]::SetEnvironmentVariable('RAYMAN_SETUP_SKIP_SCM_CHECKS', $previousSkipScmChecks)
    [Environment]::SetEnvironmentVariable('RAYMAN_SETUP_GITHUB_LOGIN', $previousGithubLogin)
  }

  $capture | Add-Member -MemberType NoteProperty -Name log_path -Value (Get-RaymanWorkspaceInstallLatestSetupLog -TargetRoot $resolvedTarget) -Force
  return $capture
}

function Invoke-RaymanWorkspaceInstallSelfCheck {
  param([string]$TargetRoot)

  $resolvedTarget = (Resolve-Path -LiteralPath $TargetRoot).Path
  $entryScript = Join-Path $resolvedTarget '.Rayman\rayman.ps1'
  if (-not (Test-Path -LiteralPath $entryScript -PathType Leaf)) {
    throw ("workspace-install copied .Rayman but rayman.ps1 is missing: {0}" -f $entryScript)
  }

  $psHost = Resolve-RaymanPowerShellHost
  if ([string]::IsNullOrWhiteSpace([string]$psHost)) {
    throw 'no PowerShell host found for workspace-install self-check.'
  }

  return (Invoke-RaymanNativeCommandCapture -FilePath $psHost -ArgumentList @(
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      $entryScript,
      'copy-self-check'
    ) -WorkingDirectory $resolvedTarget)
}

function Invoke-RaymanWorkspaceInstall {
  param(
    [string]$WorkspaceRoot,
    [string]$TargetPath = '',
    [switch]$NoRemember,
    [switch]$SelfCheck,
    [switch]$NoSelfCheck
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $result = [ordered]@{
    schema = 'rayman.workspace_install.result.v1'
    generated_at = (Get-Date).ToString('o')
    source_workspace_root = $resolvedRoot
    target_path = ''
    rayman_version = (Get-RaymanWorkspaceInstallVersion -WorkspaceRoot $resolvedRoot)
    copied_items = @('.Rayman')
    applied_published_version = ''
    applied_published_fingerprint = ''
    remembered_target = $false
    self_check_requested = $true
    status = 'failed'
    success = $false
    error = ''
    warning = ''
    legacy_cleanup = [pscustomobject]@{
      schema = 'rayman.workspace.legacy_cleanup.v1'
      workspace_root = ''
      removed_paths = @()
      removed_count = 0
      failed_paths = @()
      failed_count = 0
      warning = ''
    }
    setup = $null
    self_check = $null
  }

  $operationId = [Guid]::NewGuid().ToString('n')
  $backupRaymanPath = ''
  $backupRoot = ''
  $targetRaymanPath = ''
  $copyPhaseStarted = $false
  $copyPhaseCompleted = $false
  $setupPhaseStarted = $false
  $selfCheckPhaseStarted = $false
  $stage = $null
  $resultWorkspaceRoot = $resolvedRoot

  try {
    if (-not (Test-RaymanWindowsPlatform)) {
      throw 'workspace-install requires Windows.'
    }

    $runSelfCheck = $true
    if ($PSBoundParameters.ContainsKey('NoSelfCheck') -and [bool]$NoSelfCheck) {
      $runSelfCheck = $false
    }
    $result.self_check_requested = $runSelfCheck

    $resolvedTarget = Resolve-RaymanWorkspaceInstallTargetPath -WorkspaceRoot $resolvedRoot -RequestedTarget $TargetPath
    $result.target_path = [string]$resolvedTarget

    if ([string]::IsNullOrWhiteSpace([string]$resolvedTarget)) {
      throw 'workspace-install requires a target path.'
    }
    if (Test-Path -LiteralPath $resolvedTarget -PathType Leaf) {
      throw ("workspace-install target points to a file: {0}" -f $resolvedTarget)
    }

    $normalizedSource = Get-RaymanWorkspaceInstallNormalizedPath -Path $resolvedRoot
    $normalizedTarget = Get-RaymanWorkspaceInstallNormalizedPath -Path $resolvedTarget
    if ($normalizedTarget -eq $normalizedSource) {
      throw 'workspace-install target must not be the current source workspace.'
    }
    $sourceRaymanRoot = Get-RaymanWorkspaceInstallNormalizedPath -Path (Join-Path $resolvedRoot '.Rayman')
    if ($normalizedTarget.StartsWith($sourceRaymanRoot + '\')) {
      throw 'workspace-install target must not be inside the source .Rayman directory.'
    }

    Ensure-RaymanWorkspaceInstallDirectory -Path $resolvedTarget
    $resultWorkspaceRoot = $resolvedTarget
    $stage = New-RaymanDistributableStageDirectory -WorkspaceRoot $resolvedRoot
    $result.applied_published_version = if ($stage.PSObject.Properties['version']) { [string]$stage.version } else { [string]$result.rayman_version }
    $result.applied_published_fingerprint = if ($stage.PSObject.Properties['fingerprint']) { [string]$stage.fingerprint } else { '' }

    $targetRaymanPath = Join-Path $resolvedTarget '.Rayman'
    $backupRoot = New-RaymanWorkspaceInstallBackupRoot -OperationId $operationId
    $backupRaymanPath = Join-Path $backupRoot '.Rayman'

    $copyPhaseStarted = $true
    Prune-RaymanWorkspaceInstallVolatileTargetPaths -TargetRaymanPath $targetRaymanPath
    Move-RaymanWorkspaceInstallManagedPath -SourcePath $targetRaymanPath -DestinationPath $backupRaymanPath
    Copy-RaymanWorkspaceInstallTree -SourceRoot ([string]$stage.stage_rayman) -DestinationRoot $targetRaymanPath
    $copyPhaseCompleted = $true

    if (Get-Command Invoke-RaymanLegacyWorkspaceCleanup -ErrorAction SilentlyContinue) {
      $legacyCleanup = Invoke-RaymanLegacyWorkspaceCleanup -WorkspaceRoot $resolvedTarget
      if ($null -ne $legacyCleanup) {
        $result.legacy_cleanup = $legacyCleanup
        if ([int]$legacyCleanup.failed_count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$legacyCleanup.warning)) {
          Add-RaymanWorkspaceInstallWarning -Result $result -Message ([string]$legacyCleanup.warning)
        }
      }
    }

    $setupPhaseStarted = $true
    $setupCapture = Invoke-RaymanWorkspaceInstallSetup -TargetRoot $resolvedTarget
    $result.setup = $setupCapture
    if (-not [bool]$setupCapture.success) {
      $result.status = 'setup_failed'
      $result.error = if (-not [string]::IsNullOrWhiteSpace([string]$setupCapture.error)) {
        [string]$setupCapture.error
      } else {
        "workspace-install setup failed (exit=$([int]$setupCapture.exit_code))"
      }
      if ($setupCapture.PSObject.Properties['log_path'] -and -not [string]::IsNullOrWhiteSpace([string]$setupCapture.log_path)) {
        $result.error = "{0}; log={1}" -f $result.error, [string]$setupCapture.log_path
      }
      return [pscustomobject]$result
    }

    if ($runSelfCheck) {
      $selfCheckPhaseStarted = $true
      $selfCheckCapture = Invoke-RaymanWorkspaceInstallSelfCheck -TargetRoot $resolvedTarget
      $result.self_check = $selfCheckCapture
      if (-not [bool]$selfCheckCapture.success) {
        $result.status = 'self_check_failed'
        $result.error = if (-not [string]::IsNullOrWhiteSpace([string]$selfCheckCapture.error)) {
          [string]$selfCheckCapture.error
        } else {
          "workspace-install copy-self-check failed (exit=$([int]$selfCheckCapture.exit_code))"
        }
        return [pscustomobject]$result
      }
    }

    if (-not $NoRemember) {
      try {
        Save-RaymanWorkspaceInstallDefaultsDocument -WorkspaceRoot $resolvedRoot -TargetPath $resolvedTarget | Out-Null
        $result.remembered_target = $true
      } catch {
        Add-RaymanWorkspaceInstallWarning -Result $result -Message ("workspace-install succeeded but failed to remember the target path: {0}" -f $_.Exception.Message)
      }
    }

    $result.status = 'installed'
    $result.success = $true
    return [pscustomobject]$result
  } catch {
    if ([string]::IsNullOrWhiteSpace([string]$result.error)) {
      $result.error = [string]$_.Exception.Message
    }
    if ($selfCheckPhaseStarted) {
      $result.status = 'self_check_failed'
    } elseif ($setupPhaseStarted) {
      $result.status = 'setup_failed'
    } elseif ($copyPhaseStarted) {
      $result.status = 'copy_failed'
    } else {
      $result.status = 'failed'
    }
    return [pscustomobject]$result
  } finally {
    if (-not $copyPhaseCompleted) {
      if (-not [string]::IsNullOrWhiteSpace([string]$targetRaymanPath) -and -not [string]::IsNullOrWhiteSpace([string]$backupRaymanPath)) {
        try {
          Restore-RaymanWorkspaceInstallManagedPath -TargetPath $targetRaymanPath -BackupPath $backupRaymanPath
        } catch {}
      }
    } else {
      if (-not [string]::IsNullOrWhiteSpace([string]$backupRaymanPath)) {
        try { Remove-RaymanWorkspaceInstallManagedPath -Path $backupRaymanPath } catch {}
      }
      if (-not [string]::IsNullOrWhiteSpace([string]$backupRoot)) {
        try { Remove-RaymanWorkspaceInstallManagedPath -Path $backupRoot } catch {}
      }
    }

    if ($null -ne $stage -and $stage.PSObject.Properties['temp_root'] -and -not [string]::IsNullOrWhiteSpace([string]$stage.temp_root)) {
      try { Remove-RaymanWorkspaceInstallManagedPath -Path ([string]$stage.temp_root) } catch {}
    }

    try {
      Write-RaymanWorkspaceInstallJsonFile -Path (Get-RaymanWorkspaceInstallLastPath -WorkspaceRoot $resultWorkspaceRoot) -Value ([pscustomobject]$result)
    } catch {}
  }
}

if (-not $NoMain) {
  $WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  if ($null -eq $CliArgs) { $CliArgs = @() } else { $CliArgs = @($CliArgs) }

  $targetPath = ''
  $noRemember = $false
  $runSelfCheck = $true
  $json = $false

  for ($i = 0; $i -lt $CliArgs.Count; $i++) {
    $token = [string]$CliArgs[$i]
    switch -Regex ($token) {
      '^--?(target)$' { if ($i + 1 -lt $CliArgs.Count) { $targetPath = [string]$CliArgs[++$i] }; continue }
      '^--?(no-remember|noremember)$' { $noRemember = $true; continue }
      '^--?(self-check|selfcheck)$' { $runSelfCheck = $true; continue }
      '^--?(no-self-check|noselfcheck)$' { $runSelfCheck = $false; continue }
      '^--?(json)$' { $json = $true; continue }
      default { continue }
    }
  }

  $result = $null
  switch ($Action.ToLowerInvariant()) {
    'install' {
      $result = Invoke-RaymanWorkspaceInstall -WorkspaceRoot $WorkspaceRoot -TargetPath $targetPath -NoRemember:$noRemember -SelfCheck:$runSelfCheck -NoSelfCheck:(-not $runSelfCheck)
      break
    }
  }

  if (-not [bool]$result.success) {
    $global:LASTEXITCODE = 1
    if (-not $json -and -not [string]::IsNullOrWhiteSpace([string]$result.error)) {
      Write-Error ([string]$result.error)
    }
  }

  if ($json) {
    $result | ConvertTo-Json -Depth 12
  } elseif ([bool]$result.success) {
    Write-Host ("安装完成：{0}" -f [string]$result.target_path)
    Write-Host "已复制：.Rayman"
    Write-Host "已自动执行：powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\.Rayman\\setup.ps1"
    if ([bool]$result.self_check_requested) {
      Write-Host "已追加执行：rayman.ps1 copy-self-check"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$result.warning)) {
      Write-Warning ([string]$result.warning)
    }
  }

  exit $(if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 })
}
