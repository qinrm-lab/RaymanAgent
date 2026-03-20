param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
  throw "common.ps1 not found: $commonPath"
}
. $commonPath

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path

function Convert-RaymanOwnedPsSingleQuotedLiteral([string]$Value) {
  if ($null -eq $Value) { return '' }
  return $Value.Replace("'", "''")
}

function ConvertTo-RaymanOwnedStableHash([string]$Value) {
  $text = if ($null -eq $Value) { '' } else { [string]$Value }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
  $sha = [System.Security.Cryptography.SHA1]::Create()
  try {
    $hashBytes = $sha.ComputeHash($bytes)
  } finally {
    $sha.Dispose()
  }
  return ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
}

function Get-RaymanOwnedProcessRegistryPath {
  param(
    [string]$WorkspaceRootPath
  )

  return (Join-Path $WorkspaceRootPath '.Rayman\runtime\workspace_owned_processes.json')
}

function Get-RaymanOwnedProcessPathComparisonValue {
  param(
    [string]$PathValue
  )

  if (Get-Command Get-RaymanPathComparisonValue -ErrorAction SilentlyContinue) {
    return (Get-RaymanPathComparisonValue -PathValue $PathValue)
  }

  if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
  try {
    $full = [System.IO.Path]::GetFullPath($PathValue)
    return ($full.TrimEnd('\', '/') -replace '\\', '/').ToLowerInvariant()
  } catch {
    return (($PathValue -replace '\\', '/').TrimEnd('/', '\')).ToLowerInvariant()
  }
}

function Resolve-RaymanOwnedWindowsPowerShellPath {
  if (Test-RaymanWindowsPlatform) {
    foreach ($candidate in @('powershell.exe', 'powershell', 'pwsh.exe', 'pwsh')) {
      $cmd = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        return [string]$cmd.Source
      }
    }
  } else {
    $cmd = Get-Command 'powershell.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
      return [string]$cmd.Source
    }
  }

  return $null
}

function Resolve-RaymanOwnedTaskKillPath {
  foreach ($candidate in @('taskkill.exe', 'taskkill')) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
      return [string]$cmd.Source
    }
  }

  if (Test-RaymanWindowsPlatform) {
    $fallback = Join-Path $env:WINDIR 'System32\taskkill.exe'
    if (Test-Path -LiteralPath $fallback -PathType Leaf) {
      return $fallback
    }
  }

  return $null
}

function Convert-RaymanOwnedPathToWindows {
  param(
    [string]$PathValue
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
  if (Test-RaymanWindowsPlatform) {
    try {
      return [System.IO.Path]::GetFullPath($PathValue)
    } catch {
      return $PathValue
    }
  }

  $wslPathCmd = Get-Command 'wslpath' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $wslPathCmd -or [string]::IsNullOrWhiteSpace([string]$wslPathCmd.Source)) {
    return ''
  }

  try {
    $converted = (& $wslPathCmd.Source -w $PathValue | Select-Object -First 1)
    return ([string]$converted).Trim()
  } catch {
    return ''
  }
}

function Get-RaymanOwnedInteropFilePath {
  param(
    [string]$WorkspaceRootPath,
    [string]$Prefix
  )

  $runtimeDir = Join-Path $WorkspaceRootPath '.Rayman\runtime'
  if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
  }

  return (Join-Path $runtimeDir ("{0}.{1}.json" -f $Prefix, [Guid]::NewGuid().ToString('N')))
}

function Invoke-RaymanOwnedWindowsJsonQuery {
  param(
    [string]$WorkspaceRootPath,
    [string]$ScriptBody,
    [string]$Prefix = 'owned_process'
  )

  if ([string]::IsNullOrWhiteSpace($ScriptBody)) { return $null }
  $psPath = Resolve-RaymanOwnedWindowsPowerShellPath
  if ([string]::IsNullOrWhiteSpace($psPath)) { return $null }

  $resultPath = Get-RaymanOwnedInteropFilePath -WorkspaceRootPath $WorkspaceRootPath -Prefix $Prefix
  $resultPathWindows = Convert-RaymanOwnedPathToWindows -PathValue $resultPath
  if ([string]::IsNullOrWhiteSpace($resultPathWindows)) { return $null }

  $template = @'
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
function Write-Result([object]$Value) {
  ($Value | ConvertTo-Json -Depth 10 -Compress) | Set-Content -LiteralPath '__RESULT__' -Encoding UTF8
}
__BODY__
'@
  $command = $template.Replace('__RESULT__', (Convert-RaymanOwnedPsSingleQuotedLiteral -Value $resultPathWindows)).Replace('__BODY__', $ScriptBody)

  try {
    & $psPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command | Out-Null
  } catch {
    try { Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue } catch {}
    return $null
  }

  if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
    return $null
  }

  try {
    return (Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  } finally {
    try { Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue } catch {}
  }
}

function Resolve-RaymanOwnedProcessOwnerPid {
  param(
    [string]$ExplicitOwnerPid = ''
  )

  $parsed = 0
  if (-not [string]::IsNullOrWhiteSpace($ExplicitOwnerPid) -and [int]::TryParse($ExplicitOwnerPid.Trim(), [ref]$parsed) -and $parsed -gt 0) {
    return $parsed
  }

  $envPid = [string][Environment]::GetEnvironmentVariable('VSCODE_PID')
  if (-not [string]::IsNullOrWhiteSpace($envPid) -and [int]::TryParse($envPid.Trim(), [ref]$parsed) -and $parsed -gt 0) {
    return $parsed
  }

  if (-not (Test-RaymanWindowsPlatform)) {
    return 0
  }

  $visited = New-Object 'System.Collections.Generic.HashSet[int]'
  $currentPid = [int]$PID
  $hop = 0
  while ($currentPid -gt 0 -and $hop -lt 12) {
    if ($visited.Contains($currentPid)) { break }
    [void]$visited.Add($currentPid)

    $proc = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $currentPid) -ErrorAction SilentlyContinue
    if ($null -eq $proc) { break }
    $parentPid = [int]$proc.ParentProcessId
    if ($parentPid -le 0) { break }

    $parent = Get-Process -Id $parentPid -ErrorAction SilentlyContinue
    if ($null -ne $parent) {
      $name = [string]$parent.ProcessName
      if ($name -like 'Code*') {
        return $parentPid
      }
    }

    $currentPid = $parentPid
    $hop++
  }

  return 0
}

