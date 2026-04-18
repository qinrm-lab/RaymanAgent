param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$NoMain,
  [Parameter(Position=0)][string]$Action = 'status',
  [Parameter(Position=1, ValueFromRemainingArguments=$true)][string[]]$ActionArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$manageAccountsIsMain = (-not $NoMain)

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
  throw "common.ps1 not found: $commonPath"
}
. $commonPath

$sessionCommonPath = Join-Path $PSScriptRoot '..\state\session_common.ps1'
if (Test-Path -LiteralPath $sessionCommonPath -PathType Leaf) {
  . $sessionCommonPath
}

if ($null -eq $ActionArgs) {
  $ActionArgs = @()
} else {
  $ActionArgs = @($ActionArgs)
}

function Write-CodexInfo([string]$Message) {
  Write-Host ("[rayman codex] {0}" -f $Message) -ForegroundColor Cyan
}

function Write-CodexWarn([string]$Message) {
  Write-Host ("[rayman codex] {0}" -f $Message) -ForegroundColor Yellow
}

function Exit-CodexError([string]$Message, [int]$ExitCode = 2) {
  Write-Host ("[rayman codex] {0}" -f $Message) -ForegroundColor Red
  exit $ExitCode
}

function Format-CodexVersionText {
  param(
    [string]$Version
  )

  if ([string]::IsNullOrWhiteSpace($Version)) {
    return '(unknown)'
  }
  return [string]$Version
}

function Write-VsCodeReloadHint {
  if ((Test-Path "Env:\VSCODE_PID") -or ($env:TERM_PROGRAM -eq 'vscode') -or ($env:VSCODE_INJECTION -eq '1')) {
    $esc = [char]27
    $bel = [char]7
    $hyperlink = "${esc}]8;;command:workbench.action.reloadWindow${bel}[🔄 点击此处快速重载窗口]${esc}]8;;${bel}"
    Write-Host ""
    Write-Host -ForegroundColor Green "✅ 账号授权状态已更新。"
    Write-Host -ForegroundColor Cyan "👉 为了使新授权在当前 VS Code 扩展（Codex/Copilot）中生效，请 $hyperlink，或按 Ctrl+Shift+P 执行 'Reload Window'。"
    Write-Host ""
  }
}

function Write-CodexCliUpdateMessages {
  param(
    [object]$Result,
    [switch]$ExplicitUpgrade
  )

  if ($null -eq $Result) {
    return
  }

  $beforeText = Format-CodexVersionText -Version ([string]$Result.version_before)
  $afterText = Format-CodexVersionText -Version ([string]$Result.version_after)
  $latestText = if ([string]::IsNullOrWhiteSpace([string]$Result.latest_version)) { '' } else { [string]$Result.latest_version }

  if ([bool]$Result.updated) {
    $message = "Codex CLI auto-updated: $beforeText -> $afterText"
    if (-not [string]::IsNullOrWhiteSpace($latestText)) {
      $message += " (registry latest=$latestText)"
    }
    if ($ExplicitUpgrade) {
      Write-CodexInfo $message
    } else {
      Write-CodexWarn $message
    }
    return
  }

  switch ([string]$Result.reason) {
    'already_latest' {
      Write-CodexInfo ("Codex CLI is already up to date: {0}" -f $afterText)
      return
    }
    'already_latest_explicit' {
      Write-CodexInfo ("Codex CLI is already up to date: {0}" -f $afterText)
      return
    }
    'latest_check_failed_nonblocking' {
      Write-CodexWarn ('Unable to query npm registry for the latest Codex CLI version; continuing with the current compatible version.')
      return
    }
    'latest_policy_skipped_non_npm_managed' {
      Write-CodexWarn ([string]$Result.output)
      return
    }
    'current_version_unknown_nonblocking' {
      Write-CodexWarn ('Unable to determine the current Codex CLI version; continuing with the current compatible install.')
      return
    }
    'latest_update_failed_nonblocking' {
      Write-CodexWarn ('Latest-version auto-update failed; continuing with the current compatible Codex CLI.')
      return
    }
    'compatibility_auto_updated' {
      $message = "Codex CLI auto-updated for compatibility: $beforeText -> $afterText"
      if (-not [string]::IsNullOrWhiteSpace($latestText)) {
        $message += " (registry latest=$latestText)"
      }
      if ($ExplicitUpgrade) {
        Write-CodexInfo $message
      } else {
        Write-CodexWarn $message
      }
      return
    }
  }

  if ($ExplicitUpgrade -and -not [bool]$Result.success -and -not [string]::IsNullOrWhiteSpace([string]$Result.output)) {
    Write-CodexWarn ([string]$Result.output)
  }
}

function Ensure-CodexCliReady {
  param(
    [string]$WorkspaceRoot,
    [string]$AccountAlias = '',
    [switch]$AsJson,
    [switch]$ForceUpgrade,
    [string]$AutoUpdatePolicyOverride = ''
  )

  $result = Ensure-RaymanCodexCliUpToDate -WorkspaceRoot $WorkspaceRoot -AccountAlias $AccountAlias -ForceRefresh -ForceUpgrade:$ForceUpgrade -PolicyOverride $AutoUpdatePolicyOverride
  if (-not $AsJson) {
    Write-CodexCliUpdateMessages -Result $result -ExplicitUpgrade:$ForceUpgrade
  }

  if ($ForceUpgrade) {
    if (-not [bool]$result.success) {
      $detail = if ([string]::IsNullOrWhiteSpace([string]$result.output)) { [string]$result.reason } else { [string]$result.output }
      Exit-CodexError ("Codex CLI upgrade failed ({0})." -f $detail) 3
    }
    return $result
  }

  if (-not [bool]$result.compatible) {
    $detail = if ([string]::IsNullOrWhiteSpace([string]$result.output)) { [string]$result.reason } else { [string]$result.output }
    $aliasText = if ([string]::IsNullOrWhiteSpace($AccountAlias)) { 'current context' } else { ("alias '{0}'" -f $AccountAlias) }
    Exit-CodexError ("Codex CLI is not compatible for {0} ({1})." -f $aliasText, $detail) 3
  }

  return $result
}

function Test-HasToken {
  param(
    [string[]]$Tokens,
    [string[]]$Names
  )

  $allTokens = @($Tokens)
  foreach ($token in $allTokens) {
    $text = [string]$token
    foreach ($name in @($Names)) {
      if ($text -eq ('--' + $name) -or $text -eq ('-' + $name)) {
        return $true
      }
    }
  }
  return $false
}

function Get-OptionValue {
  param(
    [string[]]$Tokens,
    [string[]]$Names,
    [string]$Default = ''
  )

  $allTokens = @($Tokens)
  for ($i = 0; $i -lt $allTokens.Count; $i++) {
    $token = [string]$allTokens[$i]
    foreach ($name in @($Names)) {
      if ($token -eq ('--' + $name) -or $token -eq ('-' + $name)) {
        if ($i + 1 -lt $allTokens.Count) {
          return [string]$allTokens[$i + 1]
        }
      }
      if ($token.StartsWith('--' + $name + '=', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $token.Substring($name.Length + 3)
      }
      if ($token.StartsWith('-' + $name + '=', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $token.Substring($name.Length + 2)
      }
    }
  }
  return $Default
}

function Get-PassthroughArguments {
  param(
    [string[]]$Tokens
  )

  $allTokens = @($Tokens)
  $separatorIndex = [array]::IndexOf($allTokens, '--')
  if ($separatorIndex -ge 0) {
    if ($separatorIndex + 1 -ge $allTokens.Count) {
      return @()
    }
    return @($allTokens[($separatorIndex + 1)..($allTokens.Count - 1)])
  }
  return $allTokens
}

function Test-InteractiveInputAvailable {
  try {
    return (-not [Console]::IsInputRedirected)
  } catch {
    return $true
  }
}

function Convert-ArgumentLineToTokens {
  param(
    [string]$Text
  )

  if ([string]::IsNullOrWhiteSpace($Text)) {
    return @()
  }

  return @($Text.Trim() -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Format-StatusText([object]$Status) {
  $text = [string](Get-RaymanMapValue -Map $Status -Key 'status' -Default '')
  if ([string]::IsNullOrWhiteSpace($text)) {
    return 'unknown'
  }
  return $text
}

function Format-CodexAuthModeLastText {
  param(
    [AllowEmptyString()][string]$Mode
  )

  $normalized = Normalize-RaymanCodexAuthModeLast -Mode $Mode
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    return '(none)'
  }
  return $normalized
}

function Format-CodexDetectedAuthText {
  param(
    [object]$Status
  )

  $detected = Normalize-RaymanCodexDetectedAuthMode -Mode ([string](Get-RaymanMapValue -Map $Status -Key 'auth_mode_detected' -Default 'unknown'))
  $source = [string](Get-RaymanMapValue -Map $Status -Key 'auth_source' -Default 'none')
  if ($detected -eq 'unknown') {
    return 'unknown'
  }
  if ([string]::IsNullOrWhiteSpace($source) -or $source -eq 'none') {
    return $detected
  }
  return ('{0}/{1}' -f $detected, $source)
}

function Format-CodexNativeSessionText {
  param(
    [object]$Session
  )

  if ($null -eq $Session -or -not [bool](Get-RaymanMapValue -Map $Session -Key 'available' -Default $false)) {
    return '(none)'
  }

  $title = [string](Get-RaymanMapValue -Map $Session -Key 'thread_name' -Default '')
  if ([string]::IsNullOrWhiteSpace($title)) {
    $title = [string](Get-RaymanMapValue -Map $Session -Key 'id' -Default '(unnamed)')
  }
  $updatedAt = [string](Get-RaymanMapValue -Map $Session -Key 'updated_at' -Default '')
  if ([string]::IsNullOrWhiteSpace($updatedAt)) {
    return $title
  }
  return ('{0} @ {1}' -f $title, $updatedAt)
}

function Format-CodexSavedStateSummaryText {
  param(
    [object]$Summary
  )

  if ($null -eq $Summary) {
    return 'saved=0'
  }

  $total = [int](Get-RaymanMapValue -Map $Summary -Key 'total_count' -Default 0)
  $manualCount = [int](Get-RaymanMapValue -Map $Summary -Key 'manual_count' -Default 0)
  $autoTempCount = [int](Get-RaymanMapValue -Map $Summary -Key 'auto_temp_count' -Default 0)
  if ($total -le 0) {
    return 'saved=0'
  }

  $latest = Get-RaymanMapValue -Map $Summary -Key 'latest' -Default $null
  $latestName = if ($null -ne $latest) { [string](Get-RaymanMapValue -Map $latest -Key 'name' -Default '') } else { '' }
  if ([string]::IsNullOrWhiteSpace($latestName) -and $null -ne $latest) {
    $latestName = [string](Get-RaymanMapValue -Map $latest -Key 'slug' -Default '')
  }
  if ([string]::IsNullOrWhiteSpace($latestName)) {
    return ('saved={0} manual={1} auto={2}' -f $total, $manualCount, $autoTempCount)
  }
  return ('saved={0} manual={1} auto={2} latest={3}' -f $total, $manualCount, $autoTempCount, $latestName)
}

function Format-CodexYunyiSummaryText {
  param(
    [object]$Status
  )

  $baseUrl = [string](Get-RaymanMapValue -Map $Status -Key 'last_yunyi_base_url' -Default '')
  $configReady = [bool](Get-RaymanMapValue -Map $Status -Key 'last_yunyi_config_ready' -Default $false)
  $reuseReason = [string](Get-RaymanMapValue -Map $Status -Key 'last_yunyi_reuse_reason' -Default '')
  if ([string]::IsNullOrWhiteSpace($baseUrl) -and -not $configReady) {
    return 'yunyi=none'
  }

  $statusText = if ($configReady) { 'ready' } else { 'saved' }
  if ([string]::IsNullOrWhiteSpace($baseUrl)) {
    return ('yunyi={0}' -f $statusText)
  }
  if ([string]::IsNullOrWhiteSpace($reuseReason)) {
    return ('yunyi={0} {1}' -f $statusText, $baseUrl)
  }
  return ('yunyi={0} {1} source={2}' -f $statusText, $baseUrl, $reuseReason)
}

function Write-CodexRepeatErrorSummary {
  param([object]$Status)

  $signature = [string](Get-RaymanMapValue -Map $Status -Key 'known_error_signature' -Default '')
  if ([string]::IsNullOrWhiteSpace($signature)) {
    return
  }

  $severity = [string](Get-RaymanMapValue -Map $Status -Key 'known_error_severity' -Default 'warn')
  $blocked = [bool](Get-RaymanMapValue -Map $Status -Key 'repeat_prevented' -Default $false)
  $guardStage = [string](Get-RaymanMapValue -Map $Status -Key 'guard_stage' -Default '')
  $message = [string](Get-RaymanMapValue -Map $Status -Key 'known_error_message' -Default '')
  $repair = [string](Get-RaymanMapValue -Map $Status -Key 'repair_command' -Default '')

  Write-CodexWarn ("repeat-error signature={0} severity={1} blocked={2} stage={3}" -f $signature, $severity, [string]$blocked.ToString().ToLowerInvariant(), $guardStage)
  if (-not [string]::IsNullOrWhiteSpace($message)) {
    Write-CodexWarn ("repeat-error detail: {0}" -f $message)
  }
  if (-not [string]::IsNullOrWhiteSpace($repair)) {
    Write-CodexWarn ("repeat-error repair: {0}" -f $repair)
  }
}

function Invoke-CodexRepeatErrorGuardExitIfNeeded {
  param(
    [object]$Status,
    [string]$Stage,
    [switch]$AsJson
  )

  if ($AsJson) {
    return
  }

  $signature = [string](Get-RaymanMapValue -Map $Status -Key 'known_error_signature' -Default '')
  if ([string]::IsNullOrWhiteSpace($signature)) {
    return
  }

  if (-not [bool](Get-RaymanMapValue -Map $Status -Key 'repeat_prevented' -Default $false)) {
    return
  }

  $repair = [string](Get-RaymanMapValue -Map $Status -Key 'repair_command' -Default '')
  $message = [string](Get-RaymanMapValue -Map $Status -Key 'known_error_message' -Default '')
  $suffix = if ([string]::IsNullOrWhiteSpace($repair)) { '' } else { (" Run `{0}`." -f $repair) }
  $detail = if ([string]::IsNullOrWhiteSpace($message)) { $signature } else { ("{0}: {1}" -f $signature, $message) }
  Exit-CodexError ("repeat error guard blocked {0} ({1}).{2}" -f $Stage, $detail, $suffix) 6
}

function Convert-StatusToRow {
  param(
    [object]$Account,
    [object]$Status
  )

  return [pscustomobject]@{
    alias = [string](Get-RaymanMapValue -Map $Account -Key 'alias' -Default '')
    codex_home = [string](Get-RaymanMapValue -Map $Account -Key 'codex_home' -Default '')
    effective_codex_home = [string](Get-RaymanMapValue -Map $Status -Key 'codex_home' -Default (Get-RaymanMapValue -Map $Account -Key 'codex_home' -Default ''))
    desktop_codex_home = [string](Get-RaymanMapValue -Map $Status -Key 'desktop_codex_home' -Default '')
    auth_scope = [string](Get-RaymanMapValue -Map $Status -Key 'auth_scope' -Default (Get-RaymanMapValue -Map $Account -Key 'auth_scope' -Default ''))
    default_profile = [string](Get-RaymanMapValue -Map $Account -Key 'default_profile' -Default '')
    authenticated = [bool](Get-RaymanMapValue -Map $Status -Key 'authenticated' -Default $false)
    status = [string](Get-RaymanMapValue -Map $Status -Key 'status' -Default 'unknown')
    last_checked_at = [string](Get-RaymanMapValue -Map $Status -Key 'generated_at' -Default '')
    known_error_signature = [string](Get-RaymanMapValue -Map $Status -Key 'known_error_signature' -Default '')
    known_error_severity = [string](Get-RaymanMapValue -Map $Status -Key 'known_error_severity' -Default '')
    known_error_message = [string](Get-RaymanMapValue -Map $Status -Key 'known_error_message' -Default '')
    guard_stage = [string](Get-RaymanMapValue -Map $Status -Key 'guard_stage' -Default '')
    repeat_prevented = [bool](Get-RaymanMapValue -Map $Status -Key 'repeat_prevented' -Default $false)
    auth_mode_last = Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $Status -Key 'auth_mode_last' -Default (Get-RaymanMapValue -Map $Account -Key 'auth_mode_last' -Default '')))
    auth_mode_detected = Normalize-RaymanCodexDetectedAuthMode -Mode ([string](Get-RaymanMapValue -Map $Status -Key 'auth_mode_detected' -Default 'unknown'))
    auth_source = [string](Get-RaymanMapValue -Map $Status -Key 'auth_source' -Default 'none')
    last_login_mode = [string](Get-RaymanMapValue -Map $Status -Key 'last_login_mode' -Default (Get-RaymanMapValue -Map $Account -Key 'last_login_mode' -Default ''))
    last_login_strategy = [string](Get-RaymanMapValue -Map $Status -Key 'last_login_strategy' -Default (Get-RaymanMapValue -Map $Account -Key 'last_login_strategy' -Default ''))
    last_login_prompt_classification = [string](Get-RaymanMapValue -Map $Status -Key 'last_login_prompt_classification' -Default (Get-RaymanMapValue -Map $Account -Key 'last_login_prompt_classification' -Default ''))
    last_login_started_at = [string](Get-RaymanMapValue -Map $Status -Key 'last_login_started_at' -Default (Get-RaymanMapValue -Map $Account -Key 'last_login_started_at' -Default ''))
    last_login_finished_at = [string](Get-RaymanMapValue -Map $Status -Key 'last_login_finished_at' -Default (Get-RaymanMapValue -Map $Account -Key 'last_login_finished_at' -Default ''))
    last_login_success = [bool](Get-RaymanMapValue -Map $Status -Key 'last_login_success' -Default (Get-RaymanMapValue -Map $Account -Key 'last_login_success' -Default $false))
    last_yunyi_base_url = [string](Get-RaymanMapValue -Map $Status -Key 'last_yunyi_base_url' -Default (Get-RaymanMapValue -Map $Account -Key 'last_yunyi_base_url' -Default ''))
    last_yunyi_success_at = [string](Get-RaymanMapValue -Map $Status -Key 'last_yunyi_success_at' -Default (Get-RaymanMapValue -Map $Account -Key 'last_yunyi_success_at' -Default ''))
    last_yunyi_config_ready = [bool](Get-RaymanMapValue -Map $Status -Key 'last_yunyi_config_ready' -Default (Get-RaymanMapValue -Map $Account -Key 'last_yunyi_config_ready' -Default $false))
    last_yunyi_reuse_reason = [string](Get-RaymanMapValue -Map $Status -Key 'last_yunyi_reuse_reason' -Default (Get-RaymanMapValue -Map $Account -Key 'last_yunyi_reuse_reason' -Default ''))
    last_yunyi_base_url_source = [string](Get-RaymanMapValue -Map $Status -Key 'last_yunyi_base_url_source' -Default (Get-RaymanMapValue -Map $Account -Key 'last_yunyi_base_url_source' -Default ''))
    login_smoke_mode = [string](Get-RaymanMapValue -Map $Status -Key 'login_smoke_mode' -Default '')
    login_smoke_next_allowed_at = [string](Get-RaymanMapValue -Map $Status -Key 'login_smoke_next_allowed_at' -Default '')
    login_smoke_throttled = [bool](Get-RaymanMapValue -Map $Status -Key 'login_smoke_throttled' -Default $false)
    desktop_auth_present = [bool](Get-RaymanMapValue -Map $Status -Key 'desktop_auth_present' -Default $false)
    desktop_global_cloud_access = [string](Get-RaymanMapValue -Map $Status -Key 'desktop_global_cloud_access' -Default '')
    desktop_target_mode = [string](Get-RaymanMapValue -Map $Status -Key 'desktop_target_mode' -Default (Get-RaymanMapValue -Map $Account -Key 'desktop_target_mode' -Default ''))
    desktop_saved_token_reused = [bool](Get-RaymanMapValue -Map $Status -Key 'desktop_saved_token_reused' -Default (Get-RaymanMapValue -Map $Account -Key 'desktop_saved_token_reused' -Default $false))
    desktop_saved_token_source = [string](Get-RaymanMapValue -Map $Status -Key 'desktop_saved_token_source' -Default (Get-RaymanMapValue -Map $Account -Key 'desktop_saved_token_source' -Default ''))
    desktop_status_command = [string](Get-RaymanMapValue -Map $Status -Key 'desktop_status_command' -Default '')
    desktop_status_quota_visible = [bool](Get-RaymanMapValue -Map $Status -Key 'desktop_status_quota_visible' -Default (Get-RaymanMapValue -Map $Account -Key 'desktop_status_quota_visible' -Default $false))
    desktop_status_reason = [string](Get-RaymanMapValue -Map $Status -Key 'desktop_status_reason' -Default (Get-RaymanMapValue -Map $Account -Key 'desktop_status_reason' -Default ''))
    desktop_config_conflict = [string](Get-RaymanMapValue -Map $Status -Key 'desktop_config_conflict' -Default (Get-RaymanMapValue -Map $Account -Key 'desktop_config_conflict' -Default ''))
    desktop_unsynced_reason = [string](Get-RaymanMapValue -Map $Status -Key 'desktop_unsynced_reason' -Default (Get-RaymanMapValue -Map $Account -Key 'desktop_unsynced_reason' -Default ''))
    latest_native_session = Get-RaymanMapValue -Map $Status -Key 'latest_native_session' -Default (Get-RaymanMapValue -Map $Account -Key 'latest_native_session' -Default $null)
    saved_state_summary = Get-RaymanMapValue -Map $Status -Key 'saved_state_summary' -Default $null
    recent_saved_states = @((Get-RaymanMapValue -Map $Status -Key 'recent_saved_states' -Default @()) | ForEach-Object { $_ })
  }
}

function Get-RaymanCodexAccountRows {
  param(
    [string]$TargetWorkspaceRoot = ''
  )

  $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $TargetWorkspaceRoot
  $registry = Get-RaymanCodexRegistry
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($key in @((ConvertTo-RaymanStringKeyMap -InputObject $registry.accounts).Keys | Sort-Object)) {
    $account = Get-RaymanMapValue -Map $registry.accounts -Key $key -Default $null
    if ($null -eq $account) { continue }
    $alias = [string](Get-RaymanMapValue -Map $account -Key 'alias' -Default $key)
    $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $resolvedWorkspace -AccountAlias $alias -SkipReportWrite -GuardStage 'codex.status'
    $rows.Add((Convert-StatusToRow -Account $account -Status $status)) | Out-Null
  }
  return @($rows.ToArray())
}

function Get-RaymanCodexAliasRow {
  param(
    [string]$Alias,
    [string]$TargetWorkspaceRoot = ''
  )

  $normalizedAlias = Normalize-RaymanCodexAlias -Alias $Alias
  if ([string]::IsNullOrWhiteSpace($normalizedAlias)) {
    return $null
  }

  foreach ($row in @(Get-RaymanCodexAccountRows -TargetWorkspaceRoot $TargetWorkspaceRoot)) {
    if ([string]$row.alias -ieq $normalizedAlias) {
      return $row
    }
  }
  return $null
}

function Get-PreferredYunyiAliasForWorkspace {
  param(
    [string]$TargetWorkspaceRoot = ''
  )

  $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $TargetWorkspaceRoot
  $reportPath = Get-RaymanCodexLoginReportPath -WorkspaceRoot $resolvedWorkspace
  if (-not [string]::IsNullOrWhiteSpace([string]$reportPath) -and (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
    try {
      $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      $reportMode = Resolve-RaymanCodexLoginMode -Mode ([string](Get-RaymanMapValue -Map $report -Key 'mode' -Default ''))
      $reportAlias = Normalize-RaymanCodexAlias -Alias ([string](Get-RaymanMapValue -Map $report -Key 'alias' -Default ''))
      if ($reportMode -eq 'yunyi' -and -not [string]::IsNullOrWhiteSpace([string]$reportAlias) -and [bool](Get-RaymanMapValue -Map $report -Key 'success' -Default $false)) {
        return $reportAlias
      }
    } catch {
      # ignore malformed last-login reports
    }
  }

  $binding = Get-RaymanCodexWorkspaceBinding -WorkspaceRoot $resolvedWorkspace
  $bindingAlias = Normalize-RaymanCodexAlias -Alias ([string]$binding.account_alias)
  if (-not [string]::IsNullOrWhiteSpace([string]$bindingAlias)) {
    $bindingRecord = Get-RaymanCodexAccountRecord -Alias $bindingAlias
    if ($null -ne $bindingRecord -and -not [string]::IsNullOrWhiteSpace([string](Get-RaymanMapValue -Map $bindingRecord -Key 'last_yunyi_success_at' -Default ''))) {
      return $bindingAlias
    }
  }

  $candidates = @(
    Get-RaymanCodexAccountRows -TargetWorkspaceRoot $resolvedWorkspace |
    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.last_yunyi_success_at) } |
    Sort-Object @{ Expression = { [string]$_.last_yunyi_success_at }; Descending = $true }, @{ Expression = { [string]$_.alias } }
  )
  if ($candidates.Count -gt 0) {
    return [string]$candidates[0].alias
  }

  return ''
}

