param(
  [string]$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "../../..")).Path,
  [switch]$AsJson,
  [switch]$SkipContextRefresh
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$raymanRoot = Join-Path $resolvedWorkspaceRoot '.Rayman'

$checks = New-Object 'System.Collections.Generic.List[object]'
$failures = New-Object 'System.Collections.Generic.List[string]'

function Add-Check {
  param(
    [string]$Name,
    [bool]$Passed,
    [string]$Detail
  )

  $checks.Add([pscustomobject]@{
      name = $Name
      passed = $Passed
      detail = $Detail
    }) | Out-Null

  if (-not $Passed) {
    $failures.Add(("{0}: {1}" -f $Name, $Detail)) | Out-Null
  }
}

function Test-NonEmptyFile {
  param(
    [string]$RelativePath,
    [string[]]$RequiredTokens = @()
  )

  $fullPath = Join-Path $resolvedWorkspaceRoot $RelativePath
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    Add-Check -Name $RelativePath -Passed $false -Detail 'missing'
    return
  }

  $raw = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) {
    Add-Check -Name $RelativePath -Passed $false -Detail 'empty'
    return
  }

  $missingTokens = New-Object 'System.Collections.Generic.List[string]'
  foreach ($token in $RequiredTokens) {
    if ($raw -notmatch [regex]::Escape($token)) {
      $missingTokens.Add($token) | Out-Null
    }
  }

  if ($missingTokens.Count -gt 0) {
    Add-Check -Name $RelativePath -Passed $false -Detail ("missing tokens: {0}" -f (($missingTokens | ForEach-Object { $_ }) -join ', '))
    return
  }

  Add-Check -Name $RelativePath -Passed $true -Detail 'ok'
}

Test-NonEmptyFile -RelativePath 'AGENTS.md' -RequiredTokens @('skills.auto.md', 'RELEASE_REQUIREMENTS.md')
Test-NonEmptyFile -RelativePath '.github/copilot-instructions.md' -RequiredTokens @('.github/instructions/general.instructions.md', '.Rayman/CONTEXT.md', '.Rayman/context/skills.auto.md', '.codex/config.toml', 'OpenAI Docs MCP', 'Playwright MCP', 'Rayman WinApp MCP')
Test-NonEmptyFile -RelativePath '.github/instructions/general.instructions.md' -RequiredTokens @('description', 'Rayman General Instructions', '.codex/config.toml', 'Agent capabilities', 'Rayman WinApp MCP')
Test-NonEmptyFile -RelativePath '.github/instructions/backend.instructions.md' -RequiredTokens @('applyTo', '**/*.ps1')
Test-NonEmptyFile -RelativePath '.github/instructions/frontend.instructions.md' -RequiredTokens @('applyTo', '**/*.{ts,tsx,js,jsx,css,scss,html}')
Test-NonEmptyFile -RelativePath '.Rayman/scripts/utils/generate_context.ps1' -RequiredTokens @('skills.auto.md', 'CONTEXT.md', '## Agent Capabilities')
Test-NonEmptyFile -RelativePath '.Rayman/scripts/utils/request_attention.ps1' -RequiredTokens @('param', 'Message')
Test-NonEmptyFile -RelativePath '.Rayman/scripts/skills/detect_skills.ps1' -RequiredTokens @('skills.auto.md', 'Agent capabilities')
Test-NonEmptyFile -RelativePath '.Rayman/scripts/agents/dispatch.ps1' -RequiredTokens @('agent-pre-dispatch', 'RaymanCapabilityHints', 'openai_docs', 'web_auto_test', 'winapp_auto_test')
Test-NonEmptyFile -RelativePath '.Rayman/config/agent_capabilities.json' -RequiredTokens @('rayman.agent_capabilities.v1', '"openai_docs"', '"web_auto_test"', '"winapp_auto_test"')
Test-NonEmptyFile -RelativePath '.Rayman/scripts/agents/ensure_agent_capabilities.ps1' -RequiredTokens @('RAYMAN_AGENT_CAPABILITIES_ENABLED', '.codex', 'agent_capabilities.report.json', 'playwright.ready.windows.json', 'winapp.ready.windows.json', 'raymanWinApp')
Test-NonEmptyFile -RelativePath '.Rayman/config/model_routing.json'
Test-NonEmptyFile -RelativePath '.Rayman/README.md' -RequiredTokens @('rayman context-update', 'rayman agent-contract', 'rayman agent-capabilities', '.codex/config.toml')
Test-NonEmptyFile -RelativePath '.Rayman/rayman.ps1' -RequiredTokens @('"context-update"', '"agent-contract"', '"agent-capabilities"', '"ensure-winapp"', '"winapp-test"', '"winapp-inspect"')
Test-NonEmptyFile -RelativePath '.Rayman/scripts/windows/ensure_winapp.ps1' -RequiredTokens @('winapp.ready.windows.json', 'RAYMAN_WINAPP_REQUIRE')
Test-NonEmptyFile -RelativePath '.Rayman/scripts/windows/winapp_core.ps1' -RequiredTokens @('rayman.winapp.ready.v1', 'rayman.winapp.flow.result.v1', 'System.Windows.Automation')
Test-NonEmptyFile -RelativePath '.Rayman/scripts/windows/run_winapp_flow.ps1' -RequiredTokens @('rayman.winapp.flow.result.v1', 'winapp.flow.sample.json')
Test-NonEmptyFile -RelativePath '.Rayman/scripts/windows/inspect_winapp.ps1' -RequiredTokens @('control_tree.json', 'control_tree.txt')
Test-NonEmptyFile -RelativePath '.Rayman/scripts/windows/winapp_mcp_server.ps1' -RequiredTokens @('list_windows', 'get_control_tree', 'run_winapp_flow', 'capture_window')
Test-NonEmptyFile -RelativePath '.Rayman/winapp.flow.sample.json' -RequiredTokens @('rayman.winapp.flow.v1', 'launch_command')

if (-not $SkipContextRefresh) {
  $contextScript = Join-Path $raymanRoot 'scripts\utils\generate_context.ps1'
  try {
    & $contextScript -WorkspaceRoot $resolvedWorkspaceRoot | Out-Null
    Add-Check -Name 'context-refresh' -Passed $true -Detail 'generate_context.ps1 executed successfully'
  } catch {
    Add-Check -Name 'context-refresh' -Passed $false -Detail $_.Exception.Message
  }
}

Test-NonEmptyFile -RelativePath '.Rayman/CONTEXT.md' -RequiredTokens @('## Workspace Snapshot', '## Auto Skills', '## Agent Capabilities')
Test-NonEmptyFile -RelativePath '.Rayman/context/skills.auto.md' -RequiredTokens @('选择结果', '## 你应当使用的能力/工具')

$checkItems = [object[]]$checks.ToArray()
$result = [pscustomobject]@{
  workspaceRoot = $resolvedWorkspaceRoot
  passed = ($failures.Count -eq 0)
  checkCount = $checks.Count
  failureCount = $failures.Count
  checks = $checkItems
}

if ($AsJson) {
  $result | ConvertTo-Json -Depth 6
} else {
  foreach ($check in $checks) {
    $status = if ($check.passed) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1} - {2}" -f $status, $check.name, $check.detail) -ForegroundColor $(if ($check.passed) { 'Green' } else { 'Red' })
  }
  if ($failures.Count -eq 0) {
    Write-Host 'Agent contract checks passed.' -ForegroundColor Green
  } else {
    Write-Host ('Agent contract checks failed: {0}' -f ($failures -join ' | ')) -ForegroundColor Red
  }
}

if ($failures.Count -gt 0) {
  exit 1
}
