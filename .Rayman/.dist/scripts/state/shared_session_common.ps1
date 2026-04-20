Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
    . $commonPath
}
$memoryBootstrapPath = Join-Path $PSScriptRoot '..\memory\memory_bootstrap.ps1'
if (Test-Path -LiteralPath $memoryBootstrapPath -PathType Leaf) {
    . $memoryBootstrapPath
}
$eventHooksPath = Join-Path $PSScriptRoot '..\utils\event_hooks.ps1'
if (Test-Path -LiteralPath $eventHooksPath -PathType Leaf) {
    . $eventHooksPath -NoMain
}
$codexCommonPath = Join-Path $PSScriptRoot '..\codex\codex_common.ps1'
if (Test-Path -LiteralPath $codexCommonPath -PathType Leaf) {
    . $codexCommonPath
}

function Get-RaymanSharedSessionWorkspaceRoot {
    param(
        [string]$WorkspaceRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..\..\..') | Select-Object -ExpandProperty Path)
    )

    if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        return (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    }

    if (Get-Command Resolve-RaymanWorkspaceRoot -ErrorAction SilentlyContinue) {
        return (Resolve-RaymanWorkspaceRoot -StartPath $WorkspaceRoot)
    }
    return (Resolve-Path -LiteralPath $WorkspaceRoot).Path
}

function Resolve-RaymanSharedSessionManageScriptPath {
    param([string]$WorkspaceRoot)

    $localCandidate = Join-Path $PSScriptRoot 'manage_shared_sessions.py'
    if (Test-Path -LiteralPath $localCandidate -PathType Leaf) {
        return $localCandidate
    }

    $resolvedRoot = Get-RaymanSharedSessionWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    return (Join-Path $resolvedRoot '.Rayman\scripts\state\manage_shared_sessions.py')
}

function Get-RaymanSharedSessionEnvString {
    param(
        [string]$WorkspaceRoot,
        [string]$Name,
        [string]$Default = ''
    )

    if (Get-Command Get-RaymanWorkspaceEnvString -ErrorAction SilentlyContinue) {
        return [string](Get-RaymanWorkspaceEnvString -WorkspaceRoot $WorkspaceRoot -Name $Name -Default $Default)
    }

    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace([string]$raw)) {
        return $Default
    }
    return [string]$raw
}

function Get-RaymanSharedSessionEnvBool {
    param(
        [string]$WorkspaceRoot,
        [string]$Name,
        [bool]$Default = $false
    )

    if (Get-Command Get-RaymanWorkspaceEnvBool -ErrorAction SilentlyContinue) {
        return [bool](Get-RaymanWorkspaceEnvBool -WorkspaceRoot $WorkspaceRoot -Name $Name -Default $Default)
    }

    $raw = [string](Get-RaymanSharedSessionEnvString -WorkspaceRoot $WorkspaceRoot -Name $Name -Default '')
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $Default
    }
    return ($raw.Trim().ToLowerInvariant() -in @('1', 'true', 'yes', 'on'))
}

function Get-RaymanSharedSessionEnvInt {
    param(
        [string]$WorkspaceRoot,
        [string]$Name,
        [int]$Default,
        [int]$Min = 0,
        [int]$Max = 2147483647
    )

    $raw = [string](Get-RaymanSharedSessionEnvString -WorkspaceRoot $WorkspaceRoot -Name $Name -Default '')
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $Default
    }

    $parsed = 0
    if (-not [int]::TryParse($raw, [ref]$parsed)) {
        return $Default
    }
    if ($parsed -lt $Min) { return $Min }
    if ($parsed -gt $Max) { return $Max }
    return $parsed
}

function Get-RaymanSharedSessionConfig {
    param([string]$WorkspaceRoot)

    $resolvedRoot = Get-RaymanSharedSessionWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    return [pscustomobject]@{
        enabled = Get-RaymanSharedSessionEnvBool -WorkspaceRoot $resolvedRoot -Name 'RAYMAN_SHARED_SESSION_ENABLED' -Default $false
        scope = [string](Get-RaymanSharedSessionEnvString -WorkspaceRoot $resolvedRoot -Name 'RAYMAN_SHARED_SESSION_SCOPE' -Default 'same_machine_single_user')
        copilot_mode = [string](Get-RaymanSharedSessionEnvString -WorkspaceRoot $resolvedRoot -Name 'RAYMAN_SHARED_SESSION_COPILOT_MODE' -Default 'cli_or_sdk')
        lock_timeout_seconds = [int](Get-RaymanSharedSessionEnvInt -WorkspaceRoot $resolvedRoot -Name 'RAYMAN_SHARED_SESSION_LOCK_TIMEOUT_SECONDS' -Default 300 -Min 1 -Max 3600)
        compaction_enabled = Get-RaymanSharedSessionEnvBool -WorkspaceRoot $resolvedRoot -Name 'RAYMAN_SHARED_SESSION_COMPACTION_ENABLED' -Default $true
    }
}

function Test-RaymanSharedSessionEnabled {
    param([string]$WorkspaceRoot)

    return [bool](Get-RaymanSharedSessionConfig -WorkspaceRoot $WorkspaceRoot).enabled
}

function Get-RaymanSharedSessionPaths {
    param([string]$WorkspaceRoot)

    $resolvedRoot = Get-RaymanSharedSessionWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $stateRoot = Join-Path $resolvedRoot '.Rayman\state\shared_sessions'
    $runtimeRoot = Join-Path $resolvedRoot '.Rayman\runtime\shared_sessions'
    return [pscustomobject]@{
        workspace_root = $resolvedRoot
        state_root = $stateRoot
        runtime_root = $runtimeRoot
        database_path = Join-Path $stateRoot 'shared_sessions.sqlite3'
        manage_script = Resolve-RaymanSharedSessionManageScriptPath -WorkspaceRoot $resolvedRoot
    }
}

function Ensure-RaymanSharedSessionDir {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Get-RaymanSharedSessionObjectValue {
    param(
        [object]$Object,
        [string]$Key,
        [object]$Default = ''
    )

    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Key)) {
        return $Default
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Key)) {
            return $Object[$Key]
        }
        foreach ($candidate in @($Object.Keys)) {
            if ([string]$candidate -ieq $Key) {
                return $Object[$candidate]
            }
        }
        return $Default
    }

    if ($Object.PSObject -and $Object.PSObject.Properties[$Key]) {
        return $Object.$Key
    }
    foreach ($property in @($Object.PSObject.Properties)) {
        if ([string]$property.Name -ieq $Key) {
            return $property.Value
        }
    }

    return $Default
}

