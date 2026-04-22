Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ComparablePathText {
  param(
    [string]$PathValue
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
  $candidate = [string]$PathValue
  if ($candidate.StartsWith('Microsoft.PowerShell.Core\FileSystem::', [System.StringComparison]::OrdinalIgnoreCase)) {
    $candidate = $candidate.Substring('Microsoft.PowerShell.Core\FileSystem::'.Length)
  }
  $candidate = $candidate.Trim().Trim('"').Trim("'")
  if ($candidate -match '^/mnt/([A-Za-z])(?:/(.*))?$') {
    $drive = ([string]$Matches[1]).ToUpperInvariant()
    $rest = if ($Matches.Count -gt 2) { [string]$Matches[2] } else { '' }
    if ([string]::IsNullOrWhiteSpace($rest)) {
      $candidate = ('{0}:\' -f $drive)
    } else {
      $candidate = ('{0}:\{1}' -f $drive, ($rest -replace '/', '\'))
    }
  }
  if ($candidate -match '^[A-Za-z]:[\\/]') {
    return $candidate
  }
  try {
    return [System.IO.Path]::GetFullPath($candidate)
  } catch {
    return $candidate
  }
}

function Get-PathComparisonValue {
  param(
    [string]$PathValue
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
  $full = Resolve-ComparablePathText -PathValue $PathValue
  return ($full.TrimEnd('\', '/') -replace '\\', '/').ToLowerInvariant()
}

function Test-AbsolutePathText {
  param(
    [string]$PathValue
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) { return $false }
  if ($PathValue -match '^[A-Za-z]:[\\/]') { return $true }
  try {
    return [System.IO.Path]::IsPathRooted($PathValue)
  } catch {
    return $false
  }
}

function Get-DisplayRelativePath {
  param(
    [string]$BasePath,
    [string]$FullPath
  )

  if ([string]::IsNullOrWhiteSpace($FullPath)) { return '' }
  $baseRaw = [string]$BasePath
  $fullRaw = [string]$FullPath
  if ($baseRaw.StartsWith('Microsoft.PowerShell.Core\FileSystem::', [System.StringComparison]::OrdinalIgnoreCase)) {
    $baseRaw = $baseRaw.Substring('Microsoft.PowerShell.Core\FileSystem::'.Length)
  }
  if ($fullRaw.StartsWith('Microsoft.PowerShell.Core\FileSystem::', [System.StringComparison]::OrdinalIgnoreCase)) {
    $fullRaw = $fullRaw.Substring('Microsoft.PowerShell.Core\FileSystem::'.Length)
  }
  $baseFull = (Resolve-ComparablePathText -PathValue $baseRaw).TrimEnd('\', '/')
  $full = Resolve-ComparablePathText -PathValue $fullRaw
  $baseNorm = Get-PathComparisonValue -PathValue $baseFull
  $fullNorm = Get-PathComparisonValue -PathValue $full
  if ($fullNorm.StartsWith($baseNorm + '/')) {
    return ($full.Substring($baseFull.Length).TrimStart('\', '/') -replace '\\', '/')
  }
  return ($full -replace '\\', '/')
}

function Get-VersionTokenFromName {
  param(
    [string]$Name
  )

  if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
  $match = [regex]::Match($Name, '(?i)\bv\d+\b')
  if (-not $match.Success) { return '' }
  return $match.Value.ToLowerInvariant()
}

function Get-ReportWorkspaceRoot {
  param(
    [object]$Report
  )

  if ($null -eq $Report) { return '' }
  $prop = $Report.PSObject.Properties['workspace_root']
  if ($null -eq $prop -or [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
    return ''
  }
  return [string]$prop.Value
}

function Test-ReportWorkspaceRootMatch {
  param(
    [object]$Report,
    [string]$WorkspaceRoot
  )

  $reportRoot = Get-ReportWorkspaceRoot -Report $Report
  if ([string]::IsNullOrWhiteSpace($reportRoot)) {
    return $true
  }
  if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    return $false
  }
  return ((Get-PathComparisonValue -PathValue $reportRoot) -eq (Get-PathComparisonValue -PathValue $WorkspaceRoot))
}

function Get-ReportGeneratedAtUtc {
  param(
    [object]$Report
  )

  if ($null -eq $Report) { return $null }
  $prop = $Report.PSObject.Properties['generated_at']
  if ($null -eq $prop -or [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
    return $null
  }
  try {
    return ([datetimeoffset]::Parse([string]$prop.Value)).UtcDateTime
  } catch {
    return $null
  }
}

function Get-ReportFreshnessBaseline {
  param(
    [object]$Report,
    [string]$ReportPath = ''
  )

  $generatedAtUtc = Get-ReportGeneratedAtUtc -Report $Report
  if ($null -ne $generatedAtUtc) {
    return [pscustomobject]@{
      source = 'generated_at'
      timestamp_utc = $generatedAtUtc
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($ReportPath) -and (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
    return [pscustomobject]@{
      source = 'file_mtime'
      timestamp_utc = (Get-Item -LiteralPath $ReportPath).LastWriteTimeUtc
    }
  }

  return [pscustomobject]@{
    source = ''
    timestamp_utc = $null
  }
}

function Get-LatestFreshnessInput {
  param(
    [string]$WorkspaceRoot,
    [string[]]$Paths = @()
  )

  $latestTimestamp = $null
  $latestPath = ''
  if ($null -eq $Paths) {
    return [pscustomobject]@{
      path = ''
      timestamp_utc = $null
    }
  }

  foreach ($pathValue in @($Paths)) {
    if ([string]::IsNullOrWhiteSpace([string]$pathValue)) { continue }
    $candidate = [string]$pathValue
    if (-not (Test-AbsolutePathText -PathValue $candidate) -and -not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
      $candidate = Join-Path $WorkspaceRoot $candidate
    }

    $items = @()
    $hasWildcard = ($candidate.IndexOfAny(@([char]'*', [char]'?', [char]'[')) -ge 0)
    if ($hasWildcard) {
      $items = @(Get-ChildItem -Path $candidate -File -Force -ErrorAction SilentlyContinue)
    } elseif (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $items = @(Get-Item -LiteralPath $candidate -Force)
    } elseif (Test-Path -LiteralPath $candidate -PathType Container) {
      $items = @(Get-ChildItem -LiteralPath $candidate -Recurse -File -Force -ErrorAction SilentlyContinue)
    } else {
      continue
    }

    foreach ($item in $items) {
      if ($null -eq $item) { continue }
      $timestampUtc = $item.LastWriteTimeUtc
      if ($null -eq $latestTimestamp -or $timestampUtc -gt $latestTimestamp) {
        $latestTimestamp = $timestampUtc
        $latestPath = [string]$item.FullName
      }
    }
  }

  return [pscustomobject]@{
    path = $latestPath
    timestamp_utc = $latestTimestamp
  }
}

function Get-TestLaneReportEvaluation {
  param(
    [object]$Report,
    [string]$ExpectedSchema,
    [string]$SuccessProperty = 'success',
    [string]$OverallProperty = '',
    [string]$WorkspaceRoot = '',
    [string]$ReportPath = '',
    [string[]]$FreshnessPaths = @(),
    [switch]$RequireGeneratedAt
  )

  if ($null -eq $Report) {
    return [pscustomobject]@{
      status = 'INVALID'
      detail = 'report parse failed'
    }
  }

  $schemaText = ''
  if ($null -ne $Report.PSObject.Properties['schema'] -and $null -ne $Report.schema) {
    $schemaText = [string]$Report.schema
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedSchema) -and $schemaText -ne $ExpectedSchema) {
    return [pscustomobject]@{
      status = 'INVALID'
      detail = ("schema mismatch: actual={0}, expected={1}" -f $schemaText, $ExpectedSchema)
    }
  }

  if (-not (Test-ReportWorkspaceRootMatch -Report $Report -WorkspaceRoot $WorkspaceRoot)) {
    $reportRoot = Get-ReportWorkspaceRoot -Report $Report
    return [pscustomobject]@{
      status = 'STALE'
      detail = ("stale_report_workspace_mismatch:{0}" -f $reportRoot)
    }
  }

  $generatedAtRaw = ''
  if ($null -ne $Report.PSObject.Properties['generated_at'] -and $null -ne $Report.generated_at) {
    $generatedAtRaw = [string]$Report.generated_at
  }
  $generatedAtUtc = Get-ReportGeneratedAtUtc -Report $Report
  if ($RequireGeneratedAt) {
    if ([string]::IsNullOrWhiteSpace($generatedAtRaw)) {
      return [pscustomobject]@{
        status = 'STALE'
        detail = 'stale_report_missing_generated_at'
      }
    }
    if ($null -eq $generatedAtUtc) {
      return [pscustomobject]@{
        status = 'STALE'
        detail = ("stale_report_invalid_generated_at:{0}" -f $generatedAtRaw)
      }
    }
  }

  if ($null -ne $FreshnessPaths -and @($FreshnessPaths).Count -gt 0) {
    $baseline = Get-ReportFreshnessBaseline -Report $Report -ReportPath $ReportPath
    if ($null -eq $baseline.timestamp_utc) {
      return [pscustomobject]@{
        status = 'STALE'
        detail = 'stale_report_missing_freshness_timestamp'
      }
    }

    $latestInput = Get-LatestFreshnessInput -WorkspaceRoot $WorkspaceRoot -Paths $FreshnessPaths
    if ($null -ne $latestInput.timestamp_utc -and $latestInput.timestamp_utc -gt $baseline.timestamp_utc.AddSeconds(1)) {
      $latestInputPath = if ([string]::IsNullOrWhiteSpace([string]$latestInput.path)) {
        ''
      } else {
        Get-DisplayRelativePath -BasePath $WorkspaceRoot -FullPath ([string]$latestInput.path)
      }
      return [pscustomobject]@{
        status = 'STALE'
        detail = ("stale_report_older_than_inputs:{0}" -f $latestInputPath)
      }
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($OverallProperty)) {
    $overallProp = $Report.PSObject.Properties[$OverallProperty]
    if ($null -eq $overallProp -or [string]::IsNullOrWhiteSpace([string]$overallProp.Value)) {
      return [pscustomobject]@{
        status = 'INVALID'
        detail = ("missing overall property: {0}" -f $OverallProperty)
      }
    }

    $overallText = ([string]$overallProp.Value).Trim().ToUpperInvariant()
    if ($overallText -notin @('PASS', 'WARN', 'FAIL')) {
      return [pscustomobject]@{
        status = 'INVALID'
        detail = ("invalid overall value: {0}" -f [string]$overallProp.Value)
      }
    }

    return [pscustomobject]@{
      status = $overallText
      detail = ("overall={0}" -f $overallText)
    }
  }

  if ([string]::IsNullOrWhiteSpace($SuccessProperty)) {
    return [pscustomobject]@{
      status = 'INVALID'
      detail = 'no evaluation property configured'
    }
  }

  $successProp = $Report.PSObject.Properties[$SuccessProperty]
  if ($null -eq $successProp) {
    return [pscustomobject]@{
      status = 'INVALID'
      detail = ("missing success property: {0}" -f $SuccessProperty)
    }
  }

  try {
    $successValue = [bool][System.Management.Automation.LanguagePrimitives]::ConvertTo($successProp.Value, [bool])
  } catch {
    return [pscustomobject]@{
      status = 'INVALID'
      detail = ("invalid success value: {0}" -f [string]$successProp.Value)
    }
  }

  return [pscustomobject]@{
    status = $(if ($successValue) { 'PASS' } else { 'FAIL' })
    detail = ("{0}={1}" -f $SuccessProperty, $successValue.ToString().ToLowerInvariant())
  }
}

function Get-ReleaseGateScanIgnoreRules {
  return @(
    '/\.tmp_sandbox_',
    '/\.temp\/rayman-dynamic-sandbox(?:[^/]*)?(?:/|$)',
    '/\.rayman\.stage\.',
    '/\.rayman_full_',
    '/rayman_full_bundle/',
    '/\.venv/',
    '/\.git/',
    '/\.rayman/context\.md$',
    '/\.rayman/scripts/testing/',
    '/\.rayman/logs/',
    '/\.rayman/state/',
    '/\.rayman/runtime/',
    '/\.rayman/cache/',
    '/\.rayman/\.dist/scripts/testing/',
    '/\.rayman/\.dist/logs/',
    '/\.rayman/\.dist/state/',
    '/\.rayman/\.dist/runtime/',
    '/\.rayman/\.dist/cache/',
    '/\.rayman/scripts/release/release_gate\.ps1$',
    '/\.rayman/\.dist/scripts/release/release_gate\.ps1$'
  )
}

function Test-ReleaseGatePathIgnored {
  param(
    [string]$FullPath,
    [string[]]$Rules = @()
  )

  $fullNorm = Get-PathComparisonValue -PathValue $FullPath
  if ([string]::IsNullOrWhiteSpace($fullNorm)) {
    return $false
  }

  foreach ($rule in @($Rules)) {
    if ([string]::IsNullOrWhiteSpace([string]$rule)) {
      continue
    }
    if ($fullNorm -match [string]$rule) {
      return $true
    }
  }

  return $false
}

function Resolve-ReleaseGateShellHost {
  foreach ($candidate in @('pwsh.exe', 'pwsh', 'powershell.exe', 'powershell')) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
      return [string]$cmd.Source
    }
  }

  return $null
}

function Invoke-ReleaseGateLaneAutoRun {
  param(
    [string]$WorkspaceRoot,
    [string]$Action,
    [scriptblock]$Runner = $null
  )

  $commandText = [string]$Action
  if ([string]::IsNullOrWhiteSpace($commandText)) {
    return [pscustomobject]@{
      attempted = $false
      started = $false
      success = $false
      exit_code = 1
      reason = 'action_missing'
      command = ''
      output = ''
    }
  }

  if ($commandText.StartsWith('执行 ')) {
    $commandText = $commandText.Substring(3).Trim()
  } else {
    $commandText = $commandText.Trim()
  }

  if ([string]::IsNullOrWhiteSpace($commandText)) {
    return [pscustomobject]@{
      attempted = $false
      started = $false
      success = $false
      exit_code = 1
      reason = 'command_missing'
      command = ''
      output = ''
    }
  }

  $isWindowsHost = ($env:OS -eq 'Windows_NT')
  if (Get-Command Test-RaymanWindowsPlatform -ErrorAction SilentlyContinue) {
    $isWindowsHost = [bool](Test-RaymanWindowsPlatform)
  }
  if ($isWindowsHost -and $commandText -match '^\s*bash\s+(.+)$' -and (Get-Command Resolve-RaymanBashCommand -ErrorAction SilentlyContinue)) {
    $bashRunner = Resolve-RaymanBashCommand
    if (
      $null -ne $bashRunner -and
      -not [string]::IsNullOrWhiteSpace([string]$bashRunner.path) -and
      [string]$bashRunner.mode -ne 'wsl'
    ) {
      $bashArgs = [string]$matches[1].Trim()
      $escapedBashPath = ([string]$bashRunner.path).Replace("'", "''")
      $commandText = "& '$escapedBashPath' $bashArgs"
    }
  }

  if ($null -ne $Runner) {
    $result = & $Runner $commandText
    if ($null -ne $result) {
      return $result
    }
  }

  $shellHost = Resolve-ReleaseGateShellHost
  if ([string]::IsNullOrWhiteSpace($shellHost)) {
    return [pscustomobject]@{
      attempted = $true
      started = $false
      success = $false
      exit_code = 127
      reason = 'shell_host_missing'
      command = $commandText
      output = 'release-gate auto-run skipped: no PowerShell host found'
    }
  }

  if (Get-Command Invoke-RaymanNativeCommandCapture -ErrorAction SilentlyContinue) {
    $capture = Invoke-RaymanNativeCommandCapture -FilePath $shellHost -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $commandText) -WorkingDirectory $WorkspaceRoot
    return [pscustomobject]@{
      attempted = $true
      started = [bool]$capture.started
      success = [bool]$capture.success
      exit_code = [int]$capture.exit_code
      reason = if ([bool]$capture.started) { 'completed' } else { 'start_failed' }
      command = $commandText
      output = [string]$capture.output
    }
  }

  try {
    $original = Get-Location
    Set-Location -LiteralPath $WorkspaceRoot
    & $shellHost -NoProfile -ExecutionPolicy Bypass -Command $commandText
    $exitCode = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    return [pscustomobject]@{
      attempted = $true
      started = $true
      success = ($exitCode -eq 0)
      exit_code = $exitCode
      reason = 'completed'
      command = $commandText
      output = ''
    }
  } catch {
    return [pscustomobject]@{
      attempted = $true
      started = $true
      success = $false
      exit_code = 1
      reason = 'runtime_exception'
      command = $commandText
      output = [string]$_.Exception.Message
    }
  } finally {
    try { Set-Location -LiteralPath $original.Path } catch {}
  }
}
