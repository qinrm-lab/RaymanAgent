$repeatErrorGuardPath = Join-Path $PSScriptRoot '..\utils\repeat_error_guard.ps1'
if (Test-Path -LiteralPath $repeatErrorGuardPath -PathType Leaf) {
    . $repeatErrorGuardPath -NoMain
}

function Write-RaymanUtf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Set-RaymanManagedTextBlock {
    param(
        [string]$Path,
        [string]$BeginMarker,
        [string]$EndMarker,
        [string[]]$Lines = @()
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'managed block path is required.'
    }
    if ([string]::IsNullOrWhiteSpace($BeginMarker) -or [string]::IsNullOrWhiteSpace($EndMarker)) {
        throw 'managed block markers are required.'
    }

    $existing = ''
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $existing = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    }
    if ($null -eq $existing) { $existing = '' }

    $newline = if ($existing -match "`r`n") { "`r`n" } else { "`n" }
    $blockLines = @([string]$BeginMarker)
    foreach ($line in @($Lines)) {
        $blockLines += [string]$line
    }
    $blockLines += [string]$EndMarker
    $blockText = (($blockLines -join $newline).TrimEnd("`r", "`n") + $newline)

    $updated = $existing
    $pattern = '(?s)' + [regex]::Escape($BeginMarker) + '.*?' + [regex]::Escape($EndMarker) + '\r?\n?'
    if ($updated -match $pattern) {
        $updated = [regex]::Replace($updated, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $blockText }, 1)
    } else {
        if (-not [string]::IsNullOrWhiteSpace($updated)) {
            if ($updated -notmatch "(\r?\n)$") {
                $updated += $newline
            }
            if ($updated -notmatch "(\r?\n){2}$") {
                $updated += $newline
            }
        }
        $updated += $blockText
    }

    if ($updated -eq $existing) {
        return [pscustomobject]@{
            changed = $false
            path = $Path
        }
    }

    Write-RaymanUtf8NoBom -Path $Path -Content $updated
    return [pscustomobject]@{
        changed = $true
        path = $Path
    }
}

if (-not (Get-Variable -Name 'RaymanCodexCompatibilityCache' -Scope Script -ErrorAction SilentlyContinue)) {
    $script:RaymanCodexCompatibilityCache = @{}
}

if (-not (Get-Variable -Name 'RaymanCodexLoginOverrideSupportCache' -Scope Script -ErrorAction SilentlyContinue)) {
    $script:RaymanCodexLoginOverrideSupportCache = @{}
}

function ConvertTo-RaymanStringKeyMap {
    param(
        [object]$InputObject
    )

    $map = [ordered]@{}
    if ($null -eq $InputObject) {
        return $map
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $map[[string]$key] = $InputObject[$key]
        }
        return $map
    }

    foreach ($prop in $InputObject.PSObject.Properties) {
        $map[[string]$prop.Name] = $prop.Value
    }
    return $map
}

function Get-RaymanMapValue {
    param(
        [object]$Map,
        [string]$Key,
        $Default = $null
    )

    if ($null -eq $Map -or [string]::IsNullOrWhiteSpace($Key)) {
        return $Default
    }

    if ($Map -is [System.Collections.IDictionary]) {
        if ($Map.Contains($Key)) {
            return $Map[$Key]
        }
        foreach ($candidateKey in $Map.Keys) {
            if ([string]$candidateKey -ieq $Key) {
                return $Map[$candidateKey]
            }
        }
        return $Default
    }

    $prop = $Map.PSObject.Properties[$Key]
    if ($null -ne $prop) {
        return $prop.Value
    }

    foreach ($candidateProp in $Map.PSObject.Properties) {
        if ([string]$candidateProp.Name -ieq $Key) {
            return $candidateProp.Value
        }
    }
    return $Default
}

function Get-RaymanUserHomePath {
    $userHome = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($userHome)) {
        $userHome = [string]$env:HOME
    }
    if ([string]::IsNullOrWhiteSpace($userHome)) {
        try {
            $userHome = [System.IO.Path]::GetFullPath('~')
        } catch {
            $userHome = ''
        }
    }
    return [string]$userHome
}

function Get-RaymanStateRoot {
    $override = [Environment]::GetEnvironmentVariable('RAYMAN_HOME')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        if ([System.IO.Path]::IsPathRooted($override)) {
            return [System.IO.Path]::GetFullPath($override)
        }

        $userHome = Get-RaymanUserHomePath
        if (-not [string]::IsNullOrWhiteSpace($userHome)) {
            return [System.IO.Path]::GetFullPath((Join-Path $userHome $override))
        }
        return [System.IO.Path]::GetFullPath($override)
    }

    $resolvedUserHome = Get-RaymanUserHomePath
    if ([string]::IsNullOrWhiteSpace($resolvedUserHome)) {
        throw 'Unable to resolve user home for Rayman state root.'
    }
    return (Join-Path $resolvedUserHome '.rayman')
}

function Get-RaymanCodexStateRoot {
    return (Join-Path (Get-RaymanStateRoot) 'codex')
}

function Get-RaymanCodexAccountsRoot {
    return (Join-Path (Get-RaymanCodexStateRoot) 'accounts')
}

function Test-RaymanCodexWindowsHost {
    try {
        if ($null -ne $PSVersionTable.PSObject.Properties['Platform']) {
            return ([string]$PSVersionTable.Platform -eq 'Win32NT')
        }
    } catch {}

    return ($env:OS -eq 'Windows_NT')
}

function Test-RaymanCodexDeviceAuthProcessCandidate {
    param(
        [object]$Process
    )

    if ($null -eq $Process) {
        return $false
    }

    $name = [string](Get-RaymanMapValue -Map $Process -Key 'Name' -Default (Get-RaymanMapValue -Map $Process -Key 'name' -Default ''))
    $commandLine = [string](Get-RaymanMapValue -Map $Process -Key 'CommandLine' -Default (Get-RaymanMapValue -Map $Process -Key 'command_line' -Default ''))
    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        return $false
    }

    if ($commandLine -notmatch '(?i)(?:^|\s)login\s+--device-auth(?:\s|$)') {
        return $false
    }

    if ($name -match '(?i)^codex(?:\.exe)?$') {
        return $true
    }

    return (
        $commandLine -match '(?i)(?:^|["''\s\\/])codex(?:\.exe|\.cmd|\.bat|\.ps1|\.js)?(?=["''\s]|$)' -or
        $commandLine -match '(?i)@openai[\\/]+codex[\\/]+bin[\\/]+codex\.js'
    )
}

function Get-RaymanCodexDeviceAuthProcesses {
    param(
        [switch]$IncludeAllUsers
    )

    if (-not (Test-RaymanCodexWindowsHost)) {
        return @()
    }

    $currentUser = [string]$env:USERNAME
    $currentDomain = [string]$env:USERDOMAIN
    $items = New-Object System.Collections.Generic.List[object]
    $candidates = New-Object System.Collections.Generic.List[object]
    $candidateProcessIds = @{}
    try {
        foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
            if (-not (Test-RaymanCodexDeviceAuthProcessCandidate -Process $process)) {
                continue
            }

            $processId = 0
            try {
                $processId = [int]$process.ProcessId
            } catch {
                $processId = 0
            }

            if ($processId -gt 0) {
                $candidateProcessIds[$processId] = $true
            }

            $candidates.Add($process) | Out-Null
        }
    } catch {
        return @()
    }

    foreach ($candidate in @($candidates.ToArray())) {
        $processId = 0
        try {
            $processId = [int]$candidate.ProcessId
        } catch {
            $processId = 0
        }

        $parentProcessId = 0
        try {
            $parentProcessId = [int]$candidate.ParentProcessId
        } catch {
            $parentProcessId = 0
        }

        if ($parentProcessId -gt 0 -and $candidateProcessIds.ContainsKey($parentProcessId)) {
            continue
        }

        $ownerUser = ''
        $ownerDomain = ''
        $ownerResolved = $false
        $ownerMatches = [bool]$IncludeAllUsers
        if (-not $IncludeAllUsers) {
            try {
                $owner = Invoke-CimMethod -InputObject $candidate -MethodName GetOwner -ErrorAction Stop
                if ([int]$owner.ReturnValue -eq 0) {
                    $ownerUser = [string]$owner.User
                    $ownerDomain = [string]$owner.Domain
                    $ownerResolved = $true
                    $ownerMatches = (
                        -not [string]::IsNullOrWhiteSpace($ownerUser) -and
                        $ownerUser -ieq $currentUser -and
                        (
                            [string]::IsNullOrWhiteSpace($currentDomain) -or
                            [string]::IsNullOrWhiteSpace($ownerDomain) -or
                            $ownerDomain -ieq $currentDomain
                        )
                    )
                }
            } catch {
                $ownerResolved = $false
                $ownerMatches = $false
            }
        }

        if (-not $ownerMatches) {
            continue
        }

        $createdAt = ''
        $ageSeconds = -1
        try {
            $creationValue = Get-RaymanMapValue -Map $candidate -Key 'CreationDate' -Default $null
            if ($null -ne $creationValue) {
                $created = if ($creationValue -is [datetime]) {
                    [datetime]$creationValue
                } else {
                    [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$creationValue)
                }
                $createdAt = $created.ToString('o')
                $ageSeconds = [int][Math]::Floor(((Get-Date).ToUniversalTime() - $created.ToUniversalTime()).TotalSeconds)
            }
        } catch {
            $createdAt = ''
            $ageSeconds = -1
        }

        $parentExists = $false
        if ($parentProcessId -gt 0) {
            try {
                $null = Get-Process -Id $parentProcessId -ErrorAction Stop
                $parentExists = $true
            } catch {
                $parentExists = $false
            }
        }

        $items.Add([pscustomobject]@{
                process_id = $processId
                parent_process_id = $parentProcessId
                parent_exists = $parentExists
                name = [string]$candidate.Name
                command_line = [string]$candidate.CommandLine
                owner_user = $ownerUser
                owner_domain = $ownerDomain
                owner_resolved = $ownerResolved
                created_at = $createdAt
                age_seconds = $ageSeconds
            }) | Out-Null
    }

    return @($items.ToArray())
}

function Get-RaymanCodexRegistryPath {
    return (Join-Path (Get-RaymanCodexStateRoot) 'registry.json')
}

function Get-RaymanCodexWorkspaceStateRoot {
    param(
        [string]$WorkspaceRoot = ''
    )

    $resolvedWorkspaceRoot = Resolve-RaymanCodexWorkspacePath -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace([string]$resolvedWorkspaceRoot)) {
        return ''
    }
    return (Join-Path $resolvedWorkspaceRoot '.Rayman\state\codex')
}

function Get-RaymanCodexLoginAttemptStatePath {
    param(
        [string]$WorkspaceRoot = ''
    )

    $stateRoot = Get-RaymanCodexWorkspaceStateRoot -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace([string]$stateRoot)) {
        return ''
    }
    return (Join-Path $stateRoot 'login_attempts.json')
}

function Get-RaymanCodexLoginReportPath {
    param(
        [string]$WorkspaceRoot = ''
    )

    $resolvedWorkspaceRoot = Resolve-RaymanCodexWorkspacePath -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace([string]$resolvedWorkspaceRoot)) {
        return ''
    }
    return (Join-Path $resolvedWorkspaceRoot '.Rayman\runtime\codex.login.last.json')
}

function Get-RaymanCodexLoginForegroundOnly {
    param(
        [string]$WorkspaceRoot = ''
    )

    return [bool](Get-RaymanWorkspaceEnvBool -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_CODEX_LOGIN_FOREGROUND_ONLY' -Default $true)
}

function Get-RaymanCodexLoginAllowHidden {
    param(
        [string]$WorkspaceRoot = ''
    )

    return [bool](Get-RaymanWorkspaceEnvBool -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_CODEX_LOGIN_ALLOW_HIDDEN' -Default $false)
}

function Get-RaymanCodexLoginSmokeCooldownMinutes {
    param(
        [string]$WorkspaceRoot = ''
    )

    $rawValue = [string](Get-RaymanWorkspaceEnvString -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_CODEX_LOGIN_SMOKE_COOLDOWN_MINUTES' -Default '30')
    $parsed = 0
    if ([int]::TryParse($rawValue, [ref]$parsed)) {
        if ($parsed -lt 1) { return 1 }
        if ($parsed -gt 1440) { return 1440 }
        return $parsed
    }
    return 30
}

function Get-RaymanCodexLoginSmokeMaxAttempts {
    param(
        [string]$WorkspaceRoot = ''
    )

    $rawValue = [string](Get-RaymanWorkspaceEnvString -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_CODEX_LOGIN_SMOKE_MAX_ATTEMPTS' -Default '1')
    $parsed = 0
    if ([int]::TryParse($rawValue, [ref]$parsed)) {
        if ($parsed -lt 1) { return 1 }
        if ($parsed -gt 10) { return 10 }
        return $parsed
    }
    return 1
}

function Get-RaymanCodexLoginPromptClassification {
    param(
        [AllowEmptyString()][string]$Text
    )

    if ([string]::IsNullOrWhiteSpace([string]$Text)) {
        return 'none'
    }

    $normalized = ([string]$Text).Trim().ToLowerInvariant()
    if ($normalized -match 'sandbox_private_desktop|private desktop|winsta0') {
        return 'sandbox_private_desktop'
    }
    if ($normalized -match 'hide_full_access_warning|full access warning|full-access warning|danger-full-access') {
        return 'sandbox_full_access_warning'
    }
    if ($normalized -match 'cannot interact|unable to interact|not interactive') {
        return 'non_interactive_prompt'
    }
    if ($normalized -match 'permission|approval') {
        return 'permission_prompt'
    }
    if ($normalized -match 'open this url|browser approval|device code|device-auth') {
        return 'browser_or_device_flow'
    }
    if ($normalized -match 'sandbox') {
        return 'sandbox_prompt'
    }
    return 'unknown'
}

function Get-RaymanCodexLoginAttemptState {
    param(
        [string]$WorkspaceRoot = ''
    )

    $path = Get-RaymanCodexLoginAttemptStatePath -WorkspaceRoot $WorkspaceRoot
    $state = [ordered]@{
        schema = 'rayman.codex.login_attempts.v1'
        generated_at = ''
        entries = [ordered]@{}
    }

    if ([string]::IsNullOrWhiteSpace([string]$path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]$state
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $state.generated_at = [string](Get-RaymanMapValue -Map $raw -Key 'generated_at' -Default '')
        $state.entries = ConvertTo-RaymanStringKeyMap -InputObject (Get-RaymanMapValue -Map $raw -Key 'entries' -Default $null)
    } catch {}

    return [pscustomobject]$state
}

function Save-RaymanCodexLoginAttemptState {
    param(
        [string]$WorkspaceRoot = '',
        [object]$State
    )

    $path = Get-RaymanCodexLoginAttemptStatePath -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace([string]$path)) {
        return ''
    }

    $stateRoot = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
    }

    $entryMap = ConvertTo-RaymanStringKeyMap -InputObject (Get-RaymanMapValue -Map $State -Key 'entries' -Default $null)
    $payload = [ordered]@{
        schema = 'rayman.codex.login_attempts.v1'
        generated_at = (Get-Date).ToString('o')
        entries = $entryMap
    }
    Write-RaymanUtf8NoBom -Path $path -Content (($payload | ConvertTo-Json -Depth 10).TrimEnd() + "`n")
    return $path
}

function Get-RaymanCodexLoginAttemptKey {
    param(
        [string]$WorkspaceRoot = '',
        [string]$Alias = '',
        [string]$Mode = ''
    )

    $normalizedAlias = Normalize-RaymanCodexAlias -Alias $Alias
    $normalizedMode = [string]$Mode
    if ([string]::IsNullOrWhiteSpace([string]$normalizedAlias) -or [string]::IsNullOrWhiteSpace([string]$normalizedMode)) {
        return ''
    }
    $workspaceKey = Get-RaymanCodexWorkspaceKey -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace([string]$workspaceKey)) {
        return ''
    }
    return ('{0}|{1}|{2}' -f $workspaceKey, $normalizedAlias.ToLowerInvariant(), $normalizedMode.Trim().ToLowerInvariant())
}

function Get-RaymanCodexLoginSmokeWindowSummary {
    param(
        [string]$WorkspaceRoot = '',
        [string]$Alias = '',
        [string]$Mode = ''
    )

    $cooldownMinutes = Get-RaymanCodexLoginSmokeCooldownMinutes -WorkspaceRoot $WorkspaceRoot
    $maxAttempts = Get-RaymanCodexLoginSmokeMaxAttempts -WorkspaceRoot $WorkspaceRoot
    $entryKey = Get-RaymanCodexLoginAttemptKey -WorkspaceRoot $WorkspaceRoot -Alias $Alias -Mode $Mode
    $state = Get-RaymanCodexLoginAttemptState -WorkspaceRoot $WorkspaceRoot
    $entry = if ([string]::IsNullOrWhiteSpace([string]$entryKey)) { $null } else { Get-RaymanMapValue -Map $state.entries -Key $entryKey -Default $null }
    $now = Get-Date

    $windowStartedAt = [string](Get-RaymanMapValue -Map $entry -Key 'window_started_at' -Default '')
    $lastAttemptAt = [string](Get-RaymanMapValue -Map $entry -Key 'last_attempt_at' -Default '')
    $attemptCount = [int](Get-RaymanMapValue -Map $entry -Key 'attempt_count' -Default 0)
    $nextAllowedAt = ''
    $throttled = $false

    if (-not [string]::IsNullOrWhiteSpace([string]$windowStartedAt)) {
        try {
            $windowStart = [datetimeoffset]::Parse($windowStartedAt)
            $windowEnd = $windowStart.AddMinutes($cooldownMinutes)
            if ($windowEnd -gt [datetimeoffset]$now) {
                $nextAllowedAt = $windowEnd.ToString('o')
                $throttled = ($attemptCount -ge $maxAttempts)
            } else {
                $attemptCount = 0
                $windowStartedAt = ''
                $lastAttemptAt = ''
            }
        } catch {
            $attemptCount = 0
            $windowStartedAt = ''
            $lastAttemptAt = ''
        }
    }

    return [pscustomobject]@{
        mode = ([string]$Mode).Trim().ToLowerInvariant()
        cooldown_minutes = $cooldownMinutes
        max_attempts = $maxAttempts
        attempt_count = $attemptCount
        last_attempt_at = $lastAttemptAt
        window_started_at = $windowStartedAt
        next_allowed_at = $nextAllowedAt
        throttled = $throttled
        allowed = (-not $throttled)
    }
}

function Register-RaymanCodexLoginSmokeAttempt {
    param(
        [string]$WorkspaceRoot = '',
        [string]$Alias = '',
        [string]$Mode = ''
    )

    $entryKey = Get-RaymanCodexLoginAttemptKey -WorkspaceRoot $WorkspaceRoot -Alias $Alias -Mode $Mode
    if ([string]::IsNullOrWhiteSpace([string]$entryKey)) {
        return $null
    }

    $state = Get-RaymanCodexLoginAttemptState -WorkspaceRoot $WorkspaceRoot
    $entryMap = ConvertTo-RaymanStringKeyMap -InputObject $state.entries
    $summary = Get-RaymanCodexLoginSmokeWindowSummary -WorkspaceRoot $WorkspaceRoot -Alias $Alias -Mode $Mode
    $nowText = (Get-Date).ToString('o')

    $attemptCount = [int]$summary.attempt_count + 1
    $windowStartedAt = if ([string]::IsNullOrWhiteSpace([string]$summary.window_started_at)) { $nowText } else { [string]$summary.window_started_at }
    $nextAllowedAt = ''
    try {
        $nextAllowedAt = ([datetimeoffset]::Parse($windowStartedAt).AddMinutes([int]$summary.cooldown_minutes)).ToString('o')
    } catch {
        $nextAllowedAt = ''
    }

    $entryMap[$entryKey] = [ordered]@{
        workspace_root = Resolve-RaymanCodexWorkspacePath -WorkspaceRoot $WorkspaceRoot
        alias = Normalize-RaymanCodexAlias -Alias $Alias
        mode = ([string]$Mode).Trim().ToLowerInvariant()
        window_started_at = $windowStartedAt
        last_attempt_at = $nowText
        attempt_count = $attemptCount
        cooldown_minutes = [int]$summary.cooldown_minutes
        max_attempts = [int]$summary.max_attempts
        next_allowed_at = $nextAllowedAt
    }
    $state.entries = $entryMap
    Save-RaymanCodexLoginAttemptState -WorkspaceRoot $WorkspaceRoot -State $state | Out-Null
    return (Get-RaymanCodexLoginSmokeWindowSummary -WorkspaceRoot $WorkspaceRoot -Alias $Alias -Mode $Mode)
}

function Get-RaymanCodexLoginSmokeAliasSummary {
    param(
        [string]$WorkspaceRoot = '',
        [string]$Alias = ''
    )

    $summaries = @(
        Get-RaymanCodexLoginSmokeWindowSummary -WorkspaceRoot $WorkspaceRoot -Alias $Alias -Mode 'web'
        Get-RaymanCodexLoginSmokeWindowSummary -WorkspaceRoot $WorkspaceRoot -Alias $Alias -Mode 'device'
    )
    $active = @($summaries | Where-Object { [bool]$_.throttled -and -not [string]::IsNullOrWhiteSpace([string]$_.next_allowed_at) } | Sort-Object next_allowed_at)
    if ($active.Count -eq 0) {
        return [pscustomobject]@{
            throttled = $false
            mode = ''
            next_allowed_at = ''
            cooldown_minutes = (Get-RaymanCodexLoginSmokeCooldownMinutes -WorkspaceRoot $WorkspaceRoot)
            max_attempts = (Get-RaymanCodexLoginSmokeMaxAttempts -WorkspaceRoot $WorkspaceRoot)
        }
    }
    $first = $active[0]
    return [pscustomobject]@{
        throttled = $true
        mode = [string]$first.mode
        next_allowed_at = [string]$first.next_allowed_at
        cooldown_minutes = [int]$first.cooldown_minutes
        max_attempts = [int]$first.max_attempts
    }
}

function Get-RaymanDefaultCodexHomePath {
    $raw = [Environment]::GetEnvironmentVariable('CODEX_HOME')
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        try {
            return [System.IO.Path]::GetFullPath($raw)
        } catch {
            return [string]$raw
        }
    }

    $userHome = Get-RaymanUserHomePath
    if ([string]::IsNullOrWhiteSpace($userHome)) {
        return ''
    }
    return (Join-Path $userHome '.codex')
}

function Get-RaymanCodexDesktopHomePath {
    $override = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_DESKTOP_HOME')
    if (-not [string]::IsNullOrWhiteSpace([string]$override)) {
        try {
            return [System.IO.Path]::GetFullPath([string]$override)
        } catch {
            return [string]$override
        }
    }

    $userHome = Get-RaymanUserHomePath
    if ([string]::IsNullOrWhiteSpace($userHome)) {
        return ''
    }

    return (Join-Path $userHome '.codex')
}

function Normalize-RaymanCodexAuthScope {
    param(
        [AllowEmptyString()][string]$Scope
    )

    if ([string]::IsNullOrWhiteSpace([string]$Scope)) {
        return ''
    }

    switch ($Scope.Trim().ToLowerInvariant()) {
        { $_ -in @('desktop', 'desktop_global', 'desktop-global', 'global', 'global_desktop', 'global-desktop') } { return 'desktop_global' }
        { $_ -in @('alias', 'alias_local', 'alias-local', 'local', 'account') } { return 'alias_local' }
        default { return '' }
    }
}

function Resolve-RaymanCodexAuthScopeForMode {
    param(
        [string]$WorkspaceRoot = '',
        [string]$Mode = '',
        [string]$ExistingScope = ''
    )

    $normalizedMode = Normalize-RaymanCodexAuthModeLast -Mode $Mode
    if ((Test-RaymanCodexWindowsHost) -and $normalizedMode -in @('web', 'yunyi')) {
        return 'desktop_global'
    }

    $normalizedExisting = Normalize-RaymanCodexAuthScope -Scope $ExistingScope
    if (-not [string]::IsNullOrWhiteSpace([string]$normalizedExisting)) {
        return $normalizedExisting
    }

    return 'alias_local'
}

function Get-RaymanCodexDesktopGlobalStatePath {
    $desktopHome = Get-RaymanCodexDesktopHomePath
    if ([string]::IsNullOrWhiteSpace([string]$desktopHome)) {
        return ''
    }

    return (Join-Path $desktopHome '.codex-global-state.json')
}

function Get-RaymanCodexDesktopGlobalStateSummary {
    $statePath = Get-RaymanCodexDesktopGlobalStatePath
    $summary = [ordered]@{
        path = $statePath
        present = $false
        parse_failed = $false
        codex_cloud_access = ''
    }

    if ([string]::IsNullOrWhiteSpace([string]$statePath) -or -not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return [pscustomobject]$summary
    }

    $summary.present = $true
    try {
        $raw = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $atomState = Get-RaymanMapValue -Map $raw -Key 'electron-persisted-atom-state' -Default $null
        $summary.codex_cloud_access = [string](Get-RaymanMapValue -Map $atomState -Key 'codexCloudAccess' -Default '')
    } catch {
        $summary.parse_failed = $true
    }

    return [pscustomobject]$summary
}

function Get-RaymanCodexConfigState {
    param(
        [string]$CodexHome = '',
        [string]$Alias = ''
    )

    $configPath = Get-RaymanCodexAccountConfigPath -CodexHome $CodexHome -Alias $Alias
    $state = [ordered]@{
        path = $configPath
        present = $false
        parse_failed = $false
        model_provider = ''
        custom_provider_sections = @()
        experimental_bearer_token_present = $false
        requires_openai_auth = $false
        base_url_present = $false
        base_url_value = ''
        yunyi_base_url = ''
        yunyi_name_present = $false
        conflict_detected = $false
        conflict_reason = ''
        preferred_mode = 'web'
    }

    if ([string]::IsNullOrWhiteSpace([string]$configPath) -or -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return [pscustomobject]$state
    }

    $state.present = $true
    $raw = ''
    try {
        $raw = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    } catch {
        $state.parse_failed = $true
        return [pscustomobject]$state
    }

    if ([string]::IsNullOrWhiteSpace([string]$raw)) {
        return [pscustomobject]$state
    }

    $conflictReasons = New-Object System.Collections.Generic.List[string]
    $rootModelProvider = ''
    $currentTable = ''
    foreach ($line in @([string]$raw -split "`r?`n")) {
        $text = [string]$line
        if ([string]::IsNullOrWhiteSpace([string]$text)) {
            continue
        }

        $tableMatch = [regex]::Match($text, '^\s*\[(?<table>[^\]\r\n]+)\]\s*(?:#.*)?$')
        if ($tableMatch.Success) {
            $currentTable = [string]$tableMatch.Groups['table'].Value
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$currentTable)) {
            continue
        }

        $providerMatch = [regex]::Match($text, '^\s*model_provider\s*=\s*"(?<name>[^"]+)"\s*(?:#.*)?$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($providerMatch.Success) {
            $rootModelProvider = [string]$providerMatch.Groups['name'].Value
            break
        }
    }

    $state.model_provider = [string]$rootModelProvider
    if (-not [string]::IsNullOrWhiteSpace([string]$state.model_provider)) {
        $conflictReasons.Add(('model_provider:{0}' -f [string]$state.model_provider)) | Out-Null
        switch ([string]$state.model_provider) {
            'yunyi' { $state.preferred_mode = 'yunyi' }
            default { $state.preferred_mode = 'api' }
        }
    }

    $providerSections = New-Object System.Collections.Generic.List[string]
    foreach ($match in @([regex]::Matches($raw, '(?ms)^\[model_providers\.(?<name>[^\]\r\n]+)\]\r?\n(?<body>.*?)(?=^\[|\z)'))) {
        $name = [string]$match.Groups['name'].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $providerSections.Add($name) | Out-Null
        $body = [string]$match.Groups['body'].Value
        if ($body -match '(?im)^\s*experimental_bearer_token\s*=') {
            $state.experimental_bearer_token_present = $true
        }
        if ($body -match '(?im)^\s*requires_openai_auth\s*=\s*true\b') {
            $state.requires_openai_auth = $true
        }
        $baseUrlMatch = [regex]::Match($body, '(?im)^\s*base_url\s*=\s*"(?<value>[^"]+)"')
        if ($baseUrlMatch.Success) {
            $state.base_url_present = $true
            $baseUrlValue = [string]$baseUrlMatch.Groups['value'].Value
            if ([string]::IsNullOrWhiteSpace([string]$state.base_url_value)) {
                $state.base_url_value = $baseUrlValue
            }
            if ([string]$name -eq 'yunyi') {
                $state.yunyi_base_url = $baseUrlValue
            }
        }
        $providerNameMatch = [regex]::Match($body, '(?im)^\s*name\s*=\s*"(?<value>[^"]+)"')
        if ($providerNameMatch.Success -and [string]$name -eq 'yunyi') {
            $state.yunyi_name_present = (-not [string]::IsNullOrWhiteSpace([string]$providerNameMatch.Groups['value'].Value))
        }
    }
    $state.custom_provider_sections = @($providerSections.ToArray())

    if (@($state.custom_provider_sections).Count -gt 0) {
        $conflictReasons.Add('custom_provider_section') | Out-Null
    }
    if ([bool]$state.experimental_bearer_token_present) {
        $conflictReasons.Add('experimental_bearer_token') | Out-Null
    }
    if ([bool]$state.requires_openai_auth) {
        $conflictReasons.Add('requires_openai_auth') | Out-Null
    }
    if ([bool]$state.base_url_present) {
        $conflictReasons.Add('base_url') | Out-Null
    }

    $state.conflict_detected = ($conflictReasons.Count -gt 0)
    $state.conflict_reason = ((@($conflictReasons.ToArray()) | Select-Object -Unique) -join ',')
    return [pscustomobject]$state
}

function Get-RaymanCodexDesktopApiActivationStatus {
    param(
        [string]$Mode = '',
        [object]$DesktopConfigState = $null,
        [object]$DesktopAuthSummary = $null,
        [object]$DesktopGlobalState = $null
    )

    $normalizedMode = Normalize-RaymanCodexAuthModeLast -Mode $Mode
    $status = [ordered]@{
        target_mode = $normalizedMode
        applicable = ($normalizedMode -in @('api', 'yunyi'))
        ready = $false
        reason = 'not_applicable'
        config_ready = $false
        config_reason = ''
        auth_ready = $false
        auth_reason = ''
        config_conflict = ''
        cloud_access = if ($null -ne $DesktopGlobalState) { [string](Get-RaymanMapValue -Map $DesktopGlobalState -Key 'codex_cloud_access' -Default '') } else { '' }
    }

    if (-not [bool]$status.applicable) {
        return [pscustomobject]$status
    }

    $configState = if ($null -eq $DesktopConfigState) { [pscustomobject]@{} } else { $DesktopConfigState }
    $authSummary = if ($null -eq $DesktopAuthSummary) { [pscustomobject]@{} } else { $DesktopAuthSummary }
    $status.auth_ready = (
        [bool](Get-RaymanMapValue -Map $authSummary -Key 'present' -Default $false) -and
        [string](Get-RaymanMapValue -Map $authSummary -Key 'auth_mode' -Default '') -eq 'apikey' -and
        [bool](Get-RaymanMapValue -Map $authSummary -Key 'openai_api_key_present' -Default $false)
    )
    if (-not [bool]$status.auth_ready) {
        if (-not [bool](Get-RaymanMapValue -Map $authSummary -Key 'present' -Default $false)) {
            $status.auth_reason = 'desktop_api_auth_missing'
        } elseif ([string](Get-RaymanMapValue -Map $authSummary -Key 'auth_mode' -Default '') -ne 'apikey') {
            $status.auth_reason = 'desktop_api_auth_unsynced'
        } elseif (-not [bool](Get-RaymanMapValue -Map $authSummary -Key 'openai_api_key_present' -Default $false)) {
            $status.auth_reason = 'desktop_api_auth_missing'
        } else {
            $status.auth_reason = 'desktop_api_auth_invalid'
        }
    }

    switch ($normalizedMode) {
        'api' {
            $status.config_ready = (-not [bool](Get-RaymanMapValue -Map $configState -Key 'conflict_detected' -Default $false))
            if ([bool]$status.config_ready) {
                $status.config_reason = 'config_ready'
            } elseif ([bool](Get-RaymanMapValue -Map $configState -Key 'parse_failed' -Default $false)) {
                $status.config_reason = 'desktop_config_parse_failed'
            } else {
                $status.config_reason = 'desktop_config_conflict'
                $status.config_conflict = [string](Get-RaymanMapValue -Map $configState -Key 'conflict_reason' -Default '')
            }
        }
        'yunyi' {
            $yunyiReady = (
                [string](Get-RaymanMapValue -Map $configState -Key 'model_provider' -Default '') -eq 'yunyi' -and
                [bool](Get-RaymanMapValue -Map $configState -Key 'yunyi_name_present' -Default $false) -and
                -not [string]::IsNullOrWhiteSpace([string](Get-RaymanMapValue -Map $configState -Key 'yunyi_base_url' -Default ''))
            )
            $status.config_ready = [bool]$yunyiReady
            if ([bool]$status.config_ready) {
                $status.config_reason = 'config_ready'
            } elseif ([bool](Get-RaymanMapValue -Map $configState -Key 'parse_failed' -Default $false)) {
                $status.config_reason = 'desktop_config_parse_failed'
            } elseif ([string](Get-RaymanMapValue -Map $configState -Key 'model_provider' -Default '') -ne 'yunyi') {
                $status.config_reason = 'config_not_yunyi'
            } elseif (-not [bool](Get-RaymanMapValue -Map $configState -Key 'yunyi_name_present' -Default $false)) {
                $status.config_reason = 'yunyi_name_missing'
            } else {
                $status.config_reason = 'yunyi_base_url_missing'
            }
        }
    }

    if ([bool]$status.auth_ready -and [bool]$status.config_ready -and [string]$status.cloud_access -eq 'disabled') {
        $status.ready = $true
        $status.reason = 'api_key_active'
        return [pscustomobject]$status
    }

    if ([string]$status.cloud_access -ne 'disabled') {
        $status.reason = 'desktop_cloud_access_enabled'
    } elseif (-not [bool]$status.auth_ready) {
        $status.reason = [string]$status.auth_reason
    } else {
        $status.reason = [string]$status.config_reason
    }

    return [pscustomobject]$status
}

