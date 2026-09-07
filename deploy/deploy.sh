#!/bin/bash
# Deploys one immutable Git-SHA image tag to the BeeBase production
# stack. Invoked on the EC2 host itself, normally via an Azure DevOps
# pipeline's `aws ssm send-command` (AWS-RunShellScript) targeting this
# instance - see the CI pipeline template for the exact invocation.
#
# Assumes docker-compose.prod.yml, this script, and Caddyfile are already
# in place under /opt/beebase (bootstrapped once manually or via a
# dedicated ops update - see the deployment report's manual steps; they
# change rarely, unlike the application images this script deploys on
# every run).
#
# Usage: deploy.sh <git-sha>
set -euo pipefail

COMPOSE_DIR="/opt/beebase/compose"
CONFIG_DIR="/opt/beebase/config"
ENV_FILE="${CONFIG_DIR}/.env"
COMPOSE="docker compose -f ${COMPOSE_DIR}/docker-compose.prod.yml --env-file ${ENV_FILE}"
SSM_PATH="/beebase/prod"

log() { echo "[deploy $(date -u +%H:%M:%S)] $*"; }
fail() { echo "[deploy $(date -u +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

# --- 1. Receive the Git SHA/image tag ---

IMAGE_TAG="${1:-}"
[ -n "${IMAGE_TAG}" ] || fail "usage: deploy.sh <git-sha>"
[ "${IMAGE_TAG}" != "latest" ] || fail "refusing to deploy tag 'latest' - pass a real Git commit SHA"
[[ "${IMAGE_TAG}" =~ ^[0-9a-f]{7,40}$ ]] || fail "IMAGE_TAG '${IMAGE_TAG}' doesn't look like a Git commit SHA"

log "deploying IMAGE_TAG=${IMAGE_TAG}"

# --- Derive account/region-specific values from the instance itself
#     rather than hardcoding them - IMDSv2 token required (metadata_options
#     in Terraform enforces this). ---

IMDS_TOKEN=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
AWS_REGION=$(curl -fsS -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
  http://169.254.169.254/latest/meta-data/placement/region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# --- 2 & 3. Retrieve production secrets/config from SSM Parameter Store,
#     write a fresh 0600 environment file ---
#
# Everything under /beebase/prod - both plain config (PUBLIC_DOMAIN,
# R2_BUCKET, ...) and SecureString secrets (JWT_PRIVATE_KEY,
# POSTGRES_*_PASSWORD, ...) - lives in one path so a single call
# retrieves it all; --with-decryption is a no-op for the plain-String
# parameters and decrypts the SecureString ones.

log "fetching parameters from SSM Parameter Store (${SSM_PATH})"

umask 077
: >"${ENV_FILE}"
{
  echo "ECR_REGISTRY=${ECR_REGISTRY}"
  echo "AWS_REGION=${AWS_REGION}"
  echo "IMAGE_TAG=${IMAGE_TAG}"
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
[ "${PARAM_COUNT}" -gt 3 ] || fail "expected production secrets under ${SSM_PATH}, found none - check SSM Parameter Store setup"

# --- 4. Authenticate to ECR using the EC2 instance role ---

log "authenticating to ECR (${ECR_REGISTRY})"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

# --- 5. Pull the requested immutable images ---

log "pulling images for tag ${IMAGE_TAG}"
${COMPOSE} pull

# --- 6. Run required database migrations ---
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

# --- 7. Start/recreate the production stack ---

log "starting/recreating the full stack"
${COMPOSE} up -d --remove-orphans

# --- 8. Wait for health/readiness checks ---

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

# --- 9. Basic smoke test through the gateway ---
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

# --- 10. Success ---

log "deploy of ${IMAGE_TAG} complete"
${COMPOSE} ps
