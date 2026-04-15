param(
  [string]$WorkspaceRoot = $(if (-not [string]::IsNullOrWhiteSpace([string]$PSScriptRoot)) { (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path } else { (Get-Location).Path }),
  [Parameter(Position = 0)][ValidateSet('register')][string]$Action = 'register',
  [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$CliArgs,
  [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$savedWorkspaceRegisterCliState = @{
  WorkspaceRoot = $WorkspaceRoot
  Action = $Action
  CliArgs = @($CliArgs)
  NoMain = [bool]$NoMain
}

. (Join-Path $PSScriptRoot '..\..\common.ps1')
. (Join-Path $PSScriptRoot '..\release\package_distributable.ps1') -NoMain

$WorkspaceRoot = [string]$savedWorkspaceRegisterCliState.WorkspaceRoot
$Action = [string]$savedWorkspaceRegisterCliState.Action
$CliArgs = @($savedWorkspaceRegisterCliState.CliArgs)
$NoMain = [bool]$savedWorkspaceRegisterCliState.NoMain

function Ensure-RaymanWorkspaceRegisterDirectory {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace([string]$Path)) { return }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Write-RaymanWorkspaceRegisterUtf8NoBom {
  param(
    [string]$Path,
    [string]$Content
  )

  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace([string]$parent)) {
    Ensure-RaymanWorkspaceRegisterDirectory -Path $parent
  }

  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Write-RaymanWorkspaceRegisterJsonFile {
  param(
    [string]$Path,
    [object]$Value,
    [int]$Depth = 16
  )

  $json = ($Value | ConvertTo-Json -Depth $Depth)
  Write-RaymanWorkspaceRegisterUtf8NoBom -Path $Path -Content (($json.TrimEnd()) + "`n")
}

function Read-RaymanWorkspaceRegisterJsonFile {
  param([string]$Path)

  if (Get-Command Read-RaymanJsonFile -ErrorAction SilentlyContinue) {
    $doc = Read-RaymanJsonFile -Path $Path
    if ($null -eq $doc -or -not [bool]$doc.Exists -or [bool]$doc.ParseFailed) {
      return $null
    }
    return $doc.Obj
  }

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  try {
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Resolve-RaymanWorkspaceRegisterPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace([string]$Path)) {
    return ''
  }

  try {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath([string]$Path)
  } catch {
    return [System.IO.Path]::GetFullPath([string]$Path)
  }
}

function Get-RaymanWorkspaceRegisterNormalizedPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace([string]$Path)) { return '' }
  return ([System.IO.Path]::GetFullPath([string]$Path)).TrimEnd('\', '/').ToLowerInvariant()
}

function Get-RaymanWorkspaceRegisterLocalAppDataRoot {
  $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
  if ([string]::IsNullOrWhiteSpace([string]$localAppData)) {
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace([string]$userProfile)) {
      $userProfile = [Environment]::GetEnvironmentVariable('USERPROFILE')
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$userProfile)) {
      $localAppData = Join-Path $userProfile 'AppData\Local'
    }
  }
  if ([string]::IsNullOrWhiteSpace([string]$localAppData)) {
    throw 'workspace-register could not resolve LOCALAPPDATA.'
  }
  return (Resolve-RaymanWorkspaceRegisterPath -Path $localAppData)
}

function Get-RaymanWorkspaceRegisterAppDataRoot {
  $appData = [Environment]::GetEnvironmentVariable('APPDATA')
  if ([string]::IsNullOrWhiteSpace([string]$appData)) {
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace([string]$userProfile)) {
      $userProfile = [Environment]::GetEnvironmentVariable('USERPROFILE')
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$userProfile)) {
      $appData = Join-Path $userProfile 'AppData\Roaming'
    }
  }
  if ([string]::IsNullOrWhiteSpace([string]$appData)) {
    throw 'workspace-register could not resolve APPDATA.'
  }
  return (Resolve-RaymanWorkspaceRegisterPath -Path $appData)
}

function Get-RaymanWorkspaceRegisterUserRoot {
  return (Join-Path (Get-RaymanWorkspaceRegisterLocalAppDataRoot) 'Rayman')
}

function Get-RaymanWorkspaceRegisterStateRoot {
  $path = Join-Path (Get-RaymanWorkspaceRegisterUserRoot) 'state'
  Ensure-RaymanWorkspaceRegisterDirectory -Path $path
  return $path
}

function Get-RaymanWorkspaceRegisterRuntimeRoot {
  $path = Join-Path (Get-RaymanWorkspaceRegisterUserRoot) 'runtime'
  Ensure-RaymanWorkspaceRegisterDirectory -Path $path
  return $path
}

function Get-RaymanWorkspaceRegisterBinRoot {
  $path = Join-Path (Get-RaymanWorkspaceRegisterUserRoot) 'bin'
  Ensure-RaymanWorkspaceRegisterDirectory -Path $path
  return $path
}

function Get-RaymanWorkspaceRegisterSourceStatePath {
  return (Join-Path (Get-RaymanWorkspaceRegisterStateRoot) 'workspace_source.json')
}

function Get-RaymanWorkspaceRegisterLastPath {
  return (Join-Path (Get-RaymanWorkspaceRegisterRuntimeRoot) 'workspace_register.last.json')
}

function Get-RaymanWorkspaceRegisterLauncherPs1Path {
  return (Join-Path (Get-RaymanWorkspaceRegisterBinRoot) 'rayman-here.ps1')
}

function Get-RaymanWorkspaceRegisterLauncherCmdPath {
  return (Join-Path (Get-RaymanWorkspaceRegisterBinRoot) 'rayman-here.cmd')
}

function Get-RaymanWorkspaceRegisterWindowsAppsRoot {
  return (Join-Path (Get-RaymanWorkspaceRegisterLocalAppDataRoot) 'Microsoft\WindowsApps')
}

function Get-RaymanWorkspaceRegisterLauncherShimCmdPath {
  return (Join-Path (Get-RaymanWorkspaceRegisterWindowsAppsRoot) 'rayman-here.cmd')
}

function Get-RaymanWorkspaceRegisterDesktopBootstrapPs1Path {
  return (Join-Path (Get-RaymanWorkspaceRegisterBinRoot) 'rayman-codex-desktop-bootstrap.ps1')
}

function Get-RaymanWorkspaceRegisterDesktopBootstrapCmdPath {
  return (Join-Path (Get-RaymanWorkspaceRegisterBinRoot) 'rayman-codex-desktop-bootstrap.cmd')
}

function Get-RaymanWorkspaceRegisterDesktopBootstrapStartupVbsPath {
  return (Join-Path (Get-RaymanWorkspaceRegisterStartupRoot) 'rayman-codex-desktop-bootstrap.vbs')
}

function Get-RaymanWorkspaceRegisterDesktopBootstrapLegacyStartupCmdPath {
  return (Join-Path (Get-RaymanWorkspaceRegisterStartupRoot) 'rayman-codex-desktop-bootstrap.cmd')
}

function Get-RaymanWorkspaceRegisterStartupRoot {
  return (Join-Path (Get-RaymanWorkspaceRegisterAppDataRoot) 'Microsoft\Windows\Start Menu\Programs\Startup')
}

