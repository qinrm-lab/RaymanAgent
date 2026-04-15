param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [string]$OutputDir = "",
  [string]$PackageName = "",
  [switch]$IncludeVectorDb,
  [switch]$IncludeStateFiles,
  [switch]$IncludeRuntimeFiles,
  [switch]$IncludeLogs,
  [switch]$KeepRuntimeHistory,
  [switch]$KeepLogHistory,
  [switch]$NoMain
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

  $gitMarker = Join-Path $Root '.git'
  if (Test-Path -LiteralPath $gitMarker) {
    return
  }

  $snapshotScript = Join-Path $Root '.Rayman\scripts\backup\snapshot_workspace.ps1'
  if (-not (Test-Path -LiteralPath $snapshotScript -PathType Leaf)) { return }
  try {
    & $snapshotScript -WorkspaceRoot $Root -Reason $Reason | Out-Host
  } catch {
    Warn ("auto snapshot failed: {0}" -f $_.Exception.Message)
  }
}

function Get-RaymanDistributableVersion {
  param([string]$WorkspaceRoot)

  $versionPath = Join-Path $WorkspaceRoot '.Rayman\VERSION'
  if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
    return 'unknown'
  }

  try {
    return (Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8).Trim()
  } catch {
    return 'unknown'
  }
}

