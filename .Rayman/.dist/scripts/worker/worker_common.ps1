Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workerCommonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (Test-Path -LiteralPath $workerCommonPath -PathType Leaf) {
  . $workerCommonPath
}

function Ensure-RaymanWorkerDirectory {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace([string]$Path)) { return }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Write-RaymanWorkerUtf8NoBom {
  param(
    [string]$Path,
    [string]$Content
  )

  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace([string]$parent)) {
    Ensure-RaymanWorkerDirectory -Path $parent
  }

  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Read-RaymanWorkerJsonFile {
  param(
    [string]$Path,
    [switch]$AsHashtable
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  try {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace([string]$raw)) { return $null }
    if ($AsHashtable) {
      return ($raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
    }
    return ($raw | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Write-RaymanWorkerJsonFile {
  param(
    [string]$Path,
    [object]$Value,
    [int]$Depth = 12
  )

  if ([string]::IsNullOrWhiteSpace([string]$Path)) { return }
  $json = ($Value | ConvertTo-Json -Depth $Depth)
  Write-RaymanWorkerUtf8NoBom -Path $Path -Content (($json.TrimEnd()) + "`n")
}

function Test-RaymanWorkerWindowsHost {
  try {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
  } catch {
    return $false
  }
}

function Get-RaymanWorkerEnvInt {
  param(
    [string]$Name,
    [int]$Default,
    [int]$Min = 1,
    [int]$Max = 65535
  )

  $raw = [Environment]::GetEnvironmentVariable($Name)
  $parsed = 0
  if (-not [string]::IsNullOrWhiteSpace([string]$raw) -and [int]::TryParse([string]$raw, [ref]$parsed)) {
    if ($parsed -lt $Min) { return $Min }
    if ($parsed -gt $Max) { return $Max }
    return $parsed
  }
  return $Default
}

function Get-RaymanWorkerDiscoveryPort {
  return (Get-RaymanWorkerEnvInt -Name 'RAYMAN_WORKER_DISCOVERY_PORT' -Default 47631)
}

function Get-RaymanWorkerControlPort {
  return (Get-RaymanWorkerEnvInt -Name 'RAYMAN_WORKER_CONTROL_PORT' -Default 47632)
}

function Get-RaymanWorkerDiscoveryListenSeconds {
  return (Get-RaymanWorkerEnvInt -Name 'RAYMAN_WORKER_DISCOVERY_LISTEN_SECONDS' -Default 4 -Min 1 -Max 300)
}

function Get-RaymanWorkerExecutionTimeoutSeconds {
  return (Get-RaymanWorkerEnvInt -Name 'RAYMAN_WORKER_EXEC_TIMEOUT_SECONDS' -Default 1800 -Min 5 -Max 7200)
}

function Get-RaymanWorkerGitCommandTimeoutMilliseconds {
  return (Get-RaymanWorkerEnvInt -Name 'RAYMAN_WORKER_GIT_COMMAND_TIMEOUT_MS' -Default 1500 -Min 100 -Max 30000)
}

function Get-RaymanWorkerVersion {
  param([string]$WorkspaceRoot)

  $versionPath = Join-Path $WorkspaceRoot '.Rayman\VERSION'
  if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
    return 'unknown'
  }

  try {
    return (Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8).Trim()
  } catch {
    return 'unknown'
  }
}

function Get-RaymanWorkerDevStateRoot {
  param([string]$WorkspaceRoot)

  $path = Join-Path $WorkspaceRoot '.Rayman\state\workers'
  Ensure-RaymanWorkerDirectory -Path $path
  return $path
}

function Get-RaymanWorkerRuntimeRoot {
  param([string]$WorkspaceRoot)

  $path = Join-Path $WorkspaceRoot '.Rayman\runtime\workers'
  Ensure-RaymanWorkerDirectory -Path $path
  return $path
}

function Get-RaymanWorkerRegistryPath {
  param([string]$WorkspaceRoot)

  return (Join-Path (Get-RaymanWorkerDevStateRoot -WorkspaceRoot $WorkspaceRoot) 'registry.json')
}

function Get-RaymanWorkerActivePath {
  param([string]$WorkspaceRoot)

  return (Join-Path (Get-RaymanWorkerDevStateRoot -WorkspaceRoot $WorkspaceRoot) 'active.json')
}

function Get-RaymanWorkerDiscoveryLastPath {
  param([string]$WorkspaceRoot)

  return (Join-Path (Get-RaymanWorkerRuntimeRoot -WorkspaceRoot $WorkspaceRoot) 'discovery.last.json')
}

function Get-RaymanWorkerDebugLastPath {
  param([string]$WorkspaceRoot)

  return (Join-Path (Get-RaymanWorkerRuntimeRoot -WorkspaceRoot $WorkspaceRoot) 'debug.last.json')
}

function Get-RaymanWorkerHostRuntimeRoot {
  param([string]$WorkspaceRoot)

  $path = Join-Path $WorkspaceRoot '.Rayman\runtime\worker'
  Ensure-RaymanWorkerDirectory -Path $path
  return $path
}

function Get-RaymanWorkerHostStatusPath {
  param([string]$WorkspaceRoot)

  return (Join-Path (Get-RaymanWorkerHostRuntimeRoot -WorkspaceRoot $WorkspaceRoot) 'host.status.json')
}

function Get-RaymanWorkerBeaconLastPath {
  param([string]$WorkspaceRoot)

  return (Join-Path (Get-RaymanWorkerHostRuntimeRoot -WorkspaceRoot $WorkspaceRoot) 'beacon.last.json')
}

function Get-RaymanWorkerUpgradeLastPath {
  param([string]$WorkspaceRoot)

  return (Join-Path (Get-RaymanWorkerHostRuntimeRoot -WorkspaceRoot $WorkspaceRoot) 'upgrade.last.json')
}

function Get-RaymanWorkerSyncLastPath {
  param([string]$WorkspaceRoot)

  return (Join-Path (Get-RaymanWorkerHostRuntimeRoot -WorkspaceRoot $WorkspaceRoot) 'sync.last.json')
}

function Get-RaymanWorkerVsdbgStatusPath {
  param([string]$WorkspaceRoot)

  return (Join-Path (Get-RaymanWorkerHostRuntimeRoot -WorkspaceRoot $WorkspaceRoot) 'vsdbg.last.json')
}

function Get-RaymanWorkerDebugSessionPath {
  param([string]$WorkspaceRoot)

  return (Join-Path (Get-RaymanWorkerHostRuntimeRoot -WorkspaceRoot $WorkspaceRoot) 'debug.session.last.json')
}

function Get-RaymanWorkerUploadRoot {
  param([string]$WorkspaceRoot)

  $path = Join-Path (Get-RaymanWorkerHostRuntimeRoot -WorkspaceRoot $WorkspaceRoot) 'uploads'
  Ensure-RaymanWorkerDirectory -Path $path
  return $path
}

function Get-RaymanWorkerStagingRoot {
  param([string]$WorkspaceRoot)

  $path = Join-Path (Get-RaymanWorkerHostRuntimeRoot -WorkspaceRoot $WorkspaceRoot) 'staging'
  Ensure-RaymanWorkerDirectory -Path $path
  return $path
}

function Get-RaymanWorkerMachineName {
  if (-not [string]::IsNullOrWhiteSpace([string]$env:COMPUTERNAME)) {
    return [string]$env:COMPUTERNAME
  }
  return [System.Environment]::MachineName
}

function Get-RaymanWorkerDisplayName {
  param([string]$WorkspaceRoot)

  $override = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_NAME')
  if (-not [string]::IsNullOrWhiteSpace([string]$override)) {
    return [string]$override
  }

  $leaf = Split-Path -Leaf $WorkspaceRoot
  if ([string]::IsNullOrWhiteSpace([string]$leaf)) {
    $leaf = 'workspace'
  }
  return ('{0}:{1}' -f (Get-RaymanWorkerMachineName), $leaf)
}

function Get-RaymanWorkerStableId {
  param([string]$WorkspaceRoot)

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $seed = ('{0}|{1}' -f (Get-RaymanWorkerMachineName), $resolvedRoot.ToLowerInvariant())
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($seed)
    $hash = $sha.ComputeHash($bytes)
  } finally {
    $sha.Dispose()
  }

  return ([System.BitConverter]::ToString($hash)).Replace('-', '').Substring(0, 16).ToLowerInvariant()
}

function Get-RaymanWorkerTaskPath {
  param([string]$WorkspaceRoot)

  return ('\Rayman\{0}\' -f (Get-RaymanWorkerStableId -WorkspaceRoot $WorkspaceRoot))
}

function Get-RaymanWorkerPrimaryAddress {
  $addresses = New-Object System.Collections.Generic.List[string]
  try {
    foreach ($address in @([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()))) {
      if ($null -eq $address) { continue }
      if ($address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
      $candidate = [string]$address.IPAddressToString
      if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
      if ($candidate.StartsWith('127.')) { continue }
      $addresses.Add($candidate) | Out-Null
    }
  } catch {}

  if ($addresses.Count -gt 0) {
    return [string]$addresses[0]
  }
  return '127.0.0.1'
}

function Get-RaymanWorkerCurrentUser {
  try {
    return ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
  } catch {
    if (-not [string]::IsNullOrWhiteSpace([string]$env:USERNAME)) {
      return [string]$env:USERNAME
    }
    return ''
  }
}

function Get-RaymanWorkerGitSnapshot {
  param([string]$WorkspaceRoot)

  $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $git -or [string]::IsNullOrWhiteSpace([string]$git.Source)) {
    return [pscustomobject]@{
      available = $false
      branch = ''
      commit = ''
      dirty = $false
      status = @()
    }
  }

  $branch = ''
  $commit = ''
  $dirty = $false
  $statusLines = @()
  $timedOut = $false
  $timeoutMs = Get-RaymanWorkerGitCommandTimeoutMilliseconds
  try {
    $branchCapture = Invoke-RaymanWorkerNativeCommandCapture -FilePath $git.Source -ArgumentList @('-C', $WorkspaceRoot, 'rev-parse', '--abbrev-ref', 'HEAD') -WorkingDirectory $WorkspaceRoot -TimeoutMilliseconds $timeoutMs
    if ([bool]$branchCapture.success -and $branchCapture.stdout.Count -gt 0) {
      $branch = [string]$branchCapture.stdout[0]
    }
    if ([bool]$branchCapture.timed_out) {
      $timedOut = $true
    }
  } catch {}
  try {
    $commitCapture = Invoke-RaymanWorkerNativeCommandCapture -FilePath $git.Source -ArgumentList @('-C', $WorkspaceRoot, 'rev-parse', 'HEAD') -WorkingDirectory $WorkspaceRoot -TimeoutMilliseconds $timeoutMs
    if ([bool]$commitCapture.success -and $commitCapture.stdout.Count -gt 0) {
      $commit = [string]$commitCapture.stdout[0]
    }
    if ([bool]$commitCapture.timed_out) {
      $timedOut = $true
    }
  } catch {}
  try {
    $statusCapture = Invoke-RaymanWorkerNativeCommandCapture -FilePath $git.Source -ArgumentList @('-C', $WorkspaceRoot, 'status', '--porcelain') -WorkingDirectory $WorkspaceRoot -TimeoutMilliseconds $timeoutMs
    if ($null -ne $statusCapture) {
      if ([bool]$statusCapture.timed_out) {
        $timedOut = $true
        $dirty = $true
        $statusLines = @("[git status timed out after $timeoutMs ms]")
      } else {
        $statusLines = @($statusCapture.stdout)
        $dirty = ($statusLines.Count -gt 0)
      }
    }
  } catch {}

  return [pscustomobject]@{
    available = $true
    branch = $branch
    commit = $commit
    dirty = $dirty
    status = @($statusLines | ForEach-Object { [string]$_ })
    timed_out = $timedOut
  }
}

function Invoke-RaymanWorkerNativeCommandCapture {
  param(
    [string]$FilePath,
    [string[]]$ArgumentList = @(),
    [string]$WorkingDirectory = '',
    [int]$TimeoutMilliseconds = 5000
  )

  $result = [ordered]@{
    success = $false
    started = $false
    exit_code = -1
    output = ''
    stdout = @()
    stderr = @()
    command = ''
    file_path = [string]$FilePath
    error = ''
    timed_out = $false
  }

  if ([string]::IsNullOrWhiteSpace([string]$FilePath)) {
    $result.error = 'file_path_missing'
    return [pscustomobject]$result
  }

  $quotedArgs = @($ArgumentList | ForEach-Object {
        $arg = [string]$_
        if ([string]::IsNullOrWhiteSpace($arg)) { return "''" }
        if ($arg -match '[\s"]') {
          return ('"' + ($arg -replace '"', '\"') + '"')
        }
        return $arg
      })
  $result.command = ((@([string]$FilePath) + $quotedArgs) -join ' ').Trim()

  $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_worker_capture_' + [Guid]::NewGuid().ToString('N'))
  $stdoutPath = $tempBase + '.stdout.txt'
  $stderrPath = $tempBase + '.stderr.txt'
  $proc = $null

  try {
    $params = @{
      FilePath = [string]$FilePath
      ArgumentList = @($ArgumentList)
      PassThru = $true
      RedirectStandardOutput = $stdoutPath
      RedirectStandardError = $stderrPath
      WindowStyle = 'Hidden'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$WorkingDirectory)) {
      $params['WorkingDirectory'] = $WorkingDirectory
    }

    $proc = Start-Process @params
    $result.started = $true
    if (-not $proc.WaitForExit($TimeoutMilliseconds)) {
      $result.timed_out = $true
      try { $proc.Kill() } catch {}
      [void]$proc.WaitForExit(1000)
    }

    if ($null -ne $proc -and $proc.HasExited) {
      $result.exit_code = [int]$proc.ExitCode
    }
    if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
      $result.stdout = @([string[]](Get-Content -LiteralPath $stdoutPath -Encoding UTF8 -ErrorAction SilentlyContinue))
    }
    if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
      $result.stderr = @([string[]](Get-Content -LiteralPath $stderrPath -Encoding UTF8 -ErrorAction SilentlyContinue))
    }
    $result.output = [string](@($result.stdout + $result.stderr) -join [Environment]::NewLine)
    $result.success = (-not [bool]$result.timed_out -and $result.exit_code -eq 0)
  } catch {
    $result.error = $_.Exception.Message
    if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
      $result.stdout = @([string[]](Get-Content -LiteralPath $stdoutPath -Encoding UTF8 -ErrorAction SilentlyContinue))
    }
    if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
      $result.stderr = @([string[]](Get-Content -LiteralPath $stderrPath -Encoding UTF8 -ErrorAction SilentlyContinue))
    }
    $result.output = [string](@($result.stdout + $result.stderr) -join [Environment]::NewLine)
  } finally {
    try { Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue } catch {}
    try { Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue } catch {}
  }

  return [pscustomobject]$result
}

