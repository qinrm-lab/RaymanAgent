param(
  [Alias('WorkspaceRoot')]
  [string]$ContextAuditWorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [Alias('Mode')]
  [ValidateSet('warn', 'block', 'off')]
  [string]$ContextAuditMode = 'warn',
  [Alias('InvocationSource')]
  [string]$ContextAuditInvocationSource = 'context-audit',
  [Alias('Json')]
  [switch]$ContextAuditJson,
  [Alias('NoMain')]
  [switch]$ContextAuditNoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
  . $commonPath
}
$eventHooksPath = Join-Path $PSScriptRoot '..\utils\event_hooks.ps1'
if (Test-Path -LiteralPath $eventHooksPath -PathType Leaf) {
  . $eventHooksPath -NoMain
}

function Resolve-RaymanContextAuditWorkspaceRoot {
  param([string]$WorkspaceRoot)

  if (Get-Command Resolve-RaymanWorkspaceRoot -ErrorAction SilentlyContinue) {
    return (Resolve-RaymanWorkspaceRoot -StartPath $WorkspaceRoot)
  }
  return (Resolve-Path -LiteralPath $WorkspaceRoot).Path
}

function Get-RaymanContextAuditEffectiveMode {
  param([string]$RequestedMode)

  $envMode = [Environment]::GetEnvironmentVariable('RAYMAN_CONTEXT_AUDIT_MODE')
  if (-not [string]::IsNullOrWhiteSpace($envMode)) {
    $normalized = $envMode.Trim().ToLowerInvariant()
    if ($normalized -in @('warn', 'block', 'off')) {
      return $normalized
    }
  }

  $disabled = [Environment]::GetEnvironmentVariable('RAYMAN_CONTEXT_AUDIT_DISABLED')
  if (-not [string]::IsNullOrWhiteSpace($disabled) -and $disabled -ne '0' -and $disabled -ne 'false' -and $disabled -ne 'False') {
    return 'off'
  }

  return ([string]$RequestedMode).Trim().ToLowerInvariant()
}

