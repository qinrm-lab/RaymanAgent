#!/usr/bin/env bash
set -euo pipefail

workspace_root="$(pwd)"
browser="${RAYMAN_PLAYWRIGHT_BROWSER:-chromium}"
require_playwright="${RAYMAN_PLAYWRIGHT_REQUIRE:-1}"

usage() {
  cat <<'TXT'
Usage:
  bash ./.Rayman/scripts/pwa/ensure_playwright_wsl.sh [options]

Options:
  --workspace-root DIR   workspace root (default: current directory)
  --browser NAME         browser to prepare (default: env RAYMAN_PLAYWRIGHT_BROWSER or chromium)
  --require 0|1          fail when Playwright is not ready (default: env RAYMAN_PLAYWRIGHT_REQUIRE or 1)
TXT
}

is_flag() {
  [[ "${1:-}" == "0" || "${1:-}" == "1" ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-root) workspace_root="${2:-}"; shift 2 ;;
    --browser) browser="${2:-}"; shift 2 ;;
    --require) require_playwright="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[pwa] unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

is_flag "${require_playwright}" || { echo "[pwa] --require must be 0 or 1" >&2; exit 2; }

workspace_root="$(cd "${workspace_root}" && pwd)"
cd "${workspace_root}"

browser="$(printf '%s' "${browser}" | tr '[:upper:]' '[:lower:]')"
if [[ "${browser}" != "chromium" ]]; then
  echo "[pwa] unsupported browser: ${browser} (only chromium is supported)" >&2
  exit 2
fi

runtime_dir=".Rayman/runtime"
marker_file="${runtime_dir}/playwright.ready.wsl.json"
mkdir -p "${runtime_dir}"
playwright_version=""
chromium_source=""

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_marker() {
  local success="$1"
  local skipped="$2"
  local detail="$3"
  local chromium_source="$4"
  local playwright_version="$5"
  local generated_at
  generated_at="$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")"

  local detail_e chromium_e version_e
  detail_e="$(json_escape "${detail}")"
  chromium_e="$(json_escape "${chromium_source}")"
  version_e="$(json_escape "${playwright_version}")"

  cat > "${marker_file}" <<JSON
{"schema":"rayman.playwright.wsl.v1","success":${success},"skipped":${skipped},"browser":"${browser}","chromium_source":"${chromium_e}","playwright_version":"${version_e}","generated_at":"${generated_at}","detail":"${detail_e}"}
JSON
}

finalize_marker_on_exit() {
  local rc=$?
  set +e
  if [[ ! -f "${marker_file}" ]]; then
    write_marker false false "playwright ensure aborted before marker (exit=${rc})" "${chromium_source:-missing}" "${playwright_version:-}" >/dev/null 2>&1 || true
    echo "[pwa] WARN: marker missing on exit; wrote fallback marker (exit=${rc})" >&2
  fi
  return "${rc}"
}

trap finalize_marker_on_exit EXIT

if [[ "${RAYMAN_SKIP_PWA:-0}" == "1" ]]; then
  if [[ "${require_playwright}" == "1" ]]; then
    write_marker false true "RAYMAN_SKIP_PWA=1 conflicts with required Playwright readiness" "skipped" ""
    echo "[pwa] RAYMAN_SKIP_PWA=1 conflicts with required Playwright readiness" >&2
    exit 2
  fi
  write_marker false true "RAYMAN_SKIP_PWA=1 (non-required mode)" "skipped" ""
  echo "[pwa] RAYMAN_SKIP_PWA=1, skip in non-required mode"
  exit 0
fi

echo "[pwa] ensure Playwright toolchain on WSL/Linux"

have() { command -v "$1" >/dev/null 2>&1; }

sudo_nopass=0
if have sudo && sudo -n true >/dev/null 2>&1; then
  sudo_nopass=1
fi
if [[ "${sudo_nopass}" != "1" ]]; then
  echo "[pwa] WARN: sudo non-interactive is unavailable; skip '--with-deps' and rely on existing system deps/cache."
fi

# Prefer Linux node/npm/npx even when Windows Node is on PATH (common in WSL).
pick_linux_bin() {
  local name="$1"
  if [[ -x "/usr/bin/${name}" ]]; then
    echo "/usr/bin/${name}"
    return 0
  fi
  command -v "${name}" 2>/dev/null || true
}

