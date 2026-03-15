param(
    [string]$WorkspaceRoot = $(Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path,
    [switch]$NoMain
)

$ErrorActionPreference = 'Stop'

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
    if (-not $NoMain) {
        throw "common.ps1 not found: $commonPath"
    }
} else {
    . $commonPath
}

# 导入核心模块
$CoreModulePath = Join-Path $PSScriptRoot "..\core\Rayman-Core.psm1"
if (Test-Path $CoreModulePath) {
    Import-Module $CoreModulePath -Force
}

$DotNetDepsHelperPath = Join-Path $PSScriptRoot '..\utils\ensure_project_test_deps.ps1'
if (Test-Path $DotNetDepsHelperPath) {
    . $DotNetDepsHelperPath -NoMain
}

$WorkspaceProcessOwnershipPath = Join-Path $PSScriptRoot '..\utils\workspace_process_ownership.ps1'
if (Test-Path $WorkspaceProcessOwnershipPath) {
    . $WorkspaceProcessOwnershipPath -NoMain
}

function Get-EnvInt([string]$Name, [int]$Default) {
    $raw = [Environment]::GetEnvironmentVariable($Name)
    $val = 0
    if (-not [string]::IsNullOrWhiteSpace($raw) -and [int]::TryParse($raw, [ref]$val)) { return $val }
    return $Default
}

function Get-EnvString([string]$Name, [string]$Default) {
    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    return $raw
}

function Get-EnvBoolCompat([string]$Name, [bool]$Default) {
    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    return ($raw -ne '0' -and $raw -ne 'false' -and $raw -ne 'False')
}

function Set-LastExitCodeCompat([int]$Value) {
    try { Set-Variable -Name 'LASTEXITCODE' -Scope Global -Value $Value -Force } catch {}
    try { Set-Variable -Name 'LASTEXITCODE' -Scope Script -Value $Value -Force } catch {}
}

function Test-IsWindowsPlatformCompat {
    try {
        return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    } catch {
        return $false
    }
}

function Test-IsMacOSPlatformCompat {
    try {
        return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)
    } catch {
        return $false
    }
}

function ConvertTo-PsSingleQuotedLiteral([string]$Value) {
    if ($null -eq $Value) { return '' }
    return $Value.Replace("'", "''")
}

function New-RaymanDotNetPidFilePath {
    param(
        [string]$Prefix = 'dotnet.host'
    )

    $runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime'
    if (-not (Test-Path -LiteralPath $runtimeDir)) {
        New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
    }
    return (Join-Path $runtimeDir ("{0}.{1}.pid" -f $Prefix, [Guid]::NewGuid().ToString('N')))
}

function Wait-RaymanDotNetRootPid {
    param(
        [string]$PidFilePath,
        [int]$TimeoutMilliseconds = 5000
    )

    if ([string]::IsNullOrWhiteSpace($PidFilePath)) { return 0 }

    $deadline = (Get-Date).AddMilliseconds([Math]::Max(200, $TimeoutMilliseconds))
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $PidFilePath -PathType Leaf) {
            try {
                $raw = (Get-Content -LiteralPath $PidFilePath -Raw -Encoding ASCII).Trim()
                $parsed = 0
                if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -gt 0) {
                    return $parsed
                }
            } catch {}
        }
        Start-Sleep -Milliseconds 100
    }

    return 0
}

function New-RaymanDotNetHostCommand {
    param(
        [string]$WorkspacePath,
        [string]$Command,
        [string]$PidFilePath
    )

    $workspaceEscaped = ConvertTo-PsSingleQuotedLiteral -Value $WorkspacePath
    $commandEscaped = ConvertTo-PsSingleQuotedLiteral -Value $Command
    $pidFileEscaped = ConvertTo-PsSingleQuotedLiteral -Value $PidFilePath

    $template = @'
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
Set-Location '__WORKSPACE__'
Set-Content -LiteralPath '__PIDFILE__' -Value $PID -Encoding ASCII
$requested = '__COMMAND__'
$effective = $requested
if ($requested -match '^\s*dotnet(\s+.*)?$') {
  $suffix = if ($matches[1]) { $matches[1] } else { '' }
  $candidate = '.\.dotnet\dotnet.exe'
  if (Test-Path -LiteralPath $candidate -PathType Leaf) {
    $effective = $candidate + $suffix
  }
}
Write-Output ('[dotnet-host][windows] pid={0}' -f $PID)
Write-Output ('[dotnet-host][windows] requested={0}' -f $requested)
Write-Output ('[dotnet-host][windows] effective={0}' -f $effective)
Invoke-Expression $effective
exit $LASTEXITCODE
'@

    return $template.Replace('__WORKSPACE__', $workspaceEscaped).Replace('__PIDFILE__', $pidFileEscaped).Replace('__COMMAND__', $commandEscaped)
}

function Resolve-DotNetWindowsBridge {
    param([string]$WorkspaceRoot)

    $result = [ordered]@{
        available = $false
        reason = ''
        powershell_path = ''
        workspace_windows = ''
    }

    if (Test-IsWindowsPlatformCompat) {
        $result.reason = 'already_windows_host'
        return [pscustomobject]$result
    }

    $psExe = Get-Command 'powershell.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $psExe -or [string]::IsNullOrWhiteSpace([string]$psExe.Source)) {
        $result.reason = 'powershell.exe_not_found'
        return [pscustomobject]$result
    }

    $wslPathCmd = Get-Command 'wslpath' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $wslPathCmd -or [string]::IsNullOrWhiteSpace([string]$wslPathCmd.Source)) {
        $result.reason = 'wslpath_not_found'
        return [pscustomobject]$result
    }

    if ($WorkspaceRoot -notmatch '^/mnt/[A-Za-z]/') {
        $result.reason = 'workspace_not_on_windows_drive'
        return [pscustomobject]$result
    }

    $workspaceWin = ''
    try {
        $workspaceWin = (& $wslPathCmd.Source -w $WorkspaceRoot | Select-Object -First 1)
        $workspaceWin = [string]$workspaceWin
    } catch {
        $workspaceWin = ''
    }
    if ([string]::IsNullOrWhiteSpace($workspaceWin)) {
        $result.reason = 'workspace_wslpath_conversion_failed'
        return [pscustomobject]$result
    }

    $result.available = $true
    $result.reason = 'ok'
    $result.powershell_path = [string]$psExe.Source
    $result.workspace_windows = $workspaceWin.Trim()
    return [pscustomobject]$result
}

function Test-CanUseWindowsDotNetFromCurrentHost([object]$BridgeContext) {
    if ($null -eq $BridgeContext) { return $false }
    if (-not $BridgeContext.PSObject.Properties['available']) { return $false }
    return [bool]$BridgeContext.available
}

function Write-DotNetExecDetail {
    param(
        [string]$LogPath,
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($LogPath)) { return }
    try {
        $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message
        Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value $line
    } catch {}
}

