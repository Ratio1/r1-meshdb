#!/usr/bin/env bash
set -euo pipefail

base_image="${1:-ghcr.io/ratio1/deeploy-cockroachdb-service:main}"
expectation="${2:-fixed}"
broken_base_image="${CRDB_BROKEN_BASE_IMAGE:-ghcr.io/ratio1/deeploy-cockroachdb-service@sha256:1c082541525f2ec73b07286f9773c5069f70c959c9e67f4a5e1d5200688a1ebe}"
case "${expectation}" in
  broken) base_image="${broken_base_image}" ;;
  fixed) ;;
  *)
    echo "expectation must be 'broken' or 'fixed'" >&2
    exit 2
    ;;
esac
run_id="$$-${RANDOM}"
test_image="deeploy-crdb-runtime-supervision:${run_id}"
tmp="$(mktemp -d /tmp/deeploy-crdb-runtime-supervision.XXXXXX)"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
containers=()
test_label="com.ratio1.deeploy-crdb-runtime-supervision=${run_id}"

cleanup() {
  local status=$?
  local cleanup_failed=0
  local name
  trap - EXIT
  for name in "${containers[@]}"; do
    docker rm -f "${name}" >/dev/null 2>&1 || true
  done
  docker ps -aq --filter "label=${test_label}" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker ps -aq --filter "label=${test_label}" | grep -q . && cleanup_failed=1
  docker image rm -f "${test_image}" >/dev/null 2>&1 || true
  docker image inspect "${test_image}" >/dev/null 2>&1 && cleanup_failed=1
  rm -rf "${tmp}" || cleanup_failed=1
  [[ ! -e "${tmp}" ]] || cleanup_failed=1
  if [[ "${status}" == "0" && "${cleanup_failed}" != "0" ]]; then
    echo "runtime supervision smoke cleanup failed" >&2
    status=1
  fi
  exit "${status}"
}
trap cleanup EXIT

# shellcheck disable=SC2016  # Match the literal default expression in the entrypoint.
if ! grep -Fq \
    'CRDB_BOOTSTRAP_TIMEOUT_SECONDS="${CRDB_BOOTSTRAP_TIMEOUT_SECONDS:-300}"' \
    "${repo_root}/entrypoint.sh"; then
  echo "production bootstrap timeout default is not 300 seconds" >&2
  exit 1
fi

docker build \
  --build-arg "BASE_IMAGE=${base_image}" \
  --build-arg "ENTRYPOINT_MODE=${expectation}" \
  --label "${test_label}" \
  -f tests/runtime-supervision/Dockerfile \
  -t "${test_image}" \
  . >/dev/null

mkdir -p "${tmp}/certs" "${tmp}/token"
printf 'runtime-supervision-fake-token\n' > "${tmp}/token/cf-token"

docker run --rm -u "$(id -u):$(id -g)" -v "${tmp}/certs:/certs" --entrypoint /cockroach/cockroach "${base_image}" \
  cert create-ca --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
docker run --rm -u "$(id -u):$(id -g)" -v "${tmp}/certs:/certs" --entrypoint /cockroach/cockroach "${base_image}" \
  cert create-node roach1 localhost 127.0.0.1 --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
docker run --rm -u "$(id -u):$(id -g)" -v "${tmp}/certs:/certs" --entrypoint /cockroach/cockroach "${base_image}" \
  cert create-client root --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
rm -f "${tmp}/certs/ca.key"

container_has_command() {
  local name="$1"
  local needle="$2"
  local processes
  processes="$(docker top "${name}" -eo pid,args 2>/dev/null)" || return 1
  case "${processes}" in
    *"${needle}"*) return 0 ;;
    *) return 1 ;;
  esac
}

wait_for_command() {
  local name="$1"
  local prefix="$2"
  local attempts="${3:-240}"
  for _ in $(seq 1 "${attempts}"); do
    if container_has_command "${name}" "${prefix}"; then
      return 0
    fi
    if [[ "$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || true)" != "true" ]]; then
      break
    fi
    sleep 0.25
  done
  docker top "${name}" -eo pid,args >&2 2>/dev/null || true
  docker logs "${name}" >&2 2>/dev/null || true
  echo "timed out waiting for command '${prefix}' in ${name}" >&2
  return 1
}