function Get-RaymanWorkerExecutionRoot {
  param(
    [string]$WorkspaceRoot,
    [object]$SyncManifest = $null
  )

  if ($null -eq $SyncManifest) {
    $syncPath = Get-RaymanWorkerSyncLastPath -WorkspaceRoot $WorkspaceRoot
    $SyncManifest = Read-RaymanWorkerJsonFile -Path $syncPath
  }

  if ($null -ne $SyncManifest -and $SyncManifest.PSObject.Properties['mode'] -and [string]$SyncManifest.mode -eq 'staged') {
    $stagingRoot = [string]$SyncManifest.staging_root
    if (-not [string]::IsNullOrWhiteSpace([string]$stagingRoot) -and (Test-Path -LiteralPath $stagingRoot -PathType Container)) {
      return $stagingRoot
    }
  }

  return (Resolve-Path -LiteralPath $WorkspaceRoot).Path
}

function Get-RaymanWorkerProjectTargetFrameworks {
  param([string]$ProjectPath)

  $frameworks = New-Object System.Collections.Generic.List[string]
  try {
    [xml]$xml = Get-Content -LiteralPath $ProjectPath -Raw -Encoding UTF8
    foreach ($propGroup in @($xml.Project.PropertyGroup)) {
      if ($null -eq $propGroup) { continue }
      foreach ($name in @('TargetFramework', 'TargetFrameworks')) {
        $node = $propGroup.$name
        if ($null -eq $node) { continue }
        foreach ($segment in @([string]$node -split ';')) {
          $value = ([string]$segment).Trim()
          if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            $frameworks.Add($value) | Out-Null
          }
        }
      }
    }
  } catch {}

  return @($frameworks.ToArray() | Select-Object -Unique)
}

