# Ratio1 Patch Record

This file records every deliberate difference between upstream CockroachDB
v23.1.28 commit `76e598c9b1c100fd9280b979140b5e377c330a20` and this distribution.
Every released file is covered by `source/manifest.sha256`.

R1 MeshDB v1.0.2 includes a first-party, dependency-free browser console at
`engine/pkg/ui/distoss/assets/bundle.js`, with its icon at
`engine/pkg/ui/distoss/assets/favicon.svg`. The console uses the retained
authenticated v2 login and SQL APIs to show cluster identity, list user tables,
and run SQL. `engine/pkg/ui/ui.go` links these assets from the console page.

The release also adds a reviewed `not_affected` OpenVEX decision for
`CVE-2026-53613`. The advisory targets util-linux's setuid `mount` path; the
minimal scratch runtime retains only non-setuid `setsid` from that package and
contains no `mount`, `umount`, `libmount`, or `/etc/fstab`. These changes do not
alter database, wire-protocol, consensus, or store-format behavior.

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
  of the exact upstream commit. The release gate runs the legacy Make generators
  with Go 1.19.10 in the neutral, digest-pinned validator defined by
  `tests/generated-source/Dockerfile`, then byte-compares all 155 retained
  generated OSS outputs. `source/generated-files.txt` identifies those outputs;
  the public image build never regenerates or mutates source. The temporary full
  checkout is validation input only and is never archived or distributed.

### R1 MeshDB identity, support, and privacy defaults

Ratio1 changed product-facing strings, issue/support routing, compatibility
documentation, and telemetry defaults in these retained upstream files:

- `engine/pkg/build/info.go`
- `engine/pkg/cli/cli.go`
- `engine/pkg/cli/clierrorplus/decorate_error.go`
- `engine/pkg/cli/cliflags/flags.go`
- `engine/pkg/cli/clisqlcfg/context.go`
- `engine/pkg/cli/clisqlclient/conn.go`
- `engine/pkg/cli/clisqlshell/sql.go`
- `engine/pkg/cli/demo.go`
- `engine/pkg/cli/debug_recover_loss_of_quorum.go`
- `engine/pkg/cli/examples.go`
- `engine/pkg/cli/flags.go`
- `engine/pkg/cli/gen.go`
- `engine/pkg/cli/import.go`
- `engine/pkg/cli/init.go`
- `engine/pkg/cli/sql_shell_cmd.go`
- `engine/pkg/cli/start.go`
- `engine/pkg/docs/docs.go`
- `engine/pkg/kv/kvserver/replica_consistency.go`
- `engine/pkg/kv/kvserver/replica_corruption.go`
- `engine/pkg/kv/kvclient/kvcoord/txn_coord_sender.go`
- `engine/pkg/server/api_v2_error.go`
- `engine/pkg/server/diagnostics/diagnostics.go`
- `engine/pkg/server/server.go`
- `engine/pkg/settings/cluster/cluster_settings.go`
- `engine/pkg/sql/crdb_internal.go`
- `engine/pkg/sql/vars.go`
- `engine/pkg/ui/ui.go` (product identity and first-party console asset links)
- `engine/pkg/util/log/clog.go`
- `engine/pkg/util/log/logcrash/crash_reporting.go`
- `engine/pkg/util/tracing/tracer.go`

The compiled CLI, console, build metadata, logs, SQL build-info row, and
OpenTelemetry service name now identify R1 MeshDB. Fatal errors and issue URLs
route to Ratio1. Compatibility links are pinned explicitly to upstream v23.1
instead of deriving a nonexistent CockroachDB v1.0 documentation path.

Update checks, diagnostics reporting, and crash submission have no default
network endpoint; diagnostics reporting is disabled and telemetry opt-out is
enabled by default. An operator may still configure the retained explicit
crash-report environment override. Neutral comment wording for excluded
enterprise workloads/assets remains in `engine/pkg/cli/cli.go` and
`engine/pkg/ui/ui.go` so source-boundary checks require no exceptions.

### Dependency snapshot and neutral direct build

The retained runtime dependency snapshot is refreshed for the pinned Go 1.26.6
toolchain. `engine/go.mod`, `engine/go.sum`, and
`engine/vendor/modules.txt` are hash-pinned in `source/provenance.json` and
`source/ratio1-engine-overrides.json`; every vendored file remains covered by
the source manifest and affirmative license inventory. Security-relevant
updates include gRPC 1.82.1, pgx/v5 5.9.2, pgx/v4 4.18.3, pgproto3/v2 2.3.3,
Apache Thrift 0.23.0, Azure Identity 1.6.0, MSAL 1.2.2, JWT/v4 4.5.2,
JWT/v5 5.2.2, and current reviewed `x/crypto`, `x/net`, `x/oauth2`, and
`x/text` versions. Azure Identity 1.6.0 addresses `GO-2024-2918`; its MSAL
upgrade also removes the legacy unversioned JWT package from the compiled
runtime.

