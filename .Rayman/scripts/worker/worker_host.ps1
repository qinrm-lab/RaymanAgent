param(
  [string]$WorkspaceRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path,
  [switch]$TunnelServer,
  [int]$TunnelPort = 0,
  [string]$VsdbgPath = '',
  [string]$VsdbgArgumentsBase64 = '',
  [string]$WorkingDirectory = '',
  [switch]$NoBeacon,
  [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$savedWorkerHostState = @{
  WorkspaceRoot = $WorkspaceRoot
  TunnelServer = [bool]$TunnelServer
  TunnelPort = $TunnelPort
  VsdbgPath = $VsdbgPath
  VsdbgArgumentsBase64 = $VsdbgArgumentsBase64
  WorkingDirectory = $WorkingDirectory
  NoBeacon = [bool]$NoBeacon
  NoMain = [bool]$NoMain
}

. (Join-Path $PSScriptRoot 'worker_common.ps1')
. (Join-Path $PSScriptRoot 'worker_sync.ps1') -NoMain
. (Join-Path $PSScriptRoot 'worker_upgrade.ps1') -NoMain

$WorkspaceRoot = [string]$savedWorkerHostState.WorkspaceRoot
$TunnelServer = [bool]$savedWorkerHostState.TunnelServer
$TunnelPort = [int]$savedWorkerHostState.TunnelPort
$VsdbgPath = [string]$savedWorkerHostState.VsdbgPath
$VsdbgArgumentsBase64 = [string]$savedWorkerHostState.VsdbgArgumentsBase64
$WorkingDirectory = [string]$savedWorkerHostState.WorkingDirectory
$NoBeacon = [bool]$savedWorkerHostState.NoBeacon
$NoMain = [bool]$savedWorkerHostState.NoMain

function Convert-RaymanWorkerArgsToCommandLine {
  param([string[]]$Arguments)

  return (@($Arguments | ForEach-Object {
        $arg = [string]$_
        if ($arg -match '[\s"]') {
          '"' + ($arg -replace '"', '\"') + '"'
        } else {
          $arg
        }
      }) -join ' ')
}

function Read-RaymanWorkerRequestJson {
  param([System.Net.HttpListenerRequest]$Request)

  if ($null -eq $Request) { return $null }
  $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
  try {
    $raw = $reader.ReadToEnd()
  } finally {
    $reader.Dispose()
  }
  if ([string]::IsNullOrWhiteSpace([string]$raw)) {
    return $null
  }
  return ($raw | ConvertFrom-Json -ErrorAction Stop)
}

function Save-RaymanWorkerRequestBodyToFile {
  param(
    [System.Net.HttpListenerRequest]$Request,
    [string]$Path
  )

  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace([string]$parent)) {
    Ensure-RaymanWorkerDirectory -Path $parent
  }

  $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
  try {
    $Request.InputStream.CopyTo($stream)
  } finally {
    $stream.Dispose()
  }
  return $Path
}

function Write-RaymanWorkerResponse {
  param(
    [System.Net.HttpListenerContext]$Context,
    [int]$StatusCode,
    [object]$Payload
  )

  $Context.Response.StatusCode = $StatusCode
  $Context.Response.ContentType = 'application/json; charset=utf-8'
  $bytes = [System.Text.Encoding]::UTF8.GetBytes((($Payload | ConvertTo-Json -Depth 12).TrimEnd() + "`n"))
  $Context.Response.ContentLength64 = $bytes.Length
  $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $Context.Response.OutputStream.Flush()
  $Context.Response.Close()
}

function Get-RaymanWorkerHeaderValue {
  param(
    [object]$Headers,
    [string]$Name
  )

  if ($null -eq $Headers -or [string]::IsNullOrWhiteSpace([string]$Name)) {
    return ''
  }

  if ($Headers -is [System.Collections.Specialized.NameValueCollection]) {
    $value = $Headers[[string]$Name]
    if ($null -ne $value) {
      return [string]$value
    }
  }

  if ($Headers -is [System.Collections.IDictionary]) {
    foreach ($key in @($Headers.Keys)) {
      if ([string]$key -ieq $Name) {
        return [string]$Headers[$key]
      }
    }
  }

  foreach ($prop in @($Headers.PSObject.Properties)) {
    if ([string]$prop.Name -ieq $Name) {
      return [string]$prop.Value
    }
  }

  return ''
}

function Assert-RaymanWorkerAuthorized {
  param(
    [string]$WorkspaceRoot,
    [object]$Headers
  )

  $resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  if (-not (Test-RaymanWorkerControlAuthRequired -WorkspaceRoot $resolvedWorkspaceRoot)) {
    return
  }

  $expectedToken = [string](Get-RaymanWorkerAuthToken -WorkspaceRoot $resolvedWorkspaceRoot)
  $actualToken = Get-RaymanWorkerHeaderValue -Headers $Headers -Name 'X-Rayman-Worker-Token'
  if ([string]::IsNullOrWhiteSpace([string]$actualToken)) {
    throw ([System.UnauthorizedAccessException]::new('worker auth token is required'))
  }
  if ($actualToken -ne $expectedToken) {
    throw ([System.UnauthorizedAccessException]::new('worker auth token is invalid'))
  }
}

function Get-RaymanWorkerCurrentSyncManifest {
  param([string]$WorkspaceRoot)

  return (Read-RaymanWorkerJsonFile -Path (Get-RaymanWorkerSyncLastPath -WorkspaceRoot $WorkspaceRoot))
}

function Set-RaymanWorkerAttachedSyncManifest {
  param([string]$WorkspaceRoot)

  $manifest = [pscustomobject]@{
    schema = 'rayman.worker.sync_manifest.v1'
    generated_at = (Get-Date).ToString('o')
    mode = 'attached'
    workspace_root = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    staging_root = ''
    cleanup_hint = ''
    rollback_hint = ''
  }
  Write-RaymanWorkerJsonFile -Path (Get-RaymanWorkerSyncLastPath -WorkspaceRoot $WorkspaceRoot) -Value $manifest
  return $manifest
}

function Send-RaymanWorkerBeacon {
  param(
    [string]$WorkspaceRoot,
    [string]$HostStartTime
  )

  $status = Read-RaymanWorkerJsonFile -Path (Get-RaymanWorkerHostStatusPath -WorkspaceRoot $WorkspaceRoot)
  if ($null -eq $status) {
    $status = Get-RaymanWorkerStatusSnapshot -WorkspaceRoot $WorkspaceRoot -SyncManifest (Get-RaymanWorkerCurrentSyncManifest -WorkspaceRoot $WorkspaceRoot) -ProcessId $PID -HostStartTime $HostStartTime
  }
  $payload = Get-RaymanWorkerBeaconPayload -WorkspaceRoot $WorkspaceRoot -SyncManifest (Get-RaymanWorkerCurrentSyncManifest -WorkspaceRoot $WorkspaceRoot) -ProcessId $PID -HostStartTime $HostStartTime -StatusSnapshot $status
  $bytes = [System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 10))
  $udp = New-Object System.Net.Sockets.UdpClient
  try {
    $udp.EnableBroadcast = $true
    $targets = @(Get-RaymanWorkerDiscoveryTargets -WorkspaceRoot $WorkspaceRoot)
    foreach ($target in @($targets)) {
      [void]$udp.Send($bytes, $bytes.Length, $target)
    }
  } finally {
    $udp.Dispose()
  }
  Write-RaymanWorkerJsonFile -Path (Get-RaymanWorkerBeaconLastPath -WorkspaceRoot $WorkspaceRoot) -Value $payload
  return $payload
}