function Get-RaymanCodexDesktopSessionsRoot {
    $desktopHome = Get-RaymanCodexDesktopHomePath
    if ([string]::IsNullOrWhiteSpace([string]$desktopHome)) {
        return ''
    }

    return (Join-Path $desktopHome 'sessions')
}

function Get-RaymanCodexDesktopTuiLogPath {
    $desktopHome = Get-RaymanCodexDesktopHomePath
    if ([string]::IsNullOrWhiteSpace([string]$desktopHome)) {
        return ''
    }

    return (Join-Path $desktopHome 'log\codex-tui.log')
}

function Get-RaymanCodexDesktopLoginLogPath {
    $desktopHome = Get-RaymanCodexDesktopHomePath
    if ([string]::IsNullOrWhiteSpace([string]$desktopHome)) {
        return ''
    }

    return (Join-Path $desktopHome 'log\codex-login.log')
}

function Get-RaymanCodexDesktopStatusCommand {
    return '/status'
}

function Get-RaymanCodexDesktopStatusValidationReportPath {
    param(
        [string]$WorkspaceRoot = ''
    )

    $resolvedWorkspaceRoot = Resolve-RaymanCodexWorkspacePath -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace([string]$resolvedWorkspaceRoot)) {
        return ''
    }

    return (Join-Path $resolvedWorkspaceRoot '.Rayman\runtime\codex.desktop.status.last.json')
}

function Get-RaymanCodexDesktopStatusQuotaPatterns {
    return @(
        'quota',
        'remaining',
        'rate limit',
        'rate-limit',
        'usage',
        'limit reset',
        'rpm',
        'tpm',
        '配额',
        '额度',
        '剩余',
        '限制'
    )
}

function Get-RaymanCodexDesktopBlockedThreadPatterns {
    return @(
        'answer \d+ questions to proceed',
        'question[s]? to proceed',
        'request_user_input',
        'acceptance criteria',
        '请选择',
        '需要回答',
        '需要先回答',
        '需要确认'
    )
}

function Test-RaymanCodexDesktopQuotaVisible {
    param(
        [AllowEmptyString()][string]$Text
    )

    if ([string]::IsNullOrWhiteSpace([string]$Text)) {
        return $false
    }

    foreach ($pattern in @(Get-RaymanCodexDesktopStatusQuotaPatterns)) {
        if ([string]$Text -match ('(?im){0}' -f $pattern)) {
            return $true
        }
    }

    return $false
}

function Test-RaymanCodexDesktopThreadBlockedText {
    param(
        [AllowEmptyString()][string]$Text
    )

    if ([string]::IsNullOrWhiteSpace([string]$Text)) {
        return $false
    }

    foreach ($pattern in @(Get-RaymanCodexDesktopBlockedThreadPatterns)) {
        if ([string]$Text -match ('(?im){0}' -f $pattern)) {
            return $true
        }
    }

    return $false
}

function Test-RaymanCodexDesktopSessionPayload {
    param([object]$Payload)

    if ($null -eq $Payload) {
        return $false
    }

    $originator = [string](Get-RaymanMapValue -Map $Payload -Key 'originator' -Default '')
    $source = [string](Get-RaymanMapValue -Map $Payload -Key 'source' -Default '')

    if ($originator -match '(?i)codex desktop|codex[_ -]?vscode') {
        return $true
    }

    if ($source -match '^(?i)vscode$') {
        return $true
    }

    return $false
}

function Get-RaymanCodexDesktopSessionMeta {
    param(
        [string]$SessionPath
    )

    $result = [ordered]@{
        valid = $false
        session_id = ''
        workspace_root = ''
        source = ''
        originator = ''
        session_path = $SessionPath
        last_write_at = ''
    }

    if ([string]::IsNullOrWhiteSpace([string]$SessionPath) -or -not (Test-Path -LiteralPath $SessionPath -PathType Leaf)) {
        return [pscustomobject]$result
    }

    $result.last_write_at = (Get-Item -LiteralPath $SessionPath).LastWriteTime.ToString('o')
    try {
        $firstLine = Get-Content -LiteralPath $SessionPath -TotalCount 1 -Encoding UTF8 | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace([string]$firstLine)) {
            return [pscustomobject]$result
        }

        $lineObj = $firstLine | ConvertFrom-Json -ErrorAction Stop
        if ([string](Get-RaymanMapValue -Map $lineObj -Key 'type' -Default '') -ne 'session_meta') {
            return [pscustomobject]$result
        }

        $payload = Get-RaymanMapValue -Map $lineObj -Key 'payload' -Default $null
        $originator = [string](Get-RaymanMapValue -Map $payload -Key 'originator' -Default '')
        $source = [string](Get-RaymanMapValue -Map $payload -Key 'source' -Default '')
        $workspaceRoot = [string](Get-RaymanMapValue -Map $payload -Key 'cwd' -Default '')
        if ([string]::IsNullOrWhiteSpace([string]$workspaceRoot)) {
            return [pscustomobject]$result
        }

        if (-not (Test-RaymanCodexDesktopSessionPayload -Payload $payload)) {
            return [pscustomobject]$result
        }

        $result.valid = $true
        $result.session_id = [string](Get-RaymanMapValue -Map $payload -Key 'id' -Default '')
        $result.workspace_root = $workspaceRoot
        $result.source = $source
        $result.originator = $originator
        return [pscustomobject]$result
    } catch {
        return [pscustomobject]$result
    }
}

function Get-RaymanCodexDesktopLatestWorkspaceSession {
    param(
        [string]$WorkspaceRoot = ''
    )

    $sessionsRoot = Get-RaymanCodexDesktopSessionsRoot
    $resolvedWorkspaceRoot = Resolve-RaymanCodexWorkspacePath -WorkspaceRoot $WorkspaceRoot
    $workspaceKey = Get-RaymanPathComparisonValue -PathValue $resolvedWorkspaceRoot
    if ([string]::IsNullOrWhiteSpace([string]$sessionsRoot) -or [string]::IsNullOrWhiteSpace([string]$workspaceKey) -or -not (Test-Path -LiteralPath $sessionsRoot -PathType Container)) {
        return [pscustomobject]@{
            available = $false
            session_id = ''
            session_path = ''
            workspace_root = $resolvedWorkspaceRoot
            last_write_at = ''
        }
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        $meta = Get-RaymanCodexDesktopSessionMeta -SessionPath ([string]$file.FullName)
        if (-not [bool]$meta.valid) {
            continue
        }

        if ((Get-RaymanPathComparisonValue -PathValue ([string]$meta.workspace_root)) -ne $workspaceKey) {
            continue
        }

        return [pscustomobject]@{
            available = $true
            session_id = [string]$meta.session_id
            session_path = [string]$meta.session_path
            workspace_root = [string]$meta.workspace_root
            last_write_at = [string]$meta.last_write_at
        }
    }

    return [pscustomobject]@{
        available = $false
        session_id = ''
        session_path = ''
        workspace_root = $resolvedWorkspaceRoot
        last_write_at = ''
    }
}

function Get-RaymanCodexDesktopSessionTailText {
    param(
        [string]$SessionPath,
        [int]$TailCount = 80
    )

    if ([string]::IsNullOrWhiteSpace([string]$SessionPath) -or -not (Test-Path -LiteralPath $SessionPath -PathType Leaf)) {
        return ''
    }

    try {
        return ((Get-Content -LiteralPath $SessionPath -Tail $TailCount -Encoding UTF8) -join [Environment]::NewLine)
    } catch {
        return ''
    }
}

function Get-RaymanCodexDesktopStructuredProbeText {
    param([object]$LineObject)

    if ($null -eq $LineObject) {
        return ''
    }

    $lineType = [string](Get-RaymanMapValue -Map $LineObject -Key 'type' -Default '')
    switch ($lineType) {
        'event_msg' {
            $payload = Get-RaymanMapValue -Map $LineObject -Key 'payload' -Default $null
            if ($null -eq $payload) {
                return ''
            }

            $payloadType = [string](Get-RaymanMapValue -Map $payload -Key 'type' -Default '')
            if ($payloadType -in @('status', 'error', 'warning')) {
                return [string](Get-RaymanMapValue -Map $payload -Key 'message' -Default '')
            }

            return ''
        }
        default {
            return ''
        }
    }
}

function Get-RaymanCodexDesktopSessionQuotaProbe {
    param([string]$SessionPath)

    $result = [ordered]@{
        text = ''
        matched_at = $null
        source = 'none'
        quota_visible = $false
    }

    if ([string]::IsNullOrWhiteSpace([string]$SessionPath) -or -not (Test-Path -LiteralPath $SessionPath -PathType Leaf)) {
        return [pscustomobject]$result
    }

    $parts = New-Object System.Collections.Generic.List[string]
    $latestMatchAt = $null
    $tailLines = @()
    try {
        $tailLines = @(Get-Content -LiteralPath $SessionPath -Tail 120 -Encoding UTF8 -ErrorAction SilentlyContinue)
    } catch {
        $tailLines = @()
    }

    foreach ($line in $tailLines) {
        $lineText = [string]$line
        if ([string]::IsNullOrWhiteSpace([string]$lineText)) {
            continue
        }

        $probeText = ''
        $lineTimestamp = $null
        try {
            $lineObject = $lineText | ConvertFrom-Json -ErrorAction Stop
            $probeText = [string](Get-RaymanCodexDesktopStructuredProbeText -LineObject $lineObject)
            $timestampText = [string](Get-RaymanMapValue -Map $lineObject -Key 'timestamp' -Default '')
            if (-not [string]::IsNullOrWhiteSpace([string]$timestampText)) {
                try {
                    $lineTimestamp = [datetime]::Parse($timestampText)
                } catch {
                    $lineTimestamp = $null
                }
            }
        } catch {
            continue
        }

        if ([string]::IsNullOrWhiteSpace([string]$probeText) -or -not (Test-RaymanCodexDesktopQuotaVisible -Text $probeText)) {
            continue
        }

        if ($null -ne $lineTimestamp -and ($null -eq $latestMatchAt -or [datetime]$lineTimestamp -gt [datetime]$latestMatchAt)) {
            $latestMatchAt = [datetime]$lineTimestamp
        }

        $parts.Add($probeText) | Out-Null
    }

    $result.text = (($parts.ToArray() | Select-Object -Unique) -join "`n").Trim()
    $result.matched_at = $latestMatchAt
    $result.source = if ($parts.Count -gt 0) { 'desktop_session_tail' } else { 'none' }
    $result.quota_visible = ($parts.Count -gt 0)
    return [pscustomobject]$result
}

function Normalize-RaymanCodexAlias {
    param(
        [string]$Alias
    )

    if ([string]::IsNullOrWhiteSpace($Alias)) {
        return ''
    }
    return ([string]$Alias).Trim()
}

function Get-RaymanCodexAliasKey {
    param(
        [string]$Alias
    )

    $normalized = Normalize-RaymanCodexAlias -Alias $Alias
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return ''
    }
    return $normalized.ToLowerInvariant()
}

function Get-RaymanCodexAccountHomePath {
    param(
        [string]$Alias
    )

    $normalized = Normalize-RaymanCodexAlias -Alias $Alias
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return ''
    }

    $safeAlias = ConvertTo-RaymanSafeNamespace -Value $normalized
    return (Join-Path (Get-RaymanCodexAccountsRoot) $safeAlias)
}

function Normalize-RaymanCodexAuthModeLast {
    param(
        [AllowEmptyString()][string]$Mode
    )

    if ([string]::IsNullOrWhiteSpace($Mode)) {
        return ''
    }

    switch ($Mode.Trim().ToLowerInvariant()) {
        { $_ -in @('device', 'device_auth', 'device-auth') } { return 'device' }
        { $_ -in @('api', 'api_key', 'api-key', 'apikey') } { return 'api' }
        { $_ -in @('yunyi', 'yunyi_api', 'yunyi-api') } { return 'yunyi' }
        { $_ -in @('web', 'chatgpt', 'default') } { return 'web' }
        default { return '' }
    }
}

function Normalize-RaymanCodexDetectedAuthMode {
    param(
        [AllowEmptyString()][string]$Mode
    )

    if ([string]::IsNullOrWhiteSpace($Mode)) {
        return 'unknown'
    }

    switch ($Mode.Trim().ToLowerInvariant()) {
        'chatgpt' { return 'chatgpt' }
        'apikey' { return 'apikey' }
        'env_apikey' { return 'env_apikey' }
        default { return 'unknown' }
    }
}

function New-RaymanCodexNativeSessionSummary {
    param(
        [string]$SessionIndexPath = ''
    )

    return [ordered]@{
        available = $false
        id = ''
        thread_name = ''
        updated_at = ''
        source = 'none'
        session_index_path = [string]$SessionIndexPath
    }
}

function ConvertTo-RaymanCodexNativeSessionSummary {
    param(
        [object]$InputObject,
        [string]$SessionIndexPath = ''
    )

    $summary = New-RaymanCodexNativeSessionSummary -SessionIndexPath $SessionIndexPath
    if ($null -eq $InputObject) {
        return [pscustomobject]$summary
    }

    $summary.available = [bool](Get-RaymanMapValue -Map $InputObject -Key 'available' -Default $false)
    $summary.id = [string](Get-RaymanMapValue -Map $InputObject -Key 'id' -Default '')
    $summary.thread_name = [string](Get-RaymanMapValue -Map $InputObject -Key 'thread_name' -Default '')
    $summary.updated_at = [string](Get-RaymanMapValue -Map $InputObject -Key 'updated_at' -Default '')
    $summary.source = [string](Get-RaymanMapValue -Map $InputObject -Key 'source' -Default $(if ($summary.available) { 'session_index_jsonl' } else { 'none' }))
    $summary.session_index_path = [string](Get-RaymanMapValue -Map $InputObject -Key 'session_index_path' -Default $SessionIndexPath)

    return [pscustomobject]$summary
}

function ConvertTo-RaymanCodexDesktopWorkspaceSessionSummary {
    param([object]$Session)

    $sessionPath = if ($null -ne $Session) { [string](Get-RaymanMapValue -Map $Session -Key 'session_path' -Default '') } else { '' }
    if ($null -eq $Session -or -not [bool](Get-RaymanMapValue -Map $Session -Key 'available' -Default $false)) {
        return (ConvertTo-RaymanCodexNativeSessionSummary -InputObject $null -SessionIndexPath $sessionPath)
    }

    return (ConvertTo-RaymanCodexNativeSessionSummary -InputObject ([ordered]@{
                available = $true
                id = [string](Get-RaymanMapValue -Map $Session -Key 'session_id' -Default '')
                thread_name = 'VSCode workspace session'
                updated_at = [string](Get-RaymanMapValue -Map $Session -Key 'last_write_at' -Default '')
                source = 'desktop_workspace_session'
                session_index_path = $sessionPath
            }) -SessionIndexPath $sessionPath)
}

function Get-RaymanCodexAuthFilePath {
    param(
        [string]$CodexHome = '',
        [string]$Alias = ''
    )

    $resolvedHome = [string]$CodexHome
    if ([string]::IsNullOrWhiteSpace($resolvedHome) -and -not [string]::IsNullOrWhiteSpace($Alias)) {
        $resolvedHome = Get-RaymanCodexAccountHomePath -Alias $Alias
    }
    if ([string]::IsNullOrWhiteSpace($resolvedHome)) {
        return ''
    }
    return (Join-Path $resolvedHome 'auth.json')
}

function Get-RaymanCodexAuthFileSummary {
    param(
        [string]$CodexHome = '',
        [string]$Alias = ''
    )

    $authPath = Get-RaymanCodexAuthFilePath -CodexHome $CodexHome -Alias $Alias
    $summary = [ordered]@{
        path = $authPath
        present = $false
        parse_failed = $false
        auth_mode = 'unknown'
        account_id = ''
        openai_api_key_present = $false
        hash = ''
    }

    if ([string]::IsNullOrWhiteSpace([string]$authPath) -or -not (Test-Path -LiteralPath $authPath -PathType Leaf)) {
        return [pscustomobject]$summary
    }

    $summary.present = $true
    try {
        $summary.hash = [string]((Get-FileHash -LiteralPath $authPath -Algorithm SHA256).Hash)
    } catch {}

    try {
        $authDoc = Get-Content -LiteralPath $authPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $summary.auth_mode = Normalize-RaymanCodexDetectedAuthMode -Mode ([string](Get-RaymanMapValue -Map $authDoc -Key 'auth_mode' -Default ''))
        $summary.openai_api_key_present = (-not [string]::IsNullOrWhiteSpace([string](Get-RaymanMapValue -Map $authDoc -Key 'OPENAI_API_KEY' -Default '')))

        $tokens = Get-RaymanMapValue -Map $authDoc -Key 'tokens' -Default $null
        $summary.account_id = [string](Get-RaymanMapValue -Map $tokens -Key 'account_id' -Default (Get-RaymanMapValue -Map $authDoc -Key 'account_id' -Default ''))
        if ($summary.auth_mode -eq 'unknown' -and [bool]$summary.openai_api_key_present) {
            $summary.auth_mode = 'apikey'
        }
    } catch {
        $summary.parse_failed = $true
    }

    return [pscustomobject]$summary
}

function Get-RaymanCodexSessionIndexPath {
    param(
        [string]$CodexHome = '',
        [string]$Alias = ''
    )

    $resolvedHome = [string]$CodexHome
    if ([string]::IsNullOrWhiteSpace($resolvedHome) -and -not [string]::IsNullOrWhiteSpace($Alias)) {
        $resolvedHome = Get-RaymanCodexAccountHomePath -Alias $Alias
    }
    if ([string]::IsNullOrWhiteSpace($resolvedHome)) {
        return ''
    }
    return (Join-Path $resolvedHome 'session_index.jsonl')
}

function Get-RaymanCodexAuthModeFromStatusText {
    param(
        [AllowEmptyString()][string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return 'unknown'
    }

    if ($Text -match '(?im)\bapi key\b') {
        return 'apikey'
    }
    if ($Text -match '(?im)\bchatgpt\b') {
        return 'chatgpt'
    }
    return 'unknown'
}

function Get-RaymanDotEnvString {
    param(
        [string]$WorkspaceRoot = '',
        [string]$Name = ''
    )

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot) -or [string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }

    $resolvedWorkspace = Resolve-RaymanLiteralPath -PathValue $WorkspaceRoot -AllowMissing
    if ([string]::IsNullOrWhiteSpace([string]$resolvedWorkspace)) {
        return ''
    }

    $dotEnvPath = Join-Path $resolvedWorkspace '.env'
    if (-not (Test-Path -LiteralPath $dotEnvPath -PathType Leaf)) {
        return ''
    }

    try {
        foreach ($line in @(Get-Content -LiteralPath $dotEnvPath -Encoding UTF8)) {
            $text = [string]$line
            if ([string]::IsNullOrWhiteSpace($text)) {
                continue
            }

            $trimmed = $text.Trim()
            if ($trimmed.StartsWith('#')) {
                continue
            }

            $match = [regex]::Match($trimmed, '^(?:export\s+)?(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?<value>.*)$')
            if (-not $match.Success) {
                continue
            }

            if ([string]$match.Groups['name'].Value -ine $Name) {
                continue
            }

            $rawValue = [string]$match.Groups['value'].Value
            if ([string]::IsNullOrWhiteSpace([string]$rawValue)) {
                return ''
            }

            $rawValue = $rawValue.Trim()
            if ([string]::IsNullOrWhiteSpace([string]$rawValue)) {
                return ''
            }

            if ($rawValue[0] -in @("'", '"')) {
                $quote = [string]$rawValue[0]
                $closingIndex = -1
                for ($index = 1; $index -lt $rawValue.Length; $index++) {
                    $candidate = [string]$rawValue[$index]
                    $escaped = ($index -gt 0 -and [string]$rawValue[$index - 1] -eq '\')
                    if ($candidate -eq $quote -and -not $escaped) {
                        $closingIndex = $index
                        break
                    }
                }

                if ($closingIndex -lt 1) {
                    return ''
                }

                return $rawValue.Substring(1, $closingIndex - 1)
            }

            $commentIndex = $rawValue.IndexOf(' #')
            if ($commentIndex -ge 0) {
                $rawValue = $rawValue.Substring(0, $commentIndex)
            }
            return $rawValue.Trim()
        }
    } catch {}

    return ''
}

function Get-RaymanCodexYunyiCanonicalConfigPath {
    $desktopHome = Get-RaymanCodexDesktopHomePath
    if ([string]::IsNullOrWhiteSpace([string]$desktopHome)) {
        return ''
    }
    return (Join-Path $desktopHome 'config.toml.yunyi')
}

function Get-RaymanCodexYunyiCanonicalAuthPath {
    $desktopHome = Get-RaymanCodexDesktopHomePath
    if ([string]::IsNullOrWhiteSpace([string]$desktopHome)) {
        return ''
    }
    return (Join-Path $desktopHome 'auth.json.yunyi')
}

function Get-RaymanCodexYunyiBackupRoot {
    $desktopHome = Get-RaymanCodexDesktopHomePath
    if ([string]::IsNullOrWhiteSpace([string]$desktopHome)) {
        return ''
    }
    return (Join-Path $desktopHome 'yunyi')
}

function Get-RaymanCodexYunyiBackupAuthPath {
    $backupRoot = Get-RaymanCodexYunyiBackupRoot
    if ([string]::IsNullOrWhiteSpace([string]$backupRoot)) {
        return ''
    }
    return (Join-Path $backupRoot 'auth.json.yunyi')
}

function Get-RaymanCodexWorkspaceYunyiLoginRoot {
    param(
        [string]$WorkspaceRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace([string]$WorkspaceRoot)) {
        return ''
    }

    try {
        $resolvedWorkspace = Resolve-RaymanCodexWorkspacePath -WorkspaceRoot $WorkspaceRoot
    } catch {
        $resolvedWorkspace = Resolve-RaymanLiteralPath -PathValue $WorkspaceRoot -AllowMissing
    }
    if ([string]::IsNullOrWhiteSpace([string]$resolvedWorkspace)) {
        return ''
    }
    return (Join-Path $resolvedWorkspace '.Rayman\login')
}

function Get-RaymanCodexWorkspaceYunyiCanonicalConfigPath {
    param(
        [string]$WorkspaceRoot = ''
    )

    $loginRoot = Get-RaymanCodexWorkspaceYunyiLoginRoot -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace([string]$loginRoot)) {
        return ''
    }
    return (Join-Path $loginRoot 'config.toml.yunyi')
}

function Get-RaymanCodexWorkspaceYunyiCanonicalAuthPath {
    param(
        [string]$WorkspaceRoot = ''
    )

    $loginRoot = Get-RaymanCodexWorkspaceYunyiLoginRoot -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace([string]$loginRoot)) {
        return ''
    }
    return (Join-Path $loginRoot 'auth.json.yunyi')
}

function Get-RaymanCodexWorkspaceYunyiBackupRoot {
    param(
        [string]$WorkspaceRoot = ''
    )

    $loginRoot = Get-RaymanCodexWorkspaceYunyiLoginRoot -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace([string]$loginRoot)) {
        return ''
    }
    return (Join-Path $loginRoot 'yunyi')
}

function Get-RaymanCodexWorkspaceYunyiBackupAuthPath {
    param(
        [string]$WorkspaceRoot = ''
    )

    $backupRoot = Get-RaymanCodexWorkspaceYunyiBackupRoot -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace([string]$backupRoot)) {
        return ''
    }
    return (Join-Path $backupRoot 'auth.json.yunyi')
}

function Get-RaymanCodexYunyiSortedTomlPathsFromRoot {
    param(
        [string]$Root
    )

    if ([string]::IsNullOrWhiteSpace([string]$Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
        return @()
    }

    try {
        $items = @(Get-ChildItem -LiteralPath $Root -Filter '*.toml' -File -ErrorAction Stop | Sort-Object `
            @{ Expression = { if ([string]$_.Name -ieq 'config.toml.yunyi') { 0 } else { 1 } } }, `
            @{ Expression = { [string]$_.Name } })
        return @($items | Select-Object -ExpandProperty FullName)
    } catch {
        return @()
    }
}

function Get-RaymanCodexYunyiBackupTomlPaths {
    return @(Get-RaymanCodexYunyiSortedTomlPathsFromRoot -Root (Get-RaymanCodexYunyiBackupRoot))
}

function Get-RaymanCodexWorkspaceYunyiBackupTomlPaths {
    param(
        [string]$WorkspaceRoot = ''
    )

    return @(Get-RaymanCodexYunyiSortedTomlPathsFromRoot -Root (Get-RaymanCodexWorkspaceYunyiBackupRoot -WorkspaceRoot $WorkspaceRoot))
}

function Test-RaymanCodexYunyiPlaceholderBaseUrl {
    param(
        [AllowEmptyString()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return $false
    }

    $trimmed = [string]$Value.Trim()
    return (
        $trimmed -match '(?i)\bexample\.(com|org|net)\b' -or
        $trimmed -match '(?i)your-provider' -or
        $trimmed -match '(?i)canonical\.yunyi\.example\.com' -or
        $trimmed -match '(?i)backup\.yunyi\.example\.com' -or
        $trimmed -match '(?i)api\.yunyi\.example\.com'
    )
}

function Test-RaymanCodexYunyiPlaceholderApiKey {
    param(
        [AllowEmptyString()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return $false
    }

    $trimmed = [string]$Value.Trim()
    return (
        $trimmed -match '(?i)^yy-demo-token-' -or
        $trimmed -match '(?i)^yy-canonical-token-' -or
        $trimmed -match '(?i)^yy-backup-auth-token-' -or
        $trimmed -match '(?i)^yy-backup-legacy-token-' -or
        $trimmed -match '(?i)^yy-legacy-token-' -or
        $trimmed -match '(?i)^demo-' -or
        $trimmed -match '(?i)^placeholder'
    )
}

function Get-RaymanCodexYunyiTomlState {
    param(
        [string]$Path
    )

    $state = [ordered]@{
        path = [string]$Path
        present = $false
        parse_failed = $false
        base_url = ''
        base_url_present = $false
        base_url_placeholder_detected = $false
        provider_name = ''
        provider_name_present = $false
        experimental_bearer_token = ''
        experimental_bearer_token_present = $false
        experimental_bearer_token_placeholder_detected = $false
        requires_openai_auth = $false
    }

    if ([string]::IsNullOrWhiteSpace([string]$Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]$state
    }

    $state.present = $true
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace([string]$raw)) {
            return [pscustomobject]$state
        }

        $providerMatch = [regex]::Match($raw, '(?ms)^\[model_providers\.yunyi\]\r?\n(?<body>.*?)(?=^\[|\z)')
        $body = if ($providerMatch.Success) { [string]$providerMatch.Groups['body'].Value } else { [string]$raw }

        $baseUrlMatch = [regex]::Match($body, '(?im)^\s*base_url\s*=\s*"(?<value>[^"]+)"')
        if ($baseUrlMatch.Success) {
            $state.base_url = [string]$baseUrlMatch.Groups['value'].Value
            $state.base_url_present = (-not [string]::IsNullOrWhiteSpace([string]$state.base_url))
            $state.base_url_placeholder_detected = (Test-RaymanCodexYunyiPlaceholderBaseUrl -Value ([string]$state.base_url))
        }
        $providerNameMatch = [regex]::Match($body, '(?im)^\s*name\s*=\s*"(?<value>[^"]+)"')
        if ($providerNameMatch.Success) {
            $state.provider_name = [string]$providerNameMatch.Groups['value'].Value
            $state.provider_name_present = (-not [string]::IsNullOrWhiteSpace([string]$state.provider_name))
        }

        $tokenMatch = [regex]::Match($body, '(?im)^\s*experimental_bearer_token\s*=\s*"(?<value>[^"]+)"')
        if ($tokenMatch.Success) {
            $state.experimental_bearer_token = [string]$tokenMatch.Groups['value'].Value
            $state.experimental_bearer_token_present = (-not [string]::IsNullOrWhiteSpace([string]$state.experimental_bearer_token))
            $state.experimental_bearer_token_placeholder_detected = (Test-RaymanCodexYunyiPlaceholderApiKey -Value ([string]$state.experimental_bearer_token))
        }

        $state.requires_openai_auth = ($body -match '(?im)^\s*requires_openai_auth\s*=\s*true\b')
    } catch {
        $state.parse_failed = $true
    }

    return [pscustomobject]$state
}

function Get-RaymanCodexYunyiAuthFileState {
    param(
        [string]$Path
    )

    $state = [ordered]@{
        path = [string]$Path
        present = $false
        parse_failed = $false
        available = $false
        value = ''
        auth_mode = 'unknown'
        placeholder_detected = $false
        reason = 'missing'
    }

    if ([string]::IsNullOrWhiteSpace([string]$Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]$state
    }

    $state.present = $true
    try {
        $authDoc = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $candidate = [string](Get-RaymanMapValue -Map $authDoc -Key 'OPENAI_API_KEY' -Default '')
        $trimmedCandidate = [string]$candidate.Trim()
        $state.auth_mode = Normalize-RaymanCodexDetectedAuthMode -Mode ([string](Get-RaymanMapValue -Map $authDoc -Key 'auth_mode' -Default ''))
        $valid = Test-RaymanCodexApiKeyCandidate -Value $trimmedCandidate -AllowCustomProviderToken:$true
        $state.placeholder_detected = (Test-RaymanCodexYunyiPlaceholderApiKey -Value $trimmedCandidate)
        $state.available = ($valid -and -not [bool]$state.placeholder_detected)
        $state.value = if ($valid) { $trimmedCandidate } else { '' }
        $state.reason = if ([bool]$state.placeholder_detected) { 'placeholder_value' } elseif ($valid) { 'valid' } elseif ([string]::IsNullOrWhiteSpace($trimmedCandidate)) { 'missing_OPENAI_API_KEY' } else { 'invalid_format' }
    } catch {
        $state.parse_failed = $true
        $state.reason = 'parse_failed'
    }

    return [pscustomobject]$state
}

function Get-RaymanCodexYunyiBaseUrlStateFromTomlPaths {
    param(
        [string[]]$Paths = @(),
        [string]$SourcePrefix = '',
        [string]$Reason = 'backup_toml'
    )

    foreach ($path in @($Paths)) {
        $state = Get-RaymanCodexYunyiTomlState -Path ([string]$path)
        if (-not [bool]$state.base_url_present -or [string]::IsNullOrWhiteSpace([string]$state.base_url) -or [bool]$state.base_url_placeholder_detected -or -not [bool]$state.provider_name_present) {
            continue
        }

        return [pscustomobject]@{
            present = $true
            available = $true
            value = [string]$state.base_url
            source = ('{0}:{1}' -f $SourcePrefix, [System.IO.Path]::GetFileName([string]$path))
            path = [string]$state.path
            reason = [string]$Reason
        }
    }

    return [pscustomobject]@{
        present = $false
        available = $false
        value = ''
        source = 'none'
        path = ''
        reason = 'missing'
    }
}

function Get-RaymanCodexYunyiApiKeyStateFromBackupSources {
    param(
        [string]$AuthJsonPath = '',
        [string[]]$TomlPaths = @(),
        [string]$AuthJsonSource = '',
        [string]$TomlSourcePrefix = '',
        [string]$AuthJsonReason = 'backup_auth_json',
        [string]$TomlReason = 'backup_toml_legacy_token'
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$AuthJsonPath)) {
        $authState = Get-RaymanCodexYunyiAuthFileState -Path $AuthJsonPath
        if ([bool]$authState.available -and -not [string]::IsNullOrWhiteSpace([string]$authState.value)) {
            return [pscustomobject]@{
                present = $true
                available = $true
                value = [string]$authState.value
                source = [string]$AuthJsonSource
                path = [string]$authState.path
                reason = [string]$AuthJsonReason
            }
        }
    }

    foreach ($path in @($TomlPaths)) {
        $state = Get-RaymanCodexYunyiTomlState -Path ([string]$path)
        if (
            -not [bool]$state.experimental_bearer_token_present -or
            [string]::IsNullOrWhiteSpace([string]$state.experimental_bearer_token) -or
            [bool]$state.experimental_bearer_token_placeholder_detected -or
            -not (Test-RaymanCodexApiKeyCandidate -Value ([string]$state.experimental_bearer_token) -AllowCustomProviderToken:$true)
        ) {
            continue
        }

        return [pscustomobject]@{
            present = $true
            available = $true
            value = [string]$state.experimental_bearer_token
            source = ('{0}:{1}#experimental_bearer_token' -f $TomlSourcePrefix, [System.IO.Path]::GetFileName([string]$path))
            path = [string]$state.path
            reason = [string]$TomlReason
        }
    }

    return [pscustomobject]@{
        present = $false
        available = $false
        value = ''
        source = 'none'
        path = ''
        reason = 'missing'
    }
}

