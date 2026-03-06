#!/usr/bin/env bash
set -euo pipefail

workspace_root="$(pwd)"
auto_install="${RAYMAN_AUTO_INSTALL_TEST_DEPS:-1}"
require_deps="${RAYMAN_REQUIRE_TEST_DEPS:-1}"
windows_preferred="${RAYMAN_DOTNET_WINDOWS_PREFERRED:-1}"
windows_strict="${RAYMAN_DOTNET_WINDOWS_STRICT:-0}"
only_kinds=""

usage() {
  cat <<'TXT'
Usage:
  bash ./.Rayman/scripts/utils/ensure_project_test_deps.sh [options]

Options:
  --workspace-root DIR   workspace root (default: current directory)
  --auto-install 0|1     auto-install missing deps (default: env RAYMAN_AUTO_INSTALL_TEST_DEPS or 1)
  --require 0|1          fail when deps remain missing (default: env RAYMAN_REQUIRE_TEST_DEPS or 1)
  --only KINDS           comma list: dotnet,node,python (default: all)
TXT
}

is_flag() {
  case "${1:-}" in
    1|0|true|false|TRUE|FALSE|True|False) return 0 ;;
    *) return 1 ;;
  esac
}
to_bool01() {
  case "${1:-}" in
    1|true|TRUE|True) echo "1" ;;
    0|false|FALSE|False) echo "0" ;;
    *) echo "__invalid__" ;;
  esac
}
normalize_only_kinds() {
  local raw="${1:-}"
  local norm=""
  local has_dotnet=0
  local has_node=0
  local has_python=0

  if [[ -z "${raw//[[:space:]]/}" ]]; then
    echo ""
    return 0
  fi

  IFS=',' read -ra parts <<< "${raw}"
  for part in "${parts[@]}"; do
    local tk
    tk="$(echo "${part}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    [[ -z "${tk}" ]] && continue
    case "${tk}" in
      all)
        has_dotnet=1
        has_node=1
        has_python=1
        ;;
      dotnet) has_dotnet=1 ;;
      node) has_node=1 ;;
      python) has_python=1 ;;
      *)
        echo "__invalid__:${tk}"
        return 0
        ;;
    esac
  done

  if [[ "${has_dotnet}" == "1" ]]; then
    norm="dotnet"
  fi
  if [[ "${has_node}" == "1" ]]; then
    if [[ -n "${norm}" ]]; then norm+=",node"; else norm="node"; fi
  fi
  if [[ "${has_python}" == "1" ]]; then
    if [[ -n "${norm}" ]]; then norm+=",python"; else norm="python"; fi
  fi

  echo "${norm}"
}
has_kind_enabled() {
  local only="${1:-}"
  local kind="${2:-}"
  if [[ -z "${only}" ]]; then
    return 0
  fi
  [[ ",${only}," == *",${kind},"* ]]
}
has_cmd() { command -v "$1" >/dev/null 2>&1; }
info() { echo "[test-deps] $*"; }
warn() { echo "[test-deps][warn] $*" >&2; }

is_wsl() {
  [[ -n "${WSL_INTEROP:-}" ]] && return 0
  grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null
}

DOTNET_PROBE_OUTPUT=""
DOTNET_PROBE_REASON=""
BRIDGE_READY=0
BRIDGE_REASON=""
BRIDGE_PS=""
BRIDGE_WORKSPACE_WIN=""
BRIDGE_SCRIPT_WIN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-root) workspace_root="${2:-}"; shift 2 ;;
    --auto-install) auto_install="${2:-}"; shift 2 ;;
    --require) require_deps="${2:-}"; shift 2 ;;
    --only) only_kinds="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[test-deps] unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

is_flag "${auto_install}" || { echo "[test-deps] --auto-install must be 0/1/true/false" >&2; exit 2; }
is_flag "${require_deps}" || { echo "[test-deps] --require must be 0/1/true/false" >&2; exit 2; }
is_flag "${windows_preferred}" || { echo "[test-deps] RAYMAN_DOTNET_WINDOWS_PREFERRED must be 0/1/true/false" >&2; exit 2; }
is_flag "${windows_strict}" || { echo "[test-deps] RAYMAN_DOTNET_WINDOWS_STRICT must be 0/1/true/false" >&2; exit 2; }

auto_install="$(to_bool01 "${auto_install}")"
require_deps="$(to_bool01 "${require_deps}")"
windows_preferred="$(to_bool01 "${windows_preferred}")"
windows_strict="$(to_bool01 "${windows_strict}")"
only_kinds="$(normalize_only_kinds "${only_kinds}")"
if [[ "${only_kinds}" == __invalid__:* ]]; then
  echo "[test-deps] --only contains invalid kind: ${only_kinds#__invalid__:}" >&2
  exit 2
fi

workspace_root="$(cd "${workspace_root}" && pwd)"
cd "${workspace_root}"

