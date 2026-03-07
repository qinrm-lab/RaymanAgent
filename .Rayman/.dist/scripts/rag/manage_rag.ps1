param(
    [ValidateSet('status', 'build')][string]$Action = 'status',
    [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
    [switch]$Reset,
    [switch]$NoInstallDeps,
    [switch]$Json,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
    . $commonPath
}

$bootstrapPath = Join-Path $PSScriptRoot 'rag_bootstrap.ps1'
if (Test-Path -LiteralPath $bootstrapPath -PathType Leaf) {
    . $bootstrapPath
}

function Write-RagInfo([string]$Message) {
    if (-not $Quiet) {
        Write-Host ("[rag] {0}" -f $Message) -ForegroundColor DarkCyan
    }
}

function Write-RagWarn([string]$Message) {
    if (-not $Quiet) {
        Write-Host ("[rag] {0}" -f $Message) -ForegroundColor Yellow
    }
}

function Ensure-RaymanDirectory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

$resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$paths = Get-RaymanRagPaths -WorkspaceRoot $resolvedRoot
$buildScript = Join-Path $PSScriptRoot 'build_index.py'
$requirementsPath = Join-Path $PSScriptRoot 'requirements.txt'
$statusFile = Join-Path $resolvedRoot '.Rayman\runtime\rag\status.json'
Ensure-RaymanDirectory -Path (Split-Path -Parent $statusFile)

if ($Reset) {
    foreach ($target in @($paths.ChromaDbPath, $paths.IndexRoot)) {
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Ensure-RaymanDirectory -Path $paths.RagRoot
Ensure-RaymanDirectory -Path $paths.ProjectRoot
Ensure-RaymanDirectory -Path $paths.ChromaDbPath
Ensure-RaymanDirectory -Path $paths.IndexRoot

$bootstrap = $null
$depsReady = $false
if (Get-Command Invoke-RaymanRagBootstrap -ErrorAction SilentlyContinue) {
    try {
        $bootstrap = Invoke-RaymanRagBootstrap -WorkspaceRoot $resolvedRoot -EnsureDeps:(-not $NoInstallDeps) -NoInstallDeps:$NoInstallDeps -Quiet:$Quiet
        $depsReady = [bool]$bootstrap.Success
    } catch {
        $bootstrap = [pscustomobject]@{
            Success = $false
            Message = $_.Exception.Message
            PythonExe = ''
            PythonArgs = @()
            PythonLabel = ''
        }
        $depsReady = $false
    }
}

$manifestPath = Join-Path $paths.IndexRoot 'manifest.json'
$indexBuilt = $false
$indexMessage = ''

if ($Action -eq 'build') {
    if ($depsReady -and -not [string]::IsNullOrWhiteSpace([string]$bootstrap.PythonExe) -and (Test-Path -LiteralPath $buildScript -PathType Leaf)) {
        try {
            $pythonArgs = @($bootstrap.PythonArgs + @(
                $buildScript,
                '--workspace-root', $resolvedRoot,
                '--output', $manifestPath,
                '--namespace', $paths.Namespace,
                '--chroma-db-path', $paths.ChromaDbPath
            ))
            & $bootstrap.PythonExe @pythonArgs | Out-Null
            $indexBuilt = $true
            $indexMessage = '索引清单已生成。'
        } catch {
            $indexMessage = ("索引构建降级：{0}" -f $_.Exception.Message)
        }
    } else {
        $indexMessage = 'RAG 依赖未完全就绪，已完成目录初始化并跳过索引构建。'
    }
} else {
    $indexBuilt = (Test-Path -LiteralPath $manifestPath -PathType Leaf)
    $indexMessage = if ($indexBuilt) { '索引清单已存在。' } else { '尚未发现索引清单。' }
}

$status = [pscustomobject]@{
    action = $Action
    workspace_root = $resolvedRoot
    namespace = $paths.Namespace
    rag_root = $paths.RagRoot
    chroma_db_path = $paths.ChromaDbPath
    index_root = $paths.IndexRoot
    requirements_path = $requirementsPath
    build_script = $buildScript
    deps_ready = $depsReady
    bootstrap_message = if ($null -ne $bootstrap) { [string]$bootstrap.Message } else { 'rag_bootstrap.ps1 不可用' }
    python = if ($null -ne $bootstrap) { [string]$bootstrap.PythonLabel } else { '' }
    index_built = $indexBuilt
    message = $indexMessage
}

$status | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statusFile -Encoding UTF8

if ($Json) {
    $status | ConvertTo-Json -Depth 6
} else {
    if ($depsReady) {
        Write-RagInfo $status.message
    } else {
        Write-RagWarn (("{0} ({1})" -f $status.message, $status.bootstrap_message).Trim())
    }
}
