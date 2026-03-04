param(
  [Alias('a')][string]$ApprovalMode = $(if ($env:RAYMAN_APPROVAL_MODE) { $env:RAYMAN_APPROVAL_MODE } else { 'full-auto' })
)

. "$PSScriptRoot\common.ps1"

# --- self-repair --------------------------------------------------------
& "$PSScriptRoot\scripts\repair\ensure_complete_rayman.ps1" -Root (Resolve-Path "$PSScriptRoot\..").Path | Out-Host

$ErrorActionPreference = 'Stop'

function Ensure-RaymanSolutionNameEncoding([string]$WorkspaceRoot) {
  try {
    $solutionNamePath = Join-Path $WorkspaceRoot '.SolutionName'
    if (-not (Test-Path -LiteralPath $solutionNamePath -PathType Leaf)) { return }

    $bytes = [System.IO.File]::ReadAllBytes($solutionNamePath)
    if ($null -eq $bytes -or $bytes.Length -lt 3) { return }

    if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
      $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
      $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
      [System.IO.File]::WriteAllText($solutionNamePath, $text, $utf8NoBom)
      Write-Info ("[init] 已修复 .SolutionName BOM 编码: {0}" -f $solutionNamePath)
    }
  } catch {
    Write-Warn ("[init] 修复 .SolutionName 编码失败：{0}" -f $_.Exception.Message)
  }
}

function Get-RaymanConfigProp([object]$Object, [string]$Name, $DefaultValue) {
  if ($null -eq $Object) { return $DefaultValue }
  $prop = $Object.PSObject.Properties[$Name]
  if ($null -eq $prop) { return $DefaultValue }
  if ($null -eq $prop.Value) { return $DefaultValue }
  return $prop.Value
}

function ConvertTo-RaymanConfigBool([object]$Value, [bool]$Default = $false) {
  if ($null -eq $Value) { return $Default }
  if ($Value -is [bool]) { return [bool]$Value }
  $raw = [string]$Value
  if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
  switch ($raw.Trim().ToLowerInvariant()) {
    '1' { return $true }
    'true' { return $true }
    'yes' { return $true }
    'on' { return $true }
    '0' { return $false }
    'false' { return $false }
    'no' { return $false }
    'off' { return $false }
    default { return $Default }
  }
}

function Get-RaymanBackupInitSettings([string]$WorkspaceRoot) {
  $configPath = Join-Path $WorkspaceRoot '.Rayman\config.json'

  $rawConfig = $null
  if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try {
      $rawConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
      Write-Warn ("[config] 读取 .Rayman/config.json 失败，使用默认备份配置：{0}" -f $_.Exception.Message)
    }
  } else {
    Write-Warn "[config] 未找到 .Rayman/config.json，使用默认备份配置。"
  }

  $rawBackup = $null
  if ($rawConfig -and $rawConfig.PSObject.Properties['backup']) {
    $rawBackup = $rawConfig.backup
  } elseif ($rawConfig) {
    Write-Warn "[config] config.json 缺少 backup 节点，使用默认备份配置。"
  }

  $enabled = ConvertTo-RaymanConfigBool -Value (Get-RaymanConfigProp -Object $rawBackup -Name 'enabled' -DefaultValue $true) -Default $true
  $onFailure = [string](Get-RaymanConfigProp -Object $rawBackup -Name 'onFailure' -DefaultValue 'stop')
  if ([string]::IsNullOrWhiteSpace($onFailure)) { $onFailure = 'stop' }
  $onFailure = $onFailure.Trim().ToLowerInvariant()
  if ($onFailure -ne 'stop' -and $onFailure -ne 'warn') {
    Write-Warn ("[config] backup.onFailure={0} 非法，回退为 stop。" -f $onFailure)
    $onFailure = 'stop'
  }

  return [pscustomobject]@{
    ConfigPath = $configPath
    Enabled    = $enabled
    OnFailure  = $onFailure
  }
}

function Invoke-RaymanPreInitBackup([string]$WorkspaceRoot) {
  $settings = Get-RaymanBackupInitSettings -WorkspaceRoot $WorkspaceRoot
  if (-not $settings.Enabled) {
    Write-Info "[backup] 已在 .Rayman/config.json 中禁用初始化前备份。"
    return
  }

  $backupScript = Join-Path $PSScriptRoot 'scripts\backup\backup_solution.ps1'
  if (-not (Test-Path -LiteralPath $backupScript -PathType Leaf)) {
    $msg = "缺少备份脚本：$backupScript"
    if ($settings.OnFailure -eq 'stop') { throw $msg }
    Write-Warn ("[backup] {0}（已按 onFailure=warn 继续）" -f $msg)
    return
  }

  try {
    & $backupScript -WorkspaceRoot $WorkspaceRoot -ConfigPath $settings.ConfigPath | Out-Host
  } catch {
    $msg = "初始化前备份失败：$($_.Exception.Message)"
    if ($settings.OnFailure -eq 'stop') { throw $msg }
    Write-Warn ("[backup] {0}（已按 onFailure=warn 继续）" -f $msg)
  }
}

function Invoke-RaymanAutoSnapshotIfNoGit([string]$WorkspaceRoot) {
  $enabled = [string][System.Environment]::GetEnvironmentVariable('RAYMAN_AUTO_SNAPSHOT_ON_NO_GIT')
  if ([string]::IsNullOrWhiteSpace($enabled)) { $enabled = '1' }
  if ($enabled -eq '0') { return }

  $git = Get-Command git -ErrorAction SilentlyContinue
  if ($null -eq $git) { return }

  Push-Location $WorkspaceRoot
  try {
    & git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -eq 0) { return }
  } finally {
    Pop-Location
  }

  $snapshotScript = Join-Path $PSScriptRoot 'scripts\backup\snapshot_workspace.ps1'
  if (-not (Test-Path -LiteralPath $snapshotScript -PathType Leaf)) { return }
  try {
    & $snapshotScript -WorkspaceRoot $WorkspaceRoot -Reason 'init.ps1:auto-non-git' | Out-Host
  } catch {
    Write-Warn ("[snapshot] 自动快照失败：{0}" -f $_.Exception.Message)
  }
}

try {
  $workspaceRootForBackup = (Resolve-Path (Join-Path $PSScriptRoot '..')) | Select-Object -ExpandProperty Path
  Ensure-RaymanSolutionNameEncoding -WorkspaceRoot $workspaceRootForBackup
  Invoke-RaymanAutoSnapshotIfNoGit -WorkspaceRoot $workspaceRootForBackup
  Invoke-RaymanPreInitBackup -WorkspaceRoot $workspaceRootForBackup
} catch {
  Write-Error $_
  throw
}

# --- approval mode -------------------------------------------------------------
try {
  $env:RAYMAN_APPROVAL_MODE = $ApprovalMode
  $runtime = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path ".Rayman\runtime"
  if (-not (Test-Path $runtime)) { New-Item -ItemType Directory -Force $runtime | Out-Null }
  Set-Content -Path (Join-Path $runtime "approval_mode") -Value $ApprovalMode -NoNewline
  Write-Info ("approval: {0}" -f $ApprovalMode)
} catch {
  Write-Warn ("approval mode init failed: {0}" -f $_.Exception.Message)
}




