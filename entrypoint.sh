#!/usr/bin/env bash
set -euo pipefail

if [[ "${R1_SQL_SECRETS_REEXEC:-}" != "1" ]]; then
  stage_secret_input() {
    local value="$1"
    local source_file="$2"
    local destination="$3"
    local label="$4"

    if [[ -n "${source_file}" ]]; then
      if [[ ! -f "${source_file}" || -L "${source_file}" || ! -r "${source_file}" ]]; then
        echo "[deeploy-crdb] ${label} file is not a readable regular file" >&2
        return 1
      fi
      cat "${source_file}" > "${destination}"
    else
      printf '%s' "${value}" > "${destination}"
    fi
    chmod 600 "${destination}"
  }

  : "${CRDB_PASSWORD:?CRDB_PASSWORD is required}"
  if [[ -z "${CF_TUNNEL_TOKEN:-}" && -z "${CF_TUNNEL_TOKEN_FILE:-}" ]]; then
    echo "[deeploy-crdb] CF_TUNNEL_TOKEN or CF_TUNNEL_TOKEN_FILE is required" >&2
    exit 1
  fi
  secret_dir="$(mktemp -d /tmp/r1-distributed-sql-secrets.XXXXXXXX)"
  chmod 700 "${secret_dir}"
  umask 077
  printf '%s' "${CRDB_PASSWORD}" > "${secret_dir}/database-password"
  chmod 600 "${secret_dir}/database-password"
  if ! stage_secret_input "${CF_TUNNEL_TOKEN:-}" "${CF_TUNNEL_TOKEN_FILE:-}" \
      "${secret_dir}/cloudflare-token" "Cloudflare token" || \
    ! stage_secret_input "${CRDB_CA_CRT:-}" "${CRDB_CA_CRT_FILE:-}" \
      "${secret_dir}/ca-crt" "CA certificate" || \
    ! stage_secret_input "${CRDB_NODE_CRT:-}" "${CRDB_NODE_CRT_FILE:-}" \
      "${secret_dir}/node-crt" "node certificate" || \
    ! stage_secret_input "${CRDB_NODE_KEY:-}" "${CRDB_NODE_KEY_FILE:-}" \
      "${secret_dir}/node-key" "node key" || \
    ! stage_secret_input "${CRDB_CLIENT_ROOT_CRT:-}" "${CRDB_CLIENT_ROOT_CRT_FILE:-}" \
      "${secret_dir}/client-root-crt" "root client certificate" || \
    ! stage_secret_input "${CRDB_CLIENT_ROOT_KEY:-}" "${CRDB_CLIENT_ROOT_KEY_FILE:-}" \
      "${secret_dir}/client-root-key" "root client key"; then
    rm -rf "${secret_dir}"
    exit 1
  fi
  exec env \
    -u CRDB_PASSWORD -u CF_TUNNEL_TOKEN -u CF_TUNNEL_TOKEN_FILE -u TUNNEL_TOKEN -u TUNNEL_TOKEN_FILE \
    -u CRDB_CA_CRT -u CRDB_CA_CRT_FILE \
    -u CRDB_NODE_CRT -u CRDB_NODE_CRT_FILE \
    -u CRDB_NODE_KEY -u CRDB_NODE_KEY_FILE \
    -u CRDB_CLIENT_ROOT_CRT -u CRDB_CLIENT_ROOT_CRT_FILE \
    -u CRDB_CLIENT_ROOT_KEY -u CRDB_CLIENT_ROOT_KEY_FILE \
    R1_SQL_SECRETS_REEXEC=1 \
    R1_SQL_SECRET_DIR="${secret_dir}" \
    CRDB_CA_CRT_FILE="${secret_dir}/ca-crt" \
    CRDB_NODE_CRT_FILE="${secret_dir}/node-crt" \
    CRDB_NODE_KEY_FILE="${secret_dir}/node-key" \
    CRDB_CLIENT_ROOT_CRT_FILE="${secret_dir}/client-root-crt" \
    CRDB_CLIENT_ROOT_KEY_FILE="${secret_dir}/client-root-key" \
    "$0" "$@"
fi

: "${R1_SQL_SECRET_DIR:?internal secret directory is required}"
case "${R1_SQL_SECRET_DIR}" in
  /tmp/r1-distributed-sql-secrets.*) ;;
  *) echo "[deeploy-crdb] invalid internal secret directory" >&2; exit 1 ;;
esac
if [[ -L "${R1_SQL_SECRET_DIR}" || ! -d "${R1_SQL_SECRET_DIR}" ||
      "$(stat -c '%u:%a' "${R1_SQL_SECRET_DIR}" 2>/dev/null || true)" != "0:700" ]]; then
  echo "[deeploy-crdb] invalid internal secret directory" >&2
  exit 1
fi
R1_SQL_PASSWORD_FILE="${R1_SQL_SECRET_DIR}/database-password"
R1_SQL_TUNNEL_TOKEN_FILE="${R1_SQL_SECRET_DIR}/cloudflare-token"
R1_SQL_STAGED_CERT_FILES=(
  "${R1_SQL_SECRET_DIR}/ca-crt"
  "${R1_SQL_SECRET_DIR}/node-crt"
  "${R1_SQL_SECRET_DIR}/node-key"
  "${R1_SQL_SECRET_DIR}/client-root-crt"
  "${R1_SQL_SECRET_DIR}/client-root-key"
)
for secret_file in "${R1_SQL_PASSWORD_FILE}" "${R1_SQL_TUNNEL_TOKEN_FILE}" \
    "${R1_SQL_STAGED_CERT_FILES[@]}"; do
  if [[ -L "${secret_file}" || ! -f "${secret_file}" ||
        "$(stat -c '%u:%a' "${secret_file}" 2>/dev/null || true)" != "0:600" ]]; then
    echo "[deeploy-crdb] invalid internal secret file" >&2
    exit 1
  fi
done
early_secret_cleanup() {
  rm -f -- "${R1_SQL_PASSWORD_FILE}" "${R1_SQL_TUNNEL_TOKEN_FILE}" \
    "${R1_SQL_STAGED_CERT_FILES[@]}" >/dev/null 2>&1 || true
  rmdir "${R1_SQL_SECRET_DIR}" >/dev/null 2>&1 || true
}
trap early_secret_cleanup EXIT
CRDB_PASSWORD="$(cat "${R1_SQL_PASSWORD_FILE}")"
export -n CRDB_PASSWORD R1_SQL_SECRET_DIR R1_SQL_PASSWORD_FILE R1_SQL_TUNNEL_TOKEN_FILE

: "${CRDB_NODE_ID:?CRDB_NODE_ID is required}"
: "${CRDB_NODE_COUNT:?CRDB_NODE_COUNT is required}"
: "${CRDB_HOSTNAMES:?CRDB_HOSTNAMES is required}"
: "${CRDB_DATABASE:?CRDB_DATABASE is required}"
: "${CRDB_USER:?CRDB_USER is required}"
: "${CRDB_PASSWORD:?CRDB_PASSWORD is required}"

CRDB_SQL_PORT="${CRDB_SQL_PORT:-26257}"
CRDB_HTTP_PORT="${CRDB_HTTP_PORT:-8080}"
CRDB_LISTEN_HOST="${CRDB_LISTEN_HOST:-127.0.0.1}"
CRDB_HTTP_HOST="${CRDB_HTTP_HOST:-127.0.0.1}"
CRDB_MAX_OFFSET="${CRDB_MAX_OFFSET:-500ms}"
CRDB_STORE="${CRDB_STORE:-/cockroach/cockroach-data}"
CRDB_LOOPBACK_PREFIX="${CRDB_LOOPBACK_PREFIX:-127.77.0}"
CRDB_CACHE="${CRDB_CACHE:-.25}"
CRDB_MAX_SQL_MEMORY="${CRDB_MAX_SQL_MEMORY:-.25}"
CRDB_CERTS_DIR="${CRDB_CERTS_DIR:-/cockroach/certs}"
CRDB_ACCEPT_SQL_WITHOUT_TLS="${CRDB_ACCEPT_SQL_WITHOUT_TLS:-false}"
CRDB_BOOTSTRAP_TIMEOUT_SECONDS="${CRDB_BOOTSTRAP_TIMEOUT_SECONDS:-300}"
CRDB_SHUTDOWN_GRACE_SECONDS="${CRDB_SHUTDOWN_GRACE_SECONDS:-3}"
CRDB_AUTO_RECOVER_CORRUPT_STORE="${CRDB_AUTO_RECOVER_CORRUPT_STORE:-true}"
CRDB_RECOVERY_MIN_FREE_BYTES="${CRDB_RECOVERY_MIN_FREE_BYTES:-1073741824}"
CRDB_RECOVERY_MIN_FREE_INODES="${CRDB_RECOVERY_MIN_FREE_INODES:-1024}"
CRDB_RECOVERY_HANDLER_TIMEOUT_SECONDS="${CRDB_RECOVERY_HANDLER_TIMEOUT_SECONDS:-2}"
CRDB_RECOVERY_LOG_SCAN_BYTES="${CRDB_RECOVERY_LOG_SCAN_BYTES:-1048576}"
CRDB_RECOVERY_LOG_RETENTION_RUNS="${CRDB_RECOVERY_LOG_RETENTION_RUNS:-10}"
# The legacy v23.1.28 image does not advertise gRPC TLS ALPN. Keep certificate
# authentication and encryption while allowing one-at-a-time image migration.
GRPC_ENFORCE_ALPN_ENABLED=false
export GRPC_ENFORCE_ALPN_ENABLED

