#!/bin/bash
# End-to-end tests for deploy.sh itself, with aws/docker/curl replaced
# by the scripts in deploy/tests/mocks/ - no real AWS account or Docker
# daemon involved. Complements test_manifest.sh (pure manifest parsing)
# and test_env_config.sh (pure per-service validation) by exercising
# deploy.sh's actual control flow: ECR image-existence verification,
# fail-fast ordering, the per-service config validation gate, the
# deploy.env regeneration, the rollback config-snapshot/restore cycle,
# and the success path.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "${TESTS_DIR}")"
MOCKS_DIR="${TESTS_DIR}/mocks"
DEPLOY_SH="${DEPLOY_DIR}/deploy.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed, deploy.sh integration tests need it (deploy.sh itself requires jq in production)"
  exit 0
fi

PASS=0
FAIL=0

# seed_complete_service_config <config-dir>
# Seeds all 9 services' production .env files, complete and mode 0600 -
# the happy-path starting point most tests build on. Distinct fake
# values per service/key so a test can tell them apart afterwards.
seed_complete_service_config() {
  local dir="$1"
  mkdir -p "${dir}"

  : >"${dir}/gateway.env"
  cat >"${dir}/auth.env" <<'EOF'
POSTGRES_AUTH_PASSWORD=fake-auth-pw
JWT_PRIVATE_KEY=fake-jwt-key
TOTP_ENCRYPTION_KEY=fake-totp-key
EOF
  echo -e "POSTGRES_APIARY_PASSWORD=fake-apiary-pw\nINTERNAL_SERVICE_TOKEN=fake-internal-token" >"${dir}/apiary.env"
  echo -e "POSTGRES_HIVE_PASSWORD=fake-hive-pw\nINTERNAL_SERVICE_TOKEN=fake-internal-token" >"${dir}/hive.env"
  echo -e "POSTGRES_INSPECTION_PASSWORD=fake-inspection-pw\nINTERNAL_SERVICE_TOKEN=fake-internal-token" >"${dir}/inspection.env"
  echo -e "POSTGRES_HARVEST_PASSWORD=fake-harvest-pw\nINTERNAL_SERVICE_TOKEN=fake-internal-token" >"${dir}/harvest.env"
  cat >"${dir}/media.env" <<'EOF'
POSTGRES_MEDIA_PASSWORD=fake-media-pw
STORAGE_BUCKET=fake-bucket
EOF
  : >"${dir}/statistics.env"
  cat >"${dir}/subscription.env" <<'EOF'
POSTGRES_SUBSCRIPTION_PASSWORD=fake-subscription-pw
AUTH_JWKS_URL=http://auth-service:8080/.well-known/jwks.json
REDIS_ADDR=redis:6379
APPLE_BUNDLE_ID=com.beebase.production
APPLE_KEY_ID=fake-apple-key-id
APPLE_ISSUER_ID=fake-apple-issuer-id
APPLE_PRIVATE_KEY=fake-apple-private-key
APPLE_ENVIRONMENT=Production
GOOGLE_PACKAGE_NAME=com.beebase.production
GOOGLE_SERVICE_ACCOUNT_JSON={"type":"service_account"}
EOF

  cat >"${dir}/notification.env" <<'EOF'
POSTGRES_NOTIFICATION_PASSWORD=fake-notification-pw
INTERNAL_SERVICE_TOKEN=fake-internal-token
FIREBASE_PROJECT_ID=beebase-production
FIREBASE_SERVICE_ACCOUNT_JSON_BASE64=eyJ0eXBlIjoic2VydmljZV9hY2NvdW50In0=
AUTH_JWKS_URL=http://auth-service:8080/.well-known/jwks.json
REDIS_ADDR=redis:6379
APPLE_BUNDLE_ID=com.beebase.production
APPLE_KEY_ID=fake-apple-key-id
APPLE_ISSUER_ID=fake-apple-issuer-id
APPLE_PRIVATE_KEY=fake-apple-private-key
APPLE_ENVIRONMENT=Production
EOF

  chmod 600 "${dir}"/*.env
}

ALL_FAKE_SECRETS="fake-auth-pw|fake-apiary-pw|fake-hive-pw|fake-inspection-pw|fake-harvest-pw|fake-media-pw|fake-subscription-pw|fake-notification-pw|fake-totp-key|fake-jwt-key|fake-apple-key-id|fake-apple-issuer-id|fake-apple-private-key"

# run_deploy <manifest-file> - invokes deploy.sh with a fresh, isolated
# /opt/beebase-style layout under a temp dir and mocked aws/docker/curl
# on PATH. Sets OUT, RC, DOCKER_LOG and DEPLOY_ROOT for the caller to
# inspect.
#
# By default, seeds config/ with a complete set of all 9 services'
# production .env files first, since deploy.sh now requires every one of
# them to already exist - set PRESEED_MODE=none to simulate a host where
# none has been provisioned yet, or PRESEED_MODE=reuse to keep whatever
# is already sitting in ${REUSE_ROOT}/config (used by the rollback
# tests, which need config to persist and mutate across two deploys of
# the same root).
run_deploy() {
  local manifest_file="$1"
  local root

  if [ "${PRESEED_MODE:-default}" = "reuse" ]; then
    root="${REUSE_ROOT}"
  else
    root="$(mktemp -d)"
    mkdir -p "${root}/config" "${root}/releases"
    case "${PRESEED_MODE:-default}" in
      none) : ;;
      default) seed_complete_service_config "${root}/config" ;;
    esac
  fi

  DOCKER_LOG="${root}/docker.log"
  : >"${DOCKER_LOG}"

  OUT=$(
    PATH="${MOCKS_DIR}:${PATH}" \
    BEEBASE_COMPOSE_DIR="${DEPLOY_DIR}/.." \
    BEEBASE_CONFIG_DIR="${root}/config" \
    BEEBASE_RELEASES_DIR="${root}/releases" \
    MOCK_DOCKER_LOG="${DOCKER_LOG}" \
    MOCK_MISSING_IMAGES="${MOCK_MISSING_IMAGES:-}" \
    MOCK_SSM_INCLUDE_SECRETS="${MOCK_SSM_INCLUDE_SECRETS:-0}" \
    MOCK_EDGE_STATE="${MOCK_EDGE_STATE:-}" \
    bash "${DEPLOY_SH}" "${manifest_file}" 2>&1
  )
  RC=$?
  DEPLOY_ROOT="${root}"
}

valid_manifest_file() {
  local file="$1"
  cat >"${file}" <<'EOF'
RELEASE=2026.09.07-1
GATEWAY_IMAGE_TAG=5a066d9aa5a066d9aa5a066d9aa5a066d9aa5a06
AUTH_IMAGE_TAG=0b4d246bb0b4d246bb0b4d246bb0b4d246bb0b4d
APIARY_IMAGE_TAG=436efffcc436efffcc436efffcc436efffcc436
HIVE_IMAGE_TAG=f9e257addf9e257addf9e257addf9e257addf9e
INSPECTION_IMAGE_TAG=8844c5bee8844c5bee8844c5bee8844c5bee8844
HARVEST_IMAGE_TAG=c2b91af00c2b91af00c2b91af00c2b91af00c2b9
MEDIA_IMAGE_TAG=a5b903bffa5b903bffa5b903bffa5b903bffa5b9
STATISTICS_IMAGE_TAG=a0877a011a0877a011a0877a011a0877a011a08
NOTIFICATION_IMAGE_TAG=c85447100c85447100c85447100c85447100c854
SUBSCRIPTION_IMAGE_TAG=b85447100b85447100b85447100b85447100b854
EOF
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# --- 1. no argument at all ---

run_deploy ""
if [ "${RC}" -ne 0 ] && echo "${OUT}" | grep -qi "usage:"; then
  echo "PASS: no manifest argument fails with a usage message"
  PASS=$((PASS + 1))
else
  echo "FAIL: no manifest argument fails with a usage message (rc=${RC})"
  echo "${OUT}"
  FAIL=$((FAIL + 1))
fi

# --- 2. manifest file does not exist ---

run_deploy "${TMP_DIR}/does-not-exist.env"
if [ "${RC}" -ne 0 ]; then
  echo "PASS: nonexistent manifest file fails the deploy"
  PASS=$((PASS + 1))
else
  echo "FAIL: nonexistent manifest file fails the deploy"
  FAIL=$((FAIL + 1))
fi

# --- 3. malformed manifest ---

BAD_FILE="${TMP_DIR}/malformed.env"
printf 'not a key value line\n' >"${BAD_FILE}"
run_deploy "${BAD_FILE}"
if [ "${RC}" -ne 0 ]; then
  echo "PASS: malformed manifest fails the deploy"
  PASS=$((PASS + 1))
else
  echo "FAIL: malformed manifest fails the deploy"
  FAIL=$((FAIL + 1))
fi

# --- 4. missing a required service tag ---

MISSING_FILE="${TMP_DIR}/missing-key.env"
valid_manifest_file "${MISSING_FILE}"
grep -v '^AUTH_IMAGE_TAG=' "${MISSING_FILE}" >"${MISSING_FILE}.tmp" && mv "${MISSING_FILE}.tmp" "${MISSING_FILE}"
run_deploy "${MISSING_FILE}"
if [ "${RC}" -ne 0 ] && echo "${OUT}" | grep -q "AUTH_IMAGE_TAG"; then
  echo "PASS: manifest missing AUTH_IMAGE_TAG fails the deploy with a clear message"
  PASS=$((PASS + 1))
else
  echo "FAIL: manifest missing AUTH_IMAGE_TAG fails the deploy with a clear message (rc=${RC})"
  echo "${OUT}"
  FAIL=$((FAIL + 1))
fi

# --- 5. invalid SHA ---

INVALID_SHA_FILE="${TMP_DIR}/invalid-sha.env"
valid_manifest_file "${INVALID_SHA_FILE}"
sed -i.bak 's/^AUTH_IMAGE_TAG=.*/AUTH_IMAGE_TAG=not-hex!/' "${INVALID_SHA_FILE}"
run_deploy "${INVALID_SHA_FILE}"
if [ "${RC}" -ne 0 ]; then
  echo "PASS: invalid (non-hex) image tag fails the deploy"
  PASS=$((PASS + 1))
else
  echo "FAIL: invalid (non-hex) image tag fails the deploy"
  FAIL=$((FAIL + 1))
fi

# --- 6. "latest" is rejected ---

LATEST_FILE="${TMP_DIR}/latest.env"
valid_manifest_file "${LATEST_FILE}"
sed -i.bak 's/^AUTH_IMAGE_TAG=.*/AUTH_IMAGE_TAG=latest/' "${LATEST_FILE}"
run_deploy "${LATEST_FILE}"
if [ "${RC}" -ne 0 ] && echo "${OUT}" | grep -qi "latest"; then
  echo "PASS: 'latest' image tag is rejected with a clear message"
  PASS=$((PASS + 1))
else
  echo "FAIL: 'latest' image tag is rejected with a clear message (rc=${RC})"
  echo "${OUT}"
  FAIL=$((FAIL + 1))
fi

# --- 7. an image missing from ECR fails the deploy and never touches
#     the running stack (no `compose ... pull` / `compose ... up` call
#     is ever made) ---

VALID_FILE="${TMP_DIR}/valid.env"
valid_manifest_file "${VALID_FILE}"

MOCK_MISSING_IMAGES="beebase-auth-service:0b4d246bb0b4d246bb0b4d246bb0b4d246bb0b4d" run_deploy "${VALID_FILE}"
if [ "${RC}" -ne 0 ] && echo "${OUT}" | grep -q "not found in ECR"; then
  if grep -qE '^compose .*(pull| up )' "${DOCKER_LOG}" 2>/dev/null; then
    echo "FAIL: missing ECR image still resulted in a pull/up call - stack was touched"
    FAIL=$((FAIL + 1))
  else
    echo "PASS: missing ECR image fails the deploy before touching the running stack"
    PASS=$((PASS + 1))
  fi
else
  echo "FAIL: missing ECR image fails the deploy (rc=${RC})"
  echo "${OUT}"
  FAIL=$((FAIL + 1))
fi

# --- 8. full successful deploy (all mocks happy) ---

run_deploy "${VALID_FILE}"
if [ "${RC}" -eq 0 ] && echo "${OUT}" | grep -q "deploy of release 2026.09.07-1 complete"; then
  echo "PASS: successful deploy completes with all image tags parsed correctly"
  PASS=$((PASS + 1))
else
  echo "FAIL: successful deploy completes with all image tags parsed correctly (rc=${RC})"
  echo "${OUT}"
  FAIL=$((FAIL + 1))
fi

if [ -L "${DEPLOY_ROOT}/releases/current" ] && [ "$(readlink "${DEPLOY_ROOT}/releases/current")" = "${VALID_FILE}" ]; then
  echo "PASS: releases/current points at the deployed manifest after success"
  PASS=$((PASS + 1))
else
  echo "FAIL: releases/current points at the deployed manifest after success"
  FAIL=$((FAIL + 1))
fi

mode_of() {
  stat -f '%OLp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

if [ -f "${DEPLOY_ROOT}/config/deploy.env" ] && [ "$(mode_of "${DEPLOY_ROOT}/config/deploy.env")" = "600" ]; then
  echo "PASS: generated deploy.env is written with mode 0600"
  PASS=$((PASS + 1))
else
  echo "FAIL: generated deploy.env is written with mode 0600"
  FAIL=$((FAIL + 1))
fi

# --- 9. edge has no Docker HEALTHCHECK (Health=none) and must still
#     pass deployment once its container state is "running", logging
#     that explicitly instead of waiting for "healthy" ---

run_deploy "${VALID_FILE}"
if [ "${RC}" -eq 0 ] && echo "${OUT}" | grep -q "edge is running"; then
  echo "PASS: edge with Health=none is accepted once running, and logged as such"
  PASS=$((PASS + 1))
else
  echo "FAIL: edge with Health=none is accepted once running, and logged as such (rc=${RC})"
  echo "${OUT}"
  FAIL=$((FAIL + 1))
fi

# --- 10. edge exited is an outright deployment failure, not a retry ---

MOCK_EDGE_STATE="exited" run_deploy "${VALID_FILE}"
if [ "${RC}" -ne 0 ] && echo "${OUT}" | grep -qi "edge container is exited"; then
  echo "PASS: edge container exited fails the deploy with a clear message"
  PASS=$((PASS + 1))
else
  echo "FAIL: edge container exited fails the deploy with a clear message (rc=${RC})"
  echo "${OUT}"
  FAIL=$((FAIL + 1))
fi

# --- 11. edge dead is an outright deployment failure ---

MOCK_EDGE_STATE="dead" run_deploy "${VALID_FILE}"
if [ "${RC}" -ne 0 ] && echo "${OUT}" | grep -qi "edge container is dead"; then
  echo "PASS: edge container dead fails the deploy with a clear message"
  PASS=$((PASS + 1))
else
  echo "FAIL: edge container dead fails the deploy with a clear message (rc=${RC})"
  echo "${OUT}"
  FAIL=$((FAIL + 1))
fi

# --- 12. edge container not found at all is an outright deployment
#     failure ---

MOCK_EDGE_STATE="not-found" run_deploy "${VALID_FILE}"
if [ "${RC}" -ne 0 ] && echo "${OUT}" | grep -qi "edge container is not-found"; then
  echo "PASS: edge container not found fails the deploy with a clear message"
  PASS=$((PASS + 1))
else
  echo "FAIL: edge container not found fails the deploy with a clear message (rc=${RC})"
  echo "${OUT}"
  FAIL=$((FAIL + 1))
fi

# --- 13. no service .env files at all fails the deploy clearly, never
#     touches the stack, and never tries to paper over it by generating
#     any of them from SSM ---

PRESEED_MODE=none run_deploy "${VALID_FILE}"
if [ "${RC}" -ne 0 ] && echo "${OUT}" | grep -qi "does not exist"; then
  echo "PASS: missing service .env files fail the deploy with a clear message"
  PASS=$((PASS + 1))
else
  echo "FAIL: missing service .env files fail the deploy with a clear message (rc=${RC})"
  echo "${OUT}"
  FAIL=$((FAIL + 1))
fi
if grep -qE '^compose .*(pull| up )' "${DOCKER_LOG}" 2>/dev/null; then
  echo "FAIL: missing service .env files still resulted in a pull/up call - stack was touched"
  FAIL=$((FAIL + 1))
else
  echo "PASS: missing service .env files never touch the running stack"
  PASS=$((PASS + 1))
fi

# --- 14. one service's .env missing one required key fails the deploy,
#     names the missing key AND the file, and never echoes any secret
#     value (from the keys that ARE present, in any service) while
#     doing so ---

MISSING_SECRET_ROOT="$(mktemp -d)"
mkdir -p "${MISSING_SECRET_ROOT}/config" "${MISSING_SECRET_ROOT}/releases"
seed_complete_service_config "${MISSING_SECRET_ROOT}/config"
grep -v '^JWT_PRIVATE_KEY=' "${MISSING_SECRET_ROOT}/config/auth.env" >"${MISSING_SECRET_ROOT}/config/auth.env.tmp"
mv "${MISSING_SECRET_ROOT}/config/auth.env.tmp" "${MISSING_SECRET_ROOT}/config/auth.env"
chmod 600 "${MISSING_SECRET_ROOT}/config/auth.env"

REUSE_ROOT="${MISSING_SECRET_ROOT}" PRESEED_MODE=reuse run_deploy "${VALID_FILE}"
if [ "${RC}" -ne 0 ] && echo "${OUT}" | grep -q "auth.env" && echo "${OUT}" | grep -q "JWT_PRIVATE_KEY"; then
  echo "PASS: auth.env missing JWT_PRIVATE_KEY fails the deploy and names both the file and the key"
  PASS=$((PASS + 1))
else
  echo "FAIL: auth.env missing JWT_PRIVATE_KEY fails the deploy and names both the file and the key (rc=${RC})"
  echo "${OUT}"
  FAIL=$((FAIL + 1))
fi
if echo "${OUT}" | grep -qE "${ALL_FAKE_SECRETS}"; then
  echo "FAIL: deploy output leaked a present secret's value while reporting a missing one"
  FAIL=$((FAIL + 1))
else
  echo "PASS: deploy output never leaks a secret value while reporting a missing one"
  PASS=$((PASS + 1))
fi
rm -rf "${MISSING_SECRET_ROOT}"

# --- 15. wrong permissions on one service's .env fail the deploy
#     before touching the stack, even though every key is present ---

BAD_MODE_ROOT="$(mktemp -d)"
mkdir -p "${BAD_MODE_ROOT}/config" "${BAD_MODE_ROOT}/releases"
seed_complete_service_config "${BAD_MODE_ROOT}/config"
chmod 644 "${BAD_MODE_ROOT}/config/media.env"

REUSE_ROOT="${BAD_MODE_ROOT}" PRESEED_MODE=reuse run_deploy "${VALID_FILE}"
if [ "${RC}" -ne 0 ] && echo "${OUT}" | grep -q "media.env" && echo "${OUT}" | grep -q "0600"; then
  echo "PASS: media.env with mode 644 fails the deploy, naming the file and the required mode"
  PASS=$((PASS + 1))
else
  echo "FAIL: media.env with mode 644 fails the deploy, naming the file and the required mode (rc=${RC})"
  echo "${OUT}"
  FAIL=$((FAIL + 1))
fi
rm -rf "${BAD_MODE_ROOT}"

# --- 16. a successful deploy leaves every one of the 9 service .env
#     files byte-for-byte untouched - deploy.sh only ever validates and
#     reads them, never rewrites them ---

run_deploy "${VALID_FILE}"
if [ "${RC}" -eq 0 ] &&
  grep -qxF "POSTGRES_AUTH_PASSWORD=fake-auth-pw" "${DEPLOY_ROOT}/config/auth.env" &&
  grep -qxF "JWT_PRIVATE_KEY=fake-jwt-key" "${DEPLOY_ROOT}/config/auth.env" &&
  grep -qxF "TOTP_ENCRYPTION_KEY=fake-totp-key" "${DEPLOY_ROOT}/config/auth.env" &&
  grep -qxF "STORAGE_BUCKET=fake-bucket" "${DEPLOY_ROOT}/config/media.env"
then
  echo "PASS: each service's production .env is left unchanged by a successful deploy"
  PASS=$((PASS + 1))
else
  echo "FAIL: each service's production .env is left unchanged by a successful deploy"
  cat "${DEPLOY_ROOT}/config/auth.env" "${DEPLOY_ROOT}/config/media.env"
  FAIL=$((FAIL + 1))
fi

# --- 17. deploy.sh's own output never contains a secret's value, on a
#     fully successful run ---

if echo "${OUT}" | grep -qE "${ALL_FAKE_SECRETS}"; then
  echo "FAIL: deploy.sh output contains a secret value"
  FAIL=$((FAIL + 1))
else
  echo "PASS: deploy.sh output never contains a secret value"
  PASS=$((PASS + 1))
fi

# --- 18. deploy.env (the one file Compose interpolation reads) never
#     contains JWT_PRIVATE_KEY, TOTP_ENCRYPTION_KEY or STORAGE_BUCKET -
#     those are only ever injected straight into their owning
#     container via env_file:, never mirrored into the shared
#     interpolation file. It DOES need a same-deploy copy of each
#     POSTGRES_*_PASSWORD (see docker-compose.prod.yml's header comment
#     for why), so this is checked by key name, not by absence of the
#     value alone. ---

if grep -q "^JWT_PRIVATE_KEY=" "${DEPLOY_ROOT}/config/deploy.env" ||
   grep -q "^TOTP_ENCRYPTION_KEY=" "${DEPLOY_ROOT}/config/deploy.env" ||
   grep -q "^STORAGE_BUCKET=" "${DEPLOY_ROOT}/config/deploy.env"
then
  echo "FAIL: deploy.env contains a key that should only ever live in its owning service's own .env"
  FAIL=$((FAIL + 1))
else
  echo "PASS: deploy.env never contains JWT_PRIVATE_KEY, TOTP_ENCRYPTION_KEY or STORAGE_BUCKET"
  PASS=$((PASS + 1))
fi
if grep -qxF "POSTGRES_AUTH_PASSWORD=fake-auth-pw" "${DEPLOY_ROOT}/config/deploy.env"; then
  echo "PASS: deploy.env mirrors auth's POSTGRES_AUTH_PASSWORD for Compose's own interpolation"
  PASS=$((PASS + 1))
else
  echo "FAIL: deploy.env mirrors auth's POSTGRES_AUTH_PASSWORD for Compose's own interpolation"
  FAIL=$((FAIL + 1))
fi

# --- 19. a stale/rogue secret (and a stale STORAGE_BUCKET, left over
#     from before the per-service .env migration) still sitting in SSM
#     under /beebase/prod is ignored outright: only PUBLIC_DOMAIN is
#     ever accepted from SSM, and no rogue value is ever written
#     anywhere or logged ---

MOCK_SSM_INCLUDE_SECRETS=1 run_deploy "${VALID_FILE}"
if [ "${RC}" -eq 0 ] && grep -qxF "JWT_PRIVATE_KEY=fake-jwt-key" "${DEPLOY_ROOT}/config/auth.env"; then
  echo "PASS: auth.env's JWT_PRIVATE_KEY wins over a same-named SSM parameter (auth.env is simply never touched)"
  PASS=$((PASS + 1))
else
  echo "FAIL: auth.env's JWT_PRIVATE_KEY wins over a same-named SSM parameter (rc=${RC})"
  FAIL=$((FAIL + 1))
fi
if grep -rqF "rogue-ssm" "${DEPLOY_ROOT}/config/" 2>/dev/null || echo "${OUT}" | grep -qF "rogue-ssm"; then
  echo "FAIL: a stale SSM secret value leaked into deployed config or the deploy log"
  FAIL=$((FAIL + 1))
else
  echo "PASS: a stale SSM secret value never reaches deployed config or the deploy log"
  PASS=$((PASS + 1))
fi
if grep -qF "rogue-ssm-bucket" "${DEPLOY_ROOT}/config/deploy.env" 2>/dev/null; then
  echo "FAIL: a stale SSM STORAGE_BUCKET leaked into deploy.env"
  FAIL=$((FAIL + 1))
else
  echo "PASS: a stale SSM STORAGE_BUCKET never reaches deploy.env (STORAGE_BUCKET is media-owned now, not SSM-sourced)"
  PASS=$((PASS + 1))
fi
if echo "${OUT}" | grep -q "ignoring SSM parameter JWT_PRIVATE_KEY" && echo "${OUT}" | grep -q "ignoring SSM parameter STORAGE_BUCKET"; then
  echo "PASS: deploy.sh logs (by name only) that it ignored every non-PUBLIC_DOMAIN SSM parameter"
  PASS=$((PASS + 1))
else
  echo "FAIL: deploy.sh logs (by name only) that it ignored every non-PUBLIC_DOMAIN SSM parameter"
  echo "${OUT}"
  FAIL=$((FAIL + 1))
fi

# --- 20. rollback: redeploying the SAME release manifest a second time
#     restores that release's own snapshotted configuration, discarding
#     any operator edit made to the live files in between - this is
#     what keeps an image tag and its configuration from ever coming
#     apart across a rollback (see deploy.sh's restore step). ---

ROLLBACK_ROOT="$(mktemp -d)"
mkdir -p "${ROLLBACK_ROOT}/config" "${ROLLBACK_ROOT}/releases"
seed_complete_service_config "${ROLLBACK_ROOT}/config"

REUSE_ROOT="${ROLLBACK_ROOT}" PRESEED_MODE=reuse run_deploy "${VALID_FILE}"
FIRST_RC="${RC}"

SNAPSHOT_DIR="${ROLLBACK_ROOT}/releases/2026.09.07-1/config-snapshot"
if [ "${FIRST_RC}" -eq 0 ] && [ -f "${SNAPSHOT_DIR}/auth.env" ] && grep -qxF "JWT_PRIVATE_KEY=fake-jwt-key" "${SNAPSHOT_DIR}/auth.env"; then
  echo "PASS: a successful deploy snapshots this release's own configuration"
  PASS=$((PASS + 1))
else
  echo "FAIL: a successful deploy snapshots this release's own configuration (rc=${FIRST_RC})"
  FAIL=$((FAIL + 1))
fi

# Simulate an operator changing the live auth.env in between deploys -
# e.g. rotating a key ahead of the NEXT release, before this release is
# ever rolled back to.
sed -i.bak 's/^JWT_PRIVATE_KEY=.*/JWT_PRIVATE_KEY=tampered-after-first-deploy/' "${ROLLBACK_ROOT}/config/auth.env"

REUSE_ROOT="${ROLLBACK_ROOT}" PRESEED_MODE=reuse run_deploy "${VALID_FILE}"
SECOND_RC="${RC}"

if [ "${SECOND_RC}" -eq 0 ] && echo "${OUT}" | grep -q "restoring its exact per-service configuration"; then
  echo "PASS: redeploying the same release logs that it is restoring that release's own configuration"
  PASS=$((PASS + 1))
else
  echo "FAIL: redeploying the same release logs that it is restoring that release's own configuration (rc=${SECOND_RC})"
  echo "${OUT}"
  FAIL=$((FAIL + 1))
fi
if grep -qxF "JWT_PRIVATE_KEY=fake-jwt-key" "${ROLLBACK_ROOT}/config/auth.env"; then
  echo "PASS: rollback/redeploy restores the release's original JWT_PRIVATE_KEY, discarding the operator's later edit"
  PASS=$((PASS + 1))
else
  echo "FAIL: rollback/redeploy restores the release's original JWT_PRIVATE_KEY, discarding the operator's later edit"
  cat "${ROLLBACK_ROOT}/config/auth.env"
  FAIL=$((FAIL + 1))
fi
if echo "${OUT}" | grep -qF "tampered-after-first-deploy"; then
  echo "FAIL: the tampered/rotated secret value was echoed into deploy.sh's own output"
  FAIL=$((FAIL + 1))
else
  echo "PASS: the tampered/rotated secret value is never echoed into deploy.sh's own output"
  PASS=$((PASS + 1))
fi
rm -rf "${ROLLBACK_ROOT}"

# --- 21. a release id whose config snapshot exists but is missing one
#     service's file fails the deploy outright rather than silently
#     deploying a partial/inconsistent configuration - this is the
#     "image and config can never become mismatched" guarantee's other
#     half: a corrupt snapshot must never be treated as good enough. ---

PARTIAL_SNAPSHOT_ROOT="$(mktemp -d)"
mkdir -p "${PARTIAL_SNAPSHOT_ROOT}/config" "${PARTIAL_SNAPSHOT_ROOT}/releases"
seed_complete_service_config "${PARTIAL_SNAPSHOT_ROOT}/config"

REUSE_ROOT="${PARTIAL_SNAPSHOT_ROOT}" PRESEED_MODE=reuse run_deploy "${VALID_FILE}"
[ "${RC}" -eq 0 ] || echo "(setup deploy for test 21 failed unexpectedly: ${OUT})"

rm -f "${PARTIAL_SNAPSHOT_ROOT}/releases/2026.09.07-1/config-snapshot/hive.env"

REUSE_ROOT="${PARTIAL_SNAPSHOT_ROOT}" PRESEED_MODE=reuse run_deploy "${VALID_FILE}"
if [ "${RC}" -ne 0 ] && echo "${OUT}" | grep -qi "partial rollback snapshot"; then
  echo "PASS: a corrupted/partial config snapshot fails the deploy rather than proceeding with mismatched config"
  PASS=$((PASS + 1))
else
  echo "FAIL: a corrupted/partial config snapshot fails the deploy rather than proceeding with mismatched config (rc=${RC})"
  echo "${OUT}"
  FAIL=$((FAIL + 1))
fi
rm -rf "${PARTIAL_SNAPSHOT_ROOT}"

# --- 22. deploy.env is deliberately NOT snapshotted (it's a derived,
#     deploy-owned, non-secret cache regenerated every deploy - see
#     docker-compose.prod.yml's header comment) - only the 9 service
#     .env files are ---

run_deploy "${VALID_FILE}"
SNAPSHOT_DIR="${DEPLOY_ROOT}/releases/2026.09.07-1/config-snapshot"
if [ -d "${SNAPSHOT_DIR}" ] && [ ! -e "${SNAPSHOT_DIR}/deploy.env" ]; then
  echo "PASS: the config snapshot holds only the 9 service .env files, never deploy.env"
  PASS=$((PASS + 1))
else
  echo "FAIL: the config snapshot holds only the 9 service .env files, never deploy.env"
  ls -la "${SNAPSHOT_DIR}" 2>/dev/null
  FAIL=$((FAIL + 1))
fi

# --- 23. the old, single, shared /opt/beebase/config/.env is never
#     read, written to, or required by deploy.sh - even when it exists
#     and looks complete, it must never become the active source of
#     configuration. Its mere presence must not let a deploy skip
#     provisioning the 9 new per-service files. ---

LEGACY_ONLY_ROOT="$(mktemp -d)"
mkdir -p "${LEGACY_ONLY_ROOT}/config" "${LEGACY_ONLY_ROOT}/releases"
cat >"${LEGACY_ONLY_ROOT}/config/.env" <<'EOF'
POSTGRES_AUTH_PASSWORD=legacy-auth-pw
POSTGRES_APIARY_PASSWORD=legacy-apiary-pw
POSTGRES_HIVE_PASSWORD=legacy-hive-pw
POSTGRES_INSPECTION_PASSWORD=legacy-inspection-pw
POSTGRES_MEDIA_PASSWORD=legacy-media-pw
TOTP_ENCRYPTION_KEY=legacy-totp-key
JWT_PRIVATE_KEY=legacy-jwt-key
EOF
chmod 600 "${LEGACY_ONLY_ROOT}/config/.env"

REUSE_ROOT="${LEGACY_ONLY_ROOT}" PRESEED_MODE=reuse run_deploy "${VALID_FILE}"
if [ "${RC}" -ne 0 ] && echo "${OUT}" | grep -q "does not exist"; then
  echo "PASS: a legacy single .env alone (no per-service files) still fails the deploy"
  PASS=$((PASS + 1))
else
  echo "FAIL: a legacy single .env alone (no per-service files) still fails the deploy (rc=${RC})"
  echo "${OUT}"
  FAIL=$((FAIL + 1))
fi

seed_complete_service_config "${LEGACY_ONLY_ROOT}/config"
REUSE_ROOT="${LEGACY_ONLY_ROOT}" PRESEED_MODE=reuse run_deploy "${VALID_FILE}"
if [ "${RC}" -eq 0 ] &&
  grep -qxF "JWT_PRIVATE_KEY=legacy-jwt-key" "${LEGACY_ONLY_ROOT}/config/.env" &&
  ! grep -qF "legacy-" "${LEGACY_ONLY_ROOT}/config/deploy.env" 2>/dev/null &&
  ! echo "${OUT}" | grep -qF "legacy-"
then
  echo "PASS: the legacy .env is left untouched and never becomes part of the active deploy once the 9 files exist"
  PASS=$((PASS + 1))
else
  echo "FAIL: the legacy .env is left untouched and never becomes part of the active deploy once the 9 files exist (rc=${RC})"
  cat "${LEGACY_ONLY_ROOT}/config/.env"
  FAIL=$((FAIL + 1))
fi
rm -rf "${LEGACY_ONLY_ROOT}"

echo
echo "deploy.sh integration tests: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
