param(
  [string]$RootDir = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

$Begin = "<!-- RAYMAN:SKILLS:BEGIN -->"
$End   = "<!-- RAYMAN:SKILLS:END -->"

$Header = @"
$Begin
# Skills（自动注入）

- 推断结果：$SkillsSelectedText
- 详细建议：$AutoMd

要求：
- 开始工作前，先阅读并遵守上面 skills 建议。
- 如果建议与实际冲突，以可复现/可验证为准，并在输出中解释原因。

$End
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

$Text = Get-Content -Raw -Encoding UTF8 $PromptFile
$newLine = Get-RaymanPreferredNewLine -Text $Text

if ($Text.Contains($Begin) -and $Text.Contains($End)) {
  $Pattern = [regex]::Escape($Begin) + ".*?" + [regex]::Escape($End)
  $New = [regex]::Replace($Text, $Pattern, $Header, [System.Text.RegularExpressions.RegexOptions]::Singleline)
  $null = Set-RaymanUtf8BomTextIfChanged -Path $PromptFile -Text $New -NewLine $newLine
} else {
  $New = $Header + "`r`n`r`n" + $Text
  $null = Set-RaymanUtf8BomTextIfChanged -Path $PromptFile -Text $New -NewLine $newLine
}
