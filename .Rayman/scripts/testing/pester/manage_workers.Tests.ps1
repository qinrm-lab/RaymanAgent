BeforeAll {
  $script:WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  . (Join-Path $script:WorkspaceRoot '.Rayman\scripts\worker\manage_workers.ps1') -NoMain

  function script:Initialize-TestRaymanWorkerExportWorkspace {
    param([string]$Root)

    foreach ($path in @(
        (Join-Path $Root '.Rayman'),
        (Join-Path $Root '.Rayman\scripts\worker'),
        (Join-Path $Root '.Rayman\templates\worker-package-root'),
        (Join-Path $Root '.Rayman\templates\worker-package-root\download'),
        (Join-Path $Root '.Rayman\templates\worker-package-root\download\vsdbg'),
        (Join-Path $Root '.Rayman\templates\worker-package-root\download\powershell7'),
        (Join-Path $Root '.Rayman\state\worker-package-cache\vsdbg'),
        (Join-Path $Root '.Rayman\state\workers\fixture-state'),
        (Join-Path $Root '.Rayman\runtime\workers'),
        (Join-Path $Root '.Rayman\runtime\worker\logs'),
        (Join-Path $Root '.Rayman\temp\fixture-temp')
      )) {
      New-Item -ItemType Directory -Force -Path $path | Out-Null
    }

    Set-Content -LiteralPath (Join-Path $Root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\scripts\worker\worker_host.ps1') -Encoding UTF8 -Value 'Write-Output ''worker host'''
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\runtime\worker\logs\stale.log') -Encoding UTF8 -Value 'stale log'
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\state\workers\fixture-state\worker.txt') -Encoding UTF8 -Value 'state'
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\temp\fixture-temp\note.txt') -Encoding UTF8 -Value 'temp'
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\templates\worker-package-root\all.ps1') -Encoding UTF8 -Value 'Write-Output ''all workflow'''
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\templates\worker-package-root\all.bat') -Encoding ASCII -Value '@echo off'
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\templates\worker-package-root\collect-worker-diag.ps1') -Encoding UTF8 -Value 'Write-Output ''collect diag'''
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\templates\worker-package-root\collect-worker-diag.bat') -Encoding ASCII -Value '@echo off'
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\templates\worker-package-root\repair-worker-encoding.ps1') -Encoding UTF8 -Value 'Write-Output ''repair encoding'''
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\templates\worker-package-root\repair-worker-encoding.bat') -Encoding ASCII -Value '@echo off'
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\templates\worker-package-root\download\README.txt') -Encoding UTF8 -Value 'download root'
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\templates\worker-package-root\download\vsdbg\README.txt') -Encoding UTF8 -Value 'vsdbg placeholder'
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\templates\worker-package-root\download\powershell7\README.txt') -Encoding UTF8 -Value 'pwsh placeholder'
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\state\worker-package-cache\vsdbg\vsdbg.exe') -Encoding UTF8 -Value 'vsdbg-binary'
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\state\worker-package-cache\vsdbg\helper.txt') -Encoding UTF8 -Value 'helper'
  }
}

Describe 'worker manage helpers' {
  It 'preserves spaced paths and quoted args for worker exec commands' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman worker manage ' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $scriptPath = Join-Path $root 'echo args.ps1'
      Set-Content -LiteralPath $scriptPath -Encoding UTF8 -Value @'
param([string]$WorkspaceRoot, [string]$Label)
Write-Output $WorkspaceRoot
Write-Output $Label
'@

      $commandText = Format-RaymanWorkerCommandText -CommandParts @($scriptPath, '-WorkspaceRoot', $root, '-Label', "O'Brien")
      $psHost = Resolve-RaymanPowerShellHost
      $output = @(& $psHost -NoProfile -ExecutionPolicy Bypass -Command $commandText 2>&1 | ForEach-Object { [string]$_ })

      $LASTEXITCODE | Should -Be 0
      $output | Should -Contain $root
      $output | Should -Contain "O'Brien"
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'uses an encoded command for scheduled task registration' {
    $scriptPath = 'C:\Users\Test User\My Repo\.Rayman\scripts\worker\worker_host.ps1'
    $workspaceRoot = 'C:\Users\Test User\My Repo'

    $argumentText = Get-RaymanWorkerScheduledTaskArguments -WorkerHostScript $scriptPath -WorkspaceRoot $workspaceRoot
    $encoded = $argumentText -replace '^-NoProfile -ExecutionPolicy Bypass -EncodedCommand ', ''
    $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))

    $argumentText | Should -Match '^-NoProfile -ExecutionPolicy Bypass -EncodedCommand '
    $decoded | Should -Be "& 'C:\Users\Test User\My Repo\.Rayman\scripts\worker\worker_host.ps1' -WorkspaceRoot 'C:\Users\Test User\My Repo'"
  }

  It 'auto-selects the sole registry worker when no selector is provided' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_select_single_' + [Guid]::NewGuid().ToString('N'))
    try {
      foreach ($path in @(
          (Join-Path $root '.Rayman'),
          (Join-Path $root '.Rayman\state\workers'),
          (Join-Path $root '.Rayman\runtime\workers')
        )) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
      }
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"

      Write-RaymanWorkerRegistryDocument -WorkspaceRoot $root -Workers @([pscustomobject]@{
            worker_id = 'worker-a'
            worker_name = 'host-a'
            address = '192.168.2.50'
            control_port = 47632
            control_url = 'http://192.168.2.50:47632/'
          })

      $resolved = Resolve-RaymanWorkerSelection -WorkspaceRoot $root -WorkerId '' -WorkerName '' -AllowActive:$false

      $resolved.worker_id | Should -Be 'worker-a'
      $resolved.worker_name | Should -Be 'host-a'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'prefers the configured remote worker even when the active record points at the protected local machine' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_resolve_remote_first_' + [Guid]::NewGuid().ToString('N'))
    $computerNameBackup = $env:COMPUTERNAME
    try {
      foreach ($path in @(
          (Join-Path $root '.Rayman'),
          (Join-Path $root '.Rayman\state\workers'),
          (Join-Path $root '.Rayman\runtime\workers')
        )) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
      }
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v164`n"
      Set-Content -LiteralPath (Join-Path $root '.rayman.env.ps1') -Encoding UTF8 -Value @'
$env:RAYMAN_WORKER_PROTECTED_MACHINE_NAMES = 'QIN5521'
$env:RAYMAN_WORKER_PREFERRED_REMOTE_ID = '9366f479e6b9199a'
$env:RAYMAN_WORKER_PREFERRED_REMOTE_NAME = 'INTEL-RAYMANWEB:RaymanAgent.Worker'
$env:RAYMAN_WORKER_PREFERRED_REMOTE_CONTROL_URL = 'http://192.168.2.107:47632/'
'@
      $env:COMPUTERNAME = 'QIN5521'

      $localWorker = [pscustomobject]@{
        worker_id = (Get-RaymanWorkerStableId -WorkspaceRoot $root)
        worker_name = 'QIN5521:RaymanAgent'
        machine_name = 'QIN5521'
        address = '127.0.0.1'
        control_port = 47632
        control_url = 'http://127.0.0.1:47632/'
        workspace_root = $root
      }
      $remoteWorker = [pscustomobject]@{
        worker_id = '9366f479e6b9199a'
        worker_name = 'INTEL-RAYMANWEB:RaymanAgent.Worker'
        machine_name = 'INTEL-RAYMANWEB'
        address = '192.168.2.107'
        control_port = 47632
        control_url = 'http://192.168.2.107:47632/'
        workspace_root = 'C:\raymanweb\RaymanAgent.Worker'
      }
      Write-RaymanWorkerRegistryDocument -WorkspaceRoot $root -Workers @($localWorker, $remoteWorker) | Out-Null
      Set-RaymanActiveWorkerRecord -WorkspaceRoot $root -Worker $localWorker -WorkspaceMode 'attached' -SyncManifest $null | Out-Null

      $resolved = Resolve-RaymanWorkerSelection -WorkspaceRoot $root -WorkerId '' -WorkerName '' -AllowActive

      $resolved.worker_id | Should -Be '9366f479e6b9199a'
      $resolved.worker_name | Should -Be 'INTEL-RAYMANWEB:RaymanAgent.Worker'
    } finally {
      $env:COMPUTERNAME = $computerNameBackup
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'prefers the active worker when protected local use is explicitly allowed' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_resolve_active_allowed_' + [Guid]::NewGuid().ToString('N'))
    $computerNameBackup = $env:COMPUTERNAME
    try {
      foreach ($path in @(
          (Join-Path $root '.Rayman'),
          (Join-Path $root '.Rayman\state\workers'),
          (Join-Path $root '.Rayman\runtime\workers')
        )) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
      }
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v164`n"
      Set-Content -LiteralPath (Join-Path $root '.rayman.env.ps1') -Encoding UTF8 -Value @'
