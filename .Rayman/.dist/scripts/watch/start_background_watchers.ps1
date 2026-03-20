param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$FromVscodeAuto,
  [string]$VscodeOwnerPid = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot "..\..\common.ps1"
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
  throw "common.ps1 not found: $commonPath"
}
. $commonPath

$ownedProcessPath = Join-Path $PSScriptRoot '..\utils\workspace_process_ownership.ps1'
if (-not (Test-Path -LiteralPath $ownedProcessPath -PathType Leaf)) {
  throw "workspace_process_ownership.ps1 not found: $ownedProcessPath"
}
. $ownedProcessPath -NoMain

$watchLifecycleLibPath = Join-Path $PSScriptRoot 'watch_lifecycle.lib.ps1'
if (-not (Test-Path -LiteralPath $watchLifecycleLibPath -PathType Leaf)) {
  throw "watch_lifecycle.lib.ps1 not found: $watchLifecycleLibPath"
}
. $watchLifecycleLibPath

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
[void](Repair-RaymanNestedDir -WorkspaceRoot $WorkspaceRoot)
$raymanDir = Join-Path $WorkspaceRoot '.Rayman'
$runtimeDir = Join-Path $raymanDir 'runtime'
if (-not (Test-Path -LiteralPath $runtimeDir)) {
  New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
}
$isWindowsHost = Test-RaymanWindowsPlatform
$sharedOwnerContext = Get-RaymanWorkspaceSharedProcessOwnerContext -WorkspaceRootPath $WorkspaceRoot

function Remove-StaleVsCodeSessions {
  $sessionDir = Join-Path $runtimeDir 'vscode_sessions'
  foreach ($session in @(Get-RaymanVsCodeSessionEntries -SessionDirectory $sessionDir)) {
    if ([bool]$session.active) {
      continue
    }

    $sessionFileName = if ([string]::IsNullOrWhiteSpace([string]$session.path)) {
      '(unknown)'
    } else {
      [System.IO.Path]::GetFileName([string]$session.path)
    }

    if (-not [bool]$session.valid) {
      Write-Warn ("[watch-auto] invalid session file removed: {0}" -f $sessionFileName)
    } else {
      Write-Info ("[watch-auto] removing stale vscode session: {0}" -f $sessionFileName)
    }

    try {
      Remove-Item -LiteralPath ([string]$session.path) -Force -ErrorAction SilentlyContinue
    } catch {
      Write-Warn ("[watch-auto] remove stale session failed ({0}): {1}" -f [string]$session.path, $_.Exception.Message)
      Write-RaymanDiag -Scope 'watch-auto' -Message ("remove stale session failed; session={0}; error={1}" -f [string]$session.path, $_.Exception.ToString())
    }
  }
}

function Resolve-StartPowerShellHost {
  $hostCmd = Resolve-RaymanPowerShellHost
  if (-not [string]::IsNullOrWhiteSpace($hostCmd)) {
    return $hostCmd
  }

  try {
    $selfProc = Get-Process -Id $PID -ErrorAction Stop
    if ($null -ne $selfProc -and -not [string]::IsNullOrWhiteSpace([string]$selfProc.Path)) {
      return [string]$selfProc.Path
    }
  } catch {}

  return $null
}

function Write-PidFile([string]$PidFile, [int]$ProcessId) {
  if ([string]::IsNullOrWhiteSpace($PidFile) -or $ProcessId -le 0) { return }

  $pidDir = Split-Path -Parent $PidFile
  if (-not [string]::IsNullOrWhiteSpace($pidDir) -and -not (Test-Path -LiteralPath $pidDir)) {
    New-Item -ItemType Directory -Force -Path $pidDir | Out-Null
  }

  try {
    Set-Content -LiteralPath $PidFile -Value $ProcessId -NoNewline -Encoding ASCII
  } catch {
    Write-Warn ("[watch-auto] write pid file failed ({0}): {1}" -f $PidFile, $_.Exception.Message)
    Write-RaymanDiag -Scope 'watch-auto' -Message ("write pid failed; pidFile={0}; error={1}" -f $PidFile, $_.Exception.ToString())
  }
}

