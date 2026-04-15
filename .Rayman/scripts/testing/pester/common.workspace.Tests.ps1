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

function script:Import-FunctionFromFile {
  param(
    [string]$Path,
    [string]$FunctionName
  )

  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  if ($null -ne $errors -and $errors.Count -gt 0) {
    throw ("failed to parse {0}: {1}" -f $Path, ($errors | ForEach-Object { $_.Message } | Select-Object -First 1))
  }

  $functionAst = $ast.Find({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      [string]::Equals($node.Name, $FunctionName, [System.StringComparison]::Ordinal)
    }, $true)
  if ($null -eq $functionAst) {
    throw ("function not found: {0}" -f $FunctionName)
  }

  Set-Item -Path ("Function:\script:{0}" -f $FunctionName) -Value ([scriptblock]::Create($functionAst.Body.Extent.Text))
}

function script:Set-CommonFunctionDouble {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
  )

  foreach ($scopePrefix in @('global', 'script')) {
    Set-Item -Path ("Function:\{0}:{1}" -f $scopePrefix, $Name) -Value $ScriptBlock
  }
}

function script:Remove-CommonFunctionDouble {
  param([Parameter(Mandatory = $true)][string]$Name)

  foreach ($scopePrefix in @('global', 'script')) {
    Remove-Item -Path ("Function:\{0}:{1}" -f $scopePrefix, $Name) -ErrorAction SilentlyContinue
  }
}

function script:Reset-ManagedWriteHarnessFunctions {
  $commonPath = Join-Path $PSScriptRoot '..\..\..\common.ps1'
  foreach ($functionName in @(
      'Get-RaymanManagedWriteAuditPath',
      'Write-RaymanManagedWriteAudit',
      'Test-RaymanMappedSectionWriteError',
      'Invoke-RaymanUtf8NoBomDirectWrite',
      'Invoke-RaymanUtf8NoBomInPlaceWrite',
      'Set-RaymanManagedUtf8File'
    )) {
    Import-FunctionFromFile -Path $commonPath -FunctionName $functionName
  }
}

function script:Start-TestMappedFileHoldProcess {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$SleepMs = 350
  )

  $token = [Guid]::NewGuid().ToString('N')
  $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("rayman_mapped_hold_{0}.ps1" -f $token)
  $readyPath = Join-Path ([System.IO.Path]::GetTempPath()) ("rayman_mapped_hold_{0}.ready" -f $token)
  @'
param(
  [Parameter(Mandatory = $true)][string]$TargetPath,
  [Parameter(Mandatory = $true)][string]$ReadyPath,
  [int]$SleepMs = 350
)

