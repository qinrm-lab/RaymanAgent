#!/usr/bin/env bash
set -euo pipefail
if [[ "${RAYMAN_DEBUG:-0}" == "1" ]]; then set -x; fi

ROOT="$(pwd)"

SOL="$(bash ./.Rayman/scripts/requirements/detect_solution.sh)"
SOL_DIR=".${SOL}"
# all requirements stay under .<SolutionName>/
SOL_REQ="${SOL_DIR}/.${SOL}.requirements.md"
PROJ_LIST_HEADER="## Project requirements 列表（必须逐一遵守）"

mkdir -p "${SOL_DIR}"

mapfile -t PROJS < <(bash ./.Rayman/scripts/requirements/detect_projects.sh || true)
TEMPLATE_PRIMARY="${ROOT}/.Rayman/templates/requirements.project.template.md"
TEMPLATE_DIST="${ROOT}/.Rayman/.dist/templates/requirements.project.template.md"
TEMPLATE=""
TEMPLATE_SOURCE="builtin-fallback"

if [[ -f "${TEMPLATE_PRIMARY}" ]]; then
  TEMPLATE="${TEMPLATE_PRIMARY}"
  TEMPLATE_SOURCE="workspace-template"
elif [[ -f "${TEMPLATE_DIST}" ]]; then
  TEMPLATE="${TEMPLATE_DIST}"
  TEMPLATE_SOURCE="dist-template"
fi

echo "[req] template source: ${TEMPLATE_SOURCE}"

render_project_template() {
  local project_name="$1"
  if [[ -n "${TEMPLATE}" && -f "${TEMPLATE}" ]]; then
    local escaped
    escaped="$(printf '%s' "${project_name}" | sed -e 's/[\/&]/\\&/g')"
    sed "s/{{PROJECT_NAME}}/${escaped}/g" "${TEMPLATE}"
    return 0
  fi

  cat <<EOF
# ${project_name} 项目 Requirements（强制约束）

## 项目范围
- 本文件定义 **${project_name}** 项目的强制约束规则。
- 任何涉及该项目的代码修改 / 测试执行，都必须遵守本文件。

## 必须遵守的规则（请按项目实际补充）
- （示例）不得随意修改公共 API（除非同步更新依赖项目）
- （示例）新增依赖必须说明原因与替代方案
- （示例）涉及配置变更必须同步更新部署/运行文档

## 测试要求（请按项目实际补充）
- （示例）修改必须通过现有测试
- （示例）新增行为必须补充测试用例

## 附件（可选，支持复杂操作）
- 允许在本项目 requirements 旁边添加附件文件（例如：截图、操作步骤、脚本片段、示例输入输出）。
- 建议放在同目录的 \`attachments/\` 下，并在此处列出相对路径与用途。
- **注意：附件是 requirements 的一部分**，涉及修改时需同步更新。

## 功能需求（来自Prompt，自动维护）

<!-- RAYMAN:AUTOGEN: marker blocks are managed automatically -->

## 验收标准（来自Prompt，自动维护）

<!-- RAYMAN:AUTOGEN: marker blocks are managed automatically -->

## 附件（来自Prompt，自动维护，可手工追加）

<!-- RAYMAN:AUTOGEN: marker blocks are managed automatically -->
EOF
}

for p in "${PROJS[@]}"; do
  pd="${SOL_DIR}/.${p}"
  pf="${pd}/.${p}.requirements.md"
  mkdir -p "${pd}"
  if [[ ! -f "${pf}" ]]; then
    render_project_template "${p}" > "${pf}"
    echo "[req] wrote: ${pf}"
  fi
done

# Migrate legacy requirements (root layout) into new structure (idempotent)
bash ./.Rayman/scripts/requirements/migrate_legacy_requirements.sh || true

build_project_list_file() {
  local out_file="$1"
  local count=0
  : > "${out_file}"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    rel="${f#./}"
    [[ "$rel" == "${SOL_REQ#./}" ]] && continue
    echo "- ${rel}" >> "${out_file}"
    count=$((count + 1))
  done < <(find "${SOL_DIR}" -maxdepth 3 -type f -name ".*.requirements.md" | sort)

  if [[ "${count}" -eq 0 ]]; then
    echo "- (none detected)" >> "${out_file}"
  fi
}

write_solution_requirements() {
  local project_list_file="$1"
  {
    echo "# ${SOL} Solution Requirements（强制约束）"
    echo
    echo "## 必须先读这个文件"
    echo "- 本文件为 Solution 级强制约束，必须执行。"
    echo "- 本文件必须包含全部 Project requirements（按路径文本列出）。"
    echo
    echo "${PROJ_LIST_HEADER}"
    echo
    cat "${project_list_file}"
    echo
    echo "## 说明"
    echo "- CI 会校验：此文件必须包含上述每一条路径文本。"
    echo "- 约定：Solution/Project requirements 均在 ${SOL_DIR}/ 下，不应在根目录出现 .*.requirements.md"
  } > "${SOL_REQ}"
  echo "[req] wrote: ${SOL_REQ}"
}

refresh_project_list_section() {
  local project_list_file="$1"
  local tmp
  tmp="$(mktemp)"

  awk -v header="${PROJ_LIST_HEADER}" -v list_file="${project_list_file}" '
    function print_list() {
      while ((getline line < list_file) > 0) {
        print line
      }
      close(list_file)
    }
    {
      if ($0 == header) {
        found = 1
        in_section = 1
        print $0
        print ""
        print_list()
        print ""
        next
      }

      if (in_section == 1) {
        if ($0 ~ /^## /) {
          in_section = 0
          print $0
        }
        next
      }

      print $0
    }
    END {
      if (found == 0) {
        if (NR > 0) {
          print ""
        }
        print header
        print ""
        print_list()
        print ""
      }
    }
  ' "${SOL_REQ}" > "${tmp}"

  mv "${tmp}" "${SOL_REQ}"
  echo "[req] refreshed project list: ${SOL_REQ}"
}

project_list_tmp="$(mktemp)"
build_project_list_file "${project_list_tmp}"

# Build / refresh solution-level index
if [[ ! -f "${SOL_REQ}" || "${RAYMAN_FORCE_REBUILD:-0}" == "1" ]]; then
  write_solution_requirements "${project_list_tmp}"
else
  refresh_project_list_section "${project_list_tmp}"
fi

rm -f "${project_list_tmp}"
