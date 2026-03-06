#!/usr/bin/env bash
set -euo pipefail

metrics_limit=200
trend_days=14
out_root=".Rayman/runtime/artifacts/telemetry"
bundle_id="$(date +%Y%m%dT%H%M%S)"
make_tar=1
run_baseline_guard=1
baseline_report_only=1
baseline_recent_days=3
baseline_days=14
baseline_min_days=3
baseline_warn_fail_rate_delta=2
baseline_warn_avg_ms_delta=2000
baseline_block_fail_rate_delta=5
baseline_block_avg_ms_delta=5000
refresh_index=1
index_file=""
prune_keep=0
prune_max_age_days=0
prune_dry_run=0
prune_validate=1

usage() {
  cat <<'TXT'
Usage:
  bash ./.Rayman/scripts/telemetry/export_artifacts.sh [options]

Options:
  --metrics-limit N                  metrics sample size (default: 200)
  --trend-days N                     trend window days (default: 14)
  --out-root DIR                     output root dir (default: .Rayman/runtime/artifacts/telemetry)
  --bundle-id ID                     custom bundle id (default: timestamp)
  --make-tar 0|1                     generate tar.gz bundle (default: 1)
  --run-baseline-guard 0|1           include baseline guard report (default: 1)
  --baseline-report-only 0|1         baseline guard non-blocking mode (default: 1)
  --baseline-recent-days N
  --baseline-days N
  --baseline-min-days N
  --baseline-warn-fail-rate-delta N
  --baseline-warn-avg-ms-delta N
  --baseline-block-fail-rate-delta N
  --baseline-block-avg-ms-delta N
  --refresh-index 0|1               refresh artifact index after export (default: 1)
  --index-file FILE                 artifact index file (default: <out-root>/index.json)
  --prune-keep N                    prune and keep newest N bundles (0 disables keep rule; default: 0)
  --prune-max-age-days N            prune bundles older than N days (0 disables age rule; default: 0)
  --prune-dry-run 0|1               prune dry-run mode (default: 0)
  --prune-validate 0|1              validate index during prune/indexing (default: 1)
TXT
}

is_int() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; }
is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
is_flag() { [[ "${1:-}" == "0" || "${1:-}" == "1" ]]; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --metrics-limit) metrics_limit="${2:-}"; shift 2 ;;
    --trend-days) trend_days="${2:-}"; shift 2 ;;
    --out-root) out_root="${2:-}"; shift 2 ;;
    --bundle-id) bundle_id="${2:-}"; shift 2 ;;
    --make-tar) make_tar="${2:-}"; shift 2 ;;
    --run-baseline-guard) run_baseline_guard="${2:-}"; shift 2 ;;
    --baseline-report-only) baseline_report_only="${2:-}"; shift 2 ;;
    --baseline-recent-days) baseline_recent_days="${2:-}"; shift 2 ;;
    --baseline-days) baseline_days="${2:-}"; shift 2 ;;
    --baseline-min-days) baseline_min_days="${2:-}"; shift 2 ;;
    --baseline-warn-fail-rate-delta) baseline_warn_fail_rate_delta="${2:-}"; shift 2 ;;
    --baseline-warn-avg-ms-delta) baseline_warn_avg_ms_delta="${2:-}"; shift 2 ;;
    --baseline-block-fail-rate-delta) baseline_block_fail_rate_delta="${2:-}"; shift 2 ;;
    --baseline-block-avg-ms-delta) baseline_block_avg_ms_delta="${2:-}"; shift 2 ;;
    --refresh-index) refresh_index="${2:-}"; shift 2 ;;
    --index-file) index_file="${2:-}"; shift 2 ;;
    --prune-keep) prune_keep="${2:-}"; shift 2 ;;
    --prune-max-age-days) prune_max_age_days="${2:-}"; shift 2 ;;
    --prune-dry-run) prune_dry_run="${2:-}"; shift 2 ;;
    --prune-validate) prune_validate="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[telemetry-export] unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for v in "${metrics_limit}" "${trend_days}" "${baseline_recent_days}" "${baseline_days}" "${baseline_min_days}" "${baseline_warn_avg_ms_delta}" "${baseline_block_avg_ms_delta}"; do
  if ! is_int "${v}"; then
    echo "[telemetry-export] integer option invalid: ${v}" >&2
    exit 2
  fi