function Get-RaymanCodexUserHomeYunyiBackupBaseUrlState {
    return (Get-RaymanCodexYunyiBaseUrlStateFromTomlPaths -Paths (Get-RaymanCodexYunyiBackupTomlPaths) -SourcePrefix 'user_home_backup' -Reason 'backup_toml')
}

function Get-RaymanCodexUserHomeYunyiBackupApiKeyState {
    return (Get-RaymanCodexYunyiApiKeyStateFromBackupSources `
        -AuthJsonPath (Get-RaymanCodexYunyiBackupAuthPath) `
        -TomlPaths (Get-RaymanCodexYunyiBackupTomlPaths) `
        -AuthJsonSource 'user_home_backup:auth.json.yunyi' `
        -TomlSourcePrefix 'user_home_backup' `
        -AuthJsonReason 'backup_auth_json' `
        -TomlReason 'backup_toml_legacy_token')
}

function Get-RaymanCodexWorkspaceYunyiBaseUrlState {
    param(
        [string]$WorkspaceRoot = ''
    )

    $canonicalPath = Get-RaymanCodexWorkspaceYunyiCanonicalConfigPath -WorkspaceRoot $WorkspaceRoot
    $canonicalState = Get-RaymanCodexYunyiTomlState -Path $canonicalPath
    if ([bool]$canonicalState.base_url_present -and -not [string]::IsNullOrWhiteSpace([string]$canonicalState.base_url) -and -not [bool]$canonicalState.base_url_placeholder_detected -and [bool]$canonicalState.provider_name_present) {
        return [pscustomobject]@{
            present = $true
            available = $true
            value = [string]$canonicalState.base_url
            source = 'workspace_login:config.toml.yunyi'
            path = [string]$canonicalState.path
            reason = 'workspace_login_canonical'
        }
    }

    $backupState = Get-RaymanCodexYunyiBaseUrlStateFromTomlPaths -Paths (Get-RaymanCodexWorkspaceYunyiBackupTomlPaths -WorkspaceRoot $WorkspaceRoot) -SourcePrefix 'workspace_login_backup' -Reason 'workspace_login_backup_toml'
    if ([bool]$backupState.available) {
        return $backupState
    }

    return [pscustomobject]@{
        present = ([bool]$canonicalState.present)
        available = $false
        value = ''
        source = 'none'
        path = ''
        reason = if ([bool]$canonicalState.base_url_placeholder_detected) { 'workspace_login_canonical_placeholder' } elseif ([bool]$canonicalState.present -and -not [bool]$canonicalState.provider_name_present) { 'workspace_login_canonical_name_missing' } elseif ([bool]$canonicalState.present) { 'workspace_login_canonical_missing_base_url' } else { 'missing' }
    }
}

function Get-RaymanCodexWorkspaceYunyiApiKeyState {
    param(
        [string]$WorkspaceRoot = ''
    )

    $canonicalAuthPath = Get-RaymanCodexWorkspaceYunyiCanonicalAuthPath -WorkspaceRoot $WorkspaceRoot
    $canonicalAuthState = Get-RaymanCodexYunyiAuthFileState -Path $canonicalAuthPath
    if ([bool]$canonicalAuthState.available -and -not [string]::IsNullOrWhiteSpace([string]$canonicalAuthState.value)) {
        return [pscustomobject]@{
            present = $true
            available = $true
            value = [string]$canonicalAuthState.value
            source = 'workspace_login:auth.json.yunyi'
            path = [string]$canonicalAuthState.path
            reason = 'workspace_login_canonical_auth_json'
        }
    }

    $backupState = Get-RaymanCodexYunyiApiKeyStateFromBackupSources `
        -AuthJsonPath (Get-RaymanCodexWorkspaceYunyiBackupAuthPath -WorkspaceRoot $WorkspaceRoot) `
        -TomlPaths (Get-RaymanCodexWorkspaceYunyiBackupTomlPaths -WorkspaceRoot $WorkspaceRoot) `
        -AuthJsonSource 'workspace_login_backup:auth.json.yunyi' `
        -TomlSourcePrefix 'workspace_login_backup' `
        -AuthJsonReason 'workspace_login_backup_auth_json' `
        -TomlReason 'workspace_login_backup_toml_legacy_token'
    if ([bool]$backupState.available) {
        return $backupState
    }

    $canonicalConfigPath = Get-RaymanCodexWorkspaceYunyiCanonicalConfigPath -WorkspaceRoot $WorkspaceRoot
    $canonicalConfigState = Get-RaymanCodexYunyiTomlState -Path $canonicalConfigPath
    if (
        [bool]$canonicalConfigState.experimental_bearer_token_present -and
        -not [bool]$canonicalConfigState.experimental_bearer_token_placeholder_detected -and
        -not [string]::IsNullOrWhiteSpace([string]$canonicalConfigState.experimental_bearer_token) -and
        (Test-RaymanCodexApiKeyCandidate -Value ([string]$canonicalConfigState.experimental_bearer_token) -AllowCustomProviderToken:$true)
    ) {
        return [pscustomobject]@{
            present = $true
            available = $true
            value = [string]$canonicalConfigState.experimental_bearer_token
            source = 'workspace_login:config.toml.yunyi#experimental_bearer_token'
            path = [string]$canonicalConfigState.path
            reason = 'workspace_login_canonical_toml_legacy_token'
        }
    }

    return [pscustomobject]@{
        present = ([bool]$canonicalAuthState.present -or [bool]$canonicalConfigState.present)
        available = $false
        value = ''
        source = 'none'
        path = ''
        reason = if ([bool]$canonicalAuthState.placeholder_detected) { 'workspace_login_canonical_placeholder' } else { 'missing' }
    }
}

function Get-RaymanCodexUserHomeYunyiBaseUrlState {
    $canonicalPath = Get-RaymanCodexYunyiCanonicalConfigPath
    $canonicalState = Get-RaymanCodexYunyiTomlState -Path $canonicalPath
    if ([bool]$canonicalState.base_url_present -and -not [string]::IsNullOrWhiteSpace([string]$canonicalState.base_url) -and -not [bool]$canonicalState.base_url_placeholder_detected -and [bool]$canonicalState.provider_name_present) {
        return [pscustomobject]@{
            present = $true
            available = $true
            value = [string]$canonicalState.base_url
            source = 'user_home:config.toml.yunyi'
            path = [string]$canonicalState.path
            reason = 'canonical_config'
        }
    }

    $backupState = Get-RaymanCodexUserHomeYunyiBackupBaseUrlState
    if ([bool]$backupState.available) {
        return $backupState
    }

    return [pscustomobject]@{
        present = ([bool]$canonicalState.present)
        available = $false
        value = ''
        source = 'none'
        path = ''
        reason = if ([bool]$canonicalState.base_url_placeholder_detected) { 'canonical_config_placeholder' } elseif ([bool]$canonicalState.present -and -not [bool]$canonicalState.provider_name_present) { 'canonical_config_name_missing' } elseif ([bool]$canonicalState.present) { 'canonical_config_missing_base_url' } else { 'missing' }
    }
}

function Get-RaymanCodexUserHomeYunyiApiKeyState {
    $canonicalAuthPath = Get-RaymanCodexYunyiCanonicalAuthPath
    $canonicalAuthState = Get-RaymanCodexYunyiAuthFileState -Path $canonicalAuthPath
    if ([bool]$canonicalAuthState.available -and -not [string]::IsNullOrWhiteSpace([string]$canonicalAuthState.value)) {
        return [pscustomobject]@{
            present = $true
            available = $true
            value = [string]$canonicalAuthState.value
            source = 'user_home:auth.json.yunyi'
            path = [string]$canonicalAuthState.path
            reason = 'canonical_auth_json'
        }
    }

    $backupState = Get-RaymanCodexUserHomeYunyiBackupApiKeyState
    if ([bool]$backupState.available) {
        return $backupState
    }

    $canonicalConfigPath = Get-RaymanCodexYunyiCanonicalConfigPath
    $canonicalConfigState = Get-RaymanCodexYunyiTomlState -Path $canonicalConfigPath
    if (
        [bool]$canonicalConfigState.experimental_bearer_token_present -and
        -not [bool]$canonicalConfigState.experimental_bearer_token_placeholder_detected
    ) {
        $candidate = [string]$canonicalConfigState.experimental_bearer_token
        if (Test-RaymanCodexApiKeyCandidate -Value $candidate -AllowCustomProviderToken:$true) {
            return [pscustomobject]@{
                present = $true
                available = $true
                value = [string]$candidate
                source = 'user_home:config.toml.yunyi#experimental_bearer_token'
                path = [string]$canonicalConfigState.path
                reason = 'canonical_toml_legacy_token'
            }
        }
    }

    return [pscustomobject]@{
        present = ([bool]$canonicalAuthState.present -or [bool]$canonicalConfigState.present)
        available = $false
        value = ''
        source = 'none'
        path = ''
        reason = if ([bool]$canonicalAuthState.placeholder_detected) { 'canonical_auth_placeholder' } elseif ([bool]$canonicalConfigState.experimental_bearer_token_placeholder_detected) { 'canonical_toml_placeholder' } else { 'missing' }
    }
}

function Set-RaymanCodexYunyiConfigFile {
    param(
        [string]$Path,
        [string]$BaseUrl
    )

    if ([string]::IsNullOrWhiteSpace([string]$Path)) {
        return [pscustomobject]@{
            success = $false
            path = ''
            base_url = ''
            reason = 'path_missing'
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$BaseUrl)) {
        return [pscustomobject]@{
            success = $false
            path = [string]$Path
            base_url = ''
            reason = 'base_url_missing'
        }
    }

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace([string]$directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $existingRaw = if (Test-Path -LiteralPath $Path -PathType Leaf) { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 } else { '' }
    $newline = if ([string]$existingRaw -match "`r`n") { "`r`n" } else { "`n" }

    $updatedRaw = [string]$existingRaw
    $updatedRaw = [regex]::Replace($updatedRaw, '(?ms)^# RAYMAN:YUNYI:BEGIN\r?\n.*?^# RAYMAN:YUNYI:END\r?\n?', '')
    $updatedRaw = [regex]::Replace($updatedRaw, '(?ms)^\[model_providers\.yunyi\]\r?\n.*?(?=^\[|\z)', '')
    $updatedRaw = [regex]::Replace($updatedRaw, '(?im)^\s*model_provider\s*=\s*"yunyi"\s*\r?\n?', '')
    $updatedRaw = [regex]::Replace($updatedRaw, '(\r?\n){3,}', ($newline + $newline))
    $updatedRaw = $updatedRaw.Trim()
    if ([string]::IsNullOrWhiteSpace([string]$updatedRaw)) {
        $updatedRaw = ''
    } else {
        $updatedRaw += $newline
    }

    if ($updatedRaw -ne $existingRaw) {
        Write-RaymanUtf8NoBom -Path $Path -Content $updatedRaw
    }

    Set-RaymanManagedTextBlock -Path $Path -BeginMarker '# RAYMAN:YUNYI:BEGIN' -EndMarker '# RAYMAN:YUNYI:END' -Lines @(
        '# Rayman-managed Yunyi provider settings.',
        'model_provider = "yunyi"',
        '',
        '[model_providers.yunyi]',
        'name = "yunyi"',
        ('base_url = "{0}"' -f ([string]$BaseUrl -replace '"', '\"')),
        'wire_api = "responses"'
    ) | Out-Null

    $summary = Get-RaymanCodexYunyiTomlState -Path $Path
    return [pscustomobject]@{
        success = [bool]$summary.base_url_present
        path = [string]$summary.path
        base_url = [string]$summary.base_url
        reason = if ([bool]$summary.base_url_present) { 'configured' } else { 'base_url_missing_after_write' }
    }
}

function Set-RaymanCodexYunyiProviderTemplateFile {
    param(
        [string]$Path,
        [string]$BaseUrl,
        [string]$ApiKey = ''
    )

    if ([string]::IsNullOrWhiteSpace([string]$Path)) {
        return [pscustomobject]@{
            success = $false
            path = ''
            reason = 'path_missing'
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$BaseUrl)) {
        return [pscustomobject]@{
            success = $false
            path = [string]$Path
            reason = 'base_url_missing'
        }
    }

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace([string]$directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('model_provider = "yunyi"') | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('[model_providers.yunyi]') | Out-Null
    $lines.Add('name = "yunyi"') | Out-Null
    $lines.Add(('base_url = "{0}"' -f ([string]$BaseUrl -replace '"', '\"'))) | Out-Null
    $lines.Add('wire_api = "responses"') | Out-Null
    if (-not [string]::IsNullOrWhiteSpace([string]$ApiKey)) {
        $lines.Add(('experimental_bearer_token = "{0}"' -f ([string]$ApiKey -replace '"', '\"'))) | Out-Null
        $lines.Add('requires_openai_auth = true') | Out-Null
    }

    Write-RaymanUtf8NoBom -Path $Path -Content ((($lines -join "`n").TrimEnd()) + "`n")
    $summary = Get-RaymanCodexYunyiTomlState -Path $Path
    return [pscustomobject]@{
        success = [bool]$summary.base_url_present
        path = [string]$summary.path
        reason = if ([bool]$summary.base_url_present) { 'configured' } else { 'base_url_missing_after_write' }
    }
}

function Set-RaymanCodexYunyiAuthFile {
    param(
        [string]$Path,
        [string]$ApiKey
    )

    if ([string]::IsNullOrWhiteSpace([string]$Path)) {
        return [pscustomobject]@{
            success = $false
            path = ''
            reason = 'path_missing'
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$ApiKey)) {
        return [pscustomobject]@{
            success = $false
            path = [string]$Path
            reason = 'api_key_missing'
        }
    }

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace([string]$directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $payload = [ordered]@{
        OPENAI_API_KEY = [string]$ApiKey
        auth_mode = 'apikey'
    }
    Write-RaymanUtf8NoBom -Path $Path -Content ((($payload | ConvertTo-Json -Depth 6).TrimEnd()) + "`n")
    $summary = Get-RaymanCodexYunyiAuthFileState -Path $Path
    return [pscustomobject]@{
        success = [bool]$summary.available
        path = [string]$summary.path
        reason = if ([bool]$summary.available) { 'configured' } else { [string]$summary.reason }
    }
}

function Get-RaymanCodexYunyiPreferredBackupTomlFileName {
    return 'config - api驿站.toml'
}

function Copy-RaymanCodexYunyiRawTomlBackup {
    param(
        [string]$SourcePath = '',
        [string]$DestinationRoot = '',
        [string]$BaseUrl = '',
        [string]$ApiKey = ''
    )

    if ([string]::IsNullOrWhiteSpace([string]$DestinationRoot)) {
        return [pscustomobject]@{
            success = $false
            path = ''
            reason = 'destination_root_missing'
        }
    }

    if (-not (Test-Path -LiteralPath $DestinationRoot -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null
    }

    $destinationPath = Join-Path $DestinationRoot $(if (-not [string]::IsNullOrWhiteSpace([string]$SourcePath)) { [System.IO.Path]::GetFileName([string]$SourcePath) } else { Get-RaymanCodexYunyiPreferredBackupTomlFileName })
    if (-not [string]::IsNullOrWhiteSpace([string]$SourcePath) -and (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        $resolvedSourcePath = Resolve-RaymanLiteralPath -PathValue $SourcePath -AllowMissing
        $resolvedDestinationPath = Resolve-RaymanLiteralPath -PathValue $destinationPath -AllowMissing
        if (
            -not [string]::IsNullOrWhiteSpace([string]$resolvedSourcePath) -and
            -not [string]::IsNullOrWhiteSpace([string]$resolvedDestinationPath) -and
            [string]$resolvedSourcePath -ieq [string]$resolvedDestinationPath
        ) {
            return [pscustomobject]@{
                success = $true
                path = $destinationPath
                reason = 'source_equals_destination'
            }
        }
        Copy-Item -LiteralPath $SourcePath -Destination $destinationPath -Force
        return [pscustomobject]@{
            success = $true
            path = $destinationPath
            reason = 'copied_source'
        }
    }

    $generated = Set-RaymanCodexYunyiProviderTemplateFile -Path $destinationPath -BaseUrl $BaseUrl -ApiKey $ApiKey
    return [pscustomobject]@{
        success = [bool]$generated.success
        path = [string]$generated.path
        reason = if ([bool]$generated.success) { 'generated_template' } else { [string]$generated.reason }
    }
}

function Sync-RaymanCodexUserHomeYunyiState {
    param(
        [string]$WorkspaceRoot = '',
        [string]$BaseUrl = '',
        [string]$ApiKey = '',
        [string]$BackupTomlSourcePath = ''
    )

    $configResult = $null
    $authResult = $null
    $backupAuthResult = $null
    $workspaceConfigResult = $null
    $workspaceAuthResult = $null
    $workspaceBackupAuthResult = $null
    $backupTomlResult = $null
    $workspaceBackupTomlResult = $null

    if (-not [string]::IsNullOrWhiteSpace([string]$BaseUrl)) {
        $configResult = Set-RaymanCodexYunyiConfigFile -Path (Get-RaymanCodexYunyiCanonicalConfigPath) -BaseUrl $BaseUrl
        if (-not [string]::IsNullOrWhiteSpace([string]$WorkspaceRoot)) {
            $workspaceConfigResult = Set-RaymanCodexYunyiConfigFile -Path (Get-RaymanCodexWorkspaceYunyiCanonicalConfigPath -WorkspaceRoot $WorkspaceRoot) -BaseUrl $BaseUrl
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$ApiKey)) {
        $authResult = Set-RaymanCodexYunyiAuthFile -Path (Get-RaymanCodexYunyiCanonicalAuthPath) -ApiKey $ApiKey
        $backupAuthResult = Set-RaymanCodexYunyiAuthFile -Path (Get-RaymanCodexYunyiBackupAuthPath) -ApiKey $ApiKey
        if (-not [string]::IsNullOrWhiteSpace([string]$WorkspaceRoot)) {
            $workspaceAuthResult = Set-RaymanCodexYunyiAuthFile -Path (Get-RaymanCodexWorkspaceYunyiCanonicalAuthPath -WorkspaceRoot $WorkspaceRoot) -ApiKey $ApiKey
            $workspaceBackupAuthResult = Set-RaymanCodexYunyiAuthFile -Path (Get-RaymanCodexWorkspaceYunyiBackupAuthPath -WorkspaceRoot $WorkspaceRoot) -ApiKey $ApiKey
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$BaseUrl)) {
        $backupTomlResult = Copy-RaymanCodexYunyiRawTomlBackup -SourcePath $BackupTomlSourcePath -DestinationRoot (Get-RaymanCodexYunyiBackupRoot) -BaseUrl $BaseUrl -ApiKey $ApiKey
        if (-not [string]::IsNullOrWhiteSpace([string]$WorkspaceRoot)) {
            $workspaceBackupTomlResult = Copy-RaymanCodexYunyiRawTomlBackup -SourcePath $BackupTomlSourcePath -DestinationRoot (Get-RaymanCodexWorkspaceYunyiBackupRoot -WorkspaceRoot $WorkspaceRoot) -BaseUrl $BaseUrl -ApiKey $ApiKey
        }
    }

    return [pscustomobject]@{
        config = $configResult
        auth = $authResult
        backup_auth = $backupAuthResult
        workspace_config = $workspaceConfigResult
        workspace_auth = $workspaceAuthResult
        workspace_backup_auth = $workspaceBackupAuthResult
        backup_toml = $backupTomlResult
        workspace_backup_toml = $workspaceBackupTomlResult
        success = (
            ($null -eq $configResult -or [bool]$configResult.success) -and
            ($null -eq $authResult -or [bool]$authResult.success) -and
            ($null -eq $backupAuthResult -or [bool]$backupAuthResult.success) -and
            ($null -eq $workspaceConfigResult -or [bool]$workspaceConfigResult.success) -and
            ($null -eq $workspaceAuthResult -or [bool]$workspaceAuthResult.success) -and
            ($null -eq $workspaceBackupAuthResult -or [bool]$workspaceBackupAuthResult.success) -and
            ($null -eq $backupTomlResult -or [bool]$backupTomlResult.success) -and
            ($null -eq $workspaceBackupTomlResult -or [bool]$workspaceBackupTomlResult.success)
        )
    }
}

function Ensure-RaymanCodexYunyiUserHomeState {
    param(
        [string]$WorkspaceRoot = ''
    )

    $canonicalConfigState = Get-RaymanCodexYunyiTomlState -Path (Get-RaymanCodexYunyiCanonicalConfigPath)
    $canonicalAuthState = Get-RaymanCodexYunyiAuthFileState -Path (Get-RaymanCodexYunyiCanonicalAuthPath)
    $canonicalBaseValid = ([bool]$canonicalConfigState.base_url_present -and -not [string]::IsNullOrWhiteSpace([string]$canonicalConfigState.base_url) -and -not [bool]$canonicalConfigState.base_url_placeholder_detected -and [bool]$canonicalConfigState.provider_name_present)
    $canonicalApiValid = ([bool]$canonicalAuthState.available -and -not [string]::IsNullOrWhiteSpace([string]$canonicalAuthState.value))
    $needsBaseRepair = (-not $canonicalBaseValid)
    $needsApiRepair = (-not $canonicalApiValid)

    if (-not $needsBaseRepair -and -not $needsApiRepair) {
        return [pscustomobject]@{
            success = $true
            repaired = $false
            base_url = [string]$canonicalConfigState.base_url
            api_key = '[redacted]'
            base_source = 'user_home:config.toml.yunyi'
            api_source = 'user_home:auth.json.yunyi'
            sync = $null
            reason = 'canonical_ready'
        }
    }

    $backupBaseState = Get-RaymanCodexUserHomeYunyiBackupBaseUrlState
    if (-not [bool]$backupBaseState.available) {
        $backupBaseState = Get-RaymanCodexWorkspaceYunyiBaseUrlState -WorkspaceRoot $WorkspaceRoot
    }
    $backupApiState = Get-RaymanCodexUserHomeYunyiBackupApiKeyState
    if (-not [bool]$backupApiState.available) {
        $backupApiState = Get-RaymanCodexWorkspaceYunyiApiKeyState -WorkspaceRoot $WorkspaceRoot
    }

    $baseUrl = if ($canonicalBaseValid) { [string]$canonicalConfigState.base_url } elseif ([bool]$backupBaseState.available) { [string]$backupBaseState.value } else { '' }
    $apiKey = if ($canonicalApiValid) { [string]$canonicalAuthState.value } elseif ([bool]$backupApiState.available) { [string]$backupApiState.value } else { '' }
    $backupTomlSourcePath = ''
    foreach ($candidate in @($backupApiState, $backupBaseState)) {
        if ($null -eq $candidate) {
            continue
        }
        $candidatePath = [string](Get-RaymanMapValue -Map $candidate -Key 'path' -Default '')
        if (-not [string]::IsNullOrWhiteSpace([string]$candidatePath) -and $candidatePath -match '\.toml$') {
            $backupTomlSourcePath = $candidatePath
            break
        }
    }

    if (
        ($needsBaseRepair -and [string]::IsNullOrWhiteSpace([string]$baseUrl)) -or
        ($needsApiRepair -and [string]::IsNullOrWhiteSpace([string]$apiKey))
    ) {
        return [pscustomobject]@{
            success = $false
            repaired = $false
            base_url = [string]$baseUrl
            api_key = if ([string]::IsNullOrWhiteSpace([string]$apiKey)) { '' } else { '[redacted]' }
            base_source = if ([bool]$backupBaseState.available) { [string]$backupBaseState.source } else { '' }
            api_source = if ([bool]$backupApiState.available) { [string]$backupApiState.source } else { '' }
            sync = $null
            reason = 'repair_source_missing'
        }
    }

    $sync = Sync-RaymanCodexUserHomeYunyiState -WorkspaceRoot $WorkspaceRoot -BaseUrl $baseUrl -ApiKey $apiKey -BackupTomlSourcePath $backupTomlSourcePath
    return [pscustomobject]@{
        success = [bool]$sync.success
        repaired = $true
        base_url = [string]$baseUrl
        api_key = '[redacted]'
        base_source = if ($canonicalBaseValid) { 'user_home:config.toml.yunyi' } else { [string]$backupBaseState.source }
        api_source = if ($canonicalApiValid) { 'user_home:auth.json.yunyi' } else { [string]$backupApiState.source }
        sync = $sync
        reason = if ([bool]$sync.success) { 'repaired_from_backup' } else { 'repair_sync_incomplete' }
    }
}

function Get-RaymanCodexEnvironmentBaseUrlState {
    param(
        [string]$WorkspaceRoot = '',
        [string]$AccountAlias = ''
    )

    $processBaseUrl = [Environment]::GetEnvironmentVariable('OPENAI_BASE_URL')
    if (-not [string]::IsNullOrWhiteSpace([string]$processBaseUrl)) {
        return [pscustomobject]@{
            present = $true
            available = $true
            value = ([string]$processBaseUrl).Trim()
            source = 'process_environment'
            variable_name = 'OPENAI_BASE_URL'
        }
    }

    $processApiBase = [Environment]::GetEnvironmentVariable('OPENAI_API_BASE')
    if (-not [string]::IsNullOrWhiteSpace([string]$processApiBase)) {
        return [pscustomobject]@{
            present = $true
            available = $true
            value = ([string]$processApiBase).Trim()
            source = 'process_environment'
            variable_name = 'OPENAI_API_BASE'
        }
    }

    $dotEnvBaseUrl = Get-RaymanDotEnvString -WorkspaceRoot $WorkspaceRoot -Name 'OPENAI_BASE_URL'
    if (-not [string]::IsNullOrWhiteSpace([string]$dotEnvBaseUrl)) {
        return [pscustomobject]@{
            present = $true
            available = $true
            value = ([string]$dotEnvBaseUrl).Trim()
            source = 'workspace_dotenv'
            variable_name = 'OPENAI_BASE_URL'
        }
    }

    $dotEnvApiBase = Get-RaymanDotEnvString -WorkspaceRoot $WorkspaceRoot -Name 'OPENAI_API_BASE'
    if (-not [string]::IsNullOrWhiteSpace([string]$dotEnvApiBase)) {
        return [pscustomobject]@{
            present = $true
            available = $true
            value = ([string]$dotEnvApiBase).Trim()
            source = 'workspace_dotenv'
            variable_name = 'OPENAI_API_BASE'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$AccountAlias)) {
        $accountRecord = Get-RaymanCodexAccountRecord -Alias $AccountAlias
        $recordBaseUrl = if ($null -ne $accountRecord) { [string](Get-RaymanMapValue -Map $accountRecord -Key 'last_yunyi_base_url' -Default '') } else { '' }
        if (-not [string]::IsNullOrWhiteSpace([string]$recordBaseUrl)) {
            return [pscustomobject]@{
                present = $true
                available = $true
                value = ([string]$recordBaseUrl).Trim()
                source = 'account_record'
                variable_name = 'OPENAI_BASE_URL'
            }
        }
    }

    return [pscustomobject]@{
        present = $false
        available = $false
        value = ''
        source = 'none'
        variable_name = ''
    }
}

function Test-RaymanCodexApiKeyCandidate {
    param(
        [AllowEmptyString()][string]$Value,
        [bool]$AllowCustomProviderToken = $false
    )

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return $false
    }

    $trimmed = [string]$Value.Trim()
    if ([string]::IsNullOrWhiteSpace([string]$trimmed)) {
        return $false
    }

    if ($trimmed.StartsWith("'") -or $trimmed.StartsWith('"') -or $trimmed.EndsWith("'") -or $trimmed.EndsWith('"')) {
        return $false
    }

    if ($trimmed -match '\s') {
        return $false
    }

    if ($trimmed -match '^sk-[A-Za-z0-9][A-Za-z0-9_-]{12,}$') {
        return $true
    }

    if ($AllowCustomProviderToken) {
        return ($trimmed.Length -ge 8)
    }

    return $false
}

function Get-RaymanCodexEnvironmentApiKeyState {
    param(
        [string]$WorkspaceRoot = '',
        [string]$AccountAlias = ''
    )

    $baseUrlState = Get-RaymanCodexEnvironmentBaseUrlState -WorkspaceRoot $WorkspaceRoot -AccountAlias $AccountAlias
    $allowCustomToken = ([bool]$baseUrlState.available -and -not [string]::IsNullOrWhiteSpace([string]$baseUrlState.value))

    $processValue = [Environment]::GetEnvironmentVariable('OPENAI_API_KEY')
    if (-not [string]::IsNullOrWhiteSpace([string]$processValue)) {
        $trimmedValue = [string]$processValue.Trim()
        $valid = Test-RaymanCodexApiKeyCandidate -Value $trimmedValue -AllowCustomProviderToken:$allowCustomToken
        return [pscustomobject]@{
            present = $true
            available = $valid
            valid = $valid
            value = if ($valid) { $trimmedValue } else { '' }
            source = 'process_environment'
            reason = if ($valid -and $allowCustomToken -and -not ($trimmedValue -match '^sk-')) { 'custom_provider_token' } elseif ($valid) { 'valid' } else { 'invalid_format' }
            base_url_present = [bool]$baseUrlState.present
            base_url_value = [string]$baseUrlState.value
            base_url_source = [string]$baseUrlState.source
        }
    }

    $dotEnvValue = Get-RaymanDotEnvString -WorkspaceRoot $WorkspaceRoot -Name 'OPENAI_API_KEY'
    if (-not [string]::IsNullOrWhiteSpace([string]$dotEnvValue)) {
        $trimmedValue = [string]$dotEnvValue.Trim()
        $valid = Test-RaymanCodexApiKeyCandidate -Value $trimmedValue -AllowCustomProviderToken:$allowCustomToken
        return [pscustomobject]@{
            present = $true
            available = $valid
            valid = $valid
            value = if ($valid) { $trimmedValue } else { '' }
            source = 'workspace_dotenv'
            reason = if ($valid -and $allowCustomToken -and -not ($trimmedValue -match '^sk-')) { 'custom_provider_token' } elseif ($valid) { 'valid' } else { 'invalid_format' }
            base_url_present = [bool]$baseUrlState.present
            base_url_value = [string]$baseUrlState.value
            base_url_source = [string]$baseUrlState.source
        }
    }

    return [pscustomobject]@{
        present = $false
        available = $false
        valid = $false
        value = ''
        source = 'none'
        reason = 'missing'
        base_url_present = [bool]$baseUrlState.present
        base_url_value = [string]$baseUrlState.value
        base_url_source = [string]$baseUrlState.source
    }
}

function Get-RaymanCodexNativeAuthState {
    param(
        [string]$WorkspaceRoot = '',
        [string]$CodexHome = '',
        [string]$StatusText = ''
    )

    $authFilePath = Get-RaymanCodexAuthFilePath -CodexHome $CodexHome
    $environmentApiKeyState = Get-RaymanCodexEnvironmentApiKeyState -WorkspaceRoot $WorkspaceRoot
    $state = [ordered]@{
        auth_mode_detected = 'unknown'
        auth_source = 'none'
        auth_file_path = $authFilePath
        auth_file_present = $false
        environment_api_key_present = [bool]$environmentApiKeyState.present
        environment_api_key_valid = [bool]$environmentApiKeyState.valid
        environment_api_key_source = [string]$environmentApiKeyState.source
    }

    if (-not [string]::IsNullOrWhiteSpace($authFilePath) -and (Test-Path -LiteralPath $authFilePath -PathType Leaf)) {
        $state.auth_file_present = $true
        try {
            $authDoc = Get-Content -LiteralPath $authFilePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            $detected = Normalize-RaymanCodexDetectedAuthMode -Mode ([string](Get-RaymanMapValue -Map $authDoc -Key 'auth_mode' -Default ''))
            if ($detected -ne 'unknown') {
                $state.auth_mode_detected = $detected
                $state.auth_source = 'native_auth_json'
                return [pscustomobject]$state
            }
        } catch {}
    }

    if ([bool]$environmentApiKeyState.available) {
        $state.auth_mode_detected = 'env_apikey'
        $state.auth_source = 'environment'
        return [pscustomobject]$state
    }

    $detectedFromStatus = Get-RaymanCodexAuthModeFromStatusText -Text $StatusText
    if ($detectedFromStatus -ne 'unknown') {
        $state.auth_mode_detected = $detectedFromStatus
        $state.auth_source = 'codex_login_status'
    }

    return [pscustomobject]$state
}

function Get-RaymanCodexCommandEnvironmentOverrides {
    param(
        [string]$CodexHome = '',
        [hashtable]$AdditionalOverrides = @{}
    )

    $envOverrides = @{}
    if (-not [string]::IsNullOrWhiteSpace($CodexHome)) {
        $envOverrides['CODEX_HOME'] = $CodexHome
    }

    foreach ($name in @($AdditionalOverrides.Keys)) {
        $envOverrides[[string]$name] = $AdditionalOverrides[$name]
    }

    return $envOverrides
}

function Get-RaymanCodexApiKeyEnvironmentOverrides {
    param(
        [string]$WorkspaceRoot = '',
        [string]$AccountAlias = ''
    )

    $apiKeyState = Get-RaymanCodexEnvironmentApiKeyState -WorkspaceRoot $WorkspaceRoot -AccountAlias $AccountAlias
    $baseUrlState = Get-RaymanCodexEnvironmentBaseUrlState -WorkspaceRoot $WorkspaceRoot -AccountAlias $AccountAlias

    $overrides = @{}
    if ([bool]$apiKeyState.available) {
        $overrides['OPENAI_API_KEY'] = [string]$apiKeyState.value
    }
    if ([bool]$baseUrlState.available -and -not [string]::IsNullOrWhiteSpace([string]$baseUrlState.value)) {
        $overrides['OPENAI_BASE_URL'] = [string]$baseUrlState.value
        $overrides['OPENAI_API_BASE'] = [string]$baseUrlState.value
    }

    if ($overrides.Count -eq 0) {
        return @{}
    }

    return $overrides
}

function Get-RaymanCodexLatestNativeSession {
    param(
        [string]$CodexHome = '',
        [string]$Alias = ''
    )

    $sessionIndexPath = Get-RaymanCodexSessionIndexPath -CodexHome $CodexHome -Alias $Alias
    $emptySummary = New-RaymanCodexNativeSessionSummary -SessionIndexPath $sessionIndexPath
    if ([string]::IsNullOrWhiteSpace($sessionIndexPath) -or -not (Test-Path -LiteralPath $sessionIndexPath -PathType Leaf)) {
        return [pscustomobject]$emptySummary
    }

    $bestSummary = $null
    $bestSortKey = [datetimeoffset]::MinValue
    foreach ($line in @(Get-Content -LiteralPath $sessionIndexPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $text = [string]$line
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        try {
            $item = $text | ConvertFrom-Json -ErrorAction Stop
        } catch {
            continue
        }

        $updatedAt = [string](Get-RaymanMapValue -Map $item -Key 'updated_at' -Default '')
        $sortKey = [datetimeoffset]::MinValue
        if (-not [string]::IsNullOrWhiteSpace($updatedAt)) {
            try {
                $sortKey = [datetimeoffset]::Parse($updatedAt)
            } catch {
                $sortKey = [datetimeoffset]::MinValue
            }
        }

        if ($null -ne $bestSummary -and $sortKey -lt $bestSortKey) {
            continue
        }

        $bestSortKey = $sortKey
        $bestSummary = [ordered]@{
            available = $true
            id = [string](Get-RaymanMapValue -Map $item -Key 'id' -Default '')
            thread_name = [string](Get-RaymanMapValue -Map $item -Key 'thread_name' -Default '')
            updated_at = $updatedAt
            source = 'session_index_jsonl'
            session_index_path = $sessionIndexPath
        }
    }

    if ($null -eq $bestSummary) {
        return [pscustomobject]$emptySummary
    }

    return (ConvertTo-RaymanCodexNativeSessionSummary -InputObject $bestSummary -SessionIndexPath $sessionIndexPath)
}

function Get-RaymanCodexWorkspaceSavedStateSummary {
    param(
        [string]$WorkspaceRoot = '',
        [string]$AccountAlias = ''
    )

    $normalizedAlias = Normalize-RaymanCodexAlias -Alias $AccountAlias
    $resolvedWorkspace = ''
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        try {
            $resolvedWorkspace = Resolve-RaymanCodexWorkspacePath -WorkspaceRoot $WorkspaceRoot
        } catch {
            $resolvedWorkspace = [string]$WorkspaceRoot
        }
    }

    $summary = [ordered]@{
        workspace_root = $resolvedWorkspace
        account_alias = $normalizedAlias
        total_count = 0
        manual_count = 0
        auto_temp_count = 0
        latest = $null
        recent_saved_states = @()
    }

    if ([string]::IsNullOrWhiteSpace($resolvedWorkspace)) {
        return [pscustomobject]$summary
    }

    $sessionRoot = Join-Path $resolvedWorkspace '.Rayman\state\sessions'
    if (-not (Test-Path -LiteralPath $sessionRoot -PathType Container)) {
        return [pscustomobject]$summary
    }

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($sessionDir in @(Get-ChildItem -LiteralPath $sessionRoot -Directory -ErrorAction SilentlyContinue)) {
        $manifestPath = Join-Path $sessionDir.FullName 'session.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            continue
        }

        $manifest = $null
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $manifest = $null
        }
        if ($null -eq $manifest) {
            continue
        }

        $backend = [string](Get-RaymanMapValue -Map $manifest -Key 'backend' -Default '')
        if ($backend -ne 'codex') {
            continue
        }

        $manifestAlias = Normalize-RaymanCodexAlias -Alias ([string](Get-RaymanMapValue -Map $manifest -Key 'account_alias' -Default ''))
        if (-not [string]::IsNullOrWhiteSpace($normalizedAlias) -and $manifestAlias -ne $normalizedAlias) {
            continue
        }

        $status = [string](Get-RaymanMapValue -Map $manifest -Key 'status' -Default 'paused')
        if ($status -ne 'paused') {
            continue
        }

        $updatedAt = [string](Get-RaymanMapValue -Map $manifest -Key 'updated_at' -Default '')
        $sortKey = [datetimeoffset]::MinValue
        if (-not [string]::IsNullOrWhiteSpace($updatedAt)) {
            try {
                $sortKey = [datetimeoffset]::Parse($updatedAt)
            } catch {
                $sortKey = [datetimeoffset]::MinValue
            }
        }

        $sessionKind = [string](Get-RaymanMapValue -Map $manifest -Key 'session_kind' -Default 'manual')
        $row = [pscustomobject]@{
            name = [string](Get-RaymanMapValue -Map $manifest -Key 'name' -Default '')
            slug = [string](Get-RaymanMapValue -Map $manifest -Key 'slug' -Default '')
            status = $status
            session_kind = $sessionKind
            backend = $backend
            account_alias = $manifestAlias
            updated_at = $updatedAt
            task_description = [string](Get-RaymanMapValue -Map $manifest -Key 'task_description' -Default '')
            owner_display = [string](Get-RaymanMapValue -Map $manifest -Key 'owner_display' -Default '')
            worktree_path = [string](Get-RaymanMapValue -Map $manifest -Key 'worktree_path' -Default '')
            branch = [string](Get-RaymanMapValue -Map $manifest -Key 'branch' -Default '')
            sort_key = $sortKey
        }

        $items.Add($row) | Out-Null
    }

    $sorted = @($items.ToArray() | Sort-Object @{ Expression = { $_.sort_key }; Descending = $true }, @{ Expression = { [string]$_.slug } })
    $summary.total_count = $sorted.Count
    $summary.manual_count = @($sorted | Where-Object { [string]$_.session_kind -eq 'manual' }).Count
    $summary.auto_temp_count = @($sorted | Where-Object { [string]$_.session_kind -eq 'auto_temp' }).Count
    $summary.latest = if ($sorted.Count -gt 0) { $sorted[0] } else { $null }
    $summary.recent_saved_states = @($sorted | Select-Object -First 3 | ForEach-Object {
            [pscustomobject]@{
                name = [string]$_.name
                slug = [string]$_.slug
                status = [string]$_.status
                session_kind = [string]$_.session_kind
                backend = [string]$_.backend
                account_alias = [string]$_.account_alias
                updated_at = [string]$_.updated_at
                task_description = [string]$_.task_description
                owner_display = [string]$_.owner_display
                worktree_path = [string]$_.worktree_path
                branch = [string]$_.branch
            }
        })

    return [pscustomobject]$summary
}

function Get-RaymanCodexRegistry {
    $path = Get-RaymanCodexRegistryPath
    $registry = [ordered]@{
        schema = 'rayman.codex.accounts.v1'
        path = $path
        parse_failed = $false
        parse_error = ''
        accounts = [ordered]@{}
        workspaces = [ordered]@{}
    }

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]$registry
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $schema = [string](Get-RaymanMapValue -Map $raw -Key 'schema' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($schema)) {
            $registry.schema = $schema
        }
        $registry.accounts = ConvertTo-RaymanStringKeyMap -InputObject (Get-RaymanMapValue -Map $raw -Key 'accounts' -Default $null)
        $registry.workspaces = ConvertTo-RaymanStringKeyMap -InputObject (Get-RaymanMapValue -Map $raw -Key 'workspaces' -Default $null)
    } catch {
        $registry.parse_failed = $true
        $registry.parse_error = $_.Exception.Message
    }

    return [pscustomobject]$registry
}

