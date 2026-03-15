param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $WorkspaceRoot '.Rayman\common.ps1'
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
  . $commonPath
}

function Ensure-ParentDir([string]$Path) {
  $parent = Split-Path -Parent $Path
  if ([string]::IsNullOrWhiteSpace($parent)) { return }
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
}

function Ensure-FileIfMissing([string]$Path, [string]$Content, [switch]$AlwaysUpdate) {
  Ensure-ParentDir -Path $Path
  $needsBootstrap = $false
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    try {
      $existing = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
      $needsBootstrap = [string]::IsNullOrWhiteSpace($existing)
    } catch {
      $needsBootstrap = $true
    }
  }

  if ($AlwaysUpdate -or $needsBootstrap -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
    return $true
  }
  return $false
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path

$routerJsonPath = Join-Path $WorkspaceRoot '.Rayman\config\agent_router.json'
$policyJsonPath = Join-Path $WorkspaceRoot '.Rayman\config\agent_policy.json'
$reviewJsonPath = Join-Path $WorkspaceRoot '.Rayman\config\review_loop.json'
$modelRoutingJsonPath = Join-Path $WorkspaceRoot '.Rayman\config\model_routing.json'
$systemSlimPolicyPath = Join-Path $WorkspaceRoot '.Rayman\config\system_slim_policy.json'

$routerJson = @'
{
  "schema": "rayman.agent_router.v1",
  "default_backend": "local",
  "fallback_order": [
    "codex",
    "local"
  ],
  "cloud_enabled": false,
  "cloud_whitelist": [],
  "task_backend_preferences": {
    "bugfix": [
      "codex",
      "copilot",
      "local"
    ],
    "refactor": [
      "codex",
      "local"
    ],
    "tests": [
      "local",
      "codex"
    ],
    "review": [
      "gemini",
      "claude",
      "gpt",
      "copilot",
      "codex",
      "local"
    ],
    "release": [
      "local",
      "codex"
    ]
  },
  "backend_requirements": {
    "copilot": {
      "commands_any": [
        "gh"
      ],
      "env_any": [
        "GITHUB_TOKEN",
        "GH_TOKEN"
      ],
      "allow_cloud": true
    },
    "codex": {
      "commands_any": [
        "codex"
      ],
      "env_any": [
        "OPENAI_API_KEY"
      ],
      "allow_cloud": true
    },
    "gemini": {
      "commands_any": [
        "gemini"
      ],
      "env_any": [
        "GEMINI_API_KEY",
        "GOOGLE_API_KEY"
      ],
      "allow_cloud": true
    },
    "claude": {
      "commands_any": [
        "claude"
      ],
      "env_any": [
        "ANTHROPIC_API_KEY"
      ],
      "allow_cloud": true
    },
    "gpt": {
      "commands_any": [
        "codex"
      ],
      "env_any": [
        "OPENAI_API_KEY"
      ],
      "allow_cloud": true
    },
    "local": {
      "commands_any": [],
      "env_any": [],
      "allow_cloud": false
    }
  }
}
'@

$policyJson = @'
{
  "schema": "rayman.agent_policy.v1",
  "allow_bypass_with_reason": true,
  "audit": {
    "decision_log": ".Rayman/runtime/decision.log",
    "require_reason_env": "RAYMAN_BYPASS_REASON"
  },
  "sensitive_paths": [
    ".Rayman/release/private_key.pem",
    ".env",
    ".env.local",
    ".github/workflows"
  ],
  "hooks": {
    "pre_dispatch": {
      "enabled": true,
      "blocked_commands": [
        "git\\s+reset\\s+--hard",
        "git\\s+checkout\\s+--\\s+",
        "rm\\s+-rf\\s+/"
      ],
      "blocked_path_tokens": [
        ".Rayman/release/private_key.pem"
      ]
    },
    "post_tool": {
      "enabled": true,
      "required_logs_on_failure": [
        ".Rayman/state/last_error.log"
      ]
    },
    "pre_commit": {
      "enabled": false,
      "required_commands": [
        "rayman test-fix"
      ]
    }
  }
}
'@

$reviewJson = @'
{
  "schema": "rayman.review_loop.config.v1",
  "max_rounds": 2,
  "task_kind_default": "review",
  "dispatch_each_round": true,
  "record_first_pass_telemetry": true,
  "test_fix_command": "rayman test-fix",
  "review_notes_file": ".Rayman/context/review.notes.md",
  "diff_summary": {
    "enabled": true,
    "max_files": 40,
    "ignore_dirs": [
      ".git",
      ".Rayman/runtime",
      ".Rayman/logs",
      ".Rayman/state",
      ".Rayman/.dist",
      "node_modules",
      ".venv",
      "bin",
      "obj",
      ".Rayman_full_for_copy",
      "Rayman_full_bundle",
      ".tmp_sandbox_*",
      ".rayman.stage.*"
    ]
  }
}
'@

