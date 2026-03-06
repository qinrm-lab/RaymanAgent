param(
    [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
    [object]$AutoInstall = $true,
    [object]$Require = $true,
    [string]$OnlyKinds = '',
    [string]$Caller = '',
    [string]$CallerHostType = '',
    [string]$CallerWorkspaceRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info([string]$m){ Write-Host ("ℹ️  [test-deps] {0}" -f $m) -ForegroundColor Cyan }
function Warn([string]$m){ Write-Host ("⚠️  [test-deps] {0}" -f $m) -ForegroundColor Yellow }
function Fail([string]$m){ Write-Host ("❌ [test-deps] {0}" -f $m) -ForegroundColor Red; exit 2 }

function Convert-ToBoolCompat([object]$Value, [bool]$Default) {
    if ($null -eq $Value) { return $Default }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    if ($Value -is [sbyte] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]) {
        return ([int64]$Value -ne 0)
    }

    $raw = [string]$Value
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    $token = $raw.Trim().ToLowerInvariant()
    switch ($token) {
        '1' { return $true }
        'true' { return $true }
        '$true' { return $true }
        'yes' { return $true }
        'y' { return $true }
        'on' { return $true }
        '0' { return $false }
        'false' { return $false }
        '$false' { return $false }
        'no' { return $false }
        'n' { return $false }
        'off' { return $false }
    }

    try {
        return [bool]::Parse($raw)
    } catch {
        return $Default
    }
}

function Test-Cmd([string]$Name) {
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-PythonCmd {
    return (Test-Cmd 'python') -or (Test-Cmd 'python3')
}

function Resolve-OnlyKinds([string]$OnlyKindsText) {
    $result = [ordered]@{
        DotNet = $true
        Node = $true
        Python = $true
        Raw = 'all'
    }

    if ([string]::IsNullOrWhiteSpace($OnlyKindsText)) {
        return [pscustomobject]$result
    }

    $tokens = @()
    foreach ($part in ($OnlyKindsText -split ',')) {
        $t = [string]$part
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        $tokens += $t.Trim().ToLowerInvariant()
    }
    if ($tokens.Count -eq 0) {
        return [pscustomobject]$result
    }

    $result.DotNet = $false
    $result.Node = $false
    $result.Python = $false
    $result.Raw = ($tokens -join ',')

    foreach ($tk in $tokens) {
        switch ($tk) {
            'all' {
                $result.DotNet = $true
                $result.Node = $true
                $result.Python = $true
            }
            'dotnet' { $result.DotNet = $true }
            'node' { $result.Node = $true }
            'python' { $result.Python = $true }
            default {
                throw ("invalid value for -OnlyKinds: '{0}' (allowed: dotnet,node,python,all)" -f $tk)
            }
        }
    }

    return [pscustomobject]$result
}

function Get-HostTypeLabel {
    try {
        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            return 'windows'
        }
    } catch {}
    return 'non-windows'
}

function Add-PathHint([string]$PathItem) {
    if ([string]::IsNullOrWhiteSpace($PathItem)) { return }
    if (-not (Test-Path -LiteralPath $PathItem -PathType Container)) { return }
    if ($env:Path -notlike ('*' + $PathItem + '*')) {
        $env:Path = "$PathItem;$env:Path"
    }
}

function Refresh-ProcessPathFromRegistryBestEffort {
    try {
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $parts = @()
        if (-not [string]::IsNullOrWhiteSpace($machinePath)) { $parts += $machinePath }
        if (-not [string]::IsNullOrWhiteSpace($userPath)) { $parts += $userPath }
        if ($parts.Count -gt 0) { $env:Path = ($parts -join ';') }
    } catch {}
}

function Add-ToolPathHintsBestEffort {
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        Add-PathHint (Join-Path $env:ProgramFiles 'dotnet')
        Add-PathHint (Join-Path $env:ProgramFiles 'nodejs')
    }

    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return }

    $pythonRoots = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python310')
    )
    foreach ($root in $pythonRoots) {
        Add-PathHint $root
        Add-PathHint (Join-Path $root 'Scripts')
    }
}

