#!/usr/bin/env bash
set -euo pipefail

fail(){ echo "❌ [rayman-release] $*" >&2; exit 2; }
info(){ echo "✅ [rayman-release] $*"; }
warn(){ echo "⚠️  [rayman-release] $*" >&2; }

emit_copy_smoke_guidance(){
  warn "这不是在等待你输入内容；这里是 strict sandbox copy smoke 校验失败。"
  warn "建议先单独运行：.\\.Rayman\\rayman.ps1 release-gate -Mode project"
  warn "若确认是当前主机的 Windows Sandbox / 权限限制，可显式放行：先设置 RAYMAN_ALLOW_COPY_SMOKE_SANDBOX_FAIL=1，再设置 RAYMAN_BYPASS_REASON。"
}

RUNTIME_DIR=".Rayman/runtime"
DECISION_LOG="${RUNTIME_DIR}/decision.log"
DECISION_SUMMARY="${RUNTIME_DIR}/decision.summary.tsv"
DECISION_MAINTAINER="./.Rayman/scripts/release/maintain_decision_log.sh"
mkdir -p "${RUNTIME_DIR}"

now_ts(){ date -Iseconds; }

require_bypass_reason(){
  local gate="$1"
  local reason="${RAYMAN_BYPASS_REASON:-}"
  if [[ -z "${reason// }" ]]; then
    fail "${gate} 需要显式原因：请设置 RAYMAN_BYPASS_REASON。"
  fi
  printf '%s' "${reason}"
}

record_bypass(){
  local gate="$1"
  local reason="$2"
  printf '%s gate=%s action=BYPASS reason=%s\n' "$(now_ts)" "${gate}" "${reason}" >> "${DECISION_LOG}"
  if [[ -f "${DECISION_MAINTAINER}" ]]; then
    bash "${DECISION_MAINTAINER}" --log "${DECISION_LOG}" --summary "${DECISION_SUMMARY}" >/dev/null || true
  fi
  warn "gate bypass: ${gate}（reason=${reason}）"
}

DOC="RELEASE_REQUIREMENTS.md"
ALT=".Rayman/RELEASE_REQUIREMENTS.md"

if [[ -f "$ALT" ]]; then
  SRC="$ALT"
elif [[ -f "$DOC" ]]; then
  SRC="$DOC"
else
  fail "未找到 RELEASE_REQUIREMENTS.md（根目录或 .Rayman/ 下）"
fi

start="<!-- RAYMAN:RELEASE_CHECKLIST -->"
end="<!-- /RAYMAN:RELEASE_CHECKLIST -->"

extract() {
  awk -v s="$start" -v e="$end" '
    $0==s {flag=1; next}
    $0==e {flag=0}
    flag==1 {print}
  ' "$1"
}

block="$(extract "$SRC")"
if [[ -z "$block" && "$SRC" != "$ALT" && -f "$ALT" ]]; then
  block="$(extract "$ALT")"
  SRC="$ALT"
fi

[[ -n "$block" ]] || fail "RELEASE_REQUIREMENTS.md 缺少机器可读清单 block"

