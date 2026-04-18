Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  $script:ManageMemory = Join-Path $script:WorkspaceRoot '.Rayman\scripts\memory\manage_memory.ps1'
  $script:ManageMemoryPy = Join-Path $script:WorkspaceRoot '.Rayman\scripts\memory\manage_memory.py'
  $script:RepairScript = Join-Path $script:WorkspaceRoot '.Rayman\scripts\repair\run_tests_and_fix.ps1'
  $script:SaveStateScript = Join-Path $script:WorkspaceRoot '.Rayman\scripts\state\save_state.ps1'
  $script:ResumeStateScript = Join-Path $script:WorkspaceRoot '.Rayman\scripts\state\resume_state.ps1'
  $script:RuntimeTemp = Join-Path $script:WorkspaceRoot '.Rayman\runtime\memory\test-fixtures'
  $script:GitPath = (Get-Command git -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1)
  $script:PowerShellCmd = @(
    (Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
    (Get-Command powershell -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
    (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1)
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
  $script:PythonCmd = if (Test-Path -LiteralPath (Join-Path $script:WorkspaceRoot '.venv\Scripts\python.exe') -PathType Leaf) {
    (Join-Path $script:WorkspaceRoot '.venv\Scripts\python.exe')
  } else {
    'python'
  }
  if (-not (Test-Path -LiteralPath $script:RuntimeTemp -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $script:RuntimeTemp | Out-Null
  }
}

function script:New-AgentMemoryTestRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_agent_memory_' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  return $root
}

function script:Initialize-AgentMemoryGitRoot {
  param([string]$Root)

  & $script:GitPath -C $Root init | Out-Null
  & $script:GitPath -C $Root config user.email 'rayman@example.test' | Out-Null
  & $script:GitPath -C $Root config user.name 'Rayman Tests' | Out-Null
  Set-Content -LiteralPath (Join-Path $Root 'notes.txt') -Encoding UTF8 -Value 'base'
  & $script:GitPath -C $Root add notes.txt | Out-Null
  & $script:GitPath -C $Root commit -m 'base' | Out-Null
}

function script:Get-AgentMemoryEventTypes {
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

Describe 'agent memory' {
  It 'emits a valid status payload' {
    $result = & $script:ManageMemory -WorkspaceRoot $script:WorkspaceRoot -Action status -Json | ConvertFrom-Json

    $result.schema | Should -Be 'rayman.agent_memory.status.v1'
    $result.success | Should -Be $true
    [string]::IsNullOrWhiteSpace([string]$result.status_path) | Should -Be $false
    [string]$result.session_search_backend | Should -Match '^(fts5|lexical)$'
    ($result.counts.PSObject.Properties.Name -contains 'session_recalls') | Should -Be $true
  }

  It 'ships Agent Memory schemas and fixtures into the contract validator' {
    $validatorRaw = Get-Content -LiteralPath (Join-Path $script:WorkspaceRoot '.Rayman\scripts\testing\validate_json_contracts.py') -Raw -Encoding UTF8
    $paths = @(
      '.Rayman\scripts\testing\schemas\agent_memory_status.v1.schema.json',
      '.Rayman\scripts\testing\schemas\agent_memory_search_result.v1.schema.json',
      '.Rayman\scripts\testing\schemas\agent_memory_summarize_result.v1.schema.json',
      '.Rayman\scripts\testing\fixtures\reports\agent_memory.status.sample.json',
      '.Rayman\scripts\testing\fixtures\reports\agent_memory.search.sample.json',
      '.Rayman\scripts\testing\fixtures\reports\agent_memory.summarize.sample.json'
    )

    foreach ($relativePath in $paths) {
      Test-Path -LiteralPath (Join-Path $script:WorkspaceRoot $relativePath) | Should -Be $true
    }

    $validatorRaw | Should -Match 'agent_memory_status'
    $validatorRaw | Should -Match 'agent_memory_search_result'
    $validatorRaw | Should -Match 'agent_memory_summarize_result'
  }

  It 'replaces legacy memory wording in the repair summary template' {
    $raw = Get-Content -LiteralPath $script:RepairScript -Raw -Encoding UTF8

    $raw | Should -Match 'Agent Memory'
    $raw | Should -Not -Match ('## 🧠 R' + 'AG')
    $raw | Should -Not -Match ('含 ' + 'R' + 'AG')
    $raw | Should -Not -Match ('R' + 'AG 记忆库')
  }

  It 'removes legacy vector-db tokens from maintenance scripts and stale setup flags from copy smoke' {
    $snapshotPs = Get-Content -LiteralPath (Join-Path $script:WorkspaceRoot '.Rayman\scripts\backup\snapshot_workspace.ps1') -Raw -Encoding UTF8
    $snapshotSh = Get-Content -LiteralPath (Join-Path $script:WorkspaceRoot '.Rayman\scripts\backup\snapshot_workspace.sh') -Raw -Encoding UTF8
    $copySmoke = Get-Content -LiteralPath (Join-Path $script:WorkspaceRoot '.Rayman\scripts\release\copy_smoke.ps1') -Raw -Encoding UTF8
    $trackedNoise = Get-Content -LiteralPath (Join-Path $script:WorkspaceRoot '.Rayman\scripts\release\contract_scm_tracked_noise.sh') -Raw -Encoding UTF8

    $snapshotPs | Should -Match '\.Rayman/state/memory'
    $snapshotSh | Should -Match '\.Rayman/state/memory'
    $snapshotPs | Should -Not -Match ('chroma' + '_' + 'db')
    $snapshotSh | Should -Not -Match ('chroma' + '_' + 'db')
    $snapshotPs | Should -Not -Match ('rag' + '\.db')
    $snapshotSh | Should -Not -Match ('rag' + '\.db')
    $copySmoke | Should -Not -Match ('NoAutoMigrate' + 'Legacy' + 'Rag')
    $trackedNoise | Should -Not -Match ('NoAutoMigrate' + 'Legacy' + 'Rag')
  }

  It 'indexes session recall payloads into unified recall search results' {
    $root = New-AgentMemoryTestRoot
    $payloadPath = Join-Path $root 'session-refresh.json'
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\state\sessions\alpha') | Out-Null
      $payload = [ordered]@{
        session_slug = 'alpha'
        session_name = 'Alpha'
        session_kind = 'manual'
        status = 'paused'
        backend = 'codex'
        account_alias = 'alpha'
        owner_display = 'VSCODE_PID#111'
        owner_key = 'VSCODE_PID:111:test-workspace'
        task_description = 'Investigate rollback telemetry'
        summary_text = 'Rollback restore kept snapshot semantics unchanged.'
        handover_path = ''
        patch_path = ''
        meta_path = ''
        stash_oid = ''
        worktree_path = ''
        branch = ''
        created_at = '2026-04-16T09:00:00Z'
        updated_at = '2026-04-16T09:05:00Z'
      }
      $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $payloadPath -Encoding UTF8

      $refresh = & $script:ManageMemory -WorkspaceRoot $root -Action session-refresh -InputJsonFile $payloadPath -Json | ConvertFrom-Json
      $status = & $script:ManageMemory -WorkspaceRoot $root -Action status -Json | ConvertFrom-Json
      $search = & $script:ManageMemory -WorkspaceRoot $root -Action search -Query 'alpha rollback VSCODE_PID' -Scope all -Json | ConvertFrom-Json

      $refresh.schema | Should -Be 'rayman.agent_memory.session_refresh.v1'
      [string]$refresh.search_backend | Should -Match '^(fts5|lexical)$'
      [int]$status.counts.session_recalls | Should -Be 1
      [string]$status.session_search_backend | Should -Match '^(fts5|lexical)$'
      @($search.session_recalls).Count | Should -BeGreaterThan 0
      [string]$search.session_search_backend | Should -Match '^(fts5|lexical)$'
      [string]$search.session_recalls[0].source_kind | Should -Be 'session_manual'
      @($search.recall_results | Where-Object { [string]$_.source_kind -eq 'session_manual' }).Count | Should -BeGreaterThan 0
      [string]$search.session_recalls[0].account_alias | Should -Be 'alpha'
      [string]$search.session_recalls[0].owner_display | Should -Be 'VSCODE_PID#111'
    } finally {
      Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'refreshes searchable recall from state flows and emits memory events' {
    if ([string]::IsNullOrWhiteSpace([string]$script:GitPath)) {
      Set-ItResult -Skipped -Because 'git not found'
      return
    }

    $root = New-AgentMemoryTestRoot
    $aliasBackup = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_ACCOUNT_ALIAS')
    try {
      Initialize-AgentMemoryGitRoot -Root $root
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_ACCOUNT_ALIAS', 'alpha')
      Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Encoding UTF8 -Value 'alpha saved state'

      & $script:SaveStateScript -WorkspaceRoot $root -Name 'Alpha Recall' -TaskDescription 'alpha rollback investigation' | Out-Null
      & $script:ResumeStateScript -WorkspaceRoot $root -Name 'Alpha Recall' -Json | ConvertFrom-Json | Out-Null
      $search = & $script:ManageMemory -WorkspaceRoot $root -Action search -Query 'alpha rollback investigation' -Scope all -Json | ConvertFrom-Json
      $summary = & $script:ManageMemory -WorkspaceRoot $root -Action summarize -TaskKey 'handover/alpha' -DrainPending -Json | ConvertFrom-Json
      $eventTypes = @(Get-AgentMemoryEventTypes -Root $root)

      @($search.session_recalls | Where-Object { [string]$_.session_name -eq 'Alpha Recall' }).Count | Should -BeGreaterThan 0
      [string]$search.session_recalls[0].source_kind | Should -Match '^session_'
      $summary.schema | Should -Be 'rayman.agent_memory.summarize_result.v1'
      ($eventTypes -contains 'memory.session_refresh') | Should -Be $true
      ($eventTypes -contains 'memory.search') | Should -Be $true
      ($eventTypes -contains 'memory.summarize') | Should -Be $true
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_ACCOUNT_ALIAS', $aliasBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
