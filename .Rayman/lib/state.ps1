<#
.Rayman/lib/state.ps1
Minimal state library: Save-State, Load-State, Apply-State, Rollback-State
#>

function Ensure-TransferDir {
    param()
    $root = Split-Path -Parent $MyInvocation.MyCommand.Definition
    $transfer = Join-Path $root '..\state\transfer' | Resolve-Path -ErrorAction SilentlyContinue
    if (-not $transfer) {
        $base = Join-Path $root '..\state' | Resolve-Path -ErrorAction SilentlyContinue
        if (-not $base) { New-Item -ItemType Directory -Path (Join-Path $root '..\state') | Out-Null }
        New-Item -ItemType Directory -Path (Join-Path $root '..\state\transfer') -Force | Out-Null
        $transfer = Join-Path $root '..\state\transfer'
    }
    return (Resolve-Path $transfer).ProviderPath
}

function Export-State {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Alias
    )

    $transferDir = Ensure-TransferDir
    $outFile = Join-Path $transferDir ($Alias + '.json')

    # Capture basic env vars (PATH + RAYMAN_*)
    $envCapture = @{}
    $envCapture.PATH = $env:PATH
    Get-ChildItem env: | Where-Object { $_.Name -like 'RAYMAN*' } | ForEach-Object { $envCapture[$_.Name] = $_.Value }

    # Capture .Rayman files listing
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
    $raymanRoot = Join-Path $scriptRoot '..' | Resolve-Path -ErrorAction SilentlyContinue
    $raymanFiles = @()
    if ($raymanRoot) { Get-ChildItem -Path $raymanRoot -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $raymanFiles += $_.FullName } }

    # Try to capture installed packages via winget (best-effort)
    $installed = @()
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        try {
            $w = winget list 2>$null | Out-String
            $installed = $w -split "`n" | Where-Object { $_ -and ($_ -notmatch "^Name") }
        } catch { $installed = @() }
    }

    $state = [ordered]@{
        Alias = $Alias
        Timestamp = (Get-Date).ToString('o')
        Env = $envCapture
        Installed = $installed
        RaymanFiles = $raymanFiles
    }

    $json = $state | ConvertTo-Json -Depth 5
    $json | Out-File -FilePath $outFile -Encoding UTF8
    Write-Host "Exported state to $outFile"
    return $outFile
}

function Load-StateFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "State file not found: $Path" }
    $txt = Get-Content -Raw -Path $Path -ErrorAction Stop
    return $txt | ConvertFrom-Json
}

function Import-State {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Alias,
        [switch]$DryRun,
        [switch]$AutoInstall
    )

    $transferDir = Ensure-TransferDir
    $file = Join-Path $transferDir ($Alias + '.json')
    if (-not (Test-Path $file)) { Write-Error "Snapshot not found: $file"; return }
    $state = Load-StateFile -Path $file

    # Prepare dry-run summary
    $missingEnv = @()
    foreach ($name in $state.Env.PSObject.Properties.Name) {
           $curVal = [System.Environment]::GetEnvironmentVariable($name)
           if (-not $curVal) { $missingEnv += $name }
    }

    $missingPackages = @()
    if ($state.Installed) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            $current = (winget list 2>$null | Out-String) -split "`n"
            foreach ($line in $state.Installed) {
                $name = $line.Trim()
                if ($name -and ($current -notcontains $line)) { $missingPackages += $name }
            }
        }
    }

    Write-Host "Import summary for alias '$($state.Alias)' (exported: $($state.Timestamp))"
    Write-Host "  Missing env vars: $($missingEnv.Count)"
    if ($missingEnv.Count -gt 0) { $missingEnv | ForEach-Object { Write-Host "    $_" } }
    Write-Host "  Missing packages (best-effort): $($missingPackages.Count)"
    if ($missingPackages.Count -gt 0) { $missingPackages | ForEach-Object { Write-Host "    $_" } }

    if ($DryRun) { Write-Host "Dry-run requested; no changes applied."; return }

    # Create a pre-import backup snapshot to allow rollback
    $backupAlias = "preimport-$(Get-Date -Format 'yyyyMMddHHmmss')"
    try {
        Export-State -Alias $backupAlias | Out-Null
        Write-Host "Created pre-import backup snapshot: $backupAlias"
    } catch { Write-Warning "Failed to create backup snapshot: $_" }

    try {
        Apply-State -StateObject $state -AutoInstall:$AutoInstall
        Write-Host "Import completed."
    } catch {
        Write-Error "Import failed: $_. Attempting rollback..."
        try { Rollback-State -Alias $backupAlias } catch { Write-Error "Rollback also failed: $_" }
        return
    }

    # Try to restart watchers if helper exists
    try { Restart-Watchers } catch { Write-Warning "Restart-Watchers failed or not implemented: $_" }
}

