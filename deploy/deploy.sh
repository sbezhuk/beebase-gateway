#!/bin/bash

set -euo pipefail

# Deploys one immutable release manifest to the BeeBase production
# stack. Invoked on the EC2 host itself, normally via the
# production-release GitHub Actions workflow's `aws ssm send-command`
# (AWS-RunShellScript) targeting this instance - see
# .github/workflows/production-release.yml for the exact invocation.
#
# BeeBase is 9 independent Git repositories, each with its own pipeline
# and its own commit SHA - there is no single Git SHA that describes
# "the app". A release manifest is what does: a plain KEY=VALUE file
# naming the exact image tag (Git SHA) of every one of the 10 services
# that make up one production release together. See
# deploy/lib/manifest.sh for its format and validation rules, and
# docker-compose.prod.yml's header comment for why the compose file has
# one image-tag variable per service instead of a single IMAGE_TAG.
#
# Manifests are immutable and never rebuilt: this script only ever reads
# the one it's given (normally from /opt/beebase/releases/<release>.env)
# and, once the deploy succeeds, points /opt/beebase/releases/current at
# it. Rolling back means re-running this script against a previous
# manifest already on disk - see the README's Rollback section.
#
# The deployment bundle installed under /opt/beebase/deploy contains the
# deployment script, manifest library, Caddyfile and docker-compose.prod.yml.
# The bundle is installed during EC2 bootstrap from an immutable S3 object.
#
# Configuration: each of the 9 application services owns its own
# production .env at ${BEEBASE_CONFIG_DIR:-/opt/beebase/config}/<service>.env
# (see deploy/lib/env_config.sh for the exact file names and required
# keys, and deploy/env-templates/ for the per-service templates an
# operator provisions them from). This script never writes to any of
# those 9 files - it only validates them, every time, before it will
# touch the running stack (see "Validate every service's own .env"
# below) - and never prints a value from any of them, only key names.
#
# The single exception is ${CONFIG_DIR}/deploy.env, which this script
# fully regenerates on every deploy: non-secret deploy-computed values
# (ECR_REGISTRY, AWS_REGION, RELEASE, every *_IMAGE_TAG, PUBLIC_DOMAIN,
# BEEBASE_CONFIG_DIR) plus a same-deploy copy of each
# POSTGRES_*_PASSWORD read from that service's own .env. deploy.env
# exists only because Docker Compose's own ${VAR} interpolation (used by
# every postgres-* container and migrate-* job) can only ever read from
# the single file passed via `docker compose --env-file` - see
# docker-compose.prod.yml's header comment. It is a derived cache
# regenerated from the 9 authoritative files every time, never operator
# -edited, and never a second source of truth.
#
# The old, single, shared /opt/beebase/config/.env this replaced is
# never read, written, or deleted by this script. Nothing here migrates
# it or treats it as a fallback - see the deployment report's remaining
# migration step for retiring it once the new flow is proven.
#
# Usage: deploy.sh <release-manifest.env>
#   e.g. deploy.sh /opt/beebase/releases/2026.09.07-1.env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/manifest.sh
source "${SCRIPT_DIR}/lib/manifest.sh"
# shellcheck source=lib/env_config.sh
source "${SCRIPT_DIR}/lib/env_config.sh"

COMPOSE_DIR="${BEEBASE_COMPOSE_DIR:-/opt/beebase/compose}"
CONFIG_DIR="${BEEBASE_CONFIG_DIR:-/opt/beebase/config}"
RELEASES_DIR="${BEEBASE_RELEASES_DIR:-/opt/beebase/releases}"

DEPLOY_ENV_FILE="${CONFIG_DIR}/deploy.env"
CADDYFILE_SOURCE="${SCRIPT_DIR}/Caddyfile"
CADDYFILE_TARGET="${CONFIG_DIR}/Caddyfile"

CURRENT_LINK="${RELEASES_DIR}/current"
COMPOSE="docker compose -f ${COMPOSE_DIR}/docker-compose.prod.yml --env-file ${DEPLOY_ENV_FILE}"
SSM_PATH="/beebase/prod"

log() {
  echo "[deploy $(date -u +%H:%M:%S)] $*"
}

fail() {
  echo "[deploy $(date -u +%H:%M:%S)] ERROR: $*" >&2
  exit 1
}

# --- 1, 2, 3. Receive, parse and validate the release manifest ---
#
# Every required-key/tag-format/"latest" check lives in
# deploy/lib/manifest.sh so it can be unit-tested on its own, without
# AWS or Docker - see deploy/tests/test_manifest.sh.

