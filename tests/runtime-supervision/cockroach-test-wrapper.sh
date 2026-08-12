#!/usr/bin/env bash
set -euo pipefail

block_forever() {
  trap 'exit 143' TERM INT
  while true; do
    sleep 1
  done
}

block_forever_ignoring_term() {
  trap '' TERM INT
  while true; do
    sleep 1
  done
}

is_readiness_query() {
  local arg
  for arg in "$@"; do
    [[ "${arg}" == "SELECT 1" ]] && return 0
  done
  return 1
}

kill_real_server() {
  local command command_file pid found=0
  for command_file in /proc/[0-9]*/cmdline; do
    command="$(tr '\0' ' ' 2>/dev/null < "${command_file}" || true)"
    case "${command}" in
      "/cockroach/cockroach-real start "*)
        pid="${command_file#/proc/}"
        pid="${pid%/cmdline}"
        kill -KILL "${pid}"
        found=1
        ;;
    esac
  done
  [[ "${found}" == "1" ]]
}

store_from_start_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --store=*)
        printf '%s\n' "${arg#--store=}"
        return 0
        ;;
    esac
  done
  return 1
}

log_dir_from_start_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --log-dir=*)
        printf '%s\n' "${arg#--log-dir=}"
        return 0
        ;;
    esac
  done
  return 1
}

listen_address_from_start_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --listen-addr=*)
        printf '%s\n' "${arg#--listen-addr=}"
        return 0
        ;;
    esac
  done
  return 1
}

write_test_server_log() {
  local log_dir="$1"
  local mode="$2"
  mkdir -p "${log_dir}"
  case "${mode}" in
    corruption_exit|corruption_signal_exit|corruption_block)
      printf 'F000000 00:00:00.000000 1 storage: local corruption detected: pebble/table: invalid table 004786 (checksum mismatch at 937483/2360)\n' \
        >> "${log_dir}/cockroach-current.log"
      touch /runtime/capture/current-corruption-log-ready
      ;;
    split_corruption_exit)
      printf 'F000000 00:00:00.000000 1 storage: local corruption detected: pebble/table: invalid table 004786\nchecksum mismatch at 937483/2360\n' \
        >> "${log_dir}/cockroach-current.log"
      ;;
    truncate_corruption_exit)
      printf 'stale bytes that must be discarded\n' > "${log_dir}/cockroach-current.log"
      : > "${log_dir}/cockroach-current.log"
      printf 'F000000 00:00:00.000000 1 storage: local corruption detected: pebble/table: invalid table 004786 (checksum mismatch at 937483/2360)\n' \
        >> "${log_dir}/cockroach-current.log"
      ;;
  esac
}

