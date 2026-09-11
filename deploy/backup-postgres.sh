#!/bin/bash
# Daily logical backup of all 7 BeeBase databases: pg_dump each, gzip,
# stream straight to S3 (never landing on local disk, so backups are
# never stored only on the EC2 instance). Runs via a systemd timer - see
# beebase-backup.timer/.service, installed once alongside deploy.sh.
#
# pg_dump runs inside each already-running postgres container via
# `docker compose exec`, authenticating over the container's local Unix
# socket (trusted for the container's own `beebase` role) - no database
# password needs to be known by this script.
set -euo pipefail

COMPOSE_DIR="/opt/beebase/compose"
CONFIG_DIR="/opt/beebase/config"
ENV_FILE="${CONFIG_DIR}/.env"
COMPOSE="docker compose -f ${COMPOSE_DIR}/docker-compose.prod.yml --env-file ${ENV_FILE}"

log() { echo "[backup $(date -u +%H:%M:%S)] $*"; }
fail() { echo "[backup $(date -u +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

[ -f "${ENV_FILE}" ] || fail "${ENV_FILE} not found - has deploy.sh ever run successfully?"

S3_BACKUP_BUCKET=$(grep -m1 '^STORAGE_BUCKET=' "${ENV_FILE}" | cut -d= -f2-)
[ -n "${S3_BACKUP_BUCKET}" ] || fail "STORAGE_BUCKET not set in ${ENV_FILE} (check SSM Parameter Store)"

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
FAILURES=0

# service -> database name
declare -A DATABASES=(
  [postgres-auth]=beebase_auth
  [postgres-apiary]=beebase_apiary
  [postgres-hive]=beebase_hive
  [postgres-inspection]=beebase_inspection
  [postgres-harvest]=beebase_harvest
  [postgres-media]=beebase_media
  [postgres-subscription]=beebase_subscription
)

for svc in "${!DATABASES[@]}"; do
  db="${DATABASES[$svc]}"
  dest="s3://${S3_BACKUP_BUCKET}/postgres/${db}/${TIMESTAMP}.sql.gz"
  log "dumping ${db} (via ${svc}) -> ${dest}"

  # --expected-size is only needed above 50GB (AWS CLI default assumption
  # for a size-less stream) - nowhere near this deployment's dump sizes.
  if ${COMPOSE} exec -T "${svc}" pg_dump -U beebase "${db}" \
      | gzip \
      | aws s3 cp - "${dest}"; then
    log "ok: ${db}"
  else
    echo "[backup $(date -u +%H:%M:%S)] ERROR: backup failed for ${db}" >&2
    FAILURES=$((FAILURES + 1))
  fi
done

if [ "${FAILURES}" -gt 0 ]; then
  fail "${FAILURES} of 7 database backups failed"
fi

log "all 7 database backups completed successfully"
