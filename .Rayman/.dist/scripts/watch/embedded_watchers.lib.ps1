if (-not (Get-Command Resolve-RaymanAutoSaveTargetPaths -ErrorAction SilentlyContinue)) {
  $sessionCommonPath = Join-Path $PSScriptRoot '..\state\session_common.ps1'
  if (Test-Path -LiteralPath $sessionCommonPath -PathType Leaf) {
    . $sessionCommonPath
  }
}

if (-not (Get-Command Ensure-RaymanSharedSession -ErrorAction SilentlyContinue)) {
  $sharedSessionCommonPath = Join-Path $PSScriptRoot '..\state\shared_session_common.ps1'
  if (Test-Path -LiteralPath $sharedSessionCommonPath -PathType Leaf) {
    . $sharedSessionCommonPath
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

function Get-RaymanNetworkResumeRuntimeDirectory {
  param([string]$WorkspaceRoot)

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $runtimeDir = Join-Path $resolvedRoot '.Rayman\runtime\network_resume'
  if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
  }
  return $runtimeDir
}

function Get-RaymanNetworkResumePendingStatePath {
  param([string]$WorkspaceRoot)

  return (Join-Path (Get-RaymanNetworkResumeRuntimeDirectory -WorkspaceRoot $WorkspaceRoot) 'pending_continuation.json')
}

function Get-RaymanNetworkResumeDispatchSummaryPath {
  param([string]$WorkspaceRoot)

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  return (Join-Path $resolvedRoot '.Rayman\runtime\agent_runs\last.json')
}

function Read-RaymanNetworkResumeJsonOrNull {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace([string]$Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  if (Get-Command Read-RaymanJsonFile -ErrorAction SilentlyContinue) {
    $doc = Read-RaymanJsonFile -Path $Path
    if ($null -ne $doc -and [bool]$doc.Exists -and -not [bool]$doc.ParseFailed) {
      return $doc.Obj
    }
    return $null
  }

  try {
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Read-RaymanNetworkResumePendingState {
  param([string]$WorkspaceRoot)

  return (Read-RaymanNetworkResumeJsonOrNull -Path (Get-RaymanNetworkResumePendingStatePath -WorkspaceRoot $WorkspaceRoot))
}

function Write-RaymanNetworkResumePendingState {
  param(
    [string]$WorkspaceRoot,
    [object]$Pending
  )

  $path = Get-RaymanNetworkResumePendingStatePath -WorkspaceRoot $WorkspaceRoot
  $jsonText = (($Pending | ConvertTo-Json -Depth 16).TrimEnd() + "`n")
  if (Get-Command Write-RaymanUtf8NoBom -ErrorAction SilentlyContinue) {
    Write-RaymanUtf8NoBom -Path $path -Content $jsonText
  } else {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $jsonText, $encoding)
  }
  return $path
}

function Remove-RaymanNetworkResumePendingState {
  param([string]$WorkspaceRoot)

  $path = Get-RaymanNetworkResumePendingStatePath -WorkspaceRoot $WorkspaceRoot
  if (Test-Path -LiteralPath $path -PathType Leaf) {
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    return $true
  }
  return $false
}

function Get-RaymanNetworkResumeFirstSaveIdleSeconds {
  return 60
}

function Get-RaymanNetworkResumeStableHash {
  param([AllowEmptyString()][string]$Value)

  if (Get-Command Get-RaymanSharedSessionStableHash -ErrorAction SilentlyContinue) {
    return (Get-RaymanSharedSessionStableHash -Value $Value)
  }
  if (Get-Command Get-RaymanSessionStableHash -ErrorAction SilentlyContinue) {
    return (Get-RaymanSessionStableHash -Value $Value)
  }

  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Value)
    $hash = $sha.ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Get-RaymanNetworkResumeIdentityKey {
  param(
    [string]$TaskKind = '',
    [string]$TaskIntent = '',
    [string]$EffectiveTaskKey = '',
    [string]$SharedSessionId = '',
    [string]$RunId = ''
  )

  return (Get-RaymanNetworkResumeStableHash -Value (($TaskKind, $TaskIntent, $EffectiveTaskKey, $SharedSessionId, $RunId) -join '|'))
}

function Get-RaymanNetworkResumePreviewText {
  param(
    [string]$Text,
    [int]$MaxLength = 2400
  )

  $normalized = ([string]$Text).Trim()
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    return ''
  }

  if ($normalized.Length -gt $MaxLength) {
    return ($normalized.Substring(0, $MaxLength) + '...')
  }
  return $normalized
}

function Get-RaymanNetworkResumeTaskIntentFromSummary {
  param([object]$Summary)

  if ($null -eq $Summary) {
    return ''
  }

  $networkResume = if ($Summary.PSObject.Properties['network_resume']) { $Summary.network_resume } else { $null }
  foreach ($value in @(
      $(if ($null -ne $networkResume -and $networkResume.PSObject.Properties['task_intent']) { [string]$networkResume.task_intent } else { '' }),
      $(if ($Summary.PSObject.Properties['task']) { [string]$Summary.task } else { '' }),
      $(if ($Summary.PSObject.Properties['executed_command']) { [string]$Summary.executed_command } else { '' }),
      $(if ($Summary.PSObject.Properties['selection_reason']) { [string]$Summary.selection_reason } else { '' })
    )) {
    if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
      return ([string]$value).Trim()
    }
  }

  return ''
}

function Get-RaymanNetworkResumeSummaryState {
  param(
    [object]$Summary,
    [object]$Candidate = $null
  )

  $networkResume = if ($null -ne $Summary -and $Summary.PSObject.Properties['network_resume']) { $Summary.network_resume } else { $null }
  $tempCheckpoint = if ($null -ne $Summary -and $Summary.PSObject.Properties['temp_checkpoint']) { $Summary.temp_checkpoint } else { $null }
  $tempArtifacts = if ($null -ne $tempCheckpoint -and $tempCheckpoint.PSObject.Properties['artifacts']) { $tempCheckpoint.artifacts } else { $null }
  $sharedSession = if ($null -ne $Summary -and $Summary.PSObject.Properties['shared_session']) { $Summary.shared_session } else { $null }

  $taskIntent = Get-RaymanNetworkResumeTaskIntentFromSummary -Summary $Summary
  $taskKind = if ($null -ne $networkResume -and $networkResume.PSObject.Properties['task_kind'] -and -not [string]::IsNullOrWhiteSpace([string]$networkResume.task_kind)) {
    [string]$networkResume.task_kind
  } elseif ($null -ne $Summary -and $Summary.PSObject.Properties['task_kind']) {
    [string]$Summary.task_kind
  } else {
    'dispatch'
  }

  $preferredBackend = if ($null -ne $networkResume -and $networkResume.PSObject.Properties['preferred_backend'] -and -not [string]::IsNullOrWhiteSpace([string]$networkResume.preferred_backend)) {
    [string]$networkResume.preferred_backend
  } elseif ($null -ne $Summary -and $Summary.PSObject.Properties['preferred_backend']) {
    [string]$Summary.preferred_backend
  } elseif ($null -ne $Summary -and $Summary.PSObject.Properties['selected_backend']) {
    [string]$Summary.selected_backend
  } elseif ($null -ne $Candidate -and $Candidate.PSObject.Properties['backend']) {
    [string]$Candidate.backend
  } else {
    ''
  }

  $selectedBackend = if ($null -ne $networkResume -and $networkResume.PSObject.Properties['selected_backend'] -and -not [string]::IsNullOrWhiteSpace([string]$networkResume.selected_backend)) {
    [string]$networkResume.selected_backend
  } elseif ($null -ne $Summary -and $Summary.PSObject.Properties['selected_backend']) {
    [string]$Summary.selected_backend
  } elseif ($null -ne $Candidate -and $Candidate.PSObject.Properties['backend']) {
    [string]$Candidate.backend
  } else {
    ''
  }

  $sharedSessionId = if ($null -ne $networkResume -and $networkResume.PSObject.Properties['shared_session_id'] -and -not [string]::IsNullOrWhiteSpace([string]$networkResume.shared_session_id)) {
    [string]$networkResume.shared_session_id
  } elseif ($null -ne $sharedSession -and $sharedSession.PSObject.Properties['session_id']) {
    [string]$sharedSession.session_id
  } else {
    ''
  }

  $sharedSessionTaskSlug = if ($null -ne $networkResume -and $networkResume.PSObject.Properties['shared_session_task_slug'] -and -not [string]::IsNullOrWhiteSpace([string]$networkResume.shared_session_task_slug)) {
    [string]$networkResume.shared_session_task_slug
  } elseif ($null -ne $sharedSession -and $sharedSession.PSObject.Properties['task_slug']) {
    [string]$sharedSession.task_slug
  } else {
    ''
  }

  $sessionSlug = if ($null -ne $networkResume -and $networkResume.PSObject.Properties['session_slug'] -and -not [string]::IsNullOrWhiteSpace([string]$networkResume.session_slug)) {
    [string]$networkResume.session_slug
  } elseif ($null -ne $tempCheckpoint -and $tempCheckpoint.PSObject.Properties['session_slug']) {
    [string]$tempCheckpoint.session_slug
  } else {
    ''
  }

  $handoverPath = if ($null -ne $networkResume -and $networkResume.PSObject.Properties['handover_path']) {
    [string]$networkResume.handover_path
  } elseif ($null -ne $tempArtifacts -and $tempArtifacts.PSObject.Properties['handover_path']) {
    [string]$tempArtifacts.handover_path
  } else {
    ''
  }

  $patchPath = if ($null -ne $networkResume -and $networkResume.PSObject.Properties['patch_path']) {
    [string]$networkResume.patch_path
  } elseif ($null -ne $tempArtifacts -and $tempArtifacts.PSObject.Properties['auto_save_patch_path']) {
    [string]$tempArtifacts.auto_save_patch_path
  } else {
    ''
  }

  $metaPath = if ($null -ne $networkResume -and $networkResume.PSObject.Properties['meta_path']) {
    [string]$networkResume.meta_path
  } elseif ($null -ne $tempArtifacts -and $tempArtifacts.PSObject.Properties['auto_save_meta_path']) {
    [string]$tempArtifacts.auto_save_meta_path
  } else {
    ''
  }

  $checkpointId = if ($null -ne $networkResume -and $networkResume.PSObject.Properties['checkpoint_id']) {
    [string]$networkResume.checkpoint_id
  } elseif ($null -ne $sharedSession -and $sharedSession.PSObject.Properties['checkpoint_id']) {
    [string]$sharedSession.checkpoint_id
  } else {
    ''
  }

  return [pscustomobject]@{
    task_kind = $taskKind
    task_intent = $taskIntent
    effective_task_key = $(if ($null -ne $Summary -and $Summary.PSObject.Properties['effective_task_key']) { [string]$Summary.effective_task_key } else { '' })
    preferred_backend = $preferredBackend
    selected_backend = $selectedBackend
    account_alias = if ($null -ne $networkResume -and $networkResume.PSObject.Properties['account_alias']) { [string]$networkResume.account_alias } else { '' }
    shared_session_id = $sharedSessionId
    shared_session_task_slug = $sharedSessionTaskSlug
    checkpoint_id = $checkpointId
    session_slug = $sessionSlug
    handover_path = $handoverPath
    patch_path = $patchPath
    meta_path = $metaPath
    generated_at = $(if ($null -ne $Summary -and $Summary.PSObject.Properties['generated_at']) { [string]$Summary.generated_at } else { '' })
    run_id = $(if ($null -ne $Summary -and $Summary.PSObject.Properties['run_id']) { [string]$Summary.run_id } else { '' })
  }
}

function Test-RaymanNetworkResumeSummaryMatchesPending {
  param(
    [object]$Summary,
    [object]$Pending
  )

  if ($null -eq $Summary -or $null -eq $Pending) {
    return $false
  }

  $summaryState = Get-RaymanNetworkResumeSummaryState -Summary $Summary
  if (-not [string]::IsNullOrWhiteSpace([string]$Pending.shared_session_id) -and [string]$summaryState.shared_session_id -eq [string]$Pending.shared_session_id) {
    return $true
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$Pending.effective_task_key) -and [string]$summaryState.effective_task_key -eq [string]$Pending.effective_task_key) {
    return $true
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$Pending.identity_key)) {
    $summaryIdentityKey = Get-RaymanNetworkResumeIdentityKey -TaskKind ([string]$summaryState.task_kind) -TaskIntent ([string]$summaryState.task_intent) -EffectiveTaskKey ([string]$summaryState.effective_task_key) -SharedSessionId ([string]$summaryState.shared_session_id) -RunId ([string]$summaryState.run_id)
    if ([string]$summaryIdentityKey -eq [string]$Pending.identity_key) {
      return $true
    }
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$Pending.run_id) -and $Summary.PSObject.Properties['run_id'] -and [string]$Summary.run_id -eq [string]$Pending.run_id) {
    return $true
  }
  return $false
}

