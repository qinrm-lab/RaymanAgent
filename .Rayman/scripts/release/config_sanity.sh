#!/usr/bin/env bash
set -euo pipefail

fail(){ echo "❌ [rayman-config] $*" >&2; exit 8; }
warn(){ echo "⚠️  [rayman-config] $*" >&2; }
ok(){ echo "OK"; }

solution_file=".SolutionName"
settings_file=".vscode/settings.json"
mcp_file=".Rayman/mcp/mcp_servers.json"
setup_file=".Rayman/setup.ps1"
test_fix_file=".Rayman/scripts/repair/run_tests_and_fix.ps1"
rayman_cli=".Rayman/rayman.ps1"
dispatch_file=".Rayman/scripts/agents/dispatch.ps1"
review_loop_file=".Rayman/scripts/agents/review_loop.ps1"
first_pass_file=".Rayman/scripts/agents/first_pass_report.ps1"
prompts_file=".Rayman/scripts/agents/prompts_catalog.ps1"
router_cfg=".Rayman/config/agent_router.json"
policy_cfg=".Rayman/config/agent_policy.json"
review_cfg=".Rayman/config/review_loop.json"

[[ -f "${solution_file}" ]] || fail "missing: ${solution_file}"
[[ -f "${settings_file}" ]] || fail "missing: ${settings_file}"
[[ -f "${mcp_file}" ]] || fail "missing: ${mcp_file}"
[[ -f "${setup_file}" ]] || fail "missing: ${setup_file}"
[[ -f "${test_fix_file}" ]] || fail "missing: ${test_fix_file}"
[[ -f "${rayman_cli}" ]] || fail "missing: ${rayman_cli}"
[[ -f "${dispatch_file}" ]] || fail "missing: ${dispatch_file}"
[[ -f "${review_loop_file}" ]] || fail "missing: ${review_loop_file}"
[[ -f "${first_pass_file}" ]] || fail "missing: ${first_pass_file}"
[[ -f "${prompts_file}" ]] || fail "missing: ${prompts_file}"
[[ -f "${router_cfg}" ]] || fail "missing: ${router_cfg}"
[[ -f "${policy_cfg}" ]] || fail "missing: ${policy_cfg}"
[[ -f "${review_cfg}" ]] || fail "missing: ${review_cfg}"

if LC_ALL=C grep -q $'\xEF\xBB\xBF' "${solution_file}"; then
  fail ".SolutionName 包含 UTF-8 BOM，请改为纯文本（ASCII/UTF-8 无 BOM）"
fi

if command -v python3 >/dev/null 2>&1; then
  pybin="python3"
elif command -v python >/dev/null 2>&1; then
  pybin="python"
else
  warn "python not found; skip settings.json duplicate-key check"
  ok
  exit 0
fi

"${pybin}" - <<'PY' "${settings_file}"
import json
import sys
from typing import Any, List, Tuple

path = sys.argv[1]

def load_with_case_insensitive_dup_check(pairs: List[Tuple[str, Any]]) -> dict:
    out = {}
    seen = {}
    for k, v in pairs:
        lk = k.lower()
        if lk in seen:
            prev = seen[lk]
            raise ValueError(
                f"duplicate key ignoring case: '{k}' conflicts with '{prev}'"
            )
        seen[lk] = k
        out[k] = v
    return out

with open(path, "r", encoding="utf-8") as f:
    try:
        data = json.load(f, object_pairs_hook=load_with_case_insensitive_dup_check)
    except Exception as e:
        raise SystemExit(f"settings parse/check failed: {e}")

terminal = data.get("chat.tools.terminal.autoApprove", {})
if isinstance(terminal, dict):
    if terminal.get("/^.*$/") is True:
        raise SystemExit("chat.tools.terminal.autoApprove contains unsafe wildcard /^.*$/")

edits = data.get("chat.tools.edits.autoApprove", {})
if isinstance(edits, dict):
    if edits.get("**/*") is True:
        raise SystemExit("chat.tools.edits.autoApprove contains unsafe wildcard **/*")

print("settings.json sanity OK")
PY

"${pybin}" - <<'PY' "${mcp_file}" "$(pwd)"
import json
import os
import re
import sys

mcp_path = sys.argv[1]
workspace_root = sys.argv[2]
workspace_norm = os.path.abspath(workspace_root).replace("\\", "/").rstrip("/").lower()

with open(mcp_path, "r", encoding="utf-8") as f:
    data = json.load(f)

servers = data.get("mcpServers", {})
sqlite = servers.get("sqlite")
if not isinstance(sqlite, dict):
    raise SystemExit("mcp_servers.json missing mcpServers.sqlite")

args = sqlite.get("args", [])
if not isinstance(args, list):
    raise SystemExit("mcpServers.sqlite.args must be an array")

try:
    idx = args.index("--db-path")
