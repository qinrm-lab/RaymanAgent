param(
  [Parameter(Position=0)][string]$Command = "help",
  [Parameter(Position=1, ValueFromRemainingArguments=$true)][string[]]$CliArgs
)

. (Join-Path $PSScriptRoot 'common.ps1')
$commandCatalogScript = Join-Path $PSScriptRoot 'scripts\utils\command_catalog.ps1'
if (Test-Path -LiteralPath $commandCatalogScript -PathType Leaf) {
  . $commandCatalogScript
}
$postCommandHygieneScript = Join-Path $PSScriptRoot 'scripts\utils\post_command_hygiene.ps1'
if (Test-Path -LiteralPath $postCommandHygieneScript -PathType Leaf) {
  . $postCommandHygieneScript -NoMain
}

$stateScript = Join-Path $PSScriptRoot 'lib\state.ps1'
if (Test-Path -LiteralPath $stateScript -PathType Leaf) {
  . $stateScript
}

$cmd = $Command.ToLowerInvariant()
$commandProvided = $PSBoundParameters.ContainsKey('Command')
$script:RaymanCliWorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:RaymanCliInvokedFromMenu = $false
if ($null -eq $CliArgs) {
  $CliArgs = @()
} else {
  $CliArgs = @($CliArgs)
}

function Get-RaymanMenuStatePath {
  param([string]$WorkspaceRoot = $script:RaymanCliWorkspaceRoot)

  $workspaceRoot = $WorkspaceRoot
  $runtimeDir = Join-Path $workspaceRoot '.Rayman\runtime'
  if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
  }
  return (Join-Path $runtimeDir 'menu_last_choice.json')
}

function Get-RaymanLastMenuChoice {
  param([string]$WorkspaceRoot = $script:RaymanCliWorkspaceRoot)

  $statePath = Get-RaymanMenuStatePath -WorkspaceRoot $WorkspaceRoot
  if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
  try {
    $obj = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    return $obj
  } catch {
    return $null
  }
}

function Set-RaymanLastMenuChoice {
  param(
    [int]$Index,
    [string]$CommandName,
    [string[]]$CommandArgs,
    [string]$WorkspaceRoot = $script:RaymanCliWorkspaceRoot
  )

  try {
    $statePath = Get-RaymanMenuStatePath -WorkspaceRoot $WorkspaceRoot
    $payload = [ordered]@{
      index = $Index
      command = $CommandName
      args = @($CommandArgs)
      updatedAt = (Get-Date).ToString('o')
    }
    $json = $payload | ConvertTo-Json -Depth 8
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($statePath, $json, $utf8NoBom)
  } catch {
    # ignore menu state persistence failures
  }
}

function Get-RaymanInteractiveMenuDefaultArgs {
  param([string]$CommandName)

  switch ([string]$CommandName) {
    'codex' { return @('menu') }
    'prompts' { return @('-Action', 'list') }
    'proxy-health' { return @('--refresh') }
    default { return @() }
  }
}

function Get-RaymanInteractiveMenuEntries {
  param([string]$WorkspaceRoot = $script:RaymanCliWorkspaceRoot)

  if (-not (Get-Command Import-RaymanCommandCatalog -ErrorAction SilentlyContinue)) {
    throw 'command catalog helpers are unavailable.'
  }

  $menu = New-Object System.Collections.Generic.List[object]
  $displayIndex = 0
  foreach ($entry in @(Import-RaymanCommandCatalog -WorkspaceRoot $WorkspaceRoot)) {
    $name = [string]$entry.name
    if ($name -in @('help', 'menu')) {
      continue
    }

    $platform = [string]$entry.platform
    if ($platform -eq 'windows-only') {
      $isWindowsHost = $false
      try {
        $isWindowsHost = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
      } catch {
        $isWindowsHost = $false
      }
      if (-not $isWindowsHost) {
        continue
      }
    }

    $displayIndex++
    $menu.Add([ordered]@{
        Index = $displayIndex
        Command = $name
        Desc = [string]$entry.summary
        DefaultArgs = @(Get-RaymanInteractiveMenuDefaultArgs -CommandName $name)
        Recommended = [bool]$entry.recommended
        Platform = $platform
        Group = [string]$entry.group
      }) | Out-Null
  }

  return @($menu.ToArray())
}

function Resolve-RaymanDefaultMenuItem {
  param(
    [object[]]$MenuEntries,
    [string]$WorkspaceRoot = $script:RaymanCliWorkspaceRoot
  )

  $menu = @($MenuEntries)
  if ($menu.Count -eq 0) { return $null }

  $last = Get-RaymanLastMenuChoice -WorkspaceRoot $WorkspaceRoot
  if ($null -ne $last) {
    if ($last.PSObject.Properties['command'] -and -not [string]::IsNullOrWhiteSpace([string]$last.command)) {
      $matchedByCommand = $menu | Where-Object { [string]$_.Command -ieq [string]$last.command } | Select-Object -First 1
      if ($matchedByCommand) {
        return $matchedByCommand
      }
    }

    if ($last.PSObject.Properties['index']) {
      $parsedIndex = 0
      if ([int]::TryParse([string]$last.index, [ref]$parsedIndex)) {
        $matchedByIndex = $menu | Where-Object { [int]$_.Index -eq $parsedIndex } | Select-Object -First 1
        if ($matchedByIndex) {
          return $matchedByIndex
        }
      }
    }
  }

  return $null
}

function Resolve-RaymanInteractiveMenuSelection {
  param([object]$Selection)

  if ($null -eq $Selection) {
    return $null
  }

  $commandName = ''
  $args = @()
  $hasCommand = $false
  $hasCliArgs = $false

  if ($Selection -is [System.Collections.IDictionary]) {
    $dict = [System.Collections.IDictionary]$Selection
    foreach ($key in $dict.Keys) {
      if (-not $hasCommand -and [string]$key -ieq 'Command') {
        $commandName = [string]$dict[$key]
        $hasCommand = $true
      }
      if (-not $hasCliArgs -and [string]$key -ieq 'CliArgs') {
        $args = @($dict[$key])
        $hasCliArgs = $true
      }
    }
  } else {
    if ($Selection.PSObject.Properties['Command']) {
      $commandName = [string]$Selection.Command
      $hasCommand = $true
    }
    if ($Selection.PSObject.Properties['CliArgs']) {
      $args = @($Selection.CliArgs)
      $hasCliArgs = $true
    }
  }

  if (-not $hasCommand -or [string]::IsNullOrWhiteSpace($commandName)) {
    throw 'Interactive menu returned an invalid selection object.'
  }
  if (-not $hasCliArgs) {
    $args = @()
  }

  return @{
    Command = $commandName
    CliArgs = [string[]]@($args | ForEach-Object { [string]$_ })
  }
}

