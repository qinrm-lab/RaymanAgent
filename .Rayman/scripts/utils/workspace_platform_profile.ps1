param(
    [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
    [switch]$Json,
    [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RaymanWorkspacePlatformTextValue {
    param(
        [object]$Object,
        [string]$Name,
        [string]$Default = ''
    )

    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Name)) { return $Default }
    try {
        $prop = $Object.PSObject.Properties[$Name]
        if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
        return [string]$prop.Value
    } catch {
        return $Default
    }
}

function Get-RaymanWorkspacePlatformTargetFrameworksFromText {
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

function Get-RaymanWorkspacePlatformProjectSignals {
    param(
        [string]$ProjectPath,
        [string]$ProjectText
    )

    $frameworks = @(Get-RaymanWorkspacePlatformTargetFrameworksFromText -ProjectText $ProjectText)
    $lower = if ([string]::IsNullOrWhiteSpace($ProjectText)) { '' } else { $ProjectText.ToLowerInvariant() }

    $usesMaui = ($lower -match '<usemaui>\s*true\s*</usemaui>')
    $usesWpf = ($lower -match '<usewpf>\s*true\s*</usewpf>')
    $usesWinForms = ($lower -match '<usewindowsforms>\s*true\s*</usewindowsforms>')
    $usesWinUi = ($lower -match '<usewinui>\s*true\s*</usewinui>') -or
        $lower.Contains('microsoft.ui.xaml') -or
        $lower.Contains('winuiex')
    $usesWindowsAppSdk = $lower.Contains('microsoft.windowsappsdk') -or
        $lower.Contains('windowsappsdkselfcontained') -or
        $lower.Contains('windowsappsdkdeploymentmanager') -or
        $lower.Contains('package.appxmanifest')

    $hasWindowsTarget = $false
    $hasNonWindowsTarget = $false
    foreach ($framework in @($frameworks)) {
        if ([string]::IsNullOrWhiteSpace($framework)) { continue }
        if ($framework -match '-windows') {
            $hasWindowsTarget = $true
        } else {
            $hasNonWindowsTarget = $true
        }
    }

    $hasWindowsDesktopUi = $usesMaui -or $usesWpf -or $usesWinForms -or $usesWinUi -or $usesWindowsAppSdk
    $requiresWindowsHost = $hasWindowsDesktopUi -or $hasWindowsTarget
    $isWindowsOnlyDesktopProject = $usesWpf -or
        $usesWinForms -or
        $usesWinUi -or
        $usesWindowsAppSdk -or
        ($hasWindowsTarget -and -not $hasNonWindowsTarget)

    return [pscustomobject]@{
        path = $ProjectPath
        target_frameworks = @($frameworks)
        use_maui = $usesMaui
        use_wpf = $usesWpf
        use_windows_forms = $usesWinForms
        use_winui = $usesWinUi
        use_windows_app_sdk = $usesWindowsAppSdk
        has_windows_target = $hasWindowsTarget
        has_non_windows_target = $hasNonWindowsTarget
        has_windows_desktop_ui = $hasWindowsDesktopUi
        requires_windows_host = $requiresWindowsHost
        is_windows_only_desktop_project = $isWindowsOnlyDesktopProject
    }
}

function Get-RaymanWorkspacePlatformProfile {
    param([string]$WorkspaceRoot)

    $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $excludeSegs = @('\.git\', '\.Rayman\', '\.venv\', '\node_modules\', '\bin\', '\obj\')
    function Is-ExcludedPlatformPath([string]$FullPath) {
        $p = $FullPath.Replace('/', '\')
        foreach ($seg in $excludeSegs) {
            if ($p -like ('*' + $seg + '*')) { return $true }
        }
        return $false
    }

    $projectFiles = @(Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File -Include *.sln,*.slnx,*.csproj,*.fsproj,*.vbproj -ErrorAction SilentlyContinue |
        Where-Object { -not (Is-ExcludedPlatformPath -FullPath $_.FullName) })

    $dotNetProjectPaths = New-Object 'System.Collections.Generic.List[string]'
    $targetFrameworks = New-Object 'System.Collections.Generic.List[string]'
    $projects = New-Object 'System.Collections.Generic.List[object]'
    $windowsProjectPaths = New-Object 'System.Collections.Generic.List[string]'
    $mauiProjects = New-Object 'System.Collections.Generic.List[object]'

    $needsDotNet = $false
    $hasWindowsTargeting = $false
    $hasWindowsDesktopUi = $false
    $requiresWindowsHost = $false
    $windowsOnlyDesktopProject = $false

    foreach ($file in $projectFiles) {
        $needsDotNet = $true
        if (-not $dotNetProjectPaths.Contains($file.FullName)) {
            $dotNetProjectPaths.Add($file.FullName) | Out-Null
        }

        $raw = ''
        if ($file.Extension -in @('.csproj', '.fsproj', '.vbproj')) {
            try {
                $raw = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
            } catch {
                $raw = ''
            }
        }

        $signals = Get-RaymanWorkspacePlatformProjectSignals -ProjectPath $file.FullName -ProjectText $raw
        $projects.Add($signals) | Out-Null

        foreach ($framework in @($signals.target_frameworks)) {
            if ([string]::IsNullOrWhiteSpace([string]$framework)) { continue }
            if (-not $targetFrameworks.Contains([string]$framework)) {
                $targetFrameworks.Add([string]$framework) | Out-Null
            }
        }

        if ([bool]$signals.has_windows_target -or [bool]$signals.has_windows_desktop_ui) {
            $hasWindowsTargeting = $true
            if (-not $windowsProjectPaths.Contains($file.FullName)) {
                $windowsProjectPaths.Add($file.FullName) | Out-Null
            }
        }
        if ([bool]$signals.has_windows_desktop_ui) {
            $hasWindowsDesktopUi = $true
        }
        if ([bool]$signals.requires_windows_host) {
            $requiresWindowsHost = $true
        }
        if ([bool]$signals.is_windows_only_desktop_project) {
            $windowsOnlyDesktopProject = $true
        }
        if ([bool]$signals.use_maui) {
            $mauiProjects.Add($signals) | Out-Null
        }
    }

    return [pscustomobject]@{
        schema = 'rayman.workspace_platform_profile.v1'
        workspace_root = $resolvedRoot
        needs_dotnet = $needsDotNet
        has_windows_targeting = $hasWindowsTargeting
        has_windows_desktop_ui = $hasWindowsDesktopUi
        requires_windows_host = $requiresWindowsHost
        allows_windows_dotnet_bridge = $requiresWindowsHost
        auto_enable_windows = $requiresWindowsHost
        is_windows_only_desktop_project = $windowsOnlyDesktopProject
        dotnet_project_paths = @($dotNetProjectPaths.ToArray())
        target_frameworks = @($targetFrameworks.ToArray())
        windows_project_paths = @($windowsProjectPaths.ToArray())
        maui_projects = @($mauiProjects.ToArray())
        projects = @($projects.ToArray())
        primary_windows_project = if ($windowsProjectPaths.Count -gt 0) { [string]$windowsProjectPaths[0] } else { '' }
        summary = if ($requiresWindowsHost) { 'windows_host_required' } elseif ($needsDotNet) { 'dotnet_workspace' } else { 'no_dotnet_projects' }
    }
}

if (-not $NoMain) {
    $WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $profile = Get-RaymanWorkspacePlatformProfile -WorkspaceRoot $WorkspaceRoot
    if ($Json) {
        $profile | ConvertTo-Json -Depth 8
    } else {
        Write-Host ("workspace={0}" -f $profile.workspace_root)
        Write-Host ("summary={0}" -f $profile.summary)
        Write-Host ("requires_windows_host={0}" -f [string]([bool]$profile.requires_windows_host).ToString().ToLowerInvariant())
        Write-Host ("auto_enable_windows={0}" -f [string]([bool]$profile.auto_enable_windows).ToString().ToLowerInvariant())
        Write-Host ("has_windows_desktop_ui={0}" -f [string]([bool]$profile.has_windows_desktop_ui).ToString().ToLowerInvariant())
    }
}
