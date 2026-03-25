#!/usr/bin/env bash
set -euo pipefail

workspace_root=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-root)
      workspace_root="${2:-}"
      shift 2
      ;;
    *)
      echo "[workspace-state] unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "${workspace_root}" ]]; then
  workspace_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
else
  workspace_root="$(cd "${workspace_root}" && pwd)"
fi

path_cmp() {
  local value="${1:-}"
  value="${value#Microsoft.PowerShell.Core\FileSystem::}"
  value="${value//\\//}"
  value="${value%/}"
  printf '%s' "${value}" | tr '[:upper:]' '[:lower:]'
}

extract_workspace_root() {
  local path="$1"
  [[ -f "${path}" ]] || return 0
  tr -d '\r' < "${path}" | sed -n 's/.*"workspace_root"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

marker_path="${workspace_root}/.Rayman/runtime/workspace.marker.json"
foreign_root=""

probe_files=(
  "${marker_path}"
  "${workspace_root}/.Rayman/runtime/agent_capabilities.report.json"
  "${workspace_root}/.Rayman/runtime/dotnet.exec.last.json"
  "${workspace_root}/.Rayman/runtime/playwright.ready.windows.json"
  "${workspace_root}/.Rayman/runtime/winapp.ready.windows.json"
  "${workspace_root}/.Rayman/runtime/test_lanes/host_smoke.report.json"
  "${workspace_root}/.Rayman/runtime/project_gates/fast.report.json"
  "${workspace_root}/.Rayman/runtime/project_gates/browser.report.json"
)

workspace_norm="$(path_cmp "${workspace_root}")"
for probe in "${probe_files[@]}"; do
  report_root="$(extract_workspace_root "${probe}")"
  [[ -n "${report_root}" ]] || continue
  report_norm="$(path_cmp "${report_root}")"
  if [[ -n "${report_norm}" && "${report_norm}" != "${workspace_norm}" ]]; then
    foreign_root="${report_root}"
    break
  fi
done

removed=0
if [[ -n "${foreign_root}" ]]; then
  for dir_path in \
    "${workspace_root}/.Rayman/logs" \
    "${workspace_root}/.Rayman/runtime/test_lanes" \
    "${workspace_root}/.Rayman/runtime/project_gates" \
    "${workspace_root}/.Rayman/runtime/mcp" \
    "${workspace_root}/.Rayman/runtime/pwa-tests" \
    "${workspace_root}/.Rayman/runtime/winapp-tests" \
    "${workspace_root}/.Rayman/runtime/memory" \
    "${workspace_root}/.rag"; do
    if [[ -e "${dir_path}" ]]; then
      rm -rf "${dir_path}"
      removed=$((removed + 1))
    fi
  done

  while IFS= read -r -d '' file_path; do
    rm -f "${file_path}"
    removed=$((removed + 1))
  done < <(find "${workspace_root}/.Rayman/runtime" -type f \( -name '*ready*.json' -o -name 'agent_capabilities.report.*' -o -name 'proxy.resolved.json' -o -name 'dotnet.exec.last.json' \) -print0 2>/dev/null || true)

  while IFS= read -r -d '' file_path; do
    rm -f "${file_path}"
    removed=$((removed + 1))
  done < <(find "${workspace_root}/.Rayman/state" -maxdepth 1 -type f \( -name 'release_gate_report.*' -o -name 'diagnostics_*' -o -name 'last_*' \) -print0 2>/dev/null || true)

  for legacy_path in \
    "${workspace_root}/.Rayman/state/chroma_db" \
    "${workspace_root}/.Rayman/state/rag.db"; do
    if [[ -e "${legacy_path}" ]]; then
      rm -rf "${legacy_path}"
      removed=$((removed + 1))
    fi
  done

  if [[ -d "${workspace_root}/.Rayman/state/memory" ]]; then
    while IFS= read -r -d '' entry_path; do
      rm -rf "${entry_path}"
      removed=$((removed + 1))
    done < <(find "${workspace_root}/.Rayman/state/memory" -mindepth 1 -maxdepth 1 -print0 2>/dev/null || true)
  fi
fi

mkdir -p "$(dirname "${marker_path}")"
version_path="${workspace_root}/.Rayman/VERSION"
rayman_version=""
if [[ -f "${version_path}" ]]; then
  rayman_version="$(tr -d '\r' < "${version_path}" | head -n1)"
fi

cat > "${marker_path}" <<JSON
{
  "schema": "rayman.workspace.marker.v1",
  "workspace_root": "${workspace_root//\\/\\\\}",
  "written_at": "$(date -Iseconds)",
  "rayman_version": "${rayman_version//\\/\\\\}"
}
JSON

if [[ -n "${foreign_root}" ]]; then
  echo "[workspace-state] detected cross-workspace copy from ${foreign_root}; removed=${removed}"
else
  echo "[workspace-state] current workspace marker refreshed: ${marker_path}"
fi
