Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  . (Join-Path $PSScriptRoot '..\..\..\common.ps1')
  . (Join-Path $PSScriptRoot '..\..\codex\manage_accounts.ps1') -NoMain
}

function script:New-TestCommandWrapper {
  param(
    [string]$Root,
    [string]$Name,
    [string]$ScriptBody
  )

  $implPath = Join-Path $Root ('{0}.impl.ps1' -f $Name)
  $wrapperPath = Join-Path $Root ('{0}.cmd' -f $Name)
  Set-Content -LiteralPath $implPath -Encoding UTF8 -Value $ScriptBody
  $pwsh = Get-Command 'pwsh' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $pwsh) {
    $pwsh = Get-Command 'powershell' -ErrorAction SilentlyContinue | Select-Object -First 1
  }
  if ($null -eq $pwsh) {
    throw 'pwsh/powershell not found for codex wrapper test'
  }

  $quotedImpl = $implPath.Replace("'", "''")
  Set-Content -LiteralPath $wrapperPath -Encoding ASCII -Value @"
@echo off
"$($pwsh.Source)" -NoProfile -ExecutionPolicy Bypass -Command "& '$quotedImpl' @args" -- %*
exit /b %ERRORLEVEL%
"@

  return $wrapperPath
}

function script:New-CodexTestWrapper {
  param(
    [string]$Root,
    [string]$ScriptBody
  )

  return (New-TestCommandWrapper -Root $Root -Name 'codex' -ScriptBody $ScriptBody)
}

function script:New-CodexPowerShellWrapper {
  param(
    [string]$Root,
    [string]$ScriptBody
  )

  $scriptPath = Join-Path $Root 'codex.ps1'
  Set-Content -LiteralPath $scriptPath -Encoding UTF8 -Value $ScriptBody
  return $scriptPath
}

function script:New-VsCodeBundledCodexWrapper {
  param(
    [string]$ExtensionsRoot,
    [string]$ExtensionName = 'openai.chatgpt-26.5318.11754-win32-x64',
    [string]$WrapperKind = 'cmd',
    [string]$ScriptBody
  )

  $binRoot = Join-Path (Join-Path $ExtensionsRoot $ExtensionName) 'bin\windows-x86_64'
  New-Item -ItemType Directory -Force -Path $binRoot | Out-Null

  switch ($WrapperKind) {
    'ps1' { return (New-CodexPowerShellWrapper -Root $binRoot -ScriptBody $ScriptBody) }
    default { return (New-CodexTestWrapper -Root $binRoot -ScriptBody $ScriptBody) }
  }
}

function script:New-NpmTestWrapper {
  param(
    [string]$Root,
    [string]$ScriptBody
  )

  return (New-TestCommandWrapper -Root $Root -Name 'npm' -ScriptBody $ScriptBody)
}

function script:New-VsCodeStorageState {
  param(
    [string]$AppDataRoot,
    [hashtable]$WorkspaceAssociations,
    [object[]]$Profiles = @(
      [ordered]@{ location = '-331173c2'; name = '秦瑞明'; icon = 'default' },
      [ordered]@{ location = '-58c37004'; name = '黎馨檄'; icon = 'default' },
      [ordered]@{ location = '-71d75b54'; name = 'Nemo'; icon = 'default' }
    )
  )

  $storagePath = Join-Path $AppDataRoot 'Code\User\globalStorage\storage.json'
  $storageDir = Split-Path -Parent $storagePath
  New-Item -ItemType Directory -Force -Path $storageDir | Out-Null

  $workspaces = [ordered]@{}
  foreach ($entry in $WorkspaceAssociations.GetEnumerator()) {
    $workspaces[[string]$entry.Key] = [string]$entry.Value
  }

  $payload = [ordered]@{
    userDataProfiles = @($Profiles)
    profileAssociations = [ordered]@{
      workspaces = $workspaces
    }
  }

  Set-Content -LiteralPath $storagePath -Encoding UTF8 -Value (($payload | ConvertTo-Json -Depth 8).TrimEnd() + "`n")
  return $storagePath
}

function script:Get-TestPathWithoutCodex {
  $paths = New-Object System.Collections.Generic.List[string]
  foreach ($name in @('cmd.exe', 'powershell.exe')) {
    $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
      continue
    }

    $directory = Split-Path -Parent ([string]$command.Source)
    if (-not [string]::IsNullOrWhiteSpace($directory) -and ($paths -notcontains $directory)) {
      $paths.Add($directory) | Out-Null
    }
  }

  return ([string[]]$paths -join ';')
}

