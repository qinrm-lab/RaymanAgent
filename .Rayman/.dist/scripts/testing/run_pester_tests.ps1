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

$testFiles = @(Get-ChildItem -LiteralPath $testsPath -Filter '*.Tests.ps1' -File | Sort-Object FullName)
if ($testFiles.Count -eq 0) {
  throw "No Pester test files found under: $testsPath"
}

$aggregate = [ordered]@{
  TotalCount = 0
  PassedCount = 0
  FailedCount = 0
  SkippedCount = 0
  InconclusiveCount = 0
  Duration = [timespan]::Zero
}
$failedContainers = New-Object System.Collections.Generic.List[string]

foreach ($testFile in $testFiles) {
  try {
    Set-Location -LiteralPath $WorkspaceRoot
    if (Get-PSDrive -Name 'TestDrive' -ErrorAction SilentlyContinue) {
      Remove-PSDrive -Name 'TestDrive' -Force -ErrorAction SilentlyContinue
    }
  } catch {}

  $config = New-PesterConfiguration
  $config.Run.Path = @([string]$testFile.FullName)
  $config.Run.PassThru = $true
  $config.Output.Verbosity = 'Detailed'
  $config.TestResult.Enabled = $true
  $config.TestResult.OutputFormat = 'NUnitXml'
  $config.TestResult.OutputPath = $xmlPath

  $fileResult = Invoke-Pester -Configuration $config
  $aggregate.TotalCount += [int]$fileResult.TotalCount
  $aggregate.PassedCount += [int]$fileResult.PassedCount
  $aggregate.FailedCount += [int]$fileResult.FailedCount
  $aggregate.SkippedCount += [int]$fileResult.SkippedCount
  $aggregate.InconclusiveCount += [int]$fileResult.InconclusiveCount
  $aggregate.Duration += $fileResult.Duration

  if ([int]$fileResult.FailedCount -gt 0) {
    $failedContainers.Add([string]$testFile.FullName) | Out-Null
  }
}

$report = [pscustomobject]@{
  schema = 'rayman.testing.pester.v1'
  workspace_root = $WorkspaceRoot
  success = ([int]$aggregate.FailedCount -eq 0)
  total = [int]$aggregate.TotalCount
  passed = [int]$aggregate.PassedCount
  failed = [int]$aggregate.FailedCount
  skipped = [int]$aggregate.SkippedCount
  inconclusive = [int]$aggregate.InconclusiveCount
  duration_seconds = [double]$aggregate.Duration.TotalSeconds
  xml_path = $xmlPath
  failed_paths = @($failedContainers.ToArray())
}
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
$report | ConvertTo-Json -Depth 5

if (-not [bool]$report.success) {
  exit 1
}
