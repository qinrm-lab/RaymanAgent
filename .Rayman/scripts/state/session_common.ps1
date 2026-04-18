Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
    . $commonPath
}

$ownershipHelperPath = Join-Path $PSScriptRoot '..\utils\workspace_process_ownership.ps1'
if (Test-Path -LiteralPath $ownershipHelperPath -PathType Leaf) {
    . $ownershipHelperPath
}
$memoryHelperPath = Join-Path $PSScriptRoot '..\memory\memory_common.ps1'
if (Test-Path -LiteralPath $memoryHelperPath -PathType Leaf) {
    . $memoryHelperPath
}
$eventHooksPath = Join-Path $PSScriptRoot '..\utils\event_hooks.ps1'
if (Test-Path -LiteralPath $eventHooksPath -PathType Leaf) {
    . $eventHooksPath -NoMain
}

function Get-RaymanStateWorkspaceRoot {
    param(
        [string]$WorkspaceRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..\..\..') | Select-Object -ExpandProperty Path)
    )

    return (Resolve-Path -LiteralPath $WorkspaceRoot).Path
}

function Resolve-RaymanSessionDisplayName {
    param([string]$Name)

    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        return $Name.Trim()
    }

    return ('unnamed-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

function ConvertTo-RaymanSessionSlug {
    param([string]$Name)

    $text = Resolve-RaymanSessionDisplayName -Name $Name
    $slug = [regex]::Replace($text.ToLowerInvariant(), '[^a-z0-9._-]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        return ('session-{0}' -f (Get-Date -Format 'yyyyMMddHHmmss'))
    }
    return $slug
}

function Get-RaymanStateDirectoryPath {
    param([string]$WorkspaceRoot)

    return (Join-Path (Get-RaymanStateWorkspaceRoot -WorkspaceRoot $WorkspaceRoot) '.Rayman\state')
}

function Get-RaymanSessionRootPath {
    param([string]$WorkspaceRoot)

    return (Join-Path (Get-RaymanStateDirectoryPath -WorkspaceRoot $WorkspaceRoot) 'sessions')
}

function Get-RaymanSessionPaths {
    param(
        [string]$WorkspaceRoot,
        [string]$Slug
    )

    $sessionRoot = Get-RaymanSessionRootPath -WorkspaceRoot $WorkspaceRoot
    $sessionDir = Join-Path $sessionRoot $Slug
    return [pscustomobject]@{
        session_root = $sessionRoot
        session_dir = $sessionDir
        manifest_path = Join-Path $sessionDir 'session.json'
        handover_path = Join-Path $sessionDir 'handover.md'
        auto_save_patch_path = Join-Path $sessionDir 'auto_save.patch'
        auto_save_meta_path = Join-Path $sessionDir 'auto_save_meta.json'
    }
}

function Get-RaymanLegacyStatePaths {
    param([string]$WorkspaceRoot)

    $stateDir = Get-RaymanStateDirectoryPath -WorkspaceRoot $WorkspaceRoot
    return [pscustomobject]@{
        pending_path = Join-Path $stateDir 'pending_task.md'
        auto_save_patch_path = Join-Path $stateDir 'auto_save.patch'
        auto_save_meta_path = Join-Path $stateDir 'auto_save_meta.json'
    }
}

function Get-RaymanActiveSessionPath {
    param([string]$WorkspaceRoot)

    return (Join-Path (Get-RaymanStateDirectoryPath -WorkspaceRoot $WorkspaceRoot) 'active_session.json')
}

function Get-RaymanActiveSessionOwnerRoot {
    param([string]$WorkspaceRoot)

    return (Join-Path (Get-RaymanStateDirectoryPath -WorkspaceRoot $WorkspaceRoot) 'active_sessions')
}

function Get-RaymanSessionStableHash {
    param([AllowEmptyString()][string]$Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Value)
        $hashBytes = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant())
    } finally {
        $sha.Dispose()
    }
}

function Get-RaymanSessionOwnerContext {
    param(
        [string]$WorkspaceRoot,
        [object]$OwnerContext = $null
    )

    if ($null -ne $OwnerContext) {
        return $OwnerContext
    }

    $resolvedRoot = Get-RaymanStateWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    if (Get-Command Get-RaymanWorkspaceProcessOwnerContext -ErrorAction SilentlyContinue) {
        try {
            $resolved = Get-RaymanWorkspaceProcessOwnerContext -WorkspaceRootPath $resolvedRoot
            if ($null -ne $resolved) {
                return $resolved
            }
        } catch {}
    }

    $ownerToken = $resolvedRoot
    $ownerHash = Get-RaymanSessionStableHash -Value $ownerToken
    $workspaceHash = Get-RaymanSessionStableHash -Value $resolvedRoot
    return [pscustomobject]@{
        workspace_root = $resolvedRoot
        workspace_hash = $workspaceHash
        owner_source = 'workspace-root'
        owner_token = $ownerToken
        owner_hash = $ownerHash
        owner_key = ('workspace-root:{0}:{1}' -f $ownerHash, $workspaceHash)
        owner_display = ('workspace#{0}' -f $ownerHash.Substring(0, [Math]::Min(12, $ownerHash.Length)))
    }
}

function Get-RaymanSessionOwnerFileStem {
    param([object]$OwnerContext)

    if ($null -eq $OwnerContext) {
        return 'workspace-root'
    }

    $ownerSource = if ($OwnerContext.PSObject.Properties['owner_source']) { [string]$OwnerContext.owner_source } else { 'workspace-root' }
    $ownerHash = if ($OwnerContext.PSObject.Properties['owner_hash'] -and -not [string]::IsNullOrWhiteSpace([string]$OwnerContext.owner_hash)) {
        [string]$OwnerContext.owner_hash
    } else {
        Get-RaymanSessionStableHash -Value $(if ($OwnerContext.PSObject.Properties['owner_token']) { [string]$OwnerContext.owner_token } else { 'workspace-root' })
    }
    $normalizedSource = [regex]::Replace($ownerSource.ToLowerInvariant(), '[^a-z0-9._-]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($normalizedSource)) {
        $normalizedSource = 'owner'
    }
    return ('{0}-{1}' -f $normalizedSource, $ownerHash.Substring(0, [Math]::Min(16, $ownerHash.Length)))
}