done

for v in "${prune_keep}" "${prune_max_age_days}"; do
  if ! is_uint "${v}"; then
    echo "[telemetry-export] integer option invalid (must be >= 0): ${v}" >&2
    exit 2
  fi
done
for v in "${make_tar}" "${run_baseline_guard}" "${baseline_report_only}" "${refresh_index}" "${prune_dry_run}" "${prune_validate}"; do
  if ! is_flag "${v}"; then
    echo "[telemetry-export] flag must be 0/1: ${v}" >&2
    exit 2
  fi
done

if [[ -z "${index_file}" ]]; then
  index_file="${out_root}/index.json"
fi

bundle_dir="${out_root}/${bundle_id}"
mkdir -p "${bundle_dir}"

metrics_json="${bundle_dir}/metrics.json"
metrics_txt="${bundle_dir}/metrics.txt"
trend_md="${bundle_dir}/daily_trend.md"
trend_json="${bundle_dir}/daily_trend.json"
first_pass_md="${bundle_dir}/first_pass_report.md"
first_pass_json="${bundle_dir}/first_pass_report.json"
baseline_txt="${bundle_dir}/baseline_guard.txt"
baseline_json="${bundle_dir}/baseline_guard.json"
manifest_json="${bundle_dir}/manifest.json"
generated_at="$(date -Iseconds)"

bash ./.Rayman/scripts/telemetry/rules_metrics.sh --limit "${metrics_limit}" --json > "${metrics_json}"
bash ./.Rayman/scripts/telemetry/rules_metrics.sh --limit "${metrics_limit}" > "${metrics_txt}"
bash ./.Rayman/scripts/telemetry/validate_json.sh --kind metrics --file "${metrics_json}"

bash ./.Rayman/scripts/telemetry/daily_trend.sh --days "${trend_days}" --out "${trend_md}" --json-out "${trend_json}"
bash ./.Rayman/scripts/telemetry/validate_json.sh --kind trend --file "${trend_json}"

first_pass_status="SKIP"
first_pass_src_md=".Rayman/runtime/telemetry/first_pass_report.md"
first_pass_src_json=".Rayman/runtime/telemetry/first_pass_report.json"
if [[ -f "./.Rayman/scripts/agents/first_pass_report.ps1" ]]; then
  if command -v pwsh >/dev/null 2>&1; then
    if pwsh -NoProfile -ExecutionPolicy Bypass -File ./.Rayman/scripts/agents/first_pass_report.ps1 -WorkspaceRoot "$(pwd)" >/dev/null 2>&1; then
      first_pass_status="OK"
    else
      first_pass_status="FAIL"
    fi
  elif command -v powershell.exe >/dev/null 2>&1; then
    fp_script="./.Rayman/scripts/agents/first_pass_report.ps1"
    fp_root="$(pwd)"
    if command -v wslpath >/dev/null 2>&1; then
      fp_script="$(wslpath -w "${fp_script}")"
      fp_root="$(wslpath -w "${fp_root}")"
    fi
    if powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${fp_script}" -WorkspaceRoot "${fp_root}" >/dev/null 2>&1; then
      first_pass_status="OK"
    else
      first_pass_status="FAIL"
    fi
  fi
fi

if [[ -f "${first_pass_src_md}" ]]; then
  cp "${first_pass_src_md}" "${first_pass_md}"
fi
if [[ -f "${first_pass_src_json}" ]]; then
  cp "${first_pass_src_json}" "${first_pass_json}"
  bash ./.Rayman/scripts/telemetry/validate_json.sh --kind first-pass --file "${first_pass_json}"
fi

