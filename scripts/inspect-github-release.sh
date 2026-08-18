#!/usr/bin/env bash
# Copyright 2026 Ratio1
# Licensed under the Apache License, Version 2.0. See LICENSE.

set -euo pipefail
umask 077

release_tag="${1:?usage: inspect-github-release.sh <release-tag>}"
: "${GH_TOKEN:?GH_TOKEN is required}"

if [[ ! "${release_tag}" =~ ^v23\.1\.28-r1\.[0-9]+\.[0-9]+$ ]]; then
  echo "invalid R1 MeshDB release tag: ${release_tag}" >&2
  exit 2
fi

for command in curl python3; do
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

response="${tmp}/response.json"
status="$({
  printf 'url = "https://api.github.com/repos/Ratio1/r1-distributed-sql/releases/tags/%s"\n' "${release_tag}"
  printf 'header = "Authorization: Bearer %s"\n' "${GH_TOKEN}"
  printf 'header = "Accept: application/vnd.github+json"\n'
  printf 'header = "X-GitHub-Api-Version: 2022-11-28"\n'
  printf 'silent\nshow-error\n'
  printf 'output = "%s"\n' "${response}"
  printf 'write-out = "%%{http_code}"\n'
} | curl --config -)"

case "${status}" in
  200)
    python3 - "${release_tag}" "${response}" <<'PY'
import json
from pathlib import Path
import sys

expected_tag, response_path = sys.argv[1:]
document = json.loads(Path(response_path).read_text(encoding="utf-8"))
if document.get("tag_name") != expected_tag:
  raise SystemExit("GitHub release response identified an unexpected tag")
draft = document.get("draft")
if not isinstance(draft, bool):
  raise SystemExit("GitHub release response omitted its draft state")
print("draft" if draft else "published")
PY
    ;;
  404)
    printf 'missing\n'
    ;;
  *)
    echo "GitHub release lookup for ${release_tag} returned HTTP ${status}" >&2
    exit 1
    ;;
esac
