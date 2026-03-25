BeforeAll {
  . (Join-Path $PSScriptRoot '..\..\pwa\playwright_ready.lib.ps1')
  $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
}

Describe 'playwright_ready.lib' {
  It 'defaults an empty scope to wsl' {
    Normalize-Scope -Value '' | Should -Be 'wsl'
  }

  It 'accepts sandbox scope' {
    Normalize-Scope -Value 'sandbox' | Should -Be 'sandbox'
  }

  It 'rejects unsupported scope values' {
    { Normalize-Scope -Value 'desktop' } | Should -Throw
  }

  It 'classifies bootstrap stalled sandbox errors' {
    Get-SandboxFailureKindFromMessage -Message 'sandbox bootstrap appears stalled (stall_seconds=360)' | Should -Be 'bootstrap_stalled'
  }

  It 'classifies existing sandbox instance errors' {
    Get-SandboxFailureKindFromMessage -Message 'existing Windows Sandbox instance is already running; processes=WindowsSandbox#1234' | Should -Be 'existing_instance_running'
  }

  It 'returns action guidance for existing sandbox instance errors' {
    Get-SandboxActionRequired -FailureKind 'existing_instance_running' | Should -Match '关闭已有 Sandbox'
  }

  It 'converts string booleans flexibly' {
    Convert-ToBoolFlexible -Value 'yes' -ParameterName 'Require' | Should -BeTrue
    Convert-ToBoolFlexible -Value 'off' -ParameterName 'Require' | Should -BeFalse
  }

  It 'keeps sandbox offline cache gating enabled by default' {
    $raw = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.Rayman\scripts\pwa\ensure_playwright_ready.ps1') -Raw -Encoding UTF8

    $needle = [regex]::Escape("RAYMAN_SANDBOX_OFFLINE_CACHE_REQUIRE' -DefaultValue `$true")
    ([regex]::Matches($raw, $needle)).Count | Should -Be 2
  }
}