$mmf = $null
$view = $null
try {
  $mmf = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateFromFile($TargetPath, [System.IO.FileMode]::Open, ('rayman_hold_' + [Guid]::NewGuid().ToString('N')), 0)
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

Describe 'managed write helpers' {
  BeforeEach {
    Reset-ManagedWriteHarnessFunctions
  }

  It 'returns unchanged without rewriting identical content' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_managed_write_unchanged_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $path = Join-Path $root 'sample.txt'
      [System.IO.File]::WriteAllText($path, 'same', (New-Object System.Text.UTF8Encoding($false)))

      $result = Set-RaymanManagedUtf8File -Path $path -Content 'same' -AuditRoot $root -Label 'unchanged-test'

      $result.ok | Should -BeTrue
      $result.changed | Should -BeFalse
      $result.mode | Should -Be 'unchanged'
      ((Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim()) | Should -Be 'same'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'writes new content directly and records audit output' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_managed_write_direct_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $path = Join-Path $root 'sample.txt'

      $result = Set-RaymanManagedUtf8File -Path $path -Content 'direct-write' -AuditRoot $root -Label 'direct-test'
      $auditPath = Join-Path $root '.Rayman\runtime\managed_write.last.json'
      $audit = Get-Content -LiteralPath $auditPath -Raw -Encoding UTF8 | ConvertFrom-Json

      $result.ok | Should -BeTrue
      $result.changed | Should -BeTrue
      $result.mode | Should -Be 'direct'
      ((Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim()) | Should -Be 'direct-write'
      [string]$audit.last_write.mode | Should -Be 'direct'
      [string]$audit.last_write.label | Should -Be 'direct-test'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'retries mapped-section writes until a direct retry succeeds' {
    if (-not (Test-RaymanWindowsPlatform)) {
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_managed_write_retry_' + [Guid]::NewGuid().ToString('N'))
    $mappedHold = $null
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $path = Join-Path $root 'sample.txt'
      [System.IO.File]::WriteAllText($path, 'abcd', (New-Object System.Text.UTF8Encoding($false)))
      $mappedHold = Start-TestMappedFileHoldProcess -Path $path -SleepMs 275

      $result = Set-RaymanManagedUtf8File -Path $path -Content 'wxyz' -AuditRoot $root -Label 'retry-test' -RetryDelaysMs @(100, 250, 500)
      $auditPath = Join-Path $root '.Rayman\runtime\managed_write.last.json'
      $audit = Get-Content -LiteralPath $auditPath -Raw -Encoding UTF8 | ConvertFrom-Json

      $result.ok | Should -BeTrue
      $result.mode | Should -Be 'retry_success'
      $result.retry_count | Should -BeGreaterThan 0
      ((Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim()) | Should -Be 'wxyz'
      [string]$audit.last_write.mode | Should -Be 'retry_success'
    } finally {
      Stop-TestMappedFileHoldProcess -Handle $mappedHold
      Remove-CommonFunctionDouble -Name 'Invoke-RaymanUtf8NoBomDirectWrite'
      Reset-ManagedWriteHarnessFunctions
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'continues into mapped-write recovery when reading the existing file is blocked' {
    if (-not (Test-RaymanWindowsPlatform)) {
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_managed_write_read_retry_' + [Guid]::NewGuid().ToString('N'))
    $script:readFailureTriggered = $false
    $script:directWriteAttempt = 0
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $path = Join-Path $root 'sample.txt'
      [System.IO.File]::WriteAllText($path, 'abcd', (New-Object System.Text.UTF8Encoding($false)))

      Mock Get-Content {
        if (-not $script:readFailureTriggered) {
          $script:readFailureTriggered = $true
          throw 'The process cannot access the file because it is being used by another process.'
        }
        Microsoft.PowerShell.Management\Get-Content @PSBoundParameters
      } -ParameterFilter { [string]$LiteralPath -eq $path }

      $result = Set-RaymanManagedUtf8File -Path $path -Content 'wxyz' -AuditRoot $root -Label 'read-retry-test' -RetryDelaysMs @(0, 0, 0) -DirectWriteAction {
        param([string]$TargetPath, [string]$TargetContent)
        $script:directWriteAttempt++
        if ($script:directWriteAttempt -eq 1) {
          throw 'The requested operation cannot be performed on a file with a user-mapped section open.'
        }
        [System.IO.File]::WriteAllText($TargetPath, $TargetContent, (New-Object System.Text.UTF8Encoding($false)))
      }
      $auditPath = Join-Path $root '.Rayman\runtime\managed_write.last.json'
      $audit = Get-Content -LiteralPath $auditPath -Raw -Encoding UTF8 | ConvertFrom-Json

      $result.ok | Should -BeTrue
      $result.mode | Should -Be 'retry_success'
      $result.retry_count | Should -BeGreaterThan 0
      ((Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim()) | Should -Be 'wxyz'
      [string]$audit.last_write.mode | Should -Be 'retry_success'
    } finally {
      Reset-ManagedWriteHarnessFunctions
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'uses in-place fallback when mapped writes keep failing but byte length matches' {
    if (-not (Test-RaymanWindowsPlatform)) {
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_managed_write_inplace_' + [Guid]::NewGuid().ToString('N'))
    $script:fallbackInvoked = $false
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $path = Join-Path $root 'sample.txt'
      [System.IO.File]::WriteAllText($path, 'abcd', (New-Object System.Text.UTF8Encoding($false)))

      $result = Set-RaymanManagedUtf8File -Path $path -Content 'wxyz' -AuditRoot $root -Label 'fallback-test' -RetryDelaysMs @(0, 0, 0) -DirectWriteAction {
        param([string]$TargetPath, [string]$TargetContent)
        throw 'The requested operation cannot be performed on a file with a user-mapped section open.'
      } -InPlaceWriteAction {
        param([string]$TargetPath, [string]$TargetContent)
        $script:fallbackInvoked = $true
        [System.IO.File]::WriteAllText($TargetPath, $TargetContent, (New-Object System.Text.UTF8Encoding($false)))
      }
      $auditPath = Join-Path $root '.Rayman\runtime\managed_write.last.json'
      $audit = Get-Content -LiteralPath $auditPath -Raw -Encoding UTF8 | ConvertFrom-Json

      $result.ok | Should -BeTrue
      $result.mode | Should -Be 'in_place_fallback'
      $result.reason | Should -Be 'mapped_section_same_length'
      $script:fallbackInvoked | Should -BeTrue
      ((Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim()) | Should -Be 'wxyz'
      [string]$audit.last_write.mode | Should -Be 'in_place_fallback'
    } finally {
      Reset-ManagedWriteHarnessFunctions
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'fails explicitly when mapped writes stay blocked and byte length differs' {
    if (-not (Test-RaymanWindowsPlatform)) {
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_managed_write_mismatch_' + [Guid]::NewGuid().ToString('N'))
    $script:mismatchFallbackInvoked = $false
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $path = Join-Path $root 'sample.txt'
      [System.IO.File]::WriteAllText($path, 'abcd', (New-Object System.Text.UTF8Encoding($false)))

      $result = Set-RaymanManagedUtf8File -Path $path -Content 'wxyz1234' -AuditRoot $root -Label 'mismatch-test' -RetryDelaysMs @(0, 0, 0) -DirectWriteAction {
        param([string]$TargetPath, [string]$TargetContent)
        throw 'The requested operation cannot be performed on a file with a user-mapped section open.'
      } -InPlaceWriteAction {
        param([string]$TargetPath, [string]$TargetContent)
        $script:mismatchFallbackInvoked = $true
      }

      $result.ok | Should -BeFalse
      $result.mode | Should -Be 'failed'
      $result.reason | Should -Be 'mapped_section_length_mismatch'
      $script:mismatchFallbackInvoked | Should -Not -BeTrue
    } finally {
      Reset-ManagedWriteHarnessFunctions
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
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
      (@($rules.RaymanManaged | Where-Object { $_.Key -eq 'workspace_project' })).Count | Should -Be 1
      (@($rules.RaymanManaged | Where-Object { $_.Key -eq 'all_dev_ps1' })).Count | Should -Be 1
      (@($rules.RaymanManaged | Where-Object { $_.Key -eq 'all_dev_bat' })).Count | Should -Be 1
      (@($rules.RaymanManaged | Where-Object { $_.Key -eq 'vscode_launch' })).Count | Should -Be 1
      (@($rules.RaymanManaged | Where-Object { Test-RaymanScmTrackedNoiseRuleMatch -NormalizedPath '.gitignore' -Rule $_ })).Count | Should -Be 0
      (@($rules.RaymanManaged | Where-Object { Test-RaymanScmTrackedNoiseRuleMatch -NormalizedPath 'RaymanAgent.slnx' -Rule $_ })).Count | Should -Be 0
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'treats .vscode/launch.json as generated tracked-noise in external and source workspaces' {
    $externalRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_common_external_launch_' + [Guid]::NewGuid().ToString('N'))
    $sourceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_common_source_launch_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $externalRoot '.Rayman\scripts\testing') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $externalRoot '.vscode') | Out-Null
      Set-Content -LiteralPath (Join-Path $externalRoot '.Rayman\scripts\testing\run_fast_contract.sh') -Value '#!/usr/bin/env bash' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $externalRoot '.vscode\launch.json') -Value '{}' -Encoding UTF8

      New-Item -ItemType Directory -Force -Path (Join-Path $sourceRoot '.Rayman\scripts\testing') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $sourceRoot '.github\workflows') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $sourceRoot '.vscode') | Out-Null
      Set-Content -LiteralPath (Join-Path $sourceRoot '.Rayman\scripts\testing\run_fast_contract.sh') -Value '#!/usr/bin/env bash' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $sourceRoot '.github\workflows\rayman-test-lanes.yml') -Value 'name: rayman-test-lanes' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $sourceRoot '.vscode\launch.json') -Value '{}' -Encoding UTF8

      $externalRules = Get-RaymanScmTrackedNoiseRules -WorkspaceRoot $externalRoot
      $sourceRules = Get-RaymanScmTrackedNoiseRules -WorkspaceRoot $sourceRoot

      (@($externalRules.RaymanManaged | Where-Object { Test-RaymanScmTrackedNoiseRuleMatch -NormalizedPath '.vscode/launch.json' -Rule $_ })).Count | Should -BeGreaterThan 0
      (@($sourceRules.RaymanManaged | Where-Object { Test-RaymanScmTrackedNoiseRuleMatch -NormalizedPath '.vscode/launch.json' -Rule $_ })).Count | Should -BeGreaterThan 0
    } finally {
      Remove-Item -LiteralPath $externalRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'keeps external requirements and agentic docs trackable while matching generated workflow and config assets' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_common_external_allowlist_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\testing') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\testing\run_fast_contract.sh') -Value '#!/usr/bin/env bash' -Encoding UTF8

      $solutionDir = Join-Path $root '.SampleExternal'
      $agenticDir = Join-Path $solutionDir 'agentic'
      New-Item -ItemType Directory -Force -Path $agenticDir | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.github\workflows') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.github\agents') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.github\skills\demo') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.github\prompts') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.github\instructions') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.codex') | Out-Null

      Set-Content -LiteralPath (Join-Path $solutionDir '.SampleExternal.requirements.md') -Value '# requirements' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $agenticDir 'plan.md') -Value '# plan' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $agenticDir 'contract.json') -Value '{"ok":true}' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.rayman.project.json') -Value '{"solution":"SampleExternal"}' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.codex\config.toml') -Value 'model = "gpt-5"' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.github\model-policy.md') -Value '# model policy' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.github\workflows\rayman-project-fast-gate.yml') -Value 'name: fast' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.github\agents\rayman_worker.agent.md') -Value '# worker' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.github\skills\demo\SKILL.md') -Value '# skill' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.github\prompts\rayman.prompt.md') -Value '# prompt' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.github\instructions\workspace.instructions.md') -Value '# instructions' -Encoding UTF8

      $rules = Get-RaymanScmTrackedNoiseRules -WorkspaceRoot $root

      $rules.WorkspaceKind | Should -Be 'external'
      foreach ($blockedPath in @(
          '.rayman.project.json',
          '.codex/config.toml',
          '.github/model-policy.md',
          '.github/workflows/rayman-project-fast-gate.yml',
          '.github/agents/rayman_worker.agent.md',
          '.github/skills/demo/SKILL.md',
          '.github/prompts/rayman.prompt.md',
          '.github/instructions/workspace.instructions.md'
        )) {
        $matches = @($rules.RaymanManaged | Where-Object { Test-RaymanScmTrackedNoiseRuleMatch -NormalizedPath $blockedPath -Rule $_ })
        $matches.Count | Should -BeGreaterThan 0
      }

      foreach ($allowedPath in @(
          '.SampleExternal/.SampleExternal.requirements.md',
          '.SampleExternal/agentic/plan.md',
          '.SampleExternal/agentic/contract.json'
        )) {
        $matches = @($rules.RaymanManaged | Where-Object { Test-RaymanScmTrackedNoiseRuleMatch -NormalizedPath $allowedPath -Rule $_ })
        $matches.Count | Should -Be 0
      }
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'matches source temp and package artifacts while keeping authored Rayman files clear' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_common_source_artifacts_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\testing') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.github\workflows') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\temp') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\tmp') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\release') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman_full_for_copy') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root 'Rayman_full_bundle') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.tmp_sandbox_verify_case') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.Rayman\scripts\testing\run_fast_contract.sh') -Value '#!/usr/bin/env bash' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.github\workflows\rayman-test-lanes.yml') -Value 'name: rayman-test-lanes' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.Rayman\temp\cache.txt') -Value 'temp' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.Rayman\tmp\scratch.txt') -Value 'tmp' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.Rayman\release\bundle.zip') -Value 'zip' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.Rayman\release\bundle.tar.gz') -Value 'tar' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.Rayman_full_for_copy\manifest.txt') -Value 'copy' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root 'Rayman_full_bundle\bundle.txt') -Value 'bundle' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $root '.tmp_sandbox_verify_case\trace.txt') -Value 'trace' -Encoding UTF8

      $rules = Get-RaymanScmTrackedNoiseRules -WorkspaceRoot $root

      $rules.WorkspaceKind | Should -Be 'source'
      foreach ($blockedPath in @(
          '.Rayman/temp/cache.txt',
          '.Rayman/tmp/scratch.txt',
          '.Rayman/release/bundle.zip',
          '.Rayman/release/bundle.tar.gz',
          '.Rayman_full_for_copy/manifest.txt',
          'Rayman_full_bundle/bundle.txt',
          '.tmp_sandbox_verify_case/trace.txt'
        )) {
        $matches = @($rules.RaymanManaged | Where-Object { Test-RaymanScmTrackedNoiseRuleMatch -NormalizedPath $blockedPath -Rule $_ })
        $matches.Count | Should -BeGreaterThan 0
      }

      $authoredMatches = @($rules.RaymanManaged | Where-Object {
          Test-RaymanScmTrackedNoiseRuleMatch -NormalizedPath '.Rayman/scripts/testing/run_fast_contract.sh' -Rule $_
        })
      $authoredMatches.Count | Should -Be 0
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

  It 'adds the interaction mode setting into a managed block when the workspace env file is missing or outdated' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_interaction_env_' + [Guid]::NewGuid().ToString('N'))
    $previousInteractionMode = [Environment]::GetEnvironmentVariable('RAYMAN_INTERACTION_MODE')
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      [Environment]::SetEnvironmentVariable('RAYMAN_INTERACTION_MODE', $null)

      $first = Set-RaymanWorkspaceEnvValue -WorkspaceRoot $root -Name 'RAYMAN_INTERACTION_MODE' -Value 'general' -AddIfMissing -ManagedBlockId 'RAYMAN:INTERACTION:MODE' -ManagedBy 'Rayman interaction-mode'
      $second = Set-RaymanWorkspaceEnvValue -WorkspaceRoot $root -Name 'RAYMAN_INTERACTION_MODE' -Value 'simple' -AddIfMissing -ManagedBlockId 'RAYMAN:INTERACTION:MODE' -ManagedBy 'Rayman interaction-mode'
      $raw = Get-Content -LiteralPath (Join-Path $root '.rayman.env.ps1') -Raw -Encoding UTF8

      $first.Ok | Should -BeTrue
      $first.Added | Should -BeTrue
      $second.Ok | Should -BeTrue
      $second.Updated | Should -BeTrue
      ([regex]::Matches($raw, '# RAYMAN:INTERACTION:MODE:BEGIN')).Count | Should -Be 1
      ([regex]::Matches($raw, '(?m)^\s*\$env:RAYMAN_INTERACTION_MODE\s*=\s*''simple''\s*$')).Count | Should -Be 1
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_INTERACTION_MODE', $previousInteractionMode)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'defaults invalid interaction mode values back to detailed' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_interaction_default_' + [Guid]::NewGuid().ToString('N'))
    $previousInteractionMode = [Environment]::GetEnvironmentVariable('RAYMAN_INTERACTION_MODE')
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      [Environment]::SetEnvironmentVariable('RAYMAN_INTERACTION_MODE', $null)
      Set-Content -LiteralPath (Join-Path $root '.rayman.env.ps1') -Encoding UTF8 -Value @'
