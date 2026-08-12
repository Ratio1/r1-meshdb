# Ratio1 Patch Record

This file records every deliberate difference between upstream CockroachDB
v23.1.28 commit `76e598c9b1c100fd9280b979140b5e377c330a20` and this distribution.
Every released file is covered by `source/manifest.sha256`.

## Source Preparation

### OSS runtime closure

- Retained the exact transitive source closure used by
  `pkg/cmd/cockroach-oss`, recorded in `source/runtime-files.txt`.
- Retained the GEOS, jemalloc, libedit, and PROJ source trees at the revisions
  recorded in `source/provenance.json`.
- Retained applicable upstream and vendored license/notice files.
- Excluded enterprise implementation, unused build/test/documentation trees,
  upstream workflow configuration, nested Git metadata, and the unused Kerberos
  native dependency. No enterprise feature gate was bypassed or relabeled.
- Generated parser, protobuf, and related outputs in an isolated full checkout
  of the exact upstream commit. `source/generated-files.txt` identifies those
  outputs; the public build never regenerates or mutates source.

### Comment-only source cleanup

Two comments in the retained OSS closure referred to excluded enterprise
workloads/assets. Ratio1 replaced those references with neutral wording in:

- `engine/pkg/cli/cli.go`
- `engine/pkg/ui/ui.go`

These edits do not affect compiled behavior. They allow the source-boundary
gate to reject enterprise paths and license markers without exceptions.

### Neutral direct build

`scripts/build-engine.sh` replaces the omitted mixed-tree Make/Bazel entrypoints.
It builds the four checked-in native dependencies and then compiles only
`pkg/cmd/cockroach-oss` with Go 1.19.13, `GOPROXY=off`, `-mod=vendor`, a fixed
source timestamp, and deterministic Ratio1 build metadata. It preserves the
upstream commit as `Build Commit ID` and requires all of:

```text
Distribution:     OSS
Build Tag:        v23.1.28-r1.<major>.<patch>
Build Type:       release
```

No database, SQL, consensus, storage, wire-protocol, or on-disk-format source
has been modified by Ratio1.

## Ratio1 Runtime Layer

The entrypoint and its tests were ported without behavior changes from
`Ratio1/deeploy-cockroachdb-service` commit
`89f1760c29b8d37bdac3ac4f274797e261db2811`:

| Source commit | Retained behavior |
| --- | --- |
| `0970295` | Multi-node Cloudflare sidecar and cluster bootstrap contract |
| `deb10f9` | Startup validation and hardening |
| `cb9ca47` | Separate wildcard SQL and RPC bind behavior |
| `c442cf1` | Deeploy-provided CA/node certificate authentication |
| `7362a14` | Bootstrap through the node's logical hostname |
| `b275cb0` | Build the upstream OSS executable |
| `3f4a2c4` | Child supervision and bounded corruption recovery |
| `b7d4294` | Idempotent database-operator privileges |
| `89f1760` | TLS-required SQL client connections by default |

The image retains `/cockroach/cockroach`, the legacy
`/usr/local/bin/deeploy-crdb-entrypoint`, `CRDB_*`, `roachN` logical hostnames,
certificate layout, Cloudflare topology, recovery metadata, and store format.

## Release Layer

- Uses digest-pinned neutral Go, Cloudflared, and Debian images.
- Resolves Debian packages from a dated snapshot and pins direct package
  versions.
- Embeds Apache, upstream, third-party, provenance, patch, and affirmative
  source-license records.
- Publishes source/image SPDX and CycloneDX SBOMs, GitHub build provenance, an
  OCI SPDX attestation, and a keyless Cosign signature for each image digest.

Future releases must add the purpose, affected files, compatibility impact,
tests, and first release for every new engine or runtime patch.
