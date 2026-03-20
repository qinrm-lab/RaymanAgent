param(
    [string]$WorkspaceRoot = $(Resolve-Path (Join-Path $PSScriptRoot "..\..\..") | Select-Object -ExpandProperty Path),
    [int]$ExpireHours = 24 # 默认状态过期时间为 24 小时
)

. (Join-Path $PSScriptRoot "..\..\common.ps1")

$stateFile = Join-Path $WorkspaceRoot ".Rayman\state\pending_task.md"

if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
    $fileInfo = Get-Item -LiteralPath $stateFile
    $timeDiff = (Get-Date) - $fileInfo.LastWriteTime

    # 检查状态是否过期
    if ($timeDiff.TotalHours -gt $ExpireHours) {
        Write-Host ""
        Write-Host "=======================================================" -ForegroundColor Gray
        Write-Host "🧹 RAYMAN AI 提示: 发现过期的任务状态文件，已自动清理。" -ForegroundColor Gray
        Write-Host "=======================================================" -ForegroundColor Gray
        Write-Host ""
        try {
            Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
        } catch {}
        exit 0
    }

    $content = Get-Content -LiteralPath $stateFile -Raw
    if (-not [string]::IsNullOrWhiteSpace($content)) {
        $pendingMessage = "您有一个未完成的 AI 任务！请在 Copilot 中输入 '继续' 恢复执行。"
        Write-Host ""
        Write-Host "=======================================================" -ForegroundColor Yellow -BackgroundColor Black
        Write-Host "⚠️  RAYMAN AI 提示: 您有一个未完成的 AI 任务！" -ForegroundColor Yellow -BackgroundColor Black
        Write-Host "👉  请在 Copilot 聊天框中输入 '继续' 来恢复执行。" -ForegroundColor Cyan -BackgroundColor Black
        Write-Host "=======================================================" -ForegroundColor Yellow -BackgroundColor Black
        Write-Host ""

        try {
            Invoke-RaymanAttentionAlert -Kind 'manual' -Title 'Rayman AI 提示' -Reason $pendingMessage -WorkspaceRoot $WorkspaceRoot | Out-Null
        } catch {}

        # 退出码为 1，以便 VS Code 任务在 silent 模式下自动弹出终端
        exit 1
    }
}

exit 0
