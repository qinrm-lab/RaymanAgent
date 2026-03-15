BeforeAll {
  . (Join-Path $PSScriptRoot '..\..\..\common.ps1')
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

  throw 'pwsh/powershell not found for test wrapper'
}

function script:New-TestNativeWrapper {
  param(
    [string]$Root,
    [string]$Name,
    [string]$PowerShellBody
  )

  $psPath = Join-Path $Root ("{0}.impl.ps1" -f $Name)
  Set-Content -LiteralPath $psPath -Encoding UTF8 -Value $PowerShellBody

  $pwshPath = Get-TestPowerShellPath
  $psCommandPath = $psPath.Replace("'", "''")
  if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
    $wrapperPath = Join-Path $Root ("{0}.cmd" -f $Name)
    $wrapper = @"
@echo off
"$pwshPath" -NoProfile -ExecutionPolicy Bypass -Command "& '$psCommandPath' @args" -- %*
exit /b %ERRORLEVEL%
"@
    Set-Content -LiteralPath $wrapperPath -Encoding ASCII -Value $wrapper
    return $wrapperPath
  }

  $wrapperPath = Join-Path $Root $Name
  $wrapper = @"
#!/usr/bin/env bash
exec "$pwshPath" -NoProfile -Command "& '$psCommandPath' @args" -- "$@"
"@
  Set-Content -LiteralPath $wrapperPath -Encoding UTF8 -Value $wrapper
  & chmod +x $wrapperPath
  return $wrapperPath
}

