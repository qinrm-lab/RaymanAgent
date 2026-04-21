BeforeAll {
  $script:WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  . (Join-Path $script:WorkspaceRoot '.Rayman\scripts\worker\worker_host.ps1') -NoMain
}

Describe 'worker host auth guards' {
  It 'allows loopback-only requests without a token' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_host_loopback_' + [Guid]::NewGuid().ToString('N'))
    $lanBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_LAN_ENABLED')
    $tokenBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN')
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_LAN_ENABLED', '0')
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', $null)

      { Assert-RaymanWorkerAuthorized -WorkspaceRoot $root -Headers @{} } | Should -Not -Throw
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_LAN_ENABLED', $lanBackup)
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', $tokenBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'requires a matching token when LAN mode is enabled' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_host_auth_' + [Guid]::NewGuid().ToString('N'))
    $lanBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_LAN_ENABLED')
    $tokenBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN')
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_LAN_ENABLED', '1')
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', 'shared-secret')

      { Assert-RaymanWorkerAuthorized -WorkspaceRoot $root -Headers @{} } | Should -Throw '*required*'
      { Assert-RaymanWorkerAuthorized -WorkspaceRoot $root -Headers @{ 'X-Rayman-Worker-Token' = 'wrong-secret' } } | Should -Throw '*invalid*'
      { Assert-RaymanWorkerAuthorized -WorkspaceRoot $root -Headers @{ 'X-Rayman-Worker-Token' = 'shared-secret' } } | Should -Not -Throw
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_LAN_ENABLED', $lanBackup)
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', $tokenBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'allows LAN requests without a token when auth is not configured' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_host_failfast_' + [Guid]::NewGuid().ToString('N'))
    $lanBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_LAN_ENABLED')
    $tokenBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN')
    $controlPortBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_CONTROL_PORT')
    $discoveryPortBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_DISCOVERY_PORT')
    $workerProcess = $null
    $statusPath = ''
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_LAN_ENABLED', '1')
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', $null)
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_CONTROL_PORT', [string](Get-Random -Minimum 41000 -Maximum 47000))
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_DISCOVERY_PORT', [string](Get-Random -Minimum 47001 -Maximum 53000))

      { Assert-RaymanWorkerAuthorized -WorkspaceRoot $root -Headers @{} } | Should -Not -Throw

      $startProcessParams = @{
        FilePath = (Resolve-RaymanPowerShellHost)
        ArgumentList = @(
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          (Join-Path $script:WorkspaceRoot '.Rayman\scripts\worker\worker_host.ps1'),
          '-WorkspaceRoot',
          $root,
          '-NoBeacon'
        )
        PassThru = $true
      }
      if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $startProcessParams.WindowStyle = 'Hidden'
      }

      $workerProcess = Start-Process @startProcessParams

      $statusPath = Get-RaymanWorkerHostStatusPath -WorkspaceRoot $root
      $deadline = (Get-Date).AddSeconds(20)
      while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $statusPath) -and -not $workerProcess.HasExited) {
        Start-Sleep -Milliseconds 200
      }

      Test-Path -LiteralPath $statusPath | Should -Be $true
      $workerProcess.HasExited | Should -Be $false
    } finally {
      if ($null -ne $workerProcess -and -not $workerProcess.HasExited) {
        Stop-Process -Id $workerProcess.Id -Force -ErrorAction SilentlyContinue
      }
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_LAN_ENABLED', $lanBackup)
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', $tokenBackup)
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_CONTROL_PORT', $controlPortBackup)
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_DISCOVERY_PORT', $discoveryPortBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'keeps per-client staged sessions isolated' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_host_client_isolation_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"

      $clientA = [pscustomobject]@{
        schema = 'rayman.worker.client_context.v1'
        client_id = 'aaaaaaaaaaaaaaaa'
        machine_name = 'DEV-A'
        source_workspace_root = 'C:\dev\a'
        workspace_name = 'a'
      }
      $clientB = [pscustomobject]@{
        schema = 'rayman.worker.client_context.v1'
        client_id = 'bbbbbbbbbbbbbbbb'
        machine_name = 'DEV-B'
        source_workspace_root = 'C:\dev\b'
        workspace_name = 'b'
      }

      Set-RaymanWorkerClientSyncManifest -WorkspaceRoot $root -ClientContext $clientA -SyncManifest ([pscustomobject]@{
          schema = 'rayman.worker.sync_manifest.v1'
          generated_at = (Get-Date).ToString('o')
          mode = 'staged'
          source_workspace_root = 'C:\dev\a'
          staging_root = (Join-Path $root '.Rayman\runtime\worker\staging\aaaaaaaaaaaaaaaa\stage-a')
        }) | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime\worker\staging\aaaaaaaaaaaaaaaa\stage-a') | Out-Null
      Set-RaymanWorkerClientSyncManifest -WorkspaceRoot $root -ClientContext $clientB -SyncManifest ([pscustomobject]@{
          schema = 'rayman.worker.sync_manifest.v1'
          generated_at = (Get-Date).ToString('o')
          mode = 'staged'
          source_workspace_root = 'C:\dev\b'
          staging_root = (Join-Path $root '.Rayman\runtime\worker\staging\bbbbbbbbbbbbbbbb\stage-b')
        }) | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime\worker\staging\bbbbbbbbbbbbbbbb\stage-b') | Out-Null

      $statusA = Invoke-RaymanWorkerRequestData -WorkspaceRoot $root -HostStartTime '' -RequestData ([pscustomobject]@{
          method = 'GET'
          path = '/status'
          headers = @{}
          query_string = @{ client_id = 'aaaaaaaaaaaaaaaa' }
          body_json = $null
          body_bytes = @()
        })
      $statusB = Invoke-RaymanWorkerRequestData -WorkspaceRoot $root -HostStartTime '' -RequestData ([pscustomobject]@{
          method = 'GET'
          path = '/status'
          headers = @{}
          query_string = @{ client_id = 'bbbbbbbbbbbbbbbb' }
          body_json = $null
          body_bytes = @()
        })

      [string]$statusA.client_session.client_id | Should -Be 'aaaaaaaaaaaaaaaa'
      [string]$statusB.client_session.client_id | Should -Be 'bbbbbbbbbbbbbbbb'
      [string]$statusA.execution_root | Should -Match 'stage-a$'
      [string]$statusB.execution_root | Should -Match 'stage-b$'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'rejects attached sync requests on shared workers' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_host_reject_attached_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"

      {
        Invoke-RaymanWorkerRequestData -WorkspaceRoot $root -HostStartTime '' -RequestData ([pscustomobject]@{
            method = 'POST'
            path = '/sync'
            headers = @{}
            query_string = @{}
            body_json = [pscustomobject]@{
              mode = 'attached'
              client_context = [pscustomobject]@{
                schema = 'rayman.worker.client_context.v1'
                client_id = 'cccccccccccccccc'
                machine_name = 'DEV-C'
                source_workspace_root = 'C:\dev\c'
                workspace_name = 'c'
              }
            }
            body_bytes = @()
          })
      } | Should -Throw '*shared worker only supports staged mode*'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
