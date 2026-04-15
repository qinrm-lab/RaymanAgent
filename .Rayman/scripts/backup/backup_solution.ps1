param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path $WorkspaceRoot '.Rayman\config.json'
}

$script:DefaultExcludeDirNames = @(
  'bin',
  'obj',
  'Debug',
  'Release',
  'out',
  'target',
  'TestResults',
  'artifacts',
  '.vs'
)

function Get-BackupConfigProp([object]$Object, [string]$Name, $DefaultValue) {
  if ($null -eq $Object) { return $DefaultValue }
  $prop = $Object.PSObject.Properties[$Name]
  if ($null -eq $prop) { return $DefaultValue }
  if ($null -eq $prop.Value) { return $DefaultValue }
  return $prop.Value
}

function ConvertTo-BackupBool([object]$Value, [bool]$Default = $false) {
  if ($null -eq $Value) { return $Default }
  if ($Value -is [bool]) { return [bool]$Value }
  $raw = [string]$Value
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

function Get-ExcludeNames([object]$RawValue) {
  if ($null -eq $RawValue) { return @($script:DefaultExcludeDirNames) }

  $items = @()
  if ($RawValue -is [System.Collections.IEnumerable] -and -not ($RawValue -is [string])) {
    foreach ($v in $RawValue) { $items += [string]$v }
  } else {
    $items += [string]$RawValue
  }

  $result = New-Object 'System.Collections.Generic.List[string]'
  foreach ($item in $items) {
    $trimmed = $item.Trim()
    if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
      $result.Add($trimmed) | Out-Null
    }
  }

  if ($result.Count -eq 0) {
    return @($script:DefaultExcludeDirNames)
  }
  return @($result)
}

function Get-BackupConfig([string]$Path) {
  $rawConfig = $null
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    try {
      $rawConfig = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
      throw ("读取配置失败：{0}" -f $_.Exception.Message)
    }
  }

  $backupRaw = $null
  if ($rawConfig -and $rawConfig.PSObject.Properties['backup']) {
    $backupRaw = $rawConfig.backup
  }

  $root = [string](Get-BackupConfigProp -Object $backupRaw -Name 'root' -DefaultValue 'F:\backup')
  $mode = [string](Get-BackupConfigProp -Object $backupRaw -Name 'mode' -DefaultValue 'timestamp')
  $onFailure = [string](Get-BackupConfigProp -Object $backupRaw -Name 'onFailure' -DefaultValue 'stop')
  $enabled = ConvertTo-BackupBool -Value (Get-BackupConfigProp -Object $backupRaw -Name 'enabled' -DefaultValue $true) -Default $true
  $includeGit = ConvertTo-BackupBool -Value (Get-BackupConfigProp -Object $backupRaw -Name 'includeGit' -DefaultValue $true) -Default $true
  $excludeNames = Get-ExcludeNames -RawValue (Get-BackupConfigProp -Object $backupRaw -Name 'excludeDirNames' -DefaultValue $null)

  return [pscustomobject]@{
    enabled         = $enabled
    root            = if ([string]::IsNullOrWhiteSpace($root)) { 'F:\backup' } else { $root.Trim() }
    mode            = if ([string]::IsNullOrWhiteSpace($mode)) { 'timestamp' } else { $mode.Trim().ToLowerInvariant() }
    onFailure       = if ([string]::IsNullOrWhiteSpace($onFailure)) { 'stop' } else { $onFailure.Trim().ToLowerInvariant() }
    includeGit      = $includeGit
    excludeDirNames = @($excludeNames)
  }
}