function Show-RaymanInteractiveMenu {
  param([string]$WorkspaceRoot = $script:RaymanCliWorkspaceRoot)

  $menu = @(Get-RaymanInteractiveMenuEntries -WorkspaceRoot $WorkspaceRoot)
  $defaultItem = Resolve-RaymanDefaultMenuItem -MenuEntries $menu -WorkspaceRoot $WorkspaceRoot
  $defaultIndex = 0
  if ($defaultItem) {
    $defaultIndex = [int]$defaultItem.Index
  }

  Write-Host @"
=======================================================
🤖 Rayman 交互菜单（输入编号即可）
=======================================================
"@

  foreach ($item in $menu) {
    $marker = ' '
    if ($defaultIndex -gt 0 -and [int]$item.Index -eq $defaultIndex) {
      $marker = '★'
    }
    $desc = [string]$item.Desc
    if ([bool]$item.Recommended) {
      $desc = ('{0} [推荐]' -f $desc)
    }
    Write-Host ("{0} {1,2}) {2,-17} {3}" -f $marker, [int]$item.Index, [string]$item.Command, $desc)
  }

  Write-Host @"

可输入：
 - 编号（如 6）
 - 回车（默认执行上次选择）
 - 命令名（如 test-fix）
 - q / quit / exit 退出
=======================================================
"@

  if ($defaultIndex -gt 0) {
    $choice = Read-Host ("请选择操作（默认 {0}）" -f $defaultIndex)
  } else {
    $choice = Read-Host "请选择操作"
  }

  if ([string]::IsNullOrWhiteSpace($choice)) {
    if ($defaultItem) {
      Set-RaymanLastMenuChoice -Index ([int]$defaultItem.Index) -CommandName ([string]$defaultItem.Command) -CommandArgs @($defaultItem.DefaultArgs) -WorkspaceRoot $WorkspaceRoot
      return @{
        Command = [string]$defaultItem.Command
        CliArgs = [string[]]@($defaultItem.DefaultArgs)
      }
    }
    return @{
      Command = 'help'
      CliArgs = @()
    }
  }

  $token = $choice.Trim()
  switch -Regex ($token.ToLowerInvariant()) {
    '^(q|quit|exit)$' { return $null }
  }

  $parsedIndex = 0
  if ([int]::TryParse($token, [ref]$parsedIndex)) {
    $pickedByIndex = $menu | Where-Object { [int]$_.Index -eq $parsedIndex } | Select-Object -First 1
    if ($pickedByIndex) {
      Set-RaymanLastMenuChoice -Index ([int]$pickedByIndex.Index) -CommandName ([string]$pickedByIndex.Command) -CommandArgs @($pickedByIndex.DefaultArgs) -WorkspaceRoot $WorkspaceRoot
      return @{
        Command = [string]$pickedByIndex.Command
        CliArgs = [string[]]@($pickedByIndex.DefaultArgs)
      }
    }
  }

  $parts = @($token -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($parts.Count -eq 0) {
    return @{
      Command = 'help'
      CliArgs = @()
    }
  }

  $name = [string]$parts[0]
  $extraArgs = @()
  if ($parts.Count -gt 1) {
    $extraArgs = @($parts[1..($parts.Count - 1)])
  }

  $matched = $menu | Where-Object { [string]$_.Command -ieq $name } | Select-Object -First 1
  if ($matched) {
    $finalArgs = @($matched.DefaultArgs) + @($extraArgs)
    if ([string]$matched.Command -ieq 'codex' -and $extraArgs.Count -gt 0) {
      $finalArgs = @($extraArgs)
    }
    Set-RaymanLastMenuChoice -Index ([int]$matched.Index) -CommandName ([string]$matched.Command) -CommandArgs $finalArgs -WorkspaceRoot $WorkspaceRoot
    return @{
      Command = [string]$matched.Command
      CliArgs = [string[]]$finalArgs
    }
  }

  Set-RaymanLastMenuChoice -Index 0 -CommandName $name -CommandArgs $extraArgs -WorkspaceRoot $WorkspaceRoot
  return @{
    Command = $name
    CliArgs = [string[]]$extraArgs
  }
}

function Show-Help {
  $helpText = ''
  if (Get-Command Format-RaymanHelpText -ErrorAction SilentlyContinue) {
    $helpText = (Format-RaymanHelpText -WorkspaceRoot $script:RaymanCliWorkspaceRoot -Surface pwsh)
  } else {
    $helpVersion = 'v165'
    if (Get-Command Get-RaymanCatalogVersionToken -ErrorAction SilentlyContinue) {
      $helpVersion = Get-RaymanCatalogVersionToken -WorkspaceRoot $script:RaymanCliWorkspaceRoot
    }

    $helpText = @"
Rayman CLI ($helpVersion)

Usage:
  .\.Rayman\rayman.cmd <command>
"@
  }

  Write-Output $helpText
  Write-Output ''
  Write-Output '提示：交互式终端里直接运行 `.\.Rayman\rayman.ps1 codex` 会进入 Codex 二级菜单。'
}

function Test-RaymanInteractiveConsoleAvailable {
  try {
    return (-not [Console]::IsInputRedirected)
  } catch {
    return $true
  }
}

function Test-RaymanShouldEnterCodexMenu {
  param(
    [string]$CommandName,
    [string[]]$InputArgs = @()
  )

  if ([string]::IsNullOrWhiteSpace($CommandName)) {
    return $false
  }
  if ($CommandName.Trim().ToLowerInvariant() -ne 'codex') {
    return $false
  }
  if (@($InputArgs).Count -gt 0) {
    return $false
  }
  return (Test-RaymanInteractiveConsoleAvailable)
}

function Get-RaymanInteractionModeChoices {
  return @(
    [pscustomobject]@{
      Value = 'detailed'
      Label = '详细'
      Summary = '尽可能多先给 plan 和选项说明，再收集你的选择。'
    },
    [pscustomobject]@{
      Value = 'general'
      Label = '一般'
      Summary = '只在会明显改变结果或返工成本的歧义上先停下来确认。'
    },
    [pscustomobject]@{
      Value = 'simple'
      Label = '简单'
      Summary = '只在高风险或明显可能走错方向时先确认，其余快速继续。'
    }
  )
}

function Get-RaymanInteractionModeChoice {
  param([string]$Mode)

  $normalized = if (Get-Command Normalize-RaymanInteractionMode -ErrorAction SilentlyContinue) {
    Normalize-RaymanInteractionMode -Mode $Mode -Default 'detailed'
  } else {
    'detailed'
  }
  return @(Get-RaymanInteractionModeChoices | Where-Object { [string]$_.Value -eq $normalized } | Select-Object -First 1)[0]
}

function Write-RaymanInteractionModeStatus {
  param([string]$WorkspaceRoot = $script:RaymanCliWorkspaceRoot)

  $mode = if (Get-Command Get-RaymanInteractionMode -ErrorAction SilentlyContinue) {
    Get-RaymanInteractionMode -WorkspaceRoot $WorkspaceRoot
  } else {
    'detailed'
  }
  $choice = Get-RaymanInteractionModeChoice -Mode $mode
  $description = if (Get-Command Get-RaymanInteractionModeDescription -ErrorAction SilentlyContinue) {
    Get-RaymanInteractionModeDescription -Mode $mode
  } else {
    ''
  }
  $example = if (Get-Command Get-RaymanInteractionModeExamples -ErrorAction SilentlyContinue) {
    Get-RaymanInteractionModeExamples -Mode $mode
  } else {
    ''
  }

  Write-Host ("[interaction-mode] workspace={0}" -f $WorkspaceRoot) -ForegroundColor DarkCyan
  Write-Host ("[interaction-mode] current={0} ({1})" -f [string]$choice.Value, [string]$choice.Label) -ForegroundColor Cyan
  if (-not [string]::IsNullOrWhiteSpace($description)) {
    Write-Host ("[interaction-mode] rule={0}" -f $description) -ForegroundColor Gray
  }
  if (-not [string]::IsNullOrWhiteSpace($example)) {
    Write-Host ("[interaction-mode] note={0}" -f $example) -ForegroundColor DarkGray
  }
}

function Read-RaymanInteractionModeSelection {
  param([string]$WorkspaceRoot = $script:RaymanCliWorkspaceRoot)

  $currentMode = if (Get-Command Get-RaymanInteractionMode -ErrorAction SilentlyContinue) {
    Get-RaymanInteractionMode -WorkspaceRoot $WorkspaceRoot
  } else {
    'detailed'
  }
  $choices = @(Get-RaymanInteractionModeChoices)

  Write-Host '=======================================================' -ForegroundColor Cyan
  Write-Host 'Rayman 交互模式' -ForegroundColor Cyan
  Write-Host '=======================================================' -ForegroundColor Cyan
  for ($i = 0; $i -lt $choices.Count; $i++) {
    $choice = $choices[$i]
    $marker = if ([string]$choice.Value -eq [string]$currentMode) { '★' } else { ' ' }
    Write-Host ("{0} {1}) {2,-8} {3}" -f $marker, ($i + 1), ([string]$choice.Label + ' / ' + [string]$choice.Value), [string]$choice.Summary)
  }
  Write-Host ''
  Write-Host '说明：跨工作区 target 选择、policy block、release gate、危险操作等硬门禁仍然会停下。' -ForegroundColor DarkYellow
  Write-Host '可输入：编号、模式名（detailed/general/simple）、回车保留当前值、q 取消。' -ForegroundColor DarkGray

  $currentChoice = Get-RaymanInteractionModeChoice -Mode $currentMode
  $selection = Read-Host ("请选择交互模式（默认 {0}）" -f [string]$currentChoice.Value)
  if ([string]::IsNullOrWhiteSpace([string]$selection)) {
    return $currentMode
  }

  $token = ([string]$selection).Trim().ToLowerInvariant()
  if ($token -match '^(q|quit|exit|cancel)$') {
    return ''
  }

  $parsedIndex = 0
  if ([int]::TryParse($token, [ref]$parsedIndex) -and $parsedIndex -ge 1 -and $parsedIndex -le $choices.Count) {
    return [string]$choices[$parsedIndex - 1].Value
  }

  if (Get-Command Normalize-RaymanInteractionMode -ErrorAction SilentlyContinue) {
    $normalized = Normalize-RaymanInteractionMode -Mode $token -Default ''
    if (-not [string]::IsNullOrWhiteSpace([string]$normalized)) {
      return $normalized
    }
  }

  throw ("invalid interaction mode selection: {0}" -f $selection)
}

function Set-RaymanInteractionModePreference {
  param(
    [string]$WorkspaceRoot = $script:RaymanCliWorkspaceRoot,
    [string]$Mode
  )

  if (-not (Get-Command Normalize-RaymanInteractionMode -ErrorAction SilentlyContinue)) {
    throw 'interaction mode helpers are unavailable.'
  }
  $normalized = Normalize-RaymanInteractionMode -Mode $Mode -Default ''
  if ([string]::IsNullOrWhiteSpace([string]$normalized)) {
    throw ("invalid interaction mode: {0}" -f $Mode)
  }

  $result = Set-RaymanWorkspaceEnvValue `
    -WorkspaceRoot $WorkspaceRoot `
    -Name 'RAYMAN_INTERACTION_MODE' `
    -Value $normalized `
    -AddIfMissing `
    -ManagedBlockId 'RAYMAN:INTERACTION:MODE' `
    -ManagedBy 'Rayman interaction-mode'
  if (-not [bool]$result.Ok) {
    throw ("failed to persist interaction mode: {0}" -f [string]$result.Reason)
  }

  $refreshFailures = New-Object System.Collections.Generic.List[string]
  $refreshScripts = @(
    [pscustomobject]@{
      Path = (Join-Path $WorkspaceRoot '.Rayman\scripts\skills\inject_codex_fix_prompt.ps1')
      Parameters = @{}
      Label = '.Rayman/codex_fix_prompt.txt'
    },
    [pscustomobject]@{
      Path = (Join-Path $WorkspaceRoot '.Rayman\scripts\utils\generate_context.ps1')
      Parameters = @{ WorkspaceRoot = $WorkspaceRoot }
      Label = '.Rayman/CONTEXT.md'
    }
  )
  foreach ($script in $refreshScripts) {
    if (-not (Test-Path -LiteralPath ([string]$script.Path) -PathType Leaf)) {
      $refreshFailures.Add(("missing refresh script for {0}: {1}" -f [string]$script.Label, [string]$script.Path)) | Out-Null
      continue
    }

    try {
      $scriptParams = @{}
      foreach ($entry in @($script.Parameters.GetEnumerator())) {
        $scriptParams[[string]$entry.Key] = $entry.Value
      }
      if (Test-Path variable:LASTEXITCODE) {
        $global:LASTEXITCODE = 0
      }
      & ([string]$script.Path) @scriptParams | Out-Null
      if (-not $?) {
        $refreshFailures.Add(("refresh failed for {0}" -f [string]$script.Label)) | Out-Null
      }
    } catch {
      $refreshFailures.Add(("refresh failed for {0}: {1}" -f [string]$script.Label, $_.Exception.Message)) | Out-Null
    }
  }
  if ($refreshFailures.Count -gt 0) {
    throw ("interaction mode saved but refresh failed: {0}" -f (($refreshFailures | Select-Object -Unique) -join '; '))
  }

  $choice = Get-RaymanInteractionModeChoice -Mode $normalized
  Write-Host ("[interaction-mode] saved={0} ({1}) path={2}" -f [string]$choice.Value, [string]$choice.Label, [string]$result.Path) -ForegroundColor Green
  Write-Host ("[interaction-mode] rule={0}" -f (Get-RaymanInteractionModeDescription -Mode $normalized)) -ForegroundColor Gray
  return $result
}

function Invoke-RaymanInteractionModeCommand {
  param(
    [string]$WorkspaceRoot = $script:RaymanCliWorkspaceRoot,
    [string[]]$InputArgs = @()
  )

  $showRequested = Test-RaymanCliFlagPresent -InputArgs $InputArgs -Names @('show')
  $setValue = [string](Get-RaymanCliOptionValue -InputArgs $InputArgs -Names @('set') -Default '')
  if ([string]::IsNullOrWhiteSpace([string]$setValue)) {
    foreach ($token in @($InputArgs)) {
      $candidate = [string]$token
      if ([string]::IsNullOrWhiteSpace([string]$candidate) -or $candidate.StartsWith('-')) { continue }
      $normalized = Normalize-RaymanInteractionMode -Mode $candidate -Default ''
      if (-not [string]::IsNullOrWhiteSpace([string]$normalized)) {
        $setValue = $normalized
        break
      }
    }
  }

  if (-not [string]::IsNullOrWhiteSpace([string]$setValue)) {
    Set-RaymanInteractionModePreference -WorkspaceRoot $WorkspaceRoot -Mode $setValue | Out-Null
    return
  }

  if ($showRequested -or -not (Test-RaymanInteractiveConsoleAvailable)) {
    Write-RaymanInteractionModeStatus -WorkspaceRoot $WorkspaceRoot
    return
  }

  $selection = Read-RaymanInteractionModeSelection -WorkspaceRoot $WorkspaceRoot
  if ([string]::IsNullOrWhiteSpace([string]$selection)) {
    Write-Host '[interaction-mode] cancelled.' -ForegroundColor Yellow
    return
  }

  Set-RaymanInteractionModePreference -WorkspaceRoot $WorkspaceRoot -Mode $selection | Out-Null
}

if ((-not $commandProvided) -and $cmd -ne 'menu') {
  Show-Help
  Write-Host ''
  Write-Host '提示：如需交互式菜单，请显式运行：.\.Rayman\rayman.cmd menu' -ForegroundColor Cyan
  exit 0
}

if ($cmd -eq 'menu') {
  $picked = Resolve-RaymanInteractiveMenuSelection -Selection (Show-RaymanInteractiveMenu -WorkspaceRoot $script:RaymanCliWorkspaceRoot)
  if ($null -eq $picked) { exit 0 }
  $script:RaymanCliInvokedFromMenu = $true
  $cmd = ([string]$picked.Command).ToLowerInvariant()
  $CliArgs = [string[]]@($picked['CliArgs'])
}

if (Test-RaymanShouldEnterCodexMenu -CommandName $cmd -InputArgs $CliArgs) {
  $CliArgs = @('menu')
}

function Stop-RaymanWatcherByPidFile([string]$PidFile, [string]$Name) {
  if (-not (Test-Path -LiteralPath $PidFile -PathType Leaf)) {
    Write-Host ("[{0}] pid file not found." -f $Name)
    return
  }

  $raw = ''
  try { $raw = (Get-Content -LiteralPath $PidFile -Raw -ErrorAction Stop).Trim() } catch {}
  $pidVal = 0
  if ([int]::TryParse($raw, [ref]$pidVal) -and $pidVal -gt 0) {
    $p = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
    if ($p) {
      try { Stop-Process -Id $pidVal -Force -ErrorAction Stop } catch {}
    }
  }

  try { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue } catch {}
  if (Test-Path -LiteralPath $PidFile -PathType Leaf) {
    Write-Host ("[{0}] stop requested, but pid file still exists (可能权限受限)." -f $Name)
  } else {
    Write-Host ("[{0}] stopped" -f $Name)
  }
}

function ConvertTo-RaymanForwardArgs([string[]]$InputArgs, [string[]]$KnownParamNames) {
  if (-not $InputArgs) { return @() }
  $known = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($n in $KnownParamNames) {
    if (-not [string]::IsNullOrWhiteSpace($n)) { [void]$known.Add($n) }
  }

  $out = New-Object System.Collections.Generic.List[string]
  foreach ($arg in $InputArgs) {
    if ([string]::IsNullOrWhiteSpace($arg)) {
      [void]$out.Add($arg)
      continue
    }

    if ($arg.StartsWith('-')) {
      [void]$out.Add($arg)
      continue
    }

    if ($known.Contains($arg)) {
      [void]$out.Add(('-' + $arg))
      continue
    }

    [void]$out.Add($arg)
  }
  return @($out)
}

function Get-RaymanCliTokenName([string]$Token) {
  if ([string]::IsNullOrWhiteSpace($Token)) { return '' }
  return $Token.Trim().TrimStart('-')
}

function Test-RaymanCliTokenMatches([string]$Token, [string[]]$Names) {
  $candidate = Get-RaymanCliTokenName -Token $Token
  if ([string]::IsNullOrWhiteSpace($candidate)) { return $false }
  foreach ($name in $Names) {
    if ($candidate.Equals([string]$name, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $true
    }
  }
  return $false
}

function Test-RaymanCliFlagPresent([string[]]$InputArgs, [string[]]$Names) {
  foreach ($arg in @($InputArgs)) {
    if (Test-RaymanCliTokenMatches -Token ([string]$arg) -Names $Names) {
      return $true
    }
  }
  return $false
}

function Get-RaymanCliOptionValue {
  param(
    [string[]]$InputArgs,
    [string[]]$Names,
    [object]$Default = $null,
    [switch]$ThrowOnMissingValue
  )

  $argsArray = @($InputArgs)
  for ($i = 0; $i -lt $argsArray.Count; $i++) {
    if (-not (Test-RaymanCliTokenMatches -Token ([string]$argsArray[$i]) -Names $Names)) { continue }
    if ($i + 1 -lt $argsArray.Count) {
      return $argsArray[$i + 1]
    }
    if ($ThrowOnMissingValue) {
      throw ('missing value for --{0}' -f $Names[0])
    }
    return $Default
  }
  return $Default
}

function ConvertTo-RaymanBoolValue([object]$Value, [bool]$Default) {
  if ($null -eq $Value) { return $Default }
  $text = ([string]$Value).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return $Default }
  switch ($text.ToLowerInvariant()) {
    '1' { return $true }
    'true' { return $true }
    'yes' { return $true }
    'on' { return $true }
    '0' { return $false }
    'false' { return $false }
    'no' { return $false }
    'off' { return $false }
    default { return $Default }
  }
}

function Get-RaymanCliBoolOptionValue([string[]]$InputArgs, [string[]]$Names, [bool]$Default) {
  $value = Get-RaymanCliOptionValue -InputArgs $InputArgs -Names $Names -Default $null
  return (ConvertTo-RaymanBoolValue -Value $value -Default $Default)
}

function Resolve-RaymanCommandExitCode([int]$Default = 0) {
  if (Test-Path variable:LASTEXITCODE) {
    return [int]$LASTEXITCODE
  }
  return $(if ($?) { $Default } else { 1 })
}

function Test-RaymanCliDoneAlertSuppressed {
  param(
    [string]$CommandName,
    [string[]]$InputArgs = @()
  )

  if ([string]::IsNullOrWhiteSpace($CommandName)) { return $true }

  switch ($CommandName.Trim().ToLowerInvariant()) {
    'help' { return $true }
    'menu' { return $true }
    'copy-self-check' { return $true }
    'codex' { return $true }
  }

  if (Convert-RaymanStringToBool -Value ([Environment]::GetEnvironmentVariable('CI')) -Default $false) {
    return $true
  }

  try {
    if ([Console]::IsOutputRedirected -or [Console]::IsErrorRedirected) {
      return $true
    }
  } catch {}

  foreach ($arg in @($InputArgs)) {
    $token = Get-RaymanCliTokenName -Token ([string]$arg)
    if ([string]::IsNullOrWhiteSpace($token)) { continue }
    switch ($token.ToLowerInvariant()) {
      'json' { return $true }
      'as-json' { return $true }
      'asjson' { return $true }
    }
  }

  return $false
}

function Invoke-RaymanCliDoneAlert {
  param(
    [string]$CommandName,
    [string[]]$InputArgs = @()
  )

  if (Test-RaymanCliDoneAlertSuppressed -CommandName $CommandName -InputArgs $InputArgs) {
    return
  }

  try {
    $reason = 'Rayman 命令已完成。'
    if (-not [string]::IsNullOrWhiteSpace($CommandName)) {
      $reason = ("Rayman 命令已完成：{0}" -f $CommandName)
    }
    Invoke-RaymanAttentionAlert -Kind 'done' -Reason $reason -WorkspaceRoot $script:RaymanCliWorkspaceRoot | Out-Null
  } catch {}
}

function Test-RaymanCliPostCommandQuietMode {
  param(
    [string]$CommandName,
    [string[]]$InputArgs = @()
  )

  if (Convert-RaymanStringToBool -Value ([Environment]::GetEnvironmentVariable('CI')) -Default $false) {
    return $true
  }

  try {
    if ([Console]::IsOutputRedirected -or [Console]::IsErrorRedirected) {
      return $true
    }
  } catch {}

  foreach ($arg in @($InputArgs)) {
    $token = Get-RaymanCliTokenName -Token ([string]$arg)
    if ([string]::IsNullOrWhiteSpace($token)) { continue }
    switch ($token.ToLowerInvariant()) {
      'json' { return $true }
      'as-json' { return $true }
      'asjson' { return $true }
    }
  }

  return $false
}

function Invoke-RaymanCliPostCommandHygiene {
  param(
    [int]$ExitCode,
    [string]$CommandName,
    [string[]]$InputArgs = @()
  )

  if (-not (Get-Command Invoke-RaymanPostCommandHygiene -ErrorAction SilentlyContinue)) {
    return
  }
  if ([string]::IsNullOrWhiteSpace([string]$CommandName)) {
    return
  }
  switch ($CommandName.Trim().ToLowerInvariant()) {
    'help' { return }
    'menu' { return }
  }

  $quietMode = Test-RaymanCliPostCommandQuietMode -CommandName $CommandName -InputArgs $InputArgs
  try {
    Invoke-RaymanPostCommandHygiene -WorkspaceRoot $script:RaymanCliWorkspaceRoot -CommandName $CommandName -InputArgs $InputArgs -ExitCode $ExitCode -Quiet:$quietMode | Out-Null
  } catch {}
}

function Exit-RaymanCli {
  param(
    [int]$ExitCode,
    [string]$CommandName,
    [string[]]$InputArgs = @()
  )

  Invoke-RaymanCliPostCommandHygiene -ExitCode $ExitCode -CommandName $CommandName -InputArgs $InputArgs

  if ($ExitCode -eq 0) {
    Invoke-RaymanCliDoneAlert -CommandName $CommandName -InputArgs $InputArgs
  }

  exit $ExitCode
}

function Invoke-RaymanDoctorCopySmoke {
  param(
    [string[]]$InputArgs = @(),
    [string]$CommandName = 'doctor'
  )

  $doctorArgs = @($InputArgs)
  $copySmokeStrict = Test-RaymanCliFlagPresent -InputArgs $doctorArgs -Names @('strict')
  $copySmokeKeepTemp = Test-RaymanCliFlagPresent -InputArgs $doctorArgs -Names @('keep-temp')
  $copySmokeTimeoutSeconds = [int](Get-RaymanCliOptionValue -InputArgs $doctorArgs -Names @('timeout-seconds') -Default 120 -ThrowOnMissingValue:$false)
  $copySmokeScope = [string](Get-RaymanCliOptionValue -InputArgs $doctorArgs -Names @('scope') -Default 'wsl' -ThrowOnMissingValue:$false)
  $doctorRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
  $smokeParams = @{
    WorkspaceRoot = $doctorRoot
    TimeoutSeconds = $copySmokeTimeoutSeconds
    Scope = $copySmokeScope
  }
  if ($copySmokeStrict) { $smokeParams['Strict'] = $true }
  if ($copySmokeKeepTemp) { $smokeParams['KeepTemp'] = $true }

  if (Test-Path variable:LASTEXITCODE) {
    $global:LASTEXITCODE = 0
  }
  & "$PSScriptRoot\scripts\release\copy_smoke.ps1" @smokeParams
  $copySmokeExitCode = if (Test-Path variable:LASTEXITCODE) {
    [int]$LASTEXITCODE
  } elseif ($?) {
    0
  } else {
    1
  }
  Exit-RaymanCli -ExitCode $copySmokeExitCode -CommandName $CommandName -InputArgs $InputArgs
}

function Get-RaymanLatestCopySmokeDebugBundlePath {
  $tempDir = [System.IO.Path]::GetTempPath()
  try {
    $latest = Get-ChildItem -LiteralPath $tempDir -Directory -Filter 'rayman_copy_smoke_*' -ErrorAction Stop |
      Where-Object { $_.LastWriteTime -ge (Get-Date).AddHours(-12) } |
      Sort-Object LastWriteTime -Descending |
      ForEach-Object {
        $bundlePath = Join-Path $_.FullName '.Rayman\runtime\copy_smoke_debug_bundle.txt'
        if (Test-Path -LiteralPath $bundlePath -PathType Leaf) {
          [PSCustomObject]@{
            BundlePath = $bundlePath
            TempRoot = $_.FullName
            LastWriteTime = $_.LastWriteTime
          }
        }
      } |
      Select-Object -First 1
    return $latest
  } catch {
    return $null
  }
}

function Get-RaymanCopySmokeDebugBundleValues([string]$BundlePath) {
  if ([string]::IsNullOrWhiteSpace($BundlePath) -or -not (Test-Path -LiteralPath $BundlePath -PathType Leaf)) { return $null }
  try {
    $lines = Get-Content -LiteralPath $BundlePath -Encoding UTF8 -ErrorAction Stop
    $map = [ordered]@{}
    foreach ($line in $lines) {
      if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
      if ([string]$line -notmatch '^[A-Za-z0-9_]+=(.*)$') { continue }
      $parts = [string]$line -split '=', 2
      if ($parts.Count -ne 2) { continue }
      $map[$parts[0]] = $parts[1]
    }
    return [PSCustomObject]$map
  } catch {
    return $null
  }
}

function Format-RaymanStopProcessCommand([string]$PidListText) {
  if ([string]::IsNullOrWhiteSpace($PidListText)) { return $null }
  $pidValues = New-Object System.Collections.Generic.List[string]
  foreach ($token in ([string]$PidListText -split '[^0-9]+')) {
    if ([string]::IsNullOrWhiteSpace($token)) { continue }
    $parsed = 0
    if ([int]::TryParse($token, [ref]$parsed) -and $parsed -gt 0) {
      [void]$pidValues.Add([string]$parsed)
    }
  }
  if ($pidValues.Count -eq 0) { return $null }
  return ('Stop-Process -Id {0} -Force' -f ($pidValues -join ','))
}

function Show-RaymanDoctorCopySmokeHint {
  $latest = Get-RaymanLatestCopySmokeDebugBundlePath
  if ($null -eq $latest -or [string]::IsNullOrWhiteSpace([string]$latest.BundlePath)) { return }
  $bundle = Get-RaymanCopySmokeDebugBundleValues -BundlePath ([string]$latest.BundlePath)
  if ($null -eq $bundle) { return }

  Write-Host '附加提示：检测到最近一次 copy smoke 的 Sandbox 摘要：' -ForegroundColor Yellow
  if ($bundle.PSObject.Properties['sandbox_owner'] -and -not [string]::IsNullOrWhiteSpace([string]$bundle.sandbox_owner)) {
    Write-Host ("  owner: {0}" -f [string]$bundle.sandbox_owner) -ForegroundColor Yellow
  }
  if ($bundle.PSObject.Properties['sandbox_owned_pids'] -and -not [string]::IsNullOrWhiteSpace([string]$bundle.sandbox_owned_pids)) {
    Write-Host ("  owned pids: {0}" -f [string]$bundle.sandbox_owned_pids) -ForegroundColor Yellow
  }
  if ($bundle.PSObject.Properties['sandbox_foreign_pids'] -and -not [string]::IsNullOrWhiteSpace([string]$bundle.sandbox_foreign_pids) -and [string]$bundle.sandbox_foreign_pids -ne '(none)') {
    Write-Host ("  foreign pids: {0}（不要动）" -f [string]$bundle.sandbox_foreign_pids) -ForegroundColor Yellow
  }
  if ($bundle.PSObject.Properties['sandbox_unknown_pids'] -and -not [string]::IsNullOrWhiteSpace([string]$bundle.sandbox_unknown_pids) -and [string]$bundle.sandbox_unknown_pids -ne '(none)') {
    Write-Host ("  unknown pids: {0}（暂不建议处理）" -f [string]$bundle.sandbox_unknown_pids) -ForegroundColor Yellow
  }
  if ($bundle.PSObject.Properties['sandbox_suggest_close_pids'] -and -not [string]::IsNullOrWhiteSpace([string]$bundle.sandbox_suggest_close_pids) -and [string]$bundle.sandbox_suggest_close_pids -ne '(none)') {
    Write-Host ("  建议仅关闭：{0}" -f [string]$bundle.sandbox_suggest_close_pids) -ForegroundColor Yellow
    $stopCommand = $null
    if ($bundle.PSObject.Properties['sandbox_suggest_close_command'] -and -not [string]::IsNullOrWhiteSpace([string]$bundle.sandbox_suggest_close_command)) {
      $stopCommand = [string]$bundle.sandbox_suggest_close_command
    }
    if ([string]::IsNullOrWhiteSpace($stopCommand)) {
      $stopCommand = Format-RaymanStopProcessCommand -PidListText ([string]$bundle.sandbox_suggest_close_pids)
    }
    if (-not [string]::IsNullOrWhiteSpace($stopCommand)) {
      Write-Host ("  可复制命令：{0}" -f $stopCommand) -ForegroundColor DarkYellow
    }
  }
  if ($bundle.PSObject.Properties['temp_workspace'] -and -not [string]::IsNullOrWhiteSpace([string]$bundle.temp_workspace)) {
    Write-Host ("  temp workspace: {0}" -f [string]$bundle.temp_workspace) -ForegroundColor DarkYellow
  }
  Write-Host ("  debug bundle: {0}" -f [string]$latest.BundlePath) -ForegroundColor DarkYellow
}

switch ($cmd) {
  "help" { Show-Help; break }
  "init" { & "$PSScriptRoot\init.cmd"; break }
  "watch" { & "$PSScriptRoot\win-watch.ps1"; break }
  "watch-auto" {
    & "$PSScriptRoot\scripts\watch\start_background_watchers.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    break
  }
  "watch-stop" {
    $rootPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $stopParams = @{
      WorkspaceRoot = $rootPath
      IncludeResidualCleanup = $true
    }
    $ownerPid = [string][Environment]::GetEnvironmentVariable('VSCODE_PID')
    if (-not [string]::IsNullOrWhiteSpace($ownerPid)) {
      $stopParams['OwnerPid'] = $ownerPid
    }
    & "$PSScriptRoot\scripts\watch\stop_background_watchers.ps1" @stopParams
    break
  }
  "fast-init" {
    # Prefer WSL fast-init if repo is on a Windows drive (most common)
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($null -ne $wsl) {
      $repo = (Resolve-Path (Join-Path $PSScriptRoot ".."))
      & wsl.exe -e bash -lc "cd \"$repo\" && bash ./.Rayman/scripts/fast-init/fast-init.sh --only-new" | Out-Host
    } else {
      Write-Host "[fast-init] wsl.exe not found; run fast-init inside WSL." -ForegroundColor Yellow
    }
    break
  }

  "migrate" {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($null -ne $wsl) {
      $repo = (Resolve-Path (Join-Path $PSScriptRoot ".."))
      & wsl.exe -e bash -lc "cd \"$repo\" && bash ./.Rayman/scripts/requirements/migrate_legacy_requirements.sh" | Out-Host
    } else {
      & "$PSScriptRoot\scripts\requirements\migrate_legacy_requirements.ps1"
    }
    break
  }

  "memory-bootstrap" {
    & "$PSScriptRoot\scripts\memory\memory_bootstrap.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path -Action ensure -Prewarm @CliArgs
    break
  }
  "memory-summarize" {
    & "$PSScriptRoot\scripts\memory\manage_memory.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path -Action summarize -DrainPending @CliArgs
    break
  }
  "memory-search" {
    & "$PSScriptRoot\scripts\memory\manage_memory.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path -Action search @CliArgs
    break
  }

  "doctor" {
    $doctorArgs = @($CliArgs)
    $copySmoke = Test-RaymanCliFlagPresent -InputArgs $doctorArgs -Names @('copy-smoke')

    if ($copySmoke) {
      Invoke-RaymanDoctorCopySmoke -InputArgs $doctorArgs -CommandName $cmd
    }

    $doctorRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $agentContractScript = Join-Path $doctorRoot '.Rayman\scripts\agents\check_agent_contract.ps1'
    if (Test-Path -LiteralPath $agentContractScript -PathType Leaf) {
      if (Test-Path variable:LASTEXITCODE) {
        $global:LASTEXITCODE = 0
      }
      & $agentContractScript -WorkspaceRoot $doctorRoot
      $doctorAgentExitCode = 0
      if (Test-Path variable:LASTEXITCODE) {
        $doctorAgentExitCode = [int]$LASTEXITCODE
      } elseif (-not $?) {
        $doctorAgentExitCode = 1
      }
      if ($doctorAgentExitCode -ne 0) {
        Write-Host '提示：agent-contract 已失败；无需手动输入内容。请直接查看上面的 FAIL 项，或重跑：.\.Rayman\rayman.ps1 agent-contract' -ForegroundColor Yellow
        Exit-RaymanCli -ExitCode $doctorAgentExitCode -CommandName $cmd -InputArgs $CliArgs
      }
    }

    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($null -ne $wsl) {
      $repoWin = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
      if ($repoWin -match '^[A-Za-z]:\\') {
        $drive = $repoWin.Substring(0,1).ToLowerInvariant()
        $rest = $repoWin.Substring(2).Replace('\', '/')
        $repoWsl = "/mnt/$drive$rest"
      } else {
        $repoWsl = $repoWin.Replace('\', '/')
      }
      & wsl.exe -e bash -lc "cd '$repoWsl' && bash ./.Rayman/run/rules.sh doctor" | Out-Host
      if (Test-Path variable:LASTEXITCODE) {
        $doctorExitCode = [int]$LASTEXITCODE
        if ($doctorExitCode -ne 0) {
          Write-Host '提示：doctor 失败通常不是让你“输入内容”，而是下游严格校验未通过。' -ForegroundColor Yellow
          Show-RaymanDoctorCopySmokeHint
          Write-Host '下一步建议 1：先单独运行 .\.Rayman\rayman.ps1 release-gate -Mode project，确认主链路是否正常。' -ForegroundColor Yellow
          Write-Host '下一步建议 2：若是当前主机的 Windows Sandbox 权限问题，可显式设置 RAYMAN_ALLOW_COPY_SMOKE_SANDBOX_FAIL=1 和 RAYMAN_BYPASS_REASON 后再运行 doctor。' -ForegroundColor Yellow
        }
      }
    } else {
      & "$PSScriptRoot\win-check.ps1"; 
    }
    break
  }
  "copy-self-check" {
    Invoke-RaymanDoctorCopySmoke -InputArgs $CliArgs -CommandName $cmd
  }
  "check" { & "$PSScriptRoot\win-check.ps1"; break }
  "fast-gate" {
    $workspaceArg = [string](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('WorkspaceRoot', 'workspace-root') -Default ((Resolve-Path (Join-Path $PSScriptRoot "..")).Path))
    & "$PSScriptRoot\scripts\project\run_project_gate.ps1" -WorkspaceRoot $workspaceArg -Lane fast
    break
  }
  "browser-gate" {
    $workspaceArg = [string](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('WorkspaceRoot', 'workspace-root') -Default ((Resolve-Path (Join-Path $PSScriptRoot "..")).Path))
    & "$PSScriptRoot\scripts\project\run_project_gate.ps1" -WorkspaceRoot $workspaceArg -Lane browser
    break
  }
  "full-gate" {
    $workspaceArg = [string](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('WorkspaceRoot', 'workspace-root') -Default ((Resolve-Path (Join-Path $PSScriptRoot "..")).Path))
    & "$PSScriptRoot\scripts\project\run_project_gate.ps1" -WorkspaceRoot $workspaceArg -Lane full
    break
  }
  "ensure-test-deps" {
    $workspaceArg = [string](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('WorkspaceRoot', 'workspace-root') -Default ((Resolve-Path (Join-Path $PSScriptRoot "..")).Path))
    $autoInstall = Get-RaymanCliBoolOptionValue -InputArgs $CliArgs -Names @('AutoInstall', 'auto-install') -Default $true
    $require = Get-RaymanCliBoolOptionValue -InputArgs $CliArgs -Names @('Require', 'require') -Default $true
    & "$PSScriptRoot\scripts\utils\ensure_project_test_deps.ps1" -WorkspaceRoot $workspaceArg -AutoInstall:$autoInstall -Require:$require
    break
  }
  "ensure-playwright" {
    $workspaceArg = [string](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('WorkspaceRoot', 'workspace-root') -Default ((Resolve-Path (Join-Path $PSScriptRoot "..")).Path))
    $scopeArg = [string][Environment]::GetEnvironmentVariable('RAYMAN_PLAYWRIGHT_SETUP_SCOPE')
    if ([string]::IsNullOrWhiteSpace($scopeArg)) { $scopeArg = 'wsl' }
    $browserArg = [string][Environment]::GetEnvironmentVariable('RAYMAN_PLAYWRIGHT_BROWSER')
    if ([string]::IsNullOrWhiteSpace($browserArg)) { $browserArg = 'chromium' }
    $require = $true
    $timeoutArg = 1800
    $timeoutEnv = [string][Environment]::GetEnvironmentVariable('RAYMAN_PLAYWRIGHT_TIMEOUT_SECONDS')
    $timeoutEnvParsed = 0
    if (-not [string]::IsNullOrWhiteSpace($timeoutEnv) -and [int]::TryParse($timeoutEnv, [ref]$timeoutEnvParsed)) { $timeoutArg = $timeoutEnvParsed }
    $requireEnv = [string][Environment]::GetEnvironmentVariable('RAYMAN_PLAYWRIGHT_REQUIRE')
    if (-not [string]::IsNullOrWhiteSpace($requireEnv)) {
      $require = ($requireEnv -ne '0' -and $requireEnv -ne 'false' -and $requireEnv -ne 'False')
    }

    $scopeArg = [string](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('Scope', 'scope') -Default $scopeArg)
    $browserArg = [string](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('Browser', 'browser') -Default $browserArg)
    $require = Get-RaymanCliBoolOptionValue -InputArgs $CliArgs -Names @('Require', 'require') -Default $require
    $timeoutArg = [int](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('TimeoutSeconds', 'timeout-seconds') -Default $timeoutArg)

    if (Test-RaymanWindowsPlatform) {
      & "$PSScriptRoot\scripts\pwa\ensure_playwright_ready.ps1" -WorkspaceRoot $workspaceArg -Scope $scopeArg -Browser $browserArg -Require:$require -TimeoutSeconds $timeoutArg
    } else {
      Push-Location $workspaceArg
      try {
        & bash ./.Rayman/scripts/pwa/ensure_playwright_wsl.sh --browser $browserArg --require $(if ($require) { '1' } else { '0' })
      } finally {
        Pop-Location
      }
    }
    break
  }
  "ensure-winapp" {
    $workspaceArg = [string](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('WorkspaceRoot', 'workspace-root') -Default ((Resolve-Path (Join-Path $PSScriptRoot "..")).Path))
    $requireArg = Get-RaymanCliBoolOptionValue -InputArgs $CliArgs -Names @('Require', 'require') -Default $false

    & "$PSScriptRoot\scripts\windows\ensure_winapp.ps1" -WorkspaceRoot $workspaceArg -Require:$requireArg
    break
  }
  "pwa-test" {
    $workspaceArg = [string](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('WorkspaceRoot', 'workspace-root') -Default ((Resolve-Path (Join-Path $PSScriptRoot "..")).Path))
    $flowArg = [string](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('FlowFile', 'flow-file') -Default '.Rayman/pwa.flow.sample.json')
    $browserArg = [string](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('Browser', 'browser') -Default 'chromium')
    $headlessArg = Get-RaymanCliBoolOptionValue -InputArgs $CliArgs -Names @('Headless', 'headless') -Default $true
    $timeoutArg = [int](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('TimeoutMs', 'timeout-ms') -Default 30000)
    $requireArg = Get-RaymanCliBoolOptionValue -InputArgs $CliArgs -Names @('Require', 'require') -Default $true
    $preferSandboxArg = Get-RaymanCliBoolOptionValue -InputArgs $CliArgs -Names @('PreferSandbox', 'prefer-sandbox') -Default $true

    & "$PSScriptRoot\scripts\pwa\run_pwa_flow.ps1" -WorkspaceRoot $workspaceArg -FlowFile $flowArg -Browser $browserArg -Headless:$headlessArg -TimeoutMs $timeoutArg -Require:$requireArg -PreferSandbox:$preferSandboxArg
    break
  }
  "winapp-test" {
    $workspaceArg = [string](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('WorkspaceRoot', 'workspace-root') -Default ((Resolve-Path (Join-Path $PSScriptRoot "..")).Path))
    $flowArg = [string](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('FlowFile', 'flow-file') -Default '.Rayman/winapp.flow.sample.json')
    $winAppRequireDefault = $true
    $winAppRequireEnv = [string][Environment]::GetEnvironmentVariable('RAYMAN_WINAPP_REQUIRE')
    if (-not [string]::IsNullOrWhiteSpace($winAppRequireEnv)) {
      $winAppRequireDefault = ($winAppRequireEnv -ne '0' -and $winAppRequireEnv -ne 'false' -and $winAppRequireEnv -ne 'False')
    }
    $timeoutDefault = 15000
    $timeoutEnv = [string][Environment]::GetEnvironmentVariable('RAYMAN_WINAPP_DEFAULT_TIMEOUT_MS')
    $timeoutEnvParsed = 0
    if (-not [string]::IsNullOrWhiteSpace($timeoutEnv) -and [int]::TryParse($timeoutEnv, [ref]$timeoutEnvParsed)) {
      $timeoutDefault = $timeoutEnvParsed
    }
    $requireArg = Get-RaymanCliBoolOptionValue -InputArgs $CliArgs -Names @('Require', 'require') -Default $winAppRequireDefault
    $timeoutArg = [int](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('DefaultTimeoutMs', 'default-timeout-ms') -Default $timeoutDefault)

    & "$PSScriptRoot\scripts\windows\run_winapp_flow.ps1" -WorkspaceRoot $workspaceArg -FlowFile $flowArg -Require:$requireArg -DefaultTimeoutMs $timeoutArg
    break
  }
  "winapp-inspect" {
    $workspaceArg = [string](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('WorkspaceRoot', 'workspace-root') -Default ((Resolve-Path (Join-Path $PSScriptRoot "..")).Path))
    $titleRegexArg = [string](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('WindowTitleRegex', 'window-title-regex', 'TitleRegex', 'title-regex') -Default '.*')
    $outFileArg = [string](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('OutFile', 'out-file') -Default '.Rayman/runtime/winapp-tests/control_tree.json')
    $timeoutArg = [int](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('TimeoutSeconds', 'timeout-seconds') -Default 20)

    & "$PSScriptRoot\scripts\windows\inspect_winapp.ps1" -WorkspaceRoot $workspaceArg -WindowTitleRegex $titleRegexArg -OutFile $outFileArg -TimeoutSeconds $timeoutArg
    break
  }
  "linux-test" {
    $workspaceArg = [string](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('WorkspaceRoot', 'workspace-root') -Default ((Resolve-Path (Join-Path $PSScriptRoot "..")).Path))
    $commandArg = [string](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('TestCommand', 'test-command', 'Cmd', 'cmd') -Default '')
    $autoInstallArg = Get-RaymanCliBoolOptionValue -InputArgs $CliArgs -Names @('AutoInstall', 'auto-install') -Default $true
    $requireArg = Get-RaymanCliBoolOptionValue -InputArgs $CliArgs -Names @('Require', 'require') -Default $true

    & "$PSScriptRoot\scripts\linux\run_wsl_auto_test.ps1" -WorkspaceRoot $workspaceArg -Command $commandArg -AutoInstall:$autoInstallArg -Require:$requireArg
    break
  }
  "clean" {
    $workspaceArg = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $keepDaysArg = $null
    $dryRunArg = $null
    $aggressiveArg = $null
    $copySmokeArtifactsArg = $null

    for ($i = 0; $i -lt $CliArgs.Count; $i++) {
      $token = [string]$CliArgs[$i]
      switch -Regex ($token) {
        '^--?(WorkspaceRoot|workspace-root)$' { if ($i + 1 -lt $CliArgs.Count) { $workspaceArg = [string]$CliArgs[++$i] }; continue }
        '^--?(KeepDays|keep-days)$' { if ($i + 1 -lt $CliArgs.Count) { $keepDaysArg = [string]$CliArgs[++$i] }; continue }
        '^--?(DryRun|dry-run)$' { if ($i + 1 -lt $CliArgs.Count) { $dryRunArg = [string]$CliArgs[++$i] }; continue }
        '^--?(Aggressive|aggressive)$' { if ($i + 1 -lt $CliArgs.Count) { $aggressiveArg = [string]$CliArgs[++$i] }; continue }
        '^--?(CopySmokeArtifacts|copy-smoke-artifacts)$' { if ($i + 1 -lt $CliArgs.Count) { $copySmokeArtifactsArg = [string]$CliArgs[++$i] }; continue }
      }
    }

    $params = @{ WorkspaceRoot = $workspaceArg }
    if (-not [string]::IsNullOrWhiteSpace($keepDaysArg)) { $params['KeepDays'] = [int]$keepDaysArg }
    if (-not [string]::IsNullOrWhiteSpace($dryRunArg)) { $params['DryRun'] = [int]$dryRunArg }
    if (-not [string]::IsNullOrWhiteSpace($aggressiveArg)) { $params['Aggressive'] = [int]$aggressiveArg }
    if (-not [string]::IsNullOrWhiteSpace($copySmokeArtifactsArg)) { $params['CopySmokeArtifacts'] = [int]$copySmokeArtifactsArg }

    & "$PSScriptRoot\scripts\utils\clean_workspace.ps1" @params
    break
  }
  "snapshot" {
    $workspaceArg = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $reasonArg = $null
    $keepArg = $null

    for ($i = 0; $i -lt $CliArgs.Count; $i++) {
      $token = [string]$CliArgs[$i]
      switch -Regex ($token) {
        '^--?(WorkspaceRoot|workspace-root)$' { if ($i + 1 -lt $CliArgs.Count) { $workspaceArg = [string]$CliArgs[++$i] }; continue }
        '^--?(Reason|reason)$' { if ($i + 1 -lt $CliArgs.Count) { $reasonArg = [string]$CliArgs[++$i] }; continue }
        '^--?(Keep|keep)$' { if ($i + 1 -lt $CliArgs.Count) { $keepArg = [string]$CliArgs[++$i] }; continue }
        default {
          if ([string]::IsNullOrWhiteSpace($reasonArg)) { $reasonArg = $token; continue }
          if ([string]::IsNullOrWhiteSpace($keepArg)) { $keepArg = $token; continue }
        }
      }
    }

    $params = @{ WorkspaceRoot = $workspaceArg }
    if (-not [string]::IsNullOrWhiteSpace($reasonArg)) { $params['Reason'] = $reasonArg }
    if (-not [string]::IsNullOrWhiteSpace($keepArg)) { $params['Keep'] = [int]$keepArg }

    & "$PSScriptRoot\scripts\backup\snapshot_workspace.ps1" @params
    break
  }
  "metrics" {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    $metricsArgLine = ""
    if ($CliArgs) { $metricsArgLine = ($CliArgs -join " ") }
    if ($null -ne $wsl) {
      $repoWin = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
      if ($repoWin -match '^[A-Za-z]:\\') {
        $drive = $repoWin.Substring(0,1).ToLowerInvariant()
        $rest = $repoWin.Substring(2).Replace('\', '/')
        $repoWsl = "/mnt/$drive$rest"
      } else {
        $repoWsl = $repoWin.Replace('\', '/')
      }
      $wslCmd = "cd '$repoWsl' && bash ./.Rayman/scripts/telemetry/rules_metrics.sh"
      if ($metricsArgLine) { $wslCmd += " $metricsArgLine" }
      & wsl.exe -e bash -lc $wslCmd | Out-Host
    } else {
      $bash = Get-Command bash -ErrorAction SilentlyContinue
      if ($null -ne $bash) {
        & bash ".\.Rayman\scripts\telemetry\rules_metrics.sh" @CliArgs | Out-Host
      } else {
        Write-Host "[metrics] neither wsl.exe nor bash found."
      }
    }
    break
  }
  "trend" {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    $trendArgLine = ""
    if ($CliArgs) { $trendArgLine = ($CliArgs -join " ") }
    if ($null -ne $wsl) {
      $repoWin = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
      if ($repoWin -match '^[A-Za-z]:\\') {
        $drive = $repoWin.Substring(0,1).ToLowerInvariant()
        $rest = $repoWin.Substring(2).Replace('\', '/')
        $repoWsl = "/mnt/$drive$rest"
      } else {
        $repoWsl = $repoWin.Replace('\', '/')
      }
      $wslCmd = "cd '$repoWsl' && bash ./.Rayman/scripts/telemetry/daily_trend.sh"
      if ($trendArgLine) { $wslCmd += " $trendArgLine" }
      & wsl.exe -e bash -lc $wslCmd | Out-Host
    } else {
      $bash = Get-Command bash -ErrorAction SilentlyContinue
      if ($null -ne $bash) {
        & bash ".\.Rayman\scripts\telemetry\daily_trend.sh" @CliArgs | Out-Host
      } else {
        Write-Host "[trend] neither wsl.exe nor bash found."
      }
    }
    break
  }
  "baseline-guard" {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    $argLine = ""
    if ($CliArgs) { $argLine = ($CliArgs -join " ") }
    if ($null -ne $wsl) {
      $repoWin = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
      if ($repoWin -match '^[A-Za-z]:\\') {
        $drive = $repoWin.Substring(0,1).ToLowerInvariant()
        $rest = $repoWin.Substring(2).Replace('\', '/')
        $repoWsl = "/mnt/$drive$rest"
      } else {
        $repoWsl = $repoWin.Replace('\', '/')
      }
      $wslCmd = "cd '$repoWsl' && bash ./.Rayman/scripts/telemetry/baseline_guard.sh"
      if ($argLine) { $wslCmd += " $argLine" }
      & wsl.exe -e bash -lc $wslCmd | Out-Host
    } else {
      $bash = Get-Command bash -ErrorAction SilentlyContinue
      if ($null -ne $bash) {
        & bash ".\.Rayman\scripts\telemetry\baseline_guard.sh" @CliArgs | Out-Host
      } else {
        Write-Host "[baseline-guard] neither wsl.exe nor bash found."
      }
    }
    break
  }
  "telemetry-export" {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    $argLine = ""
    if ($CliArgs) { $argLine = ($CliArgs -join " ") }
    if ($null -ne $wsl) {
      $repoWin = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
      if ($repoWin -match '^[A-Za-z]:\\') {
        $drive = $repoWin.Substring(0,1).ToLowerInvariant()
        $rest = $repoWin.Substring(2).Replace('\', '/')
        $repoWsl = "/mnt/$drive$rest"
      } else {
        $repoWsl = $repoWin.Replace('\', '/')
      }
      $wslCmd = "cd '$repoWsl' && bash ./.Rayman/scripts/telemetry/export_artifacts.sh"
      if ($argLine) { $wslCmd += " $argLine" }
      & wsl.exe -e bash -lc $wslCmd | Out-Host
    } else {
      $bash = Get-Command bash -ErrorAction SilentlyContinue
      if ($null -ne $bash) {
        & bash ".\.Rayman\scripts\telemetry\export_artifacts.sh" @CliArgs | Out-Host
      } else {
        Write-Host "[telemetry-export] neither wsl.exe nor bash found."
      }
    }
    break
  }
  "telemetry-index" {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    $argLine = ""
    if ($CliArgs) { $argLine = ($CliArgs -join " ") }
    if ($null -ne $wsl) {
      $repoWin = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
      if ($repoWin -match '^[A-Za-z]:\\') {
        $drive = $repoWin.Substring(0,1).ToLowerInvariant()
        $rest = $repoWin.Substring(2).Replace('\', '/')
        $repoWsl = "/mnt/$drive$rest"
      } else {
        $repoWsl = $repoWin.Replace('\', '/')
      }
      $wslCmd = "cd '$repoWsl' && bash ./.Rayman/scripts/telemetry/index_artifacts.sh"
      if ($argLine) { $wslCmd += " $argLine" }
      & wsl.exe -e bash -lc $wslCmd | Out-Host
    } else {
      $bash = Get-Command bash -ErrorAction SilentlyContinue
      if ($null -ne $bash) {
        & bash ".\.Rayman\scripts\telemetry\index_artifacts.sh" @CliArgs | Out-Host
      } else {
        Write-Host "[telemetry-index] neither wsl.exe nor bash found."
      }
    }
    break
  }
  "telemetry-prune" {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    $argLine = ""
    if ($CliArgs) { $argLine = ($CliArgs -join " ") }
    if ($null -ne $wsl) {
      $repoWin = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
      if ($repoWin -match '^[A-Za-z]:\\') {
        $drive = $repoWin.Substring(0,1).ToLowerInvariant()
        $rest = $repoWin.Substring(2).Replace('\', '/')
        $repoWsl = "/mnt/$drive$rest"
      } else {
        $repoWsl = $repoWin.Replace('\', '/')
      }
      $wslCmd = "cd '$repoWsl' && bash ./.Rayman/scripts/telemetry/prune_artifacts.sh"
      if ($argLine) { $wslCmd += " $argLine" }
      & wsl.exe -e bash -lc $wslCmd | Out-Host
    } else {
      $bash = Get-Command bash -ErrorAction SilentlyContinue
      if ($null -ne $bash) {
        & bash ".\.Rayman\scripts\telemetry\prune_artifacts.sh" @CliArgs | Out-Host
      } else {
        Write-Host "[telemetry-prune] neither wsl.exe nor bash found."
      }
    }
    break
  }
  "deploy" { & "$PSScriptRoot\scripts\deploy\deploy.ps1" @CliArgs; break }
  "cache-clear" { & "$PSScriptRoot\scripts\utils\clear_cache.ps1" @CliArgs; break }
    "transfer-export" { Export-State -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path; break }
    "transfer-import" {
      $rootPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
      Import-State -WorkspaceRoot $rootPath
      Apply-State -WorkspaceRoot $rootPath
      Restart-Watchers -WorkspaceRoot $rootPath
      break
    }
  "state-save" { & "$PSScriptRoot\scripts\state\save_state.ps1" @CliArgs; break }
  "state-list" { & "$PSScriptRoot\scripts\state\list_state.ps1" @CliArgs; break }
  "state-resume" { & "$PSScriptRoot\scripts\state\resume_state.ps1" @CliArgs; break }
  "worktree-create" { & "$PSScriptRoot\scripts\state\worktree_create.ps1" @CliArgs; break }
  "test-fix" { & "$PSScriptRoot\scripts\repair\run_tests_and_fix.ps1" @CliArgs; break }
  "dist-sync" { & "$PSScriptRoot\scripts\release\sync_dist_from_src.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path -Validate; break }
  "diagnostics-residual" { & "$PSScriptRoot\scripts\utils\diagnose_residual_diagnostics.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @CliArgs; break }
  "sound-check" { & "$PSScriptRoot\scripts\utils\sound_check.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @CliArgs; break }
  "release-gate" {
    $releaseParams = @{ WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path }
    for ($i = 0; $i -lt $CliArgs.Count; $i++) {
      $token = [string]$CliArgs[$i]
      switch -Regex ($token) {
        '^--?(WorkspaceRoot|workspace-root)$' { if ($i + 1 -lt $CliArgs.Count) { $releaseParams['WorkspaceRoot'] = [string]$CliArgs[++$i] }; continue }
        '^--?(ReportPath|report-path)$' { if ($i + 1 -lt $CliArgs.Count) { $releaseParams['ReportPath'] = [string]$CliArgs[++$i] }; continue }
        '^--?(Mode|mode)$' { if ($i + 1 -lt $CliArgs.Count) { $releaseParams['Mode'] = [string]$CliArgs[++$i] }; continue }
        '^--?(SkipAutoDistSync|skip-auto-dist-sync)$' { $releaseParams['SkipAutoDistSync'] = $true; continue }
        '^--?(AllowNoGit|allow-no-git)$' { $releaseParams['AllowNoGit'] = $true; continue }
        '^--?(Json|json)$' { $releaseParams['Json'] = $true; continue }
        '^--?(IncludeResidualDiagnostics|include-residual-diagnostics)$' { $releaseParams['IncludeResidualDiagnostics'] = $true; continue }
      }
    }
    & "$PSScriptRoot\scripts\release\release_gate.ps1" @releaseParams
    $releaseExitCode = 0
    if (Test-Path variable:LASTEXITCODE) {
      $releaseExitCode = [int]$LASTEXITCODE
    } elseif (-not $?) {
      $releaseExitCode = 1
    }
    Exit-RaymanCli -ExitCode $releaseExitCode -CommandName $cmd -InputArgs $CliArgs
  }
  "release" {
    $releaseParams = @{ WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path }
    for ($i = 0; $i -lt $CliArgs.Count; $i++) {
      $token = [string]$CliArgs[$i]
      switch -Regex ($token) {
        '^--?(WorkspaceRoot|workspace-root)$' { if ($i + 1 -lt $CliArgs.Count) { $releaseParams['WorkspaceRoot'] = [string]$CliArgs[++$i] }; continue }
        '^--?(ReportPath|report-path)$' { if ($i + 1 -lt $CliArgs.Count) { $releaseParams['ReportPath'] = [string]$CliArgs[++$i] }; continue }
        '^--?(Mode|mode)$' { if ($i + 1 -lt $CliArgs.Count) { $releaseParams['Mode'] = [string]$CliArgs[++$i] }; continue }
        '^--?(SkipAutoDistSync|skip-auto-dist-sync)$' { $releaseParams['SkipAutoDistSync'] = $true; continue }
        '^--?(AllowNoGit|allow-no-git)$' { $releaseParams['AllowNoGit'] = $true; continue }
        '^--?(Json|json)$' { $releaseParams['Json'] = $true; continue }
        '^--?(IncludeResidualDiagnostics|include-residual-diagnostics)$' { $releaseParams['IncludeResidualDiagnostics'] = $true; continue }
      }
    }
    & "$PSScriptRoot\scripts\release\release_gate.ps1" @releaseParams
    $releaseExitCode = 0
    if (Test-Path variable:LASTEXITCODE) {
      $releaseExitCode = [int]$LASTEXITCODE
    } elseif (-not $?) {
      $releaseExitCode = 1
    }
    Exit-RaymanCli -ExitCode $releaseExitCode -CommandName $cmd -InputArgs $CliArgs
  }
  "version" {
    & "$PSScriptRoot\scripts\release\manage_version.ps1" -WorkspaceRoot $script:RaymanCliWorkspaceRoot -Action show
    Exit-RaymanCli -ExitCode (Resolve-RaymanCommandExitCode -Default 0) -CommandName $cmd -InputArgs $CliArgs
  }
  "newversion" {
    $newVersionArgs = @($CliArgs)
    if ($newVersionArgs.Count -eq 0 -and $script:RaymanCliInvokedFromMenu) {
      $menuVersion = [string](Read-Host '请输入目标版本（如 v162）')
      if ([string]::IsNullOrWhiteSpace($menuVersion)) {
        Write-Host '[newversion] 已取消。'
        Exit-RaymanCli -ExitCode 0 -CommandName $cmd -InputArgs @()
      }
      $newVersionArgs = @($menuVersion.Trim())
    }

    if ($newVersionArgs.Count -eq 0) {
      Write-Error 'newversion requires an explicit target version like v162.'
      Exit-RaymanCli -ExitCode 2 -CommandName $cmd -InputArgs $CliArgs
    }
    if ($newVersionArgs.Count -gt 1) {
      Write-Error 'newversion accepts exactly one target version argument.'
      Exit-RaymanCli -ExitCode 2 -CommandName $cmd -InputArgs $CliArgs
    }

    & "$PSScriptRoot\scripts\release\manage_version.ps1" -WorkspaceRoot $script:RaymanCliWorkspaceRoot -Action set -Version ([string]$newVersionArgs[0])
    Exit-RaymanCli -ExitCode (Resolve-RaymanCommandExitCode -Default 0) -CommandName $cmd -InputArgs $newVersionArgs
  }
  "package-dist" { & "$PSScriptRoot\scripts\release\package_distributable.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @CliArgs; break }
  "context-update" { & "$PSScriptRoot\scripts\utils\generate_context.ps1" @CliArgs; break }
  "agent-contract" {
    if (Test-Path variable:LASTEXITCODE) {
      $global:LASTEXITCODE = 0
    }
    & "$PSScriptRoot\scripts\agents\check_agent_contract.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @CliArgs
    if ($?) {
      $global:LASTEXITCODE = 0
      break
    }
    if (Test-Path variable:LASTEXITCODE) {
      Exit-RaymanCli -ExitCode ([int]$LASTEXITCODE) -CommandName $cmd -InputArgs $CliArgs
    }
    Exit-RaymanCli -ExitCode 1 -CommandName $cmd -InputArgs $CliArgs
  }
  "agent-capabilities" {
    $capabilityParams = @{ WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path }
    $syncRequested = $false
    $jsonRequested = $false
    for ($i = 0; $i -lt $CliArgs.Count; $i++) {
      $token = [string]$CliArgs[$i]
      switch -Regex ($token) {
        '^--?(WorkspaceRoot|workspace-root)$' { if ($i + 1 -lt $CliArgs.Count) { $capabilityParams['WorkspaceRoot'] = [string]$CliArgs[++$i] }; continue }
        '^--?(Action|action)$' { if ($i + 1 -lt $CliArgs.Count) { $capabilityParams['Action'] = [string]$CliArgs[++$i] }; continue }
        '^--?(Sync|sync)$' { $syncRequested = $true; continue }
        '^--?(Json|json)$' { $jsonRequested = $true; continue }
      }
    }
    if ($syncRequested -and -not $capabilityParams.ContainsKey('Action')) {
      $capabilityParams['Action'] = 'sync'
    }
    if (-not $capabilityParams.ContainsKey('Action')) {
      $capabilityParams['Action'] = 'status'
    }
    if ($jsonRequested) {
      $capabilityParams['Json'] = $true
    }
    & "$PSScriptRoot\scripts\agents\ensure_agent_capabilities.ps1" @capabilityParams
    if (Test-Path variable:LASTEXITCODE) {
      Exit-RaymanCli -ExitCode ([int]$LASTEXITCODE) -CommandName $cmd -InputArgs $CliArgs
    }
    Exit-RaymanCli -ExitCode $(if ($?) { 0 } else { 1 }) -CommandName $cmd -InputArgs $CliArgs
  }
  "interaction-mode" {
    Invoke-RaymanInteractionModeCommand -WorkspaceRoot $script:RaymanCliWorkspaceRoot -InputArgs $CliArgs
    Exit-RaymanCli -ExitCode 0 -CommandName $cmd -InputArgs $CliArgs
  }
  "codex" { & "$PSScriptRoot\scripts\codex\manage_accounts.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @CliArgs; break }
  "worker" { & "$PSScriptRoot\scripts\worker\manage_workers.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @CliArgs; break }
  "workspace-install" { & "$PSScriptRoot\scripts\workspace\install_workspace.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path -Action install @CliArgs; break }
  "workspace-register" { & "$PSScriptRoot\scripts\workspace\register_workspace.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @CliArgs; break }
  "health-check" { & "$PSScriptRoot\scripts\watch\daily_health_check.ps1" @CliArgs; break }
  "one-click-health" {
    $workspaceArg = [string](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('WorkspaceRoot', 'workspace-root') -Default $script:RaymanCliWorkspaceRoot)
    $jsonArg = Test-RaymanCliFlagPresent -InputArgs $CliArgs -Names @('Json', 'json', 'AsJson', 'as-json', 'asjson')

    & "$PSScriptRoot\scripts\watch\daily_health_check.ps1" -WorkspaceRoot $workspaceArg -Force
    $dailyExitCode = Resolve-RaymanCommandExitCode -Default 0
    if ($dailyExitCode -ne 0) {
      Exit-RaymanCli -ExitCode $dailyExitCode -CommandName $cmd -InputArgs $CliArgs
    }

    & "$PSScriptRoot\scripts\proxy\proxy_health_check.ps1" -WorkspaceRoot $workspaceArg -Refresh:$true -AsJson:$jsonArg
    break
  }
  "proxy-health" {
    $workspaceArg = [string](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('WorkspaceRoot', 'workspace-root') -Default $script:RaymanCliWorkspaceRoot)
    $refreshArg = Test-RaymanCliFlagPresent -InputArgs $CliArgs -Names @('Refresh', 'refresh')
    $jsonArg = Test-RaymanCliFlagPresent -InputArgs $CliArgs -Names @('Json', 'json', 'AsJson', 'as-json', 'asjson')
    & "$PSScriptRoot\scripts\proxy\proxy_health_check.ps1" -WorkspaceRoot $workspaceArg -Refresh:$refreshArg -AsJson:$jsonArg
    break
  }
  "ensure-wsl-deps" { & "$PSScriptRoot\scripts\utils\ensure_wsl_deps.ps1" @CliArgs; break }
  "ensure-win-deps" { & "$PSScriptRoot\scripts\utils\ensure_win_deps.ps1" @CliArgs; break }
  "dispatch" { & "$PSScriptRoot\scripts\agents\dispatch.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @CliArgs; break }
  "review-loop" { & "$PSScriptRoot\scripts\agents\review_loop.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @CliArgs; break }
  "first-pass-report" { & "$PSScriptRoot\scripts\agents\first_pass_report.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @CliArgs; break }
  "single-repo-upgrade" {
    $upgradeParams = @{ WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path }
    for ($i = 0; $i -lt $CliArgs.Count; $i++) {
      $token = [string]$CliArgs[$i]
      switch -Regex ($token) {
        '^--?(WorkspaceRoot|workspace-root)$' { if ($i + 1 -lt $CliArgs.Count) { $upgradeParams['WorkspaceRoot'] = [string]$CliArgs[++$i] }; continue }
        '^--?(Task|task)$' { if ($i + 1 -lt $CliArgs.Count) { $upgradeParams['Task'] = [string]$CliArgs[++$i] }; continue }
        '^--?(TaskKind|task-kind)$' { if ($i + 1 -lt $CliArgs.Count) { $upgradeParams['TaskKind'] = [string]$CliArgs[++$i] }; continue }
        '^--?(PreferredBackend|preferred-backend)$' { if ($i + 1 -lt $CliArgs.Count) { $upgradeParams['PreferredBackend'] = [string]$CliArgs[++$i] }; continue }
        '^--?(AutoResetCircuit|auto-reset-circuit)$' {
          if ($i + 1 -lt $CliArgs.Count -and -not ([string]$CliArgs[$i + 1]).StartsWith('-')) {
            $upgradeParams['AutoResetCircuit'] = [string]$CliArgs[++$i]
          } else {
            $upgradeParams['AutoResetCircuit'] = '1'
          }
          continue
        }
        '^--?(NoAutoResetCircuit|no-auto-reset-circuit)$' { $upgradeParams['AutoResetCircuit'] = '0'; continue }
        '^--?(RiskMode|risk-mode)$' { if ($i + 1 -lt $CliArgs.Count) { $upgradeParams['RiskMode'] = [string]$CliArgs[++$i] }; continue }
        '^--?(BypassReason|bypass-reason)$' { if ($i + 1 -lt $CliArgs.Count) { $upgradeParams['BypassReason'] = [string]$CliArgs[++$i] }; continue }
        '^--?(ApproveHighRisk|approve-high-risk)$' { $upgradeParams['ApproveHighRisk'] = $true; continue }
        '^--?(SkipReleaseGate|skip-release-gate)$' { $upgradeParams['SkipReleaseGate'] = $true; continue }
        '^--?(PolicyBypass|policy-bypass)$' { $upgradeParams['PolicyBypass'] = $true; continue }
      }
    }
    & "$PSScriptRoot\scripts\agents\single_repo_upgrade.ps1" @upgradeParams
    break
  }
  "single-repo-kpi" {
    $kpiParams = @{ WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path }
    for ($i = 0; $i -lt $CliArgs.Count; $i++) {
      $token = [string]$CliArgs[$i]
      switch -Regex ($token) {
        '^--?(WorkspaceRoot|workspace-root)$' { if ($i + 1 -lt $CliArgs.Count) { $kpiParams['WorkspaceRoot'] = [string]$CliArgs[++$i] }; continue }
        '^--?(Window|window)$' { if ($i + 1 -lt $CliArgs.Count) { $kpiParams['Window'] = [int][string]$CliArgs[++$i] }; continue }
        '^--?(Json|json)$' { $kpiParams['Json'] = $true; continue }
      }
    }
    & "$PSScriptRoot\scripts\telemetry\single_repo_kpi.ps1" @kpiParams
    break
  }
  "prompts" { & "$PSScriptRoot\scripts\agents\prompts_catalog.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @CliArgs; break }
  default { Write-Error "Unknown command: $Command"; Exit-RaymanCli -ExitCode 2 -CommandName $Command -InputArgs $CliArgs }
}

Exit-RaymanCli -ExitCode (Resolve-RaymanCommandExitCode -Default 0) -CommandName $cmd -InputArgs $CliArgs
