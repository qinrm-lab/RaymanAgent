param(
  [string]$WorkspaceRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path,
  [Parameter(Position = 0)][string]$Action = 'status',
  [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$CliArgs,
  [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$savedWorkerCliState = @{
  WorkspaceRoot = $WorkspaceRoot
  Action = $Action
  CliArgs = @($CliArgs)
  NoMain = [bool]$NoMain
}

. (Join-Path $PSScriptRoot 'worker_common.ps1')
. (Join-Path $PSScriptRoot 'worker_sync.ps1') -NoMain
. (Join-Path $PSScriptRoot 'worker_upgrade.ps1') -NoMain
$runtimeCleanupScript = Join-Path $PSScriptRoot '..\utils\runtime_cleanup.ps1'
if (Test-Path -LiteralPath $runtimeCleanupScript -PathType Leaf) {
  . $runtimeCleanupScript -NoMain
}

$WorkspaceRoot = [string]$savedWorkerCliState.WorkspaceRoot
$Action = [string]$savedWorkerCliState.Action
$CliArgs = @($savedWorkerCliState.CliArgs)
$NoMain = [bool]$savedWorkerCliState.NoMain

function Split-RaymanWorkerCommandTail {
  param([string[]]$Arguments)

  $before = New-Object System.Collections.Generic.List[string]
  $after = New-Object System.Collections.Generic.List[string]
  $seenSeparator = $false
  foreach ($arg in @($Arguments)) {
    if (-not $seenSeparator -and [string]$arg -eq '--') {
      $seenSeparator = $true
      continue
    }
    if ($seenSeparator) {
      $after.Add([string]$arg) | Out-Null
    } else {
      $before.Add([string]$arg) | Out-Null
    }
  }

  return [pscustomobject]@{
    options = @($before.ToArray())
    remainder = @($after.ToArray())
  }
}

function Resolve-RaymanWorkerSelection {
  param(
    [string]$WorkspaceRoot,
    [string]$WorkerId,
    [string]$WorkerName,
    [switch]$AllowActive
  )

  $worker = Resolve-RaymanWorkerBySelector -WorkspaceRoot $WorkspaceRoot -WorkerId $WorkerId -WorkerName $WorkerName -AllowActive:$AllowActive
  if ($null -eq $worker) {
    $registryWorkers = @(Get-RaymanSelectableRegistryWorkers -WorkspaceRoot $WorkspaceRoot)
    if ($registryWorkers.Count -eq 1 -and [string]::IsNullOrWhiteSpace([string]$WorkerId) -and [string]::IsNullOrWhiteSpace([string]$WorkerName)) {
      return $registryWorkers[0]
    }
    throw 'worker not found; run `rayman.ps1 worker discover` first.'
  }
  return $worker
}

function Assert-RaymanWorkerActionAllowed {
  param(
    [string]$WorkspaceRoot,
    [string]$Action,
    [object]$Worker = $null,
    [switch]$LocalOnly
  )

  if (Get-RaymanWorkerAllowProtectedLocal -WorkspaceRoot $WorkspaceRoot) {
    return
  }

  if ($LocalOnly -and (Test-RaymanWorkerProtectedDevMachine -WorkspaceRoot $WorkspaceRoot)) {
    throw ('worker {0} is blocked on protected dev machine {1}; set RAYMAN_WORKER_ALLOW_PROTECTED_LOCAL=1 only for an explicit local-worker operation.' -f $Action, (Get-RaymanWorkerMachineName))
  }

  if ($null -ne $Worker -and (Test-RaymanWorkerProtectedLocalCandidate -WorkspaceRoot $WorkspaceRoot -Worker $Worker)) {
    throw ('worker {0} is blocked for protected local worker {1}; remote-first policy keeps the dev machine safe unless you explicitly opt in with RAYMAN_WORKER_ALLOW_PROTECTED_LOCAL=1.' -f $Action, [string]$Worker.worker_name)
  }
}

function Ensure-RaymanSelectedWorkerIsActive {
  param(
    [string]$WorkspaceRoot,
    [object]$Worker,
    [string]$WorkspaceMode = 'attached'
  )

  $active = Get-RaymanActiveWorkerRecord -WorkspaceRoot $WorkspaceRoot
  if ($null -ne $active -and [string]$active.worker_id -eq [string]$Worker.worker_id) {
    return $active
  }

  return (Set-RaymanActiveWorkerRecord -WorkspaceRoot $WorkspaceRoot -Worker $Worker -WorkspaceMode $WorkspaceMode -SyncManifest $null -ClientContext (Get-RaymanWorkerClientContext -WorkspaceRoot $WorkspaceRoot))
}

function Format-RaymanWorkerCommandText {
  param([string[]]$CommandParts)

  $tokens = @($CommandParts | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
  if ($tokens.Count -eq 0) {
    return ''
  }
  if ($tokens.Count -eq 1) {
    $single = [string]$tokens[0]
    if ($single -match '[\|\;\(\)\$]') {
      return $single
    }
  }

  $rendered = New-Object System.Collections.Generic.List[string]
  $safeTokenPattern = '^[A-Za-z0-9_\-./:\\=]+$'
  $rendered.Add('&') | Out-Null
  foreach ($token in @($tokens)) {
    if ([string]::IsNullOrEmpty([string]$token)) {
      $rendered.Add("''") | Out-Null
    } elseif ($token -match $safeTokenPattern) {
      $rendered.Add($token) | Out-Null
    } else {
      $rendered.Add(("'{0}'" -f ($token -replace "'", "''"))) | Out-Null
    }
  }
  return (($rendered.ToArray()) -join ' ')
}

function Get-RaymanWorkerScheduledTaskArguments {
  param(
    [string]$WorkerHostScript,
    [string]$WorkspaceRoot
  )

  $commandText = ("& '{0}' -WorkspaceRoot '{1}'" -f $WorkerHostScript.Replace("'", "''"), $WorkspaceRoot.Replace("'", "''"))
  $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($commandText))
  return ('-NoProfile -ExecutionPolicy Bypass -EncodedCommand {0}' -f $encoded)
}

function New-RaymanWorkerScheduledTaskAction {
  param(
    [string]$Execute,
    [string]$Argument
  )

  return (New-ScheduledTaskAction -Execute $Execute -Argument $Argument)
}

function New-RaymanWorkerScheduledTaskTrigger {
  param([string]$UserName)

  return (New-ScheduledTaskTrigger -AtLogOn -User $UserName)
}

function New-RaymanWorkerScheduledTaskSettings {
  return (New-ScheduledTaskSettingsSet `
      -AllowStartIfOnBatteries `
      -DontStopIfGoingOnBatteries `
      -StartWhenAvailable `
      -MultipleInstances IgnoreNew `
      -RestartCount 999 `
      -RestartInterval ([TimeSpan]::FromMinutes(1)) `
      -ExecutionTimeLimit ([TimeSpan]::Zero))
}

function Register-RaymanWorkerScheduledTask {
  param(
    [string]$TaskPath,
    [string]$TaskName,
    [object]$Action,
    [object]$Trigger,
    [object]$Settings
  )

  Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Description 'Rayman Worker login autostart' -Force | Out-Null
}

function Start-RaymanWorkerScheduledTask {
  param(
    [string]$TaskPath,
    [string]$TaskName
  )

  Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
}

function New-RaymanWorkerCliErrorResult {
  param(
    [string]$Action,
    [System.Management.Automation.ErrorRecord]$ErrorRecord
  )

  $payload = [ordered]@{
    schema = 'rayman.worker.cli_error.v1'
    generated_at = (Get-Date).ToString('o')
    action = [string]$Action
    error = [string]$ErrorRecord.Exception.Message
  }
  if ($null -ne $ErrorRecord.Exception -and $null -ne $ErrorRecord.Exception.Data -and $ErrorRecord.Exception.Data.Contains('rayman_payload')) {
    $payload['remote_error'] = $ErrorRecord.Exception.Data['rayman_payload']
  }
  return [pscustomobject]$payload
}

function Install-RaymanLocalWorker {
  param([string]$WorkspaceRoot)

  Assert-RaymanWorkerActionAllowed -WorkspaceRoot $WorkspaceRoot -Action 'install-local' -LocalOnly

  if (-not (Test-RaymanWorkerWindowsHost)) {
    throw 'worker install-local requires Windows.'
  }

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $workerHostScript = Join-Path $resolvedRoot '.Rayman\scripts\worker\worker_host.ps1'
  if (-not (Test-Path -LiteralPath $workerHostScript -PathType Leaf)) {
    throw ("worker host script missing: {0}" -f $workerHostScript)
  }

  $psHost = if (Get-Command Resolve-RaymanPowerShellHost -ErrorAction SilentlyContinue) {
    Resolve-RaymanPowerShellHost
  } else {
    'powershell.exe'
  }

  $taskPath = Get-RaymanWorkerTaskPath -WorkspaceRoot $resolvedRoot
  $taskName = 'Rayman Worker'
  $userName = Get-RaymanWorkerCurrentUser
  $actionArguments = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $workerHostScript,
    '-WorkspaceRoot',
    $resolvedRoot
  )

  $taskAction = New-RaymanWorkerScheduledTaskAction -Execute $psHost -Argument (Get-RaymanWorkerScheduledTaskArguments -WorkerHostScript $workerHostScript -WorkspaceRoot $resolvedRoot)
  $taskTrigger = New-RaymanWorkerScheduledTaskTrigger -UserName $userName
  $taskSettings = New-RaymanWorkerScheduledTaskSettings
  Register-RaymanWorkerScheduledTask -TaskPath $taskPath -TaskName $taskName -Action $taskAction -Trigger $taskTrigger -Settings $taskSettings

  Set-RaymanWorkerAttachedSyncManifest -WorkspaceRoot $resolvedRoot | Out-Null
  $vsdbgStatus = Ensure-RaymanWorkerVsdbg -WorkspaceRoot $resolvedRoot
  $firewallStatus = Ensure-RaymanWorkerFirewallRules -WorkspaceRoot $resolvedRoot
  $startMethod = 'scheduled_task'
  try {
    Start-RaymanWorkerScheduledTask -TaskPath $taskPath -TaskName $taskName
  } catch {
    $startMethod = 'process_fallback'
    Start-Process -FilePath $psHost -ArgumentList $actionArguments -WindowStyle Hidden | Out-Null
  }
  Start-Sleep -Milliseconds 800

  return [pscustomobject]@{
    schema = 'rayman.worker.install.result.v1'
    generated_at = (Get-Date).ToString('o')
    worker_id = (Get-RaymanWorkerStableId -WorkspaceRoot $resolvedRoot)
    worker_name = (Get-RaymanWorkerDisplayName -WorkspaceRoot $resolvedRoot)
    workspace_root = $resolvedRoot
    task_path = $taskPath
    task_name = $taskName
    power_shell_host = $psHost
    start_method = $startMethod
    debugger_ready = [bool]$vsdbgStatus.debugger_ready
    debugger_path = [string]$vsdbgStatus.debugger_path
    debugger_error = if ($vsdbgStatus.PSObject.Properties['debugger_error']) { [string]$vsdbgStatus.debugger_error } else { '' }
    firewall_ready = [bool]$firewallStatus.firewall_ready
    firewall_error = if ($firewallStatus.PSObject.Properties['firewall_error']) { [string]$firewallStatus.firewall_error } else { '' }
    firewall = $firewallStatus
  }
}

function Uninstall-RaymanLocalWorker {
  param([string]$WorkspaceRoot)

  Assert-RaymanWorkerActionAllowed -WorkspaceRoot $WorkspaceRoot -Action 'uninstall-local' -LocalOnly

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $taskPath = Get-RaymanWorkerTaskPath -WorkspaceRoot $resolvedRoot
  $taskName = 'Rayman Worker'
  try {
    Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
  } catch {}

  $status = Read-RaymanWorkerJsonFile -Path (Get-RaymanWorkerHostStatusPath -WorkspaceRoot $resolvedRoot)
  if ($null -ne $status -and $status.PSObject.Properties['process_id']) {
    try { Stop-Process -Id ([int]$status.process_id) -Force -ErrorAction SilentlyContinue } catch {}
  }

  $removedFirewallRules = 0
  try {
    $removedFirewallRules = [int](Remove-RaymanWorkerFirewallRules -WorkspaceRoot $resolvedRoot)
  } catch {}

  return [pscustomobject]@{
    schema = 'rayman.worker.uninstall.result.v1'
    generated_at = (Get-Date).ToString('o')
    workspace_root = $resolvedRoot
    task_path = $taskPath
    task_name = $taskName
    firewall_rules_removed = $removedFirewallRules
  }
}

function Test-RaymanWorkerInteractiveConsoleAvailable {
  try {
    return (-not [Console]::IsInputRedirected)
  } catch {
    return $true
  }
}

function Resolve-RaymanWorkerExportPath {
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

function Get-RaymanWorkerExportDefaultsDocument {
  param([string]$WorkspaceRoot)

  $path = Get-RaymanWorkerExportDefaultsPath -WorkspaceRoot $WorkspaceRoot
  $existing = Read-RaymanWorkerJsonFile -Path $path
  if ($null -ne $existing) {
    return $existing
  }

  return [pscustomobject]@{
    schema = 'rayman.worker.export.defaults.v1'
    target_path = ''
    last_export_at = ''
  }
}

function Save-RaymanWorkerExportDefaultsDocument {
  param(
    [string]$WorkspaceRoot,
    [string]$TargetPath
  )

  $payload = [pscustomobject]@{
    schema = 'rayman.worker.export.defaults.v1'
    target_path = [string]$TargetPath
    last_export_at = (Get-Date).ToString('o')
  }
  Write-RaymanWorkerJsonFile -Path (Get-RaymanWorkerExportDefaultsPath -WorkspaceRoot $WorkspaceRoot) -Value $payload
  return $payload
}

function Resolve-RaymanWorkerExportTargetPath {
  param(
    [string]$WorkspaceRoot,
    [string]$RequestedTarget = ''
  )

  if (-not [string]::IsNullOrWhiteSpace([string]$RequestedTarget)) {
    return (Resolve-RaymanWorkerExportPath -Path $RequestedTarget)
  }

  $defaults = Get-RaymanWorkerExportDefaultsDocument -WorkspaceRoot $WorkspaceRoot
  $rememberedTarget = if ($defaults.PSObject.Properties['target_path']) { [string]$defaults.target_path } else { '' }

  if (-not (Test-RaymanWorkerInteractiveConsoleAvailable)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rememberedTarget)) {
      return (Resolve-RaymanWorkerExportPath -Path $rememberedTarget)
    }
    throw 'worker export-package requires --target when stdin is redirected.'
  }

  if (-not [string]::IsNullOrWhiteSpace([string]$rememberedTarget)) {
    $prompt = ("导出目标目录（回车复用：{0}）" -f $rememberedTarget)
    $input = [string](Read-Host $prompt)
    if ([string]::IsNullOrWhiteSpace([string]$input)) {
      return (Resolve-RaymanWorkerExportPath -Path $rememberedTarget)
    }
    return (Resolve-RaymanWorkerExportPath -Path $input)
  }

  $input = [string](Read-Host '请输入工作机最小包导出目录')
  if ([string]::IsNullOrWhiteSpace([string]$input)) {
    throw 'worker export-package requires a target path.'
  }
  return (Resolve-RaymanWorkerExportPath -Path $input)
}

function Remove-RaymanWorkerExportManagedPath {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }
  Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
}

function Move-RaymanWorkerExportManagedPath {
  param(
    [string]$SourcePath,
    [string]$DestinationPath
  )

  if (-not (Test-Path -LiteralPath $SourcePath)) {
    return
  }
  Move-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
}

function Restore-RaymanWorkerExportManagedPath {
  param(
    [string]$TargetPath,
    [string]$BackupPath
  )

  if (-not (Test-Path -LiteralPath $BackupPath)) {
    return
  }

  if (Test-Path -LiteralPath $TargetPath) {
    Remove-RaymanWorkerExportManagedPath -Path $TargetPath
  }
  Move-Item -LiteralPath $BackupPath -Destination $TargetPath -Force
}

function Get-RaymanWorkerExportEnvContent {
  param([string]$AuthToken)

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('$env:RAYMAN_WORKER_LAN_ENABLED = ''1''') | Out-Null

  if (-not [string]::IsNullOrWhiteSpace([string]$AuthToken)) {
    $safeToken = ([string]$AuthToken).Replace("'", "''")
    $lines.Add(('$env:RAYMAN_WORKER_AUTH_TOKEN = ''{0}''' -f $safeToken)) | Out-Null
  }

  $lines.Add('') | Out-Null
  return (@($lines.ToArray()) -join [Environment]::NewLine)
}

function Get-RaymanWorkerExportRootAssetFileNames {
  return @(
    'all.ps1',
    'all.bat',
    'collect-worker-diag.ps1',
    'collect-worker-diag.bat',
    'repair-worker-encoding.ps1',
    'repair-worker-encoding.bat'
  )
}

function Get-RaymanWorkerExportCopiedItemNames {
  return @(
    '.Rayman',
    '.rayman.env.ps1',
    'INSTALL-WORKER.txt',
    'download'
  ) + @(Get-RaymanWorkerExportRootAssetFileNames)
}

function Get-RaymanWorkerExportTemplateRoot {
  param([string]$RaymanRoot)

  return (Join-Path $RaymanRoot 'templates\worker-package-root')
}

function Get-RaymanWorkerExportRootAssetSpecs {
  param([string]$RaymanRoot)

  $templateRoot = Get-RaymanWorkerExportTemplateRoot -RaymanRoot $RaymanRoot
  if (-not (Test-Path -LiteralPath $templateRoot -PathType Container)) {
    throw ("worker export templates missing: {0}" -f $templateRoot)
  }

  $specs = New-Object System.Collections.Generic.List[object]
  foreach ($fileName in @(Get-RaymanWorkerExportRootAssetFileNames)) {
    $sourcePath = Join-Path $templateRoot $fileName
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
      throw ("worker export template missing: {0}" -f $sourcePath)
    }

    $specs.Add([pscustomobject]@{
        item_name = $fileName
        source_path = $sourcePath
      }) | Out-Null
  }

  return @($specs.ToArray())
}

function Get-RaymanWorkerExportDownloadTemplateRoot {
  param([string]$RaymanRoot)

  return (Join-Path (Get-RaymanWorkerExportTemplateRoot -RaymanRoot $RaymanRoot) 'download')
}

function Get-RaymanWorkerExportCacheRoot {
  param([string]$WorkspaceRoot)

  $path = Join-Path $WorkspaceRoot '.Rayman\state\worker-package-cache'
  Ensure-RaymanWorkerDirectory -Path $path
  return $path
}

function Get-RaymanWorkerExportVsdbgCacheRoot {
  param([string]$WorkspaceRoot)

  return (Join-Path (Get-RaymanWorkerExportCacheRoot -WorkspaceRoot $WorkspaceRoot) 'vsdbg')
}

function Get-RaymanWorkerExportPowerShell7CacheRoot {
  param([string]$WorkspaceRoot)

  return (Join-Path (Get-RaymanWorkerExportCacheRoot -WorkspaceRoot $WorkspaceRoot) 'powershell7')
}

function Get-RaymanWorkerPowerShell7ManifestPath {
  param([string]$WorkspaceRoot)

  return (Join-Path (Get-RaymanWorkerExportPowerShell7CacheRoot -WorkspaceRoot $WorkspaceRoot) 'manifest.json')
}

function Test-RaymanWorkerExportPowerShell7PayloadPresent {
  param([string]$Root)

  if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    return $false
  }

  $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
      $_.Name -notin @('README.txt', '.gitkeep', 'manifest.json')
    })
  return ($files.Count -gt 0)
}

function Resolve-RaymanWorkerWingetPath {
  $command = Get-Command 'winget' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
    return [string]$command.Source
  }
  return ''
}

function Get-RaymanWorkerPowerShell7InstallerFile {
  param([string]$Root)

  if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    return $null
  }

  return (Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
      $_.Name -match '^PowerShell[-_][0-9]+(\.[0-9]+){2,3}.*win[-_]x64.*\.msi$'
    } | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}

function Invoke-RaymanWorkerPowerShell7Download {
  param([string]$DestinationRoot)

  $wingetPath = Resolve-RaymanWorkerWingetPath
  if ([string]::IsNullOrWhiteSpace([string]$wingetPath)) {
    throw 'winget is not available to download the latest PowerShell 7 installer.'
  }

  Ensure-RaymanWorkerDirectory -Path $DestinationRoot
  $capture = Invoke-RaymanNativeCommandCapture -FilePath $wingetPath -ArgumentList @(
      'download',
      '--id',
      'Microsoft.PowerShell',
      '--source',
      'winget',
      '--accept-source-agreements',
      '--download-directory',
      $DestinationRoot
    ) -WorkingDirectory $DestinationRoot

  if (-not [bool]$capture.started) {
    throw 'failed to launch winget download for Microsoft.PowerShell.'
  }
  if ([int]$capture.exit_code -ne 0) {
    $tail = @($capture.stdout + $capture.stderr | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 5)
    $suffix = if ($tail.Count -gt 0) { ': ' + ($tail -join ' | ') } else { '' }
    throw ("winget download failed with exit code {0}{1}" -f [int]$capture.exit_code, $suffix)
  }

  $installer = Get-RaymanWorkerPowerShell7InstallerFile -Root $DestinationRoot
  if ($null -eq $installer) {
    throw 'winget download completed but no PowerShell 7 x64 MSI was found in the destination directory.'
  }

  $version = ''
  if ([string]$installer.Name -match '^PowerShell[-_](?<version>[0-9]+(\.[0-9]+){2,3}).*win[-_]x64.*\.msi$') {
    $version = [string]$Matches['version']
  }

  return [pscustomobject]@{
    installer_path = [string]$installer.FullName
    installer_name = [string]$installer.Name
    version = $version
    downloaded_at = (Get-Date).ToString('o')
    source = 'winget'
    package_id = 'Microsoft.PowerShell'
  }
}

function Sync-RaymanWorkerPowerShell7Cache {
  param([string]$WorkspaceRoot)

  $resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $cacheRoot = Get-RaymanWorkerExportPowerShell7CacheRoot -WorkspaceRoot $resolvedWorkspaceRoot
  Ensure-RaymanWorkerDirectory -Path $cacheRoot
  $manifestPath = Get-RaymanWorkerPowerShell7ManifestPath -WorkspaceRoot $resolvedWorkspaceRoot
  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman-powershell7-cache-' + [Guid]::NewGuid().ToString('n'))
  Ensure-RaymanWorkerDirectory -Path $tempRoot

  try {
    $download = Invoke-RaymanWorkerPowerShell7Download -DestinationRoot $tempRoot

    foreach ($existing in @(Get-ChildItem -LiteralPath $cacheRoot -Force -ErrorAction SilentlyContinue)) {
      if ($existing.Name -in @('README.txt', '.gitkeep', 'manifest.json')) {
        continue
      }
      Remove-Item -LiteralPath $existing.FullName -Recurse -Force -ErrorAction Stop
    }

    $destinationInstallerPath = Join-Path $cacheRoot ([string]$download.installer_name)
    Copy-Item -LiteralPath ([string]$download.installer_path) -Destination $destinationInstallerPath -Force

    $manifest = [pscustomobject]@{
      schema = 'rayman.worker.powershell7.cache.v1'
      generated_at = (Get-Date).ToString('o')
      version = [string]$download.version
      installer_name = [string]$download.installer_name
      installer_path = $destinationInstallerPath
      source = [string]$download.source
      package_id = [string]$download.package_id
      downloaded_at = [string]$download.downloaded_at
    }
    Write-RaymanWorkerJsonFile -Path $manifestPath -Value $manifest

    return [pscustomobject]@{
      refreshed = $true
      installer_present = $true
      installer_path = $destinationInstallerPath
      installer_name = [string]$download.installer_name
      version = [string]$download.version
      manifest_path = $manifestPath
    }
  } catch {
    $existingInstaller = Get-RaymanWorkerPowerShell7InstallerFile -Root $cacheRoot
    $existingManifest = Read-RaymanWorkerJsonFile -Path $manifestPath
    return [pscustomobject]@{
      refreshed = $false
      installer_present = ($null -ne $existingInstaller)
      installer_path = if ($null -ne $existingInstaller) { [string]$existingInstaller.FullName } else { '' }
      installer_name = if ($null -ne $existingInstaller) { [string]$existingInstaller.Name } else { '' }
      version = if ($null -ne $existingManifest -and $existingManifest.PSObject.Properties['version']) { [string]$existingManifest.version } else { '' }
      manifest_path = $manifestPath
      error = [string]$_.Exception.Message
    }
  } finally {
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

function New-RaymanWorkerExportDownloadDirectory {
  param(
    [string]$WorkspaceRoot,
    [string]$RaymanRoot,
    [string]$PreparedRoot
  )

  $downloadTemplateRoot = Get-RaymanWorkerExportDownloadTemplateRoot -RaymanRoot $RaymanRoot
  if (-not (Test-Path -LiteralPath $downloadTemplateRoot -PathType Container)) {
    throw ("worker export download templates missing: {0}" -f $downloadTemplateRoot)
  }

  if (Test-Path -LiteralPath $PreparedRoot) {
    Remove-Item -LiteralPath $PreparedRoot -Recurse -Force -ErrorAction Stop
  }
  Ensure-RaymanWorkerDirectory -Path $PreparedRoot
  Copy-RaymanWorkerUpgradeContent -SourceRoot $downloadTemplateRoot -DestinationRoot $PreparedRoot

  $vsdbgCacheRoot = Get-RaymanWorkerExportVsdbgCacheRoot -WorkspaceRoot $WorkspaceRoot
  $vsdbgTargetRoot = Join-Path $PreparedRoot 'vsdbg'
  $vsdbgIncluded = $false
  if (Test-Path -LiteralPath (Join-Path $vsdbgCacheRoot 'vsdbg.exe') -PathType Leaf) {
    Ensure-RaymanWorkerDirectory -Path $vsdbgTargetRoot
    Copy-RaymanWorkerUpgradeContent -SourceRoot $vsdbgCacheRoot -DestinationRoot $vsdbgTargetRoot
    $vsdbgIncluded = (Test-Path -LiteralPath (Join-Path $vsdbgTargetRoot 'vsdbg.exe') -PathType Leaf)
  }

  $powershell7CacheRoot = Get-RaymanWorkerExportPowerShell7CacheRoot -WorkspaceRoot $WorkspaceRoot
  $powershell7TargetRoot = Join-Path $PreparedRoot 'powershell7'
  $powershell7Included = $false
  $powershell7Status = Sync-RaymanWorkerPowerShell7Cache -WorkspaceRoot $WorkspaceRoot
  if (Test-RaymanWorkerExportPowerShell7PayloadPresent -Root $powershell7CacheRoot) {
    Ensure-RaymanWorkerDirectory -Path $powershell7TargetRoot
    Copy-RaymanWorkerUpgradeContent -SourceRoot $powershell7CacheRoot -DestinationRoot $powershell7TargetRoot
    $powershell7Included = (Test-RaymanWorkerExportPowerShell7PayloadPresent -Root $powershell7TargetRoot)
  }

  return [pscustomobject]@{
    source_path = $PreparedRoot
    vsdbg_included = [bool]$vsdbgIncluded
    powershell7_included = [bool]$powershell7Included
    powershell7_status = $powershell7Status
  }
}

function Get-RaymanWorkerExportInstallInstructions {
  return @(
    'Copy this entire directory as-is to the work machine workspace root.',
    'Do not cherry-pick files from it.',
    '',
    'Open the copied directory on the work machine inside an interactive Windows login session.',
    'This package does not copy any AI token; RAYMAN_WORKER_AUTH_TOKEN is only an optional worker control secret.',
    'If you enable LAN mode, prefer an elevated PowerShell session for the first install so Rayman can auto-configure inbound firewall access.',
    'If download\vsdbg is present, Rayman will prefer that local debugger payload before attempting any online download.',
    'If download\powershell7 contains a PowerShell 7 x64 installer, keep it as an offline repair option; the export step will refresh it to the latest stable package when possible.',
    '',
    'Preferred one-click run:',
    '.\all.bat',
    '',
    'Manual fallback:',
    'powershell.exe -ExecutionPolicy Bypass -File .\.Rayman\rayman.ps1 worker install-local',
    ''
  ) -join [Environment]::NewLine
}

function Invoke-RaymanWorkerExportPackage {
  param(
    [string]$WorkspaceRoot,
    [string]$TargetPath = '',
    [switch]$NoRemember
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $token = [string](Get-RaymanWorkerAuthToken -WorkspaceRoot $resolvedRoot)

  $resolvedTarget = Resolve-RaymanWorkerExportTargetPath -WorkspaceRoot $resolvedRoot -RequestedTarget $TargetPath
  if ([string]::IsNullOrWhiteSpace([string]$resolvedTarget)) {
    throw 'worker export-package requires a target path.'
  }

  $operationId = [Guid]::NewGuid().ToString('n')
  $package = $null
  $extractRoot = ''
  $preparedDownload = $null
  $completed = $false
  $managedItems = New-Object System.Collections.Generic.List[object]

  try {
    Ensure-RaymanWorkerDirectory -Path $resolvedTarget
    $package = New-RaymanWorkerUpgradePackage -WorkspaceRoot $resolvedRoot
    $extractRoot = Join-Path (Split-Path -Parent ([string]$package.package_path)) ('export-{0}' -f $operationId)
    Ensure-RaymanWorkerDirectory -Path $extractRoot
    Expand-Archive -LiteralPath ([string]$package.package_path) -DestinationPath $extractRoot -Force
    $rootAssetSpecs = @(Get-RaymanWorkerExportRootAssetSpecs -RaymanRoot $extractRoot)
    $preparedDownload = New-RaymanWorkerExportDownloadDirectory -WorkspaceRoot $resolvedRoot -RaymanRoot $extractRoot -PreparedRoot (Join-Path $extractRoot '__worker-download')

    $managedItems.Add([pscustomobject]@{
          item_name = '.Rayman'
          kind = 'directory'
          target_path = (Join-Path $resolvedTarget '.Rayman')
          staged_path = (Join-Path $resolvedTarget ('.Rayman.__rayman_export_new_{0}' -f $operationId))
          backup_path = (Join-Path $resolvedTarget ('.Rayman.__rayman_export_old_{0}' -f $operationId))
          source_path = $extractRoot
        }) | Out-Null
    $managedItems.Add([pscustomobject]@{
          item_name = '.rayman.env.ps1'
          kind = 'generated'
          target_path = (Join-Path $resolvedTarget '.rayman.env.ps1')
          staged_path = (Join-Path $resolvedTarget ('.rayman.env.ps1.__rayman_export_new_{0}' -f $operationId))
          backup_path = (Join-Path $resolvedTarget ('.rayman.env.ps1.__rayman_export_old_{0}' -f $operationId))
          content = (Get-RaymanWorkerExportEnvContent -AuthToken $token)
        }) | Out-Null
    $managedItems.Add([pscustomobject]@{
          item_name = 'INSTALL-WORKER.txt'
          kind = 'generated'
          target_path = (Join-Path $resolvedTarget 'INSTALL-WORKER.txt')
          staged_path = (Join-Path $resolvedTarget ('INSTALL-WORKER.txt.__rayman_export_new_{0}' -f $operationId))
          backup_path = (Join-Path $resolvedTarget ('INSTALL-WORKER.txt.__rayman_export_old_{0}' -f $operationId))
          content = (Get-RaymanWorkerExportInstallInstructions)
        }) | Out-Null
    $managedItems.Add([pscustomobject]@{
          item_name = 'download'
          kind = 'directory'
          target_path = (Join-Path $resolvedTarget 'download')
          staged_path = (Join-Path $resolvedTarget ('download.__rayman_export_new_{0}' -f $operationId))
          backup_path = (Join-Path $resolvedTarget ('download.__rayman_export_old_{0}' -f $operationId))
          source_path = [string]$preparedDownload.source_path
        }) | Out-Null
    foreach ($asset in @($rootAssetSpecs)) {
      $managedItems.Add([pscustomobject]@{
            item_name = [string]$asset.item_name
            kind = 'file'
            target_path = (Join-Path $resolvedTarget ([string]$asset.item_name))
            staged_path = (Join-Path $resolvedTarget ('{0}.__rayman_export_new_{1}' -f [string]$asset.item_name, $operationId))
            backup_path = (Join-Path $resolvedTarget ('{0}.__rayman_export_old_{1}' -f [string]$asset.item_name, $operationId))
            source_path = [string]$asset.source_path
          }) | Out-Null
    }

    foreach ($item in @($managedItems.ToArray())) {
      switch ([string]$item.kind) {
        'directory' {
          Ensure-RaymanWorkerDirectory -Path ([string]$item.staged_path)
          Copy-Item -Path (Join-Path ([string]$item.source_path) '*') -Destination ([string]$item.staged_path) -Recurse -Force
        }
        'generated' {
          Write-RaymanWorkerUtf8NoBom -Path ([string]$item.staged_path) -Content ([string]$item.content)
        }
        'file' {
          Copy-Item -LiteralPath ([string]$item.source_path) -Destination ([string]$item.staged_path) -Force
        }
      }
    }

    foreach ($item in @($managedItems.ToArray())) {
      Move-RaymanWorkerExportManagedPath -SourcePath ([string]$item.target_path) -DestinationPath ([string]$item.backup_path)
    }

    foreach ($item in @($managedItems.ToArray())) {
      Move-Item -LiteralPath ([string]$item.staged_path) -Destination ([string]$item.target_path) -Force
    }

    if (-not $NoRemember) {
      Save-RaymanWorkerExportDefaultsDocument -WorkspaceRoot $resolvedRoot -TargetPath $resolvedTarget | Out-Null
    }

    $result = [pscustomobject]@{
      schema = 'rayman.worker.export.result.v1'
      generated_at = (Get-Date).ToString('o')
      workspace_root = $resolvedRoot
      target_path = $resolvedTarget
      rayman_version = (Get-RaymanWorkerVersion -WorkspaceRoot $resolvedRoot)
      copied_items = @(Get-RaymanWorkerExportCopiedItemNames)
      env_path = (Join-Path $resolvedTarget '.rayman.env.ps1')
      install_path = (Join-Path $resolvedTarget 'INSTALL-WORKER.txt')
      vsdbg_included = if ($null -ne $preparedDownload) { [bool]$preparedDownload.vsdbg_included } else { $false }
      powershell7_included = if ($null -ne $preparedDownload) { [bool]$preparedDownload.powershell7_included } else { $false }
      remembered_target = (-not $NoRemember)
    }
    Write-RaymanWorkerJsonFile -Path (Get-RaymanWorkerExportLastPath -WorkspaceRoot $resolvedRoot) -Value $result
    $completed = $true
    return $result
  } catch {
    foreach ($path in @($managedItems | ForEach-Object { [string]$_.staged_path })) {
      try { Remove-RaymanWorkerExportManagedPath -Path $path } catch {}
    }
    $restoreEntries = @($managedItems | ForEach-Object {
        @{
          target = [string]$_.target_path
          backup = [string]$_.backup_path
        }
      })
    [array]::Reverse($restoreEntries)
    foreach ($restore in @($restoreEntries)) {
      try {
        Restore-RaymanWorkerExportManagedPath -TargetPath ([string]$restore.target) -BackupPath ([string]$restore.backup)
      } catch {}
    }
    throw
  } finally {
    if ($completed) {
      foreach ($path in @($managedItems | ForEach-Object { [string]$_.backup_path })) {
        try { Remove-RaymanWorkerExportManagedPath -Path $path } catch {}
      }
    }
    foreach ($path in @($managedItems | ForEach-Object { [string]$_.staged_path }) + @($extractRoot)) {
      if (-not [string]::IsNullOrWhiteSpace([string]$path)) {
        try { Remove-RaymanWorkerExportManagedPath -Path $path } catch {}
      }
    }
    if ($null -ne $package -and $package.PSObject.Properties['package_path']) {
      try { Remove-RaymanWorkerExportManagedPath -Path ([string]$package.package_path) } catch {}
    }
  }
}

function Discover-RaymanWorkers {
  param(
    [string]$WorkspaceRoot,
    [int]$ListenSeconds
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $port = Get-RaymanWorkerDiscoveryPort
  $udp = New-Object System.Net.Sockets.UdpClient
  $udp.Client.ExclusiveAddressUse = $false
  $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
  $udp.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $port))

  $workers = New-Object System.Collections.Generic.List[object]
  $deadline = (Get-Date).AddSeconds($ListenSeconds)
  try {
    while ((Get-Date) -lt $deadline) {
      if ($udp.Available -le 0) {
        Start-Sleep -Milliseconds 200
        continue
      }
      $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
      $bytes = $udp.Receive([ref]$remote)
      $text = [System.Text.Encoding]::UTF8.GetString($bytes)
      try {
        $payload = $text | ConvertFrom-Json -ErrorAction Stop
      } catch {
        continue
      }
      if ([string]$payload.schema -ne 'rayman.worker.beacon.v1') { continue }
      if (-not $payload.PSObject.Properties['address'] -or [string]::IsNullOrWhiteSpace([string]$payload.address)) {
        $payload | Add-Member -MemberType NoteProperty -Name address -Value ([string]$remote.Address.IPAddressToString) -Force
      }
      $workers.Add($payload) | Out-Null
    }
  } finally {
    $udp.Dispose()
  }

  $discoveredWorkers = @($workers.ToArray())
  if ($discoveredWorkers.Count -eq 0 -and ((-not (Test-RaymanWorkerProtectedDevMachine -WorkspaceRoot $resolvedRoot)) -or (Get-RaymanWorkerAllowProtectedLocal -WorkspaceRoot $resolvedRoot))) {
    try {
      $loopbackStatus = Invoke-RaymanWorkerControlRequest -Worker ([pscustomobject]@{
            address = '127.0.0.1'
            control_port = (Get-RaymanWorkerControlPort)
            control_url = ('http://127.0.0.1:{0}/' -f (Get-RaymanWorkerControlPort))
          }) -Method GET -Path '/status' -TimeoutSeconds 5 -WorkspaceRoot $resolvedRoot
      if ($null -ne $loopbackStatus -and [string]$loopbackStatus.schema -eq 'rayman.worker.status.v1') {
        $discoveredWorkers = @([pscustomobject]@{
              worker_id = [string]$loopbackStatus.worker_id
              worker_name = [string]$loopbackStatus.worker_name
              machine_name = [string]$loopbackStatus.machine_name
              user_name = [string]$loopbackStatus.user_name
              version = [string]$loopbackStatus.version
              workspace_root = [string]$loopbackStatus.workspace_root
              workspace_name = [string]$loopbackStatus.workspace_name
              workspace_mode = [string]$loopbackStatus.workspace_mode
              interactive_session = [bool]$loopbackStatus.interactive_session
              address = [string]$loopbackStatus.address
              discovery_port = if ($loopbackStatus.PSObject.Properties['discovery']) { [int]$loopbackStatus.discovery.port } else { $port }
              control_port = if ($loopbackStatus.PSObject.Properties['control']) { [int]$loopbackStatus.control.port } else { (Get-RaymanWorkerControlPort) }
              control_url = if ($loopbackStatus.PSObject.Properties['control']) { [string]$loopbackStatus.control.base_url } else { ('http://127.0.0.1:{0}/' -f (Get-RaymanWorkerControlPort)) }
              debugger_ready = if ($loopbackStatus.PSObject.Properties['debugger_ready']) { [bool]$loopbackStatus.debugger_ready } else { $false }
              debugger_path = if ($loopbackStatus.PSObject.Properties['debugger_path']) { [string]$loopbackStatus.debugger_path } else { '' }
              debugger_error = if ($loopbackStatus.PSObject.Properties['debugger_error']) { [string]$loopbackStatus.debugger_error } else { '' }
              capabilities = $loopbackStatus.capabilities
              git = $loopbackStatus.git
            })
      }
    } catch {}
  }

  $merged = Merge-RaymanWorkerRegistry -WorkspaceRoot $resolvedRoot -Workers $discoveredWorkers
  $visibleWorkers = @(Get-RaymanSelectableRegistryWorkers -WorkspaceRoot $resolvedRoot -Workers @($merged.workers))
  $summary = [pscustomobject]@{
    schema = 'rayman.worker.discovery.last.v1'
    generated_at = (Get-Date).ToString('o')
    workspace_root = $resolvedRoot
    listen_seconds = $ListenSeconds
    workers = @($visibleWorkers)
  }
  Save-RaymanWorkerDiscoverySummary -WorkspaceRoot $resolvedRoot -Summary $summary
  return $summary
}

function Get-RaymanWorkerLiveStatus {
  param(
    [string]$WorkspaceRoot,
    [object]$Worker
  )

  $clientContext = Get-RaymanWorkerClientContext -WorkspaceRoot $WorkspaceRoot
  $statusTimeout = Get-RaymanWorkerStatusTimeoutSeconds -WorkspaceRoot $WorkspaceRoot
  try {
    $status = Invoke-RaymanWorkerControlRequest -Worker $Worker -Method GET -Path '/status' -TimeoutSeconds $statusTimeout -WorkspaceRoot $WorkspaceRoot -ClientContext $clientContext
  } catch {
    $fallbackTimeout = Get-RaymanWorkerStatusFallbackTimeoutSeconds -WorkspaceRoot $WorkspaceRoot
    $isTimeout = ($_.Exception.Message -match 'timed out|HttpClient\.Timeout|request was canceled')
    if (-not $isTimeout -or $fallbackTimeout -le $statusTimeout) {
      throw
    }
    $status = Invoke-RaymanWorkerControlRequest -Worker $Worker -Method GET -Path '/status' -TimeoutSeconds $fallbackTimeout -WorkspaceRoot $WorkspaceRoot -ClientContext $clientContext
  }
  if ($null -ne $status) {
    [void](Merge-RaymanWorkerRegistry -WorkspaceRoot $WorkspaceRoot -Workers @([pscustomobject]@{
          worker_id = [string]$status.worker_id
          worker_name = [string]$status.worker_name
          address = [string]$status.address
          control_port = [int]$status.control.port
          control_url = [string]$status.control.base_url
          workspace_root = [string]$status.workspace_root
          workspace_mode = [string]$status.workspace_mode
          version = [string]$status.version
          machine_name = [string]$status.machine_name
          debugger_ready = if ($status.PSObject.Properties['debugger_ready']) { [bool]$status.debugger_ready } else { $false }
          debugger_path = if ($status.PSObject.Properties['debugger_path']) { [string]$status.debugger_path } else { '' }
        }))
  }
  return $status
}

function Invoke-RaymanWorkerSyncAction {
  param(
    [string]$WorkspaceRoot,
    [object]$Worker,
    [string]$Mode
  )

  $clientContext = Get-RaymanWorkerClientContext -WorkspaceRoot $WorkspaceRoot
  if ($Mode -eq 'staged') {
    $bundle = New-RaymanWorkerSyncBundle -WorkspaceRoot $WorkspaceRoot
    $syncManifest = Invoke-RaymanWorkerControlRequest -Worker $Worker -Method POST -Path '/sync' -Body ([pscustomobject]@{
          mode = 'staged'
          bundle_name = [System.IO.Path]::GetFileName([string]$bundle.bundle_path)
          bundle_base64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes([string]$bundle.bundle_path))
        }) -TimeoutSeconds 300 -WorkspaceRoot $WorkspaceRoot -ClientContext $clientContext
    if ($null -ne $syncManifest) {
      $sourceFingerprint = if ($bundle.PSObject.Properties['manifest'] -and $bundle.manifest.PSObject.Properties['fingerprint']) {
        [string]$bundle.manifest.fingerprint
      } else {
        ''
      }
      if (-not [string]::IsNullOrWhiteSpace([string]$sourceFingerprint)) {
        $syncManifest | Add-Member -MemberType NoteProperty -Name source_fingerprint -Value $sourceFingerprint -Force
      }
      if ($bundle.PSObject.Properties['manifest'] -and $bundle.manifest.PSObject.Properties['file_count']) {
        $syncManifest | Add-Member -MemberType NoteProperty -Name source_file_count -Value ([int]$bundle.manifest.file_count) -Force
      }
    }
    Write-RaymanWorkerJsonFile -Path (Get-RaymanWorkerSyncLastPath -WorkspaceRoot $WorkspaceRoot) -Value $syncManifest
    $active = Set-RaymanActiveWorkerRecord -WorkspaceRoot $WorkspaceRoot -Worker $Worker -WorkspaceMode 'staged' -SyncManifest $syncManifest -ClientContext $clientContext
    $cleanup = if (Get-Command Invoke-RaymanRuntimeCleanup -ErrorAction SilentlyContinue) {
      Invoke-RaymanRuntimeCleanup -WorkspaceRoot $WorkspaceRoot -Mode 'cache-clear' -KeepDays 14 -WriteSummary
    } else {
      $null
    }
    return [pscustomobject]@{
      schema = 'rayman.worker.sync.result.v1'
      generated_at = (Get-Date).ToString('o')
      mode = 'staged'
      sync_manifest = $syncManifest
      active = $active
      bundle = $bundle
      cleanup = $cleanup
    }
  }

  throw 'shared workers support staged sync only; use `rayman.ps1 worker sync --mode staged`.'
}

function Invoke-RaymanWorkerDebugAction {
  param(
    [string]$WorkspaceRoot,
    [object]$Worker,
    [string]$Mode,
    [string]$Program = '',
    [int]$ProcessId = 0
  )

  $active = Get-RaymanActiveWorkerRecord -WorkspaceRoot $WorkspaceRoot
  $syncManifest = if ($null -ne $active -and $active.PSObject.Properties['sync_manifest']) { $active.sync_manifest } else { $null }
  $clientContext = if ($null -ne $active -and $active.PSObject.Properties['client_context']) { $active.client_context } else { (Get-RaymanWorkerClientContext -WorkspaceRoot $WorkspaceRoot) }
  $manifest = Invoke-RaymanWorkerControlRequest -Worker $Worker -Method POST -Path '/debug' -Body ([pscustomobject]@{
        mode = $Mode
        program = $Program
        process_id = $ProcessId
        sync_manifest = $syncManifest
      }) -TimeoutSeconds 30 -WorkspaceRoot $WorkspaceRoot -ClientContext $clientContext

  if ($null -ne $manifest -and $manifest.PSObject.Properties['source_file_map']) {
    $map = [ordered]@{}
    foreach ($prop in $manifest.source_file_map.PSObject.Properties) {
      $map[[string]$prop.Name] = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    }
    $manifest.source_file_map = [pscustomobject]$map
  }

  Save-RaymanWorkerDebugManifest -WorkspaceRoot $WorkspaceRoot -Manifest $manifest
  Update-RaymanWorkerLaunchBindings -WorkspaceRoot $WorkspaceRoot -Manifest $manifest | Out-Null
  return $manifest
}

function Invoke-RaymanWorkerUpgradeAction {
  param(
    [string]$WorkspaceRoot,
    [object]$Worker
  )

  $clientContext = Get-RaymanWorkerClientContext -WorkspaceRoot $WorkspaceRoot
  $package = New-RaymanWorkerUpgradePackage -WorkspaceRoot $WorkspaceRoot
  $response = Invoke-RaymanWorkerControlRequest -Worker $Worker -Method POST -Path '/upgrade' -Body ([pscustomobject]@{
        package_name = [System.IO.Path]::GetFileName([string]$package.package_path)
        package_base64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes([string]$package.package_path))
      }) -TimeoutSeconds 300 -WorkspaceRoot $WorkspaceRoot -ClientContext $clientContext

  $status = $null
  $deadline = (Get-Date).AddSeconds(45)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 1500
    try {
      $status = Get-RaymanWorkerLiveStatus -WorkspaceRoot $WorkspaceRoot -Worker $Worker
      if ($null -ne $status) { break }
    } catch {}
  }

  return [pscustomobject]@{
    schema = 'rayman.worker.upgrade.result.v1'
    generated_at = (Get-Date).ToString('o')
    response = $response
    package = $package
    status = $status
  }
}

function Get-RaymanWorkerCliExitCode {
  param(
    [object]$Result
  )

  if ($null -eq $Result -or $null -eq $Result.PSObject.Properties['exit_code']) {
    return 0
  }

  $resolvedExitCode = 0
  if ([int]::TryParse([string]$Result.exit_code, [ref]$resolvedExitCode)) {
    return $resolvedExitCode
  }

  return 0
}

if (-not $NoMain) {
  $WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  if ($null -eq $CliArgs) { $CliArgs = @() } else { $CliArgs = @($CliArgs) }

  $tail = Split-RaymanWorkerCommandTail -Arguments $CliArgs
  $argsList = @($tail.options)
  $remainder = @($tail.remainder)
  $workerId = ''
  $workerName = ''
  $mode = 'attached'
  $program = ''
  $processId = 0
  $targetPath = ''
  $noRemember = $false
  $json = $false
  $unparsedArgs = New-Object System.Collections.Generic.List[string]

  for ($i = 0; $i -lt $argsList.Count; $i++) {
    $token = [string]$argsList[$i]
    switch -Regex ($token) {
      '^--?(id)$' { if ($i + 1 -lt $argsList.Count) { $workerId = [string]$argsList[++$i] }; continue }
      '^--?(name)$' { if ($i + 1 -lt $argsList.Count) { $workerName = [string]$argsList[++$i] }; continue }
      '^--?(mode)$' { if ($i + 1 -lt $argsList.Count) { $mode = [string]$argsList[++$i] }; continue }
      '^--?(program)$' { if ($i + 1 -lt $argsList.Count) { $program = [string]$argsList[++$i] }; continue }
      '^--?(process-id|processid)$' { if ($i + 1 -lt $argsList.Count) { $processId = [int][string]$argsList[++$i] }; continue }
      '^--?(target)$' { if ($i + 1 -lt $argsList.Count) { $targetPath = [string]$argsList[++$i] }; continue }
      '^--?(no-remember|noremember)$' { $noRemember = $true; continue }
      '^--?(json)$' { $json = $true; continue }
      default { $unparsedArgs.Add($token) | Out-Null; continue }
    }
  }

  if ($Action.ToLowerInvariant() -eq 'exec' -and $remainder.Count -eq 0 -and $unparsedArgs.Count -gt 0) {
    $remainder = @($unparsedArgs.ToArray())
  }

  $result = $null
  try {
    switch ($Action.ToLowerInvariant()) {
      'install-local' { $result = Install-RaymanLocalWorker -WorkspaceRoot $WorkspaceRoot; break }
      'uninstall-local' { $result = Uninstall-RaymanLocalWorker -WorkspaceRoot $WorkspaceRoot; break }
      'discover' {
        $result = Discover-RaymanWorkers -WorkspaceRoot $WorkspaceRoot -ListenSeconds (Get-RaymanWorkerDiscoveryListenSeconds)
        break
      }
      'list' {
        $result = Get-RaymanVisibleWorkerRegistryDocument -WorkspaceRoot $WorkspaceRoot
        break
      }
      'use' {
        $worker = Resolve-RaymanWorkerSelection -WorkspaceRoot $WorkspaceRoot -WorkerId $workerId -WorkerName $workerName -AllowActive:$false
        Assert-RaymanWorkerActionAllowed -WorkspaceRoot $WorkspaceRoot -Action 'use' -Worker $worker
        $result = Set-RaymanActiveWorkerRecord -WorkspaceRoot $WorkspaceRoot -Worker $worker -WorkspaceMode $mode -SyncManifest $null -ClientContext (Get-RaymanWorkerClientContext -WorkspaceRoot $WorkspaceRoot)
        break
      }
      'clear' {
        Set-RaymanWorkerAttachedSyncManifest -WorkspaceRoot $WorkspaceRoot | Out-Null
        $active = Get-RaymanActiveWorkerRecord -WorkspaceRoot $WorkspaceRoot
        $remoteClear = $null
        if ($null -ne $active -and -not [string]::IsNullOrWhiteSpace([string]$active.worker_id)) {
          try {
            $worker = Resolve-RaymanWorkerSelection -WorkspaceRoot $WorkspaceRoot -WorkerId ([string]$active.worker_id) -AllowActive
            if ($null -ne $worker) {
              $clientContext = if ($active.PSObject.Properties['client_context']) { $active.client_context } else { (Get-RaymanWorkerClientContext -WorkspaceRoot $WorkspaceRoot) }
              $remoteClear = Invoke-RaymanWorkerControlRequest -Worker $worker -Method POST -Path '/client/clear' -Body ([pscustomobject]@{}) -TimeoutSeconds 30 -WorkspaceRoot $WorkspaceRoot -ClientContext $clientContext
            }
          } catch {}
        }
        Clear-RaymanActiveWorkerRecord -WorkspaceRoot $WorkspaceRoot
        $cleanup = if (Get-Command Invoke-RaymanRuntimeCleanup -ErrorAction SilentlyContinue) {
          Invoke-RaymanRuntimeCleanup -WorkspaceRoot $WorkspaceRoot -Mode 'cache-clear' -KeepDays 14 -WriteSummary
        } else {
          $null
        }
        $result = [pscustomobject]@{
          schema = 'rayman.worker.clear.result.v1'
          generated_at = (Get-Date).ToString('o')
          workspace_root = $WorkspaceRoot
          remote_clear = $remoteClear
          cleanup = $cleanup
        }
        break
      }
      'status' {
        $worker = Resolve-RaymanWorkerSelection -WorkspaceRoot $WorkspaceRoot -WorkerId $workerId -WorkerName $workerName -AllowActive
        Assert-RaymanWorkerActionAllowed -WorkspaceRoot $WorkspaceRoot -Action 'status' -Worker $worker
        $result = Get-RaymanWorkerLiveStatus -WorkspaceRoot $WorkspaceRoot -Worker $worker
        break
      }
      'exec' {
        $worker = Resolve-RaymanWorkerSelection -WorkspaceRoot $WorkspaceRoot -WorkerId $workerId -WorkerName $workerName -AllowActive
        Assert-RaymanWorkerActionAllowed -WorkspaceRoot $WorkspaceRoot -Action 'exec' -Worker $worker
        if ([string]::IsNullOrWhiteSpace((Format-RaymanWorkerCommandText -CommandParts $remainder))) {
          throw 'worker exec requires `-- <command>`.'
        }
        Ensure-RaymanSelectedWorkerIsActive -WorkspaceRoot $WorkspaceRoot -Worker $worker -WorkspaceMode $mode | Out-Null
        $result = Invoke-RaymanWorkerRemoteCommand -WorkspaceRoot $WorkspaceRoot -CommandText (Format-RaymanWorkerCommandText -CommandParts $remainder)
        if (-not $json) {
          foreach ($line in @($result.output_lines)) {
            Write-Host $line
          }
        }
        break
      }
      'sync' {
        $worker = Resolve-RaymanWorkerSelection -WorkspaceRoot $WorkspaceRoot -WorkerId $workerId -WorkerName $workerName -AllowActive
        Assert-RaymanWorkerActionAllowed -WorkspaceRoot $WorkspaceRoot -Action 'sync' -Worker $worker
        $result = Invoke-RaymanWorkerSyncAction -WorkspaceRoot $WorkspaceRoot -Worker $worker -Mode $mode
        break
      }
      'debug' {
        $worker = Resolve-RaymanWorkerSelection -WorkspaceRoot $WorkspaceRoot -WorkerId $workerId -WorkerName $workerName -AllowActive
        Assert-RaymanWorkerActionAllowed -WorkspaceRoot $WorkspaceRoot -Action 'debug' -Worker $worker
        Ensure-RaymanSelectedWorkerIsActive -WorkspaceRoot $WorkspaceRoot -Worker $worker -WorkspaceMode $mode | Out-Null
        $result = Invoke-RaymanWorkerDebugAction -WorkspaceRoot $WorkspaceRoot -Worker $worker -Mode $mode -Program $program -ProcessId $processId
        break
      }
      'upgrade' {
        $worker = Resolve-RaymanWorkerSelection -WorkspaceRoot $WorkspaceRoot -WorkerId $workerId -WorkerName $workerName -AllowActive
        Assert-RaymanWorkerActionAllowed -WorkspaceRoot $WorkspaceRoot -Action 'upgrade' -Worker $worker
        $result = Invoke-RaymanWorkerUpgradeAction -WorkspaceRoot $WorkspaceRoot -Worker $worker
        break
      }
      'export-package' {
        $result = Invoke-RaymanWorkerExportPackage -WorkspaceRoot $WorkspaceRoot -TargetPath $targetPath -NoRemember:$noRemember
        if (-not $json) {
          Write-Host ("导出完成：{0}" -f [string]$result.target_path)
          Write-Host ("已写入：{0}" -f ((@($result.copied_items) -join ', ')))
          Write-Host '下一步：在工作机登录会话中打开该目录并执行'
          Write-Host '.\all.bat'
        }
        break
      }
      default {
        throw ("unknown worker action: {0}" -f $Action)
      }
    }
    $global:LASTEXITCODE = Get-RaymanWorkerCliExitCode -Result $result
  } catch {
    $result = New-RaymanWorkerCliErrorResult -Action $Action -ErrorRecord $_
    $global:LASTEXITCODE = 1
    if ($Action.ToLowerInvariant() -in @('exec', 'export-package') -and -not $json) {
      Write-Error ([string]$result.error)
    }
  }

  if ($json -or $Action.ToLowerInvariant() -notin @('exec', 'export-package')) {
    $result | ConvertTo-Json -Depth 12
  }
  exit $(if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 })
}
