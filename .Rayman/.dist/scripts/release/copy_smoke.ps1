param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$Strict,
  [switch]$KeepTemp,
  [switch]$OpenOnFail,
  [int]$TimeoutSeconds = 120,
  [ValidateSet('all','wsl','sandbox','host')][string]$Scope = 'wsl'
)

$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
  . $commonPath
}
$workspaceOwnershipPath = Join-Path $PSScriptRoot '..\utils\workspace_process_ownership.ps1'
if (Test-Path -LiteralPath $workspaceOwnershipPath -PathType Leaf) {
  . $workspaceOwnershipPath -NoMain
}

$script:CopySmokeStartedAt = Get-Date
$script:CopySmokeRunId = [Guid]::NewGuid().ToString('n')

function Info([string]$m){ Write-Host ("ℹ️  [copy-smoke] {0}" -f $m) -ForegroundColor Cyan }
function Ok([string]$m){ Write-Host ("✅ [copy-smoke] {0}" -f $m) -ForegroundColor Green }
function Warn([string]$m){ Write-Host ("⚠️  [copy-smoke] {0}" -f $m) -ForegroundColor Yellow }
function Fail([string]$m){ Write-Host ("❌ [copy-smoke] {0}" -f $m) -ForegroundColor Red; exit 2 }

function Write-CopySmokeTelemetry([int]$ExitCode) {
  if (-not (Get-Command Write-RaymanRulesTelemetryRecord -ErrorAction SilentlyContinue)) {
    return
  }
  try {
    $durationMs = [int][Math]::Max(0, [Math]::Round(((Get-Date) - $script:CopySmokeStartedAt).TotalMilliseconds))
    Write-RaymanRulesTelemetryRecord -WorkspaceRoot $WorkspaceRoot -RunId $script:CopySmokeRunId -Profile 'copy-self-check' -Stage 'final' -Scope $Scope -Status $(if ($ExitCode -eq 0) { 'OK' } else { 'FAIL' }) -ExitCode $ExitCode -DurationMs $durationMs -Command 'copy-self-check' | Out-Null
  } catch {}
}

function Reset-LastExitCodeCompat {
  try { Set-Variable -Name 'LASTEXITCODE' -Scope Global -Value 0 -Force } catch {}
  try { Set-Variable -Name 'LASTEXITCODE' -Scope Script -Value 0 -Force } catch {}
}

function Get-LastExitCodeCompat([int]$Default = 0) {
  try {
    $g = Get-Variable -Name 'LASTEXITCODE' -Scope Global -ErrorAction Stop
    if ($null -ne $g.Value) { return [int]$g.Value }
  } catch {}

  try {
    $s = Get-Variable -Name 'LASTEXITCODE' -Scope Script -ErrorAction Stop
    if ($null -ne $s.Value) { return [int]$s.Value }
  } catch {}

  return $Default
}

function Set-EnvOverride {
  param(
    [hashtable]$Backup,
    [string]$Name,
    [string]$Value
  )

  if (-not $Backup.ContainsKey($Name)) {
    $Backup[$Name] = [System.Environment]::GetEnvironmentVariable($Name)
  }
  [System.Environment]::SetEnvironmentVariable($Name, $Value)
}

function Clear-EnvOverride {
  param(
    [hashtable]$Backup,
    [string]$Name
  )

  if (-not $Backup.ContainsKey($Name)) {
    $Backup[$Name] = [System.Environment]::GetEnvironmentVariable($Name)
  }
  [System.Environment]::SetEnvironmentVariable($Name, $null)
}

function Restore-EnvOverrides([hashtable]$Backup) {
  foreach ($name in $Backup.Keys) {
    $previousValue = $Backup[$name]
    if ($null -eq $previousValue) {
      [System.Environment]::SetEnvironmentVariable($name, $null)
    } else {
      [System.Environment]::SetEnvironmentVariable($name, [string]$previousValue)
    }
  }
}

function Test-CopySmokeHostIsWindows {
  try {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
  } catch {
    return $false
  }
}

function Get-CopySmokeSandboxProcesses {
  if (-not (Test-CopySmokeHostIsWindows)) { return @() }
  try {
    return @(Get-Process -Name 'WindowsSandbox', 'WindowsSandboxClient' -ErrorAction SilentlyContinue)
  } catch {
    return @()
  }
}

function Get-CopySmokeSandboxPidSnapshot {
  $pids = @()
  foreach ($proc in @(Get-CopySmokeSandboxProcesses)) {
    if ($null -eq $proc) { continue }
    $pids += [int]$proc.Id
  }
  if (@($pids).Count -eq 0) { return @() }
  return ,@($pids | Sort-Object -Unique)
}

function Get-CopySmokeOwnerToken {
  foreach ($name in @('RAYMAN_VSCODE_WINDOW_OWNER', 'VSCODE_IPC_HOOK_CLI', 'VSCODE_IPC_HOOK', 'VSCODE_PID')) {
    $value = [string][Environment]::GetEnvironmentVariable($name)
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return [pscustomobject]@{
        Source = $name
        Value  = $value.Trim()
      }
    }
  }
  return $null
}

function Get-CopySmokeSandboxOwnerRegistryPath {
  $dir = Join-Path ([System.IO.Path]::GetTempPath()) 'rayman'
  return (Join-Path $dir 'sandbox-owner-registry.json')
}

