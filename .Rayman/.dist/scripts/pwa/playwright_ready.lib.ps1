Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonSafe {
  param(
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Get-EnvStringOrDefault {
  param(
    [string]$Name,
    [string]$DefaultValue
  )

  $raw = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($raw)) { return $DefaultValue }
  return $raw.Trim()
}

function Get-EnvBoolOrDefault {
  param(
    [string]$Name,
    [bool]$DefaultValue
  )

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

function Get-EnvIntOrDefault {
  param(
    [string]$Name,
    [int]$DefaultValue,
    [int]$MinValue,
    [int]$MaxValue
  )

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

function Normalize-Scope {
  param(
    [string]$Value
  )

  $scope = if ([string]::IsNullOrWhiteSpace($Value)) { 'wsl' } else { $Value.Trim().ToLowerInvariant() }
  if ($scope -notin @('all', 'wsl', 'sandbox', 'host')) {
    throw ("invalid scope: {0} (expected: all|wsl|sandbox|host)" -f $Value)
  }
  return $scope
}

function Test-MarkerSuccess {
  param(
    [object]$Marker
  )

  if ($null -eq $Marker) { return $false }
  $prop = $Marker.PSObject.Properties['success']
  if ($null -eq $prop) { return $false }
  return [bool]$prop.Value
}

function Get-SandboxFailureKindFromMessage {
  param(
    [string]$Message
  )

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

function Get-SandboxActionRequired {
  param(
    [string]$FailureKind
  )

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

function Get-WslActionRequired {
  param(
    [string]$FailureKind
  )

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

function Get-HostActionRequired {
  param(
    [string]$FailureKind
  )

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