function Save-DotNetExecSummary {
    param(
        [string]$SummaryPath,
        [hashtable]$Summary
    )

    if ([string]::IsNullOrWhiteSpace($SummaryPath) -or $null -eq $Summary) { return }
    try {
        ($Summary | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $SummaryPath -Encoding UTF8
    } catch {}
}

function Resolve-RaymanOwnedProcessRegistration {
    param(
        [string]$WorkspaceRootPath,
        [string]$OwnedKind,
        [string]$OwnedLauncher,
        [string]$OwnedCommand,
        [string]$OwnedPidFile = '',
        [string]$OwnedOwnerPid = '',
        [string]$OwnedCommandLineNeedle = '',
        [int]$FallbackProcessId = 0,
        [object]$ExistingOwnerContext = $null,
        [object]$ExistingRecord = $null
    )

    $rootPid = 0
    if ($null -ne $ExistingRecord -and $ExistingRecord.PSObject.Properties['root_pid']) {
        try { $rootPid = [int]$ExistingRecord.root_pid } catch { $rootPid = 0 }
    }

    if ($rootPid -le 0) {
        $rootPid = Wait-RaymanDotNetRootPid -PidFilePath $OwnedPidFile -TimeoutMilliseconds 5000
    }
    if ($rootPid -le 0 -and -not [string]::IsNullOrWhiteSpace($OwnedCommandLineNeedle) -and (Get-Command Find-RaymanOwnedWindowsProcessIdsByCommandLineNeedle -ErrorAction SilentlyContinue)) {
        $candidatePids = @(Find-RaymanOwnedWindowsProcessIdsByCommandLineNeedle -WorkspaceRootPath $WorkspaceRootPath -Needle $OwnedCommandLineNeedle -ProcessNames @('powershell.exe', 'pwsh.exe'))
        if ($candidatePids.Count -gt 0) {
            $rootPid = [int]$candidatePids[0]
        }
    }
    if ($rootPid -le 0 -and (Test-IsWindowsPlatformCompat) -and $FallbackProcessId -gt 0) {
        $rootPid = $FallbackProcessId
    }

    $ownerContext = $ExistingOwnerContext
    if ($rootPid -gt 0 -and $null -eq $ownerContext -and (Get-Command Get-RaymanWorkspaceProcessOwnerContext -ErrorAction SilentlyContinue)) {
        $ownerContext = Get-RaymanWorkspaceProcessOwnerContext -WorkspaceRootPath $WorkspaceRootPath -ExplicitOwnerPid $OwnedOwnerPid
    }

    $record = $ExistingRecord
    if ($rootPid -gt 0 -and $null -eq $record -and (Get-Command Register-RaymanWorkspaceOwnedProcess -ErrorAction SilentlyContinue)) {
        $record = Register-RaymanWorkspaceOwnedProcess -WorkspaceRootPath $WorkspaceRootPath -OwnerContext $ownerContext -Kind $OwnedKind -Launcher $OwnedLauncher -RootPid $rootPid -Command $OwnedCommand
    }
    if ($rootPid -gt 0 -and $null -eq $record) {
        $record = [pscustomobject]@{
            workspace_root = $WorkspaceRootPath
            owner_key = if ($null -ne $ownerContext) { [string]$ownerContext.owner_key } else { '' }
            owner_display = if ($null -ne $ownerContext) { [string]$ownerContext.owner_display } else { '' }
            kind = $OwnedKind
            launcher = $OwnedLauncher
            root_pid = $rootPid
            started_at = ''
            command = $OwnedCommand
            state = 'running'
        }
    }

    return [pscustomobject]@{
        root_pid = $rootPid
        owner_context = $ownerContext
        record = $record
    }
}

function Invoke-ProcessWithTimeout {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [int]$TimeoutSeconds,
        [string]$WorkspaceRootPath = '',
        [string]$OwnedKind = '',
        [string]$OwnedLauncher = '',
        [string]$OwnedCommand = '',
        [string]$OwnedPidFile = '',
        [string]$OwnedOwnerPid = '',
        [string]$OwnedCommandLineNeedle = ''
    )

    $result = [ordered]@{
        exit_code = 1
        timed_out = $false
        output_lines = @()
        error_message = ''
        owned_root_pid = $null
        owner_display = ''
        cleanup_attempted = $false
        cleanup_result = ''
        cleanup_reason = ''
        cleanup_pids = @()
    }

    $stdoutPath = ''
    $stderrPath = ''
    $proc = $null
    $ownedOwnerContext = $null
    $ownedRecord = $null
    $ownedRootPid = 0
    $shouldTrackOwnedProcess = $false

    function Set-CleanupFields([hashtable]$Target, [object]$Cleanup) {
        if ($null -eq $Cleanup) { return }
        $Target.cleanup_attempted = $true
        $Target.cleanup_result = [string]$Cleanup.cleanup_result
        $Target.cleanup_reason = [string]$Cleanup.cleanup_reason
        $Target.cleanup_pids = @($Cleanup.cleanup_pids)
    }

    try {
        $stdoutPath = [System.IO.Path]::GetTempFileName()
        $stderrPath = [System.IO.Path]::GetTempFileName()

        $proc = Start-Process -FilePath $FilePath `
            -ArgumentList @($ArgumentList) `
            -PassThru `
            -NoNewWindow `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath

        $shouldTrackOwnedProcess = (
            -not [string]::IsNullOrWhiteSpace($WorkspaceRootPath) -and
            -not [string]::IsNullOrWhiteSpace($OwnedKind) -and
            -not [string]::IsNullOrWhiteSpace($OwnedLauncher) -and
            (Get-Command Register-RaymanWorkspaceOwnedProcess -ErrorAction SilentlyContinue) -and
            (Get-Command Get-RaymanWorkspaceProcessOwnerContext -ErrorAction SilentlyContinue)
        )
        if ($shouldTrackOwnedProcess) {
            $resolvedOwned = Resolve-RaymanOwnedProcessRegistration -WorkspaceRootPath $WorkspaceRootPath -OwnedKind $OwnedKind -OwnedLauncher $OwnedLauncher -OwnedCommand $OwnedCommand -OwnedPidFile $OwnedPidFile -OwnedOwnerPid $OwnedOwnerPid -OwnedCommandLineNeedle $OwnedCommandLineNeedle -FallbackProcessId ([int]$proc.Id)
            $ownedRootPid = [int]$resolvedOwned.root_pid
            $ownedOwnerContext = $resolvedOwned.owner_context
            $ownedRecord = $resolvedOwned.record
            if ($ownedRootPid -gt 0) {
                $result.owned_root_pid = $ownedRootPid
                if ($null -ne $ownedOwnerContext) {
                    $result.owner_display = [string]$ownedOwnerContext.owner_display
                }
            }
        }

        if ($TimeoutSeconds -gt 0) {
            $waited = $proc.WaitForExit($TimeoutSeconds * 1000)
            if (-not $waited) {
                $result.timed_out = $true
                if ($null -eq $ownedRecord -and $shouldTrackOwnedProcess) {
                    $resolvedOwned = Resolve-RaymanOwnedProcessRegistration -WorkspaceRootPath $WorkspaceRootPath -OwnedKind $OwnedKind -OwnedLauncher $OwnedLauncher -OwnedCommand $OwnedCommand -OwnedPidFile $OwnedPidFile -OwnedOwnerPid $OwnedOwnerPid -OwnedCommandLineNeedle $OwnedCommandLineNeedle -FallbackProcessId ([int]$proc.Id) -ExistingOwnerContext $ownedOwnerContext -ExistingRecord $ownedRecord
                    $ownedRootPid = [int]$resolvedOwned.root_pid
                    $ownedOwnerContext = $resolvedOwned.owner_context
                    $ownedRecord = $resolvedOwned.record
                    if ($ownedRootPid -gt 0) {
                        $result.owned_root_pid = $ownedRootPid
                    }
                    if ($null -ne $ownedOwnerContext) {
                        $result.owner_display = [string]$ownedOwnerContext.owner_display
                    }
                }
                if ($null -ne $ownedRecord -and (Get-Command Stop-RaymanWorkspaceOwnedProcess -ErrorAction SilentlyContinue)) {
                    $cleanup = Stop-RaymanWorkspaceOwnedProcess -WorkspaceRootPath $WorkspaceRootPath -Record $ownedRecord -Reason 'timeout'
                    Set-CleanupFields -Target $result -Cleanup $cleanup
                }
                try { $proc.Kill() } catch {}
                try { $proc.WaitForExit() } catch {}
                $result.exit_code = 124
            } else {
                $result.exit_code = [int]$proc.ExitCode
            }
        } else {
            $proc.WaitForExit()
            $result.exit_code = [int]$proc.ExitCode
        }

        if (-not $result.timed_out -and $ownedRootPid -gt 0 -and $null -ne $ownedRecord) {
            $liveTree = @()
            if ((Get-Command Get-RaymanWindowsProcessTreePids -ErrorAction SilentlyContinue) -and (Get-Command Get-RaymanOwnedWindowsProcessDetails -ErrorAction SilentlyContinue)) {
                $treePids = @(Get-RaymanWindowsProcessTreePids -WorkspaceRootPath $WorkspaceRootPath -RootPid $ownedRootPid -IncludeRoot)
                foreach ($treePid in $treePids) {
                    $details = Get-RaymanOwnedWindowsProcessDetails -WorkspaceRootPath $WorkspaceRootPath -ProcessId ([int]$treePid)
                    if ([bool]$details.alive) {
                        $liveTree += [int]$treePid
                    }
                }
            }

            if ($liveTree.Count -gt 0 -and (Get-Command Stop-RaymanWorkspaceOwnedProcess -ErrorAction SilentlyContinue)) {
                $cleanup = Stop-RaymanWorkspaceOwnedProcess -WorkspaceRootPath $WorkspaceRootPath -Record $ownedRecord -Reason 'post_exit_cleanup'
                Set-CleanupFields -Target $result -Cleanup $cleanup
            } elseif (Get-Command Remove-RaymanWorkspaceOwnedProcess -ErrorAction SilentlyContinue) {
                Remove-RaymanWorkspaceOwnedProcess -WorkspaceRootPath $WorkspaceRootPath -RootPid $ownedRootPid
            }
        }

        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($file in @($stdoutPath, $stderrPath)) {
            if ([string]::IsNullOrWhiteSpace($file) -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
            foreach ($line in (Get-Content -LiteralPath $file -Encoding UTF8 -ErrorAction SilentlyContinue)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
                    [void]$lines.Add([string]$line)
                }
            }
        }
        $result.output_lines = @($lines)
    } catch {
        $result.error_message = $_.Exception.Message
        if ($null -eq $ownedRecord -and $shouldTrackOwnedProcess -and $null -ne $proc) {
            $resolvedOwned = Resolve-RaymanOwnedProcessRegistration -WorkspaceRootPath $WorkspaceRootPath -OwnedKind $OwnedKind -OwnedLauncher $OwnedLauncher -OwnedCommand $OwnedCommand -OwnedPidFile $OwnedPidFile -OwnedOwnerPid $OwnedOwnerPid -OwnedCommandLineNeedle $OwnedCommandLineNeedle -FallbackProcessId ([int]$proc.Id) -ExistingOwnerContext $ownedOwnerContext -ExistingRecord $ownedRecord
            $ownedRootPid = [int]$resolvedOwned.root_pid
            $ownedOwnerContext = $resolvedOwned.owner_context
            $ownedRecord = $resolvedOwned.record
            if ($ownedRootPid -gt 0) {
                $result.owned_root_pid = $ownedRootPid
            }
            if ($null -ne $ownedOwnerContext) {
                $result.owner_display = [string]$ownedOwnerContext.owner_display
            }
        }
        if ($null -ne $ownedRecord -and (Get-Command Stop-RaymanWorkspaceOwnedProcess -ErrorAction SilentlyContinue)) {
            $cleanup = Stop-RaymanWorkspaceOwnedProcess -WorkspaceRootPath $WorkspaceRootPath -Record $ownedRecord -Reason 'exception'
            Set-CleanupFields -Target $result -Cleanup $cleanup
        }
        if ($result.exit_code -eq 0) {
            $result.exit_code = 1
        }
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($OwnedPidFile) -and (Test-Path -LiteralPath $OwnedPidFile -PathType Leaf)) {
            try { Remove-Item -LiteralPath $OwnedPidFile -Force -ErrorAction SilentlyContinue } catch {}
        }
        foreach ($tmp in @($stdoutPath, $stderrPath)) {
            if (-not [string]::IsNullOrWhiteSpace($tmp) -and (Test-Path -LiteralPath $tmp -PathType Leaf)) {
                try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
    }

    return [pscustomobject]$result
}

function Invoke-DotNetViaWindowsHost {
    param(
        [string]$Command,
        [object]$BridgeContext,
        [int]$TimeoutSeconds
    )

    $pidFilePath = New-RaymanDotNetPidFilePath -Prefix 'dotnet.bridge'
    $pidFileWindows = Convert-RaymanOwnedPathToWindows -PathValue $pidFilePath
    if ([string]::IsNullOrWhiteSpace($pidFileWindows)) {
        throw "cannot convert bridge pid file path to Windows path: $pidFilePath"
    }

    $winCommand = New-RaymanDotNetHostCommand -WorkspacePath ([string]$BridgeContext.workspace_windows) -Command $Command -PidFilePath $pidFileWindows

    $processResult = Invoke-ProcessWithTimeout -FilePath ([string]$BridgeContext.powershell_path) -ArgumentList @(
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        $winCommand
    ) -TimeoutSeconds $TimeoutSeconds -WorkspaceRootPath $WorkspaceRoot -OwnedKind 'dotnet' -OwnedLauncher 'windows-bridge' -OwnedCommand $Command -OwnedPidFile $pidFilePath -OwnedCommandLineNeedle $pidFileWindows

    return [pscustomobject]@{
        success = (($processResult.exit_code -eq 0) -and (-not $processResult.timed_out))
        exit_code = [int]$processResult.exit_code
        timed_out = [bool]$processResult.timed_out
        output_lines = @($processResult.output_lines)
        error_message = [string]$processResult.error_message
        invoked_via = [string]$BridgeContext.powershell_path
        workspace_windows = [string]$BridgeContext.workspace_windows
        owned_root_pid = $processResult.owned_root_pid
        owner_display = [string]$processResult.owner_display
        cleanup_attempted = [bool]$processResult.cleanup_attempted
        cleanup_result = [string]$processResult.cleanup_result
        cleanup_reason = [string]$processResult.cleanup_reason
        cleanup_pids = @($processResult.cleanup_pids)
    }
}

function Invoke-DotNetViaNativeWindowsHost {
    param(
        [string]$Command,
        [int]$TimeoutSeconds
    )

    $psHost = Resolve-RaymanOwnedWindowsPowerShellPath
    if ([string]::IsNullOrWhiteSpace($psHost)) {
        throw 'cannot resolve a Windows PowerShell host for native dotnet execution.'
    }

    $pidFilePath = New-RaymanDotNetPidFilePath -Prefix 'dotnet.native'
    $pidFileNative = if (Test-IsWindowsPlatformCompat) { $pidFilePath } else { Convert-RaymanOwnedPathToWindows -PathValue $pidFilePath }
    if ([string]::IsNullOrWhiteSpace($pidFileNative)) {
        throw "cannot resolve native pid file path: $pidFilePath"
    }

    $nativeCommand = New-RaymanDotNetHostCommand -WorkspacePath $WorkspaceRoot -Command $Command -PidFilePath $pidFileNative
    $processResult = Invoke-ProcessWithTimeout -FilePath $psHost -ArgumentList @(
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        $nativeCommand
    ) -TimeoutSeconds $TimeoutSeconds -WorkspaceRootPath $WorkspaceRoot -OwnedKind 'dotnet' -OwnedLauncher 'windows-native' -OwnedCommand $Command -OwnedPidFile $pidFilePath -OwnedCommandLineNeedle $pidFileNative

    return [pscustomobject]@{
        success = (($processResult.exit_code -eq 0) -and (-not $processResult.timed_out))
        exit_code = [int]$processResult.exit_code
        timed_out = [bool]$processResult.timed_out
        output_lines = @($processResult.output_lines)
        error_message = [string]$processResult.error_message
        invoked_via = [string]$psHost
        workspace_windows = $WorkspaceRoot
        owned_root_pid = $processResult.owned_root_pid
        owner_display = [string]$processResult.owner_display
        cleanup_attempted = [bool]$processResult.cleanup_attempted
        cleanup_result = [string]$processResult.cleanup_result
        cleanup_reason = [string]$processResult.cleanup_reason
        cleanup_pids = @($processResult.cleanup_pids)
    }
}

function Invoke-RaymanCommand {
    param(
        [string]$Command,
        [bool]$UseSandboxEffective,
        [string]$SandboxScript,
        [string]$Kind = ''
    )

    if ($UseSandboxEffective -and (Test-Path -LiteralPath $SandboxScript -PathType Leaf)) {
        return & $SandboxScript -Command $Command 2>&1
    }

    if ($Kind -ne 'dotnet') {
        return Invoke-Expression $Command 2>&1
    }

    $windowsPreferred = Get-EnvBoolCompat -Name 'RAYMAN_DOTNET_WINDOWS_PREFERRED' -Default $true
    $windowsStrict = Get-EnvBoolCompat -Name 'RAYMAN_DOTNET_WINDOWS_STRICT' -Default $false
    $timeoutSeconds = Get-EnvInt -Name 'RAYMAN_DOTNET_WINDOWS_TIMEOUT_SECONDS' -Default 1800
    if ($timeoutSeconds -lt 30) { $timeoutSeconds = 30 }
    if ($timeoutSeconds -gt 7200) { $timeoutSeconds = 7200 }

    $bridgeContext = Resolve-DotNetWindowsBridge -WorkspaceRoot $WorkspaceRoot
    $canBridge = Test-CanUseWindowsDotNetFromCurrentHost -BridgeContext $bridgeContext
    $isWindowsHost = Test-IsWindowsPlatformCompat

    $summary = [ordered]@{
        schema = 'rayman.dotnet.exec.v1'
        generated_at = (Get-Date).ToString('o')
        workspace_root = $WorkspaceRoot
        requested_command = $Command
        selected_host = ''
        fallback_host = ''
        success = $false
        final_exit_code = 1
        windows_exit_code = $null
        wsl_exit_code = $null
        windows_timed_out = $false
        windows_error_message = ''
        windows_invoked_via = ''
        windows_workspace = ''
        strict_mode = $windowsStrict
        windows_preferred = $windowsPreferred
        timeout_seconds = $timeoutSeconds
        host_is_windows = $isWindowsHost
        can_use_windows_bridge = $canBridge
        bridge_reason = [string]$bridgeContext.reason
        reason = ''
        error_message = ''
        detail_log = $script:DotNetExecDetailPath
        owned_root_pid = $null
        cleanup_attempted = $false
        cleanup_result = ''
        cleanup_reason = ''
        cleanup_pids = @()
    }

    $out = New-Object System.Collections.Generic.List[object]
    $windowsOut = @()
    $finalExit = 1

    Write-DotNetExecDetail -LogPath $script:DotNetExecDetailPath -Message ("dotnet strategy command='{0}' preferred={1} strict={2} hostIsWindows={3} canBridge={4} bridgeReason={5}" -f $Command, $windowsPreferred, $windowsStrict, $isWindowsHost, $canBridge, [string]$bridgeContext.reason)

    if ($isWindowsHost) {
        $summary.selected_host = 'windows-native'
        $native = Invoke-DotNetViaNativeWindowsHost -Command $Command -TimeoutSeconds $timeoutSeconds
        $nativeOut = @($native.output_lines)
        $finalExit = [int]$native.exit_code
        $summary.windows_exit_code = $finalExit
        $summary.windows_timed_out = [bool]$native.timed_out
        $summary.windows_error_message = [string]$native.error_message
        $summary.windows_invoked_via = [string]$native.invoked_via
        $summary.windows_workspace = [string]$native.workspace_windows
        $summary.owned_root_pid = $native.owned_root_pid
        $summary.cleanup_attempted = [bool]$native.cleanup_attempted
        $summary.cleanup_result = [string]$native.cleanup_result
        $summary.cleanup_reason = [string]$native.cleanup_reason
        $summary.cleanup_pids = @($native.cleanup_pids)
        $summary.reason = 'native_windows_host'
        Write-DotNetExecDetail -LogPath $script:DotNetExecDetailPath -Message ("windows native exit={0} timeout={1} rootPid={2} cleanup={3} cleanupReason={4}" -f [int]$native.exit_code, [bool]$native.timed_out, [string]$native.owned_root_pid, [string]$native.cleanup_result, [string]$native.cleanup_reason)
        $out.AddRange(@($nativeOut))
    } elseif (-not $windowsPreferred) {
        $summary.selected_host = 'wsl'
        $wslOut = Invoke-Expression $Command 2>&1
        $finalExit = [int]$LASTEXITCODE
        $summary.wsl_exit_code = $finalExit
        $summary.reason = 'windows_preferred_disabled'
        $out.AddRange(@($wslOut))
    } elseif (-not $canBridge) {
        $summary.selected_host = 'wsl'
        $wslOut = Invoke-Expression $Command 2>&1
        $finalExit = [int]$LASTEXITCODE
        $summary.wsl_exit_code = $finalExit
        $summary.reason = ('windows_bridge_unavailable:{0}' -f [string]$bridgeContext.reason)
        $out.AddRange(@($wslOut))
    } else {
        $summary.selected_host = 'windows-bridge'
        $win = Invoke-DotNetViaWindowsHost -Command $Command -BridgeContext $bridgeContext -TimeoutSeconds $timeoutSeconds
        $windowsOut = @($win.output_lines)
        $summary.windows_exit_code = [int]$win.exit_code
        $summary.windows_timed_out = [bool]$win.timed_out
        $summary.windows_error_message = [string]$win.error_message
        $summary.windows_invoked_via = [string]$win.invoked_via
        $summary.windows_workspace = [string]$win.workspace_windows
        $summary.owned_root_pid = $win.owned_root_pid
        $summary.cleanup_attempted = [bool]$win.cleanup_attempted
        $summary.cleanup_result = [string]$win.cleanup_result
        $summary.cleanup_reason = [string]$win.cleanup_reason
        $summary.cleanup_pids = @($win.cleanup_pids)
        Write-DotNetExecDetail -LogPath $script:DotNetExecDetailPath -Message ("windows bridge exit={0} timeout={1} via={2} rootPid={3} cleanup={4} cleanupReason={5}" -f [int]$win.exit_code, [bool]$win.timed_out, [string]$win.invoked_via, [string]$win.owned_root_pid, [string]$win.cleanup_result, [string]$win.cleanup_reason)
        if ($win.success) {
            $finalExit = [int]$win.exit_code
            $summary.reason = 'windows_bridge_success'
            $out.AddRange(@($windowsOut))
        } elseif ($windowsStrict) {
            $finalExit = [int]$win.exit_code
            $summary.reason = if ($win.timed_out) { 'windows_bridge_timeout_strict' } else { 'windows_bridge_failed_strict' }
            $summary.error_message = if ($win.timed_out) {
                ("windows dotnet execution timed out after {0}s" -f $timeoutSeconds)
            } else {
                [string]$win.error_message
            }
            $out.AddRange(@($windowsOut))
        } else {
            $summary.fallback_host = 'wsl'
            $summary.reason = if ($win.timed_out) { 'windows_bridge_timeout_fallback_wsl' } else { 'windows_bridge_failed_fallback_wsl' }
            $warnLine = "[dotnet-host] windows execution failed (exit=$($win.exit_code)); fallback to WSL command"
            Write-Host "⚠️  $warnLine" -ForegroundColor Yellow
            $out.AddRange(@($windowsOut))
            $out.Add($warnLine) | Out-Null
            $wslOut = Invoke-Expression $Command 2>&1
            $finalExit = [int]$LASTEXITCODE
            $summary.wsl_exit_code = $finalExit
            $out.AddRange(@($wslOut))
        }
    }

    Set-LastExitCodeCompat -Value $finalExit
    $summary.success = ($finalExit -eq 0)
    $summary.final_exit_code = $finalExit
    Save-DotNetExecSummary -SummaryPath $script:DotNetExecSummaryPath -Summary $summary
    Write-DotNetExecDetail -LogPath $script:DotNetExecDetailPath -Message ("dotnet strategy result selected={0} fallback={1} final_exit={2} windows_exit={3} wsl_exit={4} reason={5}" -f [string]$summary.selected_host, [string]$summary.fallback_host, $finalExit, [string]$summary.windows_exit_code, [string]$summary.wsl_exit_code, [string]$summary.reason)

    return $out.ToArray()
}

function Get-FileRefsFromLines {
    param([string[]]$Lines)

    $exts = 'cs|csproj|sln|slnx|ts|tsx|js|jsx|py|ps1|sh|json|yml|yaml|md'
    $patterns = @(
        "(?<path>[A-Za-z]:\\\\[^:\r\n]+?\\.(?:$exts))(?::(?<line>\d+))?",
        "(?<path>(?:\./|\.\./|\.\\|\.\\\\|[^\s:]+/)[^:\r\n]+?\\.(?:$exts))(?::(?<line>\d+))?"
    )

    $found = New-Object System.Collections.Generic.List[string]
    foreach ($ln in $Lines) {
        foreach ($pat in $patterns) {
            $m = [regex]::Matches($ln, $pat)
            foreach ($mm in $m) {
                $p = $mm.Groups['path'].Value
                $l = $mm.Groups['line'].Value
                if (-not [string]::IsNullOrWhiteSpace($p)) {
                    if (-not [string]::IsNullOrWhiteSpace($l)) { $found.Add("$p`:$l") } else { $found.Add($p) }
                }
            }
        }
    }
    return $found | Select-Object -Unique
}

if (-not $NoMain) {

# 1. 触发成本熔断器检查 (每次运行算作 1 次循环)
$CircuitBreakerScript = Join-Path $WorkspaceRoot ".Rayman\scripts\utils\circuit_breaker.ps1"
if (Test-Path $CircuitBreakerScript) {
    Write-Host "🛡️ [Circuit Breaker] 检查执行预算..." -ForegroundColor Cyan
    & $CircuitBreakerScript -AddLoops 1
}

Write-Host "🔍 开始自动检测并运行测试/构建 (Self-Healing)..." -ForegroundColor Cyan

$StateDir = Join-Path $WorkspaceRoot ".Rayman\state"
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }
$RuntimeDir = Join-Path $WorkspaceRoot ".Rayman\runtime"
if (-not (Test-Path $RuntimeDir)) { New-Item -ItemType Directory -Path $RuntimeDir | Out-Null }
$LogsDir = Join-Path $WorkspaceRoot ".Rayman\logs"
if (-not (Test-Path $LogsDir)) { New-Item -ItemType Directory -Path $LogsDir | Out-Null }

$script:DotNetExecSummaryPath = Join-Path $RuntimeDir 'dotnet.exec.last.json'
$script:DotNetExecDetailPath = Join-Path $LogsDir ("dotnet.exec.{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

$LogFile = Join-Path $StateDir "last_error.log"
$ErrorFound = $false

if (Get-Command Get-RaymanRequiredAssetAnalysis -ErrorAction SilentlyContinue) {
    $testFixPreflight = Get-RaymanRequiredAssetAnalysis -WorkspaceRoot $WorkspaceRoot -Label 'test-fix-preflight' -RequiredRelPaths @(
        '.Rayman/scripts/utils/request_attention.ps1',
        '.Rayman/scripts/utils/generate_context.ps1'
    )
    if (-not [bool]$testFixPreflight.ok) {
        Write-RaymanRequiredAssetDiagnostics -Analysis $testFixPreflight -Scope 'test-fix' -LogPath $LogFile
        Set-Content -LiteralPath $LogFile -Encoding UTF8 -Value (Format-RaymanRequiredAssetSummary -Analysis $testFixPreflight)
        Write-Host ("❌ [test-fix] preflight failed: {0}" -f (Format-RaymanRequiredAssetSummary -Analysis $testFixPreflight)) -ForegroundColor Red
        exit 1
    }
}

# 检查是否启用了 Docker 沙箱模式（默认关闭，仅在显式开启时启用）
$UseSandbox = Get-EnvBoolCompat -Name 'RAYMAN_USE_SANDBOX' -Default $false
$SandboxScript = Join-Path $WorkspaceRoot ".Rayman\scripts\sandbox\run_in_sandbox.ps1"

# 沙箱只有在 docker 可用时才算有效，否则会造成“本该跑测试却直接失败”的误报
$dockerOk = $null -ne (Get-Command docker -ErrorAction SilentlyContinue)
$UseSandboxEffective = ($UseSandbox -and $dockerOk -and (Test-Path -LiteralPath $SandboxScript -PathType Leaf))

Set-Location $WorkspaceRoot

$MaxAttempts = Get-EnvInt -Name 'RAYMAN_SELF_HEAL_MAX_ATTEMPTS' -Default 2
if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
if ($MaxAttempts -gt 5) { $MaxAttempts = 5 }
}

$FixLog = New-Object System.Collections.Generic.List[string]
$CommandLog = New-Object System.Collections.Generic.List[string]

function New-RaymanQuotedDotNetCommand {
    param(
        [ValidateSet('build', 'test', 'restore', 'workload restore')]
        [string]$Verb,
        [string]$Path = '',
        [string]$Framework = ''
    )

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add('dotnet') | Out-Null
    foreach ($segment in ($Verb -split ' ')) {
        if (-not [string]::IsNullOrWhiteSpace($segment)) {
            $parts.Add($segment) | Out-Null
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $parts.Add("'" + (ConvertTo-PsSingleQuotedLiteral $Path) + "'") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($Framework)) {
        $parts.Add('-f') | Out-Null
        $parts.Add($Framework) | Out-Null
    }
    return ($parts -join ' ')
}

function Get-RaymanMauiPreferredPlatform {
    param([string]$WorkspaceRootOverride = '')

    $resolvedWorkspaceRoot = $WorkspaceRoot
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceRootOverride)) {
        $resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRootOverride).Path
    }
    $windowsPreferred = Get-EnvBoolCompat -Name 'RAYMAN_DOTNET_WINDOWS_PREFERRED' -Default $true
    $bridgeContext = Resolve-DotNetWindowsBridge -WorkspaceRoot $resolvedWorkspaceRoot
    if ((Test-IsWindowsPlatformCompat) -or ($windowsPreferred -and (Test-CanUseWindowsDotNetFromCurrentHost -BridgeContext $bridgeContext))) {
        return 'windows'
    }
    if (Test-IsMacOSPlatformCompat) {
        return 'maccatalyst'
    }
    return 'android'
}

