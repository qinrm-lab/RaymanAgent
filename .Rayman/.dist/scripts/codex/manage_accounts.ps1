param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$NoMain,
  [Parameter(Position=0)][string]$Action = 'status',
  [Parameter(Position=1, ValueFromRemainingArguments=$true)][string[]]$ActionArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
  throw "common.ps1 not found: $commonPath"
}
. $commonPath

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
    [switch]$ForceUpgrade
  )

  $result = Ensure-RaymanCodexCliUpToDate -WorkspaceRoot $WorkspaceRoot -AccountAlias $AccountAlias -ForceRefresh -ForceUpgrade:$ForceUpgrade
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

function Convert-StatusToRow {
  param(
    [object]$Account,
    [object]$Status
  )

  return [pscustomobject]@{
    alias = [string](Get-RaymanMapValue -Map $Account -Key 'alias' -Default '')
    codex_home = [string](Get-RaymanMapValue -Map $Account -Key 'codex_home' -Default '')
    default_profile = [string](Get-RaymanMapValue -Map $Account -Key 'default_profile' -Default '')
    authenticated = [bool](Get-RaymanMapValue -Map $Status -Key 'authenticated' -Default $false)
    status = [string](Get-RaymanMapValue -Map $Status -Key 'status' -Default 'unknown')
    last_checked_at = [string](Get-RaymanMapValue -Map $Status -Key 'generated_at' -Default '')
  }
}

function Get-RaymanCodexAccountRows {
  $registry = Get-RaymanCodexRegistry
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($key in @((ConvertTo-RaymanStringKeyMap -InputObject $registry.accounts).Keys | Sort-Object)) {
    $account = Get-RaymanMapValue -Map $registry.accounts -Key $key -Default $null
    if ($null -eq $account) { continue }
    $alias = [string](Get-RaymanMapValue -Map $account -Key 'alias' -Default $key)
    $status = Get-RaymanCodexLoginStatus -AccountAlias $alias -SkipReportWrite
    $rows.Add((Convert-StatusToRow -Account $account -Status $status)) | Out-Null
  }
  return @($rows.ToArray())
}

function Get-RaymanCodexAliasRow {
  param(
    [string]$Alias
  )

  $normalizedAlias = Normalize-RaymanCodexAlias -Alias $Alias
  if ([string]::IsNullOrWhiteSpace($normalizedAlias)) {
    return $null
  }

  foreach ($row in @(Get-RaymanCodexAccountRows)) {
    if ([string]$row.alias -ieq $normalizedAlias) {
      return $row
    }
  }
  return $null
}

function Get-LoginAliasRows {
  param(
    [string]$TargetWorkspaceRoot
  )

  $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $TargetWorkspaceRoot
  $binding = if ([string]::IsNullOrWhiteSpace($resolvedWorkspace)) {
    [pscustomobject]@{ account_alias = ''; profile = '' }
  } else {
    Get-RaymanCodexWorkspaceBinding -WorkspaceRoot $resolvedWorkspace
  }
  $currentAlias = Normalize-RaymanCodexAlias -Alias ([string]$binding.account_alias)
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

  if (-not [string]::IsNullOrWhiteSpace($currentAlias)) {
    Add-LoginAliasRow -Alias $currentAlias -Kind 'alias' -Tag '当前绑定'
  }
  Add-LoginAliasRow -Alias 'main' -Kind 'alias' -Tag '主账号推荐' -Recommended:$true
  foreach ($row in @(Get-RaymanCodexAccountRows)) {
    Add-LoginAliasRow -Alias ([string]$row.alias) -Kind 'alias' -Tag '已有 alias'
  }
  Add-LoginAliasRow -Alias 'gpt-alt' -Kind 'alias' -Tag '推荐第二账号' -Recommended:$true
  Add-LoginAliasRow -Alias '' -Kind 'custom' -Tag '手工输入'

  return @($rows.ToArray())
}

