param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$Strict,
  [switch]$KeepTemp,
  [switch]$OpenOnFail,
  [int]$TimeoutSeconds = 120,
  [ValidateSet('all','wsl','sandbox','host')][string]$Scope = 'wsl'
)

$ErrorActionPreference = 'Stop'

function Info([string]$m){ Write-Host ("ℹ️  [copy-smoke] {0}" -f $m) -ForegroundColor Cyan }
function Ok([string]$m){ Write-Host ("✅ [copy-smoke] {0}" -f $m) -ForegroundColor Green }
function Warn([string]$m){ Write-Host ("⚠️  [copy-smoke] {0}" -f $m) -ForegroundColor Yellow }
function Fail([string]$m){ Write-Host ("❌ [copy-smoke] {0}" -f $m) -ForegroundColor Red; exit 2 }

function Reset-LastExitCodeCompat {
  try { Set-Variable -Name 'LASTEXITCODE' -Scope Global -Value 0 -Force } catch {}
  try { Set-Variable -Name 'LASTEXITCODE' -Scope Script -Value 0 -Force } catch {}
}

function Get-LastExitCodeCompat([int]$Default = 0) {
  try {
    $g = Get-Variable -Name 'LASTEXITCODE' -Scope Global -ErrorAction Stop
    if ($null -ne $g.Value) { return [int]$g.Value }
  } catch {}

  try {
    $s = Get-Variable -Name 'LASTEXITCODE' -Scope Script -ErrorAction Stop
    if ($null -ne $s.Value) { return [int]$s.Value }
  } catch {}

  return $Default
}

function Set-EnvOverride {
  param(
    [hashtable]$Backup,
    [string]$Name,
    [string]$Value
  )

  if (-not $Backup.ContainsKey($Name)) {
    $Backup[$Name] = [string][System.Environment]::GetEnvironmentVariable($Name)
  }
  [System.Environment]::SetEnvironmentVariable($Name, $Value)
}

function Restore-EnvOverrides([hashtable]$Backup) {
  foreach ($name in $Backup.Keys) {
    [System.Environment]::SetEnvironmentVariable($name, [string]$Backup[$name])
  }
}

function Test-CopySmokeHostIsWindows {
  try {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
  } catch {
    return $false
  }
}

function Convert-PathToWindowsViaWslpath([string]$Path) {
  $wslPathCmd = Get-Command 'wslpath' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $wslPathCmd) { return $Path }
  try {
    $raw = (& $wslPathCmd.Source -w $Path | Select-Object -First 1)
    if (-not [string]::IsNullOrWhiteSpace([string]$raw)) {
      return [string]$raw.Trim()
    }
  } catch {}
  return $Path
}

function Escape-PsSingleQuoted([string]$Value) {
  if ($null -eq $Value) { return '' }
  return $Value.Replace("'", "''")
}

