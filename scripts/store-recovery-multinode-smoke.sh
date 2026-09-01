#!/usr/bin/env bash
set -euo pipefail

image="${1:-deeploy-crdb-runtime-supervision:local}"
run_id="${2:-$$-${RANDOM}}"
# This topology test isolates Docker Desktop clock skew; production stays at 500ms.
test_max_offset="${CRDB_TEST_MAX_OFFSET:-5s}"
network="deeploy-crdb-recovery-multinode-${run_id}"
test_label="com.ratio1.deeploy-crdb-recovery-multinode=${run_id}"
runtime_volume="deeploy-crdb-recovery-runtime-${run_id}"
nodes=(
  "deeploy-crdb-recovery-node1-${run_id}"
  "deeploy-crdb-recovery-node2-${run_id}"
  "deeploy-crdb-recovery-node3-${run_id}"
)
stores=(
  "deeploy-crdb-recovery-store1-${run_id}"
  "deeploy-crdb-recovery-store2-${run_id}"
  "deeploy-crdb-recovery-store3-${run_id}"
)
volumes=("${runtime_volume}" "${stores[@]}")

sanitize_diagnostic() {
  sed -E \
    -e 's/store_recovery_multinode_secret/[REDACTED_DB_PASSWORD]/g' \
    -e 's/store_recovery_canary_secret/[REDACTED_CANARY_PASSWORD]/g' \
    -e 's/store-recovery-multinode-fake-token/[REDACTED_TUNNEL_TOKEN]/g' \
    -e 's/(PGPASSWORD=)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/-----BEGIN [^-]*PRIVATE KEY-----/[REDACTED_PRIVATE_KEY]/g' \
    -e 's/-----END [^-]*PRIVATE KEY-----/[REDACTED_PRIVATE_KEY]/g'
}

cleanup() {
  local status=$?
  local cleanup_failed=0
  local name volume
  trap - EXIT
  if [[ "${status}" != "0" ]]; then
    for name in "${nodes[@]}"; do
      timeout 15s docker logs --tail 200 "${name}" 2>&1 | sanitize_diagnostic >&2 || true
      timeout 15s docker exec "${name}" sh -c \
        'find /cockroach/cockroach-data/logs -type f -name "*.log" -exec grep -hE "r4|quorum|unavailable|acquire lease|leaseholder|liveness" {} + 2>/dev/null | tail -n 120' \
        2>&1 | sanitize_diagnostic >&2 || true
    done
  fi
  docker ps -aq --filter "label=${test_label}" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker ps -aq --filter "label=${test_label}" | grep -q . && cleanup_failed=1
  for volume in "${volumes[@]}"; do
    docker volume rm "${volume}" >/dev/null 2>&1 || true
    docker volume inspect "${volume}" >/dev/null 2>&1 && cleanup_failed=1
  done
  docker network rm "${network}" >/dev/null 2>&1 || true
  docker network inspect "${network}" >/dev/null 2>&1 && cleanup_failed=1
  if [[ "${status}" == "0" && "${cleanup_failed}" != "0" ]]; then
    echo "store recovery multinode cleanup failed" >&2
    status=1
  fi
  exit "${status}"
}
trap cleanup EXIT

for volume in "${volumes[@]}"; do
  docker volume create --label "${test_label}" "${volume}" >/dev/null
done
for store in "${stores[@]}"; do
  docker run --rm -v "${store}:/store" --entrypoint /bin/sh "${image}" \
    -c 'chown 0:0 /store && chmod 700 /store'
done

docker run --rm -v "${runtime_volume}:/runtime" --entrypoint /bin/sh "${image}" \
  -c 'mkdir -m 700 /runtime/certs /runtime/token && printf "store-recovery-multinode-fake-token\n" > /runtime/token/cf-token'
docker run --rm -v "${runtime_volume}:/runtime" \
  --entrypoint /cockroach/cockroach-real "${image}" \
  cert create-ca --certs-dir=/runtime/certs --ca-key=/runtime/certs/ca.key >/dev/null
