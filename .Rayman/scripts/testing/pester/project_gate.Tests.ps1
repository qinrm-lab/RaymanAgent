BeforeAll {
  . (Join-Path $PSScriptRoot '..\..\..\common.ps1')
  . (Join-Path $PSScriptRoot '..\..\project\project_gate.lib.ps1')
  function Invoke-WithSourceProjectGateStateIsolation {
    param([scriptblock]$Body)

    $sourceRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..') | Select-Object -ExpandProperty Path
    $configPath = Join-Path $sourceRoot '.rayman.project.json'
    $reportPath = Join-Path $sourceRoot '.Rayman\runtime\project_gates\fast.report.json'
    $configBackupPath = ''
    $reportBackupPath = ''

    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
      $configBackupPath = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_project_gate_config_backup_' + [Guid]::NewGuid().ToString('N') + '.json')
      Copy-Item -LiteralPath $configPath -Destination $configBackupPath -Force
      Remove-Item -LiteralPath $configPath -Force
    }

    if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
      $reportBackupPath = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_project_gate_report_backup_' + [Guid]::NewGuid().ToString('N') + '.json')
      Copy-Item -LiteralPath $reportPath -Destination $reportBackupPath -Force
    }

    try {
      & $Body $sourceRoot $configPath
    } finally {
      if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
      }
      if (-not [string]::IsNullOrWhiteSpace($configBackupPath) -and (Test-Path -LiteralPath $configBackupPath -PathType Leaf)) {
        Move-Item -LiteralPath $configBackupPath -Destination $configPath -Force
      }

      if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
        Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue
      }
      if (-not [string]::IsNullOrWhiteSpace($reportBackupPath) -and (Test-Path -LiteralPath $reportBackupPath -PathType Leaf)) {
        Move-Item -LiteralPath $reportBackupPath -Destination $reportPath -Force
      }
    }
  }
}

