BeforeAll {
  $script:WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  . (Join-Path $PSScriptRoot '..\..\..\common.ps1')
  . (Join-Path $PSScriptRoot '..\host_smoke.lib.ps1')
}

Describe 'host smoke bash path conversion' {
  It 'converts Windows paths to WSL mount paths when required' {
    Convert-RaymanHostSmokePathToBashCompat -PathValue 'E:\rayman\software\RaymanAgent' -Mode wsl | Should -Be '/mnt/e/rayman/software/RaymanAgent'
  }

  It 'normalizes Windows paths for plain bash mode' {
    Convert-RaymanHostSmokePathToBashCompat -PathValue 'E:\rayman\software\RaymanAgent' -Mode bash | Should -Be 'E:/rayman/software/RaymanAgent'
  }
}

Describe 'host smoke native capture' {
  It 'preserves stderr text and exact exit code' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_host_smoke_capture_' + [Guid]::NewGuid().ToString('N'))
    try {
      $logDir = Join-Path $root 'logs'
      New-Item -ItemType Directory -Force -Path $logDir | Out-Null

      $psHost = Resolve-RaymanPowerShellHost
      $psHost | Should -Not -BeNullOrEmpty

      $result = Invoke-RaymanHostSmokeStep -Name 'stderr_exit' -LogDir $logDir -FilePath $psHost -ArgumentList @('-NoProfile', '-Command', "[Console]::Error.WriteLine('host smoke stderr'); exit 7") -WorkingDirectory $root
      $logText = Get-Content -LiteralPath $result.log_path -Raw -Encoding UTF8

      $result.started | Should -Be $true
      $result.exit_code | Should -Be 7
      $result.output | Should -Match 'host smoke stderr'
      $logText | Should -Match 'host smoke stderr'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'times out long-running steps and marks them as timed out' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_host_smoke_timeout_' + [Guid]::NewGuid().ToString('N'))
    try {
      $logDir = Join-Path $root 'logs'
      New-Item -ItemType Directory -Force -Path $logDir | Out-Null

      $psHost = Resolve-RaymanPowerShellHost
      $psHost | Should -Not -BeNullOrEmpty

      $result = Invoke-RaymanHostSmokeStep -Name 'timeout_step' -LogDir $logDir -FilePath $psHost -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 5') -WorkingDirectory $root -TimeoutSeconds 1
      $logText = Get-Content -LiteralPath $result.log_path -Raw -Encoding UTF8

      $result.started | Should -Be $true
      $result.timed_out | Should -Be $true
      $result.exit_code | Should -Be 124
      $result.launch_error | Should -Match 'timed out'
      $logText | Should -Match 'timed out'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'host smoke python resolution' {
  It 'falls back to python when python3 is not runnable' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_host_smoke_python_' + [Guid]::NewGuid().ToString('N'))
    $pathBackup = [string]$env:PATH
    $pathSeparator = if (Test-RaymanWindowsPlatform) { ';' } else { ':' }
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      if (Test-RaymanWindowsPlatform) {
        Set-Content -LiteralPath (Join-Path $root 'python3.cmd') -Encoding ASCII -Value @'
@echo off
echo python3 unavailable 1>&2
exit /b 9009
'@
        Set-Content -LiteralPath (Join-Path $root 'python.cmd') -Encoding ASCII -Value @'
@echo off
echo Python 3.13.5
exit /b 0
'@
      } else {
        Set-Content -LiteralPath (Join-Path $root 'python3') -Encoding ASCII -Value @'
#!/usr/bin/env bash
echo python3 unavailable >&2
exit 9
'@
        Set-Content -LiteralPath (Join-Path $root 'python') -Encoding ASCII -Value @'
#!/usr/bin/env bash
echo Python 3.13.5
exit 0
'@
        & chmod +x (Join-Path $root 'python3')
        & chmod +x (Join-Path $root 'python')
      }

      $env:PATH = $root + $pathSeparator + $pathBackup
      $resolution = Resolve-RaymanHostSmokePythonCommand -WorkingDirectory $root

      $resolution.name | Should -Be 'python'
      $resolution.path | Should -Match 'python(\.cmd)?$'
      @($resolution.attempts).Count | Should -BeGreaterOrEqual 2
      @($resolution.attempts)[0].name | Should -Be 'python3'
      @($resolution.attempts)[0].exit_code | Should -Not -Be 0
      @($resolution.attempts)[1].name | Should -Be 'python'
      @($resolution.attempts)[1].exit_code | Should -Be 0
    } finally {
      $env:PATH = $pathBackup
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'host smoke worker loopback coverage' {
  It 'keeps worker loopback steps in the host smoke lane' {
    $scriptPath = Join-Path $script:WorkspaceRoot '.Rayman\scripts\testing\run_host_smoke.ps1'
    $raw = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8

    $raw | Should -Match 'worker_loopback_fixture_build'
    $raw | Should -Match 'worker_loopback_discover'
    $raw | Should -Match 'worker_loopback_use'
    $raw | Should -Match 'worker_loopback_status'
    $raw | Should -Match 'worker_loopback_exec'
    $raw | Should -Match 'worker_loopback_sync_attached'
    $raw | Should -Match 'worker_loopback_sync_staged'
    $raw | Should -Match 'worker_loopback_fixture_stage'
    $raw | Should -Match 'worker_loopback_debug_prepare'
    $raw | Should -Match 'worker_loopback_clear'
    $raw | Should -Match 'generated_at'
  }

  It 'stages the worker smoke fixture before building so source bin and obj are ignored' {
    $dotnet = Get-Command dotnet.exe, dotnet -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $dotnet -or [string]::IsNullOrWhiteSpace([string]$dotnet.Source)) {
      Set-ItResult -Skipped -Because 'dotnet not found'
      return
    }

    $sourceFixtureRoot = Join-Path $script:WorkspaceRoot '.Rayman\scripts\testing\fixtures\worker_smoke_app'
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_fixture_stage_' + [Guid]::NewGuid().ToString('N'))
    $fixtureRoot = Join-Path $tempRoot 'worker_smoke_app'
    $projectPath = Join-Path $fixtureRoot 'WorkerSmokeApp.csproj'
    $fixtureRuntimeRoot = Join-Path $tempRoot 'runtime'
    $stageRoot = Join-Path $fixtureRuntimeRoot 'source'
    $outputDir = Join-Path $fixtureRuntimeRoot 'build'
    $intermediateDir = Join-Path $fixtureRuntimeRoot 'obj'
    $fixtureBin = Join-Path $fixtureRoot 'bin'
    $fixtureObj = Join-Path $fixtureRoot 'obj'
    try {
      New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
      foreach ($child in @(Get-ChildItem -LiteralPath $sourceFixtureRoot -Force -ErrorAction Stop)) {
        Copy-Item -LiteralPath $child.FullName -Destination (Join-Path $fixtureRoot $child.Name) -Recurse -Force
      }
      New-Item -ItemType Directory -Force -Path $fixtureBin | Out-Null
      New-Item -ItemType Directory -Force -Path $fixtureObj | Out-Null
      Set-Content -LiteralPath (Join-Path $fixtureBin 'stale.txt') -Encoding UTF8 -Value 'bin-stale'
      Set-Content -LiteralPath (Join-Path $fixtureObj 'stale.txt') -Encoding UTF8 -Value 'obj-stale'

      $staged = Initialize-RaymanHostSmokeStagedProject -SourceProjectPath $projectPath -StageRoot $stageRoot

      & $dotnet.Source build $staged.staged_project_path -c Debug -nologo -o $outputDir "-p:MSBuildProjectExtensionsPath=$intermediateDir\\" "-p:BaseIntermediateOutputPath=$intermediateDir\\" | Out-Null

      $LASTEXITCODE | Should -Be 0
      $staged.staged_project_path | Should -Not -Be $projectPath
      (Test-Path -LiteralPath (Join-Path $outputDir 'WorkerSmokeApp.dll') -PathType Leaf) | Should -Be $true
      (Test-Path -LiteralPath (Join-Path $stageRoot 'bin') -PathType Container) | Should -Be $false
      (Test-Path -LiteralPath (Join-Path $stageRoot 'obj') -PathType Container) | Should -Be $false
      (Test-Path -LiteralPath (Join-Path $fixtureBin 'stale.txt') -PathType Leaf) | Should -Be $true
      (Test-Path -LiteralPath (Join-Path $fixtureObj 'stale.txt') -PathType Leaf) | Should -Be $true
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'host smoke worker selection' {
  It 'selects the expected loopback worker without returning an empty array placeholder' {
    $workers = @(
      [pscustomobject]@{
        worker_id = 'remote-worker'
        address = '192.168.2.107'
        control_port = 47632
        control_url = 'http://192.168.2.107:47632/'
      }
      [pscustomobject]@{
        worker_id = 'loopback-worker'
        address = '127.0.0.1'
        control_port = 52585
        control_url = 'http://127.0.0.1:52585/'
      }
    )

    $selected = Select-RaymanHostSmokeLoopbackWorker -Workers $workers -ExpectedControlPort 52585

    $selected | Should -Not -BeNullOrEmpty
    [string]$selected.worker_id | Should -Be 'loopback-worker'
  }

  It 'returns null when discover output does not contain a loopback worker' {
    $workers = @(
      [pscustomobject]@{
        worker_id = 'remote-worker'
        address = '192.168.2.107'
        control_port = 47632
        control_url = 'http://192.168.2.107:47632/'
      }
    )

    $selected = Select-RaymanHostSmokeLoopbackWorker -Workers $workers -ExpectedControlPort 52585

    $selected | Should -Be $null
  }
}
