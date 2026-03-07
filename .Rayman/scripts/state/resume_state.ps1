$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$StateDir = Join-Path $WorkspaceRoot ".Rayman\state"
$PendingFile = Join-Path $StateDir "pending_task.md"
$AutoSavePatch = Join-Path $StateDir "auto_save.patch"
$AutoSaveMeta = Join-Path $StateDir "auto_save_meta.json"

if (Test-Path $PendingFile) {
    Write-Host "📄 发现挂起的任务：" -ForegroundColor Cyan
    Get-Content $PendingFile | Write-Host
    Remove-Item $PendingFile -Force
    Write-Host "✅ 状态文件已清理" -ForegroundColor Green
} else {
    Write-Host "ℹ️ 没有找到挂起的任务状态文件。" -ForegroundColor Cyan
}

# 恢复自动保存的 Patch (应对断电/崩溃)
if (Test-Path $AutoSavePatch) {
    Write-Host "⚠️ 发现异常中断遗留的自动保存状态！正在尝试恢复..." -ForegroundColor Yellow
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Set-Location $WorkspaceRoot
        try {
            # 尝试应用 patch
            git apply $AutoSavePatch
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✅ 已成功恢复断电前未保存的代码更改！" -ForegroundColor Green
                Remove-Item $AutoSavePatch -Force
                if (Test-Path $AutoSaveMeta) { Remove-Item $AutoSaveMeta -Force }
            } else {
                Write-Host "❌ 恢复自动保存失败，可能存在冲突。Patch 文件保留在: $AutoSavePatch" -ForegroundColor Red
            }
        } catch {
            Write-Host "❌ 恢复自动保存时发生错误: $_" -ForegroundColor Red
        }
    }
}

# 恢复 Git Stash (仅在 Git 仓库内)
if (Get-Command git -ErrorAction SilentlyContinue) {
    Set-Location $WorkspaceRoot
    $inWorkTree = $false
    try {
        $null = git rev-parse --is-inside-work-tree 2>$null
        if ($LASTEXITCODE -eq 0) { $inWorkTree = $true }
    } catch {}

    if ($inWorkTree) {
        $stashList = git stash list 2>$null
        if ($stashList -match "Rayman WIP") {
            git stash pop | Out-Null
            Write-Host "✅ 已恢复 Git Stash 中的工作区状态" -ForegroundColor Green
        }
    }
}

& "$PSScriptRoot\..\utils\request_attention.ps1" -Message "欢迎回来，状态已恢复，请继续工作"
