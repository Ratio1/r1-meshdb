#!/usr/bin/env bash
set -euo pipefail

image="${1:-deeploy-crdb-runtime-supervision:local}"
run_id="${2:-$$-${RANDOM}}"
test_max_offset="${CRDB_TEST_MAX_OFFSET:-500ms}"
test_cache="${CRDB_TEST_CACHE:-128MiB}"
test_sql_memory="${CRDB_TEST_MAX_SQL_MEMORY:-128MiB}"
test_node_count="${CRDB_TEST_NODE_COUNT:-3}"
if [[ ! "${test_node_count}" =~ ^[1-9][0-9]*$ ]] || \
   ! awk -v value="${test_node_count}" 'BEGIN { exit !(value >= 3) }'; then
  echo "CRDB_TEST_NODE_COUNT must be an integer of at least 3" >&2
  exit 1
fi
network="deeploy-crdb-entrypoint-${run_id}"
nodes=()
stores=()
certificate_hostnames=()
cluster_hostnames=()
for node_id in $(seq 1 "${test_node_count}"); do
  nodes+=("deeploy-crdb-entrypoint-${node_id}-${run_id}")
  stores+=("deeploy-crdb-entrypoint-store-${node_id}-${run_id}")
  certificate_hostnames+=("roach${node_id}")
  cluster_hostnames+=("roach${node_id}.local")
done
node1="${nodes[0]}"
node2="${nodes[1]}"
node3="${nodes[2]}"
runtime_volume="deeploy-crdb-entrypoint-runtime-${run_id}"
volumes=("${stores[@]}" "${runtime_volume}")
tmp="$(mktemp -d /tmp/deeploy-crdb-entrypoint-multinode.XXXXXX)"

cleanup() {
  local status=$?
  local cleanup_failed=0
  trap - EXIT
  if [[ "${status}" != "0" ]]; then
    for name in "${nodes[@]}"; do
      docker logs "${name}" >&2 2>/dev/null || true
    done
  fi
  docker rm -f "${nodes[@]}" >/dev/null 2>&1 || true
  for name in "${nodes[@]}"; do
    docker inspect "${name}" >/dev/null 2>&1 && cleanup_failed=1
  done
  docker volume rm -f "${volumes[@]}" >/dev/null 2>&1 || true
  for volume in "${volumes[@]}"; do
    docker volume inspect "${volume}" >/dev/null 2>&1 && cleanup_failed=1
  done
  docker network rm "${network}" >/dev/null 2>&1 || true
  docker network inspect "${network}" >/dev/null 2>&1 && cleanup_failed=1
  docker run --rm -v "${tmp}:/cleanup" --entrypoint /bin/sh "${image}" \
    -c 'rm -rf /cleanup/* /cleanup/.[!.]* /cleanup/..?*' >/dev/null 2>&1 || cleanup_failed=1
  rmdir "${tmp}" >/dev/null 2>&1 || cleanup_failed=1
  if [[ "${status}" == "0" && "${cleanup_failed}" != "0" ]]; then
    echo "entrypoint multinode smoke cleanup failed" >&2
    status=1
  fi
  exit "${status}"
}
trap cleanup EXIT

for volume in "${volumes[@]}"; do
  docker volume create "${volume}" >/dev/null
done

docker run --rm -v "${runtime_volume}:/runtime" --entrypoint /bin/sh "${image}" \
  -c 'mkdir -m 700 /runtime/certs /runtime/token && printf "entrypoint-multinode-fake-token\n" > /runtime/token/cf-token'
docker run --rm -v "${runtime_volume}:/runtime" --entrypoint /cockroach/cockroach "${image}" \
  cert create-ca --certs-dir=/runtime/certs --ca-key=/runtime/certs/ca.key >/dev/null
docker run --rm -v "${runtime_volume}:/runtime" --entrypoint /cockroach/cockroach "${image}" \
  cert create-node "${certificate_hostnames[@]}" localhost 127.0.0.1 \
  --certs-dir=/runtime/certs --ca-key=/runtime/certs/ca.key >/dev/null
docker run --rm -v "${runtime_volume}:/runtime" --entrypoint /cockroach/cockroach "${image}" \
  cert create-client root --certs-dir=/runtime/certs --ca-key=/runtime/certs/ca.key >/dev/null
docker run --rm -v "${runtime_volume}:/runtime" --entrypoint /bin/sh "${image}" \
  -c 'rm -f /runtime/certs/ca.key'

docker network create "${network}" >/dev/null

