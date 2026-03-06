param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [string]$OutputDir = "",
  [string]$PackageName = "",
  [switch]$IncludeVectorDb,
  [switch]$IncludeStateFiles,
  [switch]$IncludeRuntimeFiles,
  [switch]$IncludeLogs,
  [switch]$KeepRuntimeHistory,
  [switch]$KeepLogHistory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info([string]$m){ Write-Host ("ℹ️  [rayman-package] {0}" -f $m) -ForegroundColor Cyan }
function Ok([string]$m){ Write-Host ("✅ [rayman-package] {0}" -f $m) -ForegroundColor Green }
function Warn([string]$m){ Write-Host ("⚠️  [rayman-package] {0}" -f $m) -ForegroundColor Yellow }
function Fail([string]$m){ Write-Host ("❌ [rayman-package] {0}" -f $m) -ForegroundColor Red; exit 2 }

function Get-DirSizeBytes([string]$Path){
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return 0 }
  $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
  if ($null -eq $sum) { return 0 }
  return [int64]$sum
}

function Get-PackageVersionToken([string]$Name){
  if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
  $m = [regex]::Match($Name, '(?i)\bv\d+\b')
  if (-not $m.Success) { return '' }
  return $m.Value.ToLowerInvariant()
}

function Clear-DirectoryContents([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return 0 }
  $items = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
  foreach ($item in $items) {
    Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
  }
  return $items.Count
}

function Invoke-RaymanAutoSnapshotIfNoGit([string]$Root, [string]$Reason) {
  $enabled = [string][System.Environment]::GetEnvironmentVariable('RAYMAN_AUTO_SNAPSHOT_ON_NO_GIT')
  if ([string]::IsNullOrWhiteSpace($enabled)) { $enabled = '1' }
  if ($enabled -eq '0') { return }

  if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return }

  Push-Location $Root
  try {
    & git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -eq 0) { return }
  } finally {
    Pop-Location
  }

  $snapshotScript = Join-Path $Root '.Rayman\scripts\backup\snapshot_workspace.ps1'
  if (-not (Test-Path -LiteralPath $snapshotScript -PathType Leaf)) { return }
  try {
    & $snapshotScript -WorkspaceRoot $Root -Reason $Reason | Out-Host
  } catch {
    Warn ("auto snapshot failed: {0}" -f $_.Exception.Message)
  }
}

function Add-ExcludePatterns {
  param([System.Collections.Generic.List[string]]$List)

  # 默认不分发的临时/缓存数据
  [void]$List.Add('state\\chroma_db')
  [void]$List.Add('state\\rag.db')
  [void]$List.Add('state\\release_gate_report.md')
  [void]$List.Add('state\\last_error.log')
  [void]$List.Add('state\\last_error_summary.md')
  [void]$List.Add('runtime')
  [void]$List.Add('logs')

  if ($IncludeVectorDb) {
    $List.Remove('state\\chroma_db') | Out-Null
    $List.Remove('state\\rag.db') | Out-Null
  }
  if ($IncludeRuntimeFiles) {
    $List.Remove('runtime') | Out-Null
  }
  if ($IncludeLogs) {
    $List.Remove('logs') | Out-Null
  }
  if ($IncludeStateFiles) {
    $List.Remove('state\\release_gate_report.md') | Out-Null
    $List.Remove('state\\last_error.log') | Out-Null
    $List.Remove('state\\last_error_summary.md') | Out-Null
  }
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
Invoke-RaymanAutoSnapshotIfNoGit -Root $WorkspaceRoot -Reason 'package_distributable.ps1:auto-non-git'
$raymanDir = Join-Path $WorkspaceRoot '.Rayman'
if (-not (Test-Path -LiteralPath $raymanDir -PathType Container)) {
  Fail ".Rayman 不存在：$raymanDir"
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
  $OutputDir = Join-Path $raymanDir 'release'
}
if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
}

$version = 'unknown'
$versionFile = Join-Path $raymanDir 'VERSION'
if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
  $version = (Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8).Trim()
}

if ([string]::IsNullOrWhiteSpace($PackageName)) {
  $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
  $PackageName = "rayman-distributable-$version-$ts.zip"
}

$packageVersion = Get-PackageVersionToken -Name $PackageName
if ([string]::IsNullOrWhiteSpace($packageVersion)) {
  Fail ("package name must include version token (e.g. v159): {0}" -f $PackageName)
}
if ($packageVersion -ne $version.ToLowerInvariant()) {
  Fail ("package version mismatch: package={0}, expected={1}" -f $packageVersion, $version)
}

