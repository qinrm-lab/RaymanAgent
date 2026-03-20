Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:RaymanWinAppAssembliesLoaded = $false

function Get-PropValue {
  param(
    [object]$Object,
    [string]$Name,
    $Default = $null
  )

  if ($null -eq $Object) { return $Default }
  $prop = $Object.PSObject.Properties[$Name]
  if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
  return $prop.Value
}

function Convert-ToStringArray {
  param(
    [object]$Value
  )

  if ($null -eq $Value) { return @() }
  $items = New-Object 'System.Collections.Generic.List[string]'
  foreach ($entry in @($Value)) {
    $text = [string]$entry
    if (-not [string]::IsNullOrWhiteSpace($text)) {
      $items.Add($text.Trim()) | Out-Null
    }
  }
  return @($items)
}

function Ensure-Dir {
  param(
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Write-Utf8NoBom {
  param(
    [string]$Path,
    [string]$Content
  )

  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-EnvBoolCompat {
  param(
    [string]$Name,
    [bool]$Default = $false
  )

  $raw = [Environment]::GetEnvironmentVariable($Name)
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

function Get-EnvIntCompat {
  param(
    [string]$Name,
    [int]$Default,
    [int]$Min = 1,
    [int]$Max = 2147483647
  )

  $raw = [Environment]::GetEnvironmentVariable($Name)
  $parsed = 0
  if (-not [string]::IsNullOrWhiteSpace($raw) -and [int]::TryParse($raw, [ref]$parsed)) {
    if ($parsed -lt $Min) { return $Min }
    if ($parsed -gt $Max) { return $Max }
    return $parsed
  }
  return $Default
}

function Get-NowIsoTimestamp {
  return (Get-Date).ToString('o')
}

function Test-WinAppHostIsWindows {
  try {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
  } catch {
    return $false
  }
}

function Get-WinAppRuntimePaths {
  param(
    [string]$WorkspaceRoot
  )

  $runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime'
  $testsDir = Join-Path $runtimeDir 'winapp-tests'
  $logsDir = Join-Path $WorkspaceRoot '.Rayman\logs'
  $screenshotsDir = Join-Path $testsDir 'screenshots'
  return [pscustomobject]@{
    runtime_dir = $runtimeDir
    tests_dir = $testsDir
    logs_dir = $logsDir
    screenshots_dir = $screenshotsDir
    readiness_json_path = Join-Path $runtimeDir 'winapp.ready.windows.json'
    readiness_log_path = Join-Path $logsDir 'winapp.ready.windows.log'
    control_tree_json_path = Join-Path $testsDir 'control_tree.json'
    control_tree_text_path = Join-Path $testsDir 'control_tree.txt'
    last_result_json_path = Join-Path $testsDir 'last_result.json'
  }
}

function Write-WinAppLogLine {
  param(
    [string]$Path,
    [string]$Level,
    [string]$Message
  )

  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  Ensure-Dir -Path (Split-Path -Parent $Path)
  $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message
  Add-Content -LiteralPath $Path -Encoding UTF8 -Value $line
}

function ConvertTo-WinAppRectObject {
  param(
    [object]$Rect
  )

  if ($null -eq $Rect) { return $null }
  try {
    return [pscustomobject]@{
      left = [double]$Rect.Left
      top = [double]$Rect.Top
      width = [double]$Rect.Width
      height = [double]$Rect.Height
      right = [double]$Rect.Right
      bottom = [double]$Rect.Bottom
    }
  } catch {
    return $null
  }
}

function Get-WinAppDesktopSessionState {
  if (-not (Test-WinAppHostIsWindows)) {
    return [pscustomobject]@{
      available = $false
      reason = 'host_not_windows'
      session_name = ''
      user_interactive = $false
    }
  }

  $userInteractive = $false
  try {
    $userInteractive = [Environment]::UserInteractive
  } catch {
    $userInteractive = $false
  }

  $sessionName = [string]$env:SESSIONNAME
  if (-not $userInteractive) {
    return [pscustomobject]@{
      available = $false
      reason = 'desktop_session_unavailable'
      session_name = $sessionName
      user_interactive = $false
    }
  }

  return [pscustomobject]@{
    available = $true
    reason = 'interactive_desktop'
    session_name = $sessionName
    user_interactive = $true
  }
}

function Test-WinAppReadinessReasonNotApplicable {
  param(
    [string]$Reason
  )

  if ([string]::IsNullOrWhiteSpace($Reason)) { return $false }
  return ($Reason.Trim().ToLowerInvariant() -eq 'host_not_windows')
}

function Import-WinAppAssemblies {
  if ($script:RaymanWinAppAssembliesLoaded) { return }

  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing

  if ($null -eq ('RaymanWin32Native' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class RaymanWin32Native
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
}
"@
  }

  $script:RaymanWinAppAssembliesLoaded = $true
}

function Get-WinAppReadinessState {
  param(
    [string]$WorkspaceRoot
  )

  $desktop = Get-WinAppDesktopSessionState
  $uiaAvailable = $false
  $screenshotAvailable = $false
  $reason = 'ready'
  $detail = 'windows_desktop_ready'
  $errorMessage = ''

  if (-not (Test-WinAppHostIsWindows)) {
    $reason = 'host_not_windows'
    $detail = 'Windows UI Automation is only available on Windows hosts.'
  } elseif (-not [bool]$desktop.available) {
    $reason = 'desktop_session_unavailable'
    $detail = 'An interactive Windows desktop session is required.'
  } else {
    try {
      Import-WinAppAssemblies
      $root = [System.Windows.Automation.AutomationElement]::RootElement
      $uiaAvailable = ($null -ne $root)
    } catch {
      $uiaAvailable = $false
      $errorMessage = $_.Exception.Message
    }

    try {
      $bmp = New-Object System.Drawing.Bitmap 1, 1
      try {
        $graphics = [System.Drawing.Graphics]::FromImage($bmp)
        try {
          $graphics.CopyFromScreen(0, 0, 0, 0, (New-Object System.Drawing.Size 1, 1))
          $screenshotAvailable = $true
        } finally {
          if ($null -ne $graphics) { $graphics.Dispose() }
        }
      } finally {
        if ($null -ne $bmp) { $bmp.Dispose() }
      }
    } catch {
      $screenshotAvailable = $false
      if ([string]::IsNullOrWhiteSpace($errorMessage)) {
        $errorMessage = $_.Exception.Message
      }
    }

    if (-not $uiaAvailable) {
      $reason = 'uia_unavailable'
      if ([string]::IsNullOrWhiteSpace($errorMessage)) {
        $detail = 'Failed to load System.Windows.Automation.'
      } else {
        $detail = [string]$errorMessage
      }
    } elseif (-not $screenshotAvailable) {
      $reason = 'screenshot_unavailable'
      $detail = 'Screenshot capture is unavailable in the current desktop session.'
    }
  }

  return [pscustomobject]@{
    schema = 'rayman.winapp.ready.v1'
    generated_at = Get-NowIsoTimestamp
    workspace_root = $WorkspaceRoot
    host_is_windows = Test-WinAppHostIsWindows
    desktop_session_available = [bool]$desktop.available
    desktop_session_reason = [string]$desktop.reason
    desktop_session_name = [string]$desktop.session_name
    user_interactive = [bool]$desktop.user_interactive
    uia_available = $uiaAvailable
    screenshot_available = $screenshotAvailable
    ready = ((Test-WinAppHostIsWindows) -and [bool]$desktop.available -and $uiaAvailable -and $screenshotAvailable)
    reason = $reason
    detail = $detail
    error_message = $errorMessage
  }
}

function Write-WinAppReadinessReport {
  param(
    [string]$WorkspaceRoot,
    [object]$State
  )

  $paths = Get-WinAppRuntimePaths -WorkspaceRoot $WorkspaceRoot
  Ensure-Dir -Path $paths.runtime_dir
  Ensure-Dir -Path $paths.logs_dir
  ($State | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $paths.readiness_json_path -Encoding UTF8
  Write-WinAppLogLine -Path $paths.readiness_log_path -Level 'info' -Message ('ready={0} reason={1} detail={2}' -f ([bool]$State.ready), [string]$State.reason, [string]$State.detail)
  if (-not [string]::IsNullOrWhiteSpace([string]$State.error_message)) {
    Write-WinAppLogLine -Path $paths.readiness_log_path -Level 'warn' -Message ([string]$State.error_message)
  }
  return $paths.readiness_json_path
}

function ConvertTo-WinAppControlTypeName {
  param(
    [object]$Element
  )

  try {
    $name = [string]$Element.Current.ControlType.ProgrammaticName
    if ($name.StartsWith('ControlType.', [System.StringComparison]::OrdinalIgnoreCase)) {
      $name = $name.Substring('ControlType.'.Length)
    }
    return $name
  } catch {
    return ''
  }
}

function Get-WinAppProcessNameById {
  param(
    [int]$ProcessId
  )

  if ($ProcessId -le 0) { return '' }
  $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $proc) {
    return ''
  }
  return [string]$proc.ProcessName
}

function ConvertTo-WinAppElementInfo {
  param(
    [object]$Element
  )

  if ($null -eq $Element) { return $null }
  $name = ''
  $automationId = ''
  $className = ''
  $processId = 0
  $nativeWindowHandle = 0
  $isEnabled = $false
  $boundingRectangle = $null

  try { $name = [string]$Element.Current.Name } catch {}
  try { $automationId = [string]$Element.Current.AutomationId } catch {}
  try { $className = [string]$Element.Current.ClassName } catch {}
  try { $processId = [int]$Element.Current.ProcessId } catch {}
  try { $nativeWindowHandle = [int]$Element.Current.NativeWindowHandle } catch {}
  try { $isEnabled = [bool]$Element.Current.IsEnabled } catch {}
  try { $boundingRectangle = ConvertTo-WinAppRectObject -Rect $Element.Current.BoundingRectangle } catch {}

  return [pscustomobject]@{
    name = $name
    automation_id = $automationId
    class_name = $className
    control_type = ConvertTo-WinAppControlTypeName -Element $Element
    process_id = $processId
    process_name = Get-WinAppProcessNameById -ProcessId $processId
    native_window_handle = $nativeWindowHandle
    is_enabled = $isEnabled
    bounding_rectangle = $boundingRectangle
  }
}

function Get-WinAppTopLevelWindowElements {
  param(
    [string]$WindowTitleRegex = '.*',
    [string]$ProcessName = '',
    [int]$ProcessId = 0
  )

  Import-WinAppAssemblies
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
  $matched = New-Object 'System.Collections.Generic.List[object]'
  $regex = $null
  if (-not [string]::IsNullOrWhiteSpace($WindowTitleRegex)) {
    $regex = New-Object System.Text.RegularExpressions.Regex($WindowTitleRegex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  }
  $processNeedle = ([string]$ProcessName).Trim().ToLowerInvariant()
  if ($processNeedle.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
    $processNeedle = $processNeedle.Substring(0, $processNeedle.Length - 4)
  }

  for ($i = 0; $i -lt $windows.Count; $i++) {
    $element = $windows.Item($i)
    if ($null -eq $element) { continue }
    $info = ConvertTo-WinAppElementInfo -Element $element
    if ([string]::IsNullOrWhiteSpace([string]$info.name) -and [int]$info.native_window_handle -le 0) { continue }
    if (-not [string]::IsNullOrWhiteSpace($processNeedle) -and ([string]$info.process_name).ToLowerInvariant() -ne $processNeedle) { continue }
    if ($ProcessId -gt 0 -and [int]$info.process_id -ne $ProcessId) { continue }
    if ($null -ne $regex -and -not $regex.IsMatch([string]$info.name)) { continue }
    $matched.Add($element) | Out-Null
  }

  return @($matched)
}

function Wait-WinAppWindow {
  param(
    [string]$WindowTitleRegex = '.*',
    [string]$ProcessName = '',
    [int]$ProcessId = 0,
    [int]$TimeoutSeconds = 20
  )

  $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSeconds))
  do {
    $windows = @(Get-WinAppTopLevelWindowElements -WindowTitleRegex $WindowTitleRegex -ProcessName $ProcessName -ProcessId $ProcessId)
    if ($windows.Count -gt 0) {
      return $windows[0]
    }
    Start-Sleep -Milliseconds 250
  } while ((Get-Date) -lt $deadline)

  return $null
}

function ConvertTo-WinAppElementTree {
  param(
    [object]$Element,
    [int]$Depth = 0,
    [int]$MaxDepth = 6
  )

  $node = ConvertTo-WinAppElementInfo -Element $Element
  if ($null -eq $node) { return $null }

  $children = @()
  if ($Depth -lt $MaxDepth) {
    try {
      $rawChildren = $Element.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
      $items = New-Object 'System.Collections.Generic.List[object]'
      for ($i = 0; $i -lt $rawChildren.Count; $i++) {
        $childTree = ConvertTo-WinAppElementTree -Element $rawChildren.Item($i) -Depth ($Depth + 1) -MaxDepth $MaxDepth
        if ($null -ne $childTree) {
          $items.Add($childTree) | Out-Null
        }
      }
      $children = $items.ToArray()
    } catch {
      $children = @()
    }
  }

  $ordered = [ordered]@{
    name = [string]$node.name
    automation_id = [string]$node.automation_id
    class_name = [string]$node.class_name
    control_type = [string]$node.control_type
    process_id = [int]$node.process_id
    process_name = [string]$node.process_name
    native_window_handle = [int]$node.native_window_handle
    is_enabled = [bool]$node.is_enabled
    bounding_rectangle = $node.bounding_rectangle
    children = @($children)
  }

  return [pscustomobject]$ordered
}

function ConvertTo-WinAppTreeText {
  param(
    [object]$Node,
    [int]$Depth = 0
  )

  if ($null -eq $Node) { return @() }
  $indent = ('  ' * [Math]::Max(0, $Depth))
  $label = '{0}- {1} [type={2}; id={3}; class={4}; enabled={5}]' -f $indent, [string]$Node.name, [string]$Node.control_type, [string]$Node.automation_id, [string]$Node.class_name, ([bool]$Node.is_enabled).ToString().ToLowerInvariant()
  $lines = New-Object 'System.Collections.Generic.List[string]'
  $lines.Add($label) | Out-Null
  foreach ($child in @($Node.children)) {
    foreach ($line in ConvertTo-WinAppTreeText -Node $child -Depth ($Depth + 1)) {
      $lines.Add($line) | Out-Null
    }
  }
  return @($lines)
}

function Test-WinAppSelectorMatch {
  param(
    [object]$Element,
    [object]$Selector
  )

  if ($null -eq $Selector) { return $true }
  $info = ConvertTo-WinAppElementInfo -Element $Element
  if ($null -eq $info) { return $false }

  $automationId = [string](Get-PropValue -Object $Selector -Name 'automation_id' -Default '')
  if (-not [string]::IsNullOrWhiteSpace($automationId) -and $info.automation_id -ne $automationId) { return $false }

  $name = [string](Get-PropValue -Object $Selector -Name 'name' -Default '')
  if (-not [string]::IsNullOrWhiteSpace($name) -and $info.name -ne $name) { return $false }

  $nameRegex = [string](Get-PropValue -Object $Selector -Name 'name_regex' -Default '')
  if (-not [string]::IsNullOrWhiteSpace($nameRegex)) {
    if ([string]::IsNullOrWhiteSpace($info.name) -or -not ([regex]::IsMatch($info.name, $nameRegex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase))) {
      return $false
    }
  }

  $className = [string](Get-PropValue -Object $Selector -Name 'class_name' -Default '')
  if (-not [string]::IsNullOrWhiteSpace($className) -and $info.class_name -ne $className) { return $false }

  $controlType = [string](Get-PropValue -Object $Selector -Name 'control_type' -Default '')
  if (-not [string]::IsNullOrWhiteSpace($controlType) -and $info.control_type.ToLowerInvariant() -ne $controlType.Trim().ToLowerInvariant()) { return $false }

  return $true
}

function Resolve-WinAppElement {
  param(
    [object]$RootElement,
    [object]$Selector,
    [bool]$IncludeRoot = $false
  )

  if ($null -eq $Selector) { return $RootElement }
  $matches = New-Object 'System.Collections.Generic.List[object]'

  if ($IncludeRoot -and (Test-WinAppSelectorMatch -Element $RootElement -Selector $Selector)) {
    $matches.Add($RootElement) | Out-Null
  }

  $rawDescendants = $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  for ($i = 0; $i -lt $rawDescendants.Count; $i++) {
    $element = $rawDescendants.Item($i)
    if (Test-WinAppSelectorMatch -Element $element -Selector $Selector) {
      $matches.Add($element) | Out-Null
    }
  }

  if ($matches.Count -eq 0) { return $null }
  $index = [int](Get-PropValue -Object $Selector -Name 'index' -Default 0)
  if ($index -lt 0) { $index = 0 }
  if ($index -ge $matches.Count) { return $null }
  return $matches[$index]
}

function Get-WinAppElementText {
  param(
    [object]$Element
  )

  if ($null -eq $Element) { return '' }

  $valuePattern = $null
  try {
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$valuePattern) -and $null -ne $valuePattern) {
      $value = [string]([System.Windows.Automation.ValuePattern]$valuePattern).Current.Value
      if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
  } catch {}

  $textPattern = $null
  try {
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$textPattern) -and $null -ne $textPattern) {
      $text = [string]([System.Windows.Automation.TextPattern]$textPattern).DocumentRange.GetText(-1)
      if (-not [string]::IsNullOrWhiteSpace($text)) { return $text }
    }
  } catch {}

  try {
    return [string]$Element.Current.Name
  } catch {
    return ''
  }
}

