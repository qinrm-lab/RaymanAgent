Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$TotalSteps = 4
$ProcessTimeoutSeconds = 30

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

function New-StepLogHeader {
    param(
        [int]$StepNumber,
        [string]$DisplayName,
        [string]$WorkingDirectory,
        [string]$CommandText
    )

    return (Join-LogLines -Lines @(
        ('StartedAt: {0}' -f (Get-Date).ToString('o')),
        ('Step: {0}/{1}' -f $StepNumber, $TotalSteps),
        ('DisplayName: {0}' -f $DisplayName),
        ('MachineName: {0}' -f $env:COMPUTERNAME),
        ('UserName: {0}' -f $env:USERNAME),
        ('WorkingDirectory: {0}' -f $WorkingDirectory),
        ('Command: {0}' -f $CommandText),
        ''
    )) + [Environment]::NewLine
}

function Add-LogSection {
    param(
        [string]$Path,
        [string]$Title,
        [string]$Content
    )

    $resolvedContent = if ([string]::IsNullOrEmpty($Content)) { '(empty)' } else { $Content.TrimEnd("`r", "`n") }
    $section = Join-LogLines -Lines @(
        ('=== {0} ===' -f $Title),
        $resolvedContent,
        ''
    )
    Append-LogText -Path $Path -Content ($section + [Environment]::NewLine)
}

