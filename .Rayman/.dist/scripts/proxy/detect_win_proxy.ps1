param(
  [string]$WorkspaceRoot = $((Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path)
)

. "$PSScriptRoot\..\..\common.ps1"

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ObjectValueCaseInsensitive([object]$Object, [string]$Name) {
  if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Name)) { return $null }
  if ($Object -is [System.Collections.IDictionary]) {
    foreach ($k in $Object.Keys) {
      if ([string]$k -ieq $Name) { return $Object[$k] }
    }
  }
  foreach ($p in $Object.PSObject.Properties) {
    if ($p.Name -ieq $Name) { return $p.Value }
  }
  return $null
}

function Get-SettingValue([object]$Settings, [string]$FlatKey, [string[]]$NestedPath) {
  $v = Get-ObjectValueCaseInsensitive -Object $Settings -Name $FlatKey
  if ($null -ne $v) { return $v }

  $current = $Settings
  foreach ($segment in $NestedPath) {
    if ($null -eq $current) { return $null }
    $current = Get-ObjectValueCaseInsensitive -Object $current -Name $segment
  }
  return $current
}

function Remove-JsonComments([string]$Text) {
  if ([string]::IsNullOrEmpty($Text)) { return $Text }
  $sb = New-Object System.Text.StringBuilder
  $inString = $false
  $escapeNext = $false
  $inLineComment = $false
  $inBlockComment = $false
  for ($i = 0; $i -lt $Text.Length; $i++) {
    $c = $Text[$i]
    $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }

    if ($inLineComment) {
      if ($c -eq "`n") {
        $inLineComment = $false
        [void]$sb.Append($c)
      }
      continue
    }

    if ($inBlockComment) {
      if ($c -eq '*' -and $next -eq '/') {
        $inBlockComment = $false
        $i++
      }
      continue
    }

    if ($inString) {
      [void]$sb.Append($c)
      if ($escapeNext) {
        $escapeNext = $false
      } elseif ($c -eq '\') {
        $escapeNext = $true
      } elseif ($c -eq '"') {
        $inString = $false
      }
      continue
    }

    if ($c -eq '"') {
      $inString = $true
      [void]$sb.Append($c)
      continue
    }

    if ($c -eq '/' -and $next -eq '/') {
      $inLineComment = $true
      $i++
      continue
    }

    if ($c -eq '/' -and $next -eq '*') {
      $inBlockComment = $true
      $i++
      continue
    }

    [void]$sb.Append($c)
  }
  return $sb.ToString()
}