function Get-WinAppElementClickablePoint {
  param(
    [object]$Element
  )

  $rawRect = $null
  try { $rawRect = $Element.Current.BoundingRectangle } catch {}
  $rect = ConvertTo-WinAppRectObject -Rect $rawRect
  if ($null -eq $rect) { return $null }
  if ($rect.width -le 1 -or $rect.height -le 1) { return $null }
  return [pscustomobject]@{
    x = [int]([Math]::Round($rect.left + ($rect.width / 2.0)))
    y = [int]([Math]::Round($rect.top + ($rect.height / 2.0)))
  }
}

function Focus-WinAppElement {
  param(
    [object]$Element
  )

  if ($null -eq $Element) { return }
  try {
    $handle = [int]$Element.Current.NativeWindowHandle
    if ($handle -gt 0) {
      [RaymanWin32Native]::ShowWindow([IntPtr]$handle, 5) | Out-Null
      [RaymanWin32Native]::SetForegroundWindow([IntPtr]$handle) | Out-Null
    }
  } catch {}
  try {
    $Element.SetFocus()
  } catch {}
}

function Invoke-WinAppMouseClick {
  param(
    [int]$X,
    [int]$Y,
    [switch]$DoubleClick
  )

  [RaymanWin32Native]::SetCursorPos($X, $Y) | Out-Null
  $leftDown = [uint32]0x0002
  $leftUp = [uint32]0x0004
  [RaymanWin32Native]::mouse_event($leftDown, [uint32]$X, [uint32]$Y, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [RaymanWin32Native]::mouse_event($leftUp, [uint32]$X, [uint32]$Y, 0, [UIntPtr]::Zero)
  if ($DoubleClick) {
    Start-Sleep -Milliseconds 80
    [RaymanWin32Native]::mouse_event($leftDown, [uint32]$X, [uint32]$Y, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 40
    [RaymanWin32Native]::mouse_event($leftUp, [uint32]$X, [uint32]$Y, 0, [UIntPtr]::Zero)
  }
}

function Invoke-WinAppElementClick {
  param(
    [object]$Element,
    [switch]$DoubleClick
  )

  if ($null -eq $Element) {
    throw 'Target element is required for click.'
  }

  Focus-WinAppElement -Element $Element

  if (-not $DoubleClick) {
    $invokePattern = $null
    try {
      if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invokePattern) -and $null -ne $invokePattern) {
        ([System.Windows.Automation.InvokePattern]$invokePattern).Invoke()
        return 'invoke_pattern'
      }
    } catch {}

    $selectionPattern = $null
    try {
      if ($Element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$selectionPattern) -and $null -ne $selectionPattern) {
        ([System.Windows.Automation.SelectionItemPattern]$selectionPattern).Select()
        return 'selection_item_pattern'
      }
    } catch {}
  }

  $point = Get-WinAppElementClickablePoint -Element $Element
  if ($null -eq $point) {
    throw 'Unable to resolve a clickable point for the target element.'
  }

  Invoke-WinAppMouseClick -X $point.x -Y $point.y -DoubleClick:$DoubleClick
  return $(if ($DoubleClick) { 'mouse_double_click' } else { 'mouse_click' })
}

