Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:RaymanWslInteropAvailabilityCache = $null

$raymanCodexCommonPath = Join-Path $PSScriptRoot 'scripts\codex\codex_common.ps1'
if (Test-Path -LiteralPath $raymanCodexCommonPath -PathType Leaf) {
    . $raymanCodexCommonPath
}

function Get-RaymanWorkspaceRootDefault {
    if (-not [string]::IsNullOrWhiteSpace([string]$PSScriptRoot)) {
        return (Split-Path -Parent $PSScriptRoot)
    }

    try {
        $cwd = (Get-Location).Path
        return $cwd
    } catch {
        return [System.IO.Directory]::GetCurrentDirectory()
    }
}

function Resolve-RaymanWorkspaceRoot {
    param(
        [string]$StartPath = ''
    )

    $candidate = if ([string]::IsNullOrWhiteSpace($StartPath)) {
        Get-RaymanWorkspaceRootDefault
    } else {
        $StartPath
    }

    try {
        $candidate = [System.IO.Path]::GetFullPath($candidate)
    } catch {}

    while (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $raymanDir = Join-Path $candidate '.Rayman'
        if (Test-Path -LiteralPath $raymanDir -PathType Container) {
            return $candidate
        }

        $parent = Split-Path -Parent $candidate
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $candidate) {
            break
        }
        $candidate = $parent
    }

    return (Get-RaymanWorkspaceRootDefault)
}

function Get-RaymanPathComparisonValue {
    param(
        [string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
    $candidate = [string]$PathValue
    if ($candidate.StartsWith('Microsoft.PowerShell.Core\FileSystem::', [System.StringComparison]::OrdinalIgnoreCase)) {
        $candidate = $candidate.Substring('Microsoft.PowerShell.Core\FileSystem::'.Length)
    }
    $candidate = $candidate.Trim().Trim('"').Trim("'")
    if ($candidate -match '^/mnt/([A-Za-z])(?:/(.*))?$') {
        $drive = [string]$Matches[1]
        $rest = if ($Matches.Count -gt 2) { [string]$Matches[2] } else { '' }
        if ([string]::IsNullOrWhiteSpace($rest)) {
            $candidate = ('{0}:\' -f $drive.ToUpperInvariant())
        } else {
            $candidate = ('{0}:\{1}' -f $drive.ToUpperInvariant(), ($rest -replace '/', '\'))
        }
    }
    try {
        $full = [System.IO.Path]::GetFullPath($candidate)
    } catch {
        $full = $candidate
    }
    return ($full.TrimEnd('\', '/') -replace '\\', '/').ToLowerInvariant()
}

function Get-RaymanPathComparisonVariants {
    param(
        [string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return @() }

    $variants = New-Object System.Collections.Generic.List[string]
    $primary = Get-RaymanPathComparisonValue -PathValue $PathValue
    if (-not [string]::IsNullOrWhiteSpace($primary)) {
        $variants.Add($primary) | Out-Null
    }

    $raw = [string]$PathValue
    if ($raw.StartsWith('Microsoft.PowerShell.Core\FileSystem::', [System.StringComparison]::OrdinalIgnoreCase)) {
        $raw = $raw.Substring('Microsoft.PowerShell.Core\FileSystem::'.Length)
    }
    $raw = $raw.Trim().Trim('"').Trim("'")

    if ($raw -match '^([A-Za-z]):[\\/]*(.*)$') {
        $drive = ([string]$Matches[1]).ToLowerInvariant()
        $rest = [string]$Matches[2]
        $restNorm = ($rest -replace '\\', '/').Trim('/')
        $wslVariant = if ([string]::IsNullOrWhiteSpace($restNorm)) {
            "/mnt/$drive"
        } else {
            "/mnt/$drive/$restNorm"
        }
        $normalizedWsl = Get-RaymanPathComparisonValue -PathValue $wslVariant
        if (-not [string]::IsNullOrWhiteSpace($normalizedWsl) -and $variants -notcontains $normalizedWsl) {
            $variants.Add($normalizedWsl) | Out-Null
        }
    } elseif ($raw -match '^/mnt/([A-Za-z])(?:/(.*))?$') {
        $drive = ([string]$Matches[1]).ToUpperInvariant()
        $rest = if ($Matches.Count -gt 2) { [string]$Matches[2] } else { '' }
        $windowsVariant = if ([string]::IsNullOrWhiteSpace($rest)) {
            ('{0}:\' -f $drive)
        } else {
            ('{0}:\{1}' -f $drive, ($rest -replace '/', '\'))
        }
        $normalizedWindows = Get-RaymanPathComparisonValue -PathValue $windowsVariant
        if (-not [string]::IsNullOrWhiteSpace($normalizedWindows) -and $variants -notcontains $normalizedWindows) {
            $variants.Add($normalizedWindows) | Out-Null
        }
    }

    return @($variants | Select-Object -Unique)
}

function Test-RaymanPathsEquivalent {
    param(
        [string]$LeftPath,
        [string]$RightPath
    )

    $leftVariants = @(Get-RaymanPathComparisonVariants -PathValue $LeftPath)
    $rightVariants = @(Get-RaymanPathComparisonVariants -PathValue $RightPath)
    if ($leftVariants.Count -eq 0 -or $rightVariants.Count -eq 0) { return $false }

    foreach ($left in $leftVariants) {
        if ($rightVariants -contains $left) {
            return $true
        }
    }
    return $false
}

function Convert-RaymanPathForCurrentHost {
    param(
        [string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }

    $candidate = [string]$PathValue
    if ($candidate.StartsWith('Microsoft.PowerShell.Core\FileSystem::', [System.StringComparison]::OrdinalIgnoreCase)) {
        $candidate = $candidate.Substring('Microsoft.PowerShell.Core\FileSystem::'.Length)
    }
    $candidate = $candidate.Trim().Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($candidate)) { return '' }

    $isWindowsHost = Test-RaymanWindowsPlatform
    if ($isWindowsHost) {
        if ($candidate -match '^/mnt/([A-Za-z])(?:/(.*))?$') {
            $drive = ([string]$Matches[1]).ToUpperInvariant()
            $rest = if ($Matches.Count -gt 2) { [string]$Matches[2] } else { '' }
            if ([string]::IsNullOrWhiteSpace($rest)) {
                return ('{0}:\' -f $drive)
            }
            return ('{0}:\{1}' -f $drive, ($rest -replace '/', '\'))
        }
        return $candidate
    }

    if ($candidate -match '^([A-Za-z]):[\\/]*(.*)$') {
        $drive = ([string]$Matches[1]).ToLowerInvariant()
        $rest = [string]$Matches[2]
        $restNorm = ($rest -replace '\\', '/').Trim('/')
        if ([string]::IsNullOrWhiteSpace($restNorm)) {
            return "/mnt/$drive"
        }
        return "/mnt/$drive/$restNorm"
    }

    return $candidate
}

function Resolve-RaymanLiteralPath {
    param(
        [string]$PathValue,
        [switch]$AllowMissing
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($item in @([string]$PathValue, (Convert-RaymanPathForCurrentHost -PathValue $PathValue))) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        $normalized = [string]$item
        if ($normalized.StartsWith('Microsoft.PowerShell.Core\FileSystem::', [System.StringComparison]::OrdinalIgnoreCase)) {
            $normalized = $normalized.Substring('Microsoft.PowerShell.Core\FileSystem::'.Length)
        }
        $normalized = $normalized.Trim().Trim('"').Trim("'")
        if ([string]::IsNullOrWhiteSpace($normalized)) { continue }
        if ($candidates -notcontains $normalized) {
            $candidates.Add($normalized) | Out-Null
        }
    }

    foreach ($candidate in @($candidates.ToArray())) {
        try {
            return ((Resolve-Path -LiteralPath $candidate -ErrorAction Stop | Select-Object -First 1).Path)
        } catch {}
    }

    foreach ($candidate in @($candidates.ToArray())) {
        try {
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        } catch {}
    }

    if ($AllowMissing -and $candidates.Count -gt 0) {
        return [string]$candidates[0]
    }

    return ''
}

function Get-RaymanReportWorkspaceRoot {
    param(
        [object]$Report
    )

    if ($null -eq $Report) { return '' }
    $prop = $Report.PSObject.Properties['workspace_root']
    if ($null -eq $prop -or [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
        return ''
    }
    return [string]$prop.Value
}

function Test-RaymanReportWorkspaceMatchesRoot {
    param(
        [object]$Report,
        [string]$WorkspaceRoot
    )

    $reportRoot = Get-RaymanReportWorkspaceRoot -Report $Report
    if ([string]::IsNullOrWhiteSpace($reportRoot)) {
        return $true
    }
    return (Test-RaymanPathsEquivalent -LeftPath $WorkspaceRoot -RightPath $reportRoot)
}

function Write-Info([string]$Message) {
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Warn([string]$Message) {
    Write-Host $Message -ForegroundColor Yellow
}

function Write-ErrorInfo([string]$Message) {
    Write-Host $Message -ForegroundColor Red
}

function Convert-RaymanStringToBool {
    param(
        [string]$Value,
        [bool]$Default = $false
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Default
    }

    switch ($Value.Trim().ToLowerInvariant()) {
        '1' { return $true }
        'true' { return $true }
        'yes' { return $true }
        'y' { return $true }
        'on' { return $true }
        '0' { return $false }
        'false' { return $false }
        'no' { return $false }
        'n' { return $false }
        'off' { return $false }
        default { return $Default }
    }
}

function Get-RaymanEnvBool {
    param(
        [string]$Name,
        [bool]$Default = $false
    )

    return (Convert-RaymanStringToBool -Value ([Environment]::GetEnvironmentVariable($Name)) -Default $Default)
}

function Get-RaymanWorkspaceEnvBool {
    param(
        [string]$WorkspaceRoot,
        [string]$Name,
        [bool]$Default = $false
    )

    $processValue = [Environment]::GetEnvironmentVariable($Name)
    if (-not [string]::IsNullOrWhiteSpace([string]$processValue)) {
        return (Convert-RaymanStringToBool -Value $processValue -Default $Default)
    }

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot) -or [string]::IsNullOrWhiteSpace($Name)) {
        return $Default
    }

    $workspaceRootPath = Resolve-RaymanLiteralPath -PathValue $WorkspaceRoot -AllowMissing
    if ([string]::IsNullOrWhiteSpace($workspaceRootPath)) {
        return $Default
    }

    $envFile = [System.IO.Path]::Combine($workspaceRootPath, '.rayman.env.ps1')
    if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
        return $Default
    }

    try {
        $pattern = ('^\s*\$env:{0}\s*=\s*(?<value>[^#\r\n]+?)\s*(?:#.*)?$' -f [regex]::Escape($Name))
        foreach ($line in @(Get-Content -LiteralPath $envFile -Encoding UTF8)) {
            $candidate = [string]$line
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                continue
            }
            $match = [regex]::Match($candidate, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $match.Success) {
                continue
            }

            $rawValue = [string]$match.Groups['value'].Value
            if (($rawValue.StartsWith("'") -and $rawValue.EndsWith("'")) -or ($rawValue.StartsWith('"') -and $rawValue.EndsWith('"'))) {
                if ($rawValue.Length -ge 2) {
                    $rawValue = $rawValue.Substring(1, $rawValue.Length - 2)
                }
            }

            return (Convert-RaymanStringToBool -Value $rawValue -Default $Default)
        }
    } catch {}

    return $Default
}

function Get-RaymanWorkspaceEnvString {
    param(
        [string]$WorkspaceRoot,
        [string]$Name,
        [string]$Default = ''
    )

    $processValue = [Environment]::GetEnvironmentVariable($Name)
    if (-not [string]::IsNullOrWhiteSpace([string]$processValue)) {
        return [string]$processValue
    }

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot) -or [string]::IsNullOrWhiteSpace($Name)) {
        return $Default
    }

    $workspaceRootPath = Resolve-RaymanLiteralPath -PathValue $WorkspaceRoot -AllowMissing
    if ([string]::IsNullOrWhiteSpace($workspaceRootPath)) {
        return $Default
    }

    $envFile = [System.IO.Path]::Combine($workspaceRootPath, '.rayman.env.ps1')
    if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
        return $Default
    }

    try {
        $pattern = ('^\s*\$env:{0}\s*=\s*(?<value>[^#\r\n]+?)\s*(?:#.*)?$' -f [regex]::Escape($Name))
        foreach ($line in @(Get-Content -LiteralPath $envFile -Encoding UTF8)) {
            $candidate = [string]$line
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                continue
            }
            $match = [regex]::Match($candidate, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $match.Success) {
                continue
            }

            $rawValue = [string]$match.Groups['value'].Value
            if (($rawValue.StartsWith("'") -and $rawValue.EndsWith("'")) -or ($rawValue.StartsWith('"') -and $rawValue.EndsWith('"'))) {
                if ($rawValue.Length -ge 2) {
                    $rawValue = $rawValue.Substring(1, $rawValue.Length - 2)
                }
            }

            return $rawValue
        }
    } catch {}

    return $Default
}

function Get-RaymanWorkspaceEnvStringEntry {
    param(
        [string]$WorkspaceRoot,
        [string]$Name
    )

    $empty = [pscustomobject]@{
        configured = $false
        source = 'default'
        value = ''
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $empty
    }

    $processValue = [Environment]::GetEnvironmentVariable($Name)
    if (-not [string]::IsNullOrWhiteSpace([string]$processValue)) {
        return [pscustomobject]@{
            configured = $true
            source = 'process'
            value = [string]$processValue
        }
    }

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        return $empty
    }

    $workspaceRootPath = Resolve-RaymanLiteralPath -PathValue $WorkspaceRoot -AllowMissing
    if ([string]::IsNullOrWhiteSpace($workspaceRootPath)) {
        return $empty
    }

    $envFile = [System.IO.Path]::Combine($workspaceRootPath, '.rayman.env.ps1')
    if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
        return $empty
    }

    try {
        $pattern = ('^\s*\$env:{0}\s*=\s*(?<value>[^#\r\n]+?)\s*(?:#.*)?$' -f [regex]::Escape($Name))
        foreach ($line in @(Get-Content -LiteralPath $envFile -Encoding UTF8)) {
            $candidate = [string]$line
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                continue
            }

            $match = [regex]::Match($candidate, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $match.Success) {
                continue
            }

            $rawValue = [string]$match.Groups['value'].Value
            if (($rawValue.StartsWith("'") -and $rawValue.EndsWith("'")) -or ($rawValue.StartsWith('"') -and $rawValue.EndsWith('"'))) {
                if ($rawValue.Length -ge 2) {
                    $rawValue = $rawValue.Substring(1, $rawValue.Length - 2)
                }
            }

            return [pscustomobject]@{
                configured = $true
                source = 'workspace_env'
                value = $rawValue
            }
        }
    } catch {}

    return $empty
}

function Set-RaymanManagedTextBlock {
    param(
        [string]$Path,
        [string]$BeginMarker,
        [string]$EndMarker,
        [string[]]$Lines = @(),
        [string]$AuditRoot = '',
        [string]$Label = 'managed-text-block'
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
            ok = $true
            changed = $false
            path = $Path
            reason = 'unchanged'
        }
    }

    $resolvedAuditRoot = if ([string]::IsNullOrWhiteSpace($AuditRoot)) { Split-Path -Parent $Path } else { $AuditRoot }
    $writeResult = Set-RaymanManagedUtf8File -Path $Path -Content $updated -AuditRoot $resolvedAuditRoot -Label $Label
    if (-not [bool]$writeResult.ok) {
        return [pscustomobject]@{
            ok = $false
            changed = $false
            path = $Path
            reason = [string]$writeResult.reason
            error_message = [string]$writeResult.error_message
        }
    }

    return [pscustomobject]@{
        ok = $true
        changed = [bool]$writeResult.changed
        path = $Path
        reason = [string]$writeResult.reason
        error_message = ''
    }
}

function Normalize-RaymanInteractionMode {
    param(
        [string]$Mode,
        [string]$Default = 'detailed'
    )

    $allowEmptyFallback = [string]::IsNullOrWhiteSpace([string]$Default)
    $fallback = if ($allowEmptyFallback) { '' } else { ([string]$Default).Trim().ToLowerInvariant() }
    switch (([string]$fallback).Trim().ToLowerInvariant()) {
        'general' { $fallback = 'general' }
        'simple' { $fallback = 'simple' }
        'detailed' { $fallback = 'detailed' }
        default {
            if ($allowEmptyFallback) {
                $fallback = ''
            } else {
                $fallback = 'detailed'
            }
        }
    }

    $candidate = if ([string]::IsNullOrWhiteSpace([string]$Mode)) { '' } else { ([string]$Mode).Trim().ToLowerInvariant() }
    switch ($candidate) {
        'detailed' { return 'detailed' }
        'general' { return 'general' }
        'simple' { return 'simple' }
        default { return $fallback }
    }
}

function Get-RaymanInteractionMode {
    param([string]$WorkspaceRoot = '')

    $raw = [string](Get-RaymanWorkspaceEnvString -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_INTERACTION_MODE' -Default 'detailed')
    return (Normalize-RaymanInteractionMode -Mode $raw -Default 'detailed')
}

function Get-RaymanInteractionModeLabel {
    param([string]$Mode)

    switch (Normalize-RaymanInteractionMode -Mode $Mode -Default 'detailed') {
        'general' { return '一般' }
        'simple' { return '简单' }
        default { return '详细' }
    }
}

function Get-RaymanInteractionModeDescription {
    param([string]$Mode)

    switch (Normalize-RaymanInteractionMode -Mode $Mode -Default 'detailed') {
        'general' {
            return '当歧义会明显改变结果、范围、实现路径、风险、测试期望或返工成本时先给 plan、选项与明确验收标准；次要细节可带默认假设继续。'
        }
        'simple' {
            return '只在高风险、不可逆、跨工作区、发布/架构级或明显可能走错方向时先给 plan、选项与明确验收标准；其余按推荐默认继续并写出假设。'
        }
        default {
            return '只要目标不明确、存在明显多路径或不同方案结果差异明显，就先给 plan、解释选项与结果，并写出明确验收标准。'
        }
    }
}

function Get-RaymanInteractionModeExamples {
    param([string]$Mode)

    switch (Normalize-RaymanInteractionMode -Mode $Mode -Default 'detailed') {
        'general' { return '适合中等规模确认：关键分歧先问，低影响细节可默认。' }
        'simple' { return '适合低打断：仅高风险场景停下，其余快速执行。' }
        default { return '适合高协作密度：尽可能多把关键分歧摊开说明后再执行。' }
    }
}

function Get-RaymanInteractionModePromptPreamble {
    param([string]$WorkspaceRoot = '')

    $mode = Get-RaymanInteractionMode -WorkspaceRoot $WorkspaceRoot
    $modeLabel = Get-RaymanInteractionModeLabel -Mode $mode
    $activeRule = Get-RaymanInteractionModeDescription -Mode $mode

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('[RaymanInteractionMode]')
    $lines.Add(('mode={0}' -f $mode))
    $lines.Add(('mode_label={0}' -f $modeLabel))
    $lines.Add(('active_rule={0}' -f $activeRule))
    $lines.Add('ambiguity_floor=When the prompt is not clear enough and ambiguity can affect goal, scope, implementation path, risk, test expectations, target workspace, or rollback, stop first and provide concrete options plus explicit acceptance criteria. This applies outside Codex Plan Mode.')
    $lines.Add('detailed=When the goal is unclear, multiple implementation paths exist, or outcomes differ meaningfully, stop first, explain options, state acceptance criteria, and collect more user choices before locking the spec.')
    $lines.Add('general=Ask when ambiguity materially changes outcome, scope, implementation path, risk, test expectations, or rework cost; if you ask, include concrete options and explicit acceptance criteria; proceed on lower-impact details with explicit assumptions.')
    $lines.Add('simple=Ask only on high-risk, irreversible, cross-workspace, release/architecture-level, or likely-wrong-direction ambiguity; if you ask, include concrete options and explicit acceptance criteria; otherwise proceed with explicit assumptions.')
    $lines.Add('hard_gates=Cross-workspace target selection, policy blocks, release gates, and dangerous operations still require a stop.')
    $lines.Add('full_auto_note=Full-auto approves code changes, but it does not authorize guessing user intent when multiple meaningful paths exist.')
    $lines.Add('[/RaymanInteractionMode]')
    return ($lines -join "`n")
}

function Set-RaymanWorkspaceEnvValue {
    param(
        [string]$WorkspaceRoot,
        [string]$Name,
        [string]$Value,
        [switch]$AddIfMissing,
        [string]$ManagedBlockId = '',
        [string]$ManagedBy = 'Rayman'
    )

    $result = [ordered]@{
        Ok = $false
        Updated = $false
        Added = $false
        Reason = ''
        Path = ''
        PreviousValue = ''
        NewValue = [string]$Value
    }

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot) -or -not (Test-Path -LiteralPath $WorkspaceRoot -PathType Container)) {
        $result.Reason = 'workspace_not_found'
        return [pscustomobject]$result
    }
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $result.Reason = 'name_required'
        return [pscustomobject]$result
    }

    $envFile = Join-Path $WorkspaceRoot '.rayman.env.ps1'
    $result.Path = $envFile
    $raw = ''
    if (Test-Path -LiteralPath $envFile -PathType Leaf) {
        try {
            $raw = Get-Content -LiteralPath $envFile -Raw -Encoding UTF8
        } catch {
            $result.Reason = ("read_failed:{0}" -f $_.Exception.Message)
            return [pscustomobject]$result
        }
    } elseif (-not $AddIfMissing) {
        $result.Reason = 'env_file_missing'
        return [pscustomobject]$result
    }
    if ($null -eq $raw) { $raw = '' }

    $newline = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
    $lines = @([regex]::Split($raw, "\r?\n"))
    $pattern = ('^(?<indent>\s*)\$env:{0}\s*=\s*(?<raw>[^#\r\n]+?)(?<suffix>\s*(?:#.*)?)$' -f [regex]::Escape($Name))
    $matchIndex = -1
    $replacementLine = ''

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]
        $match = [regex]::Match($line, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) {
            continue
        }

        $matchIndex = $i
        $rawValue = [string]$match.Groups['raw'].Value
        $trimmedValue = $rawValue.Trim()
        if (($trimmedValue.StartsWith("'") -and $trimmedValue.EndsWith("'")) -or ($trimmedValue.StartsWith('"') -and $trimmedValue.EndsWith('"'))) {
            if ($trimmedValue.Length -ge 2) {
                $trimmedValue = $trimmedValue.Substring(1, $trimmedValue.Length - 2)
            }
        }
        $result.PreviousValue = $trimmedValue
        $replacementLine = ('{0}$env:{1} = ''{2}''{3}' -f [string]$match.Groups['indent'].Value, $Name, ($Value -replace "'", "''"), [string]$match.Groups['suffix'].Value)
        break
    }

    if ($matchIndex -ge 0) {
        if ([string]$lines[$matchIndex] -eq $replacementLine) {
            $result.Ok = $true
            return [pscustomobject]$result
        }

        $lines[$matchIndex] = $replacementLine
        $newContent = ($lines -join $newline)
        $writeResult = Set-RaymanManagedUtf8File -Path $envFile -Content $newContent -AuditRoot $WorkspaceRoot -Label ("workspace-env:{0}" -f $Name)
        if (-not [bool]$writeResult.ok) {
            $detail = if (-not [string]::IsNullOrWhiteSpace([string]$writeResult.error_message)) {
                [string]$writeResult.error_message
            } else {
                [string]$writeResult.reason
            }
            $result.Reason = ("write_failed:{0}" -f $detail)
            return [pscustomobject]$result
        }

        $result.Ok = $true
        $result.Updated = [bool]$writeResult.changed
        return [pscustomobject]$result
    }

    if (-not $AddIfMissing) {
        $result.Reason = 'assignment_not_found'
        return [pscustomobject]$result
    }

    $blockId = if ([string]::IsNullOrWhiteSpace([string]$ManagedBlockId)) { ('RAYMAN:ENV:{0}' -f $Name) } else { [string]$ManagedBlockId }
    $beginMarker = ('# {0}:BEGIN' -f $blockId)
    $endMarker = ('# {0}:END' -f $blockId)
    $escapedValue = [string]$Value -replace "'", "''"
    $blockLines = @(
        ('# {0} managed workspace env assignment.' -f $ManagedBy),
        ('if ([string]::IsNullOrWhiteSpace([string]`$env:{0})) {{' -f $Name),
        ("    `$env:{0} = '{1}'" -f $Name, $escapedValue),
        '}'
    )
    $blockResult = Set-RaymanManagedTextBlock `
        -Path $envFile `
        -BeginMarker $beginMarker `
        -EndMarker $endMarker `
        -AuditRoot $WorkspaceRoot `
        -Label ("workspace-env:{0}" -f $Name) `
        -Lines $blockLines
    if (-not [bool]$blockResult.ok) {
        $detail = if ($blockResult.PSObject.Properties['error_message']) { [string]$blockResult.error_message } else { [string]$blockResult.reason }
        $result.Reason = ("write_failed:{0}" -f $detail)
        return [pscustomobject]$result
    }

    $result.Ok = $true
    $result.Updated = [bool]$blockResult.changed
    $result.Added = $true
    $result.Reason = 'added_managed_block'
    return [pscustomobject]$result
}