function Read-MenuSelection {
  param(
    [string]$Title,
    [object[]]$Rows,
    [scriptblock]$Render,
    [object]$DefaultRow = $null
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

  $raw = Read-Host 'Select'
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return $DefaultRow
  }

  $index = 0
  if (-not [int]::TryParse($raw, [ref]$index)) {
    return $null
  }
  if ($index -lt 1 -or $index -gt $Rows.Count) {
    return $null
  }
  return $Rows[$index - 1]
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

  return (Read-MenuSelection -Title $Prompt -Rows $items -Render $Render -DefaultRow $DefaultRow)
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
    [string]$Picker = 'auto'
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
  $loginRows = @(Get-LoginAliasRows -TargetWorkspaceRoot $resolvedWorkspace)
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
    [pscustomobject]@{ action = 'list'; label = '账号列表'; description = '列出已知 alias、认证状态、默认 profile 和 home'; recommended = $false }
    [pscustomobject]@{ action = 'login'; label = '登录账号'; description = '用设备码登录 main / gpt-alt / 已有 alias，或手工输入'; recommended = $false }
    [pscustomobject]@{ action = 'switch'; label = '切换账号'; description = '把当前 workspace 绑定到另一个已知 alias'; recommended = $false }
    [pscustomobject]@{ action = 'manage'; label = '管理账号'; description = '查看详情、更新默认 profile、重登、删除 alias'; recommended = $false }
    [pscustomobject]@{ action = 'run'; label = '运行 Codex CLI'; description = '输入简单参数后透传给 codex CLI'; recommended = $false }
    [pscustomobject]@{ action = 'upgrade'; label = '升级 Codex CLI'; description = '检查并升级当前宿主上的 Codex CLI'; recommended = $false }
  )
}