function Start-RaymanWorkerTunnelProcess {
  param(
    [string]$WorkspaceRoot,
    [string]$VsdbgPath,
    [string[]]$VsdbgArguments,
    [string]$WorkingDirectory
  )

  $listener = [System.Net.Sockets.TcpListener]::new((Get-RaymanWorkerBindIPAddress -WorkspaceRoot $WorkspaceRoot), 0)
  $listener.Start()
  $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
  $listener.Stop()

  $argsJson = @($VsdbgArguments) | ConvertTo-Json -Compress
  $argsBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($argsJson))
  $psHost = if (Get-Command Resolve-RaymanPowerShellHost -ErrorAction SilentlyContinue) {
    Resolve-RaymanPowerShellHost
  } else {
    'powershell.exe'
  }

  Start-Process -FilePath $psHost -ArgumentList @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $PSCommandPath,
    '-WorkspaceRoot',
    $WorkspaceRoot,
    '-TunnelServer',
    '-TunnelPort',
    ([string]$port),
    '-VsdbgPath',
    $VsdbgPath,
    '-VsdbgArgumentsBase64',
    $argsBase64,
    '-WorkingDirectory',
    $WorkingDirectory
  ) -WindowStyle Hidden | Out-Null

  return $port
}

function Start-RaymanWorkerDebugTunnelServer {
  param(
    [string]$WorkspaceRoot,
    [int]$TunnelPort,
    [string]$VsdbgPath,
    [string[]]$VsdbgArguments,
    [string]$WorkingDirectory
  )

  if ([string]::IsNullOrWhiteSpace([string]$VsdbgPath)) {
    throw 'vsdbg path is required'
  }
  if (-not (Test-Path -LiteralPath $VsdbgPath -PathType Leaf)) {
    throw ("vsdbg path does not exist: {0}" -f $VsdbgPath)
  }

  $listener = [System.Net.Sockets.TcpListener]::new((Get-RaymanWorkerBindIPAddress -WorkspaceRoot $WorkspaceRoot), $TunnelPort)
  $listener.Start()
  try {
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $VsdbgPath
      $psi.Arguments = Convert-RaymanWorkerArgsToCommandLine -Arguments $VsdbgArguments
      $psi.WorkingDirectory = if ([string]::IsNullOrWhiteSpace([string]$WorkingDirectory)) { (Split-Path -Parent $VsdbgPath) } else { $WorkingDirectory }
      $psi.UseShellExecute = $false
      $psi.RedirectStandardInput = $true
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true

      $process = New-Object System.Diagnostics.Process
      $process.StartInfo = $psi
      [void]$process.Start()

      $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stream)
      $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stream)
      $stdinTask = $stream.CopyToAsync($process.StandardInput.BaseStream)

      while (-not $process.HasExited) {
        if ($stdinTask.IsCompleted) { break }
        Start-Sleep -Milliseconds 200
      }

      try { $process.StandardInput.Close() } catch {}
      try { $stdinTask.Wait(1000) | Out-Null } catch {}
      try { $stdoutTask.Wait(1000) | Out-Null } catch {}
      try { $stderrTask.Wait(1000) | Out-Null } catch {}
      if (-not $process.HasExited) {
        $process.WaitForExit(1000) | Out-Null
      }
    } finally {
      try { $client.Close() } catch {}
    }
  } finally {
    $listener.Stop()
  }
}

function Resolve-RaymanWorkerDebugTunnelSpec {
  param(
    [string]$WorkspaceRoot,
    [object]$Body,
    [object]$Session
  )

  if ($null -eq $Session) {
    throw 'worker debug manifest missing; run `rayman.ps1 worker debug --mode launch|attach` first.'
  }
  if ($Session.PSObject.Properties['debugger_ready'] -and -not [bool]$Session.debugger_ready) {
    $message = if ($Session.PSObject.Properties['debugger_error'] -and -not [string]::IsNullOrWhiteSpace([string]$Session.debugger_error)) {
      [string]$Session.debugger_error
    } else {
      'worker debug manifest indicates that vsdbg is not ready'
    }
    throw $message
  }

  $vsdbgStatus = Ensure-RaymanWorkerVsdbg -WorkspaceRoot $WorkspaceRoot
  if (-not [bool]$vsdbgStatus.debugger_ready) {
    $message = if ($vsdbgStatus.PSObject.Properties['debugger_error'] -and -not [string]::IsNullOrWhiteSpace([string]$vsdbgStatus.debugger_error)) {
      [string]$vsdbgStatus.debugger_error
    } else {
      'vsdbg is not ready'
    }
    throw $message
  }

  $debuggerPath = if ($null -ne $Body -and $Body.PSObject.Properties['debugger_path'] -and -not [string]::IsNullOrWhiteSpace([string]$Body.debugger_path)) {
    [string]$Body.debugger_path
  } elseif ($Session.PSObject.Properties['debugger_path'] -and -not [string]::IsNullOrWhiteSpace([string]$Session.debugger_path)) {
    [string]$Session.debugger_path
  } else {
    [string]$vsdbgStatus.debugger_path
  }
  if ([string]::IsNullOrWhiteSpace([string]$debuggerPath)) {
    throw 'worker debug manifest is missing debugger_path; re-run `rayman.ps1 worker debug --mode launch|attach`.'
  }

  return [pscustomobject]@{
    debugger_path = $debuggerPath
    debugger_arguments = if ($null -ne $Body -and $Body.PSObject.Properties['debugger_arguments']) { @($Body.debugger_arguments | ForEach-Object { [string]$_ }) } else { @() }
    working_directory = if ($null -ne $Body -and $Body.PSObject.Properties['working_directory']) { [string]$Body.working_directory } elseif ($Session.PSObject.Properties['cwd']) { [string]$Session.cwd } else { $WorkspaceRoot }
  }
}

