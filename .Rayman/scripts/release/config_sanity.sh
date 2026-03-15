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
agent_caps_cfg=".Rayman/config/agent_capabilities.json"
agent_caps_script=".Rayman/scripts/agents/ensure_agent_capabilities.ps1"
winapp_ensure_script=".Rayman/scripts/windows/ensure_winapp.ps1"
winapp_core_script=".Rayman/scripts/windows/winapp_core.ps1"
winapp_flow_script=".Rayman/scripts/windows/run_winapp_flow.ps1"
winapp_inspect_script=".Rayman/scripts/windows/inspect_winapp.ps1"
winapp_mcp_script=".Rayman/scripts/windows/winapp_mcp_server.ps1"
winapp_sample_flow=".Rayman/winapp.flow.sample.json"
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
[[ -f "${agent_caps_cfg}" ]] || fail "missing: ${agent_caps_cfg}"
[[ -f "${agent_caps_script}" ]] || fail "missing: ${agent_caps_script}"
[[ -f "${winapp_ensure_script}" ]] || fail "missing: ${winapp_ensure_script}"
[[ -f "${winapp_core_script}" ]] || fail "missing: ${winapp_core_script}"
[[ -f "${winapp_flow_script}" ]] || fail "missing: ${winapp_flow_script}"
[[ -f "${winapp_inspect_script}" ]] || fail "missing: ${winapp_inspect_script}"
[[ -f "${winapp_mcp_script}" ]] || fail "missing: ${winapp_mcp_script}"
[[ -f "${winapp_sample_flow}" ]] || fail "missing: ${winapp_sample_flow}"
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

with open(path, "r", encoding="utf-8-sig") as f:
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

with open(mcp_path, "r", encoding="utf-8-sig") as f:
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
  "RAYMAN_SETUP_GIT_INIT"
  "RAYMAN_SETUP_GITHUB_LOGIN"
  "RAYMAN_SETUP_GITHUB_LOGIN_STRICT"
  "RAYMAN_GITHUB_HOST"
  "RAYMAN_GITHUB_GIT_PROTOCOL"
  "RAYMAN_DOTNET_WINDOWS_PREFERRED"
  "RAYMAN_DOTNET_WINDOWS_STRICT"
  "RAYMAN_DOTNET_WINDOWS_TIMEOUT_SECONDS"
  "RAYMAN_AGENT_DEFAULT_BACKEND"
  "RAYMAN_AGENT_FALLBACK_ORDER"
  "RAYMAN_AGENT_CLOUD_ENABLED"
  "RAYMAN_AGENT_POLICY_BYPASS"
  "RAYMAN_AGENT_CLOUD_WHITELIST"
  "RAYMAN_AGENT_CAPABILITIES_ENABLED"
  "RAYMAN_AGENT_CAP_OPENAI_DOCS_ENABLED"
  "RAYMAN_AGENT_CAP_WEB_AUTO_TEST_ENABLED"
  "RAYMAN_AGENT_CAP_WINAPP_AUTO_TEST_ENABLED"
  "RAYMAN_WINAPP_REQUIRE"
  "RAYMAN_WINAPP_DEFAULT_TIMEOUT_MS"
  "RAYMAN_FIRST_PASS_WINDOW"
  "RAYMAN_REVIEW_LOOP_MAX_ROUNDS"
  "RAYMAN_VSCODE_BOOTSTRAP_PROFILE"
)
for key in "${required_env_defaults[@]}"; do
  if ! grep -Fq "${key}" "${setup_file}"; then
    fail "setup.ps1 missing required workspace env default: ${key}"
  fi
done

