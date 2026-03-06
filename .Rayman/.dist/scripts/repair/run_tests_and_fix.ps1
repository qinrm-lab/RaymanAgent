$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path

# 导入核心模块
$CoreModulePath = Join-Path $PSScriptRoot "..\core\Rayman-Core.psm1"
if (Test-Path $CoreModulePath) {
    Import-Module $CoreModulePath -Force
}

function Get-EnvInt([string]$Name, [int]$Default) {
    $raw = [Environment]::GetEnvironmentVariable($Name)
    $val = 0
    if (-not [string]::IsNullOrWhiteSpace($raw) -and [int]::TryParse($raw, [ref]$val)) { return $val }
    return $Default
}

function Get-EnvString([string]$Name, [string]$Default) {
    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    return $raw
}

function Get-EnvBoolCompat([string]$Name, [bool]$Default) {
    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    return ($raw -ne '0' -and $raw -ne 'false' -and $raw -ne 'False')
}

function Set-LastExitCodeCompat([int]$Value) {
    try { Set-Variable -Name 'LASTEXITCODE' -Scope Global -Value $Value -Force } catch {}
    try { Set-Variable -Name 'LASTEXITCODE' -Scope Script -Value $Value -Force } catch {}
}

function Test-IsWindowsPlatformCompat {
    try {
        return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    } catch {
        return $false
    }
}

function Escape-PsSingleQuoted([string]$Value) {
    if ($null -eq $Value) { return '' }
    return $Value.Replace("'", "''")
}

function Resolve-DotNetWindowsBridge {
    param([string]$WorkspaceRoot)

    $result = [ordered]@{
        available = $false
        reason = ''
        powershell_path = ''
        workspace_windows = ''
    }

    if (Test-IsWindowsPlatformCompat) {
        $result.reason = 'already_windows_host'
        return [pscustomobject]$result
    }

    $psExe = Get-Command 'powershell.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $psExe -or [string]::IsNullOrWhiteSpace([string]$psExe.Source)) {
        $result.reason = 'powershell.exe_not_found'
        return [pscustomobject]$result
    }

    $wslPathCmd = Get-Command 'wslpath' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $wslPathCmd -or [string]::IsNullOrWhiteSpace([string]$wslPathCmd.Source)) {
        $result.reason = 'wslpath_not_found'
        return [pscustomobject]$result
    }

    if ($WorkspaceRoot -notmatch '^/mnt/[A-Za-z]/') {
        $result.reason = 'workspace_not_on_windows_drive'
        return [pscustomobject]$result
    }

    $workspaceWin = ''
    try {
        $workspaceWin = (& $wslPathCmd.Source -w $WorkspaceRoot | Select-Object -First 1)
        $workspaceWin = [string]$workspaceWin
    } catch {
        $workspaceWin = ''
    }
    if ([string]::IsNullOrWhiteSpace($workspaceWin)) {
        $result.reason = 'workspace_wslpath_conversion_failed'
        return [pscustomobject]$result
    }

    $result.available = $true
    $result.reason = 'ok'
    $result.powershell_path = [string]$psExe.Source
    $result.workspace_windows = $workspaceWin.Trim()
    return [pscustomobject]$result
}

function Test-CanUseWindowsDotNetFromCurrentHost([object]$BridgeContext) {
    if ($null -eq $BridgeContext) { return $false }
    if (-not $BridgeContext.PSObject.Properties['available']) { return $false }
    return [bool]$BridgeContext.available
}

function Write-DotNetExecDetail {
    param(
        [string]$LogPath,
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($LogPath)) { return }
    try {
        $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message
        Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value $line
    } catch {}
}

