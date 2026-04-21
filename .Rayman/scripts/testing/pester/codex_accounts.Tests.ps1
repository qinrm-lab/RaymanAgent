Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  . (Join-Path $PSScriptRoot '..\..\..\common.ps1')
  . (Join-Path $PSScriptRoot '..\..\codex\manage_accounts.ps1') -NoMain
  $script:CodexAccountsIsWindowsHost = [bool](Test-RaymanWindowsPlatform)
}

function script:New-TestCommandWrapper {
  param(
    [string]$Root,
    [string]$Name,
    [string]$ScriptBody
  )

  $implPath = Join-Path $Root ('{0}.impl.ps1' -f $Name)
  Set-Content -LiteralPath $implPath -Encoding UTF8 -Value $ScriptBody
  $pwsh = Get-Command 'pwsh' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $pwsh) {
    $pwsh = Get-Command 'powershell' -ErrorAction SilentlyContinue | Select-Object -First 1
  }
  if ($null -eq $pwsh) {
    throw 'pwsh/powershell not found for codex wrapper test'
  }

  $quotedImpl = $implPath.Replace("'", "''")
  if (Test-RaymanWindowsPlatform) {
    $wrapperPath = Join-Path $Root ('{0}.cmd' -f $Name)
    Set-Content -LiteralPath $wrapperPath -Encoding ASCII -Value @"
@echo off
"$($pwsh.Source)" -NoProfile -ExecutionPolicy Bypass -Command "& '$quotedImpl' @args" -- %*
exit /b %ERRORLEVEL%
"@
  } else {
    $wrapperPath = Join-Path $Root $Name
    $bashPath = Resolve-TestBashCommand
    $quotedPwsh = ([string]$pwsh.Source).Replace('"', '\"')
    $quotedImplForShell = ([string]$implPath).Replace('"', '\"')
    Set-Content -LiteralPath $wrapperPath -Encoding ASCII -Value @"
#!$bashPath
"$quotedPwsh" -NoProfile -ExecutionPolicy Bypass -File "$quotedImplForShell" "`$@"
"@
    $chmod = Resolve-TestChmodCommand
    & $chmod '+x' '--' $wrapperPath
  }

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

  if (-not $script:CodexAccountsIsWindowsHost) {
    New-TestCommandWrapper -Root $Root -Name 'npm.cmd' -ScriptBody $ScriptBody | Out-Null
  }

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

function script:Write-CodexDesktopWorkspaceSession {
  param(
    [string]$DesktopHome,
    [string]$WorkspaceRoot,
    [string]$SessionId = 'desktop-workspace-session-1',
    [datetime]$SessionTimestamp = (Get-Date).AddMinutes(-1),
    [string[]]$StatusMessages = @()
  )

  $sessionDir = Join-Path $DesktopHome 'sessions\2026\04\15'
  New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
  $sessionPath = Join-Path $sessionDir ('rollout-' + $SessionId + '.jsonl')
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add((([ordered]@{
            timestamp = $SessionTimestamp.ToUniversalTime().ToString('o')
            type = 'session_meta'
            payload = [ordered]@{
              id = $SessionId
              timestamp = $SessionTimestamp.ToUniversalTime().ToString('o')
              cwd = $WorkspaceRoot
              originator = 'codex_vscode'
              source = 'vscode'
            }
          }) | ConvertTo-Json -Depth 6 -Compress)) | Out-Null

  $i = 0
  foreach ($message in @($StatusMessages)) {
    $lines.Add((([ordered]@{
              timestamp = $SessionTimestamp.AddSeconds($i + 1).ToUniversalTime().ToString('o')
              type = 'event_msg'
              payload = [ordered]@{
                type = 'status'
                message = [string]$message
              }
            }) | ConvertTo-Json -Depth 6 -Compress)) | Out-Null
    $i++
  }

  Set-Content -LiteralPath $sessionPath -Encoding UTF8 -Value @($lines.ToArray())
  (Get-Item -LiteralPath $sessionPath).LastWriteTime = Get-Date
  return $sessionPath
}

function script:Resolve-TestChmodCommand {
  foreach ($candidate in @('/bin/chmod', '/usr/bin/chmod', 'chmod')) {
    if ($candidate.StartsWith('/')) {
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
      }
      continue
    }

    $command = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
      return [string]$command.Source
    }
  }

  throw 'chmod not found for codex wrapper test'
}

function script:Resolve-TestBashCommand {
  foreach ($candidate in @('/bin/bash', '/usr/bin/bash', 'bash')) {
    if ($candidate.StartsWith('/')) {
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
      }
      continue
    }

    $command = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
      return [string]$command.Source
    }
  }

  throw 'bash not found for codex wrapper test'
}

function script:Join-TestPath {
  param(
    [string]$Entry,
    [string]$CurrentPath
  )

  if ([string]::IsNullOrWhiteSpace([string]$CurrentPath)) {
    return $Entry
  }

  return ($Entry + [System.IO.Path]::PathSeparator + $CurrentPath)
}

