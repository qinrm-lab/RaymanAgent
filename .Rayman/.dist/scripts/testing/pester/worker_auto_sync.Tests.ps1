BeforeAll {
  $script:WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  . (Join-Path $script:WorkspaceRoot '.Rayman\scripts\watch\worker_auto_sync.ps1') -NoMain

  function script:New-TestWorkerAutoSyncRoot {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_auto_sync_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null
    Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
    return $root
  }
}

Describe 'worker auto sync watcher' {
  BeforeEach {
    $script:autoSyncEnvBackup = @{}
    foreach ($name in @(
        'RAYMAN_WORKER_AUTO_SYNC_ENABLED',
        'RAYMAN_WORKER_AUTO_SYNC_POLL_MS',
        'RAYMAN_WORKER_AUTO_SYNC_DEBOUNCE_SECONDS',
        'RAYMAN_WORKER_AUTO_SYNC_RETRY_SECONDS'
      )) {
      $script:autoSyncEnvBackup[$name] = [Environment]::GetEnvironmentVariable($name)
      [Environment]::SetEnvironmentVariable($name, $null)
    }

    [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTO_SYNC_ENABLED', '1')

    Mock Get-RaymanWorkerSyncFingerprintInfo { throw 'unexpected fingerprint request' }
    Mock Get-RaymanWorkerLiveStatus { throw 'unexpected live status request' }
    Mock Invoke-RaymanWorkerSyncAction { throw 'unexpected sync request' }
  }

  AfterEach {
    foreach ($entry in $script:autoSyncEnvBackup.GetEnumerator()) {
      [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value)
    }
  }

  It 'records no_active_worker when no worker is selected' {
    $root = New-TestWorkerAutoSyncRoot
    try {
      $state = New-RaymanWorkerAutoSyncState -WorkspaceRoot $root
      Mock Get-RaymanWorkerActiveExecutionContext { return $null }

      $result = Invoke-RaymanWorkerAutoSyncCycle -State $state
      $status = Get-Content -LiteralPath (Get-RaymanWorkerAutoSyncStatusPath -WorkspaceRoot $root) -Raw -Encoding UTF8 | ConvertFrom-Json

      $result.status | Should -Be 'no_active_worker'
      $status.status | Should -Be 'no_active_worker'
      Assert-MockCalled Get-RaymanWorkerActiveExecutionContext -Times 1 -Exactly -Scope It
      Assert-MockCalled Invoke-RaymanWorkerSyncAction -Times 0 -Scope It
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'waits until the active worker is in staged mode' {
    $root = New-TestWorkerAutoSyncRoot
    try {
      $state = New-RaymanWorkerAutoSyncState -WorkspaceRoot $root
      $context = [pscustomobject]@{
        worker = [pscustomobject]@{ worker_id = 'worker-a'; control_url = 'http://127.0.0.1:47632/' }
        active = [pscustomobject]@{
          worker_id = 'worker-a'
          workspace_mode = 'attached'
        }
      }
      Mock Get-RaymanWorkerActiveExecutionContext { return $context }

      $result = Invoke-RaymanWorkerAutoSyncCycle -State $state
      $status = Get-Content -LiteralPath (Get-RaymanWorkerAutoSyncStatusPath -WorkspaceRoot $root) -Raw -Encoding UTF8 | ConvertFrom-Json

      $result.status | Should -Be 'waiting_for_staged'
      $status.status | Should -Be 'waiting_for_staged'
      $status.worker_id | Should -Be 'worker-a'
      $status.mode | Should -Be 'attached'
      Assert-MockCalled Get-RaymanWorkerSyncFingerprintInfo -Times 0 -Scope It
      Assert-MockCalled Invoke-RaymanWorkerSyncAction -Times 0 -Scope It
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'stays idle when the staged fingerprint already matches the active worker baseline' {
    $root = New-TestWorkerAutoSyncRoot
    try {
      $state = New-RaymanWorkerAutoSyncState -WorkspaceRoot $root
      $context = [pscustomobject]@{
        worker = [pscustomobject]@{ worker_id = 'worker-a'; control_url = 'http://127.0.0.1:47632/' }
        active = [pscustomobject]@{
          worker_id = 'worker-a'
          workspace_mode = 'staged'
          sync_manifest = [pscustomobject]@{
            source_fingerprint = 'fp-same'
            generated_at = '2026-03-28T10:00:00.0000000+08:00'
          }
        }
      }
      Mock Get-RaymanWorkerActiveExecutionContext { return $context }
      Mock Get-RaymanWorkerSyncFingerprintInfo {
        [pscustomobject]@{
          fingerprint = 'fp-same'
          file_count = 1
          entries = @([pscustomobject]@{ relative = 'src/app.txt' })
        }
      }

      $result = Invoke-RaymanWorkerAutoSyncCycle -State $state
      $status = Get-Content -LiteralPath (Get-RaymanWorkerAutoSyncStatusPath -WorkspaceRoot $root) -Raw -Encoding UTF8 | ConvertFrom-Json

      $result.status | Should -Be 'idle'
      $status.status | Should -Be 'idle'
      $status.fingerprint | Should -Be 'fp-same'
      $status.last_success_fingerprint | Should -Be 'fp-same'
      Assert-MockCalled Invoke-RaymanWorkerSyncAction -Times 0 -Scope It
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'stays idle on the first cycle when a staged worker has no fingerprint baseline yet' {
    $root = New-TestWorkerAutoSyncRoot
    try {
      $state = New-RaymanWorkerAutoSyncState -WorkspaceRoot $root
      $context = [pscustomobject]@{
        worker = [pscustomobject]@{ worker_id = 'worker-a'; control_url = 'http://127.0.0.1:47632/' }
        active = [pscustomobject]@{
          worker_id = 'worker-a'
          workspace_mode = 'staged'
          sync_manifest = [pscustomobject]@{
            mode = 'staged'
            staging_root = 'C:\stage\existing'
          }
        }
      }
      Mock Get-RaymanWorkerActiveExecutionContext { return $context }
      Mock Get-RaymanWorkerSyncFingerprintInfo {
        [pscustomobject]@{
          fingerprint = 'fp-legacy'
          file_count = 1
          entries = @([pscustomobject]@{ relative = 'src/app.txt' })
        }
      }

      $result = Invoke-RaymanWorkerAutoSyncCycle -State $state
      $status = Get-Content -LiteralPath (Get-RaymanWorkerAutoSyncStatusPath -WorkspaceRoot $root) -Raw -Encoding UTF8 | ConvertFrom-Json

      $result.status | Should -Be 'idle'
      $status.status | Should -Be 'idle'
      $status.fingerprint | Should -Be 'fp-legacy'
      Assert-MockCalled Invoke-RaymanWorkerSyncAction -Times 0 -Scope It
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'classifies auth and connectivity precondition failures distinctly' {
    (Get-RaymanWorkerAutoSyncPreconditionStatus -Message 'worker auth token is invalid') | Should -Be 'worker_auth_failed'
    (Get-RaymanWorkerAutoSyncPreconditionStatus -Message 'The operation has timed out.') | Should -Be 'worker_unreachable'
    (Get-RaymanWorkerAutoSyncPreconditionStatus -Message 'worker control endpoint is incomplete') | Should -Be 'worker_status_unavailable'
  }

  It 'syncs immediately and writes success status when debounce is disabled' {
    $root = New-TestWorkerAutoSyncRoot
    [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTO_SYNC_DEBOUNCE_SECONDS', '0')
    try {
      $state = New-RaymanWorkerAutoSyncState -WorkspaceRoot $root
      $context = [pscustomobject]@{
        worker = [pscustomobject]@{ worker_id = 'worker-a'; control_url = 'http://127.0.0.1:47632/' }
        active = [pscustomobject]@{
          worker_id = 'worker-a'
          workspace_mode = 'staged'
          sync_manifest = [pscustomobject]@{
            source_fingerprint = 'fp-old'
            generated_at = '2026-03-28T10:00:00.0000000+08:00'
          }
        }
      }
      Mock Get-RaymanWorkerActiveExecutionContext { return $context }
      Mock Get-RaymanWorkerSyncFingerprintInfo {
        [pscustomobject]@{
          fingerprint = 'fp-sync'
          file_count = 2
          entries = @(
            [pscustomobject]@{ relative = 'notes/local.txt' },
            [pscustomobject]@{ relative = 'src/app.txt' }
          )
        }
      }
      Mock Get-RaymanWorkerLiveStatus { return [pscustomobject]@{ worker_id = 'worker-a' } }
      Mock Invoke-RaymanWorkerSyncAction {
        [pscustomobject]@{
          bundle = [pscustomobject]@{ bundle_id = 'bundle-123' }
          sync_manifest = [pscustomobject]@{ staging_root = 'C:\stage\bundle-123' }
        }
      }

      $result = Invoke-RaymanWorkerAutoSyncCycle -State $state
      $status = Get-Content -LiteralPath (Get-RaymanWorkerAutoSyncStatusPath -WorkspaceRoot $root) -Raw -Encoding UTF8 | ConvertFrom-Json

      $result.status | Should -Be 'success'
      $status.status | Should -Be 'success'
      $status.worker_id | Should -Be 'worker-a'
      $status.mode | Should -Be 'staged'
      $status.fingerprint | Should -Be 'fp-sync'
      $status.last_success_fingerprint | Should -Be 'fp-sync'
      $status.bundle_id | Should -Be 'bundle-123'
      $status.staging_root | Should -Be 'C:\stage\bundle-123'
      [string]$status.last_attempt_at | Should -Not -BeNullOrEmpty
      [string]$status.last_success_at | Should -Not -BeNullOrEmpty
      Assert-MockCalled Get-RaymanWorkerLiveStatus -Times 1 -Exactly -Scope It
      Assert-MockCalled Invoke-RaymanWorkerSyncAction -Times 1 -Exactly -Scope It
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'keeps one pending sync for consecutive edits and retries after failures' {
    $root = New-TestWorkerAutoSyncRoot
    [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTO_SYNC_DEBOUNCE_SECONDS', '5')
    [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTO_SYNC_RETRY_SECONDS', '30')
    try {
      $state = New-RaymanWorkerAutoSyncState -WorkspaceRoot $root
      $context = [pscustomobject]@{
        worker = [pscustomobject]@{ worker_id = 'worker-a'; control_url = 'http://127.0.0.1:47632/' }
        active = [pscustomobject]@{
          worker_id = 'worker-a'
          workspace_mode = 'staged'
          sync_manifest = [pscustomobject]@{
            source_fingerprint = 'fp-initial'
            generated_at = '2026-03-28T10:00:00.0000000+08:00'
          }
        }
      }
      $fingerprints = [System.Collections.Queue]::new()
      foreach ($value in @('fp-a', 'fp-b', 'fp-b', 'fp-b')) {
        $fingerprints.Enqueue($value)
      }

      Mock Get-RaymanWorkerActiveExecutionContext { return $context }
      Mock Get-RaymanWorkerSyncFingerprintInfo {
        $current = [string]$fingerprints.Dequeue()
        [pscustomobject]@{
          fingerprint = $current
          file_count = 1
          entries = @([pscustomobject]@{ relative = 'src/app.txt' })
        }
      }
      Mock Get-RaymanWorkerLiveStatus { throw 'worker offline' }
      Mock Invoke-RaymanWorkerSyncAction {
        [pscustomobject]@{
          bundle = [pscustomobject]@{ bundle_id = 'bundle-merged' }
          sync_manifest = [pscustomobject]@{ staging_root = 'C:\stage\bundle-merged' }
        }
      }

      (Invoke-RaymanWorkerAutoSyncCycle -State $state).status | Should -Be 'debouncing'
      (Invoke-RaymanWorkerAutoSyncCycle -State $state).status | Should -Be 'debouncing'
      $state.PendingFingerprint | Should -Be 'fp-b'

      $state.PendingSince = (Get-Date).AddSeconds(-10)
      $retryResult = Invoke-RaymanWorkerAutoSyncCycle -State $state
      $retryStatus = Get-Content -LiteralPath (Get-RaymanWorkerAutoSyncStatusPath -WorkspaceRoot $root) -Raw -Encoding UTF8 | ConvertFrom-Json

      $retryResult.status | Should -Be 'worker_unreachable'
      $retryStatus.status | Should -Be 'worker_unreachable'
      $retryStatus.error | Should -Match 'worker offline'
      $state.PendingFingerprint | Should -Be 'fp-b'
      $state.CooldownUntil | Should -Not -Be $null
      Assert-MockCalled Get-RaymanWorkerLiveStatus -Times 1 -Exactly -Scope It

      Mock Get-RaymanWorkerLiveStatus { return [pscustomobject]@{ worker_id = 'worker-a' } }
      $state.CooldownUntil = (Get-Date).AddSeconds(-1)
      $state.PendingSince = (Get-Date).AddSeconds(-10)

      $successResult = Invoke-RaymanWorkerAutoSyncCycle -State $state
      $successStatus = Get-Content -LiteralPath (Get-RaymanWorkerAutoSyncStatusPath -WorkspaceRoot $root) -Raw -Encoding UTF8 | ConvertFrom-Json

      $successResult.status | Should -Be 'success'
      $successStatus.status | Should -Be 'success'
      $successStatus.last_success_fingerprint | Should -Be 'fp-b'
      [string]$state.PendingFingerprint | Should -Be ''
      Assert-MockCalled Invoke-RaymanWorkerSyncAction -Times 1 -Exactly -Scope It
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'uses retry_wait only after the worker is reachable but sync itself fails' {
    $root = New-TestWorkerAutoSyncRoot
    [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTO_SYNC_DEBOUNCE_SECONDS', '0')
    try {
      $state = New-RaymanWorkerAutoSyncState -WorkspaceRoot $root
      $context = [pscustomobject]@{
        worker = [pscustomobject]@{ worker_id = 'worker-a'; control_url = 'http://127.0.0.1:47632/' }
        active = [pscustomobject]@{
          worker_id = 'worker-a'
          workspace_mode = 'staged'
          sync_manifest = [pscustomobject]@{
            source_fingerprint = 'fp-old'
            generated_at = '2026-03-28T10:00:00.0000000+08:00'
          }
        }
      }
      Mock Get-RaymanWorkerActiveExecutionContext { return $context }
      Mock Get-RaymanWorkerSyncFingerprintInfo {
        [pscustomobject]@{
          fingerprint = 'fp-sync-fail'
          file_count = 1
          entries = @([pscustomobject]@{ relative = 'src/app.txt' })
        }
      }
      Mock Get-RaymanWorkerLiveStatus { return [pscustomobject]@{ worker_id = 'worker-a' } }
      Mock Invoke-RaymanWorkerSyncAction { throw 'upload failed' }

      $result = Invoke-RaymanWorkerAutoSyncCycle -State $state
      $status = Get-Content -LiteralPath (Get-RaymanWorkerAutoSyncStatusPath -WorkspaceRoot $root) -Raw -Encoding UTF8 | ConvertFrom-Json

      $result.status | Should -Be 'retry_wait'
      $status.status | Should -Be 'retry_wait'
      $status.error | Should -Match 'upload failed'
      Assert-MockCalled Get-RaymanWorkerLiveStatus -Times 1 -Exactly -Scope It
      Assert-MockCalled Invoke-RaymanWorkerSyncAction -Times 1 -Exactly -Scope It
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
