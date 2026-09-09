# Per-service production `.env` file names and the variables each one
# must supply before deploy.sh will touch the running stack. Replaces
# the old single-file lib/secrets.sh now that every one of the 7
# BeeBase services owns its own production `.env` under
# ${BEEBASE_CONFIG_DIR:-/opt/beebase/config}/ - see
# docker-compose.prod.yml's header comment and README's "Secrets,
# images, 'no latest'" section for the full picture.
#
# Each required-key list mirrors, per service:
#   1. that service's own .env.example (../<service-repo>/.env.example)
#   2. that service's internal/config Load() required-field checks
#   3. what docker-compose.prod.yml's env_file:-sourced keys need, on
#      top of what it already supplies via `environment:` (network
#      topology and other non-secret, compose-owned values never belong
#      here - see ENV_REQUIRED_KEYS below and requirement 11 in the
#      deployment report).
#
# Pure bash, no AWS/Docker calls - unit-tested on its own (see
# deploy/tests/test_env_config.sh), the same way lib/manifest.sh is.

ENV_SERVICES=(gateway auth apiary hive inspection media statistics subscription)

# Production env file name for each service, relative to
# ${BEEBASE_CONFIG_DIR:-/opt/beebase/config}/ - matches
# docker-compose.prod.yml's env_file: entries exactly.
declare -gA ENV_FILE_NAME=(
  [gateway]=gateway.env
  [auth]=auth.env
  [apiary]=apiary.env
  [hive]=hive.env
  [inspection]=inspection.env
  [media]=media.env
  [statistics]=statistics.env
  [subscription]=subscription.env
)

# The template an operator provisions that service's real file from.
declare -gA ENV_TEMPLATE_NAME=(
  [gateway]=gateway.env.example
  [auth]=auth.env.example
  [apiary]=apiary.env.example
  [hive]=hive.env.example
  [inspection]=inspection.env.example
  [media]=media.env.example
  [statistics]=statistics.env.example
  [subscription]=subscription.env.example
)

# Keys an operator must set directly in that service's own .env before
# deploy.sh will deploy - every one of these is, by definition, also a
# secret (see env_config_is_secret_key) and must never be logged.
# gateway and statistics-service currently need none: every variable
# they read is either optional or supplied by docker-compose.prod.yml's
# `environment:` block (network topology owned by compose - see
# requirement 11). Both still get their own (near-empty) file so the
# architecture stays uniform and ready for a future secret.
declare -gA ENV_REQUIRED_KEYS=(
  [gateway]=""
  [auth]="POSTGRES_AUTH_PASSWORD JWT_PRIVATE_KEY TOTP_ENCRYPTION_KEY"
  [apiary]="POSTGRES_APIARY_PASSWORD"
  [hive]="POSTGRES_HIVE_PASSWORD"
  [inspection]="POSTGRES_INSPECTION_PASSWORD"
  [media]="POSTGRES_MEDIA_PASSWORD STORAGE_BUCKET"
  [statistics]=""
  [subscription]="POSTGRES_SUBSCRIPTION_PASSWORD"
)

# Services whose POSTGRES_PASSWORD deploy.sh must also mirror - by key
# name only, value never logged - into the deploy-generated
# .../config/deploy.env. This is the one place Compose still resolves a
# secret via top-level `--env-file` interpolation (${VAR} syntax)
# instead of `env_file:`: the postgres-* container's own POSTGRES_PASSWORD
# and the migrate-* job's `-database=...` command argument are both
# resolved by Compose itself at compose-file-parse time, which can only
# ever read from the single --env-file - it cannot reach into another
# service's env_file: contents (those are only ever injected straight
# into that one container's runtime environment). See
# docker-compose.prod.yml's header comment for the full explanation.
# deploy.env is regenerated from these authoritative per-service files
# on every deploy; it is never operator-edited and is not a second
# source of truth.
declare -gA ENV_DB_INTERPOLATION_KEY=(
  [auth]=POSTGRES_AUTH_PASSWORD
  [apiary]=POSTGRES_APIARY_PASSWORD
  [hive]=POSTGRES_HIVE_PASSWORD
  [inspection]=POSTGRES_INSPECTION_PASSWORD
  [media]=POSTGRES_MEDIA_PASSWORD
  [subscription]=POSTGRES_SUBSCRIPTION_PASSWORD
)

