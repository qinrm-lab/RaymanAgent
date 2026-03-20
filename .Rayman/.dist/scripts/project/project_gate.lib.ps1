Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DisplayRelativePath {
  param(
    [string]$BasePath,
    [string]$FullPath
  )

  if ([string]::IsNullOrWhiteSpace($FullPath)) { return '' }

  $baseRaw = [string]$BasePath
  $fullRaw = [string]$FullPath
  if ($baseRaw.StartsWith('Microsoft.PowerShell.Core\FileSystem::', [System.StringComparison]::OrdinalIgnoreCase)) {
    $baseRaw = $baseRaw.Substring('Microsoft.PowerShell.Core\FileSystem::'.Length)
  }
  if ($fullRaw.StartsWith('Microsoft.PowerShell.Core\FileSystem::', [System.StringComparison]::OrdinalIgnoreCase)) {
    $fullRaw = $fullRaw.Substring('Microsoft.PowerShell.Core\FileSystem::'.Length)
  }

  try {
    $baseFull = [System.IO.Path]::GetFullPath($baseRaw).TrimEnd('\', '/')
  } catch {
    $baseFull = $baseRaw.TrimEnd('\', '/')
  }

  try {
    $full = [System.IO.Path]::GetFullPath($fullRaw)
  } catch {
    $full = $fullRaw
  }

  $baseNorm = ($baseFull -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
  $fullNorm = ($full -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
  if ($fullNorm.StartsWith($baseNorm + '/')) {
    return ($full.Substring($baseFull.Length).TrimStart('\', '/') -replace '\\', '/')
  }
  return ($full -replace '\\', '/')
}

function Get-RaymanObjectPropertyValue {
  param(
    [object]$Object,
    [string]$Name,
    $Default = $null
  )

  if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Name)) {
    return $Default
  }

  try {
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) {
      return $Default
    }
    return $prop.Value
  } catch {
    return $Default
  }
}

function Get-RaymanProjectConfigDefaults {
  return [ordered]@{
    schema = 'rayman.project_config.v1'
    project_name = ''
    build_command = ''
    browser_command = ''
    full_gate_command = ''
    enable_windows = $false
    extra_protected_assets_manifest = ''
    path_filters = [ordered]@{
      fast = @(
        '.Rayman/**'
        '.github/workflows/**'
        '.rayman.project.json'
        '.SolutionName'
        '**/*.requirements.md'
        '**/*.sln'
        '**/*.slnx'
        '**/*.csproj'
        '**/*.fsproj'
        '**/*.props'
        '**/*.targets'
        '**/package.json'
        '**/pnpm-lock.yaml'
        '**/package-lock.json'
        '**/yarn.lock'
      )
      browser = @(
        '.Rayman/**'
        '.github/workflows/**'
        '.rayman.project.json'
        'src/**'
        'app/**'
        'web/**'
        'pages/**'
        'components/**'
        'public/**'
        'playwright/**'
        'tests/**'
        'test-*.js'
        'test-*.ts'
        'test-*.tsx'
      )
      full = @(
        '.Rayman/**'
        '.github/workflows/**'
        '.rayman.project.json'
        '.SolutionName'
        '**/*.requirements.md'
        '**/*.sln'
        '**/*.slnx'
        '**/*.csproj'
        '**/*.fsproj'
        '**/*.props'
        '**/*.targets'
        '**/*.js'
        '**/*.ts'
        '**/*.tsx'
        '**/*.json'
      )
    }
    extensions = [ordered]@{
      project_fast_checks = ''
      project_browser_checks = ''
      project_release_checks = ''
    }
  }
}

function Get-RaymanProjectConfigPath {
  param([string]$WorkspaceRoot)

  return (Join-Path $WorkspaceRoot '.rayman.project.json')
}

function Get-RaymanProjectGateRuntimeDir {
  param([string]$WorkspaceRoot)

  return (Join-Path $WorkspaceRoot '.Rayman\runtime\project_gates')
}

function Get-RaymanProjectGateReportPath {
  param(
    [string]$WorkspaceRoot,
    [ValidateSet('fast', 'browser', 'full')][string]$Lane
  )

  return (Join-Path (Get-RaymanProjectGateRuntimeDir -WorkspaceRoot $WorkspaceRoot) ("{0}.report.json" -f $Lane))
}

function Get-RaymanProjectGateLogDir {
  param([string]$WorkspaceRoot)

  return (Join-Path (Get-RaymanProjectGateRuntimeDir -WorkspaceRoot $WorkspaceRoot) 'logs')
}

function Get-RaymanProjectDisplayName {
  param(
    [string]$WorkspaceRoot,
    [object]$Config
  )

  $projectName = [string](Get-RaymanObjectPropertyValue -Object $Config -Name 'project_name' -Default '')
  if (-not [string]::IsNullOrWhiteSpace($projectName)) {
    return $projectName.Trim()
  }

  $leaf = ''
  try {
    $leaf = Split-Path -Leaf ((Resolve-Path -LiteralPath $WorkspaceRoot).Path)
  } catch {
    $leaf = Split-Path -Leaf $WorkspaceRoot
  }

  if ([string]::IsNullOrWhiteSpace($leaf)) {
    return 'rayman-project'
  }
  return $leaf
}

function ConvertTo-RaymanBoolean {
  param(
    $Value,
    [bool]$Default = $false
  )

  if ($null -eq $Value) { return $Default }
  $text = ([string]$Value).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return $Default }
  switch ($text.ToLowerInvariant()) {
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

function Get-RaymanStringArrayOrDefault {
  param(
    $Value,
    [string[]]$Default = @()
  )

  if ($null -eq $Value) {
    return @($Default)
  }

  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
    $items = @()
    foreach ($item in $Value) {
      $text = [string]$item
      if (-not [string]::IsNullOrWhiteSpace($text)) {
        $items += $text.Trim()
      }
    }
    if ($items.Count -gt 0) {
      return @($items)
    }
  }

  $scalar = [string]$Value
  if ([string]::IsNullOrWhiteSpace($scalar)) {
    return @($Default)
  }
  return @($scalar.Trim())
}

function Read-RaymanProjectConfig {
  param([string]$WorkspaceRoot)

  $defaults = Get-RaymanProjectConfigDefaults
  $configPath = Get-RaymanProjectConfigPath -WorkspaceRoot $WorkspaceRoot
  $parsed = $null
  $exists = Test-Path -LiteralPath $configPath -PathType Leaf
  $parseError = ''
  if ($exists) {
    try {
      $parsed = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
      $parseError = $_.Exception.Message
    }
  }

  $pathFiltersRaw = Get-RaymanObjectPropertyValue -Object $parsed -Name 'path_filters' -Default $null
  $extensionsRaw = Get-RaymanObjectPropertyValue -Object $parsed -Name 'extensions' -Default $null

  $resolved = [pscustomobject]@{
    schema = [string](Get-RaymanObjectPropertyValue -Object $parsed -Name 'schema' -Default $defaults.schema)
    project_name = [string](Get-RaymanObjectPropertyValue -Object $parsed -Name 'project_name' -Default $defaults.project_name)
    build_command = [string](Get-RaymanObjectPropertyValue -Object $parsed -Name 'build_command' -Default $defaults.build_command)
    browser_command = [string](Get-RaymanObjectPropertyValue -Object $parsed -Name 'browser_command' -Default $defaults.browser_command)
    full_gate_command = [string](Get-RaymanObjectPropertyValue -Object $parsed -Name 'full_gate_command' -Default $defaults.full_gate_command)
    enable_windows = (ConvertTo-RaymanBoolean -Value (Get-RaymanObjectPropertyValue -Object $parsed -Name 'enable_windows' -Default $defaults.enable_windows) -Default $false)
    extra_protected_assets_manifest = [string](Get-RaymanObjectPropertyValue -Object $parsed -Name 'extra_protected_assets_manifest' -Default $defaults.extra_protected_assets_manifest)
    path_filters = [pscustomobject]@{
      fast = @(Get-RaymanStringArrayOrDefault -Value (Get-RaymanObjectPropertyValue -Object $pathFiltersRaw -Name 'fast' -Default $null) -Default $defaults.path_filters.fast)
      browser = @(Get-RaymanStringArrayOrDefault -Value (Get-RaymanObjectPropertyValue -Object $pathFiltersRaw -Name 'browser' -Default $null) -Default $defaults.path_filters.browser)
      full = @(Get-RaymanStringArrayOrDefault -Value (Get-RaymanObjectPropertyValue -Object $pathFiltersRaw -Name 'full' -Default $null) -Default $defaults.path_filters.full)
    }
    extensions = [pscustomobject]@{
      project_fast_checks = [string](Get-RaymanObjectPropertyValue -Object $extensionsRaw -Name 'project_fast_checks' -Default $defaults.extensions.project_fast_checks)
      project_browser_checks = [string](Get-RaymanObjectPropertyValue -Object $extensionsRaw -Name 'project_browser_checks' -Default $defaults.extensions.project_browser_checks)
      project_release_checks = [string](Get-RaymanObjectPropertyValue -Object $extensionsRaw -Name 'project_release_checks' -Default $defaults.extensions.project_release_checks)
    }
  }

  return [pscustomobject]@{
    path = $configPath
    exists = $exists
    parse_error = $parseError
    valid = [string]::IsNullOrWhiteSpace($parseError)
    config = $resolved
  }
}

function ConvertTo-RaymanProjectConfigJson {
  param(
    [string]$WorkspaceRoot,
    [object]$Config = $null
  )

  $resolvedConfig = $Config
  if ($null -eq $resolvedConfig) {
    $defaults = Get-RaymanProjectConfigDefaults
    $resolvedConfig = [pscustomobject]@{
      schema = $defaults.schema
      project_name = (Split-Path -Leaf $WorkspaceRoot)
      build_command = $defaults.build_command
      browser_command = $defaults.browser_command
      full_gate_command = $defaults.full_gate_command
      enable_windows = $defaults.enable_windows
      extra_protected_assets_manifest = $defaults.extra_protected_assets_manifest
      path_filters = [pscustomobject]@{
        fast = @($defaults.path_filters.fast)
        browser = @($defaults.path_filters.browser)
        full = @($defaults.path_filters.full)
      }
      extensions = [pscustomobject]@{
        project_fast_checks = $defaults.extensions.project_fast_checks
        project_browser_checks = $defaults.extensions.project_browser_checks
        project_release_checks = $defaults.extensions.project_release_checks
      }
    }
  }

  return ($resolvedConfig | ConvertTo-Json -Depth 8)
}

function New-RaymanProjectGateCheck {
  param(
    [string]$Key,
    [string]$Name,
    [ValidateSet('PASS', 'WARN', 'FAIL', 'SKIP')][string]$Status,
    [string]$Detail,
    [string]$Action = '',
    [string]$Command = '',
    [string]$LogPath = '',
    [int]$ExitCode = 0,
    [double]$DurationSeconds = 0
  )

  return [pscustomobject]@{
    key = $Key
    name = $Name
    status = $Status
    detail = $Detail
    action = $Action
    command = $Command
    log_path = $LogPath
    exit_code = $ExitCode
    duration_seconds = [math]::Round($DurationSeconds, 3)
  }
}

function New-RaymanProjectGateEmptyCommandCheck {
  param(
    [string]$Key,
    [string]$Name,
    [string]$Action = '',
    [string]$LogPath = '',
    [ValidateSet('source', 'external')][string]$WorkspaceKind = 'external',
    [switch]$WarnWhenEmpty
  )

  if (($WorkspaceKind -eq 'source') -and $WarnWhenEmpty.IsPresent) {
    return (New-RaymanProjectGateCheck -Key $Key -Name $Name -Status SKIP -Detail 'source workspace; consumer-only project config not applicable' -Action '' -LogPath $LogPath)
  }

  $status = if ($WarnWhenEmpty.IsPresent) { 'WARN' } else { 'SKIP' }
  return (New-RaymanProjectGateCheck -Key $Key -Name $Name -Status $status -Detail 'command not configured' -Action $Action -LogPath $LogPath)
}

function Get-RaymanProjectGateSummary {
  param($Checks)

  $checkItems = @($Checks)

  $passCount = @($checkItems | Where-Object { [string]$_.status -eq 'PASS' }).Count
  $warnCount = @($checkItems | Where-Object { [string]$_.status -eq 'WARN' }).Count
  $failCount = @($checkItems | Where-Object { [string]$_.status -eq 'FAIL' }).Count
  $skipCount = @($checkItems | Where-Object { [string]$_.status -eq 'SKIP' }).Count

  $overall = 'PASS'
  if ($failCount -gt 0) {
    $overall = 'FAIL'
  } elseif ($warnCount -gt 0) {
    $overall = 'WARN'
  }

  return [pscustomobject]@{
    overall = $overall
    success = ($overall -ne 'FAIL')
    counts = [pscustomobject]@{
      pass = $passCount
      warn = $warnCount
      fail = $failCount
      skip = $skipCount
      total = @($checkItems).Count
    }
  }
}

function Get-RaymanProjectGateExitCode {
  param([string]$Overall)

  if ([string]$Overall -eq 'FAIL') {
    return 1
  }
  return 0
}

function Format-RaymanWorkflowYamlList {
  param(
    [string[]]$Values,
    [int]$Indent = 6
  )

  $prefix = (' ' * $Indent)
  $lines = @()
  foreach ($value in @($Values)) {
    $text = [string]$value
    if ([string]::IsNullOrWhiteSpace($text)) { continue }
    $escaped = $text.Replace("'", "''")
    $lines += ('{0}- ''{1}''' -f $prefix, $escaped)
  }
  if ($lines.Count -eq 0) {
    return ('{0}- ''.Rayman/**''' -f $prefix)
  }
  return ($lines -join "`n")
}

function Get-RaymanProjectWorkflowTemplatePath {
  param(
    [string]$WorkspaceRoot,
    [ValidateSet('fast', 'browser', 'full')][string]$Lane
  )

  return (Join-Path $WorkspaceRoot (Join-Path '.Rayman\templates\workflows' ("rayman-project-{0}-gate.yml" -f $Lane)))
}

function Get-RaymanProjectWorkflowTargetPath {
  param(
    [string]$WorkspaceRoot,
    [ValidateSet('fast', 'browser', 'full')][string]$Lane
  )

  return (Join-Path $WorkspaceRoot (Join-Path '.github\workflows' ("rayman-project-{0}-gate.yml" -f $Lane)))
}