function Get-CodexManageActionRows {
  return @(
    [pscustomobject]@{ action = 'details'; label = '查看详情'; description = '显示 alias、状态、默认 profile、CODEX_HOME 和绑定情况'; recommended = $true }
    [pscustomobject]@{ action = 'set-default-profile'; label = '更新默认 profile'; description = '修改 alias 的默认 Codex execution profile'; recommended = $false }
    [pscustomobject]@{ action = 'relogin'; label = '重新设备码登录'; description = '复用当前 alias 容器重新执行 codex login --device-auth'; recommended = $false }
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
  $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $resolvedWorkspace -AccountAlias ([string]$context.account_alias) -SkipReportWrite
  Write-Host ''
  Write-CodexInfo ("workspace={0}" -f $resolvedWorkspace)
  Write-CodexInfo ("alias={0}" -f $(if ([string]::IsNullOrWhiteSpace([string]$context.account_alias)) { '(unbound)' } else { [string]$context.account_alias }))
  Write-CodexInfo ("认证状态={0}" -f [string]$status.status)
  Write-CodexInfo ("VS Code user profile={0}" -f (Format-VsCodeUserProfileText -ProfileState $context))
  Write-CodexInfo ("Codex execution profile={0}" -f (Format-CodexExecutionProfileText -Profile ([string]$context.effective_profile)))
}

function Select-CodexAliasRow {
  param(
    [string]$Alias,
    [string]$Picker = 'auto',
    [string]$Prompt = 'Select Codex alias'
  )

  if (-not [string]::IsNullOrWhiteSpace($Alias)) {
    $aliasRow = Get-RaymanCodexAliasRow -Alias $Alias
    if ($null -eq $aliasRow) {
      Exit-CodexError ("Unknown Codex alias '{0}'." -f $Alias)
    }
    return $aliasRow
  }

  $aliasRows = @(Get-RaymanCodexAccountRows)
  if ($aliasRows.Count -eq 0) {
    Exit-CodexError 'No Rayman-managed Codex aliases are available. Run `rayman codex login --alias <alias>` first.'
  }

  $defaultRow = $aliasRows | Select-Object -First 1
  $picked = Select-WithFzfOrMenu -Rows $aliasRows -Picker $Picker -Prompt $Prompt -Render {
    param($row)
    "{0}  [{1}]  codex_execution_profile={2}" -f [string]$row.alias, [string]$row.status, (Format-CodexExecutionProfileText -Profile ([string]$row.default_profile))
  } -KeySelector {
    param($row)
    [string]$row.alias
  } -DefaultRow $defaultRow
  if ($null -eq $picked) {
    Exit-CodexError 'Alias selection cancelled.'
  }
  return $picked
}

function Invoke-CodexAliasDeviceAuth {
  param(
    [string]$Alias,
    [string]$TargetWorkspaceRoot,
    [string]$Profile = '',
    [switch]$SetDefaultProfile
  )

  $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $TargetWorkspaceRoot
  $normalizedAlias = Normalize-RaymanCodexAlias -Alias $Alias
  Ensure-CodexCliReady -WorkspaceRoot $resolvedWorkspace -AccountAlias $normalizedAlias | Out-Null
  $account = Ensure-RaymanCodexAccount -Alias $normalizedAlias -DefaultProfile $Profile -SetDefaultProfile:$SetDefaultProfile
  Write-CodexInfo ("starting device auth for alias={0}" -f $normalizedAlias)
  Write-CodexInfo ("after browser approval, tell the agent: 已授权 {0}" -f $normalizedAlias)
  $result = Invoke-RaymanCodexRawInteractive -CodexHome ([string]$account.codex_home) -WorkingDirectory $resolvedWorkspace -ArgumentList @('login', '--device-auth') -PreferHiddenWindow
  if ((-not [bool]$result.success) -and (Test-RaymanWindowsPlatform)) {
    Write-CodexWarn 'hidden device auth launch failed; retrying with the legacy foreground flow.'
    $result = Invoke-RaymanCodexRawInteractive -CodexHome ([string]$account.codex_home) -WorkingDirectory $resolvedWorkspace -ArgumentList @('login', '--device-auth')
  }
  if (-not [bool]$result.success) {
    Exit-CodexError ("codex login failed for alias '{0}'." -f $normalizedAlias) $result.exit_code
  }

  $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $resolvedWorkspace -AccountAlias $normalizedAlias
  return [pscustomobject]@{
    workspace_root = $resolvedWorkspace
    alias = $normalizedAlias
    account = $account
    status = $status
  }
}

function Show-CodexAliasDetails {
  param(
    [object]$AliasRow,
    [string]$TargetWorkspaceRoot
  )

  $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $TargetWorkspaceRoot
  $alias = [string](Get-RaymanMapValue -Map $AliasRow -Key 'alias' -Default '')
  $account = Get-RaymanCodexAccountRecord -Alias $alias
  $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $resolvedWorkspace -AccountAlias $alias -SkipReportWrite
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
  Write-CodexInfo ("default Codex execution profile={0}" -f (Format-CodexExecutionProfileText -Profile ([string](Get-RaymanMapValue -Map $account -Key 'default_profile' -Default ''))))
  Write-CodexInfo ("CODEX_HOME={0}" -f [string](Get-RaymanMapValue -Map $account -Key 'codex_home' -Default ''))
  Write-CodexInfo ("current workspace bound={0}" -f $(if ($boundToCurrentWorkspace) { 'yes' } else { 'no' }))
  Write-CodexInfo ("known workspace references={0}" -f @($references | Where-Object { [bool]$_.registry_matches -or [bool]$_.binding_matches }).Count)
}

function Invoke-CodexManageAlias {
  param(
    [string]$TargetWorkspaceRoot,
    [string]$Picker = 'auto'
  )

  $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $TargetWorkspaceRoot
  $aliasRow = Select-CodexAliasRow -Picker $Picker -Prompt '选择要管理的 alias'
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
      $result = Invoke-CodexAliasDeviceAuth -Alias $selectedAlias -TargetWorkspaceRoot $resolvedWorkspace
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
    'list' { Invoke-ActionList; return }
    'login' { Invoke-ActionLogin -Alias '' -Profile '' -TargetWorkspaceRoot $TargetWorkspaceRoot -Picker $Picker; return }
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
    [switch]$AsJson
  )

  $rows = @(Get-RaymanCodexAccountRows)
  if ($AsJson) {
    [pscustomobject]@{
      schema = 'rayman.codex.accounts.list.v1'
      generated_at = (Get-Date).ToString('o')
      accounts = $rows
    } | ConvertTo-Json -Depth 8
    return
  }

  if ($rows.Count -eq 0) {
    Write-CodexInfo 'No Rayman-managed Codex aliases have been registered yet.'
    return
  }

  foreach ($row in $rows) {
    Write-Host ("- {0} [{1}] Codex execution profile={2} home={3}" -f [string]$row.alias, [string]$row.status, (Format-CodexExecutionProfileText -Profile ([string]$row.default_profile)), [string]$row.codex_home)
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
    Invoke-ActionList -AsJson:$AsJson
    return
  }

  $resolvedWorkspace = Resolve-WorkspaceRootInput -InputRoot $TargetWorkspaceRoot
  $preflightContext = Resolve-RaymanCodexContext -WorkspaceRoot $resolvedWorkspace
  $cliUpdate = Ensure-CodexCliReady -WorkspaceRoot $resolvedWorkspace -AccountAlias ([string]$preflightContext.account_alias) -AsJson:$AsJson
  $context = Resolve-RaymanCodexContext -WorkspaceRoot $resolvedWorkspace
  $binding = Get-RaymanCodexWorkspaceBinding -WorkspaceRoot $resolvedWorkspace
  $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $resolvedWorkspace -AccountAlias $context.account_alias
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
  if (-not [string]::IsNullOrWhiteSpace([string]$status.repair_command) -and -not [bool]$status.authenticated -and [bool]$context.managed) {
    Write-CodexWarn ("login repair: {0}" -f [string]$status.repair_command)
  }
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

  $result = Set-RaymanCodexWorkspaceTrust -WorkspaceRoot $WorkspaceRoot -Alias $Alias -TrustLevel $TrustLevel
  Write-CodexInfo ("workspace trust={0} alias={1} config={2}{3}" -f [string]$result.trust_level, [string]$Alias, [string]$result.config_path, $(if ([bool]$result.changed) { ' [updated]' } else { ' [unchanged]' }))
  return $result
}

