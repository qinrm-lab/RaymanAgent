BeforeAll {
  $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  . (Join-Path $PSScriptRoot '..\..\..\common.ps1')
  . (Join-Path $PSScriptRoot '..\..\watch\watch_lifecycle.lib.ps1')
  . (Join-Path $PSScriptRoot '..\..\utils\workspace_process_ownership.ps1') -NoMain
  . (Join-Path $PSScriptRoot '..\..\watch\stop_background_watchers.ps1') -WorkspaceRoot $script:RepoRoot -NoMain
}

function script:New-WatchLifecycleRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_watch_lifecycle_' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime\vscode_sessions') | Out-Null
  return $root
}

function script:Write-WatchSession {
  param(
    [string]$Root,
    [int]$ParentPid,
    [string]$State = 'watching',
    [string]$ParentStartUtc = ''
  )

  $sessionPath = Join-Path $Root ('.Rayman\runtime\vscode_sessions\{0}.json' -f $ParentPid)
  $payload = [ordered]@{
    parentPid = $ParentPid
    parentStartUtc = $ParentStartUtc
    state = $State
    updatedAt = '2026-03-18T15:25:45.0000000+08:00'
  } | ConvertTo-Json -Depth 4

  Set-Content -LiteralPath $sessionPath -Encoding UTF8 -Value $payload
}

function script:New-OwnedCleanupResult {
  param(
    [object]$Record,
    [string]$Reason
  )

  return [pscustomobject]@{
    kind = [string]$Record.kind
    root_pid = [int]$Record.root_pid
    owner_display = [string]$Record.owner_display
    cleanup_reason = $Reason
    cleanup_result = 'cleaned'
    cleanup_pids = @([int]$Record.root_pid)
    alive_pids = @()
  }
}

