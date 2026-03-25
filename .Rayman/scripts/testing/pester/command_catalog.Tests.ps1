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
    ($names -contains 'self-check') | Should -Be $true
    ($names -contains 'package') | Should -Be $true
    ($names -contains 'health') | Should -Be $true
    ($names -contains 'proxy-check') | Should -Be $true
  }

  It 'formats generated command docs with LF-only endings' {
    $commandsText = Get-RaymanCommandsText -WorkspaceRoot $script:WorkspaceRoot
    $readmeBlock = Get-RaymanReadmeCommandSection -WorkspaceRoot $script:WorkspaceRoot

    $commandsText.Contains("`r") | Should -Be $false
    $readmeBlock.Contains("`r") | Should -Be $false
  }

  It 'shows pwsh-only compatibility aliases in pwsh help' {
    $helpText = Format-RaymanHelpText -WorkspaceRoot $script:WorkspaceRoot -Surface pwsh

    $helpText | Should -Match 'self-check'
    $helpText | Should -Match 'package'
    $helpText | Should -Match 'health'
    $helpText | Should -Match 'proxy-check'
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
}
