#!/usr/bin/env bash
set -euo pipefail

image="${1:-deeploy-cockroachdb-service:local}"
network="deeploy-crdb-multinode-smoke"
node1="deeploy-crdb-multinode-smoke-1"
node2="deeploy-crdb-multinode-smoke-2"
tmp="$(mktemp -d /tmp/deeploy-crdb-multinode.XXXXXX)"

cleanup() {
  local status=$?
  local cleanup_failed=0
  trap - EXIT
  if [[ "${status}" != "0" ]]; then
    docker logs "${node1}" >&2 2>/dev/null || true
    docker logs "${node2}" >&2 2>/dev/null || true
  fi
  docker rm -f "${node1}" "${node2}" >/dev/null 2>&1 || true
  docker inspect "${node1}" >/dev/null 2>&1 && cleanup_failed=1
  docker inspect "${node2}" >/dev/null 2>&1 && cleanup_failed=1
  docker network rm "${network}" >/dev/null 2>&1 || true
  docker network inspect "${network}" >/dev/null 2>&1 && cleanup_failed=1
  docker run --rm -v "${tmp}:/cleanup" --entrypoint /bin/sh "${image}" \
    -c 'rm -rf /cleanup/* /cleanup/.[!.]* /cleanup/..?*' >/dev/null 2>&1 || cleanup_failed=1
  rmdir "${tmp}" >/dev/null 2>&1 || cleanup_failed=1
  if [[ "${status}" == "0" && "${cleanup_failed}" != "0" ]]; then
    echo "local multinode smoke cleanup failed" >&2
    status=1
  fi
  exit "${status}"
}
trap cleanup EXIT

mkdir -p "${tmp}/certs" "${tmp}/roach1" "${tmp}/roach2"

docker run --rm -u "$(id -u):$(id -g)" -v "${tmp}/certs:/certs" --entrypoint /cockroach/cockroach "${image}" \
  cert create-ca --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
docker run --rm -u "$(id -u):$(id -g)" -v "${tmp}/certs:/certs" --entrypoint /cockroach/cockroach "${image}" \
  cert create-node roach1 roach2 localhost 127.0.0.1 --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
docker run --rm -u "$(id -u):$(id -g)" -v "${tmp}/certs:/certs" --entrypoint /cockroach/cockroach "${image}" \
  cert create-client root --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
rm -f "${tmp}/certs/ca.key"

docker network create "${network}" >/dev/null

docker run -d --name "${node1}" --hostname roach1 --network "${network}" --network-alias roach1 \
  -v "${tmp}/certs:/certs:ro" \
  -v "${tmp}/roach1:/store" \
  --entrypoint /cockroach/cockroach \
  "${image}" start \
  --certs-dir=/certs \
  --store=/store \
  --listen-addr=roach1:26257 \
  --advertise-addr=roach1:26257 \
  --http-addr=roach1:8080 \
  --join=roach1:26257,roach2:26257 \
  --cache=.25 \
  --max-sql-memory=.25 >/dev/null

docker run -d --name "${node2}" --hostname roach2 --network "${network}" --network-alias roach2 \
  -v "${tmp}/certs:/certs:ro" \
  -v "${tmp}/roach2:/store" \
  --entrypoint /cockroach/cockroach \
  "${image}" start \
  --certs-dir=/certs \
  --store=/store \
  --listen-addr=roach2:26257 \
  --advertise-addr=roach2:26257 \
  --http-addr=roach2:8080 \
  --join=roach1:26257,roach2:26257 \
  --cache=.25 \
  --max-sql-memory=.25 >/dev/null

for _ in $(seq 1 90); do
  if docker exec "${node1}" /cockroach/cockroach init --certs-dir=/certs --host=roach1:26257 >/dev/null 2>&1; then
    break
  fi
  if docker exec "${node1}" /cockroach/cockroach sql --certs-dir=/certs --host=roach1:26257 -e "select 1" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

docker exec "${node1}" /cockroach/cockroach sql --certs-dir=/certs --host=roach1:26257 \
  -e "create database if not exists smoke_multi;" \
  -e "create table if not exists smoke_multi.items (id int primary key, note string);" \
  -e "upsert into smoke_multi.items values (1, 'roach1'), (2, 'roach2');" >/dev/null

count="$(docker exec "${node2}" /cockroach/cockroach sql --certs-dir=/certs --host=roach2:26257 --format=csv \
  -e "select count(*) from smoke_multi.items;" | tail -n 1 | tr -d '\r')"
if [[ "${count}" != "2" ]]; then
  echo "expected replicated row count 2, got ${count}" >&2
  exit 1
fi

node_count="$(docker exec "${node1}" /cockroach/cockroach sql --certs-dir=/certs --host=roach1:26257 --format=csv \
  -e "select count(*) from crdb_internal.gossip_nodes;" | tail -n 1 | tr -d '\r')"
if [[ "${node_count}" != "2" ]]; then
  echo "expected 2 gossip nodes, got ${node_count}" >&2
  exit 1
fi

echo "local multinode smoke ok"