function script:Get-TestWorkspaceFileUri {
  param([string]$WorkspaceRoot)

  $resolvedPath = Resolve-Path -LiteralPath $WorkspaceRoot -ErrorAction Stop | Select-Object -ExpandProperty Path
  if ($script:CodexAccountsIsWindowsHost) {
    return ([System.Uri]$resolvedPath).AbsoluteUri
  }

  $builder = [System.UriBuilder]::new()
  $builder.Scheme = 'file'
  $builder.Host = ''
  $builder.Path = ([string]$resolvedPath).Replace('\', '/')
  return $builder.Uri.AbsoluteUri
}

function script:Test-SkipUnlessWindowsHost {
  param([string]$Because)

  if ($script:CodexAccountsIsWindowsHost) {
    return $false
  }

  Set-ItResult -Skipped -Because $Because
  return $true
}

function script:Set-TestCodexAccountAuthScope {
  param(
    [string]$Alias,
    [string]$AuthScope
  )

  $registry = Get-RaymanCodexRegistry
  $accounts = ConvertTo-RaymanStringKeyMap -InputObject $registry.accounts
  $aliasKey = Get-RaymanCodexAliasKey -Alias $Alias
  $record = Get-RaymanMapValue -Map $accounts -Key $aliasKey -Default $null
  if ($null -eq $record) {
    throw ("Rayman Codex alias '{0}' is not registered for test scope seeding." -f $Alias)
  }

  $recordMap = ConvertTo-RaymanStringKeyMap -InputObject $record
  $recordMap['auth_scope'] = Normalize-RaymanCodexAuthScope -Scope $AuthScope
  $accounts[$aliasKey] = $recordMap
  $registry.accounts = $accounts
  Save-RaymanCodexRegistry -Registry $registry | Out-Null
}

function script:Get-TestPathWithoutCodex {
  $paths = New-Object System.Collections.Generic.List[string]
  foreach ($name in @('pwsh', 'pwsh.exe', 'powershell', 'powershell.exe', 'cmd.exe')) {
    $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
      continue
    }

    $directory = Split-Path -Parent ([string]$command.Source)
    if (-not [string]::IsNullOrWhiteSpace($directory) -and ($paths -notcontains $directory)) {
      $paths.Add($directory) | Out-Null
    }
  }

  return ([string[]]$paths -join [System.IO.Path]::PathSeparator)
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
      RAYMAN_CODEX_LOGIN_FOREGROUND_ONLY = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_LOGIN_FOREGROUND_ONLY')
      RAYMAN_CODEX_LOGIN_ALLOW_HIDDEN = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_LOGIN_ALLOW_HIDDEN')
      RAYMAN_CODEX_LOGIN_SMOKE_COOLDOWN_MINUTES = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_LOGIN_SMOKE_COOLDOWN_MINUTES')
      RAYMAN_CODEX_LOGIN_SMOKE_MAX_ATTEMPTS = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_LOGIN_SMOKE_MAX_ATTEMPTS')
      RAYMAN_CODEX_DESKTOP_HOME = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME')
      RAYMAN_VSCODE_EXTENSIONS_ROOT = [Environment]::GetEnvironmentVariable('RAYMAN_VSCODE_EXTENSIONS_ROOT')
      RAYMAN_NPM_GLOBAL_BIN_ROOT = [Environment]::GetEnvironmentVariable('RAYMAN_NPM_GLOBAL_BIN_ROOT')
    }

    [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_ENABLED', '0')
    [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_POLICY', 'off')
    [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_LOGIN_FOREGROUND_ONLY', $null)
    [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_LOGIN_ALLOW_HIDDEN', $null)
    [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_LOGIN_SMOKE_COOLDOWN_MINUTES', $null)
    [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_LOGIN_SMOKE_MAX_ATTEMPTS', $null)
    [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $null)
    [Environment]::SetEnvironmentVariable('RAYMAN_VSCODE_EXTENSIONS_ROOT', $null)
    $script:testNoNpmGlobalBinRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_no_npm_' + [Guid]::NewGuid().ToString('N'))
    [Environment]::SetEnvironmentVariable('RAYMAN_NPM_GLOBAL_BIN_ROOT', $script:testNoNpmGlobalBinRoot)
    [Environment]::SetEnvironmentVariable('PATH', (Get-TestPathWithoutCodex))
    $script:RaymanCodexCompatibilityCache = @{}
    $script:RaymanCodexLoginOverrideSupportCache = @{}
    Mock Resolve-RaymanCodexLoginConfigOverrides {
      return [pscustomobject]@{
        available = $false
        supported = $false
        skipped_reason = 'test_default'
        config_args = @()
        keys = @()
        probe = $null
      }
    }
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
      $configRaw | Should -Match ([regex]::Escape((Get-RaymanCodexWorkspaceTrustHeader -WorkspaceRoot 'E:\rayman\software\RaymanAgent')))
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

  It 'prefers the last successful Yunyi alias when opening the Yunyi login menu' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_rows_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_rows_workspace_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null

      Ensure-RaymanCodexAccount -Alias 'main' | Out-Null
      Ensure-RaymanCodexAccount -Alias 'yunyi1' | Out-Null
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'main' -Profile '' | Out-Null
      Set-RaymanCodexAccountYunyiMetadata -Alias 'yunyi1' -BaseUrl 'https://api.yunyi.example.com/v1' -SuccessAt '2026-03-30T00:02:00Z' -ConfigReady $true -ReuseReason 'last_yunyi_config' -BaseUrlSource 'config:alias' | Out-Null

      $rows = @(Get-LoginAliasRows -TargetWorkspaceRoot $workspaceRoot -PreferredMode 'yunyi')
      $labels = @($rows | ForEach-Object { [string]$_.label })
      $yunyiRow = $rows | Where-Object { [string]$_.label -eq 'yunyi1' } | Select-Object -First 1

      $labels[0] | Should -Be 'yunyi1'
      [bool]$yunyiRow.recommended | Should -Be $true
      (@([string[]]$yunyiRow.tags) -contains '最近 Yunyi 成功') | Should -Be $true

      Mock -CommandName Test-InteractiveInputAvailable -MockWith { $true }
      Mock -CommandName Read-Host -MockWith { '' }
      $selection = Resolve-LoginAliasChoice -Alias '' -TargetWorkspaceRoot $workspaceRoot -Picker 'menu' -Mode 'yunyi'

      [string]$selection.alias | Should -Be 'yunyi1'
      [string]$selection.alias_source | Should -Be 'menu'
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'falls back to the newest VS Code bundled codex command when PATH does not contain codex' {
    if (-not $script:CodexAccountsIsWindowsHost) {
      Set-ItResult -Skipped -Because 'VS Code bundled codex fallback is Windows-only.'
      return
    }

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
    if (-not $script:CodexAccountsIsWindowsHost) {
      Set-ItResult -Skipped -Because 'PATH codex fallback precedence is validated on Windows.'
      return
    }

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
      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $binRoot -CurrentPath (Get-TestPathWithoutCodex)))

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
    if (-not $script:CodexAccountsIsWindowsHost) {
      Set-ItResult -Skipped -Because 'npm-global versus VS Code bundled codex precedence is Windows-only.'
      return
    }

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
      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry (Split-Path -Parent $vscodeWrapper) -CurrentPath (Get-TestPathWithoutCodex)))

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

  It 'prefers a sibling codex.cmd over codex.ps1 on Windows PATH to avoid extra PowerShell host windows' {
    if (-not $script:CodexAccountsIsWindowsHost) {
      Set-ItResult -Skipped -Because 'Sibling codex.cmd precedence only applies on Windows.'
      return
    }

    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_cmd_sibling_bin_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
      New-CodexPowerShellWrapper -Root $binRoot -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
Write-Output 'powershell-wrapper'
exit 0
'@ | Out-Null
      $cmdWrapper = New-CodexTestWrapper -Root $binRoot -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
Write-Output 'cmd-wrapper'
exit 0
'@
      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $binRoot -CurrentPath (Get-TestPathWithoutCodex)))

      $commandInfo = Get-RaymanCodexCommandInfo
      $capture = Invoke-RaymanCodexRawCapture -CodexHome '' -ArgumentList @('whoami')

      [bool]$commandInfo.available | Should -Be $true
      [string]$commandInfo.resolution_source | Should -Be 'path'
      [string]$commandInfo.path | Should -Be $cmdWrapper
      [string]$capture.output | Should -Match 'cmd-wrapper'
    } finally {
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
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
    Invoke-CodexMenuAction -MenuAction 'login-web' -TargetWorkspaceRoot 'E:\repo' -Picker 'menu'
    Invoke-CodexMenuAction -MenuAction 'login-smoke' -TargetWorkspaceRoot 'E:\repo' -Picker 'menu'
    Invoke-CodexMenuAction -MenuAction 'login-yunyi' -TargetWorkspaceRoot 'E:\repo' -Picker 'menu'
    Invoke-CodexMenuAction -MenuAction 'login-api' -TargetWorkspaceRoot 'E:\repo' -Picker 'menu'
    Invoke-CodexMenuAction -MenuAction 'login-device' -TargetWorkspaceRoot 'E:\repo' -Picker 'menu'
    Invoke-CodexMenuAction -MenuAction 'switch' -TargetWorkspaceRoot 'E:\repo' -Picker 'menu'
    Invoke-CodexMenuAction -MenuAction 'manage' -TargetWorkspaceRoot 'E:\repo' -Picker 'menu'
    Invoke-CodexMenuAction -MenuAction 'run' -TargetWorkspaceRoot 'E:\repo' -Picker 'menu'
    Invoke-CodexMenuAction -MenuAction 'upgrade' -TargetWorkspaceRoot 'E:\repo' -Picker 'menu'

    Assert-MockCalled Invoke-ActionStatus -Exactly 1 -ParameterFilter { $TargetWorkspaceRoot -eq 'E:\repo' }
    Assert-MockCalled Invoke-ActionList -Exactly 1 -ParameterFilter { $TargetWorkspaceRoot -eq 'E:\repo' }
    Assert-MockCalled Invoke-ActionLogin -Exactly 1 -ParameterFilter { $TargetWorkspaceRoot -eq 'E:\repo' -and $Picker -eq 'menu' -and $Mode -eq 'web' }
    Assert-MockCalled Invoke-ActionLogin -Exactly 1 -ParameterFilter { $TargetWorkspaceRoot -eq 'E:\repo' -and $Picker -eq 'menu' -and $LoginSmoke -and $PromptForMode }
    Assert-MockCalled Invoke-ActionLogin -Exactly 1 -ParameterFilter { $TargetWorkspaceRoot -eq 'E:\repo' -and $Picker -eq 'menu' -and $Mode -eq 'yunyi' }
    Assert-MockCalled Invoke-ActionLogin -Exactly 1 -ParameterFilter { $TargetWorkspaceRoot -eq 'E:\repo' -and $Picker -eq 'menu' -and $Mode -eq 'api' }
    Assert-MockCalled Invoke-ActionLogin -Exactly 1 -ParameterFilter { $TargetWorkspaceRoot -eq 'E:\repo' -and $Picker -eq 'menu' -and $Mode -eq 'device' }
    Assert-MockCalled Invoke-ActionSwitch -Exactly 1 -ParameterFilter { $TargetWorkspaceRoot -eq 'E:\repo' -and $Picker -eq 'menu' }
    Assert-MockCalled Invoke-CodexManageAlias -Exactly 1 -ParameterFilter { $TargetWorkspaceRoot -eq 'E:\repo' -and $Picker -eq 'menu' }
    Assert-MockCalled Invoke-ActionRunFromMenu -Exactly 1 -ParameterFilter { $TargetWorkspaceRoot -eq 'E:\repo' }
    Assert-MockCalled Invoke-ActionUpgrade -Exactly 1 -ParameterFilter { $TargetWorkspaceRoot -eq 'E:\repo' }
  }

  It 'prefers web login in the interactive mode picker when no previous auth mode is recorded' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_mode_pick_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_mode_pick_workspace_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null

      Mock Test-InteractiveInputAvailable { return $true }
      Mock Select-WithFzfOrMenu {
        param($Rows, $Picker, $Prompt, $Render, $KeySelector, $DefaultRow)
        return $DefaultRow
      }

      $choice = Resolve-CodexLoginModeChoice -Mode '' -Alias 'alpha' -TargetWorkspaceRoot $workspaceRoot -Picker 'menu' -PromptForMode

      [string]$choice.mode | Should -Be 'web'
      [string]$choice.source | Should -Be 'menu'
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'accepts explicit yunyi mode in the login mode resolver' {
    $choice = Resolve-CodexLoginModeChoice -Mode 'yunyi' -Alias 'alpha' -TargetWorkspaceRoot 'E:\repo' -Picker 'menu'

    [string]$choice.mode | Should -Be 'yunyi'
    [string]$choice.source | Should -Be 'explicit'
  }

  It 'defaults non-prompted login mode resolution to web' {
    $choice = Resolve-CodexLoginModeChoice -Mode '' -Alias 'alpha' -TargetWorkspaceRoot 'E:\repo' -Picker 'menu'

    [string]$choice.mode | Should -Be 'web'
    [string]$choice.source | Should -Be 'default_web'
  }

  It 'reads API keys from stdin when requested' {
    $originalIn = [Console]::In
    try {
      Mock Test-InteractiveInputAvailable { return $false }
      [Console]::SetIn([System.IO.StringReader]::new("sk-test-key`n"))

      $value = Get-CodexApiKeyInput -FromStdin

      [string]$value | Should -Be 'sk-test-key'
    } finally {
      [Console]::SetIn($originalIn)
    }
  }

  It 'supports web login through the unified native login dispatcher' {
    if (-not $script:CodexAccountsIsWindowsHost) {
      Set-ItResult -Skipped -Because 'Desktop-global web login dispatch is Windows-only.'
      return
    }

    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_web_login_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_web_login_workspace_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_web_login_desktop_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $desktopHome | Out-Null
      $account = Ensure-RaymanCodexAccount -Alias 'alpha'

      Mock Ensure-CodexCliReady {}
      Mock Resolve-RaymanCodexLoginConfigOverrides {
        return [pscustomobject]@{
          available = $true
          supported = $true
          skipped_reason = ''
          config_args = @('-c', 'windows.sandbox_private_desktop=false', '-c', 'notice.hide_full_access_warning=true')
          keys = @('windows.sandbox_private_desktop', 'notice.hide_full_access_warning')
          probe = $null
        }
      }
      Mock Invoke-RaymanCodexRawInteractive {
        return [pscustomobject]@{ success = $true; exit_code = 0; launch_strategy = 'foreground'; output = ''; output_captured = $false; error = '' }
      } -ParameterFilter {
        $CodexHome -eq $desktopHome -and
        -not $PreferHiddenWindow -and
        $ArgumentList.Count -eq 5 -and
        $ArgumentList[0] -eq '-c' -and $ArgumentList[1] -eq 'windows.sandbox_private_desktop=false' -and
        $ArgumentList[2] -eq '-c' -and $ArgumentList[3] -eq 'notice.hide_full_access_warning=true' -and
        $ArgumentList[4] -eq 'login' -and
        $EnvironmentOverrides.ContainsKey('OPENAI_API_KEY') -and $null -eq $EnvironmentOverrides['OPENAI_API_KEY'] -and
        $EnvironmentOverrides.ContainsKey('OPENAI_BASE_URL') -and $null -eq $EnvironmentOverrides['OPENAI_BASE_URL']
      }
      Mock Invoke-RaymanCodexDesktopStatusValidation {
        return [pscustomobject]@{
          success = $true
          reason = 'quota_visible'
          status_command = '/status'
          quota_visible = $true
          desktop_auth_present = $true
          desktop_global_cloud_access = 'enabled'
          desktop_config_conflict = ''
          desktop_unsynced_reason = ''
        }
      }
      Mock Get-RaymanCodexLoginStatus {
        return [pscustomobject]@{
          generated_at = '2026-03-30T00:00:00Z'
          authenticated = $true
          status = 'authenticated'
          auth_mode_last = 'web'
          latest_native_session = [pscustomobject]@{ available = $false; id = ''; thread_name = ''; updated_at = ''; source = 'none'; session_index_path = '' }
        }
      }

      $result = Invoke-CodexAliasNativeLogin -Alias 'alpha' -TargetWorkspaceRoot $workspaceRoot -Mode web
      $record = Get-RaymanCodexAccountRecord -Alias 'alpha'

      [string]$result.mode | Should -Be 'web'
      [string]$record.auth_mode_last | Should -Be 'web'
      [string]$record.auth_scope | Should -Be 'desktop_global'
      [string]$record.desktop_target_mode | Should -Be 'web'
      [string]$record.last_login_mode | Should -Be 'web'
      [string]$record.last_login_strategy | Should -Be 'foreground'
      Assert-MockCalled Invoke-RaymanCodexRawInteractive -Exactly 1 -ParameterFilter { $CodexHome -eq $desktopHome -and -not $PreferHiddenWindow }
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'reuses a saved ChatGPT token from the alias home before opening browser login' {
    if (-not $script:CodexAccountsIsWindowsHost) {
      Set-ItResult -Skipped -Because 'Saved ChatGPT desktop token reuse is Windows-only.'
      return
    }

    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_saved_web_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_saved_web_workspace_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_saved_web_desktop_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $desktopHome | Out-Null
      $account = Ensure-RaymanCodexAccount -Alias 'alpha'
      $aliasAuthPath = Join-Path ([string]$account.codex_home) 'auth.json'
      $desktopAuthPath = Join-Path $desktopHome 'auth.json'
      $desktopConfigPath = Join-Path $desktopHome 'config.toml'
      $desktopStatePath = Join-Path $desktopHome '.codex-global-state.json'

      Set-Content -LiteralPath $aliasAuthPath -Encoding UTF8 -Value @'
{
  "auth_mode": "chatgpt",
  "tokens": {
    "account_id": "acct-alpha"
  }
}
'@
      Set-Content -LiteralPath $desktopAuthPath -Encoding UTF8 -Value '{"auth_mode":"apikey","OPENAI_API_KEY":"demo-apikey"}'
      Set-Content -LiteralPath $desktopConfigPath -Encoding UTF8 -Value @'
model_provider = "yunyi"

[model_providers.yunyi]
base_url = "https://yunyi.example.com/codex"
wire_api = "responses"
experimental_bearer_token = "demo-bearer"
requires_openai_auth = true
'@
      Set-Content -LiteralPath $desktopStatePath -Encoding UTF8 -Value '{"electron-persisted-atom-state":{"codexCloudAccess":"disabled"}}'

      Mock Ensure-CodexCliReady {}
      Mock Invoke-RaymanCodexRawInteractive {}
      Mock Invoke-RaymanCodexDesktopStatusValidation {
        return [pscustomobject]@{
          success = $true
          reason = 'quota_visible'
          status_command = '/status'
          quota_visible = $true
          desktop_auth_present = $true
          desktop_global_cloud_access = 'enabled'
          desktop_config_conflict = ''
          desktop_unsynced_reason = ''
        }
      }
      Mock Get-RaymanCodexLoginStatus {
        return [pscustomobject]@{
          generated_at = '2026-03-30T00:00:00Z'
          authenticated = $true
          status = 'authenticated'
          auth_mode_last = 'web'
          auth_mode_detected = 'chatgpt'
          auth_source = 'native_auth_json'
          desktop_target_mode = 'web'
          desktop_saved_token_reused = $true
          desktop_saved_token_source = 'alias_auth'
          desktop_status_quota_visible = $true
          desktop_status_reason = 'quota_visible'
          desktop_global_cloud_access = 'enabled'
          latest_native_session = [pscustomobject]@{ available = $false; id = ''; thread_name = ''; updated_at = ''; source = 'none'; session_index_path = '' }
        }
      }

      $result = Invoke-CodexAliasNativeLogin -Alias 'alpha' -TargetWorkspaceRoot $workspaceRoot -Mode web
      $report = Get-Content -LiteralPath (Join-Path $workspaceRoot '.Rayman\runtime\codex.login.last.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      $desktopConfigRaw = Get-Content -LiteralPath $desktopConfigPath -Raw -Encoding UTF8
      $desktopStateRaw = Get-Content -LiteralPath $desktopStatePath -Raw -Encoding UTF8

      (Get-Content -LiteralPath $desktopAuthPath -Raw -Encoding UTF8) | Should -Match '"auth_mode"\s*:\s*"chatgpt"'
      $desktopConfigRaw | Should -Not -Match 'model_provider'
      $desktopConfigRaw | Should -Not -Match 'experimental_bearer_token'
      $desktopConfigRaw | Should -Not -Match '\[model_providers\.yunyi\]'
      $desktopStateRaw | Should -Match '"codexCloudAccess"\s*:\s*"enabled"'
      [string]$result.mode | Should -Be 'web'
      [bool]$report.desktop_saved_token_reused | Should -Be $true
      [string]$report.desktop_saved_token_source | Should -Be 'alias_auth'
      [string]$report.command | Should -Be 'saved-chatgpt-desktop-repair'
      Assert-MockCalled Invoke-RaymanCodexRawInteractive -Exactly 0
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $null)
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'prefers canonical user-home Yunyi files before prompting and prefers auth.json over legacy TOML tokens' {
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_canonical_workspace_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_canonical_home_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $desktopHome | Out-Null
      Set-Content -LiteralPath (Join-Path $desktopHome 'config.toml.yunyi') -Encoding UTF8 -Value @'
model_provider = "yunyi"

[model_providers.yunyi]
name = "yunyi"
base_url = "https://canonical.rdzhvip.com/codex"
wire_api = "responses"
experimental_bearer_token = "8A5RFUH6-SZEV-5R07-F86V-UNNEMTPMVJV4"
'@
      Set-Content -LiteralPath (Join-Path $desktopHome 'auth.json.yunyi') -Encoding UTF8 -Value '{"OPENAI_API_KEY":"8A5RFUH6-SZEV-5R07-F86V-UNNEMTPMVJV4","auth_mode":"apikey"}'

      Mock Read-Host { throw 'prompt should not be used when canonical Yunyi files exist' }

      $baseChoice = Get-CodexYunyiBaseUrlChoice -WorkspaceRoot $workspaceRoot
      $apiKey = Get-CodexYunyiApiKeyInput -WorkspaceRoot $workspaceRoot
      $apiKeyState = Get-RaymanCodexUserHomeYunyiApiKeyState

      [string]$baseChoice.base_url | Should -Be 'https://canonical.rdzhvip.com/codex'
      [string]$baseChoice.source | Should -Be 'user_home:config.toml.yunyi'
      [string]$apiKey | Should -Be '8A5RFUH6-SZEV-5R07-F86V-UNNEMTPMVJV4'
      [string]$apiKeyState.source | Should -Be 'user_home:auth.json.yunyi'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $null)
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'falls back to Yunyi backup files under the user-home yunyi directory' {
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_backup_workspace_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_backup_home_' + [Guid]::NewGuid().ToString('N'))
    $backupRoot = Join-Path $desktopHome 'yunyi'
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
      Set-Content -LiteralPath (Join-Path $backupRoot 'config - api驿站.toml') -Encoding UTF8 -Value @'
model_provider = "yunyi"

[model_providers.yunyi]
name = "yunyi"
base_url = "https://backup.rdzhvip.com/codex"
wire_api = "responses"
experimental_bearer_token = "8A5RFUH6-SZEV-5R07-F86V-UNNEMTPMVJV4"
'@
      Set-Content -LiteralPath (Join-Path $backupRoot 'auth.json.yunyi') -Encoding UTF8 -Value '{"OPENAI_API_KEY":"8A5RFUH6-SZEV-5R07-F86V-UNNEMTPMVJV4","auth_mode":"apikey"}'

      Mock Read-Host { throw 'prompt should not be used when backup Yunyi files exist' }

      $baseChoice = Get-CodexYunyiBaseUrlChoice -WorkspaceRoot $workspaceRoot
      $apiKey = Get-CodexYunyiApiKeyInput -WorkspaceRoot $workspaceRoot
      $apiKeyState = Get-RaymanCodexUserHomeYunyiApiKeyState

      [string]$baseChoice.base_url | Should -Be 'https://backup.rdzhvip.com/codex'
      [string]$baseChoice.source | Should -Be 'user_home:config.toml.yunyi'
      [string]$apiKey | Should -Be '8A5RFUH6-SZEV-5R07-F86V-UNNEMTPMVJV4'
      [string]$apiKeyState.source | Should -Be 'user_home:auth.json.yunyi'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $null)
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'repairs placeholder canonical Yunyi files from the user-home backup TOML before login input resolution' {
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_repair_workspace_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_repair_home_' + [Guid]::NewGuid().ToString('N'))
    $backupRoot = Join-Path $desktopHome 'yunyi'
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
      Set-Content -LiteralPath (Join-Path $desktopHome 'config.toml.yunyi') -Encoding UTF8 -Value @'
model_provider = "yunyi"

[model_providers.yunyi]
name = "yunyi"
base_url = "https://api.yunyi.example.com/v1"
wire_api = "responses"
'@
      Set-Content -LiteralPath (Join-Path $desktopHome 'auth.json.yunyi') -Encoding UTF8 -Value '{"OPENAI_API_KEY":"8A5RFUH6-SZEV-5R07-F86V-UNNEMTPMVJV4","auth_mode":"apikey"}'
      Set-Content -LiteralPath (Join-Path $backupRoot 'config - api驿站.toml') -Encoding UTF8 -Value @'
model_provider = "yunyi"

[model_providers.yunyi]
name = "yunyi"
base_url = "https://yunyi.rdzhvip.com/codex"
wire_api = "responses"
experimental_bearer_token = "8A5RFUH6-SZEV-5R07-F86V-UNNEMTPMVJV4"
requires_openai_auth = true
'@

      $baseChoice = Get-CodexYunyiBaseUrlChoice -WorkspaceRoot $workspaceRoot
      $apiKey = Get-CodexYunyiApiKeyInput -WorkspaceRoot $workspaceRoot
      $canonicalConfigRaw = Get-Content -LiteralPath (Join-Path $desktopHome 'config.toml.yunyi') -Raw -Encoding UTF8
      $canonicalAuthRaw = Get-Content -LiteralPath (Join-Path $desktopHome 'auth.json.yunyi') -Raw -Encoding UTF8

      [string]$baseChoice.base_url | Should -Be 'https://yunyi.rdzhvip.com/codex'
      [string]$baseChoice.source | Should -Be 'user_home:config.toml.yunyi'
      [string]$apiKey | Should -Be '8A5RFUH6-SZEV-5R07-F86V-UNNEMTPMVJV4'
      $canonicalConfigRaw | Should -Match 'https://yunyi\.rdzhvip\.com/codex'
      $canonicalAuthRaw | Should -Match '"OPENAI_API_KEY"\s*:\s*"8A5RFUH6-SZEV-5R07-F86V-UNNEMTPMVJV4"'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $null)
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'uses .Rayman login fallback when user-home Yunyi files are missing or poisoned' {
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_workspace_backup_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_workspace_backup_home_' + [Guid]::NewGuid().ToString('N'))
    $workspaceLoginRoot = Join-Path $workspaceRoot '.Rayman\login'
    $workspaceLoginBackupRoot = Join-Path $workspaceLoginRoot 'yunyi'
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $desktopHome | Out-Null
      New-Item -ItemType Directory -Force -Path $workspaceLoginBackupRoot | Out-Null
      Set-Content -LiteralPath (Join-Path $desktopHome 'config.toml.yunyi') -Encoding UTF8 -Value @'
model_provider = "yunyi"

[model_providers.yunyi]
name = "yunyi"
base_url = "https://backup.yunyi.example.com/codex"
wire_api = "responses"
'@
      Set-Content -LiteralPath (Join-Path $desktopHome 'auth.json.yunyi') -Encoding UTF8 -Value '{"OPENAI_API_KEY":"yy-demo-token-123456","auth_mode":"apikey"}'
      Set-Content -LiteralPath (Join-Path $workspaceLoginRoot 'auth.json.yunyi') -Encoding UTF8 -Value '{"OPENAI_API_KEY":"8A5RFUH6-SZEV-5R07-F86V-UNNEMTPMVJV4","auth_mode":"apikey"}'
      Set-Content -LiteralPath (Join-Path $workspaceLoginBackupRoot 'config - api驿站.toml') -Encoding UTF8 -Value @'
model_provider = "yunyi"

[model_providers.yunyi]
name = "yunyi"
base_url = "https://yunyi.rdzhvip.com/codex"
wire_api = "responses"
experimental_bearer_token = "8A5RFUH6-SZEV-5R07-F86V-UNNEMTPMVJV4"
requires_openai_auth = true
'@

      $baseChoice = Get-CodexYunyiBaseUrlChoice -WorkspaceRoot $workspaceRoot
      $apiKey = Get-CodexYunyiApiKeyInput -WorkspaceRoot $workspaceRoot
      $userBackupAuthRaw = Get-Content -LiteralPath (Join-Path $desktopHome 'yunyi\auth.json.yunyi') -Raw -Encoding UTF8

      [string]$baseChoice.base_url | Should -Be 'https://yunyi.rdzhvip.com/codex'
      [string]$baseChoice.source | Should -Be 'user_home:config.toml.yunyi'
      [string]$apiKey | Should -Be '8A5RFUH6-SZEV-5R07-F86V-UNNEMTPMVJV4'
      $userBackupAuthRaw | Should -Match '"OPENAI_API_KEY"\s*:\s*"8A5RFUH6-SZEV-5R07-F86V-UNNEMTPMVJV4"'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $null)
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'activates Yunyi login desktop-globally and syncs canonical state without leaking the raw key into metadata' {
    if (-not $script:CodexAccountsIsWindowsHost) {
      Set-ItResult -Skipped -Because 'Desktop-global Yunyi activation is Windows-only.'
      return
    }

    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_login_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_login_workspace_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_login_desktop_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $desktopHome | Out-Null
      $account = Ensure-RaymanCodexAccount -Alias 'alpha'
      Set-RaymanCodexAccountLoginDiagnostics -Alias 'alpha' -LoginMode 'web' -AuthScope 'desktop_global' -LaunchStrategy 'foreground' -PromptClassification 'none' -StartedAt '2026-03-30T00:00:00Z' -FinishedAt '2026-03-30T00:01:00Z' -Success $true -DesktopTargetMode 'web' | Out-Null

      Mock Ensure-CodexCliReady {}
      Mock Get-CodexYunyiBaseUrlChoice {
        return [pscustomobject]@{
          base_url = 'https://api.yunyi.example.com/v1'
          source = 'env:RAYMAN_CODEX_YUNYI_BASE_URL'
          prompted = $false
        }
      }
      Mock Get-CodexYunyiApiKeyInput { return 'yy-demo-token-123456' }
      Mock Invoke-RaymanCodexRawCaptureWithStdin {
        Set-Content -LiteralPath (Join-Path $desktopHome 'auth.json') -Encoding UTF8 -Value '{"OPENAI_API_KEY":"yy-demo-token-123456","auth_mode":"apikey"}'
        return [pscustomobject]@{ success = $true; exit_code = 0; output = 'Logged in using an API key'; stdout = @('Logged in using an API key'); stderr = @(); command = 'codex login --with-api-key'; error = '' }
      } -ParameterFilter {
        $CodexHome -eq $desktopHome -and
        $ArgumentList.Count -eq 2 -and $ArgumentList[0] -eq 'login' -and $ArgumentList[1] -eq '--with-api-key' -and
        $StdinText -eq 'yy-demo-token-123456' -and
        $EnvironmentOverrides.ContainsKey('OPENAI_BASE_URL') -and [string]$EnvironmentOverrides['OPENAI_BASE_URL'] -eq 'https://api.yunyi.example.com/v1' -and
        $EnvironmentOverrides.ContainsKey('OPENAI_API_BASE') -and [string]$EnvironmentOverrides['OPENAI_API_BASE'] -eq 'https://api.yunyi.example.com/v1'
      }
      Mock Invoke-RaymanCodexDesktopStatusValidation {
        return [pscustomobject]@{
          success = $true
          reason = 'api_key_active'
          status_command = '/status'
          quota_visible = $false
          desktop_auth_present = $true
          desktop_global_cloud_access = 'disabled'
          desktop_config_conflict = ''
          desktop_unsynced_reason = ''
        }
      } -ParameterFilter { $TargetMode -eq 'yunyi' -and $DesktopCodexHome -eq $desktopHome }
      Mock Get-RaymanCodexLoginStatus {
        return [pscustomobject]@{
          generated_at = '2026-03-30T00:00:00Z'
          authenticated = $true
          status = 'authenticated'
          auth_mode_last = 'yunyi'
          auth_scope = 'desktop_global'
          desktop_target_mode = 'yunyi'
          desktop_status_reason = 'api_key_active'
          desktop_global_cloud_access = 'disabled'
          latest_native_session = [pscustomobject]@{ available = $false; id = ''; thread_name = ''; updated_at = ''; source = 'none'; session_index_path = '' }
        }
      }

      $result = Invoke-CodexAliasNativeLogin -Alias 'alpha' -TargetWorkspaceRoot $workspaceRoot -Mode yunyi
      $record = Get-RaymanCodexAccountRecord -Alias 'alpha'
      $aliasConfigRaw = Get-Content -LiteralPath (Join-Path ([string]$account.codex_home) 'config.toml') -Raw -Encoding UTF8
      $aliasAuthRaw = Get-Content -LiteralPath (Join-Path ([string]$account.codex_home) 'auth.json') -Raw -Encoding UTF8
      $desktopConfigRaw = Get-Content -LiteralPath (Join-Path $desktopHome 'config.toml') -Raw -Encoding UTF8
      $desktopAuthRaw = Get-Content -LiteralPath (Join-Path $desktopHome 'auth.json') -Raw -Encoding UTF8
      $canonicalConfigRaw = Get-Content -LiteralPath (Join-Path $desktopHome 'config.toml.yunyi') -Raw -Encoding UTF8
      $canonicalAuthRaw = Get-Content -LiteralPath (Join-Path $desktopHome 'auth.json.yunyi') -Raw -Encoding UTF8
      $backupAuthRaw = Get-Content -LiteralPath (Join-Path $desktopHome 'yunyi\auth.json.yunyi') -Raw -Encoding UTF8
      $workspaceConfigRaw = Get-Content -LiteralPath (Join-Path $workspaceRoot '.Rayman\login\config.toml.yunyi') -Raw -Encoding UTF8
      $workspaceAuthRaw = Get-Content -LiteralPath (Join-Path $workspaceRoot '.Rayman\login\auth.json.yunyi') -Raw -Encoding UTF8
      $workspaceBackupAuthRaw = Get-Content -LiteralPath (Join-Path $workspaceRoot '.Rayman\login\yunyi\auth.json.yunyi') -Raw -Encoding UTF8
      $workspaceBackupTomlRaw = Get-Content -LiteralPath (Join-Path $workspaceRoot '.Rayman\login\yunyi\config - api驿站.toml') -Raw -Encoding UTF8
      $report = Get-Content -LiteralPath (Join-Path $workspaceRoot '.Rayman\runtime\codex.login.last.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      $aliasProviderIndex = [string]$aliasConfigRaw.IndexOf('model_provider = "yunyi"')
      $aliasFirstTable = [regex]::Match([string]$aliasConfigRaw, '(?m)^\[')
      $aliasFirstTableIndex = if ([bool]$aliasFirstTable.Success) { [int]$aliasFirstTable.Index } else { [int]::MaxValue }
      $desktopProviderIndex = [string]$desktopConfigRaw.IndexOf('model_provider = "yunyi"')
      $desktopFirstTable = [regex]::Match([string]$desktopConfigRaw, '(?m)^\[')
      $desktopFirstTableIndex = if ([bool]$desktopFirstTable.Success) { [int]$desktopFirstTable.Index } else { [int]::MaxValue }

      [string]$result.mode | Should -Be 'yunyi'
      [string]$record.auth_mode_last | Should -Be 'yunyi'
      [string]$record.auth_scope | Should -Be 'desktop_global'
      [string]$record.last_yunyi_base_url | Should -Be 'https://api.yunyi.example.com/v1'
      [bool]$record.last_yunyi_config_ready | Should -Be $true
      $aliasConfigRaw | Should -Match 'model_provider = "yunyi"'
      $aliasConfigRaw | Should -Match 'base_url = "https://api\.yunyi\.example\.com/v1"'
      $aliasProviderIndex | Should -BeLessThan $aliasFirstTableIndex
      $aliasAuthRaw | Should -Match '"OPENAI_API_KEY"\s*:\s*"yy-demo-token-123456"'
      $desktopConfigRaw | Should -Match 'model_provider = "yunyi"'
      $desktopConfigRaw | Should -Match 'base_url = "https://api\.yunyi\.example\.com/v1"'
      $desktopProviderIndex | Should -BeLessThan $desktopFirstTableIndex
      $desktopAuthRaw | Should -Match '"OPENAI_API_KEY"\s*:\s*"yy-demo-token-123456"'
      $canonicalConfigRaw | Should -Match 'base_url = "https://api\.yunyi\.example\.com/v1"'
      $canonicalConfigRaw | Should -Not -Match 'yy-demo-token-123456'
      $canonicalConfigRaw | Should -Not -Match 'experimental_bearer_token'
      $canonicalAuthRaw | Should -Match '"OPENAI_API_KEY"\s*:\s*"yy-demo-token-123456"'
      $backupAuthRaw | Should -Match '"OPENAI_API_KEY"\s*:\s*"yy-demo-token-123456"'
      $workspaceConfigRaw | Should -Match 'base_url = "https://api\.yunyi\.example\.com/v1"'
      $workspaceAuthRaw | Should -Match '"OPENAI_API_KEY"\s*:\s*"yy-demo-token-123456"'
      $workspaceBackupAuthRaw | Should -Match '"OPENAI_API_KEY"\s*:\s*"yy-demo-token-123456"'
      $workspaceBackupTomlRaw | Should -Match 'experimental_bearer_token = "yy-demo-token-123456"'
      [string]$report.auth_scope | Should -Be 'desktop_global'
      [string]$report.desktop_target_mode | Should -Be 'yunyi'
      [string]$report.desktop_status_reason | Should -Be 'api_key_active'
      [string]$report.desktop_global_cloud_access | Should -Be 'disabled'
      [bool]$report.reused_yunyi_config | Should -Be $false
      [string]$report.yunyi_base_url_source | Should -Be 'env:RAYMAN_CODEX_YUNYI_BASE_URL'
      [string]$report.yunyi_reuse_reason | Should -Be 'fresh_base_url'
      (($record | ConvertTo-Json -Depth 12)) | Should -Not -Match [regex]::Escape('yy-demo-token-123456')
      (($report | ConvertTo-Json -Depth 12)) | Should -Not -Match [regex]::Escape('yy-demo-token-123456')
      Assert-MockCalled Invoke-RaymanCodexRawCaptureWithStdin -Exactly 1 -ParameterFilter {
        $CodexHome -eq $desktopHome -and
        $ArgumentList.Count -eq 2 -and $ArgumentList[0] -eq 'login' -and $ArgumentList[1] -eq '--with-api-key' -and
        $StdinText -eq 'yy-demo-token-123456' -and
        $EnvironmentOverrides.ContainsKey('OPENAI_BASE_URL') -and [string]$EnvironmentOverrides['OPENAI_BASE_URL'] -eq 'https://api.yunyi.example.com/v1'
      }
      Assert-MockCalled Invoke-RaymanCodexDesktopStatusValidation -Exactly 1 -ParameterFilter { $TargetMode -eq 'yunyi' -and $DesktopCodexHome -eq $desktopHome }
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $null)
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'restores desktop auth cache when Yunyi desktop activation validation fails' {
    if (-not $script:CodexAccountsIsWindowsHost) {
      Set-ItResult -Skipped -Because 'Desktop-global Yunyi validation recovery is Windows-only.'
      return
    }

    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_restore_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_restore_workspace_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_restore_desktop_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $desktopHome | Out-Null
      $desktopAuthPath = Join-Path $desktopHome 'auth.json'
      Set-Content -LiteralPath $desktopAuthPath -Encoding UTF8 -Value '{"auth_mode":"chatgpt","seed":"before"}'
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null

      Mock Ensure-CodexCliReady {}
      Mock Get-CodexYunyiBaseUrlChoice {
        return [pscustomobject]@{
          base_url = 'https://api.yunyi.example.com/v1'
          source = 'env:RAYMAN_CODEX_YUNYI_BASE_URL'
          prompted = $false
        }
      }
      Mock Get-CodexYunyiApiKeyInput { return 'yy-demo-token-123456' }
      Mock Invoke-RaymanCodexRawCaptureWithStdin {
        Set-Content -LiteralPath $desktopAuthPath -Encoding UTF8 -Value '{"OPENAI_API_KEY":"yy-demo-token-123456","auth_mode":"apikey","seed":"after"}'
        return [pscustomobject]@{ success = $true; exit_code = 0; output = 'Logged in using an API key'; stdout = @('Logged in using an API key'); stderr = @(); command = 'codex login --with-api-key'; error = '' }
      } -ParameterFilter { $CodexHome -eq $desktopHome }
      Mock Invoke-RaymanCodexDesktopStatusValidation {
        return [pscustomobject]@{
          success = $false
          reason = 'desktop_api_auth_unsynced'
          status_command = '/status'
          quota_visible = $false
          desktop_auth_present = $true
          desktop_global_cloud_access = 'disabled'
          desktop_config_conflict = ''
          desktop_unsynced_reason = 'desktop_api_auth_unsynced'
        }
      } -ParameterFilter { $TargetMode -eq 'yunyi' -and $DesktopCodexHome -eq $desktopHome }
      Mock Get-RaymanCodexLoginStatus {
        return [pscustomobject]@{
          generated_at = '2026-03-30T00:00:00Z'
          authenticated = $false
          status = 'desktop_repair_needed'
          auth_mode_last = 'yunyi'
          latest_native_session = [pscustomobject]@{ available = $false; id = ''; thread_name = ''; updated_at = ''; source = 'none'; session_index_path = '' }
        }
      }
      Mock Exit-CodexError { throw $Message }

      { Invoke-CodexAliasNativeLogin -Alias 'alpha' -TargetWorkspaceRoot $workspaceRoot -Mode 'yunyi' } | Should -Throw '*desktop validation failed*'

      (Get-Content -LiteralPath $desktopAuthPath -Raw -Encoding UTF8) | Should -Match '"seed":"before"'
      $report = Get-Content -LiteralPath (Join-Path $workspaceRoot '.Rayman\runtime\codex.login.last.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      [bool]$report.rollback_applied | Should -Be $true
      [string]$report.desktop_status_reason | Should -Be 'desktop_api_auth_unsynced'
      [string]$report.auth_scope | Should -Be 'desktop_global'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $null)
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'activates saved Yunyi desktop state during alias switch without prompting' {
    if (-not $script:CodexAccountsIsWindowsHost) {
      Set-ItResult -Skipped -Because 'Saved Yunyi desktop activation is Windows-only.'
      return
    }

    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_switch_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_switch_workspace_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_switch_desktop_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $desktopHome | Out-Null

      Set-Content -LiteralPath (Join-Path $desktopHome 'auth.json') -Encoding UTF8 -Value '{"auth_mode":"chatgpt","seed":"before"}'
      Set-Content -LiteralPath (Join-Path $desktopHome 'config.toml.yunyi') -Encoding UTF8 -Value @'
model_provider = "yunyi"

[model_providers.yunyi]
name = "yunyi"
base_url = "https://api.yunyi.example.com/v1"
wire_api = "responses"
'@
      Set-Content -LiteralPath (Join-Path $desktopHome 'auth.json.yunyi') -Encoding UTF8 -Value '{"OPENAI_API_KEY":"8A5RFUH6-SZEV-5R07-F86V-UNNEMTPMVJV4","auth_mode":"apikey"}'
      Set-Content -LiteralPath (Join-Path $desktopHome '.codex-global-state.json') -Encoding UTF8 -Value '{"electron-persisted-atom-state":{"codexCloudAccess":"enabled"}}'

      $account = Ensure-RaymanCodexAccount -Alias 'alpha'
      Set-RaymanCodexAccountLoginDiagnostics -Alias 'alpha' -LoginMode 'yunyi' -AuthScope 'alias_local' -LaunchStrategy 'foreground' -PromptClassification 'none' -StartedAt '2026-03-30T00:00:00Z' -FinishedAt '2026-03-30T00:01:00Z' -Success $true -DesktopTargetMode 'yunyi' | Out-Null
      Set-RaymanCodexAccountStatus -Alias 'alpha' -Status 'authenticated' -CheckedAt '2026-03-30T00:02:00Z' -AuthModeLast 'yunyi' -LatestNativeSession ([pscustomobject]@{ available = $false; id = ''; thread_name = ''; updated_at = ''; source = 'none'; session_index_path = '' }) | Out-Null

      Mock Ensure-CodexCliReady {}
      Mock Invoke-RaymanCodexDesktopStatusValidation {
        return [pscustomobject]@{
          success = $true
          reason = 'api_key_active'
          status_command = '/status'
          quota_visible = $false
          desktop_auth_present = $true
          desktop_global_cloud_access = 'disabled'
          desktop_config_conflict = ''
          desktop_unsynced_reason = ''
        }
      } -ParameterFilter { $TargetMode -eq 'yunyi' -and $DesktopCodexHome -eq $desktopHome }
      Mock Get-RaymanCodexLoginStatus {
        return [pscustomobject]@{
          generated_at = '2026-03-30T00:03:00Z'
          authenticated = $true
          status = 'authenticated'
          auth_mode_last = 'yunyi'
          auth_scope = 'desktop_global'
          desktop_target_mode = 'yunyi'
          desktop_status_reason = 'api_key_active'
          desktop_global_cloud_access = 'disabled'
          latest_native_session = [pscustomobject]@{ available = $false; id = ''; thread_name = ''; updated_at = ''; source = 'none'; session_index_path = '' }
          saved_state_summary = [pscustomobject]@{ workspace_root = $workspaceRoot; account_alias = 'alpha'; total_count = 0; manual_count = 0; auto_temp_count = 0; latest = $null; recent_saved_states = @() }
        }
      }

      Invoke-ActionSwitch -Alias 'alpha' -Profile '' -TargetWorkspaceRoot $workspaceRoot -Picker 'menu'

      $binding = Get-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot
      $record = Get-RaymanCodexAccountRecord -Alias 'alpha'
      $desktopConfigRaw = Get-Content -LiteralPath (Join-Path $desktopHome 'config.toml') -Raw -Encoding UTF8
      $desktopAuthRaw = Get-Content -LiteralPath (Join-Path $desktopHome 'auth.json') -Raw -Encoding UTF8
      $desktopStateRaw = Get-Content -LiteralPath (Join-Path $desktopHome '.codex-global-state.json') -Raw -Encoding UTF8

      [string]$binding.account_alias | Should -Be 'alpha'
      [string]$record.auth_scope | Should -Be 'desktop_global'
      [string]$record.desktop_target_mode | Should -Be 'yunyi'
      $desktopConfigRaw | Should -Match 'model_provider = "yunyi"'
      $desktopConfigRaw | Should -Match 'https://api\.yunyi\.example\.com/v1'
      $desktopAuthRaw | Should -Match '"OPENAI_API_KEY"\s*:\s*"8A5RFUH6-SZEV-5R07-F86V-UNNEMTPMVJV4"'
      $desktopStateRaw | Should -Match '"codexCloudAccess"\s*:\s*"disabled"'
      Assert-MockCalled Invoke-RaymanCodexDesktopStatusValidation -Exactly 1 -ParameterFilter { $TargetMode -eq 'yunyi' -and $DesktopCodexHome -eq $desktopHome }
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $null)
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'auto-repairs web alias switch when desktop/global auth is out of sync' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_switch_web_repair_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_switch_web_repair_workspace_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null

      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null
      Set-RaymanCodexAccountLoginDiagnostics -Alias 'alpha' -LoginMode 'web' -AuthScope 'desktop_global' -LaunchStrategy 'foreground' -PromptClassification 'none' -StartedAt '2026-04-12T20:00:00Z' -FinishedAt '2026-04-12T20:01:00Z' -Success $true -DesktopTargetMode 'web' | Out-Null
      Set-RaymanCodexAccountStatus -Alias 'alpha' -Status 'desktop_repair_needed' -CheckedAt '2026-04-12T20:02:00Z' -AuthModeLast 'web' -LatestNativeSession ([pscustomobject]@{ available = $false; id = ''; thread_name = ''; updated_at = ''; source = 'none'; session_index_path = '' }) | Out-Null

      Mock Ensure-CodexCliReady {}
      Mock Test-RaymanCodexWindowsHost { return $true }
      Mock Select-CodexAliasRow {
        return [pscustomobject]@{
          alias = 'alpha'
          default_profile = ''
        }
      }
      Mock Invoke-RaymanCodexDesktopAliasActivation {
        return [pscustomobject]@{
          attempted = $true
          applicable = $true
          success = $false
          reason = 'desktop_home_auth_unsynced'
          saved_token_reused = $false
          saved_token_source = ''
          status = $null
        }
      } -ParameterFilter { $Alias -eq 'alpha' -and $Mode -eq 'web' }
      Mock Get-RaymanCodexLoginStatus {
        return [pscustomobject]@{
          authenticated = $false
          status = 'desktop_repair_needed'
          auth_mode_last = 'web'
          auth_mode_detected = 'apikey'
          desktop_unsynced_reason = 'desktop_home_auth_unsynced'
          latest_native_session = [pscustomobject]@{ available = $false; id = ''; thread_name = ''; updated_at = ''; source = 'none'; session_index_path = '' }
          saved_state_summary = [pscustomobject]@{ workspace_root = $workspaceRoot; account_alias = 'alpha'; total_count = 0; manual_count = 0; auto_temp_count = 0; latest = $null; recent_saved_states = @() }
          repair_command = 'rayman codex login --alias alpha'
        }
      }
      $script:repairSwitchLoginCall = $null
      Mock Invoke-CodexAliasNativeLogin {
        $script:repairSwitchLoginCall = [pscustomobject]@{
          Alias = [string]$Alias
          TargetWorkspaceRoot = [string]$TargetWorkspaceRoot
          Mode = [string]$Mode
          LogoutFirst = [bool]$LogoutFirst
        }
        return [pscustomobject]@{
          workspace_root = $workspaceRoot
          alias = 'alpha'
          mode = 'web'
          account = (Get-RaymanCodexAccountRecord -Alias 'alpha')
          status = [pscustomobject]@{
            authenticated = $true
            status = 'authenticated'
            auth_mode_last = 'web'
            latest_native_session = [pscustomobject]@{ available = $false; id = ''; thread_name = ''; updated_at = ''; source = 'none'; session_index_path = '' }
            saved_state_summary = [pscustomobject]@{ workspace_root = $workspaceRoot; account_alias = 'alpha'; total_count = 0; manual_count = 0; auto_temp_count = 0; latest = $null; recent_saved_states = @() }
            repair_command = ''
          }
        }
      }
      Mock Sync-WorkspaceTrust {}

      Invoke-ActionSwitch -Alias 'alpha' -Profile '' -TargetWorkspaceRoot $workspaceRoot -Picker 'menu'

      Assert-MockCalled Invoke-CodexAliasNativeLogin -Exactly 1
      [string]$script:repairSwitchLoginCall.Alias | Should -Be 'alpha'
      [string]$script:repairSwitchLoginCall.Mode | Should -Be 'web'
      [bool]$script:repairSwitchLoginCall.LogoutFirst | Should -Be $false
      [bool](Test-RaymanPathsEquivalent -LeftPath ([string]$script:repairSwitchLoginCall.TargetWorkspaceRoot) -RightPath $workspaceRoot) | Should -Be $true
      Assert-MockCalled Sync-WorkspaceTrust -Exactly 1 -ParameterFilter { $WorkspaceRoot -eq $workspaceRoot -and $Alias -eq 'alpha' }
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'rebuilds the Yunyi config from the last successful non-sensitive state before login' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_reuse_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_reuse_workspace_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_reuse_desktop_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $desktopHome | Out-Null
      $account = Ensure-RaymanCodexAccount -Alias 'alpha'
      Set-RaymanCodexAccountYunyiMetadata -Alias 'alpha' -BaseUrl 'https://api.yunyi.example.com/v1' -SuccessAt '2026-03-30T00:02:00Z' -ConfigReady $false -ReuseReason 'last_yunyi_record' -BaseUrlSource 'record:last_yunyi_base_url' | Out-Null
      $expectedCodexHome = if (Test-RaymanCodexWindowsHost) { $desktopHome } else { [string]$account.codex_home }

      Mock Ensure-CodexCliReady {}
      Mock Get-CodexYunyiBaseUrlChoice {
        throw 'fresh Yunyi base_url input should not be used when a saved config is available'
      }
      Mock Get-CodexYunyiApiKeyInput { return 'yy-demo-token-123456' }
      Mock Invoke-RaymanCodexRawCaptureWithStdin {
        Set-Content -LiteralPath (Join-Path $desktopHome 'auth.json') -Encoding UTF8 -Value '{"OPENAI_API_KEY":"yy-demo-token-123456","auth_mode":"apikey"}'
        return [pscustomobject]@{ success = $true; exit_code = 0; output = 'Logged in using an API key'; stdout = @('Logged in using an API key'); stderr = @(); command = 'codex login --with-api-key'; error = '' }
      } -ParameterFilter {
        $CodexHome -eq $expectedCodexHome -and
        $EnvironmentOverrides.ContainsKey('OPENAI_BASE_URL') -and [string]$EnvironmentOverrides['OPENAI_BASE_URL'] -eq 'https://api.yunyi.example.com/v1'
      }
      Mock Invoke-RaymanCodexDesktopStatusValidation {
        return [pscustomobject]@{
          success = $true
          reason = 'api_key_active'
          status_command = '/status'
          quota_visible = $false
          desktop_auth_present = $true
          desktop_global_cloud_access = 'disabled'
          desktop_config_conflict = ''
          desktop_unsynced_reason = ''
        }
      } -ParameterFilter { $TargetMode -eq 'yunyi' -and $DesktopCodexHome -eq $desktopHome }
      Mock Get-RaymanCodexLoginStatus {
        return [pscustomobject]@{
          generated_at = '2026-03-30T00:03:00Z'
          authenticated = $true
          status = 'authenticated'
          latest_native_session = [pscustomobject]@{ available = $false; id = ''; thread_name = ''; updated_at = ''; source = 'none'; session_index_path = '' }
        }
      }

      $result = Invoke-CodexAliasNativeLogin -Alias 'alpha' -TargetWorkspaceRoot $workspaceRoot -Mode yunyi
      $record = Get-RaymanCodexAccountRecord -Alias 'alpha'
      $aliasConfigRaw = Get-Content -LiteralPath (Join-Path ([string]$account.codex_home) 'config.toml') -Raw -Encoding UTF8
      $report = Get-Content -LiteralPath (Join-Path $workspaceRoot '.Rayman\runtime\codex.login.last.json') -Raw -Encoding UTF8 | ConvertFrom-Json

      [string]$result.mode | Should -Be 'yunyi'
      [bool]$record.last_yunyi_config_ready | Should -Be $true
      [string]$record.last_yunyi_base_url | Should -Be 'https://api.yunyi.example.com/v1'
      $aliasConfigRaw | Should -Match 'model_provider = "yunyi"'
      $aliasConfigRaw | Should -Match 'base_url = "https://api\.yunyi\.example\.com/v1"'
      [bool]$report.reused_yunyi_config | Should -Be $true
      [string]$report.yunyi_reuse_reason | Should -Be 'last_yunyi_record'
      [string]$report.yunyi_base_url_source | Should -Be 'record:last_yunyi_base_url'
      Assert-MockCalled Get-CodexYunyiBaseUrlChoice -Exactly 0
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $null)
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'supports API login through the unified native login dispatcher without persisting the raw key in status metadata' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_api_login_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_api_login_workspace_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_api_login_desktop_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $desktopHome | Out-Null
      Set-Content -LiteralPath (Join-Path $desktopHome 'config.toml') -Encoding UTF8 -Value @'
model_provider = "yunyi"

[model_providers.yunyi]
base_url = "https://api.yunyi.example.com/v1"
wire_api = "responses"
experimental_bearer_token = "demo-bearer"
requires_openai_auth = true
'@
      $account = Ensure-RaymanCodexAccount -Alias 'alpha'
      Set-RaymanCodexAccountLoginDiagnostics -Alias 'alpha' -LoginMode 'web' -AuthScope 'desktop_global' -LaunchStrategy 'foreground' -PromptClassification 'none' -StartedAt '2026-03-30T00:00:00Z' -FinishedAt '2026-03-30T00:01:00Z' -Success $true -DesktopTargetMode 'web' | Out-Null

      Mock Ensure-CodexCliReady {}
      Mock Get-CodexApiKeyInput { return 'sk-secret-value' } -ParameterFilter { $FromStdin }
      Mock Invoke-RaymanCodexRawCaptureWithStdin {
        Set-Content -LiteralPath (Join-Path $desktopHome 'auth.json') -Encoding UTF8 -Value '{"OPENAI_API_KEY":"sk-secret-value","auth_mode":"apikey"}'
        return [pscustomobject]@{ success = $true; exit_code = 0; output = 'Logged in using an API key - sk-****'; stdout = @('Logged in using an API key - sk-****'); stderr = @(); command = 'codex login --with-api-key'; error = '' }
      } -ParameterFilter { $CodexHome -eq $desktopHome -and $ArgumentList.Count -eq 2 -and $ArgumentList[0] -eq 'login' -and $ArgumentList[1] -eq '--with-api-key' -and $StdinText -eq 'sk-secret-value' }
      Mock Invoke-RaymanCodexDesktopStatusValidation {
        return [pscustomobject]@{
          success = $true
          reason = 'api_key_active'
          status_command = '/status'
          quota_visible = $false
          desktop_auth_present = $true
          desktop_global_cloud_access = 'disabled'
          desktop_config_conflict = ''
          desktop_unsynced_reason = ''
        }
      } -ParameterFilter { $TargetMode -eq 'api' -and $DesktopCodexHome -eq $desktopHome }
      Mock Get-RaymanCodexLoginStatus {
        return [pscustomobject]@{
          generated_at = '2026-03-30T00:00:00Z'
          authenticated = $true
          status = 'authenticated'
          latest_native_session = [pscustomobject]@{ available = $false; id = ''; thread_name = ''; updated_at = ''; source = 'none'; session_index_path = '' }
        }
      }

      $result = Invoke-CodexAliasNativeLogin -Alias 'alpha' -TargetWorkspaceRoot $workspaceRoot -Mode api -ApiKeyFromStdin
      $record = Get-RaymanCodexAccountRecord -Alias 'alpha'
      $desktopConfigRaw = Get-Content -LiteralPath (Join-Path $desktopHome 'config.toml') -Raw -Encoding UTF8

      [string]$result.mode | Should -Be 'api'
      [string]$record.auth_mode_last | Should -Be 'api'
      [string]$record.auth_scope | Should -Be 'desktop_global'
      if ($script:CodexAccountsIsWindowsHost) {
        $desktopConfigRaw | Should -Not -Match 'model_provider'
      }
      Assert-MockCalled Get-CodexApiKeyInput -Exactly 1 -ParameterFilter { $FromStdin }
      Assert-MockCalled Invoke-RaymanCodexRawCaptureWithStdin -Exactly 1 -ParameterFilter { $CodexHome -eq $desktopHome -and $ArgumentList.Count -eq 2 -and $ArgumentList[0] -eq 'login' -and $ArgumentList[1] -eq '--with-api-key' -and $StdinText -eq 'sk-secret-value' }
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $null)
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'prefers environment-backed API login before prompting for a raw key' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_api_env_login_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_api_env_login_workspace_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null
      Set-Content -LiteralPath (Join-Path $workspaceRoot '.env') -Encoding UTF8 -Value "OPENAI_API_KEY=sk-dotenv-key-valid-123456`n"

      Mock Ensure-CodexCliReady {}
      Mock Get-CodexApiKeyInput { throw 'should not prompt for a raw API key' }
      Mock Invoke-RaymanCodexRawCaptureWithStdin { throw 'should not call native api-key login when env key exists' }
      Mock Get-RaymanCodexLoginStatus {
        return [pscustomobject]@{
          generated_at = '2026-03-30T00:00:00Z'
          authenticated = $true
          status = 'authenticated'
          auth_mode_last = 'api'
          auth_mode_detected = 'env_apikey'
          auth_source = 'environment'
          latest_native_session = [pscustomobject]@{ available = $false; id = ''; thread_name = ''; updated_at = ''; source = 'none'; session_index_path = '' }
        }
      }

      $result = Invoke-CodexAliasNativeLogin -Alias 'alpha' -TargetWorkspaceRoot $workspaceRoot -Mode api
      $record = Get-RaymanCodexAccountRecord -Alias 'alpha'

      [string]$result.mode | Should -Be 'api'
      [string]$result.status.status | Should -Be 'authenticated'
      [bool]$result.status.authenticated | Should -Be $true
      [string]$result.status.auth_mode_last | Should -Be 'api'
      [string]$result.status.auth_mode_detected | Should -Be 'env_apikey'
      [string]$record.auth_mode_last | Should -Be 'api'
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'keeps the saved Yunyi base URL in runtime overrides for desktop-global commands' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_runtime_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_yunyi_runtime_workspace_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null
      Set-RaymanCodexAccountYunyiMetadata -Alias 'alpha' -BaseUrl 'https://api.yunyi.example.com/v1' -SuccessAt '2026-04-10T00:00:00Z' -ConfigReady $true -ReuseReason 'last_yunyi_record' -BaseUrlSource 'record:last_yunyi_base_url' | Out-Null

      Mock Resolve-RaymanCodexContext {
        return [pscustomobject]@{
          workspace_root = $workspaceRoot
          account_alias = 'alpha'
          auth_scope = 'desktop_global'
          codex_home = 'C:\Temp\codex-home'
          effective_profile = ''
          managed = $true
          account_known = $true
          login_repair_command = 'rayman codex login'
        }
      }
      Mock Ensure-RaymanCodexCliCompatible {
        return [pscustomobject]@{ compatible = $true; reason = 'ok'; output = ''; version = '0.0.0' }
      }
      Mock Invoke-RaymanCodexRawInteractive {
        return [pscustomobject]@{ success = $true; exit_code = 0; command = 'codex whoami'; error = '' }
      } -ParameterFilter {
        $CodexHome -eq 'C:\Temp\codex-home' -and
        $EnvironmentOverrides.ContainsKey('OPENAI_BASE_URL') -and
        [string]$EnvironmentOverrides['OPENAI_BASE_URL'] -eq 'https://api.yunyi.example.com/v1' -and
        $EnvironmentOverrides.ContainsKey('OPENAI_API_BASE') -and
        [string]$EnvironmentOverrides['OPENAI_API_BASE'] -eq 'https://api.yunyi.example.com/v1' -and
        -not $EnvironmentOverrides.ContainsKey('OPENAI_API_KEY')
      }

      $result = Invoke-RaymanCodexCommand -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -ArgumentList @('whoami')

      [bool]$result.success | Should -Be $true
      Assert-MockCalled Invoke-RaymanCodexRawInteractive -Exactly 1 -ParameterFilter {
        $CodexHome -eq 'C:\Temp\codex-home' -and
        $EnvironmentOverrides.ContainsKey('OPENAI_BASE_URL') -and
        [string]$EnvironmentOverrides['OPENAI_BASE_URL'] -eq 'https://api.yunyi.example.com/v1' -and
        $EnvironmentOverrides.ContainsKey('OPENAI_API_BASE') -and
        [string]$EnvironmentOverrides['OPENAI_API_BASE'] -eq 'https://api.yunyi.example.com/v1' -and
        -not $EnvironmentOverrides.ContainsKey('OPENAI_API_KEY')
      }
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'parses quoted workspace .env OPENAI_API_KEY values with trailing comments without keeping the quotes' {
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_dotenv_parse_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      Set-Content -LiteralPath (Join-Path $workspaceRoot '.env') -Encoding UTF8 -Value 'OPENAI_API_KEY="sk-valid-comment-1234567890" # keep hidden'

      $rawValue = Get-RaymanDotEnvString -WorkspaceRoot $workspaceRoot -Name 'OPENAI_API_KEY'
      $state = Get-RaymanCodexEnvironmentApiKeyState -WorkspaceRoot $workspaceRoot

      [string]$rawValue | Should -Be 'sk-valid-comment-1234567890'
      [bool]$state.available | Should -Be $true
      [string]$state.value | Should -Be 'sk-valid-comment-1234567890'
      [string]$state.reason | Should -Be 'valid'
    } finally {
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'reuses the existing CODEX_HOME when re-running device auth for an alias' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_relogin_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_relogin_workspace_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      $account = Ensure-RaymanCodexAccount -Alias 'alpha'

      Mock Ensure-CodexCliReady {}
      Mock Resolve-RaymanCodexLoginConfigOverrides {
        return [pscustomobject]@{
          available = $true
          supported = $true
          skipped_reason = ''
          config_args = @('-c', 'windows.sandbox_private_desktop=false', '-c', 'notice.hide_full_access_warning=true')
          keys = @('windows.sandbox_private_desktop', 'notice.hide_full_access_warning')
          probe = $null
        }
      }
      Mock Invoke-CodexDeviceAuthPreflight {
        return [pscustomobject]@{ stale_processes = @(); active_processes = @(); killed_processes = @() }
      }
      Mock Invoke-RaymanCodexRawInteractive {
        return [pscustomobject]@{ success = $true; exit_code = 0; launch_strategy = 'foreground'; output = ''; output_captured = $false; error = '' }
      } -ParameterFilter { $CodexHome -eq [string]$account.codex_home -and -not $PreferHiddenWindow -and $ArgumentList[-2] -eq 'login' -and $ArgumentList[-1] -eq '--device-auth' }
      Mock Get-RaymanCodexLoginStatus {
        return [pscustomobject]@{ authenticated = $true; status = 'authenticated' }
      }

      $result = Invoke-CodexAliasDeviceAuth -Alias 'alpha' -TargetWorkspaceRoot $workspaceRoot

      [string]$result.alias | Should -Be 'alpha'
      Assert-MockCalled Ensure-CodexCliReady -Exactly 1 -ParameterFilter { $WorkspaceRoot -eq $workspaceRoot -and $AccountAlias -eq 'alpha' -and $AutoUpdatePolicyOverride -eq 'compatibility' }
      Assert-MockCalled Invoke-CodexDeviceAuthPreflight -Exactly 1 -ParameterFilter { $Alias -eq 'alpha' -and $StaleAfterSeconds -eq 180 }
      Assert-MockCalled Invoke-RaymanCodexRawInteractive -Exactly 1 -ParameterFilter { $CodexHome -eq [string]$account.codex_home -and -not $PreferHiddenWindow }
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'only uses hidden launch for device auth when explicitly enabled' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_hidden_fallback_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_hidden_fallback_workspace_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      $account = Ensure-RaymanCodexAccount -Alias 'alpha'

      Mock Ensure-CodexCliReady {}
      Mock Test-RaymanWindowsPlatform { return $true }
      Mock Get-RaymanCodexLoginForegroundOnly { return $false }
      Mock Get-RaymanCodexLoginAllowHidden { return $true }
      Mock Resolve-RaymanCodexLoginConfigOverrides {
        return [pscustomobject]@{
          available = $true
          supported = $true
          skipped_reason = ''
          config_args = @()
          keys = @()
          probe = $null
        }
      }
      Mock Invoke-CodexDeviceAuthPreflight {
        return [pscustomobject]@{ stale_processes = @(); active_processes = @(); killed_processes = @() }
      }
      Mock Invoke-RaymanCodexRawInteractive {
        if ($PreferHiddenWindow) {
          return [pscustomobject]@{ success = $true; exit_code = 0; launch_strategy = 'hidden'; output = ''; output_captured = $true; error = '' }
        }
        return [pscustomobject]@{ success = $true; exit_code = 0; launch_strategy = 'foreground'; output = ''; output_captured = $false; error = '' }
      } -ParameterFilter { $CodexHome -eq [string]$account.codex_home -and $ArgumentList.Count -eq 2 -and $ArgumentList[0] -eq 'login' -and $ArgumentList[1] -eq '--device-auth' }
      Mock Get-RaymanCodexLoginStatus {
        return [pscustomobject]@{ authenticated = $true; status = 'authenticated' }
      }

      $result = Invoke-CodexAliasDeviceAuth -Alias 'alpha' -TargetWorkspaceRoot $workspaceRoot

      [string]$result.alias | Should -Be 'alpha'
      Assert-MockCalled Ensure-CodexCliReady -Exactly 1 -ParameterFilter { $WorkspaceRoot -eq $workspaceRoot -and $AccountAlias -eq 'alpha' -and $AutoUpdatePolicyOverride -eq 'compatibility' }
      Assert-MockCalled Invoke-CodexDeviceAuthPreflight -Exactly 1 -ParameterFilter { $Alias -eq 'alpha' -and $StaleAfterSeconds -eq 180 }
      Assert-MockCalled Invoke-RaymanCodexRawInteractive -Exactly 1 -ParameterFilter { $CodexHome -eq [string]$account.codex_home -and $PreferHiddenWindow }
      Assert-MockCalled Invoke-RaymanCodexRawInteractive -Exactly 0 -ParameterFilter { $CodexHome -eq [string]$account.codex_home -and -not $PreferHiddenWindow }
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'skips login-only config overrides when the installed CLI does not support them' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_login_override_skip_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_login_override_skip_workspace_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_login_override_skip_desktop_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $desktopHome | Out-Null
      $account = Ensure-RaymanCodexAccount -Alias 'alpha'
      $expectedCodexHome = if ($script:CodexAccountsIsWindowsHost) { $desktopHome } else { [string]$account.codex_home }

      Mock Ensure-CodexCliReady {}
      Mock Resolve-RaymanCodexLoginConfigOverrides {
        return [pscustomobject]@{
          available = $true
          supported = $false
          skipped_reason = 'unsupported_by_cli'
          config_args = @()
          keys = @('windows.sandbox_private_desktop', 'notice.hide_full_access_warning')
          probe = [pscustomobject]@{ exit_code = 2; failed_by_config = $true }
        }
      }
      Mock Invoke-RaymanCodexRawInteractive {
        return [pscustomobject]@{ success = $true; exit_code = 0; launch_strategy = 'foreground'; output = ''; output_captured = $false; error = '' }
      } -ParameterFilter { $CodexHome -eq $expectedCodexHome -and -not $PreferHiddenWindow -and $ArgumentList.Count -eq 1 -and $ArgumentList[0] -eq 'login' }
      Mock Get-RaymanCodexLoginStatus { return [pscustomobject]@{ generated_at = '2026-03-30T00:00:00Z'; authenticated = $true; status = 'authenticated' } }

      $result = Invoke-CodexAliasNativeLogin -Alias 'alpha' -TargetWorkspaceRoot $workspaceRoot -Mode web

      [string]$result.mode | Should -Be 'web'
      Assert-MockCalled Invoke-RaymanCodexRawInteractive -Exactly 1 -ParameterFilter { $CodexHome -eq $expectedCodexHome -and -not $PreferHiddenWindow -and $ArgumentList.Count -eq 1 -and $ArgumentList[0] -eq 'login' }
      $report = Get-Content -LiteralPath (Join-Path $workspaceRoot '.Rayman\runtime\codex.login.last.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      [bool]$report.overrides_requested | Should -Be $true
      [bool]$report.overrides_applied | Should -Be $false
      [string]$report.override_skipped_reason | Should -Be 'unsupported_by_cli'
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'blocks repeated login-smoke attempts inside the cooldown window' {
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_login_smoke_block_workspace_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      Mock Resolve-LoginAliasChoice {
        return [pscustomobject]@{
          workspace_root = $workspaceRoot
          alias = 'alpha'
          alias_source = 'manual'
          vscode_user_profile_state = $null
        }
      }
      Mock Resolve-CodexLoginSmokeModeChoice { return [pscustomobject]@{ mode = 'web'; source = 'explicit' } }
      Mock Write-CodexLoginSmokeBudget {
        return [pscustomobject]@{
          throttled = $true
          next_allowed_at = '2026-04-09T20:00:00+08:00'
          mode = 'web'
          cooldown_minutes = 30
          max_attempts = 1
          attempt_count = 1
        }
      }
      Mock Write-CodexBlockedLoginSmokeReport { return (Join-Path $workspaceRoot '.Rayman\runtime\codex.login.last.json') }
      Mock Invoke-CodexAliasNativeLogin {}
      Mock Exit-CodexError { throw $Message }

      { Invoke-ActionLogin -Alias 'alpha' -Profile '' -TargetWorkspaceRoot $workspaceRoot -Mode 'web' -LoginSmoke } | Should -Throw '*login-smoke is throttled*'
      Assert-MockCalled Invoke-CodexAliasNativeLogin -Exactly 0
    } finally {
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'allows login-smoke force to bypass cooldown and still records the report' {
    if (Test-SkipUnlessWindowsHost -Because 'Desktop-global login smoke validation is Windows-only.') {
      return
    }
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_login_smoke_force_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_login_smoke_force_workspace_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_login_smoke_force_desktop_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $desktopHome | Out-Null
      $account = Ensure-RaymanCodexAccount -Alias 'alpha'

      Mock Ensure-CodexCliReady {}
      Mock Resolve-RaymanCodexLoginConfigOverrides {
        return [pscustomobject]@{
          available = $true
          supported = $true
          skipped_reason = ''
          config_args = @()
          keys = @()
          probe = $null
        }
      }
      Mock Resolve-LoginAliasChoice {
        return [pscustomobject]@{
          workspace_root = $workspaceRoot
          alias = 'alpha'
          alias_source = 'manual'
          vscode_user_profile_state = $null
        }
      }
      Mock Resolve-CodexLoginSmokeModeChoice { return [pscustomobject]@{ mode = 'web'; source = 'explicit' } }
      Mock Write-CodexLoginSmokeBudget {
        return [pscustomobject]@{
          throttled = $true
          next_allowed_at = '2026-04-09T20:00:00+08:00'
          mode = 'web'
          cooldown_minutes = 30
          max_attempts = 1
          attempt_count = 1
        }
      }
      Mock Invoke-RaymanCodexRawInteractive {
        return [pscustomobject]@{ success = $true; exit_code = 0; launch_strategy = 'foreground'; output = ''; output_captured = $false; error = '' }
      } -ParameterFilter { $CodexHome -eq $desktopHome -and -not $PreferHiddenWindow -and $ArgumentList.Count -eq 1 -and $ArgumentList[0] -eq 'login' }
      Mock Invoke-RaymanCodexDesktopStatusValidation {
        return [pscustomobject]@{
          success = $true
          reason = 'quota_visible'
          status_command = '/status'
          quota_visible = $true
          desktop_auth_present = $true
          desktop_global_cloud_access = 'enabled'
        }
      }
      Mock Get-RaymanCodexLoginStatus {
        return [pscustomobject]@{
          generated_at = '2026-03-30T00:00:00Z'
          authenticated = $true
          status = 'authenticated'
          latest_native_session = [pscustomobject]@{ available = $false; id = ''; thread_name = ''; updated_at = ''; source = 'none'; session_index_path = '' }
        }
      }

      $result = Invoke-ActionLogin -Alias 'alpha' -Profile '' -TargetWorkspaceRoot $workspaceRoot -Mode 'web' -LoginSmoke -Force
      $report = Get-Content -LiteralPath (Join-Path $workspaceRoot '.Rayman\runtime\codex.login.last.json') -Raw -Encoding UTF8 | ConvertFrom-Json

      [string]$result.alias | Should -Be 'alpha'
      [bool]$report.smoke | Should -Be $true
      [bool]$report.force | Should -Be $true
      [string]$report.mode | Should -Be 'web'
      [string]$report.launch_strategy | Should -Be 'foreground'
      [string]$report.auth_scope | Should -Be 'desktop_global'
      [bool]$report.desktop_status_quota_visible | Should -Be $true
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'restores desktop auth cache when web login smoke fails desktop status validation' {
    if (Test-SkipUnlessWindowsHost -Because 'Web login smoke desktop validation is Windows-only.') {
      return
    }
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_web_smoke_restore_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_web_smoke_restore_workspace_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_web_smoke_restore_desktop_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $desktopHome | Out-Null
      $desktopAuthPath = Join-Path $desktopHome 'auth.json'
      Set-Content -LiteralPath $desktopAuthPath -Encoding UTF8 -Value '{"auth_mode":"chatgpt","seed":"before"}'
      $account = Ensure-RaymanCodexAccount -Alias 'alpha'

      Mock Ensure-CodexCliReady {}
      Mock Resolve-RaymanCodexLoginConfigOverrides {
        return [pscustomobject]@{
          available = $true
          supported = $true
          skipped_reason = ''
          config_args = @()
          keys = @()
          probe = $null
        }
      }
      Mock Invoke-RaymanCodexRawInteractive {
        Set-Content -LiteralPath $desktopAuthPath -Encoding UTF8 -Value '{"auth_mode":"chatgpt","seed":"after"}'
        return [pscustomobject]@{ success = $true; exit_code = 0; launch_strategy = 'foreground'; output = ''; output_captured = $false; error = '' }
      } -ParameterFilter { $CodexHome -eq $desktopHome -and -not $PreferHiddenWindow -and $ArgumentList.Count -eq 1 -and $ArgumentList[0] -eq 'login' }
      Mock Invoke-RaymanCodexDesktopStatusValidation {
        return [pscustomobject]@{
          success = $false
          reason = 'desktop_status_quota_missing'
          status_command = '/status'
          quota_visible = $false
          desktop_auth_present = $true
          desktop_global_cloud_access = 'enabled'
        }
      }
      Mock Get-RaymanCodexLoginStatus {
        return [pscustomobject]@{
          generated_at = '2026-03-30T00:00:00Z'
          authenticated = $true
          status = 'authenticated'
          auth_mode_last = 'web'
          latest_native_session = [pscustomobject]@{ available = $false; id = ''; thread_name = ''; updated_at = ''; source = 'none'; session_index_path = '' }
        }
      }
      Mock Exit-CodexError { throw $Message }

      { Invoke-CodexAliasNativeLogin -Alias 'alpha' -TargetWorkspaceRoot $workspaceRoot -Mode 'web' -LoginSmoke } | Should -Throw '*desktop validation failed*'

      (Get-Content -LiteralPath $desktopAuthPath -Raw -Encoding UTF8) | Should -Match '"seed":"before"'
      $report = Get-Content -LiteralPath (Join-Path $workspaceRoot '.Rayman\runtime\codex.login.last.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      [bool]$report.rollback_applied | Should -Be $true
      [string]$report.desktop_status_reason | Should -Be 'desktop_status_quota_missing'
      [string]$report.auth_scope | Should -Be 'desktop_global'
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'classifies desktop thread blocked separately from auth failure for web login smoke' {
    if (Test-SkipUnlessWindowsHost -Because 'Web login smoke desktop validation is Windows-only.') {
      return
    }
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_web_smoke_blocked_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_web_smoke_blocked_workspace_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_web_smoke_blocked_desktop_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $desktopHome | Out-Null
      Set-Content -LiteralPath (Join-Path $desktopHome 'auth.json') -Encoding UTF8 -Value '{"auth_mode":"chatgpt","seed":"before"}'
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null

      Mock Ensure-CodexCliReady {}
      Mock Resolve-RaymanCodexLoginConfigOverrides {
        return [pscustomobject]@{
          available = $true
          supported = $true
          skipped_reason = ''
          config_args = @()
          keys = @()
          probe = $null
        }
      }
      Mock Invoke-RaymanCodexRawInteractive {
        return [pscustomobject]@{ success = $true; exit_code = 0; launch_strategy = 'foreground'; output = ''; output_captured = $false; error = '' }
      } -ParameterFilter { $CodexHome -eq $desktopHome -and -not $PreferHiddenWindow -and $ArgumentList.Count -eq 1 -and $ArgumentList[0] -eq 'login' }
      Mock Invoke-RaymanCodexDesktopStatusValidation {
        return [pscustomobject]@{
          success = $false
          reason = 'desktop_thread_blocked'
          status_command = '/status'
          quota_visible = $false
          desktop_auth_present = $true
          desktop_global_cloud_access = 'enabled'
        }
      }
      Mock Get-RaymanCodexLoginStatus {
        return [pscustomobject]@{
          generated_at = '2026-03-30T00:00:00Z'
          authenticated = $true
          status = 'authenticated'
          auth_mode_last = 'web'
          latest_native_session = [pscustomobject]@{ available = $false; id = ''; thread_name = ''; updated_at = ''; source = 'none'; session_index_path = '' }
        }
      }
      Mock Exit-CodexError { throw $Message }

      { Invoke-CodexAliasNativeLogin -Alias 'alpha' -TargetWorkspaceRoot $workspaceRoot -Mode 'web' -LoginSmoke } | Should -Throw '*desktop validation failed*'

      $report = Get-Content -LiteralPath (Join-Path $workspaceRoot '.Rayman\runtime\codex.login.last.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      [string]$report.desktop_status_reason | Should -Be 'desktop_thread_blocked'
      [bool]$report.rollback_applied | Should -Be $true
      [string]$report.error | Should -Match 'desktop status validation failed'
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'soft-passes web desktop validation when window is unavailable but auth changed to chatgpt' {
    if (Test-SkipUnlessWindowsHost -Because 'Web desktop validation soft-pass behavior is Windows-only.') {
      return
    }
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_web_window_softpass_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_web_window_softpass_workspace_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_web_window_softpass_desktop_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $desktopHome | Out-Null

      $desktopAuthPath = Join-Path $desktopHome 'auth.json'
      Set-Content -LiteralPath $desktopAuthPath -Encoding UTF8 -Value '{"auth_mode":"apikey","OPENAI_API_KEY":"sk-before"}'

      $account = Ensure-RaymanCodexAccount -Alias 'alpha'
      $aliasAuthPath = Join-Path ([string]$account.codex_home) 'auth.json'
      Set-Content -LiteralPath $aliasAuthPath -Encoding UTF8 -Value '{"auth_mode":"apikey","OPENAI_API_KEY":"sk-alias"}'

      Mock Ensure-CodexCliReady {}
      Mock Resolve-RaymanCodexLoginConfigOverrides {
        return [pscustomobject]@{
          available = $true
          supported = $true
          skipped_reason = ''
          config_args = @()
          keys = @()
          probe = $null
        }
      }
      Mock Invoke-RaymanCodexRawInteractive {
        Set-Content -LiteralPath $desktopAuthPath -Encoding UTF8 -Value '{"auth_mode":"chatgpt","seed":"after"}'
        return [pscustomobject]@{ success = $true; exit_code = 0; launch_strategy = 'foreground'; output = ''; output_captured = $false; error = '' }
      } -ParameterFilter { $CodexHome -eq $desktopHome -and -not $PreferHiddenWindow -and $ArgumentList.Count -eq 1 -and $ArgumentList[0] -eq 'login' }
      Mock Invoke-RaymanCodexDesktopStatusValidation {
        return [pscustomobject]@{
          success = $false
          reason = 'desktop_window_not_found'
          status_command = '/status'
          quota_visible = $false
          desktop_auth_present = $true
          desktop_global_cloud_access = 'enabled'
          desktop_config_conflict = ''
          desktop_unsynced_reason = ''
        }
      }
      Mock Get-RaymanCodexLoginStatus {
        return [pscustomobject]@{
          generated_at = '2026-03-30T00:00:00Z'
          authenticated = $true
          status = 'authenticated'
          auth_mode_last = 'web'
          latest_native_session = [pscustomobject]@{ available = $false; id = ''; thread_name = ''; updated_at = ''; source = 'none'; session_index_path = '' }
        }
      }

      $result = Invoke-CodexAliasNativeLogin -Alias 'alpha' -TargetWorkspaceRoot $workspaceRoot -Mode 'web' -LoginSmoke

      [string]$result.alias | Should -Be 'alpha'
      (Get-Content -LiteralPath $desktopAuthPath -Raw -Encoding UTF8) | Should -Match '"seed":"after"'

      $report = Get-Content -LiteralPath (Join-Path $workspaceRoot '.Rayman\runtime\codex.login.last.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      [bool]$report.rollback_applied | Should -Be $false
      [string]$report.desktop_status_reason | Should -Be 'desktop_window_not_found_soft_pass'
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'runs best-effort logout before relogin for an alias' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_relogout_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_relogout_workspace_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      $account = Ensure-RaymanCodexAccount -Alias 'alpha'

      Mock Ensure-CodexCliReady {}
      Mock Invoke-CodexDeviceAuthPreflight {
        return [pscustomobject]@{ stale_processes = @(); active_processes = @(); killed_processes = @() }
      }
      Mock Invoke-RaymanCodexLogoutBestEffort {
        return [pscustomobject]@{ success = $true; not_logged_in = $false; output = 'Logged out'; exit_code = 0 }
      } -ParameterFilter { $CodexHome -eq [string]$account.codex_home -and $WorkingDirectory -eq $workspaceRoot }
      Mock Invoke-RaymanCodexRawInteractive {
        return [pscustomobject]@{ success = $true; exit_code = 0 }
      } -ParameterFilter { $CodexHome -eq [string]$account.codex_home -and -not $PreferHiddenWindow }
      Mock Get-RaymanCodexLoginStatus {
        return [pscustomobject]@{ authenticated = $true; status = 'authenticated' }
      }

      $result = Invoke-CodexAliasDeviceAuth -Alias 'alpha' -TargetWorkspaceRoot $workspaceRoot -LogoutFirst

      [string]$result.alias | Should -Be 'alpha'
      Assert-MockCalled Invoke-RaymanCodexLogoutBestEffort -Exactly 1 -ParameterFilter { $CodexHome -eq [string]$account.codex_home -and $WorkingDirectory -eq $workspaceRoot }
      Assert-MockCalled Invoke-RaymanCodexRawInteractive -Exactly 1 -ParameterFilter { $CodexHome -eq [string]$account.codex_home -and -not $PreferHiddenWindow }
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'detects wrapper-hosted device-auth processes and drops child candidates' {
    if (Test-SkipUnlessWindowsHost -Because 'Device-auth process tree inspection relies on Windows CIM.') {
      return
    }
    Mock Test-RaymanCodexWindowsHost { return $true }
    Mock Get-CimInstance {
      return @(
        [pscustomobject]@{
          ProcessId = 100
          ParentProcessId = 40
          Name = 'cmd.exe'
          CommandLine = 'C:\Windows\System32\cmd.exe /d /c "C:\Users\qinrm\AppData\Roaming\npm\codex.cmd" login --device-auth'
          CreationDate = [datetime]'2026-03-26T12:00:00Z'
        },
        [pscustomobject]@{
          ProcessId = 101
          ParentProcessId = 100
          Name = 'node.exe'
          CommandLine = '"C:\Program Files\nodejs\node.exe" "C:\Users\qinrm\AppData\Roaming\npm\node_modules\@openai\codex\bin\codex.js" login --device-auth'
          CreationDate = [datetime]'2026-03-26T12:00:01Z'
        },
        [pscustomobject]@{
          ProcessId = 200
          ParentProcessId = 41
          Name = 'powershell.exe'
          CommandLine = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Users\qinrm\AppData\Local\Temp\codex.ps1 login --device-auth'
          CreationDate = [datetime]'2026-03-26T12:00:02Z'
        },
        [pscustomobject]@{
          ProcessId = 201
          ParentProcessId = 200
          Name = 'codex.exe'
          CommandLine = 'codex.exe login --device-auth'
          CreationDate = [datetime]'2026-03-26T12:00:03Z'
        },
        [pscustomobject]@{
          ProcessId = 300
          ParentProcessId = 42
          Name = 'codex.exe'
          CommandLine = 'codex.exe login --device-auth'
          CreationDate = [datetime]'2026-03-26T12:00:04Z'
        },
        [pscustomobject]@{
          ProcessId = 400
          ParentProcessId = 43
          Name = 'powershell.exe'
          CommandLine = 'powershell.exe -File C:\Users\qinrm\AppData\Local\Temp\other.ps1 login --device-auth'
          CreationDate = [datetime]'2026-03-26T12:00:05Z'
        }
      )
    }
    Mock Invoke-CimMethod {
      return [pscustomobject]@{
        ReturnValue = 0
        User = [string]$env:USERNAME
        Domain = [string]$env:USERDOMAIN
      }
    }
    Mock Get-Process {
      param([int]$Id)
      return [pscustomobject]@{ Id = $Id }
    }

    $result = @(Get-RaymanCodexDeviceAuthProcesses -IncludeAllUsers)
    $processIds = @($result | ForEach-Object { [int]$_.process_id } | Sort-Object)

    ($processIds -join ',') | Should -Be '100,200,300'
  }

  It 'stops orphaned device-auth processes before starting login' {
    Mock Test-RaymanWindowsPlatform { return $true }
    Mock Get-RaymanCodexDeviceAuthProcesses {
      return @(
        [pscustomobject]@{
          process_id = 101
          age_seconds = 20
          parent_process_id = 88
          parent_exists = $false
          owner_user = 'tester'
          owner_domain = 'RAYMAN'
          created_at = '2026-03-25T12:00:00.0000000+08:00'
        }
      )
    }
    Mock Stop-Process {}

    $result = Invoke-CodexDeviceAuthPreflight -Alias 'alpha'

    @($result.killed_processes).Count | Should -Be 1
    Assert-MockCalled Stop-Process -Exactly 1 -ParameterFilter { $Id -eq 101 -and $Force }
  }

  It 'fails fast when an older device-auth process is still active' {
    Mock Test-RaymanWindowsPlatform { return $true }
    Mock Get-RaymanCodexDeviceAuthProcesses {
      return @(
        [pscustomobject]@{
          process_id = 201
          age_seconds = 600
          parent_process_id = 88
          parent_exists = $true
          owner_user = 'tester'
          owner_domain = 'RAYMAN'
          created_at = '2026-03-25T12:00:00.0000000+08:00'
        }
      )
    }
    Mock Stop-Process {}
    Mock Exit-CodexError {
      param([string]$Message, [int]$ExitCode)
      throw ("EXIT:{0}:{1}" -f $ExitCode, $Message)
    }

    $thrownMessage = ''
    try {
      Invoke-CodexDeviceAuthPreflight -Alias 'alpha' | Out-Null
    } catch {
      $thrownMessage = $_.Exception.Message
    }

    $thrownMessage | Should -Match '^EXIT:4:.*still active'
    Assert-MockCalled Stop-Process -Exactly 0
  }

  It 'fails fast when a fresh device-auth process is still active' {
    Mock Test-RaymanWindowsPlatform { return $true }
    Mock Get-RaymanCodexDeviceAuthProcesses {
      return @(
        [pscustomobject]@{
          process_id = 202
          age_seconds = 20
          parent_process_id = 77
          parent_exists = $true
          owner_user = 'tester'
          owner_domain = 'RAYMAN'
          created_at = '2026-03-25T12:09:40.0000000+08:00'
        }
      )
    }
    Mock Stop-Process {}
    Mock Exit-CodexError {
      param([string]$Message, [int]$ExitCode)
      throw ("EXIT:{0}:{1}" -f $ExitCode, $Message)
    }

    $thrownMessage = ''
    try {
      Invoke-CodexDeviceAuthPreflight -Alias 'alpha' | Out-Null
    } catch {
      $thrownMessage = $_.Exception.Message
    }

    $thrownMessage | Should -Match '^EXIT:4:.*still active'
    Assert-MockCalled Stop-Process -Exactly 0
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
      $workspaceUri = Get-TestWorkspaceFileUri -WorkspaceRoot $workspaceRoot
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
      $workspaceUri = Get-TestWorkspaceFileUri -WorkspaceRoot $workspaceRoot
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

  It 'allows typing an alias name directly in the switch menu fallback' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_switch_pick_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      Ensure-RaymanCodexAccount -Alias 'main' | Out-Null
      Ensure-RaymanCodexAccount -Alias 'qinrm1' | Out-Null

      Mock -CommandName Read-Host -MockWith { 'qinrm1' }
      $selection = Select-CodexAliasRow -Alias '' -Picker 'menu' -Prompt 'Select Codex alias'

      [string]$selection.alias | Should -Be 'qinrm1'
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
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
    Write-Output 'codex-cli 0.116.0'
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

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $toolRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null

      $result = Ensure-RaymanCodexCliUpToDate -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -ForceRefresh

      [bool]$result.success | Should -Be $true
      [bool]$result.compatible | Should -Be $true
      [bool]$result.updated | Should -Be $true
      [string]$result.reason | Should -Be 'compatibility_auto_updated'
      [bool]$result.latest_check_attempted | Should -Be $false
      [string]$result.version_before | Should -Be '0.47.0'
      [string]$result.version_after | Should -Be '0.116.0'
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
  Write-Output 'codex-cli 0.116.0'
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

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $toolRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))
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

  It 'policy override compatibility skips npm latest lookup even when the default policy is latest' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_override_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_override_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_override_bin_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_ENABLED', $null)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_POLICY', 'latest')
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $binRoot | Out-Null

      New-CodexTestWrapper -Root $binRoot -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
if ($argv.Count -eq 1 -and $argv[0] -eq '--version') {
  Write-Output 'codex-cli 0.116.0'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'features' -and $argv[1] -eq 'list') {
  Write-Output 'feature_a alpha true'
  exit 0
}
Write-Output 'ok'
exit 0
'@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $binRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null
      Mock Get-RaymanCodexLatestVersionInfo {
        throw 'npm latest lookup should not be called when compatibility is forced'
      }

      $result = Ensure-RaymanCodexCliUpToDate -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -ForceRefresh -PolicyOverride 'compatibility'

      [bool]$result.success | Should -Be $true
      [bool]$result.compatible | Should -Be $true
      [bool]$result.latest_check_attempted | Should -Be $false
      [string]$result.reason | Should -Be 'feature_probe_ok'
      Assert-MockCalled Get-RaymanCodexLatestVersionInfo -Exactly 0
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
    Write-Output 'codex-cli 0.120.0'
  } else {
    Write-Output 'codex-cli 0.116.0'
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
  Write-Output '0.120.0'
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

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $toolRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null

      $result = Ensure-RaymanCodexCliUpToDate -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -ForceRefresh

      [bool]$result.success | Should -Be $true
      [bool]$result.compatible | Should -Be $true
      [bool]$result.updated | Should -Be $true
      [bool]$result.latest_check_attempted | Should -Be $true
      [bool]$result.latest_check_succeeded | Should -Be $true
      [string]$result.reason | Should -Be 'updated_to_latest'
      [string]$result.version_before | Should -Be '0.116.0'
      [string]$result.latest_version | Should -Be '0.120.0'
      [string]$result.version_after | Should -Be '0.120.0'
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

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $toolRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))
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
  Write-Output 'codex-cli 0.116.0'
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

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $toolRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))
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
    Write-Output 'codex-cli 0.116.0'
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

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $toolRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null

      $result = Ensure-RaymanCodexCliUpToDate -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -ForceRefresh

      [bool]$result.success | Should -Be $true
      [bool]$result.compatible | Should -Be $true
      [bool]$result.updated | Should -Be $true
      [bool]$result.latest_check_attempted | Should -Be $true
      [bool]$result.latest_check_succeeded | Should -Be $false
      [string]$result.reason | Should -Be 'compatibility_auto_updated'
      [string]$result.version_after | Should -Be '0.116.0'
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
    Write-Output 'codex-cli 0.120.0'
  } else {
    Write-Output 'codex-cli 0.116.0'
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
  Write-Output '0.120.0'
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

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $toolRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))

      $payload = Invoke-ActionUpgrade -TargetWorkspaceRoot $workspaceRoot

      [bool]$payload.success | Should -Be $true
      [bool]$payload.compatible | Should -Be $true
      [bool]$payload.updated | Should -Be $true
      [string]$payload.reason | Should -Be 'updated_to_latest'
      [string]$payload.version_before | Should -Be '0.116.0'
      [string]$payload.latest_version | Should -Be '0.120.0'
      [string]$payload.version_after | Should -Be '0.120.0'
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
  Write-Output 'codex-cli 0.120.0'
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
  Write-Output '0.120.0'
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

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $toolRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))

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
  Write-Output 'codex-cli 0.116.0'
  exit 0
}
if (`$argv.Count -ge 2 -and `$argv[0] -eq 'features' -and `$argv[1] -eq 'list') {
  Write-Output 'feature_a alpha true'
  exit 0
}
Write-Output 'ok'
exit 0
"@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $binRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))

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

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $binRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))
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

  It 'treats a workspace .env OPENAI_API_KEY as a valid managed login for run flows' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_env_run_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_env_run_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_env_run_bin_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
      Set-Content -LiteralPath (Join-Path $workspaceRoot '.env') -Encoding UTF8 -Value "OPENAI_API_KEY=sk-dotenv-run-valid-123456`n"
      New-CodexTestWrapper -Root $binRoot -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
if ($argv.Count -eq 1 -and $argv[0] -eq '--version') {
  Write-Output 'codex-cli 0.116.0'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'features' -and $argv[1] -eq 'list') {
  Write-Output 'feature_a alpha true'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'login' -and $argv[1] -eq 'status') {
  Write-Output 'Not logged in'
  exit 1
}
Write-Output ('env=' + $env:OPENAI_API_KEY)
exit 0
'@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $binRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -Profile 'review' | Out-Null

      $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha'
      $result = Invoke-RaymanCodexCommand -WorkspaceRoot $workspaceRoot -ArgumentList @('exec', 'hello') -RequireManagedLogin -Capture
      $statusJson = $status | ConvertTo-Json -Depth 8

      [string]$status.status | Should -Be 'authenticated'
      [bool]$status.authenticated | Should -Be $true
      [string]$status.auth_mode_last | Should -Be 'api'
      [string]$status.auth_mode_detected | Should -Be 'env_apikey'
      [string]$result.output | Should -Match 'env=sk-dotenv-run-valid-123456'
      $statusJson | Should -Not -Match 'sk-dotenv-run-valid-123456'
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'does not treat malformed workspace .env OPENAI_API_KEY values as an authenticated managed login' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_env_invalid_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_env_invalid_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_env_invalid_bin_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
      Set-Content -LiteralPath (Join-Path $workspaceRoot '.env') -Encoding UTF8 -Value 'OPENAI_API_KEY="not-a-real-key" # invalid'
      New-CodexTestWrapper -Root $binRoot -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
if ($argv.Count -eq 1 -and $argv[0] -eq '--version') {
  Write-Output 'codex-cli 0.116.0'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'features' -and $argv[1] -eq 'list') {
  Write-Output 'feature_a alpha true'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'login' -and $argv[1] -eq 'status') {
  Write-Output 'Not logged in'
  exit 1
}
Write-Output ('env=' + $env:OPENAI_API_KEY)
exit 0
'@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $binRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -Profile 'review' | Out-Null

      $apiKeyState = Get-RaymanCodexEnvironmentApiKeyState -WorkspaceRoot $workspaceRoot
      $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha'
      $thrownMessage = ''
      try {
        Invoke-RaymanCodexCommand -WorkspaceRoot $workspaceRoot -ArgumentList @('exec', 'hello') -RequireManagedLogin | Out-Null
      } catch {
        $thrownMessage = $_.Exception.Message
      }

      [bool]$apiKeyState.present | Should -Be $true
      [bool]$apiKeyState.available | Should -Be $false
      [string]$apiKeyState.reason | Should -Be 'invalid_format'
      [string]$status.status | Should -Be 'not_logged_in'
      [bool]$status.authenticated | Should -Be $false
      [string]$status.auth_mode_detected | Should -Be 'unknown'
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
  Write-Output 'codex-cli 0.116.0'
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

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $binRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))
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

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $binRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))
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

  It 'maps auth.json auth_mode values into detected auth metadata without overwriting auth_mode_last' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_auth_mode_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_auth_mode_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_auth_mode_bin_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
      New-CodexTestWrapper -Root $binRoot -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
