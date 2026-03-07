param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot "..\..\common.ps1"
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
  throw "common.ps1 not found: $commonPath"
}
. $commonPath

function Write-EnsureInfo([string]$Message) {
  if (-not $Quiet) { Write-Info $Message }
}

function Write-EnsureWarn([string]$Message) {
  if (-not $Quiet) { Write-Warn $Message }
}

if (-not (Get-RaymanEnvBool -Name 'RAYMAN_ALERT_WATCH_ENABLED' -Default $true)) {
  Write-EnsureInfo "[alert-watch] disabled by RAYMAN_ALERT_WATCH_ENABLED=0."
  exit 0
}

if (-not (Get-RaymanEnvBool -Name 'RAYMAN_ALERT_WATCH_ON_PROMPT_ENABLED' -Default $true)) {
  Write-EnsureInfo "[alert-watch] disabled on prompt flow by RAYMAN_ALERT_WATCH_ON_PROMPT_ENABLED=0."
  exit 0
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime'
if (-not (Test-Path -LiteralPath $runtimeDir)) {
  New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
}

$pidFile = Join-Path $runtimeDir 'attention_watch.pid'
$watchScript = Join-Path $WorkspaceRoot '.Rayman\scripts\alerts\attention_watch.ps1'
if (-not (Test-Path -LiteralPath $watchScript -PathType Leaf)) {
  Write-EnsureWarn ("[alert-watch] script not found: {0}" -f $watchScript)
  exit 0
}

if (Test-Path -LiteralPath $pidFile -PathType Leaf) {
  $pidVal = Get-RaymanPidFromFile -PidFilePath $pidFile
  if ($pidVal -gt 0 -and (Test-RaymanPidFileProcess -PidFilePath $pidFile -AllowedProcessNames @('powershell', 'pwsh'))) {
    Write-EnsureInfo ("[alert-watch] already running (PID={0})." -f $pidVal)
    exit 0
  }
  if ($pidVal -gt 0) {
    Write-EnsureWarn ("[alert-watch] stale pid file detected (PID={0}); restarting." -f $pidVal)
  }
  try {
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
  } catch {
    Write-RaymanDiag -Scope 'ensure-alert-watch' -Message ("remove stale pid failed: {0}" -f $_.Exception.ToString())
  }
}

try {
  $psHost = Resolve-RaymanPowerShellHost
  if ([string]::IsNullOrWhiteSpace($psHost)) {
    throw "cannot find PowerShell host (pwsh/powershell) in PATH"
  }

  $proc = Start-RaymanProcessHiddenCompat -FilePath $psHost -ArgumentList @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $watchScript,
    '-WorkspaceRoot',
    $WorkspaceRoot,
    '-PidFile',
    $pidFile
  )

  try {
    Set-Content -LiteralPath $pidFile -Value $proc.Id -NoNewline -Encoding ASCII
  } catch {
    Write-EnsureWarn ("[alert-watch] write pid file failed: {0}" -f $_.Exception.Message)
    Write-RaymanDiag -Scope 'ensure-alert-watch' -Message ("write pid file failed: {0}" -f $_.Exception.ToString())
  }

  Write-EnsureInfo ("[alert-watch] started (PID={0}, host={1})." -f $proc.Id, $psHost)
} catch {
  Write-EnsureWarn ("[alert-watch] start failed: {0}" -f $_.Exception.Message)
  Write-RaymanDiag -Scope 'ensure-alert-watch' -Message ("start failed: {0}" -f $_.Exception.ToString())
}