function Reset-PortableRuntimeAndLogs([string]$RaymanRoot) {
  foreach ($rel in @('runtime','logs')) {
    $p = Join-Path $RaymanRoot $rel
    if (Test-Path -LiteralPath $p -PathType Container) {
      Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
    } elseif (Test-Path -LiteralPath $p) {
      Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }

  # Avoid stale MCP pid carry-over when copying from a used workspace.
  $mcpPid = Join-Path $RaymanRoot 'mcp\mcp_pids.json'
  if (Test-Path -LiteralPath $mcpPid -PathType Leaf) {
    Remove-Item -LiteralPath $mcpPid -Force -ErrorAction SilentlyContinue
  }
}

function Copy-RaymanTemplateForSmoke {
  param(
    [string]$SourceRayman,
    [string]$TargetRayman
  )

  if (-not (Test-Path -LiteralPath $SourceRayman -PathType Container)) {
    throw ("source .Rayman not found: {0}" -f $SourceRayman)
  }

  if (-not (Test-Path -LiteralPath $TargetRayman -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $TargetRayman | Out-Null
  }

  $excluded = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  [void]$excluded.Add('runtime')
  [void]$excluded.Add('logs')
  [void]$excluded.Add('.Rayman')

  $entries = @(Get-ChildItem -LiteralPath $SourceRayman -Force -ErrorAction Stop)
  foreach ($entry in $entries) {
    if ($excluded.Contains([string]$entry.Name)) { continue }
    Copy-Item -LiteralPath $entry.FullName -Destination $TargetRayman -Recurse -Force
  }
}

function Ensure-CopySmokeGitRepo([string]$Root) {
  if (Test-Path -LiteralPath (Join-Path $Root '.git') -PathType Container) {
    return
  }

  $git = Get-Command 'git' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $git -or [string]::IsNullOrWhiteSpace([string]$git.Source)) {
    Warn 'strict 模式未找到 git，无法为临时目录初始化仓库，后续 Release Gate 可能失败。'
    return
  }

  try {
    Push-Location $Root
    & $git.Source init | Out-Null
    & $git.Source config user.name 'rayman-copy-smoke' | Out-Null
    & $git.Source config user.email 'rayman-copy-smoke@local' | Out-Null
    Ok 'strict 模式已为临时目录初始化 git 仓库（用于 Release Gate 验收）'
  } catch {
    Warn ("strict 模式初始化临时 git 仓库失败: {0}" -f $_.Exception.Message)
  } finally {
    Pop-Location
  }
}

function Show-CopySmokeOpenHints([string]$TempRoot) {
  if ([string]::IsNullOrWhiteSpace($TempRoot)) { return }
  $quoted = '"' + $TempRoot.Replace('"','\"') + '"'
  Info ("open hint (PowerShell): ii {0}" -f $quoted)
  if (Test-CopySmokeHostIsWindows) {
    Info ("open hint (Explorer): explorer.exe {0}" -f $quoted)
  }
}

function Build-CopySmokeDebugSummary {
  param(
    [string]$TempRoot,
    [string]$SetupLog,
    [string]$PlaywrightSummary,
    [string]$SetupException,
    [string]$SetupExceptionLocation,
    [string]$SetupExceptionStackTop,
    [int]$ExitCode,
    [string]$Scope,
    [bool]$StrictMode
  )

  $releaseGateReport = Join-Path $TempRoot '.Rayman\state\release_gate_report.md'
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('[Rayman copy-smoke debug bundle]') | Out-Null
  $lines.Add(("strict={0}" -f ([string]$StrictMode).ToLowerInvariant())) | Out-Null
  $lines.Add(("scope={0}" -f $Scope)) | Out-Null
  $lines.Add(("exit_code={0}" -f $ExitCode)) | Out-Null
  $lines.Add(("temp_workspace={0}" -f $TempRoot)) | Out-Null
  if (-not [string]::IsNullOrWhiteSpace($SetupLog)) {
    $lines.Add(("setup_log={0}" -f $SetupLog)) | Out-Null
  }
  if (Test-Path -LiteralPath $releaseGateReport -PathType Leaf) {
    $lines.Add(("release_gate_report={0}" -f $releaseGateReport)) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($PlaywrightSummary) -and (Test-Path -LiteralPath $PlaywrightSummary -PathType Leaf)) {
    $lines.Add(("playwright_summary={0}" -f $PlaywrightSummary)) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($SetupException)) {
    $lines.Add(("exception={0}" -f $SetupException)) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($SetupExceptionLocation)) {
    $lines.Add(("exception_location={0}" -f $SetupExceptionLocation)) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($SetupExceptionStackTop)) {
    $lines.Add(("exception_stack_top={0}" -f $SetupExceptionStackTop)) | Out-Null
  }

  return ($lines -join [Environment]::NewLine)
}

function Try-CopyCopySmokeDebugToClipboard([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  if (-not (Test-CopySmokeHostIsWindows)) { return $false }
  try {
    if (Get-Command 'Set-Clipboard' -ErrorAction SilentlyContinue) {
      Set-Clipboard -Value $Text
      return $true
    }
  } catch {}

  try {
    $clipExe = Get-Command 'clip.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $clipExe -and -not [string]::IsNullOrWhiteSpace([string]$clipExe.Source)) {
      $Text | & $clipExe.Source
      return $true
    }
  } catch {}

  return $false
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$sourceRayman = Join-Path $WorkspaceRoot '.Rayman'
if (-not (Test-Path -LiteralPath $sourceRayman -PathType Container)) {
  Fail ".Rayman not found: $sourceRayman"
}

$tag = Get-Date -Format 'yyyyMMdd_HHmmss'
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("rayman_copy_smoke_{0}_{1}" -f $tag, ([Guid]::NewGuid().ToString('N').Substring(0,8)))
$tmpRayman = Join-Path $tmpRoot '.Rayman'
$setupScript = Join-Path $tmpRayman 'setup.ps1'
$playwrightSummaryPath = Join-Path $tmpRayman 'runtime\playwright.ready.windows.json'

$envBackup = @{}
$setupExitCode = 0
$setupException = ''
$setupExceptionLocation = ''
$setupExceptionStackTop = ''

try {
  New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
  Copy-RaymanTemplateForSmoke -SourceRayman $sourceRayman -TargetRayman $tmpRayman
  Reset-PortableRuntimeAndLogs -RaymanRoot $tmpRayman
  if ($Strict) {
    Ensure-CopySmokeGitRepo -Root $tmpRoot
  }
  Info ("copy smoke workspace: {0}" -f $tmpRoot)
  Info ("copy smoke options: strict={0} scope={1} timeout_seconds={2}" -f ([string]$Strict.IsPresent).ToLowerInvariant(), $Scope, $TimeoutSeconds)
  Info "copied .Rayman (excluded runtime/logs history) and sanitized runtime/logs"

  if (-not (Test-Path -LiteralPath $setupScript -PathType Leaf)) {
    throw ("setup script missing in copied folder: {0}" -f $setupScript)
  }

  Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_PLAYWRIGHT_SETUP_SCOPE' -Value $Scope
  Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_PLAYWRIGHT_TIMEOUT_SECONDS' -Value ([string]$TimeoutSeconds)
  Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_MCP_SQLITE_DB_AUTOFIX' -Value '1'
  Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_SETUP_SKIP_POST_CHECK' -Value '1'
  Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_RAG_ROOT' -Value '.rag'
  Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_RAG_NAMESPACE' -Value (Split-Path -Leaf $tmpRoot)
  Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_ALLOW_EXTERNAL_RAG_ROOT' -Value '0'
  Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_PRESERVE_RAG_NAMESPACE' -Value '0'
  if (-not $Strict) {
    Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_PLAYWRIGHT_REQUIRE' -Value '0'
  }

  Reset-LastExitCodeCompat
  $hostIsWindows = Test-CopySmokeHostIsWindows
  $powershellExe = Get-Command 'powershell.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  $preferWindowsSetup = (-not $hostIsWindows) -and ($null -ne $powershellExe)

  if ($preferWindowsSetup) {
    $setupScriptWin = Convert-PathToWindowsViaWslpath -Path $setupScript
    $tmpRootWin = Convert-PathToWindowsViaWslpath -Path $tmpRoot
    $setupScriptEscaped = Escape-PsSingleQuoted -Value $setupScriptWin
    $tmpRootEscaped = Escape-PsSingleQuoted -Value $tmpRootWin
    $timeoutEscaped = Escape-PsSingleQuoted -Value ([string]$TimeoutSeconds)
    $scopeEscaped = Escape-PsSingleQuoted -Value $Scope
    if ($Strict) {
      $cmd = @(
        "`$env:RAYMAN_PLAYWRIGHT_SETUP_SCOPE='$scopeEscaped'"
        "`$env:RAYMAN_PLAYWRIGHT_TIMEOUT_SECONDS='$timeoutEscaped'"
        "`$env:RAYMAN_MCP_SQLITE_DB_AUTOFIX='1'"
        "`$env:RAYMAN_SETUP_SKIP_POST_CHECK='1'"
        "& '$setupScriptEscaped' -WorkspaceRoot '$tmpRootEscaped'"
      ) -join '; '
      & $powershellExe.Source -NoProfile -ExecutionPolicy Bypass -Command $cmd
    } else {
      $cmd = @(
        "`$env:RAYMAN_PLAYWRIGHT_REQUIRE='0'"
        "`$env:RAYMAN_PLAYWRIGHT_SETUP_SCOPE='$scopeEscaped'"
        "`$env:RAYMAN_PLAYWRIGHT_TIMEOUT_SECONDS='$timeoutEscaped'"
        "`$env:RAYMAN_MCP_SQLITE_DB_AUTOFIX='1'"
        "`$env:RAYMAN_SETUP_SKIP_POST_CHECK='1'"
        "& '$setupScriptEscaped' -WorkspaceRoot '$tmpRootEscaped' -SkipReleaseGate -NoAutoMigrateLegacyRag"
      ) -join '; '
      & $powershellExe.Source -NoProfile -ExecutionPolicy Bypass -Command $cmd
    }
  } elseif ($Strict) {
    & $setupScript -WorkspaceRoot $tmpRoot
  } else {
    & $setupScript -WorkspaceRoot $tmpRoot -SkipReleaseGate -NoAutoMigrateLegacyRag
  }
  $setupExitCode = Get-LastExitCodeCompat -Default 0
} catch {
  $setupException = $_.Exception.Message
  try {
    if ($null -ne $_.InvocationInfo -and -not [string]::IsNullOrWhiteSpace([string]$_.InvocationInfo.ScriptName)) {
      $lineInfo = ''
      if ($_.InvocationInfo.ScriptLineNumber -gt 0) {
        $lineInfo = (":{0}" -f $_.InvocationInfo.ScriptLineNumber)
      }
      $setupExceptionLocation = ("{0}{1}" -f $_.InvocationInfo.ScriptName, $lineInfo)
    }
  } catch {}
  try {
    $stackRaw = [string]$_.ScriptStackTrace
    if (-not [string]::IsNullOrWhiteSpace($stackRaw)) {
      $top = ($stackRaw -split "(\r\n|\n|\r)")[0]
      if (-not [string]::IsNullOrWhiteSpace([string]$top)) {
        $setupExceptionStackTop = [string]$top.Trim()
      }
    }
  } catch {}
  $setupExitCode = Get-LastExitCodeCompat -Default 1
  if ($setupExitCode -eq 0) { $setupExitCode = 1 }
} finally {
  Restore-EnvOverrides -Backup $envBackup
}

$setupLog = ''
$logsDir = Join-Path $tmpRayman 'logs'
if (Test-Path -LiteralPath $logsDir -PathType Container) {
  try {
    $latestLog = Get-ChildItem -LiteralPath $logsDir -Filter 'setup.win.*.log' -File -ErrorAction Stop |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if ($null -ne $latestLog) { $setupLog = $latestLog.FullName }
  } catch {}
}

if ($setupExitCode -eq 0) {
  Ok ("copy smoke passed (strict={0}, scope={1})" -f ([string]$Strict.IsPresent).ToLowerInvariant(), $Scope)
  if (-not [string]::IsNullOrWhiteSpace($setupLog)) {
    Info ("setup log: {0}" -f $setupLog)
  }

  if ($KeepTemp) {
    Info ("kept temp workspace: {0}" -f $tmpRoot)
    Show-CopySmokeOpenHints -TempRoot $tmpRoot
  } else {
    try {
      Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
      Info "temp workspace cleaned"
    } catch {
      Warn ("failed to clean temp workspace: {0}" -f $_.Exception.Message)
      Info ("temp workspace: {0}" -f $tmpRoot)
    }
  }
  exit 0
}

Warn ("copy smoke failed (exit={0}, scope={1})" -f $setupExitCode, $Scope)
if (-not [string]::IsNullOrWhiteSpace($setupException)) {
  Warn ("exception: {0}" -f $setupException)
}
if (-not [string]::IsNullOrWhiteSpace($setupExceptionLocation)) {
  Warn ("exception location: {0}" -f $setupExceptionLocation)
}
if (-not [string]::IsNullOrWhiteSpace($setupExceptionStackTop)) {
  Warn ("exception stack (top): {0}" -f $setupExceptionStackTop)
}
if (-not [string]::IsNullOrWhiteSpace($setupLog)) {
  Warn ("setup log: {0}" -f $setupLog)
}
if (Test-Path -LiteralPath $playwrightSummaryPath -PathType Leaf) {
  Warn ("playwright summary: {0}" -f $playwrightSummaryPath)
}
Warn ("temp workspace kept for inspection: {0}" -f $tmpRoot)
Show-CopySmokeOpenHints -TempRoot $tmpRoot
$debugBundle = Build-CopySmokeDebugSummary -TempRoot $tmpRoot -SetupLog $setupLog -PlaywrightSummary $playwrightSummaryPath -SetupException $setupException -SetupExceptionLocation $setupExceptionLocation -SetupExceptionStackTop $setupExceptionStackTop -ExitCode $setupExitCode -Scope $Scope -StrictMode $Strict.IsPresent
if (Try-CopyCopySmokeDebugToClipboard -Text $debugBundle) {
  Ok '已将关键排障路径复制到剪贴板（可直接粘贴给同事/AI）'
} else {
  Warn '未能写入剪贴板，请手动复制上面的路径信息。'
}
if ($OpenOnFail -and (Test-CopySmokeHostIsWindows)) {
  try {
    Start-Process -FilePath 'explorer.exe' -ArgumentList @($tmpRoot) | Out-Null
    Info 'opened temp workspace in Explorer (OpenOnFail=1)'
  } catch {
    Warn ("failed to open Explorer automatically: {0}" -f $_.Exception.Message)
  }
}
exit $setupExitCode
