param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [string]$CommandName = '',
  [string[]]$InputArgs = @(),
  [int]$ExitCode = 0,
  [switch]$Quiet,
  [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
  . $commonPath
}
$workspaceStateGuardPath = Join-Path $PSScriptRoot 'workspace_state_guard.ps1'
if (Test-Path -LiteralPath $workspaceStateGuardPath -PathType Leaf) {
  . $workspaceStateGuardPath
}
$legacyCleanupPath = Join-Path $PSScriptRoot 'legacy_rayman_cleanup.ps1'
if (Test-Path -LiteralPath $legacyCleanupPath -PathType Leaf) {
  . $legacyCleanupPath -NoMain
}
$runtimeCleanupPath = Join-Path $PSScriptRoot 'runtime_cleanup.ps1'
if (Test-Path -LiteralPath $runtimeCleanupPath -PathType Leaf) {
  . $runtimeCleanupPath -NoMain
}

function Get-RaymanPostCommandHygieneReportPath {
  param([string]$WorkspaceRoot)

  return (Join-Path (Resolve-Path -LiteralPath $WorkspaceRoot).Path '.Rayman\runtime\post_command_hygiene.last.json')
}

function Write-RaymanPostCommandHygieneReport {
  param(
    [string]$WorkspaceRoot,
    [object]$Report
  )

  $reportPath = Get-RaymanPostCommandHygieneReportPath -WorkspaceRoot $WorkspaceRoot
  if (Get-Command Write-RaymanRuntimeCleanupJsonFile -ErrorAction SilentlyContinue) {
    Write-RaymanRuntimeCleanupJsonFile -Path $reportPath -Value $Report -Depth 10
  } else {
    $parent = Split-Path -Parent $reportPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $json = ($Report | ConvertTo-Json -Depth 10)
    [System.IO.File]::WriteAllText($reportPath, ($json.TrimEnd() + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  }
  return $reportPath
}

function Test-RaymanPostCommandHygieneEnabled {
  param([string]$WorkspaceRoot)

  if (Get-Command Get-RaymanWorkspaceEnvBool -ErrorAction SilentlyContinue) {
    return (Get-RaymanWorkspaceEnvBool -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_POST_COMMAND_HYGIENE_ENABLED' -Default $true)
  }

  $raw = [Environment]::GetEnvironmentVariable('RAYMAN_POST_COMMAND_HYGIENE_ENABLED')
  if ([string]::IsNullOrWhiteSpace([string]$raw)) {
    return $true
  }
  return ($raw -match '^(?i:true|1|yes|y|on)$')
}

function Test-RaymanPostCommandHygieneSkippedCommand {
  param([string]$CommandName)

  if ([string]::IsNullOrWhiteSpace([string]$CommandName)) {
    return $true
  }

  switch ($CommandName.Trim().ToLowerInvariant()) {
    'help' { return $true }
    'menu' { return $true }
    default { return $false }
  }
}

function Convert-RaymanPostCommandGitPath {
  param([string]$RawPath)

  $candidate = [string]$RawPath
  if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
    return ''
  }

  if ($candidate -match ' -> ') {
    $candidate = ($candidate -split ' -> ', 2)[1]
  }
  $candidate = $candidate.Trim()
  if ($candidate.StartsWith('"') -and $candidate.EndsWith('"') -and $candidate.Length -ge 2) {
    $candidate = $candidate.Substring(1, $candidate.Length - 2)
    $candidate = $candidate.Replace('\"', '"').Replace('\\\\', '\')
  }

  return ($candidate.Replace('\', '/').Trim())
}

function Get-RaymanPostCommandGitDirtyEntries {
  param([string]$WorkspaceRoot)

  $result = [ordered]@{
    available = $false
    inside_git = $false
    reason = 'unknown'
    entries = @()
  }

  $gitCmd = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $gitCmd -or [string]::IsNullOrWhiteSpace([string]$gitCmd.Source)) {
    $result.reason = 'git_not_found'
    return [pscustomobject]$result
  }
  $result.available = $true

  try {
    & $gitCmd.Source -C $WorkspaceRoot rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) {
      $result.reason = 'not_git_workspace'
      return [pscustomobject]$result
    }
    $result.inside_git = $true

    $statusLines = @(& $gitCmd.Source -C $WorkspaceRoot status --porcelain --untracked-files=all 2>$null)
    if ($LASTEXITCODE -ne 0) {
      $result.reason = 'git_status_failed'
      return [pscustomobject]$result
    }

    $entries = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($line in @($statusLines)) {
      $rawLine = [string]$line
      if ([string]::IsNullOrWhiteSpace([string]$rawLine)) {
        continue
      }
      $status = if ($rawLine.Length -ge 2) { $rawLine.Substring(0, 2) } else { $rawLine }
      $pathText = if ($rawLine.Length -gt 3) { $rawLine.Substring(3) } else { '' }
      $normalizedPath = Convert-RaymanPostCommandGitPath -RawPath $pathText
      if ([string]::IsNullOrWhiteSpace([string]$normalizedPath)) {
        continue
      }

      $key = $normalizedPath.ToLowerInvariant()
      if ($seen.ContainsKey($key)) {
        continue
      }
      $seen[$key] = $true
      $entries.Add([pscustomobject]@{
          status = $status
          path = $normalizedPath
        }) | Out-Null
    }

    $result.reason = 'ok'
    $result.entries = @($entries.ToArray())
    return [pscustomobject]$result
  } catch {
    $result.reason = ("exception:{0}" -f $_.Exception.Message)
    return [pscustomobject]$result
  }
}

function Get-RaymanPostCommandDirtyTreeAnalysis {
  param([string]$WorkspaceRoot)

  $status = Get-RaymanPostCommandGitDirtyEntries -WorkspaceRoot $WorkspaceRoot
  $analysis = [ordered]@{
    available = [bool]$status.available
    inside_git = [bool]$status.inside_git
    reason = [string]$status.reason
    total_count = 0
    rayman_count = 0
    source_rayman_count = 0
    advisory_count = 0
    non_rayman_count = 0
    rayman_paths = @()
    source_rayman_paths = @()
    advisory_paths = @()
    non_rayman_paths = @()
  }

  if (-not [bool]$status.available -or -not [bool]$status.inside_git) {
    return [pscustomobject]$analysis
  }

  $rules = $null
  if (Get-Command Get-RaymanScmTrackedNoiseRules -ErrorAction SilentlyContinue) {
    $rules = Get-RaymanScmTrackedNoiseRules -WorkspaceRoot $WorkspaceRoot
  }
  $workspaceKind = ''
  if (Get-Command Get-RaymanWorkspaceKind -ErrorAction SilentlyContinue) {
    $workspaceKind = [string](Get-RaymanWorkspaceKind -WorkspaceRoot $WorkspaceRoot)
  }

  $raymanPaths = New-Object System.Collections.Generic.List[string]
  $sourceRaymanPaths = New-Object System.Collections.Generic.List[string]
  $advisoryPaths = New-Object System.Collections.Generic.List[string]
  $businessPaths = New-Object System.Collections.Generic.List[string]

  function Test-RaymanSourceWorkspaceTrackedPath {
    param([string]$NormalizedPath)

    if ($workspaceKind -ne 'source' -or [string]::IsNullOrWhiteSpace([string]$NormalizedPath)) {
      return $false
    }

    $candidate = [string]$NormalizedPath
    foreach ($prefix in @(
        '.Rayman/',
        '.Rayman/.dist/',
        '.RaymanAgent/',
        '.github/agents/',
        '.github/skills/',
        '.github/prompts/',
        '.github/instructions/'
      )) {
      if ($candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
      }
    }

    return ($candidate -in @(
        'AGENTS.md',
        '.gitignore',
        'RaymanAgent.slnx',
        '.github/copilot-instructions.md',
        '.github/model-policy.md'
      ))
  }

  foreach ($entry in @($status.entries)) {
    $path = [string]$entry.path
    $matchedRayman = $false
    $matchedAdvisory = $false
    if ($null -ne $rules) {
      foreach ($rule in @($rules.RaymanManaged)) {
        if (Test-RaymanScmTrackedNoiseRuleMatch -NormalizedPath $path -Rule $rule) {
          $matchedRayman = $true
          break
        }
      }
      if (-not $matchedRayman) {
        foreach ($rule in @($rules.Advisory)) {
          if (Test-RaymanScmTrackedNoiseRuleMatch -NormalizedPath $path -Rule $rule) {
            $matchedAdvisory = $true
            break
          }
        }
      }
    }

    if ($matchedRayman) {
      $raymanPaths.Add($path) | Out-Null
    } elseif (Test-RaymanSourceWorkspaceTrackedPath -NormalizedPath $path) {
      $sourceRaymanPaths.Add($path) | Out-Null
    } elseif ($matchedAdvisory) {
      $advisoryPaths.Add($path) | Out-Null
    } else {
      $businessPaths.Add($path) | Out-Null
    }
  }

  $analysis.total_count = @($status.entries).Count
  $analysis.rayman_count = $raymanPaths.Count
  $analysis.source_rayman_count = $sourceRaymanPaths.Count
  $analysis.advisory_count = $advisoryPaths.Count
  $analysis.non_rayman_count = ($advisoryPaths.Count + $businessPaths.Count)
  $analysis.rayman_paths = @($raymanPaths.ToArray())
  $analysis.source_rayman_paths = @($sourceRaymanPaths.ToArray())
  $analysis.advisory_paths = @($advisoryPaths.ToArray())
  $analysis.non_rayman_paths = @($advisoryPaths.ToArray() + $businessPaths.ToArray())
  return [pscustomobject]$analysis
}

function Invoke-RaymanTrackedNoiseAutoFix {
  param(
    [string]$WorkspaceRoot,
    [object]$TrackedNoise
  )

  $result = [ordered]@{
    attempted = $false
    success = $false
    skipped_reason = ''
    fixed_roots = @()
    fixed_count = 0
    command = ''
    output_tail = @()
    error = ''
  }

  if ($null -eq $TrackedNoise) {
    $result.skipped_reason = 'no_analysis'
    return [pscustomobject]$result
  }
  if (-not [bool]$TrackedNoise.available -or -not [bool]$TrackedNoise.insideGit) {
    $result.skipped_reason = [string]$TrackedNoise.reason
    return [pscustomobject]$result
  }
  if ([bool]$TrackedNoise.allowTrackedRaymanAssets) {
    $result.skipped_reason = 'allowed_by_workspace_env'
    return [pscustomobject]$result
  }

  $roots = New-Object System.Collections.Generic.List[string]
  foreach ($candidate in @($TrackedNoise.raymanMatchedRoots | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
    if ([string]$candidate -match '[\*\?\[]') {
      foreach ($trackedPath in @($TrackedNoise.raymanTrackedPaths | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        if ($roots -notcontains $trackedPath) {
          $roots.Add($trackedPath) | Out-Null
        }
      }
      continue
    }

    if ($roots -notcontains $candidate) {
      $roots.Add($candidate) | Out-Null
    }
  }
  $roots = @($roots.ToArray())
  if ($roots.Count -le 0) {
    $result.skipped_reason = 'no_roots'
    return [pscustomobject]$result
  }

  $gitCmd = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $gitCmd -or [string]::IsNullOrWhiteSpace([string]$gitCmd.Source)) {
    $result.skipped_reason = 'git_not_found'
    return [pscustomobject]$result
  }

  $result.attempted = $true
  $result.fixed_roots = @($roots)
  $result.fixed_count = $roots.Count
  $result.command = Get-RaymanScmTrackedNoiseGitRmCommand -Paths $roots

  try {
    $output = @(& $gitCmd.Source -C $WorkspaceRoot rm -r --cached -- @($roots) 2>&1)
    $exitCode = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }
    $result.output_tail = @($output | ForEach-Object { [string]$_ } | Select-Object -Last 8)
    if ($exitCode -eq 0) {
      $result.success = $true
      return [pscustomobject]$result
    }

    $result.error = ("git_rm_cached_failed: exit={0}" -f $exitCode)
    return [pscustomobject]$result
  } catch {
    $result.error = $_.Exception.Message
    return [pscustomobject]$result
  }
}

function Invoke-RaymanPostCommandHygiene {
  param(
    [string]$WorkspaceRoot,
    [string]$CommandName = '',
    [string[]]$InputArgs = @(),
    [int]$ExitCode = 0,
    [switch]$Quiet
  )

  $resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $report = [ordered]@{
    schema = 'rayman.post_command_hygiene.v1'
    generated_at = (Get-Date).ToString('o')
    workspace_root = $resolvedWorkspaceRoot
    command_name = [string]$CommandName
    input_args = @($InputArgs | ForEach-Object { [string]$_ })
    exit_code = [int]$ExitCode
    quiet = [bool]$Quiet
    enabled = $true
    skipped = $false
    skip_reason = ''
    workspace_state_guard = $null
    legacy_cleanup = $null
    cleanup = $null
    tracked_noise = $null
    dirty_tree = $null
    warning_emitted = $false
    warnings = @()
  }

  if (-not (Test-RaymanPostCommandHygieneEnabled -WorkspaceRoot $resolvedWorkspaceRoot)) {
    $report.enabled = $false
    $report.skipped = $true
    $report.skip_reason = 'disabled'
    $reportPath = Write-RaymanPostCommandHygieneReport -WorkspaceRoot $resolvedWorkspaceRoot -Report ([pscustomobject]$report)
    $report['report_path'] = $reportPath
    return [pscustomobject]$report
  }

  if (Test-RaymanPostCommandHygieneSkippedCommand -CommandName $CommandName) {
    $report.skipped = $true
    $report.skip_reason = 'no_op_command'
    $reportPath = Write-RaymanPostCommandHygieneReport -WorkspaceRoot $resolvedWorkspaceRoot -Report ([pscustomobject]$report)
    $report['report_path'] = $reportPath
    return [pscustomobject]$report
  }

  $warnings = New-Object System.Collections.Generic.List[string]

  try {
    if (Get-Command Invoke-RaymanWorkspaceStateGuard -ErrorAction SilentlyContinue) {
      $report.workspace_state_guard = Invoke-RaymanWorkspaceStateGuard -WorkspaceRoot $resolvedWorkspaceRoot
    }
  } catch {
    $warning = ("workspace_state_guard failed: {0}" -f $_.Exception.Message)
    $warnings.Add($warning) | Out-Null
    $report.workspace_state_guard = [pscustomobject]@{
      error = $warning
    }
  }

  try {
    if (Get-Command Invoke-RaymanLegacyWorkspaceCleanup -ErrorAction SilentlyContinue) {
      $report.legacy_cleanup = Invoke-RaymanLegacyWorkspaceCleanup -WorkspaceRoot $resolvedWorkspaceRoot
    }
  } catch {
    $warning = ("legacy_cleanup failed: {0}" -f $_.Exception.Message)
    $warnings.Add($warning) | Out-Null
    $report.legacy_cleanup = [pscustomobject]@{
      error = $warning
    }
  }

  try {
    if (Get-Command Invoke-RaymanRuntimeCleanup -ErrorAction SilentlyContinue) {
      $report.cleanup = Invoke-RaymanRuntimeCleanup -WorkspaceRoot $resolvedWorkspaceRoot -Mode 'post-command' -KeepDays 0 -WriteSummary
    }
  } catch {
    $warning = ("runtime_cleanup failed: {0}" -f $_.Exception.Message)
    $warnings.Add($warning) | Out-Null
    $report.cleanup = [pscustomobject]@{
      error = $warning
    }
  }

  $trackedNoiseBefore = $null
  $trackedNoiseAfter = $null
  $autoFix = [pscustomobject]@{
    attempted = $false
    success = $false
    skipped_reason = ''
    fixed_roots = @()
    fixed_count = 0
    command = ''
    output_tail = @()
    error = ''
  }

  try {
    if (Get-Command Get-RaymanScmTrackedNoiseAnalysis -ErrorAction SilentlyContinue) {
      $trackedNoiseBefore = Get-RaymanScmTrackedNoiseAnalysis -WorkspaceRoot $resolvedWorkspaceRoot
      $autoFix = Invoke-RaymanTrackedNoiseAutoFix -WorkspaceRoot $resolvedWorkspaceRoot -TrackedNoise $trackedNoiseBefore
      $trackedNoiseAfter = Get-RaymanScmTrackedNoiseAnalysis -WorkspaceRoot $resolvedWorkspaceRoot
    }
  } catch {
    $warning = ("tracked_noise analysis failed: {0}" -f $_.Exception.Message)
    $warnings.Add($warning) | Out-Null
    if (-not [string]::IsNullOrWhiteSpace([string]$autoFix.error)) {
      $autoFix.error = ("{0}; {1}" -f [string]$autoFix.error, $_.Exception.Message)
    } else {
      $autoFix.error = $_.Exception.Message
    }
  }

  $report.tracked_noise = [pscustomobject]@{
    before = if ($null -ne $trackedNoiseBefore) {
      [pscustomobject]@{
        status = [string]$trackedNoiseBefore.status
        reason = [string]$trackedNoiseBefore.reason
        allow_tracked_rayman_assets = [bool]$trackedNoiseBefore.allowTrackedRaymanAssets
        rayman_tracked_count = [int]$trackedNoiseBefore.raymanTrackedCount
        advisory_tracked_count = [int]$trackedNoiseBefore.advisoryTrackedCount
        rayman_command = [string]$trackedNoiseBefore.raymanCommand
      }
    } else {
      $null
    }
    auto_fix = $autoFix
    after = if ($null -ne $trackedNoiseAfter) {
      [pscustomobject]@{
        status = [string]$trackedNoiseAfter.status
        reason = [string]$trackedNoiseAfter.reason
        allow_tracked_rayman_assets = [bool]$trackedNoiseAfter.allowTrackedRaymanAssets
        rayman_tracked_count = [int]$trackedNoiseAfter.raymanTrackedCount
        advisory_tracked_count = [int]$trackedNoiseAfter.advisoryTrackedCount
        rayman_command = [string]$trackedNoiseAfter.raymanCommand
      }
    } else {
      $null
    }
  }

  try {
    $report.dirty_tree = Get-RaymanPostCommandDirtyTreeAnalysis -WorkspaceRoot $resolvedWorkspaceRoot
  } catch {
    $warning = ("dirty_tree analysis failed: {0}" -f $_.Exception.Message)
    $warnings.Add($warning) | Out-Null
    $report.dirty_tree = [pscustomobject]@{
      available = $false
      inside_git = $false
      reason = $warning
      total_count = 0
      rayman_count = 0
      source_rayman_count = 0
      advisory_count = 0
      non_rayman_count = 0
      rayman_paths = @()
      source_rayman_paths = @()
      advisory_paths = @()
      non_rayman_paths = @()
    }
  }

  if ($null -ne $report.dirty_tree -and [int]$report.dirty_tree.non_rayman_count -gt 0) {
    $warnings.Add(("remaining non-Rayman dirty tree: {0}" -f ((@($report.dirty_tree.non_rayman_paths | Select-Object -First 5)) -join ', '))) | Out-Null
  }
  if ($null -ne $report.cleanup -and $report.cleanup.PSObject.Properties['failed_count'] -and [int]$report.cleanup.failed_count -gt 0) {
    $warnings.Add(("post-command cleanup failed_count={0}" -f [int]$report.cleanup.failed_count)) | Out-Null
  }
  if ($autoFix.PSObject.Properties['attempted'] -and [bool]$autoFix.attempted -and -not [bool]$autoFix.success) {
    $warnings.Add(("tracked-noise auto-fix failed: {0}" -f [string]$autoFix.error)) | Out-Null
  }

  $report.warning_emitted = (-not $Quiet -and $null -ne $report.dirty_tree -and [int]$report.dirty_tree.non_rayman_count -gt 0)
  $report.warnings = @($warnings.ToArray())
  $reportPath = Write-RaymanPostCommandHygieneReport -WorkspaceRoot $resolvedWorkspaceRoot -Report ([pscustomobject]$report)
  $report['report_path'] = $reportPath

  if (-not $Quiet) {
    if ($autoFix.PSObject.Properties['attempted'] -and [bool]$autoFix.attempted -and [bool]$autoFix.success -and [int]$autoFix.fixed_count -gt 0) {
      Write-Host ("🧹 [hygiene] 已自动解除 Git 跟踪的 Rayman 生成资产: {0}" -f ((@($autoFix.fixed_roots | Select-Object -First 5)) -join ', ')) -ForegroundColor DarkCyan
    }
    if ($null -ne $report.dirty_tree -and [int]$report.dirty_tree.non_rayman_count -gt 0) {
      Write-Host ("⚠️  [hygiene] 当前仍有非 Rayman 脏树: count={0}; samples={1}; report={2}" -f [int]$report.dirty_tree.non_rayman_count, ((@($report.dirty_tree.non_rayman_paths | Select-Object -First 5)) -join ', '), $reportPath) -ForegroundColor Yellow
    }
    if ($autoFix.PSObject.Properties['attempted'] -and [bool]$autoFix.attempted -and -not [bool]$autoFix.success -and -not [string]::IsNullOrWhiteSpace([string]$autoFix.error)) {
      Write-Host ("⚠️  [hygiene] Rayman 跟踪噪声自动修复失败: {0}" -f [string]$autoFix.error) -ForegroundColor Yellow
    }
  }

  return [pscustomobject]$report
}

if (-not $NoMain) {
  Invoke-RaymanPostCommandHygiene -WorkspaceRoot $WorkspaceRoot -CommandName $CommandName -InputArgs $InputArgs -ExitCode $ExitCode -Quiet:$Quiet | ConvertTo-Json -Depth 10
}