# hard-guard against missing release scripts (close the loop)
need_scripts=(
  "./.Rayman/scripts/release/checklist.sh"
  "./.Rayman/scripts/release/assert_workspace_hygiene.sh"
  "./.Rayman/scripts/release/assert_dist_sync.sh"
  "./.Rayman/scripts/release/copy_smoke.ps1"
  "./.Rayman/scripts/release/contract_update_from_prompt.sh"
  "./.Rayman/scripts/release/issues_gate.sh"
  "./.Rayman/scripts/release/regression_guard.sh"
  "./.Rayman/scripts/release/spotcheck_release.sh"
  "./.Rayman/scripts/release/contract_git_safe.sh"
  "./.Rayman/scripts/release/contract_scm_tracked_noise.sh"
  "./.Rayman/scripts/release/contract_nested_repair.sh"
  "./.Rayman/scripts/release/maintain_decision_log.sh"
  "./.Rayman/scripts/release/maintain_decision_log.ps1"
  "./.Rayman/scripts/release/config_sanity.sh"
  "./.Rayman/scripts/telemetry/rules_metrics.sh"
  "./.Rayman/scripts/telemetry/daily_trend.sh"
  "./.Rayman/scripts/telemetry/validate_json.sh"
  "./.Rayman/scripts/telemetry/baseline_guard.sh"
  "./.Rayman/scripts/telemetry/export_artifacts.sh"
  "./.Rayman/scripts/telemetry/index_artifacts.sh"
  "./.Rayman/scripts/telemetry/prune_artifacts.sh"
  "./.Rayman/scripts/telemetry/schemas/rules_metrics.v1.schema.json"
  "./.Rayman/scripts/telemetry/schemas/daily_trend.v1.schema.json"
  "./.Rayman/scripts/telemetry/schemas/baseline_guard.v1.schema.json"
  "./.Rayman/scripts/telemetry/schemas/first_pass_report.v1.schema.json"
  "./.Rayman/scripts/telemetry/schemas/artifact_bundle.v1.schema.json"
  "./.Rayman/scripts/telemetry/schemas/artifact_index.v1.schema.json"
  "./.Rayman/scripts/release/verify_signature.sh"
  "./.Rayman/scripts/release/contract_release_gate.sh"
  "./.Rayman/scripts/release/contract_playwright_fallback.sh"
  "./.Rayman/scripts/backup/snapshot_workspace.sh"
  "./.Rayman/scripts/backup/snapshot_workspace.ps1"
  "./.Rayman/scripts/utils/clean_workspace.sh"
  "./.Rayman/scripts/utils/clean_workspace.ps1"
  "./.Rayman/scripts/utils/ensure_project_test_deps.sh"
  "./.Rayman/scripts/utils/ensure_project_test_deps.ps1"
  "./.Rayman/scripts/repair/run_tests_and_fix.ps1"
  "./.Rayman/scripts/pwa/ensure_playwright_ready.ps1"
  "./.Rayman/scripts/pwa/prepare_windows_sandbox_cache.ps1"
  "./.Rayman/scripts/proxy/sandbox_proxy_bridge.ps1"
  "./.Rayman/scripts/agents/resolve_agents_file.sh"
  "./.Rayman/scripts/agents/ensure_agent_assets.ps1"
  "./.Rayman/scripts/agents/dispatch.ps1"
  "./.Rayman/scripts/agents/review_loop.ps1"
  "./.Rayman/scripts/agents/first_pass_report.ps1"
  "./.Rayman/scripts/agents/prompts_catalog.ps1"
  "./.Rayman/scripts/memory/memory_bootstrap.ps1"
  "./.Rayman/scripts/memory/manage_memory.ps1"
)
for s in "${need_scripts[@]}"; do
  [[ -f "$s" ]] || fail "Rayman 脚本缺失：$s（请同步完整 .Rayman 目录）"
done

# Basic MUST_EXIST / MUST_RUN handling
while IFS= read -r line; do
  line="${line##- }"
  case "$line" in
    MUST_EXIST:*)
      p="${line#MUST_EXIST: }"
      [[ -e "$p" ]] || fail "MUST_EXIST 不满足：$p"
      ;;
    MUST_RUN:*)
      cmd="${line#MUST_RUN: }"
      if [[ "$cmd" == *"validate_requirements.sh"* || "$cmd" == *"checklist.sh"* || "$cmd" == *"spotcheck_release.sh"* || "$cmd" == *"contract_update_from_prompt.sh"* || "$cmd" == *"contract_playwright_fallback.sh"* ]]; then
        :
      else
        bash -lc "$cmd" >/dev/null
      fi
      ;;
  esac
done <<< "$block"

# checklist
bash ./.Rayman/scripts/release/checklist.sh >/dev/null || fail "release checklist 失败"

# workspace hygiene
bash ./.Rayman/scripts/release/assert_workspace_hygiene.sh >/dev/null || fail "workspace hygiene 检查失败"

# config sanity (solution/settings consistency)
bash ./.Rayman/scripts/release/config_sanity.sh >/dev/null || fail "config_sanity 检查失败"

# source/.dist drift guard
bash ./.Rayman/scripts/release/assert_dist_sync.sh >/dev/null || fail ".Rayman 与 .dist 脚本不同步"

# contract tests
bash ./.Rayman/scripts/release/contract_update_from_prompt.sh >/dev/null || fail "update_from_prompt 契约测试失败"
bash ./.Rayman/scripts/release/contract_release_gate.sh >/dev/null || fail "release_gate 契约测试失败"
bash ./.Rayman/scripts/release/contract_playwright_fallback.sh >/dev/null || fail "playwright fallback 契约测试失败"
bash ./.Rayman/scripts/release/contract_git_safe.sh >/dev/null || fail "git safe 契约测试失败"
bash ./.Rayman/scripts/release/contract_scm_tracked_noise.sh >/dev/null || fail "scm tracked noise 契约测试失败"
bash ./.Rayman/scripts/release/contract_nested_repair.sh >/dev/null || fail "nested repair 契约测试失败"

