#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

interval="${RAYMAN_WATCH_INTERVAL_SECONDS:-15}"
once="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once) once="1" ;;
    --interval)
      shift || { echo "missing value for --interval" >&2; exit 2; }
      interval="${1:-15}"
      ;;
    *)
      echo "[rayman-watch] unknown arg: $1" >&2
      exit 2
      ;;
  esac
  shift || true
done

run_cycle() {
  echo "[rayman-watch] fast-init (only new)"
  bash ./.Rayman/scripts/fast-init/fast-init.sh --only-new || true
  echo "[rayman-watch] process prompts"
  bash ./.Rayman/scripts/requirements/process_prompts.sh
}

if [[ "${once}" == "1" ]]; then
  run_cycle
  exit 0
fi

echo "[rayman-watch] started (interval=${interval}s)"
while true; do
  run_cycle
  sleep "${interval}"
done
