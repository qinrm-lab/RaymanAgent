param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [string]$Scope = '',
  [string]$Browser = '',
  [object]$Require = $null,
  [int]$TimeoutSeconds = 0,
  [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info([string]$Message) {
  if ($Json) { return }
  Write-Host ("[playwright-ready] {0}" -f $Message)
}

function Warn([string]$Message) {
  if ($Json) { return }
  Write-Host ("[playwright-ready][warn] {0}" -f $Message) -ForegroundColor Yellow
}

function Read-JsonSafe([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Get-EnvStringOrDefault([string]$Name, [string]$DefaultValue) {
  $raw = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($raw)) { return $DefaultValue }
  return $raw.Trim()
}

function Get-EnvBoolOrDefault([string]$Name, [bool]$DefaultValue) {
  $raw = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($raw)) { return $DefaultValue }
  switch ($raw.Trim().ToLowerInvariant()) {
    '1' { return $true }
    'true' { return $true }
    'yes' { return $true }
    'on' { return $true }
    '0' { return $false }
    'false' { return $false }
    'no' { return $false }
    'off' { return $false }
    default { return $DefaultValue }
  }
}

function Get-EnvIntOrDefault([string]$Name, [int]$DefaultValue, [int]$MinValue, [int]$MaxValue) {
  $raw = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($raw)) { return $DefaultValue }
  $value = 0
  if (-not [int]::TryParse($raw.Trim(), [ref]$value)) { return $DefaultValue }
  if ($value -lt $MinValue) { return $MinValue }
  if ($value -gt $MaxValue) { return $MaxValue }
  return $value
}

function Convert-ToBoolFlexible {
  param(
    [object]$Value,
    [string]$ParameterName = 'value'
  )

  if ($Value -is [bool]) { return [bool]$Value }

  $text = [string]$Value
  if (-not [string]::IsNullOrWhiteSpace($text)) {
    switch ($text.Trim().ToLowerInvariant()) {
      '1' { return $true }
      'true' { return $true }
      'yes' { return $true }
      'on' { return $true }
      '0' { return $false }
      'false' { return $false }
      'no' { return $false }
      'off' { return $false }
    }
  }

  try {
    return [bool][System.Management.Automation.LanguagePrimitives]::ConvertTo($Value, [bool])
  } catch {
    throw ("invalid boolean value for -{0}: {1}" -f $ParameterName, [string]$Value)
  }
}

function Normalize-Scope([string]$Value) {
  $scope = if ([string]::IsNullOrWhiteSpace($Value)) { 'wsl' } else { $Value.Trim().ToLowerInvariant() }
  if ($scope -ne 'all' -and $scope -ne 'wsl' -and $scope -ne 'sandbox' -and $scope -ne 'host') {
    throw ("invalid scope: {0} (expected: all|wsl|sandbox|host)" -f $Value)
  }
  return $scope
}

function Escape-BashSingleQuotes([string]$Value) {
  if ($null -eq $Value) { return '' }
  $replacement = "'" + '"' + "'" + '"' + "'"
  return $Value.Replace("'", $replacement)
}

function Convert-WindowsPathToWsl([string]$Path) {
  $normalized = [string]$Path
  if ($normalized.StartsWith('Microsoft.PowerShell.Core\FileSystem::', [System.StringComparison]::OrdinalIgnoreCase)) {
    $normalized = $normalized.Substring('Microsoft.PowerShell.Core\FileSystem::'.Length)
  }

  try {
    $normalized = [System.IO.Path]::GetFullPath($normalized)
  } catch {}

  if ($normalized -match '^\\\\wsl\.localhost\\[^\\]+\\(?<rest>.*)$') {
    $rest = $matches['rest'] -replace '\\', '/'
    if ([string]::IsNullOrWhiteSpace($rest)) { return '/' }
    if ($rest.StartsWith('/')) { return $rest }
    return "/$rest"
  }

  if ($normalized -match '^(?<drive>[A-Za-z]):\\(?<rest>.*)$') {
    $drive = $matches['drive'].ToLowerInvariant()
    $rest = $matches['rest'] -replace '\\', '/'
    if ([string]::IsNullOrWhiteSpace($rest)) {
      return "/mnt/$drive"
    }
    return "/mnt/$drive/$rest"
  }
  return ($normalized -replace '\\', '/')
}

function Test-HostIsWindows {
  try {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
  } catch {
    return $false
  }
}

function Test-MarkerSuccess([object]$Marker) {
  if ($null -eq $Marker) { return $false }
  $prop = $Marker.PSObject.Properties['success']
  if ($null -eq $prop) { return $false }
  return [bool]$prop.Value
}

function Get-ExceptionTypeName([object]$ErrorRecord) {
  if ($null -eq $ErrorRecord) { return '' }
  try {
    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.GetType()) {
      return [string]$ErrorRecord.Exception.GetType().FullName
    }
  } catch {}
  return ''
}

function Get-ExceptionMessage([object]$ErrorRecord) {
  if ($null -eq $ErrorRecord) { return '' }
  try {
    if ($ErrorRecord.Exception) {
      return [string]$ErrorRecord.Exception.Message
    }
  } catch {}
  return ''
}

function Get-ExceptionScriptStack([object]$ErrorRecord) {
  if ($null -eq $ErrorRecord) { return '' }
  try {
    if (-not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.ScriptStackTrace)) {
      return [string]$ErrorRecord.ScriptStackTrace
    }
  } catch {}
  return ''
}

function Get-LastNativeExitCodeOrDefault([int]$DefaultCode = 0) {
  try {
    $varGlobal = Get-Variable -Name 'LASTEXITCODE' -Scope Global -ErrorAction Stop
    if ($null -ne $varGlobal.Value) {
      return [int]$varGlobal.Value
    }
  } catch {}

  try {
    $varScript = Get-Variable -Name 'LASTEXITCODE' -Scope Script -ErrorAction Stop
    if ($null -ne $varScript.Value) {
      return [int]$varScript.Value
    }
  } catch {}

  return $DefaultCode
}

. (Join-Path $PSScriptRoot 'playwright_ready.lib.ps1')

$script:PlaywrightReadyStage = 'bootstrap'
$WorkspaceRootResolved = ''
$RuntimeDir = ''
$LogsDir = ''
$SandboxStatusDir = ''
$WslMarkerPath = ''
$SandboxMarkerPath = ''
$SummaryPath = ''
$DetailLogPath = ''
$ScopeEffective = ''
$BrowserEffective = ''
$TimeoutEffective = 0
$RequireEffective = $false
$summaryJsonText = ''
$summary = $null
$HostIsWindows = Test-HostIsWindows

