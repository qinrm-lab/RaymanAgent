param(
  [ValidateSet('show', 'set')][string]$Action = 'show',
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [string]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\..\common.ps1')

function Write-ManageVersionInfo([string]$Message) {
  Write-Host ("[version] {0}" -f $Message)
}

function Fail-ManageVersion([string]$Message, [int]$ExitCode = 1) {
  Write-Host ("[version] ERROR: {0}" -f $Message) -ForegroundColor Red
  exit $ExitCode
}

function Write-RaymanUtf8NoBomFile {
  param(
    [string]$Path,
    [string]$Content
  )

  $dirPath = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dirPath) -and -not (Test-Path -LiteralPath $dirPath -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $dirPath | Out-Null
  }

  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Get-RaymanVersionTokenParts {
  param([string]$RawVersion)

  if ([string]::IsNullOrWhiteSpace($RawVersion)) {
    throw 'target version is required'
  }

  $match = [regex]::Match($RawVersion.Trim(), '^(?i)v(?<num>\d+)$')
  if (-not $match.Success) {
    throw ("invalid version token: {0}. expected vNNN or VNNN" -f $RawVersion)
  }

  $num = [string]$match.Groups['num'].Value
  return [pscustomobject]@{
    number = $num
    lower = ('v{0}' -f $num)
    upper = ('V{0}' -f $num)
  }
}

function Resolve-RaymanAgentsFilePath {
  param([string]$WorkspaceRoot)

  foreach ($candidate in @('AGENTS.md', 'agents.md')) {
    $path = Join-Path $WorkspaceRoot $candidate
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      return $path
    }
  }

  return (Join-Path $WorkspaceRoot 'AGENTS.md')
}