function Invoke-RaymanWorkerRequest {
  param(
    [string]$WorkspaceRoot,
    [System.Net.HttpListenerContext]$Context,
    [string]$HostStartTime
  )

  $request = $Context.Request
  $relativePath = [string]$request.Url.AbsolutePath
  if ([string]::IsNullOrWhiteSpace([string]$relativePath)) {
    $relativePath = '/'
  }
  $method = [string]$request.HttpMethod
  $currentSync = Get-RaymanWorkerCurrentSyncManifest -WorkspaceRoot $WorkspaceRoot
  Assert-RaymanWorkerAuthorized -WorkspaceRoot $WorkspaceRoot -Headers $request.Headers

  switch ("{0} {1}" -f $method.ToUpperInvariant(), $relativePath.ToLowerInvariant()) {
    'GET /status' {
      $status = Get-RaymanWorkerStatusSnapshot -WorkspaceRoot $WorkspaceRoot -SyncManifest $currentSync -ProcessId $PID -HostStartTime $HostStartTime
      Write-RaymanWorkerJsonFile -Path (Get-RaymanWorkerHostStatusPath -WorkspaceRoot $WorkspaceRoot) -Value $status
      return $status
    }
    'POST /exec' {
      $body = Read-RaymanWorkerRequestJson -Request $request
      if ($null -eq $body -or [string]::IsNullOrWhiteSpace([string]$body.command)) {
        throw 'exec command is required'
      }
      $syncManifest = if ($null -ne $body.PSObject.Properties['sync_manifest'] -and $null -ne $body.sync_manifest) { $body.sync_manifest } else { $currentSync }
      $executionRoot = Get-RaymanWorkerExecutionRoot -WorkspaceRoot $WorkspaceRoot -SyncManifest $syncManifest
      $timeoutSeconds = if ($null -ne $body.PSObject.Properties['timeout_seconds']) { [int]$body.timeout_seconds } else { (Get-RaymanWorkerExecutionTimeoutSeconds) }
      $result = Invoke-RaymanWorkerLocalCommand -WorkspaceRoot $WorkspaceRoot -ExecutionRoot $executionRoot -CommandText ([string]$body.command) -TimeoutSeconds $timeoutSeconds
      return [pscustomobject]@{
        schema = 'rayman.worker.exec.result.v1'
        generated_at = (Get-Date).ToString('o')
        success = [bool]$result.success
        exit_code = [int]$result.exit_code
        error_message = [string]$result.error_message
        output_lines = @($result.output_lines)
        execution_root = [string]$result.execution_root
        workspace_mode = if ($null -ne $syncManifest -and $syncManifest.PSObject.Properties['mode']) { [string]$syncManifest.mode } else { 'attached' }
      }
    }
    'PUT /sync/upload' {
      $token = [string]$request.QueryString['token']
      if ([string]::IsNullOrWhiteSpace([string]$token)) {
        throw 'sync upload token is required'
      }
      $destination = Join-Path (Get-RaymanWorkerUploadRoot -WorkspaceRoot $WorkspaceRoot) ("sync-{0}.zip" -f $token)
      Save-RaymanWorkerRequestBodyToFile -Request $request -Path $destination | Out-Null
      return [pscustomobject]@{
        schema = 'rayman.worker.upload.result.v1'
        generated_at = (Get-Date).ToString('o')
        token = $token
        path = $destination
      }
    }
    'POST /sync' {
      $body = Read-RaymanWorkerRequestJson -Request $request
      $mode = if ($null -ne $body -and $body.PSObject.Properties['mode']) { [string]$body.mode } else { 'attached' }
      if ($mode -eq 'staged') {
        $bundlePath = ''
        if ($null -ne $body -and $body.PSObject.Properties['bundle_base64'] -and -not [string]::IsNullOrWhiteSpace([string]$body.bundle_base64)) {
          $token = [Guid]::NewGuid().ToString('n')
          $bundlePath = Join-Path (Get-RaymanWorkerUploadRoot -WorkspaceRoot $WorkspaceRoot) ("sync-{0}.zip" -f $token)
          [System.IO.File]::WriteAllBytes($bundlePath, [Convert]::FromBase64String([string]$body.bundle_base64))
        } else {
          $token = [string]$body.upload_token
          if ([string]::IsNullOrWhiteSpace([string]$token)) {
            throw 'staged sync requires upload_token or bundle_base64'
          }
          $bundlePath = Join-Path (Get-RaymanWorkerUploadRoot -WorkspaceRoot $WorkspaceRoot) ("sync-{0}.zip" -f $token)
        }
        if (-not (Test-Path -LiteralPath $bundlePath -PathType Leaf)) {
          throw ("sync bundle not found: {0}" -f $bundlePath)
        }
        return (Expand-RaymanWorkerSyncBundle -WorkspaceRoot $WorkspaceRoot -BundlePath $bundlePath)
      }
      return (Set-RaymanWorkerAttachedSyncManifest -WorkspaceRoot $WorkspaceRoot)
    }
    'POST /debug' {
      $body = Read-RaymanWorkerRequestJson -Request $request
      $mode = if ($null -ne $body -and $body.PSObject.Properties['mode']) { [string]$body.mode } else { 'launch' }
      $program = if ($null -ne $body -and $body.PSObject.Properties['program']) { [string]$body.program } else { '' }
      $processId = if ($null -ne $body -and $body.PSObject.Properties['process_id']) { [int]$body.process_id } else { 0 }
      $syncManifest = if ($null -ne $body -and $body.PSObject.Properties['sync_manifest'] -and $null -ne $body.sync_manifest) { $body.sync_manifest } else { $currentSync }
      $manifest = New-RaymanWorkerDebugManifest -WorkspaceRoot $WorkspaceRoot -Mode $mode -SyncManifest $syncManifest -Program $program -ProcessId $processId
      Write-RaymanWorkerJsonFile -Path (Get-RaymanWorkerDebugSessionPath -WorkspaceRoot $WorkspaceRoot) -Value $manifest
      return $manifest
    }
    'POST /debug/tunnel' {
      $body = Read-RaymanWorkerRequestJson -Request $request
      $session = Read-RaymanWorkerJsonFile -Path (Get-RaymanWorkerDebugSessionPath -WorkspaceRoot $WorkspaceRoot)
      $tunnelSpec = Resolve-RaymanWorkerDebugTunnelSpec -WorkspaceRoot $WorkspaceRoot -Body $body -Session $session
      $port = Start-RaymanWorkerTunnelProcess -WorkspaceRoot $WorkspaceRoot -VsdbgPath ([string]$tunnelSpec.debugger_path) -VsdbgArguments @($tunnelSpec.debugger_arguments) -WorkingDirectory ([string]$tunnelSpec.working_directory)
      return [pscustomobject]@{
        schema = 'rayman.worker.debug_tunnel.v1'
        generated_at = (Get-Date).ToString('o')
        address = (Get-RaymanWorkerAdvertisedAddress -WorkspaceRoot $WorkspaceRoot)
        port = $port
      }
    }
    'PUT /upgrade/upload' {
      $token = [string]$request.QueryString['token']
      if ([string]::IsNullOrWhiteSpace([string]$token)) {
        throw 'upgrade upload token is required'
      }
      $destination = Join-Path (Get-RaymanWorkerUploadRoot -WorkspaceRoot $WorkspaceRoot) ("upgrade-{0}.zip" -f $token)
      Save-RaymanWorkerRequestBodyToFile -Request $request -Path $destination | Out-Null
      return [pscustomobject]@{
        schema = 'rayman.worker.upload.result.v1'
        generated_at = (Get-Date).ToString('o')
        token = $token
        path = $destination
      }
    }
    'POST /upgrade' {
      $body = Read-RaymanWorkerRequestJson -Request $request
      $packagePath = ''
      if ($null -ne $body -and $body.PSObject.Properties['package_base64'] -and -not [string]::IsNullOrWhiteSpace([string]$body.package_base64)) {
        $token = [Guid]::NewGuid().ToString('n')
        $packagePath = Join-Path (Get-RaymanWorkerUploadRoot -WorkspaceRoot $WorkspaceRoot) ("upgrade-{0}.zip" -f $token)
        [System.IO.File]::WriteAllBytes($packagePath, [Convert]::FromBase64String([string]$body.package_base64))
      } else {
        $token = if ($null -ne $body -and $body.PSObject.Properties['upload_token']) { [string]$body.upload_token } else { '' }
        if ([string]::IsNullOrWhiteSpace([string]$token)) {
          throw 'upgrade requires upload_token or package_base64'
        }
        $packagePath = Join-Path (Get-RaymanWorkerUploadRoot -WorkspaceRoot $WorkspaceRoot) ("upgrade-{0}.zip" -f $token)
      }
      if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        throw ("upgrade package not found: {0}" -f $packagePath)
      }
      $psHost = if (Get-Command Resolve-RaymanPowerShellHost -ErrorAction SilentlyContinue) { Resolve-RaymanPowerShellHost } else { 'powershell.exe' }
      $upgradeScript = Join-Path $WorkspaceRoot '.Rayman\scripts\worker\worker_upgrade.ps1'
      Start-Process -FilePath $psHost -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgradeScript, '-WorkspaceRoot', $WorkspaceRoot, '-Action', 'apply-and-restart', '-PackagePath', $packagePath, '-WorkerHostPid', ([string]$PID)) -WindowStyle Hidden | Out-Null
      return [pscustomobject]@{
        schema = 'rayman.worker.upgrade.accepted.v1'
        generated_at = (Get-Date).ToString('o')
        accepted = $true
        package_path = $packagePath
      }
    }
    default {
      return [pscustomobject]@{
        schema = 'rayman.worker.error.v1'
        generated_at = (Get-Date).ToString('o')
        error = 'not_found'
        path = $relativePath
        method = $method
      }
    }
  }
}

