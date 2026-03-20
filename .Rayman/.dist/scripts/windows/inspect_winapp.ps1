param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [string]$WindowTitleRegex = '.*',
  [string]$OutFile = '.Rayman/runtime/winapp-tests/control_tree.json',
  [int]$TimeoutSeconds = 20,
  [int]$MaxDepth = 6,
  [switch]$Require,
  [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'winapp_core.ps1')

function Resolve-WinAppInspectOutputPaths {
  param(
    [string]$WorkspaceRoot,
    [string]$OutFile
  )

  $paths = Get-WinAppRuntimePaths -WorkspaceRoot $WorkspaceRoot
  $defaultJsonPath = Join-Path $WorkspaceRoot '.Rayman/runtime/winapp-tests/control_tree.json'
  $defaultTextPath = Join-Path $WorkspaceRoot '.Rayman/runtime/winapp-tests/control_tree.txt'
  $candidate = if ([System.IO.Path]::IsPathRooted($OutFile)) { $OutFile } else { Join-Path $WorkspaceRoot $OutFile }
  $extension = [System.IO.Path]::GetExtension($candidate)
  if ([string]::IsNullOrWhiteSpace($extension) -or $extension.ToLowerInvariant() -eq '.json') {
    $jsonPath = $candidate
    $textPath = [System.IO.Path]::ChangeExtension($candidate, '.txt')
  } elseif ($extension.ToLowerInvariant() -eq '.txt') {
    $textPath = $candidate
    $jsonPath = [System.IO.Path]::ChangeExtension($candidate, '.json')
  } else {
    $jsonPath = ($candidate + '.json')
    $textPath = ($candidate + '.txt')
  }

  if ([string]::IsNullOrWhiteSpace($jsonPath)) { $jsonPath = if ([string]::IsNullOrWhiteSpace([string]$paths.control_tree_json_path)) { $defaultJsonPath } else { $paths.control_tree_json_path } }
  if ([string]::IsNullOrWhiteSpace($textPath)) { $textPath = if ([string]::IsNullOrWhiteSpace([string]$paths.control_tree_text_path)) { $defaultTextPath } else { $paths.control_tree_text_path } }

  return [pscustomobject]@{
    json_path = $jsonPath
    text_path = $textPath
  }
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$requireEffective = if ($PSBoundParameters.ContainsKey('Require')) { $Require.IsPresent } else { Get-EnvBoolCompat -Name 'RAYMAN_WINAPP_REQUIRE' -Default $false }
$runtimePaths = Get-WinAppRuntimePaths -WorkspaceRoot $WorkspaceRoot
$outputPaths = Resolve-WinAppInspectOutputPaths -WorkspaceRoot $WorkspaceRoot -OutFile $OutFile
$state = Get-WinAppReadinessState -WorkspaceRoot $WorkspaceRoot
Write-WinAppReadinessReport -WorkspaceRoot $WorkspaceRoot -State $state | Out-Null

if (-not [bool]$state.ready) {
  $payload = [pscustomobject]@{
    schema = 'rayman.winapp.inspect.v1'
    generated_at = Get-NowIsoTimestamp
    workspace_root = $WorkspaceRoot
    success = $false
    degraded = $true
    reason = [string]$state.reason
    detail = [string]$state.detail
    json_path = $outputPaths.json_path
    text_path = $outputPaths.text_path
  }
  if ($Json) {
    $payload | ConvertTo-Json -Depth 8
  } else {
    Write-Host ('[winapp-inspect] unavailable: {0} ({1})' -f [string]$state.reason, [string]$state.detail) -ForegroundColor Yellow
  }
  if ($requireEffective) { exit 1 }
  exit 0
}

Import-WinAppAssemblies
$window = Wait-WinAppWindow -WindowTitleRegex $WindowTitleRegex -TimeoutSeconds $TimeoutSeconds
if ($null -eq $window) {
  Write-Host ('[winapp-inspect] no window matched regex: {0}' -f $WindowTitleRegex) -ForegroundColor Yellow
  exit 1
}

$tree = Get-WinAppWindowControlTree -Window $window -MaxDepth $MaxDepth
Ensure-Dir -Path (Split-Path -Parent $outputPaths.json_path)
Ensure-Dir -Path (Split-Path -Parent $outputPaths.text_path)
($tree.tree | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $outputPaths.json_path -Encoding UTF8
Write-Utf8NoBom -Path $outputPaths.text_path -Content ((@($tree.text) -join [Environment]::NewLine) + [Environment]::NewLine)

$result = [pscustomobject]@{
  schema = 'rayman.winapp.inspect.v1'
  generated_at = Get-NowIsoTimestamp
  workspace_root = $WorkspaceRoot
  success = $true
  window = ConvertTo-WinAppElementInfo -Element $window
  json_path = $outputPaths.json_path
  text_path = $outputPaths.text_path
}

if ($Json) {
  $result | ConvertTo-Json -Depth 10
} else {
  Write-Host ('[winapp-inspect] json: {0}' -f $outputPaths.json_path) -ForegroundColor Cyan
  Write-Host ('[winapp-inspect] text: {0}' -f $outputPaths.text_path) -ForegroundColor Cyan
}
