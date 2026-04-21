param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [ValidateSet('fast', 'browser', 'full')][string]$Lane = 'fast',
  [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\..\common.ps1')
. (Join-Path $PSScriptRoot 'project_gate.lib.ps1')
$workspaceOwnershipPath = Join-Path $PSScriptRoot '..\utils\workspace_process_ownership.ps1'
if (Test-Path -LiteralPath $workspaceOwnershipPath -PathType Leaf) {
  . $workspaceOwnershipPath -NoMain
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$workspaceKind = Get-RaymanWorkspaceKind -WorkspaceRoot $WorkspaceRoot
$runtimeDir = Get-RaymanProjectGateRuntimeDir -WorkspaceRoot $WorkspaceRoot
$logDir = Get-RaymanProjectGateLogDir -WorkspaceRoot $WorkspaceRoot
if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
}
if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}

$script:RaymanProjectGateTimeoutSeconds = 0
$timeoutRaw = [string][Environment]::GetEnvironmentVariable('RAYMAN_PROJECT_GATE_TIMEOUT_SECONDS')
$timeoutParsed = 0
if (-not [string]::IsNullOrWhiteSpace($timeoutRaw) -and [int]::TryParse($timeoutRaw.Trim(), [ref]$timeoutParsed) -and $timeoutParsed -gt 0) {
  $script:RaymanProjectGateTimeoutSeconds = [Math]::Min($timeoutParsed, 86400)
}

function Resolve-RaymanCommandPath {
  param([string[]]$Names)

  foreach ($name in @($Names)) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
      return [string]$cmd.Source
    }
  }
  return $null
}

function Resolve-RaymanBashRunner {
  $override = [string][Environment]::GetEnvironmentVariable('RAYMAN_BASH_PATH')
  if (-not [string]::IsNullOrWhiteSpace($override) -and (Test-Path -LiteralPath $override -PathType Leaf)) {
    return [pscustomobject]@{
      path = (Resolve-Path -LiteralPath $override).Path
      mode = 'bash'
    }
  }

  if (Test-RaymanWindowsPlatform) {
    $wslPath = Resolve-RaymanCommandPath -Names @('wsl.exe', 'wsl')
    if (-not [string]::IsNullOrWhiteSpace($wslPath)) {
      return [pscustomobject]@{
        path = $wslPath
        mode = 'wsl'
      }
    }
  }

  $bashPath = Resolve-RaymanCommandPath -Names @('bash', 'bash.exe')
  if (-not [string]::IsNullOrWhiteSpace($bashPath)) {
    return [pscustomobject]@{
      path = $bashPath
      mode = 'bash'
    }
  }

  return $null
}

