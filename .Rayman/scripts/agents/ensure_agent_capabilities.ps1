param(
  [ValidateSet('status', 'sync')][string]$Action = 'status',
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
  . $commonPath
}

function Write-CapInfo([string]$Message) {
  if ($Json) { return }
  if (Get-Command Write-Info -ErrorAction SilentlyContinue) {
    Write-Info $Message
  } else {
    Write-Host $Message -ForegroundColor Cyan
  }
}

function Write-CapWarn([string]$Message) {
  if ($Json) { return }
  if (Get-Command Write-Warn -ErrorAction SilentlyContinue) {
    Write-Warn $Message
  } else {
    Write-Host $Message -ForegroundColor Yellow
  }
}

function Get-EnvBoolCompat([string]$Name, [bool]$Default = $false) {
  $raw = [Environment]::GetEnvironmentVariable($Name)
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

function Get-EnvIntCompat([string]$Name, [int]$Default, [int]$Min = 1, [int]$Max = 2147483647) {
  $raw = [Environment]::GetEnvironmentVariable($Name)
  $parsed = 0
  if (-not [string]::IsNullOrWhiteSpace($raw) -and [int]::TryParse($raw, [ref]$parsed)) {
    if ($parsed -lt $Min) { return $Min }
    if ($parsed -gt $Max) { return $Max }
    return $parsed
  }
  return $Default
}

function Convert-ToStringArray([object]$Value) {
  if ($null -eq $Value) { return @() }
  $items = New-Object System.Collections.Generic.List[string]
  foreach ($entry in @($Value)) {
    $text = [string]$entry
    if (-not [string]::IsNullOrWhiteSpace($text)) {
      $items.Add($text.Trim()) | Out-Null
    }
  }
  return @($items)
}

function Get-PropValue([object]$Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  $prop = $Object.PSObject.Properties[$Name]
  if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
  return $prop.Value
}

function Test-MapHasKey([object]$Map, [string]$Key) {
  if ($null -eq $Map -or [string]::IsNullOrWhiteSpace($Key)) { return $false }

  if ($Map -is [System.Collections.IDictionary]) {
    return $Map.Contains($Key)
  }

  $prop = $Map.PSObject.Properties[$Key]
  return ($null -ne $prop)
}

function Get-JsonOrNull([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  if (Get-Command Read-RaymanJsonFile -ErrorAction SilentlyContinue) {
    $doc = Read-RaymanJsonFile -Path $Path
    if ([bool]$doc.ParseFailed) {
      Write-Warn ("[agent-cap] invalid json/jsonc: {0}; fallback to defaults. detail={1}" -f $Path, [string]$doc.Error)
      return $null
    }
    return $doc.Obj
  }
  try {
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Ensure-Dir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Test-HostIsWindows {
  try {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
  } catch {
    return $false
  }
}

function Get-WinAppManagedMcpId {
  return 'raymanWinApp'
}

function Get-WinAppDesktopSessionState {
  if (-not (Test-HostIsWindows)) {
    return [pscustomobject]@{
      available = $false
      reason = 'host_not_windows'
      session_name = ''
      user_interactive = $false
    }
  }

  $userInteractive = $false
  try {
    $userInteractive = [Environment]::UserInteractive
  } catch {
    $userInteractive = $false
  }

  $sessionName = [string]$env:SESSIONNAME
  if (-not $userInteractive) {
    return [pscustomobject]@{
      available = $false
      reason = 'desktop_session_unavailable'
      session_name = $sessionName
      user_interactive = $false
    }
  }

  return [pscustomobject]@{
    available = $true
    reason = 'interactive_desktop'
    session_name = $sessionName
    user_interactive = $true
  }
}

function Get-CapabilityEnvToggleName([string]$CapabilityName) {
  switch ($CapabilityName) {
    'openai_docs' { return 'RAYMAN_AGENT_CAP_OPENAI_DOCS_ENABLED' }
    'web_auto_test' { return 'RAYMAN_AGENT_CAP_WEB_AUTO_TEST_ENABLED' }
    'winapp_auto_test' { return 'RAYMAN_AGENT_CAP_WINAPP_AUTO_TEST_ENABLED' }
    default { return '' }
  }
}

function Get-CodexHomePath {
  if (Get-Command Resolve-RaymanCodexContext -ErrorAction SilentlyContinue) {
    $context = Resolve-RaymanCodexContext -WorkspaceRoot $WorkspaceRoot
    if ($null -ne $context -and -not [string]::IsNullOrWhiteSpace([string]$context.codex_home)) {
      return [string]$context.codex_home
    }
  }

  $raw = [Environment]::GetEnvironmentVariable('CODEX_HOME')
  if (-not [string]::IsNullOrWhiteSpace($raw)) {
    return $raw
  }

  $userHome = [Environment]::GetFolderPath('UserProfile')
  if ([string]::IsNullOrWhiteSpace($userHome)) {
    $userHome = $env:HOME
  }
  if ([string]::IsNullOrWhiteSpace($userHome)) {
    return ''
  }
  return (Join-Path $userHome '.codex')
}

function Get-CodexUserConfigPath {
  $codexHome = Get-CodexHomePath
  if ([string]::IsNullOrWhiteSpace($codexHome)) { return '' }
  return (Join-Path $codexHome 'config.toml')
}

function Get-CodexProjectTrustStatus([string]$WorkspaceRoot) {
  $configPath = Get-CodexUserConfigPath
  if ([string]::IsNullOrWhiteSpace($configPath) -or -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    return [pscustomobject]@{
      status = 'unknown'
      reason = 'user_config_missing'
      config_path = $configPath
    }
  }

  try {
    $workspaceTokens = @()
    if (Get-Command Get-RaymanPathComparisonVariants -ErrorAction SilentlyContinue) {
      $workspaceTokens = @(Get-RaymanPathComparisonVariants -PathValue $WorkspaceRoot)
    }
    if ($workspaceTokens.Count -eq 0) {
      $workspaceTokens = @(([System.IO.Path]::GetFullPath($WorkspaceRoot)).Replace('\', '/').TrimEnd('/').ToLowerInvariant())
    }
    $sections = New-Object System.Collections.Generic.List[object]
    $currentHeader = ''
    $currentLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in Get-Content -LiteralPath $configPath -Encoding UTF8) {
      $trimmed = ([string]$line).Trim()
      if ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']')) {
        if (-not [string]::IsNullOrWhiteSpace($currentHeader)) {
          $sections.Add([pscustomobject]@{
              header = $currentHeader
              body = @($currentLines)
            }) | Out-Null
        }
        $currentHeader = $trimmed
        $currentLines = New-Object System.Collections.Generic.List[string]
        continue
      }
      if (-not [string]::IsNullOrWhiteSpace($currentHeader)) {
        $currentLines.Add([string]$line) | Out-Null
      }
    }

    if (-not [string]::IsNullOrWhiteSpace($currentHeader)) {
      $sections.Add([pscustomobject]@{
          header = $currentHeader
          body = @($currentLines)
        }) | Out-Null
    }

    foreach ($section in $sections) {
      $headerText = [string]$section.header
      $headerNorm = $headerText.ToLowerInvariant()
      if ($headerNorm -notmatch '^\[projects\.') { continue }

      $matchedWorkspace = $false
      foreach ($workspaceToken in $workspaceTokens) {
        if ([string]::IsNullOrWhiteSpace($workspaceToken)) { continue }
        $backslashToken = $workspaceToken.Replace('/', '\')
        if ($headerNorm.Contains($workspaceToken) -or $headerNorm.Contains($backslashToken)) {
          $matchedWorkspace = $true
          break
        }
      }
      if (-not $matchedWorkspace) { continue }

      $bodyText = ((@($section.body) -join "`n")).ToLowerInvariant()
      if ($bodyText -match 'trust_level\s*=\s*"trusted"') {
        return [pscustomobject]@{
          status = 'trusted'
          reason = 'matched_user_config'
          config_path = $configPath
        }
      }
      if ($bodyText -match 'trust_level\s*=\s*"untrusted"') {
        return [pscustomobject]@{
          status = 'untrusted'
          reason = 'matched_user_config'
          config_path = $configPath
        }
      }
    }

    return [pscustomobject]@{
      status = 'unknown'
      reason = 'workspace_not_found'
      config_path = $configPath
    }
  } catch {
    return [pscustomobject]@{
      status = 'unknown'
      reason = ('trust_probe_failed:{0}' -f $_.Exception.Message)
      config_path = $configPath
    }
  }
}

function Get-CodexRuntimeHostState([string]$WorkspaceRoot) {
  $settingsPath = Join-Path $WorkspaceRoot '.vscode\settings.json'
  $currentHost = if (Test-HostIsWindows) {
    'windows'
  } elseif (-not [string]::IsNullOrWhiteSpace([string]$env:WSL_INTEROP) -or $WorkspaceRoot -match '^/mnt/[A-Za-z]/') {
    'wsl'
  } else {
    'linux'
  }

  $runtimeHost = $currentHost
  $source = 'current_host'
  $runInWsl = $null

  $settings = Get-JsonOrNull -Path $settingsPath
  if ($null -ne $settings -and $settings.PSObject.Properties['chatgpt.runCodexInWindowsSubsystemForLinux']) {
    $runInWsl = [bool]$settings.'chatgpt.runCodexInWindowsSubsystemForLinux'
    $runtimeHost = if ($runInWsl) { 'wsl' } else { 'windows' }
    $source = 'vscode_setting'
  }

  return [pscustomobject]@{
    current_host = $currentHost
    runtime_host = $runtimeHost
    source = $source
    settings_path = $settingsPath
    run_in_wsl = $runInWsl
  }
}

function Get-RaymanCapabilityRegistry([string]$WorkspaceRoot) {
  $registryPath = Join-Path $WorkspaceRoot '.Rayman\config\agent_capabilities.json'
  $config = Get-JsonOrNull -Path $registryPath
  $capabilities = New-Object System.Collections.Generic.List[object]
  $valid = $true
  $registryError = ''

  if ($null -eq $config) {
    $valid = $false
    $registryError = 'registry_missing_or_invalid_json'
  } else {
    $schema = [string](Get-PropValue -Object $config -Name 'schema' -Default '')
    if ($schema -ne 'rayman.agent_capabilities.v1') {
      $valid = $false
      $registryError = ('unexpected_schema:{0}' -f $schema)
    }

    $capRoot = Get-PropValue -Object $config -Name 'capabilities' -Default $null
    if ($null -eq $capRoot) {
      $valid = $false
      if ([string]::IsNullOrWhiteSpace($registryError)) {
        $registryError = 'capabilities_missing'
      }
    } else {
      foreach ($prop in $capRoot.PSObject.Properties) {
        $cap = $prop.Value
        $capabilities.Add([pscustomobject]@{
            name = [string]$prop.Name
            enabled = [bool](Get-PropValue -Object $cap -Name 'enabled' -Default $true)
            provider = [string](Get-PropValue -Object $cap -Name 'provider' -Default '')
            kind = [string](Get-PropValue -Object $cap -Name 'kind' -Default '')
            mcp_id = [string](Get-PropValue -Object $cap -Name 'mcp_id' -Default '')
            url = [string](Get-PropValue -Object $cap -Name 'url' -Default '')
            command = [string](Get-PropValue -Object $cap -Name 'command' -Default '')
            args = @(Convert-ToStringArray -Value (Get-PropValue -Object $cap -Name 'args' -Default $null))
            required = [bool](Get-PropValue -Object $cap -Name 'required' -Default $false)
            prepare_command = [string](Get-PropValue -Object $cap -Name 'prepare_command' -Default '')
            fallback_command = [string](Get-PropValue -Object $cap -Name 'fallback_command' -Default '')
            triggers = @(Convert-ToStringArray -Value (Get-PropValue -Object $cap -Name 'triggers' -Default $null))
          }) | Out-Null
      }
    }
  }

  return [pscustomobject]@{
    path = $registryPath
    valid = $valid
    error = $registryError
    capabilities = $capabilities.ToArray()
  }
}

function Get-NumericVersionTuple([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return @(0, 0, 0) }
  $match = [regex]::Match($Text, '(\d+)\.(\d+)\.(\d+)')
  if (-not $match.Success) { return @(0, 0, 0) }
  return @(
    [int]$match.Groups[1].Value,
    [int]$match.Groups[2].Value,
    [int]$match.Groups[3].Value
  )
}

function Test-VersionAtLeast([string]$Candidate, [string]$Minimum) {
  $candidateTuple = @(Get-NumericVersionTuple -Text $Candidate)
  $minimumTuple = @(Get-NumericVersionTuple -Text $Minimum)
  for ($index = 0; $index -lt 3; $index++) {
    if ($candidateTuple[$index] -gt $minimumTuple[$index]) { return $true }
    if ($candidateTuple[$index] -lt $minimumTuple[$index]) { return $false }
  }
  return $true
}

function Get-CodexVersionInfo {
  if (Get-Command Get-RaymanCodexVersionInfo -ErrorAction SilentlyContinue) {
    return (Get-RaymanCodexVersionInfo -WorkspaceRoot $WorkspaceRoot)
  }

  $codexCmd = Get-Command 'codex' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $codexCmd -or [string]::IsNullOrWhiteSpace([string]$codexCmd.Source)) {
    return [pscustomobject]@{
      available = $false
      raw = ''
      numeric = ''
    }
  }

  try {
    $raw = (& $codexCmd.Source '--version' 2>$null | Select-Object -First 1)
    $rawText = [string]$raw
    $numericMatch = [regex]::Match($rawText, '(\d+\.\d+\.\d+)')
    return [pscustomobject]@{
      available = $true
      raw = $rawText
      numeric = if ($numericMatch.Success) { [string]$numericMatch.Groups[1].Value } else { '' }
    }
  } catch {
    return [pscustomobject]@{
      available = $true
      raw = ''
      numeric = ''
    }
  }
}

function Get-CodexFeatureProbe {
  if (Get-Command Get-RaymanCodexFeatureProbe -ErrorAction SilentlyContinue) {
    try {
      return (Get-RaymanCodexFeatureProbe -WorkspaceRoot $WorkspaceRoot)
    } catch {
      $versionInfo = Get-CodexVersionInfo
      return [pscustomobject]@{
        codex_available = [bool]$versionInfo.available
        codex_version = [string]$versionInfo.raw
        numeric_version = [string]$versionInfo.numeric
        features_available = $false
        features = @{}
        error = [string]$_.Exception.Message
      }
    }
  }

  $versionInfo = Get-CodexVersionInfo
  $featureMap = @{}
  $featuresAvailable = $false

  if ([bool]$versionInfo.available) {
    $codexCmd = Get-Command 'codex' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $codexCmd) {
      try {
        if (Test-Path variable:LASTEXITCODE) {
          $global:LASTEXITCODE = 0
        }
        $lines = @(& $codexCmd.Source 'features' 'list' 2>$null)
        $exitCode = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }
        if ($exitCode -eq 0 -and $lines.Count -gt 0) {
          $featuresAvailable = $true
          foreach ($line in $lines) {
            $text = ([string]$line).Trim()
            if ($text -notmatch '^(?<name>\S+)\s+(?<stage>\S+)\s+(?<enabled>\S+)$') { continue }
            $featureMap[[string]$Matches['name']] = [pscustomobject]@{
              stage = [string]$Matches['stage']
              enabled = ([string]$Matches['enabled'] -eq 'true')
            }
          }
        }
      } catch {}
    }
  }

  return [pscustomobject]@{
    codex_available = [bool]$versionInfo.available
    codex_version = [string]$versionInfo.raw
    numeric_version = [string]$versionInfo.numeric
    features_available = $featuresAvailable
    features = $featureMap
  }
}

function Get-CodexFeatureSupportStatus {
  param(
    [object]$Probe,
    [string]$FeatureKey,
    [string]$FeatureName = '',
    [string]$MinimumVersion = '0.5.80',
    [switch]$AlwaysSupported
  )

  if ($AlwaysSupported) {
    return [pscustomobject]@{
      key = $FeatureKey
      supported = $true
      support_source = 'always'
      support_reason = 'rayman_managed'
      feature_detected = $false
      feature_stage = ''
      cli_feature_enabled = $false
      minimum_version = $MinimumVersion
      codex_version = [string](Get-PropValue -Object $Probe -Name 'codex_version' -Default '')
    }
  }

  if ($null -eq $Probe -or -not [bool](Get-PropValue -Object $Probe -Name 'codex_available' -Default $false)) {
    return [pscustomobject]@{
      key = $FeatureKey
      supported = $false
      support_source = 'command_probe'
      support_reason = 'codex_command_missing'
      feature_detected = $false
      feature_stage = ''
      cli_feature_enabled = $false
      minimum_version = $MinimumVersion
      codex_version = ''
    }
  }

  $features = Get-PropValue -Object $Probe -Name 'features' -Default @{}
  if (-not [string]::IsNullOrWhiteSpace($FeatureName) -and (Test-MapHasKey -Map $features -Key $FeatureName)) {
    $feature = $features[$FeatureName]
    $stage = [string](Get-PropValue -Object $feature -Name 'stage' -Default '')
    return [pscustomobject]@{
      key = $FeatureKey
      supported = ($stage -ne 'removed')
      support_source = 'features_list'
      support_reason = if ($stage -eq 'removed') { 'feature_removed' } else { 'feature_present' }
      feature_detected = $true
      feature_stage = $stage
      cli_feature_enabled = [bool](Get-PropValue -Object $feature -Name 'enabled' -Default $false)
      minimum_version = $MinimumVersion
      codex_version = [string](Get-PropValue -Object $Probe -Name 'codex_version' -Default '')
    }
  }

  $numericVersion = [string](Get-PropValue -Object $Probe -Name 'numeric_version' -Default '')
  if (-not [string]::IsNullOrWhiteSpace($numericVersion) -and (Test-VersionAtLeast -Candidate $numericVersion -Minimum $MinimumVersion)) {
    return [pscustomobject]@{
      key = $FeatureKey
      supported = $true
      support_source = 'version_fallback'
      support_reason = ('version_at_least_{0}' -f $MinimumVersion)
      feature_detected = $false
      feature_stage = ''
      cli_feature_enabled = $false
      minimum_version = $MinimumVersion
      codex_version = [string](Get-PropValue -Object $Probe -Name 'codex_version' -Default '')
    }
  }

  return [pscustomobject]@{
    key = $FeatureKey
    supported = $false
    support_source = 'version_fallback'
    support_reason = if ([string]::IsNullOrWhiteSpace($numericVersion)) { 'version_unknown' } else { ('version_below_{0}' -f $MinimumVersion) }
    feature_detected = $false
    feature_stage = ''
    cli_feature_enabled = $false
    minimum_version = $MinimumVersion
    codex_version = [string](Get-PropValue -Object $Probe -Name 'codex_version' -Default '')
  }
}

function Get-RaymanMultiAgentRegistry([string]$WorkspaceRoot) {
  $registryPath = Join-Path $WorkspaceRoot '.Rayman\config\codex_multi_agent.json'
  $config = Get-JsonOrNull -Path $registryPath
  $roles = New-Object System.Collections.Generic.List[object]
  $delegationRules = New-Object System.Collections.Generic.List[object]
  $valid = $true
  $registryError = ''

  if ($null -eq $config) {
    $valid = $false
    $registryError = 'registry_missing_or_invalid_json'
  } else {
    $schema = [string](Get-PropValue -Object $config -Name 'schema' -Default '')
    if ($schema -ne 'rayman.codex_multi_agent.v1') {
      $valid = $false
      $registryError = ('unexpected_schema:{0}' -f $schema)
    }

    $rolesRoot = Get-PropValue -Object $config -Name 'roles' -Default $null
    if ($null -eq $rolesRoot) {
      $valid = $false
      if ([string]::IsNullOrWhiteSpace($registryError)) {
        $registryError = 'roles_missing'
      }
    } else {
      $codexConfigDir = Join-Path $WorkspaceRoot '.codex'
      foreach ($prop in $rolesRoot.PSObject.Properties) {
        $role = $prop.Value
        $configFile = [string](Get-PropValue -Object $role -Name 'config_file' -Default '')
        $resolvedConfigPath = ''
        $configExists = $false
        if (-not [string]::IsNullOrWhiteSpace($configFile)) {
          try {
            $resolvedConfigPath = [System.IO.Path]::GetFullPath((Join-Path $codexConfigDir $configFile))
            $configExists = Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf
          } catch {
            $resolvedConfigPath = ''
            $configExists = $false
          }
        }

        $roles.Add([pscustomobject]@{
            name = [string]$prop.Name
            description = [string](Get-PropValue -Object $role -Name 'description' -Default '')
            config_file = $configFile
            resolved_config_path = $resolvedConfigPath
            config_exists = $configExists
            nickname_candidates = @(Convert-ToStringArray -Value (Get-PropValue -Object $role -Name 'nickname_candidates' -Default $null))
            mode = [string](Get-PropValue -Object $role -Name 'mode' -Default '')
            responsibility = [string](Get-PropValue -Object $role -Name 'responsibility' -Default '')
          }) | Out-Null
      }
    }

    foreach ($rule in @(Get-PropValue -Object $config -Name 'delegation_rules' -Default @())) {
      if ($null -eq $rule) { continue }
      $delegationRules.Add([pscustomobject]@{
          id = [string](Get-PropValue -Object $rule -Name 'id' -Default '')
          mode = [string](Get-PropValue -Object $rule -Name 'mode' -Default '')
          role = [string](Get-PropValue -Object $rule -Name 'role' -Default '')
          summary = [string](Get-PropValue -Object $rule -Name 'summary' -Default '')
        }) | Out-Null
    }
  }

  $detection = Get-PropValue -Object $config -Name 'detection' -Default $null
  $defaults = Get-PropValue -Object $config -Name 'defaults' -Default $null

  return [pscustomobject]@{
    path = $registryPath
    valid = $valid
    error = $registryError
    enabled = [bool](Get-PropValue -Object $config -Name 'enabled' -Default $true)
    env_toggle = [string](Get-PropValue -Object $config -Name 'env_toggle' -Default 'RAYMAN_CODEX_MULTI_AGENT_ENABLED')
    detection_feature_name = [string](Get-PropValue -Object $detection -Name 'feature_name' -Default 'multi_agent')
    detection_preferred_command = [string](Get-PropValue -Object $detection -Name 'preferred_command' -Default 'codex features list')
    minimum_version_fallback = [string](Get-PropValue -Object $detection -Name 'minimum_version_fallback' -Default '0.5.80')
    features_multi_agent = [bool](Get-PropValue -Object $defaults -Name 'features.multi_agent' -Default $true)
    max_threads = [int](Get-PropValue -Object $defaults -Name 'agents.max_threads' -Default 4)
    max_depth = [int](Get-PropValue -Object $defaults -Name 'agents.max_depth' -Default 2)
    job_max_runtime_seconds = [int](Get-PropValue -Object $defaults -Name 'agents.job_max_runtime_seconds' -Default 1800)
    roles = $roles.ToArray()
    delegation_rules = $delegationRules.ToArray()
  }
}

function Get-CodexMultiAgentSupportStatus([object]$Registry, [object]$Probe = $null) {
  if ($null -eq $Probe) {
    $Probe = Get-CodexFeatureProbe
  }
  $featureName = [string](Get-PropValue -Object $Registry -Name 'detection_feature_name' -Default 'multi_agent')
  $minimumVersion = [string](Get-PropValue -Object $Registry -Name 'minimum_version_fallback' -Default '0.5.80')
  $support = Get-CodexFeatureSupportStatus -Probe $Probe -FeatureKey 'multi_agent' -FeatureName $featureName -MinimumVersion $minimumVersion
  return [pscustomobject]@{
    codex_available = [bool](Get-PropValue -Object $Probe -Name 'codex_available' -Default $false)
    codex_version = [string](Get-PropValue -Object $Probe -Name 'codex_version' -Default '')
    supported = [bool]$support.supported
    support_source = [string]$support.support_source
    support_reason = [string]$support.support_reason
    feature_detected = [bool]$support.feature_detected
    feature_stage = [string]$support.feature_stage
    cli_feature_enabled = [bool]$support.cli_feature_enabled
  }
}

function Resolve-RaymanMultiAgentState {
  param(
    [object]$Registry,
    [object]$Support,
    [object]$TrustState
  )

  $envToggle = [string](Get-PropValue -Object $Registry -Name 'env_toggle' -Default 'RAYMAN_CODEX_MULTI_AGENT_ENABLED')
  $envEnabled = Get-EnvBoolCompat -Name $envToggle -Default $true
  $requestedEnabled = ([bool](Get-PropValue -Object $Registry -Name 'enabled' -Default $true) -and $envEnabled)
  $trustStatus = [string](Get-PropValue -Object $TrustState -Name 'status' -Default 'unknown')
  $trustAssumption = if ($trustStatus -eq 'trusted') { 'trusted' } else { 'assumed_allowed' }

  $degradedReason = ''
  $effective = $false
  if (-not [bool]$Registry.valid) {
    $degradedReason = 'multi_agent_registry_invalid'
  } elseif (-not [bool](Get-PropValue -Object $Registry -Name 'enabled' -Default $true)) {
    $degradedReason = 'multi_agent_config_disabled'
  } elseif (-not $envEnabled) {
    $degradedReason = 'multi_agent_env_disabled'
  } elseif (-not [bool]$Support.supported) {
    $degradedReason = [string]$Support.support_reason
  } elseif ($trustStatus -eq 'untrusted') {
    $degradedReason = ('workspace_not_trusted:{0}' -f $trustStatus)
    $trustAssumption = 'explicitly_untrusted'
  } else {
    $effective = $true
  }

  return [pscustomobject]@{
    env_toggle = $envToggle
    env_enabled = $envEnabled
    config_enabled = [bool](Get-PropValue -Object $Registry -Name 'enabled' -Default $true)
    requested_enabled = $requestedEnabled
    feature_name = [string](Get-PropValue -Object $Registry -Name 'detection_feature_name' -Default 'multi_agent')
    features_multi_agent = [bool](Get-PropValue -Object $Registry -Name 'features_multi_agent' -Default $true)
    max_threads = [int](Get-PropValue -Object $Registry -Name 'max_threads' -Default 4)
    max_depth = [int](Get-PropValue -Object $Registry -Name 'max_depth' -Default 2)
    job_max_runtime_seconds = [int](Get-PropValue -Object $Registry -Name 'job_max_runtime_seconds' -Default 1800)
    supported = [bool]$Support.supported
    support_source = [string]$Support.support_source
    support_reason = [string]$Support.support_reason
    feature_detected = [bool]$Support.feature_detected
    feature_stage = [string]$Support.feature_stage
    cli_feature_enabled = [bool]$Support.cli_feature_enabled
    codex_version = [string]$Support.codex_version
    trust_status = $trustStatus
    trust_assumption = $trustAssumption
    effective = $effective
    degraded_reason = $degradedReason
    should_write = ([bool]$Registry.valid -and $requestedEnabled -and [bool]$Support.supported)
    roles = @($Registry.roles)
    delegation_rules = @($Registry.delegation_rules)
  }
}

function Get-RaymanManagedSliceStates {
  param(
    [object]$CodexProbe,
    [object]$MultiAgentRegistry,
    [object]$MultiAgentState
  )

  $projectDocSupport = Get-CodexFeatureSupportStatus -Probe $CodexProbe -FeatureKey 'project_doc' -MinimumVersion '0.5.80'
  $profilesSupport = Get-CodexFeatureSupportStatus -Probe $CodexProbe -FeatureKey 'profiles' -MinimumVersion '0.5.80'
  $advancedSubagentsSupport = Get-CodexFeatureSupportStatus -Probe $CodexProbe -FeatureKey 'advanced_subagents' -MinimumVersion '0.5.80'

  return [ordered]@{
    capabilities = [pscustomobject]@{
      name = 'capabilities'
      supported = $true
      support_source = 'always'
      support_reason = 'rayman_managed'
      feature_detected = $false
      feature_stage = ''
      cli_feature_enabled = $false
      should_write = $true
    }
    project_doc = [pscustomobject]@{
      name = 'project_doc'
      supported = [bool]$projectDocSupport.supported
      support_source = [string]$projectDocSupport.support_source
      support_reason = [string]$projectDocSupport.support_reason
      feature_detected = [bool]$projectDocSupport.feature_detected
      feature_stage = [string]$projectDocSupport.feature_stage
      cli_feature_enabled = [bool]$projectDocSupport.cli_feature_enabled
      should_write = [bool]$projectDocSupport.supported
    }
    profiles = [pscustomobject]@{
      name = 'profiles'
      supported = [bool]$profilesSupport.supported
      support_source = [string]$profilesSupport.support_source
      support_reason = [string]$profilesSupport.support_reason
      feature_detected = [bool]$profilesSupport.feature_detected
      feature_stage = [string]$profilesSupport.feature_stage
      cli_feature_enabled = [bool]$profilesSupport.cli_feature_enabled
      should_write = [bool]$profilesSupport.supported
    }
    subagents = [pscustomobject]@{
      name = 'subagents'
      supported = ([bool]$MultiAgentState.supported -and [bool]$advancedSubagentsSupport.supported)
      support_source = if ([bool]$MultiAgentState.supported -and [bool]$advancedSubagentsSupport.supported) {
        if ([string]$advancedSubagentsSupport.support_source -eq 'always') { [string]$MultiAgentState.support_source } else { [string]$advancedSubagentsSupport.support_source }
      } elseif (-not [bool]$MultiAgentState.supported) {
        [string]$MultiAgentState.support_source
      } else {
        [string]$advancedSubagentsSupport.support_source
      }
      support_reason = if (-not [bool]$MultiAgentState.supported) {
        [string]$MultiAgentState.support_reason
      } elseif (-not [bool]$advancedSubagentsSupport.supported) {
        [string]$advancedSubagentsSupport.support_reason
      } else {
        'supported'
      }
      feature_detected = ([bool]$MultiAgentState.feature_detected -or [bool]$advancedSubagentsSupport.feature_detected)
      feature_stage = if ([bool]$MultiAgentState.feature_detected) { [string]$MultiAgentState.feature_stage } else { [string]$advancedSubagentsSupport.feature_stage }
      cli_feature_enabled = ([bool]$MultiAgentState.cli_feature_enabled -or [bool]$advancedSubagentsSupport.cli_feature_enabled)
      should_write = ([bool]$MultiAgentState.should_write -and [bool]$advancedSubagentsSupport.supported -and [bool]$MultiAgentRegistry.valid)
    }
  }
}

function Resolve-RaymanCapabilityState {
  param(
    [object]$Registry,
    [string]$WorkspaceRoot,
    [object]$RuntimeHostState
  )

  $globalEnabled = Get-EnvBoolCompat -Name 'RAYMAN_AGENT_CAPABILITIES_ENABLED' -Default $true
  $resolved = New-Object System.Collections.Generic.List[object]
  $hostIsWindows = Test-HostIsWindows
  $desktop = Get-WinAppDesktopSessionState
  $runtimeHost = [string](Get-PropValue -Object $RuntimeHostState -Name 'runtime_host' -Default '')
  if ([string]::IsNullOrWhiteSpace($runtimeHost)) { $runtimeHost = if ($hostIsWindows) { 'windows' } else { 'wsl' } }

  foreach ($capability in @($Registry.capabilities)) {
    $name = [string]$capability.name
    $toggleName = Get-CapabilityEnvToggleName -CapabilityName $name
    $envRaw = if ([string]::IsNullOrWhiteSpace($toggleName)) { '' } else { [string][Environment]::GetEnvironmentVariable($toggleName) }
    $envOverride = $null
    $activationSource = 'config'
    if (-not [string]::IsNullOrWhiteSpace($envRaw)) {
      $envOverride = Get-EnvBoolCompat -Name $toggleName -Default $true
      $activationSource = 'env_override'
    }

    $active = $true
    $statusReason = 'active'
    if (-not $Registry.valid) {
      $active = $false
      $statusReason = 'registry_invalid'
    } elseif (-not $globalEnabled) {
      $active = $false
      $statusReason = 'global_disabled'
    } elseif (-not [bool]$capability.enabled) {
      $active = $false
      $statusReason = 'config_disabled'
    } elseif ($null -ne $envOverride -and -not [bool]$envOverride) {
      $active = $false
      $statusReason = 'env_disabled'
    }

    if ($active -and $name -eq 'winapp_auto_test') {
      if ($runtimeHost -ne 'windows') {
        $active = $false
        $statusReason = 'runtime_host_not_windows'
      } else {
        $activationSource = 'runtime_host'
      }
    }

    $resolved.Add([pscustomobject]@{
        name = $name
        enabled = [bool]$capability.enabled
        provider = [string]$capability.provider
        kind = [string]$capability.kind
        mcp_id = [string]$capability.mcp_id
        url = [string]$capability.url
        command = [string]$capability.command
        args = @($capability.args)
        required = [bool]$capability.required
        prepare_command = [string]$capability.prepare_command
        fallback_command = [string]$capability.fallback_command
        triggers = @($capability.triggers)
        env_toggle = $toggleName
        active = $active
        status_reason = $statusReason
        degraded_reason = if ($active) { '' } else { $statusReason }
        activation_source = $activationSource
      }) | Out-Null
  }

  return [pscustomobject]@{
    global_enabled = $globalEnabled
    host_is_windows = $hostIsWindows
    desktop_session_available = [bool]$desktop.available
    desktop_session_reason = [string]$desktop.reason
    codex_runtime_host = $runtimeHost
    codex_runtime_host_source = [string](Get-PropValue -Object $RuntimeHostState -Name 'source' -Default '')
    runtime_host_state = $RuntimeHostState
    capabilities = $resolved.ToArray()
  }
}

function ConvertTo-TomlLiteralString([string]$Value) {
  if ($null -eq $Value) { return '""' }
  return ('"{0}"' -f (($Value -replace '\\', '\\\\') -replace '"', '\"'))
}

function ConvertTo-TomlArray([string[]]$Values) {
  $rendered = @()
  foreach ($value in @($Values)) {
    $rendered += (ConvertTo-TomlLiteralString -Value ([string]$value))
  }
  return ('[{0}]' -f ($rendered -join ', '))
}

function Get-PreferredPowerShellCommandName {
  if (Test-HostIsWindows) {
    $winPs = Get-Command 'powershell.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $winPs) {
      return 'powershell.exe'
    }
  }
  if ($null -ne (Get-Command 'pwsh' -ErrorAction SilentlyContinue | Select-Object -First 1)) {
    return 'pwsh'
  }
  if ($null -ne (Get-Command 'powershell.exe' -ErrorAction SilentlyContinue | Select-Object -First 1)) {
    return 'powershell.exe'
  }
  return 'powershell'
}

