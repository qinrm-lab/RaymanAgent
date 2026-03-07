#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

cmd="${1:-doctor}"
shift || true

case "${cmd}" in
  doctor)
    bash ./.Rayman/run/doctor.sh "$@"
    ;;
  check|release)
    bash ./.Rayman/run/check.sh "$@"
    ;;
  dev)
    bash ./.Rayman/scripts/fast-init/fast-init.sh --only-new
    bash ./.Rayman/scripts/requirements/process_prompts.sh
    ;;
  *)
    echo "[rayman-rules] unknown profile: ${cmd}" >&2
    exit 2
    ;;
esac
