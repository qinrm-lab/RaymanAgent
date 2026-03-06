param(
  [ValidateSet('start','stop')][string]$Action = 'start',
  [string]$WorkspaceRoot = $(Resolve-Path (Join-Path $PSScriptRoot "..\..\..") | Select-Object -ExpandProperty Path),
  [switch]$KeepRunning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-EnvBoolValue([string]$Name, [bool]$Default = $false) {
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

function Get-EnvIntValue([string]$Name, [int]$Default, [int]$Min = 1, [int]$Max = 65535) {
  $raw = [System.Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
  $parsed = 0
  if (-not [int]::TryParse($raw.Trim(), [ref]$parsed)) { return $Default }
  if ($parsed -lt $Min) { return $Min }
  if ($parsed -gt $Max) { return $Max }
  return $parsed
}

function Get-ProxyValueByPriority {
  foreach ($name in @('https_proxy', 'HTTPS_PROXY', 'http_proxy', 'HTTP_PROXY', 'all_proxy', 'ALL_PROXY')) {
    $v = [System.Environment]::GetEnvironmentVariable($name)
    if (-not [string]::IsNullOrWhiteSpace([string]$v)) {
      return $v.Trim()
    }
  }
  return $null
}

function Get-ProxyUri([string]$Value) {
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

function Test-LoopbackHost([string]$HostName) {
  if ([string]::IsNullOrWhiteSpace($HostName)) { return $false }
  $h = $HostName.Trim().ToLowerInvariant()
  return ($h -eq '127.0.0.1' -or $h -eq 'localhost' -or $h -eq '::1')
}

function Test-TcpPortAvailable([int]$Port) {
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

function Get-AvailableTcpPort([int]$PreferredPort) {
  if (Test-TcpPortAvailable -Port $PreferredPort) { return $PreferredPort }

  for ($p = 18080; $p -le 18180; $p++) {
    if (Test-TcpPortAvailable -Port $p) { return $p }
  }

  $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, 0)
  try {
    $listener.Start()
    return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
  } finally {
    try { $listener.Stop() } catch {}
  }
}

function Remove-FileBestEffort([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
  try { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue } catch {}
}

function Stop-BridgeProcess([int]$ProcessId) {
  if ($ProcessId -le 0) { return }
  try {
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($p) { Stop-Process -Id $ProcessId -Force -ErrorAction Stop }
  } catch {}
}

function Add-BridgeFirewallRule([string]$RuleName, [int]$Port) {
  if ([string]::IsNullOrWhiteSpace($RuleName)) { return $false }
  if ($Port -lt 1 -or $Port -gt 65535) { return $false }
  try {
    & netsh advfirewall firewall delete rule name="$RuleName" protocol=TCP localport=$Port | Out-Null
  } catch {}
  try {
    $out = (& netsh advfirewall firewall add rule name="$RuleName" dir=in action=allow protocol=TCP localport=$Port profile=any 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0) {
      return $true
    }
  } catch {}
  return $false
}

function Remove-BridgeFirewallRule([string]$RuleName, [int]$Port) {
  if ([string]::IsNullOrWhiteSpace($RuleName)) { return }
  if ($Port -lt 1 -or $Port -gt 65535) { return }
  try {
    & netsh advfirewall firewall delete rule name="$RuleName" protocol=TCP localport=$Port | Out-Null
  } catch {}
}

function Resolve-PowerShellHostPath {
  foreach ($name in @('pwsh', 'powershell')) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
      return [string]$cmd.Source
    }
  }
  return ''
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime'
if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
}

$overrideFile = Join-Path $runtimeDir 'sandbox.proxy.override.json'
$pidFile = Join-Path $runtimeDir 'sandbox_proxy_bridge.pid'
$stateFile = Join-Path $runtimeDir 'sandbox_proxy_bridge.state.json'
$logFile = Join-Path $runtimeDir 'sandbox_proxy_bridge.log'
$result = [ordered]@{
  schema = 'rayman.sandbox.proxy.bridge.v1'
  action = $Action
  success = $true
  started = $false
  stopped = $false
  keep_running = [bool]$KeepRunning
  skipped = $false
  reason = ''
  detail = ''
  workspace_root = $WorkspaceRoot
  proxy = ''
  listen_port = 0
  bridge_pid = 0
  pid_file = $pidFile
  state_file = $stateFile
  log_file = $logFile
  override_file = $overrideFile
  firewall_rule = ''
  firewall_open = $false
  generated_at = (Get-Date).ToString('o')
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
  $result.success = $false
  $result.skipped = $true
  $result.reason = 'host_not_windows'
  $result.detail = 'sandbox proxy bridge is only supported on Windows hosts'
  return [pscustomobject]$result
}

if ($Action -eq 'stop') {
  if ($KeepRunning) {
    $result.skipped = $true
    $result.reason = 'keep_running'
    $result.detail = 'skip stop because KeepRunning=true'
    return [pscustomobject]$result
  }

  $overridePayload = $null
  if (Test-Path -LiteralPath $overrideFile -PathType Leaf) {
    try {
      $overridePayload = Get-Content -LiteralPath $overrideFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {}
  }

  $bridgePid = 0
  if ($overridePayload -and $overridePayload.PSObject.Properties['bridgePid']) {
    $bridgePid = [int]$overridePayload.bridgePid
  }
  if ($bridgePid -le 0 -and (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
    try {
      $rawPid = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction Stop).Trim()
      [void][int]::TryParse($rawPid, [ref]$bridgePid)
    } catch {}
  }

  if ($bridgePid -gt 0) {
    Stop-BridgeProcess -ProcessId $bridgePid
    $result.stopped = $true
    $result.bridge_pid = $bridgePid
  }

  $ruleName = ''
  $rulePort = 0
  $ruleEnabled = $false
  if ($overridePayload) {
    if ($overridePayload.PSObject.Properties['firewallRule']) { $ruleName = [string]$overridePayload.firewallRule }
    if ($overridePayload.PSObject.Properties['firewallOpen']) { $ruleEnabled = [bool]$overridePayload.firewallOpen }
    if ($overridePayload.PSObject.Properties['bridgeListen']) {
      $listenText = [string]$overridePayload.bridgeListen
      if ($listenText -match ':(\d+)$') {
        [void][int]::TryParse($Matches[1], [ref]$rulePort)
      }
    }
  }
  if ($ruleEnabled -and -not [string]::IsNullOrWhiteSpace($ruleName) -and $rulePort -gt 0) {
    Remove-BridgeFirewallRule -RuleName $ruleName -Port $rulePort
  }

  Remove-FileBestEffort -Path $pidFile
  Remove-FileBestEffort -Path $overrideFile
  Remove-FileBestEffort -Path $stateFile

  if (-not $result.stopped) {
    $result.skipped = $true
    $result.reason = 'bridge_not_running'
    $result.detail = 'no running bridge process found'
  }

  return [pscustomobject]$result
}

if (-not (Get-EnvBoolValue -Name 'RAYMAN_SANDBOX_PROXY_BRIDGE_ENABLED' -Default $true)) {
  Remove-FileBestEffort -Path $pidFile
  Remove-FileBestEffort -Path $overrideFile
  Remove-FileBestEffort -Path $stateFile
  $result.skipped = $true
  $result.reason = 'bridge_disabled'
  $result.detail = 'RAYMAN_SANDBOX_PROXY_BRIDGE_ENABLED=0'
  return [pscustomobject]$result
}

$proxyRaw = Get-ProxyValueByPriority
$proxyUri = Get-ProxyUri -Value $proxyRaw
if ($null -eq $proxyUri) {
  Remove-FileBestEffort -Path $pidFile
  Remove-FileBestEffort -Path $overrideFile
  Remove-FileBestEffort -Path $stateFile
  $result.skipped = $true
  $result.reason = 'proxy_not_detected'
  $result.detail = 'no proxy detected from current environment'
  return [pscustomobject]$result
}

if (-not (Test-LoopbackHost -HostName $proxyUri.Host)) {
  Remove-FileBestEffort -Path $pidFile
  Remove-FileBestEffort -Path $overrideFile
  Remove-FileBestEffort -Path $stateFile
  $result.skipped = $true
  $result.reason = 'proxy_not_loopback'
  $result.detail = 'proxy is not loopback; sandbox can use it directly'
  $result.proxy = [string]$proxyRaw
  return [pscustomobject]$result
}

if ($proxyUri.Port -le 0) {
  Remove-FileBestEffort -Path $pidFile
  Remove-FileBestEffort -Path $overrideFile
  Remove-FileBestEffort -Path $stateFile
  $result.skipped = $true
  $result.reason = 'proxy_missing_port'
  $result.detail = 'proxy loopback endpoint has no valid port'
  $result.proxy = [string]$proxyRaw
  return [pscustomobject]$result
}

$scheme = $proxyUri.Scheme.ToLowerInvariant()
if ($scheme -ne 'http' -and $scheme -ne 'https') {
  Remove-FileBestEffort -Path $pidFile
  Remove-FileBestEffort -Path $overrideFile
  Remove-FileBestEffort -Path $stateFile
  $result.skipped = $true
  $result.reason = 'proxy_scheme_unsupported'
  $result.detail = 'only http/https proxy schemes are supported by bridge'
  $result.proxy = [string]$proxyRaw
  return [pscustomobject]$result
}

$existingPid = 0
if (Test-Path -LiteralPath $pidFile -PathType Leaf) {
  try {
    $rawExistingPid = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction Stop).Trim()
    [void][int]::TryParse($rawExistingPid, [ref]$existingPid)
  } catch {}
}
if ($existingPid -gt 0) {
  Stop-BridgeProcess -ProcessId $existingPid
}

$bridgeScript = Join-Path $PSScriptRoot 'run_tcp_bridge.ps1'
if (-not (Test-Path -LiteralPath $bridgeScript -PathType Leaf)) {
  Remove-FileBestEffort -Path $overrideFile
  $result.success = $false
  $result.reason = 'bridge_script_missing'
  $result.detail = "bridge script missing: $bridgeScript"
  return [pscustomobject]$result
}

$defaultPort = $proxyUri.Port + 10000
if ($defaultPort -gt 65535) { $defaultPort = 18988 }
$preferredPort = Get-EnvIntValue -Name 'RAYMAN_SANDBOX_PROXY_BRIDGE_PORT' -Default $defaultPort -Min 1025 -Max 65535
$listenPort = Get-AvailableTcpPort -PreferredPort $preferredPort
if ($listenPort -le 0) {
  Remove-FileBestEffort -Path $overrideFile
  $result.success = $false
  $result.reason = 'bridge_port_allocation_failed'
  $result.detail = 'cannot allocate listen port for sandbox proxy bridge'
  return [pscustomobject]$result
}

$psHost = Resolve-PowerShellHostPath
if ([string]::IsNullOrWhiteSpace($psHost)) {
  Remove-FileBestEffort -Path $overrideFile
  $result.success = $false
  $result.reason = 'powershell_host_missing'
  $result.detail = 'cannot find pwsh/powershell in PATH'
  return [pscustomobject]$result
}

$proc = $null
try {
  $proc = Start-Process -FilePath $psHost -ArgumentList @(
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
  ) -WindowStyle Hidden -PassThru

  Start-Sleep -Milliseconds 700
  $alive = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
  if (-not $alive) {
    Remove-FileBestEffort -Path $overrideFile
    $result.success = $false
    $result.reason = 'bridge_process_exited'
    $result.detail = "bridge process exited immediately; check log: $logFile"
    return [pscustomobject]$result
  }

  $overrideProxy = ("{0}://127.0.0.1:{1}" -f $scheme, $listenPort)

  $firewallRuleName = ''
  $firewallRuleAdded = $false
  if (Get-EnvBoolValue -Name 'RAYMAN_SANDBOX_PROXY_BRIDGE_FIREWALL_RULE_ENABLED' -Default $true) {
    $workspaceLeaf = Split-Path -Path $WorkspaceRoot -Leaf
    if ([string]::IsNullOrWhiteSpace($workspaceLeaf)) { $workspaceLeaf = 'workspace' }
    $firewallRuleName = ("Rayman Sandbox Proxy Bridge {0} {1}" -f $workspaceLeaf, $listenPort)
    $firewallRuleAdded = Add-BridgeFirewallRule -RuleName $firewallRuleName -Port $listenPort
  }

  $overridePayload = [ordered]@{
    proxy        = $overrideProxy
    source       = 'host-loopback-bridge'
    bridgePid    = $proc.Id
    bridgeListen = ('0.0.0.0:{0}' -f $listenPort)
    bridgeTarget = ('{0}:{1}' -f $proxyUri.Host, $proxyUri.Port)
    firewallRule = $firewallRuleName
    firewallOpen = $firewallRuleAdded
    generatedAt  = (Get-Date).ToString('o')
  }
  ($overridePayload | ConvertTo-Json -Depth 6) | Out-File -FilePath $overrideFile -Encoding utf8

  $result.started = $true
  $result.proxy = [string]$proxyRaw
  $result.listen_port = $listenPort
  $result.bridge_pid = $proc.Id
  $result.firewall_rule = $firewallRuleName
  $result.firewall_open = $firewallRuleAdded
  $result.detail = ("bridge started: 0.0.0.0:{0} -> {1}:{2}" -f $listenPort, $proxyUri.Host, $proxyUri.Port)
  return [pscustomobject]$result
} catch {
  if ($proc) {
    try { Stop-BridgeProcess -ProcessId $proc.Id } catch {}
  }
  Remove-FileBestEffort -Path $overrideFile
  $result.success = $false
  $result.reason = 'bridge_start_failed'
  $result.detail = $_.Exception.Message
  return [pscustomobject]$result
}
