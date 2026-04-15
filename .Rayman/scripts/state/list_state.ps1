param(
    [string]$WorkspaceRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..\..\..') | Select-Object -ExpandProperty Path),
    [switch]$All,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'session_common.ps1')

$resolvedWorkspaceRootInput = if ($PSBoundParameters.ContainsKey('WorkspaceRoot')) { [string]$PSBoundParameters['WorkspaceRoot'] } else { $WorkspaceRoot }
$ResolvedWorkspaceRoot = Get-RaymanStateWorkspaceRoot -WorkspaceRoot $resolvedWorkspaceRootInput
$records = @(Get-RaymanSessionRecords -WorkspaceRoot $ResolvedWorkspaceRoot -All:$All)

$sessions = @($records | ForEach-Object {
        [ordered]@{
            name = [string]$_.name
            slug = [string]$_.slug
            status = [string]$_.status
            isolation = [string]$_.isolation
            session_kind = [string]$_.session_kind
            backend = [string]$_.backend
            account_alias = [string]$_.account_alias
            owner_source = [string]$_.owner_source
            owner_token = [string]$_.owner_token
            owner_display = [string]$_.owner_display
            owner_key = [string]$_.owner_key
            owner_pid = [int]$_.owner_pid
            task_description = [string]$_.task_description
            last_command_completed_at = [string]$_.last_command_completed_at
            last_command_duration_ms = [int]$_.last_command_duration_ms
            updated_at = [string]$_.updated_at
            has_stash = [bool]$_.has_stash
            has_worktree = [bool]$_.has_worktree
            worktree_path = [string]$_.worktree_path
            branch = [string]$_.branch
        }
    })

if ($Json) {
    [ordered]@{
        schema = 'rayman.state.list.v1'
        workspace_root = $ResolvedWorkspaceRoot
        count = $sessions.Count
        sessions = $sessions
    } | ConvertTo-Json -Depth 8
    exit 0
}

Write-Host (Format-RaymanSessionListText -Records $records)