wait_for_exit() {
  local name="$1"
  local timeout_seconds="${2:-5}"
  local deadline=$(( $(date +%s) + timeout_seconds ))
  while true; do
    if [[ "$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || true)" != "true" ]]; then
      [[ "$(date +%s)" -le "${deadline}" ]]
      return
    fi
    [[ "$(date +%s)" -lt "${deadline}" ]] || return 1
    sleep 0.25
  done
}

wait_for_file() {
  local name="$1"
  local path="$2"
  local attempts="${3:-240}"
  for _ in $(seq 1 "${attempts}"); do
    if docker exec "${name}" test -f "${path}" >/dev/null 2>&1; then
      return 0
    fi
    if [[ "$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || true)" != "true" ]]; then
      break
    fi
    sleep 0.25
  done
  docker logs "${name}" >&2 2>/dev/null || true
  echo "timed out waiting for file '${path}' in ${name}" >&2
  return 1
}

wait_for_log() {
  local name="$1"
  local expected="$2"
  local timeout_seconds="${3:-60}"
  local deadline=$(( $(date +%s) + timeout_seconds ))
  while true; do
    if docker logs "${name}" 2>&1 | grep -Fq "${expected}"; then
      return 0
    fi
    if [[ "$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || true)" != "true" ]]; then
      break
    fi
    [[ "$(date +%s)" -lt "${deadline}" ]] || break
    sleep 0.25
  done
  docker logs "${name}" >&2 2>/dev/null || true
  echo "timed out waiting for log '${expected}' in ${name}" >&2
  return 1
}

