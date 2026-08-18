#!/usr/bin/env bash
set -euo pipefail

image="${1:-deeploy-crdb-runtime-supervision:local}"
run_id="${2:-$$-${RANDOM}}"
# This local Docker topology test isolates host clock jumps; production stays at 500ms.
test_max_offset="${CRDB_TEST_MAX_OFFSET:-5s}"
test_recovery_handler_timeout="${CRDB_TEST_RECOVERY_HANDLER_TIMEOUT_SECONDS:-10}"
# Docker Desktop process creation is outside the behavior under test here. The
# dedicated supervision suite owns strict peer/readiness timeout assertions.
test_bootstrap_timeout="${CRDB_TEST_BOOTSTRAP_TIMEOUT_SECONDS:-30}"
test_container_exit_timeout="${CRDB_TEST_CONTAINER_EXIT_TIMEOUT_SECONDS:-75}"
tmp="$(mktemp -d /tmp/deeploy-crdb-store-recovery.XXXXXX)"
test_label="com.ratio1.deeploy-crdb-store-recovery=${run_id}"
state_dir_name=".deeploy-recovery-v1"
containers=()
volumes=()

cleanup() {
  local status=$?
  local cleanup_failed=0
  trap - EXIT
  docker ps -aq --filter "label=${test_label}" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker ps -aq --filter "label=${test_label}" | grep -q . && cleanup_failed=1
  for volume in "${volumes[@]}"; do
    docker volume rm "${volume}" >/dev/null 2>&1 || true
    docker volume inspect "${volume}" >/dev/null 2>&1 && cleanup_failed=1
  done
  docker run --rm -v "${tmp}:/cleanup" --entrypoint /bin/sh "${image}" \
    -c 'rm -rf /cleanup/* /cleanup/.[!.]* /cleanup/..?*' >/dev/null 2>&1 || cleanup_failed=1
  rmdir "${tmp}" >/dev/null 2>&1 || cleanup_failed=1
  if [[ "${status}" == "0" && "${cleanup_failed}" != "0" ]]; then
    echo "store recovery regression cleanup failed" >&2
    status=1
  fi
  exit "${status}"
}
trap cleanup EXIT

mkdir -p "${tmp}/certs" "${tmp}/token" "${tmp}/capture"
printf 'store-recovery-fake-token\n' > "${tmp}/token/cf-token"

docker run --rm -u "$(id -u):$(id -g)" -v "${tmp}/certs:/certs" \
  --entrypoint /cockroach/cockroach-real "${image}" \
  cert create-ca --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
docker run --rm -u "$(id -u):$(id -g)" -v "${tmp}/certs:/certs" \
  --entrypoint /cockroach/cockroach-real "${image}" \
  cert create-node roach1 roach2 roach3 localhost 127.0.0.1 \
  --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
docker run --rm -u "$(id -u):$(id -g)" -v "${tmp}/certs:/certs" \
  --entrypoint /cockroach/cockroach-real "${image}" \
  cert create-client root --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
rm -f "${tmp}/certs/ca.key"

wait_for_exit() {
  local name="$1"
  local deadline=$(( $(date +%s) + test_container_exit_timeout ))
  while [[ "$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || true)" == "true" ]]; do
    if [[ "$(date +%s)" -ge "${deadline}" ]]; then
      docker top "${name}" -eo pid,ppid,pgid,stat,args >&2 2>/dev/null || true
      docker logs "${name}" >&2 || true
      echo "timed out waiting for ${name} to exit" >&2
      return 1
    fi
    sleep 0.2
  done
}

wait_for_host_file() {
  local path="$1"
  local deadline=$(( $(date +%s) + 20 ))
  while [[ ! -e "${path}" ]]; do
    if [[ "$(date +%s)" -ge "${deadline}" ]]; then
      echo "timed out waiting for ${path}" >&2
      return 1
    fi
    sleep 0.1
  done
}

