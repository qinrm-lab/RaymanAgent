param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-GuardPathComparisonValue {
  param(
    [string]$PathValue
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
  $candidate = [string]$PathValue
  if ($candidate.StartsWith('Microsoft.PowerShell.Core\FileSystem::', [System.StringComparison]::OrdinalIgnoreCase)) {
    $candidate = $candidate.Substring('Microsoft.PowerShell.Core\FileSystem::'.Length)
  }
  try {
    $full = [System.IO.Path]::GetFullPath($candidate)
  } catch {
    $full = $candidate
  }
  return ($full.TrimEnd('\', '/') -replace '\\', '/').ToLowerInvariant()
}

function Read-GuardJsonOrNull {
  param(
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Write-GuardJson {
  param(
    [string]$Path,
    [object]$Payload
  )

  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }

  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, ($Payload | ConvertTo-Json -Depth 8), $encoding)
}

function Get-WorkspaceMarkerPath {
  param(
    [string]$WorkspaceRoot
  )

  return (Join-Path $WorkspaceRoot '.Rayman\runtime\workspace.marker.json')
}

function Get-WorkspaceVersion {
  param(
    [string]$WorkspaceRoot
  )

  $versionPath = Join-Path $WorkspaceRoot '.Rayman\VERSION'
  if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
    return ''
  }

  try {
    return ([string](Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8)).Trim()
  } catch {
    return ''
  }
}

function Get-WorkspaceProbeFiles {
  param(
    [string]$WorkspaceRoot
  )

  return @(
    (Get-WorkspaceMarkerPath -WorkspaceRoot $WorkspaceRoot),
    (Join-Path $WorkspaceRoot '.Rayman\runtime\agent_capabilities.report.json'),
    (Join-Path $WorkspaceRoot '.Rayman\runtime\dotnet.exec.last.json'),
    (Join-Path $WorkspaceRoot '.Rayman\runtime\playwright.ready.windows.json'),
    (Join-Path $WorkspaceRoot '.Rayman\runtime\winapp.ready.windows.json'),
    (Join-Path $WorkspaceRoot '.Rayman\runtime\test_lanes\host_smoke.report.json'),
    (Join-Path $WorkspaceRoot '.Rayman\runtime\test_lanes\fast_contract.report.json'),
    (Join-Path $WorkspaceRoot '.Rayman\runtime\project_gates\fast.report.json'),
    (Join-Path $WorkspaceRoot '.Rayman\runtime\project_gates\browser.report.json')
  ) | Select-Object -Unique
}

function Get-WorkspaceMismatchEvidence {
  param(
    [string]$WorkspaceRoot
  )

  $workspaceNorm = Get-GuardPathComparisonValue -PathValue $WorkspaceRoot
  foreach ($path in @(Get-WorkspaceProbeFiles -WorkspaceRoot $WorkspaceRoot)) {
    $report = Read-GuardJsonOrNull -Path $path
    if ($null -eq $report) { continue }
    $prop = $report.PSObject.Properties['workspace_root']
    if ($null -eq $prop -or [string]::IsNullOrWhiteSpace([string]$prop.Value)) { continue }

    $reportRoot = [string]$prop.Value
    $reportNorm = Get-GuardPathComparisonValue -PathValue $reportRoot
    if ([string]::IsNullOrWhiteSpace($reportNorm) -or $reportNorm -eq $workspaceNorm) { continue }

    $source = if ((Get-WorkspaceMarkerPath -WorkspaceRoot $WorkspaceRoot) -eq $path) { 'marker' } else { 'report' }
    return [pscustomobject]@{
      detected = $true
      source = $source
      evidence_path = $path
      foreign_workspace_root = $reportRoot
    }
  }

  return [pscustomobject]@{
    detected = $false
    source = ''
    evidence_path = ''
    foreign_workspace_root = ''
  }
}

function Get-ScrubCandidates {
  param(
    [string]$WorkspaceRoot
  )

  $candidates = New-Object 'System.Collections.Generic.List[string]'

  function Add-Candidate {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not $candidates.Contains($Path)) {
      $candidates.Add($Path) | Out-Null
    }
  }

  function Add-DirectoryChildren {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
      return
    }

    foreach ($entry in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
      Add-Candidate -Path $entry.FullName
    }
  }

  foreach ($path in @(
    (Join-Path $WorkspaceRoot '.Rayman\logs'),
    (Join-Path $WorkspaceRoot '.Rayman\runtime\test_lanes'),
    (Join-Path $WorkspaceRoot '.Rayman\runtime\project_gates'),
    (Join-Path $WorkspaceRoot '.Rayman\runtime\mcp'),
    (Join-Path $WorkspaceRoot '.Rayman\runtime\pwa-tests'),
    (Join-Path $WorkspaceRoot '.Rayman\runtime\winapp-tests')
  )) {
    Add-Candidate -Path $path
  }

  $runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime'
  if (Test-Path -LiteralPath $runtimeDir -PathType Container) {
    foreach ($entry in @(Get-ChildItem -LiteralPath $runtimeDir -Recurse -File -Filter '*ready*.json' -ErrorAction SilentlyContinue)) {
      Add-Candidate -Path $entry.FullName
    }
    foreach ($entry in @(Get-ChildItem -LiteralPath $runtimeDir -File -Filter 'agent_capabilities.report.*' -ErrorAction SilentlyContinue)) {
      Add-Candidate -Path $entry.FullName
    }
    Add-Candidate -Path (Join-Path $runtimeDir 'dotnet.exec.last.json')
    Add-Candidate -Path (Join-Path $runtimeDir 'proxy.resolved.json')
  }

  $stateDir = Join-Path $WorkspaceRoot '.Rayman\state'
  if (Test-Path -LiteralPath $stateDir -PathType Container) {
    foreach ($pattern in @('release_gate_report.*', 'diagnostics_*', 'last_*', '*.state.json')) {
      foreach ($entry in @(Get-ChildItem -LiteralPath $stateDir -File -Filter $pattern -ErrorAction SilentlyContinue)) {
        Add-Candidate -Path $entry.FullName
      }
    }
    Add-Candidate -Path (Join-Path $stateDir ('chroma' + '_db'))
    Add-Candidate -Path (Join-Path $stateDir ('rag' + '.db'))
    Add-DirectoryChildren -Path (Join-Path $stateDir 'memory')
  }

  Add-Candidate -Path (Join-Path $WorkspaceRoot ('.' + 'rag'))
  Add-Candidate -Path (Join-Path $runtimeDir 'memory')

  return @($candidates.ToArray())
}

