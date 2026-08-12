# Release Process

R1 Distributed SQL releases are produced only by
`.github/workflows/release.yml`. Local builds are development evidence and are
never production signatures.

## Repository Controls

Before the first release, repository administrators must:

1. Protect `main` and require the CI workflow before merge.
2. Create the `release` environment and restrict it to version tags matching
   `v23.1.28-r1.*`.
3. Prevent tag deletion or mutation for released tags.
4. Permit the repository workflow to publish the connected GHCR package.

The release workflow independently rejects tags outside
`v23.1.28-r1.<major>.<patch>` and rejects a tag commit that is not reachable
from `origin/main`.

## First Package Publication

GHCR package visibility is separate from repository visibility. The workflow
publishes the connected package, but an organization package administrator must
set the new `r1-distributed-sql` package to **Public** after its first creation.
The release does not complete until an authenticated registry session has been
removed and the immutable digest pulls anonymously.

## Evidence

Each GitHub release contains the immutable image reference, source and image
SPDX/CycloneDX SBOMs, source hashes, provenance, notices, and Ratio1 patch
record. The image digest also carries GitHub provenance and SPDX attestations
and a separate keyless Cosign signature bound to the exact release workflow
and tag identity.

Consumers verify a release with:

```bash
scripts/verify-image.sh \
  ghcr.io/ratio1/r1-distributed-sql@sha256:<digest> \
  v23.1.28-r1.<major>.<patch>
```

Do not move an existing version or source-revision tag. Publish a new patch tag
and document superseded or revoked digests in its release notes.
