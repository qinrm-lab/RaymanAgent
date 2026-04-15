BeforeAll {
  . (Join-Path $PSScriptRoot '..\..\pwa\playwright_ready.lib.ps1')
  $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
}

Describe 'playwright_ready.lib' {
  It 'defaults an empty scope to wsl' {
    Normalize-Scope -Value '' | Should -Be 'wsl'
  }

  It 'accepts sandbox scope' {
    Normalize-Scope -Value 'sandbox' | Should -Be 'sandbox'
  }

  It 'rejects unsupported scope values' {
    { Normalize-Scope -Value 'desktop' } | Should -Throw
  }

  It 'classifies bootstrap stalled sandbox errors' {
    Get-SandboxFailureKindFromMessage -Message 'sandbox bootstrap appears stalled (stall_seconds=360)' | Should -Be 'bootstrap_stalled'
  }

  It 'classifies existing sandbox instance errors' {
    Get-SandboxFailureKindFromMessage -Message 'existing Windows Sandbox instance is already running; processes=WindowsSandbox#1234' | Should -Be 'existing_instance_running'
  }

  It 'returns action guidance for existing sandbox instance errors' {
    Get-SandboxActionRequired -FailureKind 'existing_instance_running' | Should -Match '关闭已有 Sandbox'
  }

  It 'converts string booleans flexibly' {
    Convert-ToBoolFlexible -Value 'yes' -ParameterName 'Require' | Should -BeTrue
    Convert-ToBoolFlexible -Value 'off' -ParameterName 'Require' | Should -BeFalse
  }

  It 'keeps sandbox offline cache gating enabled by default' {
    $raw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\pwa\ensure_playwright_ready.ps1') -Raw -Encoding UTF8

    $needle = [regex]::Escape("RAYMAN_SANDBOX_OFFLINE_CACHE_REQUIRE' -DefaultValue `$true")
    ([regex]::Matches($raw, $needle)).Count | Should -Be 2
  }

  It 'resolves a workspace-local Playwright cli before falling back to managed tools' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_playwright_local_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root 'node_modules\playwright') | Out-Null
      Set-Content -LiteralPath (Join-Path $root 'node_modules\playwright\cli.js') -Encoding UTF8 -Value 'process.exit(0);'
      Set-Content -LiteralPath (Join-Path $root 'node_modules\playwright\package.json') -Encoding UTF8 -Value '{ "version": "1.57.0" }'

      $resolved = Resolve-RaymanPlaywrightHostInstallInvocation -WorkspaceRoot $root -Browser chromium

      $resolved.success | Should -BeTrue
      $resolved.install_source | Should -Be 'workspace_local'
      $resolved.tool_root | Should -Be ([System.IO.Path]::GetFullPath($root))
      $resolved.package_spec | Should -Be 'playwright@1.57.0'
      $resolved.cli_path | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $root 'node_modules\playwright\cli.js')))
      @($resolved.argument_list) | Should -Be @(
        ([System.IO.Path]::GetFullPath((Join-Path $root 'node_modules\playwright\cli.js'))),
        'install',
        'chromium'
      )
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'falls back to a Rayman-managed host tool when no workspace Playwright cli exists' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_playwright_managed_' + [Guid]::NewGuid().ToString('N'))
    $localAppData = Join-Path $root 'LocalAppData'
    $originalLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    try {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $localAppData)
      New-Item -ItemType Directory -Force -Path $root | Out-Null

      $descriptor = Get-RaymanPlaywrightManagedToolDescriptor -PackageSpec 'playwright@latest'
      New-Item -ItemType Directory -Force -Path (Join-Path $descriptor.tool_root 'node_modules\playwright') | Out-Null
      Set-Content -LiteralPath $descriptor.cli_path -Encoding UTF8 -Value 'process.exit(0);'
      Set-Content -LiteralPath $descriptor.package_json_path -Encoding UTF8 -Value '{ "version": "1.58.0" }'
      Write-RaymanPlaywrightJsonFile -Path $descriptor.manifest_path -Value ([ordered]@{
          schema = 'rayman.playwright.host_tool.manifest.v1'
          package_spec = 'playwright@latest'
          tool_root = $descriptor.tool_root
          cli_path = $descriptor.cli_path
          resolved_version = '1.58.0'
          last_prepared_at = (Get-Date).ToString('o')
        })

      $resolved = Resolve-RaymanPlaywrightHostInstallInvocation -WorkspaceRoot $root -Browser chromium

      $resolved.success | Should -BeTrue
      $resolved.install_source | Should -Be 'rayman_managed'
      $resolved.tool_root | Should -Be $descriptor.tool_root
      $resolved.package_spec | Should -Be 'playwright@latest'
      $resolved.resolved_version | Should -Be '1.58.0'
      $resolved.cli_path | Should -Be $descriptor.cli_path
    } finally {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $originalLocalAppData)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
