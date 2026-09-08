# Defines the production secrets that must come exclusively from the
# production `.env` file (${BEEBASE_CONFIG_DIR:-/opt/beebase/config}/.env)
# and never from AWS SSM Parameter Store, a release manifest, a Docker
# image, or any file in this repository. See deploy/deploy.sh and this
# repo's README.md ("Secrets, images, 'no latest'") for the full picture.
#
# Pure bash, no AWS/Docker calls - deliberately, so it can be unit-tested
# on its own (see deploy/tests/test_secrets.sh) the same way
# lib/manifest.sh is.

SECRET_KEYS=(
  POSTGRES_AUTH_PASSWORD
  POSTGRES_APIARY_PASSWORD
  POSTGRES_HIVE_PASSWORD
  POSTGRES_INSPECTION_PASSWORD
  POSTGRES_MEDIA_PASSWORD
  TOTP_ENCRYPTION_KEY
  JWT_PRIVATE_KEY
)

# secrets::missing <env-file>
# Prints (one per line, names only - never values) any of SECRET_KEYS
# that are absent or empty in <env-file>. Prints nothing and returns 0
# when every key is present and non-empty; returns 1 if the file itself
# can't be read.
secrets::missing() {
  local file="$1" key value found rc=0

  if [ ! -f "${file}" ] || [ ! -r "${file}" ]; then
    printf '%s\n' "${SECRET_KEYS[@]}"
    return 1
  fi

  for key in "${SECRET_KEYS[@]}"; do
    value="$(secrets::read_value "${file}" "${key}")"
    found="$?"

    if [ "${found}" -ne 0 ] || [ -z "${value}" ]; then
      echo "${key}"
      rc=1
    fi
  done

  return "${rc}"
}

# secrets::validate <env-file>
# Same check as secrets::missing, but reports failures to stderr with
# context (never the values themselves) instead of just listing names.
secrets::validate() {
  local file="$1" missing

  missing="$(secrets::missing "${file}")" || true

  if [ -n "${missing}" ]; then
    local key
    echo "secrets: '${file}' is missing required production secrets:" >&2
    while IFS= read -r key; do
      echo "  - ${key}" >&2
    done <<<"${missing}"
    return 1
  fi

  return 0
}

# secrets::read_value <env-file> <key>
# Prints the last-assigned value of <key> in a KEY=VALUE file (a later
# line wins, matching how the shell/Docker Compose treat repeated
# assignments), empty string with a non-zero return if the key is absent
# entirely. Only reads - never logs - the value; callers must take care
# never to echo the result anywhere but into another env file.
secrets::read_value() {
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

# secrets::is_secret_key <key>
# True (rc 0) if <key> is one of SECRET_KEYS - used by deploy.sh to
# defensively strip these names out of anything it ever pulls from SSM,
# even if a stale parameter is still sitting there.
secrets::is_secret_key() {
  local key="$1" candidate

  for candidate in "${SECRET_KEYS[@]}"; do
    [ "${candidate}" = "${key}" ] && return 0
  done

  return 1
}