$packagePath = Join-Path $OutputDir $PackageName
if (Test-Path -LiteralPath $packagePath -PathType Leaf) {
  Remove-Item -LiteralPath $packagePath -Force
}

$tmpRoot = Join-Path $env:TEMP ("rayman_package_" + [Guid]::NewGuid().ToString('n'))
$stageRoot = Join-Path $tmpRoot 'stage'
$stageRayman = Join-Path $stageRoot '.Rayman'
New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null

$sizeBefore = Get-DirSizeBytes -Path $raymanDir

try {
  Info "复制 .Rayman 到临时打包目录..."
  Copy-Item -LiteralPath $raymanDir -Destination $stageRayman -Recurse -Force

  $excludePatterns = New-Object System.Collections.Generic.List[string]
  Add-ExcludePatterns -List $excludePatterns

  $removed = New-Object System.Collections.Generic.List[string]
  foreach ($rel in $excludePatterns) {
    $target = Join-Path $stageRayman $rel
    if (Test-Path -LiteralPath $target) {
      Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
      [void]$removed.Add($rel)
    }
  }

  # 保留空目录占位，方便首次运行体验
  foreach ($d in @('state','runtime','logs')) {
    $p = Join-Path $stageRayman $d
    if (-not (Test-Path -LiteralPath $p -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $p | Out-Null
    }
  }

  # 默认净化复制/打包中的历史 runtime/logs 产物，避免跨环境噪声。
  $sanitized = New-Object System.Collections.Generic.List[string]
  if ($IncludeRuntimeFiles -and -not $KeepRuntimeHistory) {
    $runtimePath = Join-Path $stageRayman 'runtime'
    $clearedCount = Clear-DirectoryContents -Path $runtimePath
    if ($clearedCount -gt 0) {
      [void]$sanitized.Add(("runtime/* (cleared={0})" -f $clearedCount))
    }
  }
  if ($IncludeLogs -and -not $KeepLogHistory) {
    $logsPath = Join-Path $stageRayman 'logs'
    $clearedCount = Clear-DirectoryContents -Path $logsPath
    if ($clearedCount -gt 0) {
      [void]$sanitized.Add(("logs/* (cleared={0})" -f $clearedCount))
    }
  }

  # 产出打包说明
  $manifestPath = Join-Path $stageRayman 'state\package_manifest.json'
  $manifest = [pscustomobject]@{
    generatedAt = (Get-Date).ToString('o')
    version = $version
    packageVersion = $packageVersion
    packageName = $PackageName
    includeVectorDb = [bool]$IncludeVectorDb
    includeStateFiles = [bool]$IncludeStateFiles
    includeRuntimeFiles = [bool]$IncludeRuntimeFiles
    includeLogs = [bool]$IncludeLogs
    keepRuntimeHistory = [bool]$KeepRuntimeHistory
    keepLogHistory = [bool]$KeepLogHistory
    sanitized = @($sanitized)
    removed = @($removed)
  }
  $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

  $sizeAfter = Get-DirSizeBytes -Path $stageRayman
  $reducedMb = [math]::Round(($sizeBefore - $sizeAfter) / 1MB, 2)
  $beforeMb = [math]::Round($sizeBefore / 1MB, 2)
  $afterMb = [math]::Round($sizeAfter / 1MB, 2)

  Info ("体积变化：{0} MB -> {1} MB（减少 {2} MB）" -f $beforeMb, $afterMb, $reducedMb)
  Info "开始压缩..."
  Compress-Archive -Path (Join-Path $stageRoot '.Rayman') -DestinationPath $packagePath -Force

  Ok ("可分发包已生成：{0}" -f $packagePath)
  Write-Host ("📦 默认已排除向量库/运行时/日志；如需完整包可加参数 -IncludeVectorDb -IncludeRuntimeFiles -IncludeLogs") -ForegroundColor DarkCyan
  if ($IncludeRuntimeFiles -and -not $KeepRuntimeHistory) {
    Write-Host ("📦 runtime 历史产物已净化（如需保留历史，请加 -KeepRuntimeHistory）") -ForegroundColor DarkCyan
  }
  if ($IncludeLogs -and -not $KeepLogHistory) {
    Write-Host ("📦 logs 历史产物已净化（如需保留历史，请加 -KeepLogHistory）") -ForegroundColor DarkCyan
  }
}
finally {
  if (Test-Path -LiteralPath $tmpRoot -PathType Container) {
    try { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }
}
