#!/bin/bash
# `docker compose config` must succeed once every per-service image-tag
# variable is set and every one of the 9 services' env files exists
# under BEEBASE_CONFIG_DIR - each service must resolve to its OWN image
# tag (the thing the old single shared IMAGE_TAG couldn't do) and load
# its OWN env file, and only its own. Also checks that compose still
# fails fast (no silent "latest" fallback, no silent "skip the missing
# secret") when a required variable or a service's env file is missing.
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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

CONFIG_DIR="${TMP_DIR}/config"
mkdir -p "${CONFIG_DIR}"

# Each file also carries a MARKER key unique to that service - not a
# real app variable, just a tracer to prove (via the resolved
# `environment.MARKER` in `docker compose config --format json`) that a
# service's env_file: never leaks another service's file, and vice
# versa. See test 4 below.
echo "MARKER=gateway-marker" >"${CONFIG_DIR}/gateway.env"
cat >"${CONFIG_DIR}/auth.env" <<'EOF'
POSTGRES_PASSWORD=auth-pw
JWT_PRIVATE_KEY=jwt-key
TOTP_ENCRYPTION_KEY=totp-key
MARKER=auth-marker
EOF
printf 'POSTGRES_PASSWORD=apiary-pw\nMARKER=apiary-marker\n' >"${CONFIG_DIR}/apiary.env"
printf 'POSTGRES_PASSWORD=hive-pw\nMARKER=hive-marker\n' >"${CONFIG_DIR}/hive.env"
printf 'POSTGRES_PASSWORD=inspection-pw\nMARKER=inspection-marker\n' >"${CONFIG_DIR}/inspection.env"
printf 'POSTGRES_PASSWORD=harvest-pw\nMARKER=harvest-marker\n' >"${CONFIG_DIR}/harvest.env"
cat >"${CONFIG_DIR}/media.env" <<'EOF'
POSTGRES_PASSWORD=media-pw
STORAGE_BUCKET=beebase-prod
MARKER=media-marker
EOF
echo "MARKER=statistics-marker" >"${CONFIG_DIR}/statistics.env"
echo "MARKER=subscription-marker" >"${CONFIG_DIR}/subscription.env"
cat >"${CONFIG_DIR}/notification.env" <<'EOF'
POSTGRES_NOTIFICATION_PASSWORD=notification-pw
FIREBASE_PROJECT_ID=beebase-production
FIREBASE_SERVICE_ACCOUNT_JSON_BASE64=eyJ0eXBlIjoic2VydmljZV9hY2NvdW50In0=
AUTH_JWKS_URL=http://auth-service:8080/.well-known/jwks.json
REDIS_ADDR=redis:6379
APPLE_BUNDLE_ID=com.beebase.production
APPLE_KEY_ID=key
APPLE_ISSUER_ID=issuer
APPLE_PRIVATE_KEY=private
APPLE_ENVIRONMENT=Production
MARKER=notification-marker
EOF
chmod 600 "${CONFIG_DIR}"/*.env

FAKE_ENV=(
  ECR_REGISTRY=123456789012.dkr.ecr.eu-central-1.amazonaws.com
  AWS_REGION=eu-central-1
  RELEASE=2026.09.07-1
  BEEBASE_CONFIG_DIR="${CONFIG_DIR}"
  GATEWAY_IMAGE_TAG=5a066d9aa5a066d9aa5a066d9aa5a066d9aa5a06
  AUTH_IMAGE_TAG=0b4d246bb0b4d246bb0b4d246bb0b4d246bb0b4d
  APIARY_IMAGE_TAG=436efffcc436efffcc436efffcc436efffcc436
  HIVE_IMAGE_TAG=f9e257addf9e257addf9e257addf9e257addf9e
  INSPECTION_IMAGE_TAG=8844c5bee8844c5bee8844c5bee8844c5bee8844
  HARVEST_IMAGE_TAG=c2b91af00c2b91af00c2b91af00c2b91af00c2b9
  MEDIA_IMAGE_TAG=a5b903bffa5b903bffa5b903bffa5b903bffa5b9
  STATISTICS_IMAGE_TAG=a0877a011a0877a011a0877a011a0877a011a08
  SUBSCRIPTION_IMAGE_TAG=b85447100b85447100b85447100b85447100b854
  NOTIFICATION_IMAGE_TAG=c85447100c85447100c85447100c85447100c854
  PUBLIC_DOMAIN=api.beebase.club
  # Mirrors what deploy.sh copies (by name only, never logged) from each
  # service's own env file into deploy.env - see docker-compose.prod.yml's
  # header comment for why Compose still needs these at the top level.
  POSTGRES_AUTH_PASSWORD=auth-pw
  POSTGRES_APIARY_PASSWORD=apiary-pw
  POSTGRES_HIVE_PASSWORD=hive-pw
  POSTGRES_INSPECTION_PASSWORD=inspection-pw
  POSTGRES_HARVEST_PASSWORD=harvest-pw
  POSTGRES_MEDIA_PASSWORD=media-pw
  POSTGRES_SUBSCRIPTION_PASSWORD=subscription-pw
  POSTGRES_NOTIFICATION_PASSWORD=notification-pw
)

# --- 1. config succeeds with every variable set and every service env
#     file present ---

RESOLVED=$(env -i "${FAKE_ENV[@]}" PATH="${PATH}" docker compose -f "${COMPOSE_FILE}" config 2>&1)
if [ $? -eq 0 ]; then
  echo "PASS: docker compose config succeeds with all image tags and env files set"
  PASS=$((PASS + 1))
else
  echo "FAIL: docker compose config succeeds with all image tags and env files set"
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
  [beebase-harvest-service]=c2b91af00c2b91af00c2b91af00c2b91af00c2b9
  [beebase-media-service]=a5b903bffa5b903bffa5b903bffa5b903bffa5b9
  [beebase-statistics-service]=a0877a011a0877a011a0877a011a0877a011a08
  [beebase-subscription-service]=b85447100b85447100b85447100b85447100b854
  [beebase-notification-service]=c85447100c85447100c85447100c85447100c854
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
  [beebase-harvest-service]=c2b91af00c2b91af00c2b91af00c2b91af00c2b9
  [beebase-media-service]=a5b903bffa5b903bffa5b903bffa5b903bffa5b9
  [beebase-subscription-service]=b85447100b85447100b85447100b85447100b854
  [beebase-notification-service]=c85447100c85447100c85447100c85447100c854
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

# --- 4. each application service loads its own env file, and only its
#     own - the whole point of moving off one shared .env. `docker
#     compose config` fully inlines env_file: content into
#     `environment:` and drops the env_file: directive itself from its
#     output, so this is checked via each service's own MARKER value
#     (seeded above, one per file) rather than by looking for the
#     env_file: path directly. ---

declare -A expect_marker=(
  [gateway]=gateway-marker
  [auth-service]=auth-marker
  [apiary-service]=apiary-marker
  [hive-service]=hive-marker
  [inspection-service]=inspection-marker
  [harvest-service]=harvest-marker
  [media-service]=media-marker
  [statistics-service]=statistics-marker
  [subscription-service]=subscription-marker
)

RESOLVED_JSON=$(env -i "${FAKE_ENV[@]}" PATH="${PATH}" docker compose -f "${COMPOSE_FILE}" config --format json 2>/dev/null)

all_env_file_ok=1
for svc in "${!expect_marker[@]}"; do
  want="${expect_marker[${svc}]}"
  got=$(echo "${RESOLVED_JSON}" | jq -r --arg svc "${svc}" '.services[$svc].environment.MARKER // "none"' 2>/dev/null)

  if [ "${got}" = "${want}" ]; then
    echo "PASS: ${svc} loads only its own env file (MARKER=${got})"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${svc} should resolve MARKER=${want} from its own env file, got '${got}'"
    all_env_file_ok=0
    FAIL=$((FAIL + 1))
  fi
done

# infra services (postgres-*, migrate-*, redis, edge) must never see any
# service's MARKER - they don't use env_file: at all, by design.
for svc in postgres-auth postgres-apiary postgres-hive postgres-inspection postgres-harvest postgres-media postgres-subscription migrate-auth migrate-apiary migrate-hive migrate-inspection migrate-harvest migrate-media migrate-subscription redis edge; do
  got=$(echo "${RESOLVED_JSON}" | jq -r --arg svc "${svc}" '.services[$svc].environment.MARKER // "none"' 2>/dev/null)
  if [ "${got}" = "none" ]; then
    echo "PASS: ${svc} does not load any service's env file"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${svc} unexpectedly resolved MARKER=${got} - it must not use env_file:"
    all_env_file_ok=0
    FAIL=$((FAIL + 1))
  fi
done

# --- 5. auth-service's resolved JWT_PRIVATE_KEY/TOTP_ENCRYPTION_KEY come
#     from auth.env (env_file), not from a compose-level default or
#     another service's file - and media-service's STORAGE_BUCKET comes
#     from media.env the same way ---

AUTH_ENV_JSON=$(echo "${RESOLVED_JSON}" | jq -r '.services["auth-service"].environment.JWT_PRIVATE_KEY // empty' 2>/dev/null)
if [ "${AUTH_ENV_JSON}" = "jwt-key" ]; then
  echo "PASS: auth-service resolves JWT_PRIVATE_KEY from auth.env"
  PASS=$((PASS + 1))
else
  echo "FAIL: auth-service resolves JWT_PRIVATE_KEY from auth.env (got '${AUTH_ENV_JSON}')"
  FAIL=$((FAIL + 1))
fi

MEDIA_BUCKET_JSON=$(echo "${RESOLVED_JSON}" | jq -r '.services["media-service"].environment.STORAGE_BUCKET // empty' 2>/dev/null)
if [ "${MEDIA_BUCKET_JSON}" = "beebase-prod" ]; then
  echo "PASS: media-service resolves STORAGE_BUCKET from media.env"
  PASS=$((PASS + 1))
else
  echo "FAIL: media-service resolves STORAGE_BUCKET from media.env (got '${MEDIA_BUCKET_JSON}')"
  FAIL=$((FAIL + 1))
fi

# --- 6. a missing service env file fails compose config outright (the
#     mechanism deploy.sh's own pre-flight validation backs up, but
#     Compose itself must never silently proceed without it either) ---

MISSING_ENV_FILE_DIR="${TMP_DIR}/config-missing-hive"
cp -R "${CONFIG_DIR}" "${MISSING_ENV_FILE_DIR}"
rm "${MISSING_ENV_FILE_DIR}/hive.env"

MISSING_HIVE_ENV=("${FAKE_ENV[@]}")
for i in "${!MISSING_HIVE_ENV[@]}"; do
  case "${MISSING_HIVE_ENV[$i]}" in
    BEEBASE_CONFIG_DIR=*) MISSING_HIVE_ENV[$i]="BEEBASE_CONFIG_DIR=${MISSING_ENV_FILE_DIR}" ;;
  esac
done

if env -i "${MISSING_HIVE_ENV[@]}" PATH="${PATH}" docker compose -f "${COMPOSE_FILE}" config >/dev/null 2>&1; then
  echo "FAIL: a missing hive.env should fail docker compose config"
  FAIL=$((FAIL + 1))
else
  echo "PASS: a missing service env file (hive.env) fails docker compose config"
  PASS=$((PASS + 1))
fi

echo
echo "compose config tests: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