function Get-RaymanSharedSessionStableHash {
    param([AllowEmptyString()][string]$Value)

    if (Get-Command Get-RaymanSessionStableHash -ErrorAction SilentlyContinue) {
        return (Get-RaymanSessionStableHash -Value $Value)
    }
    if (Get-Command Get-RaymanMemoryStableHash -ErrorAction SilentlyContinue) {
        return (Get-RaymanMemoryStableHash -Value $Value)
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Value)
        $hash = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Resolve-RaymanSharedSessionSlug {
    param(
        [string]$Name = '',
        [string]$Task = '',
        [string]$Command = '',
        [string]$TaskKind = ''
    )

    $candidate = @(
        [string]$Name
        [string]$Task
        [string]$Command
        [string]$TaskKind
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
        $candidate = 'shared-session'
    }

    if (Get-Command ConvertTo-RaymanSessionSlug -ErrorAction SilentlyContinue) {
        return (ConvertTo-RaymanSessionSlug -Name ([string]$candidate))
    }

    $slug = [regex]::Replace(([string]$candidate).ToLowerInvariant(), '[^a-z0-9._-]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        return 'shared-session'
    }
    return $slug
}

function Get-RaymanSharedSessionId {
    param(
        [string]$WorkspaceRoot,
        [string]$TaskSlug
    )

    $resolvedRoot = Get-RaymanSharedSessionWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $workspaceHash = Get-RaymanSharedSessionStableHash -Value $resolvedRoot
    $taskSlugValue = Resolve-RaymanSharedSessionSlug -Name $TaskSlug
    $workspaceShort = $workspaceHash.Substring(0, [Math]::Min(12, $workspaceHash.Length))
    return ('ws-{0}-task-{1}' -f $workspaceShort, $taskSlugValue)
}

function Get-RaymanSharedSessionWorkspaceHash {
    param([string]$WorkspaceRoot)

    return (Get-RaymanSharedSessionStableHash -Value (Get-RaymanSharedSessionWorkspaceRoot -WorkspaceRoot $WorkspaceRoot))
}

function New-RaymanSharedSessionTempPayloadFile {
    param(
        [string]$WorkspaceRoot,
        [object]$Payload
    )

    $paths = Get-RaymanSharedSessionPaths -WorkspaceRoot $WorkspaceRoot
    Ensure-RaymanSharedSessionDir -Path $paths.runtime_root
    $tmpDir = Join-Path $paths.runtime_root 'tmp'
    Ensure-RaymanSharedSessionDir -Path $tmpDir
    $path = Join-Path $tmpDir ('shared-session.' + [Guid]::NewGuid().ToString('n') + '.json')
    $jsonText = (($Payload | ConvertTo-Json -Depth 16).TrimEnd() + "`n")
    if (Get-Command Write-RaymanUtf8NoBom -ErrorAction SilentlyContinue) {
        Write-RaymanUtf8NoBom -Path $path -Content $jsonText
    } else {
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($path, $jsonText, $encoding)
    }
    return $path
}

function Invoke-RaymanSharedSessionBackend {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [ValidateSet('status', 'upsert-session', 'list', 'show', 'append-message', 'link', 'unlink', 'acquire-lock', 'release-lock', 'checkpoint', 'restore-checkpoint', 'compact', 'continue')][string]$Action,
        [string]$InputJsonFile = '',
        [string]$SessionId = '',
        [int]$Limit = 50,
        [int]$MessageLimit = 80,
        [switch]$Quiet
    )

    $paths = Get-RaymanSharedSessionPaths -WorkspaceRoot $WorkspaceRoot
    if (-not (Test-Path -LiteralPath $paths.manage_script -PathType Leaf)) {
        throw ("manage_shared_sessions.py not found: {0}" -f [string]$paths.manage_script)
    }

    $bootstrap = $null
    if (Get-Command Invoke-RaymanMemoryBootstrap -ErrorAction SilentlyContinue) {
        $bootstrap = Invoke-RaymanMemoryBootstrap -WorkspaceRoot $paths.workspace_root -ScriptRoot (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path -SkipStatusProbe -Quiet:$true
    }
    if ($null -eq $bootstrap -or -not [bool]$bootstrap.Success) {
        throw 'shared session backend could not resolve a usable Python runtime.'
    }

    $argsList = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($bootstrap.PythonArgs)) {
        $argsList.Add([string]$item) | Out-Null
    }
    $argsList.Add([string]$paths.manage_script) | Out-Null
    $argsList.Add($Action) | Out-Null
    $argsList.Add('--workspace-root') | Out-Null
    $argsList.Add([string]$paths.workspace_root) | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($InputJsonFile)) {
        $argsList.Add('--input-json-file') | Out-Null
        $argsList.Add((Resolve-Path -LiteralPath $InputJsonFile).Path) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        $argsList.Add('--session-id') | Out-Null
        $argsList.Add($SessionId) | Out-Null
    }
    if ($Limit -gt 0) {
        $argsList.Add('--limit') | Out-Null
        $argsList.Add([string]$Limit) | Out-Null
    }
    if ($MessageLimit -gt 0) {
        $argsList.Add('--message-limit') | Out-Null
        $argsList.Add([string]$MessageLimit) | Out-Null
    }
    $argsList.Add('--json') | Out-Null

    $raw = & $bootstrap.PythonExe $argsList.ToArray()
    $exitCode = [int]$LASTEXITCODE
    $text = (($raw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    if ($exitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($text)) {
            throw ("shared session backend failed with exit code {0}" -f $exitCode)
        }
        throw $text
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    try {
        return ($text | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw ("shared session backend returned invalid JSON: {0}" -f $text)
    }
}

function Get-RaymanSharedSessionStatus {
    param([string]$WorkspaceRoot)

    return (Invoke-RaymanSharedSessionBackend -WorkspaceRoot $WorkspaceRoot -Action 'status')
}

function Get-RaymanSharedSessionList {
    param(
        [string]$WorkspaceRoot,
        [int]$Limit = 50
    )

    return (Invoke-RaymanSharedSessionBackend -WorkspaceRoot $WorkspaceRoot -Action 'list' -Limit $Limit)
}

function Get-RaymanSharedSessionShow {
    param(
        [string]$WorkspaceRoot,
        [string]$SessionId,
        [int]$MessageLimit = 80
    )

    return (Invoke-RaymanSharedSessionBackend -WorkspaceRoot $WorkspaceRoot -Action 'show' -SessionId $SessionId -MessageLimit $MessageLimit)
}

function Ensure-RaymanSharedSession {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [string]$TaskSlug,
        [string]$DisplayName = '',
        [string]$Status = 'active',
        [string]$SummaryText = '',
        [string]$ResumeSummaryText = '',
        [string]$RecapText = '',
        [hashtable]$Metadata = @{},
        [switch]$IgnoreDisabled
    )

    if (-not $IgnoreDisabled -and -not (Test-RaymanSharedSessionEnabled -WorkspaceRoot $WorkspaceRoot)) {
        return [pscustomobject]@{
            schema = 'rayman.shared_session_status.v1'
            success = $true
            skipped = $true
            reason = 'disabled'
            session_id = ''
        }
    }

    $resolvedRoot = Get-RaymanSharedSessionWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $slug = Resolve-RaymanSharedSessionSlug -Name $TaskSlug
    $payload = [ordered]@{
        session_id = Get-RaymanSharedSessionId -WorkspaceRoot $resolvedRoot -TaskSlug $slug
        workspace_root = $resolvedRoot
        workspace_hash = Get-RaymanSharedSessionWorkspaceHash -WorkspaceRoot $resolvedRoot
        task_slug = $slug
        display_name = if (-not [string]::IsNullOrWhiteSpace($DisplayName)) { [string]$DisplayName } else { $slug }
        status = $Status
        scope = [string](Get-RaymanSharedSessionConfig -WorkspaceRoot $resolvedRoot).scope
        canonical_kind = 'workspace_task'
        source_of_truth = 'rayman'
        summary_text = [string]$SummaryText
        resume_summary_text = [string]$ResumeSummaryText
        recap_text = [string]$RecapText
        metadata = $Metadata
    }
    $payloadPath = New-RaymanSharedSessionTempPayloadFile -WorkspaceRoot $resolvedRoot -Payload $payload
    try {
        return (Invoke-RaymanSharedSessionBackend -WorkspaceRoot $resolvedRoot -Action 'upsert-session' -InputJsonFile $payloadPath)
    } finally {
        if (Test-Path -LiteralPath $payloadPath -PathType Leaf) {
            Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Add-RaymanSharedSessionMessage {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [string]$SessionId,
        [ValidateSet('system', 'user', 'assistant', 'tool')][string]$Role,
        [string]$ContentText = '',
        [string]$ResumeText = '',
        [string]$RecapText = '',
        [string]$AuthorKind = 'rayman',
        [string]$AuthorName = '',
        [string]$SourceKind = 'canonical',
        [string]$VendorName = '',
        [string]$VendorSessionId = '',
        [string]$QueueState = 'active',
        [switch]$Protected,
        [hashtable]$Artifact = @{},
        [hashtable]$Metadata = @{},
        [string]$MessageId = ''
    )

    $payload = [ordered]@{
        session_id = $SessionId
        message_id = if (-not [string]::IsNullOrWhiteSpace($MessageId)) { [string]$MessageId } else { '' }
        role = $Role
        author_kind = $AuthorKind
        author_name = $AuthorName
        content_text = $ContentText
        resume_text = $ResumeText
        recap_text = $RecapText
        source_kind = $SourceKind
        vendor_name = $VendorName
        vendor_session_id = $VendorSessionId
        queue_state = $QueueState
        protected = [bool]$Protected
        artifact = $Artifact
        metadata = $Metadata
    }
    $payloadPath = New-RaymanSharedSessionTempPayloadFile -WorkspaceRoot $WorkspaceRoot -Payload $payload
    try {
        return (Invoke-RaymanSharedSessionBackend -WorkspaceRoot $WorkspaceRoot -Action 'append-message' -InputJsonFile $payloadPath)
    } finally {
        if (Test-Path -LiteralPath $payloadPath -PathType Leaf) {
            Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Add-RaymanSharedSessionLink {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [string]$SessionId,
        [string]$VendorName,
        [string]$VendorSessionId,
        [string]$AdapterKind = '',
        [string]$ContinuityMode = 'transcript_bridge',
        [bool]$NativeResumeSupported = $false,
        [hashtable]$State = @{},
        [string]$Status = 'linked'
    )

    $payload = [ordered]@{
        session_id = $SessionId
        vendor_name = $VendorName
        vendor_session_id = $VendorSessionId
        adapter_kind = $AdapterKind
        continuity_mode = $ContinuityMode
        native_resume_supported = [bool]$NativeResumeSupported
        workspace_root = (Get-RaymanSharedSessionWorkspaceRoot -WorkspaceRoot $WorkspaceRoot)
        state = $State
        status = $Status
    }
    $payloadPath = New-RaymanSharedSessionTempPayloadFile -WorkspaceRoot $WorkspaceRoot -Payload $payload
    try {
        return (Invoke-RaymanSharedSessionBackend -WorkspaceRoot $WorkspaceRoot -Action 'link' -InputJsonFile $payloadPath)
    } finally {
        if (Test-Path -LiteralPath $payloadPath -PathType Leaf) {
            Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-RaymanSharedSessionLink {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [string]$SessionId,
        [string]$VendorName = '',
        [string]$VendorSessionId = ''
    )

    $payload = [ordered]@{
        session_id = $SessionId
        vendor_name = $VendorName
        vendor_session_id = $VendorSessionId
    }
    $payloadPath = New-RaymanSharedSessionTempPayloadFile -WorkspaceRoot $WorkspaceRoot -Payload $payload
    try {
        return (Invoke-RaymanSharedSessionBackend -WorkspaceRoot $WorkspaceRoot -Action 'unlink' -InputJsonFile $payloadPath)
    } finally {
        if (Test-Path -LiteralPath $payloadPath -PathType Leaf) {
            Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Enter-RaymanSharedSessionLock {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [string]$SessionId,
        [string]$OwnerId,
        [string]$OwnerLabel = '',
        [object]$QueueItem = $null
    )

    $config = Get-RaymanSharedSessionConfig -WorkspaceRoot $WorkspaceRoot
    $payload = [ordered]@{
        session_id = $SessionId
        owner_id = $OwnerId
        owner_label = if (-not [string]::IsNullOrWhiteSpace($OwnerLabel)) { [string]$OwnerLabel } else { [string]$OwnerId }
        timeout_seconds = [int]$config.lock_timeout_seconds
    }
    if ($null -ne $QueueItem) {
        $payload['queue_item'] = $QueueItem
    }
    $payloadPath = New-RaymanSharedSessionTempPayloadFile -WorkspaceRoot $WorkspaceRoot -Payload $payload
    try {
        return (Invoke-RaymanSharedSessionBackend -WorkspaceRoot $WorkspaceRoot -Action 'acquire-lock' -InputJsonFile $payloadPath)
    } finally {
        if (Test-Path -LiteralPath $payloadPath -PathType Leaf) {
            Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Exit-RaymanSharedSessionLock {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [string]$SessionId,
        [string]$OwnerId = '',
        [switch]$Force
    )

    $payload = [ordered]@{
        session_id = $SessionId
        owner_id = $OwnerId
        force = [bool]$Force
    }
    $payloadPath = New-RaymanSharedSessionTempPayloadFile -WorkspaceRoot $WorkspaceRoot -Payload $payload
    try {
        return (Invoke-RaymanSharedSessionBackend -WorkspaceRoot $WorkspaceRoot -Action 'release-lock' -InputJsonFile $payloadPath)
    } finally {
        if (Test-Path -LiteralPath $payloadPath -PathType Leaf) {
            Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Save-RaymanSharedSessionCheckpoint {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [string]$SessionId,
        [string]$CheckpointKind,
        [string]$SessionSlug = '',
        [string]$SessionKind = '',
        [string]$HandoverPath = '',
        [string]$PatchPath = '',
        [string]$MetaPath = '',
        [string]$StashOid = '',
        [string]$WorktreePath = '',
        [string]$Branch = '',
        [string]$SummaryText = '',
        [bool]$Destructive = $false,
        [hashtable]$Metadata = @{},
        [string]$CheckpointId = '',
        [int]$TurnIndex = 0
    )

    $idValue = if (-not [string]::IsNullOrWhiteSpace($CheckpointId)) {
        [string]$CheckpointId
    } else {
        'chk-' + (Get-RaymanSharedSessionStableHash -Value (($SessionId, $CheckpointKind, $SessionSlug, $PatchPath, $StashOid, $WorktreePath, $SummaryText) -join '|')).Substring(0, 24)
    }

    $payload = [ordered]@{
        checkpoint_id = $idValue
        session_id = $SessionId
        checkpoint_kind = $CheckpointKind
        turn_index = [int]$TurnIndex
        destructive = [bool]$Destructive
        session_slug = $SessionSlug
        session_kind = $SessionKind
        handover_path = $HandoverPath
        patch_path = $PatchPath
        meta_path = $MetaPath
        stash_oid = $StashOid
        worktree_path = $WorktreePath
        branch = $Branch
        summary_text = $SummaryText
        metadata = $Metadata
    }
    $payloadPath = New-RaymanSharedSessionTempPayloadFile -WorkspaceRoot $WorkspaceRoot -Payload $payload
    try {
        return (Invoke-RaymanSharedSessionBackend -WorkspaceRoot $WorkspaceRoot -Action 'checkpoint' -InputJsonFile $payloadPath)
    } finally {
        if (Test-Path -LiteralPath $payloadPath -PathType Leaf) {
            Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Restore-RaymanSharedSessionCheckpoint {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [string]$SessionId,
        [string]$CheckpointId = '',
        [string]$RestoredBy = ''
    )

    $payload = [ordered]@{
        session_id = $SessionId
        checkpoint_id = $CheckpointId
        restored_by = $RestoredBy
    }
    $payloadPath = New-RaymanSharedSessionTempPayloadFile -WorkspaceRoot $WorkspaceRoot -Payload $payload
    try {
        return (Invoke-RaymanSharedSessionBackend -WorkspaceRoot $WorkspaceRoot -Action 'restore-checkpoint' -InputJsonFile $payloadPath)
    } finally {
        if (Test-Path -LiteralPath $payloadPath -PathType Leaf) {
            Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-RaymanSharedSessionCompaction {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [string]$SessionId
    )

    if (-not [bool](Get-RaymanSharedSessionConfig -WorkspaceRoot $WorkspaceRoot).compaction_enabled) {
        return [pscustomobject]@{
            schema = 'rayman.shared_session_status.v1'
            success = $true
            compacted = 0
            skipped = $true
            reason = 'disabled'
            session_id = $SessionId
        }
    }

    $payload = [ordered]@{
        session_id = $SessionId
    }
    $payloadPath = New-RaymanSharedSessionTempPayloadFile -WorkspaceRoot $WorkspaceRoot -Payload $payload
    try {
        return (Invoke-RaymanSharedSessionBackend -WorkspaceRoot $WorkspaceRoot -Action 'compact' -InputJsonFile $payloadPath)
    } finally {
        if (Test-Path -LiteralPath $payloadPath -PathType Leaf) {
            Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-RaymanSharedSessionContinueContext {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [string]$SessionId,
        [int]$MessageLimit = 80
    )

    $payload = [ordered]@{
        session_id = $SessionId
        compact = [bool](Get-RaymanSharedSessionConfig -WorkspaceRoot $WorkspaceRoot).compaction_enabled
    }
    $payloadPath = New-RaymanSharedSessionTempPayloadFile -WorkspaceRoot $WorkspaceRoot -Payload $payload
    try {
        return (Invoke-RaymanSharedSessionBackend -WorkspaceRoot $WorkspaceRoot -Action 'continue' -InputJsonFile $payloadPath -SessionId $SessionId -MessageLimit $MessageLimit)
    } finally {
        if (Test-Path -LiteralPath $payloadPath -PathType Leaf) {
            Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-RaymanSharedSessionPromptPreamble {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [string]$Task = '',
        [string]$Command = '',
        [string]$TaskKind = '',
        [string]$TaskSlug = ''
    )

    if (-not (Test-RaymanSharedSessionEnabled -WorkspaceRoot $WorkspaceRoot)) {
        return ''
    }

    $slug = if (-not [string]::IsNullOrWhiteSpace($TaskSlug)) {
        Resolve-RaymanSharedSessionSlug -Name $TaskSlug
    } else {
        Resolve-RaymanSharedSessionSlug -Task $Task -Command $Command -TaskKind $TaskKind
    }
    $sessionId = Get-RaymanSharedSessionId -WorkspaceRoot $WorkspaceRoot -TaskSlug $slug
    try {
        $context = Get-RaymanSharedSessionContinueContext -WorkspaceRoot $WorkspaceRoot -SessionId $sessionId
    } catch {
        return ''
    }

    if ($null -eq $context -or -not [bool]$context.success -or $null -eq $context.continuation) {
        return ''
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('[RaymanSharedSession]') | Out-Null
    $lines.Add(("session_id={0}" -f [string]$sessionId)) | Out-Null
    $lines.Add(("task_slug={0}" -f [string]$slug)) | Out-Null
    $summaryText = [string]$context.continuation.summary_text
    if (-not [string]::IsNullOrWhiteSpace($summaryText)) {
        $lines.Add(("summary={0}" -f $summaryText)) | Out-Null
    }

    $nativeLinks = @($context.continuation.native_resume_links)
    if ($nativeLinks.Count -gt 0) {
        $lines.Add('native_resume_links:') | Out-Null
        foreach ($link in $nativeLinks) {
            $lines.Add(("- {0}:{1} mode={2}" -f [string]$link.vendor_name, [string]$link.vendor_session_id, [string]$link.continuity_mode)) | Out-Null
        }
    }

    $queuedMessages = @($context.continuation.queued_messages)
    if ($queuedMessages.Count -gt 0) {
        $lines.Add('queued_messages:') | Out-Null
        foreach ($message in $queuedMessages | Select-Object -First 3) {
            $content = [string]$message.content_text
            if ($content.Length -gt 240) {
                $content = $content.Substring(0, 240) + '...'
            }
            $lines.Add(("- [{0}] {1}" -f [string]$message.role, $content)) | Out-Null
        }
    }

    $recentTail = @($context.continuation.recent_tail)
    if ($recentTail.Count -gt 0) {
        $lines.Add('recent_tail:') | Out-Null
        foreach ($message in $recentTail | Select-Object -Last 4) {
            $text = if (-not [string]::IsNullOrWhiteSpace([string]$message.resume_text)) { [string]$message.resume_text } else { [string]$message.content_text }
            if ($text.Length -gt 240) {
                $text = $text.Substring(0, 240) + '...'
            }
            $lines.Add(("- [{0}] {1}" -f [string]$message.role, $text)) | Out-Null
        }
    }
    $lines.Add('[/RaymanSharedSession]') | Out-Null
    return ($lines -join "`n")
}

function Get-RaymanSharedSessionCurrentProcessId {
    return [System.Diagnostics.Process]::GetCurrentProcess().Id
}

function Get-RaymanSharedSessionCurrentUserHome {
    if (Get-Command Get-RaymanUserHomePath -ErrorAction SilentlyContinue) {
        return [string](Get-RaymanUserHomePath)
    }
    return [string][Environment]::GetFolderPath('UserProfile')
}

function Test-RaymanSharedSessionPathsEquivalent {
    param(
        [string]$LeftPath,
        [string]$RightPath
    )

    if ([string]::IsNullOrWhiteSpace($LeftPath) -or [string]::IsNullOrWhiteSpace($RightPath)) {
        return $false
    }
    if (Get-Command Test-RaymanPathsEquivalent -ErrorAction SilentlyContinue) {
        return (Test-RaymanPathsEquivalent -LeftPath $LeftPath -RightPath $RightPath)
    }
    try {
        return ((Resolve-Path -LiteralPath $LeftPath).Path.TrimEnd('\').ToLowerInvariant() -eq (Resolve-Path -LiteralPath $RightPath).Path.TrimEnd('\').ToLowerInvariant())
    } catch {
        return $false
    }
}

function Sync-RaymanSharedSessionCodexLinks {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [string]$SessionId,
        [string]$AccountAlias = ''
    )

    $results = New-Object System.Collections.Generic.List[object]
    if (-not (Get-Command Get-RaymanCodexLatestNativeSession -ErrorAction SilentlyContinue)) {
        return @()
    }

    try {
        $nativeSession = if ([string]::IsNullOrWhiteSpace($AccountAlias)) {
            Get-RaymanCodexLatestNativeSession
        } else {
            Get-RaymanCodexLatestNativeSession -Alias $AccountAlias
        }
        if ($null -ne $nativeSession -and [bool]$nativeSession.available -and -not [string]::IsNullOrWhiteSpace([string]$nativeSession.id)) {
            $state = @{
                thread_name = [string]$nativeSession.thread_name
                updated_at = [string]$nativeSession.updated_at
                source = [string]$nativeSession.source
                session_index_path = [string]$nativeSession.session_index_path
                account_alias = [string]$AccountAlias
            }
            $results.Add((Add-RaymanSharedSessionLink -WorkspaceRoot $WorkspaceRoot -SessionId $SessionId -VendorName 'codex-cli' -VendorSessionId ([string]$nativeSession.id) -AdapterKind 'codex_session_index' -ContinuityMode 'native_resume' -NativeResumeSupported $true -State $state)) | Out-Null
            $messageId = 'vendor-codex-cli-' + (Get-RaymanSharedSessionStableHash -Value ([string]$nativeSession.id)).Substring(0, 20)
            $content = ('Codex CLI linked session {0} ({1})' -f [string]$nativeSession.id, [string]$nativeSession.thread_name)
            $null = Add-RaymanSharedSessionMessage -WorkspaceRoot $WorkspaceRoot -SessionId $SessionId -Role assistant -ContentText $content -ResumeText $content -AuthorKind 'codex' -AuthorName 'Codex CLI' -SourceKind 'vendor_link' -VendorName 'codex-cli' -VendorSessionId ([string]$nativeSession.id) -Artifact @{ session_index_path = [string]$nativeSession.session_index_path } -MessageId $messageId
        }
    } catch {}

    if (Get-Command Get-RaymanCodexDesktopLatestWorkspaceSession -ErrorAction SilentlyContinue) {
        try {
            $desktopSession = Get-RaymanCodexDesktopLatestWorkspaceSession -WorkspaceRoot $WorkspaceRoot
            if ($null -ne $desktopSession -and [bool]$desktopSession.available -and -not [string]::IsNullOrWhiteSpace([string]$desktopSession.session_id)) {
                $state = @{
                    session_path = [string]$desktopSession.session_path
                    last_write_at = [string]$desktopSession.last_write_at
                    workspace_root = [string]$desktopSession.workspace_root
                }
                $results.Add((Add-RaymanSharedSessionLink -WorkspaceRoot $WorkspaceRoot -SessionId $SessionId -VendorName 'codex-desktop' -VendorSessionId ([string]$desktopSession.session_id) -AdapterKind 'codex_rollout' -ContinuityMode 'native_resume' -NativeResumeSupported $true -State $state)) | Out-Null
                $tailText = ''
                if (Get-Command Get-RaymanCodexDesktopSessionTailText -ErrorAction SilentlyContinue) {
                    $tailText = [string](Get-RaymanCodexDesktopSessionTailText -SessionPath ([string]$desktopSession.session_path) -TailCount 40)
                }
                if (-not [string]::IsNullOrWhiteSpace($tailText)) {
                    $messageId = 'vendor-codex-desktop-' + (Get-RaymanSharedSessionStableHash -Value ([string]$desktopSession.session_id)).Substring(0, 20)
                    $resumeText = $tailText
                    if ($resumeText.Length -gt 1200) {
                        $resumeText = $resumeText.Substring(0, 1200) + '...'
                    }
                    $null = Add-RaymanSharedSessionMessage -WorkspaceRoot $WorkspaceRoot -SessionId $SessionId -Role assistant -ContentText $tailText -ResumeText $resumeText -RecapText $resumeText -AuthorKind 'codex' -AuthorName 'Codex Desktop' -SourceKind 'vendor_import' -VendorName 'codex-desktop' -VendorSessionId ([string]$desktopSession.session_id) -Artifact @{ session_path = [string]$desktopSession.session_path } -MessageId $messageId
                }
            }
        } catch {}
    }

    return @($results.ToArray())
}

function Get-RaymanSharedSessionCopilotStateRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    $override = [Environment]::GetEnvironmentVariable('RAYMAN_SHARED_SESSION_COPILOT_CHRONICLE_ROOT')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $roots.Add([string]$override) | Out-Null
    }
    $home = Get-RaymanSharedSessionCurrentUserHome
    if (-not [string]::IsNullOrWhiteSpace($home)) {
        $roots.Add((Join-Path $home '.copilot\session-state')) | Out-Null
        $roots.Add((Join-Path $home '.config\github-copilot-cli\chronicle')) | Out-Null
    }
    return @($roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Read-RaymanSharedSessionJsonFileOrNull {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Sync-RaymanSharedSessionCopilotLinks {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [string]$SessionId
    )

    $results = New-Object System.Collections.Generic.List[object]
    $resolvedRoot = Get-RaymanSharedSessionWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    foreach ($root in @(Get-RaymanSharedSessionCopilotStateRoots)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        $selected = $null
        foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
            $metadataCandidate = @(
                (Join-Path $directory.FullName 'metadata.json')
                (Join-Path $directory.FullName 'session.json')
                (Join-Path $directory.FullName 'state.json')
            ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

            $metadata = Read-RaymanSharedSessionJsonFileOrNull -Path $metadataCandidate
            $workspaceCandidate = ''
            if ($null -ne $metadata) {
                foreach ($propertyName in @('workspace_root', 'workspaceRoot', 'cwd', 'workingDirectory')) {
                    if ($metadata.PSObject.Properties[$propertyName]) {
                        $workspaceCandidate = [string]$metadata.$propertyName
                        if (-not [string]::IsNullOrWhiteSpace($workspaceCandidate)) { break }
                    }
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($workspaceCandidate) -and -not (Test-RaymanSharedSessionPathsEquivalent -LeftPath $workspaceCandidate -RightPath $resolvedRoot)) {
                continue
            }

            $selected = [pscustomobject]@{
                directory = $directory.FullName
                session_id = $directory.Name
                metadata = $metadata
                metadata_path = [string]$metadataCandidate
                last_write_at = $directory.LastWriteTime.ToString('o')
            }
            break
        }

        if ($null -eq $selected) {
            continue
        }

        $state = @{
            directory = [string]$selected.directory
            metadata_path = [string]$selected.metadata_path
            last_write_at = [string]$selected.last_write_at
        }
        $results.Add((Add-RaymanSharedSessionLink -WorkspaceRoot $resolvedRoot -SessionId $SessionId -VendorName 'copilot-cli' -VendorSessionId ([string]$selected.session_id) -AdapterKind 'copilot_session_state' -ContinuityMode 'native_resume' -NativeResumeSupported $true -State $state)) | Out-Null

        $summaryText = ('Copilot CLI linked session {0}' -f [string]$selected.session_id)
        $messageId = 'vendor-copilot-cli-' + (Get-RaymanSharedSessionStableHash -Value ([string]$selected.session_id)).Substring(0, 20)
        $null = Add-RaymanSharedSessionMessage -WorkspaceRoot $resolvedRoot -SessionId $SessionId -Role assistant -ContentText $summaryText -ResumeText $summaryText -AuthorKind 'copilot' -AuthorName 'Copilot CLI' -SourceKind 'vendor_link' -VendorName 'copilot-cli' -VendorSessionId ([string]$selected.session_id) -Artifact @{ session_state_root = [string]$selected.directory } -MessageId $messageId
        break
    }

    $sdkSessionId = [string](Get-RaymanSharedSessionEnvString -WorkspaceRoot $resolvedRoot -Name 'RAYMAN_SHARED_SESSION_COPILOT_SDK_SESSION_ID' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($sdkSessionId)) {
        $results.Add((Add-RaymanSharedSessionLink -WorkspaceRoot $resolvedRoot -SessionId $SessionId -VendorName 'copilot-sdk' -VendorSessionId $sdkSessionId -AdapterKind 'copilot_sdk' -ContinuityMode 'native_resume' -NativeResumeSupported $true -State @{ session_id = $sdkSessionId })) | Out-Null
    }

    return @($results.ToArray())
}

function Sync-RaymanSharedSessionAdapters {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [string]$SessionId,
        [string]$AccountAlias = ''
    )

    $linked = New-Object System.Collections.Generic.List[object]
    foreach ($item in @(Sync-RaymanSharedSessionCodexLinks -WorkspaceRoot $WorkspaceRoot -SessionId $SessionId -AccountAlias $AccountAlias)) {
        $linked.Add($item) | Out-Null
    }
    foreach ($item in @(Sync-RaymanSharedSessionCopilotLinks -WorkspaceRoot $WorkspaceRoot -SessionId $SessionId)) {
        $linked.Add($item) | Out-Null
    }
    return @($linked.ToArray())
}

function Sync-RaymanSharedSessionFromManifest {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [object]$Manifest,
        [string]$HandoverPath = '',
        [string]$PatchPath = '',
        [string]$MetaPath = '',
        [string]$Action = 'state-save',
        [switch]$IgnoreDisabled
    )

    if ($null -eq $Manifest) {
        return $null
    }
    if (-not $IgnoreDisabled -and -not (Test-RaymanSharedSessionEnabled -WorkspaceRoot $WorkspaceRoot)) {
        return $null
    }

    $resolvedRoot = Get-RaymanSharedSessionWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $slug = Resolve-RaymanSharedSessionSlug -Name ([string](Get-RaymanSharedSessionObjectValue -Object $Manifest -Key 'slug' -Default ''))
    $displayName = [string](Get-RaymanSharedSessionObjectValue -Object $Manifest -Key 'name' -Default $slug)
    $taskDescription = [string](Get-RaymanSharedSessionObjectValue -Object $Manifest -Key 'task_description' -Default '')
    $handoverText = ''
    if (-not [string]::IsNullOrWhiteSpace($HandoverPath) -and (Test-Path -LiteralPath $HandoverPath -PathType Leaf)) {
        try {
            $handoverText = (Get-Content -LiteralPath $HandoverPath -Raw -Encoding UTF8 -ErrorAction Stop).Trim()
        } catch {
            $handoverText = ''
        }
    }

    $metadata = @{
        action = $Action
        session_slug = $slug
        session_kind = [string](Get-RaymanSharedSessionObjectValue -Object $Manifest -Key 'session_kind' -Default 'manual')
        isolation = [string](Get-RaymanSharedSessionObjectValue -Object $Manifest -Key 'isolation' -Default 'shared')
        backend = [string](Get-RaymanSharedSessionObjectValue -Object $Manifest -Key 'backend' -Default '')
        account_alias = [string](Get-RaymanSharedSessionObjectValue -Object $Manifest -Key 'account_alias' -Default '')
        owner_display = [string](Get-RaymanSharedSessionObjectValue -Object $Manifest -Key 'owner_display' -Default '')
        owner_key = [string](Get-RaymanSharedSessionObjectValue -Object $Manifest -Key 'owner_key' -Default '')
        worktree_path = [string](Get-RaymanSharedSessionObjectValue -Object $Manifest -Key 'worktree_path' -Default '')
        branch = [string](Get-RaymanSharedSessionObjectValue -Object $Manifest -Key 'branch' -Default '')
    }

    $sessionResult = Ensure-RaymanSharedSession -WorkspaceRoot $resolvedRoot -TaskSlug $slug -DisplayName $displayName -Status ([string](Get-RaymanSharedSessionObjectValue -Object $Manifest -Key 'status' -Default 'active')) -SummaryText $(if (-not [string]::IsNullOrWhiteSpace($handoverText)) { $handoverText } else { $taskDescription }) -ResumeSummaryText $taskDescription -RecapText $(if (-not [string]::IsNullOrWhiteSpace($handoverText)) { $handoverText } else { $taskDescription }) -Metadata $metadata -IgnoreDisabled:$IgnoreDisabled
    if ($null -eq $sessionResult -or -not [bool]$sessionResult.success) {
        return $sessionResult
    }
    $sessionId = [string]$sessionResult.session.session_id

    $messageId = 'state-' + (Get-RaymanSharedSessionStableHash -Value (($sessionId, $Action, $HandoverPath, $PatchPath, $MetaPath, $taskDescription) -join '|')).Substring(0, 24)
    $messageText = if (-not [string]::IsNullOrWhiteSpace($handoverText)) { $handoverText } else { $taskDescription }
    if (-not [string]::IsNullOrWhiteSpace($messageText)) {
        $null = Add-RaymanSharedSessionMessage -WorkspaceRoot $resolvedRoot -SessionId $sessionId -Role assistant -ContentText $messageText -ResumeText $taskDescription -RecapText $taskDescription -AuthorKind 'rayman' -AuthorName 'Rayman State' -SourceKind $Action -Artifact @{ handover_path = $HandoverPath; patch_path = $PatchPath; meta_path = $MetaPath } -Metadata $metadata -MessageId $messageId
        if (Get-Command Write-RaymanEvent -ErrorAction SilentlyContinue) {
            $eventType = if ([bool]$sessionResult.created) { 'shared_session.created' } else { 'shared_session.message_added' }
            Write-RaymanEvent -WorkspaceRoot $resolvedRoot -EventType $eventType -Category 'state' -Payload ([ordered]@{
                    session_id = $sessionId
                    session_slug = $slug
                    source_action = $Action
                }) | Out-Null
        }
    }

    $checkpointResult = Save-RaymanSharedSessionCheckpoint -WorkspaceRoot $resolvedRoot -SessionId $sessionId -CheckpointKind $Action -SessionSlug $slug -SessionKind ([string](Get-RaymanSharedSessionObjectValue -Object $Manifest -Key 'session_kind' -Default 'manual')) -HandoverPath $HandoverPath -PatchPath $PatchPath -MetaPath $MetaPath -StashOid ([string](Get-RaymanSharedSessionObjectValue -Object $Manifest -Key 'stash_oid' -Default '')) -WorktreePath ([string](Get-RaymanSharedSessionObjectValue -Object $Manifest -Key 'worktree_path' -Default '')) -Branch ([string](Get-RaymanSharedSessionObjectValue -Object $Manifest -Key 'branch' -Default '')) -SummaryText $taskDescription -Metadata $metadata

    $linkedResults = @()
    if ($metadata.backend -eq 'codex' -or -not [string]::IsNullOrWhiteSpace([string]$metadata.account_alias)) {
        $linkedResults = @(Sync-RaymanSharedSessionAdapters -WorkspaceRoot $resolvedRoot -SessionId $sessionId -AccountAlias ([string]$metadata.account_alias))
        if ($linkedResults.Count -gt 0 -and (Get-Command Write-RaymanEvent -ErrorAction SilentlyContinue)) {
            Write-RaymanEvent -WorkspaceRoot $resolvedRoot -EventType 'shared_session.linked' -Category 'state' -Payload ([ordered]@{
                    session_id = $sessionId
                    vendor_links = @($linkedResults | ForEach-Object {
                            [ordered]@{
                                vendor_name = [string]$_.vendor_name
                                vendor_session_id = [string]$_.vendor_session_id
                            }
                        })
                }) | Out-Null
        }
    }

    if ([bool](Get-RaymanSharedSessionConfig -WorkspaceRoot $resolvedRoot).compaction_enabled) {
        $compactResult = Invoke-RaymanSharedSessionCompaction -WorkspaceRoot $resolvedRoot -SessionId $sessionId
        if ($null -ne $compactResult -and [int]$compactResult.compacted -gt 0 -and (Get-Command Write-RaymanEvent -ErrorAction SilentlyContinue)) {
            Write-RaymanEvent -WorkspaceRoot $resolvedRoot -EventType 'shared_session.compacted' -Category 'state' -Payload ([ordered]@{
                    session_id = $sessionId
                    compacted = [int]$compactResult.compacted
                }) | Out-Null
        }
    }

    return [pscustomobject]@{
        schema = 'rayman.shared_session_sync.v1'
        success = $true
        session_id = $sessionId
        session_slug = $slug
        created = [bool]$sessionResult.created
        checkpoint_id = [string]$checkpointResult.checkpoint_id
        linked = @($linkedResults)
    }
}

function Sync-RaymanSharedSessionCommandCheckpoint {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [object]$CheckpointResult,
        [string]$CommandText = '',
        [string]$Backend = '',
        [string]$AccountAlias = ''
    )

    if ($null -eq $CheckpointResult -or -not [bool]$CheckpointResult.checkpointed) {
        return $null
    }
    if (-not (Test-RaymanSharedSessionEnabled -WorkspaceRoot $WorkspaceRoot)) {
        return $null
    }

    $resolvedRoot = Get-RaymanSharedSessionWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $slug = [string]$CheckpointResult.session_slug
    $manifest = $null
    if (Get-Command Read-RaymanSessionManifest -ErrorAction SilentlyContinue) {
        $manifest = Read-RaymanSessionManifest -WorkspaceRoot $resolvedRoot -Slug $slug
    }
    if ($null -eq $manifest) {
        return $null
    }

    $paths = Get-RaymanSessionPaths -WorkspaceRoot $resolvedRoot -Slug $slug
    $sync = Sync-RaymanSharedSessionFromManifest -WorkspaceRoot $resolvedRoot -Manifest $manifest -HandoverPath ([string]$paths.handover_path) -PatchPath ([string]$paths.auto_save_patch_path) -MetaPath ([string]$paths.auto_save_meta_path) -Action 'auto-temp'
    if ($null -eq $sync -or -not [bool]$sync.success) {
        return $sync
    }

    if (-not [string]::IsNullOrWhiteSpace($CommandText)) {
        $messageId = 'auto-temp-command-' + (Get-RaymanSharedSessionStableHash -Value (($sync.session_id, $CommandText, $Backend, $AccountAlias) -join '|')).Substring(0, 24)
        $null = Add-RaymanSharedSessionMessage -WorkspaceRoot $resolvedRoot -SessionId ([string]$sync.session_id) -Role tool -ContentText $CommandText -ResumeText $CommandText -AuthorKind 'rayman' -AuthorName 'Rayman Dispatch' -SourceKind 'auto_temp' -Metadata @{ backend = $Backend; account_alias = $AccountAlias } -MessageId $messageId
    }

    return $sync
}

function Sync-RaymanSharedSessionDispatchStart {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [string]$RunId,
        [string]$TaskKind,
        [string]$Task,
        [string]$Command,
        [string]$PreferredBackend = ''
    )

    if (-not (Test-RaymanSharedSessionEnabled -WorkspaceRoot $WorkspaceRoot)) {
        return $null
    }

    $slug = Resolve-RaymanSharedSessionSlug -Task $Task -Command $Command -TaskKind $TaskKind
    $displayName = if (-not [string]::IsNullOrWhiteSpace($Task)) { [string]$Task } elseif (-not [string]::IsNullOrWhiteSpace($Command)) { [string]$Command } else { ('dispatch ' + [string]$TaskKind) }
    $summaryText = @(
        [string]$Task
        [string]$Command
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    $metadata = @{
        run_id = $RunId
        task_kind = $TaskKind
        preferred_backend = $PreferredBackend
    }
    $session = Ensure-RaymanSharedSession -WorkspaceRoot $WorkspaceRoot -TaskSlug $slug -DisplayName $displayName -Status 'active' -SummaryText $summaryText -ResumeSummaryText $summaryText -RecapText $summaryText -Metadata $metadata
    if ($null -eq $session -or -not [bool]$session.success) {
        return $session
    }

    $sessionId = [string]$session.session.session_id
    $lockOwnerId = ('dispatch:{0}' -f $RunId)
    $queueItem = [ordered]@{
        run_id = $RunId
        task_kind = $TaskKind
        task = $Task
        command = $Command
        queued_at = (Get-Date).ToString('o')
    }
    $lock = Enter-RaymanSharedSessionLock -WorkspaceRoot $WorkspaceRoot -SessionId $sessionId -OwnerId $lockOwnerId -OwnerLabel ('dispatch ' + $RunId) -QueueItem $queueItem
    if ($null -ne $lock -and -not [bool]$lock.acquired) {
        $queuedText = @(
            [string]$Task
            [string]$Command
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
        if (-not [string]::IsNullOrWhiteSpace([string]$queuedText)) {
            $null = Add-RaymanSharedSessionMessage -WorkspaceRoot $WorkspaceRoot -SessionId $sessionId -Role user -ContentText $queuedText -ResumeText $queuedText -AuthorKind 'rayman' -AuthorName 'Rayman Dispatch' -SourceKind 'dispatch_queued' -QueueState 'queued' -Metadata @{ run_id = $RunId; task_kind = $TaskKind }
        }
    } elseif ($null -ne $lock -and [bool]$lock.acquired) {
        $userText = @(
            [string]$Task
            [string]$Command
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
        if (-not [string]::IsNullOrWhiteSpace([string]$userText)) {
            $null = Add-RaymanSharedSessionMessage -WorkspaceRoot $WorkspaceRoot -SessionId $sessionId -Role user -ContentText $userText -ResumeText $userText -AuthorKind 'rayman' -AuthorName 'Rayman Dispatch' -SourceKind 'dispatch_start' -Metadata @{ run_id = $RunId; task_kind = $TaskKind; preferred_backend = $PreferredBackend }
        }
        if (Get-Command Write-RaymanEvent -ErrorAction SilentlyContinue) {
            Write-RaymanEvent -WorkspaceRoot $WorkspaceRoot -EventType 'shared_session.locked' -Category 'dispatch' -Payload ([ordered]@{
                    session_id = $sessionId
                    owner_id = [string]$lock.owner_id
                    run_id = $RunId
                    queued_count = [int]$lock.queued_count
                }) | Out-Null
        }
    }

    $preamble = Get-RaymanSharedSessionPromptPreamble -WorkspaceRoot $WorkspaceRoot -Task $Task -Command $Command -TaskKind $TaskKind -TaskSlug $slug
    return [pscustomobject]@{
        schema = 'rayman.shared_session_status.v1'
        success = $true
        session_id = $sessionId
        task_slug = $slug
        lock = $lock
        prompt_preamble = $preamble
        queued = $(if ($null -ne $lock) { -not [bool]$lock.acquired } else { $false })
        lock_owner_id = $lockOwnerId
    }
}

function Sync-RaymanSharedSessionDispatchFinish {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [string]$RunId,
        [string]$SessionId,
        [string]$OwnerId = '',
        [bool]$Success,
        [string]$SelectedBackend = '',
        [string]$SelectionReason = '',
        [string]$ErrorMessage = '',
        [object]$TempCheckpoint = $null
    )

    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        return $null
    }

    $summaryText = if ($Success) {
        ('dispatch success via {0}: {1}' -f $SelectedBackend, $SelectionReason)
    } elseif (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
        ('dispatch failed via {0}: {1}' -f $SelectedBackend, $ErrorMessage)
    } else {
        ('dispatch finished via {0}: {1}' -f $SelectedBackend, $SelectionReason)
    }
    $messageId = 'dispatch-finish-' + (Get-RaymanSharedSessionStableHash -Value (($RunId, $SelectedBackend, $SelectionReason, $ErrorMessage, $Success.ToString()) -join '|')).Substring(0, 24)
    $null = Add-RaymanSharedSessionMessage -WorkspaceRoot $WorkspaceRoot -SessionId $SessionId -Role assistant -ContentText $summaryText -ResumeText $summaryText -RecapText $summaryText -AuthorKind 'rayman' -AuthorName 'Rayman Dispatch' -SourceKind 'dispatch_finish' -Metadata @{ run_id = $RunId; success = $Success; selected_backend = $SelectedBackend; selection_reason = $SelectionReason } -MessageId $messageId

    if ($null -ne $TempCheckpoint -and $TempCheckpoint.PSObject.Properties['session_slug'] -and -not [string]::IsNullOrWhiteSpace([string]$TempCheckpoint.session_slug)) {
        $paths = Get-RaymanSessionPaths -WorkspaceRoot $WorkspaceRoot -Slug ([string]$TempCheckpoint.session_slug)
        $null = Save-RaymanSharedSessionCheckpoint -WorkspaceRoot $WorkspaceRoot -SessionId $SessionId -CheckpointKind 'dispatch-turn' -SessionSlug ([string]$TempCheckpoint.session_slug) -SessionKind ([string]$(if ($TempCheckpoint.PSObject.Properties['session_kind']) { $TempCheckpoint.session_kind } else { 'auto_temp' })) -HandoverPath ([string]$paths.handover_path) -PatchPath ([string]$paths.auto_save_patch_path) -MetaPath ([string]$paths.auto_save_meta_path) -SummaryText $summaryText -Metadata @{ run_id = $RunId; selected_backend = $SelectedBackend }
    }

    $exitResult = Exit-RaymanSharedSessionLock -WorkspaceRoot $WorkspaceRoot -SessionId $SessionId -OwnerId $OwnerId
    if ($null -ne $exitResult -and [bool]$exitResult.released -and (Get-Command Write-RaymanEvent -ErrorAction SilentlyContinue)) {
        Write-RaymanEvent -WorkspaceRoot $WorkspaceRoot -EventType 'shared_session.unlocked' -Category 'dispatch' -Payload ([ordered]@{
                session_id = $SessionId
                owner_id = $OwnerId
                run_id = $RunId
            }) | Out-Null
    }
    return $exitResult
}
