#!/usr/bin/env bash
set -euo pipefail
f=".Rayman/runtime/issues.open.md"
if [[ ! -f "$f" ]]; then
  echo "OK"; exit 0
fi
if grep -qE '^- \[ \]' "$f"; then
  echo "FAIL" >&2
  echo "[issues] 未闭环问题：" >&2
  grep -nE '^- \[ \]' "$f" >&2 || true
  exit 2
fi
echo "OK"