if ($argv.Count -eq 1 -and $argv[0] -eq '--version') {
  Write-Output 'codex-cli 0.116.0'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'features' -and $argv[1] -eq 'list') {
  Write-Output 'feature_a alpha true'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'login' -and $argv[1] -eq 'status') {
  Write-Output 'Logged in using ChatGPT'
  exit 0
}
Write-Output 'ok'
exit 0
'@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $binRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))
      $account = Ensure-RaymanCodexAccount -Alias 'alpha'
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -Profile '' | Out-Null
      Set-RaymanCodexAccountStatus -Alias 'alpha' -Status 'authenticated' -CheckedAt '2026-03-30T00:00:00Z' -AuthModeLast 'device' | Out-Null
      Set-Content -LiteralPath (Join-Path ([string]$account.codex_home) 'auth.json') -Encoding UTF8 -Value (@{
          auth_mode = 'chatgpt'
        } | ConvertTo-Json)

      $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha'

      [string]$status.auth_mode_detected | Should -Be 'chatgpt'
      [string]$status.auth_source | Should -Be 'native_auth_json'
      [string]$status.auth_mode_last | Should -Be 'device'
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'reports desktop repair needed when a web-target workspace still resolves to desktop API-key auth' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_desktop_repair_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_desktop_repair_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_desktop_repair_bin_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_desktop_repair_desktop_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $desktopHome | Out-Null
      New-CodexTestWrapper -Root $binRoot -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
