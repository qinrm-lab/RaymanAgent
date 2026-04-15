param(
  [switch]$Force
)

$ErrorActionPreference = "Stop"
if ($env:RAYMAN_DEBUG -eq "1") { $VerbosePreference="Continue" }

$root = (Get-Location).Path
$sol = & bash ./.Rayman/scripts/requirements/detect_solution.sh
$solDir = ".${sol}"

$stampFile = ".Rayman/runtime/migration.done"
$backupDir = ".Rayman/runtime/migration/backup"
$mapFile = ".Rayman/runtime/migration/map.json"

New-Item -ItemType Directory -Force -Path (Split-Path $stampFile) | Out-Null
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

if ((Test-Path $stampFile) -and -not $Force -and ($env:RAYMAN_FORCE_MIGRATE -ne "1")) {
  return
}

$projs = @()
try { $projs = & bash ./.Rayman/scripts/requirements/detect_projects.sh } catch { $projs = @() }

function Get-Sha256([string]$path) {
  $cmd = Get-Command Get-FileHash -ErrorAction SilentlyContinue
  if ($null -ne $cmd) {
    return (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLower()
  }

  $alg = [System.Security.Cryptography.HashAlgorithm]::Create('SHA256')
  if ($null -eq $alg) {
    throw "hash algorithm not supported: SHA256"
  }

  $stream = [System.IO.File]::OpenRead($path)
  try {
    $bytes = $alg.ComputeHash($stream)
  } finally {
    try { $stream.Dispose() } catch {}
    try { $alg.Dispose() } catch {}
  }

  return ([System.BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
}

function Ensure-Section([string]$pf) {
  if (-not (Select-String -Path $pf -Pattern '^## 遗留 requirements 迁移（自动）' -Quiet)) {
    Add-Content -Path $pf -Value ""
    Add-Content -Path $pf -Value "## 遗留 requirements 迁移（自动）"
    Add-Content -Path $pf -Value ""
    Add-Content -Path $pf -Value "> 说明：以下内容由 Rayman 自动从旧目录结构迁移合并而来，用于保留历史约束与验收信息。"
    Add-Content -Path $pf -Value "> 原文件会被备份到 .Rayman/runtime/migration/backup/ 下。"
    Add-Content -Path $pf -Value ""
  }
}

function Append-Block([string]$pf, [string]$srcRel, [string]$hash, [string]$srcPath) {
  $exists = Select-String -Path $pf -Pattern ("RAYMAN:LEGACY_MIGRATION:BEGIN.*hash=`"" + $hash + "`"") -Quiet
  if ($exists) { return }
  Ensure-Section $pf
  Add-Content -Path $pf -Value ("<!-- RAYMAN:LEGACY_MIGRATION:BEGIN source=`"" + $srcRel + "`" hash=`"" + $hash + "`" -->")
  Add-Content -Path $pf -Value ""
  $txt = Get-Content -Raw -Path $srcPath
  $txt = $txt -replace "`r`n","`n"
  Add-Content -Path $pf -Value $txt
  Add-Content -Path $pf -Value ""
  Add-Content -Path $pf -Value "<!-- RAYMAN:LEGACY_MIGRATION:END -->"
  Add-Content -Path $pf -Value ""
}

function Remove-LegacyRequirementsSource([string]$srcPath) {
  if ([string]::IsNullOrWhiteSpace([string]$srcPath) -or -not (Test-Path -LiteralPath $srcPath -PathType Leaf)) {
    return
  }
  Remove-Item -LiteralPath $srcPath -Force -ErrorAction SilentlyContinue
}

$entries = @()

foreach ($p in $projs) {
  if ([string]::IsNullOrWhiteSpace($p)) { continue }
  $pf = Join-Path $solDir (".{0}/.{0}.requirements.md" -f $p)
  if (-not (Test-Path $pf)) { continue }

  $cands = New-Object System.Collections.Generic.List[string]
  $rootLegacy = (".\.{0}.requirements.md" -f $p)
  if (Test-Path $rootLegacy) { $cands.Add((Resolve-Path $rootLegacy).Path) }

  # PowerShell 5.1 compatibility: -Depth is not available on Get-ChildItem here.
  Get-ChildItem -Path . -Recurse -Force -File -Filter (".{0}.requirements.md" -f $p) | ForEach-Object {
    $full = $_.FullName
    if ($full -like ("*\" + $solDir + "\*")) { return }
    if ($full -like "*\.Rayman\*") { return }
    $cands.Add($full)
  }

  $uniq = $cands | Select-Object -Unique
  foreach ($src in $uniq) {
    if ((Resolve-Path $src).Path -eq (Resolve-Path $pf).Path) { continue }

    $rel = (Resolve-Path $src).Path.Substring($root.Length).TrimStart('\','/')
    $backupPath = Join-Path $backupDir $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $backupPath) | Out-Null
    Copy-Item -Force -Path $src -Destination $backupPath

    $h = Get-Sha256 $src
    $srcRel = ($rel -replace '\\','/')
    Append-Block $pf $srcRel $h $src
    $entries += [pscustomobject]@{ project=$p; source=$srcRel; target=($pf -replace '\\','/'); sha256=$h }
    Remove-LegacyRequirementsSource -srcPath $src
  }
}

$mapObj = [pscustomobject]@{ version="v1"; entries=$entries }
$mapJson = $mapObj | ConvertTo-Json -Depth 6
New-Item -ItemType Directory -Force -Path (Split-Path $mapFile) | Out-Null
Set-Content -Path $mapFile -Value $mapJson -Encoding UTF8

Set-Content -Path $stampFile -Value (Get-Date).ToUniversalTime().ToString("o") -Encoding ASCII

if ($env:RAYMAN_QUIET -ne "1") {
  if ($entries.Count -gt 0) {
    Write-Host ("[migrate] merged legacy requirements into new structure: {0} files" -f $entries.Count)
    Write-Host ("[migrate] backup dir: {0}" -f $backupDir)
  } else {
    Write-Host "[migrate] no legacy requirements found"
  }
}
