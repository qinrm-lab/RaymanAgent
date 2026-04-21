BeforeAll {
  $script:WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  . (Join-Path $script:WorkspaceRoot '.Rayman\scripts\workspace\register_workspace.ps1') -NoMain
  . (Join-Path $script:WorkspaceRoot '.Rayman\scripts\workspace\registered_workspace_bootstrap.ps1') -NoMain
  $script:WorkspaceRegisterIsWindowsHost = [bool](Test-RaymanWindowsPlatform)

  function script:Initialize-TestWorkspaceRegisterSource {
    param([string]$Root)

    foreach ($path in @(
        (Join-Path $Root '.Rayman'),
        (Join-Path $Root '.Rayman\scripts\workspace'),
        (Join-Path $Root '.RaymanAgent')
      )) {
      New-Item -ItemType Directory -Force -Path $path | Out-Null
    }

    Set-Content -LiteralPath (Join-Path $Root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\setup.ps1') -Encoding UTF8 -Value 'Write-Output ''setup'''
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\rayman.ps1') -Encoding UTF8 -Value 'Write-Output ''rayman'''
    Set-Content -LiteralPath (Join-Path $Root '.RaymanAgent\.RaymanAgent.requirements.md') -Encoding UTF8 -Value '# requirements'
  }
}

Describe 'workspace register' {
  BeforeEach {
    $script:UserEnv = @{}
    $script:ProcessEnv = @{}
    Mock Get-RaymanWorkspaceRegisterUserEnvironmentVariable {
      param([string]$Name)
      if ($script:UserEnv.ContainsKey($Name)) {
        return [string]$script:UserEnv[$Name]
      }
      return $null
    }
    Mock Set-RaymanWorkspaceRegisterUserEnvironmentVariable {
      param(
        [string]$Name,
        [string]$Value
      )
      if ($null -eq $Value) {
        $script:UserEnv.Remove($Name) | Out-Null
      } else {
        $script:UserEnv[$Name] = [string]$Value
      }
    }
    Mock Get-RaymanWorkspaceRegisterProcessEnvironmentVariable {
      param([string]$Name)
      if ($script:ProcessEnv.ContainsKey($Name)) {
        return [string]$script:ProcessEnv[$Name]
      }
      return $null
    }
    Mock Set-RaymanWorkspaceRegisterProcessEnvironmentVariable {
      param(
        [string]$Name,
        [string]$Value
      )
      if ($null -eq $Value) {
        $script:ProcessEnv.Remove($Name) | Out-Null
      } else {
        $script:ProcessEnv[$Name] = [string]$Value
      }
    }
    Mock Invoke-RaymanWorkspaceRegisterEnvironmentBroadcast { return $true }
  }

  It 'writes source state, launchers, and the VS Code user task' {
    if (-not $script:WorkspaceRegisterIsWindowsHost) {
      Set-ItResult -Skipped -Because 'workspace-register requires Windows.'
      return
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_register_' + [Guid]::NewGuid().ToString('N'))
    $localAppData = Join-Path $tempRoot 'LocalAppData'
    $appData = Join-Path $tempRoot 'AppData'
    $userProfile = Join-Path $tempRoot 'UserProfile'
    $sourceRoot = Join-Path $tempRoot 'RaymanAgent'
    $originalLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    $originalAppData = [Environment]::GetEnvironmentVariable('APPDATA')
    $originalUserProfile = [Environment]::GetEnvironmentVariable('USERPROFILE')
    $originalHome = [Environment]::GetEnvironmentVariable('HOME')

    try {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $localAppData)
      [Environment]::SetEnvironmentVariable('APPDATA', $appData)
      [Environment]::SetEnvironmentVariable('USERPROFILE', $userProfile)
      [Environment]::SetEnvironmentVariable('HOME', $userProfile)
      Initialize-TestWorkspaceRegisterSource -Root $sourceRoot
      New-Item -ItemType Directory -Force -Path (Get-RaymanWorkspaceRegisterStartupRoot) | Out-Null
      Set-Content -LiteralPath (Get-RaymanWorkspaceRegisterDesktopBootstrapLegacyStartupCmdPath) -Encoding ASCII -Value '@echo off'

      $result = Invoke-RaymanWorkspaceRegister -WorkspaceRoot $sourceRoot
      $state = Read-RaymanWorkspaceRegisterJsonFile -Path (Get-RaymanWorkspaceRegisterSourceStatePath)
      $tasks = Read-RaymanWorkspaceRegisterJsonDoc -Path (Get-RaymanWorkspaceRegisterVsCodeTasksPath)
      $codexConfigPath = Get-RaymanWorkspaceRegisterCodexConfigPath

      $result.success | Should -Be $true
      $result.status | Should -Be 'registered'
      $result.path_registered | Should -Be $true
      $result.vscode_registered | Should -Be $true
      $result.desktop_bootstrap_registered | Should -Be $true
      $result.desktop_notify_registered | Should -Be $true
      [string]$result.updated_at | Should -Match '^\d{4}-\d{2}-\d{2}T'
      Test-Path -LiteralPath $result.launcher_path | Should -Be $true
      Test-Path -LiteralPath $result.launcher_paths.ps1_path | Should -Be $true
      Test-Path -LiteralPath $result.launcher_paths.cmd_path | Should -Be $true
      Test-Path -LiteralPath $result.launcher_paths.shim_cmd_path | Should -Be $true
      Test-Path -LiteralPath $result.desktop_bootstrap_paths.ps1_path | Should -Be $true
      Test-Path -LiteralPath $result.desktop_bootstrap_paths.cmd_path | Should -Be $true
      Test-Path -LiteralPath $result.desktop_bootstrap_paths.startup_path | Should -Be $true
      Test-Path -LiteralPath $result.desktop_bootstrap_paths.startup_vbs_path | Should -Be $true
      Test-Path -LiteralPath $result.desktop_notify_script_path | Should -Be $true
      Test-Path -LiteralPath $result.desktop_notify_config_path | Should -Be $true
      Test-Path -LiteralPath (Get-RaymanWorkspaceRegisterDesktopBootstrapLegacyStartupCmdPath) | Should -Be $false
      [string]$result.launcher_path | Should -Be ([string]$result.launcher_paths.shim_cmd_path)
      $state.source_workspace_path | Should -Be ([System.IO.Path]::GetFullPath($sourceRoot))
      $state.rayman_version | Should -Be 'v161'
      $result.published_version | Should -Be 'v161'
      [string]$result.published_fingerprint | Should -Not -Be ''
      $state.published_version | Should -Be 'v161'
      $state.published_fingerprint | Should -Be $result.published_fingerprint
      $last = Read-RaymanWorkspaceRegisterJsonFile -Path (Get-RaymanWorkspaceRegisterLastPath)
      $last.source_workspace_path | Should -Be ([System.IO.Path]::GetFullPath($sourceRoot))
      [string]$last.updated_at | Should -Match '^\d{4}-\d{2}-\d{2}T'
      $tasks.ParseFailed | Should -Be $false
      @($tasks.Obj.tasks | ForEach-Object { [string]$_.label }) | Should -Contain 'Rayman: Bootstrap Current Workspace'
      @($tasks.Obj.tasks | ForEach-Object { [string]$_.label }) | Should -Contain 'Rayman: Auto Upgrade Installed Workspace'
      $bootstrapTask = @($tasks.Obj.tasks | Where-Object { [string]$_.label -eq 'Rayman: Bootstrap Current Workspace' } | Select-Object -First 1)[0]
      $autoUpgradeTask = @($tasks.Obj.tasks | Where-Object { [string]$_.label -eq 'Rayman: Auto Upgrade Installed Workspace' } | Select-Object -First 1)[0]
      $expectedPsHost = [string](Resolve-RaymanPowerShellHost)
      if ([string]::IsNullOrWhiteSpace([string]$expectedPsHost)) {
        $expectedPsHost = 'powershell.exe'
      }
      [string]$bootstrapTask.command | Should -Be $expectedPsHost
      @($bootstrapTask.args) | Should -Be @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ([string]$result.launcher_paths.ps1_path))
      [string]$autoUpgradeTask.command | Should -Be $expectedPsHost
      @($autoUpgradeTask.args) | Should -Be @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ([string]$result.launcher_paths.ps1_path), '--auto-on-open')
      [bool]$autoUpgradeTask.hide | Should -Be $true
      [string]$autoUpgradeTask.runOptions.runOn | Should -Be 'folderOpen'
      (Get-Content -LiteralPath $result.desktop_bootstrap_paths.ps1_path -Raw -Encoding UTF8) | Should -Match 'codex_desktop_bootstrap\.ps1'
      (Get-Content -LiteralPath $result.desktop_bootstrap_paths.startup_path -Raw -Encoding UTF8) | Should -Match 'powershell\.exe'
      (Get-Content -LiteralPath $result.desktop_bootstrap_paths.startup_path -Raw -Encoding UTF8) | Should -Match 'rayman-codex-desktop-bootstrap\.ps1'
      (Get-Content -LiteralPath $result.desktop_bootstrap_paths.startup_path -Raw -Encoding UTF8) | Should -Match 'shell\.Run'
      (Get-Content -LiteralPath $result.desktop_notify_script_path -Raw -Encoding UTF8) | Should -Match 'agent-turn-complete'
      (Get-Content -LiteralPath $codexConfigPath -Raw -Encoding UTF8) | Should -Match '# >>> Rayman managed notify >>>'
      (Get-Content -LiteralPath $codexConfigPath -Raw -Encoding UTF8) | Should -Match ([regex]::Escape(([string]$result.desktop_notify_script_path -replace '\\', '\\\\')))
      (Test-RaymanWorkspaceRegisterPathInList -PathList ([string]$script:UserEnv['Path']) -CandidatePath (Get-RaymanWorkspaceRegisterBinRoot)) | Should -Be $true
      Should -Invoke Invoke-RaymanWorkspaceRegisterEnvironmentBroadcast -Times 1 -Exactly
    } finally {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $originalLocalAppData)
      [Environment]::SetEnvironmentVariable('APPDATA', $originalAppData)
      [Environment]::SetEnvironmentVariable('USERPROFILE', $originalUserProfile)
      [Environment]::SetEnvironmentVariable('HOME', $originalHome)
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'supports no-vscode and no-path without writing those surfaces' {
    if (-not $script:WorkspaceRegisterIsWindowsHost) {
      Set-ItResult -Skipped -Because 'workspace-register requires Windows.'
      return
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_register_flags_' + [Guid]::NewGuid().ToString('N'))
    $localAppData = Join-Path $tempRoot 'LocalAppData'
    $appData = Join-Path $tempRoot 'AppData'
    $userProfile = Join-Path $tempRoot 'UserProfile'
    $sourceRoot = Join-Path $tempRoot 'RaymanAgent'
    $originalLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    $originalAppData = [Environment]::GetEnvironmentVariable('APPDATA')
    $originalUserProfile = [Environment]::GetEnvironmentVariable('USERPROFILE')
    $originalHome = [Environment]::GetEnvironmentVariable('HOME')

    try {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $localAppData)
      [Environment]::SetEnvironmentVariable('APPDATA', $appData)
      [Environment]::SetEnvironmentVariable('USERPROFILE', $userProfile)
      [Environment]::SetEnvironmentVariable('HOME', $userProfile)
      Initialize-TestWorkspaceRegisterSource -Root $sourceRoot

      $result = Invoke-RaymanWorkspaceRegister -WorkspaceRoot $sourceRoot -NoVsCode -NoPath

      $result.success | Should -Be $true
      $result.vscode_registered | Should -Be $false
      $result.path_registered | Should -Be $false
      $result.desktop_bootstrap_registered | Should -Be $true
      $result.desktop_notify_registered | Should -Be $true
      Test-Path -LiteralPath (Get-RaymanWorkspaceRegisterVsCodeTasksPath) | Should -Be $false
      Test-Path -LiteralPath $result.desktop_bootstrap_paths.startup_path | Should -Be $true
      Test-Path -LiteralPath $result.desktop_notify_script_path | Should -Be $true
      Test-Path -LiteralPath $result.desktop_notify_config_path | Should -Be $true
      $script:UserEnv.ContainsKey('Path') | Should -Be $false
      $script:ProcessEnv.ContainsKey('Path') | Should -Be $false
      Should -Invoke Invoke-RaymanWorkspaceRegisterEnvironmentBroadcast -Times 0 -Exactly
    } finally {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $originalLocalAppData)
      [Environment]::SetEnvironmentVariable('APPDATA', $originalAppData)
      [Environment]::SetEnvironmentVariable('USERPROFILE', $originalUserProfile)
      [Environment]::SetEnvironmentVariable('HOME', $originalHome)
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'fails fast outside the RaymanAgent source workspace' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_register_fail_' + [Guid]::NewGuid().ToString('N'))
    $originalLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    $originalAppData = [Environment]::GetEnvironmentVariable('APPDATA')

    try {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', (Join-Path $tempRoot 'LocalAppData'))
      [Environment]::SetEnvironmentVariable('APPDATA', (Join-Path $tempRoot 'AppData'))
      New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot '.Rayman') | Out-Null
      Set-Content -LiteralPath (Join-Path $tempRoot '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
      Set-Content -LiteralPath (Join-Path $tempRoot '.Rayman\setup.ps1') -Encoding UTF8 -Value 'Write-Output ''setup'''
      Set-Content -LiteralPath (Join-Path $tempRoot '.Rayman\rayman.ps1') -Encoding UTF8 -Value 'Write-Output ''rayman'''

      $result = Invoke-RaymanWorkspaceRegister -WorkspaceRoot $tempRoot

      $result.success | Should -Be $false
      $result.status | Should -Be 'failed'
      if ($script:WorkspaceRegisterIsWindowsHost) {
        $result.error | Should -Match 'RaymanAgent source workspace'
      } else {
        $result.error | Should -Be 'workspace-register requires Windows.'
      }
    } finally {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $originalLocalAppData)
      [Environment]::SetEnvironmentVariable('APPDATA', $originalAppData)
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'writes a launcher that delegates to the registered workspace bootstrap helper' {
    if (-not $script:WorkspaceRegisterIsWindowsHost) {
      Set-ItResult -Skipped -Because 'workspace-register requires Windows.'
      return
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_launcher_' + [Guid]::NewGuid().ToString('N'))
    $localAppData = Join-Path $tempRoot 'LocalAppData'
    $sourceRoot = Join-Path $tempRoot 'RaymanAgent'
    $targetRoot = Join-Path $tempRoot 'ConsumerWorkspace'
    $capturePath = Join-Path $tempRoot 'captured_args.json'
    $originalLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')

    try {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $localAppData)
      Initialize-TestWorkspaceRegisterSource -Root $sourceRoot
      Set-Content -LiteralPath (Join-Path $sourceRoot '.Rayman\scripts\workspace\registered_workspace_bootstrap.ps1') -Encoding UTF8 -Value @"
param(
  [string]`$StatePath = '',
  [string]`$TargetPath = '',
  [string[]]`$CliArgs = @(),
  [switch]`$AutoOnOpen,
  [switch]`$Json
)
([ordered]@{
  state_path = `$StatePath
  target_path = `$TargetPath
  cli_args = @(`$CliArgs)
  auto_on_open = [bool]`$AutoOnOpen
  json = [bool]`$Json
} | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath '$capturePath' -Encoding UTF8
exit 0
"@
      $statePayload = [pscustomobject]@{
        schema = 'rayman.workspace_source.state.v1'
        source_workspace_path = [System.IO.Path]::GetFullPath($sourceRoot)
        rayman_version = 'v161'
        published_version = 'v161'
        published_fingerprint = 'published-fingerprint'
        registered_at = (Get-Date).ToString('o')
      }
      Write-RaymanWorkspaceRegisterJsonFile -Path (Get-RaymanWorkspaceRegisterSourceStatePath) -Value $statePayload
      $launcherInfo = Write-RaymanWorkspaceRegisterLaunchers
      New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null

      $pwsh = Resolve-RaymanPowerShellHost
      Push-Location $targetRoot
      try {
        & $pwsh -NoProfile -ExecutionPolicy Bypass -File $launcherInfo.ps1_path --json --no-self-check
        $LASTEXITCODE | Should -Be 0
      } finally {
        Pop-Location
      }

      $captured = Get-Content -LiteralPath $capturePath -Raw -Encoding UTF8 | ConvertFrom-Json
      [string]$captured.state_path | Should -Be ([System.IO.Path]::GetFullPath((Get-RaymanWorkspaceRegisterSourceStatePath)))
      [string]$captured.target_path | Should -Be ([System.IO.Path]::GetFullPath($targetRoot))
      [bool]$captured.json | Should -Be $true
      [bool]$captured.auto_on_open | Should -Be $false
      @($captured.cli_args) | Should -Be @('--no-self-check')
    } finally {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $originalLocalAppData)
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'registered workspace bootstrap' {
  It 'skips auto-on-open for workspaces without Rayman installed' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_registered_bootstrap_skip_' + [Guid]::NewGuid().ToString('N'))
    try {
      $statePath = Join-Path $tempRoot 'workspace_source.json'
      $targetRoot = Join-Path $tempRoot 'ConsumerWorkspace'
      New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null

      $version = Get-RaymanWorkspaceRegisterVersion -WorkspaceRoot $script:WorkspaceRoot
      Write-RaymanWorkspaceInstallJsonFile -Path $statePath -Value ([pscustomobject]@{
          schema = 'rayman.workspace_source.state.v1'
          source_workspace_path = $script:WorkspaceRoot
          rayman_version = $version
          published_version = $version
          published_fingerprint = 'published-fingerprint'
        })

      Mock Get-RaymanDistributableFingerprint { return 'published-fingerprint' } -ParameterFilter { $WorkspaceRoot -eq $script:WorkspaceRoot }
      Mock Invoke-RaymanWorkspaceInstall { throw 'workspace install should not run' }

      $result = Invoke-RaymanRegisteredWorkspaceBootstrap -StatePath $statePath -TargetPath $targetRoot -AutoOnOpen

      $result.success | Should -Be $true
      $result.status | Should -Be 'skipped_auto_without_rayman'
      Should -Invoke Invoke-RaymanWorkspaceInstall -Times 0 -Exactly
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'requires re-register when the published fingerprint is missing' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_registered_bootstrap_missing_fp_' + [Guid]::NewGuid().ToString('N'))
    try {
      $statePath = Join-Path $tempRoot 'workspace_source.json'
      $targetRoot = Join-Path $tempRoot 'ConsumerWorkspace'
      New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null

      $version = Get-RaymanWorkspaceRegisterVersion -WorkspaceRoot $script:WorkspaceRoot
      Write-RaymanWorkspaceInstallJsonFile -Path $statePath -Value ([pscustomobject]@{
          schema = 'rayman.workspace_source.state.v1'
          source_workspace_path = $script:WorkspaceRoot
          rayman_version = $version
        })

      $result = Invoke-RaymanRegisteredWorkspaceBootstrap -StatePath $statePath -TargetPath $targetRoot

      $result.success | Should -Be $false
      $result.error | Should -Match 'published fingerprint'
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'requires re-register when the registered source snapshot has drifted' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_registered_bootstrap_drift_' + [Guid]::NewGuid().ToString('N'))
    try {
      $statePath = Join-Path $tempRoot 'workspace_source.json'
      $targetRoot = Join-Path $tempRoot 'ConsumerWorkspace'
      New-Item -ItemType Directory -Force -Path (Join-Path $targetRoot '.Rayman') | Out-Null

      $version = Get-RaymanWorkspaceRegisterVersion -WorkspaceRoot $script:WorkspaceRoot
      Write-RaymanWorkspaceInstallJsonFile -Path $statePath -Value ([pscustomobject]@{
          schema = 'rayman.workspace_source.state.v1'
          source_workspace_path = $script:WorkspaceRoot
          rayman_version = $version
          published_version = $version
          published_fingerprint = 'expected-fingerprint'
        })

      Mock Get-RaymanDistributableFingerprint { return 'different-fingerprint' } -ParameterFilter { $WorkspaceRoot -eq $script:WorkspaceRoot }

      $result = Invoke-RaymanRegisteredWorkspaceBootstrap -StatePath $statePath -TargetPath $targetRoot

      $result.success | Should -Be $false
      $result.error | Should -Match 'workspace-register'
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'skips reinstall when the target already matches the published snapshot' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_registered_bootstrap_current_' + [Guid]::NewGuid().ToString('N'))
    try {
      $statePath = Join-Path $tempRoot 'workspace_source.json'
      $targetRoot = Join-Path $tempRoot 'ConsumerWorkspace'
      $version = Get-RaymanWorkspaceRegisterVersion -WorkspaceRoot $script:WorkspaceRoot
      New-Item -ItemType Directory -Force -Path (Join-Path $targetRoot '.Rayman\runtime\workspace_install') | Out-Null
      Set-Content -LiteralPath (Join-Path $targetRoot '.Rayman\VERSION') -Encoding UTF8 -Value ($version + "`n")

      Write-RaymanWorkspaceInstallJsonFile -Path (Join-Path $targetRoot '.Rayman\runtime\workspace_install\last.json') -Value ([pscustomobject]@{
          schema = 'rayman.workspace_install.result.v1'
          applied_published_version = $version
          applied_published_fingerprint = 'published-fingerprint'
        })
      Write-RaymanWorkspaceInstallJsonFile -Path $statePath -Value ([pscustomobject]@{
          schema = 'rayman.workspace_source.state.v1'
          source_workspace_path = $script:WorkspaceRoot
          rayman_version = $version
          published_version = $version
          published_fingerprint = 'published-fingerprint'
        })

      Mock Get-RaymanDistributableFingerprint { return 'published-fingerprint' } -ParameterFilter { $WorkspaceRoot -eq $script:WorkspaceRoot }
      Mock Invoke-RaymanWorkspaceInstall { throw 'workspace install should not run' }

      $result = Invoke-RaymanRegisteredWorkspaceBootstrap -StatePath $statePath -TargetPath $targetRoot

      $result.success | Should -Be $true
      $result.status | Should -Be 'already_current'
      Should -Invoke Invoke-RaymanWorkspaceInstall -Times 0 -Exactly
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'normalizes old installs without a stored fingerprint and refreshes folder-open bootstrap' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_registered_bootstrap_upgrade_' + [Guid]::NewGuid().ToString('N'))
    try {
      $statePath = Join-Path $tempRoot 'workspace_source.json'
      $targetRoot = Join-Path $tempRoot 'ConsumerWorkspace'
      $version = Get-RaymanWorkspaceRegisterVersion -WorkspaceRoot $script:WorkspaceRoot
      New-Item -ItemType Directory -Force -Path (Join-Path $targetRoot '.Rayman\runtime\workspace_install') | Out-Null
      Set-Content -LiteralPath (Join-Path $targetRoot '.Rayman\VERSION') -Encoding UTF8 -Value ($version + "`n")

      Write-RaymanWorkspaceInstallJsonFile -Path (Join-Path $targetRoot '.Rayman\runtime\workspace_install\last.json') -Value ([pscustomobject]@{
          schema = 'rayman.workspace_install.result.v1'
          applied_published_version = $version
          applied_published_fingerprint = ''
        })
      Write-RaymanWorkspaceInstallJsonFile -Path $statePath -Value ([pscustomobject]@{
          schema = 'rayman.workspace_source.state.v1'
          source_workspace_path = $script:WorkspaceRoot
          rayman_version = $version
          published_version = $version
          published_fingerprint = 'published-fingerprint'
        })

      Mock Get-RaymanDistributableFingerprint { return 'published-fingerprint' } -ParameterFilter { $WorkspaceRoot -eq $script:WorkspaceRoot }
      Mock Invoke-RaymanWorkspaceInstall {
        [pscustomobject]@{
          success = $true
          status = 'installed'
          applied_published_version = $version
          applied_published_fingerprint = 'published-fingerprint'
          target_path = $targetRoot
        }
      }
      Mock Invoke-RaymanRegisteredWorkspaceBootstrapRefresh {
        [pscustomobject]@{
          success = $true
          exit_code = 0
          error = ''
          stdout = @()
          stderr = @()
          output = ''
        }
      }

      $result = Invoke-RaymanRegisteredWorkspaceBootstrap -StatePath $statePath -TargetPath $targetRoot -AutoOnOpen

      $result.success | Should -Be $true
      $result.status | Should -Be 'installed'
      Should -Invoke Invoke-RaymanWorkspaceInstall -Times 1 -Exactly
      Should -Invoke Invoke-RaymanRegisteredWorkspaceBootstrapRefresh -Times 1 -Exactly
      (Test-Path -LiteralPath (Join-Path $targetRoot '.Rayman\state\workspace_install\auto_upgrade.lock.json')) | Should -Be $false
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