function Set-PlaywrightStage([string]$Stage) {
  $script:PlaywrightReadyStage = $Stage
  if ($summary -and $summary.PSObject.Properties['stage']) {
    $summary.stage = $Stage
  }
}

function Write-DetailLog([string]$Message, [object]$ErrorRecord = $null) {
  if ([string]::IsNullOrWhiteSpace($DetailLogPath)) { return }
  try {
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $script:PlaywrightReadyStage, $Message
    Add-Content -LiteralPath $DetailLogPath -Value $line -Encoding UTF8
    if ($null -ne $ErrorRecord) {
      $typeName = Get-ExceptionTypeName -ErrorRecord $ErrorRecord
      $msg = Get-ExceptionMessage -ErrorRecord $ErrorRecord
      $stack = Get-ExceptionScriptStack -ErrorRecord $ErrorRecord
      if (-not [string]::IsNullOrWhiteSpace($typeName)) {
        Add-Content -LiteralPath $DetailLogPath -Value ("  exception_type: {0}" -f $typeName) -Encoding UTF8
      }
      if (-not [string]::IsNullOrWhiteSpace($msg)) {
        Add-Content -LiteralPath $DetailLogPath -Value ("  exception_message: {0}" -f $msg) -Encoding UTF8
      }
      if (-not [string]::IsNullOrWhiteSpace($stack)) {
        Add-Content -LiteralPath $DetailLogPath -Value ("  script_stack: {0}" -f $stack) -Encoding UTF8
      }
    }
  } catch {}
}

function New-SandboxInterventionGuidance(
  [string]$StatusFile,
  [string]$BootstrapLog,
  [string]$DetailLog,
  [string]$MarkerFile
) {
  $steps = @(
    '若你手工关闭了 Sandbox，本次 sandbox 检查会失败；无需等待自动关闭。',
    '默认 setup(scope=wsl) 会先走 WSL，不可用时自动回退 host（本地）；你也可显式设置 RAYMAN_PLAYWRIGHT_SETUP_SCOPE=host 后重跑。',
    '若你要严格验证 sandbox，请设置 RAYMAN_PLAYWRIGHT_SETUP_SCOPE=sandbox，且等待窗口 ready 前不要手动关闭。',
    '若首次使用 Sandbox：请确认“启用或关闭 Windows 功能”中已开启 Windows Sandbox 与虚拟化相关能力。',
    ("查看状态文件: {0}" -f $StatusFile),
    ("查看 Sandbox 日志: {0}" -f $BootstrapLog),
    ("查看主机详细日志: {0}" -f $DetailLog),
    ("查看标记文件: {0}" -f $MarkerFile)
  )
  return ($steps -join ' | ')
}

function Get-SandboxFailureKindFromMessage([string]$Message) {
  if ([string]::IsNullOrWhiteSpace($Message)) { return 'unknown' }
  $msg = $Message.ToLowerInvariant()
  if ($msg.Contains('feature is not enabled') -or $msg.Contains('containers-disposableclientvm') -or $msg.Contains('windowssandbox.exe not found')) {
    return 'feature_not_enabled'
  }
  if ($msg.Contains('exited before bootstrap became ready')) {
    return 'exited_before_ready'
  }
  if ($msg.Contains('bootstrap appears stalled')) {
    return 'bootstrap_stalled'
  }
  if ($msg.Contains('timeout waiting sandbox bootstrap ready')) {
    return 'timeout_no_status'
  }
  return 'unknown'
}

function Get-SandboxActionRequired([string]$FailureKind) {
  switch ($FailureKind) {
    'feature_not_enabled' {
      return '本机未启用 Windows Sandbox；可直接重跑 setup（默认 scope=wsl，并在需要时回退 host），或先设置 RAYMAN_PLAYWRIGHT_SETUP_SCOPE=wsl。'
    }
    'exited_before_ready' {
      return '若你手工关闭了 Sandbox，本次失败是预期现象；无需等待自动关闭，直接重跑 setup（默认 scope=wsl）或设置 RAYMAN_PLAYWRIGHT_SETUP_SCOPE=wsl。'
    }
    'bootstrap_stalled' {
      return 'Sandbox 启动卡住；可先重跑 setup（默认 scope=wsl），或显式设置 RAYMAN_PLAYWRIGHT_SETUP_SCOPE=wsl。'
    }
    'timeout_no_status' {
      return 'Sandbox 未在超时内产生日志状态；无需等待自动关闭，直接重跑 setup（默认 scope=wsl）或显式设置 RAYMAN_PLAYWRIGHT_SETUP_SCOPE=wsl。'
    }
    default {
      return '可先重跑 setup；若当前机器不适合 Sandbox，请设置 RAYMAN_PLAYWRIGHT_SETUP_SCOPE=wsl 或 host。'
    }
  }
}

function Set-SandboxFailureState([string]$FailureKind) {
  if ($null -eq $summary -or $null -eq $summary.sandbox) { return }
  if ([string]::IsNullOrWhiteSpace($FailureKind)) { $FailureKind = 'unknown' }
  $summary.sandbox.failure_kind = $FailureKind
  $summary.sandbox.action_required = Get-SandboxActionRequired -FailureKind $FailureKind
}

function Get-WslActionRequired([string]$FailureKind) {
  switch ($FailureKind) {
    'command_unavailable' {
      return '当前主机缺少可用的 WSL/bash 通道；可先安装/修复 WSL，或直接设置 RAYMAN_PLAYWRIGHT_SETUP_SCOPE=host。'
    }
    'script_missing' {
      return '缺少 ensure_playwright_wsl.sh；请同步完整 .Rayman 脚本，或临时设置 RAYMAN_PLAYWRIGHT_SETUP_SCOPE=host。'
    }
    'marker_missing' {
      return 'WSL 检查未生成成功标记；可重跑 setup，或设置 RAYMAN_PLAYWRIGHT_SETUP_SCOPE=host 先完成初始化。'
    }
    'execution_failed' {
      return 'WSL 检查命令执行失败；请先修复 WSL 环境，或设置 RAYMAN_PLAYWRIGHT_SETUP_SCOPE=host。'
    }
    default {
      return '可重跑 setup；若当前机器不适合 WSL，请设置 RAYMAN_PLAYWRIGHT_SETUP_SCOPE=host。'
    }
  }
}

function Set-WslFailureState([string]$FailureKind) {
  if ($null -eq $summary -or $null -eq $summary.wsl) { return }
  if ([string]::IsNullOrWhiteSpace($FailureKind)) { $FailureKind = 'unknown' }
  $summary.wsl.failure_kind = $FailureKind
  $summary.wsl.action_required = Get-WslActionRequired -FailureKind $FailureKind
}

