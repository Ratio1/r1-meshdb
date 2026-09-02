#!/usr/bin/env bash
set -euo pipefail

image="${1:-deeploy-cockroachdb-service:local}"
initial_image="${CRDB_TEST_INITIAL_IMAGE:-${image}}"
run_image="${initial_image}"
run_id="$$-${RANDOM}"
name="deeploy-crdb-secure-smoke-${run_id}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_bootstrap_timeout="${CRDB_TEST_BOOTSTRAP_TIMEOUT_SECONDS:-60}"
test_docker_timeout="${CRDB_TEST_DOCKER_TIMEOUT_SECONDS:-30}"
test_max_offset="${CRDB_TEST_MAX_OFFSET:-5s}"

validate_positive_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
    echo "${name} must be a positive integer" >&2
    exit 2
  fi
}

validate_positive_integer "CRDB_TEST_BOOTSTRAP_TIMEOUT_SECONDS" "${test_bootstrap_timeout}"
validate_positive_integer "CRDB_TEST_DOCKER_TIMEOUT_SECONDS" "${test_docker_timeout}"
test_sql_ready_timeout="${CRDB_TEST_SQL_READY_TIMEOUT_SECONDS:-$((test_bootstrap_timeout * 4 + 30))}"
validate_positive_integer "CRDB_TEST_SQL_READY_TIMEOUT_SECONDS" "${test_sql_ready_timeout}"
test_total_timeout="${CRDB_TEST_TOTAL_TIMEOUT_SECONDS:-$((test_sql_ready_timeout * 2 + 180))}"
validate_positive_integer "CRDB_TEST_TOTAL_TIMEOUT_SECONDS" "${test_total_timeout}"

tmp="$(mktemp -d /tmp/deeploy-crdb-secure.XXXXXX)"
test_deadline=$((SECONDS + test_total_timeout))

docker_with_timeout() {
  local requested_timeout="$1"
  local remaining_timeout
  shift
  remaining_timeout=$((test_deadline - SECONDS))
  if [[ "${remaining_timeout}" -le 0 ]]; then
    echo "secure single-node smoke exceeded ${test_total_timeout} seconds" >&2
    return 124
  fi
  if [[ "${requested_timeout}" -gt "${remaining_timeout}" ]]; then
    requested_timeout="${remaining_timeout}"
  fi
  timeout --signal=KILL "${requested_timeout}s" docker "$@"
}

docker_cmd() {
  docker_with_timeout "${test_docker_timeout}" "$@"
}

docker_cleanup() {
  timeout --signal=KILL "${test_docker_timeout}s" docker "$@"
}

cleanup() {
  local status=$?
  local cleanup_failed=0
  trap - EXIT
  if [[ "${status}" != "0" ]]; then
    docker_cleanup logs "${name}" >&2 2>/dev/null || true
  fi
  docker_cleanup rm -f "${name}" >/dev/null 2>&1 || true
  docker_cleanup inspect "${name}" >/dev/null 2>&1 && cleanup_failed=1
  docker_cleanup run --rm -v "${tmp}:/cleanup" --entrypoint /bin/sh "${image}" \
    -c 'rm -rf /cleanup/* /cleanup/.[!.]* /cleanup/..?*' >/dev/null 2>&1 || cleanup_failed=1
  rmdir "${tmp}" >/dev/null 2>&1 || cleanup_failed=1
  if [[ "${status}" == "0" && "${cleanup_failed}" != "0" ]]; then
    echo "secure single-node smoke cleanup failed" >&2
    status=1
  fi
  exit "${status}"
}
trap cleanup EXIT

mkdir -p "${tmp}/certs" "${tmp}/token" "${tmp}/store"
printf 'fake-token\n' > "${tmp}/token/cf-token"
docker_cmd run --rm -v "${tmp}/store:/store" --entrypoint /bin/sh "${image}" \
  -c 'chown 0:0 /store && chmod 700 /store'

docker_cmd run --rm -u "$(id -u):$(id -g)" -v "${tmp}/certs:/certs" --entrypoint /cockroach/cockroach "${image}" \
  cert create-ca --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
docker_cmd run --rm -u "$(id -u):$(id -g)" -v "${tmp}/certs:/certs" --entrypoint /cockroach/cockroach "${image}" \
  cert create-node roach1 localhost 127.0.0.1 --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