Describe 'common workspace helpers' {
  It 'classifies a copied business workspace as external without Rayman source workflows' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_common_external_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\testing') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\testing\run_fast_contract.sh') -Value '#!/usr/bin/env bash' -Encoding UTF8

      Get-RaymanWorkspaceKind -WorkspaceRoot $root | Should -Be 'external'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'classifies the Rayman source workspace when source-only workflows are present' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_common_source_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\testing') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.github\workflows') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\testing\run_fast_contract.sh') -Value '#!/usr/bin/env bash' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.github\workflows\rayman-test-lanes.yml') -Value 'name: rayman-test-lanes' -Encoding UTF8

      Get-RaymanWorkspaceKind -WorkspaceRoot $root | Should -Be 'source'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'uses external tracked-noise rules to block the whole .Rayman tree in copied workspaces' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_common_rules_external_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\testing') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\testing\run_fast_contract.sh') -Value '#!/usr/bin/env bash' -Encoding UTF8

      $rules = Get-RaymanScmTrackedNoiseRules -WorkspaceRoot $root

      $rules.WorkspaceKind | Should -Be 'external'
      (@($rules.RaymanManaged | Where-Object { $_.Key -eq 'rayman_dir' })).Count | Should -Be 1
      (@($rules.RaymanManaged | Where-Object { $_.Key -eq 'skills_auto' })).Count | Should -Be 0
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'uses source tracked-noise rules to allow authored .Rayman files while blocking local generated files' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_common_rules_source_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\testing') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.github\workflows') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\testing\run_fast_contract.sh') -Value '#!/usr/bin/env bash' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.github\workflows\rayman-test-lanes.yml') -Value 'name: rayman-test-lanes' -Encoding UTF8

      $rules = Get-RaymanScmTrackedNoiseRules -WorkspaceRoot $root

      $rules.WorkspaceKind | Should -Be 'source'
      (@($rules.RaymanManaged | Where-Object { $_.Key -eq 'rayman_dir' })).Count | Should -Be 0
      (@($rules.RaymanManaged | Where-Object { $_.Key -eq 'skills_auto' })).Count | Should -Be 1
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'updates the tracked-assets flag in place without duplicating assignments' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_common_env_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $envFile = Join-Path $root '.rayman.env.ps1'
      Set-Content -LiteralPath $envFile -Encoding UTF8 -Value @'
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS)) {
    $env:RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS = '0'
}
'@

      $first = Set-RaymanWorkspaceEnvValue -WorkspaceRoot $root -Name 'RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS' -Value '1'
      $second = Set-RaymanWorkspaceEnvValue -WorkspaceRoot $root -Name 'RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS' -Value '1'
      $raw = Get-Content -LiteralPath $envFile -Raw -Encoding UTF8
      $matchCount = ([regex]::Matches($raw, '(?m)^\s*\$env:RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS\s*=\s*''1''\s*$')).Count

      $first.Ok | Should -BeTrue
      $first.Updated | Should -BeTrue
      $second.Ok | Should -BeTrue
      $second.Updated | Should -BeFalse
      $matchCount | Should -Be 1
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'attention helpers' {
  BeforeEach {
    $script:attentionEnvBackup = @{}
    foreach ($name in @(
      'RAYMAN_ALERTS_ENABLED',
      'RAYMAN_ALERT_MANUAL_ENABLED',
      'RAYMAN_ALERT_DONE_ENABLED',
      'RAYMAN_ALERT_TTS_ENABLED',
      'RAYMAN_ALERT_TTS_DONE_ENABLED',
      'RAYMAN_REQUEST_ATTENTION_SPEECH_ENABLED'
    )) {
      $script:attentionEnvBackup[$name] = [Environment]::GetEnvironmentVariable($name)
      Remove-Item ("Env:{0}" -f $name) -ErrorAction SilentlyContinue
    }
  }

  AfterEach {
    foreach ($entry in $script:attentionEnvBackup.GetEnumerator()) {
      [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value)
    }
  }

  It 'disables done alerts from workspace env while keeping manual alerts enabled' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_attention_done_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.rayman.env.ps1') -Encoding UTF8 -Value @'
$env:RAYMAN_ALERT_DONE_ENABLED = '0'
'@

      Get-RaymanAttentionAlertEnabled -WorkspaceRoot $root -Kind 'done' | Should -BeFalse
      Get-RaymanAttentionAlertEnabled -WorkspaceRoot $root -Kind 'manual' | Should -BeTrue
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'uses the global alerts switch as a master off toggle' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_attention_master_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.rayman.env.ps1') -Encoding UTF8 -Value @'
$env:RAYMAN_ALERTS_ENABLED = '0'
'@

      Get-RaymanAttentionAlertEnabled -WorkspaceRoot $root -Kind 'manual' | Should -BeFalse
      Get-RaymanAttentionAlertEnabled -WorkspaceRoot $root -Kind 'done' | Should -BeFalse
      Get-RaymanAttentionSpeechEnabled -WorkspaceRoot $root -Kind 'done' | Should -BeFalse
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'disables done TTS independently from generic speech' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_attention_tts_done_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.rayman.env.ps1') -Encoding UTF8 -Value @'
$env:RAYMAN_ALERT_TTS_DONE_ENABLED = '0'
'@

      Get-RaymanAttentionSpeechEnabled -WorkspaceRoot $root -Kind 'done' | Should -BeFalse
      Get-RaymanAttentionSpeechEnabled -WorkspaceRoot $root -Kind 'manual' | Should -BeTrue
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'honors legacy request-attention speech override when explicitly disabled' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_attention_legacy_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $env:RAYMAN_REQUEST_ATTENTION_SPEECH_ENABLED = '0'

      Get-RaymanAttentionSpeechEnabled -WorkspaceRoot $root -Kind 'manual' | Should -BeFalse
      Get-RaymanAttentionSpeechEnabled -WorkspaceRoot $root -Kind 'done' | Should -BeFalse
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'bootstrap helpers' {
  It 'defaults the VS Code bootstrap profile to conservative' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_bootstrap_profile_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      Get-RaymanVscodeBootstrapProfile -WorkspaceRoot $root | Should -Be 'conservative'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'git bootstrap helpers' {
  BeforeEach {
    $script:gitBootstrapEnvBackup = @{}
    foreach ($name in @(
      'CI',
      'RAYMAN_SETUP_GIT_INIT',
      'RAYMAN_SETUP_GITHUB_LOGIN',
      'RAYMAN_SETUP_GITHUB_LOGIN_STRICT',
      'RAYMAN_GITHUB_HOST',
      'RAYMAN_GITHUB_GIT_PROTOCOL'
    )) {
      $script:gitBootstrapEnvBackup[$name] = [Environment]::GetEnvironmentVariable($name)
      Remove-Item ("Env:{0}" -f $name) -ErrorAction SilentlyContinue
    }
  }

  AfterEach {
    foreach ($entry in $script:gitBootstrapEnvBackup.GetEnumerator()) {
      [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value)
    }
  }

  It 'reads setup git bootstrap defaults and disables interactive login under CI' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_git_bootstrap_options_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null

      $defaultOptions = Get-RaymanSetupGitBootstrapOptions -WorkspaceRoot $root
      $defaultOptions.git_init_enabled | Should -BeTrue
      $defaultOptions.github_login_enabled | Should -BeTrue
      $defaultOptions.github_login_strict | Should -BeFalse
      $defaultOptions.github_host | Should -Be 'github.com'
      $defaultOptions.github_git_protocol | Should -Be 'https'
      $defaultOptions.allow_interactive_github_login | Should -BeTrue

      $env:CI = '1'
      $ciOptions = Get-RaymanSetupGitBootstrapOptions -WorkspaceRoot $root
      $ciOptions.ci_detected | Should -BeTrue
      $ciOptions.allow_interactive_github_login | Should -BeFalse
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'initializes a missing git repo with main as default branch' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_git_init_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null

      $result = Initialize-RaymanGitRepository -WorkspaceRoot $root

      $result.git_available | Should -BeTrue
      $result.git_repo_detected | Should -BeTrue
      $result.git_initialized | Should -BeTrue
      Test-Path -LiteralPath (Join-Path $root '.git') | Should -BeTrue

      $branch = (& git -C $root symbolic-ref --short HEAD).Trim()
      $branch | Should -Be 'main'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'prefers gh over gh.exe when both candidates are available' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_gh_prefer_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $gh = New-TestNativeWrapper -Root $root -Name 'gh_pref' -PowerShellBody 'exit 0'
      $ghExe = New-TestNativeWrapper -Root $root -Name 'gh_exe_pref' -PowerShellBody 'exit 0'

      $resolution = Get-RaymanGitHubCliResolution -GhCommandSource $gh -GhExeCommandSource $ghExe

      $resolution.available | Should -BeTrue
      $resolution.cli_kind | Should -Be 'gh'
      $resolution.source | Should -Be $gh
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'falls back to gh.exe when gh is unavailable' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_gh_fallback_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $ghExe = New-TestNativeWrapper -Root $root -Name 'gh_exe_only' -PowerShellBody 'exit 0'

      $resolution = Get-RaymanGitHubCliResolution -GhExeCommandSource $ghExe

      $resolution.available | Should -BeTrue
      $resolution.cli_kind | Should -Be 'gh.exe'
      $resolution.source | Should -Be $ghExe
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'classifies unauthenticated GitHub status from CLI output' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_gh_status_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $cli = New-TestNativeWrapper -Root $root -Name 'gh_status' -PowerShellBody @'
Write-Host 'You are not logged into any GitHub hosts. To log in, run: gh auth login'
exit 1
'@

      $status = Get-RaymanGitHubAuthStatus -CliSource $cli -GitHubHost 'github.com'

      $status.status | Should -Be 'unauthenticated'
      $status.exit_code | Should -Be 1
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'skips GitHub login when interactive login is disabled' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_gh_skip_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $cli = New-TestNativeWrapper -Root $root -Name 'gh_skip' -PowerShellBody @'
$logPath = Join-Path $PSScriptRoot 'gh_skip.log'
Add-Content -LiteralPath $logPath -Encoding UTF8 -Value ($args -join ' ')
exit 0
'@

      $report = Invoke-RaymanGitBootstrap -WorkspaceRoot $root -GitInitEnabled $false -GitHubLoginEnabled $true -AllowInteractiveGitHubLogin $false -GitHubCliSource $cli -GitHubCliKind 'gh'

      $report.github_auth_status | Should -Be 'skipped'
      $report.skipped_reason | Should -Be 'github_login_noninteractive'
      $report.github_login_attempted | Should -BeFalse
      Test-Path -LiteralPath (Join-Path $root 'gh_skip.log') | Should -BeFalse
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'runs GitHub login and auth setup-git when auth status starts unauthenticated' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_gh_login_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $cli = New-TestNativeWrapper -Root $root -Name 'gh_login' -PowerShellBody @'
$statePath = Join-Path $PSScriptRoot 'auth.state'
$setupPath = Join-Path $PSScriptRoot 'setup.state'
$logPath = Join-Path $PSScriptRoot 'gh_login.log'
Add-Content -LiteralPath $logPath -Encoding UTF8 -Value ($args -join ' ')

if ($args.Length -ge 2 -and $args[0] -eq 'auth' -and $args[1] -eq 'status') {
  if (Test-Path -LiteralPath $statePath) {
    Write-Host 'Logged in to github.com'
    exit 0
  }
  Write-Host 'You are not logged into any GitHub hosts. To log in, run: gh auth login'
  exit 1
}

if ($args.Length -ge 2 -and $args[0] -eq 'auth' -and $args[1] -eq 'login') {
  Set-Content -LiteralPath $statePath -Encoding UTF8 -Value '1'
  exit 0
}

if ($args.Length -ge 2 -and $args[0] -eq 'auth' -and $args[1] -eq 'setup-git') {
  Set-Content -LiteralPath $setupPath -Encoding UTF8 -Value '1'
  exit 0
}

Write-Error ('unexpected args: ' + ($args -join ' '))
exit 2
'@
      $attentionMarker = Join-Path $root 'attention.marker'

      $report = Invoke-RaymanGitBootstrap `
        -WorkspaceRoot $root `
        -GitInitEnabled $false `
        -GitHubLoginEnabled $true `
        -AllowInteractiveGitHubLogin $true `
        -GitHubCliSource $cli `
        -GitHubCliKind 'gh' `
        -BeforeGitHubLogin { Set-Content -LiteralPath $attentionMarker -Encoding UTF8 -Value '1' }

      $report.github_auth_status | Should -Be 'authenticated'
      $report.github_login_attempted | Should -BeTrue
      $report.github_login_success | Should -BeTrue
      $report.github_setup_git_attempted | Should -BeTrue
      $report.github_setup_git_success | Should -BeTrue
      Test-Path -LiteralPath $attentionMarker | Should -BeTrue
      Test-Path -LiteralPath (Join-Path $root 'auth.state') | Should -BeTrue
      Test-Path -LiteralPath (Join-Path $root 'setup.state') | Should -BeTrue
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'required asset helpers' {
  It 'reports missing required assets with repair guidance' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_assets_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\utils') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\utils\request_attention.ps1') -Value 'param()' -Encoding UTF8

      $analysis = Get-RaymanRequiredAssetAnalysis -WorkspaceRoot $root -Label 'test-assets' -RequiredRelPaths @(
        '.Rayman/scripts/utils/request_attention.ps1',
        '.Rayman/scripts/utils/generate_context.ps1'
      )

      $analysis.ok | Should -BeFalse
      $analysis.missing_count | Should -Be 1
      @($analysis.missing_relative_paths) | Should -Contain '.Rayman/scripts/utils/generate_context.ps1'
      (Format-RaymanRequiredAssetSummary -Analysis $analysis) | Should -Match 'repair='
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'rules telemetry helpers' {
  It 'creates rules_runs.tsv with a stable header and appends records idempotently' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_rules_tsv_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null

      $path = Write-RaymanRulesTelemetryRecord -WorkspaceRoot $root -RunId 'run1' -Profile 'doctor' -Stage 'checklist' -Scope 'rules' -Status 'OK' -ExitCode 0 -DurationMs 12 -Command 'doctor'
      Write-RaymanRulesTelemetryRecord -WorkspaceRoot $root -RunId 'run2' -Profile 'doctor' -Stage 'final' -Scope 'rules' -Status 'FAIL' -ExitCode 1 -DurationMs 20 -Command 'doctor'

      $lines = @(Get-Content -LiteralPath $path -Encoding UTF8)
      $lines[0] | Should -Be "ts_iso`trun_id`tprofile`tstage`tscope`tstatus`texit_code`tduration_ms`tcommand"
      $lines.Count | Should -Be 3
      $lines[1] | Should -Match "`trun1`tdoctor`tchecklist`trules`tOK`t0`t12`tdoctor$"
      $lines[2] | Should -Match "`trun2`tdoctor`tfinal`trules`tFAIL`t1`t20`tdoctor$"
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
