#!/usr/bin/env bash
set -euo pipefail

kind=""
target=""

usage() {
  cat <<'TXT'
Usage:
  bash ./.Rayman/scripts/telemetry/validate_json.sh --kind metrics --file <path>
  bash ./.Rayman/scripts/telemetry/validate_json.sh --kind trend --file <path>
  bash ./.Rayman/scripts/telemetry/validate_json.sh --kind baseline --file <path>
  bash ./.Rayman/scripts/telemetry/validate_json.sh --kind first-pass --file <path>
  bash ./.Rayman/scripts/telemetry/validate_json.sh --kind manifest --file <path>
  bash ./.Rayman/scripts/telemetry/validate_json.sh --kind index --file <path>
TXT
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kind)
      kind="${2:-}"
      shift 2
      ;;
    --file)
      target="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[telemetry-validate] unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "${kind}" in
  metrics|trend|baseline|first-pass|manifest|index)
    ;;
  *)
    echo "[telemetry-validate] --kind must be metrics|trend|baseline|first-pass|manifest|index" >&2
    exit 2
    ;;
esac

if [[ -z "${target}" || ! -f "${target}" ]]; then
  echo "[telemetry-validate] missing --file or file not found: ${target}" >&2
  exit 2
fi

py_bin=""
if command -v python3 >/dev/null 2>&1; then
  py_bin="python3"
elif command -v python >/dev/null 2>&1; then
  py_bin="python"
else
  echo "[telemetry-validate] requires python3/python for JSON validation" >&2
  exit 2
fi

"${py_bin}" - "${kind}" "${target}" <<'PY'
import json
import os
import sys

kind = sys.argv[1]
path = sys.argv[2]

errors = []

def err(msg):
    errors.append(msg)

def is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)

def require_key(obj, key, where):
    if not isinstance(obj, dict):
        err(f"{where} should be object")
        return None
    if key not in obj:
        err(f"missing key: {where}.{key}")
        return None
    return obj[key]

def require_str(obj, key, where):
    v = require_key(obj, key, where)
    if v is not None and not isinstance(v, str):
        err(f"{where}.{key} should be string")
    return v

def require_bool(obj, key, where):
    v = require_key(obj, key, where)
    if v is not None and not isinstance(v, bool):
        err(f"{where}.{key} should be boolean")
    return v

def require_num(obj, key, where):
    v = require_key(obj, key, where)
    if v is not None and not is_number(v):
        err(f"{where}.{key} should be number")
    return v

def require_int(obj, key, where):
    v = require_key(obj, key, where)
    if v is not None and not isinstance(v, int):
        err(f"{where}.{key} should be integer")
    return v

def require_enum_str(obj, key, where, options):
    v = require_str(obj, key, where)
    if isinstance(v, str) and v not in options:
        err(f"{where}.{key} should be one of {options}")
    return v

def require_nonneg_int(obj, key, where):
    v = require_int(obj, key, where)
    if isinstance(v, int) and v < 0:
        err(f"{where}.{key} must be >= 0")
    return v

def require_nonneg_num(obj, key, where):
    v = require_num(obj, key, where)
    if is_number(v) and float(v) < 0:
        err(f"{where}.{key} must be >= 0")
    return v

try:
    with open(path, "r", encoding="utf-8") as f:
        payload = json.load(f)
except Exception as ex:
    print(f"[telemetry-validate] invalid json: {path}: {ex}", file=sys.stderr)
    sys.exit(3)

if not isinstance(payload, dict):
    print(f"[telemetry-validate] top-level must be object: {path}", file=sys.stderr)
    sys.exit(3)

