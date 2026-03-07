$ErrorActionPreference = 'Stop'

# This script runs INSIDE Windows Sandbox at logon.
# It installs .NET 10 + Node.js + Playwright and writes host-visible status/logs
# to the mapped workspace folder so the host init.ps1 can wait for readiness.

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..') | Select-Object -ExpandProperty Path)
$HostStatusDir = Join-Path $ProjectRoot '.Rayman\runtime\windows-sandbox\status'
New-Item -ItemType Directory -Force -Path $HostStatusDir | Out-Null

$StatusFile = Join-Path $HostStatusDir 'bootstrap_status.json'
$LogFile = Join-Path $HostStatusDir 'bootstrap.log'
$PlaywrightMarkerFile = Join-Path $HostStatusDir 'playwright.ready.sandbox.json'
$OfflineCacheRoot = Join-Path $ProjectRoot '.Rayman\runtime\windows-sandbox\cache'
$OfflineCacheManifestFile = Join-Path $OfflineCacheRoot 'cache_manifest.json'
$script:BootstrapWarnings = New-Object System.Collections.Generic.List[string]
$script:OfflineCacheUsed = $false
$script:NodeSource = 'network'
$script:PlaywrightSource = 'network'
$script:NetworkPreflight = [ordered]@{ checked = $false; npm = $false; nuget = $false; detail = '' }
$script:RunId = ((Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [Guid]::NewGuid().ToString('n').Substring(0,8))
Remove-Item -LiteralPath $PlaywrightMarkerFile -Force -ErrorAction SilentlyContinue

function Write-Status([bool]$success, [string]$phase, [string]$message = '', [string]$err = '') {
  $payload = [ordered]@{
    success    = $success
    phase      = $phase
    message    = $message
    "error"    = $err
    machine    = $env:COMPUTERNAME
    startedAt  = $script:StartedAt
    finishedAt = (Get-Date).ToString('o')
  }
  ($payload | ConvertTo-Json -Depth 5) | Out-File -FilePath $StatusFile -Encoding utf8
}

# --- proxy preference -----------------------------------------------------------
$script:ProxyKeys = @('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')
$script:ProxySnapshot = @{}
foreach($k in $script:ProxyKeys){
  $v = [System.Environment]::GetEnvironmentVariable($k, 'Process')
  if (-not $v) { $v = [System.Environment]::GetEnvironmentVariable($k.ToUpperInvariant(), 'Process') }
  $script:ProxySnapshot[$k] = $v
}
$script:ProxySnapshotSource = 'process-env'

function Get-EnvBool([string]$Name, [bool]$Default = $false) {
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

function Get-ObjectValueCaseInsensitive([object]$Object, [string]$Name) {
  if ($null -eq $Object) { return $null }
  foreach ($p in $Object.PSObject.Properties) {
    if ($p.Name -ieq $Name) { return $p.Value }
  }
  return $null
}

function Get-ProxyUri([string]$ProxyValue) {
  if ([string]::IsNullOrWhiteSpace($ProxyValue)) { return $null }
  try { return [System.Uri]$ProxyValue } catch { return $null }
}

function Test-LoopbackProxyEndpoint([string]$ProxyValue) {
  $uri = Get-ProxyUri -ProxyValue $ProxyValue
  if ($null -eq $uri) { return $false }
  $h = $uri.Host.ToLowerInvariant()
  return ($h -eq '127.0.0.1' -or $h -eq 'localhost' -or $h -eq '::1')
}

function Get-SandboxHostGatewayIPv4 {
  try {
    $nics = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled=TRUE"
    foreach ($nic in $nics) {
      if (-not $nic.DefaultIPGateway) { continue }
      foreach ($gw in $nic.DefaultIPGateway) {
        $g = [string]$gw
        if ($g -match '^\d+\.\d+\.\d+\.\d+$' -and $g -ne '0.0.0.0') { return $g }
      }
    }
  } catch {}
  return $null
}

function Rewrite-ProxyLoopbackToHostGateway {
  $rewriteEnabled = Get-EnvBool -Name 'RAYMAN_SANDBOX_PROXY_REWRITE_LOOPBACK' -Default $true
  if (-not $rewriteEnabled) { return }
  $gateway = Get-SandboxHostGatewayIPv4
  if ([string]::IsNullOrWhiteSpace($gateway)) { return }

  foreach ($k in @('http_proxy','https_proxy','all_proxy')) {
    $v = [string]$script:ProxySnapshot[$k]
    if (-not (Test-LoopbackProxyEndpoint -ProxyValue $v)) { continue }
    try {
      $uri = [System.Uri]$v
      $ub = [System.UriBuilder]::new($uri)
      $ub.Host = $gateway
      $rewritten = $ub.Uri.AbsoluteUri.TrimEnd('/')
      if ($rewritten -ne $v) {
        Write-Host ("[sandbox] proxy rewrite: {0} {1} -> {2}" -f $k, $v, $rewritten)
        $script:ProxySnapshot[$k] = $rewritten
      }
    } catch {}
  }
}

function Apply-SandboxProxyOverride {
  $override = [System.Environment]::GetEnvironmentVariable('RAYMAN_SANDBOX_PROXY_OVERRIDE')
  if ([string]::IsNullOrWhiteSpace($override)) { return }
  $v = $override.Trim()
  foreach ($k in @('http_proxy','https_proxy','all_proxy')) {
    $script:ProxySnapshot[$k] = $v
  }
  Write-Host ("[sandbox] proxy override applied from RAYMAN_SANDBOX_PROXY_OVERRIDE: {0}" -f $v)
}

function Warn-IfLoopbackProxyRemains {
  foreach ($k in @('http_proxy','https_proxy','all_proxy')) {
    $v = [string]$script:ProxySnapshot[$k]
    if (Test-LoopbackProxyEndpoint -ProxyValue $v) {
      Add-BootstrapWarning ("proxy {0} still points to loopback inside Sandbox ({1}); if downloads fail, set RAYMAN_SANDBOX_PROXY_OVERRIDE to a host-reachable proxy endpoint." -f $k, $v)
      return
    }
  }
}

function Test-ProxySnapshotHasEndpoint {
  return (-not [string]::IsNullOrWhiteSpace([string]$script:ProxySnapshot['http_proxy'])) -or
         (-not [string]::IsNullOrWhiteSpace([string]$script:ProxySnapshot['https_proxy'])) -or
         (-not [string]::IsNullOrWhiteSpace([string]$script:ProxySnapshot['all_proxy']))
}

function Apply-SandboxProxyFallback {
  if (Test-ProxySnapshotHasEndpoint) { return }
  $enabled = Get-EnvBool -Name 'RAYMAN_SANDBOX_PROXY_FALLBACK_ENABLED' -Default $true
  if (-not $enabled) { return }

  $fallback = [System.Environment]::GetEnvironmentVariable('RAYMAN_SANDBOX_PROXY_FALLBACK_URL')
  if ([string]::IsNullOrWhiteSpace($fallback)) { $fallback = 'http://127.0.0.1:8988' }
  $fallback = $fallback.Trim()

  $script:ProxySnapshot['http_proxy'] = $fallback
  $script:ProxySnapshot['https_proxy'] = $fallback
  $script:ProxySnapshot['all_proxy'] = $fallback
  if ([string]::IsNullOrWhiteSpace([string]$script:ProxySnapshot['no_proxy'])) {
    $script:ProxySnapshot['no_proxy'] = 'localhost,127.0.0.1,::1'
  }
  $script:ProxySnapshotSource = 'sandbox-fallback'
  Write-Host ("[sandbox] proxy fallback applied: {0}" -f $fallback)
}

function Sync-NuGetProxyEnv {
  $proxy = ''
  foreach ($k in @('https_proxy','http_proxy','all_proxy')) {
    $v = [string]$script:ProxySnapshot[$k]
    if (-not [string]::IsNullOrWhiteSpace($v)) {
      $proxy = $v
      break
    }
  }

  if ([string]::IsNullOrWhiteSpace($proxy)) {
    foreach ($name in @('NUGET_HTTP_PROXY','NUGET_HTTPS_PROXY','NUGET_PROXY')) {
      Set-Item -Path "Env:$name" -Value $null -ErrorAction SilentlyContinue
    }
    return
  }

  foreach ($name in @('NUGET_HTTP_PROXY','NUGET_HTTPS_PROXY','NUGET_PROXY')) {
    Set-Item -Path "Env:$name" -Value $proxy -ErrorAction SilentlyContinue
  }
}

function Import-ProxySnapshotFromHostFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  try {
    $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $applied = $false
    foreach($k in $script:ProxyKeys){
      $v = Get-ObjectValueCaseInsensitive -Object $json -Name $k
      if (-not $v) { $v = Get-ObjectValueCaseInsensitive -Object $json -Name $k.ToUpperInvariant() }
      if (-not [string]::IsNullOrWhiteSpace([string]$v)) {
        $script:ProxySnapshot[$k] = [string]$v
        $applied = $true
      }
    }
    if ($applied) {
      $script:ProxySnapshotSource = [string](Get-ObjectValueCaseInsensitive -Object $json -Name 'source')
      if ([string]::IsNullOrWhiteSpace($script:ProxySnapshotSource)) { $script:ProxySnapshotSource = 'host-snapshot' }
      Write-Host ("[sandbox] proxy snapshot restored from {0} (source={1})" -f $Path, $script:ProxySnapshotSource)
      return $true
    }
  } catch {
    Write-Host ("[sandbox] WARN: failed to load proxy snapshot {0}: {1}" -f $Path, $_.Exception.Message)
  }
  return $false
}

function Import-ProxyOverrideFromHostFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  try {
    $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $override = [string](Get-ObjectValueCaseInsensitive -Object $json -Name 'proxy')
    if ([string]::IsNullOrWhiteSpace($override)) {
      $override = [string](Get-ObjectValueCaseInsensitive -Object $json -Name 'http_proxy')
    }
    if ([string]::IsNullOrWhiteSpace($override)) { return $false }

    $script:ProxySnapshot['http_proxy'] = $override
    $script:ProxySnapshot['https_proxy'] = $override
    $script:ProxySnapshot['all_proxy'] = $override
    $script:ProxySnapshotSource = 'host-override-file'
    Write-Host ("[sandbox] proxy override loaded from file: {0} -> {1}" -f $Path, $override)
    return $true
  } catch {
    Write-Host ("[sandbox] WARN: failed to load proxy override {0}: {1}" -f $Path, $_.Exception.Message)
    return $false
  }
}

