BeforeAll {
  $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  . (Join-Path $script:RepoRoot '.Rayman\scripts\watch\codex_desktop_bootstrap.ps1') -NoMain
}

function script:New-CodexDesktopBootstrapTestRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_desktop_bootstrap_' + [Guid]::NewGuid().ToString('N'))
  $localAppData = Join-Path $root 'LocalAppData'
  $desktopHome = Join-Path $root 'CodexHome'
  $workspaceRoot = Join-Path $root 'Workspace'
  New-Item -ItemType Directory -Force -Path (Join-Path $desktopHome 'sessions\2026\04\02') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $workspaceRoot '.Rayman') | Out-Null
  return [pscustomobject]@{
    root = $root
    local_app_data = $localAppData
    desktop_home = $desktopHome
    workspace_root = $workspaceRoot
  }
}

function script:Write-CodexDesktopBootstrapSession {
  param(
    [string]$DesktopHome,
    [string]$WorkspaceRoot,
    [string]$SessionId = 'desktop-session-1',
    [datetime]$SessionTimestamp = (Get-Date).AddHours(-1),
    [datetime]$LastWriteAt = (Get-Date),
    [string]$Originator = 'Codex Desktop',
    [string]$Source = 'vscode'
  )

  $sessionPath = Join-Path $DesktopHome ('sessions\2026\04\02\rollout-{0}.jsonl' -f [Guid]::NewGuid().ToString('N'))
  $payload = [ordered]@{
    timestamp = (Get-Date).ToString('o')
    type = 'session_meta'
    payload = [ordered]@{
      id = $SessionId
      timestamp = $SessionTimestamp.ToString('o')
      cwd = $WorkspaceRoot
      source = $Source
      originator = $Originator
    }
  }
  (($payload | ConvertTo-Json -Depth 6 -Compress).TrimEnd() + "`n") | Set-Content -LiteralPath $sessionPath -Encoding UTF8
  (Get-Item -LiteralPath $sessionPath).LastWriteTime = $LastWriteAt
  return $sessionPath
}

