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

$testHost = ''
try {
  $testHost = [string](Get-Process -Id $PID -ErrorAction Stop | Select-Object -ExpandProperty Path)
} catch {
  $testHost = ''
}
if ([string]::IsNullOrWhiteSpace($testHost)) {
  foreach ($candidate in @('pwsh', 'pwsh.exe', 'powershell', 'powershell.exe')) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
      $testHost = [string]$cmd.Source
      break
    }
  }
}
if ([string]::IsNullOrWhiteSpace($testHost)) {
  throw 'Unable to resolve a PowerShell host for isolated Pester execution.'
}

$perFileRunnerPath = Join-Path $runtimeDir 'run_pester_single_file.ps1'
$perFileRunner = @'
param(
  [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
  [Parameter(Mandatory = $true)][string]$TestFile,
  [Parameter(Mandatory = $true)][string]$PesterModulePath,
  [Parameter(Mandatory = $true)][string]$XmlPath,
  [Parameter(Mandatory = $true)][string]$ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$TestFile = (Resolve-Path -LiteralPath $TestFile).Path

Import-Module $PesterModulePath -Force | Out-Null

try {
  Set-Location -LiteralPath $WorkspaceRoot
  if (Get-PSDrive -Name 'TestDrive' -ErrorAction SilentlyContinue) {
    Remove-PSDrive -Name 'TestDrive' -Force -ErrorAction SilentlyContinue
  }
} catch {}

$config = New-PesterConfiguration
$config.Run.Path = @($TestFile)
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $true
$config.TestResult.OutputFormat = 'NUnitXml'
$config.TestResult.OutputPath = $XmlPath

$payload = $null

try {
  $result = Invoke-Pester -Configuration $config
  $payload = [ordered]@{
    success = ([int]$result.FailedCount -eq 0)
    total = [int]$result.TotalCount
    passed = [int]$result.PassedCount
    failed = [int]$result.FailedCount
    skipped = [int]$result.SkippedCount
    inconclusive = [int]$result.InconclusiveCount
    duration_seconds = [double]$result.Duration.TotalSeconds
    fatal = $false
    error = ''
  }
} catch {
  $payload = [ordered]@{
    success = $false
    total = 0
    passed = 0
    failed = 1
    skipped = 0
    inconclusive = 0
    duration_seconds = 0
    fatal = $true
    error = $_.Exception.Message
  }
}

$payload['test_file'] = $TestFile
$payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultPath -Encoding UTF8

if ([bool]$payload.success) {
  exit 0
}

exit 1
'@
Set-Content -LiteralPath $perFileRunnerPath -Encoding UTF8 -Value $perFileRunner

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
  $resultPath = Join-Path $runtimeDir ([string]('{0}.result.json' -f $testFile.BaseName))
  if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
  }

  $fileResult = $null
  $childExitCode = 1

  try {
    & $testHost -NoProfile -ExecutionPolicy Bypass -File $perFileRunnerPath `
      -WorkspaceRoot $WorkspaceRoot `
      -TestFile ([string]$testFile.FullName) `
      -PesterModulePath ([string]$pesterModule.Path) `
      -XmlPath $xmlPath `
      -ResultPath $resultPath
    $childExitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
  } catch {
    $childExitCode = 1
  }

  if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
    try {
      $fileResult = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
      $fileResult = $null
    }
  }

  if ($null -eq $fileResult) {
    $fileResult = [pscustomobject]@{
      success = $false
      total = 0
      passed = 0
      failed = 1
      skipped = 0
      inconclusive = 0
      duration_seconds = 0
      fatal = $true
      error = 'Per-file Pester result payload was not created.'
      test_file = [string]$testFile.FullName
    }
  }

  $aggregate.TotalCount += [int]$fileResult.total
  $aggregate.PassedCount += [int]$fileResult.passed
  $aggregate.FailedCount += [int]$fileResult.failed
  $aggregate.SkippedCount += [int]$fileResult.skipped
  $aggregate.InconclusiveCount += [int]$fileResult.inconclusive
  $aggregate.Duration += [timespan]::FromSeconds([double]$fileResult.duration_seconds)

  if ($childExitCode -ne 0 -or -not [bool]$fileResult.success) {
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