function Remove-JsonTrailingCommas([string]$Text) {
  if ([string]::IsNullOrEmpty($Text)) { return $Text }
  $sb = New-Object System.Text.StringBuilder
  $inString = $false
  $escapeNext = $false
  for ($i = 0; $i -lt $Text.Length; $i++) {
    $c = $Text[$i]
    if ($inString) {
      [void]$sb.Append($c)
      if ($escapeNext) {
        $escapeNext = $false
      } elseif ($c -eq '\') {
        $escapeNext = $true
      } elseif ($c -eq '"') {
        $inString = $false
      }
      continue
    }

    if ($c -eq '"') {
      $inString = $true
      [void]$sb.Append($c)
      continue
    }

    if ($c -eq ',') {
      $j = $i + 1
      while ($j -lt $Text.Length -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
      if ($j -lt $Text.Length -and ($Text[$j] -eq '}' -or $Text[$j] -eq ']')) {
        continue
      }
    }

    [void]$sb.Append($c)
  }
  return $sb.ToString()
}

function ConvertFrom-JsonC([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $noComment = Remove-JsonComments -Text $Text
  $clean = Remove-JsonTrailingCommas -Text $noComment
  return ($clean | ConvertFrom-Json -ErrorAction Stop)
}

function Normalize-ProxyUrl([object]$Value) {
  if ($null -eq $Value) { return $null }
  $raw = [string]$Value
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  $raw = $raw.Trim()
  if ($raw -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') { return $raw }
  return "http://$raw"
}

function Normalize-NoProxy([object]$Value) {
  if ($null -eq $Value) { return $null }
  $raw = [string]$Value
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  $parts = @()
  foreach ($p in ($raw -split '[,;]')) {
    $t = $p.Trim()
    if (-not [string]::IsNullOrWhiteSpace($t) -and $t -ne '<local>') { $parts += $t }
  }
  if ($parts.Count -eq 0) { return $null }
  return ($parts -join ',')
}

function Normalize-ProxyRecord([hashtable]$Proxy) {
  $Proxy.http_proxy = Normalize-ProxyUrl $Proxy.http_proxy
  $Proxy.https_proxy = Normalize-ProxyUrl $Proxy.https_proxy
  $Proxy.all_proxy = Normalize-ProxyUrl $Proxy.all_proxy
  $Proxy.no_proxy = Normalize-NoProxy $Proxy.no_proxy

  $single = $null
  if ($Proxy.http_proxy) { $single = $Proxy.http_proxy }
  elseif ($Proxy.https_proxy) { $single = $Proxy.https_proxy }
  elseif ($Proxy.all_proxy) { $single = $Proxy.all_proxy }

  if ($single) {
    if (-not $Proxy.http_proxy) { $Proxy.http_proxy = $single }
    if (-not $Proxy.https_proxy) { $Proxy.https_proxy = $single }
    if (-not $Proxy.all_proxy) { $Proxy.all_proxy = $single }
  }

  if (($Proxy.http_proxy -or $Proxy.https_proxy -or $Proxy.all_proxy) -and -not $Proxy.no_proxy) {
    $Proxy.no_proxy = 'localhost,127.0.0.1,::1'
  }

  return $Proxy
}

function Decode-JsonStringLiteral([string]$Encoded) {
  if ($null -eq $Encoded) { return $null }
  try {
    $wrapped = '"' + $Encoded + '"'
    return ($wrapped | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $Encoded
  }
}

function Get-JsonStringValueByFlatKey([string]$Text, [string]$Key) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $pattern = '(?s)"' + [regex]::Escape($Key) + '"\s*:\s*"((?:\\.|[^"\\])*)"'
  $m = [regex]::Match($Text, $pattern)
  if (-not $m.Success) { return $null }
  return Decode-JsonStringLiteral -Encoded $m.Groups[1].Value
}

function Get-JsonObjectBodyByFlatKey([string]$Text, [string]$Key) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $prefixPattern = '"' + [regex]::Escape($Key) + '"\s*:'
  $m = [regex]::Match($Text, $prefixPattern)
  if (-not $m.Success) { return $null }

  $i = $m.Index + $m.Length
  while ($i -lt $Text.Length -and [char]::IsWhiteSpace($Text[$i])) { $i++ }
  if ($i -ge $Text.Length -or $Text[$i] -ne '{') { return $null }

  $start = $i + 1
  $depth = 1
  $inString = $false
  $escapeNext = $false
  for ($j = $start; $j -lt $Text.Length; $j++) {
    $c = $Text[$j]
    if ($inString) {
      if ($escapeNext) {
        $escapeNext = $false
      } elseif ($c -eq '\') {
        $escapeNext = $true
      } elseif ($c -eq '"') {
        $inString = $false
      }
      continue
    }

    if ($c -eq '"') {
      $inString = $true
      continue
    }

    if ($c -eq '{') {
      $depth++
      continue
    }

    if ($c -eq '}') {
      $depth--
      if ($depth -eq 0) {
        return $Text.Substring($start, $j - $start)
      }
    }
  }

  return $null
}

function Get-ProxyFromSettingsTextFallback([string]$CleanText, [string]$SourceName) {
  $proxy = @{
    source      = $SourceName
    http_proxy  = $null
    https_proxy = $null
    all_proxy   = $null
    no_proxy    = $null
  }

  $envBody = Get-JsonObjectBodyByFlatKey -Text $CleanText -Key 'terminal.integrated.env.windows'
  if ($envBody) {
    $proxy.http_proxy = Get-JsonStringValueByFlatKey -Text $envBody -Key 'http_proxy'
    if (-not $proxy.http_proxy) { $proxy.http_proxy = Get-JsonStringValueByFlatKey -Text $envBody -Key 'HTTP_PROXY' }

    $proxy.https_proxy = Get-JsonStringValueByFlatKey -Text $envBody -Key 'https_proxy'
    if (-not $proxy.https_proxy) { $proxy.https_proxy = Get-JsonStringValueByFlatKey -Text $envBody -Key 'HTTPS_PROXY' }

    $proxy.all_proxy = Get-JsonStringValueByFlatKey -Text $envBody -Key 'all_proxy'
    if (-not $proxy.all_proxy) { $proxy.all_proxy = Get-JsonStringValueByFlatKey -Text $envBody -Key 'ALL_PROXY' }

    $proxy.no_proxy = Get-JsonStringValueByFlatKey -Text $envBody -Key 'no_proxy'
    if (-not $proxy.no_proxy) { $proxy.no_proxy = Get-JsonStringValueByFlatKey -Text $envBody -Key 'NO_PROXY' }
  }

  $httpProxy = Get-JsonStringValueByFlatKey -Text $CleanText -Key 'http.proxy'
  if (-not $httpProxy) {
    $httpObj = Get-JsonObjectBodyByFlatKey -Text $CleanText -Key 'http'
    if ($httpObj) {
      $httpProxy = Get-JsonStringValueByFlatKey -Text $httpObj -Key 'proxy'
    }
  }

  if ($httpProxy) {
    if (-not $proxy.http_proxy) { $proxy.http_proxy = $httpProxy }
    if (-not $proxy.https_proxy) { $proxy.https_proxy = $httpProxy }
    if (-not $proxy.all_proxy) { $proxy.all_proxy = $httpProxy }
  }

  $proxy = Normalize-ProxyRecord -Proxy $proxy
  if (-not $proxy.http_proxy -and -not $proxy.https_proxy -and -not $proxy.all_proxy) { return $null }
  return $proxy
}

function Get-ProxyFromSettingsFile([string]$SettingsPath, [string]$SourceName) {
  if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) { return $null }
  try {
    $raw = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8
    $clean = Remove-JsonTrailingCommas -Text (Remove-JsonComments -Text $raw)

    $settings = $null
    $parseError = $null
    try {
      $settings = ($clean | ConvertFrom-Json -ErrorAction Stop)
    } catch {
      $parseError = $_.Exception.Message
    }

    $proxyFromObject = $null
    if ($settings) {
      $proxyFromObject = @{
        source      = $SourceName
        http_proxy  = $null
        https_proxy = $null
        all_proxy   = $null
        no_proxy    = $null
      }

      $envObj = Get-SettingValue -Settings $settings -FlatKey 'terminal.integrated.env.windows' -NestedPath @('terminal', 'integrated', 'env', 'windows')
      if ($envObj) {
        $proxyFromObject.http_proxy = Get-ObjectValueCaseInsensitive -Object $envObj -Name 'http_proxy'
        if (-not $proxyFromObject.http_proxy) { $proxyFromObject.http_proxy = Get-ObjectValueCaseInsensitive -Object $envObj -Name 'HTTP_PROXY' }

        $proxyFromObject.https_proxy = Get-ObjectValueCaseInsensitive -Object $envObj -Name 'https_proxy'
        if (-not $proxyFromObject.https_proxy) { $proxyFromObject.https_proxy = Get-ObjectValueCaseInsensitive -Object $envObj -Name 'HTTPS_PROXY' }

        $proxyFromObject.all_proxy = Get-ObjectValueCaseInsensitive -Object $envObj -Name 'all_proxy'
        if (-not $proxyFromObject.all_proxy) { $proxyFromObject.all_proxy = Get-ObjectValueCaseInsensitive -Object $envObj -Name 'ALL_PROXY' }

        $proxyFromObject.no_proxy = Get-ObjectValueCaseInsensitive -Object $envObj -Name 'no_proxy'
        if (-not $proxyFromObject.no_proxy) { $proxyFromObject.no_proxy = Get-ObjectValueCaseInsensitive -Object $envObj -Name 'NO_PROXY' }
      }

      $httpProxy = Get-SettingValue -Settings $settings -FlatKey 'http.proxy' -NestedPath @('http', 'proxy')
      if ($httpProxy) {
        if (-not $proxyFromObject.http_proxy) { $proxyFromObject.http_proxy = $httpProxy }
        if (-not $proxyFromObject.https_proxy) { $proxyFromObject.https_proxy = $httpProxy }
        if (-not $proxyFromObject.all_proxy) { $proxyFromObject.all_proxy = $httpProxy }
      }

      $proxyFromObject = Normalize-ProxyRecord -Proxy $proxyFromObject
      if (-not $proxyFromObject.http_proxy -and -not $proxyFromObject.https_proxy -and -not $proxyFromObject.all_proxy) {
        $proxyFromObject = $null
      }
    }

    if ($proxyFromObject) { return $proxyFromObject }

    $proxyFromText = Get-ProxyFromSettingsTextFallback -CleanText $clean -SourceName $SourceName
    if ($proxyFromText) {
      if ($parseError) {
        Write-Info ("Proxy settings loaded with text fallback: {0}" -f $SettingsPath)
      }
      return $proxyFromText
    }

    if ($parseError) {
      Write-Warn ("Proxy settings parse failed: {0} ({1})" -f $SettingsPath, $parseError)
    }
    return $null
  } catch {
    Write-Warn ("Proxy settings parse failed: {0} ({1})" -f $SettingsPath, $_.Exception.Message)
    return $null
  }
}

function Get-ProxyFromSystem() {
  try {
    $k = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    $enable = (Get-ItemProperty -Path $k -Name ProxyEnable -ErrorAction Stop).ProxyEnable
    if ($enable -ne 1) { return $null }

    $server = (Get-ItemProperty -Path $k -Name ProxyServer -ErrorAction Stop).ProxyServer
    if ([string]::IsNullOrWhiteSpace([string]$server)) { return $null }

    $proxy = @{
      source      = 'system proxy'
      http_proxy  = $null
      https_proxy = $null
      all_proxy   = $null
      no_proxy    = $null
    }

    if ($server -match '=') {
      foreach ($segment in ($server -split ';')) {
        if ($segment -match '^\s*([^=]+)\s*=\s*(.+)\s*$') {
          $key = $Matches[1].Trim().ToLowerInvariant()
          $value = $Matches[2].Trim()
          switch ($key) {
            'http' { $proxy.http_proxy = $value }
            'https' { $proxy.https_proxy = $value }
            'socks' { if (-not $proxy.all_proxy) { $proxy.all_proxy = $value } }
            default { if (-not $proxy.all_proxy) { $proxy.all_proxy = $value } }
          }
        }
      }
    } else {
      $proxy.http_proxy = $server.Trim()
      $proxy.https_proxy = $server.Trim()
      $proxy.all_proxy = $server.Trim()
    }

    try {
      $override = (Get-ItemProperty -Path $k -Name ProxyOverride -ErrorAction Stop).ProxyOverride
      if ($override) { $proxy.no_proxy = $override }
    } catch {}

    $proxy = Normalize-ProxyRecord -Proxy $proxy
    if (-not $proxy.http_proxy -and -not $proxy.https_proxy -and -not $proxy.all_proxy) { return $null }
    return $proxy
  } catch {
    Write-Warn ("System proxy read failed: {0}" -f $_.Exception.Message)
    return $null
  }
}

function Get-UserSettingsCandidates() {
  $candidates = New-Object System.Collections.Generic.List[string]

  $customPath = [Environment]::GetEnvironmentVariable('RAYMAN_PROXY_USER_SETTINGS_PATH')
  if (-not [string]::IsNullOrWhiteSpace($customPath)) {
    try {
      $resolvedCustom = (Resolve-Path -LiteralPath $customPath -ErrorAction Stop).Path
      $candidates.Add($resolvedCustom)
    } catch {
      # ignore invalid custom path
    }
  }

  foreach ($relative in @(
      'Code\User\settings.json',
      'Code - Insiders\User\settings.json',
      'VSCodium\User\settings.json'
    )) {
    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
      $path = Join-Path $env:APPDATA $relative
      if (Test-Path -LiteralPath $path -PathType Leaf) {
        $candidates.Add($path)
      }
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
    $profilesRoot = Join-Path $env:APPDATA 'Code\User\profiles'
    if (Test-Path -LiteralPath $profilesRoot -PathType Container) {
      try {
        $profileSettings = Get-ChildItem -LiteralPath $profilesRoot -Directory -ErrorAction Stop |
          ForEach-Object { Join-Path $_.FullName 'settings.json' } |
          Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
          Sort-Object { (Get-Item -LiteralPath $_).LastWriteTime } -Descending
        foreach ($s in $profileSettings) {
          $candidates.Add($s)
        }
      } catch {
        # ignore profile scan failures
      }
    }
  }

  return $candidates | Select-Object -Unique
}

function Set-ProxyEnv([hashtable]$Proxy) {
  $map = @{
    'http_proxy'  = $Proxy.http_proxy
    'https_proxy' = $Proxy.https_proxy
    'all_proxy'   = $Proxy.all_proxy
    'no_proxy'    = $Proxy.no_proxy
  }
  foreach ($k in $map.Keys) {
    $upper = $k.ToUpperInvariant()
    $v = $map[$k]
    if ([string]::IsNullOrWhiteSpace([string]$v)) {
      Remove-Item -Path "Env:$k" -ErrorAction SilentlyContinue
      Remove-Item -Path "Env:$upper" -ErrorAction SilentlyContinue
    } else {
      Set-Item -Path ("Env:{0}" -f $k) -Value $v
      Set-Item -Path ("Env:{0}" -f $upper) -Value $v
    }
  }
}

function Clear-ProxyEnv() {
  foreach ($k in @('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')) {
    $upper = $k.ToUpperInvariant()
    Remove-Item -Path "Env:$k" -ErrorAction SilentlyContinue
    Remove-Item -Path "Env:$upper" -ErrorAction SilentlyContinue
  }
}

function Convert-ToFileSystemLiteralPath([string]$PathValue) {
  if ([string]::IsNullOrWhiteSpace($PathValue)) { return $PathValue }
  $prefix = 'Microsoft.PowerShell.Core\FileSystem::'
  if ($PathValue.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $PathValue.Substring($prefix.Length)
  }
  return $PathValue
}

function Write-ProxySnapshot([string]$Root, [hashtable]$Proxy, [string]$Source) {
  $runtimeDir = Join-Path $Root '.Rayman\runtime'
  $runtimeDir = Convert-ToFileSystemLiteralPath -PathValue $runtimeDir
  if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
  }

  $payload = [ordered]@{
    source      = $Source
    http_proxy  = if ($Proxy) { $Proxy.http_proxy } else { $null }
    https_proxy = if ($Proxy) { $Proxy.https_proxy } else { $null }
    all_proxy   = if ($Proxy) { $Proxy.all_proxy } else { $null }
    no_proxy    = if ($Proxy) { $Proxy.no_proxy } else { $null }
    resolvedAt  = (Get-Date).ToString('o')
  }

  $snapshotPath = Join-Path $runtimeDir 'proxy.resolved.json'
  $json = $payload | ConvertTo-Json -Depth 8
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  try {
    [System.IO.File]::WriteAllText($snapshotPath, $json, $utf8NoBom)
  } catch {
    Set-Content -LiteralPath $snapshotPath -Value $json -Encoding UTF8
  }
  return $snapshotPath
}

