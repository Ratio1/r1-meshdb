#!/usr/bin/env bash
set -euo pipefail

image="${1:-deeploy-crdb-runtime-supervision:local}"
run_id="${2:-$$-${RANDOM}}"
test_max_offset="${CRDB_TEST_MAX_OFFSET:-500ms}"
network="deeploy-crdb-entrypoint-${run_id}"
node1="deeploy-crdb-entrypoint-1-${run_id}"
node2="deeploy-crdb-entrypoint-2-${run_id}"
node3="deeploy-crdb-entrypoint-3-${run_id}"
tmp="$(mktemp -d /tmp/deeploy-crdb-entrypoint-multinode.XXXXXX)"

cleanup() {
  local status=$?
  local cleanup_failed=0
  trap - EXIT
  if [[ "${status}" != "0" ]]; then
    docker logs "${node1}" >&2 2>/dev/null || true
    docker logs "${node2}" >&2 2>/dev/null || true
    docker logs "${node3}" >&2 2>/dev/null || true
  fi
  docker rm -f "${node1}" "${node2}" "${node3}" >/dev/null 2>&1 || true
  docker inspect "${node1}" >/dev/null 2>&1 && cleanup_failed=1
  docker inspect "${node2}" >/dev/null 2>&1 && cleanup_failed=1
  docker inspect "${node3}" >/dev/null 2>&1 && cleanup_failed=1
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

mkdir -p "${tmp}/certs" "${tmp}/token" "${tmp}/roach1" "${tmp}/roach2" "${tmp}/roach3"
printf 'entrypoint-multinode-fake-token\n' > "${tmp}/token/cf-token"
docker run --rm -v "${tmp}:/testbed" --entrypoint /bin/sh "${image}" \
  -c 'chown 0:0 /testbed/roach1 /testbed/roach2 /testbed/roach3 && chmod 700 /testbed/roach1 /testbed/roach2 /testbed/roach3'

docker run --rm -u "$(id -u):$(id -g)" -v "${tmp}/certs:/certs" --entrypoint /cockroach/cockroach "${image}" \
  cert create-ca --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
docker run --rm -u "$(id -u):$(id -g)" -v "${tmp}/certs:/certs" --entrypoint /cockroach/cockroach "${image}" \
  cert create-node roach1 roach2 roach3 localhost 127.0.0.1 --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
docker run --rm -u "$(id -u):$(id -g)" -v "${tmp}/certs:/certs" --entrypoint /cockroach/cockroach "${image}" \
  cert create-client root --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
rm -f "${tmp}/certs/ca.key"

docker network create "${network}" >/dev/null

start_node() {
  local node_id="$1"
  local name="$2"
  # Docker Desktop can pause proxy-heavy test containers long enough to exceed
  # the production 500ms clock limit; this test validates topology/lifecycle.
  docker run -d --name "${name}" --hostname "roach${node_id}" \
    --network "${network}" --network-alias "target-roach${node_id}" \
    -v "${tmp}/certs:/test-certs:ro" \
    -v "${tmp}/certs/ca.crt:/runtime/ca.crt:ro" \
    -v "${tmp}/certs/node.crt:/runtime/node.crt:ro" \
    -v "${tmp}/certs/node.key:/runtime/node.key:ro" \
    -v "${tmp}/certs/client.root.crt:/runtime/client.root.crt:ro" \
    -v "${tmp}/certs/client.root.key:/runtime/client.root.key:ro" \
    -v "${tmp}/token/cf-token:/runtime/cf-token:ro" \
    -v "${tmp}/roach${node_id}:/cockroach/cockroach-data" \
    -e "CRDB_NODE_ID=${node_id}" \
    -e CRDB_NODE_COUNT=3 \
    -e CRDB_HOSTNAMES=roach1.local,roach2.local,roach3.local \
    -e CRDB_DATABASE=appdb \
    -e CRDB_USER=app_user \
    -e CRDB_PASSWORD=entrypoint_multinode_secret \
    -e CRDB_LISTEN_HOST=0.0.0.0 \
    -e "CRDB_MAX_OFFSET=${test_max_offset}" \
    -e CRDB_CA_CRT_FILE=/runtime/ca.crt \
    -e CRDB_NODE_CRT_FILE=/runtime/node.crt \
    -e CRDB_NODE_KEY_FILE=/runtime/node.key \
    -e CRDB_CLIENT_ROOT_CRT_FILE=/runtime/client.root.crt \
    -e CRDB_CLIENT_ROOT_KEY_FILE=/runtime/client.root.key \
    -e CF_TUNNEL_TOKEN_FILE=/runtime/cf-token \
    -e TEST_CLOUDFLARED_ACCESS_MODE=proxy \
    -e CRDB_BOOTSTRAP_TIMEOUT_SECONDS=60 \
    "${image}" >/dev/null
}

start_node 2 "${node2}"
start_node 3 "${node3}"
start_node 1 "${node1}"

ready=0
for _ in $(seq 1 120); do
  if docker exec -e PGPASSWORD=entrypoint_multinode_secret "${node1}" /cockroach/cockroach sql \
    --url "postgresql://app_user@roach1:26257/appdb?sslmode=require" \
    -e "select 1" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "${ready}" != "1" ]]; then
  echo "three-node entrypoint cluster did not become SQL-ready" >&2
  exit 1
