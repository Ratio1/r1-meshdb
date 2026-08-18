#!/usr/bin/env bash
# Copyright 2026 Ratio1
# Licensed under the Apache License, Version 2.0. See LICENSE.

set -euo pipefail
umask 077

image_ref="${1:?usage: verify-image.sh <image@sha256:digest> <release-tag>}"
release_tag="${2:?usage: verify-image.sh <image@sha256:digest> <release-tag>}"
expected_issuer="https://token.actions.githubusercontent.com"
expected_identity="https://github.com/Ratio1/r1-distributed-sql/.github/workflows/release.yml@refs/heads/main"

[[ "${image_ref}" =~ ^ghcr\.io/ratio1/r1-meshdb@sha256:[0-9a-f]{64}$ ]] || {
  printf 'image must be an immutable ghcr.io/ratio1/r1-meshdb digest\n' >&2
  exit 1
}

if [[ ! "${release_tag}" =~ ^v1\.0\.[0-9]+$ ]]; then
  printf 'invalid R1 MeshDB release tag: %s\n' "${release_tag}" >&2
  exit 1
fi

for command in cmp diff docker cosign gh git python3 sha256sum tar; do
  command -v "${command}" >/dev/null 2>&1 || {
    printf 'required command not found: %s\n' "${command}" >&2
    exit 1
  }
done

tmp_dir="$(mktemp -d)"
anonymous_config="${tmp_dir}/docker-config"
mkdir -m 700 "${anonymous_config}"
container_id=""
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "${container_id}" ]]; then
    docker rm "${container_id}" >/dev/null 2>&1 || status=1
  fi
  find "${tmp_dir}" -mindepth 1 -depth -delete || status=1
  rmdir "${tmp_dir}" || status=1
  exit "${status}"
}
trap cleanup EXIT

is_draft="$(gh release view "${release_tag}" --repo Ratio1/r1-distributed-sql \
  --json isDraft --jq .isDraft)"
[[ "${is_draft}" == "false" ]] || {
  echo "release is missing or is still a draft: ${release_tag}" >&2
  exit 1
}
mkdir "${tmp_dir}/release"
gh release download "${release_tag}" --repo Ratio1/r1-distributed-sql \
  --pattern image-reference.txt --dir "${tmp_dir}/release"
gh release download "${release_tag}" --repo Ratio1/r1-distributed-sql \
  --pattern r1-meshdb-debian-corresponding-source.tar.gz --dir "${tmp_dir}/release"
printf '%s\n' "${image_ref}" > "${tmp_dir}/expected-image-reference.txt"
cmp "${tmp_dir}/expected-image-reference.txt" "${tmp_dir}/release/image-reference.txt"

# Resolve the public source tag with credentials and user Git configuration
# disabled. The peeled ref wins for an annotated tag; otherwise the lightweight
# tag's object is the release commit.
tag_refs="$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
  git -C "${tmp_dir}" -c credential.helper= -c http.extraHeader= ls-remote \
  https://github.com/Ratio1/r1-distributed-sql.git \
  "refs/tags/${release_tag}" "refs/tags/${release_tag}^{}")"
tag_commit="$(awk '$2 ~ /\^\{\}$/ { print $1; found=1 } END { if (!found) exit 1 }' \
  <<< "${tag_refs}" 2>/dev/null || awk '$2 !~ /\^\{\}$/ { print $1; exit }' <<< "${tag_refs}")"
[[ "${tag_commit}" =~ ^[0-9a-f]{40}$ ]] || {
  echo "public source tag is missing or invalid: ${release_tag}" >&2
  exit 1
}

gh attestation verify "oci://${image_ref}" \
  --repo Ratio1/r1-distributed-sql \
  --cert-identity "${expected_identity}" \
  --source-ref "refs/heads/main" \
  --source-digest "${tag_commit}" \
  --predicate-type 'https://slsa.dev/provenance/v1'
gh attestation verify "oci://${image_ref}" \
  --repo Ratio1/r1-distributed-sql \
  --cert-identity "${expected_identity}" \
  --source-ref "refs/heads/main" \
  --source-digest "${tag_commit}" \
  --predicate-type 'https://spdx.dev/Document/v2.3'

# This pull deliberately uses an empty credential directory. Public anonymous
# access is a release requirement, not an assumption derived from repository
# visibility, and verification must not mutate the caller's registry session.
DOCKER_CONFIG="${anonymous_config}" docker pull "${image_ref}"
container_id="$(docker create "${image_ref}")"
docker cp "${container_id}:/cockroach/cockroach" "${tmp_dir}/cockroach"
mkdir "${tmp_dir}/image-debian" "${tmp_dir}/release-debian"
docker cp "${container_id}:/usr/share/src/r1-meshdb/debian/." "${tmp_dir}/image-debian/"
(cd "${tmp_dir}/image-debian" && sha256sum -c SHA256SUMS)
tar -xzf "${tmp_dir}/release/r1-meshdb-debian-corresponding-source.tar.gz" \
  --strip-components=1 -C "${tmp_dir}/release-debian"
diff -qr "${tmp_dir}/image-debian" "${tmp_dir}/release-debian"
chmod 755 "${tmp_dir}/cockroach"
(
  cd "${tmp_dir}"
  ./cockroach version | grep -F 'Distribution:     OSS'
  ./cockroach version | grep -F "Build Tag:        ${release_tag}"
)

cosign verify \
  --certificate-oidc-issuer "${expected_issuer}" \
  --certificate-identity "${expected_identity}" \
  "${image_ref}"

cosign verify-attestation \
  --type spdxjson \
  --certificate-oidc-issuer "${expected_issuer}" \
  --certificate-identity "${expected_identity}" \
  "${image_ref}"

cosign verify-attestation \
  --type openvex \
  --certificate-oidc-issuer "${expected_issuer}" \
  --certificate-identity "${expected_identity}" \
  "${image_ref}"

docker image inspect "${image_ref}" --format '{{json .Config.Labels}}' \
  > "${tmp_dir}/labels.json"
python3 - "${tmp_dir}/labels.json" "${release_tag}" "${tag_commit}" <<'PY'
import json
from pathlib import Path
import sys

labels = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = {
  "org.opencontainers.image.licenses": "Apache-2.0",
  "org.opencontainers.image.source": "https://github.com/Ratio1/r1-distributed-sql",
  "org.opencontainers.image.version": sys.argv[2],
  "org.opencontainers.image.revision": sys.argv[3],
  "io.ratio1.r1-meshdb.distribution": "OSS",
}
for key, value in expected.items():
  if labels.get(key) != value:
    raise SystemExit(f"image label mismatch: {key}")
PY
printf 'verified signed R1 MeshDB image: %s\n' "${image_ref}"