if (-not (Test-ProxySnapshotHasEndpoint)) {
  $proxySnapshotPath = Join-Path $ProjectRoot '.Rayman\runtime\proxy.resolved.json'
  [void](Import-ProxySnapshotFromHostFile -Path $proxySnapshotPath)
}
Apply-SandboxProxyFallback
$proxyOverridePath = Join-Path $ProjectRoot '.Rayman\runtime\sandbox.proxy.override.json'
[void](Import-ProxyOverrideFromHostFile -Path $proxyOverridePath)
Apply-SandboxProxyOverride
Rewrite-ProxyLoopbackToHostGateway
Warn-IfLoopbackProxyRemains
Sync-NuGetProxyEnv

function Clear-ProxyEnv {
  foreach($k in $script:ProxyKeys){
    $upper = $k.ToUpperInvariant()
    Set-Item -Path "Env:$k" -Value $null -ErrorAction SilentlyContinue
    Set-Item -Path "Env:$upper" -Value $null -ErrorAction SilentlyContinue
  }
  foreach ($name in @('NUGET_HTTP_PROXY','NUGET_HTTPS_PROXY','NUGET_PROXY')) {
    Set-Item -Path "Env:$name" -Value $null -ErrorAction SilentlyContinue
  }
}

function Get-ProxySnapshotSummary {
  $http = [string]$script:ProxySnapshot['http_proxy']
  $https = [string]$script:ProxySnapshot['https_proxy']
  $all = [string]$script:ProxySnapshot['all_proxy']
  return ("http={0}; https={1}; all={2}" -f $http, $https, $all)
}

