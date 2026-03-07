param(
    [string]$TaskDescription = "未提供详细描述"
)

$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$StateDir = Join-Path $WorkspaceRoot ".Rayman\state"

if (-not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir | Out-Null
}

$PendingFile = Join-Path $StateDir "pending_task.md"
$Date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$Content = @"
# 暂停任务状态

**时间**: $Date
**任务描述**: 
$TaskDescription

"@

Set-Content -Path $PendingFile -Value $Content -Encoding UTF8
Write-Host "✅ 状态已保存到 $PendingFile" -ForegroundColor Green

# Git Stash (硬状态保存)
if (Get-Command git -ErrorAction SilentlyContinue) {
    $stashMsg = "Rayman WIP: $Date"
    # 检查是否有未提交的更改
    $status = git status --porcelain
    if ($status) {
        git stash push -u -m $stashMsg | Out-Null
        Write-Host "✅ 工作区已通过 Git Stash 保存 ($stashMsg)" -ForegroundColor Green
    } else {
        Write-Host "ℹ️ 工作区干净，无需 Git Stash" -ForegroundColor Cyan
    }
}

& "$PSScriptRoot\..\utils\request_attention.ps1" -Message "状态已保存，工作区已暂存"
