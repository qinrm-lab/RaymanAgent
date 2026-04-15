#!/usr/bin/env bash
set -euo pipefail
if [[ "${RAYMAN_DEBUG:-0}" == "1" ]]; then set -x; fi

TEMPLATE=".Rayman/agents.template.md"
RESOLVE_SCRIPT=".Rayman/scripts/agents/resolve_agents_file.sh"
CANONICAL="AGENTS.md"

[[ -f "${TEMPLATE}" ]] || { echo "[agent] template missing: ${TEMPLATE}" >&2; exit 2; }
[[ -f "${RESOLVE_SCRIPT}" ]] || { echo "[agent] resolve script missing: ${RESOLVE_SCRIPT}" >&2; exit 2; }

AGENTS_PATH="$(bash "${RESOLVE_SCRIPT}" --canonicalize)"
if [[ ! -f "${AGENTS_PATH}" ]]; then
  cp "${TEMPLATE}" "${AGENTS_PATH}"
  echo "[agent] wrote: ${AGENTS_PATH}"
fi

tmp="$(mktemp)"
in_block=0
while IFS= read -r line; do
  if [[ "$line" =~ "<!-- RAYMAN:MANDATORY_REQUIREMENTS" ]]; then
    in_block=1; continue
  fi
  if [[ "$line" =~ "<!-- /RAYMAN:MANDATORY_REQUIREMENTS" ]]; then
    in_block=0; continue
  fi
  if [[ "$line" =~ "<!-- RAYMAN:MANAGED_REFERENCES:BEGIN" ]]; then
    in_block=1; continue
  fi
  if [[ "$line" =~ "<!-- /RAYMAN:MANAGED_REFERENCES:END" ]]; then
    in_block=0; continue
  fi
  [[ "$in_block" -eq 0 ]] && echo "$line" >> "$tmp"
done < "${AGENTS_PATH}"

block="$(awk '
  /<!-- RAYMAN:MANDATORY_REQUIREMENTS/ { flag=1 }
  flag { print }
  /<!-- \/RAYMAN:MANDATORY_REQUIREMENTS/ && flag==1 { flag=0; exit }
' "${TEMPLATE}")"

managed_refs_block="$(cat <<'EOF'
<!-- RAYMAN:MANAGED_REFERENCES:BEGIN -->
## Rayman Managed References

- 自动建议 skills：`./.Rayman/context/skills.auto.md`
- 发布纪律：遵守 `.Rayman/RELEASE_REQUIREMENTS.md`
<!-- /RAYMAN:MANAGED_REFERENCES:END -->
EOF
)"

if [[ -z "${block// }" ]]; then
  echo "[agent] mandatory requirements block missing in template: ${TEMPLATE}" >&2
  rm -f "$tmp" "$tmp.new" 2>/dev/null || true
  exit 2
fi

# Make sure file ends with blank line then append block
printf "%s\n\n" "$(cat "$tmp")" > "$tmp.new"
echo "$block" >> "$tmp.new"
echo >> "$tmp.new"
echo "$managed_refs_block" >> "$tmp.new"
mv "$tmp.new" "${AGENTS_PATH}"
echo "[agent] normalized: ${AGENTS_PATH} (deduped mandatory block)"

# Replace placeholder with actual solution requirements filename if available
SOL="$(bash ./.Rayman/scripts/requirements/detect_solution.sh || true)"
if [[ -n "${SOL}" ]]; then
  SOL_DIR=".${SOL}"
  sol_file="${SOL_DIR}/.${SOL}.requirements.md"
  if [[ -f "${sol_file}" ]]; then
    sol_base="${sol_file#./}"
    # New canonical placeholder.
    sed -i "s|\\.<SolutionName>/\\.<SolutionName>\\.requirements\\.md|${sol_base}|g" "${AGENTS_PATH}" || true
    # Backward-compatible placeholder from legacy templates.
    sed -i "s|\\.<SolutionName>\\.requirements\\.md|${sol_base}|g" "${AGENTS_PATH}" || true
  fi
fi

# Canonical name is AGENTS.md; keep legacy readers compatible by allowing fallback resolution.
if [[ "${AGENTS_PATH}" != "${CANONICAL}" ]]; then
  echo "[agent] warn: non-canonical agents path resolved to ${AGENTS_PATH}" >&2
fi