function Find-RaymanWorkerHeaderBoundary {
  param([byte[]]$Bytes)

  for ($i = 0; $i -le ($Bytes.Length - 4); $i++) {
    if ($Bytes[$i] -eq 13 -and $Bytes[$i + 1] -eq 10 -and $Bytes[$i + 2] -eq 13 -and $Bytes[$i + 3] -eq 10) {
      return $i
    }
  }
  return -1
}

function Read-RaymanWorkerTcpBufferedBytes {
  param(
    [System.Net.Sockets.NetworkStream]$Stream,
    [System.IO.MemoryStream]$Buffer,
    [int]$Count
  )

  while (($Buffer.Length - $Buffer.Position) -lt $Count) {
    $chunk = New-Object byte[] 4096
    $read = $Stream.Read($chunk, 0, $chunk.Length)
    if ($read -le 0) {
      throw 'unexpected end of stream while reading request body'
    }
    $existingPosition = $Buffer.Position
    $appendPosition = $Buffer.Length
    $Buffer.Position = $appendPosition
    $Buffer.Write($chunk, 0, $read)
    $Buffer.Position = $existingPosition
  }

  $bytes = New-Object byte[] $Count
  [void]$Buffer.Read($bytes, 0, $Count)
  return $bytes
}

function Read-RaymanWorkerTcpLine {
  param(
    [System.Net.Sockets.NetworkStream]$Stream,
    [System.IO.MemoryStream]$Buffer
  )

  $line = New-Object System.Collections.Generic.List[byte]
  while ($true) {
    $next = Read-RaymanWorkerTcpBufferedBytes -Stream $Stream -Buffer $Buffer -Count 1
    if ($next[0] -eq 10) {
      break
    }
    if ($next[0] -ne 13) {
      $line.Add([byte]$next[0]) | Out-Null
    }
  }
  return [System.Text.Encoding]::ASCII.GetString($line.ToArray())
}