function Read-RaymanContextAuditJsonOrNull {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  try {
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Get-RaymanContextAuditDefaultSkillRoots {
  return @(
    [pscustomobject]@{
      path = '.github/skills'
      trust = 'managed'
      enabled = $true
      allowlisted = $true
    }
    [pscustomobject]@{
      path = '.Rayman/skills'
      trust = 'managed'
      enabled = $true
      allowlisted = $true
    }
  )
}

function Test-RaymanContextAuditTrustedSkillRoot {
  param([object]$Entry)

  if ($null -eq $Entry) {
    return $false
  }

  $enabled = if ($Entry.PSObject.Properties['enabled']) { [bool]$Entry.enabled } else { $true }
  if (-not $enabled) {
    return $false
  }

  $trust = if ($Entry.PSObject.Properties['trust']) {
    ([string]$Entry.trust).Trim().ToLowerInvariant()
  } else {
    'ignored'
  }
  if ($trust -eq 'managed') {
    return $true
  }

  $allowlisted = if ($Entry.PSObject.Properties['allowlisted']) { [bool]$Entry.allowlisted } else { $false }
  return ($trust -eq 'allowlisted' -and $allowlisted)
}

function Get-RaymanConfiguredSkillRoots {
  param([string]$WorkspaceRoot)

  $root = Resolve-RaymanContextAuditWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
  $registryPath = Join-Path $root '.Rayman\config\skills_registry.json'
  $results = New-Object System.Collections.Generic.List[string]
  $entries = New-Object System.Collections.Generic.List[object]

  if (Test-Path -LiteralPath $registryPath -PathType Leaf) {
    try {
      $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      foreach ($collectionName in @('roots', 'external_roots')) {
        if ($null -eq $registry.PSObject.Properties[$collectionName]) { continue }
        foreach ($entry in @($registry.$collectionName)) {
          if ($null -eq $entry) { continue }
          $entries.Add($entry) | Out-Null
        }
      }
    } catch {}
  }

  if ($entries.Count -eq 0) {
    foreach ($entry in @(Get-RaymanContextAuditDefaultSkillRoots)) {
      $entries.Add($entry) | Out-Null
    }
  }

  foreach ($entry in @($entries.ToArray())) {
    if (-not (Test-RaymanContextAuditTrustedSkillRoot -Entry $entry)) {
      continue
    }

    $pathText = if ($entry.PSObject.Properties['path']) { [string]$entry.path } else { '' }
    if ([string]::IsNullOrWhiteSpace($pathText)) { continue }
    $absolute = if ([System.IO.Path]::IsPathRooted($pathText)) { $pathText } else { Join-Path $root $pathText }
    if ($results -notcontains $absolute) {
      $results.Add($absolute) | Out-Null
    }
  }

  return @($results.ToArray())
}

function Get-RaymanContextAuditActiveSessionHandoverPaths {
  param([string]$WorkspaceRoot)

  $root = Resolve-RaymanContextAuditWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
  $stateDir = Join-Path $root '.Rayman\state'
  $results = New-Object System.Collections.Generic.List[string]
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  $activeFiles = New-Object System.Collections.Generic.List[string]

  $primaryActivePath = Join-Path $stateDir 'active_session.json'
  if (Test-Path -LiteralPath $primaryActivePath -PathType Leaf) {
    $activeFiles.Add($primaryActivePath) | Out-Null
  }

  $ownerActiveDir = Join-Path $stateDir 'active_sessions'
  foreach ($file in @(Get-ChildItem -LiteralPath $ownerActiveDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    $activeFiles.Add($file.FullName) | Out-Null
  }

  foreach ($activeFile in @($activeFiles.ToArray())) {
    $active = Read-RaymanContextAuditJsonOrNull -Path $activeFile
    if ($null -eq $active) { continue }

    $slug = if ($active.PSObject.Properties['slug']) { [string]$active.slug } else { '' }
    if ([string]::IsNullOrWhiteSpace($slug)) { continue }

    $sessionDir = Join-Path (Join-Path $stateDir 'sessions') $slug
    $manifestPath = Join-Path $sessionDir 'session.json'
    $handoverPath = Join-Path $sessionDir 'handover.md'
    $manifest = Read-RaymanContextAuditJsonOrNull -Path $manifestPath
    if ($null -ne $manifest -and $manifest.PSObject.Properties['handover_artifacts'] -and $manifest.handover_artifacts.PSObject.Properties['handover_path']) {
      $configuredPath = [string]$manifest.handover_artifacts.handover_path
      if (-not [string]::IsNullOrWhiteSpace($configuredPath)) {
        $handoverPath = if ([System.IO.Path]::IsPathRooted($configuredPath)) { $configuredPath } else { Join-Path $root $configuredPath }
      }
    }

    if ((Test-Path -LiteralPath $handoverPath -PathType Leaf) -and $seen.Add($handoverPath)) {
      $results.Add($handoverPath) | Out-Null
    }
  }

  return @($results.ToArray())
}

function Get-RaymanContextAuditTargets {
  param([string]$WorkspaceRoot)

  $root = Resolve-RaymanContextAuditWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
  $targets = New-Object System.Collections.Generic.List[object]
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

  function Add-Target {
    param(
      [string]$Path,
      [string]$SourceKind
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    if (-not $seen.Add($Path)) { return }
    $targets.Add([pscustomobject]@{
        path = $Path
        source_kind = $SourceKind
      }) | Out-Null
  }

  Add-Target -Path (Join-Path $root 'AGENTS.md') -SourceKind 'agents'
  Add-Target -Path (Join-Path $root '.Rayman\CONTEXT.md') -SourceKind 'managed_context'
  Add-Target -Path (Join-Path $root '.Rayman\context\skills.auto.md') -SourceKind 'auto_skills'
  Add-Target -Path (Join-Path $root '.Rayman\codex_fix_prompt.txt') -SourceKind 'managed_prompt'

  foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root '.github\prompts') -Filter '*.prompt.md' -File -ErrorAction SilentlyContinue)) {
    Add-Target -Path $file.FullName -SourceKind 'prompt_asset'
  }
  foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root '.github\instructions') -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
    Add-Target -Path $file.FullName -SourceKind 'instruction_asset'
  }
  foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root '.github\agents') -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
    Add-Target -Path $file.FullName -SourceKind 'agent_asset'
  }
  foreach ($skillRoot in @(Get-RaymanConfiguredSkillRoots -WorkspaceRoot $root)) {
    foreach ($file in @(Get-ChildItem -LiteralPath $skillRoot -Filter 'SKILL.md' -Recurse -File -ErrorAction SilentlyContinue)) {
      Add-Target -Path $file.FullName -SourceKind 'skill_manifest'
    }
  }
  foreach ($handoverPath in @(Get-RaymanContextAuditActiveSessionHandoverPaths -WorkspaceRoot $root)) {
    Add-Target -Path $handoverPath -SourceKind 'session_handover'
  }

  return @($targets.ToArray())
}

