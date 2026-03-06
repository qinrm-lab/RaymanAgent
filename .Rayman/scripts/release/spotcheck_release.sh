#!/usr/bin/env bash
set -euo pipefail

info(){ echo "✅ [rayman-spotcheck] $*"; }
warn(){ echo "⚠️  [rayman-spotcheck] $*" >&2; }
fail(){ echo "❌ [rayman-spotcheck] $*" >&2; exit 3; }

RUNTIME_DIR=".Rayman/runtime"
DECISION_LOG="${RUNTIME_DIR}/decision.log"
DECISION_SUMMARY="${RUNTIME_DIR}/decision.summary.tsv"
DECISION_MAINTAINER="./.Rayman/scripts/release/maintain_decision_log.sh"

now_ts(){ date -Iseconds; }
require_bypass_reason(){
  local gate="$1"
  local reason="${RAYMAN_BYPASS_REASON:-}"
  if [[ -z "${reason// }" ]]; then
    fail "${gate} 需要显式原因：请设置 RAYMAN_BYPASS_REASON。"
  fi
  printf '%s' "${reason}"
}
record_bypass(){
  local gate="$1"
  local reason="$2"
  printf '%s gate=%s action=BYPASS reason=%s\n' "$(now_ts)" "${gate}" "${reason}" >> "${DECISION_LOG}"
  if [[ -f "${DECISION_MAINTAINER}" ]]; then
    bash "${DECISION_MAINTAINER}" --log "${DECISION_LOG}" --summary "${DECISION_SUMMARY}" >/dev/null || true
  fi
  warn "gate bypass: ${gate}（reason=${reason}）"
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"
mkdir -p "${RUNTIME_DIR}"

# 0) hard gate: open issues must be closed
ISSUE_FILE=".Rayman/runtime/issues.open.md"
if [[ -f "$ISSUE_FILE" ]]; then
  if grep -qE '^\s*-\s*\[ \]\s+' "$ISSUE_FILE"; then
    fail "存在未闭环问题：$ISSUE_FILE（包含 - [ ] 项）。请先闭环再发布。"
  fi
fi
info "issues gate OK"

# 1) regression guard (markers/entrypoints)
bash ./.Rayman/scripts/release/regression_guard.sh
info "regression guard OK"

# 2) baseline checklist (avoid recursive call to validate_release_requirements.sh)
bash ./.Rayman/scripts/release/checklist.sh >/dev/null
info "release checklist baseline OK"

# 3) random spotcheck: lightweight commands
SEED_FILE=".Rayman/runtime/spotcheck.seed"
if [[ -f "$SEED_FILE" ]]; then
  seed="$(cat "$SEED_FILE" | tr -d '\r\n')"
else
  seed="$(date +%Y%m%d%H%M%S)"
  echo "$seed" > "$SEED_FILE"
fi

metrics_limit="${RAYMAN_RELEASE_METRICS_LIMIT:-20}"
metrics_cmd="bash ./.Rayman/scripts/telemetry/rules_metrics.sh --limit ${metrics_limit}"

if [[ "${RAYMAN_RELEASE_METRICS_GUARD:-0}" == "1" ]]; then
  warn_fail_rate="${RAYMAN_RELEASE_WARN_FAIL_RATE:-10}"
  warn_avg_ms="${RAYMAN_RELEASE_WARN_AVG_MS:-8000}"
  block_fail_rate="${RAYMAN_RELEASE_BLOCK_FAIL_RATE:-${RAYMAN_RELEASE_MAX_FAIL_RATE:-20}}"
  block_avg_ms="${RAYMAN_RELEASE_BLOCK_AVG_MS:-${RAYMAN_RELEASE_MAX_AVG_MS:-12000}}"

  info "metrics staged guard enabled: warn(fail<=${warn_fail_rate}% avg<=${warn_avg_ms}ms) block(fail<=${block_fail_rate}% avg<=${block_avg_ms}ms)"

  warn_log=".Rayman/runtime/spotcheck.metrics.warn.log"
  block_log=".Rayman/runtime/spotcheck.metrics.block.log"

  if ! bash -lc "${metrics_cmd} --assert-max-fail-rate ${warn_fail_rate} --assert-max-avg-ms ${warn_avg_ms}" > "${warn_log}" 2>&1; then
    warn "metrics WARN threshold exceeded（不阻断发布）"
    tail -n 60 "${warn_log}" >&2 || true
  else
    info "metrics WARN threshold OK"
  fi

  if ! bash -lc "${metrics_cmd} --assert-max-fail-rate ${block_fail_rate} --assert-max-avg-ms ${block_avg_ms}" > "${block_log}" 2>&1; then
    echo "---- metrics block log (tail) ----" >&2
    tail -n 80 "${block_log}" >&2 || true
    fail "metrics BLOCK threshold exceeded"
  fi
  info "metrics BLOCK threshold OK"
fi

if [[ "${RAYMAN_RELEASE_BASELINE_GUARD:-0}" == "1" ]]; then
  baseline_recent_days="${RAYMAN_RELEASE_BASELINE_RECENT_DAYS:-3}"
  baseline_days="${RAYMAN_RELEASE_BASELINE_DAYS:-14}"
  baseline_min_days="${RAYMAN_RELEASE_BASELINE_MIN_DAYS:-3}"
  baseline_warn_fail_delta="${RAYMAN_RELEASE_BASELINE_WARN_FAIL_RATE_DELTA:-2}"
  baseline_warn_avg_delta="${RAYMAN_RELEASE_BASELINE_WARN_AVG_MS_DELTA:-2000}"
  baseline_block_fail_delta="${RAYMAN_RELEASE_BASELINE_BLOCK_FAIL_RATE_DELTA:-5}"
  baseline_block_avg_delta="${RAYMAN_RELEASE_BASELINE_BLOCK_AVG_MS_DELTA:-5000}"
  baseline_log=".Rayman/runtime/spotcheck.baseline.log"

  baseline_cmd="bash ./.Rayman/scripts/telemetry/baseline_guard.sh --recent-days ${baseline_recent_days} --baseline-days ${baseline_days} --min-baseline-days ${baseline_min_days} --warn-fail-rate-delta ${baseline_warn_fail_delta} --warn-avg-ms-delta ${baseline_warn_avg_delta} --block-fail-rate-delta ${baseline_block_fail_delta} --block-avg-ms-delta ${baseline_block_avg_delta}"

  info "baseline guard enabled: recent=${baseline_recent_days}d baseline=${baseline_days}d warn(delta_fail<=${baseline_warn_fail_delta}, delta_avg<=${baseline_warn_avg_delta}) block(delta_fail<=${baseline_block_fail_delta}, delta_avg<=${baseline_block_avg_delta})"

  if ! bash -lc "${baseline_cmd}" > "${baseline_log}" 2>&1; then
    echo "---- baseline guard log (tail) ----" >&2
    tail -n 80 "${baseline_log}" >&2 || true
    fail "baseline guard BLOCK threshold exceeded"
  fi

  if grep -q "status=WARN" "${baseline_log}" 2>/dev/null; then
    warn "baseline guard WARN（不阻断发布）"
    tail -n 60 "${baseline_log}" >&2 || true
  else
    info "baseline guard OK"
  fi
fi

if [[ "${RAYMAN_RELEASE_TELEMETRY_FRESH_GUARD:-1}" == "1" ]]; then
  fresh_max_age_hours="${RAYMAN_RELEASE_TELEMETRY_MAX_AGE_HOURS:-24}"
  fresh_auto_export="${RAYMAN_RELEASE_TELEMETRY_AUTO_EXPORT:-1}"
  fresh_out_root="${RAYMAN_RELEASE_TELEMETRY_OUT_ROOT:-.Rayman/runtime/artifacts/telemetry}"
  fresh_index_file="${RAYMAN_RELEASE_TELEMETRY_INDEX_FILE:-${fresh_out_root}/index.json}"
  fresh_log=".Rayman/runtime/spotcheck.telemetry_fresh.log"
  fresh_export_log=".Rayman/runtime/spotcheck.telemetry_export.log"

  [[ "${fresh_max_age_hours}" =~ ^[1-9][0-9]*$ ]] || fail "invalid RAYMAN_RELEASE_TELEMETRY_MAX_AGE_HOURS=${fresh_max_age_hours}（需为正整数）"
  [[ "${fresh_auto_export}" == "0" || "${fresh_auto_export}" == "1" ]] || fail "invalid RAYMAN_RELEASE_TELEMETRY_AUTO_EXPORT=${fresh_auto_export}（需为 0/1）"

  py_bin=""
  if command -v python3 >/dev/null 2>&1; then
    py_bin="python3"
  elif command -v python >/dev/null 2>&1; then
    py_bin="python"
  else
    fail "telemetry freshness guard requires python3/python"
  fi

  info "telemetry freshness guard enabled: max_age<=${fresh_max_age_hours}h auto_export=${fresh_auto_export}"

  run_freshness_check() {
    local out_root="$1"
    local index_file="$2"
    local max_age_hours="$3"
    local py="$4"
    local log_file="$5"

    bash ./.Rayman/scripts/telemetry/index_artifacts.sh --out-root "${out_root}" --index-file "${index_file}" --validate 1 >/dev/null
    "${py}" - "${index_file}" "${max_age_hours}" > "${log_file}" 2>&1 <<'PY'
import datetime as dt
import json
import sys

index_file = sys.argv[1]
max_age_hours = float(sys.argv[2])

with open(index_file, "r", encoding="utf-8") as f:
    payload = json.load(f)

summary = payload.get("summary")
if not isinstance(summary, dict):
    print("status=BLOCK")
    print("reason=missing summary")
    sys.exit(4)

latest = summary.get("latest_bundle")
if not isinstance(latest, dict):
    print("status=BLOCK")
    print("reason=missing latest_bundle")
    sys.exit(4)

exists = bool(latest.get("exists"))
if not exists:
    print("status=BLOCK")
    print("reason=no telemetry bundles")
    sys.exit(4)

age_hours_raw = latest.get("age_hours")
try:
    age_hours = float(age_hours_raw)
except Exception:
    print("status=BLOCK")
    print("reason=invalid latest_bundle.age_hours")
    sys.exit(4)

bundle_id = str(latest.get("bundle_id", ""))
generated_at = str(latest.get("generated_at", ""))
risk_level = str(summary.get("risk_level", "UNKNOWN"))
flags = summary.get("anomaly_flags", [])
if not isinstance(flags, list):
    flags = []
flags_txt = ",".join(str(x) for x in flags if isinstance(x, str))

print("status=PASS" if age_hours <= max_age_hours else "status=BLOCK")
print(f"bundle_id={bundle_id}")
print(f"generated_at={generated_at}")
print(f"age_hours={age_hours:.2f}")
print(f"max_age_hours={max_age_hours:.2f}")
print(f"risk_level={risk_level}")
print(f"anomaly_flags={flags_txt}")

if age_hours > max_age_hours:
    sys.exit(4)
PY
  }

  freshness_ok=1
  if ! run_freshness_check "${fresh_out_root}" "${fresh_index_file}" "${fresh_max_age_hours}" "${py_bin}" "${fresh_log}"; then
    freshness_ok=0
    if [[ "${fresh_auto_export}" == "1" ]]; then
      warn "freshness check failed; auto-generate telemetry bundle and retry"
      if bash ./.Rayman/scripts/telemetry/export_artifacts.sh --out-root "${fresh_out_root}" --make-tar 0 --run-baseline-guard 1 --baseline-report-only 1 --refresh-index 1 --index-file "${fresh_index_file}" > "${fresh_export_log}" 2>&1; then
        if run_freshness_check "${fresh_out_root}" "${fresh_index_file}" "${fresh_max_age_hours}" "${py_bin}" "${fresh_log}"; then
          freshness_ok=1
        fi
      fi
    fi
  fi

  if [[ "${freshness_ok}" -eq 1 ]]; then
    info "telemetry freshness guard OK"
    sed 's/^/[rayman-spotcheck] freshness: /' "${fresh_log}" | tail -n 8
  else
    echo "---- telemetry freshness log (tail) ----" >&2
    tail -n 80 "${fresh_log}" >&2 || true
    if [[ -f "${fresh_export_log}" ]]; then
      echo "---- telemetry auto-export log (tail) ----" >&2
      tail -n 80 "${fresh_export_log}" >&2 || true
    fi

    if [[ "${RAYMAN_ALLOW_STALE_TELEMETRY:-0}" == "1" ]]; then
      reason="$(require_bypass_reason "stale-telemetry")"
      record_bypass "stale-telemetry" "${reason}"
      warn "telemetry freshness guard failed（按显式决策放行）"
    else
      fail "telemetry freshness guard failed（可显式设置 RAYMAN_ALLOW_STALE_TELEMETRY=1 + RAYMAN_BYPASS_REASON 放行）"
    fi
  fi
fi

# shellcheck disable=SC2206
candidates=(
  "bash ./.Rayman/scripts/release/regression_guard.sh"
  "bash ./.Rayman/scripts/release/assert_dist_sync.sh"
  "bash ./.Rayman/scripts/release/assert_workspace_hygiene.sh"
  "bash ./.Rayman/scripts/release/config_sanity.sh"
  "$metrics_cmd"
  "bash ./.Rayman/scripts/telemetry/index_artifacts.sh --validate 1"
  "bash ./.Rayman/scripts/telemetry/prune_artifacts.sh --keep 50 --dry-run 1 --validate 1"
  "bash ./.Rayman/scripts/telemetry/export_artifacts.sh --make-tar 0 --run-baseline-guard 1 --baseline-report-only 1"
  "bash ./.Rayman/scripts/release/checklist.sh"
  "bash ./.Rayman/scripts/release/contract_update_from_prompt.sh"
  "bash ./.Rayman/scripts/release/contract_release_gate.sh"
  "bash ./.Rayman/scripts/release/contract_playwright_fallback.sh"
  "bash ./.Rayman/scripts/release/issues_gate.sh"
)

if command -v powershell.exe >/dev/null 2>&1; then
  candidates+=("powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./.Rayman/scripts/release/copy_smoke.ps1 -Strict -Scope sandbox -TimeoutSeconds 180")
elif command -v pwsh >/dev/null 2>&1; then
  candidates+=("pwsh -NoProfile -ExecutionPolicy Bypass -File ./.Rayman/scripts/release/copy_smoke.ps1 -Strict -Scope sandbox -TimeoutSeconds 180")
fi

# deterministic shuffle using seed
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY' "$seed" "${candidates[@]}" > .Rayman/runtime/spotcheck.plan
import sys, random
seed=sys.argv[1]
cmds=sys.argv[2:]
r=random.Random(seed)
r.shuffle(cmds)
n=min(3,len(cmds))
for c in cmds[:n]:
    print(c)
PY
elif command -v python >/dev/null 2>&1; then
  python - <<'PY' "$seed" "${candidates[@]}" > .Rayman/runtime/spotcheck.plan
import sys, random
seed=sys.argv[1]
cmds=sys.argv[2:]
r=random.Random(seed)
r.shuffle(cmds)
n=min(3,len(cmds))
for c in cmds[:n]:
    print(c)
PY
else
  # Fallback without python: stable rotation based on cksum(seed).
  seed_num="$(printf '%s' "$seed" | cksum | awk '{print $1}')"
  n_all="${#candidates[@]}"
  [[ "$n_all" -gt 0 ]] || fail "no spotcheck candidates"
  offset=$((seed_num % n_all))
  : > .Rayman/runtime/spotcheck.plan
  for ((i=0; i<n_all; i++)); do
    idx=$(((offset + i) % n_all))
    echo "${candidates[$idx]}" >> .Rayman/runtime/spotcheck.plan
  done
  head -n 3 .Rayman/runtime/spotcheck.plan > .Rayman/runtime/spotcheck.plan.tmp
  mv .Rayman/runtime/spotcheck.plan.tmp .Rayman/runtime/spotcheck.plan
fi

info "spotcheck seed: $seed"
info "spotcheck plan:"
sed 's/^/  - /' .Rayman/runtime/spotcheck.plan

while IFS= read -r cmd; do
  [[ -n "$cmd" ]] || continue
  info "run: $cmd"
  # do not spam output, keep last lines on failure
  if ! bash -lc "$cmd" > .Rayman/runtime/spotcheck.last.log 2>&1; then
    echo "---- spotcheck last log (tail) ----" >&2
    tail -n 80 .Rayman/runtime/spotcheck.last.log >&2 || true
    fail "spotcheck failed: $cmd"
  fi
done < .Rayman/runtime/spotcheck.plan

info "spotcheck OK"
