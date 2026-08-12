#!/usr/bin/env bash
set -euo pipefail

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
    trap 'exit 0' TERM INT
    while true; do
      sleep 1
    done
  fi
  if [[ "${hostname}" == "${TEST_CLOUDFLARED_ACCESS_LISTEN_DELAY_HOSTNAME:-}" ]]; then
    sleep "${TEST_CLOUDFLARED_ACCESS_LISTEN_DELAY_SECONDS:-2}"
  fi
  access_handler="sleep 60"
  if [[ "${hostname}" == "${TEST_CLOUDFLARED_ACCESS_PROBE_CAPTURE_HOSTNAME:-}" ]]; then
    access_handler="echo probe >> /tmp/cloudflared/peer-probes; sleep 60"
  fi
  exec socat \
    "TCP-LISTEN:${listen_address##*:},bind=${listen_address%:*},reuseaddr,fork" \
    "SYSTEM:${access_handler}"
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
  exec socat \
    "TCP-LISTEN:${listen_port},bind=${listen_host},reuseaddr,fork" \
    "TCP:${target_address}"
fi

trap 'exit 0' TERM INT
while true; do
  sleep 1
done
