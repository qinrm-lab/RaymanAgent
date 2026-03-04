param(
    [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\.." | Select-Object -ExpandProperty Path),
    [switch]$SkipReleaseGate,
    [switch]$ForceReindex,
    [switch]$AutoMigrateLegacyRag,
    [switch]$NoAutoMigrateLegacyRag,
    [switch]$SelfCheck,
    [switch]$StrictCheck
)
$autoMigrateLegacyRagEffective = $true
if ($NoAutoMigrateLegacyRag) {
    $autoMigrateLegacyRagEffective = $false
} elseif ($PSBoundParameters.ContainsKey('AutoMigrateLegacyRag')) {
    $autoMigrateLegacyRagEffective = $AutoMigrateLegacyRag.IsPresent
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$raymanCommonPath = Join-Path $PSScriptRoot "common.ps1"
$raymanCommonImported = $false

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

function Normalize-WorkspaceRagEnv {
    param(
        [string]$WorkspaceRoot,
        [string]$DefaultNamespace = ''
    )

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { return }
    $resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $expectedRagRoot = Join-Path $resolvedWorkspaceRoot '.rag'
    $allowExternalRagRoot = Get-EnvBoolCompat -Name 'RAYMAN_ALLOW_EXTERNAL_RAG_ROOT' -Default $false
    $preserveRagNamespace = Get-EnvBoolCompat -Name 'RAYMAN_PRESERVE_RAG_NAMESPACE' -Default $false

    $ragRoot = [string]$env:RAYMAN_RAG_ROOT
    if ([string]::IsNullOrWhiteSpace($ragRoot)) {
        $ragRoot = $expectedRagRoot
    } elseif (-not [System.IO.Path]::IsPathRooted($ragRoot)) {
        $ragRoot = Join-Path $resolvedWorkspaceRoot $ragRoot
    }

    if (-not $allowExternalRagRoot -and -not (Test-PathInsideCompat -PathValue $ragRoot -RootValue $expectedRagRoot)) {
        Write-Host ("⚠️ [RAG] 检测到跨工作区 RAYMAN_RAG_ROOT={0}，已自动重置为 {1}" -f [string]$env:RAYMAN_RAG_ROOT, $expectedRagRoot) -ForegroundColor Yellow
        $ragRoot = $expectedRagRoot
    }

    $resolvedDefaultNamespace = ''
    if ([string]::IsNullOrWhiteSpace($DefaultNamespace)) {
        $resolvedDefaultNamespace = Split-Path -Leaf $resolvedWorkspaceRoot
    } else {
        $resolvedDefaultNamespace = [string]$DefaultNamespace
    }
    if ([string]::IsNullOrWhiteSpace($resolvedDefaultNamespace)) {
        $resolvedDefaultNamespace = 'default'
    }

    $ragNamespaceRaw = [string]$env:RAYMAN_RAG_NAMESPACE
    if ($preserveRagNamespace -and -not [string]::IsNullOrWhiteSpace($ragNamespaceRaw)) {
        $ragNamespace = $ragNamespaceRaw
    } else {
        if (-not $preserveRagNamespace -and -not [string]::IsNullOrWhiteSpace($ragNamespaceRaw) -and ($ragNamespaceRaw -ne $resolvedDefaultNamespace)) {
            Write-Host ("⚠️ [RAG] 检测到跨工作区 RAYMAN_RAG_NAMESPACE={0}，已重置为 {1}（如需保留请设置 RAYMAN_PRESERVE_RAG_NAMESPACE=1）" -f $ragNamespaceRaw, $resolvedDefaultNamespace) -ForegroundColor Yellow
        }
        $ragNamespace = $resolvedDefaultNamespace
    }

    foreach ($invalidCh in [System.IO.Path]::GetInvalidFileNameChars()) {
        $ragNamespace = $ragNamespace.Replace([string]$invalidCh, '_')
    }
    if ([string]::IsNullOrWhiteSpace($ragNamespace)) {
        $ragNamespace = 'default'
    }

    $env:RAYMAN_RAG_ROOT = $ragRoot
    $env:RAYMAN_RAG_NAMESPACE = $ragNamespace
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
        'RAYMAN_AUTO_INSTALL_TEST_DEPS' = '1'
        'RAYMAN_REQUIRE_TEST_DEPS' = '1'
        'RAYMAN_SELF_HEAL_AUTO_DEP_INSTALL' = '1'
        'RAYMAN_USE_SANDBOX' = '0'
        'RAYMAN_PRESERVE_RAG_NAMESPACE' = '0'
        'RAYMAN_PLAYWRIGHT_REQUIRE' = '1'
        'RAYMAN_PLAYWRIGHT_AUTO_INSTALL' = '1'
        'RAYMAN_PLAYWRIGHT_SETUP_SCOPE' = 'wsl'
        'RAYMAN_GIT_SAFECRLF_SUPPRESS' = '1'
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
        'RAYMAN_AGENT_POLICY_BYPASS' = '0'
        'RAYMAN_AGENT_CLOUD_WHITELIST' = ''
        'RAYMAN_FIRST_PASS_WINDOW' = '20'
        'RAYMAN_REVIEW_LOOP_MAX_ROUNDS' = '2'
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

function Invoke-EnsureRequirementsLayout {
    param([string]$WorkspaceRoot)

    $ensureScript = Join-Path $WorkspaceRoot ".Rayman\scripts\requirements\ensure_requirements.sh"
    if (-not (Test-Path -LiteralPath $ensureScript -PathType Leaf)) {
        Write-Host ("⚠️ [req] 缺少脚本，跳过 requirements 补齐: {0}" -f $ensureScript) -ForegroundColor Yellow
        return
    }

    $bashCmd = Get-Command 'bash' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $bashCmd -or [string]::IsNullOrWhiteSpace([string]$bashCmd.Source)) {
        Write-Host "⚠️ [req] 未找到 bash，跳过 requirements 补齐。" -ForegroundColor Yellow
        return
    }

    Push-Location $WorkspaceRoot
    try {
        Reset-LastExitCodeCompat
        & $bashCmd.Source "./.Rayman/scripts/requirements/ensure_requirements.sh"
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

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_RAG_HEARTBEAT_SECONDS)) {
    `$env:RAYMAN_RAG_HEARTBEAT_SECONDS = [string]`$env:RAYMAN_HEARTBEAT_SECONDS
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_SANDBOX_HEARTBEAT_SECONDS)) {
    `$env:RAYMAN_SANDBOX_HEARTBEAT_SECONDS = [string]`$env:RAYMAN_HEARTBEAT_SECONDS
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_MCP_HEARTBEAT_SECONDS)) {
    `$env:RAYMAN_MCP_HEARTBEAT_SECONDS = [string]`$env:RAYMAN_HEARTBEAT_SECONDS
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_RAG_ROOT)) {
    `$env:RAYMAN_RAG_ROOT = Join-Path `$PSScriptRoot '.rag'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_RAG_NAMESPACE)) {
    `$env:RAYMAN_RAG_NAMESPACE = Split-Path -Leaf `$PSScriptRoot
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_PRESERVE_RAG_NAMESPACE)) {
    `$env:RAYMAN_PRESERVE_RAG_NAMESPACE = '0'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_RAG_PYTHON)) {
    `$venvWinPython = Join-Path `$PSScriptRoot '.venv\Scripts\python.exe'
    `$venvPosixPython = Join-Path `$PSScriptRoot '.venv/bin/python'
    if (Test-Path -LiteralPath `$venvWinPython -PathType Leaf) {
        `$env:RAYMAN_RAG_PYTHON = `$venvWinPython
    } elseif (Test-Path -LiteralPath `$venvPosixPython -PathType Leaf) {
        `$env:RAYMAN_RAG_PYTHON = `$venvPosixPython
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

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_USE_SANDBOX)) {
    `$env:RAYMAN_USE_SANDBOX = '0'
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

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_AGENT_POLICY_BYPASS)) {
    `$env:RAYMAN_AGENT_POLICY_BYPASS = '0'
}

if (`$null -eq `$env:RAYMAN_AGENT_CLOUD_WHITELIST) {
    `$env:RAYMAN_AGENT_CLOUD_WHITELIST = ''
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_FIRST_PASS_WINDOW)) {
    `$env:RAYMAN_FIRST_PASS_WINDOW = '20'
}

if ([string]::IsNullOrWhiteSpace([string]`$env:RAYMAN_REVIEW_LOOP_MAX_ROUNDS)) {
    `$env:RAYMAN_REVIEW_LOOP_MAX_ROUNDS = '2'
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
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_USE_SANDBOX)) {
    $env:RAYMAN_USE_SANDBOX = '0'
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
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AGENT_POLICY_BYPASS)) {
    $env:RAYMAN_AGENT_POLICY_BYPASS = '0'
}
if ($null -eq $env:RAYMAN_AGENT_CLOUD_WHITELIST) {
    $env:RAYMAN_AGENT_CLOUD_WHITELIST = ''
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_FIRST_PASS_WINDOW)) {
    $env:RAYMAN_FIRST_PASS_WINDOW = '20'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_REVIEW_LOOP_MAX_ROUNDS)) {
    $env:RAYMAN_REVIEW_LOOP_MAX_ROUNDS = '2'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_PRESERVE_RAG_NAMESPACE)) {
    $env:RAYMAN_PRESERVE_RAG_NAMESPACE = '0'
}

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
Normalize-WorkspaceRagEnv -WorkspaceRoot $WorkspaceRoot -DefaultNamespace $solutionName
Invoke-EnsureRequirementsLayout -WorkspaceRoot $WorkspaceRoot

# 2. 生成 .github/copilot-instructions.md
$githubDir = Join-Path $WorkspaceRoot ".github"
if (-not (Test-Path -LiteralPath $githubDir)) {
    New-Item -ItemType Directory -Force -Path $githubDir | Out-Null
}

$instructionsFile = Join-Path $githubDir "copilot-instructions.md"
$instructionsContent = @"
# Rayman AI 助手自定义指令

当用户在聊天框中输入单个问号（`?` 或 `？`）时，请读取 `.Rayman/commands.txt` 文件的内容，并将其作为可用命令列表展示给用户。

当用户输入 "初始化" 或 "运行 setup" 时，请运行 `.Rayman/setup.ps1` 脚本来初始化环境。

当用户输入 "WSL 安装依赖" 或 "安装 WSL 依赖" 时，请运行 `.Rayman/scripts/utils/ensure_wsl_deps.ps1` 脚本，它会在 Ubuntu(WSL2) 中自动安装 `pwsh`、通知与语音依赖（需要 sudo 密码）。

当用户输入 "Windows 依赖检查" 或 "安装 Windows 依赖" 时，请运行 `.Rayman/scripts/utils/ensure_win_deps.ps1` 脚本，检查并提示 Windows 侧常用工具（如 git/wsl/dotnet/node/python）。

当用户输入 "保存状态" 或 "暂停" 时，请运行 `.Rayman/scripts/state/save_state.ps1` 脚本，它会生成 Markdown 状态并自动执行 Git Stash 暂存代码。
当用户输入 "继续" 时，请运行 `.Rayman/scripts/state/resume_state.ps1` 脚本，它会恢复 Git Stash 并清理状态文件。

当用户输入 "自愈" 或 "测试并修复" 时，请运行 `.Rayman/scripts/repair/run_tests_and_fix.ps1` 脚本。如果报错，请读取 `.Rayman/state/last_error.log` 并自动尝试修复代码。

当用户输入 "更新上下文" 时，请运行 `.Rayman/scripts/utils/generate_context.ps1` 脚本。在执行复杂任务前，请优先读取 `.Rayman/CONTEXT.md` 了解项目结构。

当用户输入 "拷贝后自检"、"拷贝初始化自检" 或 "自检初始化" 时，请运行 `.Rayman/rayman.ps1 copy-self-check`，用于验证 `.Rayman` 拷贝到新项目后是否能成功初始化。

当用户输入 "严格自检"、"出厂验收" 或 "严格模式自检" 时，请运行 `.Rayman/rayman.ps1 copy-self-check --strict`，用于执行包含 Release Gate 的一键出厂验收。

当用户输入 "严格自检保留现场" 或 "出厂验收保留现场" 时，请运行 `.Rayman/rayman.ps1 copy-self-check --strict --scope wsl --keep-temp --open-on-fail`，用于失败后自动保留并打开临时验收目录。

当用户输入 "停止监听" 或 "停止后台服务" 时，请运行 `.Rayman/scripts/watch/stop_background_watchers.ps1` 脚本来停止所有后台监听进程。

当用户输入 "清理缓存" 或 "一键清理缓存" 时，请运行 `.Rayman/scripts/utils/clear_cache.ps1` 脚本。
当用户输入 "一键部署" 时，请运行 `.Rayman/scripts/deploy/deploy.ps1` 脚本。如果用户指定了项目名（如 "一键部署 WebApp"），请将项目名作为 `-ProjectName` 参数传递给脚本。

【重要】当你在执行任务过程中，遇到需要用户手动确认、输入信息或进行人机交互时，请务必先运行 `.Rayman/scripts/utils/request_attention.ps1` 脚本，通过语音提醒用户。你可以通过 `-Message` 参数传递具体的提示内容，例如：`.Rayman/scripts/utils/request_attention.ps1 -Message "需要您确认部署配置"`。

【规划增强】当用户的需求较复杂、信息不完整或表述不清晰时：
1) 先自动给出一个简短的可执行计划（分步骤/待办）；
2) 提出最多 3-4 个关键澄清问题；
3) 若用户未回复，按“最小返工”的默认方案继续推进，并在关键分歧点再次确认。

【模型与输出策略】
- 优先使用用户选择的模型。如果不可用，请自动降级选择当前可用的最强模型（如 Claude 3.5 Sonnet, GPT-4o, Gemini 1.5 Pro 等）。
- 忽略 Token 消耗限制，提供最完整、最深入的代码实现和架构分析。
- 严禁在生成代码时使用 `// ...existing code...` 或类似占位符省略逻辑，必须输出完整的、可直接运行的代码块。
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

# 3. 初始化高级模块 (Docker Sandbox, RAG, MCP)
Write-Host "📦 [Sandbox] 正在后台构建 Docker 沙箱镜像 (这可能需要几分钟)..." -ForegroundColor Cyan
$SandboxScript = Join-Path $WorkspaceRoot ".Rayman\scripts\sandbox\run_in_sandbox.ps1"
if (Test-Path $SandboxScript) {
    # 异步构建镜像，不阻塞主流程
    Start-Process -FilePath "powershell" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"& '$SandboxScript' -Command 'echo Sandbox Ready'`"" -WindowStyle Hidden
}

Write-Host "🧠 [RAG] 正在初始化向量记忆库..." -ForegroundColor Cyan
$RagScript = Join-Path $WorkspaceRoot ".Rayman\scripts\rag\manage_rag.ps1"
$ragDecisionSummary = "未执行（RAG 脚本不存在）"
$ragDbPath = ''
if (Test-Path $RagScript) {
    $ragRoot = [string]$env:RAYMAN_RAG_ROOT
    if ([string]::IsNullOrWhiteSpace($ragRoot)) {
        $ragRoot = Join-Path $WorkspaceRoot ".rag"
    } elseif (-not [System.IO.Path]::IsPathRooted($ragRoot)) {
        $ragRoot = Join-Path $WorkspaceRoot $ragRoot
    }

    $ragNamespace = [string]$env:RAYMAN_RAG_NAMESPACE
    if ([string]::IsNullOrWhiteSpace($ragNamespace)) {
        $ragNamespace = $solutionName
    }

    foreach ($invalidCh in [System.IO.Path]::GetInvalidFileNameChars()) {
        $ragNamespace = $ragNamespace.Replace([string]$invalidCh, '_')
    }
    if ([string]::IsNullOrWhiteSpace($ragNamespace)) {
        $ragNamespace = "default"
    }

    $env:RAYMAN_RAG_ROOT = $ragRoot
    $env:RAYMAN_RAG_NAMESPACE = $ragNamespace

    $ragProjectPath = Join-Path $ragRoot $ragNamespace
    $ragDbPath = Join-Path $ragProjectPath "chroma_db"
    $legacyRagDbPath = Join-Path $WorkspaceRoot ".Rayman\state\chroma_db"
    $ragMigrateScript = Join-Path $WorkspaceRoot ".Rayman\scripts\rag\migrate_legacy_rag.ps1"
    $ragBootstrapScript = Join-Path $WorkspaceRoot ".Rayman\scripts\rag\rag_bootstrap.ps1"

    if (Test-Path -LiteralPath $ragBootstrapScript -PathType Leaf) {
        try {
            . $ragBootstrapScript
            $ragProbe = Invoke-RaymanRagBootstrap -WorkspaceRoot $WorkspaceRoot -EnsureDeps:$false -NoInstallDeps -Quiet
            if ($ragProbe.Success) {
                Write-Host ("✅ [RAG] 预检通过（解释器: {0}）" -f [string]$ragProbe.PythonLabel) -ForegroundColor Green
            } else {
                Write-Host ("⚠️ [RAG] 预检提示：{0}" -f [string]$ragProbe.Message) -ForegroundColor Yellow
            }
        } catch {
            Write-Host ("⚠️ [RAG] 预检执行失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    } else {
        Write-Host "⚠️ [RAG] 缺少 rag_bootstrap.ps1，跳过 RAG 预检。" -ForegroundColor Yellow
    }

    $hasExistingRagDb = $false
    if (Test-Path -LiteralPath $ragDbPath -PathType Container) {
        try {
            $hasExistingRagDb = $null -ne (Get-ChildItem -LiteralPath $ragDbPath -Recurse -File -ErrorAction Stop | Select-Object -First 1)
        } catch {
            $hasExistingRagDb = $false
        }
    }

    $hasLegacyRagDb = $false
    if (Test-Path -LiteralPath $legacyRagDbPath -PathType Container) {
        try {
            $hasLegacyRagDb = $null -ne (Get-ChildItem -LiteralPath $legacyRagDbPath -Recurse -File -ErrorAction Stop | Select-Object -First 1)
        } catch {
            $hasLegacyRagDb = $false
        }
    }

    if ($hasLegacyRagDb -and -not $hasExistingRagDb -and -not $ForceReindex) {
        Write-Host "⚠️ [RAG] 检测到旧向量库路径：$legacyRagDbPath" -ForegroundColor Yellow
        if ($autoMigrateLegacyRagEffective) {
            if (Test-Path -LiteralPath $ragMigrateScript -PathType Leaf) {
                Write-Host "🚚 [RAG] 自动迁移已开启（默认）：开始迁移旧向量库..." -ForegroundColor Yellow
                Reset-LastExitCodeCompat
                & $ragMigrateScript -WorkspaceRoot $WorkspaceRoot -RagRoot $ragRoot -Namespace $ragNamespace
                $ragMigrateExitCode = Get-LastExitCodeCompat -Default 0
                if ($ragMigrateExitCode -eq 0) {
                    try {
                        $hasExistingRagDb = $null -ne (Get-ChildItem -LiteralPath $ragDbPath -Recurse -File -ErrorAction Stop | Select-Object -First 1)
                    } catch {
                        $hasExistingRagDb = $false
                    }
                    if ($hasExistingRagDb) {
                        Write-Host "✅ [RAG] 自动迁移完成，已切换复用新路径向量库。" -ForegroundColor Green
                    }
                } else {
                    Write-Host ("⚠️ [RAG] 自动迁移失败（exit={0}），将继续按默认流程处理。" -f $ragMigrateExitCode) -ForegroundColor Yellow
                }
            } else {
                Write-Host "⚠️ [RAG] 未找到迁移脚本: $ragMigrateScript" -ForegroundColor Yellow
            }
        } else {
            Write-Host "💡 [RAG] 建议迁移到新路径后再复用：$ragDbPath" -ForegroundColor Yellow
            Write-Host "   可使用自动迁移：.\.Rayman\setup.ps1" -ForegroundColor DarkYellow
            Write-Host "   或手动执行：.\.Rayman\rayman.ps1 migrate-rag" -ForegroundColor DarkYellow
            Write-Host "   迁移命令（PowerShell）：" -ForegroundColor DarkYellow
            Write-Host "   New-Item -ItemType Directory -Force -Path '$ragDbPath' | Out-Null" -ForegroundColor DarkGray
            Write-Host "   robocopy '$legacyRagDbPath' '$ragDbPath' /E /COPY:DAT /R:1 /W:1 | Out-Null" -ForegroundColor DarkGray
        }
    }

    if ($ForceReindex) {
        Write-Host "♻️ [RAG] 已启用 -ForceReindex：将重建向量库（Reset）" -ForegroundColor Yellow
        & $RagScript -Action build -Reset
        $ragDecisionSummary = "强制重建（ForceReindex=1, Reset=1） -> $ragDbPath"
    } elseif ($hasExistingRagDb) {
        Write-Host "✅ [RAG] 检测到已有向量库，默认复用并跳过重建（如需重建请使用 -ForceReindex）" -ForegroundColor Green
        $ragDecisionSummary = "复用已有向量库（跳过重建） -> $ragDbPath"
    } else {
        & $RagScript -Action build
        $ragDecisionSummary = "首次构建（未检测到可复用向量库） -> $ragDbPath"
    }
}
Write-Host "🧾 [RAG] 本次策略：$ragDecisionSummary" -ForegroundColor DarkCyan

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

# 4. 生成或更新 .vscode/tasks.json
$vscodeDir = Join-Path $WorkspaceRoot ".vscode"
if (-not (Test-Path -LiteralPath $vscodeDir)) {
    New-Item -ItemType Directory -Force -Path $vscodeDir | Out-Null
}

$tasksFile = Join-Path $vscodeDir "tasks.json"
$raymanTasks = @(
    @{
        label = "Rayman: Auto Start Watchers"
        type = "shell"
        command = "powershell"
        linux = @{ command = "pwsh" }
        args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/watch/start_background_watchers.ps1", "-WorkspaceRoot", "`${workspaceFolder}", "-VscodeOwnerPid", "`${env:VSCODE_PID}", "-FromVscodeAuto")
        runOptions = @{ runOn = "folderOpen" }
        presentation = @{ reveal = "never"; panel = "shared"; clear = $false }
        problemMatcher = @()
    },
    @{
        label = "Rayman: Check Win Deps"
        type = "shell"
        command = "powershell"
        linux = @{ command = "pwsh" }
        args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/utils/check_win_deps.ps1")
        runOptions = @{ runOn = "folderOpen" }
        presentation = @{ reveal = "never"; panel = "shared"; clear = $false }
        problemMatcher = @()
    },
    @{
        label = "Rayman: Check Pending Task"
        type = "shell"
        command = "powershell"
        linux = @{ command = "pwsh" }
        args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/state/check_pending_task.ps1")
        runOptions = @{ runOn = "folderOpen" }
        presentation = @{ reveal = "silent"; panel = "shared"; clear = $false }
        problemMatcher = @()
    },
    @{
        label = "Rayman: Check WSL Deps"
        type = "shell"
        command = "powershell"
        args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "exit 0")
        # WSL 下优先用 bash 自检（不依赖 pwsh，避免首次打开就全任务失效且无提示）
        linux = @{
            command = "bash";
            args = @("-lc", "cd '`${workspaceFolder}' && bash ./.Rayman/scripts/utils/check_wsl_deps.sh")
        }
        runOptions = @{ runOn = "folderOpen" }
        presentation = @{ reveal = "silent"; panel = "shared"; clear = $false }
        problemMatcher = @()
    },
    @{
        label = "Rayman: Daily Health Check"
        type = "shell"
        command = "powershell"
        linux = @{ command = "pwsh" }
        args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/watch/daily_health_check.ps1")
        runOptions = @{ runOn = "folderOpen" }
        presentation = @{ reveal = "always"; panel = "shared"; clear = $false }
        problemMatcher = @()
    },
    @{
        label = "Rayman: Update Context"
        type = "shell"
        command = "powershell"
        linux = @{ command = "pwsh" }
        args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/utils/generate_context.ps1")
        presentation = @{ reveal = "always"; panel = "shared"; clear = $false }
        problemMatcher = @()
    },
    @{
        label = "Rayman: Test & Fix"
        type = "shell"
        command = "powershell"
        linux = @{ command = "pwsh" }
        args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/repair/run_tests_and_fix.ps1")
        presentation = @{ reveal = "always"; panel = "shared"; clear = $false }
        problemMatcher = @()
    },
    @{
        label = "Rayman: Review Loop"
        type = "shell"
        command = "powershell"
        linux = @{ command = "pwsh" }
        args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/agents/review_loop.ps1", "-WorkspaceRoot", "`${workspaceFolder}", "-TaskKind", "bugfix")
        presentation = @{ reveal = "always"; panel = "shared"; clear = $false }
        problemMatcher = @()
    },
    @{
        label = "Rayman: First Pass Report"
        type = "shell"
        command = "powershell"
        linux = @{ command = "pwsh" }
        args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/agents/first_pass_report.ps1", "-WorkspaceRoot", "`${workspaceFolder}")
        presentation = @{ reveal = "always"; panel = "shared"; clear = $false }
        problemMatcher = @()
    },
    @{
        label = "Rayman: Ensure Playwright"
        type = "shell"
        command = "powershell"
        args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/pwa/ensure_playwright_ready.ps1", "-WorkspaceRoot", "`${workspaceFolder}")
        linux = @{
            command = "bash";
            args = @("-lc", "cd '`${workspaceFolder}' && bash ./.Rayman/scripts/pwa/ensure_playwright_wsl.sh")
        }
        presentation = @{ reveal = "always"; panel = "shared"; clear = $false }
        problemMatcher = @()
    },
    @{
        label = "Rayman: Ensure WSL Deps"
        type = "shell"
        command = "powershell"
        args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/utils/ensure_wsl_deps.ps1")
        # 在 WSL 里直接跑 bash 脚本（此时可能尚未安装 pwsh）
        linux = @{ 
            command = "bash";
            args = @("-lc", "cd '`${workspaceFolder}' && bash ./.Rayman/scripts/utils/ensure_wsl_deps.sh")
        }
        presentation = @{ reveal = "always"; panel = "shared"; clear = $false }
        problemMatcher = @()
    },
    @{
        label = "Rayman: Ensure Win Deps"
        type = "shell"
        command = "powershell"
        linux = @{ command = "pwsh" }
        args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/utils/ensure_win_deps.ps1")
        presentation = @{ reveal = "always"; panel = "shared"; clear = $false }
        problemMatcher = @()
    },
    @{
        label = "Rayman: Copy Init Self Check"
        type = "shell"
        command = "powershell"
        linux = @{ command = "pwsh" }
        args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/rayman.ps1", "copy-self-check")
        presentation = @{ reveal = "always"; panel = "shared"; clear = $false }
        problemMatcher = @()
    },
    @{
        label = "Rayman: Factory Check (Strict)"
        type = "shell"
        command = "powershell"
        linux = @{ command = "pwsh" }
        args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/rayman.ps1", "copy-self-check", "--strict", "--scope", "wsl")
        presentation = @{ reveal = "always"; panel = "shared"; clear = $false }
        problemMatcher = @()
    },
    @{
        label = "Rayman: Factory Check (Strict, Keep Temp)"
        type = "shell"
        command = "powershell"
        linux = @{ command = "pwsh" }
        args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/rayman.ps1", "copy-self-check", "--strict", "--scope", "wsl", "--keep-temp", "--open-on-fail")
        presentation = @{ reveal = "always"; panel = "shared"; clear = $false }
        problemMatcher = @()
    },
    @{
        label = "Rayman: Stop Watchers"
        type = "shell"
        command = "powershell"
        linux = @{ command = "pwsh" }
        args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/watch/stop_background_watchers.ps1")
        presentation = @{ reveal = "always"; panel = "shared"; clear = $false }
        problemMatcher = @()
    },
    @{
        label = "Rayman: Clear Cache"
        type = "shell"
        command = "powershell"
        linux = @{ command = "pwsh" }
        args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/utils/clear_cache.ps1")
        presentation = @{ reveal = "always"; panel = "shared"; clear = $false }
        problemMatcher = @()
    },
    @{
        label = "Rayman: Deploy"
        type = "shell"
        command = "powershell"
        linux = @{ command = "pwsh" }
        args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/deploy/deploy.ps1")
        presentation = @{ reveal = "always"; panel = "shared"; clear = $false }
        problemMatcher = @()
    },
    @{
        label = "Rayman: Release Gate"
        type = "shell"
        command = "powershell"
        linux = @{ command = "pwsh" }
        args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`${workspaceFolder}/.Rayman/scripts/release/release_gate.ps1", "-WorkspaceRoot", "`${workspaceFolder}")
        presentation = @{ reveal = "always"; panel = "shared"; clear = $false }
        problemMatcher = @()
    }
)

if (Test-Path -LiteralPath $tasksFile -PathType Leaf) {
    try {
        $rawJson = Get-Content -LiteralPath $tasksFile -Raw
        # 简单移除单行和多行注释 (处理 JSONC)
        $rawJson = $rawJson -replace '(?m)//.*$', ''
        $rawJson = $rawJson -replace '(?s)/\*.*?\*/', ''
        
        $existingTasksJson = $rawJson | ConvertFrom-Json
        $existingTasks = if ($existingTasksJson.tasks) { @($existingTasksJson.tasks) } else { @() }
        
        # 过滤掉旧的 Rayman 任务
        $filteredTasks = $existingTasks | Where-Object { $_.label -notmatch "^Rayman:" }
        
        # 合并新任务
        $mergedTasks = $filteredTasks + $raymanTasks
        $existingTasksJson.tasks = $mergedTasks
        
        $existingTasksJson | ConvertTo-Json -Depth 10 | Set-Content -Path $tasksFile -Encoding UTF8
        Write-Host "✅ 已更新 .vscode/tasks.json (合并了现有任务)" -ForegroundColor Green
    } catch {
        Write-Host "⚠️ 更新 .vscode/tasks.json 失败，可能是 JSON 格式不正确。请手动添加任务。" -ForegroundColor Yellow
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
.rag/
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
        
        # 尝试清理 Git 缓存，防止已入库的缓存文件阻碍性能
        $gitDir = Join-Path $WorkspaceRoot ".git"
        if (Test-Path -LiteralPath $gitDir -PathType Container) {
            Write-Host "⏳ 正在清理 Git 本地缓存索引..." -ForegroundColor Cyan
            Push-Location $WorkspaceRoot
            try {
                git rm -r --cached . > $null 2>&1
                git add . > $null 2>&1
            } catch {}
            finally {
                Pop-Location
            }
        }
    }

    # 4.5.2 更新 .vscode/settings.json
    $settingsPath = Join-Path $vscodeDir "settings.json"
    $settingsObj = @{}
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try {
            $settingsObj = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        } catch {
            $settingsObj = @{}
        }
    }

    # 注入基础优化
    $settingsObj["editor.largeFileOptimizations"] = $true
    $settingsObj["git.untrackedChanges"] = "separate"
    
    # 注入搜索排除
    if (-not $settingsObj.Contains("search.exclude")) {
        $settingsObj["search.exclude"] = @{}
    }
    if ($settingsObj["search.exclude"] -is [System.Collections.Hashtable] -or $settingsObj["search.exclude"] -is [System.Management.Automation.PSCustomObject]) {
        $searchDict = if ($settingsObj["search.exclude"] -is [System.Management.Automation.PSCustomObject]) { 
            [Hashtable]($settingsObj["search.exclude"].psobject.properties | % { @{$_.Name=$_.Value} })
        } else { $settingsObj["search.exclude"] }
        $searchDict["**/.artifacts"] = $true
        $searchDict["**/node_modules"] = $true
        $searchDict["**/obj"] = $true
        $searchDict["**/bin"] = $true
        $searchDict["**/gtp_logs"] = $true
        $searchDict["**/.rag"] = $true
        $settingsObj["search.exclude"] = $searchDict
    }

    # 注入监听排除 (终极杀招)
    if (-not $settingsObj.Contains("files.watcherExclude")) {
        $settingsObj["files.watcherExclude"] = @{}
    }
    if ($settingsObj["files.watcherExclude"] -is [System.Collections.Hashtable] -or $settingsObj["files.watcherExclude"] -is [System.Management.Automation.PSCustomObject]) {
        $watcherDict = if ($settingsObj["files.watcherExclude"] -is [System.Management.Automation.PSCustomObject]) { 
            [Hashtable]($settingsObj["files.watcherExclude"].psobject.properties | % { @{$_.Name=$_.Value} })
        } else { $settingsObj["files.watcherExclude"] }
        $watcherDict["**/.artifacts/**"] = $true
        $watcherDict["**/node_modules/*/**"] = $true
        $watcherDict["**/obj/**"] = $true
        $watcherDict["**/bin/**"] = $true
        $watcherDict["**/gtp_logs/**"] = $true
        $watcherDict["**/.rag/**"] = $true
        $watcherDict["**/.git/objects/**"] = $true
        $watcherDict["**/.playwright-mcp/**"] = $true
        $settingsObj["files.watcherExclude"] = $watcherDict
    }

    $settingsObj | ConvertTo-Json -Depth 5 -Compress:$false | Set-Content -Path $settingsPath -Encoding UTF8
    Write-Host "✅ 已配置 .vscode/settings.json 深度性能优化" -ForegroundColor Green
} catch {
    Write-Host ("⚠️ 优化 VS Code 性能配置发生异常：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
}

# 5. 强制 Playwright 就绪（setup + init 全覆盖）
$PlaywrightReadyScript = Join-Path $WorkspaceRoot ".Rayman\scripts\pwa\ensure_playwright_ready.ps1"
$ProxyDetectScript = Join-Path $WorkspaceRoot ".Rayman\scripts\proxy\detect_win_proxy.ps1"

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
$playwrightScope = [Environment]::GetEnvironmentVariable('RAYMAN_PLAYWRIGHT_SETUP_SCOPE')
if ([string]::IsNullOrWhiteSpace($playwrightScope)) { $playwrightScope = 'wsl' }
$playwrightScopeSource = [Environment]::GetEnvironmentVariable('RAYMAN_PLAYWRIGHT_SETUP_SCOPE')
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

if (Test-HostIsWindowsCompat -and (Test-Path -LiteralPath $ProxyDetectScript -PathType Leaf)) {
    Write-Host "🔌 [Proxy] 正在刷新代理探测快照..." -ForegroundColor Cyan
    try {
        & $ProxyDetectScript -WorkspaceRoot $WorkspaceRoot | Out-Host
    } catch {
        Write-Host ("⚠️ [Proxy] 刷新代理探测失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

if (Test-HostIsWindowsCompat) {
    Set-RaymanProxyEnvForCurrentProcess -Root $WorkspaceRoot
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
            exit $playwrightExitCode
        }
        Write-Host "✅ [Playwright] 就绪检查通过" -ForegroundColor Green
    } catch {
        Write-Host ("❌ [Playwright] 就绪检查异常：{0}" -f $_.Exception.Message) -ForegroundColor Red
        Show-PlaywrightTroubleshootingHints -Root $WorkspaceRoot
        if ($playwrightRequire) { exit 2 }
        Write-Host "⚠️ [Playwright] 当前为非强制模式，继续执行后续步骤。" -ForegroundColor Yellow
    }
} else {
    $missingMsg = "缺少脚本: $PlaywrightReadyScript"
    if ($playwrightRequire) {
        Write-Host ("❌ [Playwright] {0}" -f $missingMsg) -ForegroundColor Red
        Show-PlaywrightTroubleshootingHints -Root $WorkspaceRoot
        exit 2
    }
    Write-Host ("⚠️ [Playwright] {0}（非强制模式继续）" -f $missingMsg) -ForegroundColor Yellow
}

# 6. 默认执行发布闸门（可通过 -SkipReleaseGate 跳过）
if (-not $SkipReleaseGate) {
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
            Write-Host "⚠️ [Release Gate] 当前工作区不是 Git 仓库，setup 初始化阶段自动启用 -AllowNoGit（project 模式按 PASS 豁免）。" -ForegroundColor Yellow
        }
        Reset-LastExitCodeCompat
        & $ReleaseGateScript @releaseGateArgs
        $releaseGateExitCode = Get-LastExitCodeCompat -Default 0
        if ($releaseGateExitCode -ne 0) {
            Write-Host "❌ [Release Gate] 未通过，请先修复报告问题后再开始项目工作。" -ForegroundColor Red
            Write-Host "   报告路径: .Rayman/state/release_gate_report.md" -ForegroundColor Yellow
            exit $releaseGateExitCode
        }
        Write-Host "✅ [Release Gate] 通过" -ForegroundColor Green
    } else {
        Write-Host "⚠️ [Release Gate] 未找到脚本，已跳过: $ReleaseGateScript" -ForegroundColor Yellow
    }
} else {
    Write-Host "⏭️ [Release Gate] 已按参数跳过（-SkipReleaseGate）" -ForegroundColor Yellow
}

