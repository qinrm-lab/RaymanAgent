BeforeAll {
  $script:WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  . (Join-Path $script:WorkspaceRoot '.Rayman\common.ps1')
  . (Join-Path $script:WorkspaceRoot '.Rayman\scripts\utils\workspace_platform_profile.ps1') -NoMain

  function script:Initialize-TestWorkspace {
    param(
      [string]$Root,
      [switch]$Source
    )

    New-Item -ItemType Directory -Force -Path (Join-Path $Root '.Rayman\scripts\testing') | Out-Null
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\scripts\testing\run_fast_contract.sh') -Encoding UTF8 -Value '#!/usr/bin/env bash'
    if ($Source) {
      New-Item -ItemType Directory -Force -Path (Join-Path $Root '.github\workflows') | Out-Null
      Set-Content -LiteralPath (Join-Path $Root '.github\workflows\rayman-test-lanes.yml') -Encoding UTF8 -Value 'name: rayman-test-lanes'
    }
  }

  function script:New-TestProject {
    param(
      [string]$ProjectDir,
      [string]$ProjectName
    )

    New-Item -ItemType Directory -Force -Path $ProjectDir | Out-Null
    Set-Content -LiteralPath (Join-Path $ProjectDir ("{0}.csproj" -f $ProjectName)) -Encoding UTF8 -Value '<Project><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>'
  }

  function script:Write-TestSolution {
    param(
      [string]$Root,
      [string[]]$ProjectPaths
    )

    $solutionPath = Join-Path $Root 'RaymanAgent.slnx'
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('<Solution>') | Out-Null
    foreach ($projectPath in @($ProjectPaths)) {
      $lines.Add(("  <Project Path=""{0}"" />" -f ([string]$projectPath).Replace('\', '/'))) | Out-Null
    }
    $lines.Add('</Solution>') | Out-Null
    Set-Content -LiteralPath $solutionPath -Encoding UTF8 -Value ($lines.ToArray())
    return $solutionPath
  }
}

Describe 'workspace platform profile helper' {
  It 'uses a single root .slnx project list in source workspaces' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_profile_source_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-TestWorkspace -Root $root -Source
      $fixtureDir = Join-Path $root '.Rayman\scripts\testing\fixtures\worker_smoke_app'
      New-TestProject -ProjectDir $fixtureDir -ProjectName 'WorkerSmokeApp'
      Write-TestSolution -Root $root -ProjectPaths @('.Rayman/scripts/testing/fixtures/worker_smoke_app/WorkerSmokeApp.csproj') | Out-Null

      $profile = Get-RaymanWorkspacePlatformProfile -WorkspaceRoot $root

      $profile.needs_dotnet | Should -BeTrue
      @($profile.dotnet_project_paths).Count | Should -Be 1
      @($profile.dotnet_project_paths)[0] | Should -Be (Join-Path $fixtureDir 'WorkerSmokeApp.csproj')
      @($profile.projects).Count | Should -Be 1
      @($profile.projects)[0].path | Should -Be (Join-Path $fixtureDir 'WorkerSmokeApp.csproj')
      @($profile.target_frameworks) | Should -Contain 'net8.0'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'falls back to scan discovery when the root solution has no usable project' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_profile_fallback_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-TestWorkspace -Root $root -Source
      $authoredDir = Join-Path $root 'src\DemoApp'
      $runtimeDir = Join-Path $root '.Rayman\runtime\worker\staging\demo-stage\RuntimeTemp'
      New-TestProject -ProjectDir $authoredDir -ProjectName 'DemoApp'
      New-TestProject -ProjectDir $runtimeDir -ProjectName 'RuntimeTemp'
      Write-TestSolution -Root $root -ProjectPaths @('.Rayman/scripts/testing/fixtures/worker_smoke_app/MissingApp.csproj') | Out-Null

      $profile = Get-RaymanWorkspacePlatformProfile -WorkspaceRoot $root

      @($profile.dotnet_project_paths).Count | Should -Be 1
      @($profile.dotnet_project_paths)[0] | Should -Be (Join-Path $authoredDir 'DemoApp.csproj')
      @($profile.projects).Count | Should -Be 1
      @($profile.projects)[0].path | Should -Be (Join-Path $authoredDir 'DemoApp.csproj')
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'does not require .NET when a root solution resolves no managed projects' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_profile_solution_only_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-TestWorkspace -Root $root -Source
      Write-TestSolution -Root $root -ProjectPaths @('native/NativeApp.vcxproj') | Out-Null

      $profile = Get-RaymanWorkspacePlatformProfile -WorkspaceRoot $root

      $profile.needs_dotnet | Should -BeFalse
      @($profile.dotnet_project_paths).Count | Should -Be 0
      @($profile.projects).Count | Should -Be 0
      @($profile.target_frameworks).Count | Should -Be 0
      $profile.summary | Should -Be 'no_dotnet_projects'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
