param(
    [string]$WorkspaceRoot = $(Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path,
    [string]$LogFile = $(Join-Path $WorkspaceRoot ".Rayman\state\last_error.log"),
    [string]$SnapshotOutFile = $(Join-Path $WorkspaceRoot ".Rayman\state\error_snapshot.md")
)

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$ErrorActionPreference = 'Stop'

Write-Host "📸 [Snapshot] 开始捕获故障现场快照..." -ForegroundColor Cyan

# 1. 抓取近期环境日志 (last_error.log)
$logContent = "无日志文件"
if (Test-Path $LogFile) {
    try {
        $logContent = (Get-Content -LiteralPath $LogFile -Tail 100 -Encoding UTF8 -ErrorAction SilentlyContinue) -join "`r`n"
    } catch {}
}

# 2. 抓取 Git 变更上下文 (Git diff 对错误行周围代码)
# 注意：这有助于 Agent 知道最近改了什么导致了这次错误
$gitDiff = "无版本控制或暂无改动"
try {
    $currentDir = Get-Location
    Set-Location $WorkspaceRoot
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $gitDiffRaw = git diff HEAD
        if (-not [string]::IsNullOrWhiteSpace($gitDiffRaw)) {
            $gitLines = $gitDiffRaw -split "`n"
            if ($gitLines.Count -gt 500) {
                # 截断过长 diff
                $gitDiff = ($gitLines[0..499] -join "`n") + "`n... (diff 截断) ..."
            } else {
                $gitDiff = $gitDiffRaw
            }
        }
    }
    Set-Location $currentDir
} catch {}

# 3. Web/UI 端测试 MCP 降级检测
# 若是由 Playwright/UI 等引起，提示调用专门工具（实际操作已由 MCP / UI测试输出截屏，这里附加提示）
$uiDetectionText = ""
if ($logContent -match "playwright|browser|webdriver|winapps|automationid|uiautomation|not visible|timeout \d+ms exceeded") {
    $uiDetectionText = @"
⚠️ 检出了前端/UI自动化错误特征。
请务必结合 Playwright MCP 或 WinApp Automation 截图来分析故障，因为此处文本日志无法体现 UI 控件的状态。
"@
}

# 4. 系统环境信息
$osVer = [Environment]::OSVersion.VersionString
$msystem = $env:MSYSTEM
$psVer = $PSVersionTable.PSVersion.ToString()

# 生成 Markdown 结构的 Snapshot
$snapshotContent = @"
# 🚨 故障现场诊断快照 (Snapshot)

**日期**: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
**操作系统**: $osVer (MSYSTEM: $msystem)
**PowerShell**: $psVer
**工作区**: $WorkspaceRoot

$uiDetectionText

## 📝 最近 100 行报错日志
```text
$logContent
```

## 🔍 近期 Git 本地更改代码 (Diff)
```diff
$gitDiff
```

## ⚙️ 重要环境变量
RAYMAN_PYTHON = $($env:RAYMAN_PYTHON)
RAYMAN_DOTNET_PRIMARY = $($env:RAYMAN_DOTNET_PRIMARY)

"@

try {
    $outDir = Split-Path $SnapshotOutFile -Parent
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
    Set-Content -LiteralPath $SnapshotOutFile -Value $snapshotContent -Encoding UTF8
    Write-Host "✅ [Snapshot] 快照已保存至: $SnapshotOutFile" -ForegroundColor Green
} catch {
    Write-Host "⚠️ [Snapshot] 快照保存失败: $_" -ForegroundColor Yellow
}