function Get-RaymanOwnedActiveSessionPath {
    param(
        [string]$WorkspaceRoot,
        [object]$OwnerContext = $null
    )

    $resolvedOwnerContext = Get-RaymanSessionOwnerContext -WorkspaceRoot $WorkspaceRoot -OwnerContext $OwnerContext
    return (Join-Path (Get-RaymanActiveSessionOwnerRoot -WorkspaceRoot $WorkspaceRoot) ((Get-RaymanSessionOwnerFileStem -OwnerContext $resolvedOwnerContext) + '.json'))
}

function Get-RaymanSessionRuntimeContext {
    param(
        [string]$WorkspaceRoot,
        [string]$Backend = '',
        [string]$AccountAlias = '',
        [object]$OwnerContext = $null
    )

    $resolvedRoot = Get-RaymanStateWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $resolvedAccountAlias = if (-not [string]::IsNullOrWhiteSpace($AccountAlias)) {
        [string]$AccountAlias
    } else {
        [string](Get-RaymanWorkspaceEnvString -WorkspaceRoot $resolvedRoot -Name 'RAYMAN_CODEX_ACCOUNT_ALIAS' -Default '')
    }
    $resolvedBackend = if (-not [string]::IsNullOrWhiteSpace($Backend)) {
        ([string]$Backend).Trim().ToLowerInvariant()
    } elseif (-not [string]::IsNullOrWhiteSpace($resolvedAccountAlias)) {
        'codex'
    } else {
        'local'
    }
    $resolvedOwnerContext = Get-RaymanSessionOwnerContext -WorkspaceRoot $resolvedRoot -OwnerContext $OwnerContext
    return [pscustomobject]@{
        workspace_root = $resolvedRoot
        backend = $resolvedBackend
        account_alias = $resolvedAccountAlias
        owner_context = $resolvedOwnerContext
    }
}

function Get-RaymanSessionOwnerMetadata {
    param(
        [object]$OwnerContext = $null,
        [object]$Existing = $null
    )

    $ownerPid = 0
    $ownerSource = ''
    $ownerToken = ''
    $ownerDisplay = ''
    $ownerKey = ''
    if ($null -ne $OwnerContext) {
        $ownerSource = if ($OwnerContext.PSObject.Properties['owner_source']) { [string]$OwnerContext.owner_source } else { '' }
        $ownerToken = if ($OwnerContext.PSObject.Properties['owner_token']) { [string]$OwnerContext.owner_token } else { '' }
        $ownerDisplay = if ($OwnerContext.PSObject.Properties['owner_display']) { [string]$OwnerContext.owner_display } else { '' }
        $ownerKey = if ($OwnerContext.PSObject.Properties['owner_key']) { [string]$OwnerContext.owner_key } else { '' }
    } elseif ($null -ne $Existing) {
        $ownerSource = if ($Existing.PSObject.Properties['owner_source']) { [string]$Existing.owner_source } else { '' }
        $ownerToken = if ($Existing.PSObject.Properties['owner_token']) { [string]$Existing.owner_token } else { '' }
        $ownerDisplay = if ($Existing.PSObject.Properties['owner_display']) { [string]$Existing.owner_display } else { '' }
        $ownerKey = if ($Existing.PSObject.Properties['owner_key']) { [string]$Existing.owner_key } else { '' }
    }

    if (-not [string]::IsNullOrWhiteSpace($ownerToken)) {
        $parsedOwnerPid = 0
        if ([int]::TryParse($ownerToken, [ref]$parsedOwnerPid) -and $parsedOwnerPid -gt 0) {
            $ownerPid = $parsedOwnerPid
        }
    }
    if ($ownerPid -le 0 -and $null -ne $Existing -and $Existing.PSObject.Properties['owner_pid']) {
        try { $ownerPid = [int]$Existing.owner_pid } catch { $ownerPid = 0 }
    }

    return [ordered]@{
        owner_source = $ownerSource
        owner_token = $ownerToken
        owner_display = $ownerDisplay
        owner_key = $ownerKey
        owner_pid = $ownerPid
    }
}

function Get-RaymanSessionWorktreeRoot {
    param([string]$WorkspaceRoot)

    $resolvedRoot = Get-RaymanStateWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $parent = Split-Path -Parent $resolvedRoot
    $workspaceName = Split-Path -Leaf $resolvedRoot
    return (Join-Path (Join-Path $parent '_rayman_sessions') $workspaceName)
}

function Get-RaymanSessionWorktreePath {
    param(
        [string]$WorkspaceRoot,
        [string]$Slug
    )

    return (Join-Path (Get-RaymanSessionWorktreeRoot -WorkspaceRoot $WorkspaceRoot) $Slug)
}

function Get-RaymanSessionBranchName {
    param([string]$Slug)

    return ('codex/session/{0}' -f $Slug)
}

function Write-RaymanSessionTextFile {
    param(
        [string]$Path,
        [AllowEmptyString()][string]$Content
    )

    if (Get-Command Write-RaymanUtf8NoBom -ErrorAction SilentlyContinue) {
        Write-RaymanUtf8NoBom -Path $Path -Content $Content
        return
    }

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Write-RaymanSessionJsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $json = (($Value | ConvertTo-Json -Depth 10).TrimEnd() + "`n")
    Write-RaymanSessionTextFile -Path $Path -Content $json
}

