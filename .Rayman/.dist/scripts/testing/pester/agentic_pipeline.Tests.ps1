Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  $script:DispatchScript = Join-Path $script:RepoRoot '.Rayman\scripts\agents\dispatch.ps1'
  $script:ReviewLoopScript = Join-Path $script:RepoRoot '.Rayman\scripts\agents\review_loop.ps1'
  . (Join-Path $script:RepoRoot '.Rayman\scripts\agents\agentic_pipeline.ps1')
}

function script:New-AgenticWorkspace {
  param(
    [string]$Root,
    [switch]$IncludeManagedDocLinks
  )

  New-Item -ItemType Directory -Force -Path (Join-Path $Root '.Rayman\config') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $Root '.Rayman\scripts\repair') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $Root '.Rayman\scripts\agents') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $Root '.Rayman\scripts\utils') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $Root '.RaymanAgent') | Out-Null
  Set-Content -LiteralPath (Join-Path $Root '.SolutionName') -Encoding UTF8 -Value 'RaymanAgent'
  Set-Content -LiteralPath (Join-Path $Root '.Rayman\RELEASE_REQUIREMENTS.md') -Encoding UTF8 -Value '# release'
  foreach ($rel in @(
    '.Rayman\common.ps1',
    '.Rayman\config\agent_router.json',
    '.Rayman\config\agent_policy.json',
    '.Rayman\config\review_loop.json',
    '.Rayman\config\model_routing.json',
    '.Rayman\config\agent_capabilities.json',
    '.Rayman\config\codex_multi_agent.json',
    '.Rayman\config\agentic_pipeline.json',
    '.Rayman\scripts\agents\dispatch.ps1',
    '.Rayman\scripts\agents\context_audit.ps1',
    '.Rayman\scripts\agents\prompts_catalog.ps1',
    '.Rayman\scripts\utils\event_hooks.ps1',
    '.Rayman\scripts\utils\request_attention.ps1',
    '.Rayman\scripts\utils\generate_context.ps1',
    '.Rayman\scripts\repair\ensure_complete_rayman.ps1'
  )) {
    Copy-Item -LiteralPath (Join-Path $script:RepoRoot $rel) -Destination (Join-Path $Root $rel) -Force
  }
  Set-Content -LiteralPath (Join-Path $Root '.Rayman\scripts\repair\run_tests_and_fix.ps1') -Encoding UTF8 -Value @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
exit 0
'@

  $requirementLines = @(
    '# RaymanAgent Requirements',
    '',
    '- (none detected)'
  )
  if ($IncludeManagedDocLinks) {
    $requirementLines += @(
      '- .RaymanAgent/agentic/plan.current.md',
      '- .RaymanAgent/agentic/plan.current.json',
      '- .RaymanAgent/agentic/tool-policy.md',
      '- .RaymanAgent/agentic/tool-policy.json',
      '- .RaymanAgent/agentic/reflection.current.md',
      '- .RaymanAgent/agentic/reflection.current.json',
      '- .RaymanAgent/agentic/evals.md'
    )
  }
  Set-Content -LiteralPath (Join-Path $Root '.RaymanAgent\.RaymanAgent.requirements.md') -Encoding UTF8 -Value $requirementLines
}