start_node() {
  local node_id="$1"
  local name="$2"
  local -a certificate_arguments=(
    -e CRDB_CA_CRT_FILE=/runtime/certs/ca.crt
    -e CRDB_NODE_CRT_FILE=/runtime/certs/node.crt
    -e CRDB_NODE_KEY_FILE=/runtime/certs/node.key
    -e CRDB_CLIENT_ROOT_CRT_FILE=/runtime/certs/client.root.crt
    -e CRDB_CLIENT_ROOT_KEY_FILE=/runtime/certs/client.root.key
  )
  if [[ "${node_id}" == "1" ]]; then
    certificate_arguments=(
      -e "CRDB_CA_CRT=$(read_runtime_file ca.crt)"
      -e "CRDB_NODE_CRT=$(read_runtime_file node.crt)"
      -e "CRDB_NODE_KEY=$(read_runtime_file node.key)"
      -e "CRDB_CLIENT_ROOT_CRT=$(read_runtime_file client.root.crt)"
      -e "CRDB_CLIENT_ROOT_KEY=$(read_runtime_file client.root.key)"
    )
  fi
  # Co-located test nodes must not each size memory as a fraction of the whole
  # Docker VM; production runs one service member per edge node.
  docker run -d --name "${name}" --hostname "roach${node_id}" \
    --network "${network}" --network-alias "target-roach${node_id}" \
    -v "${runtime_volume}:/runtime:ro" \
    -v "${stores[$((node_id - 1))]}:/cockroach/cockroach-data" \
    -e "CRDB_NODE_ID=${node_id}" \
    -e "CRDB_NODE_COUNT=${test_node_count}" \
    -e "CRDB_HOSTNAMES=$(IFS=,; printf '%s' "${cluster_hostnames[*]}")" \
    -e "CRDB_NUM_REPLICAS=${test_node_count}" \
    -e "CRDB_NUM_VOTERS=${test_node_count}" \
    -e CRDB_DATABASE=appdb \
    -e CRDB_USER=app_user \
    -e CRDB_PASSWORD=entrypoint_multinode_secret \
    -e CRDB_LISTEN_HOST=0.0.0.0 \
    -e "CRDB_MAX_OFFSET=${test_max_offset}" \
    -e "CRDB_CACHE=${test_cache}" \
    -e "CRDB_MAX_SQL_MEMORY=${test_sql_memory}" \
    "${certificate_arguments[@]}" \
    -e CF_TUNNEL_TOKEN_FILE=/runtime/token/cf-token \
    -e TEST_CLOUDFLARED_ACCESS_MODE=proxy \
    -e CRDB_BOOTSTRAP_TIMEOUT_SECONDS=180 \
    "${image}" >/dev/null
}

read_runtime_file() {
  local name="$1"
  docker run --rm -v "${runtime_volume}:/runtime:ro" --entrypoint /bin/sh "${image}" \
    -c 'cat "/runtime/certs/$1"' read-runtime-file "${name}"
}

for node_id in $(seq 2 "${test_node_count}"); do
  start_node "${node_id}" "${nodes[$((node_id - 1))]}"
done
start_node 1 "${node1}"

ready=0
for _ in $(seq 1 120); do
  if docker exec -e PGPASSWORD=entrypoint_multinode_secret "${node1}" \
    timeout --kill-after=2s 20s /cockroach/cockroach sql \
    --url "postgresql://app_user@roach1:26257/appdb?sslmode=require" \
    -e "select 1" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "${ready}" != "1" ]]; then
  echo "${test_node_count}-node entrypoint cluster did not become SQL-ready" >&2
  exit 1
fi

for name in "${nodes[@]}"; do
  docker exec "${name}" /bin/bash -c '
    set -euo pipefail
    scanner_pid="$$"
    for environment in /proc/[0-9]*/environ; do
      [[ "$environment" != "/proc/${scanner_pid}/environ" ]] || continue
      if ! values="$(tr "\000" "\n" 2>/dev/null < "$environment")"; then
        if [[ -e "$environment" ]]; then
          echo "process environment scan failed" >&2
          exit 1
        fi
        continue
      fi
      if grep -Eq "entrypoint_multinode_secret|entrypoint-multinode-fake-token|^CRDB_(CA_CRT|NODE_CRT|NODE_KEY|CLIENT_ROOT_CRT|CLIENT_ROOT_KEY)=" <<< "$values"; then
        echo "secret remained in a supervised process environment" >&2
        exit 1
      fi
    done
    password_cleanup_complete=false
    password_cleanup_deadline=$((SECONDS + 30))
    while true; do
      password_file=""
      if ! password_file="$(find /tmp -xdev -type f -name database-password -print -quit)"; then
        echo "database bootstrap password cleanup scan failed" >&2
        exit 1
      fi
      if [[ -z "$password_file" ]]; then
        password_cleanup_complete=true
        break
      fi
      if (( SECONDS >= password_cleanup_deadline )); then
        break
      fi
      sleep 1
    done
    if [[ "$password_cleanup_complete" != "true" ]]; then
      echo "database bootstrap password file was not removed after bounded wait" >&2
      exit 1
    fi
    token_file="$(find /tmp -xdev -type f -name cloudflare-token | head -n 1)"
    [[ -n "$token_file" && "$(stat -c "%u:%a" "$token_file")" == "0:600" ]]
    certificate_file=""
    if ! certificate_file="$(find /tmp -xdev -type f \
        \( -name ca-crt -o -name node-crt -o -name node-key \
           -o -name client-root-crt -o -name client-root-key \) \
        -print -quit)"; then
      echo "staged certificate cleanup scan failed" >&2
      exit 1
    fi
    if [[ -n "$certificate_file" ]]; then
      echo "staged certificate material was not removed" >&2
      exit 1
    fi
  '
