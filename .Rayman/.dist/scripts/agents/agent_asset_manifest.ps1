Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-RaymanManagedAssetContractItem {
  param(
    [string]$RelativePath,
    [string[]]$RequiredTokens = @()
  )

  return [pscustomobject]@{
    relative_path = [string]$RelativePath
    required_tokens = @($RequiredTokens | ForEach-Object { [string]$_ })
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

function Get-RaymanManagedAssetContracts {
  $contracts = New-Object System.Collections.Generic.List[object]
  $staticContracts = @(
    @{ path = 'AGENTS.md'; tokens = @('skills.auto.md', 'RELEASE_REQUIREMENTS.md') }
    @{ path = '.github/copilot-instructions.md'; tokens = @('.github/instructions/general.instructions.md', '.github/model-policy.md', '.Rayman/CONTEXT.md', '.Rayman/context/skills.auto.md', '.Rayman/release/FEATURE_INVENTORY.md', '.Rayman/release/ENHANCEMENT_ROADMAP_2026.md', '.codex/config.toml', 'OpenAI Docs MCP', 'Playwright MCP', 'Rayman WinApp MCP', '.github/agents', '.github/skills', '.github/prompts', 'gh auth setup-git') }
    @{ path = '.github/model-policy.md'; tokens = @('Rayman Model Policy', 'Auto model selection', 'repository-managed', 'hosted / policy-dependent', 'OpenAI Docs MCP') }
    @{ path = '.github/instructions/general.instructions.md'; tokens = @('description', 'Rayman General Instructions', '.codex/config.toml', '.github/model-policy.md', '.Rayman/release/FEATURE_INVENTORY.md', '.Rayman/release/ENHANCEMENT_ROADMAP_2026.md', 'Agent capabilities', 'Rayman WinApp MCP', '.github/agents', '.github/skills', '.github/prompts') }
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
    @{ path = '.Rayman/scripts/utils/generate_context.ps1'; tokens = @('skills.auto.md', 'CONTEXT.md', '## Agent Capabilities') }
    @{ path = '.Rayman/scripts/utils/request_attention.ps1'; tokens = @('param', 'Message') }
    @{ path = '.Rayman/scripts/skills/detect_skills.ps1'; tokens = @('skills.auto.md', 'Agent capabilities') }
    @{ path = '.Rayman/scripts/agents/dispatch.ps1'; tokens = @('agent-pre-dispatch', 'RaymanCapabilityHints', 'openai_docs', 'web_auto_test', 'winapp_auto_test') }
    @{ path = '.Rayman/scripts/codex/manage_accounts.ps1'; tokens = @('rayman codex', 'Invoke-ActionLogin', 'Invoke-ActionSwitch', 'Invoke-ActionRun') }
    @{ path = '.Rayman/config/agent_capabilities.json'; tokens = @('rayman.agent_capabilities.v1', '"openai_docs"', '"web_auto_test"', '"winapp_auto_test"') }
    @{ path = '.Rayman/scripts/agents/ensure_agent_capabilities.ps1'; tokens = @('RAYMAN_AGENT_CAPABILITIES_ENABLED', '.codex', 'agent_capabilities.report.json', 'playwright.ready.windows.json', 'winapp.ready.windows.json', 'raymanWinApp', 'project_doc_fallback_filenames', 'Render-RaymanManagedProfilesBlock', 'rayman_docs', 'codex_runtime_host', 'path_normalization_status', 'multi_agent_trust_assumption') }
    @{ path = '.Rayman/config/model_routing.json'; tokens = @('review.initial.prompt.md', 'review.counter.prompt.md', 'review.final.prompt.md') }
    @{ path = '.Rayman/config/codex_agents/rayman_explorer.toml'; tokens = @('name = "rayman_explorer"', 'description =', 'model = "gpt-5.4-mini"') }
    @{ path = '.Rayman/config/codex_agents/rayman_reviewer.toml'; tokens = @('name = "rayman_reviewer"', 'description =', 'model = "gpt-5.4"') }
    @{ path = '.Rayman/config/codex_agents/rayman_docs_researcher.toml'; tokens = @('name = "rayman_docs_researcher"', 'description =', 'model = "gpt-5.4-mini"', '[[skills.config]]', 'openai-docs-research') }
    @{ path = '.Rayman/config/codex_agents/rayman_browser_debugger.toml'; tokens = @('name = "rayman_browser_debugger"', 'description =', 'model = "gpt-5.4"', 'mcp_servers.playwright.enabled = true', 'browser-e2e-debug') }
    @{ path = '.Rayman/config/codex_agents/rayman_winapp_debugger.toml'; tokens = @('name = "rayman_winapp_debugger"', 'description =', 'model = "gpt-5.4"', 'mcp_servers.raymanWinApp.enabled = true', 'winapp-debug') }
    @{ path = '.Rayman/config/codex_agents/rayman_worker.toml'; tokens = @('name = "rayman_worker"', 'description =', 'model = "gpt-5.3-codex"', 'sandbox_mode = "workspace-write"') }
    @{ path = '.Rayman/README.md'; tokens = @('rayman.ps1 context-update', 'rayman.ps1 agent-contract', 'rayman agent-capabilities', 'rayman.ps1 worker', '.codex/config.toml', '.Rayman/release/FEATURE_INVENTORY.md', '.github/model-policy.md') }
    @{ path = '.Rayman/release/FEATURE_INVENTORY.md'; tokens = @('Rayman Feature Inventory', 'Entrypoints And Setup', 'Watch / Alerts / Lifecycle', 'Agent / Capability / Prompt Governance', 'Browser / PWA / WinApp', 'Release / CI / Security', 'State / Transfer / Docs / Telemetry') }
    @{ path = '.Rayman/release/ENHANCEMENT_ROADMAP_2026.md'; tokens = @('Rayman Enhancement Roadmap 2026', 'P0', 'P1', 'P2', 'Codex SDK', 'artifact attestations', 'Appium Windows Driver') }
    @{ path = '.Rayman/rayman.ps1'; tokens = @('"context-update"', '"agent-contract"', '"agent-capabilities"', '"codex"', '"worker"', '"ensure-winapp"', '"winapp-test"', '"winapp-inspect"') }
    @{ path = '.Rayman/setup.ps1'; tokens = @('Rayman WinApp MCP', '.github/agents', '.github/skills', '.github/prompts', '.vscode/launch.json', 'gh auth setup-git') }
    @{ path = '.Rayman/scripts/windows/ensure_winapp.ps1'; tokens = @('winapp.ready.windows.json', 'RAYMAN_WINAPP_REQUIRE') }
    @{ path = '.Rayman/scripts/windows/winapp_core.ps1'; tokens = @('rayman.winapp.ready.v1', 'rayman.winapp.flow.result.v1', 'System.Windows.Automation') }
    @{ path = '.Rayman/scripts/windows/run_winapp_flow.ps1'; tokens = @('rayman.winapp.flow.result.v1', 'winapp.flow.sample.json') }
    @{ path = '.Rayman/scripts/windows/inspect_winapp.ps1'; tokens = @('control_tree.json', 'control_tree.txt') }
    @{ path = '.Rayman/scripts/windows/winapp_mcp_server.ps1'; tokens = @('list_windows', 'get_control_tree', 'run_winapp_flow', 'capture_window') }
    @{ path = '.Rayman/winapp.flow.sample.json'; tokens = @('rayman.winapp.flow.v1', 'launch_command') }
  )

  foreach ($contract in $staticContracts) {
    $contracts.Add((New-RaymanManagedAssetContractItem -RelativePath ([string]$contract.path) -RequiredTokens @($contract.tokens))) | Out-Null
  }

  foreach ($reviewPrompt in @(Get-RaymanReviewPromptManifest)) {
    $contracts.Add((New-RaymanManagedAssetContractItem -RelativePath ([string]$reviewPrompt.relative_path) -RequiredTokens @($reviewPrompt.required_tokens))) | Out-Null
  }

  return @($contracts.ToArray())
}