baseline_rc=0
baseline_status="SKIP"
if [[ "${run_baseline_guard}" == "1" ]]; then
  baseline_cmd=(
    bash ./.Rayman/scripts/telemetry/baseline_guard.sh
    --recent-days "${baseline_recent_days}"
    --baseline-days "${baseline_days}"
    --min-baseline-days "${baseline_min_days}"
    --warn-fail-rate-delta "${baseline_warn_fail_rate_delta}"
    --warn-avg-ms-delta "${baseline_warn_avg_ms_delta}"
    --block-fail-rate-delta "${baseline_block_fail_rate_delta}"
    --block-avg-ms-delta "${baseline_block_avg_ms_delta}"
    --json-out "${baseline_json}"
  )
  if [[ "${baseline_report_only}" == "1" ]]; then
    baseline_cmd+=(--report-only)
  fi

  set +e
  "${baseline_cmd[@]}" > "${baseline_txt}" 2>&1
  baseline_rc=$?
  set -e

  if grep -q "status=BLOCK" "${baseline_txt}" 2>/dev/null; then
    baseline_status="BLOCK"
  elif grep -q "status=WARN" "${baseline_txt}" 2>/dev/null; then
    baseline_status="WARN"
  elif grep -q "status=PASS" "${baseline_txt}" 2>/dev/null; then
    baseline_status="PASS"
  elif grep -q "status=INSUFFICIENT_BASELINE" "${baseline_txt}" 2>/dev/null; then
    baseline_status="INSUFFICIENT_BASELINE"
  else
    baseline_status="UNKNOWN"
  fi

  if [[ "${baseline_rc}" -ne 0 && "${baseline_report_only}" != "1" ]]; then
    echo "[telemetry-export] baseline guard failed (rc=${baseline_rc})" >&2
    tail -n 80 "${baseline_txt}" >&2 || true
    exit "${baseline_rc}"
  fi
fi

if [[ -f "${baseline_json}" ]]; then
  bash ./.Rayman/scripts/telemetry/validate_json.sh --kind baseline --file "${baseline_json}"
fi

cat > "${manifest_json}" <<JSON
{"schema":"rayman.telemetry.artifact_bundle.v1","generated_at":"${generated_at}","bundle_id":"${bundle_id}","bundle_dir":"${bundle_dir}","metrics_limit":${metrics_limit},"trend_days":${trend_days},"first_pass":{"status":"${first_pass_status}","has_md":$(if [[ -f "${first_pass_md}" ]]; then echo 1; else echo 0; fi),"has_json":$(if [[ -f "${first_pass_json}" ]]; then echo 1; else echo 0; fi)},"baseline":{"enabled":${run_baseline_guard},"report_only":${baseline_report_only},"status":"${baseline_status}","rc":${baseline_rc}},"files":[{"name":"metrics.json","path":"${metrics_json}"},{"name":"metrics.txt","path":"${metrics_txt}"},{"name":"daily_trend.md","path":"${trend_md}"},{"name":"daily_trend.json","path":"${trend_json}"},{"name":"first_pass_report.md","path":"${first_pass_md}"},{"name":"first_pass_report.json","path":"${first_pass_json}"},{"name":"baseline_guard.txt","path":"${baseline_txt}"},{"name":"baseline_guard.json","path":"${baseline_json}"},{"name":"manifest.json","path":"${manifest_json}"}]}
JSON

bash ./.Rayman/scripts/telemetry/validate_json.sh --kind manifest --file "${manifest_json}"

echo "${bundle_id}" > "${out_root}/latest.txt"

tar_path=""
if [[ "${make_tar}" == "1" ]]; then
  if command -v tar >/dev/null 2>&1; then
    tar_path="${out_root}/telemetry-${bundle_id}.tar.gz"
    tar -czf "${tar_path}" -C "${out_root}" "${bundle_id}"
  else
    echo "[telemetry-export] tar not found; skip tarball packaging" >&2
  fi
fi

if [[ "${prune_keep}" -gt 0 || "${prune_max_age_days}" -gt 0 ]]; then
  bash ./.Rayman/scripts/telemetry/prune_artifacts.sh \
    --out-root "${out_root}" \
    --keep "${prune_keep}" \
    --max-age-days "${prune_max_age_days}" \
    --dry-run "${prune_dry_run}" \
    --index-file "${index_file}" \
    --validate "${prune_validate}"
elif [[ "${refresh_index}" == "1" ]]; then
  bash ./.Rayman/scripts/telemetry/index_artifacts.sh \
    --out-root "${out_root}" \
    --index-file "${index_file}" \
    --validate "${prune_validate}"
fi

echo "[telemetry-export] bundle=${bundle_dir}"
[[ -n "${tar_path}" ]] && echo "[telemetry-export] tar=${tar_path}"
echo "[telemetry-export] manifest=${manifest_json}"
if [[ "${prune_keep}" -gt 0 || "${prune_max_age_days}" -gt 0 || "${refresh_index}" == "1" ]]; then
  echo "[telemetry-export] index=${index_file}"
fi
