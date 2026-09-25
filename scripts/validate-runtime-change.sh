#!/usr/bin/env bash
set -euo pipefail

base_image="${1:-ghcr.io/ratio1/deeploy-cockroachdb-service:main}"
run_id="$$-${RANDOM}"
test_image="deeploy-crdb-runtime-candidate:${run_id}"

cleanup() {
  local status=$?
  local cleanup_failed=0
  trap - EXIT
  docker image rm -f "${test_image}" >/dev/null 2>&1 || true
  docker image inspect "${test_image}" >/dev/null 2>&1 && cleanup_failed=1
  if [[ "${status}" == "0" && "${cleanup_failed}" != "0" ]]; then
    echo "runtime candidate image cleanup failed" >&2
    status=1
  fi
  exit "${status}"
}
trap cleanup EXIT

docker build \
  --build-arg "BASE_IMAGE=${base_image}" \
  -f tests/runtime-supervision/Dockerfile.production-overlay \
  -t "${test_image}" \
  . >/dev/null

bash scripts/smoke.sh "${test_image}"
timeout --signal=TERM --kill-after=30s 5m \
  bash scripts/sql-tls-transport-smoke.sh "${test_image}"
bash scripts/local-multinode-smoke.sh "${test_image}"
R1_RUNTIME_REQUIRE_EXACT_ENTRYPOINT=false \
  bash scripts/runtime-supervision-smoke.sh "${test_image}" fixed

echo "runtime change validation ok"
