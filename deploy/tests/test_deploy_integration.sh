#!/bin/bash
# End-to-end tests for deploy.sh itself, with aws/docker/curl replaced
# by the scripts in deploy/tests/mocks/ - no real AWS account or Docker
# daemon involved. Complements test_manifest.sh (pure manifest parsing)
# by exercising deploy.sh's actual control flow: ECR image-existence
# verification, fail-fast ordering, and the success path.
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

# Fake values for the seven secrets deploy.sh must now source exclusively
# from the production .env - never from SSM. Distinct per key so a test
# can tell them apart in the resulting .env.
seed_secrets_env() {
  local file="$1"
  cat >"${file}" <<'EOF'
POSTGRES_AUTH_PASSWORD=fake-auth-pw
POSTGRES_APIARY_PASSWORD=fake-apiary-pw
POSTGRES_HIVE_PASSWORD=fake-hive-pw
POSTGRES_INSPECTION_PASSWORD=fake-inspection-pw
POSTGRES_MEDIA_PASSWORD=fake-media-pw
TOTP_ENCRYPTION_KEY=fake-totp-key
JWT_PRIVATE_KEY=fake-jwt-key
EOF
  chmod 600 "${file}"
}

# run_deploy <manifest-file> - invokes deploy.sh with a fresh, isolated
# /opt/beebase-style layout under a temp dir and mocked aws/docker/curl
# on PATH. Sets OUT, RC and DOCKER_LOG for the caller to inspect.
#
# By default, seeds config/.env with a complete set of the seven
# production secrets first, since deploy.sh now requires that file to
# already exist - set PRESEED_ENV_FILE=none to simulate a host where it
# hasn't been provisioned yet, or PRESEED_ENV_FILE=<path> to seed from a
# specific file instead (e.g. one missing a key).
run_deploy() {
  local manifest_file="$1"
  local root
  root="$(mktemp -d)"
  mkdir -p "${root}/config" "${root}/releases"

  case "${PRESEED_ENV_FILE:-default}" in
    none) : ;;
    default) seed_secrets_env "${root}/config/.env" ;;
    *) cp "${PRESEED_ENV_FILE}" "${root}/config/.env" && chmod 600 "${root}/config/.env" ;;
  esac

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
MEDIA_IMAGE_TAG=a5b903bffa5b903bffa5b903bffa5b903bffa5b9
STATISTICS_IMAGE_TAG=a0877a011a0877a011a0877a011a0877a011a08
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

if [ -f "${DEPLOY_ROOT}/config/.env" ] && [ "$(stat -f '%OLp' "${DEPLOY_ROOT}/config/.env" 2>/dev/null || stat -c '%a' "${DEPLOY_ROOT}/config/.env")" = "600" ]; then
  echo "PASS: generated .env is written with mode 0600"
  PASS=$((PASS + 1))
else
  echo "FAIL: generated .env is written with mode 0600"
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

# --- 13. no production .env at all fails the deploy clearly, and never
#     tries to paper over it by generating one from SSM ---

PRESEED_ENV_FILE=none run_deploy "${VALID_FILE}"
if [ "${RC}" -ne 0 ] && echo "${OUT}" | grep -qi "production .env not found"; then
  echo "PASS: missing production .env fails the deploy with a clear message"
  PASS=$((PASS + 1))
else
  echo "FAIL: missing production .env fails the deploy with a clear message (rc=${RC})"
  echo "${OUT}"
  FAIL=$((FAIL + 1))
fi

# --- 14. production .env missing one required secret fails the deploy,
#     names the missing key, and never echoes any secret value (from the
#     keys that ARE present) while doing so ---

MISSING_SECRET_ENV="${TMP_DIR}/missing-secret.env"
seed_secrets_env "${MISSING_SECRET_ENV}"
grep -v '^JWT_PRIVATE_KEY=' "${MISSING_SECRET_ENV}" >"${MISSING_SECRET_ENV}.tmp" && mv "${MISSING_SECRET_ENV}.tmp" "${MISSING_SECRET_ENV}"

