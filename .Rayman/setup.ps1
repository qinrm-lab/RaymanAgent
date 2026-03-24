param(
    [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\.." | Select-Object -ExpandProperty Path),
    [switch]$SkipReleaseGate,
    [switch]$ForceReindex,
    [switch]$SelfCheck,
    [switch]$StrictCheck
)

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$raymanCommonPath = Join-Path $PSScriptRoot "common.ps1"
$raymanCommonImported = $false
$workspaceOwnershipPath = Join-Path $PSScriptRoot 'scripts\utils\workspace_process_ownership.ps1'
$workspaceOwnershipImported = $false
$workspaceStateGuardResult = $null
$workspaceStateGuardError = ''
$workspaceStateGuardScript = Join-Path $PSScriptRoot 'scripts\utils\workspace_state_guard.ps1'
$script:RaymanSetupVsCodeBaseline = @()
$script:RaymanSetupVsCodeOwnerContext = $null
$script:RaymanSetupVsCodeFinalized = $false
$script:RaymanSetupVsCodeReport = $null

if (Test-Path -LiteralPath $raymanCommonPath -PathType Leaf) {
    . $raymanCommonPath
    $raymanCommonImported = $true
}
if (Test-Path -LiteralPath $workspaceOwnershipPath -PathType Leaf) {
    . $workspaceOwnershipPath -NoMain
    $workspaceOwnershipImported = $true
}

if (Test-Path -LiteralPath $workspaceStateGuardScript -PathType Leaf) {
    try {
        $workspaceStateGuardJson = & $workspaceStateGuardScript -WorkspaceRoot $WorkspaceRoot -Json
        if (-not [string]::IsNullOrWhiteSpace([string]$workspaceStateGuardJson)) {
            if ($raymanCommonImported -and (Get-Command ConvertFrom-RaymanJsonText -ErrorAction SilentlyContinue)) {
                $workspaceStateGuardResult = ConvertFrom-RaymanJsonText -Text ([string]$workspaceStateGuardJson)
            } else {
                $workspaceStateGuardResult = $workspaceStateGuardJson | ConvertFrom-Json -ErrorAction Stop
            }
        }
    } catch {
        $workspaceStateGuardError = $_.Exception.Message
    }
} else {
    $workspaceStateGuardError = ("missing: {0}" -f $workspaceStateGuardScript)
}

if ($workspaceOwnershipImported -and (Get-Command Get-RaymanVsCodeProcessSnapshot -ErrorAction SilentlyContinue)) {
    try {
        $script:RaymanSetupVsCodeBaseline = @(Get-RaymanVsCodeProcessSnapshot -WorkspaceRootPath $WorkspaceRoot)
        $script:RaymanSetupVsCodeOwnerContext = Get-RaymanWorkspaceProcessOwnerContext -WorkspaceRootPath $WorkspaceRoot
    } catch {
        $script:RaymanSetupVsCodeBaseline = @()
        $script:RaymanSetupVsCodeOwnerContext = $null
        Write-Host ("⚠️ [VS Code] 初始化窗口基线采集失败: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Invoke-RaymanSetupFinalize {
    param(
        [int]$ExitCode = 0,
        [string]$Reason = 'setup'
    )

    if ($script:RaymanSetupVsCodeFinalized) {
        return $script:RaymanSetupVsCodeReport
    }
    $script:RaymanSetupVsCodeFinalized = $true

    if (-not $workspaceOwnershipImported -or -not (Get-Command Sync-RaymanWorkspaceVsCodeWindows -ErrorAction SilentlyContinue)) {
        return $null
    }

    try {
        if ($null -eq $script:RaymanSetupVsCodeOwnerContext) {
            $script:RaymanSetupVsCodeOwnerContext = Get-RaymanWorkspaceProcessOwnerContext -WorkspaceRootPath $WorkspaceRoot
        }
        $script:RaymanSetupVsCodeReport = Sync-RaymanWorkspaceVsCodeWindows `
            -WorkspaceRootPath $WorkspaceRoot `
            -BaselineSnapshot $script:RaymanSetupVsCodeBaseline `
            -WorkspaceRoots @($WorkspaceRoot) `
            -OwnerContext $script:RaymanSetupVsCodeOwnerContext `
            -CleanupOwned:($ExitCode -ne 0) `
            -CleanupReason ('setup-{0}' -f $Reason) `
            -Source 'setup'

        if ($null -ne $script:RaymanSetupVsCodeReport) {
            $newPids = @($script:RaymanSetupVsCodeReport.new_pids)
            $cleanupPids = @($script:RaymanSetupVsCodeReport.cleanup_pids)
            if ($newPids.Count -gt 0) {
                Write-Host ("ℹ️ [VS Code] 本次 setup 新增窗口 PID: {0}" -f ($newPids -join ', ')) -ForegroundColor DarkCyan
            }
            if ($cleanupPids.Count -gt 0) {
                Write-Host ("🧹 [VS Code] 已回收 setup 新增窗口 PID: {0}" -f ($cleanupPids -join ', ')) -ForegroundColor DarkCyan
            }
        }
    } catch {
        Write-Host ("⚠️ [VS Code] setup 窗口审计失败: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }

    return $script:RaymanSetupVsCodeReport
}

function Exit-RaymanSetup {
    param(
        [int]$ExitCode,
        [string]$Reason = 'setup'
    )

    Invoke-RaymanSetupFinalize -ExitCode $ExitCode -Reason $Reason | Out-Null
    exit $ExitCode
}

function Read-RaymanJsonConfigCompat {
    param(
        [string]$Path,
        [switch]$AsHashtable,
        [string]$WarningPrefix = 'json'
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Exists = $false
            ParseFailed = $false
            Obj = $null
            Error = ''
        }
    }

    if ($raymanCommonImported -and (Get-Command Read-RaymanJsonFile -ErrorAction SilentlyContinue)) {
        $doc = Read-RaymanJsonFile -Path $Path -AsHashtable:$AsHashtable
        if ([bool]$doc.ParseFailed) {
            Write-Host ("⚠️ [{0}] 无法解析 JSON/JSONC，已回退默认值: {1} ({2})" -f $WarningPrefix, $Path, [string]$doc.Error) -ForegroundColor Yellow
        }
        return $doc
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $obj = if ($AsHashtable) {
            $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        } else {
            $raw | ConvertFrom-Json -ErrorAction Stop
        }
        return [pscustomobject]@{
            Exists = $true
            ParseFailed = $false
            Obj = $obj
            Error = ''
        }
    } catch {
        Write-Host ("⚠️ [{0}] 无法解析 JSON，已回退默认值: {1} ({2})" -f $WarningPrefix, $Path, $_.Exception.Message) -ForegroundColor Yellow
        return [pscustomobject]@{
            Exists = $true
            ParseFailed = $true
            Obj = $null
            Error = $_.Exception.Message
        }
    }
}

trap {
    $trapExitCode = Get-LastExitCodeCompat -Default 1
    if ($trapExitCode -eq 0) { $trapExitCode = 1 }
    Write-Host ("❌ [Setup] 未处理异常：{0}" -f $_.Exception.Message) -ForegroundColor Red
    Exit-RaymanSetup -ExitCode $trapExitCode -Reason 'unhandled-exception'
}

function Get-EnvBoolCompat([string]$Name, [bool]$Default) {
    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    return ($raw -ne '0' -and $raw -ne 'false' -and $raw -ne 'False')
}

function Get-EnvIntCompat([string]$Name, [int]$Default, [int]$Min = 1, [int]$Max = 86400) {
    $raw = [Environment]::GetEnvironmentVariable($Name)
    $parsed = 0
    if (-not [string]::IsNullOrWhiteSpace($raw) -and [int]::TryParse($raw, [ref]$parsed)) {
        if ($parsed -lt $Min) { return $Min }
        if ($parsed -gt $Max) { return $Max }
        return $parsed
    }
    return $Default
}

function Test-HostIsWindowsCompat {
    try {
        return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    } catch {
        return $false
    }
}

function Test-WindowsSandboxFeatureEnabledCompat {
    if (-not (Test-HostIsWindowsCompat)) { return $false }

    $sandboxExePath = Join-Path $env:WINDIR 'System32\WindowsSandbox.exe'
    if (-not (Test-Path -LiteralPath $sandboxExePath -PathType Leaf)) { return $false }

    # Prefer CIM probe to avoid elevation-related noisy host errors.
    try {
        $feature = Get-CimInstance -ClassName Win32_OptionalFeature -Filter "Name='Containers-DisposableClientVM'" -ErrorAction SilentlyContinue
        if ($null -ne $feature -and $null -ne $feature.InstallState) {
            return ([int]$feature.InstallState -eq 1)
        }
    } catch {}

    return $false
}

function Convert-WindowsPathToWslCompat([string]$Path) {
    $normalized = $Path
    try {
        $normalized = [System.IO.Path]::GetFullPath($Path)
    } catch {}

    if ($normalized -match '^\\\\wsl\.localhost\\[^\\]+\\(?<rest>.*)$') {
        $rest = $matches['rest'] -replace '\\', '/'
        if ([string]::IsNullOrWhiteSpace($rest)) { return '/' }
        if ($rest.StartsWith('/')) { return $rest }
        return "/$rest"
    }

    if ($normalized -match '^(?<drive>[A-Za-z]):\\(?<rest>.*)$') {
        $drive = $matches['drive'].ToLowerInvariant()
        $rest = $matches['rest'] -replace '\\', '/'
        if ([string]::IsNullOrWhiteSpace($rest)) {
            return "/mnt/$drive"
        }
        return "/mnt/$drive/$rest"
    }
    return ($normalized -replace '\\', '/')
}

function Get-PathComparisonValueCompat([string]$PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
    $candidate = [string]$PathValue
    if ($candidate.StartsWith('Microsoft.PowerShell.Core\FileSystem::', [System.StringComparison]::OrdinalIgnoreCase)) {
        $candidate = $candidate.Substring('Microsoft.PowerShell.Core\FileSystem::'.Length)
    }
    try {
        $full = [System.IO.Path]::GetFullPath($candidate)
    } catch {
        $full = $candidate
    }
    return ($full.TrimEnd('\', '/') -replace '\\', '/').ToLowerInvariant()
}

function Test-PathInsideCompat([string]$PathValue, [string]$RootValue) {
    $pathNorm = Get-PathComparisonValueCompat $PathValue
    $rootNorm = Get-PathComparisonValueCompat $RootValue
    if ([string]::IsNullOrWhiteSpace($pathNorm) -or [string]::IsNullOrWhiteSpace($rootNorm)) { return $false }
    if ($pathNorm -eq $rootNorm) { return $true }
    return $pathNorm.StartsWith($rootNorm + '/')
}

function Normalize-WorkspaceMemoryEnv {
    param(
        [string]$WorkspaceRoot
    )

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { return }
    $resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $memoryRoot = Join-Path $resolvedWorkspaceRoot '.Rayman\state\memory'
    if (-not (Test-Path -LiteralPath $memoryRoot -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $memoryRoot | Out-Null
    }

    if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_MEMORY_PYTHON)) {
        $venvWinPython = Join-Path $resolvedWorkspaceRoot '.venv\Scripts\python.exe'
        $venvPosixPython = Join-Path $resolvedWorkspaceRoot '.venv/bin/python'
        if (Test-Path -LiteralPath $venvWinPython -PathType Leaf) {
            $env:RAYMAN_MEMORY_PYTHON = $venvWinPython
        } elseif (Test-Path -LiteralPath $venvPosixPython -PathType Leaf) {
            $env:RAYMAN_MEMORY_PYTHON = $venvPosixPython
        }
    }
}

function Get-LastExitCodeCompat([int]$Default = 0) {
    try {
        $globalVar = Get-Variable -Name "LASTEXITCODE" -Scope Global -ErrorAction Stop
        if ($null -ne $globalVar.Value) { return [int]$globalVar.Value }
    } catch {}
    try {
        $scriptVar = Get-Variable -Name "LASTEXITCODE" -Scope Script -ErrorAction Stop
        if ($null -ne $scriptVar.Value) { return [int]$scriptVar.Value }
    } catch {}
    return $Default
}

function Reset-LastExitCodeCompat {
    try { Set-Variable -Name "LASTEXITCODE" -Scope Global -Value 0 -Force } catch {}
    try { Set-Variable -Name "LASTEXITCODE" -Scope Script -Value 0 -Force } catch {}
}

function Invoke-SetupChildPowerShellScript {
    param(
        [string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
        throw 'copy-self-check script path is empty'
    }
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw ("copy-self-check script missing: {0}" -f $ScriptPath)
    }

    $psHost = $null
    if ($raymanCommonImported -and (Get-Command Resolve-RaymanPowerShellHost -ErrorAction SilentlyContinue)) {
        $psHost = Resolve-RaymanPowerShellHost
    }
    if ([string]::IsNullOrWhiteSpace([string]$psHost)) {
        foreach ($candidate in @('powershell.exe', 'powershell', 'pwsh.exe', 'pwsh')) {
            $cmd = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
                $psHost = [string]$cmd.Source
                break
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$psHost)) {
        throw 'PowerShell host not found for setup self-check'
    }

    Reset-LastExitCodeCompat
    & $psHost -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments | Out-Host
    if ($?) {
        return 0
    }
    return (Get-LastExitCodeCompat -Default 1)
}

function Invoke-PlaywrightAutoInstall {
    param(
        [string]$WorkspaceRoot,
        [string]$Scope,
        [string]$Browser,
        [int]$TimeoutSeconds
    )

    $scopeNorm = if ([string]::IsNullOrWhiteSpace($Scope)) { 'all' } else { $Scope.Trim().ToLowerInvariant() }
    $browserNorm = if ([string]::IsNullOrWhiteSpace($Browser)) { 'chromium' } else { $Browser.Trim().ToLowerInvariant() }
    $shouldWsl = ($scopeNorm -eq 'all' -or $scopeNorm -eq 'wsl')
    $attempted = $false
    $hostIsWindows = Test-HostIsWindowsCompat

    Write-Host "📦 [Playwright] 正在自动安装浏览器运行时（可用于 Copilot/Codex 网页自动化调试）..." -ForegroundColor Cyan

    if ($hostIsWindows) {
        $npxCmd = Get-Command 'npx.cmd' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $npxCmd) {
            $npxCmd = Get-Command 'npx' -ErrorAction SilentlyContinue | Select-Object -First 1
        }

        if ($null -ne $npxCmd -and -not [string]::IsNullOrWhiteSpace([string]$npxCmd.Source)) {
            $attempted = $true
            Write-Host ("   -> [host] {0} -y playwright install {1}" -f $npxCmd.Source, $browserNorm) -ForegroundColor DarkCyan
            try {
                Reset-LastExitCodeCompat
                & $npxCmd.Source -y playwright install $browserNorm
                $hostInstallExitCode = Get-LastExitCodeCompat -Default 0
                if ($hostInstallExitCode -eq 0) {
                    Write-Host "✅ [Playwright][host] 自动安装完成" -ForegroundColor Green
                } else {
                    Write-Host ("⚠️ [Playwright][host] 自动安装失败（exit={0}），将继续执行就绪检查。" -f $hostInstallExitCode) -ForegroundColor Yellow
                }
            } catch {
                Write-Host ("⚠️ [Playwright][host] 自动安装异常：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
            }
        } else {
            Write-Host "⚠️ [Playwright][host] 未找到 npx，跳过 host 自动安装。" -ForegroundColor Yellow
        }

        if ($shouldWsl -and (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
            $wslEnsureScript = Join-Path $WorkspaceRoot ".Rayman\scripts\pwa\ensure_playwright_wsl.sh"
            if (Test-Path -LiteralPath $wslEnsureScript -PathType Leaf) {
                $attempted = $true
                $workspaceWsl = Convert-WindowsPathToWslCompat -Path $WorkspaceRoot
                $workspaceWslEscaped = $workspaceWsl.Replace("'", "'""'""'")
                $browserEscaped = $browserNorm.Replace("'", "'""'""'")
                $cmd = "cd '$workspaceWslEscaped' && bash ./.Rayman/scripts/pwa/ensure_playwright_wsl.sh --browser '$browserEscaped' --require 0"
                Write-Host "   -> [wsl] ensure_playwright_wsl.sh --require 0" -ForegroundColor DarkCyan
                try {
                    Reset-LastExitCodeCompat
                    & wsl.exe -e bash -lc $cmd
                    $wslInstallExitCode = Get-LastExitCodeCompat -Default 0
                    if ($wslInstallExitCode -eq 0) {
                        Write-Host "✅ [Playwright][wsl] 自动安装完成" -ForegroundColor Green
                    } else {
                        Write-Host ("⚠️ [Playwright][wsl] 自动安装失败（exit={0}），将继续执行就绪检查。" -f $wslInstallExitCode) -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host ("⚠️ [Playwright][wsl] 自动安装异常：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
                }
            } else {
                Write-Host ("⚠️ [Playwright][wsl] 缺少脚本：{0}" -f $wslEnsureScript) -ForegroundColor Yellow
            }
        }
    } else {
        $wslScript = Join-Path $WorkspaceRoot ".Rayman/scripts/pwa/ensure_playwright_wsl.sh"
        if ((Get-Command bash -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $wslScript -PathType Leaf)) {
            $attempted = $true
            Write-Host "   -> [linux] ensure_playwright_wsl.sh --require 0" -ForegroundColor DarkCyan
            Push-Location $WorkspaceRoot
            try {
                Reset-LastExitCodeCompat
                & bash ./.Rayman/scripts/pwa/ensure_playwright_wsl.sh --browser $browserNorm --require 0
                $linuxInstallExitCode = Get-LastExitCodeCompat -Default 0
                if ($linuxInstallExitCode -eq 0) {
                    Write-Host "✅ [Playwright][linux] 自动安装完成" -ForegroundColor Green
                } else {
                    Write-Host ("⚠️ [Playwright][linux] 自动安装失败（exit={0}），将继续执行就绪检查。" -f $linuxInstallExitCode) -ForegroundColor Yellow
                }
            } catch {
                Write-Host ("⚠️ [Playwright][linux] 自动安装异常：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
            } finally {
                Pop-Location
            }
        }
    }

    if (-not $attempted) {
        Write-Host "⚠️ [Playwright] 未找到可用的自动安装通道，跳过自动安装。" -ForegroundColor Yellow
    } elseif ($TimeoutSeconds -gt 0) {
        Write-Host ("ℹ️ [Playwright] 自动安装阶段完成（timeout配置={0}s）" -f $TimeoutSeconds) -ForegroundColor DarkCyan
    }
}

$script:SetupTranscriptActive = $false
$script:SetupLogPath = ''

function Stop-SetupTranscriptSafe {
    if (-not $script:SetupTranscriptActive) { return }
    try {
        Stop-Transcript | Out-Null
    } catch {}
    $script:SetupTranscriptActive = $false
}

function Get-LatestPlaywrightDetailLog([string]$Root) {
    $logsDir = Join-Path $Root ".Rayman\logs"
    if (-not (Test-Path -LiteralPath $logsDir -PathType Container)) { return '' }
    try {
        $latest = Get-ChildItem -LiteralPath $logsDir -Filter "playwright.ready.win.*.log" -File -ErrorAction Stop |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($null -ne $latest) { return $latest.FullName }
    } catch {}
    return ''
}

function Show-PlaywrightTroubleshootingHints {
    param([string]$Root)

    $summaryPath = Join-Path $Root ".Rayman\runtime\playwright.ready.windows.json"
    $detailPath = ''
    if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
        try {
            $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ($summary.PSObject.Properties['detail_log']) {
                $detailPath = [string]$summary.detail_log
            }
        } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($detailPath)) {
        $detailPath = Get-LatestPlaywrightDetailLog -Root $Root
    }
    if ([string]::IsNullOrWhiteSpace($detailPath)) {
        $detailPath = '(not found yet)'
    }

    Write-Host "🔎 [Playwright] 排障入口：" -ForegroundColor Yellow
    Write-Host ("   setup 日志路径: {0}" -f $script:SetupLogPath) -ForegroundColor DarkYellow
    Write-Host ("   playwright summary 路径: {0}" -f $summaryPath) -ForegroundColor DarkYellow
    Write-Host ("   playwright 详细日志路径: {0}" -f $detailPath) -ForegroundColor DarkYellow
    Write-Host "   说明: RAYMAN_SANDBOX_AUTO_CLOSE 是脚本收尾行为，不需要等待系统自动关闭 Sandbox。" -ForegroundColor DarkYellow
    Write-Host "   若你手工关闭了 Sandbox: 直接重跑 setup；默认先走 wsl，必要时自动回退 host（本地）。" -ForegroundColor DarkYellow
    Write-Host "   如需严格 sandbox 校验: 设置 `$env:RAYMAN_PLAYWRIGHT_SETUP_SCOPE='sandbox'（失败会阻断）。" -ForegroundColor DarkYellow
}

function Ensure-WorkspaceEnvDefaults {
    param([string]$EnvFilePath)

    if ([string]::IsNullOrWhiteSpace($EnvFilePath)) { return }
    if (-not (Test-Path -LiteralPath $EnvFilePath -PathType Leaf)) { return }

    $defaults = [ordered]@{
        'RAYMAN_HEARTBEAT_SECONDS' = '30'
        'RAYMAN_HEARTBEAT_VERBOSE' = '1'
        'RAYMAN_HEARTBEAT_SMART_SILENCE_ENABLED' = '1'
        'RAYMAN_HEARTBEAT_SILENT_WINDOW_SECONDS' = '15'
        'RAYMAN_AUTO_INSTALL_TEST_DEPS' = '1'
        'RAYMAN_REQUIRE_TEST_DEPS' = '1'
        'RAYMAN_SELF_HEAL_AUTO_DEP_INSTALL' = '1'
        'RAYMAN_PLAYWRIGHT_REQUIRE' = '1'
        'RAYMAN_PLAYWRIGHT_AUTO_INSTALL' = '1'
        'RAYMAN_PLAYWRIGHT_SETUP_SCOPE' = 'wsl'
        'RAYMAN_GIT_SAFECRLF_SUPPRESS' = '1'
        'RAYMAN_SETUP_GIT_INIT' = '1'
        'RAYMAN_SETUP_GITHUB_LOGIN' = '1'
        'RAYMAN_SETUP_GITHUB_LOGIN_STRICT' = '0'
        'RAYMAN_GITHUB_HOST' = 'github.com'
        'RAYMAN_GITHUB_GIT_PROTOCOL' = 'https'
        'RAYMAN_AUTO_REPAIR_NESTED_RAYMAN' = '1'
        'RAYMAN_SANDBOX_OFFLINE_CACHE_ENABLED' = '1'
        'RAYMAN_SANDBOX_OFFLINE_CACHE_COPY_BROWSERS' = '1'
        'RAYMAN_SANDBOX_OFFLINE_CACHE_REFRESH_HOURS' = '24'
        'RAYMAN_SANDBOX_OFFLINE_CACHE_FORCE' = '0'
        'RAYMAN_DOTNET_WINDOWS_PREFERRED' = '1'
        'RAYMAN_DOTNET_WINDOWS_STRICT' = '0'
        'RAYMAN_DOTNET_WINDOWS_TIMEOUT_SECONDS' = '1800'
        'RAYMAN_AGENT_DEFAULT_BACKEND' = 'local'
        'RAYMAN_AGENT_FALLBACK_ORDER' = 'codex,local'
        'RAYMAN_AGENT_CLOUD_ENABLED' = '0'
        'RAYMAN_AGENT_PIPELINE' = 'planner_v1'
        'RAYMAN_AGENT_DOC_GATE' = '1'
        'RAYMAN_AGENT_OPENAI_OPTIONAL' = 'auto'
        'RAYMAN_AGENT_CAPABILITIES_ENABLED' = '1'
        'RAYMAN_AGENT_CAP_OPENAI_DOCS_ENABLED' = '1'
        'RAYMAN_AGENT_CAP_WEB_AUTO_TEST_ENABLED' = '1'
        'RAYMAN_AGENT_CAP_WINAPP_AUTO_TEST_ENABLED' = '1'
        'RAYMAN_AGENT_POLICY_BYPASS' = '0'
        'RAYMAN_AGENT_CLOUD_WHITELIST' = ''
        'RAYMAN_WINAPP_REQUIRE' = '0'
        'RAYMAN_WINAPP_DEFAULT_TIMEOUT_MS' = '15000'
        'RAYMAN_FIRST_PASS_WINDOW' = '20'
        'RAYMAN_REVIEW_LOOP_MAX_ROUNDS' = '2'
        'RAYMAN_ALERT_SURFACE' = 'log'
        'RAYMAN_ALERT_DONE_ENABLED' = '0'
        'RAYMAN_ALERT_TTS_ENABLED' = '0'
        'RAYMAN_ALERT_TTS_DONE_ENABLED' = '0'
        'RAYMAN_AUTO_START_ATTENTION_WATCH_ENABLED' = '0'
        'RAYMAN_ALERT_WATCH_ON_PROMPT_ENABLED' = '0'
        'RAYMAN_AUTO_SAVE_WATCH_ENABLED' = '0'
        'RAYMAN_VSCODE_BOOTSTRAP_PROFILE' = 'conservative'
        'RAYMAN_SCM_CHANGE_SOFT_LIMIT' = '100'
        'RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS' = '0'
    }
    $expressionDefaults = [ordered]@{
        'RAYMAN_SANDBOX_HEARTBEAT_SECONDS' = '[string]$env:RAYMAN_HEARTBEAT_SECONDS'
        'RAYMAN_MCP_HEARTBEAT_SECONDS' = '[string]$env:RAYMAN_HEARTBEAT_SECONDS'
    }

    $raw = ''
    try {
        $raw = Get-Content -LiteralPath $EnvFilePath -Raw -Encoding UTF8
    } catch {
        return
    }
    if ($null -eq $raw) { $raw = '' }

    $missingBlocks = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $defaults.GetEnumerator()) {
        $key = [string]$entry.Key
        $value = [string]$entry.Value
        if ($raw -match [regex]::Escape("env:$key")) { continue }
        $block = @"
if ([string]::IsNullOrWhiteSpace([string]`$env:$key)) {
    `$env:$key = '$value'
}
"@
        $missingBlocks.Add($block) | Out-Null
    }
    foreach ($entry in $expressionDefaults.GetEnumerator()) {
        $key = [string]$entry.Key
        $expression = [string]$entry.Value
        if ($raw -match [regex]::Escape("env:$key")) { continue }
        $block = @"
if ([string]::IsNullOrWhiteSpace([string]`$env:$key)) {
    `$env:$key = $expression
}
"@
        $missingBlocks.Add($block) | Out-Null
    }

    if ($missingBlocks.Count -le 0) { return }

    $prefix = "`r`n# Rayman dependency auto-heal defaults (managed by setup)`r`n"
    $appendText = ($missingBlocks -join "`r`n")
    $newContent = $raw
    if (-not [string]::IsNullOrWhiteSpace($newContent) -and -not $newContent.EndsWith("`n")) {
        $newContent += "`r`n"
    }
    $newContent += $prefix + $appendText + "`r`n"

    try {
        Set-Content -LiteralPath $EnvFilePath -Value $newContent -Encoding UTF8
        Write-Host ("✅ 已补齐 .rayman.env.ps1 默认依赖策略（新增 {0} 项）" -f $missingBlocks.Count) -ForegroundColor Green
    } catch {
        Write-Host ("⚠️ 补齐 .rayman.env.ps1 默认依赖策略失败: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Clear-SetupDirectoryContents {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        return 0
    }

    $items = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    foreach ($item in $items) {
        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $items.Count
}

function Get-SetupLegacyMemoryPaths {
    param([string]$WorkspaceRoot)

    if ($raymanCommonImported -and (Get-Command Get-RaymanLegacyMemoryPaths -ErrorAction SilentlyContinue)) {
        try {
            return (Get-RaymanLegacyMemoryPaths -WorkspaceRoot $WorkspaceRoot)
        } catch {}
    }

    $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $stateRoot = Join-Path $resolvedRoot '.Rayman\state'
    return [pscustomobject]@{
        WorkspaceRoot = $resolvedRoot
        LegacyRoot = Join-Path $resolvedRoot ('.' + 'rag')
        LegacyStateDirectory = Join-Path $stateRoot ('chroma' + '_db')
        LegacyStateFile = Join-Path $stateRoot ('rag' + '.db')
    }
}

function Get-SetupMemoryPaths {
    param([string]$WorkspaceRoot)

    if ($raymanCommonImported -and (Get-Command Get-RaymanMemoryPaths -ErrorAction SilentlyContinue)) {
        try {
            return (Get-RaymanMemoryPaths -WorkspaceRoot $WorkspaceRoot)
        } catch {}
    }

    $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $memoryRoot = Join-Path $resolvedRoot '.Rayman\state\memory'
    $runtimeRoot = Join-Path $resolvedRoot '.Rayman\runtime\memory'
    return [pscustomobject]@{
        WorkspaceRoot = $resolvedRoot
        MemoryRoot = $memoryRoot
        RuntimeRoot = $runtimeRoot
    }
}

function Get-SetupLegacySnapshotArtifacts {
    param([string]$WorkspaceRoot)

    $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $snapshotRoot = Join-Path $resolvedRoot '.Rayman\runtime\snapshots'
    $artifacts = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $snapshotRoot -PathType Container)) {
        return @($artifacts.ToArray())
    }

    $markers = @(
        ('.' + 'rag'),
        ('.Rayman/state/' + ('chroma' + '_db')),
        ('.Rayman/state/' + ('rag' + '.db'))
    )

    foreach ($manifest in @(Get-ChildItem -LiteralPath $snapshotRoot -File -Filter '*.manifest.json' -ErrorAction SilentlyContinue)) {
        $raw = ''
        try {
            $raw = Get-Content -LiteralPath $manifest.FullName -Raw -Encoding UTF8 -ErrorAction Stop
        } catch {
            continue
        }

        $hasLegacyMarker = $false
        foreach ($marker in $markers) {
            if ($raw -like ('*' + $marker + '*')) {
                $hasLegacyMarker = $true
                break
            }
        }
        if (-not $hasLegacyMarker) {
            continue
        }

        if (-not $artifacts.Contains($manifest.FullName)) {
            $artifacts.Add($manifest.FullName) | Out-Null
        }

        if ($manifest.Name.EndsWith('.manifest.json', [System.StringComparison]::OrdinalIgnoreCase)) {
            $archiveStem = $manifest.Name.Substring(0, $manifest.Name.Length - '.manifest.json'.Length)
            $archivePath = Join-Path $manifest.DirectoryName ($archiveStem + '.tar.gz')
            if ((Test-Path -LiteralPath $archivePath -PathType Leaf) -and -not $artifacts.Contains($archivePath)) {
                $artifacts.Add($archivePath) | Out-Null
            }
        }
    }

    return @($artifacts.ToArray())
}

function Invoke-SetupLegacyMemoryCleanup {
    param(
        [string]$WorkspaceRoot,
        [switch]$ResetAgentMemoryData
    )

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot) -or -not (Test-Path -LiteralPath $WorkspaceRoot -PathType Container)) {
        return $null
    }

    $legacyPaths = Get-SetupLegacyMemoryPaths -WorkspaceRoot $WorkspaceRoot
    $memoryPaths = Get-SetupMemoryPaths -WorkspaceRoot $WorkspaceRoot
    $removed = New-Object System.Collections.Generic.List[string]

    foreach ($path in @(
        [string]$legacyPaths.LegacyRoot,
        [string]$legacyPaths.LegacyStateDirectory,
        [string]$legacyPaths.LegacyStateFile
    )) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
            continue
        }
        try {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            $removed.Add($path) | Out-Null
        } catch {
            Write-Host ("⚠️ [setup] 清理 legacy 记忆残留失败: {0} ({1})" -f $path, $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    foreach ($path in @(Get-SetupLegacySnapshotArtifacts -WorkspaceRoot $WorkspaceRoot)) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
            continue
        }
        try {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            $removed.Add($path) | Out-Null
        } catch {
            Write-Host ("⚠️ [setup] 清理 legacy 快照残留失败: {0} ({1})" -f $path, $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    $memoryReset = $false
    if ($ResetAgentMemoryData) {
        $memoryReset = ((Clear-SetupDirectoryContents -Path ([string]$memoryPaths.MemoryRoot)) -gt 0)
        if (Test-Path -LiteralPath ([string]$memoryPaths.RuntimeRoot) -PathType Container) {
            try {
                Remove-Item -LiteralPath ([string]$memoryPaths.RuntimeRoot) -Recurse -Force -ErrorAction Stop
                $removed.Add([string]$memoryPaths.RuntimeRoot) | Out-Null
                $memoryReset = $true
            } catch {
                Write-Host ("⚠️ [setup] 清理 Agent Memory runtime 失败: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            }
        }
    }

    if (-not (Test-Path -LiteralPath ([string]$memoryPaths.MemoryRoot) -PathType Container)) {
        New-Item -ItemType Directory -Force -Path ([string]$memoryPaths.MemoryRoot) | Out-Null
    }

    if ($removed.Count -gt 0) {
        Write-Host ("🧹 [setup] 已清理 legacy 记忆残留: {0}" -f $removed.Count) -ForegroundColor DarkCyan
    }
    if ($memoryReset) {
        Write-Host "🧹 [setup] 检测到跨工作区复制，已重置 Agent Memory 数据库与 runtime。" -ForegroundColor DarkCyan
    }

    return [pscustomobject]@{
        RemovedCount = $removed.Count
        RemovedPaths = @($removed.ToArray())
        ResetAgentMemoryData = [bool]$memoryReset
    }
}

function Normalize-SetupText([string]$Value) {
    if ($null -eq $Value) { return '' }
    $normalized = [string]$Value
    $normalized = $normalized.TrimStart([char]0xFEFF)
    $normalized = $normalized -replace "`r", ''
    return $normalized.Trim()
}

function Clear-SetupLogsBeforeRun([string]$LogsDir) {
    if ([string]::IsNullOrWhiteSpace($LogsDir)) { return }
    if (-not (Test-Path -LiteralPath $LogsDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
        return
    }

    try {
        $entries = @(Get-ChildItem -LiteralPath $LogsDir -Force -ErrorAction Stop)
        if ($entries.Count -le 0) { return }
        foreach ($entry in $entries) {
            Remove-Item -LiteralPath $entry.FullName -Recurse -Force -ErrorAction Stop
        }
        Write-Host ("🧹 [setup] 已清理旧日志：{0} 项" -f $entries.Count) -ForegroundColor DarkCyan
    } catch {
        Write-Host ("⚠️ [setup] 清理旧日志失败: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Sync-RaymanAssetsFromDistIfMissing {
    param([string]$WorkspaceRoot)

    $raymanRoot = Join-Path $WorkspaceRoot ".Rayman"
    $distRoot = Join-Path $raymanRoot ".dist"
    $sourceScriptsRoot = Join-Path $distRoot "scripts"
    $targetScriptsRoot = Join-Path $raymanRoot "scripts"

    $copied = 0
    $skipped = 0
    $missingSource = 0
    $errors = 0

    if (Test-Path -LiteralPath $sourceScriptsRoot -PathType Container) {
        if (-not (Test-Path -LiteralPath $targetScriptsRoot -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $targetScriptsRoot | Out-Null
        }

        $sourceScriptsRootFull = ''
        try {
            $sourceScriptsRootFull = [System.IO.Path]::GetFullPath($sourceScriptsRoot).TrimEnd('\', '/')
        } catch {
            $sourceScriptsRootFull = [string]$sourceScriptsRoot
        }
        $sourceScriptsRootPrefix = $sourceScriptsRootFull + [System.IO.Path]::DirectorySeparatorChar
        $sourceFiles = @(Get-ChildItem -LiteralPath $sourceScriptsRoot -Recurse -File -ErrorAction SilentlyContinue)
        foreach ($sourceFile in $sourceFiles) {
            $sourceFileFull = ''
            try {
                $sourceFileFull = [System.IO.Path]::GetFullPath([string]$sourceFile.FullName)
            } catch {
                $sourceFileFull = [string]$sourceFile.FullName
            }

            if ($sourceFileFull.StartsWith($sourceScriptsRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $relativePath = $sourceFileFull.Substring($sourceScriptsRootPrefix.Length).TrimStart('\', '/')
            } else {
                $errors++
                Write-Host ("⚠️ [asset-heal] 无法推导相对路径，已跳过: root={0}; file={1}" -f $sourceScriptsRootFull, $sourceFileFull) -ForegroundColor Yellow
                continue
            }
            if ([string]::IsNullOrWhiteSpace($relativePath)) { continue }

            $targetPath = Join-Path $targetScriptsRoot $relativePath
            if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
                $skipped++
                continue
            }

            $targetDir = Split-Path -Parent $targetPath
            if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
                New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
            }

            try {
                Copy-Item -LiteralPath $sourceFile.FullName -Destination $targetPath -Force
                $copied++
            } catch {
                $errors++
                Write-Host ("⚠️ [asset-heal] 复制失败: {0} -> {1}; {2}" -f $sourceFile.FullName, $targetPath, $_.Exception.Message) -ForegroundColor Yellow
            }
        }
    } else {
        $missingSource++
        Write-Host ("⚠️ [asset-heal] 缺少脚本源目录，跳过 scripts 自动补齐: {0}" -f $sourceScriptsRoot) -ForegroundColor Yellow
    }

    $rootFileMappings = @(
        @{
            Source = Join-Path $distRoot "RELEASE_REQUIREMENTS.md"
            Target = Join-Path $raymanRoot "RELEASE_REQUIREMENTS.md"
            Label = "RELEASE_REQUIREMENTS.md"
        },
        @{
            Source = Join-Path $distRoot "VERSION"
            Target = Join-Path $raymanRoot "VERSION"
            Label = "VERSION"
        }
    )

    foreach ($mapping in $rootFileMappings) {
        $sourcePath = [string]$mapping.Source
        $targetPath = [string]$mapping.Target
        $label = [string]$mapping.Label

        if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
            $skipped++
            continue
        }
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            $missingSource++
            Write-Host ("⚠️ [asset-heal] 缺少源文件，无法补齐 .Rayman/{0}: {1}" -f $label, $sourcePath) -ForegroundColor Yellow
            continue
        }

        $targetDir = Split-Path -Parent $targetPath
        if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
        }

        try {
            Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
            $copied++
        } catch {
            $errors++
            Write-Host ("⚠️ [asset-heal] 复制失败: {0} -> {1}; {2}" -f $sourcePath, $targetPath, $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    $summaryColor = if ($errors -gt 0) { 'Yellow' } else { 'DarkCyan' }
    Write-Host ("ℹ️ [asset-heal] 缺失资产补齐完成: copied={0} skipped={1} missing_source={2} errors={3}" -f $copied, $skipped, $missingSource, $errors) -ForegroundColor $summaryColor
}

function Invoke-EnsureRequirementsLayout {
    param([string]$WorkspaceRoot)

    $ensureScriptRel = "./.Rayman/scripts/requirements/ensure_requirements.sh"
    $ensureScript = Join-Path $WorkspaceRoot ".Rayman\scripts\requirements\ensure_requirements.sh"
    if (-not (Test-Path -LiteralPath $ensureScript -PathType Leaf)) {
        $ensureScriptRel = "./.Rayman/.dist/scripts/requirements/ensure_requirements.sh"
        $ensureScript = Join-Path $WorkspaceRoot ".Rayman\.dist\scripts\requirements\ensure_requirements.sh"
        if (Test-Path -LiteralPath $ensureScript -PathType Leaf) {
            Write-Host ("⚠️ [req] workspace 脚本缺失，回退使用 dist 版本: {0}" -f $ensureScript) -ForegroundColor Yellow
        } else {
            Write-Host ("⚠️ [req] 缺少脚本，跳过 requirements 补齐: {0}" -f $ensureScript) -ForegroundColor Yellow
            return
        }
    }

    $bashCmd = Get-Command 'bash' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $bashCmd -or [string]::IsNullOrWhiteSpace([string]$bashCmd.Source)) {
        Write-Host "⚠️ [req] 未找到 bash，跳过 requirements 补齐。" -ForegroundColor Yellow
        return
    }

    Push-Location $WorkspaceRoot
    try {
        Reset-LastExitCodeCompat
        & $bashCmd.Source $ensureScriptRel
        $exitCode = Get-LastExitCodeCompat -Default 0
        if ($exitCode -eq 0) {
            Write-Host "✅ [req] requirements 结构补齐完成" -ForegroundColor Green
        } else {
            Write-Host ("⚠️ [req] ensure_requirements.sh 执行失败（exit={0}），已跳过本次补齐。" -f $exitCode) -ForegroundColor Yellow
        }
    } catch {
        Write-Host ("⚠️ [req] requirements 补齐异常: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    } finally {
        Pop-Location
    }
}

function Get-RaymanDefaultScmIgnoreMode {
    param([string]$WorkspaceRoot)

    $workspaceKind = Get-RaymanWorkspaceKind -WorkspaceRoot $WorkspaceRoot
    if ($workspaceKind -eq 'external') {
        return 'gitignore'
    }

    return 'info-exclude'
}

function Get-RaymanScmIgnoreMode {
    param([string]$WorkspaceRoot)

    $defaultMode = Get-RaymanDefaultScmIgnoreMode -WorkspaceRoot $WorkspaceRoot
    $rawMode = [Environment]::GetEnvironmentVariable('RAYMAN_SCM_IGNORE_MODE')
    if ([string]::IsNullOrWhiteSpace($rawMode)) { return $defaultMode }

    switch ($rawMode.Trim().ToLowerInvariant()) {
        'info-exclude' { return 'info-exclude' }
        'gitignore' { return 'gitignore' }
        'off' { return 'off' }
        default {
            Write-Host ("⚠️ [SCM] RAYMAN_SCM_IGNORE_MODE={0} 非法，回退为 {1}。" -f $rawMode, $defaultMode) -ForegroundColor Yellow
            return $defaultMode
        }
    }
}

function Get-RaymanScmSoftLimit {
    return (Get-EnvIntCompat -Name 'RAYMAN_SCM_CHANGE_SOFT_LIMIT' -Default 100 -Min 1 -Max 200000)
}

function Get-RaymanScmIgnoreRules {
    param([string]$WorkspaceRoot)

    $workspaceKind = Get-RaymanWorkspaceKind -WorkspaceRoot $WorkspaceRoot
    if ($workspaceKind -eq 'external') {
        return @(
            '.Rayman/'
            '.SolutionName'
            '.rayman.env.ps1'
            '.rayman.project.json'
            '.cursorrules'
            '.clinerules'
            '.codex/config.toml'
            '.github/copilot-instructions.md'
            '.github/model-policy.md'
            '.github/instructions/'
            '.github/agents/'
            '.github/skills/'
            '.github/prompts/'
            '.github/workflows/rayman-project-fast-gate.yml'
            '.github/workflows/rayman-project-browser-gate.yml'
            '.github/workflows/rayman-project-full-gate.yml'
            '.vscode/tasks.json'
            '.vscode/settings.json'
            '.Rayman_full_for_copy/'
            'Rayman_full_bundle/'
            '.tmp_sandbox_verify_*/'
            '.artifacts/'
            'obj/'
            'bin/'
            'test-results/'
        )
    }

    return @(
        '.Rayman/context/skills.auto.md'
        '.Rayman/logs/'
        '.Rayman/runtime/'
        '.Rayman/state/'
        '.Rayman/temp/'
        '.Rayman/tmp/'
        '.Rayman/release/*.zip'
        '.Rayman/release/*.tar.gz'
        '.Rayman/mcp/*.bak'
        '.Rayman/release/delivery-pack-*.md'
        '.Rayman/release/public-release-notes-*.md'
        '.Rayman/release/release-notes-*.md'
        '.Rayman_full_for_copy/'
        'Rayman_full_bundle/'
        '.tmp_sandbox_verify_*/'
        '.cursorrules'
        '.clinerules'
        '.vscode/tasks.json'
        '.vscode/settings.json'
        '.rayman.env.ps1'
        '.env'
        '.codex/config.toml'
        '.artifacts/'
        'obj/'
        'bin/'
        'test-results/'
    )
}

function Update-RaymanScmIgnoreRules {
    param([string]$WorkspaceRoot)

    $workspaceKind = Get-RaymanWorkspaceKind -WorkspaceRoot $WorkspaceRoot
    $mode = Get-RaymanScmIgnoreMode -WorkspaceRoot $WorkspaceRoot
    if ($mode -eq 'off') {
        Write-Host "⏭️ [SCM] 已关闭忽略规则注入（RAYMAN_SCM_IGNORE_MODE=off）。" -ForegroundColor DarkCyan
        return [pscustomobject]@{
            mode = $mode
            applied = $false
            workspace_kind = $workspaceKind
            target_path = ''
            reason = 'disabled_by_env'
        }
    }

    $beginMarker = '# RAYMAN:GENERATED:BEGIN'
    $endMarker = '# RAYMAN:GENERATED:END'
    $ignoreRules = @(Get-RaymanScmIgnoreRules -WorkspaceRoot $WorkspaceRoot)

    $targetPath = ''
    if ($mode -eq 'gitignore') {
        $targetPath = Join-Path $WorkspaceRoot '.gitignore'
    } else {
        $gitInfoDir = Join-Path $WorkspaceRoot '.git/info'
        if (-not (Test-Path -LiteralPath $gitInfoDir -PathType Container)) {
            Write-Host "⚠️ [SCM] 未检测到 .git/info，跳过 info/exclude 注入。可设置 RAYMAN_SCM_IGNORE_MODE=gitignore。" -ForegroundColor Yellow
            return [pscustomobject]@{
                mode = $mode
                applied = $false
                workspace_kind = $workspaceKind
                target_path = ''
                reason = 'git_info_missing'
            }
        }
        $targetPath = Join-Path $gitInfoDir 'exclude'
    }

    try {
        $targetDir = Split-Path -Parent $targetPath
        if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
        }
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
            New-Item -ItemType File -Force -Path $targetPath | Out-Null
        }

        $currentLines = @(Get-Content -LiteralPath $targetPath -Encoding UTF8 -ErrorAction SilentlyContinue)
        $filtered = New-Object System.Collections.Generic.List[string]
        $insideBlock = $false
        foreach ($line in $currentLines) {
            $trimmed = [string]$line
            if ($trimmed.Trim() -eq $beginMarker) {
                $insideBlock = $true
                continue
            }
            if ($insideBlock) {
                if ($trimmed.Trim() -eq $endMarker) {
                    $insideBlock = $false
                }
                continue
            }
            [void]$filtered.Add($trimmed)
        }

        while ($filtered.Count -gt 0 -and [string]::IsNullOrWhiteSpace([string]$filtered[$filtered.Count - 1])) {
            $filtered.RemoveAt($filtered.Count - 1)
        }

        $output = New-Object System.Collections.Generic.List[string]
        foreach ($line in $filtered) {
            [void]$output.Add([string]$line)
        }
        if ($output.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$output[$output.Count - 1])) {
            [void]$output.Add('')
        }

        [void]$output.Add($beginMarker)
        [void]$output.Add(("# Managed by Rayman setup.ps1 (SCM noise control, workspace_kind={0})" -f $workspaceKind))
        foreach ($rule in $ignoreRules) {
            [void]$output.Add([string]$rule)
        }
        [void]$output.Add($endMarker)

        $newContent = ($output -join "`r`n") + "`r`n"
        Set-Content -LiteralPath $targetPath -Value $newContent -Encoding UTF8

        Write-Host ("✅ [SCM] 已注入忽略规则（workspace={0}, mode={1}）: {2}" -f $workspaceKind, $mode, $targetPath) -ForegroundColor Green
        Write-Host "ℹ️ [SCM] 提示：已被 Git 跟踪的文件不受 ignore 规则影响，需手动取消跟踪（例如 git rm --cached）。" -ForegroundColor DarkCyan
        return [pscustomobject]@{
            mode = $mode
            applied = $true
            workspace_kind = $workspaceKind
            target_path = $targetPath
            reason = 'ok'
        }
    } catch {
        Write-Host ("⚠️ [SCM] 注入忽略规则失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
        return [pscustomobject]@{
            mode = $mode
            applied = $false
            workspace_kind = $workspaceKind
            target_path = $targetPath
            reason = 'write_failed'
        }
    }
}

function Get-RaymanScmStatusSummary {
    param([string]$WorkspaceRoot)

    $summary = [ordered]@{
        git_available = $false
        inside_git = $false
        modified = 0
        added = 0
        untracked = 0
        total = 0
        top_sources = @()
    }

    $gitCmd = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $gitCmd -or [string]::IsNullOrWhiteSpace([string]$gitCmd.Source)) {
        return [pscustomobject]$summary
    }
    $summary.git_available = $true

    try {
        Reset-LastExitCodeCompat
        & $gitCmd.Source -C $WorkspaceRoot rev-parse --is-inside-work-tree *> $null
        $insideExitCode = Get-LastExitCodeCompat -Default 1
        if ($insideExitCode -ne 0) {
            return [pscustomobject]$summary
        }
        $summary.inside_git = $true

        Reset-LastExitCodeCompat
        $porcelainLines = @(& $gitCmd.Source -C $WorkspaceRoot status --porcelain --untracked-files=all 2>$null)
        $statusExitCode = Get-LastExitCodeCompat -Default 1
        if ($statusExitCode -ne 0) {
            return [pscustomobject]$summary
        }

        $topCounter = @{}
        foreach ($rawLine in $porcelainLines) {
            $line = [string]$rawLine
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line.Length -lt 3) { continue }

            $statusCode = $line.Substring(0, 2)
            $pathPart = ''
            if ($line.Length -ge 4) {
                $pathPart = $line.Substring(3).Trim()
            }
            if ($pathPart.Contains(' -> ')) {
                $parts = $pathPart -split ' -> '
                $pathPart = [string]$parts[$parts.Length - 1]
            }
            $pathPart = $pathPart.Trim().Trim('"')
            if ([string]::IsNullOrWhiteSpace($pathPart)) {
                $pathPart = '(unknown)'
            }

            if ($statusCode -eq '??') {
                $summary.untracked++
            } elseif ($statusCode.IndexOf('A') -ge 0) {
                $summary.added++
            } else {
                $summary.modified++
            }
            $summary.total++

            $normalizedPath = $pathPart.Replace('\', '/')
            $topKey = if ($normalizedPath.Contains('/')) { $normalizedPath.Substring(0, $normalizedPath.IndexOf('/')) } else { $normalizedPath }
            if ([string]::IsNullOrWhiteSpace($topKey)) { $topKey = '(root)' }
            if (-not $topCounter.ContainsKey($topKey)) {
                $topCounter[$topKey] = 0
            }
            $topCounter[$topKey] = [int]$topCounter[$topKey] + 1
        }

        $summary.top_sources = @(
            $topCounter.GetEnumerator() |
                Sort-Object Value -Descending |
                Select-Object -First 8 |
                ForEach-Object { "{0}:{1}" -f [string]$_.Key, [int]$_.Value }
        )
    } catch {
        return [pscustomobject]$summary
    }

    return [pscustomobject]$summary
}

function Write-RaymanScmSoftLimitWarning {
    param(
        [object]$Summary,
        [int]$SoftLimit = 100
    )

    if ($null -eq $Summary) { return }

    if (-not [bool]$Summary.git_available) {
        Write-Host "ℹ️ [SCM] 当前环境未检测到 git，跳过 SCM 变更统计。" -ForegroundColor DarkCyan
        return
    }
    if (-not [bool]$Summary.inside_git) {
        Write-Host "ℹ️ [SCM] 当前目录不是 Git 工作区，跳过 SCM 变更统计。" -ForegroundColor DarkCyan
        return
    }

    Write-Host ("ℹ️ [SCM] 变更统计: total={0} modified={1} added={2} untracked={3}" -f [int]$Summary.total, [int]$Summary.modified, [int]$Summary.added, [int]$Summary.untracked) -ForegroundColor DarkCyan

    if ([int]$Summary.total -gt $SoftLimit) {
        Write-Host ("⚠️ [SCM] 可见变更数超过软阈值 {0}（当前 {1}）。" -f $SoftLimit, [int]$Summary.total) -ForegroundColor Yellow
        $topSources = @($Summary.top_sources | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($topSources.Count -gt 0) {
            Write-Host ("⚠️ [SCM] 主要来源(top): {0}" -f ($topSources -join ', ')) -ForegroundColor Yellow
        }
    } else {
        Write-Host ("✅ [SCM] 可见变更数在软阈值内（阈值={0}）。" -f $SoftLimit) -ForegroundColor Green
    }
}

function Write-RaymanScmTrackedNoiseDiagnostics {
    param(
        [object]$Analysis,
        [switch]$Block
    )

    if ($null -eq $Analysis) { return }
    if (-not [bool]$Analysis.available -or -not [bool]$Analysis.insideGit) { return }

    $raymanSummary = Format-RaymanScmTrackedNoiseGroups -Groups $Analysis.raymanGroups
    $raymanSamples = Format-RaymanScmTrackedNoiseSamples -Groups $Analysis.raymanGroups
    $advisorySummary = Format-RaymanScmTrackedNoiseGroups -Groups $Analysis.advisoryGroups
    $advisorySamples = Format-RaymanScmTrackedNoiseSamples -Groups $Analysis.advisoryGroups
    $workspaceKind = [string]$Analysis.workspaceKind

    if ($Block -and [bool]$Analysis.raymanBlocked) {
        if ($workspaceKind -eq 'source') {
            Write-Host "❌ [SCM] tracked_rayman_assets_blocked: 检测到 source workspace 的本地/生成资产已被 Git 跟踪。" -ForegroundColor Red
        } else {
            Write-Host "❌ [SCM] tracked_rayman_assets_blocked: 检测到 external workspace 的 Rayman 本地资产已被 Git 跟踪。" -ForegroundColor Red
        }
        if (-not [string]::IsNullOrWhiteSpace($raymanSummary)) {
            Write-Host ("   Rayman 资产分布: {0}" -f $raymanSummary) -ForegroundColor DarkYellow
        }
        if (-not [string]::IsNullOrWhiteSpace($raymanSamples)) {
            Write-Host ("   样例: {0}" -f $raymanSamples) -ForegroundColor DarkYellow
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Analysis.raymanCommand)) {
            Write-Host ("   修复命令: {0}" -f [string]$Analysis.raymanCommand) -ForegroundColor Yellow
        }
        Write-Host "   说明: ignore 规则（.gitignore / .git/info/exclude）仅对 untracked 生效；tracked 文件必须先从 Git 索引移除。" -ForegroundColor DarkYellow
        if ($workspaceKind -eq 'external') {
            Write-Host "   external workspace 只建议提交业务源码、业务文档，以及 .<SolutionName>/ 下的 requirements / agentic 文档；Rayman 生成的 workflow / 配置应保持未跟踪。" -ForegroundColor DarkYellow
        } else {
            Write-Host "   source workspace 可跟踪 authored .Rayman/ 与 .SolutionName，但 state/runtime/cache/temp/backup/package 与编辑器本地配置不应入库。" -ForegroundColor DarkYellow
        }
        Write-Host "   如需明确允许当前仓库跟踪 Rayman 资产，请在 .rayman.env.ps1 中设置 RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS=1。" -ForegroundColor DarkYellow
    } elseif ([int]$Analysis.raymanTrackedCount -gt 0 -and [bool]$Analysis.allowTrackedRaymanAssets) {
        Write-Host ("ℹ️ [SCM] 已显式放行 tracked Rayman assets（RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS=1）: {0}" -f $raymanSummary) -ForegroundColor DarkCyan
    }

    if ([bool]$Analysis.advisoryPresent) {
        Write-Host "⚠️ [SCM] 检测到非 Rayman 常见产物目录已被 Git 跟踪（仅告警，不阻断 setup）。" -ForegroundColor Yellow
        if (-not [string]::IsNullOrWhiteSpace($advisorySummary)) {
            Write-Host ("   目录分布: {0}" -f $advisorySummary) -ForegroundColor DarkYellow
        }
        if (-not [string]::IsNullOrWhiteSpace($advisorySamples)) {
            Write-Host ("   样例: {0}" -f $advisorySamples) -ForegroundColor DarkYellow
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Analysis.advisoryCommand)) {
            Write-Host ("   建议命令: {0}" -f [string]$Analysis.advisoryCommand) -ForegroundColor DarkYellow
        }
    }
}

$setupLogsDir = Join-Path $WorkspaceRoot ".Rayman\logs"
if (-not (Test-Path -LiteralPath $setupLogsDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $setupLogsDir | Out-Null
}
Clear-SetupLogsBeforeRun -LogsDir $setupLogsDir
$setupTs = Get-Date -Format "yyyyMMdd_HHmmss"
$script:SetupLogPath = Join-Path $setupLogsDir ("setup.win.{0}.log" -f $setupTs)
try {
    Start-Transcript -Path $script:SetupLogPath -Force | Out-Null
    $script:SetupTranscriptActive = $true
    Write-Host ("🧾 [setup] 日志: {0}" -f $script:SetupLogPath) -ForegroundColor DarkCyan
    if ($null -ne $workspaceStateGuardResult) {
        if ([bool]$workspaceStateGuardResult.scrubbed) {
            Write-Host ("🧹 [workspace-state] 检测到跨工作区拷贝，已清理 {0} 项（source={1}）。" -f [int]$workspaceStateGuardResult.removed_count, [string]$workspaceStateGuardResult.foreign_workspace_root) -ForegroundColor DarkCyan
        } else {
            Write-Host ("ℹ️ [workspace-state] 已刷新当前工作区 marker: {0}" -f [string]$workspaceStateGuardResult.marker_path) -ForegroundColor DarkCyan
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($workspaceStateGuardError)) {
        Write-Host ("⚠️ [workspace-state] 预清理失败：{0}" -f $workspaceStateGuardError) -ForegroundColor Yellow
    }
} catch {
    Write-Host ("⚠️ [setup] 启动 transcript 失败: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
}

try {
Write-Host ""
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "🚀 开始初始化 Rayman 环境..." -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host ""

# 0. 工作区级用户环境（不放在 .Rayman 内，便于覆盖 .Rayman 后仍保留）
$playwrightScopeProcessOverride = [Environment]::GetEnvironmentVariable('RAYMAN_PLAYWRIGHT_SETUP_SCOPE')
$workspaceEnvFile = Join-Path $WorkspaceRoot ".rayman.env.ps1"
if (-not (Test-Path -LiteralPath $workspaceEnvFile -PathType Leaf)) {
    $workspaceEnvContent = @"
# Rayman workspace-level env (persist across .Rayman replacements)

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_HEARTBEAT_SECONDS)) {
    `$env:RAYMAN_HEARTBEAT_SECONDS = '30'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_HEARTBEAT_VERBOSE)) {
    `$env:RAYMAN_HEARTBEAT_VERBOSE = '1'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_HEARTBEAT_SMART_SILENCE_ENABLED)) {
    `$env:RAYMAN_HEARTBEAT_SMART_SILENCE_ENABLED = '1'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_HEARTBEAT_SILENT_WINDOW_SECONDS)) {
    `$env:RAYMAN_HEARTBEAT_SILENT_WINDOW_SECONDS = '15'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_SANDBOX_HEARTBEAT_SECONDS)) {
    `$env:RAYMAN_SANDBOX_HEARTBEAT_SECONDS = [string]`$env:RAYMAN_HEARTBEAT_SECONDS
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_MCP_HEARTBEAT_SECONDS)) {
    `$env:RAYMAN_MCP_HEARTBEAT_SECONDS = [string]`$env:RAYMAN_HEARTBEAT_SECONDS
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_MEMORY_PYTHON)) {
    `$venvWinPython = Join-Path `$PSScriptRoot '.venv\Scripts\python.exe'
    `$venvPosixPython = Join-Path `$PSScriptRoot '.venv/bin/python'
    if (Test-Path -LiteralPath `$venvWinPython -PathType Leaf) {
        `$env:RAYMAN_MEMORY_PYTHON = `$venvWinPython
    } elseif (Test-Path -LiteralPath `$venvPosixPython -PathType Leaf) {
        `$env:RAYMAN_MEMORY_PYTHON = `$venvPosixPython
    }
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_AUTO_INSTALL_TEST_DEPS)) {
    `$env:RAYMAN_AUTO_INSTALL_TEST_DEPS = '1'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_REQUIRE_TEST_DEPS)) {
    `$env:RAYMAN_REQUIRE_TEST_DEPS = '1'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_SELF_HEAL_AUTO_DEP_INSTALL)) {
    `$env:RAYMAN_SELF_HEAL_AUTO_DEP_INSTALL = '1'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_PLAYWRIGHT_REQUIRE)) {
    `$env:RAYMAN_PLAYWRIGHT_REQUIRE = '1'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_PLAYWRIGHT_BROWSER)) {
    `$env:RAYMAN_PLAYWRIGHT_BROWSER = 'chromium'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_PLAYWRIGHT_SETUP_SCOPE)) {
    `$env:RAYMAN_PLAYWRIGHT_SETUP_SCOPE = 'wsl'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_PLAYWRIGHT_TIMEOUT_SECONDS)) {
    `$env:RAYMAN_PLAYWRIGHT_TIMEOUT_SECONDS = '1800'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_PLAYWRIGHT_AUTO_INSTALL)) {
    `$env:RAYMAN_PLAYWRIGHT_AUTO_INSTALL = '1'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_GIT_SAFECRLF_SUPPRESS)) {
    `$env:RAYMAN_GIT_SAFECRLF_SUPPRESS = '1'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_SETUP_GIT_INIT)) {
    `$env:RAYMAN_SETUP_GIT_INIT = '1'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_SETUP_GITHUB_LOGIN)) {
    `$env:RAYMAN_SETUP_GITHUB_LOGIN = '1'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_SETUP_GITHUB_LOGIN_STRICT)) {
    `$env:RAYMAN_SETUP_GITHUB_LOGIN_STRICT = '0'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_GITHUB_HOST)) {
    `$env:RAYMAN_GITHUB_HOST = 'github.com'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_GITHUB_GIT_PROTOCOL)) {
    `$env:RAYMAN_GITHUB_GIT_PROTOCOL = 'https'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_AUTO_REPAIR_NESTED_RAYMAN)) {
    `$env:RAYMAN_AUTO_REPAIR_NESTED_RAYMAN = '1'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_SANDBOX_OFFLINE_CACHE_ENABLED)) {
    `$env:RAYMAN_SANDBOX_OFFLINE_CACHE_ENABLED = '1'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_SANDBOX_OFFLINE_CACHE_COPY_BROWSERS)) {
    `$env:RAYMAN_SANDBOX_OFFLINE_CACHE_COPY_BROWSERS = '1'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_SANDBOX_OFFLINE_CACHE_REFRESH_HOURS)) {
    `$env:RAYMAN_SANDBOX_OFFLINE_CACHE_REFRESH_HOURS = '24'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_SANDBOX_OFFLINE_CACHE_FORCE)) {
    `$env:RAYMAN_SANDBOX_OFFLINE_CACHE_FORCE = '0'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_MCP_SQLITE_DB_AUTOFIX)) {
    `$env:RAYMAN_MCP_SQLITE_DB_AUTOFIX = '1'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_DOTNET_WINDOWS_PREFERRED)) {
    `$env:RAYMAN_DOTNET_WINDOWS_PREFERRED = '1'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_DOTNET_WINDOWS_STRICT)) {
    `$env:RAYMAN_DOTNET_WINDOWS_STRICT = '0'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_DOTNET_WINDOWS_TIMEOUT_SECONDS)) {
    `$env:RAYMAN_DOTNET_WINDOWS_TIMEOUT_SECONDS = '1800'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_AGENT_DEFAULT_BACKEND)) {
    `$env:RAYMAN_AGENT_DEFAULT_BACKEND = 'local'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_AGENT_FALLBACK_ORDER)) {
    `$env:RAYMAN_AGENT_FALLBACK_ORDER = 'codex,local'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_AGENT_CLOUD_ENABLED)) {
    `$env:RAYMAN_AGENT_CLOUD_ENABLED = '0'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_AGENT_PIPELINE)) {
    `$env:RAYMAN_AGENT_PIPELINE = 'planner_v1'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_AGENT_DOC_GATE)) {
    `$env:RAYMAN_AGENT_DOC_GATE = '1'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_AGENT_OPENAI_OPTIONAL)) {
    `$env:RAYMAN_AGENT_OPENAI_OPTIONAL = 'auto'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_AGENT_CAPABILITIES_ENABLED)) {
    `$env:RAYMAN_AGENT_CAPABILITIES_ENABLED = '1'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_AGENT_CAP_OPENAI_DOCS_ENABLED)) {
    `$env:RAYMAN_AGENT_CAP_OPENAI_DOCS_ENABLED = '1'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_AGENT_CAP_WEB_AUTO_TEST_ENABLED)) {
    `$env:RAYMAN_AGENT_CAP_WEB_AUTO_TEST_ENABLED = '1'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_AGENT_CAP_WINAPP_AUTO_TEST_ENABLED)) {
    `$env:RAYMAN_AGENT_CAP_WINAPP_AUTO_TEST_ENABLED = '1'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_AGENT_POLICY_BYPASS)) {
    `$env:RAYMAN_AGENT_POLICY_BYPASS = '0'
}

