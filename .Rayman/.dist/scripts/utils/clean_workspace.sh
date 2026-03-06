#!/usr/bin/env bash
set -euo pipefail

workspace_root="$(pwd)"
keep_days="${RAYMAN_CLEAN_KEEP_DAYS:-14}"
dry_run="${RAYMAN_CLEAN_DRY_RUN:-1}"
aggressive="${RAYMAN_CLEAN_AGGRESSIVE:-0}"
copy_smoke_artifacts="${RAYMAN_CLEAN_COPY_SMOKE_ARTIFACTS:-0}"

usage() {
  cat <<'TXT'
Usage:
  bash ./.Rayman/scripts/utils/clean_workspace.sh [options]

Options:
  --workspace-root DIR   workspace root (default: current directory)
  --keep-days N          delete entries older than N days (default: env RAYMAN_CLEAN_KEEP_DAYS or 14)
  --dry-run 0|1          print plan without deleting (default: env RAYMAN_CLEAN_DRY_RUN or 1)
  --aggressive 0|1       also clean .Rayman_full_for_copy and Rayman_full_bundle (default: env RAYMAN_CLEAN_AGGRESSIVE or 0)
  --copy-smoke-artifacts 0|1  also clean /tmp/rayman_copy_smoke_* (default: env RAYMAN_CLEAN_COPY_SMOKE_ARTIFACTS or 0)
TXT
}

is_uint(){ [[ "${1:-}" =~ ^[0-9]+$ ]]; }
is_flag(){ [[ "${1:-}" == "0" || "${1:-}" == "1" ]]; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-root) workspace_root="${2:-}"; shift 2 ;;
    --keep-days) keep_days="${2:-}"; shift 2 ;;
    --dry-run) dry_run="${2:-}"; shift 2 ;;
    --aggressive) aggressive="${2:-}"; shift 2 ;;
    --copy-smoke-artifacts) copy_smoke_artifacts="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[rayman-clean] unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

is_uint "${keep_days}" || { echo "[rayman-clean] keep-days must be >= 0" >&2; exit 2; }
is_flag "${dry_run}" || { echo "[rayman-clean] dry-run must be 0 or 1" >&2; exit 2; }
is_flag "${aggressive}" || { echo "[rayman-clean] aggressive must be 0 or 1" >&2; exit 2; }
is_flag "${copy_smoke_artifacts}" || { echo "[rayman-clean] copy-smoke-artifacts must be 0 or 1" >&2; exit 2; }

workspace_root="$(cd "${workspace_root}" && pwd)"
now_epoch="$(date +%s)"

should_delete_path() {
  local p="$1"
  if [[ ! -e "$p" ]]; then
    return 1
  fi
  if [[ "${keep_days}" -eq 0 ]]; then
    return 0
  fi

  local mtime
  mtime="$(stat -c %Y "$p" 2>/dev/null || true)"
  if [[ -z "${mtime}" || ! "${mtime}" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  local age_days
  age_days=$(( (now_epoch - mtime) / 86400 ))
  [[ "${age_days}" -ge "${keep_days}" ]]
}

declare -a candidates=()

add_candidate() {
  local p="$1"
  [[ -e "$p" ]] || return 0
  if should_delete_path "$p"; then
    candidates+=("$p")
  fi
}

# root sandbox verification dirs
for d in "${workspace_root}"/.tmp_sandbox_verify_* "${workspace_root}"/.tmp_sandbox_verify_clean_*; do
  [[ -e "$d" ]] || continue
  add_candidate "$d"
done

# runtime tmp entries
runtime_tmp_dir="${workspace_root}/.Rayman/runtime/tmp"
if [[ -d "${runtime_tmp_dir}" ]]; then
  while IFS= read -r -d '' item; do
    add_candidate "$item"
  done < <(find "${runtime_tmp_dir}" -mindepth 1 -maxdepth 1 -print0)
fi

# telemetry test bundles
telemetry_dir="${workspace_root}/.Rayman/runtime/artifacts/telemetry"
if [[ -d "${telemetry_dir}" ]]; then
  while IFS= read -r -d '' item; do
    add_candidate "$item"
  done < <(find "${telemetry_dir}" -mindepth 1 -maxdepth 1 -type d -name 'test-bundle*' -print0)
fi

if [[ "${aggressive}" == "1" ]]; then
  add_candidate "${workspace_root}/.Rayman_full_for_copy"
  add_candidate "${workspace_root}/Rayman_full_bundle"
fi

if [[ "${copy_smoke_artifacts}" == "1" ]]; then
  tmp_root="${TMPDIR:-/tmp}"
  if [[ -d "${tmp_root}" ]]; then
    while IFS= read -r -d '' item; do
      add_candidate "$item"
    done < <(find "${tmp_root}" -mindepth 1 -maxdepth 1 -type d -name 'rayman_copy_smoke_*' -print0 2>/dev/null)
  fi
fi

# de-duplicate
if [[ "${#candidates[@]}" -gt 0 ]]; then
  mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | awk '!seen[$0]++')
fi

if [[ "${#candidates[@]}" -eq 0 ]]; then
  echo "[rayman-clean] no entries matched (keep_days=${keep_days}, aggressive=${aggressive}, copy_smoke_artifacts=${copy_smoke_artifacts})"
  exit 0
fi

echo "[rayman-clean] workspace=${workspace_root}"
echo "[rayman-clean] keep_days=${keep_days} dry_run=${dry_run} aggressive=${aggressive} copy_smoke_artifacts=${copy_smoke_artifacts}"
for p in "${candidates[@]}"; do
  rel="${p#${workspace_root}/}"
  if [[ "${rel}" == "${p}" ]]; then rel="$p"; fi
  echo "[rayman-clean] candidate: ${rel}"
done

if [[ "${dry_run}" == "1" ]]; then
  echo "[rayman-clean] dry-run only; no deletion executed"
  exit 0
fi

removed=0
for p in "${candidates[@]}"; do
  if [[ -e "$p" ]]; then
    rm -rf "$p"
    removed=$((removed + 1))
  fi
done

echo "[rayman-clean] removed=${removed}"
