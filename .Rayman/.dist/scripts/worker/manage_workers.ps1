param(
  [string]$WorkspaceRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path,
  [Parameter(Position = 0)][string]$Action = 'status',
  [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$CliArgs,
  [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$savedWorkerCliState = @{
  WorkspaceRoot = $WorkspaceRoot
  Action = $Action
  CliArgs = @($CliArgs)
  NoMain = [bool]$NoMain
}

. (Join-Path $PSScriptRoot 'worker_common.ps1')
. (Join-Path $PSScriptRoot 'worker_sync.ps1') -NoMain
. (Join-Path $PSScriptRoot 'worker_upgrade.ps1') -NoMain

$WorkspaceRoot = [string]$savedWorkerCliState.WorkspaceRoot
$Action = [string]$savedWorkerCliState.Action
$CliArgs = @($savedWorkerCliState.CliArgs)
$NoMain = [bool]$savedWorkerCliState.NoMain

function Split-RaymanWorkerCommandTail {
  param([string[]]$Arguments)

  $before = New-Object System.Collections.Generic.List[string]
  $after = New-Object System.Collections.Generic.List[string]
  $seenSeparator = $false
  foreach ($arg in @($Arguments)) {
    if (-not $seenSeparator -and [string]$arg -eq '--') {
      $seenSeparator = $true
      continue
    }
    if ($seenSeparator) {
      $after.Add([string]$arg) | Out-Null
    } else {
      $before.Add([string]$arg) | Out-Null
    }
  }

  return [pscustomobject]@{
    options = @($before.ToArray())
    remainder = @($after.ToArray())
  }
}

function Resolve-RaymanWorkerSelection {
  param(
    [string]$WorkspaceRoot,
    [string]$WorkerId,
    [string]$WorkerName,
    [switch]$AllowActive
  )

  $worker = Resolve-RaymanWorkerBySelector -WorkspaceRoot $WorkspaceRoot -WorkerId $WorkerId -WorkerName $WorkerName -AllowActive:$AllowActive
  if ($null -eq $worker) {
    $registryWorkers = @(Get-RaymanWorkerRegistryDocument -WorkspaceRoot $WorkspaceRoot).workers
    if ($registryWorkers.Count -eq 1 -and [string]::IsNullOrWhiteSpace([string]$WorkerId) -and [string]::IsNullOrWhiteSpace([string]$WorkerName)) {
      return $registryWorkers[0]
    }
    throw 'worker not found; run `rayman.ps1 worker discover` first.'
  }
  return $worker
}

function Format-RaymanWorkerCommandText {
  param([string[]]$CommandParts)

  return ((@($CommandParts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ' ').Trim())
}

function New-RaymanWorkerCliErrorResult {
  param(
    [string]$Action,
    [System.Management.Automation.ErrorRecord]$ErrorRecord
  )

  $payload = [ordered]@{
    schema = 'rayman.worker.cli_error.v1'
    generated_at = (Get-Date).ToString('o')
    action = [string]$Action
    error = [string]$ErrorRecord.Exception.Message
  }
  if ($null -ne $ErrorRecord.Exception -and $null -ne $ErrorRecord.Exception.Data -and $ErrorRecord.Exception.Data.Contains('rayman_payload')) {
    $payload['remote_error'] = $ErrorRecord.Exception.Data['rayman_payload']
  }
  return [pscustomobject]$payload
}

function Install-RaymanLocalWorker {
  param([string]$WorkspaceRoot)

  if (-not (Test-RaymanWorkerWindowsHost)) {
    throw 'worker install-local requires Windows.'
  }

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $workerHostScript = Join-Path $resolvedRoot '.Rayman\scripts\worker\worker_host.ps1'
  if (-not (Test-Path -LiteralPath $workerHostScript -PathType Leaf)) {
    throw ("worker host script missing: {0}" -f $workerHostScript)
  }

  $psHost = if (Get-Command Resolve-RaymanPowerShellHost -ErrorAction SilentlyContinue) {
    Resolve-RaymanPowerShellHost
  } else {
    'powershell.exe'
  }

  $taskPath = Get-RaymanWorkerTaskPath -WorkspaceRoot $resolvedRoot
  $taskName = 'Rayman Worker'
  $userName = Get-RaymanWorkerCurrentUser
  $actionArguments = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $workerHostScript,
    '-WorkspaceRoot',
    $resolvedRoot
  )

  $taskAction = New-ScheduledTaskAction -Execute $psHost -Argument (Format-RaymanWorkerCommandText -CommandParts $actionArguments)
  $taskTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userName
  $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
  Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Action $taskAction -Trigger $taskTrigger -Settings $taskSettings -Description 'Rayman Worker login autostart' -Force | Out-Null

  Set-RaymanWorkerAttachedSyncManifest -WorkspaceRoot $resolvedRoot | Out-Null
  $vsdbgStatus = Ensure-RaymanWorkerVsdbg -WorkspaceRoot $resolvedRoot
  Start-Process -FilePath $psHost -ArgumentList $actionArguments -WindowStyle Hidden | Out-Null
  Start-Sleep -Milliseconds 800

  return [pscustomobject]@{
    schema = 'rayman.worker.install.result.v1'
    generated_at = (Get-Date).ToString('o')
    worker_id = (Get-RaymanWorkerStableId -WorkspaceRoot $resolvedRoot)
    worker_name = (Get-RaymanWorkerDisplayName -WorkspaceRoot $resolvedRoot)
    workspace_root = $resolvedRoot
    task_path = $taskPath
    task_name = $taskName
    power_shell_host = $psHost
    debugger_ready = [bool]$vsdbgStatus.debugger_ready
    debugger_path = [string]$vsdbgStatus.debugger_path
    debugger_error = if ($vsdbgStatus.PSObject.Properties['debugger_error']) { [string]$vsdbgStatus.debugger_error } else { '' }
  }
}

function Uninstall-RaymanLocalWorker {
  param([string]$WorkspaceRoot)

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $taskPath = Get-RaymanWorkerTaskPath -WorkspaceRoot $resolvedRoot
  $taskName = 'Rayman Worker'
  try {
    Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
  } catch {}

  $status = Read-RaymanWorkerJsonFile -Path (Get-RaymanWorkerHostStatusPath -WorkspaceRoot $resolvedRoot)
  if ($null -ne $status -and $status.PSObject.Properties['process_id']) {
    try { Stop-Process -Id ([int]$status.process_id) -Force -ErrorAction SilentlyContinue } catch {}
  }

  return [pscustomobject]@{
    schema = 'rayman.worker.uninstall.result.v1'
    generated_at = (Get-Date).ToString('o')
    workspace_root = $resolvedRoot
    task_path = $taskPath
    task_name = $taskName
  }
}

function Discover-RaymanWorkers {
  param(
    [string]$WorkspaceRoot,
    [int]$ListenSeconds
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $port = Get-RaymanWorkerDiscoveryPort
  $udp = New-Object System.Net.Sockets.UdpClient
  $udp.Client.ExclusiveAddressUse = $false
  $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
  $udp.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $port))

  $workers = New-Object System.Collections.Generic.List[object]
  $deadline = (Get-Date).AddSeconds($ListenSeconds)
  try {
    while ((Get-Date) -lt $deadline) {
      if ($udp.Available -le 0) {
        Start-Sleep -Milliseconds 200
        continue
      }
      $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
      $bytes = $udp.Receive([ref]$remote)
      $text = [System.Text.Encoding]::UTF8.GetString($bytes)
      try {
        $payload = $text | ConvertFrom-Json -ErrorAction Stop
      } catch {
        continue
      }
      if ([string]$payload.schema -ne 'rayman.worker.beacon.v1') { continue }
      if (-not $payload.PSObject.Properties['address'] -or [string]::IsNullOrWhiteSpace([string]$payload.address)) {
        $payload | Add-Member -MemberType NoteProperty -Name address -Value ([string]$remote.Address.IPAddressToString) -Force
      }
      $workers.Add($payload) | Out-Null
    }
  } finally {
    $udp.Dispose()
  }

  $discoveredWorkers = @($workers.ToArray())
  if ($discoveredWorkers.Count -eq 0) {
    try {
      $loopbackStatus = Invoke-RaymanWorkerControlRequest -Worker ([pscustomobject]@{
            address = '127.0.0.1'
            control_port = (Get-RaymanWorkerControlPort)
            control_url = ('http://127.0.0.1:{0}/' -f (Get-RaymanWorkerControlPort))
          }) -Method GET -Path '/status' -TimeoutSeconds 5
      if ($null -ne $loopbackStatus -and [string]$loopbackStatus.schema -eq 'rayman.worker.status.v1') {
        $discoveredWorkers = @([pscustomobject]@{
              worker_id = [string]$loopbackStatus.worker_id
              worker_name = [string]$loopbackStatus.worker_name
              machine_name = [string]$loopbackStatus.machine_name
              user_name = [string]$loopbackStatus.user_name
              version = [string]$loopbackStatus.version
              workspace_root = [string]$loopbackStatus.workspace_root
              workspace_name = [string]$loopbackStatus.workspace_name
              workspace_mode = [string]$loopbackStatus.workspace_mode
              interactive_session = [bool]$loopbackStatus.interactive_session
              address = [string]$loopbackStatus.address
              discovery_port = if ($loopbackStatus.PSObject.Properties['discovery']) { [int]$loopbackStatus.discovery.port } else { $port }
              control_port = if ($loopbackStatus.PSObject.Properties['control']) { [int]$loopbackStatus.control.port } else { (Get-RaymanWorkerControlPort) }
              control_url = if ($loopbackStatus.PSObject.Properties['control']) { [string]$loopbackStatus.control.base_url } else { ('http://127.0.0.1:{0}/' -f (Get-RaymanWorkerControlPort)) }
              debugger_ready = if ($loopbackStatus.PSObject.Properties['debugger_ready']) { [bool]$loopbackStatus.debugger_ready } else { $false }
              debugger_path = if ($loopbackStatus.PSObject.Properties['debugger_path']) { [string]$loopbackStatus.debugger_path } else { '' }
              debugger_error = if ($loopbackStatus.PSObject.Properties['debugger_error']) { [string]$loopbackStatus.debugger_error } else { '' }
              capabilities = $loopbackStatus.capabilities
              git = $loopbackStatus.git
            })
      }
    } catch {}
  }

  $merged = Merge-RaymanWorkerRegistry -WorkspaceRoot $resolvedRoot -Workers $discoveredWorkers
  $summary = [pscustomobject]@{
    schema = 'rayman.worker.discovery.last.v1'
    generated_at = (Get-Date).ToString('o')
    workspace_root = $resolvedRoot
    listen_seconds = $ListenSeconds
    workers = @($merged.workers)
  }
  Save-RaymanWorkerDiscoverySummary -WorkspaceRoot $resolvedRoot -Summary $summary
  return $summary
}

function Get-RaymanWorkerLiveStatus {
  param(
    [string]$WorkspaceRoot,
    [object]$Worker
  )

  $status = Invoke-RaymanWorkerControlRequest -Worker $Worker -Method GET -Path '/status' -TimeoutSeconds 10
  if ($null -ne $status) {
    [void](Merge-RaymanWorkerRegistry -WorkspaceRoot $WorkspaceRoot -Workers @([pscustomobject]@{
          worker_id = [string]$status.worker_id
          worker_name = [string]$status.worker_name
          address = [string]$status.address
          control_port = [int]$status.control.port
          control_url = [string]$status.control.base_url
          workspace_root = [string]$status.workspace_root
          workspace_mode = [string]$status.workspace_mode
          version = [string]$status.version
          machine_name = [string]$status.machine_name
          debugger_ready = if ($status.PSObject.Properties['debugger_ready']) { [bool]$status.debugger_ready } else { $false }
          debugger_path = if ($status.PSObject.Properties['debugger_path']) { [string]$status.debugger_path } else { '' }
        }))
  }
  return $status
}

function Invoke-RaymanWorkerSyncAction {
  param(
    [string]$WorkspaceRoot,
    [object]$Worker,
    [string]$Mode
  )

  if ($Mode -eq 'staged') {
    $bundle = New-RaymanWorkerSyncBundle -WorkspaceRoot $WorkspaceRoot
    $syncManifest = Invoke-RaymanWorkerControlRequest -Worker $Worker -Method POST -Path '/sync' -Body ([pscustomobject]@{
          mode = 'staged'
          bundle_name = [System.IO.Path]::GetFileName([string]$bundle.bundle_path)
          bundle_base64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes([string]$bundle.bundle_path))
        }) -TimeoutSeconds 300
    $active = Set-RaymanActiveWorkerRecord -WorkspaceRoot $WorkspaceRoot -Worker $Worker -WorkspaceMode 'staged' -SyncManifest $syncManifest
    return [pscustomobject]@{
      schema = 'rayman.worker.sync.result.v1'
      generated_at = (Get-Date).ToString('o')
      mode = 'staged'
      sync_manifest = $syncManifest
      active = $active
      bundle = $bundle
    }
  }

  $syncManifest = Invoke-RaymanWorkerControlRequest -Worker $Worker -Method POST -Path '/sync' -Body ([pscustomobject]@{
        mode = 'attached'
      }) -TimeoutSeconds 30
  $active = Set-RaymanActiveWorkerRecord -WorkspaceRoot $WorkspaceRoot -Worker $Worker -WorkspaceMode 'attached' -SyncManifest $syncManifest
  return [pscustomobject]@{
    schema = 'rayman.worker.sync.result.v1'
    generated_at = (Get-Date).ToString('o')
    mode = 'attached'
    sync_manifest = $syncManifest
    active = $active
  }
}

function Invoke-RaymanWorkerDebugAction {
  param(
    [string]$WorkspaceRoot,
    [object]$Worker,
    [string]$Mode,
    [string]$Program = '',
    [int]$ProcessId = 0
  )

  $active = Get-RaymanActiveWorkerRecord -WorkspaceRoot $WorkspaceRoot
  $syncManifest = if ($null -ne $active -and $active.PSObject.Properties['sync_manifest']) { $active.sync_manifest } else { $null }
  $manifest = Invoke-RaymanWorkerControlRequest -Worker $Worker -Method POST -Path '/debug' -Body ([pscustomobject]@{
        mode = $Mode
        program = $Program
        process_id = $ProcessId
        sync_manifest = $syncManifest
      }) -TimeoutSeconds 30

  if ($null -ne $manifest -and $manifest.PSObject.Properties['source_file_map']) {
    $map = [ordered]@{}
    foreach ($prop in $manifest.source_file_map.PSObject.Properties) {
      $map[[string]$prop.Name] = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    }
    $manifest.source_file_map = [pscustomobject]$map
  }

  Save-RaymanWorkerDebugManifest -WorkspaceRoot $WorkspaceRoot -Manifest $manifest
  Update-RaymanWorkerLaunchBindings -WorkspaceRoot $WorkspaceRoot -Manifest $manifest | Out-Null
  return $manifest
}

function Invoke-RaymanWorkerUpgradeAction {
  param(
    [string]$WorkspaceRoot,
    [object]$Worker
  )

  $package = New-RaymanWorkerUpgradePackage -WorkspaceRoot $WorkspaceRoot
  $response = Invoke-RaymanWorkerControlRequest -Worker $Worker -Method POST -Path '/upgrade' -Body ([pscustomobject]@{
        package_name = [System.IO.Path]::GetFileName([string]$package.package_path)
        package_base64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes([string]$package.package_path))
      }) -TimeoutSeconds 300

  $status = $null
  $deadline = (Get-Date).AddSeconds(45)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 1500
    try {
      $status = Get-RaymanWorkerLiveStatus -WorkspaceRoot $WorkspaceRoot -Worker $Worker
      if ($null -ne $status) { break }
    } catch {}
  }

  return [pscustomobject]@{
    schema = 'rayman.worker.upgrade.result.v1'
    generated_at = (Get-Date).ToString('o')
    response = $response
    package = $package
    status = $status
  }
}