# --- proxy (workspace settings -> user settings -> system proxy) ----------------
try {
  $WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')) | Select-Object -ExpandProperty Path
  & "$PSScriptRoot\scripts\proxy\detect_win_proxy.ps1" -WorkspaceRoot $WorkspaceRoot | Out-Host
  $proxySnapshotPath = Join-Path $WorkspaceRoot '.Rayman\runtime\proxy.resolved.json'
  if (Test-Path -LiteralPath $proxySnapshotPath -PathType Leaf) {
    try {
      $proxySnapshot = Get-Content -LiteralPath $proxySnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      Write-Info ("proxy source: {0}" -f ([string]$proxySnapshot.source))
    } catch {
      Write-Warn ("proxy snapshot parse failed: {0}" -f $_.Exception.Message)
    }
  }
} catch {
  Write-Warn ("proxy detect failed: {0}" -f $_.Exception.Message)
}

# --- skills (auto) -------------------------------------------------------------------

try {

  if ($env:RAYMAN_SKILLS_AUTO -ne "0") {

    & "$PSScriptRoot\scripts\skills\detect_skills.ps1" -Root (Resolve-Path "$PSScriptRoot\..").Path | Out-Host

    if (Test-Path (Join-Path (Resolve-Path "$PSScriptRoot\..").Path ".Rayman\runtime\skills.env.ps1")) {

      . (Join-Path (Resolve-Path "$PSScriptRoot\..").Path ".Rayman\runtime\skills.env.ps1")

    }

  }

} catch {

  Write-Host "[skills] warn: $($_.Exception.Message)"

}



# --- logging -------------------------------------------------------------------

$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')) | Select-Object -ExpandProperty Path

$LogDir = Join-Path $WorkspaceRoot '.Rayman\logs'

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force $LogDir | Out-Null }

$Ts = Get-Date -Format "yyyyMMdd_HHmmss"

$LogPath = Join-Path $LogDir ("init.win.{0}.log" -f $Ts)

Start-Transcript -Path $LogPath -Append | Out-Null

Write-Host ("[init] log: {0}" -f $LogPath)



# Version banner

$VersionPath = Join-Path $PSScriptRoot 'VERSION'

$RaymanVersion = if (Test-Path $VersionPath) { (Get-Content $VersionPath -Raw).Trim() } else { "unknown" }