docker run --rm -v "${runtime_volume}:/runtime" \
  --entrypoint /cockroach/cockroach-real "${image}" \
  cert create-node roach1 roach2 roach3 localhost 127.0.0.1 \
  --certs-dir=/runtime/certs --ca-key=/runtime/certs/ca.key >/dev/null
docker run --rm -v "${runtime_volume}:/runtime" \
  --entrypoint /cockroach/cockroach-real "${image}" \
  cert create-client root --certs-dir=/runtime/certs --ca-key=/runtime/certs/ca.key >/dev/null
docker run --rm -v "${runtime_volume}:/runtime" --entrypoint /bin/sh "${image}" \
  -c 'rm -f /runtime/certs/ca.key'

docker network create "${network}" >/dev/null

start_node() {
  local node_id="$1"
  local name="${nodes[$((node_id - 1))]}"
  # Bind mounts share the host filesystem; capacity behavior has separate tests.
  docker run -d --name "${name}" --hostname "roach${node_id}" \
    --label "${test_label}" \
    --network "${network}" --network-alias "target-roach${node_id}" \
    -v "${runtime_volume}:/runtime:ro" \
    -v "${stores[$((node_id - 1))]}:/cockroach/cockroach-data" \
    -e "CRDB_NODE_ID=${node_id}" \
    -e CRDB_NODE_COUNT=3 \
    -e CRDB_HOSTNAMES=roach1.local,roach2.local,roach3.local \
    -e CRDB_DATABASE=appdb \
    -e CRDB_USER=app_user \
    -e CRDB_PASSWORD=store_recovery_multinode_secret \
    -e CRDB_LISTEN_HOST=0.0.0.0 \
    -e "CRDB_MAX_OFFSET=${test_max_offset}" \
    -e CRDB_CA_CRT_FILE=/runtime/certs/ca.crt \
    -e CRDB_NODE_CRT_FILE=/runtime/certs/node.crt \
    -e CRDB_NODE_KEY_FILE=/runtime/certs/node.key \
    -e CRDB_CLIENT_ROOT_CRT_FILE=/runtime/certs/client.root.crt \
    -e CRDB_CLIENT_ROOT_KEY_FILE=/runtime/certs/client.root.key \
    -e CF_TUNNEL_TOKEN_FILE=/runtime/token/cf-token \
    -e TEST_CLOUDFLARED_ACCESS_MODE=proxy \
    -e CRDB_BOOTSTRAP_TIMEOUT_SECONDS=120 \
    -e TEST_DF_USED_KB=1024 \
    -e TEST_DF_AVAILABLE_KB=2097152 \
    -e TEST_DF_USED_INODES=1000 \
    -e TEST_DF_AVAILABLE_INODES=100000 \
    "${image}" >/dev/null
}

wait_for_exit() {
  local name="$1"
  local timeout_seconds="${2:-20}"
  local deadline=$(( $(date +%s) + timeout_seconds ))
  while [[ "$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || true)" == "true" ]]; do
    if [[ "$(date +%s)" -ge "${deadline}" ]]; then
      echo "timed out waiting for ${name} to exit" >&2
      return 1
    fi
    sleep 0.25
  done
}

app_sql_on() {
  local node_id="$1"
  shift
  docker exec -e PGPASSWORD=store_recovery_multinode_secret "${nodes[$((node_id - 1))]}" \
    /cockroach/cockroach-real sql \
    --url "postgresql://app_user@roach${node_id}:26257/appdb?sslmode=require" "$@"
}

canary_sql_on() {
  local node_id="$1"
  shift
  docker exec -e PGPASSWORD=store_recovery_canary_secret "${nodes[$((node_id - 1))]}" \
    /cockroach/cockroach-real sql \
    --url "postgresql://recovery_canary@roach${node_id}:26257/appdb?sslmode=require" "$@"
}

root_sql_on() {
  local node_id="$1"
  shift
  docker exec "${nodes[$((node_id - 1))]}" /cockroach/cockroach-real sql \
    --certs-dir=/runtime/certs --host="roach${node_id}:26257" "$@"
}

root_sql_on_node1() {
  root_sql_on 1 "$@"
}