function Read-RaymanWorkerChunkedBody {
  param(
    [System.Net.Sockets.NetworkStream]$Stream,
    [byte[]]$InitialBytes
  )

  $buffer = New-Object System.IO.MemoryStream
  if ($null -ne $InitialBytes -and $InitialBytes.Length -gt 0) {
    $buffer.Write($InitialBytes, 0, $InitialBytes.Length)
  }
  $buffer.Position = 0

  $payload = New-Object System.IO.MemoryStream
  try {
    while ($true) {
      $sizeLine = (Read-RaymanWorkerTcpLine -Stream $Stream -Buffer $buffer).Trim()
      if ([string]::IsNullOrWhiteSpace([string]$sizeLine)) {
        continue
      }

      $hexToken = ([string]$sizeLine -split ';')[0].Trim()
      $chunkSize = 0
      if (-not [int]::TryParse($hexToken, [System.Globalization.NumberStyles]::HexNumber, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$chunkSize)) {
        throw ("invalid chunk size: {0}" -f $sizeLine)
      }
      if ($chunkSize -eq 0) {
        while ($true) {
          $trailerLine = Read-RaymanWorkerTcpLine -Stream $Stream -Buffer $buffer
          if ([string]::IsNullOrWhiteSpace([string]$trailerLine)) {
            break
          }
        }
        break
      }

      $chunkBytes = Read-RaymanWorkerTcpBufferedBytes -Stream $Stream -Buffer $buffer -Count $chunkSize
      $payload.Write($chunkBytes, 0, $chunkBytes.Length)
      $terminator = Read-RaymanWorkerTcpBufferedBytes -Stream $Stream -Buffer $buffer -Count 2
      if ($terminator[0] -ne 13 -or $terminator[1] -ne 10) {
        throw 'invalid chunk terminator'
      }
    }

    return $payload.ToArray()
  } finally {
    $payload.Dispose()
    $buffer.Dispose()
  }
}

function Read-RaymanWorkerTcpRequest {
  param([System.Net.Sockets.TcpClient]$Client)

  $stream = $Client.GetStream()
  $memory = New-Object System.IO.MemoryStream
  $buffer = New-Object byte[] 4096
  $headerBoundary = -1
  while ($headerBoundary -lt 0) {
    $read = $stream.Read($buffer, 0, $buffer.Length)
    if ($read -le 0) {
      throw 'unexpected end of stream while reading request headers'
    }
    $memory.Write($buffer, 0, $read)
    $headerBoundary = Find-RaymanWorkerHeaderBoundary -Bytes $memory.ToArray()
  }

  $allBytes = $memory.ToArray()
  $headerText = [System.Text.Encoding]::ASCII.GetString($allBytes, 0, $headerBoundary + 4)
  $lines = @($headerText -split "`r`n")
  if ($lines.Count -lt 1) {
    throw 'invalid request line'
  }

  $requestLine = [string]$lines[0]
  $parts = @($requestLine -split ' ')
  if ($parts.Count -lt 2) {
    throw ("invalid request line: {0}" -f $requestLine)
  }

  $headers = @{}
  foreach ($line in @($lines | Select-Object -Skip 1)) {
    if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
    $separatorIndex = $line.IndexOf(':')
    if ($separatorIndex -lt 1) { continue }
    $name = $line.Substring(0, $separatorIndex).Trim()
    $value = $line.Substring($separatorIndex + 1).Trim()
    $headers[$name] = $value
  }

  if ($headers.ContainsKey('Expect') -and [string]$headers['Expect'] -match '(?i)100-continue') {
    $continueBytes = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
    $stream.Write($continueBytes, 0, $continueBytes.Length)
    $stream.Flush()
  }

  $contentLength = 0
  if ($headers.ContainsKey('Content-Length')) {
    [void][int]::TryParse([string]$headers['Content-Length'], [ref]$contentLength)
  }

  $bodyStart = $headerBoundary + 4
  $prefetched = [Math]::Max(0, $allBytes.Length - $bodyStart)
  $prefetchedBody = if ($prefetched -gt 0) {
    $bytes = New-Object byte[] $prefetched
    [Array]::Copy($allBytes, $bodyStart, $bytes, 0, $prefetched)
    $bytes
  } else {
    @()
  }

  $bodyBytes = @()
  $offset = 0
  if ($headers.ContainsKey('Transfer-Encoding') -and [string]$headers['Transfer-Encoding'] -match '(?i)chunked') {
    $bodyBytes = Read-RaymanWorkerChunkedBody -Stream $stream -InitialBytes $prefetchedBody
    $offset = $bodyBytes.Length
  } else {
    $bodyBytes = New-Object byte[] $contentLength
    if ($prefetched -gt 0) {
      [Array]::Copy($prefetchedBody, 0, $bodyBytes, 0, [Math]::Min($prefetched, $contentLength))
    }
    $offset = [Math]::Min($prefetched, $contentLength)
    while ($offset -lt $contentLength) {
      $read = $stream.Read($bodyBytes, $offset, $contentLength - $offset)
      if ($read -le 0) { break }
      $offset += $read
    }
  }

  $uri = [System.Uri]::new(('http://rayman.invalid' + [string]$parts[1]))
  $bodyText = if ($contentLength -gt 0) { [System.Text.Encoding]::UTF8.GetString($bodyBytes, 0, $offset) } else { '' }
  $bodyJson = $null
  if (-not [string]::IsNullOrWhiteSpace([string]$bodyText) -and ($headers['Content-Type'] -like 'application/json*' -or [string]::IsNullOrWhiteSpace([string]$headers['Content-Type']))) {
    try {
      $bodyJson = $bodyText | ConvertFrom-Json -ErrorAction Stop
    } catch {
      $bodyJson = $null
    }
  }

  return [pscustomobject]@{
    method = [string]$parts[0]
    raw_target = [string]$parts[1]
    path = [string]$uri.AbsolutePath
    query = $uri.Query.TrimStart('?')
    query_string = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
    headers = $headers
    body_bytes = $bodyBytes
    body_text = $bodyText
    body_json = $bodyJson
  }
}

function Write-RaymanWorkerTcpResponse {
  param(
    [System.Net.Sockets.TcpClient]$Client,
    [int]$StatusCode,
    [object]$Payload
  )

  $reason = switch ($StatusCode) {
    200 { 'OK' }
    401 { 'Unauthorized' }
    404 { 'Not Found' }
    500 { 'Internal Server Error' }
    default { 'OK' }
  }
  $body = (($Payload | ConvertTo-Json -Depth 12).TrimEnd() + "`n")
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
  $header = "HTTP/1.1 $StatusCode $reason`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
  $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
  $stream = $Client.GetStream()
  $stream.Write($headerBytes, 0, $headerBytes.Length)
  $stream.Write($bodyBytes, 0, $bodyBytes.Length)
  $stream.Flush()
}