ensure_linux_node() {
  local node_bin
  node_bin="$(pick_linux_bin node)"
  if [[ -z "${node_bin}" || "${node_bin}" == *".exe" || "${node_bin}" == /mnt/* ]]; then
    echo "[pwa] WARN: node resolves to Windows binary (${node_bin:-missing}). Installing Linux nodejs/npm and using /usr/bin/* when available."
    sudo apt-get update -y
    sudo apt-get install -y nodejs npm
  fi
}

ensure_linux_node

NPM_BIN="$(pick_linux_bin npm)"
NPX_BIN="$(pick_linux_bin npx)"

if [[ -z "${NPM_BIN}" || -z "${NPX_BIN}" ]]; then
  echo "[pwa] installing nodejs/npm..."
  sudo apt-get update -y
  sudo apt-get install -y nodejs npm
  NPM_BIN="$(pick_linux_bin npm)"
  NPX_BIN="$(pick_linux_bin npx)"
fi

echo "[pwa] npm: ${NPM_BIN}"
echo "[pwa] npx: ${NPX_BIN}"

# If we are inside a repo with package.json, install deps first to avoid Playwright warnings
if [[ -f "package.json" ]]; then
  if [[ ! -d "node_modules" || "${RAYMAN_FORCE_NPM_INSTALL:-0}" == "1" ]]; then
    echo "[pwa] npm install (project deps)"
    "${NPM_BIN}" install
  else
    echo "[pwa] npm deps already present (node_modules)"
  fi
fi

# Fast-path cache
BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-${HOME}/.cache/ms-playwright}"
DEPS_MARKER=".Rayman/runtime/playwright_deps.ok"

has_playwright_cache() {
  ls "${BROWSERS_PATH}"/chromium-* >/dev/null 2>&1 && return 0
  return 1
}

playwright_cmd() {
  # --no-install: fail fast if present in node_modules/.bin
  if "${NPX_BIN}" --no-install playwright --version >/dev/null 2>&1; then
    echo "${NPX_BIN} playwright"
  else
    echo "${NPX_BIN} --yes playwright@latest"
  fi
}

save_proxy_env() {
  export __RAYMAN_HTTP_PROXY="${http_proxy-}"
  export __RAYMAN_HTTPS_PROXY="${https_proxy-}"
  export __RAYMAN_ALL_PROXY="${all_proxy-}"
  export __RAYMAN_HTTP_PROXY_U="${HTTP_PROXY-}"
  export __RAYMAN_HTTPS_PROXY_U="${HTTPS_PROXY-}"
  export __RAYMAN_ALL_PROXY_U="${ALL_PROXY-}"
  export __RAYMAN_NO_PROXY="${no_proxy-}"
  export __RAYMAN_NO_PROXY_U="${NO_PROXY-}"
}

clear_proxy_env() {
  unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY
}

restore_proxy_env() {
  if [[ -n "${__RAYMAN_HTTP_PROXY-}" ]]; then export http_proxy="${__RAYMAN_HTTP_PROXY}"; else unset http_proxy; fi
  if [[ -n "${__RAYMAN_HTTPS_PROXY-}" ]]; then export https_proxy="${__RAYMAN_HTTPS_PROXY}"; else unset https_proxy; fi
  if [[ -n "${__RAYMAN_ALL_PROXY-}" ]]; then export all_proxy="${__RAYMAN_ALL_PROXY}"; else unset all_proxy; fi
  if [[ -n "${__RAYMAN_HTTP_PROXY_U-}" ]]; then export HTTP_PROXY="${__RAYMAN_HTTP_PROXY_U}"; else unset HTTP_PROXY; fi
  if [[ -n "${__RAYMAN_HTTPS_PROXY_U-}" ]]; then export HTTPS_PROXY="${__RAYMAN_HTTPS_PROXY_U}"; else unset HTTPS_PROXY; fi
  if [[ -n "${__RAYMAN_ALL_PROXY_U-}" ]]; then export ALL_PROXY="${__RAYMAN_ALL_PROXY_U}"; else unset ALL_PROXY; fi
  if [[ -n "${__RAYMAN_NO_PROXY-}" ]]; then export no_proxy="${__RAYMAN_NO_PROXY}"; else unset no_proxy; fi
  if [[ -n "${__RAYMAN_NO_PROXY_U-}" ]]; then export NO_PROXY="${__RAYMAN_NO_PROXY_U}"; else unset NO_PROXY; fi
}

playwright_install_try() {
  local label="$1"
  local attempts="$2"
  local attempt rc cmd
  cmd="$(playwright_cmd)"
  set +e
  rc=1
  for attempt in $(seq 1 "${attempts}"); do
    echo "[pwa] ${label}: playwright install attempt ${attempt}/${attempts} (${browser})"
    # shellcheck disable=SC2086
    if [[ -f "${DEPS_MARKER}" || "${sudo_nopass}" != "1" ]]; then
      ${cmd} install "${browser}"
    else
      ${cmd} install --with-deps "${browser}"
    fi
    rc=$?
    if [[ $rc -eq 0 ]]; then
      echo "[pwa] ${label}: playwright install success"
      if [[ ! -f "${DEPS_MARKER}" ]]; then
        date -Iseconds > "${DEPS_MARKER}" || true
        echo "[pwa] wrote deps marker: ${DEPS_MARKER}"
      fi
      break
    fi
    echo "[pwa] WARN: ${label}: playwright install failed (rc=$rc). Retrying in 5s..."
    sleep 5
  done
  set -e
  return $rc
}

install_system_chromium() {
  echo "[pwa] fallback: install system chromium via apt (no Playwright CDN download required)"
  sudo apt-get update -y
  sudo apt-get install -y chromium || true
  sudo apt-get install -y chromium-browser || true
  sudo apt-get install -y xvfb fonts-liberation libgtk-3-0 libnss3 libasound2 || true

  local exe=""
  if command -v chromium >/dev/null 2>&1; then exe="$(command -v chromium)"; fi
  if [[ -z "$exe" ]] && command -v chromium-browser >/dev/null 2>&1; then exe="$(command -v chromium-browser)"; fi

  if [[ -n "$exe" ]]; then
    echo "[pwa] system chromium found: $exe"
    mkdir -p ".Rayman/runtime"
    cat > ".Rayman/runtime/pwa_browser.env" <<ENV
# Generated by ensure_playwright_wsl.sh
export RAYMAN_PWA_CHROMIUM_EXECUTABLE="${exe}"
ENV
    echo "[pwa] wrote: .Rayman/runtime/pwa_browser.env"
    return 0
  fi

  echo "[pwa] ERROR: system chromium install attempted, but executable not found."
  return 1
}

detect_playwright_version() {
  local version_line=""
  if [[ -n "${NPX_BIN}" ]] && "${NPX_BIN}" --no-install playwright --version >/tmp/rayman_pw_ver.txt 2>/dev/null; then
    version_line="$(head -n 1 /tmp/rayman_pw_ver.txt || true)"
    rm -f /tmp/rayman_pw_ver.txt
    printf '%s' "${version_line}"
    return 0
  fi
  rm -f /tmp/rayman_pw_ver.txt >/dev/null 2>&1 || true

  if have playwright; then
    set +e
    version_line="$(playwright --version 2>/dev/null | head -n 1)"
    local rc=$?
    set -e
    if [[ $rc -eq 0 && -n "${version_line}" ]]; then
      printf '%s' "${version_line}"
      return 0
    fi
  fi

  if [[ -n "${NPX_BIN}" ]] && "${NPX_BIN}" --yes playwright@latest --version >/tmp/rayman_pw_ver.txt 2>/dev/null; then
    version_line="$(head -n 1 /tmp/rayman_pw_ver.txt || true)"
    rm -f /tmp/rayman_pw_ver.txt
    printf '%s' "${version_line}"
    return 0
  fi
  rm -f /tmp/rayman_pw_ver.txt >/dev/null 2>&1 || true

  return 1
}

detect_chromium_source() {
  if has_playwright_cache; then
    printf '%s' "playwright-cache"
    return 0
  fi

  if [[ -f ".Rayman/runtime/pwa_browser.env" ]]; then
    # shellcheck disable=SC1091
    source ".Rayman/runtime/pwa_browser.env" || true
    if [[ -n "${RAYMAN_PWA_CHROMIUM_EXECUTABLE:-}" && -x "${RAYMAN_PWA_CHROMIUM_EXECUTABLE}" ]]; then
      printf '%s' "system-chromium-env"
      return 0
    fi
  fi

  if command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1; then
    printf '%s' "system-chromium-path"
    return 0
  fi

  return 1
}

need_install=1
if [[ "${RAYMAN_FORCE_PLAYWRIGHT_INSTALL:-0}" != "1" ]]; then
  if has_playwright_cache && [[ -f "${DEPS_MARKER}" ]]; then
    echo "[pwa] playwright chromium already present (${BROWSERS_PATH}) and deps marker exists; verify readiness"
    need_install=0
  fi
fi

rc=0
if [[ "${need_install}" == "1" ]]; then
  echo "[pwa] installing playwright browsers + deps (${browser})"
  save_proxy_env

  echo "[pwa] phase1: try without proxy env"
  clear_proxy_env
  "${NPM_BIN}" config delete proxy >/dev/null 2>&1 || true
  "${NPM_BIN}" config delete https-proxy >/dev/null 2>&1 || true

  if playwright_install_try "no-proxy" 3; then
    rc=0
  else
    rc=$?
  fi

  if [[ $rc -ne 0 ]]; then
    echo "[pwa] phase2: retry with proxy env (if any)"
    restore_proxy_env
    if [[ -n "${https_proxy-}" ]]; then "${NPM_BIN}" config set https-proxy "${https_proxy}" >/dev/null 2>&1 || true; fi
    if [[ -n "${http_proxy-}" ]]; then "${NPM_BIN}" config set proxy "${http_proxy}" >/dev/null 2>&1 || true; fi

    if playwright_install_try "proxy" 3; then
      rc=0
    else
      rc=$?
    fi
  fi

  if [[ $rc -ne 0 ]]; then
    echo "[pwa] phase3: try alternate PLAYWRIGHT_DOWNLOAD_HOST"
    export PLAYWRIGHT_DOWNLOAD_HOST="${RAYMAN_PLAYWRIGHT_DOWNLOAD_HOST:-https://playwright.azureedge.net}"
    if playwright_install_try "alt-host" 3; then
      rc=0
    else
      rc=$?
    fi
  fi

  if [[ $rc -ne 0 ]]; then
    echo "[pwa] ERROR: playwright install failed after retries (no-proxy -> proxy -> alt-host)."
    echo "[pwa] Trying to fall back to system Chromium so you can keep debugging PWA..."
    if install_system_chromium; then
      echo "[pwa] fallback success: system chromium installed."
      rc=0
    else
      echo "[pwa] fallback failed: cannot install system chromium either."
    fi
  fi
fi

set +e
playwright_version="$(detect_playwright_version 2>/dev/null)"
playwright_version_rc=$?
chromium_source="$(detect_chromium_source 2>/dev/null)"
chromium_source_rc=$?
set -e

if [[ $playwright_version_rc -ne 0 ]]; then
  playwright_version=""
fi
if [[ $chromium_source_rc -ne 0 ]]; then
  chromium_source=""
fi

ready=0
if [[ -n "${playwright_version}" && -n "${chromium_source}" ]]; then
  ready=1
fi

if [[ "${ready}" == "1" ]]; then
  write_marker true false "playwright wsl ready" "${chromium_source}" "${playwright_version}"
  echo "[pwa] ready: browser=${browser} chromium_source=${chromium_source} playwright_version=${playwright_version}"
else
  write_marker false false "playwright or chromium probe failed" "${chromium_source:-missing}" "${playwright_version}"
  echo "[pwa] ERROR: playwright readiness probe failed (browser=${browser}, playwright_version=${playwright_version:-missing}, chromium_source=${chromium_source:-missing})" >&2
  if [[ "${require_playwright}" == "1" ]]; then
    exit 2
  fi
fi

if command -v dotnet >/dev/null 2>&1; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  RAYMAN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
  OUT_DIR="$RAYMAN_DIR/runtime"
  mkdir -p "$OUT_DIR"
  PFX="$OUT_DIR/devcert.pfx"
  PASS="${RAYMAN_DEVCERT_PASSWORD:-rayman}"
  if [[ "${RAYMAN_FORCE_DEVCERT_EXPORT:-0}" == "1" || ! -f "$PFX" ]]; then
    echo "[pwa] exporting dotnet dev cert to $PFX (best effort)"
    set +e
    dotnet dev-certs https -ep "$PFX" -p "$PASS" >/dev/null 2>&1
    rc2=$?
    set -e
    if [[ $rc2 -ne 0 ]]; then
      echo "[pwa] WARN: devcert export failed (non-blocking)"
    fi
  fi
fi

echo "[pwa] done"
exit 0