function Remove-RaymanJsonComments {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $sb = New-Object System.Text.StringBuilder
    $inString = $false
    $escapeNext = $false
    $inLineComment = $false
    $inBlockComment = $false

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }

        if ($inLineComment) {
            if ($c -eq "`n") {
                $inLineComment = $false
                [void]$sb.Append($c)
            }
            continue
        }

        if ($inBlockComment) {
            if ($c -eq '*' -and $next -eq '/') {
                $inBlockComment = $false
                $i++
            }
            continue
        }

        if ($inString) {
            [void]$sb.Append($c)
            if ($escapeNext) {
                $escapeNext = $false
            } elseif ($c -eq '\') {
                $escapeNext = $true
            } elseif ($c -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($c -eq '"') {
            $inString = $true
            [void]$sb.Append($c)
            continue
        }

        if ($c -eq '/' -and $next -eq '/') {
            $inLineComment = $true
            $i++
            continue
        }

        if ($c -eq '/' -and $next -eq '*') {
            $inBlockComment = $true
            $i++
            continue
        }

        [void]$sb.Append($c)
    }

    return $sb.ToString()
}

function Remove-RaymanJsonTrailingCommas {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $sb = New-Object System.Text.StringBuilder
    $inString = $false
    $escapeNext = $false

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]

        if ($inString) {
            [void]$sb.Append($c)
            if ($escapeNext) {
                $escapeNext = $false
            } elseif ($c -eq '\') {
                $escapeNext = $true
            } elseif ($c -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($c -eq '"') {
            $inString = $true
            [void]$sb.Append($c)
            continue
        }

        if ($c -eq ',') {
            $j = $i + 1
            while ($j -lt $Text.Length -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
            if ($j -lt $Text.Length -and ($Text[$j] -eq '}' -or $Text[$j] -eq ']')) {
                continue
            }
        }

        [void]$sb.Append($c)
    }

    return $sb.ToString()
}

function ConvertFrom-RaymanJsonDeserializerValue {
    param(
        [object]$Value,
        [switch]$AsHashtable
    )

    if ($null -eq $Value) { return $null }

    if ($Value -is [System.Collections.IDictionary]) {
        $map = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $map[[string]$key] = ConvertFrom-RaymanJsonDeserializerValue -Value $Value[$key] -AsHashtable:$AsHashtable
        }
        if ($AsHashtable) {
            return $map
        }
        return [pscustomobject]$map
    }

    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Value) {
            $items.Add((ConvertFrom-RaymanJsonDeserializerValue -Value $item -AsHashtable:$AsHashtable)) | Out-Null
        }
        return @($items.ToArray())
    }

    return $Value
}

function ConvertFrom-RaymanJsonText {
    param(
        [string]$Text,
        [switch]$AsHashtable
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $jsonDocumentType = 'System.Text.Json.JsonDocument' -as [type]
    if ($null -ne $jsonDocumentType) {
        $jsonValueKindType = 'System.Text.Json.JsonValueKind' -as [type]
        $convertElement = $null
        $convertElement = {
            param([object]$Element)

            switch ($Element.ValueKind) {
                $jsonValueKindType::Object {
                    $map = [ordered]@{}
                    foreach ($prop in $Element.EnumerateObject()) {
                        $map[[string]$prop.Name] = & $convertElement $prop.Value
                    }
                    if ($AsHashtable) { return $map }
                    return [pscustomobject]$map
                }
                $jsonValueKindType::Array {
                    $items = New-Object System.Collections.Generic.List[object]
                    foreach ($child in $Element.EnumerateArray()) {
                        $items.Add((& $convertElement $child)) | Out-Null
                    }
                    return @($items.ToArray())
                }
                $jsonValueKindType::String { return $Element.GetString() }
                $jsonValueKindType::Number {
                    $longValue = 0L
                    if ($Element.TryGetInt64([ref]$longValue)) { return $longValue }
                    $doubleValue = 0.0
                    if ($Element.TryGetDouble([ref]$doubleValue)) { return $doubleValue }
                    return $Element.ToString()
                }
                $jsonValueKindType::True { return $true }
                $jsonValueKindType::False { return $false }
                $jsonValueKindType::Null { return $null }
                default { return $Element.ToString() }
            }
        }

        $doc = $null
        try {
            $doc = $jsonDocumentType::Parse($Text)
            return (& $convertElement $doc.RootElement)
        } finally {
            if ($null -ne $doc) { $doc.Dispose() }
        }
    }

    $serializer = $null
    try { Add-Type -AssemblyName 'System.Web.Extensions' -ErrorAction SilentlyContinue | Out-Null } catch {}
    try {
        $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    } catch {
        $serializer = $null
    }
    if ($null -ne $serializer) {
        try { $serializer.MaxJsonLength = [int]::MaxValue } catch {}
        $parsed = $serializer.DeserializeObject($Text)
        return (ConvertFrom-RaymanJsonDeserializerValue -Value $parsed -AsHashtable:$AsHashtable)
    }

    $convertFromJsonSupportsHashtable = $false
    try {
        $convertFromJsonCmd = Get-Command ConvertFrom-Json -ErrorAction Stop
        $convertFromJsonSupportsHashtable = $convertFromJsonCmd.Parameters.ContainsKey('AsHashtable')
    } catch {}
    if ($AsHashtable) {
        if (-not $convertFromJsonSupportsHashtable) {
            throw 'ConvertFrom-Json -AsHashtable is unavailable and no alternate JSON parser was found.'
        }
        return ($Text | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
    }
    return ($Text | ConvertFrom-Json -ErrorAction Stop)
}

function Read-RaymanJsonFile {
    param(
        [string]$Path,
        [switch]$AsHashtable
    )

    $result = [ordered]@{
        Exists = $false
        ParseFailed = $false
        Obj = $null
        Error = ''
        Sanitized = $false
        Path = $Path
    }

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]$result
    }

    $result.Exists = $true
    $raw = ''
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    } catch {
        $result.ParseFailed = $true
        $result.Error = $_.Exception.Message
        return [pscustomobject]$result
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]$result
    }

    $clean = Remove-RaymanJsonTrailingCommas -Text (Remove-RaymanJsonComments -Text $raw)
    $result.Sanitized = ($clean -ne $raw)

    try {
        $result.Obj = ConvertFrom-RaymanJsonText -Text $clean -AsHashtable:$AsHashtable
    } catch {
        $result.ParseFailed = $true
        $result.Error = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Get-RaymanWorkspaceApprovalMode {
    param(
        [string]$WorkspaceRoot = ''
    )

    $raw = [string](Get-RaymanWorkspaceEnvString -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_APPROVAL_MODE' -Default 'full-auto')
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return 'full-auto'
    }
    return $raw.Trim().ToLowerInvariant()
}

function Get-RaymanSetupPostCheckMode {
    param(
        [string]$WorkspaceRoot = ''
    )

    $raw = [string](Get-RaymanWorkspaceEnvString -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_SETUP_POST_CHECK_MODE' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        switch ($raw.Trim().ToLowerInvariant()) {
            'prompt' { return 'prompt' }
            'strict' { return 'strict' }
            'normal' { return 'normal' }
            'skip' { return 'skip' }
        }
    }

    if ((Get-RaymanWorkspaceApprovalMode -WorkspaceRoot $WorkspaceRoot) -eq 'full-auto') {
        return 'strict'
    }

    $interactive = $true
    try {
        $interactive = (-not [Console]::IsInputRedirected)
    } catch {
        $interactive = $true
    }

    if ($interactive) {
        return 'prompt'
    }

    return 'strict'
}