function Get-RaymanNetworkResumeRetryDueAt {
  param(
    [object]$Pending,
    [int]$RetrySeconds
  )

  if ($null -eq $Pending) {
    return $null
  }

  $baseTime = ConvertTo-RaymanNullableDateTime -Value $(if ($Pending.PSObject.Properties['last_attempt_at']) { [string]$Pending.last_attempt_at } else { '' })
  if ($null -eq $baseTime) {
    $baseTime = ConvertTo-RaymanNullableDateTime -Value $(if ($Pending.PSObject.Properties['first_saved_at']) { [string]$Pending.first_saved_at } else { '' })
  }
  if ($null -eq $baseTime) {
    return $null
  }
  return ([datetime]$baseTime).AddSeconds([int][Math]::Max(60, $RetrySeconds))
}

function Format-RaymanNetworkResumeSharedSessionPreamble {
  param(
    [string]$SessionId,
    [string]$TaskSlug,
    [object]$Continuation
  )

  if ($null -eq $Continuation) {
    return ''
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('[RaymanSharedSession]') | Out-Null
  $lines.Add(("session_id={0}" -f [string]$SessionId)) | Out-Null
  if (-not [string]::IsNullOrWhiteSpace([string]$TaskSlug)) {
    $lines.Add(("task_slug={0}" -f [string]$TaskSlug)) | Out-Null
  }
  if ($Continuation.PSObject.Properties['summary_text'] -and -not [string]::IsNullOrWhiteSpace([string]$Continuation.summary_text)) {
    $lines.Add(("summary={0}" -f [string]$Continuation.summary_text)) | Out-Null
  }

  $nativeLinks = @($(if ($Continuation.PSObject.Properties['native_resume_links']) { $Continuation.native_resume_links } else { @() }))
  if ($nativeLinks.Count -gt 0) {
    $lines.Add('native_resume_links:') | Out-Null
    foreach ($link in $nativeLinks) {
      $lines.Add(("- {0}:{1} mode={2}" -f [string]$link.vendor_name, [string]$link.vendor_session_id, [string]$link.continuity_mode)) | Out-Null
    }
  }

  $queuedMessages = @($(if ($Continuation.PSObject.Properties['queued_messages']) { $Continuation.queued_messages } else { @() }))
  if ($queuedMessages.Count -gt 0) {
    $lines.Add('queued_messages:') | Out-Null
    foreach ($message in $queuedMessages | Select-Object -First 3) {
      $text = Get-RaymanNetworkResumePreviewText -Text ([string]$message.content_text) -MaxLength 240
      $lines.Add(("- [{0}] {1}" -f [string]$message.role, $text)) | Out-Null
    }
  }

  $recentTail = @($(if ($Continuation.PSObject.Properties['recent_tail']) { $Continuation.recent_tail } else { @() }))
  if ($recentTail.Count -gt 0) {
    $lines.Add('recent_tail:') | Out-Null
    foreach ($message in $recentTail | Select-Object -Last 4) {
      $text = if (-not [string]::IsNullOrWhiteSpace([string]$message.resume_text)) { [string]$message.resume_text } else { [string]$message.content_text }
      $text = Get-RaymanNetworkResumePreviewText -Text $text -MaxLength 240
      $lines.Add(("- [{0}] {1}" -f [string]$message.role, $text)) | Out-Null
    }
  }
  $lines.Add('[/RaymanSharedSession]') | Out-Null
  return ($lines -join "`n")
}

function Get-RaymanNetworkResumeContinuationPreamble {
  param(
    [string]$WorkspaceRoot,
    [object]$Pending
  )

  $parts = New-Object System.Collections.Generic.List[string]
  $parts.Add('[RaymanNetworkResume]') | Out-Null
  $parts.Add((Get-RaymanNetworkResumePrompt)) | Out-Null

  if ($null -ne $Pending -and $Pending.PSObject.Properties['shared_session_id'] -and -not [string]::IsNullOrWhiteSpace([string]$Pending.shared_session_id) -and (Get-Command Get-RaymanSharedSessionContinueContext -ErrorAction SilentlyContinue)) {
    try {
      $context = Get-RaymanSharedSessionContinueContext -WorkspaceRoot $WorkspaceRoot -SessionId ([string]$Pending.shared_session_id) -MessageLimit 120
      if ($null -ne $context -and [bool]$context.success -and $context.PSObject.Properties['continuation']) {
        $sharedPreamble = Format-RaymanNetworkResumeSharedSessionPreamble -SessionId ([string]$Pending.shared_session_id) -TaskSlug $(if ($Pending.PSObject.Properties['shared_session_task_slug']) { [string]$Pending.shared_session_task_slug } else { '' }) -Continuation $context.continuation
        if (-not [string]::IsNullOrWhiteSpace($sharedPreamble)) {
          $parts.Add($sharedPreamble) | Out-Null
        }
      }
    } catch {}
  }

  $handoverPath = if ($null -ne $Pending -and $Pending.PSObject.Properties['handover_path']) { [string]$Pending.handover_path } else { '' }
  if (-not [string]::IsNullOrWhiteSpace($handoverPath) -and (Test-Path -LiteralPath $handoverPath -PathType Leaf)) {
    try {
      $handoverText = Get-RaymanNetworkResumePreviewText -Text (Get-Content -LiteralPath $handoverPath -Raw -Encoding UTF8 -ErrorAction Stop) -MaxLength 2400
      if (-not [string]::IsNullOrWhiteSpace($handoverText)) {
        $parts.Add('[RaymanSavedState]') | Out-Null
        $parts.Add($handoverText) | Out-Null
        $parts.Add('[/RaymanSavedState]') | Out-Null
      }
    } catch {}
  }

  if ($null -ne $Pending -and $Pending.PSObject.Properties['failure_text'] -and -not [string]::IsNullOrWhiteSpace([string]$Pending.failure_text)) {
    $parts.Add(("latest_failure={0}" -f (Get-RaymanNetworkResumePreviewText -Text ([string]$Pending.failure_text) -MaxLength 600))) | Out-Null
  }

  $parts.Add('[/RaymanNetworkResume]') | Out-Null
  return (($parts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "`n")
}

function Save-RaymanNetworkResumePendingStateFromCandidate {
  param(
    [string]$WorkspaceRoot,
    [object]$Candidate,
    [object]$ExistingPending = $null
  )

  if ($null -eq $Candidate -or -not [bool]$Candidate.available) {
    return $null
  }

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $summary = if ($Candidate.PSObject.Properties['summary']) { $Candidate.summary } else { $null }
  $summaryState = Get-RaymanNetworkResumeSummaryState -Summary $summary -Candidate $Candidate
  $taskIntent = [string]$summaryState.task_intent
  if ([string]::IsNullOrWhiteSpace($taskIntent)) {
    $taskIntent = if ($Candidate.PSObject.Properties['desktop_session_id'] -and -not [string]::IsNullOrWhiteSpace([string]$Candidate.desktop_session_id)) {
      ('continue desktop session ' + [string]$Candidate.desktop_session_id)
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$Candidate.run_id)) {
      ('continue interrupted task ' + [string]$Candidate.run_id)
    } else {
      'continue interrupted workspace task'
    }
  }

  $taskKind = if ([string]::IsNullOrWhiteSpace([string]$summaryState.task_kind)) { 'dispatch' } else { [string]$summaryState.task_kind }
  $preferredBackend = if (-not [string]::IsNullOrWhiteSpace([string]$summaryState.preferred_backend)) { [string]$summaryState.preferred_backend } elseif ($Candidate.PSObject.Properties['backend']) { [string]$Candidate.backend } else { '' }
  $selectedBackend = if (-not [string]::IsNullOrWhiteSpace([string]$summaryState.selected_backend)) { [string]$summaryState.selected_backend } elseif ($Candidate.PSObject.Properties['backend']) { [string]$Candidate.backend } else { '' }
  $accountAlias = [string]$summaryState.account_alias
  $forcedCheckpoint = $null

  if (([string]::IsNullOrWhiteSpace([string]$summaryState.session_slug) -or [string]::IsNullOrWhiteSpace([string]$summaryState.handover_path)) -and $null -ne $summary -and (Get-Command Invoke-RaymanSessionCommandCheckpoint -ErrorAction SilentlyContinue)) {
    try {
      $durationMs = if ($summary.PSObject.Properties['duration_ms']) { [int]$summary.duration_ms } else { 0 }
      $thresholdMs = if (Get-Command Get-RaymanSessionAutoTempThresholdMs -ErrorAction SilentlyContinue) { [int](Get-RaymanSessionAutoTempThresholdMs) } else { 60000 }
      if ($durationMs -lt $thresholdMs) {
        $durationMs = $thresholdMs
      }
      $checkpointBackend = if (-not [string]::IsNullOrWhiteSpace($selectedBackend)) { $selectedBackend } elseif (-not [string]::IsNullOrWhiteSpace($preferredBackend)) { $preferredBackend } else { 'local' }
      $forcedCheckpoint = Invoke-RaymanSessionCommandCheckpoint -WorkspaceRoot $resolvedRoot -DurationMs $durationMs -Backend $checkpointBackend -AccountAlias $accountAlias -CommandText $taskIntent
      if ($null -ne $forcedCheckpoint -and [bool]$forcedCheckpoint.checkpointed) {
        $summaryState.session_slug = [string]$forcedCheckpoint.session_slug
        if ($forcedCheckpoint.PSObject.Properties['artifacts'] -and $null -ne $forcedCheckpoint.artifacts) {
          $summaryState.handover_path = if ($forcedCheckpoint.artifacts.PSObject.Properties['handover_path']) { [string]$forcedCheckpoint.artifacts.handover_path } else { [string]$summaryState.handover_path }
          $summaryState.patch_path = if ($forcedCheckpoint.artifacts.PSObject.Properties['auto_save_patch_path']) { [string]$forcedCheckpoint.artifacts.auto_save_patch_path } else { [string]$summaryState.patch_path }
          $summaryState.meta_path = if ($forcedCheckpoint.artifacts.PSObject.Properties['auto_save_meta_path']) { [string]$forcedCheckpoint.artifacts.auto_save_meta_path } else { [string]$summaryState.meta_path }
        }
      }
    } catch {}
  }

  if (-not [string]::IsNullOrWhiteSpace([string]$summaryState.session_slug) -and (Get-Command Get-RaymanSessionPaths -ErrorAction SilentlyContinue)) {
    $sessionPaths = Get-RaymanSessionPaths -WorkspaceRoot $resolvedRoot -Slug ([string]$summaryState.session_slug)
    if ([string]::IsNullOrWhiteSpace([string]$summaryState.handover_path) -and $sessionPaths.PSObject.Properties['handover_path']) {
      $summaryState.handover_path = [string]$sessionPaths.handover_path
    }
    if ([string]::IsNullOrWhiteSpace([string]$summaryState.patch_path) -and $sessionPaths.PSObject.Properties['auto_save_patch_path']) {
      $summaryState.patch_path = [string]$sessionPaths.auto_save_patch_path
    }
    if ([string]::IsNullOrWhiteSpace([string]$summaryState.meta_path) -and $sessionPaths.PSObject.Properties['auto_save_meta_path']) {
      $summaryState.meta_path = [string]$sessionPaths.auto_save_meta_path
    }
  }

  if ([string]::IsNullOrWhiteSpace([string]$summaryState.shared_session_task_slug)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$summaryState.session_slug)) {
      $summaryState.shared_session_task_slug = [string]$summaryState.session_slug
    } elseif (Get-Command Resolve-RaymanSharedSessionSlug -ErrorAction SilentlyContinue) {
      $summaryState.shared_session_task_slug = Resolve-RaymanSharedSessionSlug -Task $taskIntent -TaskKind $taskKind -Command $taskIntent
    }
  }

  $sharedEnsure = $null
  if (Get-Command Ensure-RaymanSharedSession -ErrorAction SilentlyContinue) {
    try {
      $sharedEnsure = Ensure-RaymanSharedSession -WorkspaceRoot $resolvedRoot -TaskSlug ([string]$summaryState.shared_session_task_slug) -DisplayName $taskIntent -Status 'needs_attention' -SummaryText $taskIntent -ResumeSummaryText $taskIntent -RecapText $taskIntent -Metadata @{
        run_id = [string]$Candidate.run_id
        task_kind = $taskKind
        backend = $selectedBackend
        candidate_source = if ($Candidate.PSObject.Properties['candidate_source']) { [string]$Candidate.candidate_source } else { 'agent_run' }
        source_action = 'network_resume'
      } -IgnoreDisabled
      if ($null -ne $sharedEnsure -and [bool]$sharedEnsure.success) {
        $summaryState.shared_session_id = [string]$sharedEnsure.session.session_id
      }
    } catch {}
  }

  if (-not [string]::IsNullOrWhiteSpace([string]$summaryState.shared_session_id) -and -not [string]::IsNullOrWhiteSpace([string]$summaryState.session_slug) -and (Get-Command Save-RaymanSharedSessionCheckpoint -ErrorAction SilentlyContinue)) {
    try {
      $checkpointSummary = if ($Candidate.PSObject.Properties['failure_text']) { [string]$Candidate.failure_text } else { $taskIntent }
      $checkpointResult = Save-RaymanSharedSessionCheckpoint -WorkspaceRoot $resolvedRoot -SessionId ([string]$summaryState.shared_session_id) -CheckpointKind 'network-resume-save' -SessionSlug ([string]$summaryState.session_slug) -SessionKind 'auto_temp' -HandoverPath ([string]$summaryState.handover_path) -PatchPath ([string]$summaryState.patch_path) -MetaPath ([string]$summaryState.meta_path) -SummaryText $checkpointSummary -Metadata @{
        run_id = [string]$Candidate.run_id
        candidate_source = if ($Candidate.PSObject.Properties['candidate_source']) { [string]$Candidate.candidate_source } else { 'agent_run' }
      }
      if ($null -ne $checkpointResult -and $checkpointResult.PSObject.Properties['checkpoint_id']) {
        $summaryState.checkpoint_id = [string]$checkpointResult.checkpoint_id
      }
    } catch {}
  }

  if (-not [string]::IsNullOrWhiteSpace([string]$summaryState.shared_session_id) -and (Get-Command Sync-RaymanSharedSessionAdapters -ErrorAction SilentlyContinue)) {
    try {
      $null = Sync-RaymanSharedSessionAdapters -WorkspaceRoot $resolvedRoot -SessionId ([string]$summaryState.shared_session_id) -AccountAlias $accountAlias
    } catch {}
  }

  if (-not [string]::IsNullOrWhiteSpace([string]$summaryState.shared_session_id) -and (Get-Command Add-RaymanSharedSessionMessage -ErrorAction SilentlyContinue)) {
    try {
      $messageText = if ($Candidate.PSObject.Properties['failure_text'] -and -not [string]::IsNullOrWhiteSpace([string]$Candidate.failure_text)) {
        [string]$Candidate.failure_text
      } else {
        'Saved continuation state after transient provider outage.'
      }
      $messageId = 'network-resume-save-' + (Get-RaymanNetworkResumeStableHash -Value (($Candidate.run_id, $messageText, $summaryState.handover_path, $summaryState.patch_path, $summaryState.meta_path) -join '|')).Substring(0, 24)
      $null = Add-RaymanSharedSessionMessage -WorkspaceRoot $resolvedRoot -SessionId ([string]$summaryState.shared_session_id) -Role assistant -ContentText $messageText -ResumeText $taskIntent -RecapText $taskIntent -AuthorKind 'rayman' -AuthorName 'Rayman Network Resume' -SourceKind 'network_resume_save' -Artifact @{
        handover_path = [string]$summaryState.handover_path
        patch_path = [string]$summaryState.patch_path
        meta_path = [string]$summaryState.meta_path
      } -Metadata @{
        run_id = [string]$Candidate.run_id
        task_kind = $taskKind
      } -MessageId $messageId
    } catch {}
  }

  $identityKey = Get-RaymanNetworkResumeIdentityKey -TaskKind $taskKind -TaskIntent $taskIntent -EffectiveTaskKey ([string]$summaryState.effective_task_key) -SharedSessionId ([string]$summaryState.shared_session_id) -RunId ([string]$Candidate.run_id)
  $stateKey = Get-RaymanNetworkResumeStableHash -Value (($identityKey, $summaryState.session_slug, $summaryState.checkpoint_id, $summaryState.handover_path, $summaryState.patch_path, $summaryState.meta_path, $summaryState.generated_at, $(if ($Candidate.PSObject.Properties['failure_text']) { [string]$Candidate.failure_text } else { '' })) -join '|')

  if ($null -ne $ExistingPending -and $ExistingPending.PSObject.Properties['state_key'] -and [string]$ExistingPending.state_key -eq $stateKey) {
    return $ExistingPending
  }

  $now = Get-Date
  $firstSavedAt = if ($null -ne $ExistingPending -and $ExistingPending.PSObject.Properties['identity_key'] -and [string]$ExistingPending.identity_key -eq $identityKey -and $ExistingPending.PSObject.Properties['first_saved_at']) {
    [string]$ExistingPending.first_saved_at
  } else {
    $now.ToString('o')
  }
  $attemptCount = if ($null -ne $ExistingPending -and $ExistingPending.PSObject.Properties['identity_key'] -and [string]$ExistingPending.identity_key -eq $identityKey -and $ExistingPending.PSObject.Properties['attempt_count']) {
    [int]$ExistingPending.attempt_count
  } else {
    0
  }
  $lastAttemptAt = if ($null -ne $ExistingPending -and $ExistingPending.PSObject.Properties['identity_key'] -and [string]$ExistingPending.identity_key -eq $identityKey -and $ExistingPending.PSObject.Properties['last_attempt_at']) {
    [string]$ExistingPending.last_attempt_at
  } else {
    ''
  }

  $pending = [ordered]@{
    schema = 'rayman.watch.network_resume_pending.v1'
    workspace_root = $resolvedRoot
    run_id = [string]$Candidate.run_id
    candidate_source = if ($Candidate.PSObject.Properties['candidate_source']) { [string]$Candidate.candidate_source } else { 'agent_run' }
    backend = if ($Candidate.PSObject.Properties['backend']) { [string]$Candidate.backend } else { $selectedBackend }
    task_kind = $taskKind
    task = $taskIntent
    effective_task_key = [string]$summaryState.effective_task_key
    preferred_backend = $preferredBackend
    selected_backend = $selectedBackend
    account_alias = $accountAlias
    shared_session_id = [string]$summaryState.shared_session_id
    shared_session_task_slug = [string]$summaryState.shared_session_task_slug
    session_slug = [string]$summaryState.session_slug
    checkpoint_id = [string]$summaryState.checkpoint_id
    handover_path = [string]$summaryState.handover_path
    patch_path = [string]$summaryState.patch_path
    meta_path = [string]$summaryState.meta_path
    failure_classification = if ($Candidate.PSObject.Properties['failure_classification']) { [string]$Candidate.failure_classification.classification } else { '' }
    failure_kind = if ($Candidate.PSObject.Properties['failure_classification'] -and $Candidate.failure_classification.PSObject.Properties['failure_kind']) { [string]$Candidate.failure_classification.failure_kind } else { '' }
    failure_text = if ($Candidate.PSObject.Properties['failure_text']) { [string]$Candidate.failure_text } else { '' }
    native_resume_supported = if ($Candidate.PSObject.Properties['native_resume_supported']) { [bool]$Candidate.native_resume_supported } else { $false }
    resume_target_kind = if ($Candidate.PSObject.Properties['resume_target_kind']) { [string]$Candidate.resume_target_kind } else { '' }
    desktop_session_id = if ($Candidate.PSObject.Properties['desktop_session_id']) { [string]$Candidate.desktop_session_id } else { '' }
    desktop_session_path = if ($Candidate.PSObject.Properties['desktop_session_path']) { [string]$Candidate.desktop_session_path } else { '' }
    summary_generated_at = [string]$summaryState.generated_at
    failure_started_at = if ($Candidate.PSObject.Properties['failure_started_at'] -and $null -ne $Candidate.failure_started_at) { ([datetime]$Candidate.failure_started_at).ToString('o') } else { '' }
    first_saved_at = $firstSavedAt
    pending_state_updated_at = $now.ToString('o')
    last_attempt_at = $lastAttemptAt
    attempt_count = $attemptCount
    identity_key = $identityKey
    state_key = $stateKey
    resume_mode = if ([bool]$(if ($Candidate.PSObject.Properties['native_resume_supported']) { $Candidate.native_resume_supported } else { $false })) { 'native' } else { 'shared_session' }
  }

  Write-RaymanNetworkResumePendingState -WorkspaceRoot $resolvedRoot -Pending $pending | Out-Null
  return ([pscustomobject]$pending)
}

