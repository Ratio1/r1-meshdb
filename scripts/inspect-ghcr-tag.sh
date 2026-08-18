#!/usr/bin/env bash
# Copyright 2026 Ratio1
# Licensed under the Apache License, Version 2.0. See LICENSE.

set -euo pipefail
umask 077

tagged_ref="${1:?usage: inspect-ghcr-tag.sh <ghcr-version-tag>}"
: "${GHCR_USERNAME:?GHCR_USERNAME is required}"
: "${GHCR_TOKEN:?GHCR_TOKEN is required}"

if [[ ! "${tagged_ref}" =~ ^ghcr\.io/ratio1/r1-distributed-sql:(v23\.1\.28-r1\.[0-9]+\.[0-9]+)$ ]]; then
  echo "invalid R1 MeshDB GHCR version tag: ${tagged_ref}" >&2
  exit 2
fi
tag="${BASH_REMATCH[1]}"

for command in base64 curl python3; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "required command not found: ${command}" >&2
    exit 2
  }
done

tmp="$(mktemp -d)"
cleanup() {
  local status=$?
  trap - EXIT
  find "${tmp}" -mindepth 1 -depth -delete || status=1
  rmdir "${tmp}" || status=1
  exit "${status}"
}
trap cleanup EXIT

basic_auth="$(printf '%s' "${GHCR_USERNAME}:${GHCR_TOKEN}" | base64 | tr -d '\n')"
token_response="$({
  printf 'url = "https://ghcr.io/token?service=ghcr.io&scope=repository%%3Aratio1%%2Fr1-distributed-sql%%3Apull"\n'
  printf 'header = "Authorization: Basic %s"\n' "${basic_auth}"
  printf 'silent\nshow-error\nfail\n'
} | curl --config -)"
unset basic_auth

registry_token="$(python3 -c '
import json
import sys

document = json.load(sys.stdin)
token = document.get("token") or document.get("access_token")
if not isinstance(token, str) or not token:
  raise SystemExit("GHCR token response omitted the registry token")
print(token)
' <<< "${token_response}")"
unset token_response

headers="${tmp}/headers"
status="$({
  printf 'url = "https://ghcr.io/v2/ratio1/r1-distributed-sql/manifests/%s"\n' "${tag}"
  printf 'head\n'
  printf 'header = "Authorization: Bearer %s"\n' "${registry_token}"
  printf 'header = "Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"\n'
  printf 'silent\nshow-error\n'
  printf 'output = "/dev/null"\n'
  printf 'dump-header = "%s"\n' "${headers}"
  printf 'write-out = "%%{http_code}"\n'
} | curl --config -)"
unset registry_token

case "${status}" in
  200)
    digest="$(tr -d '\r' < "${headers}" \
      | awk 'tolower($0) ~ /^docker-content-digest:[[:space:]]*/ { sub(/^[^:]*:[[:space:]]*/, ""); print }' \
      | tail -n 1)"
    [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
      echo "GHCR returned an invalid or missing manifest digest for ${tagged_ref}" >&2
      exit 1
    }
    printf '%s\n' "${digest}"
    ;;
  404)
    printf 'absent\n'
    ;;
  *)
    echo "GHCR manifest lookup for ${tagged_ref} returned HTTP ${status}" >&2
    exit 1
    ;;
esac