function Convert-RaymanPathToBashCompat {
  param(
    [string]$PathValue,
    [ValidateSet('bash', 'wsl')][string]$Mode = 'wsl'
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
  if (-not (Test-RaymanWindowsPlatform)) { return $PathValue }

  $fullPath = $PathValue
  try {
    $fullPath = [System.IO.Path]::GetFullPath($PathValue)
  } catch {}

  if ($Mode -eq 'wsl' -and $fullPath -match '^([A-Za-z]):\\(.*)$') {
    $drive = [string]$Matches[1].ToLowerInvariant()
    $rest = [string]$Matches[2]
    if ([string]::IsNullOrWhiteSpace($rest)) {
      return ("/mnt/{0}" -f $drive)
    }
    return ("/mnt/{0}/{1}" -f $drive, ($rest -replace '\\', '/'))
  }

  return ($fullPath -replace '\\', '/')
}

function Convert-RaymanToBashSingleQuotedLiteral([string]$Value) {
  if ($null -eq $Value) { return "''" }
  return ("'" + ([string]$Value).Replace("'", "'""'""'") + "'")
}

function ConvertTo-RaymanProjectGateCleanupDetail {
  param([object]$Cleanup)

  if ($null -eq $Cleanup) { return '' }

  $parts = New-Object System.Collections.Generic.List[string]
  $resultText = if ($Cleanup.PSObject.Properties['cleanup_result']) { [string]$Cleanup.cleanup_result } else { '' }
  if (-not [string]::IsNullOrWhiteSpace($resultText)) {
    $parts.Add(("process_cleanup={0}" -f $resultText)) | Out-Null
  }

  foreach ($entry in @(
      @{ name = 'cleanup_roots'; values = @($Cleanup.cleanup_root_pids) }
      @{ name = 'cleanup_pids'; values = @($Cleanup.cleanup_pids) }
      @{ name = 'alive_pids'; values = @($Cleanup.alive_pids) }
      @{ name = 'launcher_tree'; values = @($Cleanup.launcher_tree_pids) }
      @{ name = 'matched_pids'; values = @($Cleanup.matched_pids) }
    )) {
    $values = @($entry.values | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    if ($values.Count -gt 0) {
      $parts.Add(("{0}={1}" -f [string]$entry.name, ($values -join ','))) | Out-Null
    }
  }

  return ($parts -join '; ')
}

function Get-RaymanProjectGateCleanupLogLines {
  param([object]$Cleanup)

  if ($null -eq $Cleanup) { return @() }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('[rayman-project-gate] process cleanup summary') | Out-Null
  $lines.Add((ConvertTo-RaymanProjectGateCleanupDetail -Cleanup $Cleanup)) | Out-Null
  foreach ($cleanupResult in @($Cleanup.cleanup_results)) {
    if ($null -eq $cleanupResult) { continue }
    $lines.Add((
        '  root_pid={0}; result={1}; cleanup_pids={2}; alive_pids={3}; reason={4}' -f
        [string]$cleanupResult.root_pid,
        [string]$cleanupResult.cleanup_result,
        ((@($cleanupResult.cleanup_pids) | ForEach-Object { [string]$_ }) -join ','),
        ((@($cleanupResult.alive_pids) | ForEach-Object { [string]$_ }) -join ','),
        [string]$cleanupResult.cleanup_reason
      )) | Out-Null
  }
  return @($lines.ToArray() | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}

function Invoke-RaymanGateProcess {
  param(
    [string]$FilePath,
    [string[]]$ArgumentList = @(),
    [string]$WorkingDirectory,
    [string]$LogPath,
    [hashtable]$EnvironmentOverrides = @{}
  )

  $result = [ordered]@{
    ok = $false
    exit_code = 0
    log_path = $LogPath
    detail = ''
    stdout = ''
    stderr = ''
    timed_out = $false
    cleanup = $null
  }

  $backup = @{}
  foreach ($name in $EnvironmentOverrides.Keys) {
    $backup[$name] = [string][Environment]::GetEnvironmentVariable($name)
    [Environment]::SetEnvironmentVariable($name, [string]$EnvironmentOverrides[$name])
  }

  $stdoutPath = Join-Path $logDir (([System.IO.Path]::GetFileNameWithoutExtension($LogPath)) + '.stdout.tmp')
  $stderrPath = Join-Path $logDir (([System.IO.Path]::GetFileNameWithoutExtension($LogPath)) + '.stderr.tmp')
  $proc = $null
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $cleanupState = [pscustomobject]@{
    invoked = $false
  }
  $cleanupAvailable = (
    (Test-RaymanWindowsPlatform) -and
    -not [string]::IsNullOrWhiteSpace($WorkingDirectory) -and
    (Get-Command Get-RaymanWorkspaceProcessSnapshot -ErrorAction SilentlyContinue) -and
    (Get-Command Invoke-RaymanWorkspaceOwnedProcessCleanupFromBaseline -ErrorAction SilentlyContinue)
  )
  $baselineSnapshot = @()
  $baselineCapturedAtUtc = [datetime]::MinValue

  function Merge-ProjectGateBaselineSnapshotItems {
    param([object[]]$Items = @())

    $merged = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($Items)) {
      if ($null -eq $item) { continue }
      $key = ''
      if (Get-Command Get-RaymanWorkspaceProcessSnapshotKey -ErrorAction SilentlyContinue) {
        $key = Get-RaymanWorkspaceProcessSnapshotKey -ProcessInfo $item
      }
      if ([string]::IsNullOrWhiteSpace([string]$key) -and $item.PSObject.Properties['pid']) {
        $key = ('pid:{0}' -f [string]$item.pid)
      }
      if ([string]::IsNullOrWhiteSpace([string]$key) -or $seen.Add($key)) {
        $merged.Add($item) | Out-Null
      }
    }

    return @($merged.ToArray())
  }

  function Invoke-ProjectGateCleanupOnce {
    if ([bool]$cleanupState.invoked -or -not $cleanupAvailable -or [string]::IsNullOrWhiteSpace($WorkingDirectory) -or $null -eq $proc) {
      return
    }
    $cleanupState.invoked = $true
    try {
      $result.cleanup = Invoke-RaymanWorkspaceOwnedProcessCleanupFromBaseline -WorkspaceRootPath $WorkingDirectory -BaselineSnapshot @($baselineSnapshot) -BaselineCapturedAtUtc $baselineCapturedAtUtc -LauncherProcessId ([int]$proc.Id) -OwnedKind 'project-gate' -OwnedLauncher 'project-gate' -OwnedCommand ((@([string]$FilePath) + @($ArgumentList | ForEach-Object { [string]$_ })) -join ' ') -CleanupReason 'project-gate'
    } catch {
      $result.cleanup = [pscustomobject]@{
        cleanup_required = $true
        cleanup_succeeded = $false
        cleanup_result = 'cleanup_failed'
        cleanup_root_pids = @()
        cleanup_pids = @()
        launcher_tree_pids = @()
        matched_pids = @()
        alive_pids = @()
        cleanup_results = @()
      }
      if ([string]::IsNullOrWhiteSpace([string]$result.detail)) {
        $result.detail = $_.Exception.Message
      } else {
        $result.detail = ("{0}; cleanup_error={1}" -f [string]$result.detail, $_.Exception.Message)
      }
    }
  }

  try {
    if ($cleanupAvailable) {
      try {
        $baselineCapturedAtUtc = [datetime]::UtcNow
        $baselineSnapshot = @(Get-RaymanWorkspaceProcessSnapshot -WorkspaceRootPath $WorkingDirectory)
        Start-Sleep -Milliseconds 200
        $baselineSnapshot = Merge-ProjectGateBaselineSnapshotItems -Items @(
          @($baselineSnapshot) +
          @(Get-RaymanWorkspaceProcessSnapshot -WorkspaceRootPath $WorkingDirectory)
        )
      } catch {
        $baselineSnapshot = @()
      }
    }

    $startParams = @{
      FilePath = $FilePath
      ArgumentList = @($ArgumentList)
      WorkingDirectory = $WorkingDirectory
      PassThru = $true
      RedirectStandardOutput = $stdoutPath
      RedirectStandardError = $stderrPath
    }

    $proc = Start-Process @startParams
    if ($script:RaymanProjectGateTimeoutSeconds -gt 0) {
      $completed = $proc.WaitForExit($script:RaymanProjectGateTimeoutSeconds * 1000)
      if (-not $completed) {
        $result.timed_out = $true
      } else {
        $proc.WaitForExit()
      }
    } else {
      $proc.WaitForExit()
    }

    Invoke-ProjectGateCleanupOnce
    if ($result.timed_out -and $null -ne $proc -and -not $proc.HasExited) {
      try { $proc.Kill() } catch {}
      try { $proc.WaitForExit() } catch {}
    }
    $watch.Stop()

    $stdout = ''
    $stderr = ''
    if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
      $stdout = Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8
    }
    if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
      $stderr = Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8
    }

    $sections = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
      $sections.Add($stdout.TrimEnd()) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
      if ($sections.Count -gt 0) { $sections.Add('') | Out-Null }
      $sections.Add($stderr.TrimEnd()) | Out-Null
    }
    $cleanupLogLines = @(Get-RaymanProjectGateCleanupLogLines -Cleanup $result.cleanup)
    if ($cleanupLogLines.Count -gt 0) {
      if ($sections.Count -gt 0) { $sections.Add('') | Out-Null }
      foreach ($line in $cleanupLogLines) {
        $sections.Add([string]$line) | Out-Null
      }
    }
    Set-Content -LiteralPath $LogPath -Value ($sections -join "`n") -Encoding UTF8

    $commandExitCode = if ($result.timed_out) { 124 } else { [int]$proc.ExitCode }
    $cleanupOk = ($null -eq $result.cleanup -or [bool]$result.cleanup.cleanup_succeeded)
    $result.ok = ($commandExitCode -eq 0 -and -not $result.timed_out -and $cleanupOk)
    $result.exit_code = if (-not $cleanupOk -and $commandExitCode -eq 0) { 1 } else { $commandExitCode }
    $result.stdout = $stdout
    $result.stderr = $stderr
    $detailParts = New-Object System.Collections.Generic.List[string]
    $detailParts.Add(("exit={0}" -f $commandExitCode)) | Out-Null
    if ($result.timed_out) {
      $detailParts.Add(("timed_out=true")) | Out-Null
      $detailParts.Add(("timeout_seconds={0}" -f $script:RaymanProjectGateTimeoutSeconds)) | Out-Null
    }
    $detailParts.Add(("duration_seconds={0}" -f [math]::Round($watch.Elapsed.TotalSeconds, 3))) | Out-Null
    $cleanupDetail = ConvertTo-RaymanProjectGateCleanupDetail -Cleanup $result.cleanup
    if (-not [string]::IsNullOrWhiteSpace($cleanupDetail)) {
      $detailParts.Add($cleanupDetail) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$result.detail)) {
      $detailParts.Add([string]$result.detail) | Out-Null
    }
    $result.detail = ($detailParts.ToArray() -join '; ')
    return [pscustomobject]$result
  } catch {
    Invoke-ProjectGateCleanupOnce
    if ($null -ne $proc -and -not $proc.HasExited) {
      try { $proc.Kill() } catch {}
      try { $proc.WaitForExit() } catch {}
    }
    $watch.Stop()
    $message = $_.Exception.Message
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($message) | Out-Null
    $cleanupLogLines = @(Get-RaymanProjectGateCleanupLogLines -Cleanup $result.cleanup)
    if ($cleanupLogLines.Count -gt 0) {
      $lines.Add('') | Out-Null
      foreach ($line in $cleanupLogLines) {
        $lines.Add([string]$line) | Out-Null
      }
    }
    Set-Content -LiteralPath $LogPath -Value ($lines -join "`n") -Encoding UTF8
    $result.exit_code = if ($result.timed_out) { 124 } else { 1 }
    $cleanupDetail = ConvertTo-RaymanProjectGateCleanupDetail -Cleanup $result.cleanup
    if ([string]::IsNullOrWhiteSpace($cleanupDetail)) {
      $result.detail = $message
    } else {
      $result.detail = ("{0}; {1}" -f $message, $cleanupDetail)
    }
    return [pscustomobject]$result
  } finally {
    foreach ($name in $backup.Keys) {
      [Environment]::SetEnvironmentVariable($name, [string]$backup[$name])
    }
    foreach ($tmpPath in @($stdoutPath, $stderrPath)) {
      if (Test-Path -LiteralPath $tmpPath -PathType Leaf) {
        Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
      }
    }
    try {
      if ($null -ne $proc) {
        $proc.Dispose()
      }
    } catch {}
  }
}

