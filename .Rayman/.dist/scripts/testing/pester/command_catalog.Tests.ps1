Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  . (Join-Path $script:WorkspaceRoot '.Rayman\scripts\utils\command_catalog.ps1')
  $script:CurrentVersion = (Get-Content -LiteralPath (Join-Path $script:WorkspaceRoot '.Rayman\VERSION') -Raw -Encoding UTF8).Trim().ToLowerInvariant()
}

Describe 'command catalog' {
  It 'imports command entries as a stable array' {
    $catalog = @(Import-RaymanCommandCatalog -WorkspaceRoot $script:WorkspaceRoot)

    ($catalog.Count -gt 0) | Should -Be $true
    [string]::IsNullOrWhiteSpace([string]$catalog[0].name) | Should -Be $false
    [string]::IsNullOrWhiteSpace([string]$catalog[0].platform) | Should -Be $false
  }

  It 'formats pwsh help text from the catalog' {
    $helpText = Format-RaymanHelpText -WorkspaceRoot $script:WorkspaceRoot -Surface pwsh

    $helpText | Should -Match ("Rayman CLI \({0}\)" -f [regex]::Escape($script:CurrentVersion))
    $helpText | Should -Match 'rayman\.ps1'
  }

  It 'contains version management commands in the catalog' {
    $catalog = @(Import-RaymanCommandCatalog -WorkspaceRoot $script:WorkspaceRoot)
    $names = @($catalog | ForEach-Object { [string]$_.name })

    ($names -contains 'version') | Should -Be $true
    ($names -contains 'newversion') | Should -Be $true
    ($names -contains 'codex') | Should -Be $true
    ($names -contains 'worker') | Should -Be $true
    ($names -contains 'workspace-install') | Should -Be $true
    ($names -contains 'workspace-register') | Should -Be $true
    ($names -contains 'interaction-mode') | Should -Be $true
    ($names -contains 'sound-check') | Should -Be $true
    ($names -contains 'copy-self-check') | Should -Be $true
    ($names -contains 'package-dist') | Should -Be $true
    ($names -contains 'health-check') | Should -Be $true
    ($names -contains 'proxy-health') | Should -Be $true
    ($names -contains 'one-click-health') | Should -Be $true
    ($names -contains 'state-list') | Should -Be $true
    ($names -contains 'worktree-create') | Should -Be $true
    ($names -contains 'self-check') | Should -Be $false
    ($names -contains 'copy-check') | Should -Be $false
    ($names -contains 'package') | Should -Be $false
    ($names -contains 'health') | Should -Be $false
    ($names -contains '一键健康检查') | Should -Be $false
    ($names -contains 'proxy-check') | Should -Be $false
    ($names -contains 'worker-export') | Should -Be $false
    ($names -contains 'req-ts-backfill') | Should -Be $false
    ($names -contains 'interactive') | Should -Be $false
    ($names -contains 'alert-watch') | Should -Be $false
    ($names -contains 'alert-stop') | Should -Be $false
  }

  It 'formats generated command docs with LF-only endings' {
    $commandsText = Get-RaymanCommandsText -WorkspaceRoot $script:WorkspaceRoot
    $readmeBlock = Get-RaymanReadmeCommandSection -WorkspaceRoot $script:WorkspaceRoot

    $commandsText.Contains("`r") | Should -Be $false
    $readmeBlock.Contains("`r") | Should -Be $false
  }

  It 'shows only canonical command names in pwsh help' {
    $helpText = Format-RaymanHelpText -WorkspaceRoot $script:WorkspaceRoot -Surface pwsh

    $helpText | Should -Match 'copy-self-check'
    $helpText | Should -Match 'package-dist'
    $helpText | Should -Match 'health-check'
    $helpText | Should -Match 'proxy-health'
    $helpText | Should -Not -Match '(?m)^\s+self-check\s+\['
    $helpText | Should -Not -Match '(?m)^\s+copy-check\s+\['
    $helpText | Should -Not -Match '(?m)^\s+package\s+\['
    $helpText | Should -Not -Match '(?m)^\s+proxy-check\s+\['
    $helpText | Should -Not -Match '(?m)^\s+worker-export\s+\['
    $helpText | Should -Not -Match '(?m)^\s+req-ts-backfill\s+\['
    $helpText | Should -Not -Match '(?m)^\s+interactive\s+\['
  }

  It 'documents unified codex login mode flags in the README' {
    $readmeRaw = Get-Content -LiteralPath (Join-Path $script:WorkspaceRoot '.Rayman\README.md') -Raw -Encoding UTF8

    $readmeRaw | Should -Match 'rayman codex login --alias <alias> --mode web\|device\|api\|yunyi'
    $readmeRaw | Should -Match '--api-key-stdin'
  }

  It 'bridges public transfer handover commands through the bash entrypoint' {
    $catalog = @(Get-RaymanCommandCatalogEntriesForSurface -WorkspaceRoot $script:WorkspaceRoot -Surface bash)
    $bashNames = @($catalog | ForEach-Object { [string]$_.name })
    $bashRaw = Get-Content -LiteralPath (Join-Path $script:WorkspaceRoot '.Rayman\rayman') -Raw -Encoding UTF8

    ($bashNames -contains 'transfer-export') | Should -Be $true
    ($bashNames -contains 'transfer-import') | Should -Be $true
    $bashRaw | Should -Match 'transfer-export\)'
    $bashRaw | Should -Match 'transfer-import\)'
  }

  It 'keeps help, README, commands, and context aligned with the catalog' {
    $scriptPath = Join-Path $script:WorkspaceRoot '.Rayman\scripts\testing\verify_cli_parity.ps1'
    $result = & $scriptPath -WorkspaceRoot $script:WorkspaceRoot -AsJson | ConvertFrom-Json

    $result.success | Should -Be $true
  }

  It 'prints parity results in text mode without throwing' {
    $scriptPath = Join-Path $script:WorkspaceRoot '.Rayman\scripts\testing\verify_cli_parity.ps1'
    $psHost = (Get-Command powershell.exe -ErrorAction Stop | Select-Object -First 1).Source
    $output = & $psHost -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkspaceRoot $script:WorkspaceRoot 2>&1
    $exitCode = $LASTEXITCODE

    $exitCode | Should -Be 0
    (@($output) -join "`n") | Should -Match '\[PASS\] generated_docs - commands\.txt and README markers match command catalog'
  }
}
