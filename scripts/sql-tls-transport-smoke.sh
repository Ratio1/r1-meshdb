#!/usr/bin/env bash
set -euo pipefail

image="${1:-deeploy-cockroachdb-service:local}"
client_image="${CRDB_TEST_CLIENT_IMAGE:-postgres@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777}"
sniffer_image="${CRDB_TEST_SNIFFER_IMAGE:-nicolaka/netshoot@sha256:a20c2531bf35436ed3766cd6cfe89d352b050ccc4d7005ce6400adf97503da1b}"
run_id="$$-${RANDOM}"
network="deeploy-crdb-sql-tls-${run_id}"
server="deeploy-crdb-sql-tls-server-${run_id}"
client="deeploy-crdb-sql-tls-client-${run_id}"
sniffer="deeploy-crdb-sql-tls-sniffer-${run_id}"
tmp="$(mktemp -d /tmp/deeploy-crdb-sql-tls.XXXXXX)"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
password="tls_transport_password_${run_id}"
token_canary="tls-transport-token-${run_id}"
plaintext_request="CRDB_PLAINTEXT_REQUEST_${run_id}"
tls_request="CRDB_TLS_REQUEST_${run_id}"
plaintext_response="$(printf '%s' "${plaintext_request}" | md5sum | awk '{print $1}')"
tls_response="$(printf '%s' "${tls_request}" | md5sum | awk '{print $1}')"

cleanup() {
  local status=$?
  local cleanup_failed=0
  trap - EXIT
  docker rm -f "${sniffer}" "${client}" "${server}" >/dev/null 2>&1 || true
  for resource in "${sniffer}" "${client}" "${server}"; do
    docker inspect "${resource}" >/dev/null 2>&1 && cleanup_failed=1
  done
  docker network rm "${network}" >/dev/null 2>&1 || true
  docker network inspect "${network}" >/dev/null 2>&1 && cleanup_failed=1
  docker run --rm -v "${tmp}:/cleanup" --entrypoint /bin/sh "${image}" \
    -c 'find /cleanup -mindepth 1 -delete' >/dev/null 2>&1 || cleanup_failed=1
  rmdir "${tmp}" >/dev/null 2>&1 || cleanup_failed=1
  if [[ "${status}" == "0" && "${cleanup_failed}" != "0" ]]; then
    echo "SQL TLS transport smoke cleanup failed" >&2
    status=1
  fi
  exit "${status}"
}
trap cleanup EXIT

mkdir -p "${tmp}/certs" "${tmp}/capture" "${tmp}/store" "${tmp}/token"
chmod 700 "${tmp}" "${tmp}/certs" "${tmp}/capture" "${tmp}/store" "${tmp}/token"
printf '%s\n' "${token_canary}" > "${tmp}/token/cf-token"
chmod 600 "${tmp}/token/cf-token"

docker pull "${client_image}" >/dev/null
docker pull "${sniffer_image}" >/dev/null
docker image inspect "${client_image}" >/dev/null
docker image inspect "${sniffer_image}" >/dev/null
docker run --rm -v "${tmp}/store:/store" --entrypoint /bin/sh "${image}" \
  -c 'chown 0:0 /store && chmod 700 /store'
docker run --rm -u "$(id -u):$(id -g)" -v "${tmp}/certs:/certs" \
  --entrypoint /cockroach/cockroach "${image}" \
  cert create-ca --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
docker run --rm -u "$(id -u):$(id -g)" -v "${tmp}/certs:/certs" \
  --entrypoint /cockroach/cockroach "${image}" \
  cert create-node roach1 localhost 127.0.0.1 --certs-dir=/certs \
  --ca-key=/certs/ca.key >/dev/null
docker run --rm -u "$(id -u):$(id -g)" -v "${tmp}/certs:/certs" \
  --entrypoint /cockroach/cockroach "${image}" \
  cert create-client root --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
rm -f "${tmp}/certs/ca.key"

docker network create "${network}" >/dev/null
docker run -d --name "${client}" --network "${network}" --entrypoint /bin/sh "${client_image}" \
  -c 'exec sleep 3600' >/dev/null
