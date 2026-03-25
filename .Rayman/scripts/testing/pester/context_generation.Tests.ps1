BeforeAll {
  $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
}

Describe 'context generation' {
  It 'uses tracked top-level entries and ignores runtime-specific capability state' {
    $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $git -or [string]::IsNullOrWhiteSpace([string]$git.Source)) {
      Set-ItResult -Skipped -Because 'git not found'
      return
    }

    $psHost = (Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($null -eq $psHost) {
      $psHost = (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1)
    }
    if ($null -eq $psHost -or [string]::IsNullOrWhiteSpace([string]$psHost.Source)) {
      Set-ItResult -Skipped -Because 'PowerShell host not found'
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_context_generation_' + [Guid]::NewGuid().ToString('N'))
    $previousSkillsSelected = [Environment]::GetEnvironmentVariable('RAYMAN_SKILLS_SELECTED', 'Process')
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\utils') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\skills') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\templates') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\skills') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root 'src') | Out-Null

      Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\common.ps1') -Destination (Join-Path $root '.Rayman\common.ps1')
      Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\utils\generate_context.ps1') -Destination (Join-Path $root '.Rayman\scripts\utils\generate_context.ps1')
      Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\skills\detect_skills.ps1') -Destination (Join-Path $root '.Rayman\scripts\skills\detect_skills.ps1')
      Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\skills\inject_codex_fix_prompt.ps1') -Destination (Join-Path $root '.Rayman\scripts\skills\inject_codex_fix_prompt.ps1')
      Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\templates\codex_fix_prompt.base.txt') -Destination (Join-Path $root '.Rayman\templates\codex_fix_prompt.base.txt')
      Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\skills\rules.json') -Destination (Join-Path $root '.Rayman\skills\rules.json')

      Set-Content -LiteralPath (Join-Path $root 'AGENTS.md') -Encoding UTF8 -Value "# temp`n"
      Set-Content -LiteralPath (Join-Path $root 'src\app.txt') -Encoding UTF8 -Value "tracked`n"

      & $git.Source -C $root init | Out-Null
      $LASTEXITCODE | Should -Be 0
      & $git.Source -C $root add --all | Out-Null
      $LASTEXITCODE | Should -Be 0

      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\runtime') | Out-Null
      Set-Content -LiteralPath (Join-Path $root '.env') -Encoding UTF8 -Value 'local-secret'
      Set-Content -LiteralPath (Join-Path $root 'local.log') -Encoding UTF8 -Value 'noise'
      Set-Content -LiteralPath (Join-Path $root '.Rayman\runtime\agent_capabilities.report.json') -Encoding UTF8 -Value @'
{
  "schema": "rayman.agent_capabilities.report.v1",
  "active_capabilities": ["openai_docs"],
  "workspace_trust_status": "trusted",
  "workspace_trust_reason": "matched_user_config"
}
'@

      [Environment]::SetEnvironmentVariable('RAYMAN_SKILLS_SELECTED', $null, 'Process')
      & $psHost.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root '.Rayman\scripts\utils\generate_context.ps1') -WorkspaceRoot $root | Out-Null
      $first = Get-Content -LiteralPath (Join-Path $root '.Rayman\CONTEXT.md') -Raw -Encoding UTF8

      $first | Should -Match ([regex]::Escape('Top-level entries: .Rayman, AGENTS.md, src'))
      $first | Should -Not -Match '\.env'
      $first | Should -Not -Match 'local\.log'
      $first | Should -Not -Match 'matched_user_config'
      $first | Should -Not -Match 'openai_docs'
      $first | Should -Match 'environment-specific'

      Set-Content -LiteralPath (Join-Path $root '.Rayman\runtime\agent_capabilities.report.json') -Encoding UTF8 -Value @'
{
  "schema": "rayman.agent_capabilities.report.v1",
  "active_capabilities": ["winapp_auto_test"],
  "workspace_trust_status": "unknown",
  "workspace_trust_reason": "workspace_not_found"
}
'@

      & $psHost.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root '.Rayman\scripts\utils\generate_context.ps1') -WorkspaceRoot $root | Out-Null
      $second = Get-Content -LiteralPath (Join-Path $root '.Rayman\CONTEXT.md') -Raw -Encoding UTF8

      $second | Should -Be $first
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_SKILLS_SELECTED', $previousSkillsSelected, 'Process')
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
