if (-not (Get-Command Resolve-RaymanAutoSaveTargetPaths -ErrorAction SilentlyContinue)) {
  $sessionCommonPath = Join-Path $PSScriptRoot '..\state\session_common.ps1'
  if (Test-Path -LiteralPath $sessionCommonPath -PathType Leaf) {
    . $sessionCommonPath
  }
}

if (Test-RaymanWindowsPlatform -and $null -eq ('RaymanLastInputNative' -as [type])) {
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class RaymanLastInputNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO
    {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
}
"@
}

function Set-RaymanWatcherPidFile {
  param(
    [string]$PidFile,
    [int]$ProcessId
  )

  if ([string]::IsNullOrWhiteSpace([string]$PidFile) -or $ProcessId -le 0) { return }

  $pidDir = Split-Path -Parent $PidFile
  if (-not [string]::IsNullOrWhiteSpace([string]$pidDir) -and -not (Test-Path -LiteralPath $pidDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $pidDir | Out-Null
  }

  Set-Content -LiteralPath $PidFile -Value $ProcessId -NoNewline -Encoding ASCII
}

function Clear-RaymanWatcherPidFile {
  param(
    [string]$PidFile,
    [int]$ExpectedPid = 0
  )

  if ([string]::IsNullOrWhiteSpace([string]$PidFile) -or -not (Test-Path -LiteralPath $PidFile -PathType Leaf)) { return }
  if ($ExpectedPid -gt 0) {
    $pidValue = Get-RaymanPidFromFile -PidFilePath $PidFile
    if ($pidValue -gt 0 -and $pidValue -ne $ExpectedPid) {
      return
    }
  }

  Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
}

function Build-EmbeddedAttentionKeywordRegex([string[]]$Keywords) {
  $safe = @($Keywords | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [Regex]::Escape($_) })
  if ($safe.Count -eq 0) { return $null }
  return '(?i)(' + ($safe -join '|') + ')'
}

function Get-EmbeddedAttentionWindows([bool]$WatchAll, [System.Collections.Generic.HashSet[string]]$WatchNames) {
  $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
      $_.MainWindowHandle -ne 0 -and -not [string]::IsNullOrWhiteSpace($_.MainWindowTitle)
    })
  if ($WatchAll) { return $procs }
  return @($procs | Where-Object { $WatchNames.Contains($_.ProcessName) })
}

function Test-EmbeddedSandboxWindow([object]$Window) {
  if ($null -eq $Window) { return $false }
  return (([string]$Window.ProcessName -match '^(?i)WindowsSandbox(Client)?$') -or ([string]$Window.MainWindowTitle -match '(?i)Windows Sandbox'))
}

function Get-DefaultEmbeddedSandboxAttentionWindowPhrases {
  return @(
    'action required',
    'approval required',
    'input required',
    'manual action required',
    'needs your attention',
    'requires confirmation',
    'run command',
    'please confirm',
    'confirm action',
    '需要人工确认',
    '需要人工处理',
    '需要确认',
    '需要批准',
    '请确认',
    '请批准',
    '参数错误',
    '启动失败',
    'bootstrap failed',
    'feature is not enabled',
    'requires elevation',
    'timed out',
    '超时',
    '错误代码',
    '0x80070057',
    '0x80004005',
    '需要回复'
  )
}

function Get-DefaultEmbeddedGenericAttentionWindowPhrases {
  return @(
    'action required',
    'approval required',
    'input required',
    'manual action required',
    'needs your attention',
    'requires confirmation',
    'run command',
    'please confirm',
    'confirm action',
    'approve',
    'approval',
    '请选择目标',
    '需要选择 target',
    '是否应用这些更改',
    '应用这些更改',
    '需要人工确认',
    '需要人工处理',
    '需要确认',
    '需要批准',
    '请确认',
    '请批准',
    '需要回复',
    '跨工作区 prompt',
    'target（solution/project）'
  )
}

function Resolve-EmbeddedAttentionMatchProfile([object]$Window) {
  if (Test-EmbeddedSandboxWindow -Window $Window) { return 'sandbox' }
  return 'generic'
}

function Normalize-EmbeddedAttentionWindowTitle([string]$Title) {
  $value = [string]$Title
  if ([string]::IsNullOrWhiteSpace($value)) { return '' }

  $normalized = $value.Trim().ToLowerInvariant()
  $normalized = [Regex]::Replace($normalized, '0x[0-9a-f]+', '<hex>')
  $normalized = [Regex]::Replace($normalized, '\d+', '<n>')
  $normalized = [Regex]::Replace($normalized, '\s+', ' ')
  return $normalized
}

