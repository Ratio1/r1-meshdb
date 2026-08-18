# Release Process

R1 MeshDB releases are produced only by
`.github/workflows/release.yml`. Local builds are development evidence and are
never production signatures.

## Repository Controls

Before the first release, repository administrators must:

1. Protect `main` and require the CI workflow before merge.
2. Create the `release` environment with required reviewers and restrict it to
   the protected `main` branch.
3. Prevent tag deletion or mutation for released tags.
4. Permit the repository workflow to publish the connected GHCR package.
5. Add `CF_ACCOUNT_ID`, `CF_ZONE_ID`, `CF_API_TOKEN`, and `CF_BASE_DOMAIN` as
   protected release-environment secrets. Use a dedicated token restricted to
   Cloudflare Tunnel edit plus DNS edit and zone read for one disposable zone.
6. Make the source repository public before dispatching a release. It may stay
   private while changes are staged and reviewed, but a public image is not
   published from source that anonymous recipients cannot retrieve. Keep the
   corresponding tagged source public for as long as that image is distributed.

An administrator manually dispatches the workflow from `main` with a version
matching `v1.0.<patch>`. The workflow requires its source SHA to
equal `origin/main` and byte-compares that checkout with an anonymously
downloaded source archive before it publishes even an untagged candidate. It
creates no Git or OCI release tag until the candidate has passed validation,
signing, and anonymous digest pull.

The candidate also has to pass a persisted rolling upgrade and rollback against
the immutable legacy service image, plus a three-node test using the unchanged
candidate image and three ephemeral real Cloudflare tunnels. Cleanup is
fail-closed: release promotion stops if any DNS record or tunnel cannot be
removed.
An untagged candidate digest is not a release and must not be used by consumers.
Only a published immutable digest that passes `scripts/verify-image.sh` is an
approved release artifact. Failed candidate digests may remain addressable in
GHCR, but they receive no version tag, source release, or `latest` tag.
If remote cleanup fails, the workflow deletes tunnel tokens but retains the
non-secret tunnel/DNS identifiers as `cloudflare-cleanup-state.json` in the
attempt-scoped `r1-meshdb-cloudflare-cleanup-<run ID>-<run attempt>`
artifact for seven days. The Cloudflare cleanup recovery workflow, **Recover
ephemeral Cloudflare resources**, runs automatically after a failed, cancelled,
or timed-out release. An operator can also dispatch it from `main` with the
source run ID and, when needed, its run attempt. The recovery validates the
source run and re-discovers only resources in that exact attempt namespace;
identifiers from the artifact never select resources for deletion.
Release-environment approval rules can delay cleanup, so operators must confirm
that the recovery run completes.

## First Package Publication

GHCR package visibility is separate from repository visibility. The workflow
builds the candidate once and publishes it only by immutable digest, with no
human-facing tag. It tests and scans that exact registry digest, then signs and
attests it.

GitHub does not expose a supported API for changing a package's visibility.
After the source repository is public, a package administrator must open the
`r1-meshdb` package settings and set **Package visibility** to
**Public**. The first release run is expected to stop at the anonymous-pull
gate after creating the package. Change visibility in the GitHub UI and rerun
the same release tag; no source or OCI version tag has been created at that
point. Later releases need no visibility action.

Do not make the package public while the source repository is private. The
workflow uses a fresh empty Docker credential directory to anonymously
pull the exact signed digest before it prepares a draft GitHub release/source
tag, creates the single immutable version image tag, publishes the release,
and updates `latest` last.
A version collision fails closed instead of moving an existing identifier.
If a run stops between those promotion steps, the next run may resume only
when the existing source tag resolves to the same source commit and the
existing OCI version tag resolves to the same candidate digest. Any mismatch
fails closed.

## Evidence

Each GitHub release contains the immutable image reference, source and image
SPDX/CycloneDX SBOMs, source hashes, provenance, notices, the exact Debian
corresponding-source bundle, and the Ratio1 patch record. GitHub's source
archive for the immutable tag is publicly available,
and the release records the SHA-256 of the anonymously downloaded pre-release
source archive. The image digest also carries GitHub provenance and SPDX attestations
and a separate keyless Cosign signature bound to the exact release workflow on
protected `main`. The reviewed OpenVEX document is attached as a digest-bound
Cosign attestation.

Consumers verify a release with:

```bash
scripts/verify-image.sh \
  ghcr.io/ratio1/r1-meshdb@sha256:<digest> \
  v1.0.<patch>
```

Do not move an existing version tag. Publish a new patch tag and document
superseded or revoked digests in its release notes.
