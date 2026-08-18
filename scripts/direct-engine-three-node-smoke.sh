#!/usr/bin/env bash
set -euo pipefail

image="${1:?usage: direct-engine-three-node-smoke.sh <image-ref> [run-id]}"
run_id="${2:-$$-${RANDOM}}"
network="r1-meshdb-direct-${run_id}"
tmp="$(mktemp -d /tmp/r1-meshdb-direct.XXXXXX)"
nodes=("r1-meshdb-direct-1-${run_id}" "r1-meshdb-direct-2-${run_id}" "r1-meshdb-direct-3-${run_id}")
volumes=("r1-meshdb-direct-store-1-${run_id}" "r1-meshdb-direct-store-2-${run_id}" "r1-meshdb-direct-store-3-${run_id}")

cleanup() {
  local status=$?
  local failed=0
  trap - EXIT
  if [[ "${status}" != "0" ]]; then
    for node in "${nodes[@]}"; do
      docker logs "${node}" >&2 2>/dev/null || true
    done
  fi
  docker rm -f "${nodes[@]}" >/dev/null 2>&1 || true
  for node in "${nodes[@]}"; do
    docker inspect "${node}" >/dev/null 2>&1 && failed=1
  done
  docker volume rm -f "${volumes[@]}" >/dev/null 2>&1 || true
  for volume in "${volumes[@]}"; do
    docker volume inspect "${volume}" >/dev/null 2>&1 && failed=1
  done
  docker network rm "${network}" >/dev/null 2>&1 || true
  docker network inspect "${network}" >/dev/null 2>&1 && failed=1
  docker run --rm -v "${tmp}:/cleanup" --entrypoint /bin/sh "${image}" \
    -c 'rm -rf /cleanup/* /cleanup/.[!.]* /cleanup/..?*' >/dev/null 2>&1 || failed=1
  rmdir "${tmp}" >/dev/null 2>&1 || failed=1
  if [[ "${status}" == "0" && "${failed}" != "0" ]]; then
    echo "direct engine smoke cleanup failed" >&2
    status=1
  fi
  exit "${status}"
}
trap cleanup EXIT

mkdir -p "${tmp}/certs"
docker run --rm -u "$(id -u):$(id -g)" -v "${tmp}/certs:/certs" \
  --entrypoint /cockroach/cockroach "${image}" cert create-ca \
  --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
docker run --rm -u "$(id -u):$(id -g)" -v "${tmp}/certs:/certs" \
  --entrypoint /cockroach/cockroach "${image}" cert create-node \
  roach1 roach2 roach3 localhost 127.0.0.1 \
  --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
docker run --rm -u "$(id -u):$(id -g)" -v "${tmp}/certs:/certs" \
  --entrypoint /cockroach/cockroach "${image}" cert create-client root \
  --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
find "${tmp}/certs" -maxdepth 1 -name ca.key -delete
docker network create "${network}" >/dev/null
for volume in "${volumes[@]}"; do
  docker volume create "${volume}" >/dev/null
done

for index in 1 2 3; do
  docker run -d --name "${nodes[$((index - 1))]}" --hostname "roach${index}" \
    --network "${network}" --network-alias "roach${index}" \
    -v "${tmp}/certs:/certs:ro" \
    -v "${volumes[$((index - 1))]}:/store" \
    --entrypoint /cockroach/cockroach "${image}" start \
    --certs-dir=/certs \
    --store=/store \
    --listen-addr="roach${index}:26257" \
    --advertise-addr="roach${index}:26257" \
    --http-addr="roach${index}:8080" \
    --join=roach1:26257,roach2:26257,roach3:26257 \
    --max-offset=500ms \
    --cache=.25 \
    --max-sql-memory=.25 >/dev/null
done

ready=false
for _ in $(seq 1 120); do
  docker exec "${nodes[0]}" timeout --kill-after=2s 15s /cockroach/cockroach init \
    --certs-dir=/certs --host=roach1:26257 >/dev/null 2>&1 || true
  if docker exec "${nodes[0]}" timeout --kill-after=2s 20s /cockroach/cockroach sql \
    --certs-dir=/certs --host=roach1:26257 -e 'select 1' >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
