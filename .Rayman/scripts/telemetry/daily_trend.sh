#!/usr/bin/env bash
set -euo pipefail

telemetry_file=".Rayman/runtime/telemetry/rules_runs.tsv"
out_file=".Rayman/runtime/telemetry/daily_trend.md"
json_out=""
days=7

usage() {
  cat <<'TXT'
Usage:
  bash ./.Rayman/scripts/telemetry/daily_trend.sh [--days N] [--out FILE] [--json-out FILE] [--source FILE]

Options:
  --days N       Include latest N days with data (default: 7)
  --out FILE     Markdown report output path
  --json-out FILE Optional JSON report output path
  --source FILE  Telemetry TSV source (default: .Rayman/runtime/telemetry/rules_runs.tsv)
TXT
}

json_escape() {
  printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g' -e ':a;N;$!ba;s/\n/\\n/g'
}

write_no_data_report() {
  local reason="$1"
  local generated_at
  generated_at="$(date -Iseconds)"
  mkdir -p "$(dirname "${out_file}")"
  {
    echo "# Rayman Daily Trend"
    echo
    echo "- generated_at: ${generated_at}"
    echo "- source: ${telemetry_file}"
    echo "- window_days: ${days}"
    echo
    echo "No telemetry data available (${reason})."
  } > "${out_file}"

  if [[ -n "${json_out}" ]]; then
    mkdir -p "$(dirname "${json_out}")"
    local reason_esc source_esc out_esc
    reason_esc="$(json_escape "${reason}")"
    source_esc="$(json_escape "${telemetry_file}")"
    out_esc="$(json_escape "${out_file}")"
    cat > "${json_out}" <<JSON
{"schema":"rayman.telemetry.trend.v1","generated_at":"${generated_at}","source":"${source_esc}","report":"${out_esc}","window_days":${days},"has_data":false,"reason":"${reason_esc}","summary":{"total":0,"ok":0,"fail":0,"fail_rate":0.0,"avg_ms":0},"daily":[],"top_failing_commands":[]}
JSON
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)
      days="${2:-7}"
      shift 2
      ;;
    --out)
      out_file="${2:-${out_file}}"
      shift 2
      ;;
    --json-out)
      json_out="${2:-}"
      shift 2
      ;;
    --source)
      telemetry_file="${2:-${telemetry_file}}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[trend] unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! "${days}" =~ ^[1-9][0-9]*$ ]]; then
  echo "[trend] invalid --days: ${days}" >&2
  exit 2
fi

if [[ ! -f "${telemetry_file}" ]]; then
  write_no_data_report "telemetry file missing"
  echo "[trend] report=${out_file}"
  [[ -n "${json_out}" ]] && echo "[trend] json=${json_out}"
  exit 0
fi

rows_tsv="$(mktemp)"
dates_tsv="$(mktemp)"
selected_dates_tsv="$(mktemp)"
stats_tsv="$(mktemp)"
top_fail_tsv="$(mktemp)"
trap 'rm -f "${rows_tsv}" "${dates_tsv}" "${selected_dates_tsv}" "${stats_tsv}" "${top_fail_tsv}"' EXIT

awk -F'\t' '
  NR==1 && $1=="ts_iso" { next }
  NF>=9 {
    day=substr($1,1,10)
    if (day ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) {
      print day "\t" $6 "\t" ($8+0) "\t" $9
    }
  }
' "${telemetry_file}" > "${rows_tsv}"

if [[ ! -s "${rows_tsv}" ]]; then
  write_no_data_report "no valid telemetry rows"
  echo "[trend] report=${out_file}"
  [[ -n "${json_out}" ]] && echo "[trend] json=${json_out}"
  exit 0
fi

awk -F'\t' '{print $1}' "${rows_tsv}" | sort -u > "${dates_tsv}"
tail -n "${days}" "${dates_tsv}" > "${selected_dates_tsv}"

while IFS= read -r day; do
  [[ -n "${day}" ]] || continue
  awk -F'\t' -v d="${day}" '
    $1==d {
      total++
      if ($2=="OK") ok++
      dur += ($3+0)
    }
    END {
      if (total>0) {
        fail = total - ok
        rate = (fail*100.0)/total
        avg = dur/total
        printf "%s\t%d\t%d\t%d\t%.1f\t%.0f\n", d, total, ok, fail, rate, avg
      }
    }
  ' "${rows_tsv}" >> "${stats_tsv}"
