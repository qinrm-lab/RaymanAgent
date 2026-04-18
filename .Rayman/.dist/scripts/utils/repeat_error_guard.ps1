param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [string]$GuardStage = 'manual',
  [switch]$AsJson,
  [switch]$FailOnMatch,
  [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path 'Function:\Get-RaymanMapValue')) {
  function Get-RaymanMapValue {
    param(
      [object]$Map,
      [string]$Key,
      [object]$Default = $null
    )

    if ($null -eq $Map -or [string]::IsNullOrWhiteSpace($Key)) {
      return $Default
    }

    if ($Map -is [System.Collections.IDictionary]) {
      if ($Map.Contains($Key)) {
        return $Map[$Key]
      }
      foreach ($candidate in $Map.Keys) {
        if ([string]$candidate -ieq $Key) {
          return $Map[$candidate]
        }
      }
      return $Default
    }

    if ($Map.PSObject -and $Map.PSObject.Properties[$Key]) {
      return $Map.$Key
    }
    foreach ($property in @($Map.PSObject.Properties)) {
      if ([string]$property.Name -ieq $Key) {
        return $property.Value
      }
    }
    return $Default
  }
}

if (-not (Test-Path 'Function:\Write-RaymanUtf8NoBom')) {
  function Write-RaymanUtf8NoBom {
    param(
      [string]$Path,
      [string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
  }
}

function Get-RaymanRepeatErrorCatalogPath {
  param([string]$WorkspaceRoot)

  $workspacePath = Join-Path $WorkspaceRoot '.Rayman\context\repeat-error-catalog.json'
  if (Test-Path -LiteralPath $workspacePath -PathType Leaf) {
    return $workspacePath
  }

  $assetRoot = Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path
  return (Join-Path $assetRoot '.Rayman\context\repeat-error-catalog.json')
}

function Get-RaymanRepeatErrorGuardRuntimePath {
  param([string]$WorkspaceRoot)

  return (Join-Path $WorkspaceRoot '.Rayman\runtime\repeat_error_guard.last.json')
}

function Get-RaymanRepeatErrorCurrentConfigReferencePath {
  param([string]$WorkspaceRoot)

  $workspacePath = Join-Path $WorkspaceRoot '.Rayman\context\current-config-reference.md'
  if (Test-Path -LiteralPath $workspacePath -PathType Leaf) {
    return $workspacePath
  }

  $assetRoot = Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path
  return (Join-Path $assetRoot '.Rayman\context\current-config-reference.md')
}

function Get-RaymanRepeatErrorCatalog {
  param([string]$WorkspaceRoot)

  $path = Get-RaymanRepeatErrorCatalogPath -WorkspaceRoot $WorkspaceRoot
  $result = [ordered]@{
    schema = 'rayman.repeat_error_catalog.v1'
    path = $path
    present = $false
    parse_failed = $false
    parse_error = ''
    signatures = @()
  }

  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return [pscustomobject]$result
  }

  $result.present = $true
  try {
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $schema = [string](Get-RaymanMapValue -Map $raw -Key 'schema' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($schema)) {
      $result.schema = $schema
    }
    $result.signatures = @((Get-RaymanMapValue -Map $raw -Key 'signatures' -Default @()) | ForEach-Object { $_ })
  } catch {
    $result.parse_failed = $true
    $result.parse_error = $_.Exception.Message
  }

  return [pscustomobject]$result
}

function Get-RaymanRepeatErrorCatalogSignature {
  param(
    [object]$Catalog,
    [string]$SignatureId
  )

  foreach ($item in @((Get-RaymanMapValue -Map $Catalog -Key 'signatures' -Default @()) | ForEach-Object { $_ })) {
    if ([string](Get-RaymanMapValue -Map $item -Key 'signature_id' -Default '') -eq $SignatureId) {
      return $item
    }
  }
  return $null
}

function Get-RaymanRepeatErrorMarkdownValue {
  param(
    [string]$Text,
    [string]$Pattern
  )

  if ([string]::IsNullOrWhiteSpace($Text) -or [string]::IsNullOrWhiteSpace($Pattern)) {
    return ''
  }

  $match = [regex]::Match($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)
  if ($match.Success) {
    return [string]$match.Groups['value'].Value
  }
  return ''
}

function Get-RaymanCurrentConfigBaseline {
  param([string]$WorkspaceRoot)

  $path = Get-RaymanRepeatErrorCurrentConfigReferencePath -WorkspaceRoot $WorkspaceRoot
  $result = [ordered]@{
    path = $path
    present = $false
    parse_failed = $false
    parse_error = ''
    account_alias = ''
    authenticated = ''
    login_type = ''
    repair_command = ''
    proxy = [ordered]@{
      http_proxy = ''
      https_proxy = ''
      all_proxy = ''
      no_proxy = ''
    }
    memory = [ordered]@{
      search_backend = ''
      fallback_reason = ''
      deps_ready = ''
    }
  }

  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return [pscustomobject]$result
  }

  $result.present = $true
  try {
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $result.account_alias = Get-RaymanRepeatErrorMarkdownValue -Text $raw -Pattern 'Rayman 绑定账号别名：`(?<value>[^`]+)`'
    $result.authenticated = Get-RaymanRepeatErrorMarkdownValue -Text $raw -Pattern '认证状态：`(?<value>[^`]+)`'
    $result.login_type = Get-RaymanRepeatErrorMarkdownValue -Text $raw -Pattern '登录方式：`(?<value>[^`]+)`'
    $result.repair_command = Get-RaymanRepeatErrorMarkdownValue -Text $raw -Pattern '修复命令基线：`(?<value>[^`]+)`'
    $result.proxy.http_proxy = Get-RaymanRepeatErrorMarkdownValue -Text $raw -Pattern '^\s*-\s*`http_proxy=(?<value>[^`]+)`'
    $result.proxy.https_proxy = Get-RaymanRepeatErrorMarkdownValue -Text $raw -Pattern '^\s*-\s*`https_proxy=(?<value>[^`]+)`'
    $result.proxy.all_proxy = Get-RaymanRepeatErrorMarkdownValue -Text $raw -Pattern '^\s*-\s*`all_proxy=(?<value>[^`]+)`'
    $result.proxy.no_proxy = Get-RaymanRepeatErrorMarkdownValue -Text $raw -Pattern '^\s*-\s*`no_proxy=(?<value>[^`]+)`'
    $result.memory.search_backend = Get-RaymanRepeatErrorMarkdownValue -Text $raw -Pattern '当前检索后端：`(?<value>[^`]+)`'
    $result.memory.fallback_reason = Get-RaymanRepeatErrorMarkdownValue -Text $raw -Pattern 'fallback 原因：`(?<value>[^`]+)`'
    $depsRaw = Get-RaymanRepeatErrorMarkdownValue -Text $raw -Pattern '^\s*-\s*`deps_ready=(?<value>[^`]+)`'
    if (-not [string]::IsNullOrWhiteSpace($depsRaw)) {
      $result.memory.deps_ready = $depsRaw
    }
  } catch {
    $result.parse_failed = $true
    $result.parse_error = $_.Exception.Message
  }

  return [pscustomobject]$result
}