function Get-LoginAliasRows {
  param(
    [string]$TargetWorkspaceRoot,
    [string]$PreferredMode = '',
    [switch]$FilterByMode
  )

  $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $TargetWorkspaceRoot
  $binding = if ([string]::IsNullOrWhiteSpace($resolvedWorkspace)) {
    [pscustomobject]@{ account_alias = ''; profile = '' }
  } else {
    Get-RaymanCodexWorkspaceBinding -WorkspaceRoot $resolvedWorkspace
  }
  $currentAlias = Normalize-RaymanCodexAlias -Alias ([string]$binding.account_alias)
  $normalizedPreferredMode = Resolve-RaymanCodexLoginMode -Mode $PreferredMode
  $preferredYunyiAlias = if ($normalizedPreferredMode -eq 'yunyi') { Get-PreferredYunyiAliasForWorkspace -TargetWorkspaceRoot $resolvedWorkspace } else { '' }
  $rows = New-Object System.Collections.Generic.List[object]
  $rowIndexByKey = @{}

  function local:Add-LoginAliasRow {
    param(
      [string]$Alias,
      [string]$Kind,
      [string]$Tag,
      [bool]$Recommended = $false
    )

    $normalizedAlias = if ($Kind -eq 'custom') { '' } else { Normalize-RaymanCodexAlias -Alias $Alias }
    $key = if ($Kind -eq 'custom') { '__custom__' } else { Get-RaymanCodexAliasKey -Alias $normalizedAlias }
    if ([string]::IsNullOrWhiteSpace($key)) {
      return
    }

    # Skip aliases that don't support the filter mode
    if ($FilterByMode -and -not [string]::IsNullOrWhiteSpace([string]$normalizedPreferredMode) -and $Kind -eq 'alias') {
      switch ($normalizedPreferredMode) {
        'yunyi' {
          # Yunyi mode can reuse either a ready local config or the last successful Yunyi alias metadata.
          $yunyiSummary = Get-RaymanCodexYunyiConfigSummary -Alias $normalizedAlias
          $record = Get-RaymanCodexAccountRecord -Alias $normalizedAlias
          $hasRecentYunyiSuccess = (
            $null -ne $record -and
            -not [string]::IsNullOrWhiteSpace([string](Get-RaymanMapValue -Map $record -Key 'last_yunyi_success_at' -Default ''))
          )
          if (-not [bool]$yunyiSummary.config_ready -and -not $hasRecentYunyiSuccess) {
            return
          }
        }
        'web' {
          # Web mode supports all aliases
        }
        'device' {
          # Device auth supports all aliases
        }
        'api' {
          # API mode supports all aliases that have been used
        }
      }
    }

    if ($rowIndexByKey.ContainsKey($key)) {
      $existing = $rows[[int]$rowIndexByKey[$key]]
      $tags = @([string[]](Get-RaymanMapValue -Map $existing -Key 'tags' -Default @()))
      if (-not [string]::IsNullOrWhiteSpace($Tag) -and ($tags -notcontains $Tag)) {
        $tags += $Tag
      }
      $existing.tags = @($tags)
      if ($Recommended) {
        $existing.recommended = $true
      }
      return
    }

    $rowIndexByKey[$key] = $rows.Count
    $rows.Add([pscustomobject]@{
        kind = $Kind
        alias = $normalizedAlias
        key = $key
        label = if ($Kind -eq 'custom') { 'custom' } else { $normalizedAlias }
        tags = if ([string]::IsNullOrWhiteSpace($Tag)) { @() } else { @($Tag) }
        recommended = $Recommended
      }) | Out-Null
  }

  if (-not [string]::IsNullOrWhiteSpace([string]$preferredYunyiAlias)) {
    Add-LoginAliasRow -Alias $preferredYunyiAlias -Kind 'alias' -Tag '最近 Yunyi 成功' -Recommended:$true
  }
  if (-not [string]::IsNullOrWhiteSpace($currentAlias)) {
    Add-LoginAliasRow -Alias $currentAlias -Kind 'alias' -Tag '当前绑定'
  }
  Add-LoginAliasRow -Alias 'main' -Kind 'alias' -Tag '主账号推荐' -Recommended:([string]$normalizedPreferredMode -ne 'yunyi')
  foreach ($row in @(Get-RaymanCodexAccountRows -TargetWorkspaceRoot $resolvedWorkspace)) {
    Add-LoginAliasRow -Alias ([string]$row.alias) -Kind 'alias' -Tag '已有 alias'
  }
  Add-LoginAliasRow -Alias 'gpt-alt' -Kind 'alias' -Tag '推荐第二账号' -Recommended:([string]$normalizedPreferredMode -ne 'yunyi')
  Add-LoginAliasRow -Alias '' -Kind 'custom' -Tag '手工输入'

  return @($rows.ToArray())
}

function Resolve-RaymanCodexLoginMode {
  param(
    [AllowEmptyString()][string]$Mode
  )

  if ([string]::IsNullOrWhiteSpace($Mode)) {
    return ''
  }

  switch ($Mode.Trim().ToLowerInvariant()) {
    { $_ -in @('web', 'device', 'api', 'yunyi') } { return $_ }
    default { Exit-CodexError ("Unknown codex login mode: {0}. Expected web, device, api, or yunyi." -f $Mode) }
  }
}

function Get-CodexLoginModeRows {
  param(
    [string]$PreferredMode = 'web'
  )

  $normalizedPreferredMode = Resolve-RaymanCodexLoginMode -Mode $PreferredMode
  if ([string]::IsNullOrWhiteSpace($normalizedPreferredMode)) {
    $normalizedPreferredMode = 'web'
  }

  return @(
    [pscustomobject]@{ mode = 'web'; label = '网页登录'; description = '执行原生 `codex login` 默认流'; recommended = ($normalizedPreferredMode -eq 'web') }
    [pscustomobject]@{ mode = 'device'; label = '设备码'; description = '执行 `codex login --device-auth`'; recommended = ($normalizedPreferredMode -eq 'device') }
    [pscustomobject]@{ mode = 'api'; label = 'API Key'; description = '执行 `codex login --with-api-key`'; recommended = ($normalizedPreferredMode -eq 'api') }
    [pscustomobject]@{ mode = 'yunyi'; label = 'Yunyi API'; description = '使用 Yunyi/OpenAI 兼容 endpoint 执行 API Key 登录'; recommended = ($normalizedPreferredMode -eq 'yunyi') }
  )
}

function Get-CodexLoginSmokeModeRows {
  return @(
    [pscustomobject]@{ mode = 'web'; label = '网页登录'; description = '执行一次真实 `codex login` 登录验证'; recommended = $true }
    [pscustomobject]@{ mode = 'device'; label = '设备码'; description = '执行一次真实 `codex login --device-auth` 登录验证'; recommended = $false }
  )
}

function Get-CodexLoginEnvironmentOverrides {
  param(
    [string]$Mode,
    [string]$WorkspaceRoot,
    [string]$YunyiBaseUrl = ''
  )

  $normalizedMode = Resolve-RaymanCodexLoginMode -Mode $Mode
  switch ($normalizedMode) {
    'web' {
      return @{
        OPENAI_API_KEY = $null
        OPENAI_BASE_URL = $null
        OPENAI_API_BASE = $null
      }
    }
    'device' {
      return @{
        OPENAI_API_KEY = $null
        OPENAI_BASE_URL = $null
        OPENAI_API_BASE = $null
      }
    }
    'api' {
      return (Get-RaymanCodexApiKeyEnvironmentOverrides -WorkspaceRoot $WorkspaceRoot)
    }
    'yunyi' {
      $overrides = @{
        OPENAI_BASE_URL = [string]$YunyiBaseUrl
        OPENAI_API_BASE = [string]$YunyiBaseUrl
      }
      $apiState = Get-RaymanCodexEnvironmentApiKeyState -WorkspaceRoot $WorkspaceRoot
      if ([bool]$apiState.available -and -not [string]::IsNullOrWhiteSpace([string]$apiState.value)) {
        $overrides['OPENAI_API_KEY'] = [string]$apiState.value
      }
      return $overrides
    }
  }

  return @{}
}

function Get-CodexYunyiBaseUrlChoice {
  param(
    [string]$WorkspaceRoot
  )

  Ensure-RaymanCodexYunyiUserHomeState -WorkspaceRoot $WorkspaceRoot | Out-Null
  $userHomeState = Get-RaymanCodexUserHomeYunyiBaseUrlState
  $workspaceBackupState = $null
  $candidate = ''
  $source = ''
  $path = ''
  if ([bool]$userHomeState.available -and -not [string]::IsNullOrWhiteSpace([string]$userHomeState.value)) {
    $candidate = [string]$userHomeState.value
    $source = [string]$userHomeState.source
    $path = [string](Get-RaymanMapValue -Map $userHomeState -Key 'path' -Default '')
  }
  if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
    $workspaceBackupState = Get-RaymanCodexWorkspaceYunyiBaseUrlState -WorkspaceRoot $WorkspaceRoot
    if ([bool]$workspaceBackupState.available -and -not [string]::IsNullOrWhiteSpace([string]$workspaceBackupState.value)) {
      $candidate = [string]$workspaceBackupState.value
      $source = [string]$workspaceBackupState.source
      $path = [string](Get-RaymanMapValue -Map $workspaceBackupState -Key 'path' -Default '')
    }
  }
  if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
    $candidate = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_YUNYI_BASE_URL')
    $source = 'env:RAYMAN_CODEX_YUNYI_BASE_URL'
  }
  if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
    $candidate = [Environment]::GetEnvironmentVariable('OPENAI_BASE_URL')
    $source = 'env:OPENAI_BASE_URL'
  }
  if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
    $candidate = [Environment]::GetEnvironmentVariable('OPENAI_API_BASE')
    $source = 'env:OPENAI_API_BASE'
  }
  if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
    $candidate = Get-RaymanDotEnvString -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_CODEX_YUNYI_BASE_URL'
    $source = 'dotenv:RAYMAN_CODEX_YUNYI_BASE_URL'
  }
  if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
    $candidate = Get-RaymanDotEnvString -WorkspaceRoot $WorkspaceRoot -Name 'OPENAI_BASE_URL'
    $source = 'dotenv:OPENAI_BASE_URL'
  }
  if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
    $candidate = Get-RaymanDotEnvString -WorkspaceRoot $WorkspaceRoot -Name 'OPENAI_API_BASE'
    $source = 'dotenv:OPENAI_API_BASE'
  }

  if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
    if (-not (Test-InteractiveInputAvailable)) {
      Exit-CodexError 'codex login --mode yunyi requires RAYMAN_CODEX_YUNYI_BASE_URL/OPENAI_BASE_URL in non-interactive terminals.'
    }
    $candidate = [string](Read-Host 'Yunyi/OpenAI 兼容 API Base URL (例如 https://api.your-provider.com/v1)')
    $source = 'prompt'
  }

  $candidate = [string]$candidate
  $candidate = $candidate.Trim()
  if ([string]::IsNullOrWhiteSpace($candidate)) {
    Exit-CodexError 'Yunyi base URL cannot be empty.'
  }

  $uri = $null
  if (-not [Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$uri) -or ($uri.Scheme -ne 'https' -and $uri.Scheme -ne 'http')) {
    Exit-CodexError ('Invalid Yunyi base URL: {0}' -f $candidate)
  }

  return [pscustomobject]@{
    base_url = $candidate.TrimEnd('/')
    source = $source
    path = $path
    prompted = ($source -eq 'prompt')
  }
}

function Get-CodexYunyiBaseUrlInput {
  param(
    [string]$WorkspaceRoot
  )

  return [string](Get-CodexYunyiBaseUrlChoice -WorkspaceRoot $WorkspaceRoot).base_url
}

function Get-CodexYunyiApiKeyInput {
  param(
    [string]$WorkspaceRoot,
    [switch]$FromStdin
  )

  Ensure-RaymanCodexYunyiUserHomeState -WorkspaceRoot $WorkspaceRoot | Out-Null
  $userHomeState = Get-RaymanCodexUserHomeYunyiApiKeyState
  $candidate = ''
  if ([bool]$userHomeState.available -and -not [string]::IsNullOrWhiteSpace([string]$userHomeState.value)) {
    $candidate = [string]$userHomeState.value
  }
  if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
    $workspaceBackupState = Get-RaymanCodexWorkspaceYunyiApiKeyState -WorkspaceRoot $WorkspaceRoot
    if ([bool]$workspaceBackupState.available -and -not [string]::IsNullOrWhiteSpace([string]$workspaceBackupState.value)) {
      $candidate = [string]$workspaceBackupState.value
    }
  }
  if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
    $candidate = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_YUNYI_API_KEY')
  }
  if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
    $candidate = Get-RaymanDotEnvString -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_CODEX_YUNYI_API_KEY'
  }
  if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
    $state = Get-RaymanCodexEnvironmentApiKeyState -WorkspaceRoot $WorkspaceRoot
    if ([bool]$state.available) {
      $candidate = [string]$state.value
    }
  }

  if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
    return ([string]$candidate).Trim()
  }

  return (Get-CodexApiKeyInput -FromStdin:$FromStdin)
}

function Get-RaymanCodexYunyiConfigSummary {
  param(
    [string]$Alias
  )

  $state = Get-RaymanCodexConfigState -Alias $Alias
  $baseUrl = if (-not [string]::IsNullOrWhiteSpace([string]$state.yunyi_base_url)) { [string]$state.yunyi_base_url } else { '' }
  $configReady = ([string]$state.model_provider -eq 'yunyi' -and -not [string]::IsNullOrWhiteSpace([string]$baseUrl) -and [bool]$state.yunyi_name_present)
  $reason = if (-not [bool]$state.present) {
    'config_missing'
  } elseif ([string]$state.model_provider -ne 'yunyi') {
    'config_not_yunyi'
  } elseif ([string]::IsNullOrWhiteSpace([string]$baseUrl)) {
    'yunyi_base_url_missing'
  } elseif (-not [bool]$state.yunyi_name_present) {
    'yunyi_name_missing'
  } else {
    'ready'
  }

  return [pscustomobject]@{
    alias = (Normalize-RaymanCodexAlias -Alias $Alias)
    path = [string]$state.path
    present = [bool]$state.present
    model_provider = [string]$state.model_provider
    base_url = $baseUrl
    config_ready = $configReady
    reason = $reason
  }
}

function Set-RaymanCodexAliasYunyiConfig {
  param(
    [string]$Alias,
    [string]$BaseUrl
  )

  $normalizedAlias = Normalize-RaymanCodexAlias -Alias $Alias
  if ([string]::IsNullOrWhiteSpace([string]$normalizedAlias)) {
    Exit-CodexError 'Yunyi config requires a non-empty alias.'
  }
  if ([string]::IsNullOrWhiteSpace([string]$BaseUrl)) {
    Exit-CodexError 'Yunyi config requires a non-empty base URL.'
  }

  $account = Ensure-RaymanCodexAccount -Alias $normalizedAlias
  $configPath = Get-RaymanCodexAccountConfigPath -CodexHome ([string]$account.codex_home)
  Ensure-RaymanCodexAccountConfig -CodexHome ([string]$account.codex_home) | Out-Null
  $existingRaw = if (Test-Path -LiteralPath $configPath -PathType Leaf) { Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 } else { '' }
  $newline = if ([string]$existingRaw -match "`r`n") { "`r`n" } else { "`n" }

  $updatedRaw = [string]$existingRaw
  $updatedRaw = [regex]::Replace($updatedRaw, '(?ms)^# RAYMAN:YUNYI:BEGIN\r?\n.*?^# RAYMAN:YUNYI:END\r?\n?', '')
  $updatedRaw = [regex]::Replace($updatedRaw, '(?ms)^\[model_providers\.yunyi\]\r?\n.*?(?=^\s*\[|^# RAYMAN:|\z)', '')
  $updatedRaw = [regex]::Replace($updatedRaw, '(?im)^\s*model_provider\s*=\s*"yunyi"\s*\r?\n?', '')
  $updatedRaw = [regex]::Replace($updatedRaw, '(\r?\n){3,}', ($newline + $newline))
  $updatedRaw = $updatedRaw.Trim()
  if ([string]::IsNullOrWhiteSpace([string]$updatedRaw)) {
    $updatedRaw = ''
  } else {
    $updatedRaw += $newline
  }

  if ($updatedRaw -ne $existingRaw) {
    Write-RaymanUtf8NoBom -Path $configPath -Content $updatedRaw
  }

  $yunyiBlockLines = @(
    '# RAYMAN:YUNYI:BEGIN',
    '# Rayman-managed Yunyi provider settings.',
    'model_provider = "yunyi"',
    '',
    '[model_providers.yunyi]',
    'name = "yunyi"',
    ('base_url = "{0}"' -f ([string]$BaseUrl -replace '"', '\"')),
    'wire_api = "responses"',
    '# RAYMAN:YUNYI:END'
  )
  $yunyiBlockText = (($yunyiBlockLines -join $newline).TrimEnd("`r", "`n") + $newline)

  $normalizedBody = [string]$updatedRaw
  if (-not [string]::IsNullOrWhiteSpace([string]$normalizedBody)) {
    $normalizedBody = $normalizedBody.TrimStart("`r", "`n")
  }

  $finalRaw = if ([string]::IsNullOrWhiteSpace([string]$normalizedBody)) {
    $yunyiBlockText
  } else {
    $yunyiBlockText + $newline + $normalizedBody
  }

  Write-RaymanUtf8NoBom -Path $configPath -Content $finalRaw

  $summary = Get-RaymanCodexYunyiConfigSummary -Alias $normalizedAlias
  return [pscustomobject]@{
    success = [bool]$summary.config_ready
    path = [string]$summary.path
    base_url = [string]$summary.base_url
    config_ready = [bool]$summary.config_ready
    reason = if ([bool]$summary.config_ready) { 'configured' } else { [string]$summary.reason }
  }
}

function Resolve-CodexYunyiBaseUrlChoice {
  param(
    [string]$Alias,
    [string]$WorkspaceRoot
  )

  $normalizedAlias = Normalize-RaymanCodexAlias -Alias $Alias
  $configSummary = Get-RaymanCodexYunyiConfigSummary -Alias $normalizedAlias
  if ([bool]$configSummary.config_ready -and -not [string]::IsNullOrWhiteSpace([string]$configSummary.base_url)) {
    return [pscustomobject]@{
      base_url = [string]$configSummary.base_url
      source = 'config:alias'
      path = [string]$configSummary.path
      reuse_reason = 'last_yunyi_config'
      reused = $true
      config_ready = $true
      config_rebuilt = $false
      fallback_reason = ''
    }
  }

  $record = Get-RaymanCodexAccountRecord -Alias $normalizedAlias
  $recordBaseUrl = if ($null -ne $record) { [string](Get-RaymanMapValue -Map $record -Key 'last_yunyi_base_url' -Default '') } else { '' }
  if (-not [string]::IsNullOrWhiteSpace([string]$recordBaseUrl)) {
    $rebuild = Set-RaymanCodexAliasYunyiConfig -Alias $normalizedAlias -BaseUrl $recordBaseUrl
    if ([bool]$rebuild.success) {
      return [pscustomobject]@{
        base_url = [string]$rebuild.base_url
        source = 'record:last_yunyi_base_url'
        path = [string]$rebuild.path
        reuse_reason = 'last_yunyi_record'
        reused = $true
        config_ready = [bool]$rebuild.config_ready
        config_rebuilt = $true
        fallback_reason = ''
      }
    }
    Write-CodexWarn ("Yunyi config rebuild failed for alias={0}: {1}. Falling back to fresh base_url resolution." -f $normalizedAlias, [string]$rebuild.reason)
  }

  $inputChoice = Get-CodexYunyiBaseUrlChoice -WorkspaceRoot $WorkspaceRoot
  $writeResult = Set-RaymanCodexAliasYunyiConfig -Alias $normalizedAlias -BaseUrl ([string]$inputChoice.base_url)
  if (-not [bool]$writeResult.success) {
    Write-CodexWarn ("Yunyi config write incomplete for alias={0}: {1}" -f $normalizedAlias, [string]$writeResult.reason)
  }

  return [pscustomobject]@{
    base_url = [string]$inputChoice.base_url
    source = [string]$inputChoice.source
    path = [string](Get-RaymanMapValue -Map $inputChoice -Key 'path' -Default '')
    reuse_reason = 'fresh_base_url'
    reused = $false
    config_ready = [bool]$writeResult.config_ready
    config_rebuilt = $false
    fallback_reason = 'no_saved_yunyi_state'
  }
}

function Resolve-CodexLoginModeChoice {
  param(
    [string]$Mode,
    [string]$Alias = '',
    [string]$TargetWorkspaceRoot = '',
    [string]$Picker = 'auto',
    [switch]$PromptForMode
  )

  $explicitMode = Resolve-RaymanCodexLoginMode -Mode $Mode
  if (-not [string]::IsNullOrWhiteSpace($explicitMode)) {
    return [pscustomobject]@{
      mode = $explicitMode
      source = 'explicit'
    }
  }

  if (-not $PromptForMode) {
    return [pscustomobject]@{
      mode = 'web'
      source = 'default_web'
    }
  }

  if (-not (Test-InteractiveInputAvailable)) {
    return [pscustomobject]@{
      mode = 'web'
      source = 'noninteractive_default_web'
    }
  }

  $preferredMode = 'web'
  if (-not [string]::IsNullOrWhiteSpace($Alias)) {
    $row = Get-RaymanCodexAliasRow -Alias $Alias -TargetWorkspaceRoot $TargetWorkspaceRoot
    $existingMode = Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $row -Key 'auth_mode_last' -Default ''))
    if (-not [string]::IsNullOrWhiteSpace($existingMode)) {
      $preferredMode = $existingMode
    }
  }

  $modeRows = @(Get-CodexLoginModeRows -PreferredMode $preferredMode)
  $defaultRow = $modeRows | Where-Object { [bool]$_.recommended } | Select-Object -First 1
  if ($null -eq $defaultRow) {
    $defaultRow = $modeRows | Select-Object -First 1
  }

  $picked = Select-WithFzfOrMenu -Rows $modeRows -Picker $Picker -Prompt '选择登录方式' -Render {
    param($row)
    "{0}{1}  {2}" -f [string]$row.label, $(if ([bool]$row.recommended) { '  [推荐]' } else { '' }), [string]$row.description
  } -KeySelector {
    param($row)
    [string]$row.mode
  } -DefaultRow $defaultRow
  if ($null -eq $picked) {
    Exit-CodexError 'Login mode selection cancelled.'
  }

  return [pscustomobject]@{
    mode = [string]$picked.mode
    source = 'menu'
  }
}

function Resolve-CodexLoginSmokeModeChoice {
  param(
    [string]$Mode,
    [string]$Alias = '',
    [string]$TargetWorkspaceRoot = '',
    [string]$Picker = 'auto',
    [switch]$PromptForMode
  )

  $explicitMode = Resolve-RaymanCodexLoginMode -Mode $Mode
  if (-not [string]::IsNullOrWhiteSpace($explicitMode)) {
    if ($explicitMode -notin @('web', 'device')) {
      Exit-CodexError 'codex login-smoke only supports --mode web or --mode device.'
    }
    return [pscustomobject]@{
      mode = $explicitMode
      source = 'explicit'
    }
  }

  if (-not $PromptForMode) {
    Exit-CodexError 'codex login-smoke requires --mode web|device.'
  }

  if (-not (Test-InteractiveInputAvailable)) {
    Exit-CodexError 'codex login-smoke requires --mode web|device in non-interactive terminals.'
  }

  $modeRows = @(Get-CodexLoginSmokeModeRows)
  $defaultRow = $modeRows | Where-Object { [bool]$_.recommended } | Select-Object -First 1
  if ($null -eq $defaultRow) {
    $defaultRow = $modeRows | Select-Object -First 1
  }

  $picked = Select-WithFzfOrMenu -Rows $modeRows -Picker $Picker -Prompt ("选择 {0} 的登录 smoke 方式" -f $Alias) -Render {
    param($row)
    "{0}{1}  {2}" -f [string]$row.label, $(if ([bool]$row.recommended) { '  [推荐]' } else { '' }), [string]$row.description
  } -KeySelector {
    param($row)
    [string]$row.mode
  } -DefaultRow $defaultRow
  if ($null -eq $picked) {
    Exit-CodexError 'Codex login smoke mode selection cancelled.'
  }

  return [pscustomobject]@{
    mode = [string]$picked.mode
    source = 'menu'
  }
}

function Read-MenuSelection {
  param(
    [string]$Title,
    [object[]]$Rows,
    [scriptblock]$Render,
    [object]$DefaultRow = $null,
    [scriptblock]$KeySelector = $null
  )

  if (@($Rows).Count -eq 0) {
    return $null
  }

  Write-Host ''
  Write-Host $Title -ForegroundColor Cyan
  for ($i = 0; $i -lt $Rows.Count; $i++) {
    $label = & $Render $Rows[$i]
    Write-Host ("  [{0}] {1}" -f ($i + 1), $label)
  }

  $raw = Read-Host $(if ($null -ne $KeySelector) { 'Select (number or key)' } else { 'Select' })
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return $DefaultRow
  }

  $token = $raw.Trim()
  $index = 0
  if ([int]::TryParse($token, [ref]$index)) {
    if ($index -lt 1 -or $index -gt $Rows.Count) {
      return $null
    }
    return $Rows[$index - 1]
  }

  if ($null -ne $KeySelector) {
    foreach ($row in $Rows) {
      $candidateKey = ''
      try {
        $candidateKey = [string](& $KeySelector $row)
      } catch {
        $candidateKey = ''
      }

      if (-not [string]::IsNullOrWhiteSpace($candidateKey) -and $candidateKey -ieq $token) {
        return $row
      }
    }
  }

  return $null
}

function Select-WithFzfOrMenu {
  param(
    [object[]]$Rows,
    [string]$Picker = 'auto',
    [string]$Prompt = 'Select',
    [scriptblock]$Render,
    [scriptblock]$KeySelector,
    [object]$DefaultRow = $null
  )

  $items = @($Rows)
  if ($items.Count -eq 0) {
    return $null
  }

  $normalizedPicker = if ([string]::IsNullOrWhiteSpace($Picker)) { 'auto' } else { $Picker.Trim().ToLowerInvariant() }
  $fzf = if ($normalizedPicker -ne 'menu') { Get-Command 'fzf' -ErrorAction SilentlyContinue | Select-Object -First 1 } else { $null }
  $canUseFzf = ($null -ne $fzf)
  if ($normalizedPicker -eq 'fzf' -and -not $canUseFzf) {
    Exit-CodexError 'fzf is not installed on this host.'
  }

  if ($canUseFzf -and $normalizedPicker -in @('auto', 'fzf')) {
    $lookup = @{}
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($item in $items) {
      $line = (& $Render $item)
      $key = (& $KeySelector $item)
      $lookup[[string]$line] = $key
      $lines.Add([string]$line) | Out-Null
    }

    $selected = @($lines.ToArray()) | & $fzf.Source --prompt ($Prompt + '> ') | Select-Object -First 1
    if (-not [string]::IsNullOrWhiteSpace([string]$selected)) {
      $selectedKey = [string]$lookup[[string]$selected]
      foreach ($item in $items) {
        if ((& $KeySelector $item) -eq $selectedKey) {
          return $item
        }
      }
    }
  }

  return (Read-MenuSelection -Title $Prompt -Rows $items -Render $Render -DefaultRow $DefaultRow -KeySelector $KeySelector)
}

function Resolve-WorkspaceRootInput {
  param(
    [string]$InputRoot
  )

  $candidate = if ([string]::IsNullOrWhiteSpace($InputRoot)) { $WorkspaceRoot } else { $InputRoot }
  if (Get-Command Resolve-RaymanCodexWorkspacePath -ErrorAction SilentlyContinue) {
    return (Resolve-RaymanCodexWorkspacePath -WorkspaceRoot $candidate)
  }
  try {
    return [System.IO.Path]::GetFullPath($candidate)
  } catch {
    return [string]$candidate
  }
}