wait_for_sql() {
  local node_id="$1"
  local timeout_seconds="${2:-180}"
  local deadline=$(( $(date +%s) + timeout_seconds ))
  while [[ "$(date +%s)" -lt "${deadline}" ]]; do
    if app_sql_on "${node_id}" -e 'select 1' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "node ${node_id} did not become SQL-ready" >&2
  return 1
}

wait_for_full_replication() {
  local deadline=$(( $(date +%s) + 300 ))
  local stability_seconds="${CRDB_TEST_REPLICATION_STABILITY_SECONDS:-30}"
  local stable_since="" now="" incomplete_ranges="" critical_ranges=""
  local applied_snapshots="" metadata_ready="" metadata_sample="" slot store_id
  local -A store_ids=()
  if [[ ! "${stability_seconds}" =~ ^[1-9][0-9]*$ || "${stability_seconds}" -gt 60 ]]; then
    echo "CRDB_TEST_REPLICATION_STABILITY_SECONDS must be an integer from 1 through 60" >&2
    return 1
  fi
  while [[ "$(date +%s)" -lt "${deadline}" ]]; do
    incomplete_ranges="$(root_sql_on_node1 --format=csv \
      -e 'select count(*) from crdb_internal.ranges_no_leases where array_length(voting_replicas, 1) < 3 or array_length(learner_replicas, 1) > 0;' \
      2>/dev/null | tail -n 1 | tr -d '\r' || true)"
    critical_ranges="$(root_sql_on_node1 --format=csv \
      -e 'select count(*) from crdb_internal.ranges where range_id in (1, 4) and array_length(replicas, 1) = 3;' \
      2>/dev/null | tail -n 1 | tr -d '\r' || true)"
    applied_snapshots=0
    metadata_ready=0
    for slot in 2 3; do
      if [[ -z "${store_ids[${slot}]:-}" ]]; then
        store_id="$(root_sql_on "${slot}" --format=csv \
          -e 'select crdb_internal.node_id();' 2>/dev/null | tail -n 1 | tr -d '\r' || true)"
        if [[ "${store_id}" =~ ^[1-9][0-9]*$ ]]; then
          store_ids["${slot}"]="${store_id}"
        fi
      fi
      metadata_sample="$(root_sql_on "${slot}" --format=csv \
        -e "select (select count(*) from system.users where username = 'app_user'), (select count(*) from system.role_members where member = 'app_user'), (select count(*) from system.role_options where username = 'app_user'), (select count(*) from appdb.public.recovery_smoke);" \
        2>/dev/null | tail -n 1 | tr -d '\r' || true)"
      if [[ "${metadata_sample}" =~ ^1,[0-9]+,[0-9]+,1000$ ]]; then
        metadata_ready=$((metadata_ready + 1))
      fi
      for range_id in 1 4; do
        store_id="${store_ids[${slot}]:-}"
        if [[ -n "${store_id}" ]] && docker exec "${nodes[$((slot - 1))]}" sh -c \
          "find /cockroach/cockroach-data/logs -type f -name '*.log' -exec grep -hF 's${store_id},r${range_id}/' {} + 2>/dev/null | grep -Fq 'applying INITIAL snapshot'"; then
          applied_snapshots=$((applied_snapshots + 1))
        fi
      done
    done
    now="$(date +%s)"
    if [[ "${incomplete_ranges}" == "0" && "${critical_ranges}" == "2" && \
          "${applied_snapshots}" == "4" && "${metadata_ready}" == "2" ]]; then
      if [[ -z "${stable_since}" ]]; then
        stable_since="${now}"
        echo "exact three-voter replication and survivor metadata reads are stable; observing for ${stability_seconds} seconds" >&2
      elif [[ $((now - stable_since)) -ge "${stability_seconds}" ]]; then
        return 0
      fi
    else
      if [[ -n "${stable_since}" ]]; then
        echo "replication readiness changed during the stability window; restarting observation" >&2
      fi
      stable_since=""
    fi
    sleep 1
  done
  echo "cluster replication did not remain stable: incomplete=${incomplete_ranges:-unknown}, critical=${critical_ranges:-unknown}/2, applied-snapshots=${applied_snapshots:-unknown}/4, survivor-metadata=${metadata_ready:-unknown}/2" >&2
  return 1
}