function Escape-WinAppSendKeysLiteral {
  param(
    [string]$Text
  )

  if ([string]::IsNullOrEmpty($Text)) { return '' }
  $escaped = $Text
  foreach ($ch in @('{', '}', '+', '^', '%', '~', '(', ')', '[', ']')) {
    $escaped = $escaped.Replace($ch, ('{' + $ch + '}'))
  }
  return $escaped
}

function Invoke-WinAppElementType {
  param(
    [object]$Element,
    [string]$Text
  )

  if ($null -eq $Element) {
    throw 'Target element is required for type.'
  }

  $valuePattern = $null
  try {
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$valuePattern) -and $null -ne $valuePattern) {
      ([System.Windows.Automation.ValuePattern]$valuePattern).SetValue($Text)
      return 'value_pattern'
    }
  } catch {}

  Focus-WinAppElement -Element $Element
  Start-Sleep -Milliseconds 80
  [System.Windows.Forms.SendKeys]::SendWait((Escape-WinAppSendKeysLiteral -Text $Text))
  return 'sendkeys_literal'
}

function Invoke-WinAppElementSendKeys {
  param(
    [object]$Element,
    [string]$Keys
  )

  if ($null -eq $Element) {
    throw 'Target element is required for send_keys.'
  }

  Focus-WinAppElement -Element $Element
  Start-Sleep -Milliseconds 80
  [System.Windows.Forms.SendKeys]::SendWait($Keys)
  return 'sendkeys'
}

