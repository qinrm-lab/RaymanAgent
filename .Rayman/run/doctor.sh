#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

echo "[rayman-doctor] validate requirements layout"
bash ./.Rayman/scripts/ci/validate_requirements.sh

echo "[rayman-doctor] checklist"
bash ./.Rayman/scripts/release/checklist.sh

echo "[rayman-doctor] regression guard"
bash ./.Rayman/scripts/release/regression_guard.sh

echo "[rayman-doctor] config sanity"
bash ./.Rayman/scripts/release/config_sanity.sh

echo "[rayman-doctor] OK"