Describe 'Rayman Codex account helpers' {
  BeforeEach {
    $script:envBackup = @{
      RAYMAN_HOME = [Environment]::GetEnvironmentVariable('RAYMAN_HOME')
      PATH = [Environment]::GetEnvironmentVariable('PATH')
      CODEX_HOME = [Environment]::GetEnvironmentVariable('CODEX_HOME')
      APPDATA = [Environment]::GetEnvironmentVariable('APPDATA')
      RAYMAN_CODEX_AUTO_UPDATE_ENABLED = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_ENABLED')
      RAYMAN_CODEX_AUTO_UPDATE_POLICY = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_POLICY')
      RAYMAN_VSCODE_EXTENSIONS_ROOT = [Environment]::GetEnvironmentVariable('RAYMAN_VSCODE_EXTENSIONS_ROOT')
      RAYMAN_NPM_GLOBAL_BIN_ROOT = [Environment]::GetEnvironmentVariable('RAYMAN_NPM_GLOBAL_BIN_ROOT')
    }

    [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_ENABLED', '0')
    [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_POLICY', 'off')
    [Environment]::SetEnvironmentVariable('RAYMAN_VSCODE_EXTENSIONS_ROOT', $null)
    $script:testNoNpmGlobalBinRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_no_npm_' + [Guid]::NewGuid().ToString('N'))
    [Environment]::SetEnvironmentVariable('RAYMAN_NPM_GLOBAL_BIN_ROOT', $script:testNoNpmGlobalBinRoot)
    $script:RaymanCodexCompatibilityCache = @{}
  }

  AfterEach {
    foreach ($entry in $script:envBackup.GetEnumerator()) {
      [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value)
    }
  }

  It 'creates isolated account homes and registry records under RAYMAN_HOME' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_state_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)

      $account = Ensure-RaymanCodexAccount -Alias 'work' -DefaultProfile 'dev' -SetDefaultProfile
      $registry = Get-RaymanCodexRegistry
      $configPath = Join-Path ([string]$account.codex_home) 'config.toml'

      [string]$account.alias | Should -Be 'work'
      [string]$account.default_profile | Should -Be 'dev'
      (Test-Path -LiteralPath $configPath -PathType Leaf) | Should -Be $true
      (Get-Content -LiteralPath $configPath -Raw -Encoding UTF8) | Should -Match 'cli_auth_credentials_store = "file"'
      ((ConvertTo-RaymanStringKeyMap -InputObject $registry.accounts).Contains('work')) | Should -Be $true
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'writes workspace trust into the alias config using a project-scoped projects section' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_trust_state_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)

      $account = Ensure-RaymanCodexAccount -Alias 'work'
      $result = Set-RaymanCodexWorkspaceTrust -Alias 'work' -WorkspaceRoot 'E:\rayman\software\RaymanAgent'
      $state = Get-RaymanCodexWorkspaceTrustState -Alias 'work' -WorkspaceRoot 'E:\rayman\software\RaymanAgent'
      $configRaw = Get-Content -LiteralPath (Join-Path ([string]$account.codex_home) 'config.toml') -Raw -Encoding UTF8

      [bool]$result.changed | Should -Be $true
      [string]$result.trust_level | Should -Be 'trusted'
      [bool]$state.present | Should -Be $true
      [string]$state.trust_level | Should -Be 'trusted'
      $configRaw | Should -Match '\[projects\."E:/rayman/software/RaymanAgent"\]'
      $configRaw | Should -Match 'trust_level = "trusted"'

      $second = Set-RaymanCodexWorkspaceTrust -Alias 'work' -WorkspaceRoot 'E:\rayman\software\RaymanAgent'
      [bool]$second.changed | Should -Be $false
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'writes workspace binding and de-duplicates equivalent Windows and WSL workspace records' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_workspace_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_workspace_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null

      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -Profile 'review' | Out-Null
      Set-RaymanCodexWorkspaceRecord -WorkspaceRoot 'E:\Rayman\Software\DemoRepo' -AccountAlias 'alpha' -Profile 'review' | Out-Null
      Set-RaymanCodexWorkspaceRecord -WorkspaceRoot '/mnt/e/Rayman/Software/DemoRepo' -AccountAlias 'beta' -Profile 'build' | Out-Null
      $registry = Get-RaymanCodexRegistry
      $envRaw = Get-Content -LiteralPath (Join-Path $workspaceRoot '.rayman.env.ps1') -Raw -Encoding UTF8

      $envRaw | Should -Match 'RAYMAN_CODEX_ACCOUNT_ALIAS'
      $envRaw | Should -Match 'RAYMAN_CODEX_PROFILE'
      $workspaceMap = ConvertTo-RaymanStringKeyMap -InputObject $registry.workspaces
      @($workspaceMap.Keys).Count | Should -Be 2
      $demoRecord = Get-RaymanCodexWorkspaceRecord -WorkspaceRoot 'E:\Rayman\Software\DemoRepo'
      [string]$demoRecord.last_account_alias | Should -Be 'beta'
      [string]$demoRecord.last_profile | Should -Be 'build'
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'offers stable login alias presets for main, existing aliases, gpt-alt, and custom input' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_login_rows_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_login_rows_workspace_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null

      Ensure-RaymanCodexAccount -Alias 'main' | Out-Null
      Ensure-RaymanCodexAccount -Alias 'myalias' | Out-Null
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'main' -Profile '' | Out-Null

      $rows = @(Get-LoginAliasRows -TargetWorkspaceRoot $workspaceRoot)
      $labels = @($rows | ForEach-Object { [string]$_.label })
      $mainRow = $rows | Where-Object { [string]$_.label -eq 'main' } | Select-Object -First 1

      $labels[0] | Should -Be 'main'
      @($labels | Where-Object { $_ -eq 'main' }).Count | Should -Be 1
      ($labels -contains 'myalias') | Should -Be $true
      ($labels -contains 'gpt-alt') | Should -Be $true
      ($labels -contains 'custom') | Should -Be $true
      (@([string[]]$mainRow.tags) -contains '当前绑定') | Should -Be $true
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'falls back to the newest VS Code bundled codex command when PATH does not contain codex' {
    $extensionsRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_vscode_ext_' + [Guid]::NewGuid().ToString('N'))
    try {
      $olderWrapper = New-VsCodeBundledCodexWrapper -ExtensionsRoot $extensionsRoot -ExtensionName 'openai.chatgpt-26.5000.10000-win32-x64' -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
if ($argv.Count -eq 1 -and $argv[0] -eq '--version') {
  Write-Output 'codex-cli 0.5.81-old'
  exit 0
}
Write-Output 'old'
exit 0
'@
      $newerWrapper = New-VsCodeBundledCodexWrapper -ExtensionsRoot $extensionsRoot -ExtensionName 'openai.chatgpt-26.6000.20000-win32-x64' -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
if ($argv.Count -eq 1 -and $argv[0] -eq '--version') {
  Write-Output 'codex-cli 0.5.82-new'
  exit 0
}
Write-Output 'new'
exit 0
'@
      (Get-Item (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $olderWrapper)))).LastWriteTime = [datetime]'2026-03-18T10:00:00'
      (Get-Item (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $newerWrapper)))).LastWriteTime = [datetime]'2026-03-19T10:00:00'
      [Environment]::SetEnvironmentVariable('RAYMAN_VSCODE_EXTENSIONS_ROOT', $extensionsRoot)
      [Environment]::SetEnvironmentVariable('PATH', (Get-TestPathWithoutCodex))

      $commandInfo = Get-RaymanCodexCommandInfo
      $versionResult = Invoke-RaymanCodexRawCapture -CodexHome '' -ArgumentList @('--version')

      [bool]$commandInfo.available | Should -Be $true
      [string]$commandInfo.resolution_source | Should -Be 'vscode_extension'
      [string]$commandInfo.path | Should -Be $newerWrapper
      [bool]$versionResult.success | Should -Be $true
      [string]$versionResult.output | Should -Match '0.5.82'
    } finally {
      Remove-Item -LiteralPath $extensionsRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'prefers a PATH codex command over the VS Code bundled fallback' {
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_path_first_bin_' + [Guid]::NewGuid().ToString('N'))
    $extensionsRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_path_first_ext_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
      $pathWrapper = New-CodexTestWrapper -Root $binRoot -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
Write-Output 'path-first'
exit 0
'@
      New-VsCodeBundledCodexWrapper -ExtensionsRoot $extensionsRoot -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
Write-Output 'fallback'
exit 0
'@ | Out-Null
      [Environment]::SetEnvironmentVariable('RAYMAN_VSCODE_EXTENSIONS_ROOT', $extensionsRoot)
      [Environment]::SetEnvironmentVariable('PATH', ($binRoot + ';' + (Get-TestPathWithoutCodex)))

      $commandInfo = Get-RaymanCodexCommandInfo
      $capture = Invoke-RaymanCodexRawCapture -CodexHome '' -ArgumentList @('whoami')

      [bool]$commandInfo.available | Should -Be $true
      [string]$commandInfo.resolution_source | Should -Be 'path'
      [string]$commandInfo.path | Should -Be $pathWrapper
      [string]$capture.output | Should -Match 'path-first'
    } finally {
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $extensionsRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'prefers npm-global codex over a VS Code bundled codex that appears on PATH' {
    $extensionsRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_prefer_npm_ext_' + [Guid]::NewGuid().ToString('N'))
    $npmBinRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_prefer_npm_bin_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $npmBinRoot | Out-Null
      $vscodeWrapper = New-VsCodeBundledCodexWrapper -ExtensionsRoot $extensionsRoot -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
Write-Output 'vscode-bundled'
exit 0
'@
      $npmWrapper = New-CodexTestWrapper -Root $npmBinRoot -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
Write-Output 'npm-global'
exit 0
'@
      [Environment]::SetEnvironmentVariable('RAYMAN_VSCODE_EXTENSIONS_ROOT', $extensionsRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_NPM_GLOBAL_BIN_ROOT', $npmBinRoot)
      [Environment]::SetEnvironmentVariable('PATH', ((Split-Path -Parent $vscodeWrapper) + ';' + (Get-TestPathWithoutCodex)))

      $commandInfo = Get-RaymanCodexCommandInfo
      $capture = Invoke-RaymanCodexRawCapture -CodexHome '' -ArgumentList @('whoami')

      [bool]$commandInfo.available | Should -Be $true
      [string]$commandInfo.resolution_source | Should -Be 'npm_global'
      [string]$commandInfo.path | Should -Be $npmWrapper
      [string]$capture.output | Should -Match 'npm-global'
    } finally {
      Remove-Item -LiteralPath $extensionsRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $npmBinRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'reports the enhanced not-found message after checking PATH and the VS Code bundled location' {
    $extensionsRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_not_found_ext_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $extensionsRoot | Out-Null
      [Environment]::SetEnvironmentVariable('RAYMAN_VSCODE_EXTENSIONS_ROOT', $extensionsRoot)
      [Environment]::SetEnvironmentVariable('PATH', (Get-TestPathWithoutCodex))

      $status = Get-RaymanCodexCliCompatibilityStatus -WorkspaceRoot $extensionsRoot -ForceRefresh

      [bool]$status.compatible | Should -Be $false
      [string]$status.reason | Should -Be 'codex_command_not_found'
      [string]$status.output | Should -Match 'Checked PATH and VS Code ChatGPT extension bundled codex location'
    } finally {
      Remove-Item -LiteralPath $extensionsRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'updates alias default profile without overwriting explicit workspace bindings' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_profile_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceExplicit = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_profile_explicit_' + [Guid]::NewGuid().ToString('N'))
    $workspaceInherited = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_profile_inherited_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceExplicit | Out-Null
      New-Item -ItemType Directory -Force -Path $workspaceInherited | Out-Null

      Ensure-RaymanCodexAccount -Alias 'alpha' -DefaultProfile 'review' -SetDefaultProfile | Out-Null
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceExplicit -AccountAlias 'alpha' -Profile 'explicit' | Out-Null
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceInherited -AccountAlias 'alpha' -Profile '' | Out-Null

      $updated = Set-RaymanCodexAccountDefaultProfile -Alias 'alpha' -DefaultProfile 'ops'
      $explicitContext = Resolve-RaymanCodexContext -WorkspaceRoot $workspaceExplicit
      $inheritedContext = Resolve-RaymanCodexContext -WorkspaceRoot $workspaceInherited
      $explicitBinding = Get-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceExplicit

      [string]$updated.default_profile | Should -Be 'ops'
      [string]$explicitBinding.profile | Should -Be 'explicit'
      [string]$explicitContext.effective_profile | Should -Be 'explicit'
      [string]$inheritedContext.effective_profile | Should -Be 'ops'
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceExplicit -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceInherited -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'safely deletes an alias while clearing known workspace references and keeping CODEX_HOME' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_delete_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_delete_workspace_' + [Guid]::NewGuid().ToString('N'))
    $missingWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_delete_missing_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null

      $account = Ensure-RaymanCodexAccount -Alias 'alpha' -DefaultProfile 'review' -SetDefaultProfile
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -Profile 'review' | Out-Null
      Set-RaymanCodexWorkspaceRecord -WorkspaceRoot $missingWorkspace -AccountAlias 'alpha' -Profile 'ops' | Out-Null

      $removed = Remove-RaymanCodexAlias -Alias 'alpha'
      $registry = Get-RaymanCodexRegistry
      $binding = Get-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot
      $missingRecord = Get-RaymanCodexWorkspaceRecord -WorkspaceRoot $missingWorkspace

      [bool]$removed.removed | Should -Be $true
      ((ConvertTo-RaymanStringKeyMap -InputObject $registry.accounts).Contains('alpha')) | Should -Be $false
      [string]$binding.account_alias | Should -Be ''
      [string]$binding.profile | Should -Be ''
      [string]$missingRecord.last_account_alias | Should -Be ''
      [string]$missingRecord.last_profile | Should -Be ''
      (Test-Path -LiteralPath ([string]$account.codex_home) -PathType Container) | Should -Be $true
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $missingWorkspace -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'hard deletes an alias home after clearing registry state' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_delete_hard_state_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      $account = Ensure-RaymanCodexAccount -Alias 'alpha'

      $removed = Remove-RaymanCodexAlias -Alias 'alpha' -DeleteHome

      [bool]$removed.removed | Should -Be $true
      [bool]$removed.deleted_home | Should -Be $true
      (Test-Path -LiteralPath ([string]$account.codex_home) -PathType Container) | Should -Be $false
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'dispatches codex submenu actions to the existing handlers' {
    Mock Invoke-ActionStatus {}
    Mock Invoke-ActionList {}
    Mock Invoke-ActionLogin {}
    Mock Invoke-ActionSwitch {}
    Mock Invoke-CodexManageAlias {}
    Mock Invoke-ActionRunFromMenu {}
    Mock Invoke-ActionUpgrade { return [pscustomobject]@{ success = $true } }

    Invoke-CodexMenuAction -MenuAction 'status' -TargetWorkspaceRoot 'E:\repo' -Picker 'menu'
    Invoke-CodexMenuAction -MenuAction 'list' -TargetWorkspaceRoot 'E:\repo' -Picker 'menu'
    Invoke-CodexMenuAction -MenuAction 'login' -TargetWorkspaceRoot 'E:\repo' -Picker 'menu'
    Invoke-CodexMenuAction -MenuAction 'switch' -TargetWorkspaceRoot 'E:\repo' -Picker 'menu'
    Invoke-CodexMenuAction -MenuAction 'manage' -TargetWorkspaceRoot 'E:\repo' -Picker 'menu'
    Invoke-CodexMenuAction -MenuAction 'run' -TargetWorkspaceRoot 'E:\repo' -Picker 'menu'
    Invoke-CodexMenuAction -MenuAction 'upgrade' -TargetWorkspaceRoot 'E:\repo' -Picker 'menu'

    Assert-MockCalled Invoke-ActionStatus -Exactly 1 -ParameterFilter { $TargetWorkspaceRoot -eq 'E:\repo' }
    Assert-MockCalled Invoke-ActionList -Exactly 1
    Assert-MockCalled Invoke-ActionLogin -Exactly 1 -ParameterFilter { $TargetWorkspaceRoot -eq 'E:\repo' -and $Picker -eq 'menu' }
    Assert-MockCalled Invoke-ActionSwitch -Exactly 1 -ParameterFilter { $TargetWorkspaceRoot -eq 'E:\repo' -and $Picker -eq 'menu' }
    Assert-MockCalled Invoke-CodexManageAlias -Exactly 1 -ParameterFilter { $TargetWorkspaceRoot -eq 'E:\repo' -and $Picker -eq 'menu' }
    Assert-MockCalled Invoke-ActionRunFromMenu -Exactly 1 -ParameterFilter { $TargetWorkspaceRoot -eq 'E:\repo' }
    Assert-MockCalled Invoke-ActionUpgrade -Exactly 1 -ParameterFilter { $TargetWorkspaceRoot -eq 'E:\repo' }
  }

  It 'reuses the existing CODEX_HOME when re-running device auth for an alias' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_relogin_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_relogin_workspace_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      $account = Ensure-RaymanCodexAccount -Alias 'alpha'

      Mock Ensure-CodexCliReady {}
      Mock Invoke-RaymanCodexRawInteractive {
        return [pscustomobject]@{ success = $true; exit_code = 0 }
      } -ParameterFilter { $CodexHome -eq [string]$account.codex_home -and $PreferHiddenWindow -and $ArgumentList.Count -eq 2 -and $ArgumentList[0] -eq 'login' -and $ArgumentList[1] -eq '--device-auth' }
      Mock Get-RaymanCodexLoginStatus {
        return [pscustomobject]@{ authenticated = $true; status = 'authenticated' }
      }

      $result = Invoke-CodexAliasDeviceAuth -Alias 'alpha' -TargetWorkspaceRoot $workspaceRoot

      [string]$result.alias | Should -Be 'alpha'
      Assert-MockCalled Invoke-RaymanCodexRawInteractive -Exactly 1 -ParameterFilter { $CodexHome -eq [string]$account.codex_home -and $PreferHiddenWindow }
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'falls back to the foreground device auth flow when hidden launch fails on Windows' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_hidden_fallback_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_hidden_fallback_workspace_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      $account = Ensure-RaymanCodexAccount -Alias 'alpha'

      Mock Ensure-CodexCliReady {}
      Mock Test-RaymanWindowsPlatform { return $true }
      Mock Invoke-RaymanCodexRawInteractive {
        if ($PreferHiddenWindow) {
          return [pscustomobject]@{ success = $false; exit_code = 1 }
        }
        return [pscustomobject]@{ success = $true; exit_code = 0 }
      } -ParameterFilter { $CodexHome -eq [string]$account.codex_home -and $ArgumentList.Count -eq 2 -and $ArgumentList[0] -eq 'login' -and $ArgumentList[1] -eq '--device-auth' }
      Mock Get-RaymanCodexLoginStatus {
        return [pscustomobject]@{ authenticated = $true; status = 'authenticated' }
      }

      $result = Invoke-CodexAliasDeviceAuth -Alias 'alpha' -TargetWorkspaceRoot $workspaceRoot

      [string]$result.alias | Should -Be 'alpha'
      Assert-MockCalled Invoke-RaymanCodexRawInteractive -Exactly 1 -ParameterFilter { $CodexHome -eq [string]$account.codex_home -and $PreferHiddenWindow }
      Assert-MockCalled Invoke-RaymanCodexRawInteractive -Exactly 1 -ParameterFilter { $CodexHome -eq [string]$account.codex_home -and -not $PreferHiddenWindow }
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'injects workspace profile unless the caller already passed one' {
    $injected = @(Add-RaymanCodexProfileArguments -ArgumentList @('exec', '-C', 'repo', 'hello') -Profile 'review')
    $explicit = @(Add-RaymanCodexProfileArguments -ArgumentList @('--profile', 'ops', 'exec', 'hello') -Profile 'review')

    $injected[0] | Should -Be '--profile'
    $injected[1] | Should -Be 'review'
    ($explicit -join ' ') | Should -Be '--profile ops exec hello'
  }

  It 'resolves hidden interactive invocation through cmd.exe for cmd wrappers' {
    $cmdInvocation = Resolve-RaymanCodexInteractiveInvocation -CodexCommand ([pscustomobject]@{
        available = $true
        path = 'C:\Users\qinrm\AppData\Roaming\npm\codex.cmd'
      }) -ArgumentList @('login', '--device-auth')

    [bool]$cmdInvocation.available | Should -Be $true
    [string]$cmdInvocation.file_path | Should -Match 'cmd(\.exe)?$'
    @($cmdInvocation.argument_list)[0] | Should -Be '/d'
    @($cmdInvocation.argument_list)[1] | Should -Be '/c'
    @($cmdInvocation.argument_list)[2] | Should -Match 'codex\.cmd'
  }

  It 'resolves the active VS Code user profile from local workspace associations' {
    $appDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_appdata_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('APPDATA', $appDataRoot)
      New-VsCodeStorageState -AppDataRoot $appDataRoot -WorkspaceAssociations @{
        'file:///e%3A/rayman/software/RaymanAgent' = '-331173c2'
      } | Out-Null

      $state = Get-RaymanVsCodeUserProfileState -WorkspaceRoot 'E:\rayman\software\RaymanAgent'

      [bool]$state.available | Should -Be $true
      [bool]$state.profile_detected | Should -Be $true
      [string]$state.profile_name | Should -Be '秦瑞明'
      [string]$state.profile_location | Should -Be '-331173c2'
      [string]$state.status | Should -Be 'workspace_profile_detected'
      [string]$state.matched_workspace_uri | Should -Be 'file:///e%3A/rayman/software/RaymanAgent'
      @($state.profiles).Count | Should -Be 3
    } finally {
      Remove-Item -LiteralPath $appDataRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'resolves the active VS Code user profile from WSL workspace associations' {
    $appDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_appdata_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('APPDATA', $appDataRoot)
      New-VsCodeStorageState -AppDataRoot $appDataRoot -WorkspaceAssociations @{
        'vscode-remote://wsl+Ubuntu/mnt/e/rayman/software/RaymanAgent' = '-331173c2'
      } | Out-Null

      $state = Get-RaymanVsCodeUserProfileState -WorkspaceRoot '/mnt/e/rayman/software/RaymanAgent'

      [bool]$state.profile_detected | Should -Be $true
      [string]$state.profile_name | Should -Be '秦瑞明'
      [string]$state.matched_workspace_uri | Should -Be 'vscode-remote://wsl+Ubuntu/mnt/e/rayman/software/RaymanAgent'
    } finally {
      Remove-Item -LiteralPath $appDataRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'defaults login alias selection to the main preset on blank input' {
    $appDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_appdata_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_login_default_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('APPDATA', $appDataRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      Ensure-RaymanCodexAccount -Alias 'main' | Out-Null
      Ensure-RaymanCodexAccount -Alias 'myalias' | Out-Null
      Ensure-RaymanCodexAccount -Alias 'gpt-alt' | Out-Null
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'main' -Profile '' | Out-Null
      $workspaceUri = ([System.Uri](Resolve-Path $workspaceRoot | Select-Object -ExpandProperty Path)).AbsoluteUri
      New-VsCodeStorageState -AppDataRoot $appDataRoot -WorkspaceAssociations @{
        $workspaceUri = '-331173c2'
      } | Out-Null

      Mock -CommandName Test-InteractiveInputAvailable -MockWith { $true }
      Mock -CommandName Read-Host -MockWith { '' }
      $selection = Resolve-LoginAliasChoice -Alias '' -TargetWorkspaceRoot $workspaceRoot -Picker 'menu'

      [string]$selection.alias | Should -Be 'main'
      [string]$selection.alias_source | Should -Be 'menu'
    } finally {
      Remove-Item -LiteralPath $appDataRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'allows choosing a different preset alias from the login menu' {
    $appDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_appdata_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_login_pick_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('APPDATA', $appDataRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      Ensure-RaymanCodexAccount -Alias 'main' | Out-Null
      Ensure-RaymanCodexAccount -Alias 'myalias' | Out-Null
      Ensure-RaymanCodexAccount -Alias 'gpt-alt' | Out-Null
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'main' -Profile '' | Out-Null
      $workspaceUri = ([System.Uri](Resolve-Path $workspaceRoot | Select-Object -ExpandProperty Path)).AbsoluteUri
      New-VsCodeStorageState -AppDataRoot $appDataRoot -WorkspaceAssociations @{
        $workspaceUri = '-331173c2'
      } | Out-Null

      $rows = @(Get-LoginAliasRows -TargetWorkspaceRoot $workspaceRoot)
      $labels = @($rows | ForEach-Object { [string]$_.label })
      $targetIndex = [array]::IndexOf($labels, 'gpt-alt') + 1
      $targetIndex | Should -BeGreaterThan 0

      Mock -CommandName Test-InteractiveInputAvailable -MockWith { $true }
      Mock -CommandName Read-Host -MockWith { [string]$targetIndex }
      $selection = Resolve-LoginAliasChoice -Alias '' -TargetWorkspaceRoot $workspaceRoot -Picker 'menu'

      [string]$selection.alias | Should -Be 'gpt-alt'
      [string]$selection.alias_source | Should -Be 'menu'
    } finally {
      Remove-Item -LiteralPath $appDataRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'honors an explicit alias without prompting for VS Code user profile selection' {
    $appDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_appdata_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('APPDATA', $appDataRoot)
      New-VsCodeStorageState -AppDataRoot $appDataRoot -WorkspaceAssociations @{
        'file:///e%3A/rayman/software/RaymanAgent' = '-331173c2'
      } | Out-Null

      $selection = Resolve-LoginAliasChoice -Alias 'main' -TargetWorkspaceRoot 'E:\rayman\software\RaymanAgent' -Picker 'menu'

      [string]$selection.alias | Should -Be 'main'
      [string]$selection.alias_source | Should -Be 'explicit'
    } finally {
      Remove-Item -LiteralPath $appDataRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'compatibility policy auto-updates codex-cli when the installed CLI is incompatible with Rayman config' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_compat_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_compat_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_compat_bin_' + [Guid]::NewGuid().ToString('N'))
    $toolRoot = Join-Path $binRoot 'npm'
    $markerPath = Join-Path $binRoot 'codex.updated'
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_ENABLED', $null)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_POLICY', 'compatibility')
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null

      $quotedMarkerPath = $markerPath.Replace("'", "''")
      New-CodexTestWrapper -Root $toolRoot -ScriptBody @"
param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$argv)
`$markerPath = '$quotedMarkerPath'
`$updated = Test-Path -LiteralPath `$markerPath
if (`$argv.Count -eq 1 -and `$argv[0] -eq '--version') {
  if (`$updated) {
    Write-Output 'codex-cli 0.5.80'
  } else {
    Write-Output 'codex-cli 0.47.0'
  }
  exit 0
}
if (`$argv.Count -ge 2 -and `$argv[0] -eq 'features' -and `$argv[1] -eq 'list') {
  if (`$updated) {
    Write-Output 'feature_a alpha true'
    exit 0
  }
  Write-Output 'unknown variant xhigh for key model_reasoning_effort'
  exit 1
}
Write-Output 'ok'
exit 0
"@ | Out-Null

      New-NpmTestWrapper -Root $toolRoot -ScriptBody @"
param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$argv)
`$markerPath = '$quotedMarkerPath'
if (`$argv.Count -ge 3 -and `$argv[0] -eq 'install' -and `$argv[1] -eq '-g' -and `$argv[2] -eq '@openai/codex') {
  New-Item -ItemType File -Force -Path `$markerPath | Out-Null
  Write-Output 'updated'
  exit 0
}
Write-Output ('unexpected npm args: ' + (`$argv -join ' '))
exit 1
"@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', ($toolRoot + ';' + [Environment]::GetEnvironmentVariable('PATH')))
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null

      $result = Ensure-RaymanCodexCliUpToDate -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -ForceRefresh

      [bool]$result.success | Should -Be $true
      [bool]$result.compatible | Should -Be $true
      [bool]$result.updated | Should -Be $true
      [string]$result.reason | Should -Be 'compatibility_auto_updated'
      [bool]$result.latest_check_attempted | Should -Be $false
      [string]$result.version_before | Should -Be '0.47.0'
      [string]$result.version_after | Should -Be '0.5.80'
      (Test-Path -LiteralPath $markerPath -PathType Leaf) | Should -Be $true
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'compatibility policy does not update a compatible codex-cli that is behind npm latest' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_policy_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_policy_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_policy_bin_' + [Guid]::NewGuid().ToString('N'))
    $toolRoot = Join-Path $binRoot 'npm'
    $markerPath = Join-Path $binRoot 'codex.updated'
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_ENABLED', $null)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_POLICY', 'compatibility')
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null

      $quotedMarkerPath = $markerPath.Replace("'", "''")
      New-CodexTestWrapper -Root $toolRoot -ScriptBody @"
param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$argv)
if (`$argv.Count -eq 1 -and `$argv[0] -eq '--version') {
  Write-Output 'codex-cli 0.5.80'
  exit 0
}
if (`$argv.Count -ge 2 -and `$argv[0] -eq 'features' -and `$argv[1] -eq 'list') {
  Write-Output 'feature_a alpha true'
  exit 0
}
Write-Output 'ok'
exit 0
"@ | Out-Null

      New-NpmTestWrapper -Root $toolRoot -ScriptBody @"
param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$argv)
`$markerPath = '$quotedMarkerPath'
if (`$argv.Count -ge 1) {
  New-Item -ItemType File -Force -Path `$markerPath | Out-Null
  Write-Output ('unexpected npm args: ' + (`$argv -join ' '))
  exit 1
}
exit 0
"@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', ($toolRoot + ';' + [Environment]::GetEnvironmentVariable('PATH')))
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null

      $result = Ensure-RaymanCodexCliUpToDate -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -ForceRefresh

      [bool]$result.success | Should -Be $true
      [bool]$result.compatible | Should -Be $true
      [bool]$result.updated | Should -Be $false
      [bool]$result.latest_check_attempted | Should -Be $false
      [string]$result.reason | Should -Be 'feature_probe_ok'
      (Test-Path -LiteralPath $markerPath -PathType Leaf) | Should -Be $false
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'latest policy auto-updates codex-cli when the installed CLI is behind npm latest' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_latest_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_latest_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_latest_bin_' + [Guid]::NewGuid().ToString('N'))
    $toolRoot = Join-Path $binRoot 'npm'
    $markerPath = Join-Path $binRoot 'codex.updated'
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_ENABLED', $null)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_POLICY', 'latest')
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null

      $quotedMarkerPath = $markerPath.Replace("'", "''")
      New-CodexTestWrapper -Root $toolRoot -ScriptBody @"
param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$argv)
`$markerPath = '$quotedMarkerPath'
`$updated = Test-Path -LiteralPath `$markerPath
if (`$argv.Count -eq 1 -and `$argv[0] -eq '--version') {
  if (`$updated) {
    Write-Output 'codex-cli 0.6.10'
  } else {
    Write-Output 'codex-cli 0.5.80'
  }
  exit 0
}
if (`$argv.Count -ge 2 -and `$argv[0] -eq 'features' -and `$argv[1] -eq 'list') {
  Write-Output 'feature_a alpha true'
  exit 0
}
Write-Output 'ok'
exit 0
"@ | Out-Null

      New-NpmTestWrapper -Root $toolRoot -ScriptBody @"
param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$argv)
`$markerPath = '$quotedMarkerPath'
if (`$argv.Count -ge 3 -and `$argv[0] -eq 'view' -and `$argv[1] -eq '@openai/codex' -and `$argv[2] -eq 'version') {
  Write-Output '0.6.10'
  exit 0
}
if (`$argv.Count -ge 3 -and `$argv[0] -eq 'install' -and `$argv[1] -eq '-g' -and `$argv[2] -eq '@openai/codex') {
  New-Item -ItemType File -Force -Path `$markerPath | Out-Null
  Write-Output 'updated'
  exit 0
}
Write-Output ('unexpected npm args: ' + (`$argv -join ' '))
exit 1
"@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', ($toolRoot + ';' + [Environment]::GetEnvironmentVariable('PATH')))
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null

      $result = Ensure-RaymanCodexCliUpToDate -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -ForceRefresh

      [bool]$result.success | Should -Be $true
      [bool]$result.compatible | Should -Be $true
      [bool]$result.updated | Should -Be $true
      [bool]$result.latest_check_attempted | Should -Be $true
      [bool]$result.latest_check_succeeded | Should -Be $true
      [string]$result.reason | Should -Be 'updated_to_latest'
      [string]$result.version_before | Should -Be '0.5.80'
      [string]$result.latest_version | Should -Be '0.6.10'
      [string]$result.version_after | Should -Be '0.6.10'
      (Test-Path -LiteralPath $markerPath -PathType Leaf) | Should -Be $true
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'off policy leaves an incompatible codex-cli untouched' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_off_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_off_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_off_bin_' + [Guid]::NewGuid().ToString('N'))
    $toolRoot = Join-Path $binRoot 'npm'
    $markerPath = Join-Path $binRoot 'codex.updated'
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_ENABLED', $null)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_POLICY', 'off')
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null

      $quotedMarkerPath = $markerPath.Replace("'", "''")
      New-CodexTestWrapper -Root $toolRoot -ScriptBody @"