function New-EmbeddedAttentionGroupReason([string]$ProcessName, [string]$MatchProfile, [string[]]$Titles) {
  $uniqueTitles = @($Titles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  $count = $uniqueTitles.Count
  $samples = @($uniqueTitles | Select-Object -First 3)
  $sampleText = if ($samples.Count -gt 0) { $samples -join ' | ' } else { '无标题' }

  if ($MatchProfile -eq 'sandbox') {
    if ($count -gt 1) {
      return ("检测到 {0} 个相似的 Sandbox 关注窗口：{1}。请不要手工关闭该窗口；若已关闭，无需等待自动关闭，回宿主机重跑 setup 或设置 RAYMAN_PLAYWRIGHT_SETUP_SCOPE=wsl。" -f $count, $sampleText)
    }

    return ("检测到 Sandbox 窗口需要关注：{0} - {1}。请不要手工关闭该窗口；若已关闭，无需等待自动关闭，回宿主机重跑 setup 或设置 RAYMAN_PLAYWRIGHT_SETUP_SCOPE=wsl。" -f $ProcessName, $sampleText)
  }

  if ($count -gt 1) {
    return ("检测到 {0} 个相似的待人工处理窗口：{1} - {2}" -f $count, $ProcessName, $sampleText)
  }

  return ("检测到疑似需要人工处理的窗口：{0} - {1}" -f $ProcessName, $sampleText)
}

function Resolve-EmbeddedAttentionSeverity([string]$MatchProfile, [string[]]$Titles) {
  $joined = (@($Titles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' | ').ToLowerInvariant()

  if ($MatchProfile -eq 'sandbox') {
    if ($joined -match 'bootstrap failed|feature is not enabled|requires elevation|timed out|超时|参数错误|错误代码|0x80070057|0x80004005|启动失败') {
      return 'high'
    }
    return 'medium'
  }

  if ($joined -match 'target|请选择目标|需要选择|跨工作区 prompt|应用这些更改|是否应用这些更改') {
    return 'medium'
  }

  return 'low'
}

function Get-EmbeddedAttentionSeverityPrefix([string]$Severity) {
  switch ($Severity) {
    'high' { return '[高优先级] ' }
    'medium' { return '[中优先级] ' }
    default { return '[低优先级] ' }
  }
}

function Get-EmbeddedAttentionSeverityTitle([string]$Severity) {
  switch ($Severity) {
    'high' { return 'Rayman 高优先级提醒' }
    'medium' { return 'Rayman 中优先级提醒' }
    default { return 'Rayman 低优先级提醒' }
  }
}

function New-RaymanAttentionWatchState {
  param(
    [string]$WorkspaceRoot,
    [bool]$ExitWhenIdle = $true
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $runtimeDir = Join-Path $resolvedRoot '.Rayman\runtime'
  if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
  }

  $watchAll = Get-RaymanEnvBool -Name 'RAYMAN_ALERT_WATCH_ALL_PROCESSES' -Default $false
  $watchNamesRaw = @(Get-RaymanAttentionWatchProcessNames -WorkspaceRoot $resolvedRoot)
  $watchNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($name in $watchNamesRaw) { [void]$watchNames.Add($name) }

  $hasGlobalOverride = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('RAYMAN_ALERT_WINDOW_KEYWORDS'))
  $sandboxKeywords = if ($hasGlobalOverride) {
    @(Get-RaymanStringListEnv -Name 'RAYMAN_ALERT_WINDOW_KEYWORDS' -Default (Get-DefaultEmbeddedSandboxAttentionWindowPhrases))
  } else {
    @(Get-RaymanStringListEnv -Name 'RAYMAN_ALERT_WINDOW_SANDBOX_KEYWORDS' -Default (Get-DefaultEmbeddedSandboxAttentionWindowPhrases))
  }
  $genericKeywords = if ($hasGlobalOverride) {
    $sandboxKeywords
  } else {
    @(Get-RaymanStringListEnv -Name 'RAYMAN_ALERT_WINDOW_VSCODE_KEYWORDS' -Default (Get-DefaultEmbeddedGenericAttentionWindowPhrases))
  }

  $sandboxKeywordRegex = Build-EmbeddedAttentionKeywordRegex -Keywords $sandboxKeywords
  $genericKeywordRegex = Build-EmbeddedAttentionKeywordRegex -Keywords $genericKeywords
  if ([string]::IsNullOrWhiteSpace($sandboxKeywordRegex)) {
    throw 'Sandbox attention keyword list is empty.'
  }
  if ([string]::IsNullOrWhiteSpace($genericKeywordRegex)) {
    throw 'Generic attention keyword list is empty.'
  }

  return [pscustomobject]@{
    WorkspaceRoot = $resolvedRoot
    RuntimeDir = $runtimeDir
    ExitWhenIdle = [bool]$ExitWhenIdle
    PollMs = Get-RaymanEnvInt -Name 'RAYMAN_ALERT_WATCH_POLL_MS' -Default 1200 -Min 300 -Max 10000
    IdleExitSeconds = Get-RaymanEnvInt -Name 'RAYMAN_ALERT_WATCH_TARGET_IDLE_EXIT_SECONDS' -Default 600 -Min 30 -Max 86400
    ManualCooldownSeconds = Get-RaymanEnvInt -Name 'RAYMAN_ALERT_WATCH_COOLDOWN_SECONDS' -Default 90 -Min 5 -Max 3600
    ClearDoneSeconds = Get-RaymanEnvInt -Name 'RAYMAN_ALERT_WATCH_CLEAR_DONE_SECONDS' -Default 5 -Min 1 -Max 300
    ManualMaxSeconds = Get-RaymanEnvInt -Name 'RAYMAN_ALERT_WATCH_MANUAL_MAX_SECONDS' -Default 180 -Min 5 -Max 3600
    WatchAll = [bool]$watchAll
    WatchNames = $watchNames
    WatchNamesRaw = @($watchNamesRaw)
    SandboxKeywordRegex = $sandboxKeywordRegex
    GenericKeywordRegex = $genericKeywordRegex
    SandboxKeywords = @($sandboxKeywords)
    GenericKeywords = @($genericKeywords)
    AlertedAt = (New-Object 'System.Collections.Generic.Dictionary[string, datetime]' ([System.StringComparer]::OrdinalIgnoreCase))
    HadPending = $false
    ClearAt = $null
    LastTargetSeen = Get-Date
  }
}

function Get-RaymanAttentionWatchDelayMs {
  param([object]$State)

  if ($null -eq $State) { return 1200 }
  return [int][Math]::Max(300, [int]$State.PollMs)
}

function Get-RaymanAttentionWatchStartupMessage {
  param([object]$State)

  if ($null -eq $State) { return '[alert-watch] disabled' }

  return ("[alert-watch] started (pid={0}, poll={1}ms, idle-exit={2}s, watch={3}, sandbox-phrases={4}, generic-phrases={5}, mode={6})" -f
    $PID,
    [int]$State.PollMs,
    [int]$State.IdleExitSeconds,
    ((@($State.WatchNamesRaw) | Select-Object -Unique) -join ','),
    ((@($State.SandboxKeywords) | Select-Object -Unique) -join ' | '),
    ((@($State.GenericKeywords) | Select-Object -Unique) -join ' | '),
    $(if ([bool]$State.ExitWhenIdle) { 'detached' } else { 'embedded' }))
}

function Invoke-RaymanAttentionWatchCycle {
  param([object]$State)

  if ($null -eq $State) {
    return [pscustomobject]@{
      should_exit = $false
      reason = 'state_missing'
      matches = @()
    }
  }

  $targets = @()
  if (-not [bool]$State.WatchAll -and $State.WatchNames.Count -gt 0) {
    $targets = @(Get-Process -Name @($State.WatchNames) -ErrorAction SilentlyContinue)
  }
  if ([bool]$State.WatchAll -or $targets.Count -gt 0) {
    $State.LastTargetSeen = Get-Date
  } else {
    $idle = [int]((Get-Date) - [datetime]$State.LastTargetSeen).TotalSeconds
    if ([bool]$State.ExitWhenIdle -and $idle -ge [int]$State.IdleExitSeconds) {
      return [pscustomobject]@{
        should_exit = $true
        reason = ("idle_exit:{0}" -f $idle)
        matches = @()
      }
    }
  }

  $windows = Get-EmbeddedAttentionWindows -WatchAll:([bool]$State.WatchAll) -WatchNames $State.WatchNames
  $matches = @(
    foreach ($window in $windows) {
      $profile = Resolve-EmbeddedAttentionMatchProfile -Window $window
      $profileRegex = if ($profile -eq 'sandbox') { [string]$State.SandboxKeywordRegex } else { [string]$State.GenericKeywordRegex }
      if (-not [string]::IsNullOrWhiteSpace($profileRegex) -and [string]$window.MainWindowTitle -match $profileRegex) {
        $normalizedTitle = Normalize-EmbeddedAttentionWindowTitle -Title ([string]$window.MainWindowTitle)
        [pscustomobject]@{
          ProcessName = [string]$window.ProcessName
          MainWindowTitle = [string]$window.MainWindowTitle
          MatchProfile = $profile
          NormalizedTitle = $normalizedTitle
          AggregateKey = ("{0}|{1}|{2}" -f ([string]$window.ProcessName), $profile, $normalizedTitle)
        }
      }
    }
  )

  if ($matches.Count -gt 0) {
    $State.HadPending = $true
    $State.ClearAt = $null
    $groups = @($matches | Group-Object -Property AggregateKey)
    foreach ($group in $groups) {
      $m = $group.Group | Select-Object -First 1
      $key = [string]$group.Name
      $now = Get-Date
      $shouldAlert = $true
      if ($State.AlertedAt.ContainsKey($key)) {
        $cooldown = [int]($now - $State.AlertedAt[$key]).TotalSeconds
        if ($cooldown -lt [int]$State.ManualCooldownSeconds) { $shouldAlert = $false }
      }
      if ($shouldAlert) {
        $State.AlertedAt[$key] = $now
        $groupTitles = @($group.Group | ForEach-Object { [string]$_.MainWindowTitle })
        $severity = Resolve-EmbeddedAttentionSeverity -MatchProfile ([string]$m.MatchProfile) -Titles $groupTitles
        $reason = (Get-EmbeddedAttentionSeverityPrefix -Severity $severity) + (New-EmbeddedAttentionGroupReason -ProcessName ([string]$m.ProcessName) -MatchProfile ([string]$m.MatchProfile) -Titles $groupTitles)
        $title = Get-EmbeddedAttentionSeverityTitle -Severity $severity
        Invoke-RaymanAttentionAlert -Kind 'manual' -Reason $reason -Title $title -MaxSeconds ([int]$State.ManualMaxSeconds) -WorkspaceRoot ([string]$State.WorkspaceRoot) | Out-Null
      }
    }
  } else {
    if ([bool]$State.HadPending) {
      if ($null -eq $State.ClearAt) {
        $State.ClearAt = Get-Date
      } else {
        $quiet = [int]((Get-Date) - [datetime]$State.ClearAt).TotalSeconds
        if ($quiet -ge [int]$State.ClearDoneSeconds) {
          Invoke-RaymanAttentionAlert -Kind 'done' -Reason '疑似待处理窗口已消失。' -WorkspaceRoot ([string]$State.WorkspaceRoot) | Out-Null
          $State.HadPending = $false
          $State.ClearAt = $null
        }
      }
    }
  }

  return [pscustomobject]@{
    should_exit = $false
    reason = 'ok'
    matches = @($matches)
  }
}

function Get-RaymanNetworkResumeStatePath {
  param([string]$WorkspaceRoot)

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  return (Join-Path $resolvedRoot '.Rayman\runtime\network_resume.status.json')
}

function Get-RaymanNetworkResumePrompt {
  return '网络已恢复。请从中断处继续，不要从头开始。Continue from the interruption point; do not restart from scratch.'
}

function Get-RaymanNetworkResumeWatchDelayMs {
  param([object]$State)

  if ($null -eq $State) { return 5000 }
  return [int][Math]::Max(1000, [int]$State.PollMs)
}

function Get-RaymanNetworkResumeWatchStartupMessage {
  param([object]$State)

  if ($null -eq $State) { return '[network-resume] disabled' }

  return ("[network-resume] started (poll={0}ms, network-threshold={1}s, throttle-wait={2}s, timeout={3}ms, retry={4}s, max-attempts={5})" -f
    [int]$State.PollMs,
    [int]$State.ThresholdSeconds,
    [int]$State.ThrottleWaitSeconds,
    [int]$State.ProbeTimeoutMs,
    [int]$State.RetrySeconds,
    [int]$State.MaxAttempts)
}

function Get-RaymanNetworkResumeRawEnvString {
  param(
    [string]$Name,
    [string]$Default = ''
  )

  $raw = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace([string]$raw)) {
    return $Default
  }
  return ([string]$raw).Trim()
}

function ConvertTo-RaymanNullableDateTime {
  param([object]$Value)

  if ($null -eq $Value) { return $null }
  $text = ([string]$Value).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  try {
    return [datetime]::Parse($text)
  } catch {
    return $null
  }
}

function Get-RaymanCurrentUserIdleInfo {
  $result = [ordered]@{
    available = $false
    idle_since = $null
    last_input_at = $null
    idle_seconds = 0
    error = ''
  }

  if (-not (Test-RaymanWindowsPlatform)) {
    $result.error = 'windows_only'
    return [pscustomobject]$result
  }

  if ($null -eq ('RaymanLastInputNative' -as [type])) {
    $result.error = 'native_type_missing'
    return [pscustomobject]$result
  }

  try {
    $info = New-Object 'RaymanLastInputNative+LASTINPUTINFO'
    $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type]'RaymanLastInputNative+LASTINPUTINFO')
    if (-not [RaymanLastInputNative]::GetLastInputInfo([ref]$info)) {
      $result.error = ('GetLastInputInfo failed: {0}' -f [Runtime.InteropServices.Marshal]::GetLastWin32Error())
      return [pscustomobject]$result
    }

    $nowTicks = [uint32][Environment]::TickCount
    $deltaTicks = [uint32]($nowTicks - [uint32]$info.dwTime)
    $idleMs = [int64]$deltaTicks
    $lastInputAt = (Get-Date).AddMilliseconds(-1 * $idleMs)

    $result.available = $true
    $result.last_input_at = $lastInputAt
    $result.idle_since = $lastInputAt
    $result.idle_seconds = [int][Math]::Max(0, [Math]::Floor($idleMs / 1000.0))
    return [pscustomobject]$result
  } catch {
    $result.error = $_.Exception.Message
    return [pscustomobject]$result
  }
}

function Get-RaymanCodexDesktopHomePath {
  $override = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME')
  if (-not [string]::IsNullOrWhiteSpace($override)) {
    try {
      return [System.IO.Path]::GetFullPath([string]$override)
    } catch {
      return [string]$override
    }
  }

  $userHome = Get-RaymanUserHomePath
  if ([string]::IsNullOrWhiteSpace($userHome)) {
    return ''
  }
  return (Join-Path $userHome '.codex')
}

function Get-RaymanCodexDesktopSessionsRoot {
  $codexHome = Get-RaymanCodexDesktopHomePath
  if ([string]::IsNullOrWhiteSpace($codexHome)) {
    return ''
  }
  return (Join-Path $codexHome 'sessions')
}

function Get-RaymanCodexDesktopTuiLogPath {
  $codexHome = Get-RaymanCodexDesktopHomePath
  if ([string]::IsNullOrWhiteSpace($codexHome)) {
    return ''
  }
  return (Join-Path $codexHome 'log\codex-tui.log')
}

function Test-RaymanNetworkResumeDesktopSourceEnabled {
  return (Get-RaymanEnvBool -Name 'RAYMAN_NETWORK_RESUME_DESKTOP_SOURCE_ENABLED' -Default $true)
}

function Get-RaymanNetworkResumeDesktopSessionLookbackHours {
  return (Get-RaymanEnvInt -Name 'RAYMAN_CODEX_DESKTOP_SESSION_LOOKBACK_HOURS' -Default 12 -Min 1 -Max 168)
}

function Test-RaymanNetworkResumeDesktopSessionMeta {
  param([object]$Meta)

  if ($null -eq $Meta) { return $false }
  if (Get-Command Test-RaymanCodexDesktopSessionPayload -ErrorAction SilentlyContinue) {
    try {
      return (Test-RaymanCodexDesktopSessionPayload -Payload $Meta)
    } catch {}
  }

  $originator = [string](Get-RaymanMapValue -Map $Meta -Key 'originator' -Default '')
  if ($originator -match '(?i)codex desktop|codex[_ -]?vscode') { return $true }
  $source = [string](Get-RaymanMapValue -Map $Meta -Key 'source' -Default '')
  if ($source -match '^(?i)vscode$') { return $true }
  return $false
}