function Get-RaymanWorkerDotNetEntrypoints {
  param([string]$ExecutionRoot)

  $entries = New-Object System.Collections.Generic.List[object]
  if (-not (Test-Path -LiteralPath $ExecutionRoot -PathType Container)) {
    return @()
  }

  $projects = @(Get-ChildItem -LiteralPath $ExecutionRoot -Recurse -Filter '*.csproj' -File -ErrorAction SilentlyContinue)
  foreach ($project in $projects) {
    $projectName = [System.IO.Path]::GetFileNameWithoutExtension($project.Name)
    if ($projectName -match '(?i)test') { continue }

    $frameworks = @(Get-RaymanWorkerProjectTargetFrameworks -ProjectPath $project.FullName)
    if ($frameworks.Count -eq 0) {
      $frameworks = @('net8.0')
    }

    $existingPrograms = New-Object System.Collections.Generic.List[string]
    $guessedPrograms = New-Object System.Collections.Generic.List[string]
    foreach ($framework in $frameworks) {
      foreach ($candidateLeaf in @(
          ("{0}.dll" -f $projectName),
          ("{0}.exe" -f $projectName)
        )) {
        $candidate = Join-Path $project.Directory.FullName ("bin\Debug\{0}\{1}" -f $framework, $candidateLeaf)
        $guessedPrograms.Add($candidate) | Out-Null
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
          $existingPrograms.Add($candidate) | Out-Null
        }
      }
    }

    $entries.Add([pscustomobject]@{
        project_name = $projectName
        project_path = [string]$project.FullName
        target_frameworks = @($frameworks)
        guessed_programs = @($guessedPrograms.ToArray() | Select-Object -Unique)
        existing_programs = @($existingPrograms.ToArray() | Select-Object -Unique)
      }) | Out-Null
  }

  return @($entries.ToArray())
}

function Get-RaymanWorkerVsdbgInstallRoot {
  param([string]$WorkspaceRoot)

  return (Join-Path $WorkspaceRoot '.Rayman\tools\vsdbg')
}

function Get-RaymanWorkerVsdbgProbe {
  param([string]$WorkspaceRoot)

  $resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $installRoot = Get-RaymanWorkerVsdbgInstallRoot -WorkspaceRoot $resolvedWorkspaceRoot
  $override = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_VSDBG_PATH')
  if (-not [string]::IsNullOrWhiteSpace([string]$override)) {
    $candidate = [string]$override
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return [pscustomobject]@{
        debugger_ready = $true
        debugger_path = $candidate
        source = 'env_override'
        install_root = $installRoot
        debugger_error = ''
      }
    }

    return [pscustomobject]@{
      debugger_ready = $false
      debugger_path = $candidate
      source = 'env_override'
      install_root = $installRoot
      debugger_error = ("RAYMAN_WORKER_VSDBG_PATH points to a missing file: {0}" -f $candidate)
    }
  }

  foreach ($candidateInfo in @(
      @{ path = (Join-Path $installRoot 'vsdbg.exe'); source = 'workspace_tools' },
      @{ path = (Join-Path $resolvedWorkspaceRoot '.Rayman\runtime\worker\tools\vsdbg\vsdbg.exe'); source = 'legacy_runtime_tools' }
    )) {
    $candidatePath = [string]$candidateInfo.path
    if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
      return [pscustomobject]@{
        debugger_ready = $true
        debugger_path = $candidatePath
        source = [string]$candidateInfo.source
        install_root = $installRoot
        debugger_error = ''
      }
    }
  }

  foreach ($name in @('vsdbg.exe', 'vsdbg')) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
      return [pscustomobject]@{
        debugger_ready = $true
        debugger_path = [string]$cmd.Source
        source = 'path'
        install_root = $installRoot
        debugger_error = ''
      }
    }
  }

  return [pscustomobject]@{
    debugger_ready = $false
    debugger_path = ''
    source = 'missing'
    install_root = $installRoot
    debugger_error = 'vsdbg was not found; install-local/upgrade/debug will attempt to download it to .Rayman/tools/vsdbg.'
  }
}

function Get-RaymanWorkerVsdbgStatus {
  param([string]$WorkspaceRoot)

  $resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $probe = Get-RaymanWorkerVsdbgProbe -WorkspaceRoot $resolvedWorkspaceRoot
  $payload = [ordered]@{
    schema = 'rayman.worker.vsdbg.status.v1'
    generated_at = (Get-Date).ToString('o')
    workspace_root = $resolvedWorkspaceRoot
    debugger_ready = [bool]$probe.debugger_ready
    debugger_path = [string]$probe.debugger_path
    source = [string]$probe.source
    install_root = [string]$probe.install_root
    download_uri = 'https://aka.ms/getvsdbgps1'
    proxy_source = [string][Environment]::GetEnvironmentVariable('RAYMAN_PROXY_SOURCE')
  }
  if (-not [bool]$probe.debugger_ready -and -not [string]::IsNullOrWhiteSpace([string]$probe.debugger_error)) {
    $payload['debugger_error'] = [string]$probe.debugger_error
  }
  return [pscustomobject]$payload
}

