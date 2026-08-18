#!/usr/bin/env bash
# Copyright 2026 Ratio1
# Licensed under the Apache License, Version 2.0. See LICENSE.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${1:?usage: testbed/run-local-cluster.sh <image-ref>}"
run_id="r1-meshdb-local-$$-${RANDOM}"
transport_image="r1-meshdb-local-transport:${run_id}"

cleanup() {
  local status=$?
  trap - EXIT
  docker image rm -f "${transport_image}" >/dev/null 2>&1 || true
  if docker image inspect "${transport_image}" >/dev/null 2>&1; then
    echo "local transport image cleanup failed" >&2
    status=1
  fi
  exit "${status}"
}
trap cleanup EXIT

require_digest="${R1_MESHDB_REQUIRE_DIGEST:-${R1_SQL_REQUIRE_DIGEST:-true}}"
if [[ "${require_digest}" == "true" && "${image}" != *@sha256:* ]]; then
  echo "local release-candidate validation requires an immutable image digest" >&2
  exit 1
fi

docker image inspect "${image}" >/dev/null
bash "${root}/scripts/direct-engine-three-node-smoke.sh" "${image}" "${run_id}"

base_binary_hash="$(docker run --rm --entrypoint sha256sum "${image}" /cockroach/cockroach | awk '{print $1}')"
base_entrypoint_hash="$(docker run --rm --entrypoint sha256sum "${image}" /usr/local/bin/deeploy-crdb-entrypoint | awk '{print $1}')"
docker build \
  --build-arg "BASE_IMAGE=${image}" \
  --file "${root}/tests/local-transport/Dockerfile" \
  --tag "${transport_image}" \
  "${root}" >/dev/null
test_binary_hash="$(docker run --rm --entrypoint sha256sum "${transport_image}" /cockroach/cockroach | awk '{print $1}')"
test_entrypoint_hash="$(docker run --rm --entrypoint sha256sum "${transport_image}" /usr/local/bin/deeploy-crdb-entrypoint | awk '{print $1}')"
[[ "${test_binary_hash}" == "${base_binary_hash}" ]] || { echo "transport overlay changed the database binary" >&2; exit 1; }
[[ "${test_entrypoint_hash}" == "${base_entrypoint_hash}" ]] || { echo "transport overlay changed the production entrypoint" >&2; exit 1; }

CRDB_TEST_MAX_OFFSET=500ms \
  bash "${root}/scripts/entrypoint-multinode-smoke.sh" "${transport_image}" "${run_id}"
