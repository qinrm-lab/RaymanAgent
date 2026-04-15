BeforeAll {
  . (Join-Path $PSScriptRoot '..\..\utils\workspace_process_ownership.ps1') -NoMain
  . (Join-Path $PSScriptRoot '..\..\repair\run_tests_and_fix.ps1') -NoMain
}

Describe 'workspace_process_ownership owner resolution' {
  It 'prefers the existing VS Code owner token when VSCODE_PID is unavailable' {
    $envNames = @('RAYMAN_VSCODE_WINDOW_OWNER', 'VSCODE_IPC_HOOK_CLI', 'VSCODE_IPC_HOOK', 'VSCODE_PID')
    $previous = @{}
    foreach ($name in $envNames) {
      $previous[$name] = [Environment]::GetEnvironmentVariable($name)
    }

    try {
      [Environment]::SetEnvironmentVariable('VSCODE_PID', $null)
      [Environment]::SetEnvironmentVariable('VSCODE_IPC_HOOK', $null)
      [Environment]::SetEnvironmentVariable('VSCODE_IPC_HOOK_CLI', $null)
      [Environment]::SetEnvironmentVariable('RAYMAN_VSCODE_WINDOW_OWNER', 'owner-xyz')

      $ctx = Get-RaymanWorkspaceProcessOwnerContext -WorkspaceRootPath (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path -ExplicitOwnerPid '424242'

      $ctx.owner_source | Should -Be 'RAYMAN_VSCODE_WINDOW_OWNER'
      $ctx.owner_token | Should -Be 'owner-xyz'
    } finally {
      foreach ($name in $envNames) {
        [Environment]::SetEnvironmentVariable($name, $previous[$name])
      }
    }
  }

  It 'falls back to a single vscode session owner pid when env owner tokens are unavailable' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_owned_session_' + [Guid]::NewGuid().ToString('N'))
    $envNames = @('RAYMAN_VSCODE_WINDOW_OWNER', 'VSCODE_IPC_HOOK_CLI', 'VSCODE_IPC_HOOK', 'VSCODE_PID')
    $previous = @{}
    foreach ($name in $envNames) {
      $previous[$name] = [Environment]::GetEnvironmentVariable($name)
    }

    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime\vscode_sessions') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\runtime\vscode_sessions\424242.json') -Encoding UTF8 -Value (@{
        parentPid = 424242
        state = 'watching'
      } | ConvertTo-Json -Depth 4)

      foreach ($name in $envNames) {
        [Environment]::SetEnvironmentVariable($name, $null)
      }

      $ctx = Get-RaymanWorkspaceProcessOwnerContext -WorkspaceRootPath $root

      $ctx.owner_source | Should -Be 'VSCODE_PID'
      $ctx.owner_token | Should -Be '424242'
    } finally {
      foreach ($name in $envNames) {
        [Environment]::SetEnvironmentVariable($name, $previous[$name])
      }
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'prefers an explicit owner pid over a session-derived owner pid when both are available' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_owned_explicit_' + [Guid]::NewGuid().ToString('N'))
    $envNames = @('RAYMAN_VSCODE_WINDOW_OWNER', 'VSCODE_IPC_HOOK_CLI', 'VSCODE_IPC_HOOK', 'VSCODE_PID')
    $previous = @{}
    foreach ($name in $envNames) {
      $previous[$name] = [Environment]::GetEnvironmentVariable($name)
    }

    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime\vscode_sessions') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\runtime\vscode_sessions\424242.json') -Encoding UTF8 -Value (@{
        parentPid = 424242
        state = 'watching'
      } | ConvertTo-Json -Depth 4)

      foreach ($name in $envNames) {
        [Environment]::SetEnvironmentVariable($name, $null)
      }

      $ctx = Get-RaymanWorkspaceProcessOwnerContext -WorkspaceRootPath $root -ExplicitOwnerPid '515151'

      $ctx.owner_source | Should -Be 'VSCODE_PID'
      $ctx.owner_token | Should -Be '515151'
    } finally {
      foreach ($name in $envNames) {
        [Environment]::SetEnvironmentVariable($name, $previous[$name])
      }
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'builds a stable shared owner context for workspace-level watchers' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_owned_shared_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null

      $ctxA = Get-RaymanWorkspaceSharedProcessOwnerContext -WorkspaceRootPath $root
      $ctxB = Get-RaymanWorkspaceSharedProcessOwnerContext -WorkspaceRootPath $root

      $ctxA.owner_source | Should -Be 'workspace-shared'
      $ctxA.owner_key | Should -Be $ctxB.owner_key
      $ctxA.owner_display | Should -Match '^workspace-shared#'
      $ctxA.owner_key | Should -Not -Be (Get-RaymanWorkspaceProcessOwnerContext -WorkspaceRootPath $root).owner_key
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'workspace_process_ownership registry helpers' {
  It 'prunes dead records while keeping live records in the same workspace' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_owned_registry_' + [Guid]::NewGuid().ToString('N'))
    $rootPid = 0
    $taskKill = Resolve-RaymanOwnedTaskKillPath
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime') | Out-Null
      $registryPath = Get-RaymanOwnedProcessRegistryPath -WorkspaceRootPath $root
      $pidFile = Join-Path $root '.Rayman\runtime\registry_live_root.pid'
      $pidFileWindows = Convert-RaymanOwnedPathToWindows -PathValue $pidFile
      $psWindows = Resolve-RaymanOwnedWindowsPowerShellPath
      if ([string]::IsNullOrWhiteSpace($psWindows) -or [string]::IsNullOrWhiteSpace($pidFileWindows)) {
        return
      }

      $scriptBody = @'
Set-Content -LiteralPath '__PIDFILE__' -Value $PID -Encoding ASCII
Start-Sleep -Seconds 60
'@
      $scriptBody = $scriptBody.Replace('__PIDFILE__', (Convert-RaymanOwnedPsSingleQuotedLiteral -Value $pidFileWindows))
      $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($scriptBody))
      $launcher = Start-Process -FilePath $psWindows -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -PassThru

      $deadline = (Get-Date).AddSeconds(10)
      while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
        Start-Sleep -Milliseconds 200
      }
      (Test-Path -LiteralPath $pidFile -PathType Leaf) | Should -Be $true

      $rootPid = [int]((Get-Content -LiteralPath $pidFile -Raw -Encoding ASCII).Trim())
      $liveDetails = Get-RaymanOwnedWindowsProcessDetails -WorkspaceRootPath $root -ProcessId $rootPid
      @(
        [pscustomobject]@{
          workspace_root = $root
          owner_key = 'owner-a'
          owner_display = 'owner-a'
          kind = 'dotnet'
          launcher = 'windows-bridge'
          root_pid = 101
          started_at = '2026-03-14T00:00:00Z'
          command = 'dotnet test'
          state = 'running'
        }
        [pscustomobject]@{
          workspace_root = $root
          owner_key = 'owner-a'
          owner_display = 'owner-a'
          kind = 'dotnet'
          launcher = 'windows-native'
          root_pid = $rootPid
          started_at = [string]$liveDetails.start_utc
          command = 'dotnet build'
          state = 'running'
        }
      ) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $registryPath -Encoding UTF8

      $records = @(Get-RaymanWorkspaceOwnedProcessRecords -WorkspaceRootPath $root)
      $saved = @(Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)

      $records.Count | Should -Be 1
      [int]$records[0].root_pid | Should -Be $rootPid
      $saved.Count | Should -Be 1
      [int]$saved[0].root_pid | Should -Be $rootPid

      try { Stop-Process -Id $launcher.Id -Force -ErrorAction SilentlyContinue } catch {}
    } finally {
      if ($rootPid -gt 0 -and -not [string]::IsNullOrWhiteSpace($taskKill)) {
        try { & $taskKill /PID $rootPid /T /F 2>$null | Out-Null } catch {}
      }
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'stops only records that match the current owner and requested kind' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_owned_owner_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $owner = [pscustomobject]@{
        owner_key = 'owner-a'
        owner_display = 'owner-a'
      }
      $records = @(
        [pscustomobject]@{
          workspace_root = $root
          owner_key = 'owner-a'
          owner_display = 'owner-a'
          kind = 'dotnet'
          launcher = 'windows-bridge'
          root_pid = 301
          started_at = '2026-03-14T00:00:00Z'
          command = 'dotnet test'
          state = 'running'
        }
        [pscustomobject]@{
          workspace_root = $root
          owner_key = 'owner-b'
          owner_display = 'owner-b'
          kind = 'dotnet'
          launcher = 'windows-native'
          root_pid = 302
          started_at = '2026-03-14T00:00:01Z'
          command = 'dotnet build'
          state = 'running'
        }
        [pscustomobject]@{
          workspace_root = $root
          owner_key = 'owner-a'
          owner_display = 'owner-a'
          kind = 'node'
          launcher = 'pwsh'
          root_pid = 303
          started_at = '2026-03-14T00:00:02Z'
          command = 'npm test'
          state = 'running'
        }
      )

      Mock Get-RaymanWorkspaceOwnedProcessRecords { return $records }
      Mock Stop-RaymanWorkspaceOwnedProcess {
        param([string]$WorkspaceRootPath, [object]$Record, [string]$Reason)
        return [pscustomobject]@{
          root_pid = [int]$Record.root_pid
          cleanup_reason = $Reason
        }
      }

      $results = @(Stop-RaymanWorkspaceOwnedProcessesForCurrentOwner -WorkspaceRootPath $root -OwnerContext $owner -Kinds @('dotnet') -Reason 'watch-stop')

      $results.Count | Should -Be 1
      [int]$results[0].root_pid | Should -Be 301
      $results[0].cleanup_reason | Should -Be 'watch-stop'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'workspace_process_ownership vscode window audit' {
  It 'registers only new Code windows that match the tracked workspace' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_owned_vscode_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime') | Out-Null
      $baseline = @(
        [pscustomobject]@{
          pid = 101
          start_utc = '2026-03-19T00:00:00Z'
          process_name = 'Code'
          command_line = 'Code.exe "E:\foreign"'
          main_window_title = 'foreign'
        }
      )
      $current = @(
        $baseline[0]
        [pscustomobject]@{
          pid = 202
          start_utc = '2026-03-19T00:01:00Z'
          process_name = 'Code'
          command_line = ('Code.exe "{0}"' -f $root)
          main_window_title = 'rayman-owned'
        }
        [pscustomobject]@{
          pid = 303
          start_utc = '2026-03-19T00:02:00Z'
          process_name = 'Code'
          command_line = 'Code.exe "E:\other-workspace"'
          main_window_title = 'other'
        }
      )
      $owner = [pscustomobject]@{
        owner_key = 'owner-a'
        owner_display = 'owner-a'
        owner_source = 'VSCODE_PID'
        owner_token = '424242'
      }

      Mock Get-RaymanVsCodeProcessSnapshot { return $current }
      Mock Register-RaymanWorkspaceOwnedProcess {
        param([string]$WorkspaceRootPath, [object]$OwnerContext, [string]$Kind, [string]$Launcher, [int]$RootPid, [string]$Command)
        return [pscustomobject]@{
          workspace_root = $WorkspaceRootPath
          owner_key = [string]$OwnerContext.owner_key
          owner_display = [string]$OwnerContext.owner_display
          kind = $Kind
          launcher = $Launcher
          root_pid = $RootPid
          command = $Command
        }
      }

      $report = Sync-RaymanWorkspaceVsCodeWindows -WorkspaceRootPath $root -BaselineSnapshot $baseline -WorkspaceRoots @($root) -OwnerContext $owner -Source 'setup'

      (@($report.new_pids) -join ',') | Should -Be '202,303'
      (@($report.owned_pids) -join ',') | Should -Be '202'
      [int]$report.owner_pid | Should -Be 424242
      (@($report.workspace_match | Where-Object { [int]$_.pid -eq 202 } | Select-Object -First 1).matched) | Should -Be $true
      (@($report.workspace_match | Where-Object { [int]$_.pid -eq 303 } | Select-Object -First 1).matched) | Should -Be $false
      Assert-MockCalled Register-RaymanWorkspaceOwnedProcess -Times 1 -Exactly -Scope It -ParameterFilter {
        $Kind -eq 'vscode' -and $RootPid -eq 202 -and $Launcher -eq 'setup-vscode-window'
      }
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'cleans only newly owned Code windows when requested' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_owned_vscode_cleanup_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime') | Out-Null
      $baseline = @()
      $current = @(
        [pscustomobject]@{
          pid = 202
          start_utc = '2026-03-19T00:01:00Z'
          process_name = 'Code'
          command_line = ('Code.exe "{0}"' -f $root)
          main_window_title = 'rayman-owned'
        }
        [pscustomobject]@{
          pid = 303
          start_utc = '2026-03-19T00:02:00Z'
          process_name = 'Code'
          command_line = 'Code.exe "E:\other-workspace"'
          main_window_title = 'other'
        }
      )
      $owner = [pscustomobject]@{
        owner_key = 'owner-a'
        owner_display = 'owner-a'
        owner_source = 'VSCODE_PID'
        owner_token = '424242'
      }

      Mock Get-RaymanVsCodeProcessSnapshot { return $current }
      Mock Register-RaymanWorkspaceOwnedProcess {
        param([string]$WorkspaceRootPath, [object]$OwnerContext, [string]$Kind, [string]$Launcher, [int]$RootPid, [string]$Command)
        return [pscustomobject]@{
          workspace_root = $WorkspaceRootPath
          owner_key = [string]$OwnerContext.owner_key
          owner_display = [string]$OwnerContext.owner_display
          kind = $Kind
          launcher = $Launcher
          root_pid = $RootPid
          command = $Command
        }
      }
      Mock Stop-RaymanWorkspaceOwnedProcess {
        param([string]$WorkspaceRootPath, [object]$Record, [string]$Reason)
        return [pscustomobject]@{
          root_pid = [int]$Record.root_pid
          cleanup_reason = $Reason
          cleanup_result = 'cleaned'
          cleanup_pids = @([int]$Record.root_pid)
        }
      }

      $report = Sync-RaymanWorkspaceVsCodeWindows -WorkspaceRootPath $root -BaselineSnapshot $baseline -WorkspaceRoots @($root) -OwnerContext $owner -CleanupOwned -CleanupReason 'setup-failed' -Source 'setup'

      $report.cleanup_result | Should -Be 'cleaned'
      (@($report.cleanup_pids) -join ',') | Should -Be '202'
      Assert-MockCalled Stop-RaymanWorkspaceOwnedProcess -Times 1 -Exactly -Scope It -ParameterFilter {
        [int]$Record.root_pid -eq 202 -and $Reason -eq 'setup-failed'
      }
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'registers tracked workspace audit roots and skips child clientProcessId leaves' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_owned_vscode_audit_' + [Guid]::NewGuid().ToString('N'))
    $copyRoot = Join-Path $root 'copy-smoke'
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $copyRoot '.Rayman\runtime') | Out-Null
      Set-Content -LiteralPath (Join-Path $copyRoot '.Rayman\runtime\vscode_windows.last.json') -Encoding UTF8 -Value (@{
        schema = 'rayman.vscode_windows.v1'
        workspace_root = $copyRoot
        new_pids = @(202, 203)
      } | ConvertTo-Json -Depth 4)

      $baseline = @()
      $current = @(
        [pscustomobject]@{
          pid = 202
          parent_pid = 424242
          start_utc = '2026-03-19T00:01:00Z'
          process_name = 'Code'
          command_line = 'Code.exe --type=utility'
          main_window_title = ''
        }
        [pscustomobject]@{
          pid = 203
          parent_pid = 202
          start_utc = '2026-03-19T00:01:02Z'
          process_name = 'Code'
          command_line = 'Code.exe server.js --clientProcessId=202'
          main_window_title = ''
        }
        [pscustomobject]@{
          pid = 303
          parent_pid = 999
          start_utc = '2026-03-19T00:01:03Z'
          process_name = 'Code'
          command_line = 'Code.exe --type=utility'
          main_window_title = ''
        }
      )
      $owner = [pscustomobject]@{
        owner_key = 'owner-a'
        owner_display = 'owner-a'
        owner_source = 'VSCODE_PID'
        owner_token = '424242'
      }

      Mock Get-RaymanVsCodeProcessSnapshot { return $current }
      Mock Register-RaymanWorkspaceOwnedProcess {
        param([string]$WorkspaceRootPath, [object]$OwnerContext, [string]$Kind, [string]$Launcher, [int]$RootPid, [string]$Command)
        return [pscustomobject]@{
          workspace_root = $WorkspaceRootPath
          owner_key = [string]$OwnerContext.owner_key
          owner_display = [string]$OwnerContext.owner_display
          kind = $Kind
          launcher = $Launcher
          root_pid = $RootPid
          command = $Command
        }
      }

      $report = Sync-RaymanWorkspaceVsCodeWindows -WorkspaceRootPath $root -BaselineSnapshot $baseline -WorkspaceRoots @($copyRoot) -OwnerContext $owner -Source 'copy-smoke'

      (@($report.owned_pids) -join ',') | Should -Be '202'
      ((@($report.workspace_match | Where-Object { [int]$_.pid -eq 202 })[0]).reason) | Should -Be 'tracked_workspace_audit'
      ((@($report.workspace_match | Where-Object { [int]$_.pid -eq 203 })[0]).reason) | Should -Be 'tracked_workspace_audit'
      Assert-MockCalled Register-RaymanWorkspaceOwnedProcess -Times 1 -Exactly -Scope It -ParameterFilter {
        $Kind -eq 'vscode' -and $RootPid -eq 202 -and $Launcher -eq 'copy-smoke-vscode-window'
      }
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'workspace_process_ownership project gate helpers' {
  It 'matches workspace-owned processes by command line or executable path' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_owned_match_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin') | Out-Null

      $commandLineMatch = Resolve-RaymanWorkspaceOwnedProcessMatch -ProcessInfo ([pscustomobject]@{
          pid = 101
          command_line = ('powershell.exe -File "{0}\child.ps1"' -f $root)
          executable_path = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        }) -WorkspaceRoots @($root)
      $executablePathMatch = Resolve-RaymanWorkspaceOwnedProcessMatch -ProcessInfo ([pscustomobject]@{
          pid = 102
          command_line = 'RaymanWeb.Server.exe --http-port 5085 --auto-ports'
          executable_path = (Join-Path $root 'bin\RaymanWeb.Server.exe')
        }) -WorkspaceRoots @($root)

      [bool]$commandLineMatch.matched | Should -Be $true
      [string]$commandLineMatch.reason | Should -Be 'command_line'
      [bool]$executablePathMatch.matched | Should -Be $true
      [string]$executablePathMatch.reason | Should -Be 'executable_path'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'registers only new matched roots from a baseline snapshot' {
    if (-not (Test-RaymanWindowsPlatform)) {
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_owned_baseline_cleanup_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $baseline = @(
        [pscustomobject]@{
          pid = 101
          start_utc = '2026-04-08T00:00:00Z'
          parent_pid = 0
          process_name = 'powershell'
          command_line = ('powershell.exe -File "{0}\child.ps1"' -f $root)
          executable_path = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        }
      )
      $current = @(
        $baseline[0]
        [pscustomobject]@{
          pid = 202
          start_utc = '2026-04-08T00:01:00Z'
          parent_pid = 0
          process_name = 'powershell'
          command_line = ('powershell.exe -File "{0}\spawn.ps1"' -f $root)
          executable_path = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        }
        [pscustomobject]@{
          pid = 203
          start_utc = '2026-04-08T00:01:01Z'
          parent_pid = 202
          process_name = 'RaymanWeb.Server'
          command_line = 'RaymanWeb.Server.exe --http-port 5085 --auto-ports'
          executable_path = (Join-Path $root 'bin\RaymanWeb.Server.exe')
        }
      )
      $postCleanup = @($baseline)

      Mock Get-RaymanWorkspaceProcessOwnerContext {
        return [pscustomobject]@{
          owner_key = 'owner-a'
          owner_display = 'owner-a'
        }
      }
      Mock Register-RaymanWorkspaceOwnedProcess {
        param([string]$WorkspaceRootPath, [object]$OwnerContext, [string]$Kind, [string]$Launcher, [int]$RootPid, [string]$Command)
        return [pscustomobject]@{
          workspace_root = $WorkspaceRootPath
          owner_key = [string]$OwnerContext.owner_key
          owner_display = [string]$OwnerContext.owner_display
          kind = $Kind
          launcher = $Launcher
          root_pid = $RootPid
          command = $Command
        }
      }
      Mock Stop-RaymanWorkspaceOwnedProcess {
        param([string]$WorkspaceRootPath, [object]$Record, [string]$Reason)
        return [pscustomobject]@{
          root_pid = [int]$Record.root_pid
          cleanup_reason = $Reason
          cleanup_result = 'cleaned'
          cleanup_pids = @([int]$Record.root_pid)
          alive_pids = @()
        }
      }
      Mock Get-RaymanWorkspaceProcessSnapshot {
        return $postCleanup
      }

      $report = Invoke-RaymanWorkspaceOwnedProcessCleanupFromBaseline -WorkspaceRootPath $root -BaselineSnapshot $baseline -CurrentSnapshot $current -OwnedKind 'project-gate' -OwnedLauncher 'project-gate' -OwnedCommand 'test-command'

      $report.cleanup_result | Should -Be 'cleaned'
      (@($report.root_pids) -join ',') | Should -Be '202'
      (@($report.matched_pids) -join ',') | Should -Be '202,203'
      (@($report.alive_pids) -join ',') | Should -Be ''
      Assert-MockCalled Register-RaymanWorkspaceOwnedProcess -Times 1 -Exactly -Scope It -ParameterFilter {
        $Kind -eq 'project-gate' -and $RootPid -eq 202 -and $Launcher -eq 'project-gate'
      }
      Assert-MockCalled Stop-RaymanWorkspaceOwnedProcess -Times 1 -Exactly -Scope It -ParameterFilter {
        [int]$Record.root_pid -eq 202 -and $Reason -eq 'project-gate'
      }
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'run_tests_and_fix owned process registration' {
  It 'falls back to command line discovery when the pid file is missing' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_owned_registration_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null

      Mock Wait-RaymanDotNetRootPid { return 0 }
      Mock Find-RaymanOwnedWindowsProcessIdsByCommandLineNeedle { return @(777) }
      Mock Get-RaymanWorkspaceProcessOwnerContext {
        return [pscustomobject]@{
          owner_key = 'owner-a'
          owner_display = 'owner-a'
        }
      }
      Mock Register-RaymanWorkspaceOwnedProcess {
        param([string]$WorkspaceRootPath, [object]$OwnerContext, [string]$Kind, [string]$Launcher, [int]$RootPid, [string]$Command)
        return [pscustomobject]@{
          workspace_root = $WorkspaceRootPath
          owner_key = [string]$OwnerContext.owner_key
          owner_display = [string]$OwnerContext.owner_display
          kind = $Kind
          launcher = $Launcher
          root_pid = $RootPid
          started_at = ''
          command = $Command
          state = 'running'
        }
      }

      $resolved = Resolve-RaymanOwnedProcessRegistration -WorkspaceRootPath $root -OwnedKind 'dotnet' -OwnedLauncher 'windows-bridge' -OwnedCommand 'dotnet test' -OwnedCommandLineNeedle 'needle-123'

      [int]$resolved.root_pid | Should -Be 777
      $resolved.record | Should -Not -Be $null
      [string]$resolved.record.owner_key | Should -Be 'owner-a'
      Assert-MockCalled Wait-RaymanDotNetRootPid -Times 1 -Exactly -Scope It
      Assert-MockCalled Find-RaymanOwnedWindowsProcessIdsByCommandLineNeedle -Times 1 -Exactly -Scope It
      Assert-MockCalled Register-RaymanWorkspaceOwnedProcess -Times 1 -Exactly -Scope It
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'workspace_process_ownership integration' {
  It 'kills a Windows process tree registered for the workspace' {
    $psWindows = Resolve-RaymanOwnedWindowsPowerShellPath
    $taskKill = Resolve-RaymanOwnedTaskKillPath
    if ([string]::IsNullOrWhiteSpace($psWindows) -or [string]::IsNullOrWhiteSpace($taskKill)) {
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_owned_integration_' + [Guid]::NewGuid().ToString('N'))
    $rootPid = 0
    $childPid = 0
    $treePids = @()
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime') | Out-Null
      $pidFile = Join-Path $root '.Rayman\runtime\owned_process_root.pid'
      $childPidFile = Join-Path $root '.Rayman\runtime\owned_process_child.pid'
      $pidFileWindows = Convert-RaymanOwnedPathToWindows -PathValue $pidFile
      $childPidFileWindows = Convert-RaymanOwnedPathToWindows -PathValue $childPidFile
      if ([string]::IsNullOrWhiteSpace($pidFileWindows)) {
        return
      }
      if ([string]::IsNullOrWhiteSpace($childPidFileWindows)) {
        return
      }

      $childScript = "Start-Sleep -Seconds 60"
      $childEncoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($childScript))
      $parentScript = @'
$child = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-EncodedCommand', '__CHILD__') -PassThru
Set-Content -LiteralPath '__CHILD_PID_FILE__' -Value $child.Id -Encoding ASCII
Set-Content -LiteralPath '__PIDFILE__' -Value $PID -Encoding ASCII
Start-Sleep -Seconds 60
'@
      $parentScript = $parentScript.Replace('__CHILD__', $childEncoded).Replace('__CHILD_PID_FILE__', (Convert-RaymanOwnedPsSingleQuotedLiteral -Value $childPidFileWindows)).Replace('__PIDFILE__', (Convert-RaymanOwnedPsSingleQuotedLiteral -Value $pidFileWindows))
      $parentEncoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($parentScript))

      $launcher = Start-Process -FilePath $psWindows -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $parentEncoded) -PassThru
      $deadline = (Get-Date).AddSeconds(10)
      while ((Get-Date) -lt $deadline -and (-not (Test-Path -LiteralPath $pidFile -PathType Leaf) -or -not (Test-Path -LiteralPath $childPidFile -PathType Leaf))) {
        Start-Sleep -Milliseconds 200
      }

      (Test-Path -LiteralPath $pidFile -PathType Leaf) | Should -Be $true
      (Test-Path -LiteralPath $childPidFile -PathType Leaf) | Should -Be $true
      $rootPid = [int]((Get-Content -LiteralPath $pidFile -Raw -Encoding ASCII).Trim())
      $childPid = [int]((Get-Content -LiteralPath $childPidFile -Raw -Encoding ASCII).Trim())
      $rootPid | Should -BeGreaterThan 0
      $childPid | Should -BeGreaterThan 0

      $owner = Get-RaymanWorkspaceProcessOwnerContext -WorkspaceRootPath $root -ExplicitOwnerPid '424242'
      $record = Register-RaymanWorkspaceOwnedProcess -WorkspaceRootPath $root -OwnerContext $owner -Kind 'dotnet' -Launcher 'windows-bridge' -RootPid $rootPid -Command 'dotnet test'

      $treePids = @((Get-RaymanWindowsProcessTreePids -WorkspaceRootPath $root -RootPid $rootPid -IncludeRoot) + $childPid | Select-Object -Unique)

      $result = Stop-RaymanWorkspaceOwnedProcess -WorkspaceRootPath $root -Record $record -Reason 'integration-test'

      $result.cleanup_result | Should -Be 'cleaned'
      foreach ($pidValue in $treePids) {
        $details = Get-RaymanOwnedWindowsProcessDetails -WorkspaceRootPath $root -ProcessId ([int]$pidValue)
        [bool]$details.alive | Should -Be $false
      }
      @(Get-RaymanWorkspaceOwnedProcessRecords -WorkspaceRootPath $root).Count | Should -Be 0

      try { Stop-Process -Id $launcher.Id -Force -ErrorAction SilentlyContinue } catch {}
    } finally {
      if ($rootPid -gt 0) {
        try { & $taskKill /PID $rootPid /T /F 2>$null | Out-Null } catch {}
      }
      foreach ($pidValue in $treePids) {
        try { & $taskKill /PID ([int]$pidValue) /T /F 2>$null | Out-Null } catch {}
      }
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
