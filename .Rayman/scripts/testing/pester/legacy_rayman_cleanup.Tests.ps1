BeforeAll {
  $script:WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  . (Join-Path $script:WorkspaceRoot '.Rayman\scripts\utils\legacy_rayman_cleanup.ps1') -NoMain
}

Describe 'legacy Rayman workspace cleanup' {
  It 'matches only known root-level legacy Rayman residue names' {
    (Test-RaymanLegacyWorkspaceResidueName -Name '.Rayman.__rayman_workspace_install_old_deadbeef') | Should -Be $true
    (Test-RaymanLegacyWorkspaceResidueName -Name '.Rayman.bak') | Should -Be $true
    (Test-RaymanLegacyWorkspaceResidueName -Name '.Rayman.stage.20260329010404-deadbeef') | Should -Be $true
    (Test-RaymanLegacyWorkspaceTempResidueName -Name 'rayman-dynamic-sandbox') | Should -Be $true
    (Test-RaymanLegacyWorkspaceTempResidueName -Name 'rayman-dynamic-sandbox-20260330') | Should -Be $true
    (Test-RaymanLegacyWorkspaceResidueName -Name '.Rayman') | Should -Be $false
    (Test-RaymanLegacyWorkspaceResidueName -Name '.Rayman.keep') | Should -Be $false
    (Test-RaymanLegacyWorkspaceResidueRelativePath -RelativePath '.Rayman.stage.20260329010404-deadbeef/noise.requirements.md') | Should -Be $true
    (Test-RaymanLegacyWorkspaceResidueRelativePath -RelativePath '.temp/rayman-dynamic-sandbox/agents.md') | Should -Be $true
    (Test-RaymanLegacyWorkspaceResidueRelativePath -RelativePath '.temp/not-rayman/agents.md') | Should -Be $false
    (Test-RaymanLegacyWorkspaceResidueRelativePath -RelativePath 'src/.Rayman.stage.20260329010404-deadbeef/noise.requirements.md') | Should -Be $false
  }

  It 'removes only known legacy Rayman siblings from the workspace root' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_legacy_cleanup_' + [Guid]::NewGuid().ToString('N'))
    try {
      foreach ($path in @(
          (Join-Path $root '.Rayman.__rayman_workspace_install_old_deadbeef'),
          (Join-Path $root '.Rayman.bak'),
          (Join-Path $root '.Rayman.stage.20260329010404-deadbeef'),
          (Join-Path $root '.temp\rayman-dynamic-sandbox'),
          (Join-Path $root '.Rayman'),
          (Join-Path $root '.Rayman.keep'),
          (Join-Path $root '.temp\keep-me'),
          (Join-Path $root 'src\.Rayman.stage.20260329010404-deadbeef')
        )) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
      }

      $report = Invoke-RaymanLegacyWorkspaceCleanup -WorkspaceRoot $root

      [int]$report.removed_count | Should -Be 4
      [int]$report.failed_count | Should -Be 0
      (Test-Path -LiteralPath (Join-Path $root '.Rayman.__rayman_workspace_install_old_deadbeef')) | Should -Be $false
      (Test-Path -LiteralPath (Join-Path $root '.Rayman.bak')) | Should -Be $false
      (Test-Path -LiteralPath (Join-Path $root '.Rayman.stage.20260329010404-deadbeef')) | Should -Be $false
      (Test-Path -LiteralPath (Join-Path $root '.temp\rayman-dynamic-sandbox')) | Should -Be $false
      (Test-Path -LiteralPath (Join-Path $root '.Rayman')) | Should -Be $true
      (Test-Path -LiteralPath (Join-Path $root '.Rayman.keep')) | Should -Be $true
      (Test-Path -LiteralPath (Join-Path $root '.temp\keep-me')) | Should -Be $true
      (Test-Path -LiteralPath (Join-Path $root 'src\.Rayman.stage.20260329010404-deadbeef')) | Should -Be $true
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
