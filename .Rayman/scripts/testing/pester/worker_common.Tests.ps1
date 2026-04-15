BeforeAll {
  $script:WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  . (Join-Path $script:WorkspaceRoot '.Rayman\scripts\worker\worker_common.ps1')

  function script:Initialize-TestRaymanWorkerWorkspace {
    param(
      [string]$Root,
      [switch]$Source
    )

    New-Item -ItemType Directory -Force -Path (Join-Path $Root '.Rayman\scripts\testing') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Root '.Rayman') | Out-Null
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\scripts\testing\run_fast_contract.sh') -Encoding UTF8 -Value '#!/usr/bin/env bash'
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
    if ($Source) {
      New-Item -ItemType Directory -Force -Path (Join-Path $Root '.github\workflows') | Out-Null
      Set-Content -LiteralPath (Join-Path $Root '.github\workflows\rayman-test-lanes.yml') -Encoding UTF8 -Value 'name: rayman-test-lanes'
    }
  }

  function script:New-TestRaymanWorkerProject {
    param(
      [string]$ProjectDir,
      [string]$ProjectName,
      [string]$Sdk = 'Microsoft.NET.Sdk',
      [string]$OutputType = 'Exe'
    )

    New-Item -ItemType Directory -Force -Path (Join-Path $ProjectDir 'bin\Debug\net8.0') | Out-Null
    $projectLines = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace([string]$Sdk)) {
      $projectLines.Add('<Project>') | Out-Null
    } else {
      $projectLines.Add(('<Project Sdk="{0}">' -f $Sdk)) | Out-Null
    }
    $projectLines.Add('  <PropertyGroup>') | Out-Null
    $projectLines.Add('    <TargetFramework>net8.0</TargetFramework>') | Out-Null
    if (-not [string]::IsNullOrWhiteSpace([string]$OutputType)) {
      $projectLines.Add(('    <OutputType>{0}</OutputType>' -f $OutputType)) | Out-Null
    }
    $projectLines.Add('  </PropertyGroup>') | Out-Null
    $projectLines.Add('</Project>') | Out-Null
    Set-Content -LiteralPath (Join-Path $ProjectDir ("{0}.csproj" -f $ProjectName)) -Encoding UTF8 -Value ($projectLines.ToArray())
    Set-Content -LiteralPath (Join-Path $ProjectDir ("bin\Debug\net8.0\{0}.dll" -f $ProjectName)) -Encoding UTF8 -Value ($ProjectName.ToLowerInvariant())
  }

  function script:Write-TestRaymanSolutionFile {
    param(
      [string]$Root,
      [string[]]$ProjectPaths,
      [ValidateSet('slnx', 'sln')][string]$Format = 'slnx',
      [string]$Name = 'RaymanAgent'
    )

    $solutionPath = Join-Path $Root ("{0}.{1}" -f $Name, $Format)
    if ($Format -eq 'slnx') {
      $lines = New-Object System.Collections.Generic.List[string]
      $lines.Add('<Solution>') | Out-Null
      foreach ($projectPath in @($ProjectPaths)) {
        $normalizedPath = ([string]$projectPath).Replace('\', '/')
        $lines.Add(("  <Project Path=""{0}"" />" -f $normalizedPath)) | Out-Null
      }
      $lines.Add('</Solution>') | Out-Null
      Set-Content -LiteralPath $solutionPath -Encoding UTF8 -Value ($lines.ToArray())
      return $solutionPath
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Microsoft Visual Studio Solution File, Format Version 12.00') | Out-Null
    foreach ($projectPath in @($ProjectPaths)) {
      $normalizedPath = ([string]$projectPath).Replace('/', '\')
      $projectName = [System.IO.Path]::GetFileNameWithoutExtension($normalizedPath)
      $projectGuid = [Guid]::NewGuid().ToString().ToUpperInvariant()
      $lines.Add(("Project(""{{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}}"") = ""{0}"", ""{1}"", ""{{{2}}}""" -f $projectName, $normalizedPath, $projectGuid)) | Out-Null
      $lines.Add('EndProject') | Out-Null
    }
    Set-Content -LiteralPath $solutionPath -Encoding UTF8 -Value ($lines.ToArray())
    return $solutionPath
  }
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
      Set-Content -LiteralPath (Join-Path $projectDir 'DemoApp.csproj') -Encoding UTF8 -Value '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework><OutputType>Exe</OutputType></PropertyGroup></Project>'
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

  It 'discovers a packaged download vsdbg payload before legacy runtime tools or PATH' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_vsdbg_download_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root 'download\vsdbg') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
      Set-Content -LiteralPath (Join-Path $root 'download\vsdbg\vsdbg.exe') -Encoding UTF8 -Value 'package'
      Set-Content -LiteralPath (Join-Path $root 'download\vsdbg\helper.txt') -Encoding UTF8 -Value 'helper'

      $status = Get-RaymanWorkerVsdbgStatus -WorkspaceRoot $root

      $status.debugger_ready | Should -Be $true
      $status.debugger_path | Should -Be (Join-Path $root 'download\vsdbg\vsdbg.exe')
      $status.source | Should -Be 'package_download_cache'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'installs vsdbg from the packaged download cache without attempting an online bootstrap' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_vsdbg_download_install_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root 'download\vsdbg\1033') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
      Set-Content -LiteralPath (Join-Path $root 'download\vsdbg\vsdbg.exe') -Encoding UTF8 -Value 'package'
      Set-Content -LiteralPath (Join-Path $root 'download\vsdbg\1033\vsdbg.resources.dll') -Encoding UTF8 -Value 'resource'

      Mock Invoke-WebRequest {}

      $status = Ensure-RaymanWorkerVsdbg -WorkspaceRoot $root

      $status.debugger_ready | Should -Be $true
      $status.source | Should -Be 'package_download_cache'
      $status.debugger_path | Should -Be (Join-Path $root '.Rayman\tools\vsdbg\vsdbg.exe')
      Test-Path -LiteralPath (Join-Path $root '.Rayman\tools\vsdbg\vsdbg.exe') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $root '.Rayman\tools\vsdbg\1033\vsdbg.resources.dll') | Should -Be $true
      Assert-MockCalled Invoke-WebRequest -Times 0
    } finally {
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
      $status.firewall_ready | Should -Be $true
      $status.firewall.required | Should -Be $false
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_LAN_ENABLED', $lanBackup)
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', $tokenBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'loads the worker auth token from workspace config' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_auth_header_' + [Guid]::NewGuid().ToString('N'))
    $lanBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_LAN_ENABLED')
    $tokenBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN')
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
      Set-Content -LiteralPath (Join-Path $root '.rayman.env.ps1') -Encoding UTF8 -Value @'
