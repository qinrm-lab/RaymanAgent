param(
    [Parameter(Mandatory=$true)][string]$FilePath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
    Write-Host "❌ 无法找到目标文件: $FilePath" -ForegroundColor Red
    exit 1
}

$bakFilePath = "$FilePath.probe_bak"
if (Test-Path -LiteralPath $bakFilePath -PathType Leaf) {
    try {
        Copy-Item -LiteralPath $bakFilePath -Destination $FilePath -Force
        Remove-Item -LiteralPath $bakFilePath -Force
        Write-Host "✅ 已成功回滚并清理探针，恢复文件: $FilePath" -ForegroundColor Green
    } catch {
        Write-Host "❌ 恢复源文件时出错: $_" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "⚠️ 未找到 $FilePath 的探针备份文件 ($bakFilePath)，可能未注入过探针或已被清理。" -ForegroundColor Yellow
}