function Register-RaymanBackgroundProcess {
  param(
    [string]$Name,
    [int]$ProcessId,
    [object]$OwnerContext,
    [string]$Kind = 'watcher',
    [string]$Launcher = 'watch-auto',
    [string]$Command = ''
  )

  if ($ProcessId -le 0 -or $null -eq $OwnerContext) { return }
  $commandText = if ([string]::IsNullOrWhiteSpace($Command)) { $Name } else { $Command }

  try {
    $null = Register-RaymanWorkspaceOwnedProcess `
      -WorkspaceRootPath $WorkspaceRoot `
      -OwnerContext $OwnerContext `
      -Kind $Kind `
      -Launcher $Launcher `
      -RootPid $ProcessId `
      -Command $commandText
  } catch {
    Write-Warn ("[watch-auto] register owned process failed ({0}, pid={1}): {2}" -f $Name, $ProcessId, $_.Exception.Message)
    Write-RaymanDiag -Scope 'watch-auto' -Message ("register owned process failed; name={0}; pid={1}; error={2}" -f $Name, $ProcessId, $_.Exception.ToString())
  }
}

function Resolve-RaymanBackgroundCommandText([string]$ScriptPath, [string[]]$ScriptArgs) {
  $parts = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($ScriptPath)) {
    $parts.Add($ScriptPath) | Out-Null
  }
  foreach ($arg in @($ScriptArgs)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$arg)) {
      $parts.Add([string]$arg) | Out-Null
    }
  }
  return (($parts.ToArray()) -join ' ')
}

function Resolve-McpRootPid([string]$PidFile, [int[]]$FallbackPids = @()) {
  $pidFromFile = Get-RaymanPidFromFile -PidFilePath $PidFile
  if ($pidFromFile -gt 0) {
    return $pidFromFile
  }

  foreach ($pidValue in @($FallbackPids | Select-Object -Unique)) {
    if ([int]$pidValue -gt 0) {
      return [int]$pidValue
    }
  }

  return 0
}

function Find-ExistingPowerShellProcess([string]$ScriptPath, [string]$WorkspaceRootPath) {
  if (-not $isWindowsHost) { return 0 }
  if ([string]::IsNullOrWhiteSpace($ScriptPath)) { return 0 }

  $scriptNeedle = Normalize-RaymanWatchPathForMatch -PathValue $ScriptPath
  $workspaceNeedle = Normalize-RaymanWatchPathForMatch -PathValue (Join-Path $WorkspaceRootPath '.Rayman')
  if ([string]::IsNullOrWhiteSpace($scriptNeedle) -or [string]::IsNullOrWhiteSpace($workspaceNeedle)) { return 0 }

  $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    ($_.Name -ieq 'pwsh.exe' -or $_.Name -ieq 'powershell.exe') -and -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine)
  }

  foreach ($proc in $processes) {
    $procPid = [int]$proc.ProcessId
    if ($procPid -eq [int]$PID) { continue }
    $cmd = ([string]$proc.CommandLine).ToLowerInvariant().Replace('/', '\')
    if ($cmd.Contains($scriptNeedle) -and $cmd.Contains($workspaceNeedle)) {
      return $procPid
    }
  }

  return 0
}

function Find-ExistingExitWatchProcess([int]$ParentPid, [string]$WorkspaceRootPath, [string]$ExitWatchScript) {
  if (-not $isWindowsHost) { return 0 }
  if ($ParentPid -le 0) { return 0 }

  $scriptNeedle = Normalize-RaymanWatchPathForMatch -PathValue $ExitWatchScript
  $workspaceNeedle = Normalize-RaymanWatchPathForMatch -PathValue $WorkspaceRootPath
  if ([string]::IsNullOrWhiteSpace($scriptNeedle) -or [string]::IsNullOrWhiteSpace($workspaceNeedle)) { return 0 }

  $pidToken = ("-parentpid {0}" -f $ParentPid)
  $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    ($_.Name -ieq 'pwsh.exe' -or $_.Name -ieq 'powershell.exe') -and -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine)
  }
  foreach ($proc in $processes) {
    $procPid = [int]$proc.ProcessId
    if ($procPid -eq [int]$PID) { continue }
    $cmd = ([string]$proc.CommandLine).ToLowerInvariant().Replace('/', '\')
    if ($cmd.Contains($scriptNeedle) -and $cmd.Contains($workspaceNeedle) -and $cmd.Contains($pidToken)) {
      return $procPid
    }
  }

  return 0
}

