param(
  [string]$WorkspaceRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path,
  [ValidateSet('build-bundle', 'materialize-bundle')][string]$Action = 'build-bundle',
  [string]$BundlePath = '',
  [string]$ExecutionRoot = '',
  [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'worker_common.ps1')

function Get-RaymanWorkerSyncTempRoot {
  param([string]$WorkspaceRoot)

  $path = Join-Path (Get-RaymanWorkerHostRuntimeRoot -WorkspaceRoot $WorkspaceRoot) 'sync-temp'
  Ensure-RaymanWorkerDirectory -Path $path
  return $path
}

function Get-RaymanWorkerSyncExcludes {
  return @(
    '.git',
    '.venv',
    'venv',
    'env',
    'node_modules',
    '.vs',
    '.idea',
    '__pycache__',
    '.pytest_cache',
    '.mypy_cache',
    'bin',
    'obj',
    '.Rayman\runtime',
    '.Rayman\state',
    '.Rayman\logs',
    '.Rayman\temp',
    '.Rayman\tmp',
    '.Rayman\.dist'
  )
}

function Get-RaymanWorkerSyncSegmentExcludes {
  return @(
    '.venv',
    'venv',
    'env',
    'node_modules',
    '.vs',
    '.idea',
    '__pycache__',
    '.pytest_cache',
    '.mypy_cache',
    'bin',
    'obj'
  )
}

function Test-RaymanWorkerSyncExcluded {
  param(
    [string]$Root,
    [string]$Path
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
  $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
  $relative = $resolvedPath.Substring($resolvedRoot.Length).TrimStart('\', '/')
  $segments = @($relative -split '[\\/]')
  foreach ($name in @(Get-RaymanWorkerSyncSegmentExcludes)) {
    if ($segments -contains $name) { return $true }
  }
  foreach ($prefix in @(Get-RaymanWorkerSyncExcludes)) {
    $normalizedPrefix = ($prefix -replace '/', '\').TrimStart('\')
    if ($relative.Equals($normalizedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($relative.StartsWith($normalizedPrefix + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

function Copy-RaymanWorkerSyncFile {
  param(
    [string]$Source,
    [string]$Destination
  )

  $parent = Split-Path -Parent $Destination
  if (-not [string]::IsNullOrWhiteSpace([string]$parent)) {
    Ensure-RaymanWorkerDirectory -Path $parent
  }
  [System.IO.File]::Copy($Source, $Destination, $true)
}

function New-RaymanWorkerSyncBundle {
  param(
    [string]$WorkspaceRoot,
    [string]$OutFile = ''
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $tempRoot = Get-RaymanWorkerSyncTempRoot -WorkspaceRoot $resolvedRoot
  $bundleId = [Guid]::NewGuid().ToString('n')
  $stageRoot = Join-Path $tempRoot ("b-{0}" -f $bundleId.Substring(0, 8))
  $payloadRoot = Join-Path $stageRoot 'payload'
  Ensure-RaymanWorkerDirectory -Path $payloadRoot

  $files = @(Get-ChildItem -LiteralPath $resolvedRoot -Recurse -Force -File -ErrorAction SilentlyContinue)
  $included = New-Object System.Collections.Generic.List[string]
  foreach ($file in $files) {
    if (Test-RaymanWorkerSyncExcluded -Root $resolvedRoot -Path $file.FullName) { continue }
    $relative = $file.FullName.Substring($resolvedRoot.Length).TrimStart('\', '/')
    $destination = Join-Path $payloadRoot $relative
    Copy-RaymanWorkerSyncFile -Source $file.FullName -Destination $destination
    $included.Add(($relative -replace '\\', '/')) | Out-Null
  }

  $manifest = [pscustomobject]@{
    schema = 'rayman.worker.sync_bundle.v1'
    generated_at = (Get-Date).ToString('o')
    bundle_id = $bundleId
    source_workspace_root = $resolvedRoot
    file_count = $included.Count
    files = @($included.ToArray())
    git = (Get-RaymanWorkerGitSnapshot -WorkspaceRoot $resolvedRoot)
  }
  Write-RaymanWorkerJsonFile -Path (Join-Path $stageRoot 'manifest.json') -Value $manifest

  if ([string]::IsNullOrWhiteSpace([string]$OutFile)) {
    $OutFile = Join-Path $tempRoot ("sync-bundle-{0}.zip" -f $bundleId)
  }
  if (Test-Path -LiteralPath $OutFile -PathType Leaf) {
    Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
  }

  Compress-Archive -Path (Join-Path $stageRoot '*') -DestinationPath $OutFile -Force
  return [pscustomobject]@{
    schema = 'rayman.worker.sync_bundle.result.v1'
    generated_at = (Get-Date).ToString('o')
    bundle_id = $bundleId
    bundle_path = $OutFile
    manifest = $manifest
  }
}

function Expand-RaymanWorkerSyncBundle {
  param(
    [string]$WorkspaceRoot,
    [string]$BundlePath,
    [string]$ExecutionRoot = ''
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $resolvedBundle = (Resolve-Path -LiteralPath $BundlePath).Path
  $tempRoot = Get-RaymanWorkerSyncTempRoot -WorkspaceRoot $resolvedRoot
  $extractRoot = Join-Path $tempRoot ("x-{0}" -f [Guid]::NewGuid().ToString('n').Substring(0, 8))
  Ensure-RaymanWorkerDirectory -Path $extractRoot
  Expand-Archive -LiteralPath $resolvedBundle -DestinationPath $extractRoot -Force

  $manifestPath = Join-Path $extractRoot 'manifest.json'
  $manifest = Read-RaymanWorkerJsonFile -Path $manifestPath
  if ($null -eq $manifest) {
    throw ("sync bundle manifest missing: {0}" -f $manifestPath)
  }

  $payloadRoot = Join-Path $extractRoot 'payload'
  if ([string]::IsNullOrWhiteSpace([string]$ExecutionRoot)) {
    $ExecutionRoot = Join-Path (Get-RaymanWorkerStagingRoot -WorkspaceRoot $resolvedRoot) ("stage-{0}" -f [string]$manifest.bundle_id)
  }
  Ensure-RaymanWorkerDirectory -Path $ExecutionRoot

  Copy-Item -LiteralPath (Join-Path $payloadRoot '*') -Destination $ExecutionRoot -Recurse -Force
  $syncManifest = [pscustomobject]@{
    schema = 'rayman.worker.sync_manifest.v1'
    generated_at = (Get-Date).ToString('o')
    mode = 'staged'
    bundle_id = [string]$manifest.bundle_id
    bundle_path = $resolvedBundle
    source_workspace_root = [string]$manifest.source_workspace_root
    staging_root = $ExecutionRoot
    cleanup_hint = ('Remove-Item -LiteralPath ''{0}'' -Recurse -Force' -f $ExecutionRoot.Replace("'", "''"))
    rollback_hint = 'switch back to attached mode'
    bundle_manifest = $manifest
  }
  Write-RaymanWorkerJsonFile -Path (Get-RaymanWorkerSyncLastPath -WorkspaceRoot $resolvedRoot) -Value $syncManifest
  return $syncManifest
}

if (-not $NoMain) {
  $WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  switch ($Action) {
    'build-bundle' {
      New-RaymanWorkerSyncBundle -WorkspaceRoot $WorkspaceRoot -OutFile $BundlePath | ConvertTo-Json -Depth 12
      break
    }
    'materialize-bundle' {
      Expand-RaymanWorkerSyncBundle -WorkspaceRoot $WorkspaceRoot -BundlePath $BundlePath -ExecutionRoot $ExecutionRoot | ConvertTo-Json -Depth 12
      break
    }
  }
}
