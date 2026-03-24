param(
    [ValidateSet('status', 'record', 'summarize', 'search', 'prune')][string]$Action = 'status',
    [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
    [string]$InputJsonFile = '',
    [string]$Query = '',
    [string]$TaskKey = '',
    [string]$TaskKind = '',
    [string]$Scope = '',
    [string]$Kind = '',
    [string[]]$Tags = @(),
    [int]$Limit = 5,
    [int]$RecentLimit = 2,
    [int]$MaxAgeDays = 0,
    [int]$KeepPerTask = 0,
    [switch]$DrainPending,
    [switch]$Prewarm,
    [switch]$NoInstallDeps,
    [switch]$Json,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bootstrapPath = Join-Path $PSScriptRoot 'memory_bootstrap.ps1'
if (-not (Test-Path -LiteralPath $bootstrapPath -PathType Leaf)) {
    throw "memory_bootstrap.ps1 not found: $bootstrapPath"
}
. $bootstrapPath

$resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$bootstrap = Invoke-RaymanMemoryBootstrap -WorkspaceRoot $resolvedRoot -EnsureDeps:$false -NoInstallDeps:$NoInstallDeps -Prewarm:$Prewarm -Quiet:$Quiet
if (-not $bootstrap.Success) {
    if ($Json) {
        [pscustomobject]@{
            schema = 'rayman.agent_memory.error.v1'
            success = $false
            message = [string]$bootstrap.Message
            action = $Action
        } | ConvertTo-Json -Depth 6
        exit 1
    }
    throw $bootstrap.Message
}

$backendPath = Join-Path $resolvedRoot '.Rayman\scripts\memory\manage_memory.py'
$pythonArgs = New-Object System.Collections.Generic.List[string]
foreach ($item in @($bootstrap.PythonArgs)) {
    $pythonArgs.Add([string]$item) | Out-Null
}
$pythonArgs.Add($backendPath) | Out-Null
$pythonArgs.Add($Action) | Out-Null
$pythonArgs.Add('--workspace-root') | Out-Null
$pythonArgs.Add($resolvedRoot) | Out-Null

if (-not [string]::IsNullOrWhiteSpace($InputJsonFile)) {
    $pythonArgs.Add('--input-json-file') | Out-Null
    $pythonArgs.Add((Resolve-Path -LiteralPath $InputJsonFile).Path) | Out-Null
}
if (-not [string]::IsNullOrWhiteSpace($Query)) {
    $pythonArgs.Add('--query') | Out-Null
    $pythonArgs.Add($Query) | Out-Null
}
if (-not [string]::IsNullOrWhiteSpace($TaskKey)) {
    $pythonArgs.Add('--task-key') | Out-Null
    $pythonArgs.Add($TaskKey) | Out-Null
}
if (-not [string]::IsNullOrWhiteSpace($TaskKind)) {
    $pythonArgs.Add('--task-kind') | Out-Null
    $pythonArgs.Add($TaskKind) | Out-Null
}
if (-not [string]::IsNullOrWhiteSpace($Scope)) {
    $pythonArgs.Add('--scope') | Out-Null
    $pythonArgs.Add($Scope) | Out-Null
}
if (-not [string]::IsNullOrWhiteSpace($Kind)) {
    $pythonArgs.Add('--kind') | Out-Null
    $pythonArgs.Add($Kind) | Out-Null
}
foreach ($tag in @($Tags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    $pythonArgs.Add('--tag') | Out-Null
    $pythonArgs.Add([string]$tag) | Out-Null
}
if ($Limit -gt 0) {
    $pythonArgs.Add('--limit') | Out-Null
    $pythonArgs.Add([string]$Limit) | Out-Null
}
if ($RecentLimit -ge 0) {
    $pythonArgs.Add('--recent-limit') | Out-Null
    $pythonArgs.Add([string]$RecentLimit) | Out-Null
}
if ($MaxAgeDays -gt 0) {
    $pythonArgs.Add('--max-age-days') | Out-Null
    $pythonArgs.Add([string]$MaxAgeDays) | Out-Null
}
if ($KeepPerTask -gt 0) {
    $pythonArgs.Add('--keep-per-task') | Out-Null
    $pythonArgs.Add([string]$KeepPerTask) | Out-Null
}
if ($DrainPending) {
    $pythonArgs.Add('--drain-pending') | Out-Null
}
if ($Prewarm) {
    $pythonArgs.Add('--prewarm') | Out-Null
}
if ($Json) {
    $pythonArgs.Add('--json') | Out-Null
}

& $bootstrap.PythonExe $pythonArgs.ToArray()
exit $LASTEXITCODE
