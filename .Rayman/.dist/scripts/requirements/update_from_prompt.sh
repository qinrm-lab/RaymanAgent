#!/usr/bin/env bash
set -euo pipefail
if [[ "${RAYMAN_DEBUG:-0}" == "1" ]]; then set -x; fi

PROMPT_FILE="${1:-}"
if [[ -z "${PROMPT_FILE}" || ! -f "${PROMPT_FILE}" ]]; then
  echo "[req-from-prompt] missing prompt file: ${PROMPT_FILE}" >&2
  exit 2
fi

SOL="$(bash ./.Rayman/scripts/requirements/detect_solution.sh)"
SOL_DIR=".${SOL}"
SOL_REQ="${SOL_DIR}/.${SOL}.requirements.md"
mapfile -t PROJS < <(bash ./.Rayman/scripts/requirements/detect_projects.sh || true)

prompt_txt="$(cat "${PROMPT_FILE}")"

prompt_norm="$(printf "%s" "${prompt_txt}" | sed $'s/\r$//')"

trim() { echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
normalize_workspace_name() { printf '%s' "$(trim "${1:-}")" | tr '[:upper:]' '[:lower:]'; }
join_by_comma() { local IFS=', '; printf '%s' "$*"; }

workspace_aliases=()
add_workspace_alias() {
  local raw="${1:-}" norm existing
  raw="$(trim "${raw}")"
  [[ -z "${raw}" ]] && return 0
  norm="$(normalize_workspace_name "${raw}")"
  for existing in "${workspace_aliases[@]:-}"; do
    [[ "$(normalize_workspace_name "${existing}")" == "${norm}" ]] && return 0
  done
  workspace_aliases+=("${raw}")
}

workspace_alias_exists() {
  local name="${1:-}" norm existing
  norm="$(normalize_workspace_name "${name}")"
  [[ -z "${norm}" ]] && return 1
  for existing in "${workspace_aliases[@]:-}"; do
    [[ "$(normalize_workspace_name "${existing}")" == "${norm}" ]] && return 0
  done
  return 1
}

is_reserved_workspace_prefix() {
  local key
  key="$(normalize_workspace_name "${1:-}")"
  case "${key}" in
    target|workspace|工作区|功能|需求|验收标准|验收|feature|features|requirement|requirements|acceptance\ criteria|ac|附件|attachment|attachments|问题|issue|issues|closed|resolved|已解决|已修复)
      return 0
      ;;
  esac
  return 1
}

