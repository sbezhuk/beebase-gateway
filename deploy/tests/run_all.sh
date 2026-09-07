#!/bin/bash
# Runs every deploy/ test suite. See `make deploy-test` in the repo
# Makefile.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

overall_rc=0
for suite in test_manifest.sh test_compose_config.sh test_deploy_integration.sh; do
  echo "=== ${suite} ==="
  bash "${TESTS_DIR}/${suite}"
  rc=$?
  [ "${rc}" -eq 0 ] || overall_rc=1
  echo
done

exit "${overall_rc}"
