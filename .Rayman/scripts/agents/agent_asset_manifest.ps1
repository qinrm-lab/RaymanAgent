Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-RaymanManagedAssetContractItem {
  param(
    [string]$RelativePath,
    [string[]]$RequiredTokens = @(),
    [string[]]$ForbiddenPatterns = @()
  )

  return [pscustomobject]@{
    relative_path = [string]$RelativePath
    required_tokens = @($RequiredTokens | ForEach-Object { [string]$_ })
    forbidden_patterns = @($ForbiddenPatterns | ForEach-Object { [string]$_ })
  }
}

function New-RaymanManualCommandDocumentScopeItem {
  param(
    [string]$RelativePath,
    [ValidateSet('live', 'historical')][string]$Mode = 'live',
    [string[]]$RequiredTokens = @(),
    [switch]$StripGeneratedCommandBlock
  )

  return [pscustomobject]@{
    relative_path = [string]$RelativePath
    mode = [string]$Mode
    required_tokens = @($RequiredTokens | ForEach-Object { [string]$_ })
    strip_generated_command_block = [bool]$StripGeneratedCommandBlock
  }
}

function New-RaymanManualCommandVerificationRuleItem {
  param(
    [string]$MatchPattern,
    [ValidateSet('cli_help', 'unit_backed', 'script_exists')][string]$VerificationProfile,
    [string]$VerificationTarget = '',
    [string]$Notes = ''
  )

  return [pscustomobject]@{
    match_pattern = [string]$MatchPattern
    verification_profile = [string]$VerificationProfile
    verification_target = [string]$VerificationTarget
    notes = [string]$Notes
  }
}

function Get-RaymanReviewPromptManifest {
  return @(
    [pscustomobject]@{
      key = 'review.initial.prompt.md'
      route = 'gemini_latest_pro'
      relative_path = '.github/prompts/review.initial.prompt.md'
      required_tokens = @('description:', '{{TASK}}')
    }
    [pscustomobject]@{
      key = 'review.counter.prompt.md'
      route = 'claude_latest_opus'
      relative_path = '.github/prompts/review.counter.prompt.md'
      required_tokens = @('description:', '{{TASK}}')
    }
    [pscustomobject]@{
      key = 'review.final.prompt.md'
      route = 'gpt_latest'
      relative_path = '.github/prompts/review.final.prompt.md'
      required_tokens = @('description:', '{{TASK}}')
    }
  )
}

function Get-RaymanManualCommandDocumentScopes {
  return @(
    New-RaymanManualCommandDocumentScopeItem -RelativePath '.Rayman/README.md' -StripGeneratedCommandBlock
    New-RaymanManualCommandDocumentScopeItem -RelativePath '.github/copilot-instructions.md'
    New-RaymanManualCommandDocumentScopeItem -RelativePath '.github/agents/rayman-browser.agent.md'
    New-RaymanManualCommandDocumentScopeItem -RelativePath '.github/agents/rayman-winapp.agent.md'
    New-RaymanManualCommandDocumentScopeItem -RelativePath '.github/skills/browser-e2e-debug/SKILL.md'
    New-RaymanManualCommandDocumentScopeItem -RelativePath '.github/skills/winapp-debug/SKILL.md'
    New-RaymanManualCommandDocumentScopeItem -RelativePath '.github/skills/worker-remote-debug/SKILL.md'
    New-RaymanManualCommandDocumentScopeItem -RelativePath '.Rayman/release/FEATURE_INVENTORY.md'
    New-RaymanManualCommandDocumentScopeItem -RelativePath '.Rayman/release/delivery-pack-v159-20260307.md' -Mode historical -RequiredTokens @('Historical archive:')
    New-RaymanManualCommandDocumentScopeItem -RelativePath '.Rayman/release/public-release-notes-v159-20260307.md' -Mode historical -RequiredTokens @('Historical archive:')
    New-RaymanManualCommandDocumentScopeItem -RelativePath '.Rayman/release/release-notes-v159-20260307.md' -Mode historical -RequiredTokens @('Historical archive:')
  )
}

