#!/usr/bin/env bash
set -euo pipefail

if [[ "${TEST_FIND_MODE:-}" == "fail_run_log" &&
      " $* " == *"/logs"* ]]; then
  exit 1
fi

exec /usr/bin/find "$@"
