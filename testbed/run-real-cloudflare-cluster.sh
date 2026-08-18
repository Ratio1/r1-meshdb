#!/usr/bin/env bash
# Copyright 2026 Ratio1
# Licensed under the Apache License, Version 2.0. See LICENSE.

set -euo pipefail
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${1:?usage: testbed/run-real-cloudflare-cluster.sh <immutable-image-ref>}"
[[ "${image}" == *@sha256:* ]] || { echo "real Cloudflare validation requires an immutable image digest" >&2; exit 1; }

: "${CF_ACCOUNT_ID:?CF_ACCOUNT_ID is required}"
: "${CF_ZONE_ID:?CF_ZONE_ID is required}"
: "${CF_API_TOKEN:?CF_API_TOKEN is required}"
: "${CF_BASE_DOMAIN:?CF_BASE_DOMAIN is required}"

GITHUB_RUN_ID="${GITHUB_RUN_ID:-$$}"
GITHUB_RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}"
[[ "${GITHUB_RUN_ID}" =~ ^[1-9][0-9]*$ ]]
[[ "${GITHUB_RUN_ATTEMPT}" =~ ^[1-9][0-9]*$ ]]
run_id="${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}"
prefix="r1-meshdb-ci-${run_id}"
[[ "${#prefix}" -le 40 ]]
tmp="$(mktemp -d /tmp/r1-meshdb-real-cloudflare.XXXXXXXX)"
allocation_dir="${tmp}/cloudflare"
certs_dir="${tmp}/certs"
nodes=("r1-meshdb-real-1-${run_id}" "r1-meshdb-real-2-${run_id}" "r1-meshdb-real-3-${run_id}")
networks=("r1-meshdb-real-net-1-${run_id}" "r1-meshdb-real-net-2-${run_id}" "r1-meshdb-real-net-3-${run_id}")
stores=("r1-meshdb-real-store-1-${run_id}" "r1-meshdb-real-store-2-${run_id}" "r1-meshdb-real-store-3-${run_id}")
db_password="r1_real_cloudflare_validation_password"
cleanup_started=false
evidence_dir="${R1_MESHDB_EVIDENCE_DIR:-${R1_SQL_EVIDENCE_DIR:-}}"

