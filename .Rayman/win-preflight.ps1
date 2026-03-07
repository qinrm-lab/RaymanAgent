param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\.." | Select-Object -ExpandProperty Path)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info([string]$Message) { Write-Host ("[win-preflight] {0}" -f $Message) -ForegroundColor Cyan }
function Fail([string]$Message) { Write-Host ("[win-preflight] {0}" -f $Message) -ForegroundColor Red; exit 2 }

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$raymanDir = Join-Path $WorkspaceRoot '.Rayman'

if (-not (Test-Path -LiteralPath $raymanDir -PathType Container)) {
  Fail ("missing .Rayman directory: {0}" -f $raymanDir)
}

$targets = Get-ChildItem -LiteralPath $raymanDir -Recurse -File -Filter '*.ps1' | Where-Object {
  $_.FullName -notmatch '\\logs\\' -and
  $_.FullName -notmatch '\\runtime\\' -and
  $_.FullName -notmatch '\\state\\'
}

$errorsFound = New-Object System.Collections.Generic.List[string]
foreach ($file in $targets) {
  $tokens = $null
  $parseErrors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
  if ($parseErrors -and $parseErrors.Count -gt 0) {
    foreach ($parseError in $parseErrors) {
      [void]$errorsFound.Add(("{0}:{1}:{2} {3}" -f $file.FullName, $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message))
    }
  }
}

if ($errorsFound.Count -gt 0) {
  $preview = $errorsFound | Select-Object -First 10
  foreach ($line in $preview) {
    Write-Host $line -ForegroundColor Yellow
  }
  Fail ("PowerShell preflight failed with {0} parse error(s)." -f $errorsFound.Count)
}

Info ("PowerShell preflight passed for {0} file(s)." -f $targets.Count)
