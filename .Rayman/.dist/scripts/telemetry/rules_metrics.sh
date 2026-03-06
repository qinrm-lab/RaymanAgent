#!/usr/bin/env bash
set -euo pipefail

file=".Rayman/runtime/telemetry/rules_runs.tsv"
limit=200
run_id_filter=""
assert_max_fail_rate=""
assert_max_avg_ms=""
output_json=0

usage() {
  cat <<'TXT'
Usage:
  bash ./.Rayman/scripts/telemetry/rules_metrics.sh [--limit N] [--run-id ID] [--json]
  bash ./.Rayman/scripts/telemetry/rules_metrics.sh --limit 200 --assert-max-fail-rate 10 --assert-max-avg-ms 8000

Options:
  --limit N    Analyze latest N records (default: 200)
  --run-id ID  Analyze records for a specific run_id only
  --json       Output machine-readable JSON summary
  --assert-max-fail-rate PERCENT  Exit non-zero if fail rate exceeds threshold
  --assert-max-avg-ms N           Exit non-zero if avg_ms exceeds threshold
TXT
}

json_escape() {
  printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g' -e ':a;N;$!ba;s/\n/\\n/g'
}

emit_no_data_json() {
  local message="$1"
  local gate_failed="$2"
  local filter_type filter_value max_fail_json max_avg_json
  local message_esc source_esc value_esc
  local gate_failed_json generated_at

  filter_type="latest"
  filter_value="${limit}"
  if [[ -n "${run_id_filter}" ]]; then
    filter_type="run_id"
    filter_value="${run_id_filter}"
  fi

  max_fail_json="null"
  max_avg_json="null"
  [[ -n "${assert_max_fail_rate}" ]] && max_fail_json="${assert_max_fail_rate}"
  [[ -n "${assert_max_avg_ms}" ]] && max_avg_json="${assert_max_avg_ms}"

  gate_failed_json="false"
  [[ "${gate_failed}" -eq 1 ]] && gate_failed_json="true"
  generated_at="$(date -Iseconds)"

  message_esc="$(json_escape "${message}")"
  source_esc="$(json_escape "${file}")"
  value_esc="$(json_escape "${filter_value}")"

  cat <<JSON
{"schema":"rayman.telemetry.metrics.v1","generated_at":"${generated_at}","source":"${source_esc}","filter":{"type":"${filter_type}","value":"${value_esc}"},"has_data":false,"message":"${message_esc}","summary":{"total":0,"ok":0,"fail":0,"success_rate":0.0,"fail_rate":0.0,"avg_ms":0},"profile_summary":[],"top_failing_commands":[],"recent_failures":[],"assertions":{"max_fail_rate":${max_fail_json},"max_avg_ms":${max_avg_json},"failed":${gate_failed_json}}}
JSON
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)
      limit="${2:-200}"
      shift 2
      ;;
    --run-id)
      run_id_filter="${2:-}"
      shift 2
      ;;
    --json)
      output_json=1
      shift
      ;;
    --assert-max-fail-rate)
      assert_max_fail_rate="${2:-}"
      shift 2
      ;;
    --assert-max-avg-ms)
      assert_max_avg_ms="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! "${limit}" =~ ^[1-9][0-9]*$ ]]; then
  echo "[metrics] invalid --limit: ${limit}" >&2
  exit 2
fi

