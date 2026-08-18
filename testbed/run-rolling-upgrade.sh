#!/usr/bin/env bash
# Copyright 2026 Ratio1
# Licensed under the Apache License, Version 2.0. See LICENSE.

set -euo pipefail
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
candidate_image="${1:?usage: testbed/run-rolling-upgrade.sh <candidate-image> [legacy-image]}"
legacy_image="${2:-ghcr.io/ratio1/deeploy-cockroachdb-service@sha256:a2ca8a245d7c033a0469a65728351f293191e7ecbc3451083e51471a555fdd11}"
require_digest="${R1_MESHDB_REQUIRE_DIGEST:-${R1_SQL_REQUIRE_DIGEST:-true}}"
if [[ "${require_digest}" == "true" && "${candidate_image}" != *@sha256:* ]]; then
  echo "rolling release validation requires an immutable candidate digest" >&2
  exit 1
fi
[[ "${legacy_image}" == *@sha256:* ]] || { echo "legacy rollback image must use an immutable digest" >&2; exit 1; }

run_id="r1-meshdb-rolling-$$-${RANDOM}"
network="${run_id}"
legacy_overlay="r1-meshdb-legacy-transport:${run_id}"
candidate_overlay="r1-meshdb-candidate-transport:${run_id}"
nodes=("${run_id}-1" "${run_id}-2" "${run_id}-3")
tmp="$(mktemp -d /tmp/r1-meshdb-rolling.XXXXXXXX)"
certs_dir="${tmp}/certs"
stores=("${run_id}-store-1" "${run_id}-store-2" "${run_id}-store-3")
token_file="${tmp}/cf-token"
db_password="r1_rolling_validation_password"
child_password="r1_rolling_child_password"
evidence_dir="${R1_MESHDB_EVIDENCE_DIR:-${R1_SQL_EVIDENCE_DIR:-}}"
cleanup_started=false

record_evidence() {
  local status="$1"
  [[ -n "${evidence_dir}" ]] || return 0
  mkdir -p "${evidence_dir}"
  chmod 700 "${evidence_dir}"
  {
    printf 'status=%s\n' "${status}"
    printf 'candidate=%s\n' "${candidate_image}"
    printf 'legacy=%s\n' "${legacy_image}"
  } > "${evidence_dir}/summary.txt"
  for index in 1 2 3; do
    raw="${tmp}/node-${index}.raw.log"
    docker logs "${nodes[$((index - 1))]}" > "${raw}" 2>&1 || true
    python3 - "${raw}" "${evidence_dir}/node-${index}.log" <<'PY'
from pathlib import Path
import sys

logs = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
for secret in (
  "r1_rolling_validation_password",
  "r1_rolling_child_password",
  "r1-rolling-fake-token",
):
  logs = logs.replace(secret, "[redacted]")
Path(sys.argv[2]).write_text(logs, encoding="utf-8")
PY
    rm -f "${raw}"
  done
}

cleanup() {
  local status="${1:-$?}"
  local cleanup_failed=0
  [[ "${cleanup_started}" == "false" ]] || return
  cleanup_started=true
  trap - EXIT INT TERM
  record_evidence "${status}" || cleanup_failed=1
  for node in "${nodes[@]}"; do
    docker rm -f "${node}" >/dev/null 2>&1 || true
    docker inspect "${node}" >/dev/null 2>&1 && cleanup_failed=1
  done
  docker volume rm -f "${stores[@]}" >/dev/null 2>&1 || true
  for store in "${stores[@]}"; do
    docker volume inspect "${store}" >/dev/null 2>&1 && cleanup_failed=1
  done
  docker network rm "${network}" >/dev/null 2>&1 || true
  docker network inspect "${network}" >/dev/null 2>&1 && cleanup_failed=1
  docker image rm -f "${legacy_overlay}" "${candidate_overlay}" >/dev/null 2>&1 || true
  docker image inspect "${legacy_overlay}" >/dev/null 2>&1 && cleanup_failed=1
  docker image inspect "${candidate_overlay}" >/dev/null 2>&1 && cleanup_failed=1
  if docker image inspect "${candidate_image}" >/dev/null 2>&1; then
    docker run --rm --volume "${tmp}:/cleanup" --entrypoint /bin/bash "${candidate_image}" \
      -c 'find /cleanup -mindepth 1 -depth -delete' >/dev/null 2>&1 || cleanup_failed=1
  else
    find "${tmp}" -mindepth 1 -depth -delete >/dev/null 2>&1 || cleanup_failed=1
  fi
  rmdir "${tmp}" >/dev/null 2>&1 || cleanup_failed=1
  if [[ "${status}" == "0" && "${cleanup_failed}" != "0" ]]; then
    echo "rolling upgrade cleanup failed" >&2
    status=1
  fi
  exit "${status}"
}
trap 'cleanup $?' EXIT
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

