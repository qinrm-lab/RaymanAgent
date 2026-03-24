Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RaymanAgenticPropValue {
  param(
    [object]$Object,
    [string]$Name,
    $Default = $null
  )

  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) {
    if ($Object.Contains($Name)) { return $Object[$Name] }
    return $Default
  }

  $prop = $Object.PSObject.Properties[$Name]
  if ($null -eq $prop) { return $Default }
  if ($null -eq $prop.Value) { return $Default }
  return $prop.Value
}

function Get-RaymanAgenticCapabilityToolKey {
  param([string]$CapabilityName)

  $name = ([string]$CapabilityName).Trim().ToLowerInvariant()
  switch ($name) {
    'openai_docs' { return 'openai_docs_mcp' }
    'web_auto_test' { return 'playwright_mcp' }
    'winapp_auto_test' { return 'rayman_winapp_mcp' }
    default { return [string]$CapabilityName }
  }
}

function ConvertTo-RaymanAgenticStringArray {
  param([object]$Value)

  if ($null -eq $Value) { return @() }
  $items = New-Object System.Collections.Generic.List[string]
  foreach ($item in @($Value)) {
    $text = [string]$item
    if (-not [string]::IsNullOrWhiteSpace($text)) {
      $items.Add($text.Trim()) | Out-Null
    }
  }
  return @($items.ToArray())
}

