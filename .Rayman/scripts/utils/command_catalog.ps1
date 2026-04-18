Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RaymanCommandCatalogPath {
  param([string]$WorkspaceRoot)

  return (Join-Path $WorkspaceRoot '.Rayman\config\command_catalog.tsv')
}

function Get-RaymanCommandGroupTitle {
  param([string]$Group)

  $normalized = if ([string]::IsNullOrWhiteSpace($Group)) { '' } else { $Group.Trim().ToLowerInvariant() }
  switch ($normalized) {
    'core' { return 'Core' }
    'watchers' { return 'Watchers' }
    'automation' { return 'Automation' }
    'project' { return 'Project Gates' }
    'release' { return 'Release' }
    'diagnostics' { return 'Diagnostics' }
    'state' { return 'State' }
    default { throw ("unknown command group: {0}" -f $Group) }
  }
}

function Get-RaymanPlatformTag {
  param([string]$Platform)

  $normalized = if ([string]::IsNullOrWhiteSpace($Platform)) { '' } else { $Platform.Trim().ToLowerInvariant() }
  switch ($normalized) {
    'all' { return 'all' }
    'pwsh-only' { return 'pwsh-only' }
    'windows-only' { return 'windows-only' }
    default { throw ("unknown platform tag: {0}" -f $Platform) }
  }
}

function Test-RaymanCatalogWindowsHost {
  try {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
  } catch {
    return $false
  }
}

function Get-RaymanCatalogVersionToken {
  param([string]$WorkspaceRoot)

  $fallback = 'v164'
  if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    return $fallback
  }

  $versionPath = Join-Path $WorkspaceRoot '.Rayman\VERSION'
  if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
    return $fallback
  }

  try {
    $raw = (Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8).Trim()
    if ($raw -match '^(?i)v\d+$') {
      return $raw.ToLowerInvariant()
    }
  } catch {}

  return $fallback
}

function Get-RaymanCommandInvocationText {
  param([object]$Command)

  if ($null -eq $Command) { return '' }
  if ([string]$Command.platform -eq 'all') {
    return ("rayman {0}" -f [string]$Command.name)
  }
  return ("rayman.ps1 {0}" -f [string]$Command.name)
}

function Get-RaymanCommandCatalogEntriesForSurface {
  param(
    [string]$WorkspaceRoot,
    [ValidateSet('bash', 'pwsh')][string]$Surface
  )

  $commands = @(Import-RaymanCommandCatalog -WorkspaceRoot $WorkspaceRoot)
  if ($Surface -eq 'bash') {
    return @($commands | Where-Object { [string]$_.platform -eq 'all' })
  }
  $isWindowsHost = Test-RaymanCatalogWindowsHost
  return @($commands | Where-Object {
      $platform = [string]$_.platform
      if ($platform -eq 'windows-only') {
        return $isWindowsHost
      }
      return $true
    })
}

function Import-RaymanCommandCatalog {
  param([string]$WorkspaceRoot)

  $catalogPath = Get-RaymanCommandCatalogPath -WorkspaceRoot $WorkspaceRoot
  if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
    throw ("command catalog missing: {0}" -f $catalogPath)
  }

  $items = New-Object System.Collections.Generic.List[object]
  $names = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  $lineNumber = 0
  foreach ($rawLine in @(Get-Content -LiteralPath $catalogPath -Encoding UTF8)) {
    $lineNumber++
    $line = [string]$rawLine
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line.TrimStart().StartsWith('#')) { continue }

    $parts = @($line -split "`t")
    if ($parts.Count -ne 5) {
      throw ("invalid command catalog line {0}: expected 5 tab-separated columns" -f $lineNumber)
    }

    $name = [string]$parts[0]
    $platform = Get-RaymanPlatformTag -Platform ([string]$parts[1])
    $group = [string]$parts[2]
    $summary = [string]$parts[3]
    $recommendedRaw = [string]$parts[4]
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($summary)) {
      throw ("invalid command catalog line {0}: name/summary must be non-empty" -f $lineNumber)
    }
    if ($recommendedRaw.Trim() -ne '0' -and $recommendedRaw.Trim() -ne '1') {
      throw ("invalid command catalog line {0}: recommended must be 0 or 1" -f $lineNumber)
    }
    if (-not $names.Add($name.Trim())) {
      throw ("duplicate command catalog entry: {0}" -f $name.Trim())
    }

    $items.Add([pscustomobject]@{
        order = $items.Count
        name = $name.Trim()
        platform = $platform
        group = $group.Trim().ToLowerInvariant()
        group_title = Get-RaymanCommandGroupTitle -Group $group
        summary = $summary.Trim()
        recommended = ($recommendedRaw.Trim() -eq '1')
      }) | Out-Null
  }

  return $items.ToArray()
}

function Get-RaymanCommandCatalogByName {
  param([string]$WorkspaceRoot)

  $map = @{}
  foreach ($item in @(Import-RaymanCommandCatalog -WorkspaceRoot $WorkspaceRoot)) {
    $map[[string]$item.name] = $item
  }
  return $map
}

function Get-RaymanRecommendedCommandEntries {
  param([string]$WorkspaceRoot)

  return @(Import-RaymanCommandCatalog -WorkspaceRoot $WorkspaceRoot | Where-Object { [bool]$_.recommended })
}

