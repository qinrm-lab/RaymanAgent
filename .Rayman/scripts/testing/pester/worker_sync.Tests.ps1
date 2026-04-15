BeforeAll {
  $script:WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  . (Join-Path $script:WorkspaceRoot '.Rayman\scripts\worker\worker_sync.ps1') -NoMain
}

Describe 'worker staged sync bundle' {
  It 'excludes workspace-local noise and gitignored files from the bundle manifest' {
    $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $git -or [string]::IsNullOrWhiteSpace([string]$git.Source)) {
      Set-ItResult -Skipped -Because 'git not found'
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_sync_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\testing') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.github\workflows') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.codex') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\release') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.vscode') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root 'src') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root 'notes') | Out-Null

      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\testing\run_fast_contract.sh') -Encoding UTF8 -Value 'echo ready'
      Set-Content -LiteralPath (Join-Path $root '.github\workflows\rayman-test-lanes.yml') -Encoding UTF8 -Value "name: test`n"
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
      Set-Content -LiteralPath (Join-Path $root '.gitignore') -Encoding UTF8 -Value "*.secret`n"
      Set-Content -LiteralPath (Join-Path $root '.env') -Encoding UTF8 -Value 'top-secret'
      Set-Content -LiteralPath (Join-Path $root '.codex\config.toml') -Encoding UTF8 -Value 'api_key = "secret"'
      Set-Content -LiteralPath (Join-Path $root '.Rayman\release\rayman-v161.zip') -Encoding UTF8 -Value 'zip'
      Set-Content -LiteralPath (Join-Path $root '.vscode\tasks.json') -Encoding UTF8 -Value '{}'
      Set-Content -LiteralPath (Join-Path $root 'src\app.txt') -Encoding UTF8 -Value 'keep me'
      Set-Content -LiteralPath (Join-Path $root 'notes\local.txt') -Encoding UTF8 -Value 'keep me too'
      Set-Content -LiteralPath (Join-Path $root 'debug.secret') -Encoding UTF8 -Value 'ignore me'

      & $git.Source -C $root init | Out-Null
      $LASTEXITCODE | Should -Be 0

      $bundle = New-RaymanWorkerSyncBundle -WorkspaceRoot $root
      $files = @($bundle.manifest.files)

      [string]$bundle.manifest.fingerprint | Should -Match '^[0-9a-f]{64}$'
      $files | Should -Contain 'src/app.txt'
      $files | Should -Contain 'notes/local.txt'
      $files | Should -Not -Contain '.env'
      $files | Should -Not -Contain '.codex/config.toml'
      $files | Should -Not -Contain '.Rayman/release/rayman-v161.zip'
      $files | Should -Not -Contain '.vscode/tasks.json'
      $files | Should -Not -Contain 'debug.secret'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'changes fingerprints only when staged bundle inputs change' {
    $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $git -or [string]::IsNullOrWhiteSpace([string]$git.Source)) {
      Set-ItResult -Skipped -Because 'git not found'
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_fingerprint_' + [Guid]::NewGuid().ToString('N'))
    try {
      foreach ($path in @(
          (Join-Path $root '.Rayman\scripts\testing'),
          (Join-Path $root '.Rayman\runtime\workers'),
          (Join-Path $root '.github\workflows'),
          (Join-Path $root 'src')
        )) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
      }

      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\testing\run_fast_contract.sh') -Encoding UTF8 -Value 'echo ready'
      Set-Content -LiteralPath (Join-Path $root '.github\workflows\rayman-test-lanes.yml') -Encoding UTF8 -Value "name: test`n"
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
      Set-Content -LiteralPath (Join-Path $root '.gitignore') -Encoding UTF8 -Value "*.secret`n"
      Set-Content -LiteralPath (Join-Path $root 'src\app.txt') -Encoding UTF8 -Value 'alpha'
      Set-Content -LiteralPath (Join-Path $root '.env') -Encoding UTF8 -Value 'secret-a'
      Set-Content -LiteralPath (Join-Path $root 'ignored.secret') -Encoding UTF8 -Value 'skip-a'
      Set-Content -LiteralPath (Join-Path $root '.Rayman\runtime\workers\auto_sync.last.json') -Encoding UTF8 -Value '{}'

      & $git.Source -C $root init | Out-Null
      $LASTEXITCODE | Should -Be 0

      $first = Get-RaymanWorkerSyncFingerprintInfo -WorkspaceRoot $root
      Start-Sleep -Milliseconds 20
      Set-Content -LiteralPath (Join-Path $root '.env') -Encoding UTF8 -Value 'secret-b'
      Set-Content -LiteralPath (Join-Path $root 'ignored.secret') -Encoding UTF8 -Value 'skip-b'
      Set-Content -LiteralPath (Join-Path $root '.Rayman\runtime\workers\auto_sync.last.json') -Encoding UTF8 -Value '{"status":"idle"}'
      $second = Get-RaymanWorkerSyncFingerprintInfo -WorkspaceRoot $root
      Start-Sleep -Milliseconds 20
      Set-Content -LiteralPath (Join-Path $root 'src\app.txt') -Encoding UTF8 -Value 'beta'
      $third = Get-RaymanWorkerSyncFingerprintInfo -WorkspaceRoot $root

      $included = @($first.entries | ForEach-Object { [string]$_.relative })
      $included | Should -Contain 'src/app.txt'
      $included | Should -Not -Contain '.env'
      $included | Should -Not -Contain 'ignored.secret'
      $included | Should -Not -Contain '.Rayman/runtime/workers/auto_sync.last.json'
      $second.fingerprint | Should -Be $first.fingerprint
      $third.fingerprint | Should -Not -Be $first.fingerprint
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