required_cli_tokens=(
  "\"copy-self-check\""
  "\"fast-gate\""
  "\"browser-gate\""
  "\"full-gate\""
  "\"agent-capabilities\""
  "\"ensure-winapp\""
  "\"winapp-test\""
  "\"winapp-inspect\""
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

required_agent_cap_tokens=(
  "rayman.agent_capabilities.v1"
  "\"openai_docs\""
  "\"web_auto_test\""
  "\"winapp_auto_test\""
  "\"openaiDeveloperDocs\""
  "\"@playwright/mcp\""
  "\"raymanWinApp\""
)
for token in "${required_agent_cap_tokens[@]}"; do
  if ! grep -Fq "${token}" "${agent_caps_cfg}"; then
    fail "agent_capabilities.json missing token: ${token}"
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

ps_runner=()
if command -v pwsh >/dev/null 2>&1; then
  ps_runner=(pwsh -NoProfile -File)
elif command -v powershell >/dev/null 2>&1; then
  ps_runner=(powershell -NoProfile -ExecutionPolicy Bypass -File)
else
  fail "pwsh/powershell not found; cannot validate agent capability sync"
fi

RAYMAN_AGENT_CAPABILITIES_SKIP_PREPARE=1 "${ps_runner[@]}" "${agent_caps_script}" -Action sync -WorkspaceRoot "$(pwd)" >/dev/null || fail "agent capability sync failed (first run)"
[[ -f ".Rayman/runtime/agent_capabilities.report.json" ]] || fail "agent capability sync did not emit runtime report"

"${pybin}" - <<'PY' ".Rayman/runtime/agent_capabilities.report.json" ".codex/config.toml"
import json
import os
import sys

report_path = sys.argv[1]
config_path = sys.argv[2]

with open(report_path, "r", encoding="utf-8") as f:
    report = json.load(f)

if not report.get("registry_valid"):
    raise SystemExit("agent capability report says registry_valid=false")

active = set(report.get("active_capabilities") or [])
global_enabled = bool(report.get("global_enabled", True))
config_exists = os.path.isfile(config_path)
raw = ""
if config_exists:
    with open(config_path, "r", encoding="utf-8") as f:
        raw = f.read()

managed_start = "# >>> Rayman managed capabilities >>>"
managed_end = "# <<< Rayman managed capabilities <<<"
managed_present = managed_start in raw and managed_end in raw

if report.get("managed_block_present", False) != managed_present:
    raise SystemExit("managed block presence mismatch between report and .codex/config.toml")

if not global_enabled or not active:
    if managed_present and not config_exists:
        raise SystemExit("managed block marked present but .codex/config.toml is missing")
else:
    if not config_exists:
        raise SystemExit("active capabilities exist but .codex/config.toml is missing")
    if not managed_present:
        raise SystemExit(".codex/config.toml missing managed block markers")
    if "openai_docs" in active:
        if "mcp_servers.openaiDeveloperDocs" not in raw or "https://developers.openai.com/mcp" not in raw:
            raise SystemExit(".codex/config.toml missing OpenAI Docs MCP block for active openai_docs capability")
    if "web_auto_test" in active:
        if "mcp_servers.playwright" not in raw or "@playwright/mcp" not in raw:
            raise SystemExit(".codex/config.toml missing Playwright MCP block for active web_auto_test capability")
    if "winapp_auto_test" in active:
        if "mcp_servers.raymanWinApp" not in raw or "winapp_mcp_server.ps1" not in raw:
            raise SystemExit(".codex/config.toml missing WinApp MCP block for active winapp_auto_test capability")
PY

hash_before="missing"
if [[ -f ".codex/config.toml" ]]; then
  hash_before="$(sha1sum .codex/config.toml | awk '{print $1}')"
fi
RAYMAN_AGENT_CAPABILITIES_SKIP_PREPARE=1 "${ps_runner[@]}" "${agent_caps_script}" -Action sync -WorkspaceRoot "$(pwd)" >/dev/null || fail "agent capability sync failed (second run)"
hash_after="missing"
if [[ -f ".codex/config.toml" ]]; then
  hash_after="$(sha1sum .codex/config.toml | awk '{print $1}')"
fi
[[ "${hash_before}" == "${hash_after}" ]] || fail ".codex/config.toml changed after second sync (not idempotent)"

ok
