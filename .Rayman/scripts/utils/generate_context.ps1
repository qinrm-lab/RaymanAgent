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

function Get-PreferredNewLine([string]$Text) {
	if ($Text -match "`r`n") { return "`r`n" }
	if ($Text -match "`n") { return "`n" }
	return "`r`n"
}

function Convert-NewLineText {
	param(
		[string]$Text,
		[string]$NewLine
	)

	$normalized = ($Text -replace "`r`n", "`n") -replace "`r", "`n"
	if ($NewLine -eq "`n") {
		return $normalized
	}
	return ($normalized -replace "`n", $NewLine)
}

function Set-Utf8BomTextIfChanged {
	param(
		[string]$Path,
		[string]$Text,
		[string]$NewLine = "`r`n"
	)

	$rendered = Convert-NewLineText -Text $Text -NewLine $NewLine
	$existing = ''
	if (Test-Path -LiteralPath $Path -PathType Leaf) {
		$existing = [System.IO.File]::ReadAllText($Path)
	}

	if ($existing -ceq $rendered) {
		return $false
	}

	$enc = New-Object System.Text.UTF8Encoding($true)
	[System.IO.File]::WriteAllText($Path, $rendered, $enc)
	return $true
}

function Get-StableTopLevelEntries([string]$WorkspaceRoot) {
	$git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
	if ($null -ne $git -and -not [string]::IsNullOrWhiteSpace([string]$git.Source)) {
		try {
			$tracked = @(& $git.Source -C $WorkspaceRoot ls-files --cached --full-name 2>$null)
			if ($LASTEXITCODE -eq 0) {
				$entryMap = [ordered]@{}
				foreach ($line in @($tracked)) {
					$normalized = ([string]$line).Replace('\', '/').Trim()
					if ([string]::IsNullOrWhiteSpace($normalized)) {
						continue
					}

					$topLevel = ($normalized -split '/')[0]
					if ([string]::IsNullOrWhiteSpace($topLevel)) {
						continue
					}

					if (-not $entryMap.Contains($topLevel)) {
						$entryMap[$topLevel] = $true
					}
				}

				if ($entryMap.Count -gt 0) {
					return @($entryMap.Keys | Sort-Object)
				}
			}
		} catch {}
	}

	return @(Get-ChildItem -LiteralPath $WorkspaceRoot -Force -ErrorAction SilentlyContinue |
			Where-Object { $_.Name -notin @('.git', 'node_modules') } |
			Select-Object -ExpandProperty Name |
			Sort-Object)
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
$interactionMode = if (Get-Command Get-RaymanInteractionMode -ErrorAction SilentlyContinue) {
	Get-RaymanInteractionMode -WorkspaceRoot $WorkspaceRoot
} else {
	'detailed'
}
$interactionLabel = if (Get-Command Get-RaymanInteractionModeLabel -ErrorAction SilentlyContinue) {
	Get-RaymanInteractionModeLabel -Mode $interactionMode
} else {
	'详细'
}
$interactionDescription = if (Get-Command Get-RaymanInteractionModeDescription -ErrorAction SilentlyContinue) {
	Get-RaymanInteractionModeDescription -Mode $interactionMode
} else {
	'只要目标不明确、存在明显多路径或不同方案结果差异明显，就先给 plan、解释选项与结果，并写出明确验收标准。'
}
$topLevel = @(Get-StableTopLevelEntries -WorkspaceRoot $WorkspaceRoot)
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
$lines.Add("## Collaboration Preference")
$lines.Add("")
$lines.Add(('- Mode: `{0}` ({1})' -f $interactionMode, $interactionLabel))
$lines.Add(('- Summary: {0}' -f $interactionDescription))
$lines.Add('- Ambiguity floor: if the prompt is not clear enough and the ambiguity can affect goal, scope, implementation path, risk, test expectations, target workspace, or rollback, Rayman must provide concrete options plus explicit acceptance criteria before proceeding, even outside Codex Plan Mode.')
$lines.Add('- Hard gates: cross-workspace target selection, policy block, release gate, and dangerous operations still require a stop.')
$lines.Add('- Post-command hygiene: Rayman auto-cleans safe transient residue after each CLI command, auto-fixes tracked Rayman generated assets unless `RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS=1`, and only warns when non-Rayman dirty tree still remains.')
$lines.Add("")
$lines.Add("## Agent Capabilities")
$lines.Add("")
$lines.Add('- Report: `.Rayman\runtime\agent_capabilities.report.md`')
$lines.Add(('- Codex config: `{0}`' -f $(if (Test-Path -LiteralPath $codexConfigPath -PathType Leaf) { '.codex\config.toml' } else { '(missing)' })))
$lines.Add('- Summary: active capabilities, workspace trust, and readiness are environment-specific; inspect the runtime report instead of committing those values into `.Rayman\CONTEXT.md`.')
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
$recommendedBlock = @($recommendedBlock)
$recommendedEntries = @($recommendedEntries)
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

$existingContext = ''
if (Test-Path -LiteralPath $contextPath -PathType Leaf) {
	$existingContext = [System.IO.File]::ReadAllText($contextPath)
}
$newLine = Get-PreferredNewLine -Text $existingContext
$contextText = ($lines -join "`r`n")
$updated = Set-Utf8BomTextIfChanged -Path $contextPath -Text $contextText -NewLine $newLine

if ($updated) {
	Write-ContextInfo ("[context] wrote: {0}" -f (Get-RelativeDisplayPath -BasePath $WorkspaceRoot -TargetPath $contextPath))
} else {
	Write-ContextInfo ("[context] unchanged: {0}" -f (Get-RelativeDisplayPath -BasePath $WorkspaceRoot -TargetPath $contextPath))
}
Write-ContextInfo ("[context] skills: {0}" -f (Get-RelativeDisplayPath -BasePath $WorkspaceRoot -TargetPath $skillsPath))
