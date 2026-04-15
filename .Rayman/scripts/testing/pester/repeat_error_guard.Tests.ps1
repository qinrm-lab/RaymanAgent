Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  . (Join-Path $script:RepoRoot '.Rayman\common.ps1')
  . (Join-Path $script:RepoRoot '.Rayman\scripts\utils\repeat_error_guard.ps1') -NoMain
}

function script:Write-TestUtf8File {
  param(
    [string]$Path,
    [string]$Content
  )

  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function script:Write-TestJsonFile {
  param(
    [string]$Path,
    [object]$Value
  )

  Write-TestUtf8File -Path $Path -Content ((($Value | ConvertTo-Json -Depth 12).TrimEnd()) + "`n")
}

function script:Initialize-RepeatErrorWorkspace {
  param([string]$Root)

  foreach ($dir in @(
      '.Rayman',
      '.Rayman\context',
      '.Rayman\runtime',
      '.Rayman\runtime\memory',
      '.Rayman\scripts\utils',
      '.Rayman\scripts\repair',
      '.Rayman\scripts\release',
      '.Rayman\scripts\agents'
    )) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Root $dir) | Out-Null
  }

  foreach ($file in @(
      '.Rayman\common.ps1',
      '.Rayman\win-check.ps1',
      '.Rayman\scripts\utils\repeat_error_guard.ps1',
      '.Rayman\scripts\repair\capture_snapshot.ps1',
      '.Rayman\context\repeat-error-catalog.json'
    )) {
    Copy-Item -LiteralPath (Join-Path $script:RepoRoot $file) -Destination (Join-Path $Root $file) -Force
  }

  Write-TestUtf8File -Path (Join-Path $Root '.Rayman\win-preflight.ps1') -Content @'
param([string]$WorkspaceRoot)
'@
  Write-TestUtf8File -Path (Join-Path $Root '.Rayman\scripts\agents\check_agent_contract.ps1') -Content @'
param([string]$WorkspaceRoot)
Write-Host "agent contract ok"
'@
  Write-TestUtf8File -Path (Join-Path $Root '.Rayman\scripts\release\release_gate.ps1') -Content @'
param(
  [string]$WorkspaceRoot,
  [string]$Mode,
  [switch]$AllowNoGit
)
Write-Host "release gate ok"
'@
  Write-TestUtf8File -Path (Join-Path $Root '.Rayman\scripts\release\validate_release_requirements.sh') -Content @'
#!/usr/bin/env bash
exit 0
'@
}

function script:Write-MinimalCurrentConfigReference {
  param(
    [string]$Path,
    [string]$AccountAlias = 'alpha',
    [string]$RepairCommand = 'rayman codex login --alias alpha',
    [string]$HttpProxy = 'http://127.0.0.1:7890',
    [string]$HttpsProxy = 'http://127.0.0.1:7890',
    [string]$AllProxy = 'http://127.0.0.1:7890',
    [string]$NoProxy = 'localhost,127.0.0.1,::1',
    [string]$MemoryBackend = 'lexical',
    [string]$MemoryFallback = 'embedding_model_unavailable:OSError'
  )

  Write-TestUtf8File -Path $Path -Content @"
# Rayman 当前配置参考

## Codex 执行与绑定

- Rayman 绑定账号别名：``$AccountAlias``
- 认证状态：``authenticated``
- 登录方式：``ChatGPT``
- 修复命令基线：``$RepairCommand``

## 代理与网络

- ``http_proxy=$HttpProxy``
- ``https_proxy=$HttpsProxy``
- ``all_proxy=$AllProxy``
- ``no_proxy=$NoProxy``

## Agent Memory 基线

- 当前检索后端：``$MemoryBackend``
- ``deps_ready=false``
- fallback 原因：``$MemoryFallback``
"@
}

