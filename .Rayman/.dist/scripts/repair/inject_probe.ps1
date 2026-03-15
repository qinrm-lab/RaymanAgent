param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [Parameter(Mandatory=$true)][int]$LineNumber,
    [Parameter(Mandatory=$true)][string]$ProbeCode,
    [switch]$KeepBak
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
    Write-Host "❌ 无法找到目标文件: $FilePath" -ForegroundColor Red
    exit 1
}

$bakFilePath = "$FilePath.probe_bak"
if (-not (Test-Path -LiteralPath $bakFilePath -PathType Leaf)) {
    # 建立备份文件以便回滚
    Copy-Item -LiteralPath $FilePath -Destination $bakFilePath -Force
    Write-Host "✅ 已备份源文件至: $bakFilePath" -ForegroundColor Cyan
}

try {
    $lines = [System.Collections.Generic.List[string]](Get-Content -LiteralPath $FilePath -Encoding UTF8)
    
    if ($LineNumber -le 0 -or $LineNumber -gt ($lines.Count + 1)) {
        throw "行号越界"
    }

    # 简单注入：在指定行前面直接插入探针代码
    # 因为是以 1 为基准的行号
    $insertIndex = $LineNumber - 1
    
    $prefix = "/* [RAYMAN-PROBE] */ "
    if ($FilePath -match '\.py$') {
        $prefix = "# [RAYMAN-PROBE] "
    } elseif ($FilePath -match '\.cs$') {
        $prefix = "/* [RAYMAN-PROBE] */ "
    }

    $injectedLine = $prefix + $ProbeCode
    $lines.Insert($insertIndex, $injectedLine)

    Set-Content -LiteralPath $FilePath -Value $lines.ToArray() -Encoding UTF8
    Write-Host "✅ 成功在 $FilePath 第 ${LineNumber} 行注入探针: $ProbeCode" -ForegroundColor Green

} catch {
    Write-Host "❌ 探针注入失败: $_" -ForegroundColor Red
    exit 1
}
