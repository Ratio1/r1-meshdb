#!/usr/bin/env bash
# Copyright 2026 Ratio1
# Licensed under the Apache License, Version 2.0. See LICENSE.

set -euo pipefail

if [[ "${TEST_ATOMIC_REPLACE_MODE:-}" == "fail" ]]; then
  exit 1
fi

if [[ "${TEST_ATOMIC_REPLACE_MODE:-}" == "fail_exhaustion" &&
      "${2:-}" == */exhausted ]]; then
  exit 1
fi

exec /usr/local/bin/r1-atomic-replace-real "$1" "$2"