function Get-RaymanBoolEnv([string]$Name, [bool]$Default = $false) {
  $raw = [System.Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
  switch ($raw.Trim().ToLowerInvariant()) {
    '1' { return $true }
    'true' { return $true }
    'yes' { return $true }
    'on' { return $true }
    '0' { return $false }
    'false' { return $false }
    'no' { return $false }
    'off' { return $false }
    default { return $Default }
  }
}

function Get-RaymanIntEnv([string]$Name, [int]$Default, [int]$Min = 1, [int]$Max = 86400) {
  $raw = [System.Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
  $parsed = 0
  if ([int]::TryParse($raw, [ref]$parsed)) {
    if ($parsed -lt $Min) { return $Min }
    if ($parsed -gt $Max) { return $Max }
    return $parsed
  }
  return $Default
}

$script:RaymanManualAlertRaised = $false

function Invoke-RaymanManualAlert([string]$Reason, [int]$MaxSeconds = 0) {
  if ($script:RaymanManualAlertRaised) { return }
  try {
    Invoke-RaymanAttentionAlert -Kind 'manual' -Reason $Reason -MaxSeconds $MaxSeconds | Out-Null
    $script:RaymanManualAlertRaised = $true
  } catch {}
}

function Invoke-RaymanDoneAlert([string]$Reason = 'Rayman 初始化已完成') {
  try {
    Invoke-RaymanAttentionAlert -Kind 'done' -Reason $Reason | Out-Null
  } catch {}
}

function Invoke-RaymanErrorAlert([string]$Reason = 'Rayman 初始化失败，需要人工介入') {
  if ($script:RaymanManualAlertRaised) { return }
  try {
    Invoke-RaymanAttentionAlert -Kind 'error' -Reason $Reason | Out-Null
  } catch {}
}

function Start-RaymanAttentionWatch([string]$WorkspaceRoot) {
  $enabled = Get-RaymanBoolEnv -Name 'RAYMAN_ALERT_WATCH_ENABLED' -Default $true
  if (-not $enabled) {
    Write-Info "[alert-watch] 已禁用自动启动（RAYMAN_ALERT_WATCH_ENABLED=0）。"
    return
  }

  $watchScript = Join-Path $PSScriptRoot 'scripts\alerts\attention_watch.ps1'
  if (-not (Test-Path -LiteralPath $watchScript -PathType Leaf)) {
    Write-Warn ("[alert-watch] 缺少脚本：{0}" -f $watchScript)
    return
  }

  $runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime'
  if (-not (Test-Path -LiteralPath $runtimeDir)) {
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
  }
  $pidFile = Join-Path $runtimeDir 'attention_watch.pid'

  if (Test-Path -LiteralPath $pidFile -PathType Leaf) {
    $oldPid = Get-RaymanPidFromFile -PidFilePath $pidFile
    if ($oldPid -gt 0 -and (Test-RaymanPidFileProcess -PidFilePath $pidFile -AllowedProcessNames @('powershell', 'pwsh'))) {
      Write-Info ("[alert-watch] 已在运行（PID={0}），跳过重复启动。" -f $oldPid)
      return
    }
    if ($oldPid -gt 0) {
      Write-Warn ("[alert-watch] 检测到失效 pid 文件（PID={0}），准备重启监控。" -f $oldPid)
    }
    try { Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue } catch {}
  }

  try {
    $psHost = Resolve-RaymanPowerShellHost
    if ([string]::IsNullOrWhiteSpace($psHost)) {
      throw "cannot find PowerShell host (pwsh/powershell) in PATH"
    }

    $proc = Start-RaymanProcessHiddenCompat -FilePath $psHost -ArgumentList @(
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      $watchScript,
      '-WorkspaceRoot',
      $WorkspaceRoot,
      '-PidFile',
      $pidFile
    )
    Write-Info ("[alert-watch] 已启动后台监控（PID={0}, host={1}）。" -f $proc.Id, $psHost)
  } catch {
    Write-Warn ("[alert-watch] 启动失败：{0}" -f $_.Exception.Message)
  }
}

function Install-RaymanVscodeAutoStart([string]$WorkspaceRoot) {
  $enabled = Get-RaymanBoolEnv -Name 'RAYMAN_VSCODE_AUTO_START_INSTALL_ENABLED' -Default $true
  if (-not $enabled) {
    Write-Info "[vscode-auto] 已禁用自动安装（RAYMAN_VSCODE_AUTO_START_INSTALL_ENABLED=0）。"
    return
  }

  $installScript = Join-Path $PSScriptRoot 'scripts\watch\install_vscode_autostart.ps1'
  if (-not (Test-Path -LiteralPath $installScript -PathType Leaf)) {
    Write-Warn ("[vscode-auto] 缺少脚本：{0}" -f $installScript)
    return
  }

  try {
    & $installScript -WorkspaceRoot $WorkspaceRoot | Out-Host
  } catch {
    Write-Warn ("[vscode-auto] 安装失败：{0}" -f $_.Exception.Message)
  }
}

$script:RaymanSandboxProxyBridge = $null
$script:RaymanKeepSandboxProxyBridge = $false

function Get-RaymanProxyValueByPriority {
  foreach ($name in @('https_proxy', 'HTTPS_PROXY', 'http_proxy', 'HTTP_PROXY', 'all_proxy', 'ALL_PROXY')) {
    $v = [System.Environment]::GetEnvironmentVariable($name)
    if (-not [string]::IsNullOrWhiteSpace([string]$v)) {
      return $v.Trim()
    }
  }
  return $null
}

function Get-RaymanProxyUri([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  try {
    return [System.Uri]$Value
  } catch {
    if ($Value -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
      try { return [System.Uri]("http://$Value") } catch {}
    }
    return $null
  }
}

function Test-RaymanLoopbackHost([string]$HostName) {
  if ([string]::IsNullOrWhiteSpace($HostName)) { return $false }
  $h = $HostName.Trim().ToLowerInvariant()
  return ($h -eq '127.0.0.1' -or $h -eq 'localhost' -or $h -eq '::1')
}

function Test-RaymanTcpPortAvailable([int]$Port) {
  if ($Port -lt 1 -or $Port -gt 65535) { return $false }
  $listener = $null
  try {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port)
    $listener.Start()
    return $true
  } catch {
    return $false
  } finally {
    if ($listener) {
      try { $listener.Stop() } catch {}
    }
  }
}

function Get-RaymanAvailableTcpPort([int]$PreferredPort) {
  if (Test-RaymanTcpPortAvailable -Port $PreferredPort) { return $PreferredPort }

  for ($p = 18080; $p -le 18180; $p++) {
    if (Test-RaymanTcpPortAvailable -Port $p) { return $p }
  }

  $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, 0)
  try {
    $listener.Start()
    return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
  } finally {
    try { $listener.Stop() } catch {}
  }
}

function Remove-RaymanFileBestEffort([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
  try { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue } catch {}
}

function Stop-RaymanSandboxProxyBridgeProcess([int]$ProcessId) {
  if ($ProcessId -le 0) { return }
  try {
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($p) { Stop-Process -Id $ProcessId -Force -ErrorAction Stop }
  } catch {}
}

function Add-RaymanProxyBridgeFirewallRule([string]$RuleName, [int]$Port) {
  if ([string]::IsNullOrWhiteSpace($RuleName)) { return $false }
  if ($Port -lt 1 -or $Port -gt 65535) { return $false }
  try {
    & netsh advfirewall firewall delete rule name="$RuleName" protocol=TCP localport=$Port | Out-Null
  } catch {}
  try {
    $out = (& netsh advfirewall firewall add rule name="$RuleName" dir=in action=allow protocol=TCP localport=$Port profile=any 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0) {
      Write-Info ("[sandbox-proxy] firewall allow rule added: {0} (tcp/{1})" -f $RuleName, $Port)
      return $true
    }
    Write-Warn ("[sandbox-proxy] firewall rule add failed (exit={0}): {1}" -f $LASTEXITCODE, $out)
    Write-Warn ("[sandbox-proxy] 建议以管理员执行：netsh advfirewall firewall add rule name=""{0}"" dir=in action=allow protocol=TCP localport={1} profile=any" -f $RuleName, $Port)
    return $false
  } catch {}
  Write-Warn ("[sandbox-proxy] firewall rule add failed: {0} (tcp/{1}); sandbox may not reach host bridge." -f $RuleName, $Port)
  return $false
}

function Remove-RaymanProxyBridgeFirewallRule([string]$RuleName, [int]$Port) {
  if ([string]::IsNullOrWhiteSpace($RuleName)) { return }
  if ($Port -lt 1 -or $Port -gt 65535) { return }
  try {
    & netsh advfirewall firewall delete rule name="$RuleName" protocol=TCP localport=$Port | Out-Null
    if ($LASTEXITCODE -eq 0) {
      Write-Info ("[sandbox-proxy] firewall rule removed: {0} (tcp/{1})" -f $RuleName, $Port)
    }
  } catch {}
}

function Start-RaymanSandboxProxyBridge([string]$WorkspaceRoot) {
  $runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime'
  if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
  }

  $overrideFile = Join-Path $runtimeDir 'sandbox.proxy.override.json'
  $pidFile = Join-Path $runtimeDir 'sandbox_proxy_bridge.pid'
  $stateFile = Join-Path $runtimeDir 'sandbox_proxy_bridge.state.json'
  $logFile = Join-Path $runtimeDir 'sandbox_proxy_bridge.log'
  $oldPid = 0
  if (Test-Path -LiteralPath $pidFile -PathType Leaf) {
    try {
      $oldRaw = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction Stop).Trim()
      [void][int]::TryParse($oldRaw, [ref]$oldPid)
    } catch {}
  }

  if (-not (Get-RaymanBoolEnv -Name 'RAYMAN_SANDBOX_PROXY_BRIDGE_ENABLED' -Default $true)) {
    if ($oldPid -gt 0) { Stop-RaymanSandboxProxyBridgeProcess -ProcessId $oldPid }
    Remove-RaymanFileBestEffort -Path $pidFile
    Remove-RaymanFileBestEffort -Path $stateFile
    Remove-RaymanFileBestEffort -Path $overrideFile
    return $null
  }

  $proxyRaw = Get-RaymanProxyValueByPriority
  $proxyUri = Get-RaymanProxyUri -Value $proxyRaw
  if ($null -eq $proxyUri) {
    if ($oldPid -gt 0) { Stop-RaymanSandboxProxyBridgeProcess -ProcessId $oldPid }
    Remove-RaymanFileBestEffort -Path $pidFile
    Remove-RaymanFileBestEffort -Path $stateFile
    Remove-RaymanFileBestEffort -Path $overrideFile
    return $null
  }

  if (-not (Test-RaymanLoopbackHost -HostName $proxyUri.Host)) {
    if ($oldPid -gt 0) { Stop-RaymanSandboxProxyBridgeProcess -ProcessId $oldPid }
    Remove-RaymanFileBestEffort -Path $pidFile
    Remove-RaymanFileBestEffort -Path $stateFile
    Remove-RaymanFileBestEffort -Path $overrideFile
    return $null
  }

  if ($proxyUri.Port -le 0) {
    Write-Warn ("[sandbox-proxy] loopback proxy missing port: {0}" -f $proxyRaw)
    if ($oldPid -gt 0) { Stop-RaymanSandboxProxyBridgeProcess -ProcessId $oldPid }
    Remove-RaymanFileBestEffort -Path $pidFile
    Remove-RaymanFileBestEffort -Path $stateFile
    Remove-RaymanFileBestEffort -Path $overrideFile
    return $null
  }

  $scheme = $proxyUri.Scheme.ToLowerInvariant()
  if ($scheme -ne 'http' -and $scheme -ne 'https') {
    Write-Warn ("[sandbox-proxy] unsupported proxy scheme for bridge: {0}" -f $proxyRaw)
    if ($oldPid -gt 0) { Stop-RaymanSandboxProxyBridgeProcess -ProcessId $oldPid }
    Remove-RaymanFileBestEffort -Path $pidFile
    Remove-RaymanFileBestEffort -Path $stateFile
    Remove-RaymanFileBestEffort -Path $overrideFile
    return $null
  }

  if ($oldPid -gt 0) { Stop-RaymanSandboxProxyBridgeProcess -ProcessId $oldPid }

  $bridgeScript = Join-Path $PSScriptRoot 'scripts\proxy\run_tcp_bridge.ps1'
  if (-not (Test-Path -LiteralPath $bridgeScript -PathType Leaf)) {
    Write-Warn ("[sandbox-proxy] bridge script missing: {0}" -f $bridgeScript)
    Remove-RaymanFileBestEffort -Path $overrideFile
    return $null
  }

  $defaultPort = $proxyUri.Port + 10000
  if ($defaultPort -gt 65535) { $defaultPort = 18988 }
  $preferredPort = Get-RaymanIntEnv -Name 'RAYMAN_SANDBOX_PROXY_BRIDGE_PORT' -Default $defaultPort -Min 1025 -Max 65535
  $listenPort = Get-RaymanAvailableTcpPort -PreferredPort $preferredPort
  if ($listenPort -le 0) {
    Write-Warn "[sandbox-proxy] cannot allocate listen port for bridge."
    Remove-RaymanFileBestEffort -Path $overrideFile
    return $null
  }

  try {
    $psHost = Resolve-RaymanPowerShellHost
    if ([string]::IsNullOrWhiteSpace($psHost)) {
      throw "cannot find PowerShell host (pwsh/powershell) in PATH"
    }

    $proc = Start-RaymanProcessHiddenCompat -FilePath $psHost -ArgumentList @(
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      $bridgeScript,
      '-ListenAddress',
      '0.0.0.0',
      '-ListenPort',
      $listenPort,
      '-TargetHost',
      $proxyUri.Host,
      '-TargetPort',
      $proxyUri.Port,
      '-PidFile',
      $pidFile,
      '-LogFile',
      $logFile,
      '-StateFile',
      $stateFile
    )
    Write-Info ("[sandbox-proxy] bridge host={0} pid={1}" -f $psHost, $proc.Id)

    Start-Sleep -Milliseconds 700
    $alive = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    if (-not $alive) {
      Write-Warn ("[sandbox-proxy] bridge process exited immediately; check {0}" -f $logFile)
      Remove-RaymanFileBestEffort -Path $overrideFile
      return $null
    }

    $overrideProxy = ("{0}://127.0.0.1:{1}" -f $scheme, $listenPort)
    $firewallRuleName = $null
    $firewallRuleAdded = $false
    if (Get-RaymanBoolEnv -Name 'RAYMAN_SANDBOX_PROXY_BRIDGE_FIREWALL_RULE_ENABLED' -Default $true) {
      $workspaceLeaf = Split-Path -Path $WorkspaceRoot -Leaf
      if ([string]::IsNullOrWhiteSpace($workspaceLeaf)) { $workspaceLeaf = 'workspace' }
      $firewallRuleName = ("Rayman Sandbox Proxy Bridge {0} {1}" -f $workspaceLeaf, $listenPort)
      $firewallRuleAdded = Add-RaymanProxyBridgeFirewallRule -RuleName $firewallRuleName -Port $listenPort
    }

    $payload = [ordered]@{
      proxy        = $overrideProxy
      source       = 'host-loopback-bridge'
      bridgePid    = $proc.Id
      bridgeListen = ('0.0.0.0:{0}' -f $listenPort)
      bridgeTarget = ('{0}:{1}' -f $proxyUri.Host, $proxyUri.Port)
      firewallRule = $firewallRuleName
      firewallOpen = $firewallRuleAdded
      generatedAt  = (Get-Date).ToString('o')
    }
    ($payload | ConvertTo-Json -Depth 6) | Out-File -FilePath $overrideFile -Encoding utf8

    Write-Info ("[sandbox-proxy] bridge started pid={0} listen=0.0.0.0:{1} -> {2}:{3}" -f $proc.Id, $listenPort, $proxyUri.Host, $proxyUri.Port)
    Write-Info ("[sandbox-proxy] override file: {0}" -f $overrideFile)

    return [pscustomobject]@{
      Pid          = $proc.Id
      PidFile      = $pidFile
      StateFile    = $stateFile
      LogFile      = $logFile
      OverrideFile = $overrideFile
      ListenPort   = $listenPort
      FirewallRuleName = $firewallRuleName
      FirewallRuleAdded = $firewallRuleAdded
    }
  } catch {
    Write-Warn ("[sandbox-proxy] start bridge failed: {0}" -f $_.Exception.Message)
    Remove-RaymanFileBestEffort -Path $overrideFile
    return $null
  }
}

