param(
  [string]$StatePath = '',
  [string]$TargetPath = '',
  [string[]]$CliArgs = @(),
  [switch]$AutoOnOpen,
  [switch]$Json,
  [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\..\common.ps1')
. (Join-Path $PSScriptRoot '..\release\package_distributable.ps1') -NoMain
. (Join-Path $PSScriptRoot '.\install_workspace.ps1') -NoMain

function Resolve-RaymanRegisteredBootstrapPath {
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

function Get-RaymanRegisteredBootstrapDefaultStatePath {
  $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
  if ([string]::IsNullOrWhiteSpace([string]$localAppData)) {
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace([string]$userProfile)) {
      $userProfile = [Environment]::GetEnvironmentVariable('USERPROFILE')
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$userProfile)) {
      $localAppData = Join-Path $userProfile 'AppData\Local'
    }
  }
  if ([string]::IsNullOrWhiteSpace([string]$localAppData)) {
    throw 'registered workspace bootstrap could not resolve LOCALAPPDATA.'
  }

  return (Join-Path (Resolve-RaymanRegisteredBootstrapPath -Path $localAppData) 'Rayman\state\workspace_source.json')
}

function Read-RaymanRegisteredBootstrapJsonOrNull {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  return (Read-RaymanWorkspaceInstallJsonFile -Path $Path)
}

function Get-RaymanRegisteredBootstrapInstallOptions {
  param([string[]]$InputArgs = @())

  $noRemember = $false
  $runSelfCheck = $true
  foreach ($token in @($InputArgs)) {
    switch -Regex ([string]$token) {
      '^--?(no-remember|noremember)$' { $noRemember = $true; continue }
      '^--?(self-check|selfcheck)$' { $runSelfCheck = $true; continue }
      '^--?(no-self-check|noselfcheck)$' { $runSelfCheck = $false; continue }
      default { continue }
    }
  }

  return [pscustomobject]@{
    no_remember = $noRemember
    run_self_check = $runSelfCheck
  }
}

function Invoke-RaymanRegisteredWorkspaceBootstrapRefresh {
  param(
    [string]$TargetWorkspaceRoot,
    [string]$VscodeOwnerPid = ''
  )

  $resolvedTarget = Resolve-RaymanRegisteredBootstrapPath -Path $TargetWorkspaceRoot
  $scriptPath = Join-Path $resolvedTarget '.Rayman\scripts\watch\vscode_folder_open_bootstrap.ps1'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    return [pscustomobject]@{
      success = $false
      exit_code = 1
      command = ''
      error = ("missing vscode folder open bootstrap script: {0}" -f $scriptPath)
      stdout = @()
      stderr = @()
      output = ''
    }
  }

  $psHost = Resolve-RaymanPowerShellHost
  if ([string]::IsNullOrWhiteSpace([string]$psHost)) {
    return [pscustomobject]@{
      success = $false
      exit_code = 1
      command = ''
      error = 'no PowerShell host found for vscode folder open bootstrap refresh.'
      stdout = @()
      stderr = @()
      output = ''
    }
  }

  $argumentList = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $scriptPath,
    '-WorkspaceRoot',
    $resolvedTarget
  )
  if (-not [string]::IsNullOrWhiteSpace([string]$VscodeOwnerPid)) {
    $argumentList += @('-VscodeOwnerPid', [string]$VscodeOwnerPid)
  }

  return (Invoke-RaymanNativeCommandCapture -FilePath $psHost -ArgumentList $argumentList -WorkingDirectory $resolvedTarget)
}