if kind == "metrics":
    schema = require_str(payload, "schema", "root")
    if schema is not None and schema != "rayman.telemetry.metrics.v1":
        err("root.schema must be rayman.telemetry.metrics.v1")
    require_str(payload, "generated_at", "root")
    require_str(payload, "source", "root")
    has_data = require_bool(payload, "has_data", "root")

    filter_obj = require_key(payload, "filter", "root")
    if isinstance(filter_obj, dict):
        ftype = require_str(filter_obj, "type", "root.filter")
        if ftype is not None and ftype not in ("latest", "run_id"):
            err("root.filter.type must be latest or run_id")
        require_str(filter_obj, "value", "root.filter")

    summary = require_key(payload, "summary", "root")
    if isinstance(summary, dict):
        for k in ("total", "ok", "fail"):
            v = require_int(summary, k, "root.summary")
            if isinstance(v, int) and v < 0:
                err(f"root.summary.{k} must be >= 0")
        for k in ("success_rate", "fail_rate", "avg_ms"):
            v = require_num(summary, k, "root.summary")
            if is_number(v) and k != "avg_ms" and not (0 <= float(v) <= 100):
                err(f"root.summary.{k} must be in [0,100]")
            if is_number(v) and k == "avg_ms" and float(v) < 0:
                err("root.summary.avg_ms must be >= 0")

    prof = require_key(payload, "profile_summary", "root")
    if prof is not None and not isinstance(prof, list):
        err("root.profile_summary should be array")
    if isinstance(prof, list):
        for i, item in enumerate(prof):
            where = f"root.profile_summary[{i}]"
            if not isinstance(item, dict):
                err(f"{where} should be object")
                continue
            require_str(item, "profile", where)
            for k in ("total", "ok", "fail"):
                require_int(item, k, where)
            require_num(item, "ok_rate", where)
            require_num(item, "avg_ms", where)

    top = require_key(payload, "top_failing_commands", "root")
    if top is not None and not isinstance(top, list):
        err("root.top_failing_commands should be array")
    if isinstance(top, list):
        for i, item in enumerate(top):
            where = f"root.top_failing_commands[{i}]"
            if not isinstance(item, dict):
                err(f"{where} should be object")
                continue
            c = require_int(item, "count", where)
            if isinstance(c, int) and c < 1:
                err(f"{where}.count must be >= 1")
            require_str(item, "command", where)

    recent = require_key(payload, "recent_failures", "root")
    if recent is not None and not isinstance(recent, list):
        err("root.recent_failures should be array")
    if isinstance(recent, list):
        for i, item in enumerate(recent):
            where = f"root.recent_failures[{i}]"
            if not isinstance(item, dict):
                err(f"{where} should be object")
                continue
            require_str(item, "ts_iso", where)
            require_str(item, "profile", where)
            require_str(item, "status", where)
            require_int(item, "exit_code", where)
            d = require_num(item, "duration_ms", where)
            if is_number(d) and float(d) < 0:
                err(f"{where}.duration_ms must be >= 0")
            require_str(item, "command", where)

    assertions = require_key(payload, "assertions", "root")
    if isinstance(assertions, dict):
        for k in ("max_fail_rate", "max_avg_ms"):
            if k not in assertions:
                err(f"missing key: root.assertions.{k}")
            else:
                v = assertions[k]
                if v is not None and not is_number(v):
                    err(f"root.assertions.{k} should be number or null")
        require_bool(assertions, "failed", "root.assertions")

    if isinstance(has_data, bool) and not has_data:
        msg = payload.get("message")
        if msg is not None and not isinstance(msg, str):
            err("root.message should be string when present")

elif kind == "trend":
    schema = require_str(payload, "schema", "root")
    if schema is not None and schema != "rayman.telemetry.trend.v1":
        err("root.schema must be rayman.telemetry.trend.v1")
    require_str(payload, "generated_at", "root")
    require_str(payload, "source", "root")
    require_str(payload, "report", "root")
    wd = require_int(payload, "window_days", "root")
    if isinstance(wd, int) and wd < 1:
        err("root.window_days must be >= 1")
    has_data = require_bool(payload, "has_data", "root")

    summary = require_key(payload, "summary", "root")
    if isinstance(summary, dict):
        for k in ("total", "ok", "fail"):
            v = require_int(summary, k, "root.summary")
            if isinstance(v, int) and v < 0:
                err(f"root.summary.{k} must be >= 0")
        fr = require_num(summary, "fail_rate", "root.summary")
        if is_number(fr) and not (0 <= float(fr) <= 100):
            err("root.summary.fail_rate must be in [0,100]")
        am = require_num(summary, "avg_ms", "root.summary")
        if is_number(am) and float(am) < 0:
            err("root.summary.avg_ms must be >= 0")

    daily = require_key(payload, "daily", "root")
    if daily is not None and not isinstance(daily, list):
        err("root.daily should be array")
    if isinstance(daily, list):
        for i, item in enumerate(daily):
            where = f"root.daily[{i}]"
            if not isinstance(item, dict):
                err(f"{where} should be object")
                continue
            require_str(item, "date", where)
            for k in ("total", "ok", "fail"):
                require_int(item, k, where)
            fr = require_num(item, "fail_rate", where)
            if is_number(fr) and not (0 <= float(fr) <= 100):
                err(f"{where}.fail_rate must be in [0,100]")
            am = require_num(item, "avg_ms", where)
            if is_number(am) and float(am) < 0:
                err(f"{where}.avg_ms must be >= 0")

    top = require_key(payload, "top_failing_commands", "root")
    if top is not None and not isinstance(top, list):
        err("root.top_failing_commands should be array")
    if isinstance(top, list):
        for i, item in enumerate(top):
            where = f"root.top_failing_commands[{i}]"
            if not isinstance(item, dict):
                err(f"{where} should be object")
                continue
            c = require_int(item, "count", where)
            if isinstance(c, int) and c < 1:
                err(f"{where}.count must be >= 1")
            require_str(item, "command", where)

    if isinstance(has_data, bool) and not has_data:
        reason = payload.get("reason")
        if reason is not None and not isinstance(reason, str):
            err("root.reason should be string when present")

