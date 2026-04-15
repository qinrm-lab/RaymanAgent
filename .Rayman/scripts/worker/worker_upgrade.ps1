param(
  [string]$WorkspaceRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path,
  [ValidateSet('build-package', 'apply', 'apply-and-restart')][string]$Action = 'build-package',
  [string]$PackagePath = '',
  [int]$WorkerHostPid = 0,
  [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'worker_common.ps1')

function Copy-RaymanWorkerUpgradeContent {
  param(
    [string]$SourceRoot,
    [string]$DestinationRoot,
    [string[]]$ExcludeNames = @()
  )

  $resolvedSourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
  Ensure-RaymanWorkerDirectory -Path $DestinationRoot
  foreach ($child in @(Get-ChildItem -LiteralPath $resolvedSourceRoot -Force -ErrorAction SilentlyContinue)) {
    if ($ExcludeNames -contains [string]$child.Name) {
      continue
    }
    Copy-Item -LiteralPath $child.FullName -Destination (Join-Path $DestinationRoot $child.Name) -Recurse -Force
  }
}

function Get-RaymanWorkerUpgradeTempRoot {
  param([string]$WorkspaceRoot)

  $path = Join-Path (Get-RaymanWorkerHostRuntimeRoot -WorkspaceRoot $WorkspaceRoot) 'upgrade-temp'
  Ensure-RaymanWorkerDirectory -Path $path
  return $path
}

function New-RaymanWorkerUpgradePackage {
  param(
    [string]$WorkspaceRoot,
    [string]$OutFile = ''
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $raymanRoot = Join-Path $resolvedRoot '.Rayman'
  $tempRoot = Get-RaymanWorkerUpgradeTempRoot -WorkspaceRoot $resolvedRoot
  $packageId = [Guid]::NewGuid().ToString('n')
  $stageRoot = Join-Path $tempRoot ("package-{0}" -f $packageId)
  Ensure-RaymanWorkerDirectory -Path $stageRoot

  Copy-RaymanWorkerUpgradeContent -SourceRoot $raymanRoot -DestinationRoot $stageRoot -ExcludeNames @('runtime', 'state', 'logs', 'temp', 'tmp')

  if ([string]::IsNullOrWhiteSpace([string]$OutFile)) {
    $OutFile = Join-Path $tempRoot ("rayman-upgrade-{0}.zip" -f $packageId)
  }
  if (Test-Path -LiteralPath $OutFile -PathType Leaf) {
    Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
  }

  Compress-Archive -Path (Join-Path $stageRoot '*') -DestinationPath $OutFile -Force
  return [pscustomobject]@{
    schema = 'rayman.worker.upgrade_package.v1'
    generated_at = (Get-Date).ToString('o')
    package_id = $packageId
    package_path = $OutFile
  }
}

function Install-RaymanWorkerUpgradePackage {
  param(
    [string]$WorkspaceRoot,
    [string]$PackagePath
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $resolvedPackage = (Resolve-Path -LiteralPath $PackagePath).Path
  $tempRoot = Get-RaymanWorkerUpgradeTempRoot -WorkspaceRoot $resolvedRoot
  $extractRoot = Join-Path $tempRoot ("apply-{0}" -f [Guid]::NewGuid().ToString('n'))
  Ensure-RaymanWorkerDirectory -Path $extractRoot
  Expand-Archive -LiteralPath $resolvedPackage -DestinationPath $extractRoot -Force

  $raymanRoot = Join-Path $resolvedRoot '.Rayman'
  $previousVersion = Get-RaymanWorkerVersion -WorkspaceRoot $resolvedRoot
  Copy-RaymanWorkerUpgradeContent -SourceRoot $extractRoot -DestinationRoot $raymanRoot
  $report = [pscustomobject]@{
    schema = 'rayman.worker.upgrade.last.v1'
    generated_at = (Get-Date).ToString('o')
    package_path = $resolvedPackage
    workspace_root = $resolvedRoot
    previous_version = $previousVersion
    current_version = (Get-RaymanWorkerVersion -WorkspaceRoot $resolvedRoot)
    restarted = $false
  }
  Write-RaymanWorkerJsonFile -Path (Get-RaymanWorkerUpgradeLastPath -WorkspaceRoot $resolvedRoot) -Value $report
  return $report
}

function Invoke-RaymanWorkerUpgradeAndRestart {
  param(
    [string]$WorkspaceRoot,
    [string]$PackagePath,
    [int]$WorkerHostPid = 0
  )

  Start-Sleep -Milliseconds 800
  if ($WorkerHostPid -gt 0) {
    try {
      Stop-Process -Id $WorkerHostPid -Force -ErrorAction SilentlyContinue
      Start-Sleep -Milliseconds 500
    } catch {}
  }

  $report = Install-RaymanWorkerUpgradePackage -WorkspaceRoot $WorkspaceRoot -PackagePath $PackagePath
  $vsdbgStatus = Ensure-RaymanWorkerVsdbg -WorkspaceRoot $WorkspaceRoot
  $workerHostScript = Join-Path $WorkspaceRoot '.Rayman\scripts\worker\worker_host.ps1'
  $psHost = if (Get-Command Resolve-RaymanPowerShellHost -ErrorAction SilentlyContinue) {
    Resolve-RaymanPowerShellHost
  } else {
    'powershell.exe'
  }
  Start-Process -FilePath $psHost -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $workerHostScript, '-WorkspaceRoot', $WorkspaceRoot) -WindowStyle Hidden | Out-Null

  $updated = Read-RaymanWorkerJsonFile -Path (Get-RaymanWorkerUpgradeLastPath -WorkspaceRoot $WorkspaceRoot)
  if ($null -eq $updated) {
    $updated = $report
  }
  $updated.restarted = $true
  $updated | Add-Member -MemberType NoteProperty -Name debugger_ready -Value ([bool]$vsdbgStatus.debugger_ready) -Force
  $updated | Add-Member -MemberType NoteProperty -Name debugger_path -Value ([string]$vsdbgStatus.debugger_path) -Force
  if ($vsdbgStatus.PSObject.Properties['debugger_error']) {
    $updated | Add-Member -MemberType NoteProperty -Name debugger_error -Value ([string]$vsdbgStatus.debugger_error) -Force
  }
  Write-RaymanWorkerJsonFile -Path (Get-RaymanWorkerUpgradeLastPath -WorkspaceRoot $WorkspaceRoot) -Value $updated
  return $updated
}

if (-not $NoMain) {
  $WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  switch ($Action) {
    'build-package' {
      New-RaymanWorkerUpgradePackage -WorkspaceRoot $WorkspaceRoot -OutFile $PackagePath | ConvertTo-Json -Depth 8
      break
    }
    'apply' {
      Install-RaymanWorkerUpgradePackage -WorkspaceRoot $WorkspaceRoot -PackagePath $PackagePath | ConvertTo-Json -Depth 8
      break
    }
    'apply-and-restart' {
      Invoke-RaymanWorkerUpgradeAndRestart -WorkspaceRoot $WorkspaceRoot -PackagePath $PackagePath -WorkerHostPid $WorkerHostPid | ConvertTo-Json -Depth 8
      break
    }
  }
}
