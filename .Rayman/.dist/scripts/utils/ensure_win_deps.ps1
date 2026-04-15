param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$Force,
  [switch]$Lightweight
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
  $WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
} catch {
  throw "WorkspaceRoot not found: $WorkspaceRoot"
}

$stateDir = Join-Path $WorkspaceRoot '.Rayman\state'
$stateFile = Join-Path $stateDir 'win_deps_ok.flag'

function Write-Title([string]$Text) {
  Write-Host ''
  Write-Host '=========================================' -ForegroundColor Cyan
  Write-Host $Text -ForegroundColor Cyan
  Write-Host '=========================================' -ForegroundColor Cyan
}

function Test-Tool([string]$Name) {
  return ($null -ne (Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1))
}

function Get-OptionalToolVersion([string]$Command, [string[]]$Args = @('--version')) {
  try {
    $output = & $Command @Args 2>$null | Select-Object -First 1
    return [string]$output
  } catch {
    return ''
  }
}

function Get-WindowsAppsPath {
  try {
    return (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
  } catch {
    return ''
  }
}

function Repair-WingetPathBestEffort {
  $windowsApps = Get-WindowsAppsPath
  if ([string]::IsNullOrWhiteSpace($windowsApps)) { return $false }

  try {
    if ($env:Path -notlike ('*' + $windowsApps + '*')) {
      $env:Path = $env:Path.TrimEnd(';') + ';' + $windowsApps
    }
  } catch {}

  try {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrWhiteSpace($userPath)) {
      [Environment]::SetEnvironmentVariable('Path', $windowsApps, 'User')
      return $true
    }
    if ($userPath -notlike ('*' + $windowsApps + '*')) {
      [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $windowsApps), 'User')
    }
    return $true
  } catch {
    return $false
  }
}

function Invoke-DotNetInstallHint {
  $autoInstall = [string][Environment]::GetEnvironmentVariable('RAYMAN_AUTO_INSTALL_DOTNET')
  if ($autoInstall.Trim() -ne '1') {
    Write-Host 'ℹ️ 如需自动尝试安装 .NET，可先设置环境变量 RAYMAN_AUTO_INSTALL_DOTNET=1 再重跑本脚本。' -ForegroundColor Cyan
    return
  }

  try {
    $root = Join-Path $env:LOCALAPPDATA 'Rayman\dotnet'
    $installDir = Split-Path -Parent $root
    $installScript = Join-Path $installDir 'dotnet-install.ps1'
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installScript -UseBasicParsing
    & powershell -NoProfile -ExecutionPolicy Bypass -File $installScript -Channel '10.0' -InstallDir $root -NoPath | Out-Host
    & powershell -NoProfile -ExecutionPolicy Bypass -File $installScript -Channel '10.0' -Runtime 'windowsdesktop' -OS 'win' -Architecture 'x64' -InstallDir $root -NoPath | Out-Host
    $env:DOTNET_ROOT = $root
    if ($env:Path -notlike ('*' + $root + '*')) {
      $env:Path = $root + ';' + $env:Path
    }
    try { [Environment]::SetEnvironmentVariable('DOTNET_ROOT', $root, 'User') } catch {}
    Write-Host '✅ 已尝试安装 .NET；若当前终端仍未生效，请重启终端或 Reload Window。' -ForegroundColor Green
  } catch {
    Write-Host ("❌ 自动安装 .NET 失败：{0}" -f $_.Exception.Message) -ForegroundColor Red
  }
}

function Write-LightweightStatus([string]$Name, [bool]$Exists, [string]$Note) {
  if ($Exists) {
    Write-Host ("✅ {0} 已存在" -f $Name) -ForegroundColor Green
    return
  }

  if ([string]::IsNullOrWhiteSpace($Note)) {
    Write-Host ("⚠️ {0} 未检测到" -f $Name) -ForegroundColor Yellow
  } else {
    Write-Host ("⚠️ {0} 未检测到（{1}）" -f $Name, $Note) -ForegroundColor Yellow
  }
}

