param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [string]$ReportPath = "",
  [ValidateSet('standard','project')][string]$Mode = 'standard',
  [switch]$SkipAutoDistSync,
  [switch]$AllowNoGit,
  [switch]$Json,
  [switch]$IncludeResidualDiagnostics
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# note: keep this script fully PowerShell 5.1 compatible
$releaseGateStartedAt = Get-Date

function Info([string]$m){ Write-Host ("ℹ️  [release-gate] {0}" -f $m) -ForegroundColor Cyan }
function Ok([string]$m){ Write-Host ("✅ [release-gate] {0}" -f $m) -ForegroundColor Green }
function Warn([string]$m){ Write-Host ("⚠️  [release-gate] {0}" -f $m) -ForegroundColor Yellow }
function FailMsg([string]$m){ Write-Host ("❌ [release-gate] {0}" -f $m) -ForegroundColor Red }

function Add-Result {
  param(
    [System.Collections.Generic.List[object]]$Results,
    [string]$Name,
    [ValidateSet('PASS','WARN','FAIL')][string]$Status,
    [string]$Detail,
    [string]$Action = ''
  )
  $Results.Add([pscustomobject]@{
    Name = $Name
    Status = $Status
    Detail = $Detail
    Action = $Action
  }) | Out-Null
}

function Get-QuickFixCommandsForCheck([string]$CheckName) {
  switch ($CheckName) {
    'Git工作区检测' { return @('git init') }
    'Rayman资产Git跟踪噪声' { return @('git rm -r --cached -- .Rayman .SolutionName .cursorrules .clinerules .rayman.env.ps1 .github/copilot-instructions.md') }
    '非Rayman产物Git跟踪噪声' { return @('git rm -r --cached -- .dotnet10 dist publish .tmp .temp') }
    'Dist镜像同步' { return @('.\\.Rayman\\rayman.ps1 dist-sync') }
    '版本一致性' { return @('.\\.Rayman\\rayman.ps1 release-gate -Mode project') }
    'Agent Memory 存储有效' { return @('.\\.Rayman\\rayman.ps1 memory-bootstrap') }
    'MCP配置可移植性' { return @('.\\.Rayman\\scripts\\mcp\\manage_mcp.ps1 -Action status') }
    'Playwright摘要结构' { return @('.\\.Rayman\\rayman.ps1 ensure-playwright') }
    'Agent能力同步' { return @('.\\.Rayman\\rayman.ps1 agent-capabilities --sync') }
    'Windows桌面自动化能力' { return @('.\\.Rayman\\rayman.ps1 ensure-winapp') }
    '快速契约Lane' { return @('bash ./.Rayman/scripts/testing/run_fast_contract.sh') }
    '项目快速门禁' { return @('.\\.Rayman\\rayman.ps1 fast-gate') }
    '项目浏览器门禁' { return @('.\\.Rayman\\rayman.ps1 browser-gate') }
    'PowerShell逻辑单测' { return @('.\\.Rayman\\scripts\\testing\\run_pester_tests.ps1 -WorkspaceRoot "$PWD"') }
    'Bash逻辑单测' { return @('bash ./.Rayman/scripts/testing/run_bats_tests.sh') }
    '宿主环境冒烟' { return @('.\\.Rayman\\scripts\\testing\\run_host_smoke.ps1 -WorkspaceRoot "$PWD"') }
    '依赖自动补全默认项' { return @('.\\.Rayman\\setup.ps1') }
    'Agent Memory 检索有效' { return @('.\\.Rayman\\rayman.ps1 memory-bootstrap', '.\\.Rayman\\rayman.ps1 memory-search -Query "release requirements"') }
    '单仓库增强风险快照' { return @('.\\.Rayman\\rayman.ps1 single-repo-upgrade --RiskMode strict --ApproveHighRisk') }
    default {
      return @()
    }
  }
}

function Read-JsoncFile([string]$Path) {
  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $raw = $raw -replace '(?m)//.*$', ''
  $raw = $raw -replace '(?s)/\*.*?\*/', ''
  return ($raw | ConvertFrom-Json)
}

function Get-JsonOrNull([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Get-PropValue([object]$Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  $prop = $Object.PSObject.Properties[$Name]
  if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
  return $prop.Value
}

function Get-ReleaseGateReportSnapshot {
  param([string]$ReportPath)

  $snapshot = [ordered]@{
    exists = $false
    generated_at_utc = $null
    file_mtime_utc = $null
    timestamp_utc = $null
  }

  if ([string]::IsNullOrWhiteSpace([string]$ReportPath) -or -not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
    return [pscustomobject]$snapshot
  }

  $snapshot.exists = $true
  try {
    $snapshot.file_mtime_utc = (Get-Item -LiteralPath $ReportPath -Force).LastWriteTimeUtc
  } catch {}

  $report = Get-JsonOrNull -Path $ReportPath
  if ($null -ne $report) {
    $snapshot.generated_at_utc = Get-ReportGeneratedAtUtc -Report $report
  }
  if ($null -ne $snapshot.generated_at_utc) {
    $snapshot.timestamp_utc = $snapshot.generated_at_utc
  } else {
    $snapshot.timestamp_utc = $snapshot.file_mtime_utc
  }

  return [pscustomobject]$snapshot
}

function Get-ReleaseGateSnapshotKey {
  param([string]$ReportPath)

  if ([string]::IsNullOrWhiteSpace([string]$ReportPath)) {
    return ''
  }

  try {
    return ([System.IO.Path]::GetFullPath([string]$ReportPath).Trim().ToLowerInvariant())
  } catch {
    return ([string]$ReportPath).Trim().ToLowerInvariant()
  }
}

function Get-ReleaseGateDirectorySnapshotMap {
  param([string]$ReportDirectory)

  $snapshots = @{}
  if ([string]::IsNullOrWhiteSpace([string]$ReportDirectory) -or -not (Test-Path -LiteralPath $ReportDirectory -PathType Container)) {
    return $snapshots
  }

  foreach ($item in @(Get-ChildItem -LiteralPath $ReportDirectory -Filter '*.json' -File -Force -ErrorAction SilentlyContinue)) {
    if ($null -eq $item) { continue }
    $key = Get-ReleaseGateSnapshotKey -ReportPath ([string]$item.FullName)
    if ([string]::IsNullOrWhiteSpace($key)) { continue }
    $snapshots[$key] = Get-ReleaseGateReportSnapshot -ReportPath ([string]$item.FullName)
  }

  return $snapshots
}

function Get-ReleaseGateSnapshotFromMap {
  param(
    [hashtable]$SnapshotMap,
    [string]$ReportPath
  )

  if ($null -eq $SnapshotMap) {
    return $null
  }

  $key = Get-ReleaseGateSnapshotKey -ReportPath $ReportPath
  if ([string]::IsNullOrWhiteSpace($key) -or -not $SnapshotMap.ContainsKey($key)) {
    return $null
  }

  return $SnapshotMap[$key]
}

function Get-ReleaseGateObservedAutoRefreshStateText {
  param(
    [object]$InitialSnapshot,
    [object]$CurrentSnapshot,
    [string]$EvaluationStatus,
    [datetime]$GateStartedAt
  )

  if ($null -eq $CurrentSnapshot -or -not [bool](Get-PropValue -Object $CurrentSnapshot -Name 'exists' -Default $false)) {
    return ''
  }

  $currentTimestamp = Get-PropValue -Object $CurrentSnapshot -Name 'timestamp_utc' -Default $null
  if ($null -eq $currentTimestamp) {
    return ''
  }

  $gateStartedUtc = $GateStartedAt.ToUniversalTime()
  $initialExists = if ($null -ne $InitialSnapshot) {
    [bool](Get-PropValue -Object $InitialSnapshot -Name 'exists' -Default $false)
  } else {
    $false
  }
  $initialTimestamp = if ($null -ne $InitialSnapshot) {
    Get-PropValue -Object $InitialSnapshot -Name 'timestamp_utc' -Default $null
  } else {
    $null
  }

  $refreshedDuringGate = $false
  if ($initialExists -and $null -ne $initialTimestamp) {
    $refreshedDuringGate = ($currentTimestamp -gt $initialTimestamp.AddSeconds(1))
  } else {
    $refreshedDuringGate = ($currentTimestamp -ge $gateStartedUtc.AddSeconds(-1))
  }

  if (-not $refreshedDuringGate) {
    return ''
  }

  if ($EvaluationStatus -eq 'PASS') {
    return 'refreshed_and_passed'
  }
  if ($EvaluationStatus -eq 'STALE') {
    return 'still_stale_after_refresh'
  }

  return 'refreshed_and_failed'
}

function Get-FirstMatches([string[]]$Items, [int]$Limit = 5) {
  if ($null -eq $Items) { return @() }
  if ($Items.Count -le $Limit) { return $Items }
  return @($Items[0..($Limit-1)])
}

function Get-LegacySnippetSample {
  param(
    [string]$Raw,
    [string]$Pattern,
    [string]$RelPath
  )

  if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
  $lines = $Raw -split "`r?`n"
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match $Pattern) {
      $ln = $i + 1
      $prev = if ($i -gt 0) { $lines[$i-1].Trim() } else { '' }
      $curr = $lines[$i].Trim()
      $next = if ($i -lt ($lines.Count - 1)) { $lines[$i+1].Trim() } else { '' }
      return [pscustomobject]@{
        RelPath = $RelPath
        Line = $ln
        Prev = $prev
        Curr = $curr
        Next = $next
      }
    }
  }

  return $null
}