emit_survivor_diagnostics() {
  local node_id="$1"
  local name="${nodes[$((node_id - 1))]}"
  local diagnostic=""
  docker inspect "${name}" \
    --format 'container={{.Name}} status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' \
    2>&1 | sanitize_diagnostic >&2 || true
  diagnostic="$(timeout 15s docker exec "${name}" /cockroach/cockroach-real sql \
    --certs-dir=/runtime/certs --host="roach${node_id}:26257" --format=csv \
    -e 'select count(*) as gossip_nodes from crdb_internal.gossip_nodes; select count(*) as incomplete_ranges from crdb_internal.ranges_no_leases where array_length(voting_replicas, 1) < 3 or array_length(learner_replicas, 1) > 0; select range_id, lease_holder, replicas from crdb_internal.ranges where range_id in (1, 4) order by range_id;' \
    2>&1 || true)"
  printf '%s\n' "${diagnostic}" | sanitize_diagnostic | tail -n 40 >&2
}

wait_for_recovered_replication() {
  local node_id="$1"
  local retired_node_id="$2"
  local deadline=$(( $(date +%s) + 240 ))
  local under_replicated="" store_replicas="" table_ranges="" retired_ranges=""
  while [[ "$(date +%s)" -lt "${deadline}" ]]; do
    under_replicated="$(root_sql_on_node1 --format=csv \
      -e "select coalesce(sum((metrics->>'ranges.underreplicated')::int), 0) from crdb_internal.kv_store_status;" \
      2>/dev/null | tail -n 1 | tr -d '\r' || true)"
    store_replicas="$(root_sql_on_node1 --format=csv \
      -e "select coalesce(sum((metrics->>'replicas')::int), 0) from crdb_internal.kv_store_status where node_id = ${node_id};" \
      2>/dev/null | tail -n 1 | tr -d '\r' || true)"
    table_ranges="$(root_sql_on_node1 --format=csv \
      -e "select count(*) from [show ranges from table appdb.public.recovery_smoke] where ${node_id} = any(replicas);" \
      2>/dev/null | tail -n 1 | tr -d '\r' || true)"
    retired_ranges="$(root_sql_on_node1 --format=csv \
      -e "select count(*) from crdb_internal.ranges where ${retired_node_id} = any(replicas);" \
      2>/dev/null | tail -n 1 | tr -d '\r' || true)"
    if [[ "${under_replicated}" == "0" && "${store_replicas}" =~ ^[1-9][0-9]*$ && \
          "${table_ranges}" =~ ^[1-9][0-9]*$ && "${retired_ranges}" == "0" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "recovered node did not fully replace retired node ${retired_node_id}: node=${node_id}, under-replicated=${under_replicated:-unknown}, store-replicas=${store_replicas:-unknown}, table-ranges=${table_ranges:-unknown}, retired-ranges=${retired_ranges:-unknown}" >&2
  return 1
}

retry_app_sql() {
  local node_id="$1"
  shift
  local started_at output=""
  started_at="$(date +%s)"
  local deadline=$((started_at + ${CRDB_TEST_OUTAGE_TIMEOUT_SECONDS:-180}))
  while [[ "$(date +%s)" -lt "${deadline}" ]]; do
    if output="$(app_sql_on "${node_id}" "$@" 2>&1)"; then
      printf '%s\n' "${output}"
      echo "node ${node_id} accepted the post-failure SQL operation after $(( $(date +%s) - started_at )) seconds" >&2
      return 0
    fi
    sleep 1
  done
  printf '%s\n' "${output}" | sanitize_diagnostic >&2
  echo "node ${node_id} did not accept the post-failure app-user SQL operation" >&2
  emit_survivor_diagnostics "${node_id}"
  return 1
}

retry_canary_sql() {
  local node_id="$1"
  shift
  local started_at output=""
  started_at="$(date +%s)"
  local deadline=$((started_at + ${CRDB_TEST_OUTAGE_TIMEOUT_SECONDS:-180}))
  while [[ "$(date +%s)" -lt "${deadline}" ]]; do
    if output="$(canary_sql_on "${node_id}" "$@" 2>&1)"; then
      printf '%s\n' "${output}"
      echo "node ${node_id} accepted the cold canary authentication after $(( $(date +%s) - started_at )) seconds" >&2
      return 0
    fi
    sleep 1
  done
  printf '%s\n' "${output}" | sanitize_diagnostic >&2
  echo "node ${node_id} did not accept the post-failure cold canary authentication" >&2
  emit_survivor_diagnostics "${node_id}"
  return 1
}

inject_corruption_and_kill() {
  local name="$1"
  docker exec "${name}" sh -c '
    for command_file in /proc/[0-9]*/cmdline; do
      command="$(tr "\0" " " 2>/dev/null < "${command_file}" || true)"
      case "${command}" in
        "/cockroach/cockroach-real start "*)
          pid="${command_file#/proc/}"
          pid="${pid%/cmdline}"
          log_dir=""
          for arg in $(tr "\0" "\n" < "${command_file}"); do
            case "${arg}" in --log-dir=*) log_dir="${arg#--log-dir=}" ;; esac
          done
          test -n "${log_dir}"
          printf "%s\n" "F000000 00:00:00.000000 1 storage: local corruption detected: pebble/table: invalid table 004786 (checksum mismatch at 937483/2360)" \
            >> "${log_dir}/deeploy-current-corruption.log"
          sync "${log_dir}/deeploy-current-corruption.log" || true
          kill -KILL "${pid}"
          exit 0
          ;;
      esac
    done
    exit 1
  '
}