function Read-RaymanSessionJsonOrNull {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    if (Get-Command Read-RaymanJsonFile -ErrorAction SilentlyContinue) {
        $doc = Read-RaymanJsonFile -Path $Path
        if ($null -ne $doc -and -not [bool]$doc.ParseFailed) {
            return $doc.Obj
        }
        return $null
    }

    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Read-RaymanSessionManifest {
    param(
        [string]$WorkspaceRoot,
        [string]$Slug
    )

    $paths = Get-RaymanSessionPaths -WorkspaceRoot $WorkspaceRoot -Slug $Slug
    return (Read-RaymanSessionJsonOrNull -Path $paths.manifest_path)
}

function Get-RaymanSessionArtifactMap {
    param([object]$Paths)

    return [ordered]@{
        manifest_path = [string]$Paths.manifest_path
        handover_path = [string]$Paths.handover_path
        auto_save_patch_path = [string]$Paths.auto_save_patch_path
        auto_save_meta_path = [string]$Paths.auto_save_meta_path
    }
}

function New-RaymanSessionManifest {
    param(
        [string]$WorkspaceRoot,
        [string]$Name,
        [string]$Slug,
        [string]$Status = 'paused',
        [string]$Isolation = 'shared',
        [string]$TaskDescription = '',
        [string]$StashOid = '',
        [string]$WorktreePath = '',
        [string]$Branch = '',
        [string]$SessionKind = 'manual',
        [string]$Backend = '',
        [string]$AccountAlias = '',
        [object]$OwnerContext = $null,
        [string]$LastCommandCompletedAt = '',
        [int]$LastCommandDurationMs = 0,
        [object]$Existing = $null
    )

    $paths = Get-RaymanSessionPaths -WorkspaceRoot $WorkspaceRoot -Slug $Slug
    $resolvedRoot = Get-RaymanStateWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $now = (Get-Date).ToString('o')
    $createdAt = if ($null -ne $Existing -and $Existing.PSObject.Properties['created_at']) {
        [string]$Existing.created_at
    } else {
        $now
    }
    $sessionKindValue = if (-not [string]::IsNullOrWhiteSpace($SessionKind)) {
        [string]$SessionKind
    } elseif ($null -ne $Existing -and $Existing.PSObject.Properties['session_kind']) {
        [string]$Existing.session_kind
    } else {
        'manual'
    }
    $backendValue = if ($PSBoundParameters.ContainsKey('Backend')) {
        [string]$Backend
    } elseif ($null -ne $Existing -and $Existing.PSObject.Properties['backend']) {
        [string]$Existing.backend
    } else {
        ''
    }
    $accountAliasValue = if ($PSBoundParameters.ContainsKey('AccountAlias')) {
        [string]$AccountAlias
    } elseif ($null -ne $Existing -and $Existing.PSObject.Properties['account_alias']) {
        [string]$Existing.account_alias
    } else {
        ''
    }
    $lastCommandCompletedAtValue = if ($PSBoundParameters.ContainsKey('LastCommandCompletedAt')) {
        [string]$LastCommandCompletedAt
    } elseif ($null -ne $Existing -and $Existing.PSObject.Properties['last_command_completed_at']) {
        [string]$Existing.last_command_completed_at
    } else {
        ''
    }
    $lastCommandDurationMsValue = if ($PSBoundParameters.ContainsKey('LastCommandDurationMs')) {
        [int]$LastCommandDurationMs
    } elseif ($null -ne $Existing -and $Existing.PSObject.Properties['last_command_duration_ms']) {
        [int]$Existing.last_command_duration_ms
    } else {
        0
    }
    $ownerMetadata = Get-RaymanSessionOwnerMetadata -OwnerContext $OwnerContext -Existing $Existing

    return [ordered]@{
        schema = 'rayman.state.session.v1'
        name = $Name
        slug = $Slug
        status = $Status
        isolation = $Isolation
        task_description = $TaskDescription
        stash_oid = $StashOid
        handover_artifacts = Get-RaymanSessionArtifactMap -Paths $paths
        worktree_path = $WorktreePath
        branch = $Branch
        session_kind = $sessionKindValue
        backend = $backendValue
        account_alias = $accountAliasValue
        owner_source = [string]$ownerMetadata.owner_source
        owner_token = [string]$ownerMetadata.owner_token
        owner_display = [string]$ownerMetadata.owner_display
        owner_key = [string]$ownerMetadata.owner_key
        owner_pid = [int]$ownerMetadata.owner_pid
        last_command_completed_at = $lastCommandCompletedAtValue
        last_command_duration_ms = $lastCommandDurationMsValue
        workspace_root = $resolvedRoot
        created_at = $createdAt
        updated_at = $now
    }
}

function Save-RaymanSessionManifest {
    param(
        [string]$WorkspaceRoot,
        [object]$Manifest
    )

    if ($null -eq $Manifest) {
        throw 'session manifest is required'
    }

    $slug = [string]$Manifest.slug
    if ([string]::IsNullOrWhiteSpace($slug)) {
        throw 'session manifest missing slug'
    }

    $paths = Get-RaymanSessionPaths -WorkspaceRoot $WorkspaceRoot -Slug $slug
    if (-not (Test-Path -LiteralPath $paths.session_dir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $paths.session_dir | Out-Null
    }

    Write-RaymanSessionJsonFile -Path $paths.manifest_path -Value $Manifest
    return $paths.manifest_path
}

function Get-RaymanActiveSession {
    param(
        [string]$WorkspaceRoot,
        [object]$OwnerContext = $null
    )

    $owned = Read-RaymanSessionJsonOrNull -Path (Get-RaymanOwnedActiveSessionPath -WorkspaceRoot $WorkspaceRoot -OwnerContext $OwnerContext)
    if ($null -ne $owned) {
        return $owned
    }

    return (Read-RaymanSessionJsonOrNull -Path (Get-RaymanActiveSessionPath -WorkspaceRoot $WorkspaceRoot))
}

function Set-RaymanActiveSession {
    param(
        [string]$WorkspaceRoot,
        [object]$Manifest,
        [object]$OwnerContext = $null
    )

    if ($null -eq $Manifest) {
        return
    }

    $resolvedOwnerContext = Get-RaymanSessionOwnerContext -WorkspaceRoot $WorkspaceRoot -OwnerContext $OwnerContext
    $payload = [ordered]@{
        schema = 'rayman.state.active_session.v1'
        name = [string]$Manifest.name
        slug = [string]$Manifest.slug
        isolation = [string]$Manifest.isolation
        worktree_path = [string]$Manifest.worktree_path
        branch = [string]$Manifest.branch
        session_kind = if ($Manifest.PSObject.Properties['session_kind']) { [string]$Manifest.session_kind } else { 'manual' }
        backend = if ($Manifest.PSObject.Properties['backend']) { [string]$Manifest.backend } else { '' }
        account_alias = if ($Manifest.PSObject.Properties['account_alias']) { [string]$Manifest.account_alias } else { '' }
        owner_source = if ($resolvedOwnerContext.PSObject.Properties['owner_source']) { [string]$resolvedOwnerContext.owner_source } else { '' }
        owner_token = if ($resolvedOwnerContext.PSObject.Properties['owner_token']) { [string]$resolvedOwnerContext.owner_token } else { '' }
        owner_display = if ($resolvedOwnerContext.PSObject.Properties['owner_display']) { [string]$resolvedOwnerContext.owner_display } else { '' }
        owner_key = if ($resolvedOwnerContext.PSObject.Properties['owner_key']) { [string]$resolvedOwnerContext.owner_key } else { '' }
        owner_pid = $(if ($resolvedOwnerContext.PSObject.Properties['owner_token']) { $parsedOwnerPid = 0; if ([int]::TryParse([string]$resolvedOwnerContext.owner_token, [ref]$parsedOwnerPid)) { $parsedOwnerPid } else { 0 } } else { 0 })
        updated_at = (Get-Date).ToString('o')
    }
    Write-RaymanSessionJsonFile -Path (Get-RaymanOwnedActiveSessionPath -WorkspaceRoot $WorkspaceRoot -OwnerContext $resolvedOwnerContext) -Value $payload
    Write-RaymanSessionJsonFile -Path (Get-RaymanActiveSessionPath -WorkspaceRoot $WorkspaceRoot) -Value $payload
}

function Resolve-RaymanAutoSaveTargetPaths {
    param(
        [string]$WorkspaceRoot,
        [string]$Slug = '',
        [object]$OwnerContext = $null
    )

    if (-not [string]::IsNullOrWhiteSpace($Slug)) {
        return (Get-RaymanSessionPaths -WorkspaceRoot $WorkspaceRoot -Slug $Slug)
    }

    $active = Get-RaymanActiveSession -WorkspaceRoot $WorkspaceRoot -OwnerContext $OwnerContext
    if ($null -ne $active -and -not [string]::IsNullOrWhiteSpace([string]$active.slug)) {
        return (Get-RaymanSessionPaths -WorkspaceRoot $WorkspaceRoot -Slug ([string]$active.slug))
    }

    return (Get-RaymanLegacyStatePaths -WorkspaceRoot $WorkspaceRoot)
}

function Move-RaymanLegacyAutoSaveArtifactsToSession {
    param(
        [string]$WorkspaceRoot,
        [string]$Slug
    )

    $legacy = Get-RaymanLegacyStatePaths -WorkspaceRoot $WorkspaceRoot
    $sessionPaths = Get-RaymanSessionPaths -WorkspaceRoot $WorkspaceRoot -Slug $Slug
    if (-not (Test-Path -LiteralPath $sessionPaths.session_dir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $sessionPaths.session_dir | Out-Null
    }

    foreach ($pair in @(
            @{ Source = [string]$legacy.auto_save_patch_path; Target = [string]$sessionPaths.auto_save_patch_path }
            @{ Source = [string]$legacy.auto_save_meta_path; Target = [string]$sessionPaths.auto_save_meta_path }
        )) {
        if (-not (Test-Path -LiteralPath $pair.Source -PathType Leaf)) {
            continue
        }

        if ($pair.Source -eq $pair.Target) {
            continue
        }

        Move-Item -LiteralPath $pair.Source -Destination $pair.Target -Force
    }
}

function Get-RaymanGitCommandPath {
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $gitCmd -or [string]::IsNullOrWhiteSpace([string]$gitCmd.Source)) {
        return ''
    }
    return [string]$gitCmd.Source
}

function Test-RaymanGitWorkTree {
    param([string]$WorkspaceRoot)

    $gitPath = Get-RaymanGitCommandPath
    if ([string]::IsNullOrWhiteSpace($gitPath)) {
        return $false
    }

    $resolvedRoot = Get-RaymanStateWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $saved = Get-Location
    try {
        Set-Location -LiteralPath $resolvedRoot
        & $gitPath rev-parse --is-inside-work-tree 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } finally {
        Set-Location -LiteralPath $saved.Path
    }
}

function Get-RaymanGitManagedExcludePathspecs {
    return @(
        ':(exclude).Rayman/state'
        ':(exclude).Rayman/state/**'
        ':(exclude).Rayman/runtime'
        ':(exclude).Rayman/runtime/**'
    )
}

function Get-RaymanGitContentPathspec {
    param([switch]$ExcludeManaged)

    $pathspec = New-Object System.Collections.Generic.List[string]
    $pathspec.Add('.') | Out-Null
    if ($ExcludeManaged) {
        foreach ($entry in @(Get-RaymanGitManagedExcludePathspecs)) {
            $pathspec.Add([string]$entry) | Out-Null
        }
    }
    return @($pathspec.ToArray())
}

function Test-RaymanGitManagedStatusLine {
    param([string]$Line)

    $text = [string]$Line
    if ($text.Length -lt 4) {
        return $false
    }

    $pathValue = $text.Substring(3).Trim()
    if ($pathValue -match '\s+->\s+(?<target>.+)$') {
        $pathValue = [string]$matches['target']
    }
    $normalized = $pathValue.Trim('"').Replace('\', '/')
    while ($normalized.StartsWith('./')) {
        $normalized = $normalized.Substring(2)
    }

    return (
        $normalized -eq '.Rayman/state' -or
        $normalized.StartsWith('.Rayman/state/') -or
        $normalized -eq '.Rayman/runtime' -or
        $normalized.StartsWith('.Rayman/runtime/')
    )
}

function Get-RaymanGitStatusLines {
    param(
        [string]$WorkspaceRoot,
        [switch]$ExcludeManaged
    )

    $gitPath = Get-RaymanGitCommandPath
    if ([string]::IsNullOrWhiteSpace($gitPath)) {
        return @()
    }

    $resolvedRoot = Get-RaymanStateWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $saved = Get-Location
    try {
        Set-Location -LiteralPath $resolvedRoot
        $pathspec = @(Get-RaymanGitContentPathspec -ExcludeManaged:$ExcludeManaged)
        $statusArgs = @('status', '--porcelain', '--untracked-files=all', '--') + $pathspec
        $lines = @(& $gitPath @statusArgs 2>$null)
        if ($LASTEXITCODE -eq 0) {
            return @($lines)
        }

        $fallback = @(& $gitPath status --porcelain --untracked-files=all 2>$null)
        if (-not $ExcludeManaged) {
            return @($fallback)
        }
        return @($fallback | Where-Object { -not (Test-RaymanGitManagedStatusLine -Line ([string]$_)) })
    } finally {
        Set-Location -LiteralPath $saved.Path
    }
}

function Get-RaymanGitTopStashOid {
  param([string]$WorkspaceRoot)

    $gitPath = Get-RaymanGitCommandPath
    if ([string]::IsNullOrWhiteSpace($gitPath)) {
        return ''
    }

    $resolvedRoot = Get-RaymanStateWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
  $saved = Get-Location
  try {
    Set-Location -LiteralPath $resolvedRoot
    $value = (& $gitPath stash list --format='%H' 2>$null | Select-Object -First 1)
    if ($null -eq $value) {
        return ''
    }
    return ([string]$value).Trim()
  } finally {
    Set-Location -LiteralPath $saved.Path
  }
}

function Save-RaymanGitSessionStash {
    param(
        [string]$WorkspaceRoot,
        [string]$SessionName,
        [string]$Slug
    )

    $result = [ordered]@{
        success = $false
        status_count = 0
        stash_created = $false
        stash_oid = ''
        message = ''
        reason = 'git_missing'
    }

    $gitPath = Get-RaymanGitCommandPath
    if ([string]::IsNullOrWhiteSpace($gitPath)) {
        return [pscustomobject]$result
    }

    if (-not (Test-RaymanGitWorkTree -WorkspaceRoot $WorkspaceRoot)) {
        $result.reason = 'not_git_worktree'
        return [pscustomobject]$result
    }

    $resolvedRoot = Get-RaymanStateWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $status = @(Get-RaymanGitStatusLines -WorkspaceRoot $resolvedRoot -ExcludeManaged)
    $result.status_count = $status.Count
    if ($status.Count -le 0) {
        $result.success = $true
        $result.reason = 'clean'
        return [pscustomobject]$result
    }

    $before = Get-RaymanGitTopStashOid -WorkspaceRoot $resolvedRoot
    $timestamp = (Get-Date).ToString('o')
    $message = "Rayman WIP [session=$Slug] [name=$SessionName] [ts=$timestamp]"
    $saved = Get-Location
    try {
        Set-Location -LiteralPath $resolvedRoot
        $pathspec = @(Get-RaymanGitContentPathspec -ExcludeManaged)
        $stashArgs = @('stash', 'push', '-u', '-m', $message, '--') + $pathspec
        & $gitPath @stashArgs | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $result.reason = 'stash_push_failed'
            return [pscustomobject]$result
        }
    } finally {
        Set-Location -LiteralPath $saved.Path
    }

    $after = Get-RaymanGitTopStashOid -WorkspaceRoot $resolvedRoot
    $result.success = $true
    $result.message = $message
    $result.stash_oid = $after
    $result.stash_created = (-not [string]::IsNullOrWhiteSpace($after) -and $after -ne $before)
    $result.reason = if ($result.stash_created) { 'stashed' } else { 'stash_unchanged' }
    return [pscustomobject]$result
}

function Get-RaymanGitStashRefByOid {
    param(
        [string]$WorkspaceRoot,
        [string]$StashOid
    )

    if ([string]::IsNullOrWhiteSpace($StashOid)) {
        return ''
    }

    $gitPath = Get-RaymanGitCommandPath
    if ([string]::IsNullOrWhiteSpace($gitPath)) {
        return ''
    }

    $resolvedRoot = Get-RaymanStateWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $saved = Get-Location
    try {
        Set-Location -LiteralPath $resolvedRoot
        foreach ($line in @(& $gitPath stash list --format='%H %gd' 2>$null)) {
            $parts = @(([string]$line).Trim() -split '\s+')
            if ($parts.Count -lt 2) {
                continue
            }
            if ([string]$parts[0] -eq $StashOid) {
                return [string]$parts[1]
            }
        }
    } finally {
        Set-Location -LiteralPath $saved.Path
    }

    return ''
}

function Test-RaymanGitCommitExists {
    param(
        [string]$WorkspaceRoot,
        [string]$Commitish
    )

    if ([string]::IsNullOrWhiteSpace($Commitish)) {
        return $false
    }

    $gitPath = Get-RaymanGitCommandPath
    if ([string]::IsNullOrWhiteSpace($gitPath)) {
        return $false
    }

    $resolvedRoot = Get-RaymanStateWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $saved = Get-Location
    try {
        Set-Location -LiteralPath $resolvedRoot
        & $gitPath rev-parse --verify ('{0}^{{commit}}' -f $Commitish) 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } finally {
        Set-Location -LiteralPath $saved.Path
    }
}

function Restore-RaymanGitSessionStash {
    param(
        [string]$WorkspaceRoot,
        [string]$StashOid
    )

    $result = [ordered]@{
        success = $false
        applied = $false
        dropped = $false
        ref = ''
        reason = 'stash_missing'
    }

    if ([string]::IsNullOrWhiteSpace($StashOid)) {
        return [pscustomobject]$result
    }

    $gitPath = Get-RaymanGitCommandPath
    if ([string]::IsNullOrWhiteSpace($gitPath) -or -not (Test-RaymanGitWorkTree -WorkspaceRoot $WorkspaceRoot)) {
        $result.reason = 'git_unavailable'
        return [pscustomobject]$result
    }

    $stashRef = Get-RaymanGitStashRefByOid -WorkspaceRoot $WorkspaceRoot -StashOid $StashOid
    $applyTarget = if (-not [string]::IsNullOrWhiteSpace($stashRef)) {
        $stashRef
    } elseif (Test-RaymanGitCommitExists -WorkspaceRoot $WorkspaceRoot -Commitish $StashOid) {
        $StashOid
    } else {
        ''
    }

    if ([string]::IsNullOrWhiteSpace($applyTarget)) {
        $result.reason = 'stash_not_found'
        return [pscustomobject]$result
    }

    $resolvedRoot = Get-RaymanStateWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $saved = Get-Location
    try {
        Set-Location -LiteralPath $resolvedRoot
        & $gitPath stash apply $applyTarget | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $result.reason = 'stash_apply_failed'
            return [pscustomobject]$result
        }

        $result.applied = $true
        $result.ref = $stashRef
        if (-not [string]::IsNullOrWhiteSpace($stashRef)) {
            & $gitPath stash drop $stashRef | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $result.dropped = $true
            }
        }
        $result.success = $true
        $result.reason = 'restored'
    } finally {
        Set-Location -LiteralPath $saved.Path
    }

    return [pscustomobject]$result
}

