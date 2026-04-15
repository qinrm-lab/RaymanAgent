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
  if ($msg.Contains('only one running windows sandbox instance') -or $msg.Contains('仅允许一个运行的 windows 沙盒实例') -or $msg.Contains('existing windows sandbox instance is already running')) {
    return 'existing_instance_running'
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
    'existing_instance_running' {
      return '检测到已有 Windows Sandbox 实例在运行；先关闭已有 Sandbox 窗口，或等待当前 Rayman sandbox session 完成后再重试。'
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
      return '当前主机缺少可用的 Node.js/npm；请先安装或修复 Node.js 环境后重试。'
    }
    'tool_prepare_failed' {
      return 'Rayman 自管的 host Playwright 工具准备失败；请检查网络代理与 npm 源配置后重试。'
    }
    'execution_failed' {
      return 'host 模式安装/检查 Playwright 失败；请检查网络代理与 npm 源配置后重试。'
    }
    default {
      return 'host 模式未就绪；请检查 Node.js/npm 后重试。'
    }
  }
}

function Get-RaymanPlaywrightStableHash {
  param([AllowEmptyString()][string]$Value)

  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Value)
    $hashBytes = $sha.ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant())
  } finally {
    $sha.Dispose()
  }
}

function Resolve-RaymanPlaywrightUserRoot {
  $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
  if (-not [string]::IsNullOrWhiteSpace([string]$localAppData)) {
    return (Join-Path $localAppData 'Rayman')
  }

  $home = [Environment]::GetEnvironmentVariable('HOME')
  if (-not [string]::IsNullOrWhiteSpace([string]$home)) {
    return (Join-Path (Join-Path $home '.local') 'share\Rayman')
  }

  $userProfile = [Environment]::GetFolderPath('UserProfile')
  if (-not [string]::IsNullOrWhiteSpace([string]$userProfile)) {
    return (Join-Path $userProfile 'AppData\Local\Rayman')
  }

  return (Join-Path ([System.IO.Path]::GetTempPath()) 'Rayman')
}

function Ensure-RaymanPlaywrightDirectory {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace([string]$Path)) { return }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Read-RaymanPlaywrightJsonOrNull {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Write-RaymanPlaywrightJsonFile {
  param(
    [string]$Path,
    [object]$Value
  )

  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace([string]$parent)) {
    Ensure-RaymanPlaywrightDirectory -Path $parent
  }
  ($Value | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Resolve-RaymanPlaywrightCommandPath {
  param([string[]]$Candidates)

  foreach ($candidate in @($Candidates)) {
    if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
      continue
    }
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
      return [string]$cmd.Source
    }
  }

  return ''
}

function Resolve-RaymanPlaywrightNodeCommand {
  if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
    return (Resolve-RaymanPlaywrightCommandPath -Candidates @('node.exe', 'node'))
  }
  return (Resolve-RaymanPlaywrightCommandPath -Candidates @('node', 'node.exe'))
}

function Resolve-RaymanPlaywrightNpmCommand {
  if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
    return (Resolve-RaymanPlaywrightCommandPath -Candidates @('npm.cmd', 'npm'))
  }
  return (Resolve-RaymanPlaywrightCommandPath -Candidates @('npm', 'npm.cmd'))
}

