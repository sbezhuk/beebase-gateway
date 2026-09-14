#!/bin/bash
# Checks deploy/azure-pipelines-release.yml's replacement,
# .github/workflows/production-release.yml, against its checklist: all
# 7 SHA inputs exist independently, every required ECR image is
# checked, a missing image fails the run, the manifest has all 7
# services and no secrets, SSM deployment uses the generated manifest,
# deploy.sh's own logic isn't reimplemented here, and the workflow is
# manual/protected.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_DIR="$(dirname "$(dirname "${TESTS_DIR}")")"
WORKFLOW="${GATEWAY_DIR}/.github/workflows/production-release.yml"

PASS=0
FAIL=0

check() {
  local desc="$1" ok="$2"
  if [ "${ok}" -eq 1 ]; then
    echo "PASS: ${desc}"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${desc}"
    FAIL=$((FAIL + 1))
  fi
}

if [ ! -f "${WORKFLOW}" ]; then
  echo "FAIL: ${WORKFLOW} does not exist"
  exit 1
fi

# --- all 7 SHA inputs exist, independently (no shared/common SHA) ---

for input in gateway_image_tag auth_image_tag apiary_image_tag hive_image_tag inspection_image_tag media_image_tag statistics_image_tag subscription_image_tag notification_image_tag; do
  grep -q "^      ${input}:" "${WORKFLOW}"
  check "workflow_dispatch input '${input}' exists" $([ $? -eq 0 ] && echo 1 || echo 0)
done

# Each input must map to its OWN env var (GATEWAY_IMAGE_TAG <- inputs.gateway_image_tag,
# not e.g. every var reading from the same inputs.image_tag) - this is
# what "no SHA implicitly shared between repos" means structurally.
all_distinct_ok=1
for pair in \
  "gateway_image_tag:GATEWAY_IMAGE_TAG" \
  "auth_image_tag:AUTH_IMAGE_TAG" \
  "apiary_image_tag:APIARY_IMAGE_TAG" \
  "hive_image_tag:HIVE_IMAGE_TAG" \
  "inspection_image_tag:INSPECTION_IMAGE_TAG" \
  "media_image_tag:MEDIA_IMAGE_TAG" \
  "statistics_image_tag:STATISTICS_IMAGE_TAG" \
  "subscription_image_tag:SUBSCRIPTION_IMAGE_TAG" \
  "notification_image_tag:NOTIFICATION_IMAGE_TAG"; do
  input="${pair%%:*}"
  var="${pair##*:}"
  grep -qF "${var}: \${{ inputs.${input} }}" "${WORKFLOW}" || all_distinct_ok=0
done
check "each of the 8 inputs feeds its own distinct *_IMAGE_TAG variable" "${all_distinct_ok}"

# --- rollback input is optional convenience, distinct from the 7 SHAs ---

grep -q "rollback_release:" "${WORKFLOW}"
check "optional rollback_release input exists" $([ $? -eq 0 ] && echo 1 || echo 0)

# --- every required ECR image is checked: 7 app + 5 migrate ---

grep -c "aws ecr describe-images" "${WORKFLOW}" | grep -qE "^[2-9]$|^[1-9][0-9]$"
check "aws ecr describe-images is called (image existence checks)" $([ $? -eq 0 ] && echo 1 || echo 0)

grep -qF "MANIFEST_SERVICE_TAG_KEYS" "${WORKFLOW}" && grep -qF "MANIFEST_MIGRATE_TAG_KEYS" "${WORKFLOW}"
check "checks both app image keys and migrate image keys (deploy/lib/manifest.sh's own key lists)" $([ $? -eq 0 ] && echo 1 || echo 0)

# --- a missing image causes failure, never a silent fallback ---

grep -qF "not found in ECR" "${WORKFLOW}" && grep -A1 "not found in ECR" "${WORKFLOW}" | grep -qF "exit 1"
check "a missing ECR image fails the run (exit 1), no fallback" $([ $? -eq 0 ] && echo 1 || echo 0)