function Stop-RaymanSandboxProxyBridge([object]$BridgeInfo, [bool]$KeepRunning = $false) {
  if ($null -eq $BridgeInfo) { return }
  if ($KeepRunning) {
    Write-Info ("[sandbox-proxy] keep running pid={0} (auto-close disabled)." -f $BridgeInfo.Pid)
    return
  }

  Stop-RaymanSandboxProxyBridgeProcess -ProcessId ([int]$BridgeInfo.Pid)
  if ($BridgeInfo.PSObject.Properties['FirewallRuleAdded'] -and $BridgeInfo.FirewallRuleAdded -and
      $BridgeInfo.PSObject.Properties['FirewallRuleName'] -and -not [string]::IsNullOrWhiteSpace([string]$BridgeInfo.FirewallRuleName)) {
    Remove-RaymanProxyBridgeFirewallRule -RuleName ([string]$BridgeInfo.FirewallRuleName) -Port ([int]$BridgeInfo.ListenPort)
  }
  Remove-RaymanFileBestEffort -Path ([string]$BridgeInfo.PidFile)
  Remove-RaymanFileBestEffort -Path ([string]$BridgeInfo.OverrideFile)
  Remove-RaymanFileBestEffort -Path ([string]$BridgeInfo.StateFile)
  Write-Info "[sandbox-proxy] bridge stopped and override removed."
}

Write-Info ("Windows Init ({0})" -f $RaymanVersion)
Start-RaymanAttentionWatch -WorkspaceRoot $WorkspaceRoot
Install-RaymanVscodeAutoStart -WorkspaceRoot $WorkspaceRoot



