param(
  [string]$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path,
  [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$emitJson = [bool]$AsJson

# schema: rayman.manual_command_contracts.v1
. (Join-Path $WorkspaceRoot '.Rayman\common.ps1')
. (Join-Path $WorkspaceRoot '.Rayman\scripts\utils\command_catalog.ps1')
. (Join-Path $WorkspaceRoot '.Rayman\scripts\agents\agent_asset_manifest.ps1')
$AsJson = [System.Management.Automation.SwitchParameter]$emitJson

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$checks = New-Object 'System.Collections.Generic.List[object]'
$failures = New-Object 'System.Collections.Generic.List[string]'
$unitBackedCache = @{}

function Test-ManualCommandCurrentHostIsWindows {
  if (Get-Command Test-RaymanWindowsPlatform -ErrorAction SilentlyContinue) {
    return [bool](Test-RaymanWindowsPlatform)
  }
  return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
}

function Resolve-UnitBackedPowerShellHost {
  $preferWindowsInterop = -not (Test-ManualCommandCurrentHostIsWindows)
  $candidates = if ($preferWindowsInterop) {
    @('pwsh.exe', 'powershell.exe', 'pwsh', 'powershell')
  } else {
    @('pwsh', 'pwsh.exe', 'powershell.exe', 'powershell')
  }

  foreach ($candidate in $candidates) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $cmd -or [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
      continue
    }

    $source = [string]$cmd.Source
    return [pscustomobject]@{
      source = $source
      is_windows_host = ($source -match '(?i)\.exe$')
    }
  }

  return $null
}

function Convert-UnitBackedPathForHost {
  param(
    [string]$Path,
    [bool]$WindowsHost
  )

  if ([string]::IsNullOrWhiteSpace($Path) -or -not $WindowsHost) {
    return $Path
  }
  if (Test-ManualCommandCurrentHostIsWindows) {
    return $Path
  }

  $wslPathCmd = Get-Command 'wslpath' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $wslPathCmd -or [string]::IsNullOrWhiteSpace([string]$wslPathCmd.Source)) {
    return $Path
  }

  try {
    $converted = (& $wslPathCmd.Source -w $Path | Select-Object -First 1)
    if (-not [string]::IsNullOrWhiteSpace([string]$converted)) {
      return [string]$converted.Trim()
    }
  } catch {}

  return $Path
}

function Get-ManualCommandCapturedOutputTail {
  param(
    [string]$Path,
    [int]$MaxLines = 24,
    [int]$MaxChars = 1600
  )

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return ''
  }

  $raw = $null
  try {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
  } catch {
    try {
      $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    } catch {
      return ''
    }
  }

  $text = if ($null -eq $raw) { '' } else { [string]$raw }
  if ([string]::IsNullOrWhiteSpace($text)) {
    return ''
  }

  $text = $text -replace '\x1b\[[0-9;?]*[ -/]*[@-~]', ''
  $lines = @(
    $text -split "`r?`n" |
      ForEach-Object { ([string]$_).Trim() } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )
  if ($lines.Count -eq 0) {
    return ''
  }
  if ($lines.Count -gt $MaxLines) {
    $lines = $lines[($lines.Count - $MaxLines)..($lines.Count - 1)]
  }

  $tail = ($lines -join ' | ').Trim()
  if ($tail.Length -gt $MaxChars) {
    $tail = '...' + $tail.Substring($tail.Length - $MaxChars)
  }
  return $tail
}

function Add-ManualCommandCheck {
  param(
    [string]$Name,
    [bool]$Passed,
    [string]$Detail
  )

  $checks.Add([pscustomobject]@{
      name = $Name
      passed = $Passed
      detail = $Detail
    }) | Out-Null

  if (-not $Passed) {
    $failures.Add(("{0}: {1}" -f $Name, $Detail)) | Out-Null
  }
}

function Get-ManualCommandFileContent {
  param([object]$Scope)

  $fullPath = Join-Path $WorkspaceRoot ([string]$Scope.relative_path)
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    throw ("missing file: {0}" -f [string]$Scope.relative_path)
  }

  $raw = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8
  if ([bool]$Scope.strip_generated_command_block) {
    $raw = [regex]::Replace($raw, '(?s)<!-- RAYMAN:COMMANDS:BEGIN -->.*?<!-- RAYMAN:COMMANDS:END -->', '')
  }
  return $raw
}