if [[ -n "${assert_max_fail_rate}" ]]; then
  if ! [[ "${assert_max_fail_rate}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "[metrics] invalid --assert-max-fail-rate: ${assert_max_fail_rate}" >&2
    exit 2
  fi
  if ! awk -v v="${assert_max_fail_rate}" 'BEGIN { exit !(v >= 0 && v <= 100) }'; then
    echo "[metrics] --assert-max-fail-rate must be in [0,100]" >&2
    exit 2
  fi
fi

if [[ -n "${assert_max_avg_ms}" && ! "${assert_max_avg_ms}" =~ ^[1-9][0-9]*$ ]]; then
  echo "[metrics] invalid --assert-max-avg-ms: ${assert_max_avg_ms}" >&2
  exit 2
fi

if [[ ! -f "${file}" ]]; then
  gate_failed=0
  message="[metrics] no telemetry file: ${file}"
  if [[ -n "${assert_max_fail_rate}" || -n "${assert_max_avg_ms}" ]]; then
    gate_failed=1
  fi
  if [[ "${output_json}" -eq 1 ]]; then
    emit_no_data_json "${message}" "${gate_failed}"
  else
    echo "${message}"
    if [[ "${gate_failed}" -eq 1 ]]; then
      echo "[metrics] gate fail: no telemetry file for assertion checks" >&2
    fi
  fi
  [[ "${gate_failed}" -eq 1 ]] && exit 3 || exit 0
fi

tmp="$(mktemp)"
tmp_profiles="$(mktemp)"
tmp_top_fail="$(mktemp)"
tmp_recent_fail="$(mktemp)"
trap 'rm -f "$tmp" "$tmp_profiles" "$tmp_top_fail" "$tmp_recent_fail"' EXIT

if [[ -n "${run_id_filter}" ]]; then
  awk -F'\t' -v rid="${run_id_filter}" '
    BEGIN { OFS="\t" }
    NR==1 && $1=="ts_iso" { print; next }
    $2==rid { print }
  ' "${file}" > "${tmp}"
else
  # Keep one possible header row plus latest payload rows.
  tail -n "$((limit + 1))" "${file}" > "${tmp}"
fi

total="$(awk -F'\t' '
  NR==1 && $1=="ts_iso" { next }
  NF>=9 { c++ }
  END { print c+0 }
' "${tmp}")"

if [[ "${total}" -eq 0 ]]; then
  gate_failed=0
  message="[metrics] no records in sample"
  if [[ -n "${run_id_filter}" ]]; then
    message="[metrics] no records for run_id=${run_id_filter}"
  fi
  if [[ -n "${assert_max_fail_rate}" || -n "${assert_max_avg_ms}" ]]; then
    gate_failed=1
  fi
  if [[ "${output_json}" -eq 1 ]]; then
    emit_no_data_json "${message}" "${gate_failed}"
  else
    echo "${message}"
    if [[ "${gate_failed}" -eq 1 ]]; then
      echo "[metrics] gate fail: no telemetry records to evaluate assertions" >&2
    fi
  fi
  [[ "${gate_failed}" -eq 1 ]] && exit 3 || exit 0
fi

ok_count="$(awk -F'\t' '
  NR==1 && $1=="ts_iso" { next }
  NF>=9 && $6=="OK" { c++ }
  END { print c+0 }
' "${tmp}")"

fail_count="$(( total - ok_count ))"
success_rate="$(awk -v ok="${ok_count}" -v total="${total}" 'BEGIN { printf "%.1f", (ok*100.0)/total }')"
fail_rate="$(awk -v fail="${fail_count}" -v total="${total}" 'BEGIN { printf "%.1f", (fail*100.0)/total }')"
avg_ms="$(awk -F'\t' '
  NR==1 && $1=="ts_iso" { next }
  NF>=9 {
    sum += ($8+0)
    c++
  }
  END {
    if (c==0) print 0;
    else printf "%.0f", (sum/c);
  }
' "${tmp}")"

awk -F'\t' '
  NR==1 && $1=="ts_iso" { next }
  NF>=9 {
    p=$3
    total[p]++
    dur[p]+=($8+0)
    if ($6=="OK") ok[p]++
    else fail[p]++
  }
  END {
    for (p in total) {
      rate = (ok[p]+0) * 100.0 / total[p]
      avg = dur[p] / total[p]
      printf "%s\t%d\t%d\t%d\t%.1f\t%.0f\n", p, total[p], ok[p]+0, fail[p]+0, rate, avg
    }
  }
' "${tmp}" | sort -t $'\t' -k2,2nr > "${tmp_profiles}"

awk -F'\t' '
  NR==1 && $1=="ts_iso" { next }
  NF>=9 && $6!="OK" {
    c[$9]++
  }
  END {
    for (k in c) printf "%d\t%s\n", c[k], k
  }
' "${tmp}" | sort -t $'\t' -k1,1nr | head -n 8 > "${tmp_top_fail}"

awk -F'\t' '
  NR==1 && $1=="ts_iso" { next }
  NF>=9 && $6!="OK" {
    printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1, $3, $6, $7, $8, $9
  }
' "${tmp}" | tail -n 10 > "${tmp_recent_fail}"

gate_failed=0
if [[ -n "${assert_max_fail_rate}" ]]; then
  if ! awk -v actual="${fail_rate}" -v max="${assert_max_fail_rate}" 'BEGIN { exit !(actual <= max) }'; then
    gate_failed=1
  fi
fi
if [[ -n "${assert_max_avg_ms}" ]]; then
  if [[ "${avg_ms}" -gt "${assert_max_avg_ms}" ]]; then
    gate_failed=1
  fi
fi

if [[ "${output_json}" -eq 1 ]]; then
  generated_at="$(date -Iseconds)"
  filter_type="latest"
  filter_value="${limit}"
  if [[ -n "${run_id_filter}" ]]; then
    filter_type="run_id"
    filter_value="${run_id_filter}"
  fi

  max_fail_json="null"
  max_avg_json="null"
  [[ -n "${assert_max_fail_rate}" ]] && max_fail_json="${assert_max_fail_rate}"
  [[ -n "${assert_max_avg_ms}" ]] && max_avg_json="${assert_max_avg_ms}"

  gate_failed_json="false"
  [[ "${gate_failed}" -eq 1 ]] && gate_failed_json="true"

  profile_json="["
  comma=""
  while IFS=$'\t' read -r p t o f r a; do
    [[ -n "${p:-}" ]] || continue
    p_esc="$(json_escape "${p}")"
    profile_json+="${comma}{\"profile\":\"${p_esc}\",\"total\":${t},\"ok\":${o},\"fail\":${f},\"ok_rate\":${r},\"avg_ms\":${a}}"
    comma=","
  done < "${tmp_profiles}"
  profile_json+="]"

  top_fail_json="["
  comma=""
  while IFS=$'\t' read -r c cmd; do
    [[ -n "${c:-}" ]] || continue
    cmd_esc="$(json_escape "${cmd}")"
    top_fail_json+="${comma}{\"count\":${c},\"command\":\"${cmd_esc}\"}"
    comma=","
  done < "${tmp_top_fail}"
  top_fail_json+="]"

  recent_fail_json="["
  comma=""
  while IFS=$'\t' read -r ts p st rc ms cmd; do
    [[ -n "${ts:-}" ]] || continue
    ts_esc="$(json_escape "${ts}")"
    p_esc="$(json_escape "${p}")"
    st_esc="$(json_escape "${st}")"
    cmd_esc="$(json_escape "${cmd}")"
    recent_fail_json+="${comma}{\"ts_iso\":\"${ts_esc}\",\"profile\":\"${p_esc}\",\"status\":\"${st_esc}\",\"exit_code\":${rc},\"duration_ms\":${ms},\"command\":\"${cmd_esc}\"}"
    comma=","
  done < "${tmp_recent_fail}"
  recent_fail_json+="]"

  source_esc="$(json_escape "${file}")"
  value_esc="$(json_escape "${filter_value}")"
  cat <<JSON
{"schema":"rayman.telemetry.metrics.v1","generated_at":"${generated_at}","source":"${source_esc}","filter":{"type":"${filter_type}","value":"${value_esc}"},"has_data":true,"summary":{"total":${total},"ok":${ok_count},"fail":${fail_count},"success_rate":${success_rate},"fail_rate":${fail_rate},"avg_ms":${avg_ms}},"profile_summary":${profile_json},"top_failing_commands":${top_fail_json},"recent_failures":${recent_fail_json},"assertions":{"max_fail_rate":${max_fail_json},"max_avg_ms":${max_avg_json},"failed":${gate_failed_json}}}
JSON
else
  echo "[metrics] source=${file}"
  if [[ -n "${run_id_filter}" ]]; then
    echo "[metrics] filter=run_id:${run_id_filter}"
  else
    echo "[metrics] filter=latest:${limit}"
  fi
  echo "[metrics] total=${total} ok=${ok_count} fail=${fail_count} success_rate=${success_rate}% avg_ms=${avg_ms}"
  echo

  echo "[metrics] profile summary:"
  awk -F'\t' '
    BEGIN { printf "  %-12s %7s %7s %7s %9s %9s\n", "profile", "total", "ok", "fail", "ok_rate", "avg_ms" }
    { printf "  %-12s %7s %7s %7s %8s%% %9s\n", $1, $2, $3, $4, $5, $6 }
  ' "${tmp_profiles}"
  echo

  echo "[metrics] top failing commands:"
  if [[ -s "${tmp_top_fail}" ]]; then
    awk -F'\t' '{ printf "  %4s  %s\n", $1, $2 }' "${tmp_top_fail}"
  else
    echo "  (none)"
  fi
  echo

  echo "[metrics] recent failures:"
  if [[ -s "${tmp_recent_fail}" ]]; then
    awk -F'\t' '{ printf "  %s | profile=%s status=%s rc=%s ms=%s | %s\n", $1, $2, $3, $4, $5, $6 }' "${tmp_recent_fail}"
  else
    echo "  (none)"
  fi

  if [[ "${gate_failed}" -eq 1 ]]; then
    if [[ -n "${assert_max_fail_rate}" ]]; then
      if ! awk -v actual="${fail_rate}" -v max="${assert_max_fail_rate}" 'BEGIN { exit !(actual <= max) }'; then
        echo "[metrics] gate fail: fail_rate=${fail_rate}% > max=${assert_max_fail_rate}%" >&2
      fi
    fi
    if [[ -n "${assert_max_avg_ms}" && "${avg_ms}" -gt "${assert_max_avg_ms}" ]]; then
      echo "[metrics] gate fail: avg_ms=${avg_ms} > max=${assert_max_avg_ms}" >&2
    fi
  fi
fi

if [[ "${gate_failed}" -eq 1 ]]; then
  exit 3
fi
