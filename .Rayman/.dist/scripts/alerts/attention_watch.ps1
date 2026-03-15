param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [string]$PidFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot "..\..\common.ps1"
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
  . $commonPath
} else {
  throw "common.ps1 not found: $commonPath"
}

function Build-KeywordRegex([string[]]$Keywords) {
  $safe = @($Keywords | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [Regex]::Escape($_) })
  if ($safe.Count -eq 0) { return $null }
  return '(?i)(' + ($safe -join '|') + ')'
}

function Get-WatchWindows([bool]$WatchAll, [System.Collections.Generic.HashSet[string]]$WatchNames) {
  $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
      $_.MainWindowHandle -ne 0 -and -not [string]::IsNullOrWhiteSpace($_.MainWindowTitle)
    })
  if ($WatchAll) { return $procs }
  return @($procs | Where-Object { $WatchNames.Contains($_.ProcessName) })
}

function Test-IsSandboxWindow([object]$Window) {
  if ($null -eq $Window) { return $false }
  return (([string]$Window.ProcessName -match '^(?i)WindowsSandbox(Client)?$') -or ([string]$Window.MainWindowTitle -match '(?i)Windows Sandbox'))
}

function Get-DefaultSandboxAttentionWindowPhrases {
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

function Get-DefaultGenericAttentionWindowPhrases {
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

function Resolve-AttentionMatchProfile([object]$Window) {
  if (Test-IsSandboxWindow -Window $Window) { return 'sandbox' }
  return 'generic'
}

function Normalize-AttentionWindowTitle([string]$Title) {
  $value = [string]$Title
  if ([string]::IsNullOrWhiteSpace($value)) { return '' }

  $normalized = $value.Trim().ToLowerInvariant()
  $normalized = [Regex]::Replace($normalized, '0x[0-9a-f]+', '<hex>')
  $normalized = [Regex]::Replace($normalized, '\d+', '<n>')
  $normalized = [Regex]::Replace($normalized, '\s+', ' ')
  return $normalized
}

function Get-AttentionAggregateKey([object]$Match) {
  if ($null -eq $Match) { return '' }
  $normalizedTitle = Normalize-AttentionWindowTitle -Title ([string]$Match.MainWindowTitle)
  return ("{0}|{1}|{2}" -f ([string]$Match.ProcessName), ([string]$Match.MatchProfile), $normalizedTitle)
}

function New-AttentionGroupReason([string]$ProcessName, [string]$MatchProfile, [string[]]$Titles) {
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

function Resolve-AttentionSeverity([string]$MatchProfile, [string[]]$Titles) {
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

function Get-AttentionSeverityPrefix([string]$Severity) {
  switch ($Severity) {
    'high' { return '[高优先级] ' }
    'medium' { return '[中优先级] ' }
    default { return '[低优先级] ' }
  }
}

function Get-AttentionSeverityTitle([string]$Severity) {
  switch ($Severity) {
    'high' { return 'Rayman 高优先级提醒' }
    'medium' { return 'Rayman 中优先级提醒' }
    default { return 'Rayman 低优先级提醒' }
  }
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime'
if (-not (Test-Path -LiteralPath $runtimeDir)) {
  New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
}

if ([string]::IsNullOrWhiteSpace($PidFile)) {
  $PidFile = Join-Path $runtimeDir 'attention_watch.pid'
}

$pollMs = Get-RaymanEnvInt -Name 'RAYMAN_ALERT_WATCH_POLL_MS' -Default 1200 -Min 300 -Max 10000
$idleExitSeconds = Get-RaymanEnvInt -Name 'RAYMAN_ALERT_WATCH_TARGET_IDLE_EXIT_SECONDS' -Default 600 -Min 30 -Max 86400
$manualCooldownSeconds = Get-RaymanEnvInt -Name 'RAYMAN_ALERT_WATCH_COOLDOWN_SECONDS' -Default 90 -Min 5 -Max 3600
$clearDoneSeconds = Get-RaymanEnvInt -Name 'RAYMAN_ALERT_WATCH_CLEAR_DONE_SECONDS' -Default 5 -Min 1 -Max 300
$manualMaxSeconds = Get-RaymanEnvInt -Name 'RAYMAN_ALERT_WATCH_MANUAL_MAX_SECONDS' -Default 180 -Min 5 -Max 3600

$watchAll = Get-RaymanEnvBool -Name 'RAYMAN_ALERT_WATCH_ALL_PROCESSES' -Default $false
$watchNamesRaw = @(Get-RaymanAttentionWatchProcessNames)
$watchNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in $watchNamesRaw) { [void]$watchNames.Add($name) }

$hasGlobalOverride = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('RAYMAN_ALERT_WINDOW_KEYWORDS'))
$sandboxKeywords = if ($hasGlobalOverride) {
  @(Get-RaymanStringListEnv -Name 'RAYMAN_ALERT_WINDOW_KEYWORDS' -Default (Get-DefaultSandboxAttentionWindowPhrases))
} else {
  @(Get-RaymanStringListEnv -Name 'RAYMAN_ALERT_WINDOW_SANDBOX_KEYWORDS' -Default (Get-DefaultSandboxAttentionWindowPhrases))
}
$genericKeywords = if ($hasGlobalOverride) {
  $sandboxKeywords
} else {
  @(Get-RaymanStringListEnv -Name 'RAYMAN_ALERT_WINDOW_VSCODE_KEYWORDS' -Default (Get-DefaultGenericAttentionWindowPhrases))
}

$sandboxKeywordRegex = Build-KeywordRegex -Keywords $sandboxKeywords
$genericKeywordRegex = Build-KeywordRegex -Keywords $genericKeywords
if ([string]::IsNullOrWhiteSpace($sandboxKeywordRegex)) {
  throw "Sandbox attention keyword list is empty."
}
if ([string]::IsNullOrWhiteSpace($genericKeywordRegex)) {
  throw "Generic attention keyword list is empty."
}

$alertedAt = New-Object 'System.Collections.Generic.Dictionary[string, datetime]' ([System.StringComparer]::OrdinalIgnoreCase)
$hadPending = $false
$clearAt = $null
$lastTargetSeen = Get-Date

try {
  Set-Content -LiteralPath $PidFile -Value $PID -NoNewline -Encoding ASCII
} catch {
  Write-Warn ("[alert-watch] write pid file failed: {0}" -f $_.Exception.Message)
  Write-RaymanDiag -Scope 'alert-watch' -Message ("write pid file failed: {0}" -f $_.Exception.ToString())
}

Write-Info ("[alert-watch] started (pid={0}, poll={1}ms, idle-exit={2}s, watch={3}, sandbox-phrases={4}, generic-phrases={5})" -f $PID, $pollMs, $idleExitSeconds, (($watchNamesRaw | Select-Object -Unique) -join ','), (($sandboxKeywords | Select-Object -Unique) -join ' | '), (($genericKeywords | Select-Object -Unique) -join ' | '))

try {
  while ($true) {
    $targets = @()
    if (-not $watchAll -and $watchNames.Count -gt 0) {
      $targets = @(Get-Process -Name @($watchNames) -ErrorAction SilentlyContinue)
    }
    if ($watchAll -or $targets.Count -gt 0) {
      $lastTargetSeen = Get-Date
    } else {
      $idle = [int]((Get-Date) - $lastTargetSeen).TotalSeconds
      if ($idle -ge $idleExitSeconds) {
        Write-Info ("[alert-watch] no target process for {0}s, exiting." -f $idle)
        break
      }
    }

    $windows = Get-WatchWindows -WatchAll:$watchAll -WatchNames $watchNames
    $matches = @(
      foreach ($window in $windows) {
        $profile = Resolve-AttentionMatchProfile -Window $window
        $profileRegex = if ($profile -eq 'sandbox') { $sandboxKeywordRegex } else { $genericKeywordRegex }
        if (-not [string]::IsNullOrWhiteSpace($profileRegex) -and [string]$window.MainWindowTitle -match $profileRegex) {
          $normalizedTitle = Normalize-AttentionWindowTitle -Title ([string]$window.MainWindowTitle)
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
      $hadPending = $true
      $clearAt = $null
      $groups = @($matches | Group-Object -Property AggregateKey)
      foreach ($group in $groups) {
        $m = $group.Group | Select-Object -First 1
        $key = [string]$group.Name
        $now = Get-Date
        $shouldAlert = $true
        if ($alertedAt.ContainsKey($key)) {
          $cooldown = [int]($now - $alertedAt[$key]).TotalSeconds
          if ($cooldown -lt $manualCooldownSeconds) { $shouldAlert = $false }
        }
        if ($shouldAlert) {
          $alertedAt[$key] = $now
          $groupTitles = @($group.Group | ForEach-Object { [string]$_.MainWindowTitle })
          $severity = Resolve-AttentionSeverity -MatchProfile ([string]$m.MatchProfile) -Titles $groupTitles
          $reason = (Get-AttentionSeverityPrefix -Severity $severity) + (New-AttentionGroupReason -ProcessName ([string]$m.ProcessName) -MatchProfile ([string]$m.MatchProfile) -Titles $groupTitles)
          $title = Get-AttentionSeverityTitle -Severity $severity
          Invoke-RaymanAttentionAlert -Kind 'manual' -Reason $reason -Title $title -MaxSeconds $manualMaxSeconds | Out-Null
        }
      }
    } else {
      if ($hadPending) {
        if ($null -eq $clearAt) {
          $clearAt = Get-Date
        } else {
          $quiet = [int]((Get-Date) - $clearAt).TotalSeconds
          if ($quiet -ge $clearDoneSeconds) {
            Invoke-RaymanAttentionAlert -Kind 'done' -Reason '疑似待处理窗口已消失。' | Out-Null
            $hadPending = $false
            $clearAt = $null
          }
        }
      }
    }

    Start-Sleep -Milliseconds $pollMs
  }
} catch {
  Write-Warn ("[alert-watch] failed: {0}" -f $_.Exception.Message)
  Write-RaymanDiag -Scope 'alert-watch' -Message ("main loop failed: {0}" -f $_.Exception.ToString())
  try {
    Invoke-RaymanAttentionAlert -Kind 'error' -Reason 'alert-watch 运行异常，需要人工查看。' -MaxSeconds 30 | Out-Null
  } catch {
    Write-RaymanDiag -Scope 'alert-watch' -Message ("error alert invoke failed: {0}" -f $_.Exception.ToString())
  }
} finally {
  try {
    if (Test-Path -LiteralPath $PidFile) { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue }
  } catch {
    Write-RaymanDiag -Scope 'alert-watch' -Message ("cleanup pid file failed: {0}" -f $_.Exception.ToString())
  }
  Write-Info "[alert-watch] stopped"
}
