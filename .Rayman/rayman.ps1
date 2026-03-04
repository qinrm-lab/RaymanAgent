param(
  [Parameter(Position=0)][string]$Command = "help",
  [Parameter(Position=1, ValueFromRemainingArguments=$true)][string[]]$Args
)

$cmd = $Command.ToLowerInvariant()
$commandProvided = $PSBoundParameters.ContainsKey('Command')

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
    @{ Index = 1;  Command = 'init';              Desc = '初始化环境';              Args = @() },
    @{ Index = 2;  Command = 'ensure-win-deps';   Desc = 'Windows 依赖检查';        Args = @() },
    @{ Index = 3;  Command = 'ensure-wsl-deps';   Desc = 'WSL 依赖检查/安装';       Args = @() },
    @{ Index = 4;  Command = 'proxy-health';      Desc = '代理健康检查（自动 refresh）'; Args = @('--refresh') },
    @{ Index = 5;  Command = 'ensure-playwright'; Desc = 'Playwright 就绪检查';     Args = @() },
    @{ Index = 6;  Command = 'test-fix';          Desc = '测试并修复（自愈）';      Args = @() },
    @{ Index = 7;  Command = 'release-gate';      Desc = '发布闸门检查';            Args = @() },
    @{ Index = 8;  Command = 'context-update';    Desc = '更新上下文';              Args = @() },
    @{ Index = 9;  Command = 'cache-clear';       Desc = '清理缓存';                Args = @() },
    @{ Index = 10; Command = 'state-save';        Desc = '保存状态';                Args = @() },
    @{ Index = 11; Command = 'state-resume';      Desc = '恢复状态';                Args = @() },
    @{ Index = 12; Command = 'watch-auto';        Desc = '启动后台监听';            Args = @() },
    @{ Index = 13; Command = 'watch-stop';        Desc = '停止后台监听';            Args = @() },
    @{ Index = 14; Command = 'prompts';           Desc = 'Prompt 模板管理';         Args = @('-Action', 'list') },
    @{ Index = 15; Command = 'copy-self-check';   Desc = '拷贝后初始化自检';        Args = @() },
    @{ Index = 16; Command = 'pwa-test';          Desc = 'PWA 自动化测试（本机兜底）'; Args = @() },
    @{ Index = 17; Command = 'winapp-test';       Desc = 'Windows桌面自动化（WinForms/MAUI）'; Args = @() },
    @{ Index = 18; Command = 'winapp-inspect';    Desc = 'Windows控件树探查';       Args = @() },
    @{ Index = 19; Command = 'linux-test';        Desc = 'WSL Linux 自动化自测';   Args = @() },
    @{ Index = 20; Command = 'single-repo-upgrade'; Desc = '单仓库深度增强（质量优先）'; Args = @() },
    @{ Index = 21; Command = 'single-repo-kpi';   Desc = '单仓库KPI看板生成';        Args = @() }
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
        Set-RaymanLastMenuChoice -Index $pickedDefault.Index -CommandName $pickedDefault.Command -CommandArgs $pickedDefault.Args
        return @{ Command = $pickedDefault.Command; Args = @($pickedDefault.Args) }
      }
    }
    return @{ Command = 'help'; Args = @() }
  }

  $token = $choice.Trim()
  $pickedByIndex = $null
  $parsedIndex = 0
  if ([int]::TryParse($token, [ref]$parsedIndex)) {
    $pickedByIndex = $menu | Where-Object { $_.Index -eq $parsedIndex } | Select-Object -First 1
    if ($pickedByIndex) {
      Set-RaymanLastMenuChoice -Index $pickedByIndex.Index -CommandName $pickedByIndex.Command -CommandArgs $pickedByIndex.Args
      return @{ Command = $pickedByIndex.Command; Args = @($pickedByIndex.Args) }
    }
  }

  switch -Regex ($token.ToLowerInvariant()) {
    '^(q|quit|exit)$' { return $null }
    default {
      $parts = @($token -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      if ($parts.Count -eq 0) {
        return @{ Command = 'help'; Args = @() }
      }

      $name = $parts[0]
      $extraArgs = @()
      if ($parts.Count -gt 1) {
        $extraArgs = @($parts[1..($parts.Count - 1)])
      }

      $matched = $menu | Where-Object { $_.Command -ieq $name } | Select-Object -First 1
      if ($matched) {
        $finalArgs = @($matched.Args) + @($extraArgs)
        Set-RaymanLastMenuChoice -Index $matched.Index -CommandName $matched.Command -CommandArgs $finalArgs
        return @{ Command = $matched.Command; Args = $finalArgs }
      }

      Set-RaymanLastMenuChoice -Index 0 -CommandName $name -CommandArgs $extraArgs
      return @{ Command = $name; Args = $extraArgs }
    }
  }
}