function Resolve-RaymanOwnedParsedPid {
  param(
    [string]$Value
  )

  $parsed = 0
  if (-not [string]::IsNullOrWhiteSpace($Value) -and [int]::TryParse($Value.Trim(), [ref]$parsed) -and $parsed -gt 0) {
    return $parsed
  }

  return 0
}

function Get-RaymanOwnedVsCodeSessionDir {
  param(
    [string]$WorkspaceRootPath
  )

  return (Join-Path $WorkspaceRootPath '.Rayman\runtime\vscode_sessions')
}

function Resolve-RaymanOwnedSessionOwnerPid {
  param(
    [string]$WorkspaceRootPath
  )

  $sessionDir = Get-RaymanOwnedVsCodeSessionDir -WorkspaceRootPath $WorkspaceRootPath
  if (-not (Test-Path -LiteralPath $sessionDir -PathType Container)) {
    return 0
  }

  $candidatePids = New-Object System.Collections.Generic.List[int]
  foreach ($sessionFile in @(Get-ChildItem -LiteralPath $sessionDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    if ($null -eq $sessionFile) { continue }

    $sessionPid = Resolve-RaymanOwnedParsedPid -Value ([System.IO.Path]::GetFileNameWithoutExtension([string]$sessionFile.Name))
    if ($sessionPid -le 0) {
      try {
        $session = Get-Content -LiteralPath $sessionFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $session -and $session.PSObject.Properties['parentPid']) {
          $sessionPid = Resolve-RaymanOwnedParsedPid -Value ([string]$session.parentPid)
        }
      } catch {}
    }

    if ($sessionPid -gt 0) {
      $candidatePids.Add($sessionPid) | Out-Null
    }
  }

  $uniquePids = @($candidatePids.ToArray() | Select-Object -Unique)
  if ($uniquePids.Count -eq 1) {
    return [int]$uniquePids[0]
  }

  return 0
}

function Get-RaymanWorkspaceProcessOwnerContext {
  param(
    [string]$WorkspaceRootPath,
    [string]$ExplicitOwnerPid = ''
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRootPath).Path
  $workspaceNorm = Get-RaymanOwnedProcessPathComparisonValue -PathValue $resolvedRoot
  $workspaceHash = ConvertTo-RaymanOwnedStableHash -Value $workspaceNorm

  $ownerSource = 'workspace-root'
  $ownerToken = $resolvedRoot
  $ownerDisplay = ('workspace#{0}' -f $workspaceHash.Substring(0, [Math]::Min(12, $workspaceHash.Length)))

  $explicitOwnerPidValue = Resolve-RaymanOwnedParsedPid -Value $ExplicitOwnerPid
  $envVscodePid = [string][Environment]::GetEnvironmentVariable('VSCODE_PID')
  $envVscodePidValue = Resolve-RaymanOwnedParsedPid -Value $envVscodePid
  $sessionOwnerPid = 0
  if ($envVscodePidValue -gt 0) {
    $ownerSource = 'VSCODE_PID'
    $ownerToken = [string]$envVscodePidValue
    $ownerDisplay = ('VSCODE_PID#{0}' -f $envVscodePidValue)
  } elseif (-not [string]::IsNullOrWhiteSpace($envVscodePid)) {
    $ownerSource = 'VSCODE_PID'
    $ownerToken = $envVscodePid.Trim()
    $ownerDisplay = ('VSCODE_PID#{0}' -f $ownerToken)
  } else {
    foreach ($name in @('RAYMAN_VSCODE_WINDOW_OWNER', 'VSCODE_IPC_HOOK_CLI', 'VSCODE_IPC_HOOK')) {
      $candidate = [string][Environment]::GetEnvironmentVariable($name)
      if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $ownerSource = $name
        $ownerToken = $candidate.Trim()
        $ownerDisplay = ('{0}#{1}' -f $name, (ConvertTo-RaymanOwnedStableHash -Value $ownerToken).Substring(0, 12))
        break
      }
    }

    if ($ownerSource -eq 'workspace-root') {
      $sessionOwnerPid = Resolve-RaymanOwnedSessionOwnerPid -WorkspaceRootPath $resolvedRoot
      if ($sessionOwnerPid -gt 0) {
        $ownerSource = 'VSCODE_PID'
        $ownerToken = [string]$sessionOwnerPid
        $ownerDisplay = ('VSCODE_PID#{0}' -f $sessionOwnerPid)
      } elseif ($explicitOwnerPidValue -gt 0) {
        $ownerSource = 'VSCODE_PID'
        $ownerToken = [string]$explicitOwnerPidValue
        $ownerDisplay = ('VSCODE_PID#{0}' -f $explicitOwnerPidValue)
      } else {
        $ownerPid = Resolve-RaymanOwnedProcessOwnerPid
        if ($ownerPid -gt 0) {
          $ownerSource = 'VSCODE_PID'
          $ownerToken = [string]$ownerPid
          $ownerDisplay = ('VSCODE_PID#{0}' -f $ownerPid)
        }
      }
    }
  }

  $ownerHash = ConvertTo-RaymanOwnedStableHash -Value $ownerToken

  return [pscustomobject]@{
    workspace_root = $resolvedRoot
    workspace_hash = $workspaceHash
    owner_source = $ownerSource
    owner_token = $ownerToken
    owner_hash = $ownerHash
    owner_key = ('{0}:{1}:{2}' -f $ownerSource, $ownerHash, $workspaceHash)
    owner_display = $ownerDisplay
  }
}

function Get-RaymanWorkspaceSharedProcessOwnerContext {
  param(
    [string]$WorkspaceRootPath
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRootPath).Path
  $workspaceNorm = Get-RaymanOwnedProcessPathComparisonValue -PathValue $resolvedRoot
  $workspaceHash = ConvertTo-RaymanOwnedStableHash -Value $workspaceNorm
  $ownerSource = 'workspace-shared'
  $ownerToken = ('shared::{0}' -f $workspaceNorm)
  $ownerHash = ConvertTo-RaymanOwnedStableHash -Value $ownerToken

  return [pscustomobject]@{
    workspace_root = $resolvedRoot
    workspace_hash = $workspaceHash
    owner_source = $ownerSource
    owner_token = $ownerToken
    owner_hash = $ownerHash
    owner_key = ('{0}:{1}:{2}' -f $ownerSource, $ownerHash, $workspaceHash)
    owner_display = ('workspace-shared#{0}' -f $workspaceHash.Substring(0, [Math]::Min(12, $workspaceHash.Length)))
  }
}