function Get-WorkspaceRows {
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($workspace in @(Get-RaymanCodexWorkspaceRecords)) {
    if ($null -eq $workspace) { continue }
    $rows.Add([pscustomobject]@{
        workspace_root = [string](Get-RaymanMapValue -Map $workspace -Key 'workspace_root' -Default '')
        display_name = [string](Get-RaymanMapValue -Map $workspace -Key 'display_name' -Default '')
        last_account_alias = [string](Get-RaymanMapValue -Map $workspace -Key 'last_account_alias' -Default '')
        last_profile = [string](Get-RaymanMapValue -Map $workspace -Key 'last_profile' -Default '')
        last_used_at = [string](Get-RaymanMapValue -Map $workspace -Key 'last_used_at' -Default '')
      }) | Out-Null
  }
  return @($rows.ToArray())
}

function Format-CodexExecutionProfileText {
  param(
    [string]$Profile
  )

  if ([string]::IsNullOrWhiteSpace($Profile)) {
    return '(none)'
  }
  return [string]$Profile
}

function Format-VsCodeUserProfileText {
  param(
    [object]$ProfileState
  )

  if ($null -eq $ProfileState) {
    return '(unknown)'
  }
  if ([bool](Get-RaymanMapValue -Map $ProfileState -Key 'profile_detected' -Default $false)) {
    return [string](Get-RaymanMapValue -Map $ProfileState -Key 'profile_name' -Default '')
  }
  if ([bool](Get-RaymanMapValue -Map $ProfileState -Key 'profile_is_default' -Default $false)) {
    return '(VS Code default profile)'
  }
  return '(unmatched)'
}

function Get-VsCodeUserProfileRows {
  param(
    [object]$ProfileState
  )

  $detectedName = [string](Get-RaymanMapValue -Map $ProfileState -Key 'profile_name' -Default '')
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($profile in @((Get-RaymanMapValue -Map $ProfileState -Key 'profiles' -Default @()))) {
    $name = [string](Get-RaymanMapValue -Map $profile -Key 'name' -Default '')
    if ([string]::IsNullOrWhiteSpace($name)) {
      continue
    }
    $rows.Add([pscustomobject]@{
        alias = $name
        location = [string](Get-RaymanMapValue -Map $profile -Key 'location' -Default '')
        current = (-not [string]::IsNullOrWhiteSpace($detectedName) -and $name -ieq $detectedName)
      }) | Out-Null
  }

  return @(
    $rows.ToArray() |
    Sort-Object `
      @{ Expression = { if ([bool]$_.current) { 0 } else { 1 } } }, `
      @{ Expression = { [string]$_.alias } }
  )
}

function Resolve-LoginAliasChoice {
  param(
    [string]$Alias,
    [string]$TargetWorkspaceRoot,
    [string]$Picker = 'auto',
    [string]$Mode = ''
  )

  $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $TargetWorkspaceRoot
  $normalizedAlias = Normalize-RaymanCodexAlias -Alias $Alias
  $profileState = Get-RaymanVsCodeUserProfileState -WorkspaceRoot $resolvedWorkspace
  if (-not [string]::IsNullOrWhiteSpace($normalizedAlias)) {
    return [pscustomobject]@{
      workspace_root = $resolvedWorkspace
      alias = $normalizedAlias
      alias_source = 'explicit'
      vscode_user_profile_state = $profileState
    }
  }

  if (-not (Test-InteractiveInputAvailable)) {
    Exit-CodexError 'login requires --alias <alias> in non-interactive terminals.'
  }

  Write-CodexInfo ("workspace={0}" -f $resolvedWorkspace)
  Write-CodexInfo ("VS Code user profile={0}" -f (Format-VsCodeUserProfileText -ProfileState $profileState))
  # When a specific mode is selected, filter aliases to show only those compatible with that mode
  $shouldFilterByMode = [bool](-not [string]::IsNullOrWhiteSpace($Mode))
  $loginRows = @(Get-LoginAliasRows -TargetWorkspaceRoot $resolvedWorkspace -PreferredMode $Mode -FilterByMode:$shouldFilterByMode)
  $defaultRow = $loginRows | Select-Object -First 1
  $selected = Select-WithFzfOrMenu -Rows $loginRows -Picker $Picker -Prompt '选择登录 alias' -Render {
    param($row)
    $description = ([string[]](Get-RaymanMapValue -Map $row -Key 'tags' -Default @()) -join ' / ')
    "{0}{1}{2}" -f [string]$row.label, $(if ([bool]$row.recommended) { '  [推荐]' } else { '' }), $(if ([string]::IsNullOrWhiteSpace($description)) { '' } else { '  ' + $description })
  } -KeySelector {
    param($row)
    [string]$row.key
  } -DefaultRow $defaultRow
  if ($null -eq $selected) {
    Exit-CodexError 'Login alias selection cancelled.'
  }

  if ([string](Get-RaymanMapValue -Map $selected -Key 'kind' -Default '') -eq 'custom') {
    $manualAlias = Normalize-RaymanCodexAlias -Alias (Read-Host 'Alias')
    if ([string]::IsNullOrWhiteSpace($manualAlias)) {
      Exit-CodexError 'login requires a non-empty alias.'
    }

    return [pscustomobject]@{
      workspace_root = $resolvedWorkspace
      alias = $manualAlias
      alias_source = 'manual'
      vscode_user_profile_state = $profileState
    }
  }

  return [pscustomobject]@{
    workspace_root = $resolvedWorkspace
    alias = [string]$selected.alias
    alias_source = 'menu'
    vscode_user_profile_state = $profileState
  }
}

function Resolve-DesiredProfile {
  param(
    [object]$AccountRow,
    [string]$ExplicitProfile,
    [object]$CurrentBinding,
    [string]$DesiredAlias
  )

  if (-not [string]::IsNullOrWhiteSpace($ExplicitProfile)) {
    return [string]$ExplicitProfile
  }

  $currentAlias = Normalize-RaymanCodexAlias -Alias ([string](Get-RaymanMapValue -Map $CurrentBinding -Key 'account_alias' -Default ''))
  if (-not [string]::IsNullOrWhiteSpace($currentAlias) -and $currentAlias -ieq $DesiredAlias) {
    $currentProfile = [string](Get-RaymanMapValue -Map $CurrentBinding -Key 'profile' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($currentProfile)) {
      return $currentProfile
    }
  }

  return [string](Get-RaymanMapValue -Map $AccountRow -Key 'default_profile' -Default '')
}

function Get-CodexMenuActionRows {
  return @(
    [pscustomobject]@{ action = 'status'; label = '状态与绑定'; description = '查看当前 workspace 绑定、VS Code profile 和认证状态'; recommended = $true }
    [pscustomobject]@{ action = 'list'; label = '账号列表'; description = '列出已知 alias、登录方式、最近 session 和本地 saved state 摘要'; recommended = $false }
    [pscustomobject]@{ action = 'login-web'; label = '网页登录'; description = '直接选择 alias 后执行原生 `codex login`'; recommended = $false }
    [pscustomobject]@{ action = 'login-smoke'; label = '登录 Smoke'; description = '带节流保护地执行一次真实网页登录/设备码验证'; recommended = $false }
    [pscustomobject]@{ action = 'login-yunyi'; label = 'Yunyi 登录'; description = '使用 Yunyi/OpenAI 兼容 endpoint 执行 API Key 登录'; recommended = $false }
    [pscustomobject]@{ action = 'login-api'; label = 'API 登录'; description = '优先复用环境变量/.env 中的 OPENAI_API_KEY，否则回退原生 API key 登录'; recommended = $false }
    [pscustomobject]@{ action = 'login-device'; label = '设备码登录'; description = '直接选择 alias 后执行 `codex login --device-auth`'; recommended = $false }
    [pscustomobject]@{ action = 'switch'; label = '切换账号'; description = '把当前 workspace 绑定到另一个已知 alias'; recommended = $false }
    [pscustomobject]@{ action = 'manage'; label = '管理账号'; description = '查看详情、更新默认 profile、重新登录、删除 alias'; recommended = $false }
    [pscustomobject]@{ action = 'run'; label = '运行 Codex CLI'; description = '输入简单参数后透传给 codex CLI'; recommended = $false }
    [pscustomobject]@{ action = 'upgrade'; label = '升级 Codex CLI'; description = '检查并升级当前宿主上的 Codex CLI'; recommended = $false }
  )
}

function Get-CodexManageActionRows {
  return @(
    [pscustomobject]@{ action = 'details'; label = '查看详情'; description = '显示 alias、认证模式、最近 session、saved state 与绑定情况'; recommended = $true }
    [pscustomobject]@{ action = 'set-default-profile'; label = '更新默认 profile'; description = '修改 alias 的默认 Codex execution profile'; recommended = $false }
    [pscustomobject]@{ action = 'relogin'; label = '重新登录'; description = '复用当前 alias 容器重新执行网页登录 / API / 设备码登录'; recommended = $false }
    [pscustomobject]@{ action = 'delete-safe'; label = '安全删除'; description = '移除 alias 和 workspace 引用，但保留 CODEX_HOME 与凭据'; recommended = $false }
    [pscustomobject]@{ action = 'delete-hard'; label = '彻底删除'; description = '安全删除后，再删除该 alias 的 CODEX_HOME'; recommended = $false }
  )
}

function Show-CodexMenuHeader {
  param(
    [string]$TargetWorkspaceRoot
  )

  $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $TargetWorkspaceRoot
  $context = Resolve-RaymanCodexContext -WorkspaceRoot $resolvedWorkspace
  $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $resolvedWorkspace -AccountAlias ([string]$context.account_alias) -SkipReportWrite -GuardStage 'codex.status'
  Write-Host ''
  Write-CodexInfo ("workspace={0}" -f $resolvedWorkspace)
  Write-CodexInfo ("alias={0}" -f $(if ([string]::IsNullOrWhiteSpace([string]$context.account_alias)) { '(unbound)' } else { [string]$context.account_alias }))
  Write-CodexInfo ("认证状态={0}" -f [string]$status.status)
  Write-CodexInfo ("最近登录方式={0} / 当前检测={1}" -f (Format-CodexAuthModeLastText -Mode ([string]$status.auth_mode_last)), (Format-CodexDetectedAuthText -Status $status))
  if ($status.PSObject.Properties['desktop_target_mode'] -and -not [string]::IsNullOrWhiteSpace([string]$status.desktop_target_mode)) {
    Write-CodexInfo ("桌面目标模式={0} saved_token={1} source={2}" -f [string]$status.desktop_target_mode, [string]$status.desktop_saved_token_reused, [string]$status.desktop_saved_token_source)
  }
  if ($status.PSObject.Properties['auth_scope'] -and -not [string]::IsNullOrWhiteSpace([string]$status.auth_scope)) {
    Write-CodexInfo ("认证作用域={0} effective_home={1}" -f [string]$status.auth_scope, [string]$status.codex_home)
  }
  if ($status.PSObject.Properties['last_login_mode'] -and -not [string]::IsNullOrWhiteSpace([string]$status.last_login_mode)) {
    Write-CodexInfo ("最近登录诊断={0} / {1} / {2}" -f [string]$status.last_login_mode, [string]$status.last_login_strategy, [string]$status.last_login_prompt_classification)
  }
  if (
    ($status.PSObject.Properties['last_yunyi_base_url'] -and -not [string]::IsNullOrWhiteSpace([string]$status.last_yunyi_base_url)) -or
    ($status.PSObject.Properties['last_yunyi_config_ready'] -and [bool]$status.last_yunyi_config_ready)
  ) {
    Write-CodexInfo ("Yunyi 复用={0} base_url={1} source={2}" -f [string]$status.last_yunyi_reuse_reason, [string]$status.last_yunyi_base_url, [string]$status.last_yunyi_base_url_source)
  }
  if ($status.PSObject.Properties['desktop_status_command'] -and -not [string]::IsNullOrWhiteSpace([string]$status.desktop_status_command)) {
    Write-CodexInfo ("Desktop {0} quota_visible={1} reason={2} conflict={3} unsynced={4}" -f [string]$status.desktop_status_command, [string]$status.desktop_status_quota_visible, [string]$status.desktop_status_reason, [string]$status.desktop_config_conflict, [string]$status.desktop_unsynced_reason)
  }
  if ($status.PSObject.Properties['login_smoke_next_allowed_at'] -and -not [string]::IsNullOrWhiteSpace([string]$status.login_smoke_next_allowed_at)) {
    Write-CodexWarn ("登录 smoke 冷却至 {0} (mode={1})" -f [string]$status.login_smoke_next_allowed_at, [string]$status.login_smoke_mode)
  }
  Write-CodexRepeatErrorSummary -Status $status
  Write-CodexInfo ("最近原生 session={0}" -f (Format-CodexNativeSessionText -Session $status.latest_native_session))
  Write-CodexInfo ("当前 workspace saved state={0}" -f (Format-CodexSavedStateSummaryText -Summary $status.saved_state_summary))
  Write-CodexInfo ("VS Code user profile={0}" -f (Format-VsCodeUserProfileText -ProfileState $context))
  Write-CodexInfo ("Codex execution profile={0}" -f (Format-CodexExecutionProfileText -Profile ([string]$context.effective_profile)))
}

function Select-CodexAliasRow {
  param(
    [string]$Alias,
    [string]$Picker = 'auto',
    [string]$Prompt = 'Select Codex alias',
    [string]$TargetWorkspaceRoot = ''
  )

  if (-not [string]::IsNullOrWhiteSpace($Alias)) {
    $aliasRow = Get-RaymanCodexAliasRow -Alias $Alias -TargetWorkspaceRoot $TargetWorkspaceRoot
    if ($null -eq $aliasRow) {
      Exit-CodexError ("Unknown Codex alias '{0}'." -f $Alias)
    }
    return $aliasRow
  }

  $aliasRows = @(Get-RaymanCodexAccountRows -TargetWorkspaceRoot $TargetWorkspaceRoot)
  if ($aliasRows.Count -eq 0) {
    Exit-CodexError 'No Rayman-managed Codex aliases are available. Run `rayman codex login --alias <alias>` first.'
  }

  $defaultRow = $aliasRows | Select-Object -First 1
  $picked = Select-WithFzfOrMenu -Rows $aliasRows -Picker $Picker -Prompt $Prompt -Render {
    param($row)
    "{0}  [{1}]  mode={2}  native={3}  {4}" -f [string]$row.alias, [string]$row.status, (Format-CodexAuthModeLastText -Mode ([string]$row.auth_mode_last)), (Format-CodexNativeSessionText -Session $row.latest_native_session), (Format-CodexSavedStateSummaryText -Summary $row.saved_state_summary)
  } -KeySelector {
    param($row)
    [string]$row.alias
  } -DefaultRow $defaultRow
  if ($null -eq $picked) {
    Exit-CodexError 'Alias selection cancelled.'
  }
  return $picked
}

function Format-CodexDeviceAuthProcessText {
  param(
    [object]$Process
  )

  $processId = [int](Get-RaymanMapValue -Map $Process -Key 'process_id' -Default 0)
  $ageSeconds = [int](Get-RaymanMapValue -Map $Process -Key 'age_seconds' -Default -1)
  $parentProcessId = [int](Get-RaymanMapValue -Map $Process -Key 'parent_process_id' -Default 0)
  $parentExists = [bool](Get-RaymanMapValue -Map $Process -Key 'parent_exists' -Default $false)
  $ownerUser = [string](Get-RaymanMapValue -Map $Process -Key 'owner_user' -Default '')
  $ownerDomain = [string](Get-RaymanMapValue -Map $Process -Key 'owner_domain' -Default '')
  $createdAt = [string](Get-RaymanMapValue -Map $Process -Key 'created_at' -Default '')

  $ownerText = if ([string]::IsNullOrWhiteSpace($ownerUser)) {
    '(owner unknown)'
  } elseif ([string]::IsNullOrWhiteSpace($ownerDomain)) {
    $ownerUser
  } else {
    ('{0}\{1}' -f $ownerDomain, $ownerUser)
  }
  $ageText = if ($ageSeconds -ge 0) { ('{0}s' -f $ageSeconds) } else { '(unknown age)' }
  $createdText = if ([string]::IsNullOrWhiteSpace($createdAt)) { '(unknown created_at)' } else { $createdAt }
  $parentText = if ($parentProcessId -gt 0) {
    ('{0}:{1}' -f $(if ($parentExists) { 'alive' } else { 'missing' }), $parentProcessId)
  } else {
    '(no parent)'
  }

  return ('pid={0} age={1} parent={2} owner={3} created={4}' -f $processId, $ageText, $parentText, $ownerText, $createdText)
}

function Invoke-CodexDeviceAuthPreflight {
  param(
    [string]$Alias,
    [int]$StaleAfterSeconds = 180
  )

  if (-not (Test-RaymanWindowsPlatform)) {
    return [pscustomobject]@{
      stale_processes = @()
      active_processes = @()
      killed_processes = @()
      stale_after_seconds = $StaleAfterSeconds
    }
  }

  $deviceAuthProcesses = @(Get-RaymanCodexDeviceAuthProcesses)
  if ($deviceAuthProcesses.Count -eq 0) {
    return [pscustomobject]@{
      stale_processes = @()
      active_processes = @()
      killed_processes = @()
      stale_after_seconds = $StaleAfterSeconds
    }
  }

  $staleProcesses = New-Object System.Collections.Generic.List[object]
  $activeProcesses = New-Object System.Collections.Generic.List[object]
  $killedProcesses = New-Object System.Collections.Generic.List[object]

  foreach ($process in $deviceAuthProcesses) {
    $ageSeconds = [int](Get-RaymanMapValue -Map $process -Key 'age_seconds' -Default -1)
    $parentExists = [bool](Get-RaymanMapValue -Map $process -Key 'parent_exists' -Default $false)
    $isStale = (-not $parentExists)
    if ($isStale) {
      $staleProcesses.Add($process) | Out-Null
    } else {
      $activeProcesses.Add($process) | Out-Null
    }
  }

  foreach ($process in @($staleProcesses.ToArray())) {
    $processId = [int](Get-RaymanMapValue -Map $process -Key 'process_id' -Default 0)
    if ($processId -le 0) {
      continue
    }

    try {
      Stop-Process -Id $processId -Force -ErrorAction Stop
      $killedProcesses.Add($process) | Out-Null
      Write-CodexWarn ("stopped orphaned Codex device-auth process for alias={0}: {1}" -f $Alias, (Format-CodexDeviceAuthProcessText -Process $process))
    } catch {
      Exit-CodexError ("Failed to stop orphaned Codex device-auth process for alias '{0}': {1}" -f $Alias, $_.Exception.Message) 4
    }
  }

  if ($activeProcesses.Count -gt 0) {
    $details = @($activeProcesses.ToArray() | ForEach-Object { Format-CodexDeviceAuthProcessText -Process $_ }) -join '; '
    Exit-CodexError ("Another Codex device-auth login is still active. Finish it first or close that auth window before retrying. alias={0} active={1}" -f $Alias, $details) 4
  }

  return [pscustomobject]@{
    stale_processes = @($staleProcesses.ToArray())
    active_processes = @($activeProcesses.ToArray())
    killed_processes = @($killedProcesses.ToArray())
    stale_after_seconds = $StaleAfterSeconds
  }
}

function ConvertFrom-SecureStringPlainText {
  param(
    [Security.SecureString]$SecureString
  )

  if ($null -eq $SecureString) {
    return ''
  }

  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    if ($bstr -ne [IntPtr]::Zero) {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
  }
}

function Get-CodexApiKeyInput {
  param(
    [switch]$FromStdin
  )

  if ($FromStdin) {
    if (Test-InteractiveInputAvailable) {
      Exit-CodexError 'codex login --mode api --api-key-stdin requires redirected stdin.'
    }

    $stdin = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($stdin)) {
      Exit-CodexError 'No API key was provided on stdin.'
    }
    return [string]$stdin.Trim()
  }

  if (-not (Test-InteractiveInputAvailable)) {
    Exit-CodexError 'codex login --mode api requires --api-key-stdin in non-interactive terminals.'
  }

  $secure = Read-Host 'OpenAI API Key' -AsSecureString
  $plain = ConvertFrom-SecureStringPlainText -SecureString $secure
  if ([string]::IsNullOrWhiteSpace($plain)) {
    Exit-CodexError 'API key cannot be empty.'
  }
  return [string]$plain.Trim()
}

function Resolve-RaymanCodexInteractiveLoginStrategy {
  param(
    [string]$WorkspaceRoot,
    [string]$Mode
  )

  $normalizedMode = Resolve-RaymanCodexLoginMode -Mode $Mode
  $foregroundOnly = Get-RaymanCodexLoginForegroundOnly -WorkspaceRoot $WorkspaceRoot
  $allowHidden = Get-RaymanCodexLoginAllowHidden -WorkspaceRoot $WorkspaceRoot

  if (-not (Test-RaymanWindowsPlatform)) {
    return [pscustomobject]@{
      strategy = 'foreground'
      prefer_hidden = $false
      allow_fallback = $false
      fallback_suppressed = $false
      reason = 'non_windows_foreground'
      foreground_only = $false
      allow_hidden = $false
    }
  }

  if ($normalizedMode -notin @('web', 'device')) {
    return [pscustomobject]@{
      strategy = 'foreground'
      prefer_hidden = $false
      allow_fallback = $false
      fallback_suppressed = $false
      reason = 'non_interactive_mode'
      foreground_only = $foregroundOnly
      allow_hidden = $allowHidden
    }
  }

  if (-not $foregroundOnly -and $allowHidden) {
    return [pscustomobject]@{
      strategy = 'hidden_then_foreground'
      prefer_hidden = $true
      allow_fallback = $true
      fallback_suppressed = $false
      reason = 'legacy_hidden_opt_in'
      foreground_only = $foregroundOnly
      allow_hidden = $allowHidden
    }
  }

  return [pscustomobject]@{
    strategy = 'foreground'
    prefer_hidden = $false
    allow_fallback = $false
    fallback_suppressed = $true
    reason = $(if ($foregroundOnly) { 'foreground_only_default' } else { 'hidden_not_allowed' })
    foreground_only = $foregroundOnly
    allow_hidden = $allowHidden
  }
}

function Write-CodexLoginSmokeBudget {
  param(
    [string]$WorkspaceRoot,
    [string]$Alias,
    [string]$Mode,
    [switch]$Force
  )

  $summary = Get-RaymanCodexLoginSmokeWindowSummary -WorkspaceRoot $WorkspaceRoot -Alias $Alias -Mode $Mode
  Write-CodexInfo ("login smoke budget alias={0} mode={1}: {2}" -f $Alias, $Mode, (Resolve-RaymanCodexLoginSmokeSummaryText -Summary $summary))
  if ([bool]$Force) {
    Write-CodexWarn 'login smoke force override enabled; cooldown will be bypassed for this attempt.'
  }
  return $summary
}

function Write-CodexBlockedLoginSmokeReport {
  param(
    [string]$WorkspaceRoot,
    [string]$Alias,
    [string]$Mode,
    [object]$ThrottleSummary
  )

  $report = [ordered]@{
    schema = 'rayman.codex.login.last.v1'
    generated_at = (Get-Date).ToString('o')
    workspace_root = $WorkspaceRoot
    alias = $Alias
    mode = $Mode
    auth_scope = ''
    alias_codex_home = ''
    desktop_codex_home = ''
    desktop_auth_present = $false
    desktop_global_cloud_access = ''
    desktop_status_command = '/status'
    desktop_status_quota_visible = $false
    desktop_status_reason = 'not_started'
    desktop_validation_report_path = ''
    rollback_applied = $false
    rollback_reason = ''
    smoke = $true
    blocked = $true
    blocked_reason = 'smoke_throttled'
    success = $false
    exit_code = 4
    launch_strategy = 'not_started'
    fallback_used = $false
    fallback_suppressed = $true
    prompt_classification = 'none'
    overrides_requested = $false
    overrides_applied = $false
    override_keys = @()
    override_skipped_reason = 'not_started'
    output_captured = $false
    started_at = ''
    finished_at = ''
    duration_ms = 0
    smoke_throttle = $ThrottleSummary
  }
  return (Write-RaymanCodexLoginReport -WorkspaceRoot $WorkspaceRoot -Report ([pscustomobject]$report))
}

function Get-RaymanCodexDesktopModeBackupRoot {
  param(
    [string]$Alias
  )

  $account = Ensure-RaymanCodexAccount -Alias $Alias
  $root = Join-Path ([string]$account.codex_home) 'desktop_mode_backups'
  if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
  }
  return $root
}

function Get-RaymanCodexDesktopModeBackupPath {
  param(
    [string]$Alias,
    [string]$Name
  )

  if ([string]::IsNullOrWhiteSpace([string]$Name)) {
    return ''
  }
  return (Join-Path (Get-RaymanCodexDesktopModeBackupRoot -Alias $Alias) $Name)
}

function Get-RaymanCodexDesktopSharedBackupRoot {
  param([string]$DesktopCodexHome)

  $desktopHome = if ([string]::IsNullOrWhiteSpace([string]$DesktopCodexHome)) { Get-RaymanCodexDesktopHomePath } else { [string]$DesktopCodexHome }
  if ([string]::IsNullOrWhiteSpace([string]$desktopHome)) {
    return ''
  }

  $root = Join-Path $desktopHome '.Rayman\desktop_mode_backups'
  if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
  }
  return $root
}

function Get-RaymanCodexDesktopSharedBackupPath {
  param(
    [string]$DesktopCodexHome,
    [string]$Name
  )

  if ([string]::IsNullOrWhiteSpace([string]$Name)) {
    return ''
  }
  return (Join-Path (Get-RaymanCodexDesktopSharedBackupRoot -DesktopCodexHome $DesktopCodexHome) $Name)
}

