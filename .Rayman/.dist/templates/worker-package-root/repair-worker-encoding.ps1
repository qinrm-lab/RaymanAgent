Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)

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

function Add-RepairLogSection {
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

function Read-TextWithFallback {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)

    try {
        $text = $utf8Strict.GetString($bytes)
    } catch {
        $text = [System.Text.Encoding]::Default.GetString($bytes)
    }

    while (-not [string]::IsNullOrEmpty($text) -and [int][char]$text[0] -eq 65279) {
        $text = $text.Substring(1)
    }

    return $text
}

function Convert-FileToUtf8Bom {
    param([string]$Path)

    $originalBytes = [System.IO.File]::ReadAllBytes($Path)
    $hasUtf8Bom = $originalBytes.Length -ge 3 -and $originalBytes[0] -eq 239 -and $originalBytes[1] -eq 187 -and $originalBytes[2] -eq 191
    $text = Read-TextWithFallback -Path $Path
    [System.IO.File]::WriteAllText($Path, $text, $Utf8Bom)

    return [pscustomobject]@{
        Path = $Path
        HadUtf8Bom = $hasUtf8Bom
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

$repairLogPath = Join-Path $logRoot 'repair-encoding.log'
Write-LogText -Path $repairLogPath -Content ((Join-LogLines -Lines @(
    ('StartedAt: {0}' -f (Get-Date).ToString('o')),
    ('MachineName: {0}' -f $env:COMPUTERNAME),
    ('UserName: {0}' -f $env:USERNAME),
    ('WorkspaceRoot: {0}' -f $workspaceRoot),
    ''
)) + [Environment]::NewLine)

$targets = New-Object System.Collections.Generic.List[string]

$raymanRoot = Join-Path $workspaceRoot '.Rayman'
if (Test-Path -LiteralPath $raymanRoot -PathType Container) {
    foreach ($file in @(Get-ChildItem -LiteralPath $raymanRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') })) {
        $targets.Add($file.FullName) | Out-Null
    }
}

foreach ($rootFileName in @('.rayman.env.ps1', 'all.ps1', 'collect-worker-diag.ps1', 'repair-worker-encoding.ps1')) {
    $rootFilePath = Join-Path $workspaceRoot $rootFileName
    if (Test-Path -LiteralPath $rootFilePath -PathType Leaf) {
        $targets.Add($rootFilePath) | Out-Null
    }
}

$uniqueTargets = @($targets | Sort-Object -Unique)
$updated = New-Object System.Collections.Generic.List[object]

foreach ($targetPath in $uniqueTargets) {
    try {
        $updated.Add((Convert-FileToUtf8Bom -Path $targetPath)) | Out-Null
    } catch {
        Add-RepairLogSection -Path $repairLogPath -Title 'ERROR' -Content ('{0}: {1}' -f $targetPath, $_.Exception.Message)
    }
}

$summaryLines = New-Object System.Collections.Generic.List[string]
$summaryLines.Add(('FilesVisited: {0}' -f $uniqueTargets.Count)) | Out-Null
$summaryLines.Add(('FilesRewritten: {0}' -f $updated.Count)) | Out-Null
$summaryLines.Add('') | Out-Null
foreach ($item in $updated) {
    $summaryLines.Add(('{0} | previous_utf8_bom={1}' -f $item.Path, $item.HadUtf8Bom)) | Out-Null
}
Add-RepairLogSection -Path $repairLogPath -Title 'REWRITE_SUMMARY' -Content (Join-LogLines -Lines @($summaryLines.ToArray()))

$diagScriptPath = Join-Path $workspaceRoot 'collect-worker-diag.ps1'
if (Test-Path -LiteralPath $diagScriptPath -PathType Leaf) {
    Add-RepairLogSection -Path $repairLogPath -Title 'NEXT' -Content 'Running collect-worker-diag.ps1 after encoding repair.'
    $diagOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $diagScriptPath 2>&1 | Out-String
    Add-RepairLogSection -Path $repairLogPath -Title 'DIAG_STDOUT' -Content $diagOutput
} else {
    Add-RepairLogSection -Path $repairLogPath -Title 'NEXT' -Content 'collect-worker-diag.ps1 not found; skipped post-repair diagnostics.'
}

Append-LogText -Path $repairLogPath -Content ((Join-LogLines -Lines @(
    ('FinishedAt: {0}' -f (Get-Date).ToString('o')),
    ''
)) + [Environment]::NewLine)

Write-Host 'Repair complete.'
Write-Host 'Logs:'
Write-Host '  .\log\repair-encoding.log'
Write-Host '  .\log\1.log'
Write-Host '  .\log\2.log'
Write-Host '  .\log\3.log'
Write-Host '  .\log\4.log'
