Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  $script:SaveStateScript = Join-Path $script:WorkspaceRoot '.Rayman\scripts\state\save_state.ps1'
  $script:ResumeStateScript = Join-Path $script:WorkspaceRoot '.Rayman\scripts\state\resume_state.ps1'
  $script:ListStateScript = Join-Path $script:WorkspaceRoot '.Rayman\scripts\state\list_state.ps1'
  $script:RollbackScript = Join-Path $script:WorkspaceRoot '.Rayman\scripts\state\rollback_state.ps1'
  $script:WorktreeCreateScript = Join-Path $script:WorkspaceRoot '.Rayman\scripts\state\worktree_create.ps1'
  $script:SessionCommonPath = Join-Path $script:WorkspaceRoot '.Rayman\scripts\state\session_common.ps1'
  $script:SharedSessionScript = Join-Path $script:WorkspaceRoot '.Rayman\scripts\state\shared_session.ps1'
  $script:SharedSessionCommonPath = Join-Path $script:WorkspaceRoot '.Rayman\scripts\state\shared_session_common.ps1'
  $script:CodexCommonPath = Join-Path $script:WorkspaceRoot '.Rayman\scripts\codex\codex_common.ps1'
  $script:EmbeddedWatchersPath = Join-Path $script:WorkspaceRoot '.Rayman\scripts\watch\embedded_watchers.lib.ps1'
  $script:GitPath = (Get-Command git -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1)
  . $script:SessionCommonPath
  . $script:SharedSessionCommonPath
  . $script:CodexCommonPath
}

function script:New-StateSessionTestRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_state_sessions_' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  return $root
}

function script:Initialize-StateSessionGitRoot {
  param([string]$Root)

  & $script:GitPath -C $Root init | Out-Null
  & $script:GitPath -C $Root config user.email 'rayman@example.test' | Out-Null
  & $script:GitPath -C $Root config user.name 'Rayman Tests' | Out-Null
  Set-Content -LiteralPath (Join-Path $Root 'notes.txt') -Encoding UTF8 -Value 'base'
  & $script:GitPath -C $Root add notes.txt | Out-Null
  & $script:GitPath -C $Root commit -m 'base' | Out-Null
}

function script:New-StateSessionOwnerContext {
  param(
    [string]$Root,
    [string]$Token,
    [string]$Source = 'VSCODE_PID'
  )

  $workspaceHash = Get-RaymanSessionStableHash -Value $Root
  $ownerHash = Get-RaymanSessionStableHash -Value $Token
  [pscustomobject]@{
    workspace_root = $Root
    workspace_hash = $workspaceHash
    owner_source = $Source
    owner_token = $Token
    owner_hash = $ownerHash
    owner_key = ('{0}:{1}:{2}' -f $Source, $ownerHash, $workspaceHash)
    owner_display = ('{0}#{1}' -f $Source, $Token)
  }
}

function script:Get-StateSessionEventTypes {
  param([string]$Root)

  $eventDir = Join-Path $Root '.Rayman\runtime\events'
  if (-not (Test-Path -LiteralPath $eventDir -PathType Container)) {
    return @()
  }

  $types = New-Object System.Collections.Generic.List[string]
  foreach ($file in @(Get-ChildItem -LiteralPath $eventDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)) {
    foreach ($line in @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)) {
      if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
      try {
        $event = [string]$line | ConvertFrom-Json -ErrorAction Stop
        if ($event.PSObject.Properties['event_type']) {
          $types.Add([string]$event.event_type) | Out-Null
        }
      } catch {}
    }
  }

  return @($types.ToArray())
}