function Save-DotNetExecSummary {
    param(
        [string]$SummaryPath,
        [hashtable]$Summary
    )

    if ([string]::IsNullOrWhiteSpace($SummaryPath) -or $null -eq $Summary) { return }
    try {
        ($Summary | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $SummaryPath -Encoding UTF8
    } catch {}
}

function Invoke-ProcessWithTimeout {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [int]$TimeoutSeconds
    )

    $result = [ordered]@{
        exit_code = 1
        timed_out = $false
        output_lines = @()
        error_message = ''
    }

    $stdoutPath = ''
    $stderrPath = ''

    try {
        $stdoutPath = [System.IO.Path]::GetTempFileName()
        $stderrPath = [System.IO.Path]::GetTempFileName()

        $proc = Start-Process -FilePath $FilePath `
            -ArgumentList @($ArgumentList) `
            -PassThru `
            -NoNewWindow `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath

        if ($TimeoutSeconds -gt 0) {
            $waited = $proc.WaitForExit($TimeoutSeconds * 1000)
            if (-not $waited) {
                $result.timed_out = $true
                try { $proc.Kill() } catch {}
                try { $proc.WaitForExit() } catch {}
                $result.exit_code = 124
            } else {
                $result.exit_code = [int]$proc.ExitCode
            }
        } else {
            $proc.WaitForExit()
            $result.exit_code = [int]$proc.ExitCode
        }

        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($file in @($stdoutPath, $stderrPath)) {
            if ([string]::IsNullOrWhiteSpace($file) -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
            foreach ($line in (Get-Content -LiteralPath $file -Encoding UTF8 -ErrorAction SilentlyContinue)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
                    [void]$lines.Add([string]$line)
                }
            }
        }
        $result.output_lines = @($lines)
    } catch {
        $result.error_message = $_.Exception.Message
        if ($result.exit_code -eq 0) {
            $result.exit_code = 1
        }
    } finally {
        foreach ($tmp in @($stdoutPath, $stderrPath)) {
            if (-not [string]::IsNullOrWhiteSpace($tmp) -and (Test-Path -LiteralPath $tmp -PathType Leaf)) {
                try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
    }

    return [pscustomobject]$result
}

function Invoke-DotNetViaWindowsHost {
    param(
        [string]$Command,
        [object]$BridgeContext,
        [int]$TimeoutSeconds
    )

    $workspaceEscaped = Escape-PsSingleQuoted -Value ([string]$BridgeContext.workspace_windows)
    $commandEscaped = Escape-PsSingleQuoted -Value $Command

    $winCommandTemplate = @'
$ErrorActionPreference = 'Stop'
Set-Location '__WORKSPACE__'
$requested = '__COMMAND__'
$effective = $requested
if ($requested -match '^\s*dotnet(\s+.*)?$') {
  $suffix = if ($matches[1]) { $matches[1] } else { '' }
  $candidate = '.\.dotnet\dotnet.exe'
  if (Test-Path -LiteralPath $candidate -PathType Leaf) {
    $effective = $candidate + $suffix
  }
}
Write-Output ('[dotnet-host][windows] requested={0}' -f $requested)
Write-Output ('[dotnet-host][windows] effective={0}' -f $effective)
Invoke-Expression $effective
exit $LASTEXITCODE
'@
    $winCommand = $winCommandTemplate.Replace('__WORKSPACE__', $workspaceEscaped).Replace('__COMMAND__', $commandEscaped)

    $processResult = Invoke-ProcessWithTimeout -FilePath ([string]$BridgeContext.powershell_path) -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        $winCommand
    ) -TimeoutSeconds $TimeoutSeconds

    return [pscustomobject]@{
        success = (($processResult.exit_code -eq 0) -and (-not $processResult.timed_out))
        exit_code = [int]$processResult.exit_code
        timed_out = [bool]$processResult.timed_out
        output_lines = @($processResult.output_lines)
        error_message = [string]$processResult.error_message
        invoked_via = [string]$BridgeContext.powershell_path
        workspace_windows = [string]$BridgeContext.workspace_windows
    }
}

function Invoke-RaymanCommand {
    param(
        [string]$Command,
        [bool]$UseSandboxEffective,
        [string]$SandboxScript,
        [string]$Kind = ''
    )

    if ($UseSandboxEffective -and (Test-Path -LiteralPath $SandboxScript -PathType Leaf)) {
        return & $SandboxScript -Command $Command 2>&1
    }

    if ($Kind -ne 'dotnet') {
        return Invoke-Expression $Command 2>&1
    }

    $windowsPreferred = Get-EnvBoolCompat -Name 'RAYMAN_DOTNET_WINDOWS_PREFERRED' -Default $true
    $windowsStrict = Get-EnvBoolCompat -Name 'RAYMAN_DOTNET_WINDOWS_STRICT' -Default $false
    $timeoutSeconds = Get-EnvInt -Name 'RAYMAN_DOTNET_WINDOWS_TIMEOUT_SECONDS' -Default 1800
    if ($timeoutSeconds -lt 30) { $timeoutSeconds = 30 }
    if ($timeoutSeconds -gt 7200) { $timeoutSeconds = 7200 }

    $bridgeContext = Resolve-DotNetWindowsBridge -WorkspaceRoot $WorkspaceRoot
    $canBridge = Test-CanUseWindowsDotNetFromCurrentHost -BridgeContext $bridgeContext
    $isWindowsHost = Test-IsWindowsPlatformCompat

    $summary = [ordered]@{
        schema = 'rayman.dotnet.exec.v1'
        generated_at = (Get-Date).ToString('o')
        workspace_root = $WorkspaceRoot
        requested_command = $Command
        selected_host = ''
        fallback_host = ''
        success = $false
        final_exit_code = 1
        windows_exit_code = $null
        wsl_exit_code = $null
        windows_timed_out = $false
        windows_error_message = ''
        windows_invoked_via = ''
        windows_workspace = ''
        strict_mode = $windowsStrict
        windows_preferred = $windowsPreferred
        timeout_seconds = $timeoutSeconds
        host_is_windows = $isWindowsHost
        can_use_windows_bridge = $canBridge
        bridge_reason = [string]$bridgeContext.reason
        reason = ''
        error_message = ''
        detail_log = $script:DotNetExecDetailPath
    }

    $out = New-Object System.Collections.Generic.List[object]
    $windowsOut = @()
    $finalExit = 1

    Write-DotNetExecDetail -LogPath $script:DotNetExecDetailPath -Message ("dotnet strategy command='{0}' preferred={1} strict={2} hostIsWindows={3} canBridge={4} bridgeReason={5}" -f $Command, $windowsPreferred, $windowsStrict, $isWindowsHost, $canBridge, [string]$bridgeContext.reason)

    if ($isWindowsHost) {
        $summary.selected_host = 'windows-native'
        $nativeOut = Invoke-Expression $Command 2>&1
        $finalExit = [int]$LASTEXITCODE
        $summary.windows_exit_code = $finalExit
        $summary.reason = 'native_windows_host'
        $out.AddRange(@($nativeOut))
    } elseif (-not $windowsPreferred) {
        $summary.selected_host = 'wsl'
        $wslOut = Invoke-Expression $Command 2>&1
        $finalExit = [int]$LASTEXITCODE
        $summary.wsl_exit_code = $finalExit
        $summary.reason = 'windows_preferred_disabled'
        $out.AddRange(@($wslOut))
    } elseif (-not $canBridge) {
        $summary.selected_host = 'wsl'
        $wslOut = Invoke-Expression $Command 2>&1
        $finalExit = [int]$LASTEXITCODE
        $summary.wsl_exit_code = $finalExit
        $summary.reason = ('windows_bridge_unavailable:{0}' -f [string]$bridgeContext.reason)
        $out.AddRange(@($wslOut))
    } else {
        $summary.selected_host = 'windows-bridge'
        $win = Invoke-DotNetViaWindowsHost -Command $Command -BridgeContext $bridgeContext -TimeoutSeconds $timeoutSeconds
        $windowsOut = @($win.output_lines)
        $summary.windows_exit_code = [int]$win.exit_code
        $summary.windows_timed_out = [bool]$win.timed_out
        $summary.windows_error_message = [string]$win.error_message
        $summary.windows_invoked_via = [string]$win.invoked_via
        $summary.windows_workspace = [string]$win.workspace_windows
        Write-DotNetExecDetail -LogPath $script:DotNetExecDetailPath -Message ("windows bridge exit={0} timeout={1} via={2}" -f [int]$win.exit_code, [bool]$win.timed_out, [string]$win.invoked_via)
        if ($win.success) {
            $finalExit = [int]$win.exit_code
            $summary.reason = 'windows_bridge_success'
            $out.AddRange(@($windowsOut))
        } elseif ($windowsStrict) {
            $finalExit = [int]$win.exit_code
            $summary.reason = if ($win.timed_out) { 'windows_bridge_timeout_strict' } else { 'windows_bridge_failed_strict' }
            $summary.error_message = if ($win.timed_out) {
                ("windows dotnet execution timed out after {0}s" -f $timeoutSeconds)
            } else {
                [string]$win.error_message
            }
            $out.AddRange(@($windowsOut))
        } else {
            $summary.fallback_host = 'wsl'
            $summary.reason = if ($win.timed_out) { 'windows_bridge_timeout_fallback_wsl' } else { 'windows_bridge_failed_fallback_wsl' }
            $warnLine = "[dotnet-host] windows execution failed (exit=$($win.exit_code)); fallback to WSL command"
            Write-Host "⚠️  $warnLine" -ForegroundColor Yellow
            $out.AddRange(@($windowsOut))
            $out.Add($warnLine) | Out-Null
            $wslOut = Invoke-Expression $Command 2>&1
            $finalExit = [int]$LASTEXITCODE
            $summary.wsl_exit_code = $finalExit
            $out.AddRange(@($wslOut))
        }
    }

    Set-LastExitCodeCompat -Value $finalExit
    $summary.success = ($finalExit -eq 0)
    $summary.final_exit_code = $finalExit
    Save-DotNetExecSummary -SummaryPath $script:DotNetExecSummaryPath -Summary $summary
    Write-DotNetExecDetail -LogPath $script:DotNetExecDetailPath -Message ("dotnet strategy result selected={0} fallback={1} final_exit={2} windows_exit={3} wsl_exit={4} reason={5}" -f [string]$summary.selected_host, [string]$summary.fallback_host, $finalExit, [string]$summary.windows_exit_code, [string]$summary.wsl_exit_code, [string]$summary.reason)

    return $out.ToArray()
}

function Get-FileRefsFromLines {
    param([string[]]$Lines)

    $exts = 'cs|csproj|sln|ts|tsx|js|jsx|py|ps1|sh|json|yml|yaml|md'
    $patterns = @(
        "(?<path>[A-Za-z]:\\\\[^:\r\n]+?\\.(?:$exts))(?::(?<line>\d+))?",
        "(?<path>(?:\./|\.\./|\.\\|\.\\\\|[^\s:]+/)[^:\r\n]+?\\.(?:$exts))(?::(?<line>\d+))?"
    )

    $found = New-Object System.Collections.Generic.List[string]
    foreach ($ln in $Lines) {
        foreach ($pat in $patterns) {
            $m = [regex]::Matches($ln, $pat)
            foreach ($mm in $m) {
                $p = $mm.Groups['path'].Value
                $l = $mm.Groups['line'].Value
                if (-not [string]::IsNullOrWhiteSpace($p)) {
                    if (-not [string]::IsNullOrWhiteSpace($l)) { $found.Add("$p`:$l") } else { $found.Add($p) }
                }
            }
        }
    }
    return $found | Select-Object -Unique
}

# 1. 触发成本熔断器检查 (每次运行算作 1 次循环)
$CircuitBreakerScript = Join-Path $WorkspaceRoot ".Rayman\scripts\utils\circuit_breaker.ps1"
if (Test-Path $CircuitBreakerScript) {
    Write-Host "🛡️ [Circuit Breaker] 检查执行预算..." -ForegroundColor Cyan
    & $CircuitBreakerScript -AddLoops 1
}

Write-Host "🔍 开始自动检测并运行测试/构建 (Self-Healing)..." -ForegroundColor Cyan

$StateDir = Join-Path $WorkspaceRoot ".Rayman\state"
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }
$RuntimeDir = Join-Path $WorkspaceRoot ".Rayman\runtime"
if (-not (Test-Path $RuntimeDir)) { New-Item -ItemType Directory -Path $RuntimeDir | Out-Null }
$LogsDir = Join-Path $WorkspaceRoot ".Rayman\logs"
if (-not (Test-Path $LogsDir)) { New-Item -ItemType Directory -Path $LogsDir | Out-Null }

