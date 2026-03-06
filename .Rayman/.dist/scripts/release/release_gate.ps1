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
    'Dist镜像同步' { return @('.\\.Rayman\\rayman.ps1 dist-sync') }
    '版本一致性' { return @('.\\.Rayman\\rayman.ps1 release-gate -Mode project') }
    'RAG路径隔离' { return @('$env:RAYMAN_RAG_ROOT=".rag"', '.\\.Rayman\\rayman.ps1 migrate-rag') }
    'MCP配置可移植性' { return @('.\\.Rayman\\scripts\\mcp\\manage_mcp.ps1 -Action status') }
    'Playwright摘要结构' { return @('.\\.Rayman\\rayman.ps1 ensure-playwright') }
    '依赖自动补全默认项' { return @('.\\.Rayman\\setup.ps1') }
    'MCP/RAG最小可用性' { return @('.\\.Rayman\\scripts\\mcp\\manage_mcp.ps1 -Action start', '.\\.Rayman\\scripts\\rag\\manage_rag.ps1 -Action build') }
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

function Resolve-ChildPowerShellHost {
  $candidates = @('pwsh.exe', 'pwsh', 'powershell.exe', 'powershell')
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
$runtimeDir = Join-Path $raymanDir 'runtime'
if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
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
$expectedTag = 'V159'
$expectedVersion = 'v159'

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
$scanIgnoreRules = @(
  '/\.tmp_sandbox_',
  '/\.rayman\.stage\.',
  '/\.rayman_full_',
  '/rayman_full_bundle/',
  '/\.venv/',
  '/\.git/',
  '/\.rayman/context\.md$',
  '/\.rayman/state/.*\.md$',
  '/\.rayman/state/release_gate_report\.md$',
  '/\.rayman/state/release_gate_report\.json$',
  '/\.rayman/scripts/release/release_gate\.ps1$',
  '/\.rayman/\.dist/scripts/release/release_gate\.ps1$'
)

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
    if ($agentsRaw -notmatch 'RAYMAN:MANDATORY_REQUIREMENTS_V159') {
      $agentsRel = Get-DisplayRelativePath -BasePath $WorkspaceRoot -FullPath $agentsPath
      $versionIssues.Add(("{0} missing V159 marker" -f $agentsRel)) | Out-Null
    }
  }
}