The refreshed gRPC credentials options gained an additional field after the
retained Google API client snapshot was published. The vendored
`google.golang.org/api/transport/grpc/dial.go` uses the equivalent named-field
literal from Google API client v0.160.0 so the retained client compiles without
changing its authentication behavior. This compatibility backport is
recorded as `google-api-grpc-credentials-options` and hash-pinned in
`source/ratio1-engine-overrides.json`.

The vendored libedit binding's generated
`engine/vendor/github.com/knz/go-libedit/unix/zcgo_flags_extra.go` is also
hash-pinned there because CockroachDB's `vendor_rebuild` emits it and it is not
part of the checksum-backed upstream module archive.

`scripts/build-engine.sh` replaces the omitted mixed-tree Make/Bazel entrypoints.
It builds the four checked-in native dependencies and then compiles only
`pkg/cmd/cockroach-oss` with Go 1.26.6, `GOPROXY=off`, `-mod=vendor`, a fixed
source timestamp, and deterministic Ratio1 build metadata. It preserves the
upstream commit as `Build Commit ID` and requires all of:

```text
Distribution:     OSS
Build Tag:        v1.0.2
Build Type:       release
```

No query-planning, query-execution, consensus, wire-protocol, or on-disk-format
semantics have been modified by Ratio1. The one storage-source change is the
typed corruption signal documented below; `crdb_internal` changes only the
reported product name and one catalog description.

`engine/pkg/util/goschedstats/runtime_go1.26.go` preserves the v23.1 scheduler
load-sampling contract on Go 1.26 by reading the standard
`/sched/goroutines/runnable:goroutines` and `/sched/gomaxprocs:threads`
runtime metrics. It replaces the excluded Go 1.19 runtime-structure link for
this toolchain without changing the admission-control callback API.
`engine/pkg/util/goschedstats/runtime_go1.26_test.go` covers that adapter.

`engine/pkg/util/ctxutil/context.go` now uses the public
`context.AfterFunc` API. The incompatible private-ABI shim
`engine/pkg/util/ctxutil/context_abi_pre1_20.go` is omitted, and
`engine/pkg/util/ctxutil/context_go1.20_test.go` covers cancellation and
non-cancellable contexts.

### Security backports

- `CVE-2026-39821` and `CVE-2026-46600`: all Go runtime binaries are rebuilt
  with Go 1.26.6 instead of Go 1.26.5. The patch release supplies the standard
  library fixes used by the database, Cloudflared, and the atomic replacement
  helper without changing their source-level behavior.
- `GO-2026-4518`: `engine/vendor/github.com/jackc/pgproto3/v2/data_row.go`
  rejects negative non-null field lengths. The regression is in
  `data_row_r1_test.go` and covers direct decoding plus a complete frontend
  frame; the fix follows maintained pgx commit
  `7f382f5190f58c16f5bd9d60f4443b658a5a3a22`.
- `GO-2026-5004`:
  `engine/vendor/github.com/jackc/pgx/v4/internal/sanitize/sanitize.go`
  recognizes PostgreSQL dollar-quoted strings and clamps overflowing
  placeholders. `sanitize_r1_test.go` covers both cases; the backport follows
  upstream fix commit `60644f84918a8af66d14a4b0d865d4edafd955da`.
- `CVE-2026-43871`:
  `engine/vendor/github.com/apache/thrift/lib/go/thrift/compact_protocol.go`
  rejects compact-protocol varints longer than the valid 10-byte encoding for
  a 64-bit integer. `compact_protocol_r1_test.go` covers the overlong input and
  valid 10-byte boundary; the backport is the exact Go fix from Apache Thrift
  commit `d5152211af61f850ec393604316804096dd4632e`.
- `CVE-2026-84304`: the official gRPC-Go receive-buffer compaction fix from
  commit `8cfeca0e1ee5ea0980dcc320e20240fa1079ec77` is backported to the engine's
  vendored v1.82.1 source and Cloudflared's vendored v1.83.0 source. The engine
  changes are hash-pinned at:
  - `engine/vendor/google.golang.org/grpc/internal/envconfig/envconfig.go`
  - `engine/vendor/google.golang.org/grpc/internal/mem/buffer_pool.go`
  - `engine/vendor/google.golang.org/grpc/internal/transport/handler_server.go`
  - `engine/vendor/google.golang.org/grpc/internal/transport/http2_client.go`
  - `engine/vendor/google.golang.org/grpc/internal/transport/http2_server.go`
  - `engine/vendor/google.golang.org/grpc/internal/transport/transport.go`
  - `engine/vendor/google.golang.org/grpc/mem/buffer_pool.go`
  - `engine/vendor/google.golang.org/grpc/mem/buffers.go`
  - `engine/vendor/google.golang.org/grpc/internal/transport/recv_buffer_compaction_r1_test.go`
  Cloudflared applies the exact v1.83.0 patch in
  `security/backports/grpc-go-cve-2026-84304-v1.83.0.patch` before its tests and
  reproducible build. The regression bounds fragmented receive backlogs to a
  pooled compacted buffer instead of retaining one heap object per DATA frame.

