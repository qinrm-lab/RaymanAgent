#!/usr/bin/env bash
set -euo pipefail

out_root=".Rayman/runtime/artifacts/telemetry"
index_file=""
validate=1
max_bundles=0

usage() {
  cat <<'TXT'
Usage:
  bash ./.Rayman/scripts/telemetry/index_artifacts.sh [options]

Options:
  --out-root DIR         Telemetry artifact root (default: .Rayman/runtime/artifacts/telemetry)
  --index-file FILE      Index output file (default: <out-root>/index.json)
  --validate 0|1         Validate manifest + referenced JSON (default: 1)
  --max-bundles N        Limit index size (0 means all; default: 0)
TXT
}

is_flag() { [[ "${1:-}" == "0" || "${1:-}" == "1" ]]; }
is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-root) out_root="${2:-}"; shift 2 ;;
    --index-file) index_file="${2:-}"; shift 2 ;;
    --validate) validate="${2:-}"; shift 2 ;;
    --max-bundles) max_bundles="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[telemetry-index] unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! is_flag "${validate}"; then
  echo "[telemetry-index] --validate must be 0 or 1: ${validate}" >&2
  exit 2
fi

if ! is_uint "${max_bundles}"; then
  echo "[telemetry-index] --max-bundles must be >= 0: ${max_bundles}" >&2
  exit 2
fi

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
  echo "[telemetry-index] requires python3/python" >&2
  exit 2
fi

mapfile -t manifests < <(find "${out_root}" -mindepth 2 -maxdepth 2 -type f -name "manifest.json" 2>/dev/null | sort)

if [[ "${validate}" == "1" ]]; then
  for mf in "${manifests[@]}"; do
    bash ./.Rayman/scripts/telemetry/validate_json.sh --kind manifest --file "${mf}"
  done

  if [[ "${#manifests[@]}" -gt 0 ]]; then
    while IFS=$'\t' read -r kind path; do
      [[ -n "${kind}" && -n "${path}" ]] || continue
      [[ -f "${path}" ]] || continue
      bash ./.Rayman/scripts/telemetry/validate_json.sh --kind "${kind}" --file "${path}"
    done < <(
      "${py_bin}" - "${manifests[@]}" <<'PY'
import json
import os
import sys

seen = set()
for manifest_path in sys.argv[1:]:
    try:
        with open(manifest_path, "r", encoding="utf-8") as f:
            manifest = json.load(f)
    except Exception:
        continue
    bundle_dir = os.path.dirname(manifest_path)
    for item in manifest.get("files", []):
        if not isinstance(item, dict):
            continue
        name = item.get("name")
        path = item.get("path")
        if not isinstance(name, str) or not isinstance(path, str):
            continue
        abs_path = path if os.path.isabs(path) else os.path.join(bundle_dir, path)
        kind = None
        if name == "metrics.json":
            kind = "metrics"
        elif name == "daily_trend.json":
            kind = "trend"
        elif name == "baseline_guard.json":
            kind = "baseline"
        if kind is None:
            continue
        key = (kind, os.path.normpath(abs_path))
        if key in seen:
            continue
        seen.add(key)
        print(f"{kind}\t{key[1]}")
PY
    )
  fi
fi

generated_at="$(date -Iseconds)"

"${py_bin}" - "${out_root}" "${index_file}" "${generated_at}" "${max_bundles}" "${manifests[@]}" <<'PY'
import datetime as dt
import json
import os
import sys

out_root = sys.argv[1]
index_file = sys.argv[2]
generated_at = sys.argv[3]
max_bundles = int(sys.argv[4])
manifest_paths = sys.argv[5:]

def to_float(v, default=0.0):
    try:
        if isinstance(v, bool):
            return default
        return float(v)
    except Exception:
        return default

def to_int(v, default=0):
    try:
        if isinstance(v, bool):
            return default
        return int(v)
    except Exception:
        return default

def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None

