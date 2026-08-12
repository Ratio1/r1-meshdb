#!/usr/bin/env bash
set -euo pipefail

if [[ "${TEST_MV_MODE:-}" == "fail" ]]; then
  exit 1
fi

if [[ "${TEST_MV_MODE:-}" == "fail_exhaustion" &&
      "${*: -1}" == */exhausted ]]; then
  exit 1
fi

exec /bin/mv "$@"