function Write-WorkspaceMarker {
  param(
    [string]$WorkspaceRoot
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $markerPath = Get-WorkspaceMarkerPath -WorkspaceRoot $resolvedRoot
  $payload = [pscustomobject]@{
    schema = 'rayman.workspace.marker.v1'
    workspace_root = $resolvedRoot
    written_at = (Get-Date).ToString('o')
    rayman_version = Get-WorkspaceVersion -WorkspaceRoot $resolvedRoot
  }
  Write-GuardJson -Path $markerPath -Payload $payload
  return $markerPath
}

function Invoke-RaymanWorkspaceStateGuard {
  param(
    [string]$WorkspaceRoot
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $evidence = Get-WorkspaceMismatchEvidence -WorkspaceRoot $resolvedRoot
  $removed = New-Object 'System.Collections.Generic.List[string]'

  if ([bool]$evidence.detected) {
    foreach ($candidate in @(Get-ScrubCandidates -WorkspaceRoot $resolvedRoot)) {
      try {
        Remove-Item -LiteralPath $candidate -Recurse -Force -ErrorAction Stop
        $removed.Add($candidate) | Out-Null
      } catch {}
    }
  }

  $markerPath = Write-WorkspaceMarker -WorkspaceRoot $resolvedRoot
  return [pscustomobject]@{
    schema = 'rayman.workspace.state.guard.v1'
    workspace_root = $resolvedRoot
    scrubbed = [bool]$evidence.detected
    reason = $(if ([bool]$evidence.detected) { 'foreign_workspace_state' } else { 'workspace_state_current' })
    evidence_source = [string]$evidence.source
    evidence_path = [string]$evidence.evidence_path
    foreign_workspace_root = [string]$evidence.foreign_workspace_root
    removed_count = $removed.Count
    removed_paths = @($removed.ToArray())
    marker_path = $markerPath
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  $result = Invoke-RaymanWorkspaceStateGuard -WorkspaceRoot $WorkspaceRoot
  if ($Json) {
    $result | ConvertTo-Json -Depth 8
  } else {
    if ([bool]$result.scrubbed) {
      Write-Host ("[workspace-state] detected cross-workspace copy from {0}; removed={1}" -f [string]$result.foreign_workspace_root, [int]$result.removed_count) -ForegroundColor Yellow
    } else {
      Write-Host ("[workspace-state] current workspace marker refreshed: {0}" -f [string]$result.marker_path) -ForegroundColor DarkCyan
    }
  }
}