function Save-RaymanCodexRegistry {
    param(
        [object]$Registry
    )

    $path = Get-RaymanCodexRegistryPath
    $stateRoot = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
    }

    $accountMap = ConvertTo-RaymanStringKeyMap -InputObject (Get-RaymanMapValue -Map $Registry -Key 'accounts' -Default $null)
    $workspaceMap = ConvertTo-RaymanStringKeyMap -InputObject (Get-RaymanMapValue -Map $Registry -Key 'workspaces' -Default $null)

    $accountsOut = [ordered]@{}
    foreach ($key in @($accountMap.Keys | Sort-Object)) {
        $item = $accountMap[$key]
        $latestNativeSession = ConvertTo-RaymanCodexNativeSessionSummary -InputObject (Get-RaymanMapValue -Map $item -Key 'latest_native_session' -Default $null)
        $accountsOut[[string]$key] = [ordered]@{
            alias = [string](Get-RaymanMapValue -Map $item -Key 'alias' -Default $key)
            alias_key = [string](Get-RaymanMapValue -Map $item -Key 'alias_key' -Default $key)
            safe_alias = [string](Get-RaymanMapValue -Map $item -Key 'safe_alias' -Default (ConvertTo-RaymanSafeNamespace -Value ([string](Get-RaymanMapValue -Map $item -Key 'alias' -Default $key))))
            codex_home = [string](Get-RaymanMapValue -Map $item -Key 'codex_home' -Default '')
            auth_scope = Normalize-RaymanCodexAuthScope -Scope ([string](Get-RaymanMapValue -Map $item -Key 'auth_scope' -Default ''))
            default_profile = [string](Get-RaymanMapValue -Map $item -Key 'default_profile' -Default '')
            auth_mode_last = Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $item -Key 'auth_mode_last' -Default ''))
            last_status = [string](Get-RaymanMapValue -Map $item -Key 'last_status' -Default '')
            last_checked_at = [string](Get-RaymanMapValue -Map $item -Key 'last_checked_at' -Default '')
            last_login_mode = [string](Get-RaymanMapValue -Map $item -Key 'last_login_mode' -Default '')
            last_login_strategy = [string](Get-RaymanMapValue -Map $item -Key 'last_login_strategy' -Default '')
            last_login_prompt_classification = [string](Get-RaymanMapValue -Map $item -Key 'last_login_prompt_classification' -Default '')
            last_login_started_at = [string](Get-RaymanMapValue -Map $item -Key 'last_login_started_at' -Default '')
            last_login_finished_at = [string](Get-RaymanMapValue -Map $item -Key 'last_login_finished_at' -Default '')
            last_login_success = [bool](Get-RaymanMapValue -Map $item -Key 'last_login_success' -Default $false)
            desktop_target_mode = Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $item -Key 'desktop_target_mode' -Default ''))
            desktop_saved_token_reused = [bool](Get-RaymanMapValue -Map $item -Key 'desktop_saved_token_reused' -Default $false)
            desktop_saved_token_source = [string](Get-RaymanMapValue -Map $item -Key 'desktop_saved_token_source' -Default '')
            desktop_status_command = [string](Get-RaymanMapValue -Map $item -Key 'desktop_status_command' -Default '')
            desktop_status_quota_visible = [bool](Get-RaymanMapValue -Map $item -Key 'desktop_status_quota_visible' -Default $false)
            desktop_status_reason = [string](Get-RaymanMapValue -Map $item -Key 'desktop_status_reason' -Default '')
            desktop_config_conflict = [string](Get-RaymanMapValue -Map $item -Key 'desktop_config_conflict' -Default '')
            desktop_unsynced_reason = [string](Get-RaymanMapValue -Map $item -Key 'desktop_unsynced_reason' -Default '')
            desktop_status_checked_at = [string](Get-RaymanMapValue -Map $item -Key 'desktop_status_checked_at' -Default '')
            last_yunyi_base_url = [string](Get-RaymanMapValue -Map $item -Key 'last_yunyi_base_url' -Default '')
            last_yunyi_success_at = [string](Get-RaymanMapValue -Map $item -Key 'last_yunyi_success_at' -Default '')
            last_yunyi_config_ready = [bool](Get-RaymanMapValue -Map $item -Key 'last_yunyi_config_ready' -Default $false)
            last_yunyi_reuse_reason = [string](Get-RaymanMapValue -Map $item -Key 'last_yunyi_reuse_reason' -Default '')
            last_yunyi_base_url_source = [string](Get-RaymanMapValue -Map $item -Key 'last_yunyi_base_url_source' -Default '')
            latest_native_session = [ordered]@{
                available = [bool]$latestNativeSession.available
                id = [string]$latestNativeSession.id
                thread_name = [string]$latestNativeSession.thread_name
                updated_at = [string]$latestNativeSession.updated_at
                source = [string]$latestNativeSession.source
                session_index_path = [string]$latestNativeSession.session_index_path
            }
        }
    }

    $workspacesOut = [ordered]@{}
    foreach ($key in @($workspaceMap.Keys | Sort-Object)) {
        $item = $workspaceMap[$key]
        $workspacesOut[[string]$key] = [ordered]@{
            normalized_root = [string](Get-RaymanMapValue -Map $item -Key 'normalized_root' -Default $key)
            workspace_root = [string](Get-RaymanMapValue -Map $item -Key 'workspace_root' -Default '')
            display_name = [string](Get-RaymanMapValue -Map $item -Key 'display_name' -Default '')
            last_account_alias = [string](Get-RaymanMapValue -Map $item -Key 'last_account_alias' -Default '')
            last_profile = [string](Get-RaymanMapValue -Map $item -Key 'last_profile' -Default '')
            last_used_at = [string](Get-RaymanMapValue -Map $item -Key 'last_used_at' -Default '')
        }
    }

    $payload = [ordered]@{
        schema = 'rayman.codex.accounts.v1'
        generated_at = (Get-Date).ToString('o')
        accounts = $accountsOut
        workspaces = $workspacesOut
    }

    Write-RaymanUtf8NoBom -Path $path -Content (($payload | ConvertTo-Json -Depth 10).TrimEnd() + "`n")
    return $path
}

function Get-RaymanCodexAccountRecord {
    param(
        [string]$Alias
    )

    $aliasKey = Get-RaymanCodexAliasKey -Alias $Alias
    if ([string]::IsNullOrWhiteSpace($aliasKey)) {
        return $null
    }

    $registry = Get-RaymanCodexRegistry
    return (Get-RaymanMapValue -Map $registry.accounts -Key $aliasKey -Default $null)
}

function Ensure-RaymanCodexAccountConfig {
    param(
        [string]$CodexHome
    )

    if ([string]::IsNullOrWhiteSpace($CodexHome)) {
        throw 'Codex home path is required.'
    }

    if (-not (Test-Path -LiteralPath $CodexHome -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null
    }

    $configPath = Get-RaymanCodexAccountConfigPath -CodexHome $CodexHome
    Set-RaymanManagedTextBlock -Path $configPath -BeginMarker '# RAYMAN:CODEX:BEGIN' -EndMarker '# RAYMAN:CODEX:END' -Lines @(
        '# Rayman-managed per-account Codex settings.',
        'cli_auth_credentials_store = "file"'
    ) | Out-Null
    return $configPath
}

function Get-RaymanCodexAccountConfigPath {
    param(
        [string]$CodexHome = '',
        [string]$Alias = ''
    )

    $resolvedHome = [string]$CodexHome
    if ([string]::IsNullOrWhiteSpace($resolvedHome) -and -not [string]::IsNullOrWhiteSpace($Alias)) {
        $resolvedHome = Get-RaymanCodexAccountHomePath -Alias $Alias
    }
    if ([string]::IsNullOrWhiteSpace($resolvedHome)) {
        return ''
    }
    return (Join-Path $resolvedHome 'config.toml')
}

function ConvertTo-RaymanCodexWorkspaceTrustPath {
    param(
        [string]$WorkspaceRoot
    )

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        return ''
    }

    try {
        $resolved = Resolve-RaymanCodexWorkspacePath -WorkspaceRoot $WorkspaceRoot
    } catch {
        try {
            $resolved = [System.IO.Path]::GetFullPath($WorkspaceRoot)
        } catch {
            $resolved = [string]$WorkspaceRoot
        }
    }

    return ([string]$resolved).Replace('\', '/').TrimEnd('/')
}

function Get-RaymanCodexWorkspaceTrustHeader {
    param(
        [string]$WorkspaceRoot
    )

    $workspacePath = ConvertTo-RaymanCodexWorkspaceTrustPath -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace($workspacePath)) {
        return ''
    }

    $escapedPath = $workspacePath.Replace('\', '\\').Replace('"', '\"')
    return ('[projects."{0}"]' -f $escapedPath)
}

function Get-RaymanCodexWorkspaceTrustState {
    param(
        [string]$WorkspaceRoot,
        [string]$CodexHome = '',
        [string]$Alias = ''
    )

    $configPath = Get-RaymanCodexAccountConfigPath -CodexHome $CodexHome -Alias $Alias
    $sectionHeader = Get-RaymanCodexWorkspaceTrustHeader -WorkspaceRoot $WorkspaceRoot
    $state = [ordered]@{
        present = $false
        trust_level = ''
        config_path = $configPath
        workspace_root = ConvertTo-RaymanCodexWorkspaceTrustPath -WorkspaceRoot $WorkspaceRoot
        section_header = $sectionHeader
    }

    if ([string]::IsNullOrWhiteSpace($configPath) -or [string]::IsNullOrWhiteSpace($sectionHeader) -or -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return [pscustomobject]$state
    }

    $raw = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]$state
    }

    $pattern = '(?ms)^' + [regex]::Escape($sectionHeader) + '\r?\n(?<body>.*?)(?=^\[|\z)'
    $match = [regex]::Match($raw, $pattern)
    if (-not $match.Success) {
        return [pscustomobject]$state
    }

    $trustMatch = [regex]::Match([string]$match.Groups['body'].Value, '(?im)^\s*trust_level\s*=\s*"(?<level>[^"]+)"')
    if ($trustMatch.Success) {
        $state.present = $true
        $state.trust_level = [string]$trustMatch.Groups['level'].Value
    }

    return [pscustomobject]$state
}

function Set-RaymanCodexWorkspaceTrust {
    param(
        [string]$WorkspaceRoot,
        [string]$CodexHome = '',
        [string]$Alias = '',
        [ValidateSet('trusted', 'untrusted')][string]$TrustLevel = 'trusted'
    )

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        throw 'Workspace root is required.'
    }

    $configPath = Get-RaymanCodexAccountConfigPath -CodexHome $CodexHome -Alias $Alias
    if ([string]::IsNullOrWhiteSpace($configPath)) {
        throw 'Codex account config path is required.'
    }

    $configDir = Split-Path -Parent $configPath
    Ensure-RaymanCodexAccountConfig -CodexHome $configDir | Out-Null

    $sectionHeader = Get-RaymanCodexWorkspaceTrustHeader -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace($sectionHeader)) {
        throw 'Workspace trust header could not be resolved.'
    }

    $existing = ''
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $existing = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    }
    if ($null -eq $existing) {
        $existing = ''
    }

    $newline = if ($existing -match "`r`n") { "`r`n" } else { "`n" }
    $trustLine = ('trust_level = "{0}"' -f $TrustLevel)
    $updated = $existing
    $changed = $false
    $pattern = '(?ms)^' + [regex]::Escape($sectionHeader) + '\r?\n(?<body>.*?)(?=^\[|\z)'
    $match = [regex]::Match($existing, $pattern)

    if ($match.Success) {
        $body = [string]$match.Groups['body'].Value
        $newBody = $body
        if ([regex]::IsMatch($body, '(?im)^\s*trust_level\s*=')) {
            $newBody = [regex]::Replace($body, '(?im)^\s*trust_level\s*=.*$', $trustLine, 1)
        } else {
            $newBody = $trustLine + $newline + $body
        }

        $replacement = $sectionHeader + $newline + $newBody
        $updated = $existing.Substring(0, $match.Index) + $replacement + $existing.Substring($match.Index + $match.Length)
        $changed = ($updated -ne $existing)
    } else {
        $sectionText = $sectionHeader + $newline + $trustLine + $newline
        if (-not [string]::IsNullOrWhiteSpace($updated)) {
            if ($updated -notmatch "(\r?\n)$") {
                $updated += $newline
            }
            if ($updated -notmatch "(\r?\n){2}$") {
                $updated += $newline
            }
        }
        $updated += $sectionText
        $changed = ($updated -ne $existing)
    }

    if ($changed) {
        Write-RaymanUtf8NoBom -Path $configPath -Content $updated
    }

    return [pscustomobject]@{
        changed = $changed
        config_path = $configPath
        workspace_root = ConvertTo-RaymanCodexWorkspaceTrustPath -WorkspaceRoot $WorkspaceRoot
        section_header = $sectionHeader
        trust_level = $TrustLevel
    }
}

function Ensure-RaymanCodexAccount {
    param(
        [string]$Alias,
        [string]$DefaultProfile = '',
        [switch]$SetDefaultProfile
    )

    $normalized = Normalize-RaymanCodexAlias -Alias $Alias
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw 'Codex alias is required.'
    }

    $aliasKey = Get-RaymanCodexAliasKey -Alias $normalized
    $codexHome = Get-RaymanCodexAccountHomePath -Alias $normalized
    $safeAlias = ConvertTo-RaymanSafeNamespace -Value $normalized
    Ensure-RaymanCodexAccountConfig -CodexHome $codexHome | Out-Null

    $registry = Get-RaymanCodexRegistry
    $accounts = ConvertTo-RaymanStringKeyMap -InputObject $registry.accounts
    $existing = Get-RaymanMapValue -Map $accounts -Key $aliasKey -Default $null
    $latestNativeSession = ConvertTo-RaymanCodexNativeSessionSummary -InputObject (Get-RaymanMapValue -Map $existing -Key 'latest_native_session' -Default $null)

    $record = [ordered]@{
        alias = $normalized
        alias_key = $aliasKey
        safe_alias = $safeAlias
        codex_home = $codexHome
        auth_scope = if ($null -ne $existing) { Resolve-RaymanCodexAuthScopeForMode -ExistingScope ([string](Get-RaymanMapValue -Map $existing -Key 'auth_scope' -Default '')) -Mode ([string](Get-RaymanMapValue -Map $existing -Key 'auth_mode_last' -Default '')) } else { 'alias_local' }
        default_profile = if ($SetDefaultProfile) { [string]$DefaultProfile } elseif ($null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'default_profile' -Default '') } else { '' }
        auth_mode_last = if ($null -ne $existing) { Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $existing -Key 'auth_mode_last' -Default '')) } else { '' }
        last_status = if ($null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'last_status' -Default '') } else { '' }
        last_checked_at = if ($null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'last_checked_at' -Default '') } else { '' }
        last_login_mode = if ($null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'last_login_mode' -Default '') } else { '' }
        last_login_strategy = if ($null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'last_login_strategy' -Default '') } else { '' }
        last_login_prompt_classification = if ($null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'last_login_prompt_classification' -Default '') } else { '' }
        last_login_started_at = if ($null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'last_login_started_at' -Default '') } else { '' }
        last_login_finished_at = if ($null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'last_login_finished_at' -Default '') } else { '' }
        last_login_success = if ($null -ne $existing) { [bool](Get-RaymanMapValue -Map $existing -Key 'last_login_success' -Default $false) } else { $false }
        desktop_target_mode = if ($null -ne $existing) { Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $existing -Key 'desktop_target_mode' -Default '')) } else { '' }
        desktop_saved_token_reused = if ($null -ne $existing) { [bool](Get-RaymanMapValue -Map $existing -Key 'desktop_saved_token_reused' -Default $false) } else { $false }
        desktop_saved_token_source = if ($null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'desktop_saved_token_source' -Default '') } else { '' }
        desktop_status_command = if ($null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'desktop_status_command' -Default '') } else { '' }
        desktop_status_quota_visible = if ($null -ne $existing) { [bool](Get-RaymanMapValue -Map $existing -Key 'desktop_status_quota_visible' -Default $false) } else { $false }
        desktop_status_reason = if ($null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'desktop_status_reason' -Default '') } else { '' }
        desktop_config_conflict = if ($null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'desktop_config_conflict' -Default '') } else { '' }
        desktop_unsynced_reason = if ($null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'desktop_unsynced_reason' -Default '') } else { '' }
        desktop_status_checked_at = if ($null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'desktop_status_checked_at' -Default '') } else { '' }
        last_yunyi_base_url = if ($null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'last_yunyi_base_url' -Default '') } else { '' }
        last_yunyi_success_at = if ($null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'last_yunyi_success_at' -Default '') } else { '' }
        last_yunyi_config_ready = if ($null -ne $existing) { [bool](Get-RaymanMapValue -Map $existing -Key 'last_yunyi_config_ready' -Default $false) } else { $false }
        last_yunyi_reuse_reason = if ($null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'last_yunyi_reuse_reason' -Default '') } else { '' }
        last_yunyi_base_url_source = if ($null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'last_yunyi_base_url_source' -Default '') } else { '' }
        latest_native_session = $latestNativeSession
    }

    $accounts[$aliasKey] = $record
    $registry.accounts = $accounts
    Save-RaymanCodexRegistry -Registry $registry | Out-Null
    return [pscustomobject]$record
}

function Set-RaymanCodexAccountStatus {
    param(
        [string]$Alias,
        [string]$Status,
        [string]$CheckedAt,
        [string]$AuthModeLast = '',
        [object]$LatestNativeSession = $null
    )

    $normalized = Normalize-RaymanCodexAlias -Alias $Alias
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }

    $record = Ensure-RaymanCodexAccount -Alias $normalized
    $registry = Get-RaymanCodexRegistry
    $accounts = ConvertTo-RaymanStringKeyMap -InputObject $registry.accounts
    $aliasKey = Get-RaymanCodexAliasKey -Alias $normalized
    $latestNativeSessionValue = if ($PSBoundParameters.ContainsKey('LatestNativeSession')) {
        ConvertTo-RaymanCodexNativeSessionSummary -InputObject $LatestNativeSession
    } else {
        ConvertTo-RaymanCodexNativeSessionSummary -InputObject (Get-RaymanMapValue -Map $record -Key 'latest_native_session' -Default $null)
    }

    $updated = [ordered]@{
        alias = [string](Get-RaymanMapValue -Map $record -Key 'alias' -Default $normalized)
        alias_key = [string](Get-RaymanMapValue -Map $record -Key 'alias_key' -Default $aliasKey)
        safe_alias = [string](Get-RaymanMapValue -Map $record -Key 'safe_alias' -Default (ConvertTo-RaymanSafeNamespace -Value $normalized))
        codex_home = [string](Get-RaymanMapValue -Map $record -Key 'codex_home' -Default (Get-RaymanCodexAccountHomePath -Alias $normalized))
        auth_scope = Resolve-RaymanCodexAuthScopeForMode -ExistingScope ([string](Get-RaymanMapValue -Map $record -Key 'auth_scope' -Default '')) -Mode $(if ([string]::IsNullOrWhiteSpace($AuthModeLast)) { [string](Get-RaymanMapValue -Map $record -Key 'auth_mode_last' -Default '') } else { $AuthModeLast })
        default_profile = [string](Get-RaymanMapValue -Map $record -Key 'default_profile' -Default '')
        auth_mode_last = if ([string]::IsNullOrWhiteSpace($AuthModeLast)) { Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $record -Key 'auth_mode_last' -Default '')) } else { Normalize-RaymanCodexAuthModeLast -Mode $AuthModeLast }
        last_status = [string]$Status
        last_checked_at = [string]$CheckedAt
        last_login_mode = [string](Get-RaymanMapValue -Map $record -Key 'last_login_mode' -Default '')
        last_login_strategy = [string](Get-RaymanMapValue -Map $record -Key 'last_login_strategy' -Default '')
        last_login_prompt_classification = [string](Get-RaymanMapValue -Map $record -Key 'last_login_prompt_classification' -Default '')
        last_login_started_at = [string](Get-RaymanMapValue -Map $record -Key 'last_login_started_at' -Default '')
        last_login_finished_at = [string](Get-RaymanMapValue -Map $record -Key 'last_login_finished_at' -Default '')
        last_login_success = [bool](Get-RaymanMapValue -Map $record -Key 'last_login_success' -Default $false)
        desktop_target_mode = Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $record -Key 'desktop_target_mode' -Default ''))
        desktop_saved_token_reused = [bool](Get-RaymanMapValue -Map $record -Key 'desktop_saved_token_reused' -Default $false)
        desktop_saved_token_source = [string](Get-RaymanMapValue -Map $record -Key 'desktop_saved_token_source' -Default '')
        desktop_status_command = [string](Get-RaymanMapValue -Map $record -Key 'desktop_status_command' -Default '')
        desktop_status_quota_visible = [bool](Get-RaymanMapValue -Map $record -Key 'desktop_status_quota_visible' -Default $false)
        desktop_status_reason = [string](Get-RaymanMapValue -Map $record -Key 'desktop_status_reason' -Default '')
        desktop_config_conflict = [string](Get-RaymanMapValue -Map $record -Key 'desktop_config_conflict' -Default '')
        desktop_unsynced_reason = [string](Get-RaymanMapValue -Map $record -Key 'desktop_unsynced_reason' -Default '')
        desktop_status_checked_at = [string](Get-RaymanMapValue -Map $record -Key 'desktop_status_checked_at' -Default '')
        last_yunyi_base_url = [string](Get-RaymanMapValue -Map $record -Key 'last_yunyi_base_url' -Default '')
        last_yunyi_success_at = [string](Get-RaymanMapValue -Map $record -Key 'last_yunyi_success_at' -Default '')
        last_yunyi_config_ready = [bool](Get-RaymanMapValue -Map $record -Key 'last_yunyi_config_ready' -Default $false)
        last_yunyi_reuse_reason = [string](Get-RaymanMapValue -Map $record -Key 'last_yunyi_reuse_reason' -Default '')
        last_yunyi_base_url_source = [string](Get-RaymanMapValue -Map $record -Key 'last_yunyi_base_url_source' -Default '')
        latest_native_session = $latestNativeSessionValue
    }

    $accounts[$aliasKey] = $updated
    $registry.accounts = $accounts
    Save-RaymanCodexRegistry -Registry $registry | Out-Null
    return [pscustomobject]$updated
}