if (-not $Force -and (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
  $lastWrite = (Get-Item -LiteralPath $stateFile).LastWriteTime
  if (((Get-Date) - $lastWrite) -lt (New-TimeSpan -Hours 24)) {
    Write-Host '✅ Windows 依赖检查已在 24 小时内通过，跳过检查。(使用 -Force 强制检查)' -ForegroundColor Green
    exit 0
  }
}

Write-Title '🪟 Rayman Windows 依赖检查'

if ($env:OS -ne 'Windows_NT') {
  Write-Host 'ℹ️ 当前不是 Windows 主机，跳过 Windows 依赖检查。' -ForegroundColor Cyan
  exit 0
}

$checks = @(
  @{ Name = 'git';     Required = $false; Note = '推荐：用于 stash / 提交 / 发布'; VersionArgs = @('--version') },
  @{ Name = 'wsl.exe'; Required = $false; Note = '推荐：用于 WSL 依赖安装与 smoke'; VersionArgs = @('--version') },
  @{ Name = 'winget';  Required = $false; Note = '可选：用于 Windows 侧自动安装'; VersionArgs = @('--version') },
  @{ Name = 'dotnet';  Required = $false; Note = '可选：.NET 项目构建 / 部署'; VersionArgs = @('--version') },
  @{ Name = 'node';    Required = $false; Note = '可选：Node 项目构建 / 部署'; VersionArgs = @('--version') },
  @{ Name = 'python';  Required = $false; Note = '可选：Python 工具 / 测试'; VersionArgs = @('--version') },
  @{ Name = 'uv';      Required = $false; Note = '可选：Python / MCP 运行管理'; VersionArgs = @('--version') }
)

if ($Lightweight) {
  Write-Host 'ℹ️ 轻量模式：仅检查命令是否存在，不读取版本，不触发安装建议。' -ForegroundColor Cyan
  foreach ($check in $checks) {
    $toolName = [string]$check.Name
    Write-LightweightStatus -Name $toolName -Exists:(Test-Tool -Name $toolName) -Note ([string]$check.Note)
  }

  if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
  }
  Set-Content -LiteralPath $stateFile -Value (Get-Date).ToString('o') -Encoding UTF8
  Write-Host '✅ Windows 依赖轻量检查完成。' -ForegroundColor Green
  exit 0
}

$missingRequired = New-Object System.Collections.Generic.List[string]
$missingOptional = New-Object System.Collections.Generic.List[string]

foreach ($check in $checks) {
  $toolName = [string]$check.Name
  $exists = Test-Tool -Name $toolName
  if ($exists) {
    $version = Get-OptionalToolVersion -Command $toolName -Args @($check.VersionArgs)
    if ([string]::IsNullOrWhiteSpace($version)) {
      Write-Host ("✅ {0} 已存在" -f $toolName) -ForegroundColor Green
    } else {
      Write-Host ("✅ {0} 已存在 · {1}" -f $toolName, $version.Trim()) -ForegroundColor Green
    }
    continue
  }

  if ($check.Required) {
    [void]$missingRequired.Add($toolName)
    Write-Host ("❌ {0} 未检测到（{1}）" -f $toolName, [string]$check.Note) -ForegroundColor Red
  } else {
    [void]$missingOptional.Add($toolName)
    Write-Host ("⚠️ {0} 未检测到（{1}）" -f $toolName, [string]$check.Note) -ForegroundColor Yellow
  }

  if ($toolName -eq 'winget') {
    $fixed = Repair-WingetPathBestEffort
    if ($fixed -and (Test-Tool -Name 'winget')) {
      Write-Host '✅ 已尝试修复 WindowsApps PATH，winget 在当前终端可用。' -ForegroundColor Green
    }
  }

  if ($toolName -eq 'dotnet') {
    Invoke-DotNetInstallHint
  }
}

if ($missingRequired.Count -gt 0) {
  Write-Host ("❌ 缺少必要依赖：{0}" -f ($missingRequired -join ', ')) -ForegroundColor Red
  try {
    & "$PSScriptRoot\request_attention.ps1" -Message ("Windows 依赖检查失败：缺少 {0}" -f ($missingRequired -join ', '))
  } catch {}
  exit 2
}

if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
}
Set-Content -LiteralPath $stateFile -Value (Get-Date).ToString('o') -Encoding UTF8

if ($missingOptional.Count -gt 0) {
  Write-Host ("⚠️ 可选依赖缺失：{0}" -f ($missingOptional -join ', ')) -ForegroundColor Yellow
}
Write-Host '✅ Windows 依赖检查完成，已记录状态。' -ForegroundColor Green
Write-Host 'ℹ️ 若提示音文件存在但你仍怀疑没声音，可运行：rayman.ps1 sound-check。' -ForegroundColor Cyan
Write-Host 'ℹ️ 若你主要在 WSL(/mnt/*) 开发，可运行：Rayman: Ensure WSL Deps。' -ForegroundColor Cyan

exit 0
