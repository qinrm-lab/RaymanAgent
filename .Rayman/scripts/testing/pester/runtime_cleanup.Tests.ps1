BeforeAll {
  $script:WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  . (Join-Path $script:WorkspaceRoot '.Rayman\scripts\utils\runtime_cleanup.ps1') -NoMain
}

Describe 'runtime cleanup helper' {
  It 'preserves the active staged root during cache-clear cleanup and writes a summary' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_runtime_cleanup_cache_' + [Guid]::NewGuid().ToString('N'))
    try {
      $keepStage = Join-Path $root '.Rayman\runtime\worker\staging\keep-stage'
      $dropStage = Join-Path $root '.Rayman\runtime\worker\staging\drop-stage'
      $syncTemp = Join-Path $root '.Rayman\runtime\worker\sync-temp\sync-a'
      $upload = Join-Path $root '.Rayman\runtime\worker\uploads\upload-a'
      $upgrade = Join-Path $root '.Rayman\runtime\worker\upgrade-temp\upgrade-a'
      $bats = Join-Path $root '.Rayman\runtime\bats_maui\fixture-a'

      foreach ($path in @(
          $keepStage,
          $dropStage,
          $syncTemp,
          $upload,
          $upgrade,
          $bats,
          (Join-Path $root '.Rayman\state\workers')
        )) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
      }

      $activePayload = [pscustomobject]@{
        worker_id = 'worker-a'
        workspace_mode = 'staged'
        sync_manifest = [pscustomobject]@{
          mode = 'staged'
          staging_root = $keepStage
        }
      }
      Write-RaymanRuntimeCleanupJsonFile -Path (Join-Path $root '.Rayman\state\workers\active.json') -Value $activePayload -Depth 6

      $report = Invoke-RaymanRuntimeCleanup -WorkspaceRoot $root -Mode 'cache-clear' -WriteSummary
      $summaryPath = Get-RaymanRuntimeCleanupSummaryPath -WorkspaceRoot $root
      $summary = Read-RaymanRuntimeCleanupJsonFile -Path $summaryPath

      Test-Path -LiteralPath $keepStage -PathType Container | Should -Be $true
      Test-Path -LiteralPath $dropStage | Should -Be $false
      Test-Path -LiteralPath $syncTemp | Should -Be $false
      Test-Path -LiteralPath $upload | Should -Be $false
      Test-Path -LiteralPath $upgrade | Should -Be $false
      Test-Path -LiteralPath $bats | Should -Be $false
      $report.preserved_count | Should -Be 1
      $summary.mode | Should -Be 'cache-clear'
      @($summary.preserved | Where-Object { $_.path -eq '.Rayman/runtime/worker/staging/keep-stage' }).Count | Should -Be 1
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'prunes expired transient data and retains only the newest nested migration backup during workspace cleanup' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_runtime_cleanup_workspace_' + [Guid]::NewGuid().ToString('N'))
    try {
      $oldStage = Join-Path $root '.Rayman\runtime\worker\staging\old-stage'
      $freshStage = Join-Path $root '.Rayman\runtime\worker\staging\fresh-stage'
      $oldBats = Join-Path $root '.Rayman\runtime\bats_maui\old-fixture'
      $migrationRoot = Join-Path $root '.Rayman\runtime\migration'
      $oldBackup = Join-Path $migrationRoot 'nested_rayman_old'
      $newBackup = Join-Path $migrationRoot 'nested_rayman_new'

      foreach ($path in @($oldStage, $freshStage, $oldBats, $oldBackup, $newBackup)) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
      }

      $oldTime = (Get-Date).AddDays(-30)
      $freshTime = (Get-Date).AddDays(-2)
      foreach ($path in @($oldStage, $oldBats, $oldBackup)) {
        (Get-Item -LiteralPath $path -Force).LastWriteTime = $oldTime
      }
      foreach ($path in @($freshStage, $newBackup)) {
        (Get-Item -LiteralPath $path -Force).LastWriteTime = $freshTime
      }

      $report = Invoke-RaymanRuntimeCleanup -WorkspaceRoot $root -Mode 'workspace-clean' -KeepDays 14

      Test-Path -LiteralPath $oldStage | Should -Be $false
      Test-Path -LiteralPath $oldBats | Should -Be $false
      Test-Path -LiteralPath $oldBackup | Should -Be $false
      Test-Path -LiteralPath $freshStage -PathType Container | Should -Be $true
      Test-Path -LiteralPath $newBackup -PathType Container | Should -Be $true
      $report.removed_count | Should -Be 3
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'keeps copy-smoke cleanup scoped to the workspace unless external temp cleanup is enabled' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_runtime_cleanup_scope_' + [Guid]::NewGuid().ToString('N'))
    $external = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_copy_smoke_' + [Guid]::NewGuid().ToString('N'))
    $powershellHost = (Get-Command powershell.exe -ErrorAction Stop).Source
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      New-Item -ItemType Directory -Force -Path $external | Out-Null

      $cleanScript = Join-Path $root '.Rayman\scripts\utils\clean_workspace.ps1'
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cleanScript) | Out-Null
      Copy-Item -LiteralPath (Join-Path $script:WorkspaceRoot '.Rayman\scripts\utils\clean_workspace.ps1') -Destination $cleanScript -Force
      Copy-Item -LiteralPath (Join-Path $script:WorkspaceRoot '.Rayman\scripts\utils\runtime_cleanup.ps1') -Destination (Join-Path $root '.Rayman\scripts\utils\runtime_cleanup.ps1') -Force

      & $powershellHost -NoProfile -ExecutionPolicy Bypass -File $cleanScript -WorkspaceRoot $root -KeepDays 0 -DryRun 0 -CopySmokeArtifacts 1 -AllowExternalTemp 0 | Out-Null

      Test-Path -LiteralPath $external -PathType Container | Should -Be $true
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $external -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'uses setup-prune to delete transient worker directories while preserving the active staged root' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_runtime_cleanup_setup_' + [Guid]::NewGuid().ToString('N'))
    try {
      $keepStage = Join-Path $root '.Rayman\runtime\worker\staging\keep-stage'
      $dropStage = Join-Path $root '.Rayman\runtime\worker\staging\drop-stage'
      $syncTemp = Join-Path $root '.Rayman\runtime\worker\sync-temp\sync-a'
      $upload = Join-Path $root '.Rayman\runtime\worker\uploads\upload-a'
      $upgrade = Join-Path $root '.Rayman\runtime\worker\upgrade-temp\upgrade-a'
      $migrationRoot = Join-Path $root '.Rayman\runtime\migration'
      $oldBackup = Join-Path $migrationRoot 'nested_rayman_old'
      $newBackup = Join-Path $migrationRoot 'nested_rayman_new'

      foreach ($path in @(
          $keepStage,
          $dropStage,
          $syncTemp,
          $upload,
          $upgrade,
          $oldBackup,
          $newBackup,
          (Join-Path $root '.Rayman\state\workers')
        )) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
      }

      $oldTime = (Get-Date).AddDays(-30)
      $newTime = (Get-Date).AddDays(-1)
      (Get-Item -LiteralPath $oldBackup -Force).LastWriteTime = $oldTime
      (Get-Item -LiteralPath $newBackup -Force).LastWriteTime = $newTime

      $activePayload = [pscustomobject]@{
        worker_id = 'worker-a'
        workspace_mode = 'staged'
        sync_manifest = [pscustomobject]@{
          mode = 'staged'
          staging_root = $keepStage
        }
      }
      Write-RaymanRuntimeCleanupJsonFile -Path (Join-Path $root '.Rayman\state\workers\active.json') -Value $activePayload -Depth 6

      $report = Invoke-RaymanRuntimeCleanup -WorkspaceRoot $root -Mode 'setup-prune'

      Test-Path -LiteralPath $keepStage -PathType Container | Should -Be $true
      Test-Path -LiteralPath $dropStage | Should -Be $false
      Test-Path -LiteralPath $syncTemp | Should -Be $false
      Test-Path -LiteralPath $upload | Should -Be $false
      Test-Path -LiteralPath $upgrade | Should -Be $false
      Test-Path -LiteralPath $oldBackup | Should -Be $false
      Test-Path -LiteralPath $newBackup -PathType Container | Should -Be $true
      @($report.preserved | Where-Object { $_.path -eq '.Rayman/runtime/worker/staging/keep-stage' }).Count | Should -Be 1
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'uses post-command cleanup to remove fresh transient residue while preserving logs and current evidence' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_runtime_cleanup_post_command_' + [Guid]::NewGuid().ToString('N'))
    try {
      $keepStage = Join-Path $root '.Rayman\runtime\worker\staging\keep-stage'
      $dropStage = Join-Path $root '.Rayman\runtime\worker\staging\drop-stage'
      $syncTemp = Join-Path $root '.Rayman\runtime\worker\sync-temp\sync-a'
      $upload = Join-Path $root '.Rayman\runtime\worker\uploads\upload-a'
      $upgrade = Join-Path $root '.Rayman\runtime\worker\upgrade-temp\upgrade-a'
      $bats = Join-Path $root '.Rayman\runtime\bats_maui\fixture-a'
      $runtimeTmp = Join-Path $root '.Rayman\runtime\tmp\run-a'
      $hostSmokeReport = Join-Path $root '.Rayman\runtime\test_lanes\host_smoke.report.json'
      $logPath = Join-Path $root '.Rayman\logs\setup.log'

      foreach ($path in @(
          $keepStage,
          $dropStage,
          $syncTemp,
          $upload,
          $upgrade,
          $bats,
          $runtimeTmp,
          (Join-Path $root '.Rayman\state\workers'),
          (Split-Path -Parent $hostSmokeReport),
          (Split-Path -Parent $logPath)
        )) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
      }

      Set-Content -LiteralPath $hostSmokeReport -Encoding UTF8 -Value '{"overall":"PASS"}'
      Set-Content -LiteralPath $logPath -Encoding UTF8 -Value 'keep-log'

      $activePayload = [pscustomobject]@{
        worker_id = 'worker-a'
        workspace_mode = 'staged'
        sync_manifest = [pscustomobject]@{
          mode = 'staged'
          staging_root = $keepStage
        }
      }
      Write-RaymanRuntimeCleanupJsonFile -Path (Join-Path $root '.Rayman\state\workers\active.json') -Value $activePayload -Depth 6

      $report = Invoke-RaymanRuntimeCleanup -WorkspaceRoot $root -Mode 'post-command'

      Test-Path -LiteralPath $keepStage -PathType Container | Should -Be $true
      Test-Path -LiteralPath $dropStage | Should -Be $false
      Test-Path -LiteralPath $syncTemp | Should -Be $false
      Test-Path -LiteralPath $upload | Should -Be $false
      Test-Path -LiteralPath $upgrade | Should -Be $false
      Test-Path -LiteralPath $bats | Should -Be $false
      Test-Path -LiteralPath $runtimeTmp | Should -Be $false
      Test-Path -LiteralPath $hostSmokeReport -PathType Leaf | Should -Be $true
      Test-Path -LiteralPath $logPath -PathType Leaf | Should -Be $true
      @($report.preserved | Where-Object { $_.path -eq '.Rayman/runtime/worker/staging/keep-stage' }).Count | Should -Be 1
      @($report.planned_removals | Where-Object { $_.path -eq '.Rayman/runtime/tmp/run-a' }).Count | Should -Be 1
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'deduplicates cache-clear candidates and skips excluded .Rayman/.dist cache segments' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_runtime_cleanup_dedupe_' + [Guid]::NewGuid().ToString('N'))
    try {
      $ragRoot = Join-Path $root '.rag'
      $binDir = Join-Path $root 'src\DemoApp\bin'
      $objDir = Join-Path $root 'src\DemoApp\obj'
      $distBin = Join-Path $root '.Rayman\.dist\bin'
      $sandboxNodeModules = Join-Path $root '.Rayman\runtime\windows-sandbox\cache\node-runtime\node_modules'
      $latestMigrationBin = Join-Path $root '.Rayman\runtime\migration\nested_rayman_keep\DeleteDir\bin'

      foreach ($path in @($ragRoot, $binDir, $objDir, $distBin, $sandboxNodeModules, $latestMigrationBin)) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
      }

      $report = Invoke-RaymanRuntimeCleanup -WorkspaceRoot $root -Mode 'cache-clear' -DryRun
      $candidatePaths = @($report.planned_removals | ForEach-Object { [string]$_.path })

      @($candidatePaths | Where-Object { $_ -eq '.rag' }).Count | Should -Be 1
      $candidatePaths | Should -Contain 'src/DemoApp/bin'
      $candidatePaths | Should -Contain 'src/DemoApp/obj'
      $candidatePaths | Should -Not -Contain '.Rayman/.dist/bin'
      $candidatePaths | Should -Not -Contain '.Rayman/runtime/windows-sandbox/cache/node-runtime/node_modules'
      $candidatePaths | Should -Not -Contain '.Rayman/runtime/migration/nested_rayman_keep/DeleteDir/bin'
      @($report.preserved | Where-Object { $_.path -eq '.Rayman/runtime/migration/nested_rayman_keep' }).Count | Should -Be 1
      @($candidatePaths | Select-Object -Unique).Count | Should -Be $candidatePaths.Count
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
