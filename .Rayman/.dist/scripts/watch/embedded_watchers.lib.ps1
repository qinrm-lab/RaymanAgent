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
  $watchNamesRaw = @(Get-RaymanAttentionWatchProcessNames)
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

    $status = @(git status --porcelain)
    if ($status.Count -gt 0) {
      git add -N . | Out-Null
      git diff | Set-Content -LiteralPath ([string]$State.PatchFile) -Encoding UTF8

      $meta = [ordered]@{
        timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        files_changed = $status.Count
      }
      $meta | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath ([string]$State.MetaFile) -Encoding UTF8

      Write-Host ("[auto-save] {0} 自动保存了 {1} 个文件的更改到 {2}" -f (Get-Date -Format 'HH:mm:ss'), $status.Count, [string]$State.PatchFile)
      return [pscustomobject]@{
        saved = $true
        files_changed = $status.Count
        reason = 'saved'
      }
    }

    if (Test-Path -LiteralPath ([string]$State.PatchFile) -PathType Leaf) {
      Remove-Item -LiteralPath ([string]$State.PatchFile) -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath ([string]$State.MetaFile) -PathType Leaf) {
      Remove-Item -LiteralPath ([string]$State.MetaFile) -Force -ErrorAction SilentlyContinue
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
