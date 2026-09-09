#!/bin/bash
# Unit tests for deploy/lib/env_config.sh - pure bash, no AWS/Docker
# calls, same shape as test_manifest.sh. Exercises the per-service
# required-key lists and the presence/mode/non-empty checks deploy.sh
# relies on to refuse a deploy whose per-service production .env files
# are missing or incomplete.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "${TESTS_DIR}")"

# shellcheck source=../lib/env_config.sh
source "${DEPLOY_DIR}/lib/env_config.sh"

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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# write_complete_config <config-dir>
# Seeds every one of the 7 services' env files, complete and mode 0600.
write_complete_config() {
  local dir="$1"
  mkdir -p "${dir}"

  : >"${dir}/gateway.env"
  cat >"${dir}/auth.env" <<'EOF'
POSTGRES_AUTH_PASSWORD=auth-pw
JWT_PRIVATE_KEY=jwt-key
TOTP_ENCRYPTION_KEY=totp-key
EOF
  echo "POSTGRES_APIARY_PASSWORD=apiary-pw" >"${dir}/apiary.env"
  echo "POSTGRES_HIVE_PASSWORD=hive-pw" >"${dir}/hive.env"
  echo "POSTGRES_INSPECTION_PASSWORD=inspection-pw" >"${dir}/inspection.env"
  cat >"${dir}/media.env" <<'EOF'
POSTGRES_MEDIA_PASSWORD=media-pw
STORAGE_BUCKET=beebase-prod
EOF
  : >"${dir}/statistics.env"
  echo "POSTGRES_SUBSCRIPTION_PASSWORD=subscription-pw" >"${dir}/subscription.env"

  chmod 600 "${dir}"/*.env
}

# --- 1. the 8 services and their file names ---

EXPECTED_SERVICES="gateway auth apiary hive inspection media statistics subscription"
check "ENV_SERVICES is exactly the 8 BeeBase services" \
  $([ "${ENV_SERVICES[*]}" = "${EXPECTED_SERVICES}" ] && echo 1 || echo 0)

declare -A expected_names=(
  [gateway]=gateway.env
  [auth]=auth.env
  [apiary]=apiary.env
  [hive]=hive.env
  [inspection]=inspection.env
  [media]=media.env
  [statistics]=statistics.env
  [subscription]=subscription.env
)
all_names_ok=1
for service in "${ENV_SERVICES[@]}"; do
  [ "${ENV_FILE_NAME[${service}]}" = "${expected_names[${service}]}" ] || all_names_ok=0
done
check "each service maps to <service>.env exactly" "${all_names_ok}"

# --- 2. required-key ownership matches the deployment report's mapping:
#     each service owns its own DB password; JWT/TOTP stay with auth;
#     storage stays with media; gateway/statistics need none ---

check "auth requires POSTGRES_AUTH_PASSWORD, JWT_PRIVATE_KEY and TOTP_ENCRYPTION_KEY" \
  $([ "${ENV_REQUIRED_KEYS[auth]}" = "POSTGRES_AUTH_PASSWORD JWT_PRIVATE_KEY TOTP_ENCRYPTION_KEY" ] && echo 1 || echo 0)
check "apiary requires only POSTGRES_APIARY_PASSWORD" \
  $([ "${ENV_REQUIRED_KEYS[apiary]}" = "POSTGRES_APIARY_PASSWORD" ] && echo 1 || echo 0)
check "hive requires only POSTGRES_HIVE_PASSWORD" \
  $([ "${ENV_REQUIRED_KEYS[hive]}" = "POSTGRES_HIVE_PASSWORD" ] && echo 1 || echo 0)
check "inspection requires only POSTGRES_INSPECTION_PASSWORD" \
  $([ "${ENV_REQUIRED_KEYS[inspection]}" = "POSTGRES_INSPECTION_PASSWORD" ] && echo 1 || echo 0)
check "media requires POSTGRES_MEDIA_PASSWORD and STORAGE_BUCKET" \
  $([ "${ENV_REQUIRED_KEYS[media]}" = "POSTGRES_MEDIA_PASSWORD STORAGE_BUCKET" ] && echo 1 || echo 0)
check "gateway requires no production secret" \
  $([ -z "${ENV_REQUIRED_KEYS[gateway]}" ] && echo 1 || echo 0)
check "statistics requires no production secret" \
  $([ -z "${ENV_REQUIRED_KEYS[statistics]}" ] && echo 1 || echo 0)
check "subscription requires only POSTGRES_SUBSCRIPTION_PASSWORD" \
  $([ "${ENV_REQUIRED_KEYS[subscription]}" = "POSTGRES_SUBSCRIPTION_PASSWORD" ] && echo 1 || echo 0)

# --- 3. a complete, correctly-permissioned config directory validates
#     cleanly, service by service and all at once ---

COMPLETE_DIR="${TMP_DIR}/complete"
write_complete_config "${COMPLETE_DIR}"

all_services_ok=1
for service in "${ENV_SERVICES[@]}"; do
  env_config_validate_service "${COMPLETE_DIR}" "${service}" >/dev/null 2>&1 || all_services_ok=0
done
check "every one of the 8 services validates individually when complete" "${all_services_ok}"

env_config_validate_all "${COMPLETE_DIR}" >/dev/null 2>&1
check "env_config_validate_all succeeds when every service's .env is complete" $([ $? -eq 0 ] && echo 1 || echo 0)

# --- 4. a missing service .env file fails validation and names the file ---

MISSING_FILE_DIR="${TMP_DIR}/missing-file"
write_complete_config "${MISSING_FILE_DIR}"
rm "${MISSING_FILE_DIR}/hive.env"

ERR="$(env_config_validate_service "${MISSING_FILE_DIR}" "hive" 2>&1 >/dev/null)"
RC=$?
check "a missing service .env file fails validation" $([ "${RC}" -ne 0 ] && echo 1 || echo 0)
echo "${ERR}" | grep -q "hive.env"
check "the validation error names the missing file" $([ $? -eq 0 ] && echo 1 || echo 0)

env_config_validate_all "${MISSING_FILE_DIR}" >/dev/null 2>&1
check "env_config_validate_all fails when any single service's file is missing" $([ $? -ne 0 ] && echo 1 || echo 0)

# --- 5. a missing required key fails validation and names the key, for
#     the service that actually owns it ---

MISSING_KEY_DIR="${TMP_DIR}/missing-key"
write_complete_config "${MISSING_KEY_DIR}"
grep -v '^JWT_PRIVATE_KEY=' "${MISSING_KEY_DIR}/auth.env" >"${MISSING_KEY_DIR}/auth.env.tmp"
mv "${MISSING_KEY_DIR}/auth.env.tmp" "${MISSING_KEY_DIR}/auth.env"
chmod 600 "${MISSING_KEY_DIR}/auth.env"

ERR="$(env_config_validate_service "${MISSING_KEY_DIR}" "auth" 2>&1 >/dev/null)"
RC=$?
check "auth.env missing JWT_PRIVATE_KEY fails validation" $([ "${RC}" -ne 0 ] && echo 1 || echo 0)
echo "${ERR}" | grep -q "JWT_PRIVATE_KEY"
check "the validation error names the missing key" $([ $? -eq 0 ] && echo 1 || echo 0)

# A sibling service missing an unrelated key must never fail because of
# auth's problem - each service is validated independently.
env_config_validate_service "${MISSING_KEY_DIR}" "apiary" >/dev/null 2>&1
check "a sibling service with its own complete .env still validates" $([ $? -eq 0 ] && echo 1 || echo 0)

# --- 6. an empty (but present) required key is treated the same as
#     missing ---

EMPTY_KEY_DIR="${TMP_DIR}/empty-key"
write_complete_config "${EMPTY_KEY_DIR}"
sed -i.bak 's/^STORAGE_BUCKET=.*/STORAGE_BUCKET=/' "${EMPTY_KEY_DIR}/media.env"
chmod 600 "${EMPTY_KEY_DIR}/media.env"

env_config_validate_service "${EMPTY_KEY_DIR}" "media" >/dev/null 2>&1
check "an empty-valued required key fails validation" $([ $? -ne 0 ] && echo 1 || echo 0)

# --- 7. wrong file permissions fail validation, even with every key
#     present and correct ---

BAD_MODE_DIR="${TMP_DIR}/bad-mode"
write_complete_config "${BAD_MODE_DIR}"
chmod 644 "${BAD_MODE_DIR}/apiary.env"

ERR="$(env_config_validate_service "${BAD_MODE_DIR}" "apiary" 2>&1 >/dev/null)"
RC=$?
check "a service .env with mode 644 fails validation" $([ "${RC}" -ne 0 ] && echo 1 || echo 0)
echo "${ERR}" | grep -q "0600"
check "the permission-mode error mentions the required 0600" $([ $? -eq 0 ] && echo 1 || echo 0)

# --- 8. env_config_missing_required and validate_service never print a
#     secret's value, only key names ---

MISSING_OUTPUT="$(env_config_missing_required "${MISSING_KEY_DIR}/auth.env" "auth")"
echo "${MISSING_OUTPUT}" | grep -qF "="
check "env_config_missing_required output contains no '=' (names only, never values)" $([ $? -ne 0 ] && echo 1 || echo 0)

if env_config_validate_service "${COMPLETE_DIR}" "auth" 2>&1 >/dev/null | grep -qF "jwt-key"; then
  check "env_config_validate_service never echoes a secret's value" 0
else
  check "env_config_validate_service never echoes a secret's value" 1
fi

# --- 9. env_config_is_secret_key recognizes each service's own
#     required keys, and rejects a key that service doesn't own ---

all_recognized=1
for key in ${ENV_REQUIRED_KEYS[auth]}; do
  env_config_is_secret_key "auth" "${key}" || all_recognized=0
done
check "env_config_is_secret_key recognizes all of auth's required keys" "${all_recognized}"

env_config_is_secret_key "auth" "STORAGE_BUCKET"
check "env_config_is_secret_key rejects a key auth doesn't own (media's STORAGE_BUCKET)" $([ $? -ne 0 ] && echo 1 || echo 0)

env_config_is_secret_key "gateway" "PUBLIC_DOMAIN"
check "env_config_is_secret_key rejects a non-secret, non-owned key" $([ $? -ne 0 ] && echo 1 || echo 0)

# --- 10. ENV_DB_INTERPOLATION_KEY covers exactly the 5 database-owning
#     services, mapping each to its own compose-interpolation variable
#     name - see docker-compose.prod.yml's header comment for why this
#     mirroring exists at all ---

declare -A expected_interp=(
  [auth]=POSTGRES_AUTH_PASSWORD
  [apiary]=POSTGRES_APIARY_PASSWORD
  [hive]=POSTGRES_HIVE_PASSWORD
  [inspection]=POSTGRES_INSPECTION_PASSWORD
  [media]=POSTGRES_MEDIA_PASSWORD
  [subscription]=POSTGRES_SUBSCRIPTION_PASSWORD
)
interp_ok=1
[ "${#ENV_DB_INTERPOLATION_KEY[@]}" -eq 6 ] || interp_ok=0
for service in "${!expected_interp[@]}"; do
  [ "${ENV_DB_INTERPOLATION_KEY[${service}]}" = "${expected_interp[${service}]}" ] || interp_ok=0
done
check "ENV_DB_INTERPOLATION_KEY covers exactly the 6 DB-owning services with the right names" "${interp_ok}"

# --- 11. every deploy/env-templates/*.env.example matches
#     ENV_TEMPLATE_NAME and never contains a non-empty value for a
#     required key (placeholders only) ---

all_templates_ok=1
for service in "${ENV_SERVICES[@]}"; do
  template="${DEPLOY_DIR}/env-templates/${ENV_TEMPLATE_NAME[${service}]}"
  [ -f "${template}" ] || { all_templates_ok=0; echo "missing template: ${template}"; continue; }

  for key in ${ENV_REQUIRED_KEYS[${service}]}; do
    grep -qxF "${key}=" "${template}" || { all_templates_ok=0; echo "template ${template} does not list ${key}= as an empty placeholder"; }
  done

  grep -E '^[A-Za-z_][A-Za-z0-9_]*=.+' "${template}" >/dev/null 2>&1 && {
    all_templates_ok=0
    echo "template ${template} assigns a non-empty value to something"
  }
done
check "every service's env-template exists, lists its required keys, and assigns nothing" "${all_templates_ok}"

echo
echo "env_config.sh unit tests: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
