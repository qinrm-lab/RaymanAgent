param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [string]$FlowFile = '.Rayman/winapp.flow.sample.json',
  [switch]$Require,
  [int]$DefaultTimeoutMs = 0,
  [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'winapp_core.ps1')

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$paths = Get-WinAppRuntimePaths -WorkspaceRoot $WorkspaceRoot
Ensure-Dir -Path $paths.tests_dir
Ensure-Dir -Path $paths.logs_dir
Ensure-Dir -Path $paths.screenshots_dir

$requireEffective = if ($PSBoundParameters.ContainsKey('Require')) { $Require.IsPresent } else { Get-EnvBoolCompat -Name 'RAYMAN_WINAPP_REQUIRE' -Default $false }
$flowPath = if ([System.IO.Path]::IsPathRooted($FlowFile)) { $FlowFile } else { Join-Path $WorkspaceRoot $FlowFile }
$detailLog = Join-Path $paths.logs_dir ('winapp.flow.{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

try {
  $flow = Read-WinAppFlowFile -FlowFilePath $flowPath
  $effectiveTimeoutMs = if ($DefaultTimeoutMs -gt 0) {
    $DefaultTimeoutMs
  } else {
    $flowTimeout = [int](Get-PropValue -Object $flow -Name 'default_timeout_ms' -Default 0)
    if ($flowTimeout -gt 0) {
      $flowTimeout
    } else {
      Get-EnvIntCompat -Name 'RAYMAN_WINAPP_DEFAULT_TIMEOUT_MS' -Default 15000 -Min 1000 -Max 600000
    }
  }

  $result = Invoke-WinAppFlow -WorkspaceRoot $WorkspaceRoot -Flow $flow -FlowFile $flowPath -DefaultTimeoutMs $effectiveTimeoutMs -Require:$requireEffective -DetailLog $detailLog -ResultPath $paths.last_result_json_path
  if ($Json) {
    $result | ConvertTo-Json -Depth 12
  } else {
    Write-Host ('[winapp-test] result: {0}' -f $paths.last_result_json_path) -ForegroundColor Cyan
    if ([bool]$result.success) {
      Write-Host '[winapp-test] flow passed.' -ForegroundColor Green
    } elseif ([bool]$result.degraded) {
      Write-Host ('[winapp-test] degraded: {0}' -f [string]$result.degraded_reason) -ForegroundColor Yellow
    }
  }
  if (-not [bool]$result.success -and $requireEffective) {
    exit 1
  }
} catch {
  $fallback = [ordered]@{
    schema = 'rayman.winapp.flow.result.v1'
    generated_at = Get-NowIsoTimestamp
    workspace_root = $WorkspaceRoot
    flow_file = $flowPath
    default_timeout_ms = $DefaultTimeoutMs
    success = $false
    degraded = $false
    degraded_reason = ''
    error_message = $_.Exception.Message
    detail_log = $detailLog
    launch = $null
    window = $null
    artifacts = [ordered]@{
      last_result_json = $paths.last_result_json_path
      readiness_json = $paths.readiness_json_path
      screenshots_dir = $paths.screenshots_dir
    }
    steps = @()
  }
  Write-WinAppLogLine -Path $detailLog -Level 'error' -Message $_.Exception.ToString()
  Save-WinAppResult -Path $paths.last_result_json_path -Result $fallback
  if ($Json) {
    ([pscustomobject]$fallback) | ConvertTo-Json -Depth 12
  } else {
    Write-Host ('[winapp-test] failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ('[winapp-test] result: {0}' -f $paths.last_result_json_path) -ForegroundColor Cyan
  }
  exit 1
}