PRESEED_ENV_FILE="${MISSING_SECRET_ENV}" run_deploy "${VALID_FILE}"
if [ "${RC}" -ne 0 ] && echo "${OUT}" | grep -q "JWT_PRIVATE_KEY"; then
  echo "PASS: production .env missing JWT_PRIVATE_KEY fails the deploy and names it"
  PASS=$((PASS + 1))
else
  echo "FAIL: production .env missing JWT_PRIVATE_KEY fails the deploy and names it (rc=${RC})"
  echo "${OUT}"
  FAIL=$((FAIL + 1))
fi
if echo "${OUT}" | grep -qF "fake-auth-pw"; then
  echo "FAIL: deploy output leaked a present secret's value while reporting a missing one"
  FAIL=$((FAIL + 1))
else
  echo "PASS: deploy output never leaks a secret value while reporting a missing one"
  PASS=$((PASS + 1))
fi

# --- 15. a successful deploy carries the seven secrets over from the
#     production .env byte-for-byte - never regenerated, never touched ---

run_deploy "${VALID_FILE}"
if [ "${RC}" -eq 0 ] &&
  grep -qxF "POSTGRES_AUTH_PASSWORD=fake-auth-pw" "${DEPLOY_ROOT}/config/.env" &&
  grep -qxF "JWT_PRIVATE_KEY=fake-jwt-key" "${DEPLOY_ROOT}/config/.env" &&
  grep -qxF "TOTP_ENCRYPTION_KEY=fake-totp-key" "${DEPLOY_ROOT}/config/.env"
then
  echo "PASS: production secrets are carried over into the deployed .env unchanged"
  PASS=$((PASS + 1))
else
  echo "FAIL: production secrets are carried over into the deployed .env unchanged"
  cat "${DEPLOY_ROOT}/config/.env"
  FAIL=$((FAIL + 1))
fi

# --- 16. deploy.sh's own output never contains a secret's value, on a
#     fully successful run ---

if echo "${OUT}" | grep -qE "fake-auth-pw|fake-apiary-pw|fake-hive-pw|fake-inspection-pw|fake-media-pw|fake-totp-key|fake-jwt-key"; then
  echo "FAIL: deploy.sh output contains a secret value"
  FAIL=$((FAIL + 1))
else
  echo "PASS: deploy.sh output never contains a secret value"
  PASS=$((PASS + 1))
fi

# --- 17. a stale/rogue secret still sitting in SSM under /beebase/prod
#     is ignored outright: the production .env's value always wins, and
#     the rogue SSM value is never written anywhere or logged ---

MOCK_SSM_INCLUDE_SECRETS=1 run_deploy "${VALID_FILE}"
if [ "${RC}" -eq 0 ] && grep -qxF "JWT_PRIVATE_KEY=fake-jwt-key" "${DEPLOY_ROOT}/config/.env"; then
  echo "PASS: production .env's JWT_PRIVATE_KEY wins over a same-named SSM parameter"
  PASS=$((PASS + 1))
else
  echo "FAIL: production .env's JWT_PRIVATE_KEY wins over a same-named SSM parameter (rc=${RC})"
  cat "${DEPLOY_ROOT}/config/.env" 2>/dev/null
  FAIL=$((FAIL + 1))
fi
if grep -qF "rogue-ssm" "${DEPLOY_ROOT}/config/.env" 2>/dev/null || echo "${OUT}" | grep -qF "rogue-ssm"; then
  echo "FAIL: a stale SSM secret value leaked into the deployed .env or the deploy log"
  FAIL=$((FAIL + 1))
else
  echo "PASS: a stale SSM secret value never reaches the deployed .env or the deploy log"
  PASS=$((PASS + 1))
fi
if echo "${OUT}" | grep -q "ignoring SSM parameter JWT_PRIVATE_KEY"; then
  echo "PASS: deploy.sh logs (by name only) that it ignored the stale SSM secret"
  PASS=$((PASS + 1))
else
  echo "FAIL: deploy.sh logs (by name only) that it ignored the stale SSM secret"
  echo "${OUT}"
  FAIL=$((FAIL + 1))
fi

echo
echo "deploy.sh integration tests: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