function Restore-ProxyEnv {
  foreach($k in $script:ProxyKeys){
    $upper = $k.ToUpperInvariant()
    $v = $script:ProxySnapshot[$k]
    if ($null -eq $v -or "$v" -eq "") {
      Set-Item -Path "Env:$k" -Value $null -ErrorAction SilentlyContinue
      Set-Item -Path "Env:$upper" -Value $null -ErrorAction SilentlyContinue
    } else {
      Set-Item -Path "Env:$k" -Value $v -ErrorAction SilentlyContinue
      Set-Item -Path "Env:$upper" -Value $v -ErrorAction SilentlyContinue
    }
  }
  Sync-NuGetProxyEnv
}

function Invoke-WithProxyPreference([string]$name, [scriptblock]$action) {
  Write-Host ("[sandbox] step: {0} (phase1: no-proxy)" -f $name)
  Clear-ProxyEnv
  try {
    return (& $action)
  } catch {
    $e1 = $_.Exception.Message
    Write-Host ("[sandbox] WARN: {0} failed without proxy: {1}" -f $name, $e1)
  }

  $summary = Get-ProxySnapshotSummary
  Write-Host ("[sandbox] step: {0} (phase2: with-proxy {1})" -f $name, $summary)
  Restore-ProxyEnv
  try {
    return (& $action)
  } catch {
    throw ("{0} failed with proxy ({1}): {2}" -f $name, $summary, $_.Exception.Message)
  }
}

function Add-BootstrapWarning([string]$message) {
  Write-Host "[sandbox] WARN: $message"
  $null = $script:BootstrapWarnings.Add($message)
}