Describe 'agentic pipeline helpers' {
  BeforeEach {
    $script:agenticEnvBackup = @{}
    foreach ($name in @(
      'RAYMAN_AGENT_PIPELINE',
      'RAYMAN_AGENT_DOC_GATE',
      'RAYMAN_AGENT_OPENAI_OPTIONAL',
      'RAYMAN_SYSTEM_SLIM_ENABLED',
      'RAYMAN_INTERACTION_MODE'
    )) {
      $script:agenticEnvBackup[$name] = [Environment]::GetEnvironmentVariable($name)
      [Environment]::SetEnvironmentVariable($name, $null)
    }
    $script:originalPath = [Environment]::GetEnvironmentVariable('PATH')
    $script:codexFunctionBackup = if (Test-Path Function:\codex) { (Get-Item Function:\codex).ScriptBlock.ToString() } else { $null }
    if (Test-Path Function:\codex) {
      Remove-Item Function:\codex -Force
    }
    [Environment]::SetEnvironmentVariable('OPENAI_API_KEY', $null)
    [Environment]::SetEnvironmentVariable('RAYMAN_STUB_LOG', $null)
  }

  AfterEach {
    foreach ($entry in $script:agenticEnvBackup.GetEnumerator()) {
      [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value)
    }
    [Environment]::SetEnvironmentVariable('PATH', $script:originalPath)
    [Environment]::SetEnvironmentVariable('OPENAI_API_KEY', $null)
    [Environment]::SetEnvironmentVariable('RAYMAN_STUB_LOG', $null)
    if (Test-Path Function:\codex) {
      Remove-Item Function:\codex -Force
    }
    if ($null -ne $script:codexFunctionBackup) {
      Set-Item Function:\codex -Value ([scriptblock]::Create($script:codexFunctionBackup))
    }
  }

  It 'loads planner_v1 defaults and honors env overrides' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_agentic_cfg_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\config') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\config\agentic_pipeline.json') -Encoding UTF8 -Value @'
{
  "schema": "rayman.agentic_pipeline.v1",
  "default_pipeline": "planner_v1",
  "legacy_pipeline_name": "legacy",
  "doc_gate_enabled": true,
  "openai_optional": "auto"
}
'@

      $defaults = Get-RaymanAgenticPipelineConfig -WorkspaceRoot $root
      $defaults.data.active_pipeline | Should -Be 'planner_v1'
      $defaults.data.doc_gate_enabled | Should -BeTrue
      $defaults.data.openai_optional | Should -Be 'auto'

      [Environment]::SetEnvironmentVariable('RAYMAN_AGENT_PIPELINE', 'legacy')
      [Environment]::SetEnvironmentVariable('RAYMAN_AGENT_DOC_GATE', '0')
      [Environment]::SetEnvironmentVariable('RAYMAN_AGENT_OPENAI_OPTIONAL', 'off')

      $overridden = Get-RaymanAgenticPipelineConfig -WorkspaceRoot $root
      $overridden.data.active_pipeline | Should -Be 'legacy'
      $overridden.data.doc_gate_enabled | Should -BeFalse
      $overridden.data.openai_optional | Should -Be 'off'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'ranks tools, keeps subagent hints, and deduplicates fallbacks' {
    $config = (Get-RaymanAgenticPipelineConfig -WorkspaceRoot $script:RepoRoot).data
    $matches = @(
      [pscustomobject]@{
        name = 'openai_docs'
        matched_triggers = @('openai', 'model')
        fallback_command = 'rayman docs'
      }
    )
    $multiAgent = [pscustomobject]@{
      valid = $true
      roles = @(
        [pscustomobject]@{ name = 'rayman_docs_researcher' }
      )
      delegation_rules = @(
        [pscustomobject]@{ id = 'openai_docs'; role = 'rayman_docs_researcher'; mode = 'required' }
      )
    }

    $policy = New-RaymanAgenticToolPolicy -TaskKind 'review' -Task 'OpenAI model review' -Command '' -PromptKey '' -PreferredBackend '' -CapabilityMatches $matches -MultiAgentRegistry $multiAgent -ConfigData $config

    @($policy.selected_tool_keys) | Should -Contain 'openai_docs_mcp'
    @($policy.selected_subagents) | Should -Contain 'rayman_docs_researcher'
    @($policy.fallback_chain) | Should -Contain 'rayman docs'
    @($policy.fallback_chain) | Should -Contain 'local_shell'
    @(@($policy.fallback_chain) | Group-Object | Where-Object { $_.Count -gt 1 }).Count | Should -Be 0
  }

  It 'marks optional features disabled until supported and still requests them for delegated prompt work' {
    function global:codex { param([Parameter(ValueFromRemainingArguments = $true)] $Args) 'codex 1.0.0' }
    $config = (Get-RaymanAgenticPipelineConfig -WorkspaceRoot $script:RepoRoot).data
    $matches = @(
      [pscustomobject]@{
        name = 'openai_docs'
        matched_triggers = @('openai', 'docs', 'model')
        fallback_command = 'rayman docs'
      }
    )
    $multiAgent = [pscustomobject]@{
      valid = $true
      roles = @([pscustomobject]@{ name = 'rayman_docs_researcher' })
      delegation_rules = @([pscustomobject]@{ id = 'openai_docs'; role = 'rayman_docs_researcher'; mode = 'required' })
    }
    $capabilityState = [pscustomobject]@{
      capabilities = @([pscustomobject]@{ name = 'openai_docs'; active = $true })
    }

    $policy = New-RaymanAgenticToolPolicy -TaskKind 'review' -Task 'OpenAI docs prompt review' -Command '' -PromptKey 'review.initial.prompt.md' -PreferredBackend '' -CapabilityMatches $matches -MultiAgentRegistry $multiAgent -ConfigData $config
    $contract = New-RaymanAgenticExecutionContract -TaskKind 'review' -Task 'OpenAI docs prompt review' -Command '' -PromptKey 'review.initial.prompt.md' -PreferredBackend '' -ToolPolicy $policy -CapabilityMatches $matches -ConfigData $config -CapabilityState $capabilityState

    foreach ($feature in @($contract.optional_state.features)) {
      $feature.available | Should -BeFalse
      $feature.support_mode | Should -Be 'disabled_until_supported'
      $feature.support_reason | Should -Be 'delegated_codex_executor_not_implemented'
      $feature.reason | Should -Be 'disabled_until_supported'
    }
    @($contract.optional_requests | ForEach-Object { $_.name }) | Should -Contain 'background_mode'
    @($contract.optional_requests | ForEach-Object { $_.name }) | Should -Contain 'compaction'
    @($contract.optional_requests | ForEach-Object { $_.name }) | Should -Contain 'prompt_optimizer'
    @($contract.optional_requests | Where-Object { $_.name -eq 'background_mode' } | Select-Object -First 1).available | Should -BeFalse
  }

  It 'builds an execution contract that prioritizes codex and local fallback' {
    $config = (Get-RaymanAgenticPipelineConfig -WorkspaceRoot $script:RepoRoot).data
    $matches = @(
      [pscustomobject]@{
        name = 'web_auto_test'
        matched_triggers = @('browser', 'ui', 'e2e')
        prepare_command = 'rayman ensure-playwright'
        fallback_command = 'rayman pwa-test'
      }
    )
    $multiAgent = [pscustomobject]@{
      valid = $true
      roles = @([pscustomobject]@{ name = 'rayman_browser_debugger' })
      delegation_rules = @([pscustomobject]@{ id = 'browser_ui'; role = 'rayman_browser_debugger'; mode = 'required' })
    }

    $policy = New-RaymanAgenticToolPolicy -TaskKind 'review' -Task 'browser ui e2e review' -Command '' -PromptKey '' -PreferredBackend '' -CapabilityMatches $matches -MultiAgentRegistry $multiAgent -ConfigData $config
    $contract = New-RaymanAgenticExecutionContract -TaskKind 'review' -Task 'browser ui e2e review' -Command '' -PromptKey '' -PreferredBackend '' -ToolPolicy $policy -CapabilityMatches $matches -ConfigData $config

    $contract.delegation_required | Should -BeTrue
    $contract.backend_order[0] | Should -Be 'codex'
    @($contract.backend_order) | Should -Contain 'local'
    $contract.local_fallback_command | Should -Be 'rayman pwa-test'
    @($contract.prepare_commands) | Should -Contain 'rayman ensure-playwright'
  }

  It 'fails the review doc gate when managed links are missing from solution requirements' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_agentic_gate_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\config') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.RaymanAgent') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.SolutionName') -Encoding UTF8 -Value 'RaymanAgent'
      Set-Content -LiteralPath (Join-Path $root '.RaymanAgent\.RaymanAgent.requirements.md') -Encoding UTF8 -Value @'