$script:DotNetExecSummaryPath = Join-Path $RuntimeDir 'dotnet.exec.last.json'
$script:DotNetExecDetailPath = Join-Path $LogsDir ("dotnet.exec.{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

$LogFile = Join-Path $StateDir "last_error.log"
$ErrorFound = $false

# 检查是否启用了 Docker 沙箱模式（默认关闭，仅在显式开启时启用）
$UseSandbox = Get-EnvBoolCompat -Name 'RAYMAN_USE_SANDBOX' -Default $false
$SandboxScript = Join-Path $WorkspaceRoot ".Rayman\scripts\sandbox\run_in_sandbox.ps1"

# 沙箱只有在 docker 可用时才算有效，否则会造成“本该跑测试却直接失败”的误报
$dockerOk = $null -ne (Get-Command docker -ErrorAction SilentlyContinue)
$UseSandboxEffective = ($UseSandbox -and $dockerOk -and (Test-Path -LiteralPath $SandboxScript -PathType Leaf))

Set-Location $WorkspaceRoot

$MaxAttempts = Get-EnvInt -Name 'RAYMAN_SELF_HEAL_MAX_ATTEMPTS' -Default 2
if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
if ($MaxAttempts -gt 5) { $MaxAttempts = 5 }

$FixLog = New-Object System.Collections.Generic.List[string]
$CommandLog = New-Object System.Collections.Generic.List[string]

function Try-CommonFixes {
    param(
        [string]$Kind,
        [string[]]$OutputLines
    )

    $did = $false
    $autoDep = Get-EnvBoolCompat -Name 'RAYMAN_SELF_HEAL_AUTO_DEP_INSTALL' -Default $true

    if (-not $autoDep) {
        return $false
    }

    $text = ($OutputLines -join "`n")

    if ($Kind -eq 'dotnet') {
        if ($text -match 'assets file.*not found|Run a NuGet package restore|NU1\d\d\d|NU2\d\d\d|NU3\d\d\d') {
            Write-Host "🛠️  [Self-Heal] 尝试 dotnet restore ..." -ForegroundColor Yellow
            $FixLog.Add('dotnet restore')
            $null = Invoke-RaymanCommand -Command 'dotnet restore' -UseSandboxEffective $false -SandboxScript $SandboxScript -Kind 'dotnet'
            $did = $true
        }
    } elseif ($Kind -eq 'node') {
        if ($text -match 'Cannot find module|ERR! code MODULE_NOT_FOUND|npm ERR!|ELIFECYCLE') {
            $lock = Test-Path -LiteralPath (Join-Path $WorkspaceRoot 'package-lock.json') -PathType Leaf
            $cmd = 'npm install'
            if ($lock) { $cmd = 'npm ci' }
            Write-Host "🛠️  [Self-Heal] 尝试 $cmd ..." -ForegroundColor Yellow
            $FixLog.Add($cmd)
            $null = Invoke-RaymanCommand -Command $cmd -UseSandboxEffective $false -SandboxScript $SandboxScript -Kind 'node'
            $did = $true
        }
    } elseif ($Kind -eq 'python') {
        $py = Get-EnvString -Name 'RAYMAN_PYTHON' -Default 'python'
        if (-not (Get-Command $py -ErrorAction SilentlyContinue)) { $py = 'python' }
        if ($text -match 'No module named pytest|ModuleNotFoundError:.*pytest') {
            Write-Host "🛠️  [Self-Heal] 安装 pytest ..." -ForegroundColor Yellow
            $FixLog.Add("$py -m pip install pytest")
            $null = & $py -m pip install pytest 2>&1
            $did = $true
        }
        if ((Test-Path -LiteralPath (Join-Path $WorkspaceRoot 'requirements.txt') -PathType Leaf) -and ($text -match 'ModuleNotFoundError: No module named|ImportError')) {
            Write-Host "🛠️  [Self-Heal] 安装 requirements.txt 依赖 ..." -ForegroundColor Yellow
            $FixLog.Add("$py -m pip install -r requirements.txt")
            $null = & $py -m pip install -r (Join-Path $WorkspaceRoot 'requirements.txt') 2>&1
            $did = $true
        }
    } elseif ($Kind -eq 'rayman') {
        $text = ($OutputLines -join "`n")
        $repairScript = Join-Path $WorkspaceRoot '.Rayman\scripts\repair\ensure_complete_rayman.ps1'
        $syncScript = Join-Path $WorkspaceRoot '.Rayman\scripts\release\sync_dist_from_src.ps1'

        if ($text -match 'source missing:|source missing|缺少内置修复包|缺少') {
            if (Test-Path -LiteralPath $repairScript -PathType Leaf) {
                Write-Host "🛠️  [Self-Heal] 尝试修复 Rayman 缺失文件 (ensure_complete_rayman.ps1) ..." -ForegroundColor Yellow
                $FixLog.Add('ensure_complete_rayman.ps1')
                $null = & $repairScript -Root $WorkspaceRoot 2>&1
                $did = $true
            }
        }

        if ($text -match 'dist missing:|dist missing|\.Rayman/\.dist 漂移|dist-drift|漂移') {
            if (Test-Path -LiteralPath $syncScript -PathType Leaf) {
                Write-Host "🛠️  [Self-Heal] 尝试同步 .Rayman/.dist (sync_dist_from_src.ps1) ..." -ForegroundColor Yellow
                $FixLog.Add('sync_dist_from_src.ps1 -Validate')
                $null = & $syncScript -WorkspaceRoot $WorkspaceRoot -Validate 2>&1
                $did = $true
            }
        }
    }

    return $did
}

function Get-PrimaryCommand {
    if (Get-ChildItem -Path $WorkspaceRoot -Filter "*.sln" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1) {
        $prefer = Get-EnvString -Name 'RAYMAN_DOTNET_PRIMARY' -Default ''
        if ($prefer -eq 'build') { return @{ Kind='dotnet'; Command='dotnet build' } }
        if ($prefer -eq 'test') { return @{ Kind='dotnet'; Command='dotnet test' } }

        $hasTests = $false
        try {
            if (Get-ChildItem -Path $WorkspaceRoot -Filter '*Tests*.csproj' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1) {
                $hasTests = $true
            }
        } catch {}
        if ($hasTests) { return @{ Kind='dotnet'; Command='dotnet test' } }
        return @{ Kind='dotnet'; Command='dotnet build' }
    }

    $pkgPath = Join-Path $WorkspaceRoot 'package.json'
    if (Test-Path -LiteralPath $pkgPath -PathType Leaf) {
        try {
            $pkg = Get-Content -LiteralPath $pkgPath -Raw -ErrorAction Stop | ConvertFrom-Json
            $scripts = $pkg.scripts
            if ($null -ne $scripts -and ($scripts.PSObject.Properties.Name -contains 'test')) {
                return @{ Kind='node'; Command='npm test' }
            }
            if ($null -ne $scripts -and ($scripts.PSObject.Properties.Name -contains 'build')) {
                return @{ Kind='node'; Command='npm run build' }
            }
        } catch {}
        return @{ Kind='node'; Command='npm run build' }
    }

    if ((Test-Path -LiteralPath (Join-Path $WorkspaceRoot 'requirements.txt') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $WorkspaceRoot 'pyproject.toml') -PathType Leaf)) {
        $py = Get-EnvString -Name 'RAYMAN_PYTHON' -Default 'python'
        if (-not (Get-Command $py -ErrorAction SilentlyContinue)) { $py = 'python' }
        return @{ Kind='python'; Command="$py -m pytest" }
    }

    # Rayman/RaymanAgent 自检（脚本仓库没有 sln/package.json/requirements 的情况下也要能跑）
    $raymanDir = Join-Path $WorkspaceRoot '.Rayman'
    $assert = Join-Path $raymanDir 'scripts\release\assert_dist_sync.ps1'
    $dist = Join-Path $raymanDir '.dist'
    if ((Test-Path -LiteralPath $assert -PathType Leaf) -and (Test-Path -LiteralPath $dist -PathType Container)) {
        # 直接调用脚本，避免在 WSL/Linux 下依赖 powershell(.exe) 命令名。
        $assertEscaped = $assert.Replace("'", "''")
        $workspaceEscaped = $WorkspaceRoot.Replace("'", "''")
        $cmd = "& '" + $assertEscaped + "' -WorkspaceRoot '" + $workspaceEscaped + "'"
        return @{ Kind='rayman'; Command=$cmd }
    }

    return $null
}

