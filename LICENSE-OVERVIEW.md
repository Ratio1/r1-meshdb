# Licensing Overview

R1 MeshDB is a mixed-license distribution. The root [LICENSE](LICENSE)
is the Apache License 2.0 text that applies to Ratio1-authored files and to
upstream engine files whose Business Source License change license has taken
effect. It does not replace the licenses of included third-party source or
binaries.

Third-party components retain their original licenses. Their component-level
license conclusions, full notice locations, and source provenance are recorded
in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md),
[`source/license-inventory.json`](source/license-inventory.json), the release
SPDX and CycloneDX SBOMs, and the license files shipped in the source and image.

The SBOM application record identifies the Ratio1-authored R1 MeshDB package as
Apache-2.0. Third-party packages, native dependencies, and source files retain
their own component- or file-level license conclusions; dependency
relationships describe the combined distribution without inventing an
aggregate license. Exact non-standard texts use hash-qualified, document-local
SPDX `LicenseRef` identifiers. Aggregate license or notice documents use
`NOASSERTION` with an explanatory comment instead of claiming one license for
several independent texts.