param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$argv)
if (`$argv.Count -eq 1 -and `$argv[0] -eq '--version') {
  Write-Output 'codex-cli 0.47.0'
  exit 0
}
if (`$argv.Count -ge 2 -and `$argv[0] -eq 'features' -and `$argv[1] -eq 'list') {
  Write-Output 'unknown variant xhigh for key model_reasoning_effort'
  exit 1
}
Write-Output 'ok'
exit 0
"@ | Out-Null

      New-NpmTestWrapper -Root $toolRoot -ScriptBody @"
param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$argv)
`$markerPath = '$quotedMarkerPath'
New-Item -ItemType File -Force -Path `$markerPath | Out-Null
Write-Output ('unexpected npm args: ' + (`$argv -join ' '))
exit 1
"@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', ($toolRoot + ';' + [Environment]::GetEnvironmentVariable('PATH')))
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null

      $result = Ensure-RaymanCodexCliUpToDate -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -ForceRefresh

      [bool]$result.success | Should -Be $false
      [bool]$result.compatible | Should -Be $false
      [bool]$result.updated | Should -Be $false
      [string]$result.reason | Should -Be 'policy_off'
      [string]$result.version_before | Should -Be '0.47.0'
      (Test-Path -LiteralPath $markerPath -PathType Leaf) | Should -Be $false
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'latest policy keeps going when npm latest lookup fails but the current CLI is compatible' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_latest_fail_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_latest_fail_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_latest_fail_bin_' + [Guid]::NewGuid().ToString('N'))
    $toolRoot = Join-Path $binRoot 'npm'
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_ENABLED', $null)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_POLICY', 'latest')
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null

      New-CodexTestWrapper -Root $toolRoot -ScriptBody @"
