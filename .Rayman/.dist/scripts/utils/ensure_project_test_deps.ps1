param(
    [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
    [object]$AutoInstall = $true,
    [object]$Require = $true,
    [switch]$NoMain,
    [string]$OnlyKinds = '',
    [string]$Caller = '',
    [string]$CallerHostType = '',
    [string]$CallerWorkspaceRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
    . $commonPath
}

$workspacePlatformProfilePath = Join-Path $PSScriptRoot 'workspace_platform_profile.ps1'
if (Test-Path -LiteralPath $workspacePlatformProfilePath -PathType Leaf) {
    . $workspacePlatformProfilePath -NoMain
}

function Info([string]$m){ Write-Host ("ℹ️  [test-deps] {0}" -f $m) -ForegroundColor Cyan }
function Warn([string]$m){ Write-Host ("⚠️  [test-deps] {0}" -f $m) -ForegroundColor Yellow }
function Fail([string]$m){ Write-Host ("❌ [test-deps] {0}" -f $m) -ForegroundColor Red }

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

function Get-RaymanDotNetTargetFrameworksFromText {
    param([string]$ProjectText)

    $frameworks = New-Object 'System.Collections.Generic.List[string]'
    if ([string]::IsNullOrWhiteSpace($ProjectText)) {
        return @()
    }

    foreach ($match in [regex]::Matches($ProjectText, '<TargetFrameworks?\b[^>]*>\s*([^<]+?)\s*</TargetFrameworks?>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $raw = [string]$match.Groups[1].Value
        foreach ($part in ($raw -split ';')) {
            $token = [string]$part
            if ([string]::IsNullOrWhiteSpace($token)) { continue }
            $token = $token.Trim()
            if ($token -match '\$\(') { continue }
            if (-not $frameworks.Contains($token)) {
                $frameworks.Add($token) | Out-Null
            }
        }
    }

    return @($frameworks.ToArray())
}

function Get-RaymanDotNetSdkMajorFromFrameworks {
    param([string[]]$Frameworks)

    $highest = 0
    foreach ($framework in @($Frameworks)) {
        if ([string]::IsNullOrWhiteSpace($framework)) { continue }
        $match = [regex]::Match([string]$framework, 'net(?<major>\d+)\.\d+', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) { continue }
        $candidate = 0
        if ([int]::TryParse([string]$match.Groups['major'].Value, [ref]$candidate)) {
            if ($candidate -gt $highest) {
                $highest = $candidate
            }
        }
    }
    return $highest
}

function Get-RaymanDotNetSdkMajorFromGlobalJson {
    param([string]$WorkspaceRoot)

    $globalJsonPath = Join-Path $WorkspaceRoot 'global.json'
    if (-not (Test-Path -LiteralPath $globalJsonPath -PathType Leaf)) {
        return 0
    }

    try {
        $json = Get-Content -LiteralPath $globalJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $sdkNode = $json.PSObject.Properties['sdk']
        if ($null -eq $sdkNode -or $null -eq $sdkNode.Value) { return 0 }
        $versionProp = $sdkNode.Value.PSObject.Properties['version']
        if ($null -eq $versionProp -or [string]::IsNullOrWhiteSpace([string]$versionProp.Value)) { return 0 }
        $match = [regex]::Match([string]$versionProp.Value, '^(?<major>\d+)\.')
        if (-not $match.Success) { return 0 }
        return [int]$match.Groups['major'].Value
    } catch {
        return 0
    }
}

function Resolve-RaymanDotNetInstallChannel {
    param([int]$SdkMajor = 0)

    if ($SdkMajor -gt 0) {
        return ("{0}.0" -f $SdkMajor)
    }

    $channel = [string][Environment]::GetEnvironmentVariable('RAYMAN_DOTNET_CHANNEL')
    if ([string]::IsNullOrWhiteSpace($channel)) {
        return 'LTS'
    }
    return $channel.Trim()
}

function Resolve-RaymanDotNetWingetPackageId {
    param([int]$SdkMajor = 0)

    if ($SdkMajor -gt 0) {
        return ("Microsoft.DotNet.SDK.{0}" -f $SdkMajor)
    }

    $channel = [string][Environment]::GetEnvironmentVariable('RAYMAN_DOTNET_CHANNEL')
    if (-not [string]::IsNullOrWhiteSpace($channel)) {
        $match = [regex]::Match($channel.Trim(), '^(?<major>\d+)(?:\.\d+)?$')
        if ($match.Success) {
            return ("Microsoft.DotNet.SDK.{0}" -f [int]$match.Groups['major'].Value)
        }
    }

    return ''
}

function Get-RaymanInstalledDotNetSdkMajors {
    $majors = New-Object 'System.Collections.Generic.List[int]'
    if (-not (Test-Cmd 'dotnet')) {
        return @()
    }

    try {
        $lines = & dotnet --list-sdks 2>$null
    } catch {
        $lines = @()
    }

    foreach ($line in @($lines)) {
        $match = [regex]::Match([string]$line, '^\s*(?<major>\d+)\.')
        if (-not $match.Success) { continue }
        $major = 0
        if ([int]::TryParse([string]$match.Groups['major'].Value, [ref]$major)) {
            if (-not $majors.Contains($major)) {
                $majors.Add($major) | Out-Null
            }
        }
    }

    return @($majors.ToArray() | Sort-Object)
}

function Test-RaymanDotNetSdkReady {
    param([int]$RequiredSdkMajor = 0)

    if (-not (Test-Cmd 'dotnet')) { return $false }
    if ($RequiredSdkMajor -le 0) { return $true }
    return (@(Get-RaymanInstalledDotNetSdkMajors) -contains $RequiredSdkMajor)
}

function Get-RaymanWorkspaceDependencyProfile {
    param(
        [string]$WorkspaceRoot,
        [string]$OnlyKindsText = ''
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $onlyKindsConfig = Resolve-OnlyKinds -OnlyKindsText $OnlyKindsText
    $platformProfile = $null
    if (Get-Command Get-RaymanWorkspacePlatformProfile -ErrorAction SilentlyContinue) {
        try {
            $platformProfile = Get-RaymanWorkspacePlatformProfile -WorkspaceRoot $resolvedRoot
        } catch {
            $platformProfile = $null
        }
    }

    $excludeSegs = @('\.git\', '\.Rayman\', '\.venv\', '\node_modules\', '\bin\', '\obj\')
    function Is-ExcludedPath([string]$FullPath) {
        $p = $FullPath.Replace('/', '\')
        foreach ($seg in $excludeSegs) {
            if ($p -like ('*' + $seg + '*')) { return $true }
        }
        return $false
    }

    $projectFiles = Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File -Include *.sln,*.slnx,*.csproj,*.fsproj,*.vbproj,package.json,pyproject.toml,requirements.txt -ErrorAction SilentlyContinue |
        Where-Object { -not (Is-ExcludedPath -FullPath $_.FullName) }

    $needsDotNet = if ($null -ne $platformProfile) { [bool]$platformProfile.needs_dotnet } else { $false }
    $needsNode = $false
    $needsPython = $false
    $needWindowsDesktop = if ($null -ne $platformProfile) { [bool]$platformProfile.has_windows_desktop_ui } else { $false }
    $requiresWindowsHost = if ($null -ne $platformProfile) { [bool]$platformProfile.requires_windows_host } else { $false }
    $autoEnableWindows = if ($null -ne $platformProfile) { [bool]$platformProfile.auto_enable_windows } else { $false }
    $windowsOnlyDesktopProject = if ($null -ne $platformProfile) { [bool]$platformProfile.is_windows_only_desktop_project } else { $false }
    $allFrameworks = New-Object 'System.Collections.Generic.List[string]'
    $mauiProjects = New-Object 'System.Collections.Generic.List[object]'
    $dotNetProjectPaths = New-Object 'System.Collections.Generic.List[string]'

    function Add-UniqueString {
        param(
            [System.Collections.Generic.List[string]]$List,
            [string]$Value
        )

        if ($null -eq $List) { return }
        if ([string]::IsNullOrWhiteSpace([string]$Value)) { return }
        if (-not $List.Contains([string]$Value)) {
            $List.Add([string]$Value) | Out-Null
        }
    }

    function Add-MauiProjectSignal {
        param(
            [System.Collections.Generic.List[object]]$List,
            [string]$Path,
            [string[]]$Frameworks = @()
        )

        if ($null -eq $List -or [string]::IsNullOrWhiteSpace([string]$Path)) { return }

        $resolvedPath = [string]$Path
        try {
            $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
        } catch {}

        $frameworkList = New-Object 'System.Collections.Generic.List[string]'
        foreach ($framework in @($Frameworks)) {
            if ([string]::IsNullOrWhiteSpace([string]$framework)) { continue }
            if (-not $frameworkList.Contains([string]$framework)) {
                $frameworkList.Add([string]$framework) | Out-Null
            }
        }

        $existing = $null
        foreach ($candidate in @($List.ToArray())) {
            if ($null -eq $candidate) { continue }
            $candidatePath = ''
            if ($candidate.PSObject.Properties['Path']) {
                $candidatePath = [string]$candidate.Path
            }
            if ($candidate.PSObject.Properties['path']) {
                $candidatePath = [string]$candidate.path
            }
            if ([string]::IsNullOrWhiteSpace($candidatePath)) { continue }
            if ($candidatePath.Equals($resolvedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                $existing = $candidate
                break
            }
        }

        if ($null -eq $existing) {
            $List.Add([pscustomobject]@{
                Path = $resolvedPath
                TargetFrameworks = @($frameworkList.ToArray())
            }) | Out-Null
            return
        }

        $existingFrameworks = New-Object 'System.Collections.Generic.List[string]'
        foreach ($framework in @($existing.TargetFrameworks)) {
            if ([string]::IsNullOrWhiteSpace([string]$framework)) { continue }
            if (-not $existingFrameworks.Contains([string]$framework)) {
                $existingFrameworks.Add([string]$framework) | Out-Null
            }
        }
        foreach ($framework in @($frameworkList.ToArray())) {
            if (-not $existingFrameworks.Contains([string]$framework)) {
                $existingFrameworks.Add([string]$framework) | Out-Null
            }
        }
        $existing.TargetFrameworks = @($existingFrameworks.ToArray())
    }

    function Get-PreferredMauiProjectFromList {
        param([object[]]$Projects)

        foreach ($project in @($Projects)) {
            if ($null -eq $project) { continue }
            $frameworks = @()
            if ($project.PSObject.Properties['TargetFrameworks']) {
                $frameworks = @($project.TargetFrameworks)
            }
            foreach ($framework in @($frameworks)) {
                if ([string]::IsNullOrWhiteSpace([string]$framework)) { continue }
                if ([string]$framework -match '-windows') {
                    return $project
                }
            }
        }
        return $(if (@($Projects).Count -gt 0) { @($Projects)[0] } else { $null })
    }

    if ($null -ne $platformProfile) {
        foreach ($framework in @($platformProfile.target_frameworks)) {
            Add-UniqueString -List $allFrameworks -Value ([string]$framework)
        }
        foreach ($projectPath in @($platformProfile.dotnet_project_paths)) {
            Add-UniqueString -List $dotNetProjectPaths -Value ([string]$projectPath)
        }
        foreach ($project in @($platformProfile.maui_projects)) {
            if ($null -eq $project) { continue }
            $projectPath = ''
            if ($project.PSObject.Properties['path']) {
                $projectPath = [string]$project.path
            }
            if ($project.PSObject.Properties['Path']) {
                $projectPath = [string]$project.Path
            }
            if ([string]::IsNullOrWhiteSpace($projectPath)) { continue }
            $frameworks = @()
            if ($project.PSObject.Properties['target_frameworks']) {
                $frameworks = @($project.target_frameworks)
            }
            if ($project.PSObject.Properties['TargetFrameworks']) {
                $frameworks = @($project.TargetFrameworks)
            }
            Add-MauiProjectSignal -List $mauiProjects -Path $projectPath -Frameworks @($frameworks)
        }
    }

    foreach ($f in $projectFiles) {
        switch -Regex ($f.Name) {
            '\.(sln|slnx|csproj|fsproj|vbproj)$' {
                if (-not $needsDotNet) {
                    $needsDotNet = $true
                }
                Add-UniqueString -List $dotNetProjectPaths -Value $f.FullName
                if ($f.Extension -eq '.csproj') {
                    try {
                        $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
                        $frameworks = @(Get-RaymanDotNetTargetFrameworksFromText -ProjectText $raw)
                        foreach ($framework in $frameworks) {
                            Add-UniqueString -List $allFrameworks -Value $framework
                        }
                        $isMaui = $raw -match '<UseMaui>\s*true\s*</UseMaui>'
                        if ($raw -match '<UseWPF>\s*true\s*</UseWPF>' -or $raw -match '<UseWindowsForms>\s*true\s*</UseWindowsForms>') {
                            $needWindowsDesktop = $true
                            $requiresWindowsHost = $true
                            $autoEnableWindows = $true
                        }
                        if ($isMaui) {
                            $needWindowsDesktop = $true
                            $requiresWindowsHost = $true
                            $autoEnableWindows = $true
                            Add-MauiProjectSignal -List $mauiProjects -Path $f.FullName -Frameworks @($frameworks)
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

    $requiredSdkMajor = Get-RaymanDotNetSdkMajorFromGlobalJson -WorkspaceRoot $resolvedRoot
    if ($requiredSdkMajor -le 0) {
        $requiredSdkMajor = Get-RaymanDotNetSdkMajorFromFrameworks -Frameworks @($allFrameworks.ToArray())
    }

    $preferredMauiProject = Get-PreferredMauiProjectFromList -Projects @($mauiProjects.ToArray())

    return [pscustomobject]@{
        WorkspaceRoot = $resolvedRoot
        NeedsDotNet = $needsDotNet
        NeedsNode = $needsNode
        NeedsPython = $needsPython
        NeedWindowsDesktop = $needWindowsDesktop
        RequiresWindowsHost = $requiresWindowsHost
        AutoEnableWindows = $autoEnableWindows
        WindowsOnlyDesktopProject = $windowsOnlyDesktopProject
        IsMaui = ($mauiProjects.Count -gt 0)
        MauiProjects = @($mauiProjects.ToArray())
        PreferredMauiProject = $preferredMauiProject
        DotNetProjectPaths = @($dotNetProjectPaths.ToArray())
        TargetFrameworks = @($allFrameworks.ToArray())
        PlatformProfile = $platformProfile
        RequiredSdkMajor = $requiredSdkMajor
        DotNetInstallChannel = Resolve-RaymanDotNetInstallChannel -SdkMajor $requiredSdkMajor
        DotNetWingetPackageId = Resolve-RaymanDotNetWingetPackageId -SdkMajor $requiredSdkMajor
        OnlyKinds = $onlyKindsConfig
    }
}

function Select-RaymanMauiTargetFramework {
    param(
        [string[]]$Frameworks,
        [ValidateSet('windows', 'maccatalyst', 'android')]
        [string]$PreferredPlatform = 'windows'
    )

    $frameworkList = @($Frameworks | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($frameworkList.Count -eq 0) {
        return ''
    }

    foreach ($framework in $frameworkList) {
        if ($framework -match ('-{0}' -f [regex]::Escape($PreferredPlatform))) {
            return $framework
        }
    }

    return [string]$frameworkList[0]
}

function Install-WithWinget([string]$Id) {
    if ([string]::IsNullOrWhiteSpace($Id)) {
        return $false
    }
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

function Install-DotNetLocal([bool]$NeedWindowsDesktop, [int]$SdkMajor = 0) {
    $channel = Resolve-RaymanDotNetInstallChannel -SdkMajor $SdkMajor

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

function Invoke-RaymanDotNetWorkloadRestore {
    param(
        [object[]]$MauiProjects,
        [bool]$Require
    )

    if ($null -eq $MauiProjects -or @($MauiProjects).Count -eq 0) {
        return $true
    }
    if (-not (Test-Cmd 'dotnet')) {
        return $false
    }

    $failures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($project in @($MauiProjects)) {
        if ($null -eq $project) { continue }
        $projectPath = [string]$project.Path
        if ([string]::IsNullOrWhiteSpace($projectPath)) { continue }

        Info ("restoring MAUI workloads for {0}" -f $projectPath)
        & dotnet workload restore $projectPath | Out-Host
        $exitCode = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }
        if ($exitCode -ne 0) {
            $failures.Add($projectPath) | Out-Null
        }
    }

    if ($failures.Count -eq 0) {
        return $true
    }

    $msg = "failed to restore MAUI workloads: {0}" -f ($failures -join ', ')
    if ($Require) {
        Fail $msg
    } else {
        Warn $msg
    }
    return $false
}

function Invoke-RaymanEnsureProjectTestDeps {
    param(
        [string]$WorkspaceRoot,
        [object]$AutoInstall,
        [object]$Require,
        [string]$OnlyKinds,
        [string]$Caller,
        [string]$CallerHostType,
        [string]$CallerWorkspaceRoot
    )

    $resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $autoInstallEnabled = Convert-ToBoolCompat -Value $AutoInstall -Default $true
    $requireEnabled = Convert-ToBoolCompat -Value $Require -Default $true
    $onlyKindsConfig = Resolve-OnlyKinds -OnlyKindsText $OnlyKinds

    Set-Location $resolvedWorkspaceRoot
    Refresh-ProcessPathFromRegistryBestEffort
    Ensure-WindowsAppsInPathBestEffort
    Add-ToolPathHintsBestEffort

    $hostType = Get-HostTypeLabel
    $callerLabel = if ([string]::IsNullOrWhiteSpace($Caller)) { 'direct' } else { $Caller }
    $callerHostLabel = if ([string]::IsNullOrWhiteSpace($CallerHostType)) { 'unknown' } else { $CallerHostType }
    $callerWorkspaceLabel = if ([string]::IsNullOrWhiteSpace($CallerWorkspaceRoot)) { '(not provided)' } else { $CallerWorkspaceRoot }
    Info ("context caller={0}, callerHost={1}, scriptHost={2}, workspace={3}, callerWorkspace={4}, onlyKinds={5}" -f $callerLabel, $callerHostLabel, $hostType, $resolvedWorkspaceRoot, $callerWorkspaceLabel, [string]$onlyKindsConfig.Raw)

    $profile = Get-RaymanWorkspaceDependencyProfile -WorkspaceRoot $resolvedWorkspaceRoot -OnlyKindsText $OnlyKinds
    Info ("detected deps: dotnet={0}, node={1}, python={2}, windowsDesktop={3}, maui={4}, sdkMajor={5}" -f $profile.NeedsDotNet, $profile.NeedsNode, $profile.NeedsPython, $profile.NeedWindowsDesktop, $profile.IsMaui, $profile.RequiredSdkMajor)

    $missing = New-Object System.Collections.Generic.List[string]

    if ($profile.NeedsDotNet) {
        $dotnetReady = Test-RaymanDotNetSdkReady -RequiredSdkMajor $profile.RequiredSdkMajor
        if (-not $dotnetReady -and (Test-Cmd 'dotnet') -and $profile.RequiredSdkMajor -gt 0) {
            Warn ("dotnet is present but SDK {0} is missing; installed majors={1}" -f $profile.RequiredSdkMajor, ((@(Get-RaymanInstalledDotNetSdkMajors) | ForEach-Object { [string]$_ }) -join ','))
        }

        if (-not $dotnetReady) {
            if ($autoInstallEnabled) {
                Warn "dotnet missing or required SDK unavailable; trying auto install"
                $wingetPackageId = [string]$profile.DotNetWingetPackageId
                if (-not [string]::IsNullOrWhiteSpace($wingetPackageId)) {
                    $null = Install-WithWinget -Id $wingetPackageId
                }
                if (-not (Test-RaymanDotNetSdkReady -RequiredSdkMajor $profile.RequiredSdkMajor)) {
                    Warn 'winget install dotnet failed/unavailable; fallback to dotnet-install.ps1'
                    try { Install-DotNetLocal -NeedWindowsDesktop:$profile.NeedWindowsDesktop -SdkMajor $profile.RequiredSdkMajor } catch { Warn ("dotnet-install fallback failed: {0}" -f $_.Exception.Message) }
                }
            }
            if (-not (Test-RaymanDotNetSdkReady -RequiredSdkMajor $profile.RequiredSdkMajor)) {
                $missingLabel = if ($profile.RequiredSdkMajor -gt 0) { "dotnet-sdk-$($profile.RequiredSdkMajor)" } else { 'dotnet' }
                [void]$missing.Add($missingLabel)
            }
        }
    }

    if ($profile.NeedsNode -and -not (Test-Cmd 'node')) {
        if ($autoInstallEnabled) {
            Warn "node missing; trying auto install via winget"
            $null = Install-WithWinget -Id 'OpenJS.NodeJS.LTS'
        }
        if (-not (Test-Cmd 'node')) { [void]$missing.Add('node') }
    }

    if ($profile.NeedsPython -and -not (Test-PythonCmd)) {
        if ($autoInstallEnabled) {
            Warn "python missing; trying auto install via winget"
            $null = Install-WithWinget -Id 'Python.Python.3.12'
        }
        if (-not (Test-PythonCmd)) { [void]$missing.Add('python') }
    }

    if ($missing.Count -gt 0) {
        $msg = "missing required test dependencies: {0}" -f ($missing -join ', ')
        if ($requireEnabled) {
            Fail $msg
            return 2
        }

        Warn $msg
        return 0
    }

    if ($profile.NeedsDotNet -and $profile.IsMaui -and $autoInstallEnabled) {
        $workloadRestoreOk = Invoke-RaymanDotNetWorkloadRestore -MauiProjects $profile.MauiProjects -Require $requireEnabled
        if (-not $workloadRestoreOk -and $requireEnabled) {
            return 2
        }
    }

    Info 'test dependencies ready'
    return 0
}

if (-not $NoMain) {
    $exitCode = Invoke-RaymanEnsureProjectTestDeps `
        -WorkspaceRoot $WorkspaceRoot `
        -AutoInstall $AutoInstall `
        -Require $Require `
        -OnlyKinds $OnlyKinds `
        -Caller $Caller `
        -CallerHostType $CallerHostType `
        -CallerWorkspaceRoot $CallerWorkspaceRoot
    exit $exitCode
}