function Get-RaymanMauiWorkloadRestoreCommands {
    param([object]$PrimaryContext)

    $commands = New-Object System.Collections.Generic.List[string]
    if ($null -eq $PrimaryContext) {
        return @()
    }

    $mauiProjects = @()
    if ($PrimaryContext.PSObject.Properties['DependencyProfile']) {
        $profile = $PrimaryContext.DependencyProfile
        if ($null -ne $profile -and $profile.PSObject.Properties['MauiProjects']) {
            $mauiProjects = @($profile.MauiProjects)
        }
    }
    if ($mauiProjects.Count -eq 0 -and $PrimaryContext.PSObject.Properties['MauiProjectPath']) {
        $projectPath = [string]$PrimaryContext.MauiProjectPath
        if (-not [string]::IsNullOrWhiteSpace($projectPath)) {
            $mauiProjects = @([pscustomobject]@{ Path = $projectPath })
        }
    }

    foreach ($project in @($mauiProjects)) {
        if ($null -eq $project) { continue }
        $projectPath = [string]$project.Path
        if ([string]::IsNullOrWhiteSpace($projectPath)) { continue }
        $commands.Add((New-RaymanQuotedDotNetCommand -Verb 'workload restore' -Path $projectPath)) | Out-Null
    }

    return @($commands.ToArray() | Select-Object -Unique)
}