# --- manifest contains all 7 services ---

grep -qF "MANIFEST_SERVICE_TAG_KEYS[@]" "${WORKFLOW}"
check "manifest is built from all 7 service tag keys" $([ $? -eq 0 ] && echo 1 || echo 0)

# --- manifest contains no secrets ---

if grep -qiE 'PASSWORD|JWT_PRIVATE_KEY|TOTP_ENCRYPTION_KEY|SecureString' "${WORKFLOW}"; then
  check "manifest/workflow never references production secrets" 0
else
  check "manifest/workflow never references production secrets" 1
fi

# --- no 'latest', ever ---

if grep -qiE '(^|[^-])\blatest\b' "${WORKFLOW}"; then
  check "never uses 'latest' as an image tag" 0
else
  check "never uses 'latest' as an image tag" 1
fi

# --- every one of the 7 services' production .env files is validated
#     on the host before any image/manifest work happens, reusing
#     deploy/lib/env_config.sh's own validate_all rather than
#     reimplementing the required-key list in the workflow (which would
#     drift from deploy.sh's own checks) ---

grep -qF "env_config_validate_all" "${WORKFLOW}"
check "validates every service's .env via env_config_validate_all before anything else" $([ $? -eq 0 ] && echo 1 || echo 0)

grep -qF "source /opt/beebase/deploy/lib/env_config.sh" "${WORKFLOW}"
check "sources the deployment bundle's own env_config.sh rather than reimplementing validation" $([ $? -eq 0 ] && echo 1 || echo 0)

# --- SSM deployment uses the generated manifest, deploy.sh is the only
#     deployment logic invoked (not reimplemented here) ---

grep -qF "ssm send-command" "${WORKFLOW}" && grep -qF "/opt/beebase/deploy/deploy.sh" "${WORKFLOW}"
check "sends the manifest and invokes deploy.sh via SSM" $([ $? -eq 0 ] && echo 1 || echo 0)

grep -qF "MANIFEST_FILE" "${WORKFLOW}" && grep -qF "/opt/beebase/releases/" "${WORKFLOW}"
check "deploy.sh is invoked against /opt/beebase/releases/<release>.env" $([ $? -eq 0 ] && echo 1 || echo 0)

if grep -qE 'docker compose|compose pull|compose up|wget.*health|jwks\.json' "${WORKFLOW}"; then
  check "deploy.sh's pull/migrate/health/smoke logic is not reimplemented in the workflow" 0
else
  check "deploy.sh's pull/migrate/health/smoke logic is not reimplemented in the workflow" 1
fi

# --- manual, protected ---

grep -q "^  workflow_dispatch:" "${WORKFLOW}"
check "trigger is workflow_dispatch (manual) only" $([ $? -eq 0 ] && echo 1 || echo 0)

if grep -qE '^\s*(push|pull_request|schedule):' "${WORKFLOW}"; then
  check "no automatic trigger (push/pull_request/schedule)" 0
else
  check "no automatic trigger (push/pull_request/schedule)" 1
fi

[ "$(grep -c '^\s*environment: production' "${WORKFLOW}")" -ge 2 ]
check "both jobs run under the protected 'production' GitHub Environment" $([ $? -eq 0 ] && echo 1 || echo 0)

# --- no Azure DevOps mechanics left behind (a prose mention that this
#     workflow replaced Azure DevOps is fine and expected; actual ADO
#     syntax/config is not) ---

if grep -qE 'resources\.pipeline\.|AWSShellScript@|pipeline resource|AWS-BeeBase-OIDC|beebase-prod-pipeline' "${WORKFLOW}"; then
  check "no Azure DevOps pipeline-resource/task syntax remains" 0
else
  check "no Azure DevOps pipeline-resource/task syntax remains" 1
fi

echo
echo "production-release.yml tests: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