function Get-RaymanNetworkResumeWatchDelayMs {
  param([object]$State)

  if ($null -eq $State) { return 5000 }
  return [int][Math]::Max(1000, [int]$State.PollMs)
}

function Get-RaymanNetworkResumeWatchStartupMessage {
  param([object]$State)

  if ($null -eq $State) { return '[network-resume] disabled' }

  return ("[network-resume] started (poll={0}ms, first-save-idle={1}s, retry={2}s, probe-timeout={3}ms)" -f
    [int]$State.PollMs,
    [int]$State.FirstSaveIdleSeconds,
    [int]$State.RetrySeconds,
    [int]$State.ProbeTimeoutMs)
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
    'internal server error',
    'bad gateway',
    'gateway timeout',
    'service unavailable',
    'temporarily unavailable',
    'upstream',
    'backend overloaded',
    'server error',
    '500',
    '502',
    '503',
    '504',
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
      failure_kind = ''
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
        failure_kind = ''
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
        trigger_kind = 'provider_outage'
        classification = 'transient_provider_outage'
        failure_kind = 'throttle'
        matched = $pattern
      }
    }
  }

  $serverPatterns = @(
    '500',
    '502',
    '503',
    '504',
    'bad gateway',
    'gateway timeout',
    'service unavailable',
    'temporarily unavailable',
    'internal server error',
    'upstream',
    'backend overloaded',
    'server error',
    'upstream connect error',
    'upstream request timeout',
    'origin timeout',
    'origin error',
    '后端过载',
    '服务不可用',
    '网关超时',
    '坏网关',
    '服务器错误',
    '暂时不可用'
  )
  foreach ($pattern in $serverPatterns) {
    if ($normalized.Contains($pattern)) {
      return [pscustomobject]@{
        is_resume_candidate = $true
        is_network = $false
        trigger_kind = 'provider_outage'
        classification = 'transient_provider_outage'
        failure_kind = 'server'
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
        trigger_kind = 'provider_outage'
        classification = 'transient_provider_outage'
        failure_kind = 'network'
        matched = $pattern
      }
    }
  }

  return [pscustomobject]@{
    is_resume_candidate = $false
    is_network = $false
    trigger_kind = 'none'
    classification = 'insufficient_signal'
    failure_kind = ''
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

  $summaryPath = Get-RaymanNetworkResumeDispatchSummaryPath -WorkspaceRoot $WorkspaceRoot
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

  $dispatchCandidate = Get-RaymanNetworkResumeDispatchCandidate -WorkspaceRoot $WorkspaceRoot
  $desktopCandidate = Get-RaymanNetworkResumeDesktopSessionCandidate -WorkspaceRoot $WorkspaceRoot
  $candidates = @($dispatchCandidate, $desktopCandidate)

  if ($null -ne $dispatchCandidate -and [string]$dispatchCandidate.reason -eq 'last_run_succeeded') {
    $dispatchSortKey = Get-RaymanNetworkResumeCandidateSortKey -Candidate $dispatchCandidate
    $newerFailure = @($candidates | Where-Object { [bool]$_.available -and (Get-RaymanNetworkResumeCandidateSortKey -Candidate $_) -gt $dispatchSortKey })
    if ($newerFailure.Count -le 0) {
      return $dispatchCandidate
    }
  }

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
    [object]$Pending = $null,
    [object]$IdleInfo = $null,
    [object]$ProbeResult = $null,
    [string]$Error = '',
    [hashtable]$Extra = @{}
  )

  if ($null -eq $State) { return $null }

  $retryDueAt = Get-RaymanNetworkResumeRetryDueAt -Pending $Pending -RetrySeconds ([int]$State.RetrySeconds)
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
    first_save_idle_seconds = [int]$State.FirstSaveIdleSeconds
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
    pending_saved = ($null -ne $Pending)
    pending_checkpoint_id = $(if ($null -ne $Pending -and $Pending.PSObject.Properties['checkpoint_id']) { [string]$Pending.checkpoint_id } else { '' })
    pending_state_updated_at = $(if ($null -ne $Pending -and $Pending.PSObject.Properties['pending_state_updated_at']) { [string]$Pending.pending_state_updated_at } else { '' })
    retry_due_at = $(if ($null -ne $retryDueAt) { ([datetime]$retryDueAt).ToString('o') } else { '' })
    resume_mode = $(if ($null -ne $Pending -and $Pending.PSObject.Properties['resume_mode']) { [string]$Pending.resume_mode } else { '' })
    cleared_reason = [string]$State.ClearedReason
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
      failure_kind = $(if ($Candidate.PSObject.Properties['failure_classification'] -and $Candidate.failure_classification.PSObject.Properties['failure_kind']) { [string]$Candidate.failure_classification.failure_kind } else { '' })
      failure_match = $(if ($Candidate.PSObject.Properties['failure_classification']) { [string]$Candidate.failure_classification.matched } else { '' })
      failure_started_at = $(if ($Candidate.PSObject.Properties['failure_started_at'] -and $null -ne $Candidate.failure_started_at) { ([datetime]$Candidate.failure_started_at).ToString('o') } else { '' })
    }
  }

  if ($null -ne $Pending) {
    $payload['pending'] = [ordered]@{
      run_id = $(if ($Pending.PSObject.Properties['run_id']) { [string]$Pending.run_id } else { '' })
      task_kind = $(if ($Pending.PSObject.Properties['task_kind']) { [string]$Pending.task_kind } else { '' })
      task = $(if ($Pending.PSObject.Properties['task']) { [string]$Pending.task } else { '' })
      backend = $(if ($Pending.PSObject.Properties['backend']) { [string]$Pending.backend } else { '' })
      preferred_backend = $(if ($Pending.PSObject.Properties['preferred_backend']) { [string]$Pending.preferred_backend } else { '' })
      shared_session_id = $(if ($Pending.PSObject.Properties['shared_session_id']) { [string]$Pending.shared_session_id } else { '' })
      session_slug = $(if ($Pending.PSObject.Properties['session_slug']) { [string]$Pending.session_slug } else { '' })
      checkpoint_id = $(if ($Pending.PSObject.Properties['checkpoint_id']) { [string]$Pending.checkpoint_id } else { '' })
      resume_mode = $(if ($Pending.PSObject.Properties['resume_mode']) { [string]$Pending.resume_mode } else { '' })
      pending_state_updated_at = $(if ($Pending.PSObject.Properties['pending_state_updated_at']) { [string]$Pending.pending_state_updated_at } else { '' })
      first_saved_at = $(if ($Pending.PSObject.Properties['first_saved_at']) { [string]$Pending.first_saved_at } else { '' })
      last_attempt_at = $(if ($Pending.PSObject.Properties['last_attempt_at']) { [string]$Pending.last_attempt_at } else { '' })
      attempt_count = $(if ($Pending.PSObject.Properties['attempt_count']) { [int]$Pending.attempt_count } else { 0 })
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

function Get-RaymanNetworkResumeConfiguredRetrySeconds {
  $retryRaw = Get-RaymanNetworkResumeRawEnvString -Name 'RAYMAN_NETWORK_RESUME_RETRY_SECONDS' -Default ''
  if ([string]::IsNullOrWhiteSpace($retryRaw)) {
    $retryRaw = Get-RaymanNetworkResumeRawEnvString -Name 'RAYMAN_NETWORK_RESUME_THROTTLE_WAIT_SECONDS' -Default ''
  }

  $parsed = 0
  if (-not [string]::IsNullOrWhiteSpace($retryRaw) -and [int]::TryParse($retryRaw, [ref]$parsed)) {
    if ($parsed -lt 60) { return 60 }
    if ($parsed -gt 86400) { return 86400 }
    return $parsed
  }
  return 1800
}

function New-RaymanNetworkResumeWatchState {
  param([string]$WorkspaceRoot)

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $runtimeDir = Join-Path $resolvedRoot '.Rayman\runtime'
  if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
  }

  $retrySeconds = Get-RaymanNetworkResumeConfiguredRetrySeconds
  return [pscustomobject]@{
    WorkspaceRoot = $resolvedRoot
    RuntimeDir = $runtimeDir
    StatusPath = (Get-RaymanNetworkResumeStatePath -WorkspaceRoot $resolvedRoot)
    PendingPath = (Get-RaymanNetworkResumePendingStatePath -WorkspaceRoot $resolvedRoot)
    PollMs = (Get-RaymanEnvInt -Name 'RAYMAN_NETWORK_RESUME_POLL_MS' -Default 5000 -Min 1000 -Max 60000)
    ThresholdSeconds = (Get-RaymanEnvInt -Name 'RAYMAN_NETWORK_RESUME_THRESHOLD_SECONDS' -Default $retrySeconds -Min 60 -Max 86400)
    ThrottleWaitSeconds = $retrySeconds
    ProbeTimeoutMs = (Get-RaymanEnvInt -Name 'RAYMAN_NETWORK_RESUME_PROBE_TIMEOUT_MS' -Default 5000 -Min 1000 -Max 60000)
    RetrySeconds = $retrySeconds
    FirstSaveIdleSeconds = (Get-RaymanNetworkResumeFirstSaveIdleSeconds)
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
    ClearedReason = ''
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

function Start-RaymanSharedSessionContinuationDetached {
  param(
    [string]$WorkspaceRoot,
    [object]$Pending
  )

  $resolvedWorkspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $raymanScript = Join-Path $resolvedWorkspace '.Rayman\rayman.ps1'
  if (-not (Test-Path -LiteralPath $raymanScript -PathType Leaf)) {
    throw ("rayman.ps1 not found: {0}" -f $raymanScript)
  }

  $hostPath = if (Get-Command Resolve-RaymanPowerShellHost -ErrorAction SilentlyContinue) {
    [string](Resolve-RaymanPowerShellHost)
  } else {
    ''
  }
  if ([string]::IsNullOrWhiteSpace($hostPath)) {
    $hostPath = if (Test-RaymanWindowsPlatform) { 'powershell.exe' } else { 'pwsh' }
  }

  $runtimeDir = Get-RaymanNetworkResumeRuntimeDirectory -WorkspaceRoot $resolvedWorkspace
  $logStem = Join-Path $runtimeDir ('shared_session_continue_' + [Guid]::NewGuid().ToString('N'))
  $stdoutPath = $logStem + '.stdout.txt'
  $stderrPath = $logStem + '.stderr.txt'
  $startedAt = Get-Date

  $taskText = @(
    $(if ($null -ne $Pending -and $Pending.PSObject.Properties['task']) { [string]$Pending.task } else { '' }),
    $(if ($null -ne $Pending -and $Pending.PSObject.Properties['failure_text']) { [string]$Pending.failure_text } else { '' }),
    'continue interrupted workspace task'
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1
  $taskKind = @(
    $(if ($null -ne $Pending -and $Pending.PSObject.Properties['task_kind']) { [string]$Pending.task_kind } else { '' }),
    'dispatch'
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1
  $preferredBackend = @(
    $(if ($null -ne $Pending -and $Pending.PSObject.Properties['preferred_backend']) { [string]$Pending.preferred_backend } else { '' }),
    $(if ($null -ne $Pending -and $Pending.PSObject.Properties['selected_backend']) { [string]$Pending.selected_backend } else { '' }),
    $(if ($null -ne $Pending -and $Pending.PSObject.Properties['backend']) { [string]$Pending.backend } else { '' })
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1
  $continuationPreamble = Get-RaymanNetworkResumeContinuationPreamble -WorkspaceRoot $resolvedWorkspace -Pending $Pending

  $argumentList = New-Object System.Collections.Generic.List[string]
  foreach ($item in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $raymanScript, 'dispatch', '-WorkspaceRoot', $resolvedWorkspace, '-TaskKind', $taskKind, '-Task', $taskText)) {
    $argumentList.Add([string]$item) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$preferredBackend)) {
    $argumentList.Add('-PreferredBackend') | Out-Null
    $argumentList.Add([string]$preferredBackend) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$continuationPreamble)) {
    $argumentList.Add('-InjectedPreamble') | Out-Null
    $argumentList.Add([string]$continuationPreamble) | Out-Null
  }

  $commandText = ((@([string]$hostPath) + @($argumentList.ToArray())) -join ' ').Trim()
  $params = @{
    FilePath = [string]$hostPath
    ArgumentList = @($argumentList.ToArray())
    WorkingDirectory = $resolvedWorkspace
    PassThru = $true
    RedirectStandardOutput = $stdoutPath
    RedirectStandardError = $stderrPath
  }
  if (Test-RaymanWindowsPlatform) {
    $params['WindowStyle'] = 'Hidden'
  }

  $proc = Start-Process @params
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
      resume_mode = 'shared_session'
      continuation_preamble = $continuationPreamble
      task = $taskText
      task_kind = $taskKind
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
    resume_mode = 'shared_session'
    continuation_preamble = $continuationPreamble
    task = $taskText
    task_kind = $taskKind
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

  $workspaceRoot = [string]$State.WorkspaceRoot
  $candidate = Get-RaymanNetworkResumeCandidate -WorkspaceRoot $workspaceRoot
  $dispatchSummary = Read-RaymanNetworkResumeJsonOrNull -Path (Get-RaymanNetworkResumeDispatchSummaryPath -WorkspaceRoot $workspaceRoot)
  $pending = Read-RaymanNetworkResumePendingState -WorkspaceRoot $workspaceRoot
  $idleInfo = Get-RaymanCurrentUserIdleInfo
  $State.ClearedReason = ''

  if ($null -ne $idleInfo.idle_since) {
    $State.IdleSince = [datetime]$idleInfo.idle_since
  } else {
    $State.IdleSince = $null
  }

  if ($null -ne $pending -and $null -ne $dispatchSummary -and $dispatchSummary.PSObject.Properties['success'] -and [bool]$dispatchSummary.success -and (Test-RaymanNetworkResumeSummaryMatchesPending -Summary $dispatchSummary -Pending $pending)) {
    $null = Remove-RaymanNetworkResumePendingState -WorkspaceRoot $workspaceRoot
    Reset-RaymanNetworkResumeState -State $State
    $State.ClearedReason = 'task_completed'
    $State.SuppressedReason = 'task_completed'
    Write-RaymanNetworkResumeStatus -State $State -Status 'task_completed' -Candidate $candidate -IdleInfo $idleInfo -Pending $null | Out-Null
    return [pscustomobject]@{
      should_exit = $false
      status = 'task_completed'
    }
  }

  if ($null -ne $candidate -and [bool]$candidate.available) {
    if ([string]$candidate.run_id -ne [string]$State.LastCandidateRunId) {
      Reset-RaymanNetworkResumeCandidateState -State $State -RunId ([string]$candidate.run_id)
    }
    $State.LastCandidateRunId = [string]$candidate.run_id
    $State.TriggerKind = if ($candidate.PSObject.Properties['failure_classification'] -and $candidate.failure_classification.PSObject.Properties['failure_kind']) {
      [string]$candidate.failure_classification.failure_kind
    } elseif ($candidate.PSObject.Properties['trigger_kind']) {
      [string]$candidate.trigger_kind
    } else {
      ''
    }
    $State.ProviderUnreachableSince = if ($candidate.PSObject.Properties['failure_started_at'] -and $null -ne $candidate.failure_started_at) { [datetime]$candidate.failure_started_at } else { Get-Date }
  } elseif ($null -ne $pending) {
    $State.LastCandidateRunId = if ($pending.PSObject.Properties['run_id']) { [string]$pending.run_id } else { '' }
    $State.TriggerKind = if ($pending.PSObject.Properties['failure_kind']) { [string]$pending.failure_kind } else { 'provider_outage' }
    $State.ProviderUnreachableSince = ConvertTo-RaymanNullableDateTime -Value $(if ($pending.PSObject.Properties['failure_started_at']) { [string]$pending.failure_started_at } else { '' })
  } else {
    Reset-RaymanNetworkResumeState -State $State
  }

  if ($null -ne $idleInfo.idle_since) {
    $State.IdleSince = [datetime]$idleInfo.idle_since
  } else {
    $State.IdleSince = $null
  }

  if ($null -ne $candidate -and [bool]$candidate.available) {
    $saveGateMet = $false
    if ($null -ne $State.IdleSince) {
      $idleSeconds = [int][Math]::Max(0, [Math]::Floor(((Get-Date) - [datetime]$State.IdleSince).TotalSeconds))
      $saveGateMet = ($idleSeconds -ge [int]$State.FirstSaveIdleSeconds)
    }

    if ($null -eq $pending) {
      if (-not $saveGateMet) {
        $State.SuppressedReason = 'initial_save_waiting_idle'
        Write-RaymanNetworkResumeStatus -State $State -Status 'pending_save_waiting_idle' -Candidate $candidate -IdleInfo $idleInfo -Pending $null -Extra @{
          initial_save_idle_required_seconds = [int]$State.FirstSaveIdleSeconds
          initial_save_idle_remaining_seconds = if ($null -eq $State.IdleSince) { [int]$State.FirstSaveIdleSeconds } else { [int][Math]::Max(0, [int]$State.FirstSaveIdleSeconds - [int][Math]::Floor(((Get-Date) - [datetime]$State.IdleSince).TotalSeconds)) }
        } | Out-Null
        return [pscustomobject]@{
          should_exit = $false
          status = 'pending_save_waiting_idle'
        }
      }

      $savedPending = Save-RaymanNetworkResumePendingStateFromCandidate -WorkspaceRoot $workspaceRoot -Candidate $candidate
      if ($null -ne $savedPending) {
        $pending = $savedPending
        $State.ArmedAt = ConvertTo-RaymanNullableDateTime -Value ([string]$pending.first_saved_at)
        $State.SuppressedReason = 'pending_saved'
        Write-RaymanDiag -Scope 'network-resume' -Message ("saved pending continuation; run_id={0}; backend={1}; state_key={2}" -f [string]$pending.run_id, [string]$pending.backend, [string]$pending.state_key) -WorkspaceRoot $workspaceRoot
      }
    } else {
      $updatedPending = Save-RaymanNetworkResumePendingStateFromCandidate -WorkspaceRoot $workspaceRoot -Candidate $candidate -ExistingPending $pending
      if ($null -ne $updatedPending) {
        $previousStateKey = if ($pending.PSObject.Properties['state_key']) { [string]$pending.state_key } else { '' }
        $updatedStateKey = if ($updatedPending.PSObject.Properties['state_key']) { [string]$updatedPending.state_key } else { '' }
        if ($previousStateKey -ne $updatedStateKey) {
          $State.ClearedReason = 'pending_replaced'
          Write-RaymanDiag -Scope 'network-resume' -Message ("replaced pending continuation with newer state; run_id={0}; backend={1}; state_key={2}" -f [string]$updatedPending.run_id, [string]$updatedPending.backend, [string]$updatedPending.state_key) -WorkspaceRoot $workspaceRoot
        }
        $pending = $updatedPending
      }
    }
  }

  if ($null -eq $pending) {
    if ($null -eq $candidate) {
      $State.SuppressedReason = 'candidate_missing'
      Write-RaymanNetworkResumeStatus -State $State -Status 'candidate_missing' -IdleInfo $idleInfo -Pending $null -Error 'candidate_missing' | Out-Null
      return [pscustomobject]@{
        should_exit = $false
        status = 'candidate_missing'
      }
    }

    if (-not [bool]$candidate.available) {
      if (-not [string]::IsNullOrWhiteSpace([string]$candidate.run_id) -and [string]$candidate.run_id -ne [string]$State.LastCandidateRunId) {
        Reset-RaymanNetworkResumeCandidateState -State $State -RunId ([string]$candidate.run_id)
      }
      $State.SuppressedReason = [string]$candidate.reason
      Write-RaymanNetworkResumeStatus -State $State -Status [string]$candidate.reason -Candidate $candidate -IdleInfo $idleInfo -Pending $null -Error [string]$candidate.reason | Out-Null
      return [pscustomobject]@{
        should_exit = $false
        status = [string]$candidate.reason
      }
    }

    $State.SuppressedReason = 'pending_not_saved'
    Write-RaymanNetworkResumeStatus -State $State -Status 'pending_not_saved' -Candidate $candidate -IdleInfo $idleInfo -Pending $null -Error 'pending_not_saved' | Out-Null
    return [pscustomobject]@{
      should_exit = $false
      status = 'pending_not_saved'
    }
  }

  $State.LastResumeAttemptAt = ConvertTo-RaymanNullableDateTime -Value $(if ($pending.PSObject.Properties['last_attempt_at']) { [string]$pending.last_attempt_at } else { '' })
  $State.AttemptCount = if ($pending.PSObject.Properties['attempt_count']) { [int]$pending.attempt_count } else { 0 }
  $State.ArmedAt = ConvertTo-RaymanNullableDateTime -Value $(if ($pending.PSObject.Properties['first_saved_at']) { [string]$pending.first_saved_at } else { '' })

  $probeConfig = if ($null -ne $candidate -and $candidate.PSObject.Properties['probe'] -and $null -ne $candidate.probe -and [bool]$candidate.probe.valid) {
    $candidate.probe
  } else {
    Get-RaymanNetworkResumeProbeConfiguration -Backend $(if ($pending.PSObject.Properties['backend']) { [string]$pending.backend } else { '' })
  }

  $probeResult = $null
  if ($null -ne $probeConfig -and [bool]$probeConfig.valid -and $null -ne $probeConfig.probe_uri) {
    $probeResult = Test-RaymanNetworkResumeProviderReachable -ProbeUri $probeConfig.probe_uri -TimeoutMs ([int]$State.ProbeTimeoutMs)
    $State.LastProviderReachable = [bool]$probeResult.reachable
  } else {
    $State.LastProviderReachable = $null
  }

  $retryDueAt = Get-RaymanNetworkResumeRetryDueAt -Pending $pending -RetrySeconds ([int]$State.RetrySeconds)
  if ($null -eq $retryDueAt -or (Get-Date) -lt $retryDueAt) {
    $State.SuppressedReason = 'retry_window_wait'
    $statusText = if ($null -ne $probeResult -and [bool]$probeResult.reachable) { 'provider_recovered_waiting_retry_window' } else { 'pending_saved' }
    Write-RaymanNetworkResumeStatus -State $State -Status $statusText -Candidate $candidate -IdleInfo $idleInfo -Pending $pending -ProbeResult $probeResult -Extra @{
      retry_window_seconds = [int]$State.RetrySeconds
      retry_wait_remaining_seconds = if ($null -ne $retryDueAt) { [int][Math]::Max(0, [Math]::Floor(($retryDueAt - (Get-Date)).TotalSeconds)) } else { 0 }
    } | Out-Null
    return [pscustomobject]@{
      should_exit = $false
      status = $statusText
    }
  }

  if ($null -eq $probeResult -or -not [bool]$probeResult.reachable) {
    $State.SuppressedReason = 'provider_unreachable'
    Write-RaymanNetworkResumeStatus -State $State -Status 'provider_unreachable' -Candidate $candidate -IdleInfo $idleInfo -Pending $pending -ProbeResult $probeResult -Error 'provider_unreachable' | Out-Null
    return [pscustomobject]@{
      should_exit = $false
      status = 'provider_unreachable'
    }
  }

  $now = Get-Date
  $pending.last_attempt_at = $now.ToString('o')
  $pending.attempt_count = if ($pending.PSObject.Properties['attempt_count']) { [int]$pending.attempt_count + 1 } else { 1 }
  Write-RaymanNetworkResumePendingState -WorkspaceRoot $workspaceRoot -Pending $pending | Out-Null
  $State.LastResumeAttemptAt = $now
  $State.AttemptCount = [int]$pending.attempt_count

  $resumePrompt = Get-RaymanNetworkResumePrompt
  $candidateSource = if ($null -ne $candidate -and $candidate.PSObject.Properties['candidate_source']) { [string]$candidate.candidate_source } elseif ($pending.PSObject.Properties['candidate_source']) { [string]$pending.candidate_source } else { 'agent_run' }
  $nativeError = ''
  $nativeResult = $null
  $resumeMode = if ($pending.PSObject.Properties['resume_mode']) { [string]$pending.resume_mode } else { '' }

  if ($pending.PSObject.Properties['native_resume_supported'] -and [bool]$pending.native_resume_supported) {
    try {
      Write-RaymanDiag -Scope 'network-resume' -Message ("attempt native resume; run_id={0}; backend={1}; source={2}; attempt={3}" -f [string]$pending.run_id, [string]$pending.backend, $candidateSource, [int]$pending.attempt_count) -WorkspaceRoot $workspaceRoot
      $nativeResult = if ($candidateSource -eq 'codex_desktop_session') {
        Start-RaymanCodexDesktopResumeDetached -WorkspaceRoot $workspaceRoot -SessionId $(if ($pending.PSObject.Properties['desktop_session_id']) { [string]$pending.desktop_session_id } else { '' }) -Prompt $resumePrompt -DesktopSessionPath $(if ($pending.PSObject.Properties['desktop_session_path']) { [string]$pending.desktop_session_path } else { '' })
      } elseif ([string]$pending.backend -eq 'codex') {
        Start-RaymanCodexNativeResumeDetached -WorkspaceRoot $workspaceRoot -Prompt $resumePrompt
      } else {
        [pscustomobject]@{
          success = $false
          command = ''
          exit_code = 0
          error = ('native resume unsupported for backend ' + [string]$pending.backend)
        }
      }
      if ($null -ne $nativeResult -and [bool]$nativeResult.success) {
        $null = Remove-RaymanNetworkResumePendingState -WorkspaceRoot $workspaceRoot
        Reset-RaymanNetworkResumeState -State $State
        $State.ClearedReason = 'resume_started'
        $State.SuppressedReason = 'resume_started'
        Write-RaymanDiag -Scope 'network-resume' -Message ("native resume succeeded; run_id={0}; source={1}; command={2}" -f [string]$pending.run_id, $candidateSource, [string]$nativeResult.command) -WorkspaceRoot $workspaceRoot
        Write-RaymanNetworkResumeStatus -State $State -Status 'resumed' -Candidate $candidate -IdleInfo $idleInfo -Pending $null -ProbeResult $probeResult -Extra @{
          resume_mode = 'native'
          resume_command = [string]$nativeResult.command
          resume_exit_code = [int]$nativeResult.exit_code
          resume_pid = if ($nativeResult.PSObject.Properties['pid']) { [int]$nativeResult.pid } else { 0 }
          resume_completed = if ($nativeResult.PSObject.Properties['completed']) { [bool]$nativeResult.completed } else { $false }
          resume_stdout_path = if ($nativeResult.PSObject.Properties['stdout_path']) { [string]$nativeResult.stdout_path } else { '' }
          resume_stderr_path = if ($nativeResult.PSObject.Properties['stderr_path']) { [string]$nativeResult.stderr_path } else { '' }
          resume_target_kind = if ($nativeResult.PSObject.Properties['resume_target_kind']) { [string]$nativeResult.resume_target_kind } elseif ($pending.PSObject.Properties['resume_target_kind']) { [string]$pending.resume_target_kind } else { '' }
          cleared_reason = 'resume_started'
        } | Out-Null
        return [pscustomobject]@{
          should_exit = $false
          status = 'resumed'
        }
      }
      $nativeError = if ($null -eq $nativeResult) { 'native resume returned no result' } elseif ([string]::IsNullOrWhiteSpace([string]$nativeResult.error)) { [string]$nativeResult.output } else { [string]$nativeResult.error }
    } catch {
      $nativeError = $_.Exception.Message
      Write-RaymanDiag -Scope 'network-resume' -Message ("native resume exception; run_id={0}; source={1}; error={2}" -f [string]$pending.run_id, $candidateSource, $_.Exception.ToString()) -WorkspaceRoot $workspaceRoot
    }
  }

  try {
    Write-RaymanDiag -Scope 'network-resume' -Message ("attempt shared-session continuation; run_id={0}; backend={1}; attempt={2}" -f [string]$pending.run_id, [string]$pending.backend, [int]$pending.attempt_count) -WorkspaceRoot $workspaceRoot
    $sharedResult = Start-RaymanSharedSessionContinuationDetached -WorkspaceRoot $workspaceRoot -Pending $pending
    if ($null -ne $sharedResult -and [bool]$sharedResult.success) {
      $null = Remove-RaymanNetworkResumePendingState -WorkspaceRoot $workspaceRoot
      Reset-RaymanNetworkResumeState -State $State
      $State.ClearedReason = 'resume_started'
      $State.SuppressedReason = 'resume_started'
      Write-RaymanDiag -Scope 'network-resume' -Message ("shared-session continuation started; run_id={0}; command={1}" -f [string]$pending.run_id, [string]$sharedResult.command) -WorkspaceRoot $workspaceRoot
      Write-RaymanNetworkResumeStatus -State $State -Status 'resumed' -Candidate $candidate -IdleInfo $idleInfo -Pending $null -ProbeResult $probeResult -Extra @{
        resume_mode = 'shared_session'
        resume_command = [string]$sharedResult.command
        resume_exit_code = [int]$sharedResult.exit_code
        resume_pid = if ($sharedResult.PSObject.Properties['pid']) { [int]$sharedResult.pid } else { 0 }
        resume_completed = if ($sharedResult.PSObject.Properties['completed']) { [bool]$sharedResult.completed } else { $false }
        resume_stdout_path = if ($sharedResult.PSObject.Properties['stdout_path']) { [string]$sharedResult.stdout_path } else { '' }
        resume_stderr_path = if ($sharedResult.PSObject.Properties['stderr_path']) { [string]$sharedResult.stderr_path } else { '' }
        cleared_reason = 'resume_started'
      } | Out-Null
      return [pscustomobject]@{
        should_exit = $false
        status = 'resumed'
      }
    }

    $sharedError = if ($null -eq $sharedResult) { 'shared-session continuation returned no result' } elseif ([string]::IsNullOrWhiteSpace([string]$sharedResult.error)) { [string]$sharedResult.output } else { [string]$sharedResult.error }
    $resumeError = @($nativeError, $sharedError) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique
    $resumeErrorText = ($resumeError -join ' | ')
    $State.SuppressedReason = 'resume_unavailable'
    if (Get-Command Invoke-RaymanAttentionAlert -ErrorAction SilentlyContinue) {
      Invoke-RaymanAttentionAlert -Kind 'manual' -Title 'Rayman 网络续接失败' -Reason ("网络已恢复，但自动续接失败：{0}" -f $resumeErrorText) -WorkspaceRoot $workspaceRoot | Out-Null
    }
    Write-RaymanNetworkResumeStatus -State $State -Status 'resume_unavailable' -Candidate $candidate -IdleInfo $idleInfo -Pending $pending -ProbeResult $probeResult -Error $resumeErrorText -Extra @{
      resume_mode = if ([string]::IsNullOrWhiteSpace($resumeMode)) { 'shared_session' } else { $resumeMode }
      native_error = $nativeError
      shared_session_error = $sharedError
      resume_command = if ($null -ne $nativeResult -and $nativeResult.PSObject.Properties['command']) { [string]$nativeResult.command } else { '' }
      resume_target_kind = if ($null -ne $nativeResult -and $nativeResult.PSObject.Properties['resume_target_kind']) { [string]$nativeResult.resume_target_kind } elseif ($pending.PSObject.Properties['resume_target_kind']) { [string]$pending.resume_target_kind } else { '' }
    } | Out-Null
    return [pscustomobject]@{
      should_exit = $false
      status = 'resume_unavailable'
    }
  } catch {
    $State.SuppressedReason = 'resume_unavailable'
    $resumeError = @($nativeError, $_.Exception.Message) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique
    $resumeErrorText = ($resumeError -join ' | ')
    if (Get-Command Invoke-RaymanAttentionAlert -ErrorAction SilentlyContinue) {
      Invoke-RaymanAttentionAlert -Kind 'manual' -Title 'Rayman 网络续接失败' -Reason ("网络已恢复，但自动续接失败：{0}" -f $resumeErrorText) -WorkspaceRoot $workspaceRoot | Out-Null
    }
    Write-RaymanDiag -Scope 'network-resume' -Message ("shared-session continuation exception; run_id={0}; error={1}" -f [string]$pending.run_id, $_.Exception.ToString()) -WorkspaceRoot $workspaceRoot
    Write-RaymanNetworkResumeStatus -State $State -Status 'resume_unavailable' -Candidate $candidate -IdleInfo $idleInfo -Pending $pending -ProbeResult $probeResult -Error $resumeErrorText -Extra @{
      resume_mode = 'shared_session'
      native_error = $nativeError
    } | Out-Null
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

    $pathspec = if (Get-Command Get-RaymanGitContentPathspec -ErrorAction SilentlyContinue) {
      @(Get-RaymanGitContentPathspec -ExcludeManaged)
    } else {
      @('.')
    }
    $statusArgs = @('status', '--porcelain', '--untracked-files=all', '--') + $pathspec
    $status = @(git @statusArgs)
    if ($status.Count -gt 0) {
      $addArgs = @('add', '-N', '--') + $pathspec
      git @addArgs | Out-Null
      $patchDir = Split-Path -Parent $patchPath
      if (-not [string]::IsNullOrWhiteSpace($patchDir) -and -not (Test-Path -LiteralPath $patchDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $patchDir | Out-Null
      }
      $diffArgs = @('diff', '--') + $pathspec
      $patchContent = @(git @diffArgs) -join [Environment]::NewLine
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
