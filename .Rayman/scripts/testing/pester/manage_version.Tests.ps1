Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function script:Get-TestPowerShellPath {
  foreach ($candidate in @('pwsh', 'pwsh.exe', 'powershell', 'powershell.exe')) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
      return [string]$cmd.Source
    }
  }

  throw 'pwsh/powershell not found'
}

function script:Initialize-VersionWorkspace {
  param(
    [string]$Root,
    [switch]$AsSource
  )

  foreach ($dir in @(
    '.Rayman',
    '.Rayman\.dist',
    '.Rayman\scripts\release',
    '.Rayman\.dist\scripts\release',
    '.Rayman\scripts\utils',
    '.Rayman\scripts\testing',
    '.github\workflows'
  )) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Root $dir) | Out-Null
  }

  if ($AsSource) {
    Set-Content -LiteralPath (Join-Path $Root '.github\workflows\rayman-test-lanes.yml') -Encoding UTF8 -Value 'name: rayman-test-lanes'
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\scripts\testing\run_fast_contract.sh') -Encoding UTF8 -Value '#!/usr/bin/env bash'
  }

  Set-Content -LiteralPath (Join-Path $Root 'AGENTS.md') -Encoding UTF8 -Value @'
<!-- RAYMAN:MANDATORY_REQUIREMENTS_V161 -->
<!-- /RAYMAN:MANDATORY_REQUIREMENTS_V161 -->
'@
  Set-Content -LiteralPath (Join-Path $Root '.Rayman\agents.template.md') -Encoding UTF8 -Value @'
<!-- RAYMAN:MANDATORY_REQUIREMENTS_V161 -->
<!-- /RAYMAN:MANDATORY_REQUIREMENTS_V161 -->
'@
  Set-Content -LiteralPath (Join-Path $Root '.Rayman\VERSION') -Encoding UTF8 -Value 'v161'
  Set-Content -LiteralPath (Join-Path $Root '.Rayman\.dist\VERSION') -Encoding UTF8 -Value 'v161'
  Set-Content -LiteralPath (Join-Path $Root '.Rayman\README.md') -Encoding UTF8 -Value '# Rayman v161'
  Set-Content -LiteralPath (Join-Path $Root '.Rayman\RELEASE_REQUIREMENTS.md') -Encoding UTF8 -Value '> 当前版本： v161'
  Set-Content -LiteralPath (Join-Path $Root '.Rayman\.dist\RELEASE_REQUIREMENTS.md') -Encoding UTF8 -Value '> 当前版本： v161'
  Set-Content -LiteralPath (Join-Path $Root '.Rayman\rayman.ps1') -Encoding UTF8 -Value '$helpVersion = ''v161'''
  Set-Content -LiteralPath (Join-Path $Root '.Rayman\rayman') -Encoding UTF8 -Value 'Rayman CLI (v161)'
  Set-Content -LiteralPath (Join-Path $Root '.Rayman\scripts\utils\command_catalog.ps1') -Encoding UTF8 -Value '$fallback = ''v161'''
  Set-Content -LiteralPath (Join-Path $Root '.Rayman\scripts\release\manage_version.ps1') -Encoding UTF8 -Value '# mirrored by sync'
  Set-Content -LiteralPath (Join-Path $Root '.Rayman\scripts\release\release_gate.ps1') -Encoding UTF8 -Value @'
$expectedTag = 'V161'
$expectedVersion = 'V161'
if ($agentsRaw -notmatch 'RAYMAN:MANDATORY_REQUIREMENTS_V161') {
  $versionIssues.Add('missing V161 marker') | Out-Null
}
if ($templateRaw -notmatch 'RAYMAN:MANDATORY_REQUIREMENTS_V161') {
  $versionIssues.Add('.Rayman/agents.template.md missing V161 marker') | Out-Null
}
$legacyPattern = 'RAYMAN:MANDATORY_REQUIREMENTS_V117|RAYMAN:MANDATORY_REQUIREMENTS_V118|RAYMAN:MANDATORY_REQUIREMENTS_V154|\bv154\b|\bv153\b|\bv151\b'
'@
  Set-Content -LiteralPath (Join-Path $Root '.Rayman\.dist\scripts\release\release_gate.ps1') -Encoding UTF8 -Value @'
$expectedTag = 'V161'
$expectedVersion = 'V161'
if ($agentsRaw -notmatch 'RAYMAN:MANDATORY_REQUIREMENTS_V161') {
  $versionIssues.Add('missing V161 marker') | Out-Null
}
if ($templateRaw -notmatch 'RAYMAN:MANDATORY_REQUIREMENTS_V161') {
  $versionIssues.Add('.Rayman/agents.template.md missing V161 marker') | Out-Null
}
$legacyPattern = 'RAYMAN:MANDATORY_REQUIREMENTS_V117|RAYMAN:MANDATORY_REQUIREMENTS_V118|RAYMAN:MANDATORY_REQUIREMENTS_V154|\bv154\b|\bv153\b|\bv151\b'
'@
  Set-Content -LiteralPath (Join-Path $Root '.Rayman\scripts\release\assert_dist_sync.ps1') -Encoding UTF8 -Value @'