inspect_node1_store() {
  local command="$1"
  docker run --rm -v "${stores[0]}:/store" --entrypoint /bin/sh "${image}" -c "${command}"
}

start_node 3
start_node 2
start_node 1
wait_for_sql 1

root_sql_on_node1 -e "SET CLUSTER SETTING server.time_until_store_dead = '1m';" >/dev/null
root_sql_on_node1 -e "CREATE TABLE IF NOT EXISTS appdb.public.recovery_smoke (id INT PRIMARY KEY, payload STRING);" >/dev/null
root_sql_on_node1 -e "UPSERT INTO appdb.public.recovery_smoke SELECT i, repeat('before-', 16) FROM generate_series(1, 1000) AS g(i);" >/dev/null
root_sql_on_node1 -e "GRANT ALL ON TABLE appdb.public.recovery_smoke TO app_user;" >/dev/null
root_sql_on_node1 -e "CREATE USER IF NOT EXISTS recovery_canary WITH PASSWORD 'store_recovery_canary_secret';" >/dev/null
root_sql_on_node1 -e "GRANT CONNECT ON DATABASE appdb TO recovery_canary; GRANT USAGE ON SCHEMA appdb.public TO recovery_canary; GRANT SELECT ON TABLE appdb.public.recovery_smoke TO recovery_canary;" >/dev/null
wait_for_full_replication

gossip_count="$(root_sql_on_node1 --format=csv -e 'select count(*) from crdb_internal.gossip_nodes;' | tail -n 1 | tr -d '\r')"
if [[ "${gossip_count}" != "3" ]]; then
  echo "expected three live gossip nodes before recovery, got ${gossip_count}" >&2
  exit 1
fi
old_node_id="$(root_sql_on_node1 --format=csv -e 'select crdb_internal.node_id();' | tail -n 1 | tr -d '\r')"

inspect_node1_store "printf 'forensic sentinel\n' > /store/forensic-sentinel"
sentinel_hash="$(inspect_node1_store "sha256sum /store/forensic-sentinel | cut -d ' ' -f 1")"
inject_corruption_and_kill "${nodes[0]}"
wait_for_exit "${nodes[0]}" 20
if [[ "$(docker inspect -f '{{.State.ExitCode}}' "${nodes[0]}")" != "137" ]]; then
  echo "recovery node did not preserve the killed R1 MeshDB status" >&2
  exit 1