function Get-RaymanRepeatErrorProxyState {
  param([string]$WorkspaceRoot)

  $path = Join-Path $WorkspaceRoot '.Rayman\runtime\proxy.resolved.json'
  $result = [ordered]@{
    path = $path
    present = $false
    parse_failed = $false
    parse_error = ''
    source = ''
    http_proxy = ''
    https_proxy = ''
    all_proxy = ''
    no_proxy = ''
  }

  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return [pscustomobject]$result
  }

  $result.present = $true
  try {
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $result.source = [string](Get-RaymanMapValue -Map $raw -Key 'source' -Default '')
    $result.http_proxy = [string](Get-RaymanMapValue -Map $raw -Key 'http_proxy' -Default '')
    $result.https_proxy = [string](Get-RaymanMapValue -Map $raw -Key 'https_proxy' -Default '')
    $result.all_proxy = [string](Get-RaymanMapValue -Map $raw -Key 'all_proxy' -Default '')
    $result.no_proxy = [string](Get-RaymanMapValue -Map $raw -Key 'no_proxy' -Default '')
  } catch {
    $result.parse_failed = $true
    $result.parse_error = $_.Exception.Message
  }

  return [pscustomobject]$result
}

function Get-RaymanRepeatErrorMemoryStatus {
  param([string]$WorkspaceRoot)

  $path = Join-Path $WorkspaceRoot '.Rayman\runtime\memory\status.json'
  $result = [ordered]@{
    path = $path
    present = $false
    parse_failed = $false
    parse_error = ''
    success = $false
    search_backend = ''
    fallback_reason = ''
    deps_ready = $false
    message = ''
  }

  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return [pscustomobject]$result
  }

  $result.present = $true
  try {
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $result.success = [bool](Get-RaymanMapValue -Map $raw -Key 'success' -Default $false)
    $result.search_backend = [string](Get-RaymanMapValue -Map $raw -Key 'search_backend' -Default '')
    $result.fallback_reason = [string](Get-RaymanMapValue -Map $raw -Key 'fallback_reason' -Default '')
    $result.deps_ready = [bool](Get-RaymanMapValue -Map $raw -Key 'deps_ready' -Default $false)
    $result.message = [string](Get-RaymanMapValue -Map $raw -Key 'message' -Default '')
  } catch {
    $result.parse_failed = $true
    $result.parse_error = $_.Exception.Message
  }

  return [pscustomobject]$result
}

