param(
  [string]$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path,
  [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $WorkspaceRoot '.Rayman\common.ps1')
. (Join-Path $WorkspaceRoot '.Rayman\scripts\utils\command_catalog.ps1')
. (Join-Path $WorkspaceRoot '.Rayman\scripts\testing\host_smoke.lib.ps1')

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$checks = New-Object 'System.Collections.Generic.List[object]'
$failures = New-Object 'System.Collections.Generic.List[string]'

function Add-Check {
  param(
    [string]$Name,
    [ValidateSet('PASS', 'FAIL', 'SKIP')][string]$Status,
    [string]$Detail
  )

  $checks.Add([pscustomobject]@{
      name = $Name
      status = $Status
      detail = $Detail
    }) | Out-Null

  if ($Status -eq 'FAIL') {
    $failures.Add(("{0}: {1}" -f $Name, $Detail)) | Out-Null
  }
}

function New-CommandMapFromCatalog {
  param([object[]]$Commands)

  $map = @{}
  foreach ($command in @($Commands)) {
    $map[[string]$command.name] = [string]$command.platform
  }
  return $map
}

function Get-ExpectedCommandMap {
  param([ValidateSet('bash', 'pwsh', 'recommended')][string]$Kind)

  switch ($Kind) {
    'bash' { return (New-CommandMapFromCatalog -Commands @(Get-RaymanCommandCatalogEntriesForSurface -WorkspaceRoot $WorkspaceRoot -Surface bash)) }
    'pwsh' { return (New-CommandMapFromCatalog -Commands @(Get-RaymanCommandCatalogEntriesForSurface -WorkspaceRoot $WorkspaceRoot -Surface pwsh)) }
    default { return (New-CommandMapFromCatalog -Commands @(Get-RaymanRecommendedCommandEntries -WorkspaceRoot $WorkspaceRoot)) }
  }
}

function Read-BlockBetweenMarkers {
  param(
    [string]$Path,
    [string]$BeginMarker,
    [string]$EndMarker
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw ("missing file: {0}" -f $Path)
  }

  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $pattern = '(?s)' + [regex]::Escape($BeginMarker) + '.*?' + [regex]::Escape($EndMarker)
  $match = [regex]::Match($raw, $pattern)
  if (-not $match.Success) {
    throw ("markers not found: {0}" -f $Path)
  }
  return $match.Value
}

function Get-CommandNameFromInvocation {
  param([string]$Invocation)

  $parts = @(([string]$Invocation).Trim() -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($parts.Count -ge 2) {
    return [string]$parts[1]
  }
  if ($parts.Count -eq 1) {
    return [string]$parts[0]
  }
  return ''
}

function Parse-CommandMapFromTaggedLines {
  param([string]$Text)

  $map = @{}
  foreach ($line in @($Text -split "`r?`n")) {
    if ($line -match '^\s{2}(\S+)\s+\[(all|pwsh-only|windows-only)\]\s+') {
      $map[$matches[1]] = $matches[2]
      continue
    }

    if ($line -match '^- `\[\s*([^\]]+?)\s*\]` `([^`]+)`[:：]') {
      $commandName = Get-CommandNameFromInvocation -Invocation $matches[2]
      if (-not [string]::IsNullOrWhiteSpace($commandName)) {
        $map[$commandName] = [string]$matches[1].Trim()
      }
    }
  }
  return $map
}

function Get-CommandMapDiffText {
  param(
    [hashtable]$Expected,
    [hashtable]$Actual
  )

  $missing = New-Object System.Collections.Generic.List[string]
  $unexpected = New-Object System.Collections.Generic.List[string]
  $mismatched = New-Object System.Collections.Generic.List[string]

  foreach ($name in @($Expected.Keys | Sort-Object)) {
    if (-not $Actual.ContainsKey($name)) {
      $missing.Add($name) | Out-Null
      continue
    }
    if ([string]$Actual[$name] -ne [string]$Expected[$name]) {
      $mismatched.Add(("{0} expected={1} actual={2}" -f $name, [string]$Expected[$name], [string]$Actual[$name])) | Out-Null
    }
  }

  foreach ($name in @($Actual.Keys | Sort-Object)) {
    if (-not $Expected.ContainsKey($name)) {
      $unexpected.Add($name) | Out-Null
    }
  }

  if ($missing.Count -eq 0 -and $unexpected.Count -eq 0 -and $mismatched.Count -eq 0) {
    return 'ok'
  }

  $parts = New-Object System.Collections.Generic.List[string]
  if ($missing.Count -gt 0) {
    $parts.Add(("missing={0}" -f (($missing | ForEach-Object { $_ }) -join ', '))) | Out-Null
  }
  if ($unexpected.Count -gt 0) {
    $parts.Add(("unexpected={0}" -f (($unexpected | ForEach-Object { $_ }) -join ', '))) | Out-Null
  }
  if ($mismatched.Count -gt 0) {
    $parts.Add(("platform_mismatch={0}" -f (($mismatched | ForEach-Object { $_ }) -join '; '))) | Out-Null
  }
  return ($parts -join ' | ')
}

function Parse-BashEntrypointMap {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw ("missing file: {0}" -f $Path)
  }

  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $outerMatch = [regex]::Match($raw, '(?s)case "\$cmd" in(?<body>.*)\nesac\s*\r?\n\s*rayman_emit_done_alert')
  if (-not $outerMatch.Success) {
    throw ("main case block not found: {0}" -f $Path)
  }

  $map = @{}
  foreach ($line in @($outerMatch.Groups['body'].Value -split "`r?`n")) {
    if ($line -match '^\s{2}([^)]+)\)\s*$') {
      foreach ($label in @($matches[1] -split '\|')) {
        $name = [string]$label.Trim()
        if ([string]::IsNullOrWhiteSpace($name) -or $name -eq '*') { continue }
        $map[$name] = 'all'
      }
    }
  }

  return $map
}

function Get-MissingCommandText {
  param(
    [string[]]$ExpectedNames,
    [hashtable]$Actual
  )

  $missing = @($ExpectedNames | Sort-Object | Where-Object { -not $Actual.ContainsKey([string]$_) })
  if ($missing.Count -eq 0) {
    return 'ok'
  }
  return ('missing={0}' -f ($missing -join ', '))
}

function Invoke-CommandText {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [string]$WorkingDirectory = ''
  )

  $capture = Invoke-RaymanNativeCommandCapture -FilePath $FilePath -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory
  return [pscustomobject]@{
    exit_code = if ([bool]$capture.started) { [int]$capture.exit_code } else { -1 }
    output = (Get-RaymanHostSmokeMergedOutput -Capture $capture).TrimEnd("`r", "`n")
  }
}