items = []
for manifest_path in manifest_paths:
    manifest = load_json(manifest_path)
    if not isinstance(manifest, dict):
        continue

    bundle_fs_dir = os.path.dirname(manifest_path)
    bundle_id = manifest.get("bundle_id")
    if not isinstance(bundle_id, str) or not bundle_id:
        bundle_id = os.path.basename(bundle_fs_dir)

    item_generated_at = manifest.get("generated_at")
    if not isinstance(item_generated_at, str) or not item_generated_at:
        item_generated_at = dt.datetime.fromtimestamp(
            os.path.getmtime(manifest_path), dt.timezone.utc
        ).isoformat()

    file_map = {}
    for entry in manifest.get("files", []):
        if not isinstance(entry, dict):
            continue
        name = entry.get("name")
        path = entry.get("path")
        if not isinstance(name, str) or not isinstance(path, str):
            continue
        file_map[name] = path if os.path.isabs(path) else os.path.join(bundle_fs_dir, path)

    metrics = load_json(file_map.get("metrics.json", ""))
    trend = load_json(file_map.get("daily_trend.json", ""))
    baseline = load_json(file_map.get("baseline_guard.json", ""))

    metrics_summary = metrics.get("summary", {}) if isinstance(metrics, dict) else {}
    trend_summary = trend.get("summary", {}) if isinstance(trend, dict) else {}
    baseline_manifest = manifest.get("baseline", {}) if isinstance(manifest.get("baseline"), dict) else {}

    baseline_status = baseline_manifest.get("status")
    if not isinstance(baseline_status, str) or not baseline_status:
        baseline_status = baseline.get("status", "UNKNOWN") if isinstance(baseline, dict) else "UNKNOWN"

    baseline_rc = baseline_manifest.get("rc")
    if not isinstance(baseline_rc, int):
        baseline_rc = 0

    item = {
        "bundle_id": bundle_id,
        "generated_at": item_generated_at,
        "bundle_dir": manifest.get("bundle_dir", bundle_fs_dir) if isinstance(manifest.get("bundle_dir"), str) else bundle_fs_dir,
        "manifest_path": manifest_path,
        "baseline_status": baseline_status,
        "baseline_rc": baseline_rc,
        "metrics": {
            "has_data": bool(metrics.get("has_data")) if isinstance(metrics, dict) else False,
            "total": to_int(metrics_summary.get("total"), 0),
            "fail_rate": to_float(metrics_summary.get("fail_rate"), 0.0),
            "avg_ms": to_float(metrics_summary.get("avg_ms"), 0.0),
        },
        "trend": {
            "has_data": bool(trend.get("has_data")) if isinstance(trend, dict) else False,
            "window_days": to_int(trend.get("window_days"), 0) if isinstance(trend, dict) else 0,
            "fail_rate": to_float(trend_summary.get("fail_rate"), 0.0),
            "avg_ms": to_float(trend_summary.get("avg_ms"), 0.0),
        },
    }
    items.append(item)

def parse_iso(v):
    if not isinstance(v, str) or not v:
        return dt.datetime.fromtimestamp(0, dt.timezone.utc)
    try:
        vv = v.replace("Z", "+00:00")
        d = dt.datetime.fromisoformat(vv)
        if d.tzinfo is None:
            d = d.replace(tzinfo=dt.timezone.utc)
        return d
    except Exception:
        return dt.datetime.fromtimestamp(0, dt.timezone.utc)

items.sort(key=lambda x: (parse_iso(x.get("generated_at")), x.get("bundle_id", "")), reverse=True)
if max_bundles > 0:
    items = items[:max_bundles]

now_utc = dt.datetime.now(dt.timezone.utc)
thresholds = {
    "warn_fail_rate": 10.0,
    "warn_avg_ms": 8000.0,
    "block_fail_rate": 20.0,
    "block_avg_ms": 12000.0,
    "stale_hours": 24.0,
}
status_counts = {
    "pass": 0,
    "warn": 0,
    "block": 0,
    "insufficient_baseline": 0,
    "unknown": 0,
}
for item in items:
    s = str(item.get("baseline_status", "")).upper()
    if s == "PASS":
        status_counts["pass"] += 1
    elif s == "WARN":
        status_counts["warn"] += 1
    elif s == "BLOCK":
        status_counts["block"] += 1
    elif s == "INSUFFICIENT_BASELINE":
        status_counts["insufficient_baseline"] += 1
    else:
        status_counts["unknown"] += 1

if items:
    latest = items[0]
    latest_generated = parse_iso(latest.get("generated_at"))
    latest_age_hours = round(max((now_utc - latest_generated).total_seconds() / 3600.0, 0.0), 2)
    latest_bundle = {
        "exists": True,
        "bundle_id": str(latest.get("bundle_id", "")),
        "generated_at": str(latest.get("generated_at", "")),
        "age_hours": latest_age_hours,
        "baseline_status": str(latest.get("baseline_status", "UNKNOWN")),
        "metrics_has_data": bool(latest.get("metrics", {}).get("has_data", False)),
        "metrics_fail_rate": to_float(latest.get("metrics", {}).get("fail_rate"), 0.0),
        "metrics_avg_ms": to_float(latest.get("metrics", {}).get("avg_ms"), 0.0),
        "trend_has_data": bool(latest.get("trend", {}).get("has_data", False)),
        "trend_fail_rate": to_float(latest.get("trend", {}).get("fail_rate"), 0.0),
        "trend_avg_ms": to_float(latest.get("trend", {}).get("avg_ms"), 0.0),
    }
else:
    latest_bundle = {
        "exists": False,
        "bundle_id": "",
        "generated_at": "",
        "age_hours": -1.0,
        "baseline_status": "NONE",
        "metrics_has_data": False,
        "metrics_fail_rate": 0.0,
        "metrics_avg_ms": 0.0,
        "trend_has_data": False,
        "trend_fail_rate": 0.0,
        "trend_avg_ms": 0.0,
    }