param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$argv)
if (`$argv.Count -eq 1 -and `$argv[0] -eq '--version') {
  Write-Output 'codex-cli 0.5.80'
  exit 0
}
if (`$argv.Count -ge 2 -and `$argv[0] -eq 'features' -and `$argv[1] -eq 'list') {
  Write-Output 'feature_a alpha true'
  exit 0
}
Write-Output 'ok'
exit 0
"@ | Out-Null

      New-NpmTestWrapper -Root $toolRoot -ScriptBody @"
param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$argv)
Write-Output 'registry unavailable'
exit 1
"@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', ($toolRoot + ';' + [Environment]::GetEnvironmentVariable('PATH')))
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null

      $result = Ensure-RaymanCodexCliUpToDate -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -ForceRefresh

      [bool]$result.success | Should -Be $true
      [bool]$result.compatible | Should -Be $true
      [bool]$result.updated | Should -Be $false
      [bool]$result.latest_check_attempted | Should -Be $true
      [bool]$result.latest_check_succeeded | Should -Be $false
      [string]$result.reason | Should -Be 'latest_check_failed_nonblocking'
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'latest policy falls back to compatibility auto-update when npm latest lookup fails and the CLI is incompatible' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_latest_fb_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_latest_fb_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_latest_fb_bin_' + [Guid]::NewGuid().ToString('N'))
    $toolRoot = Join-Path $binRoot 'npm'
    $markerPath = Join-Path $binRoot 'codex.updated'
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_ENABLED', $null)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_POLICY', 'latest')
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null

      $quotedMarkerPath = $markerPath.Replace("'", "''")
      New-CodexTestWrapper -Root $toolRoot -ScriptBody @"
param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$argv)
`$markerPath = '$quotedMarkerPath'
`$updated = Test-Path -LiteralPath `$markerPath
if (`$argv.Count -eq 1 -and `$argv[0] -eq '--version') {
  if (`$updated) {
    Write-Output 'codex-cli 0.5.80'
  } else {
    Write-Output 'codex-cli 0.47.0'
  }
  exit 0
}
if (`$argv.Count -ge 2 -and `$argv[0] -eq 'features' -and `$argv[1] -eq 'list') {
  if (`$updated) {
    Write-Output 'feature_a alpha true'
    exit 0
  }
  Write-Output 'unknown variant xhigh for key model_reasoning_effort'
  exit 1
}
Write-Output 'ok'
exit 0
"@ | Out-Null

      New-NpmTestWrapper -Root $toolRoot -ScriptBody @"
param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$argv)
`$markerPath = '$quotedMarkerPath'
if (`$argv.Count -ge 3 -and `$argv[0] -eq 'view' -and `$argv[1] -eq '@openai/codex' -and `$argv[2] -eq 'version') {
  Write-Output 'registry unavailable'
  exit 1
}
if (`$argv.Count -ge 3 -and `$argv[0] -eq 'install' -and `$argv[1] -eq '-g' -and `$argv[2] -eq '@openai/codex') {
  New-Item -ItemType File -Force -Path `$markerPath | Out-Null
  Write-Output 'updated'
  exit 0
}
Write-Output ('unexpected npm args: ' + (`$argv -join ' '))
exit 1
"@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', ($toolRoot + ';' + [Environment]::GetEnvironmentVariable('PATH')))
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null

      $result = Ensure-RaymanCodexCliUpToDate -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -ForceRefresh

      [bool]$result.success | Should -Be $true
      [bool]$result.compatible | Should -Be $true
      [bool]$result.updated | Should -Be $true
      [bool]$result.latest_check_attempted | Should -Be $true
      [bool]$result.latest_check_succeeded | Should -Be $false
      [string]$result.reason | Should -Be 'compatibility_auto_updated'
      [string]$result.version_after | Should -Be '0.5.80'
      (Test-Path -LiteralPath $markerPath -PathType Leaf) | Should -Be $true
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'explicit upgrade reports before latest and after versions' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_upgrade_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_upgrade_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_upgrade_bin_' + [Guid]::NewGuid().ToString('N'))
    $toolRoot = Join-Path $binRoot 'npm'
    $markerPath = Join-Path $binRoot 'codex.updated'
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_ENABLED', '0')
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_POLICY', 'off')
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null

      $quotedMarkerPath = $markerPath.Replace("'", "''")
      New-CodexTestWrapper -Root $toolRoot -ScriptBody @"
param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$argv)
`$markerPath = '$quotedMarkerPath'
`$updated = Test-Path -LiteralPath `$markerPath
if (`$argv.Count -eq 1 -and `$argv[0] -eq '--version') {
  if (`$updated) {
    Write-Output 'codex-cli 0.6.10'
  } else {
    Write-Output 'codex-cli 0.5.80'
  }
  exit 0
}
if (`$argv.Count -ge 2 -and `$argv[0] -eq 'features' -and `$argv[1] -eq 'list') {
  Write-Output 'feature_a alpha true'
  exit 0
}
Write-Output 'ok'
exit 0
"@ | Out-Null

      New-NpmTestWrapper -Root $toolRoot -ScriptBody @"
param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$argv)
`$markerPath = '$quotedMarkerPath'
if (`$argv.Count -ge 3 -and `$argv[0] -eq 'view' -and `$argv[1] -eq '@openai/codex' -and `$argv[2] -eq 'version') {
  Write-Output '0.6.10'
  exit 0
}
if (`$argv.Count -ge 3 -and `$argv[0] -eq 'install' -and `$argv[1] -eq '-g' -and `$argv[2] -eq '@openai/codex') {
  New-Item -ItemType File -Force -Path `$markerPath | Out-Null
  Write-Output 'updated'
  exit 0
}
Write-Output ('unexpected npm args: ' + (`$argv -join ' '))
exit 1
"@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', ($toolRoot + ';' + [Environment]::GetEnvironmentVariable('PATH')))

      $payload = Invoke-ActionUpgrade -TargetWorkspaceRoot $workspaceRoot

      [bool]$payload.success | Should -Be $true
      [bool]$payload.compatible | Should -Be $true
      [bool]$payload.updated | Should -Be $true
      [string]$payload.reason | Should -Be 'updated_to_latest'
      [string]$payload.version_before | Should -Be '0.5.80'
      [string]$payload.latest_version | Should -Be '0.6.10'
      [string]$payload.version_after | Should -Be '0.6.10'
      (Test-Path -LiteralPath $markerPath -PathType Leaf) | Should -Be $true
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'explicit upgrade does not reinstall when codex-cli is already at npm latest' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_upgrade_latest_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_upgrade_latest_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_upgrade_latest_bin_' + [Guid]::NewGuid().ToString('N'))
    $toolRoot = Join-Path $binRoot 'npm'
    $markerPath = Join-Path $binRoot 'codex.updated'
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null

      $quotedMarkerPath = $markerPath.Replace("'", "''")
      New-CodexTestWrapper -Root $toolRoot -ScriptBody @"