$env:RAYMAN_INTERACTION_MODE = 'totally-invalid'
'@

      Get-RaymanInteractionMode -WorkspaceRoot $root | Should -Be 'detailed'
      Get-RaymanInteractionModeLabel -Mode 'totally-invalid' | Should -Be '详细'
      Get-RaymanInteractionModeDescription -Mode 'detailed' | Should -Match '明确验收标准'
      Get-RaymanInteractionModePromptPreamble -WorkspaceRoot $root | Should -Match 'acceptance criteria'
      Get-RaymanInteractionModePromptPreamble -WorkspaceRoot $root | Should -Match 'outside Codex Plan Mode'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_INTERACTION_MODE', $previousInteractionMode)
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'ignores empty process env strings and keeps the workspace string value authoritative' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_workspace_string_env_' + [Guid]::NewGuid().ToString('N'))
    $previousInteractionMode = [Environment]::GetEnvironmentVariable('RAYMAN_INTERACTION_MODE', 'Process')
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.rayman.env.ps1') -Encoding UTF8 -Value @'
$env:RAYMAN_INTERACTION_MODE = 'general'
'@
      [Environment]::SetEnvironmentVariable('RAYMAN_INTERACTION_MODE', '', 'Process')

      $entry = Get-RaymanWorkspaceEnvStringEntry -WorkspaceRoot $root -Name 'RAYMAN_INTERACTION_MODE'

      Get-RaymanWorkspaceEnvString -WorkspaceRoot $root -Name 'RAYMAN_INTERACTION_MODE' -Default 'detailed' | Should -Be 'general'
      [bool]$entry.configured | Should -BeTrue
      [string]$entry.source | Should -Be 'workspace_env'
      [string]$entry.value | Should -Be 'general'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_INTERACTION_MODE', $previousInteractionMode, 'Process')
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'limits dist sync trackedness enforcement to source workspaces only' {
    $assertPsRaw = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\release\assert_dist_sync.ps1') -Raw -Encoding UTF8
    $assertShRaw = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\release\assert_dist_sync.sh') -Raw -Encoding UTF8

    $assertPsRaw | Should -Match 'Get-RaymanWorkspaceKind'
    $assertPsRaw | Should -Match 'workspace kind is \{0\}; skip trackedness validation'
    $assertShRaw | Should -Match 'detect_workspace_kind'
    $assertShRaw | Should -Match 'workspace kind is \$\{workspace_kind\}; skip trackedness validation'
  }

  It 'backfills heartbeat defaults into an existing workspace env file without overwriting existing values' {
    $setupPath = Join-Path $PSScriptRoot '..\..\..\setup.ps1'
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_env_defaults_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $envFile = Join-Path $root '.rayman.env.ps1'
      Set-Content -LiteralPath $envFile -Encoding UTF8 -Value @'
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_HEARTBEAT_SECONDS)) {
    $env:RAYMAN_HEARTBEAT_SECONDS = '45'
}
'@

      $pwsh = Get-TestPowerShellPath
      $setupPathEscaped = $setupPath.Replace("'", "''")
      $envFileEscaped = $envFile.Replace("'", "''")
      $command = @"
