Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  $script:ReleaseGateScript = Join-Path $script:RepoRoot '.Rayman\scripts\release\release_gate.ps1'
  $script:CurrentVersion = (Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\VERSION') -Raw -Encoding UTF8).Trim()
  $script:CurrentTag = $script:CurrentVersion.ToUpperInvariant()
}

function script:Initialize-ReleaseGateWorkspace {
  param([string]$Root)

  foreach ($dir in @(
      '.Rayman',
      '.Rayman\.dist',
      '.Rayman\scripts\release',
      '.Rayman\.dist\scripts\release',
      '.Rayman\scripts\utils',
      '.Rayman\scripts\testing',
      '.Rayman\runtime\test_lanes'
    )) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Root $dir) | Out-Null
  }

  git -C $Root init | Out-Null
  git -C $Root config user.email 'rayman@example.test' | Out-Null
  git -C $Root config user.name 'Rayman Tests' | Out-Null
  Set-Content -LiteralPath (Join-Path $Root 'README.txt') -Encoding UTF8 -Value 'gate fixture'
  git -C $Root add README.txt | Out-Null
  git -C $Root commit -m 'base' | Out-Null

  Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'AGENTS.md') -Destination (Join-Path $Root 'AGENTS.md') -Force
  Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\common.ps1') -Destination (Join-Path $Root '.Rayman\common.ps1') -Force
  Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\agents.template.md') -Destination (Join-Path $Root '.Rayman\agents.template.md') -Force
  Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\README.md') -Destination (Join-Path $Root '.Rayman\README.md') -Force
  Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\RELEASE_REQUIREMENTS.md') -Destination (Join-Path $Root '.Rayman\RELEASE_REQUIREMENTS.md') -Force
  Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\VERSION') -Destination (Join-Path $Root '.Rayman\VERSION') -Force
  Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\rayman.ps1') -Destination (Join-Path $Root '.Rayman\rayman.ps1') -Force
  Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\rayman') -Destination (Join-Path $Root '.Rayman\rayman') -Force
  Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\utils\command_catalog.ps1') -Destination (Join-Path $Root '.Rayman\scripts\utils\command_catalog.ps1') -Force
  Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\release\release_gate.ps1') -Destination (Join-Path $Root '.Rayman\scripts\release\release_gate.ps1') -Force
  Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\release\release_gate.lib.ps1') -Destination (Join-Path $Root '.Rayman\scripts\release\release_gate.lib.ps1') -Force
  Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\.dist\VERSION') -Destination (Join-Path $Root '.Rayman\.dist\VERSION') -Force
  Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\.dist\RELEASE_REQUIREMENTS.md') -Destination (Join-Path $Root '.Rayman\.dist\RELEASE_REQUIREMENTS.md') -Force
  Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\.dist\scripts\release\release_gate.ps1') -Destination (Join-Path $Root '.Rayman\.dist\scripts\release\release_gate.ps1') -Force
  Set-Content -LiteralPath (Join-Path $Root '.Rayman\scripts\testing\run_fast_contract.sh') -Encoding UTF8 -Value '#!/usr/bin/env bash'
}

function script:Copy-ReleaseGateMirrorFixtureAssets {
  param([string]$Root)

  $assertSyncPath = Join-Path $script:RepoRoot '.Rayman\scripts\release\assert_dist_sync.ps1'
  $assertSyncRaw = Get-Content -LiteralPath $assertSyncPath -Raw -Encoding UTF8
  $mirrorMatch = [regex]::Match($assertSyncRaw, '(?ms)\$mirrorRel\s*=\s*@\((?<body>.*?)^\s*\)')
  if (-not $mirrorMatch.Success) {
    throw 'mirrorRel block not found in assert_dist_sync.ps1'
  }

  $mirrorRel = @([regex]::Matches([string]$mirrorMatch.Groups['body'].Value, "'(?<path>[^']+)'") | ForEach-Object { [string]$_.Groups['path'].Value } | Select-Object -Unique)
  foreach ($rel in $mirrorRel) {
    $relWin = $rel.Replace('/', '\')
    foreach ($prefix in @('.Rayman', '.Rayman\.dist')) {
      $src = Join-Path $script:RepoRoot (Join-Path $prefix $relWin)
      $dst = Join-Path $Root (Join-Path $prefix $relWin)
      if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
        throw ("mirror fixture source missing: {0}" -f $src)
      }
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
      Copy-Item -LiteralPath $src -Destination $dst -Force
    }
  }
}

