Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    try {
        $full = [System.IO.Path]::GetFullPath($candidate)
    } catch {
        $full = $candidate
    }
    return ($full.TrimEnd('\', '/') -replace '\\', '/').ToLowerInvariant()
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
    $workspaceNorm = Get-RaymanPathComparisonValue -PathValue $WorkspaceRoot
    $reportNorm = Get-RaymanPathComparisonValue -PathValue $reportRoot
    if ([string]::IsNullOrWhiteSpace($workspaceNorm) -or [string]::IsNullOrWhiteSpace($reportNorm)) {
        return $false
    }
    return ($workspaceNorm -eq $reportNorm)
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

    $envFile = Join-Path $WorkspaceRoot '.rayman.env.ps1'
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
    if ($null -ne $processValue) {
        return [string]$processValue
    }

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot) -or [string]::IsNullOrWhiteSpace($Name)) {
        return $Default
    }

    $envFile = Join-Path $WorkspaceRoot '.rayman.env.ps1'
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

function Get-RaymanAttentionWatchProcessNames {
    $explicit = [Environment]::GetEnvironmentVariable('RAYMAN_ALERT_WATCH_PROCESS_NAMES')
    if (-not [string]::IsNullOrWhiteSpace($explicit)) {
        return @(Get-RaymanStringListEnv -Name 'RAYMAN_ALERT_WATCH_PROCESS_NAMES' -Default @())
    }

    $names = New-Object 'System.Collections.Generic.List[string]'
    if (Get-RaymanEnvBool -Name 'RAYMAN_ALERT_WATCH_VSCODE_WINDOWS_ENABLED' -Default $false) {
        $names.Add('Code') | Out-Null
        $names.Add('Code - Insiders') | Out-Null
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
    $candidates = @('pwsh.exe', 'pwsh', 'powershell.exe', 'powershell')
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

function Get-RaymanRagPaths {
    param([string]$WorkspaceRoot)

    $resolvedRoot = Resolve-RaymanWorkspaceRoot -StartPath $WorkspaceRoot

    $ragRootRaw = [string][Environment]::GetEnvironmentVariable('RAYMAN_RAG_ROOT')
    if ([string]::IsNullOrWhiteSpace($ragRootRaw)) {
        $ragRoot = Join-Path $resolvedRoot '.rag'
    } elseif ([System.IO.Path]::IsPathRooted($ragRootRaw)) {
        $ragRoot = $ragRootRaw
    } else {
        $ragRoot = Join-Path $resolvedRoot $ragRootRaw
    }

    $namespaceRaw = [string][Environment]::GetEnvironmentVariable('RAYMAN_RAG_NAMESPACE')
    if ([string]::IsNullOrWhiteSpace($namespaceRaw)) {
        $namespaceRaw = Split-Path -Leaf $resolvedRoot
    }
    $namespace = ConvertTo-RaymanSafeNamespace -Value $namespaceRaw

    $projectRoot = Join-Path $ragRoot $namespace
    $chromaDbPath = Join-Path $projectRoot 'chroma_db'
    $indexRoot = Join-Path $projectRoot 'index'

    return [pscustomobject]@{
        WorkspaceRoot = $resolvedRoot
        RagRoot = $ragRoot
        Namespace = $namespace
        ProjectRoot = $projectRoot
        ChromaDbPath = $chromaDbPath
        IndexRoot = $indexRoot
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

        $proc = Start-Process -FilePath ([string]$gitCmd.Source) -ArgumentList $argumentString -WorkingDirectory $WorkspaceRoot -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

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
        [pscustomobject]@{ Key = 'mcp_backup'; Label = '.Rayman/mcp/*.bak'; QueryRoot = '.Rayman/mcp'; Path = '.Rayman/mcp/*.bak'; Pattern = '^\.Rayman/mcp/.*\.bak$'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'release_delivery_pack'; Label = '.Rayman/release/delivery-pack-*.md'; QueryRoot = '.Rayman/release'; Path = '.Rayman/release/delivery-pack-*.md'; Pattern = '^\.Rayman/release/delivery-pack-.*\.md$'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'release_public_notes'; Label = '.Rayman/release/public-release-notes-*.md'; QueryRoot = '.Rayman/release'; Path = '.Rayman/release/public-release-notes-*.md'; Pattern = '^\.Rayman/release/public-release-notes-.*\.md$'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'release_notes'; Label = '.Rayman/release/release-notes-*.md'; QueryRoot = '.Rayman/release'; Path = '.Rayman/release/release-notes-*.md'; Pattern = '^\.Rayman/release/release-notes-.*\.md$'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'cursor_rules'; Label = '.cursorrules'; QueryRoot = '.cursorrules'; Path = '.cursorrules'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'cline_rules'; Label = '.clinerules'; QueryRoot = '.clinerules'; Path = '.clinerules'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'workspace_env'; Label = '.rayman.env.ps1'; QueryRoot = '.rayman.env.ps1'; Path = '.rayman.env.ps1'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'vscode_tasks'; Label = '.vscode/tasks.json'; QueryRoot = '.vscode/tasks.json'; Path = '.vscode/tasks.json'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'vscode_settings'; Label = '.vscode/settings.json'; QueryRoot = '.vscode/settings.json'; Path = '.vscode/settings.json'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'root_env'; Label = '.env'; QueryRoot = '.env'; Path = '.env'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'codex_config'; Label = '.codex/config.toml'; QueryRoot = '.codex/config.toml'; Path = '.codex/config.toml'; Recursive = $false; Kind = 'rayman' }
    )

    $externalRayman = @(
        [pscustomobject]@{ Key = 'rayman_dir'; Label = '.Rayman/**'; QueryRoot = '.Rayman'; Path = '.Rayman'; Recursive = $true; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'solution_name'; Label = '.SolutionName'; QueryRoot = '.SolutionName'; Path = '.SolutionName'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'cursor_rules'; Label = '.cursorrules'; QueryRoot = '.cursorrules'; Path = '.cursorrules'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'cline_rules'; Label = '.clinerules'; QueryRoot = '.clinerules'; Path = '.clinerules'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'workspace_env'; Label = '.rayman.env.ps1'; QueryRoot = '.rayman.env.ps1'; Path = '.rayman.env.ps1'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'copilot_instructions'; Label = '.github/copilot-instructions.md'; QueryRoot = '.github/copilot-instructions.md'; Path = '.github/copilot-instructions.md'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'vscode_tasks'; Label = '.vscode/tasks.json'; QueryRoot = '.vscode/tasks.json'; Path = '.vscode/tasks.json'; Recursive = $false; Kind = 'rayman' },
        [pscustomobject]@{ Key = 'vscode_settings'; Label = '.vscode/settings.json'; QueryRoot = '.vscode/settings.json'; Path = '.vscode/settings.json'; Recursive = $false; Kind = 'rayman' }
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

    $root = if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        Resolve-RaymanWorkspaceRoot
    } else {
        Resolve-RaymanWorkspaceRoot -StartPath $WorkspaceRoot
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

    if (-not [string]::IsNullOrWhiteSpace($scriptPath) -and (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        try {
            & $scriptPath -Message $message -Title $toastTitle | Out-Null
        } catch {
            Write-RaymanDiag -Scope 'attention' -Message ("request_attention failed: {0}" -f $_.Exception.ToString()) -WorkspaceRoot $root
            Write-Warn ("[attention] {0}" -f $message)
        }
    } else {
        Write-RaymanRequiredAssetDiagnostics -Analysis $assetAnalysis -Scope 'attention'
        Write-Warn ("[attention] {0}" -f $message)
    }

    return [pscustomobject]@{
        Kind = $Kind
        Title = $toastTitle
        Reason = $message
        MaxSeconds = $MaxSeconds
        RequestedAt = (Get-Date).ToString('o')
    }
}