function Get-RaymanRepeatErrorCodexStatusFromRuntime {
  param([string]$WorkspaceRoot)

  $path = Join-Path $WorkspaceRoot '.Rayman\runtime\codex.auth.status.json'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return $null
  }

  try {
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}

function ConvertTo-RaymanRepeatGuardDesktopMode {
  param([string]$Mode)

  $normalized = if ([string]::IsNullOrWhiteSpace($Mode)) { '' } else { $Mode.Trim().ToLowerInvariant() }
  switch ($normalized) {
    'web' { return 'web' }
    'device' { return 'web' }
    'chatgpt' { return 'web' }
    'yunyi' { return 'yunyi' }
    'api' { return 'api' }
    'apikey' { return 'api' }
    'env_apikey' { return 'api' }
    default { return '' }
  }
}

function Resolve-RaymanRepeatErrorRepairCommand {
  param(
    [object]$Signature,
    [object]$CodexStatus,
    [object]$Baseline
  )

  $template = [string](Get-RaymanMapValue -Map $Signature -Key 'repair_command_template' -Default '')
  if ([string]::IsNullOrWhiteSpace($template)) {
    $template = [string](Get-RaymanMapValue -Map $CodexStatus -Key 'repair_command' -Default '')
  }
  if ([string]::IsNullOrWhiteSpace($template)) {
    $template = [string](Get-RaymanMapValue -Map $Baseline -Key 'repair_command' -Default '')
  }
  if ([string]::IsNullOrWhiteSpace($template)) {
    return ''
  }

  $alias = [string](Get-RaymanMapValue -Map $CodexStatus -Key 'account_alias' -Default '')
  if ([string]::IsNullOrWhiteSpace($alias)) {
    $alias = [string](Get-RaymanMapValue -Map $Baseline -Key 'account_alias' -Default '')
  }
  if (-not [string]::IsNullOrWhiteSpace($alias)) {
    $template = $template.Replace('{account_alias}', $alias)
  }
  return $template
}