MANIFEST_FILE="${1:-}"

[ -n "${MANIFEST_FILE}" ] \
  || fail "usage: deploy.sh <release-manifest.env> (e.g. /opt/beebase/releases/2026.09.07-1.env)"

manifest_parse "${MANIFEST_FILE}" \
  || fail "manifest '${MANIFEST_FILE}' failed to parse (see above)"

manifest_validate \
  || fail "manifest '${MANIFEST_FILE}' failed validation (see above)"

RELEASE="$(manifest_get RELEASE)"

log "deploying release ${RELEASE} from ${MANIFEST_FILE}"

for key in "${MANIFEST_SERVICE_TAG_KEYS[@]}"; do
  log "  ${key}=$(manifest_get "${key}")"
done

# --- Rollback safety: if this exact release was deployed successfully
#     before, restore the exact per-service .env files it was deployed
#     with, before anything else happens. This is what keeps an image
#     tag and its configuration from ever coming apart across a
#     rollback: re-running deploy.sh against an older manifest (the
#     documented way to roll back - see the README) always redeploys
#     that release's images together with that release's own
#     configuration, not whatever an operator may have edited into the
#     live files since. A first-time deploy of a brand-new release has
#     no snapshot yet, so this is a no-op and the currently live,
#     operator-provisioned files are what gets validated and deployed
#     below - and, on success, snapshotted for any future rollback to
#     this release. ---

CONFIG_SNAPSHOT_DIR="${RELEASES_DIR}/${RELEASE}/config-snapshot"

if [ -d "${CONFIG_SNAPSHOT_DIR}" ]; then
  log "release ${RELEASE} was deployed before - restoring its exact per-service configuration from ${CONFIG_SNAPSHOT_DIR} (values never logged)"

  mkdir -p "${CONFIG_DIR}"

  for service in "${ENV_SERVICES[@]}"; do
    snapshot_file="${CONFIG_SNAPSHOT_DIR}/${ENV_FILE_NAME[${service}]}"
    live_file="$(env_config_file_path "${CONFIG_DIR}" "${service}")"

    [ -f "${snapshot_file}" ] \
      || fail "config snapshot for release ${RELEASE} is missing ${ENV_FILE_NAME[${service}]} - refusing to deploy with a partial rollback snapshot"

    cp "${snapshot_file}" "${live_file}"
    chmod 600 "${live_file}"
  done

  log "restored configuration for all 9 services from release ${RELEASE}'s snapshot"
fi

# --- 6. Validate every service's own production .env exists, is mode
#     0600, and has every required key set - BEFORE anything about the
#     running application stack changes. Every failure is reported (not
#     just the first) so an operator sees the complete picture in one
#     pass. Never prints a value, only key names - see
#     deploy/lib/env_config.sh. ---

log "validating each of the 9 services' production .env files in ${CONFIG_DIR}"

env_config_validate_all "${CONFIG_DIR}" \
  || fail "one or more service .env files in ${CONFIG_DIR} failed validation (see above) - provision/fix them before deploying; deploy.sh never creates or completes these files itself"

log "all 9 service .env files present, mode 0600, and complete"

# --- Derive account/region-specific values from the instance itself ---
#
# IMDSv2 is required (metadata_options in Terraform enforces this).

IMDS_TOKEN=$(curl -fsS -X PUT \
  "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")