elif kind == "baseline":
    schema = require_str(payload, "schema", "root")
    if schema is not None and schema != "rayman.telemetry.baseline_guard.v1":
        err("root.schema must be rayman.telemetry.baseline_guard.v1")
    require_str(payload, "generated_at", "root")
    require_str(payload, "source", "root")
    require_enum_str(payload, "status", "root", ("PASS", "WARN", "BLOCK", "INSUFFICIENT_BASELINE"))
    reason = payload.get("reason")
    if reason is not None and not isinstance(reason, str):
        err("root.reason should be string when present")
    require_bool(payload, "report_only", "root")
    require_nonneg_int(payload, "baseline_days_used", "root")

    cfg = require_key(payload, "config", "root")
    if isinstance(cfg, dict):
        for k in ("recent_days", "baseline_days", "min_baseline_days"):
            v = require_int(cfg, k, "root.config")
            if isinstance(v, int) and v < 1:
                err(f"root.config.{k} must be >= 1")
        for k in ("warn_fail_rate_delta", "warn_avg_ms_delta", "block_fail_rate_delta", "block_avg_ms_delta"):
            require_num(cfg, k, "root.config")

    for scope in ("recent", "baseline"):
        part = require_key(payload, scope, "root")
        if isinstance(part, dict):
            for k in ("total", "ok", "fail"):
                require_nonneg_int(part, k, f"root.{scope}")
            fr = require_num(part, "fail_rate", f"root.{scope}")
            if is_number(fr) and not (0 <= float(fr) <= 100):
                err(f"root.{scope}.fail_rate must be in [0,100]")
            require_nonneg_num(part, "avg_ms", f"root.{scope}")

    delta = require_key(payload, "delta", "root")
    if isinstance(delta, dict):
        require_num(delta, "fail_rate", "root.delta")
        require_num(delta, "avg_ms", "root.delta")

elif kind == "first-pass":
    schema = require_str(payload, "schema", "root")
    if schema is not None and schema != "rayman.telemetry.first_pass.v1":
        err("root.schema must be rayman.telemetry.first_pass.v1")
    require_str(payload, "generated_at", "root")
    require_str(payload, "source", "root")
    require_str(payload, "report", "root")
    wd = require_int(payload, "window", "root")
    if isinstance(wd, int) and wd < 1:
        err("root.window must be >= 1")
    has_data = require_bool(payload, "has_data", "root")

    summary = require_key(payload, "summary", "root")
    if isinstance(summary, dict):
        for k in ("total", "pass", "fail", "current_pass_streak"):
            require_nonneg_int(summary, k, "root.summary")
        fr = require_num(summary, "first_pass_rate", "root.summary")
        if is_number(fr) and not (0 <= float(fr) <= 100):
            err("root.summary.first_pass_rate must be in [0,100]")
        require_nonneg_num(summary, "avg_duration_ms", "root.summary")

    status = payload.get("status")
    if status is not None and status not in ("PASS", "WARN", "BLOCK"):
        err("root.status should be PASS|WARN|BLOCK when present")

    baseline = payload.get("baseline")
    if baseline is not None:
        if not isinstance(baseline, dict):
            err("root.baseline should be object when present")
        else:
            for k in ("recent_days", "baseline_days"):
                v = baseline.get(k)
                if v is not None and (not isinstance(v, int) or v < 1):
                    err(f"root.baseline.{k} should be integer >= 1")
            for k in ("recent_rate", "baseline_rate"):
                v = baseline.get(k)
                if v is not None and (not is_number(v) or not (0 <= float(v) <= 100)):
                    err(f"root.baseline.{k} should be number in [0,100]")
            v = baseline.get("delta_rate")
            if v is not None and not is_number(v):
                err("root.baseline.delta_rate should be number")

    dist = payload.get("backend_distribution")
    if dist is not None:
        if not isinstance(dist, list):
            err("root.backend_distribution should be array")
        else:
            for i, item in enumerate(dist):
                where = f"root.backend_distribution[{i}]"
                if not isinstance(item, dict):
                    err(f"{where} should be object")
                    continue
                require_str(item, "backend", where)
                require_nonneg_int(item, "count", where)

    if isinstance(has_data, bool) and not has_data:
        if status is not None:
            err("root.status should be absent when has_data=false")