if (`$null -eq `$env:RAYMAN_AGENT_CLOUD_WHITELIST) {
    `$env:RAYMAN_AGENT_CLOUD_WHITELIST = ''
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_WINAPP_REQUIRE)) {
    `$env:RAYMAN_WINAPP_REQUIRE = '0'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_WINAPP_DEFAULT_TIMEOUT_MS)) {
    `$env:RAYMAN_WINAPP_DEFAULT_TIMEOUT_MS = '15000'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_FIRST_PASS_WINDOW)) {
    `$env:RAYMAN_FIRST_PASS_WINDOW = '20'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_REVIEW_LOOP_MAX_ROUNDS)) {
    `$env:RAYMAN_REVIEW_LOOP_MAX_ROUNDS = '2'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_ALERT_SURFACE)) {
    `$env:RAYMAN_ALERT_SURFACE = 'log'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_ALERT_DONE_ENABLED)) {
    `$env:RAYMAN_ALERT_DONE_ENABLED = '0'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_ALERT_TTS_ENABLED)) {
    `$env:RAYMAN_ALERT_TTS_ENABLED = '0'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_ALERT_TTS_DONE_ENABLED)) {
    `$env:RAYMAN_ALERT_TTS_DONE_ENABLED = '0'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_AUTO_START_ATTENTION_WATCH_ENABLED)) {
    `$env:RAYMAN_AUTO_START_ATTENTION_WATCH_ENABLED = '0'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_ALERT_WATCH_ON_PROMPT_ENABLED)) {
    `$env:RAYMAN_ALERT_WATCH_ON_PROMPT_ENABLED = '0'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_AUTO_SAVE_WATCH_ENABLED)) {
    `$env:RAYMAN_AUTO_SAVE_WATCH_ENABLED = '0'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_VSCODE_BOOTSTRAP_PROFILE)) {
    `$env:RAYMAN_VSCODE_BOOTSTRAP_PROFILE = 'conservative'
}

if (`$null -eq `$env:RAYMAN_SETUP_POST_CHECK_MODE) {
    `$env:RAYMAN_SETUP_POST_CHECK_MODE = ''
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_SCM_CHANGE_SOFT_LIMIT)) {
    `$env:RAYMAN_SCM_CHANGE_SOFT_LIMIT = '100'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS)) {
    `$env:RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS = '0'
}
"@
    Set-Content -Path $workspaceEnvFile -Value $workspaceEnvContent -Encoding UTF8
    Write-Host "✅ 已生成 .rayman.env.ps1（工作区持久配置）" -ForegroundColor Green
}

