Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  . (Join-Path $script:RepoRoot '.Rayman\common.ps1')
  . (Join-Path $script:RepoRoot '.Rayman\scripts\watch\embedded_watchers.lib.ps1')
}

function script:New-NetworkResumeTestRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_network_resume_' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime\agent_runs') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\logs') | Out-Null
  return $root
}

function script:Write-NetworkResumeDesktopSession {
  param(
    [string]$DesktopHome,
    [string]$WorkspaceRoot,
    [string]$SessionId = 'desktop-session-1',
    [datetime]$SessionTimestamp = (Get-Date).AddMinutes(-6),
    [string[]]$EventTexts = @('Reconnecting... 5/5', 'We''re currently experiencing high demand, which may cause temporary errors.'),
    [string]$Originator = 'Codex Desktop',
    [string]$Source = 'vscode'
  )

  $sessionDir = Join-Path $DesktopHome 'sessions\2026\03\31'
  New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
  $sessionPath = Join-Path $sessionDir ('rollout-' + $SessionId + '.jsonl')
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add((([ordered]@{
            timestamp = $SessionTimestamp.ToUniversalTime().ToString('o')
            type = 'session_meta'
            payload = [ordered]@{
              id = $SessionId
              timestamp = $SessionTimestamp.ToUniversalTime().ToString('o')
              cwd = $WorkspaceRoot
              originator = $Originator
              source = $Source
            }
          }) | ConvertTo-Json -Depth 6 -Compress)) | Out-Null

  $i = 0
  foreach ($text in @($EventTexts)) {
    $lineTime = $SessionTimestamp.AddSeconds($i + 1).ToUniversalTime().ToString('o')
    $lines.Add((([ordered]@{
              timestamp = $lineTime
              type = 'event_msg'
              payload = [ordered]@{
                type = 'status'
                message = [string]$text
              }
            }) | ConvertTo-Json -Depth 6 -Compress)) | Out-Null
    $i++
  }

  Set-Content -LiteralPath $sessionPath -Encoding UTF8 -Value @($lines.ToArray())
  (Get-Item -LiteralPath $sessionPath).LastWriteTime = Get-Date
  return $sessionPath
}

function script:Write-NetworkResumeDesktopRawLines {
  param(
    [string]$DesktopHome,
    [string]$WorkspaceRoot,
    [string[]]$RawLines = @(),
    [string]$SessionId = 'desktop-session-raw'
  )

  $sessionDir = Join-Path $DesktopHome 'sessions\2026\03\31'
  New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
  $sessionPath = Join-Path $sessionDir ('rollout-' + $SessionId + '.jsonl')
  $metaLine = (([ordered]@{
        timestamp = (Get-Date).AddMinutes(-6).ToUniversalTime().ToString('o')
        type = 'session_meta'
        payload = [ordered]@{
          id = $SessionId
          timestamp = (Get-Date).AddMinutes(-6).ToUniversalTime().ToString('o')
          cwd = $WorkspaceRoot
          originator = 'Codex Desktop'
          source = 'vscode'
        }
      }) | ConvertTo-Json -Depth 6 -Compress)
  Set-Content -LiteralPath $sessionPath -Encoding UTF8 -Value @($metaLine + @($RawLines))
  (Get-Item -LiteralPath $sessionPath).LastWriteTime = Get-Date
  return $sessionPath
}