function Ensure-WindowsAppsInPathBestEffort {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return }
    $wa = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    if (-not (Test-Path -LiteralPath $wa -PathType Container)) { return }

    if ($env:Path -notlike ('*' + $wa + '*')) {
        $env:Path = "$wa;$env:Path"
    }

    try {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ([string]::IsNullOrWhiteSpace($userPath)) { $userPath = '' }
        if ($userPath -notlike ('*' + $wa + '*')) {
            $newUserPath = if ([string]::IsNullOrWhiteSpace($userPath)) { $wa } else { ($wa + ';' + $userPath) }
            [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
        }
    } catch {}
}

function Install-WithWinget([string]$Id) {
    if (-not (Test-Cmd 'winget')) {
        Ensure-WindowsAppsInPathBestEffort
    }
    if (-not (Test-Cmd 'winget')) {
        return $false
    }

    Info ("trying winget install: {0}" -f $Id)
    & winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements | Out-Host
    Refresh-ProcessPathFromRegistryBestEffort
    Ensure-WindowsAppsInPathBestEffort
    Add-ToolPathHintsBestEffort
    return ($LASTEXITCODE -eq 0)
}

function Install-DotNetLocal([bool]$NeedWindowsDesktop) {
    $channel = [string][Environment]::GetEnvironmentVariable('RAYMAN_DOTNET_CHANNEL')
    if ([string]::IsNullOrWhiteSpace($channel)) { $channel = 'LTS' }

    $baseDir = [string]$env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($baseDir)) {
        $baseDir = Join-Path $HOME '.rayman'
    }
    $root = Join-Path $baseDir 'Rayman'
    $scriptPath = Join-Path $root 'dotnet-install.ps1'
    $dotnetRoot = Join-Path $root 'dotnet'

    New-Item -ItemType Directory -Force -Path $root | Out-Null
    New-Item -ItemType Directory -Force -Path $dotnetRoot | Out-Null

    Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $scriptPath -UseBasicParsing

    Info ("installing dotnet SDK channel={0} to {1}" -f $channel, $dotnetRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Channel $channel -InstallDir $dotnetRoot -NoPath | Out-Host

    if ($NeedWindowsDesktop) {
        Info ("installing windowsdesktop runtime channel={0}" -f $channel)
        & powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Channel $channel -Runtime 'windowsdesktop' -OS 'win' -Architecture 'x64' -InstallDir $dotnetRoot -NoPath | Out-Host
    }

    $env:DOTNET_ROOT = $dotnetRoot
    if ($env:Path -notlike ('*' + $dotnetRoot + '*')) {
        $env:Path = "$dotnetRoot;$env:Path"
    }
    try {
        [Environment]::SetEnvironmentVariable('DOTNET_ROOT', $dotnetRoot, 'User')
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ([string]::IsNullOrWhiteSpace($userPath)) { $userPath = '' }
        if ($userPath -notmatch [regex]::Escape($dotnetRoot)) {
            $newUserPath = if ([string]::IsNullOrWhiteSpace($userPath)) { $dotnetRoot } else { "$dotnetRoot;$userPath" }
            [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
        }
    } catch {}
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$AutoInstall = Convert-ToBoolCompat -Value $AutoInstall -Default $true
$Require = Convert-ToBoolCompat -Value $Require -Default $true
$onlyKindsConfig = Resolve-OnlyKinds -OnlyKindsText $OnlyKinds
Set-Location $WorkspaceRoot
Refresh-ProcessPathFromRegistryBestEffort
Ensure-WindowsAppsInPathBestEffort
Add-ToolPathHintsBestEffort

$hostType = Get-HostTypeLabel
$callerLabel = if ([string]::IsNullOrWhiteSpace($Caller)) { 'direct' } else { $Caller }
$callerHostLabel = if ([string]::IsNullOrWhiteSpace($CallerHostType)) { 'unknown' } else { $CallerHostType }
$callerWorkspaceLabel = if ([string]::IsNullOrWhiteSpace($CallerWorkspaceRoot)) { '(not provided)' } else { $CallerWorkspaceRoot }
Info ("context caller={0}, callerHost={1}, scriptHost={2}, workspace={3}, callerWorkspace={4}, onlyKinds={5}" -f $callerLabel, $callerHostLabel, $hostType, $WorkspaceRoot, $callerWorkspaceLabel, [string]$onlyKindsConfig.Raw)

$excludeSegs = @('\.git\', '\.Rayman\', '\.venv\', '\node_modules\', '\bin\', '\obj\')
function Is-ExcludedPath([string]$FullPath) {
    $p = $FullPath.Replace('/', '\')
    foreach ($seg in $excludeSegs) {
        if ($p -like ('*' + $seg + '*')) { return $true }
    }
    return $false
}

$projectFiles = Get-ChildItem -LiteralPath $WorkspaceRoot -Recurse -File -Include *.sln,*.slnx,*.csproj,*.fsproj,*.vbproj,package.json,pyproject.toml,requirements.txt -ErrorAction SilentlyContinue |
    Where-Object { -not (Is-ExcludedPath -FullPath $_.FullName) }

$needsDotNet = $false
$needsNode = $false
$needsPython = $false
$needWindowsDesktop = $false

foreach ($f in $projectFiles) {
    switch -Regex ($f.Name) {
        '\.(sln|slnx|csproj|fsproj|vbproj)$' {
            $needsDotNet = $true
            if ($f.Extension -eq '.csproj') {
                try {
                    $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
                    if ($raw -match '<UseWPF>\s*true\s*</UseWPF>' -or $raw -match '<UseWindowsForms>\s*true\s*</UseWindowsForms>') {
                        $needWindowsDesktop = $true
                    }
                } catch {}
            }
        }
        '^package\.json$' { $needsNode = $true }
        '^(pyproject\.toml|requirements\.txt)$' { $needsPython = $true }
    }
}

if (-not $onlyKindsConfig.DotNet) { $needsDotNet = $false }
if (-not $onlyKindsConfig.Node) { $needsNode = $false }
if (-not $onlyKindsConfig.Python) { $needsPython = $false }

Info ("detected deps: dotnet={0}, node={1}, python={2}, windowsDesktop={3}" -f $needsDotNet, $needsNode, $needsPython, $needWindowsDesktop)

$missing = New-Object System.Collections.Generic.List[string]

if ($needsDotNet -and -not (Test-Cmd 'dotnet')) {
    if ($AutoInstall) {
        Warn "dotnet missing; trying auto install"
        $null = Install-WithWinget -Id 'Microsoft.DotNet.SDK.8'
        if (-not (Test-Cmd 'dotnet')) {
            Warn 'winget install dotnet failed/unavailable; fallback to dotnet-install.ps1'
            try { Install-DotNetLocal -NeedWindowsDesktop:$needWindowsDesktop } catch { Warn ("dotnet-install fallback failed: {0}" -f $_.Exception.Message) }
        }
    }
    if (-not (Test-Cmd 'dotnet')) { [void]$missing.Add('dotnet') }
}

if ($needsNode -and -not (Test-Cmd 'node')) {
    if ($AutoInstall) {
        Warn "node missing; trying auto install via winget"
        $null = Install-WithWinget -Id 'OpenJS.NodeJS.LTS'
    }
    if (-not (Test-Cmd 'node')) { [void]$missing.Add('node') }
}

if ($needsPython -and -not (Test-PythonCmd)) {
    if ($AutoInstall) {
        Warn "python missing; trying auto install via winget"
        $null = Install-WithWinget -Id 'Python.Python.3.12'
    }
    if (-not (Test-PythonCmd)) { [void]$missing.Add('python') }
}

if ($missing.Count -gt 0) {
    $msg = "missing required test dependencies: {0}" -f ($missing -join ', ')
    if ($Require) {
        Fail $msg
    } else {
        Warn $msg
    }
} else {
    Info 'test dependencies ready'
}

exit 0
