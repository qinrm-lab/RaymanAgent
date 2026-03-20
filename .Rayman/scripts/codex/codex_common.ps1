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

function Get-RaymanCodexRegistryPath {
    return (Join-Path (Get-RaymanCodexStateRoot) 'registry.json')
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
        $accountsOut[[string]$key] = [ordered]@{
            alias = [string](Get-RaymanMapValue -Map $item -Key 'alias' -Default $key)
            alias_key = [string](Get-RaymanMapValue -Map $item -Key 'alias_key' -Default $key)
            safe_alias = [string](Get-RaymanMapValue -Map $item -Key 'safe_alias' -Default (ConvertTo-RaymanSafeNamespace -Value ([string](Get-RaymanMapValue -Map $item -Key 'alias' -Default $key))))
            codex_home = [string](Get-RaymanMapValue -Map $item -Key 'codex_home' -Default '')
            default_profile = [string](Get-RaymanMapValue -Map $item -Key 'default_profile' -Default '')
            auth_mode_last = [string](Get-RaymanMapValue -Map $item -Key 'auth_mode_last' -Default '')
            last_status = [string](Get-RaymanMapValue -Map $item -Key 'last_status' -Default '')
            last_checked_at = [string](Get-RaymanMapValue -Map $item -Key 'last_checked_at' -Default '')
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

    $record = [ordered]@{
        alias = $normalized
        alias_key = $aliasKey
        safe_alias = $safeAlias
        codex_home = $codexHome
        default_profile = if ($SetDefaultProfile) { [string]$DefaultProfile } elseif ($null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'default_profile' -Default '') } else { '' }
        auth_mode_last = if ($null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'auth_mode_last' -Default '') } else { '' }
        last_status = if ($null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'last_status' -Default '') } else { '' }
        last_checked_at = if ($null -ne $existing) { [string](Get-RaymanMapValue -Map $existing -Key 'last_checked_at' -Default '') } else { '' }
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
        [string]$AuthModeLast = ''
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
        default_profile = [string](Get-RaymanMapValue -Map $record -Key 'default_profile' -Default '')
        auth_mode_last = if ([string]::IsNullOrWhiteSpace($AuthModeLast)) { [string](Get-RaymanMapValue -Map $record -Key 'auth_mode_last' -Default '') } else { [string]$AuthModeLast }
        last_status = [string]$Status
        last_checked_at = [string]$CheckedAt
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
        default_profile = [string]$DefaultProfile
        auth_mode_last = [string](Get-RaymanMapValue -Map $existing -Key 'auth_mode_last' -Default '')
        last_status = [string](Get-RaymanMapValue -Map $existing -Key 'last_status' -Default '')
        last_checked_at = [string](Get-RaymanMapValue -Map $existing -Key 'last_checked_at' -Default '')
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
    $accountHome = if ($accountKnown) { [string](Get-RaymanMapValue -Map $accountRecord -Key 'codex_home' -Default '') } else { Get-RaymanCodexAccountHomePath -Alias $effectiveAlias }

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
    $codexHome = if ($managed -and -not [string]::IsNullOrWhiteSpace($accountHome)) { $accountHome } else { Get-RaymanDefaultCodexHomePath }

    return [pscustomobject]@{
        workspace_root = $resolvedWorkspaceRoot
        binding_alias = $bindingAlias
        binding_profile = [string]$binding.profile
        account_alias = $effectiveAlias
        account_alias_key = $effectiveAliasKey
        account_known = $accountKnown
        account_record = $accountRecord
        managed = $managed
        codex_home = $codexHome
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
        [string]$WorkingDirectory = ''
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

    $envOverrides = @{}
    if (-not [string]::IsNullOrWhiteSpace($CodexHome)) {
        $envOverrides['CODEX_HOME'] = $CodexHome
    }

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

function Invoke-RaymanCodexRawInteractive {
    param(
        [string]$CodexHome,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = '',
        [switch]$PreferHiddenWindow
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
    }

    $envOverrides = @{}
    if (-not [string]::IsNullOrWhiteSpace($CodexHome)) {
        $envOverrides['CODEX_HOME'] = $CodexHome
    }

    Use-RaymanTemporaryEnvironment -EnvironmentOverrides $envOverrides -ScriptBlock {
        $didPush = $false
        $stdoutPath = ''
        $stderrPath = ''
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
            $result.success = $false
        } finally {
            if (-not [string]::IsNullOrWhiteSpace($stdoutPath)) {
                try { Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue } catch {}
            }
            if (-not [string]::IsNullOrWhiteSpace($stderrPath)) {
                try { Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue } catch {}
            }
            if ($didPush) {
                Pop-Location
            }
        }
    } | Out-Null

    return [pscustomobject]$result
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
        managed = [bool](Get-RaymanMapValue -Map $Status -Key 'managed' -Default $false)
        account_known = [bool](Get-RaymanMapValue -Map $Status -Key 'account_known' -Default $false)
        authenticated = [bool](Get-RaymanMapValue -Map $Status -Key 'authenticated' -Default $false)
        status = [string](Get-RaymanMapValue -Map $Status -Key 'status' -Default 'unbound')
        exit_code = [int](Get-RaymanMapValue -Map $Status -Key 'exit_code' -Default 0)
        command = [string](Get-RaymanMapValue -Map $Status -Key 'command' -Default 'codex login status')
        output = @((Get-RaymanMapValue -Map $Status -Key 'output' -Default @()) | ForEach-Object { [string]$_ })
        repair_command = [string](Get-RaymanMapValue -Map $Status -Key 'repair_command' -Default '')
    }
    Write-RaymanUtf8NoBom -Path $path -Content (($payload | ConvertTo-Json -Depth 8).TrimEnd() + "`n")
    return $path
}