function Invoke-RaymanWorkerRequestData {
  param(
    [string]$WorkspaceRoot,
    [object]$RequestData,
    [string]$HostStartTime
  )

  $relativePath = [string]$RequestData.path
  $method = [string]$RequestData.method
  $currentSync = Get-RaymanWorkerCurrentSyncManifest -WorkspaceRoot $WorkspaceRoot
  $body = $RequestData.body_json
  Assert-RaymanWorkerAuthorized -WorkspaceRoot $WorkspaceRoot -Headers $RequestData.headers

  switch ("{0} {1}" -f $method.ToUpperInvariant(), $relativePath.ToLowerInvariant()) {
    'GET /status' {
      $status = Get-RaymanWorkerStatusSnapshot -WorkspaceRoot $WorkspaceRoot -SyncManifest $currentSync -ProcessId $PID -HostStartTime $HostStartTime
      Write-RaymanWorkerJsonFile -Path (Get-RaymanWorkerHostStatusPath -WorkspaceRoot $WorkspaceRoot) -Value $status
      return $status
    }
    'POST /exec' {
      if ($null -eq $body -or [string]::IsNullOrWhiteSpace([string]$body.command)) { throw 'exec command is required' }
      $syncManifest = if ($null -ne $body.PSObject.Properties['sync_manifest'] -and $null -ne $body.sync_manifest) { $body.sync_manifest } else { $currentSync }
      $executionRoot = Get-RaymanWorkerExecutionRoot -WorkspaceRoot $WorkspaceRoot -SyncManifest $syncManifest
      $timeoutSeconds = if ($null -ne $body.PSObject.Properties['timeout_seconds']) { [int]$body.timeout_seconds } else { (Get-RaymanWorkerExecutionTimeoutSeconds) }
      $result = Invoke-RaymanWorkerLocalCommand -WorkspaceRoot $WorkspaceRoot -ExecutionRoot $executionRoot -CommandText ([string]$body.command) -TimeoutSeconds $timeoutSeconds
      return [pscustomobject]@{
        schema = 'rayman.worker.exec.result.v1'
        generated_at = (Get-Date).ToString('o')
        success = [bool]$result.success
        exit_code = [int]$result.exit_code
        error_message = [string]$result.error_message
        output_lines = @($result.output_lines)
        execution_root = [string]$result.execution_root
        workspace_mode = if ($null -ne $syncManifest -and $syncManifest.PSObject.Properties['mode']) { [string]$syncManifest.mode } else { 'attached' }
      }
    }
    'PUT /sync/upload' {
      $token = [string]$RequestData.query_string['token']
      if ([string]::IsNullOrWhiteSpace([string]$token)) { throw 'sync upload token is required' }
      $destination = Join-Path (Get-RaymanWorkerUploadRoot -WorkspaceRoot $WorkspaceRoot) ("sync-{0}.zip" -f $token)
      [System.IO.File]::WriteAllBytes($destination, @($RequestData.body_bytes))
      return [pscustomobject]@{
        schema = 'rayman.worker.upload.result.v1'
        generated_at = (Get-Date).ToString('o')
        token = $token
        path = $destination
      }
    }
    'POST /sync' {
      $mode = if ($null -ne $body -and $body.PSObject.Properties['mode']) { [string]$body.mode } else { 'attached' }
      if ($mode -eq 'staged') {
        $bundlePath = ''
        if ($null -ne $body -and $body.PSObject.Properties['bundle_base64'] -and -not [string]::IsNullOrWhiteSpace([string]$body.bundle_base64)) {
          $token = [Guid]::NewGuid().ToString('n')
          $bundlePath = Join-Path (Get-RaymanWorkerUploadRoot -WorkspaceRoot $WorkspaceRoot) ("sync-{0}.zip" -f $token)
          [System.IO.File]::WriteAllBytes($bundlePath, [Convert]::FromBase64String([string]$body.bundle_base64))
        } else {
          $token = [string]$body.upload_token
          if ([string]::IsNullOrWhiteSpace([string]$token)) { throw 'staged sync requires upload_token or bundle_base64' }
          $bundlePath = Join-Path (Get-RaymanWorkerUploadRoot -WorkspaceRoot $WorkspaceRoot) ("sync-{0}.zip" -f $token)
        }
        if (-not (Test-Path -LiteralPath $bundlePath -PathType Leaf)) { throw ("sync bundle not found: {0}" -f $bundlePath) }
        return (Expand-RaymanWorkerSyncBundle -WorkspaceRoot $WorkspaceRoot -BundlePath $bundlePath)
      }
      return (Set-RaymanWorkerAttachedSyncManifest -WorkspaceRoot $WorkspaceRoot)
    }
    'POST /debug' {
      $mode = if ($null -ne $body -and $body.PSObject.Properties['mode']) { [string]$body.mode } else { 'launch' }
      $program = if ($null -ne $body -and $body.PSObject.Properties['program']) { [string]$body.program } else { '' }
      $processId = if ($null -ne $body -and $body.PSObject.Properties['process_id']) { [int]$body.process_id } else { 0 }
      $syncManifest = if ($null -ne $body -and $body.PSObject.Properties['sync_manifest'] -and $null -ne $body.sync_manifest) { $body.sync_manifest } else { $currentSync }
      $manifest = New-RaymanWorkerDebugManifest -WorkspaceRoot $WorkspaceRoot -Mode $mode -SyncManifest $syncManifest -Program $program -ProcessId $processId
      Write-RaymanWorkerJsonFile -Path (Get-RaymanWorkerDebugSessionPath -WorkspaceRoot $WorkspaceRoot) -Value $manifest
      return $manifest
    }
    'POST /debug/tunnel' {
      $session = Read-RaymanWorkerJsonFile -Path (Get-RaymanWorkerDebugSessionPath -WorkspaceRoot $WorkspaceRoot)
      $tunnelSpec = Resolve-RaymanWorkerDebugTunnelSpec -WorkspaceRoot $WorkspaceRoot -Body $body -Session $session
      $port = Start-RaymanWorkerTunnelProcess -WorkspaceRoot $WorkspaceRoot -VsdbgPath ([string]$tunnelSpec.debugger_path) -VsdbgArguments @($tunnelSpec.debugger_arguments) -WorkingDirectory ([string]$tunnelSpec.working_directory)
      return [pscustomobject]@{
        schema = 'rayman.worker.debug_tunnel.v1'
        generated_at = (Get-Date).ToString('o')
        address = (Get-RaymanWorkerAdvertisedAddress -WorkspaceRoot $WorkspaceRoot)
        port = $port
      }
    }
    'PUT /upgrade/upload' {
      $token = [string]$RequestData.query_string['token']
      if ([string]::IsNullOrWhiteSpace([string]$token)) { throw 'upgrade upload token is required' }
      $destination = Join-Path (Get-RaymanWorkerUploadRoot -WorkspaceRoot $WorkspaceRoot) ("upgrade-{0}.zip" -f $token)
      [System.IO.File]::WriteAllBytes($destination, @($RequestData.body_bytes))
      return [pscustomobject]@{
        schema = 'rayman.worker.upload.result.v1'
        generated_at = (Get-Date).ToString('o')
        token = $token
        path = $destination
      }
    }
    'POST /upgrade' {
      $packagePath = ''
      if ($null -ne $body -and $body.PSObject.Properties['package_base64'] -and -not [string]::IsNullOrWhiteSpace([string]$body.package_base64)) {
        $token = [Guid]::NewGuid().ToString('n')
        $packagePath = Join-Path (Get-RaymanWorkerUploadRoot -WorkspaceRoot $WorkspaceRoot) ("upgrade-{0}.zip" -f $token)
        [System.IO.File]::WriteAllBytes($packagePath, [Convert]::FromBase64String([string]$body.package_base64))
      } else {
        $token = if ($null -ne $body -and $body.PSObject.Properties['upload_token']) { [string]$body.upload_token } else { '' }
        if ([string]::IsNullOrWhiteSpace([string]$token)) { throw 'upgrade requires upload_token or package_base64' }
        $packagePath = Join-Path (Get-RaymanWorkerUploadRoot -WorkspaceRoot $WorkspaceRoot) ("upgrade-{0}.zip" -f $token)
      }
      if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) { throw ("upgrade package not found: {0}" -f $packagePath) }
      $psHost = if (Get-Command Resolve-RaymanPowerShellHost -ErrorAction SilentlyContinue) { Resolve-RaymanPowerShellHost } else { 'powershell.exe' }
      $upgradeScript = Join-Path $WorkspaceRoot '.Rayman\scripts\worker\worker_upgrade.ps1'
      Start-Process -FilePath $psHost -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgradeScript, '-WorkspaceRoot', $WorkspaceRoot, '-Action', 'apply-and-restart', '-PackagePath', $packagePath, '-WorkerHostPid', ([string]$PID)) -WindowStyle Hidden | Out-Null
      return [pscustomobject]@{
        schema = 'rayman.worker.upgrade.accepted.v1'
        generated_at = (Get-Date).ToString('o')
        accepted = $true
        package_path = $packagePath
      }
    }
    default {
      return [pscustomobject]@{
        schema = 'rayman.worker.error.v1'
        generated_at = (Get-Date).ToString('o')
        error = 'not_found'
        path = $relativePath
        method = $method
      }
    }
  }
}

