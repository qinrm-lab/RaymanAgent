#!/usr/bin/env bash
set -euo pipefail

# Detect SolutionName with the following priority:
# 1) Root file .SolutionName (preferred by this repo convention)
# 2) Root .<SolutionName>.requirements.md (single)
# 3) Root dot-solution directory .<SolutionName>/ containing requirements
# 4) Unique *.slnx in root
# 5) Unique *.sln in root

sanitize_solution_name() {
  local raw="${1:-}"
  # Strip CR + UTF-8 BOM bytes and trim whitespace.
  printf '%s' "$raw" | tr -d '\r' | sed $'s/\xEF\xBB\xBF//g' | xargs
}

if [[ -f ".SolutionName" ]]; then
  sol="$(sanitize_solution_name "$(grep -m1 -E '\S' ".SolutionName" || true)")"
  if [[ -n "${sol:-}" ]]; then
    echo "$sol"
    exit 0
  fi
fi

mapfile -t SOL_REQS < <(find . -maxdepth 1 -type f -name ".*.requirements.md" ! -name ".temp.requirements.md" | sort)
if [[ "${#SOL_REQS[@]}" -eq 1 ]]; then
  b="$(basename "${SOL_REQS[0]}")"
  n="${b#.}"; n="${n%.requirements.md}"
  n="$(sanitize_solution_name "$n")"
  echo "$n"; exit 0
fi

mapfile -t DOT_DIRS < <(find . -maxdepth 1 -type d -name ".*" | sed 's|^\./||' | sort)
for d in "${DOT_DIRS[@]}"; do
  case "$d" in .|..|.git|.github|.Rayman|.vscode|.vs|.temp|.tmp) continue;; esac
  if find "$d" -maxdepth 3 -type f -name ".*.requirements.md" | grep -q .; then
    dn="$(sanitize_solution_name "${d#.}")"
    echo "$dn"; exit 0
  fi
done

mapfile -t SLNXS < <(find . -maxdepth 1 -type f -name "*.slnx" | sort)
if [[ "${#SLNXS[@]}" -eq 1 ]]; then
  b="$(basename "${SLNXS[0]}")"
  n="$(sanitize_solution_name "${b%.slnx}")"
  echo "$n"; exit 0
fi

mapfile -t SLNS < <(find . -maxdepth 1 -type f -name "*.sln" | sort)
if [[ "${#SLNS[@]}" -eq 1 ]]; then
  b="$(basename "${SLNS[0]}")"
  n="$(sanitize_solution_name "${b%.sln}")"
  echo "$n"; exit 0
fi

echo "无法推断 SolutionName：请确保存在 .SolutionName 或唯一的 *.slnx/*.sln 或根目录存在 .<SolutionName>.requirements.md 或 .<SolutionName>/ 目录" >&2
exit 2
