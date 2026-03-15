param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$testsPath = Join-Path $WorkspaceRoot '.Rayman\scripts\testing\pester'
$runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime\test_lanes'
$xmlPath = Join-Path $runtimeDir 'pester-results.xml'
$jsonPath = Join-Path $runtimeDir 'pester.report.json'

if (-not (Test-Path -LiteralPath $testsPath -PathType Container)) {
  throw "Pester test path not found: $testsPath"
}

if (-not (Get-Module -ListAvailable -Name Pester)) {
  throw 'Pester is not installed. Install it with: Install-Module Pester -Force -SkipPublisherCheck -Scope CurrentUser'
}

if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
}

Import-Module Pester -Force | Out-Null

$config = New-PesterConfiguration
$config.Run.Path = $testsPath
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $true
$config.TestResult.OutputFormat = 'NUnitXml'
$config.TestResult.OutputPath = $xmlPath

$result = Invoke-Pester -Configuration $config

$report = [pscustomobject]@{
  schema = 'rayman.testing.pester.v1'
  workspace_root = $WorkspaceRoot
  success = ([int]$result.FailedCount -eq 0)
  total = [int]$result.TotalCount
  passed = [int]$result.PassedCount
  failed = [int]$result.FailedCount
  skipped = [int]$result.SkippedCount
  inconclusive = [int]$result.InconclusiveCount
  duration_seconds = [double]$result.Duration.TotalSeconds
  xml_path = $xmlPath
}
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
$report | ConvertTo-Json -Depth 5

if (-not [bool]$report.success) {
  exit 1
}