$env:RAYMAN_WORKER_PROTECTED_MACHINE_NAMES = 'QIN5521'
$env:RAYMAN_WORKER_ALLOW_PROTECTED_LOCAL = '1'
$env:RAYMAN_WORKER_PREFERRED_REMOTE_ID = '9366f479e6b9199a'
$env:RAYMAN_WORKER_PREFERRED_REMOTE_NAME = 'INTEL-RAYMANWEB:RaymanAgent.Worker'
$env:RAYMAN_WORKER_PREFERRED_REMOTE_CONTROL_URL = 'http://192.168.2.107:47632/'
'@
      $env:COMPUTERNAME = 'QIN5521'

      $localWorker = [pscustomobject]@{
        worker_id = (Get-RaymanWorkerStableId -WorkspaceRoot $root)
        worker_name = 'QIN5521:RaymanAgent'
        machine_name = 'QIN5521'
        address = '127.0.0.1'
        control_port = 47632
        control_url = 'http://127.0.0.1:47632/'
        workspace_root = $root
      }
      $remoteWorker = [pscustomobject]@{
        worker_id = '9366f479e6b9199a'
        worker_name = 'INTEL-RAYMANWEB:RaymanAgent.Worker'
        machine_name = 'INTEL-RAYMANWEB'
        address = '192.168.2.107'
        control_port = 47632
        control_url = 'http://192.168.2.107:47632/'
        workspace_root = 'C:\raymanweb\RaymanAgent.Worker'
      }
      Write-RaymanWorkerRegistryDocument -WorkspaceRoot $root -Workers @($localWorker, $remoteWorker) | Out-Null
      Set-RaymanActiveWorkerRecord -WorkspaceRoot $root -Worker $localWorker -WorkspaceMode 'attached' -SyncManifest $null | Out-Null

      $resolved = Resolve-RaymanWorkerSelection -WorkspaceRoot $root -WorkerId '' -WorkerName '' -AllowActive

      $resolved.worker_id | Should -Be $localWorker.worker_id
      $resolved.worker_name | Should -Be 'QIN5521:RaymanAgent'
    } finally {
      $env:COMPUTERNAME = $computerNameBackup
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'blocks install-local on a protected dev machine unless explicitly allowed' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_install_blocked_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null

      Mock Test-RaymanWorkerProtectedDevMachine { return $true }
      Mock Get-RaymanWorkerAllowProtectedLocal { return $false }
      Mock Get-RaymanWorkerMachineName { return 'QIN5521' }

      { Install-RaymanLocalWorker -WorkspaceRoot $root } | Should -Throw '*protected dev machine*'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'retries worker status with a longer direct probe when the first request times out' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_status_retry_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $worker = [pscustomobject]@{
        worker_id = '9366f479e6b9199a'
        worker_name = 'INTEL-RAYMANWEB:RaymanAgent.Worker'
        address = '192.168.2.107'
        control_port = 47632
        control_url = 'http://192.168.2.107:47632/'
      }
      $script:statusTimeoutCalls = @()
      Mock Get-RaymanWorkerStatusTimeoutSeconds { return 10 }
      Mock Get-RaymanWorkerStatusFallbackTimeoutSeconds { return 60 }
      Mock Merge-RaymanWorkerRegistry { return $null }
      Mock Invoke-RaymanWorkerControlRequest {
        param(
          [object]$Worker,
          [string]$Method,
          [string]$Path,
          [object]$Body,
          [string]$InFile,
          [string]$ContentType,
          [int]$TimeoutSeconds,
          [string]$WorkspaceRoot
        )

        $script:statusTimeoutCalls += $TimeoutSeconds
        if ($TimeoutSeconds -eq 10) {
          throw [System.Exception]::new('The request was canceled due to the configured HttpClient.Timeout of 10 seconds elapsing.')
        }

        return [pscustomobject]@{
          worker_id = '9366f479e6b9199a'
          worker_name = 'INTEL-RAYMANWEB:RaymanAgent.Worker'
          address = '192.168.2.107'
          workspace_root = 'C:\raymanweb\RaymanAgent.Worker'
          workspace_mode = 'attached'
          version = 'v164'
          machine_name = 'INTEL-RAYMANWEB'
          debugger_ready = $true
          debugger_path = 'C:\raymanweb\RaymanAgent.Worker\.Rayman\tools\vsdbg\vsdbg.exe'
          control = [pscustomobject]@{
            port = 47632
            base_url = 'http://192.168.2.107:47632/'
          }
        }
      }

      $status = Get-RaymanWorkerLiveStatus -WorkspaceRoot $root -Worker $worker

      $status.version | Should -Be 'v164'
      ($script:statusTimeoutCalls -join ',') | Should -Be '10,60'
      Assert-MockCalled Invoke-RaymanWorkerControlRequest -Times 2
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'starts the worker through Task Scheduler and reports firewall readiness in install-local results' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_install_' + [Guid]::NewGuid().ToString('N'))
    try {
      foreach ($path in @(
          (Join-Path $root '.Rayman'),
          (Join-Path $root '.Rayman\scripts\worker')
        )) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
      }
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\worker\worker_host.ps1') -Encoding UTF8 -Value 'Write-Output ''worker host'''

      Mock Test-RaymanWorkerWindowsHost { return $true }
      Mock Test-RaymanWorkerProtectedDevMachine { return $false }
      Mock Get-RaymanWorkerAllowProtectedLocal { return $false }
      Mock Resolve-RaymanPowerShellHost { return 'powershell.exe' }
      Mock New-RaymanWorkerScheduledTaskAction { return [pscustomobject]@{ kind = 'action' } }
      Mock New-RaymanWorkerScheduledTaskTrigger { return [pscustomobject]@{ kind = 'trigger' } }
      Mock New-RaymanWorkerScheduledTaskSettings { return [pscustomobject]@{ kind = 'settings' } }
      Mock Register-RaymanWorkerScheduledTask {}
      Mock Set-RaymanWorkerAttachedSyncManifest { return [pscustomobject]@{ mode = 'attached' } }
      Mock Ensure-RaymanWorkerVsdbg {
        return [pscustomobject]@{
          debugger_ready = $true
          debugger_path = 'C:\vsdbg\vsdbg.exe'
          debugger_error = ''
        }
      }
      Mock Ensure-RaymanWorkerFirewallRules {
        return [pscustomobject]@{
          schema = 'rayman.worker.firewall.status.v1'
          required = $true
          supported = $true
          elevated = $true
          firewall_ready = $true
          configured = $true
          configured_count = 2
          firewall_error = ''
          rules = @()
        }
      }
      Mock Start-RaymanWorkerScheduledTask {}
      Mock Start-Process {}

      $result = Install-RaymanLocalWorker -WorkspaceRoot $root

      $result.start_method | Should -Be 'scheduled_task'
      $result.firewall_ready | Should -Be $true
      $result.firewall.configured_count | Should -Be 2
      Assert-MockCalled Start-RaymanWorkerScheduledTask -Times 1
      Assert-MockCalled Start-Process -Times 0
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'falls back to a direct worker host launch when Task Scheduler start fails' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_install_fallback_' + [Guid]::NewGuid().ToString('N'))
    try {
      foreach ($path in @(
          (Join-Path $root '.Rayman'),
          (Join-Path $root '.Rayman\scripts\worker')
        )) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
      }
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\worker\worker_host.ps1') -Encoding UTF8 -Value 'Write-Output ''worker host'''

      Mock Test-RaymanWorkerWindowsHost { return $true }
      Mock Test-RaymanWorkerProtectedDevMachine { return $false }
      Mock Get-RaymanWorkerAllowProtectedLocal { return $false }
      Mock Resolve-RaymanPowerShellHost { return 'powershell.exe' }
      Mock New-RaymanWorkerScheduledTaskAction { return [pscustomobject]@{ kind = 'action' } }
      Mock New-RaymanWorkerScheduledTaskTrigger { return [pscustomobject]@{ kind = 'trigger' } }
      Mock New-RaymanWorkerScheduledTaskSettings { return [pscustomobject]@{ kind = 'settings' } }
      Mock Register-RaymanWorkerScheduledTask {}
      Mock Set-RaymanWorkerAttachedSyncManifest { return [pscustomobject]@{ mode = 'attached' } }
      Mock Ensure-RaymanWorkerVsdbg {
        return [pscustomobject]@{
          debugger_ready = $true
          debugger_path = 'C:\vsdbg\vsdbg.exe'
          debugger_error = ''
        }
      }
      Mock Ensure-RaymanWorkerFirewallRules {
        return [pscustomobject]@{
          schema = 'rayman.worker.firewall.status.v1'
          required = $true
          supported = $true
          elevated = $true
          firewall_ready = $true
          configured = $false
          configured_count = 0
          firewall_error = ''
          rules = @()
        }
      }
      Mock Start-RaymanWorkerScheduledTask { throw 'scheduler unavailable' }
      Mock Start-Process {}

      $result = Install-RaymanLocalWorker -WorkspaceRoot $root

      $result.start_method | Should -Be 'process_fallback'
      Assert-MockCalled Start-RaymanWorkerScheduledTask -Times 1
      Assert-MockCalled Start-Process -Times 1
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'rejects attached sync and leaves transient runtime cleanup to staged-only shared workers' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_sync_attached_' + [Guid]::NewGuid().ToString('N'))
    try {
      foreach ($path in @(
          (Join-Path $root '.Rayman'),
          (Join-Path $root '.Rayman\state\workers'),
          (Join-Path $root '.Rayman\runtime\workers'),
          (Join-Path $root '.Rayman\runtime\worker\staging\old-stage'),
          (Join-Path $root '.Rayman\runtime\worker\sync-temp\old-sync'),
          (Join-Path $root '.Rayman\runtime\bats_maui\fixture-a')
        )) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
      }
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"

      $worker = [pscustomobject]@{
        worker_id = 'worker-a'
        worker_name = 'host-a'
        address = '127.0.0.1'
        control_port = 47632
        control_url = 'http://127.0.0.1:47632/'
      }

      { Invoke-RaymanWorkerSyncAction -WorkspaceRoot $root -Worker $worker -Mode 'attached' } | Should -Throw '*staged sync only*'
      Test-Path -LiteralPath (Join-Path $root '.Rayman\runtime\worker\staging\old-stage') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $root '.Rayman\runtime\worker\sync-temp\old-sync') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $root '.Rayman\runtime\bats_maui\fixture-a') | Should -Be $true
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'rejects attached sync on shared workers before sending the request' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_sync_reject_attached_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $worker = [pscustomobject]@{
        worker_id = 'worker-a'
        worker_name = 'host-a'
        address = '127.0.0.1'
        control_port = 47632
        control_url = 'http://127.0.0.1:47632/'
      }

      Mock Invoke-RaymanWorkerControlRequest {}

      { Invoke-RaymanWorkerSyncAction -WorkspaceRoot $root -Worker $worker -Mode 'attached' } | Should -Throw '*staged sync only*'
      Assert-MockCalled Invoke-RaymanWorkerControlRequest -Times 0
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'preserves the active staged root while pruning stale staged runtime data after sync' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_sync_staged_' + [Guid]::NewGuid().ToString('N'))
    try {
      $keepStage = Join-Path $root '.Rayman\runtime\worker\staging\keep-stage'
      $dropStage = Join-Path $root '.Rayman\runtime\worker\staging\drop-stage'
      $syncTemp = Join-Path $root '.Rayman\runtime\worker\sync-temp\old-sync'
      $bundlePath = Join-Path $root '.Rayman\runtime\worker\uploads\bundle.zip'

      foreach ($path in @(
          (Join-Path $root '.Rayman'),
          (Join-Path $root '.Rayman\state\workers'),
          (Join-Path $root '.Rayman\runtime\workers'),
          $keepStage,
          $dropStage,
          $syncTemp,
          (Split-Path -Parent $bundlePath)
        )) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
      }
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
      Set-Content -LiteralPath $bundlePath -Encoding UTF8 -Value 'bundle'

      Mock New-RaymanWorkerSyncBundle {
        [pscustomobject]@{
          bundle_path = $bundlePath
          manifest = [pscustomobject]@{
            fingerprint = 'fingerprint-123'
            file_count = 7
          }
        }
      }
      Mock Invoke-RaymanWorkerControlRequest {
        [pscustomobject]@{
          schema = 'rayman.worker.sync_manifest.v1'
          generated_at = (Get-Date).ToString('o')
          mode = 'staged'
          workspace_root = $root
          staging_root = $keepStage
          cleanup_hint = ''
          rollback_hint = ''
        }
      }

      $worker = [pscustomobject]@{
        worker_id = 'worker-a'
        worker_name = 'host-a'
        address = '127.0.0.1'
        control_port = 47632
        control_url = 'http://127.0.0.1:47632/'
      }

      $result = Invoke-RaymanWorkerSyncAction -WorkspaceRoot $root -Worker $worker -Mode 'staged'
      $syncLast = Get-Content -LiteralPath (Get-RaymanWorkerSyncLastPath -WorkspaceRoot $root) -Raw -Encoding UTF8 | ConvertFrom-Json

      $result.mode | Should -Be 'staged'
      $result.cleanup.preserved_count | Should -BeGreaterThan 0
      $syncLast.mode | Should -Be 'staged'
      $syncLast.staging_root | Should -Be $keepStage
      $syncLast.source_fingerprint | Should -Be 'fingerprint-123'
      $syncLast.source_file_count | Should -Be 7
      $result.sync_manifest.source_fingerprint | Should -Be 'fingerprint-123'
      $result.sync_manifest.source_file_count | Should -Be 7
      Test-Path -LiteralPath $keepStage -PathType Container | Should -Be $true
      Test-Path -LiteralPath $dropStage | Should -Be $false
      Test-Path -LiteralPath $syncTemp | Should -Be $false
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'refreshes the local PowerShell 7 cache to a single latest installer and removes old versions' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_powershell7_cache_' + [Guid]::NewGuid().ToString('N'))
    try {
      $cacheRoot = Get-RaymanWorkerExportPowerShell7CacheRoot -WorkspaceRoot $root
      New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
      Set-Content -LiteralPath (Join-Path $cacheRoot 'PowerShell_7.5.5.0_Machine_X64_wix_en-US.msi') -Encoding UTF8 -Value 'old'
      Set-Content -LiteralPath (Join-Path $cacheRoot 'README.txt') -Encoding UTF8 -Value 'keep'

      Mock Invoke-RaymanWorkerPowerShell7Download {
        param([string]$DestinationRoot)
        $installerPath = Join-Path $DestinationRoot 'PowerShell_7.6.0.0_Machine_X64_wix_en-US.msi'
        Set-Content -LiteralPath $installerPath -Encoding UTF8 -Value 'new'
        [pscustomobject]@{
          installer_path = $installerPath
          installer_name = 'PowerShell_7.6.0.0_Machine_X64_wix_en-US.msi'
          version = '7.6.0.0'
          downloaded_at = '2026-04-03T10:00:00.0000000+08:00'
          source = 'winget'
          package_id = 'Microsoft.PowerShell'
        }
      }

      $status = Sync-RaymanWorkerPowerShell7Cache -WorkspaceRoot $root
      $files = @(Get-ChildItem -LiteralPath $cacheRoot -File | Select-Object -ExpandProperty Name)
      $manifest = Read-RaymanWorkerJsonFile -Path (Get-RaymanWorkerPowerShell7ManifestPath -WorkspaceRoot $root)

      $status.installer_present | Should -Be $true
      $status.refreshed | Should -Be $true
      $status.version | Should -Be '7.6.0.0'
      $files | Should -Contain 'PowerShell_7.6.0.0_Machine_X64_wix_en-US.msi'
      $files | Should -Not -Contain 'PowerShell_7.5.5.0_Machine_X64_wix_en-US.msi'
      $files | Should -Contain 'README.txt'
      $files | Should -Contain 'manifest.json'
      $manifest.version | Should -Be '7.6.0.0'
      $manifest.installer_name | Should -Be 'PowerShell_7.6.0.0_Machine_X64_wix_en-US.msi'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'includes the cached PowerShell 7 installer in exported worker packages when available' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_export_pwsh_' + [Guid]::NewGuid().ToString('N'))
    $tokenBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN')
    try {
      Initialize-TestRaymanWorkerExportWorkspace -Root $root
      $cacheRoot = Get-RaymanWorkerExportPowerShell7CacheRoot -WorkspaceRoot $root
      New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
      $installerPath = Join-Path $cacheRoot 'PowerShell_7.6.0.0_Machine_X64_wix_en-US.msi'
      Set-Content -LiteralPath $installerPath -Encoding UTF8 -Value 'pwsh-msi'
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', 'dev-secret-token')
      Mock Sync-RaymanWorkerPowerShell7Cache {
        [pscustomobject]@{
          refreshed = $true
          installer_present = $true
          installer_path = $installerPath
          installer_name = 'PowerShell_7.6.0.0_Machine_X64_wix_en-US.msi'
          version = '7.6.0.0'
          manifest_path = ''
        }
      }

      $target = Join-Path $root 'export-target'
      $result = Invoke-RaymanWorkerExportPackage -WorkspaceRoot $root -TargetPath $target

      $result.powershell7_included | Should -Be $true
      Test-Path -LiteralPath (Join-Path $target 'download\powershell7\PowerShell_7.6.0.0_Machine_X64_wix_en-US.msi') | Should -Be $true
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', $tokenBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'exports a minimal worker package to the requested target and records export state' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_export_' + [Guid]::NewGuid().ToString('N'))
    $tokenBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN')
    try {
      Initialize-TestRaymanWorkerExportWorkspace -Root $root
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', 'dev-secret-token')
      Mock Sync-RaymanWorkerPowerShell7Cache {
        [pscustomobject]@{
          refreshed = $true
          installer_present = $false
          installer_path = ''
          installer_name = ''
          version = ''
          manifest_path = ''
        }
      }

      $target = Join-Path $root 'export-target'
      $result = Invoke-RaymanWorkerExportPackage -WorkspaceRoot $root -TargetPath $target
      $defaults = Read-RaymanWorkerJsonFile -Path (Get-RaymanWorkerExportDefaultsPath -WorkspaceRoot $root)
      $last = Read-RaymanWorkerJsonFile -Path (Get-RaymanWorkerExportLastPath -WorkspaceRoot $root)
      $envRaw = Get-Content -LiteralPath (Join-Path $target '.rayman.env.ps1') -Raw -Encoding UTF8
      $installRaw = Get-Content -LiteralPath (Join-Path $target 'INSTALL-WORKER.txt') -Raw -Encoding UTF8

      $result.target_path | Should -Be (Resolve-Path -LiteralPath $target).Path
      $result.copied_items | Should -Be (Get-RaymanWorkerExportCopiedItemNames)
      $result.vsdbg_included | Should -Be $true
      $result.powershell7_included | Should -Be $false
      Test-Path -LiteralPath (Join-Path $target '.Rayman\scripts\worker\worker_host.ps1') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $target '.Rayman\runtime') | Should -Be $false
      Test-Path -LiteralPath (Join-Path $target '.Rayman\state') | Should -Be $false
      Test-Path -LiteralPath (Join-Path $target '.Rayman\temp') | Should -Be $false
      Test-Path -LiteralPath (Join-Path $target 'download\README.txt') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $target 'download\vsdbg\vsdbg.exe') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $target 'download\vsdbg\helper.txt') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $target 'download\powershell7\README.txt') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $target 'all.ps1') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $target 'all.bat') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $target 'collect-worker-diag.ps1') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $target 'collect-worker-diag.bat') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $target 'repair-worker-encoding.ps1') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $target 'repair-worker-encoding.bat') | Should -Be $true
      $envRaw | Should -Match '(?m)^\$env:RAYMAN_WORKER_LAN_ENABLED = ''1''\r?$'
      $envRaw | Should -Match '(?m)^\$env:RAYMAN_WORKER_AUTH_TOKEN = ''dev-secret-token''\r?$'
      $installRaw | Should -Match '\\all\.bat'
      $installRaw | Should -Match 'download\\vsdbg'
      $installRaw | Should -Match 'worker install-local'
      $installRaw | Should -Match 'Copy this entire directory as-is'
      $defaults.target_path | Should -Be $result.target_path
      $last.target_path | Should -Be $result.target_path
      $last.env_path | Should -Be (Join-Path $target '.rayman.env.ps1')
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', $tokenBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'reuses the remembered export target when interactive input is blank' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_export_prompt_' + [Guid]::NewGuid().ToString('N'))
    try {
      $rememberedTarget = Join-Path $root 'remembered-target'
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\state\workers') | Out-Null
      Write-RaymanWorkerJsonFile -Path (Get-RaymanWorkerExportDefaultsPath -WorkspaceRoot $root) -Value ([pscustomobject]@{
          schema = 'rayman.worker.export.defaults.v1'
          target_path = $rememberedTarget
          last_export_at = (Get-Date).ToString('o')
        })

      Mock Test-RaymanWorkerInteractiveConsoleAvailable { return $true }
      function global:Read-Host {
        param([string]$Prompt)
        return ''
      }

      $resolved = Resolve-RaymanWorkerExportTargetPath -WorkspaceRoot $root
      $resolved | Should -Be ([System.IO.Path]::GetFullPath($rememberedTarget))
    } finally {
      Remove-Item function:\global:Read-Host -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'does not overwrite the remembered export target when no-remember is used' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_export_noremember_' + [Guid]::NewGuid().ToString('N'))
    $tokenBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN')
    try {
      Initialize-TestRaymanWorkerExportWorkspace -Root $root
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', 'dev-secret-token')
      $rememberedTarget = [System.IO.Path]::GetFullPath((Join-Path $root 'remembered-target'))
      Write-RaymanWorkerJsonFile -Path (Get-RaymanWorkerExportDefaultsPath -WorkspaceRoot $root) -Value ([pscustomobject]@{
          schema = 'rayman.worker.export.defaults.v1'
          target_path = $rememberedTarget
          last_export_at = '2026-03-28T00:00:00.0000000+08:00'
        })
      Mock Sync-RaymanWorkerPowerShell7Cache {
        [pscustomobject]@{
          refreshed = $true
          installer_present = $false
          installer_path = ''
          installer_name = ''
          version = ''
          manifest_path = ''
        }
      }

      $newTarget = Join-Path $root 'fresh-target'
      Invoke-RaymanWorkerExportPackage -WorkspaceRoot $root -TargetPath $newTarget -NoRemember | Out-Null
      $defaults = Read-RaymanWorkerJsonFile -Path (Get-RaymanWorkerExportDefaultsPath -WorkspaceRoot $root)

      $defaults.target_path | Should -Be $rememberedTarget
      Test-Path -LiteralPath (Join-Path $newTarget '.Rayman') | Should -Be $true
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', $tokenBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'exports a minimal worker package without a worker auth token and leaves other target files intact' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_export_missing_token_' + [Guid]::NewGuid().ToString('N'))
    $tokenBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN')
    try {
      Initialize-TestRaymanWorkerExportWorkspace -Root $root
      Remove-Item -LiteralPath (Join-Path $root '.Rayman\state\worker-package-cache\vsdbg') -Recurse -Force -ErrorAction SilentlyContinue
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', $null)
      Mock Sync-RaymanWorkerPowerShell7Cache {
        [pscustomobject]@{
          refreshed = $true
          installer_present = $false
          installer_path = ''
          installer_name = ''
          version = ''
          manifest_path = ''
        }
      }
      $target = Join-Path $root 'missing-token-target'
      New-Item -ItemType Directory -Force -Path $target | Out-Null
      Set-Content -LiteralPath (Join-Path $target 'keep.txt') -Encoding UTF8 -Value 'keep'

      $result = Invoke-RaymanWorkerExportPackage -WorkspaceRoot $root -TargetPath $target
      $envRaw = Get-Content -LiteralPath (Join-Path $target '.rayman.env.ps1') -Raw -Encoding UTF8
      $installRaw = Get-Content -LiteralPath (Join-Path $target 'INSTALL-WORKER.txt') -Raw -Encoding UTF8

      $result.target_path | Should -Be (Resolve-Path -LiteralPath $target).Path
      $result.vsdbg_included | Should -Be $false
      $result.powershell7_included | Should -Be $false
      Test-Path -LiteralPath (Join-Path $target '.Rayman') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $target '.rayman.env.ps1') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $target 'INSTALL-WORKER.txt') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $target 'download\README.txt') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $target 'download\vsdbg\README.txt') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $target 'download\vsdbg\vsdbg.exe') | Should -Be $false
      Test-Path -LiteralPath (Join-Path $target 'download\powershell7\README.txt') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $target 'all.ps1') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $target 'all.bat') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $target 'collect-worker-diag.ps1') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $target 'collect-worker-diag.bat') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $target 'repair-worker-encoding.ps1') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $target 'repair-worker-encoding.bat') | Should -Be $true
      $envRaw | Should -Match '(?m)^\$env:RAYMAN_WORKER_LAN_ENABLED = ''1''\r?$'
      $envRaw | Should -Not -Match 'RAYMAN_WORKER_AUTH_TOKEN'
      $installRaw | Should -Match '\\all\.bat'
      $installRaw | Should -Match 'download\\vsdbg'
      $installRaw | Should -Match 'does not copy any AI token'
      Test-Path -LiteralPath (Join-Path $target 'keep.txt') | Should -Be $true
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', $tokenBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'clears previous worker logs before running the one-command workflow' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_all_logs_' + [Guid]::NewGuid().ToString('N'))
    try {
      foreach ($path in @(
          (Join-Path $root '.Rayman'),
          (Join-Path $root 'log')
        )) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
      }

      $templateRoot = Join-Path $script:WorkspaceRoot '.Rayman\templates\worker-package-root'
      foreach ($fileName in @('all.ps1', 'repair-worker-encoding.ps1', 'collect-worker-diag.ps1')) {
        Copy-Item -LiteralPath (Join-Path $templateRoot $fileName) -Destination (Join-Path $root $fileName) -Force
      }
      Set-Content -LiteralPath (Join-Path $root '.Rayman\rayman.ps1') -Encoding UTF8 -Value @'
