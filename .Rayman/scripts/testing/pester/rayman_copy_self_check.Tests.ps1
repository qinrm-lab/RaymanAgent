function script:Get-TestPowerShellPath {
  foreach ($candidate in @('pwsh', 'pwsh.exe', 'powershell', 'powershell.exe')) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
      return [string]$cmd.Source
    }
  }

  throw 'pwsh/powershell not found'
}

Describe 'rayman copy-self-check exit propagation' {
  It 'returns the child copy-smoke exit code' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_copy_self_check_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\release') | Out-Null
      Copy-Item -LiteralPath (Join-Path $repoRoot '.Rayman\rayman.ps1') -Destination (Join-Path $root '.Rayman\rayman.ps1')
      Copy-Item -LiteralPath (Join-Path $repoRoot '.Rayman\common.ps1') -Destination (Join-Path $root '.Rayman\common.ps1')
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\release\copy_smoke.ps1') -Encoding UTF8 -Value @'
param()
exit 13
'@

      $psPath = Get-TestPowerShellPath
      & $psPath -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root '.Rayman\rayman.ps1') copy-self-check | Out-Null

      $LASTEXITCODE | Should -Be 13
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'copy_smoke strict nested setup audit' {
  It 'archives all strict setup passes and suppresses nested done alerts' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_copy_smoke_strict_' + [Guid]::NewGuid().ToString('N'))
    $keptTempRoot = ''
    try {
      foreach ($dir in @(
        '.Rayman\scripts\release',
        '.Rayman\scripts\utils',
        '.Rayman\scripts\project',
        '.github'
      )) {
        New-Item -ItemType Directory -Force -Path (Join-Path $root $dir) | Out-Null
      }

      Copy-Item -LiteralPath (Join-Path $repoRoot '.Rayman\scripts\release\copy_smoke.ps1') -Destination (Join-Path $root '.Rayman\scripts\release\copy_smoke.ps1')
      Copy-Item -LiteralPath (Join-Path $repoRoot '.Rayman\common.ps1') -Destination (Join-Path $root '.Rayman\common.ps1')
      Copy-Item -LiteralPath (Join-Path $repoRoot '.Rayman\scripts\utils\workspace_process_ownership.ps1') -Destination (Join-Path $root '.Rayman\scripts\utils\workspace_process_ownership.ps1')

      Set-Content -LiteralPath (Join-Path $root '.Rayman\setup.ps1') -Encoding UTF8 -Value @'
param(
  [string]$WorkspaceRoot,
  [switch]$SkipReleaseGate,
  [switch]$NoAutoMigrateLegacyRag
)

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$raymanRoot = Join-Path $WorkspaceRoot '.Rayman'
$runtimeDir = Join-Path $raymanRoot 'runtime'
$logsDir = Join-Path $raymanRoot 'logs'
New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $WorkspaceRoot '.github') | Out-Null
if (-not (Test-Path -LiteralPath (Join-Path $WorkspaceRoot '.SolutionName') -PathType Leaf)) {
  Set-Content -LiteralPath (Join-Path $WorkspaceRoot '.SolutionName') -Encoding UTF8 -Value 'CopySmokeTest'
}
if (-not (Test-Path -LiteralPath (Join-Path $WorkspaceRoot '.cursorrules') -PathType Leaf)) {
  Set-Content -LiteralPath (Join-Path $WorkspaceRoot '.cursorrules') -Encoding UTF8 -Value '# cursor'
}
if (-not (Test-Path -LiteralPath (Join-Path $WorkspaceRoot '.clinerules') -PathType Leaf)) {
  Set-Content -LiteralPath (Join-Path $WorkspaceRoot '.clinerules') -Encoding UTF8 -Value '# cline'
}
if (-not (Test-Path -LiteralPath (Join-Path $WorkspaceRoot '.rayman.env.ps1') -PathType Leaf)) {
  Set-Content -LiteralPath (Join-Path $WorkspaceRoot '.rayman.env.ps1') -Encoding UTF8 -Value ''
}
if (-not (Test-Path -LiteralPath (Join-Path $WorkspaceRoot '.github\\copilot-instructions.md') -PathType Leaf)) {
  Set-Content -LiteralPath (Join-Path $WorkspaceRoot '.github\\copilot-instructions.md') -Encoding UTF8 -Value '# instructions'
}

$auditPath = Join-Path $runtimeDir 'stub.setup.invocations.jsonl'
$runIndex = [int](@((Get-Content -LiteralPath $auditPath -ErrorAction SilentlyContinue)).Count + 1)
$entry = [ordered]@{
  index = $runIndex
  alert_done = [string][Environment]::GetEnvironmentVariable('RAYMAN_ALERT_DONE_ENABLED')
  alert_tts_done = [string][Environment]::GetEnvironmentVariable('RAYMAN_ALERT_TTS_DONE_ENABLED')
  tracked_assets_mode = [string][Environment]::GetEnvironmentVariable('RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS')
  skip_release_gate = [bool]$SkipReleaseGate
}
($entry | ConvertTo-Json -Compress) | Add-Content -LiteralPath $auditPath -Encoding UTF8

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmssfff'
$logPath = Join-Path $logsDir ("setup.win.{0}.log" -f $timestamp)
$trackedEntries = @(& git -C $WorkspaceRoot ls-files -- .Rayman/VERSION 2> $null)
$tracked = (@($trackedEntries | Where-Object { [string]$_ -eq '.Rayman/VERSION' }).Count -gt 0)

if ([string][Environment]::GetEnvironmentVariable('RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS') -eq '0' -and $tracked) {
  Set-Content -LiteralPath $logPath -Encoding UTF8 -Value 'tracked_rayman_assets_blocked'
  exit 18
}

$basePid = $runIndex * 100
$newPid1 = [int]($basePid + 1)
$newPid2 = [int]($basePid + 2)
$auditReport = [ordered]@{
  schema = 'rayman.vscode_windows.v1'
  workspace_root = $WorkspaceRoot
  new_pids = @($newPid1, $newPid2)
}
$auditReport | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runtimeDir 'vscode_windows.last.json') -Encoding UTF8
Set-Content -LiteralPath $logPath -Encoding UTF8 -Value ("pass={0}" -f $runIndex)
exit 0
'@

      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\project\run_project_gate.ps1') -Encoding UTF8 -Value @'
