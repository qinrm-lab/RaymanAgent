param(
    [switch]$SkipInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ProcessTimeoutSeconds = 120
$PostInstallStatusWaitSeconds = 20

function Join-LogLines {
    param([string[]]$Lines)

    return (($Lines | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
}

function Write-LogText {
    param(
        [string]$Path,
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Append-LogText {
    param(
        [string]$Path,
        [string]$Content
    )

    [System.IO.File]::AppendAllText($Path, $Content, $Utf8NoBom)
}

function Add-LogSection {
    param(
        [string]$Path,
        [string]$Title,
        [string]$Content
    )

    $resolvedContent = if ([string]::IsNullOrWhiteSpace($Content)) { '(empty)' } else { $Content.TrimEnd("`r", "`n") }
    $section = Join-LogLines -Lines @(
        ('=== {0} ===' -f $Title),
        $resolvedContent,
        ''
    )
    Append-LogText -Path $Path -Content ($section + [Environment]::NewLine)
}

function Clear-AllLogs {
    param([string]$LogRoot)

    if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) {
        return
    }

    foreach ($name in @(
        'all-summary.log',
        'all-01-repair.log',
        'all-02-install.log',
        'all-03-postcheck.log',
        'repair-encoding.log',
        '1.log',
        '2.log',
        '3.log',
        '4.log'
    )) {
        $path = Join-Path $LogRoot $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-LoggedProcess {
    param(
        [string]$DisplayName,
        [string]$CommandText,
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory,
        [string]$LogPath
    )

    $header = Join-LogLines -Lines @(
        ('StartedAt: {0}' -f (Get-Date).ToString('o')),
        ('DisplayName: {0}' -f $DisplayName),
        ('MachineName: {0}' -f $env:COMPUTERNAME),
        ('UserName: {0}' -f $env:USERNAME),
        ('WorkingDirectory: {0}' -f $WorkingDirectory),
        ('Command: {0}' -f $CommandText),
        ''
    )
    Write-LogText -Path $LogPath -Content ($header + [Environment]::NewLine)

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman-worker-all-' + [Guid]::NewGuid().ToString('n'))
    $null = New-Item -ItemType Directory -Force -Path $tempRoot
    $stdoutPath = Join-Path $tempRoot 'stdout.txt'
    $stderrPath = Join-Path $tempRoot 'stderr.txt'

    try {
        $process = Start-Process -FilePath $FilePath `
            -ArgumentList $ArgumentList `
            -WorkingDirectory $WorkingDirectory `
            -NoNewWindow `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru

        if (-not $process.WaitForExit($ProcessTimeoutSeconds * 1000)) {
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            } catch {
            }

            $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8 } else { '' }
            $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8 } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($stderr)) {
                $stderr = $stderr.TrimEnd("`r", "`n") + [Environment]::NewLine + ('Process timed out after {0} seconds.' -f $ProcessTimeoutSeconds)
            } else {
                $stderr = ('Process timed out after {0} seconds.' -f $ProcessTimeoutSeconds)
            }

            Add-LogSection -Path $LogPath -Title 'STDOUT' -Content $stdout
            Add-LogSection -Path $LogPath -Title 'STDERR' -Content $stderr
            Append-LogText -Path $LogPath -Content ((Join-LogLines -Lines @(
                ('FinishedAt: {0}' -f (Get-Date).ToString('o')),
                'ExitCode: 124',
                'Status: FAIL',
                ''
            )) + [Environment]::NewLine)

            return [pscustomobject]@{
                ExitCode = 124
                Status = 'FAIL'
                StdOut = $stdout
                StdErr = $stderr
            }
        }

        $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8 } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8 } else { '' }

        $exitCode = [int]$process.ExitCode
        $status = if ($exitCode -eq 0) { 'PASS' } else { 'FAIL' }

        Add-LogSection -Path $LogPath -Title 'STDOUT' -Content $stdout
        Add-LogSection -Path $LogPath -Title 'STDERR' -Content $stderr
        Append-LogText -Path $LogPath -Content ((Join-LogLines -Lines @(
            ('FinishedAt: {0}' -f (Get-Date).ToString('o')),
            ('ExitCode: {0}' -f $exitCode),
            ('Status: {0}' -f $status),
            ''
        )) + [Environment]::NewLine)

        return [pscustomobject]@{
            ExitCode = $exitCode
            Status = $status
            StdOut = $stdout
            StdErr = $stderr
        }
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-DiagnosticLogPass {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    return ($raw -match '(?m)^Status:\s+PASS\s*$')
}

function Get-OptionalFileText {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return '(missing)'
    }

    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
}

function ConvertFrom-EmbeddedJsonSafe {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    try {
        return ($Text | ConvertFrom-Json -ErrorAction Stop)
    } catch {
    }

    $start = $Text.IndexOf('{')
    $end = $Text.LastIndexOf('}')
    if ($start -lt 0 -or $end -lt $start) {
        return $null
    }

    $jsonSlice = $Text.Substring($start, ($end - $start + 1))
    try {
        return ($jsonSlice | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Read-JsonFileSafe {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function ConvertTo-DateTimeSafe {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Wait-ForFreshWorkerHostStatus {
    param(
        [string]$HostStatusPath,
        [string]$WorkspaceRoot,
        [string]$ExpectedWorkerId,
        [datetime]$NotBefore,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $status = Read-JsonFileSafe -Path $HostStatusPath
        if ($null -ne $status) {
            $workspaceMatches = $status.PSObject.Properties['workspace_root'] -and ([string]$status.workspace_root -eq $WorkspaceRoot)
            $workerMatches = [string]::IsNullOrWhiteSpace($ExpectedWorkerId) -or ($status.PSObject.Properties['worker_id'] -and ([string]$status.worker_id -eq $ExpectedWorkerId))
            $hasProcessId = $status.PSObject.Properties['process_id'] -and ([int]$status.process_id -gt 0)
            $generatedAt = if ($status.PSObject.Properties['generated_at']) { ConvertTo-DateTimeSafe -Value $status.generated_at } else { $null }
            $isFresh = $false
            if ($null -ne $generatedAt) {
                $isFresh = ($generatedAt -ge $NotBefore)
            }

            if ($workspaceMatches -and $workerMatches -and $hasProcessId -and $isFresh) {
                return [pscustomobject]@{
                    Fresh = $true
                    Status = $status
                    Reason = 'ok'
                }
            }
        }

        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return [pscustomobject]@{
        Fresh = $false
        Status = (Read-JsonFileSafe -Path $HostStatusPath)
        Reason = 'timeout'
    }
}

function Convert-TaskInfoToText {
    param(
        [string]$TaskName,
        [string]$TaskPath
    )

    try {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
        return (($info | Format-List * | Out-String).TrimEnd("`r", "`n"))
    } catch {
        return ('Get-ScheduledTaskInfo failed: {0}' -f $_.Exception.Message)
    }
}

$workspaceRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    (Resolve-Path -LiteralPath $PSScriptRoot).Path
}
$logRoot = Join-Path $workspaceRoot 'log'
if (-not (Test-Path -LiteralPath $logRoot -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
}

Clear-AllLogs -LogRoot $logRoot

$summaryPath = Join-Path $logRoot 'all-summary.log'
$repairStepLog = Join-Path $logRoot 'all-01-repair.log'
$installStepLog = Join-Path $logRoot 'all-02-install.log'
$postcheckLog = Join-Path $logRoot 'all-03-postcheck.log'

$summaryLines = New-Object System.Collections.Generic.List[string]
$summaryLines.Add(('StartedAt: {0}' -f (Get-Date).ToString('o'))) | Out-Null
$summaryLines.Add(('WorkspaceRoot: {0}' -f $workspaceRoot)) | Out-Null
$summaryLines.Add(('SkipInstall: {0}' -f $SkipInstall)) | Out-Null
$summaryLines.Add('') | Out-Null

$repairResult = Invoke-LoggedProcess `
    -DisplayName 'Encoding repair and diagnostic refresh' `
    -CommandText 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\repair-worker-encoding.ps1' `
    -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', '.\repair-worker-encoding.ps1') `
    -WorkingDirectory $workspaceRoot `
    -LogPath $repairStepLog

$summaryLines.Add(('RepairStep: {0} exit={1}' -f $repairResult.Status, $repairResult.ExitCode)) | Out-Null

$diag2Path = Join-Path $logRoot '2.log'
$diag4Path = Join-Path $logRoot '4.log'
$diagPowerShellPass = Test-DiagnosticLogPass -Path $diag2Path
$diagPwshPass = Test-DiagnosticLogPass -Path $diag4Path

$summaryLines.Add(('DiagnosticWindowsPowerShell: {0}' -f $diagPowerShellPass)) | Out-Null
$summaryLines.Add(('DiagnosticPowerShell7: {0}' -f $diagPwshPass)) | Out-Null

$installExecuted = $false
$installResult = $null
$installJson = $null
$freshHostWait = $null

if (-not $diagPowerShellPass) {
    $summaryLines.Add('InstallStep: SKIPPED because .\log\2.log is not PASS.') | Out-Null
} elseif ($SkipInstall) {
    $summaryLines.Add('InstallStep: SKIPPED by -SkipInstall.') | Out-Null
    Write-LogText -Path $installStepLog -Content ((Join-LogLines -Lines @(
        ('StartedAt: {0}' -f (Get-Date).ToString('o')),
        'DisplayName: worker install-local',
        'Status: SKIPPED',
        'Reason: -SkipInstall',
        ('FinishedAt: {0}' -f (Get-Date).ToString('o')),
        ''
    )) + [Environment]::NewLine)
} else {
    $installExecuted = $true
    $installResult = Invoke-LoggedProcess `
        -DisplayName 'worker install-local' `
        -CommandText 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\.Rayman\rayman.ps1 worker install-local' `
        -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', '.\.Rayman\rayman.ps1', 'worker', 'install-local') `
        -WorkingDirectory $workspaceRoot `
        -LogPath $installStepLog

    $summaryLines.Add(('InstallStep: {0} exit={1}' -f $installResult.Status, $installResult.ExitCode)) | Out-Null

    try {
        if (-not [string]::IsNullOrWhiteSpace([string]$installResult.StdOut)) {
            $installJson = ConvertFrom-EmbeddedJsonSafe -Text ([string]$installResult.StdOut)
            if ($null -eq $installJson) {
                throw 'unable to locate JSON payload inside install stdout.'
            }
        }
    } catch {
        $summaryLines.Add(('InstallJsonParse: FAIL {0}' -f $_.Exception.Message)) | Out-Null
    }
}

$hostStatusPath = Join-Path $workspaceRoot '.Rayman\runtime\worker\host.status.json'
$vsdbgStatusPath = Join-Path $workspaceRoot '.Rayman\runtime\worker\vsdbg.last.json'
$hostStatus = $null
$vsdbgStatus = $null

if ($installExecuted -and $null -ne $installJson -and $installResult.Status -eq 'PASS') {
    $installGeneratedAt = if ($installJson.PSObject.Properties['generated_at']) { ConvertTo-DateTimeSafe -Value $installJson.generated_at } else { $null }
    if ($null -eq $installGeneratedAt) {
        $installGeneratedAt = Get-Date
    }

    $expectedWorkerId = if ($installJson.PSObject.Properties['worker_id']) { [string]$installJson.worker_id } else { '' }
    $freshHostWait = Wait-ForFreshWorkerHostStatus `
        -HostStatusPath $hostStatusPath `
        -WorkspaceRoot $workspaceRoot `
        -ExpectedWorkerId $expectedWorkerId `
        -NotBefore $installGeneratedAt `
        -TimeoutSeconds $PostInstallStatusWaitSeconds

    $hostStatus = $freshHostWait.Status
} else {
    $hostStatus = Read-JsonFileSafe -Path $hostStatusPath
}

$vsdbgStatus = Read-JsonFileSafe -Path $vsdbgStatusPath

$postcheckLines = New-Object System.Collections.Generic.List[string]
$postcheckLines.Add(('StartedAt: {0}' -f (Get-Date).ToString('o'))) | Out-Null
$postcheckLines.Add(('WorkspaceRoot: {0}' -f $workspaceRoot)) | Out-Null
$postcheckLines.Add(('InstallExecuted: {0}' -f $installExecuted)) | Out-Null
$postcheckLines.Add(('DiagnosticWindowsPowerShellPass: {0}' -f $diagPowerShellPass)) | Out-Null
$postcheckLines.Add(('DiagnosticPowerShell7Pass: {0}' -f $diagPwshPass)) | Out-Null
$postcheckLines.Add('') | Out-Null

if ($null -ne $installJson) {
    $postcheckLines.Add('InstallResultJson:') | Out-Null
    $postcheckLines.Add(($installJson | ConvertTo-Json -Depth 12)) | Out-Null
    $postcheckLines.Add('') | Out-Null
}

if ($null -ne $freshHostWait) {
    $postcheckLines.Add(('HostStatusFreshWait: {0}' -f $freshHostWait.Fresh)) | Out-Null
    $postcheckLines.Add(('HostStatusFreshWaitReason: {0}' -f $freshHostWait.Reason)) | Out-Null
    $postcheckLines.Add(('HostStatusFreshWaitTimeoutSeconds: {0}' -f $PostInstallStatusWaitSeconds)) | Out-Null
    $postcheckLines.Add('') | Out-Null
}

$scheduledTasks = @()
try {
    $scheduledTasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -eq 'Rayman Worker' })
} catch {
    $scheduledTasks = @()
    $postcheckLines.Add(('ScheduledTaskQueryError: {0}' -f $_.Exception.Message)) | Out-Null
    $postcheckLines.Add('') | Out-Null
}

if ($scheduledTasks.Count -eq 0) {
    $postcheckLines.Add('ScheduledTasks: none found with TaskName = Rayman Worker') | Out-Null
    $postcheckLines.Add('') | Out-Null
} else {
    foreach ($task in $scheduledTasks) {
        $postcheckLines.Add(('ScheduledTask: {0}{1}' -f $task.TaskPath, $task.TaskName)) | Out-Null
        $postcheckLines.Add((($task | Format-List TaskName, TaskPath, State, Description | Out-String).TrimEnd("`r", "`n"))) | Out-Null
        $postcheckLines.Add((Convert-TaskInfoToText -TaskName $task.TaskName -TaskPath $task.TaskPath)) | Out-Null
        $postcheckLines.Add('') | Out-Null
    }
}

$postcheckLines.Add('HostStatusJson:') | Out-Null
if ($null -ne $hostStatus) {
    $postcheckLines.Add(($hostStatus | ConvertTo-Json -Depth 12)) | Out-Null
} else {
    $postcheckLines.Add((Get-OptionalFileText -Path $hostStatusPath)) | Out-Null
}
$postcheckLines.Add('') | Out-Null

$postcheckLines.Add('VsdbgStatusJson:') | Out-Null
if ($null -ne $vsdbgStatus) {
    $postcheckLines.Add(($vsdbgStatus | ConvertTo-Json -Depth 12)) | Out-Null
} else {
    $postcheckLines.Add((Get-OptionalFileText -Path $vsdbgStatusPath)) | Out-Null
}
$postcheckLines.Add('') | Out-Null

if ($null -ne $hostStatus) {
    try {
        if ($hostStatus.PSObject.Properties['process_id'] -and [int]$hostStatus.process_id -gt 0) {
            try {
                $processInfo = Get-Process -Id ([int]$hostStatus.process_id) -ErrorAction Stop | Select-Object Id, ProcessName, StartTime, Path
                $postcheckLines.Add('HostProcess:') | Out-Null
                $postcheckLines.Add((($processInfo | Format-List * | Out-String).TrimEnd("`r", "`n"))) | Out-Null
                $postcheckLines.Add('') | Out-Null
            } catch {
                $postcheckLines.Add(('HostProcessError: {0}' -f $_.Exception.Message)) | Out-Null
                $postcheckLines.Add('') | Out-Null
            }
        }
    } catch {
        $postcheckLines.Add(('HostStatusParseError: {0}' -f $_.Exception.Message)) | Out-Null
        $postcheckLines.Add('') | Out-Null
    }
}

$readyForUse = $false
if ($installExecuted -and $null -ne $installJson -and $installResult.Status -eq 'PASS' -and $null -ne $hostStatus -and $null -ne $vsdbgStatus) {
    $workspaceMatches = $hostStatus.PSObject.Properties['workspace_root'] -and ([string]$hostStatus.workspace_root -eq $workspaceRoot)
    $workerMatches = $hostStatus.PSObject.Properties['worker_id'] -and $installJson.PSObject.Properties['worker_id'] -and ([string]$hostStatus.worker_id -eq [string]$installJson.worker_id)
    $hostDebuggerReady = $hostStatus.PSObject.Properties['debugger_ready'] -and [bool]$hostStatus.debugger_ready
    $vsdbgReady = $vsdbgStatus.PSObject.Properties['debugger_ready'] -and [bool]$vsdbgStatus.debugger_ready
    $readyForUse = ($workspaceMatches -and $workerMatches -and $hostDebuggerReady -and $vsdbgReady)
}

$summaryLines.Add(('ReadyForUse: {0}' -f $readyForUse)) | Out-Null

$postcheckLines.Add(('FinishedAt: {0}' -f (Get-Date).ToString('o'))) | Out-Null
Write-LogText -Path $postcheckLog -Content ((Join-LogLines -Lines @($postcheckLines.ToArray())) + [Environment]::NewLine)

$summaryLines.Add(('PostcheckLog: {0}' -f '.\log\all-03-postcheck.log')) | Out-Null
$summaryLines.Add(('RepairLog: {0}' -f '.\log\all-01-repair.log')) | Out-Null
$summaryLines.Add(('InstallLog: {0}' -f '.\log\all-02-install.log')) | Out-Null
$summaryLines.Add(('DiagLog2: {0}' -f '.\log\2.log')) | Out-Null
$summaryLines.Add(('DiagLog4: {0}' -f '.\log\4.log')) | Out-Null
$summaryLines.Add(('FinishedAt: {0}' -f (Get-Date).ToString('o'))) | Out-Null

Write-LogText -Path $summaryPath -Content ((Join-LogLines -Lines @($summaryLines.ToArray())) + [Environment]::NewLine)

Write-Host 'All workflow complete.'
Write-Host 'Logs:'
Write-Host '  .\log\all-summary.log'
Write-Host '  .\log\all-01-repair.log'
Write-Host '  .\log\all-02-install.log'
Write-Host '  .\log\all-03-postcheck.log'
Write-Host '  .\log\1.log'
Write-Host '  .\log\2.log'
Write-Host '  .\log\3.log'
Write-Host '  .\log\4.log'