fi
if ! inspect_node1_store 'test -f /store/.deeploy-recovery-v1/state && test ! -L /store/.deeploy-recovery-v1/state' || \
   [[ "$(inspect_node1_store "sha256sum /store/forensic-sentinel | cut -d ' ' -f 1")" != "${sentinel_hash}" ]]; then
  echo "first corruption did not preserve the old store and allocate recovery state" >&2
  exit 1
fi

canary_count="$(retry_canary_sql 2 --format=csv -e 'select count(*) from recovery_smoke where id = 1;' | tail -n 1 | tr -d '\r')"
if [[ "${canary_count}" != "1" ]]; then
  echo "cold survivor authentication did not read replicated data after node 1 failed" >&2
  exit 1
fi
retry_app_sql 2 -e "UPSERT INTO recovery_smoke VALUES (1001, 'written-while-node1-down');" >/dev/null
outage_value="$(retry_app_sql 3 --format=csv -e 'select payload from recovery_smoke where id = 1001;' | tail -n 1 | tr -d '\r')"
if [[ "${outage_value}" != "written-while-node1-down" ]]; then
  echo "surviving quorum did not remain writable while node 1 was down" >&2
  exit 1
fi

docker start "${nodes[0]}" >/dev/null
wait_for_sql 1 240
new_node_id="$(root_sql_on_node1 --format=csv -e 'select crdb_internal.node_id();' | tail -n 1 | tr -d '\r')"
if [[ -z "${new_node_id}" || "${new_node_id}" == "${old_node_id}" ]]; then
  echo "recovered node did not join with a new R1 MeshDB node ID" >&2
  exit 1
fi
wait_for_recovered_replication "${new_node_id}" "${old_node_id}"
rejoined_value="$(app_sql_on 1 --format=csv -e 'select payload from recovery_smoke where id = 1001;' | tail -n 1 | tr -d '\r')"
if [[ "${rejoined_value}" != "written-while-node1-down" ]]; then
  echo "recovered node cannot read data committed during its outage" >&2
  exit 1
fi

gossip_count="$(root_sql_on_node1 --format=csv -e 'select count(*) from crdb_internal.gossip_nodes;' | tail -n 1 | tr -d '\r')"
if [[ ! "${gossip_count}" =~ ^[0-9]+$ || "${gossip_count}" -lt 3 ]]; then
  echo "recovered cluster has fewer than three gossip records: ${gossip_count}" >&2
  exit 1
fi

inject_corruption_and_kill "${nodes[0]}"
wait_for_exit "${nodes[0]}" 20
inspect_node1_store "test ! -e /store/.deeploy-recovery-v1/state && grep -Fxq 'state=started' /store/.deeploy-recovery-v1/exhausted"
if [[ "$(inspect_node1_store "find /store/.deeploy-recovery-v1 -mindepth 1 -maxdepth 1 -type d -name 'store.*' | wc -l")" != "1" ]]; then
  echo "second corruption created more than one recovery store" >&2
  exit 1
fi

docker start "${nodes[0]}" >/dev/null
wait_for_exit "${nodes[0]}" 10
if [[ "$(docker inspect -f '{{.State.ExitCode}}' "${nodes[0]}")" != "1" ]]; then
  echo "exhausted recovery did not fail closed before starting R1 MeshDB" >&2
  exit 1
fi
retry_app_sql 2 -e "UPSERT INTO recovery_smoke VALUES (1002, 'survivors-after-exhaustion');" >/dev/null
final_value="$(retry_app_sql 3 --format=csv -e 'select payload from recovery_smoke where id = 1002;' | tail -n 1 | tr -d '\r')"
if [[ "${final_value}" != "survivors-after-exhaustion" ]]; then
  echo "surviving quorum failed after recovery exhaustion" >&2
  exit 1
fi

for name in "${nodes[@]}"; do
  logs="$(docker logs "${name}" 2>&1 || true)"
  if grep -Fq 'store_recovery_multinode_secret' <<< "${logs}" || \
     grep -Fq 'store_recovery_canary_secret' <<< "${logs}" || \
     grep -Fq 'store-recovery-multinode-fake-token' <<< "${logs}"; then
    echo "secret leaked into ${name} logs" >&2
    exit 1
  fi
done

echo "store recovery multinode smoke ok"