function Get-RaymanContextAuditRules {
  return @(
    [pscustomobject]@{
      kind = 'prompt_override'
      severity = 'block'
      pattern = '(?i)\b(ignore|disregard|override|bypass)\b.{0,48}\b(previous|prior|system|developer|safety|policy|instruction|instructions|guardrail|rules?)\b'
      summary = 'Prompt override language detected'
    }
    [pscustomobject]@{
      kind = 'secret_exfiltration'
      severity = 'block'
      pattern = '(?i)\b(reveal|dump|print|show|copy|upload|post|send|exfiltrat(?:e|ion)|leak)\b.{0,72}\b(secret|token|api[_ -]?key|credential|password|cookie|session|env(?:ironment)? variable)\b'
      summary = 'Secret exfiltration cue detected'
    }
    [pscustomobject]@{
      kind = 'unsafe_override'
      severity = 'block'
      pattern = '(?i)\b(you must|must now|instead|from now on)\b.{0,72}\b(ignore|disregard|replace|override|bypass)\b'
      summary = 'Unsafe override phrasing detected'
    }
  )
}

function Get-RaymanContextAuditRuleActionPattern {
  param([string]$RuleKind)

  switch ([string]$RuleKind) {
    'prompt_override' { return 'ignore|disregard|override|bypass' }
    'secret_exfiltration' { return 'reveal|dump|print|show|copy|upload|post|send|exfiltrat(?:e|ion)|leak' }
    'unsafe_override' { return 'ignore|disregard|replace|override|bypass' }
    default { return '' }
  }
}

function Get-RaymanContextAuditMatchLine {
  param(
    [string]$Text,
    [System.Text.RegularExpressions.Match]$Match
  )

  if ($null -eq $Match -or [string]::IsNullOrEmpty($Text)) {
    return ''
  }

  $lineStart = $Text.LastIndexOf("`n", [Math]::Max(0, $Match.Index - 1))
  if ($lineStart -lt 0) {
    $lineStart = 0
  } else {
    $lineStart++
  }
  $lineEnd = $Text.IndexOf("`n", $Match.Index + $Match.Length)
  if ($lineEnd -lt 0) {
    $lineEnd = $Text.Length
  }

  return $Text.Substring($lineStart, $lineEnd - $lineStart)
}

