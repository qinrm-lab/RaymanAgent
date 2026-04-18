param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [ValidateSet('list', 'audit')][string]$Action = 'list',
  [switch]$Json,
  [switch]$NoMain
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

function Resolve-RaymanSkillsWorkspaceRoot {
  param([string]$WorkspaceRoot)

  if (Get-Command Resolve-RaymanWorkspaceRoot -ErrorAction SilentlyContinue) {
    return (Resolve-RaymanWorkspaceRoot -StartPath $WorkspaceRoot)
  }
  return (Resolve-Path -LiteralPath $WorkspaceRoot).Path
}

function Get-RaymanSkillChecksum {
  param([string]$Path)

  $cmd = Get-Command Get-FileHash -ErrorAction SilentlyContinue
  if ($null -ne $cmd) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  }

  $sha = [System.Security.Cryptography.SHA256]::Create()
  $stream = [System.IO.File]::OpenRead($Path)
  try {
    $bytes = $sha.ComputeHash($stream)
    return ([System.BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
  } finally {
    try { $stream.Dispose() } catch {}
    try { $sha.Dispose() } catch {}
  }
}

function Get-RaymanSkillsRelativePath {
  param(
    [string]$BasePath,
    [string]$TargetPath
  )

  if ([string]::IsNullOrWhiteSpace([string]$TargetPath)) {
    return ''
  }

  $resolvedTargetPath = $TargetPath
  try {
    $resolvedTargetPath = [System.IO.Path]::GetFullPath([string]$TargetPath)
  } catch {}

  if ([string]::IsNullOrWhiteSpace([string]$BasePath)) {
    return ($resolvedTargetPath -replace '\\', '/')
  }

  $resolvedBasePath = $BasePath
  try {
    $resolvedBasePath = [System.IO.Path]::GetFullPath([string]$BasePath)
  } catch {}

  $normalizedBase = ($resolvedBasePath -replace '/', '\').TrimEnd('\')
  $normalizedTarget = ($resolvedTargetPath -replace '/', '\')
  if ($normalizedTarget.Equals($normalizedBase, [System.StringComparison]::OrdinalIgnoreCase)) {
    return ''
  }

  $prefix = $normalizedBase + '\'
  if ($normalizedTarget.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $normalizedTarget.Substring($prefix.Length).Replace('\', '/')
  }

  try {
    $baseUri = [Uri](([System.IO.Path]::GetFullPath($normalizedBase).TrimEnd('\') + '\'))
    $targetUri = [Uri]([System.IO.Path]::GetFullPath($normalizedTarget))
    return ([Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString())).Replace('\', '/')
  } catch {
    return ($resolvedTargetPath -replace '\\', '/')
  }
}

function Get-RaymanSkillsRegistry {
  param([string]$WorkspaceRoot)

  $root = Resolve-RaymanSkillsWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
  $path = Join-Path $root '.Rayman\config\skills_registry.json'
  $default = [pscustomobject]@{
    schema = 'rayman.skills_registry.v1'
    duplicate_resolution = 'prefer_managed'
    roots = @(
      [pscustomobject]@{
        id = 'github-managed-skills'
        path = '.github/skills'
        source_kind = 'bundled'
        trust = 'managed'
        enabled = $true
        allowlisted = $true
      }
      [pscustomobject]@{
        id = 'rayman-managed-skills'
        path = '.Rayman/skills'
        source_kind = 'bundled'
        trust = 'managed'
        enabled = $true
        allowlisted = $true
      }
    )
    external_roots = @()
  }

  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return [pscustomobject]@{
      valid = $true
      path = $path
      data = $default
      error = ''
    }
  }

  try {
    $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ([string]$data.schema -ne 'rayman.skills_registry.v1') {
      throw "unexpected schema: $([string]$data.schema)"
    }
    return [pscustomobject]@{
      valid = $true
      path = $path
      data = $data
      error = ''
    }
  } catch {
    return [pscustomobject]@{
      valid = $false
      path = $path
      data = $default
      error = $_.Exception.Message
    }
  }
}

function Get-RaymanSupportedDuplicatePolicies {
  return @(
    'prefer_managed'
    'prefer_allowlisted'
    'registry_order'
  )
}

function Get-RaymanSkillFrontMatter {
  param([string]$Path)

  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return [pscustomobject]@{
      valid = $false
      id = ''
      description = ''
      error = 'empty'
    }
  }

  $name = ''
  $description = ''
  if ($raw -match '(?s)^---\s*(?<front>.*?)\s*---') {
    $front = [string]$matches['front']
    foreach ($line in @($front -split "`r?`n")) {
      if ([string]::IsNullOrWhiteSpace($name) -and $line -match '^\s*name\s*:\s*(?<value>.+?)\s*$') {
        $name = [string]$matches['value']
      }
      if ([string]::IsNullOrWhiteSpace($description) -and $line -match '^\s*description\s*:\s*(?<value>.+?)\s*$') {
        $description = [string]$matches['value']
      }
    }
  }

  if ([string]::IsNullOrWhiteSpace($name)) {
    $name = Split-Path -Leaf (Split-Path -Parent $Path)
  }
  if ([string]::IsNullOrWhiteSpace($name)) {
    return [pscustomobject]@{
      valid = $false
      id = ''
      description = $description
      error = 'missing_name'
    }
  }

  return [pscustomobject]@{
    valid = $true
    id = $name.Trim()
    description = ([string]$description).Trim()
    error = ''
  }
}

function Get-RaymanConfiguredSkillRoots {
  param([string]$WorkspaceRoot)

  $registry = Get-RaymanSkillsRegistry -WorkspaceRoot $WorkspaceRoot
  $items = New-Object System.Collections.Generic.List[object]
  $rootOrder = 0
  foreach ($collectionName in @('roots', 'external_roots')) {
    if ($null -eq $registry.data.PSObject.Properties[$collectionName]) { continue }
    foreach ($entry in @($registry.data.$collectionName)) {
      if ($null -eq $entry) { continue }
      $pathText = if ($entry.PSObject.Properties['path']) { [string]$entry.path } else { '' }
      if ([string]::IsNullOrWhiteSpace($pathText)) { continue }
      $root = Resolve-RaymanSkillsWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
      $absolute = if ([System.IO.Path]::IsPathRooted($pathText)) { $pathText } else { Join-Path $root $pathText }
      $items.Add([pscustomobject]@{
          id = if ($entry.PSObject.Properties['id']) { [string]$entry.id } else { $pathText }
          path = $pathText
          absolute_path = $absolute
          source_kind = if ($entry.PSObject.Properties['source_kind']) { [string]$entry.source_kind } else { 'external' }
          trust = if ($entry.PSObject.Properties['trust']) { [string]$entry.trust } else { 'ignored' }
          enabled = if ($entry.PSObject.Properties['enabled']) { [bool]$entry.enabled } else { $true }
          allowlisted = if ($entry.PSObject.Properties['allowlisted']) { [bool]$entry.allowlisted } else { $false }
          root_order = $rootOrder
        }) | Out-Null
      $rootOrder++
    }
  }

  return [pscustomobject]@{
    registry = $registry
    roots = @($items.ToArray())
  }
}

function Resolve-RaymanDuplicatePolicy {
  param([object]$Registry)

  $policy = if ($null -ne $Registry -and $Registry.data.PSObject.Properties['duplicate_resolution']) {
    [string]$Registry.data.duplicate_resolution
  } else {
    'prefer_managed'
  }
  $policy = $policy.Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($policy)) {
    $policy = 'prefer_managed'
  }

  $supported = @(Get-RaymanSupportedDuplicatePolicies)
  if ($policy -notin $supported) {
    return [pscustomobject]@{
      valid = $false
      policy = $policy
      error = ('unsupported duplicate_resolution: {0}. supported: {1}' -f $policy, ($supported -join ', '))
    }
  }

  return [pscustomobject]@{
    valid = $true
    policy = $policy
    error = ''
  }
}

function Get-RaymanDuplicatePolicyRank {
  param(
    [object]$Record,
    [string]$Policy
  )

  $trust = if ($Record.PSObject.Properties['trust']) {
    ([string]$Record.trust).Trim().ToLowerInvariant()
  } else {
    ''
  }
  $allowlisted = if ($Record.PSObject.Properties['allowlisted']) { [bool]$Record.allowlisted } else { $false }
  $enabled = if ($Record.PSObject.Properties['enabled']) { [bool]$Record.enabled } else { $true }
  $rootOrder = if ($Record.PSObject.Properties['root_order']) { [int]$Record.root_order } else { [int]::MaxValue }

  switch ([string]$Policy) {
    'prefer_allowlisted' {
      if ($enabled -and ($trust -eq 'allowlisted' -and $allowlisted)) { return 0 }
      if ($enabled -and $trust -eq 'managed') { return 1 }
      return 2
    }
    'registry_order' {
      return (1000 + $rootOrder)
    }
    default {
      if ($enabled -and $trust -eq 'managed') { return 0 }
      if ($enabled -and ($trust -eq 'allowlisted' -and $allowlisted)) { return 1 }
      return 2
    }
  }
}

function Test-RaymanSkillSelectable {
  param([object]$Record)

  if ($null -eq $Record) {
    return $false
  }

  $validManifest = if ($Record.PSObject.Properties['valid_manifest']) { [bool]$Record.valid_manifest } else { $false }
  $enabled = if ($Record.PSObject.Properties['enabled']) { [bool]$Record.enabled } else { $false }
  $trust = if ($Record.PSObject.Properties['trust']) { ([string]$Record.trust).Trim().ToLowerInvariant() } else { '' }
  $allowlisted = if ($Record.PSObject.Properties['allowlisted']) { [bool]$Record.allowlisted } else { $false }

  if (-not $validManifest -or -not $enabled) {
    return $false
  }
  if ($trust -eq 'managed') {
    return $true
  }
  if ($trust -eq 'allowlisted' -and $allowlisted) {
    return $true
  }
  return $false
}

function Invoke-RaymanSkillsAudit {
  [CmdletBinding()]
  param([string]$WorkspaceRoot)

  $root = Resolve-RaymanSkillsWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
  $config = Get-RaymanConfiguredSkillRoots -WorkspaceRoot $root
  $duplicatePolicyState = Resolve-RaymanDuplicatePolicy -Registry $config.registry
  $duplicatePolicy = [string]$duplicatePolicyState.policy

  $skills = New-Object System.Collections.Generic.List[object]
  $rootResults = New-Object System.Collections.Generic.List[object]
  $invalidManifests = New-Object System.Collections.Generic.List[object]
  $duplicateMap = @{}

  foreach ($skillRoot in @($config.roots)) {
    $exists = Test-Path -LiteralPath $skillRoot.absolute_path -PathType Container
    $rootSelected = 0
    $rootBlocked = 0
    $rootInvalid = 0

    if ($exists) {
      foreach ($file in @(Get-ChildItem -LiteralPath $skillRoot.absolute_path -Filter 'SKILL.md' -Recurse -File -ErrorAction SilentlyContinue)) {
        $frontMatter = Get-RaymanSkillFrontMatter -Path $file.FullName
        $valid = [bool]$frontMatter.valid
        $verdict = 'blocked'
        $blockReason = ''
        $selected = $false
        if (-not $valid) {
          $verdict = 'invalid'
          $blockReason = [string]$frontMatter.error
          $rootInvalid++
          $invalidManifests.Add([pscustomobject]@{
              path = $file.FullName
              root_id = [string]$skillRoot.id
              error = [string]$frontMatter.error
            }) | Out-Null
        } elseif (-not [bool]$skillRoot.enabled) {
          $blockReason = 'root_disabled'
          $rootBlocked++
        } elseif ([string]$skillRoot.trust -eq 'managed') {
          $verdict = 'allowed'
          $selected = $true
          $rootSelected++
        } elseif ([bool]$skillRoot.allowlisted -and [string]$skillRoot.trust -eq 'allowlisted') {
          $verdict = 'allowed'
          $selected = $true
          $rootSelected++
        } else {
          $blockReason = 'untrusted_root'
          $rootBlocked++
        }

        $skillId = if ($valid) { [string]$frontMatter.id } else { Split-Path -Leaf (Split-Path -Parent $file.FullName) }
        $checksum = Get-RaymanSkillChecksum -Path $file.FullName
        $relativePath = Get-RaymanSkillsRelativePath -BasePath $root -TargetPath $file.FullName

        $skillRecord = [pscustomobject]@{
          skill_id = $skillId
          description = if ($valid) { [string]$frontMatter.description } else { '' }
          path = $file.FullName
          relative_path = $relativePath.Replace('\', '/')
          checksum_sha256 = $checksum
          root_id = [string]$skillRoot.id
          source_kind = [string]$skillRoot.source_kind
          trust = [string]$skillRoot.trust
          enabled = [bool]$skillRoot.enabled
          allowlisted = [bool]$skillRoot.allowlisted
          root_order = [int]$skillRoot.root_order
          valid_manifest = $valid
          verdict = $verdict
          selected = $selected
          duplicate = $false
          duplicate_resolution = ''
          block_reason = $blockReason
        }
        $skills.Add($skillRecord) | Out-Null

        if (-not [string]::IsNullOrWhiteSpace($skillId)) {
          if (-not $duplicateMap.ContainsKey($skillId)) {
            $duplicateMap[$skillId] = New-Object System.Collections.Generic.List[object]
          }
          $duplicateMap[$skillId].Add($skillRecord) | Out-Null
        }
      }
    }

    $rootResults.Add([pscustomobject]@{
        id = [string]$skillRoot.id
        path = [string]$skillRoot.path
        absolute_path = [string]$skillRoot.absolute_path
        source_kind = [string]$skillRoot.source_kind
        trust = [string]$skillRoot.trust
        enabled = [bool]$skillRoot.enabled
        allowlisted = [bool]$skillRoot.allowlisted
        exists = $exists
        selected_count = $rootSelected
        blocked_count = $rootBlocked
        invalid_count = $rootInvalid
      }) | Out-Null
  }

  $duplicateIds = New-Object System.Collections.Generic.List[object]
  $skillGroups = @($skills.ToArray() | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.skill_id) } | Group-Object -Property skill_id | Sort-Object Name)
  foreach ($group in $skillGroups) {
    $skillId = [string]$group.Name
    $records = @($group.Group)
    if ($records.Count -le 1) { continue }

    $selectableRecords = @($records | Where-Object { Test-RaymanSkillSelectable -Record $_ })
    $winner = $null
    if ($selectableRecords.Count -gt 0) {
      $winner = $selectableRecords |
        Sort-Object @{ Expression = { Get-RaymanDuplicatePolicyRank -Record $_ -Policy $duplicatePolicy } }, @{ Expression = { [int]$_.root_order } }, @{ Expression = { [string]$_.relative_path } } |
        Select-Object -First 1
    }

    $duplicateEntry = [ordered]@{
      skill_id = [string]$skillId
      selected_path = if ($null -ne $winner) { [string]$winner.relative_path } else { '' }
      duplicate_paths = @($records | ForEach-Object { [string]$_.relative_path })
      selectable_paths = @($selectableRecords | ForEach-Object { [string]$_.relative_path })
      policy = $duplicatePolicy
    }
    if ($null -eq $winner) {
      $duplicateEntry['no_winner_reason'] = 'no_selectable_candidates'
    }
    $duplicateIds.Add([pscustomobject]$duplicateEntry) | Out-Null

    foreach ($record in $records) {
      $record.duplicate = $true
      if ($null -eq $winner) {
        $record.selected = $false
        if ([string]::IsNullOrWhiteSpace([string]$record.duplicate_resolution)) {
          $record.duplicate_resolution = 'no_selectable_candidates'
        }
        continue
      }

      if ([string]$record.relative_path -eq [string]$winner.relative_path) {
        $record.selected = $true
        $record.verdict = 'allowed'
        $record.block_reason = ''
        $record.duplicate_resolution = 'selected'
        continue
      }

      $record.selected = $false
      if (Test-RaymanSkillSelectable -Record $record) {
        $record.verdict = 'blocked'
        $record.block_reason = 'duplicate_shadowed'
        $record.duplicate_resolution = ('shadowed_by:{0}' -f [string]$winner.relative_path)
      } elseif ([string]::IsNullOrWhiteSpace([string]$record.duplicate_resolution)) {
        $record.duplicate_resolution = 'ineligible_for_selection'
      }
    }
  }

  foreach ($rootResult in @($rootResults.ToArray())) {
    $rootId = [string]$rootResult.id
    $rootSkills = @($skills.ToArray() | Where-Object { [string]$_.root_id -eq $rootId })
    $rootResult.selected_count = @($rootSkills | Where-Object { [bool]$_.selected }).Count
    $rootResult.blocked_count = @($rootSkills | Where-Object { [string]$_.verdict -eq 'blocked' }).Count
    $rootResult.invalid_count = @($rootSkills | Where-Object { [string]$_.verdict -eq 'invalid' }).Count
  }

  $selectedSkills = @($skills.ToArray() | Where-Object { [bool]$_.selected } | Sort-Object skill_id, relative_path)
  $blockedSkills = @($skills.ToArray() | Where-Object { [string]$_.verdict -eq 'blocked' })
  $registryValid = ([bool]$config.registry.valid -and [bool]$duplicatePolicyState.valid)
  $registryError = [string]$config.registry.error
  if (-not [bool]$duplicatePolicyState.valid) {
    if ([string]::IsNullOrWhiteSpace($registryError)) {
      $registryError = [string]$duplicatePolicyState.error
    } else {
      $registryError = ('{0}; {1}' -f $registryError, [string]$duplicatePolicyState.error)
    }
  }
  $audit = [ordered]@{
    schema = 'rayman.skills.audit.v1'
    success = $registryValid
    registry_path = [string]$config.registry.path
    registry_valid = $registryValid
    registry_error = $registryError
    generated_at = (Get-Date).ToString('o')
    workspace_root = $root
    duplicate_resolution = $duplicatePolicy
    roots = @($rootResults.ToArray())
    skills = @($skills.ToArray())
    selected_skills = @($selectedSkills)
    duplicate_ids = @($duplicateIds.ToArray())
    invalid_manifests = @($invalidManifests.ToArray())
    blocked_sources = @($blockedSkills | ForEach-Object {
        [pscustomobject]@{
          skill_id = [string]$_.skill_id
          relative_path = [string]$_.relative_path
          block_reason = [string]$_.block_reason
        }
      })
    counts = [ordered]@{
      total_skills = $skills.Count
      selected_skills = $selectedSkills.Count
      blocked_skills = $blockedSkills.Count
      invalid_manifests = $invalidManifests.Count
      duplicate_ids = $duplicateIds.Count
    }
  }

  $runtimeDir = Join-Path $root '.Rayman\runtime'
  if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
  }
  $jsonPath = Join-Path $runtimeDir 'skills.audit.last.json'
  $mdPath = Join-Path $runtimeDir 'skills.audit.last.md'
  ($audit | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $jsonPath -Encoding UTF8

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# Rayman Skills Audit') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add(("- registry_valid: {0}" -f [string]([bool]$audit.registry_valid).ToString().ToLowerInvariant())) | Out-Null
  $lines.Add(("- duplicate_resolution: {0}" -f [string]$audit.duplicate_resolution)) | Out-Null
  $lines.Add(("- selected_skills: {0}" -f [int]$audit.counts.selected_skills)) | Out-Null
  $lines.Add(("- blocked_skills: {0}" -f [int]$audit.counts.blocked_skills)) | Out-Null
  $lines.Add(("- invalid_manifests: {0}" -f [int]$audit.counts.invalid_manifests)) | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add('## Trusted Skills') | Out-Null
  $lines.Add('') | Out-Null
  if ($selectedSkills.Count -eq 0) {
    $lines.Add('- none') | Out-Null
  } else {
    foreach ($skill in $selectedSkills) {
      $lines.Add(("- {0} [{1}/{2}] :: {3}" -f [string]$skill.skill_id, [string]$skill.source_kind, [string]$skill.trust, [string]$skill.relative_path)) | Out-Null
    }
  }
  $lines.Add('') | Out-Null
  $lines.Add('## Blocked Or Invalid') | Out-Null
  $lines.Add('') | Out-Null
  if (($blockedSkills.Count + $invalidManifests.Count) -eq 0) {
    $lines.Add('- none') | Out-Null
  } else {
    foreach ($skill in @($blockedSkills | Sort-Object skill_id, relative_path)) {
      $lines.Add(("- {0} :: {1} ({2})" -f [string]$skill.skill_id, [string]$skill.relative_path, [string]$skill.block_reason)) | Out-Null
    }
    foreach ($item in @($invalidManifests | Sort-Object path)) {
      $lines.Add(("- invalid :: {0} ({1})" -f [string]$item.path, [string]$item.error)) | Out-Null
    }
  }
  Set-Content -LiteralPath $mdPath -Encoding UTF8 -Value ($lines -join "`r`n")

  $audit['artifacts'] = [ordered]@{
    json_path = $jsonPath
    markdown_path = $mdPath
  }

  if (Get-Command Write-RaymanEvent -ErrorAction SilentlyContinue) {
    Write-RaymanEvent -WorkspaceRoot $root -EventType 'skills.audit' -Category 'skills' -Payload $audit | Out-Null
  }

  return [pscustomobject]$audit
}

if (-not $NoMain) {
  $resolvedRoot = Resolve-RaymanSkillsWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
  $audit = Invoke-RaymanSkillsAudit -WorkspaceRoot $resolvedRoot

  switch ($Action) {
    'audit' {
      if ($Json) {
        $audit | ConvertTo-Json -Depth 16
      } else {
        Write-Host ("[skills] registry_valid={0} selected={1} blocked={2}" -f [string]([bool]$audit.registry_valid).ToString().ToLowerInvariant(), [int]$audit.counts.selected_skills, [int]$audit.counts.blocked_skills)
        Write-Host ("[skills] audit: {0}" -f [string]$audit.artifacts.json_path) -ForegroundColor DarkCyan
      }
    }
    default {
      $selected = @($audit.selected_skills)
      if ($Json) {
        [ordered]@{
          schema = 'rayman.skills.list.v1'
          workspace_root = $resolvedRoot
          count = $selected.Count
          skills = $selected
          audit = $audit.artifacts
        } | ConvertTo-Json -Depth 12
      } else {
        Write-Host 'Trusted Rayman skills:'
        if ($selected.Count -eq 0) {
          Write-Host '- none'
        } else {
          foreach ($skill in $selected) {
            Write-Host ("- {0} [{1}/{2}] :: {3}" -f [string]$skill.skill_id, [string]$skill.source_kind, [string]$skill.trust, [string]$skill.relative_path)
          }
        }
        Write-Host ("[skills] audit: {0}" -f [string]$audit.artifacts.json_path) -ForegroundColor DarkCyan
      }
    }
  }

  if (-not [bool]$audit.registry_valid) {
    exit 6
  }
}