function Test-RaymanAgenticTextContainsAny {
  param(
    [string[]]$Texts,
    [string[]]$Needles
  )

  $haystacks = @($Texts | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  foreach ($needle in @($Needles | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    foreach ($haystack in $haystacks) {
      if ($haystack.Contains($needle)) {
        return $true
      }
    }
  }
  return $false
}

function Get-RaymanAgenticEnvBool {
  param(
    [string]$Name,
    [bool]$Default = $false
  )

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

function Get-RaymanAgenticEnvString {
  param(
    [string]$Name,
    [string]$Default = ''
  )

  $raw = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
  return [string]$raw
}

function Ensure-RaymanAgenticDir {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Get-RaymanAgenticJsonOrNull {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Write-RaymanAgenticJson {
  param(
    [string]$Path,
    [object]$Value
  )

  $json = ($Value | ConvertTo-Json -Depth 12)
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $json, $enc)
}

function Write-RaymanAgenticText {
  param(
    [string]$Path,
    [string]$Text
  )

  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Get-RaymanAgenticSolutionName {
  param([string]$WorkspaceRoot)

  $marker = Join-Path $WorkspaceRoot '.SolutionName'
  if (Test-Path -LiteralPath $marker -PathType Leaf) {
    $raw = [string](Get-Content -LiteralPath $marker -Raw -Encoding UTF8)
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      return $raw.Trim()
    }
  }

  $dirs = @(Get-ChildItem -LiteralPath $WorkspaceRoot -Force -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name.StartsWith('.') -and $_.Name.Length -gt 1 })
  foreach ($dir in $dirs) {
    $candidate = $dir.Name.TrimStart('.')
    $req = Join-Path $dir.FullName ('.{0}.requirements.md' -f $candidate)
    if (Test-Path -LiteralPath $req -PathType Leaf) {
      return $candidate
    }
  }

  return (Split-Path -Leaf $WorkspaceRoot)
}

function Get-RaymanAgenticArtifactPaths {
  param([string]$WorkspaceRoot)

  $solutionName = Get-RaymanAgenticSolutionName -WorkspaceRoot $WorkspaceRoot
  $solutionDirName = ".{0}" -f $solutionName
  $solutionDir = Join-Path $WorkspaceRoot $solutionDirName
  $requirementsPath = Join-Path $solutionDir ('.{0}.requirements.md' -f $solutionName)
  $agenticDir = Join-Path $solutionDir 'agentic'

  return [pscustomobject]@{
    workspace_root = $WorkspaceRoot
    solution_name = $solutionName
    solution_dir = $solutionDir
    solution_dir_name = $solutionDirName
    requirements_path = $requirementsPath
    agentic_dir = $agenticDir
    plan_json = (Join-Path $agenticDir 'plan.current.json')
    plan_md = (Join-Path $agenticDir 'plan.current.md')
    tool_policy_json = (Join-Path $agenticDir 'tool-policy.json')
    tool_policy_md = (Join-Path $agenticDir 'tool-policy.md')
    reflection_json = (Join-Path $agenticDir 'reflection.current.json')
    reflection_md = (Join-Path $agenticDir 'reflection.current.md')
    evals_md = (Join-Path $agenticDir 'evals.md')
  }
}

function Get-RaymanAgenticDefaultConfig {
  return [ordered]@{
    schema = 'rayman.agentic_pipeline.v1'
    default_pipeline = 'planner_v1'
    legacy_pipeline_name = 'legacy'
    doc_gate_enabled = $true
    openai_optional = 'auto'
    tool_budget = [ordered]@{
      default = [ordered]@{
        max_selected_tools = 3
        max_fallbacks = 2
        max_subagents = 2
      }
      review = [ordered]@{
        max_selected_tools = 4
        max_fallbacks = 3
        max_subagents = 2
      }
      release = [ordered]@{
        max_selected_tools = 4
        max_fallbacks = 2
        max_subagents = 1
      }
    }
    required_docs = [ordered]@{
      dispatch = @('plan.current.md', 'plan.current.json', 'tool-policy.md', 'tool-policy.json', 'evals.md')
      review_loop = @('plan.current.md', 'plan.current.json', 'tool-policy.md', 'tool-policy.json', 'reflection.current.md', 'reflection.current.json', 'evals.md')
    }
    openai_optional_features = [ordered]@{
      background_mode = [ordered]@{
        fallback = 'local_review_loop'
        support_mode = 'disabled_until_supported'
        support_reason = 'delegated_codex_executor_not_implemented'
      }
      compaction = [ordered]@{
        fallback = 'local_context_files'
        support_mode = 'disabled_until_supported'
        support_reason = 'delegated_codex_executor_not_implemented'
      }
      prompt_optimizer = [ordered]@{
        fallback = 'manual_evals_index'
        support_mode = 'disabled_until_supported'
        support_reason = 'delegated_codex_executor_not_implemented'
      }
    }
  }
}

function Get-RaymanAgenticPipelineConfig {
  param([string]$WorkspaceRoot)

  $default = Get-RaymanAgenticDefaultConfig
  $configPath = Join-Path $WorkspaceRoot '.Rayman\config\agentic_pipeline.json'
  $raw = Get-RaymanAgenticJsonOrNull -Path $configPath

  if ($null -ne $raw) {
    foreach ($name in @('schema', 'default_pipeline', 'legacy_pipeline_name', 'openai_optional')) {
      $value = [string](Get-RaymanAgenticPropValue -Object $raw -Name $name -Default '')
      if (-not [string]::IsNullOrWhiteSpace($value)) {
        $default[$name] = $value.Trim()
      }
    }
    if ($null -ne (Get-RaymanAgenticPropValue -Object $raw -Name 'doc_gate_enabled' -Default $null)) {
      $default.doc_gate_enabled = [bool](Get-RaymanAgenticPropValue -Object $raw -Name 'doc_gate_enabled' -Default $true)
    }

    $toolBudget = Get-RaymanAgenticPropValue -Object $raw -Name 'tool_budget' -Default $null
    if ($null -ne $toolBudget) {
      foreach ($bucket in @('default', 'review', 'release')) {
        $bucketRaw = Get-RaymanAgenticPropValue -Object $toolBudget -Name $bucket -Default $null
        if ($null -eq $bucketRaw) { continue }
        foreach ($field in @('max_selected_tools', 'max_fallbacks', 'max_subagents')) {
          $parsed = 0
          if ([int]::TryParse([string](Get-RaymanAgenticPropValue -Object $bucketRaw -Name $field -Default ''), [ref]$parsed)) {
            $default.tool_budget[$bucket][$field] = $parsed
          }
        }
      }
    }

    $requiredDocs = Get-RaymanAgenticPropValue -Object $raw -Name 'required_docs' -Default $null
    if ($null -ne $requiredDocs) {
      foreach ($stage in @('dispatch', 'review_loop')) {
        $items = ConvertTo-RaymanAgenticStringArray -Value (Get-RaymanAgenticPropValue -Object $requiredDocs -Name $stage -Default $null)
        if ($items.Count -gt 0) {
          $default.required_docs[$stage] = @($items)
        }
      }
    }

    $optional = Get-RaymanAgenticPropValue -Object $raw -Name 'openai_optional_features' -Default $null
    if ($null -ne $optional) {
      foreach ($feature in @('background_mode', 'compaction', 'prompt_optimizer')) {
        $featureRaw = Get-RaymanAgenticPropValue -Object $optional -Name $feature -Default $null
        if ($null -eq $featureRaw) { continue }
        $fallback = [string](Get-RaymanAgenticPropValue -Object $featureRaw -Name 'fallback' -Default '')
        $supportMode = [string](Get-RaymanAgenticPropValue -Object $featureRaw -Name 'support_mode' -Default '')
        $supportReason = [string](Get-RaymanAgenticPropValue -Object $featureRaw -Name 'support_reason' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($fallback)) {
          $default.openai_optional_features[$feature].fallback = $fallback.Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace($supportMode)) {
          $default.openai_optional_features[$feature].support_mode = $supportMode.Trim().ToLowerInvariant()
        }
        if (-not [string]::IsNullOrWhiteSpace($supportReason)) {
          $default.openai_optional_features[$feature].support_reason = $supportReason.Trim()
        }
      }
    }
  }

  $pipelineMode = Get-RaymanAgenticEnvString -Name 'RAYMAN_AGENT_PIPELINE' -Default ([string]$default.default_pipeline)
  if ([string]::IsNullOrWhiteSpace($pipelineMode)) {
    $pipelineMode = [string]$default.default_pipeline
  }
  $docGateEnabled = Get-RaymanAgenticEnvBool -Name 'RAYMAN_AGENT_DOC_GATE' -Default ([bool]$default.doc_gate_enabled)
  $openAiOptional = Get-RaymanAgenticEnvString -Name 'RAYMAN_AGENT_OPENAI_OPTIONAL' -Default ([string]$default.openai_optional)
  if ([string]::IsNullOrWhiteSpace($openAiOptional)) {
    $openAiOptional = [string]$default.openai_optional
  }

  return [pscustomobject]@{
    path = $configPath
    data = [pscustomobject]@{
      schema = [string]$default.schema
      default_pipeline = [string]$default.default_pipeline
      legacy_pipeline_name = [string]$default.legacy_pipeline_name
      doc_gate_enabled = [bool]$docGateEnabled
      openai_optional = [string]$openAiOptional
      active_pipeline = [string]$pipelineMode.Trim()
      tool_budget = [pscustomobject]$default.tool_budget
      required_docs = [pscustomobject]$default.required_docs
      openai_optional_features = [pscustomobject]$default.openai_optional_features
    }
  }
}

function Get-RaymanAgenticToolBudget {
  param(
    [object]$ConfigData,
    [string]$TaskKind
  )

  $taskKey = ([string]$TaskKind).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($taskKey)) {
    $taskKey = 'default'
  }
  $budget = Get-RaymanAgenticPropValue -Object (Get-RaymanAgenticPropValue -Object $ConfigData -Name 'tool_budget' -Default $null) -Name $taskKey -Default $null
  if ($null -eq $budget) {
    $budget = Get-RaymanAgenticPropValue -Object (Get-RaymanAgenticPropValue -Object $ConfigData -Name 'tool_budget' -Default $null) -Name 'default' -Default $null
  }
  if ($null -eq $budget) {
    $budget = [pscustomobject]@{
      max_selected_tools = 3
      max_fallbacks = 2
      max_subagents = 2
    }
  }
  return $budget
}

function Get-RaymanAgenticOptionalState {
  param(
    [object]$ConfigData,
    [object]$CapabilityState = $null
  )

  $mode = [string](Get-RaymanAgenticPropValue -Object $ConfigData -Name 'openai_optional' -Default 'auto')
  $mode = $mode.Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'auto' }

  $codexAvailable = ($null -ne (Get-Command codex -ErrorAction SilentlyContinue | Select-Object -First 1))
  $docsActive = $false
  if ($null -ne $CapabilityState -and $null -ne $CapabilityState.capabilities) {
    foreach ($capability in @($CapabilityState.capabilities)) {
      if ([string](Get-RaymanAgenticPropValue -Object $capability -Name 'name' -Default '') -eq 'openai_docs') {
        $docsActive = [bool](Get-RaymanAgenticPropValue -Object $capability -Name 'active' -Default $false)
        break
      }
    }
  }

  $features = New-Object System.Collections.Generic.List[object]
  foreach ($featureName in @('background_mode', 'compaction', 'prompt_optimizer')) {
    $featureConfig = Get-RaymanAgenticPropValue -Object (Get-RaymanAgenticPropValue -Object $ConfigData -Name 'openai_optional_features' -Default $null) -Name $featureName -Default $null
    $fallback = [string](Get-RaymanAgenticPropValue -Object $featureConfig -Name 'fallback' -Default 'local')
    $supportMode = [string](Get-RaymanAgenticPropValue -Object $featureConfig -Name 'support_mode' -Default 'disabled_until_supported')
    $supportReason = [string](Get-RaymanAgenticPropValue -Object $featureConfig -Name 'support_reason' -Default 'delegated_codex_executor_not_implemented')
    $enabled = ($mode -ne 'off')
    $supportMode = $supportMode.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($supportMode)) {
      $supportMode = 'disabled_until_supported'
    }
    $available = $false
    $reason = if (-not $enabled) {
      'disabled_by_env'
    } elseif ($supportMode -eq 'disabled_until_supported') {
      'disabled_until_supported'
    } elseif ($supportMode -ne 'delegated_codex_opt_in') {
      ('unsupported_support_mode_{0}' -f $supportMode)
    } elseif (-not $codexAvailable) {
      'codex_command_missing'
    } elseif (-not $docsActive) {
      'openai_docs_inactive'
    } else {
      $available = $true
      'available'
    }
    $features.Add([pscustomobject]@{
        name = $featureName
        enabled = $enabled
        available = $available
        support_mode = $supportMode
        support_reason = $supportReason
        reason = $reason
        fallback = $fallback
      }) | Out-Null
  }

  return [pscustomobject]@{
    mode = $mode
    codex_available = $codexAvailable
    openai_docs_active = $docsActive
    features = @($features.ToArray())
  }
}