fi

docker exec -e PGPASSWORD=entrypoint_multinode_secret "${node1}" /cockroach/cockroach sql \
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
docker exec -i -e PGPASSWORD=entrypoint_multinode_secret "${node2}" /cockroach/cockroach sql \
  --set=errexit=true \
  --url "postgresql://app_user@roach2:26257/appdb?sslmode=require" \
  < "${operator_sql}" >/dev/null
rm -f "${operator_sql}"

docker exec -e PGPASSWORD=entrypoint_child_secret "${node3}" /cockroach/cockroach sql \
  --url "postgresql://entrypoint_child@roach3:26257/entrypoint_operator?sslmode=require" \
  -e "create table if not exists delegated_items (id int primary key, note string);" \
  -e "upsert into delegated_items values (1, 'node3');" >/dev/null

row_count="$(docker exec -e PGPASSWORD=entrypoint_multinode_secret "${node2}" /cockroach/cockroach sql \
  --url "postgresql://app_user@roach2:26257/appdb?sslmode=require" \
  --format=csv -e "select count(*) from entrypoint_smoke;" | tail -n 1 | tr -d '\r')"
if [[ "${row_count}" != "10000" ]]; then
  echo "expected replicated row count 10000, got ${row_count}" >&2
  exit 1
fi

node_count="$(docker exec "${node1}" /cockroach/cockroach sql \
  --certs-dir=/cockroach/certs --host=roach1:26257 \
  --format=csv -e "select count(*) from crdb_internal.gossip_nodes;" | tail -n 1 | tr -d '\r')"
if [[ "${node_count}" != "3" ]]; then
  echo "expected 3 gossip nodes, got ${node_count}" >&2
  exit 1
fi

role_option_count="$(docker exec "${node3}" /cockroach/cockroach sql \
  --certs-dir=/test-certs --host=roach3:26257 --format=csv \
  -e "select count(*) from [show users] where username = 'app_user' and options like '%CREATEDB%' and options like '%CREATEROLE%' and options like '%CREATELOGIN%';" \
  | tail -n 1 | tr -d '\r')"
if [[ "${role_option_count}" != "1" ]]; then
  echo "configured operator privileges were not visible through node 3" >&2
  exit 1
fi

replication_ready=false
for _ in $(seq 1 120); do
  under_replicated="$(docker exec "${node1}" /cockroach/cockroach sql \
    --certs-dir=/cockroach/certs --host=roach1:26257 --format=csv \
    -e "select coalesce(sum((metrics->>'ranges.underreplicated')::int), 0) from crdb_internal.kv_store_status;" \
    2>/dev/null | tail -n 1 | tr -d '\r' || true)"
  if [[ "${under_replicated}" == "0" ]]; then
    replication_ready=true
    break
  fi
  sleep 1
done
if [[ "${replication_ready}" != "true" ]]; then
  echo "three-node cluster did not reach full replication before failover" >&2
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
  echo "three-node cluster lost delegated data with one node stopped" >&2
  exit 1
fi
docker start "${node1}" >/dev/null
for _ in $(seq 1 120); do
  if docker exec -e PGPASSWORD=entrypoint_multinode_secret "${node1}" /cockroach/cockroach sql \
    --url "postgresql://app_user@roach1:26257/appdb?sslmode=require" \
    -e "select 1" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
rejoined_count="$(docker exec -e PGPASSWORD=entrypoint_child_secret "${node1}" /cockroach/cockroach sql \
  --url "postgresql://entrypoint_child@roach1:26257/entrypoint_operator?sslmode=require" \
  --format=csv -e "select count(*) from delegated_items;" | tail -n 1 | tr -d '\r')"
if [[ "${rejoined_count}" != "1" ]]; then
  echo "delegated data was not readable after node 1 rejoined" >&2
  exit 1
fi

docker stop --time 15 "${node1}" "${node2}" "${node3}" >/dev/null
docker start "${node1}" "${node2}" "${node3}" >/dev/null
restart_count=""
restart_deadline=$(( $(date +%s) + 180 ))
while [[ "$(date +%s)" -lt "${restart_deadline}" ]]; do
  restart_count="$(docker exec -e PGPASSWORD=entrypoint_multinode_secret "${node3}" \
    /cockroach/cockroach sql \
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

for name in "${node1}" "${node2}" "${node3}"; do
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

echo "entrypoint multinode smoke ok"
