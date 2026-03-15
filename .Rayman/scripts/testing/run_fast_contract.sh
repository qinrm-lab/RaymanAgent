#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RUNTIME_DIR="${ROOT}/.Rayman/runtime/test_lanes"
LOG_DIR="${RUNTIME_DIR}/logs/fast_contract"
REPORT_PATH="${RUNTIME_DIR}/fast_contract.report.json"
JSON_CONTRACT_REPORT="${RUNTIME_DIR}/json_contracts.report.json"
STEPS_FILE="${RUNTIME_DIR}/fast_contract.steps.tsv"
TELEMETRY_DIR="${ROOT}/.Rayman/runtime/telemetry"
TELEMETRY_FILE="${TELEMETRY_DIR}/rules_runs.tsv"
RUN_ID="$(date +%Y%m%d_%H%M%S)_fast_contract_$$"

mkdir -p "${LOG_DIR}"
mkdir -p "${TELEMETRY_DIR}"
: > "${STEPS_FILE}"

if [[ ! -f "${TELEMETRY_FILE}" ]]; then
  echo -e "ts_iso\trun_id\tprofile\tstage\tscope\tstatus\texit_code\tduration_ms\tcommand" > "${TELEMETRY_FILE}"
fi

fail_count=0

write_rule_record() {
  local stage="$1"
  local status="$2"
  local exit_code="$3"
  local duration_ms="$4"
  shift 4
  local command_text="$*"
  command_text="${command_text//$'\t'/ }"
  command_text="${command_text//$'\r'/ }"
  command_text="${command_text//$'\n'/ }"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -Iseconds)" "${RUN_ID}" "fast-contract" "${stage}" "lane" "${status}" "${exit_code}" "${duration_ms}" "${command_text}" >> "${TELEMETRY_FILE}"
}

if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
else
  echo "[rayman-fast-contract] python/python3 not found" >&2
  exit 2
fi

if command -v pwsh >/dev/null 2>&1; then
  PS_RUNNER=(pwsh -NoProfile -ExecutionPolicy Bypass -File)
elif command -v powershell >/dev/null 2>&1; then
  PS_RUNNER=(powershell -NoProfile -ExecutionPolicy Bypass -File)
else
  echo "[rayman-fast-contract] pwsh/powershell not found" >&2
  exit 2
fi

run_step() {
  local name="$1"
  shift
  local log_path="${LOG_DIR}/${name}.log"
  local rc started_ts end_ts duration_ms status

  echo "[rayman-fast-contract] >>> ${name}"
  started_ts="$(date +%s%3N)"
  set +e
  "$@" >"${log_path}" 2>&1
  rc=$?
  set -e
  end_ts="$(date +%s%3N)"
  duration_ms=$((end_ts - started_ts))
  cat "${log_path}"

  if [[ ${rc} -eq 0 ]]; then
    printf '%s\tPASS\t%s\t%s\n' "${name}" "${rc}" "${log_path}" >>"${STEPS_FILE}"
    status="OK"
  else
    printf '%s\tFAIL\t%s\t%s\n' "${name}" "${rc}" "${log_path}" >>"${STEPS_FILE}"
    fail_count=$((fail_count + 1))
    status="FAIL"
  fi
  write_rule_record "${name}" "${status}" "${rc}" "${duration_ms}" "$@"
}

cd "${ROOT}"

run_step validate_requirements env RAYMAN_VALIDATE_REQUIREMENTS_SKIP_RELEASE=1 bash ./.Rayman/scripts/ci/validate_requirements.sh
run_step checklist bash ./.Rayman/scripts/release/checklist.sh
run_step regression_guard bash ./.Rayman/scripts/release/regression_guard.sh
run_step config_sanity bash ./.Rayman/scripts/release/config_sanity.sh
run_step agent_contract "${PS_RUNNER[@]}" ./.Rayman/scripts/agents/check_agent_contract.ps1 -WorkspaceRoot "${ROOT}" -SkipContextRefresh
run_step assert_dist_sync "${PS_RUNNER[@]}" ./.Rayman/scripts/release/assert_dist_sync.ps1 -WorkspaceRoot "${ROOT}"
run_step json_contracts "${PYTHON_BIN}" ./.Rayman/scripts/testing/validate_json_contracts.py --workspace-root "${ROOT}" --mode all --report-path "${JSON_CONTRACT_REPORT}"

"${PYTHON_BIN}" - <<'PY' "${STEPS_FILE}" "${REPORT_PATH}" "${ROOT}" "${fail_count}"
import json
import sys
from pathlib import Path

steps_file = Path(sys.argv[1])
report_path = Path(sys.argv[2])
workspace_root = sys.argv[3]
fail_count = int(sys.argv[4])

steps = []
for line in steps_file.read_text(encoding="utf-8").splitlines():
    name, status, exit_code, log_path = line.split("\t")
    steps.append(
        {
            "name": name,
            "status": status,
            "exit_code": int(exit_code),
            "log_path": log_path,
        }
    )

report = {
    "schema": "rayman.testing.fast_contract.v1",
    "workspace_root": workspace_root,
    "success": fail_count == 0,
    "counts": {
        "pass": sum(1 for step in steps if step["status"] == "PASS"),
        "fail": sum(1 for step in steps if step["status"] == "FAIL"),
    },
    "steps": steps,
}

report_path.parent.mkdir(parents=True, exist_ok=True)
report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
print(json.dumps(report, indent=2, ensure_ascii=False))
PY

write_rule_record "final" "$(if [[ ${fail_count} -eq 0 ]]; then echo OK; else echo FAIL; fi)" "${fail_count}" "0" "fast-contract"

if [[ ${fail_count} -ne 0 ]]; then
  exit 1
fi