function Invoke-ActionLogin {
  param(
    [string]$Alias,
    [string]$Profile,
    [string]$TargetWorkspaceRoot,
    [string]$Picker = 'auto'
  )

  $selection = Resolve-LoginAliasChoice -Alias $Alias -TargetWorkspaceRoot $TargetWorkspaceRoot -Picker $Picker
  $normalizedAlias = [string]$selection.alias
  $resolvedWorkspace = [string]$selection.workspace_root
  $profileState = $selection.vscode_user_profile_state

  $deviceAuth = Invoke-CodexAliasDeviceAuth -Alias $normalizedAlias -TargetWorkspaceRoot $resolvedWorkspace -Profile $Profile -SetDefaultProfile:(-not [string]::IsNullOrWhiteSpace($Profile))
  $account = $deviceAuth.account
  $status = $deviceAuth.status

  $bindingProfile = if ([string]::IsNullOrWhiteSpace($Profile)) { [string]$account.default_profile } else { [string]$Profile }
  Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $resolvedWorkspace -AccountAlias $normalizedAlias -Profile $bindingProfile | Out-Null
  if ([bool]$status.authenticated) {
    Sync-WorkspaceTrust -WorkspaceRoot $resolvedWorkspace -Alias $normalizedAlias | Out-Null
  }
  Write-CodexInfo ("VS Code user profile={0}" -f (Format-VsCodeUserProfileText -ProfileState $profileState))
  Write-CodexInfo ("alias={0} status={1}" -f $normalizedAlias, [string]$status.status)
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

  $aliasRow = Select-CodexAliasRow -Alias $Alias -Picker $Picker -Prompt 'Select Codex alias'

  $currentBinding = Get-RaymanCodexWorkspaceBinding -WorkspaceRoot $resolvedWorkspace
  $desiredAlias = [string]$aliasRow.alias
  $desiredProfile = Resolve-DesiredProfile -AccountRow $aliasRow -ExplicitProfile $Profile -CurrentBinding $currentBinding -DesiredAlias $desiredAlias
  if (-not [string]::IsNullOrWhiteSpace($Profile)) {
    Ensure-RaymanCodexAccount -Alias $desiredAlias -DefaultProfile $Profile -SetDefaultProfile | Out-Null
  }

  Set-RaymanCodexWorkspaceBinding -WorkspaceRoot $resolvedWorkspace -AccountAlias $desiredAlias -Profile $desiredProfile | Out-Null
  $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $resolvedWorkspace -AccountAlias $desiredAlias
  if ([bool]$status.authenticated) {
    Sync-WorkspaceTrust -WorkspaceRoot $resolvedWorkspace -Alias $desiredAlias | Out-Null
  }
  Write-CodexInfo ("workspace={0}" -f $resolvedWorkspace)
  Write-CodexInfo ("VS Code user profile={0}" -f (Format-VsCodeUserProfileText -ProfileState $status))
  Write-CodexInfo ("alias={0} Codex execution profile={1} status={2}" -f $desiredAlias, (Format-CodexExecutionProfileText -Profile $desiredProfile), [string]$status.status)
  if (-not [bool]$status.authenticated) {
    Write-CodexWarn ("login repair: {0}" -f [string]$status.repair_command)
  }
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

if ($NoMain) {
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
      Invoke-ActionLogin -Alias $aliasArg -Profile $profileArg -TargetWorkspaceRoot $workspaceArg -Picker $pickerArg
      break
    }
    'list' {
      Invoke-ActionList -AsJson:$jsonRequested
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