# issues must be fully closed
bash ./.Rayman/scripts/release/issues_gate.sh >/dev/null || fail "issues 未闭环"

# regression guard
bash ./.Rayman/scripts/release/regression_guard.sh >/dev/null || fail "regression_guard 失败"

# spotcheck
bash ./.Rayman/scripts/release/spotcheck_release.sh >/dev/null || fail "spotcheck_release 失败"

# strict sandbox copy smoke (blocking by default)
sandbox_smoke_cmd=""
if command -v powershell.exe >/dev/null 2>&1; then
  sandbox_smoke_cmd='powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./.Rayman/scripts/release/copy_smoke.ps1 -Strict -Scope sandbox -TimeoutSeconds 180'
elif command -v pwsh >/dev/null 2>&1; then
  sandbox_smoke_cmd='pwsh -NoProfile -ExecutionPolicy Bypass -File ./.Rayman/scripts/release/copy_smoke.ps1 -Strict -Scope sandbox -TimeoutSeconds 180'
fi

if [[ -n "${sandbox_smoke_cmd}" ]]; then
  if ! bash -lc "${sandbox_smoke_cmd}" >/dev/null; then
    if [[ "${RAYMAN_ALLOW_COPY_SMOKE_SANDBOX_FAIL:-0}" == "1" ]]; then
      reason="$(require_bypass_reason "copy-smoke-sandbox")"
      record_bypass "copy-smoke-sandbox" "${reason}"
      warn "copy smoke sandbox strict failed（按显式决策放行）"
    else
      emit_copy_smoke_guidance
      fail "copy smoke sandbox strict 失败（可显式设置 RAYMAN_ALLOW_COPY_SMOKE_SANDBOX_FAIL=1 + RAYMAN_BYPASS_REASON 放行）"
    fi
  fi
else
  if [[ "${RAYMAN_ALLOW_COPY_SMOKE_SANDBOX_FAIL:-0}" == "1" ]]; then
    reason="$(require_bypass_reason "copy-smoke-sandbox")"
    record_bypass "copy-smoke-sandbox" "${reason}"
    warn "copy smoke sandbox strict skipped: no powershell host（按显式决策放行）"
  else
    emit_copy_smoke_guidance
    fail "copy smoke sandbox strict 需要 powershell.exe/pwsh；可显式设置 RAYMAN_ALLOW_COPY_SMOKE_SANDBOX_FAIL=1 + RAYMAN_BYPASS_REASON 放行"
  fi
fi

profile="${RAYMAN_RULES_PROFILE:-${RAYMAN_PROFILE:-unknown}}"
enforce_sig="${RAYMAN_ENFORCE_SIGNATURE:-}"
if [[ -z "${enforce_sig}" ]]; then
  if [[ "${profile}" == "release" || "${RAYMAN_RELEASE_MODE:-0}" == "1" ]]; then
    enforce_sig="1"
  else
    enforce_sig="0"
  fi
fi

sig="$(RAYMAN_REQUIRE_SIGNATURE="${enforce_sig}" bash ./.Rayman/scripts/release/verify_signature.sh || true)"
case "$sig" in
  OK)
    info "signature: OK"
    ;;
  SKIP)
    if [[ "${enforce_sig}" == "1" ]]; then
      if [[ "${RAYMAN_ALLOW_UNSIGNED_RELEASE:-0}" == "1" ]]; then
        reason="$(require_bypass_reason "unsigned-release")"
        record_bypass "unsigned-release" "${reason}"
        info "signature: SKIP（按显式决策放行）"
      else
        fail "signature 缺失；release 模式必须提供签名。可显式设置 RAYMAN_ALLOW_UNSIGNED_RELEASE=1 + RAYMAN_BYPASS_REASON。"
      fi
    else
      warn "signature: SKIP（非 release 强制模式）"
    fi
    ;;
  *)
    if [[ "${RAYMAN_ALLOW_SIGNATURE_FAIL:-0}" == "1" ]]; then
      reason="$(require_bypass_reason "signature-fail")"
      record_bypass "signature-fail" "${reason}"
      warn "signature verify FAIL（按显式决策放行）"
    else
      fail "signature verify FAIL"
    fi
    ;;
esac

info "Release requirements 校验通过（$SRC）"