AWS_REGION=$(curl -fsS \
  -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
  http://169.254.169.254/latest/meta-data/placement/region)

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# --- Regenerate ${CONFIG_DIR}/deploy.env, the one file Compose's own
#     ${VAR} interpolation reads (see this script's and
#     docker-compose.prod.yml's header comments for why this file has to
#     exist at all). Fully regenerated every deploy, atomically swapped
#     into place only once complete - the 9 service .env files
#     themselves are never written to by this script. ---

mkdir -p "${CONFIG_DIR}"

umask 077

TMP_DEPLOY_ENV_FILE="$(mktemp "${CONFIG_DIR}/.deploy.env.XXXXXX")"

{
  echo "ECR_REGISTRY=${ECR_REGISTRY}"
  echo "AWS_REGION=${AWS_REGION}"
  echo "RELEASE=${RELEASE}"
  echo "BEEBASE_CONFIG_DIR=${CONFIG_DIR}"

  for key in "${MANIFEST_SERVICE_TAG_KEYS[@]}"; do
    echo "${key}=$(manifest_get "${key}")"
  done

  # Copy each service's own POSTGRES_PASSWORD into deploy.env under the
  # per-service interpolation key name docker-compose.prod.yml expects
  # (POSTGRES_AUTH_PASSWORD, POSTGRES_APIARY_PASSWORD, ...) - see
  # deploy/lib/env_config.sh's ENV_DB_INTERPOLATION_KEY comment. Read
  # straight from the authoritative per-service file; never echoed
  # anywhere else, including this script's own log output.
  for service in "${!ENV_DB_INTERPOLATION_KEY[@]}"; do
    service_file="$(env_config_file_path "${CONFIG_DIR}" "${service}")"
    password_key="${ENV_DB_INTERPOLATION_KEY[${service}]}"
    password="$(env_config_read_value "${service_file}" "${password_key}")"
    echo "${password_key}=${password}"
  done

  # The internal credential is shared by the cleanup endpoints. Read it from
  # the already-authoritative apiary env file so Compose can inject it into
  # services whose own env files do not participate in interpolation.
  internal_token="$(env_config_read_value "$(env_config_file_path "${CONFIG_DIR}" apiary)" INTERNAL_SERVICE_TOKEN)"
  echo "INTERNAL_SERVICE_TOKEN=${internal_token}"
} >"${TMP_DEPLOY_ENV_FILE}"

log "fetching non-secret global parameters from SSM Parameter Store (${SSM_PATH})"

# Only PUBLIC_DOMAIN is fetched from SSM: it's the one deploy-owned,
# genuinely global, non-secret value with no single service owner (every
# service's own configuration - including what used to be sourced from
# SSM, like media-service's STORAGE_BUCKET - now lives in that service's
# own .env; see requirement 10 in the deployment report). SSM remains
# available only as this narrow, non-secret, migration-era mechanism -
# it is never the source of truth for any production secret. Anything
# else found under ${SSM_PATH} (including a stale secret parameter left
# over from before this migration) is ignored outright and logged by
# name only, never written anywhere or echoed.

NEXT_TOKEN=""
PUBLIC_DOMAIN_FOUND=0

while : ; do
  if [ -z "${NEXT_TOKEN}" ]; then
    PAGE=$(aws ssm get-parameters-by-path \
      --path "${SSM_PATH}" \
      --with-decryption \
      --output json)
  else
    PAGE=$(aws ssm get-parameters-by-path \
      --path "${SSM_PATH}" \
      --with-decryption \
      --output json \
      --starting-token "${NEXT_TOKEN}")
  fi

  ALL_LINES=$(
    echo "${PAGE}" |
      jq -r --arg prefix "${SSM_PATH}/" \
        '.Parameters[]
         | (.Name | sub("^" + $prefix; "")) as $key
         | "\($key)=\(.Value)"'
  )

  while IFS= read -r line; do
    [ -n "${line}" ] || continue

    key="${line%%=*}"

    if [ "${key}" = "PUBLIC_DOMAIN" ]; then
      echo "${line}" >>"${TMP_DEPLOY_ENV_FILE}"
      PUBLIC_DOMAIN_FOUND=1
    else
      log "ignoring SSM parameter ${key} - only PUBLIC_DOMAIN is sourced from SSM; every service's own configuration comes from its own .env only"
    fi
  done <<<"${ALL_LINES}"

  NEXT_TOKEN=$(echo "${PAGE}" | jq -r '.NextToken // empty')

  [ -n "${NEXT_TOKEN}" ] || break
done

[ "${PUBLIC_DOMAIN_FOUND}" -eq 1 ] \
  || fail "expected PUBLIC_DOMAIN under ${SSM_PATH} in SSM Parameter Store, found none - check SSM Parameter Store setup"

mv "${TMP_DEPLOY_ENV_FILE}" "${DEPLOY_ENV_FILE}"
chmod 600 "${DEPLOY_ENV_FILE}"

DEPLOY_ENV_PARAM_COUNT=$(grep -c '=' "${DEPLOY_ENV_FILE}" || true)

log "wrote ${DEPLOY_ENV_PARAM_COUNT} parameters to ${DEPLOY_ENV_FILE} (0600, deploy-generated, values never logged)"

# --- Ensure the Caddyfile is a regular file ---
#
# The Caddyfile is part of the immutable deployment bundle.
#
# This explicitly repairs an invalid host state where
# /opt/beebase/config/Caddyfile exists as a directory. Docker Compose can
# otherwise interpret a missing bind-mount source as a directory, which
# can result in the exact failure where Caddyfile becomes a directory.
#
# Always validate the source before touching the target.

log "installing Caddyfile"

[ -f "${CADDYFILE_SOURCE}" ] \
  || fail "Caddyfile source is missing: ${CADDYFILE_SOURCE}"

mkdir -p "${CONFIG_DIR}"

if [ -d "${CADDYFILE_TARGET}" ]; then
  log "removing invalid Caddyfile directory: ${CADDYFILE_TARGET}"
  rm -rf "${CADDYFILE_TARGET}"
fi

cp "${CADDYFILE_SOURCE}" "${CADDYFILE_TARGET}"

chmod 600 "${CADDYFILE_TARGET}"

[ -f "${CADDYFILE_TARGET}" ] \
  || fail "failed to install Caddyfile: ${CADDYFILE_TARGET}"

log "Caddyfile installed successfully at ${CADDYFILE_TARGET}"

# --- 9. Authenticate to ECR using the EC2 instance role ---

log "authenticating to ECR (${ECR_REGISTRY})"

aws ecr get-login-password \
  --region "${AWS_REGION}" |
  docker login \
    --username AWS \
    --password-stdin "${ECR_REGISTRY}"

# --- 11. Verify every image the manifest names actually exists in ECR ---
#
# This happens BEFORE anything about the running application stack changes.
#
# A missing image fails the deployment outright. There is never a fallback
# to "latest" or to whatever image was already running.

log "verifying every manifest image exists in ECR"

for key in "${MANIFEST_SERVICE_TAG_KEYS[@]}"; do
  repo="${MANIFEST_ECR_REPO[${key}]}"
  tag="$(manifest_get "${key}")"

  aws ecr describe-images \
    --region "${AWS_REGION}" \
    --repository-name "${repo}" \
    --image-ids "imageTag=${tag}" \
    >/dev/null \
    || fail "image ${repo}:${tag} (${key}) not found in ECR - refusing to deploy"
done

for key in "${MANIFEST_MIGRATE_TAG_KEYS[@]}"; do
  repo="${MANIFEST_ECR_REPO[${key}]}"
  tag="$(manifest_get "${key}")-migrate"

  aws ecr describe-images \
    --region "${AWS_REGION}" \
    --repository-name "${repo}" \
    --image-ids "imageTag=${tag}" \
    >/dev/null \
    || fail "image ${repo}:${tag} not found in ECR - refusing to deploy"
done

log "all required images present in ECR"

# --- 10. Pull the verified images ---

log "pulling images for release ${RELEASE}"

${COMPOSE} pull

# --- 12, 13. Start the data layer, then run required database migrations ---
#
# Explicit, individually-checked migrations ensure that a migration failure
# stops the deployment before application containers are recreated.

log "starting data layer (postgres x8, redis)"

${COMPOSE} up -d \
  postgres-auth \
  postgres-apiary \
  postgres-hive \
  postgres-inspection \
  postgres-harvest \
  postgres-media \
  postgres-subscription \
  postgres-notification \
  redis

for svc in \
  postgres-auth \
  postgres-apiary \
  postgres-hive \
  postgres-inspection \
  postgres-harvest \
  postgres-media \
  postgres-subscription \
  postgres-notification \
  redis
do
  log "waiting for ${svc} to be healthy"

  HEALTHY=0
  STATUS="starting"

  for i in $(seq 1 30); do
    STATUS=$(
      ${COMPOSE} ps --format json "${svc}" |
        jq -r '.Health // "starting"'
    )

    if [ "${STATUS}" = "healthy" ]; then
      HEALTHY=1
      break
    fi

    sleep 2
  done

  [ "${HEALTHY}" -eq 1 ] \
    || fail "${svc} did not become healthy in time (last status: ${STATUS})"
done

for svc in \
  migrate-auth \
  migrate-apiary \
  migrate-hive \
  migrate-inspection \
  migrate-harvest \
  migrate-media \
  migrate-subscription
do
  log "running ${svc}"

  ${COMPOSE} run --rm --no-deps "${svc}" \
    || fail "${svc} failed - aborting deploy before touching application containers"
done

# --- 14. Start/recreate the production stack ---
#
# Every application container is recreated against this one release
# manifest's exact image tags, and each one loads its own service .env
# via `env_file:` (see docker-compose.prod.yml).

log "starting/recreating the full stack"

${COMPOSE} up -d --remove-orphans

# --- 15. Wait for health/readiness checks ---
#
# `edge` (Caddy) intentionally defines no Docker HEALTHCHECK - Caddy's
# own startup logs already confirm it is serving traffic and has
# provisioned TLS, so a Docker health status would be redundant and we
# do not add a fake one just to satisfy this script. Docker therefore
# always reports Health=none for it, which must not be treated as
# "unhealthy": edge is ready once its container state is "running".
# exited/dead/a container that can't be found at all are treated as an
# outright deployment failure rather than something worth retrying.

log "waiting for edge to be running"

EDGE_READY=0
EDGE_STATE="starting"

for i in $(seq 1 30); do
  EDGE_STATE=$(
    ${COMPOSE} ps --format json edge |
      jq -r '.State // empty'
  )

  [ -n "${EDGE_STATE}" ] || EDGE_STATE="not-found"

  case "${EDGE_STATE}" in
    running)
      EDGE_READY=1
      break
      ;;
    exited | dead | not-found)
      fail "edge container is ${EDGE_STATE} - deployment failed"
      ;;
  esac

  sleep 2