function Set-RaymanCodexAccountLoginDiagnostics {
    param(
        [string]$Alias,
        [string]$LoginMode = '',
        [string]$AuthScope = '',
        [string]$LaunchStrategy = '',
        [string]$PromptClassification = '',
        [string]$StartedAt = '',
        [string]$FinishedAt = '',
        [bool]$Success = $false,
        [string]$DesktopTargetMode = '',
        [bool]$DesktopSavedTokenReused = $false,
        [string]$DesktopSavedTokenSource = ''
    )

    $normalized = Normalize-RaymanCodexAlias -Alias $Alias
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }

    $record = Ensure-RaymanCodexAccount -Alias $normalized
    $registry = Get-RaymanCodexRegistry
    $accounts = ConvertTo-RaymanStringKeyMap -InputObject $registry.accounts
    $aliasKey = Get-RaymanCodexAliasKey -Alias $normalized

    $updated = [ordered]@{
        alias = [string](Get-RaymanMapValue -Map $record -Key 'alias' -Default $normalized)
        alias_key = [string](Get-RaymanMapValue -Map $record -Key 'alias_key' -Default $aliasKey)
        safe_alias = [string](Get-RaymanMapValue -Map $record -Key 'safe_alias' -Default (ConvertTo-RaymanSafeNamespace -Value $normalized))
        codex_home = [string](Get-RaymanMapValue -Map $record -Key 'codex_home' -Default (Get-RaymanCodexAccountHomePath -Alias $normalized))
        auth_scope = if ($Success) {
            Resolve-RaymanCodexAuthScopeForMode -ExistingScope $(if ([string]::IsNullOrWhiteSpace($AuthScope)) { [string](Get-RaymanMapValue -Map $record -Key 'auth_scope' -Default '') } else { $AuthScope }) -Mode $(if ([string]::IsNullOrWhiteSpace($LoginMode)) { [string](Get-RaymanMapValue -Map $record -Key 'auth_mode_last' -Default '') } else { $LoginMode })
        } else {
            Normalize-RaymanCodexAuthScope -Scope ([string](Get-RaymanMapValue -Map $record -Key 'auth_scope' -Default ''))
        }
        default_profile = [string](Get-RaymanMapValue -Map $record -Key 'default_profile' -Default '')
        auth_mode_last = Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $record -Key 'auth_mode_last' -Default ''))
        last_status = [string](Get-RaymanMapValue -Map $record -Key 'last_status' -Default '')
        last_checked_at = [string](Get-RaymanMapValue -Map $record -Key 'last_checked_at' -Default '')
        last_login_mode = [string]$LoginMode
        last_login_strategy = [string]$LaunchStrategy
        last_login_prompt_classification = [string]$PromptClassification
        last_login_started_at = [string]$StartedAt
        last_login_finished_at = [string]$FinishedAt
        last_login_success = [bool]$Success
        desktop_target_mode = if ([string]::IsNullOrWhiteSpace([string]$DesktopTargetMode)) {
            Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $record -Key 'desktop_target_mode' -Default $LoginMode))
        } else {
            Normalize-RaymanCodexAuthModeLast -Mode $DesktopTargetMode
        }
        desktop_saved_token_reused = [bool]$DesktopSavedTokenReused
        desktop_saved_token_source = [string]$DesktopSavedTokenSource
        desktop_status_command = [string](Get-RaymanMapValue -Map $record -Key 'desktop_status_command' -Default '')
        desktop_status_quota_visible = [bool](Get-RaymanMapValue -Map $record -Key 'desktop_status_quota_visible' -Default $false)
        desktop_status_reason = [string](Get-RaymanMapValue -Map $record -Key 'desktop_status_reason' -Default '')
        desktop_config_conflict = [string](Get-RaymanMapValue -Map $record -Key 'desktop_config_conflict' -Default '')
        desktop_unsynced_reason = [string](Get-RaymanMapValue -Map $record -Key 'desktop_unsynced_reason' -Default '')
        desktop_status_checked_at = [string](Get-RaymanMapValue -Map $record -Key 'desktop_status_checked_at' -Default '')
        last_yunyi_base_url = [string](Get-RaymanMapValue -Map $record -Key 'last_yunyi_base_url' -Default '')
        last_yunyi_success_at = [string](Get-RaymanMapValue -Map $record -Key 'last_yunyi_success_at' -Default '')
        last_yunyi_config_ready = [bool](Get-RaymanMapValue -Map $record -Key 'last_yunyi_config_ready' -Default $false)
        last_yunyi_reuse_reason = [string](Get-RaymanMapValue -Map $record -Key 'last_yunyi_reuse_reason' -Default '')
        last_yunyi_base_url_source = [string](Get-RaymanMapValue -Map $record -Key 'last_yunyi_base_url_source' -Default '')
        latest_native_session = ConvertTo-RaymanCodexNativeSessionSummary -InputObject (Get-RaymanMapValue -Map $record -Key 'latest_native_session' -Default $null)
    }

    $accounts[$aliasKey] = $updated
    $registry.accounts = $accounts
    Save-RaymanCodexRegistry -Registry $registry | Out-Null
    return [pscustomobject]$updated
}

function Set-RaymanCodexAccountYunyiMetadata {
    param(
        [string]$Alias,
        [string]$BaseUrl = '',
        [string]$SuccessAt = '',
        [Nullable[bool]]$ConfigReady = $null,
        [string]$ReuseReason = '',
        [string]$BaseUrlSource = ''
    )

    $normalized = Normalize-RaymanCodexAlias -Alias $Alias
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }

    $record = Ensure-RaymanCodexAccount -Alias $normalized
    $registry = Get-RaymanCodexRegistry
    $accounts = ConvertTo-RaymanStringKeyMap -InputObject $registry.accounts
    $aliasKey = Get-RaymanCodexAliasKey -Alias $normalized

    $updated = [ordered]@{
        alias = [string](Get-RaymanMapValue -Map $record -Key 'alias' -Default $normalized)
        alias_key = [string](Get-RaymanMapValue -Map $record -Key 'alias_key' -Default $aliasKey)
        safe_alias = [string](Get-RaymanMapValue -Map $record -Key 'safe_alias' -Default (ConvertTo-RaymanSafeNamespace -Value $normalized))
        codex_home = [string](Get-RaymanMapValue -Map $record -Key 'codex_home' -Default (Get-RaymanCodexAccountHomePath -Alias $normalized))
        auth_scope = Normalize-RaymanCodexAuthScope -Scope ([string](Get-RaymanMapValue -Map $record -Key 'auth_scope' -Default ''))
        default_profile = [string](Get-RaymanMapValue -Map $record -Key 'default_profile' -Default '')
        auth_mode_last = Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $record -Key 'auth_mode_last' -Default ''))
        last_status = [string](Get-RaymanMapValue -Map $record -Key 'last_status' -Default '')
        last_checked_at = [string](Get-RaymanMapValue -Map $record -Key 'last_checked_at' -Default '')
        last_login_mode = [string](Get-RaymanMapValue -Map $record -Key 'last_login_mode' -Default '')
        last_login_strategy = [string](Get-RaymanMapValue -Map $record -Key 'last_login_strategy' -Default '')
        last_login_prompt_classification = [string](Get-RaymanMapValue -Map $record -Key 'last_login_prompt_classification' -Default '')
        last_login_started_at = [string](Get-RaymanMapValue -Map $record -Key 'last_login_started_at' -Default '')
        last_login_finished_at = [string](Get-RaymanMapValue -Map $record -Key 'last_login_finished_at' -Default '')
        last_login_success = [bool](Get-RaymanMapValue -Map $record -Key 'last_login_success' -Default $false)
        desktop_target_mode = Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $record -Key 'desktop_target_mode' -Default ''))
        desktop_saved_token_reused = [bool](Get-RaymanMapValue -Map $record -Key 'desktop_saved_token_reused' -Default $false)
        desktop_saved_token_source = [string](Get-RaymanMapValue -Map $record -Key 'desktop_saved_token_source' -Default '')
        desktop_status_command = [string](Get-RaymanMapValue -Map $record -Key 'desktop_status_command' -Default '')
        desktop_status_quota_visible = [bool](Get-RaymanMapValue -Map $record -Key 'desktop_status_quota_visible' -Default $false)
        desktop_status_reason = [string](Get-RaymanMapValue -Map $record -Key 'desktop_status_reason' -Default '')
        desktop_config_conflict = [string](Get-RaymanMapValue -Map $record -Key 'desktop_config_conflict' -Default '')
        desktop_unsynced_reason = [string](Get-RaymanMapValue -Map $record -Key 'desktop_unsynced_reason' -Default '')
        desktop_status_checked_at = [string](Get-RaymanMapValue -Map $record -Key 'desktop_status_checked_at' -Default '')
        last_yunyi_base_url = if ([string]::IsNullOrWhiteSpace([string]$BaseUrl)) { [string](Get-RaymanMapValue -Map $record -Key 'last_yunyi_base_url' -Default '') } else { [string]$BaseUrl }
        last_yunyi_success_at = if ([string]::IsNullOrWhiteSpace([string]$SuccessAt)) { [string](Get-RaymanMapValue -Map $record -Key 'last_yunyi_success_at' -Default '') } else { [string]$SuccessAt }
        last_yunyi_config_ready = if ($null -eq $ConfigReady) { [bool](Get-RaymanMapValue -Map $record -Key 'last_yunyi_config_ready' -Default $false) } else { [bool]$ConfigReady }
        last_yunyi_reuse_reason = if ($PSBoundParameters.ContainsKey('ReuseReason')) { [string]$ReuseReason } else { [string](Get-RaymanMapValue -Map $record -Key 'last_yunyi_reuse_reason' -Default '') }
        last_yunyi_base_url_source = if ($PSBoundParameters.ContainsKey('BaseUrlSource')) { [string]$BaseUrlSource } else { [string](Get-RaymanMapValue -Map $record -Key 'last_yunyi_base_url_source' -Default '') }
        latest_native_session = ConvertTo-RaymanCodexNativeSessionSummary -InputObject (Get-RaymanMapValue -Map $record -Key 'latest_native_session' -Default $null)
    }

    $accounts[$aliasKey] = $updated
    $registry.accounts = $accounts
    Save-RaymanCodexRegistry -Registry $registry | Out-Null
    return [pscustomobject]$updated
}

function Set-RaymanCodexAccountDesktopStatusValidation {
    param(
        [string]$Alias,
        [string]$StatusCommand = '/status',
        [bool]$QuotaVisible = $false,
        [string]$Reason = '',
        [string]$CheckedAt = '',
        [string]$ConfigConflict = '',
        [string]$UnsyncedReason = ''
    )

    $normalized = Normalize-RaymanCodexAlias -Alias $Alias
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }

    $record = Ensure-RaymanCodexAccount -Alias $normalized
    $registry = Get-RaymanCodexRegistry
    $accounts = ConvertTo-RaymanStringKeyMap -InputObject $registry.accounts
    $aliasKey = Get-RaymanCodexAliasKey -Alias $normalized
    $checkedAtValue = if ([string]::IsNullOrWhiteSpace([string]$CheckedAt)) { (Get-Date).ToString('o') } else { [string]$CheckedAt }

    $updated = [ordered]@{
        alias = [string](Get-RaymanMapValue -Map $record -Key 'alias' -Default $normalized)
        alias_key = [string](Get-RaymanMapValue -Map $record -Key 'alias_key' -Default $aliasKey)
        safe_alias = [string](Get-RaymanMapValue -Map $record -Key 'safe_alias' -Default (ConvertTo-RaymanSafeNamespace -Value $normalized))
        codex_home = [string](Get-RaymanMapValue -Map $record -Key 'codex_home' -Default (Get-RaymanCodexAccountHomePath -Alias $normalized))
        auth_scope = Resolve-RaymanCodexAuthScopeForMode -ExistingScope ([string](Get-RaymanMapValue -Map $record -Key 'auth_scope' -Default '')) -Mode ([string](Get-RaymanMapValue -Map $record -Key 'auth_mode_last' -Default ''))
        default_profile = [string](Get-RaymanMapValue -Map $record -Key 'default_profile' -Default '')
        auth_mode_last = Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $record -Key 'auth_mode_last' -Default ''))
        last_status = [string](Get-RaymanMapValue -Map $record -Key 'last_status' -Default '')
        last_checked_at = [string](Get-RaymanMapValue -Map $record -Key 'last_checked_at' -Default '')
        last_login_mode = [string](Get-RaymanMapValue -Map $record -Key 'last_login_mode' -Default '')
        last_login_strategy = [string](Get-RaymanMapValue -Map $record -Key 'last_login_strategy' -Default '')
        last_login_prompt_classification = [string](Get-RaymanMapValue -Map $record -Key 'last_login_prompt_classification' -Default '')
        last_login_started_at = [string](Get-RaymanMapValue -Map $record -Key 'last_login_started_at' -Default '')
        last_login_finished_at = [string](Get-RaymanMapValue -Map $record -Key 'last_login_finished_at' -Default '')
        last_login_success = [bool](Get-RaymanMapValue -Map $record -Key 'last_login_success' -Default $false)
        desktop_target_mode = Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $record -Key 'desktop_target_mode' -Default ''))
        desktop_saved_token_reused = [bool](Get-RaymanMapValue -Map $record -Key 'desktop_saved_token_reused' -Default $false)
        desktop_saved_token_source = [string](Get-RaymanMapValue -Map $record -Key 'desktop_saved_token_source' -Default '')
        desktop_status_command = [string]$StatusCommand
        desktop_status_quota_visible = [bool]$QuotaVisible
        desktop_status_reason = [string]$Reason
        desktop_config_conflict = if ([string]::IsNullOrWhiteSpace([string]$ConfigConflict)) { [string](Get-RaymanMapValue -Map $record -Key 'desktop_config_conflict' -Default '') } else { [string]$ConfigConflict }
        desktop_unsynced_reason = if ([string]::IsNullOrWhiteSpace([string]$UnsyncedReason)) { [string](Get-RaymanMapValue -Map $record -Key 'desktop_unsynced_reason' -Default '') } else { [string]$UnsyncedReason }
        desktop_status_checked_at = [string]$checkedAtValue
        latest_native_session = ConvertTo-RaymanCodexNativeSessionSummary -InputObject (Get-RaymanMapValue -Map $record -Key 'latest_native_session' -Default $null)
    }

    $accounts[$aliasKey] = $updated
    $registry.accounts = $accounts
    Save-RaymanCodexRegistry -Registry $registry | Out-Null
    return [pscustomobject]$updated
}

function Set-RaymanCodexAccountDefaultProfile {
    param(
        [string]$Alias,
        [string]$DefaultProfile = ''
    )

    $normalized = Normalize-RaymanCodexAlias -Alias $Alias
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw 'Codex alias is required.'
    }

    $registry = Get-RaymanCodexRegistry
    $accounts = ConvertTo-RaymanStringKeyMap -InputObject $registry.accounts
    $aliasKey = Get-RaymanCodexAliasKey -Alias $normalized
    $existing = Get-RaymanMapValue -Map $accounts -Key $aliasKey -Default $null
    if ($null -eq $existing) {
        throw ("Unknown Codex alias '{0}'." -f $normalized)
    }

    $updated = [ordered]@{
        alias = [string](Get-RaymanMapValue -Map $existing -Key 'alias' -Default $normalized)
        alias_key = [string](Get-RaymanMapValue -Map $existing -Key 'alias_key' -Default $aliasKey)
        safe_alias = [string](Get-RaymanMapValue -Map $existing -Key 'safe_alias' -Default (ConvertTo-RaymanSafeNamespace -Value $normalized))
        codex_home = [string](Get-RaymanMapValue -Map $existing -Key 'codex_home' -Default (Get-RaymanCodexAccountHomePath -Alias $normalized))
        auth_scope = Resolve-RaymanCodexAuthScopeForMode -ExistingScope ([string](Get-RaymanMapValue -Map $existing -Key 'auth_scope' -Default '')) -Mode ([string](Get-RaymanMapValue -Map $existing -Key 'auth_mode_last' -Default ''))
        default_profile = [string]$DefaultProfile
        auth_mode_last = Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $existing -Key 'auth_mode_last' -Default ''))
        last_status = [string](Get-RaymanMapValue -Map $existing -Key 'last_status' -Default '')
        last_checked_at = [string](Get-RaymanMapValue -Map $existing -Key 'last_checked_at' -Default '')
        last_login_mode = [string](Get-RaymanMapValue -Map $existing -Key 'last_login_mode' -Default '')
        last_login_strategy = [string](Get-RaymanMapValue -Map $existing -Key 'last_login_strategy' -Default '')
        last_login_prompt_classification = [string](Get-RaymanMapValue -Map $existing -Key 'last_login_prompt_classification' -Default '')
        last_login_started_at = [string](Get-RaymanMapValue -Map $existing -Key 'last_login_started_at' -Default '')
        last_login_finished_at = [string](Get-RaymanMapValue -Map $existing -Key 'last_login_finished_at' -Default '')
        last_login_success = [bool](Get-RaymanMapValue -Map $existing -Key 'last_login_success' -Default $false)
        desktop_status_command = [string](Get-RaymanMapValue -Map $existing -Key 'desktop_status_command' -Default '')
        desktop_status_quota_visible = [bool](Get-RaymanMapValue -Map $existing -Key 'desktop_status_quota_visible' -Default $false)
        desktop_status_reason = [string](Get-RaymanMapValue -Map $existing -Key 'desktop_status_reason' -Default '')
        desktop_status_checked_at = [string](Get-RaymanMapValue -Map $existing -Key 'desktop_status_checked_at' -Default '')
        latest_native_session = ConvertTo-RaymanCodexNativeSessionSummary -InputObject (Get-RaymanMapValue -Map $existing -Key 'latest_native_session' -Default $null)
    }

    $accounts[$aliasKey] = $updated
    $registry.accounts = $accounts
    Save-RaymanCodexRegistry -Registry $registry | Out-Null
    return [pscustomobject]$updated
}

function Get-RaymanCodexAliasWorkspaceReferences {
    param(
        [string]$Alias
    )

    $normalized = Normalize-RaymanCodexAlias -Alias $Alias
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return @()
    }

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($record in @(Get-RaymanCodexWorkspaceRecords)) {
        if ($null -eq $record) {
            continue
        }

        $workspaceRoot = [string](Get-RaymanMapValue -Map $record -Key 'workspace_root' -Default '')
        if ([string]::IsNullOrWhiteSpace($workspaceRoot)) {
            continue
        }

        $workspaceExists = $false
        try {
            $workspaceExists = Test-Path -LiteralPath $workspaceRoot -PathType Container
        } catch {
            $workspaceExists = $false
        }

        $binding = $null
        if ($workspaceExists) {
            try {
                $binding = Get-RaymanCodexWorkspaceBinding -WorkspaceRoot $workspaceRoot
            } catch {
                $binding = $null
            }
        }

        $bindingAlias = Normalize-RaymanCodexAlias -Alias ([string](Get-RaymanMapValue -Map $binding -Key 'account_alias' -Default ''))
        $recordAlias = Normalize-RaymanCodexAlias -Alias ([string](Get-RaymanMapValue -Map $record -Key 'last_account_alias' -Default ''))
        $items.Add([pscustomobject]@{
                workspace_root = $workspaceRoot
                display_name = [string](Get-RaymanMapValue -Map $record -Key 'display_name' -Default (Split-Path -Leaf $workspaceRoot))
                workspace_exists = $workspaceExists
                env_path = Join-Path $workspaceRoot '.rayman.env.ps1'
                registry_alias = [string](Get-RaymanMapValue -Map $record -Key 'last_account_alias' -Default '')
                registry_profile = [string](Get-RaymanMapValue -Map $record -Key 'last_profile' -Default '')
                registry_matches = (-not [string]::IsNullOrWhiteSpace($recordAlias) -and $recordAlias -ieq $normalized)
                binding_alias = [string](Get-RaymanMapValue -Map $binding -Key 'account_alias' -Default '')
                binding_profile = [string](Get-RaymanMapValue -Map $binding -Key 'profile' -Default '')
                binding_matches = (-not [string]::IsNullOrWhiteSpace($bindingAlias) -and $bindingAlias -ieq $normalized)
            }) | Out-Null
    }

    return @($items.ToArray())
}

function Remove-RaymanCodexAlias {
    param(
        [string]$Alias,
        [switch]$DeleteHome
    )

    $normalized = Normalize-RaymanCodexAlias -Alias $Alias
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw 'Codex alias is required.'
    }

    $registry = Get-RaymanCodexRegistry
    $accounts = ConvertTo-RaymanStringKeyMap -InputObject $registry.accounts
    $aliasKey = Get-RaymanCodexAliasKey -Alias $normalized
    $existing = Get-RaymanMapValue -Map $accounts -Key $aliasKey -Default $null
    if ($null -eq $existing) {
        return [pscustomobject]@{
            alias = $normalized
            removed = $false
            deleted_home = $false
            codex_home = ''
            cleared_registry_workspaces = 0
            cleared_workspace_bindings = @()
        }
    }

    $clearedWorkspaceBindings = New-Object System.Collections.Generic.List[string]
    foreach ($reference in @(Get-RaymanCodexAliasWorkspaceReferences -Alias $normalized)) {
        if (-not [bool]$reference.workspace_exists) {
            continue
        }
        if (-not [bool]$reference.binding_matches) {
            continue
        }

        Set-RaymanCodexWorkspaceBinding -WorkspaceRoot ([string]$reference.workspace_root) -AccountAlias '' -Profile '' | Out-Null
        $clearedWorkspaceBindings.Add([string]$reference.workspace_root) | Out-Null
    }

    $registry = Get-RaymanCodexRegistry
    $accounts = ConvertTo-RaymanStringKeyMap -InputObject $registry.accounts
    $workspaces = ConvertTo-RaymanStringKeyMap -InputObject $registry.workspaces
    $registryClearedCount = 0
    foreach ($key in @($workspaces.Keys)) {
        $record = Get-RaymanMapValue -Map $workspaces -Key $key -Default $null
        $recordAlias = Normalize-RaymanCodexAlias -Alias ([string](Get-RaymanMapValue -Map $record -Key 'last_account_alias' -Default ''))
        if ([string]::IsNullOrWhiteSpace($recordAlias) -or -not ($recordAlias -ieq $normalized)) {
            continue
        }

        $workspaces[$key] = [ordered]@{
            normalized_root = [string](Get-RaymanMapValue -Map $record -Key 'normalized_root' -Default $key)
            workspace_root = [string](Get-RaymanMapValue -Map $record -Key 'workspace_root' -Default '')
            display_name = [string](Get-RaymanMapValue -Map $record -Key 'display_name' -Default '')
            last_account_alias = ''
            last_profile = ''
            last_used_at = [string](Get-RaymanMapValue -Map $record -Key 'last_used_at' -Default '')
        }
        $registryClearedCount++
    }

    $accounts.Remove($aliasKey) | Out-Null
    $registry.accounts = $accounts
    $registry.workspaces = $workspaces
    Save-RaymanCodexRegistry -Registry $registry | Out-Null

    $codexHome = [string](Get-RaymanMapValue -Map $existing -Key 'codex_home' -Default (Get-RaymanCodexAccountHomePath -Alias $normalized))
    $deletedHome = $false
    if ($DeleteHome -and -not [string]::IsNullOrWhiteSpace($codexHome) -and (Test-Path -LiteralPath $codexHome)) {
        Remove-Item -LiteralPath $codexHome -Recurse -Force
        $deletedHome = $true
    }

    return [pscustomobject]@{
        alias = $normalized
        removed = $true
        deleted_home = $deletedHome
        codex_home = $codexHome
        cleared_registry_workspaces = $registryClearedCount
        cleared_workspace_bindings = @($clearedWorkspaceBindings.ToArray())
    }
}

function Resolve-RaymanCodexWorkspacePath {
    param(
        [string]$WorkspaceRoot
    )

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        return ''
    }

    $candidate = ([string]$WorkspaceRoot).Trim()
    if ($candidate -match '^/mnt/([A-Za-z])(?:/(.*))?$') {
        $drive = ([string]$Matches[1]).ToUpperInvariant()
        $rest = if ($Matches.Count -gt 2) { [string]$Matches[2] } else { '' }
        if ([string]::IsNullOrWhiteSpace($rest)) {
            return ('{0}:\' -f $drive)
        }
        return ('{0}:\{1}' -f $drive, ($rest -replace '/', '\'))
    }

    try {
        return [System.IO.Path]::GetFullPath($candidate)
    } catch {
        return $candidate
    }
}

function Get-RaymanCodexWorkspaceKey {
    param(
        [string]$WorkspaceRoot
    )

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        return ''
    }
    return (Get-RaymanPathComparisonValue -PathValue $WorkspaceRoot)
}

function Resolve-RaymanCodexWorkspaceRecordKey {
    param(
        [object]$WorkspaceMap,
        [string]$WorkspaceRoot
    )

    $requestedKey = Get-RaymanCodexWorkspaceKey -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace($requestedKey)) {
        return ''
    }

    $map = ConvertTo-RaymanStringKeyMap -InputObject $WorkspaceMap
    foreach ($candidateKey in $map.Keys) {
        $candidate = $map[$candidateKey]
        $candidateRoot = [string](Get-RaymanMapValue -Map $candidate -Key 'workspace_root' -Default '')
        if (Test-RaymanPathsEquivalent -LeftPath $WorkspaceRoot -RightPath $candidateRoot) {
            return [string]$candidateKey
        }
        if ([string]$candidateKey -eq $requestedKey) {
            return [string]$candidateKey
        }
    }

    return $requestedKey
}

function Get-RaymanCodexWorkspaceRecord {
    param(
        [string]$WorkspaceRoot
    )

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        return $null
    }

    $registry = Get-RaymanCodexRegistry
    $key = Resolve-RaymanCodexWorkspaceRecordKey -WorkspaceMap $registry.workspaces -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace($key)) {
        return $null
    }
    return (Get-RaymanMapValue -Map $registry.workspaces -Key $key -Default $null)
}

function Set-RaymanCodexWorkspaceRecord {
    param(
        [string]$WorkspaceRoot,
        [string]$AccountAlias = '',
        [string]$Profile = ''
    )

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        throw 'Workspace root is required.'
    }

    try {
        $resolvedWorkspaceRoot = Resolve-RaymanCodexWorkspacePath -WorkspaceRoot $WorkspaceRoot
    } catch {
        $resolvedWorkspaceRoot = [string]$WorkspaceRoot
    }

    $registry = Get-RaymanCodexRegistry
    $workspaces = ConvertTo-RaymanStringKeyMap -InputObject $registry.workspaces
    $resolvedKey = Resolve-RaymanCodexWorkspaceRecordKey -WorkspaceMap $workspaces -WorkspaceRoot $resolvedWorkspaceRoot
    $existing = Get-RaymanMapValue -Map $workspaces -Key $resolvedKey -Default $null

    foreach ($candidateKey in @($workspaces.Keys)) {
        if ([string]$candidateKey -eq $resolvedKey) {
            continue
        }
        $candidate = $workspaces[$candidateKey]
        $candidateRoot = [string](Get-RaymanMapValue -Map $candidate -Key 'workspace_root' -Default '')
        if (Test-RaymanPathsEquivalent -LeftPath $candidateRoot -RightPath $resolvedWorkspaceRoot) {
            $workspaces.Remove($candidateKey)
        }
    }

    $record = [ordered]@{
        normalized_root = $resolvedKey
        workspace_root = $resolvedWorkspaceRoot
        display_name = Split-Path -Leaf $resolvedWorkspaceRoot
        last_account_alias = if ([string]::IsNullOrWhiteSpace($AccountAlias) -and $null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'last_account_alias' -Default '') } else { [string]$AccountAlias }
        last_profile = if ([string]::IsNullOrWhiteSpace($Profile) -and $null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'last_profile' -Default '') } else { [string]$Profile }
        last_used_at = (Get-Date).ToString('o')
    }

    $workspaces[$resolvedKey] = $record
    $registry.workspaces = $workspaces
    Save-RaymanCodexRegistry -Registry $registry | Out-Null
    return [pscustomobject]$record
}