function Format-RaymanHelpText {
  param(
    [string]$WorkspaceRoot,
    [ValidateSet('bash', 'pwsh')][string]$Surface
  )

  $commands = @(Get-RaymanCommandCatalogEntriesForSurface -WorkspaceRoot $WorkspaceRoot -Surface $Surface)
  $versionToken = Get-RaymanCatalogVersionToken -WorkspaceRoot $WorkspaceRoot
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add(("Rayman CLI ({0})" -f $versionToken))
  $lines.Add('')
  $lines.Add('Usage:')
  if ($Surface -eq 'bash') {
    $lines.Add('  ./.Rayman/rayman <command>')
  } else {
    $lines.Add('  .\.Rayman\rayman.cmd <command>')
    $lines.Add('  .\.Rayman\rayman.cmd menu')
  }
  $lines.Add('')
  $lines.Add('Platform tags:')
  $lines.Add('  [all]          Publicly supported from both bash `rayman` and PowerShell `rayman.ps1`.')
  $lines.Add('  [pwsh-only]    Use `rayman.ps1 <command>`.')
  $lines.Add('  [windows-only] Use `rayman.ps1 <command>` on a Windows host.')
  $lines.Add('')
  $lines.Add('Commands:')

  foreach ($command in $commands) {
    $lines.Add(("  {0,-18} [{1}] {2}" -f [string]$command.name, [string]$command.platform, [string]$command.summary))
  }

  $lines.Add('')
  $lines.Add('Notes:')
  if ($Surface -eq 'bash') {
    $lines.Add('  - This bash entry publicly supports only commands tagged `[all]`.')
    $lines.Add('  - For `[pwsh-only]` or `[windows-only]` commands, use `rayman.ps1 <command>`.')
  } else {
    $lines.Add('  - Commands tagged `[all]` are also available from bash `rayman`.')
    $lines.Add('  - `menu` is the PowerShell interactive entry point.')
  }

  return ($lines -join "`n")
}

function Get-RaymanCommandsText {
  param([string]$WorkspaceRoot)

  $commands = @(Import-RaymanCommandCatalog -WorkspaceRoot $WorkspaceRoot)
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('=======================================================')
  $lines.Add('Rayman CLI Command Catalog')
  $lines.Add('=======================================================')
  $lines.Add('')
  $lines.Add('This file is generated from `.Rayman/config/command_catalog.tsv`.')
  $lines.Add('')
  $lines.Add('Platform tags:')
  $lines.Add('- `[all]` available from both `rayman` and `rayman.ps1`.')
  $lines.Add('- `[pwsh-only]` use `rayman.ps1 <command>`.')
  $lines.Add('- `[windows-only]` use `rayman.ps1 <command>` on a Windows host.')
  $lines.Add('')

  $currentGroup = ''
  foreach ($command in $commands) {
    if ([string]$command.group -ne $currentGroup) {
      if (-not [string]::IsNullOrWhiteSpace($currentGroup)) {
        $lines.Add('')
      }
      $currentGroup = [string]$command.group
      $lines.Add(('[{0}]' -f [string]$command.group_title))
    }
    $lines.Add(('- `[ {0} ]` `{1}`: {2}' -f [string]$command.platform, (Get-RaymanCommandInvocationText -Command $command), [string]$command.summary))
  }

  $lines.Add('')
  $lines.Add('`?` or `？` should render this generated catalog.')
  $lines.Add('')
  return (($lines -join "`n").TrimEnd() + "`n")
}

function Get-RaymanReadmeCommandSection {
  param([string]$WorkspaceRoot)

  $commands = @(Import-RaymanCommandCatalog -WorkspaceRoot $WorkspaceRoot)
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('<!-- RAYMAN:COMMANDS:BEGIN -->')
  $lines.Add('### 命令总览（generated）')
  $lines.Add('')
  $lines.Add('- 平台标签：`[all]` 同时支持 `rayman` / `rayman.ps1`；`[pwsh-only]` 与 `[windows-only]` 统一使用 `rayman.ps1`。')
  $lines.Add('')

  $currentGroup = ''
  foreach ($command in $commands) {
    if ([string]$command.group -ne $currentGroup) {
      $currentGroup = [string]$command.group
      $lines.Add(('#### {0}' -f [string]$command.group_title))
    }
    $lines.Add(('- `[ {0} ]` `{1}`：{2}' -f [string]$command.platform, (Get-RaymanCommandInvocationText -Command $command), [string]$command.summary))
  }

  $lines.Add('<!-- RAYMAN:COMMANDS:END -->')
  return (($lines -join "`n").TrimEnd() + "`n")
}

function Get-RaymanContextRecommendedEntries {
  param([string]$WorkspaceRoot)

  $entries = New-Object System.Collections.Generic.List[string]
  foreach ($command in @(Get-RaymanRecommendedCommandEntries -WorkspaceRoot $WorkspaceRoot)) {
    $entries.Add(('- `[ {0} ]` `{1}`：{2}' -f [string]$command.platform, (Get-RaymanCommandInvocationText -Command $command), [string]$command.summary)) | Out-Null
  }
  return @($entries)
}

function Get-RaymanContextRecommendedBlock {
  param([string]$WorkspaceRoot)

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('<!-- RAYMAN:RECOMMENDED:BEGIN -->')
  foreach ($line in @(Get-RaymanContextRecommendedEntries -WorkspaceRoot $WorkspaceRoot)) {
    $lines.Add([string]$line)
  }
  $lines.Add('<!-- RAYMAN:RECOMMENDED:END -->')
  return @($lines)
}
