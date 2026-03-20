param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot "..\..\common.ps1"
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
  throw "common.ps1 not found: $commonPath"
}
. $commonPath

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$vscodeDir = Join-Path $WorkspaceRoot '.vscode'
$settingsPath = Join-Path $vscodeDir 'settings.json'
$tasksPath = Join-Path $vscodeDir 'tasks.json'

if (-not (Test-Path -LiteralPath $vscodeDir)) {
  New-Item -ItemType Directory -Force -Path $vscodeDir | Out-Null
}

function Remove-JsonComments([string]$Text) {
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

function Remove-JsonTrailingCommas([string]$Text) {
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

function Read-JsonDoc([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return [pscustomobject]@{
      Exists      = $false
      ParseFailed = $false
      Obj         = $null
    }
  }

  try {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
      return [pscustomobject]@{
        Exists      = $true
        ParseFailed = $false
        Obj         = $null
      }
    }
    $clean = Remove-JsonTrailingCommas -Text (Remove-JsonComments -Text $raw)
    $obj = $clean | ConvertFrom-Json -ErrorAction Stop
    return [pscustomobject]@{
      Exists      = $true
      ParseFailed = $false
      Obj         = $obj
    }
  } catch {
    Write-Warn ("[vscode-auto] parse json failed: {0}; keep original file unchanged." -f $Path)
    return [pscustomobject]@{
      Exists      = $true
      ParseFailed = $true
      Obj         = $null
    }
  }
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Find-DictionaryKey([System.Collections.IDictionary]$Dict, [string]$Name) {
  if ($null -eq $Dict) { return $null }
  foreach ($k in $Dict.Keys) {
    if ([string]$k -eq $Name) { return $k }
  }
  return $null
}

function Get-JsonProperty([object]$Obj, [string]$Name) {
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [System.Collections.IDictionary]) {
    $dictKey = Find-DictionaryKey -Dict $Obj -Name $Name
    if ($null -ne $dictKey) { return $Obj[$dictKey] }
    return $null
  }
  $prop = $Obj.PSObject.Properties[$Name]
  if ($prop) { return $prop.Value }
  return $null
}

function Set-JsonProperty([object]$Obj, [string]$Name, $Value) {
  if ($Obj -is [System.Collections.IDictionary]) {
    $dictKey = Find-DictionaryKey -Dict $Obj -Name $Name
    if ($null -ne $dictKey) { $Obj[$dictKey] = $Value } else { $Obj[$Name] = $Value }
    return
  }
  $prop = $Obj.PSObject.Properties[$Name]
  if ($prop) {
    $prop.Value = $Value
    return
  }
  Add-Member -InputObject $Obj -MemberType NoteProperty -Name $Name -Value $Value
}

function ConvertTo-JsonString([object]$Obj) {
  return ($Obj | ConvertTo-Json -Depth 64)
}

function Remove-RunOnFolderOpen([object]$Task) {
  if ($null -eq $Task) { return $Task }

  $runOptions = Get-JsonProperty -Obj $Task -Name 'runOptions'
  if ($null -eq $runOptions) { return $Task }

  $runOn = [string](Get-JsonProperty -Obj $runOptions -Name 'runOn')
  if ($runOn -ne 'folderOpen') { return $Task }

  $clone = [ordered]@{}
  if ($Task -is [System.Collections.IDictionary]) {
    foreach ($key in $Task.Keys) {
      if ([string]$key -eq 'runOptions') { continue }
      $clone[[string]$key] = $Task[$key]
    }
    return $clone
  }

  foreach ($prop in $Task.PSObject.Properties) {
    if ([string]$prop.Name -eq 'runOptions') { continue }
    $clone[[string]$prop.Name] = $prop.Value
  }
  return $clone
}

$settingsDoc = Read-JsonDoc -Path $settingsPath
if ($settingsDoc.ParseFailed) {
  Write-Warn ("[vscode-auto] skipped settings update due parse error: {0}" -f $settingsPath)
} else {
  $settings = $settingsDoc.Obj
  if ($null -eq $settings) {
    $settings = [ordered]@{}
  }
  Set-JsonProperty -Obj $settings -Name 'task.allowAutomaticTasks' -Value 'on'
  $settingsJson = ConvertTo-JsonString -Obj $settings
  Write-Utf8NoBom -Path $settingsPath -Content $settingsJson
  Write-Info ("[vscode-auto] installed: {0}" -f $settingsPath)
}

$tasksDoc = Read-JsonDoc -Path $tasksPath
if ($tasksDoc.ParseFailed) {
  Write-Warn ("[vscode-auto] skipped tasks update due parse error: {0}" -f $tasksPath)
} else {
  $tasksObj = $tasksDoc.Obj
  if ($null -eq $tasksObj) {
    $tasksObj = [ordered]@{
    version = '2.0.0'
    tasks = @()
  }
  }
  Set-JsonProperty -Obj $tasksObj -Name 'version' -Value '2.0.0'
  $currentTasks = Get-JsonProperty -Obj $tasksObj -Name 'tasks'
  if ($null -eq $currentTasks) {
    $currentTasks = @()
  }

  $taskLabel = 'Rayman: Folder Open Bootstrap'
  $capabilityTaskLabel = 'Rayman: Ensure Agent Capabilities'
  $winAppTaskLabel = 'Rayman: Ensure WinApp Automation'
  $stopTaskLabel = 'Rayman: Stop Watchers'
  $readyTaskLabel = 'Rayman: Common - Ready for Agent Work'
  $desiredTask = [ordered]@{
    label = $taskLabel
    type = 'process'
    command = 'powershell.exe'
    detail = '文件夹打开时统一执行 Rayman 后台启动与轻量检查。'
    linux = [ordered]@{
      command = 'pwsh'
    }
    args = @(
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      '${workspaceFolder}\\.Rayman\\scripts\\watch\\vscode_folder_open_bootstrap.ps1',
      '-WorkspaceRoot',
      '${workspaceFolder}',
      '-VscodeOwnerPid',
      '${env:VSCODE_PID}'
    )
    runOptions = [ordered]@{
      runOn = 'folderOpen'
    }
    presentation = [ordered]@{
      reveal = 'never'
      panel = 'shared'
      clear = $false
    }
    problemMatcher = @()
  }
  $desiredCapabilityTask = [ordered]@{
    label = $capabilityTaskLabel
    type = 'shell'
    command = 'powershell.exe'
    detail = '同步 Codex Agent capabilities 到 .codex/config.toml，并补齐 OpenAI Docs / Playwright / WinApp MCP。'
    linux = [ordered]@{
      command = 'pwsh'
    }
    args = @(
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      '${workspaceFolder}\\.Rayman\\scripts\\agents\\ensure_agent_capabilities.ps1',
      '-Action',
      'sync',
      '-WorkspaceRoot',
      '${workspaceFolder}'
    )
    presentation = [ordered]@{
      reveal = 'always'
      panel = 'shared'
      clear = $false
    }
    problemMatcher = @()
  }
  $desiredWinAppTask = [ordered]@{
    label = $winAppTaskLabel
    type = 'shell'
    command = 'powershell.exe'
    detail = '确保 Windows 桌面 UI Automation 能力可用于 WinForms / MAUI(Windows) 自动化。'
    linux = [ordered]@{
      command = 'pwsh'
    }
    args = @(
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      '${workspaceFolder}\\.Rayman\\scripts\\windows\\ensure_winapp.ps1',
      '-WorkspaceRoot',
      '${workspaceFolder}'
    )
    presentation = [ordered]@{
      reveal = 'always'
      panel = 'shared'
      clear = $false
    }
    problemMatcher = @()
  }
  $desiredStopTask = [ordered]@{
    label = $stopTaskLabel
    type = 'shell'
    command = 'powershell.exe'
    detail = '停止 Rayman watcher、auto-save 与 MCP 后台服务。'
    linux = [ordered]@{
      command = 'pwsh'
    }
    args = @(
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      '${workspaceFolder}\\.Rayman\\scripts\\watch\\stop_background_watchers.ps1',
      '-IncludeResidualCleanup',
      '-OwnerPid',
      '${env:VSCODE_PID}'
    )
    presentation = [ordered]@{
      reveal = 'always'
      panel = 'shared'
      clear = $false
    }
    problemMatcher = @()
  }

  $taskList = @($currentTasks)
  $newList = New-Object 'System.Collections.Generic.List[object]'
  $replaced = $false
  $capabilityTaskReplaced = $false
  $winAppTaskReplaced = $false
  $stopTaskReplaced = $false
  $manualOnlyLabels = @(
    'Rayman: Auto Start Watchers'
    'Rayman: Check Pending Task'
    'Rayman: Daily Health Check'
    'Rayman: Check Win Deps'
    'Rayman: Check WSL Deps'
  )
  foreach ($t in $taskList) {
    $label = [string](Get-JsonProperty -Obj $t -Name 'label')
    if ($manualOnlyLabels -contains $label) {
      $t = Remove-RunOnFolderOpen -Task $t
    }
    if (-not [string]::IsNullOrWhiteSpace($label) -and $label -eq $readyTaskLabel) {
      $dependsOn = @(Get-JsonProperty -Obj $t -Name 'dependsOn')
      if ($dependsOn.Count -eq 0) {
        $dependsOn = @('Rayman: Ensure Win Deps', $capabilityTaskLabel, 'Rayman: Ensure Playwright', 'Rayman: Update Context')
      } elseif ($dependsOn -notcontains $capabilityTaskLabel) {
        $updatedDependsOn = New-Object 'System.Collections.Generic.List[object]'
        $updatedDependsOn.Add($dependsOn[0]) | Out-Null
        $updatedDependsOn.Add($capabilityTaskLabel) | Out-Null
        for ($dependsIdx = 1; $dependsIdx -lt $dependsOn.Count; $dependsIdx++) {
          $updatedDependsOn.Add($dependsOn[$dependsIdx]) | Out-Null
        }
        $dependsOn = $updatedDependsOn.ToArray()
      }
      Set-JsonProperty -Obj $t -Name 'dependsOn' -Value $dependsOn
      Set-JsonProperty -Obj $t -Name 'detail' -Value '常用组合：确保 Windows 依赖、Agent capabilities、Playwright 能力和上下文都处于可工作状态。'
    }
    if (-not [string]::IsNullOrWhiteSpace($label) -and $label -eq $taskLabel) {
      $newList.Add($desiredTask) | Out-Null
      $replaced = $true
    } elseif (-not [string]::IsNullOrWhiteSpace($label) -and $label -eq $capabilityTaskLabel) {
      $newList.Add($desiredCapabilityTask) | Out-Null
      $capabilityTaskReplaced = $true
    } elseif (-not [string]::IsNullOrWhiteSpace($label) -and $label -eq $winAppTaskLabel) {
      $newList.Add($desiredWinAppTask) | Out-Null
      $winAppTaskReplaced = $true
    } elseif (-not [string]::IsNullOrWhiteSpace($label) -and $label -eq $stopTaskLabel) {
      $newList.Add($desiredStopTask) | Out-Null
      $stopTaskReplaced = $true
    } else {
      $newList.Add($t) | Out-Null
    }
  }
  if (-not $replaced) {
    $newList.Add($desiredTask) | Out-Null
  }
  if (-not $capabilityTaskReplaced) {
    $newList.Add($desiredCapabilityTask) | Out-Null
  }
  if (-not $winAppTaskReplaced) {
    $newList.Add($desiredWinAppTask) | Out-Null
  }
  if (-not $stopTaskReplaced) {
    $newList.Add($desiredStopTask) | Out-Null
  }
  Set-JsonProperty -Obj $tasksObj -Name 'tasks' -Value ($newList.ToArray())

  $tasksJson = ConvertTo-JsonString -Obj $tasksObj
  Write-Utf8NoBom -Path $tasksPath -Content $tasksJson
  Write-Info ("[vscode-auto] installed: {0}" -f $tasksPath)
}
