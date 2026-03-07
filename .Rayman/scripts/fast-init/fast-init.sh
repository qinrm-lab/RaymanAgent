#!/usr/bin/env bash
set -euo pipefail
if [[ "${RAYMAN_DEBUG:-0}" == "1" ]]; then set -x; fi

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

snapshot_file=".Rayman/runtime/projects.snapshot.txt"
mkdir -p "$(dirname "$snapshot_file")"

list_projects() {
  bash ./.Rayman/scripts/requirements/detect_projects.sh | sed 's/\r$//' | sort -u
}

save_snapshot() {
  list_projects > "$snapshot_file"
}

only_new=0
for a in "$@"; do
  if [[ "$a" == "--only-new" ]]; then only_new=1; fi
  if [[ "$a" == "--force" ]]; then rm -f "$snapshot_file"; fi
done

tmp_new="$(mktemp)"
trap 'rm -f "$tmp_new"' EXIT

if [[ $only_new -eq 1 && -f "$snapshot_file" ]]; then
  comm -13 "$snapshot_file" <(list_projects) > "$tmp_new" || true
else
  list_projects > "$tmp_new"
fi

if [[ ! -s "$tmp_new" ]]; then
  echo "[fast-init] no new projects"
  save_snapshot
  exit 0
fi

echo "[fast-init] new projects:" 
cat "$tmp_new" | sed 's/^/  - /'

# Ensure requirements exist (idempotent; does NOT install any deps)
bash ./.Rayman/scripts/requirements/ensure_requirements.sh

# Snapshot update
save_snapshot

echo "[fast-init] done"
