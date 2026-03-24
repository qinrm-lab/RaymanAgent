BeforeAll {
  . (Join-Path $PSScriptRoot '..\..\pwa\playwright_ready.lib.ps1')
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
}
