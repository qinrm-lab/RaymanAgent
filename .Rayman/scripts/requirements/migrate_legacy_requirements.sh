#!/usr/bin/env bash
set -euo pipefail
if [[ "${RAYMAN_DEBUG:-0}" == "1" ]]; then set -x; fi

ROOT="$(pwd)"
SOL="$(bash ./.Rayman/scripts/requirements/detect_solution.sh)"
SOL_DIR=".${SOL}"

STAMP_FILE=".Rayman/runtime/migration.done"
BACKUP_DIR=".Rayman/runtime/migration/backup"
MAP_FILE=".Rayman/runtime/migration/map.json"

mkdir -p "$(dirname "$STAMP_FILE")" "$BACKUP_DIR"

# Skip repeated migration unless forced.
if [[ -f "$STAMP_FILE" && "${RAYMAN_FORCE_MIGRATE:-0}" != "1" ]]; then
  exit 0
fi

rows_file="$(mktemp)"
trap 'rm -f "$rows_file"' EXIT

hash_file() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$f" <<'PY'
import hashlib,sys
p=sys.argv[1]
h=hashlib.sha256()
with open(p,'rb') as fp:
    h.update(fp.read())
print(h.hexdigest())
PY
  elif command -v python >/dev/null 2>&1; then
    python - "$f" <<'PY'
import hashlib,sys
p=sys.argv[1]
h=hashlib.sha256()
with open(p,'rb') as fp:
    h.update(fp.read())
print(h.hexdigest())
PY
  else
    echo "nohash"
  fi
}

backup_one() {
  local src="$1"
  local rel="${src#./}"
  local dst="$BACKUP_DIR/$rel"
  mkdir -p "$(dirname "$dst")"
  cp -f "$src" "$dst"
}

remove_legacy_source() {
  local src="$1"
  [[ -f "$src" ]] || return 0
  rm -f "$src"
}

append_section_header_if_missing() {
  local target="$1"
  if ! grep -q '^## 遗留 requirements 迁移（自动）' "$target" 2>/dev/null; then
    {
      echo
      echo '## 遗留 requirements 迁移（自动）'
      echo
      echo '> 说明：以下内容由 Rayman 自动从旧目录结构迁移合并而来，用于保留历史约束与验收信息。'
      echo '> 原文件会被备份到 .Rayman/runtime/migration/backup/ 下。'
      echo
    } >> "$target"
  fi
}

append_legacy_block() {
  local target="$1"
  local source_abs="$2"
  local source_rel="$3"
  local hash="$4"

  if grep -q "RAYMAN:LEGACY_MIGRATION:BEGIN.*source=\"${source_rel}\"" "$target" 2>/dev/null; then
    return 0
  fi

  append_section_header_if_missing "$target"
  {
    echo "<!-- RAYMAN:LEGACY_MIGRATION:BEGIN source=\"${source_rel}\" hash=\"${hash}\" -->"
    echo
    sed -e 's/\r$//' "$source_abs"
    echo
    echo '<!-- RAYMAN:LEGACY_MIGRATION:END -->'
    echo
  } >> "$target"
}

record_row() {
  local project="$1"
  local src_rel="$2"
  local target_rel="$3"
  local hash="$4"
  printf '%s\t%s\t%s\t%s\n' "$project" "$src_rel" "$target_rel" "$hash" >> "$rows_file"
}

legacy_sol_req="./.${SOL}.requirements.md"
new_sol_req="${SOL_DIR}/.${SOL}.requirements.md"

if [[ -f "$legacy_sol_req" && "$legacy_sol_req" != "$new_sol_req" ]]; then
  mkdir -p "$SOL_DIR"
  backup_one "$legacy_sol_req"
  h="$(hash_file "$legacy_sol_req")"

  if [[ ! -f "$new_sol_req" ]]; then
    cp -f "$legacy_sol_req" "$new_sol_req"
  else
    append_legacy_block "$new_sol_req" "$legacy_sol_req" "${legacy_sol_req#./}" "$h"
  fi

  record_row "__SOLUTION__" "${legacy_sol_req#./}" "${new_sol_req#./}" "$h"
  remove_legacy_source "$legacy_sol_req"
fi

mapfile -t PROJS < <(bash ./.Rayman/scripts/requirements/detect_projects.sh || true)
for p in "${PROJS[@]}"; do
  pf="${SOL_DIR}/.${p}/.${p}.requirements.md"
  [[ -f "$pf" ]] || continue

  declare -A seen=()
  candidates=()

  root_legacy="./.${p}.requirements.md"
  if [[ -f "$root_legacy" && "$root_legacy" != "./${pf#./}" ]]; then
    candidates+=("$root_legacy")
  fi

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ "$f" == "./${pf#./}" ]] && continue
    [[ "$f" == ./.Rayman/* ]] && continue
    [[ "$f" == ./${SOL_DIR}/* ]] && continue
    candidates+=("$f")
  done < <(find . -maxdepth 6 -type f -name ".${p}.requirements.md" | sort -u)

  for src in "${candidates[@]}"; do
    [[ -z "$src" ]] && continue
    if [[ -n "${seen[$src]+x}" ]]; then
      continue
    fi
    seen[$src]=1

    backup_one "$src"
    h="$(hash_file "$src")"
    append_legacy_block "$pf" "$src" "${src#./}" "$h"
    record_row "$p" "${src#./}" "${pf#./}" "$h"
    remove_legacy_source "$src"
  done

done

if command -v python3 >/dev/null 2>&1; then
  pybin=python3
elif command -v python >/dev/null 2>&1; then
  pybin=python
else
  pybin=
fi

if [[ -n "$pybin" ]]; then
  "$pybin" - "$rows_file" "$MAP_FILE" <<'PY'
import json
import os
import sys

rows_file = sys.argv[1]
map_file = sys.argv[2]
entries = []

with open(rows_file, 'r', encoding='utf-8') as f:
    for line in f:
        line = line.rstrip('\n')
        if not line:
            continue
        parts = line.split('\t')
        if len(parts) != 4:
            continue
        project, source, target, sha = parts
        entries.append({
            "project": project,
            "source": source,
            "target": target,
            "sha256": sha,
        })

os.makedirs(os.path.dirname(map_file), exist_ok=True)
with open(map_file, 'w', encoding='utf-8') as f:
    json.dump({"version": "v1", "entries": entries}, f, ensure_ascii=False, indent=2)
PY
else
  mkdir -p "$(dirname "$MAP_FILE")"
  cat > "$MAP_FILE" <<'JSON'
{
  "version": "v1",
  "entries": []
}
JSON
fi

date -u +"%Y-%m-%dT%H:%M:%SZ" > "$STAMP_FILE"

if [[ "${RAYMAN_QUIET:-0}" != "1" ]]; then
  count="$(wc -l < "$rows_file" | tr -d ' ')"
  if [[ "$count" -gt 0 ]]; then
    echo "[migrate] merged legacy requirements into new structure: ${count} files"
    echo "[migrate] backup dir: $BACKUP_DIR"
  else
    echo "[migrate] no legacy requirements found"
  fi
fi