Ensure-WorkspaceEnvDefaults -EnvFilePath $workspaceEnvFile

try {
    . $workspaceEnvFile
    Write-Host "✅ 已加载 .rayman.env.ps1（全局心跳: $($env:RAYMAN_HEARTBEAT_SECONDS)s）" -ForegroundColor Green
} catch {
    Write-Host "⚠️ 加载 .rayman.env.ps1 失败: $($_.Exception.Message)" -ForegroundColor Yellow
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_MCP_SQLITE_DB_AUTOFIX)) {
    $env:RAYMAN_MCP_SQLITE_DB_AUTOFIX = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AUTO_INSTALL_TEST_DEPS)) {
    $env:RAYMAN_AUTO_INSTALL_TEST_DEPS = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_REQUIRE_TEST_DEPS)) {
    $env:RAYMAN_REQUIRE_TEST_DEPS = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_SELF_HEAL_AUTO_DEP_INSTALL)) {
    $env:RAYMAN_SELF_HEAL_AUTO_DEP_INSTALL = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_PLAYWRIGHT_REQUIRE)) {
    $env:RAYMAN_PLAYWRIGHT_REQUIRE = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_PLAYWRIGHT_AUTO_INSTALL)) {
    $env:RAYMAN_PLAYWRIGHT_AUTO_INSTALL = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_GIT_SAFECRLF_SUPPRESS)) {
    $env:RAYMAN_GIT_SAFECRLF_SUPPRESS = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_SETUP_GIT_INIT)) {
    $env:RAYMAN_SETUP_GIT_INIT = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_SETUP_GITHUB_LOGIN)) {
    $env:RAYMAN_SETUP_GITHUB_LOGIN = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_SETUP_GITHUB_LOGIN_STRICT)) {
    $env:RAYMAN_SETUP_GITHUB_LOGIN_STRICT = '0'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_GITHUB_HOST)) {
    $env:RAYMAN_GITHUB_HOST = 'github.com'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_GITHUB_GIT_PROTOCOL)) {
    $env:RAYMAN_GITHUB_GIT_PROTOCOL = 'https'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AUTO_REPAIR_NESTED_RAYMAN)) {
    $env:RAYMAN_AUTO_REPAIR_NESTED_RAYMAN = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_SANDBOX_OFFLINE_CACHE_ENABLED)) {
    $env:RAYMAN_SANDBOX_OFFLINE_CACHE_ENABLED = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_SANDBOX_OFFLINE_CACHE_COPY_BROWSERS)) {
    $env:RAYMAN_SANDBOX_OFFLINE_CACHE_COPY_BROWSERS = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_SANDBOX_OFFLINE_CACHE_REFRESH_HOURS)) {
    $env:RAYMAN_SANDBOX_OFFLINE_CACHE_REFRESH_HOURS = '24'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_SANDBOX_OFFLINE_CACHE_FORCE)) {
    $env:RAYMAN_SANDBOX_OFFLINE_CACHE_FORCE = '0'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_DOTNET_WINDOWS_PREFERRED)) {
    $env:RAYMAN_DOTNET_WINDOWS_PREFERRED = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_DOTNET_WINDOWS_STRICT)) {
    $env:RAYMAN_DOTNET_WINDOWS_STRICT = '0'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_DOTNET_WINDOWS_TIMEOUT_SECONDS)) {
    $env:RAYMAN_DOTNET_WINDOWS_TIMEOUT_SECONDS = '1800'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AGENT_DEFAULT_BACKEND)) {
    $env:RAYMAN_AGENT_DEFAULT_BACKEND = 'local'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AGENT_FALLBACK_ORDER)) {
    $env:RAYMAN_AGENT_FALLBACK_ORDER = 'codex,local'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AGENT_CLOUD_ENABLED)) {
    $env:RAYMAN_AGENT_CLOUD_ENABLED = '0'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AGENT_PIPELINE)) {
    $env:RAYMAN_AGENT_PIPELINE = 'planner_v1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AGENT_DOC_GATE)) {
    $env:RAYMAN_AGENT_DOC_GATE = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AGENT_OPENAI_OPTIONAL)) {
    $env:RAYMAN_AGENT_OPENAI_OPTIONAL = 'auto'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AGENT_CAPABILITIES_ENABLED)) {
    $env:RAYMAN_AGENT_CAPABILITIES_ENABLED = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AGENT_CAP_OPENAI_DOCS_ENABLED)) {
    $env:RAYMAN_AGENT_CAP_OPENAI_DOCS_ENABLED = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AGENT_CAP_WEB_AUTO_TEST_ENABLED)) {
    $env:RAYMAN_AGENT_CAP_WEB_AUTO_TEST_ENABLED = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AGENT_CAP_WINAPP_AUTO_TEST_ENABLED)) {
    $env:RAYMAN_AGENT_CAP_WINAPP_AUTO_TEST_ENABLED = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AGENT_POLICY_BYPASS)) {
    $env:RAYMAN_AGENT_POLICY_BYPASS = '0'
}
if ($null -eq $env:RAYMAN_AGENT_CLOUD_WHITELIST) {
    $env:RAYMAN_AGENT_CLOUD_WHITELIST = ''
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_WINAPP_REQUIRE)) {
    $env:RAYMAN_WINAPP_REQUIRE = '0'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_WINAPP_DEFAULT_TIMEOUT_MS)) {
    $env:RAYMAN_WINAPP_DEFAULT_TIMEOUT_MS = '15000'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_FIRST_PASS_WINDOW)) {
    $env:RAYMAN_FIRST_PASS_WINDOW = '20'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_REVIEW_LOOP_MAX_ROUNDS)) {
    $env:RAYMAN_REVIEW_LOOP_MAX_ROUNDS = '2'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_ALERT_SURFACE)) {
    $env:RAYMAN_ALERT_SURFACE = 'log'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_ALERT_DONE_ENABLED)) {
    $env:RAYMAN_ALERT_DONE_ENABLED = '0'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_ALERT_TTS_ENABLED)) {
    $env:RAYMAN_ALERT_TTS_ENABLED = '0'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_ALERT_TTS_DONE_ENABLED)) {
    $env:RAYMAN_ALERT_TTS_DONE_ENABLED = '0'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AUTO_START_ATTENTION_WATCH_ENABLED)) {
    $env:RAYMAN_AUTO_START_ATTENTION_WATCH_ENABLED = '0'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_ALERT_WATCH_ON_PROMPT_ENABLED)) {
    $env:RAYMAN_ALERT_WATCH_ON_PROMPT_ENABLED = '0'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AUTO_SAVE_WATCH_ENABLED)) {
    $env:RAYMAN_AUTO_SAVE_WATCH_ENABLED = '0'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_VSCODE_BOOTSTRAP_PROFILE)) {
    $env:RAYMAN_VSCODE_BOOTSTRAP_PROFILE = 'conservative'
}
if ($null -eq $env:RAYMAN_SETUP_POST_CHECK_MODE) {
    $env:RAYMAN_SETUP_POST_CHECK_MODE = ''
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_SCM_CHANGE_SOFT_LIMIT)) {
    $env:RAYMAN_SCM_CHANGE_SOFT_LIMIT = '100'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS)) {
    $env:RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS = '0'
}

