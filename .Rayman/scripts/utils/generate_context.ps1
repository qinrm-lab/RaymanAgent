param(
	[string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
	. $commonPath
}
$commandCatalogPath = Join-Path $PSScriptRoot 'command_catalog.ps1'
if (Test-Path -LiteralPath $commandCatalogPath -PathType Leaf) {
	. $commandCatalogPath
}

function Write-ContextInfo([string]$Message) {
	if (Get-Command Write-Info -ErrorAction SilentlyContinue) {
		Write-Info $Message
	} else {
		Write-Host $Message -ForegroundColor Cyan
	}
}

function Write-ContextWarn([string]$Message) {
	if (Get-Command Write-Warn -ErrorAction SilentlyContinue) {
		Write-Warn $Message
	} else {
		Write-Host $Message -ForegroundColor Yellow
	}
}

function Get-RelativeDisplayPath([string]$BasePath, [string]$TargetPath) {
	try {
		$baseUri = [Uri](([System.IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'))
		$targetUri = [Uri]([System.IO.Path]::GetFullPath($TargetPath))
		$relative = $baseUri.MakeRelativeUri($targetUri).ToString()
		return [Uri]::UnescapeDataString($relative).Replace('/', '\')
	} catch {
		return $TargetPath
	}
}

function Get-IndentedList([string[]]$Items, [string]$Prefix = '- ') {
	$lines = New-Object System.Collections.Generic.List[string]
	foreach ($item in @($Items | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
		$lines.Add($Prefix + $item)
	}
	if ($lines.Count -eq 0) {
		$lines.Add('- (none)')
	}
	return @($lines)
}

function Add-Lines([System.Collections.Generic.List[string]]$Target, [string[]]$Items) {
	foreach ($item in @($Items)) {
		$Target.Add([string]$item)
	}
}

function Get-FilePreviewLine([string]$Path) {
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
	try {
		$line = Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
		return [string]$line
	} catch {
		return ''
	}
}

function Get-PropValue([object]$Object, [string]$Name, $Default = $null) {
	if ($null -eq $Object) { return $Default }
	$prop = $Object.PSObject.Properties[$Name]
	if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
	return $prop.Value
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$contextDir = Join-Path $WorkspaceRoot '.Rayman\context'
$runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime'
$contextPath = Join-Path $WorkspaceRoot '.Rayman\CONTEXT.md'
$skillsPath = Join-Path $contextDir 'skills.auto.md'
$skillsScript = Join-Path $WorkspaceRoot '.Rayman\scripts\skills\detect_skills.ps1'
$capabilityReportPath = Join-Path $runtimeDir 'agent_capabilities.report.json'
$capabilityReportMarkdownPath = Join-Path $runtimeDir 'agent_capabilities.report.md'
$codexConfigPath = Join-Path $WorkspaceRoot '.codex\config.toml'

New-Item -ItemType Directory -Force -Path $contextDir | Out-Null
New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null

$skillsStatus = 'not-generated'
if (Test-Path -LiteralPath $skillsScript -PathType Leaf) {
	try {
		& $skillsScript -Root $WorkspaceRoot | Out-Host
		$skillsStatus = if (Test-Path -LiteralPath $skillsPath -PathType Leaf) { 'generated' } else { 'script-ran-no-file' }
	} catch {
		$skillsStatus = 'generation-failed'
		Write-ContextWarn ("[context] detect_skills failed: {0}" -f $_.Exception.Message)
	}
} else {
	Write-ContextWarn ("[context] skills detector missing: {0}" -f $skillsScript)
}

if (-not (Test-Path -LiteralPath $skillsPath -PathType Leaf)) {
	@(
		'# Skills（自动）',
		'',
		'> skills detector 未生成结果；当前按常规工程上下文处理。',
		''
	) | Set-Content -LiteralPath $skillsPath -Encoding UTF8
}

$workspaceName = Split-Path -Leaf $WorkspaceRoot
$topLevel = @(Get-ChildItem -LiteralPath $WorkspaceRoot -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('.git','node_modules') } | Select-Object -ExpandProperty Name | Sort-Object)
$scriptGroups = @()
$scriptsRoot = Join-Path $WorkspaceRoot '.Rayman\scripts'
if (Test-Path -LiteralPath $scriptsRoot -PathType Container) {
	$scriptGroups = @(Get-ChildItem -LiteralPath $scriptsRoot -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Sort-Object)
}

$instructionFiles = @()
$instructionsRoot = Join-Path $WorkspaceRoot '.github\instructions'
if (Test-Path -LiteralPath $instructionsRoot -PathType Container) {
	$instructionFiles = @(Get-ChildItem -LiteralPath $instructionsRoot -File -ErrorAction SilentlyContinue | ForEach-Object {
			$preview = Get-FilePreviewLine -Path $_.FullName
			if ([string]::IsNullOrWhiteSpace($preview)) {
				"$($_.Name) (empty)"
			} else {
				$_.Name
			}
		} | Sort-Object)
}

$configFiles = @()
$configRoot = Join-Path $WorkspaceRoot '.Rayman\config'
if (Test-Path -LiteralPath $configRoot -PathType Container) {
	$configFiles = @(Get-ChildItem -LiteralPath $configRoot -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Sort-Object)
}

$keyFiles = @(
	'AGENTS.md',
	'.github\copilot-instructions.md',
	'.RaymanAgent\.RaymanAgent.requirements.md',
	'.Rayman\config\agent_capabilities.json',
	'.Rayman\config\codex_multi_agent.json',
	'.Rayman\config\codex_agents\rayman_explorer.toml',
	'.Rayman\config\codex_agents\rayman_reviewer.toml',
	'.Rayman\config\codex_agents\rayman_docs_researcher.toml',
	'.Rayman\config\codex_agents\rayman_browser_debugger.toml',
	'.Rayman\config\codex_agents\rayman_winapp_debugger.toml',
	'.Rayman\config\codex_agents\rayman_worker.toml',
	'.Rayman\config\agent_router.json',
	'.Rayman\config\agent_policy.json',
	'.Rayman\config\model_routing.json',
	'.Rayman\scripts\agents\ensure_agent_capabilities.ps1',
	'.Rayman\scripts\agents\dispatch.ps1'
) | ForEach-Object {
	$full = Join-Path $WorkspaceRoot $_
	if (Test-Path -LiteralPath $full) { $_ }
}

if (Test-Path -LiteralPath $codexConfigPath -PathType Leaf) {
	$keyFiles += '.codex\config.toml'
}

$capabilityReport = $null
if (Test-Path -LiteralPath $capabilityReportPath -PathType Leaf) {
	try {
		$capabilityReport = Get-Content -LiteralPath $capabilityReportPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
	} catch {
		$capabilityReport = $null
		Write-ContextWarn ("[context] capability report parse failed: {0}" -f $_.Exception.Message)
	}
}

$skillsHeadline = Get-FilePreviewLine -Path $skillsPath
$recommendedEntries = @()
if (Get-Command Get-RaymanContextRecommendedEntries -ErrorAction SilentlyContinue) {
	try {
		$recommendedEntries = @(Get-RaymanContextRecommendedEntries -WorkspaceRoot $WorkspaceRoot)
	} catch {
		$recommendedEntries = @()
		Write-ContextWarn ("[context] command catalog unavailable: {0}" -f $_.Exception.Message)
	}
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# Rayman Context")
$lines.Add("")
$lines.Add("> Artifact: local-generated")
$lines.Add("> Workspace: $workspaceName")
$lines.Add("> Skills status: $skillsStatus")
$lines.Add("")
$lines.Add("## Workspace Snapshot")
$lines.Add("")
$lines.Add('- Root: `.`')
$lines.Add("- Top-level entries: " + ($(if ($topLevel.Count -gt 0) { ($topLevel -join ', ') } else { '(none)' })))
$lines.Add("")
$lines.Add("## Governance & Agent Assets")
$lines.Add("")
Add-Lines -Target $lines -Items (Get-IndentedList -Items $keyFiles)
$lines.Add("")
$lines.Add("## File Instructions")
$lines.Add("")
Add-Lines -Target $lines -Items (Get-IndentedList -Items $instructionFiles)
$lines.Add("")
$lines.Add("## Script Domains")
$lines.Add("")
Add-Lines -Target $lines -Items (Get-IndentedList -Items $scriptGroups)
$lines.Add("")
$lines.Add("## Agent Config")
$lines.Add("")
Add-Lines -Target $lines -Items (Get-IndentedList -Items $configFiles)
$lines.Add("")
$lines.Add("## Auto Skills")
$lines.Add("")
$lines.Add('- File: `.Rayman\context\skills.auto.md`')
$lines.Add("- Summary: " + ($(if ([string]::IsNullOrWhiteSpace($skillsHeadline)) { '(none)' } else { $skillsHeadline })))
$lines.Add("")
$lines.Add("## Agent Capabilities")
$lines.Add("")
if ($null -ne $capabilityReport) {
	$activeCapabilities = @($capabilityReport.active_capabilities | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
	$playwrightReport = Get-PropValue -Object $capabilityReport -Name 'playwright' -Default $null
	$winAppReport = Get-PropValue -Object $capabilityReport -Name 'winapp' -Default $null
	$lines.Add('- Report: `.Rayman\runtime\agent_capabilities.report.md`')
	$lines.Add("- Active: " + ($(if ($activeCapabilities.Count -gt 0) { ($activeCapabilities -join ', ') } else { '(none)' })))
	$lines.Add(('- Codex config: `{0}`' -f $(if (Test-Path -LiteralPath $codexConfigPath -PathType Leaf) { '.codex\config.toml' } else { '(missing)' })))
	$lines.Add(('- Workspace trust: `{0}` ({1})' -f [string]$capabilityReport.workspace_trust_status, [string]$capabilityReport.workspace_trust_reason))
	$lines.Add(('- Managed capability block: `{0}`' -f [string]([bool]$capabilityReport.managed_block_present).ToString().ToLowerInvariant()))
	$lines.Add(('- Multi-agent supported/effective: `{0}` / `{1}`' -f [string]([bool](Get-PropValue -Object $capabilityReport -Name 'multi_agent_supported' -Default $false)).ToString().ToLowerInvariant(), [string]([bool](Get-PropValue -Object $capabilityReport -Name 'multi_agent_effective' -Default $false)).ToString().ToLowerInvariant()))
	$lines.Add(('- Multi-agent degraded reason: `{0}`' -f [string](Get-PropValue -Object $capabilityReport -Name 'multi_agent_degraded_reason' -Default '')))
	$lines.Add(('- Multi-agent roles: {0}' -f $(if (@(Get-PropValue -Object $capabilityReport -Name 'multi_agent_roles' -Default @()).Count -gt 0) { ((@(Get-PropValue -Object $capabilityReport -Name 'multi_agent_roles' -Default @()) | ForEach-Object { [string]$_ }) -join ', ') } else { '(none)' })))
	$lines.Add(('- Playwright ready: `{0}` ({1})' -f [string]([bool](Get-PropValue -Object $playwrightReport -Name 'ready' -Default $false)).ToString().ToLowerInvariant(), [string](Get-PropValue -Object $playwrightReport -Name 'reason' -Default 'unknown')))
	$lines.Add(('- WinApp ready: `{0}` ({1})' -f [string]([bool](Get-PropValue -Object $winAppReport -Name 'ready' -Default $false)).ToString().ToLowerInvariant(), [string](Get-PropValue -Object $winAppReport -Name 'reason' -Default 'unknown')))
} else {
	$lines.Add('- Report: `.Rayman\runtime\agent_capabilities.report.md` (not generated yet)')
	$lines.Add('- Summary: run `rayman agent-capabilities --sync` to materialize `.codex\config.toml`, MCP capability status, and Codex multi-agent status.')
}
$lines.Add("")
$lines.Add("## Recommended Entry Points")
$lines.Add("")
$recommendedBlock = if (Get-Command Get-RaymanContextRecommendedBlock -ErrorAction SilentlyContinue) {
	try {
		@(Get-RaymanContextRecommendedBlock -WorkspaceRoot $WorkspaceRoot)
	} catch {
		@()
	}
} else {
	@()
}
$recommendedToWrite = if ($recommendedBlock.Count -gt 0) { $recommendedBlock } elseif ($recommendedEntries.Count -gt 0) { $recommendedEntries } else {
	@(
		'<!-- RAYMAN:RECOMMENDED:BEGIN -->'
		'- `[ pwsh-only ]` `rayman.ps1 context-update`：Regenerate local context and auto-skill artifacts.'
		'- `[ pwsh-only ]` `rayman.ps1 agent-capabilities`：Sync or inspect Rayman-managed Codex capabilities.'
		'- `[ all ]` `rayman dispatch`：Route a task to codex, copilot, or local backends.'
		'- `[ pwsh-only ]` `rayman.ps1 review-loop`：Run the dispatch plus test-fix review loop.'
		'- `[ pwsh-only ]` `rayman.ps1 release-gate`：Run release readiness checks and reports.'
		'<!-- RAYMAN:RECOMMENDED:END -->'
	)
}
Add-Lines -Target $lines -Items $recommendedToWrite
$lines.Add("")

$lines | Set-Content -LiteralPath $contextPath -Encoding UTF8

Write-ContextInfo ("[context] wrote: {0}" -f (Get-RelativeDisplayPath -BasePath $WorkspaceRoot -TargetPath $contextPath))
Write-ContextInfo ("[context] skills: {0}" -f (Get-RelativeDisplayPath -BasePath $WorkspaceRoot -TargetPath $skillsPath))
