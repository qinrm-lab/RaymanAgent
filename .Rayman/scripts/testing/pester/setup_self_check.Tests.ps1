function script:Get-TestPowerShellPath {
  foreach ($candidate in @('pwsh', 'pwsh.exe', 'powershell', 'powershell.exe')) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
      return [string]$cmd.Source
    }
  }

  throw 'pwsh/powershell not found'
}

function script:Get-SetupTopLevelBlock {
  param(
    [string]$RawText,
    [string]$StartPattern
  )

  $match = [regex]::Match($RawText, ("(?ms)^{0}.*?^}}" -f $StartPattern))
  if (-not $match.Success) {
    throw ("setup block not found: {0}" -f $StartPattern)
  }
  return [string]$match.Value
}

function script:Convert-ToPsSingleQuotedLiteral {
  param([string]$Value)

  if ($null -eq $Value) { return "''" }
  return ("'" + $Value.Replace("'", "''") + "'")
}

Describe 'setup self-check child exit propagation' {
  It 'fails fast on child copy-self-check failure without printing the success banner' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_setup_self_check_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman') | Out-Null

      Set-Content -LiteralPath (Join-Path $root '.Rayman\rayman.ps1') -Encoding UTF8 -Value @'
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Args
)
exit 17
'@

      $setupRaw = Get-Content -LiteralPath (Join-Path $repoRoot '.Rayman\setup.ps1') -Raw -Encoding UTF8
      $getLastExitCodeCompat = Get-SetupTopLevelBlock -RawText $setupRaw -StartPattern 'function Get-LastExitCodeCompat'
      $resetLastExitCodeCompat = Get-SetupTopLevelBlock -RawText $setupRaw -StartPattern 'function Reset-LastExitCodeCompat'
      $invokeChildBlock = Get-SetupTopLevelBlock -RawText $setupRaw -StartPattern 'function Invoke-SetupChildPowerShellScript'
      $selfCheckBlock = Get-SetupTopLevelBlock -RawText $setupRaw -StartPattern 'if \(\$SelfCheck -or \$StrictCheck\)'

      $workspaceLiteral = Convert-ToPsSingleQuotedLiteral -Value $root
      $harnessPath = Join-Path $root 'setup.self_check.harness.ps1'
      Set-Content -LiteralPath $harnessPath -Encoding UTF8 -Value @(
        '$ErrorActionPreference = ''Stop'''
        '$raymanCommonImported = $false'
        ''
        $getLastExitCodeCompat
        ''
        $resetLastExitCodeCompat
        ''
        $invokeChildBlock
        ''
        'function Exit-RaymanSetup {'
        '  param('
        '    [int]$ExitCode,'
        '    [string]$Reason = ''setup'''
        '  )'
        '  exit $ExitCode'
        '}'
        ''
        ('$WorkspaceRoot = {0}' -f $workspaceLiteral)
        '$SelfCheck = $true'
        '$StrictCheck = $false'
        ''
        $selfCheckBlock
        ''
        'exit 0'
      )

      $psPath = Get-TestPowerShellPath
      $output = & $psPath -NoProfile -ExecutionPolicy Bypass -File $harnessPath 2>&1 | Out-String

      $LASTEXITCODE | Should -Be 17
      $output | Should -Match '拷贝初始化自检未通过'
      $output | Should -Not -Match '拷贝初始化自检通过'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'setup playwright install output classification' {
  It 'treats npm error output as fatal even when the process exits zero' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
    $setupRaw = Get-Content -LiteralPath (Join-Path $repoRoot '.Rayman\setup.ps1') -Raw -Encoding UTF8
    $functionBlock = Get-SetupTopLevelBlock -RawText $setupRaw -StartPattern 'function Test-PlaywrightAutoInstallOutputHasFatalError'
    . ([scriptblock]::Create($functionBlock))

    (Test-PlaywrightAutoInstallOutputHasFatalError -OutputLines @(
        'npm error config prefix cannot be changed from project config: E:\demo\.npmrc.'
      )) | Should -BeTrue
    (Test-PlaywrightAutoInstallOutputHasFatalError -OutputLines @(
        '[pwa] WARN: sudo non-interactive is unavailable; skip ''--with-deps'' and rely on existing system deps/cache.'
      )) | Should -BeFalse
  }
}