function Get-RaymanSessionAutoTempThresholdMs {
    return 300000
}

function Get-RaymanAutoTempSessionDescriptor {
    param(
        [string]$WorkspaceRoot,
        [string]$Backend = '',
        [string]$AccountAlias = '',
        [object]$OwnerContext = $null
    )

    $runtimeContext = Get-RaymanSessionRuntimeContext -WorkspaceRoot $WorkspaceRoot -Backend $Backend -AccountAlias $AccountAlias -OwnerContext $OwnerContext
    $ownerContextValue = $runtimeContext.owner_context
    $accountSlug = if ([string]::IsNullOrWhiteSpace([string]$runtimeContext.account_alias)) { 'unbound' } else { ConvertTo-RaymanSessionSlug -Name ([string]$runtimeContext.account_alias) }
    $ownerHash = if ($ownerContextValue.PSObject.Properties['owner_hash'] -and -not [string]::IsNullOrWhiteSpace([string]$ownerContextValue.owner_hash)) {
        [string]$ownerContextValue.owner_hash
    } else {
        Get-RaymanSessionStableHash -Value ([string]$ownerContextValue.owner_token)
    }
    $ownerPart = $ownerHash.Substring(0, [Math]::Min(12, $ownerHash.Length))
    $sessionName = ('auto-temp {0} {1} [{2}]' -f [string]$runtimeContext.backend, $accountSlug, $(if ($ownerContextValue.PSObject.Properties['owner_display']) { [string]$ownerContextValue.owner_display } else { $ownerPart }))
    $slug = ConvertTo-RaymanSessionSlug -Name ('auto-temp-{0}-{1}-{2}' -f [string]$runtimeContext.backend, $accountSlug, $ownerPart)
    return [pscustomobject]@{
        name = $sessionName
        slug = $slug
        backend = [string]$runtimeContext.backend
        account_alias = [string]$runtimeContext.account_alias
        owner_context = $ownerContextValue
    }
}