docker image inspect "${candidate_image}" >/dev/null
docker pull "${legacy_image}" >/dev/null

build_transport_overlay() {
  local base_image="$1"
  local overlay_image="$2"
  local base_binary_hash base_entrypoint_hash overlay_binary_hash overlay_entrypoint_hash
  base_binary_hash="$(docker run --rm --entrypoint sha256sum "${base_image}" /cockroach/cockroach | awk '{print $1}')"
  base_entrypoint_hash="$(docker run --rm --entrypoint sha256sum "${base_image}" /usr/local/bin/deeploy-crdb-entrypoint | awk '{print $1}')"
  docker build \
    --build-arg "BASE_IMAGE=${base_image}" \
    --file "${root}/tests/local-transport/Dockerfile" \
    --tag "${overlay_image}" \
    "${root}" >/dev/null
  overlay_binary_hash="$(docker run --rm --entrypoint sha256sum "${overlay_image}" /cockroach/cockroach | awk '{print $1}')"
  overlay_entrypoint_hash="$(docker run --rm --entrypoint sha256sum "${overlay_image}" /usr/local/bin/deeploy-crdb-entrypoint | awk '{print $1}')"
  [[ "${overlay_binary_hash}" == "${base_binary_hash}" ]] || { echo "transport overlay changed the database binary" >&2; return 1; }
  [[ "${overlay_entrypoint_hash}" == "${base_entrypoint_hash}" ]] || { echo "transport overlay changed the entrypoint" >&2; return 1; }
}

build_transport_overlay "${legacy_image}" "${legacy_overlay}"
build_transport_overlay "${candidate_image}" "${candidate_overlay}"

mkdir -p "${certs_dir}"
for store in "${stores[@]}"; do
  docker volume create "${store}" >/dev/null
done
printf 'r1-rolling-fake-token\n' > "${token_file}"
docker run --rm --user "$(id -u):$(id -g)" --volume "${certs_dir}:/certs" \
  --entrypoint /cockroach/cockroach "${candidate_image}" cert create-ca \
  --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
docker run --rm --user "$(id -u):$(id -g)" --volume "${certs_dir}:/certs" \
  --entrypoint /cockroach/cockroach "${candidate_image}" cert create-node \
  roach1 roach2 roach3 localhost 127.0.0.1 \
  --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
docker run --rm --user "$(id -u):$(id -g)" --volume "${certs_dir}:/certs" \
  --entrypoint /cockroach/cockroach "${candidate_image}" cert create-client root \
  --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
rm -f "${certs_dir}/ca.key"
docker network create "${network}" >/dev/null

start_node() {
  local index="$1"
  local image="$2"
  local offset=$((index - 1))
  docker run -d --name "${nodes[${offset}]}" --hostname "roach${index}" \
    --network "${network}" --network-alias "target-roach${index}" \
    --volume "${certs_dir}:/test-certs:ro" \
    --volume "${certs_dir}/ca.crt:/runtime/ca.crt:ro" \
    --volume "${certs_dir}/node.crt:/runtime/node.crt:ro" \
    --volume "${certs_dir}/node.key:/runtime/node.key:ro" \
    --volume "${certs_dir}/client.root.crt:/runtime/client.root.crt:ro" \
    --volume "${certs_dir}/client.root.key:/runtime/client.root.key:ro" \
    --volume "${token_file}:/runtime/cf-token:ro" \
    --volume "${stores[${offset}]}:/cockroach/cockroach-data" \
    --env "CRDB_NODE_ID=${index}" \
    --env CRDB_NODE_COUNT=3 \
    --env CRDB_HOSTNAMES=roach1.local,roach2.local,roach3.local \
    --env CRDB_DATABASE=appdb \
    --env CRDB_USER=app_user \
    --env "CRDB_PASSWORD=${db_password}" \
    --env CRDB_LISTEN_HOST=0.0.0.0 \
    --env CRDB_MAX_OFFSET=500ms \
    --env CRDB_CACHE=128MiB \
    --env CRDB_MAX_SQL_MEMORY=128MiB \
    --env CRDB_CA_CRT_FILE=/runtime/ca.crt \
    --env CRDB_NODE_CRT_FILE=/runtime/node.crt \
    --env CRDB_NODE_KEY_FILE=/runtime/node.key \
    --env CRDB_CLIENT_ROOT_CRT_FILE=/runtime/client.root.crt \
    --env CRDB_CLIENT_ROOT_KEY_FILE=/runtime/client.root.key \
    --env CF_TUNNEL_TOKEN_FILE=/runtime/cf-token \
    --env TEST_CLOUDFLARED_ACCESS_MODE=proxy \
    --env CRDB_BOOTSTRAP_TIMEOUT_SECONDS=300 \
    "${image}" >/dev/null
}

