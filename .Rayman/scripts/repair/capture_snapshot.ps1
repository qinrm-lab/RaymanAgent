param(
    [string]$WorkspaceRoot = $(Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path,
    [string]$LogFile = $(Join-Path $WorkspaceRoot ".Rayman\state\last_error.log"),
    [string]$SnapshotOutFile = $(Join-Path $WorkspaceRoot ".Rayman\state\error_snapshot.md"),
    [string]$ConfigReferenceFile = ''
)

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
    . $commonPath
}
$repeatErrorGuardPath = Join-Path $PSScriptRoot '..\utils\repeat_error_guard.ps1'
if (Test-Path -LiteralPath $repeatErrorGuardPath -PathType Leaf) {
    . $repeatErrorGuardPath -NoMain
}

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

# 5. 已保存的配置基线参考
if ([string]::IsNullOrWhiteSpace([string]$ConfigReferenceFile)) {
    $ConfigReferenceFile = Join-Path $WorkspaceRoot ".Rayman\context\current-config-reference.md"
}

$configReferenceSection = "未找到已保存配置参考。建议先维护：$ConfigReferenceFile"
if (Test-Path -LiteralPath $ConfigReferenceFile -PathType Leaf) {
    try {
        $configReferenceText = Get-Content -LiteralPath $ConfigReferenceFile -Raw -Encoding UTF8
        $configReferenceSection = @"
已保存参考路径: $ConfigReferenceFile

$configReferenceText
"@
    } catch {
        $configReferenceSection = @"
已发现配置参考文件，但读取失败。
路径: $ConfigReferenceFile
错误: $($_.Exception.Message)
"@
    }
}

# 6. 已知重复错误守卫
$repeatErrorSection = "未发现重复错误守卫结果。"
if (Get-Command Get-RaymanRepeatErrorGuardReport -ErrorAction SilentlyContinue) {
    try {
        $repeatErrorReport = Get-RaymanRepeatErrorGuardReport -WorkspaceRoot $WorkspaceRoot -GuardStage 'snapshot'
        Write-RaymanRepeatErrorGuardRuntimeReport -WorkspaceRoot $WorkspaceRoot -Report $repeatErrorReport | Out-Null
        $matches = @((Get-RaymanMapValue -Map $repeatErrorReport -Key 'matches' -Default @()) | ForEach-Object { $_ })
        if ($matches.Count -gt 0) {
            $lines = New-Object System.Collections.Generic.List[string]
            foreach ($match in $matches) {
                $lines.Add(('- signature=`{0}` severity=`{1}` blocked=`{2}`' -f [string](Get-RaymanMapValue -Map $match -Key 'signature_id' -Default ''), [string](Get-RaymanMapValue -Map $match -Key 'severity' -Default 'warn'), [string]([bool](Get-RaymanMapValue -Map $match -Key 'fail_fast' -Default $false)).ToString().ToLowerInvariant())) | Out-Null
                $message = [string](Get-RaymanMapValue -Map $match -Key 'message' -Default '')
                if (-not [string]::IsNullOrWhiteSpace($message)) {
                    $lines.Add(("  detail: {0}" -f $message)) | Out-Null
                }
                $repair = [string](Get-RaymanMapValue -Map $match -Key 'repair_command' -Default '')
                if (-not [string]::IsNullOrWhiteSpace($repair)) {
                    $lines.Add(('  repair: `{0}`' -f $repair)) | Out-Null
                }
            }
            $repeatErrorSection = ($lines.ToArray() -join "`r`n")
        } else {
            $repeatErrorSection = "未命中当前已登记的重复错误签名。"
        }
    } catch {
        $repeatErrorSection = ("重复错误守卫评估失败：{0}" -f $_.Exception.Message)
    }
}

# 生成 Markdown 结构的 Snapshot
$snapshotContent = @"
# 🚨 故障现场诊断快照 (Snapshot)

**日期**: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
**操作系统**: $osVer (MSYSTEM: $msystem)
**PowerShell**: $psVer
**工作区**: $WorkspaceRoot

$uiDetectionText

## 🧭 已保存的配置基线参考
$configReferenceSection

## 🛡️ 已知重复错误守卫
$repeatErrorSection

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
