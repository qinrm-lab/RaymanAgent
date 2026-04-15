param(
  [Alias('a')][string]$ApprovalMode = $(if ($env:RAYMAN_APPROVAL_MODE) { $env:RAYMAN_APPROVAL_MODE } else { 'full-auto' })
)

$commonScriptPath = Join-Path $PSScriptRoot 'common.ps1'
if (-not (Test-Path -LiteralPath $commonScriptPath -PathType Leaf)) {
  $workspaceRootForFallback = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
  $setupScriptPath = Join-Path $PSScriptRoot 'setup.ps1'
  Write-Host ("⚠️ [init] 缺少 common.ps1，自动降级到 setup.ps1: {0}" -f $commonScriptPath) -ForegroundColor Yellow

  if (-not (Test-Path -LiteralPath $setupScriptPath -PathType Leaf)) {
    Write-Error ("[init] setup.ps1 也不存在，无法继续: {0}" -f $setupScriptPath)
    exit 2
  }

  & $setupScriptPath -WorkspaceRoot $workspaceRootForFallback
  $fallbackExitCode = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }
  exit $fallbackExitCode
}

. $commonScriptPath

$runtimeCleanupScript = Join-Path $PSScriptRoot 'scripts\utils\runtime_cleanup.ps1'
if (Test-Path -LiteralPath $runtimeCleanupScript -PathType Leaf) {
  . $runtimeCleanupScript -NoMain
}

# --- self-repair --------------------------------------------------------
& "$PSScriptRoot\scripts\repair\ensure_complete_rayman.ps1" -Root (Resolve-Path "$PSScriptRoot\..").Path | Out-Host

$ErrorActionPreference = 'Stop'
$workspaceStateGuardResult = $null
$workspaceStateGuardError = ''
$workspaceStateGuardScript = Join-Path $PSScriptRoot 'scripts\utils\workspace_state_guard.ps1'
$workspaceRootForGuard = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if (Test-Path -LiteralPath $workspaceStateGuardScript -PathType Leaf) {
  try {
    $workspaceStateGuardJson = & $workspaceStateGuardScript -WorkspaceRoot $workspaceRootForGuard -Json
    if (-not [string]::IsNullOrWhiteSpace([string]$workspaceStateGuardJson)) {
      $workspaceStateGuardResult = $workspaceStateGuardJson | ConvertFrom-Json -ErrorAction Stop
    }
  } catch {
    $workspaceStateGuardError = $_.Exception.Message
  }
} else {
  $workspaceStateGuardError = ("missing: {0}" -f $workspaceStateGuardScript)
}

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
if ($null -ne $workspaceStateGuardResult) {
  if ([bool]$workspaceStateGuardResult.scrubbed) {
    Write-Host ("[workspace-state] detected cross-workspace copy; removed={0}; source={1}" -f [int]$workspaceStateGuardResult.removed_count, [string]$workspaceStateGuardResult.foreign_workspace_root) -ForegroundColor Yellow
  } else {
    Write-Host ("[workspace-state] marker refreshed: {0}" -f [string]$workspaceStateGuardResult.marker_path) -ForegroundColor DarkCyan
  }
} elseif (-not [string]::IsNullOrWhiteSpace($workspaceStateGuardError)) {
  Write-Warn ("[workspace-state] pre-init guard failed: {0}" -f $workspaceStateGuardError)
}

if (Get-Command Invoke-RaymanRuntimeCleanup -ErrorAction SilentlyContinue) {
  try {
    $runtimeCleanupReport = Invoke-RaymanRuntimeCleanup -WorkspaceRoot $WorkspaceRoot -Mode 'setup-prune' -KeepDays 14 -WriteSummary
    if ([int]$runtimeCleanupReport.removed_count -gt 0 -or [int]$runtimeCleanupReport.preserved_count -gt 0) {
      Write-Host ("[init] runtime 收敛完成：removed={0}, preserved={1}" -f [int]$runtimeCleanupReport.removed_count, [int]$runtimeCleanupReport.preserved_count) -ForegroundColor DarkCyan
    }
  } catch {
    Write-Warn ("[init] runtime 收敛失败：{0}" -f $_.Exception.Message)
  }
}



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