function New-RaymanAgenticOptionalRequests {
  param(
    [string]$TaskKind,
    [string]$Task,
    [string]$Command,
    [string]$PromptKey,
    [object]$ToolPolicy,
    [object]$OptionalState
  )

  $taskKindText = ([string]$TaskKind).Trim().ToLowerInvariant()
  $selectedToolCount = @(Get-RaymanAgenticPropValue -Object $ToolPolicy -Name 'selected_tool_keys' -Default @()).Count
  $selectedSubagentCount = @(Get-RaymanAgenticPropValue -Object $ToolPolicy -Name 'selected_subagents' -Default @()).Count
  $combinedSelectionCount = $selectedToolCount + $selectedSubagentCount
  $hasPromptKey = (-not [string]::IsNullOrWhiteSpace([string]$PromptKey))
  $textPool = @($TaskKind, $Task, $Command, $PromptKey)
  $requests = New-Object System.Collections.Generic.List[object]

  foreach ($feature in @(Get-RaymanAgenticPropValue -Object $OptionalState -Name 'features' -Default @())) {
    $name = [string](Get-RaymanAgenticPropValue -Object $feature -Name 'name' -Default '')
    if ([string]::IsNullOrWhiteSpace($name)) { continue }

    $requested = $false
    $requestReason = ''
    switch ($name) {
      'background_mode' {
        if (@('review', 'release') -contains $taskKindText) {
          $requested = $true
          $requestReason = ('task_kind_{0}' -f $taskKindText)
        } elseif ([string]::IsNullOrWhiteSpace([string]$Command)) {
          $requested = $true
          $requestReason = 'planner_task_without_explicit_command'
        }
      }
      'compaction' {
        if ($combinedSelectionCount -gt 1) {
          $requested = $true
          $requestReason = ('selection_count_{0}' -f $combinedSelectionCount)
        } elseif (Test-RaymanAgenticTextContainsAny -Texts $textPool -Needles @('long context', 'multi-file', 'compaction')) {
          $requested = $true
          $requestReason = 'task_requests_long_context'
        }
      }
      'prompt_optimizer' {
        if ($hasPromptKey) {
          $requested = $true
          $requestReason = 'prompt_key_present'
        } elseif (Test-RaymanAgenticTextContainsAny -Texts $textPool -Needles @('prompt', 'instruction', 'model', 'docs')) {
          $requested = $true
          $requestReason = 'task_mentions_prompt_or_docs'
        }
      }
    }

    if (-not $requested) { continue }
    $requests.Add([pscustomobject]@{
        name = $name
        requested = $true
        reason = $requestReason
        available = [bool](Get-RaymanAgenticPropValue -Object $feature -Name 'available' -Default $false)
        support_mode = [string](Get-RaymanAgenticPropValue -Object $feature -Name 'support_mode' -Default '')
        support_reason = [string](Get-RaymanAgenticPropValue -Object $feature -Name 'support_reason' -Default '')
        fallback = [string](Get-RaymanAgenticPropValue -Object $feature -Name 'fallback' -Default 'local')
      }) | Out-Null
  }

  return @($requests.ToArray())
}