function Get-RaymanNetworkResumeDesktopSessionMeta {
  param([string]$SessionPath)

  $result = [ordered]@{
    valid = $false
    session_id = ''
    session_timestamp = $null
    workspace_root = ''
    source = ''
    originator = ''
    session_path = $SessionPath
  }

  if ([string]::IsNullOrWhiteSpace($SessionPath) -or -not (Test-Path -LiteralPath $SessionPath -PathType Leaf)) {
    return [pscustomobject]$result
  }

  $firstLine = ''
  try {
    $firstLine = Get-Content -LiteralPath $SessionPath -TotalCount 1 -Encoding UTF8 | Select-Object -First 1
  } catch {
    return [pscustomobject]$result
  }
  if ([string]::IsNullOrWhiteSpace($firstLine)) {
    return [pscustomobject]$result
  }

  try {
    $lineObj = $firstLine | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return [pscustomobject]$result
  }

  if ([string](Get-RaymanMapValue -Map $lineObj -Key 'type' -Default '') -ne 'session_meta') {
    return [pscustomobject]$result
  }

  $payload = Get-RaymanMapValue -Map $lineObj -Key 'payload' -Default $null
  if ($null -eq $payload -or -not (Test-RaymanNetworkResumeDesktopSessionMeta -Meta $payload)) {
    return [pscustomobject]$result
  }

  $result.valid = $true
  $result.session_id = [string](Get-RaymanMapValue -Map $payload -Key 'id' -Default '')
  $result.session_timestamp = ConvertTo-RaymanNullableDateTime -Value ([string](Get-RaymanMapValue -Map $payload -Key 'timestamp' -Default ''))
  $result.workspace_root = [string](Get-RaymanMapValue -Map $payload -Key 'cwd' -Default '')
  $result.source = [string](Get-RaymanMapValue -Map $payload -Key 'source' -Default '')
  $result.originator = [string](Get-RaymanMapValue -Map $payload -Key 'originator' -Default '')
  return [pscustomobject]$result
}

function Get-RaymanNetworkResumeDesktopFailurePatterns {
  return @(
    'reconnecting...',
    'we''re currently experiencing high demand, which may cause temporary errors.',
    'high demand',
    'rate limit',
    'rate limited',
    'too many requests',
    '429',
    'try again later',
    'overloaded',
    'request timed out',
    'timed out',
    'offline',
    'connection reset',
    'connection refused',
    'network unreachable',
    'dns',
    'insufficient_quota',
    'quota',
    'billing',
    'payment',
    'subscription',
    'authentication required',
    'auth required',
    'auth failed',
    'login required',
    'login failed',
    'permission',
    'policy',
    'model not found',
    'invalid request'
  )
}

function Get-RaymanNetworkResumeDesktopStructuredProbeText {
  param([object]$LineObject)

  if ($null -eq $LineObject) {
    return ''
  }

  $lineType = [string](Get-RaymanMapValue -Map $LineObject -Key 'type' -Default '')
  switch ($lineType) {
    'event_msg' {
      $payload = Get-RaymanMapValue -Map $LineObject -Key 'payload' -Default $null
      if ($null -eq $payload) { return '' }
      $payloadType = [string](Get-RaymanMapValue -Map $payload -Key 'type' -Default '')
      if ($payloadType -in @('status', 'error', 'warning')) {
        return [string](Get-RaymanMapValue -Map $payload -Key 'message' -Default '')
      }
      return ''
    }
    default {
      return ''
    }
  }
}

function Get-RaymanNetworkResumeDesktopTailFailureProbe {
  param(
    [string]$SessionPath,
    [string]$SessionId
  )

  $result = [ordered]@{
    text = ''
    matched_at = $null
    source = 'none'
  }

  $patterns = @(Get-RaymanNetworkResumeDesktopFailurePatterns)
  $parts = New-Object System.Collections.Generic.List[string]
  $latestMatchAt = $null

  if (-not [string]::IsNullOrWhiteSpace($SessionPath) -and (Test-Path -LiteralPath $SessionPath -PathType Leaf)) {
    $tailLines = @()
    try {
      $tailLines = @(Get-Content -LiteralPath $SessionPath -Tail 120 -Encoding UTF8 -ErrorAction SilentlyContinue)
    } catch {
      $tailLines = @()
    }

    foreach ($line in $tailLines) {
      $lineText = [string]$line
      if ([string]::IsNullOrWhiteSpace($lineText)) { continue }
      $probeText = ''
      $lineTimestamp = $null

      try {
        $lineObj = $lineText | ConvertFrom-Json -ErrorAction Stop
        $probeText = [string](Get-RaymanNetworkResumeDesktopStructuredProbeText -LineObject $lineObj)
        $lineTimestamp = ConvertTo-RaymanNullableDateTime -Value ([string](Get-RaymanMapValue -Map $lineObj -Key 'timestamp' -Default ''))
      } catch {
        continue
      }

      if ([string]::IsNullOrWhiteSpace($probeText)) { continue }
      $probeLower = $probeText.ToLowerInvariant()
      if (-not ($patterns | Where-Object { $probeLower.Contains($_) })) { continue }
      if ($null -ne $lineTimestamp -and ($null -eq $latestMatchAt -or [datetime]$lineTimestamp -gt [datetime]$latestMatchAt)) {
        $latestMatchAt = [datetime]$lineTimestamp
      }

      $parts.Add($probeText) | Out-Null
    }
  }

  $tuiLogPath = Get-RaymanCodexDesktopTuiLogPath
  if (-not [string]::IsNullOrWhiteSpace($SessionId) -and -not [string]::IsNullOrWhiteSpace($tuiLogPath) -and (Test-Path -LiteralPath $tuiLogPath -PathType Leaf)) {
    $logLines = @()
    try {
      $logLines = @(Get-Content -LiteralPath $tuiLogPath -Tail 2000 -Encoding UTF8 -ErrorAction SilentlyContinue)
    } catch {
      $logLines = @()
    }

    foreach ($line in $logLines) {
      $lineText = [string]$line
      if ([string]::IsNullOrWhiteSpace($lineText)) { continue }
      $lineLower = $lineText.ToLowerInvariant()
      if (-not $lineLower.Contains($SessionId.ToLowerInvariant())) { continue }
      if (-not ($patterns | Where-Object { $lineLower.Contains($_) })) { continue }

      if ($lineText -match '^(?<timestamp>\d{4}-\d{2}-\d{2}t\d{2}:\d{2}:\d{2}(?:\.\d+)?z)') {
        $lineTimestamp = ConvertTo-RaymanNullableDateTime -Value ([string]$Matches['timestamp'])
        if ($null -ne $lineTimestamp -and ($null -eq $latestMatchAt -or [datetime]$lineTimestamp -gt [datetime]$latestMatchAt)) {
          $latestMatchAt = [datetime]$lineTimestamp
        }
      }

      $parts.Add($lineText) | Out-Null
    }
  }

  $result.text = (($parts.ToArray() | Select-Object -Unique) -join "`n").Trim()
  $result.matched_at = $latestMatchAt
  $result.source = if ($parts.Count -gt 0) { 'desktop_session_tail' } else { 'none' }
  return [pscustomobject]$result
}

function Get-RaymanNetworkResumeDesktopSessionCandidate {
  param([string]$WorkspaceRoot)

  if (-not (Test-RaymanNetworkResumeDesktopSourceEnabled)) {
    return [pscustomobject]@{
      available = $false
      reason = 'desktop_source_disabled'
      candidate_source = 'codex_desktop_session'
      backend = 'codex'
      run_id = ''
      desktop_session_id = ''
      desktop_session_path = ''
    }
  }

  $sessionsRoot = Get-RaymanCodexDesktopSessionsRoot
  if ([string]::IsNullOrWhiteSpace($sessionsRoot) -or -not (Test-Path -LiteralPath $sessionsRoot -PathType Container)) {
    return [pscustomobject]@{
      available = $false
      reason = 'desktop_session_missing'
      candidate_source = 'codex_desktop_session'
      backend = 'codex'
      run_id = ''
      desktop_session_id = ''
      desktop_session_path = ''
    }
  }

  $workspaceMatchValue = Get-RaymanPathComparisonValue -PathValue $WorkspaceRoot
  $cutoff = (Get-Date).AddHours(-1 * (Get-RaymanNetworkResumeDesktopSessionLookbackHours))
  $probeConfig = Get-RaymanNetworkResumeProbeConfiguration -Backend 'codex'
  $best = $null
  $bestSortKey = [datetime]::MinValue
  $bestUnavailable = $null
  $bestUnavailableSortKey = [datetime]::MinValue

  foreach ($sessionFile in @(Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue)) {
    if ($null -eq $sessionFile) { continue }
    if ($sessionFile.LastWriteTime -lt $cutoff) { continue }

    $meta = Get-RaymanNetworkResumeDesktopSessionMeta -SessionPath ([string]$sessionFile.FullName)
    if (-not [bool]$meta.valid) { continue }
    if ((Get-RaymanPathComparisonValue -PathValue ([string]$meta.workspace_root)) -ne $workspaceMatchValue) { continue }

    $failureProbe = Get-RaymanNetworkResumeDesktopTailFailureProbe -SessionPath ([string]$sessionFile.FullName) -SessionId ([string]$meta.session_id)
    $failureStartedAt = if ($null -ne $failureProbe.matched_at) {
      [datetime]$failureProbe.matched_at
    } elseif ($null -ne $meta.session_timestamp) {
      [datetime]$meta.session_timestamp
    } else {
      [datetime]$sessionFile.LastWriteTime
    }

    if ([string]::IsNullOrWhiteSpace([string]$failureProbe.text)) { continue }
    $failureClassification = Get-RaymanNetworkResumeFailureClassification -Text ([string]$failureProbe.text)
    if (-not [bool]$failureClassification.is_resume_candidate) {
      if ($null -eq $bestUnavailable -or $failureStartedAt -gt $bestUnavailableSortKey) {
        $bestUnavailableSortKey = $failureStartedAt
        $bestUnavailable = [pscustomobject]@{
          available = $false
          reason = [string]$failureClassification.classification
          candidate_source = 'codex_desktop_session'
          summary = $meta
          summary_path = [string]$sessionFile.FullName
          backend = 'codex'
          run_id = [string]$meta.session_id
          probe = $probeConfig
          failure_text = [string]$failureProbe.text
          failure_classification = $failureClassification
          trigger_kind = [string]$failureClassification.trigger_kind
          native_resume_supported = [bool]$probeConfig.native_resume_supported
          failure_started_at = $failureStartedAt
          desktop_session_id = [string]$meta.session_id
          desktop_session_path = [string]$sessionFile.FullName
          resume_target_kind = if ([string]::IsNullOrWhiteSpace([string]$meta.session_id)) { 'desktop_last' } else { 'desktop_session' }
        }
      }
      continue
    }

    if ($null -eq $best -or $failureStartedAt -gt $bestSortKey) {
      $bestSortKey = $failureStartedAt
      $best = [pscustomobject]@{
        available = $true
        reason = 'candidate_ready'
        candidate_source = 'codex_desktop_session'
        summary = $meta
        summary_path = [string]$sessionFile.FullName
        backend = 'codex'
        run_id = [string]$meta.session_id
        probe = $probeConfig
        failure_text = [string]$failureProbe.text
        failure_classification = $failureClassification
        trigger_kind = [string]$failureClassification.trigger_kind
        native_resume_supported = [bool]$probeConfig.native_resume_supported
        failure_started_at = $failureStartedAt
        desktop_session_id = [string]$meta.session_id
        desktop_session_path = [string]$sessionFile.FullName
        resume_target_kind = 'desktop_session'
      }
    }
  }

  if ($null -ne $best) {
    return $best
  }
  if ($null -ne $bestUnavailable) {
    return $bestUnavailable
  }

  return [pscustomobject]@{
    available = $false
    reason = 'desktop_session_no_match'
    candidate_source = 'codex_desktop_session'
    summary_path = ''
    backend = 'codex'
    run_id = ''
    probe = $probeConfig
    desktop_session_id = ''
    desktop_session_path = ''
  }
}

