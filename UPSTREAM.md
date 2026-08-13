# Upstream Provenance

## Engine

- Project: CockroachDB
- Source: https://github.com/cockroachdb/cockroach
- Tag: `v23.1.28`
- Commit: `76e598c9b1c100fd9280b979140b5e377c330a20`
- Upstream BSL change date: `2026-04-01`
- Change license for BSL-covered files: `Apache-2.0`
- OSS executable entry point: `engine/pkg/cmd/cockroach-oss`

The imported snapshot preserves upstream copyright and license headers. The
upstream `engine/licenses/BSL.txt` remains present because those headers refer
to it and because it documents the change date and change license.

The complete upstream repository is mixed-license. This repository therefore
uses a source-derived snapshot rather than preserving the complete upstream Git
history. The following explicit CCL implementation paths are excluded:

- `pkg/ccl`
- `pkg/ui/distccl`
- `pkg/ui/workspaces/db-console/ccl`

`scripts/verify-source-boundary.py` also rejects CCL license headers and CCL
imports in the OSS dependency graph. Documentation and OSS tests may accurately
refer to CCL feature gates; references are not CCL implementation.

## Native Dependencies

The exact upstream-pinned native dependency trees are imported as normal files
without nested Git metadata:

| Component | Commit | Role | License |
| --- | --- | --- | --- |
| GEOS | `ac79ef98b6a7bd26c87bf069f1e0685dbb648ba2` | Geometry runtime | LGPL-2.1-only; see `engine/c-deps/geos/COPYING` |
| jemalloc | `54eaed1d8b56b1aa528be3bdd1877e59c56fa90c` | Memory allocator | BSD-2-Clause; see `engine/c-deps/jemalloc/COPYING` |
| libedit | `9dc73e7879592ba49de2cae5019a15da706422b1` | SQL shell line editing | BSD-3-Clause; see `engine/c-deps/libedit/COPYING` |
| PROJ | `c8ff95857beb3027b5aa3d15726795570f38eccb` | Coordinate transforms | MIT; see `engine/c-deps/proj/COPYING` |

The upstream `krb5` submodule is not imported because the OSS executable does
not include the CCL GSS/Kerberos package.
`scripts/verify-provenance.py` recomputes each imported tree's deterministic
content/symlink digest using the algorithm recorded in
`source/provenance.json` and rejects any mismatch.

CI also fetches only the exact upstream engine commit into a temporary
verification directory and checks the recorded Ratio1 modifications,
omissions, and dependency metadata against the original file hashes. A
Go-aware lexical comparison fails unless the two comment-only overrides differ
only in comments. Toolchain compatibility changes, Ratio1 additions, security
backports, and the dependency snapshot are separately enumerated and
hash-pinned in `source/ratio1-engine-overrides.json`. The fetched checkout is
evidence input; it is never copied into or used to build the image.

## Runtime Source Closure

The repository retains only files required by the transitive dependency graph
of `pkg/cmd/cockroach-oss`, plus the four native dependency source trees and
their applicable license and notice files. `source/runtime-files.txt` records
the exact Go package, assembly, C/C++, embedded-data, and generated-file closure
reported by the pinned Go 1.26.5 builder in offline vendor mode. CI recomputes
that closure and fails on either a missing file or an unexpected runtime file.
The list also includes the nested C source tree consumed through local
preprocessor includes by the selected `go-libedit/unix` package; `go list`
does not report those indirect C include files itself.

Generated parser, protobuf, and related outputs needed by that closure were
produced in an isolated full checkout of the exact upstream commit and are
listed in `source/generated-files.txt`. The public build consumes these
checked-in artifacts offline; it does not retain upstream build-system targets
that enumerate enterprise packages. Details are in `RATIO1_PATCHES.md`.