function New-RaymanAgenticDelegationPreamble {
  param(
    [object]$ToolPolicy,
    [object]$ExecutionContract
  )

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('[RaymanAgenticExecution]')
  $lines.Add(('delegation_required={0}' -f [string]([bool](Get-RaymanAgenticPropValue -Object $ExecutionContract -Name 'delegation_required' -Default $false)).ToString().ToLowerInvariant()))
  $lines.Add(('backend_order={0}' -f ((@(Get-RaymanAgenticPropValue -Object $ExecutionContract -Name 'backend_order' -Default @()) | ForEach-Object { [string]$_ }) -join ',')))
  $lines.Add(('selected_tools={0}' -f ((@(Get-RaymanAgenticPropValue -Object $ToolPolicy -Name 'selected_tool_keys' -Default @()) | ForEach-Object { [string]$_ }) -join ',')))
  $lines.Add(('selected_subagents={0}' -f ((@(Get-RaymanAgenticPropValue -Object $ToolPolicy -Name 'selected_subagents' -Default @()) | ForEach-Object { [string]$_ }) -join ',')))
  $lines.Add(('optional_requests={0}' -f ((@(Get-RaymanAgenticPropValue -Object $ExecutionContract -Name 'optional_requests' -Default @()) | ForEach-Object { [string](Get-RaymanAgenticPropValue -Object $_ -Name 'name' -Default '') }) -join ',')))
  $lines.Add(('optional_request_states={0}' -f ((@(Get-RaymanAgenticPropValue -Object $ExecutionContract -Name 'optional_requests' -Default @()) | ForEach-Object {
          $requestName = [string](Get-RaymanAgenticPropValue -Object $_ -Name 'name' -Default '')
          $requestMode = [string](Get-RaymanAgenticPropValue -Object $_ -Name 'support_mode' -Default '')
          $requestAvailable = [string]([bool](Get-RaymanAgenticPropValue -Object $_ -Name 'available' -Default $false)).ToString().ToLowerInvariant()
          if ([string]::IsNullOrWhiteSpace($requestName)) { return $null }
          if ([string]::IsNullOrWhiteSpace($requestMode)) { return ('{0}:{1}' -f $requestName, $requestAvailable) }
          return ('{0}:{1}:{2}' -f $requestName, $requestMode, $requestAvailable)
        } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ',')))
  $lines.Add(('local_fallback_command={0}' -f [string](Get-RaymanAgenticPropValue -Object $ExecutionContract -Name 'local_fallback_command' -Default '')))
  $lines.Add('instruction=Honor selected tools and subagents before generic fallback. Only apply optional requests during Codex delegation when they are explicitly available; otherwise record the disabled state and use the documented local fallback.')
  $lines.Add('[/RaymanAgenticExecution]')
  return ($lines -join "`n")
}

function New-RaymanAgenticExecutionContract {
  param(
    [string]$TaskKind,
    [string]$Task,
    [string]$Command,
    [string]$PromptKey,
    [string]$PreferredBackend,
    [object]$ToolPolicy,
    [object[]]$CapabilityMatches,
    [object]$ConfigData,
    [object]$CapabilityState = $null
  )

  $selectedTools = @(Get-RaymanAgenticPropValue -Object $ToolPolicy -Name 'selected_tools' -Default @())
  $selectedToolKeys = @(Get-RaymanAgenticPropValue -Object $ToolPolicy -Name 'selected_tool_keys' -Default @())
  $selectedSubagents = @(Get-RaymanAgenticPropValue -Object $ToolPolicy -Name 'selected_subagents' -Default @())
  $optionalState = Get-RaymanAgenticOptionalState -ConfigData $ConfigData -CapabilityState $CapabilityState
  $optionalRequests = @(New-RaymanAgenticOptionalRequests -TaskKind $TaskKind -Task $Task -Command $Command -PromptKey $PromptKey -ToolPolicy $ToolPolicy -OptionalState $optionalState)

  $capabilityByToolKey = @{}
  foreach ($capability in @($CapabilityMatches)) {
    $toolKey = Get-RaymanAgenticCapabilityToolKey -CapabilityName ([string](Get-RaymanAgenticPropValue -Object $capability -Name 'name' -Default ''))
    if ([string]::IsNullOrWhiteSpace($toolKey)) { continue }
    $capabilityByToolKey[$toolKey] = $capability
  }

  $delegationReasons = New-Object System.Collections.Generic.List[string]
  $backendOrder = New-Object System.Collections.Generic.List[string]
  $prepareCommands = New-Object System.Collections.Generic.List[string]
  $localFallbackCommand = ''
  $localFallbackToolKey = ''
  $requiresCodex = $false

  foreach ($tool in $selectedTools) {
    $kind = ([string](Get-RaymanAgenticPropValue -Object $tool -Name 'kind' -Default '')).Trim().ToLowerInvariant()
    $key = [string](Get-RaymanAgenticPropValue -Object $tool -Name 'key' -Default '')
    if ($kind -in @('capability', 'subagent')) {
      $requiresCodex = $true
    }
    if ($kind -eq 'capability' -and $delegationReasons -notcontains ('tool:{0}' -f $key)) {
      $delegationReasons.Add(('tool:{0}' -f $key)) | Out-Null
    }
  }

  foreach ($role in $selectedSubagents) {
    $requiresCodex = $true
    if ($delegationReasons -notcontains ('subagent:{0}' -f [string]$role)) {
      $delegationReasons.Add(('subagent:{0}' -f [string]$role)) | Out-Null
    }
  }

  foreach ($request in $optionalRequests) {
    $requiresCodex = $true
    $name = [string](Get-RaymanAgenticPropValue -Object $request -Name 'name' -Default '')
    if ($delegationReasons -notcontains ('optional:{0}' -f $name)) {
      $delegationReasons.Add(('optional:{0}' -f $name)) | Out-Null
    }
  }

  foreach ($toolKey in $selectedToolKeys) {
    if ($capabilityByToolKey.ContainsKey([string]$toolKey)) {
      $capability = $capabilityByToolKey[[string]$toolKey]
      $fallback = [string](Get-RaymanAgenticPropValue -Object $capability -Name 'fallback_command' -Default '')
      $prepare = [string](Get-RaymanAgenticPropValue -Object $capability -Name 'prepare_command' -Default '')
      if ([string]::IsNullOrWhiteSpace($localFallbackCommand) -and -not [string]::IsNullOrWhiteSpace($fallback)) {
        $localFallbackCommand = $fallback.Trim()
        $localFallbackToolKey = [string]$toolKey
      }
      if (-not [string]::IsNullOrWhiteSpace($prepare) -and $prepareCommands -notcontains $prepare.Trim()) {
        $prepareCommands.Add($prepare.Trim()) | Out-Null
      }
    }
  }

  if ($requiresCodex) {
    $backendOrder.Add('codex') | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$PreferredBackend)) {
    $preferred = ([string]$PreferredBackend).Trim().ToLowerInvariant()
    if ($backendOrder -notcontains $preferred) {
      $backendOrder.Add($preferred) | Out-Null
    }
  }
  if ((-not [string]::IsNullOrWhiteSpace($localFallbackCommand)) -or ($selectedToolKeys -contains 'local_shell')) {
    if ($backendOrder -notcontains 'local') {
      $backendOrder.Add('local') | Out-Null
    }
  }

  $contract = [pscustomobject]@{
    schema = 'rayman.agentic.execution_contract.v1'
    backend_order = @($backendOrder.ToArray())
    delegation_required = $requiresCodex
    delegation_reasons = @($delegationReasons.ToArray())
    local_fallback_tool_key = $localFallbackToolKey
    local_fallback_command = $localFallbackCommand
    prepare_commands = @($prepareCommands.ToArray())
    prepare_results = @()
    optional_requests = @($optionalRequests)
    optional_state = $optionalState
  }
  $contract | Add-Member -NotePropertyName delegation_preamble -NotePropertyValue (New-RaymanAgenticDelegationPreamble -ToolPolicy $ToolPolicy -ExecutionContract $contract)
  return $contract
}

function Resolve-RaymanDispatchBlockedErrorKind {
  param([object]$DispatchSummary)

  $selectionReason = [string](Get-RaymanAgenticPropValue -Object $DispatchSummary -Name 'selection_reason' -Default '')
  if (-not [string]::IsNullOrWhiteSpace($selectionReason)) {
    return $selectionReason.Trim()
  }

  $policyReason = [string](Get-RaymanAgenticPropValue -Object $DispatchSummary -Name 'policy_block_reason' -Default '')
  if (-not [string]::IsNullOrWhiteSpace($policyReason)) {
    return $policyReason.Trim()
  }

  return 'dispatch_policy_blocked'
}

function Get-RaymanAgenticRequirementLines {
  param([string]$RequirementsPath)

  if (-not (Test-Path -LiteralPath $RequirementsPath -PathType Leaf)) { return @() }
  return @(Get-Content -LiteralPath $RequirementsPath -Encoding UTF8 -ErrorAction SilentlyContinue)
}

function Get-RaymanAgenticSummaryBullets {
  param([string]$RequirementsPath)

  $lines = Get-RaymanAgenticRequirementLines -RequirementsPath $RequirementsPath
  if ($lines.Count -eq 0) { return @() }

  $bullets = New-Object System.Collections.Generic.List[string]
  foreach ($line in $lines) {
    $trimmed = ([string]$line).Trim()
    if ($trimmed.StartsWith('- ')) {
      $text = $trimmed.Substring(2).Trim()
      if (-not [string]::IsNullOrWhiteSpace($text)) {
        $bullets.Add($text) | Out-Null
      }
    }
    if ($bullets.Count -ge 8) { break }
  }
  return @($bullets.ToArray())
}