function Capture-WinAppElementToFile {
  param(
    [object]$Element,
    [string]$Path
  )

  if ($null -eq $Element) {
    throw 'Target element is required for screenshot.'
  }

  $rawRect = $null
  try { $rawRect = $Element.Current.BoundingRectangle } catch {}
  $rect = ConvertTo-WinAppRectObject -Rect $rawRect
  if ($null -eq $rect -or $rect.width -le 1 -or $rect.height -le 1) {
    throw 'Unable to resolve a valid bounding rectangle for screenshot.'
  }

  Ensure-Dir -Path (Split-Path -Parent $Path)
  $width = [int]([Math]::Ceiling($rect.width))
  $height = [int]([Math]::Ceiling($rect.height))
  $left = [int]([Math]::Floor($rect.left))
  $top = [int]([Math]::Floor($rect.top))

  $bitmap = New-Object System.Drawing.Bitmap $width, $height
  try {
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
      $graphics.CopyFromScreen($left, $top, 0, 0, (New-Object System.Drawing.Size $width, $height))
    } finally {
      if ($null -ne $graphics) { $graphics.Dispose() }
    }
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally {
    if ($null -ne $bitmap) { $bitmap.Dispose() }
  }

  return $Path
}

function Split-WinAppLaunchCommand {
  param(
    [string]$CommandLine
  )

  $trimmed = ([string]$CommandLine).Trim()
  if ([string]::IsNullOrWhiteSpace($trimmed)) {
    throw 'launch_command is empty.'
  }

  if ($trimmed.StartsWith('"')) {
    $closingQuote = $trimmed.IndexOf('"', 1)
    if ($closingQuote -gt 0) {
      $filePath = $trimmed.Substring(1, $closingQuote - 1)
      $arguments = $trimmed.Substring($closingQuote + 1).Trim()
      return [pscustomobject]@{
        file_path = $filePath
        argument_list = $arguments
      }
    }
  }

  $spaceIndex = $trimmed.IndexOf(' ')
  if ($spaceIndex -lt 0) {
    return [pscustomobject]@{
      file_path = $trimmed
      argument_list = ''
    }
  }

  return [pscustomobject]@{
    file_path = $trimmed.Substring(0, $spaceIndex)
    argument_list = $trimmed.Substring($spaceIndex + 1).Trim()
  }
}

