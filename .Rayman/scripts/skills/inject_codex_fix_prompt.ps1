param(
  [string]$RootDir = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# RootDir is .../.Rayman/scripts/skills by default
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$Rayman = Join-Path $Root ".Rayman"
$PromptFile = Join-Path $Rayman "codex_fix_prompt.txt"
$BaseFile = Join-Path $Rayman "templates\codex_fix_prompt.base.txt"
$AutoMd = ".Rayman/context/skills.auto.md"

$SkillsSelected = $env:RAYMAN_SKILLS_SELECTED
$SkillsSelectedText = if ($SkillsSelected) { $SkillsSelected } else { "（未生成）" }
$Now = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

$Begin = "<!-- RAYMAN:SKILLS:BEGIN -->"
$End   = "<!-- RAYMAN:SKILLS:END -->"

$Header = @"
$Begin
# Skills（自动注入）

- 时间：$Now
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
    "# Rayman Codex Fix Prompt (auto-created)`r`n" | Set-Content -Encoding UTF8 $PromptFile
  }
}

# backup (best effort)
try { Copy-Item -Force $PromptFile (Join-Path $Rayman "runtime\codex_fix_prompt.bak.txt") } catch {}

$Text = Get-Content -Raw -Encoding UTF8 $PromptFile

if ($Text.Contains($Begin) -and $Text.Contains($End)) {
  $Pattern = [regex]::Escape($Begin) + ".*?" + [regex]::Escape($End)
  $New = [regex]::Replace($Text, $Pattern, $Header, [System.Text.RegularExpressions.RegexOptions]::Singleline)
  Set-Content -Encoding UTF8 $PromptFile -Value $New
} else {
  $New = $Header + "`r`n`r`n" + $Text
  Set-Content -Encoding UTF8 $PromptFile -Value $New
}
