BeforeAll {
  $script:WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  . (Join-Path $script:WorkspaceRoot '.Rayman\scripts\workspace\install_workspace.ps1') -NoMain

  function script:Initialize-TestWorkspaceInstallSource {
    param([string]$Root)

    foreach ($path in @(
        (Join-Path $Root '.Rayman'),
        (Join-Path $Root '.Rayman\.dist'),
        (Join-Path $Root '.Rayman\scripts\workspace'),
        (Join-Path $Root '.Rayman\state\memory'),
        (Join-Path $Root '.Rayman\runtime\old'),
        (Join-Path $Root '.Rayman\logs'),
        (Join-Path $Root '.Rayman\temp'),
        (Join-Path $Root '.Rayman\tmp')
      )) {
      New-Item -ItemType Directory -Force -Path $path | Out-Null
    }

    Set-Content -LiteralPath (Join-Path $Root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\setup.ps1') -Encoding UTF8 -Value 'Write-Output ''setup'''
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\rayman.ps1') -Encoding UTF8 -Value 'Write-Output ''rayman'''
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\.dist\keep.txt') -Encoding UTF8 -Value 'dist mirror'
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\scripts\workspace\marker.ps1') -Encoding UTF8 -Value 'Write-Output ''marker'''
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\state\memory\semantic.json') -Encoding UTF8 -Value '{}'
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\runtime\old\stale.txt') -Encoding UTF8 -Value 'stale runtime'
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\logs\stale.log') -Encoding UTF8 -Value 'stale log'
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\temp\scratch.txt') -Encoding UTF8 -Value 'temp'
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\tmp\scratch.txt') -Encoding UTF8 -Value 'tmp'
    Set-Content -LiteralPath (Join-Path $Root 'root-clutter.txt') -Encoding UTF8 -Value 'do not copy'
  }
}

Describe 'workspace install' {
  It 'copies only distributable .Rayman content to the target and records install state' {
    $sourceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_install_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-TestWorkspaceInstallSource -Root $sourceRoot
      $targetRoot = Join-Path $sourceRoot 'consumer-workspace'
      $expectedFingerprint = Get-RaymanDistributableFingerprint -WorkspaceRoot $sourceRoot

      Mock Invoke-RaymanWorkspaceInstallSetup {
        [pscustomobject]@{
          success = $true
          started = $true
          exit_code = 0
          command = 'setup'
          stdout = @('setup ok')
          stderr = @()
          output = 'setup ok'
          error = ''
          log_path = ''
        }
      }

      $result = Invoke-RaymanWorkspaceInstall -WorkspaceRoot $sourceRoot -TargetPath $targetRoot
      $defaults = Read-RaymanWorkspaceInstallJsonFile -Path (Get-RaymanWorkspaceInstallDefaultsPath -WorkspaceRoot $sourceRoot)
      $last = Read-RaymanWorkspaceInstallJsonFile -Path (Get-RaymanWorkspaceInstallLastPath -WorkspaceRoot $targetRoot)

      $result.success | Should -Be $true
      $result.status | Should -Be 'installed'
      $result.copied_items | Should -Be @('.Rayman')
      [int]$result.legacy_cleanup.removed_count | Should -Be 0
      Test-Path -LiteralPath (Join-Path $targetRoot '.Rayman\setup.ps1') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $targetRoot '.Rayman\.dist\keep.txt') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $targetRoot 'root-clutter.txt') | Should -Be $false
      Test-Path -LiteralPath (Join-Path $targetRoot '.Rayman\runtime\old\stale.txt') | Should -Be $false
      Test-Path -LiteralPath (Join-Path $targetRoot '.Rayman\logs\stale.log') | Should -Be $false
      Test-Path -LiteralPath (Join-Path $targetRoot '.Rayman\temp') | Should -Be $false
      Test-Path -LiteralPath (Join-Path $targetRoot '.Rayman\tmp') | Should -Be $false
      Test-Path -LiteralPath (Get-RaymanWorkspaceInstallLastPath -WorkspaceRoot $targetRoot) | Should -Be $true
      $defaults.target_path | Should -Be $result.target_path
      $last.target_path | Should -Be $result.target_path
      $last.status | Should -Be 'installed'
      $result.applied_published_version | Should -Be 'v161'
      $result.applied_published_fingerprint | Should -Be $expectedFingerprint
      $last.applied_published_version | Should -Be 'v161'
      $last.applied_published_fingerprint | Should -Be $expectedFingerprint
      [int]$last.legacy_cleanup.removed_count | Should -Be 0
    } finally {
      Remove-Item -LiteralPath $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'cleans known legacy Rayman sibling residue during install and records the cleanup result' {
    $sourceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_install_cleanup_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-TestWorkspaceInstallSource -Root $sourceRoot
      $targetRoot = Join-Path $sourceRoot 'consumer-workspace'
      foreach ($path in @(
          (Join-Path $targetRoot '.Rayman.__rayman_workspace_install_old_deadbeef'),
          (Join-Path $targetRoot '.Rayman.bak'),
          (Join-Path $targetRoot '.Rayman.stage.20260329010101-deadbeef'),
          (Join-Path $targetRoot 'business.keep')
        )) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
      }

      Mock Invoke-RaymanWorkspaceInstallSetup {
        [pscustomobject]@{
          success = $true
          started = $true
          exit_code = 0
          command = 'setup'
          stdout = @()
          stderr = @()
          output = ''
          error = ''
          log_path = ''
        }
      }

      $result = Invoke-RaymanWorkspaceInstall -WorkspaceRoot $sourceRoot -TargetPath $targetRoot -NoSelfCheck
      $last = Read-RaymanWorkspaceInstallJsonFile -Path (Get-RaymanWorkspaceInstallLastPath -WorkspaceRoot $targetRoot)

      $result.success | Should -Be $true
      [int]$result.legacy_cleanup.removed_count | Should -Be 3
      [int]$result.legacy_cleanup.failed_count | Should -Be 0
      (Test-Path -LiteralPath (Join-Path $targetRoot '.Rayman.__rayman_workspace_install_old_deadbeef')) | Should -Be $false
      (Test-Path -LiteralPath (Join-Path $targetRoot '.Rayman.bak')) | Should -Be $false
      (Test-Path -LiteralPath (Join-Path $targetRoot '.Rayman.stage.20260329010101-deadbeef')) | Should -Be $false
      (Test-Path -LiteralPath (Join-Path $targetRoot 'business.keep')) | Should -Be $true
      [int]$last.legacy_cleanup.removed_count | Should -Be 3
      [int]$last.legacy_cleanup.failed_count | Should -Be 0
    } finally {
      Remove-Item -LiteralPath $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'records a warning when legacy residue cleanup cannot remove every known sibling' {
    $sourceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_install_cleanup_warn_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-TestWorkspaceInstallSource -Root $sourceRoot
      $targetRoot = Join-Path $sourceRoot 'consumer-workspace'
      $blockedPath = Join-Path $targetRoot '.Rayman.bak'
      New-Item -ItemType Directory -Force -Path $blockedPath | Out-Null

      Mock Remove-Item {
        if ([string]$LiteralPath -eq $blockedPath) {
          throw 'locked'
        }
        Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
      } -ParameterFilter { $LiteralPath -eq $blockedPath }

      Mock Invoke-RaymanWorkspaceInstallSetup {
        [pscustomobject]@{
          success = $true
          started = $true
          exit_code = 0
          command = 'setup'
          stdout = @()
          stderr = @()
          output = ''
          error = ''
          log_path = ''
        }
      }

      $result = Invoke-RaymanWorkspaceInstall -WorkspaceRoot $sourceRoot -TargetPath $targetRoot -NoSelfCheck

      $result.success | Should -Be $true
      [int]$result.legacy_cleanup.removed_count | Should -Be 0
      [int]$result.legacy_cleanup.failed_count | Should -Be 1
      [string]$result.warning | Should -Match 'legacy Rayman residue cleanup incomplete'
      (Test-Path -LiteralPath $blockedPath) | Should -Be $true
    } finally {
      Microsoft.PowerShell.Management\Remove-Item -LiteralPath $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'reuses the remembered workspace target when interactive input is blank' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_install_prompt_' + [Guid]::NewGuid().ToString('N'))
    try {
      $rememberedTarget = Join-Path $root 'remembered-target'
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\state\workspace_install') | Out-Null
      Write-RaymanWorkspaceInstallJsonFile -Path (Get-RaymanWorkspaceInstallDefaultsPath -WorkspaceRoot $root) -Value ([pscustomobject]@{
          schema = 'rayman.workspace_install.defaults.v1'
          target_path = $rememberedTarget
          last_install_at = (Get-Date).ToString('o')
        })

      Mock Test-RaymanWorkspaceInstallInteractiveConsoleAvailable { return $true }
      function global:Read-Host {
        param([string]$Prompt)
        return ''
      }

      $resolved = Resolve-RaymanWorkspaceInstallTargetPath -WorkspaceRoot $root
      $resolved | Should -Be ([System.IO.Path]::GetFullPath($rememberedTarget))
    } finally {
      Remove-Item function:\global:Read-Host -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'does not overwrite the remembered target when no-remember is used' {
    $sourceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_install_noremember_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-TestWorkspaceInstallSource -Root $sourceRoot
      $rememberedTarget = [System.IO.Path]::GetFullPath((Join-Path $sourceRoot 'remembered-target'))
      Write-RaymanWorkspaceInstallJsonFile -Path (Get-RaymanWorkspaceInstallDefaultsPath -WorkspaceRoot $sourceRoot) -Value ([pscustomobject]@{
          schema = 'rayman.workspace_install.defaults.v1'
          target_path = $rememberedTarget
          last_install_at = '2026-03-28T00:00:00.0000000+08:00'
        })

      Mock Invoke-RaymanWorkspaceInstallSetup {
        [pscustomobject]@{
          success = $true
          started = $true
          exit_code = 0
          command = 'setup'
          stdout = @()
          stderr = @()
          output = ''
          error = ''
          log_path = ''
        }
      }

      $newTarget = Join-Path $sourceRoot 'new-target'
      $result = Invoke-RaymanWorkspaceInstall -WorkspaceRoot $sourceRoot -TargetPath $newTarget -NoRemember
      $defaults = Read-RaymanWorkspaceInstallJsonFile -Path (Get-RaymanWorkspaceInstallDefaultsPath -WorkspaceRoot $sourceRoot)

      $result.success | Should -Be $true
      $result.remembered_target | Should -Be $false
      $defaults.target_path | Should -Be $rememberedTarget
    } finally {
      Remove-Item -LiteralPath $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'runs copy-self-check by default after setup succeeds' {
    $sourceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_install_selfcheck_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-TestWorkspaceInstallSource -Root $sourceRoot
      $targetRoot = Join-Path $sourceRoot 'consumer-workspace'

      Mock Invoke-RaymanWorkspaceInstallSetup {
        [pscustomobject]@{
          success = $true
          started = $true
          exit_code = 0
          command = 'setup'
          stdout = @()
          stderr = @()
          output = ''
          error = ''
          log_path = ''
        }
      }
      Mock Invoke-RaymanWorkspaceInstallSelfCheck {
        [pscustomobject]@{
          success = $true
          started = $true
          exit_code = 0
          command = 'copy-self-check'
          stdout = @('copy ok')
          stderr = @()
          output = 'copy ok'
          error = ''
        }
      }

      $result = Invoke-RaymanWorkspaceInstall -WorkspaceRoot $sourceRoot -TargetPath $targetRoot

      $result.success | Should -Be $true
      $result.self_check_requested | Should -Be $true
      $null -ne $result.self_check | Should -Be $true
      Should -Invoke Invoke-RaymanWorkspaceInstallSelfCheck -Times 1 -Exactly
    } finally {
      Remove-Item -LiteralPath $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'keeps previous .Rayman backup outside the target workspace while setup runs' {
    $sourceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_install_external_backup_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-TestWorkspaceInstallSource -Root $sourceRoot
      $targetRoot = Join-Path $sourceRoot 'consumer-workspace'
      New-Item -ItemType Directory -Force -Path (Join-Path $targetRoot '.Rayman') | Out-Null
      Set-Content -LiteralPath (Join-Path $targetRoot '.Rayman\old.txt') -Encoding UTF8 -Value 'old'

      $script:backupVisibleDuringSetup = $true
      Mock Invoke-RaymanWorkspaceInstallSetup {
        $script:backupVisibleDuringSetup = @(
          Get-ChildItem -LiteralPath $targetRoot -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.PSIsContainer -and $_.Name -like '.Rayman.__rayman_workspace_install_old_*' }
        ).Count -gt 0

        [pscustomobject]@{
          success = $true
          started = $true
          exit_code = 0
          command = 'setup'
          stdout = @()
          stderr = @()
          output = ''
          error = ''
          log_path = ''
        }
      }
      Mock Invoke-RaymanWorkspaceInstallSelfCheck {
        [pscustomobject]@{
          success = $true
          started = $true
          exit_code = 0
          command = 'copy-self-check'
          stdout = @()
          stderr = @()
          output = ''
          error = ''
        }
      }

      $result = Invoke-RaymanWorkspaceInstall -WorkspaceRoot $sourceRoot -TargetPath $targetRoot

      $result.success | Should -Be $true
      $script:backupVisibleDuringSetup | Should -Be $false
    } finally {
      Remove-Variable -Name backupVisibleDuringSetup -Scope Script -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'prunes volatile runtime and log paths from the previous target .Rayman before backup move' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_install_prune_' + [Guid]::NewGuid().ToString('N'))
    try {
      $targetRaymanPath = Join-Path $root '.Rayman'
      foreach ($path in @(
          (Join-Path $targetRaymanPath 'runtime\stale'),
          (Join-Path $targetRaymanPath 'logs'),
          (Join-Path $targetRaymanPath 'temp'),
          (Join-Path $targetRaymanPath 'tmp')
        )) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
      }
      Set-Content -LiteralPath (Join-Path $targetRaymanPath 'keep.txt') -Encoding UTF8 -Value 'keep'
      Set-Content -LiteralPath (Join-Path $targetRaymanPath 'runtime\stale\old.txt') -Encoding UTF8 -Value 'old'

      Prune-RaymanWorkspaceInstallVolatileTargetPaths -TargetRaymanPath $targetRaymanPath

      (Test-Path -LiteralPath (Join-Path $targetRaymanPath 'runtime')) | Should -Be $false
      (Test-Path -LiteralPath (Join-Path $targetRaymanPath 'logs')) | Should -Be $false
      (Test-Path -LiteralPath (Join-Path $targetRaymanPath 'temp')) | Should -Be $false
      (Test-Path -LiteralPath (Join-Path $targetRaymanPath 'tmp')) | Should -Be $false
      (Test-Path -LiteralPath (Join-Path $targetRaymanPath 'keep.txt')) | Should -Be $true
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'invokes setup with SkipReleaseGate during workspace install bootstrap' {
    $sourceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_install_setup_args_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-TestWorkspaceInstallSource -Root $sourceRoot
      $targetRoot = Join-Path $sourceRoot 'consumer-workspace'
      New-Item -ItemType Directory -Force -Path (Join-Path $targetRoot '.Rayman') | Out-Null
      Set-Content -LiteralPath (Join-Path $targetRoot '.Rayman\setup.ps1') -Encoding UTF8 -Value 'Write-Output ''setup'''

      Mock Resolve-RaymanPowerShellHost { return 'powershell.exe' }
      Mock Invoke-RaymanNativeCommandCapture {
        param(
          [string]$FilePath,
          [string[]]$ArgumentList,
          [string]$WorkingDirectory
        )
        [pscustomobject]@{
          success = $true
          started = $true
          exit_code = 0
          command = ($ArgumentList -join ' ')
          file_path = $FilePath
          working_directory = $WorkingDirectory
          argument_list = @($ArgumentList)
          skip_scm_checks = [Environment]::GetEnvironmentVariable('RAYMAN_SETUP_SKIP_SCM_CHECKS')
          github_login = [Environment]::GetEnvironmentVariable('RAYMAN_SETUP_GITHUB_LOGIN')
          stdout = @()
          stderr = @()
          output = ''
          error = ''
        }
      }

      $capture = Invoke-RaymanWorkspaceInstallSetup -TargetRoot $targetRoot

      [string]$capture.file_path | Should -Be 'powershell.exe'
      @($capture.argument_list) | Should -Contain '-SkipReleaseGate'
      @($capture.argument_list) | Should -Contain '-WorkspaceRoot'
      [string]$capture.skip_scm_checks | Should -Be '1'
      [string]$capture.github_login | Should -Be '0'
    } finally {
      Remove-Item -LiteralPath $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'skips copy-self-check when no-self-check is used' {
    $sourceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_install_no_selfcheck_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-TestWorkspaceInstallSource -Root $sourceRoot
      $targetRoot = Join-Path $sourceRoot 'consumer-workspace'

      Mock Invoke-RaymanWorkspaceInstallSetup {
        [pscustomobject]@{
          success = $true
          started = $true
          exit_code = 0
          command = 'setup'
          stdout = @()
          stderr = @()
          output = ''
          error = ''
          log_path = ''
        }
      }
      Mock Invoke-RaymanWorkspaceInstallSelfCheck {
        throw 'copy-self-check should not run'
      }

      $result = Invoke-RaymanWorkspaceInstall -WorkspaceRoot $sourceRoot -TargetPath $targetRoot -NoSelfCheck

      $result.success | Should -Be $true
      $result.self_check_requested | Should -Be $false
      $null -eq $result.self_check | Should -Be $true
      Should -Invoke Invoke-RaymanWorkspaceInstallSelfCheck -Times 0 -Exactly
    } finally {
      Remove-Item -LiteralPath $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'records setup failures without rolling back the copied .Rayman' {
    $sourceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_install_setup_fail_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-TestWorkspaceInstallSource -Root $sourceRoot
      $targetRoot = Join-Path $sourceRoot 'consumer-workspace'

      Mock Invoke-RaymanWorkspaceInstallSetup {
        [pscustomobject]@{
          success = $false
          started = $true
          exit_code = 7
          command = 'setup'
          stdout = @()
          stderr = @('setup failed')
          output = 'setup failed'
          error = ''
          log_path = 'E:\logs\setup.log'
        }
      }

      $result = Invoke-RaymanWorkspaceInstall -WorkspaceRoot $sourceRoot -TargetPath $targetRoot
      $last = Read-RaymanWorkspaceInstallJsonFile -Path (Get-RaymanWorkspaceInstallLastPath -WorkspaceRoot $targetRoot)

      $result.success | Should -Be $false
      $result.status | Should -Be 'setup_failed'
      $result.error | Should -Match 'log=E:\\logs\\setup\.log'
      Test-Path -LiteralPath (Join-Path $targetRoot '.Rayman\setup.ps1') | Should -Be $true
      $last.status | Should -Be 'setup_failed'
    } finally {
      Remove-Item -LiteralPath $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'restores the previous .Rayman when replacement fails mid-copy' {
    $sourceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_install_restore_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-TestWorkspaceInstallSource -Root $sourceRoot
      $targetRoot = Join-Path $sourceRoot 'consumer-workspace'
      New-Item -ItemType Directory -Force -Path (Join-Path $targetRoot '.Rayman') | Out-Null
      Set-Content -LiteralPath (Join-Path $targetRoot '.Rayman\old.txt') -Encoding UTF8 -Value 'old'

      Mock Copy-Item {
        throw 'simulated move failure'
      } -ParameterFilter { ([string]$Destination -Match 'consumer-workspace' -or [string]$Path -Match 'consumer-workspace') -and ([string]$LiteralPath -Match 'setup\.ps1' -or [string]$Path -Match 'setup\.ps1') }

      $result = Invoke-RaymanWorkspaceInstall -WorkspaceRoot $sourceRoot -TargetPath $targetRoot

      $result.success | Should -Be $false
      $result.status | Should -Be 'copy_failed'
      Test-Path -LiteralPath (Join-Path $targetRoot '.Rayman\old.txt') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $targetRoot '.Rayman\setup.ps1') | Should -Be $false
    } finally {
      Remove-Item -LiteralPath $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