parse_prompt_workspace_directive() {
  local line l value candidate

  # Priority 1: explicit workspace field anywhere in prompt.
  while IFS= read -r line; do
    l="$(trim "$line")"
    [[ -z "$l" ]] && continue
    if [[ "$l" =~ ^([Ww][Oo][Rr][Kk][Ss][Pp][Aa][Cc][Ee]|工作区)[[:space:]]*[:：][[:space:]]*(.+)$ ]]; then
      value="$(trim "${BASH_REMATCH[2]}")"
      [[ -n "${value}" ]] && printf '%s\n' "${value}" && return 0
    fi
  done <<<"${prompt_norm}"

  # Priority 2: first non-empty non-comment line "<WorkspaceName>: ...".
  while IFS= read -r line; do
    l="$(trim "$line")"
    [[ -z "$l" ]] && continue
    if [[ "$l" == \#* || "$l" == '<!--'* ]]; then
      continue
    fi
    if [[ "$l" =~ ^([^:：]+)[[:space:]]*[:：].*$ ]]; then
      candidate="$(trim "${BASH_REMATCH[1]}")"
      if [[ -n "${candidate}" ]] && ! is_reserved_workspace_prefix "${candidate}"; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    fi
    break
  done <<<"${prompt_norm}"

  return 1
}

add_workspace_alias "${SOL}"
add_workspace_alias "$(basename "$(pwd -P)")"

declared_workspace="$(parse_prompt_workspace_directive 2>/dev/null || true)"
declared_workspace="$(trim "${declared_workspace}")"
if [[ -n "${declared_workspace}" ]] && ! workspace_alias_exists "${declared_workspace}"; then
  aliases="$(join_by_comma "${workspace_aliases[@]}")"
  if [[ -z "${aliases}" ]]; then
    aliases="${SOL}"
  fi
  echo "[req-from-prompt] 检测到跨工作区 prompt，已暂停；prompt 仅能对本工作区负责。" >&2
  echo "[req-from-prompt] declared workspace: ${declared_workspace}; current workspace aliases: ${aliases}" >&2
  exit 65
fi

parse_target_directive() {
  local line l
  while IFS= read -r line; do
    l="$(trim "$line")"
    [[ -z "$l" ]] && continue
    if echo "$l" | grep -Eiq '^Target[[:space:]]*[:：]'; then
      echo "$(echo "$l" | sed -E 's/^Target[[:space:]]*[:：][[:space:]]*//I')"
      return 0
    fi
  done <<<"${prompt_norm}"
  return 1
}

project_exists() {
  local name="$1"
  local p
  for p in "${PROJS[@]:-}"; do
    [[ "$p" == "$name" ]] && return 0
  done
  return 1
}

choose_target_interactive() {
  echo
  echo "[req-from-prompt] Target is required to avoid mixing solution/project requirements."
  echo "Please choose where to write this prompt:"
  echo "  0) Abort"
  echo "  1) Solution (${SOL_REQ})"
  local idx=2
  local p
  for p in "${PROJS[@]:-}"; do
    echo "  ${idx}) Project: ${p} (${SOL_DIR}/.${p}/.${p}.requirements.md)"
    idx=$((idx+1))
  done
  echo -n "Select [0-${idx}]: "
  read -r sel
  sel="$(trim "${sel:-0}")"
  if [[ "$sel" == "1" ]]; then
    echo "Solution"
    return 0
  fi
  if [[ "$sel" =~ ^[0-9]+$ ]] && [[ "$sel" -ge 2 ]] && [[ "$sel" -lt "$idx" ]]; then
    local pidx=$((sel-2))
    echo "Project:${PROJS[$pidx]}"
    return 0
  fi
  echo ""  # Abort
  return 1
}

# Parse sections
section=""
features=()
accepts=()
attachments=()
issues=()
closed=()

while IFS= read -r line; do
  l="$(echo "${line}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "${l}" ]] && continue

  if echo "${l}" | grep -Eiq '^(#+\s*)?(功能|需求|Feature|Requirement)s?[:：]?$'; then section="feature"; continue; fi
  if echo "${l}" | grep -Eiq '^(#+\s*)?(验收标准|验收|Acceptance Criteria|AC)[:：]?$'; then section="accept"; continue; fi
  if echo "${l}" | grep -Eiq '^(#+\s*)?(附件|Attachments?)[:：]?$'; then section="attach"; continue; fi
  if echo "${l}" | grep -Eiq '^(#+\s*)?(问题|Issues?)[:：]?$'; then section="issues"; continue; fi
  if echo "${l}" | grep -Eiq '^(#+\s*)?(已解决|已修复|Closed|Resolved)[:：]?$'; then section="closed"; continue; fi

  if [[ "${section}" == "feature" && "${l}" =~ ^(-|\*|[0-9]+\.)[[:space:]]+ ]]; then
    item="$(echo "${l}" | sed -E 's/^(-|\*|[0-9]+\.)[[:space:]]+//')"
    [[ -n "${item}" ]] && features+=("${item}")
  fi

  if [[ "${section}" == "accept" && "${l}" =~ ^(-|\*|[0-9]+\.)[[:space:]]+ ]]; then
    item="$(echo "${l}" | sed -E 's/^(-|\*|[0-9]+\.)[[:space:]]+//')"
    [[ -n "${item}" ]] && accepts+=("${item}")
  fi

  if [[ "${section}" == "attach" && "${l}" =~ ^(-|\*|[0-9]+\.)[[:space:]]+ ]]; then
    item="$(echo "${l}" | sed -E 's/^(-|\*|[0-9]+\.)[[:space:]]+//')"
    [[ -n "${item}" ]] && attachments+=("${item}")
  fi

  if [[ "${section}" == "issues" && "${l}" =~ ^(-|\*|[0-9]+\.)[[:space:]]+ ]]; then
    item="$(echo "${l}" | sed -E 's/^(-|\*|[0-9]+\.)[[:space:]]+//')"
    [[ -n "${item}" ]] && issues+=("${item}")
  fi

  if [[ "${section}" == "closed" && "${l}" =~ ^(-|\*|[0-9]+\.)[[:space:]]+ ]]; then
    item="$(echo "${l}" | sed -E 's/^(-|\*|[0-9]+\.)[[:space:]]+//')"
    [[ -n "${item}" ]] && closed+=("${item}")
  fi

