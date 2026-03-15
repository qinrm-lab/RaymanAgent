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

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
[void](Repair-RaymanNestedDir -WorkspaceRoot $WorkspaceRoot)
$raymanDir = Join-Path $WorkspaceRoot '.Rayman'
$runtimeDir = Join-Path $raymanDir 'runtime'
if (-not (Test-Path -LiteralPath $runtimeDir)) {
  New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
}
$isWindowsHost = Test-RaymanWindowsPlatform

function Read-SessionState([string]$SessionPath) {
  if ([string]::IsNullOrWhiteSpace($SessionPath) -or -not (Test-Path -LiteralPath $SessionPath -PathType Leaf)) {
    return $null
  }

  try {
    $raw = Get-Content -LiteralPath $SessionPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    Write-Warn ("[watch-auto] invalid session file removed: {0}" -f $SessionPath)
    try { Remove-Item -LiteralPath $SessionPath -Force -ErrorAction SilentlyContinue } catch {}
    return $null
  }
}

function Normalize-PathForMatch([string]$PathValue) {
  if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
  try {
    $full = [System.IO.Path]::GetFullPath($PathValue)
    return ($full -replace '/', '\').ToLowerInvariant()
  } catch {
    return ($PathValue -replace '/', '\').ToLowerInvariant()
  }
}

function Resolve-IntPid([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return 0 }
  $parsed = 0
  if ([int]::TryParse($Value.Trim(), [ref]$parsed) -and $parsed -gt 0) {
    return $parsed
  }
  return 0
}

function Get-ProcessStartUtcString([int]$ProcessId) {
  if ($ProcessId -le 0) { return '' }
  try {
    $proc = Get-Process -Id $ProcessId -ErrorAction Stop
    return $proc.StartTime.ToUniversalTime().ToString('o')
  } catch {
    return ''
  }
}

function Test-ProcessAlive([int]$ProcessId, [string]$ExpectedStartUtc = '') {
  if ($ProcessId -le 0) { return $false }

  try {
    $proc = Get-Process -Id $ProcessId -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace($ExpectedStartUtc)) {
      $actualStartUtc = $proc.StartTime.ToUniversalTime().ToString('o')
      if ($actualStartUtc -ne $ExpectedStartUtc) {
        return $false
      }
    }
    return $true
  } catch {
    return $false
  }
}

function Remove-StaleVsCodeSessions {
  $sessionDir = Join-Path $runtimeDir 'vscode_sessions'
  if (-not (Test-Path -LiteralPath $sessionDir -PathType Container)) {
    return
  }

  $sessionFiles = @(Get-ChildItem -LiteralPath $sessionDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
  foreach ($sessionFile in $sessionFiles) {
    $session = Read-SessionState -SessionPath $sessionFile.FullName
    if ($null -eq $session) { continue }

    $sessionPid = Resolve-IntPid -Value ([string]$session.parentPid)
    $sessionStartUtc = [string]$session.parentStartUtc
    $state = ([string]$session.state).Trim().ToLowerInvariant()
    $alive = Test-ProcessAlive -ProcessId $sessionPid -ExpectedStartUtc $sessionStartUtc
    if ($alive -and $state -ne 'parent-exited') {
      continue
    }

    Write-Info ("[watch-auto] removing stale vscode session: {0}" -f $sessionFile.Name)
    try {
      Remove-Item -LiteralPath $sessionFile.FullName -Force -ErrorAction SilentlyContinue
    } catch {
      Write-Warn ("[watch-auto] remove stale session failed ({0}): {1}" -f $sessionFile.FullName, $_.Exception.Message)
      Write-RaymanDiag -Scope 'watch-auto' -Message ("remove stale session failed; session={0}; error={1}" -f $sessionFile.FullName, $_.Exception.ToString())
    }
  }
}

function Resolve-VscodeOwnerPid([string]$ExplicitPid) {
  $pidFromArg = Resolve-IntPid -Value $ExplicitPid
  if ($pidFromArg -gt 0) { return $pidFromArg }

  $pidFromEnv = Resolve-IntPid -Value ([string][System.Environment]::GetEnvironmentVariable('VSCODE_PID'))
  if ($pidFromEnv -gt 0) { return $pidFromEnv }

  if (-not $isWindowsHost) { return 0 }

  $visited = New-Object 'System.Collections.Generic.HashSet[int]'
  $currentPid = [int]$PID
  $hop = 0
  while ($currentPid -gt 0 -and $hop -lt 12) {
    if ($visited.Contains($currentPid)) { break }
    [void]$visited.Add($currentPid)

    $proc = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $currentPid) -ErrorAction SilentlyContinue
    if ($null -eq $proc) { break }
    $parentPid = [int]$proc.ParentProcessId
    if ($parentPid -le 0) { break }

    $parent = Get-Process -Id $parentPid -ErrorAction SilentlyContinue
    if ($null -ne $parent) {
      $name = [string]$parent.ProcessName
      if ($name -like 'Code*') {
        return $parentPid
      }
    }

    $currentPid = $parentPid
    $hop++
  }

  return 0
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

function Find-ExistingPowerShellProcess([string]$ScriptPath, [string]$WorkspaceRootPath) {
  if (-not $isWindowsHost) { return 0 }
  if ([string]::IsNullOrWhiteSpace($ScriptPath)) { return 0 }

  $scriptNeedle = Normalize-PathForMatch -PathValue $ScriptPath
  $workspaceNeedle = Normalize-PathForMatch -PathValue (Join-Path $WorkspaceRootPath '.Rayman')
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

  $scriptNeedle = Normalize-PathForMatch -PathValue $ExitWatchScript
  $workspaceNeedle = Normalize-PathForMatch -PathValue $WorkspaceRootPath
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

  $dbNeedle = Normalize-PathForMatch -PathValue (Join-Path $WorkspaceRootPath '.Rayman\state\rayman.db')
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

  $normalized = Normalize-PathForMatch -PathValue $WorkspaceRootPath
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
    [bool]$DefaultEnabled = $true
  )

  if (-not (Get-RaymanEnvBool -Name $EnableEnvName -Default $DefaultEnabled)) {
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
    Write-Info ("[watch-auto] {0} already running (process-scan PID={1})." -f $Name, $existingPid)
    return
  }

  $oldPid = Get-RaymanPidFromFile -PidFilePath $PidFile
  if ($oldPid -gt 0 -and (Test-RaymanPidFileProcess -PidFilePath $PidFile -AllowedProcessNames @('powershell', 'pwsh'))) {
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
      $ownerPid = Resolve-VscodeOwnerPid -ExplicitPid $VscodeOwnerPid
      if ($ownerPid -le 0) {
        Write-Warn "[watch-auto] cannot resolve VS Code owner PID; skip exitwatch binding."
      } else {
        $exitWatchScript = Join-Path $raymanDir 'win-exitwatch.ps1'
        if (-not (Test-Path -LiteralPath $exitWatchScript -PathType Leaf)) {
          Write-Warn ("[watch-auto] exitwatch script not found: {0}" -f $exitWatchScript)
        } else {
          $existingExitWatchPid = Find-ExistingExitWatchProcess -ParentPid $ownerPid -WorkspaceRootPath $WorkspaceRoot -ExitWatchScript $exitWatchScript
          if ($existingExitWatchPid -gt 0) {
            Write-Info ("[watch-auto] exitwatch already running (PID={0}, owner={1})." -f $existingExitWatchPid, $ownerPid)
          } else {
            $sessionDir = Join-Path $runtimeDir 'vscode_sessions'
            if (-not (Test-Path -LiteralPath $sessionDir)) {
              New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
            }
            $sessionFile = Join-Path $sessionDir ("{0}.json" -f $ownerPid)
            $parentStartUtc = Get-ProcessStartUtcString -ProcessId $ownerPid
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

  $watchScript = Join-Path $raymanDir 'win-watch.ps1'
  $watchPidFile = Join-Path $runtimeDir 'win_watch.pid'
  Start-RaymanDetachedWatcher `
    -Name 'prompt-watch' `
    -ScriptPath $watchScript `
    -ScriptArgs @('-WorkspaceRoot', $WorkspaceRoot, '-PidFile', $watchPidFile) `
    -PidFile $watchPidFile `
    -EnableEnvName 'RAYMAN_AUTO_START_PROMPT_WATCH_ENABLED' `
    -DefaultEnabled $true

  $watchAllAttention = Get-RaymanEnvBool -Name 'RAYMAN_ALERT_WATCH_ALL_PROCESSES' -Default $false
  $attentionTargets = @(Get-RaymanAttentionWatchProcessNames)
  if ($watchAllAttention -or (Test-RaymanAttentionWatchTargetsAvailable -WatchAll:$watchAllAttention -ProcessNames $attentionTargets)) {
    $alertScript = Join-Path $raymanDir 'scripts\alerts\attention_watch.ps1'
    $alertPidFile = Join-Path $runtimeDir 'attention_watch.pid'
    Start-RaymanDetachedWatcher `
      -Name 'attention-watch' `
      -ScriptPath $alertScript `
      -ScriptArgs @('-WorkspaceRoot', $WorkspaceRoot, '-PidFile', $alertPidFile) `
      -PidFile $alertPidFile `
      -EnableEnvName 'RAYMAN_ALERT_WATCH_ENABLED' `
      -DefaultEnabled $true
  } else {
    Write-Info ("[watch-auto] skip attention-watch (no target process: {0})." -f (($attentionTargets | Select-Object -Unique) -join ','))
  }

  # 启动自动保存服务 (Auto-Save Watcher)
  $autoSaveScript = Join-Path $raymanDir 'scripts\state\auto_save_watch.ps1'
  $autoSavePidFile = Join-Path $runtimeDir 'auto_save_watch.pid'
  Start-RaymanDetachedWatcher `
    -Name 'auto-save-watch' `
    -ScriptPath $autoSaveScript `
    -ScriptArgs @('-WorkspaceRoot', $WorkspaceRoot, '-PidFile', $autoSavePidFile) `
    -PidFile $autoSavePidFile `
    -EnableEnvName 'RAYMAN_AUTO_SAVE_WATCH_ENABLED' `
    -DefaultEnabled $true

  # 启动 MCP 服务器
  $mcpScript = Join-Path $raymanDir 'scripts\mcp\manage_mcp.ps1'
  if (Test-Path -LiteralPath $mcpScript -PathType Leaf) {
    $mcpConfig = Join-Path $raymanDir 'mcp\mcp_servers.json'
    if (-not (Test-Path -LiteralPath $mcpConfig -PathType Leaf)) {
      Write-Info "[watch-auto] MCP config not found; skipping MCP start (.Rayman/mcp/mcp_servers.json)."
    } else {
      $mcpPids = @(Get-McpProcessPidsForWorkspace -WorkspaceRootPath $WorkspaceRoot)
      if ($mcpPids.Count -gt 0) {
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
