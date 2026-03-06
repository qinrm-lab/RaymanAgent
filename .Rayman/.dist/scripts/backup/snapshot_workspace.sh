#!/usr/bin/env bash
set -euo pipefail

workspace_root="$(pwd)"
reason="manual"
keep="${RAYMAN_SNAPSHOT_KEEP:-5}"

usage() {
  cat <<'TXT'
Usage:
  bash ./.Rayman/scripts/backup/snapshot_workspace.sh [options]

Options:
  --workspace-root DIR   workspace root (default: current directory)
  --reason TEXT          snapshot trigger reason (default: manual)
  --keep N               keep newest N snapshot archives (default: env RAYMAN_SNAPSHOT_KEEP or 5)
TXT
}

is_uint(){ [[ "${1:-}" =~ ^[0-9]+$ ]]; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-root) workspace_root="${2:-}"; shift 2 ;;
    --reason) reason="${2:-manual}"; shift 2 ;;
    --keep) keep="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[rayman-snapshot] unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

is_uint "${keep}" || { echo "[rayman-snapshot] keep must be >= 0" >&2; exit 2; }

workspace_root="$(cd "${workspace_root}" && pwd)"
snapshot_dir="${workspace_root}/.Rayman/runtime/snapshots"
mkdir -p "${snapshot_dir}"

ts="$(date +%Y%m%dT%H%M%S)"
reason_slug="$(printf '%s' "${reason}" | tr -cs 'A-Za-z0-9._-' '_' | sed 's/^_//;s/_$//')"
[[ -z "${reason_slug}" ]] && reason_slug="manual"
base="snapshot-${ts}-${reason_slug}"
archive="${snapshot_dir}/${base}.tar.gz"
manifest="${snapshot_dir}/${base}.manifest.json"

excludes=(
  ".Rayman/runtime/snapshots"
  ".Rayman/runtime/tmp"
  ".Rayman/runtime/artifacts"
  ".Rayman/logs"
  ".Rayman/state/chroma_db"
  ".Rayman/state/rag.db"
  ".venv"
  ".rag"
  ".tmp_sandbox_verify_*"
  ".tmp_sandbox_verify_clean_*"
  ".Rayman_full_for_copy"
  "Rayman_full_bundle"
)

includes=(
  ".Rayman"
  "AGENTS.md"
  "agents.md"
  ".SolutionName"
)

if [[ -f "${workspace_root}/.SolutionName" ]]; then
  sol_name="$(tr -d '\r' < "${workspace_root}/.SolutionName" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -n 1)"
  if [[ -n "${sol_name}" && -d "${workspace_root}/.${sol_name}" ]]; then
    includes+=(".${sol_name}")
  fi
fi

if ! command -v tar >/dev/null 2>&1; then
  echo "[rayman-snapshot] tar is required" >&2
  exit 2
fi

args=()
for ex in "${excludes[@]}"; do
  args+=("--exclude=${ex}")
done
existing_includes=()
for in_path in "${includes[@]}"; do
  if [[ -e "${workspace_root}/${in_path}" ]]; then
    existing_includes+=("${in_path}")
  fi
done
if [[ "${#existing_includes[@]}" -eq 0 ]]; then
  echo "[rayman-snapshot] nothing to snapshot under ${workspace_root}" >&2
  exit 2
fi

(
  cd "${workspace_root}"
  tar -czf "${archive}" "${args[@]}" "${existing_includes[@]}"
)

{
  printf '{\"schema\":\"rayman.snapshot.v1\",\"generated_at\":\"%s\",\"reason\":\"%s\",\"workspace_root\":\"%s\",\"archive\":\"%s\",\"exclude\":[' \
    "$(date -Iseconds)" "${reason}" "${workspace_root}" "${archive}"
  for i in "${!excludes[@]}"; do
    [[ "$i" -gt 0 ]] && printf ','
    printf '\"%s\"' "${excludes[$i]}"
  done
  printf '],\"include\":['
  for i in "${!existing_includes[@]}"; do
    [[ "$i" -gt 0 ]] && printf ','
    printf '\"%s\"' "${existing_includes[$i]}"
  done
  printf ']}\n'
} > "${manifest}"

if [[ "${keep}" -ge 0 ]]; then
  mapfile -t archives < <(ls -1t "${snapshot_dir}"/snapshot-*.tar.gz 2>/dev/null || true)
  if [[ "${#archives[@]}" -gt "${keep}" ]]; then
    for old in "${archives[@]:${keep}}"; do
      rm -f "${old}"
      old_manifest="${old%.tar.gz}.manifest.json"
      rm -f "${old_manifest}" 2>/dev/null || true
    done
  fi
fi

echo "[rayman-snapshot] archive=${archive}"
echo "[rayman-snapshot] manifest=${manifest}"
