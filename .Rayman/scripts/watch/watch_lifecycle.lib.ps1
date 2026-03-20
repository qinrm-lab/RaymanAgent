Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Normalize-RaymanWatchPathForMatch {
  param([string]$PathValue)

  if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
  try {
    $full = [System.IO.Path]::GetFullPath($PathValue)
    return ($full -replace '/', '\').ToLowerInvariant()
  } catch {
    return ($PathValue -replace '/', '\').ToLowerInvariant()
  }
}

function Resolve-RaymanWatchPid {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) { return 0 }
  $parsed = 0
  if ([int]::TryParse($Value.Trim(), [ref]$parsed) -and $parsed -gt 0) {
    return $parsed
  }
  return 0
}

function Get-RaymanProcessStartUtcString {
  param([int]$ProcessId)

  if ($ProcessId -le 0) { return '' }
  try {
    $proc = Get-Process -Id $ProcessId -ErrorAction Stop
    return $proc.StartTime.ToUniversalTime().ToString('o')
  } catch {
    return ''
  }
}

function Test-RaymanTrackedProcessAlive {
  param(
    [int]$ProcessId,
    [string]$ExpectedStartUtc = ''
  )

  if ($ProcessId -le 0) { return $false }

  try {
    $proc = Get-Process -Id $ProcessId -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace($ExpectedStartUtc)) {
      $actualStartUtc = $proc.StartTime.ToUniversalTime().ToString('o')
      if ($actualStartUtc -ne $ExpectedStartUtc) {
        return $false
      }
    }
    return $true
  } catch {
    return $false
  }
}

function Get-RaymanVsCodeSessionEntries {
  param([string]$SessionDirectory)

  if ([string]::IsNullOrWhiteSpace($SessionDirectory) -or -not (Test-Path -LiteralPath $SessionDirectory -PathType Container)) {
    return @()
  }

  $entries = New-Object System.Collections.Generic.List[object]
  foreach ($sessionFile in @(Get-ChildItem -LiteralPath $SessionDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    $raw = ''
    $session = $null
    $parseError = ''

    try {
      $raw = Get-Content -LiteralPath $sessionFile.FullName -Raw -Encoding UTF8
      if ([string]::IsNullOrWhiteSpace($raw)) {
        $parseError = 'empty'
      } else {
        $session = $raw | ConvertFrom-Json -ErrorAction Stop
      }
    } catch {
      $parseError = $_.Exception.Message
    }

    if ($null -eq $session) {
      $entries.Add([pscustomobject]@{
          path = [string]$sessionFile.FullName
          parent_pid = 0
          parent_start_utc = ''
          state = 'invalid'
          alive = $false
          active = $false
          valid = $false
          parse_error = $parseError
        }) | Out-Null
      continue
    }

    $parentPid = Resolve-RaymanWatchPid -Value ([string]$session.parentPid)
    $parentStartUtc = [string]$session.parentStartUtc
    $state = ([string]$session.state).Trim().ToLowerInvariant()
    $alive = Test-RaymanTrackedProcessAlive -ProcessId $parentPid -ExpectedStartUtc $parentStartUtc
    $active = ($alive -and $state -ne 'parent-exited' -and $state -ne 'stop-failed')

    $entries.Add([pscustomobject]@{
        path = [string]$sessionFile.FullName
        parent_pid = $parentPid
        parent_start_utc = $parentStartUtc
        state = $state
        alive = $alive
        active = $active
        valid = $true
        parse_error = ''
      }) | Out-Null
  }

  return @($entries.ToArray())
}

function Get-RaymanOtherActiveVsCodeSessions {
  param(
    [string]$SessionDirectory,
    [int]$CurrentOwnerPid
  )

  return @(
    Get-RaymanVsCodeSessionEntries -SessionDirectory $SessionDirectory | Where-Object {
      [bool]$_.active -and ([int]$_.parent_pid -ne $CurrentOwnerPid)
    }
  )
}

function Get-RaymanWatchCleanupReason {
  param(
    [switch]$OwnerExit,
    [switch]$Shared
  )

  if ($OwnerExit -and $Shared) { return 'watch-stop-owner-exit-shared' }
  if ($OwnerExit) { return 'watch-stop-owner-exit' }
  if ($Shared) { return 'watch-stop-shared' }
  return 'watch-stop'
}

function Resolve-RaymanVsCodeOwnerPid {
  param(
    [string]$ExplicitPid,
    [int]$CurrentProcessId = $PID,
    [bool]$WindowsHost = (Test-RaymanWindowsPlatform)
  )

  $pidFromArg = Resolve-RaymanWatchPid -Value $ExplicitPid
  if ($pidFromArg -gt 0) { return $pidFromArg }

  $pidFromEnv = Resolve-RaymanWatchPid -Value ([string][System.Environment]::GetEnvironmentVariable('VSCODE_PID'))
  if ($pidFromEnv -gt 0) { return $pidFromEnv }

  if (-not $WindowsHost) { return 0 }

  $visited = New-Object 'System.Collections.Generic.HashSet[int]'
  $currentPid = [int]$CurrentProcessId
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
