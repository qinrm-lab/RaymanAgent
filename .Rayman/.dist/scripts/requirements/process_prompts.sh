#!/usr/bin/env bash
set -euo pipefail
if [[ "${RAYMAN_DEBUG:-0}" == "1" ]]; then set -x; fi

INBOX=".Rayman/context/prompt.inbox.md"
CODEX=".Rayman/codex_fix_prompt.txt"
STATE=".Rayman/runtime/prompt.state"

hash_file(){ sha1sum "$1" | awk '{print $1}'; }

process_file(){
  local f="$1"
  [[ -f "$f" && -s "$f" ]] || return 0
  local h key old
  h="$(hash_file "$f")"
  key="$(echo "$f" | tr '/' '_')"
  old=""
  [[ -f "$STATE" ]] && old="$(grep -E "^${key}=" "$STATE" | head -n1 | cut -d= -f2- || true)"
  [[ "$h" == "$old" ]] && return 0

  echo "[prompt] detect change: $f"

  set +e
  bash ./.Rayman/scripts/requirements/update_from_prompt.sh "$f"
  rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    echo "[prompt][error] requirements sync failed (rc=${rc}); prompt state NOT updated; fix the prompt and retry" >&2
    return "${rc}"
  fi

  mkdir -p "$(dirname "$STATE")"
  touch "$STATE"
  grep -Ev "^${key}=" "$STATE" > "${STATE}.tmp" || true
  echo "${key}=${h}" >> "${STATE}.tmp"
  mv "${STATE}.tmp" "$STATE"
}

process_file "$INBOX"

if [[ -f "$CODEX" ]] && grep -q "RAYMAN:USER_PROMPT:BEGIN" "$CODEX"; then
  tmp="$(mktemp)"
  awk '
    /RAYMAN:USER_PROMPT:BEGIN/{f=1;next}
    /RAYMAN:USER_PROMPT:END/{f=0}
    f{print}
  ' "$CODEX" > "$tmp"
  if [[ -s "$tmp" ]]; then process_file "$tmp"; fi
  rm -f "$tmp"
fi