function Read-RaymanOwnedProcessRegistryRaw {
  param(
    [string]$WorkspaceRootPath
  )

  $registryPath = Get-RaymanOwnedProcessRegistryPath -WorkspaceRootPath $WorkspaceRootPath
  if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
    return @()
  }

  try {
    $raw = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $data = $raw | ConvertFrom-Json -ErrorAction Stop
    if ($data -is [System.Array]) {
      return @($data)
    }
    return @($data)
  } catch {
    return @()
  }
}

function Save-RaymanOwnedProcessRegistry {
  param(
    [string]$WorkspaceRootPath,
    [object[]]$Records
  )

  $registryPath = Get-RaymanOwnedProcessRegistryPath -WorkspaceRootPath $WorkspaceRootPath
  $dir = Split-Path -Parent $registryPath
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }

  $payload = @($Records | Where-Object { $null -ne $_ })
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($registryPath, ($payload | ConvertTo-Json -Depth 10), $utf8NoBom)
}

function Get-RaymanOwnedWindowsProcessDetails {
  param(
    [string]$WorkspaceRootPath,
    [int]$ProcessId
  )

  if ($ProcessId -le 0) {
    return [pscustomobject]@{
      alive = $false
      pid = 0
      start_utc = ''
      process_name = ''
    }
  }

  if (Test-RaymanWindowsPlatform) {
    try {
      $proc = Get-Process -Id $ProcessId -ErrorAction Stop
      return [pscustomobject]@{
        alive = $true
        pid = [int]$proc.Id
        start_utc = $proc.StartTime.ToUniversalTime().ToString('o')
        process_name = [string]$proc.ProcessName
      }
    } catch {
      return [pscustomobject]@{
        alive = $false
        pid = $ProcessId
        start_utc = ''
        process_name = ''
      }
    }
  }

  $body = @"
`$proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
if (`$null -eq `$proc) {
  Write-Result @{
    alive = `$false
    pid = $ProcessId
    start_utc = ''
    process_name = ''
  }
  exit 0
}
Write-Result @{
  alive = `$true
  pid = [int]`$proc.Id
  start_utc = `$proc.StartTime.ToUniversalTime().ToString('o')
  process_name = [string]`$proc.ProcessName
}
"@
  $result = Invoke-RaymanOwnedWindowsJsonQuery -WorkspaceRootPath $WorkspaceRootPath -ScriptBody $body -Prefix 'owned_process_alive'
  if ($null -eq $result) {
    return [pscustomobject]@{
      alive = $false
      pid = $ProcessId
      start_utc = ''
      process_name = ''
    }
  }

  return $result
}

function ConvertTo-RaymanOwnedProcessStartInstant {
  param([object]$Value)

  if ($null -eq $Value) { return $null }
  if ($Value -is [System.DateTimeOffset]) {
    return ([System.DateTimeOffset]$Value).ToUniversalTime()
  }
  if ($Value -is [System.DateTime]) {
    return ([System.DateTimeOffset]([System.DateTime]$Value).ToUniversalTime())
  }

  $text = [string]$Value
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }

  $instant = [System.DateTimeOffset]::MinValue
  if ([System.DateTimeOffset]::TryParse($text, [ref]$instant)) {
    return $instant.ToUniversalTime()
  }

  return $null
}

function Test-RaymanOwnedProcessAlive {
  param(
    [string]$WorkspaceRootPath,
    [object]$Record
  )

  if ($null -eq $Record) { return $false }
  $rootPid = 0
  try { $rootPid = [int]$Record.root_pid } catch { $rootPid = 0 }
  if ($rootPid -le 0) { return $false }

  $details = Get-RaymanOwnedWindowsProcessDetails -WorkspaceRootPath $WorkspaceRootPath -ProcessId $rootPid
  if (-not [bool]$details.alive) { return $false }

  $expectedStart = $null
  if ($Record.PSObject.Properties['started_at']) {
    $expectedStart = $Record.started_at
  }
  if ($null -eq $expectedStart) { return $true }
  if ($expectedStart -is [string] -and [string]::IsNullOrWhiteSpace([string]$expectedStart)) { return $true }

  $actualStart = $details.start_utc
  if ([string]$actualStart -eq [string]$expectedStart) {
    return $true
  }

  $expectedInstant = ConvertTo-RaymanOwnedProcessStartInstant -Value $expectedStart
  $actualInstant = ConvertTo-RaymanOwnedProcessStartInstant -Value $actualStart
  if ($null -ne $expectedInstant -and $null -ne $actualInstant) {
    return ([Math]::Abs(($actualInstant - $expectedInstant).TotalSeconds) -lt 2)
  }

  return $false
}

function Get-RaymanWindowsProcessTreePids {
  param(
    [string]$WorkspaceRootPath,
    [int]$RootPid,
    [switch]$IncludeRoot
  )

  if ($RootPid -le 0) { return @() }

  if (Test-RaymanWindowsPlatform) {
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) {
      return $(if ($IncludeRoot) { @($RootPid) } else { @() })
    }

    $childrenByParent = @{}
    foreach ($proc in $processes) {
      $parentPid = [int]$proc.ParentProcessId
      if (-not $childrenByParent.ContainsKey($parentPid)) {
        $childrenByParent[$parentPid] = New-Object System.Collections.Generic.List[int]
      }
      $childrenByParent[$parentPid].Add([int]$proc.ProcessId) | Out-Null
    }

    $visited = New-Object 'System.Collections.Generic.HashSet[int]'
    $queue = New-Object 'System.Collections.Generic.Queue[int]'
    $queue.Enqueue($RootPid)
    while ($queue.Count -gt 0) {
      $current = [int]$queue.Dequeue()
      if ($visited.Contains($current)) { continue }
      [void]$visited.Add($current)
      if ($childrenByParent.ContainsKey($current)) {
        foreach ($childPid in $childrenByParent[$current]) {
          if (-not $visited.Contains([int]$childPid)) {
            $queue.Enqueue([int]$childPid)
          }
        }
      }
    }

    $values = @($visited | ForEach-Object { [int]$_ } | Sort-Object)
    if (-not $IncludeRoot) {
      $values = @($values | Where-Object { [int]$_ -ne $RootPid })
    }
    return $values
  }

  $body = @"
