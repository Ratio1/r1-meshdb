# R1 Distributed SQL

R1 Distributed SQL is an independently maintained Ratio1 distribution of the
CockroachDB v23.1.28 open-source core. It packages the OSS database engine with
the runtime entrypoint used by the Ratio1 Deeploy service.

This project is not affiliated with or endorsed by Cockroach Labs. CockroachDB
is a trademark of Cockroach Labs, Inc. The original engine source and its
copyright notices are retained under `engine/`.

## Image

The release image is published as:

```text
ghcr.io/ratio1/r1-distributed-sql
```

Production deployments must use an immutable digest. Release workflows publish
version and source-revision tags for discovery, but those tags are not a
substitute for a digest pin.

The executable intentionally remains `/cockroach/cockroach` to preserve the
upstream wire protocol, on-disk format, diagnostic tooling, and existing
Deeploy runtime contract. A release binary must pass:

```bash
./cockroach version | grep -F 'Distribution:     OSS'
```

## Source Boundary

The engine snapshot is derived from upstream tag `v23.1.28`, commit
`76e598c9b1c100fd9280b979140b5e377c330a20`. Its Business Source License change
date was 2026-04-01, after which covered source is available under Apache-2.0.
Files that carry the CockroachDB Community License are not included.

See [UPSTREAM.md](UPSTREAM.md), [RATIO1_PATCHES.md](RATIO1_PATCHES.md), and
[`source/provenance.json`](source/provenance.json) for exact provenance and
exclusions. `scripts/verify-source-boundary.py` audits both the checked-out tree
and every reachable Git object before release.

## Build

The container build uses the checked-in, affirmatively licensed runtime source
closure, generated parsers, vendored Go modules, and native dependency source.
The engine compilation runs with `GOPROXY=off`; it does not clone or download
upstream engine source and does not consume an upstream CockroachDB image or
builder. Cloudflared is independently compiled in vendor mode from an exact
Cloudflare source commit whose archive checksum, source metadata, compiled
package closure, binary hash, licenses, notices, and patent texts are enforced.

```bash
docker build -t r1-distributed-sql:local .
docker run --rm --entrypoint /cockroach/cockroach \
  r1-distributed-sql:local version
```

Run source and release-contract checks with:

```bash
python3 -m unittest tests.test_release_contract
python3 scripts/verify-source-boundary.py --worktree-only
python3 scripts/generate-license-inventory.py --check
python3 scripts/verify-provenance.py
python3 scripts/verify-public-test-fixtures.py
python3 scripts/verify-security-vex.py
python3 scripts/generate-source-manifest.py --check
```

The three-node runtime suite is documented in [testbed/README.md](testbed/README.md).

## Supply Chain

Releases include SPDX JSON and CycloneDX JSON SBOMs, GitHub build provenance,
an OCI SBOM attestation, and a keyless Cosign signature recorded in Rekor.
Verification is bound to the Ratio1 repository workflow identity; executable
commands are in `scripts/verify-image.sh`.
Repository and package promotion controls are documented in
[RELEASE.md](RELEASE.md).

```bash
scripts/verify-image.sh \
  ghcr.io/ratio1/r1-distributed-sql@sha256:<digest> \
  v23.1.28-r1.<major>.<patch>
```

## Support

The upstream v23.1 line is no longer supported upstream. Ratio1 owns review and
backport decisions for this distribution. See [SECURITY.md](SECURITY.md) for
the disclosure and update policy. Operators should evaluate every Ratio1 patch
release and plan an engine/store-format migration rather than treating this
version as indefinitely supported.

## Licensing

Ratio1-authored files and upstream engine files whose change license has taken
effect are distributed under Apache License 2.0. Included third-party
components retain their own licenses. See [LICENSE](LICENSE), [NOTICE](NOTICE),
and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