function Test-WebEndpoint([string]$Url, [int]$TimeoutMs = 12000) {
  [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
  $req = [System.Net.WebRequest]::Create($Url)
  $req.Timeout = $TimeoutMs
  $req.ReadWriteTimeout = $TimeoutMs
  $resp = $null
  try {
    $resp = $req.GetResponse()
    return $true
  } catch {
    return $false
  } finally {
    if ($resp) { $resp.Close() }
  }
}

function Invoke-NetworkPreflight {
  $script:NetworkPreflight.checked = $true
  Write-Status $false 'network-check' 'checking npm/nuget connectivity'
  Write-Host '[sandbox] checking network endpoints (npm + nuget)...'

  $npmOk = $false
  $nugetOk = $false
  $detail = ''

  try {
    $npmOk = [bool](Invoke-WithProxyPreference 'network preflight npm registry' {
      Test-WebEndpoint -Url 'https://registry.npmjs.org/-/ping' -TimeoutMs 10000
    })
  } catch {
    $detail += (' npm=' + $_.Exception.Message)
  }

  try {
    $nugetOk = [bool](Invoke-WithProxyPreference 'network preflight nuget' {
      Test-WebEndpoint -Url 'https://api.nuget.org/v3/index.json' -TimeoutMs 10000
    })
  } catch {
    $detail += (' nuget=' + $_.Exception.Message)
  }

  $script:NetworkPreflight.npm = $npmOk
  $script:NetworkPreflight.nuget = $nugetOk
  $script:NetworkPreflight.detail = $detail.Trim()

  if (-not $npmOk -or -not $nugetOk) {
    Add-BootstrapWarning ("network preflight partial failure: npm={0}; nuget={1}; detail={2}" -f $npmOk, $nugetOk, $script:NetworkPreflight.detail)
  } else {
    Write-Host '[sandbox] network preflight passed (npm+nuget reachable).'
  }
}

function Get-PlaywrightVersion {
  $pwCmd = Get-Command playwright -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($pwCmd) {
    try {
      $line = (& $pwCmd.Source --version 2>$null | Select-Object -First 1)
      if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$line)) {
        return [string]$line
      }
    } catch {}
  }

  $npxCmd = Get-Command npx -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($npxCmd) {
    try {
      $line = (& $npxCmd.Source playwright --version 2>$null | Select-Object -First 1)
      if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$line)) {
        return [string]$line
      }
    } catch {}
  }

  return ''
}

function Test-PlaywrightChromiumInstalled {
  $roots = @()
  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $roots += (Join-Path $env:LOCALAPPDATA 'ms-playwright')
  }
  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $roots += (Join-Path $env:USERPROFILE 'AppData\Local\ms-playwright')
  }

  foreach ($root in ($roots | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    $dir = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'chromium-*' } | Select-Object -First 1
    if ($dir) { return $true }
  }

  return $false
}

function Get-PlaywrightProbeDiagnostics {
  $pw = Get-Command playwright -ErrorAction SilentlyContinue | Select-Object -First 1
  $npx = Get-Command npx -ErrorAction SilentlyContinue | Select-Object -First 1
  $npm = Get-Command npm -ErrorAction SilentlyContinue | Select-Object -First 1
  $npmRoot = ''
  try {
    if ($npm) {
      $npmRoot = (& $npm.Source root -g 2>$null | Select-Object -First 1)
    }
  } catch {}

  $diag = [ordered]@{
    playwright_cmd = if ($pw) { [string]$pw.Source } else { '' }
    npx_cmd = if ($npx) { [string]$npx.Source } else { '' }
    npm_cmd = if ($npm) { [string]$npm.Source } else { '' }
    npm_global_root = [string]$npmRoot
    chromium_installed = (Test-PlaywrightChromiumInstalled)
  }
  return (($diag | ConvertTo-Json -Depth 3 -Compress))
}

function Write-PlaywrightMarker([bool]$Success, [string]$Detail, [string]$Version = '', [bool]$OfflineCacheUsed = $false, [string]$NodeSource = '', [string]$PlaywrightSource = '') {
  $payload = [ordered]@{
    schema = 'rayman.playwright.sandbox.v1'
    success = $Success
    browser = 'chromium'
    detail = $Detail
    playwrightVersion = $Version
    offlineCacheUsed = $OfflineCacheUsed
    nodeSource = $NodeSource
    playwrightSource = $PlaywrightSource
    generatedAt = (Get-Date).ToString('o')
  }
  ($payload | ConvertTo-Json -Depth 5) | Out-File -FilePath $PlaywrightMarkerFile -Encoding utf8
}