log() {
  printf '[deeploy-crdb] %s\n' "$*" >&2
}

read_secret_value() {
  local value="${1:-}"
  local file="${2:-}"
  if [[ -n "${file}" ]]; then
    if [[ ! -r "${file}" ]]; then
      log "secret file is not readable: ${file}"
      exit 1
    fi
    cat "${file}"
    return
  fi
  printf '%s' "${value}"
}

validate_identifier() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]]; then
    log "${name} must be a SQL identifier: letters, digits, and underscores, not starting with a digit"
    exit 1
  fi
}

validate_positive_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
    log "${name} must be a positive integer"
    exit 1
  fi
}

validate_bounded_positive_integer() {
  local name="$1"
  local value="$2"
  local maximum="$3"
  validate_positive_integer "${name}" "${value}"
  if ! awk -v value="${value}" -v maximum="${maximum}" \
      'BEGIN { exit !(value <= maximum) }'; then
    log "${name} must not exceed ${maximum}"
    exit 1
  fi
}

validate_nonnegative_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    log "${name} must be a non-negative integer"
    exit 1
  fi
}

validate_boolean() {
  local name="$1"
  local value="$2"
  if [[ "${value}" != "true" && "${value}" != "false" ]]; then
    log "${name} must be true or false"
    exit 1
  fi
}

