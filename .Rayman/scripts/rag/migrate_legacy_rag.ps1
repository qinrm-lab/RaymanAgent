param(
    [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
    [string]$RagRoot = "",
    [string]$Namespace = "",
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path

function Copy-DirectoryPortable {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $robocopyCmd = Get-Command 'robocopy' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $robocopyCmd -and -not [string]::IsNullOrWhiteSpace([string]$robocopyCmd.Source)) {
        & $robocopyCmd.Source $SourcePath $DestinationPath /E /COPY:DAT /R:1 /W:1 | Out-Null
        $rc = $LASTEXITCODE
        if ($rc -gt 7) {
            throw ("robocopy failed with exit code: {0}" -f $rc)
        }
        return
    }

    Write-Host "⚠️ [RAG-MIGRATE] 未找到 robocopy，回退到 Copy-Item 递归复制。" -ForegroundColor Yellow
    $items = @(Get-ChildItem -LiteralPath $SourcePath -Force -ErrorAction SilentlyContinue)
    foreach ($item in $items) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $DestinationPath $item.Name) -Recurse -Force
    }
}

if ([string]::IsNullOrWhiteSpace($RagRoot)) {
    $RagRoot = [string]$env:RAYMAN_RAG_ROOT
}
if ([string]::IsNullOrWhiteSpace($RagRoot)) {
    $RagRoot = Join-Path $WorkspaceRoot '.rag'
} elseif (-not [System.IO.Path]::IsPathRooted($RagRoot)) {
    $RagRoot = Join-Path $WorkspaceRoot $RagRoot
}

if ([string]::IsNullOrWhiteSpace($Namespace)) {
    $Namespace = [string]$env:RAYMAN_RAG_NAMESPACE
}
if ([string]::IsNullOrWhiteSpace($Namespace)) {
    $Namespace = Split-Path -Leaf $WorkspaceRoot
}

foreach ($invalidCh in [System.IO.Path]::GetInvalidFileNameChars()) {
    $Namespace = $Namespace.Replace([string]$invalidCh, '_')
}
if ([string]::IsNullOrWhiteSpace($Namespace)) {
    $Namespace = 'default'
}

$legacyChroma = Join-Path $WorkspaceRoot '.Rayman\state\chroma_db'
$legacySqlite = Join-Path $WorkspaceRoot '.Rayman\state\rag.db'
$targetProjectRoot = Join-Path $RagRoot $Namespace
$targetChroma = Join-Path $targetProjectRoot 'chroma_db'
$targetSqlite = Join-Path $targetProjectRoot 'rag.db'

$legacyHasChroma = $false
if (Test-Path -LiteralPath $legacyChroma -PathType Container) {
    try {
        $legacyHasChroma = $null -ne (Get-ChildItem -LiteralPath $legacyChroma -Recurse -File -ErrorAction Stop | Select-Object -First 1)
    } catch {
        $legacyHasChroma = $false
    }
}
$legacyHasSqlite = Test-Path -LiteralPath $legacySqlite -PathType Leaf

if (-not $legacyHasChroma -and -not $legacyHasSqlite) {
    Write-Host "ℹ️ [RAG-MIGRATE] 未发现旧路径数据，已跳过。" -ForegroundColor Cyan
    exit 0
}

$targetHasChroma = $false
if (Test-Path -LiteralPath $targetChroma -PathType Container) {
    try {
        $targetHasChroma = $null -ne (Get-ChildItem -LiteralPath $targetChroma -Recurse -File -ErrorAction Stop | Select-Object -First 1)
    } catch {
        $targetHasChroma = $false
    }
}

if ($targetHasChroma -and -not $Force) {
    Write-Host "ℹ️ [RAG-MIGRATE] 目标路径已有向量库，未迁移（可用 -Force 覆盖）。" -ForegroundColor Cyan
    Write-Host "   目标路径: $targetChroma" -ForegroundColor DarkCyan
    exit 0
}

New-Item -ItemType Directory -Force -Path $targetProjectRoot | Out-Null
New-Item -ItemType Directory -Force -Path $targetChroma | Out-Null

if ($legacyHasChroma) {
    Write-Host "📦 [RAG-MIGRATE] 迁移 ChromaDB: $legacyChroma -> $targetChroma" -ForegroundColor Yellow
    try {
        Copy-DirectoryPortable -SourcePath $legacyChroma -DestinationPath $targetChroma
    } catch {
        Write-Host ("❌ [RAG-MIGRATE] ChromaDB 迁移失败：{0}" -f $_.Exception.Message) -ForegroundColor Red
        exit 2
    }
}

if ($legacyHasSqlite) {
    Write-Host "📦 [RAG-MIGRATE] 迁移 rag.db: $legacySqlite -> $targetSqlite" -ForegroundColor Yellow
    Copy-Item -LiteralPath $legacySqlite -Destination $targetSqlite -Force
}

Write-Host "✅ [RAG-MIGRATE] 迁移完成" -ForegroundColor Green
Write-Host "   Namespace : $Namespace" -ForegroundColor DarkGreen
Write-Host "   ChromaDB  : $targetChroma" -ForegroundColor DarkGreen
if (Test-Path -LiteralPath $targetSqlite -PathType Leaf) {
    Write-Host "   SQLite    : $targetSqlite" -ForegroundColor DarkGreen
}

exit 0