if ($argv.Count -eq 1 -and $argv[0] -eq '--version') {
  Write-Output 'codex-cli 0.116.0'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'features' -and $argv[1] -eq 'list') {
  Write-Output 'feature_a alpha true'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'login' -and $argv[1] -eq 'status') {
  Write-Output 'Logged in using an API key - sk-****'
  exit 0
}
Write-Output 'ok'
exit 0
'@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $binRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))
      $account = Ensure-RaymanCodexAccount -Alias 'alpha'
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -Profile '' | Out-Null
      Set-RaymanCodexAccountStatus -Alias 'alpha' -Status 'authenticated' -CheckedAt '2026-03-30T00:00:00Z' -AuthModeLast 'web' | Out-Null
      Set-RaymanCodexAccountLoginDiagnostics -Alias 'alpha' -LoginMode 'web' -AuthScope 'desktop_global' -LaunchStrategy 'foreground' -PromptClassification 'none' -StartedAt '2026-03-30T00:00:00Z' -FinishedAt '2026-03-30T00:01:00Z' -Success $true -DesktopTargetMode 'web' | Out-Null
      Set-Content -LiteralPath (Join-Path ([string]$account.codex_home) 'auth.json') -Encoding UTF8 -Value (@{
          auth_mode = 'chatgpt'
          tokens = @{ account_id = 'acct-alpha' }
        } | ConvertTo-Json -Depth 6)
      Set-Content -LiteralPath (Join-Path $desktopHome 'auth.json') -Encoding UTF8 -Value '{"auth_mode":"apikey","OPENAI_API_KEY":"demo-apikey"}'
      Set-Content -LiteralPath (Join-Path $desktopHome 'config.toml') -Encoding UTF8 -Value @'