function Get-RaymanWorkspaceRegisterUserProfileRoot {
  $userProfile = [Environment]::GetEnvironmentVariable('USERPROFILE')
  if ([string]::IsNullOrWhiteSpace([string]$userProfile)) {
    $userProfile = [Environment]::GetEnvironmentVariable('HOME')
  }
  if ([string]::IsNullOrWhiteSpace([string]$userProfile)) {
    $userProfile = [Environment]::GetFolderPath('UserProfile')
  }
  if ([string]::IsNullOrWhiteSpace([string]$userProfile)) {
    throw 'workspace-register could not resolve USERPROFILE.'
  }
  return (Resolve-RaymanWorkspaceRegisterPath -Path $userProfile)
}

function Get-RaymanWorkspaceRegisterCodexRoot {
  return (Join-Path (Get-RaymanWorkspaceRegisterUserProfileRoot) '.codex')
}

function Get-RaymanWorkspaceRegisterCodexConfigPath {
  return (Join-Path (Get-RaymanWorkspaceRegisterCodexRoot) 'config.toml')
}

function Get-RaymanWorkspaceRegisterCodexNotifyScriptPath {
  return (Join-Path (Get-RaymanWorkspaceRegisterCodexRoot) 'notify.ps1')
}

function Get-RaymanWorkspaceRegisterVsCodeTasksPath {
  return (Join-Path (Get-RaymanWorkspaceRegisterAppDataRoot) 'Code\User\tasks.json')
}

function Get-RaymanWorkspaceRegisterVersion {
  param([string]$WorkspaceRoot)

  $versionPath = Join-Path $WorkspaceRoot '.Rayman\VERSION'
  if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
    return 'unknown'
  }

  try {
    return (Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8).Trim()
  } catch {
    return 'unknown'
  }
}

function Test-RaymanWorkspaceRegisterSourceWorkspace {
  param([string]$WorkspaceRoot)

  if ([string]::IsNullOrWhiteSpace([string]$WorkspaceRoot)) {
    return $false
  }

  $requiredPaths = @(
    (Join-Path $WorkspaceRoot '.Rayman\rayman.ps1'),
    (Join-Path $WorkspaceRoot '.Rayman\setup.ps1'),
    (Join-Path $WorkspaceRoot '.Rayman\VERSION'),
    (Join-Path $WorkspaceRoot '.RaymanAgent\.RaymanAgent.requirements.md')
  )

  foreach ($path in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      return $false
    }
  }

  return $true
}

function Remove-RaymanWorkspaceRegisterJsonComments {
  param([string]$Text)

  if ([string]::IsNullOrEmpty($Text)) { return $Text }
  $sb = New-Object System.Text.StringBuilder
  $inString = $false
  $escapeNext = $false
  $inLineComment = $false
  $inBlockComment = $false
  for ($i = 0; $i -lt $Text.Length; $i++) {
    $c = $Text[$i]
    $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }

    if ($inLineComment) {
      if ($c -eq "`n") {
        $inLineComment = $false
        [void]$sb.Append($c)
      }
      continue
    }

    if ($inBlockComment) {
      if ($c -eq '*' -and $next -eq '/') {
        $inBlockComment = $false
        $i++
      }
      continue
    }

    if ($inString) {
      [void]$sb.Append($c)
      if ($escapeNext) {
        $escapeNext = $false
      } elseif ($c -eq '\') {
        $escapeNext = $true
      } elseif ($c -eq '"') {
        $inString = $false
      }
      continue
    }

    if ($c -eq '"') {
      $inString = $true
      [void]$sb.Append($c)
      continue
    }

    if ($c -eq '/' -and $next -eq '/') {
      $inLineComment = $true
      $i++
      continue
    }

    if ($c -eq '/' -and $next -eq '*') {
      $inBlockComment = $true
      $i++
      continue
    }

    [void]$sb.Append($c)
  }
  return $sb.ToString()
}

function Remove-RaymanWorkspaceRegisterJsonTrailingCommas {
  param([string]$Text)

  if ([string]::IsNullOrEmpty($Text)) { return $Text }
  $sb = New-Object System.Text.StringBuilder
  $inString = $false
  $escapeNext = $false
  for ($i = 0; $i -lt $Text.Length; $i++) {
    $c = $Text[$i]
    if ($inString) {
      [void]$sb.Append($c)
      if ($escapeNext) {
        $escapeNext = $false
      } elseif ($c -eq '\') {
        $escapeNext = $true
      } elseif ($c -eq '"') {
        $inString = $false
      }
      continue
    }

    if ($c -eq '"') {
      $inString = $true
      [void]$sb.Append($c)
      continue
    }

    if ($c -eq ',') {
      $j = $i + 1
      while ($j -lt $Text.Length -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
      if ($j -lt $Text.Length -and ($Text[$j] -eq '}' -or $Text[$j] -eq ']')) {
        continue
      }
    }

    [void]$sb.Append($c)
  }
  return $sb.ToString()
}

function Read-RaymanWorkspaceRegisterJsonDoc {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return [pscustomobject]@{
      Exists = $false
      ParseFailed = $false
      Obj = $null
    }
  }

  try {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
      return [pscustomobject]@{
        Exists = $true
        ParseFailed = $false
        Obj = $null
      }
    }

    $clean = Remove-RaymanWorkspaceRegisterJsonTrailingCommas -Text (Remove-RaymanWorkspaceRegisterJsonComments -Text $raw)
    return [pscustomobject]@{
      Exists = $true
      ParseFailed = $false
      Obj = ($clean | ConvertFrom-Json -ErrorAction Stop)
    }
  } catch {
    return [pscustomobject]@{
      Exists = $true
      ParseFailed = $true
      Obj = $null
    }
  }
}

function Find-RaymanWorkspaceRegisterDictionaryKey {
  param(
    [System.Collections.IDictionary]$Dict,
    [string]$Name
  )

  if ($null -eq $Dict) { return $null }
  foreach ($key in $Dict.Keys) {
    if ([string]$key -eq $Name) {
      return $key
    }
  }
  return $null
}

function Get-RaymanWorkspaceRegisterJsonProperty {
  param(
    [object]$Obj,
    [string]$Name
  )

  if ($null -eq $Obj) { return $null }
  if ($Obj -is [System.Collections.IDictionary]) {
    $dictKey = Find-RaymanWorkspaceRegisterDictionaryKey -Dict $Obj -Name $Name
    if ($null -ne $dictKey) {
      return $Obj[$dictKey]
    }
    return $null
  }

  $prop = $Obj.PSObject.Properties[$Name]
  if ($prop) { return $prop.Value }
  return $null
}

function Set-RaymanWorkspaceRegisterJsonProperty {
  param(
    [object]$Obj,
    [string]$Name,
    $Value
  )

  if ($Obj -is [System.Collections.IDictionary]) {
    $dictKey = Find-RaymanWorkspaceRegisterDictionaryKey -Dict $Obj -Name $Name
    if ($null -ne $dictKey) {
      $Obj[$dictKey] = $Value
    } else {
      $Obj[$Name] = $Value
    }
    return
  }

  $prop = $Obj.PSObject.Properties[$Name]
  if ($prop) {
    $prop.Value = $Value
    return
  }

  Add-Member -InputObject $Obj -MemberType NoteProperty -Name $Name -Value $Value
}

