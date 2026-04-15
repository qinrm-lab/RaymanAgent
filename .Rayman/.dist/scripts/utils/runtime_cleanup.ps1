param(
  [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RaymanRuntimeCleanupWorkspaceRoot {
  param([string]$WorkspaceRoot)

  return (Resolve-Path -LiteralPath $WorkspaceRoot).Path
}

function Read-RaymanRuntimeCleanupJsonFile {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace([string]$Path)) { return $null }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace([string]$raw)) { return $null }
    return ($raw | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Write-RaymanRuntimeCleanupJsonFile {
  param(
    [string]$Path,
    [object]$Value,
    [int]$Depth = 8
  )

  if ([string]::IsNullOrWhiteSpace([string]$Path)) { return }
  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace([string]$parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  $json = ($Value | ConvertTo-Json -Depth $Depth)
  [System.IO.File]::WriteAllText($Path, ($json.TrimEnd() + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-RaymanRuntimeCleanupSummaryPath {
  param([string]$WorkspaceRoot)

  return (Join-Path (Resolve-RaymanRuntimeCleanupWorkspaceRoot -WorkspaceRoot $WorkspaceRoot) '.Rayman\runtime\cleanup.last.json')
}

function Get-RaymanRuntimeCleanupRelativePath {
  param(
    [string]$WorkspaceRoot,
    [string]$Path
  )

  $resolvedWorkspaceRoot = Resolve-RaymanRuntimeCleanupWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
  $resolvedPath = [System.IO.Path]::GetFullPath([string]$Path)
  if ($resolvedPath.StartsWith($resolvedWorkspaceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    return ($resolvedPath.Substring($resolvedWorkspaceRoot.Length).TrimStart('\', '/') -replace '\\', '/')
  }
  return ($resolvedPath -replace '\\', '/')
}

function Test-RaymanRuntimeCleanupPathWithinRoot {
  param(
    [string]$Path,
    [string]$Root
  )

  if ([string]::IsNullOrWhiteSpace([string]$Path) -or [string]::IsNullOrWhiteSpace([string]$Root)) {
    return $false
  }

  $fullPath = [System.IO.Path]::GetFullPath([string]$Path).TrimEnd('\', '/')
  $fullRoot = [System.IO.Path]::GetFullPath([string]$Root).TrimEnd('\', '/')
  if ($fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $true
  }
  return $fullPath.StartsWith($fullRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-RaymanRuntimeCleanupShouldDeleteByAge {
  param(
    [string]$Path,
    [datetime]$Now,
    [int]$KeepDays
  )

  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  if ($KeepDays -le 0) { return $true }

  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if ($null -eq $item) { return $false }
  $ageDays = [int][Math]::Floor(($Now - $item.LastWriteTime).TotalDays)
  return ($ageDays -ge $KeepDays)
}

function New-RaymanRuntimeCleanupEntry {
  param(
    [string]$WorkspaceRoot,
    [string]$Path,
    [string]$Category,
    [bool]$Preserved,
    [bool]$ShouldDelete,
    [string]$Reason
  )

  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  return [pscustomobject]@{
    path = [System.IO.Path]::GetFullPath([string]$Path)
    relative_path = Get-RaymanRuntimeCleanupRelativePath -WorkspaceRoot $WorkspaceRoot -Path $Path
    category = [string]$Category
    preserved = [bool]$Preserved
    should_delete = [bool]$ShouldDelete
    reason = [string]$Reason
    last_write_time = if ($null -ne $item) { $item.LastWriteTime.ToString('o') } else { '' }
  }
}

function Get-RaymanRuntimeCleanupOptionInt {
  param(
    [string]$Name,
    [int]$Value,
    [int]$Default,
    [int]$Min = 0
  )

  if ($Value -ge $Min) {
    return $Value
  }

  $raw = [string][System.Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace([string]$raw)) {
    return $Default
  }

  $parsed = 0
  if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge $Min) {
    return $parsed
  }

  return $Default
}

function Get-RaymanRuntimeCleanupActiveStagingRoots {
  param([string]$WorkspaceRoot)

  $resolvedWorkspaceRoot = Resolve-RaymanRuntimeCleanupWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
  $roots = New-Object System.Collections.Generic.List[string]

  foreach ($path in @(
      (Join-Path $resolvedWorkspaceRoot '.Rayman\runtime\worker\sync.last.json'),
      (Join-Path $resolvedWorkspaceRoot '.Rayman\state\workers\active.json')
    )) {
    $payload = Read-RaymanRuntimeCleanupJsonFile -Path $path
    if ($null -eq $payload) { continue }

    $syncManifest = $payload
    if ($payload.PSObject.Properties['sync_manifest'] -and $null -ne $payload.sync_manifest) {
      $syncManifest = $payload.sync_manifest
    }

    if ($null -eq $syncManifest) { continue }
    $mode = if ($syncManifest.PSObject.Properties['mode']) { [string]$syncManifest.mode } else { '' }
    $stagingRoot = if ($syncManifest.PSObject.Properties['staging_root']) { [string]$syncManifest.staging_root } else { '' }
    if ($mode -ne 'staged' -or [string]::IsNullOrWhiteSpace([string]$stagingRoot)) { continue }

    try {
      $resolvedStage = [System.IO.Path]::GetFullPath($stagingRoot)
      if ((Test-Path -LiteralPath $resolvedStage -PathType Container) -and (Test-RaymanRuntimeCleanupPathWithinRoot -Path $resolvedStage -Root $resolvedWorkspaceRoot) -and -not $roots.Contains($resolvedStage)) {
        $roots.Add($resolvedStage) | Out-Null
      }
    } catch {}
  }

  return @($roots.ToArray())
}

function Add-RaymanRuntimeCleanupUniqueEntry {
  param(
    [System.Collections.Generic.List[object]]$Entries,
    [hashtable]$Seen,
    [object]$Entry
  )

  if ($null -eq $Entry -or $null -eq $Entries -or $null -eq $Seen) {
    return
  }

  $path = if ($Entry.PSObject.Properties['path']) { [string]$Entry.path } else { '' }
  if ([string]::IsNullOrWhiteSpace([string]$path)) {
    return
  }

  $key = [System.IO.Path]::GetFullPath($path).TrimEnd('\', '/').ToLowerInvariant()
  if ($Seen.ContainsKey($key)) {
    return
  }
  $Seen[$key] = $true
  $Entries.Add($Entry) | Out-Null
}

function Test-RaymanRuntimeCleanupDescriptorApplies {
  param(
    [object]$Descriptor,
    [string]$Mode,
    [int]$Aggressive,
    [int]$CopySmokeArtifacts,
    [int]$AllowExternalTemp
  )

  if ($null -eq $Descriptor) { return $false }
  if (@($Descriptor.modes).Count -gt 0 -and $Mode -notin @($Descriptor.modes)) { return $false }
  if ($Descriptor.PSObject.Properties['aggressive_only'] -and [bool]$Descriptor.aggressive_only -and $Aggressive -ne 1) { return $false }
  if ($Descriptor.PSObject.Properties['requires_copy_smoke'] -and [bool]$Descriptor.requires_copy_smoke -and $CopySmokeArtifacts -ne 1) { return $false }
  if ($Descriptor.PSObject.Properties['requires_allow_external_temp'] -and [bool]$Descriptor.requires_allow_external_temp -and $AllowExternalTemp -ne 1) { return $false }
  return $true
}

function Test-RaymanRuntimeCleanupDescriptorDeleteAll {
  param(
    [object]$Descriptor,
    [string]$Mode
  )

  if ($null -eq $Descriptor) { return $false }
  if (-not $Descriptor.PSObject.Properties['delete_all_modes']) { return $false }
  return ($Mode -in @($Descriptor.delete_all_modes))
}

function Get-RaymanRuntimeCleanupPolicyDescriptors {
  param([string]$WorkspaceRoot)

  $resolvedWorkspaceRoot = Resolve-RaymanRuntimeCleanupWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
  return @(
    [pscustomobject]@{
      category = 'workspace_cache_segments'
      kind = 'recursive_segment'
      modes = @('cache-clear')
      names = @('bin', 'obj', '.vs', 'node_modules', '.pytest_cache', '.mypy_cache', '.ruff_cache', '__pycache__', '.turbo', '.next', 'dist', 'build', 'coverage', '.rag')
      delete_all_modes = @('cache-clear')
      excluded_relative_roots = @(
        '.git',
        '.venv',
        '.Rayman/.dist',
        '.Rayman/runtime/windows-sandbox/cache',
        '.Rayman/runtime/migration',
        '.Rayman/runtime/worker/staging',
        '.Rayman/runtime/worker/sync-temp',
        '.Rayman/runtime/worker/uploads',
        '.Rayman/runtime/worker/upgrade-temp',
        '.Rayman/runtime/bats_maui'
      )
    },
    [pscustomobject]@{
      category = 'workspace_cache_segments_aggressive'
      kind = 'recursive_segment'
      modes = @('cache-clear')
      names = @('.cache', '.parcel-cache')
      delete_all_modes = @('cache-clear')
      excluded_relative_roots = @(
        '.git',
        '.venv',
        '.Rayman/.dist',
        '.Rayman/runtime/windows-sandbox/cache',
        '.Rayman/runtime/migration',
        '.Rayman/runtime/worker/staging',
        '.Rayman/runtime/worker/sync-temp',
        '.Rayman/runtime/worker/uploads',
        '.Rayman/runtime/worker/upgrade-temp',
        '.Rayman/runtime/bats_maui'
      )
      aggressive_only = $true
    },
    [pscustomobject]@{
      category = 'workspace_tmp_sandbox'
      kind = 'root_child_pattern'
      modes = @('cache-clear', 'workspace-clean', 'post-command')
      root_path = $resolvedWorkspaceRoot
      name_patterns = @('.tmp_sandbox_verify_*', '.tmp_sandbox_verify_clean_*')
      delete_all_modes = @('post-command')
    },
    [pscustomobject]@{
      category = 'runtime_tmp'
      kind = 'root_children'
      modes = @('cache-clear', 'workspace-clean', 'post-command')
      root_path = (Join-Path $resolvedWorkspaceRoot '.Rayman\runtime\tmp')
      delete_all_modes = @('post-command')
    },
    [pscustomobject]@{
      category = 'telemetry_test_bundle'
      kind = 'root_child_pattern'
      modes = @('cache-clear', 'workspace-clean')
      root_path = (Join-Path $resolvedWorkspaceRoot '.Rayman\runtime\artifacts\telemetry')
      name_patterns = @('test-bundle*')
      delete_all_modes = @()
    },
    [pscustomobject]@{
      category = 'workspace_bundle_aggressive'
      kind = 'direct_path'
      modes = @('cache-clear', 'workspace-clean')
      path = (Join-Path $resolvedWorkspaceRoot '.Rayman_full_for_copy')
      delete_all_modes = @()
      aggressive_only = $true
    },
    [pscustomobject]@{
      category = 'workspace_bundle_aggressive'
      kind = 'direct_path'
      modes = @('cache-clear', 'workspace-clean')
      path = (Join-Path $resolvedWorkspaceRoot 'Rayman_full_bundle')
      delete_all_modes = @()
      aggressive_only = $true
    },
    [pscustomobject]@{
      category = 'external_copy_smoke'
      kind = 'root_child_pattern'
      modes = @('cache-clear', 'workspace-clean')
      root_path = [System.IO.Path]::GetTempPath()
      name_patterns = @('rayman_copy_smoke_*')
      delete_all_modes = @()
      requires_copy_smoke = $true
      requires_allow_external_temp = $true
    },
    [pscustomobject]@{
      category = 'workspace_rag'
      kind = 'direct_path'
      modes = @('cache-clear', 'workspace-clean')
      path = (Join-Path $resolvedWorkspaceRoot '.rag')
      delete_all_modes = @('cache-clear')
    },
    [pscustomobject]@{
      category = 'workspace_rag'
      kind = 'direct_path'
      modes = @('cache-clear', 'workspace-clean')
      path = (Join-Path $resolvedWorkspaceRoot '.Rayman\state\chroma_db')
      delete_all_modes = @('cache-clear')
    },
    [pscustomobject]@{
      category = 'workspace_rag'
      kind = 'direct_path'
      modes = @('cache-clear', 'workspace-clean')
      path = (Join-Path $resolvedWorkspaceRoot '.Rayman\state\rag.db')
      delete_all_modes = @('cache-clear')
    },
    [pscustomobject]@{
      category = 'worker_staging'
      kind = 'root_children'
      modes = @('cache-clear', 'workspace-clean', 'setup-prune', 'post-command')
      root_path = (Join-Path $resolvedWorkspaceRoot '.Rayman\runtime\worker\staging')
      delete_all_modes = @('cache-clear', 'setup-prune', 'post-command')
      preserve_active_staging_roots = $true
      cleanup_root = $true
    },
    [pscustomobject]@{
      category = 'worker_sync_temp'
      kind = 'root_children'
      modes = @('cache-clear', 'workspace-clean', 'setup-prune', 'post-command')
      root_path = (Join-Path $resolvedWorkspaceRoot '.Rayman\runtime\worker\sync-temp')
      delete_all_modes = @('cache-clear', 'setup-prune', 'post-command')
      cleanup_root = $true
    },
    [pscustomobject]@{
      category = 'worker_uploads'
      kind = 'root_children'
      modes = @('cache-clear', 'workspace-clean', 'setup-prune', 'post-command')
      root_path = (Join-Path $resolvedWorkspaceRoot '.Rayman\runtime\worker\uploads')
      delete_all_modes = @('cache-clear', 'setup-prune', 'post-command')
      cleanup_root = $true
    },
    [pscustomobject]@{
      category = 'worker_upgrade_temp'
      kind = 'root_children'
      modes = @('cache-clear', 'workspace-clean', 'setup-prune', 'post-command')
      root_path = (Join-Path $resolvedWorkspaceRoot '.Rayman\runtime\worker\upgrade-temp')
      delete_all_modes = @('cache-clear', 'setup-prune', 'post-command')
      cleanup_root = $true
    },
    [pscustomobject]@{
      category = 'bats_maui'
      kind = 'root_children'
      modes = @('cache-clear', 'workspace-clean', 'setup-prune', 'post-command')
      root_path = (Join-Path $resolvedWorkspaceRoot '.Rayman\runtime\bats_maui')
      delete_all_modes = @('cache-clear', 'setup-prune', 'post-command')
      cleanup_root = $true
    },
    [pscustomobject]@{
      category = 'migration_nested'
      kind = 'migration_nested'
      modes = @('cache-clear', 'workspace-clean', 'setup-prune')
      root_path = (Join-Path $resolvedWorkspaceRoot '.Rayman\runtime\migration')
      delete_all_modes = @('cache-clear')
    }
  )
}

function Get-RaymanRuntimeCleanupDirectPathEntries {
  param(
    [string]$WorkspaceRoot,
    [string]$Path,
    [string]$Category,
    [bool]$DeleteAll,
    [int]$KeepDays,
    [datetime]$Now
  )

  if ([string]::IsNullOrWhiteSpace([string]$Path) -or -not (Test-Path -LiteralPath $Path)) {
    return @()
  }

  $shouldDelete = if ($DeleteAll) {
    $true
  } else {
    Test-RaymanRuntimeCleanupShouldDeleteByAge -Path $Path -Now $Now -KeepDays $KeepDays
  }
  if (-not $shouldDelete) {
    return @()
  }

  return @((New-RaymanRuntimeCleanupEntry -WorkspaceRoot $WorkspaceRoot -Path $Path -Category $Category -Preserved $false -ShouldDelete $true -Reason 'transient'))
}

function Get-RaymanRuntimeCleanupRootChildrenEntries {
  param(
    [string]$WorkspaceRoot,
    [string]$RootPath,
    [string]$Category,
    [bool]$DeleteAll,
    [int]$KeepDays,
    [datetime]$Now,
    [string[]]$PreserveRoots = @(),
    [string[]]$NamePatterns = @()
  )

  $entries = New-Object System.Collections.Generic.List[object]
  if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
    return @()
  }

  foreach ($item in @(Get-ChildItem -LiteralPath $RootPath -Force -ErrorAction SilentlyContinue)) {
    if ($NamePatterns.Count -gt 0) {
      $matchedPattern = $false
      foreach ($pattern in @($NamePatterns)) {
        if ([string]$item.Name -like [string]$pattern) {
          $matchedPattern = $true
          break
        }
      }
      if (-not $matchedPattern) {
        continue
      }
    }

    $preserve = $false
    foreach ($preserveRoot in @($PreserveRoots)) {
      if (Test-RaymanRuntimeCleanupPathWithinRoot -Path $preserveRoot -Root $item.FullName) {
        $preserve = $true
        break
      }
    }

    if ($preserve) {
      $entries.Add((New-RaymanRuntimeCleanupEntry -WorkspaceRoot $WorkspaceRoot -Path $item.FullName -Category $Category -Preserved $true -ShouldDelete $false -Reason 'active_staging_root')) | Out-Null
      continue
    }

    $shouldDelete = if ($DeleteAll) {
      $true
    } else {
      Test-RaymanRuntimeCleanupShouldDeleteByAge -Path $item.FullName -Now $Now -KeepDays $KeepDays
    }
    if ($shouldDelete) {
      $entries.Add((New-RaymanRuntimeCleanupEntry -WorkspaceRoot $WorkspaceRoot -Path $item.FullName -Category $Category -Preserved $false -ShouldDelete $true -Reason 'transient')) | Out-Null
    }
  }

  return @($entries.ToArray())
}

function Get-RaymanRuntimeCleanupRecursiveSegmentEntries {
  param(
    [string]$WorkspaceRoot,
    [string[]]$Names = @(),
    [string]$Category,
    [bool]$DeleteAll,
    [int]$KeepDays,
    [datetime]$Now,
    [string[]]$ExcludedRelativeRoots = @()
  )

  $resolvedWorkspaceRoot = Resolve-RaymanRuntimeCleanupWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
  if ($Names.Count -eq 0) {
    return @()
  }

  $nameLookup = @{}
  foreach ($name in @($Names)) {
    $normalizedName = ([string]$name).ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace([string]$normalizedName)) {
      $nameLookup[$normalizedName] = $true
    }
  }
  $excludedPrefixes = @($ExcludedRelativeRoots | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim('\', '/').Replace('\', '/').ToLowerInvariant() } | Select-Object -Unique)
  $pending = New-Object 'System.Collections.Generic.Stack[string]'
  $entries = New-Object System.Collections.Generic.List[object]
  $pending.Push($resolvedWorkspaceRoot)

  while ($pending.Count -gt 0) {
    $current = [string]$pending.Pop()
    foreach ($directory in @(Get-ChildItem -LiteralPath $current -Directory -Force -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)) {
      $relativePath = (Get-RaymanRuntimeCleanupRelativePath -WorkspaceRoot $resolvedWorkspaceRoot -Path $directory.FullName).Trim('\', '/')
      $normalizedRelativePath = $relativePath.Replace('\', '/').ToLowerInvariant()

      $skipDirectory = $false
      foreach ($excludedPrefix in @($excludedPrefixes)) {
        if ([string]::IsNullOrWhiteSpace([string]$excludedPrefix)) { continue }
        if ($normalizedRelativePath.Equals($excludedPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or $normalizedRelativePath.StartsWith($excludedPrefix + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
          $skipDirectory = $true
          break
        }
      }
      if ($skipDirectory) {
        continue
      }

      if ($nameLookup.ContainsKey(([string]$directory.Name).ToLowerInvariant())) {
        $shouldDelete = if ($DeleteAll) {
          $true
        } else {
          Test-RaymanRuntimeCleanupShouldDeleteByAge -Path $directory.FullName -Now $Now -KeepDays $KeepDays
        }
        if ($shouldDelete) {
          $entries.Add((New-RaymanRuntimeCleanupEntry -WorkspaceRoot $resolvedWorkspaceRoot -Path $directory.FullName -Category $Category -Preserved $false -ShouldDelete $true -Reason 'transient')) | Out-Null
        }
        continue
      }

      $pending.Push([string]$directory.FullName)
    }
  }

  return @($entries.ToArray())
}

function Get-RaymanRuntimeCleanupMigrationEntries {
  param(
    [string]$WorkspaceRoot,
    [string]$RootPath,
    [bool]$DeleteAll,
    [int]$KeepDays,
    [datetime]$Now
  )

  $entries = New-Object System.Collections.Generic.List[object]
  if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
    return @()
  }

  $nestedBackups = @(Get-ChildItem -LiteralPath $RootPath -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'nested_rayman_*' } | Sort-Object LastWriteTime -Descending)
  if ($nestedBackups.Count -le 0) {
    return @()
  }

  $latestBackup = $nestedBackups[0].FullName
  foreach ($backup in $nestedBackups) {
    if ($backup.FullName.Equals($latestBackup, [System.StringComparison]::OrdinalIgnoreCase)) {
      $entries.Add((New-RaymanRuntimeCleanupEntry -WorkspaceRoot $WorkspaceRoot -Path $backup.FullName -Category 'migration_nested' -Preserved $true -ShouldDelete $false -Reason 'latest_nested_backup')) | Out-Null
      continue
    }

    $shouldDelete = if ($DeleteAll) {
      $true
    } else {
      Test-RaymanRuntimeCleanupShouldDeleteByAge -Path $backup.FullName -Now $Now -KeepDays $KeepDays
    }
    if ($shouldDelete) {
      $entries.Add((New-RaymanRuntimeCleanupEntry -WorkspaceRoot $WorkspaceRoot -Path $backup.FullName -Category 'migration_nested' -Preserved $false -ShouldDelete $true -Reason 'expired_nested_backup')) | Out-Null
    }
  }

  return @($entries.ToArray())
}

function Remove-RaymanRuntimeCleanupEmptyRoots {
  param([string[]]$RootPaths)

  foreach ($rootPath in @($RootPaths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
      continue
    }
    $remaining = @(Get-ChildItem -LiteralPath $rootPath -Force -ErrorAction SilentlyContinue)
    if ($remaining.Count -eq 0) {
      Remove-Item -LiteralPath $rootPath -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

function Invoke-RaymanRuntimeCleanup {
  param(
    [string]$WorkspaceRoot,
    [ValidateSet('cache-clear', 'workspace-clean', 'setup-prune', 'post-command')][string]$Mode = 'workspace-clean',
    [int]$KeepDays = -1,
    [switch]$DryRun,
    [switch]$WriteSummary,
    [int]$Aggressive = -1,
    [int]$CopySmokeArtifacts = -1,
    [int]$AllowExternalTemp = -1
  )

  $resolvedWorkspaceRoot = Resolve-RaymanRuntimeCleanupWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
  $keepDaysValue = Get-RaymanRuntimeCleanupOptionInt -Name 'RAYMAN_CLEAN_KEEP_DAYS' -Value $KeepDays -Default 14 -Min 0
  $aggressiveValue = Get-RaymanRuntimeCleanupOptionInt -Name 'RAYMAN_CLEAN_AGGRESSIVE' -Value $Aggressive -Default 0 -Min 0
  $copySmokeArtifactsValue = Get-RaymanRuntimeCleanupOptionInt -Name 'RAYMAN_CLEAN_COPY_SMOKE_ARTIFACTS' -Value $CopySmokeArtifacts -Default 0 -Min 0
  $allowExternalTempValue = Get-RaymanRuntimeCleanupOptionInt -Name 'RAYMAN_CLEAN_ALLOW_EXTERNAL_TEMP' -Value $AllowExternalTemp -Default 0 -Min 0
  $now = Get-Date
  $activeStagingRoots = @(Get-RaymanRuntimeCleanupActiveStagingRoots -WorkspaceRoot $resolvedWorkspaceRoot)
  $entries = New-Object System.Collections.Generic.List[object]
  $seen = @{}
  $cleanupRoots = New-Object System.Collections.Generic.List[string]

  foreach ($descriptor in @(Get-RaymanRuntimeCleanupPolicyDescriptors -WorkspaceRoot $resolvedWorkspaceRoot)) {
    if (-not (Test-RaymanRuntimeCleanupDescriptorApplies -Descriptor $descriptor -Mode $Mode -Aggressive $aggressiveValue -CopySmokeArtifacts $copySmokeArtifactsValue -AllowExternalTemp $allowExternalTempValue)) {
      continue
    }

    $deleteAll = Test-RaymanRuntimeCleanupDescriptorDeleteAll -Descriptor $descriptor -Mode $Mode
    $descriptorEntries = @()
    switch ([string]$descriptor.kind) {
      'direct_path' {
        $descriptorEntries = @(Get-RaymanRuntimeCleanupDirectPathEntries -WorkspaceRoot $resolvedWorkspaceRoot -Path ([string]$descriptor.path) -Category ([string]$descriptor.category) -DeleteAll:$deleteAll -KeepDays $keepDaysValue -Now $now)
        break
      }
      'root_children' {
        $preserveRoots = if ($descriptor.PSObject.Properties['preserve_active_staging_roots'] -and [bool]$descriptor.preserve_active_staging_roots) { @($activeStagingRoots) } else { @() }
        $descriptorEntries = @(Get-RaymanRuntimeCleanupRootChildrenEntries -WorkspaceRoot $resolvedWorkspaceRoot -RootPath ([string]$descriptor.root_path) -Category ([string]$descriptor.category) -DeleteAll:$deleteAll -KeepDays $keepDaysValue -Now $now -PreserveRoots $preserveRoots)
        break
      }
      'root_child_pattern' {
        $descriptorEntries = @(Get-RaymanRuntimeCleanupRootChildrenEntries -WorkspaceRoot $resolvedWorkspaceRoot -RootPath ([string]$descriptor.root_path) -Category ([string]$descriptor.category) -DeleteAll:$deleteAll -KeepDays $keepDaysValue -Now $now -NamePatterns @($descriptor.name_patterns))
        break
      }
      'recursive_segment' {
        $descriptorEntries = @(Get-RaymanRuntimeCleanupRecursiveSegmentEntries -WorkspaceRoot $resolvedWorkspaceRoot -Names @($descriptor.names) -Category ([string]$descriptor.category) -DeleteAll:$deleteAll -KeepDays $keepDaysValue -Now $now -ExcludedRelativeRoots @($descriptor.excluded_relative_roots))
        break
      }
      'migration_nested' {
        $descriptorEntries = @(Get-RaymanRuntimeCleanupMigrationEntries -WorkspaceRoot $resolvedWorkspaceRoot -RootPath ([string]$descriptor.root_path) -DeleteAll:$deleteAll -KeepDays $keepDaysValue -Now $now)
        break
      }
    }

    foreach ($entry in @($descriptorEntries)) {
      Add-RaymanRuntimeCleanupUniqueEntry -Entries $entries -Seen $seen -Entry $entry
    }
    if ($descriptor.PSObject.Properties['cleanup_root'] -and [bool]$descriptor.cleanup_root -and -not [string]::IsNullOrWhiteSpace([string]$descriptor.root_path)) {
      if (-not $cleanupRoots.Contains([string]$descriptor.root_path)) {
        $cleanupRoots.Add([string]$descriptor.root_path) | Out-Null
      }
    }
  }

  $plannedRemovals = @($entries.ToArray() | Where-Object { -not [bool]$_.preserved -and [bool]$_.should_delete })
  $preserved = @($entries.ToArray() | Where-Object { [bool]$_.preserved })
  $removed = New-Object System.Collections.Generic.List[object]
  $failed = New-Object System.Collections.Generic.List[object]

  if (-not $DryRun) {
    foreach ($entry in @($plannedRemovals | Sort-Object { $_.path.Length } -Descending)) {
      try {
        if (Test-Path -LiteralPath ([string]$entry.path)) {
          Remove-Item -LiteralPath ([string]$entry.path) -Recurse -Force -ErrorAction Stop
        }
        $removed.Add($entry) | Out-Null
      } catch {
        $failed.Add([pscustomobject]@{
            path = [string]$entry.path
            relative_path = [string]$entry.relative_path
            category = [string]$entry.category
            error = [string]$_.Exception.Message
          }) | Out-Null
      }
    }

    Remove-RaymanRuntimeCleanupEmptyRoots -RootPaths @($cleanupRoots.ToArray())
  }

  $report = [pscustomobject]@{
    schema = 'rayman.runtime.cleanup.v1'
    generated_at = (Get-Date).ToString('o')
    workspace_root = $resolvedWorkspaceRoot
    mode = $Mode
    keep_days = $keepDaysValue
    dry_run = [bool]$DryRun
    aggressive = $aggressiveValue
    copy_smoke_artifacts = $copySmokeArtifactsValue
    allow_external_temp = $allowExternalTempValue
    active_staging_roots = @($activeStagingRoots | ForEach-Object { Get-RaymanRuntimeCleanupRelativePath -WorkspaceRoot $resolvedWorkspaceRoot -Path $_ })
    candidate_count = $entries.Count
    planned_removal_count = $plannedRemovals.Count
    preserved_count = $preserved.Count
    removed_count = $removed.Count
    failed_count = $failed.Count
    planned_removals = @($plannedRemovals | ForEach-Object {
        [pscustomobject]@{
          path = [string]$_.relative_path
          category = [string]$_.category
          reason = [string]$_.reason
        }
      })
    preserved = @($preserved | ForEach-Object {
        [pscustomobject]@{
          path = [string]$_.relative_path
          category = [string]$_.category
          reason = [string]$_.reason
        }
      })
    failed = @($failed.ToArray())
  }

  if ($WriteSummary) {
    Write-RaymanRuntimeCleanupJsonFile -Path (Get-RaymanRuntimeCleanupSummaryPath -WorkspaceRoot $resolvedWorkspaceRoot) -Value $report -Depth 8
  }

  return $report
}

if (-not $NoMain) {
  Invoke-RaymanRuntimeCleanup -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path | ConvertTo-Json -Depth 8
}
