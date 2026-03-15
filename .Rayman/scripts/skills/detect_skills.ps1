param(
  [string]$Root = $(Get-Location).Path
)

$ErrorActionPreference = "Stop"

$RulesFile = Join-Path $Root ".Rayman\skills\rules.json"
$OutMd     = Join-Path $Root ".Rayman\context\skills.auto.md"
$OutEnv    = Join-Path $Root ".Rayman\runtime\skills.env.ps1"
$CapReport = Join-Path $Root ".Rayman\runtime\agent_capabilities.report.json"

New-Item -ItemType Directory -Force -Path (Split-Path $OutMd)  | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $OutEnv) | Out-Null

if ($env:RAYMAN_SKILLS_OFF -eq "1") {
  @(
    "# Skills（自动）— 已关闭"
    ""
    '> Artifact: local-generated'
    '> 你设置了 `RAYMAN_SKILLS_OFF=1`，因此未生成自动 skills。'
    ""
  ) | Set-Content -Path $OutMd -Encoding UTF8
  '$env:RAYMAN_SKILLS_SELECTED=""' | Set-Content -Path $OutEnv -Encoding UTF8
  Write-Host "[skills] auto disabled"
  exit 0
}

if (!(Test-Path $RulesFile)) {
  throw "[skills] rules not found: $RulesFile"
}

$rules = Get-Content $RulesFile -Raw -Encoding UTF8 | ConvertFrom-Json
$skills = $rules.skills
$defaults = @()
if ($rules.defaults) { $defaults = @($rules.defaults) }

# Collect filenames (avoid huge dirs)
$excludeDirs = @(
  (Join-Path $Root ".git"),
  (Join-Path $Root ".Rayman\runtime"),
  (Join-Path $Root "node_modules")
)

$files = Get-ChildItem -Path $Root -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object {
    $p = $_.FullName
    foreach ($d in $excludeDirs) { if ($p.StartsWith($d)) { return $false } }
    return $true
  } |
  Select-Object -First 8000 -ExpandProperty FullName

function Get-NormExt([string]$path) {
  $name = [IO.Path]::GetFileName($path).ToLowerInvariant()
  $special = @("package.json","pnpm-lock.yaml","yarn.lock","package-lock.json","requirements.txt","pyproject.toml")
  if ($special -contains $name) { return $name }
  return ([string][IO.Path]::GetExtension($path)).ToLowerInvariant()
}

$exts = @{}
foreach ($f in $files) { $exts[(Get-NormExt $f)] = $true }

# Collect corpus from logs
$corpus = ""
$logGlobs = @(
  (Join-Path $Root ".Rayman\logs\*.log"),
  (Join-Path $Root ".Rayman\init.*.log")
)

foreach ($g in $logGlobs) {
  Get-ChildItem $g -ErrorAction SilentlyContinue | ForEach-Object {
    try {
      $corpus += " " + (Get-Content $_.FullName -Tail 3000 -ErrorAction SilentlyContinue | Out-String)
    } catch {}
  }
}
$corpus = $corpus.ToLowerInvariant()
$detected = New-Object System.Collections.Generic.HashSet[string]

# ext based
foreach ($prop in $skills.PSObject.Properties) {
  $sk = $prop.Name
  $conf = $prop.Value
  $matchExtProp = $conf.PSObject.Properties['match_ext']
  if ($matchExtProp -and $matchExtProp.Value) {
    foreach ($e in @($matchExtProp.Value)) {
      if ($exts.ContainsKey($e.ToLowerInvariant())) { $null = $detected.Add($sk); break }
    }
  }
}

# keyword based
foreach ($prop in $skills.PSObject.Properties) {
  $sk = $prop.Name
  $conf = $prop.Value
  $matchKeywordsProp = $conf.PSObject.Properties['match_keywords']
  if ($matchKeywordsProp -and $matchKeywordsProp.Value) {
    foreach ($k in @($matchKeywordsProp.Value)) {
      if ($corpus.Contains($k.ToLowerInvariant())) { $null = $detected.Add($sk); break }
    }
  }
}

# defaults
foreach ($d in $defaults) { if ($skills.PSObject.Properties.Name -contains $d) { $null = $detected.Add($d) } }

# FORCE override
if ($env:RAYMAN_SKILLS_FORCE) {
  $detected.Clear()
  foreach ($s in $env:RAYMAN_SKILLS_FORCE.Split(",") ) {
    $t=$s.Trim()
    if ($t) { $null = $detected.Add($t) }
  }
}

# stable order
$ordered = New-Object System.Collections.Generic.List[string]
foreach ($prop in $skills.PSObject.Properties) {
  if ($detected.Contains($prop.Name)) { $ordered.Add($prop.Name) }
}
foreach ($s in ($detected | Sort-Object)) {
  if (-not $ordered.Contains($s)) { $ordered.Add($s) }
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# Skills（自动）")
$lines.Add("")
$lines.Add("> Artifact: local-generated")
$lines.Add("> 选择结果：" + ($(if ($ordered.Count -gt 0) { ($ordered -join ", ") } else { "(none)" } )))
$lines.Add("")
if ($env:RAYMAN_SKILLS_FORCE) {
  $lines.Add("> 已强制：RAYMAN_SKILLS_FORCE=" + $env:RAYMAN_SKILLS_FORCE)
  $lines.Add("")
}
$lines.Add("## 你应当使用的能力/工具")
$lines.Add("")
if ($ordered.Count -eq 0) {
  $lines.Add("- 未检测到明显的产物类型；按常规工程/调试流程即可。")
} else {
  foreach ($sk in $ordered) {
    $hintProp = $skills.$sk.PSObject.Properties['hint']
    $hint = if ($hintProp) { $hintProp.Value } else { $null }
    if ($hint) { $lines.Add("- **$sk**：$hint") } else { $lines.Add("- **$sk**") }
  }
}
$lines.Add("")
$lines.Add("## 覆盖/关闭")
$lines.Add("")
$lines.Add('- 关闭自动：`RAYMAN_SKILLS_OFF=1`')
$lines.Add('- 强制指定：`RAYMAN_SKILLS_FORCE=pdfs,docs,spreadsheets`')
$lines.Add("")

$capSummary = '(report unavailable)'
if (Test-Path -LiteralPath $CapReport -PathType Leaf) {
  try {
    $capObj = Get-Content -LiteralPath $CapReport -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $activeCaps = @($capObj.active_capabilities | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($activeCaps.Count -gt 0) {
      $capSummary = ($activeCaps -join ", ")
    } elseif ($null -ne $capObj.PSObject.Properties['degraded_reasons'] -and @($capObj.degraded_reasons).Count -gt 0) {
      $capSummary = ("(none; degraded: {0})" -f ((@($capObj.degraded_reasons) | ForEach-Object { [string]$_ }) -join "; "))
    } else {
      $capSummary = '(none)'
    }
  } catch {
    $capSummary = ("(parse failed: {0})" -f $_.Exception.Message)
  }
}
$lines.Add("> Agent capabilities：" + $capSummary)
$lines.Add("")

$lines | Set-Content -Path $OutMd -Encoding UTF8
('$env:RAYMAN_SKILLS_SELECTED="' + ($ordered -join ",") + '"') | Set-Content -Path $OutEnv -Encoding UTF8

Write-Host ("[skills] selected: " + ($ordered -join ","))
Write-Host ("[skills] wrote: " + $OutMd)

& (Join-Path $PSScriptRoot "inject_codex_fix_prompt.ps1")
