#!/usr/bin/env bash
set -euo pipefail

fail(){ echo "❌ [rayman-contract] $*" >&2; exit 8; }
ok(){ echo "OK"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${ROOT}/runtime/contract_update_from_prompt.XXXXXX")"
SANDBOX="${TMP_ROOT}/workspace"

cleanup() {
  rm -rf "${TMP_ROOT}" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "${SANDBOX}/.Rayman/scripts/requirements"
mkdir -p "${SANDBOX}/DemoProj"

copy_req_script(){
  local name="$1"
  cp "${ROOT}/scripts/requirements/${name}" "${SANDBOX}/.Rayman/scripts/requirements/${name}"
  chmod +x "${SANDBOX}/.Rayman/scripts/requirements/${name}" || true
}

copy_req_script "detect_solution.sh"
copy_req_script "detect_projects.sh"
copy_req_script "update_from_prompt.sh"

cat > "${SANDBOX}/.SolutionName" <<'EOF_SOL'
DemoSol
EOF_SOL

cat > "${SANDBOX}/DemoProj/DemoProj.csproj" <<'EOF_CSPROJ'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
  </PropertyGroup>
</Project>
EOF_CSPROJ

cat > "${SANDBOX}/prompt.no_target.md" <<'EOF_NO_TARGET'
功能:
- 支持测试契约场景
验收标准:
- 在非交互模式下，未指定 Target 必须失败
EOF_NO_TARGET

cat > "${SANDBOX}/prompt.bad_target.md" <<'EOF_BAD_TARGET'
Target: Project:GhostProject
功能:
- 不存在项目名必须失败
EOF_BAD_TARGET

cat > "${SANDBOX}/prompt.workspace_field_mismatch.md" <<'EOF_WS_FIELD_MISMATCH'
Workspace: OtherRepo
Target: Project:DemoProj
功能:
- 跨工作区必须暂停
EOF_WS_FIELD_MISMATCH

cat > "${SANDBOX}/prompt.workspace_prefix_mismatch.md" <<'EOF_WS_PREFIX_MISMATCH'
OtherRepo: 这不是当前工作区任务
Target: Project:DemoProj
功能:
- 跨工作区必须暂停
EOF_WS_PREFIX_MISMATCH

cat > "${SANDBOX}/prompt.good_target.md" <<'EOF_GOOD_TARGET'
Workspace: DemoSol
Target: Project:DemoProj
功能:
- 新增契约测试入口
验收标准:
- requirements 文件落盘并含 marker
问题:
- 示例问题
已解决:
- 示例已解决问题
EOF_GOOD_TARGET

pushd "${SANDBOX}" >/dev/null

set +e
bash ./.Rayman/scripts/requirements/update_from_prompt.sh "./prompt.no_target.md" </dev/null >/dev/null 2>&1
rc_no_target=$?
bash ./.Rayman/scripts/requirements/update_from_prompt.sh "./prompt.bad_target.md" </dev/null >/dev/null 2>&1
rc_bad_target=$?
bash ./.Rayman/scripts/requirements/update_from_prompt.sh "./prompt.workspace_field_mismatch.md" </dev/null >/dev/null 2>&1
rc_ws_field_mismatch=$?
bash ./.Rayman/scripts/requirements/update_from_prompt.sh "./prompt.workspace_prefix_mismatch.md" </dev/null >/dev/null 2>&1
rc_ws_prefix_mismatch=$?
set -e

[[ "${rc_no_target}" -eq 64 ]] || fail "missing target should exit 64, got ${rc_no_target}"
[[ "${rc_bad_target}" -eq 64 ]] || fail "invalid target should exit 64, got ${rc_bad_target}"
[[ "${rc_ws_field_mismatch}" -eq 65 ]] || fail "workspace field mismatch should exit 65, got ${rc_ws_field_mismatch}"
[[ "${rc_ws_prefix_mismatch}" -eq 65 ]] || fail "workspace prefix mismatch should exit 65, got ${rc_ws_prefix_mismatch}"

req_file=".DemoSol/.DemoProj/.DemoProj.requirements.md"
issues_file=".Rayman/runtime/issues.open.md"

[[ ! -f "${req_file}" ]] || fail "workspace mismatch should not create requirements file: ${req_file}"
[[ ! -f "${issues_file}" ]] || fail "workspace mismatch should not create issues file: ${issues_file}"

bash ./.Rayman/scripts/requirements/update_from_prompt.sh "./prompt.good_target.md" </dev/null >/dev/null

[[ -f "${req_file}" ]] || fail "requirements file not generated: ${req_file}"
[[ -f "${issues_file}" ]] || fail "issues state file not generated: ${issues_file}"

grep -Fq "RAYMAN:FEATURE:BEGIN" "${req_file}" || fail "feature marker missing in ${req_file}"
grep -Fq "RAYMAN:ACCEPT:BEGIN" "${req_file}" || fail "accept marker missing in ${req_file}"
grep -Fq "新增契约测试入口" "${req_file}" || fail "feature content missing in ${req_file}"
grep -Fq -- "- [ ] 示例问题" "${issues_file}" || fail "open issue not synced"
grep -Fq -- "- [x] 示例已解决问题" "${issues_file}" || fail "closed issue not synced"

popd >/dev/null

ok