function Get-RaymanDistributableExcludePatterns {
  param(
    [switch]$IncludeVectorDb,
    [switch]$IncludeStateFiles,
    [switch]$IncludeRuntimeFiles,
    [switch]$IncludeLogs
  )

  $list = New-Object System.Collections.Generic.List[string]

  [void]$list.Add('state\memory')
  [void]$list.Add(('state\' + 'chroma' + '_db'))
  [void]$list.Add(('state\' + 'rag' + '.db'))
  [void]$list.Add('state\release_gate_report.md')
  [void]$list.Add('state\last_error.log')
  [void]$list.Add('state\last_error_summary.md')
  [void]$list.Add('runtime')
  [void]$list.Add('logs')
  [void]$list.Add('temp')
  [void]$list.Add('tmp')
  [void]$list.Add('cache')
  [void]$list.Add('history')

  if ($IncludeVectorDb) {
    $list.Remove('state\memory') | Out-Null
  }
  if ($IncludeRuntimeFiles) {
    $list.Remove('runtime') | Out-Null
  }
  if ($IncludeLogs) {
    $list.Remove('logs') | Out-Null
  }
  if ($IncludeStateFiles) {
    $list.Remove('state\release_gate_report.md') | Out-Null
    $list.Remove('state\last_error.log') | Out-Null
    $list.Remove('state\last_error_summary.md') | Out-Null
  }

  return @($list.ToArray())
}

function Get-RaymanDistributableRelativePath {
  param(
    [string]$RootPath,
    [string]$ChildPath
  )

  $root = [System.IO.Path]::GetFullPath([string]$RootPath).TrimEnd('\', '/')
  $child = [System.IO.Path]::GetFullPath([string]$ChildPath)
  if ($child.Length -le $root.Length) {
    return ''
  }

  $relative = $child.Substring($root.Length).TrimStart('\', '/')
  return [string]$relative
}

function Get-RaymanDistributableStableHash {
  param([AllowEmptyString()][string]$Value)

  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Value)
    $hashBytes = $sha.ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant())
  } finally {
    $sha.Dispose()
  }
}

function Get-FileHashCompat {
  param(
    [string]$Path,
    [string]$Algorithm = 'SHA256'
  )

  $cmd = Get-Command Get-FileHash -ErrorAction SilentlyContinue
  if ($null -ne $cmd) {
    return (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm -ErrorAction Stop).Hash
  }

  $alg = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
  if ($null -eq $alg) {
    throw ("hash algorithm not supported: {0}" -f $Algorithm)
  }

  $stream = [System.IO.File]::OpenRead($Path)
  try {
    $bytes = $alg.ComputeHash($stream)
  } finally {
    try { $stream.Dispose() } catch {}
    try { $alg.Dispose() } catch {}
  }

  return ([System.BitConverter]::ToString($bytes)).Replace('-', '')
}

function Get-RaymanDistributableTreeFingerprint {
  param([string]$RaymanRoot)

  if (-not (Test-Path -LiteralPath $RaymanRoot -PathType Container)) {
    throw ("distributable fingerprint root not found: {0}" -f $RaymanRoot)
  }

  $tokens = New-Object System.Collections.Generic.List[string]
  foreach ($dir in @(Get-ChildItem -LiteralPath $RaymanRoot -Recurse -Directory -Force -ErrorAction SilentlyContinue | Sort-Object FullName)) {
    $relativeDir = (Get-RaymanDistributableRelativePath -RootPath $RaymanRoot -ChildPath $dir.FullName).Replace('\', '/')
    if (-not [string]::IsNullOrWhiteSpace([string]$relativeDir)) {
      $tokens.Add(('dir|{0}' -f $relativeDir)) | Out-Null
    }
  }

  foreach ($file in @(Get-ChildItem -LiteralPath $RaymanRoot -Recurse -File -Force -ErrorAction Stop | Sort-Object FullName)) {
    $relativeFile = (Get-RaymanDistributableRelativePath -RootPath $RaymanRoot -ChildPath $file.FullName).Replace('\', '/')
    $hash = (Get-FileHashCompat -Path $file.FullName -Algorithm 'SHA256').ToLowerInvariant()
    $tokens.Add(('file|{0}|{1}|{2}' -f $relativeFile, [int64]$file.Length, $hash)) | Out-Null
  }

  return (Get-RaymanDistributableStableHash -Value (($tokens.ToArray() | Sort-Object) -join "`n"))
}

function Test-RaymanDistributableExcludedRelativePath {
  param(
    [string]$RelativePath,
    [string[]]$ExcludePatterns
  )

  $candidate = ([string]$RelativePath).Trim('\', '/').Replace('/', '\').ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
    return $false
  }

  foreach ($pattern in @($ExcludePatterns)) {
    $normalizedPattern = ([string]$pattern).Trim('\', '/').Replace('/', '\').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace([string]$normalizedPattern)) {
      continue
    }
    if ($candidate -eq $normalizedPattern -or $candidate.StartsWith($normalizedPattern + '\')) {
      return $true
    }
  }

  return $false
}

function Copy-RaymanDistributableFilteredTree {
  param(
    [string]$SourceRoot,
    [string]$DestinationRoot,
    [string[]]$ExcludePatterns = @(),
    [string]$TraversalRoot = ''
  )

  if ([string]::IsNullOrWhiteSpace([string]$TraversalRoot)) {
    $TraversalRoot = $SourceRoot
  }
  if (-not (Test-Path -LiteralPath $DestinationRoot -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null
  }
  foreach ($child in @(Get-ChildItem -LiteralPath $SourceRoot -Force -ErrorAction Stop)) {
    $relativePath = Get-RaymanDistributableRelativePath -RootPath $TraversalRoot -ChildPath $child.FullName
    if (Test-RaymanDistributableExcludedRelativePath -RelativePath $relativePath -ExcludePatterns $ExcludePatterns) {
      continue
    }

    $destinationPath = Join-Path $DestinationRoot $child.Name
    if ($child.PSIsContainer) {
      Copy-RaymanDistributableFilteredTree -SourceRoot $child.FullName -DestinationRoot $destinationPath -ExcludePatterns $ExcludePatterns -TraversalRoot $TraversalRoot
      continue
    }

    $destinationParent = Split-Path -Parent $destinationPath
    if (-not [string]::IsNullOrWhiteSpace([string]$destinationParent) -and -not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null
    }
    Copy-Item -LiteralPath $child.FullName -Destination $destinationPath -Force
  }
}

function New-RaymanDistributableStageDirectory {
  param(
    [string]$WorkspaceRoot,
    [switch]$IncludeVectorDb,
    [switch]$IncludeStateFiles,
    [switch]$IncludeRuntimeFiles,
    [switch]$IncludeLogs,
    [switch]$KeepRuntimeHistory,
    [switch]$KeepLogHistory
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  Invoke-RaymanAutoSnapshotIfNoGit -Root $resolvedRoot -Reason 'package_distributable.ps1:auto-non-git'
  $raymanDir = Join-Path $resolvedRoot '.Rayman'
  if (-not (Test-Path -LiteralPath $raymanDir -PathType Container)) {
    throw ".Rayman 不存在：$raymanDir"
  }

  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("rayman_package_" + [Guid]::NewGuid().ToString('n'))
  $stageRoot = Join-Path $tempRoot 'stage'
  $stageRayman = Join-Path $stageRoot '.Rayman'
  New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null

  $sizeBefore = Get-DirSizeBytes -Path $raymanDir
  $excludePatterns = @(Get-RaymanDistributableExcludePatterns -IncludeVectorDb:$IncludeVectorDb -IncludeStateFiles:$IncludeStateFiles -IncludeRuntimeFiles:$IncludeRuntimeFiles -IncludeLogs:$IncludeLogs)
  Copy-RaymanDistributableFilteredTree -SourceRoot $raymanDir -DestinationRoot $stageRayman -ExcludePatterns $excludePatterns

  $removed = New-Object System.Collections.Generic.List[string]
  foreach ($rel in @($excludePatterns)) {
    $sourceExcludedPath = Join-Path $raymanDir $rel
    if (Test-Path -LiteralPath $sourceExcludedPath) {
      [void]$removed.Add([string]$rel)
    }
  }

  foreach ($d in @('state','runtime','logs')) {
    $path = Join-Path $stageRayman $d
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
  }

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

  $sizeAfter = Get-DirSizeBytes -Path $stageRayman
  $fingerprint = Get-RaymanDistributableTreeFingerprint -RaymanRoot $stageRayman
  return [pscustomobject]@{
    schema = 'rayman.distributable.stage.v1'
    generated_at = (Get-Date).ToString('o')
    workspace_root = $resolvedRoot
    version = (Get-RaymanDistributableVersion -WorkspaceRoot $resolvedRoot)
    temp_root = $tempRoot
    stage_root = $stageRoot
    stage_rayman = $stageRayman
    removed = @($removed.ToArray())
    sanitized = @($sanitized.ToArray())
    fingerprint = $fingerprint
    size_before_bytes = [int64]$sizeBefore
    size_after_bytes = [int64]$sizeAfter
  }
}

function Get-RaymanDistributableFingerprint {
  param([string]$WorkspaceRoot)

  $stage = $null
  try {
    $stage = New-RaymanDistributableStageDirectory -WorkspaceRoot $WorkspaceRoot
    return [string]$stage.fingerprint
  } finally {
    if ($null -ne $stage -and $stage.PSObject.Properties['temp_root'] -and -not [string]::IsNullOrWhiteSpace([string]$stage.temp_root)) {
      Remove-Item -LiteralPath ([string]$stage.temp_root) -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

function Write-RaymanDistributableManifest {
  param(
    [string]$StageRayman,
    [string]$Version,
    [string]$PackageVersion,
    [string]$PackageName,
    [string]$Fingerprint = '',
    [string[]]$Removed = @(),
    [string[]]$Sanitized = @(),
    [switch]$IncludeVectorDb,
    [switch]$IncludeStateFiles,
    [switch]$IncludeRuntimeFiles,
    [switch]$IncludeLogs,
    [switch]$KeepRuntimeHistory,
    [switch]$KeepLogHistory
  )

  $manifestPath = Join-Path $StageRayman 'state\package_manifest.json'
  $manifest = [pscustomobject]@{
    generatedAt = (Get-Date).ToString('o')
    version = $Version
    packageVersion = $PackageVersion
    packageName = $PackageName
    distributableFingerprint = $Fingerprint
    includeVectorDb = [bool]$IncludeVectorDb
    includeStateFiles = [bool]$IncludeStateFiles
    includeRuntimeFiles = [bool]$IncludeRuntimeFiles
    includeLogs = [bool]$IncludeLogs
    keepRuntimeHistory = [bool]$KeepRuntimeHistory
    keepLogHistory = [bool]$KeepLogHistory
    sanitized = @($Sanitized)
    removed = @($Removed)
  }
  $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
}

function New-RaymanDistributablePackage {
  param(
    [string]$WorkspaceRoot,
    [string]$OutputDir = "",
    [string]$PackageName = "",
    [switch]$IncludeVectorDb,
    [switch]$IncludeStateFiles,
    [switch]$IncludeRuntimeFiles,
    [switch]$IncludeLogs,
    [switch]$KeepRuntimeHistory,
    [switch]$KeepLogHistory
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $raymanDir = Join-Path $resolvedRoot '.Rayman'
  if (-not (Test-Path -LiteralPath $raymanDir -PathType Container)) {
    throw ".Rayman 不存在：$raymanDir"
  }

  if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $raymanDir 'release'
  }
  if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
  }

  $version = Get-RaymanDistributableVersion -WorkspaceRoot $resolvedRoot
  if ([string]::IsNullOrWhiteSpace($PackageName)) {
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $PackageName = "rayman-distributable-$version-$ts.zip"
  }

  $packageVersion = Get-PackageVersionToken -Name $PackageName
  if ([string]::IsNullOrWhiteSpace($packageVersion)) {
    throw ("package name must include version token (e.g. v161): {0}" -f $PackageName)
  }
  if ($packageVersion -ne $version.ToLowerInvariant()) {
    throw ("package version mismatch: package={0}, expected={1}" -f $packageVersion, $version)
  }

  $packagePath = Join-Path $OutputDir $PackageName
  if (Test-Path -LiteralPath $packagePath -PathType Leaf) {
    Remove-Item -LiteralPath $packagePath -Force
  }

  $stage = $null
  try {
    Info "复制 .Rayman 到临时打包目录..."
    $stage = New-RaymanDistributableStageDirectory `
      -WorkspaceRoot $resolvedRoot `
      -IncludeVectorDb:$IncludeVectorDb `
      -IncludeStateFiles:$IncludeStateFiles `
      -IncludeRuntimeFiles:$IncludeRuntimeFiles `
      -IncludeLogs:$IncludeLogs `
      -KeepRuntimeHistory:$KeepRuntimeHistory `
      -KeepLogHistory:$KeepLogHistory

    Write-RaymanDistributableManifest `
      -StageRayman ([string]$stage.stage_rayman) `
      -Version $version `
      -PackageVersion $packageVersion `
      -PackageName $PackageName `
      -Fingerprint ([string]$stage.fingerprint) `
      -Removed @($stage.removed) `
      -Sanitized @($stage.sanitized) `
      -IncludeVectorDb:$IncludeVectorDb `
      -IncludeStateFiles:$IncludeStateFiles `
      -IncludeRuntimeFiles:$IncludeRuntimeFiles `
      -IncludeLogs:$IncludeLogs `
      -KeepRuntimeHistory:$KeepRuntimeHistory `
      -KeepLogHistory:$KeepLogHistory

    $beforeMb = [math]::Round(([int64]$stage.size_before_bytes) / 1MB, 2)
    $afterMb = [math]::Round(([int64]$stage.size_after_bytes) / 1MB, 2)
    $reducedMb = [math]::Round((([int64]$stage.size_before_bytes) - ([int64]$stage.size_after_bytes)) / 1MB, 2)

    Info ("体积变化：{0} MB -> {1} MB（减少 {2} MB）" -f $beforeMb, $afterMb, $reducedMb)
    Info "开始压缩..."
    Compress-Archive -Path (Join-Path ([string]$stage.stage_root) '.Rayman') -DestinationPath $packagePath -Force

    Ok ("可分发包已生成：{0}" -f $packagePath)
    Write-Host ("📦 默认已排除 Agent Memory 存储/运行时/日志；如需完整包可加参数 -IncludeVectorDb -IncludeRuntimeFiles -IncludeLogs") -ForegroundColor DarkCyan
    if ($IncludeRuntimeFiles -and -not $KeepRuntimeHistory) {
      Write-Host ("📦 runtime 历史产物已净化（如需保留历史，请加 -KeepRuntimeHistory）") -ForegroundColor DarkCyan
    }
    if ($IncludeLogs -and -not $KeepLogHistory) {
      Write-Host ("📦 logs 历史产物已净化（如需保留历史，请加 -KeepLogHistory）") -ForegroundColor DarkCyan
    }

    return [pscustomobject]@{
      schema = 'rayman.distributable.package.v1'
      generated_at = (Get-Date).ToString('o')
      workspace_root = $resolvedRoot
      version = $version
      package_name = $PackageName
      package_path = $packagePath
      package_version = $packageVersion
      stage = $stage
    }
  } finally {
    if ($null -ne $stage -and -not [string]::IsNullOrWhiteSpace([string]$stage.temp_root) -and (Test-Path -LiteralPath ([string]$stage.temp_root) -PathType Container)) {
      try { Remove-Item -LiteralPath ([string]$stage.temp_root) -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
  }
}

if (-not $NoMain) {
  try {
    New-RaymanDistributablePackage `
      -WorkspaceRoot $WorkspaceRoot `
      -OutputDir $OutputDir `
      -PackageName $PackageName `
      -IncludeVectorDb:$IncludeVectorDb `
      -IncludeStateFiles:$IncludeStateFiles `
      -IncludeRuntimeFiles:$IncludeRuntimeFiles `
      -IncludeLogs:$IncludeLogs `
      -KeepRuntimeHistory:$KeepRuntimeHistory `
      -KeepLogHistory:$KeepLogHistory | Out-Null
  } catch {
    Fail ([string]$_.Exception.Message)
  }
}