function Get-RaymanNetworkResumeCandidateSortKey {
  param([object]$Candidate)

  if ($null -eq $Candidate) {
    return [datetime]::MinValue
  }

  if ($Candidate.PSObject.Properties['failure_started_at'] -and $null -ne $Candidate.failure_started_at) {
    return [datetime]$Candidate.failure_started_at
  }

  if ($Candidate.PSObject.Properties['summary'] -and $null -ne $Candidate.summary) {
    $generatedAt = ConvertTo-RaymanNullableDateTime -Value ([string](Get-RaymanMapValue -Map $Candidate.summary -Key 'generated_at' -Default ''))
    if ($null -ne $generatedAt) {
      return [datetime]$generatedAt
    }
  }

  $summaryPath = if ($Candidate.PSObject.Properties['summary_path']) { [string]$Candidate.summary_path } else { '' }
  if (-not [string]::IsNullOrWhiteSpace($summaryPath) -and (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
    try {
      return (Get-Item -LiteralPath $summaryPath -ErrorAction Stop).LastWriteTime
    } catch {}
  }

  return [datetime]::MinValue
}

function Get-RaymanNetworkResumeProbeConfiguration {
  param([string]$Backend)

  $normalized = ([string]$Backend).Trim().ToLowerInvariant()
  $envName = ''
  $defaultUrl = ''
  $nativeResumeSupported = $false
  switch ($normalized) {
    'codex' {
      $envName = 'RAYMAN_NETWORK_RESUME_CODEX_PROBE_URL'
      $defaultUrl = 'https://api.openai.com/'
      $nativeResumeSupported = $true
      break
    }
    'copilot' {
      $envName = 'RAYMAN_NETWORK_RESUME_COPILOT_PROBE_URL'
      $defaultUrl = 'https://api.github.com/'
      $nativeResumeSupported = $false
      break
    }
    default {
      return [pscustomobject]@{
        backend = $normalized
        env_name = ''
        raw_url = ''
        probe_uri = $null
        native_resume_supported = $false
        valid = $false
        error = 'unsupported_backend'
      }
    }
  }

  $rawUrl = Get-RaymanNetworkResumeRawEnvString -Name $envName -Default $defaultUrl
  $probeUri = $null
  try {
    $probeUri = [Uri]$rawUrl
  } catch {
    return [pscustomobject]@{
      backend = $normalized
      env_name = $envName
      raw_url = $rawUrl
      probe_uri = $null
      native_resume_supported = $nativeResumeSupported
      valid = $false
      error = 'invalid_probe_url'
    }
  }

  return [pscustomobject]@{
    backend = $normalized
    env_name = $envName
    raw_url = $rawUrl
    probe_uri = $probeUri
    native_resume_supported = $nativeResumeSupported
    valid = $true
    error = ''
  }
}

function Get-RaymanNetworkResumeFailureClassification {
  param([string]$Text)

  $normalized = ([string]$Text).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    return [pscustomobject]@{
      is_resume_candidate = $false
      is_network = $false
      trigger_kind = 'none'
      classification = 'insufficient_signal'
      matched = ''
    }
  }

  $denyPatterns = @(
    'login required',
    'not logged in',
    'authentication required',
    'auth required',
    'auth failed',
    'unauthorized',
    'forbidden',
    'permission',
    'policy',
    'quota',
    'billing',
    'payment',
    'subscription',
    'insufficient_quota',
    'model not found',
    'invalid request',
    'invalid_request',
    'invalid api key',
    'invalid_api_key',
    'access denied',
    '欠费',
    '配额',
    '账单',
    '支付',
    '权限',
    '策略',
    '未登录'
  )
  foreach ($pattern in $denyPatterns) {
    if ($normalized.Contains($pattern)) {
      return [pscustomobject]@{
        is_resume_candidate = $false
        is_network = $false
        trigger_kind = 'none'
        classification = 'non_network_error'
        matched = $pattern
      }
    }
  }

  $throttlePatterns = @(
    'high demand',
    'rate limit',
    'rate limited',
    'too many requests',
    '429',
    'server overloaded',
    'overloaded',
    'capacity',
    'busy',
    'try again later',
    'please try again later',
    'high traffic',
    'high load',
    'request limit exceeded',
    '高 demand',
    '高峰',
    '高需求',
    '限流',
    '请求过多',
    '过载',
    '繁忙',
    '稍后再试',
    '请稍后再试',
    '服务繁忙'
  )
  foreach ($pattern in $throttlePatterns) {
    if ($normalized.Contains($pattern)) {
      return [pscustomobject]@{
        is_resume_candidate = $true
        is_network = $false
        trigger_kind = 'throttle'
        classification = 'transient_throttle_error'
        matched = $pattern
      }
    }
  }

  $allowPatterns = @(
    'timed out',
    'timeout',
    'unreachable',
    'offline',
    'no connection',
    'connection reset',
    'connection was reset',
    'connection refused',
    'actively refused',
    'econnreset',
    'econnrefused',
    'enetunreach',
    'ehostunreach',
    'dns',
    'name resolution',
    'temporary failure in name resolution',
    'no such host is known',
    'enotfound',
    'socketexception',
    'network is unreachable',
    '无法连接',
    '连接超时',
    '网络中断',
    '网络不可达',
    '域名解析',
    '连接被重置',
    '连接被拒绝'
  )
  foreach ($pattern in $allowPatterns) {
    if ($normalized.Contains($pattern)) {
      return [pscustomobject]@{
        is_resume_candidate = $true
        is_network = $true
        trigger_kind = 'network'
        classification = 'transient_network_error'
        matched = $pattern
      }
    }
  }

  return [pscustomobject]@{
    is_resume_candidate = $false
    is_network = $false
    trigger_kind = 'none'
    classification = 'insufficient_signal'
    matched = ''
  }
}

function Get-RaymanNetworkResumeFailureText {
  param([object]$Summary)

  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($propertyName in @('error_message', 'task', 'selection_reason', 'delegation_reason')) {
    if ($Summary.PSObject.Properties[$propertyName] -and -not [string]::IsNullOrWhiteSpace([string]$Summary.$propertyName)) {
      $parts.Add([string]$Summary.$propertyName) | Out-Null
    }
  }

  $detailLogPath = if ($Summary.PSObject.Properties['detail_log']) { [string]$Summary.detail_log } else { '' }
  if (-not [string]::IsNullOrWhiteSpace($detailLogPath) -and (Test-Path -LiteralPath $detailLogPath -PathType Leaf)) {
    try {
      foreach ($line in @(Get-Content -LiteralPath $detailLogPath -Tail 40 -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
          $parts.Add([string]$line) | Out-Null
        }
      }
    } catch {}
  }

  return (($parts.ToArray()) -join "`n").Trim()
}

function Get-RaymanNetworkResumeDispatchCandidate {
  param([string]$WorkspaceRoot)

  $statusPath = Get-RaymanNetworkResumeStatePath -WorkspaceRoot $WorkspaceRoot
  $summaryPath = Join-Path (Split-Path -Parent $statusPath) 'agent_runs\last.json'
  $summaryDoc = Read-RaymanJsonFile -Path $summaryPath
  if (-not [bool]$summaryDoc.Exists) {
    return [pscustomobject]@{
      available = $false
      reason = 'last_run_missing'
      candidate_source = 'agent_run'
      summary_path = $summaryPath
      backend = ''
      run_id = ''
    }
  }
  if ([bool]$summaryDoc.ParseFailed -or $null -eq $summaryDoc.Obj) {
    return [pscustomobject]@{
      available = $false
      reason = 'last_run_invalid'
      candidate_source = 'agent_run'
      summary_path = $summaryPath
      backend = ''
      run_id = ''
    }
  }

  $summary = $summaryDoc.Obj
  $backend = ''
  foreach ($name in @('selected_backend', 'backend', 'preferred_backend')) {
    if ($summary.PSObject.Properties[$name] -and -not [string]::IsNullOrWhiteSpace([string]$summary.$name)) {
      $backend = ([string]$summary.$name).Trim().ToLowerInvariant()
      break
    }
  }
  $runId = if ($summary.PSObject.Properties['run_id']) { [string]$summary.run_id } else { '' }
  if (-not $summary.PSObject.Properties['success'] -or [bool]$summary.success) {
    return [pscustomobject]@{
      available = $false
      reason = 'last_run_succeeded'
      candidate_source = 'agent_run'
      summary = $summary
      summary_path = $summaryPath
      backend = $backend
      run_id = $runId
    }
  }

  $probeConfig = Get-RaymanNetworkResumeProbeConfiguration -Backend $backend
  if (-not [bool]$probeConfig.valid) {
    return [pscustomobject]@{
      available = $false
      reason = [string]$probeConfig.error
      candidate_source = 'agent_run'
      summary = $summary
      summary_path = $summaryPath
      backend = $backend
      run_id = $runId
      probe = $probeConfig
    }
  }

  $failureText = Get-RaymanNetworkResumeFailureText -Summary $summary
  $failureClassification = Get-RaymanNetworkResumeFailureClassification -Text $failureText
  if (-not [bool]$failureClassification.is_resume_candidate) {
    return [pscustomobject]@{
      available = $false
      reason = [string]$failureClassification.classification
      candidate_source = 'agent_run'
      summary = $summary
      summary_path = $summaryPath
      backend = $backend
      run_id = $runId
      probe = $probeConfig
      failure_text = $failureText
      failure_classification = $failureClassification
    }
  }

  return [pscustomobject]@{
    available = $true
    reason = 'candidate_ready'
    candidate_source = 'agent_run'
    summary = $summary
    summary_path = $summaryPath
    backend = $backend
    run_id = $runId
    probe = $probeConfig
    failure_text = $failureText
    failure_classification = $failureClassification
    trigger_kind = [string]$failureClassification.trigger_kind
    native_resume_supported = [bool]$probeConfig.native_resume_supported
    failure_started_at = (ConvertTo-RaymanNullableDateTime -Value $(if ($summary.PSObject.Properties['generated_at']) { [string]$summary.generated_at } else { '' }))
    desktop_session_id = ''
    desktop_session_path = ''
    resume_target_kind = 'managed_last_run'
  }
}