# env_config_file_path <config-dir> <service>
env_config_file_path() {
  printf '%s/%s' "$1" "${ENV_FILE_NAME[$2]}"
}

# env_config_read_value <file> <key>
# Same contract as the old secrets::read_value: prints the last-assigned
# value of <key> in a KEY=VALUE file (a later line wins), empty string
# with a non-zero return if the key is absent entirely. Only reads -
# never logs - the value.
env_config_read_value() {
  local file="$1" key="$2" line value found=1

  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%$'\r'}"
    case "${line}" in
      "${key}="*)
        value="${line#"${key}"=}"
        found=0
        ;;
    esac
  done <"${file}"

  printf '%s' "${value-}"
  return "${found}"
}

# env_config_missing_required <file> <service>
# Prints (one per line, names only - never values) any required key for
# <service> that's absent or empty in <file>. Prints nothing and returns
# 0 when every required key is present and non-empty (including when
# <service> requires none at all); returns 1 if the file can't be read
# or if any key is missing/empty.
env_config_missing_required() {
  local file="$1" service="$2" key value found rc=0

  if [ ! -f "${file}" ] || [ ! -r "${file}" ]; then
    for key in ${ENV_REQUIRED_KEYS[${service}]}; do
      echo "${key}"
    done
    [ -z "${ENV_REQUIRED_KEYS[${service}]}" ] && return 0
    return 1
  fi

  for key in ${ENV_REQUIRED_KEYS[${service}]}; do
    value="$(env_config_read_value "${file}" "${key}")"
    found="$?"

    if [ "${found}" -ne 0 ] || [ -z "${value}" ]; then
      echo "${key}"
      rc=1
    fi
  done

  return "${rc}"
}

# env_config_is_secret_key <service> <key>
# True (rc 0) if <key> is one of <service>'s required keys - used to
# keep a secret's value out of anything ever logged or copied around.
env_config_is_secret_key() {
  local service="$1" key="$2" candidate

  for candidate in ${ENV_REQUIRED_KEYS[${service}]}; do
    [ "${candidate}" = "${key}" ] && return 0
  done

  return 1
}

# env_config_file_mode <file> - prints the file's permission bits
# (e.g. "600"), portably across BSD/macOS and GNU stat.
env_config_file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%OLp' "$1" 2>/dev/null
}

# env_config_validate_service <config-dir> <service>
# Checks one service's env file exists, is mode 0600, and has every
# required key set to a non-empty value. Reports failures to stderr by
# name only, never by value.
env_config_validate_service() {
  local config_dir="$1" service="$2"
  local file mode missing key

  file="$(env_config_file_path "${config_dir}" "${service}")"

  if [ ! -f "${file}" ]; then
    echo "env_config: '${file}' does not exist - provision it before deploying (cp deploy/env-templates/${ENV_TEMPLATE_NAME[${service}]} '${file}' && chmod 600 '${file}')" >&2
    return 1
  fi

  mode="$(env_config_file_mode "${file}")"
  if [ "${mode}" != "600" ]; then
    echo "env_config: '${file}' has mode ${mode:-unknown}, expected 0600 (chmod 600 '${file}')" >&2
    return 1
  fi

  missing="$(env_config_missing_required "${file}" "${service}")" || true

  if [ -n "${missing}" ]; then
    echo "env_config: '${file}' is missing required variables:" >&2
    while IFS= read -r key; do
      echo "  - ${key}" >&2
    done <<<"${missing}"
    return 1
  fi

  return 0
}

# env_config_validate_all <config-dir>
# Validates every one of the 7 services' env files, reporting every
# failure (not just the first) so an operator sees the complete picture
# in one pass. Returns non-zero if any service failed validation.
env_config_validate_all() {
  local config_dir="$1" service rc=0

  for service in "${ENV_SERVICES[@]}"; do
    env_config_validate_service "${config_dir}" "${service}" || rc=1
  done

  return "${rc}"
}
