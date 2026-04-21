param(
  [string]$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "../../..")).Path,
  [switch]$AsJson,
  [switch]$SkipContextRefresh
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$raymanRoot = Join-Path $resolvedWorkspaceRoot '.Rayman'
$assetManifestPath = Join-Path $raymanRoot 'scripts\agents\agent_asset_manifest.ps1'
if (-not (Test-Path -LiteralPath $assetManifestPath -PathType Leaf)) {
  throw ("agent_asset_manifest.ps1 not found: {0}" -f $assetManifestPath)
}
. $assetManifestPath

$checks = New-Object 'System.Collections.Generic.List[object]'
$failures = New-Object 'System.Collections.Generic.List[string]'

function Add-Check {
  param(
    [string]$Name,
    [bool]$Passed,
    [string]$Detail
  )

  $checks.Add([pscustomobject]@{
      name = $Name
      passed = $Passed
      detail = $Detail
    }) | Out-Null

  if (-not $Passed) {
    $failures.Add(("{0}: {1}" -f $Name, $Detail)) | Out-Null
  }
}

function Test-NonEmptyFile {
  param(
    [string]$RelativePath,
    [string[]]$RequiredTokens = @(),
    [string[]]$ForbiddenPatterns = @()
  )

  $fullPath = Join-Path $resolvedWorkspaceRoot $RelativePath
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    Add-Check -Name $RelativePath -Passed $false -Detail 'missing'
    return
  }

  $raw = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) {
    Add-Check -Name $RelativePath -Passed $false -Detail 'empty'
    return
  }

  $missingTokens = New-Object 'System.Collections.Generic.List[string]'
  foreach ($token in $RequiredTokens) {
    if ($raw -notmatch [regex]::Escape($token)) {
      $missingTokens.Add($token) | Out-Null
    }
  }

  $matchedForbiddenPatterns = New-Object System.Collections.Generic.List[string]
  foreach ($pattern in $ForbiddenPatterns) {
    if ([string]::IsNullOrWhiteSpace([string]$pattern)) {
      continue
    }
    if ($raw -match [string]$pattern) {
      $matchedForbiddenPatterns.Add([string]$pattern) | Out-Null
    }
  }

  if ($missingTokens.Count -gt 0 -or $matchedForbiddenPatterns.Count -gt 0) {
    $problems = New-Object System.Collections.Generic.List[string]
    if ($missingTokens.Count -gt 0) {
      $problems.Add(("missing tokens: {0}" -f (($missingTokens | ForEach-Object { $_ }) -join ', '))) | Out-Null
    }
    if ($matchedForbiddenPatterns.Count -gt 0) {
      $problems.Add(("forbidden patterns matched: {0}" -f (($matchedForbiddenPatterns | ForEach-Object { $_ }) -join ', '))) | Out-Null
    }
    Add-Check -Name $RelativePath -Passed $false -Detail (($problems | ForEach-Object { $_ }) -join ' | ')
    return
  }

  Add-Check -Name $RelativePath -Passed $true -Detail 'ok'
}

function Ensure-SkillsAutoFile {
  $skillsPath = Join-Path $resolvedWorkspaceRoot '.Rayman\context\skills.auto.md'
  if (Test-Path -LiteralPath $skillsPath -PathType Leaf) {
    return
  }

  $detectSkillsScript = Join-Path $raymanRoot 'scripts\skills\detect_skills.ps1'
  if (-not (Test-Path -LiteralPath $detectSkillsScript -PathType Leaf)) {
    return
  }

  try {
    & $detectSkillsScript -Root $resolvedWorkspaceRoot | Out-Null
  } catch {
    Add-Check -Name 'skills-auto-generate' -Passed $false -Detail $_.Exception.Message
  }
}

foreach ($assetContract in @(Get-RaymanManagedAssetContracts)) {
  Test-NonEmptyFile -RelativePath ([string]$assetContract.relative_path) -RequiredTokens @($assetContract.required_tokens) -ForbiddenPatterns @($assetContract.forbidden_patterns)
}