done

[ "${EDGE_READY}" -eq 1 ] \
  || fail "edge did not reach running state in time (last state: ${EDGE_STATE})"

log "edge is running"

APP_SERVICES="
gateway
auth-service
apiary-service
hive-service
inspection-service
harvest-service
media-service
statistics-service
subscription-service
notification-service
"

for svc in ${APP_SERVICES}; do
  log "waiting for ${svc} to be healthy"

  HEALTHY=0
  STATUS="starting"

  for i in $(seq 1 30); do
    STATUS=$(
      ${COMPOSE} ps --format json "${svc}" |
        jq -r '.Health // "starting"'
    )

    if [ "${STATUS}" = "healthy" ]; then
      HEALTHY=1
      break
    fi

    sleep 2
  done

  [ "${HEALTHY}" -eq 1 ] \
    || fail "${svc} did not become healthy in time (last status: ${STATUS})"
done

# --- 16. Basic smoke test through the gateway ---
#
# Exercises the actual proxy path rather than only checking isolated
# container healthchecks.

log "smoke test: GET /health via gateway"

${COMPOSE} exec -T gateway \
  wget -qO- http://localhost:8080/health |
  grep -q '"status":"ok"' \
  || fail "smoke test failed: gateway /health did not return ok"

log "smoke test: GET /.well-known/jwks.json via gateway"