function Get-RaymanManualCommandVerificationRules {
  return @(
    New-RaymanManualCommandVerificationRuleItem -MatchPattern '^(?:rayman|rayman\.ps1)\s+copy-self-check\b' -VerificationProfile unit_backed -VerificationTarget '.Rayman/scripts/testing/pester/rayman_copy_self_check.Tests.ps1' -Notes 'copy-self-check command path'
    New-RaymanManualCommandVerificationRuleItem -MatchPattern '^(?:rayman|rayman\.ps1)\s+worker\b' -VerificationProfile unit_backed -VerificationTarget '.Rayman/scripts/testing/pester/manage_workers.Tests.ps1' -Notes 'worker management surface'
    New-RaymanManualCommandVerificationRuleItem -MatchPattern '^(?:rayman|rayman\.ps1)\s+workspace-install\b' -VerificationProfile unit_backed -VerificationTarget '.Rayman/scripts/testing/pester/workspace_install.Tests.ps1' -Notes 'workspace install flow'
    New-RaymanManualCommandVerificationRuleItem -MatchPattern '^(?:rayman|rayman\.ps1)\s+workspace-register\b' -VerificationProfile unit_backed -VerificationTarget '.Rayman/scripts/testing/pester/workspace_register.Tests.ps1' -Notes 'workspace register flow'
    New-RaymanManualCommandVerificationRuleItem -MatchPattern '^(?:rayman|rayman\.ps1)\s+watch-stop\b' -VerificationProfile unit_backed -VerificationTarget '.Rayman/scripts/testing/pester/watch_lifecycle.Tests.ps1' -Notes 'shared watcher stop flow'
    New-RaymanManualCommandVerificationRuleItem -MatchPattern '^(?:rayman|rayman\.ps1)\s+context-audit\b' -VerificationProfile unit_backed -VerificationTarget '.Rayman/scripts/testing/pester/context_audit.Tests.ps1' -Notes 'context audit flow'
    New-RaymanManualCommandVerificationRuleItem -MatchPattern '^(?:rayman|rayman\.ps1)\s+skills\b' -VerificationProfile unit_backed -VerificationTarget '.Rayman/scripts/testing/pester/skills_registry.Tests.ps1' -Notes 'skills registry trust surface'
    New-RaymanManualCommandVerificationRuleItem -MatchPattern '^(?:rayman|rayman\.ps1)\s+memory-search\b' -VerificationProfile unit_backed -VerificationTarget '.Rayman/scripts/testing/pester/agent_memory.Tests.ps1' -Notes 'agent memory recall surface'
    New-RaymanManualCommandVerificationRuleItem -MatchPattern '^(?:rayman|rayman\.ps1)\s+rollback\b' -VerificationProfile unit_backed -VerificationTarget '.Rayman/scripts/testing/pester/state_sessions.Tests.ps1' -Notes 'rollback facade over session checkpoints'
    New-RaymanManualCommandVerificationRuleItem -MatchPattern '^(?:rayman|rayman\.ps1)\s+prompts\b' -VerificationProfile unit_backed -VerificationTarget '.Rayman/scripts/testing/pester/prompt_eval.Tests.ps1' -Notes 'prompt template evaluation surface'
    New-RaymanManualCommandVerificationRuleItem -MatchPattern '^(?:rayman|rayman\.ps1)\s+state-(?:save|list|resume)\b' -VerificationProfile unit_backed -VerificationTarget '.Rayman/scripts/testing/pester/state_sessions.Tests.ps1' -Notes 'state session flow'
    New-RaymanManualCommandVerificationRuleItem -MatchPattern '^(?:rayman|rayman\.ps1)\s+worktree-create\b' -VerificationProfile unit_backed -VerificationTarget '.Rayman/scripts/testing/pester/state_sessions.Tests.ps1' -Notes 'worktree session flow'
    New-RaymanManualCommandVerificationRuleItem -MatchPattern '^(?:rayman|rayman\.ps1)\s+(?:help|init|watch|fast-init|migrate|doctor|check|ensure-test-deps|ensure-playwright|ensure-winapp|pwa-test|winapp-test|winapp-inspect|linux-test|dispatch|codex|interaction-mode|agent-contract|agent-capabilities|sound-check|review-loop|first-pass-report|fast-gate|browser-gate|full-gate|release-gate|release|version|newversion|package-dist|clean|snapshot|metrics|trend|baseline-guard|telemetry-export|telemetry-index|telemetry-prune|deploy|cache-clear|test-fix|dist-sync|diagnostics-residual|context-update|health-check|one-click-health|proxy-health|ensure-wsl-deps|ensure-win-deps|single-repo-upgrade|single-repo-kpi|menu|transfer-export|transfer-import)\b' -VerificationProfile cli_help -Notes 'catalog-backed command'
    New-RaymanManualCommandVerificationRuleItem -MatchPattern '^(?:\.?[/\\])?\.?Rayman[/\\]scripts[/\\][A-Za-z0-9_.\\/-]+\.ps1\b' -VerificationProfile script_exists -Notes 'internal script reference'
  )
}

