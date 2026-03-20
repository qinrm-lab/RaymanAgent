Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function script:Get-RaymanFunctionBlock {
  param(
    [string]$RawText,
    [string]$FunctionName
  )

  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($RawText, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) {
    throw ("rayman.ps1 parse failed: {0}" -f ($errors | ForEach-Object { $_.Message } | Select-Object -First 1))
  }

  $func = $ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -eq $FunctionName
    }, $true) | Select-Object -First 1
  if ($null -eq $func) {
    throw ("function not found: {0}" -f $FunctionName)
  }

  return [string]$func.Extent.Text
}

BeforeAll {
  $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  $script:RaymanRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\rayman.ps1') -Raw -Encoding UTF8
  . (Join-Path $script:RepoRoot '.Rayman\scripts\utils\command_catalog.ps1')

  foreach ($functionName in @(
    'Get-RaymanMenuStatePath',
    'Get-RaymanLastMenuChoice',
    'Set-RaymanLastMenuChoice',
    'Get-RaymanInteractiveMenuDefaultArgs',
    'Get-RaymanInteractiveMenuEntries',
    'Resolve-RaymanDefaultMenuItem',
    'Resolve-RaymanInteractiveMenuSelection',
    'Show-RaymanInteractiveMenu',
    'Test-RaymanInteractiveConsoleAvailable',
    'Test-RaymanShouldEnterCodexMenu'
  )) {
    Invoke-Expression (Get-RaymanFunctionBlock -RawText $script:RaymanRaw -FunctionName $functionName)
  }
}

Describe 'rayman interactive menu helpers' {
  It 'returns null for q/quit/exit without leaking title text into the result' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_menu_quit_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\config') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\config\command_catalog.tsv') -Encoding UTF8 -Value @'
# schema: rayman.command_catalog.v1
# columns: name<TAB>platform<TAB>group<TAB>summary<TAB>recommended
help	all	core	Show CLI help and platform tags.	0
init	all	core	Run full init (environment setup).	0
version	pwsh-only	release	Show managed version state and consistency.	0
'@

      $script:RaymanCliWorkspaceRoot = $root
      function global:Read-Host {
        param([string]$Prompt)
        return 'q'
      }

      $selection = Show-RaymanInteractiveMenu -WorkspaceRoot $root
      $resolved = Resolve-RaymanInteractiveMenuSelection -Selection $selection

      $null -eq $selection | Should -Be $true
      $null -eq $resolved | Should -Be $true
    } finally {
      Remove-Item function:\global:Read-Host -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'includes catalog-driven commands that were previously missing from the handwritten menu' {
    $script:RaymanCliWorkspaceRoot = $script:RepoRoot

    $entries = @(Get-RaymanInteractiveMenuEntries -WorkspaceRoot $script:RepoRoot)
    $commands = @($entries | ForEach-Object { [string]$_.Command })

      ($commands -contains 'req-ts-backfill') | Should -Be $true
      ($commands -contains 'package-dist') | Should -Be $true
      ($commands -contains 'health-check') | Should -Be $true
      ($commands -contains 'one-click-health') | Should -Be $true
      ($commands -contains 'codex') | Should -Be $true
      ($commands -contains 'version') | Should -Be $true
      ($commands -contains 'newversion') | Should -Be $true
  }

  It 'routes codex picked from the menu into the submenu by default without changing explicit subcommands' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_menu_codex_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\config') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\config\command_catalog.tsv') -Encoding UTF8 -Value @'
# schema: rayman.command_catalog.v1
# columns: name<TAB>platform<TAB>group<TAB>summary<TAB>recommended
help	all	core	Show CLI help and platform tags.	0
codex	all	automation	Manage Codex aliases.	1
'@

      $script:RaymanCliWorkspaceRoot = $root
      function global:Read-Host {
        param([string]$Prompt)
        return 'codex'
      }
      $selection = Show-RaymanInteractiveMenu -WorkspaceRoot $root
      [string]$selection.Command | Should -Be 'codex'
      @($selection.CliArgs) | Should -Be @('menu')

      Remove-Item function:\global:Read-Host -ErrorAction SilentlyContinue
      function global:Read-Host {
        param([string]$Prompt)
        return 'codex login --alias gpt-alt'
      }
      $explicitSelection = Show-RaymanInteractiveMenu -WorkspaceRoot $root
      [string]$explicitSelection.Command | Should -Be 'codex'
      @($explicitSelection.CliArgs) | Should -Be @('login', '--alias', 'gpt-alt')
    } finally {
      Remove-Item function:\global:Read-Host -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'only enters the codex submenu for bare interactive codex invocations' {
    Mock Test-RaymanInteractiveConsoleAvailable { return $true }
    (Test-RaymanShouldEnterCodexMenu -CommandName 'codex' -InputArgs @()) | Should -Be $true
    (Test-RaymanShouldEnterCodexMenu -CommandName 'codex' -InputArgs @('status', '--json')) | Should -Be $false
    (Test-RaymanShouldEnterCodexMenu -CommandName 'dispatch' -InputArgs @()) | Should -Be $false
  }

  It 'restores the default selection by command name before falling back to the old index' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_menu_restore_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\config') | Out-Null

      Set-Content -LiteralPath (Join-Path $root '.Rayman\config\command_catalog.tsv') -Encoding UTF8 -Value @'
# schema: rayman.command_catalog.v1
# columns: name<TAB>platform<TAB>group<TAB>summary<TAB>recommended
help	all	core	Show CLI help and platform tags.	0
version	pwsh-only	release	Show managed version state and consistency.	0
newversion	pwsh-only	release	Set the managed Rayman version across governed files.	0
package-dist	pwsh-only	release	Build the distributable .Rayman package.	0
'@
      $script:RaymanCliWorkspaceRoot = $root

      Set-RaymanLastMenuChoice -Index 2 -CommandName 'newversion' -CommandArgs @() -WorkspaceRoot $root

      Set-Content -LiteralPath (Join-Path $root '.Rayman\config\command_catalog.tsv') -Encoding UTF8 -Value @'
# schema: rayman.command_catalog.v1
# columns: name<TAB>platform<TAB>group<TAB>summary<TAB>recommended
help	all	core	Show CLI help and platform tags.	0
package-dist	pwsh-only	release	Build the distributable .Rayman package.	0
version	pwsh-only	release	Show managed version state and consistency.	0
newversion	pwsh-only	release	Set the managed Rayman version across governed files.	0
'@

      $entries = @(Get-RaymanInteractiveMenuEntries -WorkspaceRoot $root)
      $defaultItem = Resolve-RaymanDefaultMenuItem -MenuEntries $entries -WorkspaceRoot $root

      [string]$defaultItem.Command | Should -Be 'newversion'
      [int]$defaultItem.Index | Should -Be 3
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