case "${1:-}" in
  start)
    case "${TEST_CRDB_START_MODE:-}" in
      exit)
        exit "${TEST_CRDB_START_EXIT_CODE:-42}"
        ;;
      corruption_exit|split_corruption_exit|truncate_corruption_exit|corruption_signal_exit|corruption_block)
        log_dir="$(log_dir_from_start_args "$@")"
        write_test_server_log "${log_dir}" "${TEST_CRDB_START_MODE}"
        if [[ "${TEST_CRDB_START_MODE}" == "corruption_signal_exit" ]]; then
          touch /runtime/capture/crdb-corruption-ready
        fi
        if [[ "${TEST_CRDB_START_MODE}" == "corruption_block" ]]; then
          touch /runtime/capture/crdb-corruption-blocked
          while [[ ! -e /runtime/capture/release-crdb-corruption ]]; do
            sleep 0.1
          done
        fi
        exit "${TEST_CRDB_START_EXIT_CODE:-86}"
        ;;
      rename_stale_exit)
        store="$(store_from_start_args "$@")"
        mv "${store}/logs/stale.log" "${store}/logs/cockroach-renamed.log"
        exit "${TEST_CRDB_START_EXIT_CODE:-86}"
        ;;
      capture_store_exit)
        : "${TEST_CRDB_CAPTURE_STORE_FILE:?TEST_CRDB_CAPTURE_STORE_FILE is required}"
        log_dir="$(log_dir_from_start_args "$@")"
        printf 'ordinary startup log\n' > "${log_dir}/cockroach-current.log"
        store_from_start_args "$@" > "${TEST_CRDB_CAPTURE_STORE_FILE}"
        exit "${TEST_CRDB_START_EXIT_CODE:-44}"
        ;;
      listen_block)
        listen_address="$(listen_address_from_start_args "$@")"
        exec socat "TCP-LISTEN:${listen_address##*:},bind=${listen_address%:*},reuseaddr,fork" SYSTEM:'sleep 60'
        ;;
      block_no_listener)
        block_forever
        ;;
      listen_after_delay)
        listen_address="$(listen_address_from_start_args "$@")"
        sleep "${TEST_CRDB_LISTEN_DELAY_SECONDS:-61}"
        exec socat "TCP-LISTEN:${listen_address##*:},bind=${listen_address%:*},reuseaddr,fork" SYSTEM:'sleep 60'
        ;;
      listen_then_exit)
        listen_address="$(listen_address_from_start_args "$@")"
        socat "TCP-LISTEN:${listen_address##*:},bind=${listen_address%:*},reuseaddr,fork" SYSTEM:'sleep 60' &
        listener_pid="$!"
        sleep 2
        kill "${listener_pid}" >/dev/null 2>&1 || true
        wait "${listener_pid}" >/dev/null 2>&1 || true
        exit "${TEST_CRDB_START_EXIT_CODE:-45}"
        ;;
    esac
    ;;
  init)
    if [[ -n "${TEST_CRDB_INIT_CAPTURE_FILE:-}" ]]; then
      touch "${TEST_CRDB_INIT_CAPTURE_FILE}"
    fi
    case "${TEST_CRDB_INIT_MODE:-}" in
      block)
        block_forever
        ;;
      ignore_term)
        block_forever_ignoring_term
        ;;
      success)
        touch /tmp/runtime-supervision-init-complete
        exit 0
        ;;
      corruption_exit)
        printf 'local corruption detected: client fixture (checksum mismatch at 1/1)\n' >&2
        exit 48
        ;;
    esac
    ;;
  sql)
    if ! is_readiness_query "$@" && [[ -n "${TEST_CRDB_SQL_CAPTURE_FILE:-}" ]]; then
      touch "${TEST_CRDB_SQL_CAPTURE_FILE}"
      if [[ -n "${TEST_CRDB_SQL_INPUT_CAPTURE_FILE:-}" ]]; then
        cat > "${TEST_CRDB_SQL_INPUT_CAPTURE_FILE}"
      fi
    fi
    case "${TEST_CRDB_SQL_MODE:-}" in
      block)
        block_forever
        ;;
      success)
        if is_readiness_query "$@"; then
          touch /tmp/runtime-supervision-readiness-complete
        else
          touch /tmp/runtime-supervision-sql-complete
        fi
        exit 0
        ;;
      fail_once)
        if is_readiness_query "$@"; then
          if [[ ! -f /tmp/runtime-supervision-sql-failed-once ]]; then
            touch /tmp/runtime-supervision-sql-failed-once
            exit 41
          fi
          touch /tmp/runtime-supervision-readiness-complete
        else
          touch /tmp/runtime-supervision-sql-complete
        fi
        exit 0
        ;;
      block_bootstrap)
        if is_readiness_query "$@"; then
          touch /tmp/runtime-supervision-readiness-complete
          exit 0
        fi
        block_forever
        ;;
      fail_then_kill_server)
        if is_readiness_query "$@"; then
          touch /tmp/runtime-supervision-readiness-complete
          exit 0
        fi
        kill_real_server
        exit 43
        ;;
      fail_bootstrap)
        if is_readiness_query "$@"; then
          touch /tmp/runtime-supervision-readiness-complete
          exit 0
        fi
        printf 'attempt\n' >> /tmp/runtime-supervision-bootstrap-attempts
        exit 47
        ;;
    esac
    ;;
esac

exec /cockroach/cockroach-real "$@"
