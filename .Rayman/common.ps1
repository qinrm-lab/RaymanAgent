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

    try {
        $proc = Get-Process -Id $procId -ErrorAction Stop
        if ($AllowedProcessNames.Count -eq 0) {
            return $true
        }

        $allowed = @($AllowedProcessNames | ForEach-Object { $_.ToLowerInvariant() })
        return ($allowed -contains ([string]$proc.ProcessName).ToLowerInvariant())
    } catch {
        return $false
    }
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

function Invoke-RaymanAttentionAlert {
    param(
        [string]$Kind = 'manual',
        [string]$Reason = '',
        [int]$MaxSeconds = 30,
        [string]$WorkspaceRoot = ''
    )

    $root = if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        Resolve-RaymanWorkspaceRoot
    } else {
        Resolve-RaymanWorkspaceRoot -StartPath $WorkspaceRoot
    }
    $scriptPath = Join-Path $root '.Rayman\scripts\utils\request_attention.ps1'
    $message = if ([string]::IsNullOrWhiteSpace($Reason)) {
        ('Rayman attention requested ({0}).' -f $Kind)
    } else {
        $Reason
    }

    if (Test-Path -LiteralPath $scriptPath -PathType Leaf) {
        try {
            & $scriptPath -Message $message | Out-Null
        } catch {
            Write-RaymanDiag -Scope 'attention' -Message ("request_attention failed: {0}" -f $_.Exception.ToString()) -WorkspaceRoot $root
            Write-Warn ("[attention] {0}" -f $message)
        }
    } else {
        Write-Warn ("[attention] {0}" -f $message)
    }

    return [pscustomobject]@{
        Kind = $Kind
        Reason = $message
        MaxSeconds = $MaxSeconds
        RequestedAt = (Get-Date).ToString('o')
    }
}