function Get-RaymanCodexWorkspaceBinding {
    param(
        [string]$WorkspaceRoot
    )

    return [pscustomobject]@{
        account_alias = [string](Get-RaymanWorkspaceEnvString -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_CODEX_ACCOUNT_ALIAS' -Default '')
        profile = [string](Get-RaymanWorkspaceEnvString -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_CODEX_PROFILE' -Default '')
    }
}

function Set-RaymanCodexWorkspaceBinding {
    param(
        [string]$WorkspaceRoot,
        [string]$AccountAlias = '',
        [string]$Profile = ''
    )

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        throw 'Workspace root is required.'
    }

    try {
        $resolvedWorkspaceRoot = Resolve-RaymanCodexWorkspacePath -WorkspaceRoot $WorkspaceRoot
    } catch {
        $resolvedWorkspaceRoot = [string]$WorkspaceRoot
    }

    if (-not (Test-Path -LiteralPath $resolvedWorkspaceRoot -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $resolvedWorkspaceRoot | Out-Null
    }

    $envFile = Join-Path $resolvedWorkspaceRoot '.rayman.env.ps1'
    Set-RaymanManagedTextBlock -Path $envFile -BeginMarker '# RAYMAN:CODEX:BEGIN' -EndMarker '# RAYMAN:CODEX:END' -Lines @(
        '# Rayman Codex workspace binding (managed by rayman codex).',
        ('$env:RAYMAN_CODEX_ACCOUNT_ALIAS = ''{0}''' -f ([string]$AccountAlias -replace "'", "''")),
        ('$env:RAYMAN_CODEX_PROFILE = ''{0}''' -f ([string]$Profile -replace "'", "''"))
    ) | Out-Null

    Set-RaymanCodexWorkspaceRecord -WorkspaceRoot $resolvedWorkspaceRoot -AccountAlias $AccountAlias -Profile $Profile | Out-Null
    return [pscustomobject]@{
        workspace_root = $resolvedWorkspaceRoot
        env_path = $envFile
        account_alias = [string]$AccountAlias
        profile = [string]$Profile
    }
}

function Get-RaymanCodexWorkspaceRecords {
    $registry = Get-RaymanCodexRegistry
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($key in @((ConvertTo-RaymanStringKeyMap -InputObject $registry.workspaces).Keys | Sort-Object)) {
        $items.Add((Get-RaymanMapValue -Map $registry.workspaces -Key $key -Default $null)) | Out-Null
    }
    return @($items.ToArray())
}

function Get-RaymanVsCodeStoragePath {
    $appData = [Environment]::GetEnvironmentVariable('APPDATA')
    if ([string]::IsNullOrWhiteSpace($appData)) {
        $userHome = Get-RaymanUserHomePath
        if (-not [string]::IsNullOrWhiteSpace($userHome)) {
            $appData = Join-Path $userHome 'AppData\Roaming'
        }
    }
    if ([string]::IsNullOrWhiteSpace($appData)) {
        return ''
    }
    return (Join-Path $appData 'Code\User\globalStorage\storage.json')
}

function Convert-RaymanVsCodeWorkspaceUriToPath {
    param(
        [string]$WorkspaceUri
    )

    if ([string]::IsNullOrWhiteSpace($WorkspaceUri)) {
        return ''
    }

    $workspaceUriText = ([string]$WorkspaceUri).Trim()

    if ($workspaceUriText -match '(?i)^file:///(?<path>.+)$') {
        $rawPath = [System.Uri]::UnescapeDataString([string]$Matches['path'])
        if ($rawPath -match '^/[A-Za-z]:/') {
            $rawPath = $rawPath.Substring(1)
        }
        try {
            return (Resolve-RaymanCodexWorkspacePath -WorkspaceRoot $rawPath)
        } catch {
            return [string]$rawPath
        }
    }

    if ($workspaceUriText -match '(?i)^vscode-remote://[^/]+(?<path>/.*)$') {
        $remotePath = [System.Uri]::UnescapeDataString([string]$Matches['path'])
        if (-not [string]::IsNullOrWhiteSpace($remotePath)) {
            try {
                return (Resolve-RaymanCodexWorkspacePath -WorkspaceRoot $remotePath)
            } catch {
                return [string]$remotePath
            }
        }
    }

    try {
        $uri = [System.Uri]$workspaceUriText
    } catch {
        return ''
    }

    if ($uri.Scheme -eq 'file') {
        $fallbackPath = [string]$uri.LocalPath
        if ($fallbackPath -match '^/[A-Za-z]:/') {
            $fallbackPath = $fallbackPath.Substring(1)
        }
        try {
            return (Resolve-RaymanCodexWorkspacePath -WorkspaceRoot $fallbackPath)
        } catch {
            return [string]$fallbackPath
        }
    }

    return ''
}

function Get-RaymanVsCodeUserProfileState {
    param(
        [string]$WorkspaceRoot = ''
    )

    $resolvedWorkspaceRoot = ''
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        try {
            $resolvedWorkspaceRoot = Resolve-RaymanCodexWorkspacePath -WorkspaceRoot $WorkspaceRoot
        } catch {
            $resolvedWorkspaceRoot = [string]$WorkspaceRoot
        }
    }

    $storagePath = Get-RaymanVsCodeStoragePath
    $result = [ordered]@{
        available = $false
        storage_path = $storagePath
        workspace_root = $resolvedWorkspaceRoot
        status = 'storage_missing'
        profile_name = ''
        profile_location = ''
        profile_source = 'none'
        profile_is_default = $false
        profile_detected = $false
        matched_workspace_uri = ''
        matched_workspace_path = ''
        profiles = @()
        matches = @()
    }

    if ([string]::IsNullOrWhiteSpace($storagePath) -or -not (Test-Path -LiteralPath $storagePath -PathType Leaf)) {
        return [pscustomobject]$result
    }

    $storage = $null
    try {
        $storage = Get-Content -LiteralPath $storagePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $result.status = 'storage_parse_failed'
        return [pscustomobject]$result
    }

    $result.available = $true
    $profileLookup = @{}
    $profiles = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @((Get-RaymanMapValue -Map $storage -Key 'userDataProfiles' -Default @()))) {
        $location = [string](Get-RaymanMapValue -Map $entry -Key 'location' -Default '')
        $name = [string](Get-RaymanMapValue -Map $entry -Key 'name' -Default '')
        if ([string]::IsNullOrWhiteSpace($location) -or [string]::IsNullOrWhiteSpace($name)) {
            continue
        }
        $profile = [pscustomobject]@{
            location = $location
            name = $name
            icon = [string](Get-RaymanMapValue -Map $entry -Key 'icon' -Default '')
        }
        $profiles.Add($profile) | Out-Null
        $profileLookup[$location] = $profile
    }
    $result.profiles = @($profiles.ToArray())

    if ([string]::IsNullOrWhiteSpace($resolvedWorkspaceRoot)) {
        $result.status = if (@($result.profiles).Count -gt 0) { 'profiles_available_workspace_missing' } else { 'workspace_missing' }
        return [pscustomobject]$result
    }

    $associationsRoot = Get-RaymanMapValue -Map $storage -Key 'profileAssociations' -Default $null
    $workspaceAssociations = ConvertTo-RaymanStringKeyMap -InputObject (Get-RaymanMapValue -Map $associationsRoot -Key 'workspaces' -Default $null)
    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($workspaceUri in @($workspaceAssociations.Keys)) {
        $workspacePath = Convert-RaymanVsCodeWorkspaceUriToPath -WorkspaceUri ([string]$workspaceUri)
        if ([string]::IsNullOrWhiteSpace($workspacePath)) {
            continue
        }
        if (-not (Test-RaymanPathsEquivalent -LeftPath $workspacePath -RightPath $resolvedWorkspaceRoot)) {
            continue
        }

        $profileLocation = [string]$workspaceAssociations[$workspaceUri]
        $isDefault = ($profileLocation -eq '__default__profile__')
        $profile = if ($profileLookup.ContainsKey($profileLocation)) { $profileLookup[$profileLocation] } else { $null }
        $matches.Add([pscustomobject]@{
                workspace_uri = [string]$workspaceUri
                workspace_path = [string]$workspacePath
                profile_location = $profileLocation
                profile_name = if ($null -ne $profile) { [string]$profile.name } else { '' }
                profile_is_default = $isDefault
                uri_kind = if ([string]$workspaceUri -like 'file://*') { 'file' } else { 'remote' }
            }) | Out-Null
    }

    $result.matches = @($matches.ToArray())
    if (@($result.matches).Count -eq 0) {
        $result.status = if (@($result.profiles).Count -gt 0) { 'workspace_unmatched' } else { 'profiles_unavailable' }
        return [pscustomobject]$result
    }

    $selectedMatch = @(
        $result.matches |
        Sort-Object `
            @{ Expression = { if (-not [bool]$_.profile_is_default) { 0 } else { 1 } } }, `
            @{ Expression = { if ([string]$_.uri_kind -eq 'file') { 0 } else { 1 } } }, `
            @{ Expression = { [string]$_.workspace_uri } }
    ) | Select-Object -First 1

    if ($null -eq $selectedMatch) {
        $result.status = 'workspace_unmatched'
        return [pscustomobject]$result
    }

    $result.matched_workspace_uri = [string]$selectedMatch.workspace_uri
    $result.matched_workspace_path = [string]$selectedMatch.workspace_path
    $result.profile_location = [string]$selectedMatch.profile_location
    $result.profile_is_default = [bool]$selectedMatch.profile_is_default

    if ([bool]$selectedMatch.profile_is_default) {
        $result.profile_source = 'workspace_association_default'
        $result.status = 'workspace_default_profile'
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$selectedMatch.profile_name)) {
        $result.profile_name = [string]$selectedMatch.profile_name
        $result.profile_source = 'workspace_association'
        $result.profile_detected = $true
        $result.status = 'workspace_profile_detected'
    } else {
        $result.profile_source = 'workspace_association_unknown'
        $result.status = 'workspace_profile_unknown'
    }

    return [pscustomobject]$result
}

function Test-RaymanCodexArgsContainProfile {
    param(
        [string[]]$ArgumentList = @()
    )

    $args = @($ArgumentList)
    for ($i = 0; $i -lt $args.Count; $i++) {
        $token = [string]$args[$i]
        if ($token -eq '-p' -or $token -eq '--profile') {
            return $true
        }
        if ($token -match '^(--profile|-p)=') {
            return $true
        }
    }
    return $false
}

function Add-RaymanCodexProfileArguments {
    param(
        [string[]]$ArgumentList = @(),
        [string]$Profile = ''
    )

    $args = @($ArgumentList)
    if ([string]::IsNullOrWhiteSpace($Profile)) {
        return $args
    }
    if (Test-RaymanCodexArgsContainProfile -ArgumentList $args) {
        return $args
    }
    return @('--profile', [string]$Profile) + $args
}

function Use-RaymanTemporaryEnvironment {
    param(
        [hashtable]$EnvironmentOverrides = @{},
        [scriptblock]$ScriptBlock
    )

    if ($null -eq $ScriptBlock) {
        throw 'ScriptBlock is required.'
    }

    $backup = @{}
    foreach ($name in @($EnvironmentOverrides.Keys)) {
        $backup[$name] = [Environment]::GetEnvironmentVariable([string]$name)
        $value = $EnvironmentOverrides[$name]
        if ($null -eq $value) {
            [Environment]::SetEnvironmentVariable([string]$name, $null)
        } else {
            [Environment]::SetEnvironmentVariable([string]$name, [string]$value)
        }
    }

    try {
        return (& $ScriptBlock)
    } finally {
        foreach ($name in @($backup.Keys)) {
            $previousValue = $backup[$name]
            if ($null -eq $previousValue) {
                [Environment]::SetEnvironmentVariable([string]$name, $null)
            } else {
                [Environment]::SetEnvironmentVariable([string]$name, [string]$previousValue)
            }
        }
    }
}

function Get-RaymanCodexVsCodeExtensionsRoot {
    $override = [Environment]::GetEnvironmentVariable('RAYMAN_VSCODE_EXTENSIONS_ROOT')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        try {
            return [System.IO.Path]::GetFullPath([string]$override)
        } catch {
            return [string]$override
        }
    }

    $userHome = Get-RaymanUserHomePath
    if ([string]::IsNullOrWhiteSpace($userHome)) {
        return ''
    }

    return (Join-Path $userHome '.vscode\extensions')
}

function Get-RaymanCodexNpmGlobalBinRoot {
    $override = [Environment]::GetEnvironmentVariable('RAYMAN_NPM_GLOBAL_BIN_ROOT')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        try {
            return [System.IO.Path]::GetFullPath([string]$override)
        } catch {
            return [string]$override
        }
    }

    $appData = [Environment]::GetEnvironmentVariable('APPDATA')
    if ([string]::IsNullOrWhiteSpace($appData)) {
        $userHome = Get-RaymanUserHomePath
        if (-not [string]::IsNullOrWhiteSpace($userHome)) {
            $appData = Join-Path $userHome 'AppData\Roaming'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($appData)) {
        return (Join-Path $appData 'npm')
    }

    return ''
}

function Get-RaymanCodexVsCodeBundledSearchPath {
    $extensionsRoot = Get-RaymanCodexVsCodeExtensionsRoot
    if ([string]::IsNullOrWhiteSpace($extensionsRoot)) {
        return 'VS Code ChatGPT extension bundled codex location'
    }

    return (Join-Path $extensionsRoot 'openai.chatgpt-*\bin\windows-x86_64\codex.exe')
}

function Get-RaymanCodexCommandNotFoundMessage {
    $searchPath = Get-RaymanCodexVsCodeBundledSearchPath
    return ('codex command not found. Checked PATH and VS Code ChatGPT extension bundled codex location ({0}).' -f $searchPath)
}

function Test-RaymanVsCodeBundledCodexPath {
    param(
        [string]$CodexPath
    )

    if ([string]::IsNullOrWhiteSpace($CodexPath)) {
        return $false
    }

    $normalizedPath = ([string]$CodexPath).Replace('/', '\').ToLowerInvariant()
    return ($normalizedPath -match '\\openai\.chatgpt-[^\\]+\\bin\\windows-x86_64\\codex(\.exe|\.cmd|\.ps1)?$')
}

function Get-RaymanNpmGlobalCodexCommandInfo {
    $binRoot = Get-RaymanCodexNpmGlobalBinRoot
    if ([string]::IsNullOrWhiteSpace($binRoot) -or -not (Test-Path -LiteralPath $binRoot -PathType Container)) {
        return [pscustomobject]@{
            available = $false
            path = ''
            name = 'codex'
            resolution_source = 'not_available'
        }
    }

    foreach ($candidateName in @('codex.cmd', 'codex.ps1', 'codex')) {
        $candidatePath = Join-Path $binRoot $candidateName
        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            continue
        }

        $resolvedPath = ''
        try {
            $resolvedPath = [System.IO.Path]::GetFullPath($candidatePath)
        } catch {
            $resolvedPath = [string]$candidatePath
        }

        return [pscustomobject]@{
            available = $true
            path = $resolvedPath
            name = [System.IO.Path]::GetFileName($resolvedPath)
            resolution_source = 'npm_global'
        }
    }

    return [pscustomobject]@{
        available = $false
        path = ''
        name = 'codex'
        resolution_source = 'not_available'
    }
}

function Get-RaymanVsCodeBundledCodexCommandInfo {
    if (-not (Test-RaymanCodexWindowsHost)) {
        return [pscustomobject]@{
            available = $false
            path = ''
            name = 'codex'
            resolution_source = 'not_available'
        }
    }

    $extensionsRoot = Get-RaymanCodexVsCodeExtensionsRoot
    if ([string]::IsNullOrWhiteSpace($extensionsRoot) -or -not (Test-Path -LiteralPath $extensionsRoot -PathType Container)) {
        return [pscustomobject]@{
            available = $false
            path = ''
            name = 'codex'
            resolution_source = 'not_available'
        }
    }

    $extensionDirs = @()
    try {
        $extensionDirs = @(Get-ChildItem -LiteralPath $extensionsRoot -Directory -Filter 'openai.chatgpt-*' -ErrorAction Stop | Sort-Object LastWriteTime -Descending)
    } catch {
        $extensionDirs = @()
    }

    foreach ($extensionDir in $extensionDirs) {
        $binDir = Join-Path ([string]$extensionDir.FullName) 'bin\windows-x86_64'
        foreach ($candidateName in @('codex.exe', 'codex.cmd', 'codex.ps1')) {
            $candidatePath = Join-Path $binDir $candidateName
            if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
                continue
            }

            $resolvedPath = ''
            try {
                $resolvedPath = [System.IO.Path]::GetFullPath($candidatePath)
            } catch {
                $resolvedPath = [string]$candidatePath
            }

            return [pscustomobject]@{
                available = $true
                path = $resolvedPath
                name = [System.IO.Path]::GetFileName($resolvedPath)
                resolution_source = 'vscode_extension'
            }
        }
    }

    return [pscustomobject]@{
        available = $false
        path = ''
        name = 'codex'
        resolution_source = 'not_available'
    }
}

function Get-RaymanCodexCommandInfo {
    $npmGlobalCodex = Get-RaymanNpmGlobalCodexCommandInfo
    $cmd = Get-Command 'codex' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd) {
        $path = ''
        if ($cmd.PSObject.Properties['Source'] -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            $path = [string]$cmd.Source
        } elseif ($cmd.PSObject.Properties['Path'] -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Path)) {
            $path = [string]$cmd.Path
        } else {
            $path = [string]$cmd.Name
        }

        $pathResolved = [pscustomobject]@{
            available = $true
            path = $path
            name = [string]$cmd.Name
            resolution_source = 'path'
        }

        if (Test-RaymanCodexWindowsHost) {
            $extension = ''
            try {
                $extension = [System.IO.Path]::GetExtension([string]$pathResolved.path)
            } catch {
                $extension = ''
            }

            if ($extension -ieq '.ps1') {
                $siblingCmd = [System.IO.Path]::ChangeExtension([string]$pathResolved.path, '.cmd')
                if (-not [string]::IsNullOrWhiteSpace($siblingCmd) -and (Test-Path -LiteralPath $siblingCmd -PathType Leaf)) {
                    $pathResolved = [pscustomobject]@{
                        available = $true
                        path = [System.IO.Path]::GetFullPath($siblingCmd)
                        name = [System.IO.Path]::GetFileName($siblingCmd)
                        resolution_source = 'path'
                    }
                }
            }
        }

        if ((Test-RaymanVsCodeBundledCodexPath -CodexPath ([string]$pathResolved.path)) -and [bool]$npmGlobalCodex.available) {
            return $npmGlobalCodex
        }

        return $pathResolved
    }

    if ([bool]$npmGlobalCodex.available) {
        return $npmGlobalCodex
    }

    $vscodeBundledCodex = Get-RaymanVsCodeBundledCodexCommandInfo
    if ([bool]$vscodeBundledCodex.available) {
        return $vscodeBundledCodex
    }

    return [pscustomobject]@{
        available = $false
        path = ''
        name = 'codex'
        resolution_source = 'not_found'
    }
}

function Get-RaymanPowerShellLauncherInfo {
    foreach ($name in @('powershell.exe', 'powershell', 'pwsh.exe', 'pwsh')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $cmd) {
            continue
        }

        $path = ''
        if ($cmd.PSObject.Properties['Source'] -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            $path = [string]$cmd.Source
        } elseif ($cmd.PSObject.Properties['Path'] -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Path)) {
            $path = [string]$cmd.Path
        } else {
            $path = [string]$cmd.Name
        }

        return [pscustomobject]@{
            available = $true
            path = $path
            name = [string]$cmd.Name
        }
    }

    return [pscustomobject]@{
        available = $false
        path = ''
        name = 'powershell'
    }
}

function Get-RaymanCmdLauncherInfo {
    $comSpec = [string]$env:ComSpec
    if (-not [string]::IsNullOrWhiteSpace($comSpec) -and (Test-Path -LiteralPath $comSpec -PathType Leaf)) {
        return [pscustomobject]@{
            available = $true
            path = $comSpec
            name = [System.IO.Path]::GetFileName($comSpec)
        }
    }

    $cmd = Get-Command 'cmd.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd) {
        $path = ''
        if ($cmd.PSObject.Properties['Source'] -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            $path = [string]$cmd.Source
        } elseif ($cmd.PSObject.Properties['Path'] -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Path)) {
            $path = [string]$cmd.Path
        } else {
            $path = [string]$cmd.Name
        }

        return [pscustomobject]@{
            available = $true
            path = $path
            name = [string]$cmd.Name
        }
    }

    return [pscustomobject]@{
        available = $false
        path = ''
        name = 'cmd.exe'
    }
}

function ConvertTo-RaymanWindowsCommandLineSegment {
    param([string]$Text)

    $value = [string]$Text
    if ([string]::IsNullOrWhiteSpace($value)) {
        return '""'
    }

    if ($value -match '[\s"&|<>^()]') {
        return ('"' + ($value -replace '"', '\"') + '"')
    }

    return $value
}

function Resolve-RaymanCodexCaptureInvocation {
    param(
        [object]$CodexCommand,
        [string[]]$ArgumentList = @()
    )

    if ($null -eq $CodexCommand -or -not [bool]$CodexCommand.available) {
        return [pscustomobject]@{
            available = $false
            file_path = ''
            argument_list = @()
            error = 'codex_command_not_found'
        }
    }

    $commandPath = [string]$CodexCommand.path
    if ($commandPath -match '(?i)\.ps1$') {
        $launcher = Get-RaymanPowerShellLauncherInfo
        if (-not [bool]$launcher.available) {
            return [pscustomobject]@{
                available = $false
                file_path = ''
                argument_list = @()
                error = 'powershell_launcher_not_found'
            }
        }

        return [pscustomobject]@{
            available = $true
            file_path = [string]$launcher.path
            argument_list = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $commandPath) + @($ArgumentList)
            error = ''
        }
    }

    return [pscustomobject]@{
        available = $true
        file_path = $commandPath
        argument_list = @($ArgumentList)
        error = ''
    }
}

function Resolve-RaymanCodexInteractiveInvocation {
    param(
        [object]$CodexCommand,
        [string[]]$ArgumentList = @()
    )

    if ($null -eq $CodexCommand -or -not [bool]$CodexCommand.available) {
        return [pscustomobject]@{
            available = $false
            file_path = ''
            argument_list = @()
            error = 'codex_command_not_found'
        }
    }

    $commandPath = [string]$CodexCommand.path
    $extension = ''
    try {
        $extension = ([string]([System.IO.Path]::GetExtension($commandPath))).ToLowerInvariant()
    } catch {
        $extension = ''
    }

    if ($extension -eq '.ps1') {
        $launcher = Get-RaymanPowerShellLauncherInfo
        if (-not [bool]$launcher.available) {
            return [pscustomobject]@{
                available = $false
                file_path = ''
                argument_list = @()
                error = 'powershell_launcher_not_found'
            }
        }

        return [pscustomobject]@{
            available = $true
            file_path = [string]$launcher.path
            argument_list = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $commandPath) + @($ArgumentList)
            error = ''
        }
    }

    if ($extension -in @('.cmd', '.bat')) {
        $launcher = Get-RaymanCmdLauncherInfo
        if (-not [bool]$launcher.available) {
            return [pscustomobject]@{
                available = $false
                file_path = ''
                argument_list = @()
                error = 'cmd_launcher_not_found'
            }
        }

        $commandLine = (@([string]$commandPath) + @($ArgumentList | ForEach-Object { [string]$_ }) | ForEach-Object {
                ConvertTo-RaymanWindowsCommandLineSegment -Text $_
            }) -join ' '
        return [pscustomobject]@{
            available = $true
            file_path = [string]$launcher.path
            argument_list = @('/d', '/c', $commandLine)
            error = ''
        }
    }

    return [pscustomobject]@{
        available = $true
        file_path = $commandPath
        argument_list = @($ArgumentList)
        error = ''
    }
}

function Get-RaymanCodexLoginConfigOverrideSpecs {
    param(
        [string]$Mode = '',
        [string]$WorkspaceRoot = ''
    )

    $normalizedMode = if ([string]::IsNullOrWhiteSpace([string]$Mode)) { '' } else { ([string]$Mode).Trim().ToLowerInvariant() }
    if ($normalizedMode -notin @('web', 'device')) {
        return @()
    }

    $specs = New-Object System.Collections.Generic.List[object]
    if (Test-RaymanWindowsPlatform) {
        $specs.Add([pscustomobject]@{
                key = 'windows.sandbox_private_desktop'
                value = '$false'
                cli_value = 'windows.sandbox_private_desktop=false'
                note = 'force login prompts onto the interactive desktop'
            }) | Out-Null
    }
    $specs.Add([pscustomobject]@{
            key = 'notice.hide_full_access_warning'
            value = '$true'
            cli_value = 'notice.hide_full_access_warning=true'
            note = 'suppress non-actionable full-access warning during login'
        }) | Out-Null

    return @($specs.ToArray())
}

function Test-RaymanCodexConfigOverrideFailureText {
    param(
        [AllowEmptyString()][string]$Text
    )

    if ([string]::IsNullOrWhiteSpace([string]$Text)) {
        return $false
    }

    return (
        $Text -match '(?im)unknown configuration key' -or
        $Text -match '(?im)unknown field' -or
        $Text -match '(?im)invalid config' -or
        $Text -match '(?im)failed to parse' -or
        $Text -match '(?im)toml'
    )
}

function Resolve-RaymanCodexLoginConfigOverrides {
    param(
        [string]$Mode = '',
        [string]$WorkspaceRoot = '',
        [string]$CodexHome = ''
    )

    $specs = @(Get-RaymanCodexLoginConfigOverrideSpecs -Mode $Mode -WorkspaceRoot $WorkspaceRoot)
    $keys = @($specs | ForEach-Object { [string]$_.key } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $result = [ordered]@{
        available = $false
        supported = $false
        skipped_reason = ''
        config_args = @()
        keys = @($keys)
        probe = $null
    }

    if ($specs.Count -eq 0) {
        $result.skipped_reason = 'mode_not_applicable'
        return [pscustomobject]$result
    }

    $codex = Get-RaymanCodexCommandInfo
    if (-not [bool]$codex.available) {
        $result.skipped_reason = 'codex_command_not_found'
        return [pscustomobject]$result
    }

    $cacheKey = ('{0}|{1}|{2}' -f [string]$codex.path, ([string]$Mode).Trim().ToLowerInvariant(), ($(if ([string]::IsNullOrWhiteSpace([string]$WorkspaceRoot)) { '' } else { Resolve-RaymanCodexWorkspacePath -WorkspaceRoot $WorkspaceRoot })))
    if ($script:RaymanCodexLoginOverrideSupportCache.ContainsKey($cacheKey)) {
        return $script:RaymanCodexLoginOverrideSupportCache[$cacheKey]
    }

    $configArgs = New-Object System.Collections.Generic.List[string]
    foreach ($spec in @($specs)) {
        $configArgs.Add('-c') | Out-Null
        $configArgs.Add([string]$spec.cli_value) | Out-Null
    }

    $probeCapture = Invoke-RaymanCodexRawCapture -CodexHome $CodexHome -WorkingDirectory $WorkspaceRoot -ArgumentList (@($configArgs.ToArray()) + @('login', 'status'))
    $probeOutput = [string]$probeCapture.output
    $probeFailedByConfig = Test-RaymanCodexConfigOverrideFailureText -Text $probeOutput

    $result.available = $true
    $result.supported = (-not $probeFailedByConfig)
    $result.skipped_reason = if ($probeFailedByConfig) { 'unsupported_by_cli' } else { '' }
    $result.config_args = if ($probeFailedByConfig) { @() } else { @($configArgs.ToArray()) }
    $result.probe = [pscustomobject]@{
        exit_code = [int]$probeCapture.exit_code
        output = $probeOutput
        failed_by_config = $probeFailedByConfig
    }

    $finalResult = [pscustomobject]$result
    $script:RaymanCodexLoginOverrideSupportCache[$cacheKey] = $finalResult
    return $finalResult
}

function Write-RaymanCodexLoginReport {
    param(
        [string]$WorkspaceRoot = '',
        [object]$Report
    )

    $path = Get-RaymanCodexLoginReportPath -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace([string]$path)) {
        return ''
    }

    $runtimeDir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
    }

    Write-RaymanUtf8NoBom -Path $path -Content ((($Report | ConvertTo-Json -Depth 10).TrimEnd()) + "`n")
    return $path
}

function Resolve-RaymanCodexLoginSmokeSummaryText {
    param([object]$Summary)

    if ($null -eq $Summary) {
        return 'smoke throttle unavailable'
    }

    if (-not [bool](Get-RaymanMapValue -Map $Summary -Key 'throttled' -Default $false)) {
        return ('smoke budget available: attempts={0}/{1} cooldown={2}m' -f [int](Get-RaymanMapValue -Map $Summary -Key 'attempt_count' -Default 0), [int](Get-RaymanMapValue -Map $Summary -Key 'max_attempts' -Default 1), [int](Get-RaymanMapValue -Map $Summary -Key 'cooldown_minutes' -Default 30))
    }

    return ('smoke throttled until {0} (mode={1})' -f [string](Get-RaymanMapValue -Map $Summary -Key 'next_allowed_at' -Default ''), [string](Get-RaymanMapValue -Map $Summary -Key 'mode' -Default ''))
}

function Resolve-RaymanCodexContext {
    param(
        [string]$WorkspaceRoot = '',
        [string]$AccountAlias = '',
        [string]$Profile = ''
    )

    $resolvedWorkspaceRoot = ''
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        try {
            $resolvedWorkspaceRoot = Resolve-RaymanCodexWorkspacePath -WorkspaceRoot $WorkspaceRoot
        } catch {
            $resolvedWorkspaceRoot = [string]$WorkspaceRoot
        }
    }

    $binding = if ([string]::IsNullOrWhiteSpace($resolvedWorkspaceRoot)) {
        [pscustomobject]@{ account_alias = ''; profile = '' }
    } else {
        Get-RaymanCodexWorkspaceBinding -WorkspaceRoot $resolvedWorkspaceRoot
    }

    $explicitAlias = Normalize-RaymanCodexAlias -Alias $AccountAlias
    $bindingAlias = Normalize-RaymanCodexAlias -Alias ([string]$binding.account_alias)
    $effectiveAlias = if (-not [string]::IsNullOrWhiteSpace($explicitAlias)) { $explicitAlias } else { $bindingAlias }
    $effectiveAliasKey = Get-RaymanCodexAliasKey -Alias $effectiveAlias

    $registry = Get-RaymanCodexRegistry
    $accountRecord = if ([string]::IsNullOrWhiteSpace($effectiveAliasKey)) { $null } else { Get-RaymanMapValue -Map $registry.accounts -Key $effectiveAliasKey -Default $null }
    $accountKnown = ($null -ne $accountRecord)
    $aliasCodexHome = if ($accountKnown) { [string](Get-RaymanMapValue -Map $accountRecord -Key 'codex_home' -Default '') } else { Get-RaymanCodexAccountHomePath -Alias $effectiveAlias }
    $desktopCodexHome = Get-RaymanCodexDesktopHomePath
    $accountAuthScope = if ($accountKnown) {
        Resolve-RaymanCodexAuthScopeForMode -ExistingScope ([string](Get-RaymanMapValue -Map $accountRecord -Key 'auth_scope' -Default '')) -Mode ([string](Get-RaymanMapValue -Map $accountRecord -Key 'auth_mode_last' -Default ''))
    } elseif ((Test-RaymanCodexWindowsHost) -and -not [string]::IsNullOrWhiteSpace($effectiveAlias)) {
        'alias_local'
    } else {
        ''
    }

    $explicitProfile = if ([string]::IsNullOrWhiteSpace($Profile)) { '' } else { ([string]$Profile).Trim() }
    $bindingProfile = if ($bindingAlias -and ($bindingAlias.ToLowerInvariant() -eq $effectiveAliasKey)) { [string]$binding.profile } else { '' }
    $defaultProfile = if ($accountKnown) { [string](Get-RaymanMapValue -Map $accountRecord -Key 'default_profile' -Default '') } else { '' }

    $effectiveProfile = ''
    $profileSource = 'none'
    if (-not [string]::IsNullOrWhiteSpace($explicitProfile)) {
        $effectiveProfile = $explicitProfile
        $profileSource = 'explicit'
    } elseif (-not [string]::IsNullOrWhiteSpace($bindingProfile)) {
        $effectiveProfile = $bindingProfile
        $profileSource = 'workspace_binding'
    } elseif (-not [string]::IsNullOrWhiteSpace($defaultProfile)) {
        $effectiveProfile = $defaultProfile
        $profileSource = 'account_default'
    }

    $vscodeUserProfile = if (-not [string]::IsNullOrWhiteSpace($resolvedWorkspaceRoot)) { Get-RaymanVsCodeUserProfileState -WorkspaceRoot $resolvedWorkspaceRoot } else { $null }

    $managed = (-not [string]::IsNullOrWhiteSpace($effectiveAlias))
    $codexHome = if ($managed) {
        if ($accountAuthScope -eq 'desktop_global' -and -not [string]::IsNullOrWhiteSpace([string]$desktopCodexHome)) {
            $desktopCodexHome
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$aliasCodexHome)) {
            $aliasCodexHome
        } else {
            Get-RaymanDefaultCodexHomePath
        }
    } else {
        Get-RaymanDefaultCodexHomePath
    }

    return [pscustomobject]@{
        workspace_root = $resolvedWorkspaceRoot
        binding_alias = $bindingAlias
        binding_profile = [string]$binding.profile
        account_alias = $effectiveAlias
        account_alias_key = $effectiveAliasKey
        account_known = $accountKnown
        account_record = $accountRecord
        managed = $managed
        auth_scope = $accountAuthScope
        codex_home = $codexHome
        alias_codex_home = $aliasCodexHome
        desktop_codex_home = $desktopCodexHome
        desktop_target_mode = if ($accountKnown) { Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $accountRecord -Key 'desktop_target_mode' -Default (Get-RaymanMapValue -Map $accountRecord -Key 'last_login_mode' -Default ''))) } else { '' }
        default_codex_home = Get-RaymanDefaultCodexHomePath
        effective_profile = $effectiveProfile
        profile_source = $profileSource
        vscode_user_profile = if ($null -ne $vscodeUserProfile) { [string]$vscodeUserProfile.profile_name } else { '' }
        vscode_user_profile_location = if ($null -ne $vscodeUserProfile) { [string]$vscodeUserProfile.profile_location } else { '' }
        vscode_user_profile_source = if ($null -ne $vscodeUserProfile) { [string]$vscodeUserProfile.profile_source } else { 'none' }
        vscode_user_profile_status = if ($null -ne $vscodeUserProfile) { [string]$vscodeUserProfile.status } else { 'workspace_missing' }
        vscode_user_profile_detected = if ($null -ne $vscodeUserProfile) { [bool]$vscodeUserProfile.profile_detected } else { $false }
        vscode_user_profile_is_default = if ($null -ne $vscodeUserProfile) { [bool]$vscodeUserProfile.profile_is_default } else { $false }
        vscode_user_profile_storage_path = if ($null -ne $vscodeUserProfile) { [string]$vscodeUserProfile.storage_path } else { '' }
        vscode_user_profile_workspace_uri = if ($null -ne $vscodeUserProfile) { [string]$vscodeUserProfile.matched_workspace_uri } else { '' }
        vscode_user_profiles = if ($null -ne $vscodeUserProfile) { @($vscodeUserProfile.profiles) } else { @() }
        login_repair_command = if (-not [string]::IsNullOrWhiteSpace($effectiveAlias)) { ('rayman codex login --alias {0}' -f $effectiveAlias) } else { '' }
    }
}

function Invoke-RaymanCodexRawCapture {
    param(
        [string]$CodexHome,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = '',
        [hashtable]$EnvironmentOverrides = @{}
    )

    $codex = Get-RaymanCodexCommandInfo
    if (-not [bool]$codex.available) {
        $notFoundMessage = Get-RaymanCodexCommandNotFoundMessage
        return [pscustomobject]@{
            success = $false
            started = $false
            exit_code = 127
            output = $notFoundMessage
            stdout = @()
            stderr = @($notFoundMessage)
            command = 'codex'
            file_path = ''
            error = 'codex_command_not_found'
        }
    }

    $envOverrides = Get-RaymanCodexCommandEnvironmentOverrides -CodexHome $CodexHome -AdditionalOverrides $EnvironmentOverrides

    return (Use-RaymanTemporaryEnvironment -EnvironmentOverrides $envOverrides -ScriptBlock {
        $invocation = Resolve-RaymanCodexCaptureInvocation -CodexCommand $codex -ArgumentList $ArgumentList
        if (-not [bool]$invocation.available) {
            return [pscustomobject]@{
                success = $false
                started = $false
                exit_code = 127
                output = [string]$invocation.error
                stdout = @()
                stderr = @([string]$invocation.error)
                command = 'codex'
                file_path = ''
                error = [string]$invocation.error
            }
        }

        Invoke-RaymanNativeCommandCapture -FilePath ([string]$invocation.file_path) -ArgumentList @($invocation.argument_list) -WorkingDirectory $WorkingDirectory
    })
}

function Invoke-RaymanCodexRawCaptureWithStdin {
    param(
        [string]$CodexHome,
        [string[]]$ArgumentList = @(),
        [AllowEmptyString()][string]$StdinText = '',
        [string]$WorkingDirectory = '',
        [hashtable]$EnvironmentOverrides = @{}
    )

    $codex = Get-RaymanCodexCommandInfo
    if (-not [bool]$codex.available) {
        $notFoundMessage = Get-RaymanCodexCommandNotFoundMessage
        return [pscustomobject]@{
            success = $false
            started = $false
            exit_code = 127
            output = $notFoundMessage
            stdout = @()
            stderr = @($notFoundMessage)
            command = 'codex'
            file_path = ''
            error = 'codex_command_not_found'
        }
    }

    $envOverrides = Get-RaymanCodexCommandEnvironmentOverrides -CodexHome $CodexHome -AdditionalOverrides $EnvironmentOverrides

    return (Use-RaymanTemporaryEnvironment -EnvironmentOverrides $envOverrides -ScriptBlock {
        $invocation = Resolve-RaymanCodexCaptureInvocation -CodexCommand $codex -ArgumentList $ArgumentList
        if (-not [bool]$invocation.available) {
            return [pscustomobject]@{
                success = $false
                started = $false
                exit_code = 127
                output = [string]$invocation.error
                stdout = @()
                stderr = @([string]$invocation.error)
                command = 'codex'
                file_path = ''
                error = [string]$invocation.error
            }
        }

        $result = [ordered]@{
            success = $false
            started = $false
            exit_code = -1
            output = ''
            stdout = @()
            stderr = @()
            command = ((@([string]$invocation.file_path) + @($invocation.argument_list | ForEach-Object { [string]$_ })) -join ' ').Trim()
            file_path = [string]$invocation.file_path
            error = ''
        }

        $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_stdin_' + [Guid]::NewGuid().ToString('N'))
        $stdinPath = $tempBase + '.stdin.txt'
        $stdoutPath = $tempBase + '.stdout.txt'
        $stderrPath = $tempBase + '.stderr.txt'
        $proc = $null
        try {
            Write-RaymanUtf8NoBom -Path $stdinPath -Content (($StdinText.TrimEnd("`r", "`n")) + "`n")
            $params = @{
                FilePath = [string]$invocation.file_path
                ArgumentList = @($invocation.argument_list)
                Wait = $true
                PassThru = $true
                RedirectStandardInput = $stdinPath
                RedirectStandardOutput = $stdoutPath
                RedirectStandardError = $stderrPath
            }
            if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
                $params['WorkingDirectory'] = $WorkingDirectory
            }
            if (Test-RaymanCodexWindowsHost) {
                $params['WindowStyle'] = 'Hidden'
            }

            $proc = Start-Process @params
            $result.started = $true
            $result.exit_code = [int]$proc.ExitCode
            if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
                $result.stdout = @([string[]](Get-Content -LiteralPath $stdoutPath -Encoding UTF8 -ErrorAction SilentlyContinue))
            }
            if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
                $result.stderr = @([string[]](Get-Content -LiteralPath $stderrPath -Encoding UTF8 -ErrorAction SilentlyContinue))
            }
            $result.output = @($result.stdout + $result.stderr) -join [Environment]::NewLine
            $result.success = ($result.exit_code -eq 0)
        } catch {
            $result.error = $_.Exception.Message
            if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
                $result.stdout = @([string[]](Get-Content -LiteralPath $stdoutPath -Encoding UTF8 -ErrorAction SilentlyContinue))
            }
            if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
                $result.stderr = @([string[]](Get-Content -LiteralPath $stderrPath -Encoding UTF8 -ErrorAction SilentlyContinue))
            }
            $result.output = @($result.stdout + $result.stderr) -join [Environment]::NewLine
        } finally {
            try {
                if ($null -ne $proc) {
                    $proc.Dispose()
                }
            } catch {}
            try { Remove-Item -LiteralPath $stdinPath -Force -ErrorAction SilentlyContinue } catch {}
            try { Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue } catch {}
            try { Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue } catch {}
        }

        return [pscustomobject]$result
    })
}

