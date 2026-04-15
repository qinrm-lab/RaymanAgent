param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\.." | Select-Object -ExpandProperty Path)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path

function Info([string]$Message) { Write-Host ("[win-check] {0}" -f $Message) -ForegroundColor Cyan }
function Warn([string]$Message) { Write-Host ("[win-check] {0}" -f $Message) -ForegroundColor Yellow }

$commonPath = Join-Path $WorkspaceRoot '.Rayman\common.ps1'
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
  . $commonPath
}
$repeatErrorGuardPath = Join-Path $WorkspaceRoot '.Rayman\scripts\utils\repeat_error_guard.ps1'
if (Test-Path -LiteralPath $repeatErrorGuardPath -PathType Leaf) {
  . $repeatErrorGuardPath -NoMain
}
$codexCommonPath = Join-Path $WorkspaceRoot '.Rayman\scripts\codex\codex_common.ps1'
$codexCommonLoaded = $false
if (Test-Path -LiteralPath $codexCommonPath -PathType Leaf) {
  . $codexCommonPath
  $codexCommonLoaded = $true
}

& (Join-Path $WorkspaceRoot '.Rayman\win-preflight.ps1') -WorkspaceRoot $WorkspaceRoot

if (Get-Command Get-RaymanRepeatErrorGuardReport -ErrorAction SilentlyContinue) {
  $guardStatus = $null
  $guardStatusPath = Join-Path $WorkspaceRoot '.Rayman\runtime\codex.auth.status.json'
  if (
    $codexCommonLoaded -and
    (Get-Command Resolve-RaymanCodexContext -ErrorAction SilentlyContinue) -and
    (Get-Command Get-RaymanCodexLoginStatus -ErrorAction SilentlyContinue)
  ) {
    try {
      $guardContext = Resolve-RaymanCodexContext -WorkspaceRoot $WorkspaceRoot
      $guardAlias = [string](Get-RaymanMapValue -Map $guardContext -Key 'account_alias' -Default '')
      $guardStatus = Get-RaymanCodexLoginStatus -WorkspaceRoot $WorkspaceRoot -AccountAlias $guardAlias -SkipReportWrite -GuardStage 'rayman.check'
    } catch {
      Warn ("repeat error guard could not refresh Codex status: {0}" -f $_.Exception.Message)
    }
  }
  if ($null -eq $guardStatus -and (Test-Path -LiteralPath $guardStatusPath -PathType Leaf)) {
    try {
      $guardStatus = Get-Content -LiteralPath $guardStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
      Warn ("repeat error guard could not read runtime Codex status: {0}" -f $_.Exception.Message)
    }
  }

  try {
    $guardReport = Get-RaymanRepeatErrorGuardReport -WorkspaceRoot $WorkspaceRoot -CodexStatus $guardStatus -GuardStage 'rayman.check'
    Write-RaymanRepeatErrorGuardRuntimeReport -WorkspaceRoot $WorkspaceRoot -Report $guardReport | Out-Null
    Write-RaymanRepeatErrorGuardText -Report $guardReport -Prefix '[win-check]'
    if ([bool](Get-RaymanMapValue -Map (Get-RaymanMapValue -Map $guardReport -Key 'summary' -Default $null) -Key 'fail_fast' -Default $false)) {
      throw ("repeat error guard blocked check: {0}" -f [string](Get-RaymanMapValue -Map (Get-RaymanMapValue -Map $guardReport -Key 'summary' -Default $null) -Key 'top_signature' -Default 'unknown'))
    }
  } catch {
    throw
  }
} else {
  Warn ("repeat error guard script not found: {0}" -f $repeatErrorGuardPath)
}

$agentContract = Join-Path $WorkspaceRoot '.Rayman\scripts\agents\check_agent_contract.ps1'
if (Test-Path -LiteralPath $agentContract -PathType Leaf) {
  Info 'run agent contract check'
  & $agentContract -WorkspaceRoot $WorkspaceRoot
} else {
  Warn ("agent contract script not found: {0}" -f $agentContract)
}

$releaseGate = Join-Path $WorkspaceRoot '.Rayman\scripts\release\release_gate.ps1'
if (Test-Path -LiteralPath $releaseGate -PathType Leaf) {
  Info 'run standard release gate'
  & $releaseGate -WorkspaceRoot $WorkspaceRoot -Mode standard -AllowNoGit
} else {
  Warn ("release gate script not found: {0}" -f $releaseGate)
}

$bash = Get-Command bash -ErrorAction SilentlyContinue
if ($null -ne $bash) {
  Info 'run full release requirements validation'
  Push-Location $WorkspaceRoot
  try {
    & bash './.Rayman/scripts/release/validate_release_requirements.sh'
  } finally {
    Pop-Location
  }
} else {
  Warn 'bash not found; skip validate_release_requirements.sh'
}

Info 'check complete'
