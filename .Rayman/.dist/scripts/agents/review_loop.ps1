param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [string]$TaskKind = 'review',
  [string]$Task = '',
  [string]$PromptKey = '',
  [string]$PreferredBackend = '',
  [switch]$PolicyBypass,
  [string]$BypassReason = '',
  [int]$MaxRounds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
  throw "common.ps1 not found: $commonPath"
}
. $commonPath

$agenticHelperPath = Join-Path $PSScriptRoot 'agentic_pipeline.ps1'
if (Test-Path -LiteralPath $agenticHelperPath -PathType Leaf) {
  . $agenticHelperPath
}

$memoryHelperPath = Join-Path $PSScriptRoot '..\memory\memory_common.ps1'
if (Test-Path -LiteralPath $memoryHelperPath -PathType Leaf) {
  . $memoryHelperPath
}

function Ensure-Dir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Get-EnvIntCompat([string]$Name, [int]$Default, [int]$Min = 1, [int]$Max = 20) {
  $raw = [Environment]::GetEnvironmentVariable($Name)
  $parsed = 0
  if (-not [string]::IsNullOrWhiteSpace($raw) -and [int]::TryParse($raw, [ref]$parsed)) {
    if ($parsed -lt $Min) { return $Min }
    if ($parsed -gt $Max) { return $Max }
    return $parsed
  }
  return $Default
}

