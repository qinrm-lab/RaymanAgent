param(
  [Parameter(Mandatory=$true)][int]$ParentPid,
  [string]$ParentStartUtc = '',
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\.." | Select-Object -ExpandProperty Path),
  [string]$SessionFile = '',
  [int]$PollSeconds = 5,
  [switch]$StopBackgroundWatchersOnExit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path

function Write-Session([string]$State) {
  if ([string]::IsNullOrWhiteSpace($SessionFile)) { return }
  $sessionDir = Split-Path -Parent $SessionFile
  if (-not (Test-Path -LiteralPath $sessionDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
  }

  $payload = [ordered]@{
    parentPid = $ParentPid
    parentStartUtc = $ParentStartUtc
    state = $State
    updatedAt = (Get-Date).ToString('o')
  } | ConvertTo-Json -Depth 4

  [System.IO.File]::WriteAllText($SessionFile, $payload, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-ParentAlive {
  try {
    $proc = Get-Process -Id $ParentPid -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace($ParentStartUtc)) {
      $actual = $proc.StartTime.ToUniversalTime().ToString('o')
      if ($actual -ne $ParentStartUtc) {
        return $false
      }
    }
    return $true
  } catch {
    return $false
  }
}

Write-Session -State 'watching'
while (Test-ParentAlive) {
  Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
}

Write-Session -State 'parent-exited'

if ($StopBackgroundWatchersOnExit) {
  $stopScript = Join-Path $WorkspaceRoot '.Rayman\scripts\watch\stop_background_watchers.ps1'
  if (Test-Path -LiteralPath $stopScript -PathType Leaf) {
    try {
      & $stopScript -WorkspaceRoot $WorkspaceRoot -OwnerPid $ParentPid -OnOwnerExit | Out-Host
      if (-not [string]::IsNullOrWhiteSpace($SessionFile) -and (Test-Path -LiteralPath $SessionFile -PathType Leaf)) {
        try {
          Remove-Item -LiteralPath $SessionFile -Force -ErrorAction Stop
        } catch {
          Write-Session -State 'stop-failed'
          throw
        }
      }
    } catch {
      Write-Session -State 'stop-failed'
      throw
    }
  }
}
