BeforeAll {
  . (Join-Path $PSScriptRoot '..\..\..\common.ps1')
  . (Join-Path $PSScriptRoot '..\..\project\project_gate.lib.ps1')
  function Invoke-WithSourceProjectGateStateIsolation {
    param([scriptblock]$Body)

    $sourceRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..') | Select-Object -ExpandProperty Path
    $configPath = Join-Path $sourceRoot '.rayman.project.json'
    $reportPath = Join-Path $sourceRoot '.Rayman\runtime\project_gates\fast.report.json'
    $configBackupPath = ''
    $reportBackupPath = ''

    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
      $configBackupPath = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_project_gate_config_backup_' + [Guid]::NewGuid().ToString('N') + '.json')
      Copy-Item -LiteralPath $configPath -Destination $configBackupPath -Force
      Remove-Item -LiteralPath $configPath -Force
    }

    if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
      $reportBackupPath = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_project_gate_report_backup_' + [Guid]::NewGuid().ToString('N') + '.json')
      Copy-Item -LiteralPath $reportPath -Destination $reportBackupPath -Force
    }

    try {
      & $Body $sourceRoot $configPath
    } finally {
      if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
      }
      if (-not [string]::IsNullOrWhiteSpace($configBackupPath) -and (Test-Path -LiteralPath $configBackupPath -PathType Leaf)) {
        Move-Item -LiteralPath $configBackupPath -Destination $configPath -Force
      }

      if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
        Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue
      }
      if (-not [string]::IsNullOrWhiteSpace($reportBackupPath) -and (Test-Path -LiteralPath $reportBackupPath -PathType Leaf)) {
        Move-Item -LiteralPath $reportBackupPath -Destination $reportPath -Force
      }
    }
  }
}

Describe 'project gate command semantics' {
  It 'marks empty consumer commands as SKIP in source workspaces' {
    $check = New-RaymanProjectGateEmptyCommandCheck -Key 'build' -Name 'Build' -Action 'configure build' -LogPath 'fast.build.log' -WorkspaceKind 'source' -WarnWhenEmpty

    $check.status | Should -Be 'SKIP'
    $check.detail | Should -Be 'source workspace; consumer-only project config not applicable'
    $check.action | Should -Be ''
  }

  It 'keeps empty consumer commands as WARN in external workspaces' {
    $check = New-RaymanProjectGateEmptyCommandCheck -Key 'build' -Name 'Build' -Action 'configure build' -LogPath 'fast.build.log' -WorkspaceKind 'external' -WarnWhenEmpty

    $check.status | Should -Be 'WARN'
    $check.detail | Should -Be 'command not configured'
    $check.action | Should -Be 'configure build'
  }
}

