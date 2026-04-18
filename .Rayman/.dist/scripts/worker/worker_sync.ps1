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

function Get-RaymanWorkerSyncRelativePath {
  param(
    [string]$Root,
    [string]$Path
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
  $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
  return $resolvedPath.Substring($resolvedRoot.Length).TrimStart('\', '/')
}

function Get-RaymanWorkerSyncNoiseRules {
  param([string]$WorkspaceRoot)

  if (-not (Get-Command Get-RaymanScmTrackedNoiseRules -ErrorAction SilentlyContinue)) {
    return @()
  }

  $rules = Get-RaymanScmTrackedNoiseRules -WorkspaceRoot $WorkspaceRoot
  if ($null -eq $rules -or -not $rules.PSObject.Properties['All']) {
    return @()
  }
  return @($rules.All)
}

function Get-RaymanWorkerSyncIgnoredPathLookup {
  param(
    [string]$WorkspaceRoot,
    [string[]]$RelativePaths = @()
  )

  $lookup = @{}
  $normalized = @($RelativePaths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Replace('\', '/') } | Select-Object -Unique)
  if ($normalized.Count -eq 0) {
    return $lookup
  }

  $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $git -or [string]::IsNullOrWhiteSpace([string]$git.Source)) {
    return $lookup
  }

  try {
    $ignoredOutput = (($normalized -join "`n") | & $git.Source -C $WorkspaceRoot check-ignore --stdin 2>$null)
    if ($LASTEXITCODE -notin @(0, 1)) {
      return $lookup
    }
    foreach ($line in @($ignoredOutput)) {
      $candidate = [string]$line
      if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
        continue
      }
      $lookup[$candidate.Replace('\', '/')] = $true
    }
  } catch {}

  return $lookup
}

function Test-RaymanWorkerSyncExcluded {
  param(
    [string]$Root,
    [string]$Path,
    [object[]]$NoiseRules = @()
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
  $relative = Get-RaymanWorkerSyncRelativePath -Root $resolvedRoot -Path $Path
  $segments = @($relative -split '[\\/]')
  foreach ($name in @(Get-RaymanWorkerSyncSegmentExcludes)) {
    if ($segments -contains $name) { return $true }
  }
  foreach ($prefix in @(Get-RaymanWorkerSyncExcludes)) {
    $normalizedPrefix = ($prefix -replace '/', '\').TrimStart('\')
    if ($relative.Equals($normalizedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($relative.StartsWith($normalizedPrefix + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  }

  $normalizedRelative = $relative.Replace('\', '/')
  foreach ($rule in @($NoiseRules)) {
    if ($null -eq $rule) { continue }
    if (Get-Command Test-RaymanScmTrackedNoiseRuleMatch -ErrorAction SilentlyContinue) {
      if (Test-RaymanScmTrackedNoiseRuleMatch -NormalizedPath $normalizedRelative -Rule $rule) {
        return $true
      }
    }
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

function Get-RaymanWorkerSyncIncludedFiles {
  param([string]$WorkspaceRoot)

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $noiseRules = @(Get-RaymanWorkerSyncNoiseRules -WorkspaceRoot $resolvedRoot)
  $files = @(Get-ChildItem -LiteralPath $resolvedRoot -Recurse -Force -File -ErrorAction SilentlyContinue)
  $candidates = New-Object System.Collections.Generic.List[object]
  foreach ($file in $files) {
    if (Test-RaymanWorkerSyncExcluded -Root $resolvedRoot -Path $file.FullName -NoiseRules $noiseRules) { continue }
    $relative = (Get-RaymanWorkerSyncRelativePath -Root $resolvedRoot -Path $file.FullName).Replace('\', '/')
    $candidates.Add([pscustomobject]@{
        source = [string]$file.FullName
        relative = $relative
        length = [int64]$file.Length
        last_write_utc_ticks = [int64]$file.LastWriteTimeUtc.Ticks
      }) | Out-Null
  }

  $ignoredLookup = Get-RaymanWorkerSyncIgnoredPathLookup -WorkspaceRoot $resolvedRoot -RelativePaths @($candidates | ForEach-Object { [string]$_.relative })
  return @(
    $candidates.ToArray() |
      Where-Object { -not $ignoredLookup.ContainsKey([string]$_.relative) } |
      Sort-Object relative
  )
}

function Get-RaymanWorkerSyncFingerprintInfo {
  param(
    [string]$WorkspaceRoot,
    [object[]]$IncludedFiles = @()
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $entries = if ($IncludedFiles.Count -gt 0) {
    @($IncludedFiles | Sort-Object relative)
  } else {
    @(Get-RaymanWorkerSyncIncludedFiles -WorkspaceRoot $resolvedRoot)
  }

  $tokens = New-Object System.Collections.Generic.List[string]
  foreach ($entry in @($entries)) {
    $tokens.Add(("{0}|{1}|{2}" -f [string]$entry.relative, [int64]$entry.length, [int64]$entry.last_write_utc_ticks)) | Out-Null
  }

  $payload = [System.Text.Encoding]::UTF8.GetBytes((@($tokens.ToArray()) -join "`n"))
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hashBytes = $sha.ComputeHash($payload)
  } finally {
    $sha.Dispose()
  }

  return [pscustomobject]@{
    schema = 'rayman.worker.sync_fingerprint.v1'
    generated_at = (Get-Date).ToString('o')
    workspace_root = $resolvedRoot
    file_count = $entries.Count
    fingerprint = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
    entries = @($entries)
  }
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

  $includedEntries = @(Get-RaymanWorkerSyncIncludedFiles -WorkspaceRoot $resolvedRoot)
  $included = New-Object System.Collections.Generic.List[string]
  foreach ($candidate in @($includedEntries)) {
    $relative = [string]$candidate.relative
    $destination = Join-Path $payloadRoot ($relative -replace '/', '\')
    Copy-RaymanWorkerSyncFile -Source ([string]$candidate.source) -Destination $destination
    $included.Add($relative) | Out-Null
  }
  $fingerprintInfo = Get-RaymanWorkerSyncFingerprintInfo -WorkspaceRoot $resolvedRoot -IncludedFiles $includedEntries

  $manifest = [pscustomobject]@{
    schema = 'rayman.worker.sync_bundle.v1'
    generated_at = (Get-Date).ToString('o')
    bundle_id = $bundleId
    source_workspace_root = $resolvedRoot
    file_count = $included.Count
    fingerprint = [string]$fingerprintInfo.fingerprint
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
    [string]$ExecutionRoot = '',
    [object]$ClientContext = $null
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $resolvedBundle = (Resolve-Path -LiteralPath $BundlePath).Path
  $resolvedClientContext = Resolve-RaymanWorkerClientContext -WorkspaceRoot '' -ClientContext $ClientContext
  if ($null -eq $resolvedClientContext) {
    throw 'client_context is required for staged sync on a shared worker'
  }
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
    $ExecutionRoot = Join-Path (Get-RaymanWorkerClientStagingRoot -WorkspaceRoot $resolvedRoot -ClientId ([string]$resolvedClientContext.client_id)) ("stage-{0}" -f [string]$manifest.bundle_id)
  }
  Ensure-RaymanWorkerDirectory -Path $ExecutionRoot

  Copy-Item -Path (Join-Path $payloadRoot '*') -Destination $ExecutionRoot -Recurse -Force
  $syncManifest = [pscustomobject]@{
    schema = 'rayman.worker.sync_manifest.v1'
    generated_at = (Get-Date).ToString('o')
    mode = 'staged'
    bundle_id = [string]$manifest.bundle_id
    bundle_path = $resolvedBundle
    client_id = [string]$resolvedClientContext.client_id
    client_context = $resolvedClientContext
    source_workspace_root = [string]$manifest.source_workspace_root
    staging_root = $ExecutionRoot
    cleanup_hint = ('Remove-Item -LiteralPath ''{0}'' -Recurse -Force' -f $ExecutionRoot.Replace("'", "''"))
    rollback_hint = 'switch back to attached mode'
    bundle_manifest = $manifest
  }
  Set-RaymanWorkerClientSyncManifest -WorkspaceRoot $resolvedRoot -ClientContext $resolvedClientContext -SyncManifest $syncManifest | Out-Null
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
