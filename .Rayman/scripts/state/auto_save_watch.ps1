<#
.SYNOPSIS
    Rayman 自动状态保存后台服务 (Auto-Save Watcher)
.DESCRIPTION
    定期（如每 5 分钟）检查工作区是否有未提交的更改。
    如果有，则自动执行轻量级的状态保存（不使用 Git Stash，以免干扰用户正常工作流，
    而是将当前未提交的 diff 备份到 .Rayman/state/auto_save.patch）。
    这样即使断电，用户也可以通过应用 patch 恢复未保存的代码。
#>
param (
    [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
    [string]$PidFile,
    [int]$IntervalSeconds = 300 # 默认 5 分钟
)

$ErrorActionPreference = "SilentlyContinue"
$StateDir = Join-Path $WorkspaceRoot ".Rayman\state"
$PatchFile = Join-Path $StateDir "auto_save.patch"
$MetaFile = Join-Path $StateDir "auto_save_meta.json"

if (-not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
}

Write-Host "[auto-save] 启动自动保存服务，间隔: $IntervalSeconds 秒"

while ($true) {
    Start-Sleep -Seconds $IntervalSeconds

    # 检查 Git 状态
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Set-Location $WorkspaceRoot
        $inWorkTree = $false
        try {
            $null = git rev-parse --is-inside-work-tree 2>$null
            if ($LASTEXITCODE -eq 0) { $inWorkTree = $true }
        } catch {}

        if ($inWorkTree) {
            # 检查是否有未提交的更改 (包括 untracked files)
            $status = git status --porcelain
            if ($status) {
                # 生成包含所有更改的 patch (包括 staged 和 unstaged)
                # 注意：git diff 默认不包含 untracked files，我们需要先 add -N
                git add -N .
                git diff > $PatchFile
                
                # 记录元数据
                $meta = @{
                    timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                    files_changed = $status.Count
                }
                $meta | ConvertTo-Json | Set-Content $MetaFile -Encoding UTF8
                
                Write-Host "[auto-save] $(Get-Date -Format 'HH:mm:ss') 自动保存了 $($status.Count) 个文件的更改到 $PatchFile"
            } else {
                # 工作区干净，清理旧的自动保存
                if (Test-Path $PatchFile) { Remove-Item $PatchFile -Force }
                if (Test-Path $MetaFile) { Remove-Item $MetaFile -Force }
            }
        }
    }
}
