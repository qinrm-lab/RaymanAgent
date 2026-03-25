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
}
