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

  It 'ignores Rayman-owned dynamic sandbox residue under .temp only' {
    $rules = @(Get-ReleaseGateScanIgnoreRules)

    (Test-ReleaseGatePathIgnored -FullPath 'E:\repo\.temp\rayman-dynamic-sandbox\agents.md' -Rules $rules) | Should -Be $true
    (Test-ReleaseGatePathIgnored -FullPath 'E:\repo\.temp\rayman-dynamic-sandbox-20260330\agents.md' -Rules $rules) | Should -Be $true
    (Test-ReleaseGatePathIgnored -FullPath 'E:\repo\.Rayman\scripts\testing\pester\release_gate.Tests.ps1' -Rules $rules) | Should -Be $true
    (Test-ReleaseGatePathIgnored -FullPath 'E:\repo\.temp\custom\agents.md' -Rules $rules) | Should -Be $false
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

  It 'supports wildcard freshness paths when checking stale reports' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_release_gate_wildcard_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root 'logs') | Out-Null
      $reportPath = Join-Path $root 'fast.report.json'
      $logPath = Join-Path $root 'logs\fast.requirements_layout.log'

      Set-Content -LiteralPath $reportPath -Encoding UTF8 -Value '{}'
      Set-Content -LiteralPath $logPath -Encoding UTF8 -Value 'new log'

      $nowUtc = [datetime]::UtcNow
      (Get-Item -LiteralPath $reportPath).LastWriteTimeUtc = $nowUtc.AddMinutes(-5)
      (Get-Item -LiteralPath $logPath).LastWriteTimeUtc = $nowUtc

      $result = Get-TestLaneReportEvaluation -Report ([pscustomobject]@{
          schema = 'rayman.project_gate.v1'
          overall = 'PASS'
          workspace_root = $root
          generated_at = ($nowUtc.AddMinutes(-5).ToString('o'))
        }) -ExpectedSchema 'rayman.project_gate.v1' -SuccessProperty '' -OverallProperty 'overall' -WorkspaceRoot $root -ReportPath $reportPath -FreshnessPaths @('logs/fast.*.log') -RequireGeneratedAt

      $result.status | Should -Be 'STALE'
      $result.detail | Should -Match 'stale_report_older_than_inputs'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'can auto-run a release-gate lane through the provided runner' {
    $result = Invoke-ReleaseGateLaneAutoRun -WorkspaceRoot 'E:\repo' -Action '执行 bash ./.Rayman/scripts/testing/run_fast_contract.sh' -Runner {
      param($commandText)
      [pscustomobject]@{
        attempted = $true
        started = $true
        success = $true
        exit_code = 0
        reason = 'completed'
        command = $commandText
        output = 'ok'
      }
    }

    [bool]$result.attempted | Should -Be $true
    [bool]$result.started | Should -Be $true
    [bool]$result.success | Should -Be $true
    [string]$result.command | Should -Be 'bash ./.Rayman/scripts/testing/run_fast_contract.sh'
  }
}