function Get-RaymanSelectedSubagentHints {
  param(
    [object]$MultiAgentRegistry,
    [string]$TaskKind,
    [string]$Task,
    [string]$Command
  )

  $taskText = (([string]$TaskKind) + ' ' + ([string]$Task) + ' ' + ([string]$Command)).ToLowerInvariant()
  $allowed = New-Object System.Collections.Generic.List[string]
  $selected = New-Object System.Collections.Generic.List[string]
  $notes = New-Object System.Collections.Generic.List[string]

  if ($null -eq $MultiAgentRegistry -or -not [bool](Get-RaymanAgenticPropValue -Object $MultiAgentRegistry -Name 'valid' -Default $false)) {
    return [pscustomobject]@{
      allowed = @()
      selected = @()
      notes = @('multi-agent registry unavailable')
    }
  }

  foreach ($role in @($MultiAgentRegistry.roles)) {
    $name = [string](Get-RaymanAgenticPropValue -Object $role -Name 'name' -Default '')
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $allowed.Add($name) | Out-Null
  }

  foreach ($rule in @($MultiAgentRegistry.delegation_rules)) {
    $role = [string](Get-RaymanAgenticPropValue -Object $rule -Name 'role' -Default '')
    $mode = [string](Get-RaymanAgenticPropValue -Object $rule -Name 'mode' -Default '')
    $id = [string](Get-RaymanAgenticPropValue -Object $rule -Name 'id' -Default '')
    if ([string]::IsNullOrWhiteSpace($role)) { continue }

    $match = $false
    switch ($id) {
      'explore_before_edit' { $match = ($taskText -match 'explore|multi-file|ambiguous|planner|plan') }
      'risk_review' { $match = ($taskText -match 'review|regression|risk|merge|release') }
      'openai_docs' { $match = ($taskText -match 'openai|model|sdk|docs|mcp|background|prompt optimizer|compaction') }
      'browser_ui' { $match = ($taskText -match 'browser|playwright|web|e2e|page|ui') }
      'windows_uia' { $match = ($taskText -match 'winapp|windows|dialog|desktop|uia|winforms|maui') }
      'sidecar_worker' { $match = ($taskText -match 'patch|implement|fix|test') }
      default { $match = $false }
    }

    if ($match -and $selected -notcontains $role) {
      $selected.Add($role) | Out-Null
      $notes.Add(('{0}: {1}' -f $role, $mode)) | Out-Null
    }
  }

  return [pscustomobject]@{
    allowed = @($allowed.ToArray())
    selected = @($selected.ToArray())
    notes = @($notes.ToArray())
  }
}

function New-RaymanAgenticToolPolicy {
  param(
    [string]$TaskKind,
    [string]$Task,
    [string]$Command,
    [string]$PromptKey,
    [string]$PreferredBackend,
    [object[]]$CapabilityMatches,
    [object]$MultiAgentRegistry,
    [object]$ConfigData
  )

  $budget = Get-RaymanAgenticToolBudget -ConfigData $ConfigData -TaskKind $TaskKind
  $candidates = New-Object System.Collections.Generic.List[object]

  $shellScore = if (-not [string]::IsNullOrWhiteSpace([string]$Command)) { 95 } else { 25 }
  $shellEvidence = if (-not [string]::IsNullOrWhiteSpace([string]$Command)) { 'command output' } else { 'workspace diff and local logs' }
  $candidates.Add([pscustomobject]@{
      key = 'local_shell'
      kind = 'shell'
      score = $shellScore
      matched_triggers = @('default')
      reason = 'Local shell remains the universal fallback and evidence collector.'
      expected_evidence = @($shellEvidence)
      fallback_chain = @()
    }) | Out-Null

  foreach ($capability in @($CapabilityMatches)) {
    $name = [string](Get-RaymanAgenticPropValue -Object $capability -Name 'name' -Default '')
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $matchedTriggers = ConvertTo-RaymanAgenticStringArray -Value (Get-RaymanAgenticPropValue -Object $capability -Name 'matched_triggers' -Default $null)
    $score = 40 + ($matchedTriggers.Count * 10)
    $evidence = @('structured evidence')
    $reason = 'Matched capability triggers.'
    $key = Get-RaymanAgenticCapabilityToolKey -CapabilityName $name
    switch ($name) {
      'openai_docs' {
        $score += 35
        $reason = 'Official OpenAI docs are the primary source for platform-specific guidance.'
        $evidence = @('official doc references', 'verified model/platform notes')
      }
      'web_auto_test' {
        $score += 30
        $reason = 'Browser or UI work should collect reproducible Playwright evidence first.'
        $evidence = @('screenshots', 'console/network evidence', 'trace-ready repro steps')
      }
      'winapp_auto_test' {
        $score += 30
        $reason = 'Windows desktop work should capture UIA/WinApp evidence before fallback.'
        $evidence = @('desktop control tree', 'UIA evidence', 'repro steps')
      }
    }

    $fallbackChain = New-Object System.Collections.Generic.List[string]
    $fallback = [string](Get-RaymanAgenticPropValue -Object $capability -Name 'fallback_command' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($fallback)) {
      $fallbackChain.Add($fallback.Trim()) | Out-Null
    }
    $fallbackChain.Add('local_shell') | Out-Null

    $candidates.Add([pscustomobject]@{
        key = $key
        kind = 'capability'
        score = $score
        matched_triggers = @($matchedTriggers)
        reason = $reason
        expected_evidence = @($evidence)
        fallback_chain = @($fallbackChain.ToArray())
      }) | Out-Null
  }

  $subagents = Get-RaymanSelectedSubagentHints -MultiAgentRegistry $MultiAgentRegistry -TaskKind $TaskKind -Task $Task -Command $Command
  foreach ($role in @($subagents.selected)) {
    $candidates.Add([pscustomobject]@{
        key = $role
        kind = 'subagent'
        score = 55
        matched_triggers = @('delegation_rule')
        reason = 'Multi-agent registry marks this role as relevant for the task shape.'
        expected_evidence = @('scoped findings', 'role-specific notes')
        fallback_chain = @('single_agent')
      }) | Out-Null
  }

  $ordered = @($candidates | Sort-Object @{ Expression = 'score'; Descending = $true }, @{ Expression = 'key'; Descending = $false })
  $maxSelected = [Math]::Max(1, [int](Get-RaymanAgenticPropValue -Object $budget -Name 'max_selected_tools' -Default 3))
  $selected = @($ordered | Select-Object -First $maxSelected)
  $fallbacks = New-Object System.Collections.Generic.List[string]
  foreach ($item in $selected) {
    foreach ($fallback in @(ConvertTo-RaymanAgenticStringArray -Value $item.fallback_chain)) {
      if ($fallbacks -notcontains $fallback) {
        $fallbacks.Add($fallback) | Out-Null
      }
    }
  }

  return [pscustomobject]@{
    schema = 'rayman.agentic.tool_policy.v1'
    task_kind = $TaskKind
    prompt_key = $PromptKey
    preferred_backend = $PreferredBackend
    budget = $budget
    selected_tools = @($selected)
    ranked_candidates = @($ordered)
    fallback_chain = @($fallbacks.ToArray())
    allowed_subagents = @($subagents.allowed)
    selected_subagents = @($subagents.selected)
    subagent_notes = @($subagents.notes)
    selected_tool_keys = @($selected | ForEach-Object { [string]$_.key })
  }
}

function Get-RaymanAgenticAcceptanceCriteria {
  param(
    [string]$TaskKind,
    [string]$Task
  )

  $criteria = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace([string]$Task)) {
    $criteria.Add(("Task goal remains: {0}" -f ([string]$Task).Trim())) | Out-Null
  }
  switch (([string]$TaskKind).Trim().ToLowerInvariant()) {
    'review' {
      $criteria.Add('Reflection outcome must be `done` before the run is treated as successful.') | Out-Null
      $criteria.Add('Doc gate must pass with current plan/tool-policy/reflection artifacts.') | Out-Null
      $criteria.Add('Review-loop success still requires `test-fix` to pass.') | Out-Null
    }
    'release' {
      $criteria.Add('Release checks must stay compatible with existing CLI entrypoints and release gate.') | Out-Null
      $criteria.Add('Doc gate must pass with updated governance artifacts.') | Out-Null
    }
    default {
      $criteria.Add('Selected tool policy must be written before execution.') | Out-Null
      $criteria.Add('Doc gate must pass for the active pipeline stage.') | Out-Null
    }
  }
  return @($criteria.ToArray())
}

