#!/bin/bash
# Deploys one immutable release manifest to the BeeBase production
# stack. Invoked on the EC2 host itself, normally via the
# production-release GitHub Actions workflow's `aws ssm send-command`
# (AWS-RunShellScript) targeting this instance - see
# .github/workflows/production-release.yml for the exact invocation.
#
# BeeBase is 7 independent Git repositories, each with its own pipeline
# and its own commit SHA - there is no single Git SHA that describes
# "the app". A release manifest is what does: a plain KEY=VALUE file
# naming the exact image tag (Git SHA) of every one of the 7 services
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
# Secrets are never stored in the deployment bundle or release manifest.
# Production secrets/configuration are retrieved from AWS SSM Parameter
# Store on every deployment and written to /opt/beebase/config/.env.
#
# Usage: deploy.sh <release-manifest.env>
#   e.g. deploy.sh /opt/beebase/releases/2026.09.07-1.env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/manifest.sh
source "${SCRIPT_DIR}/lib/manifest.sh"

COMPOSE_DIR="${BEEBASE_COMPOSE_DIR:-/opt/beebase/compose}"
CONFIG_DIR="${BEEBASE_CONFIG_DIR:-/opt/beebase/config}"
RELEASES_DIR="${BEEBASE_RELEASES_DIR:-/opt/beebase/releases}"

ENV_FILE="${CONFIG_DIR}/.env"
CADDYFILE_SOURCE="${SCRIPT_DIR}/Caddyfile"
CADDYFILE_TARGET="${CONFIG_DIR}/Caddyfile"

CURRENT_LINK="${RELEASES_DIR}/current"
COMPOSE="docker compose -f ${COMPOSE_DIR}/docker-compose.prod.yml --env-file ${ENV_FILE}"
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

manifest::parse "${MANIFEST_FILE}" \
  || fail "manifest '${MANIFEST_FILE}' failed to parse (see above)"

manifest::validate \
  || fail "manifest '${MANIFEST_FILE}' failed validation (see above)"

RELEASE="$(manifest::get RELEASE)"

log "deploying release ${RELEASE} from ${MANIFEST_FILE}"

for key in "${MANIFEST_SERVICE_TAG_KEYS[@]}"; do
  log "  ${key}=$(manifest::get "${key}")"
done

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

# --- 6. Retrieve production secrets/config from SSM Parameter Store ---
#
# Everything under /beebase/prod - both plain config and SecureString
# secrets - is retrieved on every deployment.
#
# The manifest itself never contains secrets - only image tags and the
# release id/timestamp.

log "fetching parameters from SSM Parameter Store (${SSM_PATH})"

mkdir -p "${CONFIG_DIR}"

umask 077

: >"${ENV_FILE}"

{
  echo "ECR_REGISTRY=${ECR_REGISTRY}"
  echo "AWS_REGION=${AWS_REGION}"
  echo "RELEASE=${RELEASE}"

  for key in "${MANIFEST_SERVICE_TAG_KEYS[@]}"; do
    echo "${key}=$(manifest::get "${key}")"
  done
} >>"${ENV_FILE}"

NEXT_TOKEN=""

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

  echo "${PAGE}" |
    jq -r --arg prefix "${SSM_PATH}/" \
      '.Parameters[]
       | (.Name | sub("^" + $prefix; "")) as $key
       | "\($key)=\(.Value)"' \
    >>"${ENV_FILE}"

  NEXT_TOKEN=$(echo "${PAGE}" | jq -r '.NextToken // empty')

  [ -n "${NEXT_TOKEN}" ] || break
done

chmod 600 "${ENV_FILE}"

PARAM_COUNT=$(grep -c '=' "${ENV_FILE}" || true)

log "wrote ${PARAM_COUNT} parameters to ${ENV_FILE} (0600)"

[ "${PARAM_COUNT}" -gt $((3 + ${#MANIFEST_SERVICE_TAG_KEYS[@]})) ] \
  || fail "expected production secrets under ${SSM_PATH}, found none - check SSM Parameter Store setup"

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
  tag="$(manifest::get "${key}")"

  aws ecr describe-images \
    --region "${AWS_REGION}" \
    --repository-name "${repo}" \
    --image-ids "imageTag=${tag}" \
    >/dev/null \
    || fail "image ${repo}:${tag} (${key}) not found in ECR - refusing to deploy"
done

for key in "${MANIFEST_MIGRATE_TAG_KEYS[@]}"; do
  repo="${MANIFEST_ECR_REPO[${key}]}"
  tag="$(manifest::get "${key}")-migrate"

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

log "starting data layer (postgres x5, redis)"

${COMPOSE} up -d \
  postgres-auth \
  postgres-apiary \
  postgres-hive \
  postgres-inspection \
  postgres-media \
  redis

for svc in \
  postgres-auth \
  postgres-apiary \
  postgres-hive \
  postgres-inspection \
  postgres-media \
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
  migrate-media
do
  log "running ${svc}"

  ${COMPOSE} run --rm --no-deps "${svc}" \
    || fail "${svc} failed - aborting deploy before touching application containers"
done

# --- 14. Start/recreate the production stack ---
#
# Every application container is recreated against this one release
# manifest's exact image tags.

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
media-service
statistics-service
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