function Get-McpProcessPidsForWorkspace([string]$WorkspaceRootPath) {
  if (-not $isWindowsHost) { return @() }

  $dbNeedle = Normalize-RaymanWatchPathForMatch -PathValue (Join-Path $WorkspaceRootPath '.Rayman\state\rayman.db')
  if ([string]::IsNullOrWhiteSpace($dbNeedle)) { return @() }

  $hits = New-Object 'System.Collections.Generic.List[int]'
  $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine)
  }

  foreach ($proc in $processes) {
    $procPid = [int]$proc.ProcessId
    if ($procPid -eq [int]$PID) { continue }
    $cmd = ([string]$proc.CommandLine).ToLowerInvariant().Replace('/', '\')
    if ($cmd.Contains($dbNeedle)) {
      [void]$hits.Add($procPid)
    }
  }

  return @($hits | Select-Object -Unique)
}

function Get-WatcherStartRetryCount {
  return Get-RaymanEnvInt -Name 'RAYMAN_WATCH_START_RETRY_COUNT' -Default 2 -Min 0 -Max 8
}

function Get-WatcherStartRetryDelayMs {
  return Get-RaymanEnvInt -Name 'RAYMAN_WATCH_START_RETRY_DELAY_MS' -Default 800 -Min 100 -Max 30000
}

function Get-WatcherStartFailureKind([string]$Message) {
  if ([string]::IsNullOrWhiteSpace($Message)) { return 'unknown' }
  $text = $Message.ToLowerInvariant()
  if ($text -match 'cannot find powershell host' -or $text -match 'pwsh/powershell' -or $text -match 'in path') { return 'host_not_found' }
  if ($text -match 'script not found' -or $text -match 'cannot find path' -or $text -match 'no such file') { return 'script_missing' }
  if ($text -match 'access is denied' -or $text -match 'permission') { return 'permission_denied' }
  return 'start_failed'
}

function New-WatcherStartupMutex([string]$WorkspaceRootPath) {
  if ([string]::IsNullOrWhiteSpace($WorkspaceRootPath)) { return $null }

  $normalized = Normalize-RaymanWatchPathForMatch -PathValue $WorkspaceRootPath
  if ([string]::IsNullOrWhiteSpace($normalized)) { return $null }

  $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
  $sha1 = [System.Security.Cryptography.SHA1]::Create()
  try {
    $hash = ($sha1.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
  } finally {
    $sha1.Dispose()
  }

  return (New-Object System.Threading.Mutex($false, ("Global\RaymanWatchStart_{0}" -f $hash)))
}

function Start-RaymanDetachedWatcher {
  param(
    [string]$Name,
    [string]$ScriptPath,
    [string[]]$ScriptArgs,
    [string]$PidFile,
    [string]$EnableEnvName,
    [bool]$DefaultEnabled = $true,
    [object]$EnabledOverride = $null,
    [object]$OwnerContext = $null,
    [string]$Kind = 'watcher',
    [string]$Launcher = 'watch-auto'
  )

  $enabled = if ($PSBoundParameters.ContainsKey('EnabledOverride') -and $null -ne $EnabledOverride) {
    [bool]$EnabledOverride
  } else {
    Get-RaymanEnvBool -Name $EnableEnvName -Default $DefaultEnabled
  }

  if (-not $enabled) {
    Write-Info ("[watch-auto] {0} disabled by {1}=0." -f $Name, $EnableEnvName)
    return
  }

  if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    Write-Warn ("[watch-auto] {0} script not found: {1}" -f $Name, $ScriptPath)
    return
  }

  $existingPid = Find-ExistingPowerShellProcess -ScriptPath $ScriptPath -WorkspaceRootPath $WorkspaceRoot
  if ($existingPid -gt 0) {
    Write-PidFile -PidFile $PidFile -ProcessId $existingPid
    Register-RaymanBackgroundProcess -Name $Name -ProcessId $existingPid -OwnerContext $OwnerContext -Kind $Kind -Launcher $Launcher -Command (Resolve-RaymanBackgroundCommandText -ScriptPath $ScriptPath -ScriptArgs $ScriptArgs)
    Write-Info ("[watch-auto] {0} already running (process-scan PID={1})." -f $Name, $existingPid)
    return
  }

  $oldPid = Get-RaymanPidFromFile -PidFilePath $PidFile
  if ($oldPid -gt 0 -and (Test-RaymanPidFileProcess -PidFilePath $PidFile -AllowedProcessNames @('powershell', 'pwsh'))) {
    Register-RaymanBackgroundProcess -Name $Name -ProcessId $oldPid -OwnerContext $OwnerContext -Kind $Kind -Launcher $Launcher -Command (Resolve-RaymanBackgroundCommandText -ScriptPath $ScriptPath -ScriptArgs $ScriptArgs)
    Write-Info ("[watch-auto] {0} already running (PID={1})." -f $Name, $oldPid)
    return
  }

  if ($oldPid -gt 0) {
    Write-Warn ("[watch-auto] {0} stale pid file detected (PID={1}); restarting watcher." -f $Name, $oldPid)
  }

  if (Test-Path -LiteralPath $PidFile) {
    try {
      Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    } catch {
      Write-RaymanDiag -Scope 'watch-auto' -Message ("remove stale pid failed; watcher={0}; error={1}" -f $Name, $_.Exception.ToString())
    }
  }

  $args = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $ScriptPath
  ) + $ScriptArgs

  $maxRetries = Get-WatcherStartRetryCount
  $retryDelayMs = Get-WatcherStartRetryDelayMs
  $attempt = 0
  $started = $false
  $lastKind = 'unknown'
  $lastErrorMessage = ''

  while (-not $started -and $attempt -le $maxRetries) {
    $attempt++
    try {
      $psHost = Resolve-StartPowerShellHost
      if ([string]::IsNullOrWhiteSpace($psHost)) {
        throw "cannot find PowerShell host (pwsh/powershell) in PATH"
      }
      $proc = Start-RaymanProcessHiddenCompat -FilePath $psHost -ArgumentList $args
      Write-PidFile -PidFile $PidFile -ProcessId ([int]$proc.Id)
      Register-RaymanBackgroundProcess -Name $Name -ProcessId ([int]$proc.Id) -OwnerContext $OwnerContext -Kind $Kind -Launcher $Launcher -Command (Resolve-RaymanBackgroundCommandText -ScriptPath $ScriptPath -ScriptArgs $ScriptArgs)
      Write-Info ("[watch-auto] started {0} (PID={1}, host={2})." -f $Name, $proc.Id, $psHost)
      $started = $true
      break
    } catch {
      $lastErrorMessage = $_.Exception.Message
      $lastKind = Get-WatcherStartFailureKind -Message $lastErrorMessage
      Write-RaymanDiag -Scope 'watch-auto' -Message ("start failed; watcher={0}; kind={1}; attempt={2}; error={3}" -f $Name, $lastKind, $attempt, $_.Exception.ToString())

      if ($lastKind -eq 'host_not_found' -or $lastKind -eq 'script_missing' -or $attempt -gt $maxRetries) {
        break
      }

      Write-Warn ("[watch-auto] start {0} failed (kind={1}, attempt={2}/{3}): {4}" -f $Name, $lastKind, $attempt, ($maxRetries + 1), $lastErrorMessage)
      Start-Sleep -Milliseconds $retryDelayMs
    }
  }

  if (-not $started) {
    Write-Warn ("[watch-auto] degraded: {0} not started (kind={1}, attempts={2}, reason={3})" -f $Name, $lastKind, $attempt, $lastErrorMessage)
  }
}