docker_cmd run --rm -u "$(id -u):$(id -g)" -v "${tmp}/certs:/certs" --entrypoint /cockroach/cockroach "${image}" \
  cert create-client root --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null
rm -f "${tmp}/certs/ca.key"

start_container() {
  docker_cmd run -d --name "${name}" \
    -p 127.0.0.1:0:8080 \
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
    -e CRDB_PASSWORD=app_secret_123 \
    -e "CRDB_MAX_OFFSET=${test_max_offset}" \
    -e CRDB_LISTEN_HOST=127.0.0.1 \
    -e CRDB_HTTP_HOST=0.0.0.0 \
    -e CRDB_CA_CRT_FILE=/runtime/ca.crt \
    -e CRDB_NODE_CRT_FILE=/runtime/node.crt \
    -e CRDB_NODE_KEY_FILE=/runtime/node.key \
    -e CRDB_CLIENT_ROOT_CRT_FILE=/runtime/client.root.crt \
    -e CRDB_CLIENT_ROOT_KEY_FILE=/runtime/client.root.key \
    -e CF_TUNNEL_TOKEN_FILE=/runtime/cf-token \
    -e "CRDB_BOOTSTRAP_TIMEOUT_SECONDS=${test_bootstrap_timeout}" \
    "${run_image}" >/dev/null
}

stop_container() {
  docker_cmd stop --time 15 "${name}" >/dev/null
  stop_exit_code="$(docker_cmd inspect -f '{{.State.ExitCode}}' "${name}")"
  if [[ "${stop_exit_code}" != "143" ]]; then
    echo "container exited ${stop_exit_code} after SIGTERM, expected 143" >&2
    exit 1
  fi
  docker_cmd rm "${name}" >/dev/null
}

app_sql() {
  docker_cmd exec -i -e PGPASSWORD=app_secret_123 "${name}" /cockroach/cockroach sql \
    --set=errexit=true \
    --url "postgresql://app_user@127.0.0.1:26257/appdb?sslmode=require" "$@"
}

root_sql() {
  docker_cmd exec "${name}" /cockroach/cockroach sql \
    --certs-dir=/cockroach/certs --host=roach1:26257 "$@"
}