Describe 'run_project_gate Windows process cleanup' {
  It 'ignores concurrent workspace-matching processes that are outside the gate launcher tree' {
    if (-not (Test-RaymanWindowsPlatform)) {
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_project_gate_concurrent_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      . (Join-Path $PSScriptRoot '..\..\utils\workspace_process_ownership.ps1') -NoMain

      $launcherStart = [datetime]::UtcNow.AddSeconds(-8).ToString('o')
      $childStart = [datetime]::UtcNow.AddSeconds(-6).ToString('o')
      $concurrentStart = [datetime]::UtcNow.AddSeconds(-4).ToString('o')
      $currentSnapshot = @(
        [pscustomobject]@{
          pid = 4100
          parent_pid = 4
          process_name = 'powershell'
          start_utc = $launcherStart
          command_line = ('powershell.exe -File "{0}"' -f (Join-Path $root '.Rayman\scripts\project\run_project_gate.ps1'))
          executable_path = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        }
        [pscustomobject]@{
          pid = 4200
          parent_pid = 4100
          process_name = 'powershell'
          start_utc = $childStart
          command_line = ('powershell.exe -File "{0}"' -f (Join-Path $root 'gate-child.ps1'))
          executable_path = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        }
        [pscustomobject]@{
          pid = 4300
          parent_pid = 9000
          process_name = 'powershell'
          start_utc = $concurrentStart
          command_line = ('powershell.exe -File "{0}"' -f (Join-Path $root 'manual-task.ps1'))
          executable_path = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        }
      )

      Mock Register-RaymanWorkspaceOwnedProcess {
        param([string]$WorkspaceRootPath, [object]$OwnerContext, [string]$Kind, [string]$Launcher, [int]$RootPid, [string]$Command)
        [pscustomobject]@{
          workspace_root = $WorkspaceRootPath
          owner_key = 'owner-a'
          owner_display = 'owner-a'
          kind = $Kind
          launcher = $Launcher
          root_pid = $RootPid
          command = $Command
        }
      }
      Mock Stop-RaymanWorkspaceOwnedProcess {
        param([string]$WorkspaceRootPath, [object]$Record, [string]$Reason)
        [pscustomobject]@{
          root_pid = [int]$Record.root_pid
          cleanup_reason = $Reason
          cleanup_result = 'cleaned'
          cleanup_pids = @([int]$Record.root_pid)
          alive_pids = @()
        }
      }
      Mock Get-RaymanWorkspaceProcessOwnerContext {
        [pscustomobject]@{
          owner_key = 'owner-a'
          owner_display = 'owner-a'
        }
      }

      $cleanup = Invoke-RaymanWorkspaceOwnedProcessCleanupFromBaseline -WorkspaceRootPath $root -BaselineSnapshot @() -CurrentSnapshot $currentSnapshot -BaselineCapturedAtUtc ([datetime]::UtcNow.AddMinutes(-1)) -LauncherProcessId 4100 -OwnedKind 'project-gate' -OwnedLauncher 'project-gate' -OwnedCommand 'powershell run_project_gate' -CleanupReason 'project-gate'

      @([int[]]$cleanup.matched_pids) | Should -Be @(4100, 4200)
      @([int[]]$cleanup.cleanup_root_pids) | Should -Be @(4100)
      @([int[]]$cleanup.alive_pids) | Should -Be @()
      Assert-MockCalled Stop-RaymanWorkspaceOwnedProcess -Times 1 -Exactly -Scope It -ParameterFilter {
        [int]$Record.root_pid -eq 4100
      }
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'cleans orphaned workspace-owned child processes after a successful fast-lane command' {
    if (-not (Test-RaymanWindowsPlatform)) {
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_project_gate_orphan_' + [Guid]::NewGuid().ToString('N'))
    $pidFile = Join-Path $root '.Rayman\runtime\gate_orphan.pid'
    $childPid = 0
    try {
      Copy-ProjectGateRunnerFixture -Root $root -AdditionalRelativePaths @('.Rayman\scripts\utils\workspace_process_ownership.ps1')
      Write-MinimalProjectGateScripts -Root $root
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime') | Out-Null

      Set-Content -LiteralPath (Join-Path $root '.rayman.project.json') -Encoding UTF8 -Value @'
{
  "schema": "rayman.project_config.v1",
  "build_command": "& '.\\spawn-orphan.ps1'"
}
'@

      Set-Content -LiteralPath (Join-Path $root 'child.ps1') -Encoding UTF8 -Value @'
param([Parameter(Mandatory = $true)][string]$PidFile)
Set-Content -LiteralPath $PidFile -Value $PID -Encoding ASCII
Start-Sleep -Seconds 600
'@

      $spawnScript = @'
$childScript = Join-Path $PSScriptRoot 'child.ps1'
$pidFile = Join-Path $PSScriptRoot '.Rayman\runtime\gate_orphan.pid'
$child = Start-Process -FilePath '__POWERSHELL__' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $childScript, '-PidFile', $pidFile) -PassThru -WindowStyle Hidden
$deadline = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
  Start-Sleep -Milliseconds 100
}
if (-not (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
  throw 'child pid file not written'
}
Write-Output ('child=' + $child.Id)
'@
      $spawnScript = $spawnScript.Replace('__POWERSHELL__', (Get-TestPowerShellPath).Replace("'", "''"))
      Set-Content -LiteralPath (Join-Path $root 'spawn-orphan.ps1') -Encoding UTF8 -Value $spawnScript

      $raw = & (Join-Path $root '.Rayman\scripts\project\run_project_gate.ps1') -WorkspaceRoot $root -Lane fast -Json
      $report = $raw | ConvertFrom-Json
      $buildCheck = @($report.checks | Where-Object { $_.key -eq 'build' })[0]
      $buildLog = Get-Content -LiteralPath $buildCheck.log_path -Raw -Encoding UTF8

      $childPid = [int]((Get-Content -LiteralPath $pidFile -Raw -Encoding ASCII).Trim())

      $buildCheck.status | Should -Be 'PASS'
      $buildCheck.detail | Should -Match 'process_cleanup=cleaned'
      $buildLog | Should -Match 'process cleanup summary'
      (Get-Process -Id $childPid -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
    } finally {
      if ($childPid -gt 0) {
        try { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue } catch {}
      }
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'fails timed-out commands but still cleans workspace-owned child processes' {
    if (-not (Test-RaymanWindowsPlatform)) {
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_project_gate_timeout_' + [Guid]::NewGuid().ToString('N'))
    $pidFile = Join-Path $root '.Rayman\runtime\gate_timeout.pid'
    $childPid = 0
    $timeoutBackup = [string][Environment]::GetEnvironmentVariable('RAYMAN_PROJECT_GATE_TIMEOUT_SECONDS')
    try {
      Copy-ProjectGateRunnerFixture -Root $root -AdditionalRelativePaths @('.Rayman\scripts\utils\workspace_process_ownership.ps1')
      Write-MinimalProjectGateScripts -Root $root
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime') | Out-Null

      Set-Content -LiteralPath (Join-Path $root '.rayman.project.json') -Encoding UTF8 -Value @'
{
  "schema": "rayman.project_config.v1",
  "build_command": "& '.\\spawn-timeout.ps1'"
}
'@

      Set-Content -LiteralPath (Join-Path $root 'child.ps1') -Encoding UTF8 -Value @'
param([Parameter(Mandatory = $true)][string]$PidFile)
Set-Content -LiteralPath $PidFile -Value $PID -Encoding ASCII
Start-Sleep -Seconds 60
'@

      $spawnTimeoutScript = @'
$childScript = Join-Path $PSScriptRoot 'child.ps1'
$pidFile = Join-Path $PSScriptRoot '.Rayman\runtime\gate_timeout.pid'
$child = Start-Process -FilePath '__POWERSHELL__' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $childScript, '-PidFile', $pidFile) -PassThru -WindowStyle Hidden
$deadline = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
  Start-Sleep -Milliseconds 100
}
if (-not (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
  throw 'child pid file not written'
}
Start-Sleep -Seconds 30
'@
      $spawnTimeoutScript = $spawnTimeoutScript.Replace('__POWERSHELL__', (Get-TestPowerShellPath).Replace("'", "''"))
      Set-Content -LiteralPath (Join-Path $root 'spawn-timeout.ps1') -Encoding UTF8 -Value $spawnTimeoutScript

      [Environment]::SetEnvironmentVariable('RAYMAN_PROJECT_GATE_TIMEOUT_SECONDS', '2')
      $raw = & (Join-Path $root '.Rayman\scripts\project\run_project_gate.ps1') -WorkspaceRoot $root -Lane fast -Json
      $report = $raw | ConvertFrom-Json
      $buildCheck = @($report.checks | Where-Object { $_.key -eq 'build' })[0]
      $buildLog = Get-Content -LiteralPath $buildCheck.log_path -Raw -Encoding UTF8

      $childPid = [int]((Get-Content -LiteralPath $pidFile -Raw -Encoding ASCII).Trim())

      $buildCheck.status | Should -Be 'FAIL'
      [int]$buildCheck.exit_code | Should -Be 124
      $buildCheck.detail | Should -Match 'timed_out=true'
      $buildCheck.detail | Should -Match 'process_cleanup=cleaned'
      $buildLog | Should -Match 'process cleanup summary'
      (Get-Process -Id $childPid -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_PROJECT_GATE_TIMEOUT_SECONDS', $timeoutBackup)
      if ($childPid -gt 0) {
        try { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue } catch {}
      }
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'does not kill matching workspace processes that already existed before the gate command started' {
    if (-not (Test-RaymanWindowsPlatform)) {
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_project_gate_baseline_' + [Guid]::NewGuid().ToString('N'))
    $pidFile = Join-Path $root '.Rayman\runtime\baseline_existing.pid'
    $existingPid = 0
    try {
      Copy-ProjectGateRunnerFixture -Root $root -AdditionalRelativePaths @('.Rayman\scripts\utils\workspace_process_ownership.ps1')
      Write-MinimalProjectGateScripts -Root $root
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime') | Out-Null

      Set-Content -LiteralPath (Join-Path $root '.rayman.project.json') -Encoding UTF8 -Value @'
{
  "schema": "rayman.project_config.v1",
  "build_command": "Write-Output 'baseline-safe'"
}
'@

      $cmdHost = (Get-Command 'cmd.exe' -ErrorAction Stop | Select-Object -ExpandProperty Source -First 1)
      $commandLine = ('set RAYMAN_WORKSPACE_TOKEN={0} && ping -t 127.0.0.1 >nul' -f $root)
      $existingProcess = Start-Process -FilePath $cmdHost -ArgumentList @('/d', '/c', $commandLine) -PassThru -WindowStyle Hidden
      $existingPid = [int]$existingProcess.Id
      (Get-Process -Id $existingPid -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id) | Should -Be $existingPid
      . (Join-Path $root '.Rayman\scripts\utils\workspace_process_ownership.ps1')
      $snapshotVisible = $false
      $snapshotDeadline = (Get-Date).AddSeconds(10)
      while ((Get-Date) -lt $snapshotDeadline) {
        $snapshot = @(Get-RaymanWorkspaceProcessSnapshot -WorkspaceRootPath $root)
        if (@($snapshot | Where-Object { [int]$_.pid -eq $existingPid }).Count -gt 0) {
          $snapshotVisible = $true
          break
        }
        Start-Sleep -Milliseconds 100
      }
      $snapshotVisible | Should -Be $true

      $raw = & (Join-Path $root '.Rayman\scripts\project\run_project_gate.ps1') -WorkspaceRoot $root -Lane fast -Json
      $report = $raw | ConvertFrom-Json
      $buildCheck = @($report.checks | Where-Object { $_.key -eq 'build' })[0]

      $buildCheck.status | Should -Be 'PASS'
      (Get-Process -Id $existingPid -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id) | Should -Be $existingPid

      try { Stop-Process -Id $existingProcess.Id -Force -ErrorAction SilentlyContinue } catch {}
    } finally {
      if ($existingPid -gt 0) {
        try { Stop-Process -Id $existingPid -Force -ErrorAction SilentlyContinue } catch {}
      }
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

function script:Get-TestPowerShellPath {
  $cmd = Get-Command 'pwsh' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
    return [string]$cmd.Source
  }

  $cmd = Get-Command 'powershell' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
    return [string]$cmd.Source
  }

  throw 'pwsh/powershell not found for mapped hold process'
}

function script:Invoke-ProjectGateJsonInChildPowerShell {
  param(
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [string]$Lane = 'fast',
    [hashtable]$Environment = @{}
  )

  $psHost = Get-TestPowerShellPath
  $scriptPath = Join-Path $WorkspaceRoot '.Rayman\scripts\project\run_project_gate.ps1'
  $workspaceLiteral = $WorkspaceRoot.Replace("'", "''")
  $scriptLiteral = $scriptPath.Replace("'", "''")
  $laneLiteral = $Lane.Replace("'", "''")

  $envLines = New-Object System.Collections.Generic.List[string]
  foreach ($entry in $Environment.GetEnumerator()) {
    $keyLiteral = ([string]$entry.Key).Replace("'", "''")
    if ($null -eq $entry.Value) {
      $envLines.Add(("[Environment]::SetEnvironmentVariable('{0}', `$null)" -f $keyLiteral)) | Out-Null
    } else {
      $valueLiteral = ([string]$entry.Value).Replace("'", "''")
      $envLines.Add(("[Environment]::SetEnvironmentVariable('{0}', '{1}')" -f $keyLiteral, $valueLiteral)) | Out-Null
    }
  }

  $commandBody = @"
`$ErrorActionPreference = 'Stop'
$($envLines -join [Environment]::NewLine)
& '$scriptLiteral' -WorkspaceRoot '$workspaceLiteral' -Lane '$laneLiteral' -Json
"@

  $raw = & $psHost -NoProfile -ExecutionPolicy Bypass -Command $commandBody
  $jsonText = ($raw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
  return ($jsonText | ConvertFrom-Json -ErrorAction Stop)
}

function script:Start-TestMappedFileHoldProcess {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$SleepMs = 350
  )

  $token = [Guid]::NewGuid().ToString('N')
  $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("rayman_project_gate_hold_{0}.ps1" -f $token)
  $readyPath = Join-Path ([System.IO.Path]::GetTempPath()) ("rayman_project_gate_hold_{0}.ready" -f $token)
  @'
param(
  [Parameter(Mandatory = $true)][string]$TargetPath,
  [Parameter(Mandatory = $true)][string]$ReadyPath,
  [int]$SleepMs = 350
)

$mmf = $null
$view = $null
try {
  $mmf = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateFromFile($TargetPath, [System.IO.FileMode]::Open, ('rayman_project_gate_hold_' + [Guid]::NewGuid().ToString('N')), 0)
  $view = $mmf.CreateViewAccessor()
  New-Item -ItemType File -Force -Path $ReadyPath | Out-Null
  Start-Sleep -Milliseconds $SleepMs
} finally {
  try { if ($null -ne $view) { $view.Dispose() } } catch {}
  try { if ($null -ne $mmf) { $mmf.Dispose() } } catch {}
}
'@ | Set-Content -LiteralPath $scriptPath -Encoding UTF8

  $startProcessParams = @{
    FilePath = (Get-TestPowerShellPath)
    ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-TargetPath', $Path, '-ReadyPath', $readyPath, '-SleepMs', [string]$SleepMs)
    PassThru = $true
  }
  if (Test-RaymanWindowsPlatform) {
    $startProcessParams.WindowStyle = 'Hidden'
  }
  $process = Start-Process @startProcessParams

  $deadline = (Get-Date).AddSeconds(5)
  while (-not (Test-Path -LiteralPath $readyPath) -and -not $process.HasExited -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 25
  }
  if (-not (Test-Path -LiteralPath $readyPath)) {
    try { if (-not $process.HasExited) { $process.Kill() } } catch {}
    Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue
    throw ("failed to acquire mapped file hold for {0}" -f $Path)
  }

  return [pscustomobject]@{
    Process = $process
    ScriptPath = $scriptPath
    ReadyPath = $readyPath
  }
}

function script:Stop-TestMappedFileHoldProcess {
  param([object]$Handle)

  if ($null -eq $Handle) {
    return
  }

  try {
    if ($null -ne $Handle.Process) {
      try {
        if (-not $Handle.Process.HasExited) {
          [void]$Handle.Process.WaitForExit(5000)
        }
      } catch {}
      try {
        if (-not $Handle.Process.HasExited) {
          $Handle.Process.Kill()
        }
      } catch {}
      try { $Handle.Process.Dispose() } catch {}
    }
  } finally {
    Remove-Item -LiteralPath $Handle.ScriptPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Handle.ReadyPath -Force -ErrorAction SilentlyContinue
  }
}

function script:Copy-ProjectGateRunnerFixture {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [string[]]$AdditionalRelativePaths = @()
  )

  $sourceRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..') | Select-Object -ExpandProperty Path
  $paths = @(
    '.Rayman\common.ps1'
    '.Rayman\scripts\project\project_gate.lib.ps1'
    '.Rayman\scripts\project\run_project_gate.ps1'
  ) + @($AdditionalRelativePaths)

  foreach ($rel in @($paths | Select-Object -Unique)) {
    $src = Join-Path $sourceRoot $rel
    $dst = Join-Path $Root $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    Copy-Item -LiteralPath $src -Destination $dst -Force
  }
}

function script:Write-MinimalProjectGateScripts {
  param(
    [Parameter(Mandatory = $true)][string]$Root
  )

  New-Item -ItemType Directory -Force -Path (Join-Path $Root '.Rayman\scripts\ci') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $Root '.Rayman\scripts\release') | Out-Null
  Set-Content -LiteralPath (Join-Path $Root '.Rayman\scripts\ci\validate_requirements.sh') -Encoding UTF8 -Value @'
#!/usr/bin/env bash
set -euo pipefail
printf requirements-ok
'@
  Set-Content -LiteralPath (Join-Path $Root '.Rayman\scripts\release\config_sanity.sh') -Encoding UTF8 -Value @'
#!/usr/bin/env bash
set -euo pipefail
printf config-sanity-ok
'@
}

Describe 'project gate command semantics' {
  It 'marks empty consumer commands as SKIP in source workspaces' {
    $check = New-RaymanProjectGateEmptyCommandCheck -Key 'build' -Name 'Build' -Action 'configure build' -LogPath 'fast.build.log' -WorkspaceKind 'source' -WarnWhenEmpty

    $check.status | Should -Be 'SKIP'
    $check.detail | Should -Be 'source workspace; consumer-only project config not applicable'
    $check.action | Should -Be ''
  }

  It 'keeps empty consumer commands as WARN in external workspaces' {
    $check = New-RaymanProjectGateEmptyCommandCheck -Key 'build' -Name 'Build' -Action 'configure build' -LogPath 'fast.build.log' -WorkspaceKind 'external' -WarnWhenEmpty

    $check.status | Should -Be 'WARN'
    $check.detail | Should -Be 'command not configured'
    $check.action | Should -Be 'configure build'
  }
}

Describe 'project workflow generation' {
  It 'creates managed consumer workflows and project config for external workspaces' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_project_workflow_' + [Guid]::NewGuid().ToString('N'))
    try {
      $sourceRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..') | Select-Object -ExpandProperty Path
      $pathsToCopy = @(
        '.Rayman\common.ps1'
        '.Rayman\scripts\project\project_gate.lib.ps1'
        '.Rayman\scripts\project\generate_project_workflows.ps1'
        '.Rayman\templates\workflows\rayman-project-fast-gate.yml'
        '.Rayman\templates\workflows\rayman-project-browser-gate.yml'
        '.Rayman\templates\workflows\rayman-project-full-gate.yml'
      )

      foreach ($rel in $pathsToCopy) {
        $src = Join-Path $sourceRoot $rel
        $dst = Join-Path $root $rel
        $parent = Split-Path -Parent $dst
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force
      }

      $configPath = Join-Path $root '.rayman.project.json'
      Set-Content -LiteralPath $configPath -Encoding UTF8 -Value @'
{
  "schema": "rayman.project_config.v1",
  "project_name": "RaymanConsumer",
  "build_command": "npm run build",
  "browser_command": "npx playwright test --project chromium",
  "full_gate_command": "npm run ci:full",
  "enable_windows": true,
  "path_filters": {
    "fast": [
      ".Rayman/**",
      "src/**"
    ],
    "browser": [
      "src/**",
      "test-*.js"
    ],
    "full": [
      ".Rayman/**",
      ".github/workflows/**"
    ]
  },
  "extensions": {
    "project_fast_checks": "npm test -- --runInBand",
    "project_browser_checks": "",
    "project_release_checks": "npm run release:check"
  }
}
'@

      & (Join-Path $root '.Rayman\scripts\project\generate_project_workflows.ps1') -WorkspaceRoot $root

      $fastWorkflow = Join-Path $root '.github\workflows\rayman-project-fast-gate.yml'
      $browserWorkflow = Join-Path $root '.github\workflows\rayman-project-browser-gate.yml'
      $fullWorkflow = Join-Path $root '.github\workflows\rayman-project-full-gate.yml'

      foreach ($path in @($fastWorkflow, $browserWorkflow, $fullWorkflow)) {
        Test-Path -LiteralPath $path -PathType Leaf | Should -Be $true
      }

      $fastRaw = Get-Content -LiteralPath $fastWorkflow -Raw -Encoding UTF8
      $browserRaw = Get-Content -LiteralPath $browserWorkflow -Raw -Encoding UTF8
      $fullRaw = Get-Content -LiteralPath $fullWorkflow -Raw -Encoding UTF8

      $fastRaw | Should -Match 'Rayman managed workflow'
      $fastRaw | Should -Match 'fast-gate-windows'
      $fastRaw | Should -Match "'src/\*\*'"
      $browserRaw | Should -Match "'test-\*\.js'"
      $fullRaw | Should -Match 'schedule:'
      $fullRaw | Should -Match 'full-gate-windows'
      $fullRaw | Should -Not -Match '\{\{[A-Z_]+\}\}'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'reruns workflow generation under mapped file pressure and records recovery in audit' {
    if (-not (Test-RaymanWindowsPlatform)) {
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_project_workflow_retry_' + [Guid]::NewGuid().ToString('N'))
    $mappedHold = $null
    try {
      $sourceRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..') | Select-Object -ExpandProperty Path
      $pathsToCopy = @(
        '.Rayman\common.ps1'
        '.Rayman\scripts\project\project_gate.lib.ps1'
        '.Rayman\scripts\project\generate_project_workflows.ps1'
        '.Rayman\templates\workflows\rayman-project-fast-gate.yml'
        '.Rayman\templates\workflows\rayman-project-browser-gate.yml'
        '.Rayman\templates\workflows\rayman-project-full-gate.yml'
      )

      foreach ($rel in $pathsToCopy) {
        $src = Join-Path $sourceRoot $rel
        $dst = Join-Path $root $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force
      }

      $configPath = Join-Path $root '.rayman.project.json'
      Set-Content -LiteralPath $configPath -Encoding UTF8 -Value @'
{
  "schema": "rayman.project_config.v1",
  "project_name": "RaymanConsumer",
  "build_command": "npm run build",
  "browser_command": "npx playwright test --project chromium",
  "full_gate_command": "npm run ci:full",
  "enable_windows": true,
  "path_filters": {
    "fast": [
      ".Rayman/**",
      "src/**"
    ],
    "browser": [
      "src/**",
      "test-*.js"
    ],
    "full": [
      ".Rayman/**",
      ".github/workflows/**"
    ]
  }
}
'@

      & (Join-Path $root '.Rayman\scripts\project\generate_project_workflows.ps1') -WorkspaceRoot $root

      $fastWorkflow = Join-Path $root '.github\workflows\rayman-project-fast-gate.yml'
      $mappedHold = Start-TestMappedFileHoldProcess -Path $fastWorkflow -SleepMs 325

      Set-Content -LiteralPath $configPath -Encoding UTF8 -Value @'
{
  "schema": "rayman.project_config.v1",
  "project_name": "RaymanConsumer",
  "build_command": "npm run build:ci",
  "browser_command": "npx playwright test --project chromium",
  "full_gate_command": "npm run ci:full",
  "enable_windows": true,
  "path_filters": {
    "fast": [
      ".Rayman/**",
      "src-ci/**"
    ],
    "browser": [
      "src/**",
      "test-*.js"
    ],
    "full": [
      ".Rayman/**",
      ".github/workflows/**"
    ]
  }
}
'@

      & (Join-Path $root '.Rayman\scripts\project\generate_project_workflows.ps1') -WorkspaceRoot $root

      $auditPath = Join-Path $root '.Rayman\runtime\managed_write.last.json'
      $audit = Get-Content -LiteralPath $auditPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $recentWrites = @($audit.recent_writes)
      $recoveredFastWorkflow = @($recentWrites | Where-Object {
          $null -ne $_ -and
          ([string]$_.mode -eq 'retry_success' -or [string]$_.mode -eq 'in_place_fallback') -and
          ([string]$_.path).Replace('\', '/').ToLowerInvariant().EndsWith('.github/workflows/rayman-project-fast-gate.yml')
        })

      @($recoveredFastWorkflow).Count | Should -BeGreaterThan 0
    } finally {
      Stop-TestMappedFileHoldProcess -Handle $mappedHold
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'classifies a workspace with internal workflow and requirements markers as source' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_kind_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\testing') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.RaymanAgent') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.github\workflows') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\testing\run_fast_contract.sh') -Value '#!/usr/bin/env bash' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.RaymanAgent\.RaymanAgent.requirements.md') -Value '# requirements' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.github\workflows\rayman-test-lanes.yml') -Value 'name: rayman-test-lanes' -Encoding UTF8

      Get-RaymanWorkspaceKind -WorkspaceRoot $root | Should -Be 'source'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'run_project_gate fast lane' {
  It 'returns SKIP for empty consumer commands in the source workspace' {
    Invoke-WithSourceProjectGateStateIsolation {
      param($sourceRoot, $configPath)

      $raw = & (Join-Path $sourceRoot '.Rayman\scripts\project\run_project_gate.ps1') -WorkspaceRoot $sourceRoot -Lane fast -Json
      $report = $raw | ConvertFrom-Json
      $configCheck = @($report.checks | Where-Object { $_.key -eq 'project_config' })[0]
      $buildCheck = @($report.checks | Where-Object { $_.key -eq 'build' })[0]
      $smokeCheck = @($report.checks | Where-Object { $_.key -eq 'project_smoke' })[0]

      $configCheck.status | Should -Be 'PASS'
      $buildCheck.status | Should -Be 'SKIP'
      $smokeCheck.status | Should -Be 'SKIP'
      $buildCheck.detail | Should -Be 'source workspace; consumer-only project config not applicable'
      $smokeCheck.detail | Should -Be 'source workspace; consumer-only project config not applicable'
    }
  }

  It 'executes explicitly configured commands in the source workspace' {
    Invoke-WithSourceProjectGateStateIsolation {
      param($sourceRoot, $configPath)

      Set-Content -LiteralPath $configPath -Encoding UTF8 -Value @'
{
  "schema": "rayman.project_config.v1",
  "build_command": "Write-Output 'source-build'",
  "extensions": {
    "project_fast_checks": "Write-Output 'source-smoke'"
  }
}

'@

      $allowBackup = [string][Environment]::GetEnvironmentVariable('RAYMAN_ALLOW_MISSING_BASE_REF')
      $reasonBackup = [string][Environment]::GetEnvironmentVariable('RAYMAN_BYPASS_REASON')
      try {
        [Environment]::SetEnvironmentVariable('RAYMAN_ALLOW_MISSING_BASE_REF', '1')
        [Environment]::SetEnvironmentVariable('RAYMAN_BYPASS_REASON', 'pester-source-fast-lane')

        $raw = & (Join-Path $sourceRoot '.Rayman\scripts\project\run_project_gate.ps1') -WorkspaceRoot $sourceRoot -Lane fast -Json
        $report = $raw | ConvertFrom-Json
        $buildCheck = @($report.checks | Where-Object { $_.key -eq 'build' })[0]
        $smokeCheck = @($report.checks | Where-Object { $_.key -eq 'project_smoke' })[0]

        $buildCheck.status | Should -Be 'PASS'
        $smokeCheck.status | Should -Be 'PASS'
        $buildCheck.command | Should -Be "Write-Output 'source-build'"
        $smokeCheck.command | Should -Be "Write-Output 'source-smoke'"
      } finally {
        [Environment]::SetEnvironmentVariable('RAYMAN_ALLOW_MISSING_BASE_REF', $allowBackup)
        [Environment]::SetEnvironmentVariable('RAYMAN_BYPASS_REASON', $reasonBackup)
      }
    }
  }

  It 'uses bash-safe paths for fast lane shell scripts on Windows' {
    if (-not (Test-RaymanWindowsPlatform)) {
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_project_gate_bash_' + [Guid]::NewGuid().ToString('N'))
    $fakeBashRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_project_gate_fake_bash_' + [Guid]::NewGuid().ToString('N'))
    $bashEnvBackup = [string][Environment]::GetEnvironmentVariable('RAYMAN_BASH_PATH')
    try {
      $sourceRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..') | Select-Object -ExpandProperty Path
      foreach ($rel in @(
        '.Rayman\common.ps1',
        '.Rayman\scripts\project\project_gate.lib.ps1',
        '.Rayman\scripts\project\run_project_gate.ps1'
      )) {
        $src = Join-Path $sourceRoot $rel
        $dst = Join-Path $root $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force
      }

      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\ci') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\release') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.rayman.project.json') -Encoding UTF8 -Value @'
{
  "schema": "rayman.project_config.v1"
}
'@
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\ci\validate_requirements.sh') -Encoding UTF8 -Value @'
#!/usr/bin/env bash
set -euo pipefail
printf requirements-ok
'@
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\release\config_sanity.sh') -Encoding UTF8 -Value @'
#!/usr/bin/env bash
set -euo pipefail
printf config-sanity-ok
'@
      New-Item -ItemType Directory -Force -Path $fakeBashRoot | Out-Null
      Set-Content -LiteralPath (Join-Path $fakeBashRoot 'bash.cmd') -Encoding ASCII -Value @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-bash.ps1" %*
exit /b %ERRORLEVEL%
'@
      Set-Content -LiteralPath (Join-Path $fakeBashRoot 'fake-bash.ps1') -Encoding UTF8 -Value @'
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Rest
)

$commandText = ''
if (@($Rest).Count -ge 2 -and [string]$Rest[0] -eq '-lc') {
  $commandText = (@($Rest[1..(@($Rest).Count - 1)]) -join ' ')
} elseif (@($Rest).Count -ge 4 -and [string]$Rest[0] -eq '-e' -and [string]$Rest[1] -eq 'bash' -and [string]$Rest[2] -eq '-lc') {
  $commandText = (@($Rest[3..(@($Rest).Count - 1)]) -join ' ')
}

Write-Output $commandText
if ($commandText -match 'validate_requirements\.sh') {
  Write-Output 'requirements-ok'
  exit 0
}
if ($commandText -match 'config_sanity\.sh') {
  Write-Output 'config-sanity-ok'
  exit 0
}
Write-Error ("unexpected bash command: {0}" -f $commandText)
exit 19
'@
      [Environment]::SetEnvironmentVariable('RAYMAN_BASH_PATH', (Join-Path $fakeBashRoot 'bash.cmd'))

      $raw = & (Join-Path $root '.Rayman\scripts\project\run_project_gate.ps1') -WorkspaceRoot $root -Lane fast -Json
      $report = $raw | ConvertFrom-Json
      $requirementsCheck = @($report.checks | Where-Object { $_.key -eq 'requirements_layout' })[0]
      $protectedCheck = @($report.checks | Where-Object { $_.key -eq 'protected_assets' })[0]
      $requirementsLog = Get-Content -LiteralPath $requirementsCheck.log_path -Raw -Encoding UTF8
      $protectedLog = Get-Content -LiteralPath $protectedCheck.log_path -Raw -Encoding UTF8

      $requirementsCheck.status | Should -Be 'PASS'
      $protectedCheck.status | Should -Be 'PASS'
      $requirementsLog | Should -Match 'requirements-ok'
      $protectedLog | Should -Match 'config-sanity-ok'
      $requirementsLog | Should -Match '(/mnt/|[A-Za-z]:/)'
      $protectedLog | Should -Match '(/mnt/|[A-Za-z]:/)'
      $requirementsLog | Should -Not -Match 'F:win'
      $protectedLog | Should -Not -Match 'F:win'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_BASH_PATH', $bashEnvBackup)
      Remove-Item -LiteralPath $fakeBashRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'fails missing base refs in fast lane unless the caller explicitly bypasses the requirements gate' {
    if (-not (Test-RaymanWindowsPlatform)) {
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_project_gate_missing_base_' + [Guid]::NewGuid().ToString('N'))
    $fakeBashRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_project_gate_missing_base_bash_' + [Guid]::NewGuid().ToString('N'))
    $envBackup = @{
      RAYMAN_ALLOW_MISSING_BASE_REF = [string][Environment]::GetEnvironmentVariable('RAYMAN_ALLOW_MISSING_BASE_REF')
      RAYMAN_BYPASS_REASON = [string][Environment]::GetEnvironmentVariable('RAYMAN_BYPASS_REASON')
      RAYMAN_BASE_REF = [string][Environment]::GetEnvironmentVariable('RAYMAN_BASE_REF')
      RAYMAN_DIFF_CHECK = [string][Environment]::GetEnvironmentVariable('RAYMAN_DIFF_CHECK')
      RAYMAN_BASH_PATH = [string][Environment]::GetEnvironmentVariable('RAYMAN_BASH_PATH')
    }
    try {
      $sourceRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..') | Select-Object -ExpandProperty Path
      foreach ($rel in @(
        '.Rayman\common.ps1',
        '.Rayman\scripts\project\project_gate.lib.ps1',
        '.Rayman\scripts\project\run_project_gate.ps1'
      )) {
        $src = Join-Path $sourceRoot $rel
        $dst = Join-Path $root $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force
      }

      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\ci') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\release') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\ci\validate_requirements.sh') -Encoding UTF8 -Value @'
#!/usr/bin/env bash
set -euo pipefail
printf requirements-ok
'@
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\release\config_sanity.sh') -Encoding UTF8 -Value @'
#!/usr/bin/env bash
set -euo pipefail
printf config-sanity-ok
'@
      New-Item -ItemType Directory -Force -Path $fakeBashRoot | Out-Null
      Set-Content -LiteralPath (Join-Path $fakeBashRoot 'bash.cmd') -Encoding ASCII -Value @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-bash.ps1" %*
exit /b %ERRORLEVEL%
'@
      Set-Content -LiteralPath (Join-Path $fakeBashRoot 'fake-bash.ps1') -Encoding UTF8 -Value @'
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Rest
)

$commandText = ''
if (@($Rest).Count -ge 2 -and [string]$Rest[0] -eq '-lc') {
  $commandText = (@($Rest[1..(@($Rest).Count - 1)]) -join ' ')
} elseif (@($Rest).Count -ge 4 -and [string]$Rest[0] -eq '-e' -and [string]$Rest[1] -eq 'bash' -and [string]$Rest[2] -eq '-lc') {
  $commandText = (@($Rest[3..(@($Rest).Count - 1)]) -join ' ')
}

Write-Output $commandText
if ($commandText -match 'validate_requirements\.sh') {
  if ([string]$env:RAYMAN_ALLOW_MISSING_BASE_REF -eq '1' -and -not [string]::IsNullOrWhiteSpace([string]$env:RAYMAN_BYPASS_REASON)) {
    Write-Output ('gate bypass: missing-base-ref reason=' + [string]$env:RAYMAN_BYPASS_REASON)
    exit 0
  }

  [Console]::Error.WriteLine('找不到 base ref：origin/main')
  exit 42
}

if ($commandText -match 'config_sanity\.sh') {
  Write-Output 'config-sanity-ok'
  exit 0
}

Write-Error ('unexpected bash command: ' + $commandText)
exit 19
'@

      & git @('init', '--initial-branch=feature', $root) | Out-Null
      Push-Location $root
      try {
        & git add . | Out-Null
        & git @('-c', 'user.name=Rayman Tests', '-c', 'user.email=rayman@example.com', 'commit', '-m', 'init') | Out-Null

        foreach ($name in @('RAYMAN_ALLOW_MISSING_BASE_REF', 'RAYMAN_BYPASS_REASON', 'RAYMAN_BASE_REF', 'RAYMAN_BASH_PATH')) {
          [Environment]::SetEnvironmentVariable($name, $null)
        }
        [Environment]::SetEnvironmentVariable('RAYMAN_DIFF_CHECK', '1')
        [Environment]::SetEnvironmentVariable('RAYMAN_BASH_PATH', (Join-Path $fakeBashRoot 'bash.cmd'))

        $reportFail = Invoke-ProjectGateJsonInChildPowerShell -WorkspaceRoot $root -Lane 'fast' -Environment @{
          RAYMAN_ALLOW_MISSING_BASE_REF = $null
          RAYMAN_BYPASS_REASON = $null
          RAYMAN_BASE_REF = $null
          RAYMAN_BASH_PATH = (Join-Path $fakeBashRoot 'bash.cmd')
          RAYMAN_DIFF_CHECK = '1'
        }
        $requirementsFail = @($reportFail.checks | Where-Object { $_.key -eq 'requirements_layout' })[0]
        $failLog = Get-Content -LiteralPath $requirementsFail.log_path -Raw -Encoding UTF8

        $requirementsFail.status | Should -Be 'FAIL'
        $failLog | Should -Match '找不到 base ref|missing-base-ref'

        $reportBypass = Invoke-ProjectGateJsonInChildPowerShell -WorkspaceRoot $root -Lane 'fast' -Environment @{
          RAYMAN_ALLOW_MISSING_BASE_REF = '1'
          RAYMAN_BYPASS_REASON = 'pester-missing-base-ref'
          RAYMAN_BASE_REF = $null
          RAYMAN_BASH_PATH = (Join-Path $fakeBashRoot 'bash.cmd')
          RAYMAN_DIFF_CHECK = '1'
        }
        $requirementsBypass = @($reportBypass.checks | Where-Object { $_.key -eq 'requirements_layout' })[0]
        $bypassLog = Get-Content -LiteralPath $requirementsBypass.log_path -Raw -Encoding UTF8

        $requirementsBypass.status | Should -Be 'PASS'
        $bypassLog | Should -Match 'gate bypass|base ref'
      } finally {
        Pop-Location
      }
    } finally {
      foreach ($name in $envBackup.Keys) {
        [Environment]::SetEnvironmentVariable($name, [string]$envBackup[$name])
      }
      Remove-Item -LiteralPath $fakeBashRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