function Get-JsonOrNull([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Resolve-PromptTemplateKey {
  param(
    [string]$WorkspaceRoot,
    [string]$PromptKeyText
  )

  $normalizedPromptKey = ([string]$PromptKeyText).Trim()
  if ([string]::IsNullOrWhiteSpace($normalizedPromptKey)) { return '' }

  $promptDir = Join-Path $WorkspaceRoot '.github\prompts'
  if (-not (Test-Path -LiteralPath $promptDir -PathType Container)) {
    return $normalizedPromptKey
  }

  $candidates = @(Get-ChildItem -LiteralPath $promptDir -Filter '*.prompt.md' -File -ErrorAction SilentlyContinue)
  foreach ($candidate in $candidates) {
    if ($candidate.Name.Equals($normalizedPromptKey, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $candidate.Name
    }
    if ($candidate.BaseName.Equals($normalizedPromptKey, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $candidate.Name
    }
  }

  return $normalizedPromptKey
}

function Get-PropValue([object]$Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  $prop = $Object.PSObject.Properties[$Name]
  if ($null -eq $prop) { return $Default }
  return $prop.Value
}

function Convert-ToStringArray([object]$Value) {
  if ($null -eq $Value) { return @() }
  $list = New-Object System.Collections.Generic.List[string]
  foreach ($item in @($Value)) {
    $s = [string]$item
    if (-not [string]::IsNullOrWhiteSpace($s)) { $list.Add($s.Trim()) | Out-Null }
  }
  return @($list)
}

function Get-ReviewPromptKey {
  param(
    [string]$WorkspaceRoot,
    [object]$ModelRoutingConfig,
    [string]$ExplicitPromptKey,
    [int]$RoundNumber
  )

  if (-not [string]::IsNullOrWhiteSpace([string]$ExplicitPromptKey)) {
    return Resolve-PromptTemplateKey -WorkspaceRoot $WorkspaceRoot -PromptKeyText $ExplicitPromptKey
  }
  if ($null -eq $ModelRoutingConfig) { return '' }
  $tasks = Get-PropValue -Object $ModelRoutingConfig -Name 'tasks' -Default $null
  $reviewTask = Get-PropValue -Object $tasks -Name 'review' -Default $null
  $promptKeys = @(Convert-ToStringArray -Value (Get-PropValue -Object $reviewTask -Name 'prompt_keys' -Default $null))
  if ($promptKeys.Count -eq 0) { return '' }
  $index = ($RoundNumber - 1) % $promptKeys.Count
  if ($index -lt 0) { $index = 0 }
  return Resolve-PromptTemplateKey -WorkspaceRoot $WorkspaceRoot -PromptKeyText ([string]$promptKeys[$index])
}

function Write-LoopLog([string]$Path, [string]$Message) {
  try {
    Add-Content -LiteralPath $Path -Encoding UTF8 -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message)
  } catch {}
}

function Get-FileHashCompat([string]$Path) {
  $cmd = Get-Command Get-FileHash -ErrorAction SilentlyContinue
  if ($null -ne $cmd) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash
  }

  $alg = [System.Security.Cryptography.HashAlgorithm]::Create('SHA1')
  if ($null -eq $alg) { return '' }
  $stream = [System.IO.File]::OpenRead($Path)
  try {
    $bytes = $alg.ComputeHash($stream)
  } finally {
    try { $stream.Dispose() } catch {}
    try { $alg.Dispose() } catch {}
  }
  return ([System.BitConverter]::ToString($bytes)).Replace('-', '')
}

function Get-RelativePathNorm([string]$BasePath, [string]$Path) {
  $baseNorm = [string]$BasePath
  $pathNorm = [string]$Path
  if ([string]::IsNullOrWhiteSpace($baseNorm) -or [string]::IsNullOrWhiteSpace($pathNorm)) { return '' }
  $baseNorm = $baseNorm.Replace('\', '/').TrimEnd('/')
  $pathNorm = $pathNorm.Replace('\', '/')
  $prefix = "$baseNorm/"
  if ($pathNorm.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $pathNorm.Substring($prefix.Length)
  }
  return [System.IO.Path]::GetFileName($pathNorm)
}

function Test-IgnoreRelativePath([string]$RelativePath, [string[]]$IgnorePrefixes) {
  if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $true }
  $rel = $RelativePath.Replace('\', '/').TrimStart('./')
  foreach ($raw in $IgnorePrefixes) {
    $p = [string]$raw
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    $pn = $p.Replace('\', '/').Trim().TrimStart('./').TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($pn)) { continue }
    if ($pn.EndsWith('*')) {
      $prefix = $pn.Substring(0, $pn.Length - 1)
      if ($rel.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
      continue
    }
    if ($rel.Equals($pn, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($rel.StartsWith("$pn/", [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

function Get-TextLineCountSafe([string]$Path, [string[]]$TextExtensions, [int64]$MaxSizeBytes = 2097152) {
  try {
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($TextExtensions -notcontains $ext) { return -1 }
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ([int64]$item.Length -gt $MaxSizeBytes) { return -1 }
    return @((Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)).Count
  } catch {
    return -1
  }
}

function Get-WorkspaceSnapshot {
  param(
    [string]$Root,
    [string[]]$IgnorePrefixes,
    [string[]]$TextExtensions
  )

  $map = @{}
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $map }
  $queue = New-Object System.Collections.Generic.Queue[string]
  $queue.Enqueue($Root)
  $scannedFiles = 0
  $maxScannedFiles = 8000

  while ($queue.Count -gt 0) {
    $current = $queue.Dequeue()
    $entries = Get-ChildItem -LiteralPath $current -Force -ErrorAction SilentlyContinue
    foreach ($entry in $entries) {
      $rel = Get-RelativePathNorm -BasePath $Root -Path $entry.FullName
      if ($entry.PSIsContainer) {
        if (Test-IgnoreRelativePath -RelativePath $rel -IgnorePrefixes $IgnorePrefixes) { continue }
        if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $queue.Enqueue($entry.FullName)
        continue
      }

      if (Test-IgnoreRelativePath -RelativePath $rel -IgnorePrefixes $IgnorePrefixes) { continue }
      $signature = "{0}|{1}" -f [int64]$entry.Length, [int64]$entry.LastWriteTimeUtc.Ticks
      $map[$rel] = [pscustomobject]@{
        path = $rel
        signature = $signature
        size_bytes = [int64]$entry.Length
        line_count = -1
      }

      $scannedFiles++
      if ($scannedFiles -ge $maxScannedFiles) {
        return $map
      }
    }
  }
  return $map
}

function Get-SnapshotDiffSummary {
  param(
    [hashtable]$Before,
    [hashtable]$After,
    [int]$MaxFiles = 40
  )

  if ($null -eq $Before) { $Before = @{} }
  if ($null -eq $After) { $After = @{} }
  if ($MaxFiles -lt 1) { $MaxFiles = 1 }

  $beforeKeys = @($Before.Keys)
  $afterKeys = @($After.Keys)
  $allKeys = @($beforeKeys + $afterKeys | Sort-Object -Unique)

  $items = New-Object System.Collections.Generic.List[object]
  $modified = 0
  $added = 0
  $deleted = 0
  $netLineDelta = 0
  $netSizeDeltaBytes = [int64]0
  $unknownLineDeltaFiles = 0

  foreach ($k in $allKeys) {
    $beforeItem = $null
    $afterItem = $null
    if ($Before.ContainsKey($k)) { $beforeItem = $Before[$k] }
    if ($After.ContainsKey($k)) { $afterItem = $After[$k] }

    $change = ''
    if ($null -eq $beforeItem -and $null -ne $afterItem) {
      $change = 'added'
      $added++
    } elseif ($null -ne $beforeItem -and $null -eq $afterItem) {
      $change = 'deleted'
      $deleted++
    } elseif ([string]$beforeItem.signature -ne [string]$afterItem.signature) {
      $change = 'modified'
      $modified++
    } else {
      continue
    }

    $oldLines = if ($null -eq $beforeItem) { $null } else { [int]$beforeItem.line_count }
    $newLines = if ($null -eq $afterItem) { $null } else { [int]$afterItem.line_count }
    $oldSizeBytes = if ($null -eq $beforeItem) { [int64]0 } else { [int64]$beforeItem.size_bytes }
    $newSizeBytes = if ($null -eq $afterItem) { [int64]0 } else { [int64]$afterItem.size_bytes }
    $netSizeDeltaBytes += ($newSizeBytes - $oldSizeBytes)
    $lineDelta = $null
    if ($null -ne $oldLines -and $null -ne $newLines -and $oldLines -ge 0 -and $newLines -ge 0) {
      $lineDelta = [int]($newLines - $oldLines)
      $netLineDelta += $lineDelta
    } elseif ($null -eq $oldLines -and $null -ne $newLines -and $newLines -ge 0) {
      $lineDelta = [int]$newLines
      $netLineDelta += $lineDelta
    } elseif ($null -ne $oldLines -and $oldLines -ge 0 -and $null -eq $newLines) {
      $lineDelta = [int](-1 * $oldLines)
      $netLineDelta += $lineDelta
    } else {
      $unknownLineDeltaFiles++
    }

    $items.Add([pscustomobject]@{
      path = [string]$k
      change = $change
      line_delta = $lineDelta
      old_lines = $oldLines
      new_lines = $newLines
      old_size_bytes = if ($null -eq $beforeItem) { $null } else { $oldSizeBytes }
      new_size_bytes = if ($null -eq $afterItem) { $null } else { $newSizeBytes }
    }) | Out-Null
  }

  $orderedItems = @($items | Sort-Object path)
  $sample = @($orderedItems | Select-Object -First $MaxFiles)
  $touched = $orderedItems.Count

  return [pscustomobject]@{
    method = 'file_hash_line_count'
    touched_files_count = $touched
    modified_files_count = $modified
    added_files_count = $added
    deleted_files_count = $deleted
    net_line_delta = $netLineDelta
    net_size_delta_bytes = $netSizeDeltaBytes
    unknown_line_delta_files = $unknownLineDeltaFiles
    max_files = $MaxFiles
    truncated = ($touched -gt $MaxFiles)
    files = @($sample)
  }
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$raymanDir = Join-Path $WorkspaceRoot '.Rayman'
$runtimeDir = Join-Path $raymanDir 'runtime'
$telemetryDir = Join-Path $runtimeDir 'telemetry'
$stateDir = Join-Path $raymanDir 'state'
$logsDir = Join-Path $raymanDir 'logs'
Ensure-Dir -Path $runtimeDir
Ensure-Dir -Path $telemetryDir
Ensure-Dir -Path $stateDir
Ensure-Dir -Path $logsDir

$runId = [Guid]::NewGuid().ToString('n')
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$detailLogPath = Join-Path $logsDir ("review.loop.{0}.log" -f $timestamp)
$summaryPath = Join-Path $runtimeDir 'review_loop.last.json'
$diffReportPath = Join-Path $runtimeDir 'review_loop.last.diff.md'
$firstPassTsv = Join-Path $telemetryDir 'first_pass_runs.tsv'
$dispatchLastPath = Join-Path $runtimeDir 'agent_runs\last.json'
$startedAt = Get-Date
$memoryTaskKey = if (Get-Command Get-RaymanMemoryTaskKey -ErrorAction SilentlyContinue) {
  Get-RaymanMemoryTaskKey -TaskKind $TaskKind -Task $Task -PromptKey $PromptKey -WorkspaceRoot $WorkspaceRoot
} else {
  ''
}

$dispatchScript = Join-Path $raymanDir 'scripts\agents\dispatch.ps1'
$testFixScript = Join-Path $raymanDir 'scripts\repair\run_tests_and_fix.ps1'
$reviewConfigPath = Join-Path $raymanDir 'config\review_loop.json'
$policyConfigPath = Join-Path $raymanDir 'config\agent_policy.json'
$modelRoutingPath = Join-Path $raymanDir 'config\model_routing.json'
$reviewConfig = Get-JsonOrNull -Path $reviewConfigPath
$policyConfig = Get-JsonOrNull -Path $policyConfigPath
$modelRoutingConfig = Get-JsonOrNull -Path $modelRoutingPath
$agenticConfigInfo = $null
$agenticConfig = $null
$agenticEnabled = $false
if (Get-Command Get-RaymanAgenticPipelineConfig -ErrorAction SilentlyContinue) {
  $agenticConfigInfo = Get-RaymanAgenticPipelineConfig -WorkspaceRoot $WorkspaceRoot
  $agenticConfig = $agenticConfigInfo.data
  $agenticEnabled = (-not [string]::Equals([string](Get-RaymanAgenticPropValue -Object $agenticConfig -Name 'active_pipeline' -Default 'planner_v1'), [string](Get-RaymanAgenticPropValue -Object $agenticConfig -Name 'legacy_pipeline_name' -Default 'legacy'), [System.StringComparison]::OrdinalIgnoreCase))
  if ($agenticEnabled) {
    Ensure-RaymanAgenticArtifacts -WorkspaceRoot $WorkspaceRoot | Out-Null
  }
}

if ($MaxRounds -le 0) {
  if ($null -ne $reviewConfig -and $null -ne $reviewConfig.PSObject.Properties['max_rounds']) {
    $MaxRounds = [int]$reviewConfig.max_rounds
  } else {
    $MaxRounds = Get-EnvIntCompat -Name 'RAYMAN_REVIEW_LOOP_MAX_ROUNDS' -Default 2 -Min 1 -Max 10
  }
}
if ($MaxRounds -lt 1) { $MaxRounds = 1 }
if ($MaxRounds -gt 10) { $MaxRounds = 10 }

$policyBypassRequested = $PolicyBypass.IsPresent
if (-not $policyBypassRequested) {
  $rawPolicyBypass = [Environment]::GetEnvironmentVariable('RAYMAN_AGENT_POLICY_BYPASS')
  if (-not [string]::IsNullOrWhiteSpace($rawPolicyBypass)) {
    if ($rawPolicyBypass -ne '0' -and $rawPolicyBypass -ne 'false' -and $rawPolicyBypass -ne 'False') {
      $policyBypassRequested = $true
    }
  }
}
$effectiveBypassReason = [string]$BypassReason
if ([string]::IsNullOrWhiteSpace($effectiveBypassReason)) {
  $effectiveBypassReason = [string][Environment]::GetEnvironmentVariable('RAYMAN_BYPASS_REASON')
}
if (-not [string]::IsNullOrWhiteSpace($effectiveBypassReason)) {
  $effectiveBypassReason = $effectiveBypassReason.Trim()
}

$requiredAssetAnalysis = Get-RaymanRequiredAssetAnalysis -WorkspaceRoot $WorkspaceRoot -Label 'review-loop-preflight' -RequiredRelPaths @(
  '.Rayman/scripts/agents/dispatch.ps1',
  '.Rayman/scripts/repair/run_tests_and_fix.ps1',
  '.Rayman/scripts/utils/request_attention.ps1',
  '.Rayman/scripts/utils/generate_context.ps1',
  '.Rayman/scripts/agents/prompts_catalog.ps1'
)
if (-not [bool]$requiredAssetAnalysis.ok) {
  Write-RaymanRequiredAssetDiagnostics -Analysis $requiredAssetAnalysis -Scope 'review-loop' -LogPath $detailLogPath
  $failedAt = Get-Date
  $preflightDurationMs = [int][Math]::Max(0, [Math]::Round(($failedAt - $startedAt).TotalMilliseconds))
  $preflightSummary = @{
    schema = 'rayman.review_loop.v1'
    run_id = $runId
    workspace_root = $WorkspaceRoot
    task_kind = $TaskKind
    task = $Task
    prompt_key = $PromptKey
    preferred_backend = $PreferredBackend
    policy_bypass_requested = $policyBypassRequested
    policy_bypass_reason = $effectiveBypassReason
    max_rounds = $MaxRounds
    started_at = $startedAt.ToString('o')
    finished_at = $failedAt.ToString('o')
    duration_ms = $preflightDurationMs
    success = $false
    first_pass = $false
    final_exit_code = 11
    final_error_kind = 'missing_required_assets'
    blocked_before_round1 = $true
    required_assets = $requiredAssetAnalysis
    rounds = @()
    diff_summary_enabled = $false
    diff_max_files = 0
    diff_ignore_dirs = @()
    diff_report = $diffReportPath
    detail_log = $detailLogPath
    first_pass_telemetry = $firstPassTsv
  }
  ($preflightSummary | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $summaryPath -Encoding UTF8
  try {
    Write-RaymanRulesTelemetryRecord -WorkspaceRoot $WorkspaceRoot -RunId $runId -Profile 'review-loop' -Stage 'preflight' -Scope $TaskKind -Status 'FAIL' -ExitCode 11 -DurationMs $preflightDurationMs -Command 'review-loop' | Out-Null
  } catch {}
  Write-Host ("❌ [review-loop] preflight failed: {0}" -f (Format-RaymanRequiredAssetSummary -Analysis $requiredAssetAnalysis)) -ForegroundColor Red
  exit 11
}

$requiredLogsOnFailure = @('.Rayman/state/last_error.log')
if ($null -ne $policyConfig -and $null -ne $policyConfig.hooks -and $null -ne $policyConfig.hooks.post_tool -and $null -ne $policyConfig.hooks.post_tool.required_logs_on_failure) {
  $tmp = @($policyConfig.hooks.post_tool.required_logs_on_failure | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($tmp.Count -gt 0) { $requiredLogsOnFailure = $tmp }
}

$diffSummaryEnabled = $true
$diffMaxFiles = 40
$diffIgnorePrefixes = @(
  '.git',
  '.Rayman/runtime',
  '.Rayman/logs',
  '.Rayman/state',
  '.Rayman/.dist',
  'node_modules',
  '.venv',
  'bin',
  'obj',
  '.Rayman_full_for_copy',
  'Rayman_full_bundle',
  '.tmp_sandbox_*',
  '.rayman.stage.*'
)
$diffTextExtensions = @('.ps1', '.psm1', '.psd1', '.sh', '.bash', '.zsh', '.cmd', '.bat', '.json', '.md', '.txt', '.yml', '.yaml', '.xml', '.toml', '.ini', '.env', '.cs', '.csproj', '.sln', '.py', '.js', '.jsx', '.ts', '.tsx', '.html', '.css', '.scss', '.sql')

if ($null -ne $reviewConfig -and $null -ne $reviewConfig.PSObject.Properties['diff_summary']) {
  $ds = $reviewConfig.diff_summary
  if ($null -ne $ds -and $null -ne $ds.PSObject.Properties['enabled']) {
    $diffSummaryEnabled = [bool]$ds.enabled
  }
  if ($null -ne $ds -and $null -ne $ds.PSObject.Properties['max_files']) {
    $parsed = 0
    if ([int]::TryParse([string]$ds.max_files, [ref]$parsed)) {
      if ($parsed -lt 1) { $parsed = 1 }
      if ($parsed -gt 200) { $parsed = 200 }
      $diffMaxFiles = $parsed
    }
  }
  if ($null -ne $ds -and $null -ne $ds.PSObject.Properties['ignore_dirs']) {
    $tmpIgnore = @($ds.ignore_dirs | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($tmpIgnore.Count -gt 0) { $diffIgnorePrefixes = @($diffIgnorePrefixes + $tmpIgnore | Select-Object -Unique) }
  }
}

if ($agenticEnabled -and (Get-Command Get-RaymanAgenticArtifactPaths -ErrorAction SilentlyContinue)) {
  $agenticPaths = Get-RaymanAgenticArtifactPaths -WorkspaceRoot $WorkspaceRoot
  $agenticIgnorePrefix = ('{0}/agentic' -f [string]$agenticPaths.solution_dir_name).Replace('\', '/')
  if (-not [string]::IsNullOrWhiteSpace($agenticIgnorePrefix)) {
    $diffIgnorePrefixes = @($diffIgnorePrefixes + $agenticIgnorePrefix | Select-Object -Unique)
  }
}

Write-LoopLog -Path $detailLogPath -Message ("review-loop start run_id={0} task_kind={1} max_rounds={2}" -f $runId, $TaskKind, $MaxRounds)
if ($diffSummaryEnabled) {
  Write-LoopLog -Path $detailLogPath -Message ("diff-summary enabled max_files={0}" -f $diffMaxFiles)
}

$rounds = New-Object System.Collections.Generic.List[object]
$success = $false
$firstPass = $false
$finalExitCode = 1
$finalErrorKind = 'unknown'
$round1Backend = 'local'
$agenticPlan = $null
$agenticToolPolicy = $null
$agenticReflection = $null
$agenticSelectedTools = @()
$agenticFallbackCount = 0
$agenticAcceptanceClosed = $false
$agenticDocGatePass = $false
$replanCount = 0
$snapshotBeforeRound = $null
if ($diffSummaryEnabled) {
  $snapshotBeforeRound = Get-WorkspaceSnapshot -Root $WorkspaceRoot -IgnorePrefixes $diffIgnorePrefixes -TextExtensions $diffTextExtensions
}

for ($round = 1; $round -le $MaxRounds; $round++) {
  $roundBackend = 'local'
  $roundDispatchReason = ''
  $roundPromptKey = ''
  $roundModelSource = ''
  $roundModelSelector = ''
  $roundResolvedModel = ''
  $dispatchExit = 0
  $roundPolicyBypassed = $false
  $roundPolicyBypassReason = ''
  $roundPolicyBlockedReason = ''
  $roundDiffSummary = $null

  if (Test-Path -LiteralPath $dispatchScript -PathType Leaf) {
    if ($TaskKind -eq 'review') {
      $roundPromptKey = Get-ReviewPromptKey -WorkspaceRoot $WorkspaceRoot -ModelRoutingConfig $modelRoutingConfig -ExplicitPromptKey $PromptKey -RoundNumber $round
    } elseif (-not [string]::IsNullOrWhiteSpace($PromptKey)) {
      $roundPromptKey = $PromptKey.Trim()
    }

    $dispatchParams = @{
      WorkspaceRoot = $WorkspaceRoot
      TaskKind = $TaskKind
      Task = $Task
      DryRun = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($roundPromptKey)) {
      $dispatchParams['PromptKey'] = $roundPromptKey
    }
    if ($round -eq 1 -and -not [string]::IsNullOrWhiteSpace($PreferredBackend)) {
      $dispatchParams['PreferredBackend'] = $PreferredBackend
    }
    if ($policyBypassRequested) {
      $dispatchParams['PolicyBypass'] = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($effectiveBypassReason)) {
      $dispatchParams['BypassReason'] = $effectiveBypassReason
    }
    & $dispatchScript @dispatchParams | Out-Host
    $dispatchExit = [int]$LASTEXITCODE
    if (Test-Path -LiteralPath $dispatchLastPath -PathType Leaf) {
      $dispatchObj = Get-JsonOrNull -Path $dispatchLastPath
      if ($null -ne $dispatchObj) {
        if ($null -ne $dispatchObj.PSObject.Properties['selected_backend']) {
          $roundBackend = [string]$dispatchObj.selected_backend
        }
        if ($null -ne $dispatchObj.PSObject.Properties['selection_reason']) {
          $roundDispatchReason = [string]$dispatchObj.selection_reason
        }
        if ($null -ne $dispatchObj.PSObject.Properties['prompt_key']) {
          $roundPromptKey = [string]$dispatchObj.prompt_key
        }
        if ($null -ne $dispatchObj.PSObject.Properties['model_resolution_source']) {
          $roundModelSource = [string]$dispatchObj.model_resolution_source
        }
        if ($null -ne $dispatchObj.PSObject.Properties['selected_model_selector']) {
          $roundModelSelector = [string]$dispatchObj.selected_model_selector
        }
        if ($null -ne $dispatchObj.PSObject.Properties['resolved_model']) {
          $roundResolvedModel = [string]$dispatchObj.resolved_model
        }
        if ($null -ne $dispatchObj.PSObject.Properties['policy_bypassed']) {
          $roundPolicyBypassed = [bool]$dispatchObj.policy_bypassed
        }
        if ($null -ne $dispatchObj.PSObject.Properties['policy_bypass_reason']) {
          $roundPolicyBypassReason = [string]$dispatchObj.policy_bypass_reason
        }
        if ($null -ne $dispatchObj.PSObject.Properties['policy_block_reason']) {
          $roundPolicyBlockedReason = [string]$dispatchObj.policy_block_reason
        }
        if ($agenticEnabled) {
          if ($null -ne $dispatchObj.PSObject.Properties['agentic_plan']) {
            $agenticPlan = $dispatchObj.agentic_plan
          }
          if ($null -ne $dispatchObj.PSObject.Properties['agentic_tool_policy']) {
            $agenticToolPolicy = $dispatchObj.agentic_tool_policy
          }
          if ($null -ne $dispatchObj.PSObject.Properties['selected_tools']) {
            $agenticSelectedTools = @($dispatchObj.selected_tools | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
          }
          if ($null -ne $dispatchObj.PSObject.Properties['fallback_count']) {
            $agenticFallbackCount = [int]$dispatchObj.fallback_count
          }
        }
      }
    }
  }

  if ($round -eq 1) {
    $round1Backend = $roundBackend
  }

  if ($dispatchExit -ne 0 -and $roundBackend -eq 'blocked') {
    $finalExitCode = $dispatchExit
    if ($agenticEnabled -and (Get-Command Resolve-RaymanDispatchBlockedErrorKind -ErrorAction SilentlyContinue) -and $null -ne $dispatchObj) {
      $finalErrorKind = Resolve-RaymanDispatchBlockedErrorKind -DispatchSummary $dispatchObj
    } elseif (-not [string]::IsNullOrWhiteSpace($roundDispatchReason)) {
      $finalErrorKind = $roundDispatchReason
    } else {
      $finalErrorKind = 'dispatch_policy_blocked'
    }
    if ($diffSummaryEnabled) {
      $snapshotAfterRound = Get-WorkspaceSnapshot -Root $WorkspaceRoot -IgnorePrefixes $diffIgnorePrefixes -TextExtensions $diffTextExtensions
      $roundDiffSummary = Get-SnapshotDiffSummary -Before $snapshotBeforeRound -After $snapshotAfterRound -MaxFiles $diffMaxFiles
      $snapshotBeforeRound = $snapshotAfterRound
    }
    $roundReflectionOutcome = ''
    $roundDocGatePass = $false
    $roundAcceptanceClosed = $false
    if ($agenticEnabled -and $null -ne $agenticPlan -and $null -ne $agenticToolPolicy) {
      $reflectionWriteStarted = Get-Date
      $provisionalReflection = New-RaymanReflection -WorkspaceRoot $WorkspaceRoot -ConfigData $agenticConfig -TaskKind $TaskKind -Task $Task -Plan $agenticPlan -ToolPolicy $agenticToolPolicy -Round $round -MaxRounds $MaxRounds -TestExit $dispatchExit -ErrorKind $finalErrorKind -PolicyOk $false -DiffSummary $roundDiffSummary -FallbackCount $agenticFallbackCount -ReplanCount $replanCount -DocGate ([pscustomobject]@{ pass = $true })
      Write-RaymanReflectionArtifacts -WorkspaceRoot $WorkspaceRoot -Reflection $provisionalReflection | Out-Null
      $roundDocGate = Test-RaymanAgenticDocGate -WorkspaceRoot $WorkspaceRoot -ConfigData $agenticConfig -Stage 'review_loop' -UpdatedAfter $reflectionWriteStarted -UpdatedDocNames @('reflection.current.md', 'reflection.current.json')
      $agenticReflection = New-RaymanReflection -WorkspaceRoot $WorkspaceRoot -ConfigData $agenticConfig -TaskKind $TaskKind -Task $Task -Plan $agenticPlan -ToolPolicy $agenticToolPolicy -Round $round -MaxRounds $MaxRounds -TestExit $dispatchExit -ErrorKind $finalErrorKind -PolicyOk $false -DiffSummary $roundDiffSummary -FallbackCount $agenticFallbackCount -ReplanCount $replanCount -DocGate $roundDocGate
      Write-RaymanReflectionArtifacts -WorkspaceRoot $WorkspaceRoot -Reflection $agenticReflection | Out-Null
      $roundReflectionOutcome = [string]$agenticReflection.outcome
      $roundDocGatePass = [bool]$agenticReflection.doc_gate_pass
      $roundAcceptanceClosed = [bool]$agenticReflection.acceptance_closed
      $agenticDocGatePass = $roundDocGatePass
      $agenticAcceptanceClosed = $roundAcceptanceClosed
    }
    $rounds.Add([pscustomobject]@{
      round = $round
      backend = $roundBackend
      prompt_key = $roundPromptKey
      model_source = $roundModelSource
      model_selector = $roundModelSelector
      resolved_model = $roundResolvedModel
      dispatch_reason = $roundDispatchReason
      dispatch_exit = $dispatchExit
      test_exit = $null
      error_kind = $finalErrorKind
      policy_ok = $false
      policy_bypassed = $roundPolicyBypassed
      policy_bypass_reason = $roundPolicyBypassReason
      policy_block_reason = $roundPolicyBlockedReason
      plan_id = if ($null -ne $agenticPlan) { [string]$agenticPlan.plan_id } else { '' }
      selected_tools = @($agenticSelectedTools)
      fallback_count = $agenticFallbackCount
      replan_count = $replanCount
      reflection_outcome = $roundReflectionOutcome
      doc_gate_pass = $roundDocGatePass
      acceptance_closed = $roundAcceptanceClosed
      diff_summary = $roundDiffSummary
    }) | Out-Null
    if (Get-Command Write-RaymanEpisodeMemory -ErrorAction SilentlyContinue) {
      Write-RaymanEpisodeMemory -WorkspaceRoot $WorkspaceRoot -RunId $runId -TaskKey $memoryTaskKey -TaskKind $TaskKind -Stage 'review_round' -Round $round -Success $false -ErrorKind $finalErrorKind -SelectedTools @($agenticSelectedTools) -DiffSummary $roundDiffSummary -ArtifactRefs @($detailLogPath, $dispatchLastPath) -SummaryText ("dispatch blocked: {0}" -f [string]$finalErrorKind) -ExtraPayload @{
        backend = $roundBackend
        dispatch_exit = $dispatchExit
        policy_ok = $false
      } | Out-Null
    }
    Write-LoopLog -Path $detailLogPath -Message ("round={0} blocked by dispatch: {1}" -f $round, $finalErrorKind)
    break
  }

  $testExit = 1
  $testException = ''
  $prevMemoryRunId = [Environment]::GetEnvironmentVariable('RAYMAN_MEMORY_RUN_ID')
  $prevMemoryTaskKey = [Environment]::GetEnvironmentVariable('RAYMAN_MEMORY_TASK_KEY')
  $prevMemoryTaskKind = [Environment]::GetEnvironmentVariable('RAYMAN_MEMORY_TASK_KIND')
  $prevMemoryRound = [Environment]::GetEnvironmentVariable('RAYMAN_MEMORY_ROUND')
  $env:RAYMAN_MEMORY_RUN_ID = $runId
  $env:RAYMAN_MEMORY_TASK_KEY = $memoryTaskKey
  $env:RAYMAN_MEMORY_TASK_KIND = $TaskKind
  $env:RAYMAN_MEMORY_ROUND = [string]$round
  try {
    & $testFixScript | Out-Host
    $testExit = [int]$LASTEXITCODE
  } catch {
    $testExit = 1
    $testException = $_.Exception.Message
    Write-LoopLog -Path $detailLogPath -Message ("round={0} test-fix exception={1}" -f $round, $_.Exception.Message)
  } finally {
    $env:RAYMAN_MEMORY_RUN_ID = $prevMemoryRunId
    $env:RAYMAN_MEMORY_TASK_KEY = $prevMemoryTaskKey
    $env:RAYMAN_MEMORY_TASK_KIND = $prevMemoryTaskKind
    $env:RAYMAN_MEMORY_ROUND = $prevMemoryRound
  }
  $policyOk = $true
  $errorKind = 'ok'

  if ($testExit -ne 0) {
    $missingLogs = New-Object System.Collections.Generic.List[string]
    foreach ($rel in $requiredLogsOnFailure) {
      $p = Join-Path $WorkspaceRoot $rel
      if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        $missingLogs.Add($rel) | Out-Null
      }
    }
    if ($missingLogs.Count -gt 0) {
      $policyOk = $false
      $errorKind = ("missing_required_logs:{0}" -f ($missingLogs -join ','))
    } elseif (-not [string]::IsNullOrWhiteSpace($testException)) {
      $errorKind = ("test_fix_exception:{0}" -f $testException)
    } else {
      $errLog = Join-Path $stateDir 'last_error.log'
      if (Test-Path -LiteralPath $errLog -PathType Leaf) {
        try {
          $line = Get-Content -LiteralPath $errLog -Encoding UTF8 -ErrorAction Stop | Select-Object -First 1
          if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
            $errorKind = ([string]$line).Trim()
          } else {
            $errorKind = 'test_fix_failed'
          }
        } catch {
          $errorKind = 'test_fix_failed'
        }
      } else {
        $errorKind = 'test_fix_failed'
      }
    }
  }

  if ($diffSummaryEnabled) {
    $snapshotAfterRound = Get-WorkspaceSnapshot -Root $WorkspaceRoot -IgnorePrefixes $diffIgnorePrefixes -TextExtensions $diffTextExtensions
    $roundDiffSummary = Get-SnapshotDiffSummary -Before $snapshotBeforeRound -After $snapshotAfterRound -MaxFiles $diffMaxFiles
    $snapshotBeforeRound = $snapshotAfterRound
    Write-LoopLog -Path $detailLogPath -Message ("round={0} diff touched={1} modified={2} added={3} deleted={4}" -f $round, $roundDiffSummary.touched_files_count, $roundDiffSummary.modified_files_count, $roundDiffSummary.added_files_count, $roundDiffSummary.deleted_files_count)
  }

  $roundReflectionOutcome = ''
  $roundDocGatePass = $false
  $roundAcceptanceClosed = $false
  if ($agenticEnabled -and $null -ne $agenticPlan -and $null -ne $agenticToolPolicy) {
    $reflectionWriteStarted = Get-Date
    $provisionalReflection = New-RaymanReflection -WorkspaceRoot $WorkspaceRoot -ConfigData $agenticConfig -TaskKind $TaskKind -Task $Task -Plan $agenticPlan -ToolPolicy $agenticToolPolicy -Round $round -MaxRounds $MaxRounds -TestExit $testExit -ErrorKind $errorKind -PolicyOk $policyOk -DiffSummary $roundDiffSummary -FallbackCount $agenticFallbackCount -ReplanCount $replanCount -DocGate ([pscustomobject]@{ pass = $true })
    Write-RaymanReflectionArtifacts -WorkspaceRoot $WorkspaceRoot -Reflection $provisionalReflection | Out-Null
    $roundDocGate = Test-RaymanAgenticDocGate -WorkspaceRoot $WorkspaceRoot -ConfigData $agenticConfig -Stage 'review_loop' -UpdatedAfter $reflectionWriteStarted -UpdatedDocNames @('reflection.current.md', 'reflection.current.json')
    $agenticReflection = New-RaymanReflection -WorkspaceRoot $WorkspaceRoot -ConfigData $agenticConfig -TaskKind $TaskKind -Task $Task -Plan $agenticPlan -ToolPolicy $agenticToolPolicy -Round $round -MaxRounds $MaxRounds -TestExit $testExit -ErrorKind $errorKind -PolicyOk $policyOk -DiffSummary $roundDiffSummary -FallbackCount $agenticFallbackCount -ReplanCount $replanCount -DocGate $roundDocGate
    Write-RaymanReflectionArtifacts -WorkspaceRoot $WorkspaceRoot -Reflection $agenticReflection | Out-Null
    $roundReflectionOutcome = [string]$agenticReflection.outcome
    $roundDocGatePass = [bool]$agenticReflection.doc_gate_pass
    $roundAcceptanceClosed = [bool]$agenticReflection.acceptance_closed
    $agenticDocGatePass = $roundDocGatePass
    $agenticAcceptanceClosed = $roundAcceptanceClosed
    if ($roundReflectionOutcome -eq 'replan') {
      $replanCount++
    }
  }

  $rounds.Add([pscustomobject]@{
    round = $round
    backend = $roundBackend
    prompt_key = $roundPromptKey
    model_source = $roundModelSource
    model_selector = $roundModelSelector
    resolved_model = $roundResolvedModel
    dispatch_reason = $roundDispatchReason
    dispatch_exit = $dispatchExit
    test_exit = $testExit
    error_kind = $errorKind
    policy_ok = $policyOk
    policy_bypassed = $roundPolicyBypassed
    policy_bypass_reason = $roundPolicyBypassReason
    policy_block_reason = $roundPolicyBlockedReason
    plan_id = if ($null -ne $agenticPlan) { [string]$agenticPlan.plan_id } else { '' }
    selected_tools = @($agenticSelectedTools)
    fallback_count = $agenticFallbackCount
    replan_count = $replanCount
    reflection_outcome = $roundReflectionOutcome
    doc_gate_pass = $roundDocGatePass
    acceptance_closed = $roundAcceptanceClosed
    diff_summary = $roundDiffSummary
  }) | Out-Null
  if (Get-Command Write-RaymanEpisodeMemory -ErrorAction SilentlyContinue) {
    Write-RaymanEpisodeMemory -WorkspaceRoot $WorkspaceRoot -RunId $runId -TaskKey $memoryTaskKey -TaskKind $TaskKind -Stage 'review_round' -Round $round -Success $policyOk -ErrorKind $errorKind -SelectedTools @($agenticSelectedTools) -DiffSummary $roundDiffSummary -ArtifactRefs @($detailLogPath, $summaryPath) -SummaryText ("round {0}: backend={1}; test_exit={2}" -f $round, [string]$roundBackend, $testExit) -ExtraPayload @{
      backend = $roundBackend
      test_exit = $testExit
      policy_ok = $policyOk
      reflection_outcome = $roundReflectionOutcome
    } | Out-Null
  }

  Write-LoopLog -Path $detailLogPath -Message ("round={0} backend={1} test_exit={2} error_kind={3}" -f $round, $roundBackend, $testExit, $errorKind)

  if ($testExit -eq 0) {
    if ($agenticEnabled) {
      if ($roundReflectionOutcome -eq 'done') {
        $success = $true
        $finalExitCode = 0
        $finalErrorKind = 'ok'
        if ($round -eq 1) { $firstPass = $true }
        break
      }
      $success = $false
      $finalExitCode = 7
      $finalErrorKind = if ([string]::IsNullOrWhiteSpace($roundReflectionOutcome)) { 'agentic_reflection_failed' } else { ('reflection_{0}' -f $roundReflectionOutcome) }
      break
    } else {
      $success = $true
      $finalExitCode = 0
      $finalErrorKind = 'ok'
      if ($round -eq 1) { $firstPass = $true }
      break
    }
  }

  if ($agenticEnabled -and -not [string]::IsNullOrWhiteSpace($roundReflectionOutcome)) {
    $finalExitCode = $testExit
    $finalErrorKind = ('reflection_{0}' -f $roundReflectionOutcome)
  } else {
    $finalExitCode = $testExit
    $finalErrorKind = $errorKind
  }
}

$finishedAt = Get-Date
$durationMs = [int][Math]::Max(0, [Math]::Round(($finishedAt - $startedAt).TotalMilliseconds))

if ($success -and -not $firstPass) {
  $finalErrorKind = 'needs_multiple_rounds'
}

$summary = @{
  schema = 'rayman.review_loop.v1'
  run_id = $runId
  workspace_root = $WorkspaceRoot
  task_kind = $TaskKind
  memory_task_key = $memoryTaskKey
  task = $Task
  prompt_key = $PromptKey
  preferred_backend = $PreferredBackend
  policy_bypass_requested = $policyBypassRequested
  policy_bypass_reason = $effectiveBypassReason
  max_rounds = $MaxRounds
  started_at = $startedAt.ToString('o')
  finished_at = $finishedAt.ToString('o')
  duration_ms = $durationMs
  success = $success
  first_pass = $firstPass
  pipeline = if ($agenticEnabled) { [string](Get-RaymanAgenticPropValue -Object $agenticConfig -Name 'active_pipeline' -Default 'planner_v1') } else { 'legacy' }
  plan_id = if ($null -ne $agenticPlan) { [string]$agenticPlan.plan_id } else { '' }
  selected_tools = @($agenticSelectedTools)
  fallback_count = $agenticFallbackCount
  replan_count = $replanCount
  doc_gate_pass = $agenticDocGatePass
  acceptance_closed = $agenticAcceptanceClosed
  reflection_outcome = if ($null -ne $agenticReflection) { [string]$agenticReflection.outcome } else { '' }
  agentic_reflection = $agenticReflection
  final_exit_code = $finalExitCode
  final_error_kind = $finalErrorKind
  rounds = @($rounds.ToArray())
  diff_summary_enabled = $diffSummaryEnabled
  diff_max_files = $diffMaxFiles
  diff_ignore_dirs = @($diffIgnorePrefixes)
  diff_report = $diffReportPath
  detail_log = $detailLogPath
  first_pass_telemetry = $firstPassTsv
}

if ($diffSummaryEnabled) {
  $diffLines = New-Object System.Collections.Generic.List[string]
  $diffLines.Add('# Rayman Review Loop Diff Report') | Out-Null
  $diffLines.Add('') | Out-Null
  $diffLines.Add(("- run_id: {0}" -f $runId)) | Out-Null
  $diffLines.Add(("- generated_at: {0}" -f (Get-Date).ToString('o'))) | Out-Null
  $diffLines.Add(("- workspace_root: {0}" -f $WorkspaceRoot)) | Out-Null
  $diffLines.Add(("- max_files_per_round: {0}" -f $diffMaxFiles)) | Out-Null
  $diffLines.Add('') | Out-Null

  foreach ($roundObj in @($rounds.ToArray())) {
    $ds = $null
    if ($null -ne $roundObj.PSObject.Properties['diff_summary']) {
      $ds = $roundObj.diff_summary
    }
    $diffLines.Add(("## Round {0}" -f [int]$roundObj.round)) | Out-Null
    $diffLines.Add('') | Out-Null
    $diffLines.Add(("- backend: {0}" -f [string]$roundObj.backend)) | Out-Null
    $diffLines.Add(("- test_exit: {0}" -f [string]$roundObj.test_exit)) | Out-Null
    $diffLines.Add(("- error_kind: {0}" -f [string]$roundObj.error_kind)) | Out-Null
    if ($null -eq $ds) {
      $diffLines.Add('- diff: (disabled or unavailable)') | Out-Null
      $diffLines.Add('') | Out-Null
      continue
    }
    $diffLines.Add(("- touched_files: {0}" -f [int]$ds.touched_files_count)) | Out-Null
    $diffLines.Add(("- modified_files: {0}" -f [int]$ds.modified_files_count)) | Out-Null
    $diffLines.Add(("- added_files: {0}" -f [int]$ds.added_files_count)) | Out-Null
    $diffLines.Add(("- deleted_files: {0}" -f [int]$ds.deleted_files_count)) | Out-Null
    $diffLines.Add(("- net_line_delta: {0}" -f [int]$ds.net_line_delta)) | Out-Null
    $diffLines.Add(("- net_size_delta_bytes: {0}" -f [int64]$ds.net_size_delta_bytes)) | Out-Null
    if ([bool]$ds.truncated) {
      $diffLines.Add(("- note: files list truncated to {0}" -f [int]$ds.max_files)) | Out-Null
    }
    $diffLines.Add('') | Out-Null

    $files = @()
    if ($null -ne $ds.PSObject.Properties['files']) {
      $files = @($ds.files)
    }
    if ($files.Count -eq 0) {
      $diffLines.Add('- files: (none)') | Out-Null
      $diffLines.Add('') | Out-Null
      continue
    }
    $diffLines.Add('| change | file | line_delta |') | Out-Null
    $diffLines.Add('| --- | --- | ---: |') | Out-Null
    foreach ($it in $files) {
      $deltaText = if ($null -eq $it.line_delta) { 'n/a' } else { [string]$it.line_delta }
      $diffLines.Add(('| {0} | {1} | {2} |' -f [string]$it.change, [string]$it.path, $deltaText)) | Out-Null
    }
    $diffLines.Add('') | Out-Null
  }

  Set-Content -LiteralPath $diffReportPath -Encoding UTF8 -Value ($diffLines -join "`r`n")
}

($summary | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $summaryPath -Encoding UTF8

if (Get-Command Write-RaymanEpisodeMemory -ErrorAction SilentlyContinue) {
  $finalDiffSummary = $null
  if ($rounds.Count -gt 0) {
    $finalRoundObj = $rounds[$rounds.Count - 1]
    if ($null -ne $finalRoundObj.PSObject.Properties['diff_summary']) {
      $finalDiffSummary = $finalRoundObj.diff_summary
    }
  }
  Write-RaymanEpisodeMemory -WorkspaceRoot $WorkspaceRoot -RunId $runId -TaskKey $memoryTaskKey -TaskKind $TaskKind -Stage 'review_result' -Round $rounds.Count -Success $success -ErrorKind $finalErrorKind -DurationMs $durationMs -SelectedTools @($agenticSelectedTools) -DiffSummary $finalDiffSummary -ArtifactRefs @($summaryPath, $diffReportPath, $detailLogPath) -SummaryText ("review-loop result: success={0}; first_pass={1}; final_exit={2}" -f $success, $firstPass, $finalExitCode) -ExtraPayload @{
    first_pass = $firstPass
    final_exit_code = $finalExitCode
    reflection_outcome = if ($null -ne $agenticReflection) { [string]$agenticReflection.outcome } else { '' }
  } | Out-Null
  if (Get-Command Start-RaymanMemorySummarizer -ErrorAction SilentlyContinue) {
    Start-RaymanMemorySummarizer -WorkspaceRoot $WorkspaceRoot -TaskKey $memoryTaskKey -TaskKind $TaskKind -RunId $runId | Out-Null
  }
}

$_legacyFirstPassHeader = "ts_iso`trun_id`tprofile`tstage`tscope`tstatus`terror_kind`tduration_ms`tcommand"
$_previousFirstPassHeader = "ts_iso`trun_id`tprofile`tstage`tscope`tstatus`terror_kind`tduration_ms`tcommand`tround1_touched_files`tround1_net_line_delta`tround1_modified_files`tround1_added_files`tround1_deleted_files`tround1_net_size_delta_bytes"
$_firstPassHeader = "ts_iso`trun_id`tprofile`tstage`tscope`tstatus`terror_kind`tduration_ms`tcommand`tround1_touched_files`tround1_net_line_delta`tround1_modified_files`tround1_added_files`tround1_deleted_files`tround1_net_size_delta_bytes`tplan_id`treplan_count`tselected_tools`tfallback_count`tdoc_gate_pass`tacceptance_closed`treflection_outcome"
if (-not (Test-Path -LiteralPath $firstPassTsv -PathType Leaf)) {
  $_firstPassHeader | Set-Content -LiteralPath $firstPassTsv -Encoding UTF8
} else {
  try {
    $existing = @(Get-Content -LiteralPath $firstPassTsv -Encoding UTF8 -ErrorAction Stop)
    if ($existing.Count -gt 0 -and @($_legacyFirstPassHeader, $_previousFirstPassHeader) -contains [string]$existing[0]) {
      Set-Content -LiteralPath $firstPassTsv -Encoding UTF8 -Value $_firstPassHeader
      if ($existing.Count -gt 1) {
        Add-Content -LiteralPath $firstPassTsv -Encoding UTF8 -Value @($existing | Select-Object -Skip 1)
      }
    }
  } catch {}
}

$round1Touched = 0
$round1NetLineDelta = 0
$round1Modified = 0
$round1Added = 0
$round1Deleted = 0
$round1NetSizeDeltaBytes = 0
if ($rounds.Count -gt 0) {
  $round1 = $rounds[0]
  if ($null -ne $round1 -and $null -ne $round1.PSObject.Properties['diff_summary'] -and $null -ne $round1.diff_summary) {
    $ds = $round1.diff_summary
    if ($null -ne $ds.PSObject.Properties['touched_files_count']) { $round1Touched = [int]$ds.touched_files_count }
    if ($null -ne $ds.PSObject.Properties['net_line_delta']) { $round1NetLineDelta = [int]$ds.net_line_delta }
    if ($null -ne $ds.PSObject.Properties['modified_files_count']) { $round1Modified = [int]$ds.modified_files_count }
    if ($null -ne $ds.PSObject.Properties['added_files_count']) { $round1Added = [int]$ds.added_files_count }
    if ($null -ne $ds.PSObject.Properties['deleted_files_count']) { $round1Deleted = [int]$ds.deleted_files_count }
    if ($null -ne $ds.PSObject.Properties['net_size_delta_bytes']) { $round1NetSizeDeltaBytes = [int64]$ds.net_size_delta_bytes }
  }
}

$fpStatus = if ($firstPass) { 'OK' } else { 'FAIL' }
$fpErrorKindRaw = if ($firstPass) { 'ok' } else { [string]$finalErrorKind }
$fpErrorKind = ([string]$fpErrorKindRaw -replace "[`r`n`t]+", ' ').Trim()
if ([string]::IsNullOrWhiteSpace($fpErrorKind)) { $fpErrorKind = 'unknown' }
$fpSelectedTools = ($agenticSelectedTools | ForEach-Object { [string]$_ }) -join '|'
$fpDocGatePass = if ($agenticEnabled) { [string]$agenticDocGatePass.ToString().ToLowerInvariant() } else { 'true' }
$fpAcceptanceClosed = if ($agenticEnabled) { [string]$agenticAcceptanceClosed.ToString().ToLowerInvariant() } else { [string]$success.ToString().ToLowerInvariant() }
$fpReflectionOutcome = if ($agenticEnabled -and $null -ne $agenticReflection) { [string]$agenticReflection.outcome } else { '' }
$fpPlanId = if ($null -ne $agenticPlan) { [string]$agenticPlan.plan_id } else { '' }
$fpLine = "{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}`t{8}`t{9}`t{10}`t{11}`t{12}`t{13}`t{14}`t{15}`t{16}`t{17}`t{18}`t{19}`t{20}`t{21}" -f $finishedAt.ToString('o'), $runId, 'first-pass', $TaskKind, $round1Backend, $fpStatus, $fpErrorKind, $durationMs, 'review-loop', $round1Touched, $round1NetLineDelta, $round1Modified, $round1Added, $round1Deleted, $round1NetSizeDeltaBytes, $fpPlanId, $replanCount, $fpSelectedTools, $agenticFallbackCount, $fpDocGatePass, $fpAcceptanceClosed, $fpReflectionOutcome
Add-Content -LiteralPath $firstPassTsv -Encoding UTF8 -Value $fpLine
try {
  Write-RaymanRulesTelemetryRecord -WorkspaceRoot $WorkspaceRoot -RunId $runId -Profile 'review-loop' -Stage 'final' -Scope $TaskKind -Status $(if ($success) { 'OK' } else { 'FAIL' }) -ExitCode $finalExitCode -DurationMs $durationMs -Command 'review-loop' | Out-Null
} catch {}

Write-Host ("🧾 [review-loop] summary: {0}" -f $summaryPath) -ForegroundColor DarkCyan
Write-Host ("🧾 [review-loop] first-pass telemetry: {0}" -f $firstPassTsv) -ForegroundColor DarkCyan

if ($success) {
  Write-Host ("✅ [review-loop] success first_pass={0}" -f $firstPass) -ForegroundColor Green
  exit 0
}

Write-Host ("❌ [review-loop] failed after {0} rounds (error={1})" -f $MaxRounds, $finalErrorKind) -ForegroundColor Red
exit $finalExitCode