try {
  $WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $workspaceSettings = Join-Path $WorkspaceRoot '.vscode\settings.json'
  $proxy = $null

  $resolveOrder = [Environment]::GetEnvironmentVariable('RAYMAN_PROXY_RESOLVE_ORDER')
  if ([string]::IsNullOrWhiteSpace($resolveOrder)) {
    $resolveOrder = 'user,workspace,system'
  }

  $userSettingsCandidates = @(Get-UserSettingsCandidates)
  $steps = @($resolveOrder -split '[,;\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim().ToLowerInvariant() })
  foreach ($step in $steps) {
    if ($proxy) { break }
    switch ($step) {
      'user' {
        foreach ($candidate in $userSettingsCandidates) {
          $proxy = Get-ProxyFromSettingsFile -SettingsPath $candidate -SourceName ("user settings: {0}" -f $candidate)
          if ($proxy) { break }
        }
      }
      'workspace' {
        $proxy = Get-ProxyFromSettingsFile -SettingsPath $workspaceSettings -SourceName 'workspace settings'
      }
      'system' {
        $proxy = Get-ProxyFromSystem
      }
      default {
        # ignore unknown token
      }
    }
  }

  if (-not $proxy) {
    foreach ($candidate in $userSettingsCandidates) {
      $proxy = Get-ProxyFromSettingsFile -SettingsPath $candidate -SourceName ("user settings: {0}" -f $candidate)
      if ($proxy) { break }
    }
  }
  if (-not $proxy) {
    $proxy = Get-ProxyFromSettingsFile -SettingsPath $workspaceSettings -SourceName 'workspace settings'
  }
  if (-not $proxy) {
    $proxy = Get-ProxyFromSystem
  }

  if ($proxy) {
    Set-ProxyEnv -Proxy $proxy
    $env:RAYMAN_PROXY_SOURCE = [string]$proxy.source
    Write-Info ("Proxy detected: {0}" -f $proxy.source)
    Write-Info ("proxy.http={0}" -f $proxy.http_proxy)
    Write-Info ("proxy.https={0}" -f $proxy.https_proxy)
    Write-Info ("proxy.all={0}" -f $proxy.all_proxy)
    if ($proxy.no_proxy) {
      Write-Info ("proxy.no={0}" -f $proxy.no_proxy)
    }
  } else {
    Clear-ProxyEnv
    $env:RAYMAN_PROXY_SOURCE = 'none'
    Write-Warn "未检测到可用代理（workspace/user settings 与系统代理均未命中）。"
  }

  $snapshotPath = Write-ProxySnapshot -Root $WorkspaceRoot -Proxy $proxy -Source $env:RAYMAN_PROXY_SOURCE
  Write-Info ("Proxy snapshot: {0}" -f $snapshotPath)
} catch {
  Write-Warn ("Proxy detect failed: {0}" -f $_.Exception.Message)
}
