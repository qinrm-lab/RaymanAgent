#!/usr/bin/env bash
set -euo pipefail
JOB_NAME="rayman-requirements-guard"
CMD="bash ./.Rayman/scripts/ci/validate_requirements.sh"
mkdir -p ".Rayman/ci-snippets"
if [[ -f ".gitlab-ci.yml" ]]; then
  grep -Fq "${JOB_NAME}" ".gitlab-ci.yml" && { echo "✅ already exists"; exit 0; }
  cat >> ".gitlab-ci.yml" <<YAML

${JOB_NAME}:
  stage: test
  image: alpine:3.20
  before_script:
    - apk add --no-cache bash git
    - git fetch --all --prune || true
  script:
    - ${CMD}
YAML
  echo "✅ added to .gitlab-ci.yml"
  exit 0
fi
if [[ -f "Jenkinsfile" ]]; then
  echo "stage('Rayman Requirements Guard') { steps { sh '${CMD}' } }" > ".Rayman/ci-snippets/GENERATED_SNIPPET.txt"
  echo "⚠️  Jenkinsfile: wrote snippet"
  exit 0
fi
if [[ -f "azure-pipelines.yml" ]]; then
  echo -e "
# ${JOB_NAME}
- script: |
    ${CMD}
  displayName: Rayman Requirements Guard
" >> "azure-pipelines.yml"
  echo "✅ added to azure-pipelines.yml"
  exit 0
fi
echo -e "# paste into your CI
${CMD}
" > ".Rayman/ci-snippets/GENERATED_SNIPPET.txt"
echo "⚠️  unsupported CI; wrote snippet"