create_case() {
  local name="$1"
  local store="$2"
  local node_count="$3"
  local node_id="$4"
  shift 4
  if [[ "${store}" == /* ]]; then
    mkdir -p "${store}"
  fi
  inspect_store "${store}" "chown 0:0 /store && chmod 700 /store"
  containers+=("${name}")
  docker create --name "${name}" --label "${test_label}" \
    -v "${store}:/cockroach/cockroach-data" \
    -v "${tmp}/capture:/runtime/capture" \
    -v "${tmp}/certs/ca.crt:/runtime/ca.crt:ro" \
    -v "${tmp}/certs/node.crt:/runtime/node.crt:ro" \
    -v "${tmp}/certs/node.key:/runtime/node.key:ro" \
    -v "${tmp}/certs/client.root.crt:/runtime/client.root.crt:ro" \
    -v "${tmp}/certs/client.root.key:/runtime/client.root.key:ro" \
    -v "${tmp}/token/cf-token:/runtime/cf-token:ro" \
    -e "CRDB_NODE_ID=${node_id}" \
    -e "CRDB_NODE_COUNT=${node_count}" \
    -e CRDB_HOSTNAMES=roach1.local,roach2.local,roach3.local \
    -e CRDB_DATABASE=appdb \
    -e CRDB_USER=app_user \
    -e CRDB_PASSWORD=store_recovery_secret \
    -e CRDB_LISTEN_HOST=127.0.0.1 \
    -e "CRDB_MAX_OFFSET=${test_max_offset}" \
    -e CRDB_CA_CRT_FILE=/runtime/ca.crt \
    -e CRDB_NODE_CRT_FILE=/runtime/node.crt \
    -e CRDB_NODE_KEY_FILE=/runtime/node.key \
    -e CRDB_CLIENT_ROOT_CRT_FILE=/runtime/client.root.crt \
    -e CRDB_CLIENT_ROOT_KEY_FILE=/runtime/client.root.key \
    -e CF_TUNNEL_TOKEN_FILE=/runtime/cf-token \
    -e TEST_CLOUDFLARED_ACCESS_MODE=proxy \
    -e "CRDB_BOOTSTRAP_TIMEOUT_SECONDS=${test_bootstrap_timeout}" \
    -e CRDB_SHUTDOWN_GRACE_SECONDS=1 \
    -e TEST_DF_USED_KB=1024 \
    -e TEST_DF_AVAILABLE_KB=2097152 \
    -e TEST_DF_USED_INODES=1000 \
    -e TEST_DF_AVAILABLE_INODES=100000 \
    -e "CRDB_RECOVERY_HANDLER_TIMEOUT_SECONDS=${test_recovery_handler_timeout}" \
    "$@" "${image}" >/dev/null
}

run_case() {
  local name="$1"
  docker start "${name}" >/dev/null
  wait_for_exit "${name}"
}

marker_elapsed_millis() {
  local started_file="$1"
  local finished_file="$2"
  local started finished started_seconds started_fraction
  local finished_seconds finished_fraction
  if [[ ! -f "${started_file}" || ! -f "${finished_file}" ]]; then
    echo "bounded-operation timing markers are missing: ${started_file}, ${finished_file}" >&2
    return 1
  fi
  if ! IFS= read -r started < "${started_file}" ||
     ! IFS= read -r finished < "${finished_file}"; then
    echo "bounded-operation timing markers are unreadable: ${started_file}, ${finished_file}" >&2
    return 1
  fi
  if [[ ! "${started}" =~ ^[0-9]+\.[0-9]+$ || ! "${finished}" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "bounded-operation timing markers are malformed: ${started_file}, ${finished_file}" >&2
    return 1
  fi
  started_seconds="${started%%.*}"
  started_fraction="${started#*.}000"
  finished_seconds="${finished%%.*}"
  finished_fraction="${finished#*.}000"
  printf '%s\n' "$((
    (10#${finished_seconds} - 10#${started_seconds}) * 1000 +
    10#${finished_fraction:0:3} - 10#${started_fraction:0:3}
  ))"
}

assert_exit() {
  local name="$1"
  local expected="$2"
  local actual
  actual="$(docker inspect -f '{{.State.ExitCode}}' "${name}")"
  if [[ "${actual}" != "${expected}" ]]; then
    docker logs "${name}" >&2 || true
    echo "${name} exited ${actual}, expected ${expected}" >&2
    return 1
  fi
}

assert_nonzero_exit() {
  local name="$1"
  local actual
  actual="$(docker inspect -f '{{.State.ExitCode}}' "${name}")"
  if [[ "${actual}" == "0" ]]; then
    docker logs "${name}" >&2 || true
    echo "${name} unexpectedly exited successfully" >&2
    return 1
  fi
}

assert_no_recovery_state() {
  local store="$1"
  if ! inspect_store "${store}" "test ! -e /store/${state_dir_name} && test ! -L /store/${state_dir_name}"; then
    echo "unexpected recovery state in ${store}" >&2
    return 1
  fi
}

assert_no_active_recovery() {
  local store="$1"
  if inspect_store "${store}" \
      "test -f /store/${state_dir_name}/state && grep -Eq '^state=(active|started)$' /store/${state_dir_name}/state"; then
    echo "unexpected active recovery state in ${store}" >&2
    return 1
  fi
}

assert_active_recovery() {
  local name="$1"
  local store="$2"
  if ! inspect_store "${store}" "grep -Fxq 'state=active' /store/${state_dir_name}/state"; then
    docker logs "${name}" >&2 || true
    echo "expected active recovery state in ${store}" >&2
    return 1
  fi
}

assert_log() {
  local name="$1"
  local expected="$2"
  if ! docker logs "${name}" 2>&1 | grep -F "${expected}" >/dev/null; then
    docker logs "${name}" >&2 || true
    echo "missing log '${expected}' in ${name}" >&2
    return 1
  fi
}

assert_no_classifier_temp() {
  local name="$1"
  if docker cp "${name}:/tmp/." - 2>/dev/null | tar -tf - | \
      grep -E '(^|/)deeploy-crdb-log-(list|scan)\.' >/dev/null; then
    echo "corruption classifier temporary file remains in ${name}" >&2
    return 1
  fi
}

inspect_store() {
  local store="$1"
  local command="$2"
  docker run --rm -v "${store}:/store" --entrypoint /bin/sh "${image}" -c "${command}"
}

initialize_store_log_root() {
  local store="$1"
  inspect_store "${store}" "chown 0:0 /store/logs && chmod 700 /store/logs"
}

clone_store() {
  local source_store="$1"
  local destination_store="$2"
  mkdir -p "${destination_store}"
  docker run --rm -v "${source_store}:/source:ro" -v "${destination_store}:/destination" \
    --entrypoint /bin/sh "${image}" -c 'cp -a /source/. /destination/'
}

read_capture_file() {
  docker run --rm -v "${tmp}/capture:/capture" --entrypoint /bin/sh "${image}" \
    -c 'cat /capture/selected-store'
}

ancestor_store="${tmp}/ancestor-store"
mkdir -p "${ancestor_store}"
ln -s /cockroach "${tmp}/capture/store-ancestor"
ancestor_case="deeploy-crdb-recovery-ancestor-${run_id}"
create_case "${ancestor_case}" "${ancestor_store}" 3 2 \
  -e CRDB_STORE=/runtime/capture/store-ancestor/cockroach-data \
  -e TEST_CRDB_START_MODE=exit
run_case "${ancestor_case}"
assert_exit "${ancestor_case}" 1
assert_log "${ancestor_case}" "CRDB_STORE must not contain symlink components"

direct_store="${tmp}/direct-symlink-store"
mkdir -p "${direct_store}"
ln -s /cockroach/cockroach-data "${tmp}/capture/direct-store"
direct_store_case="deeploy-crdb-recovery-direct-store-${run_id}"
create_case "${direct_store_case}" "${direct_store}" 3 2 \
  -e CRDB_STORE=/runtime/capture/direct-store \
  -e TEST_CRDB_START_MODE=exit
run_case "${direct_store_case}"
assert_exit "${direct_store_case}" 1
assert_log "${direct_store_case}" "CRDB_STORE must not contain symlink components"

root_store="${tmp}/root-store"
root_store_case="deeploy-crdb-recovery-root-store-${run_id}"
create_case "${root_store_case}" "${root_store}" 3 2 \
  -e CRDB_STORE=/ \
  -e TEST_CRDB_START_MODE=exit
run_case "${root_store_case}"
assert_exit "${root_store_case}" 1
assert_log "${root_store_case}" "CRDB_STORE must not be the filesystem root"

hostile_store_mode="${tmp}/hostile-store-mode"
hostile_store_mode_case="deeploy-crdb-recovery-hostile-store-mode-${run_id}"
create_case "${hostile_store_mode_case}" "${hostile_store_mode}" 3 2 -e TEST_CRDB_START_MODE=exit
inspect_store "${hostile_store_mode}" "chmod 777 /store"
run_case "${hostile_store_mode_case}"
assert_exit "${hostile_store_mode_case}" 1
assert_log "${hostile_store_mode_case}" "invalid R1 MeshDB store directory"

hostile_store_owner="${tmp}/hostile-store-owner"
hostile_store_owner_case="deeploy-crdb-recovery-hostile-store-owner-${run_id}"
create_case "${hostile_store_owner_case}" "${hostile_store_owner}" 3 2 -e TEST_CRDB_START_MODE=exit
inspect_store "${hostile_store_owner}" "chown 1000:1000 /store && chmod 700 /store"
run_case "${hostile_store_owner_case}"
assert_exit "${hostile_store_owner_case}" 1
assert_log "${hostile_store_owner_case}" "invalid R1 MeshDB store directory"

legacy_store_root="${tmp}/legacy-store-root"
legacy_store_root_case="deeploy-crdb-recovery-legacy-store-root-${run_id}"
create_case "${legacy_store_root_case}" "${legacy_store_root}" 3 2 -e TEST_CRDB_START_MODE=exit
inspect_store "${legacy_store_root}" "chmod 755 /store"
run_case "${legacy_store_root_case}"
assert_exit "${legacy_store_root_case}" 42
if [[ "$(inspect_store "${legacy_store_root}" "stat -c '%a' /store")" != "700" ]]; then
  echo "legacy R1 MeshDB store directory was not migrated to mode 700" >&2
  exit 1
fi

store_manifest() {
  local store="$1"
  local output="$2"
  docker run --rm -i -e "STATE_DIR_NAME=${state_dir_name}" -v "${store}:/store:ro" \
    --entrypoint /bin/bash "${image}" -s > "${output}" <<'MANIFEST_SCRIPT'
set -euo pipefail
cd /store
find . -mindepth 1 \
  -path "./${STATE_DIR_NAME}" -prune -o \
  -print0 | sort -z | while IFS= read -r -d '' path; do
    if [[ -L "${path}" ]]; then
      entry_type="symlink"
      payload="$(readlink "${path}")"
    elif [[ -f "${path}" ]]; then
      entry_type="file"
      payload="$(stat -c '%s' "${path}"):$(sha256sum "${path}" | awk '{print $1}')"
    elif [[ -d "${path}" ]]; then
      entry_type="directory"
      payload="-"
    else
      entry_type="other"
      payload="$(stat -c '%t:%T' "${path}")"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${path}" "${entry_type}" "$(stat -c '%a' "${path}")" \
      "$(stat -c '%u' "${path}")" "$(stat -c '%g' "${path}")" "${payload}"
  done
MANIFEST_SCRIPT
}

stale_store="${tmp}/stale-store"
mkdir -p "${stale_store}/logs"
printf 'local corruption detected: stale fixture (checksum mismatch at 1/1)\n' > "${stale_store}/logs/stale.log"
initialize_store_log_root "${stale_store}"
stale_case="deeploy-crdb-recovery-stale-${run_id}"
create_case "${stale_case}" "${stale_store}" 3 2 -e TEST_CRDB_START_MODE=exit
run_case "${stale_case}"
assert_exit "${stale_case}" 42
assert_no_recovery_state "${stale_store}"

renamed_store="${tmp}/renamed-store"
mkdir -p "${renamed_store}/logs"
printf 'local corruption detected: stale renamed fixture (checksum mismatch at 1/1)\n' > "${renamed_store}/logs/stale.log"
initialize_store_log_root "${renamed_store}"
renamed_case="deeploy-crdb-recovery-renamed-${run_id}"
create_case "${renamed_case}" "${renamed_store}" 3 2 -e TEST_CRDB_START_MODE=rename_stale_exit
run_case "${renamed_case}"
assert_exit "${renamed_case}" 86
assert_no_recovery_state "${renamed_store}"

split_store="${tmp}/split-store"
split_case="deeploy-crdb-recovery-split-${run_id}"
create_case "${split_case}" "${split_store}" 3 2 -e TEST_CRDB_START_MODE=split_corruption_exit
run_case "${split_case}"
assert_exit "${split_case}" 86
assert_no_recovery_state "${split_store}"

truncate_store="${tmp}/truncate-store"
truncate_case="deeploy-crdb-recovery-truncate-${run_id}"
create_case "${truncate_case}" "${truncate_store}" 3 2 -e TEST_CRDB_START_MODE=truncate_corruption_exit
run_case "${truncate_case}"
assert_exit "${truncate_case}" 86
assert_active_recovery "${truncate_case}" "${truncate_store}"

rm -f "${tmp}/capture/crdb-corruption-ready"
concurrent_store="${tmp}/concurrent-store"
concurrent_case="deeploy-crdb-recovery-concurrent-${run_id}"
create_case "${concurrent_case}" "${concurrent_store}" 3 2 \
  -e TEST_CRDB_START_MODE=corruption_signal_exit \
  -e TEST_CLOUDFLARED_SERVER_MODE=exit_on_corruption_ready
run_case "${concurrent_case}"
assert_exit "${concurrent_case}" 86
assert_active_recovery "${concurrent_case}" "${concurrent_store}"

two_node_store="${tmp}/two-node-store"
two_node_case="deeploy-crdb-recovery-two-node-${run_id}"
create_case "${two_node_case}" "${two_node_store}" 2 2 \
  -e CRDB_HOSTNAMES=roach1.local,roach2.local \
  -e TEST_CRDB_START_MODE=corruption_exit
run_case "${two_node_case}"
assert_exit "${two_node_case}" 86
assert_no_recovery_state "${two_node_store}"

disabled_store="${tmp}/disabled-store"
disabled_case="deeploy-crdb-recovery-disabled-${run_id}"
create_case "${disabled_case}" "${disabled_store}" 3 2 \
  -e CRDB_AUTO_RECOVER_CORRUPT_STORE=false \
  -e TEST_CRDB_START_MODE=corruption_exit
run_case "${disabled_case}"
assert_exit "${disabled_case}" 86
assert_no_recovery_state "${disabled_store}"

space_store="${tmp}/space-store"
space_case="deeploy-crdb-recovery-space-${run_id}"
create_case "${space_case}" "${space_store}" 3 2 \
  -e CRDB_RECOVERY_MIN_FREE_BYTES=900000000000000000 \
  -e TEST_CRDB_START_MODE=corruption_exit
run_case "${space_case}"
assert_exit "${space_case}" 86
assert_no_recovery_state "${space_store}"
assert_log "${space_case}" "insufficient free storage for corrupt-store recovery"

inode_store="${tmp}/inode-store"
inode_case="deeploy-crdb-recovery-inodes-${run_id}"
create_case "${inode_case}" "${inode_store}" 3 2 \
  -e CRDB_RECOVERY_MIN_FREE_INODES=900000000000000000 \
  -e TEST_CRDB_START_MODE=corruption_exit
run_case "${inode_case}"
assert_exit "${inode_case}" 86
assert_no_recovery_state "${inode_store}"
assert_log "${inode_case}" "insufficient free inodes for corrupt-store recovery"

inode_accounting_store="${tmp}/inode-accounting-store"
inode_accounting_case="deeploy-crdb-recovery-inode-accounting-${run_id}"
create_case "${inode_accounting_case}" "${inode_accounting_store}" 3 2 \
  -e CRDB_RECOVERY_MIN_FREE_INODES=1024 \
  -e TEST_DF_USED_INODES=1000 \
  -e TEST_DF_AVAILABLE_INODES=1500 \
  -e TEST_CRDB_START_MODE=corruption_exit
run_case "${inode_accounting_case}"
assert_exit "${inode_accounting_case}" 86
assert_no_recovery_state "${inode_accounting_store}"
assert_log "${inode_accounting_case}" "insufficient free inodes for corrupt-store recovery"

inode_boundary_store="${tmp}/inode-boundary-store"
inode_boundary_case="deeploy-crdb-recovery-inode-boundary-${run_id}"
create_case "${inode_boundary_case}" "${inode_boundary_store}" 3 2 \
  -e CRDB_RECOVERY_MIN_FREE_INODES=600 \
  -e TEST_DF_USED_INODES=1000 \
  -e TEST_DF_AVAILABLE_INODES=1600 \
  -e TEST_CRDB_START_MODE=corruption_exit
run_case "${inode_boundary_case}"
assert_exit "${inode_boundary_case}" 86
assert_active_recovery "${inode_boundary_case}" "${inode_boundary_store}"

byte_accounting_store="${tmp}/byte-accounting-store"
byte_accounting_case="deeploy-crdb-recovery-byte-accounting-${run_id}"
create_case "${byte_accounting_case}" "${byte_accounting_store}" 3 2 \
  -e CRDB_RECOVERY_MIN_FREE_BYTES=614400 \
  -e TEST_DF_USED_KB=1000 \
  -e TEST_DF_AVAILABLE_KB=1599 \
  -e TEST_CRDB_START_MODE=corruption_exit
run_case "${byte_accounting_case}"
assert_exit "${byte_accounting_case}" 86
assert_no_recovery_state "${byte_accounting_store}"
assert_log "${byte_accounting_case}" "insufficient free storage for corrupt-store recovery"

byte_boundary_store="${tmp}/byte-boundary-store"
byte_boundary_case="deeploy-crdb-recovery-byte-boundary-${run_id}"
create_case "${byte_boundary_case}" "${byte_boundary_store}" 3 2 \
  -e CRDB_RECOVERY_MIN_FREE_BYTES=614400 \
  -e TEST_DF_USED_KB=1000 \
  -e TEST_DF_AVAILABLE_KB=1600 \
  -e TEST_CRDB_START_MODE=corruption_exit
run_case "${byte_boundary_case}"
assert_exit "${byte_boundary_case}" 86
assert_active_recovery "${byte_boundary_case}" "${byte_boundary_store}"

timeout_store="${tmp}/handler-timeout-store"
timeout_case="deeploy-crdb-recovery-handler-timeout-${run_id}"
rm -f "${tmp}/capture/df-block-started" "${tmp}/capture/df-block-term"
create_case "${timeout_case}" "${timeout_store}" 3 2 \
  -e CRDB_RECOVERY_HANDLER_TIMEOUT_SECONDS=1 \
  -e TEST_DF_MODE=block \
  -e TEST_DF_BLOCK_STARTED_FILE=/runtime/capture/df-block-started \
  -e TEST_DF_BLOCK_TERM_FILE=/runtime/capture/df-block-term \
  -e TEST_CRDB_START_MODE=corruption_exit
run_case "${timeout_case}"
assert_exit "${timeout_case}" 86
assert_no_recovery_state "${timeout_store}"
assert_log "${timeout_case}" "corrupt-store classification exceeded 1 seconds"
timeout_elapsed_ms="$(marker_elapsed_millis \
  "${tmp}/capture/df-block-started" "${tmp}/capture/df-block-term")" || {
  docker logs "${timeout_case}" >&2 || true
  exit 1
}
if [[ "${timeout_elapsed_ms}" -lt 800 || "${timeout_elapsed_ms}" -gt 2000 ]]; then
  echo "bounded recovery handler took ${timeout_elapsed_ms}ms" >&2
  exit 1
fi

sync_store="${tmp}/sync-failure-store"
sync_case="deeploy-crdb-recovery-sync-failure-${run_id}"
create_case "${sync_case}" "${sync_store}" 3 2 \
  -e TEST_SYNC_MODE=fail \
  -e TEST_CRDB_START_MODE=corruption_exit
run_case "${sync_case}"
assert_exit "${sync_case}" 86
assert_no_active_recovery "${sync_store}"
assert_log "${sync_case}" "could not persist corrupt-store recovery state"

sync_restart_case="deeploy-crdb-recovery-sync-restart-${run_id}"
create_case "${sync_restart_case}" "${sync_store}" 3 2 -e TEST_CRDB_START_MODE=exit
run_case "${sync_restart_case}"
assert_exit "${sync_restart_case}" 1
assert_log "${sync_restart_case}" "invalid corrupt-store recovery state"

client_store="${tmp}/client-store"
client_case="deeploy-crdb-recovery-client-${run_id}"
create_case "${client_case}" "${client_store}" 3 1 \
  -e TEST_CRDB_START_MODE=listen_block \
  -e TEST_CRDB_INIT_MODE=corruption_exit
run_case "${client_case}"
assert_exit "${client_case}" 48
assert_no_recovery_state "${client_store}"

real_fixture_volume="deeploy-crdb-real-corrupt-fixture-${run_id}"
real_corrupt_store="${real_fixture_volume}"
docker volume create --label "${test_label}" "${real_fixture_volume}" >/dev/null
volumes+=("${real_fixture_volume}")
real_fixture_case="deeploy-crdb-real-corrupt-fixture-${run_id}"
containers+=("${real_fixture_case}")
docker run -d --name "${real_fixture_case}" --label "${test_label}" \
  -v "${real_fixture_volume}:/store" \
  -v "${tmp}/certs:/certs:ro" \
  --entrypoint /cockroach/cockroach-real "${image}" \
  start-single-node --certs-dir=/certs --store=/store \
    --listen-addr=127.0.0.1:26257 --http-addr=127.0.0.1:8080 \
    --max-offset="${test_max_offset}" \
    --log-dir=/store/fixture-logs >/dev/null
fixture_deadline=$(( $(date +%s) + 30 ))
until docker exec "${real_fixture_case}" /cockroach/cockroach-real sql \
    --certs-dir=/certs --host=127.0.0.1:26257 -e 'SELECT 1' >/dev/null 2>&1; do
  if [[ "$(date +%s)" -ge "${fixture_deadline}" ]]; then
    docker logs "${real_fixture_case}" >&2 || true
    echo "real corrupt-store fixture did not become SQL-ready" >&2
    exit 1
  fi
  sleep 0.2
done
if ! {
    printf '%s\n' \
      'CREATE DATABASE fixture;' \
      'CREATE TABLE fixture.public.t (id INT PRIMARY KEY, payload BYTES);'
    for batch_start in $(seq 1 1000 19001); do
      batch_end=$((batch_start + 999))
      printf "INSERT INTO fixture.public.t SELECT i, repeat('x', 4096)::BYTES FROM generate_series(%s, %s) AS g(i);\n" \
        "${batch_start}" "${batch_end}"
    done
  } | timeout --signal=TERM --kill-after=10s 5m \
    docker exec -i "${real_fixture_case}" /cockroach/cockroach-real sql \
      --certs-dir=/certs --host=127.0.0.1:26257 >/dev/null; then
  docker inspect "${real_fixture_case}" --format '{{json .State}}' >&2 || true
  docker logs "${real_fixture_case}" >&2 || true
  docker run --rm -v "${real_fixture_volume}:/store:ro" \
    --entrypoint /bin/sh "${image}" -c '
      find /store/fixture-logs -maxdepth 1 -type f -name "cockroach*.log" -print |
        while IFS= read -r log_file; do
          printf "--- %s ---\n" "${log_file}"
          tail -n 100 "${log_file}"
        done
    ' >&2 || true
  echo "real corrupt-store fixture workload failed" >&2
  exit 1
fi
fixture_target="$(docker exec "${real_fixture_case}" /cockroach/cockroach-real sql \
  --certs-dir=/certs --host=127.0.0.1:26257 --format=csv \
  -e 'SELECT node_id, store_id FROM crdb_internal.kv_store_status
      WHERE node_id = crdb_internal.node_id() ORDER BY store_id LIMIT 1' \
  | tail -n 1 | tr -d '\r')"
IFS=, read -r fixture_node_id fixture_store_id <<< "${fixture_target}"
if [[ ! "${fixture_node_id}" =~ ^[1-9][0-9]*$ || ! "${fixture_store_id}" =~ ^[1-9][0-9]*$ ]]; then
  echo "real corrupt-store fixture could not identify its node and store" >&2
  exit 1
fi
docker stop -t 30 "${real_fixture_case}" >/dev/null
docker rm "${real_fixture_case}" >/dev/null
docker run --rm -v "${real_fixture_volume}:/store" \
  --entrypoint /cockroach/cockroach-real "${image}" \
  debug compact /store >/dev/null
fixture_sst="$(inspect_store "${real_corrupt_store}" "find /store -maxdepth 1 -type f -name '*.sst' -printf '%s %p\\n' | sort -nr | head -n 1 | sed 's/^[0-9]* //'")"
if [[ -z "${fixture_sst}" ]]; then
  echo "real corrupt-store fixture produced no SSTable" >&2
  exit 1
fi
fixture_layout="$(docker run --rm -v "${real_fixture_volume}:/store:ro" \
  --entrypoint /cockroach/cockroach-real "${image}" \
  debug pebble sstable layout "${fixture_sst}")"
read -r fixture_data_start fixture_data_size <<< "$(awk '
  $2 == "data" { start=$1; size=$3 }
  END { gsub(/[()]/, "", size); print start, size }
' <<< "${fixture_layout}")"
if [[ ! "${fixture_data_start}" =~ ^[0-9]+$ || ! "${fixture_data_size}" =~ ^[1-9][0-9]*$ ]]; then
  echo "real corrupt-store fixture produced no data block" >&2
  exit 1
fi
fixture_corruption_offset=$((fixture_data_start + fixture_data_size / 2))
fixture_check="$(docker run --rm -v "${real_fixture_volume}:/store:ro" \
  --entrypoint /cockroach/cockroach-real "${image}" \
  debug pebble sstable check "${fixture_sst}" 2>&1)"
if grep -Fq 'checksum mismatch' <<< "${fixture_check}"; then
  echo "real corrupt-store fixture was corrupt before fault injection" >&2
  exit 1
fi
fixture_sst_sha_before="$(inspect_store "${real_corrupt_store}" "sha256sum '${fixture_sst}' | cut -d ' ' -f 1")"
inspect_store "${real_corrupt_store}" "
  byte=\$(dd if='${fixture_sst}' bs=1 skip=${fixture_corruption_offset} count=1 status=none | od -An -tu1 | tr -d ' ')
  if [ \"\${byte}\" = 0 ]; then value='\\377'; else value='\\000'; fi
  printf \"\${value}\" | dd of='${fixture_sst}' bs=1 seek=${fixture_corruption_offset} conv=notrunc status=none
"
fixture_sst_sha_corrupt="$(inspect_store "${real_corrupt_store}" "sha256sum '${fixture_sst}' | cut -d ' ' -f 1")"
if [[ "${fixture_sst_sha_corrupt}" == "${fixture_sst_sha_before}" ]]; then
  echo "real corrupt-store fixture did not alter its SSTable" >&2
  exit 1
fi
fixture_check="$(docker run --rm -v "${real_fixture_volume}:/store:ro" \
  --entrypoint /cockroach/cockroach-real "${image}" \
  debug pebble sstable check "${fixture_sst}" 2>&1)"
if ! grep -Fq 'checksum mismatch' <<< "${fixture_check}"; then
  echo "R1 MeshDB checksum verification did not detect the injected SSTable corruption" >&2
  exit 1
fi

real_detection_case="deeploy-crdb-real-corrupt-detection-${run_id}"
create_case "${real_detection_case}" "${real_corrupt_store}" 3 2 \
  -e CRDB_BOOTSTRAP_TIMEOUT_SECONDS=90
docker start "${real_detection_case}" >/dev/null
real_detection_deadline=$(( $(date +%s) + 75 ))
while [[ "$(docker inspect -f '{{.State.Running}}' "${real_detection_case}" 2>/dev/null || true)" == "true" ]]; do
  if docker exec "${real_detection_case}" timeout --kill-after=1s 2s /cockroach/cockroach-real sql \
      --certs-dir=/cockroach/certs --host=127.0.0.1:26257 \
      -e 'SELECT 1' >/dev/null 2>&1; then
    break
  fi
  if [[ "$(date +%s)" -ge "${real_detection_deadline}" ]]; then
    break
  fi
  sleep 0.2
done
if [[ "$(docker inspect -f '{{.State.Running}}' "${real_detection_case}" 2>/dev/null || true)" == "true" ]]; then
  if docker exec "${real_detection_case}" timeout --kill-after=1s 20s /cockroach/cockroach-real sql \
      --certs-dir=/cockroach/certs --host=127.0.0.1:26257 \
      -e "SELECT crdb_internal.compact_engine_span(
            ${fixture_node_id}, ${fixture_store_id}, ''::BYTES, decode('ff', 'hex')
          )" >/dev/null 2>&1; then
    echo "corrupt SSTable compaction unexpectedly succeeded" >&2
    exit 1
  fi
fi
wait_for_exit "${real_detection_case}"
assert_nonzero_exit "${real_detection_case}"
assert_active_recovery "${real_detection_case}" "${real_corrupt_store}"
inspect_store "${real_corrupt_store}" "grep -R -q 'local corruption detected:.*checksum mismatch' /store/logs/deeploy-run.*"
fixture_sst_sha_after="$(inspect_store "${real_corrupt_store}" "sha256sum '${fixture_sst}' | cut -d ' ' -f 1")"
if [[ "${fixture_sst_sha_after}" != "${fixture_sst_sha_corrupt}" ]]; then
  echo "recovery handling modified the actual corrupt SSTable" >&2
  exit 1
fi

recovery_store="${tmp}/recover-store"
mkdir -p "${recovery_store}/logs" "${recovery_store}/nested/empty-dir"
printf 'forensic sentinel\n' > "${recovery_store}/sentinel"
printf 'pre-existing log\n' > "${recovery_store}/logs/pre-existing.log"
initialize_store_log_root "${recovery_store}"
printf 'nested payload\n' > "${recovery_store}/nested/payload"
: > "${recovery_store}/nested/empty"
ln -s ../sentinel "${recovery_store}/nested/sentinel-link"
chmod 640 "${recovery_store}/nested/payload"
pre_recovery_manifest="${tmp}/capture/pre-recovery.manifest"
post_recovery_manifest="${tmp}/capture/post-recovery.manifest"
recover_case="deeploy-crdb-recovery-current-${run_id}"
rm -f "${tmp}/capture/crdb-corruption-blocked" "${tmp}/capture/release-crdb-corruption"
create_case "${recover_case}" "${recovery_store}" 3 2 -e TEST_CRDB_START_MODE=corruption_block
docker start "${recover_case}" >/dev/null
wait_for_host_file "${tmp}/capture/crdb-corruption-blocked"
store_manifest "${recovery_store}" "${pre_recovery_manifest}"
touch "${tmp}/capture/release-crdb-corruption"
wait_for_exit "${recover_case}"
assert_exit "${recover_case}" 86
if ! inspect_store "${recovery_store}" "test -f /store/${state_dir_name}/state && test ! -L /store/${state_dir_name}/state"; then
  docker logs "${recover_case}" >&2 || true
  inspect_store "${recovery_store}" "find /store -maxdepth 3 -printf '%P %y %s\\n'" >&2 || true
  echo "valid current-run corruption did not create a regular recovery marker" >&2
  exit 1
fi
permissions="$(inspect_store "${recovery_store}" "stat -c '%a' /store/${state_dir_name}/state /store/${state_dir_name}" | tr '\n' ' ')"
if [[ "${permissions}" != "600 700 " ]]; then
  echo "recovery state permissions are not restrictive" >&2
  exit 1
fi
store_manifest "${recovery_store}" "${post_recovery_manifest}"
if ! diff -u "${pre_recovery_manifest}" "${post_recovery_manifest}"; then
  echo "pre-existing Cockroach store manifest changed during recovery allocation" >&2
  exit 1
fi
marker_content="$(inspect_store "${recovery_store}" "cat /store/${state_dir_name}/state")"
grep -Fxq 'version=3' <<< "${marker_content}"
grep -Fxq 'state=active' <<< "${marker_content}"
grep -Fxq 'recovery_run=none' <<< "${marker_content}"
grep -Eq '^topology_sha256=[a-f0-9]{64}$' <<< "${marker_content}"
grep -Eq '^ca_sha256=[a-f0-9]{64}$' <<< "${marker_content}"
selected_name="$(sed -n 's/^recovery_store=//p' <<< "${marker_content}")"
if [[ ! "${selected_name}" =~ ^store\.[A-Za-z0-9]{8}$ ]] || \
   ! inspect_store "${recovery_store}" "test -d /store/${state_dir_name}/${selected_name} && test ! -L /store/${state_dir_name}/${selected_name}"; then
  echo "marker does not identify one valid recovery store" >&2
  exit 1
fi
if [[ "$(inspect_store "${recovery_store}" "find /store/${state_dir_name} -mindepth 1 -maxdepth 1 -type d -name 'store.*' | wc -l")" != "1" ]]; then
  echo "expected exactly one recovery store" >&2
  exit 1
fi

capture_file="${tmp}/capture/selected-store"
capture_case="deeploy-crdb-recovery-capture-${run_id}"
create_case "${capture_case}" "${recovery_store}" 3 2 \
  -e TEST_CRDB_START_MODE=capture_store_exit \
  -e TEST_CRDB_CAPTURE_STORE_FILE=/runtime/capture/selected-store
run_case "${capture_case}"
assert_exit "${capture_case}" 44
expected_store="/cockroach/cockroach-data/${state_dir_name}/${selected_name}"
if [[ "$(read_capture_file)" != "${expected_store}" ]]; then
  echo "restart did not select the recorded recovery store" >&2
  exit 1
fi
inspect_store "${recovery_store}" "grep -Fxq 'state=started' /store/${state_dir_name}/state"
recorded_run="$(inspect_store "${recovery_store}" "sed -n 's/^recovery_run=//p' /store/${state_dir_name}/state")"
if [[ ! "${recorded_run}" =~ ^deeploy-run\.[A-Za-z0-9]{8}$ ]]; then
  echo "started marker does not identify one exact recovery run" >&2
  exit 1
fi
post_switch_manifest="${tmp}/capture/post-switch.manifest"
store_manifest "${recovery_store}" "${post_switch_manifest}"
if ! diff -u "${post_recovery_manifest}" "${post_switch_manifest}"; then
  echo "original Cockroach store changed after switching to the recovery store" >&2
  exit 1
fi
active_template_store="${tmp}/active-template-store"
clone_store "${recovery_store}" "${active_template_store}"

missing_recovery_logs_store="${tmp}/missing-recovery-logs-store"
clone_store "${active_template_store}" "${missing_recovery_logs_store}"
inspect_store "${missing_recovery_logs_store}" \
  "rm -rf /store/${state_dir_name}/${selected_name}/logs"
missing_recovery_logs_case="deeploy-crdb-recovery-missing-logs-${run_id}"
rm -f "${capture_file}"
create_case "${missing_recovery_logs_case}" "${missing_recovery_logs_store}" 3 2 \
  -e TEST_CRDB_START_MODE=capture_store_exit \
  -e TEST_CRDB_CAPTURE_STORE_FILE=/runtime/capture/selected-store
run_case "${missing_recovery_logs_case}"
assert_exit "${missing_recovery_logs_case}" 1
assert_log "${missing_recovery_logs_case}" "could not safely inspect the previous fresh-store run"
if [[ -e "${capture_file}" ]]; then
  echo "R1 MeshDB started after recovery logs disappeared" >&2
  exit 1
fi

missing_recorded_run_store="${tmp}/missing-recorded-run-store"
clone_store "${active_template_store}" "${missing_recorded_run_store}"
inspect_store "${missing_recorded_run_store}" "
  rm -rf '/store/${state_dir_name}/${selected_name}/logs/${recorded_run}'
  mkdir -m 700 '/store/${state_dir_name}/${selected_name}/logs/deeploy-run.older000'
  printf 'ordinary older log\n' > '/store/${state_dir_name}/${selected_name}/logs/deeploy-run.older000/cockroach.log'
  touch -d '2030-01-01T00:00:00Z' '/store/${state_dir_name}/${selected_name}/logs/deeploy-run.older000'
"
missing_recorded_run_case="deeploy-crdb-recovery-missing-recorded-run-${run_id}"
rm -f "${capture_file}"
create_case "${missing_recorded_run_case}" "${missing_recorded_run_store}" 3 2 \
  -e TEST_CRDB_START_MODE=capture_store_exit \
  -e TEST_CRDB_CAPTURE_STORE_FILE=/runtime/capture/selected-store
run_case "${missing_recorded_run_case}"
assert_exit "${missing_recorded_run_case}" 1
assert_log "${missing_recorded_run_case}" "could not safely inspect the previous fresh-store run"
if [[ -e "${capture_file}" ]]; then
  echo "R1 MeshDB started after the exact recorded recovery run disappeared" >&2
  exit 1
fi

state_validation_store="${tmp}/state-validation-store"
clone_store "${recovery_store}" "${state_validation_store}"

inspect_store "${state_validation_store}" "chmod 644 /store/${state_dir_name}/state"
marker_mode_case="deeploy-crdb-recovery-marker-mode-${run_id}"
create_case "${marker_mode_case}" "${state_validation_store}" 3 2 -e TEST_CRDB_START_MODE=exit
run_case "${marker_mode_case}"
assert_exit "${marker_mode_case}" 1
assert_log "${marker_mode_case}" "invalid corrupt-store recovery state"
inspect_store "${state_validation_store}" "chmod 600 /store/${state_dir_name}/state"

inspect_store "${state_validation_store}" "chmod 755 /store/${state_dir_name}"
state_mode_case="deeploy-crdb-recovery-state-mode-${run_id}"
create_case "${state_mode_case}" "${state_validation_store}" 3 2 -e TEST_CRDB_START_MODE=exit
run_case "${state_mode_case}"
assert_exit "${state_mode_case}" 1
assert_log "${state_mode_case}" "invalid corrupt-store recovery state"
inspect_store "${state_validation_store}" "chmod 700 /store/${state_dir_name}"

inspect_store "${state_validation_store}" "chown 1000:1000 /store/${state_dir_name}"
state_owner_case="deeploy-crdb-recovery-state-owner-${run_id}"
create_case "${state_owner_case}" "${state_validation_store}" 3 2 -e TEST_CRDB_START_MODE=exit
run_case "${state_owner_case}"
assert_exit "${state_owner_case}" 1
assert_log "${state_owner_case}" "invalid corrupt-store recovery state"
inspect_store "${state_validation_store}" "chown 0:0 /store/${state_dir_name}"

inspect_store "${state_validation_store}" "chmod 755 /store/${state_dir_name}/${selected_name}"
store_mode_case="deeploy-crdb-recovery-store-mode-${run_id}"
create_case "${store_mode_case}" "${state_validation_store}" 3 2 -e TEST_CRDB_START_MODE=exit
run_case "${store_mode_case}"
assert_exit "${store_mode_case}" 1
assert_log "${store_mode_case}" "invalid corrupt-store recovery state"
inspect_store "${state_validation_store}" "chmod 700 /store/${state_dir_name}/${selected_name}"

inspect_store "${state_validation_store}" "chown 1000:1000 /store/${state_dir_name}/${selected_name}"
store_owner_case="deeploy-crdb-recovery-store-owner-${run_id}"
create_case "${store_owner_case}" "${state_validation_store}" 3 2 -e TEST_CRDB_START_MODE=exit
run_case "${store_owner_case}"
assert_exit "${store_owner_case}" 1
assert_log "${store_owner_case}" "invalid corrupt-store recovery state"

classifier_timeout_store="${tmp}/classifier-timeout-active-store"
clone_store "${recovery_store}" "${classifier_timeout_store}"
startup_scan_timeout_case="deeploy-crdb-recovery-startup-scan-timeout-${run_id}"
rm -f "${tmp}/capture/tail-block-started" "${tmp}/capture/tail-block-term"
create_case "${startup_scan_timeout_case}" "${classifier_timeout_store}" 3 2 \
  -e CRDB_RECOVERY_HANDLER_TIMEOUT_SECONDS=1 \
  -e TEST_TAIL_MODE=block_run_log \
  -e TEST_TAIL_BLOCK_STARTED_FILE=/runtime/capture/tail-block-started \
  -e TEST_TAIL_BLOCK_TERM_FILE=/runtime/capture/tail-block-term \
  -e TEST_CRDB_START_MODE=capture_store_exit \
  -e TEST_CRDB_CAPTURE_STORE_FILE=/runtime/capture/selected-store
run_case "${startup_scan_timeout_case}"
assert_exit "${startup_scan_timeout_case}" 1
assert_no_classifier_temp "${startup_scan_timeout_case}"
assert_log "${startup_scan_timeout_case}" "previous recovery log classification exceeded 1 seconds"
inspect_store "${classifier_timeout_store}" \
  "test ! -e /store/${state_dir_name}/exhausted && grep -Fxq 'state=started' /store/${state_dir_name}/state"
startup_scan_timeout_elapsed_ms="$(marker_elapsed_millis \
  "${tmp}/capture/tail-block-started" "${tmp}/capture/tail-block-term")" || {
  docker logs "${startup_scan_timeout_case}" >&2 || true
  exit 1
}
if [[ "${startup_scan_timeout_elapsed_ms}" -lt 800 || \
      "${startup_scan_timeout_elapsed_ms}" -gt 2000 ]]; then
  echo "bounded startup recovery scan took ${startup_scan_timeout_elapsed_ms}ms" >&2
  exit 1
fi

startup_scan_term_store="${tmp}/startup-scan-term-store"
clone_store "${active_template_store}" "${startup_scan_term_store}"
rm -f "${tmp}/capture/tail-blocked"
startup_scan_term_case="deeploy-crdb-recovery-startup-scan-term-${run_id}"
create_case "${startup_scan_term_case}" "${startup_scan_term_store}" 3 2 \
  -e CRDB_RECOVERY_HANDLER_TIMEOUT_SECONDS=10 \
  -e TEST_TAIL_MODE=block_run_log \
  -e TEST_CRDB_START_MODE=capture_store_exit \
  -e TEST_CRDB_CAPTURE_STORE_FILE=/runtime/capture/selected-store
docker start "${startup_scan_term_case}" >/dev/null
wait_for_host_file "${tmp}/capture/tail-blocked"
docker kill --signal TERM "${startup_scan_term_case}" >/dev/null
wait_for_exit "${startup_scan_term_case}"
assert_exit "${startup_scan_term_case}" 143
assert_no_classifier_temp "${startup_scan_term_case}"
inspect_store "${startup_scan_term_store}" \
  "test ! -e /store/${state_dir_name}/exhausted && grep -Fxq 'state=started' /store/${state_dir_name}/state"

classifier_timeout_case="deeploy-crdb-recovery-active-timeout-${run_id}"
rm -f "${tmp}/capture/current-corruption-log-ready" "${tmp}/capture/tail-blocked"
create_case "${classifier_timeout_case}" "${classifier_timeout_store}" 3 2 \
  -e CRDB_RECOVERY_HANDLER_TIMEOUT_SECONDS=1 \
  -e TEST_TAIL_MODE=block_current_run \
  -e TEST_CRDB_START_MODE=corruption_exit
run_case "${classifier_timeout_case}"
assert_exit "${classifier_timeout_case}" 86
assert_no_classifier_temp "${classifier_timeout_case}"
inspect_store "${classifier_timeout_store}" \
  "test ! -e /store/${state_dir_name}/state && grep -Fxq 'state=started' /store/${state_dir_name}/exhausted"

classifier_timeout_restart="deeploy-crdb-recovery-active-timeout-restart-${run_id}"
create_case "${classifier_timeout_restart}" "${classifier_timeout_store}" 3 2 -e TEST_CRDB_START_MODE=exit
run_case "${classifier_timeout_restart}"
assert_exit "${classifier_timeout_restart}" 1
assert_log "${classifier_timeout_restart}" "corrupt-store recovery is exhausted"

classifier_term_store="${tmp}/classifier-term-active-store"
clone_store "${recovery_store}" "${classifier_term_store}"
rm -f "${tmp}/capture/tail-blocked" "${tmp}/capture/crdb-corruption-ready" \
  "${tmp}/capture/current-corruption-log-ready"
classifier_term_case="deeploy-crdb-recovery-active-term-${run_id}"
create_case "${classifier_term_case}" "${classifier_term_store}" 3 2 \
  -e CRDB_RECOVERY_HANDLER_TIMEOUT_SECONDS=10 \
  -e TEST_TAIL_MODE=block_current_run \
  -e TEST_CRDB_START_MODE=corruption_signal_exit
docker start "${classifier_term_case}" >/dev/null
wait_for_host_file "${tmp}/capture/tail-blocked"
docker kill --signal TERM "${classifier_term_case}" >/dev/null
wait_for_exit "${classifier_term_case}"
assert_exit "${classifier_term_case}" 143
assert_no_classifier_temp "${classifier_term_case}"
inspect_store "${classifier_term_store}" \
  "test ! -e /store/${state_dir_name}/state && test -f /store/${state_dir_name}/exhausted"

classifier_term_restart="deeploy-crdb-recovery-active-term-restart-${run_id}"
create_case "${classifier_term_restart}" "${classifier_term_store}" 3 2 -e TEST_CRDB_START_MODE=exit
run_case "${classifier_term_restart}"
assert_exit "${classifier_term_restart}" 1
assert_log "${classifier_term_restart}" "corrupt-store recovery is exhausted"

topology_capture="${tmp}/capture/topology-mismatch-started"
rm -f "${topology_capture}"
topology_case="deeploy-crdb-recovery-topology-mismatch-${run_id}"
create_case "${topology_case}" "${recovery_store}" 3 2 \
  -e CRDB_HOSTNAMES=roach1.local,changed.local,roach3.local \
  -e TEST_CRDB_START_MODE=capture_store_exit \
  -e TEST_CRDB_CAPTURE_STORE_FILE=/runtime/capture/topology-mismatch-started
run_case "${topology_case}"
assert_exit "${topology_case}" 1
assert_log "${topology_case}" "corrupt-store recovery state does not match this node topology"
if [[ -e "${topology_capture}" ]]; then
  echo "R1 MeshDB started after recovery topology changed" >&2
  exit 1
fi

count_capture="${tmp}/capture/count-mismatch-started"
rm -f "${count_capture}"
count_case="deeploy-crdb-recovery-count-mismatch-${run_id}"
create_case "${count_case}" "${recovery_store}" 4 2 \
  -e CRDB_HOSTNAMES=roach1.local,roach2.local,roach3.local,roach4.local \
  -e TEST_CRDB_START_MODE=capture_store_exit \
  -e TEST_CRDB_CAPTURE_STORE_FILE=/runtime/capture/count-mismatch-started
run_case "${count_case}"
assert_exit "${count_case}" 1
assert_log "${count_case}" "corrupt-store recovery state does not match this node topology"
if [[ -e "${count_capture}" ]]; then
  echo "R1 MeshDB started after recovery node count changed" >&2
  exit 1
fi

ca_capture="${tmp}/capture/ca-mismatch-started"
rm -f "${ca_capture}"
ca_case="deeploy-crdb-recovery-ca-mismatch-${run_id}"
create_case "${ca_case}" "${recovery_store}" 3 2 \
  -e CRDB_CA_CRT_FILE=/runtime/node.crt \
  -e TEST_CRDB_START_MODE=capture_store_exit \
  -e TEST_CRDB_CAPTURE_STORE_FILE=/runtime/capture/ca-mismatch-started
run_case "${ca_case}"
assert_exit "${ca_case}" 1
assert_log "${ca_case}" "corrupt-store recovery state does not match this node topology"
if [[ -e "${ca_capture}" ]]; then
  echo "R1 MeshDB started after recovery CA changed" >&2
  exit 1
fi

node1_store="${tmp}/node1-recovery-store"
node1_first_case="deeploy-crdb-recovery-node1-first-${run_id}"
create_case "${node1_first_case}" "${node1_store}" 3 1 -e TEST_CRDB_START_MODE=corruption_exit
run_case "${node1_first_case}"
assert_exit "${node1_first_case}" 86
assert_active_recovery "${node1_first_case}" "${node1_store}"

node1_init_capture="${tmp}/capture/recovered-node1-init-called"
node1_sql_capture="${tmp}/capture/recovered-node1-bootstrap-called"
node1_sql_input_capture="${tmp}/capture/recovered-node1-bootstrap.sql"
rm -f "${node1_init_capture}" "${node1_sql_capture}" "${node1_sql_input_capture}"
node1_restart_case="deeploy-crdb-recovery-node1-restart-${run_id}"
create_case "${node1_restart_case}" "${node1_store}" 3 1 \
  -e TEST_CRDB_START_MODE=listen_then_exit \
  -e TEST_CRDB_SQL_MODE=success \
  -e TEST_CRDB_INIT_CAPTURE_FILE=/runtime/capture/recovered-node1-init-called \
  -e TEST_CRDB_SQL_CAPTURE_FILE=/runtime/capture/recovered-node1-bootstrap-called \
  -e TEST_CRDB_SQL_INPUT_CAPTURE_FILE=/runtime/capture/recovered-node1-bootstrap.sql \
  -e CRDB_BOOTSTRAP_TIMEOUT_SECONDS=5
run_case "${node1_restart_case}"
assert_exit "${node1_restart_case}" 45
assert_log "${node1_restart_case}" "skipping cluster initialization for a fresh-store recovery"
assert_log "${node1_restart_case}" "fresh-store recovery reached the surviving cluster; ensuring existing database operator privileges"
if [[ -e "${node1_init_capture}" ]]; then
  echo "recovered coordinator invoked cockroach init" >&2
  exit 1
fi
if [[ ! -e "${node1_sql_capture}" ]]; then
  echo "recovered coordinator did not repair database operator privileges" >&2
  exit 1
fi
node1_sql_input="$(docker run --rm -v "${tmp}/capture:/capture:ro" --entrypoint /bin/sh "${image}" \
  -c 'cat /capture/recovered-node1-bootstrap.sql')"
grep -Fxq "ALTER USER app_user WITH CREATEDB CREATEROLE CREATELOGIN;" <<< "${node1_sql_input}"
grep -Fxq "GRANT ALL ON DATABASE appdb TO app_user WITH GRANT OPTION;" <<< "${node1_sql_input}"
if grep -qE "PASSWORD|CREATE (DATABASE|USER)" <<< "${node1_sql_input}"; then
  echo "fresh-store recovery attempted to create identities or change credentials" >&2
  exit 1
fi
node1_sql_input=""

second_case="deeploy-crdb-recovery-second-${run_id}"
create_case "${second_case}" "${recovery_store}" 3 2 -e TEST_CRDB_START_MODE=corruption_exit
run_case "${second_case}"
assert_exit "${second_case}" 86
inspect_store "${recovery_store}" "test ! -e /store/${state_dir_name}/state && grep -Fxq 'state=started' /store/${state_dir_name}/exhausted"
if [[ "$(inspect_store "${recovery_store}" "find /store/${state_dir_name} -mindepth 1 -maxdepth 1 -type d -name 'store.*' | wc -l")" != "1" ]]; then
  echo "second corruption allocated another recovery store" >&2
  exit 1
fi

exhausted_case="deeploy-crdb-recovery-exhausted-${run_id}"
rm -f "${capture_file}"
create_case "${exhausted_case}" "${recovery_store}" 3 2 \
  -e TEST_CRDB_START_MODE=capture_store_exit \
  -e TEST_CRDB_CAPTURE_STORE_FILE=/runtime/capture/selected-store
run_case "${exhausted_case}"
assert_exit "${exhausted_case}" 1
assert_log "${exhausted_case}" "corrupt-store recovery is exhausted"
if [[ -e "${capture_file}" ]]; then
  echo "R1 MeshDB started after recovery was exhausted" >&2
  exit 1
fi

sync_exhaustion_store="${tmp}/sync-exhaustion-store"
sync_exhaustion_first="deeploy-crdb-recovery-sync-exhaustion-first-${run_id}"
create_case "${sync_exhaustion_first}" "${sync_exhaustion_store}" 3 2 -e TEST_CRDB_START_MODE=corruption_exit
run_case "${sync_exhaustion_first}"
assert_exit "${sync_exhaustion_first}" 86
assert_active_recovery "${sync_exhaustion_first}" "${sync_exhaustion_store}"

sync_exhaustion_second="deeploy-crdb-recovery-sync-exhaustion-second-${run_id}"
create_case "${sync_exhaustion_second}" "${sync_exhaustion_store}" 3 2 \
  -e TEST_SYNC_MODE=fail_exhaustion \
  -e TEST_CRDB_START_MODE=corruption_exit
run_case "${sync_exhaustion_second}"
assert_exit "${sync_exhaustion_second}" 86
assert_no_active_recovery "${sync_exhaustion_store}"
inspect_store "${sync_exhaustion_store}" "test -f /store/${state_dir_name}/exhausted"
assert_log "${sync_exhaustion_second}" "fail-closed sentinel remains active"

sync_exhaustion_restart="deeploy-crdb-recovery-sync-exhaustion-restart-${run_id}"
create_case "${sync_exhaustion_restart}" "${sync_exhaustion_store}" 3 2 -e TEST_CRDB_START_MODE=exit
run_case "${sync_exhaustion_restart}"
assert_exit "${sync_exhaustion_restart}" 1
assert_log "${sync_exhaustion_restart}" "corrupt-store recovery is exhausted"

mv_exhaustion_store="${tmp}/mv-exhaustion-store"
mv_exhaustion_first="deeploy-crdb-recovery-mv-exhaustion-first-${run_id}"
create_case "${mv_exhaustion_first}" "${mv_exhaustion_store}" 3 2 -e TEST_CRDB_START_MODE=corruption_exit
run_case "${mv_exhaustion_first}"
assert_exit "${mv_exhaustion_first}" 86
assert_active_recovery "${mv_exhaustion_first}" "${mv_exhaustion_store}"

mv_exhaustion_second="deeploy-crdb-recovery-mv-exhaustion-second-${run_id}"
rm -f "${tmp}/capture/invalid-marker-synced"
create_case "${mv_exhaustion_second}" "${mv_exhaustion_store}" 3 2 \
  -e TEST_ATOMIC_REPLACE_MODE=fail_exhaustion \
  -e TEST_SYNC_MODE=record_invalid_marker \
  -e TEST_CRDB_START_MODE=corruption_exit
run_case "${mv_exhaustion_second}"
assert_exit "${mv_exhaustion_second}" 86
assert_no_active_recovery "${mv_exhaustion_store}"
assert_log "${mv_exhaustion_second}" "invalidating the active marker"
if [[ ! -e "${tmp}/capture/invalid-marker-synced" ]]; then
  echo "fallback exhaustion invalidation did not synchronize the marker file" >&2
  exit 1
fi

mv_exhaustion_restart="deeploy-crdb-recovery-mv-exhaustion-restart-${run_id}"
create_case "${mv_exhaustion_restart}" "${mv_exhaustion_store}" 3 2 -e TEST_CRDB_START_MODE=exit
run_case "${mv_exhaustion_restart}"
assert_exit "${mv_exhaustion_restart}" 1
assert_log "${mv_exhaustion_restart}" "invalid corrupt-store recovery state"

readonly_marker_store="${tmp}/readonly-marker-store"
clone_store "${active_template_store}" "${readonly_marker_store}"
readonly_marker_path="${readonly_marker_store}/${state_dir_name}/state"
readonly_marker_second="deeploy-crdb-recovery-readonly-marker-second-${run_id}"
create_case "${readonly_marker_second}" "${readonly_marker_store}" 3 2 \
  --mount "type=bind,source=${readonly_marker_path},target=/cockroach/cockroach-data/${state_dir_name}/state,readonly" \
  -e TEST_CRDB_START_MODE=corruption_exit
run_case "${readonly_marker_second}"
assert_exit "${readonly_marker_second}" 1
assert_log "${readonly_marker_second}" "could not persist the fresh-store start state"
inspect_store "${readonly_marker_store}" "grep -Fxq 'state=started' /store/${state_dir_name}/state"

readonly_marker_restart="deeploy-crdb-recovery-readonly-marker-restart-${run_id}"
create_case "${readonly_marker_restart}" "${readonly_marker_store}" 3 2 -e TEST_CRDB_START_MODE=exit
run_case "${readonly_marker_restart}"
assert_exit "${readonly_marker_restart}" 42

scan_tail_failure_store="${tmp}/scan-tail-failure-store"
clone_store "${active_template_store}" "${scan_tail_failure_store}"
inspect_store "${scan_tail_failure_store}" \
  "run_dir=\$(find /store/${state_dir_name}/${selected_name}/logs -mindepth 1 -maxdepth 1 -type d -name 'deeploy-run.*' | head -n 1) && printf 'ordinary log\n' > \"\${run_dir}/cockroach.log\""
scan_tail_failure_case="deeploy-crdb-recovery-scan-tail-failure-${run_id}"
create_case "${scan_tail_failure_case}" "${scan_tail_failure_store}" 3 2 \
  -e TEST_TAIL_MODE=fail_run_log \
  -e TEST_CRDB_START_MODE=capture_store_exit \
  -e TEST_CRDB_CAPTURE_STORE_FILE=/runtime/capture/selected-store
rm -f "${capture_file}"
run_case "${scan_tail_failure_case}"
assert_exit "${scan_tail_failure_case}" 1
assert_log "${scan_tail_failure_case}" "could not safely inspect the previous fresh-store run"
if [[ -e "${capture_file}" ]]; then
  echo "R1 MeshDB started after a recovery log read failure" >&2
  exit 1
fi

prune_find_failure_store="${tmp}/prune-find-failure-store"
mkdir -p "${prune_find_failure_store}/logs/deeploy-run.findfail"
initialize_store_log_root "${prune_find_failure_store}"
inspect_store "${prune_find_failure_store}" \
  "chown 0:0 /store/logs/deeploy-run.findfail && chmod 700 /store/logs/deeploy-run.findfail"
prune_find_failure_case="deeploy-crdb-recovery-prune-find-failure-${run_id}"
create_case "${prune_find_failure_case}" "${prune_find_failure_store}" 3 2 \
  -e TEST_FIND_MODE=fail_run_log \
  -e TEST_CRDB_START_MODE=capture_store_exit \
  -e TEST_CRDB_CAPTURE_STORE_FILE=/runtime/capture/selected-store
rm -f "${capture_file}"
run_case "${prune_find_failure_case}"
assert_exit "${prune_find_failure_case}" 1
assert_log "${prune_find_failure_case}" "could not enumerate R1 MeshDB run-log entries"
if [[ -e "${capture_file}" ]]; then
  echo "R1 MeshDB started after run-log pruning enumeration failed" >&2
  exit 1
fi

inspect_store "${recovery_store}" "chown 1000:1000 /store/${state_dir_name}/exhausted"
unowned_exhausted_case="deeploy-crdb-recovery-unowned-exhausted-${run_id}"
create_case "${unowned_exhausted_case}" "${recovery_store}" 3 2 -e TEST_CRDB_START_MODE=exit
run_case "${unowned_exhausted_case}"
assert_exit "${unowned_exhausted_case}" 1
assert_log "${unowned_exhausted_case}" "invalid corrupt-store recovery state"

retention_store="${tmp}/retention-store"
mkdir -p "${retention_store}/logs"
initialize_store_log_root "${retention_store}"
# shellcheck disable=SC2016  # Expanded by the inspection shell in the container.
inspect_store "${retention_store}" '
  i=1
  while [ "$i" -le 12 ]; do
    name=$(printf "safe%04d" "$i")
    mkdir -m 700 "/store/logs/deeploy-run.${name}"
    printf "ordinary log\n" > "/store/logs/deeploy-run.${name}/cockroach.log"
    touch -d "@$((1000000000 + i))" "/store/logs/deeploy-run.${name}"
    i=$((i + 1))
  done
  mkdir -m 700 /store/logs/deeploy-run.bad00000
  printf "local corruption detected: retained fixture (checksum mismatch at 1/1)\n" > /store/logs/deeploy-run.bad00000/cockroach.log
  touch -d "@2000000000" /store/logs/deeploy-run.bad00000
'
retention_case="deeploy-crdb-recovery-retention-${run_id}"
create_case "${retention_case}" "${retention_store}" 3 2 \
  -e CRDB_RECOVERY_LOG_RETENTION_RUNS=10 \
  -e TEST_CRDB_START_MODE=exit
run_case "${retention_case}"
assert_exit "${retention_case}" 42
retained_run_dirs="$(inspect_store "${retention_store}" "find /store/logs -mindepth 1 -maxdepth 1 -type d -name 'deeploy-run.*' | wc -l")"
if [[ "${retained_run_dirs}" != "10" ]] || \
   ! inspect_store "${retention_store}" "test -f /store/logs/deeploy-run.bad00000/cockroach.log"; then
  echo "run-log retention did not keep ten total runs including recent corruption evidence" >&2
  exit 1
fi

log_root_mode_store="${tmp}/log-root-mode-store"
mkdir -p "${log_root_mode_store}/logs"
inspect_store "${log_root_mode_store}" "chown 0:0 /store/logs && chmod 777 /store/logs"
log_root_mode_case="deeploy-crdb-recovery-log-root-mode-${run_id}"
create_case "${log_root_mode_case}" "${log_root_mode_store}" 3 2 -e TEST_CRDB_START_MODE=exit
run_case "${log_root_mode_case}"
assert_exit "${log_root_mode_case}" 1
assert_log "${log_root_mode_case}" "invalid R1 MeshDB log directory"

log_root_legacy_store="${tmp}/log-root-legacy-store"
mkdir -p "${log_root_legacy_store}/logs"
inspect_store "${log_root_legacy_store}" "chown 0:0 /store/logs && chmod 755 /store/logs"
log_root_legacy_case="deeploy-crdb-recovery-log-root-legacy-${run_id}"
create_case "${log_root_legacy_case}" "${log_root_legacy_store}" 3 2 -e TEST_CRDB_START_MODE=exit
run_case "${log_root_legacy_case}"
assert_exit "${log_root_legacy_case}" 42
if [[ "$(inspect_store "${log_root_legacy_store}" "stat -c '%a' /store/logs")" != "700" ]]; then
  echo "legacy R1 MeshDB log directory was not migrated to mode 700" >&2
  exit 1
fi

log_root_owner_store="${tmp}/log-root-owner-store"
mkdir -p "${log_root_owner_store}/logs"
inspect_store "${log_root_owner_store}" "chown 1000:1000 /store/logs && chmod 700 /store/logs"
log_root_owner_case="deeploy-crdb-recovery-log-root-owner-${run_id}"
create_case "${log_root_owner_case}" "${log_root_owner_store}" 3 2 -e TEST_CRDB_START_MODE=exit
run_case "${log_root_owner_case}"
assert_exit "${log_root_owner_case}" 1
assert_log "${log_root_owner_case}" "invalid R1 MeshDB log directory"

run_mode_store="${tmp}/run-mode-store"
mkdir -p "${run_mode_store}/logs/deeploy-run.badmode0"
initialize_store_log_root "${run_mode_store}"
inspect_store "${run_mode_store}" "chown 0:0 /store/logs/deeploy-run.badmode0 && chmod 755 /store/logs/deeploy-run.badmode0"
run_mode_case="deeploy-crdb-recovery-run-mode-${run_id}"
create_case "${run_mode_case}" "${run_mode_store}" 3 2 -e TEST_CRDB_START_MODE=exit
run_case "${run_mode_case}"
assert_exit "${run_mode_case}" 1
assert_log "${run_mode_case}" "invalid R1 MeshDB run-log entry"

run_owner_store="${tmp}/run-owner-store"
mkdir -p "${run_owner_store}/logs/deeploy-run.badownr0"
initialize_store_log_root "${run_owner_store}"
inspect_store "${run_owner_store}" "chown 1000:1000 /store/logs/deeploy-run.badownr0 && chmod 700 /store/logs/deeploy-run.badownr0"
run_owner_case="deeploy-crdb-recovery-run-owner-${run_id}"
create_case "${run_owner_case}" "${run_owner_store}" 3 2 -e TEST_CRDB_START_MODE=exit
run_case "${run_owner_case}"
assert_exit "${run_owner_case}" 1
assert_log "${run_owner_case}" "invalid R1 MeshDB run-log entry"

mounted_run_store="${tmp}/mounted-run-store"
mounted_run_external="${tmp}/mounted-run-external"
mkdir -p "${mounted_run_store}/logs/deeploy-run.mounted1/external" "${mounted_run_external}"
printf 'must remain\n' > "${mounted_run_external}/sentinel"
initialize_store_log_root "${mounted_run_store}"
inspect_store "${mounted_run_store}" "chown 0:0 /store/logs/deeploy-run.mounted1 && chmod 700 /store/logs/deeploy-run.mounted1"
mounted_run_case="deeploy-crdb-recovery-run-mount-${run_id}"
create_case "${mounted_run_case}" "${mounted_run_store}" 3 2 \
  --mount "type=bind,source=${mounted_run_external},target=/cockroach/cockroach-data/logs/deeploy-run.mounted1/external" \
  -e TEST_CRDB_START_MODE=exit
run_case "${mounted_run_case}"
assert_exit "${mounted_run_case}" 1
assert_log "${mounted_run_case}" "invalid R1 MeshDB run-log entry"
grep -Fxq 'must remain' "${mounted_run_external}/sentinel"

rm_failure_store="${tmp}/rm-failure-store"
mkdir -p "${rm_failure_store}/logs"
initialize_store_log_root "${rm_failure_store}"
# shellcheck disable=SC2016  # Expanded by the inspection shell in the container.
inspect_store "${rm_failure_store}" '
  i=1
  while [ "$i" -le 11 ]; do
    name=$(printf "old%05d" "$i")
    mkdir -m 700 "/store/logs/deeploy-run.${name}"
    i=$((i + 1))
  done
'
rm -f "${tmp}/capture/rm-failed-once"
rm_failure_case="deeploy-crdb-recovery-rm-failure-${run_id}"
create_case "${rm_failure_case}" "${rm_failure_store}" 3 2 \
  -e TEST_RM_MODE=fail_once_run_log \
  -e TEST_CRDB_START_MODE=exit
run_case "${rm_failure_case}"
assert_exit "${rm_failure_case}" 1
assert_log "${rm_failure_case}" "could not remove old R1 MeshDB run-log entry"

logs_symlink_store="${tmp}/logs-symlink-store"
external_logs="${tmp}/capture/external-logs"
mkdir -p "${logs_symlink_store}" "${external_logs}"
ln -s /runtime/capture/external-logs "${logs_symlink_store}/logs"
logs_symlink_case="deeploy-crdb-recovery-logs-symlink-${run_id}"
create_case "${logs_symlink_case}" "${logs_symlink_store}" 3 2 -e TEST_CRDB_START_MODE=exit
run_case "${logs_symlink_case}"
assert_exit "${logs_symlink_case}" 1
assert_log "${logs_symlink_case}" "invalid R1 MeshDB log directory"
if find "${external_logs}" -mindepth 1 -print -quit | grep -q .; then
  echo "symlinked log directory escaped the R1 MeshDB store" >&2
  exit 1
fi

malformed_store="${tmp}/malformed-store"
mkdir -p "${malformed_store}/${state_dir_name}"
printf 'invalid\n' > "${malformed_store}/${state_dir_name}/state"
chmod 600 "${malformed_store}/${state_dir_name}/state"
malformed_case="deeploy-crdb-recovery-malformed-${run_id}"
create_case "${malformed_case}" "${malformed_store}" 3 2 -e TEST_CRDB_START_MODE=exit
run_case "${malformed_case}"
assert_exit "${malformed_case}" 1
assert_log "${malformed_case}" "invalid corrupt-store recovery state"

symlink_store="${tmp}/symlink-store"
mkdir -p "${symlink_store}"
ln -s /tmp "${symlink_store}/${state_dir_name}"
symlink_case="deeploy-crdb-recovery-symlink-${run_id}"
create_case "${symlink_case}" "${symlink_store}" 3 2 -e TEST_CRDB_START_MODE=exit
run_case "${symlink_case}"
assert_exit "${symlink_case}" 1
assert_log "${symlink_case}" "invalid corrupt-store recovery state"

for name in "${containers[@]}"; do
  logs="$(docker logs "${name}" 2>&1 || true)"
  if grep -Fq 'store_recovery_secret' <<< "${logs}" || grep -Fq 'store-recovery-fake-token' <<< "${logs}"; then
    echo "secret leaked into ${name} logs" >&2
    exit 1
  fi
  cloudflare_logs="${tmp}/cloudflare-${name}"
  if docker cp "${name}:/tmp/cloudflared/." "${cloudflare_logs}" >/dev/null 2>&1; then
    if grep -R -Fq 'store_recovery_secret' "${cloudflare_logs}" || \
       grep -R -Fq 'store-recovery-fake-token' "${cloudflare_logs}"; then
      echo "secret leaked into ${name} Cloudflare logs" >&2
      exit 1
    fi
  fi
done

echo "store recovery regression ok"
