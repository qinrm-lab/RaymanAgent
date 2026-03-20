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

normalize_xml() {
  tr '\r\n' '  ' < "$1"
}

extract_target_frameworks_from_csproj() {
  local path="$1"
  local raw match value part
  raw="$(normalize_xml "${path}")"
  while IFS= read -r match; do
    value="$(printf '%s' "${match}" | sed -E 's#<TargetFrameworks?[^>]*>[[:space:]]*([^<]*)[[:space:]]*</TargetFrameworks?>#\1#I')"
    IFS=';' read -ra tf_parts <<< "${value}"
    for part in "${tf_parts[@]}"; do
      part="$(echo "${part}" | xargs)"
      [[ -z "${part}" ]] && continue
      [[ "${part}" == *'$('* ]] && continue
      echo "${part}"
    done
  done < <(printf '%s' "${raw}" | grep -oEi '<TargetFrameworks?[^>]*>[^<]*</TargetFrameworks?>' || true)
}

detect_use_maui() {
  local path="$1"
  local raw
  raw="$(normalize_xml "${path}")"
  [[ "${raw,,}" == *"<usemaui>true</usemaui>"* ]]
}

detect_windows_desktop() {
  local path="$1"
  local raw
  raw="$(normalize_xml "${path}")"
  local lower="${raw,,}"
  [[ "${lower}" == *"<usewpf>true</usewpf>"* || "${lower}" == *"<usewindowsforms>true</usewindowsforms>"* ]]
}

get_global_json_sdk_major() {
  local path="${workspace_root}/global.json"
  [[ -f "${path}" ]] || return 0
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9][0-9]*\)\..*/\1/p' "${path}" | head -n1
}

