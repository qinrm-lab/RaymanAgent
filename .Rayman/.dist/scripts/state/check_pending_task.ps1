param(
    [string]$WorkspaceRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..\..\..') | Select-Object -ExpandProperty Path),
    [int]$ExpireHours = 24
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'session_common.ps1')

$WorkspaceRoot = Get-RaymanStateWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
$legacy = Get-RaymanLegacyStatePaths -WorkspaceRoot $WorkspaceRoot

if (Test-Path -LiteralPath $legacy.pending_path -PathType Leaf) {
    $fileInfo = Get-Item -LiteralPath $legacy.pending_path
    $timeDiff = (Get-Date) - $fileInfo.LastWriteTime
    if ($timeDiff.TotalHours -gt $ExpireHours) {
        try {
            Remove-Item -LiteralPath $legacy.pending_path -Force -ErrorAction SilentlyContinue
        } catch {}
    }
}

$records = @(Get-RaymanSessionRecords -WorkspaceRoot $WorkspaceRoot)
if ($records.Count -le 0) {
    exit 0
}

$names = @($records | Select-Object -First 5 | ForEach-Object { [string]$_.name })
$pendingMessage = "发现未完成的命名会话：$($names -join '、')。请先执行 rayman.ps1 state-list，再用 rayman.ps1 state-resume -Name <name> 恢复。"

Write-Host ''
Write-Host '=======================================================' -ForegroundColor Yellow -BackgroundColor Black
Write-Host '⚠️  RAYMAN AI 提示: 发现未完成的命名会话！' -ForegroundColor Yellow -BackgroundColor Black
foreach ($record in @($records | Select-Object -First 5)) {
    Write-Host ("   - {0} | isolation={1} | updated={2}" -f [string]$record.name, [string]$record.isolation, [string]$record.updated_at) -ForegroundColor Cyan -BackgroundColor Black
}
if ($records.Count -gt 5) {
    Write-Host ("   - 其余 {0} 个会话请使用 state-list 查看" -f ($records.Count - 5)) -ForegroundColor Cyan -BackgroundColor Black
}
Write-Host '👉  请先运行 `rayman.ps1 state-list`，再按名字恢复。' -ForegroundColor Cyan -BackgroundColor Black
Write-Host '=======================================================' -ForegroundColor Yellow -BackgroundColor Black
Write-Host ''

try {
    Invoke-RaymanAttentionAlert -Kind 'manual' -Title 'Rayman AI 提示' -Reason $pendingMessage -WorkspaceRoot $WorkspaceRoot | Out-Null
} catch {}

exit 1