$updateDocsScript = Join-Path $WorkspaceRoot '.Rayman\scripts\utils\update_command_docs.ps1'
try {
  & $updateDocsScript -WorkspaceRoot $WorkspaceRoot -Verify | Out-Null
  Add-Check -Name 'generated_docs' -Status PASS -Detail 'commands.txt and README markers match command catalog'
} catch {
  Add-Check -Name 'generated_docs' -Status FAIL -Detail $_.Exception.Message
}

$expectedBash = Get-ExpectedCommandMap -Kind bash
$expectedPwsh = Get-ExpectedCommandMap -Kind pwsh
$expectedRecommended = Get-ExpectedCommandMap -Kind recommended
$expectedFull = New-CommandMapFromCatalog -Commands @(Import-RaymanCommandCatalog -WorkspaceRoot $WorkspaceRoot)

$bashInvocation = New-RaymanHostSmokeBashInvocation -WorkspaceRoot $WorkspaceRoot -CommandText 'bash ./.Rayman/rayman help'
if ($null -eq $bashInvocation) {
  Add-Check -Name 'bash_help' -Status SKIP -Detail 'bash not available on current host'
} else {
  $bashResult = Invoke-CommandText -FilePath ([string]$bashInvocation.path) -Arguments @($bashInvocation.argument_list)
  if ($bashResult.exit_code -ne 0) {
    Add-Check -Name 'bash_help' -Status FAIL -Detail ("bash help failed (exit={0})" -f $bashResult.exit_code)
  } else {
    $actualBash = Parse-CommandMapFromTaggedLines -Text $bashResult.output
    $bashDiff = Get-CommandMapDiffText -Expected $expectedBash -Actual $actualBash
    Add-Check -Name 'bash_help' -Status $(if ($bashDiff -eq 'ok') { 'PASS' } else { 'FAIL' }) -Detail $bashDiff
  }
}

try {
  $actualBashEntrypoints = Parse-BashEntrypointMap -Path (Join-Path $WorkspaceRoot '.Rayman\rayman')
  $bashEntrypointDiff = Get-MissingCommandText -ExpectedNames @($expectedBash.Keys) -Actual $actualBashEntrypoints
  Add-Check -Name 'bash_entrypoints' -Status $(if ($bashEntrypointDiff -eq 'ok') { 'PASS' } else { 'FAIL' }) -Detail $bashEntrypointDiff
} catch {
  Add-Check -Name 'bash_entrypoints' -Status FAIL -Detail $_.Exception.Message
}