JWKS=$(
  ${COMPOSE} exec -T gateway \
    wget -qO- http://localhost:8080/.well-known/jwks.json
)

echo "${JWKS}" |
  jq -e '.keys | length > 0' \
  >/dev/null \
  || fail "smoke test failed: jwks.json via gateway did not return a signing key"
# --- Snapshot this release's exact configuration for future rollbacks ---
#
# Reached only after every health check and smoke test passed, so a
# snapshot only ever exists for configuration that's actually known to
# work together with this release's images. A future rollback to this
# exact release restores this exact snapshot (see the restore step near
# the top of this script), keeping an image tag and its configuration
# from ever coming apart. deploy.env is deliberately NOT snapshotted -
# it is derived, deploy-owned and non-secret, and is regenerated fresh
# from the snapshotted per-service files on every future deploy anyway.

log "snapshotting this release's per-service configuration for future rollbacks"

mkdir -p "${CONFIG_SNAPSHOT_DIR}"
chmod 700 "${CONFIG_SNAPSHOT_DIR}"

for service in "${ENV_SERVICES[@]}"; do
  live_file="$(env_config_file_path "${CONFIG_DIR}" "${service}")"
  snapshot_file="${CONFIG_SNAPSHOT_DIR}/${ENV_FILE_NAME[${service}]}"

  cp "${live_file}" "${snapshot_file}"
  chmod 600 "${snapshot_file}"
done

log "configuration snapshot for release ${RELEASE} written to ${CONFIG_SNAPSHOT_DIR}"

# --- Record this release as the currently deployed one ---
#
# This is reached only after all health checks and smoke tests passed.
# `current` therefore always points at a manifest that successfully passed
# deployment validation.

mkdir -p "${RELEASES_DIR}"

MANIFEST_ABS_PATH="$(
  cd "$(dirname "${MANIFEST_FILE}")" &&
  pwd
)/$(basename "${MANIFEST_FILE}")"

ln -sfn "${MANIFEST_ABS_PATH}" "${CURRENT_LINK}"

# --- 17. Success ---

log "deploy of release ${RELEASE} complete (current -> ${MANIFEST_ABS_PATH})"

${COMPOSE} ps