$env:RAYMAN_WORKER_LAN_ENABLED = '1'
$env:RAYMAN_WORKER_AUTH_TOKEN = 'workspace-secret'
'@
      Remove-Item Env:RAYMAN_WORKER_AUTH_TOKEN -ErrorAction SilentlyContinue
      Remove-Item Env:RAYMAN_WORKER_LAN_ENABLED -ErrorAction SilentlyContinue

      $headers = Get-RaymanWorkerControlHeaders -WorkspaceRoot $root

      $headers['X-Rayman-Worker-Token'] | Should -Be 'workspace-secret'
    } finally {
      if ($null -eq $lanBackup) {
        Remove-Item Env:RAYMAN_WORKER_LAN_ENABLED -ErrorAction SilentlyContinue
      } else {
        [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_LAN_ENABLED', $lanBackup)
      }
      if ($null -eq $tokenBackup) {
        Remove-Item Env:RAYMAN_WORKER_AUTH_TOKEN -ErrorAction SilentlyContinue
      } else {
        [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', $tokenBackup)
      }
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'does not require auth metadata for LAN status when the token is not configured' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_lan_status_noauth_' + [Guid]::NewGuid().ToString('N'))
    $lanBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_LAN_ENABLED')
    $tokenBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN')
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_LAN_ENABLED', '1')
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', $null)

      $status = Get-RaymanWorkerStatusSnapshot -WorkspaceRoot $root
      $headers = Get-RaymanWorkerControlHeaders -WorkspaceRoot $root

      $status.control.scope | Should -Be 'lan'
      $status.control.auth_required | Should -Be $false
      $headers.ContainsKey('X-Rayman-Worker-Token') | Should -Be $false
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_LAN_ENABLED', $lanBackup)
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', $tokenBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'requires auth metadata for LAN status when the token is configured' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_lan_status_auth_' + [Guid]::NewGuid().ToString('N'))
    $lanBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_LAN_ENABLED')
    $tokenBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN')
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_LAN_ENABLED', '1')
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', 'workspace-secret')

      $status = Get-RaymanWorkerStatusSnapshot -WorkspaceRoot $root
      $headers = Get-RaymanWorkerControlHeaders -WorkspaceRoot $root

      $status.control.scope | Should -Be 'lan'
      $status.control.auth_required | Should -Be $true
      $headers['X-Rayman-Worker-Token'] | Should -Be 'workspace-secret'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_LAN_ENABLED', $lanBackup)
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_AUTH_TOKEN', $tokenBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'surfaces firewall readiness failures in worker status snapshots' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_firewall_status_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"

      Mock Get-RaymanWorkerFirewallStatus {
        [pscustomobject]@{
          schema = 'rayman.worker.firewall.status.v1'
          generated_at = (Get-Date).ToString('o')
          required = $true
          supported = $true
          elevated = $false
          firewall_ready = $false
          rule_prefix = 'Rayman Worker worker-a'
          remote_address = 'LocalSubnet'
          profiles = 'Any'
          configured = $false
          configured_count = 0
          rules = @()
          firewall_error = 'Worker LAN firewall rules are missing or disabled.'
        }
      }

      $status = Get-RaymanWorkerStatusSnapshot -WorkspaceRoot $root
      $beacon = Get-RaymanWorkerBeaconPayload -WorkspaceRoot $root -StatusSnapshot $status

      $status.firewall_ready | Should -Be $false
      $status.firewall_error | Should -Match 'firewall rules are missing or disabled'
      $status.firewall.required | Should -Be $true
      $beacon.firewall_ready | Should -Be $false
      $beacon.firewall_error | Should -Match 'firewall rules are missing or disabled'
    } finally {
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

  It 'ignores runtime-generated projects when discovering debug entrypoints in source workspaces' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_entrypoints_' + [Guid]::NewGuid().ToString('N'))
    try {
      $authoredDir = Join-Path $root 'src\DemoApp'
      $runtimeDir = Join-Path $root '.Rayman\runtime\worker\staging\demo-stage\RuntimeTemp'
      $batsDir = Join-Path $root '.Rayman\runtime\bats_maui\fixture\DeleteDir'

      Initialize-TestRaymanWorkerWorkspace -Root $root -Source
      New-TestRaymanWorkerProject -ProjectDir $authoredDir -ProjectName 'DemoApp'
      New-TestRaymanWorkerProject -ProjectDir $runtimeDir -ProjectName 'RuntimeTemp'
      New-TestRaymanWorkerProject -ProjectDir $batsDir -ProjectName 'DeleteDir'

      $entries = @(Get-RaymanWorkerDotNetEntrypoints -ExecutionRoot $root -WorkspaceRoot $root)
      $defaultProgram = Get-RaymanWorkerDefaultDebugTarget -ExecutionRoot $root -WorkspaceRoot $root

      $entries.Count | Should -Be 1
      $entries[0].project_name | Should -Be 'DemoApp'
      $entries[0].project_path | Should -Be (Join-Path $authoredDir 'DemoApp.csproj')
      $defaultProgram | Should -Be (Join-Path $authoredDir 'bin\Debug\net8.0\DemoApp.dll')
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'discovers staged workspace projects without excluding the staged root prefix' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_staged_entrypoints_' + [Guid]::NewGuid().ToString('N'))
    try {
      $stageRoot = Join-Path $root '.Rayman\runtime\worker\staging\demo-stage'
      $authoredDir = Join-Path $stageRoot 'src\DemoApp'
      $fixtureDir = Join-Path $stageRoot '.Rayman\scripts\testing\fixtures\worker_smoke_app'
      $runtimeDir = Join-Path $stageRoot '.Rayman\runtime\bats_maui\fixture\DeleteDir'

      Initialize-TestRaymanWorkerWorkspace -Root $root -Source
      New-TestRaymanWorkerProject -ProjectDir $authoredDir -ProjectName 'DemoApp'
      New-TestRaymanWorkerProject -ProjectDir $fixtureDir -ProjectName 'WorkerSmokeApp'
      New-TestRaymanWorkerProject -ProjectDir $runtimeDir -ProjectName 'DeleteDir'

      $entries = @(Get-RaymanWorkerDotNetEntrypoints -ExecutionRoot $stageRoot -WorkspaceRoot $root)
      $defaultProgram = Get-RaymanWorkerDefaultDebugTarget -ExecutionRoot $stageRoot -WorkspaceRoot $root

      $entries.Count | Should -Be 1
      $entries[0].project_name | Should -Be 'DemoApp'
      $entries[0].project_path | Should -Be (Join-Path $authoredDir 'DemoApp.csproj')
      $defaultProgram | Should -Be (Join-Path $authoredDir 'bin\Debug\net8.0\DemoApp.dll')
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'does not use source-only solution priority in external workspaces' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_external_fixture_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-TestRaymanWorkerWorkspace -Root $root
      $fixtureDir = Join-Path $root '.Rayman\scripts\testing\fixtures\worker_smoke_app'
      New-TestRaymanWorkerProject -ProjectDir $fixtureDir -ProjectName 'WorkerSmokeApp'
      Write-TestRaymanSolutionFile -Root $root -ProjectPaths @('.Rayman/scripts/testing/fixtures/worker_smoke_app/WorkerSmokeApp.csproj') | Out-Null

      $entries = @(Get-RaymanWorkerDotNetEntrypoints -ExecutionRoot $root -WorkspaceRoot $root)
      $defaultProgram = Get-RaymanWorkerDefaultDebugTarget -ExecutionRoot $root -WorkspaceRoot $root

      (Get-RaymanWorkspaceKind -WorkspaceRoot $root) | Should -Be 'external'
      $entries.Count | Should -Be 0
      $defaultProgram | Should -Be ''
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'prefers the root .slnx project list in source workspaces' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_source_fixture_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-TestRaymanWorkerWorkspace -Root $root -Source
      $fixtureDir = Join-Path $root '.Rayman\scripts\testing\fixtures\worker_smoke_app'
      New-TestRaymanWorkerProject -ProjectDir $fixtureDir -ProjectName 'WorkerSmokeApp'
      Write-TestRaymanSolutionFile -Root $root -ProjectPaths @('.Rayman/scripts/testing/fixtures/worker_smoke_app/WorkerSmokeApp.csproj') | Out-Null

      $entries = @(Get-RaymanWorkerDotNetEntrypoints -ExecutionRoot $root -WorkspaceRoot $root)
      $defaultProgram = Get-RaymanWorkerDefaultDebugTarget -ExecutionRoot $root -WorkspaceRoot $root

      (Get-RaymanWorkspaceKind -WorkspaceRoot $root) | Should -Be 'source'
      $entries.Count | Should -Be 1
      $entries[0].project_name | Should -Be 'WorkerSmokeApp'
      $entries[0].project_path | Should -Be (Join-Path $fixtureDir 'WorkerSmokeApp.csproj')
      $defaultProgram | Should -Be (Join-Path $fixtureDir 'bin\Debug\net8.0\WorkerSmokeApp.dll')
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'skips class libraries when the root solution lists them before an executable project' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_solution_launchable_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-TestRaymanWorkerWorkspace -Root $root -Source
      $libraryDir = Join-Path $root 'src\SharedLib'
      $appDir = Join-Path $root 'src\DemoApp'
      New-TestRaymanWorkerProject -ProjectDir $libraryDir -ProjectName 'SharedLib' -OutputType 'Library'
      New-TestRaymanWorkerProject -ProjectDir $appDir -ProjectName 'DemoApp' -OutputType 'Exe'
      Write-TestRaymanSolutionFile -Root $root -ProjectPaths @(
        'src/SharedLib/SharedLib.csproj',
        'src/DemoApp/DemoApp.csproj'
      ) | Out-Null

      $entries = @(Get-RaymanWorkerDotNetEntrypoints -ExecutionRoot $root -WorkspaceRoot $root)
      $defaultProgram = Get-RaymanWorkerDefaultDebugTarget -ExecutionRoot $root -WorkspaceRoot $root

      $entries.Count | Should -Be 1
      $entries[0].project_name | Should -Be 'DemoApp'
      $entries[0].project_path | Should -Be (Join-Path $appDir 'DemoApp.csproj')
      $defaultProgram | Should -Be (Join-Path $appDir 'bin\Debug\net8.0\DemoApp.dll')
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'remaps root .slnx projects into staged source workspaces' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_source_staged_fixture_' + [Guid]::NewGuid().ToString('N'))
    $vsdbgOverrideBackup = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_VSDBG_PATH')
    try {
      $stageRoot = Join-Path $root '.Rayman\runtime\worker\staging\demo-stage'
      $fixtureDir = Join-Path $stageRoot '.Rayman\scripts\testing\fixtures\worker_smoke_app'
      $fixtureProgram = Join-Path $fixtureDir 'bin\Debug\net8.0\WorkerSmokeApp.dll'
      $vsdbgPath = Join-Path $root 'fake-vsdbg.exe'

      Initialize-TestRaymanWorkerWorkspace -Root $root -Source
      New-TestRaymanWorkerProject -ProjectDir $fixtureDir -ProjectName 'WorkerSmokeApp'
      Write-TestRaymanSolutionFile -Root $root -ProjectPaths @('.Rayman/scripts/testing/fixtures/worker_smoke_app/WorkerSmokeApp.csproj') | Out-Null
      Set-Content -LiteralPath $vsdbgPath -Encoding UTF8 -Value 'vsdbg'
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_VSDBG_PATH', $vsdbgPath)

      $syncManifest = [pscustomobject]@{
        mode = 'staged'
        staging_root = $stageRoot
      }
      $status = Get-RaymanWorkerStatusSnapshot -WorkspaceRoot $root -SyncManifest $syncManifest
      $manifest = New-RaymanWorkerDebugManifest -WorkspaceRoot $root -Mode 'launch' -SyncManifest $syncManifest -SkipDebuggerInstall

      $status.execution_root | Should -Be $stageRoot
      $status.debug.entrypoints.Count | Should -Be 1
      $status.debug.entrypoints[0].project_name | Should -Be 'WorkerSmokeApp'
      $status.debug.entrypoints[0].project_path | Should -Be (Join-Path $fixtureDir 'WorkerSmokeApp.csproj')
      $status.debug.default_program | Should -Be $fixtureProgram
      $manifest.execution_root | Should -Be $stageRoot
      $manifest.program | Should -Be $fixtureProgram
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_WORKER_VSDBG_PATH', $vsdbgOverrideBackup)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'uses the root .sln fallback when no .slnx exists in source workspaces' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_source_priority_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-TestRaymanWorkerWorkspace -Root $root -Source
      $fixtureDir = Join-Path $root '.Rayman\scripts\testing\fixtures\worker_smoke_app'
      New-TestRaymanWorkerProject -ProjectDir $fixtureDir -ProjectName 'WorkerSmokeApp'
      Write-TestRaymanSolutionFile -Root $root -ProjectPaths @('.Rayman\scripts\testing\fixtures\worker_smoke_app\WorkerSmokeApp.csproj') -Format 'sln' | Out-Null

      $entries = @(Get-RaymanWorkerDotNetEntrypoints -ExecutionRoot $root -WorkspaceRoot $root)
      $defaultProgram = Get-RaymanWorkerDefaultDebugTarget -ExecutionRoot $root -WorkspaceRoot $root

      $entries.Count | Should -Be 1
      $entries[0].project_name | Should -Be 'WorkerSmokeApp'
      $entries[0].project_path | Should -Be (Join-Path $fixtureDir 'WorkerSmokeApp.csproj')
      $defaultProgram | Should -Be (Join-Path $fixtureDir 'bin\Debug\net8.0\WorkerSmokeApp.dll')
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'falls back to scan discovery when the root solution has no usable project' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_solution_fallback_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-TestRaymanWorkerWorkspace -Root $root -Source
      $authoredDir = Join-Path $root 'src\DemoApp'
      $runtimeDir = Join-Path $root '.Rayman\runtime\worker\staging\demo-stage\RuntimeTemp'
      New-TestRaymanWorkerProject -ProjectDir $authoredDir -ProjectName 'DemoApp'
      New-TestRaymanWorkerProject -ProjectDir $runtimeDir -ProjectName 'RuntimeTemp'
      Write-TestRaymanSolutionFile -Root $root -ProjectPaths @('.Rayman/scripts/testing/fixtures/worker_smoke_app/MissingApp.csproj') | Out-Null

      $entries = @(Get-RaymanWorkerDotNetEntrypoints -ExecutionRoot $root -WorkspaceRoot $root)
      $defaultProgram = Get-RaymanWorkerDefaultDebugTarget -ExecutionRoot $root -WorkspaceRoot $root

      $entries.Count | Should -Be 1
      $entries[0].project_name | Should -Be 'DemoApp'
      $entries[0].project_path | Should -Be (Join-Path $authoredDir 'DemoApp.csproj')
      $defaultProgram | Should -Be (Join-Path $authoredDir 'bin\Debug\net8.0\DemoApp.dll')
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'prefers the configured remote worker and hides the protected local worker from the registry view' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_remote_first_' + [Guid]::NewGuid().ToString('N'))
    $computerNameBackup = $env:COMPUTERNAME
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\state\workers') | Out-Null
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

      $visible = Get-RaymanVisibleWorkerRegistryDocument -WorkspaceRoot $root
      $resolved = Resolve-RaymanWorkerBySelector -WorkspaceRoot $root -AllowActive

      @($visible.workers).Count | Should -Be 1
      @($visible.workers | Select-Object -ExpandProperty worker_id) | Should -Contain '9366f479e6b9199a'
      @($visible.workers | Select-Object -ExpandProperty worker_id) | Should -Not -Contain $localWorker.worker_id
      $resolved.worker_id | Should -Be '9366f479e6b9199a'
      $resolved.worker_name | Should -Be 'INTEL-RAYMANWEB:RaymanAgent.Worker'
    } finally {
      $env:COMPUTERNAME = $computerNameBackup
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'drops a protected local active worker context until an explicit opt-in is provided' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_protected_active_' + [Guid]::NewGuid().ToString('N'))
    $computerNameBackup = $env:COMPUTERNAME
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\state\workers') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v164`n"
      Set-Content -LiteralPath (Join-Path $root '.rayman.env.ps1') -Encoding UTF8 -Value @'
$env:RAYMAN_WORKER_PROTECTED_MACHINE_NAMES = 'QIN5521'
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
      Write-RaymanWorkerRegistryDocument -WorkspaceRoot $root -Workers @($localWorker) | Out-Null
      Set-RaymanActiveWorkerRecord -WorkspaceRoot $root -Worker $localWorker -WorkspaceMode 'attached' -SyncManifest $null | Out-Null

      $context = Get-RaymanWorkerActiveExecutionContext -WorkspaceRoot $root

      $context | Should -Be $null
    } finally {
      $env:COMPUTERNAME = $computerNameBackup
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