function Clear-DiagnosticLogs {
    param(
        [string]$WorkspaceRoot,
        [string]$LogRoot
    )

    foreach ($diagName in @('1.log', '2.log', '3.log', '4.log')) {
        $diagLogPath = Join-Path $LogRoot $diagName
        if (Test-Path -LiteralPath $diagLogPath -PathType Leaf) {
            Remove-Item -LiteralPath $diagLogPath -Force -ErrorAction SilentlyContinue
        }

        $legacyPath = Join-Path $WorkspaceRoot $diagName
        if (Test-Path -LiteralPath $legacyPath -PathType Leaf) {
            Remove-Item -LiteralPath $legacyPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-CommandExecutablePath {
    param([string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        return ''
    }

    if ($command.Path) {
        return [string]$command.Path
    }

    if ($command.Source -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
        return [string]$command.Source
    }

    return ''
}

function Get-InternalSha256Text {
    param(
        [string]$Path,
        [string]$DisplayPath
    )

    $resolvedDisplayPath = if ([string]::IsNullOrWhiteSpace($DisplayPath)) { $Path } else { $DisplayPath }

    if (Get-Command Get-FileHash -ErrorAction SilentlyContinue) {
        try {
            return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256 | Format-Table -AutoSize | Out-String).TrimEnd("`r", "`n"))
        } catch {
        }
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $hashBytes = $sha256.ComputeHash($stream)
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha256.Dispose()
    }

    $hashText = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '')
    return (Join-LogLines -Lines @(
        'Algorithm       Hash                                                                   Path'
        '---------       ----                                                                   ----'
        ('SHA256          {0}       {1}' -f $hashText, $resolvedDisplayPath)
    ))
}

function Invoke-ExternalProcessCapture {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory
    )

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman-worker-diag-' + [Guid]::NewGuid().ToString('n'))
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

            return [pscustomobject]@{
                ExitCode = 124
                StdOut = $stdout
                StdErr = $stderr
            }
        }

        $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8 } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8 } else { '' }

        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            StdOut = $stdout
            StdErr = $stderr
        }
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-DiagnosticStep {
    param(
        [int]$StepNumber,
        [string]$DisplayName,
        [string]$CommandText,
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory,
        [string]$LogPath,
        [string]$LogLabel,
        [string]$RequiredPath,
        [string]$RequiredLabel,
        [string]$Mode = 'process'
    )

    $header = New-StepLogHeader -StepNumber $StepNumber -DisplayName $DisplayName -WorkingDirectory $WorkingDirectory -CommandText $CommandText
    Write-LogText -Path $LogPath -Content $header

    $result = [ordered]@{
        StepNumber = $StepNumber
        DisplayName = $DisplayName
        LogPath = $LogPath
        LogLabel = $LogLabel
        ExitCode = 1
        Status = 'FAIL'
    }

    if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf)) {
        Add-LogSection -Path $LogPath -Title 'PRECHECK' -Content ('Required path not found: {0}' -f $RequiredLabel)
        Add-LogSection -Path $LogPath -Title 'STDOUT' -Content ''
        Add-LogSection -Path $LogPath -Title 'STDERR' -Content ''
        Append-LogText -Path $LogPath -Content ((Join-LogLines -Lines @(
            ('FinishedAt: {0}' -f (Get-Date).ToString('o')),
            'ExitCode: 1',
            'Status: FAIL',
            ''
        )) + [Environment]::NewLine)
        Write-Host ('Step {0}/{1} FAIL -> {2}' -f $StepNumber, $TotalSteps, $LogLabel)
        return [pscustomobject]$result
    }

    try {
        if ($Mode -eq 'hash') {
            $stdout = Get-InternalSha256Text -Path $RequiredPath -DisplayPath $RequiredLabel
            $stderr = ''
            $result.ExitCode = 0
            $result.Status = 'PASS'
        } else {
            $capture = Invoke-ExternalProcessCapture -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory
            $stdout = [string]$capture.StdOut
            $stderr = [string]$capture.StdErr
            $result.ExitCode = [int]$capture.ExitCode
            if ($result.ExitCode -eq 0) {
                $result.Status = 'PASS'
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            $result.Status = 'FAIL'
            if ($result.ExitCode -eq 0) {
                $result.ExitCode = 1
            }
        }

        Add-LogSection -Path $LogPath -Title 'STDOUT' -Content $stdout
        Add-LogSection -Path $LogPath -Title 'STDERR' -Content $stderr
    } catch {
        Add-LogSection -Path $LogPath -Title 'STDOUT' -Content ''
        Add-LogSection -Path $LogPath -Title 'STDERR' -Content $_.Exception.ToString()
    }

    Append-LogText -Path $LogPath -Content ((Join-LogLines -Lines @(
        ('FinishedAt: {0}' -f (Get-Date).ToString('o')),
        ('ExitCode: {0}' -f $result.ExitCode),
        ('Status: {0}' -f $result.Status),
        ''
    )) + [Environment]::NewLine)

    Write-Host ('Step {0}/{1} {2} -> {3}' -f $StepNumber, $TotalSteps, $result.Status, $LogLabel)
    return [pscustomobject]$result
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

Clear-DiagnosticLogs -WorkspaceRoot $workspaceRoot -LogRoot $logRoot

$raymanRelativePath = '.\.Rayman\rayman.ps1'
$raymanScriptPath = Join-Path $workspaceRoot '.Rayman\rayman.ps1'
$pwshPath = Resolve-CommandExecutablePath -Name 'pwsh'
$hasPwsh = -not [string]::IsNullOrWhiteSpace($pwshPath)
$pwshCommandLabel = if ($hasPwsh) { 'pwsh' } else { 'pwsh (not found)' }

$steps = @(
    [pscustomobject]@{
        StepNumber = 1
        DisplayName = 'Local hash'
        CommandText = 'Get-FileHash -LiteralPath .\.Rayman\rayman.ps1 -Algorithm SHA256'
        FilePath = 'powershell.exe'
        ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', 'Get-FileHash -LiteralPath .\.Rayman\rayman.ps1 -Algorithm SHA256')
        WorkingDirectory = $workspaceRoot
        LogPath = (Join-Path $logRoot '1.log')
        LogLabel = '.\log\1.log'
        RequiredPath = $raymanScriptPath
        RequiredLabel = $raymanRelativePath
        Mode = 'hash'
    },
    [pscustomobject]@{
        StepNumber = 2
        DisplayName = 'Windows PowerShell help'
        CommandText = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\.Rayman\rayman.ps1 help'
        FilePath = 'powershell.exe'
        ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', '.\.Rayman\rayman.ps1', 'help')
        WorkingDirectory = $workspaceRoot
        LogPath = (Join-Path $logRoot '2.log')
        LogLabel = '.\log\2.log'
        RequiredPath = $raymanScriptPath
        RequiredLabel = $raymanRelativePath
        Mode = 'process'
    },
    [pscustomobject]@{
        StepNumber = 3
        DisplayName = 'PowerShell 7 version'
        CommandText = 'pwsh --version'
        FilePath = if ($hasPwsh) { $pwshPath } else { 'pwsh' }
        ArgumentList = @('--version')
        WorkingDirectory = $workspaceRoot
        LogPath = (Join-Path $logRoot '3.log')
        LogLabel = '.\log\3.log'
        RequiredPath = if ($hasPwsh) { $pwshPath } else { Join-Path $workspaceRoot '.Rayman\__missing_pwsh__' }
        RequiredLabel = $pwshCommandLabel
        Mode = 'process'
    },
    [pscustomobject]@{
        StepNumber = 4
        DisplayName = 'PowerShell 7 help'
        CommandText = 'pwsh -NoProfile -File .\.Rayman\rayman.ps1 help'
        FilePath = if ($hasPwsh) { $pwshPath } else { 'pwsh' }
        ArgumentList = @('-NoProfile', '-File', '.\.Rayman\rayman.ps1', 'help')
        WorkingDirectory = $workspaceRoot
        LogPath = (Join-Path $logRoot '4.log')
        LogLabel = '.\log\4.log'
        RequiredPath = if ($hasPwsh) { $pwshPath } else { Join-Path $workspaceRoot '.Rayman\__missing_pwsh__' }
        RequiredLabel = $pwshCommandLabel
        Mode = 'process'
    }
)

$results = New-Object System.Collections.Generic.List[object]
foreach ($step in $steps) {
    $results.Add((Invoke-DiagnosticStep -StepNumber $step.StepNumber -DisplayName $step.DisplayName -CommandText $step.CommandText -FilePath $step.FilePath -ArgumentList $step.ArgumentList -WorkingDirectory $step.WorkingDirectory -LogPath $step.LogPath -LogLabel $step.LogLabel -RequiredPath $step.RequiredPath -RequiredLabel $step.RequiredLabel -Mode $step.Mode)) | Out-Null
}

Write-Host ''
Write-Host 'Summary:'
foreach ($result in $results) {
    Write-Host ('Step {0}: {1} exit={2} {3}' -f $result.StepNumber, $result.Status, $result.ExitCode, $result.LogLabel)
}
