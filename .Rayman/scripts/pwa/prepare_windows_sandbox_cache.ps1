param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [ValidateSet('chromium')][string]$Browser = 'chromium'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-EnvBoolValue([string]$Name, [bool]$Default = $false) {
  $raw = [System.Environment]::GetEnvironmentVariable($Name)
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

function Get-EnvIntValue([string]$Name, [int]$Default, [int]$Min = 1, [int]$Max = 720) {
  $raw = [System.Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
  $parsed = 0
  if (-not [int]::TryParse($raw.Trim(), [ref]$parsed)) { return $Default }
  if ($parsed -lt $Min) { return $Min }
  if ($parsed -gt $Max) { return $Max }
  return $parsed
}

function Ensure-Directory([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Remove-DirectoryContents([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
  Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
    try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }
}

function Get-CacheManifestFresh([string]$ManifestPath, [int]$MaxAgeHours) {
  if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return $false }
  try {
    $payload = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $ts = [DateTimeOffset]::Parse([string]$payload.generated_at)
    $age = (New-TimeSpan -Start $ts -End (Get-Date)).TotalHours
    if ($age -lt 0) { $age = 0 }
    return ($age -le $MaxAgeHours)
  } catch {
    return $false
  }
}

function Copy-NodeRuntimeToCache([string]$NodeCacheDir) {
  $result = [ordered]@{
    available = $false
    source = ''
    cached_path = $NodeCacheDir
    copied = $false
    error = ''
    version = ''
  }

  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $nodeCmd -or [string]::IsNullOrWhiteSpace([string]$nodeCmd.Source)) {
    $result.error = 'node command not found on host'
    return [pscustomobject]$result
  }

  $nodeDir = Split-Path -Path $nodeCmd.Source -Parent
  if (-not (Test-Path -LiteralPath $nodeDir -PathType Container)) {
    $result.error = "node runtime directory missing: $nodeDir"
    return [pscustomobject]$result
  }

  $result.available = $true
  $result.source = $nodeDir
  try {
    $ver = (& $nodeCmd.Source --version 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$ver)) {
      $result.version = [string]$ver
    }
  } catch {}

  Ensure-Directory -Path $NodeCacheDir
  try {
    Copy-Item -Path (Join-Path $nodeDir '*') -Destination $NodeCacheDir -Recurse -Force
    $result.copied = $true
  } catch {
    $result.error = $_.Exception.Message
  }

  return [pscustomobject]$result
}

function Prepare-PlaywrightPackages([string]$PackagesDir, [string]$WorkspaceRoot) {
  $result = [ordered]@{
    available = $false
    cached_path = $PackagesDir
    copied = $false
    error = ''
    packs = @()
  }

  $npmCmd = Get-Command npm -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $npmCmd -or [string]::IsNullOrWhiteSpace([string]$npmCmd.Source)) {
    $result.error = 'npm command not found on host'
    return [pscustomobject]$result
  }

  $npmExecutable = [string]$npmCmd.Source
  if ($npmExecutable -like '*.ps1') {
    $candidate = Join-Path (Split-Path -Path $npmExecutable -Parent) 'npm.cmd'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $npmExecutable = $candidate
    }
  }

  Ensure-Directory -Path $PackagesDir

  function Get-ProxyFromSnapshot([string]$RootPath) {
    try {
      $snapshotPath = Join-Path $RootPath '.Rayman\\runtime\\proxy.resolved.json'
      if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) { return '' }
      $snapshot = Get-Content -LiteralPath $snapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      foreach ($key in @('https_proxy', 'http_proxy', 'all_proxy', 'HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY')) {
        if ($snapshot.PSObject.Properties[$key] -and -not [string]::IsNullOrWhiteSpace([string]$snapshot.$key)) {
          return ([string]$snapshot.$key).Trim()
        }
      }
    } catch {}
    return ''
  }

  function Apply-NpmProxyFallback([string]$RootPath) {
    $currentProxy = [System.Environment]::GetEnvironmentVariable('https_proxy')
    if ([string]::IsNullOrWhiteSpace($currentProxy)) {
      $currentProxy = [System.Environment]::GetEnvironmentVariable('HTTPS_PROXY')
    }
    if (-not [string]::IsNullOrWhiteSpace($currentProxy)) { return '' }

    $proxy = Get-ProxyFromSnapshot -RootPath $RootPath
    if ([string]::IsNullOrWhiteSpace($proxy)) {
      $fallbackEnabled = Get-EnvBoolValue -Name 'RAYMAN_PROXY_FALLBACK_8988' -Default $true
      if ($fallbackEnabled) {
        $proxy = [System.Environment]::GetEnvironmentVariable('RAYMAN_PROXY_FALLBACK_URL')
        if ([string]::IsNullOrWhiteSpace($proxy)) { $proxy = 'http://127.0.0.1:8988' }
      }
    }
    if ([string]::IsNullOrWhiteSpace($proxy)) { return '' }

    foreach ($name in @('http_proxy', 'https_proxy', 'all_proxy', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')) {
      [System.Environment]::SetEnvironmentVariable($name, $proxy, 'Process')
    }
    if ([string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable('no_proxy'))) {
      [System.Environment]::SetEnvironmentVariable('no_proxy', 'localhost,127.0.0.1,::1', 'Process')
      [System.Environment]::SetEnvironmentVariable('NO_PROXY', 'localhost,127.0.0.1,::1', 'Process')
    }

    return $proxy
  }

  $appliedProxy = Apply-NpmProxyFallback -RootPath $WorkspaceRoot
  $attempts = Get-EnvIntValue -Name 'RAYMAN_SANDBOX_CACHE_NPM_PACK_RETRIES' -Default 3 -Min 1 -Max 10
  $sleepSeconds = Get-EnvIntValue -Name 'RAYMAN_SANDBOX_CACHE_NPM_PACK_RETRY_DELAY_SECONDS' -Default 2 -Min 1 -Max 30

  $packed = New-Object System.Collections.Generic.List[string]
  $errors = New-Object System.Collections.Generic.List[string]
  Push-Location $PackagesDir
  try {
    foreach ($pkg in @('playwright@latest', 'playwright-core@latest')) {
      $ok = $false
      for ($i = 1; $i -le $attempts; $i++) {
        try {
          $outputLines = @(& $npmExecutable pack $pkg --silent)
          if ($LASTEXITCODE -eq 0) {
            $tgzLine = ($outputLines | ForEach-Object { [string]$_ } | Where-Object { $_ -match '\\.tgz\s*$' } | Select-Object -Last 1)
            if (-not [string]::IsNullOrWhiteSpace([string]$tgzLine)) {
              $packed.Add(([string]$tgzLine).Trim()) | Out-Null
            }
            $ok = $true
            break
          }
          $flatOutput = (($outputLines | ForEach-Object { [string]$_ }) -join ' ').Trim()
          $errors.Add(('[{0}] attempt {1}/{2} exit={3}: {4}' -f $pkg, $i, $attempts, $LASTEXITCODE, $flatOutput)) | Out-Null
        } catch {
          $errMessage = ''
          $errPosition = ''
          try {
            $errMessage = [string]$PSItem.Exception.Message
          } catch {
            $errMessage = [string]$PSItem
          }
          try {
            $errPosition = [string]$PSItem.InvocationInfo.PositionMessage
          } catch {}
          if ([string]::IsNullOrWhiteSpace($errMessage)) { $errMessage = 'unknown error' }
          if (-not [string]::IsNullOrWhiteSpace($errPosition)) {
            $errMessage = ("{0} @ {1}" -f $errMessage, $errPosition.Replace("`r",' ').Replace("`n",' '))
          }
          $errors.Add(('[{0}] attempt {1}/{2} exception: {3}' -f $pkg, $i, $attempts, $errMessage)) | Out-Null
        }
        if ($i -lt $attempts) {
          Start-Sleep -Seconds $sleepSeconds
        }
      }
      if (-not $ok) {
        $errors.Add(('[{0}] failed after retries ({1})' -f $pkg, $attempts)) | Out-Null
      }
    }
  } finally {
    Pop-Location
  }

  $playwrightPkg = Get-ChildItem -LiteralPath $PackagesDir -Filter 'playwright-*.tgz' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $playwrightCorePkg = Get-ChildItem -LiteralPath $PackagesDir -Filter 'playwright-core-*.tgz' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1

  if ($playwrightPkg -and $playwrightCorePkg) {
    $result.available = $true
    $result.copied = ($packed.Count -gt 0)
    $result.packs = @($playwrightPkg.Name, $playwrightCorePkg.Name)
    if (-not [string]::IsNullOrWhiteSpace([string]$appliedProxy)) {
      $result.error = ("proxy_applied={0}" -f $appliedProxy)
    }
    return [pscustomobject]$result
  }

  $result.error = 'failed to build offline playwright packages (playwright/playwright-core)'
  if ($errors.Count -gt 0) {
    $tail = @($errors | Select-Object -Last 4) -join ' | '
    $result.error = ("{0}; details={1}" -f $result.error, $tail)
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$appliedProxy)) {
    $result.error = ("{0}; proxy={1}" -f $result.error, $appliedProxy)
  }
  return [pscustomobject]$result
}