function Test-RaymanWorkerCanHandleRequestInline {
  param([object]$RequestData)

  if ($null -eq $RequestData) {
    return $true
  }

  $method = if ($RequestData.PSObject.Properties['method']) { [string]$RequestData.method } else { '' }
  $path = if ($RequestData.PSObject.Properties['path']) { [string]$RequestData.path } else { '' }
  return ("{0} {1}" -f $method.ToUpperInvariant(), $path.ToLowerInvariant()) -eq 'GET /status'
}

function Write-RaymanWorkerRequestEnvelope {
  param(
    [string]$Path,
    [object]$RequestData
  )

  $bodyBytesBase64 = ''
  if ($null -ne $RequestData -and $RequestData.PSObject.Properties['body_bytes'] -and $null -ne $RequestData.body_bytes) {
    $bodyBytes = @([byte[]]$RequestData.body_bytes)
    if ($bodyBytes.Length -gt 0) {
      $bodyBytesBase64 = [Convert]::ToBase64String($bodyBytes)
    }
  }

  $payload = [pscustomobject]@{
    schema = 'rayman.worker.request_envelope.v1'
    generated_at = (Get-Date).ToString('o')
    request_data = [pscustomobject]@{
      method = if ($null -ne $RequestData -and $RequestData.PSObject.Properties['method']) { [string]$RequestData.method } else { '' }
      path = if ($null -ne $RequestData -and $RequestData.PSObject.Properties['path']) { [string]$RequestData.path } else { '' }
      headers = if ($null -ne $RequestData -and $RequestData.PSObject.Properties['headers']) { $RequestData.headers } else { @{} }
      query_string = if ($null -ne $RequestData -and $RequestData.PSObject.Properties['query_string']) { $RequestData.query_string } else { @{} }
      body_json = if ($null -ne $RequestData -and $RequestData.PSObject.Properties['body_json']) { $RequestData.body_json } else { $null }
      body_bytes_base64 = $bodyBytesBase64
    }
  }
  Write-RaymanWorkerJsonFile -Path $Path -Value $payload
}

function Start-RaymanWorkerRequestHandlerProcess {
  param(
    [string]$WorkspaceRoot,
    [string]$HostStartTime,
    [object]$RequestData,
    [System.Net.Sockets.TcpClient]$Client
  )

  $resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $hostRuntimeRoot = Get-RaymanWorkerHostRuntimeRoot -WorkspaceRoot $resolvedWorkspaceRoot
  $operationId = [Guid]::NewGuid().ToString('n')
  $requestPath = Join-Path $hostRuntimeRoot ("request-{0}.json" -f $operationId)
  $responsePath = Join-Path $hostRuntimeRoot ("request-{0}.response.json" -f $operationId)
  $workerScript = Join-Path $PSScriptRoot 'worker_request_worker.ps1'
  if (-not (Test-Path -LiteralPath $workerScript -PathType Leaf)) {
    throw ("worker request helper script missing: {0}" -f $workerScript)
  }

  Write-RaymanWorkerRequestEnvelope -Path $requestPath -RequestData $RequestData
  $psHost = if (Get-Command Resolve-RaymanPowerShellHost -ErrorAction SilentlyContinue) {
    Resolve-RaymanPowerShellHost
  } else {
    'powershell.exe'
  }
  $process = Start-Process -FilePath $psHost -ArgumentList @(
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      $workerScript,
      '-WorkspaceRoot',
      $resolvedWorkspaceRoot,
      '-HostStartTime',
      $HostStartTime,
      '-RequestPath',
      $requestPath,
      '-ResponsePath',
      $responsePath
    ) -WorkingDirectory $resolvedWorkspaceRoot -WindowStyle Hidden -PassThru

  return [pscustomobject]@{
    operation_id = $operationId
    client = $Client
    process = $process
    request_path = $requestPath
    response_path = $responsePath
  }
}