model_provider = "yunyi"

[model_providers.yunyi]
base_url = "https://api.yunyi.example.com/v1"
wire_api = "responses"
experimental_bearer_token = "demo-bearer"
requires_openai_auth = true
'@
      Set-Content -LiteralPath (Join-Path $desktopHome '.codex-global-state.json') -Encoding UTF8 -Value '{"electron-persisted-atom-state":{"codexCloudAccess":"disabled"}}'

      $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha'

      [string]$status.status | Should -Be 'desktop_repair_needed'
      [bool]$status.authenticated | Should -Be $false
      [string]$status.auth_mode_detected | Should -Be 'apikey'
      [string]$status.desktop_target_mode | Should -Be 'web'
      [string]$status.desktop_unsynced_reason | Should -Be 'desktop_home_auth_unsynced'
      [string]$status.desktop_status_reason | Should -Be 'desktop_home_auth_unsynced'
      [string]$status.desktop_config_conflict | Should -Match 'model_provider:yunyi'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $null)
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'promotes environment API keys to the managed api login mode' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_env_key_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_env_key_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_env_key_bin_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_env_key_desktop_' + [Guid]::NewGuid().ToString('N'))
    $apiKeyBackup = [Environment]::GetEnvironmentVariable('OPENAI_API_KEY')
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      [Environment]::SetEnvironmentVariable('OPENAI_API_KEY', 'sk-env-key-valid-123456')
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $desktopHome | Out-Null
      New-CodexTestWrapper -Root $binRoot -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
