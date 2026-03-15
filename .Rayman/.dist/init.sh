#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAYMAN_DIR="${WORKSPACE_ROOT}/.Rayman"

info(){ echo "[rayman-init] $*"; }
warn(){ echo "[rayman-init][warn] $*" >&2; }

cd "${WORKSPACE_ROOT}"

[[ -d "${RAYMAN_DIR}" ]] || { echo "[rayman-init] missing .Rayman directory" >&2; exit 2; }

repair_script="${RAYMAN_DIR}/scripts/repair/ensure_complete_rayman.sh"
if [[ -f "${repair_script}" ]]; then
  bash "${repair_script}"
fi

workspace_state_guard="${RAYMAN_DIR}/scripts/utils/workspace_state_guard.sh"
if [[ -f "${workspace_state_guard}" ]]; then
  bash "${workspace_state_guard}" --workspace-root "${WORKSPACE_ROOT}"
else
  warn "workspace state guard missing: ${workspace_state_guard}"
fi

find "${RAYMAN_DIR}" -type f -name "*.sh" -exec chmod +x {} + 2>/dev/null || true

if [[ ! -f "${RAYMAN_DIR}/codex_fix_prompt.txt" && -f "${RAYMAN_DIR}/templates/codex_fix_prompt.base.txt" ]]; then
  cp "${RAYMAN_DIR}/templates/codex_fix_prompt.base.txt" "${RAYMAN_DIR}/codex_fix_prompt.txt"
fi

info "sync requirements layout"
bash "${RAYMAN_DIR}/scripts/requirements/ensure_requirements.sh"

info "sync prompt -> requirements"
bash "${RAYMAN_DIR}/scripts/requirements/process_prompts.sh"

if [[ -f "${RAYMAN_DIR}/scripts/pwa/ensure_playwright_wsl.sh" && "${RAYMAN_SKIP_PLAYWRIGHT_READY:-0}" != "1" ]]; then
  info "ensure WSL/Linux Playwright readiness"
  bash "${RAYMAN_DIR}/scripts/pwa/ensure_playwright_wsl.sh" --workspace-root "${WORKSPACE_ROOT}" --require "${RAYMAN_PLAYWRIGHT_REQUIRE:-1}"
else
  warn "skip Playwright readiness (script missing or RAYMAN_SKIP_PLAYWRIGHT_READY=1)"
fi

info "init complete"
