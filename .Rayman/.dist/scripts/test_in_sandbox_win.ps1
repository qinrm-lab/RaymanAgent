param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\.." | Select-Object -ExpandProperty Path),
  [string]$Command = "dotnet test"
)
$ErrorActionPreference = 'Stop'
$RaymanDir = Join-Path $WorkspaceRoot '.Rayman'
$Sandbox = Join-Path $RaymanDir 'run\sandbox\workspace'
$Log = Join-Path $RaymanDir 'run\sandbox\test.log'
$DepsScript = Join-Path $RaymanDir 'scripts\utils\ensure_project_test_deps.ps1'

function Get-EnvBoolCompat([string]$Name, [bool]$Default) {
  $raw = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
  return ($raw -ne '0' -and $raw -ne 'false' -and $raw -ne 'False')
}

New-Item -ItemType Directory -Force -Path $Sandbox | Out-Null
"[sandbox] WorkspaceRoot=$WorkspaceRoot" | Out-File -FilePath $Log -Encoding utf8
"[sandbox] Command=$Command" | Out-File -FilePath $Log -Append -Encoding utf8

if (Test-Path -LiteralPath $DepsScript -PathType Leaf) {
  $autoInstall = Get-EnvBoolCompat -Name 'RAYMAN_AUTO_INSTALL_TEST_DEPS' -Default $true
  $requireDeps = Get-EnvBoolCompat -Name 'RAYMAN_REQUIRE_TEST_DEPS' -Default $true
  "[sandbox] EnsureTestDeps autoInstall=$autoInstall require=$requireDeps" | Out-File -FilePath $Log -Append -Encoding utf8
  & $DepsScript -WorkspaceRoot $WorkspaceRoot -AutoInstall:$autoInstall -Require:$requireDeps 2>&1 | Tee-Object -FilePath $Log -Append | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw ("test dependencies not ready (exit={0})" -f $LASTEXITCODE)
  }
}

Push-Location $Sandbox
try {
  cmd /c $Command 2>&1 | Tee-Object -FilePath $Log -Append | Out-Host
} finally {
  Pop-Location
}