function Get-OfflineCacheMissingSummary {
  $missing = New-Object System.Collections.Generic.List[string]
  $nodeCache = Join-Path $OfflineCacheRoot 'node-runtime'
  $pkgCache = Join-Path $OfflineCacheRoot 'npm-offline'
  $browserCache = Join-Path $OfflineCacheRoot 'ms-playwright'

  if (-not (Test-Path -LiteralPath $nodeCache -PathType Container)) {
    $missing.Add('node-runtime') | Out-Null
  } else {
    if (-not (Test-Path -LiteralPath (Join-Path $nodeCache 'node.exe') -PathType Leaf)) { $missing.Add('node.exe') | Out-Null }
    if (-not (Test-Path -LiteralPath (Join-Path $nodeCache 'npm.cmd') -PathType Leaf)) { $missing.Add('npm.cmd') | Out-Null }
  }

  if (-not (Test-Path -LiteralPath $pkgCache -PathType Container)) {
    $missing.Add('npm-offline') | Out-Null
  } else {
    if (-not (Get-ChildItem -LiteralPath $pkgCache -Filter 'playwright-*.tgz' -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
      $missing.Add('playwright-*.tgz') | Out-Null
    }
    if (-not (Get-ChildItem -LiteralPath $pkgCache -Filter 'playwright-core-*.tgz' -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
      $missing.Add('playwright-core-*.tgz') | Out-Null
    }
  }

  if (-not (Test-Path -LiteralPath $browserCache -PathType Container)) {
    $missing.Add('ms-playwright') | Out-Null
  } else {
    if (-not (Get-ChildItem -LiteralPath $browserCache -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'chromium-*' } | Select-Object -First 1)) {
      $missing.Add('chromium-*') | Out-Null
    }
  }

  if ($missing.Count -eq 0) { return '' }
  return ($missing -join ',')
}

function Enable-OfflineNodeRuntimeFromCache {
  if (-not (Get-EnvBool -Name 'RAYMAN_SANDBOX_OFFLINE_CACHE_ENABLED' -Default $true)) { return $false }
  $nodeCache = Join-Path $OfflineCacheRoot 'node-runtime'
  if (-not (Test-Path -LiteralPath $nodeCache -PathType Container)) { return $false }

  $nodeExe = Join-Path $nodeCache 'node.exe'
  if (-not (Test-Path -LiteralPath $nodeExe -PathType Leaf)) { return $false }

  $env:Path = $nodeCache + ';' + $env:Path
  if (Test-NpmAvailable) {
    $script:OfflineCacheUsed = $true
    $script:NodeSource = 'offline-cache'
    Write-Host ("[sandbox] using offline Node runtime cache: {0}" -f $nodeCache)
    return $true
  }

  return $false
}

function Copy-OfflineChromiumCacheToLocal {
  if (-not (Get-EnvBool -Name 'RAYMAN_SANDBOX_OFFLINE_CACHE_COPY_BROWSERS' -Default $true)) { return $false }

  $sourceRoot = Join-Path $OfflineCacheRoot 'ms-playwright'
  if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { return $false }

  $destRoot = ''
  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $destRoot = Join-Path $env:LOCALAPPDATA 'ms-playwright'
  } elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $destRoot = Join-Path $env:USERPROFILE 'AppData\Local\ms-playwright'
  }
  if ([string]::IsNullOrWhiteSpace($destRoot)) { return $false }

  New-Item -ItemType Directory -Force -Path $destRoot | Out-Null

  $copied = $false
  $entries = Get-ChildItem -LiteralPath $sourceRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'chromium-*' }
  foreach ($entry in $entries) {
    $target = Join-Path $destRoot $entry.Name
    if (Test-Path -LiteralPath $target -PathType Container) {
      Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    }
    Copy-Item -LiteralPath $entry.FullName -Destination $target -Recurse -Force
    $copied = $true
  }

  if ($copied) {
    Write-Host ("[sandbox] copied offline chromium cache to: {0}" -f $destRoot)
  }
  return $copied
}

function Install-PlaywrightFromOfflineCache {
  if (-not (Get-EnvBool -Name 'RAYMAN_SANDBOX_OFFLINE_CACHE_ENABLED' -Default $true)) { return $false }
  if (-not (Test-NpmAvailable)) { return $false }

  $pkgCache = Join-Path $OfflineCacheRoot 'npm-offline'
  if (-not (Test-Path -LiteralPath $pkgCache -PathType Container)) { return $false }

  $playwrightPkg = Get-ChildItem -LiteralPath $pkgCache -Filter 'playwright-*.tgz' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $playwrightCorePkg = Get-ChildItem -LiteralPath $pkgCache -Filter 'playwright-core-*.tgz' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $playwrightPkg -or -not $playwrightCorePkg) { return $false }

  $npmCmd = Get-Command npm -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $npmCmd) { return $false }

  Write-Host '[sandbox] installing Playwright from offline cache packages...'
  & $npmCmd.Source i -g $playwrightPkg.FullName $playwrightCorePkg.FullName | Out-Null

  $browserCopied = Copy-OfflineChromiumCacheToLocal
  if ($browserCopied) {
    $script:OfflineCacheUsed = $true
    $script:PlaywrightSource = 'offline-cache'
  }

  if (-not [string]::IsNullOrWhiteSpace((Get-PlaywrightVersion)) -and (Test-PlaywrightChromiumInstalled)) {
    $script:OfflineCacheUsed = $true
    if ([string]::IsNullOrWhiteSpace($script:PlaywrightSource) -or $script:PlaywrightSource -eq 'network') {
      $script:PlaywrightSource = 'offline-cache'
    }
    return $true
  }

  return $false
}

function Ensure-Winget {
  $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd) { return $cmd.Source }
  $appInstallerPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
  if (Test-Path -LiteralPath $appInstallerPath -PathType Leaf) { return $appInstallerPath }
  return $null
}

function Refresh-SessionPath {
  $machinePath = [System.Environment]::GetEnvironmentVariable('Path','Machine')
  $userPath = [System.Environment]::GetEnvironmentVariable('Path','User')
  if ($machinePath -and $userPath) {
    $env:Path = $machinePath + ';' + $userPath
  } elseif ($machinePath) {
    $env:Path = $machinePath
  } elseif ($userPath) {
    $env:Path = $userPath
  }
}

