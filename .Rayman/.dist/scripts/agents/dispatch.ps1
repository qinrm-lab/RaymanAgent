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

  $providers = Get-PropValue -Object $ModelRoutingConfig -Name 'providers' -Default $null
  $route = Get-PropValue -Object $providers -Name $routeKey -Default $null
  $provider = ''
  $selector = ''
  if ($null -ne $route) {
    $provider = [string](Get-PropValue -Object $route -Name 'provider' -Default '')
    $selector = [string](Get-PropValue -Object $route -Name 'selector' -Default '')
  }

  if ([string]::IsNullOrWhiteSpace($provider)) {
    if ($routeKey -eq 'ui_selected') {
      $provider = 'ui_selected'
      $selector = 'ui_selected'
    } else {
      $provider = $routeKey
    }
  }

  $preserveUi = ($provider -eq 'ui_selected' -or $routeKey -eq 'ui_selected')
  $resolvedModel = if ($preserveUi) {
    'ui_selected'
  } elseif (-not [string]::IsNullOrWhiteSpace($selector)) {
    ('{0}.{1}' -f $provider, $selector)
  } else {
    $provider
  }

  return [pscustomobject]@{
    effective_task_key = $effectiveTaskKey
    prompt_key = $normalizedPromptKey
    source = $source
    route_key = $routeKey
    provider = $provider
    selector = $selector
    preserve_ui = $preserveUi
    resolved_model = $resolvedModel
  }
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

function Build-SystemSlimDispatchPrompt {
  param(
    [string]$TaskText,
    [string]$CommandText,
    [string]$TaskKindText,
    [string]$WorkspaceRoot
  )

  if (-not [string]::IsNullOrWhiteSpace($TaskText)) {
    return ("TaskKind={0}`nWorkspace={1}`nTask={2}" -f $TaskKindText, $WorkspaceRoot, $TaskText.Trim())
  }
  if (-not [string]::IsNullOrWhiteSpace($CommandText)) {
    return ("TaskKind={0}`nWorkspace={1}`nRunCommand={2}" -f $TaskKindText, $WorkspaceRoot, $CommandText.Trim())
  }
  if (-not [string]::IsNullOrWhiteSpace($TaskKindText)) {
    return ("TaskKind={0}`nWorkspace={1}`nGoal=Please execute {0} workflow and report actionable result." -f $TaskKindText.Trim(), $WorkspaceRoot)
  }
  return ("Workspace={0}`nGoal=Please execute general engineering task and report actionable result." -f $WorkspaceRoot)
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
$modelResolution = Resolve-ModelRouting -ModelRoutingConfig $modelRoutingConfig -TaskKindText $TaskKind -PromptKeyText $effectivePromptKey
$selectedModelSource = [string]$modelResolution.source
$selectedModelAlias = [string]$modelResolution.route_key
$selectedModelSelector = [string]$modelResolution.selector
$resolvedModel = [string]$modelResolution.resolved_model
$effectiveTaskKey = [string]$modelResolution.effective_task_key
$routingPreferredBackend = ''
if (-not [bool]$modelResolution.preserve_ui -and -not [string]::IsNullOrWhiteSpace([string]$modelResolution.provider)) {
  $routingPreferredBackend = ([string]$modelResolution.provider).Trim().ToLowerInvariant()
}
$effectivePreferredBackend = [string]$PreferredBackend
if ([string]::IsNullOrWhiteSpace($effectivePreferredBackend)) {
  $effectivePreferredBackend = $routingPreferredBackend
}

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
    model_resolution_source = $selectedModelSource
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
  $promptText = Build-SystemSlimDispatchPrompt -TaskText $Task -CommandText $Command -TaskKindText $TaskKind -WorkspaceRoot $WorkspaceRoot
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
  model_resolution_source = $selectedModelSource
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