function Write-RaymanWorkerVsdbgStatus {
  param(
    [string]$WorkspaceRoot,
    [object]$Status
  )

  Write-RaymanWorkerJsonFile -Path (Get-RaymanWorkerVsdbgStatusPath -WorkspaceRoot $WorkspaceRoot) -Value $Status
}

function Initialize-RaymanWorkerDownloadEnvironment {
  param([string]$WorkspaceRoot)

  $proxyScript = Join-Path $WorkspaceRoot '.Rayman\scripts\proxy\detect_win_proxy.ps1'
  if (-not (Test-Path -LiteralPath $proxyScript -PathType Leaf)) {
    return
  }

  try {
    & $proxyScript -WorkspaceRoot $WorkspaceRoot | Out-Null
  } catch {
    # Best-effort only; downstream download should still report a concrete failure.
  }
}

function Ensure-RaymanWorkerVsdbg {
  param([string]$WorkspaceRoot)

  $resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $status = Get-RaymanWorkerVsdbgStatus -WorkspaceRoot $resolvedWorkspaceRoot
  if ([bool]$status.debugger_ready) {
    Write-RaymanWorkerVsdbgStatus -WorkspaceRoot $resolvedWorkspaceRoot -Status $status
    return $status
  }

  if ([string]$status.source -eq 'env_override') {
    Write-RaymanWorkerVsdbgStatus -WorkspaceRoot $resolvedWorkspaceRoot -Status $status
    return $status
  }

  Initialize-RaymanWorkerDownloadEnvironment -WorkspaceRoot $resolvedWorkspaceRoot

  $installRoot = Get-RaymanWorkerVsdbgInstallRoot -WorkspaceRoot $resolvedWorkspaceRoot
  Ensure-RaymanWorkerDirectory -Path $installRoot
  $hostRuntimeRoot = Get-RaymanWorkerHostRuntimeRoot -WorkspaceRoot $resolvedWorkspaceRoot
  $bootstrapOverride = [Environment]::GetEnvironmentVariable('RAYMAN_WORKER_VSDBG_BOOTSTRAP_SCRIPT')
  $bootstrapPath = ''
  $cleanupBootstrap = $false

  if (-not [string]::IsNullOrWhiteSpace([string]$bootstrapOverride)) {
    $bootstrapPath = [string]$bootstrapOverride
    if (-not (Test-Path -LiteralPath $bootstrapPath -PathType Leaf)) {
      $status = [ordered]@{
        schema = 'rayman.worker.vsdbg.status.v1'
        generated_at = (Get-Date).ToString('o')
        workspace_root = $resolvedWorkspaceRoot
        debugger_ready = $false
        debugger_path = ''
        source = 'bootstrap_override'
        install_root = $installRoot
        download_uri = 'https://aka.ms/getvsdbgps1'
        proxy_source = [string][Environment]::GetEnvironmentVariable('RAYMAN_PROXY_SOURCE')
        debugger_error = ("RAYMAN_WORKER_VSDBG_BOOTSTRAP_SCRIPT points to a missing file: {0}" -f $bootstrapPath)
      }
      $status = [pscustomobject]$status
      Write-RaymanWorkerVsdbgStatus -WorkspaceRoot $resolvedWorkspaceRoot -Status $status
      return $status
    }
  } else {
    $bootstrapPath = Join-Path $hostRuntimeRoot ("vsdbg-bootstrap-{0}.ps1" -f [Guid]::NewGuid().ToString('n'))
    try {
      Invoke-WebRequest -Uri 'https://aka.ms/getvsdbgps1' -OutFile $bootstrapPath -UseBasicParsing
    } catch {
      $status = [pscustomobject]@{
        schema = 'rayman.worker.vsdbg.status.v1'
        generated_at = (Get-Date).ToString('o')
        workspace_root = $resolvedWorkspaceRoot
        debugger_ready = $false
        debugger_path = ''
        source = 'download'
        install_root = $installRoot
        download_uri = 'https://aka.ms/getvsdbgps1'
        proxy_source = [string][Environment]::GetEnvironmentVariable('RAYMAN_PROXY_SOURCE')
        debugger_error = ("failed to download vsdbg bootstrap script: {0}" -f $_.Exception.Message)
      }
      Write-RaymanWorkerVsdbgStatus -WorkspaceRoot $resolvedWorkspaceRoot -Status $status
      return $status
    }
    $cleanupBootstrap = $true
  }

  $psHost = if (Get-Command Resolve-RaymanPowerShellHost -ErrorAction SilentlyContinue) {
    Resolve-RaymanPowerShellHost
  } else {
    'powershell.exe'
  }

  $capture = $null
  $installFailedMessage = ''
  try {
    $capture = Invoke-RaymanNativeCommandCapture -FilePath $psHost -ArgumentList @(
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      $bootstrapPath,
      '-Version',
      'latest',
      '-InstallPath',
      $installRoot
    ) -WorkingDirectory $resolvedWorkspaceRoot

    if (-not [bool]$capture.started) {
      $installFailedMessage = if ([string]::IsNullOrWhiteSpace([string]$capture.error)) { 'failed to launch vsdbg installer' } else { [string]$capture.error }
    } elseif ([int]$capture.exit_code -ne 0) {
      $tail = @($capture.stdout + $capture.stderr | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 3)
      $suffix = if ($tail.Count -gt 0) { ': ' + ($tail -join ' | ') } else { '' }
      $installFailedMessage = ("vsdbg installer failed with exit code {0}{1}" -f [int]$capture.exit_code, $suffix)
    }
  } catch {
    $installFailedMessage = $_.Exception.Message
  } finally {
    if ($cleanupBootstrap -and (Test-Path -LiteralPath $bootstrapPath -PathType Leaf)) {
      Remove-Item -LiteralPath $bootstrapPath -Force -ErrorAction SilentlyContinue
    }
  }

  $status = Get-RaymanWorkerVsdbgStatus -WorkspaceRoot $resolvedWorkspaceRoot
  if (-not [string]::IsNullOrWhiteSpace([string]$installFailedMessage)) {
    $statusWithError = [ordered]@{
      schema = 'rayman.worker.vsdbg.status.v1'
      generated_at = (Get-Date).ToString('o')
      workspace_root = $resolvedWorkspaceRoot
      debugger_ready = [bool]$status.debugger_ready
      debugger_path = [string]$status.debugger_path
      source = if ([bool]$status.debugger_ready) { [string]$status.source } else { 'download' }
      install_root = [string]$status.install_root
      download_uri = 'https://aka.ms/getvsdbgps1'
      proxy_source = [string][Environment]::GetEnvironmentVariable('RAYMAN_PROXY_SOURCE')
      debugger_error = $installFailedMessage
    }
    $status = [pscustomobject]$statusWithError
  }

  Write-RaymanWorkerVsdbgStatus -WorkspaceRoot $resolvedWorkspaceRoot -Status $status
  return $status
}

