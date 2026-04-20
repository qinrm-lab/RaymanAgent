param(
    [string]$WorkspaceRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..\..\..') | Select-Object -ExpandProperty Path),
    [ValidateSet('status', 'list', 'show', 'sync', 'continue', 'link', 'unlink')][string]$Action = 'status',
    [string]$Name = '',
    [string]$Task = '',
    [string]$SessionId = '',
    [string]$Prompt = '',
    [string]$Vendor = '',
    [string]$VendorSessionId = '',
    [string]$ContinuityMode = '',
    [switch]$NativeResumeSupported,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'shared_session_common.ps1')

function Resolve-RaymanSharedSessionTargetId {
    param(
        [string]$WorkspaceRoot,
        [string]$SessionId,
        [string]$Name,
        [string]$Task
    )

    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        return [string]$SessionId
    }

    $slug = Resolve-RaymanSharedSessionSlug -Name $Name -Task $Task
    return (Get-RaymanSharedSessionId -WorkspaceRoot $WorkspaceRoot -TaskSlug $slug)
}

function Format-RaymanSharedSessionListText {
    param([object[]]$Sessions = @())

    if (@($Sessions).Count -le 0) {
        return 'No shared sessions found.'
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Shared sessions:') | Out-Null
    foreach ($session in @($Sessions)) {
        $lines.Add(('- {0} | name={1} | status={2} | updated={3}' -f [string]$session.session_id, [string]$session.display_name, [string]$session.status, [string]$session.updated_at)) | Out-Null
    }
    return (($lines.ToArray()) -join [Environment]::NewLine)
}

function Format-RaymanSharedSessionShowText {
    param([object]$ShowResult)

    if ($null -eq $ShowResult) {
        return 'No shared session data.'
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $session = $ShowResult.session
    $lines.Add(('session_id={0}' -f [string]$session.session_id)) | Out-Null
    $lines.Add(('name={0}' -f [string]$session.display_name)) | Out-Null
    $lines.Add(('status={0}' -f [string]$session.status)) | Out-Null
    if (-not [string]::IsNullOrWhiteSpace([string]$session.summary_text)) {
        $lines.Add(('summary={0}' -f [string]$session.summary_text)) | Out-Null
    }
    if (@($ShowResult.links).Count -gt 0) {
        $lines.Add('links:') | Out-Null
        foreach ($link in @($ShowResult.links)) {
            $lines.Add(('- {0}:{1} mode={2} native={3}' -f [string]$link.vendor_name, [string]$link.vendor_session_id, [string]$link.continuity_mode, [string]([bool]$link.native_resume_supported).ToString().ToLowerInvariant())) | Out-Null
        }
    }
    if (@($ShowResult.checkpoints).Count -gt 0) {
        $lines.Add('checkpoints:') | Out-Null
        foreach ($checkpoint in @($ShowResult.checkpoints | Select-Object -First 5)) {
            $lines.Add(('- {0} | kind={1} | status={2}' -f [string]$checkpoint.checkpoint_id, [string]$checkpoint.checkpoint_kind, [string]$checkpoint.status)) | Out-Null
        }
    }
    if (@($ShowResult.messages).Count -gt 0) {
        $lines.Add('recent_messages:') | Out-Null
        foreach ($message in @($ShowResult.messages | Select-Object -Last 8)) {
            $text = if (-not [string]::IsNullOrWhiteSpace([string]$message.resume_text)) { [string]$message.resume_text } else { [string]$message.content_text }
            if ($text.Length -gt 180) {
                $text = $text.Substring(0, 180) + '...'
            }
            $lines.Add(('- [{0}] {1}' -f [string]$message.role, $text)) | Out-Null
        }
    }

    return (($lines.ToArray()) -join [Environment]::NewLine)
}

$resolvedWorkspaceRoot = Get-RaymanSharedSessionWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
$config = Get-RaymanSharedSessionConfig -WorkspaceRoot $resolvedWorkspaceRoot

switch ($Action) {
    'status' {
        $result = Get-RaymanSharedSessionStatus -WorkspaceRoot $resolvedWorkspaceRoot
        if ($Json) {
            $result | ConvertTo-Json -Depth 12
            exit 0
        }

        Write-Host ('shared-session enabled={0} scope={1} copilot={2} db={3}' -f [string]([bool]$config.enabled).ToString().ToLowerInvariant(), [string]$config.scope, [string]$config.copilot_mode, [string]$result.db_path)
        Write-Host ('counts: sessions={0} messages={1} links={2} checkpoints={3} locks={4}' -f [int]$result.counts.shared_sessions, [int]$result.counts.shared_session_messages, [int]$result.counts.shared_session_links, [int]$result.counts.shared_session_checkpoints, [int]$result.counts.shared_session_locks)
        break
    }
    'list' {
        $result = Get-RaymanSharedSessionList -WorkspaceRoot $resolvedWorkspaceRoot
        if ($Json) {
            $result | ConvertTo-Json -Depth 12
            exit 0
        }
        Write-Host (Format-RaymanSharedSessionListText -Sessions @($result.sessions))
        break
    }
    'show' {
        $targetId = Resolve-RaymanSharedSessionTargetId -WorkspaceRoot $resolvedWorkspaceRoot -SessionId $SessionId -Name $Name -Task $Task
        $result = Get-RaymanSharedSessionShow -WorkspaceRoot $resolvedWorkspaceRoot -SessionId $targetId -MessageLimit 120
        if ($Json) {
            $result | ConvertTo-Json -Depth 16
            exit 0
        }
        Write-Host (Format-RaymanSharedSessionShowText -ShowResult $result)
        break
    }
    'sync' {
        $slug = Resolve-RaymanSharedSessionSlug -Name $Name -Task $Task
        $ensured = Ensure-RaymanSharedSession -WorkspaceRoot $resolvedWorkspaceRoot -TaskSlug $slug -DisplayName $(if (-not [string]::IsNullOrWhiteSpace($Name)) { [string]$Name } elseif (-not [string]::IsNullOrWhiteSpace($Task)) { [string]$Task } else { $slug }) -Status 'active' -SummaryText $Task -ResumeSummaryText $Task -RecapText $Task -IgnoreDisabled
        $targetId = [string]$ensured.session.session_id
        $linked = @(Sync-RaymanSharedSessionAdapters -WorkspaceRoot $resolvedWorkspaceRoot -SessionId $targetId)
        $show = Get-RaymanSharedSessionShow -WorkspaceRoot $resolvedWorkspaceRoot -SessionId $targetId -MessageLimit 80
        $result = [ordered]@{
            schema = 'rayman.shared_session_sync.v1'
            success = $true
            session_id = $targetId
            linked_count = $linked.Count
            linked = $linked
            session = $show.session
            links = $show.links
        }
        if ($Json) {
            $result | ConvertTo-Json -Depth 16
            exit 0
        }
        Write-Host ('shared-session synced: {0}' -f $targetId) -ForegroundColor Green
        if ($linked.Count -gt 0) {
            foreach ($item in $linked) {
                Write-Host ('  linked {0}:{1}' -f [string]$item.vendor_name, [string]$item.vendor_session_id) -ForegroundColor DarkCyan
            }
        } else {
            Write-Host '  no vendor sessions discovered.' -ForegroundColor Yellow
        }
        break
    }
    'continue' {
        $slug = Resolve-RaymanSharedSessionSlug -Name $Name -Task $Task
        $summaryText = @([string]$Prompt, [string]$Task) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
        $ensured = Ensure-RaymanSharedSession -WorkspaceRoot $resolvedWorkspaceRoot -TaskSlug $slug -DisplayName $(if (-not [string]::IsNullOrWhiteSpace($Name)) { [string]$Name } elseif (-not [string]::IsNullOrWhiteSpace($Task)) { [string]$Task } else { $slug }) -Status 'active' -SummaryText $summaryText -ResumeSummaryText $summaryText -RecapText $summaryText -IgnoreDisabled
        $targetId = [string]$ensured.session.session_id
        $lockOwnerId = ('shared-session:{0}' -f (Get-RaymanSharedSessionCurrentProcessId))
        $lock = Enter-RaymanSharedSessionLock -WorkspaceRoot $resolvedWorkspaceRoot -SessionId $targetId -OwnerId $lockOwnerId -OwnerLabel 'shared-session cli'
        if ($null -ne $lock -and -not [bool]$lock.acquired -and -not [string]::IsNullOrWhiteSpace([string]$Prompt)) {
            $null = Add-RaymanSharedSessionMessage -WorkspaceRoot $resolvedWorkspaceRoot -SessionId $targetId -Role user -ContentText $Prompt -ResumeText $Prompt -AuthorKind 'rayman' -AuthorName 'shared-session cli' -SourceKind 'continue_queued' -QueueState 'queued' -Metadata @{ action = 'continue' }
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$Prompt)) {
            $null = Add-RaymanSharedSessionMessage -WorkspaceRoot $resolvedWorkspaceRoot -SessionId $targetId -Role user -ContentText $Prompt -ResumeText $Prompt -AuthorKind 'rayman' -AuthorName 'shared-session cli' -SourceKind 'continue' -Metadata @{ action = 'continue' }
        }
        $context = Get-RaymanSharedSessionContinueContext -WorkspaceRoot $resolvedWorkspaceRoot -SessionId $targetId -MessageLimit 120
        if ($null -ne $lock -and [bool]$lock.acquired) {
            $null = Exit-RaymanSharedSessionLock -WorkspaceRoot $resolvedWorkspaceRoot -SessionId $targetId -OwnerId $lockOwnerId
        }
        if ($Json) {
            $context | ConvertTo-Json -Depth 16
            exit 0
        }
        Write-Host (Format-RaymanSharedSessionShowText -ShowResult (Get-RaymanSharedSessionShow -WorkspaceRoot $resolvedWorkspaceRoot -SessionId $targetId -MessageLimit 40))
        break
    }
    'link' {
        $targetId = Resolve-RaymanSharedSessionTargetId -WorkspaceRoot $resolvedWorkspaceRoot -SessionId $SessionId -Name $Name -Task $Task
        if ([string]::IsNullOrWhiteSpace($Vendor) -or [string]::IsNullOrWhiteSpace($VendorSessionId)) {
            throw 'link requires -Vendor and -VendorSessionId'
        }
        $linkArgs = @{
            WorkspaceRoot = $resolvedWorkspaceRoot
            SessionId = $targetId
            VendorName = $Vendor
            VendorSessionId = $VendorSessionId
            AdapterKind = 'manual'
            ContinuityMode = $(if (-not [string]::IsNullOrWhiteSpace($ContinuityMode)) { $ContinuityMode } else { 'transcript_bridge' })
            State = @{ linked_from = 'manual' }
        }
        if ($NativeResumeSupported.IsPresent) {
            $linkArgs['NativeResumeSupported'] = $true
        }
        $result = Add-RaymanSharedSessionLink @linkArgs
        if ($Json) {
            $result | ConvertTo-Json -Depth 12
            exit 0
        }
        Write-Host ('linked {0}:{1} -> {2}' -f $Vendor, $VendorSessionId, $targetId) -ForegroundColor Green
        break
    }
    'unlink' {
        $targetId = Resolve-RaymanSharedSessionTargetId -WorkspaceRoot $resolvedWorkspaceRoot -SessionId $SessionId -Name $Name -Task $Task
        $result = Remove-RaymanSharedSessionLink -WorkspaceRoot $resolvedWorkspaceRoot -SessionId $targetId -VendorName $Vendor -VendorSessionId $VendorSessionId
        if ($Json) {
            $result | ConvertTo-Json -Depth 12
            exit 0
        }
        Write-Host ('removed {0} shared-session links from {1}' -f [int]$result.deleted, $targetId) -ForegroundColor Green
        break
    }
}