elif kind == "manifest":
    schema = require_str(payload, "schema", "root")
    if schema is not None and schema != "rayman.telemetry.artifact_bundle.v1":
        err("root.schema must be rayman.telemetry.artifact_bundle.v1")
    require_str(payload, "generated_at", "root")
    require_str(payload, "bundle_id", "root")
    require_str(payload, "bundle_dir", "root")
    ml = require_int(payload, "metrics_limit", "root")
    if isinstance(ml, int) and ml < 1:
        err("root.metrics_limit must be >= 1")
    td = require_int(payload, "trend_days", "root")
    if isinstance(td, int) and td < 1:
        err("root.trend_days must be >= 1")

    baseline = require_key(payload, "baseline", "root")
    if isinstance(baseline, dict):
        en = require_int(baseline, "enabled", "root.baseline")
        if isinstance(en, int) and en not in (0, 1):
            err("root.baseline.enabled must be 0 or 1")
        ro = require_int(baseline, "report_only", "root.baseline")
        if isinstance(ro, int) and ro not in (0, 1):
            err("root.baseline.report_only must be 0 or 1")
        require_str(baseline, "status", "root.baseline")
        require_nonneg_int(baseline, "rc", "root.baseline")

    files = require_key(payload, "files", "root")
    required_names = {"metrics.json", "daily_trend.json", "manifest.json"}
    seen_names = set()
    if files is not None and not isinstance(files, list):
        err("root.files should be array")
    if isinstance(files, list):
        for i, item in enumerate(files):
            where = f"root.files[{i}]"
            if not isinstance(item, dict):
                err(f"{where} should be object")
                continue
            name = require_str(item, "name", where)
            path = require_str(item, "path", where)
            if isinstance(name, str):
                seen_names.add(name)
                if not name.strip():
                    err(f"{where}.name should not be empty")
            if isinstance(path, str) and not path.strip():
                err(f"{where}.path should not be empty")
    missing = sorted(required_names - seen_names)
    if missing:
        err(f"root.files missing required names: {missing}")

