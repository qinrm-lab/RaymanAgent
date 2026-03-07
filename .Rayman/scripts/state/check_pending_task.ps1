param(
    [string]$WorkspaceRoot = $(Resolve-Path (Join-Path $PSScriptRoot "..\..\..") | Select-Object -ExpandProperty Path),
    [int]$ExpireHours = 24 # 默认状态过期时间为 24 小时
)

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
        Write-Host ""
        Write-Host "=======================================================" -ForegroundColor Yellow -BackgroundColor Black
        Write-Host "⚠️  RAYMAN AI 提示: 您有一个未完成的 AI 任务！" -ForegroundColor Yellow -BackgroundColor Black
        Write-Host "👉  请在 Copilot 聊天框中输入 '继续' 来恢复执行。" -ForegroundColor Cyan -BackgroundColor Black
        Write-Host "=======================================================" -ForegroundColor Yellow -BackgroundColor Black
        Write-Host ""
        
        # 尝试发送桌面通知
        try {
            if ($IsWindows) {
                [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
                [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
                
                $template = @"
<toast>
    <visual>
        <binding template="ToastText02">
            <text id="1">Rayman AI 提示</text>
            <text id="2">您有一个未完成的 AI 任务！请在 Copilot 中输入 '继续' 恢复执行。</text>
        </binding>
    </visual>
</toast>
"@
                $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
                $xml.LoadXml($template)
                $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
                [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Rayman AI").Show($toast)
            } elseif ($IsLinux -or $IsMacOS) {
                if (Get-Command notify-send -ErrorAction SilentlyContinue) {
                    notify-send "Rayman AI 提示" "您有一个未完成的 AI 任务！请在 Copilot 中输入 '继续' 恢复执行。"
                }
            }
        } catch {
            # 忽略通知发送失败
        }

        # 退出码为 1，以便 VS Code 任务在 silent 模式下自动弹出终端
        exit 1
    }
}

exit 0