detect_windows_bridge() {
  BRIDGE_READY=0
  BRIDGE_REASON=""
  BRIDGE_PS=""
  BRIDGE_WORKSPACE_WIN=""
  BRIDGE_SCRIPT_WIN=""

  if ! is_wsl; then
    BRIDGE_REASON="not_wsl"
    return
  fi
  if ! has_cmd powershell.exe; then
    BRIDGE_REASON="powershell.exe_not_found"
    return
  fi
  if ! has_cmd wslpath; then
    BRIDGE_REASON="wslpath_not_found"
    return
  fi
  if [[ ! "${workspace_root}" =~ ^/mnt/[A-Za-z]/ ]]; then
    BRIDGE_REASON="workspace_not_on_windows_drive"
    return
  fi
  local script_wsl="${workspace_root}/.Rayman/scripts/utils/ensure_project_test_deps.ps1"
  if [[ ! -f "${script_wsl}" ]]; then
    BRIDGE_REASON="ensure_project_test_deps.ps1_missing"
    return
  fi

  BRIDGE_WORKSPACE_WIN="$(wslpath -w "${workspace_root}" 2>/dev/null | tr -d '\r' | head -n 1)"
  BRIDGE_SCRIPT_WIN="$(wslpath -w "${script_wsl}" 2>/dev/null | tr -d '\r' | head -n 1)"
  BRIDGE_PS="$(command -v powershell.exe || true)"
  if [[ -z "${BRIDGE_WORKSPACE_WIN}" || -z "${BRIDGE_SCRIPT_WIN}" || -z "${BRIDGE_PS}" ]]; then
    BRIDGE_REASON="wslpath_conversion_failed"
    return
  fi

  BRIDGE_READY=1
  BRIDGE_REASON="ok"
}

dotnet_probe() {
  DOTNET_PROBE_OUTPUT=""
  DOTNET_PROBE_REASON=""
  if ! has_cmd dotnet; then
    DOTNET_PROBE_REASON="dotnet_not_found"
    return 1
  fi

  local out rc out2 rc2 merged lower
  set +e
  out="$(dotnet --version 2>&1)"
  rc=$?
  set -e
  DOTNET_PROBE_OUTPUT="${out}"
  if [[ ${rc} -eq 0 && -n "${out//[[:space:]]/}" ]]; then
    return 0
  fi

  set +e
  out2="$(dotnet --info 2>&1)"
  rc2=$?
  set -e
  if [[ -n "${DOTNET_PROBE_OUTPUT}" && -n "${out2}" ]]; then
    DOTNET_PROBE_OUTPUT="${DOTNET_PROBE_OUTPUT}"$'\n'"${out2}"
  elif [[ -n "${out2}" ]]; then
    DOTNET_PROBE_OUTPUT="${out2}"
  fi
  if [[ ${rc2} -eq 0 ]]; then
    return 0
  fi

  merged="${DOTNET_PROBE_OUTPUT}"
  lower="${merged,,}"
  if [[ "${lower}" =~ (vsock|exec\ format\ error|permission\ denied|cannot\ execute\ binary\ file|bad\ cpu\ type|elfclass|operation\ not\ permitted) ]]; then
    DOTNET_PROBE_REASON="dotnet_not_runnable_signature"
  else
    DOTNET_PROBE_REASON="dotnet_not_runnable"
  fi
  return 1
}

invoke_windows_dotnet_deps() {
  local auto_ps='0'
  local require_ps='0'
  if [[ "${auto_install}" == "1" ]]; then auto_ps='1'; fi
  if [[ "${require_deps}" == "1" ]]; then require_ps='1'; fi

  local output rc
  set +e
  output="$("${BRIDGE_PS}" -NoProfile -ExecutionPolicy Bypass -File "${BRIDGE_SCRIPT_WIN}" \
    -WorkspaceRoot "${BRIDGE_WORKSPACE_WIN}" \
    -AutoInstall "${auto_ps}" \
    -Require "${require_ps}" \
    -OnlyKinds "dotnet" \
    -Caller "ensure_project_test_deps.sh" \
    -CallerHostType "wsl-bridge" \
    -CallerWorkspaceRoot "${workspace_root}" 2>&1)"
  rc=$?
  set -e

  if [[ -n "${output}" ]]; then
    echo "${output}"
  fi
  return "${rc}"
}

need_dotnet=0
need_node=0
need_python=0

while IFS= read -r -d '' f; do
  name="$(basename "$f")"
  case "$name" in
    *.sln|*.slnx|*.csproj|*.fsproj|*.vbproj) need_dotnet=1 ;;
    package.json) need_node=1 ;;
    pyproject.toml|requirements.txt) need_python=1 ;;
  esac
done < <(find . -type f \( -name '*.sln' -o -name '*.slnx' -o -name '*.csproj' -o -name '*.fsproj' -o -name '*.vbproj' -o -name 'package.json' -o -name 'pyproject.toml' -o -name 'requirements.txt' \) \
  -not -path './.git/*' -not -path './.Rayman/*' -not -path './.venv/*' -not -path './node_modules/*' -print0)