function Save-RaymanCodexDesktopModeBackup {
  param(
    [string]$Alias,
    [string]$DesktopCodexHome
  )

  $backupRoot = Get-RaymanCodexDesktopModeBackupRoot -Alias $Alias
  $desktopAuthPath = Get-RaymanCodexAuthFilePath -CodexHome $DesktopCodexHome
  $desktopConfigPath = Get-RaymanCodexAccountConfigPath -CodexHome $DesktopCodexHome
  $desktopGlobalStatePath = Get-RaymanCodexDesktopGlobalStatePath
  $savedPaths = New-Object System.Collections.Generic.List[string]

  foreach ($item in @(
      [pscustomobject]@{ source = $desktopAuthPath; destination = (Get-RaymanCodexDesktopModeBackupPath -Alias $Alias -Name 'desktop.auth.last-non-chatgpt.json') }
      [pscustomobject]@{ source = $desktopConfigPath; destination = (Get-RaymanCodexDesktopModeBackupPath -Alias $Alias -Name 'desktop.config.last-non-chatgpt.toml') }
      [pscustomobject]@{ source = $desktopGlobalStatePath; destination = (Get-RaymanCodexDesktopModeBackupPath -Alias $Alias -Name 'desktop.global-state.last-non-chatgpt.json') }
    )) {
    if ([string]::IsNullOrWhiteSpace([string]$item.source) -or -not (Test-Path -LiteralPath $item.source -PathType Leaf)) {
      continue
    }

    Copy-Item -LiteralPath $item.source -Destination ([string]$item.destination) -Force
    $savedPaths.Add([string]$item.destination) | Out-Null
  }

  $desktopConfigState = Get-RaymanCodexConfigState -CodexHome $DesktopCodexHome
  $desktopAuthSummary = Get-RaymanCodexAuthFileSummary -CodexHome $DesktopCodexHome
  if ([bool]$desktopConfigState.present -and [bool]$desktopConfigState.conflict_detected -and -not [string]::IsNullOrWhiteSpace([string]$desktopConfigPath) -and (Test-Path -LiteralPath $desktopConfigPath -PathType Leaf)) {
    $yunyiDesktopPath = Join-Path $DesktopCodexHome 'config.toml.yunyi'
    $yunyiBackupPath = Get-RaymanCodexDesktopModeBackupPath -Alias $Alias -Name 'desktop.config.yunyi.toml'
    Copy-Item -LiteralPath $desktopConfigPath -Destination $yunyiDesktopPath -Force
    Copy-Item -LiteralPath $desktopConfigPath -Destination $yunyiBackupPath -Force
    $savedPaths.Add($yunyiDesktopPath) | Out-Null
    $savedPaths.Add($yunyiBackupPath) | Out-Null
  }

  if ([bool]$desktopAuthSummary.present -and [string]$desktopAuthSummary.auth_mode -eq 'chatgpt') {
    foreach ($item in @(
        [pscustomobject]@{ source = $desktopAuthPath; destination = (Get-RaymanCodexDesktopSharedBackupPath -DesktopCodexHome $DesktopCodexHome -Name 'desktop.auth.chatgpt.json') }
        [pscustomobject]@{ source = $desktopConfigPath; destination = (Get-RaymanCodexDesktopSharedBackupPath -DesktopCodexHome $DesktopCodexHome -Name 'desktop.config.chatgpt.toml') }
        [pscustomobject]@{ source = $desktopGlobalStatePath; destination = (Get-RaymanCodexDesktopSharedBackupPath -DesktopCodexHome $DesktopCodexHome -Name 'desktop.global-state.chatgpt.json') }
      )) {
      if ([string]::IsNullOrWhiteSpace([string]$item.source) -or -not (Test-Path -LiteralPath $item.source -PathType Leaf)) {
        continue
      }

      Copy-Item -LiteralPath $item.source -Destination ([string]$item.destination) -Force
      $savedPaths.Add([string]$item.destination) | Out-Null
    }
  }

  return [pscustomobject]@{
    backup_root = $backupRoot
    saved_paths = @($savedPaths.ToArray())
  }
}

function Set-RaymanCodexDesktopCloudAccessState {
  param(
    [string]$DesktopCodexHome,
    [string]$CloudAccess
  )

  $desktopHome = if ([string]::IsNullOrWhiteSpace([string]$DesktopCodexHome)) { Get-RaymanCodexDesktopHomePath } else { [string]$DesktopCodexHome }
  if ([string]::IsNullOrWhiteSpace([string]$desktopHome)) {
    return [pscustomobject]@{
      success = $false
      path = ''
      cloud_access = [string]$CloudAccess
      reason = 'desktop_home_missing'
    }
  }

  if (-not (Test-Path -LiteralPath $desktopHome -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $desktopHome | Out-Null
  }

  $statePath = Join-Path $desktopHome '.codex-global-state.json'
  $root = [ordered]@{}
  if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
      $existing = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      $root = ConvertTo-RaymanStringKeyMap -InputObject $existing
    } catch {
      $root = [ordered]@{}
    }
  }

  $atomState = ConvertTo-RaymanStringKeyMap -InputObject (Get-RaymanMapValue -Map $root -Key 'electron-persisted-atom-state' -Default $null)
  if ($atomState.Count -eq 0) {
    $atomState = [ordered]@{}
  }
  $atomState['codexCloudAccess'] = [string]$CloudAccess
  $root['electron-persisted-atom-state'] = $atomState

  Write-RaymanUtf8NoBom -Path $statePath -Content ((($root | ConvertTo-Json -Depth 12).TrimEnd()) + "`n")
  return [pscustomobject]@{
    success = $true
    path = $statePath
    cloud_access = [string]$CloudAccess
    reason = 'updated'
  }
}