function Get-WinAppPreferredPowerShellCommandName {
  if (Test-HostIsWindows) {
    $winPs = Get-Command 'powershell.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $winPs) {
      return 'powershell.exe'
    }
  }
  return (Get-PreferredPowerShellCommandName)
}

function Get-WinAppCodexServerDefinition {
  param(
    [string]$WorkspaceRoot
  )

  $scriptPath = Join-Path $WorkspaceRoot '.Rayman\scripts\windows\winapp_mcp_server.ps1'
  return [pscustomobject]@{
    command = Get-WinAppPreferredPowerShellCommandName
    args = @(
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      [System.IO.Path]::GetFullPath($scriptPath),
      '-WorkspaceRoot',
      [System.IO.Path]::GetFullPath($WorkspaceRoot)
    )
  }
}

function Render-RaymanManagedCapabilitiesBlock {
  param(
    [object[]]$Capabilities,
    [string]$WorkspaceRoot
  )

  $activeCodexCapabilities = @($Capabilities | Where-Object { $_.active -and $_.provider -eq 'codex' })
  if ($activeCodexCapabilities.Count -eq 0) {
    return ''
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# >>> Rayman managed capabilities >>>')
  $lines.Add('# Rayman manages this block. Edit outside these markers only.')
  $lines.Add('')
  foreach ($capability in $activeCodexCapabilities) {
    $mcpId = [string]$capability.mcp_id
    if ([string]$capability.name -eq 'winapp_auto_test' -and [string]::IsNullOrWhiteSpace($mcpId)) {
      $mcpId = Get-WinAppManagedMcpId
    }
    if ([string]::IsNullOrWhiteSpace($mcpId)) { continue }

    $lines.Add(('[mcp_servers.{0}]' -f $mcpId))
    switch ([string]$capability.kind) {
      'codex_mcp_http' {
        $lines.Add(('url = {0}' -f (ConvertTo-TomlLiteralString -Value ([string]$capability.url))))
      }
      'codex_mcp_stdio_plus_rayman_fallback' {
        $command = [string]$capability.command
        $args = @($capability.args)
        if ([string]$capability.name -eq 'winapp_auto_test') {
          $winApp = Get-WinAppCodexServerDefinition -WorkspaceRoot $WorkspaceRoot
          $command = [string]$winApp.command
          $args = @($winApp.args)
        }
        $lines.Add(('command = {0}' -f (ConvertTo-TomlLiteralString -Value $command)))
        $lines.Add(('args = {0}' -f (ConvertTo-TomlArray -Values @($args))))
      }
    }
    $lines.Add(('enabled = {0}' -f ([string]([bool]$capability.active).ToString().ToLowerInvariant())))
    $lines.Add(('required = {0}' -f ([string]([bool]$capability.required).ToString().ToLowerInvariant())))
    $lines.Add('')
  }
  $lines.Add('# <<< Rayman managed capabilities <<<')
  return (($lines -join "`r`n").TrimEnd())
}

function Render-RaymanManagedProjectDocBlock {
  param(
    [object]$SliceState
  )

  if ($null -eq $SliceState -or -not [bool]$SliceState.should_write) {
    return ''
  }

  $maxBytes = Get-EnvIntCompat -Name 'RAYMAN_CODEX_PROJECT_DOC_MAX_BYTES' -Default 131072 -Min 8192 -Max 1048576
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# >>> Rayman managed project_doc >>>')
  $lines.Add('# Rayman manages this block. Edit outside these markers only.')
  $lines.Add('')
  $lines.Add('project_doc_fallback_filenames = ["agents.md"]')
  $lines.Add(('project_doc_max_bytes = {0}' -f $maxBytes))
  $lines.Add('# <<< Rayman managed project_doc <<<')
  return (($lines -join "`r`n").TrimEnd())
}

function Render-RaymanManagedProfilesBlock {
  param(
    [object]$SliceState
  )

  if ($null -eq $SliceState -or -not [bool]$SliceState.should_write) {
    return ''
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# >>> Rayman managed profiles >>>')
  $lines.Add('# Rayman manages this block. Edit outside these markers only.')
  $lines.Add('')

  $profiles = @(
    [pscustomobject]@{
      name = 'rayman_docs'
      model = 'gpt-5.4-mini'
      model_reasoning_effort = 'medium'
      sandbox_mode = 'read-only'
      web_search = 'live'
      tools_view_image = $false
      service_tier = 'flex'
    },
    [pscustomobject]@{
      name = 'rayman_review'
      model = 'gpt-5.4'
      model_reasoning_effort = 'high'
      sandbox_mode = 'read-only'
      web_search = 'live'
      tools_view_image = $false
      service_tier = 'flex'
    },
    [pscustomobject]@{
      name = 'rayman_browser'
      model = 'gpt-5.4'
      model_reasoning_effort = 'high'
      sandbox_mode = 'workspace-write'
      web_search = 'cached'
      tools_view_image = $true
      service_tier = 'flex'
    },
    [pscustomobject]@{
      name = 'rayman_winapp'
      model = 'gpt-5.4'
      model_reasoning_effort = 'high'
      sandbox_mode = 'workspace-write'
      web_search = 'cached'
      tools_view_image = $true
      service_tier = 'flex'
      windows_sandbox = 'unelevated'
    },
    [pscustomobject]@{
      name = 'rayman_fast'
      model = 'gpt-5.3-codex'
      model_reasoning_effort = 'low'
      sandbox_mode = 'read-only'
      web_search = 'cached'
      tools_view_image = $false
      service_tier = 'fast'
    }
  )

  foreach ($profile in $profiles) {
    $profileName = [string]$profile.name
    $lines.Add(('[profiles.{0}]' -f $profileName))
    $lines.Add(('model = {0}' -f (ConvertTo-TomlLiteralString -Value ([string]$profile.model))))
    $lines.Add(('model_reasoning_effort = {0}' -f (ConvertTo-TomlLiteralString -Value ([string]$profile.model_reasoning_effort))))
    $lines.Add(('sandbox_mode = {0}' -f (ConvertTo-TomlLiteralString -Value ([string]$profile.sandbox_mode))))
    $lines.Add(('web_search = {0}' -f (ConvertTo-TomlLiteralString -Value ([string]$profile.web_search))))
    $lines.Add(('tools_view_image = {0}' -f ([string]([bool]$profile.tools_view_image).ToString().ToLowerInvariant())))
    $lines.Add(('service_tier = {0}' -f (ConvertTo-TomlLiteralString -Value ([string]$profile.service_tier))))
    if ($profile.PSObject.Properties['windows_sandbox']) {
      $lines.Add('')
      $lines.Add(('[profiles.{0}.windows]' -f $profileName))
      $lines.Add(('sandbox = {0}' -f (ConvertTo-TomlLiteralString -Value ([string]$profile.windows_sandbox))))
    }
    $lines.Add('')
  }

  $lines.Add('# <<< Rayman managed profiles <<<')
  return (($lines -join "`r`n").TrimEnd())
}

function Render-RaymanManagedMultiAgentBlock {
  param(
    [object]$MultiAgentState,
    [object]$SliceState = $null
  )

  if ($null -eq $MultiAgentState -or -not [bool]$MultiAgentState.should_write) {
    return ''
  }
  if ($null -ne $SliceState -and -not [bool]$SliceState.should_write) {
    return ''
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# >>> Rayman managed subagents >>>')
  $lines.Add('# Rayman manages this block. Edit outside these markers only.')
  $lines.Add('')
  $lines.Add(('features.multi_agent = {0}' -f [string]([bool]$MultiAgentState.features_multi_agent).ToString().ToLowerInvariant()))
  $lines.Add(('agents.max_threads = {0}' -f [int]$MultiAgentState.max_threads))
  $lines.Add(('agents.max_depth = {0}' -f [int]$MultiAgentState.max_depth))
  $lines.Add(('agents.job_max_runtime_seconds = {0}' -f [int]$MultiAgentState.job_max_runtime_seconds))
  $lines.Add('')

  foreach ($role in @($MultiAgentState.roles)) {
    $roleName = [string]$role.name
    if ([string]::IsNullOrWhiteSpace($roleName)) { continue }
    $prefix = ('agents.{0}' -f $roleName)
    $lines.Add(('{0}.description = {1}' -f $prefix, (ConvertTo-TomlLiteralString -Value ([string]$role.description))))
    $lines.Add(('{0}.config_file = {1}' -f $prefix, (ConvertTo-TomlLiteralString -Value ([string]$role.config_file))))
    if (@($role.nickname_candidates).Count -gt 0) {
      $lines.Add(('{0}.nickname_candidates = {1}' -f $prefix, (ConvertTo-TomlArray -Values @($role.nickname_candidates))))
    }
    $lines.Add('')
  }

  $lines.Add('# <<< Rayman managed subagents <<<')
  return (($lines -join "`r`n").TrimEnd())
}

function Get-CodexConfigPrefixText {
  return @(
    '#:schema https://developers.openai.com/codex/config-schema.json'
    '# Rayman project-scoped Codex configuration.'
    '# Codex only loads .codex/config.toml after this project is trusted.'
    ''
  ) -join "`r`n"
}

function Set-RaymanManagedBlock {
  param(
    [string]$ConfigPath,
    [string]$ManagedBlock,
    [string]$BlockName
  )

  $startMarker = ('# >>> Rayman managed {0} >>>' -f $BlockName)
  $endMarker = ('# <<< Rayman managed {0} <<<' -f $BlockName)
  $pattern = ('(?s)[ \t]*{0}.*?{1}\r?\n?' -f [regex]::Escape($startMarker), [regex]::Escape($endMarker))
  $existing = ''
  if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    $existing = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
  }

  $updated = $existing
  $hadBlock = ($existing -match [regex]::Escape($startMarker) -and $existing -match [regex]::Escape($endMarker))
  if ([string]::IsNullOrWhiteSpace($ManagedBlock)) {
    if ($hadBlock) {
      $updated = [regex]::Replace($existing, $pattern, '', 1)
      $updated = $updated.TrimEnd()
      if (-not [string]::IsNullOrWhiteSpace($updated)) {
        $updated += "`r`n"
      }
    }
  } elseif ($hadBlock) {
    $updated = [regex]::Replace($existing, $pattern, ($ManagedBlock + "`r`n"), 1)
  } else {
    $prefix = if ([string]::IsNullOrWhiteSpace($existing)) { Get-CodexConfigPrefixText } else { $existing.TrimEnd() }
    if ([string]::IsNullOrWhiteSpace($prefix)) {
      $updated = ($ManagedBlock + "`r`n")
    } else {
      $updated = ($prefix + "`r`n`r`n" + $ManagedBlock + "`r`n")
    }
  }

  $changed = ($updated -ne $existing)
  if ($changed) {
    $configDir = Split-Path -Parent $ConfigPath
    Ensure-Dir -Path $configDir
    Write-Utf8NoBom -Path $ConfigPath -Content $updated
  }

  return [pscustomobject]@{
    changed = $changed
    had_block = $hadBlock
  }
}

function Set-RaymanManagedCapabilitiesBlock {
  param(
    [string]$ConfigPath,
    [string]$ManagedBlock
  )

  return (Set-RaymanManagedBlock -ConfigPath $ConfigPath -ManagedBlock $ManagedBlock -BlockName 'capabilities')
}

function Set-RaymanManagedProjectDocBlock {
  param(
    [string]$ConfigPath,
    [string]$ManagedBlock
  )

  return (Set-RaymanManagedBlock -ConfigPath $ConfigPath -ManagedBlock $ManagedBlock -BlockName 'project_doc')
}

function Set-RaymanManagedProfilesBlock {
  param(
    [string]$ConfigPath,
    [string]$ManagedBlock
  )

  return (Set-RaymanManagedBlock -ConfigPath $ConfigPath -ManagedBlock $ManagedBlock -BlockName 'profiles')
}

function Set-RaymanManagedSubagentsBlock {
  param(
    [string]$ConfigPath,
    [string]$ManagedBlock
  )

  return (Set-RaymanManagedBlock -ConfigPath $ConfigPath -ManagedBlock $ManagedBlock -BlockName 'subagents')
}

function Test-RaymanManagedBlockPresent {
  param(
    [string]$ConfigRaw,
    [string]$BlockName
  )

  if ([string]::IsNullOrWhiteSpace($ConfigRaw)) { return $false }
  $startMarker = ('# >>> Rayman managed {0} >>>' -f $BlockName)
  $endMarker = ('# <<< Rayman managed {0} <<<' -f $BlockName)
  return ($ConfigRaw -match [regex]::Escape($startMarker) -and $ConfigRaw -match [regex]::Escape($endMarker))
}

function Get-PlaywrightWindowsReadyState([string]$WorkspaceRoot) {
  $summaryPath = Join-Path $WorkspaceRoot '.Rayman\runtime\playwright.ready.windows.json'
  if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
    return [pscustomobject]@{
      host = 'windows'
      ready = $false
      reason = 'summary_missing'
      summary_path = $summaryPath
      detail_log = ''
    }
  }

  try {
    $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if (-not (Test-RaymanReportWorkspaceMatchesRoot -Report $summary -WorkspaceRoot $WorkspaceRoot)) {
      $reportRoot = Get-RaymanReportWorkspaceRoot -Report $summary
      return [pscustomobject]@{
        host = 'windows'
        ready = $false
        reason = ('stale_report_workspace_mismatch:{0}' -f $reportRoot)
        summary_path = $summaryPath
        detail_log = ''
      }
    }
    $success = [bool](Get-PropValue -Object $summary -Name 'success' -Default $false)
    return [pscustomobject]@{
      host = 'windows'
      ready = $success
      reason = if ($success) { 'summary_success' } else { 'summary_failed' }
      summary_path = $summaryPath
      detail_log = [string](Get-PropValue -Object $summary -Name 'detail_log' -Default '')
    }
  } catch {
    return [pscustomobject]@{
      host = 'windows'
      ready = $false
      reason = ('summary_parse_failed:{0}' -f $_.Exception.Message)
      summary_path = $summaryPath
      detail_log = ''
    }
  }
}

function Get-PlaywrightWslReadyState([string]$WorkspaceRoot) {
  $summaryPath = Join-Path $WorkspaceRoot '.Rayman\runtime\playwright.ready.wsl.json'
  if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
    return [pscustomobject]@{
      host = 'wsl'
      ready = $false
      reason = 'summary_missing'
      summary_path = $summaryPath
      detail_log = ''
    }
  }

  try {
    $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if (-not (Test-RaymanReportWorkspaceMatchesRoot -Report $summary -WorkspaceRoot $WorkspaceRoot)) {
      $reportRoot = Get-RaymanReportWorkspaceRoot -Report $summary
      return [pscustomobject]@{
        host = 'wsl'
        ready = $false
        reason = ('stale_report_workspace_mismatch:{0}' -f $reportRoot)
        summary_path = $summaryPath
        detail_log = ''
      }
    }
    $success = [bool](Get-PropValue -Object $summary -Name 'success' -Default $false)
    return [pscustomobject]@{
      host = 'wsl'
      ready = $success
      reason = if ($success) { 'summary_success' } else { 'summary_failed' }
      summary_path = $summaryPath
      detail_log = [string](Get-PropValue -Object $summary -Name 'detail_log' -Default '')
    }
  } catch {
    return [pscustomobject]@{
      host = 'wsl'
      ready = $false
      reason = ('summary_parse_failed:{0}' -f $_.Exception.Message)
      summary_path = $summaryPath
      detail_log = ''
    }
  }
}