function Get-RaymanWorkerVsdbgPath {
  param([string]$WorkspaceRoot)

  return [string](Get-RaymanWorkerVsdbgStatus -WorkspaceRoot $WorkspaceRoot).debugger_path
}

function Get-RaymanWorkerDotNetProcesses {
  param([string]$ExecutionRoot = '')

  $processes = New-Object System.Collections.Generic.List[object]
  $resolvedExecutionRoot = ''
  if (-not [string]::IsNullOrWhiteSpace([string]$ExecutionRoot)) {
    try {
      $resolvedExecutionRoot = (Resolve-Path -LiteralPath $ExecutionRoot -ErrorAction Stop).Path
    } catch {
      $resolvedExecutionRoot = [string]$ExecutionRoot
    }
  }
  try {
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
      $path = ''
      try { $path = [string]$process.Path } catch { $path = '' }
      if ($process.ProcessName -match '(?i)powershell|pwsh') { continue }
      $isDotNetHost = [string]$process.ProcessName -match '(?i)^dotnet$'
      $isWorkspaceExecutable = $false
      if (-not [string]::IsNullOrWhiteSpace([string]$resolvedExecutionRoot) -and -not [string]::IsNullOrWhiteSpace([string]$path)) {
        $isWorkspaceExecutable = $path.StartsWith($resolvedExecutionRoot, [System.StringComparison]::OrdinalIgnoreCase) -and $path -match '(?i)\.exe$'
      }
      if ($isDotNetHost -or $isWorkspaceExecutable) {
        $processes.Add([pscustomobject]@{
            process_id = [int]$process.Id
            process_name = [string]$process.ProcessName
            path = $path
          }) | Out-Null
      }
    }
  } catch {}

  return @($processes.ToArray() | Sort-Object process_name, process_id)
}