function Invoke-CommonFixes {
    param(
        [string]$Kind,
        [string[]]$OutputLines,
        [object]$PrimaryContext = $null
    )

    $did = $false
    $autoDep = Get-EnvBoolCompat -Name 'RAYMAN_SELF_HEAL_AUTO_DEP_INSTALL' -Default $true

    if (-not $autoDep) {
        return $false
    }

    $text = ($OutputLines -join "`n")

    if ($Kind -eq 'dotnet') {
        if ($text -match 'NETSDK1147|workloads? must be installed|dotnet workload restore') {
            foreach ($workloadCommand in @(Get-RaymanMauiWorkloadRestoreCommands -PrimaryContext $PrimaryContext)) {
                Write-Host ("🛠️  [Self-Heal] 尝试 {0} ..." -f $workloadCommand) -ForegroundColor Yellow
                $FixLog.Add($workloadCommand)
                $null = Invoke-RaymanCommand -Command $workloadCommand -UseSandboxEffective $false -SandboxScript $SandboxScript -Kind 'dotnet'
                $did = $true
            }
        }
        if ($text -match 'assets file.*not found|Run a NuGet package restore|NU1\d\d\d|NU2\d\d\d|NU3\d\d\d') {
            Write-Host "🛠️  [Self-Heal] 尝试 dotnet restore ..." -ForegroundColor Yellow
            $FixLog.Add('dotnet restore')
            $null = Invoke-RaymanCommand -Command 'dotnet restore' -UseSandboxEffective $false -SandboxScript $SandboxScript -Kind 'dotnet'
            $did = $true
        }
    } elseif ($Kind -eq 'node') {
        if ($text -match 'Cannot find module|ERR! code MODULE_NOT_FOUND|npm ERR!|ELIFECYCLE') {
            $lock = Test-Path -LiteralPath (Join-Path $WorkspaceRoot 'package-lock.json') -PathType Leaf
            $cmd = 'npm install'
            if ($lock) { $cmd = 'npm ci' }
            Write-Host "🛠️  [Self-Heal] 尝试 $cmd ..." -ForegroundColor Yellow
            $FixLog.Add($cmd)
            $null = Invoke-RaymanCommand -Command $cmd -UseSandboxEffective $false -SandboxScript $SandboxScript -Kind 'node'
            $did = $true
        }
    } elseif ($Kind -eq 'python') {
        $py = Get-EnvString -Name 'RAYMAN_PYTHON' -Default 'python'
        if (-not (Get-Command $py -ErrorAction SilentlyContinue)) { $py = 'python' }
        if ($text -match 'No module named pytest|ModuleNotFoundError:.*pytest') {
            Write-Host "🛠️  [Self-Heal] 安装 pytest ..." -ForegroundColor Yellow
            $FixLog.Add("$py -m pip install pytest")
            $null = & $py -m pip install pytest 2>&1
            $did = $true
        }
        if ((Test-Path -LiteralPath (Join-Path $WorkspaceRoot 'requirements.txt') -PathType Leaf) -and ($text -match 'ModuleNotFoundError: No module named|ImportError')) {
            Write-Host "🛠️  [Self-Heal] 安装 requirements.txt 依赖 ..." -ForegroundColor Yellow
            $FixLog.Add("$py -m pip install -r requirements.txt")
            $null = & $py -m pip install -r (Join-Path $WorkspaceRoot 'requirements.txt') 2>&1
            $did = $true
        }
    } elseif ($Kind -eq 'rayman') {
        $text = ($OutputLines -join "`n")
        $repairScript = Join-Path $WorkspaceRoot '.Rayman\scripts\repair\ensure_complete_rayman.ps1'
        $syncScript = Join-Path $WorkspaceRoot '.Rayman\scripts\release\sync_dist_from_src.ps1'

        if ($text -match 'source missing:|source missing|缺少内置修复包|缺少') {
            if (Test-Path -LiteralPath $repairScript -PathType Leaf) {
                Write-Host "🛠️  [Self-Heal] 尝试修复 Rayman 缺失文件 (ensure_complete_rayman.ps1) ..." -ForegroundColor Yellow
                $FixLog.Add('ensure_complete_rayman.ps1')
                $null = & $repairScript -Root $WorkspaceRoot 2>&1
                $did = $true
            }
        }

        if ($text -match 'dist missing:|dist missing|\.Rayman/\.dist 漂移|dist-drift|漂移') {
            if (Test-Path -LiteralPath $syncScript -PathType Leaf) {
                Write-Host "🛠️  [Self-Heal] 尝试同步 .Rayman/.dist (sync_dist_from_src.ps1) ..." -ForegroundColor Yellow
                $FixLog.Add('sync_dist_from_src.ps1 -Validate')
                $null = & $syncScript -WorkspaceRoot $WorkspaceRoot -Validate 2>&1
                $did = $true
            }
        }
    }

    return $did
}