function Save-RaymanSessionDiffArtifacts {
    param(
        [string]$WorkspaceRoot,
        [string]$Slug
    )

    $result = [ordered]@{
        schema = 'rayman.state.session_artifacts.v1'
        workspace_root = (Get-RaymanStateWorkspaceRoot -WorkspaceRoot $WorkspaceRoot)
        slug = $Slug
        saved = $false
        files_changed = 0
        reason = 'git_missing'
    }

    $gitPath = Get-RaymanGitCommandPath
    if ([string]::IsNullOrWhiteSpace($gitPath)) {
        return [pscustomobject]$result
    }

    if (-not (Test-RaymanGitWorkTree -WorkspaceRoot $WorkspaceRoot)) {
        $result.reason = 'not_git_worktree'
        return [pscustomobject]$result
    }

    $paths = Get-RaymanSessionPaths -WorkspaceRoot $WorkspaceRoot -Slug $Slug
    $saved = Get-Location
    try {
        Set-Location -LiteralPath $result.workspace_root
        $status = @(Get-RaymanGitStatusLines -WorkspaceRoot $result.workspace_root -ExcludeManaged)
        $result.files_changed = $status.Count
        if ($status.Count -gt 0) {
            $pathspec = @(Get-RaymanGitContentPathspec -ExcludeManaged)
            $addArgs = @('add', '-N', '--') + $pathspec
            & $gitPath @addArgs | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $result.reason = 'intent_add_failed'
                return [pscustomobject]$result
            }

            $diffArgs = @('diff', '--') + $pathspec
            $patchContent = @(& $gitPath @diffArgs) -join [Environment]::NewLine
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($patchContent)) {
                $result.reason = 'diff_empty'
                return [pscustomobject]$result
            }
            Write-RaymanSessionTextFile -Path $paths.auto_save_patch_path -Content (($patchContent.TrimEnd()) + [Environment]::NewLine)
            Write-RaymanSessionJsonFile -Path $paths.auto_save_meta_path -Value ([ordered]@{
                    timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                    files_changed = $status.Count
                    excluded_managed_paths = @('.Rayman/state/**', '.Rayman/runtime/**')
                })
            $result.saved = $true
            $result.reason = 'saved'
            return [pscustomobject]$result
        }
    } finally {
        Set-Location -LiteralPath $saved.Path
    }

    if (Test-Path -LiteralPath $paths.auto_save_patch_path -PathType Leaf) {
        Remove-Item -LiteralPath $paths.auto_save_patch_path -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $paths.auto_save_meta_path -PathType Leaf) {
        Remove-Item -LiteralPath $paths.auto_save_meta_path -Force -ErrorAction SilentlyContinue
    }
    $result.reason = 'clean'
    return [pscustomobject]$result
}