param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$argv)
if (`$argv.Count -eq 1 -and `$argv[0] -eq '--version') {
  Write-Output 'codex-cli 0.6.10'
  exit 0
}
if (`$argv.Count -ge 2 -and `$argv[0] -eq 'features' -and `$argv[1] -eq 'list') {
  Write-Output 'feature_a alpha true'
  exit 0
}
Write-Output 'ok'
exit 0
"@ | Out-Null

      New-NpmTestWrapper -Root $toolRoot -ScriptBody @"
param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$argv)
`$markerPath = '$quotedMarkerPath'
if (`$argv.Count -ge 3 -and `$argv[0] -eq 'view' -and `$argv[1] -eq '@openai/codex' -and `$argv[2] -eq 'version') {
  Write-Output '0.6.10'
  exit 0
}
if (`$argv.Count -ge 3 -and `$argv[0] -eq 'install' -and `$argv[1] -eq '-g' -and `$argv[2] -eq '@openai/codex') {
  New-Item -ItemType File -Force -Path `$markerPath | Out-Null
  Write-Output 'unexpected reinstall'
  exit 0
}
Write-Output ('unexpected npm args: ' + (`$argv -join ' '))
exit 1
"@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', ($toolRoot + ';' + [Environment]::GetEnvironmentVariable('PATH')))

      $result = Ensure-RaymanCodexCliUpToDate -WorkspaceRoot $workspaceRoot -ForceRefresh -ForceUpgrade

      [bool]$result.success | Should -Be $true
      [bool]$result.compatible | Should -Be $true
      [bool]$result.updated | Should -Be $false
      [string]$result.reason | Should -Be 'already_latest_explicit'
      (Test-Path -LiteralPath $markerPath -PathType Leaf) | Should -Be $false
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'explicit upgrade is unsupported for non npm-managed codex-cli installs' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_upgrade_non_npm_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_upgrade_non_npm_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_upgrade_non_npm_bin_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $binRoot | Out-Null

      New-CodexTestWrapper -Root $binRoot -ScriptBody @"