function Get-RaymanWorkerDefaultDebugTarget {
  param(
    [string]$ExecutionRoot,
    [string]$ProgramOverride = ''
  )

  if (-not [string]::IsNullOrWhiteSpace([string]$ProgramOverride)) {
    if ([System.IO.Path]::IsPathRooted($ProgramOverride)) {
      return $ProgramOverride
    }
    return (Join-Path $ExecutionRoot ($ProgramOverride -replace '/', '\'))
  }

  foreach ($entry in @(Get-RaymanWorkerDotNetEntrypoints -ExecutionRoot $ExecutionRoot)) {
    foreach ($candidate in @($entry.existing_programs + $entry.guessed_programs)) {
      if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
        return [string]$candidate
      }
    }
  }

  return ''
}

function Get-RaymanWorkerStatusSnapshot {
  param(
    [string]$WorkspaceRoot,
    [string]$WorkspaceMode = 'attached',
    [object]$SyncManifest = $null,
    [int]$ProcessId = 0,
    [string]$HostStartTime = '',
    [switch]$IncludeProcesses
  )

  $resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $workerId = Get-RaymanWorkerStableId -WorkspaceRoot $resolvedWorkspaceRoot
  $controlPort = Get-RaymanWorkerControlPort
  $discoveryPort = Get-RaymanWorkerDiscoveryPort
  $primaryAddress = Get-RaymanWorkerPrimaryAddress
  $git = Get-RaymanWorkerGitSnapshot -WorkspaceRoot $resolvedWorkspaceRoot
  $executionRoot = Get-RaymanWorkerExecutionRoot -WorkspaceRoot $resolvedWorkspaceRoot -SyncManifest $SyncManifest
  $entrypoints = @(Get-RaymanWorkerDotNetEntrypoints -ExecutionRoot $executionRoot)
  $vsdbgStatus = Get-RaymanWorkerVsdbgStatus -WorkspaceRoot $resolvedWorkspaceRoot
  $processes = if ($IncludeProcesses) { @(Get-RaymanWorkerDotNetProcesses -ExecutionRoot $executionRoot) } else { @() }
  $debugPayload = [ordered]@{
    supported = $true
    debugger_ready = [bool]$vsdbgStatus.debugger_ready
    debugger_path = [string]$vsdbgStatus.debugger_path
    entrypoints = @($entrypoints)
    processes = @($processes)
    default_program = (Get-RaymanWorkerDefaultDebugTarget -ExecutionRoot $executionRoot)
  }
  $payload = [ordered]@{
    schema = 'rayman.worker.status.v1'
    generated_at = (Get-Date).ToString('o')
    worker_id = $workerId
    worker_name = (Get-RaymanWorkerDisplayName -WorkspaceRoot $resolvedWorkspaceRoot)
    machine_name = (Get-RaymanWorkerMachineName)
    user_name = (Get-RaymanWorkerCurrentUser)
    version = (Get-RaymanWorkerVersion -WorkspaceRoot $resolvedWorkspaceRoot)
    workspace_root = $resolvedWorkspaceRoot
    workspace_name = (Split-Path -Leaf $resolvedWorkspaceRoot)
    workspace_mode = $WorkspaceMode
    interactive_session = [Environment]::UserInteractive
    process_id = $ProcessId
    started_at = $HostStartTime
    address = $primaryAddress
    debugger_ready = [bool]$vsdbgStatus.debugger_ready
    debugger_path = [string]$vsdbgStatus.debugger_path
    discovery = [pscustomobject]@{
      protocol = 'rayman.worker.beacon.v1'
      port = $discoveryPort
    }
    control = [pscustomobject]@{
      protocol = 'rayman.worker.control.v1'
      port = $controlPort
      base_url = ('http://{0}:{1}/' -f $primaryAddress, $controlPort)
    }
    capabilities = [pscustomobject]@{
      remote_exec = $true
      staged_sync = $true
      attached_sync = $true
      dotnet_debug = $true
      self_upgrade = $true
      windows_only = $true
    }
    git = $git
    sync = $SyncManifest
    execution_root = $executionRoot
    debug = [pscustomobject]$debugPayload
  }
  if (-not [bool]$vsdbgStatus.debugger_ready -and $vsdbgStatus.PSObject.Properties['debugger_error']) {
    $payload['debugger_error'] = [string]$vsdbgStatus.debugger_error
    $debugPayload['debugger_error'] = [string]$vsdbgStatus.debugger_error
    $payload['debug'] = [pscustomobject]$debugPayload
  }
  return [pscustomobject]$payload
}

function Get-RaymanWorkerBeaconPayload {
  param(
    [string]$WorkspaceRoot,
    [string]$WorkspaceMode = 'attached',
    [object]$SyncManifest = $null,
    [int]$ProcessId = 0,
    [string]$HostStartTime = '',
    [object]$StatusSnapshot = $null
  )

  $status = $StatusSnapshot
  if ($null -eq $status) {
    $status = Get-RaymanWorkerStatusSnapshot -WorkspaceRoot $WorkspaceRoot -WorkspaceMode $WorkspaceMode -SyncManifest $SyncManifest -ProcessId $ProcessId -HostStartTime $HostStartTime
  }
  $payload = [ordered]@{
    schema = 'rayman.worker.beacon.v1'
    generated_at = (Get-Date).ToString('o')
    worker_id = [string]$status.worker_id
    worker_name = [string]$status.worker_name
    machine_name = [string]$status.machine_name
    user_name = [string]$status.user_name
    version = [string]$status.version
    workspace_root = [string]$status.workspace_root
    workspace_name = [string]$status.workspace_name
    workspace_mode = [string]$status.workspace_mode
    interactive_session = [bool]$status.interactive_session
    address = [string]$status.address
    discovery_port = [int]$status.discovery.port
    control_port = [int]$status.control.port
    control_url = [string]$status.control.base_url
    debugger_ready = if ($status.PSObject.Properties['debugger_ready']) { [bool]$status.debugger_ready } else { $false }
    debugger_path = if ($status.PSObject.Properties['debugger_path']) { [string]$status.debugger_path } else { '' }
    capabilities = $status.capabilities
    git = $status.git
  }
  if ($status.PSObject.Properties['debugger_error'] -and -not [string]::IsNullOrWhiteSpace([string]$status.debugger_error)) {
    $payload['debugger_error'] = [string]$status.debugger_error
  }
  return [pscustomobject]$payload
}

function Get-RaymanWorkerRegistryDocument {
  param([string]$WorkspaceRoot)

  $path = Get-RaymanWorkerRegistryPath -WorkspaceRoot $WorkspaceRoot
  $doc = Read-RaymanWorkerJsonFile -Path $path
  if ($null -eq $doc -or -not $doc.PSObject.Properties['workers']) {
    return [pscustomobject]@{
      schema = 'rayman.worker.registry.v1'
      generated_at = ''
      workers = @()
    }
  }
  return $doc
}

function Write-RaymanWorkerRegistryDocument {
  param(
    [string]$WorkspaceRoot,
    [object[]]$Workers
  )

  $payload = [pscustomobject]@{
    schema = 'rayman.worker.registry.v1'
    generated_at = (Get-Date).ToString('o')
    workers = @($Workers)
  }
  Write-RaymanWorkerJsonFile -Path (Get-RaymanWorkerRegistryPath -WorkspaceRoot $WorkspaceRoot) -Value $payload
  return $payload
}

function Merge-RaymanWorkerRegistry {
  param(
    [string]$WorkspaceRoot,
    [object[]]$Workers
  )

  $existing = @((Get-RaymanWorkerRegistryDocument -WorkspaceRoot $WorkspaceRoot).workers)
  $map = @{}
  foreach ($item in @($existing)) {
    if ($null -eq $item) { continue }
    $key = [string]$item.worker_id
    if ([string]::IsNullOrWhiteSpace([string]$key)) { continue }
    $map[$key] = $item
  }

  foreach ($item in @($Workers)) {
    if ($null -eq $item) { continue }
    $key = [string]$item.worker_id
    if ([string]::IsNullOrWhiteSpace([string]$key)) { continue }
    $merged = [ordered]@{}
    if ($map.ContainsKey($key) -and $null -ne $map[$key]) {
      foreach ($prop in $map[$key].PSObject.Properties) {
        $merged[$prop.Name] = $prop.Value
      }
    }
    foreach ($prop in $item.PSObject.Properties) {
      $merged[$prop.Name] = $prop.Value
    }
    $merged['last_seen'] = (Get-Date).ToString('o')
    $map[$key] = [pscustomobject]$merged
  }

  return (Write-RaymanWorkerRegistryDocument -WorkspaceRoot $WorkspaceRoot -Workers @($map.Values | Sort-Object worker_name, worker_id))
}

function Get-RaymanActiveWorkerRecord {
  param([string]$WorkspaceRoot)

  return (Read-RaymanWorkerJsonFile -Path (Get-RaymanWorkerActivePath -WorkspaceRoot $WorkspaceRoot))
}

function Set-RaymanActiveWorkerRecord {
  param(
    [string]$WorkspaceRoot,
    [object]$Worker,
    [string]$WorkspaceMode = 'attached',
    [object]$SyncManifest = $null
  )

  $record = [pscustomobject]@{
    schema = 'rayman.worker.active.v1'
    updated_at = (Get-Date).ToString('o')
    worker_id = [string]$Worker.worker_id
    worker_name = [string]$Worker.worker_name
    address = [string]$Worker.address
    control_port = [int]$Worker.control_port
    control_url = [string]$Worker.control_url
    workspace_mode = $WorkspaceMode
    sync_manifest = $SyncManifest
  }
  Write-RaymanWorkerJsonFile -Path (Get-RaymanWorkerActivePath -WorkspaceRoot $WorkspaceRoot) -Value $record
  return $record
}

function Clear-RaymanActiveWorkerRecord {
  param([string]$WorkspaceRoot)

  $path = Get-RaymanWorkerActivePath -WorkspaceRoot $WorkspaceRoot
  if (Test-Path -LiteralPath $path -PathType Leaf) {
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  }
}

function Resolve-RaymanWorkerBySelector {
  param(
    [string]$WorkspaceRoot,
    [string]$WorkerId = '',
    [string]$WorkerName = '',
    [switch]$AllowActive
  )

  $registry = @((Get-RaymanWorkerRegistryDocument -WorkspaceRoot $WorkspaceRoot).workers)
  if (-not [string]::IsNullOrWhiteSpace([string]$WorkerId)) {
    return ($registry | Where-Object { [string]$_.worker_id -eq $WorkerId } | Select-Object -First 1)
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$WorkerName)) {
    return ($registry | Where-Object { [string]$_.worker_name -ieq $WorkerName } | Select-Object -First 1)
  }
  if ($AllowActive) {
    $active = Get-RaymanActiveWorkerRecord -WorkspaceRoot $WorkspaceRoot
    if ($null -ne $active -and -not [string]::IsNullOrWhiteSpace([string]$active.worker_id)) {
      return ($registry | Where-Object { [string]$_.worker_id -eq [string]$active.worker_id } | Select-Object -First 1)
    }
  }
  return $null
}

function Get-RaymanWorkerActiveExecutionContext {
  param([string]$WorkspaceRoot)

  $active = Get-RaymanActiveWorkerRecord -WorkspaceRoot $WorkspaceRoot
  if ($null -eq $active -or [string]::IsNullOrWhiteSpace([string]$active.worker_id)) {
    return $null
  }

  $worker = Resolve-RaymanWorkerBySelector -WorkspaceRoot $WorkspaceRoot -WorkerId ([string]$active.worker_id)
  if ($null -eq $worker) {
    $worker = $active
  }

  return [pscustomobject]@{
    worker = $worker
    active = $active
  }
}

function Get-RaymanWorkerControlUri {
  param(
    [object]$Worker,
    [string]$Path = ''
  )

  if ($null -eq $Worker) {
    throw 'worker is required'
  }

  $baseUrl = ''
  if ($Worker.PSObject.Properties['control_url'] -and -not [string]::IsNullOrWhiteSpace([string]$Worker.control_url)) {
    $baseUrl = [string]$Worker.control_url
  } else {
    $address = [string]$Worker.address
    $port = [int]$Worker.control_port
    if ([string]::IsNullOrWhiteSpace([string]$address) -or $port -le 0) {
      throw 'worker control endpoint is incomplete'
    }
    $baseUrl = ('http://{0}:{1}/' -f $address, $port)
  }

  if ([string]::IsNullOrWhiteSpace([string]$Path)) {
    return $baseUrl
  }
  return ([System.Uri]::new([System.Uri]$baseUrl, $Path.TrimStart('/'))).AbsoluteUri
}

