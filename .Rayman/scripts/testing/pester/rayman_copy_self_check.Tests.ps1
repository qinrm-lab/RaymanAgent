function script:Get-TestPowerShellPath {
  foreach ($candidate in @('pwsh', 'pwsh.exe', 'powershell', 'powershell.exe')) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
      return [string]$cmd.Source
    }
  }

  throw 'pwsh/powershell not found'
}

function script:Import-CopySmokeFunctions {
  param([string[]]$Names)

  $copySmokePath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path '.Rayman\scripts\release\copy_smoke.ps1'
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($copySmokePath, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) {
    throw $errors[0].Message
  }

  $functionMap = @{}
  foreach ($fn in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $functionMap[[string]$fn.Name] = $fn
  }

  foreach ($name in @($Names)) {
    $functionAst = $functionMap[[string]$name]
    if ($null -eq $functionAst) {
      throw ('function not found: ' + $name)
    }
    $definitionText = $functionAst.Extent.Text -replace ("(?i)^function\s+{0}" -f [regex]::Escape($name)), ("function script:{0}" -f $name)
    & ([scriptblock]::Create($definitionText))
  }
}

function script:Initialize-CopySmokeMockTargets {
  foreach ($scopePrefix in @('global', 'script')) {
    Set-Item -Path ("Function:\{0}:Get-RaymanVsCodeProcessSnapshot" -f $scopePrefix) -Value {
      param([string]$WorkspaceRootPath)
      return @()
    }

    Set-Item -Path ("Function:\{0}:Stop-RaymanWorkspaceOwnedProcess" -f $scopePrefix) -Value {
      param([string]$WorkspaceRootPath, [object]$Record, [string]$Reason)
      return $null
    }
  }
}

function script:Set-CopySmokeFunctionDouble {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
  )

  foreach ($scopePrefix in @('global', 'script')) {
    Set-Item -Path ("Function:\{0}:{1}" -f $scopePrefix, $Name) -Value $ScriptBlock
  }
}

