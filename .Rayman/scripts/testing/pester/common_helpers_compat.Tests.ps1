BeforeAll {
  . (Join-Path $PSScriptRoot '..\..\..\common.ps1')
}

Describe 'json compatibility helpers' {
  It 'parses jsonc with comments and trailing commas' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_jsonc_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $jsonPath = Join-Path $root 'settings.json'
      Set-Content -LiteralPath $jsonPath -Encoding UTF8 -Value @'
{
  // comment
  "name": "rayman",
  "items": [
    1,
    2,
  ],
}
'@

      $doc = Read-RaymanJsonFile -Path $jsonPath -AsHashtable

      $doc.Exists | Should -Be $true
      $doc.ParseFailed | Should -Be $false
      [string]$doc.Obj['name'] | Should -Be 'rayman'
      (@($doc.Obj['items']) -join ',') | Should -Be '1,2'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'marks concatenated json as parse failed without throwing' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_json_invalid_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $jsonPath = Join-Path $root 'settings.json'
      Set-Content -LiteralPath $jsonPath -Encoding UTF8 -Value '{"a":1}{"b":2}'

      $doc = Read-RaymanJsonFile -Path $jsonPath

      $doc.Exists | Should -Be $true
      $doc.ParseFailed | Should -Be $true
      [string]$doc.Error | Should -Not -BeNullOrEmpty
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'setup post-check helpers' {
  BeforeEach {
    $script:postCheckEnvBackup = @{}
    foreach ($name in @('RAYMAN_APPROVAL_MODE', 'RAYMAN_SETUP_POST_CHECK_MODE')) {
      $script:postCheckEnvBackup[$name] = [Environment]::GetEnvironmentVariable($name)
      [Environment]::SetEnvironmentVariable($name, $null)
    }
  }

  AfterEach {
    foreach ($entry in $script:postCheckEnvBackup.GetEnumerator()) {
      [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value)
    }
  }

  It 'defaults setup post-check to strict under full-auto approval' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_post_check_default_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      [Environment]::SetEnvironmentVariable('RAYMAN_APPROVAL_MODE', 'full-auto')

      Get-RaymanSetupPostCheckMode -WorkspaceRoot $root | Should -Be 'strict'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'honors explicit setup post-check overrides' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_post_check_override_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      [Environment]::SetEnvironmentVariable('RAYMAN_APPROVAL_MODE', 'full-auto')
      [Environment]::SetEnvironmentVariable('RAYMAN_SETUP_POST_CHECK_MODE', 'skip')

      Get-RaymanSetupPostCheckMode -WorkspaceRoot $root | Should -Be 'skip'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