function Invoke-RaymanWorkerControlRequest {
  param(
    [object]$Worker,
    [ValidateSet('GET', 'POST', 'PUT')][string]$Method,
    [string]$Path,
    [object]$Body = $null,
    [string]$InFile = '',
    [string]$ContentType = 'application/json',
    [int]$TimeoutSeconds = 30
  )

  $uri = Get-RaymanWorkerControlUri -Worker $Worker -Path $Path
  try {
    if ($Method -eq 'GET') {
      return (Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec $TimeoutSeconds)
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$InFile)) {
      $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $InFile).Path)
      $response = Invoke-WebRequest -Uri $uri -Method $Method -Body $bytes -ContentType $ContentType -TimeoutSec $TimeoutSeconds -UseBasicParsing
      if ([string]::IsNullOrWhiteSpace([string]$response.Content)) {
        return $null
      }
      return ($response.Content | ConvertFrom-Json -ErrorAction Stop)
    }

    $json = if ($null -eq $Body) { '{}' } else { ($Body | ConvertTo-Json -Depth 12) }
    return (Invoke-RestMethod -Uri $uri -Method $Method -ContentType $ContentType -Body $json -TimeoutSec $TimeoutSeconds)
  } catch {
    $payload = $null
    try {
      if ($null -ne $_.ErrorDetails -and -not [string]::IsNullOrWhiteSpace([string]$_.ErrorDetails.Message)) {
        $payload = ([string]$_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction Stop)
      }
    } catch {
      $payload = $null
    }

    try {
      if ($null -ne $payload) {
        throw 'parsed'
      }
      $response = $_.Exception.Response
      if ($null -ne $response) {
        $stream = $response.GetResponseStream()
        if ($null -ne $stream) {
          $reader = New-Object System.IO.StreamReader($stream)
          try {
            $raw = $reader.ReadToEnd()
          } finally {
            $reader.Dispose()
          }
          if (-not [string]::IsNullOrWhiteSpace([string]$raw)) {
            $payload = $raw | ConvertFrom-Json -ErrorAction Stop
          }
        }
      }
    } catch {
      if ([string]$_.Exception.Message -ne 'parsed') {
        $payload = $null
      }
    }

    if ($null -eq $payload) {
      $payload = $null
    }

    if ($null -ne $payload) {
      $message = if ($payload.PSObject.Properties['error'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.error)) { [string]$payload.error } else { $_.Exception.Message }
      $wrapped = New-Object System.Exception($message, $_.Exception)
      try { $wrapped.Data['rayman_payload'] = $payload } catch {}
      throw $wrapped
    }

    throw
  }
}

function Invoke-RaymanWorkerRemoteCommand {
  param(
    [string]$WorkspaceRoot,
    [string]$CommandText,
    [string]$DetailLogPath = ''
  )

  $context = Get-RaymanWorkerActiveExecutionContext -WorkspaceRoot $WorkspaceRoot
  if ($null -eq $context) {
    throw 'no active worker is selected'
  }

  $worker = $context.worker
  $active = $context.active
  $body = [pscustomobject]@{
    command = $CommandText
    workspace_mode = if ($null -ne $active -and $active.PSObject.Properties['workspace_mode']) { [string]$active.workspace_mode } else { 'attached' }
    sync_manifest = if ($null -ne $active -and $active.PSObject.Properties['sync_manifest']) { $active.sync_manifest } else { $null }
    timeout_seconds = (Get-RaymanWorkerExecutionTimeoutSeconds)
  }

  $response = Invoke-RaymanWorkerControlRequest -Worker $worker -Method POST -Path '/exec' -Body $body -TimeoutSeconds ([int]$body.timeout_seconds + 10)
  $outputLines = @()
  if ($null -ne $response -and $response.PSObject.Properties['output_lines']) {
    $outputLines = @($response.output_lines | ForEach-Object { [string]$_ })
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$DetailLogPath)) {
    foreach ($line in $outputLines) {
      Add-Content -LiteralPath $DetailLogPath -Encoding UTF8 -Value $line
    }
  }

  return [pscustomobject]@{
    command = [string]$CommandText
    exit_code = if ($null -ne $response -and $response.PSObject.Properties['exit_code']) { [int]$response.exit_code } else { 1 }
    success = if ($null -ne $response -and $response.PSObject.Properties['success']) { [bool]$response.success } else { $false }
    error_message = if ($null -ne $response -and $response.PSObject.Properties['error_message']) { [string]$response.error_message } else { '' }
    output_lines = @($outputLines)
    execution_host = 'worker'
    worker_id = [string]$worker.worker_id
    worker_name = [string]$worker.worker_name
    workspace_mode = [string]$body.workspace_mode
    sync_manifest = $body.sync_manifest
  }
}

function Save-RaymanWorkerDiscoverySummary {
  param(
    [string]$WorkspaceRoot,
    [object]$Summary
  )

  Write-RaymanWorkerJsonFile -Path (Get-RaymanWorkerDiscoveryLastPath -WorkspaceRoot $WorkspaceRoot) -Value $Summary
}

function Save-RaymanWorkerDebugManifest {
  param(
    [string]$WorkspaceRoot,
    [object]$Manifest
  )

  Write-RaymanWorkerJsonFile -Path (Get-RaymanWorkerDebugLastPath -WorkspaceRoot $WorkspaceRoot) -Value $Manifest
}

function Get-RaymanWorkerDebugManifest {
  param([string]$WorkspaceRoot)

  return (Read-RaymanWorkerJsonFile -Path (Get-RaymanWorkerDebugLastPath -WorkspaceRoot $WorkspaceRoot))
}

