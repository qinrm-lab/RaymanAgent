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

try {
  $modulePathSeparator = [string][System.IO.Path]::PathSeparator
  $existingModuleRoots = @(([string]$env:PSModulePath -split [regex]::Escape($modulePathSeparator)) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $preferredModuleRoots = New-Object System.Collections.Generic.List[string]
  $myDocuments = ''
  try {
    $myDocuments = [string][Environment]::GetFolderPath('MyDocuments')
  } catch {
    $myDocuments = ''
  }

  foreach ($root in @(
    $(if (-not [string]::IsNullOrWhiteSpace([string]$HOME)) { Join-Path $HOME 'Documents\PowerShell\Modules' } else { '' }),
    $(if (-not [string]::IsNullOrWhiteSpace([string]$HOME)) { Join-Path $HOME 'Documents\WindowsPowerShell\Modules' } else { '' }),
    $(if (-not [string]::IsNullOrWhiteSpace($myDocuments)) { Join-Path $myDocuments 'PowerShell\Modules' } else { '' }),
    $(if (-not [string]::IsNullOrWhiteSpace($myDocuments)) { Join-Path $myDocuments 'WindowsPowerShell\Modules' } else { '' })
  )) {
    if ([string]::IsNullOrWhiteSpace([string]$root)) { continue }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    if ($preferredModuleRoots -notcontains $root) {
      $preferredModuleRoots.Add($root) | Out-Null
    }
  }

  $prependRoots = @($preferredModuleRoots.ToArray() | Where-Object { $existingModuleRoots -notcontains $_ })
  if ($prependRoots.Count -gt 0) {
    $env:PSModulePath = ((@($prependRoots) + @($existingModuleRoots)) -join $modulePathSeparator)
  }
} catch {}

$pesterModule = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [Version]'5.0.0' } | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $pesterModule) {
  throw 'Pester 5+ is not installed. Install it with: Install-Module Pester -Force -SkipPublisherCheck -Scope CurrentUser -MinimumVersion 5.0.0'
}

if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
}

Import-Module ([string]$pesterModule.Path) -Force | Out-Null

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
