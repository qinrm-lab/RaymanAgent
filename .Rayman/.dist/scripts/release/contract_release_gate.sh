#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="${ROOT}/.Rayman/scripts/release/release_gate.ps1"

[[ -f "${SCRIPT}" ]] || { echo "missing: ${SCRIPT}" >&2; exit 3; }

tmp_ps="$(mktemp "${ROOT}/.Rayman/runtime/contract_release_gate.XXXXXX.ps1")"
cat > "${tmp_ps}" <<'PS'
param([string]$ScriptPath)

$raw = Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
if ($raw -notmatch "\[ValidateSet\('standard','project'\)\]") {
  throw "missing mode ValidateSet(standard,project)"
}
if ($raw -notmatch "Git工作区检测") {
  throw "missing git workspace gate"
}
if ($raw -notmatch "Rayman资产Git跟踪噪声") {
  throw "missing tracked Rayman assets gate"
}
if ($raw -notmatch "非Rayman产物Git跟踪噪声") {
  throw "missing tracked noisy dirs advisory gate"
}
if ($raw -notmatch "project 模式初始化豁免，按 PASS 处理") {
  throw "missing project-mode pass waiver marker for non-git allowNoGit"
}
if ($raw -notmatch "发布包版本一致性") {
  throw "missing release artifact version gate"
}
if ($raw -notmatch "project 模式初始化豁免为 PASS") {
  throw "missing project-mode pass waiver marker for release artifacts"
}
if ($raw -notmatch 'if \(\$Mode -eq ''project''\)') {
  throw "missing project-mode branch for release artifacts"
}
if ($raw -notmatch '-Name ''发布包版本一致性'' -Status PASS -Detail \("project 模式初始化豁免：\{0\}" -f \$artifactDetail\)') {
  throw "missing PASS waiver result for project-mode release artifact mismatch"
}
if ($raw -notmatch '-Status FAIL -Detail \$artifactDetail') {
  throw "missing standard-mode FAIL branch for release artifacts"
}
if ($raw -notmatch "MCP/RAG最小可用性") {
  throw "missing MCP/RAG minimal availability gate"
}
if ($raw -notmatch "project 模式初始化豁免") {
  throw "missing project-mode pass waiver marker for MCP/RAG minimal availability"
}
if ($raw -notmatch 'Name ''MCP/RAG最小可用性'' -Status PASS -Detail \("project 模式初始化豁免：\{0\}" -f \$mcpFailDetail\)') {
  throw "missing PASS waiver result for project-mode MCP/RAG status failure"
}
if ($raw -notmatch 'Name ''MCP/RAG最小可用性'' -Status PASS -Detail \("project 模式初始化豁免：\{0\}" -f \$detail\)') {
  throw "missing PASS waiver result for project-mode RAG dependency warning"
}
if ($raw -notmatch 'Name ''MCP/RAG最小可用性'' -Status FAIL -Detail \$mcpFailDetail') {
  throw "missing FAIL result for standard-mode MCP/RAG status failure"
}
if ($raw -notmatch "单仓库增强风险快照") {
  throw "missing single-repo risk snapshot gate"
}
if ($raw -notmatch "project 模式观测项，按 PASS 处理") {
  throw "missing project-mode pass waiver marker for single-repo risk snapshot"
}

$scanBlock = [regex]::Match($raw, '\$scanIgnoreRules\s*=\s*@\((?<block>.*?)\)', [System.Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $scanBlock.Success) {
  throw "scanIgnoreRules block not found"
}

$rules = @([regex]::Matches($scanBlock.Groups['block'].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
if ($rules.Count -lt 5) {
  throw "scanIgnoreRules parsed too few rules"
}

$samples = @(
  '/mnt/e/repo/.Rayman/CONTEXT.md',
  'C:\repo\.Rayman\CONTEXT.md',
  '/mnt/e/repo/.Rayman/state/release_gate_report.md',
  '/mnt/e/repo/.Rayman/state/release_gate_report.json',
  'C:\repo\.Rayman\scripts\release\release_gate.ps1',
  '/mnt/e/repo/.Rayman/.dist/scripts/release/release_gate.ps1'
)

foreach ($sample in $samples) {
  $norm = ($sample.TrimEnd('\', '/') -replace '\\', '/').ToLowerInvariant()
  $hit = $false
  foreach ($r in $rules) {
    if ($norm -match $r) {
      $hit = $true
      break
    }
  }
  if (-not $hit) {
    throw "ignore rule mismatch for sample: $sample"
  }
}
PS

trap 'rm -f "${tmp_ps}"' EXIT
pwsh -NoProfile -File "${tmp_ps}" -ScriptPath "${SCRIPT}" >/dev/null
rm -f "${tmp_ps}"

echo "OK"
