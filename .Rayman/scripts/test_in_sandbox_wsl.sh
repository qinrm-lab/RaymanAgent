#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RAYMAN_DIR="$ROOT/.Rayman"
SANDBOX="$RAYMAN_DIR/run/sandbox/workspace"
LOG="$RAYMAN_DIR/run/sandbox/test.log"
CMD="${1:-dotnet test}"
DEPS_SCRIPT="$RAYMAN_DIR/scripts/utils/ensure_project_test_deps.sh"
AUTO_INSTALL="${RAYMAN_AUTO_INSTALL_TEST_DEPS:-1}"
REQUIRE_DEPS="${RAYMAN_REQUIRE_TEST_DEPS:-1}"

mkdir -p "$SANDBOX"
{
  echo "[sandbox] WorkspaceRoot=$ROOT"
  echo "[sandbox] Command=$CMD"
} > "$LOG"

if [[ -f "$DEPS_SCRIPT" ]]; then
  {
    echo "[sandbox] EnsureTestDeps autoInstall=$AUTO_INSTALL require=$REQUIRE_DEPS"
  } | tee -a "$LOG"
  set +e
  bash "$DEPS_SCRIPT" --workspace-root "$ROOT" --auto-install "$AUTO_INSTALL" --require "$REQUIRE_DEPS" 2>&1 | tee -a "$LOG"
  deps_rc=${PIPESTATUS[0]}
  set -e
  if [[ $deps_rc -ne 0 ]]; then
    echo "[sandbox] dependency ensure failed (rc=$deps_rc)" | tee -a "$LOG" >&2
    exit "$deps_rc"
  fi
fi

pushd "$SANDBOX" >/dev/null
set +e
bash -lc "$CMD" 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
set -e
popd >/dev/null
exit $rc
