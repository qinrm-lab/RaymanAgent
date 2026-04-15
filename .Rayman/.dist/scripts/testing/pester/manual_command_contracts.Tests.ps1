Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  . (Join-Path $script:WorkspaceRoot '.Rayman\scripts\agents\agent_asset_manifest.ps1')
}

Describe 'manual command contracts' {
  It 'declares live governed docs and historical archives separately' {
    $scopes = @(Get-RaymanManualCommandDocumentScopes)
    $livePaths = @($scopes | Where-Object { [string]$_.mode -eq 'live' } | ForEach-Object { [string]$_.relative_path })
    $historicalPaths = @($scopes | Where-Object { [string]$_.mode -eq 'historical' } | ForEach-Object { [string]$_.relative_path })

    ($livePaths -contains '.Rayman/README.md') | Should -Be $true
    ($livePaths -contains '.github/copilot-instructions.md') | Should -Be $true
    ($livePaths -contains '.github/skills/worker-remote-debug/SKILL.md') | Should -Be $true
    ($historicalPaths -contains '.Rayman/release/delivery-pack-v159-20260307.md') | Should -Be $true
    ($historicalPaths -contains '.Rayman/release/public-release-notes-v159-20260307.md') | Should -Be $true
    ($historicalPaths -contains '.Rayman/release/release-notes-v159-20260307.md') | Should -Be $true
  }

  It 'validates live manual command references and archive markers on the repo' {
    $scriptPath = Join-Path $script:WorkspaceRoot '.Rayman\scripts\agents\validate_manual_command_contracts.ps1'
    $result = & $scriptPath -WorkspaceRoot $script:WorkspaceRoot -AsJson | ConvertFrom-Json

    $result.passed | Should -Be $true
    ([int]$result.failure_count) | Should -Be 0
    (@($result.checks | Where-Object { [string]$_.name -like '.Rayman/release/*' })).Count | Should -BeGreaterThan 0
  }
}