param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$argv)
if (`$argv.Count -eq 1 -and `$argv[0] -eq '--version') {
  Write-Output 'codex-cli 0.5.80'
  exit 0
}
if (`$argv.Count -ge 2 -and `$argv[0] -eq 'features' -and `$argv[1] -eq 'list') {
  Write-Output 'feature_a alpha true'
  exit 0
}
Write-Output 'ok'
exit 0
"@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', ($binRoot + ';' + [Environment]::GetEnvironmentVariable('PATH')))

      $result = Ensure-RaymanCodexCliUpToDate -WorkspaceRoot $workspaceRoot -ForceRefresh -ForceUpgrade

      [bool]$result.success | Should -Be $false
      [bool]$result.compatible | Should -Be $true
      [bool]$result.updated | Should -Be $false
      [string]$result.reason | Should -Be 'non_npm_managed_upgrade_unsupported'
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'fails fast with a login repair command when the managed alias is not authenticated' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_failfast_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_failfast_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_failfast_bin_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
      New-CodexTestWrapper -Root $binRoot -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
if ($argv.Count -ge 2 -and $argv[0] -eq 'login' -and $argv[1] -eq 'status') {
  Write-Output 'Not logged in'
  exit 1
}
Write-Output ($env:CODEX_HOME)
exit 0
'@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', ($binRoot + ';' + [Environment]::GetEnvironmentVariable('PATH')))
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -Profile 'review' | Out-Null

      $thrownMessage = ''
      try {
        Invoke-RaymanCodexCommand -WorkspaceRoot $workspaceRoot -ArgumentList @('exec', 'hello') -RequireManagedLogin | Out-Null
      } catch {
        $thrownMessage = $_.Exception.Message
      }

      $thrownMessage | Should -Match 'rayman codex login --alias alpha'
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'normalizes missing alias auth storage to not_logged_in instead of probe_failed' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_status_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_status_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_status_bin_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
      New-CodexTestWrapper -Root $binRoot -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
if ($argv.Count -eq 1 -and $argv[0] -eq '--version') {
  Write-Output 'codex-cli 0.5.80'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'features' -and $argv[1] -eq 'list') {
  Write-Output 'feature_a alpha true'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'login' -and $argv[1] -eq 'status') {
  Write-Output 'Error checking login status: The system cannot find the file specified. (os error 2)'
  exit 1
}
Write-Output 'ok'
exit 0
'@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', ($binRoot + ';' + [Environment]::GetEnvironmentVariable('PATH')))
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -Profile '' | Out-Null

      $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha'

      [string]$status.status | Should -Be 'not_logged_in'
      [bool]$status.authenticated | Should -Be $false
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'captures codex output correctly when the resolved command is a PowerShell script wrapper' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_ps1_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_ps1_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_ps1_bin_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
      New-CodexPowerShellWrapper -Root $binRoot -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
if ($argv.Count -ge 2 -and $argv[0] -eq 'login' -and $argv[1] -eq 'status') {
  Write-Output 'Error checking login status: The system cannot find the file specified. (os error 2)'
  exit 1
}
Write-Output ('unexpected: ' + ($argv -join ' '))
exit 0
'@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', ($binRoot + ';' + [Environment]::GetEnvironmentVariable('PATH')))
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -Profile '' | Out-Null

      $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha'

      [string]$status.status | Should -Be 'not_logged_in'
      @($status.output).Count | Should -Be 1
      [string]$status.output[0] | Should -Match 'os error 2'
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'writes workspace trust automatically after a successful alias login or switch' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_login_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_login_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_login_bin_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
      New-CodexTestWrapper -Root $binRoot -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
if ($argv.Count -eq 1 -and $argv[0] -eq '--version') {
  Write-Output 'codex-cli 0.5.80'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'features' -and $argv[1] -eq 'list') {
  Write-Output 'feature_a alpha true'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'login' -and $argv[1] -eq '--device-auth') {
  Write-Output 'Open this URL and enter code ABCD-EFGH'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'login' -and $argv[1] -eq 'status') {
  Write-Output 'Logged in using ChatGPT'
  exit 0
}
Write-Output 'ok'
exit 0
'@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', ($binRoot + ';' + [Environment]::GetEnvironmentVariable('PATH')))

      Invoke-ActionLogin -Alias 'alpha' -Profile '' -TargetWorkspaceRoot $workspaceRoot -Picker 'menu'

      $trustState = Get-RaymanCodexWorkspaceTrustState -Alias 'alpha' -WorkspaceRoot $workspaceRoot
      $binding = Get-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot

      [bool]$trustState.present | Should -Be $true
      [string]$trustState.trust_level | Should -Be 'trusted'
      [string]$binding.account_alias | Should -Be 'alpha'

      Invoke-ActionSwitch -Alias 'alpha' -Profile '' -TargetWorkspaceRoot $workspaceRoot -Picker 'menu'
      $trustStateAfterSwitch = Get-RaymanCodexWorkspaceTrustState -Alias 'alpha' -WorkspaceRoot $workspaceRoot
      [bool]$trustStateAfterSwitch.present | Should -Be $true
      [string]$trustStateAfterSwitch.trust_level | Should -Be 'trusted'
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'supports explicit gpt-alt login through the VS Code bundled codex fallback' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_gpt_alt_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_gpt_alt_workspace_' + [Guid]::NewGuid().ToString('N'))
    $extensionsRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_gpt_alt_ext_' + [Guid]::NewGuid().ToString('N'))
    $markerPath = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_gpt_alt_marker_' + [Guid]::NewGuid().ToString('N') + '.txt')
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      $quotedMarkerPath = $markerPath.Replace("'", "''")
      New-VsCodeBundledCodexWrapper -ExtensionsRoot $extensionsRoot -ScriptBody @"
param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$argv)
`$markerPath = '$quotedMarkerPath'
if (`$argv.Count -eq 1 -and `$argv[0] -eq '--version') {
  Write-Output 'codex-cli 0.5.80'
  exit 0
}
if (`$argv.Count -ge 2 -and `$argv[0] -eq 'features' -and `$argv[1] -eq 'list') {
  Write-Output 'feature_a alpha true'
  exit 0
}
if (`$argv.Count -ge 2 -and `$argv[0] -eq 'login' -and `$argv[1] -eq '--device-auth') {
  Set-Content -LiteralPath `$markerPath -Encoding UTF8 -Value (`$env:CODEX_HOME + [Environment]::NewLine + (`$argv -join ' '))
  Write-Output 'Open this URL and enter code ABCD-EFGH'
  exit 0
}
if (`$argv.Count -ge 2 -and `$argv[0] -eq 'login' -and `$argv[1] -eq 'status') {
  Write-Output 'Logged in using ChatGPT'
  exit 0
}
Write-Output 'ok'
exit 0
"@ | Out-Null
      [Environment]::SetEnvironmentVariable('RAYMAN_VSCODE_EXTENSIONS_ROOT', $extensionsRoot)
      [Environment]::SetEnvironmentVariable('PATH', (Get-TestPathWithoutCodex))

      Invoke-ActionLogin -Alias 'gpt-alt' -Profile '' -TargetWorkspaceRoot $workspaceRoot -Picker 'menu'

      $trustState = Get-RaymanCodexWorkspaceTrustState -Alias 'gpt-alt' -WorkspaceRoot $workspaceRoot
      $binding = Get-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot
      $markerRaw = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8

      (Test-Path -LiteralPath $markerPath -PathType Leaf) | Should -Be $true
      [bool]$trustState.present | Should -Be $true
      [string]$trustState.trust_level | Should -Be 'trusted'
      [string]$binding.account_alias | Should -Be 'gpt-alt'
      $markerRaw | Should -Match 'gpt-alt'
      $markerRaw | Should -Match 'login --device-auth'
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $extensionsRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
    }
  }
}
