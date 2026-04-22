param(
    [string]$WorkspaceRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..\..\..') | Select-Object -ExpandProperty Path),
    [string]$Name = '',
    [string]$TaskDescription = '未提供详细描述'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'session_common.ps1')
$sharedSessionHelperPath = Join-Path $PSScriptRoot 'shared_session_common.ps1'
if (Test-Path -LiteralPath $sharedSessionHelperPath -PathType Leaf) {
    . $sharedSessionHelperPath
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

$sessionName = Resolve-RaymanSessionDisplayName -Name $Name
$slug = ConvertTo-RaymanSessionSlug -Name $sessionName
$existing = Read-RaymanSessionManifest -WorkspaceRoot $ResolvedWorkspaceRoot -Slug $slug
$activeSession = Get-RaymanActiveSession -WorkspaceRoot $ResolvedWorkspaceRoot -OwnerContext $runtimeContext.owner_context
if ($null -ne $existing -and [string]$existing.status -eq 'paused' -and ([string]$activeSession.slug -ne $slug)) {
    throw ("已存在同名 paused 会话，请先使用其他名字或先恢复该会话：{0}" -f $sessionName)
}

$paths = Get-RaymanSessionPaths -WorkspaceRoot $ResolvedWorkspaceRoot -Slug $slug
if (-not (Test-Path -LiteralPath $paths.session_dir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $paths.session_dir | Out-Null
}

$date = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$handover = @"
# 暂停任务状态

- 名称: $sessionName
- Slug: $slug
- 时间: $date
- 模式: $(if ($null -ne $existing -and -not [string]::IsNullOrWhiteSpace([string]$existing.isolation)) { [string]$existing.isolation } else { 'shared' })

## 任务描述

$TaskDescription
"@
Write-RaymanSessionTextFile -Path $paths.handover_path -Content (($handover.TrimEnd()) + "`n")

Move-RaymanLegacyAutoSaveArtifactsToSession -WorkspaceRoot $ResolvedWorkspaceRoot -Slug $slug
$stashResult = Save-RaymanGitSessionStash -WorkspaceRoot $ResolvedWorkspaceRoot -SessionName $sessionName -Slug $slug

$manifest = New-RaymanSessionManifest `
    -WorkspaceRoot $ResolvedWorkspaceRoot `
    -Name $sessionName `
    -Slug $slug `
    -Status 'paused' `
    -Isolation $(if ($null -ne $existing -and -not [string]::IsNullOrWhiteSpace([string]$existing.isolation)) { [string]$existing.isolation } else { 'shared' }) `
    -TaskDescription $TaskDescription `
    -StashOid $(if ([bool]$stashResult.stash_created) { [string]$stashResult.stash_oid } elseif ($null -ne $existing -and $existing.PSObject.Properties['stash_oid']) { [string]$existing.stash_oid } else { '' }) `
    -WorktreePath $(if ($null -ne $existing -and $existing.PSObject.Properties['worktree_path']) { [string]$existing.worktree_path } else { '' }) `
    -Branch $(if ($null -ne $existing -and $existing.PSObject.Properties['branch']) { [string]$existing.branch } else { '' }) `
    -SessionKind 'manual' `
    -Backend ([string]$runtimeContext.backend) `
    -AccountAlias ([string]$runtimeContext.account_alias) `
    -OwnerContext $runtimeContext.owner_context `
    -Existing $existing
Save-RaymanSessionManifest -WorkspaceRoot $ResolvedWorkspaceRoot -Manifest $manifest | Out-Null
Set-RaymanActiveSession -WorkspaceRoot $ResolvedWorkspaceRoot -Manifest $manifest -OwnerContext $runtimeContext.owner_context
if (Get-Command Write-RaymanSessionRecall -ErrorAction SilentlyContinue) {
    Write-RaymanSessionRecall -WorkspaceRoot $ResolvedWorkspaceRoot -Manifest $manifest -HandoverPath $paths.handover_path -PatchPath $paths.auto_save_patch_path -MetaPath $paths.auto_save_meta_path | Out-Null
}
if (Get-Command Sync-RaymanSharedSessionFromManifest -ErrorAction SilentlyContinue) {
    try {
        $null = Sync-RaymanSharedSessionFromManifest -WorkspaceRoot $ResolvedWorkspaceRoot -Manifest $manifest -HandoverPath $paths.handover_path -PatchPath $paths.auto_save_patch_path -MetaPath $paths.auto_save_meta_path -Action 'state-save'
    } catch {}
}

$legacy = Get-RaymanLegacyStatePaths -WorkspaceRoot $ResolvedWorkspaceRoot
if (Test-Path -LiteralPath $legacy.pending_path -PathType Leaf) {
  Remove-Item -LiteralPath $legacy.pending_path -Force -ErrorAction SilentlyContinue
}

Write-Host ("✅ 命名会话已保存: {0}" -f $sessionName) -ForegroundColor Green
Write-Host ("   handover={0}" -f $paths.handover_path) -ForegroundColor DarkCyan
if ([bool]$stashResult.stash_created) {
    Write-Host ("✅ 工作区已通过 Git Stash 保存 (oid={0})" -f [string]$stashResult.stash_oid) -ForegroundColor Green
} elseif ([string]$stashResult.reason -eq 'clean') {
    Write-Host 'ℹ️ 工作区干净，无需 Git Stash' -ForegroundColor Cyan
} elseif ([string]$stashResult.reason -ne 'git_missing' -and [string]$stashResult.reason -ne 'not_git_worktree') {
    Write-Host ("⚠️ Git Stash 未保存新快照: {0}" -f [string]$stashResult.reason) -ForegroundColor Yellow
}

if (Get-Command Get-RaymanMemoryTaskKey -ErrorAction SilentlyContinue) {
    $memoryRunId = [Guid]::NewGuid().ToString('n')
    $memoryTaskKey = Get-RaymanMemoryTaskKey -TaskKind 'handover' -Task $TaskDescription -WorkspaceRoot $ResolvedWorkspaceRoot
    $artifactRefs = @(
        [string]$paths.handover_path
        [string]$paths.auto_save_patch_path
        [string]$paths.auto_save_meta_path
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) }
    Write-RaymanEpisodeMemory -WorkspaceRoot $ResolvedWorkspaceRoot -RunId $memoryRunId -TaskKey $memoryTaskKey -TaskKind 'handover' -Stage 'handover' -Success $true -ArtifactRefs $artifactRefs -SummaryText 'state-save handover created' -ExtraPayload @{
        action = 'state-save'
        session_name = $sessionName
        session_slug = $slug
        stash_oid = [string]$manifest.stash_oid
    } | Out-Null
}
if (Get-Command Write-RaymanEvent -ErrorAction SilentlyContinue) {
    Write-RaymanEvent -WorkspaceRoot $ResolvedWorkspaceRoot -EventType 'session.save' -Category 'state' -Payload ([ordered]@{
            session_name = $sessionName
            session_slug = $slug
            session_kind = 'manual'
            backend = [string]$runtimeContext.backend
            account_alias = [string]$runtimeContext.account_alias
        }) | Out-Null
}

& "$PSScriptRoot\..\utils\request_attention.ps1" -WorkspaceRoot $ResolvedWorkspaceRoot -Message ("状态已保存到命名会话：{0}" -f $sessionName)
