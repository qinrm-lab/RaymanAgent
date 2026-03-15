param(
  [string]$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path,
  [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $WorkspaceRoot '.Rayman\scripts\utils\command_catalog.ps1')

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
    if ($line -match '^\s{2}([a-z0-9-]+)\s+\[(all|pwsh-only|windows-only)\]\s+') {
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

function Invoke-CommandText {
  param(
    [string]$FilePath,
    [string[]]$Arguments
  )

  try {
    $output = & $FilePath @Arguments 2>&1 | Out-String
    $exitCode = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }
    return [pscustomobject]@{
      exit_code = $exitCode
      output = $output.TrimEnd("`r", "`n")
    }
  } catch {
    return [pscustomobject]@{
      exit_code = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 1 }
      output = $_.Exception.ToString()
    }
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
$expectedFull = Get-ExpectedCommandMap -Kind pwsh

$bashCmd = Get-Command bash -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $bashCmd) {
  Add-Check -Name 'bash_help' -Status FAIL -Detail 'bash not found'
} else {
  $bashResult = Invoke-CommandText -FilePath $bashCmd.Source -Arguments @('-lc', "cd '$WorkspaceRoot' && bash ./.Rayman/rayman help")
  if ($bashResult.exit_code -ne 0) {
    Add-Check -Name 'bash_help' -Status FAIL -Detail ("bash help failed (exit={0})" -f $bashResult.exit_code)
  } else {
    $actualBash = Parse-CommandMapFromTaggedLines -Text $bashResult.output
    $bashDiff = Get-CommandMapDiffText -Expected $expectedBash -Actual $actualBash
    Add-Check -Name 'bash_help' -Status $(if ($bashDiff -eq 'ok') { 'PASS' } else { 'FAIL' }) -Detail $bashDiff
  }
}

$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $pwshCmd) {
  Add-Check -Name 'pwsh_help' -Status FAIL -Detail 'pwsh not found'
} else {
  $pwshResult = Invoke-CommandText -FilePath $pwshCmd.Source -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $WorkspaceRoot '.Rayman\rayman.ps1'), 'help')
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
  foreach ($check in @($checks)) {
    Write-Host ("[{0}] {1} - {2}" -f [string]$check.status, [string]$check.name, [string]$check.detail)
  }
}

if ($failures.Count -gt 0) {
  exit 1
}
