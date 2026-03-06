#!/usr/bin/env bash
set -euo pipefail

# Prefer parsing Solution (*.sln / *.slnx) to get the real project list.
# Fallback to legacy directory scanning when no solution is available.

declare -A seen=()

emit() {
  local name="$1"
  [[ -z "$name" ]] && return 0
  if [[ -z "${seen[$name]+x}" ]]; then
    seen["$name"]=1
    echo "$name"
  fi
}

is_excluded_dir() {
  case "$1" in
    .*|.git|.github|.Rayman|.vscode|.vs|.temp|.tmp|out|bin|obj|node_modules) return 0 ;;
    *) return 1 ;;
  esac
}

try_parse_solution() {
  local f="$1"
  [[ -f "$f" ]] || return 1

  if [[ "$f" == *.slnx ]]; then
    # slnx best-effort: extract dotnet project paths; use basename (no extension) as project name.
    while IFS= read -r p; do
      p_norm="${p//\\//}"
      n="$(basename "$p_norm")"
      n="${n%.*}"
      emit "$n"
    done < <(grep -Eo '[^"\x27]+\.(csproj|vbproj|fsproj)' "$f" | sort -u)
    return 0
  fi

  local re='= "([^"]+)"\, "([^"]+)"'
  while IFS= read -r line; do
    [[ "$line" == Project* ]] || continue
    if [[ "$line" =~ $re ]]; then
      local name="${BASH_REMATCH[1]}"
      local path="${BASH_REMATCH[2]}"
      local p_norm="${path//\\//}"
      if [[ "$p_norm" == *.csproj || "$p_norm" == *.vbproj || "$p_norm" == *.fsproj ]]; then
        emit "$name"
      fi
    fi
  done < "$f"
  return 0
}

score_solution() {
  local f="$1"
  [[ -f "$f" ]] || { echo 0; return 0; }
  if [[ "$f" == *.sln ]]; then
    grep -E '^Project\(' "$f" | grep -E '\.(csproj|vbproj|fsproj)"' | wc -l | tr -d ' '
  else
    grep -Eo '\.(csproj|vbproj|fsproj)' "$f" | wc -l | tr -d ' '
  fi
}

pick_best_solution() {
  local sol_name="$1"
  local best="" best_score=-1

  mapfile -t FILES < <(find . -maxdepth 2 -type f \( -name "*.sln" -o -name "*.slnx" \) | sort)
  [[ ${#FILES[@]} -eq 0 ]] && { echo ""; return 0; }

  if [[ -n "${sol_name}" ]]; then
    for s in "${FILES[@]}"; do
      b="$(basename "$s")"
      if [[ "${b%.*}" == "$sol_name" && "$b" == *.slnx ]]; then
        echo "$s"; return 0
      fi
    done
    for s in "${FILES[@]}"; do
      b="$(basename "$s")"
      if [[ "${b%.*}" == "$sol_name" ]]; then
        echo "$s"; return 0
      fi
    done
  fi

  mapfile -t SLNX_FILES < <(printf '%s\n' "${FILES[@]}" | grep -E '\.slnx$' || true)
  mapfile -t SLN_FILES < <(printf '%s\n' "${FILES[@]}" | grep -E '\.sln$' || true)
  local -a CANDIDATES=()
  if [[ ${#SLNX_FILES[@]} -gt 0 ]]; then
    CANDIDATES=("${SLNX_FILES[@]}")
  else
    CANDIDATES=("${SLN_FILES[@]}")
  fi

  for s in "${CANDIDATES[@]}"; do
    sc="$(score_solution "$s")"
    if [[ "$sc" -gt "$best_score" ]]; then
      best_score="$sc"; best="$s"
    fi
  done

  echo "$best"
}

SOL="$(bash ./.Rayman/scripts/requirements/detect_solution.sh 2>/dev/null || true)"
SOLFILE="$(pick_best_solution "${SOL:-}")"

if [[ -n "$SOLFILE" ]]; then
  try_parse_solution "$SOLFILE" || true
fi

# Legacy fallback: scan top-level directories for project markers
for d in */ ; do
  d="${d%/}"
  [[ -d "$d" ]] || continue
  is_excluded_dir "$d" && continue

  if find "./$d" -maxdepth 4 -type f \( -name "*.csproj" -o -name "go.mod" -o -name "package.json" -o -name "pyproject.toml" -o -name "Cargo.toml" \) | grep -q .; then
    emit "$d"
  fi
done