if ($argv.Count -eq 1 -and $argv[0] -eq '--version') {
  Write-Output 'codex-cli 0.116.0'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'features' -and $argv[1] -eq 'list') {
  Write-Output 'feature_a alpha true'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'login' -and $argv[1] -eq 'status') {
  Write-Output 'Not logged in'
  exit 1
}
Write-Output 'ok'
exit 0
'@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $binRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -Profile '' | Out-Null
      Set-RaymanCodexAccountStatus -Alias 'alpha' -Status 'authenticated' -CheckedAt '2026-03-30T00:00:00Z' -AuthModeLast 'web' | Out-Null

      $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha'

      [string]$status.status | Should -Be 'authenticated'
      [bool]$status.authenticated | Should -Be $true
      [string]$status.auth_mode_detected | Should -Be 'env_apikey'
      [string]$status.auth_source | Should -Be 'environment'
      [string]$status.auth_mode_last | Should -Be 'api'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $null)
      [Environment]::SetEnvironmentVariable('OPENAI_API_KEY', $apiKeyBackup)
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'reads latest native sessions from session_index.jsonl and exposes them in account rows' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_native_session_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_native_session_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_native_session_bin_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
      New-CodexTestWrapper -Root $binRoot -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
if ($argv.Count -eq 1 -and $argv[0] -eq '--version') {
  Write-Output 'codex-cli 0.116.0'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'features' -and $argv[1] -eq 'list') {
  Write-Output 'feature_a alpha true'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'login' -and $argv[1] -eq 'status') {
  Write-Output 'Logged in using ChatGPT'
  exit 0
}
Write-Output 'ok'
exit 0
'@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $binRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))
      $account = Ensure-RaymanCodexAccount -Alias 'alpha'
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -Profile '' | Out-Null
      Set-Content -LiteralPath (Join-Path ([string]$account.codex_home) 'session_index.jsonl') -Encoding UTF8 -Value @(
        '{"id":"sid-1","thread_name":"Older","updated_at":"2026-03-29T00:00:00Z"}'
        '{"id":"sid-2","thread_name":"Newest","updated_at":"2026-03-30T01:00:00Z"}'
      )

      $rows = @(Get-RaymanCodexAccountRows -TargetWorkspaceRoot $workspaceRoot)

      $rows.Count | Should -Be 1
      [string]$rows[0].latest_native_session.thread_name | Should -Be 'Newest'
      [string](Get-RaymanCodexAccountRecord -Alias 'alpha').latest_native_session.thread_name | Should -Be 'Newest'
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'infers desktop_global web quota visibility from the active VS Code workspace session' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_desktop_quota_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_desktop_quota_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_desktop_quota_bin_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_desktop_quota_desktop_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $desktopHome | Out-Null
      Set-Content -LiteralPath (Join-Path $desktopHome 'auth.json') -Encoding UTF8 -Value '{"auth_mode":"chatgpt","tokens":{"account_id":"acct-alpha"}}'
      Set-Content -LiteralPath (Join-Path $desktopHome '.codex-global-state.json') -Encoding UTF8 -Value '{"electron-persisted-atom-state":{"codexCloudAccess":"enabled"}}'
      $sessionPath = Write-CodexDesktopWorkspaceSession -DesktopHome $desktopHome -WorkspaceRoot $workspaceRoot -StatusMessages @(
        'OpenAI quota remaining: 97%'
        'rate limit reset in 12m'
      )
      New-CodexTestWrapper -Root $binRoot -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
