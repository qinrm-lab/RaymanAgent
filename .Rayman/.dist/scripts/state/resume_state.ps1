param(
    [string]$WorkspaceRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..\..\..') | Select-Object -ExpandProperty Path),
    [string]$Name = '',
    [switch]$AllowAlreadyResumed,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'session_common.ps1')
$sharedSessionHelperPath = Join-Path $PSScriptRoot 'shared_session_common.ps1'
if (Test-Path -LiteralPath $sharedSessionHelperPath -PathType Leaf) {
    . $sharedSessionHelperPath
}

function Invoke-RaymanSessionPatchRestore {
    param(
        [string]$TargetRoot,
        [string]$PatchPath
    )

    $result = [ordered]@{
        success = $false
        applied = $false
        reason = 'patch_missing'
    }

    if ([string]::IsNullOrWhiteSpace($PatchPath) -or -not (Test-Path -LiteralPath $PatchPath -PathType Leaf)) {
        return [pscustomobject]$result
    }

    Write-Host "⚠️ 发现命名会话遗留的自动保存 Patch，正在尝试恢复..." -ForegroundColor Yellow
    $gitPath = Get-RaymanGitCommandPath
    if ([string]::IsNullOrWhiteSpace($gitPath)) {
        $result.reason = 'git_missing'
        return [pscustomobject]$result
    }

    $saved = Get-Location
    try {
        Set-Location -LiteralPath $TargetRoot
        & $gitPath apply --check $PatchPath 2>$null
        if ($LASTEXITCODE -eq 0) {
            & $gitPath apply $PatchPath
        } else {
            & $gitPath apply --reverse --check $PatchPath 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "ℹ️ 自动保存 Patch 已经在当前工作区生效，跳过重复恢复" -ForegroundColor Cyan
                $result.success = $true
                $result.applied = $false
                $result.reason = 'already_applied'
                return [pscustomobject]$result
            }
        }
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✅ 已成功恢复会话内自动保存的代码更改" -ForegroundColor Green
            $result.success = $true
            $result.applied = $true
            $result.reason = 'restored'
        } else {
            Write-Host ("❌ 恢复自动保存失败，Patch 文件保留在: {0}" -f $PatchPath) -ForegroundColor Red
            $result.reason = 'patch_apply_failed'
        }
    } finally {
        Set-Location -LiteralPath $saved.Path
    }

    return [pscustomobject]$result
}

$resolvedWorkspaceRootInput = if ($PSBoundParameters.ContainsKey('WorkspaceRoot')) { [string]$PSBoundParameters['WorkspaceRoot'] } else { $WorkspaceRoot }
$ResolvedWorkspaceRoot = Get-RaymanStateWorkspaceRoot -WorkspaceRoot $resolvedWorkspaceRootInput
$runtimeContext = Get-RaymanSessionRuntimeContext -WorkspaceRoot $ResolvedWorkspaceRoot
$memoryHelperPath = Join-Path $PSScriptRoot '..\memory\memory_common.ps1'
if (Test-Path -LiteralPath $memoryHelperPath -PathType Leaf) {
    . $memoryHelperPath
}
$eventHooksPath = Join-Path $PSScriptRoot '..\utils\event_hooks.ps1'
if (Test-Path -LiteralPath $eventHooksPath -PathType Leaf) {
    . $eventHooksPath -NoMain
}

if ([string]::IsNullOrWhiteSpace($Name)) {
    $records = @(Get-RaymanSessionRecords -WorkspaceRoot $ResolvedWorkspaceRoot)
    if ($Json) {
        [ordered]@{
            schema = 'rayman.state.resume.prompt.v1'
            workspace_root = $ResolvedWorkspaceRoot
            count = $records.Count
            sessions = @($records | ForEach-Object {
                    [ordered]@{
                        name = [string]$_.name
                        slug = [string]$_.slug
                        status = [string]$_.status
                        isolation = [string]$_.isolation
                        updated_at = [string]$_.updated_at
                        has_stash = [bool]$_.has_stash
                        has_worktree = [bool]$_.has_worktree
                    }
                })
        } | ConvertTo-Json -Depth 8
        exit 0
    }

    Write-Host (Format-RaymanSessionListText -Records $records)
    Write-Host "请执行: rayman.ps1 state-resume -Name <name>" -ForegroundColor DarkCyan
    exit 0
}

$slug = ConvertTo-RaymanSessionSlug -Name $Name
$manifest = Read-RaymanSessionManifest -WorkspaceRoot $ResolvedWorkspaceRoot -Slug $slug
if ($null -eq $manifest) {
    throw ("未找到命名会话: {0}" -f $Name)
}

