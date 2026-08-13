# Third-Party Notices

R1 Distributed SQL includes third-party source and binaries. Each component
retains its original copyright and license. The SPDX and CycloneDX release
SBOMs are the machine-readable component inventory; this file points to the
corresponding full notice/license texts shipped in the source and image.

## CockroachDB OSS Core And Go Dependencies

- Upstream engine: CockroachDB v23.1.28 at commit
  `76e598c9b1c100fd9280b979140b5e377c330a20`.
- BSL-covered engine source changed to Apache-2.0 on 2026-04-01. See
  `engine/licenses/BSL.txt` and `engine/licenses/APL.txt`.
- Go, UI, and other third-party notices preserved from upstream are in
  `engine/licenses/THIRD-PARTY-NOTICES.txt`.
- Individual license texts are retained under `engine/licenses/` and relevant
  vendored source directories under `engine/vendor/`.
- `source/license-inventory.json` affirmatively maps every retained engine file
  to an SPDX identifier or a hash-qualified `LicenseRef` and its preserved
  license basis. `github.com/mattn/go-localereader@v0.0.1` has no standalone
  license file in the module; its MIT grant is preserved in the
  `go-localereader` section of `engine/licenses/THIRD-PARTY-NOTICES.txt`.

Explicit CockroachDB Community License implementation is not included. The CCL
text itself is also not used as a license for any distributed component.

## Native Dependencies

| Component | License text |
| --- | --- |
| GEOS | LGPL-2.1-only; `engine/c-deps/geos/COPYING` |
| jemalloc | BSD-2-Clause; `engine/c-deps/jemalloc/COPYING` |
| libedit | BSD-3-Clause; `engine/c-deps/libedit/COPYING` |
| PROJ | MIT; `engine/c-deps/proj/COPYING` |

GEOS carries the MIT-licensed Artistic Style helper under
`engine/c-deps/geos/tools/astyle/`; its separate text is retained at
`engine/c-deps/geos/tools/astyle/LICENSE.md`. It is source/build tooling and is
not copied into the runtime image.

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
source URL. All 95 LICENSE, COPYING, NOTICE, and PATENTS files from the exact
vendored source are retained under `licenses/cloudflared/dependencies/` and
embedded in the runtime image.

Cloudflare's vendor snapshot omits the lowercase MIT license file for compiled
module `github.com/facebookgo/grace`. Ratio1 separately retains that exact file
at `licenses/cloudflared/dependencies/github.com/facebookgo/grace/license`;
its source commit and hash are enforced by the compliance verifier. Replacement
modules `github.com/chungthuang/quic-go` and `github.com/ipostelnik/cli/v2` are
represented explicitly in the inventory rather than only by their original
import paths.

Cloudflared compiles `gopkg.in/yaml.v2` and `gopkg.in/yaml.v3`, whose packages
contain Apache-2.0 and MIT files. Their inventory expression is
`Apache-2.0 AND MIT`; the separate yaml.v2 libyaml MIT text is retained at
`licenses/cloudflared/dependencies/gopkg.in/yaml.v2/LICENSE.libyaml`, while the
yaml.v3 combined `LICENSE` contains both grants.

## Debian Runtime

The final image is based on a pinned Debian Bookworm Slim image and installs a
small set of Debian packages. Package versions, source packages, suppliers,
licenses, and file relationships are recorded by the image SPDX and CycloneDX
SBOMs. Debian copyright files remain in `/usr/share/doc` in the image.

Report a missing or inaccurate notice through the process in `SECURITY.md`.

## Public Upstream Test Keys

The OSS CLI dependency graph embeds CockroachDB's published security test
fixtures under `engine/pkg/security/securitytest/test_certs/`. They are not
deployment credentials and must never be used outside tests. Their exact hashes
are allowlisted in `source/public-test-fixtures.sha256`; CI rejects any changed
fixture or any additional private key.
