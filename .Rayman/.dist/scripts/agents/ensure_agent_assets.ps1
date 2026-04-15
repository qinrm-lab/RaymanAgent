param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $WorkspaceRoot '.Rayman\common.ps1'
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
  . $commonPath
}

$assetManifestPath = Join-Path $WorkspaceRoot '.Rayman\scripts\agents\agent_asset_manifest.ps1'
if (-not (Test-Path -LiteralPath $assetManifestPath -PathType Leaf)) {
  throw "agent_asset_manifest.ps1 not found: $assetManifestPath"
}
. $assetManifestPath

function Ensure-ParentDir([string]$Path) {
  $parent = Split-Path -Parent $Path
  if ([string]::IsNullOrWhiteSpace($parent)) { return }
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
}

function Get-AgentAssetDisplayPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
  if (Get-Command Get-DisplayRelativePath -ErrorAction SilentlyContinue) {
    try {
      return (Get-DisplayRelativePath -BasePath $WorkspaceRoot -FullPath $Path)
    } catch {}
  }
  return $Path
}

function Get-AgentAssetManagedWriteFailureMessage([object]$Result, [string]$Path) {
  $displayPath = Get-AgentAssetDisplayPath -Path $Path
  $reason = if ($null -ne $Result -and -not [string]::IsNullOrWhiteSpace([string]$Result.reason)) {
    [string]$Result.reason
  } else {
    'write_failed'
  }
  $detail = if ($null -ne $Result -and -not [string]::IsNullOrWhiteSpace([string]$Result.error_message)) {
    [string]$Result.error_message
  } else {
    $reason
  }
  return ("{0} write failed (reason={1}): {2}" -f $displayPath, $reason, $detail)
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
    if (Get-Command Set-RaymanManagedUtf8File -ErrorAction SilentlyContinue) {
      $writeResult = Set-RaymanManagedUtf8File -Path $Path -Content $Content -AuditRoot $WorkspaceRoot -Label ('agent-asset:' + (Get-AgentAssetDisplayPath -Path $Path))
      if (-not [bool]$writeResult.ok) {
        throw ("managed-write-failed: {0}" -f (Get-AgentAssetManagedWriteFailureMessage -Result $writeResult -Path $Path))
      }
      if ([string]$writeResult.mode -eq 'in_place_fallback') {
        Write-Host ("⚠️ [agent-assets] {0} 被当前会话占用，已使用定长原地写入回退。" -f (Get-AgentAssetDisplayPath -Path $Path)) -ForegroundColor Yellow
      }
      return [bool]$writeResult.changed
    }

    try {
      Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
      return $true
    } catch {
      throw ("managed-write-failed: {0}" -f $_.Exception.Message)
    }
  }
  return $false
}

function Test-ForceManagedFileUpdate {
  $raw = [Environment]::GetEnvironmentVariable('RAYMAN_AGENT_ASSETS_FORCE_UPDATE')
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return $false
  }
  return ($raw -ne '0' -and $raw -ne 'false' -and $raw -ne 'False')
}