[[ "${ready}" == "true" ]] || { echo "direct three-node cluster was not SQL-ready" >&2; exit 1; }

docker exec "${nodes[0]}" timeout --kill-after=2s 30s /cockroach/cockroach sql \
  --certs-dir=/certs --host=roach1:26257 \
  -e 'create database if not exists r1_smoke;' \
  -e 'create table if not exists r1_smoke.items (id int primary key, note string);' \
  -e "upsert into r1_smoke.items select i, 'row-' || i::string from generate_series(1, 10000) as g(i);" >/dev/null

replication_ready=false
incomplete_voter_sets=""
for _ in $(seq 1 300); do
  incomplete_voter_sets="$(docker exec "${nodes[1]}" \
    timeout --kill-after=2s 20s /cockroach/cockroach sql \
    --certs-dir=/certs --host=roach2:26257 --format=csv \
    -e "select count(*) from crdb_internal.ranges_no_leases where array_length(voting_replicas, 1) < 3 or array_length(learner_replicas, 1) > 0;" \
    2>/dev/null | tail -n 1 | tr -d '\r' || true)"
  if [[ "${incomplete_voter_sets}" == "0" ]]; then
    replication_ready=true
    break
  fi
  sleep 1
done
if [[ "${replication_ready}" != "true" ]]; then
  echo "direct cluster remained under-replicated: incomplete=${incomplete_voter_sets:-unknown}" >&2
  docker exec "${nodes[0]}" timeout --kill-after=2s 20s /cockroach/cockroach node status \
    --certs-dir=/certs --host=roach1:26257 >&2 2>/dev/null || true
  docker exec "${nodes[0]}" timeout --kill-after=2s 20s /cockroach/cockroach sql \
    --certs-dir=/certs --host=roach1:26257 \
    -e "select range_id, start_pretty, voting_replicas, learner_replicas from crdb_internal.ranges_no_leases where array_length(voting_replicas, 1) < 3 or array_length(learner_replicas, 1) > 0 order by range_id;" \
    >&2 2>/dev/null || true
  exit 1
fi

count="$(docker exec "${nodes[2]}" timeout --kill-after=2s 20s /cockroach/cockroach sql \
  --certs-dir=/certs --host=roach3:26257 --format=csv \
  -e 'select count(*) from r1_smoke.items;' | tail -n 1 | tr -d '\r')"
[[ "${count}" == "10000" ]] || { echo "expected 10000 rows through node 3, got ${count}" >&2; exit 1; }

docker stop --time 15 "${nodes[0]}" >/dev/null
surviving_count="$(timeout 60 docker exec "${nodes[1]}" \
  timeout --kill-after=2s 20s /cockroach/cockroach sql \
  --certs-dir=/certs --host=roach2:26257 --format=csv \
  -e 'select count(*) from r1_smoke.items;' | tail -n 1 | tr -d '\r')"
[[ "${surviving_count}" == "10000" ]] || { echo "one-node failure lost availability" >&2; exit 1; }
docker start "${nodes[0]}" >/dev/null

docker stop --time 15 "${nodes[@]}" >/dev/null
docker start "${nodes[@]}" >/dev/null
restart_count=""
for _ in $(seq 1 180); do
  restart_count="$(docker exec "${nodes[2]}" \
    timeout --kill-after=2s 20s /cockroach/cockroach sql \
    --certs-dir=/certs --host=roach3:26257 --format=csv \
    -e 'select count(*) from r1_smoke.items;' 2>/dev/null | tail -n 1 | tr -d '\r' || true)"
  [[ "${restart_count}" == "10000" ]] && break
  sleep 1
done
[[ "${restart_count}" == "10000" ]] || { echo "data unavailable after full restart" >&2; exit 1; }

echo "direct exact-image three-node smoke ok"