function Complete-RaymanWorkerPendingRequest {
  param([object]$Pending)

  if ($null -eq $Pending) {
    return $false
  }

  $response = Read-RaymanWorkerJsonFile -Path ([string]$Pending.response_path)
  if ($null -eq $response) {
    if ($null -eq $Pending.process -or -not $Pending.process.HasExited) {
      return $false
    }

    $response = [pscustomobject]@{
      schema = 'rayman.worker.request_response.v1'
      status_code = 500
      payload = [pscustomobject]@{
        schema = 'rayman.worker.error.v1'
        generated_at = (Get-Date).ToString('o')
        error = 'worker request handler exited without producing a response'
      }
    }
  }

  $statusCode = if ($response.PSObject.Properties['status_code']) { [int]$response.status_code } else { 500 }
  $payload = if ($response.PSObject.Properties['payload']) { $response.payload } else { [pscustomobject]@{
        schema = 'rayman.worker.error.v1'
        generated_at = (Get-Date).ToString('o')
        error = 'worker request handler produced an invalid response envelope'
      } }

  try {
    Write-RaymanWorkerTcpResponse -Client $Pending.client -StatusCode $statusCode -Payload $payload
  } catch {}

  try { $Pending.client.Close() } catch {}
  if ($null -ne $Pending.process) {
    try {
      if (-not $Pending.process.HasExited) {
        Stop-Process -Id $Pending.process.Id -Force -ErrorAction SilentlyContinue
      }
    } catch {}
  }
  foreach ($path in @([string]$Pending.request_path, [string]$Pending.response_path)) {
    try {
      if (-not [string]::IsNullOrWhiteSpace([string]$path) -and (Test-Path -LiteralPath $path)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
      }
    } catch {}
  }

  return $true
}

function Start-RaymanWorkerHost {
  param(
    [string]$WorkspaceRoot,
    [switch]$NoBeacon
  )

  if (-not (Test-RaymanWorkerWindowsHost)) {
    throw 'Rayman Worker currently supports Windows hosts only.'
  }

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $hostStartedAt = (Get-Date).ToString('o')
  $syncManifest = Get-RaymanWorkerCurrentSyncManifest -WorkspaceRoot $resolvedRoot
  if ($null -eq $syncManifest) {
    $syncManifest = Set-RaymanWorkerAttachedSyncManifest -WorkspaceRoot $resolvedRoot
  }

  $controlPort = Get-RaymanWorkerControlPort
  $listener = [System.Net.Sockets.TcpListener]::new((Get-RaymanWorkerBindIPAddress -WorkspaceRoot $resolvedRoot), $controlPort)
  $listener.Start()
  $pendingRequests = New-Object System.Collections.Generic.List[object]

  try {
    $status = Get-RaymanWorkerStatusSnapshot -WorkspaceRoot $resolvedRoot -SyncManifest $syncManifest -ProcessId $PID -HostStartTime $hostStartedAt
    Write-RaymanWorkerJsonFile -Path (Get-RaymanWorkerHostStatusPath -WorkspaceRoot $resolvedRoot) -Value $status

    $nextBeacon = Get-Date
    $nextStatusWrite = Get-Date
    while ($true) {
      $now = Get-Date
      if (-not $NoBeacon -and $now -ge $nextBeacon) {
        Send-RaymanWorkerBeacon -WorkspaceRoot $resolvedRoot -HostStartTime $hostStartedAt | Out-Null
        $nextBeacon = $now.AddSeconds(5)
      }
      if ($now -ge $nextStatusWrite) {
        $status = Get-RaymanWorkerStatusSnapshot -WorkspaceRoot $resolvedRoot -SyncManifest (Get-RaymanWorkerCurrentSyncManifest -WorkspaceRoot $resolvedRoot) -ProcessId $PID -HostStartTime $hostStartedAt
        Write-RaymanWorkerJsonFile -Path (Get-RaymanWorkerHostStatusPath -WorkspaceRoot $resolvedRoot) -Value $status
        $nextStatusWrite = $now.AddSeconds(10)
      }

      foreach ($pending in @($pendingRequests.ToArray())) {
        if (Complete-RaymanWorkerPendingRequest -Pending $pending) {
          [void]$pendingRequests.Remove($pending)
        }
      }

      if (-not $listener.Pending()) {
        Start-Sleep -Milliseconds 250
        continue
      }

      $client = $listener.AcceptTcpClient()
      $client.ReceiveTimeout = 15000
      $client.SendTimeout = 15000
      try {
        $requestData = Read-RaymanWorkerTcpRequest -Client $client
        if (Test-RaymanWorkerCanHandleRequestInline -RequestData $requestData) {
          $payload = Invoke-RaymanWorkerRequestData -WorkspaceRoot $resolvedRoot -RequestData $requestData -HostStartTime $hostStartedAt
          $statusCode = if ($payload.PSObject.Properties['error'] -and [string]$payload.error -eq 'not_found') { 404 } else { 200 }
          Write-RaymanWorkerTcpResponse -Client $client -StatusCode $statusCode -Payload $payload
        } else {
          $pending = Start-RaymanWorkerRequestHandlerProcess -WorkspaceRoot $resolvedRoot -HostStartTime $hostStartedAt -RequestData $requestData -Client $client
          $pendingRequests.Add($pending) | Out-Null
          $client = $null
        }
      } catch {
        try {
          $statusCode = if ($_.Exception -is [System.UnauthorizedAccessException]) { 401 } else { 500 }
          Write-RaymanWorkerTcpResponse -Client $client -StatusCode $statusCode -Payload ([pscustomobject]@{
            schema = 'rayman.worker.error.v1'
            generated_at = (Get-Date).ToString('o')
            error = $_.Exception.Message
          })
        } catch {}
      } finally {
        if ($null -ne $client) {
          try { $client.Close() } catch {}
        }
      }
    }
  } finally {
    foreach ($pending in @($pendingRequests.ToArray())) {
      [void](Complete-RaymanWorkerPendingRequest -Pending $pending)
    }
    try { $listener.Stop() } catch {}
  }
}

if (-not $NoMain) {
  $WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  if ($TunnelServer) {
    $argsJson = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$VsdbgArgumentsBase64)) {
      $argsJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($VsdbgArgumentsBase64))
    }
    $args = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$argsJson)) {
      $args = @((ConvertFrom-Json -InputObject $argsJson -ErrorAction Stop) | ForEach-Object { [string]$_ })
    }
    Start-RaymanWorkerDebugTunnelServer -WorkspaceRoot $WorkspaceRoot -TunnelPort $TunnelPort -VsdbgPath $VsdbgPath -VsdbgArguments $args -WorkingDirectory $WorkingDirectory
    exit 0
  }

  Start-RaymanWorkerHost -WorkspaceRoot $WorkspaceRoot -NoBeacon:$NoBeacon
}
