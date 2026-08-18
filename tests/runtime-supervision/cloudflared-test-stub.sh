#!/usr/bin/env bash
set -euo pipefail

record_block_timestamp() {
  local path="${1:-}"
  local uptime
  [[ -n "${path}" ]] || return 0
  read -r uptime _ < /proc/uptime
  umask 022
  printf '%s\n' "${uptime}" > "${path}"
  chmod 644 "${path}"
}

if [[ "${1:-}" == "access" && "${TEST_CLOUDFLARED_ACCESS_MODE:-}" == "exit" ]]; then
  exit "${TEST_CLOUDFLARED_ACCESS_EXIT_CODE:-24}"
fi

if [[ "${1:-}" == "tunnel" && "${TEST_CLOUDFLARED_SERVER_MODE:-${TEST_CLOUDFLARED_MODE:-}}" == "exit" ]]; then
  exit "${TEST_CLOUDFLARED_EXIT_CODE:-23}"
fi

if [[ "${1:-}" == "tunnel" && "${TEST_CLOUDFLARED_SERVER_MODE:-}" == "ignore_term" ]]; then
  trap '' TERM INT
  while true; do
    sleep 1
  done
fi

if [[ "${1:-}" == "tunnel" && "${TEST_CLOUDFLARED_SERVER_MODE:-}" == "exit_on_corruption_ready" ]]; then
  while [[ ! -e /runtime/capture/crdb-corruption-ready ]]; do
    sleep 0.02
  done
  exit "${TEST_CLOUDFLARED_EXIT_CODE:-23}"
fi

if [[ "${1:-}" == "access" && \
      ( -n "${TEST_CLOUDFLARED_ACCESS_LISTEN_DELAY_HOSTNAME:-}" || \
        -n "${TEST_CLOUDFLARED_ACCESS_BLOCK_HOSTNAME:-}" ) ]]; then
  hostname=""
  listen_address=""
  shift
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --hostname)
        hostname="$2"
        shift 2
        ;;
      --url)
        listen_address="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  if [[ "${hostname}" == "${TEST_CLOUDFLARED_ACCESS_BLOCK_HOSTNAME:-}" ]]; then
    record_block_timestamp "${TEST_CLOUDFLARED_ACCESS_BLOCK_STARTED_FILE:-}"
    trap 'record_block_timestamp "${TEST_CLOUDFLARED_ACCESS_BLOCK_TERM_FILE:-}"; exit 0' TERM INT
    while true; do
      sleep 0.05
    done
  fi
  if [[ "${hostname}" == "${TEST_CLOUDFLARED_ACCESS_LISTEN_DELAY_HOSTNAME:-}" ]]; then
    sleep "${TEST_CLOUDFLARED_ACCESS_LISTEN_DELAY_SECONDS:-2}"
  fi
  proxy_args=(
    --listen "${listen_address}"
    --target 127.0.0.1:1
  )
  if [[ "${hostname}" == "${TEST_CLOUDFLARED_ACCESS_PROBE_CAPTURE_HOSTNAME:-}" ]]; then
    proxy_args+=(--connection-log /tmp/cloudflared/peer-probes)
  fi
  exec /usr/local/bin/r1-test-tcp-proxy "${proxy_args[@]}"
fi

if [[ "${1:-}" == "access" && "${TEST_CLOUDFLARED_ACCESS_MODE:-}" == "proxy" ]]; then
  hostname=""
  listen_address=""
  shift
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --hostname)
        hostname="$2"
        shift 2
        ;;
      --url)
        listen_address="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done

  case "${hostname}" in
    roach1.local) target_address="target-roach1:26257" ;;
    roach2.local) target_address="target-roach2:26257" ;;
    roach3.local) target_address="target-roach3:26257" ;;
    *)
      echo "unknown test hostname: ${hostname}" >&2
      exit 2
      ;;
  esac

  listen_host="${listen_address%:*}"
  listen_port="${listen_address##*:}"
  if [[ -x /usr/local/bin/r1-test-tcp-proxy ]]; then
    exec /usr/local/bin/r1-test-tcp-proxy \
      --listen "${listen_host}:${listen_port}" \
      --target "${target_address}"
  fi
  echo "r1-test-tcp-proxy is required for runtime supervision" >&2
  exit 2
fi

trap 'exit 0' TERM INT
while true; do
  sleep 1
done