done <<< "${prompt_norm}"

# Fallback single-line markers
if [[ "${#features[@]}" -eq 0 ]]; then
  while IFS= read -r line; do
    if echo "$line" | grep -Eiq '^(功能|需求)[:：]'; then
      item="$(echo "$line" | sed -E 's/^(功能|需求)[:：][[:space:]]*//')"
      [[ -n "${item}" ]] && features+=("${item}")
    fi
  done <<< "${prompt_norm}"
fi

if [[ "${#accepts[@]}" -eq 0 ]]; then
  while IFS= read -r line; do
    if echo "$line" | grep -Eiq '^(验收标准|验收|AC)[:：]'; then
      item="$(echo "$line" | sed -E 's/^(验收标准|验收|AC)[:：][[:space:]]*//')"
      [[ -n "${item}" ]] && accepts+=("${item}")
    fi
  done <<< "${prompt_norm}"
fi

if [[ "${#attachments[@]}" -eq 0 ]]; then
  while IFS= read -r line; do
    if echo "$line" | grep -Eiq '^(附件|Attachment)s?[:：]'; then
      item="$(echo "$line" | sed -E 's/^(附件|Attachment)s?[:：][[:space:]]*//')"
      [[ -n "${item}" ]] && attachments+=("${item}")
    fi
  done <<< "${prompt_norm}"
fi

if [[ "${#issues[@]}" -eq 0 ]]; then
  while IFS= read -r line; do
    if echo "$line" | grep -Eiq '^(问题|Issues?)[:：]'; then
      item="$(echo "$line" | sed -E 's/^(问题|Issues?)[:：][[:space:]]*//')"
      [[ -n "${item}" ]] && issues+=("${item}")
    fi
  done <<< "${prompt_norm}"
fi

if [[ "${#closed[@]}" -eq 0 ]]; then
  while IFS= read -r line; do
    if echo "$line" | grep -Eiq '^(已解决|已修复|Closed|Resolved)[:：]'; then
      item="$(echo "$line" | sed -E 's/^(已解决|已修复|Closed|Resolved)[:：][[:space:]]*//')"
      [[ -n "${item}" ]] && closed+=("${item}")
    fi
  done <<< "${prompt_norm}"
fi

if [[ "${#features[@]}" -eq 0 && "${#accepts[@]}" -eq 0 && "${#attachments[@]}" -eq 0 && "${#issues[@]}" -eq 0 && "${#closed[@]}" -eq 0 ]]; then
  echo "[req-from-prompt] no feature/acceptance/attachments/issues detected (skip)"
  exit 0
fi

# Choose target (only when there is actionable content)
target_spec="$(parse_target_directive 2>/dev/null || true)"
target_spec="$(trim "${target_spec}")"

if [[ -z "${target_spec}" ]]; then
  if [[ -t 0 ]]; then
    if ! target_spec="$(choose_target_interactive)" || [[ -z "${target_spec}" ]]; then
      echo "[req-from-prompt] abort (no target selected)" >&2
      exit 64
    fi
  else
    echo "[req-from-prompt] Target is required to avoid mixing Solution vs Project requirements." >&2
    echo "[req-from-prompt] Add one of:" >&2
    echo "  Target: Solution" >&2
    echo "  Target: Project:<Name>" >&2
    echo >&2
    echo "[req-from-prompt] Detected projects:" >&2
    if [[ "${#PROJS[@]}" -eq 0 ]]; then
      echo "  (none detected)" >&2
    else
      i=1
      for p in "${PROJS[@]}"; do
        echo "  ${i}) ${p}    (use: Target: Project:${p})" >&2
        i=$((i+1))
      done
    fi
    exit 64
  fi
fi

target=""
if echo "${target_spec}" | grep -Eiq '^Solution$'; then
  target="${SOL_REQ}"