function Install-WingetPackageIfMissing([string]$wingetExe, [string]$id) {
  if ([string]::IsNullOrWhiteSpace($wingetExe)) { return $false }
  $installed = $false
  try {
    $listOutput = (& $wingetExe list --id $id -e 2>$null | Out-String)
    if ($listOutput -match [Regex]::Escape($id)) { $installed = $true }
  } catch {
    $installed = $false
  }
  if (-not $installed) {
    & $wingetExe install --id $id -e --accept-source-agreements --accept-package-agreements --silent | Out-Null
  }
  return $true
}

function Ensure-ToolsRoot {
  $root = 'C:\RaymanTools'
  if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
  }
  return $root
}

function Invoke-DownloadStringWithProxyPreference([string]$name, [string]$url) {
  return (Invoke-WithProxyPreference ("{0} (download text)" -f $name) {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    try {
      $wc.DownloadString($url)
    } finally {
      $wc.Dispose()
    }
  })
}

function Invoke-DownloadFileWithProxyPreference([string]$name, [string]$url, [string]$destination) {
  Invoke-WithProxyPreference ("{0} (download file)" -f $name) {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
      Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
    }
    $wc = New-Object System.Net.WebClient
    try {
      $wc.DownloadFile($url, $destination)
    } finally {
      $wc.Dispose()
    }
  }
}

function Test-DotNetSdk10Available {
  $cmd = Get-Command dotnet -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd) { return $false }
  try {
    $sdks = @(& $cmd.Source --list-sdks 2>$null)
    foreach ($sdk in $sdks) {
      if ("$sdk" -match '^\s*10\.') { return $true }
    }
  } catch {}
  return $false
}

function Test-WindowsDesktopRuntime10Available {
  $cmd = Get-Command dotnet -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd) { return $false }
  try {
    $runtimes = @(& $cmd.Source --list-runtimes 2>$null)
    foreach ($rt in $runtimes) {
      # e.g. "Microsoft.WindowsDesktop.App 10.0.3 [C:\Program Files\dotnet\shared\Microsoft.WindowsDesktop.App]"
      if ("$rt" -match '^\s*Microsoft\.WindowsDesktop\.App\s+10\.') { return $true }
    }
  } catch {}
  return $false
}

function Ensure-DotNetSdk([string]$wingetExe) {
  if ((Test-DotNetSdk10Available) -and (Test-WindowsDesktopRuntime10Available)) { return $true }

  if ($wingetExe) {
    try {
      Invoke-WithProxyPreference '.NET SDK 10 (winget)' {
        [void](Install-WingetPackageIfMissing -wingetExe $wingetExe -id 'Microsoft.DotNet.SDK.10')
      }
    } catch {}
    Refresh-SessionPath
    if ((Test-DotNetSdk10Available) -and (Test-WindowsDesktopRuntime10Available)) { return $true }
  }

  try {
    $toolsRoot = Ensure-ToolsRoot
    $dotnetInstallPath = Join-Path $toolsRoot 'dotnet-install.ps1'
    Invoke-DownloadFileWithProxyPreference -name '.NET install script' -url 'https://dot.net/v1/dotnet-install.ps1' -destination $dotnetInstallPath

    $dotnetRoot = Join-Path $toolsRoot 'dotnet'
    New-Item -ItemType Directory -Force -Path $dotnetRoot | Out-Null

    # SDK 10.x
    & powershell -NoProfile -ExecutionPolicy Bypass -File $dotnetInstallPath -Channel '10.0' -InstallDir $dotnetRoot -NoPath | Out-Host
    # WindowsDesktop Runtime 10.x（WPF/WinForms）
    & powershell -NoProfile -ExecutionPolicy Bypass -File $dotnetInstallPath -Channel '10.0' -Runtime 'windowsdesktop' -OS 'win' -Architecture 'x64' -InstallDir $dotnetRoot -NoPath | Out-Host

    $env:Path = $dotnetRoot + ';' + $env:Path
  } catch {
    Write-Host ("[sandbox] WARN: dotnet fallback install failed: {0}" -f $_.Exception.Message)
  }

  return ((Test-DotNetSdk10Available) -and (Test-WindowsDesktopRuntime10Available))
}

function Test-NpmAvailable {
  return [bool](Get-Command npm -ErrorAction SilentlyContinue)
}