# RaymanAgent Requirements

- (none detected)
- .RaymanAgent/agentic/plan.current.md
- .RaymanAgent/agentic/plan.current.json
- .RaymanAgent/agentic/tool-policy.md
- .RaymanAgent/agentic/tool-policy.json
- .RaymanAgent/agentic/evals.md
'@
      Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\config\agentic_pipeline.json') -Destination (Join-Path $root '.Rayman\config\agentic_pipeline.json')

      Ensure-RaymanAgenticArtifacts -WorkspaceRoot $root | Out-Null
      $config = (Get-RaymanAgenticPipelineConfig -WorkspaceRoot $root).data
      $gate = Test-RaymanAgenticDocGate -WorkspaceRoot $root -ConfigData $config -Stage 'review_loop'

      $gate.pass | Should -BeFalse
      @($gate.missing_links) | Should -Contain '.RaymanAgent/agentic/reflection.current.md'
      @($gate.missing_links) | Should -Contain '.RaymanAgent/agentic/reflection.current.json'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'writes plan and reflection artifacts and closes acceptance on done' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_agentic_done_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\config') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.RaymanAgent') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.SolutionName') -Encoding UTF8 -Value 'RaymanAgent'
      Set-Content -LiteralPath (Join-Path $root '.Rayman\RELEASE_REQUIREMENTS.md') -Encoding UTF8 -Value '# release'
      Set-Content -LiteralPath (Join-Path $root '.RaymanAgent\.RaymanAgent.requirements.md') -Encoding UTF8 -Value @'