function Get-ManualCommandNormalizedText {
  param([string]$Text)

  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $value = [string]$Text
  $value = $value -replace '\s+', ' '
  $value = $value.Trim()
  $value = $value.TrimEnd('.', ',', ';', ':', '，', '。')
  return $value.Trim()
}

function Get-ManualCommandSegmentsFromMarkdown {
  param([string]$Text)

  $segments = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList @([System.StringComparer]::OrdinalIgnoreCase)

  foreach ($match in [regex]::Matches($Text, '(?s)```[^\r\n]*\r?\n(?<block>.*?)```')) {
    $block = [string]$match.Groups['block'].Value
    foreach ($line in @($block -split "`r?`n")) {
      $candidate = Get-ManualCommandNormalizedText -Text $line
      if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
      if (
        $candidate -cmatch '^(?:rayman(?:\.ps1)?\s+)' -or
        $candidate -match '^(?i)(?:\./|\.\\)?\.?Rayman[\\/](?:scripts[\\/][^ ]+\.(?:ps1|sh)|rayman\.ps1)\b'
      ) {
        [void]$segments.Add($candidate)
      }
    }
  }

  foreach ($match in [regex]::Matches($Text, '`(?<code>[^`]+)`')) {
    $candidate = Get-ManualCommandNormalizedText -Text ([string]$match.Groups['code'].Value)
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    if (
      $candidate -cmatch '^(?:rayman(?:\.ps1)?\s+)' -or
      $candidate -match '^(?i)(?:\./|\.\\)?\.?Rayman[\\/](?:scripts[\\/][^ ]+\.(?:ps1|sh)|rayman\.ps1)\b'
    ) {
      [void]$segments.Add($candidate)
    }
  }

  return @($segments | Sort-Object)
}

function Resolve-ManualCommandCatalogExpectation {
  param([string]$CommandText)

  $normalized = Get-ManualCommandNormalizedText -Text $CommandText
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    return $null
  }

  $surface = ''
  $rootCommand = ''
  if ($normalized -match '^(?i)rayman\.ps1\s+(?<cmd>[A-Za-z0-9_.-]+)\b') {
    $surface = 'pwsh'
    $rootCommand = [string]$matches['cmd']
  } elseif ($normalized -match '^(?i)rayman\s+(?<cmd>[A-Za-z0-9_.-]+)\b') {
    $surface = 'bash'
    $rootCommand = [string]$matches['cmd']
  } else {
    return $null
  }

  $catalogMap = Get-RaymanCommandCatalogByName -WorkspaceRoot $WorkspaceRoot
  if (-not $catalogMap.ContainsKey($rootCommand)) {
    return [pscustomobject]@{
      ok = $false
      platform = ''
      root_command = $rootCommand
      surface = $surface
      detail = ("missing catalog entry: {0}" -f $rootCommand)
    }
  }

  $entry = $catalogMap[$rootCommand]
  $platform = [string]$entry.platform
  if ($surface -eq 'bash' -and $platform -ne 'all') {
    return [pscustomobject]@{
      ok = $false
      platform = $platform
      root_command = $rootCommand
      surface = $surface
      detail = ("command requires rayman.ps1 surface: {0}" -f $normalized)
    }
  }

  return [pscustomobject]@{
    ok = $true
    platform = $platform
    root_command = $rootCommand
    surface = $surface
    detail = ("catalog={0}/{1}" -f $rootCommand, $platform)
  }
}

function Resolve-ManualCommandVerificationRule {
  param([string]$CommandText)

  $normalized = Get-ManualCommandNormalizedText -Text $CommandText
  foreach ($rule in @(Get-RaymanManualCommandVerificationRules)) {
    if ($normalized -match [string]$rule.match_pattern) {
      return $rule
    }
  }
  return $null
}