function Test-RaymanContextAuditQuotedExample {
  param(
    [string]$LineText,
    [string]$Evidence
  )

  if ([string]::IsNullOrWhiteSpace($LineText) -or [string]::IsNullOrWhiteSpace($Evidence)) {
    return $false
  }

  if ($LineText -notmatch '(?i)\b(example|for example|e\.g\.|sample|demo|prompt injection|attack string|malicious prompt|attacker|quoted|literal|pattern|marker|regex|scan for|look for|detect)\b') {
    return $false
  }

  $lineMatch = [regex]::Match($LineText, [regex]::Escape($Evidence.Trim()), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if (-not $lineMatch.Success) {
    return $false
  }

  $before = if ($lineMatch.Index -gt 0) { $LineText.Substring(0, $lineMatch.Index) } else { '' }
  $afterStart = $lineMatch.Index + $lineMatch.Length
  $after = if ($afterStart -lt $LineText.Length) { $LineText.Substring($afterStart) } else { '' }
  return ($before -match '[`"''“”‘’]' -and $after -match '[`"''“”‘’]')
}

function Test-RaymanContextAuditMatchIsDefensive {
  param(
    [string]$Text,
    [System.Text.RegularExpressions.Match]$Match,
    [string]$RuleKind
  )

  $lineText = Get-RaymanContextAuditMatchLine -Text $Text -Match $Match
  if ([string]::IsNullOrWhiteSpace($lineText)) {
    return $false
  }

  $actionPattern = Get-RaymanContextAuditRuleActionPattern -RuleKind $RuleKind
  if (-not [string]::IsNullOrWhiteSpace($actionPattern)) {
    $negatedActionPattern = ('(?i)\b(?:do not|don''t|dont|never|must not|should not|cannot|can''t|cant|禁止|不要|不得|不可|切勿|严禁)\b(?:\s+(?:ever|directly|simply|just|please))?\s+\b(?:' + $actionPattern + ')\b')
    if ($lineText -match $negatedActionPattern) {
      return $true
    }
  }

  return (Test-RaymanContextAuditQuotedExample -LineText $lineText -Evidence ([string]$Match.Value))
}

function Get-RaymanContextAuditOversizeIssue {
  param(
    [string]$Path,
    [string]$SourceKind,
    [string]$Text
  )

  $charCount = $Text.Length
  $lineCount = @($Text -split "`r?`n").Count
  if ($charCount -ge 250000 -or $lineCount -ge 6000) {
    return [pscustomobject]@{
      severity = 'block'
      kind = 'oversize_content'
      path = $Path
      source_kind = $SourceKind
      message = ("Content is too large for safe context consumption ({0} chars, {1} lines)." -f $charCount, $lineCount)
      evidence = ''
    }
  }
  if ($charCount -ge 120000 -or $lineCount -ge 2500) {
    return [pscustomobject]@{
      severity = 'warn'
      kind = 'oversize_content'
      path = $Path
      source_kind = $SourceKind
      message = ("Content is oversized and may truncate prompt context ({0} chars, {1} lines)." -f $charCount, $lineCount)
      evidence = ''
    }
  }
  return $null
}

function Test-RaymanContextAuditTarget {
  param(
    [string]$Path,
    [string]$SourceKind
  )

  $issues = New-Object System.Collections.Generic.List[object]
  $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  if ($null -eq $text) { $text = '' }

  $oversize = Get-RaymanContextAuditOversizeIssue -Path $Path -SourceKind $SourceKind -Text $text
  if ($null -ne $oversize) {
    $issues.Add($oversize) | Out-Null
  }

  foreach ($rule in @(Get-RaymanContextAuditRules)) {
    foreach ($match in [regex]::Matches($text, [string]$rule.pattern)) {
      if (Test-RaymanContextAuditMatchIsDefensive -Text $text -Match $match -RuleKind ([string]$rule.kind)) {
        continue
      }
      $evidence = [string]$match.Value
      if ($evidence.Length -gt 180) {
        $evidence = $evidence.Substring(0, 180) + '...'
      }
      $issues.Add([pscustomobject]@{
          severity = [string]$rule.severity
          kind = [string]$rule.kind
          path = $Path
          source_kind = $SourceKind
          message = [string]$rule.summary
          evidence = $evidence.Trim()
        }) | Out-Null
    }
  }

  return [pscustomobject]@{
    path = $Path
    source_kind = $SourceKind
    bytes = [Text.Encoding]::UTF8.GetByteCount($text)
    issues = @($issues.ToArray())
  }
}

function Write-RaymanContextAuditArtifacts {
  param(
    [string]$WorkspaceRoot,
    [object]$AuditResult
  )

  $root = Resolve-RaymanContextAuditWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
  $runtimeDir = Join-Path $root '.Rayman\runtime'
  if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
  }
  $jsonPath = Join-Path $runtimeDir 'context_audit.last.json'
  $mdPath = Join-Path $runtimeDir 'context_audit.last.md'
  ($AuditResult | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $jsonPath -Encoding UTF8

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# Rayman Context Audit') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add(("- mode: {0}" -f [string]$AuditResult.effective_mode)) | Out-Null
  $lines.Add(("- blocked: {0}" -f [string]([bool]$AuditResult.blocked).ToString().ToLowerInvariant())) | Out-Null
  $lines.Add(("- invocation_source: {0}" -f [string]$AuditResult.invocation_source)) | Out-Null
  $lines.Add(("- files_scanned: {0}" -f [int]$AuditResult.files_scanned)) | Out-Null
  $lines.Add(("- warning_count: {0}" -f [int]$AuditResult.warning_count)) | Out-Null
  $lines.Add(("- blocking_issue_count: {0}" -f [int]$AuditResult.blocking_issue_count)) | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add('## Issues') | Out-Null
  $lines.Add('') | Out-Null
  if (@($AuditResult.issues).Count -eq 0) {
    $lines.Add('- none') | Out-Null
  } else {
    foreach ($issue in @($AuditResult.issues)) {
      $relative = [string]$issue.path
      try {
        $relative = [System.IO.Path]::GetRelativePath($root, [string]$issue.path)
      } catch {}
      $detail = ("- [{0}] {1} :: {2}" -f [string]$issue.severity, $relative.Replace('\', '/'), [string]$issue.message)
      if (-not [string]::IsNullOrWhiteSpace([string]$issue.evidence)) {
        $detail += (' | evidence=`{0}`' -f [string]$issue.evidence)
      }
      $lines.Add($detail) | Out-Null
    }
  }
  Set-Content -LiteralPath $mdPath -Encoding UTF8 -Value ($lines -join "`r`n")

  return [pscustomobject]@{
    json_path = $jsonPath
    markdown_path = $mdPath
  }
}

function Invoke-RaymanContextAudit {
  [CmdletBinding()]
  param(
    [string]$WorkspaceRoot,
    [string]$Mode = 'warn',
    [string]$InvocationSource = 'context-audit'
  )

  $root = Resolve-RaymanContextAuditWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
  $effectiveMode = Get-RaymanContextAuditEffectiveMode -RequestedMode $Mode
  $targets = @(Get-RaymanContextAuditTargets -WorkspaceRoot $root)
  $issues = New-Object System.Collections.Generic.List[object]
  $bytesScanned = 0

  foreach ($target in $targets) {
    $targetResult = Test-RaymanContextAuditTarget -Path ([string]$target.path) -SourceKind ([string]$target.source_kind)
    $bytesScanned += [int64]$targetResult.bytes
    foreach ($issue in @($targetResult.issues)) {
      $issues.Add($issue) | Out-Null
    }
  }

  $warningCount = @($issues.ToArray() | Where-Object { [string]$_.severity -eq 'warn' }).Count
  $blockingIssueCount = @($issues.ToArray() | Where-Object { [string]$_.severity -eq 'block' }).Count
  $blocked = ($effectiveMode -eq 'block' -and $blockingIssueCount -gt 0)

  $result = [ordered]@{
    schema = 'rayman.context_audit.v1'
    success = (-not $blocked)
    blocked = $blocked
    requested_mode = [string]$Mode
    effective_mode = $effectiveMode
    invocation_source = [string]$InvocationSource
    workspace_root = $root
    generated_at = (Get-Date).ToString('o')
    files_scanned = $targets.Count
    bytes_scanned = $bytesScanned
    issue_count = $issues.Count
    warning_count = $warningCount
    blocking_issue_count = $blockingIssueCount
    issues = @($issues.ToArray())
  }
  $artifacts = Write-RaymanContextAuditArtifacts -WorkspaceRoot $root -AuditResult $result
  $result['artifacts'] = $artifacts

  if (Get-Command Write-RaymanEvent -ErrorAction SilentlyContinue) {
    Write-RaymanEvent -WorkspaceRoot $root -EventType 'context.audit' -Category 'context' -Payload $result | Out-Null
  }

  return [pscustomobject]$result
}

if (-not $ContextAuditNoMain) {
  $resolvedWorkspaceRoot = Resolve-RaymanContextAuditWorkspaceRoot -WorkspaceRoot $ContextAuditWorkspaceRoot
  $audit = Invoke-RaymanContextAudit -WorkspaceRoot $resolvedWorkspaceRoot -Mode $ContextAuditMode -InvocationSource $ContextAuditInvocationSource

  if ($ContextAuditJson) {
    $audit | ConvertTo-Json -Depth 16
  } else {
    Write-Host ("[context-audit] mode={0} blocked={1} issues={2}" -f [string]$audit.effective_mode, [string]([bool]$audit.blocked).ToString().ToLowerInvariant(), [int]$audit.issue_count)
    Write-Host ("[context-audit] artifacts: {0}" -f [string]$audit.artifacts.json_path) -ForegroundColor DarkCyan
    foreach ($issue in @($audit.issues | Select-Object -First 12)) {
      $relative = [string]$issue.path
      try {
        $relative = [System.IO.Path]::GetRelativePath($resolvedWorkspaceRoot, [string]$issue.path)
      } catch {}
      $color = if ([string]$issue.severity -eq 'block') { 'Red' } else { 'Yellow' }
      Write-Host (" - [{0}] {1}: {2}" -f [string]$issue.severity, $relative.Replace('\', '/'), [string]$issue.message) -ForegroundColor $color
    }
  }

  if ([bool]$audit.blocked) {
    exit 8
  }
}
