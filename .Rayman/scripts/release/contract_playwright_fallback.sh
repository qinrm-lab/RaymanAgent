#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SETUP="${ROOT}/.Rayman/setup.ps1"
READY="${ROOT}/.Rayman/scripts/pwa/ensure_playwright_ready.ps1"
README="${ROOT}/.Rayman/README.md"

for file in "${SETUP}" "${READY}" "${README}"; do
  [[ -f "${file}" ]] || { echo "missing: ${file}" >&2; exit 3; }
done

assert_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq -- "${needle}" "${file}"; then
    echo "missing token in ${file}: ${needle}" >&2
    exit 3
  fi
}

assert_contains "${READY}" "function Get-SandboxFailureKindFromMessage"
assert_contains "${READY}" "function Get-SandboxActionRequired"
assert_contains "${READY}" "failure_kind"
assert_contains "${READY}" "action_required"
assert_contains "${READY}" "若你手工关闭了 Sandbox，本次 sandbox 检查会失败；无需等待自动关闭。"

assert_contains "${SETUP}" "function Get-PlaywrightSandboxFailureKind"
assert_contains "${SETUP}" "feature_not_enabled"
assert_contains "${SETUP}" "exited_before_ready"
assert_contains "${SETUP}" "bootstrap_stalled"
assert_contains "${SETUP}" "timeout_no_status"
assert_contains "${SETUP}" "自动降级到 scope=wsl 重试一次"

assert_contains "${README}" "## Windows Sandbox 常见问题"
assert_contains "${README}" "不需要。"
assert_contains "${README}" "RAYMAN_SANDBOX_AUTO_CLOSE"
assert_contains "${README}" "RAYMAN_PLAYWRIGHT_SETUP_SCOPE=sandbox"

echo "OK"
