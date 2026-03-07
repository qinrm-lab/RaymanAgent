#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RAYMAN_DIR="$ROOT_DIR/.Rayman"
PROMPT_FILE="$RAYMAN_DIR/codex_fix_prompt.txt"
BASE_FILE="$RAYMAN_DIR/templates/codex_fix_prompt.base.txt"
AUTO_MD="$RAYMAN_DIR/context/skills.auto.md"

SKILLS_SELECTED="${RAYMAN_SKILLS_SELECTED:-}"
NOW="$(date +"%Y-%m-%d %H:%M:%S")"

begin_marker='<!-- RAYMAN:SKILLS:BEGIN -->'
end_marker='<!-- RAYMAN:SKILLS:END -->'

header="$(cat <<EOF
$begin_marker
# Skills（自动注入）

- 时间：$NOW
- 推断结果：${SKILLS_SELECTED:-（未生成）}
- 详细建议：$AUTO_MD

要求：
- 开始工作前，先阅读并遵守上面 skills 建议。
- 如果建议与实际冲突，以可复现/可验证为准，并在输出中解释原因。

$end_marker
EOF
)"

mkdir -p "$RAYMAN_DIR/runtime"

# Ensure prompt exists
if [ ! -f "$PROMPT_FILE" ]; then
  if [ -f "$BASE_FILE" ]; then
    cp "$BASE_FILE" "$PROMPT_FILE"
  else
    printf "%s\n" "# Rayman Codex Fix Prompt (auto-created)" > "$PROMPT_FILE"
  fi
fi

# Backup (best-effort)
cp "$PROMPT_FILE" "$RAYMAN_DIR/runtime/codex_fix_prompt.bak.txt" 2>/dev/null || true

# If markers exist -> replace block; else -> prepend with markers
if grep -qF "$begin_marker" "$PROMPT_FILE" && grep -qF "$end_marker" "$PROMPT_FILE"; then
  # Use awk to replace between markers (inclusive)
  awk -v b="$begin_marker" -v e="$end_marker" -v h="$header" '
    BEGIN{inblk=0}
    index($0,b){print h; inblk=1; next}
    index($0,e){inblk=0; next}
    inblk==0{print}
  ' "$PROMPT_FILE" > "$PROMPT_FILE.tmp"
  mv "$PROMPT_FILE.tmp" "$PROMPT_FILE"
else
  # Prepend
  {
    printf "%s\n\n" "$header"
    cat "$PROMPT_FILE"
  } > "$PROMPT_FILE.tmp"
  mv "$PROMPT_FILE.tmp" "$PROMPT_FILE"
fi