$primary = Get-PrimaryCommand
if ($null -eq $primary) {
    Write-Host "⚠️ 未识别的项目类型，无法自动运行测试。" -ForegroundColor Yellow
    exit 0
}

$depsScript = Join-Path $WorkspaceRoot ".Rayman\scripts\utils\ensure_project_test_deps.ps1"
$depsScriptSh = Join-Path $WorkspaceRoot ".Rayman/scripts/utils/ensure_project_test_deps.sh"
$autoInstallTestDeps = Get-EnvBoolCompat -Name 'RAYMAN_AUTO_INSTALL_TEST_DEPS' -Default $true
$requireTestDeps = Get-EnvBoolCompat -Name 'RAYMAN_REQUIRE_TEST_DEPS' -Default $true
$depsOnlyKinds = ''
switch ([string]$primary.Kind) {
    'dotnet' { $depsOnlyKinds = 'dotnet' }
    'node' { $depsOnlyKinds = 'node' }
    'python' { $depsOnlyKinds = 'python' }
    default { $depsOnlyKinds = '' }
}

if ((Test-Path -LiteralPath $depsScript -PathType Leaf) -or (Test-Path -LiteralPath $depsScriptSh -PathType Leaf)) {
    $depsScopeText = if ([string]::IsNullOrWhiteSpace($depsOnlyKinds)) { 'all' } else { $depsOnlyKinds }
    Write-Host ("🧩 [Self-Heal] 检查测试依赖（autoInstall={0}, require={1}, onlyKinds={2}）..." -f $autoInstallTestDeps, $requireTestDeps, $depsScopeText) -ForegroundColor Cyan

    $depsExitCode = 0
    $isWindowsHost = Test-IsWindowsPlatformCompat
    $canUseBash = $null -ne (Get-Command bash -ErrorAction SilentlyContinue)
    if ((-not $isWindowsHost) -and $canUseBash -and (Test-Path -LiteralPath $depsScriptSh -PathType Leaf)) {
        $autoInstallFlag = if ($autoInstallTestDeps) { '1' } else { '0' }
        $requireFlag = if ($requireTestDeps) { '1' } else { '0' }
        $depsArgs = @('--workspace-root', $WorkspaceRoot, '--auto-install', $autoInstallFlag, '--require', $requireFlag)
        if (-not [string]::IsNullOrWhiteSpace($depsOnlyKinds)) {
            $depsArgs += @('--only', $depsOnlyKinds)
        }
        Write-Host "ℹ️  [Self-Heal] WSL/Linux 环境优先执行 ensure_project_test_deps.sh（含 Windows bridge）" -ForegroundColor DarkCyan
        & bash $depsScriptSh @depsArgs | Out-Host
        $depsExitCode = [int]$LASTEXITCODE
    } elseif (Test-Path -LiteralPath $depsScript -PathType Leaf) {
        $callerHostType = if ($isWindowsHost) { 'windows-native' } else { 'pwsh' }
        $depsParams = @{
            WorkspaceRoot = $WorkspaceRoot
            AutoInstall = $autoInstallTestDeps
            Require = $requireTestDeps
            Caller = 'run_tests_and_fix.ps1'
            CallerHostType = $callerHostType
            CallerWorkspaceRoot = $WorkspaceRoot
        }
        if (-not [string]::IsNullOrWhiteSpace($depsOnlyKinds)) {
            $depsParams['OnlyKinds'] = $depsOnlyKinds
        }
        & $depsScript @depsParams | Out-Host
        $depsExitCode = [int]$LASTEXITCODE
    } elseif ($canUseBash -and (Test-Path -LiteralPath $depsScriptSh -PathType Leaf)) {
        $autoInstallFlag = if ($autoInstallTestDeps) { '1' } else { '0' }
        $requireFlag = if ($requireTestDeps) { '1' } else { '0' }
        $depsArgs = @('--workspace-root', $WorkspaceRoot, '--auto-install', $autoInstallFlag, '--require', $requireFlag)
        if (-not [string]::IsNullOrWhiteSpace($depsOnlyKinds)) {
            $depsArgs += @('--only', $depsOnlyKinds)
        }
        & bash $depsScriptSh @depsArgs | Out-Host
        $depsExitCode = [int]$LASTEXITCODE
    }

    if ($depsExitCode -ne 0) {
        $ErrorFound = $true
        $msg = "测试依赖未满足，请先安装缺失 SDK。"
        Set-Content -LiteralPath $LogFile -Value $msg -Encoding UTF8
        Write-Host ("❌ {0}" -f $msg) -ForegroundColor Red
        exit 1
    }
}

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    Write-Host ("▶️ 检测到 {0} 项目，执行: {1} (attempt {2}/{3})" -f $primary.Kind, $primary.Command, $attempt, $MaxAttempts) -ForegroundColor Cyan
    $CommandLog.Add($primary.Command)

    $output = Invoke-RaymanCommand -Command $primary.Command -UseSandboxEffective $UseSandboxEffective -SandboxScript $SandboxScript -Kind $primary.Kind
    $exit = $LASTEXITCODE
    $outLines = @($output)

    if ($exit -eq 0) {
        $ErrorFound = $false
        break
    }

    $ErrorFound = $true
    $outLines | Out-File $LogFile -Encoding UTF8

    if ($attempt -lt $MaxAttempts) {
        $didFix = Try-CommonFixes -Kind $primary.Kind -OutputLines $outLines
        if (-not $didFix) {
            Write-Host "ℹ️  [Self-Heal] 未命中可自动修复的常见模式，停止重试。" -ForegroundColor Cyan
            break
        }
        # 修复后继续重跑
        continue
    }
}