client_ip="$(docker inspect -f "{{with index .NetworkSettings.Networks \"${network}\"}}{{.IPAddress}}{{end}}" "${client}")"
if [[ -z "${client_ip}" ]]; then
  echo "SQL TLS client has no IP on ${network}" >&2
  exit 1
fi

start_server() {
  local mode="${1:-default}"
  local -a mode_env=()
  docker rm -f "${server}" >/dev/null 2>&1 || true
  if [[ "${mode}" != "default" ]]; then
    mode_env=(-e "CRDB_ACCEPT_SQL_WITHOUT_TLS=${mode}")
  fi
  docker run -d --name "${server}" --hostname roach1 --network "${network}" \
    --network-alias roach1 \
    -v "${tmp}/certs/ca.crt:/runtime/ca.crt:ro" \
    -v "${tmp}/certs/node.crt:/runtime/node.crt:ro" \
    -v "${tmp}/certs/node.key:/runtime/node.key:ro" \
    -v "${tmp}/certs/client.root.crt:/runtime/client.root.crt:ro" \
    -v "${tmp}/certs/client.root.key:/runtime/client.root.key:ro" \
    -v "${tmp}/token/cf-token:/runtime/cf-token:ro" \
    -v "${tmp}/store:/cockroach/cockroach-data" \
    -v "${repo_root}/tests/runtime-supervision/cloudflared-test-stub.sh:/usr/local/bin/cloudflared:ro" \
    -e CRDB_NODE_ID=1 \
    -e CRDB_NODE_COUNT=1 \
    -e CRDB_HOSTNAMES=roach1.local \
    -e CRDB_DATABASE=appdb \
    -e CRDB_USER=app_user \
    -e "CRDB_PASSWORD=${password}" \
    -e CRDB_LISTEN_HOST=0.0.0.0 \
    -e CRDB_MAX_OFFSET=5s \
    -e CRDB_CA_CRT_FILE=/runtime/ca.crt \
    -e CRDB_NODE_CRT_FILE=/runtime/node.crt \
    -e CRDB_NODE_KEY_FILE=/runtime/node.key \
    -e CRDB_CLIENT_ROOT_CRT_FILE=/runtime/client.root.crt \
    -e CRDB_CLIENT_ROOT_KEY_FILE=/runtime/client.root.key \
    -e CF_TUNNEL_TOKEN_FILE=/runtime/cf-token \
    -e CRDB_BOOTSTRAP_TIMEOUT_SECONDS=60 \
    "${mode_env[@]}" \
    "${image}" >/dev/null
}

client_sql() {
  local sslmode="$1"
  shift
  docker exec -i -e "PGPASSWORD=${password}" "${client}" psql \
    --set ON_ERROR_STOP=1 \
    --dbname "postgresql://app_user@roach1:26257/appdb?sslmode=${sslmode}" "$@"
}

wait_for_sql() {
  local sslmode="$1"
  local deadline=$((SECONDS + 120))
  while [[ "${SECONDS}" -lt "${deadline}" ]]; do
    if client_sql "${sslmode}" -c 'select 1' >/dev/null 2>&1; then
      return 0
    fi
    if [[ "$(docker inspect -f '{{.State.Running}}' "${server}" 2>/dev/null || true)" != "true" ]]; then
      docker logs "${server}" >&2 2>/dev/null || true
      return 1
    fi
    sleep 1
  done
  return 1
}

assert_server_flag() {
  local expected="$1"
  local argv
  argv="$(docker exec "${server}" sh -c \
    'for f in /proc/[0-9]*/cmdline; do tr "\0" " " < "$f" 2>/dev/null || true; printf "\n"; done' \
    | grep '^/cockroach/cockroach start ' | head -n 1)"
  if [[ "${expected}" == "present" && "${argv}" != *"--accept-sql-without-tls"* ]]; then
    echo "compatibility mode did not add --accept-sql-without-tls" >&2
    exit 1
  fi
  if [[ "${expected}" == "absent" && "${argv}" == *"--accept-sql-without-tls"* ]]; then
    echo "default mode retained --accept-sql-without-tls" >&2
    exit 1
  fi
}

assert_server_logs_clean() {
  local logs
  logs="$(docker logs "${server}" 2>&1 || true)"
  for protected_value in \
      "${password}" "${token_canary}" \
      "${plaintext_request}" "${plaintext_response}" \
      "${tls_request}" "${tls_response}"; do
    if grep -Fq -- "${protected_value}" <<< "${logs}"; then
      echo "protected test material leaked into server logs" >&2
      exit 1
    fi
  done
}

start_capture() {
  local output_name="$1"
  docker rm -f "${sniffer}" >/dev/null 2>&1 || true
  docker run -d --name "${sniffer}" --network "container:${server}" \
    --cap-add NET_RAW --cap-add NET_ADMIN \
    -v "${tmp}/capture:/capture" \
    --entrypoint tcpdump "${sniffer_image}" \
    -U -i any -s 0 -w "/capture/${output_name}" \
    "host ${client_ip} and tcp port 26257" >/dev/null
  for _ in $(seq 1 30); do
    if docker logs "${sniffer}" 2>&1 | grep -q 'listening on'; then
      sleep 1
      return 0
    fi
    if [[ "$(docker inspect -f '{{.State.Running}}' "${sniffer}" 2>/dev/null || true)" != "true" ]]; then
      docker logs "${sniffer}" >&2 2>/dev/null || true
      return 1
    fi
    sleep 1
  done
  echo "packet sniffer did not become ready" >&2
  return 1
}

stop_capture() {
  sleep 1
  docker stop --time 5 "${sniffer}" >/dev/null
  docker rm "${sniffer}" >/dev/null
}

capture_packet_count() {
  local capture_name="$1"
  docker run --rm -v "${tmp}/capture:/capture:ro" --entrypoint tcpdump "${sniffer_image}" \
    -nn -r "/capture/${capture_name}" 2>/dev/null | wc -l | tr -d ' '
}

capture_contains() {
  local capture_name="$1"
  local marker="$2"
  docker run --rm -e "MARKER=${marker}" -v "${tmp}/capture:/capture:ro" \
    --entrypoint /bin/sh "${sniffer_image}" \
    -c 'grep -aFq -- "$MARKER" "/capture/$1"' \
    capture-check "${capture_name}"
}

capture_summary() {
  local capture_name="$1"
  docker run --rm -v "${tmp}/capture:/capture:ro" --entrypoint tshark "${sniffer_image}" \
    -r "/capture/${capture_name}" -T fields \
    -e _ws.col.Protocol -e tcp.len 2>/dev/null \
    | awk 'NF { counts[$1]++; bytes[$1] += $2 } END { for (protocol in counts) print protocol, counts[protocol], bytes[protocol] }' \
    | sort
}

write_query() {
  local path="$1"
  local marker="$2"
  printf "select '%s';\nselect md5('%s');\n" "${marker}" "${marker}" > "${path}"
  chmod 600 "${path}"
}

start_server true
wait_for_sql disable
assert_server_flag present
write_query "${tmp}/plaintext.sql" "${plaintext_request}"
start_capture plaintext.pcap
client_sql disable < "${tmp}/plaintext.sql" > "${tmp}/plaintext.out"
stop_capture
plaintext_packets="$(capture_packet_count plaintext.pcap)"
if [[ "${plaintext_packets}" -le 0 ]]; then
  echo "plaintext control captured no SQL packets" >&2
  exit 1
fi
for marker_kind in request response; do
  marker="${plaintext_request}"
  [[ "${marker_kind}" == "response" ]] && marker="${plaintext_response}"
  if ! capture_contains plaintext.pcap "${marker}"; then
    capture_summary plaintext.pcap >&2
    echo "plaintext control did not expose the expected ${marker_kind} marker" >&2
    exit 1
  fi
done
assert_server_logs_clean

docker stop --time 15 "${server}" >/dev/null
docker rm "${server}" >/dev/null
start_server
wait_for_sql require
assert_server_flag absent

if client_sql disable -c 'select 1' > "${tmp}/disable.out" 2>&1; then
  echo "default mode accepted sslmode=disable" >&2
  exit 1
fi
if docker exec -i -e PGPASSWORD=wrong_password "${client}" psql \
    --set ON_ERROR_STOP=1 \
    --dbname 'postgresql://app_user@roach1:26257/appdb?sslmode=require' \
    -c 'select 1' > "${tmp}/wrong-password.out" 2>&1; then
  echo "default mode accepted an incorrect password" >&2
  exit 1
fi

write_query "${tmp}/tls.sql" "${tls_request}"
start_capture tls.pcap
client_sql require < "${tmp}/tls.sql" > "${tmp}/tls.out"
stop_capture
tls_packets="$(capture_packet_count tls.pcap)"
if [[ "${tls_packets}" -le 0 ]]; then
  echo "TLS test captured no SQL packets" >&2
  exit 1
fi
for marker in "${tls_request}" "${tls_response}" "${password}"; do
  if capture_contains tls.pcap "${marker}"; then
    echo "TLS capture exposed protected SQL material" >&2
    exit 1
  fi
done
assert_server_logs_clean

docker stop --time 15 "${server}" >/dev/null
docker rm "${server}" >/dev/null
start_server invalid
sleep 2
if [[ "$(docker inspect -f '{{.State.Running}}' "${server}" 2>/dev/null || true)" == "true" ]]; then
  echo "invalid CRDB_ACCEPT_SQL_WITHOUT_TLS value did not fail closed" >&2
  exit 1
fi
invalid_logs="$(docker logs "${server}" 2>&1 || true)"
if [[ "${invalid_logs}" != *"CRDB_ACCEPT_SQL_WITHOUT_TLS must be true or false"* ]]; then
  echo "invalid transport mode did not report the expected validation error" >&2
  exit 1
fi

assert_server_logs_clean

printf 'SQL TLS transport smoke ok (plaintext_packets=%s tls_packets=%s)\n' \
  "${plaintext_packets}" "${tls_packets}"
