#!/bin/bash
# Unit tests for deploy/lib/secrets.sh - pure bash, no AWS/Docker calls,
# same shape as test_manifest.sh. Exercises the seven-secret allowlist
# and the presence/non-empty checks deploy.sh relies on to refuse a
# deploy whose production .env is incomplete.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "${TESTS_DIR}")"

# shellcheck source=../lib/secrets.sh
source "${DEPLOY_DIR}/lib/secrets.sh"

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

complete_env() {
  local file="$1"
  cat >"${file}" <<'EOF'
POSTGRES_AUTH_PASSWORD=a
POSTGRES_APIARY_PASSWORD=b
POSTGRES_HIVE_PASSWORD=c
POSTGRES_INSPECTION_PASSWORD=d
POSTGRES_MEDIA_PASSWORD=e
TOTP_ENCRYPTION_KEY=f
JWT_PRIVATE_KEY=g
EOF
}

# --- 1. exactly the seven secrets this task is about ---

EXPECTED_KEYS="POSTGRES_AUTH_PASSWORD POSTGRES_APIARY_PASSWORD POSTGRES_HIVE_PASSWORD POSTGRES_INSPECTION_PASSWORD POSTGRES_MEDIA_PASSWORD TOTP_ENCRYPTION_KEY JWT_PRIVATE_KEY"
ACTUAL_KEYS="${SECRET_KEYS[*]}"
[ "${#SECRET_KEYS[@]}" -eq 7 ] && [ "${ACTUAL_KEYS}" = "${EXPECTED_KEYS}" ]
check "SECRET_KEYS is exactly the seven required production secrets" $([ $? -eq 0 ] && echo 1 || echo 0)

# --- 2. a complete production .env validates cleanly ---

COMPLETE_FILE="${TMP_DIR}/complete.env"
complete_env "${COMPLETE_FILE}"
secrets::validate "${COMPLETE_FILE}" >/dev/null 2>&1
check "a .env with all seven secrets set validates successfully" $([ $? -eq 0 ] && echo 1 || echo 0)

# --- 3. a missing key fails validation and is named in the error ---

MISSING_FILE="${TMP_DIR}/missing.env"
complete_env "${MISSING_FILE}"
grep -v '^JWT_PRIVATE_KEY=' "${MISSING_FILE}" >"${MISSING_FILE}.tmp" && mv "${MISSING_FILE}.tmp" "${MISSING_FILE}"

ERR="$(secrets::validate "${MISSING_FILE}" 2>&1 >/dev/null)"
RC=$?
[ "${RC}" -ne 0 ]
check "a .env missing a key fails validation" $([ $? -eq 0 ] && echo 1 || echo 0)
echo "${ERR}" | grep -q "JWT_PRIVATE_KEY"
check "the validation error names the missing key" $([ $? -eq 0 ] && echo 1 || echo 0)

# --- 4. an empty (but present) key is treated the same as missing ---

EMPTY_FILE="${TMP_DIR}/empty.env"
complete_env "${EMPTY_FILE}"
sed -i.bak 's/^TOTP_ENCRYPTION_KEY=.*/TOTP_ENCRYPTION_KEY=/' "${EMPTY_FILE}"

secrets::validate "${EMPTY_FILE}" >/dev/null 2>&1
check "a .env with an empty-valued secret fails validation" $([ $? -ne 0 ] && echo 1 || echo 0)

# --- 5. a nonexistent file fails validation rather than crashing ---

secrets::validate "${TMP_DIR}/does-not-exist.env" >/dev/null 2>&1
check "a nonexistent .env fails validation cleanly" $([ $? -ne 0 ] && echo 1 || echo 0)

# --- 6. secrets::missing never prints a value, only key names ---

MISSING_OUTPUT="$(secrets::missing "${MISSING_FILE}")"
echo "${MISSING_OUTPUT}" | grep -qF "="
check "secrets::missing output contains no '=' (names only, never values)" $([ $? -ne 0 ] && echo 1 || echo 0)

# --- 7. secrets::is_secret_key recognizes every one of the seven, and
#     rejects an unrelated key (e.g. a non-secret SSM parameter) ---

all_recognized=1
for key in "${SECRET_KEYS[@]}"; do
  secrets::is_secret_key "${key}" || all_recognized=0
done
check "secrets::is_secret_key recognizes all seven secret keys" "${all_recognized}"

secrets::is_secret_key "PUBLIC_DOMAIN"
check "secrets::is_secret_key rejects a non-secret key" $([ $? -ne 0 ] && echo 1 || echo 0)

# --- 8. deploy/.env.example documents all seven keys as empty
#     placeholders - never a real-looking value, and never loaded by
#     anything (see deploy.sh's own ENV_FILE, which is a different path
#     entirely) ---

ENV_EXAMPLE="${DEPLOY_DIR}/.env.example"

[ -f "${ENV_EXAMPLE}" ]
check "deploy/.env.example exists" $([ $? -eq 0 ] && echo 1 || echo 0)

all_present_empty=1
for key in "${SECRET_KEYS[@]}"; do
  grep -qxF "${key}=" "${ENV_EXAMPLE}" || all_present_empty=0
done
check "deploy/.env.example lists all seven secrets as empty placeholders" "${all_present_empty}"

grep -E '^[A-Za-z_][A-Za-z0-9_]*=.+' "${ENV_EXAMPLE}" >/dev/null 2>&1
check "deploy/.env.example assigns no non-empty value to anything" $([ $? -ne 0 ] && echo 1 || echo 0)

echo
echo "secrets.sh unit tests: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
