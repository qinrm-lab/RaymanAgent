BeforeAll {
  $script:WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  . (Join-Path $script:WorkspaceRoot '.Rayman\scripts\worker\worker_common.ps1')
}

Describe 'worker common helpers' {
  It 'merges registry entries and resolves the active worker' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_registry_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\state\workers') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime\workers') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"

      $first = [pscustomobject]@{
        worker_id = 'worker-a'
        worker_name = 'host-a'
        address = '192.168.1.10'
        control_port = 47632
        control_url = 'http://192.168.1.10:47632/'
      }
      $second = [pscustomobject]@{
        worker_id = 'worker-b'
        worker_name = 'host-b'
        address = '192.168.1.11'
        control_port = 47632
        control_url = 'http://192.168.1.11:47632/'
      }

      $merged = Merge-RaymanWorkerRegistry -WorkspaceRoot $root -Workers @($first, $second)
      $active = Set-RaymanActiveWorkerRecord -WorkspaceRoot $root -Worker $first -WorkspaceMode 'staged' -SyncManifest ([pscustomobject]@{ mode = 'staged'; staging_root = 'C:\stage' })
      $resolved = Get-RaymanWorkerActiveExecutionContext -WorkspaceRoot $root

      $merged.workers.Count | Should -Be 2
      $active.worker_id | Should -Be 'worker-a'
      $resolved.worker.worker_id | Should -Be 'worker-a'
      $resolved.active.workspace_mode | Should -Be 'staged'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'builds a debug manifest that maps the worker execution root back to the local workspace' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_debug_' + [Guid]::NewGuid().ToString('N'))
    $vsdbgOverrideBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_VSDBG_PATH')
    try {
      $projectDir = Join-Path $root 'DemoApp'
      $vsdbgPath = Join-Path $root 'fake-vsdbg.exe'
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $projectDir 'bin\Debug\net8.0') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime\worker\staging\demo-stage') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
      Set-Content -LiteralPath (Join-Path $projectDir 'DemoApp.csproj') -Encoding UTF8 -Value '<Project><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>'
      Set-Content -LiteralPath (Join-Path $projectDir 'bin\Debug\net8.0\DemoApp.dll') -Encoding UTF8 -Value 'binary'
      Set-Content -LiteralPath $vsdbgPath -Encoding UTF8 -Value 'vsdbg'
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_VSDBG_PATH', $vsdbgPath)

      $syncManifest = [pscustomobject]@{
        mode = 'staged'
        staging_root = $root
      }
      $manifest = New-RaymanWorkerDebugManifest -WorkspaceRoot $root -Mode 'launch' -SyncManifest $syncManifest -SkipDebuggerInstall

      $manifest.schema | Should -Be 'rayman.worker.debug_session.v1'
      $manifest.workspace_mode | Should -Be 'staged'
      $manifest.debugger_ready | Should -Be $true
      $manifest.debugger_path | Should -Be $vsdbgPath
      $manifest.program | Should -Match 'DemoApp\.dll$'
      $manifest.source_file_map.PSObject.Properties.Name | Should -Contain $root
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_VSDBG_PATH', $vsdbgOverrideBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'prefers an explicit vsdbg override over the workspace tool path' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_vsdbg_override_' + [Guid]::NewGuid().ToString('N'))
    $vsdbgOverrideBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_VSDBG_PATH')
    try {
      $overridePath = Join-Path $root 'override-vsdbg.exe'
      $workspaceVsdbg = Join-Path $root '.Rayman\tools\vsdbg\vsdbg.exe'
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\tools\vsdbg') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
      Set-Content -LiteralPath $overridePath -Encoding UTF8 -Value 'override'
      Set-Content -LiteralPath $workspaceVsdbg -Encoding UTF8 -Value 'workspace'
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_VSDBG_PATH', $overridePath)

      $status = Get-RaymanWorkerVsdbgStatus -WorkspaceRoot $root

      $status.debugger_ready | Should -Be $true
      $status.debugger_path | Should -Be $overridePath
      $status.source | Should -Be 'env_override'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_VSDBG_PATH', $vsdbgOverrideBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'reports debugger readiness failure when the explicit override is missing' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_vsdbg_missing_' + [Guid]::NewGuid().ToString('N'))
    $vsdbgOverrideBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_VSDBG_PATH')
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_VSDBG_PATH', (Join-Path $root 'missing-vsdbg.exe'))

      $status = Get-RaymanWorkerStatusSnapshot -WorkspaceRoot $root

      $status.debugger_ready | Should -Be $false
      $status.debugger_path | Should -Match 'missing-vsdbg\.exe$'
      $status.debugger_error | Should -Match 'RAYMAN_WORKER_VSDBG_PATH'
      $status.debug.debugger_ready | Should -Be $false
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_VSDBG_PATH', $vsdbgOverrideBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'advertises loopback-only control metadata by default' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_loopback_status_' + [Guid]::NewGuid().ToString('N'))
    $lanBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_LAN_ENABLED')
    $tokenBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN')
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_LAN_ENABLED', $null)
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', $null)

      $status = Get-RaymanWorkerStatusSnapshot -WorkspaceRoot $root

      $status.address | Should -Be '127.0.0.1'
      $status.control.base_url | Should -Be ('http://127.0.0.1:{0}/' -f (Get-RaymanWorkerControlPort))
      $status.control.scope | Should -Be 'loopback'
      $status.control.auth_required | Should -Be $false
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_LAN_ENABLED', $lanBackup)
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', $tokenBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'loads the worker auth token from workspace config' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_auth_header_' + [Guid]::NewGuid().ToString('N'))
    $tokenBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN')
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
      Set-Content -LiteralPath (Join-Path $root '.rayman.env.ps1') -Encoding UTF8 -Value "`$env:RAYMAN_WORKER_AUTH_TOKEN = 'workspace-secret'"
      Remove-Item Env:RAYMAN_WORKER_AUTH_TOKEN -ErrorAction SilentlyContinue

      $headers = Get-RaymanWorkerControlHeaders -WorkspaceRoot $root

      $headers['X-Rayman-Worker-Token'] | Should -Be 'workspace-secret'
    } finally {
      if ($null -eq $tokenBackup) {
        Remove-Item Env:RAYMAN_WORKER_AUTH_TOKEN -ErrorAction SilentlyContinue
      } else {
        [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', $tokenBackup)
      }
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'times out worker native capture instead of hanging the host' {
    $powershellHost = (Get-Command powershell.exe -ErrorAction Stop).Source

    $result = Invoke-RaymanWorkerNativeCommandCapture -FilePath $powershellHost -ArgumentList @(
      '-NoProfile',
      '-Command',
      'Start-Sleep -Seconds 5'
    ) -TimeoutMilliseconds 200

    $result.started | Should -Be $true
    $result.timed_out | Should -Be $true
    $result.success | Should -Be $false
  }

  It 'times out worker local commands instead of blocking forever' {
    $result = Invoke-RaymanWorkerLocalCommand -WorkspaceRoot $script:WorkspaceRoot -ExecutionRoot $script:WorkspaceRoot -CommandText 'Start-Sleep -Seconds 5' -TimeoutSeconds 1

    $result.success | Should -Be $false
    $result.exit_code | Should -Be 124
    $result.error_message | Should -Match 'timed out'
  }

  It 'fails debug manifest creation when vsdbg is unavailable' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_manifest_missing_vsdbg_' + [Guid]::NewGuid().ToString('N'))
    $vsdbgOverrideBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_VSDBG_PATH')
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_VSDBG_PATH', $null)

      { New-RaymanWorkerDebugManifest -WorkspaceRoot $root -Mode 'attach' -SkipDebuggerInstall } | Should -Throw '*vsdbg*'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_VSDBG_PATH', $vsdbgOverrideBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'fails launch manifest creation when the target program is missing' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_manifest_missing_program_' + [Guid]::NewGuid().ToString('N'))
    $vsdbgOverrideBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_VSDBG_PATH')
    try {
      $vsdbgPath = Join-Path $root 'fake-vsdbg.exe'
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
      Set-Content -LiteralPath $vsdbgPath -Encoding UTF8 -Value 'vsdbg'
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_VSDBG_PATH', $vsdbgPath)

      { New-RaymanWorkerDebugManifest -WorkspaceRoot $root -Mode 'launch' -Program 'missing.dll' -SkipDebuggerInstall } | Should -Throw '*launch debug target not found*'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_VSDBG_PATH', $vsdbgOverrideBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