try {





  & "$PSScriptRoot\win-preflight.ps1"

  & "$PSScriptRoot\win-proxy-check.ps1"



  # --- PWA UI automation sandbox prep -------------------------------------------------

  & "$PSScriptRoot\scripts\pwa\prepare_windows_sandbox.ps1"



  $WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')) | Select-Object -ExpandProperty Path

  $SandboxDir = Join-Path (Join-Path $WorkspaceRoot '.Rayman\runtime') 'windows-sandbox'

  $WsbPath = Join-Path $SandboxDir 'rayman-pwa.wsb'
  $MappingInfoPath = Join-Path $SandboxDir 'mapping.json'

  $StatusDir = Join-Path $SandboxDir 'status'

  $StatusFile = Join-Path $StatusDir 'bootstrap_status.json'

  $LogFile = Join-Path $StatusDir 'bootstrap.log'
  $script:RaymanSandboxProxyBridge = Start-RaymanSandboxProxyBridge -WorkspaceRoot $WorkspaceRoot

  function Get-RaymanSandboxHostAclIssue([string]$hostFolder) {
    try {
      if (-not (Test-Path -LiteralPath $hostFolder -PathType Container)) {
        return $null
      }

      $acl = [System.IO.Directory]::GetAccessControl($hostFolder)
      $rules = $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
      $suspectCount = 0
      foreach ($r in $rules) {
        if ($r -and (-not $r.IsInherited) -and ($r.IdentityReference -is [System.Security.Principal.SecurityIdentifier])) {
          $sid = [System.Security.Principal.SecurityIdentifier]$r.IdentityReference
          if ($sid.Value -match '^S-1-5-') {
            try {
              [void]$sid.Translate([System.Security.Principal.NTAccount])
            } catch {
              $suspectCount++
            }
          }
        }
      }

      if ($suspectCount -gt 0) {
        return ("HostFolder ACL 包含未解析 SID（{0} 条）。该路径在部分机器会触发 Windows Sandbox 0x80070057 参数错误。" -f $suspectCount)
      }
    } catch {
      return ("读取 HostFolder ACL 失败：{0}" -f $_.Exception.Message)
    }
    return $null
  }

  function Invoke-RaymanBashQuiet([string]$Command) {
    $tmpBase = Join-Path $env:TEMP ("rayman_bash_" + [Guid]::NewGuid().ToString('n'))
    $outFile = "$tmpBase.out.txt"
    $errFile = "$tmpBase.err.txt"
    try {
      $proc = Start-Process -FilePath 'bash' -ArgumentList @('-lc', $Command) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
      $stdout = @()
      $stderr = @()
      if (Test-Path $outFile) { $stdout = @(Get-Content -Path $outFile -ErrorAction SilentlyContinue) }
      if (Test-Path $errFile) { $stderr = @(Get-Content -Path $errFile -ErrorAction SilentlyContinue) }
      return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
      }
    } finally {
      try { Remove-Item -Force $outFile -ErrorAction SilentlyContinue } catch {}
      try { Remove-Item -Force $errFile -ErrorAction SilentlyContinue } catch {}
    }
  }

  function Get-RaymanSandboxHostFolderFromWsb([string]$wsbPath) {
    if (-not (Test-Path -LiteralPath $wsbPath -PathType Leaf)) { return $null }
    try {
      [xml]$wsbXml = [System.IO.File]::ReadAllText($wsbPath)
      $hostFolder = [string]$wsbXml.Configuration.MappedFolders.MappedFolder.HostFolder
      if ([string]::IsNullOrWhiteSpace($hostFolder)) { return $null }
      return $hostFolder
    } catch {
      Write-Warn ("[sandbox] 解析 .wsb HostFolder 失败：{0}" -f $_.Exception.Message)
      return $null
    }
  }

  function Get-RaymanSandboxMappingInfo([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
      return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
    } catch {
      Write-Warn ("[sandbox] 读取 mapping 信息失败：{0}" -f $_.Exception.Message)
      return $null
    }
  }



  function Start-RaymanSandbox([string]$wsbPath) {

    $exe = Join-Path $env:WINDIR 'System32\WindowsSandbox.exe'

    if (-not (Test-Path $exe)) {

      Write-Warn "未发现 WindowsSandbox.exe（可能未启用 Windows Sandbox 功能）。已跳过自动启动。"

      return $false

    }

    if (-not (Test-Path $wsbPath)) {

      Write-Warn "未发现 .wsb 配置：$wsbPath"

      return $false

    }

    $aclHostFolder = Get-RaymanSandboxHostFolderFromWsb -wsbPath $wsbPath
    if ([string]::IsNullOrWhiteSpace($aclHostFolder)) { $aclHostFolder = $WorkspaceRoot }
    $mappingInfo = Get-RaymanSandboxMappingInfo -path $MappingInfoPath
    $aclIssue = Get-RaymanSandboxHostAclIssue $aclHostFolder
    if ($aclIssue) {
      $skipOnAclRisk = Get-RaymanBoolEnv -Name 'RAYMAN_SANDBOX_SKIP_ON_ACL_RISK' -Default $false
      Write-Warn ("[sandbox] HostFolder={0} {1}" -f $aclHostFolder, $aclIssue)
      if ($mappingInfo) {
        $mode = [string]$mappingInfo.mappingMode
        $reason = [string]$mappingInfo.mappingReason
        if (-not [string]::IsNullOrWhiteSpace($mode)) {
          Write-Warn ("[sandbox] 当前映射模式：{0}" -f $mode)
        }
        if (-not [string]::IsNullOrWhiteSpace($reason)) {
          Write-Warn ("[sandbox] 当前映射原因：{0}" -f $reason)
        }
      }
      if ($skipOnAclRisk) {
        Write-Warn "[sandbox] 已根据 RAYMAN_SANDBOX_SKIP_ON_ACL_RISK=1 跳过 Sandbox 启动。"
        Invoke-RaymanManualAlert -Reason "Sandbox HostFolder ACL 风险导致本次跳过启动，请回来确认是否清理 ACL 或强制启动。"
        return $false
      }
      Write-Warn "[sandbox] 继续尝试启动；如需遇到 ACL 风险时立即跳过，可设置 RAYMAN_SANDBOX_SKIP_ON_ACL_RISK=1。"
    }

    $existing = Get-Process -Name 'WindowsSandbox','WindowsSandboxClient' -ErrorAction SilentlyContinue
    if ($existing) {
      $existingList = ($existing | ForEach-Object { "$($_.ProcessName)#$($_.Id)" }) -join ', '
      $killExisting = Get-RaymanBoolEnv -Name 'RAYMAN_SANDBOX_KILL_EXISTING' -Default $false
      if (-not $killExisting) {
        Write-Warn ("[sandbox] 检测到已有运行中的 Sandbox 实例：{0}。默认不主动关闭，已跳过本次启动。可先手工关闭后重试，或设置 RAYMAN_SANDBOX_KILL_EXISTING=1 允许自动关闭旧实例。" -f $existingList)
        Invoke-RaymanManualAlert -Reason "检测到已有 Sandbox 实例且未自动关闭，请手工关闭后重试，或设置 RAYMAN_SANDBOX_KILL_EXISTING=1。"
        return $false
      }
      Write-Info ("[sandbox] 检测到已有运行中的 Sandbox 实例：{0}，已根据 RAYMAN_SANDBOX_KILL_EXISTING=1 自动关闭后再启动。" -f $existingList)
      foreach ($p in $existing) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
      }
      Start-Sleep -Seconds 2
    }

    # Clear previous status to avoid false positives.

    if (Test-Path $StatusFile) { Remove-Item -Force $StatusFile }

    Write-Info "启动 Windows Sandbox：$wsbPath"

    $proc = Start-Process -FilePath $exe -ArgumentList @($wsbPath) -PassThru
    Write-Info ("[sandbox] WindowsSandbox PID={0}" -f $proc.Id)

    return $proc

  }



  function Wait-RaymanSandboxReady {

    param(

      [int]$SandboxPid = 0,

      [int]$TimeoutSeconds = 1800,

      [int]$PollSeconds = 3,

      [int]$HeartbeatSeconds = 30,

      [bool]$HeartbeatSmartSilenceEnabled = $true,

      [bool]$HeartbeatVerboseEnabled = $true,

      [int]$HeartbeatSilentWindowSeconds = 15,

      [int]$EarlyExitDetectSeconds = 20,

      [int]$NoStatusFailSeconds = 45

    )



    Write-Info "等待 Sandbox bootstrap 完成（状态文件：$StatusFile）"

    $waitStarted = Get-Date
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    if ($HeartbeatSeconds -lt 1) { $HeartbeatSeconds = 30 }
    if ($HeartbeatSilentWindowSeconds -lt 1) { $HeartbeatSilentWindowSeconds = [Math]::Max(1, [Math]::Floor($HeartbeatSeconds / 2)) }

    $lastPhase = ''
    $statusObserved = $false
    $lastHeartbeatAt = Get-Date
    $lastOutputAt = Get-Date

    while ((Get-Date) -lt $deadline) {

      if (Test-Path $StatusFile) {
        $statusObserved = $true

        try {

          $raw = Get-Content $StatusFile -Raw -ErrorAction Stop

          $s = $raw | ConvertFrom-Json -ErrorAction Stop
          $phase = ([string]$s.phase).Trim()

          if ($phase -and $phase -ne $lastPhase) {

            $lastPhase = $phase

            Write-Info "[sandbox] phase=$phase message=$($s.message)"
            $lastOutputAt = Get-Date

          }

          if ($s.success -eq $true -and $phase -eq 'ready') {

            Write-Info "[sandbox] bootstrap 已就绪"

            return $true

          }

          if ($phase -like 'failed*') {

            Write-Error "[sandbox] bootstrap 失败：$($s.error)"
            Invoke-RaymanManualAlert -Reason "Sandbox bootstrap 失败。请先不要手工关闭窗口；若已关闭，无需等待自动关闭，回宿主机重跑 setup（默认可降级 wsl）或设置 RAYMAN_PLAYWRIGHT_SETUP_SCOPE=wsl。"

            if (Test-Path $LogFile) {

              Write-Info "日志：$LogFile"

            }

            return $false

          }

        } catch {

          # ignore transient parse errors while file is being written

        }

      }

      if ($SandboxPid -gt 0 -and -not $statusObserved) {
        $elapsed = [int]((Get-Date) - $waitStarted).TotalSeconds
        $proc = Get-Process -Id $SandboxPid -ErrorAction SilentlyContinue
        if (-not $proc) {
          if ($elapsed -le $EarlyExitDetectSeconds) {
            Write-Error "[sandbox] Windows Sandbox 进程提前退出且未写入状态文件。请检查 .wsb 路径格式（避免双反斜杠，如 C:\RaymanProject）并确认已启用 Windows Sandbox / Hyper-V / VirtualMachinePlatform。"
            Invoke-RaymanManualAlert -Reason "Sandbox 进程提前退出。若你手工关闭了窗口，本次会失败且无需等待自动关闭；请回宿主机重跑 setup，或设置 RAYMAN_PLAYWRIGHT_SETUP_SCOPE=wsl。"
          } else {
            Write-Error "[sandbox] Windows Sandbox 进程已退出且未写入状态文件。请检查 .wsb 配置与系统功能状态。"
            Invoke-RaymanManualAlert -Reason "Sandbox 未产生日志状态且已退出。无需等待自动关闭；可直接重跑 setup，或设置 RAYMAN_PLAYWRIGHT_SETUP_SCOPE=wsl。"
          }
          Write-Info "配置：$WsbPath"
          if (Test-Path $LogFile) {
            Write-Info "日志：$LogFile"
          }
          return $false
        }

        if ($elapsed -ge $NoStatusFailSeconds) {
          Write-Error ("[sandbox] 启动后 {0} 秒仍未写入状态文件，疑似卡在 Sandbox 错误弹窗或配置异常。" -f $elapsed)
          Invoke-RaymanManualAlert -Reason "Sandbox 长时间无状态输出。请先检查 Sandbox 窗口是否仍在运行且不要手工关闭；若已关闭，无需等待自动关闭，回宿主机重跑 setup 或设置 RAYMAN_PLAYWRIGHT_SETUP_SCOPE=wsl。"
          Write-Info "配置：$WsbPath"
          if (Test-Path $LogFile) {
            Write-Info "日志：$LogFile"
          }
          return $false
        }
      }

      if ($SandboxPid -gt 0 -and $statusObserved) {
        $procAfterStatus = Get-Process -Id $SandboxPid -ErrorAction SilentlyContinue
        if (-not $procAfterStatus) {
          $phaseHint = if ([string]::IsNullOrWhiteSpace($lastPhase)) { 'unknown' } else { $lastPhase }
          Write-Error ("[sandbox] Windows Sandbox 进程已退出，但 bootstrap 未 ready（lastPhase={0}）。" -f $phaseHint)
          Invoke-RaymanManualAlert -Reason ("Sandbox 在 phase={0} 时退出。若你手工关闭了窗口，本次失败属预期且无需等待自动关闭；请回宿主机重跑 setup，或设置 RAYMAN_PLAYWRIGHT_SETUP_SCOPE=wsl。" -f $phaseHint)
          Write-Info "配置：$WsbPath"
          if (Test-Path $LogFile) {
            Write-Info "日志：$LogFile"
          }
          return $false
        }
      }

      $now = Get-Date
      if ((($now - $lastHeartbeatAt).TotalSeconds) -ge $HeartbeatSeconds) {
        if ($HeartbeatSmartSilenceEnabled -and (($now - $lastOutputAt).TotalSeconds -lt $HeartbeatSilentWindowSeconds)) {
          $lastHeartbeatAt = $now
          Start-Sleep -Seconds $PollSeconds
          continue
        }
        $elapsed = [int](($now - $waitStarted).TotalSeconds)
        $remain = [int][Math]::Max(0, ($deadline - $now).TotalSeconds)
        $phaseHint = if ([string]::IsNullOrWhiteSpace($lastPhase)) { 'waiting' } else { $lastPhase }
        if ($HeartbeatVerboseEnabled) {
          Write-Info ("⏱️ [sandbox] 等待中... 已用 {0}s | 剩余约 {1}s | statusObserved={2} | phase={3}" -f $elapsed, $remain, $statusObserved, $phaseHint)
        } else {
          Write-Info ("⏱️ [sandbox] 等待中... {0}s" -f $elapsed)
        }
        $lastHeartbeatAt = $now
        $lastOutputAt = $now
      }

      Start-Sleep -Seconds $PollSeconds

    }

    Write-Warn "等待超时：未在规定时间内检测到 bootstrap ready。"
    Invoke-RaymanManualAlert -Reason "Sandbox 等待 ready 超时。无需等待自动关闭；可直接重跑 setup（默认 scope=wsl，必要时会回退 host），或设置 RAYMAN_PLAYWRIGHT_SETUP_SCOPE=host。"

    if (Test-Path $LogFile) {

      Write-Info "日志：$LogFile"

    }

    return $false

  }

  function Get-RaymanAutoCloseSandboxOnReady {
    return (Get-RaymanBoolEnv -Name 'RAYMAN_SANDBOX_AUTO_CLOSE' -Default $true)
  }

  function Close-RaymanSandboxProcess {
    param(
      [int]$PrimaryPid = 0,
      [string]$Reason = '结束'
    )

    $targets = New-Object System.Collections.Generic.List[object]

    if ($PrimaryPid -gt 0) {
      $p = Get-Process -Id $PrimaryPid -ErrorAction SilentlyContinue
      if ($p) { $targets.Add($p) | Out-Null }
    }

    $others = Get-Process -Name 'WindowsSandbox','WindowsSandboxClient' -ErrorAction SilentlyContinue
    foreach ($p in $others) {
      $exists = $false
      foreach ($t in $targets) {
        if ($t.Id -eq $p.Id) { $exists = $true; break }
      }
      if (-not $exists) { $targets.Add($p) | Out-Null }
    }

    if ($targets.Count -eq 0) {
      Write-Info ("[sandbox] {0} 后未检测到需要关闭的 Sandbox 进程。" -f $Reason)
      return
    }

    Write-Info ("[sandbox] {0} 后自动关闭 Sandbox：{1}" -f $Reason, (($targets | ForEach-Object { "$($_.ProcessName)#$($_.Id)" }) -join ', '))
    foreach ($p in $targets) {
      try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {}
    }
  }



  $skipStart = Get-RaymanBoolEnv -Name 'RAYMAN_SKIP_SANDBOX_START' -Default $false
  $playwrightRequire = Get-RaymanBoolEnv -Name 'RAYMAN_PLAYWRIGHT_REQUIRE' -Default $true
  $playwrightScope = [string][System.Environment]::GetEnvironmentVariable('RAYMAN_PLAYWRIGHT_SETUP_SCOPE')
  if ([string]::IsNullOrWhiteSpace($playwrightScope)) { $playwrightScope = 'all' }
  $playwrightScope = $playwrightScope.Trim().ToLowerInvariant()
  if ($playwrightScope -ne 'all' -and $playwrightScope -ne 'wsl' -and $playwrightScope -ne 'sandbox') { $playwrightScope = 'all' }
  $playwrightSandboxRequired = ($playwrightRequire -and ($playwrightScope -eq 'all' -or $playwrightScope -eq 'sandbox'))
  $playwrightSandboxMarker = Join-Path $StatusDir 'playwright.ready.sandbox.json'
  $autoClose = Get-RaymanAutoCloseSandboxOnReady
  $globalHeartbeatSeconds = Get-RaymanIntEnv -Name 'RAYMAN_HEARTBEAT_SECONDS' -Default 30 -Min 1 -Max 3600
  $sandboxHeartbeatSeconds = Get-RaymanIntEnv -Name 'RAYMAN_SANDBOX_HEARTBEAT_SECONDS' -Default $globalHeartbeatSeconds -Min 1 -Max 3600
  $globalHeartbeatVerbose = Get-RaymanBoolEnv -Name 'RAYMAN_HEARTBEAT_VERBOSE' -Default $true
  $sandboxHeartbeatVerbose = if ([string]::IsNullOrWhiteSpace([string][System.Environment]::GetEnvironmentVariable('RAYMAN_SANDBOX_HEARTBEAT_VERBOSE'))) { $globalHeartbeatVerbose } else { Get-RaymanBoolEnv -Name 'RAYMAN_SANDBOX_HEARTBEAT_VERBOSE' -Default $globalHeartbeatVerbose }
  $globalHeartbeatSmartSilence = Get-RaymanBoolEnv -Name 'RAYMAN_HEARTBEAT_SMART_SILENCE_ENABLED' -Default $true
  $sandboxHeartbeatSmartSilence = if ([string]::IsNullOrWhiteSpace([string][System.Environment]::GetEnvironmentVariable('RAYMAN_SANDBOX_HEARTBEAT_SMART_SILENCE_ENABLED'))) { $globalHeartbeatSmartSilence } else { Get-RaymanBoolEnv -Name 'RAYMAN_SANDBOX_HEARTBEAT_SMART_SILENCE_ENABLED' -Default $globalHeartbeatSmartSilence }
  $globalHeartbeatSilentWindowSeconds = Get-RaymanIntEnv -Name 'RAYMAN_HEARTBEAT_SILENT_WINDOW_SECONDS' -Default ([Math]::Max(1, [Math]::Floor($globalHeartbeatSeconds / 2))) -Min 1 -Max 600
  $sandboxHeartbeatSilentWindowSeconds = Get-RaymanIntEnv -Name 'RAYMAN_SANDBOX_HEARTBEAT_SILENT_WINDOW_SECONDS' -Default $globalHeartbeatSilentWindowSeconds -Min 1 -Max 600
  $readyTimeoutSeconds = Get-RaymanIntEnv -Name 'RAYMAN_SANDBOX_READY_TIMEOUT_SECONDS' -Default 1800 -Min 30 -Max 7200
  $noStatusFailSeconds = Get-RaymanIntEnv -Name 'RAYMAN_SANDBOX_NO_STATUS_FAIL_SECONDS' -Default 45 -Min 10 -Max 1800
  $sandboxStartState = 'not_started'

  Write-Info ("[heartbeat] 全局心跳={0}s；Sandbox 心跳={1}s；verbose={2}；静默降噪={3}（窗口 {4}s）" -f $globalHeartbeatSeconds, $sandboxHeartbeatSeconds, $sandboxHeartbeatVerbose, $sandboxHeartbeatSmartSilence, $sandboxHeartbeatSilentWindowSeconds)

  if ($skipStart -and $playwrightSandboxRequired) {
    throw "RAYMAN_SKIP_SANDBOX_START=1 与 Playwright 强保证冲突：当前要求 sandbox 侧 Playwright 就绪。请移除 skip 设置或将 RAYMAN_PLAYWRIGHT_REQUIRE=0。"
  }

  if (-not $skipStart) {

    $sandboxProcess = Start-RaymanSandbox $WsbPath

    if ($sandboxProcess -and $sandboxProcess.Id) {
      $sandboxStartState = 'started'

      $ok = $false
      try {
        $ok = Wait-RaymanSandboxReady -SandboxPid $sandboxProcess.Id -TimeoutSeconds $readyTimeoutSeconds -HeartbeatSeconds $sandboxHeartbeatSeconds -HeartbeatSmartSilenceEnabled $sandboxHeartbeatSmartSilence -HeartbeatVerboseEnabled $sandboxHeartbeatVerbose -HeartbeatSilentWindowSeconds $sandboxHeartbeatSilentWindowSeconds -NoStatusFailSeconds $noStatusFailSeconds

        if (-not $ok) {
          $sandboxStartState = 'failed'

          throw "Windows Sandbox bootstrap 未就绪（详见日志）。"

        }
        if ($playwrightSandboxRequired) {
          if (-not (Test-Path -LiteralPath $playwrightSandboxMarker -PathType Leaf)) {
            throw ("Sandbox 已 ready，但缺少 Playwright marker：{0}" -f $playwrightSandboxMarker)
          }

          $playwrightMarker = $null
          try {
            $playwrightMarker = Get-Content -LiteralPath $playwrightSandboxMarker -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
          } catch {
            throw ("Sandbox Playwright marker 解析失败：{0}" -f $_.Exception.Message)
          }

          if ($null -eq $playwrightMarker -or $playwrightMarker.success -ne $true) {
            $detail = ''
            if ($playwrightMarker -and $playwrightMarker.PSObject.Properties['detail']) { $detail = [string]$playwrightMarker.detail }
            throw ("Sandbox Playwright 未就绪：{0}" -f $detail)
          }
        }

        $sandboxStartState = 'ready'
      } finally {
        if ($autoClose) {
          $closeReason = if ($ok) { 'ready' } else { '失败/超时' }
          Close-RaymanSandboxProcess -PrimaryPid $sandboxProcess.Id -Reason $closeReason
        } else {
          Write-Info "[sandbox] 已禁用自动关闭（RAYMAN_SANDBOX_AUTO_CLOSE=0）。"
        }
      }

    }
    else {
      $sandboxStartState = 'skipped_or_blocked'
    }

  } else {
    $sandboxStartState = 'skipped_by_env'

    Write-Info "已设置 RAYMAN_SKIP_SANDBOX_START=1，跳过自动启动/等待 Sandbox。"

  }

  if ($script:RaymanSandboxProxyBridge) {
    $script:RaymanKeepSandboxProxyBridge = ($sandboxStartState -eq 'ready' -and -not $autoClose)
    Stop-RaymanSandboxProxyBridge -BridgeInfo $script:RaymanSandboxProxyBridge -KeepRunning:$script:RaymanKeepSandboxProxyBridge
    $script:RaymanSandboxProxyBridge = $null
  }



  

  # Ensure requirements layout (includes legacy migration) before prompt sync.
  try {
    if (Get-Command bash -ErrorAction SilentlyContinue) {
      $probe = Invoke-RaymanBashQuiet -Command "true"
      if ($probe.ExitCode -eq 0) {
        $run = Invoke-RaymanBashQuiet -Command "./.Rayman/scripts/requirements/ensure_requirements.sh"
        if ($run.StdOut -and $run.StdOut.Count -gt 0) {
          $run.StdOut | Out-Host
        }
        if ($run.ExitCode -ne 0) {
          $detail = if ($run.StdErr -and $run.StdErr.Count -gt 0) { $run.StdErr[0] } else { '无详细错误输出' }
          Write-Warn ("[req] ensure_requirements.sh 执行失败（exit={0}）：{1}；已跳过本次 requirements 归并。" -f $run.ExitCode, $detail)
        }
      } else {
        $detail = if ($probe.StdErr -and $probe.StdErr.Count -gt 0) { $probe.StdErr[0] } else { '无详细错误输出' }
        Write-Warn ("[req] bash 不可用（exit={0}）：{1}；已跳过本次 requirements 归并。" -f $probe.ExitCode, $detail)
      }
    } else {
      Write-Warn "[req] 未找到 bash，跳过 requirements 目录修复/迁移。"
    }
  } catch {
    Write-Warn "[req] ensure/migrate failed: $($_.Exception.Message)"
  }

  # Auto-sync prompt -> requirements (idempotent)
  try { & "$PSScriptRoot\scripts\requirements\process_prompts.ps1" | Out-Host } catch { Write-Warn "[prompt] process failed: $($_.Exception.Message)" }