if (-not (Test-Path -LiteralPath $agentsTemplatePath -PathType Leaf)) {
  $versionIssues.Add('missing .Rayman/agents.template.md') | Out-Null
} else {
  $templateRaw = Get-Content -LiteralPath $agentsTemplatePath -Raw -Encoding UTF8
  if ($templateRaw -notmatch 'RAYMAN:MANDATORY_REQUIREMENTS_V159') {
    $versionIssues.Add('.Rayman/agents.template.md missing V159 marker') | Out-Null
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
    $fullNorm = Get-PathComparisonValue $_.FullName
    $ignored = $false
    foreach ($rule in $scanIgnoreRules) {
      if ($fullNorm -match $rule) {
        $ignored = $true
        break
      }
    }
    -not $ignored
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
  '.Rayman/scripts/release/contract_nested_repair.sh',
  '.Rayman/scripts/pwa/ensure_playwright_ready.ps1',
  '.Rayman/scripts/pwa/ensure_playwright_wsl.sh',
  '.Rayman/scripts/rag/manage_rag.ps1',
  '.Rayman/scripts/rag/build_index.py',
  '.Rayman/scripts/mcp/manage_mcp.ps1',
  '.Rayman/scripts/watch/start_background_watchers.ps1',
  '.Rayman/scripts/state/save_state.ps1',
  '.Rayman/scripts/state/resume_state.ps1',
  '.Rayman/scripts/agents/ensure_agent_assets.ps1',
  '.Rayman/scripts/agents/dispatch.ps1',
  '.Rayman/scripts/agents/review_loop.ps1',
  '.Rayman/scripts/agents/first_pass_report.ps1',
  '.Rayman/scripts/agents/prompts_catalog.ps1'
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
      'RAYMAN_RAG_HEARTBEAT_SECONDS',
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
      'Rayman: Check Win Deps',
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

# 5) RAG 路径隔离（必须位于工作区根目录 .rag/<namespace>）
$ragPathIssues = @()
$commonScript = Join-Path $raymanDir 'common.ps1'
$ragPaths = $null
if (-not (Test-Path -LiteralPath $commonScript -PathType Leaf)) {
  $ragPathIssues += 'common.ps1 缺失，无法解析 RAG 路径'
} else {
  try {
    . $commonScript
    $ragPaths = Get-RaymanRagPaths -WorkspaceRoot $WorkspaceRoot
  } catch {
    $ragPathIssues += ("RAG 路径解析失败: {0}" -f $_.Exception.Message)
  }
}

if ($null -ne $ragPaths) {
  $expectedRoot = Get-PathComparisonValue (Join-Path $WorkspaceRoot '.rag')
  $actualRoot = Get-PathComparisonValue ([string]$ragPaths.RagRoot)
  $actualDb = Get-PathComparisonValue ([string]$ragPaths.ChromaDbPath)
  $legacyRoot = Get-PathComparisonValue (Join-Path $WorkspaceRoot '.Rayman/state')

  if ([string]::IsNullOrWhiteSpace([string]$ragPaths.Namespace)) {
    $ragPathIssues += 'RAG namespace 为空'
  }

  if ([string]::IsNullOrWhiteSpace($actualRoot)) {
    $ragPathIssues += 'RagRoot 为空'
  } elseif ($actualRoot -ne $expectedRoot -and -not $actualRoot.StartsWith($expectedRoot + '/')) {
    $ragPathIssues += ("RagRoot 必须位于工作区 .rag 下，当前: {0}" -f $actualRoot)
  }

  if (-not [string]::IsNullOrWhiteSpace($actualDb) -and ($actualDb -eq $legacyRoot -or $actualDb.StartsWith($legacyRoot + '/'))) {
    $ragPathIssues += ("检测到旧路径 .Rayman/state 被用作 RAG 存储: {0}" -f $actualDb)
  }
}

if ($ragPathIssues.Count -eq 0) {
  Add-Result -Results $results -Name 'RAG路径隔离' -Status PASS -Detail ("RAG 路径有效：{0}" -f [string]$ragPaths.ChromaDbPath)
} else {
  Add-Result -Results $results -Name 'RAG路径隔离' -Status FAIL -Detail ($ragPathIssues -join ' | ') -Action '设置 RAYMAN_RAG_ROOT=.rag，并确保 namespace 非空'
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
$reviewLoopPath = Join-Path $raymanDir 'scripts\agents\review_loop.ps1'
$firstPassPath = Join-Path $raymanDir 'scripts\agents\first_pass_report.ps1'
$promptCatalogPath = Join-Path $raymanDir 'scripts\agents\prompts_catalog.ps1'
$routerCfgPath = Join-Path $raymanDir 'config\agent_router.json'
$policyCfgPath = Join-Path $raymanDir 'config\agent_policy.json'
$reviewCfgPath = Join-Path $raymanDir 'config\review_loop.json'

foreach ($p in @($dispatchPath, $reviewLoopPath, $firstPassPath, $promptCatalogPath, $routerCfgPath, $policyCfgPath, $reviewCfgPath)) {
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
    $agentContractIssues.Add(("missing: {0}" -f $p)) | Out-Null
  }
}

if (Test-Path -LiteralPath $raymanCliPath -PathType Leaf) {
  $raymanRaw = Get-Content -LiteralPath $raymanCliPath -Raw -Encoding UTF8
  foreach ($token in @('"dispatch"', '"review-loop"', '"first-pass-report"', '"prompts"')) {
    if ($raymanRaw -notmatch [regex]::Escape($token)) {
      $agentContractIssues.Add(("rayman.ps1 未暴露命令: {0}" -f $token)) | Out-Null
    }
  }
} else {
  $agentContractIssues.Add(("missing: {0}" -f $raymanCliPath)) | Out-Null
}

if (Test-Path -LiteralPath $dispatchPath -PathType Leaf) {
  $dispatchRaw = Get-Content -LiteralPath $dispatchPath -Raw -Encoding UTF8
  foreach ($token in @('RAYMAN_AGENT_POLICY_BYPASS', 'RAYMAN_BYPASS_REASON', 'policy_bypassed', 'agent-pre-dispatch')) {
    if ($dispatchRaw -notmatch [regex]::Escape($token)) {
      $agentContractIssues.Add(("dispatch.ps1 缺少 policy bypass 审计标记: {0}" -f $token)) | Out-Null
    }
  }
}

if (Test-Path -LiteralPath $reviewLoopPath -PathType Leaf) {
  $reviewRaw = Get-Content -LiteralPath $reviewLoopPath -Raw -Encoding UTF8
  foreach ($token in @('Get-SnapshotDiffSummary', 'diff_summary', 'review_loop.last.diff.md')) {
    if ($reviewRaw -notmatch [regex]::Escape($token)) {
      $agentContractIssues.Add(("review_loop.ps1 缺少 diff 摘要标记: {0}" -f $token)) | Out-Null
    }
  }
}

if (Test-Path -LiteralPath $firstPassPath -PathType Leaf) {
  $firstPassRaw = Get-Content -LiteralPath $firstPassPath -Raw -Encoding UTF8
  foreach ($token in @('Change-Scale Correlation (Round 1)', 'change_scale_correlation', 'round1_touched_files', 'round1_abs_net_size_delta_bytes')) {
    if ($firstPassRaw -notmatch [regex]::Escape($token)) {
      $agentContractIssues.Add(("first_pass_report.ps1 缺少改动规模相关性标记: {0}" -f $token)) | Out-Null
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

# 10) MCP/RAG 最小可用性
$mcpScript = Join-Path $raymanDir 'scripts\mcp\manage_mcp.ps1'
$ragScript = Join-Path $raymanDir 'scripts\rag\manage_rag.ps1'
$ragBootstrapScript = Join-Path $raymanDir 'scripts\rag\rag_bootstrap.ps1'
$ragReq = Join-Path $raymanDir 'scripts\rag\requirements.txt'
$buildPy = Join-Path $raymanDir 'scripts\rag\build_index.py'

$mcpOk = $true
$mcpStatusDetail = ''
if (-not (Test-Path -LiteralPath $mcpScript -PathType Leaf)) {
  $mcpOk = $false
  $mcpStatusDetail = ("缺少脚本: {0}" -f $mcpScript)
} else {
  try {
    $childPs = Resolve-ChildPowerShellHost
    if ([string]::IsNullOrWhiteSpace($childPs)) {
      throw '未找到可用的 PowerShell host（pwsh/powershell.exe）'
    }
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $mcpScript, '-Action', 'status')
    $mcpExit = 1
    $mcpTimedOut = $false
    $statusTimeoutSeconds = 20
    $statusTimeoutRaw = [Environment]::GetEnvironmentVariable('RAYMAN_RELEASE_GATE_MCP_STATUS_TIMEOUT_SECONDS')
    if (-not [string]::IsNullOrWhiteSpace([string]$statusTimeoutRaw)) {
      $parsedTimeout = 0
      if ([int]::TryParse($statusTimeoutRaw, [ref]$parsedTimeout) -and $parsedTimeout -gt 0) {
        $statusTimeoutSeconds = $parsedTimeout
      }
    }
    $statusTimeoutMs = [Math]::Max(1000, ($statusTimeoutSeconds * 1000))
    try {
      $proc = Start-Process -FilePath $childPs -ArgumentList $childArgs -PassThru -ErrorAction Stop
      if ($null -ne $proc) {
        if ($proc.WaitForExit($statusTimeoutMs)) {
          if ($null -ne $proc.ExitCode) {
            $mcpExit = [int]$proc.ExitCode
          } else {
            $mcpExit = 0
          }
        } else {
          $mcpTimedOut = $true
          try { $proc.Kill() } catch {}
          $mcpExit = 124
        }
      } else {
        $mcpExit = 0
      }
    } catch {
      # Fallback path for hosts where Start-Process spawn behavior is restricted.
      [void](& $childPs @childArgs)
      if (Test-Path variable:LASTEXITCODE) {
        $mcpExit = [int]$LASTEXITCODE
      } elseif ($?) {
        $mcpExit = 0
      }
    }
    if ($mcpTimedOut) {
      $mcpOk = $false
      $mcpStatusDetail = ("status timeout={0}s, host={1}" -f $statusTimeoutSeconds, $childPs)
    } elseif ($mcpExit -ne 0) {
      $mcpOk = $false
      $mcpStatusDetail = ("status exit={0}, host={1}" -f $mcpExit, $childPs)
    }
  } catch {
    $mcpOk = $false
    $mcpStatusDetail = [string]$_.Exception.Message
  }
}

$ragWarn = @()
if (-not (Test-Path -LiteralPath $ragScript -PathType Leaf)) { $ragWarn += 'manage_rag.ps1 缺失' }
if (-not (Test-Path -LiteralPath $ragBootstrapScript -PathType Leaf)) { $ragWarn += 'rag_bootstrap.ps1 缺失' }
if (-not (Test-Path -LiteralPath $ragReq -PathType Leaf)) { $ragWarn += 'requirements.txt 缺失' }
if (-not (Test-Path -LiteralPath $buildPy -PathType Leaf)) { $ragWarn += 'build_index.py 缺失' }

$ragDepsOk = $true
$ragDepsRuntime = ''
if ($ragWarn.Count -eq 0) {
  try {
    . $ragBootstrapScript
    $probe = Invoke-RaymanRagBootstrap -WorkspaceRoot $WorkspaceRoot -EnsureDeps:$false -NoInstallDeps -Quiet
    if ($probe.Success) {
      $ragDepsOk = $true
      $ragDepsRuntime = [string]$probe.PythonLabel
    } else {
      $ragDepsOk = $false
      if ([string]::IsNullOrWhiteSpace([string]$probe.Message)) {
        $ragWarn += 'RAG 依赖未就绪（rag_bootstrap 探测失败）'
      } else {
        $ragWarn += [string]$probe.Message
      }
    }
  } catch {
    $ragDepsOk = $false
    $ragWarn += ("rag_bootstrap 执行失败: {0}" -f $_.Exception.Message)
  }
}

if ($mcpOk -and $ragWarn.Count -eq 0 -and $ragDepsOk) {
  $runtimeText = if ([string]::IsNullOrWhiteSpace($ragDepsRuntime)) { '自动探测' } else { $ragDepsRuntime }
  Add-Result -Results $results -Name 'MCP/RAG最小可用性' -Status PASS -Detail ("MCP status 正常，RAG 依赖可导入（{0}）" -f $runtimeText)
} elseif (-not $mcpOk) {
  $mcpFailDetail = 'MCP status 检查失败'
  if (-not [string]::IsNullOrWhiteSpace($mcpStatusDetail)) {
    $mcpFailDetail = ("{0} ({1})" -f $mcpFailDetail, $mcpStatusDetail)
  }
  if ($Mode -eq 'project') {
    Add-Result -Results $results -Name 'MCP/RAG最小可用性' -Status PASS -Detail ("project 模式初始化豁免：{0}" -f $mcpFailDetail) -Action '如需严格探活，请执行 ./.Rayman/scripts/mcp/manage_mcp.ps1 -Action start 后用 standard 模式复检'
  } else {
    Add-Result -Results $results -Name 'MCP/RAG最小可用性' -Status FAIL -Detail $mcpFailDetail -Action '检查 .Rayman/mcp/mcp_servers.json 与 mcp 脚本'
  }
} else {
  $detail = if ($ragWarn.Count -gt 0) { $ragWarn -join ' | ' } else { 'RAG 依赖未就绪（可在 setup/build 时自动安装）' }
  if ($Mode -eq 'project') {
    Add-Result -Results $results -Name 'MCP/RAG最小可用性' -Status PASS -Detail ("project 模式初始化豁免：{0}" -f $detail) -Action '如需严格探活，可先执行 Rayman: Test & Fix 或 setup 预热，再用 standard 模式复检'
  } else {
    Add-Result -Results $results -Name 'MCP/RAG最小可用性' -Status WARN -Detail $detail -Action '可先执行 Rayman: Test & Fix 或 setup 预热'
  }
}

# 11) 回滚能力
$saveState = Join-Path $raymanDir 'scripts\state\save_state.ps1'
$resumeState = Join-Path $raymanDir 'scripts\state\resume_state.ps1'
$cliPath = Join-Path $raymanDir 'rayman.ps1'
$rollbackIssues = @()
if (-not (Test-Path -LiteralPath $saveState -PathType Leaf)) { $rollbackIssues += '缺少 save_state.ps1' }
if (-not (Test-Path -LiteralPath $resumeState -PathType Leaf)) { $rollbackIssues += '缺少 resume_state.ps1' }
if (Test-Path -LiteralPath $cliPath -PathType Leaf) {
  $cliRaw = Get-Content -LiteralPath $cliPath -Raw -Encoding UTF8
  if ($cliRaw -notmatch 'state-save') { $rollbackIssues += 'rayman.ps1 未暴露 state-save 命令' }
  if ($cliRaw -notmatch 'state-resume') { $rollbackIssues += 'rayman.ps1 未暴露 state-resume 命令' }
} else {
  $rollbackIssues += '缺少 rayman.ps1'
}

if ($rollbackIssues.Count -eq 0) {
  Add-Result -Results $results -Name '回滚能力' -Status PASS -Detail '状态保存/恢复入口可用'
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
      'RAG路径隔离' {
        [void]$md.AppendLine('- 设置路径：`$env:RAYMAN_RAG_ROOT=".rag"`；确保 `RAYMAN_RAG_NAMESPACE` 非空。')
        [void]$md.AppendLine('- 迁移旧库：`./.Rayman/rayman.ps1 migrate-rag`')
      }
      'MCP/RAG最小可用性' {
        [void]$md.AppendLine('- 启动 MCP：`./.Rayman/scripts/mcp/manage_mcp.ps1 -Action start`')
        [void]$md.AppendLine('- 预热 RAG：`./.Rayman/scripts/rag/manage_rag.ps1 -Action build`')
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
