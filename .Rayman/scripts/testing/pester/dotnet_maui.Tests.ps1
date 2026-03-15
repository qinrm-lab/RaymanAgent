BeforeAll {
  . (Join-Path $PSScriptRoot '..\..\utils\ensure_project_test_deps.ps1') -NoMain
  . (Join-Path $PSScriptRoot '..\..\repair\run_tests_and_fix.ps1') -NoMain

  function New-MauiWorkspaceFixture {
    param(
      [string]$Root,
      [switch]$WithGlobalJson
    )

    New-Item -ItemType Directory -Force -Path (Join-Path $Root 'DeleteDir') | Out-Null
    Set-Content -LiteralPath (Join-Path $Root 'Tools.slnx') -Encoding UTF8 -Value @'
<Solution>
  <Project Path="DeleteDir/DeleteDir.csproj" />
</Solution>
'@
    Set-Content -LiteralPath (Join-Path $Root 'DeleteDir\DeleteDir.csproj') -Encoding UTF8 -Value @'
<Project Sdk="Microsoft.NET.Sdk.Razor">
  <PropertyGroup>
    <TargetFrameworks>net10.0-android;net10.0-ios;net10.0-maccatalyst</TargetFrameworks>
    <TargetFrameworks Condition="$([MSBuild]::IsOSPlatform('windows'))">$(TargetFrameworks);net10.0-windows10.0.19041.0</TargetFrameworks>
    <UseMaui>true</UseMaui>
    <SingleProject>true</SingleProject>
  </PropertyGroup>
</Project>
'@
    if ($WithGlobalJson) {
      Set-Content -LiteralPath (Join-Path $Root 'global.json') -Encoding UTF8 -Value @'
{
  "sdk": {
    "version": "10.0.103"
  }
}
'@
    }
  }
}

Describe 'dotnet MAUI dependency helpers' {
  It 'detects MAUI SDK major and target frameworks from workspace profile' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_maui_profile_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-MauiWorkspaceFixture -Root $root -WithGlobalJson

      $profile = Get-RaymanWorkspaceDependencyProfile -WorkspaceRoot $root

      $profile.NeedsDotNet | Should -BeTrue
      $profile.IsMaui | Should -BeTrue
      $profile.RequiredSdkMajor | Should -Be 10
      $profile.DotNetWingetPackageId | Should -Be 'Microsoft.DotNet.SDK.10'
      @($profile.MauiProjects).Count | Should -Be 1
      @($profile.PreferredMauiProject.TargetFrameworks) | Should -Contain 'net10.0-windows10.0.19041.0'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'run_tests_and_fix MAUI command selection' {
  BeforeEach {
    $script:envBackup = [Environment]::GetEnvironmentVariable('RAYMAN_DOTNET_WINDOWS_PREFERRED')
    [Environment]::SetEnvironmentVariable('RAYMAN_DOTNET_WINDOWS_PREFERRED', '1')
  }

  AfterEach {
    [Environment]::SetEnvironmentVariable('RAYMAN_DOTNET_WINDOWS_PREFERRED', $script:envBackup)
  }

  It 'prefers a Windows MAUI target when Windows bridge is available' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_maui_primary_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-MauiWorkspaceFixture -Root $root

      Mock Resolve-DotNetWindowsBridge {
        [pscustomobject]@{
          available = $true
          reason = 'ok'
          powershell_path = 'powershell.exe'
          workspace_windows = 'E:\rayman\temp'
        }
      }
      Mock Test-IsWindowsPlatformCompat { $false }
      Mock Test-CanUseWindowsDotNetFromCurrentHost { $true }
      Mock Test-IsMacOSPlatformCompat { $false }

      $primary = Get-PrimaryCommand -WorkspaceRootOverride $root

      [string]$primary.Kind | Should -Be 'dotnet'
      [bool]$primary.IsMaui | Should -BeTrue
      [string]$primary.MauiTargetFramework | Should -Be 'net10.0-windows10.0.19041.0'
      [string]$primary.Command | Should -Be ("dotnet build '{0}' -f net10.0-windows10.0.19041.0" -f (Join-Path $root 'DeleteDir\DeleteDir.csproj'))
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'restores MAUI workloads when NETSDK1147 is detected' {
    $script:FixLog = New-Object System.Collections.Generic.List[string]
    $script:SandboxScript = ''
    $script:invokedCommands = New-Object System.Collections.Generic.List[string]

    Mock Invoke-RaymanCommand {
      param(
        [string]$Command,
        [bool]$UseSandboxEffective,
        [string]$SandboxScript,
        [string]$Kind
      )
      $script:invokedCommands.Add($Command) | Out-Null
      @()
    }

    $primary = [pscustomobject]@{
      Kind = 'dotnet'
      IsMaui = $true
      MauiProjectPath = 'E:\rayman\DeleteDir\DeleteDir.csproj'
      DependencyProfile = [pscustomobject]@{
        MauiProjects = @([pscustomobject]@{ Path = 'E:\rayman\DeleteDir\DeleteDir.csproj' })
      }
    }

    $didFix = Invoke-CommonFixes -Kind 'dotnet' -OutputLines @(
      'error NETSDK1147: To build this project, the following workloads must be installed: maui-android',
      'To install these workloads, run the following command: dotnet workload restore'
    ) -PrimaryContext $primary

    $didFix | Should -BeTrue
    @($script:invokedCommands) | Should -Contain "dotnet workload restore 'E:\rayman\DeleteDir\DeleteDir.csproj'"
  }
}