function New-RaymanAgenticPlan {
  param(
    [string]$WorkspaceRoot,
    [string]$TaskKind,
    [string]$Task,
    [string]$Command,
    [string]$PromptKey,
    [string]$PreferredBackend,
    [object]$ConfigData,
    [object]$ToolPolicy,
    [object]$CapabilityState = $null
  )

  $paths = Get-RaymanAgenticArtifactPaths -WorkspaceRoot $WorkspaceRoot
  $optional = Get-RaymanAgenticOptionalState -ConfigData $ConfigData -CapabilityState $CapabilityState
  $constraints = New-Object System.Collections.Generic.List[string]
  $constraints.Add(("Follow solution requirements: {0}" -f $paths.requirements_path)) | Out-Null
  $constraints.Add(("Follow release discipline: {0}" -f (Join-Path $WorkspaceRoot '.Rayman\RELEASE_REQUIREMENTS.md'))) | Out-Null
  foreach ($bullet in @(Get-RaymanAgenticSummaryBullets -RequirementsPath $paths.requirements_path | Select-Object -First 5)) {
    $constraints.Add($bullet) | Out-Null
  }

  $requiredDocs = ConvertTo-RaymanAgenticStringArray -Value (Get-RaymanAgenticPropValue -Object (Get-RaymanAgenticPropValue -Object $ConfigData -Name 'required_docs' -Default $null) -Name 'dispatch' -Default $null)
  $planId = [Guid]::NewGuid().ToString('n')

  return [pscustomobject]@{
    schema = 'rayman.agentic.plan.v1'
    plan_id = $planId
    generated_at = (Get-Date).ToString('o')
    workspace_root = $WorkspaceRoot
    task_kind = $TaskKind
    task = $Task
    command = $Command
    prompt_key = $PromptKey
    preferred_backend = $PreferredBackend
    pipeline = [string](Get-RaymanAgenticPropValue -Object $ConfigData -Name 'active_pipeline' -Default 'planner_v1')
    requirements_path = $paths.requirements_path
    constraints = @($constraints.ToArray())
    acceptance_criteria = @(Get-RaymanAgenticAcceptanceCriteria -TaskKind $TaskKind -Task $Task)
    tool_budget = Get-RaymanAgenticToolBudget -ConfigData $ConfigData -TaskKind $TaskKind
    allowed_subagents = @((Get-RaymanAgenticPropValue -Object $ToolPolicy -Name 'allowed_subagents' -Default @()))
    selected_subagents = @((Get-RaymanAgenticPropValue -Object $ToolPolicy -Name 'selected_subagents' -Default @()))
    selected_tool_keys = @((Get-RaymanAgenticPropValue -Object $ToolPolicy -Name 'selected_tool_keys' -Default @()))
    stop_conditions = @(
      'Stop immediately on policy block or missing required artifacts.',
      'Keep the run in planner_v1 only when the doc gate remains satisfied.',
      'Use local fallback when optional OpenAI runtime features are unavailable.'
    )
    required_docs = @($requiredDocs)
    openai_optional = $optional
  }
}

function Ensure-RaymanAgenticArtifacts {
  param([string]$WorkspaceRoot)

  $paths = Get-RaymanAgenticArtifactPaths -WorkspaceRoot $WorkspaceRoot
  Ensure-RaymanAgenticDir -Path $paths.solution_dir
  Ensure-RaymanAgenticDir -Path $paths.agentic_dir

  if (-not (Test-Path -LiteralPath $paths.evals_md -PathType Leaf)) {
    $evalsText = @'
# Rayman Agentic Evals

- planner_prompt: tracked by `.github/prompts/*.prompt.md` and `plan.current.*`
- reflection_prompt: tracked by `reflection.current.*`
- grader_targets:
  - doc gate pass
  - acceptance closed
- reflection outcome distribution
- first-pass stability after planner_v1 rollout
- latest_result: pending
- baseline: pending more than one sample
'@
    Write-RaymanAgenticText -Path $paths.evals_md -Text $evalsText
  }

  if (-not (Test-Path -LiteralPath $paths.plan_md -PathType Leaf)) {
    $planText = @'
# Rayman Agentic Plan

- status: placeholder
- note: generated by `dispatch` when `RAYMAN_AGENT_PIPELINE=planner_v1`
'@
    Write-RaymanAgenticText -Path $paths.plan_md -Text $planText
  }
  if (-not (Test-Path -LiteralPath $paths.plan_json -PathType Leaf)) {
    Write-RaymanAgenticJson -Path $paths.plan_json -Value ([ordered]@{
        schema = 'rayman.agentic.plan.v1'
        status = 'placeholder'
      })
  }

  if (-not (Test-Path -LiteralPath $paths.tool_policy_md -PathType Leaf)) {
    $toolPolicyText = @'
# Rayman Tool Policy

- status: placeholder
- note: generated by `dispatch` when `RAYMAN_AGENT_PIPELINE=planner_v1`
'@
    Write-RaymanAgenticText -Path $paths.tool_policy_md -Text $toolPolicyText
  }
  if (-not (Test-Path -LiteralPath $paths.tool_policy_json -PathType Leaf)) {
    Write-RaymanAgenticJson -Path $paths.tool_policy_json -Value ([ordered]@{
        schema = 'rayman.agentic.tool_policy.v1'
        status = 'placeholder'
      })
  }

  if (-not (Test-Path -LiteralPath $paths.reflection_md -PathType Leaf)) {
    $reflectionText = @'
# Rayman Reflection

- status: placeholder
- note: generated by `review-loop` when `RAYMAN_AGENT_PIPELINE=planner_v1`
'@
    Write-RaymanAgenticText -Path $paths.reflection_md -Text $reflectionText
  }
  if (-not (Test-Path -LiteralPath $paths.reflection_json -PathType Leaf)) {
    Write-RaymanAgenticJson -Path $paths.reflection_json -Value ([ordered]@{
        schema = 'rayman.agentic.reflection.v1'
        status = 'placeholder'
      })
  }

  return $paths
}