framework_major() {
  local framework="${1:-}"
  if [[ "${framework}" =~ ^net([0-9]+)\.[0-9]+ ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
}

resolve_required_sdk_major() {
  local global_major
  global_major="$(get_global_json_sdk_major || true)"
  if [[ -n "${global_major}" ]]; then
    echo "${global_major}"
    return 0
  fi

  local highest=0
  local framework major
  for framework in "${all_frameworks[@]:-}"; do
    major="$(framework_major "${framework}")"
    [[ -z "${major}" ]] && continue
    if (( major > highest )); then
      highest="${major}"
    fi
  done
  if (( highest > 0 )); then
    echo "${highest}"
  fi
}

resolve_dotnet_channel() {
  local major="${1:-}"
  if [[ -n "${major}" ]]; then
    echo "${major}.0"
    return 0
  fi
  if [[ -n "${RAYMAN_DOTNET_CHANNEL:-}" ]]; then
    echo "${RAYMAN_DOTNET_CHANNEL}"
    return 0
  fi
  echo "LTS"
}

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

list_installed_dotnet_sdk_majors() {
  has_cmd dotnet || return 0
  dotnet --list-sdks 2>/dev/null | sed -n 's/^[[:space:]]*\([0-9][0-9]*\)\..*/\1/p' | sort -u
}

dotnet_sdk_ready() {
  local required_major="${1:-}"
  has_cmd dotnet || return 1
  if [[ -z "${required_major}" ]]; then
    return 0
  fi
  local major
  while IFS= read -r major; do
    [[ "${major}" == "${required_major}" ]] && return 0
  done < <(list_installed_dotnet_sdk_majors)
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

install_dotnet_local() {
  local channel="$1"
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

run_dotnet_workload_restore_local() {
  local project rc=0
  for project in "${maui_projects[@]:-}"; do
    info "restoring MAUI workloads for ${project}"
    if ! dotnet workload restore "${project}"; then
      rc=1
    fi
  done
  return "${rc}"
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

need_dotnet=0
need_node=0
need_python=0
need_windows_desktop=0
is_maui=0
declare -a dotnet_projects=()
declare -a maui_projects=()
declare -a all_frameworks=()

while IFS= read -r -d '' f; do
  name="$(basename "$f")"
  case "$name" in
    *.sln|*.slnx|*.csproj|*.fsproj|*.vbproj)
      need_dotnet=1
      dotnet_projects+=("$f")
      if [[ "$name" == *.csproj ]]; then
        if detect_windows_desktop "$f"; then
          need_windows_desktop=1
        fi
        while IFS= read -r framework; do
          [[ -z "${framework}" ]] && continue
          if [[ ! " ${all_frameworks[*]} " =~ [[:space:]]${framework}[[:space:]] ]]; then
            all_frameworks+=("${framework}")
          fi
        done < <(extract_target_frameworks_from_csproj "$f")
        if detect_use_maui "$f"; then
          is_maui=1
          maui_projects+=("$f")
        fi
      fi
      ;;
    package.json) need_node=1 ;;
    pyproject.toml|requirements.txt) need_python=1 ;;
  esac
done < <(find . -type f \( -name '*.sln' -o -name '*.slnx' -o -name '*.csproj' -o -name '*.fsproj' -o -name '*.vbproj' -o -name 'package.json' -o -name 'pyproject.toml' -o -name 'requirements.txt' \) \
  -not -path './.git/*' -not -path './.Rayman/*' -not -path './.venv/*' -not -path './node_modules/*' -not -path './bin/*' -not -path './obj/*' -print0)

required_sdk_major="$(resolve_required_sdk_major || true)"
dotnet_channel="$(resolve_dotnet_channel "${required_sdk_major}")"

if ! has_kind_enabled "${only_kinds}" "dotnet"; then
  need_dotnet=0
fi
if ! has_kind_enabled "${only_kinds}" "node"; then
  need_node=0
fi
if ! has_kind_enabled "${only_kinds}" "python"; then
  need_python=0
fi

info "detected deps: dotnet=${need_dotnet}, node=${need_node}, python=${need_python}, windowsDesktop=${need_windows_desktop}, maui=${is_maui}, sdkMajor=${required_sdk_major:-none}"
if [[ -n "${only_kinds}" ]]; then
  info "dependency filter enabled: only=${only_kinds}"
fi

if [[ "${need_dotnet}" == "1" && "${windows_preferred}" == "1" ]]; then
  detect_windows_bridge
  info "dotnet host strategy: windowsPreferred=1 strict=${windows_strict} bridgeReady=${BRIDGE_READY} reason=${BRIDGE_REASON}"
fi

missing=()

if [[ "${need_dotnet}" == "1" ]]; then
  dotnet_ready=0
  bridge_dotnet_completed=0
  if dotnet_probe; then
    if dotnet_sdk_ready "${required_sdk_major}"; then
      dotnet_ready=1
      info "dotnet executable probe passed"
    else
      warn "dotnet is present but required SDK major is missing (${required_sdk_major:-unspecified}); installed=$(list_installed_dotnet_sdk_majors | tr '\n' ',' | sed 's/,$//')"
    fi
  else
    warn "dotnet probe failed (${DOTNET_PROBE_REASON})"
    if [[ -n "${DOTNET_PROBE_OUTPUT}" ]]; then
      warn "dotnet probe output: $(echo "${DOTNET_PROBE_OUTPUT}" | tr '\n' ' ' | cut -c1-400)"
    fi
  fi

  if [[ "${is_maui}" == "1" && "${auto_install}" == "1" && "${windows_preferred}" == "1" && "${BRIDGE_READY}" == "1" ]]; then
    info "MAUI project detected; preferring Windows host dependency flow for workload restore"
    if invoke_windows_dotnet_deps; then
      info "Windows bridge dependency check succeeded"
      dotnet_ready=1
      bridge_dotnet_completed=1
    else
      if [[ "${windows_strict}" == "1" ]]; then
        echo "[test-deps] windows bridge dependency check failed and strict mode enabled" >&2
        exit 2
      fi
      warn "Windows bridge dependency check failed; fallback to local dependency flow"
    fi
  elif [[ "${dotnet_ready}" == "0" && "${windows_preferred}" == "1" && "${BRIDGE_READY}" == "1" ]]; then
    info "dotnet missing/unrunnable in WSL; trying Windows bridge ensure_project_test_deps.ps1"
    if invoke_windows_dotnet_deps; then
      info "Windows bridge dependency check succeeded"
      dotnet_ready=1
      bridge_dotnet_completed=1
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
      install_dotnet_local "${dotnet_channel}" || true
    fi
    if dotnet_probe && dotnet_sdk_ready "${required_sdk_major}"; then
      dotnet_ready=1
      info "dotnet executable probe passed after Linux fallback install"
    fi
  fi

  if [[ "${dotnet_ready}" == "0" ]]; then
    if [[ -n "${required_sdk_major}" ]]; then
      missing+=("dotnet-sdk-${required_sdk_major}")
    else
      missing+=(dotnet)
    fi
  elif [[ "${is_maui}" == "1" && "${auto_install}" == "1" && "${bridge_dotnet_completed}" == "0" ]]; then
    if ! run_dotnet_workload_restore_local; then
      if [[ "${require_deps}" == "1" ]]; then
        echo "[test-deps] failed to restore MAUI workloads: ${maui_projects[*]}" >&2
        exit 2
      fi
      warn "failed to restore MAUI workloads: ${maui_projects[*]}"
    fi
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
