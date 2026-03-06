#!/usr/bin/env bash
set -euo pipefail

fail(){ echo "❌ [rayman-hygiene] $*" >&2; exit 7; }
warn(){ echo "⚠️  [rayman-hygiene] $*" >&2; }
ok(){ echo "OK"; }

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

bad=0
declare -a findings=()

while IFS= read -r -d '' path; do
  rel="${path#./}"
  [[ -z "${rel}" ]] && continue

  case "${rel}" in
    .git/*|.git|.Rayman/runtime/*|.Rayman/runtime|.tmp_sandbox_verify*|.tmp_sandbox_verify_clean*|node_modules/*|node_modules|bin/*|bin|obj/*|obj)
      continue
      ;;
  esac

  if [[ "${rel}" == *$'\xEF\xBB\xBF'* ]]; then
    findings+=("path contains UTF-8 BOM bytes: ${rel}")
    bad=1
  fi

  if printf '%s' "${rel}" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    findings+=("path contains control characters: ${rel}")
    bad=1
  fi

  sanitized="${rel//$'\xEF\xBB\xBF'/}"
  if [[ "${sanitized}" != "${rel}" && -e "./${sanitized}" ]]; then
    findings+=("duplicate-like path (BOM variant): ${rel} <-> ${sanitized}")
    bad=1
  fi
done < <(find . -maxdepth 2 -mindepth 1 -print0)

if [[ "${bad}" -ne 0 ]]; then
  if [[ "${RAYMAN_ALLOW_HYGIENE_ISSUES:-0}" == "1" ]]; then
    reason="$(require_bypass_reason "workspace-hygiene")"
    record_bypass "workspace-hygiene" "${reason}"
    printf '%s\n' "${findings[@]}" >&2
    ok
    exit 0
  fi
  printf '%s\n' "${findings[@]}" >&2
  fail "workspace hygiene 检查失败"
fi

ok
