Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RaymanHostSmokeCommandPath {
  param([string[]]$Names)

  foreach ($name in @($Names)) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
      return [string]$cmd.Source
    }
  }

  return $null
}

function Resolve-RaymanHostSmokeBashRunner {
  $override = [string][Environment]::GetEnvironmentVariable('RAYMAN_BASH_PATH')
  if (-not [string]::IsNullOrWhiteSpace($override) -and (Test-Path -LiteralPath $override -PathType Leaf)) {
    return [pscustomobject]@{
      path = (Resolve-Path -LiteralPath $override).Path
      mode = 'bash'
      invoke_kind = 'bash'
    }
  }

  $bashPath = Resolve-RaymanHostSmokeCommandPath -Names @('bash', 'bash.exe')
  if (-not [string]::IsNullOrWhiteSpace($bashPath)) {
    $bashMode = 'bash'
    $bashNorm = ($bashPath -replace '/', '\').ToLowerInvariant()
    if (Test-RaymanWindowsPlatform -and $bashNorm.EndsWith('\windows\system32\bash.exe')) {
      $bashMode = 'wsl'
    }
    return [pscustomobject]@{
      path = $bashPath
      mode = $bashMode
      invoke_kind = 'bash'
    }
  }

  if (Test-RaymanWindowsPlatform) {
    $wslPath = Resolve-RaymanHostSmokeCommandPath -Names @('wsl.exe', 'wsl')
    if (-not [string]::IsNullOrWhiteSpace($wslPath)) {
      return [pscustomobject]@{
        path = $wslPath
        mode = 'wsl'
        invoke_kind = 'wsl'
      }
    }
  }

  return $null
}

function Convert-RaymanHostSmokePathToBashCompat {
  param(
    [string]$PathValue,
    [ValidateSet('bash', 'wsl')][string]$Mode = 'wsl'
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }

  $fullPath = [string]$PathValue
  if (Test-RaymanWindowsPlatform) {
    try {
      $fullPath = [System.IO.Path]::GetFullPath($PathValue)
    } catch {}
  }

  if ($Mode -eq 'wsl' -and $fullPath -match '^([A-Za-z]):\\(.*)$') {
    $drive = [string]$Matches[1].ToLowerInvariant()
    $rest = [string]$Matches[2]
    if ([string]::IsNullOrWhiteSpace($rest)) {
      return ("/mnt/{0}" -f $drive)
    }
    return ("/mnt/{0}/{1}" -f $drive, ($rest -replace '\\', '/'))
  }

  return ($fullPath -replace '\\', '/')
}

function Convert-RaymanHostSmokeToBashSingleQuotedLiteral([string]$Value) {
  if ($null -eq $Value) { return "''" }
  return ("'" + ([string]$Value).Replace("'", "'""'""'") + "'")
}

function New-RaymanHostSmokeBashInvocation {
  param(
    [string]$WorkspaceRoot,
    [string]$CommandText
  )

  if ([string]::IsNullOrWhiteSpace($WorkspaceRoot) -or [string]::IsNullOrWhiteSpace($CommandText)) {
    return $null
  }

  $runner = Resolve-RaymanHostSmokeBashRunner
  if ($null -eq $runner -or [string]::IsNullOrWhiteSpace([string]$runner.path)) {
    return $null
  }

  $runnerMode = [string]$runner.mode
  $invokeKind = [string]$runner.invoke_kind
  $workspaceBash = Convert-RaymanHostSmokePathToBashCompat -PathValue $WorkspaceRoot -Mode $runnerMode
  $bashCommand = "cd $(Convert-RaymanHostSmokeToBashSingleQuotedLiteral -Value $workspaceBash) && $CommandText"
  if ($invokeKind -eq 'wsl') {
    $argumentList = @('-e', 'bash', '-lc', $bashCommand)
    $displayCommand = ("wsl.exe -e bash -lc {0}" -f (Convert-RaymanHostSmokeToBashSingleQuotedLiteral -Value $bashCommand))
  } else {
    $argumentList = @('-lc', $bashCommand)
    $displayCommand = ("bash -lc {0}" -f (Convert-RaymanHostSmokeToBashSingleQuotedLiteral -Value $bashCommand))
  }

  return [pscustomobject]@{
    path = [string]$runner.path
    mode = $runnerMode
    argument_list = @($argumentList)
    command = $displayCommand
  }
}

function Get-RaymanHostSmokeMergedOutput {
  param([object]$Capture)

  $sections = New-Object System.Collections.Generic.List[string]
  if ($null -ne $Capture) {
    if (@($Capture.stdout).Count -gt 0) {
      $sections.Add((@($Capture.stdout) -join [Environment]::NewLine)) | Out-Null
    }
    if (@($Capture.stderr).Count -gt 0) {
      if ($sections.Count -gt 0) {
        $sections.Add('') | Out-Null
      }
      $sections.Add((@($Capture.stderr) -join [Environment]::NewLine)) | Out-Null
    }
    if ($sections.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$Capture.error)) {
      $sections.Add([string]$Capture.error) | Out-Null
    }
  }

  return ($sections -join [Environment]::NewLine)
}

