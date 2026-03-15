#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

TELEMETRY_DIR="${ROOT}/.Rayman/runtime/telemetry"
TELEMETRY_FILE="${TELEMETRY_DIR}/rules_runs.tsv"
RUN_ID="$(date +%Y%m%d_%H%M%S)_doctor_$$"

mkdir -p "${TELEMETRY_DIR}"
if [[ ! -f "${TELEMETRY_FILE}" ]]; then
	echo -e "ts_iso\trun_id\tprofile\tstage\tscope\tstatus\texit_code\tduration_ms\tcommand" > "${TELEMETRY_FILE}"
fi

write_rule_record() {
	local stage="$1"
	local scope="$2"
	local status="$3"
	local exit_code="$4"
	local duration_ms="$5"
	shift 5
	local command_text="$*"
	command_text="${command_text//$'\t'/ }"
	command_text="${command_text//$'\r'/ }"
	command_text="${command_text//$'\n'/ }"
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$(date -Iseconds)" "${RUN_ID}" "doctor" "${stage}" "${scope}" "${status}" "${exit_code}" "${duration_ms}" "${command_text}" >> "${TELEMETRY_FILE}"
}

run_step() {
	local stage="$1"
	shift
	local started_ts end_ts duration_ms rc status
	started_ts="$(date +%s%3N)"
	set +e
	"$@"
	rc=$?
	set -e
	end_ts="$(date +%s%3N)"
	duration_ms=$((end_ts - started_ts))
	status="OK"
	if [[ ${rc} -ne 0 ]]; then
		status="FAIL"
	fi
	write_rule_record "${stage}" "rules" "${status}" "${rc}" "${duration_ms}" "$@"
	return "${rc}"
}

echo "[rayman-doctor] validate requirements layout"
run_step validate_requirements env RAYMAN_VALIDATE_REQUIREMENTS_SKIP_RELEASE=1 bash ./.Rayman/scripts/ci/validate_requirements.sh

if command -v pwsh >/dev/null 2>&1; then
	echo "[rayman-doctor] agent contract"
	run_step agent_contract pwsh -NoProfile -File ./.Rayman/scripts/agents/check_agent_contract.ps1 -WorkspaceRoot "${ROOT}"
else
	echo "[rayman-doctor] WARN: pwsh not found; skip agent contract"
	write_rule_record "agent_contract" "rules" "OK" "0" "0" "skip:pwsh-not-found"
fi

echo "[rayman-doctor] checklist"
run_step checklist bash ./.Rayman/scripts/release/checklist.sh

echo "[rayman-doctor] regression guard"
run_step regression_guard bash ./.Rayman/scripts/release/regression_guard.sh

echo "[rayman-doctor] config sanity"
run_step config_sanity bash ./.Rayman/scripts/release/config_sanity.sh

write_rule_record "final" "rules" "OK" "0" "0" "doctor"

echo "[rayman-doctor] OK"
