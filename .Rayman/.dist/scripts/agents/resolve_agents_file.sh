#!/usr/bin/env bash
set -euo pipefail

canonical="AGENTS.md"
legacy="agents.md"
canonicalize=0
require_existing=0

usage() {
  cat <<'TXT'
Usage:
  bash ./.Rayman/scripts/agents/resolve_agents_file.sh [--canonicalize] [--require-existing]

Outputs:
  Prints the resolved agents file path.

Rules:
  - Canonical file is AGENTS.md
  - agents.md is legacy-compatible
  - If both exist and contents differ, fail-fast
TXT
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --canonicalize) canonicalize=1; shift ;;
    --require-existing) require_existing=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[agents] unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -f "${canonical}" && -f "${legacy}" ]]; then
  if ! cmp -s "${canonical}" "${legacy}"; then
    echo "[agents] conflict: both AGENTS.md and agents.md exist but differ" >&2
    exit 2
  fi
  echo "${canonical}"
  exit 0
fi

if [[ -f "${canonical}" ]]; then
  echo "${canonical}"
  exit 0
fi

if [[ -f "${legacy}" ]]; then
  if [[ "${canonicalize}" == "1" ]]; then
    # Case-safe rename (works on case-insensitive filesystems too).
    tmp="${legacy}.rayman.tmp.$$"
    mv "${legacy}" "${tmp}"
    mv "${tmp}" "${canonical}"
    echo "${canonical}"
    exit 0
  fi
  echo "${legacy}"
  exit 0
fi

if [[ "${require_existing}" == "1" ]]; then
  echo "[agents] missing agents file: AGENTS.md/agents.md" >&2
  exit 2
fi

echo "${canonical}"
