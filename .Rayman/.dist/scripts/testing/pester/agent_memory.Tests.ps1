Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  $script:ManageMemory = Join-Path $script:WorkspaceRoot '.Rayman\scripts\memory\manage_memory.ps1'
  $script:ManageMemoryPy = Join-Path $script:WorkspaceRoot '.Rayman\scripts\memory\manage_memory.py'
  $script:RepairScript = Join-Path $script:WorkspaceRoot '.Rayman\scripts\repair\run_tests_and_fix.ps1'
  $script:RuntimeTemp = Join-Path $script:WorkspaceRoot '.Rayman\runtime\memory\test-fixtures'
  $script:PowerShellCmd = @(
    (Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
    (Get-Command powershell -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
    (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1)
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
  $script:PythonCmd = if (Test-Path -LiteralPath (Join-Path $script:WorkspaceRoot '.venv\Scripts\python.exe') -PathType Leaf) {
    (Join-Path $script:WorkspaceRoot '.venv\Scripts\python.exe')
  } else {
    'python'
  }
  if (-not (Test-Path -LiteralPath $script:RuntimeTemp -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $script:RuntimeTemp | Out-Null
  }
}

Describe 'agent memory' {
  It 'emits a valid status payload' {
    $result = & $script:ManageMemory -WorkspaceRoot $script:WorkspaceRoot -Action status -Json | ConvertFrom-Json

    $result.schema | Should -Be 'rayman.agent_memory.status.v1'
    $result.success | Should -Be $true
    [string]::IsNullOrWhiteSpace([string]$result.status_path) | Should -Be $false
  }

  It 'ships Agent Memory schemas and fixtures into the contract validator' {
    $validatorRaw = Get-Content -LiteralPath (Join-Path $script:WorkspaceRoot '.Rayman\scripts\testing\validate_json_contracts.py') -Raw -Encoding UTF8
    $paths = @(
      '.Rayman\scripts\testing\schemas\agent_memory_status.v1.schema.json',
      '.Rayman\scripts\testing\schemas\agent_memory_search_result.v1.schema.json',
      '.Rayman\scripts\testing\schemas\agent_memory_summarize_result.v1.schema.json',
      '.Rayman\scripts\testing\fixtures\reports\agent_memory.status.sample.json',
      '.Rayman\scripts\testing\fixtures\reports\agent_memory.search.sample.json',
      '.Rayman\scripts\testing\fixtures\reports\agent_memory.summarize.sample.json'
    )

    foreach ($relativePath in $paths) {
      Test-Path -LiteralPath (Join-Path $script:WorkspaceRoot $relativePath) | Should -Be $true
    }

    $validatorRaw | Should -Match 'agent_memory_status'
    $validatorRaw | Should -Match 'agent_memory_search_result'
    $validatorRaw | Should -Match 'agent_memory_summarize_result'
  }

  It 'replaces legacy memory wording in the repair summary template' {
    $raw = Get-Content -LiteralPath $script:RepairScript -Raw -Encoding UTF8

    $raw | Should -Match 'Agent Memory'
    $raw | Should -Not -Match ('## 🧠 R' + 'AG')
    $raw | Should -Not -Match ('含 ' + 'R' + 'AG')
    $raw | Should -Not -Match ('R' + 'AG 记忆库')
  }

  It 'removes legacy vector-db tokens from maintenance scripts and stale setup flags from copy smoke' {
    $snapshotPs = Get-Content -LiteralPath (Join-Path $script:WorkspaceRoot '.Rayman\scripts\backup\snapshot_workspace.ps1') -Raw -Encoding UTF8
    $snapshotSh = Get-Content -LiteralPath (Join-Path $script:WorkspaceRoot '.Rayman\scripts\backup\snapshot_workspace.sh') -Raw -Encoding UTF8
    $copySmoke = Get-Content -LiteralPath (Join-Path $script:WorkspaceRoot '.Rayman\scripts\release\copy_smoke.ps1') -Raw -Encoding UTF8
    $trackedNoise = Get-Content -LiteralPath (Join-Path $script:WorkspaceRoot '.Rayman\scripts\release\contract_scm_tracked_noise.sh') -Raw -Encoding UTF8

    $snapshotPs | Should -Match '\.Rayman/state/memory'
    $snapshotSh | Should -Match '\.Rayman/state/memory'
    $snapshotPs | Should -Not -Match ('chroma' + '_' + 'db')
    $snapshotSh | Should -Not -Match ('chroma' + '_' + 'db')
    $snapshotPs | Should -Not -Match ('rag' + '\.db')
    $snapshotSh | Should -Not -Match ('rag' + '\.db')
    $copySmoke | Should -Not -Match ('NoAutoMigrate' + 'Legacy' + 'Rag')
    $trackedNoise | Should -Not -Match ('NoAutoMigrate' + 'Legacy' + 'Rag')
  }
}