done

docker exec -e PGPASSWORD=entrypoint_multinode_secret "${node1}" \
  timeout --kill-after=2s 30s /cockroach/cockroach sql \
  --url "postgresql://app_user@roach1:26257/appdb?sslmode=require" \
  -e "create table if not exists entrypoint_smoke (id int primary key, note string);" \
  -e "upsert into entrypoint_smoke select i, 'row-' || i::string from generate_series(1, 10000) as g(i);" >/dev/null

operator_sql="${tmp}/operator.sql"
cat > "${operator_sql}" <<'SQL'
CREATE DATABASE IF NOT EXISTS entrypoint_operator;
CREATE USER IF NOT EXISTS entrypoint_child WITH LOGIN PASSWORD 'entrypoint_child_secret';
ALTER USER entrypoint_child WITH LOGIN PASSWORD 'entrypoint_child_secret';
GRANT ALL ON DATABASE entrypoint_operator TO entrypoint_child;
SQL
chmod 600 "${operator_sql}"
docker exec -i -e PGPASSWORD=entrypoint_multinode_secret "${node2}" \
  timeout --kill-after=2s 30s /cockroach/cockroach sql \
  --set=errexit=true \
  --url "postgresql://app_user@roach2:26257/appdb?sslmode=require" \
  < "${operator_sql}" >/dev/null
rm -f "${operator_sql}"

docker exec -e PGPASSWORD=entrypoint_child_secret "${node3}" \
  timeout --kill-after=2s 20s /cockroach/cockroach sql \
  --url "postgresql://entrypoint_child@roach3:26257/entrypoint_operator?sslmode=require" \
  -e "create table if not exists delegated_items (id int primary key, note string);" \
  -e "upsert into delegated_items values (1, 'node3');" >/dev/null

row_count="$(docker exec -e PGPASSWORD=entrypoint_multinode_secret "${node2}" \
  timeout --kill-after=2s 20s /cockroach/cockroach sql \
  --url "postgresql://app_user@roach2:26257/appdb?sslmode=require" \
  --format=csv -e "select count(*) from entrypoint_smoke;" | tail -n 1 | tr -d '\r')"
if [[ "${row_count}" != "10000" ]]; then
  echo "expected replicated row count 10000, got ${row_count}" >&2
  exit 1
fi

gossip_node_count="$(docker exec "${node1}" timeout --kill-after=2s 20s /cockroach/cockroach sql \
  --certs-dir=/cockroach/certs --host=roach1:26257 \
  --format=csv -e "select count(*) from crdb_internal.gossip_nodes;" | tail -n 1 | tr -d '\r')"
if [[ "${gossip_node_count}" != "${test_node_count}" ]]; then
  echo "expected ${test_node_count} gossip nodes, got ${gossip_node_count}" >&2
  exit 1
fi

zone_config="$(docker exec "${node1}" timeout --kill-after=2s 20s /cockroach/cockroach sql \
  --certs-dir=/cockroach/certs --host=roach1:26257 --format=csv \
  -e "show zone configuration for range default;")"
if ! grep -Fq "num_replicas = ${test_node_count}" <<< "${zone_config}" || \
   ! grep -Fq "num_voters = ${test_node_count}" <<< "${zone_config}"; then
  printf '%s\n' "${zone_config}" >&2
  echo "default range does not use ${test_node_count} replicas and voters" >&2
  exit 1
fi

role_option_count="$(docker exec "${node3}" timeout --kill-after=2s 20s /cockroach/cockroach sql \
  --certs-dir=/runtime/certs --host=roach3:26257 --format=csv \
  -e "select count(*) from [show users] where username = 'app_user' and options like '%CREATEDB%' and options like '%CREATEROLE%' and options like '%CREATELOGIN%';" \
  | tail -n 1 | tr -d '\r')"
if [[ "${role_option_count}" != "1" ]]; then
  echo "configured operator privileges were not visible through node 3" >&2
  exit 1
fi