param(
  [string]$WorkspaceRoot,
  [string]$Lane = 'fast'
)

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime\project_gates'
New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
@{
  overall = 'PASS'
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runtimeDir 'fast.report.json') -Encoding UTF8
Write-Host '[fast-gate] overall=PASS'
exit 0
'@

      Set-Content -LiteralPath (Join-Path $root '.Rayman\VERSION') -Encoding UTF8 -Value 'V161'
      Set-Content -LiteralPath (Join-Path $root '.SolutionName') -Encoding UTF8 -Value 'CopySmokeTest'
      Set-Content -LiteralPath (Join-Path $root '.cursorrules') -Encoding UTF8 -Value '# cursor'
      Set-Content -LiteralPath (Join-Path $root '.clinerules') -Encoding UTF8 -Value '# cline'
      Set-Content -LiteralPath (Join-Path $root '.rayman.env.ps1') -Encoding UTF8 -Value ''
      Set-Content -LiteralPath (Join-Path $root '.github\copilot-instructions.md') -Encoding UTF8 -Value '# instructions'

      $psPath = Get-TestPowerShellPath
      $output = & $psPath -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root '.Rayman\scripts\release\copy_smoke.ps1') -WorkspaceRoot $root -Strict -KeepTemp 2>&1 | Out-String

      $LASTEXITCODE | Should -Be 0
      $match = [regex]::Match($output, 'kept temp workspace: (?<path>[^\r\n]+)')
      $match.Success | Should -Be $true
      $keptTempRoot = [string]$match.Groups['path'].Value.Trim()
      (Test-Path -LiteralPath $keptTempRoot -PathType Container) | Should -Be $true

      $setupRuns = Get-Content -LiteralPath (Join-Path $keptTempRoot '.Rayman\runtime\copy_smoke_setup_runs.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      @($setupRuns).Count | Should -Be 4
      (@($setupRuns | ForEach-Object { [string]$_.PassName }) -join ',') | Should -Be '01-fresh-pass,02-tracked-assets-block-pass,03-explicit-allow-pass,04-stable-rerun-pass'

      $invocations = @(Get-Content -LiteralPath (Join-Path $keptTempRoot '.Rayman\runtime\stub.setup.invocations.jsonl') -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
      @($invocations).Count | Should -Be 4
      foreach ($invocation in $invocations) {
        [string]$invocation.alert_done | Should -Be '0'
        [string]$invocation.alert_tts_done | Should -Be '0'
      }

      foreach ($setupRun in @($setupRuns)) {
        (Test-Path -LiteralPath ([string]$setupRun.SetupLogArchivePath) -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath ([string]$setupRun.VsCodeAuditArchivePath) -PathType Leaf) | Should -Be $true
      }
    } finally {
      if (-not [string]::IsNullOrWhiteSpace($keptTempRoot)) {
        Remove-Item -LiteralPath $keptTempRoot -Recurse -Force -ErrorAction SilentlyContinue
      }
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'repo hygiene ignore contracts' {
  It 'keeps runtime outputs and root testResults.xml ignored' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
    $gitignoreRaw = Get-Content -LiteralPath (Join-Path $repoRoot '.gitignore') -Raw -Encoding UTF8

    $gitignoreRaw | Should -Match '\.Rayman/runtime/'
    $gitignoreRaw | Should -Match '(?m)^/testResults\.xml$'
  }
}