function Get-NodeZipCandidates {
  $override = [System.Environment]::GetEnvironmentVariable('RAYMAN_SANDBOX_NODE_VERSION')
  if (-not [string]::IsNullOrWhiteSpace($override)) {
    $v = $override.Trim()
    if (-not $v.StartsWith('v')) { $v = 'v' + $v }
    return @("https://nodejs.org/dist/$v/node-$v-win-x64.zip")
  }

  try {
    $indexText = Invoke-DownloadStringWithProxyPreference -name 'node index' -url 'https://nodejs.org/dist/index.json'
    $entries = $indexText | ConvertFrom-Json -ErrorAction Stop
    $urls = New-Object System.Collections.Generic.List[string]
    foreach ($e in $entries) {
      if ($null -eq $e) { continue }
      $ver = [string]$e.version
      if ([string]::IsNullOrWhiteSpace($ver)) { continue }
      $isLts = ($null -ne $e.lts -and "$($e.lts)" -ne '' -and "$($e.lts)" -ne 'false')
      if (-not $isLts) { continue }
      $files = @($e.files)
      if ($files -notcontains 'win-x64-zip') { continue }
      $urls.Add(("https://nodejs.org/dist/{0}/node-{0}-win-x64.zip" -f $ver)) | Out-Null
      if ($urls.Count -ge 3) { break }
    }
    if ($urls.Count -gt 0) { return @($urls) }
  } catch {
    Write-Host ("[sandbox] WARN: failed to resolve Node LTS index: {0}" -f $_.Exception.Message)
  }

  return @(
    'https://nodejs.org/dist/latest-v22.x/node-v22.13.1-win-x64.zip',
    'https://nodejs.org/dist/latest-v20.x/node-v20.19.0-win-x64.zip'
  )
}

function Ensure-NodeRuntime([string]$wingetExe) {
  if (Test-NpmAvailable) { return $true }

  if ($wingetExe) {
    try {
      Invoke-WithProxyPreference 'Node.js LTS (winget)' {
        [void](Install-WingetPackageIfMissing -wingetExe $wingetExe -id 'OpenJS.NodeJS.LTS')
      }
    } catch {}
    Refresh-SessionPath
    if (Test-NpmAvailable) { return $true }
  }

  $toolsRoot = Ensure-ToolsRoot
  $candidates = Get-NodeZipCandidates
  foreach ($zipUrl in $candidates) {
    try {
      $zipName = Split-Path -Path $zipUrl -Leaf
      if ([string]::IsNullOrWhiteSpace($zipName)) { continue }
      $zipPath = Join-Path $toolsRoot $zipName
      Invoke-DownloadFileWithProxyPreference -name "Node package $zipName" -url $zipUrl -destination $zipPath

      $extractName = [System.IO.Path]::GetFileNameWithoutExtension($zipName)
      $extractPath = Join-Path $toolsRoot $extractName
      if (Test-Path -LiteralPath $extractPath -PathType Container) {
        Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue
      }
      Expand-Archive -Path $zipPath -DestinationPath $toolsRoot -Force
      if (Test-Path -LiteralPath $extractPath -PathType Container) {
        $env:Path = $extractPath + ';' + $env:Path
      }
      if (Test-NpmAvailable) { return $true }
    } catch {
      Write-Host ("[sandbox] WARN: Node fallback candidate failed ({0}): {1}" -f $zipUrl, $_.Exception.Message)
    }
  }

  return (Test-NpmAvailable)
}

$script:StartedAt = (Get-Date).ToString('o')
Write-Status $false 'starting' 'bootstrap starting'

