Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function script:Get-TestPowerShellPath {
  foreach ($candidate in @('pwsh', 'pwsh.exe', 'powershell', 'powershell.exe')) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
      return [string]$cmd.Source
    }
  }

  throw 'pwsh/powershell not found'
}

Describe 'ensure_playwright_ready host mode' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
    $script:EnsurePlaywrightPath = Join-Path $script:RepoRoot '.Rayman\scripts\pwa\ensure_playwright_ready.ps1'
    $script:PowerShellPath = Get-TestPowerShellPath
    . (Join-Path $script:RepoRoot '.Rayman\scripts\pwa\playwright_ready.lib.ps1')
  }

  It 'emits workspace-local host metadata and avoids workspace npmrc prefix issues' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_ensure_playwright_local_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root 'node_modules\playwright') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.npmrc') -Encoding UTF8 -Value "prefix=/home/qinrm/.npm-global`n"
      Set-Content -LiteralPath (Join-Path $root 'node_modules\playwright\cli.js') -Encoding UTF8 -Value 'process.exit(0);'
      Set-Content -LiteralPath (Join-Path $root 'node_modules\playwright\package.json') -Encoding UTF8 -Value '{ "version": "1.57.0" }'

      $json = & $script:PowerShellPath -NoProfile -ExecutionPolicy Bypass -File $script:EnsurePlaywrightPath -WorkspaceRoot $root -Scope host -Require:$false -Json
      $LASTEXITCODE | Should -Be 0
      $result = $json | ConvertFrom-Json

      $result.success | Should -BeTrue
      $result.scope | Should -Be 'host'
      $result.host.success | Should -BeTrue
      $result.host.install_source | Should -Be 'workspace_local'
      $result.host.tool_root | Should -Be ([System.IO.Path]::GetFullPath($root))
      $result.host.package_spec | Should -Be 'playwright@1.57.0'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'emits Rayman-managed host metadata for non-Node workspaces' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_ensure_playwright_managed_' + [Guid]::NewGuid().ToString('N'))
    $localAppData = Join-Path $root 'LocalAppData'
    $originalLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    try {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $localAppData)
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime') | Out-Null

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

      $json = & $script:PowerShellPath -NoProfile -ExecutionPolicy Bypass -File $script:EnsurePlaywrightPath -WorkspaceRoot $root -Scope host -Require:$false -Json
      $LASTEXITCODE | Should -Be 0
      $result = $json | ConvertFrom-Json

      $result.success | Should -BeTrue
      $result.scope | Should -Be 'host'
      $result.host.success | Should -BeTrue
      $result.host.install_source | Should -Be 'rayman_managed'
      $result.host.tool_root | Should -Be $descriptor.tool_root
      $result.host.package_spec | Should -Be 'playwright@latest'
    } finally {
      [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $originalLocalAppData)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