function Get-PlaywrightReadyState {
  param(
    [string]$WorkspaceRoot,
    [object]$RuntimeHostState
  )

  $windowsState = Get-PlaywrightWindowsReadyState -WorkspaceRoot $WorkspaceRoot
  $wslState = Get-PlaywrightWslReadyState -WorkspaceRoot $WorkspaceRoot
  $currentHost = [string](Get-PropValue -Object $RuntimeHostState -Name 'current_host' -Default 'linux')
  $effectiveHost = [string](Get-PropValue -Object $RuntimeHostState -Name 'runtime_host' -Default $currentHost)

  $hostState = if ($currentHost -eq 'windows') { $windowsState } elseif ($currentHost -eq 'wsl') { $wslState } else { $wslState }
  $effectiveState = if ($effectiveHost -eq 'windows') { $windowsState } elseif ($effectiveHost -eq 'wsl') { $wslState } else { $wslState }

  return [pscustomobject]@{
    ready = [bool]$effectiveState.ready
    reason = [string]$effectiveState.reason
    summary_path = [string]$effectiveState.summary_path
    detail_log = [string](Get-PropValue -Object $effectiveState -Name 'detail_log' -Default '')
    current_host = $currentHost
    current_host_ready = [bool]$hostState.ready
    current_host_reason = [string]$hostState.reason
    current_host_summary_path = [string]$hostState.summary_path
    effective_host = $effectiveHost
    effective_ready = [bool]$effectiveState.ready
    effective_reason = [string]$effectiveState.reason
    effective_summary_path = [string]$effectiveState.summary_path
    windows = $windowsState
    wsl = $wslState
  }
}