function Copy-ChromiumCache([string]$ChromiumCacheDir, [bool]$Enabled) {
  $result = [ordered]@{
    available = $false
    source = ''
    cached_path = $ChromiumCacheDir
    copied = $false
    error = ''
    entries = @()
  }

  if (-not $Enabled) {
    $result.error = 'browser cache copy disabled by RAYMAN_SANDBOX_OFFLINE_CACHE_COPY_BROWSERS=0'
    return [pscustomobject]$result
  }

  $roots = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $roots.Add((Join-Path $env:LOCALAPPDATA 'ms-playwright')) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $roots.Add((Join-Path $env:USERPROFILE 'AppData\\Local\\ms-playwright')) | Out-Null
  }

  $sourceRoot = ''
  foreach ($r in ($roots | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $r -PathType Container)) { continue }
    $chromiumDirs = Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'chromium-*' }
    if ($chromiumDirs -and $chromiumDirs.Count -gt 0) {
      $sourceRoot = $r
      break
    }
  }

  if ([string]::IsNullOrWhiteSpace($sourceRoot)) {
    $result.error = 'host chromium cache not found under ms-playwright'
    return [pscustomobject]$result
  }

  $result.available = $true
  $result.source = $sourceRoot

  Ensure-Directory -Path $ChromiumCacheDir

  try {
    $copiedEntries = New-Object System.Collections.Generic.List[string]
    $dirs = Get-ChildItem -LiteralPath $sourceRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'chromium-*' }
    foreach ($d in $dirs) {
      Copy-Item -LiteralPath $d.FullName -Destination (Join-Path $ChromiumCacheDir $d.Name) -Recurse -Force
      $copiedEntries.Add($d.Name) | Out-Null
    }
    if ($copiedEntries.Count -gt 0) {
      $result.copied = $true
      $result.entries = @($copiedEntries)
      return [pscustomobject]$result
    }
    $result.error = 'no chromium-* entries copied'
  } catch {
    $result.error = $_.Exception.Message
  }

  return [pscustomobject]$result
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$runtimeDir = Join-Path $WorkspaceRoot '.Rayman\\runtime'
Ensure-Directory -Path $runtimeDir

