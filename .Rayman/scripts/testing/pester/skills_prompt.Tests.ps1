BeforeAll {
  $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
}

Describe 'skills prompt injection' {
  It 'writes a stable skills block without timestamps and preserves content across reruns' {
    $psHost = (Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($null -eq $psHost) {
      $psHost = (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1)
    }
    if ($null -eq $psHost -or [string]::IsNullOrWhiteSpace([string]$psHost.Source)) {
      Set-ItResult -Skipped -Because 'PowerShell host not found'
      return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_skills_prompt_' + [Guid]::NewGuid().ToString('N'))
    $previousSkillsSelected = [Environment]::GetEnvironmentVariable('RAYMAN_SKILLS_SELECTED', 'Process')
    try {
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\scripts\skills') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $root '.Rayman\templates') | Out-Null

      Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\skills\inject_codex_fix_prompt.ps1') -Destination (Join-Path $root '.Rayman\scripts\skills\inject_codex_fix_prompt.ps1')
      Copy-Item -LiteralPath (Join-Path $script:RepoRoot '.Rayman\templates\codex_fix_prompt.base.txt') -Destination (Join-Path $root '.Rayman\templates\codex_fix_prompt.base.txt')

      [Environment]::SetEnvironmentVariable('RAYMAN_SKILLS_SELECTED', 'docs,spreadsheets', 'Process')

      & $psHost.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root '.Rayman\scripts\skills\inject_codex_fix_prompt.ps1') | Out-Null
      $first = Get-Content -LiteralPath (Join-Path $root '.Rayman\codex_fix_prompt.txt') -Raw -Encoding UTF8

      & $psHost.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root '.Rayman\scripts\skills\inject_codex_fix_prompt.ps1') | Out-Null
      $second = Get-Content -LiteralPath (Join-Path $root '.Rayman\codex_fix_prompt.txt') -Raw -Encoding UTF8

      $first | Should -Be $second
      $second | Should -Not -Match '时间：'
      $second | Should -Match '推断结果：docs,spreadsheets'
      $second | Should -Match ([regex]::Escape('详细建议：.Rayman/context/skills.auto.md'))
    } finally {
      [Environment]::SetEnvironmentVariable('RAYMAN_SKILLS_SELECTED', $previousSkillsSelected, 'Process')
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
