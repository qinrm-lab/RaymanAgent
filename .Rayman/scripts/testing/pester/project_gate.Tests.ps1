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
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
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
      $buildCheck = @($report.checks | Where-Object { $_.key -eq 'build' })[0]
      $smokeCheck = @($report.checks | Where-Object { $_.key -eq 'project_smoke' })[0]

      $report.overall | Should -Be 'PASS'
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
  "build_command": "printf source-build",
  "extensions": {
    "project_fast_checks": "printf source-smoke"
  }
}
'@

      $raw = & (Join-Path $sourceRoot '.Rayman\scripts\project\run_project_gate.ps1') -WorkspaceRoot $sourceRoot -Lane fast -Json
      $report = $raw | ConvertFrom-Json
      $buildCheck = @($report.checks | Where-Object { $_.key -eq 'build' })[0]
      $smokeCheck = @($report.checks | Where-Object { $_.key -eq 'project_smoke' })[0]

      $buildCheck.status | Should -Be 'PASS'
      $smokeCheck.status | Should -Be 'PASS'
      $buildCheck.command | Should -Be 'printf source-build'
      $smokeCheck.command | Should -Be 'printf source-smoke'
    }
  }
}