function Get-RaymanNetworkResumeCandidate {
  param([string]$WorkspaceRoot)

  $candidates = @(
    (Get-RaymanNetworkResumeDispatchCandidate -WorkspaceRoot $WorkspaceRoot)
    (Get-RaymanNetworkResumeDesktopSessionCandidate -WorkspaceRoot $WorkspaceRoot)
  )

  $available = @($candidates | Where-Object { [bool]$_.available })
  if ($available.Count -gt 0) {
    return @($available | Sort-Object `
        @{ Expression = { if ([string]$_.candidate_source -eq 'codex_desktop_session') { 0 } else { 1 } } }, `
        @{ Expression = { Get-RaymanNetworkResumeCandidateSortKey -Candidate $_ }; Descending = $true }, `
        @{ Expression = { [string]$_.run_id } })[0]
  }

  $informative = @($candidates | Where-Object {
      [string]$_.reason -notin @('last_run_missing', 'desktop_session_missing', 'desktop_source_disabled', 'desktop_session_no_match')
    })
  if ($informative.Count -gt 0) {
    return @($informative | Sort-Object `
        @{ Expression = { if ([string]$_.candidate_source -eq 'codex_desktop_session') { 0 } else { 1 } } }, `
        @{ Expression = { Get-RaymanNetworkResumeCandidateSortKey -Candidate $_ }; Descending = $true }, `
        @{ Expression = { [string]$_.reason } })[0]
  }

  return @($candidates | Sort-Object `
      @{ Expression = { if ([string]$_.candidate_source -eq 'agent_run') { 0 } else { 1 } } }, `
      @{ Expression = { [string]$_.reason } })[0]
}

function Test-RaymanNetworkResumeProviderReachable {
  param(
    [Uri]$ProbeUri,
    [int]$TimeoutMs
  )

  $result = [ordered]@{
    reachable = $false
    dns_resolved = $false
    http_status_code = 0
    endpoint = ''
    error = ''
    phase = 'start'
  }

  if ($null -eq $ProbeUri) {
    $result.error = 'probe_uri_missing'
    return [pscustomobject]$result
  }

  $result.endpoint = [string]$ProbeUri.AbsoluteUri

  try {
    $addresses = @([System.Net.Dns]::GetHostAddresses([string]$ProbeUri.Host))
    if ($addresses.Count -le 0) {
      $result.phase = 'dns'
      $result.error = 'dns_empty'
      return [pscustomobject]$result
    }
    $result.dns_resolved = $true
  } catch {
    $result.phase = 'dns'
    $result.error = $_.Exception.Message
    return [pscustomobject]$result
  }

  $handler = $null
  $client = $null
  $request = $null
  $response = $null
  try {
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromMilliseconds([int][Math]::Max(1000, $TimeoutMs))
    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $ProbeUri)
    $null = $request.Headers.TryAddWithoutValidation('User-Agent', 'RaymanNetworkResume/1.0')
    $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    $result.reachable = $true
    $result.phase = 'http'
    $result.http_status_code = [int]$response.StatusCode
    return [pscustomobject]$result
  } catch {
    $result.phase = 'http'
    $result.error = $_.Exception.Message
    return [pscustomobject]$result
  } finally {
    if ($null -ne $response) { $response.Dispose() }
    if ($null -ne $request) { $request.Dispose() }
    if ($null -ne $client) { $client.Dispose() }
    if ($null -ne $handler) { $handler.Dispose() }
  }
}

