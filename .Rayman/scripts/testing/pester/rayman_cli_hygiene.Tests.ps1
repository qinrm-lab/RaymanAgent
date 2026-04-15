Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
}

function script:Get-RaymanCliTestPowerShellPath {
  foreach ($candidate in @('powershell.exe', 'powershell', 'pwsh.exe', 'pwsh')) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
      return [string]$cmd.Source
    }
  }

  throw 'powershell host not found'
}

function script:Initialize-RaymanCliHygieneWorkspace {
  param([string]$Root)

  foreach ($dir in @(
      '.Rayman',
      '.Rayman\config',
      '.Rayman\scripts\utils',
      '.Rayman\scripts\release',
      '.Rayman\scripts\testing'
    )) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Root $dir) | Out-Null
  }

  foreach ($file in @(
      '.Rayman\rayman.ps1',
      '.Rayman\common.ps1',
      '.Rayman\scripts\utils\command_catalog.ps1',
      '.Rayman\scripts\utils\post_command_hygiene.ps1',
      '.Rayman\scripts\utils\workspace_state_guard.ps1',
      '.Rayman\scripts\utils\legacy_rayman_cleanup.ps1',
      '.Rayman\scripts\utils\runtime_cleanup.ps1'
    )) {
    Copy-Item -LiteralPath (Join-Path $script:RepoRoot $file) -Destination (Join-Path $Root $file) -Force
  }

  Set-Content -LiteralPath (Join-Path $Root '.Rayman\config\command_catalog.tsv') -Encoding UTF8 -Value @'
# schema: rayman.command_catalog.v1
# columns: name<TAB>platform<TAB>group<TAB>summary<TAB>recommended
help	all	core	Show CLI help and platform tags.	0
menu	pwsh-only	core	Show the interactive command picker.	0
release-gate	pwsh-only	release	Run release readiness checks and reports.	1
'@
  Set-Content -LiteralPath (Join-Path $Root '.Rayman\scripts\testing\run_fast_contract.sh') -Encoding UTF8 -Value '#!/usr/bin/env bash'
  Set-Content -LiteralPath (Join-Path $Root '.rayman.env.ps1') -Encoding UTF8 -Value '$env:RAYMAN_POST_COMMAND_HYGIENE_ENABLED = ''1'''
}

Describe 'rayman CLI post-command hygiene' {
  It 'runs shared hygiene after a successful command and writes a report' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_cli_hygiene_success_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-RaymanCliHygieneWorkspace -Root $root
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime\tmp\run-a') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\release\release_gate.ps1') -Encoding UTF8 -Value @'
param(
  [string]$WorkspaceRoot,
  [string]$ReportPath,
  [string]$Mode,
  [switch]$AllowNoGit,
  [switch]$Json,
  [switch]$IncludeResidualDiagnostics
)
Write-Host 'release gate ok'
exit 0
'@

      $psHost = Get-RaymanCliTestPowerShellPath
      & $psHost -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root '.Rayman\rayman.ps1') release-gate | Out-Null

      $LASTEXITCODE | Should -Be 0
      Test-Path -LiteralPath (Join-Path $root '.Rayman\runtime\tmp\run-a') | Should -Be $false
      Test-Path -LiteralPath (Join-Path $root '.Rayman\runtime\post_command_hygiene.last.json') -PathType Leaf | Should -Be $true
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'keeps JSON command output machine-parseable while still running hygiene' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_cli_hygiene_json_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-RaymanCliHygieneWorkspace -Root $root
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime\tmp\run-a') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\release\release_gate.ps1') -Encoding UTF8 -Value @'
param(
  [string]$WorkspaceRoot,
  [string]$ReportPath,
  [string]$Mode,
  [switch]$AllowNoGit,
  [switch]$Json,
  [switch]$IncludeResidualDiagnostics
)
@{
  schema = 'rayman.release_gate.stub.v1'
  success = $true
} | ConvertTo-Json -Depth 4
exit 0
'@

      $psHost = Get-RaymanCliTestPowerShellPath
      $output = & $psHost -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root '.Rayman\rayman.ps1') release-gate --json 2>&1
      $parsed = (@($output) -join "`n" | ConvertFrom-Json)

      $LASTEXITCODE | Should -Be 0
      [string]$parsed.schema | Should -Be 'rayman.release_gate.stub.v1'
      Test-Path -LiteralPath (Join-Path $root '.Rayman\runtime\tmp\run-a') | Should -Be $false
      Test-Path -LiteralPath (Join-Path $root '.Rayman\runtime\post_command_hygiene.last.json') -PathType Leaf | Should -Be $true
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'skips hygiene for help and menu surfaces' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_cli_hygiene_help_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-RaymanCliHygieneWorkspace -Root $root
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime\tmp\run-a') | Out-Null

      $psHost = Get-RaymanCliTestPowerShellPath
      & $psHost -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root '.Rayman\rayman.ps1') help | Out-Null

      $LASTEXITCODE | Should -Be 0
      Test-Path -LiteralPath (Join-Path $root '.Rayman\runtime\tmp\run-a') -PathType Container | Should -Be $true
      Test-Path -LiteralPath (Join-Path $root '.Rayman\runtime\post_command_hygiene.last.json') | Should -Be $false
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