function Invoke-RaymanHostSmokeStep {
  param(
    [string]$Name,
    [string]$LogDir,
    [string]$FilePath,
    [string[]]$ArgumentList = @(),
    [string]$WorkingDirectory = ''
  )

  $logPath = Join-Path $LogDir ("{0}.log" -f $Name)
  if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
  }
  $capture = Invoke-RaymanNativeCommandCapture -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory
  $outputText = Get-RaymanHostSmokeMergedOutput -Capture $capture
  Set-Content -LiteralPath $logPath -Value $outputText -Encoding UTF8

  return [pscustomobject]@{
    log_path = $logPath
    output = $outputText
    stdout = @($capture.stdout)
    stderr = @($capture.stderr)
    exit_code = if ([bool]$capture.started) { [int]$capture.exit_code } else { -1 }
    started = [bool]$capture.started
    launch_error = [string]$capture.error
    command = [string]$capture.command
  }
}

function Resolve-RaymanHostSmokePythonCommand {
  param(
    [string]$WorkingDirectory = '',
    [string[]]$Candidates = @('python3', 'python')
  )

  $attempts = New-Object System.Collections.Generic.List[object]
  foreach ($candidate in @($Candidates)) {
    $commandPath = Resolve-RaymanHostSmokeCommandPath -Names @([string]$candidate)
    if ([string]::IsNullOrWhiteSpace($commandPath)) {
      $attempts.Add([pscustomobject]@{
          name = [string]$candidate
          path = ''
          status = 'missing'
          exit_code = -1
          detail = 'command not found'
          output = ''
        }) | Out-Null
      continue
    }

    $capture = Invoke-RaymanNativeCommandCapture -FilePath $commandPath -ArgumentList @('--version') -WorkingDirectory $WorkingDirectory
    $outputText = Get-RaymanHostSmokeMergedOutput -Capture $capture
    $status = if ([bool]$capture.started -and [int]$capture.exit_code -eq 0) {
      'ok'
    } elseif ([bool]$capture.started) {
      'failed'
    } else {
      'launch_error'
    }
    $detail = if ([bool]$capture.started) {
      ("exit={0}" -f [int]$capture.exit_code)
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$capture.error)) {
      [string]$capture.error
    } else {
      'failed to start'
    }

    $attempt = [pscustomobject]@{
      name = [string]$candidate
      path = [string]$commandPath
      status = $status
      exit_code = if ([bool]$capture.started) { [int]$capture.exit_code } else { -1 }
      detail = $detail
      output = $outputText
    }
    $attempts.Add($attempt) | Out-Null

    if ($status -eq 'ok') {
      return [pscustomobject]@{
        name = [string]$candidate
        path = [string]$commandPath
        output = $outputText
        attempts = @($attempts.ToArray())
      }
    }
  }

  return [pscustomobject]@{
    name = ''
    path = ''
    output = ''
    attempts = @($attempts.ToArray())
  }
}
