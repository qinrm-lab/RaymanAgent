param(
  [string]$WorkspaceRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path,
  [string]$HostStartTime = '',
  [string]$RequestPath = '',
  [string]$ResponsePath = '',
  [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$savedRequestWorkerState = @{
  WorkspaceRoot = $WorkspaceRoot
  HostStartTime = $HostStartTime
  RequestPath = $RequestPath
  ResponsePath = $ResponsePath
  NoMain = [bool]$NoMain
}

. (Join-Path $PSScriptRoot 'worker_host.ps1') -NoMain

$WorkspaceRoot = [string]$savedRequestWorkerState.WorkspaceRoot
$HostStartTime = [string]$savedRequestWorkerState.HostStartTime
$RequestPath = [string]$savedRequestWorkerState.RequestPath
$ResponsePath = [string]$savedRequestWorkerState.ResponsePath
$NoMain = [bool]$savedRequestWorkerState.NoMain

function Read-RaymanWorkerRequestEnvelope {
  param([string]$Path)

  $doc = Read-RaymanWorkerJsonFile -Path $Path
  if ($null -eq $doc -or -not $doc.PSObject.Properties['request_data']) {
    throw ("worker request envelope is invalid: {0}" -f $Path)
  }

  $requestData = $doc.request_data
  $bodyBytes = @()
  if ($requestData.PSObject.Properties['body_bytes_base64'] -and -not [string]::IsNullOrWhiteSpace([string]$requestData.body_bytes_base64)) {
    $bodyBytes = [Convert]::FromBase64String([string]$requestData.body_bytes_base64)
  }

  return [pscustomobject]@{
    method = if ($requestData.PSObject.Properties['method']) { [string]$requestData.method } else { '' }
    path = if ($requestData.PSObject.Properties['path']) { [string]$requestData.path } else { '' }
    headers = if ($requestData.PSObject.Properties['headers']) { $requestData.headers } else { @{} }
    query_string = if ($requestData.PSObject.Properties['query_string']) { $requestData.query_string } else { @{} }
    body_json = if ($requestData.PSObject.Properties['body_json']) { $requestData.body_json } else { $null }
    body_bytes = @([byte[]]$bodyBytes)
  }
}

if (-not $NoMain) {
  $resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  try {
    $requestData = Read-RaymanWorkerRequestEnvelope -Path $RequestPath
    $payload = Invoke-RaymanWorkerRequestData -WorkspaceRoot $resolvedWorkspaceRoot -RequestData $requestData -HostStartTime $HostStartTime
    $statusCode = if ($payload.PSObject.Properties['error'] -and [string]$payload.error -eq 'not_found') { 404 } else { 200 }
    $response = [pscustomobject]@{
      schema = 'rayman.worker.request_response.v1'
      generated_at = (Get-Date).ToString('o')
      status_code = $statusCode
      payload = $payload
    }
    Write-RaymanWorkerJsonFile -Path $ResponsePath -Value $response
  } catch {
    $statusCode = if ($_.Exception -is [System.UnauthorizedAccessException]) { 401 } else { 500 }
    $response = [pscustomobject]@{
      schema = 'rayman.worker.request_response.v1'
      generated_at = (Get-Date).ToString('o')
      status_code = $statusCode
      payload = [pscustomobject]@{
        schema = 'rayman.worker.error.v1'
        generated_at = (Get-Date).ToString('o')
        error = [string]$_.Exception.Message
      }
    }
    Write-RaymanWorkerJsonFile -Path $ResponsePath -Value $response
    exit 1
  }
}
