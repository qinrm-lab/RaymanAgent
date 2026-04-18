Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
}

function script:New-SkillsRegistryTestRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_skills_registry_' + [Guid]::NewGuid().ToString('N'))
  foreach ($path in @(
      $root,
      (Join-Path $root '.Rayman\scripts\skills'),
      (Join-Path $root '.Rayman\scripts\utils'),
      (Join-Path $root '.Rayman\templates'),
      (Join-Path $root '.Rayman\skills'),
      (Join-Path $root '.Rayman\config'),
      (Join-Path $root '.github\skills\duplicate-skill'),
      (Join-Path $root '.external-skills\duplicate-skill'),
      (Join-Path $root '.external-skills\broken-skill')
    )) {
    New-Item -ItemType Directory -Force -Path $path | Out-Null
  }

  Copy-Item -LiteralPath (Join-Path $script:WorkspaceRoot '.Rayman\common.ps1') -Destination (Join-Path $root '.Rayman\common.ps1')
  Copy-Item -LiteralPath (Join-Path $script:WorkspaceRoot '.Rayman\scripts\utils\event_hooks.ps1') -Destination (Join-Path $root '.Rayman\scripts\utils\event_hooks.ps1')
  Copy-Item -LiteralPath (Join-Path $script:WorkspaceRoot '.Rayman\scripts\skills\manage_skills.ps1') -Destination (Join-Path $root '.Rayman\scripts\skills\manage_skills.ps1')
  Copy-Item -LiteralPath (Join-Path $script:WorkspaceRoot '.Rayman\scripts\skills\detect_skills.ps1') -Destination (Join-Path $root '.Rayman\scripts\skills\detect_skills.ps1')
  Copy-Item -LiteralPath (Join-Path $script:WorkspaceRoot '.Rayman\scripts\skills\inject_codex_fix_prompt.ps1') -Destination (Join-Path $root '.Rayman\scripts\skills\inject_codex_fix_prompt.ps1')
  Copy-Item -LiteralPath (Join-Path $script:WorkspaceRoot '.Rayman\templates\codex_fix_prompt.base.txt') -Destination (Join-Path $root '.Rayman\templates\codex_fix_prompt.base.txt')
  Copy-Item -LiteralPath (Join-Path $script:WorkspaceRoot '.Rayman\skills\rules.json') -Destination (Join-Path $root '.Rayman\skills\rules.json')

  Set-Content -LiteralPath (Join-Path $root '.github\skills\duplicate-skill\SKILL.md') -Encoding UTF8 -Value @'
---
name: duplicate-skill
description: Managed bundled skill.
---
# Managed Skill
'@
  Set-Content -LiteralPath (Join-Path $root '.external-skills\duplicate-skill\SKILL.md') -Encoding UTF8 -Value @'
---
name: duplicate-skill
description: External duplicate skill.
---
# External Skill
'@
  Set-Content -LiteralPath (Join-Path $root '.external-skills\broken-skill\SKILL.md') -Encoding UTF8 -Value ''
  Set-Content -LiteralPath (Join-Path $root '.Rayman\config\skills_registry.json') -Encoding UTF8 -Value @'
{
  "schema": "rayman.skills_registry.v1",
  "duplicate_resolution": "prefer_managed",
  "roots": [
    {
      "id": "github-managed-skills",
      "path": ".github/skills",
      "source_kind": "bundled",
      "trust": "managed",
      "enabled": true,
      "allowlisted": true
    }
  ],
  "external_roots": [
    {
      "id": "external-skills",
      "path": ".external-skills",
      "source_kind": "external",
      "trust": "ignored",
      "enabled": true,
      "allowlisted": false
    }
  ]
}
'@

  return $root
}

function script:Set-SkillsRegistryConfig {
  param(
    [string]$Root,
    [string]$Json
  )

  Set-Content -LiteralPath (Join-Path $Root '.Rayman\config\skills_registry.json') -Encoding UTF8 -Value $Json
}

function script:Get-SkillsEventTypes {
  param([string]$Root)

  $eventDir = Join-Path $Root '.Rayman\runtime\events'
  if (-not (Test-Path -LiteralPath $eventDir -PathType Container)) {
    return @()
  }

  $types = New-Object System.Collections.Generic.List[string]
  foreach ($file in @(Get-ChildItem -LiteralPath $eventDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)) {
    foreach ($line in @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)) {
      if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
      try {
        $event = [string]$line | ConvertFrom-Json -ErrorAction Stop
        if ($event.PSObject.Properties['event_type']) {
          $types.Add([string]$event.event_type) | Out-Null
        }
      } catch {}
    }
  }

  return @($types.ToArray())
}