function Write-RaymanAttentionAutoStartMode() {
  $enabled = Get-RaymanBoolEnv -Name 'RAYMAN_AUTO_START_ATTENTION_WATCH_ENABLED' -Default $false
  if ($enabled) {
    Write-Info '[alert-watch] detached auto-start removed; shared win-watch.ps1 will enable embedded attention scan when background watchers start.'
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

function Resolve-RaymanSystemSlimAuditScript([string]$WorkspaceRoot) {
  $candidates = @(
    (Join-Path $WorkspaceRoot '.Rayman\scripts\agents\system_slim_policy.ps1'),
    (Join-Path $WorkspaceRoot '.Rayman\.dist\scripts\agents\system_slim_policy.ps1')
  ) | Select-Object -Unique

  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }
  return ''
}

function Invoke-RaymanSystemSlimAuditSafe([string]$WorkspaceRoot, [string]$Source = 'init') {
  $auditScript = Resolve-RaymanSystemSlimAuditScript -WorkspaceRoot $WorkspaceRoot
  if ([string]::IsNullOrWhiteSpace($auditScript)) {
    Write-Warn '[Slim] system_slim_policy.ps1 not found; skip system slim audit.'
    return $null
  }

  try {
    . $auditScript
  } catch {
    Write-Warn ("[Slim] load audit script failed: {0}" -f $_.Exception.Message)
    return $null
  }

  $auditCmd = Get-Command Invoke-RaymanSystemSlimAudit -ErrorAction SilentlyContinue
  if ($null -eq $auditCmd) {
    Write-Warn ("[Slim] Invoke-RaymanSystemSlimAudit missing in: {0}" -f $auditScript)
    return $null
  }

  try {
    return (Invoke-RaymanSystemSlimAudit -WorkspaceRoot $WorkspaceRoot -Source $Source)
  } catch {
    Write-Warn ("[Slim] audit failed: {0}" -f $_.Exception.Message)
    return $null
  }
}

function Write-RaymanSystemSlimAuditSummary([object]$AuditResult) {
  if ($null -eq $AuditResult) { return }

  $activeFeatures = @()
  if ($AuditResult.PSObject.Properties['active_features']) {
    $activeFeatures = @($AuditResult.active_features | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  }

  if ($activeFeatures.Count -gt 0) {
    Write-Host ("🧩 [Slim] 当前生效精简: {0}" -f ($activeFeatures -join ', ')) -ForegroundColor Cyan
  } else {
    Write-Host "🧩 [Slim] 当前生效精简: (none)" -ForegroundColor DarkCyan
  }

  if ($AuditResult.PSObject.Properties['report_path'] -and -not [string]::IsNullOrWhiteSpace([string]$AuditResult.report_path)) {
    Write-Host ("🧾 [Slim] 报告: {0}" -f [string]$AuditResult.report_path) -ForegroundColor DarkCyan
  }

  $notifyOnUpgrade = $true
  if ($AuditResult.PSObject.Properties['notify_on_upgrade']) {
    $notifyOnUpgrade = [bool]$AuditResult.notify_on_upgrade
  }

  $upgradeDetected = $false
  if ($AuditResult.PSObject.Properties['upgrade_detected']) {
    $upgradeDetected = [bool]$AuditResult.upgrade_detected
  }

  if ($upgradeDetected -and $notifyOnUpgrade) {
    $upgradedTools = @()
    if ($AuditResult.PSObject.Properties['upgraded_tools']) {
      $upgradedTools = @($AuditResult.upgraded_tools | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $detail = if ($upgradedTools.Count -gt 0) { $upgradedTools -join ', ' } else { 'unknown tools' }
    Write-Host ("⚠️ [Slim] 检测到工具升级({0})，请确认是否继续扩大系统能力精简范围。" -f $detail) -ForegroundColor Yellow
  }
}


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

Write-Info ("Windows Init ({0})" -f $RaymanVersion)
Write-RaymanAttentionAutoStartMode
Install-RaymanVscodeAutoStart -WorkspaceRoot $WorkspaceRoot
$systemSlimAuditResult = Invoke-RaymanSystemSlimAuditSafe -WorkspaceRoot $WorkspaceRoot -Source 'init'
Write-RaymanSystemSlimAuditSummary -AuditResult $systemSlimAuditResult



try {





  & "$PSScriptRoot\win-preflight.ps1"

  & "$PSScriptRoot\win-proxy-check.ps1"



  # --- PWA UI automation sandbox prep -------------------------------------------------

  & "$PSScriptRoot\scripts\pwa\prepare_windows_sandbox.ps1"

  $agentCapabilitiesScript = Join-Path $PSScriptRoot 'scripts\agents\ensure_agent_capabilities.ps1'
  if (Test-Path -LiteralPath $agentCapabilitiesScript -PathType Leaf) {
    try {
      & $agentCapabilitiesScript -Action sync -WorkspaceRoot $WorkspaceRoot | Out-Host
    } catch {
      Write-Warn ("[agent-cap] sync failed: {0}" -f $_.Exception.Message)
    }
  } else {
    Write-Warn ("[agent-cap] missing script: {0}" -f $agentCapabilitiesScript)
  }



  $WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')) | Select-Object -ExpandProperty Path

  $SandboxDir = Join-Path (Join-Path $WorkspaceRoot '.Rayman\runtime') 'windows-sandbox'

  $WsbPath = Join-Path $SandboxDir 'rayman-pwa.wsb'
  $MappingInfoPath = Join-Path $SandboxDir 'mapping.json'

  $StatusDir = Join-Path $SandboxDir 'status'

  $StatusFile = Join-Path $StatusDir 'bootstrap_status.json'

  $LogFile = Join-Path $StatusDir 'bootstrap.log'

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

  function ConvertTo-RaymanStableHash([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'none' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
      $hashBytes = $sha.ComputeHash($bytes)
    } finally {
      $sha.Dispose()
    }
    return ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
  }

  function Get-RaymanSandboxOwnerRegistryPath {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) 'rayman'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    return (Join-Path $dir 'sandbox-owner-registry.json')
  }

  function Get-RaymanSandboxOwnerStatePath([string]$SandboxRoot) {
    return (Join-Path $SandboxRoot 'owner.state.json')
  }

  function Get-RaymanSandboxOwnerContext([string]$WorkspaceRoot) {
    $resolvedWorkspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $workspaceHash = ConvertTo-RaymanStableHash -Value ($resolvedWorkspace.ToLowerInvariant())
    $tokenSource = 'workspace-root'
    $tokenValue = $resolvedWorkspace
    foreach ($name in @('RAYMAN_VSCODE_WINDOW_OWNER', 'VSCODE_IPC_HOOK_CLI', 'VSCODE_IPC_HOOK', 'VSCODE_PID')) {
      $candidate = [string][Environment]::GetEnvironmentVariable($name)
      if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $tokenSource = $name
        $tokenValue = $candidate.Trim()
        break
      }
    }

    $ownerHash = ConvertTo-RaymanStableHash -Value $tokenValue
    $ownerDisplay = if ($tokenSource -eq 'VSCODE_PID') {
      ('{0}#{1}' -f $tokenSource, $tokenValue)
    } elseif ($tokenSource -eq 'workspace-root') {
      ('workspace#{0}' -f $workspaceHash.Substring(0, [Math]::Min(12, $workspaceHash.Length)))
    } else {
      ('{0}#{1}' -f $tokenSource, $ownerHash.Substring(0, [Math]::Min(12, $ownerHash.Length)))
    }

    return [pscustomobject]@{
      WorkspaceRoot = $resolvedWorkspace
      WorkspaceHash = $workspaceHash
      OwnerSource   = $tokenSource
      OwnerToken    = $tokenValue
      OwnerHash     = $ownerHash
      OwnerKey      = ('{0}:{1}:{2}' -f $tokenSource, $ownerHash, $workspaceHash)
      OwnerDisplay  = $ownerDisplay
    }
  }

  function Get-RaymanSandboxOwnerRegistryEntries {
    $path = Get-RaymanSandboxOwnerRegistryPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    try {
      $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
      if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
      $data = @($raw | ConvertFrom-Json -ErrorAction Stop)
      return @($data | Where-Object { $null -ne $_ -and $_.PSObject.Properties['pid'] -and [int]$_.pid -gt 0 })
    } catch {
      Write-Warn ("[sandbox] 读取 owner registry 失败：{0}" -f $_.Exception.Message)
      return @()
    }
  }

  function Save-RaymanSandboxOwnerRegistry([object[]]$Entries) {
    $path = Get-RaymanSandboxOwnerRegistryPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $payload = @($Entries | Where-Object { $null -ne $_ })
    $json = $payload | ConvertTo-Json -Depth 6
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $json, $utf8NoBom)
  }

  function Sync-RaymanSandboxOwnerRegistry {
    $entries = @(Get-RaymanSandboxOwnerRegistryEntries)
    $live = @()
    try {
      $live = @(Get-Process -Name 'WindowsSandbox', 'WindowsSandboxClient' -ErrorAction SilentlyContinue)
    } catch {}
    $livePidSet = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($proc in $live) {
      [void]$livePidSet.Add([int]$proc.Id)
    }

    $filtered = @()
    foreach ($entry in $entries) {
      $pidValue = 0
      try { $pidValue = [int]$entry.pid } catch { $pidValue = 0 }
      if ($pidValue -le 0) { continue }
      if (-not $livePidSet.Contains($pidValue)) { continue }
      $filtered += $entry
    }

    Save-RaymanSandboxOwnerRegistry -Entries $filtered
    return $filtered
  }

  function Register-RaymanSandboxOwner([int]$OwnerPid, [object]$OwnerContext, [string]$WsbPath, [string]$StatePath) {
    if ($OwnerPid -le 0 -or $null -eq $OwnerContext) { return }
    $entries = @(Sync-RaymanSandboxOwnerRegistry)
    $remaining = @($entries | Where-Object { [int]$_.pid -ne $OwnerPid })
    $record = [pscustomobject]@{
      pid           = $OwnerPid
      workspaceRoot = [string]$OwnerContext.WorkspaceRoot
      workspaceHash = [string]$OwnerContext.WorkspaceHash
      ownerSource   = [string]$OwnerContext.OwnerSource
      ownerKey      = [string]$OwnerContext.OwnerKey
      ownerDisplay  = [string]$OwnerContext.OwnerDisplay
      launchedAt    = (Get-Date).ToString('o')
      wsbPath       = $WsbPath
    }
    $remaining += $record
    Save-RaymanSandboxOwnerRegistry -Entries $remaining

    if (-not [string]::IsNullOrWhiteSpace($StatePath)) {
      try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($StatePath, ($record | ConvertTo-Json -Depth 6), $utf8NoBom)
      } catch {
        Write-Warn ("[sandbox] 写入 owner state 失败：{0}" -f $_.Exception.Message)
      }
    }
  }

  function Unregister-RaymanSandboxOwner([int[]]$Pids, [string]$StatePath = '') {
    $pidSet = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($pidValue in @($Pids)) {
      if ([int]$pidValue -gt 0) { [void]$pidSet.Add([int]$pidValue) }
    }
    if ($pidSet.Count -eq 0) { return }

    $entries = @(Sync-RaymanSandboxOwnerRegistry)
    $remaining = @($entries | Where-Object { -not $pidSet.Contains([int]$_.pid) })
    Save-RaymanSandboxOwnerRegistry -Entries $remaining

    if (-not [string]::IsNullOrWhiteSpace($StatePath) -and (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
      try { Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue } catch {}
    }
  }

  function Get-RaymanSandboxExistingSnapshot([object]$OwnerContext) {
    $live = @()
    try { $live = @(Get-Process -Name 'WindowsSandbox', 'WindowsSandboxClient' -ErrorAction SilentlyContinue) } catch {}
    $entries = @(Sync-RaymanSandboxOwnerRegistry)
    $entryMap = @{}
    foreach ($entry in $entries) {
      $entryMap[[int]$entry.pid] = $entry
    }

    $owned = @()
    $foreign = @()
    $unknown = @()

    foreach ($proc in $live) {
      $entry = $null
      if ($entryMap.ContainsKey([int]$proc.Id)) {
        $entry = $entryMap[[int]$proc.Id]
      }

      if ($null -eq $entry) {
        $unknown += $proc
        continue
      }

      if ([string]$entry.ownerKey -eq [string]$OwnerContext.OwnerKey) {
        $owned += $proc
      } else {
        $foreign += $proc
      }
    }

    return [pscustomobject]@{
      LiveProcesses    = @($live)
      OwnedProcesses   = @($owned)
      ForeignProcesses = @($foreign)
      UnknownProcesses = @($unknown)
      Entries          = @($entries)
    }
  }

  function Format-RaymanSandboxProcessList([object[]]$Processes) {
    if ($null -eq $Processes -or $Processes.Count -eq 0) { return '(none)' }
    return (($Processes | ForEach-Object { "$($_.ProcessName)#$($_.Id)" }) -join ', ')
  }

  function Write-RaymanSandboxSnapshot([string]$Stage, [object]$OwnerContext, [object]$Snapshot) {
    if ($null -eq $OwnerContext -or $null -eq $Snapshot) { return }
    Write-Info ("[sandbox] {0}: owner={1} | owned={2} | foreign={3} | unknown={4}" -f $Stage, $OwnerContext.OwnerDisplay, (Format-RaymanSandboxProcessList $Snapshot.OwnedProcesses), (Format-RaymanSandboxProcessList $Snapshot.ForeignProcesses), (Format-RaymanSandboxProcessList $Snapshot.UnknownProcesses))
  }

  $SandboxOwnerContext = Get-RaymanSandboxOwnerContext -WorkspaceRoot $WorkspaceRoot
  $SandboxOwnerStatePath = Get-RaymanSandboxOwnerStatePath -SandboxRoot $SandboxDir



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

    $snapshot = Get-RaymanSandboxExistingSnapshot -OwnerContext $SandboxOwnerContext
    Write-RaymanSandboxSnapshot -Stage 'pre-start' -OwnerContext $SandboxOwnerContext -Snapshot $snapshot
    if ($snapshot.LiveProcesses.Count -gt 0) {
      $killExisting = Get-RaymanBoolEnv -Name 'RAYMAN_SANDBOX_KILL_EXISTING' -Default $false
      if ($snapshot.ForeignProcesses.Count -gt 0 -or $snapshot.UnknownProcesses.Count -gt 0) {
        $foreignText = Format-RaymanSandboxProcessList @($snapshot.ForeignProcesses + $snapshot.UnknownProcesses)
        Write-Warn ("[sandbox] 检测到非当前 VS Code 窗口/工作区 owner 的 Sandbox 实例：{0}。为避免误伤，不会自动关闭；请在对应窗口关闭后重试。当前 owner={1}" -f $foreignText, $SandboxOwnerContext.OwnerDisplay)
        Invoke-RaymanManualAlert -Reason "检测到其他 VS Code 窗口或未知来源的 Sandbox 实例；为避免误伤，本次不会自动关闭。请在对应窗口关闭后重试。"
        return $false
      }

      if ($snapshot.OwnedProcesses.Count -gt 0) {
        $ownedText = Format-RaymanSandboxProcessList $snapshot.OwnedProcesses
        if (-not $killExisting) {
          Write-Warn ("[sandbox] 检测到当前 owner 已有 Sandbox 实例：{0}。默认不主动关闭，已跳过本次启动。可先手工关闭后重试，或设置 RAYMAN_SANDBOX_KILL_EXISTING=1 允许自动关闭本窗口旧实例。" -f $ownedText)
          Invoke-RaymanManualAlert -Reason "检测到当前 VS Code 窗口已有 Sandbox 实例且未自动关闭；请手工关闭后重试，或设置 RAYMAN_SANDBOX_KILL_EXISTING=1。"
          return $false
        }

        Write-Info ("[sandbox] 检测到当前 owner 已有 Sandbox 实例：{0}，已根据 RAYMAN_SANDBOX_KILL_EXISTING=1 自动关闭后再启动。owner={1}" -f $ownedText, $SandboxOwnerContext.OwnerDisplay)
        foreach ($p in $snapshot.LiveProcesses) {
          try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
        }
        Unregister-RaymanSandboxOwner -Pids @($snapshot.LiveProcesses | ForEach-Object { [int]$_.Id }) -StatePath $SandboxOwnerStatePath
        Start-Sleep -Seconds 2
      }
    }

    # Clear previous status to avoid false positives.

    if (Test-Path $StatusFile) { Remove-Item -Force $StatusFile }

    # 设置 Sandbox 离线优先模式环境变量
    # 这些变量会被传递到 Sandbox 内部，用于优化bootstrap过程
    $env:RAYMAN_SANDBOX_SKIP_NETWORK_PREFLIGHT = 'true'
    $env:RAYMAN_SANDBOX_OFFLINE_CACHE_ENABLED = 'true'
    
    Write-Info "启动 Windows Sandbox：$wsbPath"

    $proc = Start-Process -FilePath $exe -ArgumentList @($wsbPath) -PassThru
    Write-Info ("[sandbox] WindowsSandbox PID={0}" -f $proc.Id)
    Register-RaymanSandboxOwner -OwnerPid $proc.Id -OwnerContext $SandboxOwnerContext -WsbPath $wsbPath -StatePath $SandboxOwnerStatePath
    Write-Info ("[sandbox] owner registered: {0}" -f $SandboxOwnerContext.OwnerDisplay)

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
    $snapshot = Get-RaymanSandboxExistingSnapshot -OwnerContext $SandboxOwnerContext
    Write-RaymanSandboxSnapshot -Stage 'pre-close' -OwnerContext $SandboxOwnerContext -Snapshot $snapshot

    if ($PrimaryPid -gt 0) {
      $p = Get-Process -Id $PrimaryPid -ErrorAction SilentlyContinue
      if ($p) { $targets.Add($p) | Out-Null }
    }

    $others = if ($snapshot.ForeignProcesses.Count -eq 0 -and $snapshot.UnknownProcesses.Count -eq 0) { $snapshot.LiveProcesses } else { $snapshot.OwnedProcesses }
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
    Unregister-RaymanSandboxOwner -Pids @($targets | ForEach-Object { [int]$_.Id }) -StatePath $SandboxOwnerStatePath
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

  try { Stop-Transcript | Out-Null } catch {}

}

# rayman CLI available: .\.Rayman\rayman.cmd doctor|watch|fast-init