$sessionName = if ($manifest.PSObject.Properties['name']) { [string]$manifest.name } else { $Name }
$status = if ($manifest.PSObject.Properties['status']) { [string]$manifest.status } else { 'paused' }
if ($status -ne 'paused' -and -not ($AllowAlreadyResumed -and $status -eq 'resumed')) {
    throw ("会话当前不是 paused 状态，不能恢复: {0} (status={1})" -f $sessionName, $status)
}

$artifactMap = if ($manifest.PSObject.Properties['handover_artifacts']) {
    $manifest.handover_artifacts
} else {
    Get-RaymanSessionArtifactMap -Paths (Get-RaymanSessionPaths -WorkspaceRoot $ResolvedWorkspaceRoot -Slug $slug)
}
$handoverPath = [string]$artifactMap.handover_path
$patchPath = [string]$artifactMap.auto_save_patch_path
$metaPath = [string]$artifactMap.auto_save_meta_path
$pendingContent = ''
if (-not [string]::IsNullOrWhiteSpace($handoverPath) -and (Test-Path -LiteralPath $handoverPath -PathType Leaf)) {
    Write-Host ("📄 发现命名会话：{0}" -f $sessionName) -ForegroundColor Cyan
    $pendingContent = Get-Content -LiteralPath $handoverPath -Raw -Encoding UTF8
    Get-Content -LiteralPath $handoverPath -Encoding UTF8 | Write-Host
}

$resumeIsolation = 'shared'
$resumeRoot = $ResolvedWorkspaceRoot
if ([string]$manifest.isolation -eq 'worktree') {
    $resumeIsolation = 'worktree'
    $resumeRoot = if ($manifest.PSObject.Properties['worktree_path']) { [string]$manifest.worktree_path } else { '' }
    if ([string]::IsNullOrWhiteSpace($resumeRoot)) {
        throw ("命名会话缺少 worktree 路径，无法恢复: {0}" -f $sessionName)
    }
    if (-not (Test-Path -LiteralPath $resumeRoot -PathType Container)) {
        throw ("命名会话 worktree 路径不存在，无法恢复: {0}" -f $resumeRoot)
    }
}

$patchResult = Invoke-RaymanSessionPatchRestore -TargetRoot $resumeRoot -PatchPath $patchPath
$stashResult = Restore-RaymanGitSessionStash -WorkspaceRoot $resumeRoot -StashOid $(if ($manifest.PSObject.Properties['stash_oid']) { [string]$manifest.stash_oid } else { '' })
if ([bool]$stashResult.success) {
    Write-Host "✅ 已恢复命名会话对应的 Git Stash" -ForegroundColor Green
} elseif ([string]$stashResult.reason -ne 'stash_missing') {
    Write-Host ("⚠️ Git Stash 未恢复: {0}" -f [string]$stashResult.reason) -ForegroundColor Yellow
}

$updatedManifest = New-RaymanSessionManifest `
    -WorkspaceRoot $ResolvedWorkspaceRoot `
    -Name $sessionName `
    -Slug $slug `
    -Status 'resumed' `
    -Isolation $resumeIsolation `
    -TaskDescription $(if ($manifest.PSObject.Properties['task_description']) { [string]$manifest.task_description } else { '' }) `
    -StashOid $(if ($stashResult.success) { '' } elseif ($manifest.PSObject.Properties['stash_oid']) { [string]$manifest.stash_oid } else { '' }) `
    -WorktreePath $(if ($manifest.PSObject.Properties['worktree_path']) { [string]$manifest.worktree_path } else { '' }) `
    -Branch $(if ($manifest.PSObject.Properties['branch']) { [string]$manifest.branch } else { '' }) `
    -SessionKind $(if ($manifest.PSObject.Properties['session_kind']) { [string]$manifest.session_kind } else { 'manual' }) `
    -Backend ([string]$runtimeContext.backend) `
    -AccountAlias ([string]$runtimeContext.account_alias) `
    -OwnerContext $runtimeContext.owner_context `
    -Existing $manifest