function Get-HostActionRequired([string]$FailureKind) {
  switch ($FailureKind) {
    'command_unavailable' {
      return '当前主机缺少 npx；请安装 Node.js/npm，或先修复环境后重试。'
    }
    'execution_failed' {
      return 'host 模式安装/检查 Playwright 失败；请检查网络代理与 npm 源配置后重试。'
    }
    default {
      return 'host 模式未就绪；请检查 Node.js/npm 后重试。'
    }
  }
}

function Set-HostFailureState([string]$FailureKind) {
  if ($null -eq $summary -or $null -eq $summary.host) { return }
  if ([string]::IsNullOrWhiteSpace($FailureKind)) { $FailureKind = 'unknown' }
  $summary.host.failure_kind = $FailureKind
  $summary.host.action_required = Get-HostActionRequired -FailureKind $FailureKind
}

function Get-FileTailText([string]$Path, [int]$Lines = 15) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  try {
    $tail = Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction Stop
    if ($null -eq $tail) { return '' }
    return ((@($tail) | ForEach-Object { [string]$_.Trim() }) -join ' || ')
  } catch {
    return ''
  }
}

function Test-WindowsSandboxFeatureEnabled {
  if (-not $HostIsWindows) { return $false }
  $sandboxExe = Join-Path $env:WINDIR 'System32\WindowsSandbox.exe'
  if (-not (Test-Path -LiteralPath $sandboxExe -PathType Leaf)) { return $false }

  # Prefer non-elevated CIM probe to avoid noisy host-level TerminatingError output.
  try {
    $feature = Get-CimInstance -ClassName Win32_OptionalFeature -Filter "Name='Containers-DisposableClientVM'" -ErrorAction SilentlyContinue
    if ($null -ne $feature -and $null -ne $feature.InstallState) {
      return ([int]$feature.InstallState -eq 1)
    }
  } catch {}
  return $false
}

function Get-RecentSandboxEventHints([int]$Minutes = 10, [int]$MaxItems = 3) {
  $start = (Get-Date).AddMinutes(-1 * [Math]::Max(1, $Minutes))
  $items = New-Object System.Collections.Generic.List[string]
  try {
    $events = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $start } -ErrorAction SilentlyContinue |
      Where-Object {
        ($_.ProviderName -like '*Sandbox*') -or
        ($_.ProviderName -like '*Hyper-V*') -or
        ($_.Message -like '*Windows Sandbox*') -or
        ($_.Message -like '*Hyper-V*')
      } |
      Select-Object -First $MaxItems
    foreach ($evt in $events) {
      $msg = [string]$evt.Message
      if ($msg.Length -gt 240) { $msg = $msg.Substring(0, 240) + '...' }
      $items.Add(("[{0}] {1}" -f $evt.ProviderName, $msg.Replace("`r",' ').Replace("`n",' '))) | Out-Null
    }
  } catch {}
  if ($items.Count -eq 0) { return '' }
  return (@($items) -join ' || ')
}

function Get-SandboxHostDiagnostics {
  $enabled = Test-WindowsSandboxFeatureEnabled
  $hypervisor = ''
  try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($null -ne $cs) { $hypervisor = [string]$cs.HypervisorPresent }
  } catch {}
  $events = Get-RecentSandboxEventHints -Minutes 15 -MaxItems 3
  return ("feature_enabled={0}; hypervisor_present={1}; recent_events={2}" -f $enabled, $hypervisor, $events)
}

$failed = $false

