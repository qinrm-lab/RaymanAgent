#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path

try:
    import jsonschema
except ImportError as exc:  # pragma: no cover - runtime dependency failure path
    raise SystemExit(
        "jsonschema is required for Rayman JSON contract validation. "
        "Install it with: python3 -m pip install jsonschema"
    ) from exc


SCRIPT_DIR = Path(__file__).resolve().parent
SCHEMA_DIR = SCRIPT_DIR / "schemas"
FIXTURE_DIR = SCRIPT_DIR / "fixtures" / "reports"

CONTRACTS = [
    {
        "name": "release_gate",
        "schema": "release_gate.v1.schema.json",
        "fixture": "release_gate.sample.json",
        "runtime": ".Rayman/state/release_gate_report.json",
    },
    {
        "name": "playwright_windows",
        "schema": "playwright_windows.v2.schema.json",
        "fixture": "playwright.ready.windows.sample.json",
        "runtime": ".Rayman/runtime/playwright.ready.windows.json",
    },
    {
        "name": "playwright_wsl",
        "schema": "playwright_wsl.v1.schema.json",
        "fixture": "playwright.ready.wsl.sample.json",
        "runtime": ".Rayman/runtime/playwright.ready.wsl.json",
    },
    {
        "name": "winapp_ready",
        "schema": "winapp_ready.v1.schema.json",
        "fixture": "winapp.ready.windows.sample.json",
        "runtime": ".Rayman/runtime/winapp.ready.windows.json",
    },
    {
        "name": "winapp_flow",
        "schema": "winapp_flow.v1.schema.json",
        "fixture": None,
        "runtime": ".Rayman/winapp.flow.sample.json",
    },
    {
        "name": "winapp_flow_result",
        "schema": "winapp_flow_result.v1.schema.json",
        "fixture": "winapp.last_result.sample.json",
        "runtime": ".Rayman/runtime/winapp-tests/last_result.json",
    },
    {
        "name": "agent_capabilities_report",
        "schema": "agent_capabilities_report.v1.schema.json",
        "fixture": "agent_capabilities.report.sample.json",
        "runtime": ".Rayman/runtime/agent_capabilities.report.json",
    },
    {
        "name": "project_gate",
        "schema": "project_gate.v1.schema.json",
        "fixture": "project_gate.fast.sample.json",
        "runtime": ".Rayman/runtime/project_gates/fast.report.json",
    },
    {
        "name": "codex_auth_status",
        "schema": "codex_auth_status.v1.schema.json",
        "fixture": "codex.auth.status.sample.json",
        "runtime": ".Rayman/runtime/codex.auth.status.json",
    },
]


def load_json(path: Path):
    with path.open("r", encoding="utf-8-sig") as handle:
        return json.load(handle)


def validate_document(schema_path: Path, data_path: Path):
    schema = load_json(schema_path)
    data = load_json(data_path)
    jsonschema.Draft202012Validator(schema).validate(data)


def validate_target(results, scope, name, schema_path, data_path):
    entry = {
        "scope": scope,
        "name": name,
        "schema_path": str(schema_path),
        "data_path": str(data_path),
        "status": "PASS",
        "error": "",
    }
    try:
        validate_document(schema_path, data_path)
    except Exception as exc:  # pragma: no cover - exercised by fixture/runtime failures
        entry["status"] = "FAIL"
        entry["error"] = str(exc)
    results.append(entry)


def main():
    parser = argparse.ArgumentParser(description="Validate Rayman JSON contracts.")
    parser.add_argument(
        "--workspace-root",
        default=str(Path.cwd()),
        help="Workspace root used to locate runtime JSON artifacts.",
    )
    parser.add_argument(
        "--mode",
        choices=("all", "fixtures", "runtime"),
        default="all",
        help="Whether to validate fixtures, runtime files, or both.",
    )
    parser.add_argument(
        "--report-path",
        default="",
        help="Optional path to write a machine-readable validation report.",
    )
    args = parser.parse_args()

    workspace_root = Path(args.workspace_root).resolve()
    results = []

    for contract in CONTRACTS:
        schema_path = SCHEMA_DIR / contract["schema"]
        if not schema_path.is_file():
            results.append(
                {
                    "scope": "schema",
                    "name": contract["name"],
                    "schema_path": str(schema_path),
                    "data_path": "",
                    "status": "FAIL",
                    "error": f"missing schema: {schema_path}",
                }
            )
            continue

        if args.mode in ("all", "fixtures") and contract["fixture"]:
            fixture_path = FIXTURE_DIR / contract["fixture"]
            if not fixture_path.is_file():
                results.append(
                    {
                        "scope": "fixtures",
                        "name": contract["name"],
                        "schema_path": str(schema_path),
                        "data_path": str(fixture_path),
                        "status": "FAIL",
                        "error": f"missing fixture: {fixture_path}",
                    }
                )
            else:
                validate_target(results, "fixtures", contract["name"], schema_path, fixture_path)

        if args.mode in ("all", "runtime") and contract["runtime"]:
            runtime_path = workspace_root / contract["runtime"]
            if runtime_path.is_file():
                validate_target(results, "runtime", contract["name"], schema_path, runtime_path)
            else:
                results.append(
                    {
                        "scope": "runtime",
                        "name": contract["name"],
                        "schema_path": str(schema_path),
                        "data_path": str(runtime_path),
                        "status": "SKIP",
                        "error": "runtime file not found",
                    }
                )

    failed = [item for item in results if item["status"] == "FAIL"]
    report = {
        "schema": "rayman.testing.json_contracts.v1",
        "workspace_root": str(workspace_root),
        "mode": args.mode,
        "success": len(failed) == 0,
        "counts": {
            "pass": sum(1 for item in results if item["status"] == "PASS"),
            "skip": sum(1 for item in results if item["status"] == "SKIP"),
            "fail": len(failed),
        },
        "results": results,
    }

    if args.report_path:
        report_path = Path(args.report_path)
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")

    print(json.dumps(report, indent=2, ensure_ascii=False))
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
