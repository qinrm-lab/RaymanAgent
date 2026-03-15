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
      Assert-MockCalled Wait-RaymanDotNetRootPid -Times 1 -Exactly
      Assert-MockCalled Find-RaymanOwnedWindowsProcessIdsByCommandLineNeedle -Times 1 -Exactly
      Assert-MockCalled Register-RaymanWorkspaceOwnedProcess -Times 1 -Exactly
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
    $treePids = @()
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime') | Out-Null
      $pidFile = Join-Path $root '.Rayman\runtime\owned_process_root.pid'
      $pidFileWindows = Convert-RaymanOwnedPathToWindows -PathValue $pidFile
      if ([string]::IsNullOrWhiteSpace($pidFileWindows)) {
        return
      }

      $childScript = "Start-Sleep -Seconds 60"
      $childEncoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($childScript))
      $parentScript = @'
$child = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-EncodedCommand', '__CHILD__') -PassThru
Set-Content -LiteralPath '__PIDFILE__' -Value $PID -Encoding ASCII
Start-Sleep -Seconds 60
'@
      $parentScript = $parentScript.Replace('__CHILD__', $childEncoded).Replace('__PIDFILE__', (Convert-RaymanOwnedPsSingleQuotedLiteral -Value $pidFileWindows))
      $parentEncoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($parentScript))

      $launcher = Start-Process -FilePath $psWindows -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $parentEncoded) -PassThru
      $deadline = (Get-Date).AddSeconds(10)
      while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
        Start-Sleep -Milliseconds 200
      }

      (Test-Path -LiteralPath $pidFile -PathType Leaf) | Should -Be $true
      $rootPid = [int]((Get-Content -LiteralPath $pidFile -Raw -Encoding ASCII).Trim())
      $rootPid | Should -BeGreaterThan 0

      $owner = Get-RaymanWorkspaceProcessOwnerContext -WorkspaceRootPath $root -ExplicitOwnerPid '424242'
      $record = Register-RaymanWorkspaceOwnedProcess -WorkspaceRootPath $root -OwnerContext $owner -Kind 'dotnet' -Launcher 'windows-bridge' -RootPid $rootPid -Command 'dotnet test'

      $treePids = @(Get-RaymanWindowsProcessTreePids -WorkspaceRootPath $root -RootPid $rootPid -IncludeRoot)
      $treePids.Count | Should -BeGreaterThan 1

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
