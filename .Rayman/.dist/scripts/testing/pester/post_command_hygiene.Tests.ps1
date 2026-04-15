Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  $script:GitPath = (Get-Command git -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1)
  . (Join-Path $script:RepoRoot '.Rayman\common.ps1')
  . (Join-Path $script:RepoRoot '.Rayman\scripts\utils\post_command_hygiene.ps1') -NoMain
}

function script:Initialize-HygieneGitRoot {
  param([string]$Root)

  & $script:GitPath -C $Root init | Out-Null
  & $script:GitPath -C $Root config user.email 'rayman@example.test' | Out-Null
  & $script:GitPath -C $Root config user.name 'Rayman Tests' | Out-Null
}

Describe 'post command hygiene helper' {
  It 'auto-untracks tracked Rayman generated assets without deleting the working copy' {
    if ([string]::IsNullOrWhiteSpace([string]$script:GitPath)) {
      Set-ItResult -Skipped -Because 'git not found'
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_post_hygiene_untrack_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\testing') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\testing\run_fast_contract.sh') -Encoding UTF8 -Value '#!/usr/bin/env bash'
      Set-Content -LiteralPath (Join-Path $root '.rayman.env.ps1') -Encoding UTF8 -Value '$env:RAYMAN_POST_COMMAND_HYGIENE_ENABLED = ''1'''

      Initialize-HygieneGitRoot -Root $root
      & $script:GitPath -C $root add .Rayman/scripts/testing/run_fast_contract.sh .rayman.env.ps1 | Out-Null
      & $script:GitPath -C $root commit -m 'seed tracked rayman assets' | Out-Null

      $report = Invoke-RaymanPostCommandHygiene -WorkspaceRoot $root -CommandName 'test-fix' -ExitCode 0 -Quiet
      $tracked = @(& $script:GitPath -C $root ls-files -- .rayman.env.ps1 2>$null)

      @($tracked).Count | Should -Be 0
      Test-Path -LiteralPath (Join-Path $root '.rayman.env.ps1') -PathType Leaf | Should -Be $true
      [bool]$report.tracked_noise.auto_fix.attempted | Should -Be $true
      [bool]$report.tracked_noise.auto_fix.success | Should -Be $true
      [int]$report.tracked_noise.after.rayman_tracked_count | Should -Be 0
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'respects RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS and leaves tracked assets untouched' {
    if ([string]::IsNullOrWhiteSpace([string]$script:GitPath)) {
      Set-ItResult -Skipped -Because 'git not found'
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_post_hygiene_allow_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\testing') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\testing\run_fast_contract.sh') -Encoding UTF8 -Value '#!/usr/bin/env bash'
      Set-Content -LiteralPath (Join-Path $root '.rayman.env.ps1') -Encoding UTF8 -Value @(
        '$env:RAYMAN_POST_COMMAND_HYGIENE_ENABLED = ''1'''
        '$env:RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS = ''1'''
      )

      Initialize-HygieneGitRoot -Root $root
      & $script:GitPath -C $root add .Rayman/scripts/testing/run_fast_contract.sh .rayman.env.ps1 | Out-Null
      & $script:GitPath -C $root commit -m 'seed allowed tracked rayman assets' | Out-Null

      $report = Invoke-RaymanPostCommandHygiene -WorkspaceRoot $root -CommandName 'dispatch' -ExitCode 0 -Quiet
      $tracked = @(& $script:GitPath -C $root ls-files -- .rayman.env.ps1 2>$null)

      @($tracked).Count | Should -Be 1
      [bool]$report.tracked_noise.auto_fix.attempted | Should -Be $false
      [string]$report.tracked_noise.auto_fix.skipped_reason | Should -Be 'allowed_by_workspace_env'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'reports remaining non-Rayman dirty tree after cleanup without treating Rayman residue as business dirt' {
    if ([string]::IsNullOrWhiteSpace([string]$script:GitPath)) {
      Set-ItResult -Skipped -Because 'git not found'
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_post_hygiene_dirty_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\testing') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\testing\run_fast_contract.sh') -Encoding UTF8 -Value '#!/usr/bin/env bash'
      Set-Content -LiteralPath (Join-Path $root '.rayman.env.ps1') -Encoding UTF8 -Value '$env:RAYMAN_POST_COMMAND_HYGIENE_ENABLED = ''1'''
      Set-Content -LiteralPath (Join-Path $root 'business.txt') -Encoding UTF8 -Value 'base'
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime\tmp\run-a') | Out-Null

      Initialize-HygieneGitRoot -Root $root
      & $script:GitPath -C $root add .Rayman/scripts/testing/run_fast_contract.sh .rayman.env.ps1 business.txt | Out-Null
      & $script:GitPath -C $root commit -m 'seed business file' | Out-Null

      Set-Content -LiteralPath (Join-Path $root 'business.txt') -Encoding UTF8 -Value 'dirty'

      $report = Invoke-RaymanPostCommandHygiene -WorkspaceRoot $root -CommandName 'review-loop' -ExitCode 1 -Quiet

      Test-Path -LiteralPath (Join-Path $root '.Rayman\runtime\tmp\run-a') | Should -Be $false
      [int]$report.dirty_tree.non_rayman_count | Should -BeGreaterThan 0
      @($report.dirty_tree.non_rayman_paths) | Should -Contain 'business.txt'
      @($report.dirty_tree.rayman_paths) | Should -Not -Contain 'business.txt'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'classifies source-workspace Rayman edits separately and suppresses non-Rayman warnings when only those edits remain' {
    if ([string]::IsNullOrWhiteSpace([string]$script:GitPath)) {
      Set-ItResult -Skipped -Because 'git not found'
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_post_hygiene_source_dirty_' + [Guid]::NewGuid().ToString('N'))
    try {
      foreach ($dir in @(
          '.Rayman\scripts\testing',
          '.github\agents',
          '.github\workflows',
          '.RaymanAgent\agentic'
        )) {
        New-Item -ItemType Directory -Force -Path (Join-Path $root $dir) | Out-Null
      }

      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\testing\run_fast_contract.sh') -Encoding UTF8 -Value '#!/usr/bin/env bash'
      Set-Content -LiteralPath (Join-Path $root '.github\workflows\rayman-test-lanes.yml') -Encoding UTF8 -Value 'name: rayman-test-lanes'
      Set-Content -LiteralPath (Join-Path $root '.RaymanAgent\.RaymanAgent.requirements.md') -Encoding UTF8 -Value '# requirements'
      Set-Content -LiteralPath (Join-Path $root '.Rayman\README.md') -Encoding UTF8 -Value 'base'
      Set-Content -LiteralPath (Join-Path $root '.github\agents\rayman-browser.agent.md') -Encoding UTF8 -Value 'base-agent'
      Set-Content -LiteralPath (Join-Path $root '.RaymanAgent\agentic\plan.current.md') -Encoding UTF8 -Value 'base-plan'
      Set-Content -LiteralPath (Join-Path $root '.gitignore') -Encoding UTF8 -Value '*.log'
      Set-Content -LiteralPath (Join-Path $root 'RaymanAgent.slnx') -Encoding UTF8 -Value '<Solution />'

      Initialize-HygieneGitRoot -Root $root
      & $script:GitPath -C $root add . | Out-Null
      & $script:GitPath -C $root commit -m 'seed source workspace' | Out-Null

      Set-Content -LiteralPath (Join-Path $root '.Rayman\README.md') -Encoding UTF8 -Value 'dirty-readme'
      Set-Content -LiteralPath (Join-Path $root '.github\agents\rayman-browser.agent.md') -Encoding UTF8 -Value 'dirty-agent'
      Set-Content -LiteralPath (Join-Path $root '.RaymanAgent\agentic\plan.current.md') -Encoding UTF8 -Value 'dirty-plan'
      Set-Content -LiteralPath (Join-Path $root '.gitignore') -Encoding UTF8 -Value '*.tmp'
      Set-Content -LiteralPath (Join-Path $root 'RaymanAgent.slnx') -Encoding UTF8 -Value '<Solution><Project Path="demo.csproj" /></Solution>'

      $report = Invoke-RaymanPostCommandHygiene -WorkspaceRoot $root -CommandName 'dispatch' -ExitCode 0 -Quiet

      [int]$report.dirty_tree.source_rayman_count | Should -Be 5
      [int]$report.dirty_tree.non_rayman_count | Should -Be 0
      @($report.dirty_tree.source_rayman_paths) | Should -Contain '.Rayman/README.md'
      @($report.dirty_tree.source_rayman_paths) | Should -Contain '.github/agents/rayman-browser.agent.md'
      @($report.dirty_tree.source_rayman_paths) | Should -Contain '.RaymanAgent/agentic/plan.current.md'
      @($report.dirty_tree.source_rayman_paths) | Should -Contain '.gitignore'
      @($report.dirty_tree.source_rayman_paths) | Should -Contain 'RaymanAgent.slnx'
      @($report.warnings | Where-Object { [string]$_ -match 'remaining non-Rayman dirty tree' }).Count | Should -Be 0
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
