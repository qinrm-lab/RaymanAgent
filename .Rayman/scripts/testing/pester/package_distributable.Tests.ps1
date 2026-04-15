BeforeAll {
  $script:WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  . (Join-Path $script:WorkspaceRoot '.Rayman\scripts\release\package_distributable.ps1') -NoMain

  function script:Initialize-TestDistributableWorkspace {
    param([string]$Root)

    foreach ($path in @(
        (Join-Path $Root '.Rayman'),
        (Join-Path $Root '.Rayman\scripts'),
        (Join-Path $Root '.Rayman\state\memory'),
        (Join-Path $Root '.Rayman\runtime\migration\deep\branch'),
        (Join-Path $Root '.Rayman\logs')
      )) {
      New-Item -ItemType Directory -Force -Path $path | Out-Null
    }

    Set-Content -LiteralPath (Join-Path $Root '.Rayman\VERSION') -Encoding UTF8 -Value "v161`n"
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\scripts\marker.ps1') -Encoding UTF8 -Value 'Write-Output ''marker'''
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\state\memory\semantic.json') -Encoding UTF8 -Value '{}'
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\runtime\migration\deep\branch\stale.txt') -Encoding UTF8 -Value 'runtime noise'
    Set-Content -LiteralPath (Join-Path $Root '.Rayman\logs\old.log') -Encoding UTF8 -Value 'log noise'
  }
}

Describe 'package distributable' {
  It 'skips excluded runtime and state payloads before file copy recursion' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_package_stage_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-TestDistributableWorkspace -Root $root
      $originalCopyItem = Get-Command -Name 'Copy-Item' -CommandType Cmdlet

      Mock Copy-Item {
        param(
          [string]$LiteralPath,
          [string]$Destination
        )
        if ([string]$LiteralPath -like '*.Rayman' -or [string]$LiteralPath -like '*\.Rayman\runtime*' -or [string]$LiteralPath -like '*\.Rayman\state\memory*') {
          throw "excluded path copied: $LiteralPath"
        }
        & $originalCopyItem @PSBoundParameters
      }

      $stage = New-RaymanDistributableStageDirectory -WorkspaceRoot $root

      Test-Path -LiteralPath (Join-Path $stage.stage_rayman 'scripts\marker.ps1') | Should -Be $true
      Test-Path -LiteralPath (Join-Path $stage.stage_rayman 'runtime\migration\deep\branch\stale.txt') | Should -Be $false
      Test-Path -LiteralPath (Join-Path $stage.stage_rayman 'state\memory\semantic.json') | Should -Be $false
      @($stage.removed) | Should -Contain 'runtime'
      @($stage.removed) | Should -Contain 'state\memory'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'computes a stable fingerprint from distributable content only' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_package_fingerprint_' + [Guid]::NewGuid().ToString('N'))
    try {
      Initialize-TestDistributableWorkspace -Root $root

      $before = Get-RaymanDistributableFingerprint -WorkspaceRoot $root

      Set-Content -LiteralPath (Join-Path $root '.Rayman\runtime\migration\deep\branch\stale.txt') -Encoding UTF8 -Value 'runtime noise v2'
      Set-Content -LiteralPath (Join-Path $root '.Rayman\logs\old.log') -Encoding UTF8 -Value 'log noise v2'
      Set-Content -LiteralPath (Join-Path $root '.Rayman\state\memory\semantic.json') -Encoding UTF8 -Value '{"changed":true}'
      $ignoredChange = Get-RaymanDistributableFingerprint -WorkspaceRoot $root

      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\marker.ps1') -Encoding UTF8 -Value 'Write-Output ''marker-v2'''
      $realChange = Get-RaymanDistributableFingerprint -WorkspaceRoot $root

      $before | Should -Be $ignoredChange
      $realChange | Should -Not -Be $before
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'falls back to managed hashing when Get-FileHash is unavailable' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_package_hash_fallback_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $filePath = Join-Path $root 'sample.txt'
      Set-Content -LiteralPath $filePath -Encoding UTF8 -Value 'fallback-hash'
      $expectedHash = [System.BitConverter]::ToString(([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.IO.File]::ReadAllBytes($filePath)))).Replace('-', '')

      Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'Get-FileHash' }

      $hash = Get-FileHashCompat -Path $filePath -Algorithm 'SHA256'

      [string]$hash | Should -Match '^[0-9A-F]{64}$'
      [string]$hash | Should -Be $expectedHash
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
