BeforeAll {
  . (Join-Path $PSScriptRoot '..\..\windows\winapp_core.ps1')
}

Describe 'winapp_core' {
  It 'imports WinApp assemblies on first call without strict-mode variable errors' {
    Mock Add-Type {}

    { Import-WinAppAssemblies } | Should -Not -Throw
  }

  It 'parses quoted launch commands' {
    $parts = Split-WinAppLaunchCommand -CommandLine '"C:\Program Files\Notepad++\notepad++.exe" -multiInst'
    $parts.file_path | Should -Be 'C:\Program Files\Notepad++\notepad++.exe'
    $parts.argument_list | Should -Be '-multiInst'
  }

  It 'reports host_not_windows when host is not Windows' {
    Mock Test-WinAppHostIsWindows { $false }
    $state = Get-WinAppDesktopSessionState
    $state.available | Should -BeFalse
    $state.reason | Should -Be 'host_not_windows'
  }

  It 'treats host_not_windows as not applicable for readiness gating' {
    Test-WinAppReadinessReasonNotApplicable -Reason 'host_not_windows' | Should -BeTrue
    Test-WinAppReadinessReasonNotApplicable -Reason 'desktop_session_unavailable' | Should -BeFalse
  }

  It 'reports desktop_session_unavailable when Windows is present but desktop is unavailable' {
    Mock Test-WinAppHostIsWindows { $true }
    Mock Get-WinAppDesktopSessionState {
      [pscustomobject]@{
        available = $false
        reason = 'desktop_session_unavailable'
        session_name = 'Service'
        user_interactive = $false
      }
    }
    $state = Get-WinAppReadinessState -WorkspaceRoot 'C:\RaymanAgent'
    $state.ready | Should -BeFalse
    $state.reason | Should -Be 'desktop_session_unavailable'
  }

  It 'surfaces the real UIAutomation error message in readiness detail' {
    Mock Test-WinAppHostIsWindows { $true }
    Mock Get-WinAppDesktopSessionState {
      [pscustomobject]@{
        available = $true
        reason = 'interactive_desktop'
        session_name = 'Console'
        user_interactive = $true
      }
    }
    Mock Import-WinAppAssemblies { throw 'uia load failed' }

    $state = Get-WinAppReadinessState -WorkspaceRoot 'C:\RaymanAgent'

    $state.ready | Should -BeFalse
    $state.reason | Should -Be 'uia_unavailable'
    $state.detail | Should -Be 'uia load failed'
    $state.error_message | Should -Be 'uia load failed'
  }
}