function Get-PathComparisonValue([string]$PathValue) {
  if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
  $candidate = [string]$PathValue
  if ($candidate.StartsWith('Microsoft.PowerShell.Core\FileSystem::', [System.StringComparison]::OrdinalIgnoreCase)) {
    $candidate = $candidate.Substring('Microsoft.PowerShell.Core\FileSystem::'.Length)
  }
  try {
    $full = [System.IO.Path]::GetFullPath($candidate)
  } catch {
    $full = $candidate
  }
  return ($full.TrimEnd('\', '/') -replace '\\', '/').ToLowerInvariant()
}

function Test-AbsolutePathText([string]$PathValue) {
  if ([string]::IsNullOrWhiteSpace($PathValue)) { return $false }
  if ($PathValue -match '^[A-Za-z]:[\\/]') { return $true }
  try {
    return [System.IO.Path]::IsPathRooted($PathValue)
  } catch {
    return $false
  }
}

function Get-DisplayRelativePath([string]$BasePath, [string]$FullPath) {
  if ([string]::IsNullOrWhiteSpace($FullPath)) { return '' }
  $baseRaw = [string]$BasePath
  $fullRaw = [string]$FullPath
  if ($baseRaw.StartsWith('Microsoft.PowerShell.Core\FileSystem::', [System.StringComparison]::OrdinalIgnoreCase)) {
    $baseRaw = $baseRaw.Substring('Microsoft.PowerShell.Core\FileSystem::'.Length)
  }
  if ($fullRaw.StartsWith('Microsoft.PowerShell.Core\FileSystem::', [System.StringComparison]::OrdinalIgnoreCase)) {
    $fullRaw = $fullRaw.Substring('Microsoft.PowerShell.Core\FileSystem::'.Length)
  }
  try {
    $baseFull = [System.IO.Path]::GetFullPath($baseRaw).TrimEnd('\', '/')
  } catch {
    $baseFull = $baseRaw.TrimEnd('\', '/')
  }
  try {
    $full = [System.IO.Path]::GetFullPath($fullRaw)
  } catch {
    $full = $fullRaw
  }
  $baseNorm = Get-PathComparisonValue $baseFull
  $fullNorm = Get-PathComparisonValue $full
  if ($fullNorm.StartsWith($baseNorm + '/')) {
    return ($full.Substring($baseFull.Length).TrimStart('\', '/') -replace '\\', '/')
  }
  return ($full -replace '\\', '/')
}

function Get-FileHashCompat([string]$Path, [string]$Algorithm = 'SHA1') {
  $cmd = Get-Command Get-FileHash -ErrorAction SilentlyContinue
  if ($null -ne $cmd) {
    return (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash
  }

  $alg = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
  if ($null -eq $alg) {
    throw ("hash algorithm not supported: {0}" -f $Algorithm)
  }

  $stream = [System.IO.File]::OpenRead($Path)
  try {
    $bytes = $alg.ComputeHash($stream)
  } finally {
    try { $stream.Dispose() } catch {}
    try { $alg.Dispose() } catch {}
  }

  return ([System.BitConverter]::ToString($bytes)).Replace('-', '')
}

function Resolve-ChildPowerShellHost {
  $isWindowsHost = $false
  try {
    $isWindowsHost = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
  } catch {
    $isWindowsHost = $false
  }

  $candidates = if ($isWindowsHost) {
    @('pwsh.exe', 'pwsh', 'powershell.exe', 'powershell')
  } else {
    @('pwsh', 'powershell', 'pwsh.exe', 'powershell.exe')
  }
  foreach ($name in $candidates) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
      return [string]$cmd.Source
    }
  }

  if (-not [string]::IsNullOrWhiteSpace([string]$PSHOME)) {
    $fallbackExe = Join-Path $PSHOME 'powershell.exe'
    if (Test-Path -LiteralPath $fallbackExe -PathType Leaf) {
      return $fallbackExe
    }
  }

  return $null
}

function Get-VersionTokenFromName([string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
  $m = [regex]::Match($Name, '(?i)\bv\d+\b')
  if (-not $m.Success) { return '' }
  return $m.Value.ToLowerInvariant()
}

function Resolve-AgentsPath([string]$Root) {
  $canonical = Join-Path $Root 'AGENTS.md'
  $legacy = Join-Path $Root 'agents.md'
  $canonicalExists = Test-Path -LiteralPath $canonical -PathType Leaf
  $legacyExists = Test-Path -LiteralPath $legacy -PathType Leaf

  if ($canonicalExists -and $legacyExists) {
    $canonicalHash = (Get-FileHash -LiteralPath $canonical -Algorithm SHA1).Hash
    $legacyHash = (Get-FileHash -LiteralPath $legacy -Algorithm SHA1).Hash
    if ($canonicalHash -ne $legacyHash) {
      throw "AGENTS file conflict: AGENTS.md and agents.md both exist but differ"
    }
    return $canonical
  }

  if ($canonicalExists) { return $canonical }
  if ($legacyExists) { return $legacy }
  return $null
}

function Invoke-RaymanAutoSnapshotIfNoGit([string]$Root, [string]$Reason) {
  $enabled = [string][System.Environment]::GetEnvironmentVariable('RAYMAN_AUTO_SNAPSHOT_ON_NO_GIT')
  if ([string]::IsNullOrWhiteSpace($enabled)) { $enabled = '1' }
  if ($enabled -eq '0') { return }

  $gitMarker = Join-Path $Root '.git'
  if (Test-Path -LiteralPath $gitMarker) { return }

  $snapshotScript = Join-Path $Root '.Rayman\scripts\backup\snapshot_workspace.ps1'
  if (-not (Test-Path -LiteralPath $snapshotScript -PathType Leaf)) { return }
  try {
    & $snapshotScript -WorkspaceRoot $Root -Reason $Reason | Out-Host
  } catch {
    Warn ("auto snapshot failed: {0}" -f $_.Exception.Message)
  }
}

. (Join-Path $PSScriptRoot 'release_gate.lib.ps1')

function Get-EnvBoolCompat([string]$Name, [bool]$Default = $false) {
  $raw = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
  switch ($raw.Trim().ToLowerInvariant()) {
    '1' { return $true }
    'true' { return $true }
    'yes' { return $true }
    'on' { return $true }
    '0' { return $false }
    'false' { return $false }
    'no' { return $false }
    'off' { return $false }
    default { return $Default }
  }
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

function Restore-EnvOverrides {
  param(
    [hashtable]$Backup
  )

  foreach ($name in $Backup.Keys) {
    [System.Environment]::SetEnvironmentVariable($name, [string]$Backup[$name])
  }
}

function Get-ReleaseGateAutoRefreshEnabled {
  param(
    [object]$Definition,
    [string]$Mode
  )

  if ($Mode -eq 'project') {
    return [bool](Get-PropValue -Object $Definition -Name 'AutoRefreshInProject' -Default $false)
  }

  return [bool](Get-PropValue -Object $Definition -Name 'AutoRefreshInStandard' -Default $false)
}

function Get-ReleaseGateAutoRefreshStateText {
  param(
    [object]$Attempt,
    [string]$EvaluationStatus,
    [bool]$ReportExists
  )

  if ($null -eq $Attempt -or -not [bool](Get-PropValue -Object $Attempt -Name 'attempted' -Default $false)) {
    return ''
  }

  if (-not $ReportExists -or [string]$EvaluationStatus -eq 'STALE') {
    return 'still_stale_after_refresh'
  }

  if ([string]$EvaluationStatus -eq 'PASS') {
    return 'refreshed_and_passed'
  }

  return 'refreshed_and_failed'
}

function Test-ProxyEndpointReachable([string]$ProxyUrl, [int]$TimeoutMs = 1200) {
  if ([string]::IsNullOrWhiteSpace($ProxyUrl)) { return $false }
  try {
    $uri = [System.Uri]$ProxyUrl
    if ($uri.Port -le 0) { return $false }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
      $task = $client.ConnectAsync($uri.Host, $uri.Port)
      if (-not $task.Wait($TimeoutMs)) { return $false }
      return $client.Connected
    } finally {
      $client.Dispose()
    }
  } catch {
    return $false
  }
}

function Set-ReleaseGateProxyEnv([string]$Root) {
  $runtimeProxyPath = Join-Path $Root '.Rayman\runtime\proxy.resolved.json'
  $fallbackProxy = [Environment]::GetEnvironmentVariable('RAYMAN_PROXY_FALLBACK_URL')
  if ([string]::IsNullOrWhiteSpace($fallbackProxy)) { $fallbackProxy = 'http://127.0.0.1:8988' }
  $enableFallback = Get-EnvBoolCompat -Name 'RAYMAN_PROXY_FALLBACK_8988' -Default $true

  $proxy = ''
  $noProxy = ''

  foreach ($name in @('https_proxy','HTTPS_PROXY','http_proxy','HTTP_PROXY','all_proxy','ALL_PROXY')) {
    $v = [Environment]::GetEnvironmentVariable($name)
    if (-not [string]::IsNullOrWhiteSpace([string]$v)) {
      $proxy = [string]$v
      break
    }
  }

  if ([string]::IsNullOrWhiteSpace($proxy) -and (Test-Path -LiteralPath $runtimeProxyPath -PathType Leaf)) {
    try {
      $snapshot = Get-Content -LiteralPath $runtimeProxyPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      foreach ($k in @('https_proxy','http_proxy','all_proxy')) {
        if ($snapshot.PSObject.Properties[$k] -and -not [string]::IsNullOrWhiteSpace([string]$snapshot.$k)) {
          $proxy = [string]$snapshot.$k
          break
        }
      }
      if ($snapshot.PSObject.Properties['no_proxy']) {
        $noProxy = [string]$snapshot.no_proxy
      }
    } catch {}
  }

  if ($enableFallback) {
    $fallbackReachable = Test-ProxyEndpointReachable -ProxyUrl $fallbackProxy
    if ([string]::IsNullOrWhiteSpace($proxy)) {
      if ($fallbackReachable) {
        $proxy = $fallbackProxy
        if ([string]::IsNullOrWhiteSpace($noProxy)) { $noProxy = 'localhost,127.0.0.1,::1' }
        Info ("启用 8988 回退代理: {0}" -f $proxy)
      }
    } elseif (-not (Test-ProxyEndpointReachable -ProxyUrl $proxy) -and $fallbackReachable) {
      Warn ("当前代理不可达，切换至 8988 回退代理: {0}" -f $fallbackProxy)
      $proxy = $fallbackProxy
      if ([string]::IsNullOrWhiteSpace($noProxy)) { $noProxy = 'localhost,127.0.0.1,::1' }
    }
  }

  if ([string]::IsNullOrWhiteSpace($proxy)) {
    Info '未检测到可用代理，保持直连。'
    return
  }

  foreach ($name in @('http_proxy','HTTP_PROXY','https_proxy','HTTPS_PROXY','all_proxy','ALL_PROXY','NUGET_HTTP_PROXY','NUGET_HTTPS_PROXY','NUGET_PROXY')) {
    [Environment]::SetEnvironmentVariable($name, $proxy)
  }
  if (-not [string]::IsNullOrWhiteSpace($noProxy)) {
    foreach ($name in @('no_proxy','NO_PROXY')) {
      [Environment]::SetEnvironmentVariable($name, $noProxy)
    }
  }
  Info ("已注入当前进程代理（含 NuGet/dotnet）: {0}" -f $proxy)
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$raymanDir = Join-Path $WorkspaceRoot '.Rayman'
$winAppCorePath = Join-Path $raymanDir 'scripts\windows\winapp_core.ps1'
$runtimeDir = Join-Path $raymanDir 'runtime'
if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
}
$initialTestLaneSnapshots = Get-ReleaseGateDirectorySnapshotMap -ReportDirectory (Join-Path $runtimeDir 'test_lanes')
$initialProjectGateSnapshots = Get-ReleaseGateDirectorySnapshotMap -ReportDirectory (Join-Path $runtimeDir 'project_gates')

if (Test-Path -LiteralPath $winAppCorePath -PathType Leaf) {
  . $winAppCorePath
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $ReportPath = Join-Path $raymanDir 'state\release_gate_report.md'
}
$reportDir = Split-Path -Parent $ReportPath
if ([string]::IsNullOrWhiteSpace($reportDir)) {
  $reportDir = Join-Path $raymanDir 'state'
}
if (-not (Test-Path -LiteralPath $reportDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
}

$results = New-Object System.Collections.Generic.List[object]
$residualCacheHintEnabled = $false
$residualCacheHintMessage = ''
$residualCacheHintPossible = $false
$expectedTag = 'V164'
$expectedVersion = 'V164'

$allowNoGitByEnv = Get-EnvBoolCompat -Name 'RAYMAN_ALLOW_NO_GIT' -Default $false
$allowNoGitEffective = ($AllowNoGit -or $allowNoGitByEnv)
$gitMarkerPath = Join-Path $WorkspaceRoot '.git'
$isGitWorkspace = Test-Path -LiteralPath $gitMarkerPath
if (-not $isGitWorkspace) {
  if ($allowNoGitEffective) {
    if ($Mode -eq 'project') {
      Add-Result -Results $results -Name 'Git工作区检测' -Status PASS -Detail '当前目录不是 Git 仓库（project 模式初始化豁免，按 PASS 处理）' -Action '如需严格校验，请在 Git 仓库中运行或改用 standard 模式'
    } else {
      Add-Result -Results $results -Name 'Git工作区检测' -Status WARN -Detail '当前目录不是 Git 仓库（已按 AllowNoGit 降级）' -Action '如需严格校验，请在 Git 仓库中运行或移除 AllowNoGit'
    }
  } else {
    Add-Result -Results $results -Name 'Git工作区检测' -Status FAIL -Detail '当前目录不是 Git 仓库' -Action '在 Git 仓库中运行，或显式传入 -AllowNoGit / 设置 RAYMAN_ALLOW_NO_GIT=1'
  }
} else {
  Add-Result -Results $results -Name 'Git工作区检测' -Status PASS -Detail '检测到 Git 工作区'
}
$scanIgnoreRules = Get-ReleaseGateScanIgnoreRules
$commonScript = Join-Path $raymanDir 'common.ps1'
$commonImported = $false
$commonImportError = ''
if (Test-Path -LiteralPath $commonScript -PathType Leaf) {
  try {
    . $commonScript
    $commonImported = $true
  } catch {
    $commonImportError = $_.Exception.Message
  }
} else {
  $commonImportError = ("common.ps1 缺失: {0}" -f $commonScript)
}

if (-not $isGitWorkspace) {
  Add-Result -Results $results -Name 'Rayman资产Git跟踪噪声' -Status PASS -Detail '当前目录不是 Git 仓库，跳过 tracked Rayman assets 检查' -Action '如需 SCM 噪声治理，请在 Git 工作区中运行'
  Add-Result -Results $results -Name '非Rayman产物Git跟踪噪声' -Status PASS -Detail '当前目录不是 Git 仓库，跳过 tracked noisy dirs 检查' -Action '如需 SCM 噪声治理，请在 Git 工作区中运行'
} elseif (-not $commonImported) {
  $detail = if ([string]::IsNullOrWhiteSpace($commonImportError)) { 'common.ps1 导入失败，无法分析 SCM 跟踪噪声' } else { "common.ps1 导入失败：$commonImportError" }
  Add-Result -Results $results -Name 'Rayman资产Git跟踪噪声' -Status FAIL -Detail $detail -Action '修复 .Rayman/common.ps1 后重试'
  Add-Result -Results $results -Name '非Rayman产物Git跟踪噪声' -Status FAIL -Detail $detail -Action '修复 .Rayman/common.ps1 后重试'
} else {
  $trackedNoise = Get-RaymanScmTrackedNoiseAnalysis -WorkspaceRoot $WorkspaceRoot
  if (-not [bool]$trackedNoise.available -or -not [bool]$trackedNoise.insideGit) {
    $detail = ("SCM 噪声分析不可用：status={0}, reason={1}" -f [string]$trackedNoise.status, [string]$trackedNoise.reason)
    Add-Result -Results $results -Name 'Rayman资产Git跟踪噪声' -Status FAIL -Detail $detail -Action '检查 Git 可用性与 common.ps1 分析逻辑'
    Add-Result -Results $results -Name '非Rayman产物Git跟踪噪声' -Status FAIL -Detail $detail -Action '检查 Git 可用性与 common.ps1 分析逻辑'
  } else {
    $workspaceKind = [string]$trackedNoise.workspaceKind
    $raymanDetail = Format-RaymanScmTrackedNoiseGroups -Groups $trackedNoise.raymanGroups
    if ([bool]$trackedNoise.raymanBlocked) {
      $action = if ([string]::IsNullOrWhiteSpace([string]$trackedNoise.raymanCommand)) {
        if ($workspaceKind -eq 'source') {
          '移除 source workspace 的本地/生成资产，或在确需临时入库时于 .rayman.env.ps1 设置 RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS=1'
        } else {
          '移除 external workspace 的 Rayman 生成资产 / 本地配置；这类仓库只建议提交业务源码、业务文档，以及 .<SolutionName>/ 下的 requirements / agentic 文档；如需临时入库则在 .rayman.env.ps1 设置 RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS=1'
        }
      } else {
        if ($workspaceKind -eq 'source') {
          "{0}；如需临时保留这些本地/生成资产，则在 .rayman.env.ps1 设置 RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS=1" -f [string]$trackedNoise.raymanCommand
        } else {
          "{0}；external workspace 只建议提交业务源码、业务文档，以及 .<SolutionName>/ 下的 requirements / agentic 文档；Rayman 生成的 workflow / 配置应保持未跟踪，如需临时保留则在 .rayman.env.ps1 设置 RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS=1" -f [string]$trackedNoise.raymanCommand
        }
      }
      $detail = if ($workspaceKind -eq 'source') {
        "检测到 source workspace 本地/生成资产已被 Git 跟踪: {0}" -f $raymanDetail
      } else {
        "检测到 external workspace 的 Rayman 生成资产 / 本地配置已被 Git 跟踪: {0}" -f $raymanDetail
      }
      Add-Result -Results $results -Name 'Rayman资产Git跟踪噪声' -Status FAIL -Detail $detail -Action $action
    } elseif ([int]$trackedNoise.raymanTrackedCount -gt 0) {
      $detail = if ($workspaceKind -eq 'source') {
        "已显式放行 source workspace 本地/生成资产: {0}" -f $raymanDetail
      } else {
        "已显式放行 external workspace 的 Rayman 生成资产 / 本地配置: {0}" -f $raymanDetail
      }
      Add-Result -Results $results -Name 'Rayman资产Git跟踪噪声' -Status PASS -Detail $detail -Action '如需恢复阻断，移除 .rayman.env.ps1 中的 RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS=1'
    } else {
      $detail = if ($workspaceKind -eq 'source') {
        '未发现 source workspace 本地/生成资产 Git 跟踪噪声'
      } else {
        '未发现 external workspace Rayman 生成资产 / 本地配置 Git 跟踪噪声'
      }
      Add-Result -Results $results -Name 'Rayman资产Git跟踪噪声' -Status PASS -Detail $detail
    }

    $advisoryDetail = Format-RaymanScmTrackedNoiseGroups -Groups $trackedNoise.advisoryGroups
    if ([bool]$trackedNoise.advisoryPresent) {
      $action = if ([string]::IsNullOrWhiteSpace([string]$trackedNoise.advisoryCommand)) {
        '如需清理索引，请移除这些常见产物目录的 tracked 状态'
      } else {
        ("建议清理索引：{0}" -f [string]$trackedNoise.advisoryCommand)
      }
      Add-Result -Results $results -Name '非Rayman产物Git跟踪噪声' -Status WARN -Detail ("检测到 tracked noisy dirs: {0}" -f $advisoryDetail) -Action $action
    } else {
      Add-Result -Results $results -Name '非Rayman产物Git跟踪噪声' -Status PASS -Detail '未发现 tracked noisy dirs'
    }
  }
}

Info "开始执行 Release Gate..."
Info ("运行模式: {0}" -f $Mode)
Invoke-RaymanAutoSnapshotIfNoGit -Root $WorkspaceRoot -Reason 'release_gate.ps1:auto-non-git'
Set-ReleaseGateProxyEnv -Root $WorkspaceRoot

# 0) 自动同步 .dist 镜像（默认开启）
if (-not $SkipAutoDistSync) {
  $distSyncScript = Join-Path $raymanDir 'scripts\release\sync_dist_from_src.ps1'
  if (-not (Test-Path -LiteralPath $distSyncScript -PathType Leaf)) {
    Add-Result -Results $results -Name 'Dist镜像同步' -Status FAIL -Detail ("缺少脚本: {0}" -f $distSyncScript) -Action '补齐 sync_dist_from_src.ps1 后重试'
  } else {
    try {
      & $distSyncScript -WorkspaceRoot $WorkspaceRoot -Validate | Out-Null
      Add-Result -Results $results -Name 'Dist镜像同步' -Status PASS -Detail '已自动同步并校验 .Rayman/.dist'
    } catch {
      Add-Result -Results $results -Name 'Dist镜像同步' -Status FAIL -Detail ("自动同步失败: {0}" -f $_.Exception.Message) -Action '检查 sync_dist_from_src.ps1 与 assert_dist_sync 脚本'
    }
  }
}

# 1) 版本一致性
$versionIssues = New-Object System.Collections.Generic.List[string]
$agentsPath = $null
$agentsTemplatePath = Join-Path $raymanDir 'agents.template.md'
$versionPath = Join-Path $raymanDir 'VERSION'
$distVersionPath = Join-Path $raymanDir '.dist\VERSION'

if ($Mode -eq 'standard') {
  try {
    $agentsPath = Resolve-AgentsPath -Root $WorkspaceRoot
  } catch {
    $versionIssues.Add($_.Exception.Message) | Out-Null
  }
  if ([string]::IsNullOrWhiteSpace([string]$agentsPath) -or -not (Test-Path -LiteralPath $agentsPath -PathType Leaf)) {
    $versionIssues.Add('missing AGENTS.md/agents.md (resolved path not found)') | Out-Null
  } else {
    $agentsRaw = Get-Content -LiteralPath $agentsPath -Raw -Encoding UTF8
    if ($agentsRaw -notmatch 'RAYMAN:MANDATORY_REQUIREMENTS_V164') {
      $agentsRel = Get-DisplayRelativePath -BasePath $WorkspaceRoot -FullPath $agentsPath
      $versionIssues.Add(("{0} missing V164 marker" -f $agentsRel)) | Out-Null
    }
  }
}

if (-not (Test-Path -LiteralPath $agentsTemplatePath -PathType Leaf)) {
  $versionIssues.Add('missing .Rayman/agents.template.md') | Out-Null
} else {
  $templateRaw = Get-Content -LiteralPath $agentsTemplatePath -Raw -Encoding UTF8
  if ($templateRaw -notmatch 'RAYMAN:MANDATORY_REQUIREMENTS_V164') {
    $versionIssues.Add('.Rayman/agents.template.md missing V164 marker') | Out-Null
  }
}

if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
  $versionIssues.Add('missing .Rayman/VERSION') | Out-Null
} else {
  $v = (Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8).Trim()
  if ($v -ne $expectedVersion) { $versionIssues.Add(".Rayman/VERSION=$v (expect $expectedVersion)") | Out-Null }
}

if (-not (Test-Path -LiteralPath $distVersionPath -PathType Leaf)) {
  $versionIssues.Add('missing .Rayman/.dist/VERSION') | Out-Null
} else {
  $dv = (Get-Content -LiteralPath $distVersionPath -Raw -Encoding UTF8).Trim()
  if ($dv -ne $expectedVersion) { $versionIssues.Add(".Rayman/.dist/VERSION=$dv (expect $expectedVersion)") | Out-Null }
}

$scanBase = if ($Mode -eq 'project') { $raymanDir } else { $WorkspaceRoot }
$scanFiles = Get-ChildItem -Path $scanBase -Recurse -Include *.md,*.ps1,*.psm1,*.json,VERSION -File -ErrorAction SilentlyContinue |
  Where-Object {
      -not (Test-ReleaseGatePathIgnored -FullPath $_.FullName -Rules $scanIgnoreRules)
  }

$legacyMatches = New-Object System.Collections.Generic.List[string]
$legacySnippets = New-Object System.Collections.Generic.List[object]
$legacyPattern = 'RAYMAN:MANDATORY_REQUIREMENTS_V117|RAYMAN:MANDATORY_REQUIREMENTS_V118|RAYMAN:MANDATORY_REQUIREMENTS_V154|\bv154\b|\bv153\b|\bv151\b'
foreach ($f in $scanFiles) {
  try {
    $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
    if ($raw -match $legacyPattern) {
      $rel = Get-DisplayRelativePath -BasePath $WorkspaceRoot -FullPath $f.FullName
      $legacyMatches.Add($rel) | Out-Null
      $sample = Get-LegacySnippetSample -Raw $raw -Pattern $legacyPattern -RelPath $rel
      if ($null -ne $sample) {
        $legacySnippets.Add($sample) | Out-Null
      }
    }
  } catch {}
}

if ($legacyMatches.Count -gt 0) {
  $versionIssues.Add(("legacy version marker exists: {0}" -f ((Get-FirstMatches -Items $legacyMatches -Limit 5) -join ', '))) | Out-Null
  if ($legacySnippets.Count -gt 0) {
    $samples = @($legacySnippets | Select-Object -First 3 | ForEach-Object {
      ("{0}:{1} => {2}" -f $_.RelPath, $_.Line, $_.Curr)
    })
    $versionIssues.Add(("legacy snippet samples: {0}" -f ($samples -join ' || '))) | Out-Null
  }
}

if ($versionIssues.Count -eq 0) {
  Add-Result -Results $results -Name '版本一致性' -Status PASS -Detail ("版本与标记均已统一到 {0}/{1}（mode={2}）" -f $expectedTag, $expectedVersion, $Mode)
} else {
  Add-Result -Results $results -Name '版本一致性' -Status FAIL -Detail ($versionIssues -join ' | ') -Action '统一版本并清理旧标记'
}

# 1.1) 发布包版本一致性（project 模式初始化豁免为 PASS，standard 保持 FAIL）
$releaseArtifactIssues = New-Object System.Collections.Generic.List[string]
$releaseDir = Join-Path $raymanDir 'release'
if (Test-Path -LiteralPath $releaseDir -PathType Container) {
  $releaseZips = Get-ChildItem -LiteralPath $releaseDir -Filter 'rayman-distributable-*.zip' -File -ErrorAction SilentlyContinue
  foreach ($zip in $releaseZips) {
    $token = Get-VersionTokenFromName -Name $zip.Name
    if ([string]::IsNullOrWhiteSpace($token)) {
      $releaseArtifactIssues.Add(("{0} 缺少版本标记" -f $zip.Name)) | Out-Null
      continue
    }
    if ($token -ne $expectedVersion) {
      $releaseArtifactIssues.Add(("{0} -> {1} (expect {2})" -f $zip.Name, $token, $expectedVersion)) | Out-Null
    }
  }
}

if ($releaseArtifactIssues.Count -eq 0) {
  $artifactCount = 0
  if (Test-Path -LiteralPath $releaseDir -PathType Container) {
    $artifactCount = @(Get-ChildItem -LiteralPath $releaseDir -Filter 'rayman-distributable-*.zip' -File -ErrorAction SilentlyContinue).Count
  }
  Add-Result -Results $results -Name '发布包版本一致性' -Status PASS -Detail ("release 目录版本一致（packages={0}）" -f $artifactCount)
} else {
  $artifactDetail = ($releaseArtifactIssues -join ' | ')
  if ($Mode -eq 'project') {
    Add-Result -Results $results -Name '发布包版本一致性' -Status PASS -Detail ("project 模式初始化豁免：{0}" -f $artifactDetail) -Action ("如需严格发布，请清理旧版本发布包，仅保留 {0} 产物（建议 standard 模式复检）" -f $expectedVersion)
  } else {
    Add-Result -Results $results -Name '发布包版本一致性' -Status FAIL -Detail $artifactDetail -Action ("清理旧版本发布包，仅保留 {0} 产物" -f $expectedVersion)
  }
}

# 2) 关键脚本存在性
$requiredFiles = @(
  '.Rayman/setup.ps1',
  '.Rayman/init.ps1',
  '.Rayman/common.ps1',
  '.Rayman/scripts/release/release_gate.ps1',
  '.Rayman/scripts/release/contract_git_safe.sh',
  '.Rayman/scripts/release/contract_scm_tracked_noise.sh',
  '.Rayman/scripts/release/contract_nested_repair.sh',
  '.Rayman/scripts/pwa/ensure_playwright_ready.ps1',
  '.Rayman/scripts/pwa/ensure_playwright_wsl.sh',
  '.Rayman/scripts/memory/memory_bootstrap.ps1',
  '.Rayman/scripts/memory/manage_memory.ps1',
  '.Rayman/scripts/memory/memory_common.ps1',
  '.Rayman/scripts/memory/manage_memory.py',
  '.Rayman/scripts/mcp/manage_mcp.ps1',
  '.Rayman/win-watch.ps1',
  '.Rayman/scripts/watch/embedded_watchers.lib.ps1',
  '.Rayman/scripts/watch/start_background_watchers.ps1',
  '.Rayman/scripts/watch/vscode_folder_open_bootstrap.ps1',
  '.Rayman/scripts/watch/daily_health_check.ps1',
  '.Rayman/scripts/state/save_state.ps1',
  '.Rayman/scripts/state/resume_state.ps1',
  '.Rayman/scripts/utils/diagnose_residual_diagnostics.ps1',
  '.Rayman/scripts/utils/request_attention.ps1',
  '.Rayman/scripts/agents/ensure_agent_assets.ps1',
  '.Rayman/scripts/agents/ensure_agent_capabilities.ps1',
  '.Rayman/scripts/agents/dispatch.ps1',
  '.Rayman/scripts/agents/review_loop.ps1',
  '.Rayman/scripts/agents/first_pass_report.ps1',
  '.Rayman/scripts/agents/prompts_catalog.ps1',
  '.Rayman/config/agent_capabilities.json'
)

$missing = @()
foreach ($rel in $requiredFiles) {
  $p = Join-Path $WorkspaceRoot $rel
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $missing += $rel }
}
if ($missing.Count -eq 0) {
  Add-Result -Results $results -Name '关键脚本完整性' -Status PASS -Detail '关键入口脚本齐全'
} else {
  Add-Result -Results $results -Name '关键脚本完整性' -Status FAIL -Detail ("缺失: " + ($missing -join ', ')) -Action '补齐缺失脚本后重试'
}

# 3) 心跳自动配置
$workspaceEnv = Join-Path $WorkspaceRoot '.rayman.env.ps1'
if (-not (Test-Path -LiteralPath $workspaceEnv -PathType Leaf)) {
  Add-Result -Results $results -Name '心跳自动配置' -Status FAIL -Detail '.rayman.env.ps1 不存在' -Action '运行 ./.Rayman/setup.ps1 生成并加载'
} else {
  try {
    . $workspaceEnv
    $requiredEnv = @(
      'RAYMAN_HEARTBEAT_SECONDS',
      'RAYMAN_HEARTBEAT_VERBOSE',
      'RAYMAN_HEARTBEAT_SMART_SILENCE_ENABLED',
      'RAYMAN_HEARTBEAT_SILENT_WINDOW_SECONDS',
      'RAYMAN_SANDBOX_HEARTBEAT_SECONDS',
      'RAYMAN_MCP_HEARTBEAT_SECONDS'
    )
    $missingEnv = @()
    foreach ($n in $requiredEnv) {
      $v = [System.Environment]::GetEnvironmentVariable($n)
      if ([string]::IsNullOrWhiteSpace([string]$v)) { $missingEnv += $n }
    }
    if ($missingEnv.Count -eq 0) {
      Add-Result -Results $results -Name '心跳自动配置' -Status PASS -Detail '心跳变量自动加载正常'
    } else {
      Add-Result -Results $results -Name '心跳自动配置' -Status FAIL -Detail ("缺失环境变量: " + ($missingEnv -join ', ')) -Action '检查 .rayman.env.ps1 内容'
    }
  } catch {
    Add-Result -Results $results -Name '心跳自动配置' -Status FAIL -Detail ("加载 .rayman.env.ps1 失败: {0}" -f $_.Exception.Message) -Action '修复 .rayman.env.ps1 语法'
  }
}

# 4) VS Code 任务注册
$tasksPath = Join-Path $WorkspaceRoot '.vscode\tasks.json'
if (-not (Test-Path -LiteralPath $tasksPath -PathType Leaf)) {
  Add-Result -Results $results -Name 'VSCode任务注册' -Status FAIL -Detail '.vscode/tasks.json 不存在' -Action '运行 ./.Rayman/setup.ps1'
} else {
  try {
    $tasksJson = Read-JsoncFile -Path $tasksPath
    $labels = @()
    if ($tasksJson.tasks) { $labels = @($tasksJson.tasks | ForEach-Object { [string]$_.label }) }
    $requiredLabels = @(
      'Rayman: Auto Start Watchers',
      'Rayman: Ensure Agent Capabilities',
      'Rayman: Ensure WinApp Automation',
      'Rayman: Check Win Deps',
      'Rayman: Worker Discover',
      'Rayman: Worker Status',
      'Rayman: Worker Sync',
      'Rayman: Worker Upgrade',
      'Rayman: Worker Debug Prepare',
      'Rayman: Test & Fix',
      'Rayman: Release Gate'
    )
    $missingLabels = @()
    foreach ($l in $requiredLabels) {
      if ($labels -notcontains $l) { $missingLabels += $l }
    }
    if ($missingLabels.Count -eq 0) {
      Add-Result -Results $results -Name 'VSCode任务注册' -Status PASS -Detail '关键任务均已注册'
    } else {
      Add-Result -Results $results -Name 'VSCode任务注册' -Status FAIL -Detail ("缺少任务: " + ($missingLabels -join ', ')) -Action '重新运行 setup 生成 tasks.json'
    }
  } catch {
    Add-Result -Results $results -Name 'VSCode任务注册' -Status FAIL -Detail ("tasks.json 解析失败: {0}" -f $_.Exception.Message) -Action '修复 tasks.json 格式'
  }
}

$launchPath = Join-Path $WorkspaceRoot '.vscode\launch.json'
if (-not (Test-Path -LiteralPath $launchPath -PathType Leaf)) {
  Add-Result -Results $results -Name 'VSCode调试注册' -Status FAIL -Detail '.vscode/launch.json 不存在' -Action '运行 ./.Rayman/setup.ps1'
} else {
  try {
    $launchJson = Read-JsoncFile -Path $launchPath
    $launchNames = @()
    if ($launchJson.configurations) { $launchNames = @($launchJson.configurations | ForEach-Object { [string]$_.name }) }
    $requiredLaunchNames = @(
      'Rayman Worker: Launch .NET (Active Worker)',
      'Rayman Worker: Attach .NET (Active Worker)'
    )
    $missingLaunchNames = @()
    foreach ($name in $requiredLaunchNames) {
      if ($launchNames -notcontains $name) { $missingLaunchNames += $name }
    }
    if ($missingLaunchNames.Count -eq 0) {
      Add-Result -Results $results -Name 'VSCode调试注册' -Status PASS -Detail '关键 worker 调试入口均已注册'
    } else {
      Add-Result -Results $results -Name 'VSCode调试注册' -Status FAIL -Detail ("缺少 launch 配置: " + ($missingLaunchNames -join ', ')) -Action '重新运行 setup 生成 launch.json'
    }
  } catch {
    Add-Result -Results $results -Name 'VSCode调试注册' -Status FAIL -Detail ("launch.json 解析失败: {0}" -f $_.Exception.Message) -Action '修复 launch.json 格式'
  }
}

# 5) Agent Memory 存储有效
$memoryPathIssues = @()
$memoryPaths = $null
if (-not $commonImported) {
  if ([string]::IsNullOrWhiteSpace($commonImportError)) {
    $memoryPathIssues += 'common.ps1 导入失败，无法解析 Agent Memory 路径'
  } else {
    $memoryPathIssues += ("common.ps1 导入失败，无法解析 Agent Memory 路径: {0}" -f $commonImportError)
  }
} else {
  try {
    $memoryPaths = Get-RaymanMemoryPaths -WorkspaceRoot $WorkspaceRoot
  } catch {
    $memoryPathIssues += ("Agent Memory 路径解析失败: {0}" -f $_.Exception.Message)
  }
}

foreach ($legacyMemoryPath in @(
  (Join-Path $WorkspaceRoot ('.' + 'rag')),
  (Join-Path (Join-Path $WorkspaceRoot '.Rayman\state') ('chroma' + '_db')),
  (Join-Path (Join-Path $WorkspaceRoot '.Rayman\state') ('rag' + '.db'))
)) {
  if (Test-Path -LiteralPath $legacyMemoryPath) {
    $memoryPathIssues += ("检测到 legacy 记忆数据残留: {0}" -f $legacyMemoryPath)
  }
}

if ($null -ne $memoryPaths) {
  $expectedRoot = Get-PathComparisonValue (Join-Path $WorkspaceRoot '.Rayman/state/memory')
  $actualRoot = Get-PathComparisonValue ([string]$memoryPaths.MemoryRoot)
  $actualDb = Get-PathComparisonValue ([string]$memoryPaths.DatabasePath)

  if ([string]::IsNullOrWhiteSpace($actualRoot)) {
    $memoryPathIssues += 'MemoryRoot 为空'
  } elseif ($actualRoot -ne $expectedRoot -and -not $actualRoot.StartsWith($expectedRoot + '/')) {
    $memoryPathIssues += ("MemoryRoot 必须位于工作区 .Rayman/state/memory 下，当前: {0}" -f $actualRoot)
  }

  if ([string]::IsNullOrWhiteSpace($actualDb)) {
    $memoryPathIssues += 'DatabasePath 为空'
  } elseif (-not $actualDb.StartsWith($expectedRoot + '/')) {
    $memoryPathIssues += ("DatabasePath 必须位于工作区 .Rayman/state/memory 下，当前: {0}" -f $actualDb)
  }
}

if ($memoryPathIssues.Count -eq 0) {
  Add-Result -Results $results -Name 'Agent Memory 存储有效' -Status PASS -Detail ("Agent Memory 路径有效：{0}" -f [string]$memoryPaths.DatabasePath)
} else {
  Add-Result -Results $results -Name 'Agent Memory 存储有效' -Status FAIL -Detail ($memoryPathIssues -join ' | ') -Action '清理 legacy 记忆数据，并执行 ./.Rayman/rayman.ps1 memory-bootstrap'
}

# 6) MCP 配置可移植性（禁止硬编码工作区绝对路径）
$mcpConfigIssues = New-Object System.Collections.Generic.List[string]
$mcpConfigPath = Join-Path $raymanDir 'mcp\mcp_servers.json'
if (-not (Test-Path -LiteralPath $mcpConfigPath -PathType Leaf)) {
  $mcpConfigIssues.Add(("missing: {0}" -f $mcpConfigPath)) | Out-Null
} else {
  try {
    $mcpConfigRaw = Get-Content -LiteralPath $mcpConfigPath -Raw -Encoding UTF8
    $mcpConfig = $mcpConfigRaw | ConvertFrom-Json -ErrorAction Stop
    $sqlite = $mcpConfig.mcpServers.sqlite
    if ($null -eq $sqlite) {
      $mcpConfigIssues.Add('mcpServers.sqlite 不存在') | Out-Null
    } else {
      $sqliteParamList = @()
      $sqliteArgsProp = $null
      $sqliteArgumentPropertyName = ('ar' + 'gs')
      foreach ($prop in $sqlite.PSObject.Properties) {
        if ([string]::Equals([string]$prop.Name, $sqliteArgumentPropertyName, [System.StringComparison]::OrdinalIgnoreCase)) {
          $sqliteArgsProp = $prop
          break
        }
      }
      if ($null -ne $sqliteArgsProp) { $sqliteParamList = @($sqliteArgsProp.Value) }
      $dbPathIndex = -1
      for ($i = 0; $i -lt $sqliteParamList.Count; $i++) {
        if ([string]$sqliteParamList[$i] -eq '--db-path') {
          $dbPathIndex = $i
          break
        }
      }

      if ($dbPathIndex -lt 0 -or ($dbPathIndex + 1) -ge $sqliteParamList.Count) {
        $mcpConfigIssues.Add('sqlite 缺少 --db-path 配置') | Out-Null
      } else {
        $dbPathRaw = [string]$sqliteParamList[$dbPathIndex + 1]
        $rawLower = $dbPathRaw.ToLowerInvariant()
        $isTokenized = ($rawLower.Contains('${workspaceroot}') -or $rawLower.Contains('${workspace_root}') -or $rawLower.Contains('%workspace_root%'))
        $isAbsolute = Test-AbsolutePathText -PathValue $dbPathRaw

        $workspaceNorm = Get-PathComparisonValue $WorkspaceRoot
        $resolvedForCompare = ''
        if (-not [string]::IsNullOrWhiteSpace($dbPathRaw)) {
          try {
            if ($isAbsolute) {
              $resolvedForCompare = Get-PathComparisonValue $dbPathRaw
            } else {
              $resolvedForCompare = Get-PathComparisonValue (Join-Path $WorkspaceRoot $dbPathRaw)
            }
          } catch {
            $resolvedForCompare = ($dbPathRaw -replace '\\', '/').ToLowerInvariant()
          }
        }

        if ($isAbsolute -and (-not $isTokenized) -and $resolvedForCompare.EndsWith('/.rayman/state/rayman.db')) {
          $mcpConfigIssues.Add(("sqlite --db-path 使用了机器绝对路径: {0}" -f $dbPathRaw)) | Out-Null
        } elseif ($isAbsolute -and (-not $isTokenized) -and (-not [string]::IsNullOrWhiteSpace($workspaceNorm)) -and $resolvedForCompare.StartsWith($workspaceNorm + '/')) {
          $mcpConfigIssues.Add(("sqlite --db-path 硬编码当前工作区根路径: {0}" -f $dbPathRaw)) | Out-Null
        }
      }
    }
  } catch {
    $mcpConfigIssues.Add(("mcp_servers.json 解析失败: {0}" -f $_.Exception.Message)) | Out-Null
  }
}

if ($mcpConfigIssues.Count -eq 0) {
  Add-Result -Results $results -Name 'MCP配置可移植性' -Status PASS -Detail 'mcp_servers.json 未发现工作区硬编码路径'
} else {
  Add-Result -Results $results -Name 'MCP配置可移植性' -Status FAIL -Detail ($mcpConfigIssues -join ' | ') -Action '改用 ${workspaceRoot}/.Rayman/state/rayman.db 或外部自定义路径'
}

# 7) Playwright summary 结构完整性（失败也要有错误上下文）
$playwrightSummaryIssues = New-Object System.Collections.Generic.List[string]
$playwrightSummaryPath = Join-Path $runtimeDir 'playwright.ready.windows.json'
if (-not (Test-Path -LiteralPath $playwrightSummaryPath -PathType Leaf)) {
  $playwrightSummaryIssues.Add(("missing: {0}" -f $playwrightSummaryPath)) | Out-Null
} else {
  try {
    $playSummary = Get-Content -LiteralPath $playwrightSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if (-not (Test-ReportWorkspaceRootMatch -Report $playSummary -WorkspaceRoot $WorkspaceRoot)) {
      $playwrightSummaryIssues.Add(("stale_report_workspace_mismatch:{0}" -f (Get-ReportWorkspaceRoot -Report $playSummary))) | Out-Null
    } else {
      $requiredFields = @(
        'schema','scope','browser','require','timeout_seconds','workspace_root',
        'started_at','finished_at','success','error_type','error_message','script_stack',
        'host_ps_version','host_is_windows','stage','detail_log','wsl','sandbox'
      )
      foreach ($field in $requiredFields) {
        if ($null -eq $playSummary.PSObject.Properties[$field]) {
          $playwrightSummaryIssues.Add(("缺少字段: {0}" -f $field)) | Out-Null
        }
      }

      if ($null -ne $playSummary.PSObject.Properties['success'] -and (-not [bool]$playSummary.success)) {
        if ([string]::IsNullOrWhiteSpace([string]$playSummary.error_message)) {
          $playwrightSummaryIssues.Add('success=false 但 error_message 为空') | Out-Null
        }
        if ([string]::IsNullOrWhiteSpace([string]$playSummary.script_stack)) {
          $playwrightSummaryIssues.Add('success=false 但 script_stack 为空') | Out-Null
        }
      }
    }
  } catch {
    $playwrightSummaryIssues.Add(("playwright summary 解析失败: {0}" -f $_.Exception.Message)) | Out-Null
  }
}

if ($playwrightSummaryIssues.Count -eq 0) {
  Add-Result -Results $results -Name 'Playwright摘要结构' -Status PASS -Detail ("summary 结构完整: {0}" -f $playwrightSummaryPath)
} else {
  Add-Result -Results $results -Name 'Playwright摘要结构' -Status FAIL -Detail ($playwrightSummaryIssues -join ' | ') -Action '重新执行 ./.Rayman/scripts/pwa/ensure_playwright_ready.ps1 生成完整摘要'
}

# 8) 依赖自动补全默认项（setup 模板约束）
$autoDepsDefaultIssues = New-Object System.Collections.Generic.List[string]
$setupScriptPath = Join-Path $raymanDir 'setup.ps1'
if (-not (Test-Path -LiteralPath $setupScriptPath -PathType Leaf)) {
  $autoDepsDefaultIssues.Add(("missing: {0}" -f $setupScriptPath)) | Out-Null
} else {
  $setupRaw = Get-Content -LiteralPath $setupScriptPath -Raw -Encoding UTF8
  $requiredSetupTokens = @(
    'RAYMAN_AUTO_INSTALL_TEST_DEPS'
    'RAYMAN_REQUIRE_TEST_DEPS'
    'RAYMAN_SELF_HEAL_AUTO_DEP_INSTALL'
    'RAYMAN_PLAYWRIGHT_REQUIRE'
    'RAYMAN_PLAYWRIGHT_AUTO_INSTALL'
    'RAYMAN_SETUP_GIT_INIT'
    'RAYMAN_SETUP_GITHUB_LOGIN'
    'RAYMAN_SETUP_GITHUB_LOGIN_STRICT'
    'RAYMAN_GITHUB_HOST'
    'RAYMAN_GITHUB_GIT_PROTOCOL'
    'RAYMAN_SANDBOX_OFFLINE_CACHE_ENABLED'
    'RAYMAN_SANDBOX_OFFLINE_CACHE_COPY_BROWSERS'
    'RAYMAN_SANDBOX_OFFLINE_CACHE_REFRESH_HOURS'
    'RAYMAN_SANDBOX_OFFLINE_CACHE_FORCE'
    'RAYMAN_DOTNET_WINDOWS_PREFERRED'
    'RAYMAN_DOTNET_WINDOWS_STRICT'
    'RAYMAN_DOTNET_WINDOWS_TIMEOUT_SECONDS'
    'RAYMAN_AGENT_DEFAULT_BACKEND'
    'RAYMAN_AGENT_FALLBACK_ORDER'
    'RAYMAN_AGENT_CLOUD_ENABLED'
    'RAYMAN_AGENT_POLICY_BYPASS'
    'RAYMAN_AGENT_CLOUD_WHITELIST'
    'RAYMAN_AGENT_CAPABILITIES_ENABLED'
    'RAYMAN_AGENT_CAP_OPENAI_DOCS_ENABLED'
    'RAYMAN_AGENT_CAP_WEB_AUTO_TEST_ENABLED'
    'RAYMAN_FIRST_PASS_WINDOW'
    'RAYMAN_REVIEW_LOOP_MAX_ROUNDS'
  )
  foreach ($token in $requiredSetupTokens) {
    if ($setupRaw -notmatch [regex]::Escape($token)) {
      $autoDepsDefaultIssues.Add(("setup.ps1 缺少默认项: {0}" -f $token)) | Out-Null
    }
  }
}

if ($autoDepsDefaultIssues.Count -eq 0) {
  Add-Result -Results $results -Name '依赖自动补全默认项' -Status PASS -Detail 'setup 模板已包含依赖自动补全默认变量'
} else {
  Add-Result -Results $results -Name '依赖自动补全默认项' -Status FAIL -Detail ($autoDepsDefaultIssues -join ' | ') -Action '补齐 setup.ps1 中 .rayman.env 默认变量块'
}

# 8.1) Agent capability sync 契约（生成 .codex/config.toml managed block 并验证幂等）
$agentCapabilityIssues = New-Object System.Collections.Generic.List[string]
$agentCapabilityConfigPath = Join-Path $raymanDir 'config\agent_capabilities.json'
$agentCapabilityScriptPath = Join-Path $raymanDir 'scripts\agents\ensure_agent_capabilities.ps1'
$codexConfigPath = Join-Path $WorkspaceRoot '.codex\config.toml'
$agentCapabilityReportPath = Join-Path $runtimeDir 'agent_capabilities.report.json'

if (-not (Test-Path -LiteralPath $agentCapabilityConfigPath -PathType Leaf)) {
  $agentCapabilityIssues.Add(("missing: {0}" -f $agentCapabilityConfigPath)) | Out-Null
} else {
  $capRaw = Get-Content -LiteralPath $agentCapabilityConfigPath -Raw -Encoding UTF8
  foreach ($token in @('rayman.agent_capabilities.v1', '"openai_docs"', '"web_auto_test"', '"openaiDeveloperDocs"', '"@playwright/mcp"')) {
    if ($capRaw -notmatch [regex]::Escape($token)) {
      $agentCapabilityIssues.Add(("agent_capabilities.json 缺少标记: {0}" -f $token)) | Out-Null
    }
  }
}

if (-not (Test-Path -LiteralPath $agentCapabilityScriptPath -PathType Leaf)) {
  $agentCapabilityIssues.Add(("missing: {0}" -f $agentCapabilityScriptPath)) | Out-Null
} else {
  $envBackup = @{}
  try {
    Set-EnvOverride -Backup $envBackup -Name 'RAYMAN_AGENT_CAPABILITIES_SKIP_PREPARE' -Value '1'
    & $agentCapabilityScriptPath -WorkspaceRoot $WorkspaceRoot -Action sync | Out-Null
    $firstHash = ''
    if (Test-Path -LiteralPath $codexConfigPath -PathType Leaf) {
      $firstHash = Get-FileHashCompat -Path $codexConfigPath -Algorithm 'SHA1'
    }

    & $agentCapabilityScriptPath -WorkspaceRoot $WorkspaceRoot -Action sync | Out-Null
    $secondHash = ''
    if (Test-Path -LiteralPath $codexConfigPath -PathType Leaf) {
      $secondHash = Get-FileHashCompat -Path $codexConfigPath -Algorithm 'SHA1'
    }

    $capabilityReport = Get-JsonOrNull -Path $agentCapabilityReportPath
    if ($null -eq $capabilityReport) {
      $agentCapabilityIssues.Add(("agent capability report 缺失或解析失败: {0}" -f $agentCapabilityReportPath)) | Out-Null
    } else {
      if (-not [bool]$capabilityReport.registry_valid) {
        $agentCapabilityIssues.Add('agent capability report 标记 registry_valid=false') | Out-Null
      }

      $activeCaps = @($capabilityReport.active_capabilities | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      $managedBlockPresent = [bool]$capabilityReport.managed_block_present
      $codexConfigExists = Test-Path -LiteralPath $codexConfigPath -PathType Leaf
      $codexConfigRaw = ''
      if ($codexConfigExists) {
        $codexConfigRaw = Get-Content -LiteralPath $codexConfigPath -Raw -Encoding UTF8
      }
      $markersPresent = ($codexConfigRaw -match [regex]::Escape('# >>> Rayman managed capabilities >>>') -and $codexConfigRaw -match [regex]::Escape('# <<< Rayman managed capabilities <<<'))
      if ($managedBlockPresent -ne $markersPresent) {
        $agentCapabilityIssues.Add('agent capability report 与 .codex/config.toml 的 managed block 状态不一致') | Out-Null
      }

      if ([bool]$capabilityReport.global_enabled -and $activeCaps.Count -gt 0) {
        if (-not $codexConfigExists) {
          $agentCapabilityIssues.Add((".codex/config.toml 未生成: {0}" -f $codexConfigPath)) | Out-Null
        } elseif (-not $markersPresent) {
          $agentCapabilityIssues.Add('.codex/config.toml 缺少 managed block 标记') | Out-Null
        } else {
          if ($activeCaps -contains 'openai_docs') {
            foreach ($token in @('mcp_servers.openaiDeveloperDocs', 'https://developers.openai.com/mcp')) {
              if ($codexConfigRaw -notmatch [regex]::Escape($token)) {
                $agentCapabilityIssues.Add((".codex/config.toml 缺少 OpenAI Docs MCP 标记: {0}" -f $token)) | Out-Null
              }
            }
          }
          if ($activeCaps -contains 'web_auto_test') {
            foreach ($token in @('mcp_servers.playwright', '@playwright/mcp')) {
              if ($codexConfigRaw -notmatch [regex]::Escape($token)) {
                $agentCapabilityIssues.Add((".codex/config.toml 缺少 Playwright MCP 标记: {0}" -f $token)) | Out-Null
              }
            }
          }
          if ($activeCaps -contains 'winapp_auto_test') {
            foreach ($token in @('mcp_servers.raymanWinApp', 'winapp_mcp_server.ps1')) {
              if ($codexConfigRaw -notmatch [regex]::Escape($token)) {
                $agentCapabilityIssues.Add((".codex/config.toml 缺少 WinApp MCP 标记: {0}" -f $token)) | Out-Null
              }
            }
          }
        }
      }

      if (-not [string]::IsNullOrWhiteSpace($firstHash) -and -not [string]::IsNullOrWhiteSpace($secondHash) -and $firstHash -ne $secondHash) {
        $agentCapabilityIssues.Add('.codex/config.toml 连续两次 sync 后哈希不一致（非幂等）') | Out-Null
      }
    }
  } catch {
    $agentCapabilityIssues.Add(("ensure_agent_capabilities.ps1 执行失败: {0}" -f $_.Exception.Message)) | Out-Null
  } finally {
    Restore-EnvOverrides -Backup $envBackup
  }
}

if ($agentCapabilityIssues.Count -eq 0) {
  Add-Result -Results $results -Name 'Agent能力同步' -Status PASS -Detail 'registry / script / .codex/config.toml managed block 均通过，连续 sync 幂等'
} else {
  Add-Result -Results $results -Name 'Agent能力同步' -Status FAIL -Detail ($agentCapabilityIssues -join ' | ') -Action '执行 ./.Rayman/rayman.ps1 agent-capabilities --sync 并修复 registry/script/config'
}

# 8.1) Windows 桌面自动化能力
$winAppCapabilityIssues = New-Object System.Collections.Generic.List[string]
$winAppEnsurePath = Join-Path $raymanDir 'scripts\windows\ensure_winapp.ps1'
$winAppReadyPath = Join-Path $raymanDir 'runtime\winapp.ready.windows.json'
$winAppCapabilityStatus = 'PASS'
$winAppCapabilityDetail = ''

if (-not (Test-Path -LiteralPath $winAppEnsurePath -PathType Leaf)) {
  $winAppCapabilityIssues.Add(("missing: {0}" -f $winAppEnsurePath)) | Out-Null
} else {
  try {
    if (Test-Path variable:LASTEXITCODE) { $global:LASTEXITCODE = 0 }
    & $winAppEnsurePath -WorkspaceRoot $WorkspaceRoot -Require:$false | Out-Null
    if (-not (Test-Path -LiteralPath $winAppReadyPath -PathType Leaf)) {
      $winAppCapabilityIssues.Add(("readiness report missing: {0}" -f $winAppReadyPath)) | Out-Null
    } else {
      $winAppReport = Get-JsonOrNull -Path $winAppReadyPath
      if ($null -eq $winAppReport) {
        $winAppCapabilityIssues.Add(("readiness report parse failed: {0}" -f $winAppReadyPath)) | Out-Null
      } elseif ([bool](Get-PropValue -Object $winAppReport -Name 'ready' -Default $false)) {
        $winAppCapabilityStatus = 'PASS'
        $winAppCapabilityDetail = 'Windows UI Automation readiness passed'
      } else {
        $reason = [string](Get-PropValue -Object $winAppReport -Name 'reason' -Default 'unknown')
        $detail = [string](Get-PropValue -Object $winAppReport -Name 'detail' -Default '')
        $notApplicable = $false
        if (Get-Command Test-WinAppReadinessReasonNotApplicable -ErrorAction SilentlyContinue) {
          $notApplicable = Test-WinAppReadinessReasonNotApplicable -Reason $reason
        }
        if ($notApplicable) {
          $winAppCapabilityStatus = 'PASS'
          $winAppCapabilityDetail = ('desktop capability not applicable on current host: {0} ({1})' -f $reason, $detail)
        } elseif ($reason -eq 'desktop_session_unavailable') {
          $winAppCapabilityStatus = 'WARN'
          $winAppCapabilityDetail = ('desktop capability unavailable in current environment: {0} ({1})' -f $reason, $detail)
        } else {
          $winAppCapabilityIssues.Add(("desktop readiness failed: {0} ({1})" -f $reason, $detail)) | Out-Null
        }
      }
    }
  } catch {
    $winAppCapabilityIssues.Add(("ensure_winapp.ps1 执行失败: {0}" -f $_.Exception.Message)) | Out-Null
  }
}

if ($winAppCapabilityIssues.Count -gt 0) {
  Add-Result -Results $results -Name 'Windows桌面自动化能力' -Status FAIL -Detail ($winAppCapabilityIssues -join ' | ') -Action '执行 ./.Rayman/rayman.ps1 ensure-winapp 并修复 UIAutomation 环境'
} else {
  Add-Result -Results $results -Name 'Windows桌面自动化能力' -Status $winAppCapabilityStatus -Detail $winAppCapabilityDetail -Action $(if ($winAppCapabilityStatus -eq 'WARN') { '在 Windows 交互式桌面中执行 ./.Rayman/rayman.ps1 ensure-winapp 复核' } else { '' })
}

# 9) DotNet 执行摘要字段契约（run_tests_and_fix）
$dotnetSummaryContractIssues = New-Object System.Collections.Generic.List[string]
$testFixScriptPath = Join-Path $raymanDir 'scripts\repair\run_tests_and_fix.ps1'
if (-not (Test-Path -LiteralPath $testFixScriptPath -PathType Leaf)) {
  $dotnetSummaryContractIssues.Add(("missing: {0}" -f $testFixScriptPath)) | Out-Null
} else {
  $testFixRaw = Get-Content -LiteralPath $testFixScriptPath -Raw -Encoding UTF8
  $requiredSummaryTokens = @(
    "schema = 'rayman.dotnet.exec.v1'"
    "selected_host = ''"
    "fallback_host = ''"
    'final_exit_code = 1'
    'windows_exit_code = $null'
    'wsl_exit_code = $null'
    'windows_timed_out = $false'
    "windows_error_message = ''"
    "windows_invoked_via = ''"
    "windows_workspace = ''"
    'detail_log = $script:DotNetExecDetailPath'
  )
  foreach ($token in $requiredSummaryTokens) {
    if ($testFixRaw -notmatch [regex]::Escape($token)) {
      $dotnetSummaryContractIssues.Add(("run_tests_and_fix.ps1 缺少摘要字段标记: {0}" -f $token)) | Out-Null
    }
  }
}

if ($dotnetSummaryContractIssues.Count -eq 0) {
  Add-Result -Results $results -Name 'DotNet摘要字段契约' -Status PASS -Detail 'run_tests_and_fix.ps1 保留了 dotnet.exec 摘要字段'
} else {
  Add-Result -Results $results -Name 'DotNet摘要字段契约' -Status FAIL -Detail ($dotnetSummaryContractIssues -join ' | ') -Action '恢复 dotnet.exec.last.json 的结构化字段并重试'
}

# 9.1) Agent 路由与首轮通过率契约
$agentContractIssues = New-Object System.Collections.Generic.List[string]
$raymanCliPath = Join-Path $raymanDir 'rayman.ps1'
$dispatchPath = Join-Path $raymanDir 'scripts\agents\dispatch.ps1'
$agentContractCheckPath = Join-Path $raymanDir 'scripts\agents\check_agent_contract.ps1'
$reviewLoopPath = Join-Path $raymanDir 'scripts\agents\review_loop.ps1'
$firstPassPath = Join-Path $raymanDir 'scripts\agents\first_pass_report.ps1'
$agenticPipelinePath = Join-Path $raymanDir 'scripts\agents\agentic_pipeline.ps1'
$promptCatalogPath = Join-Path $raymanDir 'scripts\agents\prompts_catalog.ps1'
$winAppEnsureScriptPath = Join-Path $raymanDir 'scripts\windows\ensure_winapp.ps1'
$winAppFlowScriptPath = Join-Path $raymanDir 'scripts\windows\run_winapp_flow.ps1'
$winAppInspectScriptPath = Join-Path $raymanDir 'scripts\windows\inspect_winapp.ps1'
$winAppMcpScriptPath = Join-Path $raymanDir 'scripts\windows\winapp_mcp_server.ps1'
$winAppSampleFlowPath = Join-Path $raymanDir 'winapp.flow.sample.json'
$routerCfgPath = Join-Path $raymanDir 'config\agent_router.json'
$policyCfgPath = Join-Path $raymanDir 'config\agent_policy.json'
$reviewCfgPath = Join-Path $raymanDir 'config\review_loop.json'
$agenticCfgPath = Join-Path $raymanDir 'config\agentic_pipeline.json'

foreach ($p in @($dispatchPath, $agentContractCheckPath, $reviewLoopPath, $firstPassPath, $agenticPipelinePath, $promptCatalogPath, $winAppEnsureScriptPath, $winAppFlowScriptPath, $winAppInspectScriptPath, $winAppMcpScriptPath, $winAppSampleFlowPath, $routerCfgPath, $policyCfgPath, $reviewCfgPath, $agenticCfgPath)) {
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
    $agentContractIssues.Add(("missing: {0}" -f $p)) | Out-Null
  }
}

if (Test-Path -LiteralPath $raymanCliPath -PathType Leaf) {
  $raymanRaw = Get-Content -LiteralPath $raymanCliPath -Raw -Encoding UTF8
  foreach ($token in @('"agent-contract"', '"agent-capabilities"', '"ensure-winapp"', '"winapp-test"', '"winapp-inspect"', '"dispatch"', '"review-loop"', '"first-pass-report"', '"prompts"')) {
    if ($raymanRaw -notmatch [regex]::Escape($token)) {
      $agentContractIssues.Add(("rayman.ps1 未暴露命令: {0}" -f $token)) | Out-Null
    }
  }
} else {
  $agentContractIssues.Add(("missing: {0}" -f $raymanCliPath)) | Out-Null
}

if (Test-Path -LiteralPath $dispatchPath -PathType Leaf) {
  $dispatchRaw = Get-Content -LiteralPath $dispatchPath -Raw -Encoding UTF8
  foreach ($token in @('RAYMAN_AGENT_POLICY_BYPASS', 'RAYMAN_BYPASS_REASON', 'policy_bypassed', 'agent-pre-dispatch', 'planner_v1', 'agentic_plan', 'agentic_tool_policy', 'agentic_doc_gate', 'agentic_execution')) {
    if ($dispatchRaw -notmatch [regex]::Escape($token)) {
      $agentContractIssues.Add(("dispatch.ps1 缺少 agent/policy 标记: {0}" -f $token)) | Out-Null
    }
  }
}

if (Test-Path -LiteralPath $agenticPipelinePath -PathType Leaf) {
  $agenticHelperRaw = Get-Content -LiteralPath $agenticPipelinePath -Raw -Encoding UTF8
  foreach ($token in @('rayman.agentic.execution_contract.v1', 'delegation_required', 'local_fallback_command', 'optional_requests', 'prepare_results')) {
    if ($agenticHelperRaw -notmatch [regex]::Escape($token)) {
      $agentContractIssues.Add(("agentic_pipeline.ps1 缺少 execution-contract 标记: {0}" -f $token)) | Out-Null
    }
  }
}

if (Test-Path -LiteralPath $agentContractCheckPath -PathType Leaf) {
  try {
    $null = & $agentContractCheckPath -WorkspaceRoot $WorkspaceRoot -AsJson
    $agentCheckExitCode = 0
    if (Test-Path variable:LASTEXITCODE) {
      $agentCheckExitCode = [int]$LASTEXITCODE
    } elseif (-not $?) {
      $agentCheckExitCode = 1
    }
    if ($agentCheckExitCode -ne 0) {
      $agentContractIssues.Add(("check_agent_contract.ps1 返回非零退出码: {0}" -f $agentCheckExitCode)) | Out-Null
    }
  } catch {
    $agentContractIssues.Add(("check_agent_contract.ps1 执行失败: {0}" -f $_.Exception.Message)) | Out-Null
  }
}

if (Test-Path -LiteralPath $reviewLoopPath -PathType Leaf) {
  $reviewRaw = Get-Content -LiteralPath $reviewLoopPath -Raw -Encoding UTF8
  foreach ($token in @('Get-SnapshotDiffSummary', 'diff_summary', 'review_loop.last.diff.md', 'agentic_reflection', 'reflection_outcome', 'doc_gate_pass', 'acceptance_closed')) {
    if ($reviewRaw -notmatch [regex]::Escape($token)) {
      $agentContractIssues.Add(("review_loop.ps1 缺少 diff/agentic 标记: {0}" -f $token)) | Out-Null
    }
  }
}

if (Test-Path -LiteralPath $firstPassPath -PathType Leaf) {
  $firstPassRaw = Get-Content -LiteralPath $firstPassPath -Raw -Encoding UTF8
  foreach ($token in @('Change-Scale Correlation (Round 1)', 'change_scale_correlation', 'round1_touched_files', 'round1_abs_net_size_delta_bytes', 'Planner / Reflection', 'reflection_distribution', 'selected_tool_distribution')) {
    if ($firstPassRaw -notmatch [regex]::Escape($token)) {
      $agentContractIssues.Add(("first_pass_report.ps1 缺少 telemetry/agentic 标记: {0}" -f $token)) | Out-Null
    }
  }
}

if ($agentContractIssues.Count -eq 0) {
  Add-Result -Results $results -Name 'Agent路由/首轮通过率契约' -Status PASS -Detail 'dispatch/review-loop/first-pass-report/prompts 与配置均存在'
} else {
  Add-Result -Results $results -Name 'Agent路由/首轮通过率契约' -Status FAIL -Detail ($agentContractIssues -join ' | ') -Action '补齐 agent 脚本、配置与 CLI 暴露'
}

# 9.2) 单仓库增强风险快照（可观测，不阻断；project 模式按 PASS 记录）
$singleRepoRiskPath = Join-Path $runtimeDir 'single_repo_upgrade\last.json'
if (-not (Test-Path -LiteralPath $singleRepoRiskPath -PathType Leaf)) {
  if ($Mode -eq 'project') {
    Add-Result -Results $results -Name '单仓库增强风险快照' -Status PASS -Detail '未发现 single_repo_upgrade 最近快照（project 模式观测项，按 PASS 处理）' -Action '建议执行 rayman single-repo-upgrade 生成风险与质量快照'
  } else {
    Add-Result -Results $results -Name '单仓库增强风险快照' -Status WARN -Detail '未发现 single_repo_upgrade 最近快照' -Action '执行 rayman single-repo-upgrade 生成风险与质量快照'
  }
} else {
  try {
    $sr = Get-Content -LiteralPath $singleRepoRiskPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $riskLevel = [string]$sr.risk_level
    if ([string]::IsNullOrWhiteSpace($riskLevel)) { $riskLevel = 'unknown' }
    $riskScore = 0
    if ($null -ne $sr.PSObject.Properties['risk_score']) { $riskScore = [int]$sr.risk_score }
    $overallSr = [string]$sr.overall
    if ([string]::IsNullOrWhiteSpace($overallSr)) { $overallSr = 'unknown' }
    $reviewSuccessSr = $false
    if ($null -ne $sr.PSObject.Properties['review_success']) { $reviewSuccessSr = [bool]$sr.review_success }
    $circuitTripSr = $false
    if ($null -ne $sr.PSObject.Properties['circuit_breaker_tripped']) { $circuitTripSr = [bool]$sr.circuit_breaker_tripped }
    $approvedHighRisk = $false
    if ($null -ne $sr.PSObject.Properties['high_risk_approved']) { $approvedHighRisk = [bool]$sr.high_risk_approved }

    $detailText = "risk={0}({1}), overall={2}, review_success={3}, circuit_trip={4}" -f $riskLevel, $riskScore, $overallSr, $reviewSuccessSr, $circuitTripSr
    if ($riskLevel -eq 'high' -and -not $approvedHighRisk) {
      if ($Mode -eq 'project') {
        Add-Result -Results $results -Name '单仓库增强风险快照' -Status PASS -Detail ("project 模式观测项：{0}" -f $detailText) -Action '高风险改动建议使用 --RiskMode strict 并显式 --ApproveHighRisk'
      } else {
        Add-Result -Results $results -Name '单仓库增强风险快照' -Status WARN -Detail $detailText -Action '高风险改动建议使用 --RiskMode strict 并显式 --ApproveHighRisk'
      }
    } else {
      Add-Result -Results $results -Name '单仓库增强风险快照' -Status PASS -Detail $detailText
    }
  } catch {
    if ($Mode -eq 'project') {
      Add-Result -Results $results -Name '单仓库增强风险快照' -Status PASS -Detail ("project 模式观测项（快照解析失败）: {0}" -f $_.Exception.Message) -Action '建议重新执行 rayman single-repo-upgrade 并检查 JSON 输出'
    } else {
      Add-Result -Results $results -Name '单仓库增强风险快照' -Status WARN -Detail ("single_repo_upgrade 快照解析失败: {0}" -f $_.Exception.Message) -Action '重新执行 rayman single-repo-upgrade 并检查 JSON 输出'
    }
  }
}

# 9.3) 自动化测试 Lane 结果消费
$testLaneDir = Join-Path $runtimeDir 'test_lanes'
$laneDefinitions = @(
  [pscustomobject]@{
    Name = '宿主环境冒烟'
    FileName = 'host_smoke.report.json'
    Schema = 'rayman.testing.host_smoke.v1'
    SuccessProperty = ''
    OverallProperty = 'overall'
    RequireGeneratedAt = $true
    FreshnessPaths = @(
      '.Rayman/scripts/testing'
      '.Rayman/scripts/worker'
      '.Rayman/rayman.ps1'
    )
    MissingInProject = 'WARN'
    MissingInStandard = 'WARN'
    FailInProject = 'WARN'
    FailInStandard = 'FAIL'
    WarnInProject = 'WARN'
    WarnInStandard = 'WARN'
    Action = '执行 pwsh -NoProfile -ExecutionPolicy Bypass -File ./.Rayman/scripts/testing/run_host_smoke.ps1 -WorkspaceRoot "$PWD"'
    AutoRefreshInProject = $true
    AutoRefreshInStandard = $true
  }
  [pscustomobject]@{
    Name = '快速契约Lane'
    FileName = 'fast_contract.report.json'
    Schema = 'rayman.testing.fast_contract.v1'
    SuccessProperty = 'success'
    OverallProperty = ''
    RequireGeneratedAt = $true
    FreshnessPaths = @(
      '.Rayman/scripts/testing/run_fast_contract.sh'
      '.Rayman/scripts/testing'
      '.Rayman/rayman.ps1'
    )
    MissingInProject = 'WARN'
    MissingInStandard = 'FAIL'
    FailInProject = 'FAIL'
    FailInStandard = 'FAIL'
    WarnInProject = 'WARN'
    WarnInStandard = 'WARN'
    Action = '执行 bash ./.Rayman/scripts/testing/run_fast_contract.sh'
    AutoRefreshInProject = $true
    AutoRefreshInStandard = $true
  }
  [pscustomobject]@{
    Name = 'PowerShell逻辑单测'
    FileName = 'pester.report.json'
    Schema = 'rayman.testing.pester.v1'
    SuccessProperty = 'success'
    OverallProperty = ''
    MissingInProject = 'WARN'
    MissingInStandard = 'WARN'
    FailInProject = 'FAIL'
    FailInStandard = 'FAIL'
    WarnInProject = 'WARN'
    WarnInStandard = 'WARN'
    Action = '执行 pwsh -NoProfile -ExecutionPolicy Bypass -File ./.Rayman/scripts/testing/run_pester_tests.ps1 -WorkspaceRoot "$PWD"'
  }
  [pscustomobject]@{
    Name = 'Bash逻辑单测'
    FileName = 'bats.report.json'
    Schema = 'rayman.testing.bats.v1'
    SuccessProperty = 'success'
    OverallProperty = ''
    MissingInProject = 'WARN'
    MissingInStandard = 'WARN'
    FailInProject = 'FAIL'
    FailInStandard = 'FAIL'
    WarnInProject = 'WARN'
    WarnInStandard = 'WARN'
    Action = '执行 bash ./.Rayman/scripts/testing/run_bats_tests.sh'
  }
)
foreach ($lane in $laneDefinitions) {
  $laneReportPath = Join-Path $testLaneDir ([string]$lane.FileName)
  $laneReportRel = Get-DisplayRelativePath -BasePath $WorkspaceRoot -FullPath $laneReportPath
  $initialLaneSnapshot = Get-ReleaseGateSnapshotFromMap -SnapshotMap $initialTestLaneSnapshots -ReportPath $laneReportPath
  $autoRunAttempt = $null
  $shouldAutoRunLane = Get-ReleaseGateAutoRefreshEnabled -Definition $lane -Mode $Mode
  if (-not (Test-Path -LiteralPath $laneReportPath -PathType Leaf)) {
    if ($shouldAutoRunLane) {
      $autoRunAttempt = Invoke-ReleaseGateLaneAutoRun -WorkspaceRoot $WorkspaceRoot -Action ([string]$lane.Action)
    }
  }

  if (-not (Test-Path -LiteralPath $laneReportPath -PathType Leaf)) {
    $missingStatus = if ($Mode -eq 'project') { [string]$lane.MissingInProject } else { [string]$lane.MissingInStandard }
    $detail = ("缺少测试报告: {0}" -f $laneReportRel)
    $action = [string]$lane.Action
    if ($null -ne $autoRunAttempt -and [bool]$autoRunAttempt.attempted) {
      $detail = ("{0}; auto_run=attempted; started={1}; exit={2}; reason={3}" -f $detail, [string]([bool]$autoRunAttempt.started).ToString().ToLowerInvariant(), [int]$autoRunAttempt.exit_code, [string]$autoRunAttempt.reason)
      $action = ("自动补跑已尝试；若仍失败，请手工执行 {0}" -f [string]$lane.Action)
    }
    Add-Result -Results $results -Name ([string]$lane.Name) -Status $missingStatus -Detail $detail -Action $action
    continue
  }

  $laneReport = Get-JsonOrNull -Path $laneReportPath
  $laneEvalArgs = @{
    Report = $laneReport
    ExpectedSchema = [string]$lane.Schema
    SuccessProperty = [string]$lane.SuccessProperty
    OverallProperty = [string]$lane.OverallProperty
    WorkspaceRoot = $WorkspaceRoot
    ReportPath = $laneReportPath
  }
  if ($lane.PSObject.Properties['FreshnessPaths']) {
    $laneEvalArgs['FreshnessPaths'] = @($lane.FreshnessPaths)
  }
  if ($lane.PSObject.Properties['RequireGeneratedAt']) {
    $laneEvalArgs['RequireGeneratedAt'] = [bool]$lane.RequireGeneratedAt
  }
  $laneEval = Get-TestLaneReportEvaluation @laneEvalArgs
  if ($shouldAutoRunLane -and [string]$laneEval.status -eq 'STALE') {
    $autoRunAttempt = Invoke-ReleaseGateLaneAutoRun -WorkspaceRoot $WorkspaceRoot -Action ([string]$lane.Action)
    if ($null -ne $autoRunAttempt -and [bool]$autoRunAttempt.attempted -and (Test-Path -LiteralPath $laneReportPath -PathType Leaf)) {
      $laneReport = Get-JsonOrNull -Path $laneReportPath
      $laneEvalArgs['Report'] = $laneReport
      $laneEval = Get-TestLaneReportEvaluation @laneEvalArgs
    } elseif ($null -ne $autoRunAttempt -and [bool]$autoRunAttempt.attempted) {
      $laneEval = [pscustomobject]@{
        status = 'FAIL'
        detail = ("auto_run_missing_report_after_attempt:{0}" -f [string]$laneReportRel)
      }
    }
  }
  if ([string]$lane.Name -eq 'Bash逻辑单测' -and [string]$laneEval.status -eq 'FAIL' -and $null -ne $laneReport) {
    $laneReason = [string](Get-PropValue -Object $laneReport -Name 'reason' -Default '')
    $laneExitCode = [string](Get-PropValue -Object $laneReport -Name 'exit_code' -Default '')
    if ($laneReason -eq 'tool_missing' -or $laneExitCode -eq '2') {
      $laneEval = [pscustomobject]@{
        status = 'WARN'
        detail = 'bats not installed on current host'
      }
    }
  }

  $detailParts = New-Object System.Collections.Generic.List[string]
  $detailParts.Add([string]$laneEval.detail) | Out-Null
  if ($null -ne $laneReport) {
    $generatedAt = [string](Get-PropValue -Object $laneReport -Name 'generated_at' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($generatedAt)) {
      $detailParts.Add(("generated_at={0}" -f $generatedAt)) | Out-Null
    }
    $counts = Get-PropValue -Object $laneReport -Name 'counts' -Default $null
    if ($null -ne $counts) {
      $countTokens = New-Object System.Collections.Generic.List[string]
      foreach ($countName in @('pass', 'warn', 'fail', 'skip')) {
        $countValue = Get-PropValue -Object $counts -Name $countName -Default $null
        if ($null -ne $countValue -and [string]$countValue -ne '') {
          $countTokens.Add(("{0}={1}" -f $countName, $countValue)) | Out-Null
        }
      }
      foreach ($countName in @('total', 'passed', 'failed', 'skipped', 'inconclusive')) {
        $countValue = Get-PropValue -Object $laneReport -Name $countName -Default $null
        if ($null -ne $countValue -and [string]$countValue -ne '') {
          $countTokens.Add(("{0}={1}" -f $countName, $countValue)) | Out-Null
        }
      }
      if ($countTokens.Count -gt 0) {
        $detailParts.Add(($countTokens -join ', ')) | Out-Null
      }
    }
  }
  $detailParts.Add(("report={0}" -f $laneReportRel)) | Out-Null
  if ($null -ne $autoRunAttempt -and [bool]$autoRunAttempt.attempted) {
    $detailParts.Add(("auto_run=attempted, started={0}, exit={1}, reason={2}" -f [string]([bool]$autoRunAttempt.started).ToString().ToLowerInvariant(), [int]$autoRunAttempt.exit_code, [string]$autoRunAttempt.reason)) | Out-Null
    $detailParts.Add(("auto_refresh={0}" -f (Get-ReleaseGateAutoRefreshStateText -Attempt $autoRunAttempt -EvaluationStatus ([string]$laneEval.status) -ReportExists (Test-Path -LiteralPath $laneReportPath -PathType Leaf)))) | Out-Null
  } else {
    $observedAutoRefreshState = Get-ReleaseGateObservedAutoRefreshStateText -InitialSnapshot $initialLaneSnapshot -CurrentSnapshot (Get-ReleaseGateReportSnapshot -ReportPath $laneReportPath) -EvaluationStatus ([string]$laneEval.status) -GateStartedAt $releaseGateStartedAt
    if (-not [string]::IsNullOrWhiteSpace($observedAutoRefreshState)) {
      $detailParts.Add(("auto_refresh={0}" -f $observedAutoRefreshState)) | Out-Null
    }
  }
  $laneDetail = ($detailParts -join '; ')

  switch ([string]$laneEval.status) {
    'PASS' {
      Add-Result -Results $results -Name ([string]$lane.Name) -Status PASS -Detail $laneDetail
    }
    'WARN' {
      $warnStatus = if ($Mode -eq 'project') { [string]$lane.WarnInProject } else { [string]$lane.WarnInStandard }
      Add-Result -Results $results -Name ([string]$lane.Name) -Status $warnStatus -Detail $laneDetail -Action ([string]$lane.Action)
    }
    'STALE' {
      $staleStatus = if ($Mode -eq 'project') { [string]$lane.MissingInProject } else { [string]$lane.MissingInStandard }
      Add-Result -Results $results -Name ([string]$lane.Name) -Status $staleStatus -Detail $laneDetail -Action ([string]$lane.Action)
    }
    'FAIL' {
      $failStatus = if ($Mode -eq 'project') { [string]$lane.FailInProject } else { [string]$lane.FailInStandard }
      Add-Result -Results $results -Name ([string]$lane.Name) -Status $failStatus -Detail $laneDetail -Action ([string]$lane.Action)
    }
    default {
      Add-Result -Results $results -Name ([string]$lane.Name) -Status FAIL -Detail $laneDetail -Action ([string]$lane.Action)
    }
  }
}

# 9.4) 项目工作流 Lane 结果消费
$projectGateDir = Join-Path $runtimeDir 'project_gates'
$projectGateDefinitions = @(
  [pscustomobject]@{
    Name = '项目快速门禁'
    FileName = 'fast.report.json'
    Schema = 'rayman.project_gate.v1'
    RequireGeneratedAt = $true
    FreshnessPaths = @(
      '.rayman.project.json'
      '.Rayman/scripts/project'
      '.Rayman/scripts/utils'
      '.Rayman/scripts/ci/validate_requirements.sh'
      '.Rayman/scripts/release/config_sanity.sh'
      '.Rayman/runtime/project_gates/logs/fast.*.log'
    )
    MissingInProject = 'WARN'
    MissingInStandard = 'WARN'
    FailInProject = 'FAIL'
    FailInStandard = 'FAIL'
    WarnInProject = 'WARN'
    WarnInStandard = 'WARN'
    Action = '执行 .\.Rayman\rayman.ps1 fast-gate'
    AutoRefreshInProject = $true
    AutoRefreshInStandard = $true
  }
  [pscustomobject]@{
    Name = '项目浏览器门禁'
    FileName = 'browser.report.json'
    Schema = 'rayman.project_gate.v1'
    RequireGeneratedAt = $true
    FreshnessPaths = @(
      '.rayman.project.json'
      '.Rayman/scripts/project'
      '.Rayman/scripts/utils'
      '.Rayman/scripts/pwa'
      '.Rayman/scripts/windows'
      '.Rayman/runtime/project_gates/logs/browser.*.log'
    )
    MissingInProject = 'WARN'
    MissingInStandard = 'WARN'
    FailInProject = 'FAIL'
    FailInStandard = 'FAIL'
    WarnInProject = 'WARN'
    WarnInStandard = 'WARN'
    Action = '执行 .\.Rayman\rayman.ps1 browser-gate'
    AutoRefreshInProject = $true
    AutoRefreshInStandard = $true
  }
)
foreach ($lane in $projectGateDefinitions) {
  $laneReportPath = Join-Path $projectGateDir ([string]$lane.FileName)
  $laneReportRel = Get-DisplayRelativePath -BasePath $WorkspaceRoot -FullPath $laneReportPath
  $initialLaneSnapshot = Get-ReleaseGateSnapshotFromMap -SnapshotMap $initialProjectGateSnapshots -ReportPath $laneReportPath
  $autoRunAttempt = $null
  $shouldAutoRunLane = Get-ReleaseGateAutoRefreshEnabled -Definition $lane -Mode $Mode
  if (-not (Test-Path -LiteralPath $laneReportPath -PathType Leaf)) {
    if ($shouldAutoRunLane) {
      $autoRunAttempt = Invoke-ReleaseGateLaneAutoRun -WorkspaceRoot $WorkspaceRoot -Action ([string]$lane.Action)
    }
  }

  if (-not (Test-Path -LiteralPath $laneReportPath -PathType Leaf)) {
    $missingStatus = if ($Mode -eq 'project') { [string]$lane.MissingInProject } else { [string]$lane.MissingInStandard }
    $detail = ("缺少项目 gate 报告: {0}" -f $laneReportRel)
    $action = [string]$lane.Action
    if ($null -ne $autoRunAttempt -and [bool]$autoRunAttempt.attempted) {
      $detail = ("{0}; auto_run=attempted; started={1}; exit={2}; reason={3}; auto_refresh=still_stale_after_refresh" -f $detail, [string]([bool]$autoRunAttempt.started).ToString().ToLowerInvariant(), [int]$autoRunAttempt.exit_code, [string]$autoRunAttempt.reason)
      $action = ("自动补跑已尝试；若仍失败，请手工执行 {0}" -f [string]$lane.Action)
    }
    Add-Result -Results $results -Name ([string]$lane.Name) -Status $missingStatus -Detail $detail -Action $action
    continue
  }

  $laneReport = Get-JsonOrNull -Path $laneReportPath
  $laneEvalArgs = @{
    Report = $laneReport
    ExpectedSchema = [string]$lane.Schema
    SuccessProperty = ''
    OverallProperty = 'overall'
    WorkspaceRoot = $WorkspaceRoot
    ReportPath = $laneReportPath
  }
  if ($lane.PSObject.Properties['FreshnessPaths']) {
    $laneEvalArgs['FreshnessPaths'] = @($lane.FreshnessPaths)
  }
  if ($lane.PSObject.Properties['RequireGeneratedAt']) {
    $laneEvalArgs['RequireGeneratedAt'] = [bool]$lane.RequireGeneratedAt
  }
  $laneEval = Get-TestLaneReportEvaluation @laneEvalArgs
  if ($shouldAutoRunLane -and [string]$laneEval.status -eq 'STALE') {
    $autoRunAttempt = Invoke-ReleaseGateLaneAutoRun -WorkspaceRoot $WorkspaceRoot -Action ([string]$lane.Action)
    if ($null -ne $autoRunAttempt -and [bool]$autoRunAttempt.attempted -and (Test-Path -LiteralPath $laneReportPath -PathType Leaf)) {
      $laneReport = Get-JsonOrNull -Path $laneReportPath
      $laneEvalArgs['Report'] = $laneReport
      $laneEval = Get-TestLaneReportEvaluation @laneEvalArgs
    } elseif ($null -ne $autoRunAttempt -and [bool]$autoRunAttempt.attempted) {
      $laneEval = [pscustomobject]@{
        status = 'STALE'
        detail = 'stale_report_missing_after_auto_refresh'
      }
    }
  }
  $detailParts = New-Object System.Collections.Generic.List[string]
  $detailParts.Add([string]$laneEval.detail) | Out-Null
  if ($null -ne $laneReport) {
    $generatedAt = [string](Get-PropValue -Object $laneReport -Name 'generated_at' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($generatedAt)) {
      $detailParts.Add(("generated_at={0}" -f $generatedAt)) | Out-Null
    }
    $counts = Get-PropValue -Object $laneReport -Name 'counts' -Default $null
    if ($null -ne $counts) {
      $countTokens = New-Object System.Collections.Generic.List[string]
      foreach ($countName in @('pass', 'warn', 'fail', 'skip', 'total')) {
        $countValue = Get-PropValue -Object $counts -Name $countName -Default $null
        if ($null -ne $countValue -and [string]$countValue -ne '') {
          $countTokens.Add(("{0}={1}" -f $countName, $countValue)) | Out-Null
        }
      }
      if ($countTokens.Count -gt 0) {
        $detailParts.Add(($countTokens -join ', ')) | Out-Null
      }
    }
  }
  $detailParts.Add(("report={0}" -f $laneReportRel)) | Out-Null
  if ($null -ne $autoRunAttempt -and [bool]$autoRunAttempt.attempted) {
    $detailParts.Add(("auto_run=attempted, started={0}, exit={1}, reason={2}" -f [string]([bool]$autoRunAttempt.started).ToString().ToLowerInvariant(), [int]$autoRunAttempt.exit_code, [string]$autoRunAttempt.reason)) | Out-Null
    $detailParts.Add(("auto_refresh={0}" -f (Get-ReleaseGateAutoRefreshStateText -Attempt $autoRunAttempt -EvaluationStatus ([string]$laneEval.status) -ReportExists (Test-Path -LiteralPath $laneReportPath -PathType Leaf)))) | Out-Null
  } else {
    $observedAutoRefreshState = Get-ReleaseGateObservedAutoRefreshStateText -InitialSnapshot $initialLaneSnapshot -CurrentSnapshot (Get-ReleaseGateReportSnapshot -ReportPath $laneReportPath) -EvaluationStatus ([string]$laneEval.status) -GateStartedAt $releaseGateStartedAt
    if (-not [string]::IsNullOrWhiteSpace($observedAutoRefreshState)) {
      $detailParts.Add(("auto_refresh={0}" -f $observedAutoRefreshState)) | Out-Null
    }
  }
  $laneDetail = ($detailParts -join '; ')

  switch ([string]$laneEval.status) {
    'PASS' {
      Add-Result -Results $results -Name ([string]$lane.Name) -Status PASS -Detail $laneDetail
    }
    'WARN' {
      $warnStatus = if ($Mode -eq 'project') { [string]$lane.WarnInProject } else { [string]$lane.WarnInStandard }
      Add-Result -Results $results -Name ([string]$lane.Name) -Status $warnStatus -Detail $laneDetail -Action ([string]$lane.Action)
    }
    'STALE' {
      $staleStatus = if ($Mode -eq 'project') { [string]$lane.MissingInProject } else { [string]$lane.MissingInStandard }
      Add-Result -Results $results -Name ([string]$lane.Name) -Status $staleStatus -Detail $laneDetail -Action ([string]$lane.Action)
    }
    'FAIL' {
      $failStatus = if ($Mode -eq 'project') { [string]$lane.FailInProject } else { [string]$lane.FailInStandard }
      Add-Result -Results $results -Name ([string]$lane.Name) -Status $failStatus -Detail $laneDetail -Action ([string]$lane.Action)
    }
    default {
      Add-Result -Results $results -Name ([string]$lane.Name) -Status FAIL -Detail $laneDetail -Action ([string]$lane.Action)
    }
  }
}

# 10) Agent Memory 检索有效
$memoryManageScript = Join-Path $raymanDir 'scripts\memory\manage_memory.ps1'
$memoryBootstrapScript = Join-Path $raymanDir 'scripts\memory\memory_bootstrap.ps1'
$memoryBackendScript = Join-Path $raymanDir 'scripts\memory\manage_memory.py'
$memoryReq = Join-Path $raymanDir 'scripts\memory\requirements.txt'

$memoryWarn = @()
if (-not (Test-Path -LiteralPath $memoryManageScript -PathType Leaf)) { $memoryWarn += 'manage_memory.ps1 缺失' }
if (-not (Test-Path -LiteralPath $memoryBootstrapScript -PathType Leaf)) { $memoryWarn += 'memory_bootstrap.ps1 缺失' }
if (-not (Test-Path -LiteralPath $memoryBackendScript -PathType Leaf)) { $memoryWarn += 'manage_memory.py 缺失' }
if (-not (Test-Path -LiteralPath $memoryReq -PathType Leaf)) { $memoryWarn += 'requirements.txt 缺失' }

$memoryOk = $false
$memoryRuntimeText = ''
if ($memoryWarn.Count -eq 0) {
  try {
    $bootstrapRaw = & $memoryBootstrapScript -WorkspaceRoot $WorkspaceRoot -Action probe -Json
    $bootstrapText = ($bootstrapRaw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    $bootstrapObj = $bootstrapText | ConvertFrom-Json -ErrorAction Stop
    if (-not [bool]$bootstrapObj.Success) {
      $memoryWarn += [string]$bootstrapObj.Message
    } else {
      $memoryRuntimeText = [string]$bootstrapObj.PythonLabel
      $searchRaw = & $memoryManageScript -WorkspaceRoot $WorkspaceRoot -Action search -Query 'release requirements' -Json
      $searchText = ($searchRaw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
      $searchObj = $searchText | ConvertFrom-Json -ErrorAction Stop
      if ([bool]$searchObj.success) {
        $memoryOk = $true
        if (-not [string]::IsNullOrWhiteSpace([string]$searchObj.search_backend)) {
          $memoryRuntimeText = ("{0}; backend={1}" -f $memoryRuntimeText, [string]$searchObj.search_backend).Trim('; ')
        }
      } else {
        $memoryWarn += 'Agent Memory search 返回失败状态'
      }
    }
  } catch {
    $memoryWarn += ("Agent Memory 检索执行失败: {0}" -f $_.Exception.Message)
  }
}

if ($memoryOk -and $memoryWarn.Count -eq 0) {
  $detail = if ([string]::IsNullOrWhiteSpace($memoryRuntimeText)) { 'Agent Memory search 正常' } else { "Agent Memory search 正常（$memoryRuntimeText）" }
  Add-Result -Results $results -Name 'Agent Memory 检索有效' -Status PASS -Detail $detail
} else {
  $detail = if ($memoryWarn.Count -gt 0) { $memoryWarn -join ' | ' } else { 'Agent Memory 检索未就绪' }
  if ($Mode -eq 'project') {
    Add-Result -Results $results -Name 'Agent Memory 检索有效' -Status PASS -Detail ("project 模式初始化豁免：{0}" -f $detail) -Action '如需严格探活，请执行 ./.Rayman/rayman.ps1 memory-bootstrap 后复检'
  } else {
    Add-Result -Results $results -Name 'Agent Memory 检索有效' -Status FAIL -Detail $detail -Action '执行 ./.Rayman/rayman.ps1 memory-bootstrap 并确认 manage_memory.ps1 可搜索'
  }
}

# 11) 回滚能力
$saveState = Join-Path $raymanDir 'scripts\state\save_state.ps1'
$listState = Join-Path $raymanDir 'scripts\state\list_state.ps1'
$resumeState = Join-Path $raymanDir 'scripts\state\resume_state.ps1'
$worktreeCreate = Join-Path $raymanDir 'scripts\state\worktree_create.ps1'
$sessionCommon = Join-Path $raymanDir 'scripts\state\session_common.ps1'
$cliPath = Join-Path $raymanDir 'rayman.ps1'
$rollbackIssues = @()
if (-not (Test-Path -LiteralPath $saveState -PathType Leaf)) { $rollbackIssues += '缺少 save_state.ps1' }
if (-not (Test-Path -LiteralPath $listState -PathType Leaf)) { $rollbackIssues += '缺少 list_state.ps1' }
if (-not (Test-Path -LiteralPath $resumeState -PathType Leaf)) { $rollbackIssues += '缺少 resume_state.ps1' }
if (-not (Test-Path -LiteralPath $worktreeCreate -PathType Leaf)) { $rollbackIssues += '缺少 worktree_create.ps1' }
if (-not (Test-Path -LiteralPath $sessionCommon -PathType Leaf)) { $rollbackIssues += '缺少 session_common.ps1' }
if (Test-Path -LiteralPath $cliPath -PathType Leaf) {
  $cliRaw = Get-Content -LiteralPath $cliPath -Raw -Encoding UTF8
  if ($cliRaw -notmatch 'state-save') { $rollbackIssues += 'rayman.ps1 未暴露 state-save 命令' }
  if ($cliRaw -notmatch 'state-list') { $rollbackIssues += 'rayman.ps1 未暴露 state-list 命令' }
  if ($cliRaw -notmatch 'state-resume') { $rollbackIssues += 'rayman.ps1 未暴露 state-resume 命令' }
  if ($cliRaw -notmatch 'worktree-create') { $rollbackIssues += 'rayman.ps1 未暴露 worktree-create 命令' }
} else {
  $rollbackIssues += '缺少 rayman.ps1'
}

if ($rollbackIssues.Count -eq 0) {
  Add-Result -Results $results -Name '回滚能力' -Status PASS -Detail '命名会话保存/列出/恢复与 worktree 入口可用'
} else {
  Add-Result -Results $results -Name '回滚能力' -Status FAIL -Detail ($rollbackIssues -join ' | ') -Action '补齐回滚脚本与命令映射'
}

# 11.1) 诊断残留自检（可选，不阻断）
if ($IncludeResidualDiagnostics) {
  $diagScript = Join-Path $raymanDir 'scripts\utils\diagnose_residual_diagnostics.ps1'
  $diagReportJsonPath = Join-Path $raymanDir 'state\diagnostics_residual_report.json'
  if (-not (Test-Path -LiteralPath $diagScript -PathType Leaf)) {
    Add-Result -Results $results -Name '诊断残留自检' -Status WARN -Detail ('缺少脚本: {0}' -f $diagScript) -Action '补齐 diagnose_residual_diagnostics.ps1 后重试'
  } else {
    try {
      $childPs = Resolve-ChildPowerShellHost
      if ([string]::IsNullOrWhiteSpace($childPs)) {
        throw '未找到可用的 PowerShell host（pwsh/powershell.exe）'
      }
      [void](& $childPs -NoProfile -ExecutionPolicy Bypass -File $diagScript -WorkspaceRoot $WorkspaceRoot)

      $diagExit = 0
      if (Test-Path variable:LASTEXITCODE) {
        $diagExit = [int]$LASTEXITCODE
      } elseif (-not $?) {
        $diagExit = 1
      }

      $diagStatus = 'UNKNOWN'
      $diagIssueCount = 0
      if (Test-Path -LiteralPath $diagReportJsonPath -PathType Leaf) {
        try {
          $diagObj = Get-Content -LiteralPath $diagReportJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
          if ($null -ne $diagObj.PSObject.Properties['status']) {
            $diagStatus = [string]$diagObj.status
          }
          if ($null -ne $diagObj.PSObject.Properties['issues']) {
            $diagIssueCount = @($diagObj.issues).Count
          }
          if ($null -ne $diagObj.PSObject.Properties['cache_hint']) {
            $hint = $diagObj.cache_hint
            if ($null -ne $hint -and $null -ne $hint.PSObject.Properties['possible']) {
              $residualCacheHintPossible = [bool]$hint.possible
            }
            if ($null -ne $hint -and $null -ne $hint.PSObject.Properties['message']) {
              $residualCacheHintMessage = [string]$hint.message
            }
            $residualCacheHintEnabled = $true
          }
        } catch {}
      }

      if ($diagExit -eq 0 -and $diagStatus.ToUpperInvariant() -eq 'OK') {
        Add-Result -Results $results -Name '诊断残留自检' -Status PASS -Detail '诊断残留自检通过（source/dist 一致，未发现 legacy 标记）'
      } else {
        Add-Result -Results $results -Name '诊断残留自检' -Status WARN -Detail ("诊断残留自检={0}, issues={1}" -f $diagStatus, $diagIssueCount) -Action '可执行 rayman diagnostics-residual --Json 查看详情'
      }
    } catch {
      Add-Result -Results $results -Name '诊断残留自检' -Status WARN -Detail ("自检执行失败: {0}" -f $_.Exception.Message) -Action '可单独执行 rayman diagnostics-residual --Json 排查'
    }
  }
}

$passCount = @($results | Where-Object { $_.Status -eq 'PASS' }).Count
$warnCount = @($results | Where-Object { $_.Status -eq 'WARN' }).Count
$failCount = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count

$overall = if ($failCount -gt 0) { 'FAIL' } elseif ($warnCount -gt 0) { 'WARN' } else { 'PASS' }

$ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine('# Rayman Release Gate Report')
[void]$md.AppendLine('')
[void]$md.AppendLine(("> 时间：{0}" -f $ts))
[void]$md.AppendLine(("> 结论：**{0}**" -f $overall))
[void]$md.AppendLine(("> 统计：PASS={0}, WARN={1}, FAIL={2}" -f $passCount, $warnCount, $failCount))
[void]$md.AppendLine(("> 模式：{0}" -f $Mode))
[void]$md.AppendLine('')
[void]$md.AppendLine('## 扫描忽略规则摘要')
[void]$md.AppendLine('')
foreach ($rule in $scanIgnoreRules) {
  [void]$md.AppendLine(("- {0}" -f $rule))
}
[void]$md.AppendLine('')
[void]$md.AppendLine('| 检查项 | 状态 | 详情 | 建议动作 |')
[void]$md.AppendLine('|---|---|---|---|')
foreach ($r in $results) {
  $detail = ([string]$r.Detail).Replace('|','\\|')
  $advice = ([string]$r.Action).Replace('|','\\|')
  [void]$md.AppendLine(("| {0} | {1} | {2} | {3} |" -f $r.Name, $r.Status, $detail, $advice))
}

if ($residualCacheHintEnabled) {
  [void]$md.AppendLine('')
  [void]$md.AppendLine('## 诊断缓存提示')
  [void]$md.AppendLine('')
  [void]$md.AppendLine(("- possible: **{0}**" -f $residualCacheHintPossible))
  if (-not [string]::IsNullOrWhiteSpace($residualCacheHintMessage)) {
    [void]$md.AppendLine(("- message: {0}" -f $residualCacheHintMessage))
  }
}

$nonPassResults = @($results | Where-Object { $_.Status -ne 'PASS' })
if ($nonPassResults.Count -gt 0) {
  $quickCommands = New-Object System.Collections.Generic.List[string]
  foreach ($np in $nonPassResults) {
    foreach ($cmd in (Get-QuickFixCommandsForCheck -CheckName ([string]$np.Name))) {
      if (-not [string]::IsNullOrWhiteSpace([string]$cmd) -and ($quickCommands -notcontains [string]$cmd)) {
        $quickCommands.Add([string]$cmd) | Out-Null
      }
    }
  }

  if ($quickCommands.Count -gt 0) {
    [void]$md.AppendLine('')
    [void]$md.AppendLine('## 最短修复命令（按需复制）')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('```powershell')
    foreach ($cmd in $quickCommands) {
      [void]$md.AppendLine($cmd)
    }
    [void]$md.AppendLine('```')
  }
}

if ($legacySnippets.Count -gt 0) {
  [void]$md.AppendLine('')
  [void]$md.AppendLine('## Legacy 命中样本（定位辅助）')
  [void]$md.AppendLine('')
  [void]$md.AppendLine('| 文件 | 行号 | 前一行 | 命中行 | 后一行 |')
  [void]$md.AppendLine('|---|---:|---|---|---|')
  foreach ($s in @($legacySnippets | Select-Object -First 3)) {
    $p = ([string]$s.Prev).Replace('|','\\|')
    $c = ([string]$s.Curr).Replace('|','\\|')
    $n = ([string]$s.Next).Replace('|','\\|')
    [void]$md.AppendLine(("| {0} | {1} | {2} | {3} | {4} |" -f $s.RelPath, $s.Line, $p, $c, $n))
  }
}

$failedResults = @($results | Where-Object { $_.Status -eq 'FAIL' })
if ($failedResults.Count -gt 0) {
  [void]$md.AppendLine('')
  [void]$md.AppendLine('## 失败项修复模板（可直接复制后按需调整）')
  [void]$md.AppendLine('')
  foreach ($fr in $failedResults) {
    [void]$md.AppendLine(("### {0}" -f [string]$fr.Name))
    switch ([string]$fr.Name) {
      '版本一致性' {
        [void]$md.AppendLine('- 同步版本与 marker：运行 `./.Rayman/rayman.ps1 release-gate -Mode project` 验证项目模式。')
        [void]$md.AppendLine('- 清理历史临时目录：`Get-ChildItem -Force -Directory -Filter ".Rayman.stage.*" | Remove-Item -Recurse -Force`')
      }
      'Agent Memory 存储有效' {
        [void]$md.AppendLine('- 清理 legacy 记忆目录残留。')
        [void]$md.AppendLine('- 预热 Agent Memory：`./.Rayman/rayman.ps1 memory-bootstrap`')
      }
      'Agent Memory 检索有效' {
        [void]$md.AppendLine('- 预热 Agent Memory：`./.Rayman/rayman.ps1 memory-bootstrap`')
        [void]$md.AppendLine('- 验证检索：`./.Rayman/rayman.ps1 memory-search -Query "release requirements"`')
      }
      'VSCode任务注册' {
        [void]$md.AppendLine('- 重新生成任务：`./.Rayman/setup.ps1 -SkipReleaseGate`')
      }
      default {
        [void]$md.AppendLine(("- 建议动作：{0}" -f [string]$fr.Action))
      }
    }
    [void]$md.AppendLine('')
  }
}

Set-Content -LiteralPath $ReportPath -Value $md.ToString() -Encoding UTF8

$jsonReportPath = [System.IO.Path]::ChangeExtension([string]$ReportPath, '.json')
if ([string]::IsNullOrWhiteSpace($jsonReportPath)) {
  $jsonReportPath = (Join-Path $reportDir 'release_gate_report.json')
}

$checkItems = @($results | ForEach-Object {
  [pscustomobject]@{
    name = [string]$_.Name
    status = [string]$_.Status
    detail = [string]$_.Detail
    action = [string]$_.Action
  }
})

try {
  $countsObj = New-Object PSObject
  $countsObj | Add-Member -NotePropertyName pass -NotePropertyValue ([int]$passCount)
  $countsObj | Add-Member -NotePropertyName warn -NotePropertyValue ([int]$warnCount)
  $countsObj | Add-Member -NotePropertyName fail -NotePropertyValue ([int]$failCount)

  $optionsObj = New-Object PSObject
  $optionsObj | Add-Member -NotePropertyName allow_no_git -NotePropertyValue ([bool]$allowNoGitEffective)
  $optionsObj | Add-Member -NotePropertyName skip_auto_dist_sync -NotePropertyValue ([bool]$SkipAutoDistSync)
  $optionsObj | Add-Member -NotePropertyName include_residual_diagnostics -NotePropertyValue ([bool]$IncludeResidualDiagnostics)

  $jsonPayload = New-Object PSObject
  $jsonPayload | Add-Member -NotePropertyName schema -NotePropertyValue 'rayman.release_gate.v1'
  $jsonPayload | Add-Member -NotePropertyName generated_at -NotePropertyValue ((Get-Date).ToString('o'))
  $jsonPayload | Add-Member -NotePropertyName workspace_root -NotePropertyValue ([string]$WorkspaceRoot)
  $jsonPayload | Add-Member -NotePropertyName mode -NotePropertyValue ([string]$Mode)
  $jsonPayload | Add-Member -NotePropertyName report_path -NotePropertyValue ([string]$ReportPath)
  $jsonPayload | Add-Member -NotePropertyName overall -NotePropertyValue ([string]$overall)
  $jsonPayload | Add-Member -NotePropertyName counts -NotePropertyValue $countsObj
  $jsonPayload | Add-Member -NotePropertyName options -NotePropertyValue $optionsObj
  if ($IncludeResidualDiagnostics) {
    $cacheHintObj = New-Object PSObject
    $cacheHintObj | Add-Member -NotePropertyName possible -NotePropertyValue ([bool]$residualCacheHintPossible)
    $cacheHintObj | Add-Member -NotePropertyName message -NotePropertyValue ([string]$residualCacheHintMessage)
    $jsonPayload | Add-Member -NotePropertyName diagnostic_cache_hint -NotePropertyValue $cacheHintObj
  }
  $jsonPayload | Add-Member -NotePropertyName checks -NotePropertyValue $checkItems

  $jsonText = $jsonPayload | ConvertTo-Json -Depth 8
  Set-Content -LiteralPath $jsonReportPath -Value $jsonText -Encoding UTF8

  if ($Json) {
    Write-Output $jsonText
  }
} catch {
  Warn ("JSON 报告生成失败: {0}" -f $_.Exception.Message)
  if ($Json) {
    Write-Output ([pscustomobject]@{
      schema = 'rayman.release_gate.v1'
      generated_at = (Get-Date).ToString('o')
      error = [string]$_.Exception.Message
      report_path = [string]$ReportPath
    } | ConvertTo-Json -Depth 5)
  }
}

if (Get-Command Write-RaymanRulesTelemetryRecord -ErrorAction SilentlyContinue) {
  try {
    $releaseGateDurationMs = [int][Math]::Max(0, [Math]::Round(((Get-Date) - $releaseGateStartedAt).TotalMilliseconds))
    $releaseGateExitCode = if ($overall -eq 'FAIL') { 2 } else { 0 }
    Write-RaymanRulesTelemetryRecord -WorkspaceRoot $WorkspaceRoot -Profile 'release-gate' -Stage 'final' -Scope $Mode -Status $overall -ExitCode $releaseGateExitCode -DurationMs $releaseGateDurationMs -Command 'release-gate' | Out-Null
  } catch {}
}

if ($overall -eq 'FAIL') {
  FailMsg ("Release Gate 失败，报告：{0}" -f $ReportPath)
  exit 2
}
if ($overall -eq 'WARN') {
  Warn ("Release Gate 警告通过，报告：{0}" -f $ReportPath)
  exit 0
}

Ok ("Release Gate 通过，报告：{0}" -f $ReportPath)
exit 0