function Write-RaymanAutoTempSessionHandover {
    param(
        [string]$WorkspaceRoot,
        [object]$Manifest,
        [string]$CommandText = '',
        [int]$DurationMs = 0
    )

    if ($null -eq $Manifest) {
        return ''
    }

    $paths = Get-RaymanSessionPaths -WorkspaceRoot $WorkspaceRoot -Slug ([string]$Manifest.slug)
    $seconds = [Math]::Round(([double]$DurationMs / 1000), 1)
    $content = @"
# 自动临时状态

- 名称: $([string]$Manifest.name)
- Slug: $([string]$Manifest.slug)
- 类型: $([string]$Manifest.session_kind)
- 后端: $([string]$Manifest.backend)
- 账号: $([string]$Manifest.account_alias)
- Owner: $([string]$Manifest.owner_display)
- 时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
- 命令耗时: ${seconds}s

## 最近命令

$CommandText
"@
    Write-RaymanSessionTextFile -Path $paths.handover_path -Content (($content.TrimEnd()) + "`n")
    return $paths.handover_path
}

function Invoke-RaymanSessionCommandCheckpoint {
    param(
        [string]$WorkspaceRoot,
        [int]$DurationMs,
        [string]$Backend = '',
        [string]$AccountAlias = '',
        [string]$CommandText = '',
        [object]$OwnerContext = $null
    )

    $runtimeContext = Get-RaymanSessionRuntimeContext -WorkspaceRoot $WorkspaceRoot -Backend $Backend -AccountAlias $AccountAlias -OwnerContext $OwnerContext
    $result = [ordered]@{
        schema = 'rayman.state.command_checkpoint.v1'
        generated_at = (Get-Date).ToString('o')
        workspace_root = [string]$runtimeContext.workspace_root
        backend = [string]$runtimeContext.backend
        account_alias = [string]$runtimeContext.account_alias
        owner_key = if ($runtimeContext.owner_context.PSObject.Properties['owner_key']) { [string]$runtimeContext.owner_context.owner_key } else { '' }
        owner_display = if ($runtimeContext.owner_context.PSObject.Properties['owner_display']) { [string]$runtimeContext.owner_context.owner_display } else { '' }
        threshold_ms = (Get-RaymanSessionAutoTempThresholdMs)
        duration_ms = [int]$DurationMs
        command = [string]$CommandText
        checkpointed = $false
        session_kind = ''
        session_slug = ''
        reason = 'under_threshold'
        artifacts = $null
    }

    if ([int]$DurationMs -lt [int]$result.threshold_ms) {
        return [pscustomobject]$result
    }

    $active = Get-RaymanActiveSession -WorkspaceRoot $runtimeContext.workspace_root -OwnerContext $runtimeContext.owner_context
    $targetManifest = $null
    $sessionKind = 'auto_temp'
    if ($null -ne $active -and -not [string]::IsNullOrWhiteSpace([string]$active.slug)) {
        $activeManifest = Read-RaymanSessionManifest -WorkspaceRoot $runtimeContext.workspace_root -Slug ([string]$active.slug)
        if ($null -ne $activeManifest -and [string]$activeManifest.session_kind -ne 'auto_temp') {
            $sessionKind = if ($activeManifest.PSObject.Properties['session_kind']) { [string]$activeManifest.session_kind } else { 'manual' }
            $targetManifest = New-RaymanSessionManifest `
                -WorkspaceRoot $runtimeContext.workspace_root `
                -Name ([string]$activeManifest.name) `
                -Slug ([string]$activeManifest.slug) `
                -Status $(if ($activeManifest.PSObject.Properties['status']) { [string]$activeManifest.status } else { 'paused' }) `
                -Isolation $(if ($activeManifest.PSObject.Properties['isolation']) { [string]$activeManifest.isolation } else { 'shared' }) `
                -TaskDescription $(if ($activeManifest.PSObject.Properties['task_description']) { [string]$activeManifest.task_description } else { '' }) `
                -StashOid $(if ($activeManifest.PSObject.Properties['stash_oid']) { [string]$activeManifest.stash_oid } else { '' }) `
                -WorktreePath $(if ($activeManifest.PSObject.Properties['worktree_path']) { [string]$activeManifest.worktree_path } else { '' }) `
                -Branch $(if ($activeManifest.PSObject.Properties['branch']) { [string]$activeManifest.branch } else { '' }) `
                -SessionKind $sessionKind `
                -Backend ([string]$runtimeContext.backend) `
                -AccountAlias ([string]$runtimeContext.account_alias) `
                -OwnerContext $runtimeContext.owner_context `
                -LastCommandCompletedAt ((Get-Date).ToString('o')) `
                -LastCommandDurationMs ([int]$DurationMs) `
                -Existing $activeManifest
        }
    }

    if ($null -eq $targetManifest) {
        $descriptor = Get-RaymanAutoTempSessionDescriptor -WorkspaceRoot $runtimeContext.workspace_root -Backend $runtimeContext.backend -AccountAlias $runtimeContext.account_alias -OwnerContext $runtimeContext.owner_context
        $existing = Read-RaymanSessionManifest -WorkspaceRoot $runtimeContext.workspace_root -Slug ([string]$descriptor.slug)
        $targetManifest = New-RaymanSessionManifest `
            -WorkspaceRoot $runtimeContext.workspace_root `
            -Name ([string]$descriptor.name) `
            -Slug ([string]$descriptor.slug) `
            -Status 'paused' `
            -Isolation 'shared' `
            -TaskDescription $(if ($null -ne $existing -and $existing.PSObject.Properties['task_description']) { [string]$existing.task_description } elseif (-not [string]::IsNullOrWhiteSpace([string]$CommandText)) { [string]$CommandText } else { ('auto-temp checkpoint ({0})' -f [string]$runtimeContext.backend) }) `
            -StashOid '' `
            -WorktreePath $(if ($null -ne $existing -and $existing.PSObject.Properties['worktree_path']) { [string]$existing.worktree_path } else { '' }) `
            -Branch $(if ($null -ne $existing -and $existing.PSObject.Properties['branch']) { [string]$existing.branch } else { '' }) `
            -SessionKind 'auto_temp' `
            -Backend ([string]$runtimeContext.backend) `
            -AccountAlias ([string]$runtimeContext.account_alias) `
            -OwnerContext $runtimeContext.owner_context `
            -LastCommandCompletedAt ((Get-Date).ToString('o')) `
            -LastCommandDurationMs ([int]$DurationMs) `
            -Existing $existing
    }

    Save-RaymanSessionManifest -WorkspaceRoot $runtimeContext.workspace_root -Manifest $targetManifest | Out-Null
    Set-RaymanActiveSession -WorkspaceRoot $runtimeContext.workspace_root -Manifest $targetManifest -OwnerContext $runtimeContext.owner_context
    $handoverPath = Write-RaymanAutoTempSessionHandover -WorkspaceRoot $runtimeContext.workspace_root -Manifest $targetManifest -CommandText $CommandText -DurationMs $DurationMs
    $artifacts = Save-RaymanSessionDiffArtifacts -WorkspaceRoot $runtimeContext.workspace_root -Slug ([string]$targetManifest.slug)

    $result.checkpointed = $true
    $result.session_kind = if ($targetManifest.PSObject.Properties['session_kind']) { [string]$targetManifest.session_kind } else { $sessionKind }
    $result.session_slug = [string]$targetManifest.slug
    $result.reason = if ([bool]$artifacts.saved) { 'saved' } else { [string]$artifacts.reason }
    $result.artifacts = [pscustomobject]@{
        handover_path = $handoverPath
        auto_save_patch_path = if ($targetManifest.PSObject.Properties['handover_artifacts']) { [string]$targetManifest.handover_artifacts.auto_save_patch_path } else { '' }
        auto_save_meta_path = if ($targetManifest.PSObject.Properties['handover_artifacts']) { [string]$targetManifest.handover_artifacts.auto_save_meta_path } else { '' }
        files_changed = if ($null -ne $artifacts -and $artifacts.PSObject.Properties['files_changed']) { [int]$artifacts.files_changed } else { 0 }
        saved = if ($null -ne $artifacts -and $artifacts.PSObject.Properties['saved']) { [bool]$artifacts.saved } else { $false }
    }
    if (Get-Command Write-RaymanSessionRecall -ErrorAction SilentlyContinue) {
        try {
            Write-RaymanSessionRecall -WorkspaceRoot $runtimeContext.workspace_root -Manifest $targetManifest -HandoverPath $handoverPath -PatchPath ([string]$result.artifacts.auto_save_patch_path) -MetaPath ([string]$result.artifacts.auto_save_meta_path) | Out-Null
        } catch {}
    }
    if (Get-Command Write-RaymanEvent -ErrorAction SilentlyContinue) {
        try {
            Write-RaymanEvent -WorkspaceRoot $runtimeContext.workspace_root -EventType 'session.checkpoint' -Category 'state' -Payload $result | Out-Null
        } catch {}
    }
    return [pscustomobject]$result
}

