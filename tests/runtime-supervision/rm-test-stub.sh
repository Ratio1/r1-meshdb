#!/usr/bin/env bash
set -euo pipefail

if [[ "${TEST_RM_MODE:-}" == "fail_once_run_log" &&
      " $* " == *" /cockroach/cockroach-data/logs/deeploy-run."* &&
      ! -e /runtime/capture/rm-failed-once ]]; then
  touch /runtime/capture/rm-failed-once
  exit 1
fi

if [[ "${TEST_RM_MODE:-}" == "fail_once_secret_temp" &&
      " $* " == *"/tmp/deeploy-crdb-bootstrap."*".sql"* &&
      ! -e /tmp/test-rm-secret-failed-once ]]; then
  touch /tmp/test-rm-secret-failed-once
  exit 1
fi

exec /usr/bin/rm "$@"