function Invoke-RaymanCodexRawInteractive {
    param(
        [string]$CodexHome,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = '',
        [switch]$PreferHiddenWindow,
        [hashtable]$EnvironmentOverrides = @{}
    )

    $codex = Get-RaymanCodexCommandInfo
    if (-not [bool]$codex.available) {
        throw (Get-RaymanCodexCommandNotFoundMessage)
    }

    $result = [ordered]@{
        success = $false
        exit_code = 1
        command = ((@('codex') + @($ArgumentList)) -join ' ').Trim()
        error = ''
        output = ''
        output_captured = $false
        launch_strategy = if ($PreferHiddenWindow -and (Test-RaymanWindowsPlatform)) { 'hidden' } else { 'foreground' }
    }

    $envOverrides = Get-RaymanCodexCommandEnvironmentOverrides -CodexHome $CodexHome -AdditionalOverrides $EnvironmentOverrides

    Use-RaymanTemporaryEnvironment -EnvironmentOverrides $envOverrides -ScriptBlock {
        $didPush = $false
        $stdoutPath = ''
        $stderrPath = ''
        $proc = $null
        try {
            if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
                Push-Location -LiteralPath $WorkingDirectory
                $didPush = $true
            }

            $useHiddenProcess = ($PreferHiddenWindow -and (Test-RaymanWindowsPlatform))
            if ($useHiddenProcess) {
                $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_codex_interactive_' + [Guid]::NewGuid().ToString('N'))
                $stdoutPath = $tempBase + '.stdout.txt'
                $stderrPath = $tempBase + '.stderr.txt'
                $stdoutLines = @()
                $stderrLines = @()
                $invocation = Resolve-RaymanCodexInteractiveInvocation -CodexCommand $codex -ArgumentList $ArgumentList
                if (-not [bool]$invocation.available) {
                    throw [string]$invocation.error
                }
                $params = @{
                    FilePath = [string]$invocation.file_path
                    ArgumentList = @($invocation.argument_list)
                    PassThru = $true
                    RedirectStandardOutput = $stdoutPath
                    RedirectStandardError = $stderrPath
                }
                if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
                    $params['WorkingDirectory'] = $WorkingDirectory
                }
                $params['WindowStyle'] = 'Hidden'

                $proc = Start-Process @params
                $stdoutIndex = 0
                $stderrIndex = 0
                while ($true) {
                    if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
                        $stdoutLines = @([string[]](Get-Content -LiteralPath $stdoutPath -Encoding UTF8 -ErrorAction SilentlyContinue))
                        while ($stdoutIndex -lt $stdoutLines.Count) {
                            Write-Host $stdoutLines[$stdoutIndex]
                            $stdoutIndex++
                        }
                    }
                    if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
                        $stderrLines = @([string[]](Get-Content -LiteralPath $stderrPath -Encoding UTF8 -ErrorAction SilentlyContinue))
                        while ($stderrIndex -lt $stderrLines.Count) {
                            Write-Host $stderrLines[$stderrIndex]
                            $stderrIndex++
                        }
                    }
                    if ($proc.HasExited) {
                        break
                    }
                    Start-Sleep -Milliseconds 120
                }

                if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
                    $stdoutLines = @([string[]](Get-Content -LiteralPath $stdoutPath -Encoding UTF8 -ErrorAction SilentlyContinue))
                    while ($stdoutIndex -lt $stdoutLines.Count) {
                        Write-Host $stdoutLines[$stdoutIndex]
                        $stdoutIndex++
                    }
                }
                if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
                    $stderrLines = @([string[]](Get-Content -LiteralPath $stderrPath -Encoding UTF8 -ErrorAction SilentlyContinue))
                    while ($stderrIndex -lt $stderrLines.Count) {
                        Write-Host $stderrLines[$stderrIndex]
                        $stderrIndex++
                    }
                }

                $result.exit_code = [int]$proc.ExitCode
                $result.success = ($result.exit_code -eq 0)
                $result.output = (@($stdoutLines + $stderrLines) | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
                $result.output_captured = $true
            } else {
                Reset-LastExitCodeCompat
                & $codex.path @ArgumentList
                $result.exit_code = Get-LastExitCodeCompat -Default $(if ($?) { 0 } else { 1 })
                $result.success = ($result.exit_code -eq 0)
            }
        } catch {
            $result.exit_code = Get-LastExitCodeCompat -Default 1
            if ($result.exit_code -eq 0) {
                $result.exit_code = 1
            }
            $result.error = $_.Exception.Message
            if ([string]::IsNullOrWhiteSpace([string]$result.output)) {
                $result.output = [string]$_.Exception.Message
            }
            $result.success = $false
        } finally {
            if (-not [string]::IsNullOrWhiteSpace($stdoutPath)) {
                try { Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue } catch {}
            }
            if (-not [string]::IsNullOrWhiteSpace($stderrPath)) {
                try { Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue } catch {}
            }
            try {
                if ($null -ne $proc) {
                    $proc.Dispose()
                }
            } catch {}
            if ($didPush) {
                Pop-Location
            }
        }
    } | Out-Null

    return [pscustomobject]$result
}

function Invoke-RaymanCodexLogoutBestEffort {
    param(
        [string]$CodexHome,
        [string]$WorkingDirectory = ''
    )

    $capture = Invoke-RaymanCodexRawCapture -CodexHome $CodexHome -WorkingDirectory $WorkingDirectory -ArgumentList @('logout')
    $outputLines = @($capture.stdout + $capture.stderr | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    if ($outputLines.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$capture.output)) {
        $outputLines = @(([string]$capture.output).Trim())
    }

    $outputText = if ($outputLines.Count -gt 0) { $outputLines -join "`n" } else { [string]$capture.output }
    $notLoggedIn = ($outputText -match '(?im)\bnot logged in\b')

    return [pscustomobject]@{
        success = ([bool]$capture.success -or $notLoggedIn)
        exit_code = [int]$capture.exit_code
        output = $outputText
        output_lines = @($outputLines)
        not_logged_in = $notLoggedIn
        command = [string]$capture.command
        error = [string]$capture.error
    }
}

function Write-RaymanCodexAuthStatusReport {
    param(
        [string]$WorkspaceRoot,
        [object]$Status
    )

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        return ''
    }

    $runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime'
    if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
    }

    $path = Join-Path $runtimeDir 'codex.auth.status.json'
    $payload = [ordered]@{
        schema = 'rayman.codex.auth.status.v1'
        generated_at = [string](Get-RaymanMapValue -Map $Status -Key 'generated_at' -Default (Get-Date).ToString('o'))
        workspace_root = [string](Get-RaymanMapValue -Map $Status -Key 'workspace_root' -Default $WorkspaceRoot)
        vscode_user_profile = [string](Get-RaymanMapValue -Map $Status -Key 'vscode_user_profile' -Default '')
        vscode_user_profile_location = [string](Get-RaymanMapValue -Map $Status -Key 'vscode_user_profile_location' -Default '')
        vscode_user_profile_source = [string](Get-RaymanMapValue -Map $Status -Key 'vscode_user_profile_source' -Default 'none')
        vscode_user_profile_status = [string](Get-RaymanMapValue -Map $Status -Key 'vscode_user_profile_status' -Default 'workspace_missing')
        vscode_user_profile_detected = [bool](Get-RaymanMapValue -Map $Status -Key 'vscode_user_profile_detected' -Default $false)
        vscode_user_profile_is_default = [bool](Get-RaymanMapValue -Map $Status -Key 'vscode_user_profile_is_default' -Default $false)
        account_alias = [string](Get-RaymanMapValue -Map $Status -Key 'account_alias' -Default '')
        profile = [string](Get-RaymanMapValue -Map $Status -Key 'profile' -Default '')
        profile_source = [string](Get-RaymanMapValue -Map $Status -Key 'profile_source' -Default '')
        codex_home = [string](Get-RaymanMapValue -Map $Status -Key 'codex_home' -Default '')
        alias_codex_home = [string](Get-RaymanMapValue -Map $Status -Key 'alias_codex_home' -Default '')
        desktop_codex_home = [string](Get-RaymanMapValue -Map $Status -Key 'desktop_codex_home' -Default '')
        auth_scope = [string](Get-RaymanMapValue -Map $Status -Key 'auth_scope' -Default '')
        managed = [bool](Get-RaymanMapValue -Map $Status -Key 'managed' -Default $false)
        account_known = [bool](Get-RaymanMapValue -Map $Status -Key 'account_known' -Default $false)
        authenticated = [bool](Get-RaymanMapValue -Map $Status -Key 'authenticated' -Default $false)
        status = [string](Get-RaymanMapValue -Map $Status -Key 'status' -Default 'unbound')
        exit_code = [int](Get-RaymanMapValue -Map $Status -Key 'exit_code' -Default 0)
        command = [string](Get-RaymanMapValue -Map $Status -Key 'command' -Default 'codex login status')
        output = @((Get-RaymanMapValue -Map $Status -Key 'output' -Default @()) | ForEach-Object { [string]$_ })
        repair_command = [string](Get-RaymanMapValue -Map $Status -Key 'repair_command' -Default '')
        known_error_signature = [string](Get-RaymanMapValue -Map $Status -Key 'known_error_signature' -Default '')
        known_error_severity = [string](Get-RaymanMapValue -Map $Status -Key 'known_error_severity' -Default '')
        known_error_message = [string](Get-RaymanMapValue -Map $Status -Key 'known_error_message' -Default '')
        guard_stage = [string](Get-RaymanMapValue -Map $Status -Key 'guard_stage' -Default '')
        repeat_prevented = [bool](Get-RaymanMapValue -Map $Status -Key 'repeat_prevented' -Default $false)
        known_error_matches = @((Get-RaymanMapValue -Map $Status -Key 'known_error_matches' -Default @()) | ForEach-Object { $_ })
        auth_mode_last = Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $Status -Key 'auth_mode_last' -Default ''))
        auth_mode_detected = Normalize-RaymanCodexDetectedAuthMode -Mode ([string](Get-RaymanMapValue -Map $Status -Key 'auth_mode_detected' -Default 'unknown'))
        auth_source = [string](Get-RaymanMapValue -Map $Status -Key 'auth_source' -Default 'none')
        last_login_mode = [string](Get-RaymanMapValue -Map $Status -Key 'last_login_mode' -Default '')
        last_login_strategy = [string](Get-RaymanMapValue -Map $Status -Key 'last_login_strategy' -Default '')
        last_login_prompt_classification = [string](Get-RaymanMapValue -Map $Status -Key 'last_login_prompt_classification' -Default '')
        last_login_started_at = [string](Get-RaymanMapValue -Map $Status -Key 'last_login_started_at' -Default '')
        last_login_finished_at = [string](Get-RaymanMapValue -Map $Status -Key 'last_login_finished_at' -Default '')
        last_login_success = [bool](Get-RaymanMapValue -Map $Status -Key 'last_login_success' -Default $false)
        last_yunyi_base_url = [string](Get-RaymanMapValue -Map $Status -Key 'last_yunyi_base_url' -Default '')
        last_yunyi_success_at = [string](Get-RaymanMapValue -Map $Status -Key 'last_yunyi_success_at' -Default '')
        last_yunyi_config_ready = [bool](Get-RaymanMapValue -Map $Status -Key 'last_yunyi_config_ready' -Default $false)
        last_yunyi_reuse_reason = [string](Get-RaymanMapValue -Map $Status -Key 'last_yunyi_reuse_reason' -Default '')
        last_yunyi_base_url_source = [string](Get-RaymanMapValue -Map $Status -Key 'last_yunyi_base_url_source' -Default '')
        login_smoke_mode = [string](Get-RaymanMapValue -Map $Status -Key 'login_smoke_mode' -Default '')
        login_smoke_next_allowed_at = [string](Get-RaymanMapValue -Map $Status -Key 'login_smoke_next_allowed_at' -Default '')
        login_smoke_throttled = [bool](Get-RaymanMapValue -Map $Status -Key 'login_smoke_throttled' -Default $false)
        desktop_auth_present = [bool](Get-RaymanMapValue -Map $Status -Key 'desktop_auth_present' -Default $false)
        desktop_global_cloud_access = [string](Get-RaymanMapValue -Map $Status -Key 'desktop_global_cloud_access' -Default '')
        desktop_target_mode = Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $Status -Key 'desktop_target_mode' -Default ''))
        desktop_saved_token_reused = [bool](Get-RaymanMapValue -Map $Status -Key 'desktop_saved_token_reused' -Default $false)
        desktop_saved_token_source = [string](Get-RaymanMapValue -Map $Status -Key 'desktop_saved_token_source' -Default '')
        desktop_status_command = [string](Get-RaymanMapValue -Map $Status -Key 'desktop_status_command' -Default '')
        desktop_status_quota_visible = [bool](Get-RaymanMapValue -Map $Status -Key 'desktop_status_quota_visible' -Default $false)
        desktop_status_reason = [string](Get-RaymanMapValue -Map $Status -Key 'desktop_status_reason' -Default '')
        desktop_config_conflict = [string](Get-RaymanMapValue -Map $Status -Key 'desktop_config_conflict' -Default '')
        desktop_unsynced_reason = [string](Get-RaymanMapValue -Map $Status -Key 'desktop_unsynced_reason' -Default '')
        latest_native_session = ConvertTo-RaymanCodexNativeSessionSummary -InputObject (Get-RaymanMapValue -Map $Status -Key 'latest_native_session' -Default $null)
        saved_state_summary = [pscustomobject](Get-RaymanMapValue -Map $Status -Key 'saved_state_summary' -Default ([ordered]@{
                    workspace_root = [string](Get-RaymanMapValue -Map $Status -Key 'workspace_root' -Default $WorkspaceRoot)
                    account_alias = [string](Get-RaymanMapValue -Map $Status -Key 'account_alias' -Default '')
                    total_count = 0
                    manual_count = 0
                    auto_temp_count = 0
                    latest = $null
                    recent_saved_states = @()
                }))
        recent_saved_states = @((Get-RaymanMapValue -Map $Status -Key 'recent_saved_states' -Default @()) | ForEach-Object { $_ })
    }
    Write-RaymanUtf8NoBom -Path $path -Content (($payload | ConvertTo-Json -Depth 8).TrimEnd() + "`n")
    return $path
}

function Get-RaymanCodexLoginStatus {
    param(
        [string]$WorkspaceRoot = '',
        [string]$AccountAlias = '',
        [switch]$SkipReportWrite,
        [string]$GuardStage = 'codex.status'
    )

    $context = Resolve-RaymanCodexContext -WorkspaceRoot $WorkspaceRoot -AccountAlias $AccountAlias
    $checkedAt = (Get-Date).ToString('o')
    $desktopGlobalState = Get-RaymanCodexDesktopGlobalStateSummary
    $desktopAuthFilePath = Get-RaymanCodexAuthFilePath -CodexHome ([string]$context.desktop_codex_home)
    $desktopAuthPresent = (-not [string]::IsNullOrWhiteSpace([string]$desktopAuthFilePath) -and (Test-Path -LiteralPath $desktopAuthFilePath -PathType Leaf))
    $desktopStatusCommand = if ([bool]$context.account_known) { [string](Get-RaymanMapValue -Map $context.account_record -Key 'desktop_status_command' -Default (Get-RaymanCodexDesktopStatusCommand)) } else { Get-RaymanCodexDesktopStatusCommand }
    $desktopStatusQuotaVisible = if ([bool]$context.account_known) { [bool](Get-RaymanMapValue -Map $context.account_record -Key 'desktop_status_quota_visible' -Default $false) } else { $false }
    $desktopStatusReason = if ([bool]$context.account_known) { [string](Get-RaymanMapValue -Map $context.account_record -Key 'desktop_status_reason' -Default '') } else { '' }
    $desktopTargetMode = if ([string]::IsNullOrWhiteSpace([string]$context.desktop_target_mode)) {
        if ([bool]$context.account_known) {
            Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $context.account_record -Key 'last_login_mode' -Default (Get-RaymanMapValue -Map $context.account_record -Key 'auth_mode_last' -Default '')))
        } else {
            ''
        }
    } else {
        Normalize-RaymanCodexAuthModeLast -Mode ([string]$context.desktop_target_mode)
    }
    $desktopSavedTokenReused = if ([bool]$context.account_known) { [bool](Get-RaymanMapValue -Map $context.account_record -Key 'desktop_saved_token_reused' -Default $false) } else { $false }
    $desktopSavedTokenSource = if ([bool]$context.account_known) { [string](Get-RaymanMapValue -Map $context.account_record -Key 'desktop_saved_token_source' -Default '') } else { '' }
    $desktopConfigState = Get-RaymanCodexConfigState -CodexHome ([string]$context.desktop_codex_home)
    $desktopConfigConflict = [string](Get-RaymanMapValue -Map $desktopConfigState -Key 'conflict_reason' -Default '')
    $aliasConfigState = if ([bool]$context.account_known) { Get-RaymanCodexConfigState -CodexHome ([string]$context.alias_codex_home) } else { [pscustomobject]@{ model_provider = ''; yunyi_base_url = ''; present = $false } }
    $aliasAuthSummary = Get-RaymanCodexAuthFileSummary -CodexHome ([string]$context.alias_codex_home)
    $desktopAuthSummary = Get-RaymanCodexAuthFileSummary -CodexHome ([string]$context.desktop_codex_home)
    $desktopUnsyncedReason = ''
    $desktopWorkspaceSession = [pscustomobject]@{
        available = $false
        session_id = ''
        session_path = ''
        workspace_root = [string]$context.workspace_root
        last_write_at = ''
    }
    $desktopWorkspaceQuotaProbe = [pscustomobject]@{
        text = ''
        matched_at = $null
        source = 'none'
        quota_visible = $false
    }
    $desktopWorkspaceSessionRecent = $false
    $lastYunyiBaseUrl = if ([bool]$context.account_known) { [string](Get-RaymanMapValue -Map $context.account_record -Key 'last_yunyi_base_url' -Default '') } else { '' }
    if ([string]::IsNullOrWhiteSpace([string]$lastYunyiBaseUrl) -and -not [string]::IsNullOrWhiteSpace([string](Get-RaymanMapValue -Map $aliasConfigState -Key 'yunyi_base_url' -Default ''))) {
        $lastYunyiBaseUrl = [string](Get-RaymanMapValue -Map $aliasConfigState -Key 'yunyi_base_url' -Default '')
    }
    $lastYunyiConfigReady = (
        [bool]$context.account_known -and
        [string](Get-RaymanMapValue -Map $aliasConfigState -Key 'model_provider' -Default '') -eq 'yunyi' -and
        -not [string]::IsNullOrWhiteSpace([string](Get-RaymanMapValue -Map $aliasConfigState -Key 'yunyi_base_url' -Default ''))
    )
    if ($desktopTargetMode -in @('web', 'device')) {
        if ([bool]$aliasAuthSummary.present -and [string]$aliasAuthSummary.auth_mode -eq 'chatgpt' -and [string]$desktopAuthSummary.auth_mode -ne 'chatgpt') {
            $desktopUnsyncedReason = 'desktop_home_auth_unsynced'
        }
    }

    $status = [ordered]@{
        schema = 'rayman.codex.auth.status.v1'
        generated_at = $checkedAt
        workspace_root = [string]$context.workspace_root
        vscode_user_profile = [string]$context.vscode_user_profile
        vscode_user_profile_location = [string]$context.vscode_user_profile_location
        vscode_user_profile_source = [string]$context.vscode_user_profile_source
        vscode_user_profile_status = [string]$context.vscode_user_profile_status
        vscode_user_profile_detected = [bool]$context.vscode_user_profile_detected
        vscode_user_profile_is_default = [bool]$context.vscode_user_profile_is_default
        account_alias = [string]$context.account_alias
        profile = [string]$context.effective_profile
        profile_source = [string]$context.profile_source
        codex_home = [string]$context.codex_home
        alias_codex_home = [string]$context.alias_codex_home
        desktop_codex_home = [string]$context.desktop_codex_home
        auth_scope = [string]$context.auth_scope
        managed = [bool]$context.managed
        account_known = [bool]$context.account_known
        authenticated = $false
        status = 'unbound'
        exit_code = 0
        command = 'codex login status'
        output = @()
        repair_command = [string]$context.login_repair_command
        known_error_signature = ''
        known_error_severity = ''
        known_error_message = ''
        guard_stage = [string]$GuardStage
        repeat_prevented = $false
        known_error_matches = @()
        auth_mode_last = if ([bool]$context.account_known) { Normalize-RaymanCodexAuthModeLast -Mode ([string](Get-RaymanMapValue -Map $context.account_record -Key 'auth_mode_last' -Default '')) } else { '' }
        auth_mode_detected = 'unknown'
        auth_source = 'none'
        last_login_mode = if ([bool]$context.account_known) { [string](Get-RaymanMapValue -Map $context.account_record -Key 'last_login_mode' -Default '') } else { '' }
        last_login_strategy = if ([bool]$context.account_known) { [string](Get-RaymanMapValue -Map $context.account_record -Key 'last_login_strategy' -Default '') } else { '' }
        last_login_prompt_classification = if ([bool]$context.account_known) { [string](Get-RaymanMapValue -Map $context.account_record -Key 'last_login_prompt_classification' -Default '') } else { '' }
        last_login_started_at = if ([bool]$context.account_known) { [string](Get-RaymanMapValue -Map $context.account_record -Key 'last_login_started_at' -Default '') } else { '' }
        last_login_finished_at = if ([bool]$context.account_known) { [string](Get-RaymanMapValue -Map $context.account_record -Key 'last_login_finished_at' -Default '') } else { '' }
        last_login_success = if ([bool]$context.account_known) { [bool](Get-RaymanMapValue -Map $context.account_record -Key 'last_login_success' -Default $false) } else { $false }
        last_yunyi_base_url = $lastYunyiBaseUrl
        last_yunyi_success_at = if ([bool]$context.account_known) { [string](Get-RaymanMapValue -Map $context.account_record -Key 'last_yunyi_success_at' -Default '') } else { '' }
        last_yunyi_config_ready = $lastYunyiConfigReady
        last_yunyi_reuse_reason = if ([bool]$context.account_known) { [string](Get-RaymanMapValue -Map $context.account_record -Key 'last_yunyi_reuse_reason' -Default '') } else { '' }
        last_yunyi_base_url_source = if ([bool]$context.account_known) { [string](Get-RaymanMapValue -Map $context.account_record -Key 'last_yunyi_base_url_source' -Default '') } else { '' }
        login_smoke_mode = ''
        login_smoke_next_allowed_at = ''
        login_smoke_throttled = $false
        desktop_auth_present = [bool]$desktopAuthPresent
        desktop_global_cloud_access = [string]$desktopGlobalState.codex_cloud_access
        desktop_target_mode = [string]$desktopTargetMode
        desktop_saved_token_reused = [bool]$desktopSavedTokenReused
        desktop_saved_token_source = [string]$desktopSavedTokenSource
        desktop_status_command = [string]$desktopStatusCommand
        desktop_status_quota_visible = [bool]$desktopStatusQuotaVisible
        desktop_status_reason = [string]$desktopStatusReason
        desktop_config_conflict = [string]$desktopConfigConflict
        desktop_unsynced_reason = [string]$desktopUnsyncedReason
        latest_native_session = ConvertTo-RaymanCodexNativeSessionSummary -InputObject $(if ([bool]$context.account_known) { Get-RaymanMapValue -Map $context.account_record -Key 'latest_native_session' -Default $null } else { $null }) -SessionIndexPath (Get-RaymanCodexSessionIndexPath -CodexHome ([string]$context.codex_home))
        saved_state_summary = Get-RaymanCodexWorkspaceSavedStateSummary -WorkspaceRoot $context.workspace_root -AccountAlias $context.account_alias
        recent_saved_states = @()
    }
    $status.recent_saved_states = @($status.saved_state_summary.recent_saved_states)
    if ([bool]$context.account_known -and -not [string]::IsNullOrWhiteSpace([string]$context.account_alias)) {
        $smokeSummary = Get-RaymanCodexLoginSmokeAliasSummary -WorkspaceRoot $context.workspace_root -Alias $context.account_alias
        $status.login_smoke_mode = [string]$smokeSummary.mode
        $status.login_smoke_next_allowed_at = [string]$smokeSummary.next_allowed_at
        $status.login_smoke_throttled = [bool]$smokeSummary.throttled
    }

    if (-not [bool]$context.managed) {
        $status.status = 'unbound'
    } elseif (-not [bool]$context.account_known) {
        $status.status = 'unknown_alias'
        $status.exit_code = 2
        $status.output = @(('Rayman Codex alias not registered: {0}' -f [string]$context.account_alias))
    } else {
        $latestNativeSession = Get-RaymanCodexLatestNativeSession -CodexHome $context.codex_home
        $status.latest_native_session = $latestNativeSession
        if ([string]$context.auth_scope -eq 'desktop_global' -and [string]$desktopTargetMode -eq 'web') {
            $desktopWorkspaceSession = Get-RaymanCodexDesktopLatestWorkspaceSession -WorkspaceRoot $context.workspace_root
            if ([bool]$desktopWorkspaceSession.available) {
                $status.latest_native_session = ConvertTo-RaymanCodexDesktopWorkspaceSessionSummary -Session $desktopWorkspaceSession
                $desktopWorkspaceQuotaProbe = Get-RaymanCodexDesktopSessionQuotaProbe -SessionPath ([string]$desktopWorkspaceSession.session_path)
                $desktopWorkspaceLastWriteAt = [string](Get-RaymanMapValue -Map $desktopWorkspaceSession -Key 'last_write_at' -Default '')
                if (-not [string]::IsNullOrWhiteSpace([string]$desktopWorkspaceLastWriteAt)) {
                    try {
                        $desktopWorkspaceSessionRecent = (((Get-Date) - [datetime]$desktopWorkspaceLastWriteAt).TotalMinutes -le 15)
                    } catch {
                        $desktopWorkspaceSessionRecent = $false
                    }
                }
            }
        }
        $compatibility = Ensure-RaymanCodexCliCompatible -WorkspaceRoot $context.workspace_root -AccountAlias $context.account_alias
        if (-not [bool]$compatibility.compatible) {
            $status.status = 'compatibility_failed'
            $status.exit_code = 3
            $status.output = @([string]$compatibility.output)
            $authState = Get-RaymanCodexNativeAuthState -WorkspaceRoot $context.workspace_root -CodexHome $context.codex_home
            $status.auth_mode_detected = [string]$authState.auth_mode_detected
            $status.auth_source = [string]$authState.auth_source
        } else {
            $capture = Invoke-RaymanCodexRawCapture -CodexHome $context.codex_home -WorkingDirectory $context.workspace_root -ArgumentList @('login', 'status')
            $status.exit_code = [int]$capture.exit_code
            $outputLines = @($capture.stdout + $capture.stderr | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
            if ($outputLines.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$capture.output)) {
                $outputLines = @(([string]$capture.output).Trim())
            }
            $status.output = @($outputLines)
            $probeText = if ($outputLines.Count -gt 0) { ($outputLines -join "`n") } else { [string]$capture.output }
            $authState = Get-RaymanCodexNativeAuthState -WorkspaceRoot $context.workspace_root -CodexHome $context.codex_home -StatusText $probeText
            $status.auth_mode_detected = [string]$authState.auth_mode_detected
            $status.auth_source = [string]$authState.auth_source
            if ($capture.success) {
                $status.status = 'authenticated'
                $status.authenticated = $true
            } elseif ([string]$authState.auth_mode_detected -eq 'env_apikey') {
                $status.status = 'authenticated'
                $status.authenticated = $true
            } elseif (
                $probeText -match '(?im)\bnot logged in\b' -or
                $probeText -match '(?im)error checking login status:.*\bos error 2\b' -or
                $probeText -match '(?im)system cannot find the file specified' -or
                $probeText -match '系统找不到指定的文件'
            ) {
                $status.status = 'not_logged_in'
            } else {
                $status.status = 'probe_failed'
            }
        }

        if ([string]$status.auth_mode_detected -eq 'env_apikey') {
            if ([string](Get-RaymanMapValue -Map $aliasConfigState -Key 'model_provider' -Default '') -eq 'yunyi') {
                $status.auth_mode_last = 'yunyi'
            } else {
                $status.auth_mode_last = 'api'
            }
        }

        if (
            [string]$status.auth_scope -eq 'desktop_global' -and
            [string]$desktopTargetMode -eq 'web' -and
            [bool]$status.authenticated -and
            [string]$status.auth_mode_detected -eq 'chatgpt' -and
            [string]::IsNullOrWhiteSpace([string]$status.desktop_unsynced_reason) -and
            [string]$status.desktop_global_cloud_access -ne 'disabled' -and
            [bool](Get-RaymanMapValue -Map $desktopWorkspaceQuotaProbe -Key 'quota_visible' -Default $false)
        ) {
            $status.desktop_status_quota_visible = $true
            $status.desktop_status_reason = 'quota_visible'
        } elseif (
            [string]$status.auth_scope -eq 'desktop_global' -and
            [string]$desktopTargetMode -eq 'web' -and
            [bool]$status.authenticated -and
            [string]$status.auth_mode_detected -eq 'chatgpt' -and
            [string]::IsNullOrWhiteSpace([string]$status.desktop_unsynced_reason) -and
            [string]$status.desktop_global_cloud_access -ne 'disabled' -and
            [bool]$desktopWorkspaceSessionRecent -and
            [string]$status.desktop_status_reason -in @('desktop_response_timeout', 'desktop_response_timeout_soft_pass', 'desktop_window_not_found', 'desktop_window_not_found_soft_pass')
        ) {
            $status.desktop_status_quota_visible = $true
            $status.desktop_status_reason = 'quota_visible_vscode_session'
        }

        $desktopApiActivation = Get-RaymanCodexDesktopApiActivationStatus -Mode $desktopTargetMode -DesktopConfigState $desktopConfigState -DesktopAuthSummary $desktopAuthSummary -DesktopGlobalState $desktopGlobalState
        $desktopAuthRepairRequired = ([string]$status.auth_scope -eq 'desktop_global')

        if ($desktopAuthRepairRequired -and $desktopTargetMode -eq 'web') {
            if (-not [string]::IsNullOrWhiteSpace([string]$status.desktop_unsynced_reason)) {
                $status.status = 'desktop_repair_needed'
                $status.authenticated = $false
                if ([string]::IsNullOrWhiteSpace([string]$status.desktop_status_reason)) {
                    $status.desktop_status_reason = [string]$status.desktop_unsynced_reason
                }
            } elseif ([string]$status.auth_mode_detected -ne 'chatgpt') {
                $status.status = 'desktop_repair_needed'
                $status.authenticated = $false
                if ([string]::IsNullOrWhiteSpace([string]$status.desktop_status_reason)) {
                    $status.desktop_status_reason = 'desktop_home_auth_unsynced'
                }
            } elseif ([string]$status.desktop_global_cloud_access -eq 'disabled') {
                $status.status = 'desktop_repair_needed'
                $status.authenticated = $false
                if ([string]::IsNullOrWhiteSpace([string]$status.desktop_status_reason)) {
                    $status.desktop_status_reason = 'desktop_cloud_access_disabled'
                }
            }
        } elseif ($desktopAuthRepairRequired -and [bool]$desktopApiActivation.applicable) {
            $status.desktop_config_conflict = [string](Get-RaymanMapValue -Map $desktopApiActivation -Key 'config_conflict' -Default '')
            if ([string]::IsNullOrWhiteSpace([string]$status.desktop_status_reason)) {
                $status.desktop_status_reason = [string]$desktopApiActivation.reason
            }
            if (-not [bool]$desktopApiActivation.ready) {
                $status.status = 'desktop_repair_needed'
                $status.authenticated = $false
            }
        }

        if (
            [string]$status.auth_scope -eq 'desktop_global' -and
            [string]::IsNullOrWhiteSpace([string]$status.desktop_status_reason) -and
            [bool]$desktopApiActivation.applicable -and
            [bool]$desktopApiActivation.ready
        ) {
            $status.desktop_status_reason = [string]$desktopApiActivation.reason
        } elseif ([string]$status.auth_scope -eq 'desktop_global' -and [string]::IsNullOrWhiteSpace([string]$status.desktop_status_reason) -and [string]$status.desktop_global_cloud_access -eq 'disabled') {
            $status.desktop_status_reason = 'desktop_cloud_access_disabled'
        }

        if (Get-Command Get-RaymanRepeatErrorGuardReport -ErrorAction SilentlyContinue) {
            try {
                $repeatErrorReport = Get-RaymanRepeatErrorGuardReport -WorkspaceRoot $context.workspace_root -CodexStatus ([pscustomobject]$status) -GuardStage $GuardStage
                if ($null -ne $repeatErrorReport) {
                    $repeatSummary = Get-RaymanMapValue -Map $repeatErrorReport -Key 'summary' -Default $null
                    $repeatMatches = @((Get-RaymanMapValue -Map $repeatErrorReport -Key 'matches' -Default @()) | ForEach-Object { $_ })
                    $status.guard_stage = [string](Get-RaymanMapValue -Map $repeatErrorReport -Key 'guard_stage' -Default $GuardStage)
                    $status.repeat_prevented = [bool](Get-RaymanMapValue -Map $repeatSummary -Key 'fail_fast' -Default $false)
                    $status.known_error_signature = [string](Get-RaymanMapValue -Map $repeatSummary -Key 'top_signature' -Default '')
                    $status.known_error_severity = [string](Get-RaymanMapValue -Map $repeatSummary -Key 'top_severity' -Default '')
                    $status.known_error_message = [string](Get-RaymanMapValue -Map $repeatSummary -Key 'message' -Default '')
                    $status.known_error_matches = @($repeatMatches)
                    $guardRepairCommand = [string](Get-RaymanMapValue -Map $repeatSummary -Key 'repair_command' -Default '')
                    if (-not [string]::IsNullOrWhiteSpace($guardRepairCommand)) {
                        $status.repair_command = $guardRepairCommand
                    }
                    if (-not [string]::IsNullOrWhiteSpace([string]$context.workspace_root)) {
                        Write-RaymanRepeatErrorGuardRuntimeReport -WorkspaceRoot $context.workspace_root -Report $repeatErrorReport | Out-Null
                    }
                }
            } catch {
                $status.known_error_message = if ([string]::IsNullOrWhiteSpace([string]$status.known_error_message)) { ("repeat error guard failed: {0}" -f $_.Exception.Message) } else { [string]$status.known_error_message }
            }
        }

        Set-RaymanCodexAccountStatus -Alias $context.account_alias -Status $status.status -CheckedAt $checkedAt -AuthModeLast ([string]$status.auth_mode_last) -LatestNativeSession $status.latest_native_session | Out-Null
    }

    if (-not $SkipReportWrite -and -not [string]::IsNullOrWhiteSpace([string]$context.workspace_root)) {
        Write-RaymanCodexAuthStatusReport -WorkspaceRoot $context.workspace_root -Status $status | Out-Null
    }

    return [pscustomobject]$status
}

