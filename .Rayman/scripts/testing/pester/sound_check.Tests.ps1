BeforeAll {
  $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  . (Join-Path $script:RepoRoot '.Rayman\common.ps1')
  . (Join-Path $script:RepoRoot '.Rayman\scripts\utils\sound_check.ps1') -NoMain
}

Describe 'sound check helpers' {
  It 'uses the real manual and done reminder entrypoints' {
    $raw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\utils\sound_check.ps1') -Raw -Encoding UTF8

    $raw | Should -Match 'request_attention\.ps1'
    $raw | Should -Match 'codex_notify\.ps1'
    $raw | Should -Match 'agent-turn-complete'
  }

  It 'writes a passing report when both confirmations say heard' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_sound_check_pass_' + [Guid]::NewGuid().ToString('N'))
    $soundPath = Join-Path $root 'notify.wav'
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime') | Out-Null
      Set-Content -LiteralPath $soundPath -Encoding UTF8 -Value 'wave'

      Mock Test-RaymanWindowsPlatform { return $true }
      Mock Get-RaymanAttentionSoundPath { return $soundPath }
      Mock Get-RaymanAttentionSoundEnabled { return $true }
      Mock Get-RaymanSoundCheckWindowsDevices { return @([pscustomobject]@{ name = 'Speaker'; status = 'OK'; manufacturer = 'Rayman'; pnp_device_id = 'abc' }) }
      Mock Invoke-RaymanSoundCheckManualEntrypoint {}
      Mock Invoke-RaymanSoundCheckDoneEntrypoint {}
      $script:answers = @('1', '1')
      function global:Read-Host {
        param([string]$Prompt)
        $next = $script:answers[0]
        if ($script:answers.Count -gt 1) {
          $script:answers = @($script:answers[1..($script:answers.Count - 1)])
        } else {
          $script:answers = @()
        }
        return $next
      }

      $report = Invoke-RaymanSoundCheck -WorkspaceRoot $root -Mode both

      [string]$report.result | Should -Be 'passed'
      @($report.steps).Count | Should -Be 2
      [string]$report.steps[0].kind | Should -Be 'manual'
      [string]$report.steps[1].kind | Should -Be 'done'
      [string]$report.steps[0].user_confirmed | Should -Be 'heard'
      [string]$report.steps[1].user_confirmed | Should -Be 'heard'
      Test-Path -LiteralPath (Join-Path $root '.Rayman\runtime\sound_check.last.json') | Should -BeTrue
      Test-Path -LiteralPath (Join-Path $root '.Rayman\runtime\sound_check.last.md') | Should -BeTrue
      Assert-MockCalled Invoke-RaymanSoundCheckManualEntrypoint -Times 1 -Exactly
      Assert-MockCalled Invoke-RaymanSoundCheckDoneEntrypoint -Times 1 -Exactly
    } finally {
      Remove-Item function:\global:Read-Host -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'fails immediately for disabled manual sound without pretending to play' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_sound_check_disabled_' + [Guid]::NewGuid().ToString('N'))
    $soundPath = Join-Path $root 'notify.wav'
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime') | Out-Null
      Set-Content -LiteralPath $soundPath -Encoding UTF8 -Value 'wave'

      Mock Test-RaymanWindowsPlatform { return $true }
      Mock Get-RaymanAttentionSoundPath { return $soundPath }
      Mock Get-RaymanAttentionSoundEnabled {
        param([string]$WorkspaceRoot, [string]$Kind)
        return ($Kind -eq 'done')
      }
      Mock Invoke-RaymanSoundCheckManualEntrypoint {}
      Mock Invoke-RaymanSoundCheckDoneEntrypoint {}
      function global:Read-Host {
        param([string]$Prompt)
        return '1'
      }

      $report = Invoke-RaymanSoundCheck -WorkspaceRoot $root -Mode both

      [string]$report.result | Should -Be 'failed'
      [string]$report.steps[0].result | Should -Be 'failed'
      [string]$report.steps[0].error | Should -Be 'manual_sound_disabled'
      [bool]$report.steps[0].playback_invoked | Should -BeFalse
      Assert-MockCalled Invoke-RaymanSoundCheckManualEntrypoint -Times 0 -Exactly
      Assert-MockCalled Invoke-RaymanSoundCheckDoneEntrypoint -Times 1 -Exactly
    } finally {
      Remove-Item function:\global:Read-Host -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'returns cancelled when the user quits during confirmation' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_sound_check_cancel_' + [Guid]::NewGuid().ToString('N'))
    $soundPath = Join-Path $root 'notify.wav'
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime') | Out-Null
      Set-Content -LiteralPath $soundPath -Encoding UTF8 -Value 'wave'

      Mock Test-RaymanWindowsPlatform { return $true }
      Mock Get-RaymanAttentionSoundPath { return $soundPath }
      Mock Get-RaymanAttentionSoundEnabled { return $true }
      Mock Invoke-RaymanSoundCheckManualEntrypoint {}
      Mock Invoke-RaymanSoundCheckDoneEntrypoint {}
      function global:Read-Host {
        param([string]$Prompt)
        return 'q'
      }

      $report = Invoke-RaymanSoundCheck -WorkspaceRoot $root -Mode both

      [string]$report.result | Should -Be 'cancelled'
      [string]$report.steps[0].result | Should -Be 'cancelled'
      Assert-MockCalled Invoke-RaymanSoundCheckManualEntrypoint -Times 1 -Exactly
      Assert-MockCalled Invoke-RaymanSoundCheckDoneEntrypoint -Times 0 -Exactly
    } finally {
      Remove-Item function:\global:Read-Host -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'returns unsupported on non-Windows hosts' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_sound_check_unsupported_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime') | Out-Null
      Mock Test-RaymanWindowsPlatform { return $false }

      $report = Invoke-RaymanSoundCheck -WorkspaceRoot $root -Mode both

      [string]$report.result | Should -Be 'unsupported'
      @($report.steps).Count | Should -Be 0
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
