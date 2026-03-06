#!/usr/bin/env bash
set -euo pipefail

source_file=".Rayman/runtime/telemetry/rules_runs.tsv"
recent_days=3
baseline_days=14
min_baseline_days=3
warn_fail_rate_delta=2
warn_avg_ms_delta=2000
block_fail_rate_delta=5
block_avg_ms_delta=5000
json_out=""
report_only=0

usage() {
  cat <<'TXT'
Usage:
  bash ./.Rayman/scripts/telemetry/baseline_guard.sh [options]

Options:
  --source FILE                      Telemetry TSV source
  --recent-days N                    Recent window day count (default: 3)
  --baseline-days N                  Baseline window day count (default: 14)
  --min-baseline-days N              Minimum baseline days required (default: 3)
  --warn-fail-rate-delta PERCENT     Warn threshold for fail_rate delta (default: 2)
  --warn-avg-ms-delta N              Warn threshold for avg_ms delta (default: 2000)
  --block-fail-rate-delta PERCENT    Block threshold for fail_rate delta (default: 5)
  --block-avg-ms-delta N             Block threshold for avg_ms delta (default: 5000)
  --json-out FILE                    Optional JSON output
  --report-only                      Never fail the command (still reports BLOCK/WARN)
TXT
}

json_escape() {
  printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g' -e ':a;N;$!ba;s/\n/\\n/g'
}

is_int() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; }
is_num() { [[ "${1:-}" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; }
num_gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a>b) }'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      source_file="${2:-}"
      shift 2
      ;;
    --recent-days)
      recent_days="${2:-}"
      shift 2
      ;;
    --baseline-days)
      baseline_days="${2:-}"
      shift 2
      ;;
    --min-baseline-days)
      min_baseline_days="${2:-}"
      shift 2
      ;;
    --warn-fail-rate-delta)
      warn_fail_rate_delta="${2:-}"
      shift 2
      ;;
    --warn-avg-ms-delta)
      warn_avg_ms_delta="${2:-}"
      shift 2
      ;;
    --block-fail-rate-delta)
      block_fail_rate_delta="${2:-}"
      shift 2
      ;;
    --block-avg-ms-delta)
      block_avg_ms_delta="${2:-}"
      shift 2
      ;;
    --json-out)
      json_out="${2:-}"
      shift 2
      ;;
    --report-only)
      report_only=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[baseline] unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for v in "${recent_days}" "${baseline_days}" "${min_baseline_days}" "${warn_avg_ms_delta}" "${block_avg_ms_delta}"; do
  if ! is_int "${v}"; then
    echo "[baseline] integer option invalid: ${v}" >&2
    exit 2
  fi
done

for v in "${warn_fail_rate_delta}" "${block_fail_rate_delta}"; do
  if ! is_num "${v}"; then
    echo "[baseline] numeric option invalid: ${v}" >&2
    exit 2
  fi
done

generated_at="$(date -Iseconds)"
status="PASS"
reason=""
baseline_days_used=0
recent_total=0
recent_ok=0
recent_fail=0
recent_fail_rate="0.0"
recent_avg_ms="0"
baseline_total=0
baseline_ok=0
baseline_fail=0
baseline_fail_rate="0.0"
baseline_avg_ms="0"
delta_fail_rate="0.0"
delta_avg_ms="0.0"

rows_tsv="$(mktemp)"
days_tsv="$(mktemp)"
recent_dates_tsv="$(mktemp)"
baseline_dates_tsv="$(mktemp)"
trap 'rm -f "${rows_tsv}" "${days_tsv}" "${recent_dates_tsv}" "${baseline_dates_tsv}"' EXIT

emit_json() {
  [[ -n "${json_out}" ]] || return 0
  mkdir -p "$(dirname "${json_out}")"
  local source_esc reason_esc
  local report_only_json
  source_esc="$(json_escape "${source_file}")"
  reason_esc="$(json_escape "${reason}")"
  report_only_json="false"
  [[ "${report_only}" -eq 1 ]] && report_only_json="true"

  cat > "${json_out}" <<JSON
{"schema":"rayman.telemetry.baseline_guard.v1","generated_at":"${generated_at}","source":"${source_esc}","status":"${status}","reason":"${reason_esc}","report_only":${report_only_json},"config":{"recent_days":${recent_days},"baseline_days":${baseline_days},"min_baseline_days":${min_baseline_days},"warn_fail_rate_delta":${warn_fail_rate_delta},"warn_avg_ms_delta":${warn_avg_ms_delta},"block_fail_rate_delta":${block_fail_rate_delta},"block_avg_ms_delta":${block_avg_ms_delta}},"baseline_days_used":${baseline_days_used},"recent":{"total":${recent_total},"ok":${recent_ok},"fail":${recent_fail},"fail_rate":${recent_fail_rate},"avg_ms":${recent_avg_ms}},"baseline":{"total":${baseline_total},"ok":${baseline_ok},"fail":${baseline_fail},"fail_rate":${baseline_fail_rate},"avg_ms":${baseline_avg_ms}},"delta":{"fail_rate":${delta_fail_rate},"avg_ms":${delta_avg_ms}}}
JSON
}