function script:Enable-ReleaseGateSourceWorkspaceKind {
  param([string]$Root)

  $workflowPath = Join-Path $Root '.github\workflows\rayman-test-lanes.yml'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $workflowPath) | Out-Null
  Set-Content -LiteralPath $workflowPath -Encoding UTF8 -Value @'
name: rayman-test-lanes
on:
  workflow_dispatch:
'@
}

function script:New-FakeBash {
  param(
    [string]$Root,
    [ValidateSet('write_report', 'no_report')][string]$Mode = 'write_report'
  )

  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  $wrapperPath = Join-Path $Root 'bash.cmd'
  $body = if ($Mode -eq 'write_report') {
@'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
$workspaceRoot = (Get-Location).Path
$reportPath = Join-Path $workspaceRoot '.Rayman\runtime\test_lanes\fast_contract.report.json'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $reportPath) | Out-Null
$payload = [ordered]@{
  schema = 'rayman.testing.fast_contract.v1'
  generated_at = (Get-Date).ToString('o')
  workspace_root = $workspaceRoot
  success = $true
}
Set-Content -LiteralPath $reportPath -Encoding UTF8 -Value (($payload | ConvertTo-Json -Depth 6).TrimEnd() + "`n")
exit 0
'@
  } else {
@'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
Write-Output 'fast-contract auto-run executed but did not create a report'
exit 0
'@
  }

  $implPath = Join-Path $Root 'bash.impl.ps1'
  Set-Content -LiteralPath $implPath -Encoding UTF8 -Value $body
  $pwsh = Get-Command 'powershell.exe' -ErrorAction Stop | Select-Object -First 1
  $quotedImpl = $implPath.Replace("'", "''")
  Set-Content -LiteralPath $wrapperPath -Encoding ASCII -Value @"
@echo off
"$($pwsh.Source)" -NoProfile -ExecutionPolicy Bypass -Command "& '$quotedImpl' @args" -- %*
exit /b %ERRORLEVEL%
"@
  return $wrapperPath
}

function script:New-FakePwsh {
  param(
    [string]$Root
  )

  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  $wrapperPath = Join-Path $Root 'pwsh.cmd'
  $implPath = Join-Path $Root 'pwsh.impl.ps1'
  Set-Content -LiteralPath $implPath -Encoding UTF8 -Value @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
$workspaceRoot = (Get-Location).Path
$joined = ($Args -join ' ')
if ($joined -match 'run_host_smoke\.ps1') {
  $reportPath = Join-Path $workspaceRoot '.Rayman\runtime\test_lanes\host_smoke.report.json'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $reportPath) | Out-Null
  $payload = [ordered]@{
    schema = 'rayman.testing.host_smoke.v1'
    generated_at = (Get-Date).ToString('o')
    workspace_root = $workspaceRoot
    overall = 'PASS'
    steps = @()
  }
  Set-Content -LiteralPath $reportPath -Encoding UTF8 -Value (($payload | ConvertTo-Json -Depth 8).TrimEnd() + "`n")
  exit 0
}
Write-Output 'fake pwsh wrapper: no-op'
exit 0
'@
  $ps = Get-Command 'powershell.exe' -ErrorAction Stop | Select-Object -First 1
  $quotedImpl = $implPath.Replace("'", "''")
  Set-Content -LiteralPath $wrapperPath -Encoding ASCII -Value @"
@echo off
"$($ps.Source)" -NoProfile -ExecutionPolicy Bypass -Command "& '$quotedImpl' @args" -- %*
exit /b %ERRORLEVEL%
"@
  return $wrapperPath
}

