#!/usr/bin/env bash
set -euo pipefail

if [[ "${TEST_DF_MODE:-}" == "block" ]]; then
  trap '' TERM INT
  while true; do
    sleep 1
  done
fi

if [[ -n "${TEST_DF_USED_KB:-}" && -n "${TEST_DF_AVAILABLE_KB:-}" && " $* " == *" -Pk "* ]]; then
  total_kb=$((TEST_DF_USED_KB + TEST_DF_AVAILABLE_KB))
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
  printf 'fixture %s %s %s 25%% /fixture\n' "${total_kb}" "${TEST_DF_USED_KB}" "${TEST_DF_AVAILABLE_KB}"
  exit 0
fi

if [[ -n "${TEST_DF_USED_INODES:-}" && -n "${TEST_DF_AVAILABLE_INODES:-}" && " $* " == *" -Pi "* ]]; then
  total_inodes=$((TEST_DF_USED_INODES + TEST_DF_AVAILABLE_INODES))
  printf 'Filesystem Inodes IUsed IFree IUse%% Mounted on\n'
  printf 'fixture %s %s %s 25%% /fixture\n' "${total_inodes}" "${TEST_DF_USED_INODES}" "${TEST_DF_AVAILABLE_INODES}"
  exit 0
fi

exec /bin/df "$@"