try {
  Set-PlaywrightStage 'resolve-workspace'
  try {
    $WorkspaceRootResolved = (Resolve-Path -LiteralPath $WorkspaceRoot -ErrorAction Stop).Path
  } catch {
    try {
      $WorkspaceRootResolved = [System.IO.Path]::GetFullPath($WorkspaceRoot)
    } catch {
      throw ("workspace root is invalid: {0}" -f $WorkspaceRoot)
    }
  }

  $RuntimeDir = Join-Path $WorkspaceRootResolved '.Rayman\runtime'
  $LogsDir = Join-Path $WorkspaceRootResolved '.Rayman\logs'
  $SandboxStatusDir = Join-Path $RuntimeDir 'windows-sandbox\status'
  $WslMarkerPath = Join-Path $RuntimeDir 'playwright.ready.wsl.json'
  $SandboxMarkerPath = Join-Path $SandboxStatusDir 'playwright.ready.sandbox.json'
  $SummaryPath = Join-Path $RuntimeDir 'playwright.ready.windows.json'

  if (-not (Test-Path -LiteralPath $RuntimeDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
  }
  if (-not (Test-Path -LiteralPath $LogsDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
  }

  $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
  $DetailLogPath = Join-Path $LogsDir ("playwright.ready.win.{0}.log" -f $ts)

  $summary = [ordered]@{
    schema = 'rayman.playwright.windows.v2'
    scope = ''
    browser = ''
    require = $false
    timeout_seconds = 0
    workspace_root = $WorkspaceRootResolved
    started_at = (Get-Date).ToString('o')
    finished_at = $null
    success = $false
    error = ''
    error_type = ''
    error_message = ''
    script_stack = ''
    stage = $script:PlaywrightReadyStage
    detail_log = $DetailLogPath
    command_invocation = [string]$MyInvocation.Line
    host_ps_version = [string]$PSVersionTable.PSVersion
    host_is_windows = $HostIsWindows
    wsl = [ordered]@{
      executed = $false
      success = $false
      skipped = $false
      exit_code = $null
      marker = $WslMarkerPath
      detail = ''
      command = ''
      failure_kind = ''
      action_required = ''
    }
    host = [ordered]@{
      executed = $false
      success = $false
      skipped = $false
      exit_code = $null
      detail = ''
      command = ''
      failure_kind = ''
      action_required = ''
    }
    sandbox = [ordered]@{
      executed = $false
      success = $false
      skipped = $false
      exit_code = $null
      status_file = (Join-Path $SandboxStatusDir 'bootstrap_status.json')
      log_file = (Join-Path $SandboxStatusDir 'bootstrap.log')
      marker = $SandboxMarkerPath
      detail = ''
      guidance = ''
      failure_kind = ''
      action_required = ''
      command = ''
    }
    proxy = [ordered]@{
      refresh_attempted = $false
      refresh_success = $false
      source = ''
      snapshot = (Join-Path $RuntimeDir 'proxy.resolved.json')
      bridge = [ordered]@{
        attempted = $false
        started = $false
        skipped = $false
        keep_running = $false
        detail = ''
        listen_port = 0
        pid = 0
        override_file = ''
        state_file = ''
        log_file = ''
      }
    }
    offline_cache = [ordered]@{
      attempted = $false
      success = $false
      manifest = (Join-Path $RuntimeDir 'windows-sandbox\cache\cache_manifest.json')
      detail = ''
      cache_ready = $false
      node_cached = $false
      playwright_pkg_cached = $false
      browser_cached = $false
      reused = $false
    }
  }

  Write-DetailLog ("input workspace={0} scope={1} browser={2} require_bound={3} timeout={4}" -f $WorkspaceRoot, $Scope, $Browser, $PSBoundParameters.ContainsKey('Require'), $TimeoutSeconds)

  Set-PlaywrightStage 'normalize-input'
  if ([string]::IsNullOrWhiteSpace($Scope)) {
    $Scope = Get-EnvStringOrDefault -Name 'RAYMAN_PLAYWRIGHT_SETUP_SCOPE' -DefaultValue 'wsl'
  }
  $ScopeEffective = Normalize-Scope -Value $Scope

  if ([string]::IsNullOrWhiteSpace($Browser)) {
    $Browser = Get-EnvStringOrDefault -Name 'RAYMAN_PLAYWRIGHT_BROWSER' -DefaultValue 'chromium'
  }
  $BrowserEffective = $Browser.Trim().ToLowerInvariant()
  if ($BrowserEffective -ne 'chromium') {
    throw ("unsupported browser: {0} (only chromium is currently supported)" -f $BrowserEffective)
  }

  if ($TimeoutSeconds -le 0) {
    $TimeoutSeconds = Get-EnvIntOrDefault -Name 'RAYMAN_PLAYWRIGHT_TIMEOUT_SECONDS' -DefaultValue 1800 -MinValue 30 -MaxValue 7200
  }
  $TimeoutEffective = $TimeoutSeconds

  if ($PSBoundParameters.ContainsKey('Require')) {
    $RequireEffective = Convert-ToBoolFlexible -Value $Require -ParameterName 'Require'
  } else {
    $RequireEffective = Get-EnvBoolOrDefault -Name 'RAYMAN_PLAYWRIGHT_REQUIRE' -DefaultValue $true
  }

  $summary.scope = $ScopeEffective
  $summary.browser = $BrowserEffective
  $summary.require = $RequireEffective
  $summary.timeout_seconds = $TimeoutEffective

  $shouldCheckWsl = ($ScopeEffective -eq 'all' -or $ScopeEffective -eq 'wsl')
  $shouldCheckHost = ($ScopeEffective -eq 'host')
  $shouldCheckSandbox = ($ScopeEffective -eq 'all' -or $ScopeEffective -eq 'sandbox')

  Info ("scope={0} browser={1} require={2} timeout={3}s" -f $ScopeEffective, $BrowserEffective, $RequireEffective, $TimeoutEffective)
  Write-DetailLog ("normalized scope={0} browser={1} require={2} timeout={3}" -f $ScopeEffective, $BrowserEffective, $RequireEffective, $TimeoutEffective)

  function Invoke-EnsureWslPlaywright {
    $summary.wsl.executed = $true
    $summary.wsl.failure_kind = ''
    $summary.wsl.action_required = ''

    $scriptPath = Join-Path $WorkspaceRootResolved '.Rayman/scripts/pwa/ensure_playwright_wsl.sh'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
      $summary.wsl.detail = "script not found: $scriptPath"
      Set-WslFailureState -FailureKind 'script_missing'
      Write-DetailLog $summary.wsl.detail
      return $false
    }

    $requireInt = if ($RequireEffective) { '1' } else { '0' }
    $exitCode = 1
    if (Test-Path -LiteralPath $WslMarkerPath -PathType Leaf) {
      try {
        Remove-Item -LiteralPath $WslMarkerPath -Force -ErrorAction Stop
        Write-DetailLog ("removed stale wsl marker: {0}" -f $WslMarkerPath)
      } catch {
        Write-DetailLog ("failed to remove stale wsl marker: {0}" -f $_.Exception.Message)
      }
    }

    if ($HostIsWindows -and (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
      $workspaceWsl = Convert-WindowsPathToWsl -Path $WorkspaceRootResolved
      $workspaceWslEscaped = Escape-BashSingleQuotes -Value $workspaceWsl
      $browserEscaped = Escape-BashSingleQuotes -Value $BrowserEffective
      $cmd = "cd '$workspaceWslEscaped' && bash ./.Rayman/scripts/pwa/ensure_playwright_wsl.sh --browser '$browserEscaped' --require $requireInt"
      $summary.wsl.command = ('wsl.exe -e bash -lc "{0}"' -f $cmd)
      Set-PlaywrightStage 'wsl-ensure'
      Info 'running WSL playwright ensure via wsl.exe'
      Write-DetailLog ("run: {0}" -f $summary.wsl.command)
      & wsl.exe -e bash -lc $cmd
      $nativeSucceeded = $?
      $defaultCode = if ($nativeSucceeded) { 0 } else { 1 }
      $exitCode = Get-LastNativeExitCodeOrDefault -DefaultCode $defaultCode
    } elseif (Get-Command bash -ErrorAction SilentlyContinue) {
      $summary.wsl.command = "bash ./.Rayman/scripts/pwa/ensure_playwright_wsl.sh --browser $BrowserEffective --require $requireInt"
      Set-PlaywrightStage 'wsl-ensure'
      Info 'running Linux playwright ensure via local bash'
      Write-DetailLog ("run: {0}" -f $summary.wsl.command)
      Push-Location $WorkspaceRootResolved
      try {
        & bash ./.Rayman/scripts/pwa/ensure_playwright_wsl.sh --browser $BrowserEffective --require $requireInt
        $nativeSucceeded = $?
        $defaultCode = if ($nativeSucceeded) { 0 } else { 1 }
        $exitCode = Get-LastNativeExitCodeOrDefault -DefaultCode $defaultCode
      } finally {
        Pop-Location
      }
    } else {
      $summary.wsl.detail = 'neither wsl.exe nor bash is available'
      Set-WslFailureState -FailureKind 'command_unavailable'
      Write-DetailLog $summary.wsl.detail
      return $false
    }

    $summary.wsl.exit_code = $exitCode
    Write-DetailLog ("wsl ensure exit={0}" -f $exitCode)

    $marker = $null
    $markerWaitSeconds = [Math]::Max(5, [Math]::Min($TimeoutEffective, 300))
    $markerDeadline = (Get-Date).AddSeconds($markerWaitSeconds)
    while ((Get-Date) -lt $markerDeadline) {
      $marker = Read-JsonSafe -Path $WslMarkerPath
      if ($null -ne $marker) { break }
      Start-Sleep -Milliseconds 500
    }
    if ($null -eq $marker) {
      $marker = Read-JsonSafe -Path $WslMarkerPath
    }
    $markerOk = Test-MarkerSuccess -Marker $marker

    if ($exitCode -eq 0 -and $markerOk) {
      $summary.wsl.success = $true
      $summary.wsl.failure_kind = ''
      $summary.wsl.action_required = ''
      $summary.wsl.detail = 'playwright wsl ready'
      return $true
    }

    if ($null -eq $marker) {
      $summary.wsl.detail = "ensure script exit=$exitCode, marker missing (waited ${markerWaitSeconds}s)"
      Set-WslFailureState -FailureKind 'marker_missing'
    } else {
      $summary.wsl.detail = "ensure script exit=$exitCode, marker success=$([string](Test-MarkerSuccess -Marker $marker))"
      Set-WslFailureState -FailureKind 'execution_failed'
    }

    Write-DetailLog $summary.wsl.detail
    return $false
  }

  function Invoke-EnsureHostPlaywright {
    $summary.host.executed = $true
    $summary.host.failure_kind = ''
    $summary.host.action_required = ''

    $npxCmd = $null
    if ($HostIsWindows) {
      $npxCmd = Get-Command 'npx.cmd' -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($null -eq $npxCmd) {
      $npxCmd = Get-Command 'npx' -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if ($null -eq $npxCmd -or [string]::IsNullOrWhiteSpace([string]$npxCmd.Source)) {
      $summary.host.detail = 'npx command is not available'
      Set-HostFailureState -FailureKind 'command_unavailable'
      Write-DetailLog $summary.host.detail
      return $false
    }

    $summary.host.command = ("{0} -y playwright install {1}" -f [string]$npxCmd.Source, $BrowserEffective)
    Set-PlaywrightStage 'host-ensure'
    Info ("running host playwright ensure via {0}" -f [string]$npxCmd.Source)
    Write-DetailLog ("run: {0}" -f $summary.host.command)

    Push-Location $WorkspaceRootResolved
    try {
      & $npxCmd.Source -y playwright install $BrowserEffective
      $nativeSucceeded = $?
      $defaultCode = if ($nativeSucceeded) { 0 } else { 1 }
      $exitCode = Get-LastNativeExitCodeOrDefault -DefaultCode $defaultCode
      $summary.host.exit_code = $exitCode
      Write-DetailLog ("host ensure exit={0}" -f $exitCode)

      if ($exitCode -eq 0) {
        $summary.host.success = $true
        $summary.host.failure_kind = ''
        $summary.host.action_required = ''
        $summary.host.detail = 'playwright host ready'
        return $true
      }

      $summary.host.detail = "host playwright install exit=$exitCode"
      Set-HostFailureState -FailureKind 'execution_failed'
      Write-DetailLog $summary.host.detail
      return $false
    } finally {
      Pop-Location
    }
  }

  function Invoke-EnsureSandboxPlaywright {
    $summary.sandbox.executed = $true
    $summary.sandbox.failure_kind = ''
    $summary.sandbox.action_required = ''

    if (-not $HostIsWindows) {
      $summary.sandbox.detail = 'sandbox ensure requires Windows host'
      Set-SandboxFailureState -FailureKind 'unknown'
      Write-DetailLog $summary.sandbox.detail
      return $false
    }

    if (-not (Test-WindowsSandboxFeatureEnabled)) {
      $summary.sandbox.detail = 'Windows Sandbox feature is not enabled (Containers-DisposableClientVM).'
      Set-SandboxFailureState -FailureKind 'feature_not_enabled'
      Write-DetailLog $summary.sandbox.detail
      return $false
    }

    if ([string](Get-EnvStringOrDefault -Name 'RAYMAN_SKIP_SANDBOX_START' -DefaultValue '0') -eq '1') {
      $summary.sandbox.skipped = $true
      $summary.sandbox.detail = 'RAYMAN_SKIP_SANDBOX_START=1'
      Set-SandboxFailureState -FailureKind 'unknown'
      Write-DetailLog $summary.sandbox.detail
      return $false
    }

    $prepareScript = Join-Path $WorkspaceRootResolved '.Rayman\scripts\pwa\prepare_windows_sandbox.ps1'
    $proxyDetectScript = Join-Path $WorkspaceRootResolved '.Rayman\scripts\proxy\detect_win_proxy.ps1'
    $bridgeScript = Join-Path $WorkspaceRootResolved '.Rayman\scripts\proxy\sandbox_proxy_bridge.ps1'
    $cachePrepareScript = Join-Path $WorkspaceRootResolved '.Rayman\scripts\pwa\prepare_windows_sandbox_cache.ps1'
    if (-not (Test-Path -LiteralPath $prepareScript -PathType Leaf)) {
      $summary.sandbox.detail = "script not found: $prepareScript"
      Set-SandboxFailureState -FailureKind 'unknown'
      Write-DetailLog $summary.sandbox.detail
      return $false
    }

    $sandboxExe = Join-Path $env:WINDIR 'System32\WindowsSandbox.exe'
    if (-not (Test-Path -LiteralPath $sandboxExe -PathType Leaf)) {
      $summary.sandbox.detail = "WindowsSandbox.exe not found: $sandboxExe"
      Set-SandboxFailureState -FailureKind 'feature_not_enabled'
      Write-DetailLog $summary.sandbox.detail
      return $false
    }

    $sandboxDir = Join-Path $RuntimeDir 'windows-sandbox'
    if (-not (Test-Path -LiteralPath $sandboxDir -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $sandboxDir | Out-Null
    }
    if (-not (Test-Path -LiteralPath $SandboxStatusDir -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $SandboxStatusDir | Out-Null
    }

    $statusFile = [string]$summary.sandbox.status_file
    $bootstrapLogFile = [string]$summary.sandbox.log_file
    $wsbPath = Join-Path $sandboxDir 'rayman-pwa.wsb'
    $proxySnapshotPath = [string]$summary.proxy.snapshot

    Remove-Item -LiteralPath $statusFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $bootstrapLogFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $SandboxMarkerPath -Force -ErrorAction SilentlyContinue

    if (Test-Path -LiteralPath $proxyDetectScript -PathType Leaf) {
      $summary.proxy.refresh_attempted = $true
      try {
        Set-PlaywrightStage 'sandbox-proxy-refresh'
        Write-DetailLog ("run: {0} -WorkspaceRoot {1}" -f $proxyDetectScript, $WorkspaceRootResolved)
        & $proxyDetectScript -WorkspaceRoot $WorkspaceRootResolved | Out-Null
        $summary.proxy.refresh_success = $true
      } catch {
        $summary.proxy.refresh_success = $false
        $summary.proxy.source = 'refresh-failed'
        Write-DetailLog ("proxy refresh failed: {0}" -f $_.Exception.Message) $_
      }
    } else {
      $summary.proxy.refresh_attempted = $false
      $summary.proxy.refresh_success = $false
      Write-DetailLog ("proxy detect script not found: {0}" -f $proxyDetectScript)
    }

    $proxySnapshot = Read-JsonSafe -Path $proxySnapshotPath
    if ($proxySnapshot -and $proxySnapshot.PSObject.Properties['source']) {
      $summary.proxy.source = [string]$proxySnapshot.source
    }

    $bridgeStarted = $false
    if (Test-Path -LiteralPath $bridgeScript -PathType Leaf) {
      $summary.proxy.bridge.attempted = $true
      try {
        Set-PlaywrightStage 'sandbox-proxy-bridge-start'
        Write-DetailLog ("run: {0} -Action start -WorkspaceRoot {1}" -f $bridgeScript, $WorkspaceRootResolved)
        $bridgeResult = & $bridgeScript -Action start -WorkspaceRoot $WorkspaceRootResolved
        if ($bridgeResult) {
          $summary.proxy.bridge.started = [bool]$bridgeResult.started
          $summary.proxy.bridge.skipped = [bool]$bridgeResult.skipped
          $summary.proxy.bridge.detail = [string]$bridgeResult.detail
          $summary.proxy.bridge.listen_port = [int]$bridgeResult.listen_port
          $summary.proxy.bridge.pid = [int]$bridgeResult.bridge_pid
          $summary.proxy.bridge.override_file = [string]$bridgeResult.override_file
          $summary.proxy.bridge.state_file = [string]$bridgeResult.state_file
          $summary.proxy.bridge.log_file = [string]$bridgeResult.log_file
          $bridgeStarted = [bool]$bridgeResult.started
          Write-DetailLog ("sandbox proxy bridge start: started={0} skipped={1} detail={2}" -f $summary.proxy.bridge.started, $summary.proxy.bridge.skipped, $summary.proxy.bridge.detail)
        } else {
          $summary.proxy.bridge.detail = 'bridge script returned empty result'
          Write-DetailLog $summary.proxy.bridge.detail
        }
      } catch {
        $summary.proxy.bridge.started = $false
        $summary.proxy.bridge.skipped = $false
        $summary.proxy.bridge.detail = $_.Exception.Message
        Write-DetailLog ("sandbox proxy bridge start failed: {0}" -f $summary.proxy.bridge.detail) $_
      }
    } else {
      $summary.proxy.bridge.detail = ("bridge script not found: {0}" -f $bridgeScript)
      Write-DetailLog $summary.proxy.bridge.detail
    }

    if (Test-Path -LiteralPath $cachePrepareScript -PathType Leaf) {
      $summary.offline_cache.attempted = $true
      try {
        Set-PlaywrightStage 'sandbox-cache-prepare'
        Write-DetailLog ("run: {0} -WorkspaceRoot {1} -Browser {2}" -f $cachePrepareScript, $WorkspaceRootResolved, $BrowserEffective)
        $cacheResult = & $cachePrepareScript -WorkspaceRoot $WorkspaceRootResolved -Browser $BrowserEffective
        if ($cacheResult) {
          $summary.offline_cache.success = [bool]$cacheResult.success
          $summary.offline_cache.manifest = [string]$cacheResult.manifest
          $summary.offline_cache.detail = [string]$cacheResult.detail
          $summary.offline_cache.cache_ready = [bool]$cacheResult.ready_for_offline_playwright
          $summary.offline_cache.reused = [bool]$cacheResult.reused
          if ($cacheResult.PSObject.Properties['completeness']) {
            $summary.offline_cache.node_cached = [bool]$cacheResult.completeness.node
            $summary.offline_cache.playwright_pkg_cached = [bool]$cacheResult.completeness.playwright_packages
            $summary.offline_cache.browser_cached = [bool]$cacheResult.completeness.browser_cache
          }
          Write-DetailLog ("offline cache prepare: success={0} ready={1} reused={2}" -f $summary.offline_cache.success, $summary.offline_cache.cache_ready, $summary.offline_cache.reused)
        } else {
          $summary.offline_cache.success = $false
          $summary.offline_cache.detail = 'cache script returned empty result'
          Write-DetailLog $summary.offline_cache.detail
        }
      } catch {
        $summary.offline_cache.success = $false
        $summary.offline_cache.detail = $_.Exception.Message
        Write-DetailLog ("offline cache prepare failed: {0}" -f $summary.offline_cache.detail) $_
      }
    } else {
      $summary.offline_cache.attempted = $false
      $summary.offline_cache.success = $false
      $summary.offline_cache.detail = ("cache script not found: {0}" -f $cachePrepareScript)
      Write-DetailLog $summary.offline_cache.detail
    }

    Set-PlaywrightStage 'sandbox-prepare'
    Info 'preparing Windows Sandbox mapping for Playwright bootstrap'
    Write-DetailLog ("run: {0} -WorkspaceRoot {1}" -f $prepareScript, $WorkspaceRootResolved)
    & $prepareScript -WorkspaceRoot $WorkspaceRootResolved

    if (-not (Test-Path -LiteralPath $wsbPath -PathType Leaf)) {
      $summary.sandbox.detail = "wsb not found: $wsbPath"
      Set-SandboxFailureState -FailureKind 'unknown'
      Write-DetailLog $summary.sandbox.detail
      return $false
    }

    $summary.sandbox.command = "`"$sandboxExe`" `"$wsbPath`""

    $sandboxProc = $null
    $readyObserved = $false
    $startGraceSeconds = Get-EnvIntOrDefault -Name 'RAYMAN_SANDBOX_BOOTSTRAP_START_GRACE_SECONDS' -DefaultValue 90 -MinValue 15 -MaxValue 900
    $stallSeconds = Get-EnvIntOrDefault -Name 'RAYMAN_SANDBOX_BOOTSTRAP_STALL_SECONDS' -DefaultValue 300 -MinValue 30 -MaxValue 1800
    try {
      Set-PlaywrightStage 'sandbox-start'
      Info ("starting Windows Sandbox: {0}" -f $wsbPath)
      Write-DetailLog ("run: {0}" -f $summary.sandbox.command)
      $sandboxProc = Start-Process -FilePath $sandboxExe -ArgumentList @($wsbPath) -PassThru
      $summary.sandbox.exit_code = 0

      $deadline = (Get-Date).AddSeconds($TimeoutEffective)
      $waitStartedAt = Get-Date
      $statusObserved = $false
      $graceWarned = $false
      $lastProgressAt = Get-Date
      $lastPhase = ''
      $lastMessage = ''
      $lastError = ''
      Set-PlaywrightStage 'sandbox-wait-ready'
      while ((Get-Date) -lt $deadline) {
        $payload = Read-JsonSafe -Path $statusFile
        if ($null -ne $payload) {
          $statusObserved = $true
          $phase = [string]$payload.phase
          $message = [string]$payload.message
          $payloadErr = [string]$payload.error
          $ok = $false
          if ($payload.PSObject.Properties['success']) {
            $ok = [bool]$payload.success
          }

          if ($phase -ne $lastPhase -or $message -ne $lastMessage -or $payloadErr -ne $lastError) {
            $lastProgressAt = Get-Date
            $lastPhase = $phase
            $lastMessage = $message
            $lastError = $payloadErr
            Write-DetailLog ("sandbox progress: phase={0}; message={1}; error={2}" -f $phase, $message, $payloadErr)
          }

          if ($ok -and $phase -eq 'ready') {
            $readyObserved = $true
            break
          }

          if ($phase -like 'failed*' -or (-not $ok -and $phase -eq 'failed')) {
            $err = [string]$payload.error
            if ([string]::IsNullOrWhiteSpace($err)) { $err = [string]$payload.message }
            if ([string]::IsNullOrWhiteSpace($err)) {
              $err = 'bootstrap status returned failed phase without detailed error'
            }
            throw ("sandbox bootstrap failed: phase={0}; error={1}" -f $phase, $err)
          }
        }

        $running = Get-Process -Id $sandboxProc.Id -ErrorAction SilentlyContinue
        if (-not $running) {
          $statusSnapshot = Read-JsonSafe -Path $statusFile
          $bootstrapTail = Get-FileTailText -Path $bootstrapLogFile -Lines 20
          $hostDiag = Get-SandboxHostDiagnostics
          if ($null -ne $statusSnapshot) {
            $phaseSnap = [string]$statusSnapshot.phase
            $msgSnap = [string]$statusSnapshot.message
            $errSnap = [string]$statusSnapshot.error
            throw ("Windows Sandbox exited before bootstrap became ready (phase={0}; message={1}; error={2}; log_tail={3}; host_diag={4})" -f $phaseSnap, $msgSnap, $errSnap, $bootstrapTail, $hostDiag)
          }
          throw ("Windows Sandbox exited before bootstrap became ready (status file not available; log_tail={0}; host_diag={1})" -f $bootstrapTail, $hostDiag)
        }

        if (-not $statusObserved) {
          $statusAgeSeconds = (New-TimeSpan -Start $waitStartedAt -End (Get-Date)).TotalSeconds
          if ($statusAgeSeconds -ge $startGraceSeconds -and -not $graceWarned) {
            $graceWarned = $true
            $bootstrapTail = Get-FileTailText -Path $bootstrapLogFile -Lines 20
            Write-DetailLog ("sandbox bootstrap status still missing after grace period (grace_seconds={0}; status_file={1}; log_tail={2}); continue waiting until timeout" -f $startGraceSeconds, $statusFile, $bootstrapTail)
          }
        } else {
          $stallAgeSeconds = (New-TimeSpan -Start $lastProgressAt -End (Get-Date)).TotalSeconds
          if ($stallAgeSeconds -ge $stallSeconds) {
            $bootstrapTail = Get-FileTailText -Path $bootstrapLogFile -Lines 20
            throw ("sandbox bootstrap appears stalled (stall_seconds={0}; phase={1}; message={2}; error={3}; log_tail={4})" -f [int]$stallAgeSeconds, $lastPhase, $lastMessage, $lastError, $bootstrapTail)
          }
        }

        Start-Sleep -Seconds 3
      }

      if (-not $readyObserved) {
        $bootstrapTail = Get-FileTailText -Path $bootstrapLogFile -Lines 20
        if (-not $statusObserved) {
          throw ("timeout waiting sandbox bootstrap ready (timeout_seconds={0}; status_file_never_created={1}; probable_causes=Sandbox logon command not executed or startup too slow; log_tail={2})" -f $TimeoutEffective, $statusFile, $bootstrapTail)
        }
        throw ("timeout waiting sandbox bootstrap ready (timeout_seconds={0}; last_phase={1}; last_message={2}; last_error={3}; log_tail={4})" -f $TimeoutEffective, $lastPhase, $lastMessage, $lastError, $bootstrapTail)
      }

      Set-PlaywrightStage 'sandbox-wait-marker'
      $markerReady = $false
      for ($i = 0; $i -lt 5; $i++) {
        $marker = Read-JsonSafe -Path $SandboxMarkerPath
        if ($null -ne $marker -and (Test-MarkerSuccess -Marker $marker)) {
          $markerReady = $true
          break
        }
        Start-Sleep -Seconds 2
      }

      if (-not $markerReady) {
        throw ("sandbox marker missing or not successful: {0}" -f $SandboxMarkerPath)
      }

      $summary.sandbox.success = $true
      $summary.sandbox.failure_kind = ''
      $summary.sandbox.action_required = ''
      $summary.sandbox.detail = 'playwright sandbox ready'
      return $true
    } catch {
      $failureKind = Get-SandboxFailureKindFromMessage -Message $_.Exception.Message
      Set-SandboxFailureState -FailureKind $failureKind
      $summary.sandbox.guidance = New-SandboxInterventionGuidance -StatusFile $statusFile -BootstrapLog $bootstrapLogFile -DetailLog $DetailLogPath -MarkerFile $SandboxMarkerPath
      $summary.sandbox.detail = ("{0} | guidance={1}" -f $_.Exception.Message, $summary.sandbox.guidance)
      Write-DetailLog $summary.sandbox.detail $_
      return $false
    } finally {
      $autoClose = Get-EnvBoolOrDefault -Name 'RAYMAN_SANDBOX_AUTO_CLOSE' -DefaultValue $true
      if ($null -ne $sandboxProc -and $autoClose) {
        $p = Get-Process -Id $sandboxProc.Id -ErrorAction SilentlyContinue
        if ($null -ne $p) {
          try { Stop-Process -Id $sandboxProc.Id -Force -ErrorAction SilentlyContinue } catch {}
        }
      }

      if (Test-Path -LiteralPath $bridgeScript -PathType Leaf) {
        try {
          $keepRunning = (-not $autoClose)
          $stopBridgeResult = & $bridgeScript -Action stop -WorkspaceRoot $WorkspaceRootResolved -KeepRunning:$keepRunning
          $summary.proxy.bridge.keep_running = $keepRunning
          if ($null -ne $stopBridgeResult -and $stopBridgeResult.PSObject.Properties['detail']) {
            if ($bridgeStarted -or -not [string]::IsNullOrWhiteSpace([string]$stopBridgeResult.detail)) {
              Write-DetailLog ("sandbox proxy bridge stop: {0}" -f [string]$stopBridgeResult.detail)
            }
          }
        } catch {
          Write-DetailLog ("sandbox proxy bridge stop failed: {0}" -f $_.Exception.Message) $_
        }
      }
    }
  }

  Set-PlaywrightStage 'run-checks'
  if ($shouldCheckWsl) {
    $okWsl = Invoke-EnsureWslPlaywright
    if (-not $okWsl) {
      $failed = $true
      Warn ("WSL playwright ensure failed: {0}" -f [string]$summary.wsl.detail)
    }
  }

  if ($shouldCheckHost) {
    $okHost = Invoke-EnsureHostPlaywright
    if (-not $okHost) {
      $failed = $true
      Warn ("Host playwright ensure failed: {0}" -f [string]$summary.host.detail)
    }
  }

  if ($shouldCheckSandbox) {
    $okSandbox = Invoke-EnsureSandboxPlaywright
    if (-not $okSandbox) {
      $failed = $true
      Warn ("Sandbox playwright ensure failed: {0}" -f [string]$summary.sandbox.detail)
    }
  }

  if ($RequireEffective -and $failed) {
    throw 'playwright readiness is required but one or more targets failed'
  }
} catch {
  $failed = $true
  if ($summary -eq $null) {
    $summary = [ordered]@{
      schema = 'rayman.playwright.windows.v2'
      scope = ''
      browser = ''
      require = $false
      timeout_seconds = 0
      workspace_root = $WorkspaceRoot
      started_at = (Get-Date).ToString('o')
      finished_at = $null
      success = $false
      error = ''
      error_type = ''
      error_message = ''
      script_stack = ''
      stage = $script:PlaywrightReadyStage
      detail_log = $DetailLogPath
      command_invocation = [string]$MyInvocation.Line
      host_ps_version = [string]$PSVersionTable.PSVersion
      host_is_windows = $HostIsWindows
      wsl = [ordered]@{ executed = $false; success = $false; skipped = $false; exit_code = $null; marker = ''; detail = ''; command = ''; failure_kind = ''; action_required = '' }
      host = [ordered]@{ executed = $false; success = $false; skipped = $false; exit_code = $null; detail = ''; command = ''; failure_kind = ''; action_required = '' }
      sandbox = [ordered]@{ executed = $false; success = $false; skipped = $false; exit_code = $null; status_file = ''; log_file = ''; marker = ''; detail = ''; guidance = ''; failure_kind = ''; action_required = ''; command = '' }
      proxy = [ordered]@{
        refresh_attempted = $false
        refresh_success = $false
        source = ''
        snapshot = ''
        bridge = [ordered]@{ attempted = $false; started = $false; skipped = $false; keep_running = $false; detail = ''; listen_port = 0; pid = 0; override_file = ''; state_file = ''; log_file = '' }
      }
      offline_cache = [ordered]@{
        attempted = $false
        success = $false
        manifest = ''
        detail = ''
        cache_ready = $false
        node_cached = $false
        playwright_pkg_cached = $false
        browser_cached = $false
        reused = $false
      }
    }
  }

  $summary.error = $_.Exception.Message
  $summary.error_type = Get-ExceptionTypeName -ErrorRecord $_
  $summary.error_message = Get-ExceptionMessage -ErrorRecord $_
  $summary.script_stack = Get-ExceptionScriptStack -ErrorRecord $_
  $summary.stage = $script:PlaywrightReadyStage
  Write-DetailLog ("fatal: {0}" -f $summary.error_message) $_
} finally {
  if ($summary -ne $null) {
    $summary.scope = if ([string]::IsNullOrWhiteSpace($ScopeEffective)) { $summary.scope } else { $ScopeEffective }
    $summary.browser = if ([string]::IsNullOrWhiteSpace($BrowserEffective)) { $summary.browser } else { $BrowserEffective }
    if ($TimeoutEffective -gt 0) { $summary.timeout_seconds = $TimeoutEffective }
    $summary.require = $RequireEffective
    $summary.success = (-not $failed)
    $scopeConsistency = if ([string]::IsNullOrWhiteSpace($ScopeEffective)) { [string]$summary.scope } else { $ScopeEffective }
    if (($scopeConsistency -eq 'all' -or $scopeConsistency -eq 'sandbox') -and [bool]$summary.sandbox.executed -and -not [bool]$summary.sandbox.success) {
      $summary.success = $false
    }
    if (($scopeConsistency -eq 'all' -or $scopeConsistency -eq 'wsl') -and [bool]$summary.wsl.executed -and -not [bool]$summary.wsl.success) {
      $summary.success = $false
    }
    if ($scopeConsistency -eq 'host' -and [bool]$summary.host.executed -and -not [bool]$summary.host.success) {
      $summary.success = $false
    }
    $summary.finished_at = (Get-Date).ToString('o')
    $summary.stage = $script:PlaywrightReadyStage
    $summary.detail_log = $DetailLogPath

    if (-not [string]::IsNullOrWhiteSpace($SummaryPath)) {
      try {
        $summaryJsonText = ($summary | ConvertTo-Json -Depth 10)
        $summaryJsonText | Set-Content -LiteralPath $SummaryPath -Encoding UTF8
        Info ("summary: {0}" -f $SummaryPath)
      } catch {
        Warn ("failed to write summary: {0}" -f $_.Exception.Message)
      }
    } elseif ($null -ne $summary) {
      $summaryJsonText = ($summary | ConvertTo-Json -Depth 10)
    }

    if ($failed -and -not [string]::IsNullOrWhiteSpace($DetailLogPath)) {
      Info ("detail log: {0}" -f $DetailLogPath)
    }
  }
}

if ($Json -and -not [string]::IsNullOrWhiteSpace($summaryJsonText)) {
  Write-Output $summaryJsonText
}

if ($RequireEffective -and (-not [bool]$summary.success)) {
  exit 2
}

exit 0