function Get-RaymanSessionRecords {
    param(
        [string]$WorkspaceRoot,
        [switch]$All
    )

    $sessionRoot = Get-RaymanSessionRootPath -WorkspaceRoot $WorkspaceRoot
    if (-not (Test-Path -LiteralPath $sessionRoot -PathType Container)) {
        return @()
    }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($sessionDir in @(Get-ChildItem -LiteralPath $sessionRoot -Directory -ErrorAction SilentlyContinue)) {
        $manifestPath = Join-Path $sessionDir.FullName 'session.json'
        $manifest = Read-RaymanSessionJsonOrNull -Path $manifestPath
        if ($null -eq $manifest) {
            continue
        }

        $status = if ($manifest.PSObject.Properties['status']) { [string]$manifest.status } else { 'paused' }
        if (-not $All -and $status -ne 'paused') {
            continue
        }

        $updatedAt = ''
        if ($manifest.PSObject.Properties['updated_at']) {
            $updatedAt = [string]$manifest.updated_at
        }

        $sortKey = [datetimeoffset]::MinValue
        if (-not [string]::IsNullOrWhiteSpace($updatedAt)) {
            try { $sortKey = [datetimeoffset]::Parse($updatedAt) } catch {}
        }

        $artifactMap = if ($manifest.PSObject.Properties['handover_artifacts']) {
            $manifest.handover_artifacts
        } else {
            Get-RaymanSessionArtifactMap -Paths (Get-RaymanSessionPaths -WorkspaceRoot $WorkspaceRoot -Slug ([string]$manifest.slug))
        }
        $stashOid = if ($manifest.PSObject.Properties['stash_oid']) { [string]$manifest.stash_oid } else { '' }
        $worktreePath = if ($manifest.PSObject.Properties['worktree_path']) { [string]$manifest.worktree_path } else { '' }
        $backend = if ($manifest.PSObject.Properties['backend']) { [string]$manifest.backend } else { '' }
        $accountAlias = if ($manifest.PSObject.Properties['account_alias']) { [string]$manifest.account_alias } else { '' }
        $ownerDisplay = if ($manifest.PSObject.Properties['owner_display']) { [string]$manifest.owner_display } else { '' }

        $records.Add([pscustomobject]@{
                manifest = $manifest
                name = [string]$manifest.name
                slug = [string]$manifest.slug
                status = $status
                isolation = [string]$manifest.isolation
                session_kind = if ($manifest.PSObject.Properties['session_kind']) { [string]$manifest.session_kind } else { 'manual' }
                backend = $backend
                account_alias = $accountAlias
                owner_source = if ($manifest.PSObject.Properties['owner_source']) { [string]$manifest.owner_source } else { '' }
                owner_token = if ($manifest.PSObject.Properties['owner_token']) { [string]$manifest.owner_token } else { '' }
                owner_display = $ownerDisplay
                owner_key = if ($manifest.PSObject.Properties['owner_key']) { [string]$manifest.owner_key } else { '' }
                owner_pid = if ($manifest.PSObject.Properties['owner_pid']) { [int]$manifest.owner_pid } else { 0 }
                task_description = if ($manifest.PSObject.Properties['task_description']) { [string]$manifest.task_description } else { '' }
                last_command_completed_at = if ($manifest.PSObject.Properties['last_command_completed_at']) { [string]$manifest.last_command_completed_at } else { '' }
                last_command_duration_ms = if ($manifest.PSObject.Properties['last_command_duration_ms']) { [int]$manifest.last_command_duration_ms } else { 0 }
                updated_at = $updatedAt
                sort_key = $sortKey
                stash_oid = $stashOid
                has_stash = (-not [string]::IsNullOrWhiteSpace($stashOid))
                handover_path = if ($artifactMap.PSObject.Properties['handover_path']) { [string]$artifactMap.handover_path } else { '' }
                auto_save_patch_path = if ($artifactMap.PSObject.Properties['auto_save_patch_path']) { [string]$artifactMap.auto_save_patch_path } else { '' }
                auto_save_meta_path = if ($artifactMap.PSObject.Properties['auto_save_meta_path']) { [string]$artifactMap.auto_save_meta_path } else { '' }
                worktree_path = $worktreePath
                has_worktree = (-not [string]::IsNullOrWhiteSpace($worktreePath))
                branch = if ($manifest.PSObject.Properties['branch']) { [string]$manifest.branch } else { '' }
            }) | Out-Null
    }

    return @($records.ToArray() | Sort-Object @{ Expression = { $_.sort_key }; Descending = $true }, @{ Expression = { $_.slug }; Descending = $false })
}