wait_sql() {
  local index="$1"
  local deadline=$(( $(date +%s) + 300 ))
  while [[ "$(date +%s)" -lt "${deadline}" ]]; do
    if docker exec --env "PGPASSWORD=${db_password}" "${nodes[$((index - 1))]}" \
      timeout --kill-after=2s 20s /cockroach/cockroach sql \
      --url "postgresql://app_user@roach${index}:26257/appdb?sslmode=require" \
      -e 'select 1' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "node ${index} did not become SQL-ready" >&2
  return 1
}

row_count() {
  local index="$1"
  docker exec --env "PGPASSWORD=${db_password}" "${nodes[$((index - 1))]}" \
    timeout --kill-after=2s 30s /cockroach/cockroach sql \
    --url "postgresql://app_user@roach${index}:26257/appdb?sslmode=require" \
    --format=csv -e 'select count(*) from rolling_smoke;' 2>/dev/null \
    | tail -n 1 | tr -d '\r'
}

wait_row_count() {
  local index="$1"
  local phase="$2"
  local deadline=$(( $(date +%s) + 60 ))
  local count=""
  while [[ "$(date +%s)" -lt "${deadline}" ]]; do
    count="$(row_count "${index}" 2>/dev/null || true)"
    [[ "${count}" == "10000" ]] && return 0
    sleep 1
  done
  echo "expected 10000 rows ${phase} through node ${index}, got ${count:-unavailable}" >&2
  return 1
}

wait_full_replication() {
  local index="$1"
  local deadline=$(( $(date +%s) + 300 ))
  local incomplete=""
  while [[ "$(date +%s)" -lt "${deadline}" ]]; do
    incomplete="$(docker exec "${nodes[$((index - 1))]}" \
      timeout --kill-after=2s 30s /cockroach/cockroach sql \
      --certs-dir=/test-certs --host="roach${index}:26257" --format=csv \
      -e 'select count(*) from crdb_internal.ranges_no_leases where array_length(voting_replicas, 1) < 3 or array_length(learner_replicas, 1) > 0;' \
      2>/dev/null | tail -n 1 | tr -d '\r' || true)"
    [[ "${incomplete}" == "0" ]] && return 0
    sleep 2
  done
  echo "cluster did not return to full three-voter replication" >&2
  return 1
}

replace_node() {
  local index="$1"
  local image="$2"
  local phase="$3"
  local survivor=1
  [[ "${index}" != "1" ]] || survivor=2
  docker stop --time 15 "${nodes[$((index - 1))]}" >/dev/null
  wait_row_count "${survivor}" "while node ${index} was stopped"
  docker rm "${nodes[$((index - 1))]}" >/dev/null
  start_node "${index}" "${image}"
  wait_sql "${index}"
  docker exec --env "PGPASSWORD=${db_password}" "${nodes[$((index - 1))]}" \
    timeout --kill-after=2s 30s /cockroach/cockroach sql \
    --url "postgresql://app_user@roach${index}:26257/appdb?sslmode=require" \
    -e "upsert into rolling_events values ('${phase}-${index}', now());" >/dev/null
  wait_full_replication "${index}"
  wait_row_count "${index}" "after ${phase} node ${index}"
}

start_node 2 "${legacy_overlay}"
start_node 3 "${legacy_overlay}"
start_node 1 "${legacy_overlay}"
wait_sql 1
wait_sql 2
wait_sql 3

docker exec --env "PGPASSWORD=${db_password}" "${nodes[0]}" \
  timeout --kill-after=2s 90s /cockroach/cockroach sql \
  --url 'postgresql://app_user@roach1:26257/appdb?sslmode=require' \
  -e 'create table if not exists rolling_smoke (id int primary key, note string);' \
  -e "upsert into rolling_smoke select i, 'row-' || i::string from generate_series(1, 10000) as g(i);" \
  -e 'create table if not exists rolling_events (step string primary key, happened_at timestamptz);' \
  -e 'create database if not exists rolling_operator;' \
  -e "create user if not exists rolling_child with login password '${child_password}';" \
  -e "alter user rolling_child with login password '${child_password}';" \
  -e 'grant all on database rolling_operator to rolling_child;' >/dev/null