function Write-RaymanNetworkResumeStatus {
  param(
    [object]$State,
    [string]$Status,
    [object]$Candidate = $null,
    [object]$IdleInfo = $null,
    [object]$ProbeResult = $null,
    [string]$Error = '',
    [hashtable]$Extra = @{}
  )

  if ($null -eq $State) { return $null }

  $payload = [ordered]@{
    schema = 'rayman.watch.network_resume_status.v1'
    generated_at = (Get-Date).ToString('o')
    status = [string]$Status
    workspace_root = [string]$State.WorkspaceRoot
    threshold_seconds = [int]$State.ThresholdSeconds
    throttle_wait_seconds = [int]$State.ThrottleWaitSeconds
    poll_ms = [int]$State.PollMs
    probe_timeout_ms = [int]$State.ProbeTimeoutMs
    retry_seconds = [int]$State.RetrySeconds
    max_attempts = [int]$State.MaxAttempts
    provider_unreachable_since = $(if ($null -ne $State.ProviderUnreachableSince) { ([datetime]$State.ProviderUnreachableSince).ToString('o') } else { '' })
    throttled_since = $(if ($null -ne $State.ThrottledSince) { ([datetime]$State.ThrottledSince).ToString('o') } else { '' })
    idle_since = $(if ($null -ne $State.IdleSince) { ([datetime]$State.IdleSince).ToString('o') } else { '' })
    armed_at = $(if ($null -ne $State.ArmedAt) { ([datetime]$State.ArmedAt).ToString('o') } else { '' })
    trigger_kind = [string]$State.TriggerKind
    last_candidate_run_id = [string]$State.LastCandidateRunId
    last_resume_attempt_at = $(if ($null -ne $State.LastResumeAttemptAt) { ([datetime]$State.LastResumeAttemptAt).ToString('o') } else { '' })
    attempt_count = [int]$State.AttemptCount
    suppressed_reason = [string]$State.SuppressedReason
    provider_reachable = $(if ($null -eq $State.LastProviderReachable) { '' } else { [bool]$State.LastProviderReachable })
    candidate_source = $(if ($null -ne $Candidate -and $Candidate.PSObject.Properties['candidate_source']) { [string]$Candidate.candidate_source } else { '' })
    resume_target_kind = $(if ($null -ne $Candidate -and $Candidate.PSObject.Properties['resume_target_kind']) { [string]$Candidate.resume_target_kind } else { '' })
    desktop_session_id = $(if ($null -ne $Candidate -and $Candidate.PSObject.Properties['desktop_session_id']) { [string]$Candidate.desktop_session_id } else { '' })
    desktop_session_path = $(if ($null -ne $Candidate -and $Candidate.PSObject.Properties['desktop_session_path']) { [string]$Candidate.desktop_session_path } else { '' })
    error = [string]$Error
  }

  if ($null -ne $Candidate) {
    $payload['candidate'] = [ordered]@{
      available = [bool]$Candidate.available
      reason = [string]$Candidate.reason
      candidate_source = $(if ($Candidate.PSObject.Properties['candidate_source']) { [string]$Candidate.candidate_source } else { '' })
      backend = [string]$Candidate.backend
      run_id = [string]$Candidate.run_id
      trigger_kind = $(if ($Candidate.PSObject.Properties['trigger_kind']) { [string]$Candidate.trigger_kind } else { '' })
      native_resume_supported = $(if ($Candidate.PSObject.Properties['native_resume_supported']) { [bool]$Candidate.native_resume_supported } else { $false })
      resume_target_kind = $(if ($Candidate.PSObject.Properties['resume_target_kind']) { [string]$Candidate.resume_target_kind } else { '' })
      desktop_session_id = $(if ($Candidate.PSObject.Properties['desktop_session_id']) { [string]$Candidate.desktop_session_id } else { '' })
      desktop_session_path = $(if ($Candidate.PSObject.Properties['desktop_session_path']) { [string]$Candidate.desktop_session_path } else { '' })
      summary_path = $(if ($Candidate.PSObject.Properties['summary_path']) { [string]$Candidate.summary_path } else { '' })
      failure_classification = $(if ($Candidate.PSObject.Properties['failure_classification']) { [string]$Candidate.failure_classification.classification } else { '' })
      failure_match = $(if ($Candidate.PSObject.Properties['failure_classification']) { [string]$Candidate.failure_classification.matched } else { '' })
      failure_started_at = $(if ($Candidate.PSObject.Properties['failure_started_at'] -and $null -ne $Candidate.failure_started_at) { ([datetime]$Candidate.failure_started_at).ToString('o') } else { '' })
    }
  }

  if ($null -ne $IdleInfo) {
    $payload['idle'] = [ordered]@{
      available = [bool]$IdleInfo.available
      idle_seconds = [int]$IdleInfo.idle_seconds
      idle_since = $(if ($null -ne $IdleInfo.idle_since) { ([datetime]$IdleInfo.idle_since).ToString('o') } else { '' })
      error = $(if ($IdleInfo.PSObject.Properties['error']) { [string]$IdleInfo.error } else { '' })
    }
  }

  if ($null -ne $ProbeResult) {
    $payload['probe'] = [ordered]@{
      reachable = [bool]$ProbeResult.reachable
      dns_resolved = [bool]$ProbeResult.dns_resolved
      http_status_code = [int]$ProbeResult.http_status_code
      endpoint = [string]$ProbeResult.endpoint
      phase = [string]$ProbeResult.phase
      error = [string]$ProbeResult.error
    }
  }

  foreach ($key in @($Extra.Keys)) {
    $payload[[string]$key] = $Extra[$key]
  }

  $path = [string]$State.StatusPath
  $dir = Split-Path -Parent $path
  if (-not [string]::IsNullOrWhiteSpace([string]$dir) -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  ($payload | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8
  return [pscustomobject]$payload
}

function Reset-RaymanNetworkResumeState {
  param([object]$State)

  if ($null -eq $State) { return }
  $State.ProviderUnreachableSince = $null
  $State.ThrottledSince = $null
  $State.IdleSince = $null
  $State.ArmedAt = $null
  $State.TriggerKind = ''
  $State.LastProviderReachable = $null
}

function Reset-RaymanNetworkResumeCandidateState {
  param(
    [object]$State,
    [string]$RunId
  )

  if ($null -eq $State) { return }
  Reset-RaymanNetworkResumeState -State $State
  $State.LastCandidateRunId = [string]$RunId
  $State.LastResumeAttemptAt = $null
  $State.AttemptCount = 0
  $State.SuppressedReason = ''
}

function New-RaymanNetworkResumeWatchState {
  param([string]$WorkspaceRoot)

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $runtimeDir = Join-Path $resolvedRoot '.Rayman\runtime'
  if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
  }

  return [pscustomobject]@{
    WorkspaceRoot = $resolvedRoot
    RuntimeDir = $runtimeDir
    StatusPath = (Get-RaymanNetworkResumeStatePath -WorkspaceRoot $resolvedRoot)
    PollMs = (Get-RaymanEnvInt -Name 'RAYMAN_NETWORK_RESUME_POLL_MS' -Default 5000 -Min 1000 -Max 60000)
    ThresholdSeconds = (Get-RaymanEnvInt -Name 'RAYMAN_NETWORK_RESUME_THRESHOLD_SECONDS' -Default 1800 -Min 60 -Max 86400)
    ThrottleWaitSeconds = (Get-RaymanEnvInt -Name 'RAYMAN_NETWORK_RESUME_THROTTLE_WAIT_SECONDS' -Default 300 -Min 30 -Max 86400)
    ProbeTimeoutMs = (Get-RaymanEnvInt -Name 'RAYMAN_NETWORK_RESUME_PROBE_TIMEOUT_MS' -Default 5000 -Min 1000 -Max 60000)
    RetrySeconds = (Get-RaymanEnvInt -Name 'RAYMAN_NETWORK_RESUME_RETRY_SECONDS' -Default 300 -Min 5 -Max 86400)
    MaxAttempts = (Get-RaymanEnvInt -Name 'RAYMAN_NETWORK_RESUME_MAX_ATTEMPTS' -Default 3 -Min 1 -Max 20)
    ProviderUnreachableSince = $null
    ThrottledSince = $null
    IdleSince = $null
    ArmedAt = $null
    TriggerKind = ''
    LastCandidateRunId = ''
    LastResumeAttemptAt = $null
    AttemptCount = 0
    SuppressedReason = ''
    LastProviderReachable = $null
  }
}

function Start-RaymanCodexNativeResumeDetached {
  param(
    [string]$WorkspaceRoot,
    [string]$Prompt
  )

  $auth = Assert-RaymanCodexManagedLogin -WorkspaceRoot $WorkspaceRoot
  $context = $auth.context
  $compatibility = Ensure-RaymanCodexCliCompatible -WorkspaceRoot ([string]$context.workspace_root) -AccountAlias ([string]$context.account_alias)
  if (-not [bool]$compatibility.compatible) {
    $detail = if ([string]::IsNullOrWhiteSpace([string]$compatibility.output)) { [string]$compatibility.reason } else { [string]$compatibility.output }
    throw ("Codex CLI is not compatible for alias '{0}' ({1})." -f [string]$context.account_alias, $detail)
  }

  $codex = Get-RaymanCodexCommandInfo
  if (-not [bool]$codex.available) {
    throw (Get-RaymanCodexCommandNotFoundMessage)
  }

  $finalArgs = Add-RaymanCodexProfileArguments -ArgumentList @('exec', 'resume', '--last', $Prompt) -Profile ([string]$context.effective_profile)
  $invocation = Resolve-RaymanCodexInteractiveInvocation -CodexCommand $codex -ArgumentList $finalArgs
  if (-not [bool]$invocation.available) {
    throw [string]$invocation.error
  }

  $resumeRuntimeDir = Join-Path ([string]$context.workspace_root) '.Rayman\runtime\network_resume'
  if (-not (Test-Path -LiteralPath $resumeRuntimeDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $resumeRuntimeDir | Out-Null
  }

  $logStem = Join-Path $resumeRuntimeDir ('codex_resume_' + [Guid]::NewGuid().ToString('N'))
  $stdoutPath = $logStem + '.stdout.txt'
  $stderrPath = $logStem + '.stderr.txt'
  $startedAt = Get-Date
  $commandText = ((@('codex') + @($finalArgs)) -join ' ').Trim()

  $proc = Use-RaymanTemporaryEnvironment -EnvironmentOverrides @{ CODEX_HOME = [string]$context.codex_home } -ScriptBlock {
    $params = @{
      FilePath = [string]$invocation.file_path
      ArgumentList = @($invocation.argument_list)
      WorkingDirectory = [string]$context.workspace_root
      PassThru = $true
      RedirectStandardOutput = $stdoutPath
      RedirectStandardError = $stderrPath
    }
    if (Test-RaymanWindowsPlatform) {
      $params['WindowStyle'] = 'Hidden'
    }
    Start-Process @params
  }

  Start-Sleep -Milliseconds 200
  try { $proc.Refresh() } catch {}

  $stdout = @()
  $stderr = @()
  if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
    $stdout = @([string[]](Get-Content -LiteralPath $stdoutPath -Encoding UTF8 -ErrorAction SilentlyContinue))
  }
  if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
    $stderr = @([string[]](Get-Content -LiteralPath $stderrPath -Encoding UTF8 -ErrorAction SilentlyContinue))
  }
  $outputText = (@($stdout + $stderr) -join [Environment]::NewLine).Trim()

  if ($proc.HasExited -and [int]$proc.ExitCode -ne 0) {
    return [pscustomobject]@{
      success = $false
      started = $true
      completed = $true
      pid = [int]$proc.Id
      exit_code = [int]$proc.ExitCode
      command = $commandText
      output = $outputText
      error = if ([string]::IsNullOrWhiteSpace($outputText)) { ("process exited with code {0}" -f [int]$proc.ExitCode) } else { $outputText }
      stdout = @($stdout)
      stderr = @($stderr)
      stdout_path = $stdoutPath
      stderr_path = $stderrPath
      started_at = $startedAt.ToString('o')
      finished_at = (Get-Date).ToString('o')
      context = $context
      argument_list = @($finalArgs)
    }
  }

  return [pscustomobject]@{
    success = $true
    started = $true
    completed = [bool]$proc.HasExited
    pid = [int]$proc.Id
    exit_code = if ($proc.HasExited) { [int]$proc.ExitCode } else { 0 }
    command = $commandText
    output = $outputText
    error = ''
    stdout = @($stdout)
    stderr = @($stderr)
    stdout_path = $stdoutPath
    stderr_path = $stderrPath
    started_at = $startedAt.ToString('o')
    finished_at = if ($proc.HasExited) { (Get-Date).ToString('o') } else { '' }
    context = $context
    argument_list = @($finalArgs)
  }
}

function Test-RaymanCodexDesktopLastResumeEligible {
  param(
    [string]$WorkspaceRoot,
    [string]$DesktopSessionPath
  )

  if ([string]::IsNullOrWhiteSpace($DesktopSessionPath) -or -not (Test-Path -LiteralPath $DesktopSessionPath -PathType Leaf)) {
    return $false
  }

  $sessionsRoot = Get-RaymanCodexDesktopSessionsRoot
  if ([string]::IsNullOrWhiteSpace($sessionsRoot) -or -not (Test-Path -LiteralPath $sessionsRoot -PathType Container)) {
    return $false
  }

  $workspaceMatchValue = Get-RaymanPathComparisonValue -PathValue $WorkspaceRoot
  $targetPath = (Resolve-Path -LiteralPath $DesktopSessionPath).Path
  $latestCandidate = $null
  foreach ($sessionFile in @(Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue)) {
    $meta = Get-RaymanNetworkResumeDesktopSessionMeta -SessionPath ([string]$sessionFile.FullName)
    if (-not [bool]$meta.valid) { continue }
    if ((Get-RaymanPathComparisonValue -PathValue ([string]$meta.workspace_root)) -ne $workspaceMatchValue) { continue }
    if ($null -eq $latestCandidate -or $sessionFile.LastWriteTime -gt $latestCandidate.LastWriteTime) {
      $latestCandidate = $sessionFile
    }
  }

  if ($null -eq $latestCandidate) {
    return $false
  }

  return (Test-RaymanPathsEquivalent -LeftPath ([string]$latestCandidate.FullName) -RightPath $targetPath)
}

function Start-RaymanCodexDesktopResumeDetached {
  param(
    [string]$WorkspaceRoot,
    [string]$SessionId = '',
    [string]$Prompt,
    [string]$DesktopSessionPath = ''
  )

  $resolvedWorkspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $codex = Get-RaymanCodexCommandInfo
  if (-not [bool]$codex.available) {
    throw (Get-RaymanCodexCommandNotFoundMessage)
  }

  $desktopCodexHome = Get-RaymanDefaultCodexHomePath
  $resumeTargetKind = 'desktop_session'
  if ([string]::IsNullOrWhiteSpace($SessionId)) {
    if (-not (Test-RaymanCodexDesktopLastResumeEligible -WorkspaceRoot $resolvedWorkspace -DesktopSessionPath $DesktopSessionPath)) {
      throw 'desktop session id missing and --last is not eligible for this workspace.'
    }
    $resumeTargetKind = 'desktop_last'
    $finalArgs = @('resume', '--last', $Prompt)
  } else {
    $finalArgs = @('resume', $SessionId, $Prompt)
  }

  $invocation = Resolve-RaymanCodexInteractiveInvocation -CodexCommand $codex -ArgumentList $finalArgs
  if (-not [bool]$invocation.available) {
    throw [string]$invocation.error
  }

  $resumeRuntimeDir = Join-Path $resolvedWorkspace '.Rayman\runtime\network_resume'
  if (-not (Test-Path -LiteralPath $resumeRuntimeDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $resumeRuntimeDir | Out-Null
  }

  $logStem = Join-Path $resumeRuntimeDir ('codex_desktop_resume_' + [Guid]::NewGuid().ToString('N'))
  $stdoutPath = $logStem + '.stdout.txt'
  $stderrPath = $logStem + '.stderr.txt'
  $startedAt = Get-Date
  $commandText = ((@('codex') + @($finalArgs)) -join ' ').Trim()

  $proc = Use-RaymanTemporaryEnvironment -EnvironmentOverrides @{ CODEX_HOME = [string]$desktopCodexHome } -ScriptBlock {
    $params = @{
      FilePath = [string]$invocation.file_path
      ArgumentList = @($invocation.argument_list)
      WorkingDirectory = $resolvedWorkspace
      PassThru = $true
      RedirectStandardOutput = $stdoutPath
      RedirectStandardError = $stderrPath
    }
    if (Test-RaymanWindowsPlatform) {
      $params['WindowStyle'] = 'Hidden'
    }
    Start-Process @params
  }

  Start-Sleep -Milliseconds 200
  try { $proc.Refresh() } catch {}

  $stdout = @()
  $stderr = @()
  if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
    $stdout = @([string[]](Get-Content -LiteralPath $stdoutPath -Encoding UTF8 -ErrorAction SilentlyContinue))
  }
  if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
    $stderr = @([string[]](Get-Content -LiteralPath $stderrPath -Encoding UTF8 -ErrorAction SilentlyContinue))
  }
  $outputText = (@($stdout + $stderr) -join [Environment]::NewLine).Trim()

  if ($proc.HasExited -and [int]$proc.ExitCode -ne 0) {
    return [pscustomobject]@{
      success = $false
      started = $true
      completed = $true
      pid = [int]$proc.Id
      exit_code = [int]$proc.ExitCode
      command = $commandText
      output = $outputText
      error = if ([string]::IsNullOrWhiteSpace($outputText)) { ("process exited with code {0}" -f [int]$proc.ExitCode) } else { $outputText }
      stdout = @($stdout)
      stderr = @($stderr)
      stdout_path = $stdoutPath
      stderr_path = $stderrPath
      started_at = $startedAt.ToString('o')
      finished_at = (Get-Date).ToString('o')
      session_id = [string]$SessionId
      resume_target_kind = $resumeTargetKind
      desktop_session_path = [string]$DesktopSessionPath
      codex_home = [string]$desktopCodexHome
      argument_list = @($finalArgs)
    }
  }

  return [pscustomobject]@{
    success = $true
    started = $true
    completed = [bool]$proc.HasExited
    pid = [int]$proc.Id
    exit_code = if ($proc.HasExited) { [int]$proc.ExitCode } else { 0 }
    command = $commandText
    output = $outputText
    error = ''
    stdout = @($stdout)
    stderr = @($stderr)
    stdout_path = $stdoutPath
    stderr_path = $stderrPath
    started_at = $startedAt.ToString('o')
    finished_at = if ($proc.HasExited) { (Get-Date).ToString('o') } else { '' }
    session_id = [string]$SessionId
    resume_target_kind = $resumeTargetKind
    desktop_session_path = [string]$DesktopSessionPath
    codex_home = [string]$desktopCodexHome
    argument_list = @($finalArgs)
  }
}