function Show-Help {
@"
Rayman CLI (v159)

Usage:
  .\.Rayman\rayman.cmd <command>

Commands:
  init        Run Windows init (sandbox/pxy checks)
  watch       Start Windows watcher (prompt sync + fast-init)
  watch-auto  Start background watchers (prompt-watch + alert-watch)
  watch-stop  Stop background watchers (prompt-watch + alert-watch + auto-save + MCP)
  alert-watch Start Windows attention watcher (popup/manual-action alerts)
  alert-stop  Stop Windows attention watcher
  fast-init   Generate missing/new requirements only (no installs)
  migrate     Migrate legacy requirements into new structure
  migrate-rag Migrate legacy RAG DB from .Rayman/state to .rag/<namespace>
  rag-bootstrap Probe/prepare RAG Python runtime and dependencies
  doctor      Read-only health check
  copy-self-check Run copy-initialization smoke check
  check       Run check suite
  ensure-test-deps Detect and auto-install SDK/toolchain needed for project tests
  ensure-playwright Ensure Playwright browser toolchain readiness for web auto-acceptance
  pwa-test    Run Playwright PWA flow test with local fallback when sandbox is unavailable
  winapp-test Run Windows desktop UI flow test (WinForms/MAUI) with auto dependency bootstrap
  winapp-inspect Export Windows desktop control tree by title regex for flow authoring
  linux-test  Run Linux tests in WSL with auto dependency bootstrap and command auto-detection
  clean       Governance cleanup (tmp/runtime/test bundles; optional aggressive mode)
  snapshot    Create rollback snapshot under .Rayman/runtime/snapshots
  metrics     Show rules/check telemetry summary (supports --json/assert flags)
  trend       Generate daily telemetry trend report
  baseline-guard Compare recent telemetry vs historical baseline
  telemetry-export Generate telemetry artifact bundle for CI/archive
  telemetry-index Rebuild telemetry artifact index
  telemetry-prune Prune telemetry artifact history and refresh index
  deploy      Deploy projects (auto-detect)
  cache-clear Clear caches (bin/obj/node_modules etc)
  state-save  Save task state + git stash
  state-resume Resume state + git stash pop
  test-fix    Run build/tests and write last_error logs
  req-ts-backfill Backfill timestamps for requirements markdown files
  dist-sync   Sync and validate .Rayman/.dist mirror (Windows-native)
  diagnostics-residual Check script residual diagnostics (source/dist consistency)
  release-gate Run release readiness gate and generate report
  package-dist Build slim distributable .Rayman zip
  context-update Generate .Rayman/CONTEXT.md
  health-check Run daily health check once
  proxy-health Show proxy candidates and current resolved proxy (supports --refresh/--json)
  ensure-wsl-deps Install/verify WSL deps (pwsh, notify, voice)
  ensure-win-deps Check Windows deps
  dispatch    Route task backend: copilot|codex|local (with policy + fallback)
  review-loop Run dispatch + test-fix iterative review loop
  first-pass-report Generate first-pass KPI report from review-loop telemetry
  single-repo-upgrade One-click single-repo deep upgrade (quality-first + automation depth)
  single-repo-kpi Build single-repo KPI dashboard (first-pass/rounds/CFR/MTTR/manual-rate)
  prompts     List/show/apply reusable prompt templates from .github/prompts
  menu        Show interactive command picker
  interactive Alias of menu

Doctor extras:
  --copy-smoke         Copy .Rayman to a temp folder and run setup smoke test
  --strict             Use strict setup path (no SkipReleaseGate/no env relaxation)
  --keep-temp          Keep temp copy workspace even when smoke passes
  --open-on-fail       Auto open temp workspace when copy smoke fails
  --scope <value>      Playwright scope for copy smoke: wsl|host|all|sandbox (default: wsl)

Clean extras:
  --copy-smoke-artifacts <0|1>  Also clean /tmp/rayman_copy_smoke_* artifacts

Release Gate extras:
  --mode <standard|project>     Select release gate profile
  --allow-no-git                Downgrade non-git workspace to WARN (instead of FAIL)
  --json                        Print machine-readable JSON report to stdout
  --include-residual-diagnostics Run residual diagnostics check and append result into release-gate report
"@
}