docker exec --env "PGPASSWORD=${child_password}" "${nodes[1]}" \
  timeout --kill-after=2s 30s /cockroach/cockroach sql \
  --url 'postgresql://rolling_child@roach2:26257/rolling_operator?sslmode=require' \
  -e 'create table if not exists delegated_items (id int primary key, note string);' \
  -e "upsert into delegated_items values (1, 'persisted');" >/dev/null
wait_full_replication 1
[[ "$(row_count 3)" == "10000" ]]

for index in 3 2 1; do
  replace_node "${index}" "${candidate_overlay}" upgrade
done

candidate_overlay_id="$(docker image inspect "${candidate_overlay}" --format '{{.Id}}')"
for node in "${nodes[@]}"; do
  [[ "$(docker inspect "${node}" --format '{{.Image}}')" == "${candidate_overlay_id}" ]]
  docker exec "${node}" /bin/bash -c '
    set -euo pipefail
    token="$(cat /runtime/cf-token)"
    scanner_pid="$$"
    for environment in /proc/[0-9]*/environ; do
      [[ -r "$environment" ]] || continue
      [[ "$environment" != "/proc/${scanner_pid}/environ" ]] || continue
      values="$(tr "\000" "\n" < "$environment")"
      case "$values" in
        *r1_rolling_validation_password*|*"$token"*|*CRDB_NODE_KEY=*|*CRDB_CLIENT_ROOT_KEY=*)
          echo "secret remained in a candidate process environment" >&2
          exit 1
          ;;
      esac
    done
  '
done

role_count="$(docker exec "${nodes[0]}" timeout --kill-after=2s 30s /cockroach/cockroach sql \
  --certs-dir=/test-certs --host=roach1:26257 --format=csv \
  -e "select count(*) from [show users] where username = 'app_user' and options like '%CREATEDB%' and options like '%CREATEROLE%' and options like '%CREATELOGIN%';" \
  | tail -n 1 | tr -d '\r')"
[[ "${role_count}" == "1" ]] || { echo "operator privileges were lost during upgrade" >&2; exit 1; }

for store in "${stores[@]}"; do
  docker run --rm --volume "${store}:/store:ro" --entrypoint /bin/bash "${candidate_image}" \
    -c '[[ ! -e /store/.deeploy-recovery-v1/state && ! -e /store/.deeploy-recovery-v1/exhausted ]]' || {
    echo "rollback is forbidden after recovery metadata was activated" >&2
    exit 1
  }
done

for index in 3 2 1; do
  replace_node "${index}" "${legacy_overlay}" rollback
done

legacy_overlay_id="$(docker image inspect "${legacy_overlay}" --format '{{.Id}}')"
for node in "${nodes[@]}"; do
  [[ "$(docker inspect "${node}" --format '{{.Image}}')" == "${legacy_overlay_id}" ]]
done

event_count="$(docker exec --env "PGPASSWORD=${db_password}" "${nodes[2]}" \
  timeout --kill-after=2s 30s /cockroach/cockroach sql \
  --url 'postgresql://app_user@roach3:26257/appdb?sslmode=require' --format=csv \
  -e 'select count(*) from rolling_events;' | tail -n 1 | tr -d '\r')"
[[ "${event_count}" == "6" ]] || { echo "rolling canary writes were lost: ${event_count}" >&2; exit 1; }
delegated_count="$(docker exec --env "PGPASSWORD=${child_password}" "${nodes[1]}" \
  timeout --kill-after=2s 30s /cockroach/cockroach sql \
  --url 'postgresql://rolling_child@roach2:26257/rolling_operator?sslmode=require' --format=csv \
  -e 'select count(*) from delegated_items;' | tail -n 1 | tr -d '\r')"
[[ "${delegated_count}" == "1" ]] || { echo "delegated-user data was lost during rollback" >&2; exit 1; }

for node in "${nodes[@]}"; do
  logs="$(docker logs "${node}" 2>&1 || true)"
  for secret in "${db_password}" "${child_password}" 'r1-rolling-fake-token'; do
    [[ "${logs}" != *"${secret}"* ]] || { echo "secret leaked into rolling node logs" >&2; exit 1; }
  done
done

echo "persisted three-node legacy/candidate rolling upgrade and rollback ok"
