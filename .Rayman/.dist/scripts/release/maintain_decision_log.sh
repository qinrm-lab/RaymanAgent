#!/usr/bin/env bash
set -euo pipefail

log_file=".Rayman/runtime/decision.log"
summary_file=".Rayman/runtime/decision.summary.tsv"
max_lines="${RAYMAN_DECISION_LOG_MAX_LINES:-2000}"
keep_files="${RAYMAN_DECISION_LOG_KEEP_FILES:-10}"

usage() {
  cat <<'TXT'
Usage:
  bash ./.Rayman/scripts/release/maintain_decision_log.sh [options]

Options:
  --log FILE        decision log path (default: .Rayman/runtime/decision.log)
  --summary FILE    summary output path (default: .Rayman/runtime/decision.summary.tsv)
  --max-lines N     rotate when log lines exceed N (default: env RAYMAN_DECISION_LOG_MAX_LINES or 2000)
  --keep-files N    keep newest N backup files (default: env RAYMAN_DECISION_LOG_KEEP_FILES or 10)
TXT
}

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log) log_file="${2:-}"; shift 2 ;;
    --summary) summary_file="${2:-}"; shift 2 ;;
    --max-lines) max_lines="${2:-}"; shift 2 ;;
    --keep-files) keep_files="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[decision-maintain] unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

is_uint "${max_lines}" || { echo "[decision-maintain] max-lines must be >= 0" >&2; exit 2; }
is_uint "${keep_files}" || { echo "[decision-maintain] keep-files must be >= 0" >&2; exit 2; }

mkdir -p "$(dirname "${log_file}")" "$(dirname "${summary_file}")"
touch "${log_file}"

line_count="$(wc -l < "${log_file}" | tr -d ' ')"
if [[ "${max_lines}" -gt 0 && "${line_count}" -gt "${max_lines}" ]]; then
  backup="${log_file}.$(date +%Y%m%d_%H%M%S).bak"
  cp "${log_file}" "${backup}"
  tail -n "${max_lines}" "${backup}" > "${log_file}.tmp"
  mv "${log_file}.tmp" "${log_file}"
fi

if [[ "${keep_files}" -ge 0 ]]; then
  mapfile -t backups < <(ls -1t "${log_file}".*.bak 2>/dev/null || true)
  if [[ "${#backups[@]}" -gt "${keep_files}" ]]; then
    for old in "${backups[@]:${keep_files}}"; do
      rm -f "${old}"
    done
  fi
fi

tmp_summary="$(mktemp)"
awk '
  {
    if (match($0, /^([^ ]+)[[:space:]]+gate=([^ ]+)[[:space:]]+action=([^ ]+)([[:space:]]+[A-Za-z0-9_.-]+=[^ ]+)*[[:space:]]+reason=(.*)$/, m)) {
      ts=m[1]
      dt=substr(ts,1,10)
      gate=m[2]
      action=m[3]
      reason=m[5]
      key=dt SUBSEP gate SUBSEP action SUBSEP reason
      count[key]++
      if (!(key in first_ts)) {
        first_ts[key]=ts
      }
      last_ts[key]=ts
    }
  }
  END {
    for (k in count) {
      split(k, a, SUBSEP)
      printf "%s\t%s\t%s\t%s\t%d\t%s\t%s\n", a[1], a[2], a[3], a[4], count[k], first_ts[k], last_ts[k]
    }
  }
' "${log_file}" | LC_ALL=C sort -t $'\t' -k1,1 -k2,2 -k3,3 -k4,4 > "${tmp_summary}"

{
  printf 'date\tgate\taction\treason\tcount\tfirst_ts\tlast_ts\n'
  cat "${tmp_summary}"
} > "${summary_file}"

rm -f "${tmp_summary}"
echo "[decision-maintain] log=${log_file} summary=${summary_file}"