function Invoke-RaymanShellCommandCheck {
  param(
    [string]$Key,
    [string]$Name,
    [string]$CommandText,
    [string]$Action,
    [string]$LogName,
    [ValidateSet('source', 'external')][string]$WorkspaceKind = 'external',
    [switch]$WarnWhenEmpty
  )

  $logPath = Join-Path $logDir $LogName
  if ([string]::IsNullOrWhiteSpace($CommandText)) {
    return (New-RaymanProjectGateEmptyCommandCheck -Key $Key -Name $Name -Action $Action -LogPath $logPath -WorkspaceKind $WorkspaceKind -WarnWhenEmpty:$WarnWhenEmpty)
  }

  $runnerPath = $null
  $arguments = @()
  $tempScriptPath = $null
  try {
    if ((Test-RaymanWindowsPlatform) -or $WorkspaceKind -eq 'source') {
      $runnerPath = Resolve-RaymanPowerShellHost
      if ([string]::IsNullOrWhiteSpace($runnerPath)) {
        return (New-RaymanProjectGateCheck -Key $Key -Name $Name -Status FAIL -Detail 'PowerShell host not found' -Action $Action -Command $CommandText -LogPath $logPath -ExitCode 2)
      }
      $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $CommandText)
    } else {
      $runnerPath = Resolve-RaymanCommandPath -Names @('bash')
      if ([string]::IsNullOrWhiteSpace($runnerPath)) {
        return (New-RaymanProjectGateCheck -Key $Key -Name $Name -Status FAIL -Detail 'bash not found' -Action $Action -Command $CommandText -LogPath $logPath -ExitCode 2)
      }
      $tempScriptPath = Join-Path $logDir (([System.IO.Path]::GetFileNameWithoutExtension($LogName)) + '.command.tmp.sh')
      Set-Content -LiteralPath $tempScriptPath -Value @(
        '#!/usr/bin/env bash'
        'set -euo pipefail'
        $CommandText
      ) -Encoding UTF8
      $arguments = @($tempScriptPath)
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $run = Invoke-RaymanGateProcess -FilePath $runnerPath -ArgumentList $arguments -WorkingDirectory $WorkspaceRoot -LogPath $logPath
    $watch.Stop()
    $status = if ([bool]$run.ok) { 'PASS' } else { 'FAIL' }
    $detail = if ([string]::IsNullOrWhiteSpace([string]$run.detail)) { "exit=$($run.exit_code)" } else { [string]$run.detail }
    return (New-RaymanProjectGateCheck -Key $Key -Name $Name -Status $status -Detail $detail -Action $Action -Command $CommandText -LogPath $logPath -ExitCode ([int]$run.exit_code) -DurationSeconds $watch.Elapsed.TotalSeconds)
  } finally {
    if (-not [string]::IsNullOrWhiteSpace($tempScriptPath) -and (Test-Path -LiteralPath $tempScriptPath -PathType Leaf)) {
      Remove-Item -LiteralPath $tempScriptPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Join-RaymanCommandSequence {
  param([string[]]$Commands)

  $items = @($Commands | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  if ($items.Count -eq 0) {
    return ''
  }

  if (Test-RaymanWindowsPlatform) {
    $segments = New-Object System.Collections.Generic.List[string]
    foreach ($item in $items) {
      $segments.Add([string]$item) | Out-Null
      $segments.Add("if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }") | Out-Null
    }
    return ($segments -join '; ')
  }

  return ($items -join ' && ')
}

function Invoke-RaymanScriptCheck {
  param(
    [string]$Key,
    [string]$Name,
    [ValidateSet('bash', 'pwsh')][string]$Runner,
    [string]$ScriptPath,
    [string[]]$Arguments = @(),
    [string]$Action,
    [string]$LogName,
    [hashtable]$EnvironmentOverrides = @{}
  )

  $logPath = Join-Path $logDir $LogName
  if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    return (New-RaymanProjectGateCheck -Key $Key -Name $Name -Status FAIL -Detail ("missing script: {0}" -f $ScriptPath) -Action $Action -LogPath $logPath -ExitCode 2)
  }

  $runnerPath = $null
  $runnerMode = ''
  $argumentList = @()
  $commandText = ''
  if ($Runner -eq 'bash') {
    $bashRunner = Resolve-RaymanBashRunner
    if ($null -eq $bashRunner -or [string]::IsNullOrWhiteSpace([string]$bashRunner.path)) {
      return (New-RaymanProjectGateCheck -Key $Key -Name $Name -Status FAIL -Detail 'bash not found' -Action $Action -LogPath $logPath -ExitCode 2)
    }
    $runnerPath = [string]$bashRunner.path
    $runnerMode = [string]$bashRunner.mode
    if (Test-RaymanWindowsPlatform) {
      $workspaceBash = Convert-RaymanPathToBashCompat -PathValue $WorkspaceRoot -Mode $(if ($runnerMode -eq 'wsl') { 'wsl' } else { 'bash' })
      $scriptBash = Convert-RaymanPathToBashCompat -PathValue $ScriptPath -Mode $(if ($runnerMode -eq 'wsl') { 'wsl' } else { 'bash' })
      $bashArgs = New-Object System.Collections.Generic.List[string]
      foreach ($arg in @($Arguments)) {
        $argValue = [string]$arg
        if ($argValue -match '^[A-Za-z]:[\\/]') {
          $argValue = Convert-RaymanPathToBashCompat -PathValue $argValue -Mode $(if ($runnerMode -eq 'wsl') { 'wsl' } else { 'bash' })
        }
        $bashArgs.Add((Convert-RaymanToBashSingleQuotedLiteral -Value $argValue)) | Out-Null
      }
      $bashCommand = "cd $(Convert-RaymanToBashSingleQuotedLiteral -Value $workspaceBash); bash $(Convert-RaymanToBashSingleQuotedLiteral -Value $scriptBash)"
      if ($bashArgs.Count -gt 0) {
        $bashCommand += (' ' + ($bashArgs.ToArray() -join ' '))
      }
      if ($runnerMode -eq 'wsl') {
        $argumentList = @('-e', 'bash', '-lc', $bashCommand)
        $commandText = ("wsl.exe -e bash -lc {0}" -f (Convert-RaymanToBashSingleQuotedLiteral -Value $bashCommand))
      } else {
        $argumentList = @('-lc', $bashCommand)
        $commandText = ("bash -lc {0}" -f (Convert-RaymanToBashSingleQuotedLiteral -Value $bashCommand))
      }
    } else {
      $argumentList = @($ScriptPath) + @($Arguments)
      $commandText = "bash $ScriptPath $($Arguments -join ' ')".Trim()
    }
  } else {
    $runnerPath = Resolve-RaymanPowerShellHost
    if ([string]::IsNullOrWhiteSpace($runnerPath)) {
      return (New-RaymanProjectGateCheck -Key $Key -Name $Name -Status FAIL -Detail 'PowerShell host not found' -Action $Action -LogPath $logPath -ExitCode 2)
    }
    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($Arguments)
    $commandText = "$runnerPath -File $ScriptPath $($Arguments -join ' ')".Trim()
  }

  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $run = Invoke-RaymanGateProcess -FilePath $runnerPath -ArgumentList $argumentList -WorkingDirectory $WorkspaceRoot -LogPath $logPath -EnvironmentOverrides $EnvironmentOverrides
  $watch.Stop()
  $status = if ([bool]$run.ok) { 'PASS' } else { 'FAIL' }
  $detail = if ([string]::IsNullOrWhiteSpace([string]$run.detail)) { "exit=$($run.exit_code)" } else { [string]$run.detail }
  return (New-RaymanProjectGateCheck -Key $Key -Name $Name -Status $status -Detail $detail -Action $Action -Command $commandText -LogPath $logPath -ExitCode ([int]$run.exit_code) -DurationSeconds $watch.Elapsed.TotalSeconds)
}

$configInfo = Read-RaymanProjectConfig -WorkspaceRoot $WorkspaceRoot
$config = $configInfo.config
$checks = New-Object 'System.Collections.Generic.List[object]'

if ($configInfo.valid) {
  $configDetail = ''
  $configAction = '在 .rayman.project.json 中填写 build/browser/full 命令'
  if ($workspaceKind -eq 'source') {
    if ($configInfo.exists) {
      $configDetail = ("config={0} (optional in source workspace)" -f (Get-DisplayRelativePath -BasePath $WorkspaceRoot -FullPath $configInfo.path))
    } else {
      $configDetail = 'source workspace; consumer-only project config not applicable'
    }
    $configAction = ''
  } else {
    $configDetail = ("config={0}" -f (Get-DisplayRelativePath -BasePath $WorkspaceRoot -FullPath $configInfo.path))
  }
  $checks.Add((New-RaymanProjectGateCheck -Key 'project_config' -Name 'Project config' -Status PASS -Detail $configDetail -Action $configAction -LogPath '')) | Out-Null
} else {
  $checks.Add((New-RaymanProjectGateCheck -Key 'project_config' -Name 'Project config' -Status FAIL -Detail ("parse failed: {0}" -f [string]$configInfo.parse_error) -Action '修复 .rayman.project.json 的 JSON 语法后重试' -LogPath '')) | Out-Null
}

switch ($Lane) {
  'fast' {
    $checks.Add((Invoke-RaymanScriptCheck -Key 'requirements_layout' -Name 'Requirements layout' -Runner bash -ScriptPath (Join-Path $WorkspaceRoot '.Rayman/scripts/ci/validate_requirements.sh') -Action '执行 rayman fast-gate 前先修复 requirements / assets 结构' -LogName 'fast.requirements_layout.log' -EnvironmentOverrides @{ RAYMAN_VALIDATE_REQUIREMENTS_SKIP_RELEASE = '1' })) | Out-Null

    $protectedLog = Join-Path $logDir 'fast.protected_assets.log'
    $protectedChecks = @(
      Invoke-RaymanScriptCheck -Key 'protected_assets' -Name 'Protected assets / config sanity' -Runner bash -ScriptPath (Join-Path $WorkspaceRoot '.Rayman/scripts/release/config_sanity.sh') -Action '修复 .SolutionName / settings.json / mcp / Rayman managed defaults' -LogName 'fast.protected_assets.config_sanity.log'
    )
    $protectedFailed = @($protectedChecks | Where-Object { [string]$_.status -eq 'FAIL' })
    $protectedStatus = if ($protectedFailed.Count -gt 0) { 'FAIL' } else { 'PASS' }
    $protectedDetail = (@($protectedChecks | ForEach-Object { "{0}={1}" -f $_.name, $_.status }) -join '; ')
    $manifestPath = [string]$config.extra_protected_assets_manifest
    if (-not [string]::IsNullOrWhiteSpace($manifestPath)) {
      $manifestFullPath = Join-Path $WorkspaceRoot $manifestPath
      if (-not (Test-Path -LiteralPath $manifestFullPath)) {
        $protectedStatus = 'FAIL'
        $protectedDetail = $protectedDetail + ("; extra_manifest=missing:{0}" -f $manifestPath)
      } else {
        $protectedDetail = $protectedDetail + ("; extra_manifest=present:{0}" -f $manifestPath)
      }
    }
    $protectedLogLines = @()
    foreach ($protectedCheck in @($protectedChecks)) {
      $protectedLogLines += ("[{0}] {1}" -f [string]$protectedCheck.status, [string]$protectedCheck.name)
      if (-not [string]::IsNullOrWhiteSpace([string]$protectedCheck.log_path) -and (Test-Path -LiteralPath $protectedCheck.log_path -PathType Leaf)) {
        $protectedLogLines += (Get-Content -LiteralPath $protectedCheck.log_path -Encoding UTF8)
      }
      $protectedLogLines += ''
    }
    if ($protectedLogLines.Count -gt 0) {
      Set-Content -LiteralPath $protectedLog -Value $protectedLogLines -Encoding UTF8
    }
    $checks.Add((New-RaymanProjectGateCheck -Key 'protected_assets' -Name 'Protected assets' -Status $protectedStatus -Detail $protectedDetail -Action '先修复 config_sanity 与额外 manifest 的日志输出' -LogPath $protectedLog)) | Out-Null

    $checks.Add((Invoke-RaymanShellCommandCheck -Key 'build' -Name 'Build' -CommandText ([string]$config.build_command) -Action '在 .rayman.project.json 的 build_command 中配置项目最小可验证 build' -LogName 'fast.build.log' -WorkspaceKind $workspaceKind -WarnWhenEmpty)) | Out-Null
    $checks.Add((Invoke-RaymanShellCommandCheck -Key 'project_smoke' -Name 'Project smoke' -CommandText ([string]$config.extensions.project_fast_checks) -Action '在 .rayman.project.json 的 extensions.project_fast_checks 中配置轻量项目回归' -LogName 'fast.project_smoke.log' -WorkspaceKind $workspaceKind -WarnWhenEmpty)) | Out-Null
  }
  'browser' {
    $checks.Add((Invoke-RaymanShellCommandCheck -Key 'browser_regression' -Name 'Browser regression' -CommandText ([string]$config.browser_command) -Action '在 .rayman.project.json 的 browser_command 中配置 Chromium 基线浏览器回归' -LogName 'browser.browser_regression.log' -WorkspaceKind $workspaceKind -WarnWhenEmpty)) | Out-Null
    $checks.Add((Invoke-RaymanShellCommandCheck -Key 'project_smoke' -Name 'Project browser extension' -CommandText ([string]$config.extensions.project_browser_checks) -Action '在 .rayman.project.json 的 extensions.project_browser_checks 中挂接项目特有浏览器补充检查' -LogName 'browser.project_smoke.log' -WorkspaceKind $workspaceKind -WarnWhenEmpty)) | Out-Null
  }
  'full' {
    $releaseCommand = ''
    $releaseParts = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace([string]$config.full_gate_command)) {
      $releaseParts.Add([string]$config.full_gate_command) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$config.extensions.project_release_checks)) {
      $releaseParts.Add([string]$config.extensions.project_release_checks) | Out-Null
    }
    if ($releaseParts.Count -gt 0) {
      $releaseCommand = (Join-RaymanCommandSequence -Commands @($releaseParts))
    }
    $checks.Add((Invoke-RaymanShellCommandCheck -Key 'project_smoke' -Name 'Project release checks' -CommandText $releaseCommand -Action '在 .rayman.project.json 中配置 full_gate_command 或 extensions.project_release_checks' -LogName 'full.project_smoke.log' -WorkspaceKind $workspaceKind -WarnWhenEmpty)) | Out-Null
    $checks.Add((Invoke-RaymanScriptCheck -Key 'release_gate' -Name 'Release gate' -Runner pwsh -ScriptPath (Join-Path $WorkspaceRoot '.Rayman/scripts/release/release_gate.ps1') -Arguments @('-WorkspaceRoot', $WorkspaceRoot, '-Mode', 'project', '-Json') -Action '执行 rayman full-gate 或直接运行 release-gate -Mode project 排查' -LogName 'full.release_gate.log')) | Out-Null
  }
}

$summary = Get-RaymanProjectGateSummary -Checks ($checks.ToArray())
$report = [pscustomobject]@{
  schema = 'rayman.project_gate.v1'
  generated_at = (Get-Date).ToString('o')
  workspace_root = $WorkspaceRoot
  lane = $Lane
  config_path = $configInfo.path
  config_exists = [bool]$configInfo.exists
  overall = $summary.overall
  success = [bool]$summary.success
  counts = $summary.counts
  checks = $checks.ToArray()
}

$reportPath = Get-RaymanProjectGateReportPath -WorkspaceRoot $WorkspaceRoot -Lane $Lane
$reportJson = $report | ConvertTo-Json -Depth 8
Set-Content -LiteralPath $reportPath -Value $reportJson -Encoding UTF8

if ($Json) {
  Write-Output $reportJson
} else {
  Write-Host ("[{0}-gate] overall={1} report={2}" -f $Lane, $report.overall, (Get-DisplayRelativePath -BasePath $WorkspaceRoot -FullPath $reportPath)) -ForegroundColor Cyan
  foreach ($check in $checks.ToArray()) {
    $color = switch ([string]$check.status) {
      'PASS' { 'Green' }
      'WARN' { 'Yellow' }
      'FAIL' { 'Red' }
      default { 'Gray' }
    }
    Write-Host ("  - {0}: {1} ({2})" -f [string]$check.key, [string]$check.status, [string]$check.detail) -ForegroundColor $color
  }
}

exit (Get-RaymanProjectGateExitCode -Overall ([string]$report.overall))
