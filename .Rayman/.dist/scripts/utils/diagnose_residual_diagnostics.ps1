param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [string]$ReportPath = '',
  [switch]$Json,
  [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info([string]$Message) { Write-Host ("ℹ️  [diagnostics-residual] {0}" -f $Message) -ForegroundColor Cyan }
function Warn([string]$Message) { Write-Host ("⚠️  [diagnostics-residual] {0}" -f $Message) -ForegroundColor Yellow }
function FailText([string]$Message) { Write-Host ("❌ [diagnostics-residual] {0}" -f $Message) -ForegroundColor Red }

function Add-Check {
  param(
    [System.Collections.Generic.List[object]]$Checks,
    [string]$Name,
    [ValidateSet('PASS','WARN','FAIL')][string]$Status,
    [string]$Detail,
    [string]$Action = ''
  )

  $Checks.Add([pscustomobject]@{
      name = $Name
      status = $Status
      detail = $Detail
      action = $Action
    }) | Out-Null
}

function Remove-JsonComments([string]$Text) {
  if ([string]::IsNullOrEmpty($Text)) {
    return $Text
  }

  $builder = New-Object System.Text.StringBuilder
  $inString = $false
  $isEscaped = $false
  $inLineComment = $false
  $inBlockComment = $false

  for ($index = 0; $index -lt $Text.Length; $index++) {
    $char = $Text[$index]
    $next = if (($index + 1) -lt $Text.Length) { $Text[$index + 1] } else { [char]0 }

    if ($inLineComment) {
      if ($char -eq "`r" -or $char -eq "`n") {
        $inLineComment = $false
        [void]$builder.Append($char)
      }
      continue
    }

    if ($inBlockComment) {
      if ($char -eq '*' -and $next -eq '/') {
        $inBlockComment = $false
        $index++
      }
      continue
    }

    if ($inString) {
      [void]$builder.Append($char)
      if ($isEscaped) {
        $isEscaped = $false
      } elseif ($char -eq '\\') {
        $isEscaped = $true
      } elseif ($char -eq '"') {
        $inString = $false
      }
      continue
    }

    if ($char -eq '"') {
      $inString = $true
      [void]$builder.Append($char)
      continue
    }

    if ($char -eq '/' -and $next -eq '/') {
      $inLineComment = $true
      $index++
      continue
    }

    if ($char -eq '/' -and $next -eq '*') {
      $inBlockComment = $true
      $index++
      continue
    }

    [void]$builder.Append($char)
  }

  return $builder.ToString()
}

function Read-JsoncFile([string]$Path) {
  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  try {
    return ($raw | ConvertFrom-Json)
  } catch {
    $stripped = Remove-JsonComments -Text $raw
    return ($stripped | ConvertFrom-Json)
  }
}

function ConvertTo-SettingMap([object]$Value) {
  $map = @{}
  if ($null -eq $Value) { return $map }
  if ($Value -is [System.Collections.IDictionary]) {
    foreach ($key in $Value.Keys) {
      $map[[string]$key] = $Value[$key]
    }
    return $map
  }
  if ($Value -is [System.Management.Automation.PSCustomObject]) {
    foreach ($prop in $Value.PSObject.Properties) {
      $map[[string]$prop.Name] = $prop.Value
    }
  }
  return $map
}

function Get-ObjectPropertyValue {
  param(
    [object]$InputObject,
    [string]$PropertyName
  )

  if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace($PropertyName)) {
    return $null
  }

  foreach ($prop in $InputObject.PSObject.Properties) {
    if ([string]::Equals([string]$prop.Name, $PropertyName, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $prop.Value
    }
  }

  return $null
}

function Test-SettingKeysEnabled {
  param(
    [object]$SettingsObject,
    [string]$SettingName,
    [string[]]$RequiredKeys
  )

  $settingValue = Get-ObjectPropertyValue -InputObject $SettingsObject -PropertyName $SettingName
  $map = ConvertTo-SettingMap -Value $settingValue
  $missing = New-Object System.Collections.Generic.List[string]
  foreach ($key in @($RequiredKeys)) {
    if (-not $map.ContainsKey($key) -or -not [bool]$map[$key]) {
      $missing.Add($key) | Out-Null
    }
  }
  return @($missing)
}

function Test-PowerShellScriptParses {
  param([string]$Path)

  try {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $null = [scriptblock]::Create($raw)
    return [pscustomobject]@{
      Passed = $true
      Detail = 'parse ok'
    }
  } catch {
    return [pscustomobject]@{
      Passed = $false
      Detail = $_.Exception.Message
    }
  }
}

function Resolve-ChildPowerShellHost {
  foreach ($name in @('pwsh.exe', 'pwsh', 'powershell.exe', 'powershell')) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
      return [string]$cmd.Source
    }
  }
  return $null
}