$cacheRoot = Join-Path $runtimeDir 'windows-sandbox\\cache'
$manifestPath = Join-Path $cacheRoot 'cache_manifest.json'

$enabled = Get-EnvBoolValue -Name 'RAYMAN_SANDBOX_OFFLINE_CACHE_ENABLED' -Default $true
$copyBrowsers = Get-EnvBoolValue -Name 'RAYMAN_SANDBOX_OFFLINE_CACHE_COPY_BROWSERS' -Default $true
$refreshHours = Get-EnvIntValue -Name 'RAYMAN_SANDBOX_OFFLINE_CACHE_REFRESH_HOURS' -Default 24 -Min 1 -Max 720
$forceRefresh = Get-EnvBoolValue -Name 'RAYMAN_SANDBOX_OFFLINE_CACHE_FORCE' -Default $false

$result = [ordered]@{
  schema = 'rayman.sandbox.offline-cache.v1'
  success = $true
  skipped = $false
  reused = $false
  reason = ''
  detail = ''
  workspace_root = $WorkspaceRoot
  browser = $Browser
  cache_root = $cacheRoot
  manifest = $manifestPath
  settings = [ordered]@{
    enabled = $enabled
    copy_browsers = $copyBrowsers
    refresh_hours = $refreshHours
    force = $forceRefresh
  }
  completeness = [ordered]@{
    node = $false
    playwright_packages = $false
    browser_cache = $false
  }
  missing_components = @()
  failure_kind = ''
  action_required = ''
  ready_for_offline_playwright = $false
  node = $null
  playwright_packages = $null
  browser_cache = $null
  generated_at = (Get-Date).ToString('o')
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
  $result.success = $false
  $result.skipped = $true
  $result.reason = 'host_not_windows'
  $result.detail = 'sandbox offline cache preparation is only available on Windows host'
  return [pscustomobject]$result
}