if ($argv.Count -eq 1 -and $argv[0] -eq '--version') {
  Write-Output 'codex-cli 0.116.0'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'features' -and $argv[1] -eq 'list') {
  Write-Output 'feature_a alpha true'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'login' -and $argv[1] -eq 'status') {
  Write-Output 'Logged in using ChatGPT'
  exit 0
}
Write-Output 'ok'
exit 0
'@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $binRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -Profile '' | Out-Null
      Set-RaymanCodexAccountStatus -Alias 'alpha' -Status 'authenticated' -CheckedAt '2026-03-30T00:00:00Z' -AuthModeLast 'web' | Out-Null
      Set-RaymanCodexAccountLoginDiagnostics -Alias 'alpha' -LoginMode 'web' -AuthScope 'desktop_global' -LaunchStrategy 'foreground' -PromptClassification 'none' -StartedAt '2026-03-30T00:00:00Z' -FinishedAt '2026-03-30T00:01:00Z' -Success $true -DesktopTargetMode 'web' | Out-Null
      Set-RaymanCodexAccountDesktopStatusValidation -Alias 'alpha' -StatusCommand '/status' -QuotaVisible $false -Reason 'desktop_response_timeout_soft_pass' | Out-Null

      $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha'

      [string]$status.status | Should -Be 'authenticated'
      [bool]$status.authenticated | Should -Be $true
      [bool]$status.desktop_status_quota_visible | Should -Be $true
      [string]$status.desktop_status_reason | Should -Be 'quota_visible'
      [bool]$status.latest_native_session.available | Should -Be $true
      [string]$status.latest_native_session.source | Should -Be 'desktop_workspace_session'
      [string]$status.latest_native_session.id | Should -Be 'desktop-workspace-session-1'
      [string]$status.latest_native_session.session_index_path | Should -Be $sessionPath
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $null)
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'infers desktop_global web quota visibility from an active VS Code workspace session after a soft-pass timeout' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_desktop_quota_negative_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_desktop_quota_negative_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_desktop_quota_negative_bin_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_desktop_quota_negative_desktop_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $desktopHome | Out-Null
      Set-Content -LiteralPath (Join-Path $desktopHome 'auth.json') -Encoding UTF8 -Value '{"auth_mode":"chatgpt","tokens":{"account_id":"acct-alpha"}}'
      Set-Content -LiteralPath (Join-Path $desktopHome '.codex-global-state.json') -Encoding UTF8 -Value '{"electron-persisted-atom-state":{"codexCloudAccess":"enabled"}}'
      Write-CodexDesktopWorkspaceSession -DesktopHome $desktopHome -WorkspaceRoot $workspaceRoot -SessionId 'desktop-workspace-session-2' -StatusMessages @(
        'Opening workspace'
        'Waiting for response'
      ) | Out-Null
      New-CodexTestWrapper -Root $binRoot -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
if ($argv.Count -eq 1 -and $argv[0] -eq '--version') {
  Write-Output 'codex-cli 0.116.0'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'features' -and $argv[1] -eq 'list') {
  Write-Output 'feature_a alpha true'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'login' -and $argv[1] -eq 'status') {
  Write-Output 'Logged in using ChatGPT'
  exit 0
}
Write-Output 'ok'
exit 0
'@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $binRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -Profile '' | Out-Null
      Set-RaymanCodexAccountStatus -Alias 'alpha' -Status 'authenticated' -CheckedAt '2026-03-30T00:00:00Z' -AuthModeLast 'web' | Out-Null
      Set-RaymanCodexAccountLoginDiagnostics -Alias 'alpha' -LoginMode 'web' -AuthScope 'desktop_global' -LaunchStrategy 'foreground' -PromptClassification 'none' -StartedAt '2026-03-30T00:00:00Z' -FinishedAt '2026-03-30T00:01:00Z' -Success $true -DesktopTargetMode 'web' | Out-Null
      Set-RaymanCodexAccountDesktopStatusValidation -Alias 'alpha' -StatusCommand '/status' -QuotaVisible $false -Reason 'desktop_response_timeout_soft_pass' | Out-Null

      $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha'

      [bool]$status.desktop_status_quota_visible | Should -Be $true
      [string]$status.desktop_status_reason | Should -Be 'quota_visible_vscode_session'
      [bool]$status.latest_native_session.available | Should -Be $true
      [string]$status.latest_native_session.source | Should -Be 'desktop_workspace_session'
      [string]$status.latest_native_session.id | Should -Be 'desktop-workspace-session-2'
      [string]$status.known_error_signature | Should -Be ''
      [bool]$status.repeat_prevented | Should -Be $false
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $null)
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'does not override desktop_global web repair signals when desktop cloud access is disabled' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_desktop_quota_cloud_disabled_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_desktop_quota_cloud_disabled_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_desktop_quota_cloud_disabled_bin_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_desktop_quota_cloud_disabled_desktop_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $desktopHome | Out-Null
      Set-Content -LiteralPath (Join-Path $desktopHome 'auth.json') -Encoding UTF8 -Value '{"auth_mode":"chatgpt","tokens":{"account_id":"acct-alpha"}}'
      Set-Content -LiteralPath (Join-Path $desktopHome '.codex-global-state.json') -Encoding UTF8 -Value '{"electron-persisted-atom-state":{"codexCloudAccess":"disabled"}}'
      Write-CodexDesktopWorkspaceSession -DesktopHome $desktopHome -WorkspaceRoot $workspaceRoot -SessionId 'desktop-workspace-session-3' -StatusMessages @(
        'Opening workspace'
        'Waiting for response'
      ) | Out-Null
      New-CodexTestWrapper -Root $binRoot -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
if ($argv.Count -eq 1 -and $argv[0] -eq '--version') {
  Write-Output 'codex-cli 0.116.0'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'features' -and $argv[1] -eq 'list') {
  Write-Output 'feature_a alpha true'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'login' -and $argv[1] -eq 'status') {
  Write-Output 'Logged in using ChatGPT'
  exit 0
}
Write-Output 'ok'
exit 0
'@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $binRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -Profile '' | Out-Null
      Set-RaymanCodexAccountStatus -Alias 'alpha' -Status 'authenticated' -CheckedAt '2026-03-30T00:00:00Z' -AuthModeLast 'web' | Out-Null
      Set-RaymanCodexAccountLoginDiagnostics -Alias 'alpha' -LoginMode 'web' -AuthScope 'desktop_global' -LaunchStrategy 'foreground' -PromptClassification 'none' -StartedAt '2026-03-30T00:00:00Z' -FinishedAt '2026-03-30T00:01:00Z' -Success $true -DesktopTargetMode 'web' | Out-Null
      Set-RaymanCodexAccountDesktopStatusValidation -Alias 'alpha' -StatusCommand '/status' -QuotaVisible $false -Reason 'desktop_response_timeout_soft_pass' | Out-Null

      $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha'

      [string]$status.status | Should -Be 'desktop_repair_needed'
      [bool]$status.authenticated | Should -Be $false
      [bool]$status.desktop_status_quota_visible | Should -Be $false
      [string]$status.desktop_status_reason | Should -Be 'desktop_response_timeout_soft_pass'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $null)
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'flags a repeat error when desktop_global Yunyi targets detect ChatGPT auth instead' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_repeat_guard_yunyi_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_repeat_guard_yunyi_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_repeat_guard_yunyi_bin_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_repeat_guard_yunyi_desktop_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $desktopHome | Out-Null
      Set-Content -LiteralPath (Join-Path $desktopHome 'auth.json') -Encoding UTF8 -Value '{"auth_mode":"chatgpt","tokens":{"account_id":"acct-alpha"}}'
      Set-Content -LiteralPath (Join-Path $desktopHome '.codex-global-state.json') -Encoding UTF8 -Value '{"electron-persisted-atom-state":{"codexCloudAccess":"enabled"}}'
      New-CodexTestWrapper -Root $binRoot -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
if ($argv.Count -eq 1 -and $argv[0] -eq '--version') {
  Write-Output 'codex-cli 0.116.0'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'features' -and $argv[1] -eq 'list') {
  Write-Output 'feature_a alpha true'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'login' -and $argv[1] -eq 'status') {
  Write-Output 'Logged in using ChatGPT'
  exit 0
}
Write-Output 'ok'
exit 0
'@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $binRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -Profile '' | Out-Null
      Set-RaymanCodexAccountStatus -Alias 'alpha' -Status 'desktop_repair_needed' -CheckedAt '2026-03-30T00:00:00Z' -AuthModeLast 'yunyi' | Out-Null
      Set-RaymanCodexAccountLoginDiagnostics -Alias 'alpha' -LoginMode 'yunyi' -AuthScope 'desktop_global' -LaunchStrategy 'switch' -PromptClassification 'config_not_yunyi' -StartedAt '2026-03-30T00:00:00Z' -FinishedAt '2026-03-30T00:01:00Z' -Success $false -DesktopTargetMode 'yunyi' | Out-Null
      Set-RaymanCodexAccountDesktopStatusValidation -Alias 'alpha' -StatusCommand '/status' -QuotaVisible $false -Reason 'config_not_yunyi' | Out-Null
      Set-TestCodexAccountAuthScope -Alias 'alpha' -AuthScope 'desktop_global'

      $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha'

      [string]$status.known_error_signature | Should -Be 'account_mode_mismatch'
      [string]$status.known_error_severity | Should -Be 'error'
      [bool]$status.repeat_prevented | Should -Be $true
      [string]$status.guard_stage | Should -Be 'codex.status'
      [string]$status.repair_command | Should -Be 'rayman codex login --alias alpha'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $null)
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'flags a repeat error when desktop target mode drifts away from the saved login mode' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_repeat_guard_target_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_repeat_guard_target_workspace_' + [Guid]::NewGuid().ToString('N'))
    $binRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_repeat_guard_target_bin_' + [Guid]::NewGuid().ToString('N'))
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_repeat_guard_target_desktop_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $desktopHome | Out-Null
      Set-Content -LiteralPath (Join-Path $desktopHome '.codex-global-state.json') -Encoding UTF8 -Value '{"electron-persisted-atom-state":{"codexCloudAccess":"enabled"}}'
      New-CodexTestWrapper -Root $binRoot -ScriptBody @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$argv)
