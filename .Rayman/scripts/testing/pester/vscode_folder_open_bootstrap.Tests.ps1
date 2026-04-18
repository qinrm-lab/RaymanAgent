. (Join-Path $PSScriptRoot '..\..\..\common.ps1')

Describe 'vscode folder open bootstrap fingerprinting' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
    . (Join-Path $PSScriptRoot '..\..\workspace\install_workspace.ps1') -NoMain
    . (Join-Path $PSScriptRoot '..\..\watch\vscode_folder_open_bootstrap.ps1') -NoMain
  }

  It 'ignores temp, legacy Rayman residue, and runtime requirement noise while tracking real inputs' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_bootstrap_fp_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.tmp') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman.bak') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman.__rayman_workspace_install_old_deadbeef') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman.stage.20260329010303-deadbeef') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime') | Out-Null
      Set-Content -LiteralPath (Join-Path $root 'AGENTS.md') -Encoding UTF8 -Value '# test'
      Set-Content -LiteralPath (Join-Path $root 'real.requirements.md') -Encoding UTF8 -Value 'real-v1'
      Set-Content -LiteralPath (Join-Path $root '.tmp\noise.requirements.md') -Encoding UTF8 -Value 'tmp-v1'
      Set-Content -LiteralPath (Join-Path $root '.Rayman.bak\noise.requirements.md') -Encoding UTF8 -Value 'bak-v1'
      Set-Content -LiteralPath (Join-Path $root '.Rayman.__rayman_workspace_install_old_deadbeef\noise.requirements.md') -Encoding UTF8 -Value 'old-v1'
      Set-Content -LiteralPath (Join-Path $root '.Rayman.stage.20260329010303-deadbeef\noise.requirements.md') -Encoding UTF8 -Value 'stage-v1'
      Set-Content -LiteralPath (Join-Path $root '.Rayman\runtime\noise.requirements.md') -Encoding UTF8 -Value 'runtime-v1'

      $before = Get-ContextRefreshFingerprint -Root $root

      Set-Content -LiteralPath (Join-Path $root '.tmp\noise.requirements.md') -Encoding UTF8 -Value 'tmp-v2'
      Set-Content -LiteralPath (Join-Path $root '.Rayman.bak\noise.requirements.md') -Encoding UTF8 -Value 'bak-v2'
      Set-Content -LiteralPath (Join-Path $root '.Rayman.__rayman_workspace_install_old_deadbeef\noise.requirements.md') -Encoding UTF8 -Value 'old-v2'
      Set-Content -LiteralPath (Join-Path $root '.Rayman.stage.20260329010303-deadbeef\noise.requirements.md') -Encoding UTF8 -Value 'stage-v2'
      Set-Content -LiteralPath (Join-Path $root '.Rayman\runtime\noise.requirements.md') -Encoding UTF8 -Value 'runtime-v2'
      $ignoredChange = Get-ContextRefreshFingerprint -Root $root

      Set-Content -LiteralPath (Join-Path $root 'real.requirements.md') -Encoding UTF8 -Value 'real-v2'
      $realChange = Get-ContextRefreshFingerprint -Root $root

      $before | Should -Be $ignoredChange
      $realChange | Should -Not -Be $before
      (Test-ContextRefreshFingerprintPath -Root $root -CandidatePath (Join-Path $root '.tmp\noise.requirements.md')) | Should -Be $false
      (Test-ContextRefreshFingerprintPath -Root $root -CandidatePath (Join-Path $root '.Rayman.__rayman_workspace_install_old_deadbeef\noise.requirements.md')) | Should -Be $false
      (Test-ContextRefreshFingerprintPath -Root $root -CandidatePath (Join-Path $root '.Rayman.stage.20260329010303-deadbeef\noise.requirements.md')) | Should -Be $false
      (Test-ContextRefreshFingerprintPath -Root $root -CandidatePath (Join-Path $root 'real.requirements.md')) | Should -Be $true
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'uses the shared watcher bootstrap instead of detached attention helpers' {
    $raw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\watch\vscode_folder_open_bootstrap.ps1') -Raw -Encoding UTF8

    $raw | Should -Match 'start_background_watchers\.ps1'
    $raw | Should -Not -Match 'attention_watch\.ps1'
    $raw | Should -Not -Match 'ensure_attention_watch\.ps1'
  }

  It 're-applies the bound Codex alias during folder-open bootstrap' {
    $raw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\watch\vscode_folder_open_bootstrap.ps1') -Raw -Encoding UTF8

    $raw | Should -Match 'manage_accounts\.ps1'
    $raw | Should -Match 'codex-binding-auto-apply'
    $raw | Should -Match 'Invoke-RaymanCodexWorkspaceBindingAutoApply'
  }

  It 'skips folder-open work while an auto-upgrade lock is active' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_bootstrap_lock_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null
      Write-RaymanWorkspaceInstallAutoUpgradeLock -WorkspaceRoot $root -Mode 'auto_on_open' -SourceWorkspaceRoot $script:RepoRoot -PublishedVersion 'v-lock' -PublishedFingerprint 'fingerprint-lock' | Out-Null

      $pwsh = Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($null -eq $pwsh -or [string]::IsNullOrWhiteSpace([string]$pwsh.Source)) {
        $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
      }
      if ($null -eq $pwsh -or [string]::IsNullOrWhiteSpace([string]$pwsh.Source)) {
        throw 'PowerShell host not available for bootstrap test.'
      }

      & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RepoRoot '.Rayman\scripts\watch\vscode_folder_open_bootstrap.ps1') -WorkspaceRoot $root
      $LASTEXITCODE | Should -Be 0

      $report = Get-Content -LiteralPath (Join-Path $root '.Rayman\runtime\vscode_bootstrap.last.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      [string]$report.steps[0].name | Should -Be 'wait-for-auto-upgrade'
      [string]$report.steps[0].reason | Should -Be 'auto-upgrade-in-progress'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