done < "${selected_dates_tsv}"

if [[ ! -s "${stats_tsv}" ]]; then
  write_no_data_report "no rows in selected window"
  echo "[trend] report=${out_file}"
  [[ -n "${json_out}" ]] && echo "[trend] json=${json_out}"
  exit 0
fi

window_total="$(awk -F'\t' '{s+=$2} END {print s+0}' "${stats_tsv}")"
window_ok="$(awk -F'\t' '{s+=$3} END {print s+0}' "${stats_tsv}")"
window_fail="$(awk -F'\t' '{s+=$4} END {print s+0}' "${stats_tsv}")"
window_avg_ms="$(awk -F'\t' '
  { dur += ($6 * $2); total += $2 }
  END { if (total==0) print 0; else printf "%.0f", dur/total }
' "${stats_tsv}")"
window_fail_rate="$(awk -v fail="${window_fail}" -v total="${window_total}" 'BEGIN { if (total==0) print "0.0"; else printf "%.1f", (fail*100.0)/total }')"

awk -F'\t' '
  NR==FNR { keep[$1]=1; next }
  keep[$1] && $2!="OK" { c[$4]++ }
  END { for (k in c) printf "%d\t%s\n", c[k], k }
' "${selected_dates_tsv}" "${rows_tsv}" | sort -t $'\t' -k1,1nr | head -n 5 > "${top_fail_tsv}"

mkdir -p "$(dirname "${out_file}")"
{
  echo "# Rayman Daily Trend"
  echo
  echo "- generated_at: $(date -Iseconds)"
  echo "- source: ${telemetry_file}"
  echo "- window_days: ${days}"
  echo "- window_records: ${window_total}"
  echo "- window_fail_rate: ${window_fail_rate}%"
  echo "- window_avg_ms: ${window_avg_ms}"
  echo
  echo "| date | total | ok | fail | fail_rate | avg_ms |"
  echo "| --- | ---: | ---: | ---: | ---: | ---: |"
  while IFS=$'\t' read -r d t o f r a; do
    printf "| %s | %s | %s | %s | %s%% | %s |\n" "${d}" "${t}" "${o}" "${f}" "${r}" "${a}"
  done < "${stats_tsv}"
  echo
  echo "## Top Failing Commands (window)"
  if [[ -s "${top_fail_tsv}" ]]; then
    echo
    echo "| count | command |"
    echo "| ---: | --- |"
    while IFS=$'\t' read -r c cmd; do
      safe_cmd="${cmd//|/\\|}"
      printf '| %s | `%s` |\n' "${c}" "${safe_cmd}"
    done < "${top_fail_tsv}"
  else
    echo
    echo "- (none)"
  fi
} > "${out_file}"

if [[ -n "${json_out}" ]]; then
  mkdir -p "$(dirname "${json_out}")"
  daily_json="["
  comma=""
  while IFS=$'\t' read -r d t o f r a; do
    d_esc="$(json_escape "${d}")"
    daily_json+="${comma}{\"date\":\"${d_esc}\",\"total\":${t},\"ok\":${o},\"fail\":${f},\"fail_rate\":${r},\"avg_ms\":${a}}"
    comma=","
  done < "${stats_tsv}"
  daily_json+="]"

  top_fail_json="["
  comma=""
  while IFS=$'\t' read -r c cmd; do
    [[ -n "${c:-}" ]] || continue
    cmd_esc="$(json_escape "${cmd}")"
    top_fail_json+="${comma}{\"count\":${c},\"command\":\"${cmd_esc}\"}"
    comma=","
  done < "${top_fail_tsv}"
  top_fail_json+="]"

  source_esc="$(json_escape "${telemetry_file}")"
  out_esc="$(json_escape "${out_file}")"
  generated_at="$(date -Iseconds)"
  cat > "${json_out}" <<JSON
{"schema":"rayman.telemetry.trend.v1","generated_at":"${generated_at}","source":"${source_esc}","report":"${out_esc}","window_days":${days},"has_data":true,"summary":{"total":${window_total},"ok":${window_ok},"fail":${window_fail},"fail_rate":${window_fail_rate},"avg_ms":${window_avg_ms}},"daily":${daily_json},"top_failing_commands":${top_fail_json}}
JSON
fi

echo "[trend] report=${out_file}"
if [[ -n "${json_out}" ]]; then
  echo "[trend] json=${json_out}"
fi