function Get-RaymanManagedAssetContracts {
  $contracts = New-Object System.Collections.Generic.List[object]
  $staticContracts = @(
    @{ path = 'AGENTS.md'; tokens = @('skills.auto.md', 'RELEASE_REQUIREMENTS.md') }
    @{ path = '.github/copilot-instructions.md'; tokens = @('.github/instructions/general.instructions.md', '.github/model-policy.md', '.Rayman/CONTEXT.md', '.Rayman/context/skills.auto.md', '.Rayman/release/FEATURE_INVENTORY.md', '.Rayman/release/ENHANCEMENT_ROADMAP_2026.md', '.codex/config.toml', 'OpenAI Docs MCP', 'Playwright MCP', 'Rayman WinApp MCP', '.github/agents', '.github/skills', '.github/prompts', 'gh auth setup-git', '明确验收标准', 'Codex Plan Mode') }
    @{ path = '.github/model-policy.md'; tokens = @('Rayman Model Policy', 'Auto model selection', 'repository-managed', 'hosted / policy-dependent', 'OpenAI Docs MCP') }
    @{ path = '.github/instructions/general.instructions.md'; tokens = @('description', 'Rayman General Instructions', '.codex/config.toml', '.github/model-policy.md', '.Rayman/release/FEATURE_INVENTORY.md', '.Rayman/release/ENHANCEMENT_ROADMAP_2026.md', 'Agent capabilities', 'Rayman WinApp MCP', '.github/agents', '.github/skills', '.github/prompts', 'acceptance criteria', 'Codex Plan Mode') }
    @{ path = '.github/instructions/backend.instructions.md'; tokens = @('applyTo', '**/*.ps1') }
    @{ path = '.github/instructions/frontend.instructions.md'; tokens = @('applyTo', '**/*.{ts,tsx,js,jsx,css,scss,html}') }
    @{ path = '.github/agents/rayman-explorer.agent.md'; tokens = @('name: rayman-explorer', 'description:') }
    @{ path = '.github/agents/rayman-reviewer.agent.md'; tokens = @('name: rayman-reviewer', 'description:') }
    @{ path = '.github/agents/rayman-worker.agent.md'; tokens = @('name: rayman-worker', 'description:') }
    @{ path = '.github/agents/rayman-docs.agent.md'; tokens = @('name: rayman-docs', 'target: vscode', 'model: gpt-5.4-mini') }
    @{ path = '.github/agents/rayman-browser.agent.md'; tokens = @('name: rayman-browser', 'target: vscode', 'model: gpt-5.4') }
    @{ path = '.github/agents/rayman-winapp.agent.md'; tokens = @('name: rayman-winapp', 'target: vscode', 'model: gpt-5.4', 'ensure-winapp', 'winapp-test') }
    @{ path = '.github/skills/openai-docs-research/SKILL.md'; tokens = @('name: openai-docs-research', 'OpenAI Docs MCP') }
    @{ path = '.github/skills/browser-e2e-debug/SKILL.md'; tokens = @('name: browser-e2e-debug', 'Playwright MCP') }
    @{ path = '.github/skills/winapp-debug/SKILL.md'; tokens = @('name: winapp-debug', 'Rayman WinApp MCP') }
    @{ path = '.github/skills/worker-remote-debug/SKILL.md'; tokens = @('name: worker-remote-debug', 'rayman.ps1 worker', 'Rayman Worker: Launch .NET (Active Worker)') }
    @{ path = '.github/skills/rayman-release-gate/SKILL.md'; tokens = @('name: rayman-release-gate', '.Rayman/RELEASE_REQUIREMENTS.md') }
    @{ path = '.github/prompts/bugfix.prompt.md'; tokens = @('description:', '{{TASK}}') }
    @{ path = '.github/prompts/refactor.prompt.md'; tokens = @('description:', '{{TASK}}') }
    @{ path = '.github/prompts/tests.prompt.md'; tokens = @('description:', '{{TASK}}') }
    @{ path = '.github/prompts/release-triage.prompt.md'; tokens = @('description:', '{{TASK}}') }
    @{ path = '.github/prompts/worker-debug.prompt.md'; tokens = @('description:', '{{TASK}}', 'worker debug') }
    @{ path = '.Rayman/scripts/utils/generate_context.ps1'; tokens = @('skills.auto.md', 'CONTEXT.md', '## Agent Capabilities', 'context_audit', 'Trusted Skill Manifests') }
    @{ path = '.Rayman/scripts/utils/event_hooks.ps1'; tokens = @('Write-RaymanEvent', 'rayman.event_hooks.v1', '.Rayman/runtime/events', 'webhook') }
    @{ path = '.Rayman/scripts/utils/request_attention.ps1'; tokens = @('param', 'Message') }
    @{ path = '.Rayman/scripts/skills/detect_skills.ps1'; tokens = @('skills.auto.md', 'Agent capabilities', 'Trusted Skill Manifests', 'skills audit') }
    @{ path = '.Rayman/scripts/skills/manage_skills.ps1'; tokens = @('rayman.skills.audit.v1', 'skills.audit.last.json', 'skills.audit') }
    @{ path = '.Rayman/scripts/agents/context_audit.ps1'; tokens = @('rayman.context_audit.v1', 'context_audit.last.json', 'context.audit') }
    @{ path = '.Rayman/scripts/agents/dispatch.ps1'; tokens = @('agent-pre-dispatch', 'RaymanCapabilityHints', 'openai_docs', 'web_auto_test', 'winapp_auto_test', 'context_audit', 'dispatch.start', 'dispatch.finish') }
    @{ path = '.Rayman/scripts/agents/prompts_catalog.ps1'; tokens = @('ValidateSet(''list'', ''show'', ''apply'', ''eval'')', 'rayman.prompt_eval.v1', 'prompts.eval') }
    @{ path = '.Rayman/scripts/codex/manage_accounts.ps1'; tokens = @('rayman codex', 'Invoke-ActionLogin', 'Invoke-ActionSwitch', 'Invoke-ActionRun') }
    @{ path = '.Rayman/config/agent_capabilities.json'; tokens = @('rayman.agent_capabilities.v1', '"openai_docs"', '"web_auto_test"', '"winapp_auto_test"') }
    @{ path = '.Rayman/config/event_hooks.json'; tokens = @('rayman.event_hooks.v1', '"jsonl"', '".Rayman/runtime/events"', '"webhook"') }
    @{ path = '.Rayman/config/skills_registry.json'; tokens = @('rayman.skills_registry.v1', '"duplicate_resolution"', '"roots"', '"external_roots"') }
    @{ path = '.Rayman/config/prompt_eval_suites.json'; tokens = @('rayman.prompt_eval_suites.v1', '"suites"', '"prompts"', '"cases"') }
    @{ path = '.Rayman/scripts/agents/ensure_agent_capabilities.ps1'; tokens = @('RAYMAN_AGENT_CAPABILITIES_ENABLED', '.codex', 'agent_capabilities.report.json', 'playwright.ready.windows.json', 'winapp.ready.windows.json', 'raymanWinApp', 'project_doc_fallback_filenames', 'Render-RaymanManagedProfilesBlock', 'rayman_docs', 'codex_runtime_host', 'path_normalization_status', 'multi_agent_trust_assumption') }
    @{ path = '.Rayman/scripts/agents/validate_manual_command_contracts.ps1'; tokens = @('Get-RaymanManualCommandDocumentScopes', 'Get-RaymanManualCommandVerificationRules', 'manual_command_contracts') }
    @{ path = '.Rayman/config/model_routing.json'; tokens = @('review.initial.prompt.md', 'review.counter.prompt.md', 'review.final.prompt.md') }
    @{ path = '.Rayman/config/codex_agents/rayman_explorer.toml'; tokens = @('name = "rayman_explorer"', 'description =', 'Model intentionally omitted so this agent inherits the parent session model.', 'sandbox_mode = "read-only"'); forbidden_patterns = @('(?m)^\s*model\s*=') }
    @{ path = '.Rayman/config/codex_agents/rayman_reviewer.toml'; tokens = @('name = "rayman_reviewer"', 'description =', 'Model intentionally omitted so this agent inherits the parent session model.', 'sandbox_mode = "read-only"'); forbidden_patterns = @('(?m)^\s*model\s*=') }
    @{ path = '.Rayman/config/codex_agents/rayman_docs_researcher.toml'; tokens = @('name = "rayman_docs_researcher"', 'description =', 'Model intentionally omitted so this agent inherits the parent session model.', 'sandbox_mode = "read-only"', '[[skills.config]]', 'openai-docs-research'); forbidden_patterns = @('(?m)^\s*model\s*=') }
    @{ path = '.Rayman/config/codex_agents/rayman_browser_debugger.toml'; tokens = @('name = "rayman_browser_debugger"', 'description =', 'Model intentionally omitted so this agent inherits the parent session model.', 'sandbox_mode = "workspace-write"', 'mcp_servers.playwright.enabled = true', 'browser-e2e-debug'); forbidden_patterns = @('(?m)^\s*model\s*=') }
    @{ path = '.Rayman/config/codex_agents/rayman_winapp_debugger.toml'; tokens = @('name = "rayman_winapp_debugger"', 'description =', 'Model intentionally omitted so this agent inherits the parent session model.', 'sandbox_mode = "workspace-write"', 'mcp_servers.raymanWinApp.enabled = true', 'winapp-debug'); forbidden_patterns = @('(?m)^\s*model\s*=') }
    @{ path = '.Rayman/config/codex_agents/rayman_worker.toml'; tokens = @('name = "rayman_worker"', 'description =', 'Model intentionally omitted so this agent inherits the parent session model.', 'sandbox_mode = "workspace-write"'); forbidden_patterns = @('(?m)^\s*model\s*=') }
    @{ path = '.Rayman/README.md'; tokens = @('rayman.ps1 context-update', 'rayman.ps1 context-audit', 'rayman.ps1 skills', 'rayman.ps1 rollback', 'rayman.ps1 memory-search', 'rayman.ps1 prompts -Action eval', 'rayman.ps1 agent-contract', 'rayman.ps1 agent-capabilities', 'rayman.ps1 worker', '.codex/config.toml', '.Rayman/release/FEATURE_INVENTORY.md', '.github/model-policy.md', '明确验收标准', 'Codex Plan Mode', '.Rayman/runtime/events', '.Rayman/runtime/prompt_evals') }
    @{ path = '.Rayman/release/FEATURE_INVENTORY.md'; tokens = @('Rayman Feature Inventory', 'Entrypoints And Setup', 'Watch / Alerts / Lifecycle', 'Agent / Capability / Prompt Governance', 'Browser / PWA / WinApp', 'Release / CI / Security', 'State / Transfer / Docs / Telemetry') }
    @{ path = '.Rayman/release/ENHANCEMENT_ROADMAP_2026.md'; tokens = @('Rayman Enhancement Roadmap 2026', 'P0', 'P1', 'P2', 'Codex SDK', 'artifact attestations', 'Appium Windows Driver') }
    @{ path = '.Rayman/rayman.ps1'; tokens = @('"memory-search"', '"context-audit"', '"skills"', '"context-update"', '"rollback"', '"prompts"', '"agent-contract"', '"agent-capabilities"', '"codex"', '"worker"', '"ensure-winapp"', '"winapp-test"', '"winapp-inspect"') }
    @{ path = '.Rayman/scripts/state/rollback_state.ps1'; tokens = @('rayman.rollback.list.v1', 'rayman.rollback.diff.v1', 'rayman.rollback.restore.v1', 'rollback.restore') }
    @{ path = '.Rayman/setup.ps1'; tokens = @('Rayman WinApp MCP', '.github/agents', '.github/skills', '.github/prompts', '.vscode/launch.json', 'gh auth setup-git') }
    @{ path = '.Rayman/scripts/windows/ensure_winapp.ps1'; tokens = @('winapp.ready.windows.json', 'RAYMAN_WINAPP_REQUIRE') }
    @{ path = '.Rayman/scripts/windows/winapp_core.ps1'; tokens = @('rayman.winapp.ready.v1', 'rayman.winapp.flow.result.v1', 'System.Windows.Automation') }
    @{ path = '.Rayman/scripts/windows/run_winapp_flow.ps1'; tokens = @('rayman.winapp.flow.result.v1', 'winapp.flow.sample.json') }
    @{ path = '.Rayman/scripts/windows/inspect_winapp.ps1'; tokens = @('control_tree.json', 'control_tree.txt') }
    @{ path = '.Rayman/scripts/windows/winapp_mcp_server.ps1'; tokens = @('list_windows', 'get_control_tree', 'run_winapp_flow', 'capture_window') }
    @{ path = '.Rayman/winapp.flow.sample.json'; tokens = @('rayman.winapp.flow.v1', 'launch_command') }
  )

  foreach ($contract in $staticContracts) {
    $forbiddenPatterns = if ($contract.ContainsKey('forbidden_patterns')) { @($contract.forbidden_patterns) } else { @() }
    $contracts.Add((New-RaymanManagedAssetContractItem -RelativePath ([string]$contract.path) -RequiredTokens @($contract.tokens) -ForbiddenPatterns $forbiddenPatterns)) | Out-Null
  }

  foreach ($reviewPrompt in @(Get-RaymanReviewPromptManifest)) {
    $contracts.Add((New-RaymanManagedAssetContractItem -RelativePath ([string]$reviewPrompt.relative_path) -RequiredTokens @($reviewPrompt.required_tokens))) | Out-Null
  }

  return @($contracts.ToArray())
}