function Get-PrimaryCommand {
    param([string]$WorkspaceRootOverride = '')

    $resolvedWorkspaceRoot = $WorkspaceRoot
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceRootOverride)) {
        $resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRootOverride).Path
    }

    $dependencyProfile = $null
    if (Get-Command Get-RaymanWorkspaceDependencyProfile -ErrorAction SilentlyContinue) {
        $dependencyProfile = Get-RaymanWorkspaceDependencyProfile -WorkspaceRoot $resolvedWorkspaceRoot
    }

    if ($null -ne $dependencyProfile -and $dependencyProfile.NeedsDotNet) {
        $prefer = Get-EnvString -Name 'RAYMAN_DOTNET_PRIMARY' -Default ''
        $solutionFiles = @(Get-ChildItem -Path $resolvedWorkspaceRoot -Recurse -File -Include *.sln,*.slnx -ErrorAction SilentlyContinue | Select-Object -Property FullName, Name | Sort-Object Name)
        $testProjects = @(Get-ChildItem -Path $resolvedWorkspaceRoot -Filter '*Tests*.csproj' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -Property FullName, Name | Sort-Object Name)

        if ($dependencyProfile.IsMaui -and $null -ne $dependencyProfile.PreferredMauiProject) {
            $mauiProjectPath = [string]$dependencyProfile.PreferredMauiProject.Path
            $targetFramework = Select-RaymanMauiTargetFramework -Frameworks @($dependencyProfile.PreferredMauiProject.TargetFrameworks) -PreferredPlatform (Get-RaymanMauiPreferredPlatform -WorkspaceRootOverride $resolvedWorkspaceRoot)
            $command = New-RaymanQuotedDotNetCommand -Verb 'build' -Path $mauiProjectPath -Framework $targetFramework
            return [pscustomobject]@{
                Kind = 'dotnet'
                Command = $command
                DependencyProfile = $dependencyProfile
                IsMaui = $true
                MauiProjectPath = $mauiProjectPath
                MauiTargetFramework = $targetFramework
            }
        }

        if ($solutionFiles.Count -gt 0) {
            $solutionPath = [string]$solutionFiles[0].FullName
            $verb = 'build'
            if ($prefer -eq 'test' -or ($prefer -ne 'build' -and $testProjects.Count -gt 0)) {
                $verb = 'test'
            }
            return [pscustomobject]@{
                Kind = 'dotnet'
                Command = (New-RaymanQuotedDotNetCommand -Verb $verb -Path $solutionPath)
                DependencyProfile = $dependencyProfile
                IsMaui = $false
                DotNetTargetPath = $solutionPath
            }
        }

        if ($testProjects.Count -gt 0 -and $prefer -ne 'build') {
            $testProjectPath = [string]$testProjects[0].FullName
            return [pscustomobject]@{
                Kind = 'dotnet'
                Command = (New-RaymanQuotedDotNetCommand -Verb 'test' -Path $testProjectPath)
                DependencyProfile = $dependencyProfile
                IsMaui = $false
                DotNetTargetPath = $testProjectPath
            }
        }

        if ($dependencyProfile.DotNetProjectPaths.Count -gt 0) {
            $projectPath = [string]$dependencyProfile.DotNetProjectPaths[0]
            return [pscustomobject]@{
                Kind = 'dotnet'
                Command = (New-RaymanQuotedDotNetCommand -Verb 'build' -Path $projectPath)
                DependencyProfile = $dependencyProfile
                IsMaui = $false
                DotNetTargetPath = $projectPath
            }
        }
    }

    $pkgPath = Join-Path $resolvedWorkspaceRoot 'package.json'
    if (Test-Path -LiteralPath $pkgPath -PathType Leaf) {
        try {
            $pkg = Get-Content -LiteralPath $pkgPath -Raw -ErrorAction Stop | ConvertFrom-Json
            $scripts = $pkg.scripts
            if ($null -ne $scripts -and ($scripts.PSObject.Properties.Name -contains 'test')) {
                return [pscustomobject]@{ Kind='node'; Command='npm test' }
            }
            if ($null -ne $scripts -and ($scripts.PSObject.Properties.Name -contains 'build')) {
                return [pscustomobject]@{ Kind='node'; Command='npm run build' }
            }
        } catch {}
        return [pscustomobject]@{ Kind='node'; Command='npm run build' }
    }

    if ((Test-Path -LiteralPath (Join-Path $resolvedWorkspaceRoot 'requirements.txt') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $resolvedWorkspaceRoot 'pyproject.toml') -PathType Leaf)) {
        $py = Get-EnvString -Name 'RAYMAN_PYTHON' -Default 'python'
        if (-not (Get-Command $py -ErrorAction SilentlyContinue)) { $py = 'python' }
        return [pscustomobject]@{ Kind='python'; Command="$py -m pytest" }
    }

    # Rayman/RaymanAgent 自检（脚本仓库没有 sln/package.json/requirements 的情况下也要能跑）
    $raymanDir = Join-Path $resolvedWorkspaceRoot '.Rayman'
    $assert = Join-Path $raymanDir 'scripts\release\assert_dist_sync.ps1'
    $dist = Join-Path $raymanDir '.dist'
    if ((Test-Path -LiteralPath $assert -PathType Leaf) -and (Test-Path -LiteralPath $dist -PathType Container)) {
        # 直接调用脚本，避免在 WSL/Linux 下依赖 powershell(.exe) 命令名。
        $assertEscaped = $assert.Replace("'", "''")
        $workspaceEscaped = $resolvedWorkspaceRoot.Replace("'", "''")
        $cmd = "& '" + $assertEscaped + "' -WorkspaceRoot '" + $workspaceEscaped + "'"
        return [pscustomobject]@{ Kind='rayman'; Command=$cmd }
    }

    return $null
}

