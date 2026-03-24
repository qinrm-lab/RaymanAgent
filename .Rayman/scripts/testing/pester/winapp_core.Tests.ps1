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

  It 'records backend selection and fallback diagnostics in readiness state' {
    Mock Test-WinAppHostIsWindows { $true }
    Mock Get-WinAppDesktopSessionState {
      [pscustomobject]@{
        available = $false
        reason = 'desktop_session_unavailable'
        session_name = 'Service'
        user_interactive = $false
      }
    }
    Mock Get-WinAppBackendProbe {
      [pscustomobject]@{
        appium_windows_driver = [pscustomobject]@{
          available = $true
          command = 'appium'
          reason = 'command_present_driver_install_unverified'
        }
        winappdriver_compatible = [pscustomobject]@{
          available = $false
          command = ''
          reason = 'service_binary_missing'
        }
        uia_direct = [pscustomobject]@{
          available = $false
          command = 'uia-direct'
          reason = 'desktop_session_unavailable'
        }
      }
    }
    Mock Select-WinAppBackend {
      [pscustomobject]@{
        backend_preference = @('appium_windows_driver', 'winappdriver_compatible', 'uia_direct')
        preferred_backend = 'appium_windows_driver'
        preferred_backend_available = $true
        selected_backend = 'uia_direct'
        selected_backend_available = $false
        selected_backend_reason = 'preferred_appium_windows_driver_degraded_to_uia_direct_until_remote_backend_execution_is_wired'
        fallback_decision = 'used_uia_direct_fallback'
        fallback_reason = 'rayman_runtime_executes_via_uia_direct'
      }
    }

    $state = Get-WinAppReadinessState -WorkspaceRoot 'C:\RaymanAgent'

    $state.preferred_backend | Should -Be 'appium_windows_driver'
    $state.selected_backend | Should -Be 'uia_direct'
    $state.fallback_decision | Should -Be 'used_uia_direct_fallback'
    [string]$state.backend_probe.appium_windows_driver.command | Should -Be 'appium'
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
