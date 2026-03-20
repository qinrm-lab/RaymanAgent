param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$Verify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'command_catalog.ps1')

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$commandsPath = Join-Path $WorkspaceRoot '.Rayman\commands.txt'
$readmePath = Join-Path $WorkspaceRoot '.Rayman\README.md'

$expectedCommands = Get-RaymanCommandsText -WorkspaceRoot $WorkspaceRoot
$expectedReadmeBlock = Get-RaymanReadmeCommandSection -WorkspaceRoot $WorkspaceRoot

function Write-Utf8NoBomFile {
  param(
    [string]$Path,
    [string]$Content
  )

  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Set-GeneratedFileContent {
  param(
    [string]$Path,
    [string]$Expected,
    [switch]$VerifyOnly
  )

  $current = ''
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    $current = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  }
  if ($current -eq $Expected) {
    return $false
  }
  if ($VerifyOnly) {
    throw ("generated file stale: {0}. Run ./.Rayman/scripts/utils/update_command_docs.ps1" -f $Path)
  }
  Write-Utf8NoBomFile -Path $Path -Content $Expected
  return $true
}

function Update-ReadmeBlock {
  param(
    [string]$Path,
    [string]$ExpectedBlock,
    [switch]$VerifyOnly
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw ("README missing: {0}" -f $Path)
  }

  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $pattern = '(?s)<!-- RAYMAN:COMMANDS:BEGIN -->.*?<!-- RAYMAN:COMMANDS:END -->\r?\n?'
  if ($raw -notmatch '<!-- RAYMAN:COMMANDS:BEGIN -->' -or $raw -notmatch '<!-- RAYMAN:COMMANDS:END -->') {
    throw ("README command markers missing: {0}" -f $Path)
  }
  $updated = [regex]::Replace($raw, $pattern, $ExpectedBlock, 1)
  $readmeNewline = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
  $updated = $updated.TrimEnd("`r", "`n") + $readmeNewline
  if ($updated -eq $raw) {
    return $false
  }
  if ($VerifyOnly) {
    throw ("README command block stale: {0}. Run ./.Rayman/scripts/utils/update_command_docs.ps1" -f $Path)
  }
  Write-Utf8NoBomFile -Path $Path -Content $updated
  return $true
}

$commandsChanged = Set-GeneratedFileContent -Path $commandsPath -Expected $expectedCommands -VerifyOnly:$Verify
$readmeChanged = Update-ReadmeBlock -Path $readmePath -ExpectedBlock $expectedReadmeBlock -VerifyOnly:$Verify

if ($Verify) {
  Write-Output 'OK'
  exit 0
}

if ($commandsChanged) {
  Write-Host ("[command-docs] wrote {0}" -f $commandsPath) -ForegroundColor Green
}
if ($readmeChanged) {
  Write-Host ("[command-docs] updated {0}" -f $readmePath) -ForegroundColor Green
}
