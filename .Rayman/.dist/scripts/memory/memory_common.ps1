Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RaymanMemoryPaths {
    param([string]$WorkspaceRoot)

    $resolvedRoot = if (Get-Command Resolve-RaymanWorkspaceRoot -ErrorAction SilentlyContinue) {
        Resolve-RaymanWorkspaceRoot -StartPath $WorkspaceRoot
    } else {
        (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    }
    $memoryRoot = Join-Path $resolvedRoot '.Rayman\state\memory'
    $runtimeRoot = Join-Path $resolvedRoot '.Rayman\runtime\memory'
    $pendingRoot = Join-Path $runtimeRoot 'pending'

    return [pscustomobject]@{
        WorkspaceRoot = $resolvedRoot
        MemoryRoot = $memoryRoot
        RuntimeRoot = $runtimeRoot
        DatabasePath = Join-Path $memoryRoot 'memory.sqlite3'
        StatusPath = Join-Path $runtimeRoot 'status.json'
        PendingRoot = $pendingRoot
        ManageScript = Join-Path $resolvedRoot '.Rayman\scripts\memory\manage_memory.ps1'
        BootstrapScript = Join-Path $resolvedRoot '.Rayman\scripts\memory\memory_bootstrap.ps1'
    }
}

function Ensure-RaymanMemoryDir([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Get-RaymanMemoryStableHash {
    param([string]$Value)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-RaymanMemoryTaskKey {
    param(
        [string]$TaskKind,
        [string]$Task,
        [string]$PromptKey = '',
        [string]$Command = '',
        [string]$WorkspaceRoot = ''
    )

    $normalizedKind = ([string]$TaskKind).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalizedKind)) {
        $normalizedKind = 'general'
    }
    $parts = @(
        $normalizedKind,
        ([string]$Task).Trim(),
        ([string]$PromptKey).Trim(),
        ([string]$Command).Trim(),
        ([string]$WorkspaceRoot).Trim()
    )
    $material = ($parts -join '|')
    $hash = Get-RaymanMemoryStableHash -Value $material
    return ("{0}/{1}" -f $normalizedKind, $hash.Substring(0, 16))
}

function Invoke-RaymanMemoryAction {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [ValidateSet('status', 'record', 'summarize', 'search', 'prune')][string]$Action,
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
        [switch]$Quiet
    )

    $paths = Get-RaymanMemoryPaths -WorkspaceRoot $WorkspaceRoot
    if (-not (Test-Path -LiteralPath $paths.ManageScript -PathType Leaf)) {
        return $null
    }

    $args = @{
        Action = $Action
        WorkspaceRoot = $paths.WorkspaceRoot
        Json = $true
        Quiet = $Quiet
    }
    if (-not [string]::IsNullOrWhiteSpace($InputJsonFile)) { $args['InputJsonFile'] = $InputJsonFile }
    if (-not [string]::IsNullOrWhiteSpace($Query)) { $args['Query'] = $Query }
    if (-not [string]::IsNullOrWhiteSpace($TaskKey)) { $args['TaskKey'] = $TaskKey }
    if (-not [string]::IsNullOrWhiteSpace($TaskKind)) { $args['TaskKind'] = $TaskKind }
    if (-not [string]::IsNullOrWhiteSpace($Scope)) { $args['Scope'] = $Scope }
    if (-not [string]::IsNullOrWhiteSpace($Kind)) { $args['Kind'] = $Kind }
    if ($Tags.Count -gt 0) { $args['Tags'] = @($Tags) }
    if ($Limit -gt 0) { $args['Limit'] = $Limit }
    if ($RecentLimit -ge 0) { $args['RecentLimit'] = $RecentLimit }
    if ($MaxAgeDays -gt 0) { $args['MaxAgeDays'] = $MaxAgeDays }
    if ($KeepPerTask -gt 0) { $args['KeepPerTask'] = $KeepPerTask }
    if ($DrainPending) { $args['DrainPending'] = $true }
    if ($Prewarm) { $args['Prewarm'] = $true }

    $raw = & $paths.ManageScript @args 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    $text = ($raw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    try {
        return ($text | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Write-RaymanEpisodeMemory {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [string]$RunId,
        [string]$TaskKey,
        [string]$TaskKind,
        [string]$Stage,
        [int]$Round = 0,
        [Nullable[bool]]$Success = $null,
        [string]$ErrorKind = '',
        [Nullable[int]]$DurationMs = $null,
        [string[]]$SelectedTools = @(),
        [object]$DiffSummary = $null,
        [object[]]$ArtifactRefs = @(),
        [string]$SummaryText = '',
        [hashtable]$ExtraPayload = @{}
    )

    $paths = Get-RaymanMemoryPaths -WorkspaceRoot $WorkspaceRoot
    if (-not (Test-Path -LiteralPath $paths.ManageScript -PathType Leaf)) {
        return $null
    }

    Ensure-RaymanMemoryDir -Path $paths.RuntimeRoot
    $tmpDir = Join-Path $paths.RuntimeRoot 'tmp'
    Ensure-RaymanMemoryDir -Path $tmpDir
    $payloadPath = Join-Path $tmpDir ("episode.{0}.json" -f ([Guid]::NewGuid().ToString('n')))

    $payload = [ordered]@{
        run_id = $RunId
        task_key = $TaskKey
        task_kind = $TaskKind
        stage = $Stage
        round = $Round
        success = if ($null -eq $Success) { $null } else { [bool]$Success }
        error_kind = [string]$ErrorKind
        duration_ms = if ($null -eq $DurationMs) { $null } else { [int]$DurationMs }
        selected_tools = @($SelectedTools)
        diff_summary = $DiffSummary
        artifact_refs_json = @($ArtifactRefs)
        summary_text = [string]$SummaryText
    }
    foreach ($key in @($ExtraPayload.Keys)) {
        $payload[$key] = $ExtraPayload[$key]
    }

    try {
        $payload | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $payloadPath -Encoding UTF8
        return Invoke-RaymanMemoryAction -WorkspaceRoot $paths.WorkspaceRoot -Action 'record' -InputJsonFile $payloadPath -Quiet
    } finally {
        if (Test-Path -LiteralPath $payloadPath -PathType Leaf) {
            Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-RaymanMemoryPendingMarker {
    param(
        [string]$WorkspaceRoot,
        [string]$TaskKey,
        [string]$TaskKind,
        [string]$RunId,
        [string]$Reason = ''
    )

    $paths = Get-RaymanMemoryPaths -WorkspaceRoot $WorkspaceRoot
    Ensure-RaymanMemoryDir -Path $paths.PendingRoot
    $markerPath = Join-Path $paths.PendingRoot (([string]$TaskKey).Replace('/', '_') + '.json')
    [ordered]@{
        task_key = $TaskKey
        task_kind = $TaskKind
        run_id = $RunId
        reason = $Reason
        created_at = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $markerPath -Encoding UTF8
    return $markerPath
}

function Start-RaymanMemorySummarizer {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [string]$TaskKey,
        [string]$TaskKind,
        [string]$RunId
    )

    $paths = Get-RaymanMemoryPaths -WorkspaceRoot $WorkspaceRoot
    if (-not (Test-Path -LiteralPath $paths.ManageScript -PathType Leaf)) {
        return $false
    }

    $null = New-RaymanMemoryPendingMarker -WorkspaceRoot $paths.WorkspaceRoot -TaskKey $TaskKey -TaskKind $TaskKind -RunId $RunId -Reason 'background_summarize_requested'
    $launcher = Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $launcher) {
        return $false
    }

    try {
        $argList = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $paths.ManageScript,
            '-Action', 'summarize',
            '-WorkspaceRoot', $paths.WorkspaceRoot,
            '-TaskKey', $TaskKey,
            '-DrainPending',
            '-Json',
            '-Quiet'
        )
        if (-not [string]::IsNullOrWhiteSpace($RunId)) {
            $argList += @('-Query', $RunId)
        }
        Start-Process -FilePath $launcher.Source -ArgumentList $argList -WindowStyle Hidden | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Get-RaymanMemoryPromptPreamble {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [string]$TaskKind,
        [string]$Task,
        [string]$TaskKey = '',
        [string[]]$Tags = @()
    )

    $query = ([string]$Task).Trim()
    if ([string]::IsNullOrWhiteSpace($query)) {
        $query = [string]$TaskKind
    }
    $result = Invoke-RaymanMemoryAction -WorkspaceRoot $WorkspaceRoot -Action 'search' -Query $query -TaskKey $TaskKey -TaskKind $TaskKind -Tags $Tags -Limit 5 -RecentLimit 2 -Quiet
    if ($null -eq $result) { return '' }

    $hintLines = New-Object System.Collections.Generic.List[string]
    foreach ($hint in @($result.memory_hints)) {
        $content = [string]$hint.content
        if ([string]::IsNullOrWhiteSpace($content)) { continue }
        $hintLines.Add(("- [{0}] {1}" -f [string]$hint.kind, $content)) | Out-Null
    }

    $summaryLines = New-Object System.Collections.Generic.List[string]
    foreach ($summary in @($result.recent_task_summaries)) {
        $text = [string]$summary.summary_text
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $summaryLines.Add(("- [{0}] {1}" -f [string]$summary.outcome, $text)) | Out-Null
    }

    if ($hintLines.Count -eq 0 -and $summaryLines.Count -eq 0) {
        return ''
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('[RaymanAgentMemory]') | Out-Null
    $lines.Add(("search_backend={0}" -f [string]$result.search_backend)) | Out-Null
    if ($hintLines.Count -gt 0) {
        $lines.Add('memory_hints:') | Out-Null
        foreach ($line in $hintLines) {
            $lines.Add($line) | Out-Null
        }
    }
    if ($summaryLines.Count -gt 0) {
        $lines.Add('recent_summaries:') | Out-Null
        foreach ($line in $summaryLines) {
            $lines.Add($line) | Out-Null
        }
    }
    $lines.Add('[/RaymanAgentMemory]') | Out-Null
    return ($lines -join "`n")
}