function Read-RaymanPlaywrightWorkspacePackageJson {
  param([string]$WorkspaceRoot)

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $packageJsonPath = Join-Path $resolvedRoot 'package.json'
  if (-not (Test-Path -LiteralPath $packageJsonPath -PathType Leaf)) {
    return $null
  }

  try {
    return (Get-Content -LiteralPath $packageJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Get-RaymanPlaywrightWorkspaceDeclaredSpec {
  param(
    [string]$WorkspaceRoot,
    [string]$DefaultPackageSpec = 'playwright@latest'
  )

  $packageJson = Read-RaymanPlaywrightWorkspacePackageJson -WorkspaceRoot $WorkspaceRoot
  $playwrightRange = ''
  $playwrightTestRange = ''
  foreach ($sectionName in @('dependencies', 'devDependencies', 'optionalDependencies')) {
    if ($null -eq $packageJson -or $null -eq $packageJson.PSObject.Properties[$sectionName]) {
      continue
    }
    $section = $packageJson.$sectionName
    if ($null -ne $section.PSObject.Properties['playwright'] -and -not [string]::IsNullOrWhiteSpace([string]$section.playwright)) {
      $playwrightRange = [string]$section.playwright
      break
    }
    if ($null -ne $section.PSObject.Properties['@playwright/test'] -and -not [string]::IsNullOrWhiteSpace([string]$section.'@playwright/test')) {
      $playwrightTestRange = [string]$section.'@playwright/test'
    }
  }

  if (-not [string]::IsNullOrWhiteSpace([string]$playwrightRange)) {
    return [pscustomobject]@{
      package_spec = ('playwright@{0}' -f $playwrightRange)
      dependency_name = 'playwright'
      declared_range = $playwrightRange
      package_json_present = ($null -ne $packageJson)
    }
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$playwrightTestRange)) {
    return [pscustomobject]@{
      package_spec = ('playwright@{0}' -f $playwrightTestRange)
      dependency_name = '@playwright/test'
      declared_range = $playwrightTestRange
      package_json_present = ($null -ne $packageJson)
    }
  }

  return [pscustomobject]@{
    package_spec = $DefaultPackageSpec
    dependency_name = ''
    declared_range = ''
    package_json_present = ($null -ne $packageJson)
  }
}

function Get-RaymanPlaywrightWorkspaceLocalCliProbe {
  param([string]$WorkspaceRoot)

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $cliPath = Join-Path $resolvedRoot 'node_modules\playwright\cli.js'
  if (-not (Test-Path -LiteralPath $cliPath -PathType Leaf)) {
    return [pscustomobject]@{
      success = $false
      install_source = ''
      tool_root = ''
      package_spec = ''
      resolved_version = ''
      cli_path = ''
      detail = 'workspace local playwright cli not found'
    }
  }

  $packageJsonPath = Join-Path $resolvedRoot 'node_modules\playwright\package.json'
  $resolvedVersion = ''
  if (Test-Path -LiteralPath $packageJsonPath -PathType Leaf) {
    try {
      $packageJson = Get-Content -LiteralPath $packageJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      if ($null -ne $packageJson.PSObject.Properties['version']) {
        $resolvedVersion = [string]$packageJson.version
      }
    } catch {}
  }

  return [pscustomobject]@{
    success = $true
    install_source = 'workspace_local'
    tool_root = $resolvedRoot
    package_spec = $(if ([string]::IsNullOrWhiteSpace([string]$resolvedVersion)) { 'playwright' } else { ('playwright@{0}' -f $resolvedVersion) })
    resolved_version = $resolvedVersion
    cli_path = $cliPath
    detail = 'using workspace-local playwright cli'
  }
}

function Get-RaymanPlaywrightManagedToolDescriptor {
  param([string]$PackageSpec)

  $effectiveSpec = if ([string]::IsNullOrWhiteSpace([string]$PackageSpec)) { 'playwright@latest' } else { [string]$PackageSpec }
  $toolsRoot = Join-Path (Resolve-RaymanPlaywrightUserRoot) 'tools\playwright-host'
  $hash = Get-RaymanPlaywrightStableHash -Value $effectiveSpec
  $toolRoot = Join-Path $toolsRoot $hash
  return [pscustomobject]@{
    tools_root = $toolsRoot
    tool_root = $toolRoot
    manifest_path = Join-Path $toolRoot 'manifest.json'
    cli_path = Join-Path $toolRoot 'node_modules\playwright\cli.js'
    package_json_path = Join-Path $toolRoot 'node_modules\playwright\package.json'
    package_spec = $effectiveSpec
    hash = $hash
  }
}

function Ensure-RaymanPlaywrightManagedTool {
  param(
    [string]$WorkspaceRoot,
    [string]$PackageSpec
  )

  $descriptor = Get-RaymanPlaywrightManagedToolDescriptor -PackageSpec $PackageSpec
  $nodeCommand = Resolve-RaymanPlaywrightNodeCommand
  if ([string]::IsNullOrWhiteSpace([string]$nodeCommand)) {
    return [pscustomobject]@{
      success = $false
      install_source = 'rayman_managed'
      tool_root = [string]$descriptor.tool_root
      package_spec = [string]$descriptor.package_spec
      resolved_version = ''
      cli_path = ''
      node_command = $nodeCommand
      npm_command = ''
      failure_kind = 'command_unavailable'
      detail = 'node command is not available'
      install_output = @()
    }
  }

  $manifest = Read-RaymanPlaywrightJsonOrNull -Path $descriptor.manifest_path
  $needsInstall = $true
  if ($null -ne $manifest -and (Test-Path -LiteralPath $descriptor.cli_path -PathType Leaf)) {
    $manifestSpec = if ($null -ne $manifest.PSObject.Properties['package_spec']) { [string]$manifest.package_spec } else { '' }
    if ($manifestSpec -eq [string]$descriptor.package_spec) {
      $needsInstall = $false
    }
  }

  if ($needsInstall) {
    $npmCommand = Resolve-RaymanPlaywrightNpmCommand
    if ([string]::IsNullOrWhiteSpace([string]$npmCommand)) {
      return [pscustomobject]@{
        success = $false
        install_source = 'rayman_managed'
        tool_root = [string]$descriptor.tool_root
        package_spec = [string]$descriptor.package_spec
        resolved_version = ''
        cli_path = ''
        node_command = $nodeCommand
        npm_command = ''
        failure_kind = 'command_unavailable'
        detail = 'npm command is not available for managed playwright tool install'
        install_output = @()
      }
    }

    Ensure-RaymanPlaywrightDirectory -Path $descriptor.tool_root
    $toolPackageJsonPath = Join-Path $descriptor.tool_root 'package.json'
    if (-not (Test-Path -LiteralPath $toolPackageJsonPath -PathType Leaf)) {
      Set-Content -LiteralPath $toolPackageJsonPath -Encoding UTF8 -Value "{`n  `"name`": `"rayman-playwright-host`",`n  `"private`": true`n}`n"
    }

    foreach ($cleanupPath in @(
        (Join-Path $descriptor.tool_root 'node_modules'),
        (Join-Path $descriptor.tool_root 'package-lock.json')
      )) {
      if (Test-Path -LiteralPath $cleanupPath) {
        Remove-Item -LiteralPath $cleanupPath -Recurse -Force -ErrorAction SilentlyContinue
      }
    }

    $installOutput = @()
    $installExitCode = 1
    $installArgs = @('install', '--no-save', '--package-lock=false', ([string]$descriptor.package_spec))
    $saved = Get-Location
    try {
      Set-Location -LiteralPath $descriptor.tool_root
      try {
        $installOutput = @(& $npmCommand @installArgs 2>&1 | ForEach-Object { [string]$_ })
        $installExitCode = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
      } catch {
        $installExitCode = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 1 }
        $installOutput = @($installOutput + @([string]$_.Exception.Message))
      }

      if ($installExitCode -ne 0 -or -not (Test-Path -LiteralPath $descriptor.cli_path -PathType Leaf)) {
        return [pscustomobject]@{
          success = $false
          install_source = 'rayman_managed'
          tool_root = [string]$descriptor.tool_root
          package_spec = [string]$descriptor.package_spec
          resolved_version = ''
          cli_path = ''
          node_command = $nodeCommand
          npm_command = $npmCommand
          failure_kind = 'tool_prepare_failed'
          detail = ('managed playwright tool install failed (exit={0})' -f $installExitCode)
          install_output = @($installOutput)
        }
      }
    } finally {
      Set-Location -LiteralPath $saved.Path
    }
  }

  if (-not (Test-Path -LiteralPath $descriptor.cli_path -PathType Leaf)) {
    return [pscustomobject]@{
      success = $false
      install_source = 'rayman_managed'
      tool_root = [string]$descriptor.tool_root
      package_spec = [string]$descriptor.package_spec
      resolved_version = ''
      cli_path = ''
      node_command = $nodeCommand
      npm_command = $npmCommand
      failure_kind = 'tool_prepare_failed'
      detail = 'managed playwright tool cli is missing after prepare'
      install_output = @()
    }
  }

  $resolvedVersion = ''
  if (Test-Path -LiteralPath $descriptor.package_json_path -PathType Leaf) {
    try {
      $resolvedPackage = Get-Content -LiteralPath $descriptor.package_json_path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      if ($null -ne $resolvedPackage.PSObject.Properties['version']) {
        $resolvedVersion = [string]$resolvedPackage.version
      }
    } catch {}
  }

  Write-RaymanPlaywrightJsonFile -Path $descriptor.manifest_path -Value ([ordered]@{
      schema = 'rayman.playwright.host_tool.manifest.v1'
      package_spec = [string]$descriptor.package_spec
      tool_root = [string]$descriptor.tool_root
      cli_path = [string]$descriptor.cli_path
      resolved_version = $resolvedVersion
      last_prepared_at = (Get-Date).ToString('o')
    })

  return [pscustomobject]@{
    success = $true
      install_source = 'rayman_managed'
      tool_root = [string]$descriptor.tool_root
      package_spec = [string]$descriptor.package_spec
      resolved_version = $resolvedVersion
      cli_path = [string]$descriptor.cli_path
      node_command = $nodeCommand
      npm_command = ''
      failure_kind = ''
      detail = 'using Rayman-managed playwright host tool'
      install_output = @()
    }
}

function Resolve-RaymanPlaywrightHostInstallInvocation {
  param(
    [string]$WorkspaceRoot,
    [string]$Browser,
    [string]$DefaultPackageSpec = 'playwright@latest'
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $browserEffective = if ([string]::IsNullOrWhiteSpace([string]$Browser)) { 'chromium' } else { [string]$Browser.Trim().ToLowerInvariant() }
  $nodeCommand = Resolve-RaymanPlaywrightNodeCommand
  if ([string]::IsNullOrWhiteSpace([string]$nodeCommand)) {
    return [pscustomobject]@{
      success = $false
      install_source = ''
      tool_root = ''
      package_spec = ''
      resolved_version = ''
      cli_path = ''
      command = ''
      argument_list = @()
      command_display = ''
      failure_kind = 'command_unavailable'
      detail = 'node command is not available'
      install_output = @()
    }
  }

  $localProbe = Get-RaymanPlaywrightWorkspaceLocalCliProbe -WorkspaceRoot $resolvedRoot
  if ([bool]$localProbe.success) {
    return [pscustomobject]@{
      success = $true
      install_source = [string]$localProbe.install_source
      tool_root = [string]$localProbe.tool_root
      package_spec = [string]$localProbe.package_spec
      resolved_version = [string]$localProbe.resolved_version
      cli_path = [string]$localProbe.cli_path
      command = $nodeCommand
      argument_list = @([string]$localProbe.cli_path, 'install', $browserEffective)
      command_display = ('{0} {1} install {2}' -f $nodeCommand, [string]$localProbe.cli_path, $browserEffective)
      failure_kind = ''
      detail = [string]$localProbe.detail
      install_output = @()
    }
  }

  $declaredSpec = Get-RaymanPlaywrightWorkspaceDeclaredSpec -WorkspaceRoot $resolvedRoot -DefaultPackageSpec $DefaultPackageSpec
  $managedProbe = Ensure-RaymanPlaywrightManagedTool -WorkspaceRoot $resolvedRoot -PackageSpec ([string]$declaredSpec.package_spec)
  if (-not [bool]$managedProbe.success) {
    return [pscustomobject]@{
      success = $false
      install_source = 'rayman_managed'
      tool_root = [string]$managedProbe.tool_root
      package_spec = [string]$managedProbe.package_spec
      resolved_version = [string]$managedProbe.resolved_version
      cli_path = [string]$managedProbe.cli_path
      command = ''
      argument_list = @()
      command_display = ''
      failure_kind = if ($managedProbe.PSObject.Properties['failure_kind']) { [string]$managedProbe.failure_kind } else { 'tool_prepare_failed' }
      detail = if ($managedProbe.PSObject.Properties['detail']) { [string]$managedProbe.detail } else { 'managed playwright tool prepare failed' }
      install_output = if ($managedProbe.PSObject.Properties['install_output']) { @($managedProbe.install_output) } else { @() }
    }
  }

  return [pscustomobject]@{
    success = $true
    install_source = [string]$managedProbe.install_source
    tool_root = [string]$managedProbe.tool_root
    package_spec = [string]$managedProbe.package_spec
    resolved_version = [string]$managedProbe.resolved_version
    cli_path = [string]$managedProbe.cli_path
    command = $nodeCommand
    argument_list = @([string]$managedProbe.cli_path, 'install', $browserEffective)
    command_display = ('{0} {1} install {2}' -f $nodeCommand, [string]$managedProbe.cli_path, $browserEffective)
    failure_kind = ''
    detail = [string]$managedProbe.detail
    install_output = @()
  }
}