Describe 'project workflow generation' {
  It 'creates managed consumer workflows and project config for external workspaces' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_project_workflow_' + [Guid]::NewGuid().ToString('N'))
    try {
      $sourceRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..') | Select-Object -ExpandProperty Path
      $pathsToCopy = @(
        '.Rayman\common.ps1'
        '.Rayman\scripts\project\project_gate.lib.ps1'
        '.Rayman\scripts\project\generate_project_workflows.ps1'
        '.Rayman\templates\workflows\rayman-project-fast-gate.yml'
        '.Rayman\templates\workflows\rayman-project-browser-gate.yml'
        '.Rayman\templates\workflows\rayman-project-full-gate.yml'
      )

      foreach ($rel in $pathsToCopy) {
        $src = Join-Path $sourceRoot $rel
        $dst = Join-Path $root $rel
        $parent = Split-Path -Parent $dst
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force
      }

      $configPath = Join-Path $root '.rayman.project.json'
      Set-Content -LiteralPath $configPath -Encoding UTF8 -Value @'
{
  "schema": "rayman.project_config.v1",
  "project_name": "RaymanConsumer",
  "build_command": "npm run build",
  "browser_command": "npx playwright test --project chromium",
  "full_gate_command": "npm run ci:full",
  "enable_windows": true,
  "path_filters": {
    "fast": [
      ".Rayman/**",
      "src/**"
    ],
    "browser": [
      "src/**",
      "test-*.js"
    ],
    "full": [
      ".Rayman/**",
      ".github/workflows/**"
    ]
  },
  "extensions": {
    "project_fast_checks": "npm test -- --runInBand",
    "project_browser_checks": "",
    "project_release_checks": "npm run release:check"
  }
}
'@

      & (Join-Path $root '.Rayman\scripts\project\generate_project_workflows.ps1') -WorkspaceRoot $root

      $fastWorkflow = Join-Path $root '.github\workflows\rayman-project-fast-gate.yml'
      $browserWorkflow = Join-Path $root '.github\workflows\rayman-project-browser-gate.yml'
      $fullWorkflow = Join-Path $root '.github\workflows\rayman-project-full-gate.yml'

      foreach ($path in @($fastWorkflow, $browserWorkflow, $fullWorkflow)) {
        Test-Path -LiteralPath $path -PathType Leaf | Should -Be $true
      }

      $fastRaw = Get-Content -LiteralPath $fastWorkflow -Raw -Encoding UTF8
      $browserRaw = Get-Content -LiteralPath $browserWorkflow -Raw -Encoding UTF8
      $fullRaw = Get-Content -LiteralPath $fullWorkflow -Raw -Encoding UTF8

      $fastRaw | Should -Match 'Rayman managed workflow'
      $fastRaw | Should -Match 'fast-gate-windows'
      $fastRaw | Should -Match "'src/\*\*'"
      $browserRaw | Should -Match "'test-\*\.js'"
      $fullRaw | Should -Match 'schedule:'
      $fullRaw | Should -Match 'full-gate-windows'
      $fullRaw | Should -Not -Match '\{\{[A-Z_]+\}\}'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'classifies a workspace with internal workflow and requirements markers as source' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_kind_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\testing') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.RaymanAgent') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.github\workflows') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\testing\run_fast_contract.sh') -Value '#!/usr/bin/env bash' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.RaymanAgent\.RaymanAgent.requirements.md') -Value '# requirements' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.github\workflows\rayman-test-lanes.yml') -Value 'name: rayman-test-lanes' -Encoding UTF8

      Get-RaymanWorkspaceKind -WorkspaceRoot $root | Should -Be 'source'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'run_project_gate fast lane' {
  It 'returns SKIP for empty consumer commands in the source workspace' {
    Invoke-WithSourceProjectGateStateIsolation {
      param($sourceRoot, $configPath)

      $raw = & (Join-Path $sourceRoot '.Rayman\scripts\project\run_project_gate.ps1') -WorkspaceRoot $sourceRoot -Lane fast -Json
      $report = $raw | ConvertFrom-Json
      $configCheck = @($report.checks | Where-Object { $_.key -eq 'project_config' })[0]
      $buildCheck = @($report.checks | Where-Object { $_.key -eq 'build' })[0]
      $smokeCheck = @($report.checks | Where-Object { $_.key -eq 'project_smoke' })[0]

      $configCheck.status | Should -Be 'PASS'
      $buildCheck.status | Should -Be 'SKIP'
      $smokeCheck.status | Should -Be 'SKIP'
      $buildCheck.detail | Should -Be 'source workspace; consumer-only project config not applicable'
      $smokeCheck.detail | Should -Be 'source workspace; consumer-only project config not applicable'
    }
  }

  It 'executes explicitly configured commands in the source workspace' {
    Invoke-WithSourceProjectGateStateIsolation {
      param($sourceRoot, $configPath)

      Set-Content -LiteralPath $configPath -Encoding UTF8 -Value @'
{
  "schema": "rayman.project_config.v1",
  "build_command": "Write-Output 'source-build'",
  "extensions": {
    "project_fast_checks": "Write-Output 'source-smoke'"
  }
}
'@

      $allowBackup = [string][Environment]::GetEnvironmentVariable('RAYMAN_ALLOW_MISSING_BASE_REF')
      $reasonBackup = [string][Environment]::GetEnvironmentVariable('RAYMAN_BYPASS_REASON')
      try {
        [Environment]::SetEnvironmentVariable('RAYMAN_ALLOW_MISSING_BASE_REF', '1')
        [Environment]::SetEnvironmentVariable('RAYMAN_BYPASS_REASON', 'pester-source-fast-lane')

        $raw = & (Join-Path $sourceRoot '.Rayman\scripts\project\run_project_gate.ps1') -WorkspaceRoot $sourceRoot -Lane fast -Json
        $report = $raw | ConvertFrom-Json
        $buildCheck = @($report.checks | Where-Object { $_.key -eq 'build' })[0]
        $smokeCheck = @($report.checks | Where-Object { $_.key -eq 'project_smoke' })[0]

        $buildCheck.status | Should -Be 'PASS'
        $smokeCheck.status | Should -Be 'PASS'
        $buildCheck.command | Should -Be "Write-Output 'source-build'"
        $smokeCheck.command | Should -Be "Write-Output 'source-smoke'"
      } finally {
        [Environment]::SetEnvironmentVariable('RAYMAN_ALLOW_MISSING_BASE_REF', $allowBackup)
        [Environment]::SetEnvironmentVariable('RAYMAN_BYPASS_REASON', $reasonBackup)
      }
    }
  }

  It 'uses bash-safe paths for fast lane shell scripts on Windows' {
    if (-not (Test-RaymanWindowsPlatform)) {
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_project_gate_bash_' + [Guid]::NewGuid().ToString('N'))
    $fakeBashRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_project_gate_fake_bash_' + [Guid]::NewGuid().ToString('N'))
    $bashEnvBackup = [string][Environment]::GetEnvironmentVariable('RAYMAN_BASH_PATH')
    try {
      $sourceRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..') | Select-Object -ExpandProperty Path
      foreach ($rel in @(
        '.Rayman\common.ps1',
        '.Rayman\scripts\project\project_gate.lib.ps1',
        '.Rayman\scripts\project\run_project_gate.ps1'
      )) {
        $src = Join-Path $sourceRoot $rel
        $dst = Join-Path $root $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force
      }

      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\ci') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\release') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.rayman.project.json') -Encoding UTF8 -Value @'
{
  "schema": "rayman.project_config.v1"
}
'@
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\ci\validate_requirements.sh') -Encoding UTF8 -Value @'
#!/usr/bin/env bash
set -euo pipefail
printf requirements-ok
'@
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\release\config_sanity.sh') -Encoding UTF8 -Value @'
#!/usr/bin/env bash
set -euo pipefail
printf config-sanity-ok
'@
      New-Item -ItemType Directory -Force -Path $fakeBashRoot | Out-Null
      Set-Content -LiteralPath (Join-Path $fakeBashRoot 'bash.cmd') -Encoding ASCII -Value @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-bash.ps1" %*
exit /b %ERRORLEVEL%
'@
      Set-Content -LiteralPath (Join-Path $fakeBashRoot 'fake-bash.ps1') -Encoding UTF8 -Value @'
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Rest
)

$commandText = ''
if (@($Rest).Count -ge 2 -and [string]$Rest[0] -eq '-lc') {
  $commandText = (@($Rest[1..(@($Rest).Count - 1)]) -join ' ')
} elseif (@($Rest).Count -ge 4 -and [string]$Rest[0] -eq '-e' -and [string]$Rest[1] -eq 'bash' -and [string]$Rest[2] -eq '-lc') {
  $commandText = (@($Rest[3..(@($Rest).Count - 1)]) -join ' ')
}

Write-Output $commandText
if ($commandText -match 'validate_requirements\.sh') {
  Write-Output 'requirements-ok'
  exit 0
}
if ($commandText -match 'config_sanity\.sh') {
  Write-Output 'config-sanity-ok'
  exit 0
}
Write-Error ("unexpected bash command: {0}" -f $commandText)
exit 19
'@
      [Environment]::SetEnvironmentVariable('RAYMAN_BASH_PATH', (Join-Path $fakeBashRoot 'bash.cmd'))

      $raw = & (Join-Path $root '.Rayman\scripts\project\run_project_gate.ps1') -WorkspaceRoot $root -Lane fast -Json
      $report = $raw | ConvertFrom-Json
      $requirementsCheck = @($report.checks | Where-Object { $_.key -eq 'requirements_layout' })[0]
      $protectedCheck = @($report.checks | Where-Object { $_.key -eq 'protected_assets' })[0]
      $requirementsLog = Get-Content -LiteralPath $requirementsCheck.log_path -Raw -Encoding UTF8
      $protectedLog = Get-Content -LiteralPath $protectedCheck.log_path -Raw -Encoding UTF8

      $requirementsCheck.status | Should -Be 'PASS'
      $protectedCheck.status | Should -Be 'PASS'
      $requirementsLog | Should -Match 'requirements-ok'
      $protectedLog | Should -Match 'config-sanity-ok'
      $requirementsLog | Should -Match '(/mnt/|[A-Za-z]:/)'
      $protectedLog | Should -Match '(/mnt/|[A-Za-z]:/)'
      $requirementsLog | Should -Not -Match 'F:win'
      $protectedLog | Should -Not -Match 'F:win'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_BASH_PATH', $bashEnvBackup)
      Remove-Item -LiteralPath $fakeBashRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'fails missing base refs in fast lane unless the caller explicitly bypasses the requirements gate' {
    if (-not (Test-RaymanWindowsPlatform)) {
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_project_gate_missing_base_' + [Guid]::NewGuid().ToString('N'))
    $fakeBashRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_project_gate_missing_base_bash_' + [Guid]::NewGuid().ToString('N'))
    $envBackup = @{
      RAYMAN_ALLOW_MISSING_BASE_REF = [string][Environment]::GetEnvironmentVariable('RAYMAN_ALLOW_MISSING_BASE_REF')
      RAYMAN_BYPASS_REASON = [string][Environment]::GetEnvironmentVariable('RAYMAN_BYPASS_REASON')
      RAYMAN_BASE_REF = [string][Environment]::GetEnvironmentVariable('RAYMAN_BASE_REF')
      RAYMAN_DIFF_CHECK = [string][Environment]::GetEnvironmentVariable('RAYMAN_DIFF_CHECK')
      RAYMAN_BASH_PATH = [string][Environment]::GetEnvironmentVariable('RAYMAN_BASH_PATH')
    }
    try {
      $sourceRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..') | Select-Object -ExpandProperty Path
      foreach ($rel in @(
        '.Rayman\common.ps1',
        '.Rayman\scripts\project\project_gate.lib.ps1',
        '.Rayman\scripts\project\run_project_gate.ps1'
      )) {
        $src = Join-Path $sourceRoot $rel
        $dst = Join-Path $root $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force
      }

      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\ci') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\release') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\ci\validate_requirements.sh') -Encoding UTF8 -Value @'
#!/usr/bin/env bash
set -euo pipefail
printf requirements-ok
'@
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\release\config_sanity.sh') -Encoding UTF8 -Value @'
#!/usr/bin/env bash
set -euo pipefail
printf config-sanity-ok
'@
      New-Item -ItemType Directory -Force -Path $fakeBashRoot | Out-Null
      Set-Content -LiteralPath (Join-Path $fakeBashRoot 'bash.cmd') -Encoding ASCII -Value @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-bash.ps1" %*
exit /b %ERRORLEVEL%
'@
      Set-Content -LiteralPath (Join-Path $fakeBashRoot 'fake-bash.ps1') -Encoding UTF8 -Value @'
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Rest
)

$commandText = ''
if (@($Rest).Count -ge 2 -and [string]$Rest[0] -eq '-lc') {
  $commandText = (@($Rest[1..(@($Rest).Count - 1)]) -join ' ')
} elseif (@($Rest).Count -ge 4 -and [string]$Rest[0] -eq '-e' -and [string]$Rest[1] -eq 'bash' -and [string]$Rest[2] -eq '-lc') {
  $commandText = (@($Rest[3..(@($Rest).Count - 1)]) -join ' ')
}

Write-Output $commandText
if ($commandText -match 'validate_requirements\.sh') {
  $hasBaseRef = $false
  foreach ($candidate in @('origin/main', 'origin/master', 'main', 'master')) {
    & git rev-parse --verify --quiet $candidate *> $null
    if ($LASTEXITCODE -eq 0) {
      $hasBaseRef = $true
      break
    }
  }

  if ($hasBaseRef) {
    Write-Output 'requirements-ok'
    exit 0
  }

  if ([string]$env:RAYMAN_ALLOW_MISSING_BASE_REF -eq '1' -and -not [string]::IsNullOrWhiteSpace([string]$env:RAYMAN_BYPASS_REASON)) {
    Write-Output ('gate bypass: missing-base-ref reason=' + [string]$env:RAYMAN_BYPASS_REASON)
    exit 0
  }

  [Console]::Error.WriteLine('找不到 base ref：origin/main')
  exit 42
}

if ($commandText -match 'config_sanity\.sh') {
  Write-Output 'config-sanity-ok'
  exit 0
}

Write-Error ('unexpected bash command: ' + $commandText)
exit 19
'@

      & git @('init', '--initial-branch=feature', $root) | Out-Null
      Push-Location $root
      try {
        & git add . | Out-Null
        & git @('-c', 'user.name=Rayman Tests', '-c', 'user.email=rayman@example.com', 'commit', '-m', 'init') | Out-Null

        foreach ($name in @('RAYMAN_ALLOW_MISSING_BASE_REF', 'RAYMAN_BYPASS_REASON', 'RAYMAN_BASE_REF', 'RAYMAN_BASH_PATH')) {
          [Environment]::SetEnvironmentVariable($name, $null)
        }
        [Environment]::SetEnvironmentVariable('RAYMAN_DIFF_CHECK', '1')
        [Environment]::SetEnvironmentVariable('RAYMAN_BASH_PATH', (Join-Path $fakeBashRoot 'bash.cmd'))

        $rawFail = & (Join-Path $root '.Rayman\scripts\project\run_project_gate.ps1') -WorkspaceRoot $root -Lane fast -Json
        $reportFail = $rawFail | ConvertFrom-Json
        $requirementsFail = @($reportFail.checks | Where-Object { $_.key -eq 'requirements_layout' })[0]
        $failLog = Get-Content -LiteralPath $requirementsFail.log_path -Raw -Encoding UTF8

        $requirementsFail.status | Should -Be 'FAIL'
        $failLog | Should -Match '找不到 base ref|missing-base-ref'

        [Environment]::SetEnvironmentVariable('RAYMAN_ALLOW_MISSING_BASE_REF', '1')
        [Environment]::SetEnvironmentVariable('RAYMAN_BYPASS_REASON', 'pester-missing-base-ref')

        $rawBypass = & (Join-Path $root '.Rayman\scripts\project\run_project_gate.ps1') -WorkspaceRoot $root -Lane fast -Json
        $reportBypass = $rawBypass | ConvertFrom-Json
        $requirementsBypass = @($reportBypass.checks | Where-Object { $_.key -eq 'requirements_layout' })[0]
        $bypassLog = Get-Content -LiteralPath $requirementsBypass.log_path -Raw -Encoding UTF8

        $requirementsBypass.status | Should -Be 'PASS'
        $bypassLog | Should -Match 'gate bypass|base ref'
      } finally {
        Pop-Location
      }
    } finally {
      foreach ($name in $envBackup.Keys) {
        [Environment]::SetEnvironmentVariable($name, [string]$envBackup[$name])
      }
      Remove-Item -LiteralPath $fakeBashRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