function Get-WinAppWindowsReadyState([string]$WorkspaceRoot) {
  $summaryPath = Join-Path $WorkspaceRoot '.Rayman\runtime\winapp.ready.windows.json'
  if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
    try {
      $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      if (-not (Test-RaymanReportWorkspaceMatchesRoot -Report $summary -WorkspaceRoot $WorkspaceRoot)) {
        $reportRoot = Get-RaymanReportWorkspaceRoot -Report $summary
        return [pscustomobject]@{
          host = 'windows'
          ready = $false
          reason = ('stale_report_workspace_mismatch:{0}' -f $reportRoot)
          detail = ''
          summary_path = $summaryPath
        }
      }
      return [pscustomobject]@{
        host = 'windows'
        ready = [bool](Get-PropValue -Object $summary -Name 'ready' -Default $false)
        reason = [string](Get-PropValue -Object $summary -Name 'reason' -Default 'summary_missing_reason')
        detail = [string](Get-PropValue -Object $summary -Name 'detail' -Default '')
        summary_path = $summaryPath
      }
    } catch {
      return [pscustomobject]@{
        host = 'windows'
        ready = $false
        reason = ('summary_parse_failed:{0}' -f $_.Exception.Message)
        detail = ''
        summary_path = $summaryPath
      }
    }
  }

  return [pscustomobject]@{
    host = 'windows'
    ready = $false
    reason = 'summary_missing'
    detail = 'Run `rayman ensure-winapp` to materialize readiness report.'
    summary_path = $summaryPath
  }
}