replication_ready=false
for _ in $(seq 1 300); do
  incomplete_baseline_voter_sets="$(docker exec "${node1}" \
    timeout --kill-after=2s 20s /cockroach/cockroach sql \
    --certs-dir=/cockroach/certs --host=roach1:26257 --format=csv \
    -e "select count(*) from crdb_internal.ranges_no_leases where array_length(voting_replicas, 1) < 3 or array_length(learner_replicas, 1) > 0;" \
    2>/dev/null | tail -n 1 | tr -d '\r' || true)"
  incomplete_application_voter_sets="$(docker exec "${node1}" \
    timeout --kill-after=2s 20s /cockroach/cockroach sql \
    --certs-dir=/cockroach/certs --host=roach1:26257 --format=csv \
    -e "select count(*) from [show ranges from table appdb.public.entrypoint_smoke] where array_length(voting_replicas, 1) < ${test_node_count} or coalesce(array_length(non_voting_replicas, 1), 0) > 0;" \
    2>/dev/null | tail -n 1 | tr -d '\r' || true)"
  if [[ "${incomplete_baseline_voter_sets}" == "0" && \
        "${incomplete_application_voter_sets}" == "0" ]]; then
    replication_ready=true
    break
  fi
  sleep 1
done
if [[ "${replication_ready}" != "true" ]]; then
  echo "${test_node_count}-node cluster did not reach application replication before failover" >&2
  exit 1
fi

docker stop --time 15 "${node1}" >/dev/null
surviving_count=""
surviving_error="${tmp}/surviving-query.err"
surviving_deadline=$(( $(date +%s) + 120 ))
while [[ "$(date +%s)" -lt "${surviving_deadline}" ]]; do
  if surviving_output="$(docker exec -e PGPASSWORD=entrypoint_child_secret "${node2}" \
      timeout --kill-after=1s 15s /cockroach/cockroach sql \
      --url "postgresql://entrypoint_child@roach2:26257/entrypoint_operator?sslmode=require" \
      --format=csv -e "select count(*) from delegated_items;" 2>"${surviving_error}")"; then
    surviving_count="$(printf '%s\n' "${surviving_output}" | tail -n 1 | tr -d '\r')"
    if [[ "${surviving_count}" == "1" ]]; then
      break
    fi
  fi
  sleep 1
done
if [[ "${surviving_count}" != "1" ]]; then
  [[ ! -s "${surviving_error}" ]] || cat "${surviving_error}" >&2
  echo "${test_node_count}-node cluster lost delegated data with one node stopped" >&2
  exit 1
fi
docker start "${node1}" >/dev/null
for _ in $(seq 1 120); do
  if docker exec -e PGPASSWORD=entrypoint_multinode_secret "${node1}" \
    timeout --kill-after=2s 20s /cockroach/cockroach sql \
    --url "postgresql://app_user@roach1:26257/appdb?sslmode=require" \
    -e "select 1" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
rejoined_count="$(docker exec -e PGPASSWORD=entrypoint_child_secret "${node1}" \
  timeout --kill-after=2s 20s /cockroach/cockroach sql \
  --url "postgresql://entrypoint_child@roach1:26257/entrypoint_operator?sslmode=require" \
  --format=csv -e "select count(*) from delegated_items;" | tail -n 1 | tr -d '\r')"
if [[ "${rejoined_count}" != "1" ]]; then
  echo "delegated data was not readable after node 1 rejoined" >&2
  exit 1
fi

docker stop --time 15 "${nodes[@]}" >/dev/null
docker start "${nodes[@]}" >/dev/null
restart_count=""
restart_deadline=$(( $(date +%s) + 180 ))
while [[ "$(date +%s)" -lt "${restart_deadline}" ]]; do
  restart_count="$(docker exec -e PGPASSWORD=entrypoint_multinode_secret "${node3}" \
    timeout --kill-after=2s 20s /cockroach/cockroach sql \
    --url "postgresql://app_user@roach3:26257/appdb?sslmode=require" \
    --format=csv -e "select count(*) from entrypoint_smoke;" 2>/dev/null \
    | tail -n 1 | tr -d '\r' || true)"
  [[ "${restart_count}" == "10000" ]] && break
  sleep 1
done
if [[ "${restart_count}" != "10000" ]]; then
  echo "expected 10000 rows after full-fleet restart, got ${restart_count}" >&2
  exit 1
fi

for name in "${nodes[@]}"; do
  logs="$(docker logs "${name}" 2>&1 || true)"
  if grep -Fq 'entrypoint_multinode_secret' <<< "${logs}"; then
    echo "database password leaked into ${name} logs" >&2
    exit 1
  fi
  if grep -Fq 'entrypoint-multinode-fake-token' <<< "${logs}"; then
    echo "Cloudflare token leaked into ${name} logs" >&2
    exit 1
  fi
  if grep -Fq 'entrypoint_child_secret' <<< "${logs}"; then
    echo "delegated user password leaked into ${name} logs" >&2
    exit 1
  fi
done

echo "${test_node_count}-node entrypoint smoke ok"
