#!/bin/bash
# Checks every service repo's .github/workflows/ci.yml against the CI
# checklist: test stage, Docker build, ECR push, ${{ github.sha }}
# tagging, no `latest`, no production deployment, and an arm64 build
# target. Assumes every BeeBase repo is checked out as a sibling
# directory of this one - see beebase-gateway/README.md's "Running the
# full stack" - and skips (not fails) if a sibling isn't present, so
# this still runs fine from a single-repo checkout in CI.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_DIR="$(dirname "$(dirname "${TESTS_DIR}")")"
WORKSPACE_DIR="$(dirname "${GATEWAY_DIR}")"

declare -A HAS_MIGRATIONS=(
  [beebase-gateway]=0
  [beebase-auth-service]=1
  [beebase-apiary-service]=1
  [beebase-hive-service]=1
  [beebase-inspection-service]=1
  [beebase-media-service]=1
  [beebase-statistics-service]=0
)

PASS=0
FAIL=0
SKIPPED=0

for repo in "${!HAS_MIGRATIONS[@]}"; do
  workflow="${WORKSPACE_DIR}/${repo}/.github/workflows/ci.yml"

  if [ ! -f "${workflow}" ]; then
    echo "SKIP: ${repo}/.github/workflows/ci.yml not found (sibling repo not checked out here)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  check() {
    local desc="$1" ok="$2"
    if [ "${ok}" -eq 1 ]; then
      echo "PASS: ${repo}: ${desc}"
      PASS=$((PASS + 1))
    else
      echo "FAIL: ${repo}: ${desc}"
      FAIL=$((FAIL + 1))
    fi
  }

  grep -q "go test" "${workflow}" && grep -q "go vet" "${workflow}"
  check "test stage runs go vet and go test" $([ $? -eq 0 ] && echo 1 || echo 0)

  grep -q "docker/build-push-action" "${workflow}" && grep -q "docker/setup-buildx-action" "${workflow}"
  check "Docker build (buildx) step exists" $([ $? -eq 0 ] && echo 1 || echo 0)

  grep -q "amazon-ecr-login" "${workflow}" && grep -q "push: true" "${workflow}"
  check "ECR push step exists" $([ $? -eq 0 ] && echo 1 || echo 0)

  grep -qF 'github.sha' "${workflow}"
  check "image tag uses \${{ github.sha }}" $([ $? -eq 0 ] && echo 1 || echo 0)

  if grep -qiE '(^|[^-])\blatest\b' "${workflow}"; then
    check "never uses 'latest' as an image tag" 0
  else
    check "never uses 'latest' as an image tag" 1
  fi

  if grep -qE 'ssm |send-command|deploy\.sh|environment: *production' "${workflow}"; then
    check "no production deployment in the service workflow" 0
  else
    check "no production deployment in the service workflow" 1
  fi

  grep -qF 'linux/arm64' "${workflow}"
  check "linux/arm64 is the build target" $([ $? -eq 0 ] && echo 1 || echo 0)

  grep -qF 'role-to-assume' "${workflow}" && ! grep -qE 'aws-access-key-id|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY' "${workflow}"
  check "authenticates via OIDC role assumption, no static AWS keys" $([ $? -eq 0 ] && echo 1 || echo 0)

  if [ "${HAS_MIGRATIONS[${repo}]}" -eq 1 ]; then
    grep -qF 'Dockerfile.migrate' "${workflow}" && grep -qF -- '-migrate' "${workflow}"
    check "pushes a <sha>-migrate image (has migrations)" $([ $? -eq 0 ] && echo 1 || echo 0)
  else
    if grep -qF 'Dockerfile.migrate' "${workflow}"; then
      check "does not push a migrate image (no migrations)" 0
    else
      check "does not push a migrate image (no migrations)" 1
    fi
  fi
done

echo
echo "service workflow tests: ${PASS} passed, ${FAIL} failed, ${SKIPPED} skipped (sibling repo missing)"
[ "${FAIL}" -eq 0 ]