if (Get-EnvBoolCompat -Name 'RAYMAN_SETUP_SKIP_POST_CHECK' -Default $false) {
    Write-Host "⏭️ [Self Check] 已按环境变量跳过（RAYMAN_SETUP_SKIP_POST_CHECK=1）" -ForegroundColor Yellow
} elseif (-not $SelfCheck -and -not $StrictCheck) {
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

if ($SelfCheck -or $StrictCheck) {
    Write-Host ""
    Write-Host "🔍 [Self Check] 正在执行项目拷贝初始化自检..." -ForegroundColor Cyan
    $RaymanEntryScript = Join-Path $WorkspaceRoot ".Rayman\rayman.ps1"
    if (Test-Path -LiteralPath $RaymanEntryScript -PathType Leaf) {
        $checkArgs = @("copy-self-check")
        if ($StrictCheck) { $checkArgs += "--strict" }
        
        Reset-LastExitCodeCompat
        & $RaymanEntryScript @checkArgs
        $checkExitCode = Get-LastExitCodeCompat -Default 0
        if ($checkExitCode -ne 0) {
            Write-Host "❌ [Self Check] 拷贝初始化自检未通过，这可能导致模版复用时出现问题。" -ForegroundColor Red
            exit $checkExitCode
        }
        Write-Host "✅ [Self Check] 拷贝初始化自检通过，已证明此项目模版可独立移植。" -ForegroundColor Green
    } else {
        Write-Host "⚠️ [Self Check] 未找到 rayman.ps1 入口文件，跳过自检。" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "🎉 Rayman 环境初始化完成！" -ForegroundColor Green
Write-Host "👉 提示: 请重新加载 VS Code 窗口 (Ctrl+Shift+P -> Reload Window) 以使任务和 Copilot 指令生效。" -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host ""
} catch {
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
