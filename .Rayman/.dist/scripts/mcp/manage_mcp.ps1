param(
    [ValidateSet('status', 'start', 'normalize')][string]$Action = 'status',
    [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
    [switch]$Persist,
    [switch]$CreateBackup,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
    . $commonPath
}

function Get-RaymanMcpConfigPaths([string]$Root) {
    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
    return [pscustomobject]@{
        WorkspaceRoot = $resolvedRoot
        RaymanDir = (Join-Path $resolvedRoot '.Rayman')
        ConfigPath = (Join-Path $resolvedRoot '.Rayman\mcp\mcp_servers.json')
        RuntimeDir = (Join-Path $resolvedRoot '.Rayman\runtime\mcp')
        PidFile = (Join-Path $resolvedRoot '.Rayman\runtime\mcp\sqlite.pid')
        StatusFile = (Join-Path $resolvedRoot '.Rayman\runtime\mcp\status.json')
        DbPath = '${workspaceRoot}/.Rayman/state/rayman.db'
    }
}

function Get-DefaultMcpConfig([string]$DbPathToken) {
    return [ordered]@{
        mcpServers = [ordered]@{
            sqlite = [ordered]@{
                command = 'npx'
                args = @('-y', '@modelcontextprotocol/server-sqlite', '--db-path', $DbPathToken)
            }
        }
    }
}

function Get-McpConfigObject([string]$Path, [string]$DbPathToken) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return (Get-DefaultMcpConfig -DbPathToken $DbPathToken)
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        return $parsed
    } catch {
        Write-Warn ("[mcp] config parse failed, fallback to defaults: {0}" -f $_.Exception.Message)
        return (Get-DefaultMcpConfig -DbPathToken $DbPathToken)
    }
}

function ConvertTo-NormalizedMcpConfig {
    param(
        [object]$Config,
        [string]$DbPathToken
    )

    $command = 'npx'
    if ($null -ne $Config -and $null -ne $Config.mcpServers -and $null -ne $Config.mcpServers.sqlite -and -not [string]::IsNullOrWhiteSpace([string]$Config.mcpServers.sqlite.command)) {
        $command = [string]$Config.mcpServers.sqlite.command
    }

    return [ordered]@{
        mcpServers = [ordered]@{
            sqlite = [ordered]@{
                command = $command
                args = @('-y', '@modelcontextprotocol/server-sqlite', '--db-path', $DbPathToken)
            }
        }
    }
}

function Save-McpConfig {
    param(
        [hashtable]$Config,
        [string]$Path,
        [switch]$CreateBackup
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    if ($CreateBackup -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $backupPath = $Path + '.bak'
        Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    }

    $Config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-CommandPathSafe([string]$Name) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $cmd) { return $null }
    return [string]$cmd.Source
}

function Get-ActivePidInfo([string]$PidFile) {
    $pidValue = 0
    if (Get-Command Get-RaymanPidFromFile -ErrorAction SilentlyContinue) {
        $pidValue = Get-RaymanPidFromFile -PidFilePath $PidFile
    } elseif (Test-Path -LiteralPath $PidFile -PathType Leaf) {
        $raw = (Get-Content -LiteralPath $PidFile -Raw -Encoding ASCII).Trim()
        [void][int]::TryParse($raw, [ref]$pidValue)
    }

    $running = $false
    if ($pidValue -gt 0) {
        $proc = Get-Process -Id $pidValue -ErrorAction SilentlyContinue | Select-Object -First 1
        $running = ($null -ne $proc)
    }

    return [pscustomobject]@{
        Pid = $pidValue
        Running = $running
    }
}

function Write-McpStatusFile([string]$Path, [object]$Status) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $Status | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

$paths = Get-RaymanMcpConfigPaths -Root $WorkspaceRoot
$config = Get-McpConfigObject -Path $paths.ConfigPath -DbPathToken $paths.DbPath
$normalized = ConvertTo-NormalizedMcpConfig -Config $config -DbPathToken $paths.DbPath

if ($Persist -or $Action -eq 'normalize' -or -not (Test-Path -LiteralPath $paths.ConfigPath -PathType Leaf)) {
    Save-McpConfig -Config $normalized -Path $paths.ConfigPath -CreateBackup:$CreateBackup
}

$active = Get-ActivePidInfo -PidFile $paths.PidFile
$status = [pscustomobject]@{
    action = $Action
    workspace_root = $paths.WorkspaceRoot
    config_path = $paths.ConfigPath
    db_path = $paths.DbPath
    config_normalized = $true
    pid = $active.Pid
    running = $active.Running
    started = $false
    message = ''
}

switch ($Action) {
    'normalize' {
        $status.message = 'mcp_servers.json 已规范化为可移植路径。'
    }
    'status' {
        $status.message = if ($active.Running) { 'MCP sqlite server 已运行。' } else { 'MCP 配置可用，当前未检测到运行中的 sqlite server。' }
    }
    'start' {
        if ($active.Running) {
            $status.started = $true
            $status.message = 'MCP sqlite server 已在运行，无需重复启动。'
        } else {
            $sqlite = $normalized.mcpServers.sqlite
            $commandName = [string]$sqlite.command
            $resolvedCommand = if ($commandName -eq 'npx') {
                $candidate = Get-CommandPathSafe -Name 'npx.cmd'
                if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = Get-CommandPathSafe -Name 'npx' }
                $candidate
            } else {
                Get-CommandPathSafe -Name $commandName
            }

            if ([string]::IsNullOrWhiteSpace($resolvedCommand)) {
                $status.message = '未找到 npx 命令；已保留规范化配置，可在安装 Node.js 后重试。'
            } else {
                try {
                    if (-not (Test-Path -LiteralPath $paths.RuntimeDir -PathType Container)) {
                        New-Item -ItemType Directory -Force -Path $paths.RuntimeDir | Out-Null
                    }
                    $proc = Start-RaymanProcessHiddenCompat -FilePath $resolvedCommand -ArgumentList @([string[]]$sqlite.args) -WorkingDirectory $paths.WorkspaceRoot
                    Set-Content -LiteralPath $paths.PidFile -Value $proc.Id -NoNewline -Encoding ASCII
                    $status.pid = [int]$proc.Id
                    $status.running = $true
                    $status.started = $true
                    $status.message = 'MCP sqlite server 已后台启动。'
                } catch {
                    $status.message = ("MCP 启动降级：{0}" -f $_.Exception.Message)
                    if (Get-Command Write-RaymanDiag -ErrorAction SilentlyContinue) {
                        Write-RaymanDiag -Scope 'mcp' -Message ("start failed: {0}" -f $_.Exception.ToString()) -WorkspaceRoot $paths.WorkspaceRoot
                    }
                }
            }
        }
    }
}

Write-McpStatusFile -Path $paths.StatusFile -Status $status

if ($Json) {
    $status | ConvertTo-Json -Depth 6
} else {
    Write-Host ("[mcp] {0}" -f $status.message)
}