function Get-RaymanWorkspaceRegisterUserEnvironmentVariable {
  param([string]$Name)

  return [Environment]::GetEnvironmentVariable([string]$Name, 'User')
}

function Set-RaymanWorkspaceRegisterUserEnvironmentVariable {
  param(
    [string]$Name,
    [AllowNull()][string]$Value
  )

  [Environment]::SetEnvironmentVariable([string]$Name, $Value, 'User')
}

function Get-RaymanWorkspaceRegisterProcessEnvironmentVariable {
  param([string]$Name)

  return [Environment]::GetEnvironmentVariable([string]$Name, 'Process')
}

function Set-RaymanWorkspaceRegisterProcessEnvironmentVariable {
  param(
    [string]$Name,
    [AllowNull()][string]$Value
  )

  [Environment]::SetEnvironmentVariable([string]$Name, $Value, 'Process')
}

function Test-RaymanWorkspaceRegisterPathInList {
  param(
    [string]$PathList,
    [string]$CandidatePath
  )

  $normalizedCandidate = Get-RaymanWorkspaceRegisterNormalizedPath -Path $CandidatePath
  if ([string]::IsNullOrWhiteSpace([string]$normalizedCandidate)) {
    return $false
  }

  foreach ($entry in @(([string]$PathList) -split ';')) {
    if ([string]::IsNullOrWhiteSpace([string]$entry)) { continue }
    try {
      $normalizedEntry = Get-RaymanWorkspaceRegisterNormalizedPath -Path $entry
    } catch {
      continue
    }
    if ($normalizedEntry -eq $normalizedCandidate) {
      return $true
    }
  }

  return $false
}

function Add-RaymanWorkspaceRegisterPathEntry {
  param(
    [string]$PathList,
    [string]$EntryPath
  )

  if (Test-RaymanWorkspaceRegisterPathInList -PathList $PathList -CandidatePath $EntryPath) {
    return [string]$PathList
  }

  $segments = New-Object System.Collections.Generic.List[string]
  foreach ($segment in @(([string]$PathList) -split ';')) {
    if ([string]::IsNullOrWhiteSpace([string]$segment)) { continue }
    $segments.Add([string]$segment) | Out-Null
  }
  $segments.Add([string]$EntryPath) | Out-Null
  return (@($segments.ToArray()) -join ';')
}

function Invoke-RaymanWorkspaceRegisterEnvironmentBroadcast {
  if (-not (Test-RaymanWindowsPlatform)) {
    return $false
  }

  $nativeType = 'RaymanWorkspaceRegisterNative'
  if ($null -eq ($nativeType -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class RaymanWorkspaceRegisterNative
{
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint Msg,
        IntPtr wParam,
        string lParam,
        uint fuFlags,
        uint uTimeout,
        out UIntPtr lpdwResult);
}
"@
  }

  $messageResult = [UIntPtr]::Zero
  [void][RaymanWorkspaceRegisterNative]::SendMessageTimeout(
    [IntPtr]0xffff,
    0x001A,
    [IntPtr]::Zero,
    'Environment',
    0x0002,
    2000,
    [ref]$messageResult)
  return $true
}

function Convert-ToRaymanWorkspaceRegisterTomlLiteralString {
  param([string]$Value)

  if ($null -eq $Value) { return '""' }
  return ('"{0}"' -f (($Value -replace '\\', '\\\\') -replace '"', '\"'))
}

function Convert-ToRaymanWorkspaceRegisterTomlArray {
  param([string[]]$Values)

  $rendered = @()
  foreach ($value in @($Values)) {
    $rendered += (Convert-ToRaymanWorkspaceRegisterTomlLiteralString -Value ([string]$value))
  }
  return ('[{0}]' -f ($rendered -join ', '))
}

function Set-RaymanWorkspaceRegisterManagedBlock {
  param(
    [string]$ConfigPath,
    [string]$ManagedBlock,
    [string]$BlockName
  )

  $startMarker = ('# >>> Rayman managed {0} >>>' -f $BlockName)
  $endMarker = ('# <<< Rayman managed {0} <<<' -f $BlockName)
  $pattern = ('(?s)[ \t]*{0}.*?{1}\r?\n?' -f [regex]::Escape($startMarker), [regex]::Escape($endMarker))
  $existing = ''
  if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    $existing = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
  }

  $updated = $existing
  $hadBlock = ($existing -match [regex]::Escape($startMarker) -and $existing -match [regex]::Escape($endMarker))
  if ([string]::IsNullOrWhiteSpace([string]$ManagedBlock)) {
    if ($hadBlock) {
      $updated = [regex]::Replace($existing, $pattern, '', 1)
      $updated = $updated.TrimEnd()
      if (-not [string]::IsNullOrWhiteSpace([string]$updated)) {
        $updated += "`r`n"
      }
    }
  } elseif ($hadBlock) {
    $updated = [regex]::Replace($existing, $pattern, ($ManagedBlock + "`r`n"), 1)
  } else {
    $prefix = $existing.TrimEnd()
    if ([string]::IsNullOrWhiteSpace([string]$prefix)) {
      $updated = ($ManagedBlock + "`r`n")
    } else {
      $updated = ($prefix + "`r`n`r`n" + $ManagedBlock + "`r`n")
    }
  }

  $changed = ($updated -ne $existing)
  if ($changed) {
    $configDir = Split-Path -Parent $ConfigPath
    Ensure-RaymanWorkspaceRegisterDirectory -Path $configDir
    Write-RaymanWorkspaceRegisterUtf8NoBom -Path $ConfigPath -Content $updated
  }

  return [pscustomobject]@{
    changed = $changed
    had_block = $hadBlock
  }
}

function Get-RaymanWorkspaceRegisterCodexNotifyDefinition {
  $notifyScriptPath = Get-RaymanWorkspaceRegisterCodexNotifyScriptPath
  return [pscustomobject]@{
    command = 'powershell.exe'
    args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $notifyScriptPath)
  }
}

function Render-RaymanWorkspaceRegisterManagedNotifyBlock {
  $notify = Get-RaymanWorkspaceRegisterCodexNotifyDefinition
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# >>> Rayman managed notify >>>') | Out-Null
  $lines.Add('# Rayman manages this block. Edit outside these markers only.') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add(('notify = {0}' -f (Convert-ToRaymanWorkspaceRegisterTomlArray -Values (@([string]$notify.command) + @($notify.args))))) | Out-Null
  $lines.Add('# <<< Rayman managed notify <<<') | Out-Null
  return (($lines -join "`r`n").TrimEnd())
}