`$rootPid = $RootPid
`$processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
`$childrenByParent = @{}
foreach (`$proc in `$processes) {
  `$parentPid = [int]`$proc.ParentProcessId
  if (-not `$childrenByParent.ContainsKey(`$parentPid)) {
    `$childrenByParent[`$parentPid] = New-Object System.Collections.Generic.List[int]
  }
  `$childrenByParent[`$parentPid].Add([int]`$proc.ProcessId) | Out-Null
}
`$visited = New-Object 'System.Collections.Generic.HashSet[int]'
`$queue = New-Object 'System.Collections.Generic.Queue[int]'
`$queue.Enqueue(`$rootPid)
while (`$queue.Count -gt 0) {
  `$current = [int]`$queue.Dequeue()
  if (`$visited.Contains(`$current)) { continue }
  [void]`$visited.Add(`$current)
  if (`$childrenByParent.ContainsKey(`$current)) {
    foreach (`$childPid in `$childrenByParent[`$current]) {
      if (-not `$visited.Contains([int]`$childPid)) {
        `$queue.Enqueue([int]`$childPid)
      }
    }
  }
}
Write-Result (@(`$visited | ForEach-Object { [int]`$_ } | Sort-Object))
"@
  $result = Invoke-RaymanOwnedWindowsJsonQuery -WorkspaceRootPath $WorkspaceRootPath -ScriptBody $body -Prefix 'owned_process_tree'
  $values = @()
  if ($null -ne $result) {
    $values = @($result | ForEach-Object { [int]$_ })
  }
  if (-not $IncludeRoot) {
    $values = @($values | Where-Object { [int]$_ -ne $RootPid })
  }
  return @($values | Select-Object -Unique)
}