function New-RaymanRepeatErrorMatch {
  param(
    [object]$Signature,
    [string]$Message,
    [string]$GuardStage,
    [string]$RepairCommand,
    [hashtable]$Evidence = @{}
  )

  return [pscustomobject]@{
    signature_id = [string](Get-RaymanMapValue -Map $Signature -Key 'signature_id' -Default '')
    title = [string](Get-RaymanMapValue -Map $Signature -Key 'title' -Default '')
    severity = [string](Get-RaymanMapValue -Map $Signature -Key 'severity' -Default 'warn')
    fail_fast = [bool](Get-RaymanMapValue -Map $Signature -Key 'fail_fast' -Default $false)
    guard_stage = [string]$GuardStage
    repair_command = [string]$RepairCommand
    message = [string]$Message
    baseline_keys = @((Get-RaymanMapValue -Map $Signature -Key 'baseline_keys' -Default @()) | ForEach-Object { [string]$_ })
    match_features = @((Get-RaymanMapValue -Map $Signature -Key 'match_features' -Default @()) | ForEach-Object { [string]$_ })
    evidence = [pscustomobject]$Evidence
  }
}

function Get-RaymanRepeatErrorGuardReport {
  param(
    [string]$WorkspaceRoot,
    [object]$CodexStatus = $null,
    [string]$GuardStage = 'manual'
  )

  $resolvedWorkspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $catalog = Get-RaymanRepeatErrorCatalog -WorkspaceRoot $resolvedWorkspace
  $baseline = Get-RaymanCurrentConfigBaseline -WorkspaceRoot $resolvedWorkspace
  $proxyState = Get-RaymanRepeatErrorProxyState -WorkspaceRoot $resolvedWorkspace
  $memoryState = Get-RaymanRepeatErrorMemoryStatus -WorkspaceRoot $resolvedWorkspace
  $effectiveCodexStatus = if ($null -ne $CodexStatus) { $CodexStatus } else { Get-RaymanRepeatErrorCodexStatusFromRuntime -WorkspaceRoot $resolvedWorkspace }
  $matches = New-Object System.Collections.Generic.List[object]

  $accountModeSignature = Get-RaymanRepeatErrorCatalogSignature -Catalog $catalog -SignatureId 'account_mode_mismatch'
  if ($null -ne $effectiveCodexStatus -and $null -ne $accountModeSignature) {
    $authScope = [string](Get-RaymanMapValue -Map $effectiveCodexStatus -Key 'auth_scope' -Default '')
    $targetMode = ConvertTo-RaymanRepeatGuardDesktopMode -Mode ([string](Get-RaymanMapValue -Map $effectiveCodexStatus -Key 'desktop_target_mode' -Default ''))
    $detectedMode = ConvertTo-RaymanRepeatGuardDesktopMode -Mode ([string](Get-RaymanMapValue -Map $effectiveCodexStatus -Key 'auth_mode_detected' -Default ''))
    if (
      $authScope -eq 'desktop_global' -and
      $targetMode -in @('web', 'yunyi') -and
      $detectedMode -in @('web', 'api') -and
      (
        ($targetMode -eq 'yunyi' -and $detectedMode -eq 'web') -or
        ($targetMode -eq 'web' -and $detectedMode -eq 'api')
      )
    ) {
      $message = "desktop target mode '$targetMode' conflicts with detected auth '$detectedMode'."
      $repair = Resolve-RaymanRepeatErrorRepairCommand -Signature $accountModeSignature -CodexStatus $effectiveCodexStatus -Baseline $baseline
      $matches.Add((New-RaymanRepeatErrorMatch -Signature $accountModeSignature -Message $message -GuardStage $GuardStage -RepairCommand $repair -Evidence @{
            auth_scope = $authScope
            desktop_target_mode = $targetMode
            auth_mode_detected = $detectedMode
            account_alias = [string](Get-RaymanMapValue -Map $effectiveCodexStatus -Key 'account_alias' -Default '')
          })) | Out-Null
    }
  }

  $desktopTargetSignature = Get-RaymanRepeatErrorCatalogSignature -Catalog $catalog -SignatureId 'desktop_target_mode_mismatch'
  if ($null -ne $effectiveCodexStatus -and $null -ne $desktopTargetSignature) {
    $authScope = [string](Get-RaymanMapValue -Map $effectiveCodexStatus -Key 'auth_scope' -Default '')
    $targetMode = ConvertTo-RaymanRepeatGuardDesktopMode -Mode ([string](Get-RaymanMapValue -Map $effectiveCodexStatus -Key 'desktop_target_mode' -Default ''))
    $lastLoginMode = ConvertTo-RaymanRepeatGuardDesktopMode -Mode ([string](Get-RaymanMapValue -Map $effectiveCodexStatus -Key 'last_login_mode' -Default ''))
    $authModeLast = ConvertTo-RaymanRepeatGuardDesktopMode -Mode ([string](Get-RaymanMapValue -Map $effectiveCodexStatus -Key 'auth_mode_last' -Default ''))
    $expectedMode = if (-not [string]::IsNullOrWhiteSpace($lastLoginMode)) { $lastLoginMode } else { $authModeLast }
    if (
      $authScope -eq 'desktop_global' -and
      $targetMode -in @('web', 'yunyi') -and
      $expectedMode -in @('web', 'yunyi') -and
      $targetMode -ne $expectedMode
    ) {
      $message = "desktop target mode '$targetMode' drifted away from saved login mode '$expectedMode'."
      $repair = Resolve-RaymanRepeatErrorRepairCommand -Signature $desktopTargetSignature -CodexStatus $effectiveCodexStatus -Baseline $baseline
      $matches.Add((New-RaymanRepeatErrorMatch -Signature $desktopTargetSignature -Message $message -GuardStage $GuardStage -RepairCommand $repair -Evidence @{
            auth_scope = $authScope
            desktop_target_mode = $targetMode
            last_login_mode = $lastLoginMode
            auth_mode_last = $authModeLast
          })) | Out-Null
    }
  }

  $proxySignature = Get-RaymanRepeatErrorCatalogSignature -Catalog $catalog -SignatureId 'proxy_baseline_drift'
  if ($null -ne $proxySignature -and [bool]$baseline.present -and [bool]$proxyState.present) {
    $driftedKeys = New-Object System.Collections.Generic.List[string]
    foreach ($key in @('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')) {
      $baselineValue = [string](Get-RaymanMapValue -Map $baseline.proxy -Key $key -Default '')
      $runtimeValue = [string](Get-RaymanMapValue -Map $proxyState -Key $key -Default '')
      if (-not [string]::IsNullOrWhiteSpace($baselineValue) -and $baselineValue -ne $runtimeValue) {
        $driftedKeys.Add($key) | Out-Null
      }
    }
    if ($driftedKeys.Count -gt 0) {
      $message = "resolved proxy drifted away from saved baseline for: {0}." -f (($driftedKeys | Select-Object -Unique) -join ', ')
      $repair = Resolve-RaymanRepeatErrorRepairCommand -Signature $proxySignature -CodexStatus $effectiveCodexStatus -Baseline $baseline
      $matches.Add((New-RaymanRepeatErrorMatch -Signature $proxySignature -Message $message -GuardStage $GuardStage -RepairCommand $repair -Evidence @{
            drifted_keys = @($driftedKeys | Select-Object -Unique)
            proxy_source = [string](Get-RaymanMapValue -Map $proxyState -Key 'source' -Default '')
          })) | Out-Null
    }
  }

  $desktopWindowSignature = Get-RaymanRepeatErrorCatalogSignature -Catalog $catalog -SignatureId 'desktop_window_misbind_or_timeout'
  if ($null -ne $effectiveCodexStatus -and $null -ne $desktopWindowSignature) {
    $authScope = [string](Get-RaymanMapValue -Map $effectiveCodexStatus -Key 'auth_scope' -Default '')
    $desktopReason = [string](Get-RaymanMapValue -Map $effectiveCodexStatus -Key 'desktop_status_reason' -Default '')
    $desktopQuotaVisible = [bool](Get-RaymanMapValue -Map $effectiveCodexStatus -Key 'desktop_status_quota_visible' -Default $false)
    $targetMode = ConvertTo-RaymanRepeatGuardDesktopMode -Mode ([string](Get-RaymanMapValue -Map $effectiveCodexStatus -Key 'desktop_target_mode' -Default ''))
    $detectedMode = ConvertTo-RaymanRepeatGuardDesktopMode -Mode ([string](Get-RaymanMapValue -Map $effectiveCodexStatus -Key 'auth_mode_detected' -Default ''))
    $nativeSession = Get-RaymanMapValue -Map $effectiveCodexStatus -Key 'latest_native_session' -Default $null
    $sessionAvailable = [bool](Get-RaymanMapValue -Map $nativeSession -Key 'available' -Default $false)
    $sessionSource = [string](Get-RaymanMapValue -Map $nativeSession -Key 'source' -Default '')
    if (
      $authScope -eq 'desktop_global' -and
      $targetMode -eq 'web' -and
      $detectedMode -eq 'web' -and
      -not $desktopQuotaVisible -and
      $desktopReason -in @('desktop_response_timeout', 'desktop_response_timeout_soft_pass', 'desktop_window_not_found', 'desktop_window_not_found_soft_pass') -and
      -not ($sessionAvailable -and $sessionSource -eq 'desktop_workspace_session')
    ) {
      $message = "desktop status validation ended with '$desktopReason' and no workspace session quota recovery was available."
      $repair = Resolve-RaymanRepeatErrorRepairCommand -Signature $desktopWindowSignature -CodexStatus $effectiveCodexStatus -Baseline $baseline
      $matches.Add((New-RaymanRepeatErrorMatch -Signature $desktopWindowSignature -Message $message -GuardStage $GuardStage -RepairCommand $repair -Evidence @{
            desktop_status_reason = $desktopReason
            latest_native_session_source = $sessionSource
            latest_native_session_available = $sessionAvailable
          })) | Out-Null
    }
  }

  $memorySignature = Get-RaymanRepeatErrorCatalogSignature -Catalog $catalog -SignatureId 'memory_backend_regression'
  if ($null -ne $memorySignature -and [bool]$baseline.present -and [bool]$memoryState.present) {
    $baselineBackend = [string](Get-RaymanMapValue -Map $baseline.memory -Key 'search_backend' -Default '')
    $baselineFallback = [string](Get-RaymanMapValue -Map $baseline.memory -Key 'fallback_reason' -Default '')
    $currentBackend = [string](Get-RaymanMapValue -Map $memoryState -Key 'search_backend' -Default '')
    $currentFallback = [string](Get-RaymanMapValue -Map $memoryState -Key 'fallback_reason' -Default '')
    $memoryRegression = $false
    $regressionReason = ''

    if (-not [bool](Get-RaymanMapValue -Map $memoryState -Key 'success' -Default $false)) {
      $memoryRegression = $true
      $regressionReason = 'memory status reports failure'
    } elseif ($baselineBackend -eq 'embedding' -and $currentBackend -ne 'embedding') {
      $memoryRegression = $true
      $regressionReason = "baseline backend '$baselineBackend' downgraded to '$currentBackend'"
    } elseif ($baselineBackend -eq 'lexical' -and -not [string]::IsNullOrWhiteSpace($baselineFallback) -and $currentBackend -eq 'lexical' -and $currentFallback -ne $baselineFallback) {
      $memoryRegression = $true
      $regressionReason = "lexical fallback changed from '$baselineFallback' to '$currentFallback'"
    } elseif ($baselineBackend -ne $currentBackend -and $currentBackend -eq '') {
      $memoryRegression = $true
      $regressionReason = 'memory backend is now unknown'
    }

    if ($memoryRegression) {
      $message = "Agent Memory backend drift detected: $regressionReason."
      $repair = Resolve-RaymanRepeatErrorRepairCommand -Signature $memorySignature -CodexStatus $effectiveCodexStatus -Baseline $baseline
      $matches.Add((New-RaymanRepeatErrorMatch -Signature $memorySignature -Message $message -GuardStage $GuardStage -RepairCommand $repair -Evidence @{
            baseline_backend = $baselineBackend
            baseline_fallback = $baselineFallback
            current_backend = $currentBackend
            current_fallback = $currentFallback
            deps_ready = [bool](Get-RaymanMapValue -Map $memoryState -Key 'deps_ready' -Default $false)
          })) | Out-Null
    }
  }

  $sortedMatches = @($matches.ToArray() | Sort-Object `
      @{ Expression = { if ([bool](Get-RaymanMapValue -Map $_ -Key 'fail_fast' -Default $false)) { 0 } else { 1 } } }, `
      @{ Expression = { switch ([string](Get-RaymanMapValue -Map $_ -Key 'severity' -Default 'warn')) { 'error' { 0 } 'warn' { 1 } default { 2 } } } }, `
      @{ Expression = { [string](Get-RaymanMapValue -Map $_ -Key 'signature_id' -Default '') } })
  $topMatch = if ($sortedMatches.Count -gt 0) { $sortedMatches[0] } else { $null }
  $summary = [ordered]@{
    matched = ($sortedMatches.Count -gt 0)
    fail_fast = if ($null -ne $topMatch) { [bool](Get-RaymanMapValue -Map $topMatch -Key 'fail_fast' -Default $false) } else { $false }
    top_signature = if ($null -ne $topMatch) { [string](Get-RaymanMapValue -Map $topMatch -Key 'signature_id' -Default '') } else { '' }
    top_severity = if ($null -ne $topMatch) { [string](Get-RaymanMapValue -Map $topMatch -Key 'severity' -Default '') } else { '' }
    repair_command = if ($null -ne $topMatch) { [string](Get-RaymanMapValue -Map $topMatch -Key 'repair_command' -Default '') } else { '' }
    message = if ($null -ne $topMatch) { [string](Get-RaymanMapValue -Map $topMatch -Key 'message' -Default '') } else { '' }
    count = $sortedMatches.Count
  }

  return [pscustomobject]@{
    schema = 'rayman.repeat_error_guard.report.v1'
    generated_at = (Get-Date).ToString('o')
    workspace_root = $resolvedWorkspace
    guard_stage = [string]$GuardStage
    catalog_path = [string](Get-RaymanMapValue -Map $catalog -Key 'path' -Default '')
    catalog_present = [bool](Get-RaymanMapValue -Map $catalog -Key 'present' -Default $false)
    config_reference_path = [string](Get-RaymanMapValue -Map $baseline -Key 'path' -Default '')
    config_reference_present = [bool](Get-RaymanMapValue -Map $baseline -Key 'present' -Default $false)
    codex_status_present = ($null -ne $effectiveCodexStatus)
    codex_status_probe = if ($null -ne $effectiveCodexStatus) {
      [pscustomobject]@{
        account_alias = [string](Get-RaymanMapValue -Map $effectiveCodexStatus -Key 'account_alias' -Default '')
        auth_scope = [string](Get-RaymanMapValue -Map $effectiveCodexStatus -Key 'auth_scope' -Default '')
        auth_mode_detected = [string](Get-RaymanMapValue -Map $effectiveCodexStatus -Key 'auth_mode_detected' -Default '')
        auth_mode_last = [string](Get-RaymanMapValue -Map $effectiveCodexStatus -Key 'auth_mode_last' -Default '')
        last_login_mode = [string](Get-RaymanMapValue -Map $effectiveCodexStatus -Key 'last_login_mode' -Default '')
        desktop_target_mode = [string](Get-RaymanMapValue -Map $effectiveCodexStatus -Key 'desktop_target_mode' -Default '')
        desktop_status_reason = [string](Get-RaymanMapValue -Map $effectiveCodexStatus -Key 'desktop_status_reason' -Default '')
        desktop_status_quota_visible = [bool](Get-RaymanMapValue -Map $effectiveCodexStatus -Key 'desktop_status_quota_visible' -Default $false)
      }
    } else {
      $null
    }
    summary = [pscustomobject]$summary
    matches = @($sortedMatches)
  }
}

function Write-RaymanRepeatErrorGuardRuntimeReport {
  param(
    [string]$WorkspaceRoot,
    [object]$Report
  )

  $path = Get-RaymanRepeatErrorGuardRuntimePath -WorkspaceRoot $WorkspaceRoot
  $json = ($Report | ConvertTo-Json -Depth 12)
  Write-RaymanUtf8NoBom -Path $path -Content ($json.TrimEnd() + "`n")
  return $path
}

function Write-RaymanRepeatErrorGuardText {
  param(
    [object]$Report,
    [string]$Prefix = '[repeat-error]'
  )

  $summary = Get-RaymanMapValue -Map $Report -Key 'summary' -Default $null
  $matches = @((Get-RaymanMapValue -Map $Report -Key 'matches' -Default @()) | ForEach-Object { $_ })
  if (-not [bool](Get-RaymanMapValue -Map $summary -Key 'matched' -Default $false)) {
    Write-Host ("{0} no known repeated runtime errors detected." -f $Prefix) -ForegroundColor DarkGray
    return
  }

  foreach ($match in $matches) {
    $signature = [string](Get-RaymanMapValue -Map $match -Key 'signature_id' -Default '')
    $severity = [string](Get-RaymanMapValue -Map $match -Key 'severity' -Default 'warn')
    $blocked = [bool](Get-RaymanMapValue -Map $match -Key 'fail_fast' -Default $false)
    $message = [string](Get-RaymanMapValue -Map $match -Key 'message' -Default '')
    $repair = [string](Get-RaymanMapValue -Map $match -Key 'repair_command' -Default '')
    $color = if ($blocked -or $severity -eq 'error') { 'Yellow' } else { 'DarkYellow' }
    Write-Host ("{0} signature={1} severity={2} blocked={3} stage={4}" -f $Prefix, $signature, $severity, $blocked.ToString().ToLowerInvariant(), [string](Get-RaymanMapValue -Map $match -Key 'guard_stage' -Default '')) -ForegroundColor $color
    if (-not [string]::IsNullOrWhiteSpace($message)) {
      Write-Host ("{0} detail={1}" -f $Prefix, $message) -ForegroundColor Gray
    }
    if (-not [string]::IsNullOrWhiteSpace($repair)) {
      Write-Host ("{0} repair={1}" -f $Prefix, $repair) -ForegroundColor Gray
    }
  }
}

if (-not $NoMain) {
  $resolvedWorkspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $report = Get-RaymanRepeatErrorGuardReport -WorkspaceRoot $resolvedWorkspace -GuardStage $GuardStage
  Write-RaymanRepeatErrorGuardRuntimeReport -WorkspaceRoot $resolvedWorkspace -Report $report | Out-Null
  if ($AsJson) {
    $report | ConvertTo-Json -Depth 12
  } else {
    Write-RaymanRepeatErrorGuardText -Report $report
  }

  if ($FailOnMatch -and [bool](Get-RaymanMapValue -Map (Get-RaymanMapValue -Map $report -Key 'summary' -Default $null) -Key 'fail_fast' -Default $false)) {
    exit 6
  }
}