function Update-RaymanWorkerLaunchBindings {
  param(
    [string]$WorkspaceRoot,
    [object]$Manifest
  )

  $launchPath = Join-Path $WorkspaceRoot '.vscode\launch.json'
  if (-not (Test-Path -LiteralPath $launchPath -PathType Leaf)) {
    return $null
  }

  $doc = Read-RaymanWorkerJsonFile -Path $launchPath -AsHashtable
  if ($null -eq $doc) {
    return $null
  }
  if (-not $doc.ContainsKey('configurations')) {
    $doc['configurations'] = @()
  }

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $sourceFileMap = @{}
  if ($null -ne $Manifest -and $Manifest.PSObject.Properties['source_file_map']) {
    foreach ($prop in $Manifest.source_file_map.PSObject.Properties) {
      $sourceFileMap[[string]$prop.Name] = [string]$prop.Value
    }
  }
  if ($sourceFileMap.Count -eq 0 -and $null -ne $Manifest -and $Manifest.PSObject.Properties['execution_root']) {
    $sourceFileMap[[string]$Manifest.execution_root] = $resolvedRoot
  }

  $program = if ($null -ne $Manifest -and $Manifest.PSObject.Properties['program']) { [string]$Manifest.program } else { '' }
  $cwd = if ($null -ne $Manifest -and $Manifest.PSObject.Properties['cwd']) { [string]$Manifest.cwd } else { '' }
  $debuggerPath = if ($null -ne $Manifest -and $Manifest.PSObject.Properties['debugger_path']) { [string]$Manifest.debugger_path } else { '' }
  $pipeArgs = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    '${workspaceFolder}/.Rayman/scripts/worker/worker_pipe_transport.ps1',
    '-WorkspaceRoot',
    '${workspaceFolder}'
  )

  $configurations = @($doc['configurations'])
  foreach ($config in $configurations) {
    if ($null -eq $config) { continue }
    $name = if ($config.ContainsKey('name')) { [string]$config['name'] } else { '' }
    if ($name -notin @('Rayman Worker: Launch .NET (Active Worker)', 'Rayman Worker: Attach .NET (Active Worker)')) {
      continue
    }

    $config['type'] = 'coreclr'
    $config['pipeTransport'] = @{
      pipeProgram = 'powershell.exe'
      pipeArgs = @($pipeArgs)
      pipeCwd = '${workspaceFolder}'
      debuggerPath = $debuggerPath
      quoteArgs = $true
    }
    $config['sourceFileMap'] = $sourceFileMap
    $config['justMyCode'] = $true
    $config['requireExactSource'] = $false
    $config['preLaunchTask'] = 'Rayman: Worker Debug Prepare'

    if ($name -eq 'Rayman Worker: Launch .NET (Active Worker)') {
      $config['request'] = 'launch'
      $config['program'] = $program
      $config['cwd'] = $cwd
      if (-not $config.ContainsKey('console')) {
        $config['console'] = 'internalConsole'
      }
    } else {
      $config['request'] = 'attach'
      $config['processId'] = '${input:raymanWorkerAttachProcessId}'
      if (-not [string]::IsNullOrWhiteSpace([string]$cwd)) {
        $config['cwd'] = $cwd
      }
    }
  }

  $doc['configurations'] = $configurations
  Write-RaymanWorkerJsonFile -Path $launchPath -Value $doc
  return $doc
}

function New-RaymanWorkerDebugManifest {
  param(
    [string]$WorkspaceRoot,
    [string]$Mode = 'launch',
    [object]$SyncManifest = $null,
    [string]$Program = '',
    [int]$ProcessId = 0,
    [switch]$SkipDebuggerInstall
  )

  $resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $executionRoot = Get-RaymanWorkerExecutionRoot -WorkspaceRoot $resolvedWorkspaceRoot -SyncManifest $SyncManifest
  $workerId = Get-RaymanWorkerStableId -WorkspaceRoot $resolvedWorkspaceRoot
  $vsdbgStatus = if ($SkipDebuggerInstall) {
    Get-RaymanWorkerVsdbgStatus -WorkspaceRoot $resolvedWorkspaceRoot
  } else {
    Ensure-RaymanWorkerVsdbg -WorkspaceRoot $resolvedWorkspaceRoot
  }
  if (-not [bool]$vsdbgStatus.debugger_ready) {
    $message = if ($vsdbgStatus.PSObject.Properties['debugger_error'] -and -not [string]::IsNullOrWhiteSpace([string]$vsdbgStatus.debugger_error)) {
      [string]$vsdbgStatus.debugger_error
    } else {
      'vsdbg is not ready'
    }
    throw $message
  }

  $resolvedProgram = Get-RaymanWorkerDefaultDebugTarget -ExecutionRoot $executionRoot -ProgramOverride $Program
  if ($Mode -eq 'launch') {
    if ([string]::IsNullOrWhiteSpace([string]$resolvedProgram)) {
      throw 'launch debug target could not be resolved; pass --program or build a debuggable .NET entrypoint on the worker.'
    }
    if (-not (Test-Path -LiteralPath $resolvedProgram -PathType Leaf)) {
      throw ("launch debug target not found: {0}" -f $resolvedProgram)
    }
  }
  $sourceMap = [ordered]@{}
  $sourceMap[$executionRoot] = $resolvedWorkspaceRoot

  return [pscustomobject]@{
    schema = 'rayman.worker.debug_session.v1'
    generated_at = (Get-Date).ToString('o')
    mode = $Mode
    worker_id = $workerId
    worker_name = (Get-RaymanWorkerDisplayName -WorkspaceRoot $resolvedWorkspaceRoot)
    address = (Get-RaymanWorkerPrimaryAddress)
    control_port = (Get-RaymanWorkerControlPort)
    control_url = ('http://{0}:{1}/' -f (Get-RaymanWorkerPrimaryAddress), (Get-RaymanWorkerControlPort))
    workspace_root = $resolvedWorkspaceRoot
    execution_root = $executionRoot
    workspace_mode = if ($null -ne $SyncManifest -and $SyncManifest.PSObject.Properties['mode']) { [string]$SyncManifest.mode } else { 'attached' }
    debugger_ready = [bool]$vsdbgStatus.debugger_ready
    debugger_path = [string]$vsdbgStatus.debugger_path
    program = $resolvedProgram
    cwd = $executionRoot
    process_id = $ProcessId
    sync_manifest = $SyncManifest
    source_file_map = [pscustomobject]$sourceMap
    candidate_processes = @(Get-RaymanWorkerDotNetProcesses -ExecutionRoot $executionRoot)
    candidate_entrypoints = @(Get-RaymanWorkerDotNetEntrypoints -ExecutionRoot $executionRoot)
  }
}

function Invoke-RaymanWorkerLocalCommand {
  param(
    [string]$WorkspaceRoot,
    [string]$ExecutionRoot,
    [string]$CommandText,
    [int]$TimeoutSeconds = 0
  )

  $psHost = if (Get-Command Resolve-RaymanPowerShellHost -ErrorAction SilentlyContinue) {
    Resolve-RaymanPowerShellHost
  } else {
    $null
  }
  if ([string]::IsNullOrWhiteSpace([string]$psHost)) {
    foreach ($candidate in @('powershell.exe', 'powershell', 'pwsh.exe', 'pwsh')) {
      $cmd = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        $psHost = [string]$cmd.Source
        break
      }
    }
  }
  if ([string]::IsNullOrWhiteSpace([string]$psHost)) {
    throw 'PowerShell host not found'
  }

  $executionEscaped = $ExecutionRoot.Replace("'", "''")
  $commandBody = @"
`$ProgressPreference = 'SilentlyContinue'
Set-Location '$executionEscaped'
$CommandText
exit `$LASTEXITCODE
"@
  if ($TimeoutSeconds -le 0) {
    $TimeoutSeconds = Get-RaymanWorkerExecutionTimeoutSeconds
  }
  $timeoutMilliseconds = [Math]::Max(1000, ($TimeoutSeconds * 1000))
  $capture = Invoke-RaymanWorkerNativeCommandCapture -FilePath $psHost -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $commandBody) -WorkingDirectory $WorkspaceRoot -TimeoutMilliseconds $timeoutMilliseconds
  $lines = @($capture.stdout + $capture.stderr)
  $exitCode = if ([bool]$capture.timed_out) { 124 } else { [int]$capture.exit_code }
  $errorMessage = if ([bool]$capture.timed_out) {
    "command timed out after $TimeoutSeconds seconds"
  } else {
    [string]$capture.error
  }
  return [pscustomobject]@{
    success = [bool]$capture.success
    exit_code = $exitCode
    error_message = $errorMessage
    output_lines = @($lines | ForEach-Object { [string]$_ })
    execution_root = $ExecutionRoot
    command = [string]$CommandText
  }
}