monotonic_millis() {
  local uptime seconds fraction
  read -r uptime _ < /proc/uptime
  seconds="${uptime%%.*}"
  fraction="${uptime#*.}000"
  fraction="${fraction:0:3}"
  TEST_MONOTONIC_MILLIS=$((10#${seconds} * 1000 + 10#${fraction}))
}

kill_real_server() {
  local name="$1"
  docker exec "${name}" sh -c '
    found=0
    for command_file in /proc/[0-9]*/cmdline; do
      command="$(tr "\0" " " 2>/dev/null < "${command_file}" || true)"
      case "${command}" in
        "/cockroach/cockroach-real start "*)
          pid="${command_file#/proc/}"
          pid="${pid%/cmdline}"
          kill -KILL "${pid}"
          found=1
          ;;
      esac
    done
    [ "${found}" = "1" ]
  '
}

start_case() {
  local name="$1"
  local -a timeout_args=(-e CRDB_BOOTSTRAP_TIMEOUT_SECONDS=3)
  shift
  if [[ "${1:-}" == "--use-image-default-timeout" ]]; then
    timeout_args=()
    shift
  fi
  containers+=("${name}")
  docker run -d --name "${name}" \
    --label "${test_label}" \
    -v "${tmp}/certs/ca.crt:/runtime/ca.crt:ro" \
    -v "${tmp}/certs/node.crt:/runtime/node.crt:ro" \
    -v "${tmp}/certs/node.key:/runtime/node.key:ro" \
    -v "${tmp}/certs/client.root.crt:/runtime/client.root.crt:ro" \
    -v "${tmp}/certs/client.root.key:/runtime/client.root.key:ro" \
    -v "${tmp}/token/cf-token:/runtime/cf-token:ro" \
    -e CRDB_NODE_ID=1 \
    -e CRDB_NODE_COUNT=1 \
    -e CRDB_HOSTNAMES=roach1.local \
    -e CRDB_DATABASE=appdb \
    -e CRDB_USER=app_user \
    -e CRDB_PASSWORD=runtime_supervision_secret \
    -e CRDB_LISTEN_HOST=127.0.0.1 \
    -e CRDB_CA_CRT_FILE=/runtime/ca.crt \
    -e CRDB_NODE_CRT_FILE=/runtime/node.crt \
    -e CRDB_NODE_KEY_FILE=/runtime/node.key \
    -e CRDB_CLIENT_ROOT_CRT_FILE=/runtime/client.root.crt \
    -e CRDB_CLIENT_ROOT_KEY_FILE=/runtime/client.root.key \
    -e CF_TUNNEL_TOKEN_FILE=/runtime/cf-token \
    "${timeout_args[@]}" \
    -e CRDB_SHUTDOWN_GRACE_SECONDS=1 \
    "$@" \
    "${test_image}" >/dev/null
}

assert_failed_cleanly() {
  local name="$1"
  local expected_log="$2"
  local expected_exit_code="$3"
  local timeout_seconds="${4:-5}"
  if ! wait_for_exit "${name}" "${timeout_seconds}"; then
    docker logs "${name}" >&2 2>/dev/null || true
    echo "${name} remained running after CockroachDB exited" >&2
    return 1
  fi

  local exit_code
  exit_code="$(docker inspect -f '{{.State.ExitCode}}' "${name}")"
  if [[ "${exit_code}" != "${expected_exit_code}" ]]; then
    docker logs "${name}" >&2 2>/dev/null || true
    echo "${name} exited ${exit_code}, expected ${expected_exit_code}" >&2
    return 1
  fi

  local logs
  logs="$(docker logs "${name}" 2>&1 || true)"
  grep -Fq "${expected_log}" <<< "${logs}"
  if grep -Fq 'runtime_supervision_secret' <<< "${logs}"; then
    echo "database password leaked into ${name} logs" >&2
    return 1
  fi
  if grep -Fq 'runtime-supervision-fake-token' <<< "${logs}"; then
    echo "Cloudflare token leaked into ${name} logs" >&2
    return 1
  fi
}

assert_baseline_false_running() {
  local name="$1"
  sleep 3
  if [[ "$(docker inspect -f '{{.State.Running}}' "${name}")" != "true" ]]; then
    docker logs "${name}" >&2 2>/dev/null || true
    echo "baseline container exited; false-running regression was not reproduced" >&2
    return 1
  fi
  if container_has_command "${name}" "/cockroach/cockroach-real start "; then
    echo "baseline CockroachDB server did not exit" >&2
    return 1
  fi
  if ! container_has_command "${name}" "/cockroach/cockroach init "; then
    echo "baseline init client is not blocked" >&2
    return 1
  fi
  echo "baseline false-running state reproduced"
}

assert_no_bootstrap_temp() {
  local name="$1"
  local destination="${tmp}/tmp-${name}"
  mkdir -p "${destination}"
  docker cp "${name}:/tmp/." "${destination}" >/dev/null
  if find "${destination}" -maxdepth 1 \
    \( -name 'deeploy-crdb-bootstrap.*' -o -name 'deeploy-crdb-init.*' \) \
    -print -quit | grep -q .; then
    echo "bootstrap temporary file remains after ${name} exited" >&2
    return 1
  fi
}

init_case="deeploy-crdb-supervision-init-${run_id}"
start_case "${init_case}" -e TEST_CRDB_INIT_MODE=block
wait_for_command "${init_case}" "/cockroach/cockroach init "
kill_real_server "${init_case}"

if [[ "${expectation}" == "broken" ]]; then
  assert_baseline_false_running "${init_case}"
  exit 0
fi
assert_failed_cleanly "${init_case}" "CockroachDB exited during cluster initialization" 137
assert_no_bootstrap_temp "${init_case}"

pre_listener_case="deeploy-crdb-supervision-listener-${run_id}"
start_case "${pre_listener_case}" -e TEST_CRDB_START_MODE=exit -e TEST_CRDB_START_EXIT_CODE=42
assert_failed_cleanly "${pre_listener_case}" "CockroachDB exited during SQL listener readiness" 42

timeout_upper_bound_case="deeploy-crdb-supervision-timeout-upper-bound-${run_id}"
start_case "${timeout_upper_bound_case}" -e CRDB_BOOTSTRAP_TIMEOUT_SECONDS=3601
assert_failed_cleanly "${timeout_upper_bound_case}" \
  "CRDB_BOOTSTRAP_TIMEOUT_SECONDS must not exceed 3600" 1

sql_listener_timeout_case="deeploy-crdb-supervision-listener-timeout-${run_id}"
start_case "${sql_listener_timeout_case}" -e TEST_CRDB_START_MODE=block_no_listener
assert_failed_cleanly "${sql_listener_timeout_case}" \
  "CockroachDB SQL listener did not open on 127.0.0.1:26257 within 3 seconds" 1 8

default_timeout_case="deeploy-crdb-supervision-default-timeout-${run_id}"
start_case "${default_timeout_case}" \
  --use-image-default-timeout \
  -e TEST_CRDB_START_MODE=listen_after_delay \
  -e TEST_CRDB_LISTEN_DELAY_SECONDS=61 \
  -e TEST_CRDB_INIT_MODE=success \
  -e TEST_CRDB_SQL_MODE=success
wait_for_log "${default_timeout_case}" \
  "startup orchestration complete; supervising required processes" 90
docker kill --signal TERM "${default_timeout_case}" >/dev/null
if ! wait_for_exit "${default_timeout_case}" 5 || \
   [[ "$(docker inspect -f '{{.State.ExitCode}}' "${default_timeout_case}")" != "143" ]]; then
  docker logs "${default_timeout_case}" >&2 2>/dev/null || true
  echo "default timeout readiness case did not stop cleanly" >&2
  exit 1
fi

sql_case="deeploy-crdb-supervision-sql-${run_id}"
start_case "${sql_case}" -e TEST_CRDB_INIT_MODE=success -e TEST_CRDB_SQL_MODE=block
wait_for_command "${sql_case}" "/cockroach/cockroach sql "
kill_real_server "${sql_case}"
assert_failed_cleanly "${sql_case}" "CockroachDB exited during SQL bootstrap readiness" 137
assert_no_bootstrap_temp "${sql_case}"

bootstrap_case="deeploy-crdb-supervision-bootstrap-${run_id}"
start_case "${bootstrap_case}" -e TEST_CRDB_INIT_MODE=success -e TEST_CRDB_SQL_MODE=block_bootstrap
wait_for_file "${bootstrap_case}" /tmp/runtime-supervision-readiness-complete
wait_for_command "${bootstrap_case}" "/cockroach/cockroach sql "
kill_real_server "${bootstrap_case}"
assert_failed_cleanly "${bootstrap_case}" "CockroachDB exited during SQL bootstrap" 137
assert_no_bootstrap_temp "${bootstrap_case}"

cleanup_rm_case="deeploy-crdb-supervision-cleanup-rm-${run_id}"
start_case "${cleanup_rm_case}" \
  -e TEST_CRDB_INIT_MODE=success \
  -e TEST_CRDB_SQL_MODE=block_bootstrap \
  -e TEST_RM_MODE=fail_once_secret_temp
wait_for_file "${cleanup_rm_case}" /tmp/runtime-supervision-readiness-complete
wait_for_command "${cleanup_rm_case}" "/cockroach/cockroach sql "
docker kill --signal TERM "${cleanup_rm_case}" >/dev/null
assert_failed_cleanly "${cleanup_rm_case}" "could not remove a sensitive temporary file" 143
assert_no_bootstrap_temp "${cleanup_rm_case}"

simultaneous_case="deeploy-crdb-supervision-simultaneous-${run_id}"
start_case "${simultaneous_case}" -e TEST_CRDB_INIT_MODE=success -e TEST_CRDB_SQL_MODE=fail_then_kill_server
assert_failed_cleanly "${simultaneous_case}" "CockroachDB exited during" 137
assert_no_bootstrap_temp "${simultaneous_case}"

timeout_case="deeploy-crdb-supervision-timeout-${run_id}"
start_case "${timeout_case}" -e TEST_CRDB_INIT_MODE=block
wait_for_command "${timeout_case}" "/cockroach/cockroach init "
assert_failed_cleanly "${timeout_case}" "cluster initialization timed out after 3 seconds" 124 8
assert_no_bootstrap_temp "${timeout_case}"

sql_timeout_case="deeploy-crdb-supervision-sql-timeout-${run_id}"
start_case "${sql_timeout_case}" -e TEST_CRDB_INIT_MODE=success -e TEST_CRDB_SQL_MODE=block
wait_for_command "${sql_timeout_case}" "/cockroach/cockroach sql "
assert_failed_cleanly "${sql_timeout_case}" "SQL bootstrap readiness timed out after 3 seconds" 124 8
assert_no_bootstrap_temp "${sql_timeout_case}"

ddl_timeout_case="deeploy-crdb-supervision-ddl-timeout-${run_id}"
start_case "${ddl_timeout_case}" -e TEST_CRDB_INIT_MODE=success -e TEST_CRDB_SQL_MODE=block_bootstrap
wait_for_file "${ddl_timeout_case}" /tmp/runtime-supervision-readiness-complete
wait_for_command "${ddl_timeout_case}" "/cockroach/cockroach sql "
assert_failed_cleanly "${ddl_timeout_case}" "SQL bootstrap timed out after 3 seconds" 124 8
assert_no_bootstrap_temp "${ddl_timeout_case}"

ddl_failure_case="deeploy-crdb-supervision-ddl-failure-${run_id}"
start_case "${ddl_failure_case}" -e TEST_CRDB_INIT_MODE=success -e TEST_CRDB_SQL_MODE=fail_bootstrap
assert_failed_cleanly "${ddl_failure_case}" "SQL bootstrap failed with status 47; command output suppressed because it may contain credentials" 47
attempts_file="${tmp}/bootstrap-attempts"
docker cp "${ddl_failure_case}:/tmp/runtime-supervision-bootstrap-attempts" "${attempts_file}" >/dev/null
if [[ "$(wc -l < "${attempts_file}")" != "1" ]]; then
  echo "permanent SQL bootstrap failure was retried" >&2
  exit 1
fi
assert_no_bootstrap_temp "${ddl_failure_case}"

resistant_timeout_case="deeploy-crdb-supervision-resistant-timeout-${run_id}"
start_case "${resistant_timeout_case}" -e TEST_CRDB_INIT_MODE=ignore_term
wait_for_command "${resistant_timeout_case}" "/cockroach/cockroach init "
assert_failed_cleanly "${resistant_timeout_case}" "initializing CockroachDB cluster if needed" 137 10
assert_no_bootstrap_temp "${resistant_timeout_case}"

compound_case="deeploy-crdb-supervision-compound-${run_id}"
start_case "${compound_case}" \
  -e TEST_CRDB_INIT_MODE=ignore_term \
  -e TEST_CLOUDFLARED_SERVER_MODE=ignore_term \
  -e CRDB_SHUTDOWN_GRACE_SECONDS=3
wait_for_command "${compound_case}" "/cockroach/cockroach init "
kill_real_server "${compound_case}"
assert_failed_cleanly "${compound_case}" "CockroachDB exited during cluster initialization" 137 5
assert_no_bootstrap_temp "${compound_case}"

cloudflared_case="deeploy-crdb-supervision-cloudflared-${run_id}"
start_case "${cloudflared_case}" -e TEST_CRDB_INIT_MODE=block -e TEST_CLOUDFLARED_MODE=exit -e TEST_CLOUDFLARED_EXIT_CODE=23
assert_failed_cleanly "${cloudflared_case}" "Cloudflare server tunnel exited during SQL listener readiness" 23

zero_exit_case="deeploy-crdb-supervision-zero-exit-${run_id}"
start_case "${zero_exit_case}" -e TEST_CRDB_INIT_MODE=block -e TEST_CLOUDFLARED_MODE=exit -e TEST_CLOUDFLARED_EXIT_CODE=0
assert_failed_cleanly "${zero_exit_case}" "Cloudflare server tunnel exited during SQL listener readiness with status 1" 1

access_case="deeploy-crdb-supervision-access-${run_id}"
start_case "${access_case}" \
  -e CRDB_NODE_COUNT=2 \
  -e CRDB_HOSTNAMES=roach1.local,roach2.local \
  -e TEST_CLOUDFLARED_ACCESS_MODE=exit \
  -e TEST_CLOUDFLARED_ACCESS_EXIT_CODE=24
assert_failed_cleanly "${access_case}" "Cloudflare access listener for roach2 exited during peer listener readiness" 24

peer_listener_timeout_case="deeploy-crdb-supervision-peer-listener-timeout-${run_id}"
monotonic_millis
peer_listener_timeout_overall_started_ms="${TEST_MONOTONIC_MILLIS}"
start_case "${peer_listener_timeout_case}" \
  -e CRDB_NODE_COUNT=3 \
  -e CRDB_HOSTNAMES=roach1.local,roach2.local,roach3.local \
  -e TEST_CLOUDFLARED_ACCESS_LISTEN_DELAY_HOSTNAME=roach2.local \
  -e TEST_CLOUDFLARED_ACCESS_LISTEN_DELAY_SECONDS=2 \
  -e TEST_CLOUDFLARED_ACCESS_PROBE_CAPTURE_HOSTNAME=roach2.local \
  -e TEST_CLOUDFLARED_ACCESS_BLOCK_HOSTNAME=roach3.local
wait_for_log "${peer_listener_timeout_case}" \
  "starting access listener for roach3 via roach3.local on 127.77.0.3:26257" 3
monotonic_millis
peer_listener_timeout_started_ms="${TEST_MONOTONIC_MILLIS}"
peer_listener_timeout_log="one or more Cloudflare peer access listeners did not become ready within 3 seconds"
wait_for_log "${peer_listener_timeout_case}" "${peer_listener_timeout_log}" 6
monotonic_millis
peer_listener_timeout_elapsed_ms=$((TEST_MONOTONIC_MILLIS - peer_listener_timeout_started_ms))
peer_listener_timeout_overall_elapsed_ms=$((TEST_MONOTONIC_MILLIS - peer_listener_timeout_overall_started_ms))
if [[ "${peer_listener_timeout_elapsed_ms}" -gt 3500 ]]; then
  echo "peer readiness exceeded its shared deadline: ${peer_listener_timeout_elapsed_ms}ms" >&2
  exit 1
fi
if [[ "${peer_listener_timeout_overall_elapsed_ms}" -gt 4500 ]]; then
  echo "peer readiness exceeded its startup-inclusive deadline: ${peer_listener_timeout_overall_elapsed_ms}ms" >&2
  exit 1
fi
assert_failed_cleanly "${peer_listener_timeout_case}" "${peer_listener_timeout_log}" 1 8
peer_probe_capture="${tmp}/peer-probes"
docker cp "${peer_listener_timeout_case}:/tmp/cloudflared/peer-probes" "${peer_probe_capture}" >/dev/null
peer_probe_count="$(wc -l < "${peer_probe_capture}")"
if [[ "${peer_probe_count}" != "1" ]]; then
  echo "ready peer was probed ${peer_probe_count} times, expected once" >&2
  exit 1
fi

runtime_case="deeploy-crdb-supervision-runtime-${run_id}"
start_case "${runtime_case}" \
  -e TEST_CRDB_INIT_MODE=success \
  -e TEST_CRDB_SQL_MODE=fail_once \
  -e TEST_CLOUDFLARED_SERVER_MODE=ignore_term
wait_for_file "${runtime_case}" /tmp/runtime-supervision-sql-complete
wait_for_log "${runtime_case}" "startup orchestration complete; supervising required processes"
kill_real_server "${runtime_case}"
assert_failed_cleanly "${runtime_case}" "CockroachDB exited during runtime" 137

bash scripts/store-recovery-regression.sh "${test_image}" "${run_id}"
bash scripts/store-recovery-multinode-smoke.sh "${test_image}" "${run_id}"
bash scripts/entrypoint-multinode-smoke.sh "${test_image}" "${run_id}"

for name in "${containers[@]}"; do
  docker rm -f "${name}" >/dev/null 2>&1 || true
done
if docker ps -aq --filter "label=${test_label}" | grep -q .; then
  echo "runtime supervision test resources remain" >&2
  exit 1
fi

echo "runtime supervision smoke ok"