param([Parameter(Position=0)][string]$Command='help',[Parameter(Position=1, ValueFromRemainingArguments=$true)][string[]]$CliArgs)
if ($Command -eq 'help') {
  Write-Output 'Rayman help'
  exit 0
}
exit 0
'@

      foreach ($name in @('all-summary.log', 'all-01-repair.log', 'all-02-install.log', 'all-03-postcheck.log', 'repair-encoding.log', '1.log', '2.log', '3.log', '4.log')) {
        Set-Content -LiteralPath (Join-Path (Join-Path $root 'log') $name) -Encoding UTF8 -Value 'OLD_LOG_MARKER'
      }

      $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'all.ps1') -SkipInstall 2>&1 | ForEach-Object { [string]$_ })
      $summaryRaw = Get-Content -LiteralPath (Join-Path $root 'log\all-summary.log') -Raw -Encoding UTF8
      $diagRaw = Get-Content -LiteralPath (Join-Path $root 'log\2.log') -Raw -Encoding UTF8
      $repairRaw = Get-Content -LiteralPath (Join-Path $root 'log\repair-encoding.log') -Raw -Encoding UTF8

      $LASTEXITCODE | Should -Be 0
      $summaryRaw | Should -Not -Match 'OLD_LOG_MARKER'
      $diagRaw | Should -Not -Match 'OLD_LOG_MARKER'
      $repairRaw | Should -Not -Match 'OLD_LOG_MARKER'
      $summaryRaw | Should -Match 'InstallStep: SKIPPED by -SkipInstall.'
      $output | Should -Contain 'All workflow complete.'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