assert_operator_privileges() {
  local role_option_count grant_option_count admin_membership_count system_grant_count
  role_option_count="$(root_sql --format=csv \
    -e "select count(*) from [show users] where username = 'app_user' and options like '%CREATEDB%' and options like '%CREATEROLE%' and options like '%CREATELOGIN%';" \
    | tail -n 1 | tr -d '\r')"
  if [[ "${role_option_count}" != "1" ]]; then
    echo "app_user is missing one or more operator role options" >&2
    exit 1
  fi

  grant_option_count="$(root_sql --format=csv \
    -e "select count(*) from [show grants on database appdb] where grantee = 'app_user' and privilege_type = 'ALL' and is_grantable;" \
    | tail -n 1 | tr -d '\r')"
  if [[ "${grant_option_count}" != "1" ]]; then
    echo "app_user is missing grant delegation on appdb" >&2
    exit 1
  fi

  admin_membership_count="$(root_sql --format=csv \
    -e "select count(*) from [show grants on role admin] where member = 'app_user';" \
    | tail -n 1 | tr -d '\r')"
  if [[ "${admin_membership_count}" != "0" ]]; then
    echo "app_user unexpectedly belongs to admin" >&2
    exit 1
  fi

  system_grant_count="$(root_sql --format=csv \
    -e "select count(*) from [show system grants for app_user];" \
    | tail -n 1 | tr -d '\r')"
  if [[ "${system_grant_count}" != "0" ]]; then
    echo "app_user unexpectedly received a system privilege" >&2
    exit 1
  fi

  operator_sql="${tmp}/operator.sql"
  cat > "${operator_sql}" <<'SQL'
CREATE DATABASE IF NOT EXISTS operator_smoke;
CREATE USER IF NOT EXISTS operator_child WITH LOGIN PASSWORD 'operator_child_secret';
ALTER USER operator_child WITH LOGIN PASSWORD 'operator_child_secret';
GRANT ALL ON DATABASE appdb TO operator_child;
GRANT ALL ON TABLE smoke_test TO operator_child;
GRANT ALL ON DATABASE operator_smoke TO operator_child;
SQL
  chmod 600 "${operator_sql}"
  app_sql < "${operator_sql}" >/dev/null
  rm -f "${operator_sql}"

  child_login_ready=false
  child_login_deadline=$((SECONDS + 30))
  while [[ "${SECONDS}" -lt "${child_login_deadline}" ]]; do
    if docker_cmd exec -e PGPASSWORD=operator_child_secret "${name}" /cockroach/cockroach sql \
      --url "postgresql://operator_child@127.0.0.1:26257/operator_smoke?sslmode=require" \
      -e "select 1" >/dev/null 2>&1; then
      child_login_ready=true
      break
    fi
    sleep 1
  done
  if [[ "${child_login_ready}" != "true" ]]; then
    root_sql -e "show users" >&2
    echo "operator_child did not become available for password login" >&2
    exit 1
  fi

  docker_cmd exec -e PGPASSWORD=operator_child_secret "${name}" /cockroach/cockroach sql \
    --url "postgresql://operator_child@127.0.0.1:26257/operator_smoke?sslmode=require" \
    -e "create table if not exists delegated_smoke (id int primary key);" \
    -e "upsert into delegated_smoke values (1);" \
    -e "select * from delegated_smoke;" >/dev/null

  docker_cmd exec -e PGPASSWORD=operator_child_secret "${name}" /cockroach/cockroach sql \
    --url "postgresql://operator_child@127.0.0.1:26257/appdb?sslmode=require" \
    -e "upsert into smoke_test values (2, 'delegated');" >/dev/null

  negative_sql="${tmp}/operator-negative.sql"
  cat > "${negative_sql}" <<'SQL'
ALTER USER root WITH PASSWORD 'must_not_apply';
SQL
  chmod 600 "${negative_sql}"
  if app_sql < "${negative_sql}" >/dev/null 2>&1; then
    echo "app_user unexpectedly altered root" >&2
    exit 1
  fi
  cat > "${negative_sql}" <<'SQL'
ALTER ROLE admin WITH CREATEROLE;
SQL
  if app_sql < "${negative_sql}" >/dev/null 2>&1; then
    echo "app_user unexpectedly altered admin" >&2
    exit 1
  fi
  cat > "${negative_sql}" <<'SQL'
GRANT admin TO operator_child;
SQL
  if app_sql < "${negative_sql}" >/dev/null 2>&1; then
    echo "app_user unexpectedly granted admin membership" >&2
    exit 1
  fi
  rm -f "${negative_sql}"

  for secret_canary in app_secret_123 operator_child_secret must_not_apply fake-token; do
    if docker_cmd logs "${name}" 2>&1 | grep -Fq "${secret_canary}"; then
      echo "secret canary leaked into container logs" >&2
      exit 1
    fi
    if docker_cmd exec -e "SECRET_CANARY=${secret_canary}" "${name}" sh -c \
      'grep -R -Fq -- "$SECRET_CANARY" /cockroach/cockroach-data/logs 2>/dev/null'; then
      echo "secret canary leaked into R1 MeshDB logs" >&2
      exit 1
    fi
    if docker_cmd exec -e "SECRET_CANARY=${secret_canary}" "${name}" sh -c \
      'cmdlines="$(for f in /proc/[0-9]*/cmdline; do tr "\0" " " < "$f" 2>/dev/null || true; done)"; printf "%s" "$cmdlines" | grep -Fq -- "$SECRET_CANARY"'; then
      echo "secret canary ${secret_canary} leaked into process arguments" >&2
      exit 1
    fi
  done
}

assert_no_operator_privileges() {
  local role_option_count grant_option_count
  role_option_count="$(root_sql --format=csv \
    -e "select count(*) from [show users] where username = 'app_user' and (options like '%CREATEDB%' or options like '%CREATEROLE%' or options like '%CREATELOGIN%');" \
    | tail -n 1 | tr -d '\r')"
  grant_option_count="$(root_sql --format=csv \
    -e "select count(*) from [show grants on database appdb] where grantee = 'app_user' and is_grantable;" \
    | tail -n 1 | tr -d '\r')"
  if [[ "${role_option_count}" != "0" || "${grant_option_count}" != "0" ]]; then
    echo "baseline image unexpectedly includes operator privileges" >&2
    exit 1
  fi
  if app_sql -e "create database baseline_must_fail;" >/dev/null 2>&1; then
    echo "baseline app_user unexpectedly created a database" >&2
    exit 1
  fi
  if app_sql -e "create user baseline_must_fail;" >/dev/null 2>&1; then
    echo "baseline app_user unexpectedly created a user" >&2
    exit 1
  fi
}

