#!/bin/bash
# `docker compose config` must succeed once every per-service image-tag
# variable is set, and each service must resolve to its OWN tag - the
# thing the old single shared IMAGE_TAG couldn't do. Also checks that
# compose still fails fast (no silent "latest" fallback) when a
# required variable is missing.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_DIR="$(dirname "$(dirname "${TESTS_DIR}")")"
COMPOSE_FILE="${GATEWAY_DIR}/docker-compose.prod.yml"

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not installed, cannot run docker compose config"
  exit 0
fi

PASS=0
FAIL=0

FAKE_ENV=(
  ECR_REGISTRY=123456789012.dkr.ecr.eu-central-1.amazonaws.com
  AWS_REGION=eu-central-1
  RELEASE=2026.09.07-1
  GATEWAY_IMAGE_TAG=5a066d9aa5a066d9aa5a066d9aa5a066d9aa5a06
  AUTH_IMAGE_TAG=0b4d246bb0b4d246bb0b4d246bb0b4d246bb0b4d
  APIARY_IMAGE_TAG=436efffcc436efffcc436efffcc436efffcc436
  HIVE_IMAGE_TAG=f9e257addf9e257addf9e257addf9e257addf9e
  INSPECTION_IMAGE_TAG=8844c5bee8844c5bee8844c5bee8844c5bee8844
  MEDIA_IMAGE_TAG=a5b903bffa5b903bffa5b903bffa5b903bffa5b9
  STATISTICS_IMAGE_TAG=a0877a011a0877a011a0877a011a0877a011a08
  PUBLIC_DOMAIN=api.beebase.club
  POSTGRES_AUTH_PASSWORD=x
  POSTGRES_APIARY_PASSWORD=x
  POSTGRES_HIVE_PASSWORD=x
  POSTGRES_INSPECTION_PASSWORD=x
  POSTGRES_MEDIA_PASSWORD=x
  JWT_PRIVATE_KEY=x
  TOTP_ENCRYPTION_KEY=x
  STORAGE_BUCKET=beebase-prod
)

# --- 1. config succeeds with every variable set ---

RESOLVED=$(env -i "${FAKE_ENV[@]}" PATH="${PATH}" docker compose -f "${COMPOSE_FILE}" config 2>&1)
if [ $? -eq 0 ]; then
  echo "PASS: docker compose config succeeds with all image tag variables set"
  PASS=$((PASS + 1))
else
  echo "FAIL: docker compose config succeeds with all image tag variables set"
  echo "${RESOLVED}"
  FAIL=$((FAIL + 1))
fi

# --- 2. each service resolves to its OWN tag, not a shared one ---

declare -A expect=(
  [beebase-gateway]=5a066d9aa5a066d9aa5a066d9aa5a066d9aa5a06
  [beebase-auth-service]=0b4d246bb0b4d246bb0b4d246bb0b4d246bb0b4d
  [beebase-apiary-service]=436efffcc436efffcc436efffcc436efffcc436
  [beebase-hive-service]=f9e257addf9e257addf9e257addf9e257addf9e
  [beebase-inspection-service]=8844c5bee8844c5bee8844c5bee8844c5bee8844
  [beebase-media-service]=a5b903bffa5b903bffa5b903bffa5b903bffa5b9
  [beebase-statistics-service]=a0877a011a0877a011a0877a011a0877a011a08
)

all_resolved_ok=1
for repo in "${!expect[@]}"; do
  want="123456789012.dkr.ecr.eu-central-1.amazonaws.com/${repo}:${expect[${repo}]}"
  if echo "${RESOLVED}" | grep -qF "image: ${want}"; then
    echo "PASS: ${repo} resolves to its own tag (${expect[${repo}]})"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${repo} did not resolve to its own tag (${expect[${repo}]})"
    all_resolved_ok=0
    FAIL=$((FAIL + 1))
  fi
done

# migrate images use <service-tag>-migrate
declare -A expect_migrate=(
  [beebase-auth-service]=0b4d246bb0b4d246bb0b4d246bb0b4d246bb0b4d
  [beebase-apiary-service]=436efffcc436efffcc436efffcc436efffcc436
  [beebase-hive-service]=f9e257addf9e257addf9e257addf9e257addf9e
  [beebase-inspection-service]=8844c5bee8844c5bee8844c5bee8844c5bee8844
  [beebase-media-service]=a5b903bffa5b903bffa5b903bffa5b903bffa5b9
)
for repo in "${!expect_migrate[@]}"; do
  want="123456789012.dkr.ecr.eu-central-1.amazonaws.com/${repo}:${expect_migrate[${repo}]}-migrate"
  if echo "${RESOLVED}" | grep -qF "image: ${want}"; then
    echo "PASS: ${repo} migrate image uses <tag>-migrate"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${repo} migrate image did not resolve to <tag>-migrate"
    FAIL=$((FAIL + 1))
  fi
done

# --- 3. a missing per-service tag fails config, never falls back silently ---

MISSING_ENV=("${FAKE_ENV[@]/AUTH_IMAGE_TAG=*/}")
if env -i "${MISSING_ENV[@]}" PATH="${PATH}" docker compose -f "${COMPOSE_FILE}" config >/dev/null 2>&1; then
  echo "FAIL: missing AUTH_IMAGE_TAG should fail docker compose config"
  FAIL=$((FAIL + 1))
else
  echo "PASS: missing AUTH_IMAGE_TAG fails docker compose config (no silent fallback)"
  PASS=$((PASS + 1))
fi

echo
echo "compose config tests: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