function Invoke-RaymanRegisteredWorkspaceBootstrap {
  param(
    [string]$StatePath = '',
    [string]$TargetPath = '',
    [string[]]$CliArgs = @(),
    [switch]$AutoOnOpen
  )

  $resolvedStatePath = if ([string]::IsNullOrWhiteSpace([string]$StatePath)) {
    Get-RaymanRegisteredBootstrapDefaultStatePath
  } else {
    Resolve-RaymanRegisteredBootstrapPath -Path $StatePath
  }
  $resolvedTarget = if ([string]::IsNullOrWhiteSpace([string]$TargetPath)) {
    Resolve-RaymanRegisteredBootstrapPath -Path ((Get-Location).Path)
  } else {
    Resolve-RaymanRegisteredBootstrapPath -Path $TargetPath
  }

  $timestamp = (Get-Date).ToString('o')
  $result = [ordered]@{
    schema = 'rayman.workspace.bootstrap.result.v1'
    generated_at = $timestamp
    state_path = $resolvedStatePath
    target_path = $resolvedTarget
    source_workspace_path = ''
    published_version = ''
    published_fingerprint = ''
    current_rayman_version = ''
    current_install_fingerprint = ''
    auto_on_open = [bool]$AutoOnOpen
    upgrade_needed = $false
    status = 'failed'
    success = $false
    skipped_reason = ''
    error = ''
    warning = ''
    install = $null
    bootstrap = $null
    lock_path = ''
  }

  $lockWritten = $false
  try {
    if ([bool]$AutoOnOpen -and -not (Get-RaymanEnvBool -Name 'RAYMAN_VSCODE_AUTO_UPGRADE_ENABLED' -Default $true)) {
      $result.status = 'auto_upgrade_disabled'
      $result.success = $true
      $result.skipped_reason = 'disabled_by_env'
      return [pscustomobject]$result
    }

    $state = Read-RaymanRegisteredBootstrapJsonOrNull -Path $resolvedStatePath
    if ($null -eq $state) {
      throw ("Rayman source registration not found: {0}. Please run `.\.Rayman\rayman.ps1 workspace-register` in RaymanAgent first." -f $resolvedStatePath)
    }

    $publishedVersion = if ($state.PSObject.Properties['published_version'] -and -not [string]::IsNullOrWhiteSpace([string]$state.published_version)) {
      [string]$state.published_version
    } elseif ($state.PSObject.Properties['rayman_version']) {
      [string]$state.rayman_version
    } else {
      ''
    }
    $publishedFingerprint = if ($state.PSObject.Properties['published_fingerprint']) { [string]$state.published_fingerprint } else { '' }
    if ([string]::IsNullOrWhiteSpace([string]$publishedFingerprint)) {
      throw 'Rayman source registration is missing a published fingerprint. Please run `.\.Rayman\rayman.ps1 workspace-register` in RaymanAgent again.'
    }

    $sourceWorkspacePath = Resolve-RaymanRegisteredBootstrapPath -Path ([string]$state.source_workspace_path)
    if ([string]::IsNullOrWhiteSpace([string]$sourceWorkspacePath) -or -not (Test-Path -LiteralPath $sourceWorkspacePath -PathType Container)) {
      throw ('Registered Rayman source workspace is unavailable: {0}. Please run `.\.Rayman\rayman.ps1 workspace-register` again.' -f [string]$state.source_workspace_path)
    }

    $result.source_workspace_path = $sourceWorkspacePath
    $result.published_version = $publishedVersion
    $result.published_fingerprint = $publishedFingerprint

    $normalizedSource = ([System.IO.Path]::GetFullPath($sourceWorkspacePath)).TrimEnd('\', '/').ToLowerInvariant()
    $normalizedTarget = ([System.IO.Path]::GetFullPath($resolvedTarget)).TrimEnd('\', '/').ToLowerInvariant()
    if ($normalizedSource -eq $normalizedTarget) {
      $result.status = 'source_workspace'
      $result.success = $true
      $result.skipped_reason = 'source_workspace'
      return [pscustomobject]$result
    }

    $sourceFingerprint = Get-RaymanDistributableFingerprint -WorkspaceRoot $sourceWorkspacePath
    $sourceVersion = Get-RaymanWorkspaceInstallVersion -WorkspaceRoot $sourceWorkspacePath
    if ([string]$sourceVersion -ne [string]$publishedVersion -or [string]$sourceFingerprint -ne [string]$publishedFingerprint) {
      throw 'The registered Rayman source snapshot no longer matches the published source workspace. Please run `.\.Rayman\rayman.ps1 workspace-register` in RaymanAgent again.'
    }

    $installedState = Get-RaymanWorkspaceInstallAppliedState -WorkspaceRoot $resolvedTarget
    $result.current_rayman_version = [string]$installedState.rayman_version
    $result.current_install_fingerprint = [string]$installedState.applied_published_fingerprint

    if ([bool]$AutoOnOpen -and -not [bool]$installedState.has_rayman) {
      $result.status = 'skipped_auto_without_rayman'
      $result.success = $true
      $result.skipped_reason = 'workspace_missing_rayman'
      return [pscustomobject]$result
    }

    $isCurrent = [bool]$installedState.has_rayman `
      -and ([string]$installedState.rayman_version -eq [string]$publishedVersion) `
      -and ([string]$installedState.applied_published_version -eq [string]$publishedVersion) `
      -and ([string]$installedState.applied_published_fingerprint -eq [string]$publishedFingerprint)
    if ($isCurrent) {
      $result.status = 'already_current'
      $result.success = $true
      $result.skipped_reason = 'already_current'
      return [pscustomobject]$result
    }

    $result.upgrade_needed = $true
    if ([bool]$AutoOnOpen -and [bool]$installedState.has_rayman) {
      Write-RaymanWorkspaceInstallAutoUpgradeLock `
        -WorkspaceRoot $resolvedTarget `
        -Mode 'auto_on_open' `
        -SourceWorkspaceRoot $sourceWorkspacePath `
        -PublishedVersion $publishedVersion `
        -PublishedFingerprint $publishedFingerprint | Out-Null
      $result.lock_path = Get-RaymanWorkspaceInstallAutoUpgradeLockPath -WorkspaceRoot $resolvedTarget
      $lockWritten = $true
    }

    $installOptions = Get-RaymanRegisteredBootstrapInstallOptions -InputArgs $CliArgs
    $noRemember = [bool]$installOptions.no_remember
    if ([bool]$AutoOnOpen) {
      $noRemember = $true
    }

    $installResult = Invoke-RaymanWorkspaceInstall `
      -WorkspaceRoot $sourceWorkspacePath `
      -TargetPath $resolvedTarget `
      -NoRemember:$noRemember `
      -SelfCheck:([bool]$installOptions.run_self_check) `
      -NoSelfCheck:(-not [bool]$installOptions.run_self_check)
    $result.install = $installResult
    if (-not [bool]$installResult.success) {
      $result.status = if ($installResult.PSObject.Properties['status']) { [string]$installResult.status } else { 'install_failed' }
      $result.error = if ($installResult.PSObject.Properties['error']) { [string]$installResult.error } else { 'workspace install failed' }
      return [pscustomobject]$result
    }

    if ([bool]$AutoOnOpen) {
      $bootstrapCapture = Invoke-RaymanRegisteredWorkspaceBootstrapRefresh -TargetWorkspaceRoot $resolvedTarget -VscodeOwnerPid ([string]$env:VSCODE_PID)
      $result.bootstrap = $bootstrapCapture
      if (-not [bool]$bootstrapCapture.success) {
        $result.status = 'bootstrap_failed'
        $result.error = if ($bootstrapCapture.PSObject.Properties['error'] -and -not [string]::IsNullOrWhiteSpace([string]$bootstrapCapture.error)) {
          [string]$bootstrapCapture.error
        } else {
          "vscode folder open bootstrap refresh failed (exit=$([int]$bootstrapCapture.exit_code))"
        }
        return [pscustomobject]$result
      }
    }

    $result.current_rayman_version = if ($installResult.PSObject.Properties['applied_published_version']) { [string]$installResult.applied_published_version } else { [string]$publishedVersion }
    $result.current_install_fingerprint = if ($installResult.PSObject.Properties['applied_published_fingerprint']) { [string]$installResult.applied_published_fingerprint } else { [string]$publishedFingerprint }
    $result.status = 'installed'
    $result.success = $true
    return [pscustomobject]$result
  } catch {
    $result.status = 'failed'
    $result.error = [string]$_.Exception.Message
    return [pscustomobject]$result
  } finally {
    if ($lockWritten) {
      Clear-RaymanWorkspaceInstallAutoUpgradeLock -WorkspaceRoot $resolvedTarget
    }
    if (Test-Path -LiteralPath (Join-Path $resolvedTarget '.Rayman') -PathType Container) {
      try {
        Write-RaymanWorkspaceInstallJsonFile -Path (Get-RaymanWorkspaceInstallAutoUpgradeLastPath -WorkspaceRoot $resolvedTarget) -Value ([pscustomobject]$result)
      } catch {}
    }
  }
}

function Write-RaymanRegisteredWorkspaceBootstrapOutput {
  param(
    [object]$Result,
    [switch]$Json
  )

  if ($Json) {
    $Result | ConvertTo-Json -Depth 16
    return
  }

  if (-not [bool]$Result.success) {
    if (-not [string]::IsNullOrWhiteSpace([string]$Result.error)) {
      Write-Error ([string]$Result.error)
    }
    return
  }

  switch ([string]$Result.status) {
    'already_current' {
      Write-Host ("当前工作区已是已登记 Rayman 快照，无需升级：{0}" -f [string]$Result.target_path)
      break
    }
    'skipped_auto_without_rayman' {
      Write-Host ("[rayman-here] auto-on-open 跳过未安装 Rayman 的工作区：{0}" -f [string]$Result.target_path)
      break
    }
    'source_workspace' {
      Write-Host ("当前已是 RaymanAgent source workspace，跳过自动升级：{0}" -f [string]$Result.target_path)
      break
    }
    'auto_upgrade_disabled' {
      Write-Host '[rayman-here] auto-upgrade 已被 RAYMAN_VSCODE_AUTO_UPGRADE_ENABLED=0 禁用。'
      break
    }
    'installed' {
      Write-Host ("已安装/升级 Rayman：{0}" -f [string]$Result.target_path)
      if ([bool]$Result.auto_on_open) {
        Write-Host '已补跑当前工作区的 Folder Open Bootstrap。'
      }
      break
    }
    default {
      Write-Host ("Rayman bootstrap 状态：{0}" -f [string]$Result.status)
      break
    }
  }
}

if (-not $NoMain) {
  $result = Invoke-RaymanRegisteredWorkspaceBootstrap -StatePath $StatePath -TargetPath $TargetPath -CliArgs $CliArgs -AutoOnOpen:$AutoOnOpen
  if (-not [bool]$result.success) {
    $global:LASTEXITCODE = 1
  }

  Write-RaymanRegisteredWorkspaceBootstrapOutput -Result $result -Json:$Json
  exit $(if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 })
}
