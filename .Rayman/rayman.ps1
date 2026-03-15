param(
  [Parameter(Position=0)][string]$Command = "help",
  [Parameter(Position=1, ValueFromRemainingArguments=$true)][string[]]$CliArgs
)

. (Join-Path $PSScriptRoot 'common.ps1')
$commandCatalogScript = Join-Path $PSScriptRoot 'scripts\utils\command_catalog.ps1'
if (Test-Path -LiteralPath $commandCatalogScript -PathType Leaf) {
  . $commandCatalogScript
}

$cmd = $Command.ToLowerInvariant()
$commandProvided = $PSBoundParameters.ContainsKey('Command')
$script:RaymanCliWorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Get-RaymanMenuStatePath {
  $workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
  $runtimeDir = Join-Path $workspaceRoot '.Rayman\runtime'
  if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
  }
  return (Join-Path $runtimeDir 'menu_last_choice.json')
}

function Get-RaymanLastMenuChoice {
  $statePath = Get-RaymanMenuStatePath
  if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
  try {
    $obj = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    return $obj
  } catch {
    return $null
  }
}

function Set-RaymanLastMenuChoice([int]$Index, [string]$CommandName, [string[]]$CommandArgs) {
  try {
    $statePath = Get-RaymanMenuStatePath
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

function Show-RaymanInteractiveMenu {
  $menu = @(
    @{ Index = 1;  Command = 'init';              Desc = '初始化环境';              DefaultArgs = @() },
    @{ Index = 2;  Command = 'ensure-win-deps';   Desc = 'Windows 依赖检查';        DefaultArgs = @() },
    @{ Index = 3;  Command = 'ensure-wsl-deps';   Desc = 'WSL 依赖检查/安装';       DefaultArgs = @() },
    @{ Index = 4;  Command = 'proxy-health';      Desc = '代理健康检查（自动 refresh）'; DefaultArgs = @('--refresh') },
    @{ Index = 5;  Command = 'ensure-playwright'; Desc = 'Playwright 就绪检查';     DefaultArgs = @() },
    @{ Index = 6;  Command = 'test-fix';          Desc = '测试并修复（自愈）';      DefaultArgs = @() },
    @{ Index = 7;  Command = 'release-gate';      Desc = '发布闸门检查';            DefaultArgs = @() },
    @{ Index = 8;  Command = 'context-update';    Desc = '更新上下文';              DefaultArgs = @() },
    @{ Index = 9;  Command = 'cache-clear';       Desc = '清理缓存';                DefaultArgs = @() },
    @{ Index = 10; Command = 'state-save';        Desc = '保存状态';                DefaultArgs = @() },
    @{ Index = 11; Command = 'state-resume';      Desc = '恢复状态';                DefaultArgs = @() },
    @{ Index = 12; Command = 'watch-auto';        Desc = '启动后台监听';            DefaultArgs = @() },
    @{ Index = 13; Command = 'watch-stop';        Desc = '停止后台监听';            DefaultArgs = @() },
    @{ Index = 14; Command = 'prompts';           Desc = 'Prompt 模板管理';         DefaultArgs = @('-Action', 'list') },
    @{ Index = 15; Command = 'copy-self-check';   Desc = '拷贝后初始化自检';        DefaultArgs = @() },
    @{ Index = 16; Command = 'pwa-test';          Desc = 'PWA 自动化测试（本机兜底）'; DefaultArgs = @() },
    @{ Index = 17; Command = 'ensure-winapp';     Desc = 'Windows桌面自动化就绪检查'; DefaultArgs = @() },
    @{ Index = 18; Command = 'winapp-test';       Desc = 'Windows桌面自动化（WinForms/MAUI）'; DefaultArgs = @() },
    @{ Index = 19; Command = 'winapp-inspect';    Desc = 'Windows控件树探查';       DefaultArgs = @() },
    @{ Index = 20; Command = 'linux-test';        Desc = 'WSL Linux 自动化自测';   DefaultArgs = @() },
    @{ Index = 21; Command = 'single-repo-upgrade'; Desc = '单仓库深度增强（质量优先）'; DefaultArgs = @() },
    @{ Index = 22; Command = 'single-repo-kpi';   Desc = '单仓库KPI看板生成';        DefaultArgs = @() },
    @{ Index = 23; Command = 'agent-contract';    Desc = 'Agent 契约自检';           DefaultArgs = @() },
    @{ Index = 24; Command = 'agent-capabilities'; Desc = 'Agent 能力同步/状态';      DefaultArgs = @() },
    @{ Index = 25; Command = 'fast-gate';         Desc = '项目快速门禁';              DefaultArgs = @() },
    @{ Index = 26; Command = 'browser-gate';      Desc = '项目浏览器门禁';            DefaultArgs = @() },
    @{ Index = 27; Command = 'full-gate';         Desc = '项目完整门禁';              DefaultArgs = @() }
  )

  $last = Get-RaymanLastMenuChoice
  $defaultIndex = 0
  if ($last -and $last.PSObject.Properties['index']) {
    $parsed = 0
    if ([int]::TryParse([string]$last.index, [ref]$parsed)) {
      if ($menu | Where-Object { $_.Index -eq $parsed }) {
        $defaultIndex = $parsed
      }
    }
  }

@"
=======================================================
🤖 Rayman 交互菜单（输入编号即可）
=======================================================
"@

  foreach ($item in $menu) {
    $marker = ' '
    if ($defaultIndex -gt 0 -and $item.Index -eq $defaultIndex) { $marker = '★' }
    Write-Host ("{0} {1,2}) {2,-17} {3}" -f $marker, $item.Index, $item.Command, $item.Desc)
  }

  Write-Host @"

可输入：
 - 编号（如 6）
 - 回车（默认执行上次选择）
 - 命令名（如 test-fix）
 - q / quit 退出
=======================================================
"@

  if ($defaultIndex -gt 0) {
    $choice = Read-Host ("请选择操作（默认 {0}）" -f $defaultIndex)
  } else {
    $choice = Read-Host "请选择操作"
  }

  if ([string]::IsNullOrWhiteSpace($choice)) {
    if ($defaultIndex -gt 0) {
      $pickedDefault = $menu | Where-Object { $_.Index -eq $defaultIndex } | Select-Object -First 1
      if ($pickedDefault) {
        Set-RaymanLastMenuChoice -Index $pickedDefault.Index -CommandName $pickedDefault.Command -CommandArgs $pickedDefault.DefaultArgs
        return @{ Command = $pickedDefault.Command; CliArgs = @($pickedDefault.DefaultArgs) }
      }
    }
    return @{ Command = 'help'; CliArgs = @() }
  }

  $token = $choice.Trim()
  $pickedByIndex = $null
  $parsedIndex = 0
  if ([int]::TryParse($token, [ref]$parsedIndex)) {
    $pickedByIndex = $menu | Where-Object { $_.Index -eq $parsedIndex } | Select-Object -First 1
    if ($pickedByIndex) {
      Set-RaymanLastMenuChoice -Index $pickedByIndex.Index -CommandName $pickedByIndex.Command -CommandArgs $pickedByIndex.DefaultArgs
      return @{ Command = $pickedByIndex.Command; CliArgs = @($pickedByIndex.DefaultArgs) }
    }
  }

  switch -Regex ($token.ToLowerInvariant()) {
    '^(q|quit|exit)$' { return $null }
    default {
      $parts = @($token -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      if ($parts.Count -eq 0) {
        return @{ Command = 'help'; CliArgs = @() }
      }

      $name = $parts[0]
      $extraArgs = @()
      if ($parts.Count -gt 1) {
        $extraArgs = @($parts[1..($parts.Count - 1)])
      }

      $matched = $menu | Where-Object { $_.Command -ieq $name } | Select-Object -First 1
      if ($matched) {
        $finalArgs = @($matched.DefaultArgs) + @($extraArgs)
        Set-RaymanLastMenuChoice -Index $matched.Index -CommandName $matched.Command -CommandArgs $finalArgs
        return @{ Command = $matched.Command; CliArgs = $finalArgs }
      }

      Set-RaymanLastMenuChoice -Index 0 -CommandName $name -CommandArgs $extraArgs
      return @{ Command = $name; CliArgs = $extraArgs }
    }
  }
}

function Show-Help {
  if (Get-Command Format-RaymanHelpText -ErrorAction SilentlyContinue) {
    Write-Output (Format-RaymanHelpText -WorkspaceRoot $script:RaymanCliWorkspaceRoot -Surface pwsh)
    return
  }

  @"
Rayman CLI (v161)

Usage:
  .\.Rayman\rayman.cmd <command>
"@
}

if ((-not $commandProvided) -and $cmd -ne 'menu' -and $cmd -ne 'interactive') {
  Show-Help
  Write-Host ''
  Write-Host '提示：如需交互式菜单，请显式运行：.\.Rayman\rayman.cmd menu' -ForegroundColor Cyan
  exit 0
}

if ($cmd -eq 'menu' -or $cmd -eq 'interactive') {
  $picked = Show-RaymanInteractiveMenu
  if ($null -eq $picked) { exit 0 }
  $cmd = ([string]$picked.Command).ToLowerInvariant()
  if ($picked.ContainsKey('CliArgs')) {
    $CliArgs = [string[]]$picked['CliArgs']
  } else {
    $CliArgs = @()
  }
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
    'interactive' { return $true }
    'copy-self-check' { return $true }
    'self-check' { return $true }
    'copy-check' { return $true }
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

function Exit-RaymanCli {
  param(
    [int]$ExitCode,
    [string]$CommandName,
    [string[]]$InputArgs = @()
  )

  if ($ExitCode -eq 0) {
    Invoke-RaymanCliDoneAlert -CommandName $CommandName -InputArgs $InputArgs
  }

  exit $ExitCode
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
    & "$PSScriptRoot\scripts\watch\stop_background_watchers.ps1" -WorkspaceRoot $rootPath -IncludeResidualCleanup:$true
    break
  }
  "alert-watch" {
    & "$PSScriptRoot\scripts\alerts\attention_watch.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    break
  }
  "alert-stop" {
    $rootPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $pidFile = Join-Path $rootPath ".Rayman\runtime\attention_watch.pid"
    if (Test-Path -LiteralPath $pidFile -PathType Leaf) {
      $raw = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
      $pidVal = 0
      if ([int]::TryParse($raw, [ref]$pidVal) -and $pidVal -gt 0) {
        $p = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
        if ($p) {
          try { Stop-Process -Id $pidVal -Force -ErrorAction Stop } catch {}
        }
      }
      try { Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue } catch {}
      if (Test-Path -LiteralPath $pidFile -PathType Leaf) {
        Write-Host "[alert-watch] stop requested, but pid file still exists (可能权限受限)。"
      } else {
        Write-Host "[alert-watch] stopped"
      }
    } else {
      Write-Host "[alert-watch] pid file not found; watcher may not be running."
    }
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

  "migrate-rag" {
    & "$PSScriptRoot\scripts\rag\migrate_legacy_rag.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @CliArgs
    break
  }
  "rag-bootstrap" {
    & "$PSScriptRoot\scripts\rag\rag_bootstrap.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path -Action ensure @CliArgs
    break
  }

  "doctor" {
    $doctorArgs = @($CliArgs)
    $copySmoke = Test-RaymanCliFlagPresent -InputArgs $doctorArgs -Names @('copy-smoke')
    $copySmokeStrict = Test-RaymanCliFlagPresent -InputArgs $doctorArgs -Names @('strict')
    $copySmokeKeepTemp = Test-RaymanCliFlagPresent -InputArgs $doctorArgs -Names @('keep-temp')
    $copySmokeTimeoutSeconds = [int](Get-RaymanCliOptionValue -InputArgs $doctorArgs -Names @('timeout-seconds') -Default 120 -ThrowOnMissingValue:$false)
    $copySmokeScope = [string](Get-RaymanCliOptionValue -InputArgs $doctorArgs -Names @('scope') -Default 'wsl' -ThrowOnMissingValue:$false)

    if ($copySmoke) {
      $doctorRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
      $smokeParams = @{
        WorkspaceRoot = $doctorRoot
        TimeoutSeconds = $copySmokeTimeoutSeconds
        Scope = $copySmokeScope
      }
      if ($copySmokeStrict) { $smokeParams['Strict'] = $true }
      if ($copySmokeKeepTemp) { $smokeParams['KeepTemp'] = $true }
      & "$PSScriptRoot\scripts\release\copy_smoke.ps1" @smokeParams
      break
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
    & $PSCommandPath doctor --copy-smoke @CliArgs
    break
  }
  "self-check" {
    & $PSCommandPath doctor --copy-smoke @CliArgs
    break
  }
  "copy-check" {
    & $PSCommandPath doctor --copy-smoke @CliArgs
    break
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

    if ($IsWindows) {
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
  "state-save" { & "$PSScriptRoot\scripts\state\save_state.ps1" @CliArgs; break }
  "state-resume" { & "$PSScriptRoot\scripts\state\resume_state.ps1" @CliArgs; break }
  "test-fix" { & "$PSScriptRoot\scripts\repair\run_tests_and_fix.ps1" @CliArgs; break }
  "req-ts-backfill" { & "$PSScriptRoot\scripts\requirements\backfill_requirements_timestamps.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @CliArgs; break }
  "dist-sync" { & "$PSScriptRoot\scripts\release\sync_dist_from_src.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path -Validate; break }
  "diagnostics-residual" { & "$PSScriptRoot\scripts\utils\diagnose_residual_diagnostics.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @CliArgs; break }
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
  "package-dist" { & "$PSScriptRoot\scripts\release\package_distributable.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @CliArgs; break }
  "package" { & "$PSScriptRoot\scripts\release\package_distributable.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @CliArgs; break }
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
  "health-check" { & "$PSScriptRoot\scripts\watch\daily_health_check.ps1" @CliArgs; break }
  "proxy-health" {
    $workspaceArg = [string](Get-RaymanCliOptionValue -InputArgs $CliArgs -Names @('WorkspaceRoot', 'workspace-root') -Default $script:RaymanCliWorkspaceRoot)
    $refreshArg = Test-RaymanCliFlagPresent -InputArgs $CliArgs -Names @('Refresh', 'refresh')
    $jsonArg = Test-RaymanCliFlagPresent -InputArgs $CliArgs -Names @('Json', 'json', 'AsJson', 'as-json', 'asjson')
    & "$PSScriptRoot\scripts\proxy\proxy_health_check.ps1" -WorkspaceRoot $workspaceArg -Refresh:$refreshArg -AsJson:$jsonArg
    break
  }
  "proxy-check" {
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
