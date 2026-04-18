param(
  [Alias('NoMain')][switch]$RaymanEventHooksNoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
  . $commonPath
}

function Resolve-RaymanEventWorkspaceRoot {
  param([string]$WorkspaceRoot)

  if (Get-Command Resolve-RaymanWorkspaceRoot -ErrorAction SilentlyContinue) {
    return (Resolve-RaymanWorkspaceRoot -StartPath $WorkspaceRoot)
  }
  return (Resolve-Path -LiteralPath $WorkspaceRoot).Path
}

function Get-RaymanEventHooksConfig {
  param([string]$WorkspaceRoot)

  $root = Resolve-RaymanEventWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
  $configPath = Join-Path $root '.Rayman\config\event_hooks.json'
  $default = [pscustomobject]@{
    schema = 'rayman.event_hooks.v1'
    enabled = $true
    sinks = [pscustomobject]@{
      jsonl = [pscustomobject]@{
        enabled = $true
        directory = '.Rayman/runtime/events'
        rollover = 'daily'
      }
      webhook = [pscustomobject]@{
        enabled = $false
        url = ''
        timeout_seconds = 5
      }
    }
  }

  if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    return $default
  }

  try {
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ([string]$config.schema -ne 'rayman.event_hooks.v1') {
      return $default
    }
    return $config
  } catch {
    return $default
  }
}

function ConvertTo-RaymanEventJsonLine {
  param([object]$Value)

  return (($Value | ConvertTo-Json -Depth 16 -Compress) -replace "[`r`n]+", ' ')
}

function Write-RaymanEvent {
  [CmdletBinding()]
  param(
    [string]$WorkspaceRoot,
    [string]$EventType,
    [string]$Category = 'general',
    [object]$Payload = $null,
    [string]$RunId = ''
  )

  if ([string]::IsNullOrWhiteSpace($WorkspaceRoot) -or [string]::IsNullOrWhiteSpace($EventType)) {
    return [pscustomobject]@{
      written = $false
      reason = 'missing_workspace_or_event_type'
    }
  }

  $root = Resolve-RaymanEventWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
  $config = Get-RaymanEventHooksConfig -WorkspaceRoot $root
  if ($null -ne $config.PSObject.Properties['enabled'] -and -not [bool]$config.enabled) {
    return [pscustomobject]@{
      written = $false
      reason = 'disabled'
    }
  }

  $event = [ordered]@{
    schema = 'rayman.event.v1'
    event_type = [string]$EventType
    category = [string]$Category
    run_id = [string]$RunId
    workspace_root = $root
    generated_at = (Get-Date).ToString('o')
    payload = $Payload
  }

  $jsonlPath = ''
  $jsonlWritten = $false
  $webhookSent = $false
  $webhookError = ''

  $jsonlConfig = $null
  if ($null -ne $config.PSObject.Properties['sinks'] -and $null -ne $config.sinks.PSObject.Properties['jsonl']) {
    $jsonlConfig = $config.sinks.jsonl
  }
  $jsonlEnabled = $true
  if ($null -ne $jsonlConfig -and $null -ne $jsonlConfig.PSObject.Properties['enabled']) {
    $jsonlEnabled = [bool]$jsonlConfig.enabled
  }

  if ($jsonlEnabled) {
    $eventDirRel = if ($null -ne $jsonlConfig -and $null -ne $jsonlConfig.PSObject.Properties['directory'] -and -not [string]::IsNullOrWhiteSpace([string]$jsonlConfig.directory)) {
      [string]$jsonlConfig.directory
    } else {
      '.Rayman/runtime/events'
    }
    $eventDir = if ([System.IO.Path]::IsPathRooted($eventDirRel)) { $eventDirRel } else { Join-Path $root $eventDirRel }
    if (-not (Test-Path -LiteralPath $eventDir -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $eventDir | Out-Null
    }
    $jsonlPath = Join-Path $eventDir ("{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd'))
    Add-Content -LiteralPath $jsonlPath -Encoding UTF8 -Value (ConvertTo-RaymanEventJsonLine -Value $event)
    $jsonlWritten = $true
  }

  $webhookConfig = $null
  if ($null -ne $config.PSObject.Properties['sinks'] -and $null -ne $config.sinks.PSObject.Properties['webhook']) {
    $webhookConfig = $config.sinks.webhook
  }
  if ($null -ne $webhookConfig -and $null -ne $webhookConfig.PSObject.Properties['enabled'] -and [bool]$webhookConfig.enabled -and -not [string]::IsNullOrWhiteSpace([string]$webhookConfig.url)) {
    try {
      $timeout = 5
      if ($null -ne $webhookConfig.PSObject.Properties['timeout_seconds']) {
        $parsedTimeout = 0
        if ([int]::TryParse([string]$webhookConfig.timeout_seconds, [ref]$parsedTimeout) -and $parsedTimeout -gt 0) {
          $timeout = $parsedTimeout
        }
      }
      Invoke-RestMethod -Uri ([string]$webhookConfig.url) -Method Post -Body ($event | ConvertTo-Json -Depth 16) -ContentType 'application/json; charset=utf-8' -TimeoutSec $timeout | Out-Null
      $webhookSent = $true
    } catch {
      $webhookError = $_.Exception.Message
    }
  }

  return [pscustomobject]@{
    written = $jsonlWritten -or $webhookSent
    jsonl_written = $jsonlWritten
    jsonl_path = $jsonlPath
    webhook_sent = $webhookSent
    webhook_error = $webhookError
  }
}

if (-not $RaymanEventHooksNoMain) {
  Write-Output 'event_hooks.ps1 exposes Write-RaymanEvent; dot-source with -NoMain.'
}