function Set-RaymanCodexDesktopConfigMode {
  param(
    [string]$Alias,
    [string]$DesktopCodexHome,
    [string]$Mode
  )

  $normalizedMode = Normalize-RaymanCodexAuthModeLast -Mode $Mode
  $desktopHome = if ([string]::IsNullOrWhiteSpace([string]$DesktopCodexHome)) { Get-RaymanCodexDesktopHomePath } else { [string]$DesktopCodexHome }
  if ([string]::IsNullOrWhiteSpace([string]$desktopHome)) {
    return [pscustomobject]@{
      success = $false
      path = ''
      reason = 'desktop_home_missing'
    }
  }

  Ensure-RaymanCodexAccountConfig -CodexHome $desktopHome | Out-Null
  $configPath = Get-RaymanCodexAccountConfigPath -CodexHome $desktopHome
  $existingRaw = if (Test-Path -LiteralPath $configPath -PathType Leaf) { Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 } else { '' }
  $newline = if ([string]$existingRaw -match "`r`n") { "`r`n" } else { "`n" }

if ($normalizedMode -in @('api', 'yunyi')) {
      $aliasHome = Get-RaymanCodexAccountHomePath -Alias $Alias
      $aliasConfigPath = Get-RaymanCodexAccountConfigPath -CodexHome $aliasHome
      
      if (-not [string]::IsNullOrWhiteSpace([string]$aliasConfigPath) -and (Test-Path -LiteralPath $aliasConfigPath -PathType Leaf)) {
        Copy-Item -LiteralPath $aliasConfigPath -Destination $configPath -Force
        Ensure-RaymanCodexAccountConfig -CodexHome $desktopHome | Out-Null
        return [pscustomobject]@{
          success = $true
          path = $configPath
          reason = 'restored_from_alias'
          restore_source = [string]$aliasConfigPath
        }
      } elseif ($normalizedMode -eq 'yunyi') {
        # Fallback to backups if alias config is missing but restoring yunyi
        $backupCandidates = @(
          (Join-Path $desktopHome 'config.toml.yunyi')
          (Get-RaymanCodexDesktopModeBackupPath -Alias $Alias -Name 'desktop.config.yunyi.toml')
          (Get-RaymanCodexDesktopModeBackupPath -Alias $Alias -Name 'desktop.config.last-non-chatgpt.toml')
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique

        $restorePath = $backupCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if ($null -eq $restorePath -or [string]::IsNullOrWhiteSpace([string]$restorePath)) {
          return [pscustomobject]@{
            success = $false
            path = $configPath
            reason = 'yunyi_config_backup_missing'
          }
        }

        Copy-Item -LiteralPath ([string]$restorePath) -Destination $configPath -Force
        Ensure-RaymanCodexAccountConfig -CodexHome $desktopHome | Out-Null
        return [pscustomobject]@{
          success = $true
          path = $configPath
          reason = 'restored_from_backup'
          restore_source = [string]$restorePath
        }
    }
  }

  $updatedRaw = [string]$existingRaw
  $updatedRaw = [regex]::Replace($updatedRaw, '(?ms)^# RAYMAN:YUNYI:BEGIN\r?\n.*?# RAYMAN:YUNYI:END\r?\n?', '')
  $updatedRaw = [regex]::Replace($updatedRaw, '(?ms)^\[model_providers\.[^\]\r\n]+\]\r?\n.*?(?=^\s*\[|^# RAYMAN:|\z)', '')
  $updatedRaw = [regex]::Replace($updatedRaw, '(?im)^\s*model_provider\s*=.*\r?\n?', '')
  $updatedRaw = [regex]::Replace($updatedRaw, '(\r?\n){3,}', ($newline + $newline))
  $updatedRaw = $updatedRaw.Trim()
  if ([string]::IsNullOrWhiteSpace([string]$updatedRaw)) {
    $updatedRaw = ''
  } else {
    $updatedRaw += $newline
  }

  if ($updatedRaw -ne $existingRaw) {
    Write-RaymanUtf8NoBom -Path $configPath -Content $updatedRaw
  }
  Ensure-RaymanCodexAccountConfig -CodexHome $desktopHome | Out-Null

  return [pscustomobject]@{
    success = $true
    path = $configPath
    reason = if ($updatedRaw -ne $existingRaw) { 'sanitized' } else { 'unchanged' }
  }
}

function Get-RaymanCodexAuthFileSummaryFromPath {
  param([string]$Path)

  $summary = [ordered]@{
    path = [string]$Path
    present = $false
    parse_failed = $false
    auth_mode = 'unknown'
    account_id = ''
    openai_api_key_present = $false
    hash = ''
  }

  if ([string]::IsNullOrWhiteSpace([string]$Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return [pscustomobject]$summary
  }

  $summary.present = $true
  try {
    $summary.hash = [string]((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash)
  } catch {}

  try {
    $authDoc = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $summary.auth_mode = Normalize-RaymanCodexDetectedAuthMode -Mode ([string](Get-RaymanMapValue -Map $authDoc -Key 'auth_mode' -Default ''))
    $summary.openai_api_key_present = (-not [string]::IsNullOrWhiteSpace([string](Get-RaymanMapValue -Map $authDoc -Key 'OPENAI_API_KEY' -Default '')))
    $tokens = Get-RaymanMapValue -Map $authDoc -Key 'tokens' -Default $null
    $summary.account_id = [string](Get-RaymanMapValue -Map $tokens -Key 'account_id' -Default (Get-RaymanMapValue -Map $authDoc -Key 'account_id' -Default ''))
    if ($summary.auth_mode -eq 'unknown' -and [bool]$summary.openai_api_key_present) {
      $summary.auth_mode = 'apikey'
    }
  } catch {
    $summary.parse_failed = $true
  }

  return [pscustomobject]$summary
}

function Resolve-RaymanCodexDesktopSavedApiAuthSource {
  param(
    [string]$WorkspaceRoot,
    [string]$Alias,
    [object]$LoginTarget,
    [string]$Mode
  )

  $normalizedMode = Normalize-RaymanCodexAuthModeLast -Mode $Mode
  $result = [ordered]@{
    available = $false
    path = ''
    source = ''
    reason = 'saved_api_auth_missing'
  }
  if ($normalizedMode -notin @('api', 'yunyi')) {
    $result.reason = 'not_applicable'
    return [pscustomobject]$result
  }

  $candidates = New-Object System.Collections.Generic.List[object]
  if ($normalizedMode -eq 'yunyi') {
    foreach ($state in @(
        (Get-RaymanCodexUserHomeYunyiApiKeyState)
        (Get-RaymanCodexWorkspaceYunyiApiKeyState -WorkspaceRoot $WorkspaceRoot)
      )) {
      if ($null -eq $state -or -not [bool](Get-RaymanMapValue -Map $state -Key 'available' -Default $false)) {
        continue
      }
      $path = [string](Get-RaymanMapValue -Map $state -Key 'path' -Default '')
      if ([string]::IsNullOrWhiteSpace([string]$path)) {
        continue
      }
      $candidates.Add([pscustomobject]@{
          path = $path
          source = [string](Get-RaymanMapValue -Map $state -Key 'source' -Default 'yunyi_auth')
          kind = 'yunyi_auth'
          reason = [string](Get-RaymanMapValue -Map $state -Key 'reason' -Default 'canonical_auth_json')
        }) | Out-Null
    }
  }

  foreach ($candidate in @(
      [pscustomobject]@{
        path = (Get-RaymanCodexDesktopModeBackupPath -Alias $Alias -Name 'desktop.auth.last-non-chatgpt.json')
        source = 'desktop_backup_auth'
        kind = 'codex_auth'
        reason = 'desktop_backup_auth'
      }
      [pscustomobject]@{
        path = (Get-RaymanCodexAuthFilePath -CodexHome ([string](Get-RaymanMapValue -Map $LoginTarget -Key 'alias_codex_home' -Default '')))
        source = 'alias_auth'
        kind = 'codex_auth'
        reason = 'alias_auth'
      }
    )) {
    if ([string]::IsNullOrWhiteSpace([string]$candidate.path)) {
      continue
    }
    $candidates.Add($candidate) | Out-Null
  }

  $seen = @{}
  foreach ($candidate in @($candidates.ToArray())) {
    $path = [string](Get-RaymanMapValue -Map $candidate -Key 'path' -Default '')
    if ([string]::IsNullOrWhiteSpace([string]$path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
      continue
    }

    $candidateKey = $path.ToLowerInvariant()
    if ($seen.ContainsKey($candidateKey)) {
      continue
    }
    $seen[$candidateKey] = $true

    $kind = [string](Get-RaymanMapValue -Map $candidate -Key 'kind' -Default '')
    if ($kind -eq 'yunyi_auth') {
      $authState = Get-RaymanCodexYunyiAuthFileState -Path $path
      if ([bool]$authState.available) {
        return [pscustomobject]@{
          available = $true
          path = [string]$authState.path
          source = [string](Get-RaymanMapValue -Map $candidate -Key 'source' -Default 'yunyi_auth')
          reason = [string](Get-RaymanMapValue -Map $candidate -Key 'reason' -Default 'canonical_auth_json')
        }
      }
      continue
    }

    $summary = Get-RaymanCodexAuthFileSummaryFromPath -Path $path
    if ([bool]$summary.present -and [string]$summary.auth_mode -eq 'apikey' -and [bool]$summary.openai_api_key_present) {
      return [pscustomobject]@{
        available = $true
        path = [string]$summary.path
        source = [string](Get-RaymanMapValue -Map $candidate -Key 'source' -Default 'alias_auth')
        reason = [string](Get-RaymanMapValue -Map $candidate -Key 'reason' -Default 'saved_api_auth')
      }
    }
  }

  return [pscustomobject]$result
}

function Prepare-RaymanCodexDesktopLoginTarget {
  param(
    [string]$Alias,
    [string]$WorkspaceRoot,
    [object]$LoginTarget,
    [string]$Mode,
    [switch]$LogoutFirst
  )

  $normalizedMode = Normalize-RaymanCodexAuthModeLast -Mode $Mode
  $desktopHome = [string](Get-RaymanMapValue -Map $LoginTarget -Key 'desktop_codex_home' -Default '')
  $authScope = [string](Get-RaymanMapValue -Map $LoginTarget -Key 'auth_scope' -Default '')
  $result = [ordered]@{
    attempted = $false
    applicable = $false
    prep_success = $true
    should_skip_login = $false
    saved_token_reused = $false
    saved_token_source = ''
    reason = 'not_applicable'
    config_conflict = ''
    unsynced_reason = ''
    backup = $null
  }

  if (-not (Test-RaymanCodexWindowsHost) -or [string]$authScope -ne 'desktop_global' -or [string]::IsNullOrWhiteSpace([string]$desktopHome)) {
    return [pscustomobject]$result
  }

  $result.attempted = $true
  $result.applicable = $true
  $result.backup = Save-RaymanCodexDesktopModeBackup -Alias $Alias -DesktopCodexHome $desktopHome

  $configBefore = Get-RaymanCodexConfigState -CodexHome $desktopHome
  $globalBefore = Get-RaymanCodexDesktopGlobalStateSummary
  $aliasAuthBefore = Get-RaymanCodexAuthFileSummary -CodexHome ([string](Get-RaymanMapValue -Map $LoginTarget -Key 'alias_codex_home' -Default ''))
  $desktopAuthBefore = Get-RaymanCodexAuthFileSummary -CodexHome $desktopHome
  $backupAuthBefore = Get-RaymanCodexAuthFileSummaryFromPath -Path (Get-RaymanCodexDesktopModeBackupPath -Alias $Alias -Name 'desktop.auth.last-non-chatgpt.json')
  $sharedChatGptAuthBefore = Get-RaymanCodexAuthFileSummaryFromPath -Path (Get-RaymanCodexDesktopSharedBackupPath -DesktopCodexHome $desktopHome -Name 'desktop.auth.chatgpt.json')
  $result.config_conflict = [string](Get-RaymanMapValue -Map $configBefore -Key 'conflict_reason' -Default '')

  if ($normalizedMode -in @('web', 'device')) {
    $configPrep = Set-RaymanCodexDesktopConfigMode -Alias $Alias -DesktopCodexHome $desktopHome -Mode 'web'
    $cloudPrep = Set-RaymanCodexDesktopCloudAccessState -DesktopCodexHome $desktopHome -CloudAccess 'enabled'
    $result.prep_success = ([bool]$configPrep.success -and [bool]$cloudPrep.success)

    if (-not $LogoutFirst) {
      $needsRepairCopy = (
        [bool]$aliasAuthBefore.present -and
        [string]$aliasAuthBefore.auth_mode -eq 'chatgpt' -and
        (
          [string]$desktopAuthBefore.auth_mode -ne 'chatgpt' -or
          [string]$globalBefore.codex_cloud_access -eq 'disabled' -or
          [bool](Get-RaymanMapValue -Map $configBefore -Key 'conflict_detected' -Default $false)
        )
      )

      if ($needsRepairCopy) {
        $desktopAuthPath = Get-RaymanCodexAuthFilePath -CodexHome $desktopHome
        Copy-Item -LiteralPath ([string]$aliasAuthBefore.path) -Destination $desktopAuthPath -Force
        $result.should_skip_login = $true
        $result.saved_token_reused = $true
        $result.saved_token_source = 'alias_auth'
        $result.reason = 'saved_token_reused'
      } elseif (
        [bool]$sharedChatGptAuthBefore.present -and
        [string]$sharedChatGptAuthBefore.auth_mode -eq 'chatgpt' -and
        (
          [string]$desktopAuthBefore.auth_mode -ne 'chatgpt' -or
          [string]$globalBefore.codex_cloud_access -eq 'disabled' -or
          [bool](Get-RaymanMapValue -Map $configBefore -Key 'conflict_detected' -Default $false)
        )
      ) {
        $desktopAuthPath = Get-RaymanCodexAuthFilePath -CodexHome $desktopHome
        Copy-Item -LiteralPath ([string]$sharedChatGptAuthBefore.path) -Destination $desktopAuthPath -Force
        $result.should_skip_login = $true
        $result.saved_token_reused = $true
        $result.saved_token_source = 'shared_chatgpt_backup'
        $result.reason = 'saved_token_reused'
      } elseif (
        [bool]$backupAuthBefore.present -and
        [string]$backupAuthBefore.auth_mode -eq 'chatgpt' -and
        (
          [string]$desktopAuthBefore.auth_mode -ne 'chatgpt' -or
          [string]$globalBefore.codex_cloud_access -eq 'disabled' -or
          [bool](Get-RaymanMapValue -Map $configBefore -Key 'conflict_detected' -Default $false)
        )
      ) {
        $desktopAuthPath = Get-RaymanCodexAuthFilePath -CodexHome $desktopHome
        Copy-Item -LiteralPath ([string]$backupAuthBefore.path) -Destination $desktopAuthPath -Force
        $result.should_skip_login = $true
        $result.saved_token_reused = $true
        $result.saved_token_source = 'desktop_backup'
        $result.reason = 'saved_token_reused'
      } elseif ([bool]$desktopAuthBefore.present -and [string]$desktopAuthBefore.auth_mode -eq 'chatgpt') {
        $result.should_skip_login = $true
        $result.saved_token_reused = $true
        $result.saved_token_source = 'desktop_auth'
        $result.reason = 'desktop_auth_reused'
      } else {
        $result.reason = 'no_saved_chatgpt_token'
      }
    } else {
      $result.reason = 'logout_first_requested'
    }

    $desktopAuthAfter = Get-RaymanCodexAuthFileSummary -CodexHome $desktopHome
    $configAfter = Get-RaymanCodexConfigState -CodexHome $desktopHome
    $globalAfter = Get-RaymanCodexDesktopGlobalStateSummary
    $result.config_conflict = [string](Get-RaymanMapValue -Map $configAfter -Key 'conflict_reason' -Default '')
    if ([bool]$aliasAuthBefore.present -and [string]$aliasAuthBefore.auth_mode -eq 'chatgpt' -and [string]$desktopAuthAfter.auth_mode -ne 'chatgpt') {
      $result.unsynced_reason = 'desktop_home_auth_unsynced'
      $result.prep_success = $false
    }
    if ([bool](Get-RaymanMapValue -Map $configAfter -Key 'conflict_detected' -Default $false) -or [string]$globalAfter.codex_cloud_access -eq 'disabled') {
      $result.prep_success = $false
    }

    return [pscustomobject]$result
  }

  if ($normalizedMode -in @('api', 'yunyi')) {
    $configPrep = Set-RaymanCodexDesktopConfigMode -Alias $Alias -DesktopCodexHome $desktopHome -Mode $normalizedMode
    $cloudPrep = Set-RaymanCodexDesktopCloudAccessState -DesktopCodexHome $desktopHome -CloudAccess 'disabled'
    $result.prep_success = ([bool]$configPrep.success -and [bool]$cloudPrep.success)
    $result.reason = if ([bool]$result.prep_success) { 'desktop_mode_prepared' } else { [string](Get-RaymanMapValue -Map $configPrep -Key 'reason' -Default 'desktop_mode_prepare_failed') }
    $configAfter = Get-RaymanCodexConfigState -CodexHome $desktopHome
    $activationState = Get-RaymanCodexDesktopApiActivationStatus -Mode $normalizedMode -DesktopConfigState $configAfter -DesktopAuthSummary $desktopAuthBefore -DesktopGlobalState (Get-RaymanCodexDesktopGlobalStateSummary)
    $result.config_conflict = [string](Get-RaymanMapValue -Map $activationState -Key 'config_conflict' -Default '')
  }

  return [pscustomobject]$result
}

function Resolve-RaymanCodexLoginTarget {
  param(
    [string]$WorkspaceRoot,
    [string]$Mode,
    [object]$Account
  )

  $aliasCodexHome = [string](Get-RaymanMapValue -Map $Account -Key 'codex_home' -Default '')
  $normalizedMode = Normalize-RaymanCodexAuthModeLast -Mode $Mode
  $authScope = Resolve-RaymanCodexAuthScopeForMode -WorkspaceRoot $WorkspaceRoot -Mode $Mode -ExistingScope ([string](Get-RaymanMapValue -Map $Account -Key 'auth_scope' -Default ''))
  if ((Test-RaymanCodexWindowsHost) -and $normalizedMode -eq 'web') {
    $authScope = 'desktop_global'
  }
  $desktopCodexHome = Get-RaymanCodexDesktopHomePath
  $effectiveCodexHome = if ($authScope -eq 'desktop_global' -and -not [string]::IsNullOrWhiteSpace([string]$desktopCodexHome)) {
    $desktopCodexHome
  } else {
    $aliasCodexHome
  }

  if (-not [string]::IsNullOrWhiteSpace([string]$effectiveCodexHome)) {
    Ensure-RaymanCodexAccountConfig -CodexHome $effectiveCodexHome | Out-Null
  }

  return [pscustomobject]@{
    auth_scope = $authScope
    codex_home = $effectiveCodexHome
    alias_codex_home = $aliasCodexHome
    desktop_codex_home = $desktopCodexHome
  }
}

function Invoke-RaymanCodexDesktopAliasActivation {
  param(
    [string]$WorkspaceRoot,
    [string]$Alias,
    [object]$Account,
    [string]$Mode
  )

  $normalizedMode = Normalize-RaymanCodexAuthModeLast -Mode $Mode
  $result = [ordered]@{
    attempted = $false
    applicable = ($normalizedMode -in @('web', 'api', 'yunyi'))
    success = $false
    reason = 'not_applicable'
    saved_token_reused = $false
    saved_token_source = ''
    status = $null
  }
  if (-not [bool]$result.applicable -or -not (Test-RaymanCodexWindowsHost)) {
    return [pscustomobject]$result
  }

  $desktopHome = Get-RaymanCodexDesktopHomePath
  if ([string]::IsNullOrWhiteSpace([string]$desktopHome)) {
    $result.reason = 'desktop_home_missing'
    return [pscustomobject]$result
  }

  $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $WorkspaceRoot
  $loginTarget = if ($normalizedMode -eq 'web') {
    Resolve-RaymanCodexLoginTarget -WorkspaceRoot $resolvedWorkspace -Mode $normalizedMode -Account $Account
  } else {
    [pscustomobject]@{
      auth_scope = 'desktop_global'
      codex_home = $desktopHome
      alias_codex_home = [string](Get-RaymanMapValue -Map $Account -Key 'codex_home' -Default '')
      desktop_codex_home = $desktopHome
    }
  }
  $result.attempted = $true

  $snapshot = New-RaymanCodexLoginSnapshot -WorkspaceRoot $resolvedWorkspace -Alias $Alias -LoginTarget $loginTarget
  $startedAt = (Get-Date).ToString('o')
  $desktopPreparation = Prepare-RaymanCodexDesktopLoginTarget -Alias $Alias -WorkspaceRoot $resolvedWorkspace -LoginTarget $loginTarget -Mode $normalizedMode
  if (-not [bool]$desktopPreparation.prep_success) {
    Restore-RaymanCodexLoginSnapshot -Snapshot $snapshot | Out-Null
    $result.reason = if ([string]::IsNullOrWhiteSpace([string]$desktopPreparation.unsynced_reason)) { [string]$desktopPreparation.reason } else { [string]$desktopPreparation.unsynced_reason }
    return [pscustomobject]$result
  }

  if ($normalizedMode -eq 'web') {
    if (-not [bool]$desktopPreparation.should_skip_login) {
      Restore-RaymanCodexLoginSnapshot -Snapshot $snapshot | Out-Null
      $result.reason = 'saved_chatgpt_token_missing'
      return [pscustomobject]$result
    }
    $result.saved_token_reused = [bool](Get-RaymanMapValue -Map $desktopPreparation -Key 'saved_token_reused' -Default $false)
    $result.saved_token_source = [string](Get-RaymanMapValue -Map $desktopPreparation -Key 'saved_token_source' -Default '')
  } else {
    $authSource = Resolve-RaymanCodexDesktopSavedApiAuthSource -WorkspaceRoot $resolvedWorkspace -Alias $Alias -LoginTarget $loginTarget -Mode $normalizedMode
    if (-not [bool]$authSource.available) {
      Restore-RaymanCodexLoginSnapshot -Snapshot $snapshot | Out-Null
      $result.reason = [string]$authSource.reason
      return [pscustomobject]$result
    }

    $desktopAuthPath = Get-RaymanCodexAuthFilePath -CodexHome $desktopHome
    if ([string]::IsNullOrWhiteSpace([string]$desktopAuthPath)) {
      Restore-RaymanCodexLoginSnapshot -Snapshot $snapshot | Out-Null
      $result.reason = 'desktop_auth_path_missing'
      return [pscustomobject]$result
    }

    Copy-Item -LiteralPath ([string]$authSource.path) -Destination $desktopAuthPath -Force
    $result.saved_token_reused = $true
    $result.saved_token_source = [string]$authSource.source
  }

  $validation = Invoke-RaymanCodexDesktopStatusValidation -WorkspaceRoot $resolvedWorkspace -Alias $Alias -DesktopCodexHome $desktopHome -StatusCommand (Get-RaymanCodexDesktopStatusCommand) -TargetMode $normalizedMode
  if (-not [bool]$validation.success) {
    $validationReason = [string](Get-RaymanMapValue -Map $validation -Key 'reason' -Default 'desktop_activation_failed')
    $desktopAuthChanged = Test-RaymanCodexLoginSnapshotItemChanged -SnapshotItem (Get-RaymanMapValue -Map $snapshot -Key 'desktop_auth' -Default $null)
    $desktopAuthAfterValidation = Get-RaymanCodexAuthFileSummary -CodexHome $desktopHome
    $isRecoverableWebValidation = (
      $normalizedMode -eq 'web' -and
      $validationReason -in @('desktop_window_not_found', 'desktop_response_timeout') -and
      [bool]$desktopAuthChanged -and
      [bool]$desktopAuthAfterValidation.present -and
      [string]$desktopAuthAfterValidation.auth_mode -eq 'chatgpt'
    )

    if ($isRecoverableWebValidation) {
      $softPassReason = switch ($validationReason) {
        'desktop_window_not_found' { 'desktop_window_not_found_soft_pass' }
        'desktop_response_timeout' { 'desktop_response_timeout_soft_pass' }
        default { 'desktop_web_validation_soft_pass' }
      }
      if ($null -eq $validation.PSObject.Properties['reason']) {
        $validation | Add-Member -NotePropertyName 'reason' -NotePropertyValue $softPassReason
      } else {
        $validation.reason = $softPassReason
      }
      if ($null -eq $validation.PSObject.Properties['desktop_unsynced_reason']) {
        $validation | Add-Member -NotePropertyName 'desktop_unsynced_reason' -NotePropertyValue ''
      } else {
        $validation.desktop_unsynced_reason = ''
      }
      Write-CodexWarn ("desktop activation status check failed ({0}), but new web auth is present; continuing without rollback for alias={1}." -f $validationReason, $Alias)
    } else {
      Restore-RaymanCodexLoginSnapshot -Snapshot $snapshot | Out-Null
      $result.reason = $validationReason
      return [pscustomobject]$result
    }
  }

  if ($normalizedMode -in @('api', 'yunyi')) {
    $desktopAuthPath = Get-RaymanCodexAuthFilePath -CodexHome $desktopHome
    $aliasAuthPath = Get-RaymanCodexAuthFilePath -CodexHome ([string](Get-RaymanMapValue -Map $loginTarget -Key 'alias_codex_home' -Default ''))
    if (
      -not [string]::IsNullOrWhiteSpace([string]$desktopAuthPath) -and
      -not [string]::IsNullOrWhiteSpace([string]$aliasAuthPath) -and
      (Test-Path -LiteralPath $desktopAuthPath -PathType Leaf)
    ) {
      Copy-Item -LiteralPath $desktopAuthPath -Destination $aliasAuthPath -Force
    }
    if ($normalizedMode -eq 'yunyi') {
      $yunyiConfigState = Get-RaymanCodexConfigState -CodexHome $desktopHome
      $yunyiBaseUrl = [string](Get-RaymanMapValue -Map $yunyiConfigState -Key 'yunyi_base_url' -Default '')
      if (-not [string]::IsNullOrWhiteSpace([string]$yunyiBaseUrl)) {
        Set-RaymanCodexAliasYunyiConfig -Alias $Alias -BaseUrl $yunyiBaseUrl | Out-Null
        Set-RaymanCodexAccountYunyiMetadata -Alias $Alias -BaseUrl $yunyiBaseUrl -SuccessAt (Get-Date).ToString('o') -ConfigReady $true -ReuseReason 'desktop_switch_activation' -BaseUrlSource ([string](Get-RaymanMapValue -Map $result -Key 'saved_token_source' -Default '')) | Out-Null
      }
    }
  }

  $finishedAt = (Get-Date).ToString('o')
  Set-RaymanCodexAccountLoginDiagnostics -Alias $Alias -LoginMode $normalizedMode -AuthScope 'desktop_global' -LaunchStrategy 'switch' -PromptClassification 'none' -StartedAt $startedAt -FinishedAt $finishedAt -Success $true -DesktopTargetMode $normalizedMode -DesktopSavedTokenReused ([bool]$result.saved_token_reused) -DesktopSavedTokenSource ([string]$result.saved_token_source) | Out-Null
  Set-RaymanCodexAccountDesktopStatusValidation -Alias $Alias -StatusCommand (Get-RaymanCodexDesktopStatusCommand) -QuotaVisible ([bool](Get-RaymanMapValue -Map $validation -Key 'quota_visible' -Default $false)) -Reason ([string](Get-RaymanMapValue -Map $validation -Key 'reason' -Default '')) -ConfigConflict ([string](Get-RaymanMapValue -Map $validation -Key 'desktop_config_conflict' -Default '')) -UnsyncedReason ([string](Get-RaymanMapValue -Map $validation -Key 'desktop_unsynced_reason' -Default '')) | Out-Null

  $result.success = $true
  $result.reason = 'desktop_activation_applied'
  $result.status = Get-RaymanCodexLoginStatus -WorkspaceRoot $resolvedWorkspace -AccountAlias $Alias -GuardStage 'codex.switch'
  return [pscustomobject]$result
}

function New-RaymanCodexLoginSnapshot {
  param(
    [string]$WorkspaceRoot,
    [string]$Alias,
    [object]$LoginTarget
  )

  $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $WorkspaceRoot
  $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
  $root = Join-Path $resolvedWorkspace ('.Rayman\runtime\codex_login_snapshot_' + $timestamp)
  New-Item -ItemType Directory -Force -Path $root | Out-Null

  $aliasAuthPath = Get-RaymanCodexAuthFilePath -CodexHome ([string](Get-RaymanMapValue -Map $LoginTarget -Key 'alias_codex_home' -Default ''))
  $desktopAuthPath = Get-RaymanCodexAuthFilePath -CodexHome ([string](Get-RaymanMapValue -Map $LoginTarget -Key 'desktop_codex_home' -Default ''))
  $desktopConfigPath = Get-RaymanCodexAccountConfigPath -CodexHome ([string](Get-RaymanMapValue -Map $LoginTarget -Key 'desktop_codex_home' -Default ''))
  $desktopGlobalStatePath = Get-RaymanCodexDesktopGlobalStatePath
  $items = @(
    [pscustomobject]@{ key = 'alias_auth'; source = $aliasAuthPath; snapshot = (Join-Path $root 'alias_auth.pre.json') }
    [pscustomobject]@{ key = 'desktop_auth'; source = $desktopAuthPath; snapshot = (Join-Path $root 'desktop_auth.pre.json') }
    [pscustomobject]@{ key = 'desktop_config'; source = $desktopConfigPath; snapshot = (Join-Path $root 'desktop_config.pre.toml') }
    [pscustomobject]@{ key = 'desktop_global_state'; source = $desktopGlobalStatePath; snapshot = (Join-Path $root 'desktop_global_state.pre.json') }
  )

  $states = [ordered]@{}
  foreach ($item in $items) {
    $present = (-not [string]::IsNullOrWhiteSpace([string]$item.source) -and (Test-Path -LiteralPath $item.source -PathType Leaf))
    if ($present) {
      Copy-Item -LiteralPath $item.source -Destination $item.snapshot -Force
    }

    $states[[string]$item.key] = [ordered]@{
      source_path = [string]$item.source
      snapshot_path = [string]$item.snapshot
      present = $present
    }
  }

  return [pscustomobject]@{
    snapshot_root = $root
    alias = $Alias
    auth_scope = [string](Get-RaymanMapValue -Map $LoginTarget -Key 'auth_scope' -Default '')
    alias_auth = $states['alias_auth']
    desktop_auth = $states['desktop_auth']
    desktop_config = $states['desktop_config']
    desktop_global_state = $states['desktop_global_state']
  }
}

function Restore-RaymanCodexLoginSnapshot {
  param(
    [object]$Snapshot
  )

  if ($null -eq $Snapshot) {
    return [pscustomobject]@{
      restored = $false
      restored_paths = @()
    }
  }

  $restoredPaths = New-Object System.Collections.Generic.List[string]
  foreach ($item in @(
      Get-RaymanMapValue -Map $Snapshot -Key 'alias_auth' -Default $null
      Get-RaymanMapValue -Map $Snapshot -Key 'desktop_auth' -Default $null
      Get-RaymanMapValue -Map $Snapshot -Key 'desktop_config' -Default $null
      Get-RaymanMapValue -Map $Snapshot -Key 'desktop_global_state' -Default $null
    )) {
    if ($null -eq $item) { continue }
    $sourcePath = [string](Get-RaymanMapValue -Map $item -Key 'source_path' -Default '')
    $snapshotPath = [string](Get-RaymanMapValue -Map $item -Key 'snapshot_path' -Default '')
    $present = [bool](Get-RaymanMapValue -Map $item -Key 'present' -Default $false)
    if ([string]::IsNullOrWhiteSpace($sourcePath)) { continue }

    if ($present -and -not [string]::IsNullOrWhiteSpace($snapshotPath) -and (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) {
      Copy-Item -LiteralPath $snapshotPath -Destination $sourcePath -Force
      $restoredPaths.Add($sourcePath) | Out-Null
      continue
    }

    if (-not $present -and (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
      Remove-Item -LiteralPath $sourcePath -Force -ErrorAction SilentlyContinue
      $restoredPaths.Add($sourcePath) | Out-Null
    }
  }

  return [pscustomobject]@{
    restored = (@($restoredPaths.ToArray()).Count -gt 0)
    restored_paths = @($restoredPaths.ToArray())
  }
}

function Test-RaymanCodexLoginSnapshotItemChanged {
  param(
    [object]$SnapshotItem
  )

  if ($null -eq $SnapshotItem) {
    return $false
  }

  $sourcePath = [string](Get-RaymanMapValue -Map $SnapshotItem -Key 'source_path' -Default '')
  $snapshotPath = [string](Get-RaymanMapValue -Map $SnapshotItem -Key 'snapshot_path' -Default '')
  $present = [bool](Get-RaymanMapValue -Map $SnapshotItem -Key 'present' -Default $false)
  $sourceExists = (-not [string]::IsNullOrWhiteSpace([string]$sourcePath) -and (Test-Path -LiteralPath $sourcePath -PathType Leaf))

  if ($present -ne $sourceExists) {
    return $true
  }

  if (-not $present -and -not $sourceExists) {
    return $false
  }

  if ([string]::IsNullOrWhiteSpace([string]$snapshotPath) -or -not (Test-Path -LiteralPath $snapshotPath -PathType Leaf) -or -not $sourceExists) {
    return $true
  }

  try {
    $beforeHash = (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash
    $afterHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
    return ($beforeHash -ne $afterHash)
  } catch {
    return $true
  }
}

function Invoke-RaymanCodexDesktopStatusValidation {
  param(
    [string]$WorkspaceRoot,
    [string]$Alias,
    [string]$DesktopCodexHome,
    [string]$StatusCommand = '/status',
    [string]$TargetMode = '',
    [int]$TimeoutSeconds = 15
  )

  $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $WorkspaceRoot
  $reportPath = Get-RaymanCodexDesktopStatusValidationReportPath -WorkspaceRoot $resolvedWorkspace
  $runtimeDir = Split-Path -Parent $reportPath
  if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
  }

  $desktopHome = if ([string]::IsNullOrWhiteSpace([string]$DesktopCodexHome)) { Get-RaymanCodexDesktopHomePath } else { [string]$DesktopCodexHome }
  $globalState = Get-RaymanCodexDesktopGlobalStateSummary
  $desktopAuthPath = Get-RaymanCodexAuthFilePath -CodexHome $desktopHome
  $aliasAuthSummary = Get-RaymanCodexAuthFileSummary -Alias $Alias
  $desktopAuthSummary = Get-RaymanCodexAuthFileSummary -CodexHome $desktopHome
  $desktopConfigState = Get-RaymanCodexConfigState -CodexHome $desktopHome
  $normalizedTargetMode = Normalize-RaymanCodexAuthModeLast -Mode $TargetMode
  $sessionBefore = Get-RaymanCodexDesktopLatestWorkspaceSession -WorkspaceRoot $resolvedWorkspace
  $tailBefore = if ([bool]$sessionBefore.available) { Get-RaymanCodexDesktopSessionTailText -SessionPath ([string]$sessionBefore.session_path) } else { '' }

  $inspectPath = Join-Path $runtimeDir 'codex.desktop.pre.inspect.json'
  $treeTextPath = [System.IO.Path]::ChangeExtension($inspectPath, '.txt')
  $flowPath = Join-Path $runtimeDir 'codex.desktop.status.flow.json'
  $inspectScriptPath = Join-Path $resolvedWorkspace '.Rayman\scripts\windows\inspect_winapp.ps1'
  $flowScriptPath = Join-Path $resolvedWorkspace '.Rayman\scripts\windows\run_winapp_flow.ps1'
  $psHost = Resolve-RaymanPowerShellHost
  $currentUnsyncedReason = ''
  if ([bool]$aliasAuthSummary.present -and [string]$aliasAuthSummary.auth_mode -eq 'chatgpt' -and [string]$desktopAuthSummary.auth_mode -ne 'chatgpt') {
    $currentUnsyncedReason = 'desktop_home_auth_unsynced'
  }
  $desktopApiActivation = Get-RaymanCodexDesktopApiActivationStatus -Mode $normalizedTargetMode -DesktopConfigState $desktopConfigState -DesktopAuthSummary $desktopAuthSummary -DesktopGlobalState $globalState
  if ([bool]$desktopApiActivation.applicable) {
    $report = [ordered]@{
      schema = 'rayman.codex.desktop.status.validation.v1'
      generated_at = (Get-Date).ToString('o')
      workspace_root = $resolvedWorkspace
      alias = $Alias
      success = [bool]$desktopApiActivation.ready
      reason = [string]$desktopApiActivation.reason
      status_command = $StatusCommand
      quota_visible = $false
      desktop_codex_home = $desktopHome
      desktop_auth_present = (Test-Path -LiteralPath $desktopAuthPath -PathType Leaf)
      desktop_global_cloud_access = [string]$globalState.codex_cloud_access
      desktop_config_conflict = [string](Get-RaymanMapValue -Map $desktopApiActivation -Key 'config_conflict' -Default '')
      desktop_unsynced_reason = if ([bool]$desktopApiActivation.ready) { '' } else { [string](Get-RaymanMapValue -Map $desktopApiActivation -Key 'auth_reason' -Default '') }
      session_before = $sessionBefore
      session_after = $sessionBefore
      inspect_json_path = ''
      inspect_text_path = ''
      flow_path = ''
      flow_result = $null
      rollout_tail = $tailBefore
    }
    Write-RaymanUtf8NoBom -Path $reportPath -Content ((($report | ConvertTo-Json -Depth 12).TrimEnd()) + "`n")
    return [pscustomobject]$report
  }

  if ([string]::IsNullOrWhiteSpace([string]$psHost)) {
    $report = [ordered]@{
      schema = 'rayman.codex.desktop.status.validation.v1'
      generated_at = (Get-Date).ToString('o')
      workspace_root = $resolvedWorkspace
      alias = $Alias
      success = $false
      reason = 'powershell_host_missing'
      status_command = $StatusCommand
      quota_visible = $false
      desktop_codex_home = $desktopHome
      desktop_auth_present = (Test-Path -LiteralPath $desktopAuthPath -PathType Leaf)
      desktop_global_cloud_access = [string]$globalState.codex_cloud_access
      desktop_config_conflict = [string](Get-RaymanMapValue -Map $desktopConfigState -Key 'conflict_reason' -Default '')
      desktop_unsynced_reason = [string]$currentUnsyncedReason
      session_before = $sessionBefore
      session_after = $null
      inspect_json_path = ''
      inspect_text_path = ''
      flow_path = ''
      flow_result = $null
      rollout_tail = ''
    }
    Write-RaymanUtf8NoBom -Path $reportPath -Content ((($report | ConvertTo-Json -Depth 12).TrimEnd()) + "`n")
    return [pscustomobject]$report
  }

  if (-not (Test-Path -LiteralPath $inspectScriptPath -PathType Leaf) -or -not (Test-Path -LiteralPath $flowScriptPath -PathType Leaf)) {
    $heuristicQuotaVisible = $false
    $heuristicReason = 'desktop_status_quota_missing'
    if (-not [string]::IsNullOrWhiteSpace([string]$currentUnsyncedReason)) {
      $heuristicReason = [string]$currentUnsyncedReason
    } elseif ([bool](Get-RaymanMapValue -Map $desktopConfigState -Key 'conflict_detected' -Default $false)) {
      $heuristicReason = 'desktop_status_quota_missing'
    } elseif ([string]$globalState.codex_cloud_access -eq 'disabled') {
      $heuristicReason = 'desktop_cloud_access_disabled'
    } elseif ([string]$desktopAuthSummary.auth_mode -eq 'chatgpt') {
      $heuristicQuotaVisible = $true
      $heuristicReason = 'quota_visible'
    }

    $report = [ordered]@{
      schema = 'rayman.codex.desktop.status.validation.v1'
      generated_at = (Get-Date).ToString('o')
      workspace_root = $resolvedWorkspace
      alias = $Alias
      success = $heuristicQuotaVisible
      reason = $heuristicReason
      status_command = $StatusCommand
      quota_visible = $heuristicQuotaVisible
      desktop_codex_home = $desktopHome
      desktop_auth_present = (Test-Path -LiteralPath $desktopAuthPath -PathType Leaf)
      desktop_global_cloud_access = [string]$globalState.codex_cloud_access
      desktop_config_conflict = [string](Get-RaymanMapValue -Map $desktopConfigState -Key 'conflict_reason' -Default '')
      desktop_unsynced_reason = [string]$currentUnsyncedReason
      session_before = $sessionBefore
      session_after = $sessionBefore
      inspect_json_path = ''
      inspect_text_path = ''
      flow_path = ''
      flow_result = $null
      rollout_tail = $tailBefore
    }
    Write-RaymanUtf8NoBom -Path $reportPath -Content ((($report | ConvertTo-Json -Depth 12).TrimEnd()) + "`n")
    return [pscustomobject]$report
  }

  $inspectResult = $null
  try {
    $inspectRaw = & $psHost -NoProfile -ExecutionPolicy Bypass -File $inspectScriptPath -WorkspaceRoot $resolvedWorkspace -WindowTitleRegex '.*Codex.*' -TimeoutSeconds 5 -MaxDepth 8 -OutFile $inspectPath -Json
    $inspectResult = ConvertFrom-RaymanJsonText -Text ([string]$inspectRaw)
  } catch {
    $inspectResult = [pscustomobject]@{
      success = $false
      reason = 'inspect_failed'
      detail = $_.Exception.Message
      json_path = $inspectPath
      text_path = $treeTextPath
    }
  }

  $treeText = if (Test-Path -LiteralPath $treeTextPath -PathType Leaf) { Get-Content -LiteralPath $treeTextPath -Raw -Encoding UTF8 } else { '' }
  if (Test-RaymanCodexDesktopThreadBlockedText -Text ($tailBefore + [Environment]::NewLine + $treeText)) {
    $report = [ordered]@{
      schema = 'rayman.codex.desktop.status.validation.v1'
      generated_at = (Get-Date).ToString('o')
      workspace_root = $resolvedWorkspace
      alias = $Alias
      success = $false
      reason = 'desktop_thread_blocked'
      status_command = $StatusCommand
      quota_visible = $false
      desktop_codex_home = $desktopHome
      desktop_auth_present = (Test-Path -LiteralPath $desktopAuthPath -PathType Leaf)
      desktop_global_cloud_access = [string]$globalState.codex_cloud_access
      desktop_config_conflict = [string](Get-RaymanMapValue -Map $desktopConfigState -Key 'conflict_reason' -Default '')
      desktop_unsynced_reason = ''
      session_before = $sessionBefore
      session_after = $sessionBefore
      inspect_json_path = if ($null -ne $inspectResult) { [string](Get-RaymanMapValue -Map $inspectResult -Key 'json_path' -Default '') } else { '' }
      inspect_text_path = if ($null -ne $inspectResult) { [string](Get-RaymanMapValue -Map $inspectResult -Key 'text_path' -Default '') } else { '' }
      flow_path = ''
      flow_result = $null
      rollout_tail = $tailBefore
    }
    Write-RaymanUtf8NoBom -Path $reportPath -Content ((($report | ConvertTo-Json -Depth 12).TrimEnd()) + "`n")
    return [pscustomobject]$report
  }

  $flow = [ordered]@{
    schema = 'rayman.winapp.flow.v1'
    target = [ordered]@{
      process_name = 'Codex'
      window_title_regex = '.*Codex.*'
    }
    default_timeout_ms = 15000
    steps = @(
      [ordered]@{ action = 'wait_window'; process_name = 'Codex'; window_title_regex = '.*Codex.*' }
      [ordered]@{ action = 'focus' }
      [ordered]@{ action = 'send_keys'; keys = '{ESC}' }
      [ordered]@{ action = 'type'; text = $StatusCommand }
      [ordered]@{ action = 'send_keys'; keys = '{ENTER}' }
      [ordered]@{ action = 'screenshot'; file_name = 'codex-desktop-status.png' }
    )
  }
  Write-RaymanUtf8NoBom -Path $flowPath -Content ((($flow | ConvertTo-Json -Depth 12).TrimEnd()) + "`n")

  $flowResult = $null
  try {
    $flowRaw = & $psHost -NoProfile -ExecutionPolicy Bypass -File $flowScriptPath -WorkspaceRoot $resolvedWorkspace -FlowFile $flowPath -Require -Json
    $flowResult = ConvertFrom-RaymanJsonText -Text ([string]$flowRaw)
  } catch {
    $flowResult = [pscustomobject]@{
      success = $false
      degraded = $false
      degraded_reason = ''
      error_message = $_.Exception.Message
      detail_log = ''
      artifacts = [pscustomobject]@{
        screenshots_dir = ''
        last_result_json = ''
        readiness_json = ''
      }
      steps = @()
    }
  }

  $deadline = (Get-Date).AddSeconds([Math]::Max(5, $TimeoutSeconds))
  $sessionAfter = $sessionBefore
  $rolloutTail = $tailBefore
  $quotaVisible = $false
  do {
    $sessionAfter = Get-RaymanCodexDesktopLatestWorkspaceSession -WorkspaceRoot $resolvedWorkspace
    if ([bool]$sessionAfter.available) {
      $rolloutTail = Get-RaymanCodexDesktopSessionTailText -SessionPath ([string]$sessionAfter.session_path)
      if (Test-RaymanCodexDesktopQuotaVisible -Text $rolloutTail) {
        $quotaVisible = $true
        break
      }
    }
    Start-Sleep -Milliseconds 500
  } while ((Get-Date) -lt $deadline)

  $desktopAuthSummaryAfter = Get-RaymanCodexAuthFileSummary -CodexHome $desktopHome
  $desktopConfigStateAfter = Get-RaymanCodexConfigState -CodexHome $desktopHome
  $desktopUnsyncedReason = ''
  if ([bool]$aliasAuthSummary.present -and [string]$aliasAuthSummary.auth_mode -eq 'chatgpt' -and [string]$desktopAuthSummaryAfter.auth_mode -ne 'chatgpt') {
    $desktopUnsyncedReason = 'desktop_home_auth_unsynced'
  }

  $reason = if ($quotaVisible) {
    'quota_visible'
  } elseif (-not [string]::IsNullOrWhiteSpace([string]$desktopUnsyncedReason)) {
    $desktopUnsyncedReason
  } elseif (Test-RaymanCodexDesktopThreadBlockedText -Text $rolloutTail) {
    'desktop_thread_blocked'
  } elseif ([string]$globalState.codex_cloud_access -eq 'disabled') {
    'desktop_cloud_access_disabled'
  } elseif (-not [bool](Get-RaymanMapValue -Map $flowResult -Key 'success' -Default $false)) {
    $flowError = [string](Get-RaymanMapValue -Map $flowResult -Key 'error_message' -Default '')
    if ($flowError -match 'target window|wait_window failed|window') { 'desktop_window_not_found' } else { 'desktop_response_timeout' }
  } else {
    'desktop_status_quota_missing'
  }

  $report = [ordered]@{
    schema = 'rayman.codex.desktop.status.validation.v1'
    generated_at = (Get-Date).ToString('o')
    workspace_root = $resolvedWorkspace
    alias = $Alias
    success = $quotaVisible
    reason = $reason
    status_command = $StatusCommand
    quota_visible = $quotaVisible
    desktop_codex_home = $desktopHome
    desktop_auth_present = (Test-Path -LiteralPath $desktopAuthPath -PathType Leaf)
    desktop_global_cloud_access = [string]$globalState.codex_cloud_access
    desktop_config_conflict = [string](Get-RaymanMapValue -Map $desktopConfigStateAfter -Key 'conflict_reason' -Default '')
    desktop_unsynced_reason = [string]$desktopUnsyncedReason
    session_before = $sessionBefore
    session_after = $sessionAfter
    inspect_json_path = if ($null -ne $inspectResult) { [string](Get-RaymanMapValue -Map $inspectResult -Key 'json_path' -Default '') } else { '' }
    inspect_text_path = if ($null -ne $inspectResult) { [string](Get-RaymanMapValue -Map $inspectResult -Key 'text_path' -Default '') } else { '' }
    flow_path = $flowPath
    flow_result = $flowResult
    rollout_tail = $rolloutTail
  }

  Write-RaymanUtf8NoBom -Path $reportPath -Content ((($report | ConvertTo-Json -Depth 12).TrimEnd()) + "`n")
  return [pscustomobject]$report
}

function Invoke-CodexAliasInteractiveLogin {
  param(
    [string]$Alias,
    [string]$CodexHome,
    [string]$WorkingDirectory,
    [string[]]$ArgumentList,
    [string]$StartMessage,
    [string]$FallbackMessage,
    [hashtable]$EnvironmentOverrides = @{},
    [string]$Mode = '',
    [switch]$LoginSmoke
  )

  $strategy = Resolve-RaymanCodexInteractiveLoginStrategy -WorkspaceRoot $WorkingDirectory -Mode $Mode
  $overridePlan = Resolve-RaymanCodexLoginConfigOverrides -Mode $Mode -WorkspaceRoot $WorkingDirectory -CodexHome $CodexHome
  $effectiveArgs = @()
  if ([bool]$overridePlan.supported -and @($overridePlan.config_args).Count -gt 0) {
    $effectiveArgs += @($overridePlan.config_args)
  }
  $effectiveArgs += @($ArgumentList)

  if (-not [string]::IsNullOrWhiteSpace($StartMessage)) {
    Write-CodexInfo $StartMessage
  }
  Write-CodexInfo ("after browser approval, tell the agent: 已授权 {0}" -f $Alias)

  $startedAt = Get-Date
  $fallbackUsed = $false
  $result = Invoke-RaymanCodexRawInteractive -CodexHome $CodexHome -WorkingDirectory $WorkingDirectory -ArgumentList @($effectiveArgs) -PreferHiddenWindow:([bool]$strategy.prefer_hidden) -EnvironmentOverrides $EnvironmentOverrides
  if ((-not [bool]$result.success) -and [bool]$strategy.allow_fallback) {
    Write-CodexWarn $FallbackMessage
    $fallbackUsed = $true
    $result = Invoke-RaymanCodexRawInteractive -CodexHome $CodexHome -WorkingDirectory $WorkingDirectory -ArgumentList @($effectiveArgs) -EnvironmentOverrides $EnvironmentOverrides
  }
  $finishedAt = Get-Date
  $classificationSource = if ($result.PSObject.Properties['output'] -and -not [string]::IsNullOrWhiteSpace([string]$result.output)) {
    [string]$result.output
  } elseif ($result.PSObject.Properties['error']) {
    [string]$result.error
  } else {
    ''
  }

  return [pscustomobject]@{
    success = [bool]$result.success
    exit_code = [int]$result.exit_code
    command = if ($result.PSObject.Properties['command']) { [string]$result.command } else { ('codex ' + (($effectiveArgs | ForEach-Object { [string]$_ }) -join ' ')).Trim() }
    error = if ($result.PSObject.Properties['error']) { [string]$result.error } else { '' }
    output = if ($result.PSObject.Properties['output']) { [string]$result.output } else { '' }
    output_captured = if ($result.PSObject.Properties['output_captured']) { [bool]$result.output_captured } else { $false }
    launch_strategy = if ($fallbackUsed) { 'hidden_then_foreground' } else { [string]$strategy.strategy }
    fallback_used = $fallbackUsed
    fallback_suppressed = [bool]$strategy.fallback_suppressed
    override_keys = @($overridePlan.keys | ForEach-Object { [string]$_ })
    overrides_requested = (@($overridePlan.keys).Count -gt 0)
    overrides_applied = [bool]$overridePlan.supported
    override_skipped_reason = [string]$overridePlan.skipped_reason
    override_probe = $overridePlan.probe
    prompt_classification = Get-RaymanCodexLoginPromptClassification -Text $classificationSource
    mode = [string]$Mode
    started_at = $startedAt.ToString('o')
    finished_at = $finishedAt.ToString('o')
    duration_ms = [int][Math]::Max(0, [Math]::Round(($finishedAt - $startedAt).TotalMilliseconds))
  }
}

function Invoke-CodexAliasNativeLogin {
  param(
    [string]$Alias,
    [string]$TargetWorkspaceRoot,
    [string]$Profile = '',
    [switch]$SetDefaultProfile,
    [ValidateSet('web', 'device', 'api', 'yunyi')][string]$Mode = 'device',
    [switch]$ApiKeyFromStdin,
    [switch]$LogoutFirst,
    [int]$DeviceAuthStaleAfterSeconds = 180,
    [switch]$LoginSmoke,
    [switch]$Force
  )

  $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $TargetWorkspaceRoot
  $normalizedAlias = Normalize-RaymanCodexAlias -Alias $Alias
  Ensure-CodexCliReady -WorkspaceRoot $resolvedWorkspace -AccountAlias $normalizedAlias -AutoUpdatePolicyOverride 'compatibility' | Out-Null
  $account = Ensure-RaymanCodexAccount -Alias $normalizedAlias -DefaultProfile $Profile -SetDefaultProfile:$SetDefaultProfile
  $loginTarget = Resolve-RaymanCodexLoginTarget -WorkspaceRoot $resolvedWorkspace -Mode $Mode -Account $account
  $desktopGlobalState = Get-RaymanCodexDesktopGlobalStateSummary
  $smokeSummary = $null
  $yunyiBaseUrlChoice = $null
  $yunyiApiKeyForSync = ''
  $snapshot = $null
  if ($Mode -eq 'yunyi') {
    $yunyiBaseUrlChoice = Resolve-CodexYunyiBaseUrlChoice -Alias $normalizedAlias -WorkspaceRoot $resolvedWorkspace
    $yunyiApiKey = Get-CodexYunyiApiKeyInput -WorkspaceRoot $resolvedWorkspace -FromStdin:$ApiKeyFromStdin
    $yunyiApiKeyForSync = [string]$yunyiApiKey
    if ([string]::IsNullOrWhiteSpace([string]$yunyiApiKey)) {
      Exit-CodexError 'Yunyi API key cannot be empty.'
    }

    $seededYunyiState = Sync-RaymanCodexUserHomeYunyiState -WorkspaceRoot $resolvedWorkspace -BaseUrl ([string]$yunyiBaseUrlChoice.base_url) -ApiKey $yunyiApiKeyForSync -BackupTomlSourcePath $(if ([string](Get-RaymanMapValue -Map $yunyiBaseUrlChoice -Key 'path' -Default '') -match '\.toml$') { [string]$yunyiBaseUrlChoice.path } else { '' })
    if ($null -ne $seededYunyiState -and -not [bool]$seededYunyiState.success) {
      Write-CodexWarn ("Yunyi desktop seed state incomplete for alias={0}; login will continue with the available config." -f $normalizedAlias)
    }
  }
  if ((Test-RaymanCodexWindowsHost) -and [string]$loginTarget.auth_scope -eq 'desktop_global') {
    $snapshot = New-RaymanCodexLoginSnapshot -WorkspaceRoot $resolvedWorkspace -Alias $normalizedAlias -LoginTarget $loginTarget
  }
  if ($LoginSmoke) {
    if ($Mode -notin @('web', 'device')) {
      Exit-CodexError 'codex login-smoke only supports web or device mode.'
    }
    $smokeSummary = Register-RaymanCodexLoginSmokeAttempt -WorkspaceRoot $resolvedWorkspace -Alias $normalizedAlias -Mode $Mode
  }

  if ($LogoutFirst) {
    $logout = Invoke-RaymanCodexLogoutBestEffort -CodexHome ([string]$loginTarget.codex_home) -WorkingDirectory $resolvedWorkspace
    if ([bool]$logout.not_logged_in) {
      Write-CodexInfo ("alias={0} was already logged out before relogin." -f $normalizedAlias)
    } elseif ([bool]$logout.success) {
      Write-CodexInfo ("cleared existing auth state for alias={0} before relogin." -f $normalizedAlias)
    } else {
      Write-CodexWarn ("best-effort logout before relogin failed for alias={0}: {1}" -f $normalizedAlias, [string]$logout.output)
    }
  }

  $desktopPreparation = Prepare-RaymanCodexDesktopLoginTarget -Alias $normalizedAlias -WorkspaceRoot $resolvedWorkspace -LoginTarget $loginTarget -Mode $Mode -LogoutFirst:$LogoutFirst
  $desktopGlobalState = Get-RaymanCodexDesktopGlobalStateSummary
  if (-not [bool]$desktopPreparation.prep_success) {
    $errorMessage = if ([string]::IsNullOrWhiteSpace([string]$desktopPreparation.unsynced_reason)) { [string]$desktopPreparation.reason } else { [string]$desktopPreparation.unsynced_reason }
    if ($null -ne $snapshot) {
      Restore-RaymanCodexLoginSnapshot -Snapshot $snapshot | Out-Null
      $desktopGlobalState = Get-RaymanCodexDesktopGlobalStateSummary
    }
    $result = [pscustomobject]@{
      success = $false
      exit_code = 5
      command = 'desktop-mode-preparation'
      launch_strategy = 'repair'
      fallback_used = $false
      fallback_suppressed = $true
      prompt_classification = if ([string]::IsNullOrWhiteSpace($errorMessage)) { 'desktop_prepare_failed' } else { [string]$errorMessage }
      overrides_requested = $false
      overrides_applied = $false
      override_keys = @()
      override_skipped_reason = 'desktop_prepare_failed'
      override_probe = $null
      output_captured = $true
      output = [string]$errorMessage
      error = [string]$errorMessage
      started_at = ''
      finished_at = ''
      duration_ms = 0
    }
  } elseif ([bool]$desktopPreparation.should_skip_login) {
    $result = [pscustomobject]@{
      success = $true
      exit_code = 0
      command = 'saved-chatgpt-desktop-repair'
      launch_strategy = 'repair'
      fallback_used = $false
      fallback_suppressed = $true
      prompt_classification = 'none'
      overrides_requested = $false
      overrides_applied = $false
      override_keys = @()
      override_skipped_reason = 'saved_chatgpt_token_reused'
      override_probe = $null
      output_captured = $true
      output = if ([string]::IsNullOrWhiteSpace([string]$desktopPreparation.saved_token_source)) { 'Reused saved ChatGPT desktop auth' } else { ('Reused saved ChatGPT auth from {0}' -f [string]$desktopPreparation.saved_token_source) }
      error = ''
      started_at = ''
      finished_at = ''
      duration_ms = 0
    }
  } else {

    switch ($Mode) {
      'device' {
        Invoke-CodexDeviceAuthPreflight -Alias $normalizedAlias -StaleAfterSeconds $DeviceAuthStaleAfterSeconds | Out-Null
        $envOverrides = Get-CodexLoginEnvironmentOverrides -Mode 'device' -WorkspaceRoot $resolvedWorkspace
        $result = Invoke-CodexAliasInteractiveLogin -Alias $normalizedAlias -CodexHome ([string]$loginTarget.codex_home) -WorkingDirectory $resolvedWorkspace -ArgumentList @('login', '--device-auth') -StartMessage ("starting device auth for alias={0}" -f $normalizedAlias) -FallbackMessage 'hidden device auth launch failed; retrying with the legacy foreground flow.' -EnvironmentOverrides $envOverrides -Mode 'device' -LoginSmoke:$LoginSmoke
        break
      }
      'web' {
        $envOverrides = Get-CodexLoginEnvironmentOverrides -Mode 'web' -WorkspaceRoot $resolvedWorkspace
        $result = Invoke-CodexAliasInteractiveLogin -Alias $normalizedAlias -CodexHome ([string]$loginTarget.codex_home) -WorkingDirectory $resolvedWorkspace -ArgumentList @('login') -StartMessage ("starting web login for alias={0} auth_scope={1}" -f $normalizedAlias, [string]$loginTarget.auth_scope) -FallbackMessage 'hidden web login launch failed; retrying with the legacy foreground flow.' -EnvironmentOverrides $envOverrides -Mode 'web' -LoginSmoke:$LoginSmoke
        break
      }
      'api' {
        $environmentApiKeyState = $null
        $apiEnvironmentOverrides = Get-CodexLoginEnvironmentOverrides -Mode 'api' -WorkspaceRoot $resolvedWorkspace
        if (-not $ApiKeyFromStdin) {
          $environmentApiKeyState = Get-RaymanCodexEnvironmentApiKeyState -WorkspaceRoot $resolvedWorkspace
        }

        if ($null -ne $environmentApiKeyState -and [bool]$environmentApiKeyState.available -and [string]$loginTarget.auth_scope -ne 'desktop_global') {
          Write-CodexInfo ("using API key from {0} for alias={1}" -f [string]$environmentApiKeyState.source, $normalizedAlias)
          $result = [pscustomobject]@{
            success = $true
            exit_code = 0
            output = 'Using environment-backed OPENAI_API_KEY'
            stdout = @()
            stderr = @()
            command = 'environment-backed OPENAI_API_KEY'
            error = ''
          }
        } else {
          $apiKey = if ($null -ne $environmentApiKeyState -and [bool]$environmentApiKeyState.available) { [string]$environmentApiKeyState.value } else { Get-CodexApiKeyInput -FromStdin:$ApiKeyFromStdin }
          Write-CodexInfo ("starting API key login for alias={0}" -f $normalizedAlias)
          $result = Invoke-RaymanCodexRawCaptureWithStdin -CodexHome ([string]$loginTarget.codex_home) -WorkingDirectory $resolvedWorkspace -ArgumentList @('login', '--with-api-key') -StdinText $apiKey -EnvironmentOverrides $apiEnvironmentOverrides
          $apiKey = ''
        }
        break
      }
      'yunyi' {
        $yunyiBaseUrl = [string]$yunyiBaseUrlChoice.base_url
        $yunyiApiKey = [string]$yunyiApiKeyForSync
        $yunyiApiKeyForSync = [string]$yunyiApiKey
        $yunyiEnvironmentOverrides = Get-CodexLoginEnvironmentOverrides -Mode 'yunyi' -WorkspaceRoot $resolvedWorkspace -YunyiBaseUrl $yunyiBaseUrl
        if ([string]::IsNullOrWhiteSpace([string]$yunyiApiKey)) {
          Exit-CodexError 'Yunyi API key cannot be empty.'
        }

        if ([bool]$yunyiBaseUrlChoice.reused) {
          Write-CodexInfo ("reusing Yunyi config for alias={0} base_url={1} source={2} reason={3}" -f $normalizedAlias, $yunyiBaseUrl, [string]$yunyiBaseUrlChoice.source, [string]$yunyiBaseUrlChoice.reuse_reason)
        } else {
          Write-CodexWarn ("no reusable Yunyi config for alias={0}; using base_url from {1} ({2})." -f $normalizedAlias, [string]$yunyiBaseUrlChoice.source, [string]$yunyiBaseUrlChoice.fallback_reason)
        }
        Write-CodexInfo ("starting Yunyi API login for alias={0} base_url={1}" -f $normalizedAlias, $yunyiBaseUrl)
        $result = Invoke-RaymanCodexRawCaptureWithStdin -CodexHome ([string]$loginTarget.codex_home) -WorkingDirectory $resolvedWorkspace -ArgumentList @('login', '--with-api-key') -StdinText $yunyiApiKey -EnvironmentOverrides $yunyiEnvironmentOverrides
        $yunyiApiKey = ''
        break
      }
    }
  }

  $loginReport = [ordered]@{
    schema = 'rayman.codex.login.last.v1'
    generated_at = (Get-Date).ToString('o')
    workspace_root = $resolvedWorkspace
    alias = $normalizedAlias
    mode = $Mode
    desktop_target_mode = if ([string]$loginTarget.auth_scope -eq 'desktop_global') { (Normalize-RaymanCodexAuthModeLast -Mode $Mode) } else { '' }
    auth_scope = [string]$loginTarget.auth_scope
    alias_codex_home = [string]$loginTarget.alias_codex_home
    desktop_codex_home = [string]$loginTarget.desktop_codex_home
    desktop_auth_present = (-not [string]::IsNullOrWhiteSpace([string](Get-RaymanCodexAuthFilePath -CodexHome ([string]$loginTarget.desktop_codex_home))) -and (Test-Path -LiteralPath (Get-RaymanCodexAuthFilePath -CodexHome ([string]$loginTarget.desktop_codex_home)) -PathType Leaf))
    desktop_global_cloud_access = [string]$desktopGlobalState.codex_cloud_access
    desktop_saved_token_reused = [bool](Get-RaymanMapValue -Map $desktopPreparation -Key 'saved_token_reused' -Default $false)
    desktop_saved_token_source = [string](Get-RaymanMapValue -Map $desktopPreparation -Key 'saved_token_source' -Default '')
    desktop_status_command = (Get-RaymanCodexDesktopStatusCommand)
    desktop_status_quota_visible = $false
    desktop_status_reason = 'not_run'
    desktop_config_conflict = [string](Get-RaymanMapValue -Map $desktopPreparation -Key 'config_conflict' -Default '')
    desktop_unsynced_reason = [string](Get-RaymanMapValue -Map $desktopPreparation -Key 'unsynced_reason' -Default '')
    desktop_validation_report_path = ''
    rollback_applied = $false
    rollback_reason = ''
    smoke = [bool]$LoginSmoke
    force = [bool]$Force
    success = [bool]$result.success
    exit_code = [int]$result.exit_code
    command = [string](Get-RaymanMapValue -Map $result -Key 'command' -Default '')
    launch_strategy = [string](Get-RaymanMapValue -Map $result -Key 'launch_strategy' -Default '')
    fallback_used = [bool](Get-RaymanMapValue -Map $result -Key 'fallback_used' -Default $false)
    fallback_suppressed = [bool](Get-RaymanMapValue -Map $result -Key 'fallback_suppressed' -Default $false)
    prompt_classification = [string](Get-RaymanMapValue -Map $result -Key 'prompt_classification' -Default 'none')
    overrides_requested = [bool](Get-RaymanMapValue -Map $result -Key 'overrides_requested' -Default $false)
    overrides_applied = [bool](Get-RaymanMapValue -Map $result -Key 'overrides_applied' -Default $false)
    override_keys = @((Get-RaymanMapValue -Map $result -Key 'override_keys' -Default @()) | ForEach-Object { [string]$_ })
    override_skipped_reason = [string](Get-RaymanMapValue -Map $result -Key 'override_skipped_reason' -Default '')
    override_probe = Get-RaymanMapValue -Map $result -Key 'override_probe' -Default $null
    output_captured = [bool](Get-RaymanMapValue -Map $result -Key 'output_captured' -Default $false)
    error = [string](Get-RaymanMapValue -Map $result -Key 'error' -Default '')
    started_at = [string](Get-RaymanMapValue -Map $result -Key 'started_at' -Default '')
    finished_at = [string](Get-RaymanMapValue -Map $result -Key 'finished_at' -Default '')
    duration_ms = [int](Get-RaymanMapValue -Map $result -Key 'duration_ms' -Default 0)
    reused_yunyi_config = if ($null -ne $yunyiBaseUrlChoice) { [bool]$yunyiBaseUrlChoice.reused } else { $false }
    yunyi_base_url = if ($null -ne $yunyiBaseUrlChoice) { [string]$yunyiBaseUrlChoice.base_url } else { '' }
    yunyi_base_url_source = if ($null -ne $yunyiBaseUrlChoice) { [string]$yunyiBaseUrlChoice.source } else { '' }
    yunyi_reuse_reason = if ($null -ne $yunyiBaseUrlChoice) { [string]$yunyiBaseUrlChoice.reuse_reason } else { '' }
    smoke_throttle = $smokeSummary
  }

  if (-not [bool]$result.success) {
    if ($null -ne $snapshot) {
      $rollback = Restore-RaymanCodexLoginSnapshot -Snapshot $snapshot
      $loginReport.rollback_applied = [bool]$rollback.restored
      $loginReport.rollback_reason = 'login_failed'
      $desktopGlobalState = Get-RaymanCodexDesktopGlobalStateSummary
      $loginReport.desktop_global_cloud_access = [string]$desktopGlobalState.codex_cloud_access
    }
    $loginReportPath = Write-RaymanCodexLoginReport -WorkspaceRoot $resolvedWorkspace -Report ([pscustomobject]$loginReport)
    Set-RaymanCodexAccountLoginDiagnostics -Alias $normalizedAlias -LoginMode $Mode -AuthScope ([string]$loginTarget.auth_scope) -LaunchStrategy ([string]$loginReport.launch_strategy) -PromptClassification ([string]$loginReport.prompt_classification) -StartedAt ([string]$loginReport.started_at) -FinishedAt ([string]$loginReport.finished_at) -Success ([bool]$loginReport.success) -DesktopTargetMode ([string]$loginReport.desktop_target_mode) -DesktopSavedTokenReused ([bool]$loginReport.desktop_saved_token_reused) -DesktopSavedTokenSource ([string]$loginReport.desktop_saved_token_source) | Out-Null
    Exit-CodexError ("codex login failed for alias '{0}'." -f $normalizedAlias) $result.exit_code
  }

  $aliasAuthChanged = Test-RaymanCodexLoginSnapshotItemChanged -SnapshotItem (Get-RaymanMapValue -Map $snapshot -Key 'alias_auth' -Default $null)
  $desktopAuthChanged = Test-RaymanCodexLoginSnapshotItemChanged -SnapshotItem (Get-RaymanMapValue -Map $snapshot -Key 'desktop_auth' -Default $null)
  $normalizedLoginMode = Normalize-RaymanCodexAuthModeLast -Mode $Mode
  $shouldValidateDesktop = (
    (Test-RaymanCodexWindowsHost) -and
    [string]$loginTarget.auth_scope -eq 'desktop_global' -and
    (
      (
        $normalizedLoginMode -in @('web', 'device') -and
        (
          [bool]$LoginSmoke -or
          [bool]$desktopPreparation.should_skip_login -or
          [bool]$aliasAuthChanged -or
          [bool]$desktopAuthChanged
        )
      ) -or
      (
        $normalizedLoginMode -in @('api', 'yunyi')
      )
    )
  )
  if ($shouldValidateDesktop) {
    $desktopValidation = Invoke-RaymanCodexDesktopStatusValidation -WorkspaceRoot $resolvedWorkspace -Alias $normalizedAlias -DesktopCodexHome ([string]$loginTarget.desktop_codex_home) -StatusCommand (Get-RaymanCodexDesktopStatusCommand) -TargetMode $normalizedLoginMode
    if ((-not [bool]$desktopValidation.success) -and $aliasAuthChanged -and -not $desktopAuthChanged) {
      $desktopValidation.reason = 'desktop_home_auth_unsynced'
    }

    $loginReport.desktop_auth_present = [bool](Get-RaymanMapValue -Map $desktopValidation -Key 'desktop_auth_present' -Default $loginReport.desktop_auth_present)
    $loginReport.desktop_global_cloud_access = [string](Get-RaymanMapValue -Map $desktopValidation -Key 'desktop_global_cloud_access' -Default $loginReport.desktop_global_cloud_access)
    $loginReport.desktop_status_command = [string](Get-RaymanMapValue -Map $desktopValidation -Key 'status_command' -Default $loginReport.desktop_status_command)
    $loginReport.desktop_status_quota_visible = [bool](Get-RaymanMapValue -Map $desktopValidation -Key 'quota_visible' -Default $false)
    $loginReport.desktop_status_reason = [string](Get-RaymanMapValue -Map $desktopValidation -Key 'reason' -Default $(if ($normalizedLoginMode -in @('api', 'yunyi')) { 'desktop_api_activation_failed' } else { 'desktop_status_quota_missing' }))
    $loginReport.desktop_config_conflict = [string](Get-RaymanMapValue -Map $desktopValidation -Key 'desktop_config_conflict' -Default $loginReport.desktop_config_conflict)
    $loginReport.desktop_unsynced_reason = [string](Get-RaymanMapValue -Map $desktopValidation -Key 'desktop_unsynced_reason' -Default $loginReport.desktop_unsynced_reason)
    $loginReport.desktop_validation_report_path = Get-RaymanCodexDesktopStatusValidationReportPath -WorkspaceRoot $resolvedWorkspace
    Set-RaymanCodexAccountDesktopStatusValidation -Alias $normalizedAlias -StatusCommand ([string]$loginReport.desktop_status_command) -QuotaVisible ([bool]$loginReport.desktop_status_quota_visible) -Reason ([string]$loginReport.desktop_status_reason) -ConfigConflict ([string]$loginReport.desktop_config_conflict) -UnsyncedReason ([string]$loginReport.desktop_unsynced_reason) | Out-Null

    if (-not [bool]$desktopValidation.success) {
      $desktopValidationReason = [string](Get-RaymanMapValue -Map $desktopValidation -Key 'reason' -Default '')
      $desktopAuthAfterValidation = Get-RaymanCodexAuthFileSummary -CodexHome ([string]$loginTarget.desktop_codex_home)
      $isRecoverableWebValidation = (
        $normalizedLoginMode -eq 'web' -and
        $desktopValidationReason -in @('desktop_window_not_found', 'desktop_response_timeout') -and
        (
          [bool]$desktopAuthChanged -or
          (
            [bool](Get-RaymanMapValue -Map $desktopPreparation -Key 'should_skip_login' -Default $false) -and
            [bool](Get-RaymanMapValue -Map $desktopPreparation -Key 'saved_token_reused' -Default $false)
          )
        ) -and
        [bool]$desktopAuthAfterValidation.present -and
        [string]$desktopAuthAfterValidation.auth_mode -eq 'chatgpt'
      )

      if ($isRecoverableWebValidation) {
        $loginReport.desktop_status_reason = switch ($desktopValidationReason) {
          'desktop_window_not_found' { 'desktop_window_not_found_soft_pass' }
          'desktop_response_timeout' { 'desktop_response_timeout_soft_pass' }
          default { 'desktop_web_validation_soft_pass' }
        }
        $loginReport.desktop_unsynced_reason = ''
        $loginReport.desktop_status_quota_visible = [bool](Get-RaymanMapValue -Map $desktopValidation -Key 'quota_visible' -Default $false)
        Set-RaymanCodexAccountDesktopStatusValidation -Alias $normalizedAlias -StatusCommand ([string]$loginReport.desktop_status_command) -QuotaVisible ([bool]$loginReport.desktop_status_quota_visible) -Reason ([string]$loginReport.desktop_status_reason) -ConfigConflict ([string]$loginReport.desktop_config_conflict) -UnsyncedReason ([string]$loginReport.desktop_unsynced_reason) | Out-Null
        Write-CodexWarn ("desktop status check failed ({0}), but new web auth is present; continuing without rollback for alias={1}." -f $desktopValidationReason, $normalizedAlias)
      } else {
        $rollback = Restore-RaymanCodexLoginSnapshot -Snapshot $snapshot
        $loginReport.rollback_applied = [bool]$rollback.restored
        $loginReport.rollback_reason = [string]$loginReport.desktop_status_reason
        $loginReport.success = $false
        $loginReport.exit_code = 5
        $loginReport.error = ('desktop status validation failed: {0}' -f [string]$loginReport.desktop_status_reason)
        $loginReportPath = Write-RaymanCodexLoginReport -WorkspaceRoot $resolvedWorkspace -Report ([pscustomobject]$loginReport)
        Set-RaymanCodexAccountLoginDiagnostics -Alias $normalizedAlias -LoginMode $Mode -AuthScope ([string]$loginTarget.auth_scope) -LaunchStrategy ([string]$loginReport.launch_strategy) -PromptClassification ([string]$loginReport.desktop_status_reason) -StartedAt ([string]$loginReport.started_at) -FinishedAt ([string]$loginReport.finished_at) -Success:$false -DesktopTargetMode ([string]$loginReport.desktop_target_mode) -DesktopSavedTokenReused ([bool]$loginReport.desktop_saved_token_reused) -DesktopSavedTokenSource ([string]$loginReport.desktop_saved_token_source) | Out-Null
        $statusAfterRollback = Get-RaymanCodexLoginStatus -WorkspaceRoot $resolvedWorkspace -AccountAlias $normalizedAlias -GuardStage 'codex.login'
        $statusGeneratedAtRollback = [string](Get-RaymanMapValue -Map $statusAfterRollback -Key 'generated_at' -Default ((Get-Date).ToString('o')))
        $latestNativeSessionRollback = Get-RaymanMapValue -Map $statusAfterRollback -Key 'latest_native_session' -Default $null
        Set-RaymanCodexAccountStatus -Alias $normalizedAlias -Status ([string](Get-RaymanMapValue -Map $statusAfterRollback -Key 'status' -Default 'unknown')) -CheckedAt $statusGeneratedAtRollback -AuthModeLast ([string](Get-RaymanMapValue -Map $statusAfterRollback -Key 'auth_mode_last' -Default $Mode)) -LatestNativeSession $latestNativeSessionRollback | Out-Null
        Exit-CodexError ("codex desktop validation failed for alias '{0}' ({1}). report={2}" -f $normalizedAlias, [string]$loginReport.desktop_status_reason, $loginReportPath) 5
      }
    }
  }

  if ([string]$loginTarget.auth_scope -eq 'desktop_global' -and $normalizedLoginMode -in @('api', 'yunyi', 'web')) {
    $desktopAuthPath = Get-RaymanCodexAuthFilePath -CodexHome ([string]$loginTarget.desktop_codex_home)
    $aliasAuthPath = Get-RaymanCodexAuthFilePath -CodexHome ([string]$loginTarget.alias_codex_home)
    if (
      -not [string]::IsNullOrWhiteSpace([string]$desktopAuthPath) -and
      -not [string]::IsNullOrWhiteSpace([string]$aliasAuthPath) -and
      (Test-Path -LiteralPath $desktopAuthPath -PathType Leaf)
    ) {
      Copy-Item -LiteralPath $desktopAuthPath -Destination $aliasAuthPath -Force
    }
    if ($normalizedLoginMode -eq 'yunyi' -and $null -ne $yunyiBaseUrlChoice) {
      Set-RaymanCodexAliasYunyiConfig -Alias $normalizedAlias -BaseUrl ([string]$yunyiBaseUrlChoice.base_url) | Out-Null
    }
  }

  $loginReportPath = Write-RaymanCodexLoginReport -WorkspaceRoot $resolvedWorkspace -Report ([pscustomobject]$loginReport)
  Set-RaymanCodexAccountLoginDiagnostics -Alias $normalizedAlias -LoginMode $Mode -AuthScope ([string]$loginTarget.auth_scope) -LaunchStrategy ([string]$loginReport.launch_strategy) -PromptClassification ([string]$loginReport.prompt_classification) -StartedAt ([string]$loginReport.started_at) -FinishedAt ([string]$loginReport.finished_at) -Success ([bool]$loginReport.success) -DesktopTargetMode ([string]$loginReport.desktop_target_mode) -DesktopSavedTokenReused ([bool]$loginReport.desktop_saved_token_reused) -DesktopSavedTokenSource ([string]$loginReport.desktop_saved_token_source) | Out-Null
  if ($Mode -eq 'yunyi' -and $null -ne $yunyiBaseUrlChoice) {
    $yunyiConfigSummary = Get-RaymanCodexYunyiConfigSummary -Alias $normalizedAlias
    $yunyiSuccessAt = if ([string]::IsNullOrWhiteSpace([string]$loginReport.finished_at)) { [string]$loginReport.generated_at } else { [string]$loginReport.finished_at }
    Set-RaymanCodexAccountYunyiMetadata -Alias $normalizedAlias -BaseUrl ([string]$yunyiBaseUrlChoice.base_url) -SuccessAt $yunyiSuccessAt -ConfigReady ([bool]$yunyiConfigSummary.config_ready) -ReuseReason ([string]$yunyiBaseUrlChoice.reuse_reason) -BaseUrlSource ([string]$yunyiBaseUrlChoice.source) | Out-Null
    $yunyiSync = Sync-RaymanCodexUserHomeYunyiState -WorkspaceRoot $resolvedWorkspace -BaseUrl ([string]$yunyiBaseUrlChoice.base_url) -ApiKey $yunyiApiKeyForSync -BackupTomlSourcePath $(if ([string](Get-RaymanMapValue -Map $yunyiBaseUrlChoice -Key 'path' -Default '') -match '\.toml$') { [string]$yunyiBaseUrlChoice.path } else { '' })
    if ($null -ne $yunyiSync -and -not [bool]$yunyiSync.success) {
      $syncMessages = New-Object System.Collections.Generic.List[string]
      foreach ($item in @($yunyiSync.config, $yunyiSync.auth, $yunyiSync.backup_auth, $yunyiSync.workspace_config, $yunyiSync.workspace_auth, $yunyiSync.workspace_backup_auth, $yunyiSync.backup_toml, $yunyiSync.workspace_backup_toml)) {
        if ($null -eq $item -or [bool]$item.success) {
          continue
        }
        $syncMessages.Add(("{0} ({1})" -f [string]$item.reason, [string]$item.path)) | Out-Null
      }
      if ($syncMessages.Count -gt 0) {
        Write-CodexWarn ("Yunyi user-home state sync incomplete for alias={0}: {1}" -f $normalizedAlias, (($syncMessages | Select-Object -Unique) -join '; '))
      }
    }
    $yunyiApiKeyForSync = ''
  }

  $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $resolvedWorkspace -AccountAlias $normalizedAlias -GuardStage 'codex.login'
  $statusGeneratedAt = [string](Get-RaymanMapValue -Map $status -Key 'generated_at' -Default ((Get-Date).ToString('o')))
  $latestNativeSession = Get-RaymanMapValue -Map $status -Key 'latest_native_session' -Default $null
  Set-RaymanCodexAccountStatus -Alias $normalizedAlias -Status ([string](Get-RaymanMapValue -Map $status -Key 'status' -Default 'unknown')) -CheckedAt $statusGeneratedAt -AuthModeLast $Mode -LatestNativeSession $latestNativeSession | Out-Null
  if ($null -eq $status.PSObject.Properties['auth_mode_last']) {
    $status | Add-Member -NotePropertyName 'auth_mode_last' -NotePropertyValue $Mode
  } else {
    $status.auth_mode_last = $Mode
  }

  return [pscustomobject]@{
    workspace_root = $resolvedWorkspace
    alias = $normalizedAlias
    mode = $Mode
    login_report_path = $loginReportPath
    smoke_throttle = $smokeSummary
    account = $account
    status = $status
  }
}

function Invoke-CodexAliasDeviceAuth {
  param(
    [string]$Alias,
    [string]$TargetWorkspaceRoot,
    [string]$Profile = '',
    [switch]$SetDefaultProfile,
    [switch]$LogoutFirst,
    [int]$DeviceAuthStaleAfterSeconds = 180
  )

  return (Invoke-CodexAliasNativeLogin -Alias $Alias -TargetWorkspaceRoot $TargetWorkspaceRoot -Profile $Profile -SetDefaultProfile:$SetDefaultProfile -Mode 'device' -LogoutFirst:$LogoutFirst -DeviceAuthStaleAfterSeconds $DeviceAuthStaleAfterSeconds)
}

function Show-CodexAliasDetails {
  param(
    [object]$AliasRow,
    [string]$TargetWorkspaceRoot
  )

  $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $TargetWorkspaceRoot
  $alias = [string](Get-RaymanMapValue -Map $AliasRow -Key 'alias' -Default '')
  $account = Get-RaymanCodexAccountRecord -Alias $alias
  $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $resolvedWorkspace -AccountAlias $alias -SkipReportWrite -GuardStage 'codex.status'
  $currentBinding = Get-RaymanCodexWorkspaceBinding -WorkspaceRoot $resolvedWorkspace
  $references = @(Get-RaymanCodexAliasWorkspaceReferences -Alias $alias)
  $boundToCurrentWorkspace = $false
  $bindingAlias = Normalize-RaymanCodexAlias -Alias ([string]$currentBinding.account_alias)
  if (-not [string]::IsNullOrWhiteSpace($bindingAlias) -and $bindingAlias -ieq $alias) {
    $boundToCurrentWorkspace = $true
  }

  Write-Host ''
  Write-CodexInfo ("alias={0}" -f $alias)
  Write-CodexInfo ("status={0}" -f [string]$status.status)
  Write-CodexInfo ("auth_mode_last={0}" -f (Format-CodexAuthModeLastText -Mode ([string]$status.auth_mode_last)))
  Write-CodexInfo ("auth_detected={0}" -f (Format-CodexDetectedAuthText -Status $status))
  if ($status.PSObject.Properties['desktop_target_mode'] -and -not [string]::IsNullOrWhiteSpace([string]$status.desktop_target_mode)) {
    Write-CodexInfo ("desktop target={0} saved_token={1} source={2}" -f [string]$status.desktop_target_mode, [string]$status.desktop_saved_token_reused, [string]$status.desktop_saved_token_source)
  }
  if ($status.PSObject.Properties['auth_scope'] -and -not [string]::IsNullOrWhiteSpace([string]$status.auth_scope)) {
    Write-CodexInfo ("auth_scope={0} effective_home={1}" -f [string]$status.auth_scope, [string]$status.codex_home)
  }
  if ($status.PSObject.Properties['last_login_mode'] -and -not [string]::IsNullOrWhiteSpace([string]$status.last_login_mode)) {
    Write-CodexInfo ("last login={0} strategy={1} prompt={2}" -f [string]$status.last_login_mode, [string]$status.last_login_strategy, [string]$status.last_login_prompt_classification)
  }
  if (
    ($status.PSObject.Properties['last_yunyi_base_url'] -and -not [string]::IsNullOrWhiteSpace([string]$status.last_yunyi_base_url)) -or
    ($status.PSObject.Properties['last_yunyi_config_ready'] -and [bool]$status.last_yunyi_config_ready)
  ) {
    Write-CodexInfo ("yunyi base_url={0} config_ready={1} reuse_reason={2} source={3}" -f [string]$status.last_yunyi_base_url, [string]$status.last_yunyi_config_ready, [string]$status.last_yunyi_reuse_reason, [string]$status.last_yunyi_base_url_source)
  }
  if ($status.PSObject.Properties['desktop_status_command'] -and -not [string]::IsNullOrWhiteSpace([string]$status.desktop_status_command)) {
    Write-CodexInfo ("desktop {0} quota_visible={1} reason={2} cloud_access={3} conflict={4} unsynced={5}" -f [string]$status.desktop_status_command, [string]$status.desktop_status_quota_visible, [string]$status.desktop_status_reason, [string]$status.desktop_global_cloud_access, [string]$status.desktop_config_conflict, [string]$status.desktop_unsynced_reason)
  }
  if ($status.PSObject.Properties['login_smoke_next_allowed_at'] -and -not [string]::IsNullOrWhiteSpace([string]$status.login_smoke_next_allowed_at)) {
    Write-CodexWarn ("login smoke cooldown until {0} (mode={1})" -f [string]$status.login_smoke_next_allowed_at, [string]$status.login_smoke_mode)
  }
  Write-CodexRepeatErrorSummary -Status $status
  Write-CodexInfo ("default Codex execution profile={0}" -f (Format-CodexExecutionProfileText -Profile ([string](Get-RaymanMapValue -Map $account -Key 'default_profile' -Default ''))))
  Write-CodexInfo ("CODEX_HOME={0}" -f [string](Get-RaymanMapValue -Map $account -Key 'codex_home' -Default ''))
  Write-CodexInfo ("latest native session={0}" -f (Format-CodexNativeSessionText -Session $status.latest_native_session))
  Write-CodexInfo ("current workspace saved state={0}" -f (Format-CodexSavedStateSummaryText -Summary $status.saved_state_summary))
  Write-CodexInfo ("current workspace bound={0}" -f $(if ($boundToCurrentWorkspace) { 'yes' } else { 'no' }))
  Write-CodexInfo ("known workspace references={0}" -f @($references | Where-Object { [bool]$_.registry_matches -or [bool]$_.binding_matches }).Count)
  foreach ($savedState in @($status.recent_saved_states)) {
    Write-CodexInfo ("saved state: {0} [{1}] updated={2}" -f [string](Get-RaymanMapValue -Map $savedState -Key 'name' -Default (Get-RaymanMapValue -Map $savedState -Key 'slug' -Default '')), [string](Get-RaymanMapValue -Map $savedState -Key 'session_kind' -Default 'manual'), [string](Get-RaymanMapValue -Map $savedState -Key 'updated_at' -Default ''))
  }
}

function Invoke-CodexManageAlias {
  param(
    [string]$TargetWorkspaceRoot,
    [string]$Picker = 'auto'
  )

  $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $TargetWorkspaceRoot
  $aliasRow = Select-CodexAliasRow -Picker $Picker -Prompt '选择要管理的 alias' -TargetWorkspaceRoot $resolvedWorkspace
  $actionRows = @(Get-CodexManageActionRows)
  $defaultAction = $actionRows | Select-Object -First 1
  $pickedAction = Select-WithFzfOrMenu -Rows $actionRows -Picker $Picker -Prompt '选择管理动作' -Render {
    param($row)
    "{0}{1}  {2}" -f [string]$row.label, $(if ([bool]$row.recommended) { '  [推荐]' } else { '' }), [string]$row.description
  } -KeySelector {
    param($row)
    [string]$row.action
  } -DefaultRow $defaultAction
  if ($null -eq $pickedAction) {
    Exit-CodexError 'Alias management cancelled.'
  }

  $selectedAlias = [string]$aliasRow.alias
  switch ([string]$pickedAction.action) {
    'details' {
      Show-CodexAliasDetails -AliasRow $aliasRow -TargetWorkspaceRoot $resolvedWorkspace
      return
    }
    'set-default-profile' {
      $newProfile = [string](Read-Host '新的默认 Codex execution profile（留空清空）')
      $updated = Set-RaymanCodexAccountDefaultProfile -Alias $selectedAlias -DefaultProfile $newProfile
      Write-CodexInfo ("alias={0} default Codex execution profile={1}" -f $selectedAlias, (Format-CodexExecutionProfileText -Profile ([string]$updated.default_profile)))
      return
    }
    'relogin' {
      $result = Invoke-ActionLogin -Alias $selectedAlias -Profile '' -TargetWorkspaceRoot $resolvedWorkspace -Picker $Picker -PromptForMode -LogoutFirst
      Write-CodexInfo ("alias={0} status={1}" -f $selectedAlias, [string]$result.status.status)
      return
    }
    'delete-safe' {
      $confirmation = [string](Read-Host ("确认安全删除 alias '{0}'？输入 yes 继续" -f $selectedAlias))
      if ($confirmation -ne 'yes') {
        Write-CodexWarn 'Safe delete cancelled.'
        return
      }
      $removed = Remove-RaymanCodexAlias -Alias $selectedAlias
      Write-CodexInfo ("alias={0} removed={1} kept_home={2}" -f $selectedAlias, [string]$removed.removed.ToString().ToLowerInvariant(), [string]$removed.codex_home)
      return
    }
    'delete-hard' {
      $confirmation = [string](Read-Host ("输入 alias '{0}' 以彻底删除" -f $selectedAlias))
      if ($confirmation -ne $selectedAlias) {
        Write-CodexWarn 'Hard delete cancelled.'
        return
      }
      $removed = Remove-RaymanCodexAlias -Alias $selectedAlias -DeleteHome
      Write-CodexInfo ("alias={0} removed={1} deleted_home={2}" -f $selectedAlias, [string]$removed.removed.ToString().ToLowerInvariant(), [string]$removed.deleted_home.ToString().ToLowerInvariant())
      return
    }
  }
}

function Invoke-ActionRunFromMenu {
  param(
    [string]$TargetWorkspaceRoot
  )

  $rawArgs = [string](Read-Host '请输入要透传给 codex 的参数（留空取消）')
  $passthrough = @(Convert-ArgumentLineToTokens -Text $rawArgs)
  if ($passthrough.Count -eq 0) {
    Write-CodexWarn 'Codex CLI run cancelled.'
    return
  }
  Invoke-ActionRun -TargetWorkspaceRoot $TargetWorkspaceRoot -PassthroughArgs $passthrough
}

function Invoke-CodexMenuAction {
  param(
    [string]$MenuAction,
    [string]$TargetWorkspaceRoot,
    [string]$Picker = 'auto'
  )

  switch ([string]$MenuAction) {
    'status' { Invoke-ActionStatus -TargetWorkspaceRoot $TargetWorkspaceRoot; return }
    'list' { Invoke-ActionList -TargetWorkspaceRoot $TargetWorkspaceRoot; return }
    'login' { Invoke-ActionLogin -Alias '' -Profile '' -TargetWorkspaceRoot $TargetWorkspaceRoot -Picker $Picker -PromptForMode; return }
    'login-web' { Invoke-ActionLogin -Alias '' -Profile '' -TargetWorkspaceRoot $TargetWorkspaceRoot -Picker $Picker -Mode 'web'; return }
    'login-smoke' { Invoke-ActionLogin -Alias '' -Profile '' -TargetWorkspaceRoot $TargetWorkspaceRoot -Picker $Picker -LoginSmoke -PromptForMode; return }
    'login-yunyi' { Invoke-ActionLogin -Alias '' -Profile '' -TargetWorkspaceRoot $TargetWorkspaceRoot -Picker $Picker -Mode 'yunyi'; return }
    'login-api' { Invoke-ActionLogin -Alias '' -Profile '' -TargetWorkspaceRoot $TargetWorkspaceRoot -Picker $Picker -Mode 'api'; return }
    'login-device' { Invoke-ActionLogin -Alias '' -Profile '' -TargetWorkspaceRoot $TargetWorkspaceRoot -Picker $Picker -Mode 'device'; return }
    'switch' { Invoke-ActionSwitch -Alias '' -Profile '' -TargetWorkspaceRoot $TargetWorkspaceRoot -Picker $Picker; return }
    'manage' { Invoke-CodexManageAlias -TargetWorkspaceRoot $TargetWorkspaceRoot -Picker $Picker; return }
    'run' { Invoke-ActionRunFromMenu -TargetWorkspaceRoot $TargetWorkspaceRoot; return }
    'upgrade' { Invoke-ActionUpgrade -TargetWorkspaceRoot $TargetWorkspaceRoot | Out-Null; return }
    default { Exit-CodexError ("Unknown codex menu action: {0}" -f $MenuAction) }
  }
}

function Invoke-ActionMenu {
  param(
    [string]$TargetWorkspaceRoot,
    [string]$Picker = 'auto'
  )

  if (-not (Test-InteractiveInputAvailable)) {
    Exit-CodexError 'codex menu requires an interactive terminal.'
  }

  $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $TargetWorkspaceRoot
  Show-CodexMenuHeader -TargetWorkspaceRoot $resolvedWorkspace
  $rows = @(Get-CodexMenuActionRows)
  $defaultRow = $rows | Where-Object { [bool]$_.recommended } | Select-Object -First 1
  if ($null -eq $defaultRow) {
    $defaultRow = $rows | Select-Object -First 1
  }
  $selected = Select-WithFzfOrMenu -Rows $rows -Picker $Picker -Prompt 'Codex 二级菜单' -Render {
    param($row)
    "{0}{1}  {2}" -f [string]$row.label, $(if ([bool]$row.recommended) { '  [推荐]' } else { '' }), [string]$row.description
  } -KeySelector {
    param($row)
    [string]$row.action
  } -DefaultRow $defaultRow
  if ($null -eq $selected) {
    Exit-CodexError 'Codex menu cancelled.'
  }

  Invoke-CodexMenuAction -MenuAction ([string]$selected.action) -TargetWorkspaceRoot $resolvedWorkspace -Picker $Picker
}

function Invoke-ActionList {
  param(
    [string]$TargetWorkspaceRoot = '',
    [switch]$AsJson
  )

  $rows = @(Get-RaymanCodexAccountRows -TargetWorkspaceRoot $TargetWorkspaceRoot)
  if ($AsJson) {
    [pscustomobject]@{
      schema = 'rayman.codex.accounts.list.v1'
      generated_at = (Get-Date).ToString('o')
      workspace_root = (Resolve-WorkspaceRootInput -InputRoot $TargetWorkspaceRoot)
      accounts = $rows
    } | ConvertTo-Json -Depth 8
    return
  }

  if ($rows.Count -eq 0) {
    Write-CodexInfo 'No Rayman-managed Codex aliases have been registered yet.'
    return
  }

  foreach ($row in $rows) {
    $repeatSuffix = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$row.known_error_signature)) {
      $repeatSuffix = (" repeat={0}/{1}" -f [string]$row.known_error_signature, $(if ([bool]$row.repeat_prevented) { 'blocked' } else { 'warn' }))
    }
    Write-Host ("- {0} [{1}] profile={2} mode={3} target={4} detected={5} native={6} {7} {8} home={9}{10}" -f [string]$row.alias, [string]$row.status, (Format-CodexExecutionProfileText -Profile ([string]$row.default_profile)), (Format-CodexAuthModeLastText -Mode ([string]$row.auth_mode_last)), [string]$row.desktop_target_mode, (Format-CodexDetectedAuthText -Status $row), (Format-CodexNativeSessionText -Session $row.latest_native_session), (Format-CodexSavedStateSummaryText -Summary $row.saved_state_summary), (Format-CodexYunyiSummaryText -Status $row), [string]$row.codex_home, $repeatSuffix)
  }
}

function Invoke-ActionStatus {
  param(
    [string]$TargetWorkspaceRoot,
    [switch]$AllAccounts,
    [switch]$AsJson
  )

  if ($AllAccounts) {
    $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $TargetWorkspaceRoot
    $preflightContext = Resolve-RaymanCodexContext -WorkspaceRoot $resolvedWorkspace
    Ensure-CodexCliReady -WorkspaceRoot $resolvedWorkspace -AccountAlias ([string]$preflightContext.account_alias) -AsJson:$AsJson | Out-Null
    Invoke-ActionList -TargetWorkspaceRoot $resolvedWorkspace -AsJson:$AsJson
    return
  }

  $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $TargetWorkspaceRoot
  $preflightContext = Resolve-RaymanCodexContext -WorkspaceRoot $resolvedWorkspace
  $cliUpdate = Ensure-CodexCliReady -WorkspaceRoot $resolvedWorkspace -AccountAlias ([string]$preflightContext.account_alias) -AsJson:$AsJson
  $context = Resolve-RaymanCodexContext -WorkspaceRoot $resolvedWorkspace
  $binding = Get-RaymanCodexWorkspaceBinding -WorkspaceRoot $resolvedWorkspace
  $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $resolvedWorkspace -AccountAlias $context.account_alias -GuardStage 'codex.status'
  Set-RaymanCodexWorkspaceRecord -WorkspaceRoot $resolvedWorkspace -AccountAlias ([string]$binding.account_alias) -Profile ([string]$binding.profile) | Out-Null
  $context = Resolve-RaymanCodexContext -WorkspaceRoot $resolvedWorkspace

  $payload = [pscustomobject]@{
    schema = 'rayman.codex.status.v1'
    generated_at = (Get-Date).ToString('o')
    workspace_root = $resolvedWorkspace
    vscode_user_profile = [pscustomobject]@{
      name = [string]$context.vscode_user_profile
      location = [string]$context.vscode_user_profile_location
      source = [string]$context.vscode_user_profile_source
      status = [string]$context.vscode_user_profile_status
      detected = [bool]$context.vscode_user_profile_detected
      is_default = [bool]$context.vscode_user_profile_is_default
      workspace_uri = [string]$context.vscode_user_profile_workspace_uri
    }
    binding = $binding
    context = $context
    cli_update = $cliUpdate
    auth = $status
  }

  if ($AsJson) {
    $payload | ConvertTo-Json -Depth 8
    return
  }

  Write-CodexInfo ("workspace={0}" -f $resolvedWorkspace)
  Write-CodexInfo ("VS Code user profile={0} source={1}" -f (Format-VsCodeUserProfileText -ProfileState $context), [string]$context.vscode_user_profile_status)
  Write-CodexInfo ("alias={0} Codex execution profile={1} status={2}" -f $(if ([string]::IsNullOrWhiteSpace([string]$context.account_alias)) { '(unbound)' } else { [string]$context.account_alias }), (Format-CodexExecutionProfileText -Profile ([string]$context.effective_profile)), [string]$status.status)
  Write-CodexInfo ("auth_mode_last={0} auth_detected={1}" -f (Format-CodexAuthModeLastText -Mode ([string]$status.auth_mode_last)), (Format-CodexDetectedAuthText -Status $status))
  if ($status.PSObject.Properties['desktop_target_mode'] -and -not [string]::IsNullOrWhiteSpace([string]$status.desktop_target_mode)) {
    Write-CodexInfo ("desktop_target_mode={0} saved_token={1} source={2}" -f [string]$status.desktop_target_mode, [string]$status.desktop_saved_token_reused, [string]$status.desktop_saved_token_source)
  }
  if ($status.PSObject.Properties['auth_scope'] -and -not [string]::IsNullOrWhiteSpace([string]$status.auth_scope)) {
    Write-CodexInfo ("auth_scope={0} effective_home={1}" -f [string]$status.auth_scope, [string]$status.codex_home)
  }
  if ($status.PSObject.Properties['last_login_mode'] -and -not [string]::IsNullOrWhiteSpace([string]$status.last_login_mode)) {
    Write-CodexInfo ("last login={0} strategy={1} prompt={2}" -f [string]$status.last_login_mode, [string]$status.last_login_strategy, [string]$status.last_login_prompt_classification)
  }
  if (
    ($status.PSObject.Properties['last_yunyi_base_url'] -and -not [string]::IsNullOrWhiteSpace([string]$status.last_yunyi_base_url)) -or
    ($status.PSObject.Properties['last_yunyi_config_ready'] -and [bool]$status.last_yunyi_config_ready)
  ) {
    Write-CodexInfo ("yunyi base_url={0} config_ready={1} reuse_reason={2} source={3}" -f [string]$status.last_yunyi_base_url, [string]$status.last_yunyi_config_ready, [string]$status.last_yunyi_reuse_reason, [string]$status.last_yunyi_base_url_source)
  }
  if ($status.PSObject.Properties['desktop_status_command'] -and -not [string]::IsNullOrWhiteSpace([string]$status.desktop_status_command)) {
    Write-CodexInfo ("desktop {0} quota_visible={1} reason={2} cloud_access={3} conflict={4} unsynced={5}" -f [string]$status.desktop_status_command, [string]$status.desktop_status_quota_visible, [string]$status.desktop_status_reason, [string]$status.desktop_global_cloud_access, [string]$status.desktop_config_conflict, [string]$status.desktop_unsynced_reason)
  }
  if ($status.PSObject.Properties['login_smoke_next_allowed_at'] -and -not [string]::IsNullOrWhiteSpace([string]$status.login_smoke_next_allowed_at)) {
    Write-CodexWarn ("login smoke cooldown active until {0} (mode={1})" -f [string]$status.login_smoke_next_allowed_at, [string]$status.login_smoke_mode)
  }
  Write-CodexInfo ("latest native session={0}" -f (Format-CodexNativeSessionText -Session $status.latest_native_session))
  Write-CodexInfo ("current workspace saved state={0}" -f (Format-CodexSavedStateSummaryText -Summary $status.saved_state_summary))
  Write-CodexRepeatErrorSummary -Status $status
  if (-not [string]::IsNullOrWhiteSpace([string]$status.repair_command) -and -not [bool]$status.authenticated -and [bool]$context.managed) {
    Write-CodexWarn ("login repair: {0}" -f [string]$status.repair_command)
  }
  Invoke-CodexRepeatErrorGuardExitIfNeeded -Status $status -Stage 'codex status' -AsJson:$AsJson

}

function Sync-WorkspaceTrust {
  param(
    [string]$WorkspaceRoot,
    [string]$Alias,
    [string]$TrustLevel = 'trusted'
  )

  if ([string]::IsNullOrWhiteSpace($WorkspaceRoot) -or [string]::IsNullOrWhiteSpace($Alias)) {
    return $null
  }

  $context = Resolve-RaymanCodexContext -WorkspaceRoot $WorkspaceRoot -AccountAlias $Alias
  $result = Set-RaymanCodexWorkspaceTrust -WorkspaceRoot $WorkspaceRoot -Alias $Alias -CodexHome ([string]$context.codex_home) -TrustLevel $TrustLevel
  Write-CodexInfo ("workspace trust={0} alias={1} config={2}{3}" -f [string]$result.trust_level, [string]$Alias, [string]$result.config_path, $(if ([bool]$result.changed) { ' [updated]' } else { ' [unchanged]' }))
  return $result
}

function Get-RaymanCodexWorkspaceBindingAutoApplyEnabled {
  param([string]$WorkspaceRoot = '')

  return (Get-RaymanWorkspaceEnvBool -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_CODEX_WORKSPACE_BINDING_AUTO_APPLY_ENABLED' -Default $true)
}

function Get-RaymanCodexWorkspaceBindingAutoApplyRetrySeconds {
  param([string]$WorkspaceRoot = '')

  $raw = [string](Get-RaymanWorkspaceEnvString -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_CODEX_WORKSPACE_BINDING_AUTO_APPLY_RETRY_SECONDS' -Default '300')
  $value = 300
  try {
    $value = [int]$raw
  } catch {
    $value = 300
  }

  if ($value -lt 30) {
    return 30
  }
  if ($value -gt 3600) {
    return 3600
  }
  return $value
}

function Get-RaymanCodexWorkspaceBindingAutoApplyPlan {
  param([string]$WorkspaceRoot)

  $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $WorkspaceRoot
  $enabled = Get-RaymanCodexWorkspaceBindingAutoApplyEnabled -WorkspaceRoot $resolvedWorkspace
  $context = Resolve-RaymanCodexContext -WorkspaceRoot $resolvedWorkspace
  $result = [ordered]@{
    enabled = [bool]$enabled
    applicable = $false
    workspace_root = $resolvedWorkspace
    account_alias = [string]$context.account_alias
    binding_profile = [string]$context.binding_profile
    mode = ''
    signature = ''
    reason = 'workspace_unbound'
  }

  if (-not [bool]$enabled) {
    $result.reason = 'disabled'
    return [pscustomobject]$result
  }
  if (-not (Test-RaymanCodexWindowsHost)) {
    $result.reason = 'non_windows_host'
    return [pscustomobject]$result
  }
  if (-not [bool]$context.managed) {
    $result.reason = 'workspace_unbound'
    return [pscustomobject]$result
  }
  if (-not [bool]$context.account_known) {
    $result.reason = 'unknown_alias'
    return [pscustomobject]$result
  }

  $record = $context.account_record
  $mode = Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $record -Key 'desktop_target_mode' -Default (Get-RaymanMapValue -Map $record -Key 'last_login_mode' -Default (Get-RaymanMapValue -Map $record -Key 'auth_mode_last' -Default ''))))
  $result.mode = [string]$mode
  if ($mode -notin @('web', 'api', 'yunyi')) {
    $result.reason = 'desktop_activation_not_applicable'
    return [pscustomobject]$result
  }

  $result.applicable = $true
  $result.signature = ('{0}|{1}' -f [string]$context.account_alias, [string]$mode)
  $result.reason = 'ready'
  return [pscustomobject]$result
}

function Invoke-RaymanCodexWorkspaceBindingAutoApply {
  param(
    [string]$WorkspaceRoot,
    [string]$Reason = 'bootstrap',
    [string]$SessionId = '',
    [switch]$Force
  )

  $plan = Get-RaymanCodexWorkspaceBindingAutoApplyPlan -WorkspaceRoot $WorkspaceRoot
  $result = [ordered]@{
    workspace_root = [string]$plan.workspace_root
    reason = [string]$Reason
    session_id = [string]$SessionId
    enabled = [bool]$plan.enabled
    applicable = [bool]$plan.applicable
    attempted = $false
    success = $false
    alias = [string]$plan.account_alias
    mode = [string]$plan.mode
    signature = [string]$plan.signature
    status = if ([bool]$plan.enabled) { 'skipped' } else { 'disabled' }
    detail = [string]$plan.reason
    activation = $null
    auth_status = $null
    trust_synced = $false
  }

  if (-not [bool]$plan.enabled -or -not [bool]$plan.applicable) {
    return [pscustomobject]$result
  }

  $result.attempted = $true
  try {
    $account = Ensure-RaymanCodexAccount -Alias ([string]$plan.account_alias)
    $activation = Invoke-RaymanCodexDesktopAliasActivation -WorkspaceRoot ([string]$plan.workspace_root) -Alias ([string]$plan.account_alias) -Account $account -Mode ([string]$plan.mode)
    $result.activation = $activation
    if (-not [bool](Get-RaymanMapValue -Map $activation -Key 'success' -Default $false)) {
      $result.status = 'failed'
      $result.detail = [string](Get-RaymanMapValue -Map $activation -Key 'reason' -Default 'desktop_activation_failed')
      $result.auth_status = Get-RaymanCodexLoginStatus -WorkspaceRoot ([string]$plan.workspace_root) -AccountAlias ([string]$plan.account_alias) -GuardStage 'codex.bootstrap'
      return [pscustomobject]$result
    }

    $status = Get-RaymanMapValue -Map $activation -Key 'status' -Default $null
    if ($null -eq $status) {
      $status = Get-RaymanCodexLoginStatus -WorkspaceRoot ([string]$plan.workspace_root) -AccountAlias ([string]$plan.account_alias) -GuardStage 'codex.bootstrap'
    }
    $result.auth_status = $status
    if ([bool](Get-RaymanMapValue -Map $status -Key 'authenticated' -Default $false)) {
      Sync-WorkspaceTrust -WorkspaceRoot ([string]$plan.workspace_root) -Alias ([string]$plan.account_alias) | Out-Null
      $result.trust_synced = $true
    }

    $result.success = $true
    $result.status = 'applied'
    $result.detail = [string](Get-RaymanMapValue -Map $activation -Key 'reason' -Default 'desktop_activation_applied')
    return [pscustomobject]$result
  } catch {
    $result.status = 'failed'
    $result.detail = $_.Exception.Message
    return [pscustomobject]$result
  }
}

function Invoke-ActionLogin {
  param(
    [string]$Alias,
    [string]$Profile,
    [string]$TargetWorkspaceRoot,
    [string]$Picker = 'auto',
    [string]$Mode = '',
    [switch]$ApiKeyFromStdin,
    [switch]$PromptForMode,
    [switch]$LogoutFirst,
    [switch]$LoginSmoke,
    [switch]$Force
  )

  $selection = Resolve-LoginAliasChoice -Alias $Alias -TargetWorkspaceRoot $TargetWorkspaceRoot -Picker $Picker -Mode $Mode
  $normalizedAlias = [string]$selection.alias
  $resolvedWorkspace = [string]$selection.workspace_root
  $profileState = $selection.vscode_user_profile_state
  if ($ApiKeyFromStdin -and (Resolve-RaymanCodexLoginMode -Mode $Mode) -ne 'api') {
    Exit-CodexError '--api-key-stdin is only supported together with --mode api.'
  }

  $modeChoice = if ($LoginSmoke) {
    Resolve-CodexLoginSmokeModeChoice -Mode $Mode -Alias $normalizedAlias -TargetWorkspaceRoot $resolvedWorkspace -Picker $Picker -PromptForMode:$PromptForMode
  } else {
    Resolve-CodexLoginModeChoice -Mode $Mode -Alias $normalizedAlias -TargetWorkspaceRoot $resolvedWorkspace -Picker $Picker -PromptForMode:$PromptForMode
  }
  if ($LoginSmoke) {
    $smokePreview = Write-CodexLoginSmokeBudget -WorkspaceRoot $resolvedWorkspace -Alias $normalizedAlias -Mode ([string]$modeChoice.mode) -Force:$Force
    if ([bool]$smokePreview.throttled -and -not $Force) {
      $blockedReportPath = Write-CodexBlockedLoginSmokeReport -WorkspaceRoot $resolvedWorkspace -Alias $normalizedAlias -Mode ([string]$modeChoice.mode) -ThrottleSummary $smokePreview
      Exit-CodexError ("codex login-smoke is throttled until {0} for alias={1} mode={2}. Use --force to override. report={3}" -f [string]$smokePreview.next_allowed_at, $normalizedAlias, [string]$modeChoice.mode, $blockedReportPath) 4
    }
  }

  $login = Invoke-CodexAliasNativeLogin -Alias $normalizedAlias -TargetWorkspaceRoot $resolvedWorkspace -Profile $Profile -SetDefaultProfile:(-not [string]::IsNullOrWhiteSpace($Profile)) -Mode ([string]$modeChoice.mode) -ApiKeyFromStdin:$ApiKeyFromStdin -LogoutFirst:$LogoutFirst -LoginSmoke:$LoginSmoke -Force:$Force
  $account = $login.account
  $status = $login.status

  $bindingProfile = if ([string]::IsNullOrWhiteSpace($Profile)) { [string]$account.default_profile } else { [string]$Profile }
  Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $resolvedWorkspace -AccountAlias $normalizedAlias -Profile $bindingProfile | Out-Null
  
  # Activate desktop Codex context so that the new alias is immediately reflected in the workspace
  $desktopActivation = Invoke-RaymanCodexDesktopAliasActivation -WorkspaceRoot $resolvedWorkspace -Alias $normalizedAlias -Account $account -Mode ([string]$modeChoice.mode)
  if ([bool](Get-RaymanMapValue -Map $desktopActivation -Key 'attempted' -Default $false)) {
    if ([bool](Get-RaymanMapValue -Map $desktopActivation -Key 'success' -Default $false)) {
      # Update status from desktop activation if successful
      $status = Get-RaymanMapValue -Map $desktopActivation -Key 'status' -Default $status
      Write-CodexInfo ("desktop activation applied mode={0} saved_token={1} source={2}" -f [string]$modeChoice.mode, [string](Get-RaymanMapValue -Map $desktopActivation -Key 'saved_token_reused' -Default $false), [string](Get-RaymanMapValue -Map $desktopActivation -Key 'saved_token_source' -Default ''))
    } else {
      Write-CodexWarn ("desktop activation not applied for alias={0}: {1}" -f $normalizedAlias, [string](Get-RaymanMapValue -Map $desktopActivation -Key 'reason' -Default 'unknown'))
    }
  }
  if ([string](Get-RaymanMapValue -Map $status -Key 'guard_stage' -Default '') -ne 'codex.login') {
    $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $resolvedWorkspace -AccountAlias $normalizedAlias -GuardStage 'codex.login'
  }
  
  if ([bool]$status.authenticated) {
    Sync-WorkspaceTrust -WorkspaceRoot $resolvedWorkspace -Alias $normalizedAlias | Out-Null
  }
  Write-CodexInfo ("VS Code user profile={0}" -f (Format-VsCodeUserProfileText -ProfileState $profileState))
  Write-CodexInfo ("alias={0} status={1} mode={2}" -f $normalizedAlias, [string]$status.status, [string]$modeChoice.mode)
  Write-CodexRepeatErrorSummary -Status $status
  if ($LoginSmoke -and $login.PSObject.Properties['login_report_path']) {
    Write-CodexInfo ("login smoke report={0}" -f [string]$login.login_report_path)
  }

    Write-VsCodeReloadHint
  Invoke-CodexRepeatErrorGuardExitIfNeeded -Status $status -Stage 'codex login'
  return $login
}

function Invoke-ActionSwitch {
  param(
    [string]$Alias,
    [string]$Profile,
    [string]$TargetWorkspaceRoot,
    [switch]$PickWorkspace,
    [string]$Picker = 'auto'
  )

  $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $TargetWorkspaceRoot
  Ensure-CodexCliReady -WorkspaceRoot $resolvedWorkspace | Out-Null
  if ($PickWorkspace) {
    $workspaceRows = @(Get-WorkspaceRows)
    if ($workspaceRows.Count -eq 0) {
      Exit-CodexError 'No Rayman-known workspaces are available to pick.'
    }

    $pickedWorkspace = Select-WithFzfOrMenu -Rows $workspaceRows -Picker $Picker -Prompt 'Select workspace' -Render {
      param($row)
      "{0}  alias={1}  codex_execution_profile={2}  used={3}" -f [string]$row.workspace_root, $(if ([string]::IsNullOrWhiteSpace([string]$row.last_account_alias)) { '(unbound)' } else { [string]$row.last_account_alias }), (Format-CodexExecutionProfileText -Profile ([string]$row.last_profile)), [string]$row.last_used_at
    } -KeySelector {
      param($row)
      [string]$row.workspace_root
    }
    if ($null -eq $pickedWorkspace) {
      Exit-CodexError 'Workspace selection cancelled.'
    }
    $resolvedWorkspace = [string]$pickedWorkspace.workspace_root
  }

  $aliasRow = Select-CodexAliasRow -Alias $Alias -Picker $Picker -Prompt 'Select Codex alias' -TargetWorkspaceRoot $resolvedWorkspace

  $currentBinding = Get-RaymanCodexWorkspaceBinding -WorkspaceRoot $resolvedWorkspace
  $desiredAlias = [string]$aliasRow.alias
  $desiredProfile = Resolve-DesiredProfile -AccountRow $aliasRow -ExplicitProfile $Profile -CurrentBinding $currentBinding -DesiredAlias $desiredAlias
  if (-not [string]::IsNullOrWhiteSpace($Profile)) {
    Ensure-RaymanCodexAccount -Alias $desiredAlias -DefaultProfile $Profile -SetDefaultProfile | Out-Null
  }

  Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $resolvedWorkspace -AccountAlias $desiredAlias -Profile $desiredProfile | Out-Null
  $account = Ensure-RaymanCodexAccount -Alias $desiredAlias
  $desktopActivation = Invoke-RaymanCodexDesktopAliasActivation -WorkspaceRoot $resolvedWorkspace -Alias $desiredAlias -Account $account -Mode ([string](Get-RaymanMapValue -Map $account -Key 'auth_mode_last' -Default ''))
  $status = if ([bool](Get-RaymanMapValue -Map $desktopActivation -Key 'success' -Default $false) -and $null -ne (Get-RaymanMapValue -Map $desktopActivation -Key 'status' -Default $null)) {
    Get-RaymanMapValue -Map $desktopActivation -Key 'status' -Default $null
  } else {
    Get-RaymanCodexLoginStatus -WorkspaceRoot $resolvedWorkspace -AccountAlias $desiredAlias -GuardStage 'codex.switch'
  }
  $activationMode = Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $account -Key 'auth_mode_last' -Default ''))
  if ([string]::IsNullOrWhiteSpace([string]$activationMode)) {
    $activationMode = Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $status -Key 'auth_mode_last' -Default ''))
  }
  $desktopUnsyncedReason = [string](Get-RaymanMapValue -Map $status -Key 'desktop_unsynced_reason' -Default '')
  $shouldRepairWebSwitch = (
    (Test-RaymanCodexWindowsHost) -and
    [string]$activationMode -eq 'web' -and
    -not [bool]$status.authenticated -and
    (
      [string]$status.status -eq 'desktop_repair_needed' -or
      [string]$status.auth_mode_detected -eq 'apikey' -or
      [string]$status.desktop_global_cloud_access -eq 'disabled' -or
      -not [string]::IsNullOrWhiteSpace([string]$desktopUnsyncedReason)
    )
  )
  if ($shouldRepairWebSwitch) {
    Write-CodexWarn ("switch detected desktop/global web auth mismatch for alias={0}; triggering web relogin repair." -f $desiredAlias)
    $repairLogin = Invoke-CodexAliasNativeLogin -Alias $desiredAlias -TargetWorkspaceRoot $resolvedWorkspace -Profile $desiredProfile -Mode 'web'
    if ($null -ne $repairLogin) {
      $status = Get-RaymanMapValue -Map $repairLogin -Key 'status' -Default $status
      $account = Get-RaymanMapValue -Map $repairLogin -Key 'account' -Default $account
    }
  }
  if ([bool]$status.authenticated) {
    Sync-WorkspaceTrust -WorkspaceRoot $resolvedWorkspace -Alias $desiredAlias | Out-Null
  }
  Write-CodexInfo ("workspace={0}" -f $resolvedWorkspace)
  Write-CodexInfo ("VS Code user profile={0}" -f (Format-VsCodeUserProfileText -ProfileState $status))
  Write-CodexInfo ("alias={0} Codex execution profile={1} status={2}" -f $desiredAlias, (Format-CodexExecutionProfileText -Profile $desiredProfile), [string]$status.status)
  Write-CodexInfo ("auth_mode_last={0} native={1} {2}" -f (Format-CodexAuthModeLastText -Mode ([string]$status.auth_mode_last)), (Format-CodexNativeSessionText -Session $status.latest_native_session), (Format-CodexSavedStateSummaryText -Summary $status.saved_state_summary))
  if ([bool](Get-RaymanMapValue -Map $desktopActivation -Key 'attempted' -Default $false)) {
    if ([bool](Get-RaymanMapValue -Map $desktopActivation -Key 'success' -Default $false)) {
      Write-CodexInfo ("desktop activation applied mode={0} saved_token={1} source={2}" -f [string]$activationMode, [string](Get-RaymanMapValue -Map $desktopActivation -Key 'saved_token_reused' -Default $false), [string](Get-RaymanMapValue -Map $desktopActivation -Key 'saved_token_source' -Default ''))
    } else {
      Write-CodexWarn ("desktop activation not applied for alias={0}: {1}" -f $desiredAlias, [string](Get-RaymanMapValue -Map $desktopActivation -Key 'reason' -Default 'unknown'))
    }
  }
  if (-not [bool]$status.authenticated) {
    Write-CodexWarn ("login repair: {0}" -f [string]$status.repair_command)
  }
  Write-CodexRepeatErrorSummary -Status $status

    Write-VsCodeReloadHint
  Invoke-CodexRepeatErrorGuardExitIfNeeded -Status $status -Stage 'codex switch'
}