function Get-RaymanCodexLoginStatus {
    param(
        [string]$WorkspaceRoot = '',
        [string]$AccountAlias = '',
        [switch]$SkipReportWrite
    )

    $context = Resolve-RaymanCodexContext -WorkspaceRoot $WorkspaceRoot -AccountAlias $AccountAlias
    $checkedAt = (Get-Date).ToString('o')

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
        managed = [bool]$context.managed
        account_known = [bool]$context.account_known
        authenticated = $false
        status = 'unbound'
        exit_code = 0
        command = 'codex login status'
        output = @()
        repair_command = [string]$context.login_repair_command
    }

    if (-not [bool]$context.managed) {
        $status.status = 'unbound'
    } elseif (-not [bool]$context.account_known) {
        $status.status = 'unknown_alias'
        $status.exit_code = 2
        $status.output = @(('Rayman Codex alias not registered: {0}' -f [string]$context.account_alias))
    } else {
        $compatibility = Ensure-RaymanCodexCliCompatible -WorkspaceRoot $context.workspace_root -AccountAlias $context.account_alias
        if (-not [bool]$compatibility.compatible) {
            $status.status = 'compatibility_failed'
            $status.exit_code = 3
            $status.output = @([string]$compatibility.output)
        } else {
            $capture = Invoke-RaymanCodexRawCapture -CodexHome $context.codex_home -WorkingDirectory $context.workspace_root -ArgumentList @('login', 'status')
            $status.exit_code = [int]$capture.exit_code
            $outputLines = @($capture.stdout + $capture.stderr | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
            if ($outputLines.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$capture.output)) {
                $outputLines = @(([string]$capture.output).Trim())
            }
            $status.output = @($outputLines)
            $probeText = if ($outputLines.Count -gt 0) { ($outputLines -join "`n") } else { [string]$capture.output }
            if ($capture.success) {
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

        Set-RaymanCodexAccountStatus -Alias $context.account_alias -Status $status.status -CheckedAt $checkedAt -AuthModeLast 'device_auth' | Out-Null
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
            minimum_version = '0.5.80'
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

    $minimumVersion = '0.5.80'
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
        [switch]$ForceUpgrade
    )

    $policy = if ($ForceUpgrade) { 'latest' } else { Get-RaymanCodexAutoUpdatePolicy }
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

    if ($Capture) {
        $captureResult = Invoke-RaymanCodexRawCapture -CodexHome $context.codex_home -WorkingDirectory $context.workspace_root -ArgumentList $finalArgs
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
        }
    }

    $interactiveResult = Invoke-RaymanCodexRawInteractive -CodexHome $context.codex_home -WorkingDirectory $context.workspace_root -ArgumentList $finalArgs
    return [pscustomobject]@{
        success = [bool]$interactiveResult.success
        exit_code = [int]$interactiveResult.exit_code
        command = [string]$interactiveResult.command
        error = [string]$interactiveResult.error
        context = $context
        argument_list = @($finalArgs)
    }
}
