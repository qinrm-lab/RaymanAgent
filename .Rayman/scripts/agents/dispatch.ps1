param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [string]$TaskKind = 'general',
  [string]$Task = '',
  [string]$PromptKey = '',
  [string]$PreferredBackend = '',
  [string]$Command = '',
  [switch]$PolicyBypass,
  [string]$BypassReason = '',
  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-EnvBoolCompat([string]$Name, [bool]$Default) {
  $raw = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
  return ($raw -ne '0' -and $raw -ne 'false' -and $raw -ne 'False')
}

function Get-EnvStringCompat([string]$Name, [string]$Default = '') {
  $raw = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
  return [string]$raw
}

function Get-EnvListCompat([string]$Name) {
  $raw = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
  $vals = @($raw.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  return @($vals)
}

function Test-HostIsWindowsCompat {
  try {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
  } catch {
    return $false
  }
}

function Get-WinAppDesktopSessionStateCompat {
  if (-not (Test-HostIsWindowsCompat)) {
    return [pscustomobject]@{
      available = $false
      reason = 'host_not_windows'
    }
  }

  $userInteractive = $false
  try {
    $userInteractive = [Environment]::UserInteractive
  } catch {
    $userInteractive = $false
  }

  if (-not $userInteractive) {
    return [pscustomobject]@{
      available = $false
      reason = 'desktop_session_unavailable'
    }
  }

  return [pscustomobject]@{
    available = $true
    reason = 'interactive_desktop'
  }
}

function Ensure-Dir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Convert-ToStringArray([object]$Value) {
  if ($null -eq $Value) { return @() }
  $list = New-Object System.Collections.Generic.List[string]
  foreach ($item in @($Value)) {
    $s = [string]$item
    if (-not [string]::IsNullOrWhiteSpace($s)) { $list.Add($s.Trim()) | Out-Null }
  }
  return @($list)
}

function Get-PropValue([object]$Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  $prop = $Object.PSObject.Properties[$Name]
  if ($null -eq $prop) { return $Default }
  return $prop.Value
}

function Resolve-RouteDefinition {
  param(
    [object]$ModelRoutingConfig,
    [string]$RouteKey
  )

  $normalizedRouteKey = ([string]$RouteKey).Trim()
  if ([string]::IsNullOrWhiteSpace($normalizedRouteKey)) {
    $normalizedRouteKey = 'ui_selected'
  }

  $providers = Get-PropValue -Object $ModelRoutingConfig -Name 'providers' -Default $null
  $route = Get-PropValue -Object $providers -Name $normalizedRouteKey -Default $null
  $provider = ''
  $selector = ''
  if ($null -ne $route) {
    $provider = [string](Get-PropValue -Object $route -Name 'provider' -Default '')
    $selector = [string](Get-PropValue -Object $route -Name 'selector' -Default '')
  }

  if ([string]::IsNullOrWhiteSpace($provider)) {
    if ($normalizedRouteKey -eq 'ui_selected') {
      $provider = 'ui_selected'
      $selector = 'ui_selected'
    } else {
      $provider = $normalizedRouteKey
    }
  }

  $preserveUi = ($provider -eq 'ui_selected' -or $normalizedRouteKey -eq 'ui_selected')
  $resolvedModel = if ($preserveUi) {
    'ui_selected'
  } elseif (-not [string]::IsNullOrWhiteSpace($selector)) {
    ('{0}.{1}' -f $provider, $selector)
  } else {
    $provider
  }

  return [pscustomobject]@{
    route_key = $normalizedRouteKey
    provider = $provider
    selector = $selector
    preserve_ui = $preserveUi
    resolved_model = $resolvedModel
  }
}

function Get-JsonOrNull([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Resolve-ModelRouting {
  param(
    [object]$ModelRoutingConfig,
    [string]$TaskKindText,
    [string]$PromptKeyText
  )

  $normalizedTaskKind = ([string]$TaskKindText).Trim().ToLowerInvariant()
  $effectiveTaskKey = $normalizedTaskKind
  $routeKey = ''
  $source = ''

  $taskAliases = Get-PropValue -Object $ModelRoutingConfig -Name 'task_aliases' -Default $null
  if (-not [string]::IsNullOrWhiteSpace($effectiveTaskKey)) {
    $taskAlias = Get-PropValue -Object $taskAliases -Name $effectiveTaskKey -Default $null
    if (-not [string]::IsNullOrWhiteSpace([string]$taskAlias)) {
      $effectiveTaskKey = ([string]$taskAlias).Trim().ToLowerInvariant()
    }
  }

  $normalizedPromptKey = ([string]$PromptKeyText).Trim()
  if (-not [string]::IsNullOrWhiteSpace($normalizedPromptKey)) {
    $promptRoutes = Get-PropValue -Object $ModelRoutingConfig -Name 'prompt_routes' -Default $null
    $promptRoute = Get-PropValue -Object $promptRoutes -Name $normalizedPromptKey -Default $null
    if (-not [string]::IsNullOrWhiteSpace([string]$promptRoute)) {
      $routeKey = ([string]$promptRoute).Trim()
      $source = 'prompt_route'
    }
  }

  if ([string]::IsNullOrWhiteSpace($routeKey)) {
    $tasks = Get-PropValue -Object $ModelRoutingConfig -Name 'tasks' -Default $null
    $taskConfig = Get-PropValue -Object $tasks -Name $effectiveTaskKey -Default $null
    $taskModel = Get-PropValue -Object $taskConfig -Name 'model' -Default $null
    if (-not [string]::IsNullOrWhiteSpace([string]$taskModel)) {
      $routeKey = ([string]$taskModel).Trim()
      $source = 'task_config'
    }
  }

  if ([string]::IsNullOrWhiteSpace($routeKey)) {
    $defaults = Get-PropValue -Object $ModelRoutingConfig -Name 'defaults' -Default $null
    $defaultRoute = Get-PropValue -Object $defaults -Name 'route' -Default $null
    if ([string]::IsNullOrWhiteSpace([string]$defaultRoute)) {
      $defaultRoute = Get-PropValue -Object $defaults -Name 'model' -Default $null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$defaultRoute)) {
      $routeKey = ([string]$defaultRoute).Trim()
      $source = 'defaults'
    }
  }

  if ([string]::IsNullOrWhiteSpace($routeKey)) {
    $routeKey = 'ui_selected'
    $source = 'implicit_default'
  }

  $routeDefinition = Resolve-RouteDefinition -ModelRoutingConfig $ModelRoutingConfig -RouteKey $routeKey

  return [pscustomobject]@{
    effective_task_key = $effectiveTaskKey
    prompt_key = $normalizedPromptKey
    source = $source
    route_key = [string]$routeDefinition.route_key
    provider = [string]$routeDefinition.provider
    selector = [string]$routeDefinition.selector
    preserve_ui = [bool]$routeDefinition.preserve_ui
    resolved_model = [string]$routeDefinition.resolved_model
  }
}

function Get-AgentCapabilityEnvName([string]$CapabilityName) {
  $normalized = ([string]$CapabilityName).Trim().ToLowerInvariant()
  switch ($normalized) {
    'openai_docs' { return 'RAYMAN_AGENT_CAP_OPENAI_DOCS_ENABLED' }
    'web_auto_test' { return 'RAYMAN_AGENT_CAP_WEB_AUTO_TEST_ENABLED' }
    default {
      return ('RAYMAN_AGENT_CAP_{0}_ENABLED' -f (($normalized -replace '[^a-z0-9]+', '_').ToUpperInvariant()))
    }
  }
}

function Get-AgentCapabilityRegistry {
  param(
    [string]$WorkspaceRoot
  )

  $path = Join-Path $WorkspaceRoot '.Rayman\config\agent_capabilities.json'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return [pscustomobject]@{
      path = $path
      valid = $false
      schema = ''
      error = 'missing_registry'
      capabilities = @()
    }
  }

  try {
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $schema = [string](Get-PropValue -Object $raw -Name 'schema' -Default '')
    $capabilities = Get-PropValue -Object $raw -Name 'capabilities' -Default $null
    return [pscustomobject]@{
      path = $path
      valid = ($schema -eq 'rayman.agent_capabilities.v1' -and $null -ne $capabilities)
      schema = $schema
      error = ''
      capabilities = $capabilities
    }
  } catch {
    return [pscustomobject]@{
      path = $path
      valid = $false
      schema = ''
      error = $_.Exception.Message
      capabilities = @()
    }
  }
}

function Resolve-AgentCapabilityState {
  param(
    [object]$Registry
  )

  $globalEnabled = Get-EnvBoolCompat -Name 'RAYMAN_AGENT_CAPABILITIES_ENABLED' -Default $true
  $hostIsWindows = Test-HostIsWindowsCompat
  $desktop = Get-WinAppDesktopSessionStateCompat
  $resolved = New-Object System.Collections.Generic.List[object]

  if ($null -eq $Registry -or -not [bool]$Registry.valid) {
    return [pscustomobject]@{
      registry_path = [string](Get-PropValue -Object $Registry -Name 'path' -Default '')
      registry_valid = $false
      registry_error = [string](Get-PropValue -Object $Registry -Name 'error' -Default 'invalid_registry')
      global_enabled = $globalEnabled
      capabilities = @()
    }
  }

  foreach ($prop in $Registry.capabilities.PSObject.Properties) {
    $name = [string]$prop.Name
    $config = $prop.Value
    $registryEnabled = [bool](Get-PropValue -Object $config -Name 'enabled' -Default $true)
    $envName = Get-AgentCapabilityEnvName -CapabilityName $name
    $envEnabled = Get-EnvBoolCompat -Name $envName -Default $true
    $active = ($globalEnabled -and $registryEnabled -and $envEnabled)
    $statusReason = 'active'
    if (-not $globalEnabled) {
      $statusReason = 'global_disabled'
    } elseif (-not $registryEnabled) {
      $statusReason = 'registry_disabled'
    } elseif (-not $envEnabled) {
      $statusReason = 'env_disabled'
    }

    if ($active -and $name -eq 'winapp_auto_test') {
      if (-not $hostIsWindows) {
        $active = $false
        $statusReason = 'host_not_windows'
      } elseif (-not [bool]$desktop.available) {
        $active = $false
        $statusReason = [string]$desktop.reason
      }
    }

    $resolved.Add([pscustomobject]@{
        name = $name
        provider = [string](Get-PropValue -Object $config -Name 'provider' -Default '')
        kind = [string](Get-PropValue -Object $config -Name 'kind' -Default '')
        mcp_id = [string](Get-PropValue -Object $config -Name 'mcp_id' -Default '')
        required = [bool](Get-PropValue -Object $config -Name 'required' -Default $false)
        command = [string](Get-PropValue -Object $config -Name 'command' -Default '')
        args = @(Convert-ToStringArray -Value (Get-PropValue -Object $config -Name 'args' -Default $null))
        prepare_command = [string](Get-PropValue -Object $config -Name 'prepare_command' -Default '')
        fallback_command = [string](Get-PropValue -Object $config -Name 'fallback_command' -Default '')
        triggers = @(Convert-ToStringArray -Value (Get-PropValue -Object $config -Name 'triggers' -Default $null))
        active = $active
        registry_enabled = $registryEnabled
        env_name = $envName
        env_enabled = $envEnabled
        status_reason = $statusReason
      }) | Out-Null
  }

  return [pscustomobject]@{
    registry_path = [string]$Registry.path
    registry_valid = $true
    registry_error = ''
    global_enabled = $globalEnabled
    host_is_windows = $hostIsWindows
    desktop_session_available = [bool]$desktop.available
    desktop_session_reason = [string]$desktop.reason
    capabilities = @($resolved)
  }
}

function Get-AgentCapabilityMatches {
  param(
    [object]$CapabilityState,
    [string]$TaskKindText,
    [string]$PromptKeyText,
    [string]$TaskText,
    [string]$CommandText
  )

  $texts = [ordered]@{
    task_kind = ([string]$TaskKindText).Trim().ToLowerInvariant()
    prompt_key = ([string]$PromptKeyText).Trim().ToLowerInvariant()
    task = ([string]$TaskText).Trim().ToLowerInvariant()
    command = ([string]$CommandText).Trim().ToLowerInvariant()
  }

  $matches = New-Object System.Collections.Generic.List[object]
  $activeMatches = New-Object System.Collections.Generic.List[object]

  foreach ($capability in @($CapabilityState.capabilities)) {
    $matchedTriggers = New-Object System.Collections.Generic.List[string]
    foreach ($trigger in @($capability.triggers)) {
      $needle = ([string]$trigger).Trim().ToLowerInvariant()
      if ([string]::IsNullOrWhiteSpace($needle)) { continue }
      foreach ($fieldName in $texts.Keys) {
        $haystack = [string]$texts[$fieldName]
        if (-not [string]::IsNullOrWhiteSpace($haystack) -and $haystack.Contains($needle)) {
          if ($matchedTriggers -notcontains $needle) {
            $matchedTriggers.Add($needle) | Out-Null
          }
          break
        }
      }
    }

    if ($matchedTriggers.Count -eq 0) { continue }

    $match = [pscustomobject]@{
      name = [string]$capability.name
      provider = [string]$capability.provider
      kind = [string]$capability.kind
      mcp_id = [string]$capability.mcp_id
      active = [bool]$capability.active
      status_reason = [string]$capability.status_reason
      prepare_command = [string]$capability.prepare_command
      fallback_command = [string]$capability.fallback_command
      matched_triggers = @($matchedTriggers)
    }

    $matches.Add($match) | Out-Null
    if ([bool]$capability.active) {
      $activeMatches.Add($match) | Out-Null
    }
  }

  return [pscustomobject]@{
    all_matches = @($matches)
    active_matches = @($activeMatches)
  }
}

function Build-AgentCapabilityPreamble {
  param(
    [object[]]$CapabilityMatches
  )

  $matches = @($CapabilityMatches)
  if ($matches.Count -eq 0) { return '' }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('[RaymanCapabilityHints]')
  $lines.Add(('matched={0}' -f (($matches | ForEach-Object { [string]$_.name }) -join ',')))
  foreach ($match in $matches) {
    $capabilityName = [string]$match.name
    switch ($capabilityName) {
      'openai_docs' {
        $lines.Add('openai_docs=Prefer OpenAI Docs MCP (openaiDeveloperDocs). Use official docs and avoid stale memory.')
      }
      'web_auto_test' {
        $fallback = [string]$match.fallback_command
        if ([string]::IsNullOrWhiteSpace($fallback)) {
          $fallback = 'rayman pwa-test'
        }
        $lines.Add(('web_auto_test=Prefer Playwright MCP (playwright). If unavailable, fall back to `{0}`.' -f $fallback))
      }
      'winapp_auto_test' {
        $fallback = [string]$match.fallback_command
        if ([string]::IsNullOrWhiteSpace($fallback)) {
          $fallback = 'rayman winapp-test'
        }
        $lines.Add(('winapp_auto_test=Prefer Rayman Windows desktop MCP (raymanWinApp) for WinForms/MAUI desktop automation. If unavailable, fall back to `{0}`.' -f $fallback))
      }
      default {
        $message = ('{0}=Prefer capability MCP `{1}` when relevant.' -f $capabilityName, [string]$match.mcp_id)
        if (-not [string]::IsNullOrWhiteSpace([string]$match.fallback_command)) {
          $message += (' Fallback=`{0}`.' -f [string]$match.fallback_command)
        }
        $lines.Add($message)
      }
    }
  }
  $lines.Add('[/RaymanCapabilityHints]')
  return ($lines -join "`n")
}

function Get-NowTimestamp() {
  return (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
}

function Write-PolicyBypassDecision {
  param(
    [string]$WorkspaceRoot,
    [string]$RuntimeDir,
    [string]$RunId,
    [string]$BlockedReason,
    [string]$BypassReason
  )

  if ([string]::IsNullOrWhiteSpace($RuntimeDir) -or [string]::IsNullOrWhiteSpace($BypassReason)) { return }
  if (-not (Test-Path -LiteralPath $RuntimeDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
  }

  $decisionLog = Join-Path $RuntimeDir 'decision.log'
  $line = "{0} gate=agent-pre-dispatch action=BYPASS run_id={1} blocked_reason={2} reason={3}" -f (Get-NowTimestamp), $RunId, $BlockedReason, $BypassReason
  Add-Content -LiteralPath $decisionLog -Encoding UTF8 -Value $line

  try {
    $maintainer = Join-Path $WorkspaceRoot '.Rayman\scripts\release\maintain_decision_log.ps1'
    if (Test-Path -LiteralPath $maintainer -PathType Leaf) {
      & $maintainer -WorkspaceRoot $WorkspaceRoot -LogPath $decisionLog -SummaryPath (Join-Path $RuntimeDir 'decision.summary.tsv') | Out-Null
    }
  } catch {}
}

function Test-CommandExists([string]$Name) {
  return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-WhitelistMatch([string[]]$Whitelist, [string]$RepoName, [string]$RepoPath) {
  if ($Whitelist.Count -eq 0) { return $false }
  $repoNameNorm = $RepoName.ToLowerInvariant()
  $repoPathNorm = $RepoPath.Replace('\', '/').Trim().ToLowerInvariant()
  foreach ($entry in $Whitelist) {
    $e = [string]$entry
    if ([string]::IsNullOrWhiteSpace($e)) { continue }
    $n = $e.Replace('\', '/').Trim().ToLowerInvariant()
    if ($n -eq '*') { return $true }
    if ($n -eq $repoNameNorm -or $n -eq $repoPathNorm) { return $true }
  }
  return $false
}

function Add-UniqueBackend([System.Collections.Generic.List[string]]$List, [string]$Backend) {
  if ([string]::IsNullOrWhiteSpace($Backend)) { return }
  $b = $Backend.Trim().ToLowerInvariant()
  if ($null -ne $script:KnownBackends -and $script:KnownBackends.Count -gt 0) {
    if ($script:KnownBackends -notcontains $b) { return }
  } elseif (@('copilot', 'codex', 'local') -notcontains $b) {
    return
  }
  if ($List -notcontains $b) { $List.Add($b) | Out-Null }
}

function Test-BackendAvailability {
  param(
    [object]$RouterConfig,
    [string]$Backend,
    [bool]$CloudEnabled,
    [bool]$WhitelistMatch
  )

  $backendName = ([string]$Backend).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($backendName)) {
    return [pscustomobject]@{ available = $false; reason = 'empty_backend'; cloud_backend = $false }
  }

  if ($backendName -eq 'local') {
    return [pscustomobject]@{ available = $true; reason = 'local_available'; cloud_backend = $false }
  }

  $backendRequirements = Get-PropValue -Object $RouterConfig -Name 'backend_requirements' -Default $null
  $requirement = Get-PropValue -Object $backendRequirements -Name $backendName -Default $null
  if ($null -eq $requirement) {
    return [pscustomobject]@{ available = $false; reason = 'unknown_backend'; cloud_backend = $false }
  }

  $allowCloud = [bool](Get-PropValue -Object $requirement -Name 'allow_cloud' -Default $false)
  if ($allowCloud -and -not $CloudEnabled) {
    return [pscustomobject]@{ available = $false; reason = 'cloud_disabled'; cloud_backend = $true }
  }
  if ($allowCloud -and -not $WhitelistMatch) {
    return [pscustomobject]@{ available = $false; reason = 'cloud_not_whitelisted'; cloud_backend = $true }
  }

  $commands = @(Convert-ToStringArray -Value (Get-PropValue -Object $requirement -Name 'commands_any' -Default $null))
  $envNames = @(Convert-ToStringArray -Value (Get-PropValue -Object $requirement -Name 'env_any' -Default $null))
  $hasCommand = ($commands.Count -eq 0)
  foreach ($cmd in $commands) {
    if (Test-CommandExists -Name $cmd) {
      $hasCommand = $true
      break
    }
  }
  $hasEnv = ($envNames.Count -eq 0)
  foreach ($envName in $envNames) {
    if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($envName))) {
      $hasEnv = $true
      break
    }
  }

  $available = $hasCommand -or $hasEnv
  $reason = if ($available) { ('{0}_ready' -f $backendName) } else { 'missing_command_or_env' }
  return [pscustomobject]@{
    available = $available
    reason = $reason
    cloud_backend = $allowCloud
  }
}

function Get-ModelRoutingFallbackBehavior([object]$ModelRoutingConfig) {
  $defaults = Get-PropValue -Object $ModelRoutingConfig -Name 'defaults' -Default $null
  $fallbackBehavior = [string](Get-PropValue -Object $ModelRoutingConfig -Name 'fallback_behavior' -Default '')
  if ([string]::IsNullOrWhiteSpace($fallbackBehavior)) {
    $fallbackBehavior = [string](Get-PropValue -Object $defaults -Name 'fallback_behavior' -Default '')
  }
  if ([string]::IsNullOrWhiteSpace($fallbackBehavior)) {
    $fallbackBehavior = 'preserve_current_flow'
  }
  return $fallbackBehavior.Trim().ToLowerInvariant()
}

function Get-ModelRouteFallbackOrder([object]$ModelRoutingConfig) {
  $defaults = Get-PropValue -Object $ModelRoutingConfig -Name 'defaults' -Default $null
  $fallbackOrder = @(Convert-ToStringArray -Value (Get-PropValue -Object $ModelRoutingConfig -Name 'route_fallback_order' -Default $null))
  if ($fallbackOrder.Count -eq 0) {
    $fallbackOrder = @(Convert-ToStringArray -Value (Get-PropValue -Object $defaults -Name 'route_fallback_order' -Default $null))
  }
  return @($fallbackOrder)
}

function Get-ModelManualFallbackRoute([object]$ModelRoutingConfig) {
  $defaults = Get-PropValue -Object $ModelRoutingConfig -Name 'defaults' -Default $null
  $manualFallbackRoute = [string](Get-PropValue -Object $ModelRoutingConfig -Name 'manual_fallback_route' -Default '')
  if ([string]::IsNullOrWhiteSpace($manualFallbackRoute)) {
    $manualFallbackRoute = [string](Get-PropValue -Object $defaults -Name 'manual_fallback_route' -Default '')
  }
  if ([string]::IsNullOrWhiteSpace($manualFallbackRoute)) {
    $manualFallbackRoute = 'ui_selected'
  }
  return $manualFallbackRoute.Trim()
}

function Get-ModelRouteCandidateChain {
  param(
    [object]$ModelRoutingConfig,
    [object]$RequestedModelResolution
  )

  $candidates = New-Object System.Collections.Generic.List[string]
  $requestedRouteKey = [string](Get-PropValue -Object $RequestedModelResolution -Name 'route_key' -Default 'ui_selected')
  if ([string]::IsNullOrWhiteSpace($requestedRouteKey)) {
    $requestedRouteKey = 'ui_selected'
  }
  $requestedRouteKey = $requestedRouteKey.Trim()
  if ($candidates -notcontains $requestedRouteKey) {
    $candidates.Add($requestedRouteKey) | Out-Null
  }

  if ([bool](Get-PropValue -Object $RequestedModelResolution -Name 'preserve_ui' -Default $false)) {
    return @($candidates)
  }

  $fallbackBehavior = Get-ModelRoutingFallbackBehavior -ModelRoutingConfig $ModelRoutingConfig
  if ($fallbackBehavior -eq 'preserve_current_flow') {
    return @($candidates)
  }

  $fallbackOrder = @(Get-ModelRouteFallbackOrder -ModelRoutingConfig $ModelRoutingConfig)
  if ($fallbackOrder.Count -gt 0) {
    $requestedIndex = [Array]::IndexOf($fallbackOrder, $requestedRouteKey)
    if ($requestedIndex -ge 0) {
      for ($i = $requestedIndex + 1; $i -lt $fallbackOrder.Count; $i++) {
        $candidateRoute = ([string]$fallbackOrder[$i]).Trim()
        if (-not [string]::IsNullOrWhiteSpace($candidateRoute) -and $candidates -notcontains $candidateRoute) {
          $candidates.Add($candidateRoute) | Out-Null
        }
      }
    } else {
      foreach ($candidateRoute in $fallbackOrder) {
        $routeText = ([string]$candidateRoute).Trim()
        if (-not [string]::IsNullOrWhiteSpace($routeText) -and $candidates -notcontains $routeText) {
          $candidates.Add($routeText) | Out-Null
        }
      }
    }
  }

  $manualFallbackRoute = Get-ModelManualFallbackRoute -ModelRoutingConfig $ModelRoutingConfig
  if (-not [string]::IsNullOrWhiteSpace($manualFallbackRoute) -and $candidates -notcontains $manualFallbackRoute) {
    $candidates.Add($manualFallbackRoute) | Out-Null
  }

  return @($candidates)
}

function Resolve-EffectiveModelRouting {
  param(
    [object]$ModelRoutingConfig,
    [object]$RequestedModelResolution,
    [object]$RouterConfig,
    [bool]$CloudEnabled,
    [bool]$WhitelistMatch
  )

  $routeCandidates = @(Get-ModelRouteCandidateChain -ModelRoutingConfig $ModelRoutingConfig -RequestedModelResolution $RequestedModelResolution)
  $availability = [ordered]@{}

  foreach ($routeAlias in $routeCandidates) {
    $routeDefinition = Resolve-RouteDefinition -ModelRoutingConfig $ModelRoutingConfig -RouteKey ([string]$routeAlias)
    if ([bool]$routeDefinition.preserve_ui) {
      $availability[[string]$routeDefinition.route_key] = [ordered]@{
        route_key = [string]$routeDefinition.route_key
        provider = [string]$routeDefinition.provider
        selector = [string]$routeDefinition.selector
        resolved_model = [string]$routeDefinition.resolved_model
        preserve_ui = [bool]$routeDefinition.preserve_ui
        available = $true
        reason = 'manual_route_preserved'
        cloud_backend = $false
      }

      return [pscustomobject]@{
        selected = $routeDefinition
        candidate_chain = @($routeCandidates)
        availability = $availability
        selection_reason = 'selected:manual_route_preserved'
      }
    }

    $backendAvailability = Test-BackendAvailability -RouterConfig $RouterConfig -Backend ([string]$routeDefinition.provider) -CloudEnabled $CloudEnabled -WhitelistMatch $WhitelistMatch
    $availability[[string]$routeDefinition.route_key] = [ordered]@{
      route_key = [string]$routeDefinition.route_key
      provider = [string]$routeDefinition.provider
      selector = [string]$routeDefinition.selector
      resolved_model = [string]$routeDefinition.resolved_model
      preserve_ui = [bool]$routeDefinition.preserve_ui
      available = [bool]$backendAvailability.available
      reason = [string]$backendAvailability.reason
      cloud_backend = [bool]$backendAvailability.cloud_backend
    }

    if ([bool]$backendAvailability.available) {
      return [pscustomobject]@{
        selected = $routeDefinition
        candidate_chain = @($routeCandidates)
        availability = $availability
        selection_reason = ('selected:{0}' -f [string]$backendAvailability.reason)
      }
    }
  }

  return [pscustomobject]@{
    selected = $RequestedModelResolution
    candidate_chain = @($routeCandidates)
    availability = $availability
    selection_reason = 'selected:requested_route_unavailable'
  }
}

function Build-SystemSlimDispatchPrompt {
  param(
    [string]$TaskText,
    [string]$CommandText,
    [string]$TaskKindText,
    [string]$WorkspaceRoot,
    [string]$CapabilityPreamble = ''
  )

  $body = ''
  if (-not [string]::IsNullOrWhiteSpace($TaskText)) {
    $body = ("TaskKind={0}`nWorkspace={1}`nTask={2}" -f $TaskKindText, $WorkspaceRoot, $TaskText.Trim())
  } elseif (-not [string]::IsNullOrWhiteSpace($CommandText)) {
    $body = ("TaskKind={0}`nWorkspace={1}`nRunCommand={2}" -f $TaskKindText, $WorkspaceRoot, $CommandText.Trim())
  } elseif (-not [string]::IsNullOrWhiteSpace($TaskKindText)) {
    $body = ("TaskKind={0}`nWorkspace={1}`nGoal=Please execute {0} workflow and report actionable result." -f $TaskKindText.Trim(), $WorkspaceRoot)
  } else {
    $body = ("Workspace={0}`nGoal=Please execute general engineering task and report actionable result." -f $WorkspaceRoot)
  }

  if (-not [string]::IsNullOrWhiteSpace($CapabilityPreamble)) {
    return ($CapabilityPreamble.Trim() + "`n" + $body)
  }
  return $body
}

function Test-PolicyBlocked {
  param(
    [object]$PolicyConfig,
    [string]$CommandText,
    [string]$TaskText
  )

  if ($null -eq $PolicyConfig) {
    return [pscustomobject]@{ blocked = $false; reason = '' }
  }

  $hooks = $PolicyConfig.hooks
  if ($null -eq $hooks -or $null -eq $hooks.pre_dispatch) {
    return [pscustomobject]@{ blocked = $false; reason = '' }
  }
  $pre = $hooks.pre_dispatch
  $enabled = $true
  if ($null -ne $pre.PSObject.Properties['enabled']) {
    $enabled = [bool]$pre.enabled
  }
  if (-not $enabled) {
    return [pscustomobject]@{ blocked = $false; reason = '' }
  }

  foreach ($rx in Convert-ToStringArray -Value $pre.blocked_commands) {
    if (-not [string]::IsNullOrWhiteSpace($CommandText) -and $CommandText -match $rx) {
      return [pscustomobject]@{ blocked = $true; reason = ("blocked_command:{0}" -f $rx) }
    }
  }
  foreach ($token in Convert-ToStringArray -Value $pre.blocked_path_tokens) {
    if ((-not [string]::IsNullOrWhiteSpace($CommandText) -and $CommandText.Contains($token)) -or (-not [string]::IsNullOrWhiteSpace($TaskText) -and $TaskText.Contains($token))) {
      return [pscustomobject]@{ blocked = $true; reason = ("blocked_path_token:{0}" -f $token) }
    }
  }
  return [pscustomobject]@{ blocked = $false; reason = '' }
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$raymanDir = Join-Path $WorkspaceRoot '.Rayman'
$runtimeDir = Join-Path $raymanDir 'runtime'
$runsDir = Join-Path $runtimeDir 'agent_runs'
$logsDir = Join-Path $raymanDir 'logs'
Ensure-Dir -Path $runtimeDir
Ensure-Dir -Path $runsDir
Ensure-Dir -Path $logsDir

$routerConfigPath = Join-Path $raymanDir 'config\agent_router.json'
$policyConfigPath = Join-Path $raymanDir 'config\agent_policy.json'
$modelRoutingPath = Join-Path $raymanDir 'config\model_routing.json'
$capabilityRegistry = Get-AgentCapabilityRegistry -WorkspaceRoot $WorkspaceRoot
$capabilityState = Resolve-AgentCapabilityState -Registry $capabilityRegistry
$routerConfig = Get-JsonOrNull -Path $routerConfigPath
$policyConfig = Get-JsonOrNull -Path $policyConfigPath
$modelRoutingConfig = Get-JsonOrNull -Path $modelRoutingPath

$script:KnownBackends = @('copilot', 'codex', 'local')
$backendRequirements = Get-PropValue -Object $routerConfig -Name 'backend_requirements' -Default $null
if ($null -ne $backendRequirements) {
  $tmpKnownBackends = @($backendRequirements.PSObject.Properties.Name | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  if ($tmpKnownBackends.Count -gt 0) {
    $script:KnownBackends = @($tmpKnownBackends)
    if ($script:KnownBackends -notcontains 'local') {
      $script:KnownBackends += 'local'
    }
  }
}

$runId = [Guid]::NewGuid().ToString('n')
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$detailLog = Join-Path $logsDir ("agent.dispatch.{0}.log" -f $timestamp)
$summaryPath = Join-Path $runsDir ("{0}.json" -f $runId)
$lastPath = Join-Path $runsDir 'last.json'

$repoName = Split-Path -Leaf $WorkspaceRoot
$repoPath = $WorkspaceRoot
$effectivePromptKey = ([string]$PromptKey).Trim()
$requestedModelResolution = Resolve-ModelRouting -ModelRoutingConfig $modelRoutingConfig -TaskKindText $TaskKind -PromptKeyText $effectivePromptKey
$requestedModelSource = [string]$requestedModelResolution.source
$requestedModelAlias = [string]$requestedModelResolution.route_key
$requestedModelSelector = [string]$requestedModelResolution.selector
$requestedResolvedModel = [string]$requestedModelResolution.resolved_model
$effectiveTaskKey = [string]$requestedModelResolution.effective_task_key

$defaultBackend = Get-EnvStringCompat -Name 'RAYMAN_AGENT_DEFAULT_BACKEND' -Default ''
if ([string]::IsNullOrWhiteSpace($defaultBackend) -and $null -ne $routerConfig -and $null -ne $routerConfig.PSObject.Properties['default_backend']) {
  $defaultBackend = [string]$routerConfig.default_backend
}
if ([string]::IsNullOrWhiteSpace($defaultBackend)) { $defaultBackend = 'local' }

$fallbackOrder = @(Get-EnvListCompat -Name 'RAYMAN_AGENT_FALLBACK_ORDER')
if ($fallbackOrder.Count -eq 0 -and $null -ne $routerConfig -and $null -ne $routerConfig.PSObject.Properties['fallback_order']) {
  $fallbackOrder = @(Convert-ToStringArray -Value $routerConfig.fallback_order)
}
if ($fallbackOrder.Count -eq 0) { $fallbackOrder = @('codex', 'local') }

$cloudEnabledEnvRaw = [Environment]::GetEnvironmentVariable('RAYMAN_AGENT_CLOUD_ENABLED')
$cloudEnabled = Get-EnvBoolCompat -Name 'RAYMAN_AGENT_CLOUD_ENABLED' -Default $false
if ($null -ne $routerConfig -and $null -ne $routerConfig.PSObject.Properties['cloud_enabled'] -and [string]::IsNullOrWhiteSpace([string]$cloudEnabledEnvRaw)) {
  $cloudEnabled = [bool]$routerConfig.cloud_enabled
}

$cloudWhitelist = @(Get-EnvListCompat -Name 'RAYMAN_AGENT_CLOUD_WHITELIST')
if ($cloudWhitelist.Count -eq 0 -and $null -ne $routerConfig -and $null -ne $routerConfig.PSObject.Properties['cloud_whitelist']) {
  $cloudWhitelist = @(Convert-ToStringArray -Value $routerConfig.cloud_whitelist)
}

$whitelistMatch = Get-WhitelistMatch -Whitelist $cloudWhitelist -RepoName $repoName -RepoPath $repoPath
$cloudAllowedForRepo = ($cloudEnabled -and $whitelistMatch)

$effectiveModelRouting = Resolve-EffectiveModelRouting -ModelRoutingConfig $modelRoutingConfig -RequestedModelResolution $requestedModelResolution -RouterConfig $routerConfig -CloudEnabled $cloudEnabled -WhitelistMatch $whitelistMatch
$selectedModelSource = $requestedModelSource
$selectedModelAlias = [string]$effectiveModelRouting.selected.route_key
$selectedModelSelector = [string]$effectiveModelRouting.selected.selector
$resolvedModel = [string]$effectiveModelRouting.selected.resolved_model
$modelCandidateChain = @($effectiveModelRouting.candidate_chain)
$modelAvailability = $effectiveModelRouting.availability
$modelSelectionReason = [string]$effectiveModelRouting.selection_reason
$routingPreferredBackend = ''
if (-not [bool]$effectiveModelRouting.selected.preserve_ui -and -not [string]::IsNullOrWhiteSpace([string]$effectiveModelRouting.selected.provider)) {
  $routingPreferredBackend = ([string]$effectiveModelRouting.selected.provider).Trim().ToLowerInvariant()
}
$effectivePreferredBackend = [string]$PreferredBackend
if ([string]::IsNullOrWhiteSpace($effectivePreferredBackend)) {
  $effectivePreferredBackend = $routingPreferredBackend
}

$capabilityMatches = Get-AgentCapabilityMatches -CapabilityState $capabilityState -TaskKindText $TaskKind -PromptKeyText $effectivePromptKey -TaskText $Task -CommandText $Command
$matchedCapabilities = @($capabilityMatches.all_matches)
$activeCapabilityMatches = @($capabilityMatches.active_matches)
$capabilityPreamble = Build-AgentCapabilityPreamble -CapabilityMatches $activeCapabilityMatches

if ($matchedCapabilities.Count -gt 0) {
  $matchSummary = @($matchedCapabilities | ForEach-Object {
      $suffix = if ([bool]$_.active) { 'active' } else { [string]$_.status_reason }
      ('{0}[{1}]=>{2}' -f [string]$_.name, (($_.matched_triggers | ForEach-Object { [string]$_ }) -join ','), $suffix)
    })
  Add-Content -LiteralPath $detailLog -Encoding UTF8 -Value ("capability matches: {0}" -f ($matchSummary -join '; '))
}

if ($selectedModelAlias -ne $requestedModelAlias) {
  Add-Content -LiteralPath $detailLog -Encoding UTF8 -Value ("model route fallback: requested={0} resolved={1} reason={2}" -f $requestedModelAlias, $selectedModelAlias, $modelSelectionReason)
}

$allowPolicyBypass = $false
if ($null -ne $policyConfig -and $null -ne $policyConfig.PSObject.Properties['allow_bypass_with_reason']) {
  $allowPolicyBypass = [bool]$policyConfig.allow_bypass_with_reason
}

$policyBypassRequested = $PolicyBypass.IsPresent -or (Get-EnvBoolCompat -Name 'RAYMAN_AGENT_POLICY_BYPASS' -Default $false)
$policyBypassReason = [string]$BypassReason
if ([string]::IsNullOrWhiteSpace($policyBypassReason)) {
  $policyBypassReason = Get-EnvStringCompat -Name 'RAYMAN_BYPASS_REASON' -Default ''
}
if (-not [string]::IsNullOrWhiteSpace($policyBypassReason)) {
  $policyBypassReason = $policyBypassReason.Trim()
}

$policyBlocked = $false
$policyBlockedReason = ''
$policyBypassed = $false
$policyDecisionLogPath = Join-Path $runtimeDir 'decision.log'

$systemSlimActive = $false
$systemSlimFeature = ''
$delegationTarget = ''
$delegationReason = ''
$systemSlimReport = ''
$systemSlimAudit = $null

$systemSlimScriptCandidates = @(
  (Join-Path $PSScriptRoot 'system_slim_policy.ps1'),
  (Join-Path $WorkspaceRoot '.Rayman\.dist\scripts\agents\system_slim_policy.ps1')
) | Select-Object -Unique

foreach ($candidate in $systemSlimScriptCandidates) {
  if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
  try {
    . $candidate
    break
  } catch {
    Add-Content -LiteralPath $detailLog -Encoding UTF8 -Value ("system slim module load failed: {0}; error={1}" -f $candidate, $_.Exception.Message)
  }
}

try {
  $slimAuditCmd = Get-Command Invoke-RaymanSystemSlimAudit -ErrorAction SilentlyContinue
  if ($null -ne $slimAuditCmd) {
    $systemSlimAudit = Invoke-RaymanSystemSlimAudit -WorkspaceRoot $WorkspaceRoot -Source 'dispatch'
    if ($null -ne $systemSlimAudit -and $systemSlimAudit.PSObject.Properties['report_path']) {
      $systemSlimReport = [string]$systemSlimAudit.report_path
    }

    $dispatchFeature = $null
    if ($null -ne $systemSlimAudit -and $systemSlimAudit.PSObject.Properties['features'] -and $null -ne $systemSlimAudit.features) {
      $dispatchProp = $systemSlimAudit.features.PSObject.Properties['dispatch']
      if ($null -ne $dispatchProp) { $dispatchFeature = $dispatchProp.Value }
    }

    if ($null -ne $dispatchFeature) {
      if ($dispatchFeature.PSObject.Properties['reason']) {
        $delegationReason = [string]$dispatchFeature.reason
      }
      $dispatchMode = if ($dispatchFeature.PSObject.Properties['mode']) { [string]$dispatchFeature.mode } else { 'delegate' }
      if ([string]::IsNullOrWhiteSpace($dispatchMode)) { $dispatchMode = 'delegate' }
      $dispatchTarget = if ($dispatchFeature.PSObject.Properties['delegate_target']) { [string]$dispatchFeature.delegate_target } else { 'codex.exec' }
      if ([string]::IsNullOrWhiteSpace($dispatchTarget)) { $dispatchTarget = 'codex.exec' }

      if ($dispatchFeature.PSObject.Properties['active'] -and [bool]$dispatchFeature.active -and $dispatchMode.ToLowerInvariant() -eq 'delegate') {
        $systemSlimActive = $true
        $systemSlimFeature = 'dispatch'
        $delegationTarget = $dispatchTarget
      }
    }
  } else {
    $delegationReason = 'system_slim_module_unavailable'
  }
} catch {
  $delegationReason = ("system_slim_audit_failed:{0}" -f $_.Exception.Message)
  Add-Content -LiteralPath $detailLog -Encoding UTF8 -Value ("system slim audit failed: {0}" -f $_.Exception.ToString())
}

if ($systemSlimActive -and -not [string]::IsNullOrWhiteSpace($effectivePreferredBackend) -and @('codex', 'local') -notcontains $effectivePreferredBackend) {
  $systemSlimActive = $false
  $systemSlimFeature = ''
  if ([string]::IsNullOrWhiteSpace($delegationReason)) {
    $delegationReason = 'preference_override'
  }
}

$policy = Test-PolicyBlocked -PolicyConfig $policyConfig -CommandText $Command -TaskText $Task
if ($policy.blocked) {
  $policyBlocked = $true
  $policyBlockedReason = [string]$policy.reason

  if ($policyBypassRequested) {
    if (-not $allowPolicyBypass) {
      $policyBlockedReason = ("policy_bypass_not_allowed:{0}" -f [string]$policy.reason)
    } elseif ([string]::IsNullOrWhiteSpace($policyBypassReason)) {
      $policyBlockedReason = ("policy_bypass_reason_missing:{0}" -f [string]$policy.reason)
    } else {
      $policyBypassed = $true
      Write-PolicyBypassDecision -WorkspaceRoot $WorkspaceRoot -RuntimeDir $runtimeDir -RunId $runId -BlockedReason ([string]$policy.reason) -BypassReason $policyBypassReason
      Add-Content -LiteralPath $detailLog -Encoding UTF8 -Value ("policy bypassed: blocked={0}; reason={1}" -f [string]$policy.reason, $policyBypassReason)
      Write-Host ("⚠️  [dispatch] policy bypassed: {0}" -f [string]$policy.reason) -ForegroundColor Yellow
    }
  }

  if (-not $policyBypassed) {
  $blockedSummary = [ordered]@{
    schema = 'rayman.agent.dispatch.v1'
    generated_at = (Get-Date).ToString('o')
    run_id = $runId
    workspace_root = $WorkspaceRoot
    task_kind = $TaskKind
    effective_task_key = $effectiveTaskKey
    task = $Task
    prompt_key = $effectivePromptKey
    requested_model_alias = $requestedModelAlias
    requested_model_selector = $requestedModelSelector
    requested_resolved_model = $requestedResolvedModel
    model_resolution_source = $selectedModelSource
    model_candidate_chain = @($modelCandidateChain)
    model_selection_reason = $modelSelectionReason
    model_availability = $modelAvailability
    selected_model_alias = $selectedModelAlias
    selected_model_selector = $selectedModelSelector
    resolved_model = $resolvedModel
    selected_backend = 'blocked'
    selection_reason = $policyBlockedReason
    policy_blocked = $policyBlocked
    policy_block_reason = [string]$policy.reason
    policy_bypass_allowed = $allowPolicyBypass
    policy_bypass_requested = $policyBypassRequested
    policy_bypassed = $false
    policy_bypass_reason = $policyBypassReason
    policy_decision_log = $policyDecisionLogPath
    capability_registry_path = [string]$capabilityState.registry_path
    capability_registry_valid = [bool]$capabilityState.registry_valid
    capability_matches = @($matchedCapabilities)
    active_capability_matches = @($activeCapabilityMatches)
    codex_capability_preamble = $capabilityPreamble
    system_slim_active = $systemSlimActive
    system_slim_feature = $systemSlimFeature
    delegation_target = $delegationTarget
    delegation_reason = $delegationReason
    system_slim_report = $systemSlimReport
    success = $false
    exit_code = 5
    detail_log = $detailLog
  }
  ($blockedSummary | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $summaryPath -Encoding UTF8
  Copy-Item -LiteralPath $summaryPath -Destination $lastPath -Force
  Write-Host ("❌ [dispatch] blocked by policy: {0}" -f $policyBlockedReason) -ForegroundColor Red
  exit 5
  }
}

$candidates = New-Object System.Collections.Generic.List[string]
$availability = [ordered]@{}
$selectedBackend = 'local'
$selectionReason = 'default_local'

if ($systemSlimActive -and $systemSlimFeature -eq 'dispatch') {
  Add-UniqueBackend -List $candidates -Backend 'codex'
  Add-UniqueBackend -List $candidates -Backend 'local'
  $availability['codex'] = [ordered]@{
    available = $true
    reason = 'system_slim_dispatch_delegate'
    cloud_backend = $false
  }
  $selectedBackend = 'codex'
  $selectionReason = 'selected:system_slim_dispatch_delegate'
  if ([string]::IsNullOrWhiteSpace($delegationReason)) {
    $delegationReason = 'delegate_codex_exec'
  }
  if ([string]::IsNullOrWhiteSpace($delegationTarget)) {
    $delegationTarget = 'codex.exec'
  }
} else {
  if (-not [string]::IsNullOrWhiteSpace($effectivePreferredBackend)) {
    Add-UniqueBackend -List $candidates -Backend $effectivePreferredBackend
  }
  if ($candidates.Count -eq 0 -and $null -ne $routerConfig -and $null -ne $routerConfig.PSObject.Properties['task_backend_preferences']) {
    $prefs = $routerConfig.task_backend_preferences
    if ($null -ne $prefs.PSObject.Properties[$TaskKind]) {
      foreach ($b in Convert-ToStringArray -Value $prefs.$TaskKind) {
        Add-UniqueBackend -List $candidates -Backend $b
      }
    }
  }
  Add-UniqueBackend -List $candidates -Backend $defaultBackend
  foreach ($b in $fallbackOrder) {
    Add-UniqueBackend -List $candidates -Backend $b
  }
  Add-UniqueBackend -List $candidates -Backend 'local'

  foreach ($candidate in $candidates) {
    $availabilityInfo = Test-BackendAvailability -RouterConfig $routerConfig -Backend $candidate -CloudEnabled $cloudEnabled -WhitelistMatch $whitelistMatch
    $available = [bool]$availabilityInfo.available
    $reason = [string]$availabilityInfo.reason
    $isCloudBackend = [bool]$availabilityInfo.cloud_backend

    $availability[$candidate] = [ordered]@{
      available = $available
      reason = $reason
      cloud_backend = $isCloudBackend
    }

    if ($available) {
      $selectedBackend = $candidate
      $selectionReason = ("selected:{0}" -f $reason)
      break
    }
  }
}

$executedCommand = ''
$delegated = $false
$exitCode = 0
$success = $true
$errorMessage = ''

if ($systemSlimActive -and $systemSlimFeature -eq 'dispatch') {
  $delegated = $true
  $promptText = Build-SystemSlimDispatchPrompt -TaskText $Task -CommandText $Command -TaskKindText $TaskKind -WorkspaceRoot $WorkspaceRoot -CapabilityPreamble $capabilityPreamble
  $promptSingleLine = ($promptText -replace "[`r`n]+", ' ').Trim()
  $executedCommand = ('codex exec -C "{0}" "{1}"' -f $WorkspaceRoot, $promptSingleLine)
  Add-Content -LiteralPath $detailLog -Encoding UTF8 -Value ("system-slim delegated: target={0}; prompt={1}" -f $delegationTarget, $promptSingleLine)

  if (-not $DryRun) {
    try {
      $codexCmd = Get-Command 'codex' -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($null -eq $codexCmd) {
        throw 'codex command not found at runtime'
      }
      $delegateOutput = & $codexCmd.Source 'exec' '-C' $WorkspaceRoot $promptText 2>&1
      if ($delegateOutput) {
        $delegateOutput | ForEach-Object { Add-Content -LiteralPath $detailLog -Encoding UTF8 -Value ([string]$_) }
      }
      $exitCode = [int]$LASTEXITCODE
      $success = ($exitCode -eq 0)
    } catch {
      $exitCode = 1
      $success = $false
      $errorMessage = $_.Exception.Message
      Add-Content -LiteralPath $detailLog -Encoding UTF8 -Value $_.Exception.ToString()
      if ([string]::IsNullOrWhiteSpace($delegationReason)) {
        $delegationReason = ("dispatch_delegate_failed:{0}" -f $errorMessage)
      }
    }
  }
} elseif (-not [string]::IsNullOrWhiteSpace($Command)) {
  if ($selectedBackend -eq 'local') {
    $executedCommand = $Command
    if (-not $DryRun) {
      try {
        $commandOutput = Invoke-Expression $Command 2>&1
        if ($commandOutput) {
          $commandOutput | ForEach-Object { Add-Content -LiteralPath $detailLog -Encoding UTF8 -Value ([string]$_) }
        }
        $exitCode = [int]$LASTEXITCODE
        $success = ($exitCode -eq 0)
      } catch {
        $exitCode = 1
        $success = $false
        $errorMessage = $_.Exception.Message
        Add-Content -LiteralPath $detailLog -Encoding UTF8 -Value $_.Exception.ToString()
      }
    }
  } else {
    $delegated = $true
    $executedCommand = $Command
    Add-Content -LiteralPath $detailLog -Encoding UTF8 -Value ("delegated to backend={0}; command={1}" -f $selectedBackend, $Command)
  }
}

$summary = [ordered]@{
  schema = 'rayman.agent.dispatch.v1'
  generated_at = (Get-Date).ToString('o')
  run_id = $runId
  workspace_root = $WorkspaceRoot
  repository = $repoName
  task_kind = $TaskKind
  effective_task_key = $effectiveTaskKey
  task = $Task
  prompt_key = $effectivePromptKey
  preferred_backend = $effectivePreferredBackend
  requested_model_alias = $requestedModelAlias
  requested_model_selector = $requestedModelSelector
  requested_resolved_model = $requestedResolvedModel
  model_resolution_source = $selectedModelSource
  model_candidate_chain = @($modelCandidateChain)
  model_selection_reason = $modelSelectionReason
  model_availability = $modelAvailability
  selected_model_alias = $selectedModelAlias
  selected_model_selector = $selectedModelSelector
  resolved_model = $resolvedModel
  candidate_chain = @($candidates)
  selected_backend = $selectedBackend
  selection_reason = $selectionReason
  policy_blocked = $policyBlocked
  policy_block_reason = [string]$policy.reason
  policy_bypass_allowed = $allowPolicyBypass
  policy_bypass_requested = $policyBypassRequested
  policy_bypassed = $policyBypassed
  policy_bypass_reason = $policyBypassReason
  policy_decision_log = $policyDecisionLogPath
  capability_registry_path = [string]$capabilityState.registry_path
  capability_registry_valid = [bool]$capabilityState.registry_valid
  capability_matches = @($matchedCapabilities)
  active_capability_matches = @($activeCapabilityMatches)
  codex_capability_preamble = $capabilityPreamble
  cloud_enabled = $cloudEnabled
  cloud_whitelist = @($cloudWhitelist)
  cloud_whitelist_match = $whitelistMatch
  cloud_allowed_for_repo = $cloudAllowedForRepo
  availability = $availability
  dry_run = [bool]$DryRun
  delegated = $delegated
  executed_command = $executedCommand
  system_slim_active = $systemSlimActive
  system_slim_feature = $systemSlimFeature
  delegation_target = $delegationTarget
  delegation_reason = $delegationReason
  system_slim_report = $systemSlimReport
  success = $success
  exit_code = $exitCode
  error_message = $errorMessage
  detail_log = $detailLog
}

($summary | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Copy-Item -LiteralPath $summaryPath -Destination $lastPath -Force

Write-Host ("✅ [dispatch] backend={0} reason={1}" -f $selectedBackend, $selectionReason) -ForegroundColor Green
Write-Host ("🧾 [dispatch] summary={0}" -f $summaryPath) -ForegroundColor DarkCyan
if ($systemSlimActive -and $systemSlimFeature -eq 'dispatch') {
  Write-Host "✅ [dispatch] system-delegated: codex.exec" -ForegroundColor Green
}
if ($delegated) {
  Write-Host ("ℹ️ [dispatch] delegated to {0}; execute in agent/cloud workflow." -f $selectedBackend) -ForegroundColor Cyan
}

exit $exitCode