function script:Remove-CopySmokeFunctionDouble {
  param([Parameter(Mandatory = $true)][string]$Name)

  foreach ($scopePrefix in @('global', 'script')) {
    Remove-Item -Path ("Function:\{0}:{1}" -f $scopePrefix, $Name) -ErrorAction SilentlyContinue
  }
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

Describe 'copy_smoke archived vscode cleanup proof gating' {
  It 'skips archived new_pids without ownership proof' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_copy_smoke_vscode_ambiguous_' + [Guid]::NewGuid().ToString('N'))
    $warnMessages = New-Object 'System.Collections.Generic.List[string]'
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $auditPath = Join-Path $root 'vscode_windows.last.json'
      @{
        schema = 'rayman.vscode_windows.v1'
        workspace_root = (Join-Path $root 'copy-smoke')
        new_pids = @(202, 203, 303)
      } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $auditPath -Encoding UTF8

      Import-CopySmokeFunctions -Names @(
        'Resolve-CopySmokeVsCodeClientProcessId',
        'Resolve-CopySmokeArchivedVsCodeAuditCandidatePids',
        'Get-CopySmokeArchivedVsCodeAuditAnalysis',
        'Stop-CopySmokeArchivedVsCodeWindows'
      )
      Initialize-CopySmokeMockTargets

      Set-CopySmokeFunctionDouble -Name 'Warn' -ScriptBlock {
        param([string]$Message)
        $script:copySmokeWarnMessages.Add([string]$Message) | Out-Null
      }
      $script:copySmokeWarnMessages = $warnMessages

      $current = @(
        [pscustomobject]@{ pid = 202; parent_pid = 424242; process_name = 'Code'; start_utc = '2026-03-19T00:01:00Z'; main_window_title = ''; command_line = 'Code.exe --type=utility' }
        [pscustomobject]@{ pid = 203; parent_pid = 202; process_name = 'Code'; start_utc = '2026-03-19T00:01:02Z'; main_window_title = ''; command_line = 'Code.exe server.js --clientProcessId=202' }
        [pscustomobject]@{ pid = 303; parent_pid = 999; process_name = 'Code'; start_utc = '2026-03-19T00:01:03Z'; main_window_title = ''; command_line = 'Code.exe --type=utility' }
      )
      $stopCalls = New-Object 'System.Collections.Generic.List[object]'
      $script:copySmokeCurrentSnapshot = $current
      $script:copySmokeStopCalls = $stopCalls

      Set-CopySmokeFunctionDouble -Name 'Get-RaymanVsCodeProcessSnapshot' -ScriptBlock {
        param([string]$WorkspaceRootPath)
        return @($script:copySmokeCurrentSnapshot)
      }
      Set-CopySmokeFunctionDouble -Name 'Stop-RaymanWorkspaceOwnedProcess' -ScriptBlock {
        param([string]$WorkspaceRootPath, [object]$Record, [string]$Reason)
        $script:copySmokeStopCalls.Add([pscustomobject]@{
          workspace_root = $WorkspaceRootPath
          root_pid = [int]$Record.root_pid
          reason = $Reason
        }) | Out-Null
        return $null
      }

      $setupRuns = @([pscustomobject]@{ VsCodeAuditArchivePath = $auditPath })
      $analysis = Get-CopySmokeArchivedVsCodeAuditAnalysis -WorkspaceRoot $root -SetupRuns $setupRuns
      $cleanup = @(Stop-CopySmokeArchivedVsCodeWindows -WorkspaceRoot $root -SetupRuns $setupRuns)

      @($analysis.root_pids | Where-Object { $null -ne $_ }).Count | Should -Be 0
      (@($analysis.ambiguous_pids) -join ',') | Should -Be '202,203,303'
      @($cleanup).Count | Should -Be 0
      ($warnMessages -join "`n") | Should -Match 'skipped ambiguous vscode cleanup'
      [int]$stopCalls.Count | Should -Be 0
    } finally {
      foreach ($fn in @(
        'Resolve-CopySmokeVsCodeClientProcessId',
        'Resolve-CopySmokeArchivedVsCodeAuditCandidatePids',
        'Get-CopySmokeArchivedVsCodeAuditAnalysis',
        'Stop-CopySmokeArchivedVsCodeWindows',
        'Get-RaymanVsCodeProcessSnapshot',
        'Stop-RaymanWorkspaceOwnedProcess',
        'Warn'
      )) {
        Remove-CopySmokeFunctionDouble -Name $fn
      }
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'prefers archived owned_pids and keeps only the verified root pid' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_copy_smoke_vscode_owned_' + [Guid]::NewGuid().ToString('N'))
    $warnMessages = New-Object 'System.Collections.Generic.List[string]'
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $auditPath = Join-Path $root 'vscode_windows.last.json'
      @{
        schema = 'rayman.vscode_windows.v1'
        workspace_root = (Join-Path $root 'copy-smoke')
        new_pids = @(202, 203, 303)
        owned_pids = @(202, 203)
      } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $auditPath -Encoding UTF8

      Import-CopySmokeFunctions -Names @(
        'Resolve-CopySmokeVsCodeClientProcessId',
        'Resolve-CopySmokeArchivedVsCodeAuditCandidatePids',
        'Get-CopySmokeArchivedVsCodeAuditAnalysis',
        'Stop-CopySmokeArchivedVsCodeWindows'
      )
      Initialize-CopySmokeMockTargets

      Set-CopySmokeFunctionDouble -Name 'Warn' -ScriptBlock {
        param([string]$Message)
        $script:copySmokeWarnMessages.Add([string]$Message) | Out-Null
      }
      $script:copySmokeWarnMessages = $warnMessages

      $current = @(
        [pscustomobject]@{ pid = 202; parent_pid = 424242; process_name = 'Code'; start_utc = '2026-03-19T00:01:00Z'; main_window_title = ''; command_line = 'Code.exe --type=utility' }
        [pscustomobject]@{ pid = 203; parent_pid = 202; process_name = 'Code'; start_utc = '2026-03-19T00:01:02Z'; main_window_title = ''; command_line = 'Code.exe server.js --clientProcessId=202' }
        [pscustomobject]@{ pid = 303; parent_pid = 999; process_name = 'Code'; start_utc = '2026-03-19T00:01:03Z'; main_window_title = ''; command_line = 'Code.exe --type=utility' }
      )
      $stopCalls = New-Object 'System.Collections.Generic.List[object]'
      $script:copySmokeCurrentSnapshot = $current
      $script:copySmokeStopCalls = $stopCalls

      Set-CopySmokeFunctionDouble -Name 'Get-RaymanVsCodeProcessSnapshot' -ScriptBlock {
        param([string]$WorkspaceRootPath)
        return @($script:copySmokeCurrentSnapshot)
      }
      Set-CopySmokeFunctionDouble -Name 'Stop-RaymanWorkspaceOwnedProcess' -ScriptBlock {
        param([string]$WorkspaceRootPath, [object]$Record, [string]$Reason)
        $script:copySmokeStopCalls.Add([pscustomobject]@{
          workspace_root = $WorkspaceRootPath
          root_pid = [int]$Record.root_pid
          reason = $Reason
        }) | Out-Null
        return [pscustomobject]@{
          root_pid = [int]$Record.root_pid
          cleanup_reason = $Reason
          cleanup_result = 'cleaned'
          cleanup_pids = @([int]$Record.root_pid)
        }
      }

      $setupRuns = @([pscustomobject]@{ VsCodeAuditArchivePath = $auditPath })
      $analysis = Get-CopySmokeArchivedVsCodeAuditAnalysis -WorkspaceRoot $root -SetupRuns $setupRuns
      $cleanup = @(Stop-CopySmokeArchivedVsCodeWindows -WorkspaceRoot $root -SetupRuns $setupRuns)

      (@($analysis.root_pids) -join ',') | Should -Be '202'
      @($analysis.ambiguous_pids | Where-Object { $null -ne $_ }).Count | Should -Be 0
      (@($cleanup) -join ',') | Should -Be '202'
      [int]$warnMessages.Count | Should -Be 0
      [int]$stopCalls.Count | Should -Be 1
      [int]$stopCalls[0].root_pid | Should -Be 202
      [string]$stopCalls[0].reason | Should -Be 'copy-smoke-archived-audit'
    } finally {
      foreach ($fn in @(
        'Resolve-CopySmokeVsCodeClientProcessId',
        'Resolve-CopySmokeArchivedVsCodeAuditCandidatePids',
        'Get-CopySmokeArchivedVsCodeAuditAnalysis',
        'Stop-CopySmokeArchivedVsCodeWindows',
        'Get-RaymanVsCodeProcessSnapshot',
        'Stop-RaymanWorkspaceOwnedProcess',
        'Warn'
      )) {
        Remove-CopySmokeFunctionDouble -Name $fn
      }
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'copy_smoke managed write helpers' {
  It 'limits recovery detection to records from the current pass window' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_copy_smoke_managed_audit_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $auditPath = Join-Path $root 'managed_write.last.json'

      Import-CopySmokeFunctions -Names @('Test-CopySmokeManagedWriteAuditHasRecovery')

      @{
        schema = 'rayman.managed_write.audit.v1'
        updated_at = '2026-03-26T10:05:00.2200000+08:00'
        last_write = [ordered]@{
          path = (Join-Path $root '.github\copilot-instructions.md')
          mode = 'direct'
          updated_at = '2026-03-26T10:05:00.2200000+08:00'
        }
        recent_writes = @(
          [ordered]@{
            path = (Join-Path $root '.github\copilot-instructions.md')
            mode = 'retry_success'
            updated_at = '2026-03-26T10:05:00.1200000+08:00'
          },
          [ordered]@{
            path = (Join-Path $root '.github\copilot-instructions.md')
            mode = 'direct'
            updated_at = '2026-03-26T10:05:00.2200000+08:00'
          }
        )
      } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $auditPath -Encoding UTF8

      (Test-CopySmokeManagedWriteAuditHasRecovery `
          -AuditPath $auditPath `
          -Targets @('.github/copilot-instructions.md') `
          -RunStartedAt '2026-03-26T10:05:00.2000000+08:00' `
          -RunFinishedAt '2026-03-26T10:05:00.2400000+08:00') | Should -BeFalse

      @{
        schema = 'rayman.managed_write.audit.v1'
        updated_at = '2026-03-26T10:05:00.2300000+08:00'
        last_write = [ordered]@{
          path = (Join-Path $root '.github\copilot-instructions.md')
          mode = 'retry_success'
          updated_at = '2026-03-26T10:05:00.2300000+08:00'
        }
        recent_writes = @(
          [ordered]@{
            path = (Join-Path $root '.github\copilot-instructions.md')
            mode = 'retry_success'
            updated_at = '2026-03-26T10:05:00.2300000+08:00'
          }
        )
      } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $auditPath -Encoding UTF8

      (Test-CopySmokeManagedWriteAuditHasRecovery `
          -AuditPath $auditPath `
          -Targets @('.github/copilot-instructions.md') `
          -RunStartedAt '2026-03-26T10:05:00.2000000+08:00' `
          -RunFinishedAt '2026-03-26T10:05:00.2400000+08:00') | Should -BeTrue
    } finally {
      Remove-CopySmokeFunctionDouble -Name 'Test-CopySmokeManagedWriteAuditHasRecovery'
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'dirties mapped targets before the rerun contract' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_copy_smoke_dirty_targets_' + [Guid]::NewGuid().ToString('N'))
    try {
      foreach ($relative in @('.github\copilot-instructions.md', '.cursorrules', '.clinerules', '.github\workflows\rayman-project-fast-gate.yml')) {
        $path = Join-Path $root $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        Set-Content -LiteralPath $path -Encoding UTF8 -Value ('original:' + $relative)
      }

      Import-CopySmokeFunctions -Names @('Set-CopySmokeManagedWriteTargetsDirty')
      Set-CopySmokeManagedWriteTargetsDirty -WorkspaceRoot $root -Targets @(
        '.github/copilot-instructions.md'
        '.cursorrules'
        '.clinerules'
        '.github/workflows/rayman-project-fast-gate.yml'
      )

      foreach ($relative in @('.github\copilot-instructions.md', '.cursorrules', '.clinerules', '.github\workflows\rayman-project-fast-gate.yml')) {
        $raw = Get-Content -LiteralPath (Join-Path $root $relative) -Raw -Encoding UTF8
        $raw | Should -Match '(?im)^# copy-smoke stale'
        $raw | Should -Match ([regex]::Escape('original:' + $relative))
      }
    } finally {
      Remove-CopySmokeFunctionDouble -Name 'Set-CopySmokeManagedWriteTargetsDirty'
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
  [switch]$SkipReleaseGate
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
New-Item -ItemType Directory -Force -Path (Join-Path $WorkspaceRoot '.github\\workflows') | Out-Null
$solutionDir = Join-Path $WorkspaceRoot '.CopySmokeTest'
New-Item -ItemType Directory -Force -Path $solutionDir | Out-Null
if (-not (Test-Path -LiteralPath (Join-Path $solutionDir '.CopySmokeTest.requirements.md') -PathType Leaf)) {
  Set-Content -LiteralPath (Join-Path $solutionDir '.CopySmokeTest.requirements.md') -Encoding UTF8 -Value '# requirements'
}
if (-not (Test-Path -LiteralPath (Join-Path $WorkspaceRoot '.rayman.project.json') -PathType Leaf)) {
  Set-Content -LiteralPath (Join-Path $WorkspaceRoot '.rayman.project.json') -Encoding UTF8 -Value '{"solution":"CopySmokeTest"}'
}
foreach ($workflowName in @('rayman-project-fast-gate.yml', 'rayman-project-browser-gate.yml', 'rayman-project-full-gate.yml')) {
  $workflowPath = Join-Path $WorkspaceRoot ('.github\\workflows\\' + $workflowName)
  if (-not (Test-Path -LiteralPath $workflowPath -PathType Leaf)) {
    Set-Content -LiteralPath $workflowPath -Encoding UTF8 -Value ('name: ' + $workflowName)
  }
}
if (-not (Test-Path -LiteralPath (Join-Path $WorkspaceRoot '.gitignore') -PathType Leaf)) {
  Set-Content -LiteralPath (Join-Path $WorkspaceRoot '.gitignore') -Encoding UTF8 -Value @(
    '# RAYMAN:GENERATED:BEGIN',
    '/.Rayman/',
    '/.SolutionName',
    '/.cursorrules',
    '/.clinerules',
    '/.rayman.env.ps1',
    '/.rayman.project.json',
    '/.github/copilot-instructions.md',
    '/.github/workflows/rayman-project-fast-gate.yml',
    '/.github/workflows/rayman-project-browser-gate.yml',
    '/.github/workflows/rayman-project-full-gate.yml',
    '# RAYMAN:GENERATED:END'
  )
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
$managedWriteAudit = [ordered]@{
  schema = 'rayman.managed_write.audit.v1'
  updated_at = (Get-Date).ToString('o')
  last_write = [ordered]@{
    path = (Join-Path $WorkspaceRoot '.github\copilot-instructions.md')
    mode = $(if ($runIndex -ge 5) { 'in_place_fallback' } else { 'direct' })
    reason = 'ok'
    retry_count = $(if ($runIndex -ge 5) { 3 } else { 0 })
    updated_at = (Get-Date).ToString('o')
  }
  recent_writes = @(
    [ordered]@{
      path = (Join-Path $WorkspaceRoot '.github\copilot-instructions.md')
      mode = $(if ($runIndex -ge 5) { 'in_place_fallback' } else { 'direct' })
      reason = 'ok'
      retry_count = $(if ($runIndex -ge 5) { 3 } else { 0 })
      updated_at = (Get-Date).ToString('o')
    }
  )
}
$managedWriteAudit | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runtimeDir 'managed_write.last.json') -Encoding UTF8
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
      $expectedPassNames = if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        @('01-fresh-pass', '02-tracked-assets-block-pass', '03-explicit-allow-pass', '04-stable-rerun-pass', '05-mapped-write-rerun-pass')
      } else {
        @('01-fresh-pass', '02-tracked-assets-block-pass', '03-explicit-allow-pass', '04-stable-rerun-pass')
      }
      @($setupRuns).Count | Should -Be $expectedPassNames.Count
      (@($setupRuns | ForEach-Object { [string]$_.PassName }) -join ',') | Should -Be ($expectedPassNames -join ',')

      $invocations = @(Get-Content -LiteralPath (Join-Path $keptTempRoot '.Rayman\runtime\stub.setup.invocations.jsonl') -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
      @($invocations).Count | Should -Be $expectedPassNames.Count
      foreach ($invocation in $invocations) {
        [string]$invocation.alert_done | Should -Be '0'
        [string]$invocation.alert_tts_done | Should -Be '0'
      }

      foreach ($setupRun in @($setupRuns)) {
        (Test-Path -LiteralPath ([string]$setupRun.SetupLogArchivePath) -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath ([string]$setupRun.VsCodeAuditArchivePath) -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath ([string]$setupRun.ManagedWriteAuditArchivePath) -PathType Leaf) | Should -Be $true
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
    $gitignoreRaw | Should -Match '(?m)^/testResults\.xml\r?$'
  }
}