if ($ErrorFound) {
    Write-Host "❌ 发现错误！日志已保存至 $LogFile" -ForegroundColor Red
    # 额外生成一个便于贴到聊天里的摘要
    try {
        $summaryFile = Join-Path $StateDir "last_error_summary.md"
        $tail = Get-Content -LiteralPath $LogFile -ErrorAction SilentlyContinue | Select-Object -Last 200
        $refs = Get-FileRefsFromLines -Lines $tail
        $refsBlock = ''
        if ($refs -and $refs.Count -gt 0) {
            $refsLines = @(
                '',
                '## 🔗 可能相关的文件引用 (从日志提取)',
                ''
            )
            $refsLines += ($refs | Select-Object -First 30 | ForEach-Object { '- `' + $_ + '`' })
            if ($refs.Count -gt 30) { $refsLines += '- ...' }
            $refsBlock = ($refsLines -join "`r`n")
        }
        
        # 2. 尝试使用 RAG 搜索相关错误解决方案
        $RagScript = Join-Path $WorkspaceRoot ".Rayman\scripts\rag\manage_rag.ps1"
        $RagContext = ""
        if (Test-Path $RagScript) {
            Write-Host "🧠 [RAG] 正在搜索历史记忆库以寻找解决方案..." -ForegroundColor Cyan
            # 提取最后若干行错误信息作为查询词
            $QueryText = ($tail | Select-Object -Last 20) -join " "
            if (-not [string]::IsNullOrWhiteSpace($QueryText)) {
                # 截断查询词，避免过长
                if ($QueryText.Length -gt 400) { $QueryText = $QueryText.Substring(0, 400) }
                $RagResult = & $RagScript -Action search -Query $QueryText -TopK 8 2>&1
                if ($RagResult) {
                    $ragFetchedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
                    $ragFetchedUnix = [DateTimeOffset]::Now.ToUnixTimeSeconds()
                    $ragLines = @(
                        '',
                        '## 🧠 RAG 记忆库相关参考',
                        "- fetched_at_iso: $ragFetchedAt",
                        "- fetched_at_unix: $ragFetchedUnix",
                        '',
                        '```text',
                        ($RagResult -join "`r`n"),
                        '```'
                    )
                    $RagContext = ($ragLines -join "`r`n")
                }
            }
        }

        $fixBlock = ""
        if ($FixLog.Count -gt 0) {
            $fixLines = @(
                '',
                '## 🛠️ 已尝试的自动修复步骤',
                ''
            )
            $fixLines += ($FixLog | Select-Object -Unique | ForEach-Object { '- `' + $_ + '`' })
            $fixBlock = ($fixLines -join "`r`n")
        }

        $cmdBlock = ""
        if ($CommandLog.Count -gt 0) {
            $cmdLines = @(
                '',
                '## ▶️ 已执行的主命令',
                ''
            )
            $cmdLines += ($CommandLog | Select-Object -Unique | ForEach-Object { '- `' + $_ + '`' })
            $cmdBlock = ($cmdLines -join "`r`n")
        }

        $mdLines = @(
            '# Rayman 错误摘要',
            '',
            "**时间**: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
            '',
            "**工作区**: $WorkspaceRoot",
            "**沙箱**: $UseSandboxEffective",
            '## ❌ 错误日志',
            '```text',
            ($tail -join "`r`n"),
            '```',
            $cmdBlock,
            $fixBlock,
            $refsBlock,
            $RagContext,
            '',
            '---',
            '',
            '如需更完整上下文，请先运行：`.Rayman/scripts/utils/generate_context.ps1`（或使用命令：更新上下文）'
        )
        $md = ($mdLines -join "`r`n")
        Set-Content -LiteralPath $summaryFile -Value $md -Encoding UTF8
        Write-Host "📄 已生成错误摘要 (含 RAG 上下文): $summaryFile" -ForegroundColor Yellow
    } catch {
        Write-Host "⚠️ 生成错误摘要失败: $_" -ForegroundColor Yellow
    }
    & "$PSScriptRoot\..\utils\request_attention.ps1" -Message "构建或测试失败，请让 AI 查看错误日志"
    
    if (Get-Command Throw-RaymanError -ErrorAction SilentlyContinue) {
        Throw-RaymanError -Message "构建或测试失败，请查看 $summaryFile" -ErrorCodeName 'ERR_VALIDATION' -Component 'SelfHeal'
    } else {
        exit 1
    }
} else {
    Write-Host "✅ 所有检查通过！" -ForegroundColor Green
    if (Test-Path $LogFile) { Remove-Item $LogFile -Force }
    & "$PSScriptRoot\..\utils\request_attention.ps1" -Message "项目编译和测试通过"
    exit 0
}