info "detected deps: dotnet=${need_dotnet}, node=${need_node}, python=${need_python}"
if [[ -n "${only_kinds}" ]]; then
  info "dependency filter enabled: only=${only_kinds}"
fi

if ! has_kind_enabled "${only_kinds}" "dotnet"; then
  need_dotnet=0
fi
if ! has_kind_enabled "${only_kinds}" "node"; then
  need_node=0
fi
if ! has_kind_enabled "${only_kinds}" "python"; then
  need_python=0
fi
info "effective deps: dotnet=${need_dotnet}, node=${need_node}, python=${need_python}"

if [[ "${need_dotnet}" == "1" && "${windows_preferred}" == "1" ]]; then
  detect_windows_bridge
  info "dotnet host strategy: windowsPreferred=1 strict=${windows_strict} bridgeReady=${BRIDGE_READY} reason=${BRIDGE_REASON}"
fi

missing=()

install_dotnet_local() {
  local channel="${RAYMAN_DOTNET_CHANNEL:-LTS}"
  local install_root="${HOME}/.dotnet"
  mkdir -p "${install_root}"
  local installer="/tmp/dotnet-install.sh"
  if has_cmd curl; then
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o "${installer}"
  elif has_cmd wget; then
    wget -qO "${installer}" https://dot.net/v1/dotnet-install.sh
  else
    warn "curl/wget not found; cannot auto-install dotnet"
    return 1
  fi
  chmod +x "${installer}"
  "${installer}" --channel "${channel}" --install-dir "${install_root}" --no-path
  export DOTNET_ROOT="${install_root}"
  export PATH="${install_root}:${PATH}"
}

apt_try_install() {
  local pkgs=("$@")
  local -a runner
  if ! has_cmd apt-get; then
    warn "apt-get not found; cannot auto-install packages: ${pkgs[*]}"
    return 1
  fi

  if [[ "$(id -u)" -eq 0 ]]; then
    runner=(apt-get)
  elif has_cmd sudo; then
    if ! sudo -n true >/dev/null 2>&1; then
      warn "sudo requires password or permission denied; skip auto-install: ${pkgs[*]}"
      return 1
    fi
    runner=(sudo apt-get)
  else
    warn "sudo not found and current user is not root; skip auto-install: ${pkgs[*]}"
    return 1
  fi

  "${runner[@]}" update || return 1
  "${runner[@]}" install -y "${pkgs[@]}" || return 1
  return 0
}

if [[ "${need_dotnet}" == "1" ]]; then
  dotnet_ready=0
  if dotnet_probe; then
    dotnet_ready=1
    info "dotnet executable probe passed"
  else
    warn "dotnet probe failed (${DOTNET_PROBE_REASON})"
    if [[ -n "${DOTNET_PROBE_OUTPUT}" ]]; then
      warn "dotnet probe output: $(echo "${DOTNET_PROBE_OUTPUT}" | tr '\n' ' ' | cut -c1-400)"
    fi
  fi

  if [[ "${dotnet_ready}" == "0" && "${windows_preferred}" == "1" && "${BRIDGE_READY}" == "1" ]]; then
    info "dotnet missing/unrunnable in WSL; trying Windows bridge ensure_project_test_deps.ps1"
    if invoke_windows_dotnet_deps; then
      info "Windows bridge dependency check succeeded"
      dotnet_ready=1
    else
      if [[ "${windows_strict}" == "1" ]]; then
        echo "[test-deps] windows bridge dependency check failed and strict mode enabled" >&2
        exit 2
      fi
      warn "Windows bridge dependency check failed; fallback to Linux dependency flow"
    fi
  fi

  if [[ "${dotnet_ready}" == "0" ]]; then
    if [[ "${auto_install}" == "1" ]]; then
      warn "dotnet missing/unrunnable; trying local install via dotnet-install.sh"
      install_dotnet_local || true
    fi
    if dotnet_probe; then
      dotnet_ready=1
      info "dotnet executable probe passed after Linux fallback install"
    fi
  fi

  if [[ "${dotnet_ready}" == "0" ]]; then
    missing+=(dotnet)
  fi
fi

if [[ "${need_node}" == "1" ]] && ! has_cmd node; then
  if [[ "${auto_install}" == "1" ]]; then
    warn "node missing; trying apt install nodejs npm"
    apt_try_install nodejs npm || true
  fi
  has_cmd node || missing+=(node)
fi

if [[ "${need_python}" == "1" ]] && ! has_cmd python3; then
  if [[ "${auto_install}" == "1" ]]; then
    warn "python3 missing; trying apt install python3 python3-pip"
    apt_try_install python3 python3-pip || true
  fi
  has_cmd python3 || missing+=(python3)
fi

if [[ "${#missing[@]}" -gt 0 ]]; then
  if [[ "${require_deps}" == "1" ]]; then
    echo "[test-deps] missing required test dependencies: ${missing[*]}" >&2
    exit 2
  fi
  warn "missing test dependencies: ${missing[*]}"
else
  info "test dependencies ready"
fi

exit 0