if (-not $SkipContextRefresh) {
  $contextScript = Join-Path $raymanRoot 'scripts\utils\generate_context.ps1'
  try {
    & $contextScript -WorkspaceRoot $resolvedWorkspaceRoot | Out-Null
    Add-Check -Name 'context-refresh' -Passed $true -Detail 'generate_context.ps1 executed successfully'
  } catch {
    Add-Check -Name 'context-refresh' -Passed $false -Detail $_.Exception.Message
  }
}

Test-NonEmptyFile -RelativePath '.Rayman/CONTEXT.md' -RequiredTokens @('## Workspace Snapshot', '## Auto Skills', '## Agent Capabilities')
Ensure-SkillsAutoFile
Test-NonEmptyFile -RelativePath '.Rayman/context/skills.auto.md' -RequiredTokens @('选择结果', '## 你应当使用的能力/工具')

$manualCommandValidator = Join-Path $raymanRoot 'scripts\agents\validate_manual_command_contracts.ps1'
if (-not (Test-Path -LiteralPath $manualCommandValidator -PathType Leaf)) {
  Add-Check -Name 'manual-command-contracts' -Passed $false -Detail ("missing validator: {0}" -f $manualCommandValidator)
} else {
  try {
    $validatorOutput = @(& $manualCommandValidator -WorkspaceRoot $resolvedWorkspaceRoot -AsJson)
    $validatorJson = (($validatorOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    if ([string]::IsNullOrWhiteSpace($validatorJson)) {
      throw 'manual command validator returned no JSON payload'
    }

    $validatorResult = $validatorJson | ConvertFrom-Json -ErrorAction Stop
    $missingProps = @(
      @('passed', 'check_count', 'failure_count') |
        Where-Object { -not $validatorResult.PSObject.Properties[[string]$_] }
    )
    if ($missingProps.Count -gt 0) {
      throw ("manual command validator JSON missing properties: {0}" -f ($missingProps -join ', '))
    }

    $detail = "checks={0}; failures={1}" -f [int]$validatorResult.check_count, [int]$validatorResult.failure_count
    if (
      -not [bool]$validatorResult.passed -and
      $validatorResult.PSObject.Properties['checks']
    ) {
      $failedChecks = @(
        @($validatorResult.checks) |
          Where-Object { -not [bool]$_.passed } |
          Select-Object -First 3
      )
      if ($failedChecks.Count -gt 0) {
        $failedNames = @(
          $failedChecks |
            ForEach-Object { [string]$_.name } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        if ($failedNames.Count -gt 0) {
          $detail = "{0}; failed={1}" -f $detail, ($failedNames -join ' || ')
        }
      }
    }

    Add-Check -Name 'manual-command-contracts' -Passed ([bool]$validatorResult.passed) -Detail $detail
  } catch {
    Add-Check -Name 'manual-command-contracts' -Passed $false -Detail $_.Exception.Message
  }
}

$checkItems = [object[]]$checks.ToArray()
$result = [pscustomobject]@{
  workspaceRoot = $resolvedWorkspaceRoot
  passed = ($failures.Count -eq 0)
  checkCount = $checks.Count
  failureCount = $failures.Count
  checks = $checkItems
}

if ($AsJson) {
  $result | ConvertTo-Json -Depth 6
} else {
  foreach ($check in $checks) {
    $status = if ($check.passed) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1} - {2}" -f $status, $check.name, $check.detail) -ForegroundColor $(if ($check.passed) { 'Green' } else { 'Red' })
  }
  if ($failures.Count -eq 0) {
    Write-Host 'Agent contract checks passed.' -ForegroundColor Green
  } else {
    Write-Host ('Agent contract checks failed: {0}' -f ($failures -join ' | ')) -ForegroundColor Red
  }
}

if ($failures.Count -gt 0) {
  exit 1
}
