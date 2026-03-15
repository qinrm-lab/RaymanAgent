param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
  $WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
} catch {
  throw "WorkspaceRoot not found: $WorkspaceRoot"
}

$stateDir = Join-Path $WorkspaceRoot '.Rayman\state'
$stateFile = Join-Path $stateDir 'wsl_deps_ok.flag'
$scriptPath = Join-Path $PSScriptRoot 'ensure_wsl_deps.sh'

function Convert-WorkspaceToWslPath([string]$PathValue) {
  if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
  $normalized = $PathValue -replace '/', '\\'
  if ($normalized.Length -lt 3 -or $normalized[1] -ne ':') {
    return ($normalized -replace '\\', '/')
  }
  $drive = $normalized.Substring(0, 1).ToLowerInvariant()
  $rest = $normalized.Substring(2).TrimStart('\\') -replace '\\', '/'
  return "/mnt/$drive/$rest"
}

if (-not $Force -and (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
  $lastWrite = (Get-Item -LiteralPath $stateFile).LastWriteTime
  if (((Get-Date) - $lastWrite) -lt (New-TimeSpan -Hours 24)) {
    Write-Host '✅ WSL 依赖检查已在 24 小时内通过，跳过检查。(使用 -Force 强制检查)' -ForegroundColor Green
    exit 0
  }
}

if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
  throw "ensure_wsl_deps.sh not found: $scriptPath"
}

$wsl = Get-Command 'wsl.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $wsl -or [string]::IsNullOrWhiteSpace([string]$wsl.Source)) {
  Write-Host '❌ 未检测到 wsl.exe，无法在 WSL 中安装依赖。' -ForegroundColor Red
  exit 2
}

try {
  & "$PSScriptRoot\request_attention.ps1" -Message '将为 WSL 安装依赖；终端可能提示输入一次 sudo 密码。'
} catch {}

$wslWorkspaceRoot = Convert-WorkspaceToWslPath -PathValue $WorkspaceRoot
$wslScript = '.Rayman/scripts/utils/ensure_wsl_deps.sh'

Write-Host '🐧 将在 WSL(Ubuntu) 中安装/校验依赖（需要 sudo）...' -ForegroundColor Cyan
& $wsl.Source -e bash -lc "cd '$wslWorkspaceRoot' && bash '$wslScript'"
$exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }

if ($exitCode -ne 0) {
  Write-Host ("❌ WSL 依赖检查/安装失败，退出码：{0}" -f $exitCode) -ForegroundColor Red
  exit $exitCode
}

if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
}
Set-Content -LiteralPath $stateFile -Value (Get-Date).ToString('o') -Encoding UTF8
Write-Host '✅ WSL 依赖检查/安装完成，已记录状态。' -ForegroundColor Green

exit 0