function Apply-State {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object]$StateObject,
        [switch]$AutoInstall
    )

    # Apply env vars (PATH appended, RAYMAN_* set)
    foreach ($name in $StateObject.Env.PSObject.Properties.Name) {
        if ($name -eq 'PATH') {
            if ($env:PATH -notlike $StateObject.Env.PATH) {
                $env:PATH = $env:PATH + ';' + $StateObject.Env.PATH
                Write-Host "Appended PATH from snapshot"
            }
        } else {
                $curVal = [System.Environment]::GetEnvironmentVariable($name)
                if (-not $curVal) {
                Write-Host "Setting env $name"
                setx $name $StateObject.Env[$name] | Out-Null
            }
        }
    }

    # Install missing packages if requested (best-effort)
    $missingPackages = @()
    if ($StateObject.Installed -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        $current = (winget list 2>$null | Out-String) -split "`n"
        foreach ($line in $StateObject.Installed) {
            $name = $line.Trim()
            if ($name -and ($current -notcontains $line)) { $missingPackages += $name }
        }
        if ($AutoInstall -and $missingPackages.Count -gt 0) {
            foreach ($p in $missingPackages) {
                Write-Host "Attempting to install: $p"
                try { winget install --exact --id $p -e } catch { Write-Warning "Install failed for $p; manual intervention required." }
            }
        } else {
            if ($missingPackages.Count -gt 0) { Write-Host "Missing packages (not auto-installed):"; $missingPackages | ForEach-Object { Write-Host "  $_" } }
        }
    }

    Write-Host "Apply-State: env and package steps completed."

function Verify-Transfer {
    param([string]$From, [string]$To)
    $transferDir = Ensure-TransferDir
    $f1 = Join-Path $transferDir ($From + '.json')
    $f2 = Join-Path $transferDir ($To + '.json')
    if (-not (Test-Path $f1)) { Write-Error "From snapshot not found: $f1"; return }
    if (-not (Test-Path $f2)) { Write-Error "To snapshot not found: $f2"; return }
    $s1 = Load-StateFile -Path $f1
    $s2 = Load-StateFile -Path $f2

    Write-Host "Verify transfer: $From -> $To"
    Write-Host "  $From installed lines: $($s1.Installed.Count)"
    Write-Host "  $To installed lines: $($s2.Installed.Count)"
    # Further diffs can be implemented as needed
}

function Restart-Watchers {
    param()
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
    $workspaceRoot = Join-Path $scriptRoot '..'
    $stopScript = Join-Path $scriptRoot '..\scripts\watch\stop_background_watchers.ps1'
    $startScript = Join-Path $scriptRoot '..\scripts\watch\start_background_watchers.ps1'

    if (Test-Path $stopScript) {
        Write-Host "Stopping watchers..."
        & $stopScript -WorkspaceRoot $workspaceRoot -IncludeResidualCleanup:$true
    }
    if (Test-Path $startScript) {
        Write-Host "Starting watchers..."
        & $startScript -WorkspaceRoot $workspaceRoot
    }
}

function Rollback-State {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Alias
    )

    $transferDir = Ensure-TransferDir
    $file = Join-Path $transferDir ($Alias + '.json')
    if (-not (Test-Path $file)) { Write-Error "Rollback snapshot not found: $file"; return }
    $backupState = Load-StateFile -Path $file
    try {
        Write-Host "Applying rollback snapshot: $Alias"
        Apply-State -StateObject $backupState -AutoInstall:$false
        Write-Host "Rollback applied. You may need to restart shells/watchers."
    } catch { Write-Error "Rollback failed: $_" }
}
}