anomaly_flags = []
risk_level = "GREEN"
if not latest_bundle["exists"]:
    risk_level = "UNKNOWN"
    anomaly_flags.append("NO_BUNDLES")
else:
    baseline_status = str(latest_bundle["baseline_status"]).upper()
    if baseline_status == "BLOCK":
        anomaly_flags.append("LATEST_BASELINE_BLOCK")
    elif baseline_status == "WARN":
        anomaly_flags.append("LATEST_BASELINE_WARN")
    elif baseline_status == "INSUFFICIENT_BASELINE":
        anomaly_flags.append("LATEST_BASELINE_INSUFFICIENT")
    elif baseline_status != "PASS":
        anomaly_flags.append("LATEST_BASELINE_UNKNOWN")

    if not latest_bundle["metrics_has_data"]:
        anomaly_flags.append("LATEST_METRICS_NO_DATA")
    if not latest_bundle["trend_has_data"]:
        anomaly_flags.append("LATEST_TREND_NO_DATA")

    if latest_bundle["metrics_fail_rate"] >= thresholds["block_fail_rate"]:
        anomaly_flags.append("LATEST_METRICS_FAIL_RATE_BLOCK")
    elif latest_bundle["metrics_fail_rate"] >= thresholds["warn_fail_rate"]:
        anomaly_flags.append("LATEST_METRICS_FAIL_RATE_WARN")

    if latest_bundle["metrics_avg_ms"] >= thresholds["block_avg_ms"]:
        anomaly_flags.append("LATEST_METRICS_AVG_MS_BLOCK")
    elif latest_bundle["metrics_avg_ms"] >= thresholds["warn_avg_ms"]:
        anomaly_flags.append("LATEST_METRICS_AVG_MS_WARN")

    if latest_bundle["trend_fail_rate"] >= thresholds["block_fail_rate"]:
        anomaly_flags.append("LATEST_TREND_FAIL_RATE_BLOCK")
    elif latest_bundle["trend_fail_rate"] >= thresholds["warn_fail_rate"]:
        anomaly_flags.append("LATEST_TREND_FAIL_RATE_WARN")

    if latest_bundle["trend_avg_ms"] >= thresholds["block_avg_ms"]:
        anomaly_flags.append("LATEST_TREND_AVG_MS_BLOCK")
    elif latest_bundle["trend_avg_ms"] >= thresholds["warn_avg_ms"]:
        anomaly_flags.append("LATEST_TREND_AVG_MS_WARN")

    if latest_bundle["age_hours"] > thresholds["stale_hours"]:
        anomaly_flags.append("LATEST_BUNDLE_STALE")

    red_prefixes = (
        "LATEST_BASELINE_BLOCK",
        "LATEST_METRICS_FAIL_RATE_BLOCK",
        "LATEST_METRICS_AVG_MS_BLOCK",
        "LATEST_TREND_FAIL_RATE_BLOCK",
        "LATEST_TREND_AVG_MS_BLOCK",
    )
    yellow_prefixes = (
        "LATEST_BASELINE_WARN",
        "LATEST_BASELINE_INSUFFICIENT",
        "LATEST_BASELINE_UNKNOWN",
        "LATEST_METRICS_FAIL_RATE_WARN",
        "LATEST_METRICS_AVG_MS_WARN",
        "LATEST_TREND_FAIL_RATE_WARN",
        "LATEST_TREND_AVG_MS_WARN",
        "LATEST_BUNDLE_STALE",
        "LATEST_METRICS_NO_DATA",
        "LATEST_TREND_NO_DATA",
    )
    if any(flag.startswith(red_prefixes) for flag in anomaly_flags):
        risk_level = "RED"
    elif any(flag.startswith(yellow_prefixes) for flag in anomaly_flags):
        risk_level = "YELLOW"
    else:
        risk_level = "GREEN"

summary = {
    "risk_level": risk_level,
    "anomaly_flags": sorted(set(anomaly_flags)),
    "thresholds": thresholds,
    "baseline_status_counts": status_counts,
    "latest_bundle": latest_bundle,
}

payload = {
    "schema": "rayman.telemetry.artifact_index.v1",
    "generated_at": generated_at,
    "out_root": out_root,
    "total_bundles": len(items),
    "bundles": items,
    "summary": summary,
}

with open(index_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, separators=(",", ":"))
PY

if [[ "${validate}" == "1" ]]; then
  bash ./.Rayman/scripts/telemetry/validate_json.sh --kind index --file "${index_file}"
fi

echo "[telemetry-index] out_root=${out_root}"
echo "[telemetry-index] manifests=${#manifests[@]}"
echo "[telemetry-index] index=${index_file}"
