param(
  [string]$RootDir = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
  . $commonPath
}
$contextAuditPath = Join-Path $PSScriptRoot '..\agents\context_audit.ps1'
if (Test-Path -LiteralPath $contextAuditPath -PathType Leaf) {
  . $contextAuditPath -NoMain
}

function Get-RaymanPreferredNewLine {
  param([string]$Text)

  if ($Text -match "`r`n") { return "`r`n" }
  if ($Text -match "`n") { return "`n" }
  return "`r`n"
}

function Convert-RaymanNewLineText {
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

function Set-RaymanUtf8BomTextIfChanged {
  param(
    [string]$Path,
    [string]$Text,
    [string]$NewLine = "`r`n"
  )

  $rendered = Convert-RaymanNewLineText -Text $Text -NewLine $NewLine
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

# RootDir is .../.Rayman/scripts/skills by default
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$Rayman = Join-Path $Root ".Rayman"
$PromptFile = Join-Path $Rayman "codex_fix_prompt.txt"
$BaseFile = Join-Path $Rayman "templates\codex_fix_prompt.base.txt"
$AutoMd = ".Rayman/context/skills.auto.md"
$SkillsEnvFile = Join-Path $Rayman "runtime\skills.env.ps1"

$SkillsSelected = $env:RAYMAN_SKILLS_SELECTED
if ([string]::IsNullOrWhiteSpace([string]$SkillsSelected) -and (Test-Path -LiteralPath $SkillsEnvFile -PathType Leaf)) {
  try {
    foreach ($line in @(Get-Content -LiteralPath $SkillsEnvFile -Encoding UTF8)) {
      $match = [regex]::Match([string]$line, '^\s*\$env:RAYMAN_SKILLS_SELECTED\s*=\s*["''](?<value>.*?)["'']\s*$')
      if ($match.Success) {
        $SkillsSelected = [string]$match.Groups['value'].Value
        break
      }
    }
  } catch {}
}
$SkillsSelectedText = if ($SkillsSelected) { $SkillsSelected } else { "（未生成）" }
$interactionMode = if (Get-Command Get-RaymanInteractionMode -ErrorAction SilentlyContinue) {
  Get-RaymanInteractionMode -WorkspaceRoot $Root
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

$skillsBegin = "<!-- RAYMAN:SKILLS:BEGIN -->"
$skillsEnd   = "<!-- RAYMAN:SKILLS:END -->"
$interactionBegin = "<!-- RAYMAN:INTERACTION:BEGIN -->"
$interactionEnd = "<!-- RAYMAN:INTERACTION:END -->"

if (Get-Command Invoke-RaymanContextAudit -ErrorAction SilentlyContinue) {
  try {
    Invoke-RaymanContextAudit -WorkspaceRoot $Root -Mode 'warn' -InvocationSource 'inject_codex_fix_prompt' | Out-Null
  } catch {}
}

$skillsHeader = @"
$skillsBegin
# Skills（自动注入）

- 推断结果：$SkillsSelectedText
- 详细建议：$AutoMd

要求：
- 开始工作前，先阅读并遵守上面 skills 建议。
- 如果建议与实际冲突，以可复现/可验证为准，并在输出中解释原因。

$skillsEnd
"@

$interactionHeader = @"
$interactionBegin
# 交互偏好（自动注入）

- 当前模式：$interactionLabel（$interactionMode）
- 当前规则：$interactionDescription
- 硬门槛：只要提示不足够明确，且歧义会影响目标、范围、实现路径、风险、测试期望、目标工作区或回滚方式，就必须先给选项并写出明确验收标准；该规则不依赖 Codex Plan Mode。
- 详细：只要目标不明确、存在明显多路径或不同方案结果差异明显，就先给 plan、解释选项与结果，并写出明确验收标准。
- 一般：只在会明显改变结果、范围、实现路径、风险、测试期望或返工成本的歧义上先停下来确认；一旦停下，同样必须给出选项和验收标准；次要细节可带默认假设继续。
- 简单：只在高风险、不可逆、跨工作区、发布/架构级或明显可能走错方向时先停下来确认；一旦停下，同样必须给出选项和验收标准；其余按推荐默认继续并显式写出假设。
- 硬门禁：跨工作区 target 选择、policy block、release gate、危险操作仍然必须停下，不受模式影响。
- 注意：full-auto 代表改动已审批，不代表可以替用户决定需求或在多方案里自己拍板。

$interactionEnd
"@

New-Item -ItemType Directory -Force -Path (Join-Path $Rayman "runtime") | Out-Null

if (!(Test-Path $PromptFile)) {
  if (Test-Path $BaseFile) {
    Copy-Item -Force $BaseFile $PromptFile
  } else {
    $null = Set-RaymanUtf8BomTextIfChanged -Path $PromptFile -Text "# Rayman Codex Fix Prompt (auto-created)`r`n"
  }
}

# backup (best effort)
try { Copy-Item -Force $PromptFile (Join-Path $Rayman "runtime\codex_fix_prompt.bak.txt") } catch {}

function Set-RaymanManagedPromptBlock {
  param(
    [string]$Text,
    [string]$BeginMarker,
    [string]$EndMarker,
    [string]$BlockText
  )

  if ($Text.Contains($BeginMarker) -and $Text.Contains($EndMarker)) {
    $pattern = [regex]::Escape($BeginMarker) + ".*?" + [regex]::Escape($EndMarker)
    return [regex]::Replace($Text, $pattern, $BlockText, [System.Text.RegularExpressions.RegexOptions]::Singleline)
  }

  return ($BlockText + "`r`n`r`n" + $Text)
}

$Text = Get-Content -Raw -Encoding UTF8 $PromptFile
$newLine = Get-RaymanPreferredNewLine -Text $Text
$newText = Set-RaymanManagedPromptBlock -Text $Text -BeginMarker $interactionBegin -EndMarker $interactionEnd -BlockText $interactionHeader
$newText = Set-RaymanManagedPromptBlock -Text $newText -BeginMarker $skillsBegin -EndMarker $skillsEnd -BlockText $skillsHeader
$null = Set-RaymanUtf8BomTextIfChanged -Path $PromptFile -Text $newText -NewLine $newLine