record_evidence() {
  local status="$1"
  [[ -n "${evidence_dir}" ]] || return 0
  mkdir -p "${evidence_dir}"
  chmod 700 "${evidence_dir}"
  {
    printf 'status=%s\n' "${status}"
    printf 'image=%s\n' "${image}"
    printf 'run_id=%s\n' "${run_id}"
  } > "${evidence_dir}/summary.txt"
  if [[ -f "${allocation_dir}/state.json" ]]; then
    python3 - "${allocation_dir}/state.json" "${evidence_dir}/topology.json" <<'PY'
import json
from pathlib import Path
import sys

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
public = {
  "schemaVersion": 1,
  "baseDomain": state["baseDomain"],
  "tunnels": [
    {"hostname": tunnel["hostname"], "nodeIndex": tunnel["nodeIndex"]}
    for tunnel in state["tunnels"]
  ],
}
Path(sys.argv[2]).write_text(json.dumps(public, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  fi
  for index in 1 2 3; do
    raw_logs="${tmp}/node-${index}.evidence.raw"
    docker logs "${nodes[$((index - 1))]}" > "${raw_logs}" 2>&1 || true
    python3 - "${raw_logs}" "${allocation_dir}/node-${index}.token" \
      "${evidence_dir}/node-${index}.log" <<'PY'
from pathlib import Path
import sys

logs = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
token_path = Path(sys.argv[2])
secrets = ["r1_real_cloudflare_validation_password"]
if token_path.is_file():
  secrets.append(token_path.read_text(encoding="utf-8"))
for secret in secrets:
  if secret:
    logs = logs.replace(secret, "[redacted]")
Path(sys.argv[3]).write_text(logs, encoding="utf-8")
PY
    rm -f "${raw_logs}"
  done
}

preserve_cleanup_state() {
  local state="${allocation_dir}/state.json"
  local destination
  [[ -f "${state}" ]] || return 1
  # Tunnel tokens are not required for API cleanup and must never be retained.
  find "${allocation_dir}" -maxdepth 1 -name '*.token' -delete
  if [[ -n "${evidence_dir}" ]]; then
    mkdir -p "${evidence_dir}"
    chmod 700 "${evidence_dir}"
    destination="${evidence_dir}/cloudflare-cleanup-state.json"
  else
    destination="$(mktemp /tmp/r1-meshdb-cloudflare-cleanup-state.XXXXXXXX.json)"
  fi
  cp "${state}" "${destination}"
  chmod 600 "${destination}"
  echo "Cloudflare cleanup state preserved at ${destination}" >&2
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
  for network in "${networks[@]}"; do
    docker network rm "${network}" >/dev/null 2>&1 || true
    docker network inspect "${network}" >/dev/null 2>&1 && cleanup_failed=1
  done
  if [[ -f "${allocation_dir}/state.json" ]]; then
    if ! python3 "${root}/scripts/cloudflare_ephemeral_tunnels.py" cleanup \
      --state "${allocation_dir}/state.json"; then
      preserve_cleanup_state || cleanup_failed=1
      cleanup_failed=1
    fi
  fi
  if docker image inspect "${image}" >/dev/null 2>&1; then
    docker run --rm --volume "${tmp}:/cleanup" --entrypoint /bin/bash "${image}" \
      -c 'find /cleanup -mindepth 1 -depth -delete' >/dev/null 2>&1 || cleanup_failed=1
  else
    find "${tmp}" -mindepth 1 -depth -delete >/dev/null 2>&1 || cleanup_failed=1
  fi
  rmdir "${tmp}" >/dev/null 2>&1 || cleanup_failed=1
  if [[ "${status}" == "0" && "${cleanup_failed}" != "0" ]]; then
    echo "real Cloudflare validation cleanup failed" >&2
    status=1
  fi
  exit "${status}"
}
trap 'cleanup $?' EXIT
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

docker image inspect "${image}" >/dev/null
python3 "${root}/scripts/cloudflare_ephemeral_tunnels.py" create \
  --output-dir "${allocation_dir}" --count 3 --prefix "${prefix}" >/dev/null

mapfile -t hostnames < <(python3 - "${allocation_dir}/state.json" <<'PY'
import json
from pathlib import Path
import sys

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for tunnel in state["tunnels"]:
  print(tunnel["hostname"])
PY
)
[[ "${#hostnames[@]}" == "3" ]]
hostname_csv="$(IFS=,; printf '%s' "${hostnames[*]}")"

dns_ready=false
for _ in $(seq 1 120); do
  if python3 - "${hostnames[@]}" <<'PY'
import socket
import sys

for hostname in sys.argv[1:]:
  socket.getaddrinfo(hostname, 443, type=socket.SOCK_STREAM)
PY
  then
    dns_ready=true
    break
  fi
  sleep 2
done
[[ "${dns_ready}" == "true" ]] || { echo "ephemeral Cloudflare hostnames did not resolve" >&2; exit 1; }

mkdir -p "${certs_dir}"
for store in "${stores[@]}"; do
  docker volume create "${store}" >/dev/null
done
docker run --rm -u "$(id -u):$(id -g)" -v "${certs_dir}:/certs" \
  --entrypoint /cockroach/cockroach "${image}" cert create-ca \
  --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
docker run --rm -u "$(id -u):$(id -g)" -v "${certs_dir}:/certs" \
  --entrypoint /cockroach/cockroach "${image}" cert create-node \
  roach1 roach2 roach3 localhost 127.0.0.1 \
  --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
docker run --rm -u "$(id -u):$(id -g)" -v "${certs_dir}:/certs" \
  --entrypoint /cockroach/cockroach "${image}" cert create-client root \
  --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
find "${certs_dir}" -maxdepth 1 -name ca.key -delete

for network in "${networks[@]}"; do
  docker network create "${network}" >/dev/null
done

start_node() {
  local index="$1"
  local offset=$((index - 1))
  docker run -d --name "${nodes[${offset}]}" --hostname "roach${index}" \
    --network "${networks[${offset}]}" \
    -v "${certs_dir}/ca.crt:/runtime/ca.crt:ro" \
    -v "${certs_dir}/node.crt:/runtime/node.crt:ro" \
    -v "${certs_dir}/node.key:/runtime/node.key:ro" \
    -v "${certs_dir}/client.root.crt:/runtime/client.root.crt:ro" \
    -v "${certs_dir}/client.root.key:/runtime/client.root.key:ro" \
    -v "${allocation_dir}/node-${index}.token:/runtime/cf-token:ro" \
    -v "${stores[${offset}]}:/cockroach/cockroach-data" \
    -e "CRDB_NODE_ID=${index}" \
    -e CRDB_NODE_COUNT=3 \
    -e "CRDB_HOSTNAMES=${hostname_csv}" \
    -e CRDB_DATABASE=appdb \
    -e CRDB_USER=app_user \
    -e "CRDB_PASSWORD=${db_password}" \
    -e CRDB_LISTEN_HOST=0.0.0.0 \
    -e CRDB_MAX_OFFSET=500ms \
    -e CRDB_CACHE=128MiB \
    -e CRDB_MAX_SQL_MEMORY=128MiB \
    -e CRDB_CA_CRT_FILE=/runtime/ca.crt \
    -e CRDB_NODE_CRT_FILE=/runtime/node.crt \
    -e CRDB_NODE_KEY_FILE=/runtime/node.key \
    -e CRDB_CLIENT_ROOT_CRT_FILE=/runtime/client.root.crt \
    -e CRDB_CLIENT_ROOT_KEY_FILE=/runtime/client.root.key \
    -e CF_TUNNEL_TOKEN_FILE=/runtime/cf-token \
    -e CRDB_BOOTSTRAP_TIMEOUT_SECONDS=300 \
    "${image}" >/dev/null
}

start_node 2
start_node 3
start_node 1

for index in 1 2 3; do
  members="$(docker network inspect "${networks[$((index - 1))]}" --format '{{len .Containers}}')"
  [[ "${members}" == "1" ]] || { echo "node ${index} network is not isolated" >&2; exit 1; }
done

sql_ready=false
for _ in $(seq 1 180); do
  all_ready=true
  for index in 1 2 3; do
    docker exec -e "PGPASSWORD=${db_password}" "${nodes[$((index - 1))]}" \
      timeout --kill-after=2s 20s /cockroach/cockroach sql \
      --url "postgresql://app_user@roach${index}:26257/appdb?sslmode=require" \
      -e 'select 1' >/dev/null 2>&1 || all_ready=false
  done
  if [[ "${all_ready}" == "true" ]]; then
    sql_ready=true
    break
  fi
  sleep 2
done
[[ "${sql_ready}" == "true" ]] || { echo "real Cloudflare three-node cluster was not SQL-ready" >&2; exit 1; }

for index in 1 2 3; do
  docker exec "${nodes[$((index - 1))]}" /bin/bash -c '
    set -euo pipefail
    token="$(cat /runtime/cf-token)"
    scanner_pid="$$"
    for environment in /proc/[0-9]*/environ; do
      [[ -r "$environment" ]] || continue
      [[ "$environment" != "/proc/${scanner_pid}/environ" ]] || continue
      values="$(tr "\000" "\n" < "$environment")"
      case "$values" in
        *r1_real_cloudflare_validation_password*|*"$token"*)
          echo "secret remained in a supervised process environment" >&2
          exit 1
          ;;
      esac
    done
  '
done

docker exec -e "PGPASSWORD=${db_password}" "${nodes[0]}" \
  timeout --kill-after=2s 90s /cockroach/cockroach sql \
  --url 'postgresql://app_user@roach1:26257/appdb?sslmode=require' \
  -e 'create table if not exists cloudflare_smoke (id int primary key, note string);' \
  -e "upsert into cloudflare_smoke select i, 'row-' || i::string from generate_series(1, 10000) as g(i);" >/dev/null

replication_ready=false
for _ in $(seq 1 180); do
  incomplete="$(docker exec "${nodes[1]}" timeout --kill-after=2s 30s /cockroach/cockroach sql \
    --certs-dir=/cockroach/certs --host=roach2:26257 --format=csv \
    -e 'select count(*) from crdb_internal.ranges_no_leases where array_length(voting_replicas, 1) < 3 or array_length(learner_replicas, 1) > 0;' \
    2>/dev/null | tail -n 1 | tr -d '\r' || true)"
  if [[ "${incomplete}" == "0" ]]; then
    replication_ready=true
    break
  fi
  sleep 2
done
[[ "${replication_ready}" == "true" ]] || { echo "real Cloudflare cluster did not reach full replication" >&2; exit 1; }

count="$(docker exec -e "PGPASSWORD=${db_password}" "${nodes[2]}" \
  timeout --kill-after=2s 30s /cockroach/cockroach sql \
  --url 'postgresql://app_user@roach3:26257/appdb?sslmode=require' --format=csv \
  -e 'select count(*) from cloudflare_smoke;' | tail -n 1 | tr -d '\r')"
[[ "${count}" == "10000" ]] || { echo "real Cloudflare read through node 3 returned ${count} rows" >&2; exit 1; }

docker stop --time 15 "${nodes[2]}" >/dev/null
survivor_count=""
deadline=$(( $(date +%s) + 180 ))
while [[ "$(date +%s)" -lt "${deadline}" ]]; do
  survivor_count="$(docker exec -e "PGPASSWORD=${db_password}" "${nodes[1]}" \
    timeout --kill-after=2s 30s /cockroach/cockroach sql \
    --url 'postgresql://app_user@roach2:26257/appdb?sslmode=require' --format=csv \
    -e 'select count(*) from cloudflare_smoke;' 2>/dev/null | tail -n 1 | tr -d '\r' || true)"
  [[ "${survivor_count}" == "10000" ]] && break
  sleep 2
done
[[ "${survivor_count}" == "10000" ]] || { echo "cluster lost availability with one real tunnel down" >&2; exit 1; }

docker start "${nodes[2]}" >/dev/null
rejoined=false
for _ in $(seq 1 180); do
  if docker exec -e "PGPASSWORD=${db_password}" "${nodes[2]}" \
    timeout --kill-after=2s 30s /cockroach/cockroach sql \
    --url 'postgresql://app_user@roach3:26257/appdb?sslmode=require' \
    -e 'select 1' >/dev/null 2>&1; then
    rejoined=true
    break
  fi
  sleep 2
done
[[ "${rejoined}" == "true" ]] || { echo "node 3 did not rejoin through its restored tunnel" >&2; exit 1; }

for index in 1 2 3; do
  logs_file="${tmp}/node-${index}.logs"
  docker logs "${nodes[$((index - 1))]}" >"${logs_file}" 2>&1
  grep -Fq "${db_password}" "${logs_file}" && { echo "database password leaked into node ${index} logs" >&2; exit 1; }
  python3 - "${allocation_dir}/node-${index}.token" "${logs_file}" <<'PY'
from pathlib import Path
import sys

token = Path(sys.argv[1]).read_text(encoding="utf-8")
logs = Path(sys.argv[2]).read_text(encoding="utf-8", errors="replace")
if token and token in logs:
  raise SystemExit("Cloudflare token leaked into runtime logs")
PY
done

echo "unchanged-image real Cloudflare three-node smoke ok"
