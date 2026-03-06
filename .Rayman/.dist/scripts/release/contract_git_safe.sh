#!/usr/bin/env bash
set -euo pipefail

fail(){ echo "❌ [rayman-contract-git-safe] $*" >&2; exit 3; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
COMMON="${ROOT}/.Rayman/common.ps1"
[[ -f "${COMMON}" ]] || fail "missing common.ps1: ${COMMON}"
command -v git >/dev/null 2>&1 || fail "git not found"

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

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_contract_git_safe_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
Push-Location $tmpRoot
try {
  git init | Out-Null

  Set-Content -LiteralPath 'lf.txt' -Value "a`nb`n" -NoNewline -Encoding UTF8
  $env:RAYMAN_GIT_SAFECRLF_SUPPRESS = '0'

  $thrown = $false
  try {
    $warnRes = Invoke-RaymanGitSafe -WorkspaceRoot $tmpRoot -GitArgs @('-c', 'core.autocrlf=true', 'add', 'lf.txt')
  } catch {
    $thrown = $true
  }

  if ($thrown) {
    throw 'Invoke-RaymanGitSafe threw on safecrlf warning scenario'
  }
  if (-not $warnRes.ok) {
    throw ("safecrlf warning scenario should succeed, exit={0}, reason={1}" -f $warnRes.exitCode, [string]$warnRes.reason)
  }
  if ([string]$warnRes.reason -ne 'ok') {
    throw ("expected reason=ok for safecrlf scenario, actual={0}" -f [string]$warnRes.reason)
  }
  $warnStderr = [string](@($warnRes.stderr) -join "`n")
  if ($warnStderr -notmatch 'LF will be replaced by CRLF') {
    throw ("expected safecrlf warning in stderr, actual={0}" -f $warnStderr)
  }

  Set-Content -LiteralPath 'sp ace.txt' -Value 'x' -NoNewline -Encoding UTF8
  $spaceRes = Invoke-RaymanGitSafe -WorkspaceRoot $tmpRoot -GitArgs @('add', 'sp ace.txt')
  if (-not $spaceRes.ok) {
    throw ("space path add failed, exit={0}, reason={1}, stderr={2}" -f $spaceRes.exitCode, [string]$spaceRes.reason, [string](@($spaceRes.stderr) -join ' | '))
  }
  if ([string]$spaceRes.reason -ne 'ok') {
    throw ("expected reason=ok for space path add, actual={0}" -f [string]$spaceRes.reason)
  }

  $missingRoot = Join-Path $tmpRoot 'missing-workspace'
  $missingRes = Invoke-RaymanGitSafe -WorkspaceRoot $missingRoot -GitArgs @('status', '--porcelain')
  if ($missingRes.available) {
    throw 'workspace_not_found scenario should return available=false'
  }
  if ([string]$missingRes.reason -ne 'workspace_not_found') {
    throw ("expected reason=workspace_not_found, actual={0}" -f [string]$missingRes.reason)
  }
} finally {
  Pop-Location
  try { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Output 'OK'
PWSH

"${PS_HOST}" -NoProfile -ExecutionPolicy Bypass -File "${ps_script}" -Root "${ROOT}" >/dev/null
echo "OK"
