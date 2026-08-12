#!/usr/bin/env bash
set -euo pipefail

if [[ "${TEST_TAIL_MODE:-}" == "block_run_log" &&
      " $* " == *"/logs/deeploy-run."* ]]; then
  touch /runtime/capture/tail-blocked
  trap '' TERM INT
  while true; do
    sleep 1
  done
fi

if [[ "${TEST_TAIL_MODE:-}" == "block_current_run" &&
      -e /runtime/capture/current-corruption-log-ready &&
      " $* " == *"/logs/deeploy-run."* ]]; then
  touch /runtime/capture/tail-blocked
  trap '' TERM INT
  while true; do
    sleep 1
  done
fi

if [[ "${TEST_TAIL_MODE:-}" == "fail_run_log" &&
      " $* " == *"/logs/deeploy-run."* ]]; then
  exit 1
fi

exec /usr/bin/tail "$@"