function Get-WinAppReadyState {
  param(
    [string]$WorkspaceRoot,
    [object]$RuntimeHostState
  )

  $windowsState = Get-WinAppWindowsReadyState -WorkspaceRoot $WorkspaceRoot
  $currentHost = [string](Get-PropValue -Object $RuntimeHostState -Name 'current_host' -Default 'linux')
  $effectiveHost = [string](Get-PropValue -Object $RuntimeHostState -Name 'runtime_host' -Default $currentHost)

  $hostState = if ($currentHost -eq 'windows') {
    $windowsState
  } else {
    [pscustomobject]@{
      ready = $false
      reason = 'host_not_windows'
      detail = 'Windows desktop automation requires a Windows host.'
      summary_path = [string]$windowsState.summary_path
    }
  }

  $effectiveState = if ($effectiveHost -eq 'windows') {
    $windowsState
  } else {
    [pscustomobject]@{
      ready = $false
      reason = 'runtime_host_not_windows'
      detail = 'Codex runtime host is not Windows.'
      summary_path = [string]$windowsState.summary_path
    }
  }

  return [pscustomobject]@{
    ready = [bool]$effectiveState.ready
    reason = [string]$effectiveState.reason
    detail = [string](Get-PropValue -Object $effectiveState -Name 'detail' -Default '')
    summary_path = [string]$effectiveState.summary_path
    current_host = $currentHost
    current_host_ready = [bool]$hostState.ready
    current_host_reason = [string]$hostState.reason
    current_host_detail = [string](Get-PropValue -Object $hostState -Name 'detail' -Default '')
    effective_host = $effectiveHost
    effective_ready = [bool]$effectiveState.ready
    effective_reason = [string]$effectiveState.reason
    windows = $windowsState
  }
}