if (-not $enabled) {
  Ensure-Directory -Path $cacheRoot
  $result.skipped = $true
  $result.reason = 'cache_disabled'
  $result.detail = 'RAYMAN_SANDBOX_OFFLINE_CACHE_ENABLED=0'
  ($result | ConvertTo-Json -Depth 10) | Out-File -FilePath $manifestPath -Encoding utf8
  return [pscustomobject]$result
}

Ensure-Directory -Path $cacheRoot
if (-not $forceRefresh -and (Get-CacheManifestFresh -ManifestPath $manifestPath -MaxAgeHours $refreshHours)) {
  $result.reused = $true
  $result.detail = 'existing sandbox cache manifest is still fresh'
  try {
    $prev = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ($prev.PSObject.Properties['completeness']) {
      $result.completeness.node = [bool]$prev.completeness.node
      $result.completeness.playwright_packages = [bool]$prev.completeness.playwright_packages
      $result.completeness.browser_cache = [bool]$prev.completeness.browser_cache
    }
    if ($prev.PSObject.Properties['ready_for_offline_playwright']) {
      $result.ready_for_offline_playwright = [bool]$prev.ready_for_offline_playwright
    }
    if ($prev.PSObject.Properties['missing_components']) {
      $result.missing_components = @($prev.missing_components | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($prev.PSObject.Properties['failure_kind']) {
      $result.failure_kind = [string]$prev.failure_kind
    }
    if ($prev.PSObject.Properties['action_required']) {
      $result.action_required = [string]$prev.action_required
    }
  } catch {}
  return [pscustomobject]$result
}

$nodeCacheDir = Join-Path $cacheRoot 'node-runtime'
$packagesDir = Join-Path $cacheRoot 'npm-offline'
$browserCacheDir = Join-Path $cacheRoot 'ms-playwright'

$nodeResult = Copy-NodeRuntimeToCache -NodeCacheDir $nodeCacheDir
$pkgResult = Prepare-PlaywrightPackages -PackagesDir $packagesDir -WorkspaceRoot $WorkspaceRoot
$browserResult = Copy-ChromiumCache -ChromiumCacheDir $browserCacheDir -Enabled $copyBrowsers

$result.node = $nodeResult
$result.playwright_packages = $pkgResult
$result.browser_cache = $browserResult

$nodeCacheReady = (Test-Path -LiteralPath (Join-Path $nodeCacheDir 'node.exe') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $nodeCacheDir 'npm.cmd') -PathType Leaf)
$pkgCacheReady = (Get-ChildItem -LiteralPath $packagesDir -Filter 'playwright-*.tgz' -File -ErrorAction SilentlyContinue | Select-Object -First 1) -and (Get-ChildItem -LiteralPath $packagesDir -Filter 'playwright-core-*.tgz' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
$browserCacheReady = [bool](Get-ChildItem -LiteralPath $browserCacheDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'chromium-*' } | Select-Object -First 1)

$result.completeness.node = [bool]$nodeCacheReady
$result.completeness.playwright_packages = [bool]$pkgCacheReady
$result.completeness.browser_cache = [bool]$browserCacheReady

$missingComponents = New-Object System.Collections.Generic.List[string]
if (-not $result.completeness.node) {
  $missingComponents.Add('node-runtime') | Out-Null
}
if (-not $result.completeness.playwright_packages) {
  $missingComponents.Add('npm-offline') | Out-Null
}
if ($copyBrowsers -and -not $result.completeness.browser_cache) {
  $missingComponents.Add('ms-playwright') | Out-Null
}
$result.missing_components = @($missingComponents.ToArray())

$result.ready_for_offline_playwright = ($result.completeness.node -and $result.completeness.playwright_packages -and ($result.completeness.browser_cache -or -not $copyBrowsers))
if (-not $result.ready_for_offline_playwright) {
  $result.success = $false
  $result.failure_kind = 'offline_cache_incomplete'
  $result.action_required = 'Run .\.Rayman\scripts\pwa\prepare_windows_sandbox_cache.ps1 on the Windows host until node-runtime, npm-offline, and ms-playwright are all cached, then retry sandbox setup.'
  $missingText = if ($result.missing_components.Count -gt 0) { ($result.missing_components -join ', ') } else { 'unknown' }
  $result.detail = ("offline cache is incomplete; missing={0}; sandbox host preflight must block before bootstrap" -f $missingText)
}

($result | ConvertTo-Json -Depth 10) | Out-File -FilePath $manifestPath -Encoding utf8
return [pscustomobject]$result