Describe 'named state sessions' {
  It 'saves two named sessions and lists them newest first' {
    $root = New-StateSessionTestRoot
    try {
      Initialize-StateSessionGitRoot -Root $root

      Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Encoding UTF8 -Value 'alpha change'
      & $script:SaveStateScript -WorkspaceRoot $root -Name 'Alpha' -TaskDescription 'alpha task' | Out-Null
      Start-Sleep -Milliseconds 50

      Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Encoding UTF8 -Value 'beta change'
      & $script:SaveStateScript -WorkspaceRoot $root -Name 'Beta' -TaskDescription 'beta task' | Out-Null

      $list = & $script:ListStateScript -WorkspaceRoot $root -Json | ConvertFrom-Json

      $list.schema | Should -Be 'rayman.state.list.v1'
      $list.count | Should -Be 2
      $list.sessions[0].name | Should -Be 'Beta'
      $list.sessions[1].name | Should -Be 'Alpha'
      $list.sessions[0].has_stash | Should -Be $true
      $list.sessions[1].has_stash | Should -Be $true
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'restores the requested named session instead of the latest stash' {
    $root = New-StateSessionTestRoot
    try {
      Initialize-StateSessionGitRoot -Root $root

      Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Encoding UTF8 -Value 'alpha change'
      & $script:SaveStateScript -WorkspaceRoot $root -Name 'Alpha' -TaskDescription 'alpha task' | Out-Null

      Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Encoding UTF8 -Value 'beta change'
      & $script:SaveStateScript -WorkspaceRoot $root -Name 'Beta' -TaskDescription 'beta task' | Out-Null

      & $script:ResumeStateScript -WorkspaceRoot $root -Name 'Alpha' | Out-Null

      (Get-Content -LiteralPath (Join-Path $root 'notes.txt') -Raw -Encoding UTF8).Trim() | Should -Be 'alpha change'
      ((Read-RaymanSessionJsonOrNull -Path (Join-Path $root '.Rayman\state\sessions\alpha\session.json')).status) | Should -Be 'resumed'
      ((Read-RaymanSessionJsonOrNull -Path (Join-Path $root '.Rayman\state\sessions\beta\session.json')).status) | Should -Be 'paused'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'does not mutate session state when resume is called without a name' {
    $root = New-StateSessionTestRoot
    try {
      Initialize-StateSessionGitRoot -Root $root

      Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Encoding UTF8 -Value 'alpha change'
      & $script:SaveStateScript -WorkspaceRoot $root -Name 'Alpha' -TaskDescription 'alpha task' | Out-Null

      $before = Read-RaymanSessionJsonOrNull -Path (Join-Path $root '.Rayman\state\sessions\alpha\session.json')
      $prompt = & $script:ResumeStateScript -WorkspaceRoot $root -Json | ConvertFrom-Json
      $after = Read-RaymanSessionJsonOrNull -Path (Join-Path $root '.Rayman\state\sessions\alpha\session.json')

      $prompt.schema | Should -Be 'rayman.state.resume.prompt.v1'
      $prompt.count | Should -Be 1
      $before.status | Should -Be 'paused'
      $after.status | Should -Be 'paused'
      $after.updated_at | Should -Be $before.updated_at
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'session isolation helpers' {
  BeforeAll {
    . $script:EmbeddedWatchersPath
  }

  It 'prefers owner-scoped active sessions and falls back to the legacy mirror' {
    $root = New-StateSessionTestRoot
    try {
      $ownerA = New-StateSessionOwnerContext -Root $root -Token '111'
      $ownerB = New-StateSessionOwnerContext -Root $root -Token '222'
      $ownerC = New-StateSessionOwnerContext -Root $root -Token '333'

      $alphaManifest = New-RaymanSessionManifest -WorkspaceRoot $root -Name 'Alpha' -Slug 'alpha' -Status 'resumed' -Isolation 'shared' -TaskDescription 'alpha' -OwnerContext $ownerA
      $betaManifest = New-RaymanSessionManifest -WorkspaceRoot $root -Name 'Beta' -Slug 'beta' -Status 'resumed' -Isolation 'shared' -TaskDescription 'beta' -OwnerContext $ownerB
      Save-RaymanSessionManifest -WorkspaceRoot $root -Manifest $alphaManifest | Out-Null
      Save-RaymanSessionManifest -WorkspaceRoot $root -Manifest $betaManifest | Out-Null

      Set-RaymanActiveSession -WorkspaceRoot $root -Manifest $alphaManifest -OwnerContext $ownerA
      Set-RaymanActiveSession -WorkspaceRoot $root -Manifest $betaManifest -OwnerContext $ownerB

      (Get-RaymanActiveSession -WorkspaceRoot $root -OwnerContext $ownerA).slug | Should -Be 'alpha'
      (Get-RaymanActiveSession -WorkspaceRoot $root -OwnerContext $ownerB).slug | Should -Be 'beta'
      (Get-RaymanActiveSession -WorkspaceRoot $root -OwnerContext $ownerC).slug | Should -Be 'beta'
      [string](Resolve-RaymanAutoSaveTargetPaths -WorkspaceRoot $root -OwnerContext $ownerA).auto_save_patch_path | Should -Match 'sessions[\\/]+alpha[\\/]+auto_save\.patch$'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'keeps named sessions visible across Codex account switches in the same workspace' {
    $root = New-StateSessionTestRoot
    $accountBackup = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_ACCOUNT_ALIAS')
    try {
      Initialize-StateSessionGitRoot -Root $root
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_ACCOUNT_ALIAS', 'alpha')
      Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Encoding UTF8 -Value 'alpha change'
      & $script:SaveStateScript -WorkspaceRoot $root -Name 'Alpha' -TaskDescription 'alpha task' | Out-Null

      $alphaList = & $script:ListStateScript -WorkspaceRoot $root -Json | ConvertFrom-Json
      $alphaList.sessions[0].backend | Should -Be 'codex'
      $alphaList.sessions[0].account_alias | Should -Be 'alpha'

      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_ACCOUNT_ALIAS', 'beta')
      $betaList = & $script:ListStateScript -WorkspaceRoot $root -Json | ConvertFrom-Json
      $betaList.count | Should -Be 1
      $betaList.sessions[0].name | Should -Be 'Alpha'
      & $script:ResumeStateScript -WorkspaceRoot $root -Name 'Alpha' | Out-Null

      $updatedManifest = Read-RaymanSessionJsonOrNull -Path (Join-Path $root '.Rayman\state\sessions\alpha\session.json')
      [string]$updatedManifest.account_alias | Should -Be 'beta'
      [string]$updatedManifest.backend | Should -Be 'codex'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_ACCOUNT_ALIAS', $accountBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'summarizes paused codex saved states per alias without mixing local backend sessions' {
    $root = New-StateSessionTestRoot
    try {
      $ownerA = New-StateSessionOwnerContext -Root $root -Token '111'
      $alphaManual = New-RaymanSessionManifest -WorkspaceRoot $root -Name 'Alpha Manual' -Slug 'alpha-manual' -Status 'paused' -Isolation 'shared' -TaskDescription 'alpha manual' -SessionKind 'manual' -Backend 'codex' -AccountAlias 'alpha' -OwnerContext $ownerA
      $alphaAuto = New-RaymanSessionManifest -WorkspaceRoot $root -Name 'Alpha Auto' -Slug 'alpha-auto' -Status 'paused' -Isolation 'shared' -TaskDescription 'alpha auto' -SessionKind 'auto_temp' -Backend 'codex' -AccountAlias 'alpha' -OwnerContext $ownerA
      $betaManual = New-RaymanSessionManifest -WorkspaceRoot $root -Name 'Beta Manual' -Slug 'beta-manual' -Status 'paused' -Isolation 'shared' -TaskDescription 'beta manual' -SessionKind 'manual' -Backend 'codex' -AccountAlias 'beta' -OwnerContext $ownerA
      $localManual = New-RaymanSessionManifest -WorkspaceRoot $root -Name 'Local Manual' -Slug 'local-manual' -Status 'paused' -Isolation 'shared' -TaskDescription 'local manual' -SessionKind 'manual' -Backend 'local' -OwnerContext $ownerA
      Save-RaymanSessionManifest -WorkspaceRoot $root -Manifest $alphaManual | Out-Null
      Start-Sleep -Milliseconds 50
      Save-RaymanSessionManifest -WorkspaceRoot $root -Manifest $alphaAuto | Out-Null
      Start-Sleep -Milliseconds 50
      Save-RaymanSessionManifest -WorkspaceRoot $root -Manifest $betaManual | Out-Null
      Save-RaymanSessionManifest -WorkspaceRoot $root -Manifest $localManual | Out-Null

      $alphaSummary = Get-RaymanCodexWorkspaceSavedStateSummary -WorkspaceRoot $root -AccountAlias 'alpha'
      $betaSummary = Get-RaymanCodexWorkspaceSavedStateSummary -WorkspaceRoot $root -AccountAlias 'beta'

      [int]$alphaSummary.total_count | Should -Be 2
      [int]$alphaSummary.manual_count | Should -Be 1
      [int]$alphaSummary.auto_temp_count | Should -Be 1
      [string]$alphaSummary.latest.name | Should -Be 'Alpha Auto'
      [int]$betaSummary.total_count | Should -Be 1
      [string]$betaSummary.latest.name | Should -Be 'Beta Manual'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'keeps other aliases visible in saved-state summaries after switching the current Codex account' {
    $root = New-StateSessionTestRoot
    $accountBackup = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_ACCOUNT_ALIAS')
    try {
      Initialize-StateSessionGitRoot -Root $root
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_ACCOUNT_ALIAS', 'alpha')
      & $script:SaveStateScript -WorkspaceRoot $root -Name 'Alpha Manual' -TaskDescription 'alpha task' | Out-Null

      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_ACCOUNT_ALIAS', 'beta')
      & $script:SaveStateScript -WorkspaceRoot $root -Name 'Beta Manual' -TaskDescription 'beta task' | Out-Null

      $alphaSummary = Get-RaymanCodexWorkspaceSavedStateSummary -WorkspaceRoot $root -AccountAlias 'alpha'
      $betaSummary = Get-RaymanCodexWorkspaceSavedStateSummary -WorkspaceRoot $root -AccountAlias 'beta'

      [int]$alphaSummary.total_count | Should -Be 1
      [int]$betaSummary.total_count | Should -Be 1
      [string]$alphaSummary.latest.name | Should -Be 'Alpha Manual'
      [string]$betaSummary.latest.name | Should -Be 'Beta Manual'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_ACCOUNT_ALIAS', $accountBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'keeps auto-save artifacts isolated per active session' {
    $root = New-StateSessionTestRoot
    try {
      Initialize-StateSessionGitRoot -Root $root
      $state = New-RaymanAutoSaveWatchState -WorkspaceRoot $root

      $alphaManifest = New-RaymanSessionManifest -WorkspaceRoot $root -Name 'Alpha' -Slug 'alpha' -Status 'resumed' -Isolation 'shared' -TaskDescription 'alpha'
      Save-RaymanSessionManifest -WorkspaceRoot $root -Manifest $alphaManifest | Out-Null
      Set-RaymanActiveSession -WorkspaceRoot $root -Manifest $alphaManifest
      Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Encoding UTF8 -Value 'alpha autosave'
      Invoke-RaymanAutoSaveCycle -State $state | Out-Null

      $alphaPatch = Join-Path $root '.Rayman\state\sessions\alpha\auto_save.patch'
      Test-Path -LiteralPath $alphaPatch -PathType Leaf | Should -Be $true

      & $script:GitPath -C $root checkout -- notes.txt | Out-Null
      $betaManifest = New-RaymanSessionManifest -WorkspaceRoot $root -Name 'Beta' -Slug 'beta' -Status 'resumed' -Isolation 'shared' -TaskDescription 'beta'
      Save-RaymanSessionManifest -WorkspaceRoot $root -Manifest $betaManifest | Out-Null
      Set-RaymanActiveSession -WorkspaceRoot $root -Manifest $betaManifest
      Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Encoding UTF8 -Value 'beta autosave'
      Invoke-RaymanAutoSaveCycle -State $state | Out-Null

      $betaPatch = Join-Path $root '.Rayman\state\sessions\beta\auto_save.patch'
      Test-Path -LiteralPath $betaPatch -PathType Leaf | Should -Be $true
      (Get-Content -LiteralPath $alphaPatch -Raw -Encoding UTF8) | Should -Match 'alpha autosave'
      (Get-Content -LiteralPath $betaPatch -Raw -Encoding UTF8) | Should -Match 'beta autosave'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'creates an idempotent named worktree session' {
    $root = New-StateSessionTestRoot
    $first = $null
    try {
      Initialize-StateSessionGitRoot -Root $root

      $first = & $script:WorktreeCreateScript -WorkspaceRoot $root -Name 'Alpha' -Json | ConvertFrom-Json
      $second = & $script:WorktreeCreateScript -WorkspaceRoot $root -Name 'Alpha' -Json | ConvertFrom-Json

      $first.schema | Should -Be 'rayman.state.worktree_create.v1'
      $first.created | Should -Be $true
      $first.branch | Should -Be 'codex/session/alpha'
      Test-Path -LiteralPath $first.worktree_path -PathType Container | Should -Be $true
      (& $script:GitPath -C $first.worktree_path rev-parse --abbrev-ref HEAD | Select-Object -First 1).Trim() | Should -Be 'codex/session/alpha'
      $second.created | Should -Be $false
      $second.worktree_path | Should -Be $first.worktree_path
    } finally {
      if ($null -ne $first -and -not [string]::IsNullOrWhiteSpace([string]$first.worktree_path)) {
        & $script:GitPath -C $root worktree remove --force ([string]$first.worktree_path) 2>$null | Out-Null
        Remove-Item -LiteralPath ([string]$first.worktree_path) -Recurse -Force -ErrorAction SilentlyContinue
      }
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'creates an owner-scoped auto-temp session after a long command and exposes its metadata in state-list' {
    $root = New-StateSessionTestRoot
    try {
      Initialize-StateSessionGitRoot -Root $root
      $ownerA = New-StateSessionOwnerContext -Root $root -Token '111'
      Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Encoding UTF8 -Value 'alpha temp change'

      $checkpoint = Invoke-RaymanSessionCommandCheckpoint -WorkspaceRoot $root -DurationMs 400000 -Backend 'codex' -AccountAlias 'alpha' -OwnerContext $ownerA -CommandText 'codex exec test'
      $manifest = Read-RaymanSessionManifest -WorkspaceRoot $root -Slug ([string]$checkpoint.session_slug)
      $list = & $script:ListStateScript -WorkspaceRoot $root -Json | ConvertFrom-Json

      [bool]$checkpoint.checkpointed | Should -Be $true
      [string]$checkpoint.session_kind | Should -Be 'auto_temp'
      [string]$manifest.session_kind | Should -Be 'auto_temp'
      [string]$manifest.backend | Should -Be 'codex'
      [string]$manifest.account_alias | Should -Be 'alpha'
      [string]$manifest.owner_display | Should -Be 'VSCODE_PID#111'
      $patchPath = Join-Path (Join-Path (Join-Path $root '.Rayman\state\sessions') ([string]$checkpoint.session_slug)) 'auto_save.patch'
      (Get-Content -LiteralPath $patchPath -Raw -Encoding UTF8) | Should -Match 'alpha temp change'
      $list.sessions[0].session_kind | Should -Be 'auto_temp'
      $list.sessions[0].backend | Should -Be 'codex'
      $list.sessions[0].account_alias | Should -Be 'alpha'
      $list.sessions[0].owner_display | Should -Be 'VSCODE_PID#111'
      (Get-RaymanActiveSession -WorkspaceRoot $root -OwnerContext $ownerA).slug | Should -Be ([string]$checkpoint.session_slug)
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'reuses the same auto-temp session for repeated checkpoints and keeps other owners intact' {
    $root = New-StateSessionTestRoot
    try {
      Initialize-StateSessionGitRoot -Root $root
      $ownerA = New-StateSessionOwnerContext -Root $root -Token '111'
      $ownerB = New-StateSessionOwnerContext -Root $root -Token '222'

      Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Encoding UTF8 -Value 'alpha temp one'
      $checkpointA1 = Invoke-RaymanSessionCommandCheckpoint -WorkspaceRoot $root -DurationMs 400000 -Backend 'codex' -AccountAlias 'alpha' -OwnerContext $ownerA -CommandText 'codex exec alpha-1'
      $patchAPath = Join-Path (Join-Path (Join-Path $root '.Rayman\state\sessions') ([string]$checkpointA1.session_slug)) 'auto_save.patch'

      & $script:GitPath -C $root checkout -- notes.txt | Out-Null
      Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Encoding UTF8 -Value 'beta temp one'
      $checkpointB = Invoke-RaymanSessionCommandCheckpoint -WorkspaceRoot $root -DurationMs 400000 -Backend 'codex' -AccountAlias 'beta' -OwnerContext $ownerB -CommandText 'codex exec beta-1'
      $patchBPath = Join-Path (Join-Path (Join-Path $root '.Rayman\state\sessions') ([string]$checkpointB.session_slug)) 'auto_save.patch'

      & $script:GitPath -C $root checkout -- notes.txt | Out-Null
      Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Encoding UTF8 -Value 'alpha temp two'
      $checkpointA2 = Invoke-RaymanSessionCommandCheckpoint -WorkspaceRoot $root -DurationMs 400000 -Backend 'codex' -AccountAlias 'alpha' -OwnerContext $ownerA -CommandText 'codex exec alpha-2'
      $records = @(Get-RaymanSessionRecords -WorkspaceRoot $root -All)
      $ownerAAutoTemp = @($records | Where-Object { [string]$_.session_kind -eq 'auto_temp' -and [string]$_.account_alias -eq 'alpha' -and [string]$_.owner_display -eq 'VSCODE_PID#111' })

      [string]$checkpointA1.session_slug | Should -Be ([string]$checkpointA2.session_slug)
      [string]$checkpointA1.session_slug | Should -Not -Be ([string]$checkpointB.session_slug)
      (Get-Content -LiteralPath $patchAPath -Raw -Encoding UTF8) | Should -Match 'alpha temp two'
      (Get-Content -LiteralPath $patchBPath -Raw -Encoding UTF8) | Should -Match 'beta temp one'
      $ownerAAutoTemp.Count | Should -Be 1
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'updates the active manual session instead of creating a separate auto-temp session' {
    $root = New-StateSessionTestRoot
    try {
      Initialize-StateSessionGitRoot -Root $root
      $ownerA = New-StateSessionOwnerContext -Root $root -Token '111'
      $manualManifest = New-RaymanSessionManifest -WorkspaceRoot $root -Name 'Manual' -Slug 'manual' -Status 'resumed' -Isolation 'shared' -TaskDescription 'manual task' -SessionKind 'manual' -Backend 'codex' -AccountAlias 'alpha' -OwnerContext $ownerA
      Save-RaymanSessionManifest -WorkspaceRoot $root -Manifest $manualManifest | Out-Null
      Set-RaymanActiveSession -WorkspaceRoot $root -Manifest $manualManifest -OwnerContext $ownerA

      Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Encoding UTF8 -Value 'manual temp change'
      $checkpoint = Invoke-RaymanSessionCommandCheckpoint -WorkspaceRoot $root -DurationMs 400000 -Backend 'codex' -AccountAlias 'alpha' -OwnerContext $ownerA -CommandText 'codex exec manual'
      $records = @(Get-RaymanSessionRecords -WorkspaceRoot $root -All)

      [string]$checkpoint.session_slug | Should -Be 'manual'
      @($records | Where-Object { [string]$_.session_kind -eq 'auto_temp' }).Count | Should -Be 0
      (Get-Content -LiteralPath (Join-Path $root '.Rayman\state\sessions\manual\auto_save.patch') -Raw -Encoding UTF8) | Should -Match 'manual temp change'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'skips automatic temp checkpoints when the command duration is below threshold' {
    $root = New-StateSessionTestRoot
    try {
      Initialize-StateSessionGitRoot -Root $root
      $ownerA = New-StateSessionOwnerContext -Root $root -Token '111'
      Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Encoding UTF8 -Value 'short run change'

      $checkpoint = Invoke-RaymanSessionCommandCheckpoint -WorkspaceRoot $root -DurationMs 1000 -Backend 'local' -OwnerContext $ownerA -CommandText 'Write-Output short'

      [bool]$checkpoint.checkpointed | Should -Be $false
      [string]$checkpoint.reason | Should -Be 'under_threshold'
      (Test-Path -LiteralPath (Join-Path $root '.Rayman\state\sessions') -PathType Container) | Should -Be $false
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'restores a migrated shared session into its worktree and marks it active' {
    $root = New-StateSessionTestRoot
    $worktree = $null
    try {
      Initialize-StateSessionGitRoot -Root $root

      Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Encoding UTF8 -Value 'shared change'
      & $script:SaveStateScript -WorkspaceRoot $root -Name 'Alpha' -TaskDescription 'alpha task' | Out-Null

      $savedManifest = Read-RaymanSessionJsonOrNull -Path (Join-Path $root '.Rayman\state\sessions\alpha\session.json')
      $worktree = & $script:WorktreeCreateScript -WorkspaceRoot $root -Name 'Alpha' -Json | ConvertFrom-Json
      & $script:ResumeStateScript -WorkspaceRoot $root -Name 'Alpha' -Json | ConvertFrom-Json | Out-Null

      $updatedManifest = Read-RaymanSessionJsonOrNull -Path (Join-Path $root '.Rayman\state\sessions\alpha\session.json')
      $activeSession = Get-RaymanActiveSession -WorkspaceRoot $root
      $stashList = @(& $script:GitPath -C $root stash list --format='%H')

      $savedManifest.stash_oid | Should -Not -BeNullOrEmpty
      $updatedManifest.status | Should -Be 'resumed'
      $updatedManifest.isolation | Should -Be 'worktree'
      [string]$updatedManifest.stash_oid | Should -Be ''
      (Get-Content -LiteralPath (Join-Path $worktree.worktree_path 'notes.txt') -Raw -Encoding UTF8).Trim() | Should -Be 'shared change'
      $activeSession.slug | Should -Be 'alpha'
      $activeSession.isolation | Should -Be 'worktree'
      $activeSession.worktree_path | Should -Be ([string]$worktree.worktree_path)
      $stashList.Count | Should -Be 0
    } finally {
      if ($null -ne $worktree -and -not [string]::IsNullOrWhiteSpace([string]$worktree.worktree_path)) {
        & $script:GitPath -C $root worktree remove --force ([string]$worktree.worktree_path) 2>$null | Out-Null
        Remove-Item -LiteralPath ([string]$worktree.worktree_path) -Recurse -Force -ErrorAction SilentlyContinue
      }
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'surfaces manual and auto-temp sessions through rollback list' {
    $root = New-StateSessionTestRoot
    try {
      Initialize-StateSessionGitRoot -Root $root
      $ownerA = New-StateSessionOwnerContext -Root $root -Token '111'

      Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Encoding UTF8 -Value 'auto temp change'
      Invoke-RaymanSessionCommandCheckpoint -WorkspaceRoot $root -DurationMs 400000 -Backend 'codex' -AccountAlias 'alpha' -OwnerContext $ownerA -CommandText 'codex exec alpha-temp' | Out-Null

      & $script:GitPath -C $root checkout -- notes.txt | Out-Null
      Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Encoding UTF8 -Value 'manual change'
      & $script:SaveStateScript -WorkspaceRoot $root -Name 'Manual Alpha' -TaskDescription 'manual rollback task' | Out-Null

      $list = & $script:RollbackScript -WorkspaceRoot $root -Action list -Json | ConvertFrom-Json
      $kinds = @($list.sessions | ForEach-Object { [string]$_.session_kind })

      $list.schema | Should -Be 'rayman.rollback.list.v1'
      ($kinds -contains 'manual') | Should -Be $true
      ($kinds -contains 'auto_temp') | Should -Be $true
      @($list.sessions | Where-Object { [bool]$_.has_handover }).Count | Should -BeGreaterThan 0
      @($list.sessions | Where-Object { [bool]$_.has_patch }).Count | Should -BeGreaterThan 0
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'renders diff and restores auto-temp checkpoints through rollback' {
    $root = New-StateSessionTestRoot
    try {
      Initialize-StateSessionGitRoot -Root $root
      $ownerA = New-StateSessionOwnerContext -Root $root -Token '111'
      Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Encoding UTF8 -Value 'auto temp restore'

      $checkpoint = Invoke-RaymanSessionCommandCheckpoint -WorkspaceRoot $root -DurationMs 400000 -Backend 'codex' -AccountAlias 'alpha' -OwnerContext $ownerA -CommandText 'codex exec alpha-restore'
      & $script:GitPath -C $root checkout -- notes.txt | Out-Null

      $diff = & $script:RollbackScript -WorkspaceRoot $root -Action diff -Slug ([string]$checkpoint.session_slug) -Json | ConvertFrom-Json
      $restore = & $script:RollbackScript -WorkspaceRoot $root -Action restore -Slug ([string]$checkpoint.session_slug) -Json | ConvertFrom-Json
      $eventTypes = @(Get-StateSessionEventTypes -Root $root)

      $diff.schema | Should -Be 'rayman.rollback.diff.v1'
      [string]$diff.patch.mode | Should -Be 'patch'
      [int]$diff.patch.file_count | Should -BeGreaterThan 0
      $restore.schema | Should -Be 'rayman.rollback.restore.v1'
      $restore.restored | Should -Be $true
      [string]$restore.session_kind | Should -Be 'auto_temp'
      [string]$restore.resume_result.schema | Should -Be 'rayman.state.resume.v1'
      (Get-Content -LiteralPath (Join-Path $root 'notes.txt') -Raw -Encoding UTF8).Trim() | Should -Be 'auto temp restore'
      ($eventTypes -contains 'rollback.restore') | Should -Be $true
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'restores manual checkpoints through rollback without creating archive snapshots' {
    $root = New-StateSessionTestRoot
    try {
      Initialize-StateSessionGitRoot -Root $root
      Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Encoding UTF8 -Value 'manual rollback restore'

      & $script:SaveStateScript -WorkspaceRoot $root -Name 'Manual Restore' -TaskDescription 'manual rollback restore task' | Out-Null
      $restore = & $script:RollbackScript -WorkspaceRoot $root -Action restore -Name 'Manual Restore' -Json | ConvertFrom-Json

      $restore.schema | Should -Be 'rayman.rollback.restore.v1'
      $restore.restored | Should -Be $true
      [string]$restore.session_kind | Should -Be 'manual'
      (Get-Content -LiteralPath (Join-Path $root 'notes.txt') -Raw -Encoding UTF8).Trim() | Should -Be 'manual rollback restore'
      (Test-Path -LiteralPath (Join-Path $root '.Rayman\runtime\snapshots') -PathType Container) | Should -Be $false
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'creates, links, unlinks, and shows canonical shared sessions explicitly' {
    $root = New-StateSessionTestRoot
    try {
      $continueResult = & $script:SharedSessionScript -WorkspaceRoot $root -Action continue -Name 'Alpha Mesh' -Prompt 'shared session prompt' -Json | ConvertFrom-Json
      $targetSessionId = [string]$continueResult.session.session_id
      $showAfterContinue = & $script:SharedSessionScript -WorkspaceRoot $root -Action show -SessionId $targetSessionId -Json | ConvertFrom-Json
      $linkResult = & $script:SharedSessionScript -WorkspaceRoot $root -Action link -SessionId $targetSessionId -Vendor 'copilot-sdk' -VendorSessionId 'sdk-alpha' -ContinuityMode native_resume -NativeResumeSupported -Json | ConvertFrom-Json
      $showAfterLink = & $script:SharedSessionScript -WorkspaceRoot $root -Action show -SessionId $targetSessionId -Json | ConvertFrom-Json
      $unlinkResult = & $script:SharedSessionScript -WorkspaceRoot $root -Action unlink -SessionId $targetSessionId -Vendor 'copilot-sdk' -VendorSessionId 'sdk-alpha' -Json | ConvertFrom-Json
      $list = & $script:SharedSessionScript -WorkspaceRoot $root -Action list -Json | ConvertFrom-Json

      $continueResult.schema | Should -Be 'rayman.shared_session_status.v1'
      [string]$targetSessionId | Should -Match '^ws-[a-f0-9]+-task-alpha-mesh$'
      [string]$showAfterContinue.session.display_name | Should -Be 'Alpha Mesh'
      [string]$showAfterContinue.messages[0].content_text | Should -Be 'shared session prompt'
      $linkResult.schema | Should -Be 'rayman.shared_session_sync.v1'
      @($showAfterLink.links | Where-Object { [string]$_.vendor_name -eq 'copilot-sdk' -and [string]$_.vendor_session_id -eq 'sdk-alpha' }).Count | Should -Be 1
      [int]$unlinkResult.deleted | Should -Be 1
      @($list.sessions | Where-Object { [string]$_.session_id -eq $targetSessionId }).Count | Should -Be 1
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'serializes shared-session locks, queues contention, and recovers stale locks' {
    $root = New-StateSessionTestRoot
    $timeoutBackup = [Environment]::GetEnvironmentVariable('RAYMAN_SHARED_SESSION_LOCK_TIMEOUT_SECONDS')
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_SHARED_SESSION_LOCK_TIMEOUT_SECONDS', '1')
      $session = Ensure-RaymanSharedSession -WorkspaceRoot $root -TaskSlug 'lock-demo' -DisplayName 'Lock Demo' -SummaryText 'lock demo' -IgnoreDisabled
      $sessionId = [string]$session.session.session_id

      $lockA = Enter-RaymanSharedSessionLock -WorkspaceRoot $root -SessionId $sessionId -OwnerId 'owner-a' -OwnerLabel 'Owner A' -QueueItem @{ prompt = 'first queued item' }
      $lockB = Enter-RaymanSharedSessionLock -WorkspaceRoot $root -SessionId $sessionId -OwnerId 'owner-b' -OwnerLabel 'Owner B' -QueueItem @{ prompt = 'second queued item' }
      Start-Sleep -Milliseconds 1200
      $lockRecovered = Enter-RaymanSharedSessionLock -WorkspaceRoot $root -SessionId $sessionId -OwnerId 'owner-b' -OwnerLabel 'Owner B'
      $show = Get-RaymanSharedSessionShow -WorkspaceRoot $root -SessionId $sessionId -MessageLimit 20

      [bool]$lockA.acquired | Should -Be $true
      [bool]$lockB.acquired | Should -Be $false
      [bool]$lockB.queued | Should -Be $true
      [int]$lockB.queued_count | Should -Be 1
      [bool]$lockRecovered.acquired | Should -Be $true
      [bool]$lockRecovered.stale_recovered | Should -Be $true
      [int]$show.lock.queued_count | Should -Be 0
      [string]$show.lock.owner_id | Should -Be 'owner-b'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_SHARED_SESSION_LOCK_TIMEOUT_SECONDS', $timeoutBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'syncs state save, resume, and rollback into canonical shared sessions when enabled' {
    $root = New-StateSessionTestRoot
    $enabledBackup = [Environment]::GetEnvironmentVariable('RAYMAN_SHARED_SESSION_ENABLED')
    try {
      Initialize-StateSessionGitRoot -Root $root
      [Environment]::SetEnvironmentVariable('RAYMAN_SHARED_SESSION_ENABLED', '1')
      Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Encoding UTF8 -Value 'shared state save'

      & $script:SaveStateScript -WorkspaceRoot $root -Name 'Shared Alpha' -TaskDescription 'shared alpha task' | Out-Null
      & $script:ResumeStateScript -WorkspaceRoot $root -Name 'Shared Alpha' -Json | ConvertFrom-Json | Out-Null
      $restore = & $script:RollbackScript -WorkspaceRoot $root -Action restore -Name 'Shared Alpha' -Json | ConvertFrom-Json
      $show = & $script:SharedSessionScript -WorkspaceRoot $root -Action show -Name 'Shared Alpha' -Json | ConvertFrom-Json
      $messageSources = @($show.messages | ForEach-Object { [string]$_.source_kind })

      [string]$show.session.session_id | Should -Match '^ws-[a-f0-9]+-task-shared-alpha$'
      ($messageSources -contains 'state-save') | Should -Be $true
      ($messageSources -contains 'state-resume') | Should -Be $true
      @($show.checkpoints | Where-Object { [string]$_.checkpoint_kind -eq 'state-save' }).Count | Should -BeGreaterThan 0
      [bool]$restore.shared_session_restore.restored | Should -Be $true
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_SHARED_SESSION_ENABLED', $enabledBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