function Invoke-AssertDistSync {
  param(
    [string]$WorkspaceRootPath,
    [string]$AssertScriptPath
  )

  $psHost = Resolve-ChildPowerShellHost
  if ([string]::IsNullOrWhiteSpace($psHost)) {
    return [pscustomobject]@{
      ExitCode = 1
      Output = @('PowerShell host not found (pwsh/powershell)')
    }
  }

  $output = @(& $psHost -NoProfile -ExecutionPolicy Bypass -File $AssertScriptPath -WorkspaceRoot $WorkspaceRootPath 2>&1)
  $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }
  return [pscustomobject]@{
    ExitCode = $exitCode
    Output = @($output | ForEach-Object { [string]$_ })
  }
}

function Get-RelativePathOrSelf([string]$BasePath, [string]$FullPath) {
  try {
    $baseUri = [Uri](([System.IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'))
    $fullUri = [Uri]([System.IO.Path]::GetFullPath($FullPath))
    return [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($fullUri).ToString()).Replace('/', '\')
  } catch {
    return $FullPath
  }
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$stateDir = Join-Path $WorkspaceRoot '.Rayman\state'
if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $ReportPath = Join-Path $stateDir 'diagnostics_residual_report.md'
}
$jsonReportPath = [System.IO.Path]::ChangeExtension([string]$ReportPath, '.json')

$checks = New-Object 'System.Collections.Generic.List[object]'
$issues = New-Object 'System.Collections.Generic.List[object]'

$criticalScripts = @(
  '.Rayman\rayman.ps1',
  '.Rayman\scripts\release\release_gate.ps1',
  '.Rayman\scripts\release\sync_dist_from_src.ps1',
  '.Rayman\scripts\release\assert_dist_sync.ps1',
  '.Rayman\scripts\release\copy_smoke.ps1'
)

foreach ($relPath in $criticalScripts) {
  $fullPath = Join-Path $WorkspaceRoot $relPath
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    Add-Check -Checks $checks -Name ("语法解析: {0}" -f $relPath) -Status FAIL -Detail 'missing' -Action '补齐脚本后重试'
    continue
  }

  $parseResult = Test-PowerShellScriptParses -Path $fullPath
  if ($parseResult.Passed) {
    Add-Check -Checks $checks -Name ("语法解析: {0}" -f $relPath) -Status PASS -Detail $parseResult.Detail
  } else {
    Add-Check -Checks $checks -Name ("语法解析: {0}" -f $relPath) -Status FAIL -Detail $parseResult.Detail -Action '当前文本已无法解析，请先修源码'
  }
}

$assertScriptPath = Join-Path $WorkspaceRoot '.Rayman\scripts\release\assert_dist_sync.ps1'
if (-not (Test-Path -LiteralPath $assertScriptPath -PathType Leaf)) {
  Add-Check -Checks $checks -Name 'Source/Dist 镜像一致性' -Status FAIL -Detail ('missing: {0}' -f $assertScriptPath) -Action '补齐 assert_dist_sync.ps1 后重试'
} else {
  $distSyncResult = Invoke-AssertDistSync -WorkspaceRootPath $WorkspaceRoot -AssertScriptPath $assertScriptPath
  if ($distSyncResult.ExitCode -eq 0) {
    Add-Check -Checks $checks -Name 'Source/Dist 镜像一致性' -Status PASS -Detail 'assert_dist_sync.ps1 => OK'
  } else {
    $distDetail = (@($distSyncResult.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' | ')
    if ([string]::IsNullOrWhiteSpace($distDetail)) {
      $distDetail = ('assert_dist_sync.ps1 exit={0}' -f $distSyncResult.ExitCode)
    }
    Add-Check -Checks $checks -Name 'Source/Dist 镜像一致性' -Status FAIL -Detail $distDetail -Action '执行 rayman dist-sync 或修复 source/.dist 漂移'
  }
}

$settingsPath = Join-Path $WorkspaceRoot '.vscode\settings.json'
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
  Add-Check -Checks $checks -Name 'VS Code 噪音排除设置' -Status WARN -Detail 'missing: .vscode/settings.json' -Action '运行 ./.Rayman/setup.ps1 重新生成 settings'
} else {
  try {
    $settingsObj = Read-JsoncFile -Path $settingsPath
    $missingSearch = Test-SettingKeysEnabled -SettingsObject $settingsObj -SettingName 'search.exclude' -RequiredKeys @('**/.Rayman/state', '**/.Rayman/runtime')
    $missingWatcher = Test-SettingKeysEnabled -SettingsObject $settingsObj -SettingName 'files.watcherExclude' -RequiredKeys @('**/.Rayman/state/**', '**/.Rayman/runtime/**')
    $missingFiles = Test-SettingKeysEnabled -SettingsObject $settingsObj -SettingName 'files.exclude' -RequiredKeys @('**/.Rayman/state', '**/.Rayman/runtime')
    $missingAll = @($missingSearch + $missingWatcher + $missingFiles | Select-Object -Unique)
    if ($missingAll.Count -eq 0) {
      Add-Check -Checks $checks -Name 'VS Code 噪音排除设置' -Status PASS -Detail 'state/runtime 的 search/files/watcher exclude 均已启用'
    } else {
      Add-Check -Checks $checks -Name 'VS Code 噪音排除设置' -Status WARN -Detail ("缺少排除项: {0}" -f ($missingAll -join ', ')) -Action '运行 ./.Rayman/setup.ps1 恢复默认降噪设置'
    }
  } catch {
    Add-Check -Checks $checks -Name 'VS Code 噪音排除设置' -Status WARN -Detail ("settings.json 解析失败: {0}" -f $_.Exception.Message) -Action '修复 .vscode/settings.json 或重跑 setup'
  }
}

$autoSavePatchPath = Join-Path $WorkspaceRoot '.Rayman\state\auto_save.patch'
$runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime'
$runtimeFileCount = 0
if (Test-Path -LiteralPath $runtimeDir -PathType Container) {
  try {
    $runtimeFileCount = @(Get-ChildItem -LiteralPath $runtimeDir -File -Recurse -Force -ErrorAction SilentlyContinue).Count
  } catch {
    $runtimeFileCount = 0
  }
}
$stateNoisePaths = New-Object 'System.Collections.Generic.List[string]'
if (Test-Path -LiteralPath $autoSavePatchPath -PathType Leaf) {
  $stateNoisePaths.Add((Get-RelativePathOrSelf -BasePath $WorkspaceRoot -FullPath $autoSavePatchPath)) | Out-Null
}
if ($runtimeFileCount -gt 0) {
  $stateNoisePaths.Add(('.Rayman\runtime (files={0})' -f $runtimeFileCount)) | Out-Null
}

if ($stateNoisePaths.Count -eq 0) {
  Add-Check -Checks $checks -Name '生成物/历史快照噪音源' -Status PASS -Detail '未发现典型 state/runtime 噪音源'
} else {
  Add-Check -Checks $checks -Name '生成物/历史快照噪音源' -Status PASS -Detail ("发现但可视为噪音源: {0}" -f ($stateNoisePaths -join ', ')) -Action '若 Problems 仍命中旧名字，优先按缓存/历史产物处理'
}

$failCount = @($checks | Where-Object { $_.status -eq 'FAIL' }).Count
$warnCount = @($checks | Where-Object { $_.status -eq 'WARN' }).Count
$status = if ($failCount -gt 0) { 'FAIL' } elseif ($warnCount -gt 0) { 'WARN' } else { 'OK' }

foreach ($check in $checks) {
  if ($check.status -ne 'PASS') {
    $issues.Add([pscustomobject]@{
        name = [string]$check.name
        status = [string]$check.status
        detail = [string]$check.detail
        action = [string]$check.action
      }) | Out-Null
  }
}

$parseAllPassed = (@($checks | Where-Object { $_.name -like '语法解析:*' -and $_.status -eq 'FAIL' }).Count -eq 0)
$distPassed = (@($checks | Where-Object { $_.name -eq 'Source/Dist 镜像一致性' -and $_.status -eq 'PASS' }).Count -gt 0)
$cacheHintPossible = ($parseAllPassed -and $distPassed)
$cacheHintMessage = ''
if ($cacheHintPossible) {
  if ($stateNoisePaths.Count -gt 0) {
    $cacheHintMessage = '当前关键源码可解析，且 source/.dist 一致。若 VS Code Problems 仍报旧名字，更像语言服务缓存或 state/runtime 历史产物回声；优先刷新语言服务，并忽略 .Rayman/state、.Rayman/runtime、auto_save.patch 的命中。'
  } else {
    $cacheHintMessage = '当前关键源码可解析，且 source/.dist 一致。若 Problems 仍与当前文本对不上，优先按语言服务缓存残影处理。'
  }
}

$reportLines = New-Object 'System.Collections.Generic.List[string]'
$reportLines.Add('# Rayman Diagnostics Residual Report') | Out-Null
$reportLines.Add('') | Out-Null
$reportLines.Add(('> generated_at: {0}' -f (Get-Date).ToString('o'))) | Out-Null
$reportLines.Add(('> workspace_root: `{0}`' -f $WorkspaceRoot)) | Out-Null
$reportLines.Add(('> status: **{0}**' -f $status)) | Out-Null
$reportLines.Add(('> cache_hint_possible: **{0}**' -f $cacheHintPossible)) | Out-Null
$reportLines.Add('') | Out-Null
$reportLines.Add('| 检查项 | 状态 | 详情 | 建议 |') | Out-Null
$reportLines.Add('|---|---|---|---|') | Out-Null
foreach ($check in $checks) {
  $detail = ([string]$check.detail).Replace('|', '\|')
  $action = ([string]$check.action).Replace('|', '\|')
  $reportLines.Add(("| {0} | {1} | {2} | {3} |" -f [string]$check.name, [string]$check.status, $detail, $action)) | Out-Null
}

if (-not [string]::IsNullOrWhiteSpace($cacheHintMessage)) {
  $reportLines.Add('') | Out-Null
  $reportLines.Add('## 缓存残影提示') | Out-Null
  $reportLines.Add('') | Out-Null
  $reportLines.Add(('- {0}' -f $cacheHintMessage)) | Out-Null
}

$reportLines | Set-Content -LiteralPath $ReportPath -Encoding UTF8

$checkArray = @($checks.ToArray())
$issueArray = @($issues.ToArray())
$noiseSamples = @($stateNoisePaths.ToArray())

$payload = [pscustomobject]@{
  schema = 'rayman.diagnostics_residual.v1'
  generated_at = (Get-Date).ToString('o')
  workspace_root = $WorkspaceRoot
  report_path = $ReportPath
  status = $status
  checks = $checkArray
  issues = $issueArray
  noise_sources = [pscustomobject]@{
    auto_save_patch_exists = (Test-Path -LiteralPath $autoSavePatchPath -PathType Leaf)
    runtime_file_count = $runtimeFileCount
    samples = $noiseSamples
  }
  cache_hint = [pscustomobject]@{
    possible = $cacheHintPossible
    message = $cacheHintMessage
  }
}

$jsonText = $payload | ConvertTo-Json -Depth 8
$jsonText | Set-Content -LiteralPath $jsonReportPath -Encoding UTF8

if ($Json -or $AsJson) {
  Write-Output $jsonText
} else {
  Info ("status={0}" -f $status)
  Info ("report={0}" -f $ReportPath)
  Info ("json={0}" -f $jsonReportPath)
  if ($cacheHintPossible -and -not [string]::IsNullOrWhiteSpace($cacheHintMessage)) {
    Warn $cacheHintMessage
  }
}

if ($status -eq 'FAIL') {
  FailText ("残留诊断发现真实问题，报告：{0}" -f $ReportPath)
  exit 2
}

if ($status -eq 'WARN') {
  Warn ("残留诊断完成（存在可恢复警告），报告：{0}" -f $ReportPath)
  exit 0
}

Info '残留诊断通过。'
exit 0