Describe 'setup playwright auto install scope routing' {
  It 'does not resolve host install when scope is wsl on Windows' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
    $setupRaw = Get-Content -LiteralPath (Join-Path $repoRoot '.Rayman\setup.ps1') -Raw -Encoding UTF8
    $functionBlock = Get-SetupTopLevelBlock -RawText $setupRaw -StartPattern 'function Invoke-PlaywrightAutoInstall'
    . ([scriptblock]::Create($functionBlock))

    $script:playwrightReadyLibImported = $true
    function script:Test-PlaywrightAutoInstallOutputHasFatalError {
      param([string[]]$OutputLines = @())
      return $false
    }
    function script:Test-HostIsWindowsCompat { return $true }
    function script:Resolve-RaymanPlaywrightHostInstallInvocation { return $null }

    Mock Test-HostIsWindowsCompat { return $true }
    Mock Get-Command { return $null }
    Mock Resolve-RaymanPlaywrightHostInstallInvocation {
      throw 'host helper should not run for scope=wsl'
    }

    Invoke-PlaywrightAutoInstall -WorkspaceRoot $repoRoot -Scope 'wsl' -Browser 'chromium' -TimeoutSeconds 30

    Should -Invoke Resolve-RaymanPlaywrightHostInstallInvocation -Times 0 -Exactly
  }

  It 'resolves host install only when scope is host on Windows' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
    $setupRaw = Get-Content -LiteralPath (Join-Path $repoRoot '.Rayman\setup.ps1') -Raw -Encoding UTF8
    $functionBlock = Get-SetupTopLevelBlock -RawText $setupRaw -StartPattern 'function Invoke-PlaywrightAutoInstall'
    . ([scriptblock]::Create($functionBlock))

    $script:playwrightReadyLibImported = $true
    function script:Test-PlaywrightAutoInstallOutputHasFatalError {
      param([string[]]$OutputLines = @())
      return $false
    }
    function script:Test-HostIsWindowsCompat { return $true }
    function script:Resolve-RaymanPlaywrightHostInstallInvocation { return $null }

    Mock Test-HostIsWindowsCompat { return $true }
    Mock Resolve-RaymanPlaywrightHostInstallInvocation {
      return [pscustomobject]@{
        success = $false
        install_source = 'rayman_managed'
        tool_root = 'C:\Temp\Rayman\tools\playwright-host'
        package_spec = 'playwright@latest'
        detail = 'stub failure'
        install_output = @()
      }
    }

    Invoke-PlaywrightAutoInstall -WorkspaceRoot $repoRoot -Scope 'host' -Browser 'chromium' -TimeoutSeconds 30

    Should -Invoke Resolve-RaymanPlaywrightHostInstallInvocation -Times 1 -Exactly
  }
}

Describe 'setup scm ignore failure escalation' {
  It 'throws when scm ignore injection reports write_failed' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
    $setupRaw = Get-Content -LiteralPath (Join-Path $repoRoot '.Rayman\setup.ps1') -Raw -Encoding UTF8
    $functionBlock = Get-SetupTopLevelBlock -RawText $setupRaw -StartPattern 'function Assert-SetupScmIgnoreResult'
    . ([scriptblock]::Create($functionBlock))

    {
      Assert-SetupScmIgnoreResult -Result ([pscustomobject]@{
          reason = 'write_failed'
          target_path = '.gitignore'
          error_message = 'The process cannot access the file.'
        })
    } | Should -Throw 'managed-write-failed:*'

    { Assert-SetupScmIgnoreResult -Result ([pscustomobject]@{ reason = 'disabled_by_env' }) } | Should -Not -Throw
  }
}