$modelRoutingJson = @'
{
  "schema": "rayman.model_routing.v1",
  "defaults": {
    "route": "ui_selected",
    "fallback_behavior": "next_route_then_manual",
    "route_fallback_order": [
      "gemini_latest_pro",
      "claude_latest_opus",
      "gpt_latest"
    ],
    "manual_fallback_route": "ui_selected"
  },
  "task_aliases": {
    "bugfix": "fix",
    "general": "code",
    "refactor": "code",
    "tests": "code"
  },
  "providers": {
    "ui_selected": {
      "provider": "ui_selected",
      "selector": "ui_selected"
    },
    "gemini_latest_pro": {
      "provider": "gemini",
      "selector": "latest_pro"
    },
    "claude_latest_opus": {
      "provider": "claude",
      "selector": "latest_opus"
    },
    "gpt_latest": {
      "provider": "gpt",
      "selector": "latest"
    }
  },
  "tasks": {
    "code": {
      "model": "ui_selected"
    },
    "fix": {
      "model": "ui_selected"
    },
    "review": {
      "mode": "prompt_rotation",
      "prompt_keys": [
        "review.initial",
        "review.counter",
        "review.final"
      ]
    }
  },
  "prompt_routes": {
    "review.initial": "gemini_latest_pro",
    "review.counter": "claude_latest_opus",
    "review.final": "gpt_latest"
  }
}
'@

$systemSlimPolicyJson = @'
{
  "schema": "rayman.system_slim.policy.v1",
  "enabled": true,
  "notify_on_upgrade": true,
  "minimum_versions": {
    "vscode": "1.110.0",
    "codex": "0.5.80"
  },
  "features": {
    "dispatch": {
      "enabled": true,
      "mode": "delegate",
      "delegate_target": "codex.exec"
    },
    "review_loop": {
      "enabled": false,
      "mode": "keep"
    }
  }
}
'@

[void](Ensure-FileIfMissing -Path $routerJsonPath -Content $routerJson)
[void](Ensure-FileIfMissing -Path $policyJsonPath -Content $policyJson)
[void](Ensure-FileIfMissing -Path $reviewJsonPath -Content $reviewJson)
[void](Ensure-FileIfMissing -Path $modelRoutingJsonPath -Content $modelRoutingJson)
[void](Ensure-FileIfMissing -Path $systemSlimPolicyPath -Content $systemSlimPolicyJson)

$generalInstructionsPath = Join-Path $WorkspaceRoot '.github\instructions\general.instructions.md'
$backendInstructionsPath = Join-Path $WorkspaceRoot '.github\instructions\backend.instructions.md'
$frontendInstructionsPath = Join-Path $WorkspaceRoot '.github\instructions\frontend.instructions.md'

$generalInstructions = @'
---
description: "Use when working on Rayman governance files, AGENTS.md, copilot-instructions.md, prompts, config JSON, context generation, release rules, or repository automation docs."
---

# Rayman General Instructions

- Treat Rayman as an agent platform: preserve deterministic flows, auditable decisions, and rollback guidance.
- Keep source and `.Rayman/.dist` mirrors aligned for shared runtime and agent assets whenever copied distributions depend on the same behavior.
- Prefer small, verifiable contracts over broad prose; when adding a rule, also add a report, script check, or validation note when practical.
- If you touch `.github/`, `.Rayman/config/`, `AGENTS.md`, or governance docs, call out which downstream files must stay in sync.
- Agent capabilities are declared in `.Rayman/config/agent_capabilities.json`; `.codex/config.toml` is a generated workspace artifact and must stay consistent with that registry.
- OpenAI/API/model/docs tasks should prefer OpenAI Docs MCP; browser/web/e2e tasks should prefer Playwright MCP and document the Rayman fallback path when MCP is unavailable.
- Do not silently weaken requirements-reading, full-auto, release-gate, or rollback guarantees.
'@

$backendInstructions = @'
---
applyTo: "**/*.ps1"
description: "Use when editing Rayman PowerShell automation, setup/init scripts, watchers, dispatch, repair, release, or other backend orchestration scripts."
---

# Rayman Backend Instructions

- Keep scripts idempotent and safe to re-run; prefer guards over duplicate side effects.
- Use strict mode, explicit error handling, and user-visible diagnostics for degraded behavior.
- Preserve non-interactive defaults; when manual action is required, route through `request_attention.ps1` instead of spawning intrusive UI.
- When changing watcher, dispatch, setup, repair, or runtime behavior, update both source and `.Rayman/.dist` copies in the same change.
- After non-trivial backend changes, validate the affected command path and summarize what was exercised.
'@

$frontendInstructions = @'
---
applyTo: "**/*.{ts,tsx,js,jsx,css,scss,html}"
description: "Use when editing frontend, prompt UI, browser-facing assets, Playwright-visible flows, or web application code in Rayman-managed workspaces."
---

# Rayman Frontend Instructions

- Optimize for accessibility, keyboard safety, and low-friction automation.
- Favor deterministic selectors and stable UI copy for Playwright and agent-driven flows.
- Keep confirmation flows explicit; avoid surprise popups, window spawning, or modal spam.
- When UI text changes affect automation, update related Playwright or manual verification notes.
- Minimize one-off style drift; prefer shared primitives and consistent component states.
'@