finish() {
  emit_json
  echo "[baseline] source=${source_file}"
  echo "[baseline] status=${status}"
  [[ -n "${reason}" ]] && echo "[baseline] reason=${reason}"
  echo "[baseline] recent(total=${recent_total}, ok=${recent_ok}, fail=${recent_fail}, fail_rate=${recent_fail_rate}%, avg_ms=${recent_avg_ms})"
  echo "[baseline] baseline(total=${baseline_total}, ok=${baseline_ok}, fail=${baseline_fail}, fail_rate=${baseline_fail_rate}%, avg_ms=${baseline_avg_ms}, days=${baseline_days_used})"
  echo "[baseline] delta(fail_rate=${delta_fail_rate}%, avg_ms=${delta_avg_ms})"
  echo "[baseline] thresholds(warn_fail_delta<=${warn_fail_rate_delta}, warn_avg_delta<=${warn_avg_ms_delta}, block_fail_delta<=${block_fail_rate_delta}, block_avg_delta<=${block_avg_ms_delta})"
  if [[ -n "${json_out}" ]]; then
    echo "[baseline] json=${json_out}"
  fi
}

if [[ ! -f "${source_file}" ]]; then
  status="INSUFFICIENT_BASELINE"
  reason="telemetry file missing"
  finish
  exit 0
fi

awk -F'\t' '
  NR==1 && $1=="ts_iso" { next }
  NF>=9 {
    day=substr($1,1,10)
    if (day ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) {
      print day "\t" $6 "\t" ($8+0)
    }
  }
' "${source_file}" > "${rows_tsv}"

if [[ ! -s "${rows_tsv}" ]]; then
  status="INSUFFICIENT_BASELINE"
  reason="no valid telemetry rows"
  finish
  exit 0
fi

mapfile -t all_days < <(awk -F'\t' '{print $1}' "${rows_tsv}" | sort -u)
total_day_count="${#all_days[@]}"
if [[ "${total_day_count}" -lt "${recent_days}" ]]; then
  status="INSUFFICIENT_BASELINE"
  reason="not enough days for recent window"
  finish
  exit 0
fi

recent_start_idx=$(( total_day_count - recent_days ))
for ((i=recent_start_idx; i<total_day_count; i++)); do
  echo "${all_days[$i]}" >> "${recent_dates_tsv}"
done

baseline_end_idx=$(( recent_start_idx - 1 ))
if [[ "${baseline_end_idx}" -lt 0 ]]; then
  status="INSUFFICIENT_BASELINE"
  reason="no baseline days before recent window"
  finish
  exit 0
fi

baseline_start_idx=$(( baseline_end_idx - baseline_days + 1 ))
if [[ "${baseline_start_idx}" -lt 0 ]]; then baseline_start_idx=0; fi
for ((i=baseline_start_idx; i<=baseline_end_idx; i++)); do
  echo "${all_days[$i]}" >> "${baseline_dates_tsv}"
done

baseline_days_used="$(wc -l < "${baseline_dates_tsv}" | tr -d '[:space:]')"
if [[ "${baseline_days_used}" -lt "${min_baseline_days}" ]]; then
  status="INSUFFICIENT_BASELINE"
  reason="baseline days used (${baseline_days_used}) < min_baseline_days (${min_baseline_days})"
  finish
  exit 0
fi

read -r recent_total recent_ok recent_fail recent_fail_rate recent_avg_ms < <(
  awk -F'\t' '
    NR==FNR { keep[$1]=1; next }
    keep[$1] {
      total++
      if ($2=="OK") ok++
      fail = total - ok
      dur += ($3+0)
    }
    END {
      if (total==0) {
        print "0 0 0 0.0 0"
      } else {
        printf "%d %d %d %.1f %.0f\n", total, ok, fail, (fail*100.0)/total, dur/total
      }
    }
  ' "${recent_dates_tsv}" "${rows_tsv}"
)

read -r baseline_total baseline_ok baseline_fail baseline_fail_rate baseline_avg_ms < <(
  awk -F'\t' '
    NR==FNR { keep[$1]=1; next }
    keep[$1] {
      total++
      if ($2=="OK") ok++
      fail = total - ok
      dur += ($3+0)
    }
    END {
      if (total==0) {
        print "0 0 0 0.0 0"
      } else {
        printf "%d %d %d %.1f %.0f\n", total, ok, fail, (fail*100.0)/total, dur/total
      }
    }
  ' "${baseline_dates_tsv}" "${rows_tsv}"
)

if [[ "${baseline_total}" -eq 0 ]]; then
  status="INSUFFICIENT_BASELINE"
  reason="baseline window has zero records"
  finish
  exit 0
fi

delta_fail_rate="$(awk -v r="${recent_fail_rate}" -v b="${baseline_fail_rate}" 'BEGIN { printf "%.1f", (r-b) }')"
delta_avg_ms="$(awk -v r="${recent_avg_ms}" -v b="${baseline_avg_ms}" 'BEGIN { printf "%.1f", (r-b) }')"

status="PASS"
if num_gt "${delta_fail_rate}" "${block_fail_rate_delta}" || num_gt "${delta_avg_ms}" "${block_avg_ms_delta}"; then
  status="BLOCK"
elif num_gt "${delta_fail_rate}" "${warn_fail_rate_delta}" || num_gt "${delta_avg_ms}" "${warn_avg_ms_delta}"; then
  status="WARN"
fi

if [[ "${status}" == "WARN" ]]; then
  reason="delta exceeded warn threshold"
elif [[ "${status}" == "BLOCK" ]]; then
  reason="delta exceeded block threshold"
fi

finish

if [[ "${status}" == "BLOCK" && "${report_only}" -ne 1 ]]; then
  exit 3
fi