wait_for_sql() {
  local deadline=$((SECONDS + test_sql_ready_timeout))
  while [[ "${SECONDS}" -lt "${deadline}" ]]; do
    if docker_with_timeout 5 \
      exec -e PGPASSWORD=app_secret_123 "${name}" /cockroach/cockroach sql \
      --url "postgresql://app_user@127.0.0.1:26257/appdb?sslmode=require" \
      -e "select 1" >/dev/null 2>&1; then
      return 0
    fi
    if [[ "$(docker_with_timeout 5 inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || true)" != "true" ]]; then
      return 1
    fi
    sleep 1
  done
  return 1
}

assert_console_contract() {
  local -a curl_args
  local port base_url root_file bundle_file login_file sql_file
  local root_status bundle_status anonymous_status login_status session sql_status
  port="$(docker_cmd port "${name}" 8080/tcp | sed -n 's/.*://p')"
  if [[ ! "${port}" =~ ^[1-9][0-9]*$ ]]; then
    echo "console port is not published on loopback" >&2
    exit 1
  fi

  base_url="https://localhost:${port}"
  root_file="${tmp}/console-index.html"
  bundle_file="${tmp}/console-bundle.js"
  login_file="${tmp}/console-login.json"
  sql_file="${tmp}/console-sql.json"
  curl_args=(
    --noproxy '*'
    --silent
    --show-error
    --max-time "${test_docker_timeout}"
    --cacert "${tmp}/certs/ca.crt"
  )

  root_status="$(curl "${curl_args[@]}" --output "${root_file}" \
    --write-out '%{http_code}' "${base_url}/")"
  if [[ "${root_status}" != "200" ]] || ! grep -Fq '<title>R1 MeshDB Console</title>' "${root_file}"; then
    echo "console root did not return the R1 MeshDB page" >&2
    exit 1
  fi

  bundle_status="$(curl "${curl_args[@]}" --output "${bundle_file}" \
    --write-out '%{http_code}' "${base_url}/bundle.js")"
  if [[ "${bundle_status}" != "200" ]] || \
      [[ "$(wc -c < "${bundle_file}")" -le 10000 ]] || \
      ! grep -Fq 'data-r1-meshdb-console' "${bundle_file}"; then
    echo "console bundle is missing or not renderable" >&2
    exit 1
  fi

  anonymous_status="$(curl "${curl_args[@]}" --output /dev/null \
    --write-out '%{http_code}' --header 'Content-Type: application/json' \
    --data '{"execute":true,"database":"appdb","statements":[{"sql":"SELECT 1"}]}' \
    "${base_url}/api/v2/sql/")"
  if [[ "${anonymous_status}" != "401" ]]; then
    echo "console SQL API accepted an anonymous request" >&2
    exit 1
  fi

  login_status="$(curl "${curl_args[@]}" --output "${login_file}" \
    --write-out '%{http_code}' --header 'Content-Type: application/x-www-form-urlencoded' \
    --data 'username=app_user&password=app_secret_123' \
    "${base_url}/api/v2/login/")"
  if [[ "${login_status}" != "200" ]]; then
    echo "console login failed" >&2
    exit 1
  fi
  session="$(python3 - "${login_file}" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(value.get("session", ""))
PY
)"
  if [[ -z "${session}" ]]; then
    echo "console login did not return a session" >&2
    exit 1
  fi

  sql_status="$(printf 'header = "X-Cockroach-API-Session: %s"\n' "${session}" | \
    curl --config - "${curl_args[@]}" --output "${sql_file}" \
      --write-out '%{http_code}' --header 'Content-Type: application/json' \
      --data '{"execute":true,"database":"appdb","statements":[{"sql":"SELECT current_user AS username, current_database() AS database_name"}]}' \
      "${base_url}/api/v2/sql/")"
  if [[ "${sql_status}" != "200" ]] || ! python3 - "${sql_file}" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
row = value["execution"]["txn_results"][0]["rows"][0]
raise SystemExit(0 if row == {"username": "app_user", "database_name": "appdb"} else 1)
PY
  then
    echo "console authenticated SQL request failed" >&2
    exit 1
  fi
}