function Find-RaymanOwnedWindowsProcessIdsByCommandLineNeedle {
  param(
    [string]$WorkspaceRootPath,
    [string]$Needle,
    [string[]]$ProcessNames = @()
  )

  if ([string]::IsNullOrWhiteSpace($Needle)) { return @() }

  $needleLower = $Needle.ToLowerInvariant()
  $nameSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($processName in @($ProcessNames)) {
    if (-not [string]::IsNullOrWhiteSpace($processName)) {
      [void]$nameSet.Add($processName.Trim())
    }
  }

  if (Test-RaymanWindowsPlatform) {
    $matches = New-Object System.Collections.Generic.List[int]
    foreach ($proc in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
      if ($null -eq $proc) { continue }
      $procName = [string]$proc.Name
      if ($nameSet.Count -gt 0 -and -not $nameSet.Contains($procName)) { continue }
      $commandLine = [string]$proc.CommandLine
      if ([string]::IsNullOrWhiteSpace($commandLine)) { continue }
      if ($commandLine.ToLowerInvariant().Contains($needleLower)) {
        $matches.Add([int]$proc.ProcessId) | Out-Null
      }
    }
    return @($matches.ToArray() | Sort-Object -Descending | Select-Object -Unique)
  }

  $processNameLiteral = @($nameSet | ForEach-Object {
    "'" + (Convert-RaymanOwnedPsSingleQuotedLiteral -Value [string]$_) + "'"
  }) -join ','
  $nameFilter = if ($nameSet.Count -gt 0) {
    "`$nameSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)`nforeach (`$name in @($processNameLiteral)) { [void]`$nameSet.Add([string]`$name) }"
  } else {
    "`$nameSet = `$null"
  }
  $body = @"
$nameFilter
`$needle = '$(Convert-RaymanOwnedPsSingleQuotedLiteral -Value $Needle)'
`$matches = New-Object System.Collections.Generic.List[int]
foreach (`$proc in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
  if (`$null -eq `$proc) { continue }
  `$procName = [string]`$proc.Name
  if (`$null -ne `$nameSet -and -not `$nameSet.Contains(`$procName)) { continue }
  `$commandLine = [string]`$proc.CommandLine
  if ([string]::IsNullOrWhiteSpace(`$commandLine)) { continue }
  if (`$commandLine.ToLowerInvariant().Contains(`$needle.ToLowerInvariant())) {
    `$matches.Add([int]`$proc.ProcessId) | Out-Null
  }
}
Write-Result (@(`$matches.ToArray() | Sort-Object -Descending | Select-Object -Unique))
"@
  $result = Invoke-RaymanOwnedWindowsJsonQuery -WorkspaceRootPath $WorkspaceRootPath -ScriptBody $body -Prefix 'owned_process_cmdline'
  if ($null -eq $result) {
    return @()
  }

  return @($result | ForEach-Object { [int]$_ } | Select-Object -Unique)
}

function Set-RaymanWorkspaceOwnedProcessState {
  param(
    [string]$WorkspaceRootPath,
    [int]$RootPid,
    [string]$State
  )

  if ($RootPid -le 0 -or [string]::IsNullOrWhiteSpace($State)) { return }
  $records = @(Read-RaymanOwnedProcessRegistryRaw -WorkspaceRootPath $WorkspaceRootPath)
  $changed = $false
  foreach ($record in $records) {
    $recordPid = 0
    try { $recordPid = [int]$record.root_pid } catch { $recordPid = 0 }
    if ($recordPid -ne $RootPid) { continue }
    $record.state = $State
    $changed = $true
  }

  if ($changed) {
    Save-RaymanOwnedProcessRegistry -WorkspaceRootPath $WorkspaceRootPath -Records $records
  }
}

function Get-RaymanWorkspaceOwnedProcessRecords {
  param(
    [string]$WorkspaceRootPath
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRootPath).Path
  $records = @(Read-RaymanOwnedProcessRegistryRaw -WorkspaceRootPath $resolvedRoot)
  if ($records.Count -eq 0) { return @() }

  $filtered = New-Object System.Collections.Generic.List[object]
  foreach ($record in $records) {
    if ($null -eq $record) { continue }
    if (-not $record.PSObject.Properties['workspace_root']) { continue }
    if (-not $record.PSObject.Properties['owner_key']) { continue }
    if (-not $record.PSObject.Properties['root_pid']) { continue }

    $recordRoot = [string]$record.workspace_root
    if ((Get-RaymanOwnedProcessPathComparisonValue -PathValue $recordRoot) -ne (Get-RaymanOwnedProcessPathComparisonValue -PathValue $resolvedRoot)) {
      continue
    }

    if (Test-RaymanOwnedProcessAlive -WorkspaceRootPath $resolvedRoot -Record $record) {
      $filtered.Add($record) | Out-Null
    }
  }

  $filteredArray = @($filtered.ToArray())
  if ($filteredArray.Count -ne $records.Count) {
    Save-RaymanOwnedProcessRegistry -WorkspaceRootPath $resolvedRoot -Records $filteredArray
  }

  return $filteredArray
}

function Register-RaymanWorkspaceOwnedProcess {
  param(
    [string]$WorkspaceRootPath,
    [object]$OwnerContext,
    [string]$Kind,
    [string]$Launcher,
    [int]$RootPid,
    [string]$Command,
    [string]$State = 'running'
  )

  if ($RootPid -le 0) { return $null }
  if ($null -eq $OwnerContext) {
    $OwnerContext = Get-RaymanWorkspaceProcessOwnerContext -WorkspaceRootPath $WorkspaceRootPath
  }

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRootPath).Path
  $records = @(Get-RaymanWorkspaceOwnedProcessRecords -WorkspaceRootPath $resolvedRoot)
  $remaining = @($records | Where-Object {
    $recordRootValue = 0
    try { $recordRootValue = [int]$_.root_pid } catch { $recordRootValue = 0 }
    $recordRootValue -ne $RootPid
  })

  $details = Get-RaymanOwnedWindowsProcessDetails -WorkspaceRootPath $resolvedRoot -ProcessId $RootPid
  $startedAt = if ([bool]$details.alive -and -not [string]::IsNullOrWhiteSpace([string]$details.start_utc)) { [string]$details.start_utc } else { (Get-Date).ToUniversalTime().ToString('o') }

  $record = [pscustomobject]@{
    workspace_root = $resolvedRoot
    owner_key = [string]$OwnerContext.owner_key
    owner_display = [string]$OwnerContext.owner_display
    kind = [string]$Kind
    launcher = [string]$Launcher
    root_pid = $RootPid
    started_at = $startedAt
    command = [string]$Command
    state = [string]$State
  }

  $remaining += $record
  Save-RaymanOwnedProcessRegistry -WorkspaceRootPath $resolvedRoot -Records $remaining
  return $record
}

function Remove-RaymanWorkspaceOwnedProcess {
  param(
    [string]$WorkspaceRootPath,
    [int]$RootPid
  )

  if ($RootPid -le 0) { return }
  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRootPath).Path
  $records = @(Read-RaymanOwnedProcessRegistryRaw -WorkspaceRootPath $resolvedRoot)
  $remaining = @($records | Where-Object {
    $recordRootValue = 0
    try { $recordRootValue = [int]$_.root_pid } catch { $recordRootValue = 0 }
    $recordRootValue -ne $RootPid
  })
  Save-RaymanOwnedProcessRegistry -WorkspaceRootPath $resolvedRoot -Records $remaining
}

function Invoke-RaymanTaskKillTree {
  param(
    [int]$RootPid
  )

  $taskKillPath = Resolve-RaymanOwnedTaskKillPath
  if ([string]::IsNullOrWhiteSpace($taskKillPath) -or $RootPid -le 0) {
    return $false
  }

  try {
    $null = & $taskKillPath /PID $RootPid /T /F 2>$null
  } catch {
    return $false
  }
  $exitCode = 0
  if (Test-Path variable:LASTEXITCODE) {
    $exitCode = [int]$LASTEXITCODE
  }
  return ($exitCode -eq 0)
}

function Invoke-RaymanStopWindowsPids {
  param(
    [string]$WorkspaceRootPath,
    [int[]]$Pids
  )

  $targets = @($Pids | Where-Object { [int]$_ -gt 0 } | Select-Object -Unique)
  if ($targets.Count -eq 0) { return }

  if (Test-RaymanWindowsPlatform) {
    foreach ($pidValue in ($targets | Sort-Object -Descending)) {
      try { Stop-Process -Id ([int]$pidValue) -Force -ErrorAction SilentlyContinue } catch {}
    }
    return
  }

  $pidAssignments = (($targets | ForEach-Object { [string][int]$_ }) -join ',')
  $body = @"
`$pids = @($pidAssignments)
foreach (`$pidValue in (`$pids | Sort-Object -Descending)) {
  try { Stop-Process -Id ([int]`$pidValue) -Force -ErrorAction SilentlyContinue } catch {}
}
Write-Result @{ ok = `$true }
"@
  $null = Invoke-RaymanOwnedWindowsJsonQuery -WorkspaceRootPath $WorkspaceRootPath -ScriptBody $body -Prefix 'owned_process_stop'
}

function Stop-RaymanWorkspaceOwnedProcess {
  param(
    [string]$WorkspaceRootPath,
    [object]$Record,
    [string]$Reason = 'manual'
  )

  if ($null -eq $Record) { return $null }
  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRootPath).Path
  $rootPid = 0
  try { $rootPid = [int]$Record.root_pid } catch { $rootPid = 0 }

  $aliveBefore = Test-RaymanOwnedProcessAlive -WorkspaceRootPath $resolvedRoot -Record $Record
  $treePids = @(Get-RaymanWindowsProcessTreePids -WorkspaceRootPath $resolvedRoot -RootPid $rootPid -IncludeRoot)
  if ($treePids.Count -eq 0 -and $aliveBefore -and $rootPid -gt 0) {
    $treePids = @($rootPid)
  }

  $taskKillOk = $false
  if ($rootPid -gt 0) {
    $taskKillOk = Invoke-RaymanTaskKillTree -RootPid $rootPid
    Start-Sleep -Milliseconds 300
  }

  $aliveAfterTaskKill = @()
  foreach ($pidValue in $treePids) {
    $details = Get-RaymanOwnedWindowsProcessDetails -WorkspaceRootPath $resolvedRoot -ProcessId ([int]$pidValue)
    if ([bool]$details.alive) {
      $aliveAfterTaskKill += [int]$pidValue
    }
  }

  if ($aliveAfterTaskKill.Count -gt 0) {
    Invoke-RaymanStopWindowsPids -WorkspaceRootPath $resolvedRoot -Pids $aliveAfterTaskKill
    Start-Sleep -Milliseconds 300
  }

  $aliveAfterCleanup = @()
  foreach ($pidValue in $treePids) {
    $details = Get-RaymanOwnedWindowsProcessDetails -WorkspaceRootPath $resolvedRoot -ProcessId ([int]$pidValue)
    if ([bool]$details.alive) {
      $aliveAfterCleanup += [int]$pidValue
    }
  }

  $success = ($aliveAfterCleanup.Count -eq 0)
  if ($success) {
    Remove-RaymanWorkspaceOwnedProcess -WorkspaceRootPath $resolvedRoot -RootPid $rootPid
  } else {
    Set-RaymanWorkspaceOwnedProcessState -WorkspaceRootPath $resolvedRoot -RootPid $rootPid -State 'cleanup_failed'
  }

  return [pscustomobject]@{
    workspace_root = $resolvedRoot
    owner_key = [string]$Record.owner_key
    owner_display = [string]$Record.owner_display
    kind = [string]$Record.kind
    launcher = [string]$Record.launcher
    root_pid = $rootPid
    cleanup_reason = [string]$Reason
    cleanup_result = $(if ($success) { 'cleaned' } else { 'cleanup_failed' })
    cleanup_pids = @($treePids | Select-Object -Unique | Sort-Object)
    taskkill_attempted = [bool]($rootPid -gt 0)
    taskkill_result = $(if ($rootPid -gt 0 -and $taskKillOk) { 'ok' } elseif ($rootPid -gt 0) { 'fallback' } else { 'not_applicable' })
    alive_pids = @($aliveAfterCleanup | Select-Object -Unique | Sort-Object)
    was_alive = [bool]$aliveBefore
  }
}

function Get-RaymanVsCodeWindowAuditPath {
  param(
    [string]$WorkspaceRootPath
  )

  return (Join-Path $WorkspaceRootPath '.Rayman\runtime\vscode_windows.last.json')
}

function Get-RaymanVsCodeSnapshotKey {
  param(
    [object]$ProcessInfo
  )

  if ($null -eq $ProcessInfo) { return '' }
  $pidValue = 0
  try { $pidValue = [int]$ProcessInfo.pid } catch { $pidValue = 0 }
  $startUtc = ''
  if ($ProcessInfo.PSObject.Properties['start_utc']) {
    $startUtc = [string]$ProcessInfo.start_utc
  }
  return ('{0}|{1}' -f $pidValue, $startUtc)
}

function Get-RaymanVsCodeWorkspaceTokens {
  param(
    [string]$WorkspaceRootPath
  )

  if ([string]::IsNullOrWhiteSpace($WorkspaceRootPath)) { return @() }

  $resolvedRoot = ''
  try {
    $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRootPath).Path
  } catch {
    $resolvedRoot = $WorkspaceRootPath
  }

  $tokens = New-Object System.Collections.Generic.List[string]
  foreach ($variant in @(Get-RaymanPathComparisonVariants -PathValue $resolvedRoot)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$variant)) {
      $tokens.Add(([string]$variant).ToLowerInvariant()) | Out-Null
      $tokens.Add((([string]$variant).Replace('/', '\')).ToLowerInvariant()) | Out-Null
      $tokens.Add((([string]$variant).Replace('\', '/')).ToLowerInvariant()) | Out-Null
    }
  }

  try {
    $uri = [System.Uri]$resolvedRoot
    if ($uri.IsAbsoluteUri) {
      $tokens.Add($uri.AbsoluteUri.ToLowerInvariant()) | Out-Null
    }
  } catch {}

  return @($tokens.ToArray() | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
}

function Resolve-RaymanVsCodeWorkspaceMatch {
  param(
    [object]$ProcessInfo,
    [string[]]$WorkspaceRoots = @()
  )

  $commandLine = ''
  if ($null -ne $ProcessInfo -and $ProcessInfo.PSObject.Properties['command_line']) {
    $commandLine = [string]$ProcessInfo.command_line
  }
  $commandLower = $commandLine.ToLowerInvariant()

  foreach ($workspaceRoot in @($WorkspaceRoots | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)) {
    $resolvedRoot = ''
    try {
      $resolvedRoot = (Resolve-Path -LiteralPath $workspaceRoot).Path
    } catch {
      $resolvedRoot = [string]$workspaceRoot
    }

    foreach ($token in @(Get-RaymanVsCodeWorkspaceTokens -WorkspaceRootPath $resolvedRoot)) {
      if ([string]::IsNullOrWhiteSpace([string]$token)) { continue }
      if ($commandLower.Contains(([string]$token).ToLowerInvariant())) {
        return [pscustomobject]@{
          matched = $true
          workspace_root = $resolvedRoot
          reason = 'command_line'
        }
      }
    }
  }

  return [pscustomobject]@{
    matched = $false
    workspace_root = ''
    reason = 'no_workspace_token_match'
  }
}

function Resolve-RaymanVsCodeClientProcessId {
  param(
    [object]$ProcessInfo
  )

  if ($null -eq $ProcessInfo) { return 0 }
  $commandLine = ''
  if ($ProcessInfo.PSObject.Properties['command_line']) {
    $commandLine = [string]$ProcessInfo.command_line
  }
  if ([string]::IsNullOrWhiteSpace($commandLine)) { return 0 }
  $match = [regex]::Match($commandLine, '(?:^|\s)--clientProcessId=(\d+)(?:\s|$)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if (-not $match.Success) { return 0 }
  return (Resolve-RaymanOwnedParsedPid -Value ([string]$match.Groups[1].Value))
}

function Read-RaymanVsCodeWindowAuditReport {
  param(
    [string]$WorkspaceRootPath
  )

  $auditPath = Get-RaymanVsCodeWindowAuditPath -WorkspaceRootPath $WorkspaceRootPath
  if (-not (Test-Path -LiteralPath $auditPath -PathType Leaf)) {
    return $null
  }

  try {
    $report = Get-Content -LiteralPath $auditPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if (-not (Test-RaymanReportWorkspaceMatchesRoot -Report $report -WorkspaceRoot $WorkspaceRootPath)) {
      return $null
    }
    return $report
  } catch {
    return $null
  }
}

function Get-RaymanTrackedWorkspaceAuditMatches {
  param(
    [string]$WorkspaceRootPath,
    [string[]]$WorkspaceRoots = @(),
    [object[]]$NewSnapshot = @()
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRootPath).Path
  $processByPid = @{}
  foreach ($processInfo in @($NewSnapshot)) {
    $pidValue = 0
    try { $pidValue = [int]$processInfo.pid } catch { $pidValue = 0 }
    if ($pidValue -le 0) { continue }
    $processByPid[$pidValue] = $processInfo
  }

  $matches = New-Object 'System.Collections.Generic.List[object]'
  foreach ($trackedRoot in @($WorkspaceRoots | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)) {
    if (Test-RaymanPathsEquivalent -LeftPath $trackedRoot -RightPath $resolvedRoot) {
      continue
    }

    $report = Read-RaymanVsCodeWindowAuditReport -WorkspaceRootPath $trackedRoot
    if ($null -eq $report) { continue }

    $candidateSet = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($pidValue in @($report.new_pids)) {
      $pidInt = Resolve-RaymanOwnedParsedPid -Value ([string]$pidValue)
      if ($pidInt -gt 0 -and $processByPid.ContainsKey($pidInt)) {
        [void]$candidateSet.Add($pidInt)
      }
    }
    if ($candidateSet.Count -eq 0) { continue }

    foreach ($candidatePid in @($candidateSet | ForEach-Object { [int]$_ } | Sort-Object -Unique)) {
      $processInfo = $processByPid[$candidatePid]
      $parentPid = 0
      if ($processInfo.PSObject.Properties['parent_pid']) {
        try { $parentPid = [int]$processInfo.parent_pid } catch { $parentPid = 0 }
      }
      $clientPid = Resolve-RaymanVsCodeClientProcessId -ProcessInfo $processInfo
      $registerRoot = (-not $candidateSet.Contains($parentPid)) -and (-not $candidateSet.Contains($clientPid))
      $matches.Add([pscustomobject]@{
          pid = $candidatePid
          matched = $true
          workspace_root = $trackedRoot
          reason = 'tracked_workspace_audit'
          register_root = $registerRoot
        }) | Out-Null
    }
  }

  return @($matches.ToArray())
}

function Get-RaymanVsCodeProcessSnapshot {
  param(
    [string]$WorkspaceRootPath
  )

  if (Test-RaymanWindowsPlatform) {
    $processMap = @{}
    foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'Code*' })) {
      if ($null -eq $proc) { continue }
      $processMap[[int]$proc.Id] = $proc
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($proc in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -like 'Code*' })) {
      if ($null -eq $proc) { continue }
      $pidValue = [int]$proc.ProcessId
      $live = $null
      if ($processMap.ContainsKey($pidValue)) {
        $live = $processMap[$pidValue]
      }
      $startUtc = ''
      $mainWindowTitle = ''
      $processName = [string]$proc.Name
      if ($null -ne $live) {
        try { $startUtc = $live.StartTime.ToUniversalTime().ToString('o') } catch {}
        try { $mainWindowTitle = [string]$live.MainWindowTitle } catch {}
        try { $processName = [string]$live.ProcessName } catch {}
      }
      $results.Add([pscustomobject]@{
          pid = $pidValue
          parent_pid = [int]$proc.ParentProcessId
          process_name = $processName
          start_utc = $startUtc
          command_line = [string]$proc.CommandLine
          main_window_title = $mainWindowTitle
        }) | Out-Null
    }
    return @($results.ToArray() | Sort-Object pid, start_utc)
  }

  $body = @'
$processMap = @{}
foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'Code*' })) {
  if ($null -eq $proc) { continue }
  $processMap[[int]$proc.Id] = $proc
}
$results = New-Object System.Collections.Generic.List[object]
foreach ($proc in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -like 'Code*' })) {
  if ($null -eq $proc) { continue }
  $pidValue = [int]$proc.ProcessId
  $live = $null
  if ($processMap.ContainsKey($pidValue)) {
    $live = $processMap[$pidValue]
  }
  $startUtc = ''
  $mainWindowTitle = ''
  $processName = [string]$proc.Name
  if ($null -ne $live) {
    try { $startUtc = $live.StartTime.ToUniversalTime().ToString('o') } catch {}
    try { $mainWindowTitle = [string]$live.MainWindowTitle } catch {}
    try { $processName = [string]$live.ProcessName } catch {}
  }
  $results.Add([pscustomobject]@{
      pid = $pidValue
      parent_pid = [int]$proc.ParentProcessId
      process_name = $processName
      start_utc = $startUtc
      command_line = [string]$proc.CommandLine
      main_window_title = $mainWindowTitle
    }) | Out-Null
}
Write-Result (@($results.ToArray() | Sort-Object pid, start_utc))
'@
  $result = Invoke-RaymanOwnedWindowsJsonQuery -WorkspaceRootPath $WorkspaceRootPath -ScriptBody $body -Prefix 'vscode_snapshot'
  if ($null -eq $result) {
    return @()
  }
  return @($result)
}