function Invoke-RaymanCapabilityPrepare {
  param(
    [object]$Capability,
    [string]$WorkspaceRoot
  )

  $skipPrepare = Get-EnvBoolCompat -Name 'RAYMAN_AGENT_CAPABILITIES_SKIP_PREPARE' -Default $false
  if ($skipPrepare) {
    return [pscustomobject]@{
      attempted = $false
      success = $true
      exit_code = 0
      reason = 'prepare_skipped_by_env'
    }
  }

  if ([string]::IsNullOrWhiteSpace([string]$Capability.prepare_command)) {
    return [pscustomobject]@{
      attempted = $false
      success = $true
      exit_code = 0
      reason = 'prepare_not_defined'
    }
  }

  if ([string]$Capability.name -ne 'web_auto_test') {
    return [pscustomobject]@{
      attempted = $false
      success = $true
      exit_code = 0
      reason = 'prepare_manual_only'
    }
  }

  $raymanCli = Join-Path $WorkspaceRoot '.Rayman\rayman.ps1'
  if (-not (Test-Path -LiteralPath $raymanCli -PathType Leaf)) {
    return [pscustomobject]@{
      attempted = $false
      success = $false
      exit_code = 1
      reason = 'rayman_cli_missing'
    }
  }

  if (-not $Json) {
    Write-CapInfo ('[agent-cap] prepare -> {0}' -f [string]$Capability.prepare_command)
  }

  try {
    if (Test-Path variable:LASTEXITCODE) {
      $global:LASTEXITCODE = 0
    }
    & $raymanCli 'ensure-playwright' '--WorkspaceRoot' $WorkspaceRoot | Out-Host
    $exitCode = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }
    return [pscustomobject]@{
      attempted = $true
      success = ($exitCode -eq 0)
      exit_code = $exitCode
      reason = if ($exitCode -eq 0) { 'prepare_success' } else { ('prepare_failed:{0}' -f $exitCode) }
    }
  } catch {
    return [pscustomobject]@{
      attempted = $true
      success = $false
      exit_code = 1
      reason = ('prepare_exception:{0}' -f $_.Exception.Message)
    }
  }
}