function Invoke-ActionRun {
  param(
    [string]$TargetWorkspaceRoot,
    [string[]]$PassthroughArgs
  )

  $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $TargetWorkspaceRoot
  $context = Resolve-RaymanCodexContext -WorkspaceRoot $resolvedWorkspace
  Ensure-CodexCliReady -WorkspaceRoot $resolvedWorkspace -AccountAlias ([string]$context.account_alias) | Out-Null
  $result = Invoke-RaymanCodexCommand -WorkspaceRoot $resolvedWorkspace -ArgumentList @($PassthroughArgs) -RequireManagedLogin
  if (Get-Command Invoke-RaymanSessionCommandCheckpoint -ErrorAction SilentlyContinue) {
    try {
      $checkpoint = Invoke-RaymanSessionCommandCheckpoint -WorkspaceRoot $resolvedWorkspace -DurationMs $(if ($result.PSObject.Properties['duration_ms']) { [int]$result.duration_ms } else { 0 }) -Backend 'codex' -AccountAlias $(if ($result.PSObject.Properties['context'] -and $null -ne $result.context -and $result.context.PSObject.Properties['account_alias']) { [string]$result.context.account_alias } else { '' }) -CommandText ([string]$result.command)
      if ($null -ne $checkpoint -and [bool]$checkpoint.checkpointed) {
        Write-CodexInfo ("temp checkpoint={0} reason={1}" -f [string]$checkpoint.session_slug, [string]$checkpoint.reason)
      }
    } catch {
      Write-CodexWarn ("temp checkpoint skipped: {0}" -f $_.Exception.Message)
    }
  }
  exit ([int]$result.exit_code)
}

