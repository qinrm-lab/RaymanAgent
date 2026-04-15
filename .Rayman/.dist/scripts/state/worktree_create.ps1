param(
    [string]$WorkspaceRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..\..\..') | Select-Object -ExpandProperty Path),
    [string]$Name = '',
    [string]$BaseRef = 'HEAD',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'session_common.ps1')

function Test-WorktreePathIsGitRepo {
    param(
        [string]$GitPath,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($GitPath) -or [string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    & $GitPath -C $Path rev-parse --is-inside-work-tree 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

$resolvedWorkspaceRootInput = if ($PSBoundParameters.ContainsKey('WorkspaceRoot')) { [string]$PSBoundParameters['WorkspaceRoot'] } else { $WorkspaceRoot }
$ResolvedWorkspaceRoot = Get-RaymanStateWorkspaceRoot -WorkspaceRoot $resolvedWorkspaceRootInput
$runtimeContext = Get-RaymanSessionRuntimeContext -WorkspaceRoot $ResolvedWorkspaceRoot
$sessionName = Resolve-RaymanSessionDisplayName -Name $Name
$slug = ConvertTo-RaymanSessionSlug -Name $sessionName
$existing = Read-RaymanSessionManifest -WorkspaceRoot $ResolvedWorkspaceRoot -Slug $slug
$worktreePath = if ($null -ne $existing -and -not [string]::IsNullOrWhiteSpace([string]$existing.worktree_path)) {
    [string]$existing.worktree_path
} else {
    Get-RaymanSessionWorktreePath -WorkspaceRoot $ResolvedWorkspaceRoot -Slug $slug
}
$branch = if ($null -ne $existing -and -not [string]::IsNullOrWhiteSpace([string]$existing.branch)) {
    [string]$existing.branch
} else {
    Get-RaymanSessionBranchName -Slug $slug
}

$gitPath = Get-RaymanGitCommandPath
if ([string]::IsNullOrWhiteSpace($gitPath)) {
    throw 'git command not found; worktree-create requires git'
}

if (-not (Test-RaymanGitWorkTree -WorkspaceRoot $ResolvedWorkspaceRoot)) {
    throw 'worktree-create requires a git worktree workspace'
}

$created = $false
if (Test-Path -LiteralPath $worktreePath -PathType Container) {
    if (-not (Test-WorktreePathIsGitRepo -GitPath $gitPath -Path $worktreePath)) {
        throw ("worktree path already exists and is not a git worktree: {0}" -f $worktreePath)
    }
} else {
    $parent = Split-Path -Parent $worktreePath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $saved = Get-Location
    try {
        Set-Location -LiteralPath $ResolvedWorkspaceRoot
        & $gitPath show-ref --verify --quiet ("refs/heads/{0}" -f $branch)
        $branchExists = ($LASTEXITCODE -eq 0)
        if ($branchExists) {
            & $gitPath worktree add $worktreePath $branch | Out-Null
        } else {
            & $gitPath worktree add -b $branch $worktreePath $BaseRef | Out-Null
        }
        if ($LASTEXITCODE -ne 0) {
            throw ("git worktree add failed for {0}" -f $worktreePath)
        }
        $created = $true
    } finally {
        Set-Location -LiteralPath $saved.Path
    }
}

$paths = Get-RaymanSessionPaths -WorkspaceRoot $ResolvedWorkspaceRoot -Slug $slug
if (-not (Test-Path -LiteralPath $paths.session_dir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $paths.session_dir | Out-Null
}

if (-not (Test-Path -LiteralPath $paths.handover_path -PathType Leaf)) {
    $handover = @"
# Worktree Session

- 名称: $sessionName
- 模式: worktree
- 分支: $branch
- 路径: $worktreePath
- BaseRef: $BaseRef
"@
    Write-RaymanSessionTextFile -Path $paths.handover_path -Content (($handover.TrimEnd()) + "`n")
}

$manifest = New-RaymanSessionManifest `
    -WorkspaceRoot $ResolvedWorkspaceRoot `
    -Name $sessionName `
    -Slug $slug `
    -Status 'paused' `
    -Isolation 'worktree' `
    -TaskDescription $(if ($null -ne $existing -and $existing.PSObject.Properties['task_description']) { [string]$existing.task_description } else { '' }) `
    -StashOid $(if ($null -ne $existing -and $existing.PSObject.Properties['stash_oid']) { [string]$existing.stash_oid } else { '' }) `
    -WorktreePath $worktreePath `
    -Branch $branch `
    -SessionKind $(if ($null -ne $existing -and $existing.PSObject.Properties['session_kind']) { [string]$existing.session_kind } else { 'manual' }) `
    -Backend ([string]$runtimeContext.backend) `
    -AccountAlias ([string]$runtimeContext.account_alias) `
    -OwnerContext $runtimeContext.owner_context `
    -Existing $existing
Save-RaymanSessionManifest -WorkspaceRoot $ResolvedWorkspaceRoot -Manifest $manifest | Out-Null

$result = [ordered]@{
    schema = 'rayman.state.worktree_create.v1'
    workspace_root = $ResolvedWorkspaceRoot
    name = $sessionName
    slug = $slug
    branch = $branch
    worktree_path = $worktreePath
    created = $created
    status = 'paused'
}

if ($Json) {
    $result | ConvertTo-Json -Depth 8
    exit 0
}

Write-Host ("✅ 命名会话已绑定 worktree: {0}" -f $sessionName) -ForegroundColor Green
Write-Host ("   branch={0}" -f $branch) -ForegroundColor DarkCyan
Write-Host ("   path={0}" -f $worktreePath) -ForegroundColor DarkCyan
