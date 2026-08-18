#!/usr/bin/env bash
# Copyright 2026 Ratio1
# Licensed under the Apache License, Version 2.0. See LICENSE.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
upstream_commit="76e598c9b1c100fd9280b979140b5e377c330a20"
validator_image="r1-meshdb-generated-source-validator:$$-${RANDOM}"
builder_go_version="go1.19.10"

cleanup() {
  local status="$1"
  local cleanup_failed=0
  trap - EXIT
  docker image rm -f "${validator_image}" >/dev/null 2>&1 || cleanup_failed=1
  docker image inspect "${validator_image}" >/dev/null 2>&1 && cleanup_failed=1
  rm -rf "${tmp}" || cleanup_failed=1
  [[ ! -e "${tmp}" ]] || cleanup_failed=1
  if [[ "${status}" == "0" && "${cleanup_failed}" != "0" ]]; then
    echo "upstream provenance cleanup failed" >&2
    status=1
  fi
  exit "${status}"
}
trap 'cleanup $?' EXIT

engine_root="${tmp}/engine"
git -C "${tmp}" init --quiet engine
git -C "${engine_root}" remote add origin https://github.com/cockroachdb/cockroach.git
git -C "${engine_root}" fetch --quiet --depth=1 --filter=blob:none origin \
  "${upstream_commit}"
git -C "${engine_root}" checkout --quiet --detach FETCH_HEAD

docker build \
  --file "${root}/tests/generated-source/Dockerfile" \
  --tag "${validator_image}" \
  "${root}/tests/generated-source"
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp/r1-home \
  --env GOCACHE=/tmp/r1-go-build \
  --volume "${engine_root}:/go/src/github.com/cockroachdb/cockroach" \
  --volume "${root}/source/generated-files.txt:/r1-generated-files.txt:ro" \
  --workdir /go/src/github.com/cockroachdb/cockroach \
  --entrypoint /bin/bash \
  "${validator_image}" \
  -c 'set -euo pipefail
      mkdir -p "$HOME" "$GOCACHE"
      [[ "$(go version)" == "go version '"${builder_go_version}"' linux/amd64" ]]
      make -j4 vendor/modules.txt
      targets=$(grep "^pkg/" /r1-generated-files.txt | grep -Ev "\.pb(\.gw)?\.go$")
      make -j4 protobuf $targets'
python3 "${root}/scripts/verify-generated-provenance.py" --upstream-root "${engine_root}"

args=(--upstream-root "${engine_root}")
while IFS=$'\t' read -r name source_url commit; do
  native_root="${tmp}/native-${name}"
  git -C "${tmp}" init --quiet "native-${name}"
  git -C "${native_root}" remote add origin "${source_url}"
  git -C "${native_root}" fetch --quiet --depth=1 --filter=blob:none origin "${commit}"
  git -C "${native_root}" checkout --quiet --detach FETCH_HEAD
  args+=(--native-upstream "${name}=${native_root}")
done < <(
  python3 - "${root}/source/provenance.json" <<'PY'
import json
from pathlib import Path
import sys

provenance = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for dependency in provenance["nativeDependencies"]:
  print(dependency["name"], dependency["sourceUrl"], dependency["commit"], sep="\t")
PY
)

python3 "${root}/scripts/verify-provenance.py" "${args[@]}"
