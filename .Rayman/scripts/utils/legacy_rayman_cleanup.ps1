param(
  [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-RaymanLegacyWorkspaceResidueName {
  param([string]$Name)

  if ([string]::IsNullOrWhiteSpace([string]$Name)) { return $false }

  $nameLower = [string]$Name
  try {
    $nameLower = $nameLower.ToLowerInvariant()
  } catch {}

  return (
    $nameLower -like '.rayman.__rayman_workspace_install_old_*' -or
    $nameLower -like '.rayman.bak*' -or
    $nameLower -like '.rayman.stage.*'
  )
}

function Test-RaymanLegacyWorkspaceTempResidueName {
  param([string]$Name)

  if ([string]::IsNullOrWhiteSpace([string]$Name)) { return $false }

  $nameLower = [string]$Name
  try {
    $nameLower = $nameLower.ToLowerInvariant()
  } catch {}

  return ($nameLower -like 'rayman-dynamic-sandbox*')
}

function Test-RaymanLegacyWorkspaceResidueRelativePath {
  param([string]$RelativePath)

  if ([string]::IsNullOrWhiteSpace([string]$RelativePath)) { return $false }

  $segments = @(([string]$RelativePath -replace '\\', '/') -split '/' | Where-Object {
      -not [string]::IsNullOrWhiteSpace([string]$_)
    })
  if ($segments.Count -lt 1) { return $false }

  if (Test-RaymanLegacyWorkspaceResidueName -Name ([string]$segments[0])) {
    return $true
  }

  if ($segments.Count -ge 2 -and [string]$segments[0] -eq '.temp' -and (Test-RaymanLegacyWorkspaceTempResidueName -Name ([string]$segments[1]))) {
    return $true
  }

  return $false
}

function Get-RaymanLegacyWorkspaceResidueCandidates {
  param([string]$WorkspaceRoot)

  if ([string]::IsNullOrWhiteSpace([string]$WorkspaceRoot)) { return @() }

  $resolvedRoot = $WorkspaceRoot
  try {
    $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  } catch {
    $resolvedRoot = [System.IO.Path]::GetFullPath([string]$WorkspaceRoot)
  }

  if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
    return @()
  }

  $matches = New-Object System.Collections.Generic.List[object]
  foreach ($item in @(Get-ChildItem -LiteralPath $resolvedRoot -Force -ErrorAction SilentlyContinue)) {
    if (-not (Test-RaymanLegacyWorkspaceResidueName -Name ([string]$item.Name))) {
      continue
    }
    $matches.Add($item) | Out-Null
  }

  $tempRoot = Join-Path $resolvedRoot '.temp'
  if (Test-Path -LiteralPath $tempRoot -PathType Container) {
    foreach ($item in @(Get-ChildItem -LiteralPath $tempRoot -Force -ErrorAction SilentlyContinue)) {
      if (-not (Test-RaymanLegacyWorkspaceTempResidueName -Name ([string]$item.Name))) {
        continue
      }
      $matches.Add($item) | Out-Null
    }
  }

  return @($matches.ToArray() | Sort-Object FullName -Unique)
}

function Invoke-RaymanLegacyWorkspaceCleanup {
  param([string]$WorkspaceRoot)

  $removedPaths = New-Object System.Collections.Generic.List[string]
  $failedPaths = New-Object System.Collections.Generic.List[string]

  $resolvedRoot = $WorkspaceRoot
  try {
    $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  } catch {
    try {
      $resolvedRoot = [System.IO.Path]::GetFullPath([string]$WorkspaceRoot)
    } catch {
      $resolvedRoot = [string]$WorkspaceRoot
    }
  }

  foreach ($candidate in @(Get-RaymanLegacyWorkspaceResidueCandidates -WorkspaceRoot $WorkspaceRoot)) {
    $candidatePath = [string]$candidate.FullName
    if ([string]::IsNullOrWhiteSpace([string]$candidatePath)) {
      continue
    }

    try {
      Remove-Item -LiteralPath $candidatePath -Recurse -Force -ErrorAction Stop
      $removedPaths.Add($candidatePath) | Out-Null
    } catch {
      $failedPaths.Add($candidatePath) | Out-Null
    }
  }

  $warning = ''
  if ($failedPaths.Count -gt 0) {
    $warning = ("legacy Rayman residue cleanup incomplete; failed={0}" -f ($failedPaths -join ', '))
  }

  return [pscustomobject]@{
    schema = 'rayman.workspace.legacy_cleanup.v1'
    workspace_root = [string]$resolvedRoot
    removed_paths = @($removedPaths.ToArray())
    removed_count = [int]$removedPaths.Count
    failed_paths = @($failedPaths.ToArray())
    failed_count = [int]$failedPaths.Count
    warning = [string]$warning
  }
}

if ($NoMain) {
  return
}