function Invoke-ActionUpgrade {
  param(
    [string]$TargetWorkspaceRoot,
    [switch]$AsJson
  )

  $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $TargetWorkspaceRoot
  $context = Resolve-RaymanCodexContext -WorkspaceRoot $resolvedWorkspace
  $result = Ensure-CodexCliReady -WorkspaceRoot $resolvedWorkspace -AccountAlias ([string]$context.account_alias) -AsJson:$AsJson -ForceUpgrade

  $payload = [pscustomobject]@{
    schema = 'rayman.codex.upgrade.v1'
    generated_at = (Get-Date).ToString('o')
    workspace_root = $resolvedWorkspace
    policy = [string]$result.policy
    success = [bool]$result.success
    compatible = [bool]$result.compatible
    updated = [bool]$result.updated
    reason = [string]$result.reason
    npm_managed = [bool]$result.npm_managed
    version_before = [string]$result.version_before
    latest_version = [string]$result.latest_version
    version_after = [string]$result.version_after
    latest_check_attempted = [bool]$result.latest_check_attempted
    latest_check_succeeded = [bool]$result.latest_check_succeeded
    latest_check_output = [string]$result.latest_check_output
    output = [string]$result.output
  }

  if ($AsJson) {
    $payload | ConvertTo-Json -Depth 6
    return
  }

  Write-CodexInfo ("workspace={0}" -f $resolvedWorkspace)
  Write-CodexInfo ("version before={0} latest={1} after={2}" -f (Format-CodexVersionText -Version ([string]$payload.version_before)), (Format-CodexVersionText -Version ([string]$payload.latest_version)), (Format-CodexVersionText -Version ([string]$payload.version_after)))
  Write-CodexInfo ("policy={0} success={1} compatible={2} updated={3} reason={4}" -f [string]$payload.policy, [string]$payload.success, [string]$payload.compatible, [string]$payload.updated, [string]$payload.reason)
  if (-not [string]::IsNullOrWhiteSpace([string]$payload.output) -and -not [bool]$payload.updated) {
    Write-CodexWarn ([string]$payload.output)
  }

  return $payload
}

