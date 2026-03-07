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

function Get-RaymanStringListEnv([string]$Name, [string[]]$Default) {
  $raw = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($raw)) { return @($Default) }
  $items = @($raw -split '[,;|]' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($items.Count -eq 0) { return @($Default) }
  return $items
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
$watchNamesRaw = Get-RaymanStringListEnv -Name 'RAYMAN_ALERT_WATCH_PROCESS_NAMES' -Default @('Code','Code - Insiders','WindowsSandbox','WindowsSandboxClient')
$watchNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in $watchNamesRaw) { [void]$watchNames.Add($name) }

$keywords = Get-RaymanStringListEnv -Name 'RAYMAN_ALERT_WINDOW_KEYWORDS' -Default @(
  'confirm',
  'approval',
  'approve',
  'action required',
  'run command',
  'apply',
  'input required',
  'needs input',
  'choose',
  'select',
  'attention',
  'error',
  'failed',
  'sandbox',
  '确认',
  '批准',
  '审批',
  '请选择',
  '选择',
  '需要',
  '运行命令',
  '是否应用',
  '应用这些更改',
  '需要回复',
  '请求',
  '错误',
  '失败',
  '沙盒'
)
$keywordRegex = Build-KeywordRegex -Keywords $keywords
if ([string]::IsNullOrWhiteSpace($keywordRegex)) {
  throw "RAYMAN_ALERT_WINDOW_KEYWORDS is empty."
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

Write-Info ("[alert-watch] started (pid={0}, poll={1}ms, idle-exit={2}s)" -f $PID, $pollMs, $idleExitSeconds)

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
    $matches = @($windows | Where-Object { $_.MainWindowTitle -match $keywordRegex })

    if ($matches.Count -gt 0) {
      $hadPending = $true
      $clearAt = $null
      foreach ($m in $matches) {
        $key = "{0}|{1}" -f $m.ProcessName, $m.MainWindowTitle
        $now = Get-Date
        $shouldAlert = $true
        if ($alertedAt.ContainsKey($key)) {
          $cooldown = [int]($now - $alertedAt[$key]).TotalSeconds
          if ($cooldown -lt $manualCooldownSeconds) { $shouldAlert = $false }
        }
        if ($shouldAlert) {
          $alertedAt[$key] = $now
          $isSandboxWindow = ([string]$m.ProcessName -match '^(?i)WindowsSandbox(Client)?$') -or ([string]$m.MainWindowTitle -match '(?i)Windows Sandbox')
          if ($isSandboxWindow) {
            $reason = ("检测到 Sandbox 窗口需要关注：{0} - {1}。请不要手工关闭该窗口；若已关闭，无需等待自动关闭，回宿主机重跑 setup 或设置 RAYMAN_PLAYWRIGHT_SETUP_SCOPE=wsl。" -f $m.ProcessName, $m.MainWindowTitle)
          } else {
            $reason = ("检测到疑似需要人工处理的窗口：{0} - {1}" -f $m.ProcessName, $m.MainWindowTitle)
          }
          Invoke-RaymanAttentionAlert -Kind 'manual' -Reason $reason -MaxSeconds $manualMaxSeconds | Out-Null
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
