param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Args
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
  exit 0
}

. $commonPath

try {
  if (@($Args).Count -eq 0) {
    exit 0
  }

  $payloadText = [string]$Args[@($Args).Count - 1]
  if ([string]::IsNullOrWhiteSpace($payloadText)) {
    exit 0
  }

  $payload = $payloadText | ConvertFrom-Json -ErrorAction Stop
  $eventType = [string](Get-RaymanMapValue -Map $payload -Key 'type' -Default '')
  if ($eventType -ne 'agent-turn-complete') {
    exit 0
  }

  $resolvedWorkspaceRoot = Resolve-RaymanLiteralPath -PathValue $WorkspaceRoot -AllowMissing
  if ([string]::IsNullOrWhiteSpace($resolvedWorkspaceRoot)) {
    $resolvedWorkspaceRoot = [string]$WorkspaceRoot
  }

  if (-not (Get-RaymanAttentionSoundEnabled -WorkspaceRoot $resolvedWorkspaceRoot -Kind 'done')) {
    exit 0
  }

  $soundPath = Get-RaymanAttentionSoundPath -WorkspaceRoot $resolvedWorkspaceRoot
  Invoke-RaymanAttentionSoundFile -Path $soundPath | Out-Null
} catch {
}

exit 0