Describe 'repeat error guard' {
  It 'detects proxy drift and memory backend regression from the saved baseline' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_repeat_guard_report_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-RepeatErrorWorkspace -Root $root
      Write-MinimalCurrentConfigReference -Path (Join-Path $root '.Rayman\context\current-config-reference.md')
      Write-TestJsonFile -Path (Join-Path $root '.Rayman\runtime\proxy.resolved.json') -Value ([ordered]@{
            source = 'user settings'
            http_proxy = 'http://127.0.0.1:7891'
            https_proxy = 'http://127.0.0.1:7890'
            all_proxy = 'http://127.0.0.1:7892'
            no_proxy = 'localhost,127.0.0.1,::1'
          })
      Write-TestJsonFile -Path (Join-Path $root '.Rayman\runtime\memory\status.json') -Value ([ordered]@{
            schema = 'rayman.agent_memory.status.v1'
            success = $true
            search_backend = 'lexical'
            fallback_reason = 'sentence_transformers_import_failed:ModuleNotFoundError'
            deps_ready = $false
            message = 'Agent Memory search completed'
          })

      $report = Get-RaymanRepeatErrorGuardReport -WorkspaceRoot $root -GuardStage 'rayman.check'
      $ids = @($report.matches | ForEach-Object { [string]$_.signature_id })

      [bool]$report.summary.matched | Should -Be $true
      ($ids -contains 'proxy_baseline_drift') | Should -Be $true
      ($ids -contains 'memory_backend_regression') | Should -Be $true
      [bool]$report.summary.fail_fast | Should -Be $false
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'avoids false positives when runtime state matches the saved baseline' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_repeat_guard_clean_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-RepeatErrorWorkspace -Root $root
      Write-MinimalCurrentConfigReference -Path (Join-Path $root '.Rayman\context\current-config-reference.md')
      Write-TestJsonFile -Path (Join-Path $root '.Rayman\runtime\proxy.resolved.json') -Value ([ordered]@{
            source = 'user settings'
            http_proxy = 'http://127.0.0.1:7890'
            https_proxy = 'http://127.0.0.1:7890'
            all_proxy = 'http://127.0.0.1:7890'
            no_proxy = 'localhost,127.0.0.1,::1'
          })
      Write-TestJsonFile -Path (Join-Path $root '.Rayman\runtime\memory\status.json') -Value ([ordered]@{
            schema = 'rayman.agent_memory.status.v1'
            success = $true
            search_backend = 'lexical'
            fallback_reason = 'embedding_model_unavailable:OSError'
            deps_ready = $false
            message = 'Agent Memory search completed'
          })

      $report = Get-RaymanRepeatErrorGuardReport -WorkspaceRoot $root -GuardStage 'rayman.check'

      [bool]$report.summary.matched | Should -Be $false
      @($report.matches).Count | Should -Be 0
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'writes repeat error matches into error snapshots' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_repeat_guard_snapshot_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-RepeatErrorWorkspace -Root $root
      Write-MinimalCurrentConfigReference -Path (Join-Path $root '.Rayman\context\current-config-reference.md')
      Write-TestUtf8File -Path (Join-Path $root '.Rayman\state\last_error.log') -Content "desktop validation timed out`n"
      Write-TestJsonFile -Path (Join-Path $root '.Rayman\runtime\codex.auth.status.json') -Value ([ordered]@{
            schema = 'rayman.codex.auth.status.v1'
            workspace_root = $root
            account_alias = 'alpha'
            auth_scope = 'desktop_global'
            status = 'desktop_repair_needed'
            authenticated = $false
            repair_command = 'rayman codex login --alias alpha'
            auth_mode_last = 'yunyi'
            auth_mode_detected = 'chatgpt'
            desktop_target_mode = 'yunyi'
            desktop_status_reason = 'config_not_yunyi'
            desktop_status_quota_visible = $false
            latest_native_session = [ordered]@{ available = $false; source = 'none' }
          })

      & (Join-Path $root '.Rayman\scripts\repair\capture_snapshot.ps1') -WorkspaceRoot $root | Out-Null
      $snapshotRaw = Get-Content -LiteralPath (Join-Path $root '.Rayman\state\error_snapshot.md') -Raw -Encoding UTF8

      $snapshotRaw | Should -Match 'signature=`account_mode_mismatch`'
      $snapshotRaw | Should -Match 'rayman codex login --alias alpha'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'blocks win-check when a fail-fast repeat error is present' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_repeat_guard_wincheck_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-RepeatErrorWorkspace -Root $root
      Write-MinimalCurrentConfigReference -Path (Join-Path $root '.Rayman\context\current-config-reference.md')
      Write-TestJsonFile -Path (Join-Path $root '.Rayman\runtime\codex.auth.status.json') -Value ([ordered]@{
            schema = 'rayman.codex.auth.status.v1'
            workspace_root = $root
            account_alias = 'alpha'
            auth_scope = 'desktop_global'
            status = 'desktop_repair_needed'
            authenticated = $false
            repair_command = 'rayman codex login --alias alpha'
            auth_mode_last = 'yunyi'
            auth_mode_detected = 'chatgpt'
            desktop_target_mode = 'yunyi'
            desktop_status_reason = 'config_not_yunyi'
            desktop_status_quota_visible = $false
            latest_native_session = [ordered]@{ available = $false; source = 'none' }
          })

      $caught = $null
      try {
        & (Join-Path $root '.Rayman\win-check.ps1') -WorkspaceRoot $root
      } catch {
        $caught = $_
      }

      $reportPath = Join-Path $root '.Rayman\runtime\repeat_error_guard.last.json'
      if ($null -eq $caught -and (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
        Write-Host "[repeat-error-test] win-check report:"
        Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | Write-Host
      }

      $caught | Should -Not -BeNullOrEmpty
      [string]$caught.Exception.Message | Should -Match 'repeat error guard blocked check'
      (Test-Path -LiteralPath $reportPath -PathType Leaf) | Should -Be $true
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