if (-not $manageAccountsIsMain) {
  return
}

$normalizedAction = if ([string]::IsNullOrWhiteSpace($Action)) { 'status' } else { $Action.Trim().ToLowerInvariant() }
$workspaceArg = Get-OptionValue -Tokens $ActionArgs -Names @('workspace-root', 'WorkspaceRoot') -Default $WorkspaceRoot
$pickerArg = Get-OptionValue -Tokens $ActionArgs -Names @('picker') -Default 'auto'
$jsonRequested = Test-HasToken -Tokens $ActionArgs -Names @('json', 'Json', 'as-json', 'AsJson')

try {
  switch ($normalizedAction) {
    'menu' {
      Invoke-ActionMenu -TargetWorkspaceRoot $workspaceArg -Picker $pickerArg
      break
    }
    'login' {
      $aliasArg = Get-OptionValue -Tokens $ActionArgs -Names @('alias')
      $profileArg = Get-OptionValue -Tokens $ActionArgs -Names @('profile')
      $modeArg = Get-OptionValue -Tokens $ActionArgs -Names @('mode')
      $apiKeyFromStdin = Test-HasToken -Tokens $ActionArgs -Names @('api-key-stdin')
      Invoke-ActionLogin -Alias $aliasArg -Profile $profileArg -TargetWorkspaceRoot $workspaceArg -Picker $pickerArg -Mode $modeArg -ApiKeyFromStdin:$apiKeyFromStdin
      break
    }
    'login-smoke' {
      $aliasArg = Get-OptionValue -Tokens $ActionArgs -Names @('alias')
      $profileArg = Get-OptionValue -Tokens $ActionArgs -Names @('profile')
      $modeArg = Get-OptionValue -Tokens $ActionArgs -Names @('mode')
      $forceArg = Test-HasToken -Tokens $ActionArgs -Names @('force')
      Invoke-ActionLogin -Alias $aliasArg -Profile $profileArg -TargetWorkspaceRoot $workspaceArg -Picker $pickerArg -Mode $modeArg -LoginSmoke -Force:$forceArg
      break
    }
    'list' {
      Invoke-ActionList -TargetWorkspaceRoot $workspaceArg -AsJson:$jsonRequested
      break
    }
    'status' {
      $allRequested = Test-HasToken -Tokens $ActionArgs -Names @('all')
      Invoke-ActionStatus -TargetWorkspaceRoot $workspaceArg -AllAccounts:$allRequested -AsJson:$jsonRequested
      break
    }
    'switch' {
      $aliasArg = Get-OptionValue -Tokens $ActionArgs -Names @('alias')
      $profileArg = Get-OptionValue -Tokens $ActionArgs -Names @('profile')
      $pickWorkspace = Test-HasToken -Tokens $ActionArgs -Names @('pick-workspace')
      Invoke-ActionSwitch -Alias $aliasArg -Profile $profileArg -TargetWorkspaceRoot $workspaceArg -PickWorkspace:$pickWorkspace -Picker $pickerArg
      break
    }
    'workspace' {
      $aliasArg = Get-OptionValue -Tokens $ActionArgs -Names @('alias')
      $profileArg = Get-OptionValue -Tokens $ActionArgs -Names @('profile')
      Invoke-ActionSwitch -Alias $aliasArg -Profile $profileArg -TargetWorkspaceRoot $workspaceArg -PickWorkspace -Picker $pickerArg
      break
    }
    'run' {
      $passthrough = Get-PassthroughArguments -Tokens $ActionArgs
      Invoke-ActionRun -TargetWorkspaceRoot $workspaceArg -PassthroughArgs $passthrough
      break
    }
    'upgrade' {
      Invoke-ActionUpgrade -TargetWorkspaceRoot $workspaceArg -AsJson:$jsonRequested | Out-Null
      break
    }
    default {
      Exit-CodexError ("Unknown codex action: {0}" -f $Action)
    }
  }
} catch {
  Exit-CodexError $_.Exception.Message
}

exit 0
