#!/usr/bin/env bash
set -euo pipefail

missing=()

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

for cmd in pwsh git notify-send espeak-ng; do
  if ! have_cmd "$cmd"; then
    missing+=("$cmd")
  fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
  echo "[rayman] WSL deps check passed"
  exit 0
fi

echo "[rayman] WSL deps missing: ${missing[*]}" >&2
echo "[rayman] hint: run '.Rayman/rayman.ps1 ensure-wsl-deps' or task 'Rayman: Ensure WSL Deps'" >&2
exit 2
