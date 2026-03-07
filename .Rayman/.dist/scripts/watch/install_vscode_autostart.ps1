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

  $taskLabel = 'Rayman: Auto Start Watchers'
  $desiredTask = [ordered]@{
    label = $taskLabel
    type = 'shell'
    command = 'powershell'
    linux = [ordered]@{
      command = 'pwsh'
    }
    args = @(
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      '${workspaceFolder}\\.Rayman\\scripts\\watch\\start_background_watchers.ps1',
      '-WorkspaceRoot',
      '${workspaceFolder}',
      '-VscodeOwnerPid',
      '${env:VSCODE_PID}',
      '-FromVscodeAuto'
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

  $taskList = @($currentTasks)
  $newList = New-Object 'System.Collections.Generic.List[object]'
  $replaced = $false
  foreach ($t in $taskList) {
    $label = [string](Get-JsonProperty -Obj $t -Name 'label')
    if (-not [string]::IsNullOrWhiteSpace($label) -and $label -eq $taskLabel) {
      $newList.Add($desiredTask) | Out-Null
      $replaced = $true
    } else {
      $newList.Add($t) | Out-Null
    }
  }
  if (-not $replaced) {
    $newList.Add($desiredTask) | Out-Null
  }
  Set-JsonProperty -Obj $tasksObj -Name 'tasks' -Value ($newList.ToArray())

  $tasksJson = ConvertTo-JsonString -Obj $tasksObj
  Write-Utf8NoBom -Path $tasksPath -Content $tasksJson
  Write-Info ("[vscode-auto] installed: {0}" -f $tasksPath)
}