# RaymanAgent Requirements

- (none detected)
- .RaymanAgent/agentic/plan.current.md
- .RaymanAgent/agentic/plan.current.json
- .RaymanAgent/agentic/tool-policy.md
- .RaymanAgent/agentic/tool-policy.json
- .RaymanAgent/agentic/reflection.current.md
- .RaymanAgent/agentic/reflection.current.json
- .RaymanAgent/agentic/evals.md
'@
      Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\config\agentic_pipeline.json') -Destination (Join-Path $root '.Rayman\config\agentic_pipeline.json')

      $config = (Get-RaymanAgenticPipelineConfig -WorkspaceRoot $root).data
      $policy = New-RaymanAgenticToolPolicy -TaskKind 'review' -Task 'smoke review loop' -Command '' -PromptKey '' -PreferredBackend '' -CapabilityMatches @() -MultiAgentRegistry ([pscustomobject]@{ valid = $false }) -ConfigData $config

      $plan = New-RaymanAgenticPlan -WorkspaceRoot $root -TaskKind 'review' -Task 'smoke review loop' -Command '' -PromptKey '' -PreferredBackend '' -ConfigData $config -ToolPolicy $policy
      Write-RaymanAgenticPlanArtifacts -WorkspaceRoot $root -Plan $plan -ToolPolicy $policy | Out-Null

      $dispatchGate = Test-RaymanAgenticDocGate -WorkspaceRoot $root -ConfigData $config -Stage 'dispatch'
      $dispatchGate.pass | Should -BeTrue

      $reflection = New-RaymanReflection -WorkspaceRoot $root -ConfigData $config -TaskKind 'review' -Task 'smoke review loop' -Plan $plan -ToolPolicy $policy -Round 1 -MaxRounds 2 -TestExit 0 -ErrorKind 'ok' -PolicyOk $true -DiffSummary ([pscustomobject]@{ touched_files_count = 1; net_line_delta = 2 }) -FallbackCount 1 -ReplanCount 0 -DocGate ([pscustomobject]@{ pass = $true })
      $reflection.outcome | Should -Be 'done'
      $reflection.acceptance_closed | Should -BeTrue

      Write-RaymanReflectionArtifacts -WorkspaceRoot $root -Reflection $reflection | Out-Null
      $reviewGate = Test-RaymanAgenticDocGate -WorkspaceRoot $root -ConfigData $config -Stage 'review_loop'
      $reviewGate.pass | Should -BeTrue
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'returns replan, escalate, and blocked when acceptance stays open' {
    $config = (Get-RaymanAgenticPipelineConfig -WorkspaceRoot $script:RepoRoot).data
    $plan = [pscustomobject]@{ plan_id = 'plan-1' }
    $policy = [pscustomobject]@{ selected_tool_keys = @('local_shell') }
    $docGate = [pscustomobject]@{ pass = $true }

    $replan = New-RaymanReflection -WorkspaceRoot $script:RepoRoot -ConfigData $config -TaskKind 'review' -Task 'replan case' -Plan $plan -ToolPolicy $policy -Round 1 -MaxRounds 2 -TestExit 1 -ErrorKind 'test_fix_failed' -PolicyOk $true -DiffSummary $null -FallbackCount 0 -ReplanCount 0 -DocGate $docGate
    $replan.outcome | Should -Be 'replan'
    $replan.acceptance_closed | Should -BeFalse

    $escalate = New-RaymanReflection -WorkspaceRoot $script:RepoRoot -ConfigData $config -TaskKind 'review' -Task 'escalate case' -Plan $plan -ToolPolicy $policy -Round 2 -MaxRounds 2 -TestExit 1 -ErrorKind 'test_fix_failed' -PolicyOk $true -DiffSummary $null -FallbackCount 0 -ReplanCount 1 -DocGate $docGate
    $escalate.outcome | Should -Be 'escalate'

    $blocked = New-RaymanReflection -WorkspaceRoot $script:RepoRoot -ConfigData $config -TaskKind 'review' -Task 'blocked case' -Plan $plan -ToolPolicy $policy -Round 1 -MaxRounds 2 -TestExit 0 -ErrorKind 'dispatch_policy_blocked' -PolicyOk $false -DiffSummary $null -FallbackCount 0 -ReplanCount 0 -DocGate $docGate
    $blocked.outcome | Should -Be 'blocked'
  }

  It 'writes dispatch dry-run execution contract into the summary' {
    function global:codex { param([Parameter(ValueFromRemainingArguments = $true)] $Args) 'codex 1.0.0' }
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_agentic_dispatch_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-AgenticWorkspace -Root $root -IncludeManagedDocLinks
      $dispatchScript = Join-Path $root '.Rayman\scripts\agents\dispatch.ps1'

      & $dispatchScript -WorkspaceRoot $root -TaskKind 'review' -Task 'OpenAI docs prompt review' -PromptKey 'review.initial.prompt.md' -DryRun | Out-Null
      $summary = Get-Content -LiteralPath (Join-Path $root '.Rayman\runtime\agent_runs\last.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      $eventText = @((Get-ChildItem -LiteralPath (Join-Path $root '.Rayman\runtime\events') -Filter '*.jsonl' -ErrorAction SilentlyContinue | ForEach-Object {
            Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
          })) -join "`n"

      $summary.agentic_execution.backend_order[0] | Should -Be 'codex'
      $summary.interaction_mode | Should -Be 'detailed'
      $summary.context_audit.blocked | Should -BeFalse
      $summary.context_audit.effective_mode | Should -Be 'block'
      $summary.codex_capability_preamble | Should -Match '\[RaymanInteractionMode\]'
      @($summary.agentic_execution.optional_requests | ForEach-Object { $_.name }) | Should -Contain 'background_mode'
      @($summary.agentic_execution.optional_requests | ForEach-Object { $_.name }) | Should -Contain 'prompt_optimizer'
      @($summary.agentic_execution.optional_requests | Where-Object { $_.name -eq 'background_mode' } | Select-Object -First 1).support_mode | Should -Be 'disabled_until_supported'
      @($summary.agentic_execution.optional_requests | Where-Object { $_.name -eq 'background_mode' } | Select-Object -First 1).available | Should -BeFalse
      $eventText | Should -Match '"event_type":"dispatch.start"'
      $eventText | Should -Match '"event_type":"dispatch.finish"'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'skips agentic doc-gate blocking when disabled via env override' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_agentic_dispatch_doc_off_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-AgenticWorkspace -Root $root
      $dispatchScript = Join-Path $root '.Rayman\scripts\agents\dispatch.ps1'
      [Environment]::SetEnvironmentVariable('RAYMAN_AGENT_DOC_GATE', '0')

      & $dispatchScript -WorkspaceRoot $root -TaskKind 'review' -Task 'OpenAI docs prompt review' -DryRun | Out-Null
      $LASTEXITCODE | Should -Be 0

      $summary = Get-Content -LiteralPath (Join-Path $root '.Rayman\runtime\agent_runs\last.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      $summary.agentic_doc_gate.pass | Should -BeTrue
      $summary.agentic_doc_gate.enabled | Should -BeFalse
      $summary.selected_backend | Should -Not -Be 'blocked'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'runs prepare and local fallback when delegated codex degrades to local without an explicit command' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_agentic_fallback_' + [Guid]::NewGuid().ToString('N'))
    $binDir = Join-Path $root 'bin'
    $stubLog = Join-Path $root 'rayman.stub.log'
    try {
      New-AgenticWorkspace -Root $root -IncludeManagedDocLinks
      $dispatchScript = Join-Path $root '.Rayman\scripts\agents\dispatch.ps1'
      New-Item -ItemType Directory -Force -Path $binDir | Out-Null
      Set-Content -LiteralPath (Join-Path $binDir 'rayman.cmd') -Encoding ASCII -Value @'
@echo off
echo %*>>"%RAYMAN_STUB_LOG%"
exit /b 0
'@
      [Environment]::SetEnvironmentVariable('RAYMAN_SYSTEM_SLIM_ENABLED', '0')
      [Environment]::SetEnvironmentVariable('RAYMAN_STUB_LOG', $stubLog)
      [Environment]::SetEnvironmentVariable('PATH', ('{0};{1};{2}' -f $binDir, $env:SystemRoot, (Join-Path $env:SystemRoot 'System32')))

      & $dispatchScript -WorkspaceRoot $root -TaskKind 'review' -Task 'browser ui e2e review' | Out-Null
      $summary = Get-Content -LiteralPath (Join-Path $root '.Rayman\runtime\agent_runs\last.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      $stubLines = @(Get-Content -LiteralPath $stubLog -Encoding UTF8)

      $summary.selected_backend | Should -Be 'local'
      $summary.executed_command | Should -Be 'rayman pwa-test'
      $summary.agentic_execution.prepare_results.Count | Should -Be 1
      $stubLines[0] | Should -Match 'ensure-playwright'
      $stubLines[1] | Should -Match 'pwa-test'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'excludes agentic artifacts from review-loop diff telemetry' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_agentic_review_diff_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-AgenticWorkspace -Root $root -IncludeManagedDocLinks

      & $script:ReviewLoopScript -WorkspaceRoot $root -TaskKind 'review' -Task 'OpenAI docs review' -MaxRounds 1 | Out-Null
      $summary = Get-Content -LiteralPath (Join-Path $root '.Rayman\runtime\review_loop.last.json') -Raw -Encoding UTF8 | ConvertFrom-Json

      $summary.success | Should -BeTrue
      $summary.rounds[0].diff_summary.touched_files_count | Should -Be 0
      $summary.rounds[0].diff_summary.net_line_delta | Should -Be 0
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'preserves agentic doc-gate block reasons through review-loop summaries' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_agentic_review_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-AgenticWorkspace -Root $root

      & $script:ReviewLoopScript -WorkspaceRoot $root -TaskKind 'review' -Task 'OpenAI docs review' -MaxRounds 1 | Out-Null
      $summary = Get-Content -LiteralPath (Join-Path $root '.Rayman\runtime\review_loop.last.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      $eventText = @((Get-ChildItem -LiteralPath (Join-Path $root '.Rayman\runtime\events') -Filter '*.jsonl' -ErrorAction SilentlyContinue | ForEach-Object {
            Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
          })) -join "`n"

      $summary.final_error_kind | Should -Be 'agentic_doc_gate_failed'
      $summary.context_audit.blocked | Should -BeFalse
      $summary.rounds[0].error_kind | Should -Be 'agentic_doc_gate_failed'
      $summary.rounds[0].reflection_outcome | Should -Be 'blocked'
      $eventText | Should -Match '"event_type":"review.reflection"'
      $eventText | Should -Match '"event_type":"review.finish"'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