if (-not $NoMain) {
$primary = Get-PrimaryCommand -WorkspaceRootOverride $WorkspaceRoot
if ($null -eq $primary) {
    Write-Host "⚠️ 未识别的项目类型，无法自动运行测试。" -ForegroundColor Yellow
    exit 0
}

$depsScript = Join-Path $WorkspaceRoot ".Rayman\scripts\utils\ensure_project_test_deps.ps1"
$depsScriptSh = Join-Path $WorkspaceRoot ".Rayman/scripts/utils/ensure_project_test_deps.sh"
$autoInstallTestDeps = Get-EnvBoolCompat -Name 'RAYMAN_AUTO_INSTALL_TEST_DEPS' -Default $true
$requireTestDeps = Get-EnvBoolCompat -Name 'RAYMAN_REQUIRE_TEST_DEPS' -Default $true
$depsOnlyKinds = ''
switch ([string]$primary.Kind) {
    'dotnet' { $depsOnlyKinds = 'dotnet' }
    'node' { $depsOnlyKinds = 'node' }
    'python' { $depsOnlyKinds = 'python' }
    default { $depsOnlyKinds = '' }
}

if ((Test-Path -LiteralPath $depsScript -PathType Leaf) -or (Test-Path -LiteralPath $depsScriptSh -PathType Leaf)) {
    $depsScopeText = if ([string]::IsNullOrWhiteSpace($depsOnlyKinds)) { 'all' } else { $depsOnlyKinds }
    Write-Host ("🧩 [Self-Heal] 检查测试依赖（autoInstall={0}, require={1}, onlyKinds={2}）..." -f $autoInstallTestDeps, $requireTestDeps, $depsScopeText) -ForegroundColor Cyan

    $depsExitCode = 0
    $isWindowsHost = Test-IsWindowsPlatformCompat
    $canUseBash = $null -ne (Get-Command bash -ErrorAction SilentlyContinue)
    if ((-not $isWindowsHost) -and $canUseBash -and (Test-Path -LiteralPath $depsScriptSh -PathType Leaf)) {
        $autoInstallFlag = if ($autoInstallTestDeps) { '1' } else { '0' }
        $requireFlag = if ($requireTestDeps) { '1' } else { '0' }
        $depsArgs = @('--workspace-root', $WorkspaceRoot, '--auto-install', $autoInstallFlag, '--require', $requireFlag)
        if (-not [string]::IsNullOrWhiteSpace($depsOnlyKinds)) {
            $depsArgs += @('--only', $depsOnlyKinds)
        }
        Write-Host "ℹ️  [Self-Heal] WSL/Linux 环境优先执行 ensure_project_test_deps.sh（含 Windows bridge）" -ForegroundColor DarkCyan
        & bash $depsScriptSh @depsArgs | Out-Host
        $depsExitCode = [int]$LASTEXITCODE
    } elseif (Test-Path -LiteralPath $depsScript -PathType Leaf) {
        $callerHostType = if ($isWindowsHost) { 'windows-native' } else { 'pwsh' }
        $depsParams = @{
            WorkspaceRoot = $WorkspaceRoot
            AutoInstall = $autoInstallTestDeps
            Require = $requireTestDeps
            Caller = 'run_tests_and_fix.ps1'
            CallerHostType = $callerHostType
            CallerWorkspaceRoot = $WorkspaceRoot
        }
        if (-not [string]::IsNullOrWhiteSpace($depsOnlyKinds)) {
            $depsParams['OnlyKinds'] = $depsOnlyKinds
        }
        & $depsScript @depsParams | Out-Host
        $depsExitCode = [int]$LASTEXITCODE
    } elseif ($canUseBash -and (Test-Path -LiteralPath $depsScriptSh -PathType Leaf)) {
        $autoInstallFlag = if ($autoInstallTestDeps) { '1' } else { '0' }
        $requireFlag = if ($requireTestDeps) { '1' } else { '0' }
        $depsArgs = @('--workspace-root', $WorkspaceRoot, '--auto-install', $autoInstallFlag, '--require', $requireFlag)
        if (-not [string]::IsNullOrWhiteSpace($depsOnlyKinds)) {
            $depsArgs += @('--only', $depsOnlyKinds)
        }
        & bash $depsScriptSh @depsArgs | Out-Host
        $depsExitCode = [int]$LASTEXITCODE
    }

    if ($depsExitCode -ne 0) {
        $ErrorFound = $true
        $msg = "测试依赖未满足，请先安装缺失 SDK / workload。"
        Set-Content -LiteralPath $LogFile -Value $msg -Encoding UTF8
        Write-Host ("❌ {0}" -f $msg) -ForegroundColor Red
        exit 1
    }
}

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    Write-Host ("▶️ 检测到 {0} 项目，执行: {1} (attempt {2}/{3})" -f $primary.Kind, $primary.Command, $attempt, $MaxAttempts) -ForegroundColor Cyan
    $CommandLog.Add($primary.Command)

    $output = Invoke-RaymanCommand -Command $primary.Command -UseSandboxEffective $UseSandboxEffective -SandboxScript $SandboxScript -Kind $primary.Kind
    $exit = $LASTEXITCODE
    $outLines = @($output)

    if ($exit -eq 0) {
        $ErrorFound = $false
        break
    }

    $ErrorFound = $true
    $outLines | Out-File $LogFile -Encoding UTF8

    if ($attempt -lt $MaxAttempts) {
        $didFix = Invoke-CommonFixes -Kind $primary.Kind -OutputLines $outLines -PrimaryContext $primary
        if (-not $didFix) {
            Write-Host "ℹ️  [Self-Heal] 未命中可自动修复的常见模式，停止重试。" -ForegroundColor Cyan
            break
        }
        # 修复后继续重跑
        continue
    }
}

