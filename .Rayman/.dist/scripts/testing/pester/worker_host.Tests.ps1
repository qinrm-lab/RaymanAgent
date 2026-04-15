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

      $workerProcess = Start-Process -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $script:WorkspaceRoot '.Rayman\scripts\worker\worker_host.ps1'),
        '-WorkspaceRoot',
        $root,
        '-NoBeacon'
      ) -WindowStyle Hidden -PassThru

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

}