function Ensure-ManagedFile([string]$Path, [string]$Content) {
  return (Ensure-FileIfMissing -Path $Path -Content $Content -AlwaysUpdate:(Test-ForceManagedFileUpdate))
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
if (Test-ForceManagedFileUpdate) {
  Write-Host "⚠️ [agent-assets] force update enabled: existing managed assets will be overwritten." -ForegroundColor Yellow
}

$routerJsonPath = Join-Path $WorkspaceRoot '.Rayman\config\agent_router.json'
$policyJsonPath = Join-Path $WorkspaceRoot '.Rayman\config\agent_policy.json'
$reviewJsonPath = Join-Path $WorkspaceRoot '.Rayman\config\review_loop.json'
$modelRoutingJsonPath = Join-Path $WorkspaceRoot '.Rayman\config\model_routing.json'
$agenticPipelineJsonPath = Join-Path $WorkspaceRoot '.Rayman\config\agentic_pipeline.json'
$systemSlimPolicyPath = Join-Path $WorkspaceRoot '.Rayman\config\system_slim_policy.json'
$reviewPromptManifest = @(Get-RaymanReviewPromptManifest)

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

$reviewPromptRoutes = [ordered]@{}
foreach ($prompt in $reviewPromptManifest) {
  $reviewPromptRoutes[[string]$prompt.key] = [string]$prompt.route
}

$modelRoutingJson = ([ordered]@{
    schema = 'rayman.model_routing.v1'
    defaults = [ordered]@{
      route = 'ui_selected'
      fallback_behavior = 'next_route_then_manual'
      route_fallback_order = @(
        'gemini_latest_pro'
        'claude_latest_opus'
        'gpt_latest'
      )
      manual_fallback_route = 'ui_selected'
    }
    task_aliases = [ordered]@{
      bugfix = 'fix'
      general = 'code'
      refactor = 'code'
      tests = 'code'
    }
    providers = [ordered]@{
      ui_selected = [ordered]@{
        provider = 'ui_selected'
        selector = 'ui_selected'
      }
      gemini_latest_pro = [ordered]@{
        provider = 'gemini'
        selector = 'latest_pro'
      }
      claude_latest_opus = [ordered]@{
        provider = 'claude'
        selector = 'latest_opus'
      }
      gpt_latest = [ordered]@{
        provider = 'gpt'
        selector = 'latest'
      }
    }
    tasks = [ordered]@{
      code = [ordered]@{
        model = 'ui_selected'
      }
      fix = [ordered]@{
        model = 'ui_selected'
      }
      review = [ordered]@{
        mode = 'prompt_rotation'
        prompt_keys = @($reviewPromptManifest | ForEach-Object { [string]$_.key })
      }
    }
    prompt_routes = $reviewPromptRoutes
  } | ConvertTo-Json -Depth 8)

$agenticPipelineJson = @'
{
  "schema": "rayman.agentic_pipeline.v1",
  "default_pipeline": "planner_v1",
  "legacy_pipeline_name": "legacy",
  "doc_gate_enabled": true,
  "openai_optional": "auto",
  "tool_budget": {
    "default": {
      "max_selected_tools": 3,
      "max_fallbacks": 2,
      "max_subagents": 2
    },
    "review": {
      "max_selected_tools": 4,
      "max_fallbacks": 3,
      "max_subagents": 2
    },
    "release": {
      "max_selected_tools": 4,
      "max_fallbacks": 2,
      "max_subagents": 1
    }
  },
  "required_docs": {
    "dispatch": [
      "plan.current.md",
      "plan.current.json",
      "tool-policy.md",
      "tool-policy.json",
      "evals.md"
    ],
    "review_loop": [
      "plan.current.md",
      "plan.current.json",
      "tool-policy.md",
      "tool-policy.json",
      "reflection.current.md",
      "reflection.current.json",
      "evals.md"
    ]
  },
  "openai_optional_features": {
    "background_mode": {
      "fallback": "local_review_loop",
      "support_mode": "disabled_until_supported",
      "support_reason": "delegated_codex_executor_not_implemented"
    },
    "compaction": {
      "fallback": "local_context_files",
      "support_mode": "disabled_until_supported",
      "support_reason": "delegated_codex_executor_not_implemented"
    },
    "prompt_optimizer": {
      "fallback": "manual_evals_index",
      "support_mode": "disabled_until_supported",
      "support_reason": "delegated_codex_executor_not_implemented"
    }
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
    "codex": "0.116.0"
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

[void](Ensure-ManagedFile -Path $routerJsonPath -Content $routerJson)
[void](Ensure-ManagedFile -Path $policyJsonPath -Content $policyJson)
[void](Ensure-ManagedFile -Path $reviewJsonPath -Content $reviewJson)
[void](Ensure-ManagedFile -Path $modelRoutingJsonPath -Content $modelRoutingJson)
[void](Ensure-ManagedFile -Path $agenticPipelineJsonPath -Content $agenticPipelineJson)
[void](Ensure-ManagedFile -Path $systemSlimPolicyPath -Content $systemSlimPolicyJson)

$generalInstructionsPath = Join-Path $WorkspaceRoot '.github\instructions\general.instructions.md'
$backendInstructionsPath = Join-Path $WorkspaceRoot '.github\instructions\backend.instructions.md'
$frontendInstructionsPath = Join-Path $WorkspaceRoot '.github\instructions\frontend.instructions.md'
$modelPolicyPath = Join-Path $WorkspaceRoot '.github\model-policy.md'

$generalInstructions = @'
---
description: "Use when working on Rayman governance files, AGENTS.md, copilot-instructions.md, prompts, config JSON, context generation, release rules, or repository automation docs."
---

# Rayman General Instructions

- Treat Rayman as an agent platform: preserve deterministic flows, auditable decisions, and rollback guidance.
- Keep source and `.Rayman/.dist` mirrors aligned for shared runtime and agent assets whenever copied distributions depend on the same behavior.
- Prefer small, verifiable contracts over broad prose; when adding a rule, also add a report, script check, or validation note when practical.
- If you touch `.github/`, `.Rayman/config/`, `AGENTS.md`, or governance docs, call out which downstream files must stay in sync.
- Treat `.github/model-policy.md` as the single source of truth for model/runtime boundaries, and reference `.Rayman/release/FEATURE_INVENTORY.md` plus `.Rayman/release/ENHANCEMENT_ROADMAP_2026.md` when evaluating capability coverage or roadmap changes.
- Agent capabilities are declared in `.Rayman/config/agent_capabilities.json`; `.codex/config.toml` is a generated workspace artifact and now carries Rayman-managed capability, project-doc, profile, and subagent blocks.
- Rayman-managed subagent roles are fixed to `rayman_explorer`, `rayman_reviewer`, `rayman_docs_researcher`, `rayman_browser_debugger`, `rayman_winapp_debugger`, and `rayman_worker`.
- Read the current workspace interaction mode from `.Rayman/CONTEXT.md` or `RAYMAN_INTERACTION_MODE` before deciding whether to ask clarifying questions or present a plan.
- `detailed` means plan first for most meaningful ambiguity; `general` means plan first when outcome/scope/path/risk/test expectations change materially; `simple` means only high-risk ambiguity must stop the run.
- When you stop because the prompt is not clear enough, always provide concrete options plus explicit acceptance criteria before proceeding. This Rayman rule applies even outside Codex Plan Mode.
- `full-auto` approves code changes, but it does not authorize guessing user intent when multiple meaningful implementation paths exist.
- OpenAI/API/model/docs tasks should prefer OpenAI Docs MCP; browser/web/e2e tasks should prefer Playwright MCP; WinForms / MAUI(Windows) / desktop / UIA tasks should prefer Rayman WinApp MCP. Document the Rayman fallback path when MCP is unavailable.
- `.github/agents/*.agent.md`, `.github/skills/*/SKILL.md`, and `.github/prompts/*.prompt.md` are Rayman-managed capability assets; keep them aligned with `dispatch`, `review_loop`, and the capability report.
- GitHub-only features such as Copilot Memory and GitHub.com auto-model picker may be documented or detected, but are not treated as repo-enforced runtime guarantees.
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

[void](Ensure-ManagedFile -Path $modelPolicyPath -Content @'
# Rayman Model Policy

## Auto model selection

- `repository-managed`: assets and guidance enforced by this repo (`AGENTS.md`, `.github/instructions/**`, `.github/agents/**`, `.github/skills/**`, `.github/prompts/**`, `.Rayman/config/**`).
- `hosted / policy-dependent`: platform features that may exist outside the repo contract and must be detected at runtime.

## Preferred capability paths

- OpenAI/API/docs tasks: prefer OpenAI Docs MCP.
- Browser/UI/E2E tasks: prefer Playwright MCP.
- Windows desktop/UIA tasks: prefer Rayman WinApp MCP.

## Notes

- Treat this file as the single source of truth for model/runtime boundaries.
- Auto model selection can be documented or detected, but not assumed unless the current host confirms it.
'@)
[void](Ensure-ManagedFile -Path $generalInstructionsPath -Content $generalInstructions)
[void](Ensure-ManagedFile -Path $backendInstructionsPath -Content $backendInstructions)
[void](Ensure-ManagedFile -Path $frontendInstructionsPath -Content $frontendInstructions)

$promptBugfixPath = Join-Path $WorkspaceRoot '.github\prompts\bugfix.prompt.md'
$promptRefactorPath = Join-Path $WorkspaceRoot '.github\prompts\refactor.prompt.md'
$promptTestsPath = Join-Path $WorkspaceRoot '.github\prompts\tests.prompt.md'
$promptReleasePath = Join-Path $WorkspaceRoot '.github\prompts\release-triage.prompt.md'
$promptWorkerDebugPath = Join-Path $WorkspaceRoot '.github\prompts\worker-debug.prompt.md'
$promptReviewInitialPath = Join-Path $WorkspaceRoot '.github\prompts\review.initial.prompt.md'
$promptReviewCounterPath = Join-Path $WorkspaceRoot '.github\prompts\review.counter.prompt.md'
$promptReviewFinalPath = Join-Path $WorkspaceRoot '.github\prompts\review.final.prompt.md'

$promptBugfix = @'
---
description: "Generate a Rayman bugfix packet with root cause, validation, and rollback expectations."
---

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
---
description: "Generate a Rayman refactor packet focused on bounded change and regression control."
---

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
---
description: "Generate a Rayman test-closure packet for gaps, evidence, and residual risk."
---

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
---
description: "Generate a Rayman release-triage packet with blockers, evidence, and go/no-go framing."
---

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

$promptWorkerDebug = @'
---
description: "Generate a worker debug packet for remote/loopback worker diagnosis and repair."
---

# Worker Debug Packet

- Task: {{TASK}}
- Acceptance Criteria: {{ACCEPTANCE_CRITERIA}}
- Notes: {{NOTES}}
- Generated At: {{TIMESTAMP}}
- Workspace: {{WORKSPACE_ROOT}}

## worker debug focus

1. Reproduce the failing worker path
2. Capture worker status / beacon / debug manifest evidence
3. Propose the smallest safe fix and validation sequence
'@

$promptReviewInitial = @'
---
description: "Round 1 review packet for broad risk discovery and first-pass findings."
---

# Review Initial Packet

- Task: {{TASK}}
- Acceptance Criteria: {{ACCEPTANCE_CRITERIA}}
- Notes: {{NOTES}}
- Generated At: {{TIMESTAMP}}
- Workspace: {{WORKSPACE_ROOT}}

## Review Focus

1. Identify correctness, security, and regression risks
2. Call out missing tests and evidence gaps
3. Prefer concrete findings over style commentary
'@

$promptReviewCounter = @'
---
description: "Round 2 review packet for counter-review, disagreement handling, and evidence strengthening."
---

# Review Counter Packet

- Task: {{TASK}}
- Acceptance Criteria: {{ACCEPTANCE_CRITERIA}}
- Notes: {{NOTES}}
- Generated At: {{TIMESTAMP}}
- Workspace: {{WORKSPACE_ROOT}}

## Review Focus

1. Challenge the first-pass assumptions
2. Re-check changed files for hidden regressions
3. Tighten reproduction steps and failure evidence
'@

$promptReviewFinal = @'
---
description: "Final review packet for merge readiness, residual risk, and release posture."
---

# Review Final Packet

- Task: {{TASK}}
- Acceptance Criteria: {{ACCEPTANCE_CRITERIA}}
- Notes: {{NOTES}}
- Generated At: {{TIMESTAMP}}
- Workspace: {{WORKSPACE_ROOT}}

## Review Focus

1. Summarize blocking findings first
2. State residual risk and testing gaps
3. Give a clear ship / no-ship recommendation
'@

[void](Ensure-ManagedFile -Path $promptBugfixPath -Content $promptBugfix)
[void](Ensure-ManagedFile -Path $promptRefactorPath -Content $promptRefactor)
[void](Ensure-ManagedFile -Path $promptTestsPath -Content $promptTests)
[void](Ensure-ManagedFile -Path $promptReleasePath -Content $promptRelease)
[void](Ensure-ManagedFile -Path $promptWorkerDebugPath -Content $promptWorkerDebug)
[void](Ensure-ManagedFile -Path $promptReviewInitialPath -Content $promptReviewInitial)
[void](Ensure-ManagedFile -Path $promptReviewCounterPath -Content $promptReviewCounter)
[void](Ensure-ManagedFile -Path $promptReviewFinalPath -Content $promptReviewFinal)

$agentExplorerPath = Join-Path $WorkspaceRoot '.github\agents\rayman-explorer.agent.md'
$agentReviewerPath = Join-Path $WorkspaceRoot '.github\agents\rayman-reviewer.agent.md'
$agentWorkerPath = Join-Path $WorkspaceRoot '.github\agents\rayman-worker.agent.md'
$agentDocsPath = Join-Path $WorkspaceRoot '.github\agents\rayman-docs.agent.md'
$agentBrowserPath = Join-Path $WorkspaceRoot '.github\agents\rayman-browser.agent.md'
$agentWinAppPath = Join-Path $WorkspaceRoot '.github\agents\rayman-winapp.agent.md'

$agentExplorer = @'
---
name: rayman-explorer
description: Read-only explorer for ambiguous or multi-file tasks before edits begin
---

You are Rayman's codebase explorer.

- Stay read-only.
- Map the real execution path before proposing fixes.
- Return concrete evidence with file paths, symbols, and risks.
- Do not widen scope into implementation unless the parent task explicitly reassigns you.
'@

$agentReviewer = @'
---
name: rayman-reviewer
description: Reviewer for correctness, regressions, security, and missing tests
---

You are Rayman's reviewer.

- Focus on correctness, behavioral regressions, security risks, and missing tests.
- Lead with concrete findings and impacted files.
- Keep style commentary secondary unless it hides a real defect.
- Do not patch code unless explicitly redirected from review to implementation.
'@

$agentWorker = @'
---
name: rayman-worker
description: Bounded implementation worker for explicit file ownership and follow-up fixes
---

You are Rayman's bounded worker.

- Only take scoped implementation or verification tasks.
- Respect explicit file ownership and avoid expanding scope.
- Summarize exactly what changed and what was validated.
- Preserve Rayman rollback, release, and requirements discipline.
'@

$agentDocs = @'
---
name: rayman-docs
description: OpenAI docs specialist for Codex, API, SDK, and model verification
target: vscode
model: gpt-5.4-mini
---

You are Rayman's documentation specialist.

- Prefer OpenAI Docs MCP first.
- Verify Codex, API, SDK, and model behavior from official docs instead of memory.
- When MCP is unavailable, state that and fall back to the best official Rayman-supported path.
- Keep answers concise, source-backed, and explicit about inference.
'@

$agentBrowser = @'
---
name: rayman-browser
description: Browser and E2E debugger with Playwright-first evidence collection
target: vscode
model: gpt-5.4
---

You are Rayman's browser debugger.

- Prefer Playwright MCP for reproduction, screenshots, console output, and network evidence.
- If MCP is unavailable, call out the Rayman fallback path: `rayman ensure-playwright` then `rayman.ps1 pwa-test`.
- Keep fixes bounded and avoid speculative rewrites before reproducing the failure.
'@

$agentWinApp = @'
---
name: rayman-winapp
description: Windows desktop UI debugger for WinForms, WPF, MAUI(Windows), dialogs, and UIA
target: vscode
model: gpt-5.4
---

You are Rayman's Windows desktop debugger.

- Prefer Rayman WinApp MCP for WinForms, WPF, MAUI(Windows), dialog, and UIA flows.
- If MCP is unavailable, call out the Rayman fallback path: `rayman.ps1 ensure-winapp` then `rayman.ps1 winapp-test`.
- Keep changes focused on the failing desktop interaction and capture concrete evidence before broader fixes.
'@

[void](Ensure-ManagedFile -Path $agentExplorerPath -Content $agentExplorer)
[void](Ensure-ManagedFile -Path $agentReviewerPath -Content $agentReviewer)
[void](Ensure-ManagedFile -Path $agentWorkerPath -Content $agentWorker)
[void](Ensure-ManagedFile -Path $agentDocsPath -Content $agentDocs)
[void](Ensure-ManagedFile -Path $agentBrowserPath -Content $agentBrowser)
[void](Ensure-ManagedFile -Path $agentWinAppPath -Content $agentWinApp)

$skillDocsPath = Join-Path $WorkspaceRoot '.github\skills\openai-docs-research\SKILL.md'
$skillBrowserPath = Join-Path $WorkspaceRoot '.github\skills\browser-e2e-debug\SKILL.md'
$skillWinAppPath = Join-Path $WorkspaceRoot '.github\skills\winapp-debug\SKILL.md'
$skillWorkerPath = Join-Path $WorkspaceRoot '.github\skills\worker-remote-debug\SKILL.md'
$skillReleasePath = Join-Path $WorkspaceRoot '.github\skills\rayman-release-gate\SKILL.md'

$skillDocs = @'
---
name: openai-docs-research
description: Verify Codex, API, SDK, and model behavior from official OpenAI documentation
---

Use this skill when the task depends on current OpenAI / Codex facts.

- Prefer OpenAI Docs MCP first.
- Cite official docs when possible.
- Distinguish sourced facts from inference.
- Avoid relying on stale memory for model, SDK, or configuration behavior.
'@

$skillBrowser = @'
---
name: browser-e2e-debug
description: Reproduce browser issues with Playwright-first evidence and bounded fixes
---

Use this skill for browser, UI, recording, or E2E failures.

- Reproduce before fixing.
- Capture concrete evidence: steps, selectors, console, network, screenshots.
- Prefer Playwright MCP when available.
- If MCP is unavailable, fall back to `rayman ensure-playwright` then `rayman.ps1 pwa-test`.
'@

$skillWinApp = @'
---
name: winapp-debug
description: Debug Windows desktop UI flows with Rayman WinApp-first evidence
---

Use this skill for WinForms, WPF, MAUI(Windows), dialogs, or UIA failures.

- Prefer Rayman WinApp MCP when available.
- Capture the concrete failing interaction before changing application code.
- If MCP is unavailable, fall back to `rayman.ps1 ensure-winapp` then `rayman.ps1 winapp-test`.
- Keep desktop fixes narrowly scoped.
'@

$skillWorker = @'
---
name: worker-remote-debug
description: Diagnose and repair Rayman worker loopback / remote debug flows
---

Use this skill for `rayman.ps1 worker` operations, loopback worker smoke failures, or remote .NET worker debug issues.

- Start with `rayman.ps1 worker status --json` / `discover --json` and the worker runtime logs.
- Confirm the active worker, control URL, debugger readiness, and sync mode before changing code.
- Prefer the existing worker tasks and `Rayman Worker: Launch .NET (Active Worker)` / attach flows over ad-hoc launch commands.
- Keep fixes scoped to worker discovery, sync, upgrade, debug manifest, or host lifecycle behavior.
'@

$skillRelease = @'
---
name: rayman-release-gate
description: Apply Rayman release discipline, regression guards, and rollback expectations
---

Use this skill when the task affects release readiness, governance, or repository automation.

- Respect `.Rayman/RELEASE_REQUIREMENTS.md`.
- Prioritize blockers, regression risk, and rollback clarity.
- Do not weaken requirements or release gates silently.
- Prefer concrete validation steps over broad prose.
'@

[void](Ensure-ManagedFile -Path $skillDocsPath -Content $skillDocs)
[void](Ensure-ManagedFile -Path $skillBrowserPath -Content $skillBrowser)
[void](Ensure-ManagedFile -Path $skillWinAppPath -Content $skillWinApp)
[void](Ensure-ManagedFile -Path $skillWorkerPath -Content $skillWorker)
[void](Ensure-ManagedFile -Path $skillReleasePath -Content $skillRelease)

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
          ls -la .github/agents || true
          ls -la .github/skills || true
          ls -la .github/prompts || true
      - name: Validate Rayman release gate in project mode
        run: |
          pwsh -NoProfile -ExecutionPolicy Bypass -File ./.Rayman/rayman.ps1 full-gate
'@
[void](Ensure-ManagedFile -Path $workflowPath -Content $workflowContent)

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
      throw ("project workflow generation failed: {0}" -f $_.Exception.Message)
    }
  } else {
    throw ("missing project workflow generator: {0}" -f $workflowGenerator)
  }
}

Write-Host ("✅ [agent-assets] ensured router/policy/review config + GitHub instructions/agents/skills/prompts/workflow (workspace_kind={0})" -f $workspaceKind) -ForegroundColor Green
