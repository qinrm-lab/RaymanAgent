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
    [string[]]$RequiredTokens = @()
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

  if ($missingTokens.Count -gt 0) {
    Add-Check -Name $RelativePath -Passed $false -Detail ("missing tokens: {0}" -f (($missingTokens | ForEach-Object { $_ }) -join ', '))
    return
  }

  Add-Check -Name $RelativePath -Passed $true -Detail 'ok'
}

foreach ($assetContract in @(Get-RaymanManagedAssetContracts)) {
  Test-NonEmptyFile -RelativePath ([string]$assetContract.relative_path) -RequiredTokens @($assetContract.required_tokens)
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
Test-NonEmptyFile -RelativePath '.Rayman/context/skills.auto.md' -RequiredTokens @('选择结果', '## 你应当使用的能力/工具')

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