function New-CapabilityReportObject {
  param(
    [string]$Action,
    [string]$WorkspaceRoot,
    [object]$Registry,
    [object]$State,
    [object]$RuntimeHostState,
    [object]$CodexProbe,
    [object]$MultiAgentRegistry,
    [object]$MultiAgentState,
    [hashtable]$ManagedSliceStates,
    [string]$CodexConfigPath,
    [object]$TrustState,
    [hashtable]$ManagedBlockPresence,
    [hashtable]$ManagedBlockChanges,
    [object]$PrepareResult,
    [object]$PlaywrightState,
    [object]$WinAppState
  )

  $configRaw = ''
  if (Test-Path -LiteralPath $CodexConfigPath -PathType Leaf) {
    $configRaw = Get-Content -LiteralPath $CodexConfigPath -Raw -Encoding UTF8
  }

  $pathNormalizationStatus = 'native'
  $workspaceVariants = @()
  if (Get-Command Get-RaymanPathComparisonVariants -ErrorAction SilentlyContinue) {
    $workspaceVariants = @(Get-RaymanPathComparisonVariants -PathValue $WorkspaceRoot)
  }
  if ($workspaceVariants.Count -gt 1) {
    $pathNormalizationStatus = 'windows_wsl_equivalent'
  }

  $customAgentsPresent = Test-Path -LiteralPath (Join-Path $WorkspaceRoot '.github\agents') -PathType Container
  $skillsPresent = Test-Path -LiteralPath (Join-Path $WorkspaceRoot '.github\skills') -PathType Container
  $projectProfilesWritten = $false
  $subagentsWritten = $false

  $sliceReports = [ordered]@{}
  foreach ($sliceName in @('capabilities', 'project_doc', 'profiles', 'subagents')) {
    $sliceState = if (Test-MapHasKey -Map $ManagedSliceStates -Key $sliceName) { $ManagedSliceStates[$sliceName] } else { $null }
    $present = if (Test-MapHasKey -Map $ManagedBlockPresence -Key $sliceName) { [bool]$ManagedBlockPresence[$sliceName] } else { $false }
    $changed = if (Test-MapHasKey -Map $ManagedBlockChanges -Key $sliceName) { [bool]$ManagedBlockChanges[$sliceName] } else { $false }
    $sliceReports[$sliceName] = [pscustomobject]@{
      present = $present
      changed = $changed
      supported = [bool](Get-PropValue -Object $sliceState -Name 'supported' -Default $false)
      support_source = [string](Get-PropValue -Object $sliceState -Name 'support_source' -Default '')
      support_reason = [string](Get-PropValue -Object $sliceState -Name 'support_reason' -Default '')
      should_write = [bool](Get-PropValue -Object $sliceState -Name 'should_write' -Default $false)
      feature_detected = [bool](Get-PropValue -Object $sliceState -Name 'feature_detected' -Default $false)
      feature_stage = [string](Get-PropValue -Object $sliceState -Name 'feature_stage' -Default '')
      cli_feature_enabled = [bool](Get-PropValue -Object $sliceState -Name 'cli_feature_enabled' -Default $false)
    }
  }

  $capabilityReports = New-Object System.Collections.Generic.List[object]
  foreach ($capability in @($State.capabilities)) {
    $written = $false
    if (-not [string]::IsNullOrWhiteSpace($configRaw) -and -not [string]::IsNullOrWhiteSpace([string]$capability.mcp_id)) {
      $written = ($configRaw -match [regex]::Escape([string]$capability.mcp_id))
    }

    $playwrightReady = $null
    $winAppReady = $null
    if ([string]$capability.name -eq 'web_auto_test') {
      $playwrightReady = [bool]$PlaywrightState.ready
    }
    if ([string]$capability.name -eq 'winapp_auto_test') {
      $winAppReady = [bool]$WinAppState.ready
    }

    $capabilityReports.Add([pscustomobject]@{
        name = [string]$capability.name
        active = [bool]$capability.active
        status_reason = [string]$capability.status_reason
        degraded_reason = [string](Get-PropValue -Object $capability -Name 'degraded_reason' -Default '')
        activation_source = [string](Get-PropValue -Object $capability -Name 'activation_source' -Default '')
        provider = [string]$capability.provider
        kind = [string]$capability.kind
        mcp_id = [string]$capability.mcp_id
        written_to_codex_config = $written
        fallback_command = [string]$capability.fallback_command
        prepare_command = [string]$capability.prepare_command
        triggers = @($capability.triggers)
        playwright_ready = $playwrightReady
        winapp_ready = $winAppReady
      }) | Out-Null
  }

  $roleReports = New-Object System.Collections.Generic.List[object]
  foreach ($role in @($MultiAgentState.roles)) {
    $roleName = [string]$role.name
    $written = $false
    if (-not [string]::IsNullOrWhiteSpace($configRaw) -and -not [string]::IsNullOrWhiteSpace($roleName)) {
      $written = ($configRaw -match [regex]::Escape(('agents.{0}.description' -f $roleName)) -and $configRaw -match [regex]::Escape(('agents.{0}.config_file' -f $roleName)))
    }
    if ($written) { $subagentsWritten = $true }

    $roleReports.Add([pscustomobject]@{
        name = $roleName
        description = [string]$role.description
        mode = [string]$role.mode
        responsibility = [string]$role.responsibility
        config_file = [string]$role.config_file
        resolved_config_path = [string]$role.resolved_config_path
        config_exists = [bool]$role.config_exists
        nickname_candidates = @($role.nickname_candidates)
        written_to_codex_config = $written
      }) | Out-Null
  }

  $activeNames = @($capabilityReports | Where-Object { $_.active } | ForEach-Object { [string]$_.name })
  $degradedReasons = @($capabilityReports | Where-Object { -not $_.active } | ForEach-Object { ('{0}:{1}' -f $_.name, $_.status_reason) })
  $multiAgentRoleNames = @($roleReports | ForEach-Object { [string]$_.name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $delegationRules = @($MultiAgentState.delegation_rules | ForEach-Object {
      [pscustomobject]@{
        id = [string]$_.id
        mode = [string]$_.mode
        role = [string]$_.role
        summary = [string]$_.summary
      }
    })

  if (Test-MapHasKey -Map $sliceReports -Key 'profiles') {
    $projectProfilesWritten = [bool]$sliceReports['profiles'].present
  }

  return [pscustomobject]@{
    schema = 'rayman.agent_capabilities.report.v1'
    generated_at = (Get-Date).ToString('o')
    action = $Action
    workspace_root = $WorkspaceRoot
    registry_path = [string]$Registry.path
    registry_valid = [bool]$Registry.valid
    registry_error = [string]$Registry.error
    global_enabled = [bool]$State.global_enabled
    host_is_windows = [bool]$State.host_is_windows
    desktop_session_available = [bool]$State.desktop_session_available
    desktop_session_reason = [string]$State.desktop_session_reason
    codex_available = [bool](Get-PropValue -Object $CodexProbe -Name 'codex_available' -Default $false)
    codex_version = [string](Get-PropValue -Object $CodexProbe -Name 'codex_version' -Default '')
    codex_runtime_host = [string](Get-PropValue -Object $RuntimeHostState -Name 'runtime_host' -Default '')
    codex_runtime_host_source = [string](Get-PropValue -Object $RuntimeHostState -Name 'source' -Default '')
    codex_runtime_host_setting = Get-PropValue -Object $RuntimeHostState -Name 'run_in_wsl' -Default $null
    codex_runtime_settings_path = [string](Get-PropValue -Object $RuntimeHostState -Name 'settings_path' -Default '')
    path_normalization_status = $pathNormalizationStatus
    workspace_trust_status = [string]$TrustState.status
    workspace_trust_reason = [string]$TrustState.reason
    workspace_trust_config_path = [string]$TrustState.config_path
    codex_config_path = $CodexConfigPath
    codex_config_exists = (Test-Path -LiteralPath $CodexConfigPath -PathType Leaf)
    managed_block_present = [bool]$sliceReports['capabilities'].present
    project_doc_managed_block_present = [bool]$sliceReports['project_doc'].present
    profiles_managed_block_present = [bool]$sliceReports['profiles'].present
    multi_agent_managed_block_present = [bool]$sliceReports['subagents'].present
    capability_block_changed = [bool]$sliceReports['capabilities'].changed
    project_doc_block_changed = [bool]$sliceReports['project_doc'].changed
    profiles_block_changed = [bool]$sliceReports['profiles'].changed
    multi_agent_block_changed = [bool]$sliceReports['subagents'].changed
    config_file_changed = (@($sliceReports.Values | Where-Object { $_.changed }).Count -gt 0)
    managed_slices = $sliceReports
    project_profiles_written = $projectProfilesWritten
    subagents_written = $subagentsWritten
    custom_agents_present = $customAgentsPresent
    skills_present = $skillsPresent
    active_capabilities = @($activeNames)
    degraded_reasons = @($degradedReasons)
    multi_agent_config_path = [string]$MultiAgentRegistry.path
    multi_agent_config_valid = [bool]$MultiAgentRegistry.valid
    multi_agent_config_error = [string]$MultiAgentRegistry.error
    multi_agent_enabled = [bool]$MultiAgentState.config_enabled
    multi_agent_env_toggle = [string]$MultiAgentState.env_toggle
    multi_agent_env_enabled = [bool]$MultiAgentState.env_enabled
    multi_agent_requested = [bool]$MultiAgentState.requested_enabled
    multi_agent_feature_name = [string]$MultiAgentState.feature_name
    multi_agent_supported = [bool]$MultiAgentState.supported
    multi_agent_support_source = [string]$MultiAgentState.support_source
    multi_agent_support_reason = [string]$MultiAgentState.support_reason
    multi_agent_feature_detected = [bool]$MultiAgentState.feature_detected
    multi_agent_feature_stage = [string]$MultiAgentState.feature_stage
    multi_agent_cli_feature_enabled = [bool]$MultiAgentState.cli_feature_enabled
    multi_agent_trust_status = [string](Get-PropValue -Object $MultiAgentState -Name 'trust_status' -Default '')
    multi_agent_trust_assumption = [string](Get-PropValue -Object $MultiAgentState -Name 'trust_assumption' -Default '')
    multi_agent_effective = [bool]$MultiAgentState.effective
    multi_agent_degraded_reason = [string]$MultiAgentState.degraded_reason
    multi_agent_roles = @($multiAgentRoleNames)
    multi_agent_roles_detail = $roleReports.ToArray()
    multi_agent_delegation_rules = @($delegationRules)
    prepare = [pscustomobject]@{
      attempted = [bool]$PrepareResult.attempted
      success = [bool]$PrepareResult.success
      exit_code = [int]$PrepareResult.exit_code
      reason = [string]$PrepareResult.reason
    }
    playwright = [pscustomobject]@{
      ready = [bool]$PlaywrightState.ready
      reason = [string]$PlaywrightState.reason
      summary_path = [string]$PlaywrightState.summary_path
      detail_log = [string](Get-PropValue -Object $PlaywrightState -Name 'detail_log' -Default '')
      current_host = [string](Get-PropValue -Object $PlaywrightState -Name 'current_host' -Default '')
      current_host_ready = [bool](Get-PropValue -Object $PlaywrightState -Name 'current_host_ready' -Default $false)
      current_host_reason = [string](Get-PropValue -Object $PlaywrightState -Name 'current_host_reason' -Default '')
      effective_host = [string](Get-PropValue -Object $PlaywrightState -Name 'effective_host' -Default '')
      effective_ready = [bool](Get-PropValue -Object $PlaywrightState -Name 'effective_ready' -Default $false)
      effective_reason = [string](Get-PropValue -Object $PlaywrightState -Name 'effective_reason' -Default '')
      current_host_summary_path = [string](Get-PropValue -Object $PlaywrightState -Name 'current_host_summary_path' -Default '')
      effective_summary_path = [string](Get-PropValue -Object $PlaywrightState -Name 'effective_summary_path' -Default '')
    }
    winapp = [pscustomobject]@{
      ready = [bool]$WinAppState.ready
      reason = [string]$WinAppState.reason
      detail = [string](Get-PropValue -Object $WinAppState -Name 'detail' -Default '')
      summary_path = [string]$WinAppState.summary_path
      current_host = [string](Get-PropValue -Object $WinAppState -Name 'current_host' -Default '')
      current_host_ready = [bool](Get-PropValue -Object $WinAppState -Name 'current_host_ready' -Default $false)
      current_host_reason = [string](Get-PropValue -Object $WinAppState -Name 'current_host_reason' -Default '')
      current_host_detail = [string](Get-PropValue -Object $WinAppState -Name 'current_host_detail' -Default '')
      effective_host = [string](Get-PropValue -Object $WinAppState -Name 'effective_host' -Default '')
      effective_ready = [bool](Get-PropValue -Object $WinAppState -Name 'effective_ready' -Default $false)
      effective_reason = [string](Get-PropValue -Object $WinAppState -Name 'effective_reason' -Default '')
    }
    capabilities = $capabilityReports.ToArray()
  }
}

function Write-CapabilityReportFiles {
  param(
    [object]$Report,
    [string]$JsonPath,
    [string]$MarkdownPath
  )

  Ensure-Dir -Path (Split-Path -Parent $JsonPath)
  ($Report | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $JsonPath -Encoding UTF8

  $activeCaps = @($Report.active_capabilities | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $md = New-Object System.Collections.Generic.List[string]
  $md.Add(('- Global enabled: `{0}`' -f [string]([bool]$Report.global_enabled).ToString().ToLowerInvariant()))
  $md.Add(('- Registry valid: `{0}`' -f [string]([bool]$Report.registry_valid).ToString().ToLowerInvariant()))
  $md.Add(('- Codex command available: `{0}`' -f [string]([bool]$Report.codex_available).ToString().ToLowerInvariant()))
  $md.Add(('- Codex version: `{0}`' -f [string]$Report.codex_version))
  $md.Add(('- Codex runtime host: `{0}` ({1})' -f [string]$Report.codex_runtime_host, [string]$Report.codex_runtime_host_source))
  $md.Add(('- Workspace trust: `{0}` ({1})' -f [string]$Report.workspace_trust_status, [string]$Report.workspace_trust_reason))
  $md.Add(('- Codex config: `{0}`' -f [string]$Report.codex_config_path))
  $md.Add(('- Path normalization: `{0}`' -f [string]$Report.path_normalization_status))
  $md.Add(('- Host Windows: `{0}`' -f [string]([bool]$Report.host_is_windows).ToString().ToLowerInvariant()))
  $md.Add(('- Desktop session: `{0}` ({1})' -f [string]([bool]$Report.desktop_session_available).ToString().ToLowerInvariant(), [string]$Report.desktop_session_reason))
  $md.Add(('- Active capabilities: {0}' -f ($(if ($activeCaps.Count -gt 0) { ($activeCaps -join ', ') } else { '(none)' }))))
  $md.Add(('- Multi-agent config: `{0}` (valid: `{1}`)' -f [string]$Report.multi_agent_config_path, [string]([bool]$Report.multi_agent_config_valid).ToString().ToLowerInvariant()))
  $md.Add(('- Multi-agent requested: `{0}` (env `{1}`=`{2}`)' -f [string]([bool]$Report.multi_agent_requested).ToString().ToLowerInvariant(), [string]$Report.multi_agent_env_toggle, [string]([bool]$Report.multi_agent_env_enabled).ToString().ToLowerInvariant()))
  $md.Add(('- Multi-agent supported/effective: `{0}` / `{1}` ({2})' -f [string]([bool]$Report.multi_agent_supported).ToString().ToLowerInvariant(), [string]([bool]$Report.multi_agent_effective).ToString().ToLowerInvariant(), $(if ([string]::IsNullOrWhiteSpace([string]$Report.multi_agent_degraded_reason)) { 'ok' } else { [string]$Report.multi_agent_degraded_reason })))
  $md.Add(('- Multi-agent trust gate: `{0}` ({1})' -f [string]$Report.multi_agent_trust_status, [string]$Report.multi_agent_trust_assumption))
  $md.Add(('- Multi-agent roles: {0}' -f $(if (@($Report.multi_agent_roles).Count -gt 0) { ((@($Report.multi_agent_roles) | ForEach-Object { [string]$_ }) -join ', ') } else { '(none)' })))
  $md.Add(('- Custom agents present: `{0}`; skills present: `{1}`' -f [string]([bool]$Report.custom_agents_present).ToString().ToLowerInvariant(), [string]([bool]$Report.skills_present).ToString().ToLowerInvariant()))
  foreach ($sliceName in @('capabilities', 'project_doc', 'profiles', 'subagents')) {
    $slice = $null
    if ($Report.managed_slices -is [System.Collections.IDictionary]) {
      $slice = $Report.managed_slices[$sliceName]
    } else {
      $slice = Get-PropValue -Object $Report.managed_slices -Name $sliceName -Default $null
    }
    if ($null -eq $slice) { continue }
    $md.Add(('- slice {0}: present=`{1}`, changed=`{2}`, supported=`{3}`, should_write=`{4}`, reason=`{5}`' -f $sliceName, [string]([bool]$slice.present).ToString().ToLowerInvariant(), [string]([bool]$slice.changed).ToString().ToLowerInvariant(), [string]([bool]$slice.supported).ToString().ToLowerInvariant(), [string]([bool]$slice.should_write).ToString().ToLowerInvariant(), [string]$slice.support_reason))
  }
  $md.Add(('- Playwright ready: `{0}` ({1}); host=`{2}` runtime=`{3}`' -f [string]([bool]$Report.playwright.ready).ToString().ToLowerInvariant(), [string]$Report.playwright.reason, [string]$Report.playwright.current_host, [string]$Report.playwright.effective_host))
  $md.Add(('- WinApp ready: `{0}` ({1}); host=`{2}` runtime=`{3}`' -f [string]([bool]$Report.winapp.ready).ToString().ToLowerInvariant(), [string]$Report.winapp.reason, [string]$Report.winapp.current_host, [string]$Report.winapp.effective_host))
  foreach ($capability in @($Report.capabilities)) {
    $line = ('- {0}: active=`{1}`, written=`{2}`' -f [string]$capability.name, [string]([bool]$capability.active).ToString().ToLowerInvariant(), [string]([bool]$capability.written_to_codex_config).ToString().ToLowerInvariant())
    if ([string]$capability.name -eq 'web_auto_test') {
      $line += (', playwright_ready=`{0}`' -f [string]([bool]$Report.playwright.ready).ToString().ToLowerInvariant())
    }
    if ([string]$capability.name -eq 'winapp_auto_test') {
      $line += (', winapp_ready=`{0}`' -f [string]([bool]$Report.winapp.ready).ToString().ToLowerInvariant())
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$capability.status_reason)) {
      $line += (', reason=`{0}`' -f [string]$capability.status_reason)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$capability.activation_source)) {
      $line += (', activation=`{0}`' -f [string]$capability.activation_source)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$capability.fallback_command)) {
      $line += (', fallback=`{0}`' -f [string]$capability.fallback_command)
    }
    $md.Add($line)
  }
  foreach ($role in @($Report.multi_agent_roles_detail)) {
    $roleLine = ('- subagent {0}: config=`{1}`, exists=`{2}`, written=`{3}`' -f [string]$role.name, [string]$role.config_file, [string]([bool]$role.config_exists).ToString().ToLowerInvariant(), [string]([bool]$role.written_to_codex_config).ToString().ToLowerInvariant())
    if (-not [string]::IsNullOrWhiteSpace([string]$role.mode)) {
      $roleLine += (', mode=`{0}`' -f [string]$role.mode)
    }
    $md.Add($roleLine)
  }
  Write-Utf8NoBom -Path $MarkdownPath -Content (($md -join "`r`n") + "`r`n")
}

$resolvedWorkspaceRoot = if (Get-Command Resolve-RaymanLiteralPath -ErrorAction SilentlyContinue) {
  Resolve-RaymanLiteralPath -PathValue $WorkspaceRoot
} else {
  (Resolve-Path -LiteralPath $WorkspaceRoot).Path
}
if ([string]::IsNullOrWhiteSpace($resolvedWorkspaceRoot) -or -not (Test-Path -LiteralPath $resolvedWorkspaceRoot -PathType Container)) {
  throw ("Workspace root not found: {0}" -f $WorkspaceRoot)
}
$WorkspaceRoot = $resolvedWorkspaceRoot
$runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime'
$codexDir = Join-Path $WorkspaceRoot '.codex'
$codexConfigPath = Join-Path $codexDir 'config.toml'
$reportJsonPath = Join-Path $runtimeDir 'agent_capabilities.report.json'
$reportMarkdownPath = Join-Path $runtimeDir 'agent_capabilities.report.md'

Ensure-Dir -Path $runtimeDir

$registry = Get-RaymanCapabilityRegistry -WorkspaceRoot $WorkspaceRoot
$runtimeHostState = Get-CodexRuntimeHostState -WorkspaceRoot $WorkspaceRoot
$state = Resolve-RaymanCapabilityState -Registry $registry -WorkspaceRoot $WorkspaceRoot -RuntimeHostState $runtimeHostState
$trustState = Get-CodexProjectTrustStatus -WorkspaceRoot $WorkspaceRoot
$multiAgentRegistry = Get-RaymanMultiAgentRegistry -WorkspaceRoot $WorkspaceRoot
$codexProbe = Get-CodexFeatureProbe
$multiAgentSupport = Get-CodexMultiAgentSupportStatus -Registry $multiAgentRegistry -Probe $codexProbe
$multiAgentState = Resolve-RaymanMultiAgentState -Registry $multiAgentRegistry -Support $multiAgentSupport -TrustState $trustState
$managedSliceStates = Get-RaymanManagedSliceStates -CodexProbe $codexProbe -MultiAgentRegistry $multiAgentRegistry -MultiAgentState $multiAgentState
$managedBlock = Render-RaymanManagedCapabilitiesBlock -Capabilities $state.capabilities -WorkspaceRoot $WorkspaceRoot
$projectDocBlock = Render-RaymanManagedProjectDocBlock -SliceState $managedSliceStates['project_doc']
$profilesBlock = Render-RaymanManagedProfilesBlock -SliceState $managedSliceStates['profiles']
$multiAgentBlock = Render-RaymanManagedMultiAgentBlock -MultiAgentState $multiAgentState -SliceState $managedSliceStates['subagents']
$managedBlockChanges = @{
  capabilities = $false
  project_doc = $false
  profiles = $false
  subagents = $false
}
$prepareResult = [pscustomobject]@{
  attempted = $false
  success = $true
  exit_code = 0
  reason = 'prepare_not_run'
}

if ($Action -eq 'sync') {
  $syncResult = Set-RaymanManagedCapabilitiesBlock -ConfigPath $codexConfigPath -ManagedBlock $managedBlock
  $managedBlockChanges['capabilities'] = [bool]$syncResult.changed
  $projectDocSyncResult = Set-RaymanManagedProjectDocBlock -ConfigPath $codexConfigPath -ManagedBlock $projectDocBlock
  $managedBlockChanges['project_doc'] = [bool]$projectDocSyncResult.changed
  $profilesSyncResult = Set-RaymanManagedProfilesBlock -ConfigPath $codexConfigPath -ManagedBlock $profilesBlock
  $managedBlockChanges['profiles'] = [bool]$profilesSyncResult.changed
  $multiAgentSyncResult = Set-RaymanManagedSubagentsBlock -ConfigPath $codexConfigPath -ManagedBlock $multiAgentBlock
  $managedBlockChanges['subagents'] = [bool]$multiAgentSyncResult.changed

  $webAutoTest = $state.capabilities | Where-Object { $_.name -eq 'web_auto_test' } | Select-Object -First 1
  if ($null -ne $webAutoTest -and [bool]$webAutoTest.active) {
    $prepareResult = Invoke-RaymanCapabilityPrepare -Capability $webAutoTest -WorkspaceRoot $WorkspaceRoot
  }

  if (@($managedBlockChanges.Values | Where-Object { $_ }).Count -gt 0) {
    Write-CapInfo ('[agent-cap] synced: {0}' -f $codexConfigPath)
  } else {
    Write-CapInfo ('[agent-cap] already up to date: {0}' -f $codexConfigPath)
  }
}

$managedBlockPresence = @{
  capabilities = $false
  project_doc = $false
  profiles = $false
  subagents = $false
}
if (Test-Path -LiteralPath $codexConfigPath -PathType Leaf) {
  $codexRaw = Get-Content -LiteralPath $codexConfigPath -Raw -Encoding UTF8
  $managedBlockPresence['capabilities'] = Test-RaymanManagedBlockPresent -ConfigRaw $codexRaw -BlockName 'capabilities'
  $managedBlockPresence['project_doc'] = Test-RaymanManagedBlockPresent -ConfigRaw $codexRaw -BlockName 'project_doc'
  $managedBlockPresence['profiles'] = Test-RaymanManagedBlockPresent -ConfigRaw $codexRaw -BlockName 'profiles'
  $managedBlockPresence['subagents'] = Test-RaymanManagedBlockPresent -ConfigRaw $codexRaw -BlockName 'subagents'
}

$playwrightState = Get-PlaywrightReadyState -WorkspaceRoot $WorkspaceRoot -RuntimeHostState $runtimeHostState
$winAppState = Get-WinAppReadyState -WorkspaceRoot $WorkspaceRoot -RuntimeHostState $runtimeHostState
$report = New-CapabilityReportObject -Action $Action -WorkspaceRoot $WorkspaceRoot -Registry $registry -State $state -RuntimeHostState $runtimeHostState -CodexProbe $codexProbe -MultiAgentRegistry $multiAgentRegistry -MultiAgentState $multiAgentState -ManagedSliceStates $managedSliceStates -CodexConfigPath $codexConfigPath -TrustState $trustState -ManagedBlockPresence $managedBlockPresence -ManagedBlockChanges $managedBlockChanges -PrepareResult $prepareResult -PlaywrightState $playwrightState -WinAppState $winAppState
Write-CapabilityReportFiles -Report $report -JsonPath $reportJsonPath -MarkdownPath $reportMarkdownPath

if ($Json) {
  $report | ConvertTo-Json -Depth 10
} else {
  Write-CapInfo ('[agent-cap] report: {0}' -f $reportMarkdownPath)
  if ($report.active_capabilities.Count -gt 0) {
    Write-CapInfo ('[agent-cap] active: {0}' -f (($report.active_capabilities | ForEach-Object { [string]$_ }) -join ', '))
  } else {
    Write-CapWarn '[agent-cap] no active capabilities.'
  }
  Write-CapInfo ('[agent-cap] runtime host: {0} ({1})' -f [string]$report.codex_runtime_host, [string]$report.codex_runtime_host_source)
  Write-CapInfo ('[agent-cap] multi-agent supported/effective: {0}/{1}' -f [string]([bool]$report.multi_agent_supported).ToString().ToLowerInvariant(), [string]([bool]$report.multi_agent_effective).ToString().ToLowerInvariant())
}