function Get-RaymanVscodeBootstrapProfile {
    param(
        [string]$WorkspaceRoot = ''
    )

    $raw = [string](Get-RaymanWorkspaceEnvString -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_VSCODE_BOOTSTRAP_PROFILE' -Default 'conservative')
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return 'conservative'
    }

    switch ($raw.Trim().ToLowerInvariant()) {
        'active' { return 'active' }
        'strict' { return 'strict' }
        default { return 'conservative' }
    }
}

function Get-RaymanRequiredAssetAnalysis {
    param(
        [string]$WorkspaceRoot = '',
        [string[]]$RequiredRelPaths = @(),
        [string]$Label = 'required-assets'
    )

    $root = ''
    try {
        if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
            $root = Resolve-RaymanWorkspaceRoot
        } else {
            $root = Resolve-RaymanWorkspaceRoot -StartPath $WorkspaceRoot
        }
    } catch {
        $root = [string]$WorkspaceRoot
    }

    $assets = New-Object System.Collections.Generic.List[object]
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($rel in @($RequiredRelPaths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        $relText = ([string]$rel).Replace('\', '/')
        if ($relText.StartsWith('./')) {
            $relText = $relText.Substring(2)
        }
        $joinedRel = $relText.Replace('/', '\')
        $abs = if ([string]::IsNullOrWhiteSpace($root)) { $joinedRel } else { Join-Path $root $joinedRel }
        $exists = $false
        try {
            $exists = (Test-Path -LiteralPath $abs -PathType Leaf)
        } catch {
            $exists = $false
        }
        if (-not $exists) {
            $missing.Add($relText) | Out-Null
        }
        $assets.Add([pscustomobject]@{
            relative_path = $relText
            absolute_path = $abs
            exists = $exists
        }) | Out-Null
    }

    return [pscustomobject]@{
        label = $Label
        workspace_root = $root
        checked_at = (Get-Date).ToString('o')
        ok = ($missing.Count -eq 0)
        required_count = @($assets.ToArray()).Count
        missing_count = $missing.Count
        missing_relative_paths = @($missing.ToArray())
        assets = @($assets.ToArray())
        repair_action = '.\.Rayman\scripts\repair\ensure_complete_rayman.ps1'
    }
}

function Format-RaymanRequiredAssetSummary {
    param(
        [object]$Analysis
    )

    if ($null -eq $Analysis) {
        return '[required-assets] analysis unavailable'
    }

    $label = [string]$Analysis.label
    if ([string]::IsNullOrWhiteSpace($label)) { $label = 'required-assets' }
    $workspaceRoot = [string]$Analysis.workspace_root
    $repairAction = [string]$Analysis.repair_action
    $missing = @()
    if ($null -ne $Analysis.PSObject.Properties['missing_relative_paths']) {
        $missing = @($Analysis.missing_relative_paths | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($missing.Count -eq 0) {
        return ("[{0}] OK (workspace={1})" -f $label, $workspaceRoot)
    }

    return ("[{0}] missing={1} workspace={2} repair={3}" -f $label, ($missing -join ', '), $workspaceRoot, $repairAction)
}

function Write-RaymanRequiredAssetDiagnostics {
    param(
        [object]$Analysis,
        [string]$Scope = 'required-assets',
        [string]$LogPath = ''
    )

    if ($null -eq $Analysis) { return }

    $summary = Format-RaymanRequiredAssetSummary -Analysis $Analysis
    $root = ''
    if ($null -ne $Analysis.PSObject.Properties['workspace_root']) {
        $root = [string]$Analysis.workspace_root
    }

    try {
        Write-RaymanDiag -Scope $Scope -Message $summary -WorkspaceRoot $root
    } catch {}

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        try {
            $dir = Split-Path -Parent $LogPath
            if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
            }
            Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $summary)
        } catch {}
    }
}

function Get-RaymanRulesTelemetryPath {
    param(
        [string]$WorkspaceRoot = ''
    )

    $root = if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        Resolve-RaymanWorkspaceRoot
    } else {
        Resolve-RaymanWorkspaceRoot -StartPath $WorkspaceRoot
    }
    $telemetryDir = Join-Path $root '.Rayman\runtime\telemetry'
    if (-not (Test-Path -LiteralPath $telemetryDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $telemetryDir | Out-Null
    }
    return (Join-Path $telemetryDir 'rules_runs.tsv')
}

function Ensure-RaymanRulesTelemetryFile {
    param(
        [string]$WorkspaceRoot = ''
    )

    $path = Get-RaymanRulesTelemetryPath -WorkspaceRoot $WorkspaceRoot
    $header = "ts_iso`trun_id`tprofile`tstage`tscope`tstatus`texit_code`tduration_ms`tcommand"

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Set-Content -LiteralPath $path -Encoding UTF8 -Value $header
        return $path
    }

    try {
        $existing = @(Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop)
        if ($existing.Count -eq 0) {
            Set-Content -LiteralPath $path -Encoding UTF8 -Value $header
        } elseif ([string]$existing[0] -ne $header) {
            Set-Content -LiteralPath $path -Encoding UTF8 -Value $header
            if ($existing.Count -gt 1) {
                Add-Content -LiteralPath $path -Encoding UTF8 -Value @($existing | Select-Object -Skip 1)
            }
        }
    } catch {
        Set-Content -LiteralPath $path -Encoding UTF8 -Value $header
    }

    return $path
}

function ConvertTo-RaymanTelemetryField {
    param(
        [AllowNull()][object]$Value
    )

    if ($null -eq $Value) { return '' }
    return ([string]$Value -replace "[`r`n`t]+", ' ').Trim()
}

