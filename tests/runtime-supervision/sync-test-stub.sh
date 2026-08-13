#!/usr/bin/env bash
set -euo pipefail

if [[ "${TEST_SYNC_MODE:-}" == "fail" ]]; then
  exit 1
fi

if [[ "${TEST_SYNC_MODE:-}" == "fail_exhaustion" ]]; then
  for path in "$@"; do
    if [[ -e "${path}/exhausted" ]]; then
      exit 1
    fi
  done
fi

if [[ "${TEST_SYNC_MODE:-}" == "record_invalid_marker" ]]; then
  for path in "$@"; do
    if [[ "${path}" == */state ]] && grep -Fxq 'invalid' "${path}"; then
      touch /runtime/capture/invalid-marker-synced
    fi
  done
fi

exec /usr/bin/sync "$@"