normalize_and_validate_store_path() {
  local component current="" normalized
  local -a components=()

  if [[ "${CRDB_STORE}" != /* ]] || \
     ! normalized="$(realpath -s -m -- "${CRDB_STORE}")"; then
    log "CRDB_STORE must be an absolute path"
    return 1
  fi
  if [[ "${normalized}" == "/" ]]; then
    log "CRDB_STORE must not be the filesystem root"
    return 1
  fi
  CRDB_STORE="${normalized}"
  IFS='/' read -r -a components <<< "${CRDB_STORE}"
  for component in "${components[@]}"; do
    [[ -z "${component}" ]] && continue
    current="${current}/${component}"
    if [[ -L "${current}" ]]; then
      log "CRDB_STORE must not contain symlink components"
      return 1
    fi
  done
}

prepare_store_root() {
  local store_mode

  if [[ -L "${CRDB_STORE}" || ! -d "${CRDB_STORE}" || \
        "$(stat -c '%u' "${CRDB_STORE}" 2>/dev/null || true)" != "0" ]]; then
    log "invalid CockroachDB store directory"
    return 1
  fi
  store_mode="$(stat -c '%a' "${CRDB_STORE}" 2>/dev/null || true)"
  if [[ "${store_mode}" == "755" ]]; then
    chmod 700 -- "${CRDB_STORE}" || return 1
    store_mode="$(stat -c '%a' "${CRDB_STORE}" 2>/dev/null || true)"
  fi
  if [[ -L "${CRDB_STORE}" || "${store_mode}" != "700" ]]; then
    log "invalid CockroachDB store directory"
    return 1
  fi
}

sql_quote_literal() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\'}"
}

write_secret_file() {
  local path="$1"
  local content="$2"
  if [[ -z "${content}" ]]; then
    log "missing required certificate content for ${path}"
    exit 1
  fi
  umask 077
  printf '%s\n' "${content}" > "${path}"
  chmod 600 "${path}"
}

validate_identifier "CRDB_DATABASE" "${CRDB_DATABASE}"
validate_identifier "CRDB_USER" "${CRDB_USER}"
validate_positive_integer "CRDB_NODE_ID" "${CRDB_NODE_ID}"
validate_positive_integer "CRDB_NODE_COUNT" "${CRDB_NODE_COUNT}"
validate_bounded_positive_integer "CRDB_BOOTSTRAP_TIMEOUT_SECONDS" "${CRDB_BOOTSTRAP_TIMEOUT_SECONDS}" 3600
validate_positive_integer "CRDB_SHUTDOWN_GRACE_SECONDS" "${CRDB_SHUTDOWN_GRACE_SECONDS}"
validate_boolean "CRDB_ACCEPT_SQL_WITHOUT_TLS" "${CRDB_ACCEPT_SQL_WITHOUT_TLS}"
validate_boolean "CRDB_AUTO_RECOVER_CORRUPT_STORE" "${CRDB_AUTO_RECOVER_CORRUPT_STORE}"
validate_nonnegative_integer "CRDB_RECOVERY_MIN_FREE_BYTES" "${CRDB_RECOVERY_MIN_FREE_BYTES}"
validate_nonnegative_integer "CRDB_RECOVERY_MIN_FREE_INODES" "${CRDB_RECOVERY_MIN_FREE_INODES}"
validate_positive_integer "CRDB_RECOVERY_HANDLER_TIMEOUT_SECONDS" "${CRDB_RECOVERY_HANDLER_TIMEOUT_SECONDS}"
validate_positive_integer "CRDB_RECOVERY_LOG_SCAN_BYTES" "${CRDB_RECOVERY_LOG_SCAN_BYTES}"
validate_positive_integer "CRDB_RECOVERY_LOG_RETENTION_RUNS" "${CRDB_RECOVERY_LOG_RETENTION_RUNS}"
normalize_and_validate_store_path || exit 1
case "${CRDB_USER,,}" in
  root|admin|node|public)
    log "CRDB_USER must not be a reserved CockroachDB identity"
    exit 1
    ;;
esac

CRDB_RECOVERY_STATE_DIR="${CRDB_STORE}/.deeploy-recovery-v1"
CRDB_RECOVERY_MARKER="${CRDB_RECOVERY_STATE_DIR}/state"
CRDB_RECOVERY_EXHAUSTED="${CRDB_RECOVERY_STATE_DIR}/exhausted"
CRDB_ACTIVE_STORE="${CRDB_STORE}"
CRDB_RECOVERY_ACTIVE=false
CRDB_CURRENT_RUN_LOG_DIR=""

CRDB_CA_CRT="$(read_secret_value "${CRDB_CA_CRT:-}" "${CRDB_CA_CRT_FILE:-}")"
CRDB_NODE_CRT="$(read_secret_value "${CRDB_NODE_CRT:-}" "${CRDB_NODE_CRT_FILE:-}")"
CRDB_NODE_KEY="$(read_secret_value "${CRDB_NODE_KEY:-}" "${CRDB_NODE_KEY_FILE:-}")"
CRDB_CA_FINGERPRINT="$(printf '%s' "${CRDB_CA_CRT}" | sha256sum | awk '{print $1}')"
CRDB_TOPOLOGY_FINGERPRINT="$({
  printf 'node_id=%s\n' "${CRDB_NODE_ID}"
  printf 'node_count=%s\n' "${CRDB_NODE_COUNT}"
  printf 'hostnames=%s\n' "${CRDB_HOSTNAMES}"
  printf 'sql_port=%s\n' "${CRDB_SQL_PORT}"
  printf 'loopback_prefix=%s\n' "${CRDB_LOOPBACK_PREFIX}"
} | sha256sum | awk '{print $1}')"

mkdir -p "${CRDB_CERTS_DIR}"
write_secret_file "${CRDB_CERTS_DIR}/ca.crt" "${CRDB_CA_CRT}"
write_secret_file "${CRDB_CERTS_DIR}/node.crt" "${CRDB_NODE_CRT}"
write_secret_file "${CRDB_CERTS_DIR}/node.key" "${CRDB_NODE_KEY}"

if [[ "${CRDB_NODE_ID}" == "1" ]]; then
  CRDB_CLIENT_ROOT_CRT="$(read_secret_value "${CRDB_CLIENT_ROOT_CRT:-}" "${CRDB_CLIENT_ROOT_CRT_FILE:-}")"
  CRDB_CLIENT_ROOT_KEY="$(read_secret_value "${CRDB_CLIENT_ROOT_KEY:-}" "${CRDB_CLIENT_ROOT_KEY_FILE:-}")"
  write_secret_file "${CRDB_CERTS_DIR}/client.root.crt" "${CRDB_CLIENT_ROOT_CRT}"
  write_secret_file "${CRDB_CERTS_DIR}/client.root.key" "${CRDB_CLIENT_ROOT_KEY}"
fi

rm -f -- "${R1_SQL_STAGED_CERT_FILES[@]}" || {
  log "could not remove staged certificate material"
  exit 1
}
CRDB_CA_CRT=""
CRDB_NODE_CRT=""
CRDB_NODE_KEY=""
CRDB_CLIENT_ROOT_CRT=""
CRDB_CLIENT_ROOT_KEY=""
unset CRDB_CA_CRT CRDB_NODE_CRT CRDB_NODE_KEY CRDB_CLIENT_ROOT_CRT CRDB_CLIENT_ROOT_KEY
unset CRDB_CA_CRT_FILE CRDB_NODE_CRT_FILE CRDB_NODE_KEY_FILE
unset CRDB_CLIENT_ROOT_CRT_FILE CRDB_CLIENT_ROOT_KEY_FILE

CRDB_BIND_HOST="${CRDB_LISTEN_HOST}"
if [[ "${CRDB_LISTEN_HOST}" == "0.0.0.0" && "${CRDB_NODE_COUNT}" -gt 1 ]]; then
  read -r detected_container_ip _ <<< "$(hostname -i)"
  if [[ -z "${detected_container_ip}" ]]; then
    log "could not detect container IP for multi-node wildcard listen"
    exit 1
  fi
  CRDB_BIND_HOST="${detected_container_ip}"
  log "using container IP ${CRDB_BIND_HOST} for SQL listener; wildcard would conflict with peer proxy listeners"
fi

declare -a REQUIRED_PIDS=()
declare -A REQUIRED_PROCESS_NAMES=()
active_operation_pid=""
bootstrap_sql=""
bootstrap_output=""
init_output_file=""
crdb_pid=""
recovery_handler_pid=""
run_log_list_file=""

load_recovery_marker() {
  local marker_path="$1"
  local -a lines=()

  if [[ -L "${marker_path}" || ! -f "${marker_path}" || \
        "$(stat -c '%a' "${marker_path}" 2>/dev/null || true)" != "600" || \
        "$(stat -c '%s' "${marker_path}" 2>/dev/null || true)" -gt 1024 ]]; then
    return 1
  fi
  mapfile -t lines < "${marker_path}" || return 1
  if [[ "${#lines[@]}" -ne 9 || \
        "${lines[0]}" != "version=3" || \
        ( "${lines[1]}" != "state=active" && "${lines[1]}" != "state=started" ) || \
        ! "${lines[2]}" =~ ^node_id=([1-9][0-9]*)$ || \
        ! "${lines[3]}" =~ ^node_count=([1-9][0-9]*)$ || \
        ! "${lines[4]}" =~ ^topology_sha256=([a-f0-9]{64})$ || \
        ! "${lines[5]}" =~ ^ca_sha256=([a-f0-9]{64})$ || \
        ! "${lines[6]}" =~ ^created_at=([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)$ || \
        ! "${lines[7]}" =~ ^recovery_store=(store\.[A-Za-z0-9]{8})$ || \
        ! "${lines[8]}" =~ ^recovery_run=(none|deeploy-run\.[A-Za-z0-9]{8})$ ]]; then
    return 1
  fi

  RECOVERY_MARKER_STATE="${lines[1]#state=}"
  RECOVERY_MARKER_NODE_ID="${lines[2]#node_id=}"
  RECOVERY_MARKER_NODE_COUNT="${lines[3]#node_count=}"
  RECOVERY_MARKER_TOPOLOGY_FINGERPRINT="${lines[4]#topology_sha256=}"
  RECOVERY_MARKER_CA_FINGERPRINT="${lines[5]#ca_sha256=}"
  RECOVERY_MARKER_CREATED_AT="${lines[6]#created_at=}"
  RECOVERY_MARKER_STORE="${lines[7]#recovery_store=}"
  RECOVERY_MARKER_RUN="${lines[8]#recovery_run=}"
  if [[ ( "${RECOVERY_MARKER_STATE}" == "active" && "${RECOVERY_MARKER_RUN}" != "none" ) || \
        ( "${RECOVERY_MARKER_STATE}" == "started" && "${RECOVERY_MARKER_RUN}" == "none" ) ]]; then
    return 1
  fi
}

write_recovery_marker() {
  local marker_tmp

  umask 077
  marker_tmp="$(mktemp "${CRDB_RECOVERY_STATE_DIR}/state.tmp.XXXXXXXX")" || return 1
  if ! printf '%s\n' \
      'version=3' \
      "state=${RECOVERY_MARKER_STATE}" \
      "node_id=${RECOVERY_MARKER_NODE_ID}" \
      "node_count=${RECOVERY_MARKER_NODE_COUNT}" \
      "topology_sha256=${RECOVERY_MARKER_TOPOLOGY_FINGERPRINT}" \
      "ca_sha256=${RECOVERY_MARKER_CA_FINGERPRINT}" \
      "created_at=${RECOVERY_MARKER_CREATED_AT}" \
      "recovery_store=${RECOVERY_MARKER_STORE}" \
      "recovery_run=${RECOVERY_MARKER_RUN}" > "${marker_tmp}" || \
     ! chmod 600 "${marker_tmp}"; then
    rm -f "${marker_tmp}"
    return 1
  fi
  if ! sync "${marker_tmp}" >/dev/null 2>&1; then
    rm -f "${marker_tmp}"
    return 1
  fi
  if ! r1-atomic-replace "${marker_tmp}" "${CRDB_RECOVERY_MARKER}"; then
    rm -f "${marker_tmp}"
    return 1
  fi
  if ! sync "${CRDB_RECOVERY_STATE_DIR}" >/dev/null 2>&1; then
    rm -f "${CRDB_RECOVERY_MARKER}"
    sync "${CRDB_RECOVERY_STATE_DIR}" >/dev/null 2>&1 || true
    return 1
  fi
}

mark_recovery_exhausted() {
  if r1-atomic-replace "${CRDB_RECOVERY_MARKER}" "${CRDB_RECOVERY_EXHAUSTED}"; then
    if ! sync "${CRDB_RECOVERY_STATE_DIR}" >/dev/null 2>&1; then
      log "could not synchronize corrupt-store recovery exhaustion state; the fail-closed sentinel remains active"
      return 1
    fi
    return 0
  fi

  log "could not atomically persist corrupt-store recovery exhaustion; invalidating the active marker"
  if ! printf 'invalid\n' > "${CRDB_RECOVERY_MARKER}" || \
     ! chmod 000 "${CRDB_RECOVERY_MARKER}" || \
     ! sync "${CRDB_RECOVERY_MARKER}" >/dev/null 2>&1; then
    rm -f "${CRDB_RECOVERY_MARKER}" >/dev/null 2>&1 || \
      chmod 000 "${CRDB_RECOVERY_MARKER}" >/dev/null 2>&1 || true
  fi
  sync "${CRDB_RECOVERY_STATE_DIR}" >/dev/null 2>&1 || true
  return 1
}

select_recovery_store() {
  local marker_path scan_status selected_store state_entries store_entries exhausted=false

  if [[ -L "${CRDB_STORE}" || -L "${CRDB_RECOVERY_STATE_DIR}" ]]; then
    log "invalid corrupt-store recovery state"
    return 1
  fi
  if [[ ! -e "${CRDB_RECOVERY_STATE_DIR}" ]]; then
    return 0
  fi
  if [[ ! -d "${CRDB_RECOVERY_STATE_DIR}" || \
        "$(stat -c '%a' "${CRDB_RECOVERY_STATE_DIR}" 2>/dev/null || true)" != "700" || \
        "$(stat -c '%u' "${CRDB_RECOVERY_STATE_DIR}" 2>/dev/null || true)" != "0" || \
        -n "$(find "${CRDB_RECOVERY_STATE_DIR}" -maxdepth 1 -type f -name 'state.tmp.*' -print -quit 2>/dev/null)" ]]; then
    log "invalid corrupt-store recovery state"
    return 1
  fi

  if [[ -e "${CRDB_RECOVERY_EXHAUSTED}" || -L "${CRDB_RECOVERY_EXHAUSTED}" ]]; then
    marker_path="${CRDB_RECOVERY_EXHAUSTED}"
    exhausted=true
  elif [[ -e "${CRDB_RECOVERY_MARKER}" || -L "${CRDB_RECOVERY_MARKER}" ]]; then
    marker_path="${CRDB_RECOVERY_MARKER}"
  else
    log "invalid corrupt-store recovery state"
    return 1
  fi
  if ! load_recovery_marker "${marker_path}"; then
    log "invalid corrupt-store recovery state"
    return 1
  fi
  if [[ "${RECOVERY_MARKER_NODE_ID}" != "${CRDB_NODE_ID}" || \
        "${RECOVERY_MARKER_NODE_COUNT}" != "${CRDB_NODE_COUNT}" || \
        "${RECOVERY_MARKER_TOPOLOGY_FINGERPRINT}" != "${CRDB_TOPOLOGY_FINGERPRINT}" || \
        "${RECOVERY_MARKER_CA_FINGERPRINT}" != "${CRDB_CA_FINGERPRINT}" ]]; then
    log "corrupt-store recovery state does not match this node topology"
    return 1
  fi

  selected_store="${CRDB_RECOVERY_STATE_DIR}/${RECOVERY_MARKER_STORE}"
  if ! state_entries="$(find "${CRDB_RECOVERY_STATE_DIR}" -mindepth 1 -maxdepth 1 -printf . 2>/dev/null)" || \
     ! store_entries="$(find "${CRDB_RECOVERY_STATE_DIR}" -mindepth 1 -maxdepth 1 -type d -name 'store.*' -printf . 2>/dev/null)"; then
    log "invalid corrupt-store recovery state"
    return 1
  fi
  if [[ -L "${selected_store}" || ! -d "${selected_store}" || \
        "$(stat -c '%u' "${marker_path}" 2>/dev/null || true)" != "0" || \
        "$(stat -c '%u' "${selected_store}" 2>/dev/null || true)" != "0" || \
        "$(stat -c '%a' "${selected_store}" 2>/dev/null || true)" != "700" || \
        "${#state_entries}" != "2" || "${#store_entries}" != "1" ]]; then
    log "invalid corrupt-store recovery state"
    return 1
  fi
  if [[ "${exhausted}" != "true" && "${RECOVERY_MARKER_STATE}" == "started" ]]; then
    scan_status=0
    run_recovery_log_scan_bounded "${selected_store}" "${RECOVERY_MARKER_RUN}" || scan_status=$?
    if [[ "${scan_status}" == "0" ]]; then
      mark_recovery_exhausted || true
      log "previous fresh-store run reported local checksum corruption; recovery is now fail closed"
      return 1
    fi
    if [[ "${scan_status}" != "1" ]]; then
      log "could not safely inspect the previous fresh-store run; recovery remains fail closed"
      return 1
    fi
  fi
  if [[ "${exhausted}" == "true" ]]; then
    log "corrupt-store recovery is exhausted; operator intervention is required"
    return 1
  fi
  CRDB_ACTIVE_STORE="${selected_store}"
  CRDB_RECOVERY_ACTIVE=true
  log "using the recorded fresh store after local checksum corruption"
}

recovery_capacity_available() {
  local metrics used_kb used_inodes available_kb available_inodes
  local -a capacity_values=()
  if ! metrics="$(
    bash -c '
      set -o pipefail
      df -Pk -- "$1" | awk "END {print \$3; print \$4}"
      df -Pi -- "$1" | awk "END {print \$3; print \$4}"
    ' deeploy-crdb-capacity "${CRDB_STORE}"
  )"; then
    log "could not measure capacity for corrupt-store recovery; preserving the original store"
    return 1
  fi
  mapfile -t capacity_values <<< "${metrics}"
  if [[ "${#capacity_values[@]}" -ne 4 ]]; then
    log "could not measure capacity for corrupt-store recovery; preserving the original store"
    return 1
  fi
  used_kb="${capacity_values[0]}"
  available_kb="${capacity_values[1]}"
  used_inodes="${capacity_values[2]}"
  available_inodes="${capacity_values[3]}"

  if [[ ! "${used_kb}" =~ ^[0-9]+$ || ! "${available_kb}" =~ ^[0-9]+$ ]] || \
     ! awk -v used_kb="${used_kb}" -v available_kb="${available_kb}" \
       -v reserve_bytes="${CRDB_RECOVERY_MIN_FREE_BYTES}" \
       'BEGIN { exit !((available_kb * 1024) >= ((used_kb * 1024) + reserve_bytes)) }'; then
    log "insufficient free storage for corrupt-store recovery; preserving the original store"
    return 1
  fi
  if [[ ! "${used_inodes}" =~ ^[0-9]+$ || ! "${available_inodes}" =~ ^[0-9]+$ ]] || \
     ! awk -v used="${used_inodes}" -v available="${available_inodes}" \
       -v reserve="${CRDB_RECOVERY_MIN_FREE_INODES}" \
       'BEGIN { exit !(available >= (used + reserve)) }'; then
    log "insufficient free inodes for corrupt-store recovery; preserving the original store"
    return 1
  fi
}

log_dir_has_checksum_corruption() {
  local log_dir="$1"
  local entry log_file scan_status
  local -a pipeline_status=()
  local -a log_files=()
  [[ -d "${log_dir}" ]] || return 2
  shopt -s nullglob dotglob
  for entry in "${log_dir}"/*; do
    if [[ -f "${entry}" && ! -L "${entry}" ]]; then
      log_files+=("${entry}")
    fi
  done
  [[ "${#log_files[@]}" -gt 0 ]] || return 2
  for log_file in "${log_files[@]}"; do
    if tail -c "${CRDB_RECOVERY_LOG_SCAN_BYTES}" -- "${log_file}" 2>/dev/null | \
        awk 'index($0, "local corruption detected:") && index($0, "checksum mismatch") { found=1 } END { exit !found }'; then
      pipeline_status=("${PIPESTATUS[@]}")
    else
      pipeline_status=("${PIPESTATUS[@]}")
    fi
    [[ "${pipeline_status[0]}" == "0" ]] || return 2
    scan_status="${pipeline_status[1]}"
    if [[ "${scan_status}" == "0" ]]; then
      return 0
    fi
    [[ "${scan_status}" == "1" ]] || return 2
  done
  return 1
}

current_run_has_checksum_corruption() {
  [[ -n "${CRDB_CURRENT_RUN_LOG_DIR}" ]] || return 2
  log_dir_has_checksum_corruption "${CRDB_CURRENT_RUN_LOG_DIR}"
}

recovery_run_has_checksum_corruption() {
  local log_root="$1/logs" run_dir run_name="$2"

  [[ -e "${log_root}" || -L "${log_root}" ]] || return 2
  if [[ ! -d "${log_root}" || -L "${log_root}" || \
        "$(stat -c '%u' "${log_root}" 2>/dev/null || true)" != "0" || \
        "$(stat -c '%a' "${log_root}" 2>/dev/null || true)" != "700" ]]; then
    return 2
  fi
  if [[ ! "${run_name}" =~ ^deeploy-run\.[A-Za-z0-9]{8}$ ]]; then
    return 2
  fi
  run_dir="${log_root}/${run_name}"
  if [[ -L "${run_dir}" || ! -d "${run_dir}" || \
        "$(stat -c '%u' "${run_dir}" 2>/dev/null || true)" != "0" || \
        "$(stat -c '%a' "${run_dir}" 2>/dev/null || true)" != "700" ]]; then
    return 2
  fi
  log_dir_has_checksum_corruption "${run_dir}"
}

run_dir_contains_mount() {
  local _ escaped_target target run_dir="$1"

  [[ -r /proc/self/mountinfo ]] || return 2
  while IFS=' ' read -r _ _ _ _ escaped_target _; do
    printf -v target '%b' "${escaped_target}"
    if [[ "${target}" == "${run_dir}" || "${target}" == "${run_dir}/"* ]]; then
      return 0
    fi
  done < /proc/self/mountinfo
  return 1
}

prune_old_run_logs() {
  local record entry_type mount_status run_dir retained=0
  local prior_limit=$((CRDB_RECOVERY_LOG_RETENTION_RUNS - 1))
  local -a run_dirs=()

  run_log_list_file="$(mktemp /tmp/deeploy-crdb-run-list.XXXXXXXX)" || return 1
  if ! find "${CRDB_ACTIVE_STORE}/logs" -mindepth 1 -maxdepth 1 \
      -name 'deeploy-run.????????' -printf '%T@ %y %p\0' 2>/dev/null | \
      sort -zrn > "${run_log_list_file}" || \
     ! mapfile -d '' -t run_dirs < "${run_log_list_file}"; then
    log "could not enumerate CockroachDB run-log entries"
    return 1
  fi
  if ! rm -f -- "${run_log_list_file}"; then
    log "could not remove CockroachDB run-log enumeration state"
    return 1
  fi
  run_log_list_file=""
  for record in "${run_dirs[@]}"; do
    record="${record#* }"
    entry_type="${record%% *}"
    run_dir="${record#* }"
    mount_status=0
    run_dir_contains_mount "${run_dir}" || mount_status=$?
    if [[ "${entry_type}" != "d" || \
          ! "${run_dir##*/}" =~ ^deeploy-run\.[A-Za-z0-9]{8}$ || \
          -L "${run_dir}" ]]; then
      log "invalid CockroachDB run-log entry"
      return 1
    fi
    if [[ "$(stat -c '%u' "${run_dir}" 2>/dev/null || true)" != "0" || \
          "$(stat -c '%a' "${run_dir}" 2>/dev/null || true)" != "700" || \
          "${mount_status}" != "1" ]]; then
      log "invalid CockroachDB run-log entry"
      return 1
    fi
    if [[ "${retained}" -lt "${prior_limit}" ]]; then
      retained=$((retained + 1))
      continue
    fi
    if ! rm -rf -- "${run_dir}" || [[ -e "${run_dir}" || -L "${run_dir}" ]]; then
      log "could not remove old CockroachDB run-log entry"
      return 1
    fi
  done
}

fail_closed_interrupted_recovery() {
  local reason="$1"

  [[ "${CRDB_RECOVERY_ACTIVE}" == "true" ]] || return 0
  if [[ -e "${CRDB_RECOVERY_EXHAUSTED}" || -L "${CRDB_RECOVERY_EXHAUSTED}" ]]; then
    log "${reason}; recovery remains exhausted"
    return 0
  fi
  if [[ -e "${CRDB_RECOVERY_MARKER}" || -L "${CRDB_RECOVERY_MARKER}" ]]; then
    mark_recovery_exhausted || true
    log "${reason}; recovery is now fail closed"
    return 0
  fi
  umask 077
  printf 'invalid\n' > "${CRDB_RECOVERY_EXHAUSTED}" || true
  chmod 000 "${CRDB_RECOVERY_EXHAUSTED}" >/dev/null 2>&1 || true
  sync "${CRDB_RECOVERY_STATE_DIR}" >/dev/null 2>&1 || true
  log "${reason} with incomplete state; recovery is now fail closed"
}

prepare_current_run_log_dir() {
  local log_mode log_root="${CRDB_ACTIVE_STORE}/logs"

  if [[ -L "${log_root}" ]]; then
    log "invalid CockroachDB log directory"
    return 1
  fi
  if [[ ! -e "${log_root}" ]]; then
    mkdir -m 700 -- "${log_root}" || return 1
  fi
  if [[ -L "${log_root}" || ! -d "${log_root}" || \
        "$(stat -c '%u' "${log_root}" 2>/dev/null || true)" != "0" ]]; then
    log "invalid CockroachDB log directory"
    return 1
  fi
  log_mode="$(stat -c '%a' "${log_root}" 2>/dev/null || true)"
  if [[ "${log_mode}" == "755" ]]; then
    chmod 700 -- "${log_root}" || return 1
    log_mode="$(stat -c '%a' "${log_root}" 2>/dev/null || true)"
  fi
  if [[ -L "${log_root}" || "${log_mode}" != "700" ]]; then
    log "invalid CockroachDB log directory"
    return 1
  fi

  prune_old_run_logs || return 1
  CRDB_CURRENT_RUN_LOG_DIR="$(mktemp -d "${log_root}/deeploy-run.XXXXXXXX")" || return 1
  chmod 700 "${CRDB_CURRENT_RUN_LOG_DIR}" || return 1
  if [[ -L "${CRDB_CURRENT_RUN_LOG_DIR}" || \
        "$(stat -c '%u' "${CRDB_CURRENT_RUN_LOG_DIR}" 2>/dev/null || true)" != "0" || \
        "$(stat -c '%a' "${CRDB_CURRENT_RUN_LOG_DIR}" 2>/dev/null || true)" != "700" ]]; then
    log "could not establish a private current-run CockroachDB log directory"
    return 1
  fi
}

mark_recovery_started() {
  [[ "${CRDB_RECOVERY_ACTIVE}" == "true" ]] || return 0

  RECOVERY_MARKER_STATE=started
  RECOVERY_MARKER_RUN="${CRDB_CURRENT_RUN_LOG_DIR##*/}"
  if ! write_recovery_marker; then
    log "could not persist the fresh-store start state; recovery remains fail closed"
    return 1
  fi
}

prepare_corrupt_store_recovery() {
  local recovery_store
  if [[ -e "${CRDB_RECOVERY_STATE_DIR}" || -L "${CRDB_RECOVERY_STATE_DIR}" ]]; then
    if load_recovery_marker "${CRDB_RECOVERY_MARKER}"; then
      if mark_recovery_exhausted; then
        log "fresh-store recovery also encountered local checksum corruption; recovery is now exhausted"
      else
        log "could not fully synchronize corrupt-store recovery exhaustion state; later starts remain fail closed"
      fi
    else
      log "corrupt-store recovery was already consumed; no additional store will be created"
    fi
    return 0
  fi
  if [[ "${CRDB_AUTO_RECOVER_CORRUPT_STORE}" != "true" ]]; then
    log "automatic corrupt-store recovery is disabled; preserving the original store"
    return 0
  fi
  if [[ "${CRDB_NODE_COUNT}" -lt 3 ]]; then
    log "local checksum corruption detected, but automatic recovery requires at least three configured nodes"
    return 0
  fi
  recovery_capacity_available || return 0

  umask 077
  if ! mkdir -m 700 "${CRDB_RECOVERY_STATE_DIR}" || \
     ! recovery_store="$(mktemp -d "${CRDB_RECOVERY_STATE_DIR}/store.XXXXXXXX")"; then
    log "could not allocate corrupt-store recovery state; preserving the original store"
    return 1
  fi
  RECOVERY_MARKER_STATE=active
  RECOVERY_MARKER_NODE_ID="${CRDB_NODE_ID}"
  RECOVERY_MARKER_NODE_COUNT="${CRDB_NODE_COUNT}"
  RECOVERY_MARKER_TOPOLOGY_FINGERPRINT="${CRDB_TOPOLOGY_FINGERPRINT}"
  RECOVERY_MARKER_CA_FINGERPRINT="${CRDB_CA_FINGERPRINT}"
  RECOVERY_MARKER_CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  RECOVERY_MARKER_STORE="${recovery_store##*/}"
  RECOVERY_MARKER_RUN=none
  if write_recovery_marker; then
    log "local checksum corruption detected; preserved the original store and recorded one fresh-store recovery attempt"
  else
    log "could not persist corrupt-store recovery state; preserving the original store"
    return 1
  fi
}

register_required_process() {
  local pid="$1"
  local name="$2"
  REQUIRED_PIDS+=("${pid}")
  REQUIRED_PROCESS_NAMES["${pid}"]="${name}"
}

process_has_exited() {
  local pid="$1"
  local stat=""
  local state=""
  if ! kill -0 "${pid}" >/dev/null 2>&1; then
    return 0
  fi
  if [[ -r "/proc/${pid}/stat" ]]; then
    IFS= read -r stat < "/proc/${pid}/stat" || true
    stat="${stat##*) }"
    state="${stat%% *}"
  fi
  [[ "${state}" == "Z" ]]
}

collect_process_status() {
  PROCESS_STATUS=0
  wait "$1" || PROCESS_STATUS=$?
}

monotonic_millis() {
  local uptime seconds fraction
  read -r uptime _ < /proc/uptime
  seconds="${uptime%%.*}"
  fraction="${uptime#*.}000"
  fraction="${fraction:0:3}"
  MONOTONIC_MILLIS=$((10#${seconds} * 1000 + 10#${fraction}))
}

tcp_listener_ready() {
  local host="$1"
  local port="$2"
  local remaining_millis="$3"
  local timeout_millis
  local timeout_seconds
  [[ "${remaining_millis}" -gt 0 ]] || return 1
  timeout_millis="${remaining_millis}"
  if [[ "${timeout_millis}" -gt 1000 ]]; then
    timeout_millis=1000
  fi
  printf -v timeout_seconds '%d.%03d' \
    "$((timeout_millis / 1000))" "$((timeout_millis % 1000))"
  # shellcheck disable=SC2016  # Positional parameters are expanded by the probe shell.
  timeout --signal=KILL "${timeout_seconds}s" bash -c \
    'exec 3<>"/dev/tcp/${1}/${2}"' deeploy-crdb-tcp-probe "${host}" "${port}" \
    >/dev/null 2>&1
}

sleep_until_next_listener_probe() {
  local deadline="$1"
  local remaining_millis
  local sleep_millis
  local sleep_seconds
  monotonic_millis
  remaining_millis=$((deadline - MONOTONIC_MILLIS))
  [[ "${remaining_millis}" -gt 0 ]] || return 1
  sleep_millis="${remaining_millis}"
  if [[ "${sleep_millis}" -gt 100 ]]; then
    sleep_millis=100
  fi
  printf -v sleep_seconds '%d.%03d' \
    "$((sleep_millis / 1000))" "$((sleep_millis % 1000))"
  sleep "${sleep_seconds}"
}

corrupt_store_recovery_handler() {
  trap - EXIT INT TERM
  if current_run_has_checksum_corruption; then
    prepare_corrupt_store_recovery || true
  fi
}

terminate_recovery_handler() {
  local handler_pid="$1"
  local deadline

  kill -TERM -- "-${handler_pid}" >/dev/null 2>&1 || \
    kill -TERM "${handler_pid}" >/dev/null 2>&1 || true
  monotonic_millis
  deadline=$((MONOTONIC_MILLIS + 500))
  while ! process_has_exited "${handler_pid}"; do
    monotonic_millis
    [[ "${MONOTONIC_MILLIS}" -ge "${deadline}" ]] && break
    sleep 0.1
  done

  kill -KILL -- "-${handler_pid}" >/dev/null 2>&1 || \
    kill -KILL "${handler_pid}" >/dev/null 2>&1 || true
  monotonic_millis
  deadline=$((MONOTONIC_MILLIS + 1000))
  while ! process_has_exited "${handler_pid}"; do
    monotonic_millis
    [[ "${MONOTONIC_MILLIS}" -ge "${deadline}" ]] && break
    sleep 0.1
  done
  if process_has_exited "${handler_pid}"; then
    wait "${handler_pid}" >/dev/null 2>&1 || true
  else
    log "corrupt-store classifier did not exit after KILL; leaving final teardown to the container runtime"
  fi
}

run_recovery_log_scan_bounded() {
  local recovery_store="$1"
  local recovery_run="$2"
  local deadline handler_pid scan_status=0

  export -f log_dir_has_checksum_corruption recovery_run_has_checksum_corruption
  export CRDB_RECOVERY_LOG_SCAN_BYTES
  # shellcheck disable=SC2016  # Positional parameters are expanded by the worker shell.
  setsid /bin/bash -c 'set -euo pipefail; recovery_run_has_checksum_corruption "$1" "$2"' \
    deeploy-crdb-recovery-scan "${recovery_store}" "${recovery_run}" >/dev/null &
  recovery_handler_pid="$!"
  handler_pid="${recovery_handler_pid}"

  monotonic_millis
  deadline=$((MONOTONIC_MILLIS + CRDB_RECOVERY_HANDLER_TIMEOUT_SECONDS * 1000))
  while ! process_has_exited "${handler_pid}"; do
    monotonic_millis
    if [[ "${MONOTONIC_MILLIS}" -ge "${deadline}" ]]; then
      log "previous recovery log classification exceeded ${CRDB_RECOVERY_HANDLER_TIMEOUT_SECONDS} seconds"
      terminate_recovery_handler "${handler_pid}"
      recovery_handler_pid=""
      return 124
    fi
    sleep 0.1
  done
  wait "${handler_pid}" || scan_status=$?
  recovery_handler_pid=""
  return "${scan_status}"
}

run_corrupt_store_recovery_bounded() {
  local deadline handler_pid

  export -f log load_recovery_marker write_recovery_marker mark_recovery_exhausted
  export -f recovery_capacity_available log_dir_has_checksum_corruption
  export -f current_run_has_checksum_corruption prepare_corrupt_store_recovery
  export -f corrupt_store_recovery_handler
  export CRDB_CURRENT_RUN_LOG_DIR CRDB_RECOVERY_LOG_SCAN_BYTES CRDB_RECOVERY_STATE_DIR
  export CRDB_RECOVERY_MARKER CRDB_RECOVERY_EXHAUSTED CRDB_AUTO_RECOVER_CORRUPT_STORE
  export CRDB_NODE_COUNT CRDB_NODE_ID CRDB_TOPOLOGY_FINGERPRINT CRDB_CA_FINGERPRINT
  export CRDB_STORE CRDB_RECOVERY_MIN_FREE_BYTES CRDB_RECOVERY_MIN_FREE_INODES
  setsid /bin/bash -c 'set -euo pipefail; corrupt_store_recovery_handler' >/dev/null &
  recovery_handler_pid="$!"
  handler_pid="${recovery_handler_pid}"

  monotonic_millis
  deadline=$((MONOTONIC_MILLIS + CRDB_RECOVERY_HANDLER_TIMEOUT_SECONDS * 1000))
  while true; do
    if process_has_exited "${handler_pid}"; then
      wait "${handler_pid}" >/dev/null 2>&1 || true
      recovery_handler_pid=""
      return 0
    fi
    monotonic_millis
    [[ "${MONOTONIC_MILLIS}" -ge "${deadline}" ]] && break
    sleep 0.1
  done

  log "corrupt-store classification exceeded ${CRDB_RECOVERY_HANDLER_TIMEOUT_SECONDS} seconds; preserving the original store"
  terminate_recovery_handler "${handler_pid}"
  recovery_handler_pid=""
  fail_closed_interrupted_recovery "fresh-store recovery classification timed out"
}

terminate_processes() {
  local -a pids=()
  local pid all_exited attempt
  local grace_attempts=$((CRDB_SHUTDOWN_GRACE_SECONDS * 10))

  for pid in "$@"; do
    [[ -z "${pid}" ]] || pids+=("${pid}")
  done
  for pid in "${pids[@]}"; do
    process_has_exited "${pid}" || kill -TERM "${pid}" >/dev/null 2>&1 || true
  done
  for ((attempt = 0; attempt < grace_attempts; attempt++)); do
    all_exited=1
    for pid in "${pids[@]}"; do
      if ! process_has_exited "${pid}"; then
        all_exited=0
        break
      fi
    done
    [[ "${all_exited}" == "0" ]] || break
    sleep 0.1
  done
  for pid in "${pids[@]}"; do
    process_has_exited "${pid}" || kill -KILL "${pid}" >/dev/null 2>&1 || true
  done
  for ((attempt = 0; attempt < 10; attempt++)); do
    all_exited=1
    for pid in "${pids[@]}"; do
      if ! process_has_exited "${pid}"; then
        all_exited=0
        break
      fi
    done
    [[ "${all_exited}" == "0" ]] || break
    sleep 0.1
  done
  for pid in "${pids[@]}"; do
    if process_has_exited "${pid}"; then
      wait "${pid}" >/dev/null 2>&1 || true
    else
      log "process ${pid} did not exit after KILL; leaving final teardown to the container runtime"
    fi
  done
}

# shellcheck disable=SC2329  # Invoked by the EXIT/INT/TERM traps below.
cleanup() {
  local status=$?
  local recovery_handler_was_active=false
  trap - EXIT INT TERM
  set +e
  remove_sensitive_temp_file "${bootstrap_sql}"
  remove_sensitive_temp_file "${bootstrap_output}"
  remove_sensitive_temp_file "${init_output_file}"
  remove_sensitive_temp_file "${run_log_list_file}"
  remove_sensitive_temp_file "${R1_SQL_PASSWORD_FILE}"

  [[ -z "${recovery_handler_pid}" ]] || recovery_handler_was_active=true
  if [[ "${recovery_handler_was_active}" == "true" ]]; then
    terminate_recovery_handler "${recovery_handler_pid}"
    recovery_handler_pid=""
  fi
  terminate_processes "${active_operation_pid}" "${REQUIRED_PIDS[@]:-}"
  remove_sensitive_temp_file "${R1_SQL_TUNNEL_TOKEN_FILE}"
  rmdir "${R1_SQL_SECRET_DIR}" >/dev/null 2>&1 || true
  if [[ "${recovery_handler_was_active}" == "true" ]]; then
    fail_closed_interrupted_recovery "fresh-store recovery classification was interrupted"
  fi
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

remove_sensitive_temp_file() {
  local path="${1:-}"

  [[ -n "${path}" && ( -e "${path}" || -L "${path}" ) ]] || return 0
  if rm -f -- "${path}"; then
    return 0
  fi
  log "could not remove a sensitive temporary file; attempting fail-closed cleanup"
  : > "${path}" 2>/dev/null || true
  chmod 000 -- "${path}" >/dev/null 2>&1 || true
  rm -f -- "${path}" >/dev/null 2>&1 || true
  return 0
}

required_process_exited() {
  local pid="$1"
  local status="$2"
  local phase="$3"
  local name="${REQUIRED_PROCESS_NAMES[${pid}]:-Required process}"
  if [[ "${status}" == "0" ]]; then
    status=1
  fi
  if [[ "${pid}" == "${crdb_pid}" ]]; then
    run_corrupt_store_recovery_bounded
  fi
  log "${name} exited during ${phase} with status ${status}; inspect ${CRDB_ACTIVE_STORE}/logs for database details"
  exit "${status}"
}

run_guarded_operation() {
  local phase="$1"
  local operation_pid="$2"
  local operation_status
  local pid

  active_operation_pid="${operation_pid}"
  while true; do
    check_required_processes "${phase}"
    if process_has_exited "${operation_pid}"; then
      collect_process_status "${operation_pid}"
      operation_status="${PROCESS_STATUS}"
      check_required_processes "${phase}"
      active_operation_pid=""
      return "${operation_status}"
    fi
    sleep 0.1
  done
}

check_required_processes() {
  local phase="$1"
  local pid
  if [[ -n "${crdb_pid}" ]] && process_has_exited "${crdb_pid}"; then
    collect_process_status "${crdb_pid}"
    required_process_exited "${crdb_pid}" "${PROCESS_STATUS}" "${phase}"
  fi
  for pid in "${REQUIRED_PIDS[@]}"; do
    [[ "${pid}" == "${crdb_pid}" ]] && continue
    if process_has_exited "${pid}"; then
      collect_process_status "${pid}"
      required_process_exited "${pid}" "${PROCESS_STATUS}" "${phase}"
    fi
  done
}

wait_for_required_process_exit() {
  local phase="$1"
  while true; do
    check_required_processes "${phase}"
    sleep 0.1
  done
}

IFS=',' read -r -a HOSTNAMES <<< "${CRDB_HOSTNAMES}"
if [[ "${#HOSTNAMES[@]}" -ne "${CRDB_NODE_COUNT}" ]]; then
  log "CRDB_HOSTNAMES count ${#HOSTNAMES[@]} does not match CRDB_NODE_COUNT ${CRDB_NODE_COUNT}"
  exit 1
fi

if [[ "${CRDB_NODE_ID}" -lt 1 || "${CRDB_NODE_ID}" -gt "${CRDB_NODE_COUNT}" ]]; then
  log "CRDB_NODE_ID ${CRDB_NODE_ID} is outside 1..${CRDB_NODE_COUNT}"
  exit 1
fi

mkdir -p "${CRDB_STORE}" /tmp/cloudflared
normalize_and_validate_store_path || exit 1
prepare_store_root || exit 1
if ! select_recovery_store; then
  exit 1
fi

log "adding local roach host aliases"
for node in $(seq 1 "${CRDB_NODE_COUNT}"); do
  ip="${CRDB_BIND_HOST}"
  if [[ "${node}" != "${CRDB_NODE_ID}" ]]; then
    ip="${CRDB_LOOPBACK_PREFIX}.${node}"
  fi
  if ! grep -qE "[[:space:]]roach${node}([[:space:]]|$)" /etc/hosts; then
    printf '%s roach%s\n' "${ip}" "${node}" >> /etc/hosts
  fi
done

log "starting Cloudflare server tunnel for node ${CRDB_NODE_ID}"
cloudflared tunnel --no-autoupdate run \
  --token-file "${R1_SQL_TUNNEL_TOKEN_FILE}" \
  --url "tcp://${CRDB_BIND_HOST}:${CRDB_SQL_PORT}" \
  >/tmp/cloudflared/server.log 2>&1 &
register_required_process "$!" "Cloudflare server tunnel"

for node in $(seq 1 "${CRDB_NODE_COUNT}"); do
  if [[ "${node}" == "${CRDB_NODE_ID}" ]]; then
    continue
  fi
  hostname="${HOSTNAMES[$((node - 1))]}"
  listen_ip="${CRDB_LOOPBACK_PREFIX}.${node}"
  log "starting access listener for roach${node} via ${hostname} on ${listen_ip}:${CRDB_SQL_PORT}"
  cloudflared access tcp \
    --hostname "${hostname}" \
    --url "${listen_ip}:${CRDB_SQL_PORT}" \
    >/tmp/cloudflared/access-node"${node}".log 2>&1 &
  register_required_process "$!" "Cloudflare access listener for roach${node}"
done

join_list=""
for node in $(seq 1 "${CRDB_NODE_COUNT}"); do
  entry="roach${node}:${CRDB_SQL_PORT}"
  if [[ -z "${join_list}" ]]; then
    join_list="${entry}"
  else
    join_list="${join_list},${entry}"
  fi
done

wait_for_peer_listeners() {
  local node listen_ip deadline remaining_millis
  local -a unresolved_nodes=()
  local -a next_unresolved=()
  for node in $(seq 1 "${CRDB_NODE_COUNT}"); do
    if [[ "${node}" != "${CRDB_NODE_ID}" ]]; then
      unresolved_nodes+=("${node}")
    fi
  done
  monotonic_millis
  deadline=$((MONOTONIC_MILLIS + CRDB_BOOTSTRAP_TIMEOUT_SECONDS * 1000))
  while [[ "${#unresolved_nodes[@]}" -gt 0 ]]; do
    next_unresolved=()
    for node in "${unresolved_nodes[@]}"; do
      listen_ip="${CRDB_LOOPBACK_PREFIX}.${node}"
      monotonic_millis
      remaining_millis=$((deadline - MONOTONIC_MILLIS))
      [[ "${remaining_millis}" -gt 0 ]] || return 1
      if ! tcp_listener_ready "${listen_ip}" "${CRDB_SQL_PORT}" "${remaining_millis}"; then
        next_unresolved+=("${node}")
      fi
      monotonic_millis
      [[ "${MONOTONIC_MILLIS}" -lt "${deadline}" ]] || return 1
    done
    unresolved_nodes=("${next_unresolved[@]}")
    [[ "${#unresolved_nodes[@]}" -gt 0 ]] || return 0
    sleep_until_next_listener_probe "${deadline}" || return 1
  done
  return 0
}

if [[ "${CRDB_NODE_COUNT}" -gt 1 ]]; then
  wait_for_peer_listeners &
  peer_readiness_pid="$!"
  if ! run_guarded_operation "peer listener readiness" "${peer_readiness_pid}"; then
    log "one or more Cloudflare peer access listeners did not become ready within ${CRDB_BOOTSTRAP_TIMEOUT_SECONDS} seconds"
    exit 1
  fi
fi

log "starting CockroachDB node ${CRDB_NODE_ID} with join ${join_list}"
if ! prepare_current_run_log_dir; then
  exit 1
fi
if ! mark_recovery_started; then
  exit 1
fi
start_flags=(
  "--certs-dir=${CRDB_CERTS_DIR}"
  "--store=${CRDB_ACTIVE_STORE}"
  "--listen-addr=${CRDB_BIND_HOST}:${CRDB_SQL_PORT}"
  "--advertise-addr=roach${CRDB_NODE_ID}:${CRDB_SQL_PORT}"
  "--http-addr=${CRDB_HTTP_HOST}:${CRDB_HTTP_PORT}"
  "--join=${join_list}"
  "--max-offset=${CRDB_MAX_OFFSET}"
  "--cache=${CRDB_CACHE}"
  "--max-sql-memory=${CRDB_MAX_SQL_MEMORY}"
  "--log-dir=${CRDB_CURRENT_RUN_LOG_DIR}"
)
if [[ "${CRDB_ACCEPT_SQL_WITHOUT_TLS}" == "true" ]]; then
  start_flags+=("--accept-sql-without-tls")
fi
/cockroach/cockroach start \
  "${start_flags[@]}" &
crdb_pid="$!"
register_required_process "${crdb_pid}" "CockroachDB"

wait_for_sql_listener() {
  local deadline remaining_millis
  monotonic_millis
  deadline=$((MONOTONIC_MILLIS + CRDB_BOOTSTRAP_TIMEOUT_SECONDS * 1000))
  while true; do
    monotonic_millis
    remaining_millis=$((deadline - MONOTONIC_MILLIS))
    [[ "${remaining_millis}" -gt 0 ]] || return 1
    if tcp_listener_ready "${CRDB_BIND_HOST}" "${CRDB_SQL_PORT}" "${remaining_millis}"; then
      monotonic_millis
      if [[ "${MONOTONIC_MILLIS}" -lt "${deadline}" ]]; then
        return 0
      fi
      return 1
    fi
    monotonic_millis
    [[ "${MONOTONIC_MILLIS}" -lt "${deadline}" ]] || return 1
    sleep_until_next_listener_probe "${deadline}" || return 1
  done
}

wait_for_sql_listener &
sql_readiness_pid="$!"
if ! run_guarded_operation "SQL listener readiness" "${sql_readiness_pid}"; then
  log "CockroachDB SQL listener did not open on ${CRDB_BIND_HOST}:${CRDB_SQL_PORT} within ${CRDB_BOOTSTRAP_TIMEOUT_SECONDS} seconds"
  exit 1
fi

if [[ "${CRDB_NODE_ID}" == "1" ]]; then
  CRDB_BOOTSTRAP_HOST="roach${CRDB_NODE_ID}:${CRDB_SQL_PORT}"
  if [[ "${CRDB_RECOVERY_ACTIVE}" == "true" ]]; then
    log "skipping cluster initialization for a fresh-store recovery; the node must rejoin surviving peers"
  else
    log "initializing CockroachDB cluster if needed"
    init_output_file="$(mktemp /tmp/deeploy-crdb-init.XXXXXX.log)"
    timeout --signal=TERM --kill-after=5s "${CRDB_BOOTSTRAP_TIMEOUT_SECONDS}s" \
      /cockroach/cockroach init --certs-dir="${CRDB_CERTS_DIR}" --host="${CRDB_BOOTSTRAP_HOST}" \
      >"${init_output_file}" 2>&1 &
    init_pid="$!"
    init_status=0
    run_guarded_operation "cluster initialization" "${init_pid}" || init_status=$?
    init_output="$(cat "${init_output_file}")"
    rm -f "${init_output_file}"
    init_output_file=""
    if [[ "${init_status}" == "124" ]]; then
      log "cluster initialization timed out after ${CRDB_BOOTSTRAP_TIMEOUT_SECONDS} seconds"
      exit 124
    fi
    if [[ "${init_status}" != "0" ]]; then
      if grep -qiE "already initialized|cluster has already been initialized" <<< "${init_output}"; then
        log "CockroachDB cluster is already initialized"
      else
        printf '%s\n' "${init_output}" >&2
        exit "${init_status}"
      fi
    fi
  fi
  log "waiting for CockroachDB SQL bootstrap readiness"
  bootstrap_output="$(mktemp /tmp/deeploy-crdb-bootstrap.XXXXXX.log)"
  # shellcheck disable=SC2016  # Positional parameters are expanded by the inner shell.
  timeout --signal=TERM --kill-after=5s "${CRDB_BOOTSTRAP_TIMEOUT_SECONDS}s" \
    bash -c '
      while ! /cockroach/cockroach sql --certs-dir="$1" --host="$2" \
        -e "SELECT 1" >/dev/null 2> "$3"; do
        sleep 1
      done
    ' deeploy-crdb-readiness "${CRDB_CERTS_DIR}" "${CRDB_BOOTSTRAP_HOST}" \
      "${bootstrap_output}" &
  sql_bootstrap_readiness_pid="$!"
  sql_bootstrap_readiness_status=0
  run_guarded_operation "SQL bootstrap readiness" "${sql_bootstrap_readiness_pid}" || sql_bootstrap_readiness_status=$?
  rm -f "${bootstrap_output}"
  bootstrap_output=""
  if [[ "${sql_bootstrap_readiness_status}" == "124" ]]; then
    log "SQL bootstrap readiness timed out after ${CRDB_BOOTSTRAP_TIMEOUT_SECONDS} seconds"
    exit 124
  fi
  if [[ "${sql_bootstrap_readiness_status}" != "0" ]]; then
    log "SQL bootstrap readiness failed with status ${sql_bootstrap_readiness_status}"
    exit "${sql_bootstrap_readiness_status}"
  fi

  bootstrap_sql="$(mktemp /tmp/deeploy-crdb-bootstrap.XXXXXX.sql)"
  chmod 600 "${bootstrap_sql}"
  if [[ "${CRDB_RECOVERY_ACTIVE}" == "true" ]]; then
    log "fresh-store recovery reached the surviving cluster; ensuring existing database operator privileges"
    cat > "${bootstrap_sql}" <<SQL
ALTER USER ${CRDB_USER} WITH CREATEDB CREATEROLE CREATELOGIN;
GRANT ALL ON DATABASE ${CRDB_DATABASE} TO ${CRDB_USER} WITH GRANT OPTION;
SQL
  else
    password_literal="$(sql_quote_literal "${CRDB_PASSWORD}")"
    log "ensuring CockroachDB database and database operator exist"
    cat > "${bootstrap_sql}" <<SQL
CREATE DATABASE IF NOT EXISTS ${CRDB_DATABASE};
CREATE USER IF NOT EXISTS ${CRDB_USER} WITH PASSWORD ${password_literal};
ALTER USER ${CRDB_USER} WITH PASSWORD ${password_literal} CREATEDB CREATEROLE CREATELOGIN;
GRANT ALL ON DATABASE ${CRDB_DATABASE} TO ${CRDB_USER} WITH GRANT OPTION;
SQL
  fi
  bootstrap_output="$(mktemp /tmp/deeploy-crdb-bootstrap.XXXXXX.log)"
  timeout --signal=TERM --kill-after=5s "${CRDB_BOOTSTRAP_TIMEOUT_SECONDS}s" \
    /cockroach/cockroach sql --certs-dir="${CRDB_CERTS_DIR}" --host="${CRDB_BOOTSTRAP_HOST}" \
      < "${bootstrap_sql}" >/dev/null 2> "${bootstrap_output}" &
  sql_bootstrap_pid="$!"
  sql_bootstrap_status=0
  run_guarded_operation "SQL bootstrap" "${sql_bootstrap_pid}" || sql_bootstrap_status=$?
  rm -f "${bootstrap_sql}"
  rm -f "${bootstrap_output}"
  bootstrap_sql=""
  bootstrap_output=""
  if [[ "${sql_bootstrap_status}" == "124" ]]; then
    log "SQL bootstrap timed out after ${CRDB_BOOTSTRAP_TIMEOUT_SECONDS} seconds"
    exit 124
  fi
  if [[ "${sql_bootstrap_status}" != "0" ]]; then
    log "SQL bootstrap failed with status ${sql_bootstrap_status}; command output suppressed because it may contain credentials"
    exit "${sql_bootstrap_status}"
  fi
fi

remove_sensitive_temp_file "${R1_SQL_PASSWORD_FILE}"
CRDB_PASSWORD=""
unset CRDB_PASSWORD

log "startup orchestration complete; supervising required processes"
wait_for_required_process_exit "runtime"