elif echo "${target_spec}" | grep -Eiq '^Project[[:space:]]*[:：]'; then
  proj="$(echo "${target_spec}" | sed -E 's/^Project[[:space:]]*[:：][[:space:]]*//I')"
  proj="$(trim "${proj}")"
  if [[ -z "${proj}" ]]; then
    echo "[req-from-prompt] invalid Target (missing project name): ${target_spec}" >&2
    exit 64
  fi
  if ! project_exists "${proj}"; then
    echo "[req-from-prompt] unknown project in Target: ${proj}" >&2
    echo "[req-from-prompt] detected projects: ${PROJS[*]:-(none)}" >&2
    exit 64
  fi
  target="${SOL_DIR}/.${proj}/.${proj}.requirements.md"
else
  echo "[req-from-prompt] invalid Target: ${target_spec}" >&2
  echo "[req-from-prompt] expected: 'Target: Solution' or 'Target: Project:<Name>'" >&2
  if [[ "${#PROJS[@]}" -gt 0 ]]; then
    echo "[req-from-prompt] examples:" >&2
    echo "  Target: Solution" >&2
    for p in "${PROJS[@]}"; do
      echo "  Target: Project:${p}" >&2
    done
  fi
  exit 64
fi

mkdir -p "$(dirname "${target}")"
touch "${target}"

ensure_section() {
  local title="$1"
  if ! grep -qF "${title}" "${target}"; then
    {
      echo
      echo "${title}"
      echo
      echo "<!-- RAYMAN:AUTOGEN: marker blocks are managed automatically -->"
      echo
    } >> "${target}"
  fi
}
ensure_section "## 功能需求（来自Prompt，自动维护）"
ensure_section "## 验收标准（来自Prompt，自动维护）"
ensure_section "## 附件（来自Prompt，自动维护，可手工追加）"
ensure_section "## 问题清单（来自Prompt，自动维护，必须闭环）"

norm_text() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]\+/ /g' | sed 's/^ *//;s/ *$//'; }

now_ts() { date -Iseconds; }

epoch_from_ts() {
  local ts="$1"
  date -d "${ts}" +%s 2>/dev/null || true
}

ts_from_epoch() {
  local e="$1"
  date -Iseconds -d "@${e}" 2>/dev/null || now_ts
}

upsert_block() {
  local kind="$1" # FEATURE / ACCEPT / ATTACH / ISSUE
  local text="$2"
  local norm; norm="$(norm_text "${text}")"
  [[ -z "${norm}" ]] && return 0
  local id; id="$(printf "%s" "${norm}" | sha1sum | awk '{print $1}')"
  local begin_prefix="<!-- RAYMAN:${kind}:BEGIN id=${id}"
  local end="<!-- RAYMAN:${kind}:END id=${id} -->"

  local now now_epoch
  now="$(now_ts)"
  now_epoch="$(epoch_from_ts "${now}")"
  [[ -z "${now_epoch}" ]] && now_epoch="$(date +%s)"

  # Existing block?
  if grep -qF "${begin_prefix}" "${target}"; then
    local begin_line old_ts old_epoch
    begin_line="$(grep -F "${begin_prefix}" "${target}" | head -n 1)"

    old_ts=""
    if [[ "${begin_line}" =~ ts=([^[:space:]>]+) ]]; then
      old_ts="${BASH_REMATCH[1]}"
    fi

    old_epoch=""
    if [[ -n "${old_ts}" ]]; then
      old_epoch="$(epoch_from_ts "${old_ts}")"
    fi
    if [[ -z "${old_epoch}" ]]; then
      # Backfill missing/invalid ts to slightly earlier than now, so new content can overwrite.
      old_epoch=$((now_epoch-60))
      old_ts="$(ts_from_epoch "${old_epoch}")"
      new_begin_line="<!-- RAYMAN:${kind}:BEGIN id=${id} ts=${old_ts} -->"
      perl -pi -e "s/\Q${begin_line}\E/${new_begin_line}/" "${target}" || true
      begin_line="${new_begin_line}"
    fi

    existing="$(perl -0777 -ne 'if(/RAYMAN:'"${kind}"':BEGIN id='"${id}"'[^>]*-->(.*?)\Q'"${end}"'\E/s){print $1}' "${target}" | sed -E 's/^\s*//;s/\s*$//' | sed -E 's/^- //g')"
    ex_norm="$(norm_text "${existing}")"

    # Decide overwrite by ts when content differs.
    if [[ "${ex_norm}" != "${norm}" ]]; then
      if [[ "${now_epoch}" -le "${old_epoch}" ]]; then
        echo "[req-from-prompt] keep ${kind} (new ts<=old ts): ${id}";
        return 0
      fi
    fi

    begin_new="<!-- RAYMAN:${kind}:BEGIN id=${id} ts=${now} -->"
    block="${begin_new}
- ${text}
${end}"
    perl -0777 -i -pe "s/\Q${begin_prefix}\E[^>]*-->.*?\Q${end}\E/${block}/s" "${target}"
    echo "[req-from-prompt] updated ${kind}: ${id}"
  else
    begin_new="<!-- RAYMAN:${kind}:BEGIN id=${id} ts=$(now_ts) -->"
    {
      echo
      echo "${begin_new}"
      echo "- ${text}"
      echo "${end}"
    } >> "${target}"
    echo "[req-from-prompt] added ${kind}: ${id}"
  fi
}