Save-RaymanSessionManifest -WorkspaceRoot $ResolvedWorkspaceRoot -Manifest $updatedManifest | Out-Null
Set-RaymanActiveSession -WorkspaceRoot $ResolvedWorkspaceRoot -Manifest $updatedManifest -OwnerContext $runtimeContext.owner_context
if (Get-Command Write-RaymanSessionRecall -ErrorAction SilentlyContinue) {
    Write-RaymanSessionRecall -WorkspaceRoot $ResolvedWorkspaceRoot -Manifest $updatedManifest -HandoverPath $handoverPath -PatchPath $patchPath -MetaPath $metaPath | Out-Null
}
$sharedSessionSyncError = ''
if (Get-Command Sync-RaymanSharedSessionFromManifest -ErrorAction SilentlyContinue) {
    try {
        $null = Sync-RaymanSharedSessionFromManifest -WorkspaceRoot $ResolvedWorkspaceRoot -Manifest $updatedManifest -HandoverPath $handoverPath -PatchPath $patchPath -MetaPath $metaPath -Action 'state-resume'
    } catch {
        $sharedSessionSyncError = $_.Exception.Message
        if (-not $Json) {
            Write-Warning ("shared-session sync failed during state-resume: {0}" -f $sharedSessionSyncError)
        }
        if (Get-Command Write-RaymanDiag -ErrorAction SilentlyContinue) {
            Write-RaymanDiag -Scope 'shared-session' -WorkspaceRoot $ResolvedWorkspaceRoot -Message ("state-resume sync failed; session_slug={0}; error={1}" -f $slug, $_.Exception.ToString())
        }
        if (Get-Command Write-RaymanEvent -ErrorAction SilentlyContinue) {
            Write-RaymanEvent -WorkspaceRoot $ResolvedWorkspaceRoot -EventType 'shared_session.sync_failed' -Category 'state' -Payload ([ordered]@{
                    action = 'state-resume'
                    session_slug = $slug
                    error = $sharedSessionSyncError
                }) | Out-Null
        }
    }
}

if ($resumeIsolation -eq 'worktree') {
    & "$PSScriptRoot\..\utils\request_attention.ps1" -WorkspaceRoot $ResolvedWorkspaceRoot -Message ("命名会话已恢复，请在 worktree 中继续：{0}" -f $sessionName)
} else {
    & "$PSScriptRoot\..\utils\request_attention.ps1" -WorkspaceRoot $ResolvedWorkspaceRoot -Message ("欢迎回来，命名会话已恢复：{0}" -f $sessionName)
}

if (Get-Command Get-RaymanMemoryTaskKey -ErrorAction SilentlyContinue) {
    $memoryRunId = [Guid]::NewGuid().ToString('n')
    $resumeTask = if ([string]::IsNullOrWhiteSpace($pendingContent)) { "resume-state:$sessionName" } else { $pendingContent }
    $memoryTaskKey = Get-RaymanMemoryTaskKey -TaskKind 'handover' -Task $resumeTask -WorkspaceRoot $ResolvedWorkspaceRoot
    $artifactRefs = @($patchPath, $metaPath, $handoverPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) }
    Write-RaymanEpisodeMemory -WorkspaceRoot $ResolvedWorkspaceRoot -RunId $memoryRunId -TaskKey $memoryTaskKey -TaskKind 'handover' -Stage 'handover' -Success $true -ArtifactRefs $artifactRefs -SummaryText 'state-resume handover restored' -ExtraPayload @{
        action = 'state-resume'
        session_name = $sessionName
        session_slug = $slug
    } | Out-Null
}
if (Get-Command Write-RaymanEvent -ErrorAction SilentlyContinue) {
    Write-RaymanEvent -WorkspaceRoot $ResolvedWorkspaceRoot -EventType 'session.restore' -Category 'state' -Payload ([ordered]@{
            session_name = $sessionName
            session_slug = $slug
            session_kind = if ($updatedManifest.PSObject.Properties['session_kind']) { [string]$updatedManifest.session_kind } else { 'manual' }
            isolation = [string]$updatedManifest.isolation
            backend = [string]$runtimeContext.backend
            account_alias = [string]$runtimeContext.account_alias
            restored_patch = [bool]$patchResult.applied
            stash_result = [string]$stashResult.reason
        }) | Out-Null
}

if ($Json) {
    if ($resumeIsolation -eq 'worktree') {
        [ordered]@{
            schema = 'rayman.state.resume.worktree.v1'
            name = $sessionName
            slug = $slug
            status = 'resumed'
            isolation = 'worktree'
            worktree_path = [string]$updatedManifest.worktree_path
            branch = [string]$updatedManifest.branch
            restored_patch = [bool]$patchResult.applied
            stash_result = [string]$stashResult.reason
            shared_session_sync_error = $sharedSessionSyncError
        } | ConvertTo-Json -Depth 8
    } else {
        [ordered]@{
            schema = 'rayman.state.resume.v1'
            name = $sessionName
            slug = $slug
            status = 'resumed'
            isolation = 'shared'
            restored_patch = [bool]$patchResult.applied
            stash_result = [string]$stashResult.reason
            shared_session_sync_error = $sharedSessionSyncError
        } | ConvertTo-Json -Depth 8
    }
    exit 0
}

if ($resumeIsolation -eq 'worktree') {
    Write-Host ("✅ worktree 会话已恢复: {0}" -f $sessionName) -ForegroundColor Green
    Write-Host ("   branch={0}" -f [string]$updatedManifest.branch) -ForegroundColor DarkCyan
    Write-Host ("   path={0}" -f [string]$updatedManifest.worktree_path) -ForegroundColor DarkCyan
}
