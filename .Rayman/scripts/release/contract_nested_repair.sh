#!/usr/bin/env bash
set -euo pipefail

fail(){ echo "❌ [rayman-contract-nested-repair] $*" >&2; exit 3; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
COMMON="${ROOT}/.Rayman/common.ps1"
[[ -f "${COMMON}" ]] || fail "missing common.ps1: ${COMMON}"

PS_HOST=""
if command -v pwsh >/dev/null 2>&1; then
  PS_HOST="$(command -v pwsh)"
elif command -v powershell >/dev/null 2>&1; then
  PS_HOST="$(command -v powershell)"
else
  fail "pwsh/powershell not found"
fi

ps_script="$(mktemp)"
cleanup(){ rm -f "${ps_script}"; }
trap cleanup EXIT

cat > "${ps_script}" <<'PWSH'
param([string]$Root)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $Root '.Rayman/common.ps1')

$targetRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_contract_nested_' + [Guid]::NewGuid().ToString('N'))
$nestedDir = Join-Path $targetRoot '.Rayman/.Rayman'
New-Item -ItemType Directory -Force -Path $nestedDir | Out-Null
Set-Content -LiteralPath (Join-Path $nestedDir 'CONTEXT.md') -Value 'legacy nested marker' -NoNewline -Encoding UTF8

$callerDiag = Join-Path $Root '.Rayman/logs/diag.log'
$callerBefore = 0
if (Test-Path -LiteralPath $callerDiag -PathType Leaf) {
  $callerBefore = @(Get-Content -LiteralPath $callerDiag -ErrorAction SilentlyContinue).Count
}

$repairRes = Repair-RaymanNestedDir -WorkspaceRoot $targetRoot
if (-not $repairRes.repaired) {
  throw ("expected repaired=true, actual repaired={0}, error={1}" -f [string]$repairRes.repaired, [string]$repairRes.error)
}
if (Test-Path -LiteralPath (Join-Path $targetRoot '.Rayman/.Rayman') -PathType Container) {
  throw 'nested directory still exists after repair'
}
$backupPath = [string]$repairRes.backup
if (-not (Test-Path -LiteralPath $backupPath -PathType Container)) {
  $migrationRoot = Join-Path $targetRoot '.Rayman/runtime/migration'
  $migrationDirs = @()
  if (Test-Path -LiteralPath $migrationRoot -PathType Container) {
    $migrationDirs = @(Get-ChildItem -LiteralPath $migrationRoot -Directory -ErrorAction SilentlyContinue)
  }
  if ($migrationDirs.Count -lt 1) {
    throw ("backup directory missing and no migration dirs found: {0}" -f $backupPath)
  }
  $backupPath = [string]$migrationDirs[0].FullName
}

$stateLog = Join-Path $targetRoot '.Rayman/state/nested_rayman_repair.log'
if (-not (Test-Path -LiteralPath $stateLog -PathType Leaf)) {
  throw ("state log missing: {0}" -f $stateLog)
}
$stateRaw = Get-Content -LiteralPath $stateLog -Raw -Encoding UTF8
if ($stateRaw -notmatch 'OK') {
  throw 'state log does not contain OK marker'
}

$targetDiag = Join-Path $targetRoot '.Rayman/logs/diag.log'
if (-not (Test-Path -LiteralPath $targetDiag -PathType Leaf)) {
  throw ("target diag missing: {0}" -f $targetDiag)
}
$targetDiagRaw = Get-Content -LiteralPath $targetDiag -Raw -Encoding UTF8
if ($targetDiagRaw -notmatch 'nested-rayman-repair') {
  throw 'target diag does not contain nested-rayman-repair marker'
}

$callerAfterLines = @()
if (Test-Path -LiteralPath $callerDiag -PathType Leaf) {
  $callerAfterLines = @(Get-Content -LiteralPath $callerDiag -ErrorAction SilentlyContinue)
}
if ($callerAfterLines.Count -gt $callerBefore) {
  $newLines = @($callerAfterLines[$callerBefore..($callerAfterLines.Count - 1)])
  $nestedMarkerInCaller = @($newLines | Where-Object { [string]$_ -match 'nested-rayman-repair' }).Count
  if ($nestedMarkerInCaller -gt 0) {
    throw 'caller diag contains nested-rayman-repair marker; expected target workspace diag only'
  }
}

try { Remove-Item -LiteralPath $targetRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
Write-Output 'OK'
PWSH

"${PS_HOST}" -NoProfile -ExecutionPolicy Bypass -File "${ps_script}" -Root "${ROOT}" >/dev/null
echo "OK"