for f in "${features[@]}"; do upsert_block "FEATURE" "${f}"; done
for a in "${accepts[@]}"; do upsert_block "ACCEPT" "${a}"; done
for x in "${attachments[@]}"; do upsert_block "ATTACH" "${x}"; done
for it in "${issues[@]}"; do upsert_block "ISSUE" "${it}"; done

# Prune legacy empty blocks (can be introduced if earlier versions iterated an empty default value)
EMPTY_ID="da39a3ee5e6b4b0d3255bfef95601890afd80709"
prune_empty_id_block() {
  local kind="$1"
  local begin_prefix="<!-- RAYMAN:${kind}:BEGIN id=${EMPTY_ID}"
  local end="<!-- RAYMAN:${kind}:END id=${EMPTY_ID} -->"
  grep -qF "${begin_prefix}" "${target}" || return 0
  perl -0777 -i -pe "s/\n?\Q${begin_prefix}\E[^>]*-->\s*\n-?[[:space:]]*\n\Q${end}\E\s*//g" "${target}" || true
}
prune_empty_id_block "FEATURE"
prune_empty_id_block "ACCEPT"
prune_empty_id_block "ATTACH"
prune_empty_id_block "ISSUE"

# Sync issues state file (gate relies on this)
sync_issues_state() {
  local f=".Rayman/runtime/issues.open.md"
  mkdir -p .Rayman/runtime
  touch "$f"

  local now; now="$(now_ts)"

  local norm id begin_prefix begin end
  for it in "${issues[@]:-}"; do
    norm="$(norm_text "$it")"; id="$(printf "%s" "$norm" | sha1sum | awk '{print $1}')"
    begin_prefix="<!-- RAYMAN:ISSUE:BEGIN id=${id}"; end="<!-- RAYMAN:ISSUE:END id=${id} -->"
    begin="<!-- RAYMAN:ISSUE:BEGIN id=${id} ts=${now} -->"
    block="${begin}
- [ ] ${it}
${end}"
    if grep -qF "$begin_prefix" "$f"; then
      perl -0777 -i -pe "s/\Q${begin_prefix}\E[^>]*-->.*?\Q${end}\E/${block}/s" "$f"
    else
      printf "\n%s\n" "$block" >> "$f"
    fi
  done

  for it in "${closed[@]:-}"; do
    norm="$(norm_text "$it")"; id="$(printf "%s" "$norm" | sha1sum | awk '{print $1}')"
    begin_prefix="<!-- RAYMAN:ISSUE:BEGIN id=${id}"; end="<!-- RAYMAN:ISSUE:END id=${id} -->"
    begin="<!-- RAYMAN:ISSUE:BEGIN id=${id} ts=${now} -->"
    block="${begin}
- [x] ${it}
${end}"
    if grep -qF "$begin_prefix" "$f"; then
      perl -0777 -i -pe "s/\Q${begin_prefix}\E[^>]*-->.*?\Q${end}\E/${block}/s" "$f"
    else
      printf "\n%s\n" "$block" >> "$f"
    fi
  done
}

if [[ "${#issues[@]}" -gt 0 || "${#closed[@]}" -gt 0 ]]; then
  sync_issues_state
  echo "[req-from-prompt] issues synced: .Rayman/runtime/issues.open.md"
fi

echo "[req-from-prompt] wrote: ${target}"