function Get-ManageVersionDisplayPath {
  param(
    [string]$BasePath,
    [string]$FullPath
  )

  if ([string]::IsNullOrWhiteSpace($FullPath)) {
    return ''
  }

  try {
    $baseFull = [System.IO.Path]::GetFullPath([string]$BasePath).TrimEnd('\', '/')
    $targetFull = [System.IO.Path]::GetFullPath([string]$FullPath)
    if ($targetFull.StartsWith($baseFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
      return $targetFull.Substring($baseFull.Length + 1).Replace('\', '/')
    }
  } catch {}

  return ([string]$FullPath).Replace('\', '/')
}

function Get-RaymanManagedVersionPaths {
  param([string]$WorkspaceRoot)

  $raymanRoot = Join-Path $WorkspaceRoot '.Rayman'
  $agentsPath = Resolve-RaymanAgentsFilePath -WorkspaceRoot $WorkspaceRoot
  return [pscustomobject]@{
    WorkspaceRoot = $WorkspaceRoot
    RaymanRoot = $raymanRoot
    Agents = $agentsPath
    AgentsTemplate = Join-Path $raymanRoot 'agents.template.md'
    Version = Join-Path $raymanRoot 'VERSION'
    DistVersion = Join-Path $raymanRoot '.dist\VERSION'
    Readme = Join-Path $raymanRoot 'README.md'
    ReleaseRequirements = Join-Path $raymanRoot 'RELEASE_REQUIREMENTS.md'
    DistReleaseRequirements = Join-Path $raymanRoot '.dist\RELEASE_REQUIREMENTS.md'
    RaymanPs1 = Join-Path $raymanRoot 'rayman.ps1'
    RaymanBash = Join-Path $raymanRoot 'rayman'
    CommandCatalog = Join-Path $raymanRoot 'scripts\utils\command_catalog.ps1'
    ReleaseGate = Join-Path $raymanRoot 'scripts\release\release_gate.ps1'
    DistReleaseGate = Join-Path $raymanRoot '.dist\scripts\release\release_gate.ps1'
  }
}

function New-RaymanVersionCheckResult {
  param(
    [string]$Label,
    [string]$Path,
    [string]$Expected,
    [string]$Observed,
    [bool]$Ok,
    [string]$Reason
  )

  return [pscustomobject]@{
    label = $Label
    path = $Path
    expected = $Expected
    observed = $Observed
    ok = $Ok
    reason = $Reason
  }
}

function Test-RaymanLiteralVersionValue {
  param(
    [string]$Label,
    [string]$Path,
    [string]$Expected,
    [string]$ValidationPattern
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return New-RaymanVersionCheckResult -Label $Label -Path $Path -Expected $Expected -Observed '' -Ok $false -Reason 'missing'
  }

  $observed = (Get-Content -LiteralPath $Path -Raw -Encoding UTF8).Trim()
  if (-not [string]::IsNullOrWhiteSpace($ValidationPattern) -and ($observed -notmatch $ValidationPattern)) {
    return New-RaymanVersionCheckResult -Label $Label -Path $Path -Expected $Expected -Observed $observed -Ok $false -Reason 'invalid_format'
  }

  if ([string]::IsNullOrWhiteSpace($Expected)) {
    return New-RaymanVersionCheckResult -Label $Label -Path $Path -Expected '' -Observed $observed -Ok $true -Reason ''
  }

  return New-RaymanVersionCheckResult -Label $Label -Path $Path -Expected $Expected -Observed $observed -Ok ($observed -ceq $Expected) -Reason 'mismatch'
}

function Test-RaymanRegexVersionValue {
  param(
    [string]$Label,
    [string]$Path,
    [string]$Pattern,
    [string]$Expected
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return New-RaymanVersionCheckResult -Label $Label -Path $Path -Expected $Expected -Observed '' -Ok $false -Reason 'missing'
  }

  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $matches = [regex]::Matches($raw, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
  if ($matches.Count -eq 0) {
    return New-RaymanVersionCheckResult -Label $Label -Path $Path -Expected $Expected -Observed '' -Ok $false -Reason 'token_missing'
  }

  $values = New-Object System.Collections.Generic.List[string]
  foreach ($match in $matches) {
    $value = ''
    if ($match.Groups['token'].Success) {
      $value = [string]$match.Groups['token'].Value
    } else {
      $value = [string]$match.Value
    }

    if (-not $values.Contains($value)) {
      $values.Add($value) | Out-Null
    }
  }

  $observed = ($values.ToArray() -join ', ')
  $ok = ($values.Count -eq 1 -and $values[0] -ceq $Expected)
  return New-RaymanVersionCheckResult -Label $Label -Path $Path -Expected $Expected -Observed $observed -Ok $ok -Reason 'mismatch'
}

function Get-RaymanVersionReport {
  param([string]$WorkspaceRoot)

  $paths = Get-RaymanManagedVersionPaths -WorkspaceRoot $WorkspaceRoot
  $checks = New-Object System.Collections.Generic.List[object]

  $sourceVersionCheck = Test-RaymanLiteralVersionValue -Label '.Rayman/VERSION' -Path $paths.Version -Expected '' -ValidationPattern '^(?i)v\d+$'
  $checks.Add($sourceVersionCheck) | Out-Null

  $expectedLower = ''
  $expectedUpper = ''
  if ($sourceVersionCheck.ok -and -not [string]::IsNullOrWhiteSpace([string]$sourceVersionCheck.observed)) {
    $parts = Get-RaymanVersionTokenParts -RawVersion ([string]$sourceVersionCheck.observed)
    $expectedLower = [string]$parts.lower
    $expectedUpper = [string]$parts.upper
    $sourceVersionCheck.expected = $expectedLower
  } else {
    $sourceVersionCheck.expected = 'vNNN'
  }

  $checks.Add((Test-RaymanLiteralVersionValue -Label '.Rayman/.dist/VERSION' -Path $paths.DistVersion -Expected $expectedLower -ValidationPattern '^(?i)v\d+$')) | Out-Null
  $checks.Add((Test-RaymanRegexVersionValue -Label 'AGENTS marker' -Path $paths.Agents -Pattern 'RAYMAN:MANDATORY_REQUIREMENTS_(?<token>V\d+)' -Expected $expectedUpper)) | Out-Null
  $checks.Add((Test-RaymanRegexVersionValue -Label '.Rayman/agents.template.md marker' -Path $paths.AgentsTemplate -Pattern 'RAYMAN:MANDATORY_REQUIREMENTS_(?<token>V\d+)' -Expected $expectedUpper)) | Out-Null
  $checks.Add((Test-RaymanRegexVersionValue -Label '.Rayman/scripts/release/release_gate.ps1 expectedTag' -Path $paths.ReleaseGate -Pattern '(?m)^\$expectedTag\s*=\s*''(?<token>V\d+)''\s*$' -Expected $expectedUpper)) | Out-Null
  $checks.Add((Test-RaymanRegexVersionValue -Label '.Rayman/scripts/release/release_gate.ps1 expectedVersion' -Path $paths.ReleaseGate -Pattern '(?m)^\$expectedVersion\s*=\s*''(?<token>V\d+)''\s*$' -Expected $expectedUpper)) | Out-Null
  $checks.Add((Test-RaymanRegexVersionValue -Label '.Rayman/scripts/release/release_gate.ps1 marker strings' -Path $paths.ReleaseGate -Pattern "notmatch 'RAYMAN:MANDATORY_REQUIREMENTS_(?<token>V\d+)'" -Expected $expectedUpper)) | Out-Null
  $checks.Add((Test-RaymanRegexVersionValue -Label '.Rayman/scripts/release/release_gate.ps1 marker messages' -Path $paths.ReleaseGate -Pattern 'missing (?<token>V\d+) marker' -Expected $expectedUpper)) | Out-Null
  $checks.Add((Test-RaymanRegexVersionValue -Label '.Rayman/.dist/scripts/release/release_gate.ps1 expectedTag' -Path $paths.DistReleaseGate -Pattern '(?m)^\$expectedTag\s*=\s*''(?<token>V\d+)''\s*$' -Expected $expectedUpper)) | Out-Null
  $checks.Add((Test-RaymanRegexVersionValue -Label '.Rayman/.dist/scripts/release/release_gate.ps1 expectedVersion' -Path $paths.DistReleaseGate -Pattern '(?m)^\$expectedVersion\s*=\s*''(?<token>V\d+)''\s*$' -Expected $expectedUpper)) | Out-Null
  $checks.Add((Test-RaymanRegexVersionValue -Label '.Rayman/README.md title' -Path $paths.Readme -Pattern '(?m)^# Rayman (?<token>v\d+)\s*$' -Expected $expectedLower)) | Out-Null
  $checks.Add((Test-RaymanRegexVersionValue -Label '.Rayman/RELEASE_REQUIREMENTS.md current version' -Path $paths.ReleaseRequirements -Pattern '(?m)^> 当前版本：\s*(?<token>v\d+)\s*$' -Expected $expectedLower)) | Out-Null
  $checks.Add((Test-RaymanRegexVersionValue -Label '.Rayman/.dist/RELEASE_REQUIREMENTS.md current version' -Path $paths.DistReleaseRequirements -Pattern '(?m)^> 当前版本：\s*(?<token>v\d+)\s*$' -Expected $expectedLower)) | Out-Null
  $checks.Add((Test-RaymanRegexVersionValue -Label '.Rayman/rayman.ps1 help version' -Path $paths.RaymanPs1 -Pattern '(?m)^\s*\$helpVersion\s*=\s*''(?<token>v\d+)''\s*$' -Expected $expectedLower)) | Out-Null
  $checks.Add((Test-RaymanRegexVersionValue -Label '.Rayman/rayman bash banner' -Path $paths.RaymanBash -Pattern 'Rayman CLI \((?<token>v\d+)\)' -Expected $expectedLower)) | Out-Null
  $checks.Add((Test-RaymanRegexVersionValue -Label '.Rayman/scripts/utils/command_catalog.ps1 fallback version' -Path $paths.CommandCatalog -Pattern '(?m)^\s*\$fallback\s*=\s*''(?<token>v\d+)''\s*$' -Expected $expectedLower)) | Out-Null

  return [pscustomobject]@{
    workspace_root = $WorkspaceRoot
    expected_lower = $expectedLower
    expected_upper = $expectedUpper
    checks = @($checks.ToArray())
    ok = (@($checks.ToArray() | Where-Object { -not [bool]$_.ok }).Count -eq 0)
  }
}

function Show-RaymanVersionReport {
  param([object]$Report)

  Write-ManageVersionInfo ("workspace_root={0}" -f [string]$Report.workspace_root)
  Write-ManageVersionInfo ("expected_lower={0}" -f [string]$Report.expected_lower)
  Write-ManageVersionInfo ("expected_upper={0}" -f [string]$Report.expected_upper)

  foreach ($check in @($Report.checks)) {
    $relPath = Get-ManageVersionDisplayPath -BasePath ([string]$Report.workspace_root) -FullPath ([string]$check.path)
    if ([bool]$check.ok) {
      Write-Host ("[OK]   {0} => {1}" -f [string]$check.label, [string]$check.observed)
    } else {
      Write-Host ("[DIFF] {0} => expected={1}; observed={2}; reason={3}; path={4}" -f [string]$check.label, [string]$check.expected, [string]$check.observed, [string]$check.reason, $relPath)
    }
  }

  if ([bool]$Report.ok) {
    Write-ManageVersionInfo 'overall=OK'
    return
  }

  Write-ManageVersionInfo 'overall=MISMATCH'
}

function Invoke-RaymanRegexReplace {
  param(
    [string]$Path,
    [string]$Pattern,
    [scriptblock]$Evaluator
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw ("managed file missing: {0}" -f $Path)
  }

  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $script:__rayman_manage_version_replace_count = 0
  $updated = [regex]::Replace(
    $raw,
    $Pattern,
    {
      param($match)
      $script:__rayman_manage_version_replace_count = $script:__rayman_manage_version_replace_count + 1
      & $Evaluator $match
    },
    [System.Text.RegularExpressions.RegexOptions]::Multiline
  )
  $count = [int]$script:__rayman_manage_version_replace_count
  $script:__rayman_manage_version_replace_count = 0

  if ($count -le 0) {
    throw ("pattern not found in managed file: {0}" -f $Path)
  }

  if ($updated -cne $raw) {
    Write-RaymanUtf8NoBomFile -Path $Path -Content $updated
  }
}

function Invoke-RaymanVersionSet {
  param(
    [string]$WorkspaceRoot,
    [string]$TargetVersion
  )

  $workspaceKind = Get-RaymanWorkspaceKind -WorkspaceRoot $WorkspaceRoot
  if ($workspaceKind -ne 'source') {
    Fail-ManageVersion -Message ("newversion is only allowed in the Rayman source workspace. current workspace kind: {0}" -f $workspaceKind) -ExitCode 4
  }

  $paths = Get-RaymanManagedVersionPaths -WorkspaceRoot $WorkspaceRoot
  $parts = Get-RaymanVersionTokenParts -RawVersion $TargetVersion
  $lower = [string]$parts.lower
  $upper = [string]$parts.upper

  Write-ManageVersionInfo ("setting version to {0}/{1}" -f $upper, $lower)

  Write-RaymanUtf8NoBomFile -Path $paths.Version -Content ($lower + "`n")

  Invoke-RaymanRegexReplace -Path $paths.Agents -Pattern 'RAYMAN:MANDATORY_REQUIREMENTS_V\d+' -Evaluator {
    param($match)
    return ('RAYMAN:MANDATORY_REQUIREMENTS_{0}' -f $upper)
  }
  Invoke-RaymanRegexReplace -Path $paths.AgentsTemplate -Pattern 'RAYMAN:MANDATORY_REQUIREMENTS_V\d+' -Evaluator {
    param($match)
    return ('RAYMAN:MANDATORY_REQUIREMENTS_{0}' -f $upper)
  }
  Invoke-RaymanRegexReplace -Path $paths.Readme -Pattern '(?m)^# Rayman v\d+\s*$' -Evaluator {
    param($match)
    return ('# Rayman {0}' -f $lower)
  }
  Invoke-RaymanRegexReplace -Path $paths.ReleaseRequirements -Pattern '(?m)^> 当前版本：\s*v\d+\s*$' -Evaluator {
    param($match)
    return ('> 当前版本： {0}' -f $lower)
  }
  Invoke-RaymanRegexReplace -Path $paths.RaymanPs1 -Pattern '(?m)^(\s*\$helpVersion\s*=\s*)''v\d+''(\s*)$' -Evaluator {
    param($match)
    return ("{0}'{1}'{2}" -f [string]$match.Groups[1].Value, $lower, [string]$match.Groups[2].Value)
  }
  Invoke-RaymanRegexReplace -Path $paths.RaymanBash -Pattern 'Rayman CLI \(v\d+\)' -Evaluator {
    param($match)
    return ('Rayman CLI ({0})' -f $lower)
  }
  Invoke-RaymanRegexReplace -Path $paths.CommandCatalog -Pattern '(?m)^(\s*\$fallback\s*=\s*)''v\d+''(\s*)$' -Evaluator {
    param($match)
    return ("{0}'{1}'{2}" -f [string]$match.Groups[1].Value, $lower, [string]$match.Groups[2].Value)
  }
  Invoke-RaymanRegexReplace -Path $paths.ReleaseGate -Pattern '(?m)^(\$expectedTag\s*=\s*)''V\d+''(\s*)$' -Evaluator {
    param($match)
    return ("{0}'{1}'{2}" -f [string]$match.Groups[1].Value, $upper, [string]$match.Groups[2].Value)
  }
  Invoke-RaymanRegexReplace -Path $paths.ReleaseGate -Pattern '(?m)^(\$expectedVersion\s*=\s*)''V\d+''(\s*)$' -Evaluator {
    param($match)
    return ("{0}'{1}'{2}" -f [string]$match.Groups[1].Value, $upper, [string]$match.Groups[2].Value)
  }
  Invoke-RaymanRegexReplace -Path $paths.ReleaseGate -Pattern '(?m)^(\s*if \(\$agentsRaw -notmatch '')RAYMAN:MANDATORY_REQUIREMENTS_V\d+(''.*)$' -Evaluator {
    param($match)
    return ("{0}RAYMAN:MANDATORY_REQUIREMENTS_{1}{2}" -f [string]$match.Groups[1].Value, $upper, [string]$match.Groups[2].Value)
  }
  Invoke-RaymanRegexReplace -Path $paths.ReleaseGate -Pattern '(?m)^(\s*if \(\$templateRaw -notmatch '')RAYMAN:MANDATORY_REQUIREMENTS_V\d+(''.*)$' -Evaluator {
    param($match)
    return ("{0}RAYMAN:MANDATORY_REQUIREMENTS_{1}{2}" -f [string]$match.Groups[1].Value, $upper, [string]$match.Groups[2].Value)
  }
  Invoke-RaymanRegexReplace -Path $paths.ReleaseGate -Pattern 'missing V\d+ marker' -Evaluator {
    param($match)
    return ('missing {0} marker' -f $upper)
  }

  $syncScript = Join-Path $PSScriptRoot 'sync_dist_from_src.ps1'
  if (-not (Test-Path -LiteralPath $syncScript -PathType Leaf)) {
    throw ("sync script missing: {0}" -f $syncScript)
  }

  & $syncScript -WorkspaceRoot $WorkspaceRoot -Validate
  if (Test-Path variable:LASTEXITCODE) {
    if ([int]$LASTEXITCODE -ne 0) {
      throw ("sync_dist_from_src.ps1 failed with exit code {0}" -f [int]$LASTEXITCODE)
    }
  } elseif (-not $?) {
    throw 'sync_dist_from_src.ps1 failed'
  }

  $report = Get-RaymanVersionReport -WorkspaceRoot $WorkspaceRoot
  Show-RaymanVersionReport -Report $report
  if (-not [bool]$report.ok) {
    throw 'version consistency re-check failed after newversion'
  }
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path

switch ($Action) {
  'show' {
    $report = Get-RaymanVersionReport -WorkspaceRoot $WorkspaceRoot
    Show-RaymanVersionReport -Report $report
    if (-not [bool]$report.ok) {
      exit 1
    }
    exit 0
  }
  'set' {
    try {
      Invoke-RaymanVersionSet -WorkspaceRoot $WorkspaceRoot -TargetVersion $Version
      exit 0
    } catch {
      Fail-ManageVersion -Message $_.Exception.Message -ExitCode 1
    }
  }
}
