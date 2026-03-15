Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  . (Join-Path $script:WorkspaceRoot '.Rayman\scripts\utils\command_catalog.ps1')
}

Describe 'command catalog' {
  It 'imports command entries as a stable array' {
    $catalog = @(Import-RaymanCommandCatalog -WorkspaceRoot $script:WorkspaceRoot)

    $catalog.Count | Should -BeGreaterThan 0
    $catalog[0].name | Should -Not -BeNullOrEmpty
    $catalog[0].platform | Should -Not -BeNullOrEmpty
  }

  It 'formats pwsh help text from the catalog' {
    $helpText = Format-RaymanHelpText -WorkspaceRoot $script:WorkspaceRoot -Surface pwsh

    $helpText | Should -Match 'Rayman CLI \(v160\)'
    $helpText | Should -Match 'rayman\.ps1'
  }
}