start_container
wait_for_sql

app_sql \
  -e "create table if not exists smoke_test (id int primary key, note string);" \
  -e "upsert into smoke_test values (1, 'secure');" \
  -e "select * from smoke_test;" >/dev/null

if [[ "${initial_image}" != "${image}" ]]; then
  assert_no_operator_privileges
fi

if docker_cmd exec -e PGPASSWORD=wrong "${name}" /cockroach/cockroach sql \
  --url "postgresql://app_user@127.0.0.1:26257/appdb?sslmode=require" \
  -e "select 1" >/dev/null 2>&1; then
  echo "wrong password unexpectedly succeeded" >&2
  exit 1
fi

if docker_cmd exec "${name}" sh -c "for f in /proc/[0-9]*/cmdline; do tr '\0' ' ' 2>/dev/null < \"\$f\" || true; echo; done | grep '^/cockroach/cockroach start ' | grep -q -- '--insecure'"; then
  echo "cockroach process includes --insecure" >&2
  exit 1
fi

docker_cmd exec "${name}" sh -c "for f in /proc/[0-9]*/cmdline; do tr '\0' ' ' 2>/dev/null < \"\$f\" || true; echo; done | grep '^/cockroach/cockroach start ' | grep -q -- '--certs-dir=/cockroach/certs'"

if docker_cmd exec "${name}" sh -c "for f in /proc/[0-9]*/cmdline; do cmd=\$(tr '\0' ' ' 2>/dev/null < \"\$f\" || true); case \"\$cmd\" in *grep*fake-token*) continue;; esac; printf '%s\n' \"\$cmd\"; done | grep -q 'fake-token'"; then
  echo "Cloudflare token is visible in process argv" >&2
  exit 1
fi

if docker_cmd exec "${name}" sh -c "for f in /proc/[0-9]*/cmdline; do cmd=\$(tr '\0' ' ' 2>/dev/null < \"\$f\" || true); case \"\$cmd\" in *grep*app_secret_123*) continue;; esac; printf '%s\n' \"\$cmd\"; done | grep -q 'app_secret_123'"; then
  echo "database password is visible in process argv" >&2
  exit 1
fi

mode="$(docker_cmd exec "${name}" stat -c '%a' /cockroach/certs/node.key)"
if [[ "${mode}" != "600" ]]; then
  echo "node.key mode is ${mode}, expected 600" >&2
  exit 1
fi

stop_container

run_image="${image}"
start_container
wait_for_sql
persisted_note="$(app_sql --format=csv -e "select note from smoke_test where id = 1;" | tail -n 1 | tr -d '\r')"
if [[ "${persisted_note}" != "secure" ]]; then
  echo "persisted row was not readable after restart" >&2
  exit 1
fi
assert_console_contract
assert_operator_privileges

if [[ "${initial_image}" != "${image}" ]]; then
  stop_container
  start_container
  wait_for_sql
  assert_operator_privileges
fi

for reserved_user in Root ADMIN node public; do
  reserved_output=""
  reserved_status=0
  reserved_output="$(docker_cmd run --rm \
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
  -e "CRDB_USER=${reserved_user}" \
  -e CRDB_PASSWORD=app_secret_123 \
  -e CRDB_CA_CRT_FILE=/runtime/ca.crt \
  -e CRDB_NODE_CRT_FILE=/runtime/node.crt \
  -e CRDB_NODE_KEY_FILE=/runtime/node.key \
  -e CRDB_CLIENT_ROOT_CRT_FILE=/runtime/client.root.crt \
  -e CRDB_CLIENT_ROOT_KEY_FILE=/runtime/client.root.key \
  -e CF_TUNNEL_TOKEN_FILE=/runtime/cf-token \
    "${image}" 2>&1)" || reserved_status=$?
  if [[ "${reserved_status}" == "0" ]]; then
    echo "CRDB_USER=${reserved_user} unexpectedly passed validation" >&2
    exit 1
  fi
  if [[ "${reserved_status}" != "1" || \
        "${reserved_output}" != *"CRDB_USER must not be a reserved R1 MeshDB identity"* ]]; then
    echo "CRDB_USER=${reserved_user} did not fail through reserved-identity validation" >&2
    exit 1
  fi
  reserved_output=""
done

echo "secure single-node smoke ok"
