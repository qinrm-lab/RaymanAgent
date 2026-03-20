param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$Require,
  [switch]$Json,
  [switch]$DisableCompatFallback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'winapp_core.ps1')

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$requireEffective = if ($PSBoundParameters.ContainsKey('Require')) { $Require.IsPresent } else { Get-EnvBoolCompat -Name 'RAYMAN_WINAPP_REQUIRE' -Default $false }
$canonicalReportPath = Join-Path $WorkspaceRoot '.Rayman/runtime/winapp.ready.windows.json'

function Test-WinAppCompatFallbackEnabled {
  if ([bool]$DisableCompatFallback) { return $false }
  if (-not (Test-WinAppHostIsWindows)) { return $false }
  try {
    return ([string]$PSVersionTable.PSEdition -eq 'Core')
  } catch {
    return $false
  }
}

function Invoke-WinAppCompatFallbackState {
  param(
    [string]$WorkspaceRoot
  )

  if (-not (Test-WinAppCompatFallbackEnabled)) { return $null }
  $winPs = Get-Command 'powershell.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $winPs) { return $null }

  try {
    $jsonText = & $winPs.Source -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -WorkspaceRoot $WorkspaceRoot -DisableCompatFallback -Json 2>$null
    if ([string]::IsNullOrWhiteSpace([string]$jsonText)) { return $null }
    return ($jsonText | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}

$state = Get-WinAppReadinessState -WorkspaceRoot $WorkspaceRoot
$initialState = $state
if ([string]$state.reason -eq 'uia_unavailable') {
  $fallbackState = Invoke-WinAppCompatFallbackState -WorkspaceRoot $WorkspaceRoot
  if ($null -ne $fallbackState -and [string]$fallbackState.schema -eq 'rayman.winapp.ready.v1') {
    $state = $fallbackState
    if ([bool]$state.ready) {
      $originalError = [string]$initialState.error_message
      $state.error_message = if ([string]::IsNullOrWhiteSpace($originalError)) {
        'validated via powershell.exe compatibility fallback'
      } else {
        ('pwsh: {0} | fallback: powershell.exe' -f $originalError)
      }
    }
  }
}

$reportPath = Write-WinAppReadinessReport -WorkspaceRoot $WorkspaceRoot -State $state
$displayReportPath = if ([string]::IsNullOrWhiteSpace([string]$reportPath)) { $canonicalReportPath } else { $reportPath }

if ($Json) {
  $state | ConvertTo-Json -Depth 8
} else {
  Write-Host ('[winapp] report: {0}' -f $displayReportPath) -ForegroundColor Cyan
  if ([bool]$state.ready) {
    Write-Host '[winapp] Windows desktop automation is ready.' -ForegroundColor Green
  } else {
    Write-Host ('[winapp] not ready: {0} ({1})' -f [string]$state.reason, [string]$state.detail) -ForegroundColor Yellow
    Write-Host '[winapp] action: run from a Windows host with an interactive desktop session, then retry `rayman ensure-winapp` or `rayman winapp-test`.' -ForegroundColor Yellow
  }
}

if (-not [bool]$state.ready -and $requireEffective) {
  exit 1
}