function Sync-RaymanWorkspaceVsCodeWindows {
  param(
    [string]$WorkspaceRootPath,
    [object[]]$BaselineSnapshot = @(),
    [string[]]$WorkspaceRoots = @(),
    [object]$OwnerContext = $null,
    [switch]$CleanupOwned,
    [string]$CleanupReason = 'vscode-window-cleanup',
    [string]$Source = 'setup'
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRootPath).Path
  if ($null -eq $OwnerContext) {
    $OwnerContext = Get-RaymanWorkspaceProcessOwnerContext -WorkspaceRootPath $resolvedRoot
  }

  $trackedRoots = New-Object System.Collections.Generic.List[string]
  foreach ($workspaceRoot in @($WorkspaceRoots)) {
    if ([string]::IsNullOrWhiteSpace([string]$workspaceRoot)) { continue }
    try {
      $trackedRoots.Add((Resolve-Path -LiteralPath $workspaceRoot).Path) | Out-Null
    } catch {
      $trackedRoots.Add([string]$workspaceRoot) | Out-Null
    }
  }
  if ($trackedRoots.Count -eq 0) {
    $trackedRoots.Add($resolvedRoot) | Out-Null
  }
  $uniqueTrackedRoots = @($trackedRoots.ToArray() | Select-Object -Unique)

  $currentSnapshot = @(Get-RaymanVsCodeProcessSnapshot -WorkspaceRootPath $resolvedRoot)
  $baselineKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in @($BaselineSnapshot)) {
    [void]$baselineKeys.Add((Get-RaymanVsCodeSnapshotKey -ProcessInfo $entry))
  }

  $newSnapshot = @($currentSnapshot | Where-Object {
    -not $baselineKeys.Contains((Get-RaymanVsCodeSnapshotKey -ProcessInfo $_))
  })

  $directMatchByPid = @{}
  foreach ($processInfo in $newSnapshot) {
    $pidValue = 0
    try { $pidValue = [int]$processInfo.pid } catch { $pidValue = 0 }
    if ($pidValue -le 0) { continue }
    $match = Resolve-RaymanVsCodeWorkspaceMatch -ProcessInfo $processInfo -WorkspaceRoots $uniqueTrackedRoots
    if ([bool]$match.matched) {
      $directMatchByPid[$pidValue] = $match
    }
  }

  $auditMatchByPid = @{}
  $auditMatches = @(Get-RaymanTrackedWorkspaceAuditMatches -WorkspaceRootPath $resolvedRoot -WorkspaceRoots $uniqueTrackedRoots -NewSnapshot @($newSnapshot | Where-Object {
        $pidValue = 0
        try { $pidValue = [int]$_.pid } catch { $pidValue = 0 }
        $pidValue -gt 0 -and -not $directMatchByPid.ContainsKey($pidValue)
      }))
  foreach ($auditMatch in $auditMatches) {
    if ($null -eq $auditMatch) { continue }
    $pidValue = 0
    try { $pidValue = [int]$auditMatch.pid } catch { $pidValue = 0 }
    if ($pidValue -le 0) { continue }
    $auditMatchByPid[$pidValue] = $auditMatch
  }

  $workspaceMatches = New-Object System.Collections.Generic.List[object]
  $registeredRecords = New-Object System.Collections.Generic.List[object]
  $ownedPids = New-Object System.Collections.Generic.List[int]

  foreach ($processInfo in $newSnapshot) {
    $pidValue = 0
    try { $pidValue = [int]$processInfo.pid } catch { $pidValue = 0 }
    $match = $null
    $registerRoot = $false
    if ($pidValue -gt 0 -and $directMatchByPid.ContainsKey($pidValue)) {
      $match = $directMatchByPid[$pidValue]
      $registerRoot = $true
    } elseif ($pidValue -gt 0 -and $auditMatchByPid.ContainsKey($pidValue)) {
      $match = $auditMatchByPid[$pidValue]
      $registerRoot = [bool]$match.register_root
    } else {
      $match = [pscustomobject]@{
        matched = $false
        workspace_root = ''
        reason = 'no_workspace_token_match'
      }
    }
    $workspaceMatches.Add([pscustomobject]@{
        pid = $pidValue
        matched = [bool]$match.matched
        workspace_root = [string]$match.workspace_root
        reason = [string]$match.reason
        process_name = [string]$processInfo.process_name
        start_utc = [string]$processInfo.start_utc
        main_window_title = [string]$processInfo.main_window_title
        command_line = [string]$processInfo.command_line
      }) | Out-Null

    if (-not [bool]$match.matched -or -not $registerRoot) { continue }

    $record = Register-RaymanWorkspaceOwnedProcess `
      -WorkspaceRootPath $resolvedRoot `
      -OwnerContext $OwnerContext `
      -Kind 'vscode' `
      -Launcher ('{0}-vscode-window' -f $Source) `
      -RootPid $pidValue `
      -Command ([string]$processInfo.command_line)
    if ($null -ne $record) {
      $registeredRecords.Add($record) | Out-Null
      $ownedPids.Add($pidValue) | Out-Null
    }
  }

  $cleanupResults = New-Object System.Collections.Generic.List[object]
  if ($CleanupOwned) {
    foreach ($record in @($registeredRecords.ToArray())) {
      $cleanup = Stop-RaymanWorkspaceOwnedProcess -WorkspaceRootPath $resolvedRoot -Record $record -Reason $CleanupReason
      if ($null -ne $cleanup) {
        $cleanupResults.Add($cleanup) | Out-Null
      }
    }
  }

  $cleanupPids = @($cleanupResults | ForEach-Object {
    if ($_.PSObject.Properties['cleanup_pids']) {
      @($_.cleanup_pids | ForEach-Object { [int]$_ })
    }
  } | Select-Object -Unique | Sort-Object)
  $ownerPid = 0
  if ($OwnerContext.PSObject.Properties['owner_source'] -and ([string]$OwnerContext.owner_source) -eq 'VSCODE_PID') {
    try { $ownerPid = [int]$OwnerContext.owner_token } catch { $ownerPid = 0 }
  }

  $cleanupResult = if (-not $CleanupOwned) {
    'not_requested'
  } elseif ($cleanupResults.Count -eq 0) {
    'not_needed'
  } elseif (@($cleanupResults | Where-Object { [string]$_.cleanup_result -ne 'cleaned' }).Count -gt 0) {
    'cleanup_failed'
  } else {
    'cleaned'
  }

  $report = [ordered]@{
    schema = 'rayman.vscode_windows.v1'
    updated_at = (Get-Date).ToString('o')
    source = $Source
    workspace_root = $resolvedRoot
    tracked_workspace_roots = @($uniqueTrackedRoots)
    owner_pid = $ownerPid
    owner_display = if ($OwnerContext.PSObject.Properties['owner_display']) { [string]$OwnerContext.owner_display } else { '' }
    baseline_pids = @(@($BaselineSnapshot | ForEach-Object { [int]$_.pid }) | Sort-Object -Unique)
    new_pids = @(@($newSnapshot | ForEach-Object { [int]$_.pid }) | Sort-Object -Unique)
    owned_pids = @($ownedPids.ToArray() | Sort-Object -Unique)
    workspace_match = @($workspaceMatches.ToArray())
    cleanup_requested = [bool]$CleanupOwned
    cleanup_result = $cleanupResult
    cleanup_pids = @($cleanupPids)
    baseline = @($BaselineSnapshot)
    current = @($currentSnapshot)
    new = @($newSnapshot)
  }

  $auditPath = Get-RaymanVsCodeWindowAuditPath -WorkspaceRootPath $resolvedRoot
  $auditDir = Split-Path -Parent $auditPath
  if (-not (Test-Path -LiteralPath $auditDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $auditDir | Out-Null
  }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($auditPath, ($report | ConvertTo-Json -Depth 10), $utf8NoBom)

  return [pscustomobject]$report
}