$resetAgentMemoryOnCopy = ($null -ne $workspaceStateGuardResult -and [bool]$workspaceStateGuardResult.scrubbed)
Invoke-SetupLegacyMemoryCleanup -WorkspaceRoot $WorkspaceRoot -ResetAgentMemoryData:$resetAgentMemoryOnCopy | Out-Null
$script:ScmTrackedNoiseAnalysis = $null
if (-not $raymanCommonImported) {
    if (Test-Path -LiteralPath $raymanCommonPath -PathType Leaf) {
        . $raymanCommonPath
        $raymanCommonImported = $true
    } else {
        Write-Host ("⚠️ 未找到 common.ps1，跳过 nested .Rayman 自动修复: {0}" -f $raymanCommonPath) -ForegroundColor Yellow
    }
}
if ($raymanCommonImported) {
    [void](Repair-RaymanNestedDir -WorkspaceRoot $WorkspaceRoot)
    $script:ScmTrackedNoiseAnalysis = Get-RaymanScmTrackedNoiseAnalysis -WorkspaceRoot $WorkspaceRoot
    if ($null -ne $script:ScmTrackedNoiseAnalysis -and [bool]$script:ScmTrackedNoiseAnalysis.raymanBlocked) {
        Write-RaymanScmTrackedNoiseDiagnostics -Analysis $script:ScmTrackedNoiseAnalysis -Block
        throw 'tracked_rayman_assets_blocked'
    }
}