## Ratio1 Runtime Layer

The entrypoint compatibility contract and its tests were ported from
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
The entrypoint accepts `CRDB_NUM_REPLICAS` and `CRDB_NUM_VOTERS`, defaulting
both to `3`, and idempotently applies them to the default range zone during
bootstrap. Deeploy sets both values to the selected cluster node count.

Before starting supervised processes, the entrypoint re-executes itself with
database passwords, tunnel tokens, inline certificate values, and private keys
removed from the inherited process environment. It stages those inputs in
owner-only temporary files, installs certificates into the established certs
directory, deletes the staged certificate copies, and deletes the password
after bootstrap. Deeploy's persisted pipeline/Docker configuration exposure is
unchanged and remains governed by the separately planned secrets-vault work.

The original entrypoint used `findmnt` only to prevent deletion of a mounted
run-log subtree. This distribution reads the kernel's
`/proc/self/mountinfo` interface directly, preserving that guard while allowing
all block-device and mount libraries to be removed from the final image. The
entrypoint hash and original base hash are both recorded in
`source/provenance.json`.

The refreshed gRPC dependency enforces TLS ALPN by default, while the legacy
Ratio1 v23.1.28 image does not advertise ALPN on its CockroachDB RPC listener.
The entrypoint therefore sets gRPC's documented
`GRPC_ENFORCE_ALPN_ENABLED=false` compatibility switch so a persisted cluster
can be upgraded one node at a time. TLS encryption and certificate identity
verification remain active; only the missing protocol-negotiation extension is
tolerated. The persisted-volume rolling gate covers legacy-to-current upgrade
and rollback, and this switch can be removed only after legacy mixed-image
operation is no longer supported.

## Release Layer

- Uses digest-pinned neutral Go and Debian images.
- Builds Cloudflared from exact source commit
  `b4f47e2ab538ab6e31d3dc6adc5489455ad446de` and a checksum-pinned source
  archive, applies the hash-pinned `CVE-2026-84304` gRPC backport, then enforces
  the reviewed reproducible binary hash. Its focused command, carrier, and
  tunnel RPC tests run during the image build.
- Resolves Debian packages from a dated snapshot and pins direct package
  versions.
- Accompanies retained Debian object code with exact binary-to-source mappings,
  `.dsc` files, and source archives from that snapshot, both inside the image
  and as a checksum-backed release asset.
- Copies only the runtime executables, shared libraries, CA bundle, and OS
  metadata required by the database, Cloudflared, and compatibility entrypoint
  into a `scratch` final image. `source/runtime-packages.txt` is the exact
  package/version closure, and the image retains matching `dpkg` and copyright
  records for scanner and SBOM visibility.
- Embeds Apache, upstream, third-party, provenance, patch, and affirmative
  source-license records, including all current vendored Go license/notice
  files rather than relying on the upstream v23.1.28 aggregate notice alone.
- Publishes source/image SPDX and CycloneDX SBOMs, GitHub build provenance, an
  OCI SPDX attestation, and a keyless Cosign signature for each image digest.
- Pins Buildx, BuildKit, Syft, Trivy, and Cosign versions in both provenance and
  workflows. A release performs one digest-only build, validates that immutable
  registry candidate, and adds public tags only after signing succeeds.
- Names disposable Cloudflare release resources by exact GitHub run and attempt,
  preserves only non-secret cleanup identifiers for seven days, and runs an
  independent least-privilege recovery workflow after failed or cancelled
  release attempts. Manual recovery accepts an explicit failed run and optional
  attempt; both paths reject unrelated runs and exact-prefix near matches.
- Refreshes every asset of a resumable draft release, requires its asset set to
  exactly match the current release contract, and compares its published image
  reference with the validated candidate before image-tag promotion. A failed
  partial release cannot publish stale draft evidence.

Future releases must add the purpose, affected files, compatibility impact,
tests, and first release for every new engine or runtime patch.

### Foreground local-store corruption signal

`engine/pkg/storage/pebble_iterator.go` recognizes only iterator-close errors
carrying Pebble's typed `ErrCorruption` marker and preserves that marker while
adding `local corruption detected` to the resulting panic. The Ratio1
entrypoint uses that exact signal, together with `checksum mismatch`, to permit
its bounded one-time fresh-store recovery on clusters with at least three
configured nodes. All non-corruption errors retain upstream behavior, and
matching error text without the typed marker is rejected. The focused
regression is `engine/pkg/storage/pebble_iterator_r1_test.go`.