function Write-RaymanAgenticPlanArtifacts {
  param(
    [string]$WorkspaceRoot,
    [object]$Plan,
    [object]$ToolPolicy
  )

  $paths = Ensure-RaymanAgenticArtifacts -WorkspaceRoot $WorkspaceRoot
  Write-RaymanAgenticJson -Path $paths.plan_json -Value $Plan
  Write-RaymanAgenticJson -Path $paths.tool_policy_json -Value $ToolPolicy

  $planLines = New-Object System.Collections.Generic.List[string]
  $planLines.Add('# Rayman Agentic Plan') | Out-Null
  $planLines.Add('') | Out-Null
  $planLines.Add(("- plan_id: {0}" -f [string]$Plan.plan_id)) | Out-Null
  $planLines.Add(("- generated_at: {0}" -f [string]$Plan.generated_at)) | Out-Null
  $planLines.Add(("- task_kind: {0}" -f [string]$Plan.task_kind)) | Out-Null
  $planLines.Add(("- prompt_key: {0}" -f [string]$Plan.prompt_key)) | Out-Null
  $planLines.Add(("- pipeline: {0}" -f [string]$Plan.pipeline)) | Out-Null
  $planLines.Add('') | Out-Null
  $planLines.Add('## Goal') | Out-Null
  $planLines.Add('') | Out-Null
  if (-not [string]::IsNullOrWhiteSpace([string]$Plan.task)) {
    $planLines.Add(("- {0}" -f [string]$Plan.task.Trim())) | Out-Null
  } elseif (-not [string]::IsNullOrWhiteSpace([string]$Plan.command)) {
    $planLines.Add(('- Run command: `{0}`' -f [string]$Plan.command.Trim())) | Out-Null
  } else {
    $planLines.Add('- General engineering workflow') | Out-Null
  }
  $planLines.Add('') | Out-Null
  $planLines.Add('## Constraints') | Out-Null
  $planLines.Add('') | Out-Null
  foreach ($item in @($Plan.constraints)) {
    $planLines.Add(("- {0}" -f [string]$item)) | Out-Null
  }
  $planLines.Add('') | Out-Null
  $planLines.Add('## Acceptance Criteria') | Out-Null
  $planLines.Add('') | Out-Null
  foreach ($item in @($Plan.acceptance_criteria)) {
    $planLines.Add(("- {0}" -f [string]$item)) | Out-Null
  }
  $planLines.Add('') | Out-Null
  $planLines.Add('## Selected Tools') | Out-Null
  $planLines.Add('') | Out-Null
  foreach ($item in @($ToolPolicy.selected_tools)) {
    $planLines.Add(('- `{0}` score={1} reason={2}' -f [string]$item.key, [int]$item.score, [string]$item.reason)) | Out-Null
  }
  if (@($ToolPolicy.selected_tools).Count -eq 0) {
    $planLines.Add('- (none)') | Out-Null
  }
  $planLines.Add('') | Out-Null
  $planLines.Add('## Required Docs') | Out-Null
  $planLines.Add('') | Out-Null
  foreach ($item in @($Plan.required_docs)) {
    $planLines.Add(('- `{0}`' -f [string]$item)) | Out-Null
  }

  Write-RaymanAgenticText -Path $paths.plan_md -Text ($planLines -join "`r`n")

  $policyLines = New-Object System.Collections.Generic.List[string]
  $policyLines.Add('# Rayman Tool Policy') | Out-Null
  $policyLines.Add('') | Out-Null
  $policyLines.Add(("- task_kind: {0}" -f [string]$ToolPolicy.task_kind)) | Out-Null
  $policyLines.Add(("- prompt_key: {0}" -f [string]$ToolPolicy.prompt_key)) | Out-Null
  $policyLines.Add(("- preferred_backend: {0}" -f [string]$ToolPolicy.preferred_backend)) | Out-Null
  $policyLines.Add('') | Out-Null
  $policyLines.Add('## Selected Tools') | Out-Null
  $policyLines.Add('') | Out-Null
  foreach ($item in @($ToolPolicy.selected_tools)) {
    $policyLines.Add(('- `{0}` ({1}) score={2}' -f [string]$item.key, [string]$item.kind, [int]$item.score)) | Out-Null
    foreach ($evidence in @(ConvertTo-RaymanAgenticStringArray -Value $item.expected_evidence)) {
      $policyLines.Add(("  evidence: {0}" -f [string]$evidence)) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$item.reason)) {
      $policyLines.Add(("  reason: {0}" -f [string]$item.reason)) | Out-Null
    }
  }
  if (@($ToolPolicy.selected_tools).Count -eq 0) {
    $policyLines.Add('- (none)') | Out-Null
  }
  $policyLines.Add('') | Out-Null
  $policyLines.Add('## Fallback Chain') | Out-Null
  $policyLines.Add('') | Out-Null
  foreach ($item in @($ToolPolicy.fallback_chain)) {
    $policyLines.Add(('- `{0}`' -f [string]$item)) | Out-Null
  }
  if (@($ToolPolicy.fallback_chain).Count -eq 0) {
    $policyLines.Add('- (none)') | Out-Null
  }
  $policyLines.Add('') | Out-Null
  $policyLines.Add('## Selected Subagents') | Out-Null
  $policyLines.Add('') | Out-Null
  foreach ($item in @($ToolPolicy.selected_subagents)) {
    $policyLines.Add(('- `{0}`' -f [string]$item)) | Out-Null
  }
  if (@($ToolPolicy.selected_subagents).Count -eq 0) {
    $policyLines.Add('- (none)') | Out-Null
  }

  Write-RaymanAgenticText -Path $paths.tool_policy_md -Text ($policyLines -join "`r`n")
  return $paths
}

