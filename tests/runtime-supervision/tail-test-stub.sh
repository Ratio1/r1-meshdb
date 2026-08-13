#!/usr/bin/env bash
set -euo pipefail

record_block_timestamp() {
  local path="${1:-}"
  local uptime
  [[ -n "${path}" ]] || return 0
  read -r uptime _ < /proc/uptime
  umask 022
  printf '%s\n' "${uptime}" > "${path}"
  chmod 644 "${path}"
}

if [[ "${TEST_TAIL_MODE:-}" == "block_run_log" &&
      " $* " == *"/logs/deeploy-run."* ]]; then
  touch /runtime/capture/tail-blocked
  record_block_timestamp "${TEST_TAIL_BLOCK_STARTED_FILE:-}"
  trap 'record_block_timestamp "${TEST_TAIL_BLOCK_TERM_FILE:-}"' TERM INT
  while true; do
    sleep 1
  done
fi

if [[ "${TEST_TAIL_MODE:-}" == "block_current_run" &&
      -e /runtime/capture/current-corruption-log-ready &&
      " $* " == *"/logs/deeploy-run."* ]]; then
  touch /runtime/capture/tail-blocked
  record_block_timestamp "${TEST_TAIL_BLOCK_STARTED_FILE:-}"
  trap 'record_block_timestamp "${TEST_TAIL_BLOCK_TERM_FILE:-}"' TERM INT
  while true; do
    sleep 1
  done
fi

if [[ "${TEST_TAIL_MODE:-}" == "fail_run_log" &&
      " $* " == *"/logs/deeploy-run."* ]]; then
  exit 1
fi

exec /usr/bin/tail "$@"