function Get-CopySmokeSandboxOwnerRegistryEntries {
  $path = Get-CopySmokeSandboxOwnerRegistryPath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
  try {
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    return @($raw | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return @()
  }
}

function Get-CopySmokeSandboxOwnerStatePath([string]$TempRayman) {
  return (Join-Path $TempRayman 'runtime\windows-sandbox\owner.state.json')
}

function Format-CopySmokePidList([int[]]$Pids) {
  $pidList = @($Pids)
  if ($pidList.Count -eq 0) { return '(none)' }
  return (@($pidList | Sort-Object -Unique) -join ', ')
}

function Format-CopySmokeStopProcessCommand([int[]]$Pids) {
  $pidList = @($Pids)
  if ($pidList.Count -eq 0) { return $null }
  $uniquePids = @($pidList | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
  if ($uniquePids.Count -eq 0) { return $null }
  return ('Stop-Process -Id {0} -Force' -f ($uniquePids -join ','))
}

function Get-CopySmokeSandboxOwnershipSummary {
  param(
    [string]$TempRoot,
    [string]$TempRayman,
    [int[]]$BaselinePids = @(),
    [object]$OwnerToken = $null
  )

  $livePids = @((Get-CopySmokeSandboxPidSnapshot | Sort-Object -Unique))
  $baseline = @(@($BaselinePids) | Sort-Object -Unique)
  $newPids = @($livePids | Where-Object { $_ -notin $baseline })

  $ownerStatePath = Get-CopySmokeSandboxOwnerStatePath -TempRayman $TempRayman
  $ownerState = $null
  if (Test-Path -LiteralPath $ownerStatePath -PathType Leaf) {
    try {
      $ownerState = Get-Content -LiteralPath $ownerStatePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {}
  }

  $registryEntries = @(Get-CopySmokeSandboxOwnerRegistryEntries)
  $ownedPids = @()
  if ($null -ne $ownerState -and $ownerState.PSObject.Properties['pid']) {
    try {
      $ownerPid = [int]$ownerState.pid
      if ($ownerPid -gt 0 -and $ownerPid -in $livePids) { $ownedPids += $ownerPid }
    } catch {}
  }
  foreach ($entry in $registryEntries) {
    if ($null -eq $entry) { continue }
    $entryWorkspace = ''
    if ($entry.PSObject.Properties['workspaceRoot']) { $entryWorkspace = [string]$entry.workspaceRoot }
    $pidValue = 0
    try { $pidValue = [int]$entry.pid } catch { $pidValue = 0 }
    if ($pidValue -le 0 -or $pidValue -notin $livePids) { continue }
    if ($entryWorkspace -eq $TempRoot) { $ownedPids += $pidValue }
  }
  $ownedPids = @($ownedPids | Sort-Object -Unique)

  $registryPids = @()
  foreach ($entry in $registryEntries) {
    $pidValue = 0
    try { $pidValue = [int]$entry.pid } catch { $pidValue = 0 }
    if ($pidValue -gt 0 -and $pidValue -in $livePids) { $registryPids += $pidValue }
  }
  $registryPids = @($registryPids | Sort-Object -Unique)

  $foreignPids = @($registryPids | Where-Object { $_ -notin $ownedPids })
  $unknownPids = @($livePids | Where-Object { $_ -notin $registryPids })
  $suggestClosePids = @($newPids | Where-Object { $_ -in $ownedPids })

  $ownerDisplay = if ($null -ne $ownerState -and $ownerState.PSObject.Properties['ownerDisplay']) {
    [string]$ownerState.ownerDisplay
  } elseif ($null -ne $OwnerToken) {
    [string]$OwnerToken.Source
  } else {
    'workspace-root'
  }

  return [pscustomobject]@{
    OwnerDisplay      = $ownerDisplay
    BaselinePids      = @($baseline)
    LivePids          = @($livePids)
    NewPids           = @($newPids)
    OwnedPids         = @($ownedPids)
    ForeignPids       = @($foreignPids)
    UnknownPids       = @($unknownPids)
    SuggestClosePids  = @($suggestClosePids)
    OwnerStatePath    = $ownerStatePath
  }
}

function Write-CopySmokeSandboxOwnershipSummary([object]$Summary) {
  if ($null -eq $Summary) { return }
  Warn ("sandbox owner summary: owner={0}" -f [string]$Summary.OwnerDisplay)
  Warn ("sandbox pids: baseline={0} | live={1} | new={2}" -f (Format-CopySmokePidList $Summary.BaselinePids), (Format-CopySmokePidList $Summary.LivePids), (Format-CopySmokePidList $Summary.NewPids))
  Warn ("sandbox classify: owned={0} | foreign={1} | unknown={2}" -f (Format-CopySmokePidList $Summary.OwnedPids), (Format-CopySmokePidList $Summary.ForeignPids), (Format-CopySmokePidList $Summary.UnknownPids))
  if (@($Summary.SuggestClosePids).Count -gt 0) {
    Warn ("建议仅关闭当前窗口/本次 smoke 的 Sandbox PID: {0}" -f (Format-CopySmokePidList $Summary.SuggestClosePids))
    $stopCommand = Format-CopySmokeStopProcessCommand -Pids $Summary.SuggestClosePids
    if (-not [string]::IsNullOrWhiteSpace($stopCommand)) {
      Warn ("可复制命令: {0}" -f $stopCommand)
    }
  } elseif (@($Summary.ForeignPids).Count -gt 0 -or @($Summary.UnknownPids).Count -gt 0) {
    Warn '未给出自动关闭建议：当前存在外部 owner 或未知来源的 Sandbox，Rayman 不会替你处理它们。'
  }
}

function Stop-CopySmokeSandboxProcesses {
  param(
    [string]$Reason = '收尾',
    [int[]]$PreservePids = @()
  )

  if (-not (Test-CopySmokeHostIsWindows)) { return }

  $preserve = New-Object 'System.Collections.Generic.HashSet[int]'
  foreach ($pidValue in @($PreservePids)) {
    [void]$preserve.Add([int]$pidValue)
  }

  $targets = @()
  foreach ($proc in @(Get-CopySmokeSandboxProcesses)) {
    if ($null -eq $proc) { continue }
    if ($preserve.Contains([int]$proc.Id)) { continue }
    $targets += $proc
  }

  if (@($targets).Count -eq 0) {
    Info ("sandbox cleanup skipped: no new sandbox processes to close ({0})" -f $Reason)
    return
  }

  Info ("sandbox cleanup ({0}): {1}" -f $Reason, (($targets | ForEach-Object { "$($_.ProcessName)#$($_.Id)" }) -join ', '))
  foreach ($proc in $targets) {
    try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch {}
  }
  Start-Sleep -Seconds 2
}

function Convert-PathToWindowsViaWslpath([string]$Path) {
  $wslPathCmd = Get-Command 'wslpath' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $wslPathCmd) { return $Path }
  try {
    $raw = (& $wslPathCmd.Source -w $Path | Select-Object -First 1)
    if (-not [string]::IsNullOrWhiteSpace([string]$raw)) {
      return [string]$raw.Trim()
    }
  } catch {}
  return $Path
}

function ConvertTo-PsSingleQuotedLiteral([string]$Value) {
  if ($null -eq $Value) { return '' }
  return $Value.Replace("'", "''")
}

function Reset-PortableRuntimeAndLogs([string]$RaymanRoot) {
  foreach ($rel in @('runtime','logs')) {
    $p = Join-Path $RaymanRoot $rel
    if (Test-Path -LiteralPath $p -PathType Container) {
      Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
    } elseif (Test-Path -LiteralPath $p) {
      Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }

  # Avoid stale MCP pid carry-over when copying from a used workspace.
  $mcpPid = Join-Path $RaymanRoot 'mcp\mcp_pids.json'
  if (Test-Path -LiteralPath $mcpPid -PathType Leaf) {
    Remove-Item -LiteralPath $mcpPid -Force -ErrorAction SilentlyContinue
  }

  $stateRoot = Join-Path $RaymanRoot 'state'
  $memoryRoot = Join-Path $stateRoot 'memory'
  if (Test-Path -LiteralPath $memoryRoot -PathType Container) {
    foreach ($entry in @(Get-ChildItem -LiteralPath $memoryRoot -Force -ErrorAction SilentlyContinue)) {
      Remove-Item -LiteralPath $entry.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
  } else {
    New-Item -ItemType Directory -Force -Path $memoryRoot | Out-Null
  }

  foreach ($legacyPath in @(
    (Join-Path $stateRoot ('chroma' + '_db')),
    (Join-Path $stateRoot ('rag' + '.db'))
  )) {
    if (Test-Path -LiteralPath $legacyPath) {
      Remove-Item -LiteralPath $legacyPath -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

function Disable-CopySmokeSlowSetupModules([string]$TempRoot) {
  foreach ($relativePath in @(
    '.Rayman\scripts\memory\manage_memory.ps1',
    '.Rayman\scripts\mcp\manage_mcp.ps1',
    '.Rayman\scripts\agents\ensure_agent_capabilities.ps1'
  )) {
    $targetPath = Join-Path $TempRoot $relativePath
    if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
      Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Copy-RaymanTemplateForSmoke {
  param(
    [string]$SourceRayman,
    [string]$TargetRayman
  )

  if (-not (Test-Path -LiteralPath $SourceRayman -PathType Container)) {
    throw ("source .Rayman not found: {0}" -f $SourceRayman)
  }

  if (-not (Test-Path -LiteralPath $TargetRayman -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $TargetRayman | Out-Null
  }

  $excluded = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  [void]$excluded.Add('runtime')
  [void]$excluded.Add('logs')
  [void]$excluded.Add('.Rayman')

  $entries = @(Get-ChildItem -LiteralPath $SourceRayman -Force -ErrorAction Stop)
  foreach ($entry in $entries) {
    if ($excluded.Contains([string]$entry.Name)) { continue }
    Copy-Item -LiteralPath $entry.FullName -Destination $TargetRayman -Recurse -Force
  }
}

function Initialize-CopySmokeGitRepo([string]$Root) {
  if (Test-Path -LiteralPath (Join-Path $Root '.git') -PathType Container) {
    return
  }

  $git = Get-Command 'git' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $git -or [string]::IsNullOrWhiteSpace([string]$git.Source)) {
    Warn 'strict 模式未找到 git，无法为临时目录初始化仓库，后续 Release Gate 可能失败。'
    return
  }

  try {
    Push-Location $Root
    & $git.Source init | Out-Null
    & $git.Source config user.name 'rayman-copy-smoke' | Out-Null
    & $git.Source config user.email 'rayman-copy-smoke@local' | Out-Null
    Ok 'strict 模式已为临时目录初始化 git 仓库（用于 Release Gate 验收）'
  } catch {
    Warn ("strict 模式初始化临时 git 仓库失败: {0}" -f $_.Exception.Message)
  } finally {
    Pop-Location
  }
}

function Get-CopySmokeLatestSetupLog([string]$TempRayman) {
  $logsDir = Join-Path $TempRayman 'logs'
  if (-not (Test-Path -LiteralPath $logsDir -PathType Container)) { return '' }
  try {
    $latestLog = Get-ChildItem -LiteralPath $logsDir -Filter 'setup.win.*.log' -File -ErrorAction Stop |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if ($null -ne $latestLog) { return $latestLog.FullName }
  } catch {}
  return ''
}

function Get-CopySmokeLatestVsCodeAuditPath([string]$TempRayman) {
  $auditPath = Join-Path $TempRayman 'runtime\vscode_windows.last.json'
  if (Test-Path -LiteralPath $auditPath -PathType Leaf) {
    return $auditPath
  }
  return ''
}

function Convert-CopySmokePassNameToSlug([string]$PassName) {
  $value = if ([string]::IsNullOrWhiteSpace($PassName)) { 'setup-pass' } else { $PassName.Trim().ToLowerInvariant() }
  $slug = [regex]::Replace($value, '[^a-z0-9]+', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($slug)) {
    return 'setup-pass'
  }
  return $slug
}

function Get-CopySmokeSetupRunArchiveDir([string]$TempRoot) {
  return (Join-Path $TempRoot '.Rayman\runtime\copy_smoke_setup_runs')
}

function Get-CopySmokeSetupRunAuditPath([string]$TempRoot) {
  return (Join-Path $TempRoot '.Rayman\runtime\copy_smoke_setup_runs.json')
}

function Save-CopySmokeArtifactCopy {
  param(
    [string]$SourcePath,
    [string]$DestinationPath
  )

  if ([string]::IsNullOrWhiteSpace($SourcePath) -or -not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    return ''
  }
  if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
    return ''
  }

  try {
    $dir = Split-Path -Parent $DestinationPath
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
    return $DestinationPath
  } catch {
    return ''
  }
}

function Write-CopySmokeSetupRunAuditFile([string]$TempRoot) {
  if ([string]::IsNullOrWhiteSpace($TempRoot)) { return '' }
  $auditPath = Get-CopySmokeSetupRunAuditPath -TempRoot $TempRoot
  try {
    $dir = Split-Path -Parent $auditPath
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($auditPath, (@($script:CopySmokeSetupRuns.ToArray()) | ConvertTo-Json -Depth 8), $utf8NoBom)
    return $auditPath
  } catch {
    return ''
  }
}

function Add-CopySmokeSetupRunAudit {
  param(
    [string]$TempRoot,
    [hashtable]$RunRecord
  )

  if ($null -eq $RunRecord) { return '' }
  if ($null -eq $script:CopySmokeSetupRuns) {
    $script:CopySmokeSetupRuns = New-Object 'System.Collections.Generic.List[object]'
  }
  $script:CopySmokeSetupRuns.Add([pscustomobject]$RunRecord) | Out-Null
  return (Write-CopySmokeSetupRunAuditFile -TempRoot $TempRoot)
}

function Invoke-CopySmokeSetupRun {
  param(
    [string]$SetupScript,
    [string]$TempRoot,
    [string]$Scope,
    [int]$TimeoutSeconds,
    [bool]$StrictMode,
    [ValidateSet('inherit','block','clear')][string]$TrackedAssetsMode = 'inherit',
    [string]$PassName = 'setup-pass'
  )

  $tempRayman = Join-Path $TempRoot '.Rayman'
  $passSlug = Convert-CopySmokePassNameToSlug -PassName $PassName
  $startedAt = Get-Date
  $run = [ordered]@{
    PassName = $PassName
    PassSlug = $passSlug
    TrackedAssetsMode = $TrackedAssetsMode
    StartedAt = $startedAt.ToString('o')
    FinishedAt = ''
    ExitCode = 0
    Exception = ''
    ExceptionLocation = ''
    ExceptionStackTop = ''
    LatestSetupLog = ''
    SetupLogArchivePath = ''
    VsCodeAuditPath = ''
    VsCodeAuditArchivePath = ''
    AuditFilePath = ''
  }
  $runEnvBackup = @{}

  try {
    Info ("setup pass: {0} (tracked_assets_mode={1})" -f $PassName, $TrackedAssetsMode)
    switch ($TrackedAssetsMode) {
      'block' { Set-EnvOverride -Backup $runEnvBackup -Name 'RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS' -Value '0' }
      'clear' { Clear-EnvOverride -Backup $runEnvBackup -Name 'RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS' }
    }
    Set-EnvOverride -Backup $runEnvBackup -Name 'RAYMAN_ALERT_DONE_ENABLED' -Value '0'
    Set-EnvOverride -Backup $runEnvBackup -Name 'RAYMAN_ALERT_TTS_DONE_ENABLED' -Value '0'
    Reset-LastExitCodeCompat
    $hostIsWindows = Test-CopySmokeHostIsWindows
    $powershellExe = Get-Command 'powershell.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    $windowsCompatibleScopes = @('all', 'sandbox', 'host')
    $preferWindowsSetup = (-not $StrictMode) -and (-not $hostIsWindows) -and ($null -ne $powershellExe) -and ($windowsCompatibleScopes -contains $Scope)

    if ($preferWindowsSetup) {
      $setupScriptWin = Convert-PathToWindowsViaWslpath -Path $SetupScript
      $tmpRootWin = Convert-PathToWindowsViaWslpath -Path $TempRoot
      $setupScriptEscaped = ConvertTo-PsSingleQuotedLiteral -Value $setupScriptWin
      $tmpRootEscaped = ConvertTo-PsSingleQuotedLiteral -Value $tmpRootWin
      $timeoutEscaped = ConvertTo-PsSingleQuotedLiteral -Value ([string]$TimeoutSeconds)
      $scopeEscaped = ConvertTo-PsSingleQuotedLiteral -Value $Scope
      if ($StrictMode) {
        $cmd = @(
          "`$env:RAYMAN_PLAYWRIGHT_SETUP_SCOPE='$scopeEscaped'"
          "`$env:RAYMAN_PLAYWRIGHT_TIMEOUT_SECONDS='$timeoutEscaped'"
          "`$env:RAYMAN_MCP_SQLITE_DB_AUTOFIX='1'"
          "`$env:RAYMAN_SETUP_GITHUB_LOGIN='0'"
          "`$env:RAYMAN_SETUP_SKIP_POST_CHECK='1'"
          "`$env:RAYMAN_SETUP_SKIP_ADVANCED_MODULES='1'"
          "& '$setupScriptEscaped' -WorkspaceRoot '$tmpRootEscaped'"
        ) -join '; '
        & $powershellExe.Source -NoProfile -ExecutionPolicy Bypass -Command $cmd | Out-Host
      } else {
        $cmd = @(
          "`$env:RAYMAN_PLAYWRIGHT_REQUIRE='0'"
          "`$env:RAYMAN_PLAYWRIGHT_SETUP_SCOPE='$scopeEscaped'"
          "`$env:RAYMAN_PLAYWRIGHT_TIMEOUT_SECONDS='$timeoutEscaped'"
          "`$env:RAYMAN_MCP_SQLITE_DB_AUTOFIX='1'"
          "`$env:RAYMAN_SETUP_GITHUB_LOGIN='0'"
          "`$env:RAYMAN_SETUP_SKIP_POST_CHECK='1'"
          "`$env:RAYMAN_SETUP_SKIP_ADVANCED_MODULES='1'"
          "& '$setupScriptEscaped' -WorkspaceRoot '$tmpRootEscaped' -SkipReleaseGate"
        ) -join '; '
        & $powershellExe.Source -NoProfile -ExecutionPolicy Bypass -Command $cmd | Out-Host
      }
    } elseif ($StrictMode) {
      & $SetupScript -WorkspaceRoot $TempRoot | Out-Host
    } else {
      & $SetupScript -WorkspaceRoot $TempRoot -SkipReleaseGate | Out-Host
    }
    if ($?) {
      $run.ExitCode = 0
    } else {
      $run.ExitCode = Get-LastExitCodeCompat -Default 1
    }
  } catch {
    $run.Exception = $_.Exception.Message
    try {
      if ($null -ne $_.InvocationInfo -and -not [string]::IsNullOrWhiteSpace([string]$_.InvocationInfo.ScriptName)) {
        $lineInfo = ''
        if ($_.InvocationInfo.ScriptLineNumber -gt 0) {
          $lineInfo = (":{0}" -f $_.InvocationInfo.ScriptLineNumber)
        }
        $run.ExceptionLocation = ("{0}{1}" -f $_.InvocationInfo.ScriptName, $lineInfo)
      }
    } catch {}
    try {
      $stackRaw = [string]$_.ScriptStackTrace
      if (-not [string]::IsNullOrWhiteSpace($stackRaw)) {
        $top = ($stackRaw -split "(\r\n|\n|\r)")[0]
        if (-not [string]::IsNullOrWhiteSpace([string]$top)) {
          $run.ExceptionStackTop = [string]$top.Trim()
        }
      }
    } catch {}
    $run.ExitCode = Get-LastExitCodeCompat -Default 1
    if ($run.ExitCode -eq 0) { $run.ExitCode = 1 }
  } finally {
    $run.FinishedAt = (Get-Date).ToString('o')
    $latestSetupLog = Get-CopySmokeLatestSetupLog -TempRayman $tempRayman
    $latestVsCodeAudit = Get-CopySmokeLatestVsCodeAuditPath -TempRayman $tempRayman
    $archiveDir = Get-CopySmokeSetupRunArchiveDir -TempRoot $TempRoot
    $run.LatestSetupLog = $latestSetupLog
    $run.SetupLogArchivePath = Save-CopySmokeArtifactCopy -SourcePath $latestSetupLog -DestinationPath (Join-Path $archiveDir ("{0}.setup.log" -f $passSlug))
    $run.VsCodeAuditPath = $latestVsCodeAudit
    $run.VsCodeAuditArchivePath = Save-CopySmokeArtifactCopy -SourcePath $latestVsCodeAudit -DestinationPath (Join-Path $archiveDir ("{0}.vscode_windows.json" -f $passSlug))
    Restore-EnvOverrides -Backup $runEnvBackup
    $run.AuditFilePath = Add-CopySmokeSetupRunAudit -TempRoot $TempRoot -RunRecord $run
  }

  return [pscustomobject]$run
}

function Invoke-CopySmokeProjectFastGateContract {
  param(
    [string]$TempRoot,
    [string]$TempRayman
  )

  $result = [ordered]@{
    Ok = $false
    Message = ''
    ReportPath = ''
  }

  $gateScript = Join-Path $TempRayman 'scripts\project\run_project_gate.ps1'
  $reportPath = Join-Path $TempRayman 'runtime\project_gates\fast.report.json'
  $result.ReportPath = $reportPath

  if (-not (Test-Path -LiteralPath $gateScript -PathType Leaf)) {
    $result.Message = ("missing project gate script: {0}" -f $gateScript)
    return [pscustomobject]$result
  }

  try {
    Reset-LastExitCodeCompat
    & $gateScript -WorkspaceRoot $TempRoot -Lane fast
    $gateExitCode = Get-LastExitCodeCompat -Default 0
    if ($gateExitCode -ne 0) {
      $result.Message = ("fast gate returned exit={0}" -f $gateExitCode)
      return [pscustomobject]$result
    }
  } catch {
    $result.Message = $_.Exception.Message
    return [pscustomobject]$result
  }

  if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
    $result.Message = ("fast gate report missing: {0}" -f $reportPath)
    return [pscustomobject]$result
  }

  try {
    $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $overall = [string]$report.overall
    if ([string]::IsNullOrWhiteSpace($overall)) { $overall = 'unknown' }
    $result.Ok = $true
    $result.Message = ("fast gate overall={0}" -f $overall)
    return [pscustomobject]$result
  } catch {
    $result.Message = ("fast gate report parse failed: {0}" -f $_.Exception.Message)
    return [pscustomobject]$result
  }
}

function Get-CopySmokeGitCheckIgnoreResult {
  param(
    [string]$WorkspaceRoot,
    [string]$RelativePath
  )

  $git = Get-Command 'git' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $git -or [string]::IsNullOrWhiteSpace([string]$git.Source)) {
    throw 'git not found for check-ignore'
  }

  Reset-LastExitCodeCompat
  $rawOutput = @(& $git.Source -C $WorkspaceRoot check-ignore -v -- $RelativePath 2>&1)
  $exitCode = Get-LastExitCodeCompat -Default 1
  $matchedSource = ''
  $matchedPattern = ''
  $matchedPath = ''

  foreach ($line in @($rawOutput | ForEach-Object { [string]$_ })) {
    if ($line -match '^(?<source>.+?):(?<line>\d+):(?<pattern>[^\t]+)\t(?<path>.+)$') {
      $matchedSource = [string]$matches['source']
      $matchedPattern = [string]$matches['pattern']
      $matchedPath = [string]$matches['path']
      break
    }
  }

  return [pscustomobject]@{
    relative_path = $RelativePath
    ignored = ($exitCode -eq 0)
    exit_code = $exitCode
    matched_source = $matchedSource
    matched_pattern = $matchedPattern
    matched_path = $matchedPath
    raw_output = (@($rawOutput | ForEach-Object { [string]$_ }) -join "`n")
  }
}

function Resolve-CopySmokePathUnderWorkspace {
  param(
    [string]$WorkspaceRoot,
    [string]$CandidatePath
  )

  if ([string]::IsNullOrWhiteSpace($CandidatePath)) { return '' }
  if ([System.IO.Path]::IsPathRooted($CandidatePath)) { return $CandidatePath }
  return (Join-Path $WorkspaceRoot ($CandidatePath.Replace('/', '\')))
}

function Test-CopySmokeManagedIgnoreFile {
  param(
    [string]$WorkspaceRoot,
    [string]$MatchedSource
  )

  $path = Resolve-CopySmokePathUnderWorkspace -WorkspaceRoot $WorkspaceRoot -CandidatePath $MatchedSource
  if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return $false
  }

  $leaf = [string](Split-Path -Leaf $path)
  if ($leaf -ne '.gitignore' -and $leaf -ne 'exclude') {
    return $false
  }

  $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  return ($raw -match '# RAYMAN:GENERATED:BEGIN' -and $raw -match '# RAYMAN:GENERATED:END')
}

function Get-CopySmokeRelativePath {
  param(
    [string]$BasePath,
    [string]$TargetPath
  )

  $baseNorm = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'
  $targetNorm = [System.IO.Path]::GetFullPath($TargetPath)
  if (Test-Path -LiteralPath $TargetPath -PathType Container) {
    $targetNorm = $targetNorm.TrimEnd('\') + '\'
  }

  $baseUri = [System.Uri]::new($baseNorm)
  $targetUri = [System.Uri]::new($targetNorm)
  $relativeUri = $baseUri.MakeRelativeUri($targetUri)
  if ([string]::IsNullOrWhiteSpace([string]$relativeUri)) {
    return ''
  }

  return [System.Uri]::UnescapeDataString($relativeUri.ToString()).TrimEnd('/')
}

function Get-CopySmokeTrackedSolutionRequirementRelative {
  param([string]$WorkspaceRoot)

  $candidate = Get-ChildItem -LiteralPath $WorkspaceRoot -Force -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name.StartsWith('.') } |
    ForEach-Object {
      $path = Join-Path $_.FullName ($_.Name + '.requirements.md')
      if (Test-Path -LiteralPath $path -PathType Leaf) { $path }
    } |
    Select-Object -First 1

  if ($null -eq $candidate) {
    throw 'tracked solution requirements path not found'
  }

  return (Get-CopySmokeRelativePath -BasePath $WorkspaceRoot -TargetPath ([string]$candidate))
}

function Get-CopySmokeTrackedAgenticDocRelativePaths {
  param(
    [string]$WorkspaceRoot,
    [string]$RequirementsPath = ''
  )

  if ([string]::IsNullOrWhiteSpace($RequirementsPath)) {
    $RequirementsPath = Get-CopySmokeTrackedSolutionRequirementRelative -WorkspaceRoot $WorkspaceRoot
  }

  $solutionDirRel = [System.IO.Path]::GetDirectoryName($RequirementsPath)
  if ([string]::IsNullOrWhiteSpace($solutionDirRel)) {
    throw ("unable to resolve solution dir from requirements path: {0}" -f $RequirementsPath)
  }

  $solutionDir = Join-Path $WorkspaceRoot ($solutionDirRel.Replace('/', '\'))
  $agenticDir = Join-Path $solutionDir 'agentic'
  New-Item -ItemType Directory -Force -Path $agenticDir | Out-Null

  $docs = [ordered]@{
    'copy-smoke.policy.md' = "# copy smoke`n"
    'copy-smoke.contract.json' = "{`"kind`":`"agentic`"}"
  }

  $result = New-Object System.Collections.Generic.List[string]
  foreach ($name in $docs.Keys) {
    $path = Join-Path $agenticDir $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      Set-Content -LiteralPath $path -Value $docs[$name] -Encoding UTF8
    }
    $result.Add((Get-CopySmokeRelativePath -BasePath $WorkspaceRoot -TargetPath $path)) | Out-Null
  }

  return $result.ToArray()
}

function Get-CopySmokeExternalBlockedTargets {
  param([string]$WorkspaceRoot)

  $targets = New-Object System.Collections.Generic.List[string]
  foreach ($candidate in @(
      '.Rayman/VERSION',
      '.SolutionName',
      '.cursorrules',
      '.clinerules',
      '.rayman.env.ps1',
      '.rayman.project.json',
      '.codex/config.toml',
      '.github/copilot-instructions.md',
      '.github/model-policy.md',
      '.github/workflows/rayman-project-fast-gate.yml',
      '.github/workflows/rayman-project-browser-gate.yml',
      '.github/workflows/rayman-project-full-gate.yml',
      '.vscode/tasks.json',
      '.vscode/settings.json',
      '.vscode/launch.json'
    )) {
    if (Test-Path -LiteralPath (Join-Path $WorkspaceRoot $candidate)) {
      $targets.Add($candidate) | Out-Null
    }
  }

  foreach ($dirRel in @('.github/instructions', '.github/agents', '.github/skills', '.github/prompts')) {
    $dirPath = Join-Path $WorkspaceRoot $dirRel
    if (-not (Test-Path -LiteralPath $dirPath -PathType Container)) { continue }
    $sample = Get-ChildItem -LiteralPath $dirPath -Recurse -File -ErrorAction SilentlyContinue |
      Sort-Object FullName |
      Select-Object -First 1
    if ($null -eq $sample) { continue }
    $targets.Add((Get-CopySmokeRelativePath -BasePath $WorkspaceRoot -TargetPath ([string]$sample.FullName))) | Out-Null
  }

  return @($targets | Select-Object -Unique)
}

function Invoke-CopySmokeTrackedNoiseContract {
  param(
    [string]$TempRoot,
    [string]$TempRayman,
    [string]$SetupScript,
    [string]$Scope,
    [int]$TimeoutSeconds
  )

  $result = [ordered]@{
    Ok = $false
    Message = ''
    FailureLog = ''
  }

  $git = Get-Command 'git' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $git -or [string]::IsNullOrWhiteSpace([string]$git.Source)) {
    $result.Message = 'strict 合约缺少 git，无法验证 tracked Rayman assets gate'
    return [pscustomobject]$result
  }

  $requirementsPath = ''
  try {
    $requirementsPath = Get-CopySmokeTrackedSolutionRequirementRelative -WorkspaceRoot $TempRoot
  } catch {
    $result.Message = ("strict 合约未找到 solution requirements 文档：{0}" -f $_.Exception.Message)
    return [pscustomobject]$result
  }

  $allowedDocs = @($requirementsPath) + @(Get-CopySmokeTrackedAgenticDocRelativePaths -WorkspaceRoot $TempRoot -RequirementsPath $requirementsPath)
  foreach ($allowedDoc in @($allowedDocs | Select-Object -Unique)) {
    $ignoreResult = Get-CopySmokeGitCheckIgnoreResult -WorkspaceRoot $TempRoot -RelativePath $allowedDoc
    if ([bool]$ignoreResult.ignored) {
      $result.Message = ("external workspace 文档白名单被误伤：{0}" -f $allowedDoc)
      return [pscustomobject]$result
    }
  }

  $targets = @(Get-CopySmokeExternalBlockedTargets -WorkspaceRoot $TempRoot)
  $requiredGeneratedTargets = @(@(
    '.rayman.project.json',
    '.github/workflows/rayman-project-fast-gate.yml',
    '.github/workflows/rayman-project-browser-gate.yml',
    '.github/workflows/rayman-project-full-gate.yml'
  ) | Where-Object { -not (Test-Path -LiteralPath (Join-Path $TempRoot $_)) })

  if ($targets.Count -le 0) {
    $result.Message = 'strict 合约未找到可加入索引的 Rayman 生成资产'
    return [pscustomobject]$result
  }
  if ($requiredGeneratedTargets.Count -gt 0) {
    $result.Message = ("external workspace 缺少预期生成资产：{0}" -f ($requiredGeneratedTargets -join ', '))
    return [pscustomobject]$result
  }

  foreach ($blockedTarget in @($targets)) {
    $ignoreResult = Get-CopySmokeGitCheckIgnoreResult -WorkspaceRoot $TempRoot -RelativePath $blockedTarget
    if (-not [bool]$ignoreResult.ignored) {
      $result.Message = ("external workspace 应忽略 Rayman 生成资产，但未命中 ignore：{0}" -f $blockedTarget)
      return [pscustomobject]$result
    }
    if (-not (Test-CopySmokeManagedIgnoreFile -WorkspaceRoot $TempRoot -MatchedSource ([string]$ignoreResult.matched_source))) {
      $result.Message = ("ignore 命中了非 Rayman managed block：target={0}, source={1}" -f $blockedTarget, [string]$ignoreResult.matched_source)
      return [pscustomobject]$result
    }
  }

  Reset-LastExitCodeCompat
  & $git.Source -C $TempRoot add -f -- @($targets)
  if (Get-LastExitCodeCompat -Default 1) {
    $result.Message = 'strict 合约执行 git add 失败'
    return [pscustomobject]$result
  }

  $blockedAnalysis = Get-RaymanScmTrackedNoiseAnalysis -WorkspaceRoot $TempRoot
  if (-not [bool]$blockedAnalysis.raymanBlocked) {
    $result.Message = 'tracked assets 加入索引后，SCM 噪声分析未按 external workspace 规则阻断'
    return [pscustomobject]$result
  }

  $blockedRun = Invoke-CopySmokeSetupRun -SetupScript $SetupScript -TempRoot $TempRoot -Scope $Scope -TimeoutSeconds $TimeoutSeconds -StrictMode $true -TrackedAssetsMode 'block' -PassName '02-tracked-assets-block-pass'
  $blockedLog = if (-not [string]::IsNullOrWhiteSpace([string]$blockedRun.SetupLogArchivePath)) { [string]$blockedRun.SetupLogArchivePath } else { [string]$blockedRun.LatestSetupLog }
  $result.FailureLog = $blockedLog
  if ($blockedRun.ExitCode -eq 0) {
    $result.Message = 'tracked Rayman assets 已加入 Git 索引后，setup 仍然成功，未按 external workspace 规则阻断'
    return [pscustomobject]$result
  }
  if ([string]::IsNullOrWhiteSpace($blockedLog) -or -not (Select-String -LiteralPath $blockedLog -Pattern 'tracked_rayman_assets_blocked' -Quiet)) {
    $result.Message = 'setup 虽然阻断，但日志中未命中 tracked_rayman_assets_blocked 标记'
    return [pscustomobject]$result
  }

  $envFile = Join-Path $TempRoot '.rayman.env.ps1'
  if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
    $result.Message = ("workspace env file missing after tracked-assets block: {0}" -f $envFile)
    return [pscustomobject]$result
  }

  $initialAllowMatches = @(Select-String -LiteralPath $envFile -Pattern '(?m)^\s*\$env:RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS\s*=\s*''1''\s*$' -AllMatches -ErrorAction SilentlyContinue)
  if ($initialAllowMatches.Count -ne 0) {
    $result.Message = ("tracked-assets block unexpectedly persisted enabled allow assignment before override (count={0})" -f $initialAllowMatches.Count)
    return [pscustomobject]$result
  }

  $rawEnv = Get-Content -LiteralPath $envFile -Raw -Encoding UTF8
  if ($rawEnv -notmatch '(?m)^\s*\$env:RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS\s*=\s*''1''\s*$') {
    if (-not [string]::IsNullOrEmpty($rawEnv) -and -not $rawEnv.EndsWith("`n")) {
      $rawEnv += "`r`n"
    }
    $rawEnv += "`$env:RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS = '1'`r`n"
    Set-Content -LiteralPath $envFile -Value $rawEnv -Encoding UTF8
  }

  $allowMatches = @(Select-String -LiteralPath $envFile -Pattern '(?m)^\s*\$env:RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS\s*=\s*''1''\s*$' -AllMatches -ErrorAction SilentlyContinue)
  if ($allowMatches.Count -ne 1) {
    $result.Message = ("explicit allow did not persist exactly one enabled assignment (count={0})" -f $allowMatches.Count)
    return [pscustomobject]$result
  }

  $allowedRun = Invoke-CopySmokeSetupRun -SetupScript $SetupScript -TempRoot $TempRoot -Scope $Scope -TimeoutSeconds $TimeoutSeconds -StrictMode $true -TrackedAssetsMode 'clear' -PassName '03-explicit-allow-pass'
  if ($allowedRun.ExitCode -ne 0) {
    $result.Message = ("explicit allow persisted, but rerun still failed（exit={0}）" -f $allowedRun.ExitCode)
    return [pscustomobject]$result
  }

  $stableRun = Invoke-CopySmokeSetupRun -SetupScript $SetupScript -TempRoot $TempRoot -Scope $Scope -TimeoutSeconds $TimeoutSeconds -StrictMode $true -TrackedAssetsMode 'clear' -PassName '04-stable-rerun-pass'
  if ($stableRun.ExitCode -ne 0) {
    $result.Message = ("explicit allow succeeded once, but stable rerun still failed（exit={0}）" -f $stableRun.ExitCode)
    return [pscustomobject]$result
  }

  $result.Ok = $true
  $result.Message = 'fresh copy pass -> docs allowlist verified -> generated workflow/config block verified -> external tracked assets blocked -> explicit allow pass -> stable rerun pass'
  return [pscustomobject]$result
}

function Show-CopySmokeOpenHints([string]$TempRoot) {
  if ([string]::IsNullOrWhiteSpace($TempRoot)) { return }
  $quoted = '"' + $TempRoot.Replace('"','\"') + '"'
  Info ("open hint (PowerShell): ii {0}" -f $quoted)
  if (Test-CopySmokeHostIsWindows) {
    Info ("open hint (Explorer): explorer.exe {0}" -f $quoted)
  }
}

function Build-CopySmokeDebugSummary {
  param(
    [string]$TempRoot,
    [string]$SetupLog,
    [string]$PlaywrightSummary,
    [string]$SetupException,
    [string]$SetupExceptionLocation,
    [string]$SetupExceptionStackTop,
    [int]$ExitCode,
    [string]$Scope,
    [bool]$StrictMode,
    [object]$OwnershipSummary = $null,
    [object[]]$SetupRuns = @(),
    [int[]]$VsCodeAuditCleanupPids = @()
  )

  $releaseGateReport = Join-Path $TempRoot '.Rayman\state\release_gate_report.md'
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('[Rayman copy-smoke debug bundle]') | Out-Null
  $lines.Add(("strict={0}" -f ([string]$StrictMode).ToLowerInvariant())) | Out-Null
  $lines.Add(("scope={0}" -f $Scope)) | Out-Null
  $lines.Add(("exit_code={0}" -f $ExitCode)) | Out-Null
  $lines.Add(("temp_workspace={0}" -f $TempRoot)) | Out-Null
  if (-not [string]::IsNullOrWhiteSpace($SetupLog)) {
    $lines.Add(("setup_log={0}" -f $SetupLog)) | Out-Null
  }
  if (Test-Path -LiteralPath $releaseGateReport -PathType Leaf) {
    $lines.Add(("release_gate_report={0}" -f $releaseGateReport)) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($PlaywrightSummary) -and (Test-Path -LiteralPath $PlaywrightSummary -PathType Leaf)) {
    $lines.Add(("playwright_summary={0}" -f $PlaywrightSummary)) | Out-Null
  }
  $setupRunAuditPath = Get-CopySmokeSetupRunAuditPath -TempRoot $TempRoot
  if (Test-Path -LiteralPath $setupRunAuditPath -PathType Leaf) {
    $lines.Add(("setup_runs_audit={0}" -f $setupRunAuditPath)) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($SetupException)) {
    $lines.Add(("exception={0}" -f $SetupException)) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($SetupExceptionLocation)) {
    $lines.Add(("exception_location={0}" -f $SetupExceptionLocation)) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($SetupExceptionStackTop)) {
    $lines.Add(("exception_stack_top={0}" -f $SetupExceptionStackTop)) | Out-Null
  }
  if ($null -ne $OwnershipSummary) {
    $lines.Add(("sandbox_owner={0}" -f [string]$OwnershipSummary.OwnerDisplay)) | Out-Null
    $lines.Add(("sandbox_baseline_pids={0}" -f (Format-CopySmokePidList $OwnershipSummary.BaselinePids))) | Out-Null
    $lines.Add(("sandbox_live_pids={0}" -f (Format-CopySmokePidList $OwnershipSummary.LivePids))) | Out-Null
    $lines.Add(("sandbox_owned_pids={0}" -f (Format-CopySmokePidList $OwnershipSummary.OwnedPids))) | Out-Null
    $lines.Add(("sandbox_foreign_pids={0}" -f (Format-CopySmokePidList $OwnershipSummary.ForeignPids))) | Out-Null
    $lines.Add(("sandbox_unknown_pids={0}" -f (Format-CopySmokePidList $OwnershipSummary.UnknownPids))) | Out-Null
    $lines.Add(("sandbox_suggest_close_pids={0}" -f (Format-CopySmokePidList $OwnershipSummary.SuggestClosePids))) | Out-Null
    $stopCommand = Format-CopySmokeStopProcessCommand -Pids $OwnershipSummary.SuggestClosePids
    if (-not [string]::IsNullOrWhiteSpace($stopCommand)) {
      $lines.Add(("sandbox_suggest_close_command={0}" -f $stopCommand)) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$OwnershipSummary.OwnerStatePath)) {
      $lines.Add(("sandbox_owner_state={0}" -f [string]$OwnershipSummary.OwnerStatePath)) | Out-Null
    }
  }
  $runIndex = 0
  foreach ($setupRun in @($SetupRuns)) {
    if ($null -eq $setupRun) { continue }
    $runIndex++
    $prefix = ("setup_run_{0}" -f $runIndex)
    if ($setupRun.PSObject.Properties['PassName']) { $lines.Add(("{0}_name={1}" -f $prefix, [string]$setupRun.PassName)) | Out-Null }
    if ($setupRun.PSObject.Properties['ExitCode']) { $lines.Add(("{0}_exit_code={1}" -f $prefix, [int]$setupRun.ExitCode)) | Out-Null }
    if ($setupRun.PSObject.Properties['TrackedAssetsMode']) { $lines.Add(("{0}_tracked_assets_mode={1}" -f $prefix, [string]$setupRun.TrackedAssetsMode)) | Out-Null }
    if ($setupRun.PSObject.Properties['SetupLogArchivePath'] -and -not [string]::IsNullOrWhiteSpace([string]$setupRun.SetupLogArchivePath)) {
      $lines.Add(("{0}_setup_log={1}" -f $prefix, [string]$setupRun.SetupLogArchivePath)) | Out-Null
    }
    if ($setupRun.PSObject.Properties['VsCodeAuditArchivePath'] -and -not [string]::IsNullOrWhiteSpace([string]$setupRun.VsCodeAuditArchivePath)) {
      $lines.Add(("{0}_vscode_audit={1}" -f $prefix, [string]$setupRun.VsCodeAuditArchivePath)) | Out-Null
    }
  }
  if (@($VsCodeAuditCleanupPids).Count -gt 0) {
    $lines.Add(("vscode_audit_cleanup_pids={0}" -f (Format-CopySmokePidList $VsCodeAuditCleanupPids))) | Out-Null
  }

  return ($lines -join [Environment]::NewLine)
}

function Get-CopySmokeDebugBundlePath([string]$TempRoot) {
  return (Join-Path $TempRoot '.Rayman\runtime\copy_smoke_debug_bundle.txt')
}

function Write-CopySmokeDebugBundle {
  param(
    [string]$TempRoot,
    [string]$Text
  )

  if ([string]::IsNullOrWhiteSpace($TempRoot) -or [string]::IsNullOrWhiteSpace($Text)) { return $null }
  $bundlePath = Get-CopySmokeDebugBundlePath -TempRoot $TempRoot
  try {
    $bundleDir = Split-Path -Parent $bundlePath
    if (-not [string]::IsNullOrWhiteSpace($bundleDir) -and -not (Test-Path -LiteralPath $bundleDir -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $bundleDir | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($bundlePath, $Text, $utf8NoBom)
    return $bundlePath
  } catch {
    return $null
  }
}

function Set-CopySmokeDebugClipboard([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  if (-not (Test-CopySmokeHostIsWindows)) { return $false }
  try {
    if (Get-Command 'Set-Clipboard' -ErrorAction SilentlyContinue) {
      Set-Clipboard -Value $Text
      return $true
    }
  } catch {}

  try {
    $clipExe = Get-Command 'clip.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $clipExe -and -not [string]::IsNullOrWhiteSpace([string]$clipExe.Source)) {
      $Text | & $clipExe.Source
      return $true
    }
  } catch {}

  return $false
}

function Resolve-CopySmokeVsCodeClientProcessId([object]$ProcessInfo) {
  if ($null -eq $ProcessInfo) { return 0 }
  $commandLine = ''
  if ($ProcessInfo.PSObject.Properties['command_line']) {
    $commandLine = [string]$ProcessInfo.command_line
  }
  if ([string]::IsNullOrWhiteSpace($commandLine)) { return 0 }
  $match = [regex]::Match($commandLine, '(?:^|\s)--clientProcessId=(\d+)(?:\s|$)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if (-not $match.Success) { return 0 }
  $parsed = 0
  if ([int]::TryParse([string]$match.Groups[1].Value, [ref]$parsed) -and $parsed -gt 0) {
    return $parsed
  }
  return 0
}

function Resolve-CopySmokeArchivedVsCodeAuditCandidatePids([object]$AuditReport) {
  $result = [ordered]@{
    verified_pids = @()
    ambiguous_pids = @()
    proof = 'none'
  }

  if ($null -eq $AuditReport) {
    return [pscustomobject]$result
  }

  $verified = New-Object 'System.Collections.Generic.HashSet[int]'
  $ambiguous = New-Object 'System.Collections.Generic.HashSet[int]'

  if ($AuditReport.PSObject.Properties['owned_pids']) {
    foreach ($pidValue in @($AuditReport.owned_pids)) {
      $pidInt = 0
      if ([int]::TryParse([string]$pidValue, [ref]$pidInt) -and $pidInt -gt 0) {
        [void]$verified.Add($pidInt)
      }
    }
    if ($verified.Count -gt 0) {
      $result.proof = 'owned_pids'
    }
  }

  if ($verified.Count -eq 0 -and $AuditReport.PSObject.Properties['workspace_match']) {
    foreach ($entry in @($AuditReport.workspace_match)) {
      if ($null -eq $entry) { continue }
      $matched = $false
      if ($entry.PSObject.Properties['matched']) {
        $matched = [bool]$entry.matched
      }
      if (-not $matched) { continue }

      $pidInt = 0
      if ([int]::TryParse([string]$entry.pid, [ref]$pidInt) -and $pidInt -gt 0) {
        [void]$verified.Add($pidInt)
      }
    }
    if ($verified.Count -gt 0) {
      $result.proof = 'workspace_match'
    }
  }

  if ($verified.Count -eq 0 -and $AuditReport.PSObject.Properties['new_pids']) {
    foreach ($pidValue in @($AuditReport.new_pids)) {
      $pidInt = 0
      if ([int]::TryParse([string]$pidValue, [ref]$pidInt) -and $pidInt -gt 0) {
        [void]$ambiguous.Add($pidInt)
      }
    }
  }

  $result.verified_pids = @($verified | ForEach-Object { [int]$_ } | Sort-Object -Unique)
  $result.ambiguous_pids = @($ambiguous | ForEach-Object { [int]$_ } | Sort-Object -Unique)
  return [pscustomobject]$result
}

function Get-CopySmokeArchivedVsCodeAuditAnalysis {
  param(
    [string]$WorkspaceRoot,
    [object[]]$SetupRuns = @()
  )

  if (-not (Get-Command Get-RaymanVsCodeProcessSnapshot -ErrorAction SilentlyContinue)) {
    return [pscustomobject]@{
      root_pids = @()
      candidate_pids = @()
      ambiguous_pids = @()
    }
  }

  $candidateSet = New-Object 'System.Collections.Generic.HashSet[int]'
  $ambiguousSet = New-Object 'System.Collections.Generic.HashSet[int]'
  foreach ($setupRun in @($SetupRuns)) {
    if ($null -eq $setupRun) { continue }
    $auditPath = ''
    if ($setupRun.PSObject.Properties['VsCodeAuditArchivePath']) {
      $auditPath = [string]$setupRun.VsCodeAuditArchivePath
    }
    if ([string]::IsNullOrWhiteSpace($auditPath) -or -not (Test-Path -LiteralPath $auditPath -PathType Leaf)) {
      continue
    }
    try {
      $audit = Get-Content -LiteralPath $auditPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      $auditCandidateSet = Resolve-CopySmokeArchivedVsCodeAuditCandidatePids -AuditReport $audit
      foreach ($pidValue in @($auditCandidateSet.verified_pids)) {
        if ([int]$pidValue -gt 0) {
          [void]$candidateSet.Add([int]$pidValue)
        }
      }
      foreach ($pidValue in @($auditCandidateSet.ambiguous_pids)) {
        if ([int]$pidValue -gt 0) {
          [void]$ambiguousSet.Add([int]$pidValue)
        }
      }
    } catch {}
  }

  $candidatePids = @($candidateSet | ForEach-Object { [int]$_ } | Sort-Object -Unique)
  $currentSnapshot = @(Get-RaymanVsCodeProcessSnapshot -WorkspaceRootPath $WorkspaceRoot)
  $candidateSnapshot = @()
  if ($candidatePids.Count -gt 0) {
    $candidateSnapshot = @($currentSnapshot | Where-Object { [int]$_.pid -in $candidatePids })
  }
  $ambiguousPids = @()
  if ($ambiguousSet.Count -gt 0) {
    $ambiguousPids = @($currentSnapshot | Where-Object { [int]$_.pid -in @($ambiguousSet | ForEach-Object { [int]$_ }) } | ForEach-Object { [int]$_.pid } | Sort-Object -Unique)
  }

  if ($candidateSnapshot.Count -eq 0) {
    return [pscustomobject]@{
      root_pids = @()
      candidate_pids = @()
      ambiguous_pids = @($ambiguousPids)
    }
  }

  $candidateLookup = New-Object 'System.Collections.Generic.HashSet[int]'
  foreach ($pidValue in @($candidateSnapshot | ForEach-Object { [int]$_.pid })) {
    [void]$candidateLookup.Add([int]$pidValue)
  }

  $rootPids = New-Object 'System.Collections.Generic.List[int]'
  foreach ($processInfo in $candidateSnapshot) {
    $pidValue = 0
    try { $pidValue = [int]$processInfo.pid } catch { $pidValue = 0 }
    if ($pidValue -le 0) { continue }
    $parentPid = 0
    if ($processInfo.PSObject.Properties['parent_pid']) {
      try { $parentPid = [int]$processInfo.parent_pid } catch { $parentPid = 0 }
    }
    $clientPid = Resolve-CopySmokeVsCodeClientProcessId -ProcessInfo $processInfo
    if ($candidateLookup.Contains($parentPid) -or $candidateLookup.Contains($clientPid)) {
      continue
    }
    $rootPids.Add($pidValue) | Out-Null
  }

  $rootPidResult = if ($rootPids.Count -gt 0) {
    @($rootPids.ToArray() | Sort-Object -Unique)
  } else {
    @($candidateSnapshot | ForEach-Object { [int]$_.pid } | Sort-Object -Unique)
  }

  return [pscustomobject]@{
    root_pids = @($rootPidResult)
    candidate_pids = @($candidateSnapshot | ForEach-Object { [int]$_.pid } | Sort-Object -Unique)
    ambiguous_pids = @($ambiguousPids)
  }
}

function Stop-CopySmokeArchivedVsCodeWindows {
  param(
    [string]$WorkspaceRoot,
    [object[]]$SetupRuns = @(),
    [int[]]$AlreadyCleanedPids = @()
  )

  $analysis = Get-CopySmokeArchivedVsCodeAuditAnalysis -WorkspaceRoot $WorkspaceRoot -SetupRuns $SetupRuns
  $rootPids = @($analysis.root_pids)
  $ambiguousPids = @($analysis.ambiguous_pids)
  if ($ambiguousPids.Count -gt 0) {
    Warn ("skipped ambiguous vscode cleanup: {0}" -f ($ambiguousPids -join ', '))
  }
  if ($rootPids.Count -eq 0) {
    return @()
  }

  $skipSet = New-Object 'System.Collections.Generic.HashSet[int]'
  foreach ($pidValue in @($AlreadyCleanedPids)) {
    if ([int]$pidValue -gt 0) {
      [void]$skipSet.Add([int]$pidValue)
    }
  }

  $cleanupPids = New-Object 'System.Collections.Generic.List[int]'
  foreach ($rootPid in @($rootPids | Sort-Object -Descending)) {
    if ($skipSet.Contains([int]$rootPid)) { continue }
    if (Get-Command Stop-RaymanWorkspaceOwnedProcess -ErrorAction SilentlyContinue) {
      $record = [pscustomobject]@{
        owner_key = ''
        owner_display = 'copy-smoke-archived-audit'
        kind = 'vscode'
        launcher = 'copy-smoke-archived-audit'
        root_pid = [int]$rootPid
      }
      $cleanup = Stop-RaymanWorkspaceOwnedProcess -WorkspaceRootPath $WorkspaceRoot -Record $record -Reason 'copy-smoke-archived-audit'
      if ($null -ne $cleanup -and $cleanup.PSObject.Properties['cleanup_pids']) {
        foreach ($pidValue in @($cleanup.cleanup_pids)) {
          $pidInt = 0
          if ([int]::TryParse([string]$pidValue, [ref]$pidInt) -and $pidInt -gt 0) {
            $cleanupPids.Add($pidInt) | Out-Null
          }
        }
      }
      continue
    }

    try { Stop-Process -Id ([int]$rootPid) -Force -ErrorAction SilentlyContinue } catch {}
    $cleanupPids.Add([int]$rootPid) | Out-Null
  }

  return @($cleanupPids.ToArray() | Sort-Object -Unique)
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$sourceRayman = Join-Path $WorkspaceRoot '.Rayman'
if (-not (Test-Path -LiteralPath $sourceRayman -PathType Container)) {
  Fail ".Rayman not found: $sourceRayman"
}

$tag = Get-Date -Format 'yyyyMMdd_HHmmss'
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("rayman_copy_smoke_{0}_{1}" -f $tag, ([Guid]::NewGuid().ToString('N').Substring(0,8)))
$tmpRayman = Join-Path $tmpRoot '.Rayman'
$setupScript = Join-Path $tmpRayman 'setup.ps1'
$playwrightSummaryPath = Join-Path $tmpRayman 'runtime\playwright.ready.windows.json'

$envBackup = @{}
$setupExitCode = 0
$setupException = ''
$setupExceptionLocation = ''
$setupExceptionStackTop = ''
$script:CopySmokeSetupRuns = New-Object 'System.Collections.Generic.List[object]'
$sandboxBaselinePids = Get-CopySmokeSandboxPidSnapshot
$ownerToken = Get-CopySmokeOwnerToken
$vscodeBaseline = @()
$vscodeOwnerContext = $null
$vscodeReport = $null

if (Get-Command Get-RaymanVsCodeProcessSnapshot -ErrorAction SilentlyContinue) {
  try {
    $vscodeBaseline = @(Get-RaymanVsCodeProcessSnapshot -WorkspaceRootPath $WorkspaceRoot)
    $vscodeOwnerContext = Get-RaymanWorkspaceProcessOwnerContext -WorkspaceRootPath $WorkspaceRoot
  } catch {
    Warn ("vscode baseline snapshot failed: {0}" -f $_.Exception.Message)
    $vscodeBaseline = @()
    $vscodeOwnerContext = $null
  }
}

try {
  New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
  Copy-RaymanTemplateForSmoke -SourceRayman $sourceRayman -TargetRayman $tmpRayman
  Reset-PortableRuntimeAndLogs -RaymanRoot $tmpRayman
  Disable-CopySmokeSlowSetupModules -TempRoot $tmpRoot
  if ($Strict) {
    Initialize-CopySmokeGitRepo -Root $tmpRoot
  }
  Info ("copy smoke workspace: {0}" -f $tmpRoot)
  Info ("copy smoke options: strict={0} scope={1} timeout_seconds={2}" -f ([string]$Strict.IsPresent).ToLowerInvariant(), $Scope, $TimeoutSeconds)
  Info ("sandbox baseline before run: {0}" -f $(if (@($sandboxBaselinePids).Count -gt 0) { @($sandboxBaselinePids) -join ', ' } else { '(none)' }))
  if ($null -ne $ownerToken) {
    Info ("sandbox owner token: {0}" -f ([string]$ownerToken.Source))
  } else {
    Info 'sandbox owner token: (fallback to workspace-root)'
  }
  Info "copied .Rayman (excluded runtime/logs history) and sanitized runtime/logs"

  if (-not (Test-Path -LiteralPath $setupScript -PathType Leaf)) {
    throw ("setup script missing in copied folder: {0}" -f $setupScript)
  }

  Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_PLAYWRIGHT_SETUP_SCOPE' -Value $Scope
  Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_PLAYWRIGHT_TIMEOUT_SECONDS' -Value ([string]$TimeoutSeconds)
  Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_MCP_SQLITE_DB_AUTOFIX' -Value '1'
  Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_SETUP_GITHUB_LOGIN' -Value '0'
  Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_SETUP_SKIP_POST_CHECK' -Value '1'
  Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_SETUP_SKIP_ADVANCED_MODULES' -Value '1'
  Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_HOME' -Value (Join-Path $tmpRoot '.rayman-global')
  Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_SANDBOX_AUTO_CLOSE' -Value '1'
  Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_SANDBOX_KILL_EXISTING' -Value '1'
  if ($null -ne $ownerToken) {
    Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_VSCODE_WINDOW_OWNER' -Value ([string]$ownerToken.Value)
  }
  if (-not $Strict) {
    Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_PLAYWRIGHT_REQUIRE' -Value '0'
    # Non-strict copy smoke validates setup completion, not full browser runtime provisioning.
    Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_PLAYWRIGHT_AUTO_INSTALL' -Value '0'
    Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_SKIP_PWA' -Value '1'
  }

  $setupRun = Invoke-CopySmokeSetupRun -SetupScript $setupScript -TempRoot $tmpRoot -Scope $Scope -TimeoutSeconds $TimeoutSeconds -StrictMode $Strict.IsPresent -TrackedAssetsMode 'block' -PassName '01-fresh-pass'
  $setupExitCode = [int]$setupRun.ExitCode
  $setupException = [string]$setupRun.Exception
  $setupExceptionLocation = [string]$setupRun.ExceptionLocation
  $setupExceptionStackTop = [string]$setupRun.ExceptionStackTop

  if ($setupExitCode -eq 0 -and $Strict) {
    $trackedNoiseContract = Invoke-CopySmokeTrackedNoiseContract -TempRoot $tmpRoot -TempRayman $tmpRayman -SetupScript $setupScript -Scope $Scope -TimeoutSeconds $TimeoutSeconds
    if (-not [bool]$trackedNoiseContract.Ok) {
      $setupExitCode = 13
      $setupException = ("copy-smoke tracked-noise contract failed: {0}" -f [string]$trackedNoiseContract.Message)
      $setupExceptionLocation = 'copy_smoke_contract'
      if (-not [string]::IsNullOrWhiteSpace([string]$trackedNoiseContract.FailureLog)) {
        $setupExceptionStackTop = [string]$trackedNoiseContract.FailureLog
      }
    } else {
      Ok ("tracked Rayman assets gate verified: {0}" -f [string]$trackedNoiseContract.Message)
      $projectFastGateContract = Invoke-CopySmokeProjectFastGateContract -TempRoot $tmpRoot -TempRayman $tmpRayman
      if (-not [bool]$projectFastGateContract.Ok) {
        $setupExitCode = 14
        $setupException = ("copy-smoke project fast-gate contract failed: {0}" -f [string]$projectFastGateContract.Message)
        $setupExceptionLocation = 'copy_smoke_project_fast_gate'
      } else {
        Ok ("project fast gate verified: {0}" -f [string]$projectFastGateContract.Message)
        if (-not [string]::IsNullOrWhiteSpace([string]$projectFastGateContract.ReportPath)) {
          Info ("project fast gate report: {0}" -f [string]$projectFastGateContract.ReportPath)
        }
      }
    }
  }
} catch {
  $setupException = $_.Exception.Message
  try {
    if ($null -ne $_.InvocationInfo -and -not [string]::IsNullOrWhiteSpace([string]$_.InvocationInfo.ScriptName)) {
      $lineInfo = ''
      if ($_.InvocationInfo.ScriptLineNumber -gt 0) {
        $lineInfo = (":{0}" -f $_.InvocationInfo.ScriptLineNumber)
      }
      $setupExceptionLocation = ("{0}{1}" -f $_.InvocationInfo.ScriptName, $lineInfo)
    }
  } catch {}
  try {
    $stackRaw = [string]$_.ScriptStackTrace
    if (-not [string]::IsNullOrWhiteSpace($stackRaw)) {
      $top = ($stackRaw -split "(\r\n|\n|\r)")[0]
      if (-not [string]::IsNullOrWhiteSpace([string]$top)) {
        $setupExceptionStackTop = [string]$top.Trim()
      }
    }
  } catch {}
  $setupExitCode = Get-LastExitCodeCompat -Default 1
  if ($setupExitCode -eq 0) { $setupExitCode = 1 }
} finally {
  Restore-EnvOverrides -Backup $envBackup
  Stop-CopySmokeSandboxProcesses -Reason 'copy smoke finally' -PreservePids $sandboxBaselinePids
}

$setupLog = ''
$vscodeAuditCleanupPids = @()
$ownershipSummary = Get-CopySmokeSandboxOwnershipSummary -TempRoot $tmpRoot -TempRayman $tmpRayman -BaselinePids $sandboxBaselinePids -OwnerToken $ownerToken
$setupLog = Get-CopySmokeLatestSetupLog -TempRayman $tmpRayman
if (Get-Command Sync-RaymanWorkspaceVsCodeWindows -ErrorAction SilentlyContinue) {
  try {
    $cleanupVsCode = ($setupExitCode -ne 0) -or (-not $KeepTemp)
    $vscodeReport = Sync-RaymanWorkspaceVsCodeWindows `
      -WorkspaceRootPath $WorkspaceRoot `
      -BaselineSnapshot $vscodeBaseline `
      -WorkspaceRoots @($tmpRoot) `
      -OwnerContext $vscodeOwnerContext `
      -CleanupOwned:$cleanupVsCode `
      -CleanupReason $(if ($setupExitCode -ne 0) { 'copy-smoke-failed' } else { 'copy-smoke-temp-cleanup' }) `
      -Source 'copy-smoke'
    if ($null -ne $vscodeReport -and @($vscodeReport.new_pids).Count -gt 0) {
      Info ("vscode new pids: {0}" -f (@($vscodeReport.new_pids) -join ', '))
    }
    if ($null -ne $vscodeReport -and @($vscodeReport.cleanup_pids).Count -gt 0) {
      Info ("vscode cleanup pids: {0}" -f (@($vscodeReport.cleanup_pids) -join ', '))
    }
    if ($cleanupVsCode) {
      $vscodeAuditCleanupPids = @(Stop-CopySmokeArchivedVsCodeWindows -WorkspaceRoot $WorkspaceRoot -SetupRuns @($script:CopySmokeSetupRuns.ToArray()) -AlreadyCleanedPids @($vscodeReport.cleanup_pids))
      if ($vscodeAuditCleanupPids.Count -gt 0) {
        Info ("vscode archived-audit cleanup pids: {0}" -f ($vscodeAuditCleanupPids -join ', '))
      }
    }
    if (Get-Command Get-RaymanVsCodeWindowAuditPath -ErrorAction SilentlyContinue) {
      Info ("vscode report: {0}" -f (Get-RaymanVsCodeWindowAuditPath -WorkspaceRootPath $WorkspaceRoot))
    }
  } catch {
    Warn ("vscode audit failed: {0}" -f $_.Exception.Message)
  }
}

if ($setupExitCode -eq 0) {
  try {
    $copiedRaymanCli = Join-Path $tmpRayman 'rayman.ps1'
    if (Test-Path -LiteralPath $copiedRaymanCli -PathType Leaf) {
      Reset-LastExitCodeCompat
      & $copiedRaymanCli 'codex' 'status' '--json' '-WorkspaceRoot' $tmpRoot | Out-Null
      $copiedCodexStatusExit = Get-LastExitCodeCompat -Default 1
      if ($copiedCodexStatusExit -ne 0) {
        throw ("copied rayman codex status failed (exit={0})" -f $copiedCodexStatusExit)
      }

      Reset-LastExitCodeCompat
      & $copiedRaymanCli 'codex' 'list' '--json' '-WorkspaceRoot' $tmpRoot | Out-Null
      $copiedCodexListExit = Get-LastExitCodeCompat -Default 1
      if ($copiedCodexListExit -ne 0) {
        throw ("copied rayman codex list failed (exit={0})" -f $copiedCodexListExit)
      }

      Ok 'copied rayman codex status/list smoke passed'
    }
  } catch {
    $setupExitCode = 15
    $setupException = $_.Exception.Message
    $setupExceptionLocation = 'copy_smoke_codex_cli'
  }

  if ($setupExitCode -eq 0) {
    Write-CopySmokeTelemetry -ExitCode 0
    Ok ("copy smoke passed (strict={0}, scope={1})" -f ([string]$Strict.IsPresent).ToLowerInvariant(), $Scope)
    if (-not [string]::IsNullOrWhiteSpace($setupLog)) {
      Info ("setup log: {0}" -f $setupLog)
    }

    if ($KeepTemp) {
      Info ("kept temp workspace: {0}" -f $tmpRoot)
      Show-CopySmokeOpenHints -TempRoot $tmpRoot
    } else {
      try {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        Info "temp workspace cleaned"
      } catch {
        Warn ("failed to clean temp workspace: {0}" -f $_.Exception.Message)
        Info ("temp workspace: {0}" -f $tmpRoot)
      }
    }
    exit 0
  }
}

Warn ("copy smoke failed (exit={0}, scope={1})" -f $setupExitCode, $Scope)
if (-not [string]::IsNullOrWhiteSpace($setupException)) {
  Warn ("exception: {0}" -f $setupException)
}
if (-not [string]::IsNullOrWhiteSpace($setupExceptionLocation)) {
  Warn ("exception location: {0}" -f $setupExceptionLocation)
}
if (-not [string]::IsNullOrWhiteSpace($setupExceptionStackTop)) {
  Warn ("exception stack (top): {0}" -f $setupExceptionStackTop)
}
if (-not [string]::IsNullOrWhiteSpace($setupLog)) {
  Warn ("setup log: {0}" -f $setupLog)
}
if (Test-Path -LiteralPath $playwrightSummaryPath -PathType Leaf) {
  Warn ("playwright summary: {0}" -f $playwrightSummaryPath)
}
Write-CopySmokeSandboxOwnershipSummary -Summary $ownershipSummary
Warn ("temp workspace kept for inspection: {0}" -f $tmpRoot)
Show-CopySmokeOpenHints -TempRoot $tmpRoot
$debugBundle = Build-CopySmokeDebugSummary -TempRoot $tmpRoot -SetupLog $setupLog -PlaywrightSummary $playwrightSummaryPath -SetupException $setupException -SetupExceptionLocation $setupExceptionLocation -SetupExceptionStackTop $setupExceptionStackTop -ExitCode $setupExitCode -Scope $Scope -StrictMode $Strict.IsPresent -OwnershipSummary $ownershipSummary -SetupRuns @($script:CopySmokeSetupRuns.ToArray()) -VsCodeAuditCleanupPids $vscodeAuditCleanupPids
$debugBundlePath = Write-CopySmokeDebugBundle -TempRoot $tmpRoot -Text $debugBundle
if (-not [string]::IsNullOrWhiteSpace($debugBundlePath)) {
  Warn ("debug bundle: {0}" -f $debugBundlePath)
}
if (Set-CopySmokeDebugClipboard -Text $debugBundle) {
  Ok '已将关键排障路径复制到剪贴板（可直接粘贴给同事/AI）'
} else {
  Warn '未能写入剪贴板，请手动复制上面的路径信息。'
}
if ($OpenOnFail -and (Test-CopySmokeHostIsWindows)) {
  try {
    Start-Process -FilePath 'explorer.exe' -ArgumentList @($tmpRoot) | Out-Null
    Info 'opened temp workspace in Explorer (OpenOnFail=1)'
  } catch {
    Warn ("failed to open Explorer automatically: {0}" -f $_.Exception.Message)
  }
}
Write-CopySmokeTelemetry -ExitCode $setupExitCode
exit $setupExitCode
