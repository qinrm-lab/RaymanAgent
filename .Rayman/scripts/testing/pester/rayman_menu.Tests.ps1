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
    'Get-RaymanCliTokenName',
    'Test-RaymanCliTokenMatches',
    'ConvertTo-RaymanBoolValue',
    'Get-RaymanMenuStatePath',
    'Get-RaymanLastMenuChoice',
    'Set-RaymanLastMenuChoice',
    'Get-RaymanInteractiveMenuDefaultArgs',
    'Get-RaymanInteractiveMenuEntries',
    'Resolve-RaymanDefaultMenuItem',
    'Resolve-RaymanInteractiveMenuSelection',
    'Show-RaymanInteractiveMenu',
    'Test-RaymanInteractiveConsoleAvailable',
    'Test-RaymanShouldEnterCodexMenu',
    'Test-RaymanCliDoneAlertSuppressed'
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

      ($commands -contains 'package-dist') | Should -Be $true
      ($commands -contains 'health-check') | Should -Be $true
      ($commands -contains 'one-click-health') | Should -Be $true
      ($commands -contains 'codex') | Should -Be $true
      ($commands -contains 'workspace-install') | Should -Be $true
      ($commands -contains 'workspace-register') | Should -Be $true
      ($commands -contains 'interaction-mode') | Should -Be $true
      ($commands -contains 'sound-check') | Should -Be $true
      ($commands -contains 'version') | Should -Be $true
      ($commands -contains 'newversion') | Should -Be $true
      ($commands -contains 'req-ts-backfill') | Should -Be $false
      ($commands -contains 'worker-export') | Should -Be $false
      ($commands -contains 'self-check') | Should -Be $false
      ($commands -contains 'copy-check') | Should -Be $false
      ($commands -contains 'package') | Should -Be $false
      ($commands -contains 'health') | Should -Be $false
      ($commands -contains 'proxy-check') | Should -Be $false
      ($commands -contains 'interactive') | Should -Be $false
  }

  It 'persists and shows the workspace interaction mode through the CLI command' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_menu_interaction_' + [Guid]::NewGuid().ToString('N'))
    $envBackup = [Environment]::GetEnvironmentVariable('RAYMAN_ALERTS_ENABLED')
    $interactionBackup = [Environment]::GetEnvironmentVariable('RAYMAN_INTERACTION_MODE')
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\config') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\skills') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\utils') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\templates') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\skills') | Out-Null
      Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\rayman.ps1') -Destination (Join-Path $root '.Rayman\rayman.ps1')
      Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\common.ps1') -Destination (Join-Path $root '.Rayman\common.ps1')
      Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\skills\inject_codex_fix_prompt.ps1') -Destination (Join-Path $root '.Rayman\scripts\skills\inject_codex_fix_prompt.ps1')
      Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\skills\detect_skills.ps1') -Destination (Join-Path $root '.Rayman\scripts\skills\detect_skills.ps1')
      Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\utils\generate_context.ps1') -Destination (Join-Path $root '.Rayman\scripts\utils\generate_context.ps1')
      Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\utils\command_catalog.ps1') -Destination (Join-Path $root '.Rayman\scripts\utils\command_catalog.ps1')
      Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\templates\codex_fix_prompt.base.txt') -Destination (Join-Path $root '.Rayman\templates\codex_fix_prompt.base.txt')
      Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\skills\rules.json') -Destination (Join-Path $root '.Rayman\skills\rules.json')
      Set-Content -LiteralPath (Join-Path $root '.Rayman\config\command_catalog.tsv') -Encoding UTF8 -Value @'
# schema: rayman.command_catalog.v1
# columns: name<TAB>platform<TAB>group<TAB>summary<TAB>recommended
help	all	core	Show CLI help and platform tags.	0
interaction-mode	pwsh-only	core	Show or change the workspace interaction mode for plan-first ambiguity handling.	0
'@
      Set-Content -LiteralPath (Join-Path $root 'AGENTS.md') -Encoding UTF8 -Value '# temp'

      $psHost = (Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -First 1)
      if ($null -eq $psHost) {
        $psHost = (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1)
      }
      if ($null -eq $psHost -or [string]::IsNullOrWhiteSpace([string]$psHost.Source)) {
        Set-ItResult -Skipped -Because 'PowerShell host not found'
        return
      }

      [Environment]::SetEnvironmentVariable('RAYMAN_ALERTS_ENABLED', '0')
      [Environment]::SetEnvironmentVariable('RAYMAN_INTERACTION_MODE', $null)

      $raymanScript = Join-Path $root '.Rayman\rayman.ps1'
      $setCommand = "Remove-Item Env:RAYMAN_INTERACTION_MODE -ErrorAction SilentlyContinue; & '$raymanScript' interaction-mode --set general"
      $showCommand = "Remove-Item Env:RAYMAN_INTERACTION_MODE -ErrorAction SilentlyContinue; & '$raymanScript' interaction-mode --show"

      & $psHost.Source -NoProfile -ExecutionPolicy Bypass -Command $setCommand | Out-Null
      $LASTEXITCODE | Should -Be 0

      $envRaw = Get-Content -LiteralPath (Join-Path $root '.rayman.env.ps1') -Raw -Encoding UTF8
      $showOutput = & $psHost.Source -NoProfile -ExecutionPolicy Bypass -Command $showCommand 2>&1
      $LASTEXITCODE | Should -Be 0

      $envRaw | Should -Match 'RAYMAN_INTERACTION_MODE'
      $envRaw | Should -Match "RAYMAN_INTERACTION_MODE = 'general'"
      (@($showOutput) -join "`n") | Should -Match 'current=general'
      (Get-Content -LiteralPath (Join-Path $root '.Rayman\codex_fix_prompt.txt') -Raw -Encoding UTF8) | Should -Match '当前模式：一般（general）'
      (Get-Content -LiteralPath (Join-Path $root '.Rayman\CONTEXT.md') -Raw -Encoding UTF8) | Should -Match 'Mode: `general` \(一般\)'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_ALERTS_ENABLED', $envBackup)
      [Environment]::SetEnvironmentVariable('RAYMAN_INTERACTION_MODE', $interactionBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'dispatches workspace-install through the dedicated installer script' {
    $script:RaymanRaw | Should -Match '(?m)^\s+"workspace-install" \{ & "\$PSScriptRoot\\scripts\\workspace\\install_workspace\.ps1" -WorkspaceRoot .* -Action install @CliArgs; break \}'
  }

  It 'dispatches workspace-register through the dedicated registration script' {
    $script:RaymanRaw | Should -Match '(?m)^\s+"workspace-register" \{ & "\$PSScriptRoot\\scripts\\workspace\\register_workspace\.ps1"'
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

  It 'suppresses wrapper done alerts for codex flows in both pwsh and shell launchers' {
    $shellRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\rayman') -Raw -Encoding UTF8

    $script:RaymanRaw | Should -Match '(?m)^\s+''codex'' \{ return \$true \}$'
    $shellRaw | Should -Match 'copy-self-check\|codex'
    $shellRaw | Should -Not -Match 'copy-check\|codex'
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