function Get-RaymanWorkspaceRegisterCodexNotifyScriptContent {
  return @"
param(
  [Parameter(ValueFromRemainingArguments = `$true)][string[]]`$Args
)

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'

`$userHome = [Environment]::GetFolderPath('UserProfile')
if ([string]::IsNullOrWhiteSpace([string]`$userHome)) {
  `$userHome = [Environment]::GetEnvironmentVariable('USERPROFILE')
}
if ([string]::IsNullOrWhiteSpace([string]`$userHome)) {
  `$userHome = [Environment]::GetEnvironmentVariable('HOME')
}
if ([string]::IsNullOrWhiteSpace([string]`$userHome)) {
  `$userHome = ''
}

`$codexHome = if ([string]::IsNullOrWhiteSpace([string]`$userHome)) { '' } else { Join-Path `$userHome '.codex' }
`$logPath = if ([string]::IsNullOrWhiteSpace([string]`$codexHome)) { '' } else { Join-Path `$codexHome 'log\notify-events.jsonl' }
`$interactiveMarkers = @(
  'request_user_input',
  'needs_user_input',
  'requires_user_input',
  'approval_required',
  'approval-request'
)

function Get-PayloadValue([object]`$Payload, [string]`$Name, [string]`$Default = '') {
  if (`$null -eq `$Payload) { return `$Default }
  if (`$Payload -is [System.Collections.IDictionary]) {
    if (`$Payload.Contains(`$Name) -and `$null -ne `$Payload[`$Name]) {
      return [string]`$Payload[`$Name]
    }
    return `$Default
  }
  `$prop = `$Payload.PSObject.Properties[`$Name]
  if (`$null -eq `$prop -or `$null -eq `$prop.Value) { return `$Default }
  return [string]`$prop.Value
}

function Get-PayloadEventType {
  param([object]`$Payload)
  return (Get-PayloadValue -Payload `$Payload -Name 'type' -Default '')
}