$script:GitBootstrapReport = $null
$script:GitBootstrapReportPath = Join-Path (Join-Path $WorkspaceRoot '.Rayman\runtime') 'git.bootstrap.last.json'
if ($raymanCommonImported -and (Get-Command Invoke-RaymanGitBootstrap -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "===== Git Bootstrap =====" -ForegroundColor Cyan
    $gitBootstrapOptions = Get-RaymanSetupGitBootstrapOptions -WorkspaceRoot $WorkspaceRoot
    $script:GitBootstrapReport = Invoke-RaymanGitBootstrap `
        -WorkspaceRoot $WorkspaceRoot `
        -GitInitEnabled ([bool]$gitBootstrapOptions.git_init_enabled) `
        -GitHubLoginEnabled ([bool]$gitBootstrapOptions.github_login_enabled) `
        -GitHubLoginStrict ([bool]$gitBootstrapOptions.github_login_strict) `
        -GitHubHost ([string]$gitBootstrapOptions.github_host) `
        -GitProtocol ([string]$gitBootstrapOptions.github_git_protocol) `
        -AllowInteractiveGitHubLogin ([bool]$gitBootstrapOptions.allow_interactive_github_login) `
        -BeforeGitHubLogin {
            Invoke-RaymanAttentionAlert -Kind 'manual' -Reason '需要完成 GitHub 登录以启用 Git 远程认证。' -WorkspaceRoot $WorkspaceRoot | Out-Null
        }

    try {
        $gitBootstrapRuntimeDir = Split-Path -Parent $script:GitBootstrapReportPath
        if (-not (Test-Path -LiteralPath $gitBootstrapRuntimeDir -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $gitBootstrapRuntimeDir | Out-Null
        }
        $script:GitBootstrapReport | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:GitBootstrapReportPath -Encoding UTF8
    } catch {
        Write-Host ("⚠️ [Git Bootstrap] 无法写入报告: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }

    if (-not [bool]$script:GitBootstrapReport.git_available) {
        Write-Host "⚠️ [Git] 未检测到 git，可继续 setup，但当前工作区暂不能直接使用 Git。" -ForegroundColor Yellow
    } elseif ([bool]$script:GitBootstrapReport.git_initialized) {
        Write-Host ("✅ [Git] 已初始化本地仓库（{0}）" -f [string]$script:GitBootstrapReport.git_init_detail) -ForegroundColor Green
    } elseif ([bool]$script:GitBootstrapReport.git_repo_detected) {
        Write-Host "ℹ️ [Git] 已检测到现有 Git 仓库，跳过初始化。" -ForegroundColor DarkCyan
    } else {
        Write-Host ("⚠️ [Git] 未完成自动初始化（detail={0}）。" -f [string]$script:GitBootstrapReport.git_init_detail) -ForegroundColor Yellow
    }

    switch ([string]$script:GitBootstrapReport.github_auth_status) {
        'authenticated' {
            if ([bool]$script:GitBootstrapReport.github_setup_git_success) {
                if ([bool]$script:GitBootstrapReport.github_login_attempted) {
                    Write-Host ("✅ [GitHub] 已完成登录并执行 auth setup-git（{0}）" -f [string]$script:GitBootstrapReport.github_cli) -ForegroundColor Green
                } else {
                    Write-Host ("✅ [GitHub] 已检测到登录状态并执行 auth setup-git（{0}）" -f [string]$script:GitBootstrapReport.github_cli) -ForegroundColor Green
                }
            } else {
                Write-Host ("⚠️ [GitHub] 已登录，但 auth setup-git 失败（{0}）。" -f [string]$script:GitBootstrapReport.github_cli) -ForegroundColor Yellow
            }
        }
        'skipped' {
            switch ([string]$script:GitBootstrapReport.skipped_reason) {
                'github_login_disabled' {
                    Write-Host "ℹ️ [GitHub] 已按配置跳过登录（RAYMAN_SETUP_GITHUB_LOGIN=0）。" -ForegroundColor DarkCyan
                }
                'github_login_noninteractive' {
                    Write-Host "ℹ️ [GitHub] 当前为非交互场景，已跳过登录。" -ForegroundColor DarkCyan
                }
                'github_cli_missing' {
                    Write-Host "⚠️ [GitHub] 未找到 GitHub CLI，已跳过登录与 auth setup-git。" -ForegroundColor Yellow
                }
            }
        }
        'unauthenticated' {
            Write-Host ("⚠️ [GitHub] 当前仍未登录（{0}）。" -f [string]$script:GitBootstrapReport.github_cli) -ForegroundColor Yellow
        }
        'unknown' {
            Write-Host ("⚠️ [GitHub] 无法确认登录状态（{0}）。" -f [string]$script:GitBootstrapReport.github_cli) -ForegroundColor Yellow
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$script:GitBootstrapReport.repair_action)) {
        Write-Host ("   修复命令/动作: {0}" -f [string]$script:GitBootstrapReport.repair_action) -ForegroundColor DarkYellow
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:GitBootstrapReport.error_message)) {
        Write-Host ("   诊断信息: {0}" -f [string]$script:GitBootstrapReport.error_message) -ForegroundColor DarkYellow
    }

    if ([bool]$script:GitBootstrapReport.should_block_setup) {
        Write-Host "❌ [Git Bootstrap] GitHub 登录严格模式未通过，setup 已停止。" -ForegroundColor Red
        Write-Host ("   报告路径: {0}" -f $script:GitBootstrapReportPath) -ForegroundColor Yellow
        Exit-RaymanSetup -ExitCode 3 -Reason 'git-bootstrap-blocked'
    }
}

# 1. 自动检测 SolutionName
$solutionName = "当前项目"
$slnxFile = Get-ChildItem -Path $WorkspaceRoot -Filter "*.slnx" -File -ErrorAction SilentlyContinue |
    Sort-Object Name |
    Select-Object -First 1
if ($null -ne $slnxFile) {
    $solutionName = [System.IO.Path]::GetFileNameWithoutExtension($slnxFile.Name)
    Write-Host "✅ 检测到 .slnx 文件，项目名设为: $solutionName" -ForegroundColor Green
} else {
    $slnFile = Get-ChildItem -Path $WorkspaceRoot -Filter "*.sln" -File -ErrorAction SilentlyContinue |
        Sort-Object Name |
        Select-Object -First 1
    if ($null -ne $slnFile) {
        $solutionName = [System.IO.Path]::GetFileNameWithoutExtension($slnFile.Name)
        Write-Host "✅ 检测到 .sln 文件，项目名设为: $solutionName" -ForegroundColor Green
    } else {
        $solutionName = Split-Path -Leaf $WorkspaceRoot
        Write-Host "⚠️ 未检测到 .slnx 或 .sln 文件，使用文件夹名作为项目名: $solutionName" -ForegroundColor Yellow
    }
}

$solutionNameFile = Join-Path $WorkspaceRoot ".SolutionName"
$currentSolutionName = ''
$hasCurrentSolutionName = $false
if (Test-Path -LiteralPath $solutionNameFile -PathType Leaf) {
    try {
        $currentRaw = Get-Content -LiteralPath $solutionNameFile -Raw -Encoding UTF8 -ErrorAction Stop
        $currentSolutionName = Normalize-SetupText -Value $currentRaw
        $hasCurrentSolutionName = $true
    } catch {}
}

$targetSolutionName = Normalize-SetupText -Value $solutionName
if ($hasCurrentSolutionName -and ($currentSolutionName -eq $targetSolutionName)) {
    Write-Host "ℹ️ .SolutionName 已是最新，跳过写入。" -ForegroundColor DarkCyan
} else {
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($solutionNameFile, $solutionName, $utf8NoBom)
        Write-Host "✅ 已生成 .SolutionName" -ForegroundColor Green
    } catch {
        Write-Host "⚠️ 无法直接写入 .SolutionName, 尝试 Set-Content... $_" -ForegroundColor Yellow
        try {
            Set-Content -Path $solutionNameFile -Value $solutionName -Encoding UTF8 -Force
            Write-Host "✅ 已通过 Set-Content 覆盖 .SolutionName" -ForegroundColor Green
        } catch {
            Write-Host "⚠️ 无法更新 .SolutionName（已忽略，可能文件被占用）: $_" -ForegroundColor Yellow
        }
    }
}

# 1.1 requirements 结构补齐（统一到 .<SolutionName>/ 布局）
Sync-RaymanAssetsFromDistIfMissing -WorkspaceRoot $WorkspaceRoot
Normalize-WorkspaceMemoryEnv -WorkspaceRoot $WorkspaceRoot
Invoke-EnsureRequirementsLayout -WorkspaceRoot $WorkspaceRoot

# 2. 生成 .github/copilot-instructions.md
$githubDir = Join-Path $WorkspaceRoot ".github"
if (-not (Test-Path -LiteralPath $githubDir)) {
    New-Item -ItemType Directory -Force -Path $githubDir | Out-Null
}

$instructionsFile = Join-Path $githubDir "copilot-instructions.md"
$instructionsContent = @"
# Rayman AI 助手自定义指令

详细编码约定与文件类型规则请优先参考：`.github/instructions/general.instructions.md`、`.github/instructions/backend.instructions.md`、`.github/instructions/frontend.instructions.md`。

复杂任务开始前，请优先读取 `.Rayman/CONTEXT.md` 与 `.Rayman/context/skills.auto.md`；若它们缺失或过期，请先运行“更新上下文”。

Rayman 会自动生成并维护工作区级 `.codex/config.toml`；Rayman-managed slice 包括 capability MCP、`project_doc` fallback、`profiles` 与 `subagents`。不要把这些 Codex 专用 capability 混入 `.Rayman/mcp/mcp_servers.json`。

Rayman 还会维护 `.github/agents/*.agent.md`、`.github/skills/*/SKILL.md` 与 `.github/prompts/*.prompt.md`；它们是 Copilot/Codex 共享的 capability 资产，修改时必须与 `dispatch`、`review_loop` 和 capability report 保持一致。

当任务涉及 OpenAI 产品、API、模型、SDK 或官方文档时，请优先使用 OpenAI Docs MCP，而不是依赖过期记忆。

当任务涉及网页自动化、浏览器排障、页面录制、E2E 或 UI 测试时，请优先使用 Playwright MCP；若当前环境拿不到 MCP，则先走 `.Rayman/rayman.ps1 ensure-playwright`，失败时再降级到 `.Rayman/rayman.ps1 pwa-test`。

当任务涉及桌面自动化、UIA、WinForms、WPF 或 MAUI(Windows) 排障 / 测试时，请优先使用 Rayman WinApp MCP；若当前环境拿不到 MCP，则先走 `.Rayman/rayman.ps1 ensure-winapp`，失败时再降级到 `.Rayman/rayman.ps1 winapp-test`。

Copilot 环境如果没有等价 MCP，不要伪造能力；按 Rayman 已提供的命令入口做最佳努力降级即可。
GitHub.com 的 Copilot Memory、model picker / Auto model selection 属于平台能力；Rayman 只负责文档和检测，不在仓库内伪装成已托管能力。

当用户在聊天框中输入单个问号（`?` 或 `？`）时，请读取 `.Rayman/commands.txt` 文件的内容，并将其作为可用命令列表展示给用户。

当用户输入 "初始化" 或 "运行 setup" 时，请运行 `.Rayman/setup.ps1` 脚本来初始化环境。
setup 默认会准备本地 Git 仓库；交互式场景下会尝试 GitHub 登录并执行 `gh auth setup-git`，但不会自动创建 remote 仓库。

当用户输入 "WSL 安装依赖" 或 "安装 WSL 依赖" 时，请运行 `.Rayman/scripts/utils/ensure_wsl_deps.ps1` 脚本，它会在 Ubuntu(WSL2) 中自动安装 `pwsh`、通知与语音依赖（需要 sudo 密码）。

当用户输入 "Windows 依赖检查" 或 "安装 Windows 依赖" 时，请运行 `.Rayman/scripts/utils/ensure_win_deps.ps1` 脚本，检查并提示 Windows 侧常用工具（如 git/wsl/dotnet/node/python）。

当用户输入 "保存状态" 或 "暂停" 时，请运行 `.Rayman/scripts/state/save_state.ps1` 脚本，它会生成 Markdown 状态并自动执行 Git Stash 暂存代码。
当用户输入 "继续" 时，请运行 `.Rayman/scripts/state/resume_state.ps1` 脚本，它会恢复 Git Stash 并清理状态文件。

当用户输入 "自愈" 或 "测试并修复" 时，请运行 `.Rayman/scripts/repair/run_tests_and_fix.ps1` 脚本。如果报错，请读取 `.Rayman/state/last_error.log` 并自动尝试修复代码。

当用户输入 "更新上下文" 时，请运行 `.Rayman/scripts/utils/generate_context.ps1` 脚本。该脚本会刷新 `.Rayman/CONTEXT.md` 与 `.Rayman/context/skills.auto.md`；在执行复杂任务前，请优先读取它们了解项目结构与建议能力。

当用户输入 "拷贝后自检"、"拷贝初始化自检" 或 "自检初始化" 时，请运行 `.Rayman/rayman.ps1 copy-self-check`，用于验证 `.Rayman` 拷贝到新项目后是否能成功初始化。

当用户输入 "严格自检"、"出厂验收" 或 "严格模式自检" 时，请运行 `.Rayman/rayman.ps1 copy-self-check --strict`，用于执行包含 Release Gate 的一键出厂验收。

当用户输入 "严格自检保留现场" 或 "出厂验收保留现场" 时，请运行 `.Rayman/rayman.ps1 copy-self-check --strict --scope wsl --keep-temp --open-on-fail`，用于失败后自动保留并打开临时验收目录。

当用户输入 "停止监听" 或 "停止后台服务" 时，请运行 `.Rayman/scripts/watch/stop_background_watchers.ps1` 脚本来停止所有后台监听进程。

当用户输入 "清理缓存" 或 "一键清理缓存" 时，请运行 `.Rayman/scripts/utils/clear_cache.ps1` 脚本。
当用户输入 "一键部署" 时，请运行 `.Rayman/scripts/deploy/deploy.ps1` 脚本。如果用户指定了项目名（如 "一键部署 WebApp"），请将项目名作为 `-ProjectName` 参数传递给脚本。

【重要】当你在执行任务过程中，遇到需要用户手动确认、输入信息或进行人机交互时，请务必先运行 `.Rayman/scripts/utils/request_attention.ps1` 脚本，通过语音提醒用户。你可以通过 `-Message` 参数传递具体的提示内容，例如：`.Rayman/scripts/utils/request_attention.ps1 -Message "需要您确认部署配置"`。

其余通用治理、输出、验证与回滚要求，以 `AGENTS.md`、`.Rayman/CONTEXT.md`、`.Rayman/README.md` 和 `.Rayman/config/*.json` 为准；避免在本文件重复堆叠长篇规则。
"@

Set-Content -Path $instructionsFile -Value $instructionsContent -Encoding UTF8
Write-Host "✅ 已生成 .github/copilot-instructions.md" -ForegroundColor Green

# 2.1 生成 .cursorrules (Cursor/Codex)
$cursorRulesFile = Join-Path $WorkspaceRoot ".cursorrules"
Set-Content -Path $cursorRulesFile -Value $instructionsContent -Encoding UTF8
Write-Host "✅ 已生成 .cursorrules (Codex/Cursor 支持)" -ForegroundColor Green

# 2.2 生成 .clinerules (Cline/Roo Code)
$clineRulesFile = Join-Path $WorkspaceRoot ".clinerules"
Set-Content -Path $clineRulesFile -Value $instructionsContent -Encoding UTF8
Write-Host "✅ 已生成 .clinerules (Cline/Roo Code 支持)" -ForegroundColor Green

# 2.3 补齐 Agent 资产（router/policy/config + GitHub instructions/prompts/workflow）
$ensureAgentAssetsScript = Join-Path $WorkspaceRoot ".Rayman\scripts\agents\ensure_agent_assets.ps1"
if (Test-Path -LiteralPath $ensureAgentAssetsScript -PathType Leaf) {
    try {
        & $ensureAgentAssetsScript -WorkspaceRoot $WorkspaceRoot | Out-Host
    } catch {
        Write-Host ("⚠️ [agent-assets] 自动补齐失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
} else {
    Write-Host ("⚠️ [agent-assets] 缺少脚本：{0}" -f $ensureAgentAssetsScript) -ForegroundColor Yellow
}

# 2.4 生成上下文与自动 skills（供 Copilot/Codex/Agent 读取）
$generateContextScript = Join-Path $WorkspaceRoot ".Rayman\scripts\utils\generate_context.ps1"
if (-not (Test-Path -LiteralPath $generateContextScript -PathType Leaf)) {
    Write-Host ("⚠️ [context] 缺少脚本：{0}" -f $generateContextScript) -ForegroundColor Yellow
}

# 3. 初始化高级模块 (Agent Memory, MCP)
$skipAdvancedModules = Get-EnvBoolCompat -Name 'RAYMAN_SETUP_SKIP_ADVANCED_MODULES' -Default $false
if ($skipAdvancedModules) {
    Write-Host "⏭️ [setup] 已按环境变量跳过高级模块初始化（RAYMAN_SETUP_SKIP_ADVANCED_MODULES=1）" -ForegroundColor Yellow
} else {
    Write-Host "🧠 [Agent Memory] 正在初始化本地记忆..." -ForegroundColor Cyan
    $memoryBootstrapScript = Join-Path $WorkspaceRoot ".Rayman\scripts\memory\memory_bootstrap.ps1"
    $memoryManageScript = Join-Path $WorkspaceRoot ".Rayman\scripts\memory\manage_memory.ps1"
    $memoryDecisionSummary = "未执行（Agent Memory 脚本不存在）"
    if ((Test-Path -LiteralPath $memoryBootstrapScript -PathType Leaf) -and (Test-Path -LiteralPath $memoryManageScript -PathType Leaf)) {
        try {
            $memoryProbeRaw = & $memoryBootstrapScript -WorkspaceRoot $WorkspaceRoot -Action ensure -Prewarm -Json
            $memoryProbeText = ($memoryProbeRaw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
            $memoryProbe = $memoryProbeText | ConvertFrom-Json -ErrorAction Stop
            if ([bool]$memoryProbe.Success) {
                $memoryDecisionSummary = "bootstrap ready; backend=$([string]$memoryProbe.SearchBackend); status=$([string]$memoryProbe.StatusPath)"
                Write-Host ("✅ [Agent Memory] 预热完成（解释器: {0}）" -f [string]$memoryProbe.PythonLabel) -ForegroundColor Green
            } else {
                $memoryDecisionSummary = [string]$memoryProbe.Message
                Write-Host ("⚠️ [Agent Memory] 预热提示：{0}" -f [string]$memoryProbe.Message) -ForegroundColor Yellow
            }
        } catch {
            $memoryDecisionSummary = $_.Exception.Message
            Write-Host ("⚠️ [Agent Memory] 预热执行失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    } else {
        Write-Host "⚠️ [Agent Memory] 缺少 memory_bootstrap.ps1 或 manage_memory.ps1，跳过 Agent Memory 预热。" -ForegroundColor Yellow
    }
    Write-Host "🧾 [Agent Memory] 本次策略：$memoryDecisionSummary" -ForegroundColor DarkCyan

    $McpScript = Join-Path $WorkspaceRoot ".Rayman\scripts\mcp\manage_mcp.ps1"
    if (Test-Path $McpScript) {
        Write-Host "🧰 [MCP] 正在规范化 mcp_servers.json（可移植路径）..." -ForegroundColor Cyan
        Reset-LastExitCodeCompat
        & $McpScript -Action normalize -Persist -CreateBackup
        $mcpNormalizeExitCode = Get-LastExitCodeCompat -Default 0
        if ($mcpNormalizeExitCode -ne 0) {
            throw ("MCP 配置规范化失败（exit={0}）" -f $mcpNormalizeExitCode)
        }

        Write-Host "🔌 [MCP] 正在启动 MCP 服务器..." -ForegroundColor Cyan
        & $McpScript -Action start
    }

    $agentCapabilitiesScript = Join-Path $WorkspaceRoot ".Rayman\scripts\agents\ensure_agent_capabilities.ps1"
    if (Test-Path -LiteralPath $agentCapabilitiesScript -PathType Leaf) {
        Write-Host "🧩 [Agent Capabilities] 正在同步 Codex/OpenAI Docs/Playwright 能力..." -ForegroundColor Cyan
        Reset-LastExitCodeCompat
        & $agentCapabilitiesScript -Action sync -WorkspaceRoot $WorkspaceRoot | Out-Host
        $agentCapabilityExitCode = Get-LastExitCodeCompat -Default 0
        if ($agentCapabilityExitCode -ne 0) {
            throw ("Agent capability sync 失败（exit={0}）" -f $agentCapabilityExitCode)
        }
    } else {
        Write-Host ("⚠️ [Agent Capabilities] 缺少脚本：{0}" -f $agentCapabilitiesScript) -ForegroundColor Yellow
    }
}

if (Test-Path -LiteralPath $generateContextScript -PathType Leaf) {
    try {
        & $generateContextScript -WorkspaceRoot $WorkspaceRoot | Out-Host
    } catch {
        Write-Host ("⚠️ [context] 自动生成上下文失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

# 4. 生成或更新 .vscode/tasks.json
$vscodeDir = Join-Path $WorkspaceRoot ".vscode"
if (-not (Test-Path -LiteralPath $vscodeDir)) {
    New-Item -ItemType Directory -Force -Path $vscodeDir | Out-Null
}

$tasksFile = Join-Path $vscodeDir "tasks.json"
$script:RaymanTaskDegradationNotes = New-Object 'System.Collections.Generic.List[string]'

function Get-RaymanMissingTaskAssets {
    param([string[]]$RequiredRelPaths)

    $missing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($relPath in @($RequiredRelPaths)) {
        if ([string]::IsNullOrWhiteSpace($relPath)) { continue }
        $normalizedRelPath = $relPath -replace '/', '\'
        $absPath = Join-Path $WorkspaceRoot $normalizedRelPath
        if (-not (Test-Path -LiteralPath $absPath -PathType Leaf)) {
            [void]$missing.Add($relPath)
        }
    }
    return @($missing)
}

function Add-RaymanTaskDegradationNote {
    param(
        [string]$Label,
        [string]$Scope,
        [string[]]$MissingRelPaths
    )

    $detail = if ($MissingRelPaths.Count -gt 0) {
        "missing: " + ($MissingRelPaths -join ', ')
    } else {
        "degraded"
    }
    [void]$script:RaymanTaskDegradationNotes.Add(("{0} [{1}] -> {2}" -f $Label, $Scope, $detail))
}

function New-RaymanNoOpPowerShellArgs {
    param(
        [string]$Label,
        [string]$Scope,
        [string[]]$MissingRelPaths
    )

    $reason = if ($MissingRelPaths.Count -gt 0) {
        "missing: " + ($MissingRelPaths -join ', ')
    } else {
        "degraded"
    }
    $message = "⚠️ [Rayman task] $Label 已降级为 no-op（$Scope, $reason）"
    $escapedMessage = $message.Replace("'", "''")
    $commandText = "Write-Host '$escapedMessage' -ForegroundColor Yellow; exit 0"
    return @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $commandText)
}

function New-RaymanNoOpLinuxArgs {
    param(
        [string]$Label,
        [string]$Scope,
        [string[]]$MissingRelPaths
    )

    $reason = if ($MissingRelPaths.Count -gt 0) {
        "missing: " + ($MissingRelPaths -join ', ')
    } else {
        "degraded"
    }
    $message = "⚠️ [Rayman task] $Label 已降级为 no-op（$Scope, $reason）"
    $escapedMessage = $message.Replace('\', '\\').Replace('"', '\"').Replace('$', '\$').Replace('`', '\`')
    $commandText = 'echo "' + $escapedMessage + '"; exit 0'
    return @("-lc", $commandText)
}

function Normalize-RaymanTaskCommand([string]$Command) {
    if ([string]::IsNullOrWhiteSpace($Command)) { return $Command }
    if ($Command -ieq "powershell") {
        return "powershell.exe"
    }
    return $Command
}

function New-RaymanTaskWithFallback {
    param(
        [string]$Label,
        [string]$Detail = "",
        [string]$Type = "shell",
        [string]$Command = "powershell.exe",
        [string[]]$ArgumentList = @(),
        [hashtable]$Linux = $null,
        [string[]]$RequiredRelPaths = @(),
        [string[]]$LinuxRequiredRelPaths = @(),
        [string]$RunOn = "",
        [string]$Reveal = "always",
        [string]$Panel = "shared",
        [bool]$Clear = $false,
        [object]$Group = $null,
        [string[]]$DependsOn = @(),
        [string]$DependsOrder = ""
    )

    $effectiveCommand = Normalize-RaymanTaskCommand -Command $Command
    $effectiveArgs = @($ArgumentList)
    $effectiveLinux = $null
    if ($null -ne $Linux) {
        $effectiveLinux = @{}
        foreach ($k in $Linux.Keys) {
            $effectiveLinux[$k] = $Linux[$k]
        }
    }

    $missingHostAssets = @(Get-RaymanMissingTaskAssets -RequiredRelPaths $RequiredRelPaths)
    if ($missingHostAssets.Count -gt 0) {
        Add-RaymanTaskDegradationNote -Label $Label -Scope "host" -MissingRelPaths $missingHostAssets
        $effectiveCommand = Normalize-RaymanTaskCommand -Command "powershell"
        $effectiveArgs = @(New-RaymanNoOpPowerShellArgs -Label $Label -Scope "host" -MissingRelPaths $missingHostAssets)
    }

    if ($null -ne $effectiveLinux -and $LinuxRequiredRelPaths.Count -gt 0) {
        $missingLinuxAssets = @(Get-RaymanMissingTaskAssets -RequiredRelPaths $LinuxRequiredRelPaths)
        if ($missingLinuxAssets.Count -gt 0) {
            Add-RaymanTaskDegradationNote -Label $Label -Scope "linux" -MissingRelPaths $missingLinuxAssets
            $effectiveLinux = @{
                command = "bash"
                args = @(New-RaymanNoOpLinuxArgs -Label $Label -Scope "linux" -MissingRelPaths $missingLinuxAssets)
            }
        }
    }

    $task = @{
        label = $Label
        presentation = @{ reveal = $Reveal; panel = $Panel; clear = $Clear }
        problemMatcher = @()
    }

    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $task["detail"] = $Detail
    }

    if (@($DependsOn).Count -gt 0) {
        $task["dependsOn"] = @($DependsOn)
    }

    if (-not [string]::IsNullOrWhiteSpace($DependsOrder)) {
        $task["dependsOrder"] = $DependsOrder
    }

    if ($null -ne $Group) {
        $task["group"] = $Group
    }

    if (@($DependsOn).Count -eq 0) {
        $task["type"] = $Type
        $task["command"] = $effectiveCommand
        $task["args"] = $effectiveArgs
    }

    if (-not [string]::IsNullOrWhiteSpace($RunOn)) {
        $task["runOptions"] = @{ runOn = $RunOn }
    }
    if ($null -ne $effectiveLinux -and @($DependsOn).Count -eq 0) {
        $task["linux"] = $effectiveLinux
    }

    return $task
}

function Convert-RaymanSettingMapToHashtable {
    param([object]$Value)

    if ($Value -is [System.Collections.Hashtable]) {
        return $Value
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = @{}
        foreach ($prop in $Value.psobject.properties) {
            $result[[string]$prop.Name] = $prop.Value
        }
        return $result
    }

    return @{}
}

function Set-RaymanBooleanMapEntries {
    param(
        [hashtable]$Map,
        [string[]]$Keys
    )

    foreach ($key in @($Keys)) {
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        $Map[$key] = $true
    }

    return $Map
}

function Set-RaymanVsCodeBooleanSettings {
    param(
        [hashtable]$Settings,
        [string]$SettingName,
        [string[]]$Keys
    )

    $map = Convert-RaymanSettingMapToHashtable -Value $Settings[$SettingName]
    $Settings[$SettingName] = Set-RaymanBooleanMapEntries -Map $map -Keys $Keys
}

$raymanTaskDefinitions = @(
    [ordered]@{
        Label = "Rayman: Common - Sync Daily Workspace"
        Detail = "常用组合：检查待办、运行每日健康检查并刷新上下文。"
        DependsOn = @("Rayman: Check Pending Task", "Rayman: Daily Health Check", "Rayman: Update Context")
        DependsOrder = "sequence"
    },
    [ordered]@{
        Label = "Rayman: Common - Ready for Agent Work"
        Detail = "常用组合：确保 Windows 依赖、Agent capabilities、Playwright 能力和上下文都处于可工作状态。"
        DependsOn = @("Rayman: Ensure Win Deps", "Rayman: Ensure Agent Capabilities", "Rayman: Ensure Playwright", "Rayman: Update Context")
        DependsOrder = "sequence"
    },
    [ordered]@{
        Label = "Rayman: Folder Open Bootstrap"
        Detail = "文件夹打开时统一执行 Rayman 后台启动与轻量检查。"
        Type = "process"
        Command = "powershell"
        Linux = @{ command = "pwsh" }
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/watch/vscode_folder_open_bootstrap.ps1", "-WorkspaceRoot", "`${workspaceFolder}", "-VscodeOwnerPid", "`${env:VSCODE_PID}")
        RunOn = "folderOpen"
        Reveal = "never"
        RequiredRelPaths = @(".Rayman/scripts/watch/vscode_folder_open_bootstrap.ps1", ".Rayman/common.ps1")
        LinuxRequiredRelPaths = @(".Rayman/scripts/watch/vscode_folder_open_bootstrap.ps1", ".Rayman/common.ps1")
    },
    [ordered]@{
        Label = "Rayman: Auto Start Watchers"
        Detail = "手动拉起 watcher、exitwatch 与后台服务。"
        Command = "powershell"
        Linux = @{ command = "pwsh" }
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/watch/start_background_watchers.ps1", "-WorkspaceRoot", "`${workspaceFolder}", "-VscodeOwnerPid", "`${env:VSCODE_PID}", "-FromVscodeAuto")
        Reveal = "never"
        RequiredRelPaths = @(".Rayman/scripts/watch/start_background_watchers.ps1", ".Rayman/common.ps1")
        LinuxRequiredRelPaths = @(".Rayman/scripts/watch/start_background_watchers.ps1", ".Rayman/common.ps1")
    },
    [ordered]@{
        Label = "Rayman: Check Pending Task"
        Detail = "手动检查待处理状态与工作区任务提示。"
        Command = "powershell"
        Linux = @{ command = "pwsh" }
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/state/check_pending_task.ps1")
        Reveal = "silent"
    },
    [ordered]@{
        Label = "Rayman: Daily Health Check"
        Detail = "手动刷新健康摘要，扫描 TODO/FIXME 并输出日报。"
        Command = "powershell"
        Linux = @{ command = "pwsh" }
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/watch/daily_health_check.ps1")
        Reveal = "silent"
        RequiredRelPaths = @(".Rayman/scripts/watch/daily_health_check.ps1")
        LinuxRequiredRelPaths = @(".Rayman/scripts/watch/daily_health_check.ps1")
    },
    [ordered]@{
        Label = "Rayman: Update Context"
        Detail = "刷新 .Rayman/CONTEXT.md 与自动 skills 建议。"
        Command = "powershell"
        Linux = @{ command = "pwsh" }
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/utils/generate_context.ps1")
        Reveal = "never"
        RequiredRelPaths = @(".Rayman/scripts/utils/generate_context.ps1")
        LinuxRequiredRelPaths = @(".Rayman/scripts/utils/generate_context.ps1")
    },
    [ordered]@{
        Label = "Rayman: Check Win Deps"
        Detail = "手动执行轻量 Windows 依赖检查。"
        Command = "powershell"
        Linux = @{ command = "pwsh" }
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/utils/ensure_win_deps.ps1", "-Lightweight")
        Reveal = "never"
        RequiredRelPaths = @(".Rayman/scripts/utils/ensure_win_deps.ps1")
        LinuxRequiredRelPaths = @(".Rayman/scripts/utils/ensure_win_deps.ps1")
    },
    [ordered]@{
        Label = "Rayman: Check WSL Deps"
        Detail = "手动执行轻量 WSL 依赖检查。"
        Command = "powershell"
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "exit 0")
        Linux = @{ command = "bash"; args = @("-lc", "cd '`${workspaceFolder}' && bash ./.Rayman/scripts/utils/check_wsl_deps.sh") }
        Reveal = "silent"
        LinuxRequiredRelPaths = @(".Rayman/scripts/utils/check_wsl_deps.sh")
    },
    [ordered]@{
        Label = "Rayman: Ensure Win Deps"
        Detail = "完整检查并修复 Windows 侧常用开发依赖。"
        Command = "powershell"
        Linux = @{ command = "pwsh" }
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/utils/ensure_win_deps.ps1")
        RequiredRelPaths = @(".Rayman/scripts/utils/ensure_win_deps.ps1")
        LinuxRequiredRelPaths = @(".Rayman/scripts/utils/ensure_win_deps.ps1")
    },
    [ordered]@{
        Label = "Rayman: Ensure WSL Deps"
        Detail = "完整安装或修复 WSL(Ubuntu) 所需依赖。"
        Command = "powershell"
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/utils/ensure_wsl_deps.ps1")
        Linux = @{ command = "bash"; args = @("-lc", "cd '`${workspaceFolder}' && bash ./.Rayman/scripts/utils/ensure_wsl_deps.sh") }
        RequiredRelPaths = @(".Rayman/scripts/utils/ensure_wsl_deps.ps1")
        LinuxRequiredRelPaths = @(".Rayman/scripts/utils/ensure_wsl_deps.sh")
    },
    [ordered]@{
        Label = "Rayman: Ensure Playwright"
        Detail = "确保 Playwright 浏览器能力可用于自动验收与网页调试。"
        Command = "powershell"
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/pwa/ensure_playwright_ready.ps1", "-WorkspaceRoot", "`${workspaceFolder}")
        Linux = @{ command = "bash"; args = @("-lc", "cd '`${workspaceFolder}' && bash ./.Rayman/scripts/pwa/ensure_playwright_wsl.sh") }
    },
    [ordered]@{
        Label = "Rayman: Ensure WinApp Automation"
        Detail = "确保 Windows 桌面 UI Automation 能力可用于 WinForms / MAUI(Windows) 自动化。"
        Command = "powershell"
        Linux = @{ command = "pwsh" }
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/windows/ensure_winapp.ps1", "-WorkspaceRoot", "`${workspaceFolder}")
        RequiredRelPaths = @(".Rayman/scripts/windows/ensure_winapp.ps1", ".Rayman/scripts/windows/winapp_core.ps1")
        LinuxRequiredRelPaths = @(".Rayman/scripts/windows/ensure_winapp.ps1", ".Rayman/scripts/windows/winapp_core.ps1")
    },
    [ordered]@{
        Label = "Rayman: Ensure Agent Capabilities"
        Detail = "同步 Codex Agent capabilities 到 .codex/config.toml，并补齐 OpenAI Docs / Playwright / WinApp MCP。"
        Command = "powershell"
        Linux = @{ command = "pwsh" }
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/agents/ensure_agent_capabilities.ps1", "-Action", "sync", "-WorkspaceRoot", "`${workspaceFolder}")
        RequiredRelPaths = @(".Rayman/scripts/agents/ensure_agent_capabilities.ps1", ".Rayman/config/agent_capabilities.json")
        LinuxRequiredRelPaths = @(".Rayman/scripts/agents/ensure_agent_capabilities.ps1", ".Rayman/config/agent_capabilities.json")
    },
    [ordered]@{
        Label = "Rayman: First Pass Report"
        Detail = "生成首轮问题盘点报告，适合开始复杂任务前预热。"
        Command = "powershell"
        Linux = @{ command = "pwsh" }
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/agents/first_pass_report.ps1", "-WorkspaceRoot", "`${workspaceFolder}")
    },
    [ordered]@{
        Label = "Rayman: Review Loop"
        Detail = "执行 review agent 闭环，适合做审查/复核型任务。"
        Command = "powershell"
        Linux = @{ command = "pwsh" }
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/agents/review_loop.ps1", "-WorkspaceRoot", "`${workspaceFolder}", "-TaskKind", "review")
        Group = "test"
    },
    [ordered]@{
        Label = "Rayman: Test & Fix"
        Detail = "默认测试任务：运行测试/构建并尝试自动修复常见问题。"
        Command = "powershell"
        Linux = @{ command = "pwsh" }
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/repair/run_tests_and_fix.ps1")
        Group = @{ kind = "test"; isDefault = $true }
    },
    [ordered]@{
        Label = "Rayman: Copy Init Self Check"
        Detail = "拷贝 .Rayman 到临时工作区后执行一次初始化烟测。"
        Command = "powershell"
        Linux = @{ command = "pwsh" }
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/rayman.ps1", "copy-self-check")
    },
    [ordered]@{
        Label = "Rayman: Factory Check (Strict)"
        Detail = "严格模式工厂验收：WSL 范围 smoke + release 级验证。"
        Command = "powershell"
        Linux = @{ command = "pwsh" }
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/rayman.ps1", "copy-self-check", "--strict", "--scope", "wsl")
        Group = "test"
    },
    [ordered]@{
        Label = "Rayman: Factory Check (Strict, Keep Temp)"
        Detail = "严格工厂验收并在失败时保留临时现场，便于排障。"
        Command = "powershell"
        Linux = @{ command = "pwsh" }
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/rayman.ps1", "copy-self-check", "--strict", "--scope", "wsl", "--keep-temp", "--open-on-fail")
        Group = "test"
    },
    [ordered]@{
        Label = "Rayman: Release Gate"
        Detail = "发布前规则门禁与 dist/source 同步校验。"
        Command = "powershell"
        Linux = @{ command = "pwsh" }
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/release/release_gate.ps1", "-WorkspaceRoot", "`${workspaceFolder}")
    },
    [ordered]@{
        Label = "Rayman: Deploy"
        Detail = "生成可分发包，并写出部署摘要。"
        Command = "powershell"
        Linux = @{ command = "pwsh" }
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/deploy/deploy.ps1")
        RequiredRelPaths = @(".Rayman/scripts/deploy/deploy.ps1")
        LinuxRequiredRelPaths = @(".Rayman/scripts/deploy/deploy.ps1")
    },
    [ordered]@{
        Label = "Rayman: Stop Watchers"
        Detail = "停止 Rayman watcher、auto-save 与 MCP 后台服务。"
        Command = "powershell"
        Linux = @{ command = "pwsh" }
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/watch/stop_background_watchers.ps1", "-IncludeResidualCleanup", "-OwnerPid", "`${env:VSCODE_PID}")
        RequiredRelPaths = @(".Rayman/scripts/watch/stop_background_watchers.ps1")
        LinuxRequiredRelPaths = @(".Rayman/scripts/watch/stop_background_watchers.ps1")
    },
    [ordered]@{
        Label = "Rayman: Clear Cache"
        Detail = "清理工作区缓存与临时构建产物。"
        Command = "powershell"
        Linux = @{ command = "pwsh" }
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/utils/clear_cache.ps1")
        RequiredRelPaths = @(".Rayman/scripts/utils/clear_cache.ps1")
        LinuxRequiredRelPaths = @(".Rayman/scripts/utils/clear_cache.ps1")
    }
)

$raymanTasks = @(
    foreach ($taskDefinition in $raymanTaskDefinitions) {
        New-RaymanTaskWithFallback @taskDefinition
    }
)

if (Test-Path -LiteralPath $tasksFile -PathType Leaf) {
    $tasksDoc = Read-RaymanJsonConfigCompat -Path $tasksFile -WarningPrefix 'tasks'
    if ([bool]$tasksDoc.ParseFailed) {
        Write-Host "⚠️ 更新 .vscode/tasks.json 失败，可能是 JSON 格式不正确。请手动添加任务。" -ForegroundColor Yellow
    } else {
        $existingTasksJson = if ($null -ne $tasksDoc.Obj) { $tasksDoc.Obj } else { [pscustomobject]@{ version = '2.0.0'; tasks = @() } }
        $existingTasks = if ($existingTasksJson.PSObject.Properties['tasks'] -and $existingTasksJson.tasks) { @($existingTasksJson.tasks) } else { @() }

        # 过滤掉旧的 Rayman 任务
        $filteredTasks = $existingTasks | Where-Object { $_.label -notmatch "^Rayman:" }

        # 合并新任务
        $mergedTasks = $filteredTasks + $raymanTasks
        if (-not $existingTasksJson.PSObject.Properties['tasks']) {
            Add-Member -InputObject $existingTasksJson -MemberType NoteProperty -Name 'tasks' -Value $mergedTasks -Force
        } else {
            $existingTasksJson.tasks = $mergedTasks
        }

        $existingTasksJson | ConvertTo-Json -Depth 10 | Set-Content -Path $tasksFile -Encoding UTF8
        Write-Host "✅ 已更新 .vscode/tasks.json (合并了现有任务)" -ForegroundColor Green
    }
} else {
        $newTasksObj = @{
        version = "2.0.0"
        tasks = $raymanTasks
    }
    $newTasksObj | ConvertTo-Json -Depth 10 | Set-Content -Path $tasksFile -Encoding UTF8
    Write-Host "✅ 已生成 .vscode/tasks.json" -ForegroundColor Green
}

# 4.5 优化 VS Code 性能与工作区忽略配置 (settings.json & .gitignore)
try {
    # 4.5.1 更新 .gitignore
    $ignoreRules = @"

# =========================
# 深度性能优化排查 (Auto-Added by Rayman)
# =========================
node_modules/
.artifacts/
obj/
bin/
gtp_logs/
.ci/
.Rayman/state/memory/
.playwright-mcp/
App_Data/
.vs/
.Rayman/state/
.Rayman/runtime/
tmp_restore.log
restore_server_diag.log
"@
    $gitignorePath = Join-Path $WorkspaceRoot ".gitignore"
    if (-not (Test-Path -LiteralPath $gitignorePath -PathType Leaf)) {
        New-Item -ItemType File -Path $gitignorePath -Force | Out-Null
    }
    $currentIgnore = Get-Content -LiteralPath $gitignorePath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($currentIgnore) -or $currentIgnore -notmatch "\.artifacts") {
        Add-Content -Path $gitignorePath -Value $ignoreRules -Encoding UTF8
        Write-Host "✅ 已在 .gitignore 中注入性能优化忽略规则" -ForegroundColor Green
        Write-Host "ℹ️ [SCM] 已禁用自动重建 Git 索引（不再执行 git rm --cached / git add）。" -ForegroundColor DarkCyan
    }

    # 4.5.2 更新 .vscode/settings.json
    $settingsPath = Join-Path $vscodeDir "settings.json"
    $settingsObj = @{}
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        $settingsDoc = Read-RaymanJsonConfigCompat -Path $settingsPath -AsHashtable -WarningPrefix 'settings'
        if ([bool]$settingsDoc.ParseFailed) {
            $settingsObj = @{}
        } elseif ($null -ne $settingsDoc.Obj) {
            $settingsObj = $settingsDoc.Obj
        }
    }

    # 注入基础优化
    $settingsObj["editor.largeFileOptimizations"] = $true
    $settingsObj["git.untrackedChanges"] = "separate"

    # 注入搜索排除 / watcher 排除 / 资源管理器隐藏项
    Set-RaymanVsCodeBooleanSettings -Settings $settingsObj -SettingName "search.exclude" -Keys @(
        "**/.artifacts",
        "**/node_modules",
        "**/obj",
        "**/bin",
        "**/gtp_logs",
        "**/.Rayman/state/memory",
        "**/.Rayman/state",
        "**/.Rayman/runtime"
    )
    Set-RaymanVsCodeBooleanSettings -Settings $settingsObj -SettingName "files.watcherExclude" -Keys @(
        "**/.artifacts/**",
        "**/node_modules/*/**",
        "**/obj/**",
        "**/bin/**",
        "**/gtp_logs/**",
        "**/.Rayman/state/memory/**",
        "**/.git/objects/**",
        "**/.playwright-mcp/**",
        "**/.Rayman/state/**",
        "**/.Rayman/runtime/**"
    )
    Set-RaymanVsCodeBooleanSettings -Settings $settingsObj -SettingName "files.exclude" -Keys @(
        "**/.Rayman/state",
        "**/.Rayman/runtime"
    )

    # 强制在宿主 (Windows) 运行 Codex，免 WSL 代理穿透/沙箱依赖
    $settingsObj["chatgpt.runCodexInWindowsSubsystemForLinux"] = $false

    $settingsObj | ConvertTo-Json -Depth 5 -Compress:$false | Set-Content -Path $settingsPath -Encoding UTF8
    Write-Host "✅ 已配置 .vscode/settings.json 深度性能优化及 Codex 宿主运行环境" -ForegroundColor Green
} catch {
    Write-Host ("⚠️ 优化 VS Code 性能配置发生异常：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
}

# 5. 强制 Playwright 就绪（setup + init 全覆盖）
$PlaywrightReadyScript = Join-Path $WorkspaceRoot ".Rayman\scripts\pwa\ensure_playwright_ready.ps1"
$ProxyDetectScript = Join-Path $WorkspaceRoot ".Rayman\scripts\proxy\detect_win_proxy.ps1"
$ProxyCommonScript = Join-Path $WorkspaceRoot ".Rayman\common.ps1"

function Test-ProxyEndpointReachableCompat([string]$ProxyUrl, [int]$TimeoutMs = 1200) {
    if ([string]::IsNullOrWhiteSpace($ProxyUrl)) { return $false }
    try {
        $uri = [System.Uri]$ProxyUrl
        if ($uri.Port -le 0) { return $false }
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $task = $client.ConnectAsync($uri.Host, $uri.Port)
            if (-not $task.Wait($TimeoutMs)) { return $false }
            return $client.Connected
        } finally {
            $client.Dispose()
        }
    } catch {
        return $false
    }
}

function Set-RaymanProxyEnvForCurrentProcess {
    param([string]$Root)

    $runtimeProxyPath = Join-Path $Root ".Rayman\runtime\proxy.resolved.json"
    $fallbackProxy = [Environment]::GetEnvironmentVariable('RAYMAN_PROXY_FALLBACK_URL')
    if ([string]::IsNullOrWhiteSpace($fallbackProxy)) { $fallbackProxy = 'http://127.0.0.1:8988' }
    $enableFallback = Get-EnvBoolCompat -Name 'RAYMAN_PROXY_FALLBACK_8988' -Default $true

    $proxy = ''
    $noProxy = ''

    foreach ($name in @('https_proxy','HTTPS_PROXY','http_proxy','HTTP_PROXY','all_proxy','ALL_PROXY')) {
        $v = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace([string]$v)) {
            $proxy = [string]$v
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($proxy) -and (Test-Path -LiteralPath $runtimeProxyPath -PathType Leaf)) {
        try {
            $snapshot = Get-Content -LiteralPath $runtimeProxyPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            foreach ($k in @('https_proxy','http_proxy','all_proxy')) {
                if ($snapshot.PSObject.Properties[$k] -and -not [string]::IsNullOrWhiteSpace([string]$snapshot.$k)) {
                    $proxy = [string]$snapshot.$k
                    break
                }
            }
            if ($snapshot.PSObject.Properties['no_proxy']) {
                $noProxy = [string]$snapshot.no_proxy
            }
        } catch {}
    }

    if ($enableFallback) {
        $fallbackReachable = Test-ProxyEndpointReachableCompat -ProxyUrl $fallbackProxy
        if ([string]::IsNullOrWhiteSpace($proxy)) {
            if ($fallbackReachable) {
                $proxy = $fallbackProxy
                if ([string]::IsNullOrWhiteSpace($noProxy)) { $noProxy = 'localhost,127.0.0.1,::1' }
                Write-Host ("ℹ️ [Proxy] 已启用 8988 回退代理: {0}" -f $proxy) -ForegroundColor DarkCyan
            }
        } elseif (-not (Test-ProxyEndpointReachableCompat -ProxyUrl $proxy) -and $fallbackReachable) {
            Write-Host ("⚠️ [Proxy] 当前代理不可达，切换至 8988 回退代理: {0}" -f $fallbackProxy) -ForegroundColor Yellow
            $proxy = $fallbackProxy
            if ([string]::IsNullOrWhiteSpace($noProxy)) { $noProxy = 'localhost,127.0.0.1,::1' }
        }
    }

    if ([string]::IsNullOrWhiteSpace($proxy)) {
        Write-Host "ℹ️ [Proxy] 未检测到可用代理，本次保持直连。" -ForegroundColor DarkCyan
        return
    }

    foreach ($name in @('http_proxy','HTTP_PROXY','https_proxy','HTTPS_PROXY','all_proxy','ALL_PROXY','NUGET_HTTP_PROXY','NUGET_HTTPS_PROXY','NUGET_PROXY')) {
        [Environment]::SetEnvironmentVariable($name, $proxy)
    }
    if (-not [string]::IsNullOrWhiteSpace($noProxy)) {
        foreach ($name in @('no_proxy','NO_PROXY')) {
            [Environment]::SetEnvironmentVariable($name, $noProxy)
        }
    }

    Write-Host ("✅ [Proxy] 已注入当前进程代理（含 NuGet/dotnet）: {0}" -f $proxy) -ForegroundColor Green
}
$playwrightScopeRaw = [Environment]::GetEnvironmentVariable('RAYMAN_PLAYWRIGHT_SETUP_SCOPE')
$playwrightScope = $playwrightScopeRaw
if ([string]::IsNullOrWhiteSpace($playwrightScope)) { $playwrightScope = 'wsl' }
$playwrightScopeSource = 'explicit'
$playwrightScopeProcessScope = if ($null -eq $playwrightScopeProcessOverride) { '' } else { [string]$playwrightScopeProcessOverride }
if ([string]::IsNullOrWhiteSpace($playwrightScopeProcessScope)) {
    if ([string]::IsNullOrWhiteSpace($playwrightScopeRaw) -or ($playwrightScope -eq 'wsl')) {
        $playwrightScopeSource = 'default'
    } else {
        $playwrightScopeSource = 'explicit'
    }
} else {
    $playwrightScopeSource = 'explicit'
}
if ([string]::IsNullOrWhiteSpace($playwrightScopeSource)) {
    $playwrightScopeSource = 'default'
}

if ((Test-HostIsWindowsCompat) -and ($playwrightScope -eq 'all') -and ($playwrightScopeSource -eq 'default')) {
    if (-not (Test-WindowsSandboxFeatureEnabledCompat)) {
        $playwrightScope = 'wsl'
        Write-Host "⚠️ [Playwright] 检测到 Windows Sandbox 不可用，默认将 RAYMAN_PLAYWRIGHT_SETUP_SCOPE 从 all 前置降级为 wsl。" -ForegroundColor Yellow
    }
}
$playwrightBrowser = [Environment]::GetEnvironmentVariable('RAYMAN_PLAYWRIGHT_BROWSER')
if ([string]::IsNullOrWhiteSpace($playwrightBrowser)) { $playwrightBrowser = 'chromium' }
$playwrightRequire = Get-EnvBoolCompat -Name 'RAYMAN_PLAYWRIGHT_REQUIRE' -Default $true
$playwrightTimeoutSeconds = Get-EnvIntCompat -Name 'RAYMAN_PLAYWRIGHT_TIMEOUT_SECONDS' -Default 1800 -Min 30 -Max 7200
$playwrightAutoInstall = Get-EnvBoolCompat -Name 'RAYMAN_PLAYWRIGHT_AUTO_INSTALL' -Default $true
$playwrightSummaryPath = Join-Path $WorkspaceRoot ".Rayman\runtime\playwright.ready.windows.json"

if (Test-HostIsWindowsCompat) {
    if (-not (Test-Path -LiteralPath $ProxyDetectScript -PathType Leaf)) {
        Write-Host ("⚠️ [Proxy] 未找到代理探测脚本，跳过刷新: {0}" -f $ProxyDetectScript) -ForegroundColor Yellow
    } elseif (-not (Test-Path -LiteralPath $ProxyCommonScript -PathType Leaf)) {
        Write-Host ("⚠️ [Proxy] 跳过代理探测（缺少 common.ps1）: {0}" -f $ProxyCommonScript) -ForegroundColor Yellow
    } else {
        Write-Host "🔌 [Proxy] 正在刷新代理探测快照..." -ForegroundColor Cyan
        try {
            & $ProxyDetectScript -WorkspaceRoot $WorkspaceRoot | Out-Host
        } catch {
            Write-Host ("⚠️ [Proxy] 刷新代理探测失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}

if (Test-HostIsWindowsCompat) {
    Set-RaymanProxyEnvForCurrentProcess -Root $WorkspaceRoot
}

function Resolve-RaymanSystemSlimAuditScript {
    param([string]$WorkspaceRoot)

    $candidates = @(
        (Join-Path $WorkspaceRoot ".Rayman\scripts\agents\system_slim_policy.ps1"),
        (Join-Path $WorkspaceRoot ".Rayman\.dist\scripts\agents\system_slim_policy.ps1")
    ) | Select-Object -Unique

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    return ''
}

function Invoke-RaymanSystemSlimAuditSafe {
    param(
        [string]$WorkspaceRoot,
        [string]$Source = 'setup'
    )

    $auditScript = Resolve-RaymanSystemSlimAuditScript -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace($auditScript)) {
        Write-Host "⚠️ [Slim] 缺少 system_slim_policy.ps1，跳过系统能力精简审计。" -ForegroundColor Yellow
        return $null
    }

    try {
        . $auditScript
    } catch {
        Write-Host ("⚠️ [Slim] 加载审计脚本失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
        return $null
    }

    $auditCmd = Get-Command Invoke-RaymanSystemSlimAudit -ErrorAction SilentlyContinue
    if ($null -eq $auditCmd) {
        Write-Host ("⚠️ [Slim] 审计函数不存在，跳过：{0}" -f $auditScript) -ForegroundColor Yellow
        return $null
    }

    try {
        return (Invoke-RaymanSystemSlimAudit -WorkspaceRoot $WorkspaceRoot -Source $Source)
    } catch {
        Write-Host ("⚠️ [Slim] 执行审计失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
        return $null
    }
}

function Write-RaymanSystemSlimAuditSummary {
    param([object]$AuditResult)

    if ($null -eq $AuditResult) { return }

    $activeFeatures = @()
    if ($AuditResult.PSObject.Properties['active_features']) {
        $activeFeatures = @($AuditResult.active_features | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    if ($activeFeatures.Count -gt 0) {
        Write-Host ("🧩 [Slim] 当前生效精简: {0}" -f ($activeFeatures -join ', ')) -ForegroundColor Cyan
    } else {
        Write-Host "🧩 [Slim] 当前生效精简: (none)" -ForegroundColor DarkCyan
    }

    if ($AuditResult.PSObject.Properties['report_path'] -and -not [string]::IsNullOrWhiteSpace([string]$AuditResult.report_path)) {
        Write-Host ("🧾 [Slim] 报告: {0}" -f [string]$AuditResult.report_path) -ForegroundColor DarkCyan
    }

    $notifyOnUpgrade = $true
    if ($AuditResult.PSObject.Properties['notify_on_upgrade']) {
        $notifyOnUpgrade = [bool]$AuditResult.notify_on_upgrade
    }
    $upgradeDetected = $false
    if ($AuditResult.PSObject.Properties['upgrade_detected']) {
        $upgradeDetected = [bool]$AuditResult.upgrade_detected
    }
    if ($upgradeDetected -and $notifyOnUpgrade) {
        $upgradedTools = @()
        if ($AuditResult.PSObject.Properties['upgraded_tools']) {
            $upgradedTools = @($AuditResult.upgraded_tools | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        $detail = if ($upgradedTools.Count -gt 0) { $upgradedTools -join ', ' } else { 'unknown tools' }
        Write-Host ("⚠️ [Slim] 检测到工具升级({0})，请确认是否继续扩大系统能力精简范围。" -f $detail) -ForegroundColor Yellow
    }
}

function Get-ReleaseGateMissingBootstrapAssets {
    param([string]$WorkspaceRoot)

    $requiredRelPaths = @(
        '.Rayman\common.ps1',
        '.Rayman\scripts\mcp\manage_mcp.ps1',
        '.Rayman\scripts\memory\memory_bootstrap.ps1',
        '.Rayman\scripts\memory\manage_memory.ps1',
        '.Rayman\scripts\memory\manage_memory.py',
        '.Rayman\mcp\mcp_servers.json'
    )

    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($rel in $requiredRelPaths) {
        $abs = Join-Path $WorkspaceRoot $rel
        if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) {
            [void]$missing.Add($rel.Replace('\', '/'))
        }
    }
    return $missing
}

function Get-PlaywrightSandboxFailureKind {
    param([string]$SummaryPath)

    if (-not (Test-Path -LiteralPath $SummaryPath -PathType Leaf)) { return '' }

    try {
        $summaryObj = Get-Content -LiteralPath $SummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $summaryObj) { return '' }
        if ($summaryObj.PSObject.Properties['sandbox'] -and $summaryObj.sandbox) {
            if ($summaryObj.sandbox.PSObject.Properties['failure_kind']) {
                $kind = [string]$summaryObj.sandbox.failure_kind
                if (-not [string]::IsNullOrWhiteSpace($kind)) {
                    return $kind.Trim().ToLowerInvariant()
                }
            }
            if ($summaryObj.sandbox.PSObject.Properties['detail']) {
                $detail = [string]$summaryObj.sandbox.detail
                if (-not [string]::IsNullOrWhiteSpace($detail)) {
                    $detailLower = $detail.ToLowerInvariant()
                    if ($detailLower.Contains('feature is not enabled') -or $detailLower.Contains('windowssandbox.exe not found')) { return 'feature_not_enabled' }
                    if ($detailLower.Contains('exited before bootstrap became ready')) { return 'exited_before_ready' }
                    if ($detailLower.Contains('bootstrap appears stalled')) { return 'bootstrap_stalled' }
                    if ($detailLower.Contains('timeout waiting sandbox bootstrap ready')) { return 'timeout_no_status' }
                }
            }
        }
    } catch {
        return ''
    }

    return ''
}

function Get-PlaywrightWslFailureKind {
    param([string]$SummaryPath)

    if (-not (Test-Path -LiteralPath $SummaryPath -PathType Leaf)) { return '' }

    try {
        $summaryObj = Get-Content -LiteralPath $SummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $summaryObj) { return '' }
        if ($summaryObj.PSObject.Properties['wsl'] -and $summaryObj.wsl) {
            if ($summaryObj.wsl.PSObject.Properties['failure_kind']) {
                $kind = [string]$summaryObj.wsl.failure_kind
                if (-not [string]::IsNullOrWhiteSpace($kind)) {
                    return $kind.Trim().ToLowerInvariant()
                }
            }
            if ($summaryObj.wsl.PSObject.Properties['detail']) {
                $detail = [string]$summaryObj.wsl.detail
                if (-not [string]::IsNullOrWhiteSpace($detail)) {
                    $detailLower = $detail.ToLowerInvariant()
                    if ($detailLower.Contains('neither wsl.exe nor bash is available')) { return 'command_unavailable' }
                    if ($detailLower.Contains('script not found')) { return 'script_missing' }
                    if ($detailLower.Contains('marker missing')) { return 'marker_missing' }
                    if ($detailLower.Contains('ensure script exit=')) { return 'execution_failed' }
                }
            }
        }
    } catch {
        return ''
    }

    return ''
}

function Test-CanRetryPlaywrightWithoutSandbox {
    param(
        [string]$SummaryPath,
        [string]$CurrentScope,
        [string]$ScopeSource
    )

    if ($CurrentScope -ne 'all') { return $false }
    $failureKind = Get-PlaywrightSandboxFailureKind -SummaryPath $SummaryPath
    if ([string]::IsNullOrWhiteSpace($failureKind)) { return $false }
    return ($failureKind -in @('feature_not_enabled', 'exited_before_ready', 'bootstrap_stalled', 'timeout_no_status'))
}

function Test-CanRetryPlaywrightWithHost {
    param(
        [string]$SummaryPath,
        [string]$CurrentScope,
        [string]$ScopeSource
    )

    if ($CurrentScope -ne 'wsl') { return $false }
    if ($ScopeSource -ne 'default') { return $false }

    $failureKind = Get-PlaywrightWslFailureKind -SummaryPath $SummaryPath
    if ([string]::IsNullOrWhiteSpace($failureKind)) { return $false }
    return ($failureKind -in @('command_unavailable', 'script_missing', 'marker_missing', 'execution_failed', 'unknown'))
}

function Invoke-PlaywrightReadyWithFallback {
    param(
        [string]$WorkspaceRoot,
        [string]$PlaywrightReadyScript,
        [string]$SummaryPath,
        [string]$Scope,
        [string]$ScopeSource,
        [string]$Browser,
        [bool]$Require,
        [int]$TimeoutSeconds
    )

    $scopeAfterRetry = $Scope

    Reset-LastExitCodeCompat
    & $PlaywrightReadyScript -WorkspaceRoot $WorkspaceRoot -Scope $Scope -Browser $Browser -Require:$Require -TimeoutSeconds $TimeoutSeconds
    $exitCode = Get-LastExitCodeCompat -Default 0
    if ($exitCode -eq 0) {
        return $exitCode
    }

    if (Test-CanRetryPlaywrightWithoutSandbox -SummaryPath $SummaryPath -CurrentScope $Scope -ScopeSource $ScopeSource) {
        $failureKind = Get-PlaywrightSandboxFailureKind -SummaryPath $SummaryPath
        if ([string]::IsNullOrWhiteSpace($failureKind)) { $failureKind = 'unknown' }
        $failureHint = switch ($failureKind) {
            'feature_not_enabled' { '本机未启用 Windows Sandbox' }
            'exited_before_ready' { 'Sandbox 在 ready 前退出（含手工关闭场景）' }
            'bootstrap_stalled' { 'Sandbox bootstrap 卡住' }
            'timeout_no_status' { 'Sandbox bootstrap 超时且无完整状态' }
            default { 'Sandbox 启动失败' }
        }
        Write-Host ("⚠️ [Playwright] 检测到 Sandbox 失败（kind={0}, hint={1}），自动降级到 scope=wsl 重试一次。若你手工关闭了 Sandbox，无需等待自动关闭。" -f $failureKind, $failureHint) -ForegroundColor Yellow
        Reset-LastExitCodeCompat
        & $PlaywrightReadyScript -WorkspaceRoot $WorkspaceRoot -Scope 'wsl' -Browser $Browser -Require:$Require -TimeoutSeconds $TimeoutSeconds
        $exitCode = Get-LastExitCodeCompat -Default 0
        $scopeAfterRetry = 'wsl'
    }

    if ($exitCode -ne 0 -and (Test-CanRetryPlaywrightWithHost -SummaryPath $SummaryPath -CurrentScope $scopeAfterRetry -ScopeSource $ScopeSource)) {
        $failureKind = Get-PlaywrightWslFailureKind -SummaryPath $SummaryPath
        if ([string]::IsNullOrWhiteSpace($failureKind)) { $failureKind = 'unknown' }
        $failureHint = switch ($failureKind) {
            'command_unavailable' { '当前主机缺少可用的 WSL/bash 执行通道' }
            'script_missing' { '缺少 WSL 就绪脚本' }
            'marker_missing' { 'WSL 就绪标记未生成或不可用' }
            'execution_failed' { 'WSL 就绪命令执行失败' }
            default { 'WSL 就绪异常' }
        }
        Write-Host ("⚠️ [Playwright] 检测到 WSL 不可用或失败（kind={0}, hint={1}），自动回退到 scope=host 重试一次。" -f $failureKind, $failureHint) -ForegroundColor Yellow
        Reset-LastExitCodeCompat
        & $PlaywrightReadyScript -WorkspaceRoot $WorkspaceRoot -Scope 'host' -Browser $Browser -Require:$Require -TimeoutSeconds $TimeoutSeconds
        $exitCode = Get-LastExitCodeCompat -Default 0
    }

    return $exitCode
}

if (Get-EnvBoolCompat -Name 'RAYMAN_SKIP_PWA' -Default $false) {
    Write-Host "⏭️ [Playwright] 已按环境变量跳过（RAYMAN_SKIP_PWA=1）" -ForegroundColor Yellow
} else {
    if ($playwrightAutoInstall) {
        Invoke-PlaywrightAutoInstall -WorkspaceRoot $WorkspaceRoot -Scope $playwrightScope -Browser $playwrightBrowser -TimeoutSeconds $playwrightTimeoutSeconds
    } else {
        Write-Host "⏭️ [Playwright] 已关闭自动安装（RAYMAN_PLAYWRIGHT_AUTO_INSTALL=0）" -ForegroundColor Yellow
    }

    Write-Host "🧪 [Playwright] 正在确保自动验收浏览器能力就绪..." -ForegroundColor Cyan
    if (Test-Path -LiteralPath $PlaywrightReadyScript -PathType Leaf) {
        try {
            $playwrightExitCode = Invoke-PlaywrightReadyWithFallback -WorkspaceRoot $WorkspaceRoot -PlaywrightReadyScript $PlaywrightReadyScript -SummaryPath $playwrightSummaryPath -Scope $playwrightScope -ScopeSource $playwrightScopeSource -Browser $playwrightBrowser -Require:$playwrightRequire -TimeoutSeconds $playwrightTimeoutSeconds
            if ($playwrightExitCode -ne 0) {
                Write-Host ("❌ [Playwright] 就绪检查失败（exit={0}）。请查看 {1}" -f $playwrightExitCode, $playwrightSummaryPath) -ForegroundColor Red
                Show-PlaywrightTroubleshootingHints -Root $WorkspaceRoot
                Exit-RaymanSetup -ExitCode $playwrightExitCode -Reason 'playwright-ready-failed'
            }
            Write-Host "✅ [Playwright] 就绪检查通过" -ForegroundColor Green
        } catch {
            Write-Host ("❌ [Playwright] 就绪检查异常：{0}" -f $_.Exception.Message) -ForegroundColor Red
            Show-PlaywrightTroubleshootingHints -Root $WorkspaceRoot
            if ($playwrightRequire) { Exit-RaymanSetup -ExitCode 2 -Reason 'playwright-ready-exception' }
            Write-Host "⚠️ [Playwright] 当前为非强制模式，继续执行后续步骤。" -ForegroundColor Yellow
        }
    } else {
        $missingMsg = "缺少脚本: $PlaywrightReadyScript"
        if ($playwrightRequire) {
            Write-Host ("❌ [Playwright] {0}" -f $missingMsg) -ForegroundColor Red
            Show-PlaywrightTroubleshootingHints -Root $WorkspaceRoot
            Exit-RaymanSetup -ExitCode 2 -Reason 'playwright-script-missing'
        }
        Write-Host ("⚠️ [Playwright] {0}（非强制模式继续）" -f $missingMsg) -ForegroundColor Yellow
    }
}

$systemSlimAuditResult = Invoke-RaymanSystemSlimAuditSafe -WorkspaceRoot $WorkspaceRoot -Source 'setup'
Write-RaymanSystemSlimAuditSummary -AuditResult $systemSlimAuditResult

# 6. 默认执行发布闸门（可通过 -SkipReleaseGate 跳过）
if (-not $SkipReleaseGate) {
    $releaseGateMissingAssets = @(Get-ReleaseGateMissingBootstrapAssets -WorkspaceRoot $WorkspaceRoot)
    if ($releaseGateMissingAssets.Count -gt 0) {
        Write-Host ("⚠️ [Release Gate] 检测到初始化精简包缺少关键资产，setup 阶段自动跳过: {0}" -f ($releaseGateMissingAssets -join ', ')) -ForegroundColor Yellow
        Write-Host "   如需严格发布验收，请补齐资产后手工执行 .\\.Rayman\\rayman.ps1 release-gate -Mode standard" -ForegroundColor DarkYellow
    } else {
        Write-Host "🛡️ [Release Gate] 正在执行发布就绪检查..." -ForegroundColor Cyan
        $ReleaseGateScript = Join-Path $WorkspaceRoot ".Rayman\scripts\release\release_gate.ps1"
        if (Test-Path -LiteralPath $ReleaseGateScript -PathType Leaf) {
            $releaseGateArgs = @{
                WorkspaceRoot = $WorkspaceRoot
                Mode = 'project'
            }
            $gitMarkerPath = Join-Path $WorkspaceRoot '.git'
            if (-not (Test-Path -LiteralPath $gitMarkerPath)) {
                $releaseGateArgs['AllowNoGit'] = $true
                Write-Host "⚠️ [Release Gate] 当前工作区仍不是 Git 仓库（Git bootstrap 缺失/失败/已关闭），setup 初始化阶段自动启用 -AllowNoGit（project 模式按 PASS 豁免）。" -ForegroundColor Yellow
            }
            Reset-LastExitCodeCompat
            & $ReleaseGateScript @releaseGateArgs
            $releaseGateExitCode = Get-LastExitCodeCompat -Default 0
            if ($releaseGateExitCode -ne 0) {
                Write-Host "❌ [Release Gate] 未通过，请先修复报告问题后再开始项目工作。" -ForegroundColor Red
                Write-Host "   报告路径: .Rayman/state/release_gate_report.md" -ForegroundColor Yellow
                Exit-RaymanSetup -ExitCode $releaseGateExitCode -Reason 'release-gate-failed'
            }
            Write-Host "✅ [Release Gate] 通过" -ForegroundColor Green
        } else {
            Write-Host "⚠️ [Release Gate] 未找到脚本，已跳过: $ReleaseGateScript" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "⏭️ [Release Gate] 已按参数跳过（-SkipReleaseGate）" -ForegroundColor Yellow
}

if (Get-EnvBoolCompat -Name 'RAYMAN_SETUP_SKIP_POST_CHECK' -Default $false) {
    Write-Host "⏭️ [Self Check] 已按环境变量跳过（RAYMAN_SETUP_SKIP_POST_CHECK=1）" -ForegroundColor Yellow
} elseif (-not $SelfCheck -and -not $StrictCheck) {
    $postCheckMode = if ($raymanCommonImported -and (Get-Command Get-RaymanSetupPostCheckMode -ErrorAction SilentlyContinue)) {
        Get-RaymanSetupPostCheckMode -WorkspaceRoot $WorkspaceRoot
    } else {
        'prompt'
    }

    switch ($postCheckMode) {
        'skip' {
            Write-Host "⏭️ [Self Check] 已按 RAYMAN_SETUP_POST_CHECK_MODE=skip 跳过" -ForegroundColor Yellow
        }
        'strict' {
            Write-Host "🤖 [Self Check] 当前会话按 full-auto/严格默认自动执行严格拷贝自检。" -ForegroundColor DarkCyan
            $StrictCheck = $true
        }
        'normal' {
            Write-Host "🤖 [Self Check] 已按 RAYMAN_SETUP_POST_CHECK_MODE=normal 自动执行普通拷贝自检。" -ForegroundColor DarkCyan
            $SelfCheck = $true
        }
        default {
            Write-Host ""
            Write-Host "===== 初始化后续操作自检选项 =====" -ForegroundColor Cyan
            Write-Host "1. [默认] 严格拷贝自检 (出厂验收模式，证明模版健壮性)"
            Write-Host "2. 普通拷贝自检"
            Write-Host "3. 跳过自检"
            $choice = Read-Host "请输入你的选择 (1/2/3) [默认: 1]"
            if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq '1') {
                $StrictCheck = $true
            } elseif ($choice -eq '2') {
                $SelfCheck = $true
            }
        }
    }
}

if ($SelfCheck -or $StrictCheck) {
    Write-Host ""
    Write-Host "🔍 [Self Check] 正在执行项目拷贝初始化自检..." -ForegroundColor Cyan
    $RaymanEntryScript = Join-Path $WorkspaceRoot ".Rayman\rayman.ps1"
    if (Test-Path -LiteralPath $RaymanEntryScript -PathType Leaf) {
        $checkArgs = @("copy-self-check")
        if ($StrictCheck) { $checkArgs += "--strict" }

        $checkExitCode = Invoke-SetupChildPowerShellScript -ScriptPath $RaymanEntryScript -Arguments $checkArgs
        if ($checkExitCode -ne 0) {
            Write-Host "❌ [Self Check] 拷贝初始化自检未通过，这可能导致模版复用时出现问题。" -ForegroundColor Red
            Exit-RaymanSetup -ExitCode $checkExitCode -Reason 'copy-self-check-failed'
        }
        Write-Host "✅ [Self Check] 拷贝初始化自检通过，已证明此项目模版可独立移植。" -ForegroundColor Green
    } else {
        Write-Host "⚠️ [Self Check] 未找到 rayman.ps1 入口文件，跳过自检。" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "🧹 [SCM] 正在注入拷贝后噪声忽略策略并统计当前变更..." -ForegroundColor Cyan
$scmIgnoreResult = Update-RaymanScmIgnoreRules -WorkspaceRoot $WorkspaceRoot
$scmSummary = Get-RaymanScmStatusSummary -WorkspaceRoot $WorkspaceRoot
$scmSoftLimit = Get-RaymanScmSoftLimit
Write-RaymanScmSoftLimitWarning -Summary $scmSummary -SoftLimit $scmSoftLimit
if ($null -ne $script:ScmTrackedNoiseAnalysis) {
    Write-RaymanScmTrackedNoiseDiagnostics -Analysis $script:ScmTrackedNoiseAnalysis
}

if ($script:RaymanTaskDegradationNotes -and $script:RaymanTaskDegradationNotes.Count -gt 0) {
    Write-Host ""
    Write-Host "⚠️ [Tasks] 任务降级清单（已保留标签，执行改为 no-op）：" -ForegroundColor Yellow
    foreach ($note in $script:RaymanTaskDegradationNotes) {
        Write-Host ("   - {0}" -f $note) -ForegroundColor DarkYellow
    }
}

Write-Host ""
Write-Host "🎉 Rayman 环境初始化完成！" -ForegroundColor Green
Invoke-RaymanSetupFinalize -ExitCode 0 -Reason 'success' | Out-Null
Write-Host "👉 提示: 请重新加载 VS Code 窗口 (Ctrl+Shift+P -> Reload Window) 以使任务和 Copilot 指令生效。" -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host ""
if ($raymanCommonImported -and (Get-Command Invoke-RaymanAttentionAlert -ErrorAction SilentlyContinue)) {
    Invoke-RaymanAttentionAlert -Kind 'done' -Reason 'Rayman setup 已完成。' -WorkspaceRoot $WorkspaceRoot | Out-Null
}
} catch {
    if ([string]$_.Exception.Message -eq 'tracked_rayman_assets_blocked') {
        Write-Host ("🧾 [setup] 日志路径: {0}" -f $script:SetupLogPath) -ForegroundColor Yellow
        throw
    }
    Write-Host ("❌ [setup] 初始化异常：{0}" -f $_.Exception.Message) -ForegroundColor Red
    $inv = $_.InvocationInfo
    if ($null -ne $inv) {
        $lineInfo = ''
        if ($inv.ScriptLineNumber -gt 0) {
            $lineInfo = (":{0}" -f $inv.ScriptLineNumber)
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$inv.ScriptName)) {
            Write-Host ("📍 [setup] 异常位置: {0}{1}" -f $inv.ScriptName, $lineInfo) -ForegroundColor Yellow
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$_.ScriptStackTrace)) {
        $stackTop = ([string]$_.ScriptStackTrace -split "(\r\n|\n|\r)")[0]
        if (-not [string]::IsNullOrWhiteSpace([string]$stackTop)) {
            Write-Host ("🧵 [setup] 调用栈(Top): {0}" -f $stackTop.Trim()) -ForegroundColor Yellow
        }
    }
    Write-Host ("🧾 [setup] 日志路径: {0}" -f $script:SetupLogPath) -ForegroundColor Yellow
    throw
} finally {
    Stop-SetupTranscriptSafe
}
