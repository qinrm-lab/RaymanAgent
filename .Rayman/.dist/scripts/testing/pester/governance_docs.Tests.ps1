Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
}

Describe 'governance review docs' {
  It 'tracks the feature inventory with the six capability areas and status labels' {
    $path = Join-Path $script:RepoRoot '.Rayman\release\FEATURE_INVENTORY.md'
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8

    $raw | Should -Match '# Rayman Feature Inventory'
    $raw | Should -Match '## 1\. Entrypoints And Setup'
    $raw | Should -Match '## 2\. Watch / Alerts / Lifecycle'
    $raw | Should -Match '## 3\. Agent / Capability / Prompt Governance'
    $raw | Should -Match '## 4\. Browser / PWA / WinApp'
    $raw | Should -Match '## 5\. Release / CI / Security'
    $raw | Should -Match '## 6\. State / Transfer / Docs / Telemetry'
    $raw | Should -Match '`stable`'
    $raw | Should -Match '`drifting`'
    $raw | Should -Match '`under-tested`'
    $raw | Should -Match '`platform-opportunity`'
    $raw | Should -Match 'Agentic planner pipeline'
  }

  It 'tracks the 2026 roadmap with P0 P1 P2 priorities and official platform references' {
    $path = Join-Path $script:RepoRoot '.Rayman\release\ENHANCEMENT_ROADMAP_2026.md'
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8

    $raw | Should -Match '# Rayman Enhancement Roadmap 2026'
    $raw | Should -Match '## P0: Immediate Documentation And Contract Hardening'
    $raw | Should -Match '## P1: Optional Capability Upgrades'
    $raw | Should -Match '## P2: Platform-Dependent Expansion'
    $raw | Should -Match 'Codex SDK'
    $raw | Should -Match 'background mode'
    $raw | Should -Match 'planner_v1'
    $raw | Should -Match 'artifact attestations'
    $raw | Should -Match 'Playwright'
    $raw | Should -Match 'Appium Windows Driver'
  }

  It 'documents hosted model policy separately from repo-managed instructions' {
    $path = Join-Path $script:RepoRoot '.github\model-policy.md'
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8

    $raw | Should -Match '# Rayman Model Policy'
    $raw | Should -Match 'Auto model selection'
    $raw | Should -Match 'repository-managed'
    $raw | Should -Match 'hosted / policy-dependent'
    $raw | Should -Match 'OpenAI Docs MCP'
  }

  It 'links copilot instructions and README to the review assets and corrected watcher defaults' {
    $copilot = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github\copilot-instructions.md') -Raw -Encoding UTF8
    $readme = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\README.md') -Raw -Encoding UTF8

    $copilot | Should -Match '\.github/model-policy\.md'
    $copilot | Should -Match '\.Rayman/release/FEATURE_INVENTORY\.md'
    $copilot | Should -Match '\.Rayman/release/ENHANCEMENT_ROADMAP_2026\.md'

    $readme | Should -Match '\.Rayman/release/FEATURE_INVENTORY\.md'
    $readme | Should -Match '\.github/model-policy\.md'
    $readme | Should -Match 'RAYMAN_AUTO_START_ATTENTION_WATCH_ENABLED=0'
    $readme | Should -Match 'RAYMAN_AUTO_SAVE_WATCH_ENABLED=0'
    $readme | Should -Match 'RAYMAN_AGENT_PIPELINE'
    $readme | Should -Match 'RAYMAN_AGENT_DOC_GATE'
    $readme | Should -Match 'RAYMAN_AGENT_OPENAI_OPTIONAL'
    $readme | Should -Match '\.RaymanAgent/agentic/'
    $readme | Should -Match 'plan -> tool/subagent select -> execute -> reflect -> verify -> doc close'
  }
}