function Start-WinAppTargetProcess {
  param(
    [string]$LaunchCommand,
    [string]$WorkingDirectory
  )

  $parts = Split-WinAppLaunchCommand -CommandLine $LaunchCommand
  $startParams = @{
    FilePath = [string]$parts.file_path
    PassThru = $true
    WorkingDirectory = $WorkingDirectory
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$parts.argument_list)) {
    $startParams['ArgumentList'] = [string]$parts.argument_list
  }

  $process = Start-Process @startParams
  return [pscustomobject]@{
    process_id = [int]$process.Id
    file_path = [string]$parts.file_path
    argument_list = [string]$parts.argument_list
    command_line = $LaunchCommand
  }
}

function Resolve-WinAppWindowFromTarget {
  param(
    [object]$Target,
    [string]$WorkspaceRoot,
    [int]$TimeoutMs = 15000
  )

  $timeoutSeconds = [Math]::Max(1, [int]([Math]::Ceiling($TimeoutMs / 1000.0)))
  $launchCommand = [string](Get-PropValue -Object $Target -Name 'launch_command' -Default '')
  $processName = [string](Get-PropValue -Object $Target -Name 'process_name' -Default '')
  $windowTitleRegex = [string](Get-PropValue -Object $Target -Name 'window_title_regex' -Default '')

  $launch = $null
  $processId = 0
  if (-not [string]::IsNullOrWhiteSpace($launchCommand)) {
    $launch = Start-WinAppTargetProcess -LaunchCommand $launchCommand -WorkingDirectory $WorkspaceRoot
    $processId = [int]$launch.process_id
  }

  if ([string]::IsNullOrWhiteSpace($windowTitleRegex)) {
    $windowTitleRegex = '.*'
  }

  $window = Wait-WinAppWindow -WindowTitleRegex $windowTitleRegex -ProcessName $processName -ProcessId $processId -TimeoutSeconds $timeoutSeconds
  if ($null -eq $window -and $processId -gt 0 -and -not [string]::IsNullOrWhiteSpace($processName)) {
    $window = Wait-WinAppWindow -WindowTitleRegex '.*' -ProcessName $processName -TimeoutSeconds $timeoutSeconds
  }

  return [pscustomobject]@{
    launch = $launch
    window = $window
  }
}