[void](Ensure-FileIfMissing -Path $generalInstructionsPath -Content $generalInstructions)
[void](Ensure-FileIfMissing -Path $backendInstructionsPath -Content $backendInstructions)
[void](Ensure-FileIfMissing -Path $frontendInstructionsPath -Content $frontendInstructions)

$promptBugfixPath = Join-Path $WorkspaceRoot '.github\prompts\bugfix.prompt.md'
$promptRefactorPath = Join-Path $WorkspaceRoot '.github\prompts\refactor.prompt.md'
$promptTestsPath = Join-Path $WorkspaceRoot '.github\prompts\tests.prompt.md'
$promptReleasePath = Join-Path $WorkspaceRoot '.github\prompts\release-triage.prompt.md'

$promptBugfix = @'
# Bugfix Task Packet

- Task: {{TASK}}
- Acceptance Criteria: {{ACCEPTANCE_CRITERIA}}
- Notes: {{NOTES}}
- Generated At: {{TIMESTAMP}}
- Workspace: {{WORKSPACE_ROOT}}

## Expected Output

1. Root cause
2. Minimal patch
3. Verification steps
4. Rollback plan
'@

$promptRefactor = @'
# Refactor Task Packet

- Task: {{TASK}}
- Acceptance Criteria: {{ACCEPTANCE_CRITERIA}}
- Notes: {{NOTES}}
- Generated At: {{TIMESTAMP}}
- Workspace: {{WORKSPACE_ROOT}}

## Constraints

1. No behavior regression
2. Keep external API stable unless explicitly requested
3. Add/adjust tests for touched logic
'@

$promptTests = @'
# Test Gap Closure Packet

- Task: {{TASK}}
- Acceptance Criteria: {{ACCEPTANCE_CRITERIA}}
- Notes: {{NOTES}}
- Generated At: {{TIMESTAMP}}
- Workspace: {{WORKSPACE_ROOT}}

## Deliverables

1. New/updated tests
2. Execution evidence
3. Remaining risk notes
'@

$promptRelease = @'
# Release Triage Packet

- Task: {{TASK}}
- Acceptance Criteria: {{ACCEPTANCE_CRITERIA}}
- Notes: {{NOTES}}
- Generated At: {{TIMESTAMP}}
- Workspace: {{WORKSPACE_ROOT}}

## Deliverables

1. Blocking issue list
2. Mitigation and owner
3. Go/No-Go recommendation with evidence
'@

[void](Ensure-FileIfMissing -Path $promptBugfixPath -Content $promptBugfix)
[void](Ensure-FileIfMissing -Path $promptRefactorPath -Content $promptRefactor)
[void](Ensure-FileIfMissing -Path $promptTestsPath -Content $promptTests)
[void](Ensure-FileIfMissing -Path $promptReleasePath -Content $promptRelease)

$workflowPath = Join-Path $WorkspaceRoot '.github\workflows\copilot-setup-steps.yml'
$workflowContent = @'
name: copilot-setup-steps

on:
  workflow_dispatch:

jobs:
  rayman-agent-bootstrap:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Print Rayman agent assets
        run: |
          ls -la .github/instructions || true
          ls -la .github/prompts || true
      - name: Validate Rayman release gate in project mode
        run: |
          pwsh -NoProfile -ExecutionPolicy Bypass -File ./.Rayman/rayman.ps1 full-gate
'@
[void](Ensure-FileIfMissing -Path $workflowPath -Content $workflowContent)

$workspaceKind = 'external'
if (Get-Command Get-RaymanWorkspaceKind -ErrorAction SilentlyContinue) {
  $workspaceKind = Get-RaymanWorkspaceKind -WorkspaceRoot $WorkspaceRoot
}

if ($workspaceKind -eq 'external') {
  $ensureAgentsScript = Join-Path $WorkspaceRoot '.Rayman\scripts\agents\ensure_agents.sh'
  if (Test-Path -LiteralPath $ensureAgentsScript -PathType Leaf) {
    try {
      Push-Location $WorkspaceRoot
      try {
        & bash ./.Rayman/scripts/agents/ensure_agents.sh
      } finally {
        Pop-Location
      }
    } catch {
      Write-Host ("⚠️ [agent-assets] ensure_agents failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
  }

  $workflowGenerator = Join-Path $WorkspaceRoot '.Rayman\scripts\project\generate_project_workflows.ps1'
  if (Test-Path -LiteralPath $workflowGenerator -PathType Leaf) {
    try {
      & $workflowGenerator -WorkspaceRoot $WorkspaceRoot
    } catch {
      Write-Host ("⚠️ [agent-assets] project workflow generation failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
  } else {
    Write-Host ("⚠️ [agent-assets] missing project workflow generator: {0}" -f $workflowGenerator) -ForegroundColor Yellow
  }
}

Write-Host ("✅ [agent-assets] ensured router/policy/review config + GitHub instructions/prompts/workflow (workspace_kind={0})" -f $workspaceKind) -ForegroundColor Green