$startupMutex = $null
$startupLockTaken = $false
try {
  Remove-StaleVsCodeSessions

  $startupMutex = New-WatcherStartupMutex -WorkspaceRootPath $WorkspaceRoot
  if ($null -ne $startupMutex) {
    $waitMs = Get-RaymanEnvInt -Name 'RAYMAN_WATCH_START_LOCK_WAIT_MS' -Default 5000 -Min 0 -Max 60000
    try {
      $startupLockTaken = $startupMutex.WaitOne($waitMs)
    } catch {
      Write-Warn ("[watch-auto] startup lock wait failed: {0}" -f $_.Exception.Message)
    }

    if (-not $startupLockTaken) {
      Write-Info '[watch-auto] startup lock busy; skip duplicate start.'
      exit 0
    }
  }

  if ($FromVscodeAuto) {
    Write-Info "[watch-auto] trigger=vscode-folder-open"
    $enableExitLinkedStop = Get-RaymanEnvBool -Name 'RAYMAN_VSCODE_EXIT_LINKED_STOP_ENABLED' -Default $true
    if (-not $enableExitLinkedStop) {
      Write-Info "[watch-auto] exit-linked stop disabled by RAYMAN_VSCODE_EXIT_LINKED_STOP_ENABLED=0."
    } else {
      $ownerPid = Resolve-RaymanVsCodeOwnerPid -ExplicitPid $VscodeOwnerPid -CurrentProcessId $PID -WindowsHost:$isWindowsHost
      if ($ownerPid -le 0) {
        Write-Warn "[watch-auto] cannot resolve VS Code owner PID; skip exitwatch binding."
      } else {
        $ownerProcessContext = Get-RaymanWorkspaceProcessOwnerContext -WorkspaceRootPath $WorkspaceRoot -ExplicitOwnerPid ([string]$ownerPid)
        $exitWatchScript = Join-Path $raymanDir 'win-exitwatch.ps1'
        if (-not (Test-Path -LiteralPath $exitWatchScript -PathType Leaf)) {
          Write-Warn ("[watch-auto] exitwatch script not found: {0}" -f $exitWatchScript)
        } else {
          $existingExitWatchPid = Find-ExistingExitWatchProcess -ParentPid $ownerPid -WorkspaceRootPath $WorkspaceRoot -ExitWatchScript $exitWatchScript
          if ($existingExitWatchPid -gt 0) {
            Register-RaymanBackgroundProcess -Name 'exitwatch' -ProcessId $existingExitWatchPid -OwnerContext $ownerProcessContext -Kind 'watcher' -Launcher 'watch-auto-exitwatch' -Command (Resolve-RaymanBackgroundCommandText -ScriptPath $exitWatchScript -ScriptArgs @('-ParentPid', [string]$ownerPid, '-WorkspaceRoot', $WorkspaceRoot))
            Write-Info ("[watch-auto] exitwatch already running (PID={0}, owner={1})." -f $existingExitWatchPid, $ownerPid)
          } else {
            $sessionDir = Join-Path $runtimeDir 'vscode_sessions'
            if (-not (Test-Path -LiteralPath $sessionDir)) {
              New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
            }
            $sessionFile = Join-Path $sessionDir ("{0}.json" -f $ownerPid)
            $parentStartUtc = Get-RaymanProcessStartUtcString -ProcessId $ownerPid
            $exitArgs = @(
              '-NoProfile',
              '-ExecutionPolicy',
              'Bypass',
              '-File',
              $exitWatchScript,
              '-ParentPid',
              $ownerPid,
              '-WorkspaceRoot',
              $WorkspaceRoot,
              '-SessionFile',
              $sessionFile,
              '-StopBackgroundWatchersOnExit'
            )
            if (-not [string]::IsNullOrWhiteSpace($parentStartUtc)) {
              $exitArgs += @('-ParentStartUtc', $parentStartUtc)
            }

            try {
              $psHost = Resolve-StartPowerShellHost
              if ([string]::IsNullOrWhiteSpace($psHost)) {
                throw "cannot find PowerShell host (pwsh/powershell) in PATH"
              }
              $exitProc = Start-RaymanProcessHiddenCompat -FilePath $psHost -ArgumentList $exitArgs
              Register-RaymanBackgroundProcess -Name 'exitwatch' -ProcessId ([int]$exitProc.Id) -OwnerContext $ownerProcessContext -Kind 'watcher' -Launcher 'watch-auto-exitwatch' -Command (Resolve-RaymanBackgroundCommandText -ScriptPath $exitWatchScript -ScriptArgs $exitArgs)
              Write-Info ("[watch-auto] exitwatch attached (PID={0}, owner={1})." -f $exitProc.Id, $ownerPid)
            } catch {
              Write-Warn ("[watch-auto] failed to start exitwatch: {0}" -f $_.Exception.Message)
              Write-RaymanDiag -Scope 'watch-auto' -Message ("start exitwatch failed; ownerPid={0}; error={1}" -f $ownerPid, $_.Exception.ToString())
            }
          }
        }
      }
    }
  }

  $embeddedAttentionEnabled = Get-RaymanEnvBool -Name 'RAYMAN_AUTO_START_ATTENTION_WATCH_ENABLED' -Default $false
  $embeddedAutoSaveEnabled = Get-RaymanEnvBool -Name 'RAYMAN_AUTO_SAVE_WATCH_ENABLED' -Default $false
  $promptWatchEnabled = Get-RaymanEnvBool -Name 'RAYMAN_AUTO_START_PROMPT_WATCH_ENABLED' -Default $true
  $startSharedWatch = ($promptWatchEnabled -or $embeddedAttentionEnabled -or $embeddedAutoSaveEnabled)

  if ($startSharedWatch) {
    $watchScript = Join-Path $raymanDir 'win-watch.ps1'
    $watchPidFile = Join-Path $runtimeDir 'win_watch.pid'
    $watchArgs = @('-WorkspaceRoot', $WorkspaceRoot, '-PidFile', $watchPidFile)
    if ($embeddedAttentionEnabled) {
      $watchArgs += '-EnableEmbeddedAttentionWatch'
    }
    if ($embeddedAutoSaveEnabled) {
      $watchArgs += '-EnableEmbeddedAutoSave'
    }

    Start-RaymanDetachedWatcher `
      -Name 'prompt-watch' `
      -ScriptPath $watchScript `
      -ScriptArgs $watchArgs `
      -PidFile $watchPidFile `
      -EnableEnvName 'RAYMAN_AUTO_START_PROMPT_WATCH_ENABLED' `
      -DefaultEnabled $true `
      -EnabledOverride $startSharedWatch `
      -OwnerContext $sharedOwnerContext `
      -Kind 'watcher' `
      -Launcher 'watch-auto-shared'
  } else {
    Write-Info '[watch-auto] shared win-watch disabled (no prompt/attention/auto-save feature enabled).'
  }

  # 启动 MCP 服务器
  $mcpScript = Join-Path $raymanDir 'scripts\mcp\manage_mcp.ps1'
  if (Test-Path -LiteralPath $mcpScript -PathType Leaf) {
    $mcpConfig = Join-Path $raymanDir 'mcp\mcp_servers.json'
    if (-not (Test-Path -LiteralPath $mcpConfig -PathType Leaf)) {
      Write-Info "[watch-auto] MCP config not found; skipping MCP start (.Rayman/mcp/mcp_servers.json)."
    } else {
      $mcpPids = @(Get-McpProcessPidsForWorkspace -WorkspaceRootPath $WorkspaceRoot)
      if ($mcpPids.Count -gt 0) {
        $mcpRootPid = Resolve-McpRootPid -PidFile (Join-Path $runtimeDir 'mcp\sqlite.pid') -FallbackPids $mcpPids
        Register-RaymanBackgroundProcess -Name 'mcp-sqlite' -ProcessId $mcpRootPid -OwnerContext $sharedOwnerContext -Kind 'mcp' -Launcher 'watch-auto-mcp' -Command 'sqlite'
        Write-Info ("[watch-auto] MCP already running for workspace (pid(s)={0}); skip start." -f ($mcpPids -join ','))
      } else {
        Write-Info "[watch-auto] starting MCP servers..."
        $mcpRetryCount = Get-RaymanEnvInt -Name 'RAYMAN_WATCH_MCP_START_RETRY_COUNT' -Default 1 -Min 0 -Max 6
        $mcpRetryDelayMs = Get-RaymanEnvInt -Name 'RAYMAN_WATCH_MCP_START_RETRY_DELAY_MS' -Default 1500 -Min 100 -Max 30000
        $mcpAttempt = 0
        $mcpStarted = $false
        $mcpKind = 'unknown'
        $mcpError = ''
        while (-not $mcpStarted -and $mcpAttempt -le $mcpRetryCount) {
          $mcpAttempt++
          try {
            & $mcpScript -Action start
            $mcpRootPid = Resolve-McpRootPid -PidFile (Join-Path $runtimeDir 'mcp\sqlite.pid') -FallbackPids (Get-McpProcessPidsForWorkspace -WorkspaceRootPath $WorkspaceRoot)
            Register-RaymanBackgroundProcess -Name 'mcp-sqlite' -ProcessId $mcpRootPid -OwnerContext $sharedOwnerContext -Kind 'mcp' -Launcher 'watch-auto-mcp' -Command 'sqlite'
            $mcpStarted = $true
          } catch {
            $mcpError = $_.Exception.Message
            $mcpKind = Get-WatcherStartFailureKind -Message $mcpError
            Write-RaymanDiag -Scope 'watch-auto' -Message ("mcp start failed; kind={0}; attempt={1}; error={2}" -f $mcpKind, $mcpAttempt, $_.Exception.ToString())

            if ($mcpKind -eq 'host_not_found' -or $mcpAttempt -gt $mcpRetryCount) {
              break
            }
            Start-Sleep -Milliseconds $mcpRetryDelayMs
          }
        }

        if (-not $mcpStarted) {
          Write-Warn ("[watch-auto] degraded: MCP start failed (kind={0}, attempts={1}, reason={2})" -f $mcpKind, $mcpAttempt, $mcpError)
        }
      }
    }
  }
} finally {
  if ($startupLockTaken -and $null -ne $startupMutex) {
    try { $startupMutex.ReleaseMutex() } catch {}
  }
  if ($null -ne $startupMutex) {
    try { $startupMutex.Dispose() } catch {}
  }
}
