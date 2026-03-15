#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_DIR="${ROOT}/.Rayman/scripts/testing/bats"
RUNTIME_DIR="${ROOT}/.Rayman/runtime/test_lanes"
LOG_PATH="${RUNTIME_DIR}/bats.log"
REPORT_PATH="${RUNTIME_DIR}/bats.report.json"
JUNIT_PATH="${RUNTIME_DIR}/bats.junit.xml"

mkdir -p "${RUNTIME_DIR}"

if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
else
  echo "[rayman-bats] python/python3 not found. Cannot write JSON report." >&2
  exit 2
fi

write_report() {
  local success="$1"
  local exit_code="$2"
  local reason="${3:-}"
  local tool_available="${4:-true}"
  "${PYTHON_BIN}" - <<'PY' "${ROOT}" "${TEST_DIR}" "${LOG_PATH}" "${REPORT_PATH}" "${JUNIT_PATH}" "${success}" "${exit_code}" "${reason}" "${tool_available}"
import json
import sys
from pathlib import Path

workspace_root, test_dir, log_path, report_path, junit_path, success_text, exit_code, reason, tool_available = sys.argv[1:]
report = {
    "schema": "rayman.testing.bats.v1",
    "workspace_root": workspace_root,
    "test_dir": test_dir,
    "success": success_text == "true",
    "exit_code": int(exit_code),
    "reason": reason,
    "tool_available": tool_available == "true",
    "log_path": log_path,
    "junit_path": junit_path if Path(junit_path).is_file() else "",
}
Path(report_path).write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
print(json.dumps(report, indent=2, ensure_ascii=False))
PY
}

if ! command -v bats >/dev/null 2>&1; then
  echo "[rayman-bats] bats not found. Install bats-core to run bash unit tests." >&2
  printf '%s\n' "[rayman-bats] bats not found. Install bats-core to run bash unit tests." > "${LOG_PATH}"
  write_report false 2 tool_missing false
  exit 2
fi

set +e
if bats --help 2>&1 | grep -q -- '--report-formatter'; then
  bats --report-formatter junit --output "${RUNTIME_DIR}" "${TEST_DIR}" | tee "${LOG_PATH}"
else
  bats "${TEST_DIR}" | tee "${LOG_PATH}"
fi
rc=$?
set -e

reason=""
if [[ ${rc} -ne 0 ]]; then
  reason="test_failure"
fi
write_report "$([[ ${rc} -eq 0 ]] && printf true || printf false)" "${rc}" "${reason}" true
exit "${rc}"
