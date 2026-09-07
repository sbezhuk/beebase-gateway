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
# Assumes docker-compose.prod.yml, this script, deploy/lib/manifest.sh
# and Caddyfile are already in place under /opt/beebase (bootstrapped
# once manually or via a dedicated ops update - they change rarely,
# unlike the release manifests this script deploys on every run).
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
CURRENT_LINK="${RELEASES_DIR}/current"
COMPOSE="docker compose -f ${COMPOSE_DIR}/docker-compose.prod.yml --env-file ${ENV_FILE}"
SSM_PATH="/beebase/prod"

log() { echo "[deploy $(date -u +%H:%M:%S)] $*"; }
fail() { echo "[deploy $(date -u +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

# --- 1, 2, 3. Receive, parse and validate the release manifest ---
#
# Every required-key/tag-format/"latest" check lives in
# deploy/lib/manifest.sh so it can be unit-tested on its own, without
# AWS or Docker - see deploy/tests/test_manifest.sh.

MANIFEST_FILE="${1:-}"
[ -n "${MANIFEST_FILE}" ] || fail "usage: deploy.sh <release-manifest.env>  (e.g. /opt/beebase/releases/2026.09.07-1.env)"

manifest::parse "${MANIFEST_FILE}" || fail "manifest '${MANIFEST_FILE}' failed to parse (see above)"
manifest::validate || fail "manifest '${MANIFEST_FILE}' failed validation (see above)"

RELEASE="$(manifest::get RELEASE)"
log "deploying release ${RELEASE} from ${MANIFEST_FILE}"
for key in "${MANIFEST_SERVICE_TAG_KEYS[@]}"; do
  log "  ${key}=$(manifest::get "${key}")"
done

# --- Derive account/region-specific values from the instance itself
#     rather than hardcoding them - IMDSv2 token required (metadata_options
#     in Terraform enforces this). ---

IMDS_TOKEN=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
AWS_REGION=$(curl -fsS -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
  http://169.254.169.254/latest/meta-data/placement/region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# --- 6. Retrieve production secrets/config from SSM Parameter Store,
#     write a fresh 0600 environment file, adding the manifest's image
#     tags on top ---
#
# Everything under /beebase/prod - both plain config (PUBLIC_DOMAIN,
# STORAGE_BUCKET, ...) and SecureString secrets (JWT_PRIVATE_KEY,
# POSTGRES_*_PASSWORD, ...) - lives in one path so a single call
# retrieves it all; --with-decryption is a no-op for the plain-String
# parameters and decrypts the SecureString ones. The manifest itself
# never contains secrets - only image tags and the release id/timestamp.

log "fetching parameters from SSM Parameter Store (${SSM_PATH})"

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
    PAGE=$(aws ssm get-parameters-by-path --path "${SSM_PATH}" --with-decryption --output json)
  else
    PAGE=$(aws ssm get-parameters-by-path --path "${SSM_PATH}" --with-decryption --output json --starting-token "${NEXT_TOKEN}")
  fi

  echo "${PAGE}" | jq -r --arg prefix "${SSM_PATH}/" \
    '.Parameters[] | (.Name | sub("^" + $prefix; "")) as $key | "\($key)=\(.Value)"' \
    >>"${ENV_FILE}"

  NEXT_TOKEN=$(echo "${PAGE}" | jq -r '.NextToken // empty')
  [ -n "${NEXT_TOKEN}" ] || break
done

chmod 600 "${ENV_FILE}"
PARAM_COUNT=$(grep -c '=' "${ENV_FILE}" || true)
log "wrote ${PARAM_COUNT} parameters to ${ENV_FILE} (0600)"
[ "${PARAM_COUNT}" -gt $((3 + ${#MANIFEST_SERVICE_TAG_KEYS[@]})) ] || fail "expected production secrets under ${SSM_PATH}, found none - check SSM Parameter Store setup"

# --- 9. Authenticate to ECR using the EC2 instance role ---

log "authenticating to ECR (${ECR_REGISTRY})"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

# --- 11. Verify every image the manifest names actually exists in ECR
#     BEFORE anything about the running stack changes. A missing image
#     fails the deploy outright - it is never silently skipped, and
#     nothing here ever falls back to "latest" or to whatever was
#     already running. ---

log "verifying every manifest image exists in ECR"
for key in "${MANIFEST_SERVICE_TAG_KEYS[@]}"; do
  repo="${MANIFEST_ECR_REPO[${key}]}"
  tag="$(manifest::get "${key}")"
  aws ecr describe-images --region "${AWS_REGION}" --repository-name "${repo}" --image-ids "imageTag=${tag}" >/dev/null \
    || fail "image ${repo}:${tag} (${key}) not found in ECR - refusing to deploy"
done
for key in "${MANIFEST_MIGRATE_TAG_KEYS[@]}"; do
  repo="${MANIFEST_ECR_REPO[${key}]}"
  tag="$(manifest::get "${key}")-migrate"
  aws ecr describe-images --region "${AWS_REGION}" --repository-name "${repo}" --image-ids "imageTag=${tag}" >/dev/null \
    || fail "image ${repo}:${tag} not found in ECR - refusing to deploy"
done
log "all required images present in ECR"

# --- 10. Pull the verified images ---

log "pulling images for release ${RELEASE}"
${COMPOSE} pull

# --- 12, 13. Start the data layer, then run required database
#     migrations, one per service, using the exact migrate image named
#     by the manifest ---
#
# Explicit, individually-checked run --rm invocations rather than folding
# migrations into the general `up -d` below: a migration failure must be
# unambiguous and must stop the deploy before any application container
# using the new (possibly migration-dependent) code starts.

log "starting data layer (postgres x5, redis)"
${COMPOSE} up -d postgres-auth postgres-apiary postgres-hive postgres-inspection postgres-media redis

for svc in postgres-auth postgres-apiary postgres-hive postgres-inspection postgres-media redis; do
  log "waiting for ${svc} to be healthy"
  for i in $(seq 1 30); do
    STATUS=$(${COMPOSE} ps --format json "${svc}" | jq -r '.Health // "starting"')
    [ "${STATUS}" = "healthy" ] && break
    sleep 2
  done
  [ "${STATUS}" = "healthy" ] || fail "${svc} did not become healthy in time"
done

for svc in migrate-auth migrate-apiary migrate-hive migrate-inspection migrate-media; do
  log "running ${svc}"
  ${COMPOSE} run --rm --no-deps "${svc}" || fail "${svc} failed - aborting deploy before touching application containers"
done

# --- 14. Start/recreate the production stack ---
#
# Every application container is recreated together against this one
# manifest's tags - never a partial mix of old and new image versions.

log "starting/recreating the full stack"
${COMPOSE} up -d --remove-orphans

# --- 15. Wait for health/readiness checks ---

APP_SERVICES="edge gateway auth-service apiary-service hive-service inspection-service media-service statistics-service"
for svc in ${APP_SERVICES}; do
  log "waiting for ${svc} to be healthy"
  HEALTHY=0
  for i in $(seq 1 30); do
    STATUS=$(${COMPOSE} ps --format json "${svc}" | jq -r '.Health // "starting"')
    if [ "${STATUS}" = "healthy" ]; then HEALTHY=1; break; fi
    sleep 2
  done
  [ "${HEALTHY}" -eq 1 ] || fail "${svc} did not become healthy in time (last status: ${STATUS})"
done

# --- 16. Basic smoke test through the gateway ---
#
# Exercises the actual proxy path (gateway -> auth-service), not just
# each container's own isolated healthcheck: a passing /health on every
# container doesn't prove gateway can actually route to them.

log "smoke test: GET /health via gateway"
${COMPOSE} exec -T gateway wget -qO- http://localhost:8080/health | grep -q '"status":"ok"' \
  || fail "smoke test failed: gateway /health did not return ok"

log "smoke test: GET /.well-known/jwks.json via gateway (proxied to auth-service)"
JWKS=$(${COMPOSE} exec -T gateway wget -qO- http://localhost:8080/.well-known/jwks.json)
echo "${JWKS}" | jq -e '.keys | length > 0' >/dev/null \
  || fail "smoke test failed: jwks.json via gateway did not return a signing key"

# --- Record this release as the currently deployed one. Only ever
#     reached after every health check and smoke test above passed -
#     `current` always points at a manifest that is actually running. ---

mkdir -p "${RELEASES_DIR}"
MANIFEST_ABS_PATH="$(cd "$(dirname "${MANIFEST_FILE}")" && pwd)/$(basename "${MANIFEST_FILE}")"
ln -sfn "${MANIFEST_ABS_PATH}" "${CURRENT_LINK}"

# --- 17. Success ---

log "deploy of release ${RELEASE} complete (current -> ${MANIFEST_ABS_PATH})"
${COMPOSE} ps