function Get-RaymanAgenticRequiredDocPathsForStage {
  param(
    [string]$WorkspaceRoot,
    [object]$ConfigData,
    [string]$Stage
  )

  $paths = Get-RaymanAgenticArtifactPaths -WorkspaceRoot $WorkspaceRoot
  $names = ConvertTo-RaymanAgenticStringArray -Value (Get-RaymanAgenticPropValue -Object (Get-RaymanAgenticPropValue -Object $ConfigData -Name 'required_docs' -Default $null) -Name $Stage -Default $null)
  $items = New-Object System.Collections.Generic.List[object]
  foreach ($name in $names) {
    $full = Join-Path $paths.agentic_dir $name
    $relative = ('{0}/agentic/{1}' -f $paths.solution_dir_name, $name).Replace('\', '/')
    $items.Add([pscustomobject]@{
        name = $name
        full_path = $full
        relative_path = $relative
      }) | Out-Null
  }
  return @($items.ToArray())
}

function Test-RaymanAgenticDocGateEnabled {
  param([object]$ConfigData)

  return [bool](Get-RaymanAgenticPropValue -Object $ConfigData -Name 'doc_gate_enabled' -Default $true)
}

function Test-RaymanAgenticDocGate {
  param(
    [string]$WorkspaceRoot,
    [object]$ConfigData,
    [string]$Stage,
    [datetime]$UpdatedAfter = [datetime]::MinValue,
    [string[]]$UpdatedDocNames = @()
  )

  $paths = Get-RaymanAgenticArtifactPaths -WorkspaceRoot $WorkspaceRoot
  $required = @(Get-RaymanAgenticRequiredDocPathsForStage -WorkspaceRoot $WorkspaceRoot -ConfigData $ConfigData -Stage $Stage)
  if (-not (Test-RaymanAgenticDocGateEnabled -ConfigData $ConfigData)) {
    return [pscustomobject]@{
      schema = 'rayman.agentic.doc_gate.v1'
      stage = $Stage
      enabled = $false
      disabled_reason = 'disabled_by_config'
      pass = $true
      requirements_path = $paths.requirements_path
      required_docs = @($required)
      missing_docs = @()
      stale_docs = @()
      missing_links = @()
      linked_docs = @()
    }
  }

  $content = ''
  if (Test-Path -LiteralPath $paths.requirements_path -PathType Leaf) {
    $content = [string](Get-Content -LiteralPath $paths.requirements_path -Raw -Encoding UTF8)
  }

  $missing = New-Object System.Collections.Generic.List[string]
  $stale = New-Object System.Collections.Generic.List[string]
  $missingLinks = New-Object System.Collections.Generic.List[string]
  $linked = New-Object System.Collections.Generic.List[string]
  $updatedSet = @{}
  foreach ($name in @(ConvertTo-RaymanAgenticStringArray -Value $UpdatedDocNames)) {
    $updatedSet[$name] = $true
  }

  foreach ($doc in $required) {
    if (-not (Test-Path -LiteralPath $doc.full_path -PathType Leaf)) {
      $missing.Add($doc.relative_path) | Out-Null
      continue
    }
    if (-not [string]::IsNullOrWhiteSpace($content) -and $content.Contains($doc.relative_path)) {
      $linked.Add($doc.relative_path) | Out-Null
    } else {
      $missingLinks.Add($doc.relative_path) | Out-Null
    }
    if ($UpdatedAfter -ne [datetime]::MinValue -and $updatedSet.ContainsKey([string]$doc.name)) {
      $item = Get-Item -LiteralPath $doc.full_path -ErrorAction SilentlyContinue
      if ($null -eq $item -or $item.LastWriteTime -lt $UpdatedAfter) {
        $stale.Add($doc.relative_path) | Out-Null
      }
    }
  }

  return [pscustomobject]@{
    schema = 'rayman.agentic.doc_gate.v1'
    stage = $Stage
    enabled = $true
    disabled_reason = ''
    pass = ($missing.Count -eq 0 -and $stale.Count -eq 0 -and $missingLinks.Count -eq 0)
    requirements_path = $paths.requirements_path
    required_docs = @($required)
    missing_docs = @($missing.ToArray())
    stale_docs = @($stale.ToArray())
    missing_links = @($missingLinks.ToArray())
    linked_docs = @($linked.ToArray())
  }
}

function New-RaymanReflection {
  param(
    [string]$WorkspaceRoot,
    [object]$ConfigData,
    [string]$TaskKind,
    [string]$Task,
    [object]$Plan,
    [object]$ToolPolicy,
    [int]$Round,
    [int]$MaxRounds,
    [int]$TestExit,
    [string]$ErrorKind,
    [bool]$PolicyOk,
    [object]$DiffSummary,
    [int]$FallbackCount = 0,
    [int]$ReplanCount = 0,
    [object]$DocGate = $null
  )

  if ($null -eq $DocGate) {
    $DocGate = Test-RaymanAgenticDocGate -WorkspaceRoot $WorkspaceRoot -ConfigData $ConfigData -Stage 'review_loop'
  }

  $outcome = 'blocked'
  $reason = ''
  if (-not [bool]$PolicyOk) {
    $outcome = 'blocked'
    $reason = if (-not [string]::IsNullOrWhiteSpace([string]$ErrorKind)) { [string]$ErrorKind } else { 'policy_failed' }
  } elseif (-not [bool]$DocGate.pass) {
    $outcome = 'blocked'
    $reason = 'doc_gate_failed'
  } elseif ($TestExit -eq 0) {
    $outcome = 'done'
    $reason = 'tests_passed_and_docs_closed'
  } elseif ($Round -lt $MaxRounds) {
    $outcome = 'replan'
    $reason = 'tests_failed_but_budget_remaining'
  } else {
    $outcome = 'escalate'
    $reason = 'tests_failed_after_max_rounds'
  }

  $diffTouched = 0
  $diffNetLines = 0
  if ($null -ne $DiffSummary) {
    $diffTouched = [int](Get-RaymanAgenticPropValue -Object $DiffSummary -Name 'touched_files_count' -Default 0)
    $diffNetLines = [int](Get-RaymanAgenticPropValue -Object $DiffSummary -Name 'net_line_delta' -Default 0)
  }

  return [pscustomobject]@{
    schema = 'rayman.agentic.reflection.v1'
    generated_at = (Get-Date).ToString('o')
    workspace_root = $WorkspaceRoot
    stage = 'review_loop'
    task_kind = $TaskKind
    task = $Task
    plan_id = [string](Get-RaymanAgenticPropValue -Object $Plan -Name 'plan_id' -Default '')
    round = $Round
    max_rounds = $MaxRounds
    outcome = $outcome
    reason = $reason
    acceptance_closed = ($outcome -eq 'done')
    policy_ok = $PolicyOk
    doc_gate_pass = [bool](Get-RaymanAgenticPropValue -Object $DocGate -Name 'pass' -Default $false)
    doc_gate = $DocGate
    selected_tools = @((Get-RaymanAgenticPropValue -Object $ToolPolicy -Name 'selected_tool_keys' -Default @()))
    fallback_count = $FallbackCount
    replan_count = $ReplanCount
    test_exit = $TestExit
    error_kind = $ErrorKind
    diff_summary = [pscustomobject]@{
      touched_files_count = $diffTouched
      net_line_delta = $diffNetLines
    }
  }
}

function Write-RaymanReflectionArtifacts {
  param(
    [string]$WorkspaceRoot,
    [object]$Reflection
  )

  $paths = Ensure-RaymanAgenticArtifacts -WorkspaceRoot $WorkspaceRoot
  Write-RaymanAgenticJson -Path $paths.reflection_json -Value $Reflection

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# Rayman Reflection') | Out-Null
  $lines.Add('') | Out-Null
  foreach ($key in @('generated_at', 'plan_id', 'round', 'max_rounds', 'outcome', 'reason', 'test_exit', 'error_kind')) {
    $lines.Add(("- {0}: {1}" -f $key, [string](Get-RaymanAgenticPropValue -Object $Reflection -Name $key -Default ''))) | Out-Null
  }
  $lines.Add('') | Out-Null
  $lines.Add('## Acceptance') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add(("- acceptance_closed: {0}" -f [string]([bool](Get-RaymanAgenticPropValue -Object $Reflection -Name 'acceptance_closed' -Default $false)).ToString().ToLowerInvariant())) | Out-Null
  $lines.Add(("- doc_gate_pass: {0}" -f [string]([bool](Get-RaymanAgenticPropValue -Object $Reflection -Name 'doc_gate_pass' -Default $false)).ToString().ToLowerInvariant())) | Out-Null
  $lines.Add(("- policy_ok: {0}" -f [string]([bool](Get-RaymanAgenticPropValue -Object $Reflection -Name 'policy_ok' -Default $false)).ToString().ToLowerInvariant())) | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add('## Selected Tools') | Out-Null
  $lines.Add('') | Out-Null
  foreach ($item in @(Get-RaymanAgenticPropValue -Object $Reflection -Name 'selected_tools' -Default @())) {
    $lines.Add(('- `{0}`' -f [string]$item)) | Out-Null
  }
  if (@(Get-RaymanAgenticPropValue -Object $Reflection -Name 'selected_tools' -Default @()).Count -eq 0) {
    $lines.Add('- (none)') | Out-Null
  }

  Write-RaymanAgenticText -Path $paths.reflection_md -Text ($lines -join "`r`n")
  return $paths
}
