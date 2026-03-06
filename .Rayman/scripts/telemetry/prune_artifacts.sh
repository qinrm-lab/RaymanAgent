#!/usr/bin/env bash
set -euo pipefail

out_root=".Rayman/runtime/artifacts/telemetry"
keep=20
max_age_days=0
dry_run=0
index_file=""
validate=1

usage() {
  cat <<'TXT'
Usage:
  bash ./.Rayman/scripts/telemetry/prune_artifacts.sh [options]

Options:
  --out-root DIR         Telemetry artifact root (default: .Rayman/runtime/artifacts/telemetry)
  --keep N               Keep newest N bundles (0 means unlimited; default: 20)
  --max-age-days N       Delete bundles older than N days (0 means disabled; default: 0)
  --dry-run 0|1          Print deletions without deleting files (default: 0)
  --index-file FILE      Index output file (default: <out-root>/index.json)
  --validate 0|1         Validate index after prune (default: 1)
TXT
}

is_flag() { [[ "${1:-}" == "0" || "${1:-}" == "1" ]]; }
is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-root) out_root="${2:-}"; shift 2 ;;
    --keep) keep="${2:-}"; shift 2 ;;
    --max-age-days) max_age_days="${2:-}"; shift 2 ;;
    --dry-run) dry_run="${2:-}"; shift 2 ;;
    --index-file) index_file="${2:-}"; shift 2 ;;
    --validate) validate="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[telemetry-prune] unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for v in "${keep}" "${max_age_days}"; do
  if ! is_uint "${v}"; then
    echo "[telemetry-prune] numeric option must be >= 0: ${v}" >&2
    exit 2
  fi
done

for v in "${dry_run}" "${validate}"; do
  if ! is_flag "${v}"; then
    echo "[telemetry-prune] flag option must be 0 or 1: ${v}" >&2
    exit 2
  fi
done

if [[ -z "${index_file}" ]]; then
  index_file="${out_root}/index.json"
fi

mkdir -p "${out_root}" "$(dirname "${index_file}")"

py_bin=""
if command -v python3 >/dev/null 2>&1; then
  py_bin="python3"
elif command -v python >/dev/null 2>&1; then
  py_bin="python"
else
  echo "[telemetry-prune] requires python3/python" >&2
  exit 2
fi

mapfile -t rows < <(
  "${py_bin}" - "${out_root}" <<'PY'
import datetime as dt
import json
import os
import sys

out_root = sys.argv[1]
now = dt.datetime.now(dt.timezone.utc)

def parse_generated_at(v):
    if not isinstance(v, str) or not v:
        return None
    try:
        vv = v.replace("Z", "+00:00")
        d = dt.datetime.fromisoformat(vv)
        if d.tzinfo is None:
            d = d.replace(tzinfo=dt.timezone.utc)
        return d
    except Exception:
        return None

items = []
if os.path.isdir(out_root):
    for name in os.listdir(out_root):
        path = os.path.join(out_root, name)
        if not os.path.isdir(path):
            continue
        manifest = os.path.join(path, "manifest.json")
        if not os.path.isfile(manifest):
            continue

        generated = None
        bundle_id = name
        try:
            with open(manifest, "r", encoding="utf-8") as f:
                data = json.load(f)
            generated = parse_generated_at(data.get("generated_at"))
            if isinstance(data.get("bundle_id"), str) and data.get("bundle_id"):
                bundle_id = data["bundle_id"]
        except Exception:
            generated = None

        if generated is None:
            generated = dt.datetime.fromtimestamp(os.path.getmtime(manifest), dt.timezone.utc)

        age_days = int((now - generated).total_seconds() // 86400)
        items.append((generated, path, bundle_id, age_days))

items.sort(key=lambda x: x[0], reverse=True)
for generated, path, bundle_id, age_days in items:
    print(
        f"{path}\t{bundle_id}\t{generated.isoformat()}\t{age_days}"
    )
PY
)

if [[ "${#rows[@]}" -eq 0 ]]; then
  if [[ "${dry_run}" == "0" ]]; then
    rm -f "${out_root}/latest.txt" 2>/dev/null || true
  fi
  bash ./.Rayman/scripts/telemetry/index_artifacts.sh --out-root "${out_root}" --index-file "${index_file}" --validate "${validate}"
  echo "[telemetry-prune] no bundle directories found"
  exit 0
fi

removed=0
removed_tars=0
kept=0
latest_bundle=""
rank=0

for row in "${rows[@]}"; do
  rank=$((rank + 1))
  IFS=$'\t' read -r bundle_path bundle_id generated_at age_days <<< "${row}"
  [[ -n "${bundle_path}" && -n "${bundle_id}" ]] || continue

  delete=0
  reason=""
  if [[ "${keep}" -gt 0 && "${rank}" -gt "${keep}" ]]; then
    delete=1
    reason="rank>${keep}"
  fi
  if [[ "${max_age_days}" -gt 0 && "${age_days}" -gt "${max_age_days}" ]]; then
    delete=1
    if [[ -n "${reason}" ]]; then
      reason="${reason},age>${max_age_days}d"
    else
      reason="age>${max_age_days}d"
    fi
  fi

  if [[ "${delete}" -eq 1 ]]; then
    if [[ "${dry_run}" == "1" ]]; then
      echo "[telemetry-prune] dry-run delete bundle=${bundle_id} path=${bundle_path} generated_at=${generated_at} reason=${reason}"
    else
      rm -rf "${bundle_path}"
      removed=$((removed + 1))
      tar_path="${out_root}/telemetry-${bundle_id}.tar.gz"
      if [[ -f "${tar_path}" ]]; then
        rm -f "${tar_path}"
        removed_tars=$((removed_tars + 1))
      fi
      echo "[telemetry-prune] deleted bundle=${bundle_id} path=${bundle_path} reason=${reason}"
    fi
  else
    kept=$((kept + 1))
    if [[ -z "${latest_bundle}" ]]; then
      latest_bundle="${bundle_id}"
    fi
  fi
done

if [[ "${dry_run}" == "0" ]]; then
  if [[ -n "${latest_bundle}" ]]; then
    echo "${latest_bundle}" > "${out_root}/latest.txt"
  else
    rm -f "${out_root}/latest.txt" 2>/dev/null || true
  fi
fi

bash ./.Rayman/scripts/telemetry/index_artifacts.sh --out-root "${out_root}" --index-file "${index_file}" --validate "${validate}"

if [[ "${dry_run}" == "1" ]]; then
  echo "[telemetry-prune] dry-run complete keep=${keep} max_age_days=${max_age_days}"
else
  echo "[telemetry-prune] removed_bundles=${removed} removed_tars=${removed_tars} kept=${kept}"
fi