$pwshPath = Resolve-RaymanHostSmokeCommandPath -Names @('pwsh', 'pwsh.exe', 'powershell', 'powershell.exe')
if ([string]::IsNullOrWhiteSpace($pwshPath)) {
  Add-Check -Name 'pwsh_help' -Status FAIL -Detail 'pwsh not found'
} else {
  $pwshResult = Invoke-CommandText -FilePath $pwshPath -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $WorkspaceRoot '.Rayman\rayman.ps1'), 'help') -WorkingDirectory $WorkspaceRoot
  if ($pwshResult.exit_code -ne 0) {
    Add-Check -Name 'pwsh_help' -Status FAIL -Detail ("pwsh help failed (exit={0})" -f $pwshResult.exit_code)
  } else {
    $actualPwsh = Parse-CommandMapFromTaggedLines -Text $pwshResult.output
    $pwshDiff = Get-CommandMapDiffText -Expected $expectedPwsh -Actual $actualPwsh
    Add-Check -Name 'pwsh_help' -Status $(if ($pwshDiff -eq 'ok') { 'PASS' } else { 'FAIL' }) -Detail $pwshDiff
  }
}

try {
  $readmeBlock = Read-BlockBetweenMarkers -Path (Join-Path $WorkspaceRoot '.Rayman\README.md') -BeginMarker '<!-- RAYMAN:COMMANDS:BEGIN -->' -EndMarker '<!-- RAYMAN:COMMANDS:END -->'
  $actualReadme = Parse-CommandMapFromTaggedLines -Text $readmeBlock
  $readmeDiff = Get-CommandMapDiffText -Expected $expectedFull -Actual $actualReadme
  Add-Check -Name 'readme_commands' -Status $(if ($readmeDiff -eq 'ok') { 'PASS' } else { 'FAIL' }) -Detail $readmeDiff
} catch {
  Add-Check -Name 'readme_commands' -Status FAIL -Detail $_.Exception.Message
}

try {
  $commandsRaw = Get-Content -LiteralPath (Join-Path $WorkspaceRoot '.Rayman\commands.txt') -Raw -Encoding UTF8
  $actualCommandsText = Parse-CommandMapFromTaggedLines -Text $commandsRaw
  $commandsDiff = Get-CommandMapDiffText -Expected $expectedFull -Actual $actualCommandsText
  Add-Check -Name 'commands_txt' -Status $(if ($commandsDiff -eq 'ok') { 'PASS' } else { 'FAIL' }) -Detail $commandsDiff
} catch {
  Add-Check -Name 'commands_txt' -Status FAIL -Detail $_.Exception.Message
}

$contextPath = Join-Path $WorkspaceRoot '.Rayman\CONTEXT.md'
if (-not (Test-Path -LiteralPath $contextPath -PathType Leaf)) {
  Add-Check -Name 'context_recommended' -Status SKIP -Detail 'local-generated CONTEXT.md not present'
} else {
  try {
    $recommendedBlock = Read-BlockBetweenMarkers -Path $contextPath -BeginMarker '<!-- RAYMAN:RECOMMENDED:BEGIN -->' -EndMarker '<!-- RAYMAN:RECOMMENDED:END -->'
    $actualRecommended = Parse-CommandMapFromTaggedLines -Text $recommendedBlock
    $recommendedDiff = Get-CommandMapDiffText -Expected $expectedRecommended -Actual $actualRecommended
    Add-Check -Name 'context_recommended' -Status $(if ($recommendedDiff -eq 'ok') { 'PASS' } else { 'FAIL' }) -Detail $recommendedDiff
  } catch {
    Add-Check -Name 'context_recommended' -Status FAIL -Detail $_.Exception.Message
  }
}

$result = [pscustomobject]@{
  workspace_root = $WorkspaceRoot
  success = ($failures.Count -eq 0)
  checks = @($checks.ToArray())
}

if ($AsJson) {
  $result | ConvertTo-Json -Depth 6
} else {
  foreach ($check in @($checks.ToArray())) {
    Write-Host ("[{0}] {1} - {2}" -f [string]$check.status, [string]$check.name, [string]$check.detail)
  }
}

if ($failures.Count -gt 0) {
  exit 1
}