`$setupPath = '$setupPathEscaped'
`$envFile = '$envFileEscaped'
`$tokens = `$null
`$errors = `$null
`$ast = [System.Management.Automation.Language.Parser]::ParseFile(`$setupPath, [ref]`$tokens, [ref]`$errors)
if (`$errors.Count -gt 0) { throw `$errors[0].Message }
`$getFailureAst = `$ast.Find({ param(`$node) `$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and `$node.Name -eq 'Get-SetupManagedWriteFailureMessage' }, `$true)
if (`$null -eq `$getFailureAst) { throw 'Get-SetupManagedWriteFailureMessage not found' }
`$invokeWriteAst = `$ast.Find({ param(`$node) `$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and `$node.Name -eq 'Invoke-SetupManagedFileWrite' }, `$true)
if (`$null -eq `$invokeWriteAst) { throw 'Invoke-SetupManagedFileWrite not found' }
`$functionAst = `$ast.Find({ param(`$node) `$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and `$node.Name -eq 'Ensure-WorkspaceEnvDefaults' }, `$true)
if (`$null -eq `$functionAst) { throw 'Ensure-WorkspaceEnvDefaults not found' }
. ([scriptblock]::Create(`$getFailureAst.Extent.Text))
. ([scriptblock]::Create(`$invokeWriteAst.Extent.Text))
. ([scriptblock]::Create(`$functionAst.Extent.Text))
`$WorkspaceRoot = Split-Path -Parent `$envFile
Ensure-WorkspaceEnvDefaults -EnvFilePath `$envFile
"@
      & $pwsh -NoProfile -ExecutionPolicy Bypass -Command $command | Out-Null
      $LASTEXITCODE | Should -Be 0

      $raw = Get-Content -LiteralPath $envFile -Raw -Encoding UTF8

      ([regex]::Matches($raw, '(?m)^\s*\$env:RAYMAN_HEARTBEAT_SECONDS\s*=\s*''45''\s*$')).Count | Should -Be 1
      foreach ($name in @(
        'RAYMAN_HEARTBEAT_VERBOSE',
        'RAYMAN_HEARTBEAT_SMART_SILENCE_ENABLED',
        'RAYMAN_HEARTBEAT_SILENT_WINDOW_SECONDS',
        'RAYMAN_SANDBOX_HEARTBEAT_SECONDS',
        'RAYMAN_MCP_HEARTBEAT_SECONDS'
      )) {
        [regex]::IsMatch($raw, [regex]::Escape("env:$name")) | Should -BeTrue
      }
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'removes legacy snapshot artifacts during setup cleanup without resetting current memory by default' {
    $setupPath = Join-Path $PSScriptRoot '..\..\..\setup.ps1'
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_setup_cleanup_' + [Guid]::NewGuid().ToString('N'))
    try {
      $snapshotRoot = Join-Path $root '.Rayman\runtime\snapshots'
      $memoryRoot = Join-Path $root '.Rayman\state\memory'
      $ragRoot = Join-Path $root ('.' + 'rag')
      $ragDbRoot = Join-Path $ragRoot 'legacy\chroma_db'
      New-Item -ItemType Directory -Force -Path $snapshotRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $memoryRoot | Out-Null
      New-Item -ItemType Directory -Force -Path $ragDbRoot | Out-Null

      $legacyManifest = Join-Path $snapshotRoot 'legacy.manifest.json'
      $legacyArchive = Join-Path $snapshotRoot 'legacy.tar.gz'
      $keepManifest = Join-Path $snapshotRoot 'keep.manifest.json'
      $memoryDb = Join-Path $memoryRoot 'memory.sqlite3'
      $legacyMarker = '.Rayman/state/' + ('chroma' + '_db')
      Set-Content -LiteralPath $legacyManifest -Encoding UTF8 -Value ('{{"excluded_paths":["{0}"]}}' -f $legacyMarker)
      Set-Content -LiteralPath $legacyArchive -Encoding UTF8 -Value 'snapshot'
      Set-Content -LiteralPath $keepManifest -Encoding UTF8 -Value '{"excluded_paths":[".Rayman/state/memory"]}'
      Set-Content -LiteralPath $memoryDb -Encoding UTF8 -Value 'current'

      $pwsh = Get-TestPowerShellPath
      $setupPathEscaped = $setupPath.Replace("'", "''")
      $rootEscaped = $root.Replace("'", "''")
      $command = @"
`$raymanCommonImported = `$false
`$setupPath = '$setupPathEscaped'
`$root = '$rootEscaped'
`$tokens = `$null
`$errors = `$null
`$ast = [System.Management.Automation.Language.Parser]::ParseFile(`$setupPath, [ref]`$tokens, [ref]`$errors)
if (`$errors.Count -gt 0) { throw `$errors[0].Message }
`$functionMap = @{}
foreach (`$fn in `$ast.FindAll({ param(`$node) `$node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, `$true)) {
  `$functionMap[[string]`$fn.Name] = `$fn
}
foreach (`$name in @(
  'Clear-SetupDirectoryContents',
  'Get-SetupLegacyMemoryPaths',
  'Get-SetupMemoryPaths',
  'Get-SetupLegacySnapshotArtifacts',
  'Invoke-SetupLegacyMemoryCleanup'
)) {
  `$functionAst = `$functionMap[[string]`$name]
  if (`$null -eq `$functionAst) { throw ('function not found: ' + `$name) }
  . ([scriptblock]::Create(`$functionAst.Extent.Text))
}
Invoke-SetupLegacyMemoryCleanup -WorkspaceRoot `$root | Out-Null
"@
      & $pwsh -NoProfile -ExecutionPolicy Bypass -Command $command | Out-Null
      $LASTEXITCODE | Should -Be 0

      Test-Path -LiteralPath $legacyManifest | Should -BeFalse
      Test-Path -LiteralPath $legacyArchive | Should -BeFalse
      Test-Path -LiteralPath $keepManifest | Should -BeTrue
      Test-Path -LiteralPath $ragRoot | Should -BeFalse
      Test-Path -LiteralPath $memoryDb | Should -BeTrue
      Test-Path -LiteralPath $memoryRoot -PathType Container | Should -BeTrue
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
      'RAYMAN_ALERT_SOUND_ENABLED',
      'RAYMAN_ALERT_SOUND_DONE_ENABLED',
      'RAYMAN_ALERT_WATCH_VSCODE_WINDOWS_ENABLED',
      'RAYMAN_ALERT_SOUND_PATH',
      'RAYMAN_ALERT_SURFACE',
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

  It 'defaults attention alerts to log-first with quiet done and speech behavior' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_attention_defaults_' + [Guid]::NewGuid().ToString('N'))
    $homeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_attention_home_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      New-Item -ItemType Directory -Force -Path $homeRoot | Out-Null
      Mock Get-RaymanAttentionUserHomePath { return $homeRoot }

      Get-RaymanAttentionSurface -WorkspaceRoot $root | Should -Be 'log'
      Get-RaymanAttentionAlertEnabled -WorkspaceRoot $root -Kind 'manual' | Should -BeTrue
      Get-RaymanAttentionAlertEnabled -WorkspaceRoot $root -Kind 'done' | Should -BeTrue
      Get-RaymanAttentionSoundEnabled -WorkspaceRoot $root -Kind 'manual' | Should -BeTrue
      Get-RaymanAttentionSoundEnabled -WorkspaceRoot $root -Kind 'done' | Should -BeTrue
      Get-RaymanAttentionSpeechEnabled -WorkspaceRoot $root -Kind 'manual' | Should -BeFalse
      Get-RaymanAttentionSpeechEnabled -WorkspaceRoot $root -Kind 'done' | Should -BeFalse
      [string](Get-RaymanAttentionSoundPath -WorkspaceRoot $root) | Should -Be (Join-Path $homeRoot '.rayman\codex\notify.wav')
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $homeRoot -Recurse -Force -ErrorAction SilentlyContinue
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
$env:RAYMAN_ALERT_TTS_ENABLED = '1'
$env:RAYMAN_ALERT_TTS_DONE_ENABLED = '0'
'@

      Get-RaymanAttentionSpeechEnabled -WorkspaceRoot $root -Kind 'done' | Should -BeFalse
      Get-RaymanAttentionSpeechEnabled -WorkspaceRoot $root -Kind 'manual' | Should -BeTrue
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'enables manual and done sounds independently and resolves relative sound paths' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_attention_sound_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.rayman.env.ps1') -Encoding UTF8 -Value @'
$env:RAYMAN_ALERT_DONE_ENABLED = '1'
$env:RAYMAN_ALERT_SOUND_ENABLED = '1'
$env:RAYMAN_ALERT_SOUND_DONE_ENABLED = '1'
$env:RAYMAN_ALERT_SOUND_PATH = 'audio\notify.wav'
'@

      Get-RaymanAttentionSoundEnabled -WorkspaceRoot $root -Kind 'manual' | Should -BeTrue
      Get-RaymanAttentionSoundEnabled -WorkspaceRoot $root -Kind 'done' | Should -BeTrue
      [string](Get-RaymanAttentionSoundPath -WorkspaceRoot $root) | Should -Be (Join-Path $root 'audio\notify.wav')
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'migrates the legacy .codex notify.wav into the Rayman-managed sound path when no explicit override exists' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_attention_legacy_sound_' + [Guid]::NewGuid().ToString('N'))
    $homeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_attention_legacy_home_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $legacySoundPath = Join-Path $homeRoot '.codex\notify.wav'
      $managedSoundPath = Join-Path $homeRoot '.rayman\codex\notify.wav'
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $legacySoundPath) | Out-Null
      Set-Content -LiteralPath $legacySoundPath -Encoding UTF8 -Value 'legacy-sound'
      Mock Get-RaymanAttentionUserHomePath { return $homeRoot }

      $resolvedPath = Get-RaymanAttentionSoundPath -WorkspaceRoot $root

      [string]$resolvedPath | Should -Be $managedSoundPath
      Test-Path -LiteralPath $managedSoundPath | Should -BeTrue
      (Get-Content -LiteralPath $managedSoundPath -Raw -Encoding UTF8).Trim() | Should -Be 'legacy-sound'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $homeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'restores notify.wav from a Rayman codex-notify backup when no legacy file exists' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_attention_backup_sound_' + [Guid]::NewGuid().ToString('N'))
    $homeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_attention_backup_home_' + [Guid]::NewGuid().ToString('N'))
    try {
      $backupRoot = Join-Path $root '.Rayman\runtime\backups\codex-notify\20260326_220738'
      New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
      $backupSoundPath = Join-Path $backupRoot 'global-notify.wav'
      $managedSoundPath = Join-Path $homeRoot '.rayman\codex\notify.wav'
      Set-Content -LiteralPath $backupSoundPath -Encoding UTF8 -Value 'backup-sound'
      Mock Get-RaymanAttentionUserHomePath { return $homeRoot }

      $resolvedPath = Get-RaymanAttentionSoundPath -WorkspaceRoot $root

      [string]$resolvedPath | Should -Be $managedSoundPath
      Test-Path -LiteralPath $managedSoundPath | Should -BeTrue
      (Get-Content -LiteralPath $managedSoundPath -Raw -Encoding UTF8).Trim() | Should -Be 'backup-sound'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $homeRoot -Recurse -Force -ErrorAction SilentlyContinue
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

  It 'includes VS Code and Codex windows in the default attention scan target list' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_attention_targets_' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null

      $names = @(Get-RaymanAttentionWatchProcessNames -WorkspaceRoot $root)

      $names | Should -Contain 'Code'
      $names | Should -Contain 'Codex'
      $names | Should -Contain 'WindowsSandbox'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'honors workspace-level explicit attention watch process names' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_attention_watch_names_' + [Guid]::NewGuid().ToString('N'))
    $previousNames = [Environment]::GetEnvironmentVariable('RAYMAN_ALERT_WATCH_PROCESS_NAMES', 'Process')
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.rayman.env.ps1') -Encoding UTF8 -Value @'
$env:RAYMAN_ALERT_WATCH_PROCESS_NAMES = 'FooApp,BarApp'
'@
      [Environment]::SetEnvironmentVariable('RAYMAN_ALERT_WATCH_PROCESS_NAMES', '', 'Process')

      $names = @(Get-RaymanAttentionWatchProcessNames -WorkspaceRoot $root)

      $names | Should -Contain 'FooApp'
      $names | Should -Contain 'BarApp'
      $names | Should -Not -Contain 'Code'
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_ALERT_WATCH_PROCESS_NAMES', $previousNames, 'Process')
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'request_attention sound helpers' {
  It 'keeps sound playback and -DisableSound wired through request_attention.ps1' {
    $requestRaw = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\utils\request_attention.ps1') -Raw -Encoding UTF8

    $requestRaw | Should -Match '\[switch\]\$DisableSound'
    $requestRaw | Should -Match 'function Resolve-AttentionSoundEnabled'
    $requestRaw | Should -Match 'ContainsKey\(''DisableSound''\)'
    $requestRaw | Should -Match 'Invoke-RaymanAttentionSoundFile'
    $requestRaw | Should -Match 'if \(\$soundEnabled\)'
  }

  It 'uses synchronous sound playback so short-lived notifier processes still ring reliably' {
    $commonRaw = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\..\common.ps1') -Raw -Encoding UTF8

    $commonRaw | Should -Match 'PlaySync\('
  }
}

Describe 'silent child process helpers' {
  It 'keeps native capture commands hidden on Windows and cleans up redirected temp files' {
    $commonRaw = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\..\common.ps1') -Raw -Encoding UTF8

    $commonRaw | Should -Match "function Invoke-RaymanNativeCommandCapture"
    $commonRaw | Should -Match "WindowStyle'\] = 'Hidden'"
    $commonRaw | Should -Match '\$proc\.Dispose\(\)'
    $commonRaw | Should -Match 'Remove-Item -LiteralPath \$stdoutPath -Force'
    $commonRaw | Should -Match 'Remove-Item -LiteralPath \$stderrPath -Force'
  }

  It 'keeps requirements bootstrap processes hidden and disposes them after completion' {
    $setupRaw = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\..\setup.ps1') -Raw -Encoding UTF8

    $setupRaw | Should -Match "Start-Process @processParams"
    $setupRaw | Should -Match "WindowStyle'\] = 'Hidden'"
    $setupRaw | Should -Match '\$proc\.Dispose\(\)'
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