if ($ErrorFound) {
    Write-Host "❌ 发现错误！日志已保存至 $LogFile" -ForegroundColor Red
    
    # 捕获高精度故障现场快照
    $SnapshotScript = Join-Path $WorkspaceRoot ".Rayman\scripts\repair\capture_snapshot.ps1"
    if (Test-Path $SnapshotScript) {
        & $SnapshotScript -WorkspaceRoot $WorkspaceRoot -LogFile $LogFile
    }

    # 额外生成一个便于贴到聊天里的摘要
    try {
        $summaryFile = Join-Path $StateDir "last_error_summary.md"
        $tail = Get-Content -LiteralPath $LogFile -ErrorAction SilentlyContinue | Select-Object -Last 200
        $refs = Get-FileRefsFromLines -Lines $tail
        $refsBlock = ''
        if ($refs -and $refs.Count -gt 0) {
            $refsLines = @(
                '',
                '## 🔗 可能相关的文件引用 (从日志提取)',
                ''
            )
            $refsLines += ($refs | Select-Object -First 30 | ForEach-Object { '- `' + $_ + '`' })
            if ($refs.Count -gt 30) { $refsLines += '- ...' }
            $refsBlock = ($refsLines -join "`r`n")
        }
        
        # 2. 尝试使用 RAG 搜索相关错误解决方案
        $RagScript = Join-Path $WorkspaceRoot ".Rayman\scripts\rag\manage_rag.ps1"
        $RagContext = ""
        if (Test-Path $RagScript) {
            Write-Host "🧠 [RAG] 正在搜索历史记忆库以寻找解决方案..." -ForegroundColor Cyan
            # 提取最后若干行错误信息作为查询词
            $QueryText = ($tail | Select-Object -Last 20) -join " "
            if (-not [string]::IsNullOrWhiteSpace($QueryText)) {
                # 截断查询词，避免过长
                if ($QueryText.Length -gt 400) { $QueryText = $QueryText.Substring(0, 400) }
                $RagResult = & $RagScript -Action search -Query $QueryText -TopK 8 2>&1
                if ($RagResult) {
                    $ragFetchedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
                    $ragFetchedUnix = [DateTimeOffset]::Now.ToUnixTimeSeconds()
                    $ragLines = @(
                        '',
                        '## 🧠 RAG 记忆库相关参考',
                        "- fetched_at_iso: $ragFetchedAt",
                        "- fetched_at_unix: $ragFetchedUnix",
                        '',
                        '```text',
                        ($RagResult -join "`r`n"),
                        '```'
                    )
                    $RagContext = ($ragLines -join "`r`n")
                }
            }
        }

        $fixBlock = ""
        if ($FixLog.Count -gt 0) {
            $fixLines = @(
                '',
                '## 🛠️ 已尝试的自动修复步骤',
                ''
            )
            $fixLines += ($FixLog | Select-Object -Unique | ForEach-Object { '- `' + $_ + '`' })
            $fixBlock = ($fixLines -join "`r`n")
        }

        $cmdBlock = ""
        if ($CommandLog.Count -gt 0) {
            $cmdLines = @(
                '',
                '## ▶️ 已执行的主命令',
                ''
            )
            $cmdLines += ($CommandLog | Select-Object -Unique | ForEach-Object { '- `' + $_ + '`' })
            $cmdBlock = ($cmdLines -join "`r`n")
        }

        $mdLines = @(
            '# Rayman 错误摘要',
            '',
            "**时间**: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
            '',
            "**工作区**: $WorkspaceRoot",
            "**沙箱**: $UseSandboxEffective",
            '',
            '## 🕵️ 深度诊断建议 (RCA)',
            '如需深度诊断推演，可查阅刚刚生成的快照：`.Rayman/state/error_snapshot.md`',
            '或者要求 Agent 使用 `RCA Diagnostic Agent` 分析排障！',
            '',
            '## ❌ 错误日志',
            '```text',
            ($tail -join "`r`n"),
            '```',
            $cmdBlock,
            $fixBlock,
            $refsBlock,
            $RagContext,
            '',
            '---',
            '',
            '如需更完整上下文，请先运行：`.Rayman/scripts/utils/generate_context.ps1`（或使用命令：更新上下文）'
        )
        $md = ($mdLines -join "`r`n")
        Set-Content -LiteralPath $summaryFile -Value $md -Encoding UTF8
        Write-Host "📄 已生成错误摘要 (含 RAG 上下文): $summaryFile" -ForegroundColor Yellow
    } catch {
        Write-Host "⚠️ 生成错误摘要失败: $_" -ForegroundColor Yellow
    }
    if (Get-Command Invoke-RaymanAttentionAlert -ErrorAction SilentlyContinue) {
        Invoke-RaymanAttentionAlert -Kind 'error' -Reason '构建或测试失败，请让 AI 查看错误日志' -WorkspaceRoot $WorkspaceRoot | Out-Null
    }
    
    if (Get-Command Throw-RaymanError -ErrorAction SilentlyContinue) {
        Throw-RaymanError -Message "构建或测试失败，请查看 $summaryFile" -ErrorCodeName 'ERR_VALIDATION' -Component 'SelfHeal'
    } else {
        exit 1
    }
} else {
    Write-Host "✅ 所有检查通过！" -ForegroundColor Green
    if (Test-Path $LogFile) { Remove-Item $LogFile -Force }
    if (Get-Command Invoke-RaymanAttentionAlert -ErrorAction SilentlyContinue) {
        Invoke-RaymanAttentionAlert -Kind 'done' -Reason '项目编译和测试通过' -WorkspaceRoot $WorkspaceRoot | Out-Null
    }
    exit 0
}
}