try {
  Start-Transcript -Path $LogFile -Append | Out-Null
  Write-Host ("[sandbox] run_id={0}" -f $script:RunId)
  Write-Host ("[sandbox] project_root={0}" -f $ProjectRoot)
  Write-Host ("[sandbox] offline_cache_root={0}" -f $OfflineCacheRoot)
  if (Test-Path -LiteralPath $OfflineCacheManifestFile -PathType Leaf) {
    Write-Host ("[sandbox] offline_cache_manifest={0}" -f $OfflineCacheManifestFile)
  }

  $wingetExe = Ensure-Winget
  if ($wingetExe) {
    Write-Host ("[sandbox] winget: {0}" -f $wingetExe)
  } else {
    Write-Host '[sandbox] winget not found; fallback installers will be used.'
  }

  try {
    Invoke-NetworkPreflight
  } catch {
    Add-BootstrapWarning ("network preflight failed unexpectedly: " + $_.Exception.Message)
  }

  Write-Host '[sandbox] installing toolchain...'
  Write-Status $false 'installing-toolchain' 'installing .NET + Node'
  $dotnetReady = $false
  $nodeReady = $false
  $npmPreInstalled = Test-NpmAvailable
  try {
    $dotnetReady = Ensure-DotNetSdk -wingetExe $wingetExe
  } catch {
    Add-BootstrapWarning (".NET install failed: " + $_.Exception.Message)
  }

  if (Enable-OfflineNodeRuntimeFromCache) {
    $nodeReady = $true
  }

  try {
    if (-not $nodeReady) {
      $nodeReady = Ensure-NodeRuntime -wingetExe $wingetExe
      if ($nodeReady -and $script:NodeSource -eq 'network') {
        if ($npmPreInstalled) {
          $script:NodeSource = 'preinstalled'
        } else {
          $script:NodeSource = 'online-install'
        }
      }
    }
  } catch {
    Add-BootstrapWarning ("Node install failed: " + $_.Exception.Message)
  }

  if (-not $dotnetReady) {
    Add-BootstrapWarning '.NET SDK 10 unavailable after all install attempts.'
  }
  if (-not $nodeReady) {
    $script:NodeSource = 'unavailable'
    Add-BootstrapWarning 'Node.js/npm unavailable after all install attempts.'
  }

  $playwrightVersion = ''
  $offlinePlaywrightReady = $false
  Write-Host '[sandbox] installing Playwright + chromium...'
  Write-Status $false 'installing-playwright' 'installing Playwright + Chromium'
  try {
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
      throw 'npm not found; cannot install Playwright.'
    }

    try {
      $offlinePlaywrightReady = Install-PlaywrightFromOfflineCache
    } catch {
      Add-BootstrapWarning ("offline Playwright cache attempt failed: " + $_.Exception.Message)
      $offlinePlaywrightReady = $false
    }

    if (-not $offlinePlaywrightReady) {
      Invoke-WithProxyPreference 'Playwright (npm + browser download)' {
        npm config set fund false | Out-Null
        npm config set audit false | Out-Null

        # Prefer direct download; npm may have persisted proxy settings from previous runs.
        try { npm config delete proxy | Out-Null } catch {}
        try { npm config delete https-proxy | Out-Null } catch {}

        npm i -g playwright@latest | Out-Null
        $pwCmd = Get-Command playwright -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pwCmd) {
          & $pwCmd.Source install chromium --with-deps | Out-Null
        } else {
          npx --yes playwright@latest install chromium --with-deps | Out-Null
        }
      }
      $script:PlaywrightSource = 'online-install'
    }

    $playwrightVersion = Get-PlaywrightVersion
    if ([string]::IsNullOrWhiteSpace($playwrightVersion)) {
      throw 'Playwright version probe failed after install.'
    }
    if (-not (Test-PlaywrightChromiumInstalled)) {
      throw 'Playwright chromium probe failed after install.'
    }

    Write-PlaywrightMarker -Success $true -Detail 'playwright sandbox ready' -Version $playwrightVersion -OfflineCacheUsed:$script:OfflineCacheUsed -NodeSource $script:NodeSource -PlaywrightSource $script:PlaywrightSource
  } catch {
    $offlineMissing = Get-OfflineCacheMissingSummary
    $detail = [string]$_.Exception.Message
    if ($detail -like '*version probe failed*') {
      $detail = ("{0} | probe_diag={1}" -f $detail, (Get-PlaywrightProbeDiagnostics))
    }
    if (-not [string]::IsNullOrWhiteSpace($offlineMissing)) {
      $detail = ("{0} | offline_cache_missing={1}" -f $detail, $offlineMissing)
    }
    $detail = ("{0} | network_preflight=npm:{1},nuget:{2},detail:{3}" -f $detail, $script:NetworkPreflight.npm, $script:NetworkPreflight.nuget, $script:NetworkPreflight.detail)
    $detail = ('{0} | hints=Host PowerShell执行 .\.Rayman\scripts\pwa\prepare_windows_sandbox_cache.ps1 预热离线包；确认窗口"Windows Sandbox"未被手动关闭；若仍失败请查看 {1} 与 {2}' -f $detail, $StatusFile, $LogFile)
    Write-PlaywrightMarker -Success $false -Detail $detail -Version $playwrightVersion -OfflineCacheUsed:$script:OfflineCacheUsed -NodeSource $script:NodeSource -PlaywrightSource $script:PlaywrightSource
    throw $detail
  }

  $Pfx = Join-Path $ProjectRoot '.Rayman\runtime\devcert.pfx'
  if (Test-Path $Pfx) {
    $Pass = $env:RAYMAN_DEVCERT_PASSWORD
    if (-not $Pass) { $Pass = 'rayman' }
    try {
      Write-Host '[sandbox] importing dev cert (best effort)'
      Write-Status $false 'installing-cert' 'importing dev cert (best effort)'
      certutil -f -p $Pass -importpfx Root $Pfx | Out-Null
    } catch {
      Write-Host '[sandbox] WARN: devcert import failed (non-blocking)'
    }
  }

  $readyMessage = 'bootstrap completed'
  if ($script:BootstrapWarnings.Count -gt 0) {
    $readyMessage = 'bootstrap completed with warnings: ' + ($script:BootstrapWarnings -join ' | ')
  }

  Write-Host '[sandbox] done'
  Write-Status $true 'ready' $readyMessage
} catch {
  $msg = $_.Exception.Message
  Write-Host "[sandbox] ERROR: $msg"
  Write-Status $false 'failed' 'bootstrap failed' $msg
  throw
} finally {
  try { Stop-Transcript | Out-Null } catch { }
}