function script:Set-FakeRaymanCli {
  param(
    [string]$WorkspaceRoot,
    [ValidateSet('fast_gate_pass')][string]$Mode = 'fast_gate_pass'
  )

  $raymanPath = Join-Path $WorkspaceRoot '.Rayman\rayman.ps1'
  if ($Mode -eq 'fast_gate_pass') {
    Set-Content -LiteralPath $raymanPath -Encoding UTF8 -Value @'
param(
  [Parameter(Position=0)][string]$Action = '',
  [Parameter(Position=1, ValueFromRemainingArguments=$true)][string[]]$ActionArgs
)
$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ($Action -eq 'fast-gate') {
  $reportPath = Join-Path $workspaceRoot '.Rayman\runtime\project_gates\fast.report.json'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $reportPath) | Out-Null
  $payload = [ordered]@{
    schema = 'rayman.project_gate.v1'
    generated_at = (Get-Date).ToString('o')
    workspace_root = $workspaceRoot
    lane = 'fast'
    overall = 'PASS'
    success = $true
    counts = [ordered]@{
      pass = 3
      warn = 0
      fail = 0
      skip = 0
      total = 3
    }
    checks = @()
  }
  Set-Content -LiteralPath $reportPath -Encoding UTF8 -Value (($payload | ConvertTo-Json -Depth 10).TrimEnd() + "`n")
  exit 0
}
Write-Output ('fake rayman action: ' + $Action)
exit 0
'@
  }

  return $raymanPath
}