function New-WinAppResultSkeleton {
  param(
    [string]$WorkspaceRoot,
    [string]$FlowFile,
    [int]$DefaultTimeoutMs,
    [string]$DetailLog
  )

  return [ordered]@{
    schema = 'rayman.winapp.flow.result.v1'
    generated_at = Get-NowIsoTimestamp
    workspace_root = $WorkspaceRoot
    flow_file = $FlowFile
    default_timeout_ms = $DefaultTimeoutMs
    success = $false
    degraded = $false
    degraded_reason = ''
    error_message = ''
    detail_log = $DetailLog
    launch = $null
    window = $null
    artifacts = $null
    steps = @()
  }
}

function Save-WinAppResult {
  param(
    [string]$Path,
    [hashtable]$Result
  )

  Ensure-Dir -Path (Split-Path -Parent $Path)
  ([pscustomobject]$Result | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-WinAppStepTimeoutMs {
  param(
    [object]$Step,
    [int]$DefaultTimeoutMs
  )

  $timeout = [int](Get-PropValue -Object $Step -Name 'timeout_ms' -Default $DefaultTimeoutMs)
  if ($timeout -lt 1) { return $DefaultTimeoutMs }
  return $timeout
}

function Invoke-WinAppFlow {
  param(
    [string]$WorkspaceRoot,
    [object]$Flow,
    [string]$FlowFile,
    [int]$DefaultTimeoutMs,
    [bool]$Require,
    [string]$DetailLog,
    [string]$ResultPath
  )

  $paths = Get-WinAppRuntimePaths -WorkspaceRoot $WorkspaceRoot
  Ensure-Dir -Path $paths.tests_dir
  Ensure-Dir -Path $paths.screenshots_dir
  Ensure-Dir -Path $paths.logs_dir

  $readiness = Get-WinAppReadinessState -WorkspaceRoot $WorkspaceRoot
  Write-WinAppReadinessReport -WorkspaceRoot $WorkspaceRoot -State $readiness | Out-Null

  $result = New-WinAppResultSkeleton -WorkspaceRoot $WorkspaceRoot -FlowFile $FlowFile -DefaultTimeoutMs $DefaultTimeoutMs -DetailLog $DetailLog
  $result['artifacts'] = [ordered]@{
    last_result_json = $ResultPath
    readiness_json = $paths.readiness_json_path
    screenshots_dir = $paths.screenshots_dir
  }

  if (-not [bool]$readiness.ready) {
    $result['degraded'] = $true
    $result['degraded_reason'] = [string]$readiness.reason
    $result['error_message'] = [string]$readiness.detail
    Save-WinAppResult -Path $ResultPath -Result $result
    if ($Require) {
      throw ('Windows desktop automation unavailable: {0} ({1})' -f [string]$readiness.reason, [string]$readiness.detail)
    }
    return [pscustomobject]$result
  }

  Import-WinAppAssemblies

  $target = Get-PropValue -Object $Flow -Name 'target' -Default $null
  if ($null -eq $target) {
    throw 'Flow target is required.'
  }

  $resolvedWindow = Resolve-WinAppWindowFromTarget -Target $target -WorkspaceRoot $WorkspaceRoot -TimeoutMs $DefaultTimeoutMs
  $window = $resolvedWindow.window
  if ($null -eq $window) {
    throw 'Unable to resolve a target window from flow target.'
  }

  $result['launch'] = $resolvedWindow.launch
  $result['window'] = ConvertTo-WinAppElementInfo -Element $window
  $currentWindow = $window
  $stepResults = New-Object 'System.Collections.Generic.List[object]'
  $stepIndex = 0

  foreach ($step in @($Flow.steps)) {
    $stepIndex++
    $action = ([string](Get-PropValue -Object $step -Name 'action' -Default '')).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($action)) {
      throw ('Step {0} is missing action.' -f $stepIndex)
    }

    $timeoutMs = Get-WinAppStepTimeoutMs -Step $step -DefaultTimeoutMs $DefaultTimeoutMs
    $selector = Get-PropValue -Object $step -Name 'selector' -Default $null
    $stepResult = [ordered]@{
      index = $stepIndex
      action = $action
      success = $true
      selector = $selector
      detail = ''
      screenshot_path = ''
    }

    Write-WinAppLogLine -Path $DetailLog -Level 'info' -Message ('step={0} action={1}' -f $stepIndex, $action)
    switch ($action) {
      'wait_window' {
        $stepRegex = [string](Get-PropValue -Object $step -Name 'window_title_regex' -Default (Get-PropValue -Object $target -Name 'window_title_regex' -Default '.*'))
        $stepProcessName = [string](Get-PropValue -Object $step -Name 'process_name' -Default (Get-PropValue -Object $target -Name 'process_name' -Default ''))
        $waited = Wait-WinAppWindow -WindowTitleRegex $stepRegex -ProcessName $stepProcessName -TimeoutSeconds ([Math]::Max(1, [int]([Math]::Ceiling($timeoutMs / 1000.0))))
        if ($null -eq $waited) {
          throw ('Step {0}: wait_window failed for regex={1} process={2}' -f $stepIndex, $stepRegex, $stepProcessName)
        }
        $currentWindow = $waited
        $stepResult['detail'] = 'window_ready'
      }
      'click' {
        $element = Resolve-WinAppElement -RootElement $currentWindow -Selector $selector
        if ($null -eq $element) { throw ('Step {0}: target element not found for click.' -f $stepIndex) }
        $stepResult['detail'] = Invoke-WinAppElementClick -Element $element
      }
      'double_click' {
        $element = Resolve-WinAppElement -RootElement $currentWindow -Selector $selector
        if ($null -eq $element) { throw ('Step {0}: target element not found for double_click.' -f $stepIndex) }
        $stepResult['detail'] = Invoke-WinAppElementClick -Element $element -DoubleClick
      }
      'focus' {
        $element = Resolve-WinAppElement -RootElement $currentWindow -Selector $selector
        if ($null -eq $element) { throw ('Step {0}: target element not found for focus.' -f $stepIndex) }
        Focus-WinAppElement -Element $element
        $stepResult['detail'] = 'focused'
      }
      'type' {
        $text = [string](Get-PropValue -Object $step -Name 'text' -Default (Get-PropValue -Object $step -Name 'value' -Default ''))
        $element = Resolve-WinAppElement -RootElement $currentWindow -Selector $selector
        if ($null -eq $element) { throw ('Step {0}: target element not found for type.' -f $stepIndex) }
        $stepResult['detail'] = Invoke-WinAppElementType -Element $element -Text $text
      }
      'send_keys' {
        $keys = [string](Get-PropValue -Object $step -Name 'keys' -Default '')
        if ([string]::IsNullOrWhiteSpace($keys)) { throw ('Step {0}: send_keys requires keys.' -f $stepIndex) }
        $element = if ($null -ne $selector) { Resolve-WinAppElement -RootElement $currentWindow -Selector $selector } else { $currentWindow }
        if ($null -eq $element) { throw ('Step {0}: target element not found for send_keys.' -f $stepIndex) }
        $stepResult['detail'] = Invoke-WinAppElementSendKeys -Element $element -Keys $keys
      }
      'assert_exists' {
        $element = Resolve-WinAppElement -RootElement $currentWindow -Selector $selector
        if ($null -eq $element) { throw ('Step {0}: assert_exists failed.' -f $stepIndex) }
        $stepResult['detail'] = 'exists'
      }
      'assert_text_contains' {
        $expected = [string](Get-PropValue -Object $step -Name 'text' -Default '')
        if ([string]::IsNullOrWhiteSpace($expected)) { throw ('Step {0}: assert_text_contains requires text.' -f $stepIndex) }
        $element = Resolve-WinAppElement -RootElement $currentWindow -Selector $selector
        if ($null -eq $element) { throw ('Step {0}: target element not found for assert_text_contains.' -f $stepIndex) }
        $actual = Get-WinAppElementText -Element $element
        if ([string]::IsNullOrWhiteSpace($actual) -or -not $actual.Contains($expected)) {
          throw ('Step {0}: assert_text_contains failed. expected={1} actual={2}' -f $stepIndex, $expected, $actual)
        }
        $stepResult['detail'] = 'text_contains'
      }
      'assert_enabled' {
        $element = Resolve-WinAppElement -RootElement $currentWindow -Selector $selector
        if ($null -eq $element) { throw ('Step {0}: target element not found for assert_enabled.' -f $stepIndex) }
        $info = ConvertTo-WinAppElementInfo -Element $element
        if (-not [bool]$info.is_enabled) {
          throw ('Step {0}: assert_enabled failed.' -f $stepIndex)
        }
        $stepResult['detail'] = 'enabled'
      }
      'screenshot' {
        $element = if ($null -ne $selector) { Resolve-WinAppElement -RootElement $currentWindow -Selector $selector } else { $currentWindow }
        if ($null -eq $element) { throw ('Step {0}: target element not found for screenshot.' -f $stepIndex) }
        $fileName = [string](Get-PropValue -Object $step -Name 'file_name' -Default ('step-{0:D2}.png' -f $stepIndex))
        $outputPath = Join-Path $paths.screenshots_dir $fileName
        $savedPath = Capture-WinAppElementToFile -Element $element -Path $outputPath
        $stepResult['detail'] = 'screenshot_saved'
        $stepResult['screenshot_path'] = $savedPath
      }
      default {
        throw ('Step {0}: unsupported action `{1}`.' -f $stepIndex, $action)
      }
    }

    $stepResults.Add([pscustomobject]$stepResult) | Out-Null
    Start-Sleep -Milliseconds ([Math]::Min($timeoutMs, 120))
  }

  $result['steps'] = @($stepResults)
  $result['success'] = $true
  Save-WinAppResult -Path $ResultPath -Result $result
  return [pscustomobject]$result
}

function Read-WinAppFlowFile {
  param(
    [string]$FlowFilePath
  )

  if (-not (Test-Path -LiteralPath $FlowFilePath -PathType Leaf)) {
    throw ('Flow file not found: {0}' -f $FlowFilePath)
  }

  $flow = Get-Content -LiteralPath $FlowFilePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $schema = [string](Get-PropValue -Object $flow -Name 'schema' -Default '')
  if ($schema -ne 'rayman.winapp.flow.v1') {
    throw ('Unsupported flow schema: {0}' -f $schema)
  }

  $target = Get-PropValue -Object $flow -Name 'target' -Default $null
  if ($null -eq $target) {
    throw 'Flow target is required.'
  }

  $launchCommand = [string](Get-PropValue -Object $target -Name 'launch_command' -Default '')
  $processName = [string](Get-PropValue -Object $target -Name 'process_name' -Default '')
  $titleRegex = [string](Get-PropValue -Object $target -Name 'window_title_regex' -Default '')
  if ([string]::IsNullOrWhiteSpace($launchCommand) -and [string]::IsNullOrWhiteSpace($processName) -and [string]::IsNullOrWhiteSpace($titleRegex)) {
    throw 'Flow target must declare launch_command, process_name, or window_title_regex.'
  }

  $steps = @($flow.steps)
  if ($steps.Count -eq 0) {
    throw 'Flow steps are required.'
  }

  return $flow
}

function Get-WinAppWindowControlTree {
  param(
    [object]$Window,
    [int]$MaxDepth = 6
  )

  $tree = ConvertTo-WinAppElementTree -Element $Window -Depth 0 -MaxDepth $MaxDepth
  $text = @((ConvertTo-WinAppTreeText -Node $tree -Depth 0) -join [Environment]::NewLine)
  return [pscustomobject]@{
    tree = $tree
    text = $text
  }
}