Describe 'skills registry' {
  It 'keeps bundled managed skills trusted and excludes untrusted external duplicates from skills.auto.md' {
    $root = New-SkillsRegistryTestRoot
    try {
      $audit = & (Join-Path $root '.Rayman\scripts\skills\manage_skills.ps1') -WorkspaceRoot $root -Action audit -Json | ConvertFrom-Json
      & (Join-Path $root '.Rayman\scripts\skills\detect_skills.ps1') -Root $root | Out-Null
      $skillsAuto = Get-Content -LiteralPath (Join-Path $root '.Rayman\context\skills.auto.md') -Raw -Encoding UTF8

      $audit.schema | Should -Be 'rayman.skills.audit.v1'
      $audit.registry_valid | Should -Be $true
      @($audit.selected_skills | Where-Object { [string]$_.skill_id -eq 'duplicate-skill' }).Count | Should -Be 1
      [string]$audit.selected_skills[0].relative_path | Should -Be '.github/skills/duplicate-skill/SKILL.md'
      [int]$audit.counts.duplicate_ids | Should -Be 1
      [int]$audit.counts.invalid_manifests | Should -Be 1
      @($audit.blocked_sources | Where-Object { [string]$_.relative_path -eq '.external-skills/duplicate-skill/SKILL.md' }).Count | Should -Be 1
      Test-Path -LiteralPath ([string]$audit.artifacts.json_path) -PathType Leaf | Should -Be $true
      Test-Path -LiteralPath ([string]$audit.artifacts.markdown_path) -PathType Leaf | Should -Be $true
      $skillsAuto | Should -Match 'Trusted Skill Manifests'
      $skillsAuto | Should -Match '\.github/skills/duplicate-skill/SKILL\.md'
      $skillsAuto | Should -Not -Match '\.external-skills/duplicate-skill/SKILL\.md'
      (@(Get-SkillsEventTypes -Root $root) -contains 'skills.audit') | Should -Be $true
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'enforces prefer_allowlisted duplicate resolution when configured' {
    $root = New-SkillsRegistryTestRoot
    try {
      Set-SkillsRegistryConfig -Root $root -Json @'
{
  "schema": "rayman.skills_registry.v1",
  "duplicate_resolution": "prefer_allowlisted",
  "roots": [
    {
      "id": "github-managed-skills",
      "path": ".github/skills",
      "source_kind": "bundled",
      "trust": "managed",
      "enabled": true,
      "allowlisted": true
    }
  ],
  "external_roots": [
    {
      "id": "external-skills",
      "path": ".external-skills",
      "source_kind": "external",
      "trust": "allowlisted",
      "enabled": true,
      "allowlisted": true
    }
  ]
}
'@
      $audit = & (Join-Path $root '.Rayman\scripts\skills\manage_skills.ps1') -WorkspaceRoot $root -Action audit -Json | ConvertFrom-Json
      $selected = @($audit.selected_skills | Where-Object { [string]$_.skill_id -eq 'duplicate-skill' })
      $managed = @($audit.skills | Where-Object { [string]$_.relative_path -eq '.github/skills/duplicate-skill/SKILL.md' }) | Select-Object -First 1
      $external = @($audit.skills | Where-Object { [string]$_.relative_path -eq '.external-skills/duplicate-skill/SKILL.md' }) | Select-Object -First 1

      $audit.registry_valid | Should -Be $true
      [string]$audit.duplicate_resolution | Should -Be 'prefer_allowlisted'
      $selected.Count | Should -Be 1
      [string]$selected[0].relative_path | Should -Be '.external-skills/duplicate-skill/SKILL.md'
      [string]$managed.block_reason | Should -Be 'duplicate_shadowed'
      [string]$external.duplicate_resolution | Should -Be 'selected'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'marks unsupported duplicate policies as registry errors' {
    $root = New-SkillsRegistryTestRoot
    try {
      Set-SkillsRegistryConfig -Root $root -Json @'
{
  "schema": "rayman.skills_registry.v1",
  "duplicate_resolution": "first_root_wins",
  "roots": [
    {
      "id": "github-managed-skills",
      "path": ".github/skills",
      "source_kind": "bundled",
      "trust": "managed",
      "enabled": true,
      "allowlisted": true
    }
  ],
  "external_roots": []
}
'@
      $audit = & (Join-Path $root '.Rayman\scripts\skills\manage_skills.ps1') -WorkspaceRoot $root -Action audit -Json | ConvertFrom-Json
      $exitCode = $LASTEXITCODE

      $exitCode | Should -Be 6
      $audit.registry_valid | Should -Be $false
      [string]$audit.registry_error | Should -Match 'unsupported duplicate_resolution'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'suppresses trusted manifests in skills.auto.md when the registry is invalid' {
    $root = New-SkillsRegistryTestRoot
    try {
      Set-SkillsRegistryConfig -Root $root -Json @'
{
  "schema": "rayman.skills_registry.v1",
  "duplicate_resolution": "bad_policy",
  "roots": [
    {
      "id": "github-managed-skills",
      "path": ".github/skills",
      "source_kind": "bundled",
      "trust": "managed",
      "enabled": true,
      "allowlisted": true
    }
  ],
  "external_roots": []
}
'@
      & (Join-Path $root '.Rayman\scripts\skills\detect_skills.ps1') -Root $root | Out-Null
      $skillsAuto = Get-Content -LiteralPath (Join-Path $root '.Rayman\context\skills.auto.md') -Raw -Encoding UTF8

      $skillsAuto | Should -Match 'Skills registry is invalid; trusted skill manifests are suppressed'
      $skillsAuto | Should -Match 'registry_error:'
      $skillsAuto | Should -Not -Match '\.github/skills/duplicate-skill/SKILL\.md'
      $skillsAuto | Should -Not -Match 'trust=`managed`'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'enforces registry_order using selectable roots only' {
    $root = New-SkillsRegistryTestRoot
    try {
      Set-SkillsRegistryConfig -Root $root -Json @'
{
  "schema": "rayman.skills_registry.v1",
  "duplicate_resolution": "registry_order",
  "roots": [
    {
      "id": "disabled-managed",
      "path": ".github/skills",
      "source_kind": "bundled",
      "trust": "managed",
      "enabled": false,
      "allowlisted": true
    }
  ],
  "external_roots": [
    {
      "id": "external-skills",
      "path": ".external-skills",
      "source_kind": "external",
      "trust": "allowlisted",
      "enabled": true,
      "allowlisted": true
    }
  ]
}
'@
      $audit = & (Join-Path $root '.Rayman\scripts\skills\manage_skills.ps1') -WorkspaceRoot $root -Action audit -Json | ConvertFrom-Json
      $selected = @($audit.selected_skills | Where-Object { [string]$_.skill_id -eq 'duplicate-skill' })
      $disabled = @($audit.skills | Where-Object { [string]$_.root_id -eq 'disabled-managed' }) | Select-Object -First 1

      $audit.registry_valid | Should -Be $true
      [string]$selected[0].relative_path | Should -Be '.external-skills/duplicate-skill/SKILL.md'
      [string]$disabled.block_reason | Should -Be 'root_disabled'
      [string]$disabled.duplicate_resolution | Should -Not -Be 'selected'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'does not let invalid managed duplicates shadow valid allowlisted skills' {
    $root = New-SkillsRegistryTestRoot
    try {
      Set-Content -LiteralPath (Join-Path $root '.github\skills\duplicate-skill\SKILL.md') -Encoding UTF8 -Value ''
      Set-SkillsRegistryConfig -Root $root -Json @'
{
  "schema": "rayman.skills_registry.v1",
  "duplicate_resolution": "prefer_managed",
  "roots": [
    {
      "id": "github-managed-skills",
      "path": ".github/skills",
      "source_kind": "bundled",
      "trust": "managed",
      "enabled": true,
      "allowlisted": true
    }
  ],
  "external_roots": [
    {
      "id": "external-skills",
      "path": ".external-skills",
      "source_kind": "external",
      "trust": "allowlisted",
      "enabled": true,
      "allowlisted": true
    }
  ]
}
'@
      $audit = & (Join-Path $root '.Rayman\scripts\skills\manage_skills.ps1') -WorkspaceRoot $root -Action audit -Json | ConvertFrom-Json
      $selected = @($audit.selected_skills | Where-Object { [string]$_.skill_id -eq 'duplicate-skill' })
      $invalidManaged = @($audit.skills | Where-Object { [string]$_.root_id -eq 'github-managed-skills' }) | Select-Object -First 1
      $external = @($audit.skills | Where-Object { [string]$_.relative_path -eq '.external-skills/duplicate-skill/SKILL.md' }) | Select-Object -First 1

      $audit.registry_valid | Should -Be $true
      $selected.Count | Should -Be 1
      [string]$selected[0].relative_path | Should -Be '.external-skills/duplicate-skill/SKILL.md'
      [bool]$invalidManaged.valid_manifest | Should -Be $false
      [string]$invalidManaged.duplicate_resolution | Should -Not -Be 'selected'
      [string]$external.duplicate_resolution | Should -Be 'selected'
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