Write-Info "完成：Windows 侧初始化已就绪"

  Write-Info "- Sandbox 配置：$WsbPath"
  Write-Info "- Sandbox 启动状态：$sandboxStartState"

  Write-Info "- Sandbox bootstrap 状态：$StatusFile"
  Write-Info ("- Sandbox 自动关闭：{0}（可设置 RAYMAN_SANDBOX_AUTO_CLOSE=0 关闭）" -f $autoClose)
  Write-Info ("- Sandbox ready 超时：{0} 秒（可设置 RAYMAN_SANDBOX_READY_TIMEOUT_SECONDS）" -f $readyTimeoutSeconds)
  Write-Info ("- Sandbox 无状态失败阈值：{0} 秒（可设置 RAYMAN_SANDBOX_NO_STATUS_FAIL_SECONDS）" -f $noStatusFailSeconds)

  if (Test-Path $LogFile) { Write-Info "- Sandbox bootstrap 日志：$LogFile" }

  Write-Info "WSL2 侧请运行 bash ./.Rayman/init.sh 完成 Linux Playwright 依赖安装"
  Invoke-RaymanDoneAlert -Reason "Rayman 初始化已完成。"



  Stop-Transcript | Out-Null

}

catch [System.Management.Automation.PipelineStoppedException] {

  Write-Warn "检测到 PowerShell 管道被停止（通常是你关闭窗口或按了 Ctrl+C）。Rayman 未必失败；如需跳过 Sandbox 等待可设置环境变量：RAYMAN_SKIP_SANDBOX_START=1。"

  exit 0

}

catch {

  Invoke-RaymanErrorAlert -Reason "Rayman 初始化失败，需要你回来处理。"
  Write-Error $_

  throw

}

finally {

  try {
    if ($script:RaymanSandboxProxyBridge) {
      Stop-RaymanSandboxProxyBridge -BridgeInfo $script:RaymanSandboxProxyBridge -KeepRunning:$script:RaymanKeepSandboxProxyBridge
      if (-not $script:RaymanKeepSandboxProxyBridge) {
        $script:RaymanSandboxProxyBridge = $null
      }
    }
  } catch {}

  try { Stop-Transcript | Out-Null } catch {}

}

# rayman CLI available: .\.Rayman\rayman.cmd doctor|watch|fast-init