elif kind == "index":
    schema = require_str(payload, "schema", "root")
    if schema is not None and schema != "rayman.telemetry.artifact_index.v1":
        err("root.schema must be rayman.telemetry.artifact_index.v1")
    require_str(payload, "generated_at", "root")
    require_str(payload, "out_root", "root")
    total_bundles = require_nonneg_int(payload, "total_bundles", "root")

    bundles = require_key(payload, "bundles", "root")
    if bundles is not None and not isinstance(bundles, list):
        err("root.bundles should be array")
        bundles = []

    if isinstance(bundles, list):
        if isinstance(total_bundles, int) and total_bundles != len(bundles):
            err("root.total_bundles must equal len(root.bundles)")
        for i, item in enumerate(bundles):
            where = f"root.bundles[{i}]"
            if not isinstance(item, dict):
                err(f"{where} should be object")
                continue
            require_str(item, "bundle_id", where)
            require_str(item, "generated_at", where)
            require_str(item, "bundle_dir", where)
            require_str(item, "manifest_path", where)
            require_str(item, "baseline_status", where)
            require_nonneg_int(item, "baseline_rc", where)
            require_bool(item, "telemetry_source_missing", where)

            metrics = require_key(item, "metrics", where)
            if isinstance(metrics, dict):
                require_bool(metrics, "has_data", f"{where}.metrics")
                require_nonneg_int(metrics, "total", f"{where}.metrics")
                fr = require_num(metrics, "fail_rate", f"{where}.metrics")
                if is_number(fr) and not (0 <= float(fr) <= 100):
                    err(f"{where}.metrics.fail_rate must be in [0,100]")
                require_nonneg_num(metrics, "avg_ms", f"{where}.metrics")

            trend = require_key(item, "trend", where)
            if isinstance(trend, dict):
                require_bool(trend, "has_data", f"{where}.trend")
                wd = require_nonneg_int(trend, "window_days", f"{where}.trend")
                if isinstance(wd, int) and wd == 0 and trend.get("has_data") is True:
                    err(f"{where}.trend.window_days must be >= 1 when has_data=true")
                fr = require_num(trend, "fail_rate", f"{where}.trend")
                if is_number(fr) and not (0 <= float(fr) <= 100):
                    err(f"{where}.trend.fail_rate must be in [0,100]")
                require_nonneg_num(trend, "avg_ms", f"{where}.trend")

    summary = require_key(payload, "summary", "root")
    if isinstance(summary, dict):
        require_enum_str(summary, "risk_level", "root.summary", ("GREEN", "YELLOW", "RED", "UNKNOWN"))

        anomaly_flags = require_key(summary, "anomaly_flags", "root.summary")
        if anomaly_flags is not None and not isinstance(anomaly_flags, list):
            err("root.summary.anomaly_flags should be array")
        if isinstance(anomaly_flags, list):
            seen = set()
            for i, flag in enumerate(anomaly_flags):
                where = f"root.summary.anomaly_flags[{i}]"
                if not isinstance(flag, str):
                    err(f"{where} should be string")
                    continue
                if not flag.strip():
                    err(f"{where} should not be empty")
                if flag in seen:
                    err(f"{where} duplicated flag: {flag}")
                seen.add(flag)

        thresholds = require_key(summary, "thresholds", "root.summary")
        if isinstance(thresholds, dict):
            for k in ("warn_fail_rate", "warn_avg_ms", "block_fail_rate", "block_avg_ms"):
                require_nonneg_num(thresholds, k, "root.summary.thresholds")
            stale_hours = require_num(thresholds, "stale_hours", "root.summary.thresholds")
            if is_number(stale_hours) and float(stale_hours) < 1:
                err("root.summary.thresholds.stale_hours must be >= 1")

        counts = require_key(summary, "baseline_status_counts", "root.summary")
        if isinstance(counts, dict):
            for k in ("pass", "warn", "block", "insufficient_baseline", "unknown"):
                require_nonneg_int(counts, k, "root.summary.baseline_status_counts")
            if isinstance(total_bundles, int):
                csum = 0
                for k in ("pass", "warn", "block", "insufficient_baseline", "unknown"):
                    v = counts.get(k)
                    if isinstance(v, int):
                        csum += v
                if csum != total_bundles:
                    err("sum(root.summary.baseline_status_counts.*) must equal root.total_bundles")

        latest = require_key(summary, "latest_bundle", "root.summary")
        if isinstance(latest, dict):
            exists = require_bool(latest, "exists", "root.summary.latest_bundle")
            bundle_id = require_str(latest, "bundle_id", "root.summary.latest_bundle")
            generated = require_str(latest, "generated_at", "root.summary.latest_bundle")
            age_hours = require_num(latest, "age_hours", "root.summary.latest_bundle")
            if is_number(age_hours) and float(age_hours) < -1:
                err("root.summary.latest_bundle.age_hours must be >= -1")

            require_str(latest, "baseline_status", "root.summary.latest_bundle")
            require_bool(latest, "telemetry_source_missing", "root.summary.latest_bundle")
            require_bool(latest, "metrics_has_data", "root.summary.latest_bundle")
            mf = require_num(latest, "metrics_fail_rate", "root.summary.latest_bundle")
            if is_number(mf) and not (0 <= float(mf) <= 100):
                err("root.summary.latest_bundle.metrics_fail_rate must be in [0,100]")
            require_nonneg_num(latest, "metrics_avg_ms", "root.summary.latest_bundle")
            require_bool(latest, "trend_has_data", "root.summary.latest_bundle")
            tf = require_num(latest, "trend_fail_rate", "root.summary.latest_bundle")
            if is_number(tf) and not (0 <= float(tf) <= 100):
                err("root.summary.latest_bundle.trend_fail_rate must be in [0,100]")
            require_nonneg_num(latest, "trend_avg_ms", "root.summary.latest_bundle")

            if exists is True:
                if isinstance(bundle_id, str) and not bundle_id.strip():
                    err("root.summary.latest_bundle.bundle_id should not be empty when exists=true")
                if isinstance(generated, str) and not generated.strip():
                    err("root.summary.latest_bundle.generated_at should not be empty when exists=true")
                if is_number(age_hours) and float(age_hours) < 0:
                    err("root.summary.latest_bundle.age_hours must be >= 0 when exists=true")
            if exists is False:
                if is_number(age_hours) and float(age_hours) != -1:
                    err("root.summary.latest_bundle.age_hours should be -1 when exists=false")

if errors:
    print(f"[telemetry-validate] FAIL kind={kind} file={path}", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(3)

print(f"[telemetry-validate] OK kind={kind} file={path}")
PY