function Get-PayloadExcerpt {
  param([string]`$SerializedPayload)

  if ([string]::IsNullOrWhiteSpace([string]`$SerializedPayload)) { return '' }
  `$singleLine = ((`$SerializedPayload -replace '\s+', ' ').Trim())
  if (`$singleLine.Length -le 400) { return `$singleLine }
  return (`$singleLine.Substring(0, 400) + '...')
}

function Resolve-NotifyWorkspaceRoot {
  param([object]`$Payload)

  `$candidates = New-Object System.Collections.Generic.List[string]
  foreach (`$entry in @(
      (Get-PayloadValue -Payload `$Payload -Name 'cwd' -Default ''),
      (Get-PayloadValue -Payload `$Payload -Name 'workspace_root' -Default '')
    )) {
    if (-not [string]::IsNullOrWhiteSpace([string]`$entry)) {
      `$candidates.Add([string]`$entry) | Out-Null
    }
  }

  foreach (`$candidate in @(`$candidates.ToArray() | Select-Object -Unique)) {
    `$current = [string]`$candidate
    while (-not [string]::IsNullOrWhiteSpace([string]`$current)) {
      try {
        `$current = [System.IO.Path]::GetFullPath(`$current)
      } catch {}
      if (Test-Path -LiteralPath (Join-Path `$current '.Rayman') -PathType Container) {
        return `$current
      }
      `$parent = Split-Path -Parent `$current
      if ([string]::IsNullOrWhiteSpace([string]`$parent) -or `$parent -eq `$current) {
        break
      }
      `$current = `$parent
    }
  }

  return ''
}

function Resolve-NotifySoundPath {
  `$managedPath = if ([string]::IsNullOrWhiteSpace([string]`$userHome)) { '' } else { Join-Path `$userHome '.rayman\codex\notify.wav' }
  if (-not [string]::IsNullOrWhiteSpace([string]`$managedPath) -and (Test-Path -LiteralPath `$managedPath -PathType Leaf)) {
    return `$managedPath
  }
  `$legacyPath = if ([string]::IsNullOrWhiteSpace([string]`$userHome)) { '' } else { Join-Path `$userHome '.codex\notify.wav' }
  if (-not [string]::IsNullOrWhiteSpace([string]`$legacyPath) -and (Test-Path -LiteralPath `$legacyPath -PathType Leaf)) {
    return `$legacyPath
  }
  return `$managedPath
}

function Write-NotifyDiagnostic {
  param(
    [string]`$EventType,
    [string]`$MatchedReason,
    [bool]`$SoundAttempted,
    [string]`$ResolvedSoundPath,
    [string]`$PayloadExcerpt,
    [string]`$WorkspaceRoot,
    [bool]`$Delegated
  )

  if ([string]::IsNullOrWhiteSpace([string]`$logPath)) { return }
  try {
    `$logDir = Split-Path -Parent `$logPath
    if (-not [string]::IsNullOrWhiteSpace([string]`$logDir) -and -not (Test-Path -LiteralPath `$logDir -PathType Container)) {
      New-Item -ItemType Directory -Force -Path `$logDir | Out-Null
    }

    `$record = [ordered]@{
      timestamp = (Get-Date).ToString('o')
      event_type = `$EventType
      matched_reason = `$MatchedReason
      sound_attempted = `$SoundAttempted
      sound_path = `$ResolvedSoundPath
      workspace_root = `$WorkspaceRoot
      delegated = `$Delegated
      payload_excerpt = `$PayloadExcerpt
    }
    `$json = (`$record | ConvertTo-Json -Compress)
    [System.IO.File]::AppendAllText(`$logPath, `$json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new(`$false))
  } catch {
  }
}

function Resolve-NotifyMatch {
  param(
    [string]`$EventType,
    [string]`$SerializedPayload
  )

  if ([string]::Equals(`$EventType, 'agent-turn-complete', [System.StringComparison]::OrdinalIgnoreCase)) {
    return 'event_type:agent-turn-complete'
  }

  `$normalized = if ([string]::IsNullOrWhiteSpace([string]`$SerializedPayload)) { '' } else { `$SerializedPayload.ToLowerInvariant() }
  foreach (`$marker in @(`$interactiveMarkers)) {
    if (-not [string]::IsNullOrWhiteSpace([string]`$normalized) -and `$normalized.Contains(`$marker.ToLowerInvariant())) {
      return ('payload_marker:{0}' -f `$marker)
    }
  }

  return ''
}

function Invoke-NotifySound {
  param([string]`$ResolvedSoundPath)

  if ([string]::IsNullOrWhiteSpace([string]`$ResolvedSoundPath) -or -not (Test-Path -LiteralPath `$ResolvedSoundPath -PathType Leaf)) {
    return `$false
  }

  try {
    `$player = New-Object System.Media.SoundPlayer `$ResolvedSoundPath
    `$player.Load()
    `$player.PlaySync()
    return `$true
  } catch {
    return `$false
  }
}

try {
  if (`$Args.Count -eq 0) { exit 0 }

  `$serializedPayload = [string]`$Args[`$Args.Count - 1]
  `$payload = `$null
  `$eventType = ''
  `$matchedReason = ''
  `$soundAttempted = `$false
  `$delegated = `$false
  `$workspaceRoot = ''
  `$soundPath = Resolve-NotifySoundPath

  try {
    `$payload = `$serializedPayload | ConvertFrom-Json -ErrorAction Stop
    `$eventType = Get-PayloadEventType -Payload `$payload
    `$matchedReason = Resolve-NotifyMatch -EventType `$eventType -SerializedPayload `$serializedPayload
    `$workspaceRoot = Resolve-NotifyWorkspaceRoot -Payload `$payload
  } catch {
    `$eventType = 'invalid-json'
    `$matchedReason = 'parse-error'
    Write-NotifyDiagnostic -EventType `$eventType -MatchedReason `$matchedReason -SoundAttempted:`$false -ResolvedSoundPath `$soundPath -PayloadExcerpt (Get-PayloadExcerpt -SerializedPayload `$serializedPayload) -WorkspaceRoot `$workspaceRoot -Delegated:`$false
    exit 0
  }

  if ([string]::IsNullOrWhiteSpace([string]`$matchedReason)) {
    Write-NotifyDiagnostic -EventType `$eventType -MatchedReason 'ignored' -SoundAttempted:`$false -ResolvedSoundPath `$soundPath -PayloadExcerpt (Get-PayloadExcerpt -SerializedPayload `$serializedPayload) -WorkspaceRoot `$workspaceRoot -Delegated:`$false
    exit 0
  }

  if ([string]::Equals(`$eventType, 'agent-turn-complete', [System.StringComparison]::OrdinalIgnoreCase) -and -not [string]::IsNullOrWhiteSpace([string]`$workspaceRoot)) {
    `$workspaceNotify = Join-Path `$workspaceRoot '.Rayman\scripts\codex\codex_notify.ps1'
    if (Test-Path -LiteralPath `$workspaceNotify -PathType Leaf) {
      try {
        & `$workspaceNotify -WorkspaceRoot `$workspaceRoot ignored `$serializedPayload | Out-Null
        `$soundAttempted = `$true
        `$delegated = `$true
      } catch {
      }
    }
  }

  if (-not `$delegated) {
    `$soundAttempted = Invoke-NotifySound -ResolvedSoundPath `$soundPath
  }

  Write-NotifyDiagnostic -EventType `$eventType -MatchedReason `$matchedReason -SoundAttempted:`$soundAttempted -ResolvedSoundPath `$soundPath -PayloadExcerpt (Get-PayloadExcerpt -SerializedPayload `$serializedPayload) -WorkspaceRoot `$workspaceRoot -Delegated:`$delegated
} catch {
}

exit 0
"@
}

function Sync-RaymanWorkspaceRegisterCodexNotify {
  $notifyScriptPath = Get-RaymanWorkspaceRegisterCodexNotifyScriptPath
  $configPath = Get-RaymanWorkspaceRegisterCodexConfigPath
  $notifyRoot = Split-Path -Parent $notifyScriptPath
  Ensure-RaymanWorkspaceRegisterDirectory -Path $notifyRoot
  Write-RaymanWorkspaceRegisterUtf8NoBom -Path $notifyScriptPath -Content (Get-RaymanWorkspaceRegisterCodexNotifyScriptContent)
  $notifyBlockResult = Set-RaymanWorkspaceRegisterManagedBlock -ConfigPath $configPath -ManagedBlock (Render-RaymanWorkspaceRegisterManagedNotifyBlock) -BlockName 'notify'

  return [pscustomobject]@{
    notify_script_path = $notifyScriptPath
    config_path = $configPath
    config_changed = [bool]$notifyBlockResult.changed
  }
}

function Set-RaymanWorkspaceRegisterLauncherPath {
  param([string]$LauncherDir)

  $result = [ordered]@{
    path_registered = $false
    broadcasted = $false
    warning = ''
  }

  try {
    $userPath = [string](Get-RaymanWorkspaceRegisterUserEnvironmentVariable -Name 'Path')
    $updatedUserPath = Add-RaymanWorkspaceRegisterPathEntry -PathList $userPath -EntryPath $LauncherDir
    if ($updatedUserPath -ne $userPath) {
      Set-RaymanWorkspaceRegisterUserEnvironmentVariable -Name 'Path' -Value $updatedUserPath
    }

    $processPath = [string](Get-RaymanWorkspaceRegisterProcessEnvironmentVariable -Name 'Path')
    $updatedProcessPath = Add-RaymanWorkspaceRegisterPathEntry -PathList $processPath -EntryPath $LauncherDir
    if ($updatedProcessPath -ne $processPath) {
      Set-RaymanWorkspaceRegisterProcessEnvironmentVariable -Name 'Path' -Value $updatedProcessPath
    }

    $result.path_registered = $true

    try {
      $result.broadcasted = [bool](Invoke-RaymanWorkspaceRegisterEnvironmentBroadcast)
    } catch {
      $result.warning = ("workspace-register updated PATH but failed to broadcast the environment change: {0}" -f $_.Exception.Message)
    }
  } catch {
    $result.warning = ("workspace-register wrote the launcher but failed to update PATH: {0}" -f $_.Exception.Message)
  }

  return [pscustomobject]$result
}

function Get-RaymanWorkspaceRegisterLauncherPs1Content {
  return @"
param(
  [Parameter(ValueFromRemainingArguments = `$true)][string[]]`$CliArgs
)

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'

function Resolve-LauncherPath([string]`$Path) {
  if ([string]::IsNullOrWhiteSpace([string]`$Path)) { return '' }
  try {
    return [System.IO.Path]::GetFullPath([string]`$Path)
  } catch {
    return [string]`$Path
  }
}

function Resolve-LauncherPowerShellHost {
  foreach (`$candidate in @('powershell.exe', 'powershell', 'pwsh.exe', 'pwsh')) {
    `$cmd = Get-Command `$candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if (`$null -ne `$cmd -and -not [string]::IsNullOrWhiteSpace([string]`$cmd.Source)) {
      return [string]`$cmd.Source
    }
  }

  if (-not [string]::IsNullOrWhiteSpace([string]`$PSHOME)) {
    foreach (`$leaf in @('powershell.exe', 'pwsh.exe')) {
      `$path = Join-Path `$PSHOME `$leaf
      if (Test-Path -LiteralPath `$path -PathType Leaf) {
        return [string]`$path
      }
    }
  }

  throw 'rayman-here could not resolve a PowerShell host.'
}

function Get-RaymanStateValue([object]`$State, [string]`$Name) {
  if (`$null -eq `$State -or `$null -eq `$State.PSObject.Properties[`$Name]) {
    return ''
  }
  return [string]`$State.`$Name
}

function Read-LauncherState([string]`$Path) {
  if (-not (Test-Path -LiteralPath `$Path -PathType Leaf)) {
    throw ('Rayman source registration not found: {0}. Please run `.\.Rayman\rayman.ps1 workspace-register` in RaymanAgent first.' -f `$Path)
  }

  try {
    return (Get-Content -LiteralPath `$Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    throw ('Rayman source registration is unreadable: {0}. Please run `.\.Rayman\rayman.ps1 workspace-register` again.' -f `$Path)
  }
}

`$targetPath = ''
`$autoOnOpen = `$false
`$json = `$false
`$forwardArgs = New-Object System.Collections.Generic.List[string]
for (`$i = 0; `$i -lt `$CliArgs.Count; `$i++) {
  `$token = [string]`$CliArgs[`$i]
  switch -Regex (`$token) {
    '^--?(target)$' {
      if (`$i + 1 -ge `$CliArgs.Count) {
        throw 'rayman-here requires a value after --target.'
      }
      `$targetPath = Resolve-LauncherPath -Path ([string]`$CliArgs[++`$i])
      continue
    }
    '^--?target=(.+)$' {
      `$targetPath = Resolve-LauncherPath -Path ([string]`$Matches[1])
      continue
    }
    '^--?(auto-on-open|autoonopen)$' {
      `$autoOnOpen = `$true
      continue
    }
    '^--?(json)$' {
      `$json = `$true
      continue
    }
    default {
      `$forwardArgs.Add(`$token) | Out-Null
      continue
    }
  }
}

if ([string]::IsNullOrWhiteSpace([string]`$targetPath)) {
  `$targetPath = Resolve-LauncherPath -Path ((Get-Location).Path)
}

`$launcherRoot = Split-Path -Parent `$PSScriptRoot
`$statePath = Resolve-LauncherPath -Path (Join-Path `$launcherRoot 'state\workspace_source.json')
`$state = Read-LauncherState -Path `$statePath
`$sourceWorkspacePath = Resolve-LauncherPath -Path (Get-RaymanStateValue -State `$state -Name 'source_workspace_path')
if ([string]::IsNullOrWhiteSpace([string]`$sourceWorkspacePath) -or -not (Test-Path -LiteralPath `$sourceWorkspacePath -PathType Container)) {
  throw ('Registered Rayman source workspace is unavailable: {0}. Please run `.\.Rayman\rayman.ps1 workspace-register` again.' -f [string]`$state.source_workspace_path)
}

`$helperScript = Join-Path `$sourceWorkspacePath '.Rayman\scripts\workspace\registered_workspace_bootstrap.ps1'
if (-not (Test-Path -LiteralPath `$helperScript -PathType Leaf)) {
  throw ('Registered Rayman source workspace is incomplete: missing {0}. Please run `.\.Rayman\rayman.ps1 workspace-register` again.' -f `$helperScript)
}

`$psHost = Resolve-LauncherPowerShellHost
`$argumentList = @(
  '-NoProfile',
  '-ExecutionPolicy',
  'Bypass',
  '-File',
  `$helperScript,
  '-StatePath',
  `$statePath,
  '-TargetPath',
  `$targetPath
)
if (`$autoOnOpen) {
  `$argumentList += '-AutoOnOpen'
}
if (`$json) {
  `$argumentList += '-Json'
}
if (`$forwardArgs.Count -gt 0) {
  `$argumentList += '-CliArgs'
  `$argumentList += @(`$forwardArgs.ToArray())
}

& `$psHost @argumentList
exit `$LASTEXITCODE
"@
}

function Get-RaymanWorkspaceRegisterDesktopBootstrapPs1Content {
  return @"
param(
  [Parameter(ValueFromRemainingArguments = `$true)][string[]]`$CliArgs
)

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'

function Resolve-LauncherPath([string]`$Path) {
  if ([string]::IsNullOrWhiteSpace([string]`$Path)) { return '' }
  try {
    return [System.IO.Path]::GetFullPath([string]`$Path)
  } catch {
    return [string]`$Path
  }
}

function Resolve-LauncherPowerShellHost {
  foreach (`$candidate in @('powershell.exe', 'powershell', 'pwsh.exe', 'pwsh')) {
    `$cmd = Get-Command `$candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if (`$null -ne `$cmd -and -not [string]::IsNullOrWhiteSpace([string]`$cmd.Source)) {
      return [string]`$cmd.Source
    }
  }
  throw 'rayman-codex-desktop-bootstrap could not resolve a PowerShell host.'
}

function Read-LauncherState([string]`$Path) {
  if (-not (Test-Path -LiteralPath `$Path -PathType Leaf)) {
    throw ('Rayman source registration not found: {0}. Please run `.\.Rayman\rayman.ps1 workspace-register` in RaymanAgent first.' -f `$Path)
  }

  try {
    return (Get-Content -LiteralPath `$Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    throw ('Rayman source registration is unreadable: {0}. Please run `.\.Rayman\rayman.ps1 workspace-register` again.' -f `$Path)
  }
}

`$launcherRoot = Split-Path -Parent `$PSScriptRoot
`$statePath = Resolve-LauncherPath -Path (Join-Path `$launcherRoot 'state\workspace_source.json')
`$state = Read-LauncherState -Path `$statePath
`$sourceWorkspacePath = Resolve-LauncherPath -Path ([string]`$state.source_workspace_path)
if ([string]::IsNullOrWhiteSpace([string]`$sourceWorkspacePath) -or -not (Test-Path -LiteralPath `$sourceWorkspacePath -PathType Container)) {
  throw ('Registered Rayman source workspace is unavailable: {0}. Please run `.\.Rayman\rayman.ps1 workspace-register` again.' -f [string]`$state.source_workspace_path)
}

`$helperScript = Join-Path `$sourceWorkspacePath '.Rayman\scripts\watch\codex_desktop_bootstrap.ps1'
if (-not (Test-Path -LiteralPath `$helperScript -PathType Leaf)) {
  throw ('Registered Rayman source workspace is incomplete: missing {0}. Please run `.\.Rayman\rayman.ps1 workspace-register` again.' -f `$helperScript)
}

`$psHost = Resolve-LauncherPowerShellHost
`$argumentList = @(
  '-NoProfile',
  '-ExecutionPolicy',
  'Bypass',
  '-File',
  `$helperScript,
  '-StatePath',
  `$statePath
)
if (`$CliArgs.Count -gt 0) {
  `$argumentList += @(`$CliArgs)
}

& `$psHost @argumentList
exit `$LASTEXITCODE
"@
}

function Get-RaymanWorkspaceRegisterLauncherCmdContent {
  return @"
@echo off
setlocal
set "RAYMAN_PWSH="
where powershell.exe >nul 2>nul && set "RAYMAN_PWSH=powershell.exe"
if not defined RAYMAN_PWSH where pwsh.exe >nul 2>nul && set "RAYMAN_PWSH=pwsh.exe"
if not defined RAYMAN_PWSH (
  echo rayman-here could not resolve a PowerShell host. 1>&2
  exit /b 1
)
"%RAYMAN_PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0rayman-here.ps1" %*
exit /b %ERRORLEVEL%
"@
}

function Get-RaymanWorkspaceRegisterDesktopBootstrapCmdContent {
  return @"
@echo off
setlocal
set "RAYMAN_PWSH="
where powershell.exe >nul 2>nul && set "RAYMAN_PWSH=powershell.exe"
if not defined RAYMAN_PWSH where pwsh.exe >nul 2>nul && set "RAYMAN_PWSH=pwsh.exe"
if not defined RAYMAN_PWSH (
  echo rayman-codex-desktop-bootstrap could not resolve a PowerShell host. 1>&2
  exit /b 1
)
"%RAYMAN_PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0rayman-codex-desktop-bootstrap.ps1" %*
exit /b %ERRORLEVEL%
"@
}

function Get-RaymanWorkspaceRegisterDesktopBootstrapStartupVbsContent {
  param([string]$LauncherPs1Path)

  return @"
Set shell = CreateObject("WScript.Shell")
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """" & Replace("$LauncherPs1Path", """", """""") & """"", 0, False
"@
}

function Get-RaymanWorkspaceRegisterLauncherShimCmdContent {
  param([string]$LauncherPs1Path)

  return @"
@echo off
setlocal
set "RAYMAN_PWSH="
where powershell.exe >nul 2>nul && set "RAYMAN_PWSH=powershell.exe"
if not defined RAYMAN_PWSH where pwsh.exe >nul 2>nul && set "RAYMAN_PWSH=pwsh.exe"
if not defined RAYMAN_PWSH (
  echo rayman-here could not resolve a PowerShell host. 1>&2
  exit /b 1
)
"%RAYMAN_PWSH%" -NoProfile -ExecutionPolicy Bypass -File "$LauncherPs1Path" %*
exit /b %ERRORLEVEL%
"@
}

function Write-RaymanWorkspaceRegisterLaunchers {
  $ps1Path = Get-RaymanWorkspaceRegisterLauncherPs1Path
  $cmdPath = Get-RaymanWorkspaceRegisterLauncherCmdPath

  Write-RaymanWorkspaceRegisterUtf8NoBom -Path $ps1Path -Content (Get-RaymanWorkspaceRegisterLauncherPs1Content)
  Write-RaymanWorkspaceRegisterUtf8NoBom -Path $cmdPath -Content (Get-RaymanWorkspaceRegisterLauncherCmdContent)

  return [pscustomobject]@{
    ps1_path = $ps1Path
    cmd_path = $cmdPath
    shim_cmd_path = ''
  }
}

function Write-RaymanWorkspaceRegisterDesktopBootstrapLaunchers {
  $ps1Path = Get-RaymanWorkspaceRegisterDesktopBootstrapPs1Path
  $cmdPath = Get-RaymanWorkspaceRegisterDesktopBootstrapCmdPath
  $startupVbsPath = Get-RaymanWorkspaceRegisterDesktopBootstrapStartupVbsPath
  $legacyStartupCmdPath = Get-RaymanWorkspaceRegisterDesktopBootstrapLegacyStartupCmdPath

  Write-RaymanWorkspaceRegisterUtf8NoBom -Path $ps1Path -Content (Get-RaymanWorkspaceRegisterDesktopBootstrapPs1Content)
  Write-RaymanWorkspaceRegisterUtf8NoBom -Path $cmdPath -Content (Get-RaymanWorkspaceRegisterDesktopBootstrapCmdContent)
  Write-RaymanWorkspaceRegisterUtf8NoBom -Path $startupVbsPath -Content (Get-RaymanWorkspaceRegisterDesktopBootstrapStartupVbsContent -LauncherPs1Path $ps1Path)
  if (Test-Path -LiteralPath $legacyStartupCmdPath -PathType Leaf) {
    Remove-Item -LiteralPath $legacyStartupCmdPath -Force -ErrorAction SilentlyContinue
  }

  return [pscustomobject]@{
    ps1_path = $ps1Path
    cmd_path = $cmdPath
    startup_path = $startupVbsPath
    startup_vbs_path = $startupVbsPath
    legacy_startup_cmd_path = $legacyStartupCmdPath
  }
}

function Get-RaymanWorkspaceRegisterBootstrapTask {
  param(
    [string]$LauncherPs1Path,
    [string]$PowerShellPath
  )

  $command = if ([string]::IsNullOrWhiteSpace([string]$PowerShellPath)) { 'powershell.exe' } else { [string]$PowerShellPath }

  return [ordered]@{
    label = 'Rayman: Bootstrap Current Workspace'
    detail = '从已注册的 RaymanAgent source workspace 拉取 .Rayman 并自动完成 setup/self-check。'
    type = 'process'
    command = $command
    args = @(
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      $LauncherPs1Path
    )
    options = [ordered]@{
      cwd = '${workspaceFolder}'
    }
    problemMatcher = @()
    presentation = [ordered]@{
      reveal = 'always'
      panel = 'shared'
      clear = $false
    }
  }
}

function Get-RaymanWorkspaceRegisterAutoUpgradeTask {
  param(
    [string]$LauncherPs1Path,
    [string]$PowerShellPath
  )

  $command = if ([string]::IsNullOrWhiteSpace([string]$PowerShellPath)) { 'powershell.exe' } else { [string]$PowerShellPath }

  return [ordered]@{
    label = 'Rayman: Auto Upgrade Installed Workspace'
    detail = '工作区打开时自动检查已安装的 Rayman 是否需要升级到已登记快照。'
    type = 'process'
    command = $command
    args = @(
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      $LauncherPs1Path,
      '--auto-on-open'
    )
    options = [ordered]@{
      cwd = '${workspaceFolder}'
    }
    problemMatcher = @()
    hide = $true
    runOptions = [ordered]@{
      runOn = 'folderOpen'
    }
    presentation = [ordered]@{
      reveal = 'never'
      panel = 'shared'
      clear = $false
    }
  }
}

function Update-RaymanWorkspaceRegisterVsCodeTasks {
  param([string]$LauncherPs1Path)

  $tasksPath = Get-RaymanWorkspaceRegisterVsCodeTasksPath
  $doc = Read-RaymanWorkspaceRegisterJsonDoc -Path $tasksPath
  if ([bool]$doc.ParseFailed) {
    throw ("workspace-register failed to update VS Code user tasks because the existing file is not valid JSONC: {0}" -f $tasksPath)
  }

  $tasksObj = $doc.Obj
  if ($null -eq $tasksObj) {
    $tasksObj = [ordered]@{
      version = '2.0.0'
      tasks = @()
    }
  }

  Set-RaymanWorkspaceRegisterJsonProperty -Obj $tasksObj -Name 'version' -Value '2.0.0'
  $existingTasks = @(Get-RaymanWorkspaceRegisterJsonProperty -Obj $tasksObj -Name 'tasks')
  $filteredTasks = New-Object System.Collections.Generic.List[object]
  foreach ($task in $existingTasks) {
    if ($null -eq $task) { continue }
    $label = [string](Get-RaymanWorkspaceRegisterJsonProperty -Obj $task -Name 'label')
    if ($label -eq 'Rayman: Bootstrap Current Workspace' -or $label -eq 'Rayman: Auto Upgrade Installed Workspace') {
      continue
    }
    $filteredTasks.Add($task) | Out-Null
  }
  $filteredTasks.Add((Get-RaymanWorkspaceRegisterBootstrapTask -LauncherPs1Path $LauncherPs1Path -PowerShellPath (Resolve-RaymanPowerShellHost))) | Out-Null
  $filteredTasks.Add((Get-RaymanWorkspaceRegisterAutoUpgradeTask -LauncherPs1Path $LauncherPs1Path -PowerShellPath (Resolve-RaymanPowerShellHost))) | Out-Null
  Set-RaymanWorkspaceRegisterJsonProperty -Obj $tasksObj -Name 'tasks' -Value @($filteredTasks.ToArray())

  Write-RaymanWorkspaceRegisterJsonFile -Path $tasksPath -Value $tasksObj
  return $tasksPath
}

function Write-RaymanWorkspaceRegisterLauncherShim {
  param([string]$LauncherPs1Path)

  $shimPath = Get-RaymanWorkspaceRegisterLauncherShimCmdPath
  Write-RaymanWorkspaceRegisterUtf8NoBom -Path $shimPath -Content (Get-RaymanWorkspaceRegisterLauncherShimCmdContent -LauncherPs1Path $LauncherPs1Path)
  return $shimPath
}

function Invoke-RaymanWorkspaceRegister {
  param(
    [string]$WorkspaceRoot,
    [switch]$NoVsCode,
    [switch]$NoPath
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $timestamp = (Get-Date).ToString('o')
  $result = [ordered]@{
    schema = 'rayman.workspace_register.result.v1'
    generated_at = $timestamp
    updated_at = $timestamp
    source_workspace_path = $resolvedRoot
    rayman_version = (Get-RaymanWorkspaceRegisterVersion -WorkspaceRoot $resolvedRoot)
    published_version = ''
    published_fingerprint = ''
    published_at = ''
    state_path = ''
    launcher_path = ''
    launcher_paths = $null
    desktop_bootstrap_paths = $null
    desktop_bootstrap_registered = $false
    desktop_notify_script_path = ''
    desktop_notify_config_path = ''
    desktop_notify_registered = $false
    vscode_task_path = ''
    vscode_registered = $false
    path_registered = $false
    status = 'failed'
    success = $false
    error = ''
    warning = ''
  }

  try {
    if (-not (Test-RaymanWindowsPlatform)) {
      throw 'workspace-register requires Windows.'
    }

    if (-not (Test-RaymanWorkspaceRegisterSourceWorkspace -WorkspaceRoot $resolvedRoot)) {
      throw 'workspace-register must be run from the RaymanAgent source workspace.'
    }

    $result.published_version = [string]$result.rayman_version
    $result.published_fingerprint = Get-RaymanDistributableFingerprint -WorkspaceRoot $resolvedRoot
    $result.published_at = (Get-Date).ToString('o')
    $statePayload = [pscustomobject]@{
      schema = 'rayman.workspace_source.state.v1'
      source_workspace_path = $resolvedRoot
      rayman_version = $result.rayman_version
      published_version = $result.published_version
      published_fingerprint = $result.published_fingerprint
      published_at = $result.published_at
      registered_at = (Get-Date).ToString('o')
    }
    $statePath = Get-RaymanWorkspaceRegisterSourceStatePath
    Write-RaymanWorkspaceRegisterJsonFile -Path $statePath -Value $statePayload
    $result.state_path = $statePath

    $launcherInfo = Write-RaymanWorkspaceRegisterLaunchers
    $desktopBootstrapInfo = Write-RaymanWorkspaceRegisterDesktopBootstrapLaunchers
    $desktopNotifyInfo = Sync-RaymanWorkspaceRegisterCodexNotify
    try {
      $launcherInfo.shim_cmd_path = [string](Write-RaymanWorkspaceRegisterLauncherShim -LauncherPs1Path ([string]$launcherInfo.ps1_path))
    } catch {
      $result.warning = if ([string]::IsNullOrWhiteSpace([string]$result.warning)) {
        "workspace-register wrote the launcher but failed to install the immediate shell shim: $($_.Exception.Message)"
      } else {
        "{0}; workspace-register failed to install the immediate shell shim: {1}" -f [string]$result.warning, $_.Exception.Message
      }
    }
    $result.launcher_paths = $launcherInfo
    $result.launcher_path = if (-not [string]::IsNullOrWhiteSpace([string]$launcherInfo.shim_cmd_path)) {
      [string]$launcherInfo.shim_cmd_path
    } else {
      [string]$launcherInfo.cmd_path
    }
    $result.desktop_bootstrap_paths = $desktopBootstrapInfo
    $result.desktop_bootstrap_registered = $true
    $result.desktop_notify_script_path = [string]$desktopNotifyInfo.notify_script_path
    $result.desktop_notify_config_path = [string]$desktopNotifyInfo.config_path
    $result.desktop_notify_registered = $true

    if (-not $NoPath) {
      $pathUpdate = Set-RaymanWorkspaceRegisterLauncherPath -LauncherDir (Get-RaymanWorkspaceRegisterBinRoot)
      $result.path_registered = [bool]$pathUpdate.path_registered
      if (-not [string]::IsNullOrWhiteSpace([string]$pathUpdate.warning)) {
        $result.warning = if ([string]::IsNullOrWhiteSpace([string]$result.warning)) {
          [string]$pathUpdate.warning
        } else {
          "{0}; {1}" -f [string]$result.warning, [string]$pathUpdate.warning
        }
      }
    }

    if (-not $NoVsCode) {
      try {
        $result.vscode_task_path = Update-RaymanWorkspaceRegisterVsCodeTasks -LauncherPs1Path ([string]$launcherInfo.ps1_path)
        $result.vscode_registered = $true
      } catch {
        $warning = [string]$_.Exception.Message
        $result.warning = if ([string]::IsNullOrWhiteSpace([string]$result.warning)) {
          $warning
        } else {
          "{0}; {1}" -f [string]$result.warning, $warning
        }
      }
    }

    $result.status = if ([string]::IsNullOrWhiteSpace([string]$result.warning)) { 'registered' } else { 'registered_with_warnings' }
    $result.success = $true
    return [pscustomobject]$result
  } catch {
    $result.status = 'failed'
    $result.error = [string]$_.Exception.Message
    return [pscustomobject]$result
  } finally {
    try {
      Write-RaymanWorkspaceRegisterJsonFile -Path (Get-RaymanWorkspaceRegisterLastPath) -Value ([pscustomobject]$result)
    } catch {}
  }
}

if (-not $NoMain) {
  $WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  if ($null -eq $CliArgs) { $CliArgs = @() } else { $CliArgs = @($CliArgs) }

  $noVsCode = $false
  $noPath = $false
  $json = $false

  foreach ($token in $CliArgs) {
    switch -Regex ([string]$token) {
      '^--?(no-vscode|novscode)$' { $noVsCode = $true; continue }
      '^--?(no-path|nopath)$' { $noPath = $true; continue }
      '^--?(json)$' { $json = $true; continue }
      default { continue }
    }
  }

  $result = $null
  switch ($Action.ToLowerInvariant()) {
    'register' {
      $result = Invoke-RaymanWorkspaceRegister -WorkspaceRoot $WorkspaceRoot -NoVsCode:$noVsCode -NoPath:$noPath
      break
    }
  }

  if (-not [bool]$result.success) {
    $global:LASTEXITCODE = 1
    if (-not $json -and -not [string]::IsNullOrWhiteSpace([string]$result.error)) {
      Write-Error ([string]$result.error)
    }
  }

  if ($json) {
    $result | ConvertTo-Json -Depth 16
  } elseif ([bool]$result.success) {
    Write-Host ("已注册 Rayman source workspace：{0}" -f [string]$result.source_workspace_path)
    if (-not [string]::IsNullOrWhiteSpace([string]$result.published_version)) {
      Write-Host ("已发布快照：{0}" -f [string]$result.published_version)
    }
    Write-Host ("终端入口：rayman-here")
    Write-Host ("launcher：{0}" -f [string]$result.launcher_path)
    if ($result.PSObject.Properties['launcher_paths'] -and $null -ne $result.launcher_paths -and -not [string]::IsNullOrWhiteSpace([string]$result.launcher_paths.ps1_path)) {
      Write-Host ("PowerShell launcher：{0}" -f [string]$result.launcher_paths.ps1_path)
    }
    if ($result.PSObject.Properties['desktop_bootstrap_paths'] -and $null -ne $result.desktop_bootstrap_paths -and -not [string]::IsNullOrWhiteSpace([string]$result.desktop_bootstrap_paths.startup_path)) {
      Write-Host ("Codex Desktop bootstrap：{0}" -f [string]$result.desktop_bootstrap_paths.startup_path)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$result.desktop_notify_config_path)) {
      Write-Host ("Codex Desktop notify：{0}" -f [string]$result.desktop_notify_config_path)
    }
    if (-not $noVsCode -and [bool]$result.vscode_registered) {
      Write-Host 'VS Code 用户任务：Rayman: Bootstrap Current Workspace'
      Write-Host 'VS Code 自动升级：Rayman: Auto Upgrade Installed Workspace'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$result.warning)) {
      Write-Warning ([string]$result.warning)
    }
  }

  exit $(if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 })
}