function Invoke-UnitBackedManualCommandValidation {
  param([string]$RelativePath)

  if ($unitBackedCache.ContainsKey($RelativePath)) {
    return $unitBackedCache[$RelativePath]
  }

  $fullPath = Join-Path $WorkspaceRoot $RelativePath
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    $result = [pscustomobject]@{
      ok = $false
      detail = ("missing pester target: {0}" -f $RelativePath)
    }
    $unitBackedCache[$RelativePath] = $result
    return $result
  }

  $psHost = Resolve-UnitBackedPowerShellHost
  if ($null -eq $psHost -or [string]::IsNullOrWhiteSpace([string]$psHost.source)) {
    $result = [pscustomobject]@{
      ok = $false
      detail = 'PowerShell host not found for unit-backed validation.'
    }
    $unitBackedCache[$RelativePath] = $result
    return $result
  }

  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_manual_contract_' + [Guid]::NewGuid().ToString('N'))
  $runnerPathLocal = $tempRoot + '.ps1'
  $stdoutPathLocal = $tempRoot + '.stdout.txt'
  $stderrPathLocal = $tempRoot + '.stderr.txt'
  $targetPath = Convert-UnitBackedPathForHost -Path $fullPath -WindowsHost ([bool]$psHost.is_windows_host)
  $runnerPath = Convert-UnitBackedPathForHost -Path $runnerPathLocal -WindowsHost ([bool]$psHost.is_windows_host)
  $stdoutPath = Convert-UnitBackedPathForHost -Path $stdoutPathLocal -WindowsHost ([bool]$psHost.is_windows_host)
  $stderrPath = Convert-UnitBackedPathForHost -Path $stderrPathLocal -WindowsHost ([bool]$psHost.is_windows_host)
  try {
    $runner = @"
`$ErrorActionPreference = 'Stop'
`$InformationPreference = 'SilentlyContinue'
`$ProgressPreference = 'SilentlyContinue'
`$pesterModule = Get-Module -ListAvailable -Name Pester | Where-Object { `$_.Version -ge [Version]'5.0.0' } | Sort-Object Version -Descending | Select-Object -First 1
if (`$null -eq `$pesterModule) { throw 'Pester 5+ is not installed.' }
Import-Module ([string]`$pesterModule.Path) -Force | Out-Null
`$config = New-PesterConfiguration
`$config.Run.Path = @('$targetPath')
`$config.Run.PassThru = `$true
`$config.Output.Verbosity = 'None'
`$result = Invoke-Pester -Configuration `$config 6>`$null
if ([int]`$result.FailedCount -gt 0) { exit 1 }
exit 0
"@
    Set-Content -LiteralPath $runnerPathLocal -Value $runner -Encoding UTF8
    $startProcessArgs = @{
      FilePath = [string]$psHost.source
      ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerPath)
      PassThru = $true
      Wait = $true
      RedirectStandardOutput = $stdoutPath
      RedirectStandardError = $stderrPath
    }
    $isWindowsHost = $false
    if (Get-Command Test-RaymanWindowsPlatform -ErrorAction SilentlyContinue) {
      $isWindowsHost = [bool](Test-RaymanWindowsPlatform)
    } else {
      $isWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
    }
    if ($isWindowsHost) {
      $startProcessArgs.WindowStyle = 'Hidden'
    }
    $proc = Start-Process @startProcessArgs
    $detailSuffix = ''
    if ([int]$proc.ExitCode -ne 0) {
      $detailParts = New-Object System.Collections.Generic.List[string]
      $stdout = Get-ManualCommandCapturedOutputTail -Path $stdoutPathLocal
      $stderr = Get-ManualCommandCapturedOutputTail -Path $stderrPathLocal
      if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        $detailParts.Add(('stdout={0}' -f $stdout)) | Out-Null
      }
      if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        $detailParts.Add(('stderr={0}' -f $stderr)) | Out-Null
      }
      if ($detailParts.Count -gt 0) {
        $detailSuffix = ('; {0}' -f (($detailParts | ForEach-Object { $_ }) -join '; '))
      }
    }
    $result = [pscustomobject]@{
      ok = ([int]$proc.ExitCode -eq 0)
      detail = ("pester={0}; exit={1}{2}" -f $RelativePath, [int]$proc.ExitCode, $detailSuffix)
    }
    $unitBackedCache[$RelativePath] = $result
    return $result
  } finally {
    foreach ($path in @($runnerPathLocal, $stdoutPathLocal, $stderrPathLocal)) {
      if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
      }
    }
  }
}

function Invoke-ManualCommandVerification {
  param(
    [string]$RelativePath,
    [string]$CommandText,
    [object]$Rule
  )

  $normalized = Get-ManualCommandNormalizedText -Text $CommandText
  if ($null -eq $Rule) {
    return [pscustomobject]@{
      ok = $false
      detail = ("unmanaged command reference: {0}" -f $normalized)
    }
  }

  switch ([string]$Rule.verification_profile) {
    'cli_help' {
      return (Resolve-ManualCommandCatalogExpectation -CommandText $normalized)
    }
    'script_exists' {
      $scriptPath = $normalized -replace '\s+.*$', ''
      $resolvedPath = Join-Path $WorkspaceRoot $scriptPath
      return [pscustomobject]@{
        ok = (Test-Path -LiteralPath $resolvedPath -PathType Leaf)
        detail = ("script_exists={0}" -f $scriptPath)
      }
    }
    'unit_backed' {
      $catalogCheck = Resolve-ManualCommandCatalogExpectation -CommandText $normalized
      if ($null -ne $catalogCheck -and -not [bool]$catalogCheck.ok) {
        return $catalogCheck
      }
      $psHost = Resolve-UnitBackedPowerShellHost
      if (
        $null -ne $catalogCheck -and
        [bool]$catalogCheck.ok -and
        [string]$catalogCheck.platform -eq 'windows-only' -and
        -not (Test-ManualCommandCurrentHostIsWindows) -and
        ($null -eq $psHost -or -not [bool]$psHost.is_windows_host)
      ) {
        $targetPath = Join-Path $WorkspaceRoot ([string]$Rule.verification_target)
        return [pscustomobject]@{
          ok = (Test-Path -LiteralPath $targetPath -PathType Leaf)
          detail = ("{0}; pester={1}; skip=non-windows-host" -f [string]$catalogCheck.detail, [string]$Rule.verification_target)
        }
      }
      $unitCheck = Invoke-UnitBackedManualCommandValidation -RelativePath ([string]$Rule.verification_target)
      if ($null -ne $catalogCheck -and [bool]$catalogCheck.ok) {
        return [pscustomobject]@{
          ok = [bool]$unitCheck.ok
          detail = ("{0}; {1}" -f [string]$catalogCheck.detail, [string]$unitCheck.detail)
        }
      }
      return $unitCheck
    }
    default {
      return [pscustomobject]@{
        ok = $false
        detail = ("unsupported verification profile: {0}" -f [string]$Rule.verification_profile)
      }
    }
  }
}

foreach ($scope in @(Get-RaymanManualCommandDocumentScopes)) {
  $relativePath = [string]$scope.relative_path
  $fullPath = Join-Path $WorkspaceRoot $relativePath
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    $isHistoricalScope = ([string]$scope.mode -eq 'historical')
    $detail = if ($isHistoricalScope) { 'historical archive omitted from tracked repo surface' } else { 'missing' }
    Add-ManualCommandCheck -Name $relativePath -Passed $isHistoricalScope -Detail $detail
    continue
  }

  $content = Get-ManualCommandFileContent -Scope $scope
  if ([string]$scope.mode -eq 'historical') {
    $missingTokens = @($scope.required_tokens | Where-Object { $content -notmatch [regex]::Escape([string]$_) })
    Add-ManualCommandCheck -Name $relativePath -Passed ($missingTokens.Count -eq 0) -Detail $(if ($missingTokens.Count -eq 0) { 'historical archive marker present' } else { ("missing historical markers: {0}" -f ($missingTokens -join ', ')) })
    continue
  }

  $commandMatches = @(Get-ManualCommandSegmentsFromMarkdown -Text $content)
  if ($commandMatches.Count -eq 0) {
    Add-ManualCommandCheck -Name $relativePath -Passed $true -Detail 'no live manual command references'
    continue
  }

  foreach ($commandMatch in $commandMatches) {
    $rule = Resolve-ManualCommandVerificationRule -CommandText $commandMatch
    $verification = Invoke-ManualCommandVerification -RelativePath $relativePath -CommandText $commandMatch -Rule $rule
    Add-ManualCommandCheck -Name ("{0} :: {1}" -f $relativePath, $commandMatch) -Passed ([bool]$verification.ok) -Detail ([string]$verification.detail)
  }
}

$result = [pscustomobject]@{
  workspace_root = $WorkspaceRoot
  passed = ($failures.Count -eq 0)
  check_count = $checks.Count
  failure_count = $failures.Count
  checks = @($checks.ToArray())
}

if ([bool]$AsJson) {
  return ($result | ConvertTo-Json -Depth 8 -Compress)
} else {
  foreach ($check in @($checks.ToArray())) {
    $status = if ($check.passed) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1} - {2}" -f $status, [string]$check.name, [string]$check.detail) -ForegroundColor $(if ($check.passed) { 'Green' } else { 'Red' })
  }
  if ($failures.Count -eq 0) {
    Write-Host 'Manual command contracts passed.' -ForegroundColor Green
  } else {
    Write-Host ('Manual command contracts failed: {0}' -f ($failures -join ' | ')) -ForegroundColor Red
  }
}

if ($failures.Count -gt 0) {
  exit 1
}