function script:Set-FakeHostSmokeScript {
  param(
    [string]$WorkspaceRoot,
    [switch]$UseWorkspaceMutex,
    [int]$HoldSeconds = 0,
    [string]$StartMarkerName = ''
  )

  $scriptPath = Join-Path $WorkspaceRoot '.Rayman\scripts\testing\run_host_smoke.ps1'
  $body = @'
param(
  [string]$WorkspaceRoot = (Get-Location).Path
)
$reportPath = Join-Path $WorkspaceRoot '.Rayman\runtime\test_lanes\host_smoke.report.json'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $reportPath) | Out-Null
$payload = [ordered]@{
  schema = 'rayman.testing.host_smoke.v1'
  generated_at = (Get-Date).ToString('o')
  workspace_root = $WorkspaceRoot
  overall = 'PASS'
  steps = @()
}
Set-Content -LiteralPath $reportPath -Encoding UTF8 -Value (($payload | ConvertTo-Json -Depth 8).TrimEnd() + "`n")
exit 0
'@
  if ($UseWorkspaceMutex) {
    $holdSecondsClamped = [Math]::Max(0, [int]$HoldSeconds)
    $escapedStartMarkerName = ([string]$StartMarkerName).Replace("'", "''")
    Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\testing\host_smoke.lib.ps1') -Destination (Join-Path $WorkspaceRoot '.Rayman\scripts\testing\host_smoke.lib.ps1') -Force
    $body = @"
param(
  [string]`$WorkspaceRoot = (Get-Location).Path
)
. (Join-Path `$PSScriptRoot 'host_smoke.lib.ps1')
`$reportPath = Join-Path `$WorkspaceRoot '.Rayman\runtime\test_lanes\host_smoke.report.json'
`$runtimeDir = Split-Path -Parent `$reportPath
New-Item -ItemType Directory -Force -Path `$runtimeDir | Out-Null
`$mutex = New-RaymanHostSmokeRunMutex -WorkspaceRootPath `$WorkspaceRoot
if (`$null -eq `$mutex) {
  throw 'expected host smoke mutex'
}
`$waitSeconds = Get-RaymanHostSmokeMutexWaitSeconds
`$hasHandle = `$false
try {
  `$hasHandle = `$mutex.WaitOne([TimeSpan]::FromSeconds(`$waitSeconds))
  if (-not `$hasHandle) {
    throw ("timed out waiting for host smoke mutex after {0}s" -f `$waitSeconds)
  }

  `$startMarkerName = '$escapedStartMarkerName'
  if (-not [string]::IsNullOrWhiteSpace(`$startMarkerName)) {
    `$startMarkerPath = Join-Path `$runtimeDir `$startMarkerName
    Set-Content -LiteralPath `$startMarkerPath -Encoding UTF8 -Value 'started'
  }

  if ($holdSecondsClamped -gt 0) {
    Start-Sleep -Seconds $holdSecondsClamped
  }

  `$payload = [ordered]@{
    schema = 'rayman.testing.host_smoke.v1'
    generated_at = (Get-Date).ToString('o')
    workspace_root = `$WorkspaceRoot
    overall = 'PASS'
    steps = @()
  }
  Set-Content -LiteralPath `$reportPath -Encoding UTF8 -Value ((`$payload | ConvertTo-Json -Depth 8).TrimEnd() + "``n")
  exit 0
} finally {
  if (`$hasHandle) {
    `$mutex.ReleaseMutex()
  }
  `$mutex.Dispose()
}
"@
  }

  Set-Content -LiteralPath $scriptPath -Encoding UTF8 -Value $body

  return $scriptPath
}

Describe 'release_gate standard mode' {
  It 'fails dist sync when mirrored source/dist assets are still pending in the git index for source workspaces' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_release_gate_pending_index_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-ReleaseGateWorkspace -Root $root
      Copy-ReleaseGateMirrorFixtureAssets -Root $root
      Enable-ReleaseGateSourceWorkspaceKind -Root $root

      $assertScript = Join-Path $root '.Rayman\scripts\release\assert_dist_sync.ps1'
      $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $assertScript -WorkspaceRoot $root 2>&1
      $output = ($raw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
      $exitCode = $LASTEXITCODE

      $exitCode | Should -Be 6
      $output | Should -Match 'git index pending mirrored assets'
      $output | Should -Match 'git add'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'ignores Rayman-owned dynamic sandbox residue during version consistency scan' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_release_gate_ignore_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-ReleaseGateWorkspace -Root $root
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.temp\rayman-dynamic-sandbox') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.temp\rayman-dynamic-sandbox\agents.md') -Encoding UTF8 -Value '<!-- RAYMAN:MANDATORY_REQUIREMENTS_V117 -->'
      $reportPath = Join-Path $root '.Rayman\runtime\test_lanes\fast_contract.report.json'
      $payload = [ordered]@{
        schema = 'rayman.testing.fast_contract.v1'
        generated_at = (Get-Date).ToString('o')
        workspace_root = $root
        success = $true
      }
      Set-Content -LiteralPath $reportPath -Encoding UTF8 -Value (($payload | ConvertTo-Json -Depth 6).TrimEnd() + "`n")

      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:ReleaseGateScript -WorkspaceRoot $root -SkipAutoDistSync -Json | Out-Null
      $report = Get-Content -LiteralPath (Join-Path $root '.Rayman\state\release_gate_report.json') -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      $versionCheck = @($report.checks | Where-Object { [string]$_.name -eq '版本一致性' } | Select-Object -First 1)[0]

      [string]$versionCheck.status | Should -Be 'PASS'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'auto-runs fast contract once when the report is missing' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_release_gate_fast_contract_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_release_gate_bin_' + [Guid]::NewGuid().ToString('N'))
    $pathBackup = [Environment]::GetEnvironmentVariable('PATH')
    try {
      Initialize-ReleaseGateWorkspace -Root $root
      New-FakeBash -Root $binRoot -Mode 'write_report' | Out-Null
      [Environment]::SetEnvironmentVariable('PATH', ($binRoot + ';' + $pathBackup))

      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:ReleaseGateScript -WorkspaceRoot $root -SkipAutoDistSync -Json | Out-Null
      $report = Get-Content -LiteralPath (Join-Path $root '.Rayman\state\release_gate_report.json') -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      $laneCheck = @($report.checks | Where-Object { [string]$_.name -eq '快速契约Lane' } | Select-Object -First 1)[0]

      (Test-Path -LiteralPath (Join-Path $root '.Rayman\runtime\test_lanes\fast_contract.report.json') -PathType Leaf) | Should -Be $true
      [string]$laneCheck.status | Should -Be 'PASS'
    } finally {
      [Environment]::SetEnvironmentVariable('PATH', $pathBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'keeps fast contract as FAIL when auto-run still produces no report' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_release_gate_fast_contract_fail_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_release_gate_bin_' + [Guid]::NewGuid().ToString('N'))
    $pathBackup = [Environment]::GetEnvironmentVariable('PATH')
    try {
      Initialize-ReleaseGateWorkspace -Root $root
      New-FakeBash -Root $binRoot -Mode 'no_report' | Out-Null
      [Environment]::SetEnvironmentVariable('PATH', ($binRoot + ';' + $pathBackup))

      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:ReleaseGateScript -WorkspaceRoot $root -SkipAutoDistSync -Json | Out-Null
      $report = Get-Content -LiteralPath (Join-Path $root '.Rayman\state\release_gate_report.json') -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      $laneCheck = @($report.checks | Where-Object { [string]$_.name -eq '快速契约Lane' } | Select-Object -First 1)[0]

      [string]$laneCheck.status | Should -Be 'FAIL'
      [string]$laneCheck.detail | Should -Match 'auto_run=attempted'
    } finally {
      [Environment]::SetEnvironmentVariable('PATH', $pathBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'release_gate project mode' {
  It 'auto-runs host smoke when the report is stale' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_release_gate_project_host_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-ReleaseGateWorkspace -Root $root
      Set-FakeHostSmokeScript -WorkspaceRoot $root | Out-Null

      $hostSmokePath = Join-Path $root '.Rayman\runtime\test_lanes\host_smoke.report.json'
      $hostSmokePayload = [ordered]@{
        schema = 'rayman.testing.host_smoke.v1'
        generated_at = ([datetime]::UtcNow.AddMinutes(-10).ToString('o'))
        workspace_root = $root
        overall = 'FAIL'
        steps = @()
      }
      Set-Content -LiteralPath $hostSmokePath -Encoding UTF8 -Value (($hostSmokePayload | ConvertTo-Json -Depth 8).TrimEnd() + "`n")
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\testing\host_smoke_input.txt') -Encoding UTF8 -Value 'fresh host smoke input'

      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:ReleaseGateScript -WorkspaceRoot $root -Mode project -SkipAutoDistSync -Json | Out-Null
      $report = Get-Content -LiteralPath (Join-Path $root '.Rayman\state\release_gate_report.json') -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      $laneCheck = @($report.checks | Where-Object { [string]$_.name -eq '宿主环境冒烟' } | Select-Object -First 1)[0]

      [string]$laneCheck.status | Should -Be 'PASS'
      [string]$laneCheck.detail | Should -Match 'auto_refresh=refreshed_and_passed'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'serializes concurrent host smoke auto-refreshes across project-mode release gates' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_release_gate_project_host_concurrent_' + [Guid]::NewGuid().ToString('N'))
    $proc1 = $null
    $proc2 = $null
    try {
      Initialize-ReleaseGateWorkspace -Root $root
      Set-FakeHostSmokeScript -WorkspaceRoot $root -UseWorkspaceMutex -HoldSeconds 3 -StartMarkerName 'host_smoke.started' | Out-Null

      $hostSmokePath = Join-Path $root '.Rayman\runtime\test_lanes\host_smoke.report.json'
      $hostSmokePayload = [ordered]@{
        schema = 'rayman.testing.host_smoke.v1'
        generated_at = ([datetime]::UtcNow.AddMinutes(-10).ToString('o'))
        workspace_root = $root
        overall = 'FAIL'
        steps = @()
      }
      Set-Content -LiteralPath $hostSmokePath -Encoding UTF8 -Value (($hostSmokePayload | ConvertTo-Json -Depth 8).TrimEnd() + "`n")
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\testing\host_smoke_input.txt') -Encoding UTF8 -Value 'fresh host smoke input'

      $stateDir = Join-Path $root '.Rayman\state'
      New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
      $markerPath = Join-Path $root '.Rayman\runtime\test_lanes\host_smoke.started'
      $reportPath1 = Join-Path $stateDir 'release_gate_concurrent_1.md'
      $reportPath2 = Join-Path $stateDir 'release_gate_concurrent_2.md'
      $stdoutPath1 = Join-Path $stateDir 'release_gate_concurrent_1.stdout.log'
      $stdoutPath2 = Join-Path $stateDir 'release_gate_concurrent_2.stdout.log'
      $stderrPath1 = Join-Path $stateDir 'release_gate_concurrent_1.stderr.log'
      $stderrPath2 = Join-Path $stateDir 'release_gate_concurrent_2.stderr.log'

      $proc1 = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $script:ReleaseGateScript,
        '-WorkspaceRoot', $root,
        '-Mode', 'project',
        '-SkipAutoDistSync',
        '-Json',
        '-ReportPath', $reportPath1
      ) -WorkingDirectory $root -PassThru -RedirectStandardOutput $stdoutPath1 -RedirectStandardError $stderrPath1

      $markerDeadline = [datetime]::UtcNow.AddSeconds(15)
      while ([datetime]::UtcNow -lt $markerDeadline -and -not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        Start-Sleep -Milliseconds 100
      }

      (Test-Path -LiteralPath $markerPath -PathType Leaf) | Should -Be $true

      $proc2 = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $script:ReleaseGateScript,
        '-WorkspaceRoot', $root,
        '-Mode', 'project',
        '-SkipAutoDistSync',
        '-Json',
        '-ReportPath', $reportPath2
      ) -WorkingDirectory $root -PassThru -RedirectStandardOutput $stdoutPath2 -RedirectStandardError $stderrPath2

      $proc1.WaitForExit(60000) | Should -Be $true
      $proc2.WaitForExit(60000) | Should -Be $true

      $stdoutText1 = if (Test-Path -LiteralPath $stdoutPath1 -PathType Leaf) { Get-Content -LiteralPath $stdoutPath1 -Raw -Encoding UTF8 } else { '' }
      $stdoutText2 = if (Test-Path -LiteralPath $stdoutPath2 -PathType Leaf) { Get-Content -LiteralPath $stdoutPath2 -Raw -Encoding UTF8 } else { '' }
      $stderrText1 = if (Test-Path -LiteralPath $stderrPath1 -PathType Leaf) { Get-Content -LiteralPath $stderrPath1 -Raw -Encoding UTF8 } else { '' }
      $stderrText2 = if (Test-Path -LiteralPath $stderrPath2 -PathType Leaf) { Get-Content -LiteralPath $stderrPath2 -Raw -Encoding UTF8 } else { '' }
      $proc1ExitCode = -999
      $proc2ExitCode = -999
      if ($null -ne $proc1) {
        $proc1.Refresh()
        $proc1ExitCode = [int]$proc1.ExitCode
      }
      if ($null -ne $proc2) {
        $proc2.Refresh()
        $proc2ExitCode = [int]$proc2.ExitCode
      }

      if ($proc1ExitCode -ne 0) {
        throw ("first concurrent release_gate exited {0}; stdout={1}`nstderr={2}" -f $proc1ExitCode, ([string]$stdoutText1).Trim(), ([string]$stderrText1).Trim())
      }
      if ($proc2ExitCode -ne 0) {
        throw ("second concurrent release_gate exited {0}; stdout={1}`nstderr={2}" -f $proc2ExitCode, ([string]$stdoutText2).Trim(), ([string]$stderrText2).Trim())
      }

      $report1 = Get-Content -LiteralPath ([System.IO.Path]::ChangeExtension($reportPath1, '.json')) -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      $report2 = Get-Content -LiteralPath ([System.IO.Path]::ChangeExtension($reportPath2, '.json')) -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      $laneCheck1 = @($report1.checks | Where-Object { [string]$_.name -eq '宿主环境冒烟' } | Select-Object -First 1)[0]
      $laneCheck2 = @($report2.checks | Where-Object { [string]$_.name -eq '宿主环境冒烟' } | Select-Object -First 1)[0]

      [string]$laneCheck1.status | Should -Be 'PASS'
      [string]$laneCheck2.status | Should -Be 'PASS'
      [string]$laneCheck1.detail | Should -Match 'auto_refresh=refreshed_and_passed'
      [string]$laneCheck2.detail | Should -Match 'auto_refresh=refreshed_and_passed'
    } finally {
      if ($null -ne $proc1 -and -not $proc1.HasExited) {
        $proc1.Kill()
        $proc1.WaitForExit()
      }
      if ($null -ne $proc2 -and -not $proc2.HasExited) {
        $proc2.Kill()
        $proc2.WaitForExit()
      }
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'auto-runs fast-gate when the project fast gate report is stale' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_release_gate_project_fast_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-ReleaseGateWorkspace -Root $root
      Set-FakeRaymanCli -WorkspaceRoot $root | Out-Null

      $fastContractPath = Join-Path $root '.Rayman\runtime\test_lanes\fast_contract.report.json'
      $fastContractPayload = [ordered]@{
        schema = 'rayman.testing.fast_contract.v1'
        generated_at = (Get-Date).ToString('o')
        workspace_root = $root
        success = $true
      }
      Set-Content -LiteralPath $fastContractPath -Encoding UTF8 -Value (($fastContractPayload | ConvertTo-Json -Depth 6).TrimEnd() + "`n")

      $hostSmokePath = Join-Path $root '.Rayman\runtime\test_lanes\host_smoke.report.json'
      $hostSmokePayload = [ordered]@{
        schema = 'rayman.testing.host_smoke.v1'
        generated_at = (Get-Date).ToString('o')
        workspace_root = $root
        overall = 'PASS'
        steps = @()
      }
      Set-Content -LiteralPath $hostSmokePath -Encoding UTF8 -Value (($hostSmokePayload | ConvertTo-Json -Depth 8).TrimEnd() + "`n")

      $browserReportPath = Join-Path $root '.Rayman\runtime\project_gates\browser.report.json'
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $browserReportPath) | Out-Null
      $browserPayload = [ordered]@{
        schema = 'rayman.project_gate.v1'
        generated_at = (Get-Date).ToString('o')
        workspace_root = $root
        lane = 'browser'
        overall = 'PASS'
        success = $true
        counts = [ordered]@{ pass = 1; warn = 0; fail = 0; skip = 0; total = 1 }
        checks = @()
      }
      Set-Content -LiteralPath $browserReportPath -Encoding UTF8 -Value (($browserPayload | ConvertTo-Json -Depth 10).TrimEnd() + "`n")

      $fastReportPath = Join-Path $root '.Rayman\runtime\project_gates\fast.report.json'
      $fastPayload = [ordered]@{
        schema = 'rayman.project_gate.v1'
        generated_at = ([datetime]::UtcNow.AddMinutes(-10).ToString('o'))
        workspace_root = $root
        lane = 'fast'
        overall = 'FAIL'
        success = $false
        counts = [ordered]@{ pass = 0; warn = 0; fail = 3; skip = 0; total = 3 }
        checks = @()
      }
      Set-Content -LiteralPath $fastReportPath -Encoding UTF8 -Value (($fastPayload | ConvertTo-Json -Depth 10).TrimEnd() + "`n")
      Set-Content -LiteralPath (Join-Path $root '.rayman.project.json') -Encoding UTF8 -Value '{ "schema": "rayman.project_config.v1" }'

      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:ReleaseGateScript -WorkspaceRoot $root -Mode project -SkipAutoDistSync -Json | Out-Null
      $report = Get-Content -LiteralPath (Join-Path $root '.Rayman\state\release_gate_report.json') -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      $laneCheck = @($report.checks | Where-Object { [string]$_.name -eq '项目快速门禁' } | Select-Object -First 1)[0]

      [string]$laneCheck.status | Should -Be 'PASS'
      [string]$laneCheck.detail | Should -Match 'auto_refresh=refreshed_and_passed'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