function Stop-RaymanWorkspaceOwnedProcessesForCurrentOwner {
  param(
    [string]$WorkspaceRootPath,
    [object]$OwnerContext = $null,
    [string[]]$Kinds = @(),
    [string]$Reason = 'manual'
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRootPath).Path
  if ($null -eq $OwnerContext) {
    $OwnerContext = Get-RaymanWorkspaceProcessOwnerContext -WorkspaceRootPath $resolvedRoot
  }

  $records = @(Get-RaymanWorkspaceOwnedProcessRecords -WorkspaceRootPath $resolvedRoot)
  if ($records.Count -eq 0) { return @() }

  $kindSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($kind in @($Kinds)) {
    if (-not [string]::IsNullOrWhiteSpace($kind)) {
      [void]$kindSet.Add($kind.Trim())
    }
  }

  $matches = @($records | Where-Object {
    $ownerKey = if ($_.PSObject.Properties['owner_key']) { [string]$_.owner_key } else { '' }
    $kindValue = if ($_.PSObject.Properties['kind']) { [string]$_.kind } else { '' }
    if ($ownerKey -ne [string]$OwnerContext.owner_key) { return $false }
    if ($kindSet.Count -eq 0) { return $true }
    return $kindSet.Contains($kindValue)
  })

  $results = New-Object System.Collections.Generic.List[object]
  foreach ($record in $matches) {
    $result = Stop-RaymanWorkspaceOwnedProcess -WorkspaceRootPath $resolvedRoot -Record $record -Reason $Reason
    if ($null -ne $result) {
      $results.Add($result) | Out-Null
    }
  }

  return @($results.ToArray())
}

if (-not $NoMain) {
  return
}