$mirrorRel = @(
  'scripts/release/release_gate.ps1'
  'scripts/release/manage_version.ps1'
  'RELEASE_REQUIREMENTS.md'
  'VERSION'
)
exit 0
'@
}

BeforeAll {
  $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  $script:ManageVersionPath = Join-Path $script:RepoRoot '.Rayman\scripts\release\manage_version.ps1'
  $script:PowerShellPath = Get-TestPowerShellPath
}

Describe 'manage_version' {
  It 'reports a consistent workspace as overall OK' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_version_show_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      Initialize-VersionWorkspace -Root $root -AsSource

      $output = & $script:PowerShellPath -NoProfile -ExecutionPolicy Bypass -File $script:ManageVersionPath -WorkspaceRoot $root -Action show 2>&1 | Out-String

      $LASTEXITCODE | Should -Be 0
      $output | Should -Match 'overall=OK'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'returns non-zero and prints diffs when managed files disagree' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_version_diff_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      Initialize-VersionWorkspace -Root $root -AsSource
      Set-Content -LiteralPath (Join-Path $root '.Rayman\README.md') -Encoding UTF8 -Value '# Rayman v160'

      $output = & $script:PowerShellPath -NoProfile -ExecutionPolicy Bypass -File $script:ManageVersionPath -WorkspaceRoot $root -Action show 2>&1 | Out-String

      $LASTEXITCODE | Should -Be 1
      $output | Should -Match 'overall=MISMATCH'
      $output | Should -Match 'README'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'blocks newversion outside the Rayman source workspace' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_version_external_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      Initialize-VersionWorkspace -Root $root

      $output = & $script:PowerShellPath -NoProfile -ExecutionPolicy Bypass -File $script:ManageVersionPath -WorkspaceRoot $root -Action set -Version v162 2>&1 | Out-String

      $LASTEXITCODE | Should -Be 4
      $output | Should -Match 'source workspace'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'normalizes vNNN/VNNN input and updates governed source plus dist files' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_version_set_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      Initialize-VersionWorkspace -Root $root -AsSource

      $output = & $script:PowerShellPath -NoProfile -ExecutionPolicy Bypass -File $script:ManageVersionPath -WorkspaceRoot $root -Action set -Version V162 2>&1 | Out-String

      $LASTEXITCODE | Should -Be 0
      $output | Should -Match 'overall=OK'
      (Get-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Raw -Encoding UTF8).Trim() | Should -Be 'v162'
      (Get-Content -LiteralPath (Join-Path $root 'AGENTS.md') -Raw -Encoding UTF8) | Should -Match 'RAYMAN:MANDATORY_REQUIREMENTS_V162'
      (Get-Content -LiteralPath (Join-Path $root '.Rayman\scripts\release\release_gate.ps1') -Raw -Encoding UTF8) | Should -Match '\$expectedTag = ''V162'''
      (Get-Content -LiteralPath (Join-Path $root '.Rayman\scripts\release\release_gate.ps1') -Raw -Encoding UTF8) | Should -Match '\$expectedVersion = ''V162'''
      (Get-Content -LiteralPath (Join-Path $root '.Rayman\scripts\release\release_gate.ps1') -Raw -Encoding UTF8) | Should -Match 'if \(\$agentsRaw -notmatch ''RAYMAN:MANDATORY_REQUIREMENTS_V162''\)'
      (Get-Content -LiteralPath (Join-Path $root '.Rayman\scripts\release\release_gate.ps1') -Raw -Encoding UTF8) | Should -Match 'if \(\$templateRaw -notmatch ''RAYMAN:MANDATORY_REQUIREMENTS_V162''\)'
      (Get-Content -LiteralPath (Join-Path $root '.Rayman\scripts\release\release_gate.ps1') -Raw -Encoding UTF8) | Should -Match '\$legacyPattern = ''RAYMAN:MANDATORY_REQUIREMENTS_V117\|RAYMAN:MANDATORY_REQUIREMENTS_V118\|RAYMAN:MANDATORY_REQUIREMENTS_V154\|\\bv154\\b\|\\bv153\\b\|\\bv151\\b'''
      (Get-Content -LiteralPath (Join-Path $root '.Rayman\README.md') -Raw -Encoding UTF8) | Should -Match '# Rayman v162'
      (Get-Content -LiteralPath (Join-Path $root '.Rayman\.dist\VERSION') -Raw -Encoding UTF8).Trim() | Should -Be 'v162'
      (Get-Content -LiteralPath (Join-Path $root '.Rayman\.dist\RELEASE_REQUIREMENTS.md') -Raw -Encoding UTF8) | Should -Match 'v162'
      (Get-Content -LiteralPath (Join-Path $root '.Rayman\.dist\scripts\release\release_gate.ps1') -Raw -Encoding UTF8) | Should -Match 'V162'
      (Get-Content -LiteralPath (Join-Path $root '.Rayman\rayman.ps1') -Raw -Encoding UTF8) | Should -Not -Match 'v161'
      (Get-Content -LiteralPath (Join-Path $root '.Rayman\rayman') -Raw -Encoding UTF8) | Should -Not -Match 'v161'
      (Get-Content -LiteralPath (Join-Path $root '.Rayman\scripts\utils\command_catalog.ps1') -Raw -Encoding UTF8) | Should -Not -Match 'v161'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