except ValueError:
    raise SystemExit("mcpServers.sqlite.args missing --db-path")

if idx + 1 >= len(args):
    raise SystemExit("mcpServers.sqlite.args --db-path missing value")

raw = str(args[idx + 1]).strip()
if not raw:
    raise SystemExit("mcpServers.sqlite.args --db-path is empty")

tokenized = (
    "${workspaceroot}" in raw.lower()
    or "${workspace_root}" in raw.lower()
    or "%workspace_root%" in raw.lower()
)

norm = raw.replace("\\", "/").rstrip("/").lower()
legacy_suffix = "/.rayman/state/rayman.db"
is_abs = bool(re.match(r"^[a-z]:/", norm)) or norm.startswith("/")

if is_abs and norm.endswith(legacy_suffix) and not tokenized:
    raise SystemExit(
        "mcpServers.sqlite --db-path contains absolute .Rayman/state/rayman.db; use ${workspaceRoot}/.Rayman/state/rayman.db"
    )

if workspace_norm and workspace_norm in norm and is_abs and not tokenized:
    raise SystemExit("mcpServers.sqlite --db-path contains hardcoded workspace root path")

print("mcp_servers.json portability OK")
PY

required_env_defaults=(
  "RAYMAN_AUTO_INSTALL_TEST_DEPS"
  "RAYMAN_REQUIRE_TEST_DEPS"
  "RAYMAN_SELF_HEAL_AUTO_DEP_INSTALL"
  "RAYMAN_PLAYWRIGHT_REQUIRE"
  "RAYMAN_PLAYWRIGHT_AUTO_INSTALL"
  "RAYMAN_DOTNET_WINDOWS_PREFERRED"
  "RAYMAN_DOTNET_WINDOWS_STRICT"
  "RAYMAN_DOTNET_WINDOWS_TIMEOUT_SECONDS"
  "RAYMAN_AGENT_DEFAULT_BACKEND"
  "RAYMAN_AGENT_FALLBACK_ORDER"
  "RAYMAN_AGENT_CLOUD_ENABLED"
  "RAYMAN_AGENT_POLICY_BYPASS"
  "RAYMAN_AGENT_CLOUD_WHITELIST"
  "RAYMAN_FIRST_PASS_WINDOW"
  "RAYMAN_REVIEW_LOOP_MAX_ROUNDS"
)
for key in "${required_env_defaults[@]}"; do
  if ! grep -Fq "${key}" "${setup_file}"; then
    fail "setup.ps1 missing required workspace env default: ${key}"
  fi
done

required_cli_tokens=(
  "\"dispatch\""
  "\"review-loop\""
  "\"first-pass-report\""
  "\"prompts\""
)
for token in "${required_cli_tokens[@]}"; do
  if ! grep -Fq "${token}" "${rayman_cli}"; then
    fail "rayman.ps1 missing command token: ${token}"
  fi
done

required_dispatch_policy_tokens=(
  "RAYMAN_AGENT_POLICY_BYPASS"
  "RAYMAN_BYPASS_REASON"
  "policy_bypassed"
  "agent-pre-dispatch"
)
for token in "${required_dispatch_policy_tokens[@]}"; do
  if ! grep -Fq "${token}" "${dispatch_file}"; then
    fail "dispatch.ps1 missing policy bypass audit token: ${token}"
  fi
done

required_review_diff_tokens=(
  "Get-SnapshotDiffSummary"
  "diff_summary"
  "review_loop.last.diff.md"
)
for token in "${required_review_diff_tokens[@]}"; do
  if ! grep -Fq "${token}" "${review_loop_file}"; then
    fail "review_loop.ps1 missing diff summary contract token: ${token}"
  fi
done

required_first_pass_corr_tokens=(
  "Change-Scale Correlation (Round 1)"
  "change_scale_correlation"
  "round1_touched_files"
  "round1_abs_net_size_delta_bytes"
)
for token in "${required_first_pass_corr_tokens[@]}"; do
  if ! grep -Fq "${token}" "${first_pass_file}"; then
    fail "first_pass_report.ps1 missing change-scale correlation token: ${token}"
  fi
done

required_dotnet_summary_tokens=(
  "schema = 'rayman.dotnet.exec.v1'"
  "selected_host = ''"
  "fallback_host = ''"
  "final_exit_code = 1"
  "windows_exit_code = \$null"
  "wsl_exit_code = \$null"
  "windows_timed_out = \$false"
  "windows_error_message = ''"
  "windows_invoked_via = ''"
  "windows_workspace = ''"
  "detail_log = \$script:DotNetExecDetailPath"
)
for token in "${required_dotnet_summary_tokens[@]}"; do
  if ! grep -Fq "${token}" "${test_fix_file}"; then
    fail "run_tests_and_fix.ps1 missing dotnet summary token: ${token}"
  fi
done

ok