if ($argv.Count -eq 1 -and $argv[0] -eq '--version') {
  Write-Output 'codex-cli 0.116.0'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'features' -and $argv[1] -eq 'list') {
  Write-Output 'feature_a alpha true'
  exit 0
}
if ($argv.Count -ge 2 -and $argv[0] -eq 'login' -and $argv[1] -eq 'status') {
  Write-Output 'Not logged in'
  exit 1
}
Write-Output 'ok'
exit 0
'@ | Out-Null

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $binRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -Profile '' | Out-Null
      Set-RaymanCodexAccountStatus -Alias 'alpha' -Status 'desktop_repair_needed' -CheckedAt '2026-03-30T00:00:00Z' -AuthModeLast 'web' | Out-Null
      Set-RaymanCodexAccountLoginDiagnostics -Alias 'alpha' -LoginMode 'web' -AuthScope 'desktop_global' -LaunchStrategy 'switch' -PromptClassification 'none' -StartedAt '2026-03-30T00:00:00Z' -FinishedAt '2026-03-30T00:01:00Z' -Success $false -DesktopTargetMode 'yunyi' | Out-Null
      Set-RaymanCodexAccountDesktopStatusValidation -Alias 'alpha' -StatusCommand '/status' -QuotaVisible $false -Reason 'config_not_yunyi' | Out-Null
      Set-TestCodexAccountAuthScope -Alias 'alpha' -AuthScope 'desktop_global'

      $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha'

      [string]$status.known_error_signature | Should -Be 'desktop_target_mode_mismatch'
      [bool]$status.repeat_prevented | Should -Be $true
      [string]$status.repair_command | Should -Be 'rayman codex login --alias alpha'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $null)
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $binRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'includes auth mode and session summary fields in status and list JSON payloads' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_json_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_json_workspace_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -Profile 'review' | Out-Null

      Mock Ensure-CodexCliReady {
        return [pscustomobject]@{ success = $true; compatible = $true; updated = $false; reason = 'already_latest'; version_before = '0.116.0'; version_after = '0.116.0'; latest_version = '0.116.0'; latest_check_attempted = $true; latest_check_succeeded = $true; latest_check_output = ''; output = '' }
      }
      Mock Get-RaymanCodexLoginStatus {
        return [pscustomobject]@{
          schema = 'rayman.codex.auth.status.v1'
          generated_at = '2026-03-30T00:00:00Z'
          workspace_root = $workspaceRoot
          account_alias = 'alpha'
          profile = 'review'
          profile_source = 'binding'
          codex_home = 'C:\Users\tester\.codex'
          alias_codex_home = 'C:\temp\alpha'
          desktop_codex_home = 'C:\Users\tester\.codex'
          auth_scope = 'desktop_global'
          managed = $true
          account_known = $true
          authenticated = $true
          status = 'authenticated'
          exit_code = 0
          command = 'codex login status'
          output = @('Logged in using ChatGPT')
          repair_command = 'rayman codex login --alias alpha'
          known_error_signature = ''
          known_error_severity = ''
          known_error_message = ''
          guard_stage = 'codex.status'
          repeat_prevented = $false
          auth_mode_last = 'web'
          auth_mode_detected = 'chatgpt'
          auth_source = 'native_auth_json'
          last_login_mode = 'web'
          last_login_strategy = 'foreground'
          last_login_prompt_classification = 'none'
          last_login_success = $true
          last_yunyi_base_url = 'https://api.yunyi.example.com/v1'
          last_yunyi_success_at = '2026-03-29T23:59:00Z'
          last_yunyi_config_ready = $true
          last_yunyi_reuse_reason = 'last_yunyi_config'
          last_yunyi_base_url_source = 'config:alias'
          login_smoke_mode = 'web'
          login_smoke_next_allowed_at = '2026-03-30T02:00:00Z'
          login_smoke_throttled = $true
          desktop_auth_present = $true
          desktop_global_cloud_access = 'enabled'
          desktop_target_mode = 'web'
          desktop_saved_token_reused = $true
          desktop_saved_token_source = 'alias_auth'
          desktop_status_command = '/status'
          desktop_status_quota_visible = $true
          desktop_status_reason = 'quota_visible'
          desktop_config_conflict = ''
          desktop_unsynced_reason = ''
          latest_native_session = [pscustomobject]@{ available = $true; id = 'sid-1'; thread_name = 'Newest'; updated_at = '2026-03-30T01:00:00Z'; source = 'session_index_jsonl'; session_index_path = 'C:\temp\alpha\session_index.jsonl' }
          saved_state_summary = [pscustomobject]@{ workspace_root = $workspaceRoot; account_alias = 'alpha'; total_count = 2; manual_count = 1; auto_temp_count = 1; latest = [pscustomobject]@{ name = 'Fresh'; slug = 'fresh'; session_kind = 'manual'; updated_at = '2026-03-30T01:10:00Z' }; recent_saved_states = @([pscustomobject]@{ name = 'Fresh'; slug = 'fresh'; session_kind = 'manual'; updated_at = '2026-03-30T01:10:00Z' }) }
          recent_saved_states = @([pscustomobject]@{ name = 'Fresh'; slug = 'fresh'; session_kind = 'manual'; updated_at = '2026-03-30T01:10:00Z' })
        }
      }

      $statusPayload = Invoke-ActionStatus -TargetWorkspaceRoot $workspaceRoot -AsJson | ConvertFrom-Json
      $listPayload = Invoke-ActionList -TargetWorkspaceRoot $workspaceRoot -AsJson | ConvertFrom-Json

      [string]$statusPayload.auth.auth_mode_last | Should -Be 'web'
      [string]$statusPayload.auth.auth_mode_detected | Should -Be 'chatgpt'
      [string]$statusPayload.auth.auth_source | Should -Be 'native_auth_json'
      [string]$statusPayload.auth.known_error_signature | Should -Be ''
      [string]$statusPayload.auth.guard_stage | Should -Be 'codex.status'
      [bool]$statusPayload.auth.repeat_prevented | Should -Be $false
      [string]$statusPayload.auth.last_login_mode | Should -Be 'web'
      [string]$statusPayload.auth.last_login_strategy | Should -Be 'foreground'
      [string]$statusPayload.auth.auth_scope | Should -Be 'desktop_global'
      [string]$statusPayload.auth.desktop_codex_home | Should -Be 'C:\Users\tester\.codex'
      [string]$statusPayload.auth.desktop_target_mode | Should -Be 'web'
      [bool]$statusPayload.auth.desktop_saved_token_reused | Should -Be $true
      [string]$statusPayload.auth.desktop_saved_token_source | Should -Be 'alias_auth'
      [bool]$statusPayload.auth.desktop_status_quota_visible | Should -Be $true
      [string]$statusPayload.auth.desktop_status_reason | Should -Be 'quota_visible'
      [string]$statusPayload.auth.desktop_config_conflict | Should -Be ''
      [string]$statusPayload.auth.desktop_unsynced_reason | Should -Be ''
      [string]$statusPayload.auth.last_yunyi_base_url | Should -Be 'https://api.yunyi.example.com/v1'
      [bool]$statusPayload.auth.last_yunyi_config_ready | Should -Be $true
      [string]$statusPayload.auth.last_yunyi_reuse_reason | Should -Be 'last_yunyi_config'
      ([datetimeoffset]$statusPayload.auth.login_smoke_next_allowed_at).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') | Should -Be '2026-03-30T02:00:00Z'
      [string]$statusPayload.auth.latest_native_session.thread_name | Should -Be 'Newest'
      [int]$statusPayload.auth.saved_state_summary.total_count | Should -Be 2
      [string]$listPayload.accounts[0].auth_mode_last | Should -Be 'web'
      [string]$listPayload.accounts[0].last_login_mode | Should -Be 'web'
      [string]$listPayload.accounts[0].last_login_strategy | Should -Be 'foreground'
      [string]$listPayload.accounts[0].auth_scope | Should -Be 'desktop_global'
      [string]$listPayload.accounts[0].known_error_signature | Should -Be ''
      [string]$listPayload.accounts[0].guard_stage | Should -Be 'codex.status'
      [bool]$listPayload.accounts[0].repeat_prevented | Should -Be $false
      [string]$listPayload.accounts[0].effective_codex_home | Should -Be 'C:\Users\tester\.codex'
      [string]$listPayload.accounts[0].desktop_target_mode | Should -Be 'web'
      [bool]$listPayload.accounts[0].desktop_saved_token_reused | Should -Be $true
      [string]$listPayload.accounts[0].desktop_saved_token_source | Should -Be 'alias_auth'
      [bool]$listPayload.accounts[0].desktop_status_quota_visible | Should -Be $true
      [string]$listPayload.accounts[0].desktop_config_conflict | Should -Be ''
      [string]$listPayload.accounts[0].desktop_unsynced_reason | Should -Be ''
      [string]$listPayload.accounts[0].last_yunyi_base_url | Should -Be 'https://api.yunyi.example.com/v1'
      [bool]$listPayload.accounts[0].last_yunyi_config_ready | Should -Be $true
      [string]$listPayload.accounts[0].last_yunyi_reuse_reason | Should -Be 'last_yunyi_config'
      [string]$listPayload.accounts[0].latest_native_session.thread_name | Should -Be 'Newest'
      [int]$listPayload.accounts[0].saved_state_summary.total_count | Should -Be 2
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'reports desktop-global Yunyi activation in status and list JSON payloads' {
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_json_yunyi_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_json_yunyi_workspace_' + [Guid]::NewGuid().ToString('N'))
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -Profile 'review' | Out-Null

      Mock Ensure-CodexCliReady {
        return [pscustomobject]@{ success = $true; compatible = $true; updated = $false; reason = 'already_latest'; version_before = '0.116.0'; version_after = '0.116.0'; latest_version = '0.116.0'; latest_check_attempted = $true; latest_check_succeeded = $true; latest_check_output = ''; output = '' }
      }
      Mock Get-RaymanCodexLoginStatus {
        return [pscustomobject]@{
          schema = 'rayman.codex.auth.status.v1'
          generated_at = '2026-03-30T00:00:00Z'
          workspace_root = $workspaceRoot
          account_alias = 'alpha'
          profile = 'review'
          profile_source = 'binding'
          codex_home = 'C:\Users\tester\.codex'
          alias_codex_home = 'C:\temp\alpha'
          desktop_codex_home = 'C:\Users\tester\.codex'
          auth_scope = 'desktop_global'
          managed = $true
          account_known = $true
          authenticated = $true
          status = 'authenticated'
          exit_code = 0
          command = 'codex login status'
          output = @('Logged in using an API key - yy-****')
          repair_command = 'rayman codex login --alias alpha'
          auth_mode_last = 'yunyi'
          auth_mode_detected = 'apikey'
          auth_source = 'native_auth_json'
          last_login_mode = 'yunyi'
          last_login_strategy = 'switch'
          last_login_prompt_classification = 'none'
          last_login_success = $true
          last_yunyi_base_url = 'https://api.yunyi.example.com/v1'
          last_yunyi_success_at = '2026-03-29T23:59:00Z'
          last_yunyi_config_ready = $true
          last_yunyi_reuse_reason = 'last_yunyi_config'
          last_yunyi_base_url_source = 'config:alias'
          login_smoke_mode = ''
          login_smoke_next_allowed_at = ''
          login_smoke_throttled = $false
          desktop_auth_present = $true
          desktop_global_cloud_access = 'disabled'
          desktop_target_mode = 'yunyi'
          desktop_saved_token_reused = $false
          desktop_saved_token_source = 'user_home:auth.json.yunyi'
          desktop_status_command = '/status'
          desktop_status_quota_visible = $false
          desktop_status_reason = 'api_key_active'
          desktop_config_conflict = ''
          desktop_unsynced_reason = ''
          latest_native_session = [pscustomobject]@{ available = $false; id = ''; thread_name = ''; updated_at = ''; source = 'none'; session_index_path = 'C:\temp\alpha\session_index.jsonl' }
          saved_state_summary = [pscustomobject]@{ workspace_root = $workspaceRoot; account_alias = 'alpha'; total_count = 0; manual_count = 0; auto_temp_count = 0; latest = $null; recent_saved_states = @() }
          recent_saved_states = @()
        }
      }

      $statusPayload = Invoke-ActionStatus -TargetWorkspaceRoot $workspaceRoot -AsJson | ConvertFrom-Json
      $listPayload = Invoke-ActionList -TargetWorkspaceRoot $workspaceRoot -AsJson | ConvertFrom-Json

      [string]$statusPayload.auth.auth_mode_last | Should -Be 'yunyi'
      [string]$statusPayload.auth.auth_mode_detected | Should -Be 'apikey'
      [string]$statusPayload.auth.auth_scope | Should -Be 'desktop_global'
      [string]$statusPayload.auth.desktop_target_mode | Should -Be 'yunyi'
      [string]$statusPayload.auth.desktop_global_cloud_access | Should -Be 'disabled'
      [bool]$statusPayload.auth.desktop_status_quota_visible | Should -Be $false
      [string]$statusPayload.auth.desktop_status_reason | Should -Be 'api_key_active'
      [string]$statusPayload.auth.last_yunyi_base_url | Should -Be 'https://api.yunyi.example.com/v1'
      [bool]$statusPayload.auth.last_yunyi_config_ready | Should -Be $true
      [string]$listPayload.accounts[0].auth_mode_last | Should -Be 'yunyi'
      [string]$listPayload.accounts[0].auth_scope | Should -Be 'desktop_global'
      [string]$listPayload.accounts[0].desktop_target_mode | Should -Be 'yunyi'
      [string]$listPayload.accounts[0].desktop_global_cloud_access | Should -Be 'disabled'
      [string]$listPayload.accounts[0].desktop_status_reason | Should -Be 'api_key_active'
      [string]$listPayload.accounts[0].last_yunyi_base_url | Should -Be 'https://api.yunyi.example.com/v1'
    } finally {
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
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
  Write-Output 'codex-cli 0.116.0'
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

      [Environment]::SetEnvironmentVariable('PATH', (Join-TestPath -Entry $binRoot -CurrentPath ([Environment]::GetEnvironmentVariable('PATH'))))

      Invoke-ActionLogin -Alias 'alpha' -Profile '' -TargetWorkspaceRoot $workspaceRoot -Picker 'menu' -Mode 'device'

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

  It 'auto-applies the bound desktop-global alias from workspace bootstrap flows' {
    if (Test-SkipUnlessWindowsHost -Because 'Desktop-global workspace auto-apply is Windows-only.') {
      return
    }
    $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_binding_auto_apply_state_' + [Guid]::NewGuid().ToString('N'))
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_binding_auto_apply_workspace_' + [Guid]::NewGuid().ToString('N'))
    $homeBackup = [Environment]::GetEnvironmentVariable('RAYMAN_HOME')
    $autoApplyBackup = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_WORKSPACE_BINDING_AUTO_APPLY_ENABLED')
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $stateRoot)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_WORKSPACE_BINDING_AUTO_APPLY_ENABLED', '1')
      New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot -AccountAlias 'alpha' -Profile '' | Out-Null
      Set-RaymanCodexAccountLoginDiagnostics -Alias 'alpha' -LoginMode 'web' -AuthScope 'desktop_global' -LaunchStrategy 'switch' -PromptClassification 'none' -StartedAt '2026-04-17T00:00:00Z' -FinishedAt '2026-04-17T00:00:05Z' -Success $true -DesktopTargetMode 'web' | Out-Null

      Mock Invoke-RaymanCodexDesktopAliasActivation {
        [pscustomobject]@{
          attempted = $true
          success = $true
          reason = 'desktop_activation_applied'
          status = [pscustomobject]@{
            authenticated = $true
            status = 'authenticated'
          }
        }
      } -ParameterFilter { [string]$Alias -eq 'alpha' -and [string]$Mode -eq 'web' }
      Mock Sync-WorkspaceTrust {
        [pscustomobject]@{
          changed = $false
          trust_level = 'trusted'
          config_path = 'mock-config.toml'
        }
      } -ParameterFilter { [string]$WorkspaceRoot -eq $workspaceRoot -and [string]$Alias -eq 'alpha' }

      $result = Invoke-RaymanCodexWorkspaceBindingAutoApply -WorkspaceRoot $workspaceRoot -Reason 'pester'

      [bool]$result.attempted | Should -Be $true
      [bool]$result.success | Should -Be $true
      [string]$result.alias | Should -Be 'alpha'
      [string]$result.mode | Should -Be 'web'
      [bool]$result.trust_synced | Should -Be $true
      Assert-MockCalled Invoke-RaymanCodexDesktopAliasActivation -Times 1 -Exactly -ParameterFilter { [string]$Alias -eq 'alpha' -and [string]$Mode -eq 'web' }
      Assert-MockCalled Sync-WorkspaceTrust -Times 1 -Exactly -ParameterFilter { [string]$WorkspaceRoot -eq $workspaceRoot -and [string]$Alias -eq 'alpha' }
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $homeBackup)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_WORKSPACE_BINDING_AUTO_APPLY_ENABLED', $autoApplyBackup)
      Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'supports explicit gpt-alt login through the VS Code bundled codex fallback' {
    if (Test-SkipUnlessWindowsHost -Because 'VS Code bundled codex fallback is Windows-only.') {
      return
    }
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
  Write-Output 'codex-cli 0.116.0'
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

      Invoke-ActionLogin -Alias 'gpt-alt' -Profile '' -TargetWorkspaceRoot $workspaceRoot -Picker 'menu' -Mode 'device'

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