Describe 'watch lifecycle helpers' {
  It 'classifies active and invalid VS Code session files consistently' {
    $root = New-WatchLifecycleRoot
    try {
      Write-WatchSession -Root $root -ParentPid 202 -State 'watching'
      Set-Content -LiteralPath (Join-Path $root '.Rayman\runtime\vscode_sessions\bad.json') -Encoding UTF8 -Value '{bad json'

      Mock Test-RaymanTrackedProcessAlive {
        param([int]$ProcessId, [string]$ExpectedStartUtc)
        return ($ProcessId -eq 202)
      }

      $entries = @(Get-RaymanVsCodeSessionEntries -SessionDirectory (Join-Path $root '.Rayman\runtime\vscode_sessions'))

      @($entries).Count | Should -Be 2
      ($entries | Where-Object { [int]$_.parent_pid -eq 202 }).active | Should -Be $true
      ($entries | Where-Object { -not [bool]$_.valid }).parse_error | Should -Not -BeNullOrEmpty
      (@(Get-RaymanOtherActiveVsCodeSessions -SessionDirectory (Join-Path $root '.Rayman\runtime\vscode_sessions') -CurrentOwnerPid 101)).Count | Should -Be 1
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'uses stable cleanup reason tags for owner and shared shutdown paths' {
    Get-RaymanWatchCleanupReason | Should -Be 'watch-stop'
    Get-RaymanWatchCleanupReason -OwnerExit | Should -Be 'watch-stop-owner-exit'
    Get-RaymanWatchCleanupReason -Shared | Should -Be 'watch-stop-shared'
    Get-RaymanWatchCleanupReason -OwnerExit -Shared | Should -Be 'watch-stop-owner-exit-shared'
  }
}

Describe 'watch stop lifecycle orchestration' {
  BeforeEach {
    $script:ownerContext = [pscustomobject]@{
      owner_key = 'owner::101'
      owner_display = 'VSCODE_PID#101'
    }
    $script:sharedContext = [pscustomobject]@{
      owner_key = 'shared::workspace'
      owner_display = 'workspace-shared#abc'
    }

    Mock Get-RaymanWorkspaceProcessOwnerContext { return $script:ownerContext }
    Mock Get-RaymanWorkspaceSharedProcessOwnerContext { return $script:sharedContext }
    Mock Stop-ProcessByPidFile {}
    Mock Stop-ResidualRaymanStartupProcesses {}
    Mock Remove-RaymanWorkspaceOwnedProcess {}
    Mock Stop-RaymanWorkspaceOwnedProcess {
      param([string]$WorkspaceRootPath, [object]$Record, [string]$Reason)
      return (New-OwnedCleanupResult -Record $Record -Reason $Reason)
    }
  }

  It 'keeps shared services running when another VS Code session is still active' {
    $root = New-WatchLifecycleRoot
    try {
      Write-WatchSession -Root $root -ParentPid 101 -State 'parent-exited'
      Write-WatchSession -Root $root -ParentPid 202 -State 'watching'

      Mock Test-RaymanTrackedProcessAlive {
        param([int]$ProcessId, [string]$ExpectedStartUtc)
        return ($ProcessId -eq 202)
      }
      Mock Get-RaymanWorkspaceOwnedProcessRecords {
        return @(
          [pscustomobject]@{ owner_key = $script:ownerContext.owner_key; owner_display = $script:ownerContext.owner_display; kind = 'watcher'; root_pid = 4100; launcher = 'watch-auto-exitwatch' }
          [pscustomobject]@{ owner_key = $script:ownerContext.owner_key; owner_display = $script:ownerContext.owner_display; kind = 'dotnet'; root_pid = 4200; launcher = 'windows-bridge' }
          [pscustomobject]@{ owner_key = $script:ownerContext.owner_key; owner_display = $script:ownerContext.owner_display; kind = 'vscode'; root_pid = 4250; launcher = 'setup-vscode-window' }
          [pscustomobject]@{ owner_key = $script:sharedContext.owner_key; owner_display = $script:sharedContext.owner_display; kind = 'watcher'; root_pid = 4300; launcher = 'watch-auto-shared' }
          [pscustomobject]@{ owner_key = $script:sharedContext.owner_key; owner_display = $script:sharedContext.owner_display; kind = 'mcp'; root_pid = 4400; launcher = 'watch-auto-mcp' }
        )
      }

      Invoke-RaymanStopBackgroundWatchers -WorkspaceRootPath $root -ExplicitOwnerPid '101' -OwnerExit

      Assert-MockCalled Stop-RaymanWorkspaceOwnedProcess -Times 3 -Exactly -Scope It -ParameterFilter {
        [int]$Record.root_pid -in @(4100, 4200, 4250)
      }
      Assert-MockCalled Stop-RaymanWorkspaceOwnedProcess -Times 0 -Scope It -ParameterFilter {
        [int]$Record.root_pid -in @(4300, 4400)
      }
      Assert-MockCalled Stop-ProcessByPidFile -Times 0 -Exactly -Scope It
      Assert-MockCalled Stop-ResidualRaymanStartupProcesses -Times 1 -Exactly -Scope It -ParameterFilter {
        (-not $StopSharedServices) -and $CurrentOwnerPid -eq 101
      }
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'stops shared services when other session files are stale or dead' {
    $root = New-WatchLifecycleRoot
    try {
      Write-WatchSession -Root $root -ParentPid 101 -State 'parent-exited'
      Write-WatchSession -Root $root -ParentPid 202 -State 'watching'

      Mock Test-RaymanTrackedProcessAlive { return $false }
      Mock Get-RaymanWorkspaceOwnedProcessRecords {
        return @(
          [pscustomobject]@{ owner_key = $script:ownerContext.owner_key; owner_display = $script:ownerContext.owner_display; kind = 'watcher'; root_pid = 4100; launcher = 'watch-auto-exitwatch' }
          [pscustomobject]@{ owner_key = $script:ownerContext.owner_key; owner_display = $script:ownerContext.owner_display; kind = 'dotnet'; root_pid = 4200; launcher = 'windows-bridge' }
          [pscustomobject]@{ owner_key = $script:ownerContext.owner_key; owner_display = $script:ownerContext.owner_display; kind = 'vscode'; root_pid = 4250; launcher = 'setup-vscode-window' }
          [pscustomobject]@{ owner_key = $script:sharedContext.owner_key; owner_display = $script:sharedContext.owner_display; kind = 'watcher'; root_pid = 4300; launcher = 'watch-auto-shared' }
          [pscustomobject]@{ owner_key = $script:sharedContext.owner_key; owner_display = $script:sharedContext.owner_display; kind = 'mcp'; root_pid = 4400; launcher = 'watch-auto-mcp' }
        )
      }

      Invoke-RaymanStopBackgroundWatchers -WorkspaceRootPath $root -ExplicitOwnerPid '101' -OwnerExit

      Assert-MockCalled Stop-RaymanWorkspaceOwnedProcess -Times 5 -Exactly -Scope It
      Assert-MockCalled Stop-ProcessByPidFile -Times 5 -Exactly -Scope It
      Assert-MockCalled Stop-ResidualRaymanStartupProcesses -Times 1 -Exactly -Scope It -ParameterFilter {
        $StopSharedServices -and $CurrentOwnerPid -eq 101
      }
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'stops shared services during manual watch-stop even if another session is active' {
    $root = New-WatchLifecycleRoot
    try {
      Write-WatchSession -Root $root -ParentPid 202 -State 'watching'

      Mock Test-RaymanTrackedProcessAlive { return $true }
      Mock Get-RaymanWorkspaceOwnedProcessRecords {
        return @(
          [pscustomobject]@{ owner_key = $script:ownerContext.owner_key; owner_display = $script:ownerContext.owner_display; kind = 'watcher'; root_pid = 4100; launcher = 'watch-auto-exitwatch' }
          [pscustomobject]@{ owner_key = $script:ownerContext.owner_key; owner_display = $script:ownerContext.owner_display; kind = 'dotnet'; root_pid = 4200; launcher = 'windows-bridge' }
          [pscustomobject]@{ owner_key = $script:ownerContext.owner_key; owner_display = $script:ownerContext.owner_display; kind = 'vscode'; root_pid = 4250; launcher = 'setup-vscode-window' }
          [pscustomobject]@{ owner_key = $script:sharedContext.owner_key; owner_display = $script:sharedContext.owner_display; kind = 'watcher'; root_pid = 4300; launcher = 'watch-auto-shared' }
          [pscustomobject]@{ owner_key = $script:sharedContext.owner_key; owner_display = $script:sharedContext.owner_display; kind = 'mcp'; root_pid = 4400; launcher = 'watch-auto-mcp' }
        )
      }

      Invoke-RaymanStopBackgroundWatchers -WorkspaceRootPath $root -ExplicitOwnerPid '101'

      Assert-MockCalled Stop-RaymanWorkspaceOwnedProcess -Times 5 -Exactly -Scope It
      Assert-MockCalled Stop-ProcessByPidFile -Times 5 -Exactly -Scope It
      Assert-MockCalled Stop-ResidualRaymanStartupProcesses -Times 0 -Exactly -Scope It
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'keeps shared shutdown isolated from owner-scoped records when shared-only is requested' {
    $root = New-WatchLifecycleRoot
    try {
      Write-WatchSession -Root $root -ParentPid 101 -State 'parent-exited'

      Mock Test-RaymanTrackedProcessAlive { return $false }
      Mock Get-RaymanWorkspaceOwnedProcessRecords {
        return @(
          [pscustomobject]@{ owner_key = $script:ownerContext.owner_key; owner_display = $script:ownerContext.owner_display; kind = 'watcher'; root_pid = 4100; launcher = 'watch-auto-exitwatch' }
          [pscustomobject]@{ owner_key = $script:ownerContext.owner_key; owner_display = $script:ownerContext.owner_display; kind = 'dotnet'; root_pid = 4200; launcher = 'windows-bridge' }
          [pscustomobject]@{ owner_key = $script:ownerContext.owner_key; owner_display = $script:ownerContext.owner_display; kind = 'vscode'; root_pid = 4250; launcher = 'setup-vscode-window' }
          [pscustomobject]@{ owner_key = $script:sharedContext.owner_key; owner_display = $script:sharedContext.owner_display; kind = 'watcher'; root_pid = 4300; launcher = 'watch-auto-shared' }
          [pscustomobject]@{ owner_key = $script:sharedContext.owner_key; owner_display = $script:sharedContext.owner_display; kind = 'mcp'; root_pid = 4400; launcher = 'watch-auto-mcp' }
        )
      }

      Invoke-RaymanStopBackgroundWatchers -WorkspaceRootPath $root -ExplicitOwnerPid '101' -OwnerExit -SharedOnly

      Assert-MockCalled Stop-RaymanWorkspaceOwnedProcess -Times 2 -Exactly -Scope It -ParameterFilter {
        [int]$Record.root_pid -in @(4300, 4400)
      }
      Assert-MockCalled Stop-RaymanWorkspaceOwnedProcess -Times 0 -Scope It -ParameterFilter {
        [int]$Record.root_pid -in @(4100, 4200, 4250)
      }
      Assert-MockCalled Stop-ProcessByPidFile -Times 5 -Exactly -Scope It
      Assert-MockCalled Stop-ResidualRaymanStartupProcesses -Times 1 -Exactly -Scope It -ParameterFilter {
        $StopSharedServices -and $SkipExitWatchResiduals -and $CurrentOwnerPid -eq 101
      }
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'watch task generation contracts' {
  It 'adds residual cleanup and owner pid to the generated Stop Watchers task' {
    $setupRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\setup.ps1') -Raw -Encoding UTF8
    $installRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\watch\install_vscode_autostart.ps1') -Raw -Encoding UTF8

    $setupRaw | Should -Match 'Rayman: Stop Watchers'
    $setupRaw | Should -Match 'stop_background_watchers\.ps1", "-IncludeResidualCleanup", "-OwnerPid", "\`\$\{env:VSCODE_PID\}"'
    $installRaw | Should -Match '\$desiredStopTask'
    $installRaw | Should -Match "'-IncludeResidualCleanup'"
    $installRaw | Should -Match "'\$\{env:VSCODE_PID\}'"
  }

  It 'uses the shared win-watch host for embedded attention, auto-save, and network resume instead of detached helpers' {
    $startRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\watch\start_background_watchers.ps1') -Raw -Encoding UTF8
    $processPromptRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\requirements\process_prompts.ps1') -Raw -Encoding UTF8

    $startRaw | Should -Match 'RAYMAN_AUTO_START_ATTENTION_WATCH_ENABLED'
    $startRaw | Should -Match 'Get-RaymanWorkspaceEnvBool -WorkspaceRoot \$WorkspaceRoot -Name ''RAYMAN_AUTO_START_ATTENTION_WATCH_ENABLED'''
    $startRaw | Should -Match 'EnableEmbeddedAttentionWatch'
    $startRaw | Should -Match 'EnableEmbeddedAutoSave'
    $startRaw | Should -Match 'RAYMAN_NETWORK_RESUME_WATCH_ENABLED'
    $startRaw | Should -Match 'EnableEmbeddedNetworkResume'
    $startRaw | Should -Match 'FromCodexDesktopAuto'
    $startRaw | Should -Match 'trigger=codex-desktop-auto'
    $startRaw | Should -Match 'DisablePromptSync'
    $startRaw | Should -Not -Match "Name 'attention-watch'"
    $startRaw | Should -Not -Match "Name 'auto-save-watch'"
    $startRaw | Should -Not -Match "Name 'network-resume-watch'"
    $processPromptRaw | Should -Not -Match 'ensure_attention_watch\.ps1'
  }

  It 'cleans stale owned watcher records before re-registering detached watchers' {
    $startRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\watch\start_background_watchers.ps1') -Raw -Encoding UTF8

    $startRaw | Should -Match 'function Remove-StaleRaymanBackgroundProcessRecords'
    $startRaw | Should -Match 'Get-RaymanWorkspaceOwnedProcessRecords'
    $startRaw | Should -Match 'Remove-RaymanWorkspaceOwnedProcess'
    $startRaw | Should -Match 'removing stale owned process record'
  }

  It 'keeps provider-target network resume defaults and wiring mirrored across source and dist' {
    $setupRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\setup.ps1') -Raw -Encoding UTF8
    $winWatchRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\win-watch.ps1') -Raw -Encoding UTF8
    $winWatchDistRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\.dist\win-watch.ps1') -Raw -Encoding UTF8
    $embeddedRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\watch\embedded_watchers.lib.ps1') -Raw -Encoding UTF8
    $embeddedDistRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\.dist\scripts\watch\embedded_watchers.lib.ps1') -Raw -Encoding UTF8
    $readmeRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\README.md') -Raw -Encoding UTF8
    $readmeDistRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\.dist\README.md') -Raw -Encoding UTF8

    $setupRaw | Should -Match "'RAYMAN_NETWORK_RESUME_WATCH_ENABLED' = '1'"
    $setupRaw | Should -Match "'RAYMAN_NETWORK_RESUME_THROTTLE_WAIT_SECONDS' = '1800'"
    $setupRaw | Should -Match "'RAYMAN_NETWORK_RESUME_RETRY_SECONDS' = '1800'"
    $setupRaw | Should -Not -Match 'RAYMAN_NETWORK_RESUME_MAX_ATTEMPTS'
    $setupRaw | Should -Match "'RAYMAN_NETWORK_RESUME_CODEX_PROBE_URL' = 'https://api.openai.com/'"
    $winWatchRaw | Should -Match 'EnableEmbeddedNetworkResume'
    $winWatchRaw | Should -Match 'network-resume'
    $winWatchDistRaw | Should -Match 'EnableEmbeddedNetworkResume'
    $embeddedRaw | Should -Match 'network_resume\.status\.json'
    $embeddedRaw | Should -Match 'pending_continuation\.json'
    $embeddedRaw | Should -Match 'transient_provider_outage'
    $embeddedRaw | Should -Match 'FirstSaveIdleSeconds'
    $embeddedRaw | Should -Match 'Start-RaymanSharedSessionContinuationDetached'
    $embeddedRaw | Should -Match 'InjectedPreamble'
    $embeddedDistRaw | Should -Match 'network_resume\.status\.json'
    $readmeRaw | Should -Match 'RAYMAN_NETWORK_RESUME_WATCH_ENABLED=0'
    $readmeRaw | Should -Match 'RAYMAN_NETWORK_RESUME_THROTTLE_WAIT_SECONDS=<秒>'
    $readmeRaw | Should -Match 'RAYMAN_NETWORK_RESUME_RETRY_SECONDS=<秒>'
    $readmeRaw | Should -Match 'RAYMAN_NETWORK_RESUME_CODEX_PROBE_URL=<https-url>'
    $readmeRaw | Should -Match '500 / 502 / 503 / 504 / service unavailable / gateway timeout / upstream / backend overloaded'
    $readmeRaw | Should -Match 'canonical shared session / handoff continuation'
    $readmeDistRaw | Should -Match 'RAYMAN_NETWORK_RESUME_WATCH_ENABLED=0'
    $readmeDistRaw | Should -Match 'RAYMAN_NETWORK_RESUME_THROTTLE_WAIT_SECONDS=<秒>'
  }

  It 'keeps attention defaults enabled for shared watcher scanning and completion sounds' {
    $setupRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\setup.ps1') -Raw -Encoding UTF8
    $readmeRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\README.md') -Raw -Encoding UTF8

    $setupRaw | Should -Match "'RAYMAN_ALERT_DONE_ENABLED' = '1'"
    $setupRaw | Should -Match "'RAYMAN_ALERT_SOUND_ENABLED' = '1'"
    $setupRaw | Should -Match "'RAYMAN_ALERT_SOUND_DONE_ENABLED' = '1'"
    $setupRaw | Should -Match "'RAYMAN_AUTO_START_ATTENTION_WATCH_ENABLED' = '1'"
    $setupRaw | Should -Match "'RAYMAN_ALERT_WATCH_VSCODE_WINDOWS_ENABLED' = '1'"
    $readmeRaw | Should -Match '默认完成提醒与人工等待提醒都会出声'
    $readmeRaw | Should -Match 'RAYMAN_ALERT_WATCH_VSCODE_WINDOWS_ENABLED=0'
  }

  It 'keeps init and VS Code bootstrap on the shared watcher path' {
    $initRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\init.ps1') -Raw -Encoding UTF8
    $bootstrapRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\watch\vscode_folder_open_bootstrap.ps1') -Raw -Encoding UTF8
    $startRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\watch\start_background_watchers.ps1') -Raw -Encoding UTF8

    $initRaw | Should -Not -Match 'Start-RaymanAttentionWatch'
    $initRaw | Should -Not -Match 'attention_watch\.ps1'
    $bootstrapRaw | Should -Match 'start_background_watchers\.ps1'
    $bootstrapRaw | Should -Not -Match 'attention_watch\.ps1'
    $bootstrapRaw | Should -Not -Match 'ensure_attention_watch\.ps1'
    $startRaw | Should -Match 'EnableEmbeddedAttentionWatch'
  }

  It 'keeps Codex desktop auto-stop on shared-only cleanup' {
    $bootstrapRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\watch\codex_desktop_bootstrap.ps1') -Raw -Encoding UTF8

    $bootstrapRaw | Should -Match "'-SharedOnly'"
  }

  It 'starts worker auto-sync as a dedicated detached watcher and stops it with shared services' {
    $startRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\watch\start_background_watchers.ps1') -Raw -Encoding UTF8
    $stopRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\watch\stop_background_watchers.ps1') -Raw -Encoding UTF8

    $startRaw | Should -Match 'worker_auto_sync\.ps1'
    $startRaw | Should -Match "Name 'worker-auto-sync'"
    $startRaw | Should -Match "EnableEnvName 'RAYMAN_WORKER_AUTO_SYNC_ENABLED'"
    $startRaw | Should -Match "Launcher 'watch-auto-worker-sync'"
    $stopRaw | Should -Match 'worker_auto_sync\.pid'
    $stopRaw | Should -Match 'worker_auto_sync\.ps1'
  }

  It 'keeps shared watcher helper assets mirrored and repairable' {
    $assertPsRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\release\assert_dist_sync.ps1') -Raw -Encoding UTF8
    $assertShRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\release\assert_dist_sync.sh') -Raw -Encoding UTF8
    $repairPsRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\repair\ensure_complete_rayman.ps1') -Raw -Encoding UTF8
    $repairShRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\repair\ensure_complete_rayman.sh') -Raw -Encoding UTF8

    foreach ($rel in @(
      'scripts/watch/embedded_watchers.lib.ps1',
      'scripts/watch/stop_background_watchers.ps1',
      'scripts/watch/watch_lifecycle.lib.ps1',
      'scripts/watch/worker_auto_sync.ps1',
      'scripts/watch/codex_desktop_bootstrap.ps1',
      'scripts/watch/vscode_folder_open_bootstrap.ps1'
    )) {
      $srcPath = Join-Path $script:RepoRoot ('.Rayman\' + $rel.Replace('/', '\'))
      $distPath = Join-Path $script:RepoRoot ('.Rayman\.dist\' + $rel.Replace('/', '\'))
      $repairPsPath = '.Rayman\' + $rel.Replace('/', '\')
      $repairShPath = './.Rayman/' + $rel

      (Test-Path -LiteralPath $srcPath -PathType Leaf) | Should -Be $true
      (Test-Path -LiteralPath $distPath -PathType Leaf) | Should -Be $true
      $assertPsRaw | Should -Match ([regex]::Escape($rel))
      $assertShRaw | Should -Match ([regex]::Escape($rel))
      $repairPsRaw | Should -Match ([regex]::Escape($repairPsPath))
      $repairShRaw | Should -Match ([regex]::Escape($repairShPath))
    }
  }

  It 'installs a user-level Codex Desktop bootstrap alongside workspace-register' {
    $registerRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\workspace\register_workspace.ps1') -Raw -Encoding UTF8
    $bootstrapRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\watch\codex_desktop_bootstrap.ps1') -Raw -Encoding UTF8

    $registerRaw | Should -Match 'rayman-codex-desktop-bootstrap\.ps1'
    $registerRaw | Should -Match 'rayman-codex-desktop-bootstrap\.cmd'
    $registerRaw | Should -Match 'rayman-codex-desktop-bootstrap\.vbs'
    $registerRaw | Should -Match 'startup_path'
    $bootstrapRaw | Should -Match 'Get-RaymanCodexDesktopBootstrapWorkspaceEntries'
    $bootstrapRaw | Should -Match 'FromCodexDesktopAuto'
    $bootstrapRaw | Should -Match 'RAYMAN_CODEX_DESKTOP_WATCH_AUTO_START_ENABLED'
  }

  It 'routes pending-task reminders through the shared attention pipeline' {
    $pendingRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\state\check_pending_task.ps1') -Raw -Encoding UTF8

    $pendingRaw | Should -Match 'Invoke-RaymanAttentionAlert'
    $pendingRaw | Should -Not -Match 'ToastNotificationManager'
    $pendingRaw | Should -Not -Match 'notify-send'
    $pendingRaw | Should -Not -Match 'SoundPlayer'
    $pendingRaw | Should -Not -Match 'Invoke-RaymanAttentionSoundFile'
  }

  It 'prefers powershell.exe for approval-sensitive Windows launchers' {
    $setupRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\setup.ps1') -Raw -Encoding UTF8
    $installRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\watch\install_vscode_autostart.ps1') -Raw -Encoding UTF8
    $installDistRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\.dist\scripts\watch\install_vscode_autostart.ps1') -Raw -Encoding UTF8
    $capabilitiesRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\agents\ensure_agent_capabilities.ps1') -Raw -Encoding UTF8
    $capabilitiesDistRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\.dist\scripts\agents\ensure_agent_capabilities.ps1') -Raw -Encoding UTF8
    $agentsRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'AGENTS.md') -Raw -Encoding UTF8
    $copilotRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github\copilot-instructions.md') -Raw -Encoding UTF8
    $generalRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github\instructions\general.instructions.md') -Raw -Encoding UTF8
    $readmeRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\README.md') -Raw -Encoding UTF8

    $setupRaw | Should -Match 'function Normalize-RaymanTaskCommand'
    $setupRaw | Should -Match '\[string\]\$Command = "powershell\.exe"'
    $setupRaw | Should -Match '\$effectiveCommand = Normalize-RaymanTaskCommand -Command \$Command'
    $setupRaw | Should -Match '\$effectiveCommand = Normalize-RaymanTaskCommand -Command "powershell"'
    $installRaw | Should -Match "command = 'powershell\.exe'"
    $installDistRaw | Should -Match "command = 'powershell\.exe'"
    $capabilitiesRaw | Should -Match "if \(Test-HostIsWindows\)"
    $capabilitiesRaw | Should -Match "Get-Command 'powershell\.exe'"
    $capabilitiesDistRaw | Should -Match "Get-Command 'powershell\.exe'"
    $agentsRaw | Should -Match 'powershell\.exe -Command'
    $copilotRaw | Should -Match 'powershell\.exe -Command'
    $generalRaw | Should -Match 'powershell\.exe -Command'
    $readmeRaw | Should -Match 'powershell\.exe -Command'
  }

  It 'keeps fast-contract missing-base-ref bypass local-only and documents WinApp MCP fallback' {
    $fastContractRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\testing\run_fast_contract.sh') -Raw -Encoding UTF8
    $copilotRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github\copilot-instructions.md') -Raw -Encoding UTF8
    $readmeRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\README.md') -Raw -Encoding UTF8

    $fastContractRaw | Should -Match '\$\{CI:-\}'
    $fastContractRaw | Should -Match 'RAYMAN_ALLOW_MISSING_BASE_REF=1'
    $fastContractRaw | Should -Match '\[\[\s*"\$\{RAYMAN_ALLOW_MISSING_BASE_REF\}"\s*==\s*"1"\s*\]\]'
    $fastContractRaw | Should -Match 'fast-contract-local-no-origin-main'
    $fastContractRaw | Should -Match 'RUN_DIR="\$\{RUNTIME_DIR\}/runs/fast_contract/\$\{RUN_ID\}"'
    $fastContractRaw | Should -Match 'publish_latest_artifact'
    $copilotRaw | Should -Match 'Rayman WinApp MCP'
    $copilotRaw | Should -Match 'project_doc'
    $copilotRaw | Should -Match '\.github/agents'
    $copilotRaw | Should -Match '\.github/skills'
    $copilotRaw | Should -Match '\.github/prompts'
    $copilotRaw | Should -Match 'ensure-winapp'
    $copilotRaw | Should -Match 'gh auth setup-git'
    $copilotRaw | Should -Match 'winapp-test'
    $readmeRaw | Should -Match 'run_fast_contract\.sh'
    $readmeRaw | Should -Match 'missing-base-ref'
  }
}