Describe 'codex desktop bootstrap active workspace detection' {
  It 'does not start watchers for sessions that are only inside the broad lookback window' {
    $fixture = New-CodexDesktopBootstrapTestRoot
    $originalLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    $originalDesktopHome = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME')
    $originalActiveSeconds = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_ACTIVE_SESSION_SECONDS')
    try {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $fixture.local_app_data)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $fixture.desktop_home)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_ACTIVE_SESSION_SECONDS', '120')
      Write-CodexDesktopBootstrapSession -DesktopHome $fixture.desktop_home -WorkspaceRoot $fixture.workspace_root -SessionTimestamp (Get-Date).AddMinutes(-10) -LastWriteAt (Get-Date).AddMinutes(-10) | Out-Null

      $state = Read-RaymanCodexDesktopBootstrapState -ResolvedStatePath (Get-RaymanCodexDesktopBootstrapDefaultStatePath)
      Mock Invoke-RaymanCodexDesktopBootstrapWatchCommand {}

      $result = Invoke-RaymanCodexDesktopBootstrapCycle -State $state

      @($result.active_workspaces).Count | Should -Be 0
      Assert-MockCalled Invoke-RaymanCodexDesktopBootstrapWatchCommand -Times 0 -Exactly
    } finally {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $originalLocalAppData)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $originalDesktopHome)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_ACTIVE_SESSION_SECONDS', $originalActiveSeconds)
      Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'requires session activity to advance before promoting a workspace into the active Desktop index' {
    $fixture = New-CodexDesktopBootstrapTestRoot
    $originalLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    $originalDesktopHome = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME')
    $originalActiveSeconds = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_ACTIVE_SESSION_SECONDS')
    try {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $fixture.local_app_data)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $fixture.desktop_home)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_ACTIVE_SESSION_SECONDS', '120')

      $sessionTimestamp = (Get-Date).AddHours(-6)
      $sessionWriteAt = (Get-Date).AddSeconds(-20)
      $sessionPath = Write-CodexDesktopBootstrapSession -DesktopHome $fixture.desktop_home -WorkspaceRoot $fixture.workspace_root -SessionTimestamp $sessionTimestamp -LastWriteAt $sessionWriteAt

      $state = Read-RaymanCodexDesktopBootstrapState -ResolvedStatePath (Get-RaymanCodexDesktopBootstrapDefaultStatePath)
      Mock Invoke-RaymanCodexDesktopBootstrapWatchCommand {
        [pscustomobject]@{
          success = $true
          exit_code = 0
          output = ''
          error = ''
          command = 'start watchers'
        }
      } -ParameterFilter { [string]$WorkspaceRoot -eq $fixture.workspace_root -and [string]$Action -eq 'start' }

      $firstResult = Invoke-RaymanCodexDesktopBootstrapCycle -State $state
      $firstResult.active_workspaces.Count | Should -Be 0
      Assert-MockCalled Invoke-RaymanCodexDesktopBootstrapWatchCommand -Times 0 -Exactly

      (Get-Item -LiteralPath $sessionPath).LastWriteTime = (Get-Date).AddSeconds(-5)
      $secondResult = Invoke-RaymanCodexDesktopBootstrapCycle -State $state
      $activeEntry = @($secondResult.active_workspaces | Where-Object { [string]$_.workspace_root -eq $fixture.workspace_root } | Select-Object -First 1)[0]
      $savedActivityAt = ConvertTo-RaymanNullableDateTime -Value ([string]$activeEntry.activity_at)

      @($secondResult.active_workspaces).Count | Should -Be 1
      $activeEntry | Should -Not -BeNullOrEmpty
      $savedActivityAt | Should -Not -BeNullOrEmpty
      ([datetime]$savedActivityAt -gt $sessionTimestamp.AddMinutes(1)) | Should -Be $true
      Assert-MockCalled Invoke-RaymanCodexDesktopBootstrapWatchCommand -Times 1 -Exactly -ParameterFilter { [string]$WorkspaceRoot -eq $fixture.workspace_root -and [string]$Action -eq 'start' }
    } finally {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $originalLocalAppData)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $originalDesktopHome)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_ACTIVE_SESSION_SECONDS', $originalActiveSeconds)
      Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'accepts codex_vscode session metadata for the active Desktop index' {
    $fixture = New-CodexDesktopBootstrapTestRoot
    $originalLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    $originalDesktopHome = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME')
    $originalActiveSeconds = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_ACTIVE_SESSION_SECONDS')
    try {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $fixture.local_app_data)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $fixture.desktop_home)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_ACTIVE_SESSION_SECONDS', '120')

      $sessionPath = Write-CodexDesktopBootstrapSession `
        -DesktopHome $fixture.desktop_home `
        -WorkspaceRoot $fixture.workspace_root `
        -Originator 'codex_vscode' `
        -Source 'vscode' `
        -SessionTimestamp (Get-Date).AddHours(-6) `
        -LastWriteAt (Get-Date).AddSeconds(-20)

      $state = Read-RaymanCodexDesktopBootstrapState -ResolvedStatePath (Get-RaymanCodexDesktopBootstrapDefaultStatePath)
      Mock Invoke-RaymanCodexDesktopBootstrapWatchCommand {
        [pscustomobject]@{
          success = $true
          exit_code = 0
          output = ''
          error = ''
          command = 'start watchers'
        }
      } -ParameterFilter { [string]$WorkspaceRoot -eq $fixture.workspace_root -and [string]$Action -eq 'start' }

      $null = Invoke-RaymanCodexDesktopBootstrapCycle -State $state
      (Get-Item -LiteralPath $sessionPath).LastWriteTime = (Get-Date).AddSeconds(-5)
      $result = Invoke-RaymanCodexDesktopBootstrapCycle -State $state

      @($result.active_workspaces).Count | Should -Be 1
      [string]$result.active_workspaces[0].workspace_root | Should -Be $fixture.workspace_root
      Assert-MockCalled Invoke-RaymanCodexDesktopBootstrapWatchCommand -Times 1 -Exactly
    } finally {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $originalLocalAppData)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $originalDesktopHome)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_ACTIVE_SESSION_SECONDS', $originalActiveSeconds)
      Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'auto-applies the bound workspace alias once when a Desktop session becomes active' {
    $fixture = New-CodexDesktopBootstrapTestRoot
    $raymanHome = Join-Path $fixture.root 'RaymanHome'
    $originalLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    $originalDesktopHome = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME')
    $originalActiveSeconds = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_ACTIVE_SESSION_SECONDS')
    $originalRaymanHome = [Environment]::GetEnvironmentVariable('RAYMAN_HOME')
    try {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $fixture.local_app_data)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $fixture.desktop_home)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_ACTIVE_SESSION_SECONDS', '120')
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $raymanHome)

      Ensure-RaymanCodexAccount -Alias 'alpha' | Out-Null
      Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $fixture.workspace_root -AccountAlias 'alpha' -Profile '' | Out-Null
      Set-RaymanCodexAccountLoginDiagnostics -Alias 'alpha' -LoginMode 'web' -AuthScope 'desktop_global' -LaunchStrategy 'switch' -PromptClassification 'none' -StartedAt '2026-04-17T00:00:00Z' -FinishedAt '2026-04-17T00:00:05Z' -Success $true -DesktopTargetMode 'web' | Out-Null

      $sessionPath = Write-CodexDesktopBootstrapSession -DesktopHome $fixture.desktop_home -WorkspaceRoot $fixture.workspace_root -SessionTimestamp (Get-Date).AddHours(-6) -LastWriteAt (Get-Date).AddSeconds(-20)
      $state = Read-RaymanCodexDesktopBootstrapState -ResolvedStatePath (Get-RaymanCodexDesktopBootstrapDefaultStatePath)

      Mock Invoke-RaymanCodexDesktopBootstrapWatchCommand {
        [pscustomobject]@{
          success = $true
          exit_code = 0
          output = ''
          error = ''
          command = 'start watchers'
        }
      } -ParameterFilter { [string]$WorkspaceRoot -eq $fixture.workspace_root -and [string]$Action -eq 'start' }
      Mock Get-RaymanCodexWorkspaceBindingAutoApplyPlan {
        [pscustomobject]@{
          enabled = $true
          applicable = $true
          workspace_root = $fixture.workspace_root
          account_alias = 'alpha'
          binding_profile = ''
          mode = 'web'
          signature = 'alpha|web'
          reason = 'ready'
        }
      } -ParameterFilter { [string]$WorkspaceRoot -eq $fixture.workspace_root }
      Mock Get-RaymanCodexWorkspaceBindingAutoApplyRetrySeconds { 300 } -ParameterFilter { [string]$WorkspaceRoot -eq $fixture.workspace_root }
      Mock Invoke-RaymanCodexWorkspaceBindingAutoApply {
        [pscustomobject]@{
          attempted = $true
          success = $true
          alias = 'alpha'
          mode = 'web'
          signature = 'alpha|web'
          detail = 'desktop_activation_applied'
        }
      } -ParameterFilter { [string]$WorkspaceRoot -eq $fixture.workspace_root }

      $first = Invoke-RaymanCodexDesktopBootstrapCycle -State $state
      @($first.actions | Where-Object { [string]$_.action -eq 'binding-auto-apply' }).Count | Should -Be 0
      Assert-MockCalled Invoke-RaymanCodexWorkspaceBindingAutoApply -Times 0 -Exactly

      (Get-Item -LiteralPath $sessionPath).LastWriteTime = (Get-Date).AddSeconds(-5)
      $second = Invoke-RaymanCodexDesktopBootstrapCycle -State $state
      $bindingActions = @($second.actions | Where-Object { [string]$_.action -eq 'binding-auto-apply' })

      @($bindingActions).Count | Should -Be 1
      [bool]$bindingActions[0].success | Should -Be $true
      Assert-MockCalled Invoke-RaymanCodexWorkspaceBindingAutoApply -Times 1 -Exactly -ParameterFilter { [string]$WorkspaceRoot -eq $fixture.workspace_root }

      $third = Invoke-RaymanCodexDesktopBootstrapCycle -State $state
      @($third.actions | Where-Object { [string]$_.action -eq 'binding-auto-apply' }).Count | Should -Be 0
      Assert-MockCalled Invoke-RaymanCodexWorkspaceBindingAutoApply -Times 1 -Exactly -ParameterFilter { [string]$WorkspaceRoot -eq $fixture.workspace_root }

      $savedState = Get-Content -LiteralPath ([string]$state.StateFilePath) -Raw -Encoding UTF8 | ConvertFrom-Json
      $workspaceState = @($savedState.workspaces.PSObject.Properties | ForEach-Object { $_.Value } | Where-Object { [string]$_.workspace_root -eq $fixture.workspace_root } | Select-Object -First 1)[0]

      [string]$workspaceState.last_binding_auto_apply_signature | Should -Be 'alpha|web|session=desktop-session-1'
      [bool]$workspaceState.last_binding_auto_apply_success | Should -Be $true
    } finally {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $originalLocalAppData)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $originalDesktopHome)
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_ACTIVE_SESSION_SECONDS', $originalActiveSeconds)
      [Environment]::SetEnvironmentVariable('RAYMAN_HOME', $originalRaymanHome)
      Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'treats a dead pid file as stale and replaces it with the current bootstrap pid' {
    $fixture = New-CodexDesktopBootstrapTestRoot
    $originalLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    try {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $fixture.local_app_data)

      $state = Read-RaymanCodexDesktopBootstrapState -ResolvedStatePath (Get-RaymanCodexDesktopBootstrapDefaultStatePath)
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $state.PidFilePath) | Out-Null
      Set-Content -LiteralPath $state.PidFilePath -Value '999999' -NoNewline -Encoding ASCII

      $pidState = Initialize-RaymanCodexDesktopBootstrapPidFile -State $state -ScriptPath (Join-Path $script:RepoRoot '.Rayman\scripts\watch\codex_desktop_bootstrap.ps1')

      [bool]$pidState.already_running | Should -BeFalse
      [int]$pidState.stale_pid | Should -Be 999999
      (Get-Content -LiteralPath $state.PidFilePath -Raw -Encoding UTF8).Trim() | Should -Be ([string]$PID)
    } finally {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $originalLocalAppData)
      Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