function Format-RaymanSessionListText {
    param([object[]]$Records = @())

    if (@($Records).Count -le 0) {
        return "没有找到可恢复的命名会话。"
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('可用命名会话：') | Out-Null
    foreach ($record in @($Records)) {
        $stashText = if ([bool]$record.has_stash) { 'yes' } else { 'no' }
        $worktreeText = if ([bool]$record.has_worktree) { 'yes' } else { 'no' }
        $backendText = if ([string]::IsNullOrWhiteSpace([string]$record.backend)) { '-' } else { [string]$record.backend }
        $accountText = if ([string]::IsNullOrWhiteSpace([string]$record.account_alias)) { '-' } else { [string]$record.account_alias }
        $ownerText = if ([string]::IsNullOrWhiteSpace([string]$record.owner_display)) { '-' } else { [string]$record.owner_display }
        $lines.Add(('- {0} | kind={1} | status={2} | isolation={3} | backend={4} | account={5} | owner={6} | stash={7} | worktree={8} | updated={9}' -f [string]$record.name, [string]$record.session_kind, [string]$record.status, [string]$record.isolation, $backendText, $accountText, $ownerText, $stashText, $worktreeText, [string]$record.updated_at)) | Out-Null
    }

    return (($lines.ToArray()) -join [Environment]::NewLine)
}
