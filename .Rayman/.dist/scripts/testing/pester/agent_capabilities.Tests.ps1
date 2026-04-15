BeforeAll {
  $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..') | Select-Object -ExpandProperty Path
  . (Join-Path $script:RepoRoot '.Rayman\common.ps1')
  . (Join-Path $script:RepoRoot '.Rayman\scripts\agents\agent_asset_manifest.ps1')
}

Describe 'agent capability path normalization' {
  It 'treats Windows and WSL workspace roots as equivalent' {
    Test-RaymanPathsEquivalent -LeftPath 'E:\rayman\software\RaymanAgent' -RightPath '/mnt/e/rayman/software/RaymanAgent' | Should -Be $true
    Test-RaymanPathsEquivalent -LeftPath 'Microsoft.PowerShell.Core\FileSystem::E:\rayman\software\RaymanAgent' -RightPath '/mnt/e/rayman/software/RaymanAgent' | Should -Be $true
  }

  It 'accepts WSL-style report roots for the same Windows workspace' {
    $report = [pscustomobject]@{
      workspace_root = '/mnt/e/rayman/software/RaymanAgent'
    }

    Test-RaymanReportWorkspaceMatchesRoot -Report $report -WorkspaceRoot 'E:\rayman\software\RaymanAgent' | Should -Be $true
  }
}

Describe 'agent capability report contracts' {
  It 'reports runtime host, managed slices, and managed asset presence' {
    $scriptPath = Join-Path $script:RepoRoot '.Rayman\scripts\agents\ensure_agent_capabilities.ps1'
    $jsonText = & $scriptPath -Action status -WorkspaceRoot $script:RepoRoot -Json
    $report = $jsonText | ConvertFrom-Json

    $report.schema | Should -Be 'rayman.agent_capabilities.report.v1'
    $report.codex_runtime_host_source | Should -Be 'vscode_setting'
    $report.codex_runtime_host | Should -Be 'windows'
    $report.path_normalization_status | Should -Match '^(native|windows_wsl_equivalent)$'
    (($report.PSObject.Properties.Name) -contains 'project_profiles_written') | Should -Be $true
    (($report.PSObject.Properties.Name) -contains 'subagents_written') | Should -Be $true
    $report.custom_agents_present | Should -Be $true
    $report.skills_present | Should -Be $true
    $report.multi_agent_trust_assumption | Should -Not -BeNullOrEmpty
    ((@($report.managed_slices.PSObject.Properties.Name) -contains 'notify')) | Should -Be $true
    ((@($report.managed_slices.PSObject.Properties.Name) -contains 'profiles')) | Should -Be $true
    ((@($report.managed_slices.PSObject.Properties.Name) -contains 'project_doc')) | Should -Be $true
    ((@($report.managed_slices.PSObject.Properties.Name) -contains 'subagents')) | Should -Be $true
    $report.managed_slices.notify.support_reason | Should -Be 'rayman_managed'
    $report.managed_slices.profiles.support_source | Should -Not -BeNullOrEmpty
    $report.managed_slices.project_doc.support_reason | Should -Not -BeNullOrEmpty
    $report.managed_slices.subagents.support_source | Should -Not -BeNullOrEmpty
    $report.playwright.current_host | Should -Be 'windows'
    $report.playwright.effective_host | Should -Be 'windows'
    $report.winapp.current_host | Should -Be 'windows'
    $report.winapp.effective_host | Should -Be 'windows'
  }

  It 'can probe codex capabilities under an isolated CODEX_HOME' {
    $scriptPath = Join-Path $script:RepoRoot '.Rayman\scripts\agents\ensure_agent_capabilities.ps1'
    $tempCodexHome = Join-Path $script:RepoRoot ('.Rayman\runtime\tmp\agent_capabilities_test_' + [Guid]::NewGuid().ToString('N'))
    $previousCodexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME')
    try {
      New-Item -ItemType Directory -Force -Path $tempCodexHome | Out-Null
      [Environment]::SetEnvironmentVariable('CODEX_HOME', $tempCodexHome)

      $jsonText = & $scriptPath -Action status -WorkspaceRoot $script:RepoRoot -Json
      $report = $jsonText | ConvertFrom-Json

      $report.schema | Should -Be 'rayman.agent_capabilities.report.v1'
      $report.codex_available | Should -Be $true
    } finally {
      [Environment]::SetEnvironmentVariable('CODEX_HOME', $previousCodexHome)
      Remove-Item -LiteralPath $tempCodexHome -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'writes the managed notify block into the workspace codex config on sync' {
    $scriptPath = Join-Path $script:RepoRoot '.Rayman\scripts\agents\ensure_agent_capabilities.ps1'
    $webAutoBackup = [Environment]::GetEnvironmentVariable('RAYMAN_AGENT_CAP_WEB_AUTO_TEST_ENABLED')
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_AGENT_CAP_WEB_AUTO_TEST_ENABLED', '0')
      $jsonText = & $scriptPath -Action sync -WorkspaceRoot $script:RepoRoot -Json
      $report = $jsonText | ConvertFrom-Json
      $configRaw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.codex\config.toml') -Raw -Encoding UTF8

      $report.schema | Should -Be 'rayman.agent_capabilities.report.v1'
      $report.notify_managed_block_present | Should -Be $true
      $configRaw | Should -Match '# >>> Rayman managed notify >>>'
      $configRaw | Should -Match '(?m)^notify = \['
      $configRaw | Should -Match 'codex_notify\.ps1'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_AGENT_CAP_WEB_AUTO_TEST_ENABLED', $webAutoBackup)
    }
  }
}

Describe 'prompt routing contracts' {
  It 'maps review prompt keys to real prompt files' {
    $routingPath = Join-Path $script:RepoRoot '.Rayman\config\model_routing.json'
    $routing = Get-Content -LiteralPath $routingPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $promptDir = Join-Path $script:RepoRoot '.github\prompts'
    $promptFiles = @(Get-ChildItem -LiteralPath $promptDir -Filter '*.prompt.md' -File | ForEach-Object { $_.Name })
    $expectedPromptKeys = @(Get-RaymanReviewPromptManifest | ForEach-Object { [string]$_.key })
    $reviewPromptKeys = @($routing.tasks.review.prompt_keys)
    $promptRouteKeys = @($routing.prompt_routes.PSObject.Properties.Name)

    $reviewPromptKeys.Count | Should -BeGreaterThan 0
    (($reviewPromptKeys | Sort-Object) -join ',') | Should -Be (($expectedPromptKeys | Sort-Object) -join ',')
    (($promptRouteKeys | Sort-Object) -join ',') | Should -Be (($reviewPromptKeys | Sort-Object) -join ',')
    foreach ($promptKey in $reviewPromptKeys) {
      (($promptFiles -contains $promptKey)) | Should -Be $true
    }
  }
}

Describe 'agent contract script' {
  It 'passes with the managed agent assets and Codex config slices' {
    $scriptPath = Join-Path $script:RepoRoot '.Rayman\scripts\agents\check_agent_contract.ps1'
    $result = & $scriptPath -WorkspaceRoot $script:RepoRoot -AsJson -SkipContextRefresh | ConvertFrom-Json

    $result.passed | Should -Be $true
    $result.failureCount | Should -Be 0
  }
}
