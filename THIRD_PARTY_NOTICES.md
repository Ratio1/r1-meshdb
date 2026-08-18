# Third-Party Notices

R1 MeshDB includes third-party source and binaries. Each component
retains its original copyright and license. The SPDX and CycloneDX release
SBOMs are the machine-readable component inventory; this file points to the
corresponding full notice/license texts shipped in the source and image.

## CockroachDB OSS Core And Go Dependencies

- Upstream engine: CockroachDB v23.1.28 at commit
  `76e598c9b1c100fd9280b979140b5e377c330a20`.
- The exact upstream authorship artifact is retained at `engine/AUTHORS` from
  [the pinned v23.1.28 commit](https://raw.githubusercontent.com/cockroachdb/cockroach/76e598c9b1c100fd9280b979140b5e377c330a20/AUTHORS),
  SHA-256 `43f782e23df565c0f003c45dae70b25788c6fc0266a87f8624a157b499a8aac8`.
- BSL-covered engine source changed to Apache-2.0 on 2026-04-01. See
  `engine/licenses/BSL.txt` and `engine/licenses/APL.txt`.
- The upstream v23.1.28 aggregate notice is preserved at
  `engine/licenses/THIRD-PARTY-NOTICES.txt`. Because this fork refreshed some
  vendored module versions, it is historical baseline evidence rather than the
  sole authority for the current dependency closure.
- All 258 current vendored license, notice, patent, and attribution files are
  retained under `engine/vendor/`, hash-pinned by
  `source/vendor-license-manifest.json`, and copied into the runtime image at
  `/usr/share/doc/r1-meshdb/engine/vendor/`.
- `source/license-inventory.json` affirmatively maps every retained engine file
  to an SPDX identifier or a hash-qualified `LicenseRef` and its preserved
  license basis. `github.com/mattn/go-localereader@v0.0.1` has no standalone
  license file in the module; its MIT grant is preserved in the
  module's `engine/vendor/github.com/mattn/go-localereader/README.md`.

Explicit CockroachDB Community License implementation is not included. The CCL
text itself is also not used as a license for any distributed component.

## Native Dependencies

| Component | License text |
| --- | --- |
| GEOS | LGPL-2.1-only; `engine/c-deps/geos/COPYING` |
| jemalloc | BSD-2-Clause; `engine/c-deps/jemalloc/COPYING` |
| libedit | BSD-3-Clause; `engine/c-deps/libedit/COPYING` |
| PROJ | MIT; `engine/c-deps/proj/COPYING` |

GEOS is built and shipped as replaceable shared libraries loaded at runtime.
Its exact corresponding source is retained under `engine/c-deps/geos/` in each
public source tag, and the LGPL-2.1-only terms continue to apply to GEOS.

GEOS carries the MIT-licensed Artistic Style helper under
`engine/c-deps/geos/tools/astyle/`; its separate text is retained at
`engine/c-deps/geos/tools/astyle/LICENSE.md`. It is source/build tooling and is
not copied into the runtime image.

GEOS also carries the TUT C++ test framework under
`engine/c-deps/geos/tests/unit/tut/`. Its BSD-2-Clause license is retained
byte-for-byte at `engine/c-deps/geos/tests/unit/tut/LICENSE` from
[TUT commit `69d6c126e4d2263cf2cb18eb529745ea9a2296a5`](https://raw.githubusercontent.com/mrzechonek/tut-framework/69d6c126e4d2263cf2cb18eb529745ea9a2296a5/LICENSE),
SHA-256 `c208bc4abd59b0885130cd47eb9b400480a0aeeb5f0a937d35d84393258ea6c3`.
The TUT sources are test-only and are not copied into the runtime image.

The exact source snapshots also retain nested components and build helpers:

- GEOS carries BSD-3-Clause TTMATH headers under
  `engine/c-deps/geos/include/geos/algorithm/ttmath/` and a GPL-3.0-or-later
  Autoconf Archive macro with the Autoconf macro exception.
- jemalloc carries BSD-3-Clause SFMT and profiling/helper code, an MIT SMHasher
  test, and GPL-3.0-or-later Autoconf configuration helpers with the Autoconf
  exception.
- libedit carries MIT `install-sh` and GPL-2.0-or-later Autoconf/Automake and
  Libtool helpers with their corresponding exceptions.

These build and test files are not copied into the runtime image. Their full
license grants remain in their source headers, and
`source/license-inventory.json` records the exact per-file SPDX expression and
basis rather than applying the component's top-level license indiscriminately.

Exact source URLs, revisions, and tree hashes are in
`source/provenance.json`.

## Cloudflared

The runtime image builds the Cloudflare Tunnel client from Apache-2.0 source
commit `b4f47e2ab538ab6e31d3dc6adc5489455ad446de`. The exact source archive,
archive SHA-256, Git tree, source file hashes, Go toolchain, build flags, and
resulting binary SHA-256 are recorded in `source/provenance.json` and enforced
during the image build. No prebuilt Cloudflared image or binary is consumed.

The top-level Cloudflared license is retained at
`licenses/cloudflared/LICENSE`. `source/cloudflared-buildinfo.txt` records the
embedded Go module graph and `source/cloudflared-compiled-packages.txt` records
the 603-package compile closure. `source/cloudflared-license-inventory.csv`
maps every compiled component to a non-empty SPDX conclusion and immutable
source URL. All 95 notice files named LICENSE, COPYING, NOTICE, or PATENTS from
the exact vendored source are retained under
`licenses/cloudflared/dependencies/` and embedded in the runtime image.

Cloudflare's vendor snapshot omits the lowercase MIT license file for compiled
module `github.com/facebookgo/grace`. Ratio1 separately retains that exact file
as one additional MIT license at
`licenses/cloudflared/dependencies/github.com/facebookgo/grace/license`, making
96 retained dependency notice/license files in total. Its source commit and
hash are enforced by the compliance verifier. Replacement modules
`github.com/chungthuang/quic-go` and `github.com/ipostelnik/cli/v2` are
represented explicitly in the inventory rather than only by their original
import paths.

Cloudflared compiles `gopkg.in/yaml.v2` and `gopkg.in/yaml.v3`, whose packages
contain Apache-2.0 and MIT files. Their inventory expression is
`Apache-2.0 AND MIT`; the separate yaml.v2 libyaml MIT text is retained at
`licenses/cloudflared/dependencies/gopkg.in/yaml.v2/LICENSE.libyaml`, while the
yaml.v3 combined `LICENSE` contains both grants.

## Debian Runtime

The final image is based on a pinned Debian Bookworm Slim image and installs a
small set of Debian packages. Binary-to-source package/version mappings are
retained in source at `source/runtime-package-sources.tsv` and in the image at
`/usr/share/doc/r1-meshdb/runtime-package-sources.tsv`. Debian
copyright files remain in `/usr/share/doc`.

The exact `.dsc` and source archives downloaded from the Dockerfile's pinned
Debian snapshot accompany the object code inside the same image at
`/usr/share/src/r1-meshdb/debian/`. That directory includes its mapping,
`SHA256SUMS`, and a README. The release workflow also publishes a byte-identical
compressed copy as `r1-meshdb-debian-corresponding-source.tar.gz`, so recipients
do not need a live Debian mirror to obtain the corresponding source.

Report a missing or inaccurate notice through the process in `SECURITY.md`.

## SBOM Validation Schemas

Release validation vendors the official SPDX 2.3 JSON schema from SPDX
specification commit `aadf3b0b8dbbabdb4d880b0fc714255fea436ff7` under
Creative Commons Attribution 3.0 Unported, and the official CycloneDX 1.7
schemas from specification commit
`b29bae660048e0ad2fbc5f2972927b442ce951c4` under Apache-2.0. The unchanged
license texts are retained in `licenses/schemas/`. These schemas are source and
release tooling; they are not copied into the runtime image.

## Public Upstream Test Keys

The OSS CLI dependency graph embeds CockroachDB's published security test
fixtures under `engine/pkg/security/securitytest/test_certs/`. They are not
deployment credentials and must never be used outside tests. Their exact hashes
are allowlisted in `source/public-test-fixtures.sha256`; CI rejects any changed
fixture or any additional private key.
