Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RaymanNowIso() {
  return (Get-Date).ToString('o')
}

function Ensure-RaymanDirectory([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Read-RaymanJsonOrNull([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Write-RaymanJsonNoBom([string]$Path, [object]$Value) {
  $json = ($Value | ConvertTo-Json -Depth 16)
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $json, $enc)
}

function Write-RaymanTextNoBom([string]$Path, [string]$Text) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Get-RaymanPropValue([object]$Object, [string]$Name, $DefaultValue = $null) {
  if ($null -eq $Object) { return $DefaultValue }
  if ($Object -is [System.Collections.IDictionary]) {
    if ($Object.Contains($Name)) { return $Object[$Name] }
    return $DefaultValue
  }
  $prop = $Object.PSObject.Properties[$Name]
  if ($null -eq $prop) { return $DefaultValue }
  if ($null -eq $prop.Value) { return $DefaultValue }
  return $prop.Value
}

function ConvertTo-RaymanBool([object]$Value, [bool]$Default = $false) {
  if ($null -eq $Value) { return $Default }
  if ($Value -is [bool]) { return [bool]$Value }
  $raw = [string]$Value
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

function Get-RaymanBoolEnvOverride([string]$Name, [bool]$Default) {
  $raw = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
  return (ConvertTo-RaymanBool -Value $raw -Default $Default)
}

function ConvertTo-RaymanSemVersion([string]$Raw) {
  if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
  $text = [string]$Raw
  $match = [System.Text.RegularExpressions.Regex]::Match($text, '(\d+)\.(\d+)\.(\d+)')
  if ($match.Success) {
    return [Version]::new([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value)
  }

  $match2 = [System.Text.RegularExpressions.Regex]::Match($text, '(\d+)\.(\d+)')
  if ($match2.Success) {
    return [Version]::new([int]$match2.Groups[1].Value, [int]$match2.Groups[2].Value, 0)
  }

  return $null
}

function Test-RaymanVersionAtLeast([string]$DetectedVersion, [string]$MinimumVersion) {
  $detected = ConvertTo-RaymanSemVersion -Raw $DetectedVersion
  $minimum = ConvertTo-RaymanSemVersion -Raw $MinimumVersion
  if ($null -eq $detected) {
    return [pscustomobject]@{
      ok = $false
      reason = 'detected_version_unknown'
      detected = $DetectedVersion
      minimum = $MinimumVersion
    }
  }
  if ($null -eq $minimum) {
    return [pscustomobject]@{
      ok = $true
      reason = 'minimum_version_invalid_treated_as_pass'
      detected = $DetectedVersion
      minimum = $MinimumVersion
    }
  }

  $cmp = $detected.CompareTo($minimum)
  return [pscustomobject]@{
    ok = ($cmp -ge 0)
    reason = if ($cmp -ge 0) { 'version_ok' } else { 'below_minimum' }
    detected = $DetectedVersion
    minimum = $MinimumVersion
  }
}

function Get-RaymanToolVersionProbe {
  param(
    [string]$CommandName,
    [string[]]$VersionArgs = @('--version')
  )

  $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $cmd) {
    return [pscustomobject]@{
      command = $CommandName
      command_available = $false
      raw = ''
      first_line = ''
      version = ''
      version_detected = $false
    }
  }

  $raw = ''
  try {
    $out = & $cmd.Source @VersionArgs 2>&1
    $raw = ((@($out) | ForEach-Object { [string]$_ }) -join "`n").Trim()
  } catch {
    $raw = [string]$_.Exception.Message
  }

  $firstLine = ''
  if (-not [string]::IsNullOrWhiteSpace($raw)) {
    $firstLine = (([string]$raw -split "(\r\n|\n|\r)")[0]).Trim()
  }

  $parsedVersion = ''
  $parsed = $false
  $versionObj = ConvertTo-RaymanSemVersion -Raw $firstLine
  if ($null -ne $versionObj) {
    $parsed = $true
    $parsedVersion = ('{0}.{1}.{2}' -f $versionObj.Major, $versionObj.Minor, $versionObj.Build)
  }

  return [pscustomobject]@{
    command = $CommandName
    command_available = $true
    raw = $raw
    first_line = $firstLine
    version = $parsedVersion
    version_detected = $parsed
  }
}

function Get-RaymanSystemSlimDefaultPolicy() {
  return [ordered]@{
    schema = 'rayman.system_slim.policy.v1'
    enabled = $true
    notify_on_upgrade = $true
    minimum_versions = [ordered]@{
      vscode = '1.110.0'
      codex = '0.5.80'
    }
    features = [ordered]@{
      dispatch = [ordered]@{
        enabled = $true
        mode = 'delegate'
        delegate_target = 'codex.exec'
      }
      review_loop = [ordered]@{
        enabled = $false
        mode = 'keep'
      }
    }
  }
}

function Get-RaymanSystemSlimPolicy {
  param([string]$WorkspaceRoot)

  $workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $policyPath = Join-Path $workspace '.Rayman\config\system_slim_policy.json'
  $defaultPolicy = Get-RaymanSystemSlimDefaultPolicy
  $raw = Read-RaymanJsonOrNull -Path $policyPath

  if ($null -ne $raw) {
    $schema = [string](Get-RaymanPropValue -Object $raw -Name 'schema' -DefaultValue $defaultPolicy.schema)
    if ([string]::IsNullOrWhiteSpace($schema)) { $schema = $defaultPolicy.schema }
    $defaultPolicy.schema = $schema

    $defaultPolicy.enabled = ConvertTo-RaymanBool -Value (Get-RaymanPropValue -Object $raw -Name 'enabled' -DefaultValue $defaultPolicy.enabled) -Default $defaultPolicy.enabled
    $defaultPolicy.notify_on_upgrade = ConvertTo-RaymanBool -Value (Get-RaymanPropValue -Object $raw -Name 'notify_on_upgrade' -DefaultValue $defaultPolicy.notify_on_upgrade) -Default $defaultPolicy.notify_on_upgrade

    $minimumRaw = Get-RaymanPropValue -Object $raw -Name 'minimum_versions' -DefaultValue $null
    if ($null -ne $minimumRaw) {
      $vscodeMin = [string](Get-RaymanPropValue -Object $minimumRaw -Name 'vscode' -DefaultValue $defaultPolicy.minimum_versions.vscode)
      $codexMin = [string](Get-RaymanPropValue -Object $minimumRaw -Name 'codex' -DefaultValue $defaultPolicy.minimum_versions.codex)
      if (-not [string]::IsNullOrWhiteSpace($vscodeMin)) { $defaultPolicy.minimum_versions.vscode = $vscodeMin }
      if (-not [string]::IsNullOrWhiteSpace($codexMin)) { $defaultPolicy.minimum_versions.codex = $codexMin }
    }

    $featuresRaw = Get-RaymanPropValue -Object $raw -Name 'features' -DefaultValue $null
    if ($null -ne $featuresRaw) {
      $dispatchRaw = Get-RaymanPropValue -Object $featuresRaw -Name 'dispatch' -DefaultValue $null
      if ($null -ne $dispatchRaw) {
        $defaultPolicy.features.dispatch.enabled = ConvertTo-RaymanBool -Value (Get-RaymanPropValue -Object $dispatchRaw -Name 'enabled' -DefaultValue $defaultPolicy.features.dispatch.enabled) -Default $defaultPolicy.features.dispatch.enabled

        $dispatchMode = [string](Get-RaymanPropValue -Object $dispatchRaw -Name 'mode' -DefaultValue $defaultPolicy.features.dispatch.mode)
        if (-not [string]::IsNullOrWhiteSpace($dispatchMode)) { $defaultPolicy.features.dispatch.mode = $dispatchMode.Trim().ToLowerInvariant() }

        $delegateTarget = [string](Get-RaymanPropValue -Object $dispatchRaw -Name 'delegate_target' -DefaultValue $defaultPolicy.features.dispatch.delegate_target)
        if (-not [string]::IsNullOrWhiteSpace($delegateTarget)) { $defaultPolicy.features.dispatch.delegate_target = $delegateTarget.Trim() }
      }

      $reviewRaw = Get-RaymanPropValue -Object $featuresRaw -Name 'review_loop' -DefaultValue $null
      if ($null -ne $reviewRaw) {
        $defaultPolicy.features.review_loop.enabled = ConvertTo-RaymanBool -Value (Get-RaymanPropValue -Object $reviewRaw -Name 'enabled' -DefaultValue $defaultPolicy.features.review_loop.enabled) -Default $defaultPolicy.features.review_loop.enabled

        $reviewMode = [string](Get-RaymanPropValue -Object $reviewRaw -Name 'mode' -DefaultValue $defaultPolicy.features.review_loop.mode)
        if (-not [string]::IsNullOrWhiteSpace($reviewMode)) { $defaultPolicy.features.review_loop.mode = $reviewMode.Trim().ToLowerInvariant() }
      }
    }
  }

  $defaultPolicy.enabled = Get-RaymanBoolEnvOverride -Name 'RAYMAN_SYSTEM_SLIM_ENABLED' -Default $defaultPolicy.enabled
  $defaultPolicy.notify_on_upgrade = Get-RaymanBoolEnvOverride -Name 'RAYMAN_SYSTEM_SLIM_NOTIFY_ON_UPGRADE' -Default $defaultPolicy.notify_on_upgrade

  return [pscustomobject]@{
    path = $policyPath
    data = $defaultPolicy
  }
}

function Invoke-RaymanSystemSlimAudit {
  param(
    [string]$WorkspaceRoot,
    [string]$Source = 'manual'
  )

  $workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $runtimeDir = Join-Path $workspace '.Rayman\runtime'
  Ensure-RaymanDirectory -Path $runtimeDir

  $snapshotPath = Join-Path $runtimeDir 'system_slim.snapshot.json'
  $previousPath = Join-Path $runtimeDir 'system_slim.previous.json'
  $reportPath = Join-Path $runtimeDir 'system_slim.report.md'
  $eventsPath = Join-Path $runtimeDir 'system_slim.events.log'

  $policyInfo = Get-RaymanSystemSlimPolicy -WorkspaceRoot $workspace
  $policy = $policyInfo.data

  $vscodeProbe = Get-RaymanToolVersionProbe -CommandName 'code'
  $codexProbe = Get-RaymanToolVersionProbe -CommandName 'codex'

  $vscodeMin = [string](Get-RaymanPropValue -Object $policy.minimum_versions -Name 'vscode' -DefaultValue '1.110.0')
  $codexMin = [string](Get-RaymanPropValue -Object $policy.minimum_versions -Name 'codex' -DefaultValue '0.5.80')

  $vscodeAtLeast = Test-RaymanVersionAtLeast -DetectedVersion ([string]$vscodeProbe.version) -MinimumVersion $vscodeMin
  $codexAtLeast = Test-RaymanVersionAtLeast -DetectedVersion ([string]$codexProbe.version) -MinimumVersion $codexMin

  $dispatchFeatureRaw = Get-RaymanPropValue -Object $policy.features -Name 'dispatch' -DefaultValue @{}
  $dispatchEnabled = ConvertTo-RaymanBool -Value (Get-RaymanPropValue -Object $dispatchFeatureRaw -Name 'enabled' -DefaultValue $true) -Default $true
  $dispatchMode = [string](Get-RaymanPropValue -Object $dispatchFeatureRaw -Name 'mode' -DefaultValue 'delegate')
  if ([string]::IsNullOrWhiteSpace($dispatchMode)) { $dispatchMode = 'delegate' }
  $dispatchMode = $dispatchMode.Trim().ToLowerInvariant()

  $dispatchDelegateTarget = [string](Get-RaymanPropValue -Object $dispatchFeatureRaw -Name 'delegate_target' -DefaultValue 'codex.exec')
  if ([string]::IsNullOrWhiteSpace($dispatchDelegateTarget)) { $dispatchDelegateTarget = 'codex.exec' }
  $dispatchDelegateTarget = $dispatchDelegateTarget.Trim()

  $dispatchActive = $false
  $dispatchReason = ''
  if (-not [bool]$policy.enabled) {
    $dispatchReason = 'policy_disabled'
  } elseif (-not $dispatchEnabled) {
    $dispatchReason = 'feature_disabled'
  } elseif ($dispatchMode -ne 'delegate') {
    $dispatchReason = ('unsupported_mode:{0}' -f $dispatchMode)
  } elseif (-not [bool]$codexProbe.command_available) {
    $dispatchReason = 'codex_command_missing'
  } elseif (-not [bool]$codexProbe.version_detected) {
    $dispatchReason = 'codex_version_unknown'
  } elseif (-not [bool]$codexAtLeast.ok) {
    $dispatchReason = ('codex_below_minimum:{0}<{1}' -f [string]$codexProbe.version, $codexMin)
  } else {
    $dispatchActive = $true
    $dispatchReason = 'delegate_codex_exec'
  }

  $reviewFeatureRaw = Get-RaymanPropValue -Object $policy.features -Name 'review_loop' -DefaultValue @{}
  $reviewEnabled = ConvertTo-RaymanBool -Value (Get-RaymanPropValue -Object $reviewFeatureRaw -Name 'enabled' -DefaultValue $false) -Default $false
  $reviewMode = [string](Get-RaymanPropValue -Object $reviewFeatureRaw -Name 'mode' -DefaultValue 'keep')
  if ([string]::IsNullOrWhiteSpace($reviewMode)) { $reviewMode = 'keep' }
  $reviewMode = $reviewMode.Trim().ToLowerInvariant()

  $reviewActive = $false
  $reviewReason = ''
  if (-not [bool]$policy.enabled) {
    $reviewReason = 'policy_disabled'
  } elseif (-not $reviewEnabled) {
    $reviewReason = 'feature_disabled_by_policy'
  } elseif ($reviewMode -eq 'keep') {
    $reviewReason = 'keep_rayman_review_loop'
  } else {
    $reviewReason = ('unsupported_mode:{0}' -f $reviewMode)
  }

  $activeFeatures = New-Object System.Collections.Generic.List[string]
  if ($dispatchActive) { [void]$activeFeatures.Add('dispatch -> codex exec') }
  if ($reviewActive) { [void]$activeFeatures.Add('review-loop -> delegated') }

  $baseline = $null
  if (Test-Path -LiteralPath $snapshotPath -PathType Leaf) {
    $baseline = Read-RaymanJsonOrNull -Path $snapshotPath
  } elseif (Test-Path -LiteralPath $previousPath -PathType Leaf) {
    $baseline = Read-RaymanJsonOrNull -Path $previousPath
  }

  if (Test-Path -LiteralPath $snapshotPath -PathType Leaf) {
    Copy-Item -LiteralPath $snapshotPath -Destination $previousPath -Force
  }

  $upgradedTools = New-Object System.Collections.Generic.List[string]
  $versionChangedTools = New-Object System.Collections.Generic.List[string]

  foreach ($toolName in @('vscode', 'codex')) {
    $prevDetected = [string](Get-RaymanPropValue -Object (Get-RaymanPropValue -Object $baseline -Name 'detected_versions' -DefaultValue $null) -Name $toolName -DefaultValue '')
    $currDetected = if ($toolName -eq 'vscode') { [string]$vscodeProbe.version } else { [string]$codexProbe.version }

    if (-not [string]::Equals($prevDetected, $currDetected, [System.StringComparison]::OrdinalIgnoreCase)) {
      [void]$versionChangedTools.Add($toolName)
    }

    $prevVer = ConvertTo-RaymanSemVersion -Raw $prevDetected
    $currVer = ConvertTo-RaymanSemVersion -Raw $currDetected
    if ($null -ne $prevVer -and $null -ne $currVer -and ($currVer.CompareTo($prevVer) -gt 0)) {
      [void]$upgradedTools.Add($toolName)
    }
  }

  $upgradeDetected = ($upgradedTools.Count -gt 0)

  $snapshot = [ordered]@{
    schema = 'rayman.system_slim.snapshot.v1'
    generated_at = Get-RaymanNowIso
    source = $Source
    workspace_root = $workspace
    policy_path = $policyInfo.path
    policy_enabled = [bool]$policy.enabled
    notify_on_upgrade = [bool]$policy.notify_on_upgrade
    minimum_versions = [ordered]@{
      vscode = $vscodeMin
      codex = $codexMin
    }
    detected_versions = [ordered]@{
      vscode = [string]$vscodeProbe.version
      codex = [string]$codexProbe.version
    }
    probe = [ordered]@{
      vscode = [ordered]@{
        command_available = [bool]$vscodeProbe.command_available
        first_line = [string]$vscodeProbe.first_line
        raw = [string]$vscodeProbe.raw
        version_detected = [bool]$vscodeProbe.version_detected
      }
      codex = [ordered]@{
        command_available = [bool]$codexProbe.command_available
        first_line = [string]$codexProbe.first_line
        raw = [string]$codexProbe.raw
        version_detected = [bool]$codexProbe.version_detected
      }
    }
    version_checks = [ordered]@{
      vscode = $vscodeAtLeast
      codex = $codexAtLeast
    }
    features = [ordered]@{
      dispatch = [ordered]@{
        enabled = $dispatchEnabled
        mode = $dispatchMode
        delegate_target = $dispatchDelegateTarget
        active = $dispatchActive
        reason = $dispatchReason
      }
      review_loop = [ordered]@{
        enabled = $reviewEnabled
        mode = $reviewMode
        active = $reviewActive
        reason = $reviewReason
      }
    }
    active_features = @($activeFeatures)
    upgrade_detected = $upgradeDetected
    upgraded_tools = @($upgradedTools)
    changed_tools = @($versionChangedTools)
    snapshot_path = $snapshotPath
    previous_path = $previousPath
    report_path = $reportPath
    events_path = $eventsPath
  }

  Write-RaymanJsonNoBom -Path $snapshotPath -Value $snapshot

  $reportLines = New-Object System.Collections.Generic.List[string]
  $reportLines.Add('# Rayman System Slim Report') | Out-Null
  $reportLines.Add('') | Out-Null
  $reportLines.Add(('- generated_at: {0}' -f $snapshot.generated_at)) | Out-Null
  $reportLines.Add(('- source: {0}' -f $Source)) | Out-Null
  $reportLines.Add(('- policy_path: {0}' -f $policyInfo.path)) | Out-Null
  $reportLines.Add(('- runtime_snapshot: {0}' -f $snapshotPath)) | Out-Null
  $reportLines.Add('') | Out-Null

  $reportLines.Add('## Active Delegations') | Out-Null
  $reportLines.Add('') | Out-Null
  if ($activeFeatures.Count -gt 0) {
    foreach ($item in $activeFeatures) {
      $reportLines.Add(('- {0}' -f $item)) | Out-Null
    }
  } else {
    $reportLines.Add('- (none)') | Out-Null
  }
  $reportLines.Add('') | Out-Null

  $reportLines.Add('## Non-slim Features And Reasons') | Out-Null
  $reportLines.Add('') | Out-Null
  $reportLines.Add(('- dispatch: {0}' -f $dispatchReason)) | Out-Null
  $reportLines.Add(('- review-loop: {0}' -f $reviewReason)) | Out-Null
  $reportLines.Add('') | Out-Null

  $reportLines.Add('## Detected Versions') | Out-Null
  $reportLines.Add('') | Out-Null
  $reportLines.Add('| tool | version | minimum | command_available |') | Out-Null
  $reportLines.Add('| --- | --- | --- | --- |') | Out-Null
  $reportLines.Add(('| vscode | {0} | {1} | {2} |' -f ([string]$vscodeProbe.version), $vscodeMin, [string]$vscodeProbe.command_available)) | Out-Null
  $reportLines.Add(('| codex | {0} | {1} | {2} |' -f ([string]$codexProbe.version), $codexMin, [string]$codexProbe.command_available)) | Out-Null
  $reportLines.Add('') | Out-Null

  $reportLines.Add('## Version Change') | Out-Null
  $reportLines.Add('') | Out-Null
  if ($null -eq $baseline) {
    $reportLines.Add('- first snapshot: no previous baseline found.') | Out-Null
  } else {
    foreach ($toolName in @('vscode', 'codex')) {
      $prevDetected = [string](Get-RaymanPropValue -Object (Get-RaymanPropValue -Object $baseline -Name 'detected_versions' -DefaultValue $null) -Name $toolName -DefaultValue '')
      $currDetected = if ($toolName -eq 'vscode') { [string]$vscodeProbe.version } else { [string]$codexProbe.version }
      if ([string]::IsNullOrWhiteSpace($prevDetected)) { $prevDetected = '(unknown)' }
      if ([string]::IsNullOrWhiteSpace($currDetected)) { $currDetected = '(unknown)' }
      $upgradeTag = if ($upgradedTools -contains $toolName) { 'upgraded' } else { 'no-upgrade' }
      $reportLines.Add(('- {0}: {1} -> {2} ({3})' -f $toolName, $prevDetected, $currDetected, $upgradeTag)) | Out-Null
    }
  }
  $reportLines.Add('') | Out-Null

  $reportLines.Add('## Reminder') | Out-Null
  $reportLines.Add('') | Out-Null
  if ($upgradeDetected -and [bool]$policy.notify_on_upgrade) {
    $reportLines.Add('- Detected tool upgrade. Consider whether more Rayman features should be slimmed to system-native implementations.') | Out-Null
  } else {
    $reportLines.Add('- No upgrade reminder triggered in this run.') | Out-Null
  }
  $reportLines.Add('') | Out-Null

  Write-RaymanTextNoBom -Path $reportPath -Text ($reportLines -join "`r`n")

  $eventLine = ('{0} source={1} upgrade_detected={2} upgraded_tools={3} active_features={4} report={5}' -f (Get-RaymanNowIso), $Source, $upgradeDetected, (($upgradedTools -join ',') -replace '\s+', ''), (($activeFeatures -join '|') -replace '\s+', '_'), $reportPath)
  Add-Content -LiteralPath $eventsPath -Encoding UTF8 -Value $eventLine

  return [pscustomobject]@{
    success = $true
    source = $Source
    policy_path = $policyInfo.path
    policy_enabled = [bool]$policy.enabled
    notify_on_upgrade = [bool]$policy.notify_on_upgrade
    snapshot_path = $snapshotPath
    previous_path = $previousPath
    report_path = $reportPath
    events_log_path = $eventsPath
    active_features = @($activeFeatures)
    upgrade_detected = $upgradeDetected
    upgraded_tools = @($upgradedTools)
    detected_versions = [pscustomobject]@{
      vscode = [string]$vscodeProbe.version
      codex = [string]$codexProbe.version
    }
    features = [pscustomobject]@{
      dispatch = [pscustomobject]$snapshot.features.dispatch
      review_loop = [pscustomobject]$snapshot.features.review_loop
    }
  }
}
