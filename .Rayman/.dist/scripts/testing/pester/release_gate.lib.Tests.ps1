BeforeAll {
  . (Join-Path $PSScriptRoot '..\..\release\release_gate.lib.ps1')
}

Describe 'release_gate.lib' {
  It 'extracts lowercase version token from release artifact names' {
    Get-VersionTokenFromName -Name 'rayman-distributable-v160-20260312.zip' | Should -Be 'v160'
  }

  It 'returns empty version token when no token exists' {
    Get-VersionTokenFromName -Name 'rayman-distributable-latest.zip' | Should -Be ''
  }

  It 'normalizes PowerShell filesystem prefixes and path separators' {
    $raw = 'Microsoft.PowerShell.Core\FileSystem::C:\Rayman\Foo\Bar'
    Get-PathComparisonValue -PathValue $raw | Should -Be 'c:/rayman/foo/bar'
  }

  It 'treats WSL mount paths as equivalent to the same Windows workspace' {
    $result = Get-TestLaneReportEvaluation -Report ([pscustomobject]@{
        schema = 'rayman.testing.fast_contract.v1'
        success = $true
        workspace_root = '/mnt/e/rayman/software/RaymanAgent'
      }) -ExpectedSchema 'rayman.testing.fast_contract.v1' -WorkspaceRoot 'E:\rayman\software\RaymanAgent'

    $result.status | Should -Be 'PASS'
  }

  It 'renders relative display path when target is under workspace root' {
    $base = 'C:\RaymanAgent'
    $full = 'C:\RaymanAgent\.Rayman\scripts\release\release_gate.ps1'
    Get-DisplayRelativePath -BasePath $base -FullPath $full | Should -Be '.Rayman/scripts/release/release_gate.ps1'
  }

  It 'maps success-based test lane reports to PASS/FAIL' {
    $ok = Get-TestLaneReportEvaluation -Report ([pscustomobject]@{ schema = 'rayman.testing.fast_contract.v1'; success = $true }) -ExpectedSchema 'rayman.testing.fast_contract.v1'
    $fail = Get-TestLaneReportEvaluation -Report ([pscustomobject]@{ schema = 'rayman.testing.fast_contract.v1'; success = $false }) -ExpectedSchema 'rayman.testing.fast_contract.v1'

    $ok.status | Should -Be 'PASS'
    $fail.status | Should -Be 'FAIL'
  }

  It 'maps overall-based test lane reports to WARN' {
    $result = Get-TestLaneReportEvaluation -Report ([pscustomobject]@{ schema = 'rayman.testing.host_smoke.v1'; overall = 'WARN' }) -ExpectedSchema 'rayman.testing.host_smoke.v1' -SuccessProperty '' -OverallProperty 'overall'
    $result.status | Should -Be 'WARN'
  }

  It 'marks schema mismatches as INVALID' {
    $result = Get-TestLaneReportEvaluation -Report ([pscustomobject]@{ schema = 'rayman.testing.host_smoke.v1'; success = $true }) -ExpectedSchema 'rayman.testing.fast_contract.v1'
    $result.status | Should -Be 'INVALID'
  }

  It 'marks foreign workspace reports as STALE' {
    $result = Get-TestLaneReportEvaluation -Report ([pscustomobject]@{
        schema = 'rayman.testing.host_smoke.v1'
        overall = 'PASS'
        workspace_root = 'C:\ForeignWorkspace'
      }) -ExpectedSchema 'rayman.testing.host_smoke.v1' -SuccessProperty '' -OverallProperty 'overall' -WorkspaceRoot 'C:\CurrentWorkspace'

    $result.status | Should -Be 'STALE'
    $result.detail | Should -Match 'stale_report_workspace_mismatch'
  }

  It 'marks reports without generated_at as STALE when freshness is required' {
    $result = Get-TestLaneReportEvaluation -Report ([pscustomobject]@{
        schema = 'rayman.testing.host_smoke.v1'
        overall = 'PASS'
        workspace_root = 'C:\CurrentWorkspace'
      }) -ExpectedSchema 'rayman.testing.host_smoke.v1' -SuccessProperty '' -OverallProperty 'overall' -WorkspaceRoot 'C:\CurrentWorkspace' -RequireGeneratedAt

    $result.status | Should -Be 'STALE'
    $result.detail | Should -Be 'stale_report_missing_generated_at'
  }

  It 'marks reports older than lane inputs as STALE' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_release_gate_stale_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $inputPath = Join-Path $root 'input.txt'
      $reportPath = Join-Path $root 'host_smoke.report.json'

      Set-Content -LiteralPath $inputPath -Encoding UTF8 -Value 'input'
      Set-Content -LiteralPath $reportPath -Encoding UTF8 -Value '{}'

      $nowUtc = [datetime]::UtcNow
      (Get-Item -LiteralPath $reportPath).LastWriteTimeUtc = $nowUtc.AddMinutes(-5)
      (Get-Item -LiteralPath $inputPath).LastWriteTimeUtc = $nowUtc

      $result = Get-TestLaneReportEvaluation -Report ([pscustomobject]@{
          schema = 'rayman.testing.host_smoke.v1'
          overall = 'PASS'
          workspace_root = $root
          generated_at = ($nowUtc.AddMinutes(-5).ToString('o'))
        }) -ExpectedSchema 'rayman.testing.host_smoke.v1' -SuccessProperty '' -OverallProperty 'overall' -WorkspaceRoot $root -ReportPath $reportPath -FreshnessPaths @('input.txt') -RequireGeneratedAt

      $result.status | Should -Be 'STALE'
      $result.detail | Should -Match 'stale_report_older_than_inputs'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