if ((-not $commandProvided) -or $cmd -eq 'menu' -or $cmd -eq 'interactive') {
  $picked = Show-RaymanInteractiveMenu
  if ($null -eq $picked) { exit 0 }
  $cmd = ([string]$picked.Command).ToLowerInvariant()
  if ($picked.ContainsKey('Args')) {
    $Args = [string[]]$picked.Args
  } else {
    $Args = @()
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

function Normalize-RaymanForwardArgs([string[]]$InputArgs, [string[]]$KnownParamNames) {
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
    & "$PSScriptRoot\scripts\rag\migrate_legacy_rag.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @Args
    break
  }
  "rag-bootstrap" {
    & "$PSScriptRoot\scripts\rag\rag_bootstrap.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path -Action ensure @Args
    break
  }

  "doctor" {
    $copySmoke = $false
    $copySmokeStrict = $false
    $copySmokeKeepTemp = $false
    $copySmokeTimeoutSeconds = 120
    $copySmokeScope = 'wsl'
    for ($i = 0; $i -lt $Args.Count; $i++) {
      $token = [string]$Args[$i]
      switch -Regex ($token) {
        '^--copy-smoke$' { $copySmoke = $true; continue }
        '^--strict$' { $copySmokeStrict = $true; continue }
        '^--keep-temp$' { $copySmokeKeepTemp = $true; continue }
        '^--timeout-seconds$' {
          if ($i + 1 -lt $Args.Count) {
            $copySmokeTimeoutSeconds = [int][string]$Args[++$i]
          } else {
            throw 'missing value for --timeout-seconds'
          }
          continue
        }
        '^--scope$' {
          if ($i + 1 -lt $Args.Count) {
            $copySmokeScope = [string]$Args[++$i]
          } else {
            throw 'missing value for --scope'
          }
          continue
        }
      }
    }

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

    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($null -ne $wsl) {
      $repo = (Resolve-Path (Join-Path $PSScriptRoot ".."))
      & wsl.exe -e bash -lc "cd \"$repo\" && bash ./.Rayman/run/rules.sh doctor" | Out-Host
    } else {
      & "$PSScriptRoot\win-check.ps1"; 
    }
    break
  }
  "copy-self-check" {
    & $PSCommandPath doctor --copy-smoke @Args
    break
  }
  "self-check" {
    & $PSCommandPath doctor --copy-smoke @Args
    break
  }
  "copy-check" {
    & $PSCommandPath doctor --copy-smoke @Args
    break
  }
  "check" { & "$PSScriptRoot\win-check.ps1"; break }
  "ensure-test-deps" {
    $workspaceArg = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $autoInstall = $true
    $require = $true
    for ($i = 0; $i -lt $Args.Count; $i++) {
      $token = [string]$Args[$i]
      switch -Regex ($token) {
        '^--?(WorkspaceRoot|workspace-root)$' { if ($i + 1 -lt $Args.Count) { $workspaceArg = [string]$Args[++$i] }; continue }
        '^--?(AutoInstall|auto-install)$' { if ($i + 1 -lt $Args.Count) { $autoInstall = ([string]$Args[++$i] -ne '0' -and [string]$Args[$i] -ne 'false') }; continue }
        '^--?(Require|require)$' { if ($i + 1 -lt $Args.Count) { $require = ([string]$Args[++$i] -ne '0' -and [string]$Args[$i] -ne 'false') }; continue }
      }
    }
    & "$PSScriptRoot\scripts\utils\ensure_project_test_deps.ps1" -WorkspaceRoot $workspaceArg -AutoInstall:$autoInstall -Require:$require
    break
  }
  "ensure-playwright" {
    $workspaceArg = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
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

    for ($i = 0; $i -lt $Args.Count; $i++) {
      $token = [string]$Args[$i]
      switch -Regex ($token) {
        '^--?(WorkspaceRoot|workspace-root)$' { if ($i + 1 -lt $Args.Count) { $workspaceArg = [string]$Args[++$i] }; continue }
        '^--?(Scope|scope)$' { if ($i + 1 -lt $Args.Count) { $scopeArg = [string]$Args[++$i] }; continue }
        '^--?(Browser|browser)$' { if ($i + 1 -lt $Args.Count) { $browserArg = [string]$Args[++$i] }; continue }
        '^--?(Require|require)$' { if ($i + 1 -lt $Args.Count) { $require = ([string]$Args[++$i] -ne '0' -and [string]$Args[$i] -ne 'false') }; continue }
        '^--?(TimeoutSeconds|timeout-seconds)$' { if ($i + 1 -lt $Args.Count) { $timeoutArg = [int][string]$Args[++$i] }; continue }
      }
    }

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
  "pwa-test" {
    $workspaceArg = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $flowArg = '.Rayman/pwa.flow.sample.json'
    $browserArg = 'chromium'
    $headlessArg = $true
    $timeoutArg = 30000
    $requireArg = $true
    $preferSandboxArg = $true

    for ($i = 0; $i -lt $Args.Count; $i++) {
      $token = [string]$Args[$i]
      switch -Regex ($token) {
        '^--?(WorkspaceRoot|workspace-root)$' { if ($i + 1 -lt $Args.Count) { $workspaceArg = [string]$Args[++$i] }; continue }
        '^--?(FlowFile|flow-file)$' { if ($i + 1 -lt $Args.Count) { $flowArg = [string]$Args[++$i] }; continue }
        '^--?(Browser|browser)$' { if ($i + 1 -lt $Args.Count) { $browserArg = [string]$Args[++$i] }; continue }
        '^--?(Headless|headless)$' { if ($i + 1 -lt $Args.Count) { $headlessArg = ([string]$Args[++$i] -ne '0' -and [string]$Args[$i] -ne 'false') }; continue }
        '^--?(TimeoutMs|timeout-ms)$' { if ($i + 1 -lt $Args.Count) { $timeoutArg = [int][string]$Args[++$i] }; continue }
        '^--?(Require|require)$' { if ($i + 1 -lt $Args.Count) { $requireArg = ([string]$Args[++$i] -ne '0' -and [string]$Args[$i] -ne 'false') }; continue }
        '^--?(PreferSandbox|prefer-sandbox)$' { if ($i + 1 -lt $Args.Count) { $preferSandboxArg = ([string]$Args[++$i] -ne '0' -and [string]$Args[$i] -ne 'false') }; continue }
      }
    }

    & "$PSScriptRoot\scripts\pwa\run_pwa_flow.ps1" -WorkspaceRoot $workspaceArg -FlowFile $flowArg -Browser $browserArg -Headless:$headlessArg -TimeoutMs $timeoutArg -Require:$requireArg -PreferSandbox:$preferSandboxArg
    break
  }
  "winapp-test" {
    $workspaceArg = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $flowArg = '.Rayman/winapp.flow.sample.json'
    $requireArg = $true
    $timeoutArg = 15000

    for ($i = 0; $i -lt $Args.Count; $i++) {
      $token = [string]$Args[$i]
      switch -Regex ($token) {
        '^--?(WorkspaceRoot|workspace-root)$' { if ($i + 1 -lt $Args.Count) { $workspaceArg = [string]$Args[++$i] }; continue }
        '^--?(FlowFile|flow-file)$' { if ($i + 1 -lt $Args.Count) { $flowArg = [string]$Args[++$i] }; continue }
        '^--?(Require|require)$' { if ($i + 1 -lt $Args.Count) { $requireArg = ([string]$Args[++$i] -ne '0' -and [string]$Args[$i] -ne 'false') }; continue }
        '^--?(DefaultTimeoutMs|default-timeout-ms)$' { if ($i + 1 -lt $Args.Count) { $timeoutArg = [int][string]$Args[++$i] }; continue }
      }
    }

    & "$PSScriptRoot\scripts\windows\run_winapp_flow.ps1" -WorkspaceRoot $workspaceArg -FlowFile $flowArg -Require:$requireArg -DefaultTimeoutMs $timeoutArg
    break
  }
  "winapp-inspect" {
    $workspaceArg = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $titleRegexArg = '.*'
    $outFileArg = '.Rayman/runtime/winapp-tests/control_tree.txt'
    $timeoutArg = 20

    for ($i = 0; $i -lt $Args.Count; $i++) {
      $token = [string]$Args[$i]
      switch -Regex ($token) {
        '^--?(WorkspaceRoot|workspace-root)$' { if ($i + 1 -lt $Args.Count) { $workspaceArg = [string]$Args[++$i] }; continue }
        '^--?(WindowTitleRegex|window-title-regex|TitleRegex|title-regex)$' { if ($i + 1 -lt $Args.Count) { $titleRegexArg = [string]$Args[++$i] }; continue }
        '^--?(OutFile|out-file)$' { if ($i + 1 -lt $Args.Count) { $outFileArg = [string]$Args[++$i] }; continue }
        '^--?(TimeoutSeconds|timeout-seconds)$' { if ($i + 1 -lt $Args.Count) { $timeoutArg = [int][string]$Args[++$i] }; continue }
      }
    }

    & "$PSScriptRoot\scripts\windows\inspect_winapp.ps1" -WorkspaceRoot $workspaceArg -WindowTitleRegex $titleRegexArg -OutFile $outFileArg -TimeoutSeconds $timeoutArg
    break
  }
  "linux-test" {
    $workspaceArg = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $commandArg = ''
    $autoInstallArg = $true
    $requireArg = $true

    for ($i = 0; $i -lt $Args.Count; $i++) {
      $token = [string]$Args[$i]
      switch -Regex ($token) {
        '^--?(WorkspaceRoot|workspace-root)$' { if ($i + 1 -lt $Args.Count) { $workspaceArg = [string]$Args[++$i] }; continue }
        '^--?(TestCommand|test-command|Cmd|cmd)$' { if ($i + 1 -lt $Args.Count) { $commandArg = [string]$Args[++$i] }; continue }
        '^--?(AutoInstall|auto-install)$' { if ($i + 1 -lt $Args.Count) { $autoInstallArg = ([string]$Args[++$i] -ne '0' -and [string]$Args[$i] -ne 'false') }; continue }
        '^--?(Require|require)$' { if ($i + 1 -lt $Args.Count) { $requireArg = ([string]$Args[++$i] -ne '0' -and [string]$Args[$i] -ne 'false') }; continue }
      }
    }

    & "$PSScriptRoot\scripts\linux\run_wsl_auto_test.ps1" -WorkspaceRoot $workspaceArg -Command $commandArg -AutoInstall:$autoInstallArg -Require:$requireArg
    break
  }
  "clean" {
    $workspaceArg = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $keepDaysArg = $null
    $dryRunArg = $null
    $aggressiveArg = $null
    $copySmokeArtifactsArg = $null

    for ($i = 0; $i -lt $Args.Count; $i++) {
      $token = [string]$Args[$i]
      switch -Regex ($token) {
        '^--?(WorkspaceRoot|workspace-root)$' { if ($i + 1 -lt $Args.Count) { $workspaceArg = [string]$Args[++$i] }; continue }
        '^--?(KeepDays|keep-days)$' { if ($i + 1 -lt $Args.Count) { $keepDaysArg = [string]$Args[++$i] }; continue }
        '^--?(DryRun|dry-run)$' { if ($i + 1 -lt $Args.Count) { $dryRunArg = [string]$Args[++$i] }; continue }
        '^--?(Aggressive|aggressive)$' { if ($i + 1 -lt $Args.Count) { $aggressiveArg = [string]$Args[++$i] }; continue }
        '^--?(CopySmokeArtifacts|copy-smoke-artifacts)$' { if ($i + 1 -lt $Args.Count) { $copySmokeArtifactsArg = [string]$Args[++$i] }; continue }
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

    for ($i = 0; $i -lt $Args.Count; $i++) {
      $token = [string]$Args[$i]
      switch -Regex ($token) {
        '^--?(WorkspaceRoot|workspace-root)$' { if ($i + 1 -lt $Args.Count) { $workspaceArg = [string]$Args[++$i] }; continue }
        '^--?(Reason|reason)$' { if ($i + 1 -lt $Args.Count) { $reasonArg = [string]$Args[++$i] }; continue }
        '^--?(Keep|keep)$' { if ($i + 1 -lt $Args.Count) { $keepArg = [string]$Args[++$i] }; continue }
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
    if ($Args) { $metricsArgLine = ($Args -join " ") }
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
        & bash ".\.Rayman\scripts\telemetry\rules_metrics.sh" @Args | Out-Host
      } else {
        Write-Host "[metrics] neither wsl.exe nor bash found."
      }
    }
    break
  }
  "trend" {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    $trendArgLine = ""
    if ($Args) { $trendArgLine = ($Args -join " ") }
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
        & bash ".\.Rayman\scripts\telemetry\daily_trend.sh" @Args | Out-Host
      } else {
        Write-Host "[trend] neither wsl.exe nor bash found."
      }
    }
    break
  }
  "baseline-guard" {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    $argLine = ""
    if ($Args) { $argLine = ($Args -join " ") }
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
        & bash ".\.Rayman\scripts\telemetry\baseline_guard.sh" @Args | Out-Host
      } else {
        Write-Host "[baseline-guard] neither wsl.exe nor bash found."
      }
    }
    break
  }
  "telemetry-export" {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    $argLine = ""
    if ($Args) { $argLine = ($Args -join " ") }
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
        & bash ".\.Rayman\scripts\telemetry\export_artifacts.sh" @Args | Out-Host
      } else {
        Write-Host "[telemetry-export] neither wsl.exe nor bash found."
      }
    }
    break
  }
  "telemetry-index" {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    $argLine = ""
    if ($Args) { $argLine = ($Args -join " ") }
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
        & bash ".\.Rayman\scripts\telemetry\index_artifacts.sh" @Args | Out-Host
      } else {
        Write-Host "[telemetry-index] neither wsl.exe nor bash found."
      }
    }
    break
  }
  "telemetry-prune" {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    $argLine = ""
    if ($Args) { $argLine = ($Args -join " ") }
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
        & bash ".\.Rayman\scripts\telemetry\prune_artifacts.sh" @Args | Out-Host
      } else {
        Write-Host "[telemetry-prune] neither wsl.exe nor bash found."
      }
    }
    break
  }
  "deploy" { & "$PSScriptRoot\scripts\deploy\deploy.ps1" @Args; break }
  "cache-clear" { & "$PSScriptRoot\scripts\utils\clear_cache.ps1" @Args; break }
  "state-save" { & "$PSScriptRoot\scripts\state\save_state.ps1" @Args; break }
  "state-resume" { & "$PSScriptRoot\scripts\state\resume_state.ps1" @Args; break }
  "test-fix" { & "$PSScriptRoot\scripts\repair\run_tests_and_fix.ps1" @Args; break }
  "req-ts-backfill" { & "$PSScriptRoot\scripts\requirements\backfill_requirements_timestamps.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @Args; break }
  "dist-sync" { & "$PSScriptRoot\scripts\release\sync_dist_from_src.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path -Validate; break }
  "diagnostics-residual" { & "$PSScriptRoot\scripts\utils\diagnose_residual_diagnostics.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @Args; break }
  "release-gate" {
    $releaseParams = @{ WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path }
    for ($i = 0; $i -lt $Args.Count; $i++) {
      $token = [string]$Args[$i]
      switch -Regex ($token) {
        '^--?(WorkspaceRoot|workspace-root)$' { if ($i + 1 -lt $Args.Count) { $releaseParams['WorkspaceRoot'] = [string]$Args[++$i] }; continue }
        '^--?(ReportPath|report-path)$' { if ($i + 1 -lt $Args.Count) { $releaseParams['ReportPath'] = [string]$Args[++$i] }; continue }
        '^--?(Mode|mode)$' { if ($i + 1 -lt $Args.Count) { $releaseParams['Mode'] = [string]$Args[++$i] }; continue }
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
    exit $releaseExitCode
  }
  "release" {
    $releaseParams = @{ WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path }
    for ($i = 0; $i -lt $Args.Count; $i++) {
      $token = [string]$Args[$i]
      switch -Regex ($token) {
        '^--?(WorkspaceRoot|workspace-root)$' { if ($i + 1 -lt $Args.Count) { $releaseParams['WorkspaceRoot'] = [string]$Args[++$i] }; continue }
        '^--?(ReportPath|report-path)$' { if ($i + 1 -lt $Args.Count) { $releaseParams['ReportPath'] = [string]$Args[++$i] }; continue }
        '^--?(Mode|mode)$' { if ($i + 1 -lt $Args.Count) { $releaseParams['Mode'] = [string]$Args[++$i] }; continue }
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
    exit $releaseExitCode
  }
  "package-dist" { & "$PSScriptRoot\scripts\release\package_distributable.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @Args; break }
  "package" { & "$PSScriptRoot\scripts\release\package_distributable.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @Args; break }
  "context-update" { & "$PSScriptRoot\scripts\utils\generate_context.ps1" @Args; break }
  "health-check" { & "$PSScriptRoot\scripts\watch\daily_health_check.ps1" @Args; break }
  "proxy-health" {
    $proxyArgs = @()
    foreach ($a in $Args) {
      if ([string]::IsNullOrWhiteSpace([string]$a)) { $proxyArgs += $a; continue }
      if ([string]$a -match '^--(.+)$') {
        $proxyArgs += ('-' + $Matches[1])
      } else {
        $proxyArgs += $a
      }
    }
    $forward = Normalize-RaymanForwardArgs -InputArgs $proxyArgs -KnownParamNames @('WorkspaceRoot', 'Refresh', 'AsJson')
    & "$PSScriptRoot\scripts\proxy\proxy_health_check.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @forward
    break
  }
  "proxy-check" {
    $proxyArgs = @()
    foreach ($a in $Args) {
      if ([string]::IsNullOrWhiteSpace([string]$a)) { $proxyArgs += $a; continue }
      if ([string]$a -match '^--(.+)$') {
        $proxyArgs += ('-' + $Matches[1])
      } else {
        $proxyArgs += $a
      }
    }
    $forward = Normalize-RaymanForwardArgs -InputArgs $proxyArgs -KnownParamNames @('WorkspaceRoot', 'Refresh', 'AsJson')
    & "$PSScriptRoot\scripts\proxy\proxy_health_check.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @forward
    break
  }
  "ensure-wsl-deps" { & "$PSScriptRoot\scripts\utils\ensure_wsl_deps.ps1" @Args; break }
  "ensure-win-deps" { & "$PSScriptRoot\scripts\utils\ensure_win_deps.ps1" @Args; break }
  "dispatch" { & "$PSScriptRoot\scripts\agents\dispatch.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @Args; break }
  "review-loop" { & "$PSScriptRoot\scripts\agents\review_loop.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @Args; break }
  "first-pass-report" { & "$PSScriptRoot\scripts\agents\first_pass_report.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @Args; break }
  "single-repo-upgrade" {
    $upgradeParams = @{ WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path }
    for ($i = 0; $i -lt $Args.Count; $i++) {
      $token = [string]$Args[$i]
      switch -Regex ($token) {
        '^--?(WorkspaceRoot|workspace-root)$' { if ($i + 1 -lt $Args.Count) { $upgradeParams['WorkspaceRoot'] = [string]$Args[++$i] }; continue }
        '^--?(Task|task)$' { if ($i + 1 -lt $Args.Count) { $upgradeParams['Task'] = [string]$Args[++$i] }; continue }
        '^--?(TaskKind|task-kind)$' { if ($i + 1 -lt $Args.Count) { $upgradeParams['TaskKind'] = [string]$Args[++$i] }; continue }
        '^--?(PreferredBackend|preferred-backend)$' { if ($i + 1 -lt $Args.Count) { $upgradeParams['PreferredBackend'] = [string]$Args[++$i] }; continue }
        '^--?(AutoResetCircuit|auto-reset-circuit)$' {
          if ($i + 1 -lt $Args.Count -and -not ([string]$Args[$i + 1]).StartsWith('-')) {
            $upgradeParams['AutoResetCircuit'] = [string]$Args[++$i]
          } else {
            $upgradeParams['AutoResetCircuit'] = '1'
          }
          continue
        }
        '^--?(NoAutoResetCircuit|no-auto-reset-circuit)$' { $upgradeParams['AutoResetCircuit'] = '0'; continue }
        '^--?(RiskMode|risk-mode)$' { if ($i + 1 -lt $Args.Count) { $upgradeParams['RiskMode'] = [string]$Args[++$i] }; continue }
        '^--?(BypassReason|bypass-reason)$' { if ($i + 1 -lt $Args.Count) { $upgradeParams['BypassReason'] = [string]$Args[++$i] }; continue }
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
    for ($i = 0; $i -lt $Args.Count; $i++) {
      $token = [string]$Args[$i]
      switch -Regex ($token) {
        '^--?(WorkspaceRoot|workspace-root)$' { if ($i + 1 -lt $Args.Count) { $kpiParams['WorkspaceRoot'] = [string]$Args[++$i] }; continue }
        '^--?(Window|window)$' { if ($i + 1 -lt $Args.Count) { $kpiParams['Window'] = [int][string]$Args[++$i] }; continue }
        '^--?(Json|json)$' { $kpiParams['Json'] = $true; continue }
      }
    }
    & "$PSScriptRoot\scripts\telemetry\single_repo_kpi.ps1" @kpiParams
    break
  }
  "prompts" { & "$PSScriptRoot\scripts\agents\prompts_catalog.ps1" -WorkspaceRoot (Resolve-Path (Join-Path $PSScriptRoot "..")).Path @Args; break }
  default { Write-Error "Unknown command: $Command"; exit 2 }
}