function Invoke-RaymanNetworkResumeCycle {
  param([object]$State)

  if ($null -eq $State) {
    return [pscustomobject]@{
      should_exit = $false
      status = 'state_missing'
    }
  }

  $candidate = Get-RaymanNetworkResumeCandidate -WorkspaceRoot ([string]$State.WorkspaceRoot)
  $idleInfo = Get-RaymanCurrentUserIdleInfo

  if (-not [bool]$candidate.available) {
    if (-not [string]::IsNullOrWhiteSpace([string]$candidate.run_id) -and [string]$candidate.run_id -ne [string]$State.LastCandidateRunId) {
      Reset-RaymanNetworkResumeCandidateState -State $State -RunId ([string]$candidate.run_id)
    } else {
      Reset-RaymanNetworkResumeState -State $State
      $State.LastCandidateRunId = [string]$candidate.run_id
    }
    $State.SuppressedReason = [string]$candidate.reason
    Write-RaymanNetworkResumeStatus -State $State -Status [string]$candidate.reason -Candidate $candidate -IdleInfo $idleInfo -Error [string]$candidate.reason | Out-Null
    return [pscustomobject]@{
      should_exit = $false
      status = [string]$candidate.reason
    }
  }

  if ([string]$candidate.run_id -ne [string]$State.LastCandidateRunId) {
    Reset-RaymanNetworkResumeCandidateState -State $State -RunId ([string]$candidate.run_id)
  }
  $candidateTriggerKind = if ($candidate.PSObject.Properties['trigger_kind']) { [string]$candidate.trigger_kind } else { 'none' }
  if (-not [string]::IsNullOrWhiteSpace($State.TriggerKind) -and $State.TriggerKind -ne $candidateTriggerKind) {
    Reset-RaymanNetworkResumeCandidateState -State $State -RunId ([string]$candidate.run_id)
  }
  $State.TriggerKind = $candidateTriggerKind

  if ($null -ne $idleInfo.idle_since) {
    $State.IdleSince = [datetime]$idleInfo.idle_since
  } else {
    $State.IdleSince = $null
  }

  $probeResult = Test-RaymanNetworkResumeProviderReachable -ProbeUri $candidate.probe.probe_uri -TimeoutMs ([int]$State.ProbeTimeoutMs)
  $wasReachable = $State.LastProviderReachable
  $State.LastProviderReachable = [bool]$probeResult.reachable

  if (-not [bool]$candidate.native_resume_supported) {
    Reset-RaymanNetworkResumeState -State $State
    $State.SuppressedReason = 'unsupported_native_resume'
    Write-RaymanNetworkResumeStatus -State $State -Status 'unsupported_native_resume' -Candidate $candidate -IdleInfo $idleInfo -ProbeResult $probeResult -Error 'unsupported_native_resume' | Out-Null
    return [pscustomobject]@{
      should_exit = $false
      status = 'unsupported_native_resume'
    }
  }

  if ($candidateTriggerKind -eq 'throttle' -and [bool]$probeResult.reachable) {
    $State.ProviderUnreachableSince = $null
    if ($null -eq $State.ThrottledSince) {
      $State.ThrottledSince = if ($null -ne $candidate.failure_started_at) { [datetime]$candidate.failure_started_at } else { Get-Date }
    }

    if ($null -eq $State.IdleSince) {
      $State.ArmedAt = $null
      $State.SuppressedReason = 'idle_unavailable'
      Write-RaymanNetworkResumeStatus -State $State -Status 'idle_unavailable' -Candidate $candidate -IdleInfo $idleInfo -ProbeResult $probeResult -Error 'idle_unavailable' | Out-Null
      return [pscustomobject]@{
        should_exit = $false
        status = 'idle_unavailable'
      }
    }

    $throttleOverlapStart = if ([datetime]$State.ThrottledSince -gt [datetime]$State.IdleSince) { [datetime]$State.ThrottledSince } else { [datetime]$State.IdleSince }
    $throttleOverlapSeconds = [int][Math]::Max(0, [Math]::Floor(((Get-Date) - $throttleOverlapStart).TotalSeconds))
    if ($throttleOverlapSeconds -lt [int]$State.ThrottleWaitSeconds) {
      $State.ArmedAt = $null
      $State.SuppressedReason = 'throttle_wait'
      Write-RaymanNetworkResumeStatus -State $State -Status 'throttle_wait' -Candidate $candidate -IdleInfo $idleInfo -ProbeResult $probeResult -Extra @{
        overlap_started_at = $throttleOverlapStart.ToString('o')
        overlap_seconds = $throttleOverlapSeconds
      } | Out-Null
      return [pscustomobject]@{
        should_exit = $false
        status = 'throttle_wait'
      }
    }

    if ($null -eq $State.ArmedAt) {
      $State.ArmedAt = Get-Date
    }
    $State.SuppressedReason = ''
    Write-RaymanNetworkResumeStatus -State $State -Status 'throttle_armed' -Candidate $candidate -IdleInfo $idleInfo -ProbeResult $probeResult -Extra @{
      overlap_started_at = $throttleOverlapStart.ToString('o')
      overlap_seconds = $throttleOverlapSeconds
    } | Out-Null
  } else {
    $State.TriggerKind = 'network'
    $State.ThrottledSince = $null

    if (-not [bool]$probeResult.reachable) {
      if ($null -eq $State.ProviderUnreachableSince) {
        if ($candidateTriggerKind -eq 'network' -and $null -ne $candidate.failure_started_at) {
          $State.ProviderUnreachableSince = [datetime]$candidate.failure_started_at
        } else {
          $State.ProviderUnreachableSince = Get-Date
        }
      }

      if ($null -eq $State.IdleSince) {
        $State.ArmedAt = $null
        $State.SuppressedReason = 'idle_unavailable'
        Write-RaymanNetworkResumeStatus -State $State -Status 'idle_unavailable' -Candidate $candidate -IdleInfo $idleInfo -ProbeResult $probeResult -Error 'idle_unavailable' | Out-Null
        return [pscustomobject]@{
          should_exit = $false
          status = 'idle_unavailable'
        }
      }

      $overlapStart = if ([datetime]$State.ProviderUnreachableSince -gt [datetime]$State.IdleSince) { [datetime]$State.ProviderUnreachableSince } else { [datetime]$State.IdleSince }
      $overlapSeconds = [int][Math]::Max(0, [Math]::Floor(((Get-Date) - $overlapStart).TotalSeconds))
      if ($overlapSeconds -ge [int]$State.ThresholdSeconds) {
        if ($null -eq $State.ArmedAt) {
          $State.ArmedAt = Get-Date
        }
        $State.SuppressedReason = ''
        Write-RaymanNetworkResumeStatus -State $State -Status 'armed' -Candidate $candidate -IdleInfo $idleInfo -ProbeResult $probeResult -Extra @{
          overlap_started_at = $overlapStart.ToString('o')
          overlap_seconds = $overlapSeconds
        } | Out-Null
        return [pscustomobject]@{
          should_exit = $false
          status = 'armed'
        }
      }

      $State.ArmedAt = $null
      $State.SuppressedReason = 'threshold_not_met'
      Write-RaymanNetworkResumeStatus -State $State -Status 'provider_unreachable' -Candidate $candidate -IdleInfo $idleInfo -ProbeResult $probeResult -Extra @{
        overlap_started_at = $overlapStart.ToString('o')
        overlap_seconds = $overlapSeconds
      } | Out-Null
      return [pscustomobject]@{
        should_exit = $false
        status = 'provider_unreachable'
      }
    }

    $recoveredEdge = ($wasReachable -eq $false)
    if (-not $recoveredEdge) {
      $State.ProviderUnreachableSince = $null
      $State.ArmedAt = $null
      $State.SuppressedReason = 'provider_reachable'
      Write-RaymanNetworkResumeStatus -State $State -Status 'provider_reachable' -Candidate $candidate -IdleInfo $idleInfo -ProbeResult $probeResult | Out-Null
      return [pscustomobject]@{
        should_exit = $false
        status = 'provider_reachable'
      }
    }

    if ($null -eq $State.ArmedAt) {
      $State.ProviderUnreachableSince = $null
      $State.SuppressedReason = 'restored_before_threshold'
      Write-RaymanNetworkResumeStatus -State $State -Status 'restored_before_threshold' -Candidate $candidate -IdleInfo $idleInfo -ProbeResult $probeResult | Out-Null
      return [pscustomobject]@{
        should_exit = $false
        status = 'restored_before_threshold'
      }
    }
  }

  if ($null -ne $State.LastResumeAttemptAt) {
    $elapsedSinceAttempt = [int][Math]::Max(0, [Math]::Floor(((Get-Date) - [datetime]$State.LastResumeAttemptAt).TotalSeconds))
    if ($elapsedSinceAttempt -lt [int]$State.RetrySeconds) {
      $State.ProviderUnreachableSince = $null
      $State.ArmedAt = $null
      $State.SuppressedReason = 'cooldown_active'
      Write-RaymanNetworkResumeStatus -State $State -Status 'cooldown_active' -Candidate $candidate -IdleInfo $idleInfo -ProbeResult $probeResult -Extra @{
        cooldown_remaining_seconds = ([int]$State.RetrySeconds - $elapsedSinceAttempt)
      } | Out-Null
      return [pscustomobject]@{
        should_exit = $false
        status = 'cooldown_active'
      }
    }
  }

  if ([int]$State.AttemptCount -ge [int]$State.MaxAttempts) {
    $State.ProviderUnreachableSince = $null
    $State.ArmedAt = $null
    $State.SuppressedReason = 'max_attempts_reached'
    Write-RaymanNetworkResumeStatus -State $State -Status 'max_attempts_reached' -Candidate $candidate -IdleInfo $idleInfo -ProbeResult $probeResult -Error 'max_attempts_reached' | Out-Null
    return [pscustomobject]@{
      should_exit = $false
      status = 'max_attempts_reached'
    }
  }

  $now = Get-Date
  $State.LastResumeAttemptAt = $now
  $State.AttemptCount = [int]$State.AttemptCount + 1
  $resumePrompt = Get-RaymanNetworkResumePrompt
  $candidateSource = if ($candidate.PSObject.Properties['candidate_source']) { [string]$candidate.candidate_source } else { 'agent_run' }
  Write-RaymanDiag -Scope 'network-resume' -Message ("attempt native resume; run_id={0}; backend={1}; source={2}; attempt={3}" -f [string]$candidate.run_id, [string]$candidate.backend, $candidateSource, [int]$State.AttemptCount) -WorkspaceRoot ([string]$State.WorkspaceRoot)

  try {
    $resumeResult = if ($candidateSource -eq 'codex_desktop_session') {
      Start-RaymanCodexDesktopResumeDetached -WorkspaceRoot ([string]$State.WorkspaceRoot) -SessionId $(if ($candidate.PSObject.Properties['desktop_session_id']) { [string]$candidate.desktop_session_id } else { '' }) -Prompt $resumePrompt -DesktopSessionPath $(if ($candidate.PSObject.Properties['desktop_session_path']) { [string]$candidate.desktop_session_path } else { '' })
    } else {
      Start-RaymanCodexNativeResumeDetached -WorkspaceRoot ([string]$State.WorkspaceRoot) -Prompt $resumePrompt
    }
    $State.ProviderUnreachableSince = $null
    $State.ThrottledSince = $null
    $State.ArmedAt = $null
    if ([bool]$resumeResult.success) {
      $State.SuppressedReason = 'resume_started'
      Write-RaymanDiag -Scope 'network-resume' -Message ("native resume succeeded; run_id={0}; source={1}; command={2}" -f [string]$candidate.run_id, $candidateSource, [string]$resumeResult.command) -WorkspaceRoot ([string]$State.WorkspaceRoot)
      Write-RaymanNetworkResumeStatus -State $State -Status 'resumed' -Candidate $candidate -IdleInfo $idleInfo -ProbeResult $probeResult -Extra @{
        resume_command = [string]$resumeResult.command
        resume_exit_code = [int]$resumeResult.exit_code
        resume_pid = if ($resumeResult.PSObject.Properties['pid']) { [int]$resumeResult.pid } else { 0 }
        resume_completed = if ($resumeResult.PSObject.Properties['completed']) { [bool]$resumeResult.completed } else { $false }
        resume_stdout_path = if ($resumeResult.PSObject.Properties['stdout_path']) { [string]$resumeResult.stdout_path } else { '' }
        resume_stderr_path = if ($resumeResult.PSObject.Properties['stderr_path']) { [string]$resumeResult.stderr_path } else { '' }
        resume_target_kind = if ($resumeResult.PSObject.Properties['resume_target_kind']) { [string]$resumeResult.resume_target_kind } elseif ($candidate.PSObject.Properties['resume_target_kind']) { [string]$candidate.resume_target_kind } else { '' }
      } | Out-Null
      return [pscustomobject]@{
        should_exit = $false
        status = 'resumed'
      }
    }

    $resumeError = if ([string]::IsNullOrWhiteSpace([string]$resumeResult.error)) { [string]$resumeResult.output } else { [string]$resumeResult.error }
    $State.SuppressedReason = 'resume_unavailable'
    Write-RaymanDiag -Scope 'network-resume' -Message ("native resume unavailable; run_id={0}; source={1}; error={2}" -f [string]$candidate.run_id, $candidateSource, $resumeError) -WorkspaceRoot ([string]$State.WorkspaceRoot)
    Invoke-RaymanAttentionAlert -Kind 'manual' -Title 'Rayman 网络续接失败' -Reason ("网络已恢复，但原生续接失败：{0}" -f $resumeError) -WorkspaceRoot ([string]$State.WorkspaceRoot) | Out-Null
    Write-RaymanNetworkResumeStatus -State $State -Status 'resume_unavailable' -Candidate $candidate -IdleInfo $idleInfo -ProbeResult $probeResult -Error $resumeError -Extra @{
      resume_command = [string]$resumeResult.command
      resume_exit_code = [int]$resumeResult.exit_code
      resume_target_kind = if ($resumeResult.PSObject.Properties['resume_target_kind']) { [string]$resumeResult.resume_target_kind } elseif ($candidate.PSObject.Properties['resume_target_kind']) { [string]$candidate.resume_target_kind } else { '' }
    } | Out-Null
    return [pscustomobject]@{
      should_exit = $false
      status = 'resume_unavailable'
    }
  } catch {
    $State.ProviderUnreachableSince = $null
    $State.ThrottledSince = $null
    $State.ArmedAt = $null
    $State.SuppressedReason = 'resume_unavailable'
    $resumeError = $_.Exception.Message
    Write-RaymanDiag -Scope 'network-resume' -Message ("native resume exception; run_id={0}; source={1}; error={2}" -f [string]$candidate.run_id, $candidateSource, $_.Exception.ToString()) -WorkspaceRoot ([string]$State.WorkspaceRoot)
    Invoke-RaymanAttentionAlert -Kind 'manual' -Title 'Rayman 网络续接失败' -Reason ("网络已恢复，但原生续接失败：{0}" -f $resumeError) -WorkspaceRoot ([string]$State.WorkspaceRoot) | Out-Null
    Write-RaymanNetworkResumeStatus -State $State -Status 'resume_unavailable' -Candidate $candidate -IdleInfo $idleInfo -ProbeResult $probeResult -Error $resumeError | Out-Null
    return [pscustomobject]@{
      should_exit = $false
      status = 'resume_unavailable'
    }
  }
}

