#!/usr/bin/env bash
set -euo pipefail
if [[ "${RAYMAN_DEBUG:-0}" == "1" ]]; then set -x; fi

ROOT="${RAYMAN_ROOT:-$(pwd)}"
RULES_FILE="${ROOT}/.Rayman/skills/rules.json"
OUT_MD="${ROOT}/.Rayman/context/skills.auto.md"
OUT_ENV="${ROOT}/.Rayman/runtime/skills.env"

mkdir -p "$(dirname "$OUT_MD")" "$(dirname "$OUT_ENV")"

if [[ "${RAYMAN_SKILLS_OFF:-0}" == "1" ]]; then
  cat >"$OUT_MD" <<EOF
# Skills（自动）— 已关闭

> 你设置了 \`RAYMAN_SKILLS_OFF=1\`，因此未生成自动 skills。

EOF
  echo "export RAYMAN_SKILLS_SELECTED=" >"$OUT_ENV"
  echo "[skills] auto disabled"
  exit 0
fi

if [[ ! -f "$RULES_FILE" ]]; then
  echo "[skills] rules not found: $RULES_FILE" >&2
  exit 1
fi

# Collect filenames (avoid huge dirs)
mapfile -t FILES < <(find "$ROOT" \
  -path "$ROOT/.git" -prune -o \
  -path "$ROOT/.Rayman/runtime" -prune -o \
  -path "$ROOT/node_modules" -prune -o \
  -type f -print 2>/dev/null | head -n 8000)

# Collect keyword corpus from recent logs (best-effort)
CORPUS=""
if [[ -d "$ROOT/.Rayman/logs" ]]; then
  CORPUS+=" $(tail -n 3000 "$ROOT"/.Rayman/logs/*.log 2>/dev/null | tr '\n' ' ' | head -c 200000)"
fi
if [[ -d "$ROOT/.Rayman/runtime" ]]; then
  CORPUS+=" $(tail -n 3000 "$ROOT"/.Rayman/runtime/**/*.log 2>/dev/null | tr '\n' ' ' | head -c 200000)"
fi
CORPUS+=" $(tail -n 3000 "$ROOT"/.Rayman/init.*.log 2>/dev/null | tr '\n' ' ' | head -c 200000)"

export ROOT RULES_FILE OUT_MD OUT_ENV
export FORCE="${RAYMAN_SKILLS_FORCE:-}"
export FILES_TEXT="$(printf "%s\n" "${FILES[@]}")"
export CORPUS_TEXT="$CORPUS"

python3 - <<'PY'
import os, json, pathlib, datetime

root=pathlib.Path(os.environ["ROOT"])
rules_path=pathlib.Path(os.environ["RULES_FILE"])
out_md=pathlib.Path(os.environ["OUT_MD"])
out_env=pathlib.Path(os.environ["OUT_ENV"])
force=os.environ.get("FORCE","").strip()

rules=json.loads(rules_path.read_text(encoding="utf-8"))
skills=rules.get("skills",{})
defaults=rules.get("defaults",[])

files=[f for f in (os.environ.get("FILES_TEXT") or "").splitlines() if f.strip()]
corpus=(os.environ.get("CORPUS_TEXT") or "").lower()

def norm_ext(p: str)->str:
    name=pathlib.Path(p).name.lower()
    special={"package.json","pnpm-lock.yaml","yarn.lock","package-lock.json","requirements.txt","pyproject.toml"}
    if name in special:
        return name
    return pathlib.Path(p).suffix.lower()

detected=set()

exts=[norm_ext(f) for f in files]
for sk, conf in skills.items():
    for e in conf.get("match_ext",[]):
        if e.lower() in exts:
            detected.add(sk); break

for sk, conf in skills.items():
    kws=[k.lower() for k in conf.get("match_keywords",[])]
    if kws and any(k in corpus for k in kws):
        detected.add(sk)

# conservative defaults: only seed infra-related ones
for d in defaults:
    if d in skills:
        detected.add(d)

if force:
    detected=set([s.strip() for s in force.split(",") if s.strip()])

ordered=[]
for sk in skills.keys():
    if sk in detected:
        ordered.append(sk)
for sk in sorted(detected):
    if sk not in ordered:
        ordered.append(sk)

ts=datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
lines=[]
lines.append("# Skills（自动）\n")
lines.append(f"> 生成时间：{ts}")
lines.append(f"> 选择结果：{', '.join(ordered) if ordered else '(none)'}\n")
if force:
    lines.append(f"> 已强制：RAYMAN_SKILLS_FORCE={force}\n")

lines.append("## 你应当使用的能力/工具\n")
if not ordered:
    lines.append("- 未检测到明显的产物类型；按常规工程/调试流程即可。")
else:
    for sk in ordered:
        hint=skills.get(sk,{}).get("hint","").strip()
        if hint:
            lines.append(f"- **{sk}**：{hint}")
        else:
            lines.append(f"- **{sk}**")

lines.append("\n## 覆盖/关闭\n")
lines.append("- 关闭自动：`RAYMAN_SKILLS_OFF=1`")
lines.append("- 强制指定：`RAYMAN_SKILLS_FORCE=pdfs,docs,spreadsheets`")
lines.append("")

out_md.write_text("\n".join(lines), encoding="utf-8")
out_env.write_text(f'export RAYMAN_SKILLS_SELECTED="{",".join(ordered)}"\n', encoding="utf-8")
print("[skills] selected:", ",".join(ordered))
PY

# shellcheck disable=SC1090
source "$OUT_ENV" || true
echo "[skills] wrote: $OUT_MD"

bash "$RAYMAN_DIR/scripts/skills/inject_codex_fix_prompt.sh" || true
