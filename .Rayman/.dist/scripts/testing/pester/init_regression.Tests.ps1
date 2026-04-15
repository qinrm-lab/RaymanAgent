function script:Test-IsWindows {
  return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows
  )
}

function script:Get-TestBashInvocation {
  if (Test-IsWindows) {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $wsl -and -not [string]::IsNullOrWhiteSpace([string]$wsl.Source)) {
      return [pscustomobject]@{
        Mode = 'wsl'
        Path = [string]$wsl.Source
      }
    }
  }

  $bash = Get-Command bash.exe, bash -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -ne $bash -and -not [string]::IsNullOrWhiteSpace([string]$bash.Source)) {
    return [pscustomobject]@{
      Mode = 'native'
      Path = [string]$bash.Source
    }
  }

  return $null
}

function script:Convert-ToWslPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $drive = $fullPath.Substring(0, 1).ToLowerInvariant()
  $rest = $fullPath.Substring(2).Replace('\', '/')
  return "/mnt/$drive$rest"
}

function script:Invoke-TestBashScript {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Invocation,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$ScriptPath
  )

  $output = ''
  if ([string]$Invocation.Mode -eq 'wsl') {
    $workspaceRootWsl = Convert-ToWslPath -Path $WorkspaceRoot
    $command = "cd '$workspaceRootWsl' && bash '$ScriptPath'"
    $output = & $Invocation.Path -e bash -lc $command 2>&1 | Out-String
  } else {
    Push-Location $WorkspaceRoot
    try {
      $output = & $Invocation.Path $ScriptPath 2>&1 | Out-String
    } finally {
      Pop-Location
    }
  }

  return [pscustomobject]@{
    exit_code = $LASTEXITCODE
    output = [string]$output
  }
}

function script:Write-Utf8NoBomFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Content
  )

  $encoding = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function script:Get-TestRepoRoot {
  $candidate = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  if (Test-Path -LiteralPath (Join-Path $candidate '.Rayman\init.sh')) {
    return $candidate
  }

  $fallback = (Resolve-Path (Join-Path $candidate '..')).Path
  if (Test-Path -LiteralPath (Join-Path $fallback '.Rayman\init.sh')) {
    return $fallback
  }

  throw 'workspace root not found for init regression tests'
}

Describe 'Rayman init shell regressions' {
  It 'ships .vs in backup defaults for source and dist templates' {
    $repoRoot = Get-TestRepoRoot

    foreach ($configPath in @(
        (Join-Path $repoRoot '.Rayman\config.json'),
        (Join-Path $repoRoot '.Rayman\.dist\config.json')
      )) {
      $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      @($config.backup.excludeDirNames) | Should -Contain '.vs'
    }

    foreach ($scriptPath in @(
        (Join-Path $repoRoot '.Rayman\scripts\backup\backup_solution.ps1'),
        (Join-Path $repoRoot '.Rayman\.dist\scripts\backup\backup_solution.ps1')
      )) {
      $raw = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8
      $raw | Should -Match 'DefaultExcludeDirNames'
      $raw | Should -Match "'\.vs'"
    }
  }

  It 'normalizes CRLF managed shell helpers before invoking workspace_state_guard' {
    $bashInvocation = Get-TestBashInvocation
    if ($null -eq $bashInvocation) {
      Set-ItResult -Skipped -Because 'bash/WSL not available'
      return
    }

    $repoRoot = Get-TestRepoRoot
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_init_regression_' + [Guid]::NewGuid().ToString('N'))
    try {
      foreach ($dir in @(
          '.Rayman',
          '.Rayman\runtime',
          '.Rayman\scripts\repair',
          '.Rayman\scripts\utils',
          '.Rayman\scripts\requirements',
          '.Rayman\scripts\pwa'
        )) {
        New-Item -ItemType Directory -Force -Path (Join-Path $root $dir) | Out-Null
      }

      Copy-Item -LiteralPath (Join-Path $repoRoot '.Rayman\init.sh') -Destination (Join-Path $root '.Rayman\init.sh')

      Write-Utf8NoBomFile -Path (Join-Path $root '.Rayman\scripts\repair\ensure_complete_rayman.sh') -Content @'
#!/usr/bin/env bash
set -euo pipefail
printf 'repair\n' >> '.Rayman/runtime/init-order.log'
'@

      Write-Utf8NoBomFile -Path (Join-Path $root '.Rayman\scripts\utils\workspace_state_guard.sh') -Content "#!/usr/bin/env bash`r`nset -euo pipefail`r`nprintf 'guard\n' >> '.Rayman/runtime/init-order.log'`r`nprintf 'guard-ok\n' > '.Rayman/runtime/guard-ran.txt'`r`n"

      Write-Utf8NoBomFile -Path (Join-Path $root '.Rayman\scripts\requirements\ensure_requirements.sh') -Content @'
#!/usr/bin/env bash
set -euo pipefail
printf 'requirements\n' >> '.Rayman/runtime/init-order.log'
'@

      Write-Utf8NoBomFile -Path (Join-Path $root '.Rayman\scripts\requirements\process_prompts.sh') -Content @'
#!/usr/bin/env bash
set -euo pipefail
printf 'prompts\n' >> '.Rayman/runtime/init-order.log'
'@

      Write-Utf8NoBomFile -Path (Join-Path $root '.Rayman\scripts\pwa\ensure_playwright_wsl.sh') -Content @'
#!/usr/bin/env bash
set -euo pipefail
printf 'playwright\n' >> '.Rayman/runtime/init-order.log'
'@

      $firstRun = Invoke-TestBashScript -Invocation $bashInvocation -WorkspaceRoot $root -ScriptPath './.Rayman/init.sh'
      $secondRun = Invoke-TestBashScript -Invocation $bashInvocation -WorkspaceRoot $root -ScriptPath './.Rayman/init.sh'

      $firstRun.exit_code | Should -Be 0
      $firstRun.output | Should -Match 'normalized 1 shell script to LF'
      $secondRun.exit_code | Should -Be 0
      $secondRun.output | Should -Match 'shell scripts already LF'

      $orderLog = Get-Content -LiteralPath (Join-Path $root '.Rayman\runtime\init-order.log') -Raw -Encoding UTF8
      $orderLog | Should -Match '^repair'
      $orderLog | Should -Match 'guard'
      $orderLog | Should -Match 'requirements'
      $orderLog | Should -Match 'prompts'
      $orderLog | Should -Match 'playwright'

      (Get-Content -LiteralPath (Join-Path $root '.Rayman\runtime\guard-ran.txt') -Raw -Encoding UTF8) | Should -Be "guard-ok`n"
      (Get-Content -LiteralPath (Join-Path $root '.Rayman\scripts\utils\workspace_state_guard.sh') -Raw -Encoding UTF8) | Should -Not -Match "`r"
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