function New-RaymanAutoSaveWatchState {
  param([string]$WorkspaceRoot)

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $stateDir = Join-Path $resolvedRoot '.Rayman\state'
  if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
  }

  return [pscustomobject]@{
    WorkspaceRoot = $resolvedRoot
    StateDir = $stateDir
    PatchFile = Join-Path $stateDir 'auto_save.patch'
    MetaFile = Join-Path $stateDir 'auto_save_meta.json'
  }
}

function Invoke-RaymanAutoSaveCycle {
  param([object]$State)

  if ($null -eq $State) {
    return [pscustomobject]@{
      saved = $false
      files_changed = 0
      reason = 'state_missing'
    }
  }

  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    return [pscustomobject]@{
      saved = $false
      files_changed = 0
      reason = 'git_missing'
    }
  }

  $savedLocation = Get-Location
  try {
    Set-Location -LiteralPath ([string]$State.WorkspaceRoot)

    $inWorkTree = $false
    try {
      $null = git rev-parse --is-inside-work-tree 2>$null
      if ($LASTEXITCODE -eq 0) { $inWorkTree = $true }
    } catch {}

    if (-not $inWorkTree) {
      return [pscustomobject]@{
        saved = $false
        files_changed = 0
        reason = 'not_git_worktree'
      }
    }

    $targetPaths = if (Get-Command Resolve-RaymanAutoSaveTargetPaths -ErrorAction SilentlyContinue) {
      Resolve-RaymanAutoSaveTargetPaths -WorkspaceRoot ([string]$State.WorkspaceRoot)
    } else {
      [pscustomobject]@{
        auto_save_patch_path = [string]$State.PatchFile
        auto_save_meta_path = [string]$State.MetaFile
      }
    }

    $patchPath = if ($targetPaths.PSObject.Properties['auto_save_patch_path']) {
      [string]$targetPaths.auto_save_patch_path
    } else {
      [string]$State.PatchFile
    }
    $metaPath = if ($targetPaths.PSObject.Properties['auto_save_meta_path']) {
      [string]$targetPaths.auto_save_meta_path
    } else {
      [string]$State.MetaFile
    }

    $status = @(git status --porcelain)
    if ($status.Count -gt 0) {
      git add -N . | Out-Null
      $patchDir = Split-Path -Parent $patchPath
      if (-not [string]::IsNullOrWhiteSpace($patchDir) -and -not (Test-Path -LiteralPath $patchDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $patchDir | Out-Null
      }
      $patchContent = @(git diff) -join [Environment]::NewLine
      if (Get-Command Write-RaymanSessionTextFile -ErrorAction SilentlyContinue) {
        Write-RaymanSessionTextFile -Path $patchPath -Content (($patchContent.TrimEnd()) + [Environment]::NewLine)
      } else {
        $patchContent | Set-Content -LiteralPath $patchPath -Encoding UTF8
      }

      $meta = [ordered]@{
        timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        files_changed = $status.Count
      }
      if (Get-Command Write-RaymanSessionJsonFile -ErrorAction SilentlyContinue) {
        Write-RaymanSessionJsonFile -Path $metaPath -Value $meta
      } else {
        $meta | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $metaPath -Encoding UTF8
      }

      Write-Host ("[auto-save] {0} 自动保存了 {1} 个文件的更改到 {2}" -f (Get-Date -Format 'HH:mm:ss'), $status.Count, $patchPath)
      return [pscustomobject]@{
        saved = $true
        files_changed = $status.Count
        reason = 'saved'
      }
    }

    if (Test-Path -LiteralPath $patchPath -PathType Leaf) {
      Remove-Item -LiteralPath $patchPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
      Remove-Item -LiteralPath $metaPath -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
      saved = $false
      files_changed = 0
      reason = 'clean'
    }
  } finally {
    Set-Location -LiteralPath $savedLocation.Path
  }
}
