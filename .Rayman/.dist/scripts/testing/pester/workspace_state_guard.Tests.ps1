BeforeAll {
  . (Join-Path $PSScriptRoot '..\..\utils\workspace_state_guard.ps1')
}

Describe 'workspace_state_guard' {
  It 'scrubs foreign workspace runtime artifacts, legacy memory payloads, and copied Agent Memory data' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_guard_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime\test_lanes') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\logs') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\state') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\state\memory') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime\memory') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root ('.' + 'rag')) | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path $root '.Rayman\state') ('chroma' + '_db')) | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Value 'v160' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.Rayman\logs\stale.log') -Value 'stale' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.Rayman\runtime\dotnet.exec.last.json') -Encoding UTF8 -Value @'
{
  "schema": "rayman.dotnet.exec.v1",
  "workspace_root": "C:\\ForeignWorkspace",
  "requested_command": "dotnet build"
}
'@
      Set-Content -LiteralPath (Join-Path $root '.Rayman\runtime\test_lanes\host_smoke.report.json') -Encoding UTF8 -Value @'
{
  "schema": "rayman.testing.host_smoke.v1",
  "workspace_root": "C:\\ForeignWorkspace",
  "overall": "PASS"
}
'@
      Set-Content -LiteralPath (Join-Path $root '.Rayman\state\release_gate_report.json') -Value '{}' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.Rayman\state\rayman.db') -Value 'keep' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path (Join-Path $root '.Rayman\state') ('rag' + '.db')) -Value 'legacy' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.Rayman\state\memory\memory.sqlite3') -Value 'memory' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.Rayman\runtime\memory\status.json') -Value '{}' -Encoding UTF8

      $result = Invoke-RaymanWorkspaceStateGuard -WorkspaceRoot $root
      $marker = Get-Content -LiteralPath (Join-Path $root '.Rayman\runtime\workspace.marker.json') -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop

      $result.scrubbed | Should -BeTrue
      $result.removed_count | Should -BeGreaterThan 0
      @($result.removed_paths) | Should -Contain (Join-Path $root ('.' + 'rag'))
      (Test-Path -LiteralPath (Join-Path $root '.Rayman\logs')) | Should -BeFalse
      (Test-Path -LiteralPath (Join-Path $root '.Rayman\runtime\dotnet.exec.last.json')) | Should -BeFalse
      (Test-Path -LiteralPath (Join-Path $root '.Rayman\runtime\memory')) | Should -BeFalse
      (Test-Path -LiteralPath (Join-Path $root '.Rayman\state\release_gate_report.json')) | Should -BeFalse
      (Test-Path -LiteralPath (Join-Path $root ('.' + 'rag'))) | Should -BeFalse
      (Test-Path -LiteralPath (Join-Path (Join-Path $root '.Rayman\state') ('chroma' + '_db'))) | Should -BeFalse
      (Test-Path -LiteralPath (Join-Path (Join-Path $root '.Rayman\state') ('rag' + '.db'))) | Should -BeFalse
      (Test-Path -LiteralPath (Join-Path $root '.Rayman\state\memory')) | Should -BeTrue
      (Test-Path -LiteralPath (Join-Path $root '.Rayman\state\memory\memory.sqlite3')) | Should -BeFalse
      (Test-Path -LiteralPath (Join-Path $root '.Rayman\state\rayman.db')) | Should -BeTrue
      [string]$marker.workspace_root | Should -Be $root
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'treats equivalent WSL workspace paths as local and avoids false scrub' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_guard_wsl_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime\test_lanes') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\logs') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Value 'v164' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.Rayman\logs\keep.log') -Value 'keep' -Encoding UTF8

      $rootForJson = $root -replace '\\', '/'
      if ($rootForJson -match '^(?<drive>[A-Za-z]):/(?<rest>.*)$') {
        $wslRoot = ('/mnt/{0}/{1}' -f [string]$Matches['drive'].ToLowerInvariant(), [string]$Matches['rest'])
      } else {
        $wslRoot = $rootForJson
      }

      Set-Content -LiteralPath (Join-Path $root '.Rayman\runtime\test_lanes\host_smoke.report.json') -Encoding UTF8 -Value @"
{
  "schema": "rayman.testing.host_smoke.v1",
  "workspace_root": "$wslRoot",
  "overall": "PASS"
}
"@

      $result = Invoke-RaymanWorkspaceStateGuard -WorkspaceRoot $root

      $result.scrubbed | Should -BeFalse
      Test-Path -LiteralPath (Join-Path $root '.Rayman\logs\keep.log') -PathType Leaf | Should -Be $true
      Test-Path -LiteralPath (Join-Path $root '.Rayman\runtime\test_lanes\host_smoke.report.json') -PathType Leaf | Should -Be $true
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