function Write-RaymanRulesTelemetryRecord {
    param(
        [string]$WorkspaceRoot = '',
        [string]$RunId = '',
        [string]$Profile = '',
        [string]$Stage = '',
        [string]$Scope = '',
        [string]$Status = '',
        [int]$ExitCode = 0,
        [double]$DurationMs = 0,
        [string]$Command = ''
    )

    $path = Ensure-RaymanRulesTelemetryFile -WorkspaceRoot $WorkspaceRoot
    $normalizedStatus = ConvertTo-RaymanTelemetryField -Value $Status
    if ([string]::IsNullOrWhiteSpace($normalizedStatus)) {
        $normalizedStatus = if ($ExitCode -eq 0) { 'OK' } else { 'FAIL' }
    }

    $safeRunId = ConvertTo-RaymanTelemetryField -Value $(if ([string]::IsNullOrWhiteSpace($RunId)) { [Guid]::NewGuid().ToString('n') } else { $RunId })
    $line = "{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}`t{8}" -f `
        (Get-Date).ToString('o'), `
        $safeRunId, `
        (ConvertTo-RaymanTelemetryField -Value $Profile), `
        (ConvertTo-RaymanTelemetryField -Value $Stage), `
        (ConvertTo-RaymanTelemetryField -Value $Scope), `
        $normalizedStatus, `
        [int]$ExitCode, `
        [int][Math]::Max(0, [Math]::Round($DurationMs)), `
        (ConvertTo-RaymanTelemetryField -Value $Command)
    Add-Content -LiteralPath $path -Encoding UTF8 -Value $line
    return $path
}

function Get-RaymanAttentionWorkspaceRoot {
    param(
        [string]$WorkspaceRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        try {
            return (Resolve-RaymanWorkspaceRoot)
        } catch {
            return ''
        }
    }

    try {
        $resolved = (Resolve-Path -LiteralPath $WorkspaceRoot -ErrorAction Stop).Path
        if (Test-Path -LiteralPath $resolved -PathType Container) {
            return $resolved
        }
    } catch {}

    try {
        return (Resolve-RaymanWorkspaceRoot -StartPath $WorkspaceRoot)
    } catch {
        return $WorkspaceRoot
    }
}

function Get-RaymanAttentionAlertEnabled {
    param(
        [string]$WorkspaceRoot = '',
        [string]$Kind = 'manual'
    )

    $root = Get-RaymanAttentionWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    if (-not (Get-RaymanWorkspaceEnvBool -WorkspaceRoot $root -Name 'RAYMAN_ALERTS_ENABLED' -Default $true)) {
        return $false
    }

    $kindValue = if ([string]::IsNullOrWhiteSpace([string]$Kind)) { 'manual' } else { [string]$Kind }
    switch ($kindValue.Trim().ToLowerInvariant()) {
        'manual' {
            return (Get-RaymanWorkspaceEnvBool -WorkspaceRoot $root -Name 'RAYMAN_ALERT_MANUAL_ENABLED' -Default $true)
        }
        'done' {
            return (Get-RaymanWorkspaceEnvBool -WorkspaceRoot $root -Name 'RAYMAN_ALERT_DONE_ENABLED' -Default $true)
        }
        default {
            return $true
        }
    }
}

function Get-RaymanAttentionSurface {
    param(
        [string]$WorkspaceRoot = '',
        [string]$Default = 'log'
    )

    $root = Get-RaymanAttentionWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $fallback = if ([string]::IsNullOrWhiteSpace([string]$Default)) { 'log' } else { [string]$Default }
    $raw = [string](Get-RaymanWorkspaceEnvString -WorkspaceRoot $root -Name 'RAYMAN_ALERT_SURFACE' -Default $fallback)
    if ([string]::IsNullOrWhiteSpace([string]$raw)) {
        $raw = $fallback
    }

    switch ($raw.Trim().ToLowerInvariant()) {
        'toast' { return 'toast' }
        'silent' { return 'silent' }
        default { return 'log' }
    }
}

function Get-RaymanAttentionStatePath {
    param(
        [string]$WorkspaceRoot = ''
    )

    $root = Get-RaymanAttentionWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace([string]$root)) {
        return ''
    }

    $runtimeDir = Join-Path $root '.Rayman\runtime'
    if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
    }

    return (Join-Path $runtimeDir 'attention.last.json')
}

function Write-RaymanAttentionState {
    param(
        [string]$WorkspaceRoot = '',
        [string]$Kind = 'manual',
        [string]$Title = '',
        [string]$Message = '',
        [string]$Surface = 'log',
        [bool]$AlertEnabled = $true,
        [bool]$SpeechEnabled = $false,
        [bool]$Suppressed = $false
    )

    $statePath = Get-RaymanAttentionStatePath -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace([string]$statePath)) {
        return
    }

    $payload = [ordered]@{
        schema = 'rayman.attention.last.v1'
        kind = $Kind
        title = $Title
        message = $Message
        surface = $Surface
        alert_enabled = $AlertEnabled
        speech_enabled = $SpeechEnabled
        suppressed = $Suppressed
        updated_at = (Get-Date).ToString('o')
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($statePath, ($payload | ConvertTo-Json -Depth 6), $utf8NoBom)
}

function Write-RaymanAttentionConsoleMessage {
    param(
        [string]$Kind = 'manual',
        [string]$Title = '',
        [string]$Message = ''
    )

    $resolvedTitle = if ([string]::IsNullOrWhiteSpace([string]$Title)) { 'Rayman 提醒' } else { [string]$Title }
    $resolvedMessage = if ([string]::IsNullOrWhiteSpace([string]$Message)) { 'Rayman 需要您关注当前任务。' } else { [string]$Message }
    $line = ("[{0}] {1}" -f $resolvedTitle, $resolvedMessage)

    switch (([string]$Kind).Trim().ToLowerInvariant()) {
        'error' { Write-Host $line -ForegroundColor Red }
        'done' { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line -ForegroundColor Yellow }
    }
}

function Get-RaymanAttentionSpeechEnabled {
    param(
        [string]$WorkspaceRoot = '',
        [string]$Kind = 'manual'
    )

    $root = Get-RaymanAttentionWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    if (-not (Get-RaymanAttentionAlertEnabled -WorkspaceRoot $root -Kind $Kind)) {
        return $false
    }

    $legacySpeechRaw = [Environment]::GetEnvironmentVariable('RAYMAN_REQUEST_ATTENTION_SPEECH_ENABLED')
    if (-not [string]::IsNullOrWhiteSpace([string]$legacySpeechRaw)) {
        return (Convert-RaymanStringToBool -Value $legacySpeechRaw -Default $true)
    }

    if (-not (Get-RaymanWorkspaceEnvBool -WorkspaceRoot $root -Name 'RAYMAN_ALERT_TTS_ENABLED' -Default $false)) {
        return $false
    }

    $kindValue = if ([string]::IsNullOrWhiteSpace([string]$Kind)) { 'manual' } else { [string]$Kind }
    switch ($kindValue.Trim().ToLowerInvariant()) {
        'done' {
            return (Get-RaymanWorkspaceEnvBool -WorkspaceRoot $root -Name 'RAYMAN_ALERT_TTS_DONE_ENABLED' -Default $false)
        }
        default {
            return $true
        }
    }
}

function Get-RaymanAttentionSoundPath {
    param(
        [string]$WorkspaceRoot = ''
    )

    $root = Get-RaymanAttentionWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $envEntry = Get-RaymanWorkspaceEnvStringEntry -WorkspaceRoot $root -Name 'RAYMAN_ALERT_SOUND_PATH'
    if (-not [bool]$envEntry.configured) {
        return (Resolve-RaymanAttentionDefaultSoundPath -WorkspaceRoot $root)
    }

    $trimmed = [string]$envEntry.value
    if ([string]::IsNullOrWhiteSpace([string]$trimmed)) {
        return ''
    }
    $trimmed = $trimmed.Trim()
    if ([string]::IsNullOrWhiteSpace([string]$trimmed)) {
        return ''
    }
    if ([System.IO.Path]::IsPathRooted($trimmed) -or [string]::IsNullOrWhiteSpace([string]$root)) {
        return $trimmed
    }

    return (Join-Path $root $trimmed)
}

function Get-RaymanAttentionUserHomePath {
    $userHome = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace([string]$userHome)) {
        $userHome = [Environment]::GetEnvironmentVariable('USERPROFILE')
    }
    if ([string]::IsNullOrWhiteSpace([string]$userHome)) {
        $userHome = [Environment]::GetEnvironmentVariable('HOME')
    }
    if ([string]::IsNullOrWhiteSpace([string]$userHome)) {
        try {
            $userHome = [System.IO.Path]::GetFullPath('~')
        } catch {
            $userHome = ''
        }
    }
    return [string]$userHome
}

function Get-RaymanAttentionStateRoot {
    $override = [Environment]::GetEnvironmentVariable('RAYMAN_HOME')
    if (-not [string]::IsNullOrWhiteSpace([string]$override)) {
        if ([System.IO.Path]::IsPathRooted([string]$override)) {
            return [System.IO.Path]::GetFullPath([string]$override)
        }

        $userHome = Get-RaymanAttentionUserHomePath
        if (-not [string]::IsNullOrWhiteSpace([string]$userHome)) {
            return [System.IO.Path]::GetFullPath((Join-Path $userHome ([string]$override)))
        }
        return [System.IO.Path]::GetFullPath([string]$override)
    }

    $resolvedUserHome = Get-RaymanAttentionUserHomePath
    if ([string]::IsNullOrWhiteSpace([string]$resolvedUserHome)) {
        return ''
    }

    return (Join-Path $resolvedUserHome '.rayman')
}

function Get-RaymanManagedAttentionSoundPath {
    $stateRoot = Get-RaymanAttentionStateRoot
    if ([string]::IsNullOrWhiteSpace([string]$stateRoot)) {
        return ''
    }
    return (Join-Path $stateRoot 'codex\notify.wav')
}

function Get-RaymanLegacyAttentionSoundPath {
    $userHome = Get-RaymanAttentionUserHomePath
    if ([string]::IsNullOrWhiteSpace([string]$userHome)) {
        return ''
    }
    return (Join-Path $userHome '.codex\notify.wav')
}

function Get-RaymanAttentionBackupSoundPath {
    param(
        [string]$WorkspaceRoot = ''
    )

    $root = Get-RaymanAttentionWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace([string]$root)) {
        return ''
    }

    $backupRoot = Join-Path $root '.Rayman\runtime\backups\codex-notify'
    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) {
        return ''
    }

    try {
        $latest = Get-ChildItem -LiteralPath $backupRoot -Recurse -Filter 'global-notify.wav' -File -ErrorAction Stop |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1
        if ($null -ne $latest) {
            return [string]$latest.FullName
        }
    } catch {}

    return ''
}

function Resolve-RaymanAttentionDefaultSoundPath {
    param(
        [string]$WorkspaceRoot = ''
    )

    $managedPath = Get-RaymanManagedAttentionSoundPath
    if ([string]::IsNullOrWhiteSpace([string]$managedPath)) {
        return ''
    }

    if (Test-Path -LiteralPath $managedPath -PathType Leaf) {
        return $managedPath
    }

    $sourcePath = Get-RaymanLegacyAttentionSoundPath
    if ([string]::IsNullOrWhiteSpace([string]$sourcePath) -or -not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        $sourcePath = Get-RaymanAttentionBackupSoundPath -WorkspaceRoot $WorkspaceRoot
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$sourcePath) -and (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        try {
            $parent = Split-Path -Parent $managedPath
            if (-not [string]::IsNullOrWhiteSpace([string]$parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Force -Path $parent | Out-Null
            }
            Copy-Item -LiteralPath $sourcePath -Destination $managedPath -Force
            if (Test-Path -LiteralPath $managedPath -PathType Leaf) {
                return $managedPath
            }
        } catch {
            return [string]$sourcePath
        }
    }

    return $managedPath
}

function Get-RaymanAttentionSoundEnabled {
    param(
        [string]$WorkspaceRoot = '',
        [string]$Kind = 'manual'
    )

    $root = Get-RaymanAttentionWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    if (-not (Get-RaymanAttentionAlertEnabled -WorkspaceRoot $root -Kind $Kind)) {
        return $false
    }
    if (-not (Get-RaymanWorkspaceEnvBool -WorkspaceRoot $root -Name 'RAYMAN_ALERT_SOUND_ENABLED' -Default $true)) {
        return $false
    }

    $kindValue = if ([string]::IsNullOrWhiteSpace([string]$Kind)) { 'manual' } else { [string]$Kind }
    switch ($kindValue.Trim().ToLowerInvariant()) {
        'done' {
            return (Get-RaymanWorkspaceEnvBool -WorkspaceRoot $root -Name 'RAYMAN_ALERT_SOUND_DONE_ENABLED' -Default $true)
        }
        default {
            return $true
        }
    }
}

function Invoke-RaymanAttentionSoundFile {
    param(
        [string]$Path
    )

    if (-not (Test-RaymanWindowsPlatform)) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace([string]$Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        $player = New-Object System.Media.SoundPlayer $Path
        $player.Load()
        $player.PlaySync()
        try { $player.Dispose() } catch {}
        return $true
    } catch {
        return $false
    }
}

function Get-RaymanWorkspaceKind {
    param(
        [string]$WorkspaceRoot
    )

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot) -or -not (Test-Path -LiteralPath $WorkspaceRoot -PathType Container)) {
        return 'external'
    }

    $testingMarker = Join-Path $WorkspaceRoot '.Rayman\scripts\testing\run_fast_contract.sh'
    $sourceWorkflowMarkers = @(
        (Join-Path $WorkspaceRoot '.github\workflows\rayman-test-lanes.yml'),
        (Join-Path $WorkspaceRoot '.github\workflows\rayman-nightly-smoke.yml')
    )

    $solutionRequirementMarkers = @()
    try {
        $solutionRequirementMarkers = @(
            Get-ChildItem -LiteralPath $WorkspaceRoot -Force -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name.StartsWith('.') } |
                ForEach-Object { Join-Path $_.FullName ($_.Name + '.requirements.md') }
        )
    } catch {
        $solutionRequirementMarkers = @()
    }

    $hasTestingMarker = Test-Path -LiteralPath $testingMarker -PathType Leaf
    $hasSourceWorkflowMarker = $false
    foreach ($marker in $sourceWorkflowMarkers) {
        if (Test-Path -LiteralPath $marker -PathType Leaf) {
            $hasSourceWorkflowMarker = $true
            break
        }
    }

    $hasSolutionRequirementMarker = $false
    foreach ($marker in $solutionRequirementMarkers) {
        if (Test-Path -LiteralPath $marker -PathType Leaf) {
            $hasSolutionRequirementMarker = $true
            break
        }
    }

    if ($hasSourceWorkflowMarker -and ($hasTestingMarker -or $hasSolutionRequirementMarker)) {
        return 'source'
    }

    return 'external'
}

function Invoke-RaymanUtf8NoBomDirectWrite {
    param(
        [string]$Path,
        [AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Test-RaymanMappedSectionWriteError {
    param(
        [object]$ErrorRecord
    )

    if ($null -eq $ErrorRecord) {
        return $false
    }

    $messages = New-Object 'System.Collections.Generic.List[string]'
    $exceptionCandidates = New-Object 'System.Collections.Generic.List[object]'
    foreach ($seed in @(
            $ErrorRecord,
            $ErrorRecord.Exception,
            $(if ($null -ne $ErrorRecord.Exception) { $ErrorRecord.Exception.InnerException } else { $null })
        )) {
        $current = $seed
        for ($depth = 0; $depth -lt 8 -and $null -ne $current; $depth++) {
            [void]$exceptionCandidates.Add($current)
            if ($current -is [System.Management.Automation.ErrorRecord]) {
                $current = $current.Exception
                continue
            }
            if ($current -is [System.Exception]) {
                $current = $current.InnerException
                continue
            }
            break
        }
    }

    foreach ($candidate in @($exceptionCandidates.ToArray())) {
        if ($null -eq $candidate) { continue }

        $message = ''
        try {
            if ($candidate -is [System.Management.Automation.ErrorRecord]) {
                $message = [string]$candidate.Exception.Message
            } elseif ($candidate -is [System.Exception]) {
                $message = [string]$candidate.Message
                $nativeCode = ([int]$candidate.HResult -band 0xFFFF)
                if ($nativeCode -eq 32 -or $nativeCode -eq 33) {
                    return $true
                }
            } elseif ($candidate.PSObject.Properties['Message']) {
                $message = [string]$candidate.Message
            }
        } catch {
            $message = ''
        }

        if (-not [string]::IsNullOrWhiteSpace($message)) {
            [void]$messages.Add($message.Trim().ToLowerInvariant())
        }
    }

    foreach ($message in @($messages.ToArray())) {
        if ($message.Contains('user-mapped section open')) { return $true }
        if ($message.Contains('mapped section')) { return $true }
        if ($message.Contains('being used by another process')) { return $true }
        if ($message.Contains('process cannot access the file')) { return $true }
        if ($message.Contains('sharing violation')) { return $true }
        if ($message.Contains('lock violation')) { return $true }
    }

    return $false
}

function Invoke-RaymanUtf8NoBomInPlaceWrite {
    param(
        [string]$Path,
        [AllowEmptyString()][string]$Content
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'path is required for in-place write.'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ("path does not exist for in-place write: {0}" -f $Path)
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes([string]$Content)
    $fileInfo = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ([int64]$fileInfo.Length -ne [int64]$bytes.Length) {
        throw ("in-place write requires identical byte length (current={0}, target={1})" -f [int64]$fileInfo.Length, [int64]$bytes.Length)
    }

    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $stream.Position = 0
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Get-RaymanManagedWriteAuditPath {
    param(
        [string]$AuditRoot
    )

    if ([string]::IsNullOrWhiteSpace($AuditRoot)) {
        return ''
    }

    return (Join-Path $AuditRoot '.Rayman\runtime\managed_write.last.json')
}

function Write-RaymanManagedWriteAudit {
    param(
        [string]$AuditRoot,
        [object]$Record
    )

    if ([string]::IsNullOrWhiteSpace($AuditRoot) -or $null -eq $Record) {
        return
    }

    $auditPath = Get-RaymanManagedWriteAuditPath -AuditRoot $AuditRoot
    if ([string]::IsNullOrWhiteSpace($auditPath)) {
        return
    }

    try {
        $parent = Split-Path -Parent $auditPath
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }

        $recentWrites = New-Object 'System.Collections.Generic.List[object]'
        if (Test-Path -LiteralPath $auditPath -PathType Leaf) {
            try {
                $existingAudit = Get-Content -LiteralPath $auditPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                if ($null -ne $existingAudit) {
                    if ($existingAudit.PSObject.Properties['recent_writes']) {
                        foreach ($entry in @($existingAudit.recent_writes)) {
                            if ($null -ne $entry) {
                                [void]$recentWrites.Add($entry)
                            }
                        }
                    } elseif ($existingAudit.PSObject.Properties['last_write'] -and $null -ne $existingAudit.last_write) {
                        [void]$recentWrites.Add($existingAudit.last_write)
                    }
                }
            } catch {}
        }

        [void]$recentWrites.Add($Record)
        while ($recentWrites.Count -gt 25) {
            $recentWrites.RemoveAt(0)
        }

        $payload = [ordered]@{
            schema = 'rayman.managed_write.audit.v1'
            updated_at = (Get-Date).ToString('o')
            last_write = $Record
            recent_writes = @($recentWrites.ToArray())
        }

        Invoke-RaymanUtf8NoBomDirectWrite -Path $auditPath -Content ($payload | ConvertTo-Json -Depth 8)
    } catch {}
}

function Set-RaymanManagedUtf8File {
    param(
        [string]$Path,
        [AllowEmptyString()][string]$Content,
        [string]$AuditRoot = '',
        [string]$Label = '',
        [int[]]$RetryDelaysMs = @(500, 1500, 3500),
        [scriptblock]$DirectWriteAction = $null,
        [scriptblock]$InPlaceWriteAction = $null
    )

    $result = [ordered]@{
        ok = $false
        changed = $false
        mode = 'failed'
        reason = 'unknown'
        retry_count = 0
        path = [string]$Path
        previous_bytes = 0
        target_bytes = 0
        error_message = ''
        label = [string]$Label
        updated_at = (Get-Date).ToString('o')
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $targetContent = if ($null -eq $Content) { '' } else { [string]$Content }
    $result.target_bytes = [int]$encoding.GetByteCount($targetContent)
    if ($null -eq $DirectWriteAction) {
        $DirectWriteAction = {
            param($TargetPath, $TargetContent)
            Invoke-RaymanUtf8NoBomDirectWrite -Path $TargetPath -Content $TargetContent
        }
    }
    if ($null -eq $InPlaceWriteAction) {
        $InPlaceWriteAction = {
            param($TargetPath, $TargetContent)
            Invoke-RaymanUtf8NoBomInPlaceWrite -Path $TargetPath -Content $TargetContent
        }
    }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $result.reason = 'path_required'
        $auditRecord = [pscustomobject]$result
        Write-RaymanManagedWriteAudit -AuditRoot $AuditRoot -Record $auditRecord
        return $auditRecord
    }

    $existingContent = ''
    $existingRead = $false
    $readMappedSectionBlocked = $false
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $existingContent = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
            if ($null -eq $existingContent) { $existingContent = '' }
            $existingRead = $true
            $result.previous_bytes = [int]$encoding.GetByteCount([string]$existingContent)
        } catch {
            if (Test-RaymanMappedSectionWriteError -ErrorRecord $_) {
                $readMappedSectionBlocked = $true
                $existingRead = $false
                $existingContent = ''
                $result.previous_bytes = 0
            } else {
                $result.reason = 'read_failed'
                $result.error_message = $_.Exception.Message
                $auditRecord = [pscustomobject]$result
                Write-RaymanManagedWriteAudit -AuditRoot $AuditRoot -Record $auditRecord
                return $auditRecord
            }
        }
    }

    if ($existingRead -and ([string]$existingContent -ceq [string]$targetContent)) {
        $result.ok = $true
        $result.mode = 'unchanged'
        $result.reason = 'unchanged'
        $auditRecord = [pscustomobject]$result
        Write-RaymanManagedWriteAudit -AuditRoot $AuditRoot -Record $auditRecord
        return $auditRecord
    }

    $lastError = $null
    try {
        & $DirectWriteAction $Path $targetContent
        $result.ok = $true
        $result.changed = $true
        $result.mode = 'direct'
        $result.reason = 'ok'
        $auditRecord = [pscustomobject]$result
        Write-RaymanManagedWriteAudit -AuditRoot $AuditRoot -Record $auditRecord
        return $auditRecord
    } catch {
        $lastError = $_
    }

    if (-not (Test-RaymanMappedSectionWriteError -ErrorRecord $lastError)) {
        $result.reason = 'direct_write_failed'
        $result.error_message = $lastError.Exception.Message
        $auditRecord = [pscustomobject]$result
        Write-RaymanManagedWriteAudit -AuditRoot $AuditRoot -Record $auditRecord
        return $auditRecord
    }

    foreach ($delayMs in @($RetryDelaysMs)) {
        if ([int]$delayMs -gt 0) {
            Start-Sleep -Milliseconds ([int]$delayMs)
        }
        $result.retry_count++

        try {
            & $DirectWriteAction $Path $targetContent
            $result.ok = $true
            $result.changed = $true
            $result.mode = 'retry_success'
            $result.reason = 'ok'
            $result.error_message = ''
            $auditRecord = [pscustomobject]$result
            Write-RaymanManagedWriteAudit -AuditRoot $AuditRoot -Record $auditRecord
            return $auditRecord
        } catch {
            $lastError = $_
            if (-not (Test-RaymanMappedSectionWriteError -ErrorRecord $lastError)) {
                $result.reason = 'retry_failed'
                $result.error_message = $lastError.Exception.Message
                $auditRecord = [pscustomobject]$result
                Write-RaymanManagedWriteAudit -AuditRoot $AuditRoot -Record $auditRecord
                return $auditRecord
            }
        }
    }

    if ((Get-Command Test-RaymanWindowsPlatform -ErrorAction SilentlyContinue) -and (Test-RaymanWindowsPlatform) -and $existingRead -and ($result.previous_bytes -eq $result.target_bytes)) {
        try {
            & $InPlaceWriteAction $Path $targetContent
            $result.ok = $true
            $result.changed = $true
            $result.mode = 'in_place_fallback'
            $result.reason = 'mapped_section_same_length'
            $result.error_message = ''
            $auditRecord = [pscustomobject]$result
            Write-RaymanManagedWriteAudit -AuditRoot $AuditRoot -Record $auditRecord
            return $auditRecord
        } catch {
            $result.reason = 'in_place_fallback_failed'
            $result.error_message = $_.Exception.Message
            $auditRecord = [pscustomobject]$result
            Write-RaymanManagedWriteAudit -AuditRoot $AuditRoot -Record $auditRecord
            return $auditRecord
        }
    }

    if ((Get-Command Test-RaymanWindowsPlatform -ErrorAction SilentlyContinue) -and (Test-RaymanWindowsPlatform) -and $existingRead -and ($result.previous_bytes -ne $result.target_bytes)) {
        $result.reason = 'mapped_section_length_mismatch'
    } elseif ($readMappedSectionBlocked) {
        $result.reason = 'mapped_section_existing_content_unavailable'
    } elseif (-not $existingRead) {
        $result.reason = 'mapped_section_existing_content_unavailable'
    } else {
        $result.reason = 'mapped_section_retry_exhausted'
    }
    if ($null -ne $lastError -and $lastError.Exception) {
        $result.error_message = $lastError.Exception.Message
    }

    $auditRecord = [pscustomobject]$result
    Write-RaymanManagedWriteAudit -AuditRoot $AuditRoot -Record $auditRecord
    return $auditRecord
}

function Get-RaymanEnvInt {
    param(
        [string]$Name,
        [int]$Default,
        [int]$Min = [int]::MinValue,
        [int]$Max = [int]::MaxValue
    )

    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $Default
    }

    $parsed = 0
    if (-not [int]::TryParse($raw.Trim(), [ref]$parsed)) {
        return $Default
    }

    if ($parsed -lt $Min) { return $Min }
    if ($parsed -gt $Max) { return $Max }
    return $parsed
}

function Get-RaymanStringListEnv {
    param(
        [string]$Name,
        [string[]]$Default = @()
    )

    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @($Default)
    }

    $items = @($raw -split '[,;|]' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($items.Count -eq 0) {
        return @($Default)
    }

    return $items
}

function Get-RaymanWorkspaceStringListEnv {
    param(
        [string]$WorkspaceRoot,
        [string]$Name,
        [string[]]$Default = @()
    )

    $raw = [string](Get-RaymanWorkspaceEnvString -WorkspaceRoot $WorkspaceRoot -Name $Name -Default '')
    if ([string]::IsNullOrWhiteSpace([string]$raw)) {
        return @($Default)
    }

    $items = @($raw -split '[,;|]' | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($items.Count -eq 0) {
        return @($Default)
    }

    return @($items)
}

function Get-RaymanAttentionWatchProcessNames {
    param([string]$WorkspaceRoot = '')

    $explicit = @(
        Get-RaymanWorkspaceStringListEnv -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_ALERT_WATCH_PROCESS_NAMES' -Default @()
    )
    if ($explicit.Count -gt 0) {
        return @($explicit)
    }

    $names = New-Object 'System.Collections.Generic.List[string]'
    if (Get-RaymanWorkspaceEnvBool -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_ALERT_WATCH_VSCODE_WINDOWS_ENABLED' -Default $true) {
        $names.Add('Code') | Out-Null
        $names.Add('Code - Insiders') | Out-Null
        $names.Add('Codex') | Out-Null
        $names.Add('OpenAI.Codex') | Out-Null
    }
    $names.Add('WindowsSandbox') | Out-Null
    $names.Add('WindowsSandboxClient') | Out-Null
    return @($names.ToArray())
}

function Test-RaymanAttentionWatchTargetsAvailable {
    param(
        [bool]$WatchAll = $false,
        [string[]]$ProcessNames = @()
    )

    if ($WatchAll) {
        return $true
    }

    $names = @($ProcessNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($names.Count -eq 0) {
        return $false
    }

    try {
        $targets = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
        return ($targets.Count -gt 0)
    } catch {
        return $false
    }
}

function Test-RaymanWindowsPlatform {
    try {
        if ($null -ne $PSVersionTable.PSObject.Properties['Platform']) {
            return ([string]$PSVersionTable.Platform -eq 'Win32NT')
        }
    } catch {}

    return ($env:OS -eq 'Windows_NT')
}

function Resolve-RaymanPowerShellHost {
    $candidates = if (Test-RaymanWindowsPlatform) {
        @('pwsh.exe', 'pwsh', 'powershell.exe', 'powershell')
    } else {
        @('pwsh', 'powershell', 'pwsh.exe', 'powershell.exe')
    }
    foreach ($name in $candidates) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            return [string]$cmd.Source
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$PSHOME)) {
        $fallback = Join-Path $PSHOME 'powershell.exe'
        if (Test-Path -LiteralPath $fallback -PathType Leaf) {
            return $fallback
        }
    }

    return $null
}

function Start-RaymanProcessHiddenCompat {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = ''
    )

    $params = @{
        FilePath = $FilePath
        ArgumentList = @($ArgumentList)
        PassThru = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $params['WorkingDirectory'] = $WorkingDirectory
    }

    if (Test-RaymanWindowsPlatform) {
        $params['WindowStyle'] = 'Hidden'
    }

    return (Start-Process @params)
}

function Get-LastExitCodeCompat([int]$Default = 0) {
    try {
        $globalVar = Get-Variable -Name 'LASTEXITCODE' -Scope Global -ErrorAction Stop
        if ($null -ne $globalVar.Value) { return [int]$globalVar.Value }
    } catch {}

    try {
        $scriptVar = Get-Variable -Name 'LASTEXITCODE' -Scope Script -ErrorAction Stop
        if ($null -ne $scriptVar.Value) { return [int]$scriptVar.Value }
    } catch {}

    return $Default
}

function Reset-LastExitCodeCompat {
    try { Set-Variable -Name 'LASTEXITCODE' -Scope Global -Value 0 -Force } catch {}
    try { Set-Variable -Name 'LASTEXITCODE' -Scope Script -Value 0 -Force } catch {}
}

function Invoke-RaymanNativeCommandCapture {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = ''
    )

    $result = [ordered]@{
        success = $false
        started = $false
        exit_code = -1
        output = ''
        stdout = @()
        stderr = @()
        command = ''
        file_path = [string]$FilePath
        error = ''
    }

    if ([string]::IsNullOrWhiteSpace([string]$FilePath)) {
        $result.error = 'file_path_missing'
        return [pscustomobject]$result
    }

    $quotedArgs = @($ArgumentList | ForEach-Object {
        $arg = [string]$_
        if ([string]::IsNullOrWhiteSpace($arg)) { return "''" }
        if ($arg -match '[\s"]') {
            return ('"' + ($arg -replace '"', '\"') + '"')
        }
        return $arg
    })
    $result.command = ((@([string]$FilePath) + $quotedArgs) -join ' ').Trim()

    $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_native_capture_' + [Guid]::NewGuid().ToString('N'))
    $stdoutPath = $tempBase + '.stdout.txt'
    $stderrPath = $tempBase + '.stderr.txt'
    $proc = $null

    try {
        $stdoutText = ''
        $stderrText = ''
        if (Test-RaymanWindowsPlatform) {
            $params = @{
                FilePath = [string]$FilePath
                ArgumentList = @($ArgumentList)
                Wait = $true
                PassThru = $true
                RedirectStandardOutput = $stdoutPath
                RedirectStandardError = $stderrPath
                WindowStyle = 'Hidden'
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$WorkingDirectory)) {
                $params['WorkingDirectory'] = $WorkingDirectory
            }

            $proc = Start-Process @params
            if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
                $stdoutText = [string](Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
            }
            if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
                $stderrText = [string](Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
            }
        } else {
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = [string]$FilePath
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            if (-not [string]::IsNullOrWhiteSpace([string]$WorkingDirectory)) {
                $startInfo.WorkingDirectory = $WorkingDirectory
            }
            foreach ($arg in @($ArgumentList)) {
                [void]$startInfo.ArgumentList.Add([string]$arg)
            }

            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $startInfo
            $null = $proc.Start()
            $stdoutText = [string]$proc.StandardOutput.ReadToEnd()
            $stderrText = [string]$proc.StandardError.ReadToEnd()
            $proc.WaitForExit()
        }

        $result.started = $true
        $result.exit_code = [int]$proc.ExitCode
        if ($null -eq $stdoutText) { $stdoutText = '' }
        if ($null -eq $stderrText) { $stderrText = '' }
        $stdoutText = ([string]$stdoutText).TrimEnd("`r", "`n")
        $stderrText = ([string]$stderrText).TrimEnd("`r", "`n")
        if (-not [string]::IsNullOrWhiteSpace($stdoutText)) {
            $result.stdout = @([string[]]($stdoutText -split "`r?`n"))
        }
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            $result.stderr = @([string[]]($stderrText -split "`r?`n"))
        }
        $joinedOutput = @($result.stdout + $result.stderr) -join [Environment]::NewLine
        $result.output = [string]$joinedOutput
        $result.success = ($result.exit_code -eq 0)
    } catch {
        $result.error = $_.Exception.Message
        if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
            $result.stdout = @([string[]](Get-Content -LiteralPath $stdoutPath -Encoding UTF8 -ErrorAction SilentlyContinue))
        }
        if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            $result.stderr = @([string[]](Get-Content -LiteralPath $stderrPath -Encoding UTF8 -ErrorAction SilentlyContinue))
        }
        $joinedOutput = @($result.stdout + $result.stderr) -join [Environment]::NewLine
        $result.output = [string]$joinedOutput
    } finally {
        try {
            if ($null -ne $proc) {
                $proc.Dispose()
            }
        } catch {}
        try { Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue } catch {}
        try { Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue } catch {}
    }

    return [pscustomobject]$result
}

function Get-RaymanPathEntries {
    $rawPath = [string][Environment]::GetEnvironmentVariable('PATH')
    if ([string]::IsNullOrWhiteSpace([string]$rawPath)) {
        return @()
    }

    $separator = [string][System.IO.Path]::PathSeparator
    $entries = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in @($rawPath -split [regex]::Escape($separator))) {
        $candidate = [string]$entry
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
            continue
        }

        $candidate = $candidate.Trim().Trim('"')
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
            continue
        }

        try {
            $candidate = [System.IO.Path]::GetFullPath($candidate)
        } catch {}

        if ($entries -notcontains $candidate) {
            $entries.Add($candidate) | Out-Null
        }
    }

    return @($entries.ToArray())
}

function Get-RaymanCommandSourcesInPathOrder {
    param(
        [string[]]$LeafNames = @(),
        [string[]]$CommandNames = @()
    )

    $results = New-Object 'System.Collections.Generic.List[string]'
    foreach ($dir in @(Get-RaymanPathEntries)) {
        if ([string]::IsNullOrWhiteSpace([string]$dir)) {
            continue
        }

        foreach ($leafName in @($LeafNames)) {
            if ([string]::IsNullOrWhiteSpace([string]$leafName)) {
                continue
            }

            $candidate = Join-Path $dir $leafName
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                continue
            }

            try {
                $candidate = (Resolve-Path -LiteralPath $candidate).Path
            } catch {}

            if ($results -notcontains $candidate) {
                $results.Add($candidate) | Out-Null
            }
        }
    }

    foreach ($commandName in @($CommandNames)) {
        if ([string]::IsNullOrWhiteSpace([string]$commandName)) {
            continue
        }

        foreach ($command in @(Get-Command $commandName -All -ErrorAction SilentlyContinue)) {
            $source = [string]$command.Source
            if ([string]::IsNullOrWhiteSpace([string]$source)) {
                continue
            }

            if ($results -notcontains $source) {
                $results.Add($source) | Out-Null
            }
        }
    }

    return @($results.ToArray())
}

function Test-RaymanLegacyWindowsBashPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace([string]$Path)) {
        return $false
    }

    $normalized = ([string]$Path -replace '/', '\').ToLowerInvariant()
    return (
        $normalized.EndsWith('\windows\system32\bash.exe') -or
        $normalized.EndsWith('\windowsapps\bash.exe')
    )
}

function Test-RaymanWslInteropAvailable {
    param([string]$WslPath = '')

    if (-not (Test-RaymanWindowsPlatform)) {
        return $false
    }

    $overrideRaw = [string][Environment]::GetEnvironmentVariable('RAYMAN_TEST_WSL_INTEROP_AVAILABLE')
    if (-not [string]::IsNullOrWhiteSpace([string]$overrideRaw)) {
        switch -Regex ($overrideRaw.Trim().ToLowerInvariant()) {
            '^(1|true|yes|on)$' { return $true }
            '^(0|false|no|off)$' { return $false }
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$WslPath)) {
        $wslCandidates = @(Get-RaymanCommandSourcesInPathOrder -LeafNames @('wsl.exe', 'wsl') -CommandNames @('wsl.exe', 'wsl'))
        if ($wslCandidates.Count -gt 0) {
            $WslPath = [string]$wslCandidates[0]
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$WslPath)) {
        return $false
    }

    if ($null -eq $script:RaymanWslInteropAvailabilityCache) {
        $script:RaymanWslInteropAvailabilityCache = @{}
    }

    $cacheKey = ([string]$WslPath).ToLowerInvariant()
    if ($script:RaymanWslInteropAvailabilityCache.ContainsKey($cacheKey)) {
        return [bool]$script:RaymanWslInteropAvailabilityCache[$cacheKey]
    }

    $probe = Invoke-RaymanNativeCommandCapture -FilePath $WslPath -ArgumentList @('-e', 'sh', '-lc', 'exit 0')
    $available = ([bool]$probe.started -and [int]$probe.exit_code -eq 0)
    $script:RaymanWslInteropAvailabilityCache[$cacheKey] = $available
    return $available
}

function Resolve-RaymanBashCommand {
    $override = [string][Environment]::GetEnvironmentVariable('RAYMAN_BASH_PATH')
    if (-not [string]::IsNullOrWhiteSpace([string]$override) -and (Test-Path -LiteralPath $override -PathType Leaf)) {
        return [pscustomobject]@{
            path = (Resolve-Path -LiteralPath $override).Path
            mode = 'bash'
            invoke_kind = 'bash'
        }
    }

    $bashLeafNames = if (Test-RaymanWindowsPlatform) {
        @('bash.cmd', 'bash.bat', 'bash.ps1', 'bash.exe')
    } else {
        @('bash')
    }
    $bashCommandNames = if (Test-RaymanWindowsPlatform) {
        @('bash.cmd', 'bash.bat', 'bash.ps1', 'bash.exe', 'bash')
    } else {
        @('bash')
    }
    $bashCandidates = @(Get-RaymanCommandSourcesInPathOrder -LeafNames $bashLeafNames -CommandNames $bashCommandNames)

    if (-not (Test-RaymanWindowsPlatform)) {
        if ($bashCandidates.Count -eq 0) {
            return $null
        }

        return [pscustomobject]@{
            path = [string]$bashCandidates[0]
            mode = 'bash'
            invoke_kind = 'bash'
        }
    }

    foreach ($bashCandidate in $bashCandidates) {
        if (Test-RaymanLegacyWindowsBashPath -Path ([string]$bashCandidate)) {
            continue
        }

        return [pscustomobject]@{
            path = [string]$bashCandidate
            mode = 'bash'
            invoke_kind = 'bash'
        }
    }

    $wslCandidates = @(Get-RaymanCommandSourcesInPathOrder -LeafNames @('wsl.exe', 'wsl') -CommandNames @('wsl.exe', 'wsl'))
    $wslPath = if ($wslCandidates.Count -gt 0) { [string]$wslCandidates[0] } else { '' }
    if (Test-RaymanWslInteropAvailable -WslPath $wslPath) {
        if (-not [string]::IsNullOrWhiteSpace([string]$wslPath)) {
            return [pscustomobject]@{
                path = $wslPath
                mode = 'wsl'
                invoke_kind = 'wsl'
            }
        }

        foreach ($bashCandidate in $bashCandidates) {
            if (Test-RaymanLegacyWindowsBashPath -Path ([string]$bashCandidate)) {
                return [pscustomobject]@{
                    path = [string]$bashCandidate
                    mode = 'wsl'
                    invoke_kind = 'bash'
                }
            }
        }
    }

    return $null
}

function Get-RaymanSetupGitBootstrapOptions {
    param(
        [string]$WorkspaceRoot = ''
    )

    $gitInitEnabled = Get-RaymanWorkspaceEnvBool -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_SETUP_GIT_INIT' -Default $true
    $githubLoginEnabled = Get-RaymanWorkspaceEnvBool -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_SETUP_GITHUB_LOGIN' -Default $true
    $githubLoginStrict = Get-RaymanWorkspaceEnvBool -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_SETUP_GITHUB_LOGIN_STRICT' -Default $false
    $githubHost = [string](Get-RaymanWorkspaceEnvString -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_GITHUB_HOST' -Default 'github.com')
    $githubGitProtocol = [string](Get-RaymanWorkspaceEnvString -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_GITHUB_GIT_PROTOCOL' -Default 'https')
    if ([string]::IsNullOrWhiteSpace($githubHost)) { $githubHost = 'github.com' }
    if ([string]::IsNullOrWhiteSpace($githubGitProtocol)) { $githubGitProtocol = 'https' }

    $ciRaw = [Environment]::GetEnvironmentVariable('CI')
    $ciDetected = $false
    if (-not [string]::IsNullOrWhiteSpace([string]$ciRaw)) {
        $ciDetected = Convert-RaymanStringToBool -Value ([string]$ciRaw) -Default $true
    }

    return [pscustomobject]@{
        git_init_enabled = [bool]$gitInitEnabled
        github_login_enabled = [bool]$githubLoginEnabled
        github_login_strict = [bool]$githubLoginStrict
        github_host = [string]$githubHost
        github_git_protocol = [string]$githubGitProtocol
        ci_detected = [bool]$ciDetected
        allow_interactive_github_login = ([bool]$githubLoginEnabled -and (-not [bool]$ciDetected))
    }
}

function Get-RaymanGitHubCliKindFromSource {
    param(
        [string]$Source
    )

    if ([string]::IsNullOrWhiteSpace([string]$Source)) {
        return 'missing'
    }

    $leaf = ''
    try {
        $leaf = [System.IO.Path]::GetFileName([string]$Source)
    } catch {
        $leaf = [string]$Source
    }
    if ($leaf -ieq 'gh.exe') {
        return 'gh.exe'
    }
    if ($leaf -ieq 'gh') {
        return 'gh'
    }
    if ([string]$Source -match 'gh\.exe') {
        return 'gh.exe'
    }
    return 'gh'
}

function Get-RaymanGitHubCliResolution {
    param(
        [string]$GhCommandSource = '',
        [string]$GhExeCommandSource = ''
    )

    foreach ($candidate in @(
        [pscustomobject]@{ Kind = 'gh'; Source = [string]$GhCommandSource; IsOverride = $true },
        [pscustomobject]@{ Kind = 'gh.exe'; Source = [string]$GhExeCommandSource; IsOverride = $true }
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate.Source)) { continue }
        if (Test-Path -LiteralPath ([string]$candidate.Source) -PathType Leaf) {
            return [pscustomobject]@{
                available = $true
                cli_kind = [string]$candidate.Kind
                source = [string]$candidate.Source
                reason = 'override'
            }
        }
    }

    foreach ($name in @('gh', 'gh.exe')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            return [pscustomobject]@{
                available = $true
                cli_kind = [string]$name
                source = [string]$cmd.Source
                reason = 'path'
            }
        }
    }

    return [pscustomobject]@{
        available = $false
        cli_kind = 'missing'
        source = ''
        reason = 'not_found'
    }
}

function Get-RaymanGitHubAuthStatus {
    param(
        [string]$CliSource,
        [string]$GitHubHost = 'github.com'
    )

    $status = [ordered]@{
        status = 'missing'
        exit_code = -1
        output = ''
        command = ''
        success = $false
        error = ''
    }

    if ([string]::IsNullOrWhiteSpace([string]$GitHubHost)) {
        $GitHubHost = 'github.com'
    }

    if ([string]::IsNullOrWhiteSpace([string]$CliSource)) {
        return [pscustomobject]$status
    }

    $capture = Invoke-RaymanNativeCommandCapture -FilePath $CliSource -ArgumentList @('auth', 'status', '--hostname', $GitHubHost)
    $status.exit_code = [int]$capture.exit_code
    $status.output = [string]$capture.output
    $status.command = [string]$capture.command
    $status.success = [bool]$capture.success
    $status.error = [string]$capture.error

    if ([bool]$capture.success) {
        $status.status = 'authenticated'
        return [pscustomobject]$status
    }

    $outputText = [string]$capture.output
    if ($outputText -match 'not logged into' -or
        $outputText -match 'not logged in' -or
        $outputText -match 'gh auth login' -or
        $outputText -match 'authentication required' -or
        $outputText -match 'no oauth token') {
        $status.status = 'unauthenticated'
        return [pscustomobject]$status
    }

    $status.status = 'unknown'
    return [pscustomobject]$status
}

function Initialize-RaymanGitRepository {
    param(
        [string]$WorkspaceRoot,
        [string]$InitialBranch = 'main',
        [string]$GitCommandSource = ''
    )

    $result = [ordered]@{
        git_available = $false
        git_command = ''
        git_repo_detected = $false
        git_initialized = $false
        git_init_detail = ''
        repair_action = ''
        output = ''
    }

    if ([string]::IsNullOrWhiteSpace([string]$WorkspaceRoot) -or -not (Test-Path -LiteralPath $WorkspaceRoot -PathType Container)) {
        $result.git_init_detail = 'workspace_missing'
        $result.repair_action = '确认 WorkspaceRoot 有效后重跑 setup。'
        return [pscustomobject]$result
    }

    $gitMarkerPath = Join-Path $WorkspaceRoot '.git'
    $result.git_repo_detected = (Test-Path -LiteralPath $gitMarkerPath)

    $gitSource = [string]$GitCommandSource
    if ([string]::IsNullOrWhiteSpace($gitSource)) {
        $gitCmd = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $gitCmd -and -not [string]::IsNullOrWhiteSpace([string]$gitCmd.Source)) {
            $gitSource = [string]$gitCmd.Source
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($gitSource)) {
        $result.git_available = $true
        $result.git_command = $gitSource
    }

    if ([bool]$result.git_repo_detected) {
        $result.git_init_detail = 'existing_repo'
        return [pscustomobject]$result
    }

    if (-not [bool]$result.git_available) {
        $result.git_init_detail = 'git_not_found'
        $result.repair_action = '安装 Git 后重跑 setup；Windows 宿主可先运行 ./.Rayman/scripts/utils/ensure_win_deps.ps1。'
        return [pscustomobject]$result
    }

    if ([string]::IsNullOrWhiteSpace([string]$InitialBranch)) {
        $InitialBranch = 'main'
    }

    $branchInit = Invoke-RaymanNativeCommandCapture -FilePath $gitSource -ArgumentList @('init', '-b', $InitialBranch) -WorkingDirectory $WorkspaceRoot
    if ([bool]$branchInit.success -and (Test-Path -LiteralPath $gitMarkerPath)) {
        $result.git_repo_detected = $true
        $result.git_initialized = $true
        $result.git_init_detail = 'git_init_branch_flag'
        $result.output = [string]$branchInit.output
        return [pscustomobject]$result
    }

    $fallbackInit = Invoke-RaymanNativeCommandCapture -FilePath $gitSource -ArgumentList @('init') -WorkingDirectory $WorkspaceRoot
    if (-not [bool]$fallbackInit.success -or -not (Test-Path -LiteralPath $gitMarkerPath)) {
        $result.git_init_detail = 'git_init_failed'
        $result.output = [string]$fallbackInit.output
        if (-not [string]::IsNullOrWhiteSpace([string]$branchInit.output)) {
            $result.output = (@([string]$branchInit.output, [string]$fallbackInit.output) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join [Environment]::NewLine
        }
        $result.repair_action = ('手工执行 `git init -b {0}`（或旧版 Git 用 `git init` 后再执行 `git symbolic-ref HEAD refs/heads/{0}`）。' -f $InitialBranch)
        return [pscustomobject]$result
    }

    $setHead = Invoke-RaymanNativeCommandCapture -FilePath $gitSource -ArgumentList @('symbolic-ref', 'HEAD', ("refs/heads/{0}" -f $InitialBranch)) -WorkingDirectory $WorkspaceRoot
    if ([bool]$setHead.success) {
        $result.git_repo_detected = $true
        $result.git_initialized = $true
        $result.git_init_detail = 'git_init_fallback_symbolic_ref'
        $result.output = (@([string]$fallbackInit.output, [string]$setHead.output) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join [Environment]::NewLine
        return [pscustomobject]$result
    }

    $renameHead = Invoke-RaymanNativeCommandCapture -FilePath $gitSource -ArgumentList @('branch', '-M', $InitialBranch) -WorkingDirectory $WorkspaceRoot
    $result.git_repo_detected = (Test-Path -LiteralPath $gitMarkerPath)
    $result.git_initialized = [bool]$result.git_repo_detected
    if ([bool]$renameHead.success) {
        $result.git_init_detail = 'git_init_fallback_branch_rename'
        $result.output = (@([string]$fallbackInit.output, [string]$setHead.output, [string]$renameHead.output) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join [Environment]::NewLine
        return [pscustomobject]$result
    }

    $result.git_init_detail = 'git_init_fallback_head_warn'
    $result.output = (@([string]$fallbackInit.output, [string]$setHead.output, [string]$renameHead.output) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join [Environment]::NewLine
    $result.repair_action = ('手工执行 `git symbolic-ref HEAD refs/heads/{0}`，必要时再执行 `git branch -M {0}`。' -f $InitialBranch)
    return [pscustomobject]$result
}

function Invoke-RaymanGitBootstrap {
    param(
        [string]$WorkspaceRoot,
        [bool]$GitInitEnabled = $true,
        [bool]$GitHubLoginEnabled = $true,
        [bool]$GitHubLoginStrict = $false,
        [string]$GitHubHost = 'github.com',
        [string]$GitProtocol = 'https',
        [bool]$AllowInteractiveGitHubLogin = $true,
        [scriptblock]$BeforeGitHubLogin = $null,
        [string]$GitCommandSource = '',
        [string]$GitHubCliSource = '',
        [string]$GitHubCliKind = ''
    )

    if ([string]::IsNullOrWhiteSpace([string]$GitHubHost)) { $GitHubHost = 'github.com' }
    if ([string]::IsNullOrWhiteSpace([string]$GitProtocol)) { $GitProtocol = 'https' }

    $report = [ordered]@{
        schema = 'rayman.setup.git_bootstrap.v1'
        generated_at = (Get-Date).ToString('o')
        workspace_root = [string]$WorkspaceRoot
        git_available = $false
        git_command = ''
        git_repo_detected = $false
        git_initialized = $false
        git_init_detail = ''
        github_cli = 'missing'
        github_cli_source = ''
        github_auth_status = 'skipped'
        github_login_attempted = $false
        github_login_success = $false
        github_setup_git_attempted = $false
        github_setup_git_success = $false
        skipped_reason = ''
        repair_action = ''
        should_block_setup = $false
        error_message = ''
    }

    $gitBootstrap = $null
    if ([bool]$GitInitEnabled) {
        $gitBootstrap = Initialize-RaymanGitRepository -WorkspaceRoot $WorkspaceRoot -InitialBranch 'main' -GitCommandSource $GitCommandSource
        $report.git_available = [bool]$gitBootstrap.git_available
        $report.git_command = [string]$gitBootstrap.git_command
        $report.git_repo_detected = [bool]$gitBootstrap.git_repo_detected
        $report.git_initialized = [bool]$gitBootstrap.git_initialized
        $report.git_init_detail = [string]$gitBootstrap.git_init_detail
        if ([string]::IsNullOrWhiteSpace([string]$report.repair_action) -and -not [string]::IsNullOrWhiteSpace([string]$gitBootstrap.repair_action)) {
            $report.repair_action = [string]$gitBootstrap.repair_action
        }
    } else {
        $gitCmd = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$GitCommandSource) -and (Test-Path -LiteralPath $GitCommandSource -PathType Leaf)) {
            $report.git_available = $true
            $report.git_command = [string]$GitCommandSource
        } else {
            $gitCmd = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $gitCmd -and -not [string]::IsNullOrWhiteSpace([string]$gitCmd.Source)) {
                $report.git_available = $true
                $report.git_command = [string]$gitCmd.Source
            }
        }
        $gitMarkerPath = Join-Path $WorkspaceRoot '.git'
        $report.git_repo_detected = (Test-Path -LiteralPath $gitMarkerPath)
        $report.git_init_detail = if ([bool]$report.git_repo_detected) { 'existing_repo' } else { 'disabled' }
        if (-not [bool]$report.git_repo_detected) {
            $report.repair_action = '如需自动准备本地 Git 仓库，请设置 RAYMAN_SETUP_GIT_INIT=1 后重跑 setup；或手工执行 `git init -b main`。'
        }
    }

    if (-not [bool]$GitHubLoginEnabled) {
        $report.github_auth_status = 'skipped'
        $report.skipped_reason = 'github_login_disabled'
        return [pscustomobject]$report
    }

    if (-not [bool]$AllowInteractiveGitHubLogin) {
        $report.github_auth_status = 'skipped'
        $report.skipped_reason = 'github_login_noninteractive'
        return [pscustomobject]$report
    }

    $cliResolution = if (-not [string]::IsNullOrWhiteSpace([string]$GitHubCliSource)) {
        [pscustomobject]@{
            available = (Test-Path -LiteralPath $GitHubCliSource -PathType Leaf)
            cli_kind = if ([string]::IsNullOrWhiteSpace([string]$GitHubCliKind)) { Get-RaymanGitHubCliKindFromSource -Source $GitHubCliSource } else { [string]$GitHubCliKind }
            source = [string]$GitHubCliSource
            reason = 'override'
        }
    } else {
        Get-RaymanGitHubCliResolution
    }
    $report.github_cli = [string]$cliResolution.cli_kind
    $report.github_cli_source = [string]$cliResolution.source

    if (-not [bool]$cliResolution.available -or [string]::IsNullOrWhiteSpace([string]$cliResolution.source)) {
        $report.github_auth_status = 'skipped'
        $report.skipped_reason = 'github_cli_missing'
        if ([string]::IsNullOrWhiteSpace([string]$report.repair_action)) {
            $report.repair_action = ('安装 GitHub CLI 后执行: gh auth login --hostname {0} --git-protocol {1} --web' -f $GitHubHost, $GitProtocol)
        }
        $report.should_block_setup = [bool]$GitHubLoginStrict
        return [pscustomobject]$report
    }

    $authStatus = Get-RaymanGitHubAuthStatus -CliSource ([string]$cliResolution.source) -GitHubHost $GitHubHost
    $report.github_auth_status = [string]$authStatus.status

    if ($report.github_auth_status -eq 'unauthenticated') {
        if ($null -ne $BeforeGitHubLogin) {
            try {
                & $BeforeGitHubLogin
            } catch {}
        }

        $report.github_login_attempted = $true
        Write-Host "🔐 [Rayman] 因为遇到未登录，正在启动 GitHub 交互式登录..." -ForegroundColor Cyan
        Write-Host "（如果在终端里发生黑屏盲输密码，或者需查看一次性校验码，请看页面或上方提示）" -ForegroundColor DarkGray
        $loginProc = Start-Process -FilePath ([string]$cliResolution.source) -ArgumentList @('auth', 'login', '--hostname', $GitHubHost, '--git-protocol', $GitProtocol, '--web') -WorkingDirectory $WorkspaceRoot -Wait -PassThru -NoNewWindow
        $loginResult = [pscustomobject]@{
            success = ($null -ne $loginProc -and $loginProc.ExitCode -eq 0)
            output = ''
            error = if ($null -ne $loginProc -and $loginProc.ExitCode -ne 0) { "Process exited with code $($loginProc.ExitCode)" } else { "Unknown interactive failure" }
        }
        $postLoginStatus = Get-RaymanGitHubAuthStatus -CliSource ([string]$cliResolution.source) -GitHubHost $GitHubHost
        $report.github_auth_status = [string]$postLoginStatus.status
        $report.github_login_success = ([bool]$loginResult.success -and ($report.github_auth_status -eq 'authenticated'))
        if (-not [bool]$report.github_login_success) {
            $report.error_message = if (-not [string]::IsNullOrWhiteSpace([string]$loginResult.output)) { [string]$loginResult.output } else { [string]$loginResult.error }
            $report.repair_action = ('手工执行 `{0} auth login --hostname {1} --git-protocol {2} --web` 完成登录。' -f [string]$report.github_cli, $GitHubHost, $GitProtocol)
        }
        try {
            if ($null -ne $loginProc) {
                $loginProc.Dispose()
            }
        } catch {}
    } elseif ($report.github_auth_status -eq 'unknown') {
        $report.error_message = [string]$authStatus.output
        $report.repair_action = ('执行 `{0} auth status --hostname {1}` 确认状态；必要时再执行 `{0} auth login --hostname {1} --git-protocol {2} --web`。' -f [string]$report.github_cli, $GitHubHost, $GitProtocol)
    }

    if ($report.github_auth_status -eq 'authenticated') {
        $report.github_setup_git_attempted = $true
        $setupGitResult = Invoke-RaymanNativeCommandCapture -FilePath ([string]$cliResolution.source) -ArgumentList @('auth', 'setup-git', '--hostname', $GitHubHost) -WorkingDirectory $WorkspaceRoot
        $report.github_setup_git_success = [bool]$setupGitResult.success
        if (-not [bool]$report.github_setup_git_success) {
            $report.error_message = if (-not [string]::IsNullOrWhiteSpace([string]$setupGitResult.output)) { [string]$setupGitResult.output } else { [string]$setupGitResult.error }
            $report.repair_action = ('执行 `{0} auth setup-git --hostname {1}` 修复 Git credential 链。' -f [string]$report.github_cli, $GitHubHost)
        }
    }

    if ([bool]$GitHubLoginStrict) {
        if ($report.github_auth_status -ne 'authenticated') {
            $report.should_block_setup = $true
        } elseif (-not [bool]$report.github_setup_git_success) {
            $report.should_block_setup = $true
        }
    }

    return [pscustomobject]$report
}

function Get-RaymanPidFromFile {
    param([string]$PidFilePath)

    if ([string]::IsNullOrWhiteSpace($PidFilePath) -or -not (Test-Path -LiteralPath $PidFilePath -PathType Leaf)) {
        return 0
    }

    try {
        $raw = (Get-Content -LiteralPath $PidFilePath -Raw -Encoding ASCII).Trim()
        $parsed = 0
        if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -gt 0) {
            return $parsed
        }
    } catch {}

    return 0
}

function Test-RaymanPidFileProcess {
    param(
        [string]$PidFilePath,
        [string[]]$AllowedProcessNames = @()
    )

    $procId = Get-RaymanPidFromFile -PidFilePath $PidFilePath
    if ($procId -le 0) {
        return $false
    }

    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $proc) {
        return $false
    }

    if ($AllowedProcessNames.Count -eq 0) {
        return $true
    }

    $allowed = @($AllowedProcessNames | ForEach-Object { $_.ToLowerInvariant() })
    return ($allowed -contains ([string]$proc.ProcessName).ToLowerInvariant())
}

function Write-RaymanDiag {
    param(
        [string]$Scope,
        [string]$Message,
        [string]$WorkspaceRoot = ''
    )

    try {
        $root = if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
            Resolve-RaymanWorkspaceRoot
        } else {
            $WorkspaceRoot
        }
        $diagDir = Join-Path $root '.Rayman\logs\diag'
        if (-not (Test-Path -LiteralPath $diagDir -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $diagDir | Out-Null
        }

        $safeScope = if ([string]::IsNullOrWhiteSpace($Scope)) { 'general' } else { $Scope -replace '[^A-Za-z0-9._-]', '_' }
        $diagFile = Join-Path $diagDir ($safeScope + '.log')
        $line = ('[{0}] {1}' -f (Get-Date).ToString('s'), $Message)
        Add-Content -LiteralPath $diagFile -Value $line -Encoding UTF8
    } catch {}
}

function Repair-RaymanNestedDir {
    param([string]$WorkspaceRoot)

    $resolvedRoot = Resolve-RaymanWorkspaceRoot -StartPath $WorkspaceRoot
    $nestedPath = Join-Path $resolvedRoot '.Rayman\.Rayman'

    $result = [ordered]@{
        WorkspaceRoot = $resolvedRoot
        NestedPath = $nestedPath
        NestedExists = (Test-Path -LiteralPath $nestedPath -PathType Container)
        Repaired = $false
        Backup = ''
        Error = ''
    }

    if (-not $result.NestedExists) {
        return [pscustomobject]$result
    }

    try {
        $runtimeMigrationRoot = Join-Path $resolvedRoot '.Rayman\runtime\migration'
        $stateDir = Join-Path $resolvedRoot '.Rayman\state'
        $logsDir = Join-Path $resolvedRoot '.Rayman\logs'
        foreach ($dir in @($runtimeMigrationRoot, $stateDir, $logsDir)) {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
            }
        }

        $stamp = (Get-Date).ToString('yyyyMMdd_HHmmssfff')
        $backupPath = Join-Path $runtimeMigrationRoot ("nested_rayman_{0}" -f $stamp)
        Move-Item -LiteralPath $nestedPath -Destination $backupPath -Force

        $stateLog = Join-Path $stateDir 'nested_rayman_repair.log'
        $diagLog = Join-Path $logsDir 'diag.log'
        $line = "[{0}] nested-rayman-repair backup={1}" -f (Get-Date).ToString('s'), $backupPath

        Add-Content -LiteralPath $stateLog -Value ($line + ' OK') -Encoding UTF8
        Add-Content -LiteralPath $diagLog -Value $line -Encoding UTF8

        $result.Repaired = $true
        $result.Backup = $backupPath
        $result.NestedExists = $false
    } catch {
        $result.Error = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function ConvertTo-RaymanSafeNamespace([string]$Value) {
    $name = [string]$Value
    foreach ($invalidCh in [System.IO.Path]::GetInvalidFileNameChars()) {
        $name = $name.Replace([string]$invalidCh, '_')
    }
    $name = $name.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        return 'default'
    }
    return $name
}

function Get-RaymanMemoryPaths {
    param([string]$WorkspaceRoot)

    $resolvedRoot = Resolve-RaymanWorkspaceRoot -StartPath $WorkspaceRoot
    $memoryRoot = Join-Path $resolvedRoot '.Rayman\state\memory'
    $runtimeRoot = Join-Path $resolvedRoot '.Rayman\runtime\memory'

    return [pscustomobject]@{
        WorkspaceRoot = $resolvedRoot
        MemoryRoot = $memoryRoot
        RuntimeRoot = $runtimeRoot
        PendingRoot = Join-Path $runtimeRoot 'pending'
        DatabasePath = Join-Path $memoryRoot 'memory.sqlite3'
        StatusPath = Join-Path $runtimeRoot 'status.json'
    }
}

function Get-RaymanLegacyMemoryPaths {
    param([string]$WorkspaceRoot)

    $resolvedRoot = Resolve-RaymanWorkspaceRoot -StartPath $WorkspaceRoot
    $stateRoot = Join-Path $resolvedRoot '.Rayman\state'

    return [pscustomobject]@{
        WorkspaceRoot = $resolvedRoot
        LegacyRoot = Join-Path $resolvedRoot ('.' + 'rag')
        LegacyStateDirectory = Join-Path $stateRoot ('chroma' + '_db')
        LegacyStateFile = Join-Path $stateRoot ('rag' + '.db')
    }
}

function Invoke-RaymanGitSafe {
    param(
        [string]$WorkspaceRoot,
        [string[]]$GitArgs = @()
    )

    $result = [ordered]@{
        available = $false
        ok = $false
        reason = 'unknown'
        exitCode = -1
        stdout = @()
        stderr = @()
    }

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot) -or -not (Test-Path -LiteralPath $WorkspaceRoot -PathType Container)) {
        $result.reason = 'workspace_not_found'
        return [pscustomobject]$result
    }

    $gitCmd = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $gitCmd -or [string]::IsNullOrWhiteSpace([string]$gitCmd.Source)) {
        $result.reason = 'git_not_found'
        return [pscustomobject]$result
    }

    $result.available = $true

    $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_git_safe_' + [Guid]::NewGuid().ToString('N'))
    $stdoutPath = $tempBase + '.stdout.txt'
    $stderrPath = $tempBase + '.stderr.txt'

    try {
        $argumentString = (@($GitArgs) | ForEach-Object {
            $arg = [string]$_
            if ($arg -match '[\s"]') {
                '"' + ($arg -replace '"', '\"') + '"'
            } else {
                $arg
            }
        }) -join ' '

        $params = @{
            FilePath = [string]$gitCmd.Source
            ArgumentList = $argumentString
            WorkingDirectory = $WorkspaceRoot
            Wait = $true
            PassThru = $true
            RedirectStandardOutput = $stdoutPath
            RedirectStandardError = $stderrPath
        }
        if (Test-RaymanWindowsPlatform) {
            $params['WindowStyle'] = 'Hidden'
        } else {
            $params['NoNewWindow'] = $true
        }

        $proc = Start-Process @params

        if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
            $result.stdout = @([string[]](Get-Content -LiteralPath $stdoutPath -ErrorAction SilentlyContinue))
        }
        if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            $result.stderr = @([string[]](Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue))
        }

        $result.exitCode = [int]$proc.ExitCode
        $result.ok = ($result.exitCode -eq 0)
        $result.reason = if ($result.ok) { 'ok' } else { 'git_failed' }
    } catch {
        $result.reason = 'start_failed'
        $result.stderr = @($_.Exception.Message)
    } finally {
        try {
            if ($null -ne $proc) {
                $proc.Dispose()
            }
        } catch {}
        try { Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue } catch {}
        try { Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue } catch {}
    }

    return [pscustomobject]$result
}

function Get-RaymanScmTrackedNoiseRules {
    param([string]$WorkspaceRoot = '')

    $workspaceKind = Get-RaymanWorkspaceKind -WorkspaceRoot $WorkspaceRoot

    $sourceLocalRayman = @(
        [pscustomobject]@{ Key = 'skills_auto'; Label = '.Rayman/context/skills.auto.md'; QueryRoot = '.Rayman/context/skills.auto.md'; Path = '.Rayman/context/skills.auto.md'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'rayman_logs'; Label = '.Rayman/logs/**'; QueryRoot = '.Rayman/logs'; Path = '.Rayman/logs'; Recursive = $true; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'rayman_runtime'; Label = '.Rayman/runtime/**'; QueryRoot = '.Rayman/runtime'; Path = '.Rayman/runtime'; Recursive = $true; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'rayman_state'; Label = '.Rayman/state/**'; QueryRoot = '.Rayman/state'; Path = '.Rayman/state'; Recursive = $true; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'rayman_temp'; Label = '.Rayman/temp/**'; QueryRoot = '.Rayman/temp'; Path = '.Rayman/temp'; Recursive = $true; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'rayman_tmp'; Label = '.Rayman/tmp/**'; QueryRoot = '.Rayman/tmp'; Path = '.Rayman/tmp'; Recursive = $true; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'mcp_backup'; Label = '.Rayman/mcp/*.bak'; QueryRoot = '.Rayman/mcp'; Path = '.Rayman/mcp/*.bak'; Pattern = '^\.Rayman/mcp/.*\.bak$'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'release_delivery_pack'; Label = '.Rayman/release/delivery-pack-*.md'; QueryRoot = '.Rayman/release'; Path = '.Rayman/release/delivery-pack-*.md'; Pattern = '^\.Rayman/release/delivery-pack-.*\.md$'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'release_public_notes'; Label = '.Rayman/release/public-release-notes-*.md'; QueryRoot = '.Rayman/release'; Path = '.Rayman/release/public-release-notes-*.md'; Pattern = '^\.Rayman/release/public-release-notes-.*\.md$'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'release_notes'; Label = '.Rayman/release/release-notes-*.md'; QueryRoot = '.Rayman/release'; Path = '.Rayman/release/release-notes-*.md'; Pattern = '^\.Rayman/release/release-notes-.*\.md$'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'release_zip'; Label = '.Rayman/release/*.zip'; QueryRoot = '.Rayman/release'; Path = '.Rayman/release/*.zip'; Pattern = '^\.Rayman/release/.*\.zip$'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'release_tar_gz'; Label = '.Rayman/release/*.tar.gz'; QueryRoot = '.Rayman/release'; Path = '.Rayman/release/*.tar.gz'; Pattern = '^\.Rayman/release/.*\.tar\.gz$'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'full_copy_dir'; Label = '.Rayman_full_for_copy/**'; QueryRoot = '.Rayman_full_for_copy'; Path = '.Rayman_full_for_copy'; Recursive = $true; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'full_bundle_dir'; Label = 'Rayman_full_bundle/**'; QueryRoot = 'Rayman_full_bundle'; Path = 'Rayman_full_bundle'; Recursive = $true; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'sandbox_verify_dir'; Label = '.tmp_sandbox_verify_*/**'; QueryRoot = ':(glob).tmp_sandbox_verify_*'; Path = '.tmp_sandbox_verify_*/'; Pattern = '^\.tmp_sandbox_verify_[^/]+(?:/.*)?$'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'cursor_rules'; Label = '.cursorrules'; QueryRoot = '.cursorrules'; Path = '.cursorrules'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'cline_rules'; Label = '.clinerules'; QueryRoot = '.clinerules'; Path = '.clinerules'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'workspace_env'; Label = '.rayman.env.ps1'; QueryRoot = '.rayman.env.ps1'; Path = '.rayman.env.ps1'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'workspace_project'; Label = '.rayman.project.json'; QueryRoot = '.rayman.project.json'; Path = '.rayman.project.json'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'all_dev_ps1'; Label = 'all-dev.ps1'; QueryRoot = 'all-dev.ps1'; Path = 'all-dev.ps1'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'all_dev_bat'; Label = 'all-dev.bat'; QueryRoot = 'all-dev.bat'; Path = 'all-dev.bat'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'vscode_tasks'; Label = '.vscode/tasks.json'; QueryRoot = '.vscode/tasks.json'; Path = '.vscode/tasks.json'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'vscode_settings'; Label = '.vscode/settings.json'; QueryRoot = '.vscode/settings.json'; Path = '.vscode/settings.json'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'vscode_launch'; Label = '.vscode/launch.json'; QueryRoot = '.vscode/launch.json'; Path = '.vscode/launch.json'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'root_env'; Label = '.env'; QueryRoot = '.env'; Path = '.env'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'codex_config'; Label = '.codex/config.toml'; QueryRoot = '.codex/config.toml'; Path = '.codex/config.toml'; Recursive = $false; Kind = 'rayman' }
    )

    $externalRayman = @(
        [pscustomobject]@{ Key = 'rayman_dir'; Label = '.Rayman/**'; QueryRoot = '.Rayman'; Path = '.Rayman'; Recursive = $true; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'solution_name'; Label = '.SolutionName'; QueryRoot = '.SolutionName'; Path = '.SolutionName'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'cursor_rules'; Label = '.cursorrules'; QueryRoot = '.cursorrules'; Path = '.cursorrules'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'cline_rules'; Label = '.clinerules'; QueryRoot = '.clinerules'; Path = '.clinerules'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'workspace_env'; Label = '.rayman.env.ps1'; QueryRoot = '.rayman.env.ps1'; Path = '.rayman.env.ps1'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'workspace_project'; Label = '.rayman.project.json'; QueryRoot = '.rayman.project.json'; Path = '.rayman.project.json'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'codex_config'; Label = '.codex/config.toml'; QueryRoot = '.codex/config.toml'; Path = '.codex/config.toml'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'copilot_instructions'; Label = '.github/copilot-instructions.md'; QueryRoot = '.github/copilot-instructions.md'; Path = '.github/copilot-instructions.md'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'model_policy'; Label = '.github/model-policy.md'; QueryRoot = '.github/model-policy.md'; Path = '.github/model-policy.md'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'github_instructions'; Label = '.github/instructions/**'; QueryRoot = '.github/instructions'; Path = '.github/instructions'; Recursive = $true; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'github_agents'; Label = '.github/agents/**'; QueryRoot = '.github/agents'; Path = '.github/agents'; Recursive = $true; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'github_skills'; Label = '.github/skills/**'; QueryRoot = '.github/skills'; Path = '.github/skills'; Recursive = $true; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'github_prompts'; Label = '.github/prompts/**'; QueryRoot = '.github/prompts'; Path = '.github/prompts'; Recursive = $true; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'project_fast_gate'; Label = '.github/workflows/rayman-project-fast-gate.yml'; QueryRoot = '.github/workflows/rayman-project-fast-gate.yml'; Path = '.github/workflows/rayman-project-fast-gate.yml'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'project_browser_gate'; Label = '.github/workflows/rayman-project-browser-gate.yml'; QueryRoot = '.github/workflows/rayman-project-browser-gate.yml'; Path = '.github/workflows/rayman-project-browser-gate.yml'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'project_full_gate'; Label = '.github/workflows/rayman-project-full-gate.yml'; QueryRoot = '.github/workflows/rayman-project-full-gate.yml'; Path = '.github/workflows/rayman-project-full-gate.yml'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'vscode_tasks'; Label = '.vscode/tasks.json'; QueryRoot = '.vscode/tasks.json'; Path = '.vscode/tasks.json'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'vscode_settings'; Label = '.vscode/settings.json'; QueryRoot = '.vscode/settings.json'; Path = '.vscode/settings.json'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'vscode_launch'; Label = '.vscode/launch.json'; QueryRoot = '.vscode/launch.json'; Path = '.vscode/launch.json'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'full_copy_dir'; Label = '.Rayman_full_for_copy/**'; QueryRoot = '.Rayman_full_for_copy'; Path = '.Rayman_full_for_copy'; Recursive = $true; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'full_bundle_dir'; Label = 'Rayman_full_bundle/**'; QueryRoot = 'Rayman_full_bundle'; Path = 'Rayman_full_bundle'; Recursive = $true; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'sandbox_verify_dir'; Label = '.tmp_sandbox_verify_*/**'; QueryRoot = ':(glob).tmp_sandbox_verify_*'; Path = '.tmp_sandbox_verify_*/'; Pattern = '^\.tmp_sandbox_verify_[^/]+(?:/.*)?$'; Recursive = $false; Kind = 'rayman' }
    )

    $raymanManaged = if ($workspaceKind -eq 'source') { $sourceLocalRayman } else { $externalRayman }

    $advisory = @(
        [pscustomobject]@{ Key = 'dotnet_cache'; Label = '.dotnet10/**'; QueryRoot = '.dotnet10'; Path = '.dotnet10'; Recursive = $true; Kind = 'advisory' },
        [pscustomobject]@{ Key = 'dist_dir'; Label = 'dist/**'; QueryRoot = 'dist'; Path = 'dist'; Recursive = $true; Kind = 'advisory' },
        [pscustomobject]@{ Key = 'publish_dir'; Label = 'publish/**'; QueryRoot = 'publish'; Path = 'publish'; Recursive = $true; Kind = 'advisory' },
        [pscustomobject]@{ Key = 'tmp_dir'; Label = '.tmp/**'; QueryRoot = '.tmp'; Path = '.tmp'; Recursive = $true; Kind = 'advisory' },
        [pscustomobject]@{ Key = 'temp_dir'; Label = '.temp/**'; QueryRoot = '.temp'; Path = '.temp'; Recursive = $true; Kind = 'advisory' }
    )

    return [pscustomobject]@{
        WorkspaceKind = $workspaceKind
        RaymanManaged = @($raymanManaged)
        Advisory = @($advisory)
        All = @($raymanManaged + $advisory)
    }
}

function Test-RaymanScmTrackedNoiseRuleMatch {
    param(
        [string]$NormalizedPath,
        [object]$Rule
    )

    if ([string]::IsNullOrWhiteSpace($NormalizedPath) -or $null -eq $Rule) {
        return $false
    }

    $rulePath = [string]$Rule.Path
    if ([string]::IsNullOrWhiteSpace($rulePath)) {
        return $false
    }

    $pattern = ''
    if ($Rule.PSObject.Properties['Pattern']) {
        $pattern = [string]$Rule.Pattern
    }
    if (-not [string]::IsNullOrWhiteSpace($pattern)) {
        return ($NormalizedPath -match $pattern)
    }

    if ([bool]$Rule.Recursive) {
        return ($NormalizedPath -eq $rulePath -or $NormalizedPath.StartsWith($rulePath + '/'))
    }

    return ($NormalizedPath -eq $rulePath)
}

function ConvertTo-RaymanGitArgumentText {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "''"
    }

    if ($Value -notmatch '[\s"'']') {
        return $Value
    }

    return ("'{0}'" -f ($Value -replace "'", "''"))
}

function Get-RaymanScmTrackedNoiseGitRmCommand {
    param([string[]]$Paths = @())

    $normalized = @($Paths | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($normalized.Count -eq 0) {
        return ''
    }

    $rendered = @($normalized | ForEach-Object { ConvertTo-RaymanGitArgumentText -Value $_ })
    return ('git rm -r --cached -- {0}' -f ($rendered -join ' '))
}

function Format-RaymanScmTrackedNoiseGroups {
    param([object[]]$Groups = @())

    $items = @($Groups | Where-Object { $null -ne $_ -and [int]$_.Count -gt 0 } | ForEach-Object { "{0}:{1}" -f [string]$_.Label, [int]$_.Count })
    return ($items -join ', ')
}

function Format-RaymanScmTrackedNoiseSamples {
    param(
        [object[]]$Groups = @(),
        [int]$GroupLimit = 3,
        [int]$SampleLimit = 2
    )

    $items = New-Object System.Collections.Generic.List[string]
    foreach ($group in @($Groups | Where-Object { $null -ne $_ -and [int]$_.Count -gt 0 } | Select-Object -First $GroupLimit)) {
        $sampleItems = @($group.Samples | Select-Object -First $SampleLimit | ForEach-Object { [string]$_ })
        if ($sampleItems.Count -le 0) {
            continue
        }
        $items.Add(("{0} => {1}" -f [string]$group.Label, ($sampleItems -join ', '))) | Out-Null
    }

    return ($items.ToArray() -join ' | ')
}

function Get-RaymanScmTrackedNoiseAnalysis {
    param([string]$WorkspaceRoot)

    $workspaceKind = Get-RaymanWorkspaceKind -WorkspaceRoot $WorkspaceRoot
    $rules = Get-RaymanScmTrackedNoiseRules -WorkspaceRoot $WorkspaceRoot
    $result = [ordered]@{
        available = $false
        insideGit = $false
        reason = 'unknown'
        workspaceKind = $workspaceKind
        allowTrackedRaymanAssets = (Get-RaymanWorkspaceEnvBool -WorkspaceRoot $WorkspaceRoot -Name 'RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS' -Default $false)
        raymanGroups = @()
        advisoryGroups = @()
        raymanTrackedCount = 0
        advisoryTrackedCount = 0
        raymanMatchedRoots = @()
        advisoryMatchedRoots = @()
        raymanTrackedPaths = @()
        advisoryTrackedPaths = @()
        raymanCommand = ''
        advisoryCommand = ''
        raymanBlocked = $false
        advisoryPresent = $false
        status = 'unknown'
    }

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot) -or -not (Test-Path -LiteralPath $WorkspaceRoot -PathType Container)) {
        $result.reason = 'workspace_not_found'
        $result.status = 'workspace_not_found'
        return [pscustomobject]$result
    }

    $gitCmd = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $gitCmd -or [string]::IsNullOrWhiteSpace([string]$gitCmd.Source)) {
        $result.reason = 'git_not_found'
        $result.status = 'git_not_found'
        return [pscustomobject]$result
    }

    $result.available = $true

    try {
        & $gitCmd.Source -C $WorkspaceRoot rev-parse --is-inside-work-tree *> $null
        if ($LASTEXITCODE -ne 0) {
            $result.reason = 'not_git_workspace'
            $result.status = 'not_git_workspace'
            return [pscustomobject]$result
        }
        $result.insideGit = $true

        $queryRoots = @($rules.All | ForEach-Object { [string]$_.QueryRoot } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        $trackedLines = @(& $gitCmd.Source -C $WorkspaceRoot ls-files -- @($queryRoots) 2>$null)
        if ($LASTEXITCODE -ne 0) {
            $result.reason = 'git_ls_files_failed'
            $result.status = 'git_failed'
            return [pscustomobject]$result
        }

        $groupMap = @{}
        foreach ($rule in $rules.All) {
            $groupMap[[string]$rule.Key] = [ordered]@{
                Key = [string]$rule.Key
                Label = [string]$rule.Label
                Path = [string]$rule.Path
                Kind = [string]$rule.Kind
                Count = 0
                Samples = New-Object System.Collections.Generic.List[string]
            }
        }

        $raymanTrackedPaths = New-Object System.Collections.Generic.List[string]
        $advisoryTrackedPaths = New-Object System.Collections.Generic.List[string]
        $raymanMatchedRoots = New-Object System.Collections.Generic.List[string]
        $advisoryMatchedRoots = New-Object System.Collections.Generic.List[string]

        foreach ($rawLine in $trackedLines) {
            $line = [string]$rawLine
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            $normalizedPath = $line.Replace('\', '/').Trim()
            if ([string]::IsNullOrWhiteSpace($normalizedPath)) {
                continue
            }

            $matchedRule = $null
            foreach ($rule in $rules.All) {
                if (Test-RaymanScmTrackedNoiseRuleMatch -NormalizedPath $normalizedPath -Rule $rule) {
                    $matchedRule = $rule
                    break
                }
            }
            if ($null -eq $matchedRule) {
                continue
            }

            $group = $groupMap[[string]$matchedRule.Key]
            $group.Count = [int]$group.Count + 1
            if ($group.Samples.Count -lt 3) {
                $group.Samples.Add($normalizedPath) | Out-Null
            }

            if ([string]$matchedRule.Kind -eq 'rayman') {
                $commandPath = ''
                if ($matchedRule.PSObject.Properties['CommandPath']) {
                    $commandPath = [string]$matchedRule.CommandPath
                }
                if ([string]::IsNullOrWhiteSpace($commandPath)) {
                    $commandPath = [string]$matchedRule.Path
                }
                if ([string]::IsNullOrWhiteSpace($commandPath) -and $matchedRule.PSObject.Properties['Pattern']) {
                    $commandPath = $normalizedPath
                }
                $raymanTrackedPaths.Add($normalizedPath) | Out-Null
                if (-not [string]::IsNullOrWhiteSpace($commandPath) -and $raymanMatchedRoots -notcontains $commandPath) {
                    $raymanMatchedRoots.Add($commandPath) | Out-Null
                }
            } else {
                $commandPath = ''
                if ($matchedRule.PSObject.Properties['CommandPath']) {
                    $commandPath = [string]$matchedRule.CommandPath
                }
                if ([string]::IsNullOrWhiteSpace($commandPath)) {
                    $commandPath = [string]$matchedRule.Path
                }
                if ([string]::IsNullOrWhiteSpace($commandPath) -and $matchedRule.PSObject.Properties['Pattern']) {
                    $commandPath = $normalizedPath
                }
                $advisoryTrackedPaths.Add($normalizedPath) | Out-Null
                if (-not [string]::IsNullOrWhiteSpace($commandPath) -and $advisoryMatchedRoots -notcontains $commandPath) {
                    $advisoryMatchedRoots.Add($commandPath) | Out-Null
                }
            }
        }

        $result.raymanGroups = @(
            foreach ($group in $groupMap.Values) {
                if ([string]$group.Kind -ne 'rayman' -or [int]$group.Count -le 0) { continue }
                [pscustomobject]@{
                    Key = [string]$group.Key
                    Label = [string]$group.Label
                    Path = [string]$group.Path
                    Kind = [string]$group.Kind
                    Count = [int]$group.Count
                    Samples = @($group.Samples.ToArray())
                }
            }
        )
        $result.advisoryGroups = @(
            foreach ($group in $groupMap.Values) {
                if ([string]$group.Kind -ne 'advisory' -or [int]$group.Count -le 0) { continue }
                [pscustomobject]@{
                    Key = [string]$group.Key
                    Label = [string]$group.Label
                    Path = [string]$group.Path
                    Kind = [string]$group.Kind
                    Count = [int]$group.Count
                    Samples = @($group.Samples.ToArray())
                }
            }
        )

        $raymanCountMeasure = @($result.raymanGroups | Measure-Object -Property Count -Sum)
        if ($raymanCountMeasure.Count -gt 0 -and $null -ne $raymanCountMeasure[0].Sum) {
            $result.raymanTrackedCount = [int]$raymanCountMeasure[0].Sum
        } else {
            $result.raymanTrackedCount = 0
        }

        $advisoryCountMeasure = @($result.advisoryGroups | Measure-Object -Property Count -Sum)
        if ($advisoryCountMeasure.Count -gt 0 -and $null -ne $advisoryCountMeasure[0].Sum) {
            $result.advisoryTrackedCount = [int]$advisoryCountMeasure[0].Sum
        } else {
            $result.advisoryTrackedCount = 0
        }
        $result.raymanTrackedPaths = @($raymanTrackedPaths.ToArray())
        $result.advisoryTrackedPaths = @($advisoryTrackedPaths.ToArray())
        $result.raymanMatchedRoots = @($raymanMatchedRoots.ToArray())
        $result.advisoryMatchedRoots = @($advisoryMatchedRoots.ToArray())
        $result.raymanCommand = Get-RaymanScmTrackedNoiseGitRmCommand -Paths $result.raymanMatchedRoots
        $result.advisoryCommand = Get-RaymanScmTrackedNoiseGitRmCommand -Paths $result.advisoryMatchedRoots
        $result.raymanBlocked = ([int]$result.raymanTrackedCount -gt 0 -and -not [bool]$result.allowTrackedRaymanAssets)
        $result.advisoryPresent = ([int]$result.advisoryTrackedCount -gt 0)

        if ($result.raymanBlocked) {
            $result.status = 'block'
        } elseif ([int]$result.raymanTrackedCount -gt 0 -and [bool]$result.allowTrackedRaymanAssets) {
            if ($result.advisoryPresent) {
                $result.status = 'allowed_warn'
            } else {
                $result.status = 'allowed'
            }
        } elseif ($result.advisoryPresent) {
            $result.status = 'warn'
        } else {
            $result.status = 'clear'
        }

        $result.reason = 'ok'
    } catch {
        $result.reason = 'analysis_failed'
        $result.status = 'analysis_failed'
    }

    return [pscustomobject]$result
}

function Invoke-RaymanAttentionAlert {
    param(
        [string]$Kind = 'manual',
        [string]$Reason = '',
        [int]$MaxSeconds = 30,
        [string]$Title = '',
        [string]$WorkspaceRoot = ''
    )

    $root = Get-RaymanAttentionWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace([string]$root)) {
        $root = if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
            Resolve-RaymanWorkspaceRoot
        } else {
            Resolve-RaymanWorkspaceRoot -StartPath $WorkspaceRoot
        }
    }
    $assetAnalysis = Get-RaymanRequiredAssetAnalysis -WorkspaceRoot $root -Label 'attention-alert' -RequiredRelPaths @(
        '.Rayman/scripts/utils/request_attention.ps1'
    )
    $scriptPath = ''
    if ($null -ne $assetAnalysis -and [bool]$assetAnalysis.ok -and @($assetAnalysis.assets).Count -gt 0) {
        $scriptPath = [string]$assetAnalysis.assets[0].absolute_path
    }
    $message = if ([string]::IsNullOrWhiteSpace($Reason)) {
        ('Rayman attention requested ({0}).' -f $Kind)
    } else {
        $Reason
    }
    $toastTitle = if ([string]::IsNullOrWhiteSpace($Title)) {
        switch ($Kind) {
            'error' { 'Rayman 错误提醒' }
            'done' { 'Rayman 完成提醒' }
            default { 'Rayman 提醒' }
        }
    } else {
        $Title
    }

    $alertEnabled = Get-RaymanAttentionAlertEnabled -WorkspaceRoot $root -Kind $Kind
    $speechEnabled = Get-RaymanAttentionSpeechEnabled -WorkspaceRoot $root -Kind $Kind
    $soundEnabled = Get-RaymanAttentionSoundEnabled -WorkspaceRoot $root -Kind $Kind
    $surface = Get-RaymanAttentionSurface -WorkspaceRoot $root -Default 'log'

    if (-not $alertEnabled) {
        try {
            Write-RaymanDiag -Scope 'attention' -Message ("request_attention suppressed ({0}): {1}" -f $Kind, $message) -WorkspaceRoot $root
        } catch {}
        try {
            Write-RaymanAttentionState -WorkspaceRoot $root -Kind $Kind -Title $toastTitle -Message $message -Surface $surface -AlertEnabled $false -SpeechEnabled $false -Suppressed $true
        } catch {}

        return [pscustomobject]@{
            Kind = $Kind
            Title = $toastTitle
            Reason = $message
            MaxSeconds = $MaxSeconds
            RequestedAt = (Get-Date).ToString('o')
            Surface = $surface
            AlertEnabled = $false
            SpeechEnabled = $false
            Suppressed = $true
        }
    }

    try {
        Write-RaymanDiag -Scope 'attention' -Message ("request_attention ({0}, surface={1}): {2}" -f $Kind, $surface, $message) -WorkspaceRoot $root
    } catch {}

    $delivered = $false
    $shouldInvokeScript = (
        -not [string]::IsNullOrWhiteSpace($scriptPath) -and
        (Test-Path -LiteralPath $scriptPath -PathType Leaf) -and
        ($surface -eq 'toast' -or $speechEnabled -or $soundEnabled)
    )
    if ($shouldInvokeScript) {
        try {
            $attentionParams = @{
                Kind = $Kind
                Message = $message
                Title = $toastTitle
                WorkspaceRoot = $root
            }
            if ($speechEnabled) {
                $attentionParams['EnableSpeech'] = $true
            } else {
                $attentionParams['DisableSpeech'] = $true
            }
            if (-not $soundEnabled) {
                $attentionParams['DisableSound'] = $true
            }
            & $scriptPath @attentionParams | Out-Null
            $delivered = $true
        } catch {
            Write-RaymanDiag -Scope 'attention' -Message ("request_attention failed: {0}" -f $_.Exception.ToString()) -WorkspaceRoot $root
            if ($surface -ne 'silent') {
                Write-RaymanAttentionConsoleMessage -Kind $Kind -Title $toastTitle -Message $message
            }
        }
    } elseif ($surface -eq 'toast') {
        Write-RaymanRequiredAssetDiagnostics -Analysis $assetAnalysis -Scope 'attention'
        Write-RaymanAttentionConsoleMessage -Kind $Kind -Title $toastTitle -Message $message
    } elseif ($surface -eq 'log') {
        Write-RaymanAttentionConsoleMessage -Kind $Kind -Title $toastTitle -Message $message
    }

    try {
        Write-RaymanAttentionState -WorkspaceRoot $root -Kind $Kind -Title $toastTitle -Message $message -Surface $surface -AlertEnabled $true -SpeechEnabled $(if ($surface -eq 'toast') { $speechEnabled } else { $false }) -Suppressed $false
    } catch {}

    return [pscustomobject]@{
        Kind = $Kind
        Title = $toastTitle
        Reason = $message
        MaxSeconds = $MaxSeconds
        RequestedAt = (Get-Date).ToString('o')
        Surface = $surface
        AlertEnabled = $true
        SpeechEnabled = $(if ($surface -eq 'toast') { $speechEnabled } else { $false })
        Delivered = $delivered
        Suppressed = $false
    }
}
