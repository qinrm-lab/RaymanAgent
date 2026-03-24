param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$Validate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info([string]$m){ Write-Host ("ℹ️  [rayman-dist-sync] {0}" -f $m) -ForegroundColor Cyan }
function Warn([string]$m){ Write-Host ("⚠️  [rayman-dist-sync] {0}" -f $m) -ForegroundColor Yellow }
function Fail([string]$m){ Write-Host ("❌ [rayman-dist-sync] {0}" -f $m) -ForegroundColor Red; exit 6 }

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$srcRoot = Join-Path $WorkspaceRoot '.Rayman'
$distRoot = Join-Path $WorkspaceRoot '.Rayman\.dist'
if (-not (Test-Path -LiteralPath $srcRoot -PathType Container)) { Fail "source .Rayman not found: $srcRoot" }
if (-not (Test-Path -LiteralPath $distRoot -PathType Container)) { Fail "dist not found: $distRoot" }

$assertScript = Join-Path $srcRoot 'scripts\release\assert_dist_sync.ps1'
if (-not (Test-Path -LiteralPath $assertScript -PathType Leaf)) { Fail "assert_dist_sync.ps1 not found: $assertScript" }

foreach ($legacyPath in @(
  (Join-Path $distRoot 'scripts\rag'),
  (Join-Path $distRoot ('.' + 'rag'))
)) {
  if (Test-Path -LiteralPath $legacyPath) {
    Remove-Item -LiteralPath $legacyPath -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# 解析 mirrorRel 列表（简单、可读、足够稳：提取单引号字符串常量）
$raw = Get-Content -LiteralPath $assertScript -Raw -Encoding UTF8
$start = $raw.IndexOf('$mirrorRel')
if ($start -lt 0) { Fail 'mirrorRel list not found in assert_dist_sync.ps1' }

# 从 mirrorRel 起读取到文件末尾，避免列表增长后被固定长度截断
$snippet = $raw.Substring($start)
$matches = [regex]::Matches($snippet, "'([^']+)'", [System.Text.RegularExpressions.RegexOptions]::Multiline)

$rels = New-Object System.Collections.Generic.List[string]
foreach ($m in $matches) {
  $val = $m.Groups[1].Value
  if ([string]::IsNullOrWhiteSpace($val)) { continue }
  if ($val -like 'scripts/*' -or $val -like 'templates/*' -or $val -like 'skills/*' -or $val -like 'rules/*' -or $val -like 'config/*' -or $val -like 'agents/*' -or $val -like 'release/*' -or $val -in @('winapp.flow.sample.json', 'common.ps1', 'rayman', 'rayman.ps1', 'README.md', 'commands.txt', 'RELEASE_REQUIREMENTS.md', 'VERSION')) {
    [void]$rels.Add($val)
  }
}
$rels = $rels | Select-Object -Unique

if (-not $rels -or $rels.Count -eq 0) {
  Fail 'no mirror paths parsed from assert_dist_sync.ps1'
}

Info ("syncing {0} files..." -f $rels.Count)
$copied = 0
$missing = 0
foreach ($rel in $rels) {
  $relWin = $rel.Replace('/', '\\')
  $src = Join-Path $srcRoot $relWin
  $dst = Join-Path $distRoot $relWin

  if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
    Warn ("source missing (skip): .Rayman/{0}" -f $rel)
    $missing++
    continue
  }

  $parent = Split-Path -Parent $dst
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }

  Copy-Item -LiteralPath $src -Destination $dst -Force
  $copied++
}

Info ("copied={0} missing={1}" -f $copied, $missing)

if ($Validate) {
  Info 'validating dist sync...'
  if (Test-Path variable:LASTEXITCODE) { $global:LASTEXITCODE = 0 }
  & $assertScript -WorkspaceRoot $WorkspaceRoot
  $assertExitCode = 0
  if (-not $?) {
    if (Test-Path variable:LASTEXITCODE) {
      $assertExitCode = [int]$LASTEXITCODE
    } else {
      $assertExitCode = 1
    }
  } elseif (Test-Path variable:LASTEXITCODE) {
    $assertExitCode = [int]$LASTEXITCODE
  }
  if ($assertExitCode -ne 0) { Fail 'validation failed after sync' }
  Info 'validation OK'
}