function Get-SolutionName([string]$Root) {
  $solutionNameFile = Join-Path $Root '.SolutionName'
  if (Test-Path -LiteralPath $solutionNameFile -PathType Leaf) {
    $sol = Get-Content -LiteralPath $solutionNameFile -ErrorAction SilentlyContinue |
      Where-Object { $_ -match '\S' } |
      Select-Object -First 1
    if ($sol) {
      $trimmed = $sol.Trim()
      if ($trimmed) { return $trimmed }
    }
  }

  $rootReqs = @(Get-ChildItem -LiteralPath $Root -File -Force -Filter '.*.requirements.md' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne '.temp.requirements.md' } |
    Sort-Object Name)
  if ($rootReqs.Count -eq 1) {
    $name = $rootReqs[0].Name
    if ($name.StartsWith('.')) { $name = $name.Substring(1) }
    if ($name.EndsWith('.requirements.md')) {
      $name = $name.Substring(0, $name.Length - '.requirements.md'.Length)
    }
    if ($name) { return $name }
  }

  $skipDotDirs = @('.','.git','.github','.Rayman','.vscode','.vs','.temp','.tmp')
  $dotDirs = @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name.StartsWith('.') } |
    Sort-Object Name)
  foreach ($dir in $dotDirs) {
    if ($skipDotDirs -contains $dir.Name) { continue }
    # PowerShell 5.1 compatibility: -Depth is not available on Get-ChildItem here.
    $hit = Get-ChildItem -LiteralPath $dir.FullName -File -Force -Recurse -Filter '.*.requirements.md' -ErrorAction SilentlyContinue |
      Select-Object -First 1
    if ($hit) {
      return $dir.Name.TrimStart('.')
    }
  }

  $slnxs = @(Get-ChildItem -LiteralPath $Root -File -Force -Filter '*.slnx' -ErrorAction SilentlyContinue | Sort-Object Name)
  if ($slnxs.Count -eq 1) {
    return [System.IO.Path]::GetFileNameWithoutExtension($slnxs[0].Name)
  }

  $slns = @(Get-ChildItem -LiteralPath $Root -File -Force -Filter '*.sln' -ErrorAction SilentlyContinue | Sort-Object Name)
  if ($slns.Count -eq 1) {
    return [System.IO.Path]::GetFileNameWithoutExtension($slns[0].Name)
  }

  throw "无法推断 SolutionName：请确保存在 .SolutionName 或唯一的 *.slnx/*.sln 或根目录存在 .<SolutionName>.requirements.md 或 .<SolutionName>/ 目录"
}

function Get-ExcludedDirectoryPaths(
  [string]$Root,
  [string[]]$ExcludeNames,
  [bool]$IncludeGit
) {
  $excludeSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($name in $ExcludeNames) {
    if (-not [string]::IsNullOrWhiteSpace($name)) {
      $excludeSet.Add($name.Trim()) | Out-Null
    }
  }
  if (-not $IncludeGit) {
    $excludeSet.Add('.git') | Out-Null
  }

  if ($excludeSet.Count -eq 0) { return @() }

  $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  $dirs = Get-ChildItem -LiteralPath $Root -Directory -Recurse -Force -Attributes !ReparsePoint -ErrorAction SilentlyContinue
  foreach ($dir in $dirs) {
    if ($excludeSet.Contains($dir.Name)) {
      $paths.Add($dir.FullName) | Out-Null
    }
  }

  return @($paths | Sort-Object)
}

function Assert-BackupTargetOutsideSource([string]$SourceRoot, [string]$TargetRoot) {
  $src = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
  $dst = [System.IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
  if ($dst.Equals($src, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "备份目标不能与源码根目录相同：$dst"
  }
  if ($dst.StartsWith($src + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "备份目标不能位于源码目录内：$dst"
  }
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$cfg = Get-BackupConfig -Path $ConfigPath

if (-not $cfg.enabled) {
  Write-Host '[backup] disabled by config (backup.enabled=false).'
  exit 0
}

if ($cfg.mode -ne 'timestamp') {
  throw ("不支持的 backup.mode：{0}（当前仅支持 timestamp）" -f $cfg.mode)
}

$solutionName = Get-SolutionName -Root $WorkspaceRoot
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$solutionBackupRoot = Join-Path $cfg.root $solutionName
$target = Join-Path $solutionBackupRoot $timestamp

Assert-BackupTargetOutsideSource -SourceRoot $WorkspaceRoot -TargetRoot $target

$excludePaths = Get-ExcludedDirectoryPaths -Root $WorkspaceRoot -ExcludeNames $cfg.excludeDirNames -IncludeGit:$cfg.includeGit

New-Item -ItemType Directory -Force -Path $solutionBackupRoot | Out-Null
New-Item -ItemType Directory -Force -Path $target | Out-Null

Write-Host ("[backup] source: {0}" -f $WorkspaceRoot)
Write-Host ("[backup] target: {0}" -f $target)
Write-Host ("[backup] include_git: {0}" -f $cfg.includeGit)
Write-Host ("[backup] exclude_count: {0}" -f $excludePaths.Count)

$args = @(
  $WorkspaceRoot,
  $target,
  '/E',
  '/COPY:DAT',
  '/DCOPY:DAT',
  '/R:2',
  '/W:1',
  '/XJ',
  '/NFL',
  '/NDL',
  '/NP'
)
if ($excludePaths.Count -gt 0) {
  $args += '/XD'
  $args += $excludePaths
}

& robocopy.exe @args
$rc = $LASTEXITCODE
Write-Host ("[backup] robocopy_exit: {0}" -f $rc)

if ($rc -ge 8) {
  throw ("robocopy 失败（exit={0}）" -f $rc)
}

Write-Host '[backup] completed'