if (-not $NoMain) {
  $WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  if ($null -eq $CliArgs) { $CliArgs = @() } else { $CliArgs = @($CliArgs) }

  $tail = Split-RaymanWorkerCommandTail -Arguments $CliArgs
  $argsList = @($tail.options)
  $remainder = @($tail.remainder)
  $workerId = ''
  $workerName = ''
  $mode = 'attached'
  $program = ''
  $processId = 0
  $json = $false
  $unparsedArgs = New-Object System.Collections.Generic.List[string]

  for ($i = 0; $i -lt $argsList.Count; $i++) {
    $token = [string]$argsList[$i]
    switch -Regex ($token) {
      '^--?(id)$' { if ($i + 1 -lt $argsList.Count) { $workerId = [string]$argsList[++$i] }; continue }
      '^--?(name)$' { if ($i + 1 -lt $argsList.Count) { $workerName = [string]$argsList[++$i] }; continue }
      '^--?(mode)$' { if ($i + 1 -lt $argsList.Count) { $mode = [string]$argsList[++$i] }; continue }
      '^--?(program)$' { if ($i + 1 -lt $argsList.Count) { $program = [string]$argsList[++$i] }; continue }
      '^--?(process-id|processid)$' { if ($i + 1 -lt $argsList.Count) { $processId = [int][string]$argsList[++$i] }; continue }
      '^--?(json)$' { $json = $true; continue }
      default { $unparsedArgs.Add($token) | Out-Null; continue }
    }
  }

  if ($Action.ToLowerInvariant() -eq 'exec' -and $remainder.Count -eq 0 -and $unparsedArgs.Count -gt 0) {
    $remainder = @($unparsedArgs.ToArray())
  }

  $result = $null
  try {
    switch ($Action.ToLowerInvariant()) {
      'install-local' { $result = Install-RaymanLocalWorker -WorkspaceRoot $WorkspaceRoot; break }
      'uninstall-local' { $result = Uninstall-RaymanLocalWorker -WorkspaceRoot $WorkspaceRoot; break }
      'discover' {
        $result = Discover-RaymanWorkers -WorkspaceRoot $WorkspaceRoot -ListenSeconds (Get-RaymanWorkerDiscoveryListenSeconds)
        break
      }
      'list' {
        $result = Get-RaymanWorkerRegistryDocument -WorkspaceRoot $WorkspaceRoot
        break
      }
      'use' {
        $worker = Resolve-RaymanWorkerSelection -WorkspaceRoot $WorkspaceRoot -WorkerId $workerId -WorkerName $workerName -AllowActive:$false
        $result = Set-RaymanActiveWorkerRecord -WorkspaceRoot $WorkspaceRoot -Worker $worker -WorkspaceMode $mode -SyncManifest $null
        break
      }
      'clear' {
        Clear-RaymanActiveWorkerRecord -WorkspaceRoot $WorkspaceRoot
        $result = [pscustomobject]@{
          schema = 'rayman.worker.clear.result.v1'
          generated_at = (Get-Date).ToString('o')
          workspace_root = $WorkspaceRoot
        }
        break
      }
      'status' {
        $worker = Resolve-RaymanWorkerSelection -WorkspaceRoot $WorkspaceRoot -WorkerId $workerId -WorkerName $workerName -AllowActive
        $result = Get-RaymanWorkerLiveStatus -WorkspaceRoot $WorkspaceRoot -Worker $worker
        break
      }
      'exec' {
        $worker = Resolve-RaymanWorkerSelection -WorkspaceRoot $WorkspaceRoot -WorkerId $workerId -WorkerName $workerName -AllowActive
        if ([string]::IsNullOrWhiteSpace((Format-RaymanWorkerCommandText -CommandParts $remainder))) {
          throw 'worker exec requires `-- <command>`.'
        }
        if ($null -eq (Get-RaymanActiveWorkerRecord -WorkspaceRoot $WorkspaceRoot)) {
          Set-RaymanActiveWorkerRecord -WorkspaceRoot $WorkspaceRoot -Worker $worker -WorkspaceMode $mode -SyncManifest $null | Out-Null
        }
        $result = Invoke-RaymanWorkerRemoteCommand -WorkspaceRoot $WorkspaceRoot -CommandText (Format-RaymanWorkerCommandText -CommandParts $remainder)
        if (-not $json) {
          foreach ($line in @($result.output_lines)) {
            Write-Host $line
          }
        }
        if ($result.exit_code -ne 0) {
          $global:LASTEXITCODE = [int]$result.exit_code
        }
        break
      }
      'sync' {
        $worker = Resolve-RaymanWorkerSelection -WorkspaceRoot $WorkspaceRoot -WorkerId $workerId -WorkerName $workerName -AllowActive
        $result = Invoke-RaymanWorkerSyncAction -WorkspaceRoot $WorkspaceRoot -Worker $worker -Mode $mode
        break
      }
      'debug' {
        $worker = Resolve-RaymanWorkerSelection -WorkspaceRoot $WorkspaceRoot -WorkerId $workerId -WorkerName $workerName -AllowActive
        $result = Invoke-RaymanWorkerDebugAction -WorkspaceRoot $WorkspaceRoot -Worker $worker -Mode $mode -Program $program -ProcessId $processId
        break
      }
      'upgrade' {
        $worker = Resolve-RaymanWorkerSelection -WorkspaceRoot $WorkspaceRoot -WorkerId $workerId -WorkerName $workerName -AllowActive
        $result = Invoke-RaymanWorkerUpgradeAction -WorkspaceRoot $WorkspaceRoot -Worker $worker
        break
      }
      default {
        throw ("unknown worker action: {0}" -f $Action)
      }
    }
  } catch {
    $result = New-RaymanWorkerCliErrorResult -Action $Action -ErrorRecord $_
    $global:LASTEXITCODE = 1
    if ($Action.ToLowerInvariant() -eq 'exec' -and -not $json) {
      Write-Error ([string]$result.error)
    }
  }

  if ($json -or $Action.ToLowerInvariant() -notin @('exec')) {
    $result | ConvertTo-Json -Depth 12
  }
  exit $(if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 })
}
