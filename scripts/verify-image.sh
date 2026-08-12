#!/usr/bin/env bash
set -euo pipefail

image_ref="${1:?usage: verify-image.sh <image@sha256:digest> <release-tag>}"
release_tag="${2:?usage: verify-image.sh <image@sha256:digest> <release-tag>}"
expected_issuer="https://token.actions.githubusercontent.com"
expected_identity="https://github.com/Ratio1/r1-distributed-sql/.github/workflows/release.yml@refs/tags/${release_tag}"

case "${image_ref}" in
  ghcr.io/ratio1/r1-distributed-sql@sha256:*) ;;
  *)
    printf 'image must be an immutable ghcr.io/ratio1/r1-distributed-sql digest\n' >&2
    exit 1
    ;;
esac

if [[ ! "${release_tag}" =~ ^v23\.1\.28-r1\.[0-9]+\.[0-9]+$ ]]; then
  printf 'invalid R1 Distributed SQL release tag: %s\n' "${release_tag}" >&2
  exit 1
fi

for command in docker cosign gh; do
  command -v "${command}" >/dev/null 2>&1 || {
    printf 'required command not found: %s\n' "${command}" >&2
    exit 1
  }
done

gh attestation verify "oci://${image_ref}" \
  --repo Ratio1/r1-distributed-sql \
  --cert-identity "${expected_identity}" \
  --source-ref "refs/tags/${release_tag}" \
  --predicate-type 'https://slsa.dev/provenance/v1'
gh attestation verify "oci://${image_ref}" \
  --repo Ratio1/r1-distributed-sql \
  --cert-identity "${expected_identity}" \
  --source-ref "refs/tags/${release_tag}" \
  --predicate-type 'https://spdx.dev/Document/v2.3'

tmp_dir="$(mktemp -d)"
container_id=""
cleanup() {
  if [[ -n "${container_id}" ]]; then
    docker rm "${container_id}" >/dev/null 2>&1 || true
  fi
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

# This pull deliberately uses no registry login. Public anonymous access is a
# release requirement, not an assumption derived from repository visibility.
docker logout ghcr.io >/dev/null 2>&1 || true
docker pull "${image_ref}"
container_id="$(docker create "${image_ref}")"
docker cp "${container_id}:/cockroach/cockroach" "${tmp_dir}/cockroach"
chmod 755 "${tmp_dir}/cockroach"
(
  cd "${tmp_dir}"
  ./cockroach version | grep -F 'Distribution:     OSS'
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

docker image inspect "${image_ref}" --format '{{json .Config.Labels}}' \
  | grep -F 'org.opencontainers.image.source'
printf 'verified signed R1 Distributed SQL image: %s\n' "${image_ref}"