function Assert-RaymanCodexManagedLogin {
    param(
        [string]$WorkspaceRoot = '',
        [string]$AccountAlias = ''
    )

    $context = Resolve-RaymanCodexContext -WorkspaceRoot $WorkspaceRoot -AccountAlias $AccountAlias
    if (-not [bool]$context.managed) {
        return [pscustomobject]@{
            context = $context
            status = $null
        }
    }

    if (-not [bool]$context.account_known) {
        throw ("Rayman Codex alias '{0}' is not registered. Run `{1}`." -f [string]$context.account_alias, [string]$context.login_repair_command)
    }

    $status = Get-RaymanCodexLoginStatus -WorkspaceRoot $WorkspaceRoot -AccountAlias $context.account_alias
    if (-not [bool]$status.authenticated) {
        throw ("Codex login for alias '{0}' is not active (status={1}). Run `{2}`." -f [string]$context.account_alias, [string]$status.status, [string]$context.login_repair_command)
    }

    return [pscustomobject]@{
        context = $context
        status = $status
    }
}

function Get-RaymanCodexVersionInfo {
    param(
        [string]$WorkspaceRoot = '',
        [string]$AccountAlias = ''
    )

    $context = Resolve-RaymanCodexContext -WorkspaceRoot $WorkspaceRoot -AccountAlias $AccountAlias
    $codex = Get-RaymanCodexCommandInfo
    if (-not [bool]$codex.available) {
        return [pscustomobject]@{
            available = $false
            raw = ''
            numeric = ''
            context = $context
        }
    }

    $capture = Invoke-RaymanCodexRawCapture -CodexHome $context.codex_home -WorkingDirectory $context.workspace_root -ArgumentList @('--version')
    $rawText = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$capture.output)) {
        $rawText = [string]$capture.output
    }
    $numericMatch = [regex]::Match($rawText, '(\d+\.\d+\.\d+)')
    return [pscustomobject]@{
        available = $true
        raw = $rawText.Trim()
        numeric = if ($numericMatch.Success) { [string]$numericMatch.Groups[1].Value } else { '' }
        context = $context
    }
}

function Get-RaymanCodexAutoUpdatePolicy {
    $legacyRaw = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_ENABLED')
    if (-not [string]::IsNullOrWhiteSpace($legacyRaw)) {
        switch ($legacyRaw.Trim().ToLowerInvariant()) {
            '0' { return 'off' }
            'false' { return 'off' }
            'no' { return 'off' }
            'off' { return 'off' }
        }
    }

    $raw = [Environment]::GetEnvironmentVariable('RAYMAN_CODEX_AUTO_UPDATE_POLICY')
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return 'latest'
    }

    switch ($raw.Trim().ToLowerInvariant()) {
        'latest' { return 'latest' }
        'compatibility' { return 'compatibility' }
        'off' { return 'off' }
        default { return 'latest' }
    }
}

function Get-RaymanCodexAutoUpdateEnabled {
    return ((Get-RaymanCodexAutoUpdatePolicy) -ne 'off')
}

function Resolve-RaymanCodexAutoUpdatePolicy {
    param(
        [string]$PolicyOverride = '',
        [switch]$ForceUpgrade
    )

    if ($ForceUpgrade) {
        return 'latest'
    }

    $normalized = if ([string]::IsNullOrWhiteSpace($PolicyOverride)) { '' } else { $PolicyOverride.Trim().ToLowerInvariant() }
    if ($normalized -in @('latest', 'compatibility', 'off')) {
        return $normalized
    }

    return (Get-RaymanCodexAutoUpdatePolicy)
}

function Test-RaymanCodexVersionAtLeast {
    param(
        [string]$Candidate,
        [string]$Minimum
    )

    if ([string]::IsNullOrWhiteSpace($Candidate) -or [string]::IsNullOrWhiteSpace($Minimum)) {
        return $false
    }

    try {
        return ([Version]$Candidate -ge [Version]$Minimum)
    } catch {
        return $false
    }
}

function Test-RaymanCodexInstallManagedByNpm {
    param(
        [object]$CodexCommand = $null
    )

    $commandInfo = if ($null -eq $CodexCommand) { Get-RaymanCodexCommandInfo } else { $CodexCommand }
    if ($null -eq $commandInfo -or -not [bool]$commandInfo.available) {
        return $false
    }

    $path = [string]$commandInfo.path
    if ([string]::IsNullOrWhiteSpace($path)) {
        return $false
    }

    $normalizedPath = $path.Replace('/', '\').ToLowerInvariant()
    return (
        $normalizedPath -match '\\npm\\codex(\.cmd|\.ps1)?$' -or
        $normalizedPath -match '\\npm\\node_modules\\@openai\\codex\\' -or
        $normalizedPath -match '\\node_modules\\@openai\\codex\\bin\\codex\.js$'
    )
}

function Test-RaymanCodexCompatibilityOutput {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    return (
        $Text -match '(?im)unknown variant .*model_reasoning_effort' -or
        $Text -match '(?im)expected one of .*minimal.*low.*medium.*high' -or
        $Text -match '(?im)failed to parse.*config' -or
        $Text -match '(?im)invalid type:.*model_reasoning_effort'
    )
}

function Get-RaymanNpmCommandInfo {
    foreach ($name in @('npm.cmd', 'npm')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $cmd) {
            continue
        }

        $path = ''
        if ($cmd.PSObject.Properties['Source'] -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            $path = [string]$cmd.Source
        } elseif ($cmd.PSObject.Properties['Path'] -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Path)) {
            $path = [string]$cmd.Path
        } else {
            $path = [string]$cmd.Name
        }

        return [pscustomobject]@{
            available = $true
            path = $path
            name = [string]$cmd.Name
        }
    }

    return [pscustomobject]@{
        available = $false
        path = ''
        name = 'npm'
    }
}

function Get-RaymanCodexLatestVersionInfo {
    param(
        [string]$WorkspaceRoot = ''
    )

    $npm = Get-RaymanNpmCommandInfo
    if (-not [bool]$npm.available) {
        return [pscustomobject]@{
            success = $false
            version = ''
            output = 'npm command not found'
            command = 'npm view @openai/codex version'
            reason = 'npm_command_not_found'
        }
    }

    $capture = Invoke-RaymanNativeCommandCapture -FilePath $npm.path -ArgumentList @('view', '@openai/codex', 'version') -WorkingDirectory $WorkspaceRoot
    $lines = @($capture.stdout + $capture.stderr | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    $outputText = if ($lines.Count -gt 0) { ($lines -join "`n") } else { [string]$capture.output }
    $versionMatch = [regex]::Match([string]$outputText, '(\d+\.\d+\.\d+)')

    return [pscustomobject]@{
        success = ([bool]$capture.success -and $versionMatch.Success)
        version = if ($versionMatch.Success) { [string]$versionMatch.Groups[1].Value } else { '' }
        output = [string]$outputText
        command = [string]$capture.command
        reason = if ([bool]$capture.success -and $versionMatch.Success) { 'latest_version_resolved' } elseif (-not [bool]$capture.success) { 'latest_version_query_failed' } else { 'latest_version_parse_failed' }
    }
}

function Invoke-RaymanCodexGlobalUpdate {
    param(
        [string]$WorkspaceRoot = ''
    )

    $npm = Get-RaymanNpmCommandInfo
    if (-not [bool]$npm.available) {
        return [pscustomobject]@{
            success = $false
            exit_code = 127
            output = 'npm command not found'
            command = 'npm install -g @openai/codex'
            reason = 'npm_command_not_found'
        }
    }

    $capture = Invoke-RaymanNativeCommandCapture -FilePath $npm.path -ArgumentList @('install', '-g', '@openai/codex') -WorkingDirectory $WorkspaceRoot
    return [pscustomobject]@{
        success = [bool]$capture.success
        exit_code = [int]$capture.exit_code
        output = [string]$capture.output
        command = [string]$capture.command
        reason = if ([bool]$capture.success) { 'updated' } else { 'update_failed' }
    }
}

function Get-RaymanCodexCliCompatibilityStatus {
    param(
        [string]$WorkspaceRoot = '',
        [string]$AccountAlias = '',
        [switch]$ForceRefresh
    )

    $context = Resolve-RaymanCodexContext -WorkspaceRoot $WorkspaceRoot -AccountAlias $AccountAlias
    $codex = Get-RaymanCodexCommandInfo
    if (-not [bool]$codex.available) {
        $notFoundMessage = Get-RaymanCodexCommandNotFoundMessage
        return [pscustomobject]@{
            compatible = $false
            updated = $false
            reason = 'codex_command_not_found'
            minimum_version = '0.116.0'
            version_before = ''
            version_after = ''
            output = $notFoundMessage
            context = $context
        }
    }

    $cacheKey = ('{0}|{1}' -f [string]$codex.path, [string]$context.codex_home)
    if (-not $ForceRefresh -and $script:RaymanCodexCompatibilityCache.ContainsKey($cacheKey)) {
        return $script:RaymanCodexCompatibilityCache[$cacheKey]
    }

    $minimumVersion = '0.116.0'
    $versionInfo = Get-RaymanCodexVersionInfo -WorkspaceRoot $WorkspaceRoot -AccountAlias $AccountAlias
    $probe = $null
    $compatible = $true
    $reason = 'compatible'
    $output = ''

    if (-not [string]::IsNullOrWhiteSpace([string]$versionInfo.numeric) -and -not (Test-RaymanCodexVersionAtLeast -Candidate ([string]$versionInfo.numeric) -Minimum $minimumVersion)) {
        $compatible = $false
        $reason = ('version_below_{0}' -f $minimumVersion)
        $output = [string]$versionInfo.raw
    } else {
        $probe = Invoke-RaymanCodexRawCapture -CodexHome $context.codex_home -WorkingDirectory $context.workspace_root -ArgumentList @('features', 'list')
        if ([int]$probe.exit_code -eq 0) {
            $compatible = $true
            $reason = 'feature_probe_ok'
        } elseif (Test-RaymanCodexCompatibilityOutput -Text ([string]$probe.output)) {
            $compatible = $false
            $reason = 'feature_probe_config_incompatible'
            $output = [string]$probe.output
        } else {
            $compatible = $true
            $reason = 'feature_probe_nonblocking_failure'
            $output = [string]$probe.output
        }
    }

    if ($compatible) {
        $result = [pscustomobject]@{
            compatible = $true
            updated = $false
            reason = $reason
            minimum_version = $minimumVersion
            version_before = [string]$versionInfo.numeric
            version_after = [string]$versionInfo.numeric
            output = $output
            context = $context
        }
        $script:RaymanCodexCompatibilityCache[$cacheKey] = $result
        return $result
    }

    $result = [pscustomobject]@{
        compatible = $false
        updated = $false
        reason = $reason
        minimum_version = $minimumVersion
        version_before = [string]$versionInfo.numeric
        version_after = [string]$versionInfo.numeric
        output = if ([string]::IsNullOrWhiteSpace($output)) { [string]$versionInfo.raw } else { $output }
        context = $context
    }
    $script:RaymanCodexCompatibilityCache[$cacheKey] = $result
    return $result
}

function Ensure-RaymanCodexCliCompatible {
    param(
        [string]$WorkspaceRoot = '',
        [string]$AccountAlias = '',
        [switch]$ForceRefresh
    )

    $compatibility = Get-RaymanCodexCliCompatibilityStatus -WorkspaceRoot $WorkspaceRoot -AccountAlias $AccountAlias -ForceRefresh:$ForceRefresh
    if ([bool]$compatibility.compatible) {
        return $compatibility
    }

    if (-not (Get-RaymanCodexAutoUpdateEnabled)) {
        return $compatibility
    }

    $codex = Get-RaymanCodexCommandInfo
    if (-not (Test-RaymanCodexInstallManagedByNpm -CodexCommand $codex)) {
        $result = [pscustomobject]@{
            compatible = $false
            updated = $false
            reason = 'non_npm_managed_update_unsupported'
            minimum_version = [string]$compatibility.minimum_version
            version_before = [string]$compatibility.version_before
            version_after = [string]$compatibility.version_after
            output = if ([string]::IsNullOrWhiteSpace([string]$compatibility.output)) {
                'Codex CLI is not installed from an npm-managed path; automatic upgrade is unsupported in v1.'
            } else {
                ([string]$compatibility.output + [Environment]::NewLine + 'Codex CLI is not installed from an npm-managed path; automatic upgrade is unsupported in v1.')
            }
            context = $compatibility.context
        }
        $cacheKey = ('{0}|{1}' -f [string]$codex.path, [string](Get-RaymanMapValue -Map $compatibility.context -Key 'codex_home' -Default ''))
        $script:RaymanCodexCompatibilityCache[$cacheKey] = $result
        return $result
    }

    $context = $compatibility.context
    $updateResult = Invoke-RaymanCodexGlobalUpdate -WorkspaceRoot $context.workspace_root
    if (-not [bool]$updateResult.success) {
        $result = [pscustomobject]@{
            compatible = $false
            updated = $false
            reason = 'auto_update_failed'
            minimum_version = [string]$compatibility.minimum_version
            version_before = [string]$compatibility.version_before
            version_after = [string]$compatibility.version_before
            output = [string]$updateResult.output
            context = $context
        }
        $cacheKey = ('{0}|{1}' -f [string]$codex.path, [string](Get-RaymanMapValue -Map $context -Key 'codex_home' -Default ''))
        $script:RaymanCodexCompatibilityCache[$cacheKey] = $result
        return $result
    }

    $cacheKey = ('{0}|{1}' -f [string]$codex.path, [string](Get-RaymanMapValue -Map $context -Key 'codex_home' -Default ''))
    if ($script:RaymanCodexCompatibilityCache.ContainsKey($cacheKey)) {
        $script:RaymanCodexCompatibilityCache.Remove($cacheKey)
    }

    $compatibilityAfter = Get-RaymanCodexCliCompatibilityStatus -WorkspaceRoot $WorkspaceRoot -AccountAlias $AccountAlias -ForceRefresh
    $result = [pscustomobject]@{
        compatible = [bool]$compatibilityAfter.compatible
        updated = $true
        reason = if ([bool]$compatibilityAfter.compatible) { 'auto_updated' } else { 'auto_update_incomplete' }
        minimum_version = [string]$compatibilityAfter.minimum_version
        version_before = [string]$compatibility.version_before
        version_after = [string]$compatibilityAfter.version_after
        output = if ([string]::IsNullOrWhiteSpace([string]$compatibilityAfter.output)) { [string]$updateResult.output } else { [string]$compatibilityAfter.output }
        context = $context
    }
    $script:RaymanCodexCompatibilityCache[$cacheKey] = $result
    return $result
}

function Ensure-RaymanCodexCliUpToDate {
    param(
        [string]$WorkspaceRoot = '',
        [string]$AccountAlias = '',
        [switch]$ForceRefresh,
        [switch]$ForceUpgrade,
        [string]$PolicyOverride = ''
    )

    $policy = Resolve-RaymanCodexAutoUpdatePolicy -PolicyOverride $PolicyOverride -ForceUpgrade:$ForceUpgrade
    $compatibility = Get-RaymanCodexCliCompatibilityStatus -WorkspaceRoot $WorkspaceRoot -AccountAlias $AccountAlias -ForceRefresh:$ForceRefresh
    $codex = Get-RaymanCodexCommandInfo
    $latestResult = [ordered]@{
        success = [bool]$compatibility.compatible
        compatible = [bool]$compatibility.compatible
        updated = $false
        reason = if ($policy -eq 'off') { 'policy_off' } else { [string]$compatibility.reason }
        policy = $policy
        version_before = [string]$compatibility.version_before
        version_after = [string]$compatibility.version_after
        latest_version = ''
        latest_check_attempted = $false
        latest_check_succeeded = $false
        latest_check_output = ''
        output = [string]$compatibility.output
        context = $compatibility.context
        compatibility = $compatibility
        requested_upgrade = [bool]$ForceUpgrade
        npm_managed = (Test-RaymanCodexInstallManagedByNpm -CodexCommand $codex)
    }

    if (-not $ForceUpgrade -and $policy -eq 'off') {
        return [pscustomobject]$latestResult
    }

    if (-not $ForceUpgrade -and $policy -eq 'compatibility') {
        $compatibilityResult = Ensure-RaymanCodexCliCompatible -WorkspaceRoot $WorkspaceRoot -AccountAlias $AccountAlias -ForceRefresh:$ForceRefresh
        $latestResult.compatible = [bool]$compatibilityResult.compatible
        $latestResult.success = [bool]$compatibilityResult.compatible
        $latestResult.updated = [bool]$compatibilityResult.updated
        $latestResult.reason = if ([bool]$compatibilityResult.updated) { 'compatibility_auto_updated' } else { [string]$compatibilityResult.reason }
        $latestResult.version_after = [string]$compatibilityResult.version_after
        $latestResult.output = [string]$compatibilityResult.output
        $latestResult.compatibility = $compatibilityResult
        return [pscustomobject]$latestResult
    }

    if (-not [bool]$latestResult.npm_managed) {
        if ($ForceUpgrade) {
            $latestResult.success = $false
            $latestResult.reason = 'non_npm_managed_upgrade_unsupported'
            $latestResult.output = 'Codex CLI is not installed from an npm-managed path; explicit `rayman codex upgrade` is unsupported in v1.'
            return [pscustomobject]$latestResult
        }

        if ([bool]$compatibility.compatible) {
            $latestResult.reason = 'latest_policy_skipped_non_npm_managed'
            $latestResult.output = 'Codex CLI is not installed from an npm-managed path; continuing with the current compatible version.'
            return [pscustomobject]$latestResult
        }

        $compatibilityResult = Ensure-RaymanCodexCliCompatible -WorkspaceRoot $WorkspaceRoot -AccountAlias $AccountAlias -ForceRefresh:$ForceRefresh
        $latestResult.compatible = [bool]$compatibilityResult.compatible
        $latestResult.success = [bool]$compatibilityResult.compatible
        $latestResult.updated = [bool]$compatibilityResult.updated
        $latestResult.reason = if ([bool]$compatibilityResult.updated) { 'compatibility_auto_updated' } else { [string]$compatibilityResult.reason }
        $latestResult.version_after = [string]$compatibilityResult.version_after
        $latestResult.output = [string]$compatibilityResult.output
        $latestResult.compatibility = $compatibilityResult
        return [pscustomobject]$latestResult
    }

    $registryVersion = Get-RaymanCodexLatestVersionInfo -WorkspaceRoot $WorkspaceRoot
    $latestResult.latest_check_attempted = $true
    $latestResult.latest_check_succeeded = [bool]$registryVersion.success
    $latestResult.latest_version = [string]$registryVersion.version
    $latestResult.latest_check_output = [string]$registryVersion.output

    if (-not [bool]$registryVersion.success) {
        if ($ForceUpgrade) {
            $latestResult.success = $false
            $latestResult.reason = 'latest_check_failed'
            $latestResult.output = [string]$registryVersion.output
            return [pscustomobject]$latestResult
        }

        if ([bool]$compatibility.compatible) {
            $latestResult.reason = 'latest_check_failed_nonblocking'
            $latestResult.output = [string]$registryVersion.output
            return [pscustomobject]$latestResult
        }

        $compatibilityResult = Ensure-RaymanCodexCliCompatible -WorkspaceRoot $WorkspaceRoot -AccountAlias $AccountAlias -ForceRefresh:$ForceRefresh
        $latestResult.compatible = [bool]$compatibilityResult.compatible
        $latestResult.success = [bool]$compatibilityResult.compatible
        $latestResult.updated = [bool]$compatibilityResult.updated
        $latestResult.reason = if ([bool]$compatibilityResult.updated) { 'compatibility_auto_updated' } else { [string]$compatibilityResult.reason }
        $latestResult.version_after = [string]$compatibilityResult.version_after
        $latestResult.output = if ([string]::IsNullOrWhiteSpace([string]$compatibilityResult.output)) { [string]$registryVersion.output } else { [string]$compatibilityResult.output }
        $latestResult.compatibility = $compatibilityResult
        return [pscustomobject]$latestResult
    }

    $currentVersion = [string]$compatibility.version_before
    $behindLatest = $false
    $canCompareCurrent = (-not [string]::IsNullOrWhiteSpace($currentVersion) -and -not [string]::IsNullOrWhiteSpace([string]$registryVersion.version))
    if ($canCompareCurrent) {
        $behindLatest = -not (Test-RaymanCodexVersionAtLeast -Candidate $currentVersion -Minimum ([string]$registryVersion.version))
    } elseif ($ForceUpgrade) {
        $behindLatest = $true
    } elseif ([bool]$compatibility.compatible) {
        $latestResult.reason = 'current_version_unknown_nonblocking'
        return [pscustomobject]$latestResult
    } else {
        $behindLatest = $true
    }

    if (-not $behindLatest) {
        $latestResult.reason = if ($ForceUpgrade) { 'already_latest_explicit' } else { 'already_latest' }
        return [pscustomobject]$latestResult
    }

    $updateResult = Invoke-RaymanCodexGlobalUpdate -WorkspaceRoot (Get-RaymanMapValue -Map $compatibility.context -Key 'workspace_root' -Default $WorkspaceRoot)
    if (-not [bool]$updateResult.success) {
        if ($ForceUpgrade) {
            $latestResult.success = $false
            $latestResult.reason = 'latest_update_failed'
            $latestResult.output = [string]$updateResult.output
            return [pscustomobject]$latestResult
        }

        if ([bool]$compatibility.compatible) {
            $latestResult.reason = 'latest_update_failed_nonblocking'
            $latestResult.output = [string]$updateResult.output
            return [pscustomobject]$latestResult
        }

        $latestResult.success = $false
        $latestResult.compatible = $false
        $latestResult.reason = 'latest_update_failed'
        $latestResult.output = [string]$updateResult.output
        return [pscustomobject]$latestResult
    }

    $compatibilityAfter = Get-RaymanCodexCliCompatibilityStatus -WorkspaceRoot $WorkspaceRoot -AccountAlias $AccountAlias -ForceRefresh
    $latestResult.updated = $true
    $latestResult.compatible = [bool]$compatibilityAfter.compatible
    $latestResult.version_after = [string]$compatibilityAfter.version_after
    $latestResult.compatibility = $compatibilityAfter
    $latestResult.output = if ([string]::IsNullOrWhiteSpace([string]$compatibilityAfter.output)) { [string]$updateResult.output } else { [string]$compatibilityAfter.output }

    $afterAtLatest = $false
    if (-not [string]::IsNullOrWhiteSpace([string]$compatibilityAfter.version_after) -and -not [string]::IsNullOrWhiteSpace([string]$registryVersion.version)) {
        $afterAtLatest = (Test-RaymanCodexVersionAtLeast -Candidate ([string]$compatibilityAfter.version_after) -Minimum ([string]$registryVersion.version))
    }

    if ($ForceUpgrade) {
        $latestResult.success = ([bool]$compatibilityAfter.compatible -and $afterAtLatest)
        $latestResult.reason = if ([bool]$latestResult.success) { 'updated_to_latest' } else { 'latest_update_incomplete' }
        return [pscustomobject]$latestResult
    }

    if ([bool]$compatibilityAfter.compatible -and $afterAtLatest) {
        $latestResult.success = $true
        $latestResult.reason = 'updated_to_latest'
    } elseif ([bool]$compatibilityAfter.compatible) {
        $latestResult.success = $true
        $latestResult.reason = 'latest_update_incomplete_nonblocking'
    } else {
        $latestResult.success = $false
        $latestResult.reason = 'latest_update_incomplete'
    }

    return [pscustomobject]$latestResult
}

function Get-RaymanCodexFeatureProbe {
    param(
        [string]$WorkspaceRoot = '',
        [string]$AccountAlias = '',
        [switch]$RequireManagedLogin
    )

    $loginResult = $null
    if ($RequireManagedLogin) {
        $loginResult = Assert-RaymanCodexManagedLogin -WorkspaceRoot $WorkspaceRoot -AccountAlias $AccountAlias
    }

    $context = if ($null -ne $loginResult) { $loginResult.context } else { Resolve-RaymanCodexContext -WorkspaceRoot $WorkspaceRoot -AccountAlias $AccountAlias }
    $compatibility = Ensure-RaymanCodexCliCompatible -WorkspaceRoot $context.workspace_root -AccountAlias $context.account_alias
    $versionInfo = Get-RaymanCodexVersionInfo -WorkspaceRoot $WorkspaceRoot -AccountAlias $context.account_alias
    $featureMap = @{}
    $featuresAvailable = $false

    if ([bool]$compatibility.compatible -and [bool]$versionInfo.available) {
        $capture = Invoke-RaymanCodexRawCapture -CodexHome $context.codex_home -WorkingDirectory $context.workspace_root -ArgumentList @('features', 'list')
        if ($capture.exit_code -eq 0 -and @($capture.stdout).Count -gt 0) {
            $featuresAvailable = $true
            foreach ($line in @($capture.stdout)) {
                $text = ([string]$line).Trim()
                if ($text -notmatch '^(?<name>\S+)\s+(?<stage>\S+)\s+(?<enabled>\S+)$') { continue }
                $featureMap[[string]$Matches['name']] = [pscustomobject]@{
                    stage = [string]$Matches['stage']
                    enabled = ([string]$Matches['enabled'] -eq 'true')
                }
            }
        }
    }

    return [pscustomobject]@{
        codex_available = [bool]$versionInfo.available
        codex_version = [string]$versionInfo.raw
        numeric_version = [string]$versionInfo.numeric
        features_available = $featuresAvailable
        features = $featureMap
        context = $context
        auth_status = if ($null -ne $loginResult) { $loginResult.status } else { $null }
        compatibility = $compatibility
    }
}

function Invoke-RaymanCodexCommand {
    param(
        [string]$WorkspaceRoot = '',
        [string]$AccountAlias = '',
        [string]$Profile = '',
        [string[]]$ArgumentList = @(),
        [switch]$Capture,
        [switch]$RequireManagedLogin,
        [switch]$SkipProfileInjection
    )

    $auth = if ($RequireManagedLogin) {
        Assert-RaymanCodexManagedLogin -WorkspaceRoot $WorkspaceRoot -AccountAlias $AccountAlias
    } else {
        $null
    }
    $context = if ($null -ne $auth) { $auth.context } else { Resolve-RaymanCodexContext -WorkspaceRoot $WorkspaceRoot -AccountAlias $AccountAlias -Profile $Profile }
    if ($null -ne $auth -and -not [string]::IsNullOrWhiteSpace($Profile)) {
        $context = Resolve-RaymanCodexContext -WorkspaceRoot $WorkspaceRoot -AccountAlias $context.account_alias -Profile $Profile
    }

    if ([bool]$context.managed -and -not [bool]$context.account_known) {
        throw ("Rayman Codex alias '{0}' is not registered. Run `{1}`." -f [string]$context.account_alias, [string]$context.login_repair_command)
    }

    $compatibility = Ensure-RaymanCodexCliCompatible -WorkspaceRoot $context.workspace_root -AccountAlias $context.account_alias
    if (-not [bool]$compatibility.compatible) {
        $detail = if ([string]::IsNullOrWhiteSpace([string]$compatibility.output)) { [string]$compatibility.reason } else { [string]$compatibility.output }
        throw ("Codex CLI is not compatible for alias '{0}' ({1})." -f [string]$context.account_alias, $detail)
    }

    $finalArgs = @($ArgumentList)
    if (-not $SkipProfileInjection) {
        $finalArgs = Add-RaymanCodexProfileArguments -ArgumentList $finalArgs -Profile ([string]$context.effective_profile)
    }
    $runtimeEnvironmentOverrides = Get-RaymanCodexApiKeyEnvironmentOverrides -WorkspaceRoot $context.workspace_root -AccountAlias $context.account_alias
    if ([string]$context.auth_scope -eq 'desktop_global') {
        $desktopBaseUrlState = Get-RaymanCodexEnvironmentBaseUrlState -WorkspaceRoot $context.workspace_root -AccountAlias $context.account_alias
        $runtimeEnvironmentOverrides = @{}
        if ([bool]$desktopBaseUrlState.available -and -not [string]::IsNullOrWhiteSpace([string]$desktopBaseUrlState.value)) {
            $runtimeEnvironmentOverrides['OPENAI_BASE_URL'] = [string]$desktopBaseUrlState.value
            $runtimeEnvironmentOverrides['OPENAI_API_BASE'] = [string]$desktopBaseUrlState.value
        }
    }

    $startedAt = Get-Date
    if ($Capture) {
        $captureResult = Invoke-RaymanCodexRawCapture -CodexHome $context.codex_home -WorkingDirectory $context.workspace_root -ArgumentList $finalArgs -EnvironmentOverrides $runtimeEnvironmentOverrides
        $finishedAt = Get-Date
        $durationMs = [int][Math]::Max(0, [Math]::Round(($finishedAt - $startedAt).TotalMilliseconds))
        return [pscustomobject]@{
            success = [bool]$captureResult.success
            exit_code = [int]$captureResult.exit_code
            command = [string]$captureResult.command
            output = [string]$captureResult.output
            stdout = @($captureResult.stdout)
            stderr = @($captureResult.stderr)
            error = [string]$captureResult.error
            context = $context
            argument_list = @($finalArgs)
            started_at = $startedAt.ToString('o')
            finished_at = $finishedAt.ToString('o')
            duration_ms = $durationMs
        }
    }

    $interactiveResult = Invoke-RaymanCodexRawInteractive -CodexHome $context.codex_home -WorkingDirectory $context.workspace_root -ArgumentList $finalArgs -EnvironmentOverrides $runtimeEnvironmentOverrides
    $finishedAt = Get-Date
    $durationMs = [int][Math]::Max(0, [Math]::Round(($finishedAt - $startedAt).TotalMilliseconds))
    return [pscustomobject]@{
        success = [bool]$interactiveResult.success
        exit_code = [int]$interactiveResult.exit_code
        command = [string]$interactiveResult.command
        error = [string]$interactiveResult.error
        context = $context
        argument_list = @($finalArgs)
        started_at = $startedAt.ToString('o')
        finished_at = $finishedAt.ToString('o')
        duration_ms = $durationMs
    }
}
