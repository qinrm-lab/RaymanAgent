#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAYMAN_DIR="${WORKSPACE_ROOT}/.Rayman"

info(){ echo "[rayman-init] $*"; }
warn(){ echo "[rayman-init][warn] $*" >&2; }

rewrite_shell_script_with_lf() {
  local script_path="$1"
  local tmp_file="${script_path}.rayman-lf.$$"

  if command -v perl >/dev/null 2>&1; then
    if perl -e 'use strict; use warnings; my ($in, $out) = @ARGV; open my $fh, q{<:raw}, $in or die $!; local $/; my $content = <$fh>; close $fh; $content =~ s/\r\n/\n/g; $content =~ s/\r/\n/g; open my $ofh, q{>:raw}, $out or die $!; print {$ofh} $content; close $ofh; rename $out, $in or die $!;' "${script_path}" "${tmp_file}"; then
      return 0
    fi
    rm -f "${tmp_file}" 2>/dev/null || true
  fi

  tr -d '\r' < "${script_path}" > "${tmp_file}"
  mv "${tmp_file}" "${script_path}"
}

shell_script_has_cr() {
  local script_path="$1"

  if command -v perl >/dev/null 2>&1; then
    perl -e 'use strict; use warnings; my ($path) = @ARGV; open my $fh, q{<:raw}, $path or die $!; local $/; my $content = <$fh>; close $fh; exit(index($content, "\r") >= 0 ? 0 : 1);' "${script_path}"
    return $?
  fi

  LC_ALL=C grep -q $'\r' "${script_path}"
}

normalize_managed_shell_scripts() {
  local normalized=0
  local script_path=""

  while IFS= read -r -d '' script_path; do
    chmod +x "${script_path}" 2>/dev/null || true
    if shell_script_has_cr "${script_path}"; then
      rewrite_shell_script_with_lf "${script_path}"
      chmod +x "${script_path}" 2>/dev/null || true
      normalized=$((normalized + 1))
    fi
  done < <(
    find "${RAYMAN_DIR}" \
      \( -path "${RAYMAN_DIR}/runtime" -o -path "${RAYMAN_DIR}/runtime/*" \) -prune -o \
      -type f -name "*.sh" -print0 2>/dev/null
  )

  if [[ ${normalized} -eq 0 ]]; then
    info "shell scripts already LF"
  elif [[ ${normalized} -eq 1 ]]; then
    info "normalized 1 shell script to LF"
  else
    info "normalized ${normalized} shell scripts to LF"
  fi
}

cd "${WORKSPACE_ROOT}"

[[ -d "${RAYMAN_DIR}" ]] || { echo "[rayman-init] missing .Rayman directory" >&2; exit 2; }

normalize_managed_shell_scripts

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