function script:Write-NetworkResumeDesktopTuiLog {
  param(
    [string]$DesktopHome,
    [string]$SessionId,
    [string[]]$Lines = @()
  )

  $logDir = Join-Path $DesktopHome 'log'
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  $logPath = Join-Path $logDir 'codex-tui.log'
  Set-Content -LiteralPath $logPath -Encoding UTF8 -Value @($Lines | ForEach-Object {
        ("{0} WARN session_loop{{thread_id={1}}}: {2}" -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'), $SessionId, [string]$_)
      })
  return $logPath
}

function script:Write-NetworkResumeSummary {
  param(
    [string]$Root,
    [string]$RunId = 'run-1',
    [string]$Backend = 'codex',
    [bool]$Success = $false,
    [string]$ErrorMessage = 'request timed out',
    [string]$ExecutedCommand = 'dotnet build',
    [datetime]$GeneratedAt = (Get-Date).AddMinutes(-10),
    [string[]]$DetailLines = @()
  )

  $summaryPath = Join-Path $Root '.Rayman\runtime\agent_runs\last.json'
  $detailLog = Join-Path $Root '.Rayman\logs\agent.dispatch.test.log'
  if (@($DetailLines).Count -gt 0) {
    Set-Content -LiteralPath $detailLog -Encoding UTF8 -Value $DetailLines
  } else {
    Set-Content -LiteralPath $detailLog -Encoding UTF8 -Value @($ErrorMessage)
  }

  $payload = [ordered]@{
    schema = 'rayman.agent.dispatch.v1'
    generated_at = $GeneratedAt.ToString('o')
    run_id = $RunId
    selected_backend = $Backend
    success = $Success
    error_message = $ErrorMessage
    executed_command = $ExecutedCommand
    detail_log = $detailLog
    task = 'network resume test'
  }
  ($payload | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $summaryPath -Encoding UTF8
}

function script:Read-NetworkResumeStatus {
  param([object]$State)

  return (Get-Content -LiteralPath ([string]$State.StatusPath) -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function script:New-MockedIdleInfo {
  param([datetime]$IdleSince)

  [pscustomobject]@{
    available = $true
    idle_since = $IdleSince
    last_input_at = $IdleSince
    idle_seconds = [int][Math]::Max(0, [Math]::Floor(((Get-Date) - $IdleSince).TotalSeconds))
    error = ''
  }
}

Describe 'network resume watch state machine' {
  It 'does not arm when provider outage has not reached the threshold' {
    $root = New-NetworkResumeTestRoot
    try {
      Write-NetworkResumeSummary -Root $root -GeneratedAt (Get-Date).AddMinutes(-10) -ErrorMessage 'connection timed out'
      $state = New-RaymanNetworkResumeWatchState -WorkspaceRoot $root

      Mock Get-RaymanCurrentUserIdleInfo { return (New-MockedIdleInfo -IdleSince (Get-Date).AddHours(-1)) }
      Mock Test-RaymanNetworkResumeProviderReachable {
        [pscustomobject]@{
          reachable = $false
          dns_resolved = $false
          http_status_code = 0
          endpoint = 'https://api.openai.com/'
          error = 'request timed out'
          phase = 'http'
        }
      }
      Mock Start-RaymanCodexNativeResumeDetached {}

      $result = Invoke-RaymanNetworkResumeCycle -State $state
      $status = Read-NetworkResumeStatus -State $state

      $result.status | Should -Be 'provider_unreachable'
      [string]$status.armed_at | Should -Be ''
      [string]$status.suppressed_reason | Should -Be 'threshold_not_met'
      Assert-MockCalled Start-RaymanCodexNativeResumeDetached -Times 0 -Exactly
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'clears an armed outage when keyboard or mouse input breaks the overlapping idle window' {
    $root = New-NetworkResumeTestRoot
    try {
      Write-NetworkResumeSummary -Root $root -GeneratedAt (Get-Date).AddMinutes(-40) -ErrorMessage 'network unreachable'
      $state = New-RaymanNetworkResumeWatchState -WorkspaceRoot $root
      $state.LastCandidateRunId = 'run-1'
      $state.ProviderUnreachableSince = (Get-Date).AddMinutes(-40)
      $state.IdleSince = (Get-Date).AddMinutes(-35)
      $state.ArmedAt = (Get-Date).AddMinutes(-5)

      Mock Get-RaymanCurrentUserIdleInfo { return (New-MockedIdleInfo -IdleSince (Get-Date).AddMinutes(-5)) }
      Mock Test-RaymanNetworkResumeProviderReachable {
        [pscustomobject]@{
          reachable = $false
          dns_resolved = $false
          http_status_code = 0
          endpoint = 'https://api.openai.com/'
          error = 'network unreachable'
          phase = 'http'
        }
      }
      Mock Start-RaymanCodexNativeResumeDetached {}

      $result = Invoke-RaymanNetworkResumeCycle -State $state
      $status = Read-NetworkResumeStatus -State $state

      $result.status | Should -Be 'provider_unreachable'
      [string]$status.armed_at | Should -Be ''
      $status.idle.idle_seconds | Should -BeLessThan 600
      Assert-MockCalled Start-RaymanCodexNativeResumeDetached -Times 0 -Exactly
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'resumes a failed Codex task once when the provider becomes reachable again' {
    $root = New-NetworkResumeTestRoot
    try {
      Write-NetworkResumeSummary -Root $root -GeneratedAt (Get-Date).AddMinutes(-40) -ErrorMessage 'offline timeout'
      $state = New-RaymanNetworkResumeWatchState -WorkspaceRoot $root
      $state.LastCandidateRunId = 'run-1'
      $state.ProviderUnreachableSince = (Get-Date).AddMinutes(-40)
      $state.IdleSince = (Get-Date).AddMinutes(-35)
      $state.ArmedAt = (Get-Date).AddMinutes(-1)
      $state.LastProviderReachable = $false

      Mock Get-RaymanCurrentUserIdleInfo { return (New-MockedIdleInfo -IdleSince (Get-Date).AddMinutes(-35)) }
      Mock Test-RaymanNetworkResumeProviderReachable {
        [pscustomobject]@{
          reachable = $true
          dns_resolved = $true
          http_status_code = 401
          endpoint = 'https://api.openai.com/'
          error = ''
          phase = 'http'
        }
      }
      Mock Start-RaymanCodexNativeResumeDetached {
        [pscustomobject]@{
          success = $true
          started = $true
          completed = $false
          pid = 4242
          exit_code = 0
          command = 'codex exec resume --last'
          output = 'resumed'
          error = ''
          stdout = @('resumed')
          stderr = @()
        }
      }

      $first = Invoke-RaymanNetworkResumeCycle -State $state
      $second = Invoke-RaymanNetworkResumeCycle -State $state
      $status = Read-NetworkResumeStatus -State $state

      $first.status | Should -Be 'resumed'
      $second.status | Should -Be 'provider_reachable'
      $status.attempt_count | Should -Be 1
      Assert-MockCalled Start-RaymanCodexNativeResumeDetached -Times 1 -Exactly -ParameterFilter {
        [string]$WorkspaceRoot -eq $root -and
        [string]$Prompt -match '从中断处继续'
      }
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'classifies high demand style failures as throttle candidates' {
    $root = New-NetworkResumeTestRoot
    try {
      Write-NetworkResumeSummary -Root $root -GeneratedAt (Get-Date).AddMinutes(-6) -ErrorMessage 'high demand right now, please try again later'

      $candidate = Get-RaymanNetworkResumeCandidate -WorkspaceRoot $root

      [bool]$candidate.available | Should -Be $true
      [string]$candidate.trigger_kind | Should -Be 'throttle'
      [string]$candidate.failure_classification.classification | Should -Be 'transient_throttle_error'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'forms a throttle candidate from a matching Codex Desktop session without agent_runs last.json' {
    $root = New-NetworkResumeTestRoot
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_network_resume_desktop_' + [Guid]::NewGuid().ToString('N'))
    $desktopHomeBackup = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME')
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      Remove-Item -LiteralPath (Join-Path $root '.Rayman\runtime\agent_runs\last.json') -Force -ErrorAction SilentlyContinue
      Write-NetworkResumeDesktopSession -DesktopHome $desktopHome -WorkspaceRoot $root | Out-Null

      $candidate = Get-RaymanNetworkResumeCandidate -WorkspaceRoot $root

      [bool]$candidate.available | Should -Be $true
      [string]$candidate.candidate_source | Should -Be 'codex_desktop_session'
      [string]$candidate.trigger_kind | Should -Be 'throttle'
      [string]$candidate.resume_target_kind | Should -Be 'desktop_session'
      [string]$candidate.desktop_session_path | Should -Match 'rollout-'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHomeBackup)
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'ignores Codex Desktop sessions whose cwd does not match the current workspace' {
    $root = New-NetworkResumeTestRoot
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_network_resume_desktop_' + [Guid]::NewGuid().ToString('N'))
    $desktopHomeBackup = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME')
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      Remove-Item -LiteralPath (Join-Path $root '.Rayman\runtime\agent_runs\last.json') -Force -ErrorAction SilentlyContinue
      Write-NetworkResumeDesktopSession -DesktopHome $desktopHome -WorkspaceRoot (Join-Path $root 'OtherWorkspace') | Out-Null

      $candidate = Get-RaymanNetworkResumeCandidate -WorkspaceRoot $root

      [bool]$candidate.available | Should -Be $false
      [string]$candidate.reason | Should -Be 'last_run_missing'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHomeBackup)
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'accepts codex_vscode sessions when the workspace matches' {
    $root = New-NetworkResumeTestRoot
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_network_resume_desktop_' + [Guid]::NewGuid().ToString('N'))
    $desktopHomeBackup = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME')
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      Remove-Item -LiteralPath (Join-Path $root '.Rayman\runtime\agent_runs\last.json') -Force -ErrorAction SilentlyContinue
      Write-NetworkResumeDesktopSession -DesktopHome $desktopHome -WorkspaceRoot $root -Originator 'codex_vscode' -Source 'vscode' | Out-Null

      $candidate = Get-RaymanNetworkResumeCandidate -WorkspaceRoot $root

      [bool]$candidate.available | Should -Be $true
      [string]$candidate.candidate_source | Should -Be 'codex_desktop_session'
      [string]$candidate.resume_target_kind | Should -Be 'desktop_session'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHomeBackup)
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'does not resume throttled failures before the five-minute idle overlap elapses' {
    $root = New-NetworkResumeTestRoot
    try {
      Write-NetworkResumeSummary -Root $root -GeneratedAt (Get-Date).AddMinutes(-4) -ErrorMessage 'rate limited - try again later'
      $state = New-RaymanNetworkResumeWatchState -WorkspaceRoot $root

      Mock Get-RaymanCurrentUserIdleInfo { return (New-MockedIdleInfo -IdleSince (Get-Date).AddMinutes(-4)) }
      Mock Test-RaymanNetworkResumeProviderReachable {
        [pscustomobject]@{
          reachable = $true
          dns_resolved = $true
          http_status_code = 429
          endpoint = 'https://api.openai.com/'
          error = ''
          phase = 'http'
        }
      }
      Mock Start-RaymanCodexNativeResumeDetached {}

      $result = Invoke-RaymanNetworkResumeCycle -State $state
      $status = Read-NetworkResumeStatus -State $state

      $result.status | Should -Be 'throttle_wait'
      [string]$status.trigger_kind | Should -Be 'throttle'
      $status.throttle_wait_seconds | Should -Be 300
      Assert-MockCalled Start-RaymanCodexNativeResumeDetached -Times 0 -Exactly
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'resumes throttled failures after five minutes of continuous idle overlap' {
    $root = New-NetworkResumeTestRoot
    try {
      Write-NetworkResumeSummary -Root $root -GeneratedAt (Get-Date).AddMinutes(-6) -ErrorMessage '429 too many requests'
      $state = New-RaymanNetworkResumeWatchState -WorkspaceRoot $root
      $state.LastCandidateRunId = 'run-1'
      $state.ThrottledSince = (Get-Date).AddMinutes(-6)
      $state.IdleSince = (Get-Date).AddMinutes(-6)
      $state.TriggerKind = 'throttle'

      Mock Get-RaymanCurrentUserIdleInfo { return (New-MockedIdleInfo -IdleSince (Get-Date).AddMinutes(-6)) }
      Mock Test-RaymanNetworkResumeProviderReachable {
        [pscustomobject]@{
          reachable = $true
          dns_resolved = $true
          http_status_code = 429
          endpoint = 'https://api.openai.com/'
          error = ''
          phase = 'http'
        }
      }
      Mock Start-RaymanCodexNativeResumeDetached {
        [pscustomobject]@{
          success = $true
          started = $true
          completed = $false
          pid = 4343
          exit_code = 0
          command = 'codex exec resume --last'
          output = 'resumed'
          error = ''
          stdout = @()
          stderr = @()
        }
      }

      $result = Invoke-RaymanNetworkResumeCycle -State $state
      $status = Read-NetworkResumeStatus -State $state

      $result.status | Should -Be 'resumed'
      [string]$status.trigger_kind | Should -Be 'throttle'
      Assert-MockCalled Start-RaymanCodexNativeResumeDetached -Times 1 -Exactly
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'resumes throttled desktop sessions through the desktop resume helper instead of the dispatch helper' {
    $root = New-NetworkResumeTestRoot
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_network_resume_desktop_' + [Guid]::NewGuid().ToString('N'))
    $desktopHomeBackup = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME')
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      Remove-Item -LiteralPath (Join-Path $root '.Rayman\runtime\agent_runs\last.json') -Force -ErrorAction SilentlyContinue
      $sessionPath = Write-NetworkResumeDesktopSession -DesktopHome $desktopHome -WorkspaceRoot $root -SessionId 'desktop-session-1' -SessionTimestamp (Get-Date).AddMinutes(-6)
      $state = New-RaymanNetworkResumeWatchState -WorkspaceRoot $root
      $state.LastCandidateRunId = 'desktop-session-1'
      $state.ThrottledSince = (Get-Date).AddMinutes(-6)
      $state.IdleSince = (Get-Date).AddMinutes(-6)
      $state.TriggerKind = 'throttle'

      Mock Get-RaymanCurrentUserIdleInfo { return (New-MockedIdleInfo -IdleSince (Get-Date).AddMinutes(-6)) }
      Mock Test-RaymanNetworkResumeProviderReachable {
        [pscustomobject]@{
          reachable = $true
          dns_resolved = $true
          http_status_code = 429
          endpoint = 'https://api.openai.com/'
          error = ''
          phase = 'http'
        }
      }
      Mock Start-RaymanCodexDesktopResumeDetached {
        [pscustomobject]@{
          success = $true
          started = $true
          completed = $false
          pid = 4344
          exit_code = 0
          command = 'codex resume desktop-session-1'
          output = 'resumed'
          error = ''
          stdout = @()
          stderr = @()
          resume_target_kind = 'desktop_session'
        }
      } -ParameterFilter { [string]$WorkspaceRoot -eq $root -and [string]$SessionId -eq 'desktop-session-1' -and [string]$DesktopSessionPath -eq $sessionPath }
      Mock Start-RaymanCodexNativeResumeDetached {}

      $result = Invoke-RaymanNetworkResumeCycle -State $state
      $status = Read-NetworkResumeStatus -State $state

      $result.status | Should -Be 'resumed'
      [string]$status.candidate_source | Should -Be 'codex_desktop_session'
      [string]$status.resume_target_kind | Should -Be 'desktop_session'
      Assert-MockCalled Start-RaymanCodexDesktopResumeDetached -Times 1 -Exactly
      Assert-MockCalled Start-RaymanCodexNativeResumeDetached -Times 0 -Exactly
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHomeBackup)
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'never auto-resumes when the latest failure is quota or auth related' {
    $root = New-NetworkResumeTestRoot
    try {
      Write-NetworkResumeSummary -Root $root -GeneratedAt (Get-Date).AddMinutes(-40) -ErrorMessage 'insufficient_quota'
      $state = New-RaymanNetworkResumeWatchState -WorkspaceRoot $root

      Mock Get-RaymanCurrentUserIdleInfo { return (New-MockedIdleInfo -IdleSince (Get-Date).AddHours(-1)) }
      Mock Test-RaymanNetworkResumeProviderReachable {}
      Mock Start-RaymanCodexNativeResumeDetached {}

      $result = Invoke-RaymanNetworkResumeCycle -State $state
      $status = Read-NetworkResumeStatus -State $state

      $result.status | Should -Be 'non_network_error'
      [string]$status.suppressed_reason | Should -Be 'non_network_error'
      Assert-MockCalled Test-RaymanNetworkResumeProviderReachable -Times 0 -Exactly
      Assert-MockCalled Start-RaymanCodexNativeResumeDetached -Times 0 -Exactly
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'never auto-resumes desktop sessions when the latest failure is quota or auth related' {
    $root = New-NetworkResumeTestRoot
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_network_resume_desktop_' + [Guid]::NewGuid().ToString('N'))
    $desktopHomeBackup = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME')
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      Remove-Item -LiteralPath (Join-Path $root '.Rayman\runtime\agent_runs\last.json') -Force -ErrorAction SilentlyContinue
      Write-NetworkResumeDesktopSession -DesktopHome $desktopHome -WorkspaceRoot $root -EventTexts @('insufficient_quota') | Out-Null
      $state = New-RaymanNetworkResumeWatchState -WorkspaceRoot $root

      Mock Get-RaymanCurrentUserIdleInfo { return (New-MockedIdleInfo -IdleSince (Get-Date).AddHours(-1)) }
      Mock Test-RaymanNetworkResumeProviderReachable {}
      Mock Start-RaymanCodexDesktopResumeDetached {}

      $result = Invoke-RaymanNetworkResumeCycle -State $state
      $status = Read-NetworkResumeStatus -State $state

      $result.status | Should -Be 'non_network_error'
      [string]$status.suppressed_reason | Should -Be 'non_network_error'
      Assert-MockCalled Start-RaymanCodexDesktopResumeDetached -Times 0 -Exactly
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHomeBackup)
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'ignores generic transcript JSON lines that only mention auth-like words outside structured status messages' {
    $root = New-NetworkResumeTestRoot
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_network_resume_desktop_' + [Guid]::NewGuid().ToString('N'))
    $desktopHomeBackup = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME')
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      Remove-Item -LiteralPath (Join-Path $root '.Rayman\runtime\agent_runs\last.json') -Force -ErrorAction SilentlyContinue
      Write-NetworkResumeDesktopRawLines -DesktopHome $desktopHome -WorkspaceRoot $root -RawLines @(
        '{"timestamp":"2026-03-31T00:00:02Z","type":"response_item","payload":{"type":"function_call_output","output":"apply patch auth token rotation helper"}}'
      ) | Out-Null

      $candidate = Get-RaymanNetworkResumeDesktopSessionCandidate -WorkspaceRoot $root

      [bool]$candidate.available | Should -Be $false
      [string]$candidate.reason | Should -Be 'desktop_session_no_match'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHomeBackup)
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'records resume_unavailable without replaying the previous executed command' {
    $root = New-NetworkResumeTestRoot
    try {
      Write-NetworkResumeSummary -Root $root -GeneratedAt (Get-Date).AddMinutes(-40) -ErrorMessage 'connection reset by peer' -ExecutedCommand 'dotnet build'
      $state = New-RaymanNetworkResumeWatchState -WorkspaceRoot $root
      $state.LastCandidateRunId = 'run-1'
      $state.ProviderUnreachableSince = (Get-Date).AddMinutes(-40)
      $state.IdleSince = (Get-Date).AddMinutes(-35)
      $state.ArmedAt = (Get-Date).AddMinutes(-1)
      $state.LastProviderReachable = $false

      Mock Get-RaymanCurrentUserIdleInfo { return (New-MockedIdleInfo -IdleSince (Get-Date).AddMinutes(-35)) }
      Mock Test-RaymanNetworkResumeProviderReachable {
        [pscustomobject]@{
          reachable = $true
          dns_resolved = $true
          http_status_code = 401
          endpoint = 'https://api.openai.com/'
          error = ''
          phase = 'http'
        }
      }
      Mock Invoke-RaymanAttentionAlert { return $null }
      Mock Start-RaymanCodexNativeResumeDetached {
        [pscustomobject]@{
          success = $false
          started = $true
          completed = $true
          pid = 5001
          exit_code = 1
          command = 'codex exec resume --last'
          output = 'no resumable session'
          error = 'no resumable session'
          stdout = @()
          stderr = @('no resumable session')
        }
      }

      $result = Invoke-RaymanNetworkResumeCycle -State $state
      $status = Read-NetworkResumeStatus -State $state

      $result.status | Should -Be 'resume_unavailable'
      [string]$status.error | Should -Match 'no resumable session'
      Assert-MockCalled Invoke-RaymanAttentionAlert -Times 1 -Exactly
      Assert-MockCalled Start-RaymanCodexNativeResumeDetached -Times 1 -Exactly -ParameterFilter {
        [string]$WorkspaceRoot -eq $root -and
        [string]$Prompt -match '从中断处继续'
      }
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'tracks unsupported providers without trying to execute a resume command' {
    $root = New-NetworkResumeTestRoot
    try {
      Write-NetworkResumeSummary -Root $root -Backend 'copilot' -GeneratedAt (Get-Date).AddMinutes(-40) -ErrorMessage 'connection timed out'
      $state = New-RaymanNetworkResumeWatchState -WorkspaceRoot $root

      Mock Get-RaymanCurrentUserIdleInfo { return (New-MockedIdleInfo -IdleSince (Get-Date).AddHours(-1)) }
      Mock Test-RaymanNetworkResumeProviderReachable {
        [pscustomobject]@{
          reachable = $false
          dns_resolved = $false
          http_status_code = 0
          endpoint = 'https://api.github.com/'
          error = 'connection timed out'
          phase = 'http'
        }
      }
      Mock Start-RaymanCodexNativeResumeDetached {}

      $result = Invoke-RaymanNetworkResumeCycle -State $state
      $status = Read-NetworkResumeStatus -State $state

      $result.status | Should -Be 'unsupported_native_resume'
      [string]$status.suppressed_reason | Should -Be 'unsupported_native_resume'
      Assert-MockCalled Start-RaymanCodexNativeResumeDetached -Times 0 -Exactly
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'falls back to the network path when a throttled task now sees the provider as unreachable' {
    $root = New-NetworkResumeTestRoot
    try {
      Write-NetworkResumeSummary -Root $root -GeneratedAt (Get-Date).AddMinutes(-6) -ErrorMessage 'high demand right now'
      $state = New-RaymanNetworkResumeWatchState -WorkspaceRoot $root

      Mock Get-RaymanCurrentUserIdleInfo { return (New-MockedIdleInfo -IdleSince (Get-Date).AddMinutes(-6)) }
      Mock Test-RaymanNetworkResumeProviderReachable {
        [pscustomobject]@{
          reachable = $false
          dns_resolved = $false
          http_status_code = 0
          endpoint = 'https://api.openai.com/'
          error = 'offline'
          phase = 'http'
        }
      }
      Mock Start-RaymanCodexNativeResumeDetached {}

      $result = Invoke-RaymanNetworkResumeCycle -State $state
      $status = Read-NetworkResumeStatus -State $state

      $result.status | Should -Be 'provider_unreachable'
      [string]$status.trigger_kind | Should -Be 'network'
      Assert-MockCalled Start-RaymanCodexNativeResumeDetached -Times 0 -Exactly
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'prefers the newest available failure candidate when desktop and dispatch sources both exist' {
    $root = New-NetworkResumeTestRoot
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_network_resume_desktop_' + [Guid]::NewGuid().ToString('N'))
    $desktopHomeBackup = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME')
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      Write-NetworkResumeSummary -Root $root -GeneratedAt (Get-Date).AddMinutes(-20) -ErrorMessage 'connection reset by peer'
      Write-NetworkResumeDesktopSession -DesktopHome $desktopHome -WorkspaceRoot $root -SessionId 'desktop-latest' -SessionTimestamp (Get-Date).AddMinutes(-6) | Out-Null

      $candidate = Get-RaymanNetworkResumeCandidate -WorkspaceRoot $root

      [bool]$candidate.available | Should -Be $true
      [string]$candidate.candidate_source | Should -Be 'codex_desktop_session'
      [string]$candidate.run_id | Should -Be 'desktop-latest'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHomeBackup)
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'allows desktop resume --last only when the session path is still the newest matching workspace session' {
    $root = New-NetworkResumeTestRoot
    $desktopHome = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_network_resume_desktop_' + [Guid]::NewGuid().ToString('N'))
    $desktopHomeBackup = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME')
    try {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHome)
      $newest = Write-NetworkResumeDesktopSession -DesktopHome $desktopHome -WorkspaceRoot $root -SessionId '' -SessionTimestamp (Get-Date).AddMinutes(-6)
      Start-Sleep -Milliseconds 50
      Write-NetworkResumeDesktopSession -DesktopHome $desktopHome -WorkspaceRoot (Join-Path $root 'other') -SessionId 'other-session' -SessionTimestamp (Get-Date).AddMinutes(-3) | Out-Null

      Mock Get-RaymanCodexCommandInfo {
        [pscustomobject]@{
          available = $true
          path = 'codex.cmd'
        }
      }
      Mock Resolve-RaymanCodexInteractiveInvocation {
        [pscustomobject]@{
          available = $true
          file_path = 'codex.cmd'
          argument_list = @('resume', '--last', 'resume prompt')
          error = ''
        }
      }
      Mock Start-Process {
        $proc = New-Object psobject -Property @{
          Id = 7001
          ExitCode = 0
          HasExited = $false
        }
        $proc | Add-Member -MemberType ScriptMethod -Name Refresh -Value { return }
        return $proc
      }

      $result = Start-RaymanCodexDesktopResumeDetached -WorkspaceRoot $root -SessionId '' -Prompt 'resume prompt' -DesktopSessionPath $newest

      [bool]$result.success | Should -Be $true
      [string]$result.resume_target_kind | Should -Be 'desktop_last'
      Assert-MockCalled Start-Process -Times 1 -Exactly
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME', $desktopHomeBackup)
      Remove-Item -LiteralPath $desktopHome -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'launches the native resume through a detached process helper instead of the blocking command wrapper' {
    $root = New-NetworkResumeTestRoot
    try {
      Mock Assert-RaymanCodexManagedLogin {
        [pscustomobject]@{
          context = [pscustomobject]@{
            workspace_root = $root
            account_alias = 'alpha'
            effective_profile = ''
            codex_home = (Join-Path $root '.codex-home')
          }
        }
      }
      Mock Ensure-RaymanCodexCliCompatible {
        [pscustomobject]@{
          compatible = $true
          output = ''
          reason = 'ok'
        }
      }
      Mock Get-RaymanCodexCommandInfo {
        [pscustomobject]@{
          available = $true
          path = 'codex.cmd'
        }
      }
      Mock Resolve-RaymanCodexInteractiveInvocation {
        [pscustomobject]@{
          available = $true
          file_path = 'codex.cmd'
          argument_list = @('exec', 'resume', '--last', 'resume prompt')
          error = ''
        }
      }
      Mock Start-Process {
        $proc = New-Object psobject -Property @{
          Id = 6001
          ExitCode = 0
          HasExited = $false
        }
        $proc | Add-Member -MemberType ScriptMethod -Name Refresh -Value { return }
        return $proc
      }
      Mock Invoke-RaymanCodexCommand {}

      $result = Start-RaymanCodexNativeResumeDetached -WorkspaceRoot $root -Prompt 'resume prompt'

      [bool]$result.success | Should -Be $true
      [int]$result.pid | Should -Be 6001
      Assert-MockCalled Start-Process -Times 1 -Exactly
      Assert-MockCalled Invoke-RaymanCodexCommand -Times 0 -Exactly
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
