#!/usr/bin/env bats

setup_file() {
  export REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../../.." && pwd)"
}

make_workspace() {
  local root
  root="$(mktemp -d)"

  mkdir -p \
    "${root}/.Rayman/scripts/ci" \
    "${root}/.Rayman/scripts/requirements" \
    "${root}/.Rayman/scripts/agents" \
    "${root}/.Rayman/config" \
    "${root}/.RaymanAgent" \
    "${root}/.github"

  cp "${REPO_ROOT}/.Rayman/scripts/ci/validate_requirements.sh" "${root}/.Rayman/scripts/ci/validate_requirements.sh"
  cp "${REPO_ROOT}/.Rayman/scripts/requirements/detect_solution.sh" "${root}/.Rayman/scripts/requirements/detect_solution.sh"
  cp "${REPO_ROOT}/.Rayman/scripts/agents/resolve_agents_file.sh" "${root}/.Rayman/scripts/agents/resolve_agents_file.sh"
  cp "${REPO_ROOT}/.Rayman/config/agentic_pipeline.json" "${root}/.Rayman/config/agentic_pipeline.json"
  chmod +x \
    "${root}/.Rayman/scripts/ci/validate_requirements.sh" \
    "${root}/.Rayman/scripts/requirements/detect_solution.sh" \
    "${root}/.Rayman/scripts/agents/resolve_agents_file.sh"

  cat > "${root}/.SolutionName" <<'EOF'
RaymanAgent
EOF

  cat > "${root}/AGENTS.md" <<'EOF'
# AGENTS
<!-- RAYMAN:MANDATORY_REQUIREMENTS_V161 -->
## 强制 Requirements 规则（必须遵守）
1. 你必须先阅读并严格遵守 `.<SolutionName>/.<SolutionName>.requirements.md`。
<!-- /RAYMAN:MANDATORY_REQUIREMENTS_V161 -->
EOF

  cat > "${root}/.RaymanAgent/.RaymanAgent.requirements.md" <<'EOF'
# RaymanAgent Requirements

- (none detected)
EOF

  cat > "${root}/.github/copilot-instructions.md" <<'EOF'
# Copilot
EOF

  (
    cd "${root}"
    git init -b main >/dev/null 2>&1
    git config core.autocrlf false
    git config user.email "rayman@example.com"
    git config user.name "Rayman Tests"
    git add . >/dev/null 2>&1
    git commit -m "baseline" >/dev/null 2>&1
  )

  echo "${root}"
}

add_agentic_docs() {
  local root="$1"
  mkdir -p "${root}/.RaymanAgent/agentic"

  cat > "${root}/.RaymanAgent/agentic/plan.current.md" <<'EOF'
# plan
EOF
  cat > "${root}/.RaymanAgent/agentic/plan.current.json" <<'EOF'
{"schema":"rayman.agentic.plan.v1"}
EOF
  cat > "${root}/.RaymanAgent/agentic/tool-policy.md" <<'EOF'
# tool policy
EOF
  cat > "${root}/.RaymanAgent/agentic/tool-policy.json" <<'EOF'
{"schema":"rayman.agentic.tool_policy.v1"}
EOF
  cat > "${root}/.RaymanAgent/agentic/reflection.current.md" <<'EOF'
# reflection
EOF
  cat > "${root}/.RaymanAgent/agentic/reflection.current.json" <<'EOF'
{"schema":"rayman.agentic.reflection.v1"}
EOF
  cat > "${root}/.RaymanAgent/agentic/evals.md" <<'EOF'
# evals
EOF

  cat > "${root}/.RaymanAgent/.RaymanAgent.requirements.md" <<'EOF'
# RaymanAgent Requirements

- (none detected)
- .RaymanAgent/agentic/plan.current.md
- .RaymanAgent/agentic/plan.current.json
- .RaymanAgent/agentic/tool-policy.md
- .RaymanAgent/agentic/tool-policy.json
- .RaymanAgent/agentic/reflection.current.md
- .RaymanAgent/agentic/reflection.current.json
- .RaymanAgent/agentic/evals.md
EOF
}

teardown() {
  if [[ -n "${BATS_TEST_TMPDIR:-}" && -d "${BATS_TEST_TMPDIR}" ]]; then
    rm -rf "${BATS_TEST_TMPDIR}"
  fi
}

@test "validate_requirements allows legacy pipeline without agentic docs" {
  local root
  root="$(make_workspace)"

  run env \
    ROOT="${root}" \
    RAYMAN_VALIDATE_REQUIREMENTS_SKIP_RELEASE=1 \
    RAYMAN_AGENT_PIPELINE=legacy \
    RAYMAN_BASE_REF=main \
    bash -lc 'cd "$ROOT" && bash ./.Rayman/scripts/ci/validate_requirements.sh'

  [ "${status}" -eq 0 ]
  grep -q "diff 为空" <<< "${output}"
}

@test "validate_requirements blocks governance changes without requirements and agentic doc sync" {
  local root
  root="$(make_workspace)"
  add_agentic_docs "${root}"

  (
    cd "${root}"
    git add . >/dev/null 2>&1
    git commit -m "agentic baseline" >/dev/null 2>&1
    git checkout -b feature >/dev/null 2>&1
    printf '%s\n' '# changed' > .github/copilot-instructions.md
    git add .github/copilot-instructions.md >/dev/null 2>&1
    git commit -m "governance change" >/dev/null 2>&1
  )

  run env \
    ROOT="${root}" \
    RAYMAN_VALIDATE_REQUIREMENTS_SKIP_RELEASE=1 \
    RAYMAN_BASE_REF=main \
    bash -lc 'cd "$ROOT" && bash ./.Rayman/scripts/ci/validate_requirements.sh'

  [ "${status}" -eq 1 ]
  grep -q "涉及 source workspace 治理变更但未同时触达 Solution requirements 与 agentic docs" <<< "${output}"
}
