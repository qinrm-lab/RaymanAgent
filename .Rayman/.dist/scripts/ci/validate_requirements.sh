#!/usr/bin/env bash
set -euo pipefail

if [[ "${RAYMAN_VALIDATE_REQUIREMENTS_SKIP_RELEASE:-0}" != "1" ]]; then
  bash ./.Rayman/scripts/release/validate_release_requirements.sh >/dev/null
fi

fail(){ echo "❌ [rayman-ci] $*" >&2; exit 1; }
warn(){ echo "⚠️  [rayman-ci] $*" >&2; }
info(){ echo "✅ [rayman-ci] $*"; }

DEFAULT_BASE_REF="origin/main"

resolve_base_ref(){
  local explicit="${RAYMAN_BASE_REF:-}"
  if [[ -n "${explicit// }" ]]; then
    printf '%s' "${explicit}"
    return 0
  fi

  local candidate
  for candidate in "${DEFAULT_BASE_REF}" origin/master main master; do
    if git rev-parse --verify --quiet "${candidate}" >/dev/null 2>&1; then
      printf '%s' "${candidate}"
      return 0
    fi
  done

  printf '%s' "${DEFAULT_BASE_REF}"
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

SOL="$(bash ./.Rayman/scripts/requirements/detect_solution.sh)"
SOL_DIR=".${SOL}"
SOL_FILE="${SOL_DIR}/.${SOL}.requirements.md"
AGENTIC_DOCS=(
  "${SOL_DIR}/agentic/plan.current.md"
  "${SOL_DIR}/agentic/plan.current.json"
  "${SOL_DIR}/agentic/tool-policy.md"
  "${SOL_DIR}/agentic/tool-policy.json"
  "${SOL_DIR}/agentic/reflection.current.md"
  "${SOL_DIR}/agentic/reflection.current.json"
  "${SOL_DIR}/agentic/evals.md"
)

AGENTIC_CONFIG="./.Rayman/config/agentic_pipeline.json"
pipeline_mode="${RAYMAN_AGENT_PIPELINE:-}"
if [[ -z "${pipeline_mode// }" && -f "${AGENTIC_CONFIG}" ]]; then
  pipeline_mode="$(grep -E '"default_pipeline"\s*:' "${AGENTIC_CONFIG}" | head -n1 | sed -E 's/.*"default_pipeline"\s*:\s*"([^"]+)".*/\1/' || true)"
fi
if [[ -z "${pipeline_mode// }" ]]; then
  pipeline_mode="planner_v1"
fi
doc_gate_enabled="${RAYMAN_AGENT_DOC_GATE:-}"
if [[ -z "${doc_gate_enabled// }" && -f "${AGENTIC_CONFIG}" ]]; then
  doc_gate_enabled="$(grep -E '"doc_gate_enabled"\s*:' "${AGENTIC_CONFIG}" | head -n1 | sed -E 's/.*"doc_gate_enabled"\s*:\s*([^,}]+).*/\1/' | tr -d '[:space:]' || true)"
fi
if [[ -z "${doc_gate_enabled// }" ]]; then
  doc_gate_enabled="true"
fi

if printf '%s' "${SOL}" | LC_ALL=C grep -q $'\xEF\xBB\xBF'; then
  fail "detect_solution 返回了 BOM 污染的 SolutionName：${SOL}"
fi

# invariant: root should NOT contain .*.requirements.md
mapfile -t ROOT_REQS < <(find . -maxdepth 1 -type f -name ".*.requirements.md" ! -name ".temp.requirements.md" | sort)
if [[ "${#ROOT_REQS[@]}" -gt 0 ]]; then
  fail "约定：Solution/Project requirements 必须在 ${SOL_DIR}/ 下；根目录不应出现 .*.requirements.md（发现：${ROOT_REQS[*]}）"
fi

[[ -d "${SOL_DIR}" ]] || fail "缺少 Solution 目录：${SOL_DIR}/"
[[ -f "${SOL_FILE}" ]] || fail "缺少 Solution requirements：${SOL_FILE}（请运行 bash ./.Rayman/init.sh 或 ensure_requirements.sh）"

mapfile -t PROJ_REQS < <(find "${SOL_DIR}" -maxdepth 3 -type f -name ".*.requirements.md" | sort)

project_req_count=0
for f in "${PROJ_REQS[@]}"; do
  rel="${f#./}"
  [[ "$rel" == "${SOL_FILE#./}" ]] && continue
  project_req_count=$((project_req_count+1))
done

if [[ "${project_req_count}" -eq 0 ]]; then
  if [[ "${RAYMAN_ALLOW_EMPTY_PROJECTS:-1}" == "1" ]]; then
    grep -Fq -- "- (none detected)" "${SOL_FILE}" || fail "未检测到 Project requirements 时，${SOL_FILE} 必须显式包含 '- (none detected)'"
    warn "未检测到 Project requirements，按工具链仓库模式继续（RAYMAN_ALLOW_EMPTY_PROJECTS=1）。"
  else
    fail "未找到 Project requirements（或仅有 solution index），请检查 ${SOL_DIR}/ 结构"
  fi
fi

CONTENT="$(cat "${SOL_FILE}")"
for f in "${PROJ_REQS[@]}"; do
  rel="${f#./}"
  [[ "$rel" == "${SOL_FILE#./}" ]] && continue
  grep -Fq "${rel}" <<< "${CONTENT}" || fail "Solution requirements 未包含：${rel}"
done

if [[ "${pipeline_mode}" != "legacy" && "${doc_gate_enabled,,}" != "0" && "${doc_gate_enabled,,}" != "false" ]]; then
  for f in "${AGENTIC_DOCS[@]}"; do
    [[ -f "${f}" ]] || fail "缺少 agentic 文档：${f}"
    rel="${f#./}"
    grep -Fq "${rel}" <<< "${CONTENT}" || fail "Solution requirements 未包含 agentic 文档：${rel}"
  done
fi

AGENTS_PATH="$(bash ./.Rayman/scripts/agents/resolve_agents_file.sh --require-existing)" || fail "缺少 AGENTS.md/agents.md"
AGENTS="$(cat "${AGENTS_PATH}")"
open_count="$(printf '%s' "${AGENTS}" | grep -c "<!-- RAYMAN:MANDATORY_REQUIREMENTS" || true)"
close_count="$(printf '%s' "${AGENTS}" | grep -c "<!-- /RAYMAN:MANDATORY_REQUIREMENTS" || true)"
[[ "$open_count" -eq 1 && "$close_count" -eq 1 ]] || fail "${AGENTS_PATH} 强制段落必须且只能一段（open=${open_count}, close=${close_count}）"

if [[ "${RAYMAN_DIFF_CHECK:-1}" == "0" ]]; then
  reason="$(require_bypass_reason "diff-check")"
  record_bypass "diff-check" "${reason}"
  info "diff 约束已按显式决策跳过"
  exit 0
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Local tool-only workspace may not be a git repo; keep CI strict by default.
  if [[ "${CI:-}" == "true" || "${CI:-}" == "1" || "${RAYMAN_STRICT_GIT:-0}" == "1" ]]; then
    if [[ "${RAYMAN_ALLOW_NO_GIT:-0}" == "1" ]]; then
      reason="$(require_bypass_reason "no-git-repo")"
      record_bypass "no-git-repo" "${reason}"
      info "非 git 仓库，按显式决策跳过 diff 约束"
      exit 0
    fi
    fail "当前目录不是 git 仓库；CI/strict 模式下请设置 RAYMAN_ALLOW_NO_GIT=1 并提供 RAYMAN_BYPASS_REASON。"
  fi

  if [[ "${RAYMAN_ALLOW_NO_GIT:-0}" == "1" ]]; then
    reason="$(require_bypass_reason "no-git-repo")"
    record_bypass "no-git-repo" "${reason}"
    info "非 git 仓库，按显式决策跳过 diff 约束"
    exit 0
  fi

  warn "当前目录不是 git 仓库，已自动跳过 diff 约束。若需强制，请设置 RAYMAN_STRICT_GIT=1。"
  exit 0
fi

GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=Never git fetch --all --prune >/dev/null 2>&1 || true
BASE="$(resolve_base_ref)"
if [[ -z "${RAYMAN_BASE_REF:-}" && "${BASE}" != "${DEFAULT_BASE_REF}" ]] && git rev-parse --verify --quiet "${BASE}" >/dev/null 2>&1; then
  warn "默认 base ref ${DEFAULT_BASE_REF} 不存在，已自动回退到 ${BASE}"
fi

if ! git rev-parse --verify --quiet "${BASE}" >/dev/null 2>&1; then
  if [[ "${RAYMAN_ALLOW_MISSING_BASE_REF:-0}" == "1" ]]; then
    reason="$(require_bypass_reason "missing-base-ref:${BASE}")"
    record_bypass "missing-base-ref:${BASE}" "${reason}"
    info "base ref 缺失，按显式决策跳过 diff 约束"
    exit 0
  fi
  fail "找不到 base ref：${BASE}；请先 fetch 对应分支，或显式设置 RAYMAN_ALLOW_MISSING_BASE_REF=1 + RAYMAN_BYPASS_REASON。"
fi

mapfile -t CHANGED < <(git diff --name-only "${BASE}...HEAD" 2>/dev/null | sed '/^$/d' | sort || true)
[[ "${#CHANGED[@]}" -eq 0 ]] && { info "diff 为空"; exit 0; }

EXCLUDE_DIR_RE='^(\.|\.github|\.Rayman|\.vscode|\.vs|\.temp|out|bin|obj|node_modules)(/|$)'
declare -A INVOLVED=()
touched_sol=0; touched_any_proj=0
touched_agentic=0
governance_touched=0
for p in "${CHANGED[@]}"; do
  case "${p}" in
    .Rayman/*|.github/*|AGENTS.md|agents.md|.SolutionName|.rayman.env.ps1|.clinerules|.cursorrules)
      governance_touched=1
      ;;
  esac
  [[ "$p" =~ ${EXCLUDE_DIR_RE} ]] && continue
  top="${p%%/*}"
  [[ "${top}" == "${SOL_DIR}" ]] && continue
  [[ -d "${top}" ]] && INVOLVED["${top}"]=1
done
[[ "${#INVOLVED[@]}" -eq 0 && "${governance_touched}" -eq 0 ]] && { info "未涉及 Project 变更"; exit 0; }
printf '%s\n' "${CHANGED[@]}" | grep -Fq "${SOL_FILE#./}" && touched_sol=1 || true
for f in "${AGENTIC_DOCS[@]}"; do
  printf '%s\n' "${CHANGED[@]}" | grep -Fq "${f#./}" && touched_agentic=1 || true
done
for proj in "${!INVOLVED[@]}"; do
  req="${SOL_DIR}/.${proj}/.${proj}.requirements.md"
  [[ -f "${req}" ]] || fail "涉及 ${proj} 但缺少 requirements：${req}"
  printf '%s\n' "${CHANGED[@]}" | grep -Fq "${req#./}" && touched_any_proj=1 || true
done
if [[ "${governance_touched}" -eq 1 ]]; then
  [[ "${touched_sol}" -eq 1 && "${touched_agentic}" -eq 1 ]] || fail "涉及 source workspace 治理变更但未同时触达 Solution requirements 与 agentic docs。"
fi
[[ "$touched_sol" -eq 1 || "$touched_any_proj" -eq 1 ]] || fail "涉及 Project 变更但未触达 requirements。"

info "全部校验通过"
